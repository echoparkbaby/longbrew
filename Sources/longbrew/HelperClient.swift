import Foundation
import ServiceManagement
import LongbrewShared

/// Guards a continuation so it resumes exactly once. An XPC call can complete via
/// the reply block, the error handler, *or* our timeout — resuming twice would trap.
private final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func fire(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

/// A Sendable error carrying just the message — enough for every alert we show, and
/// `Result<Void, any Error>` isn't Sendable so it can't cross a continuation.
struct HelperError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// Everything the app knows about its privileged helper.
///
/// All calls are asynchronous with a bounded timeout: a wedged helper must never
/// freeze the menu bar, and must never make the app unquittable.
@MainActor
enum HelperClient {

    static let callTimeout: Duration = .seconds(10)

    static var service: SMAppService {
        SMAppService.daemon(plistName: LongbrewHelperInfo.daemonPlistName)
    }
    static var status: SMAppService.Status { service.status }
    static var isEnabled: Bool { status == .enabled }

    private static var connectionHealth: HelperHealth = .unchecked
    private static var lastHealthCheck: Date?
    private static var healthProbeInFlight = false

    static var registrationDescription: String {
        switch status {
        case .enabled: "Enabled"
        case .requiresApproval: "Approval needed"
        case .notRegistered: "Not registered"
        case .notFound: "Not found"
        @unknown default: "Unknown"
        }
    }

    static var health: HelperHealth {
        switch status {
        case .requiresApproval: return .approvalNeeded
        case .enabled:
            if healthProbeInFlight { return .checking }
            return connectionHealth
        default: return .notInstalled
        }
    }

    static func checkHealth(force: Bool = false) async {
        guard isEnabled, !healthProbeInFlight else { return }
        if !force, let lastHealthCheck, Date.now.timeIntervalSince(lastHealthCheck) < 30 { return }
        healthProbeInFlight = true
        _ = await runningGeneration()
        healthProbeInFlight = false
    }

    /// A LaunchDaemon's BundleProgram resolves *inside* this bundle, so registering
    /// from a disk image, a translocated copy, or a folder the user might move
    /// leaves a daemon pointing at a path that can vanish or be swapped.
    static var isInStableLocation: Bool {
        let path = Bundle.main.bundlePath
        return path.hasPrefix("/Applications/")
            && !path.contains("AppTranslocation")
    }

    // MARK: - Privileged calls

    private static func makeConnection() -> NSXPCConnection {
        let conn = NSXPCConnection(machServiceName: LongbrewHelperInfo.machServiceName,
                                   options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: LongbrewHelperProtocol.self)
        // Pin the helper's signature so we can't be steered to an impostor.
        conn.setCodeSigningRequirement(LongbrewHelperInfo.helperRequirement)
        return conn
    }

    /// Asks the helper to flip `pmset -a disablesleep`.
    static func setDisableSleep(_ on: Bool) async -> (ok: Bool, output: String) {
        let conn = makeConnection()
        conn.resume()
        defer { conn.invalidate() }

        let result: (Bool, String) = await withCheckedContinuation { continuation in
            // XPC invokes callbacks on its own queue, not the main actor.
            // Explicit Sendable closures avoid inheriting this method’s isolation.
            let shot = OneShot(continuation)
            let proxy = conn.remoteObjectProxyWithErrorHandler { @Sendable error in
                shot.fire((false, error.localizedDescription))
            } as? LongbrewHelperProtocol

            guard let proxy else {
                shot.fire((false, "Couldn’t reach the privileged helper."))
                return
            }
            proxy.setDisableSleep(on) { @Sendable ok, out in shot.fire((ok, out)) }

            Task {
                try? await Task.sleep(for: callTimeout)
                shot.fire((false, "The privileged helper didn’t respond in time."))
            }
        }
        if !result.0 {
            connectionHealth = .failed
            Diagnostics.recordError("Helper operation failed: " + result.1)
        } else if connectionHealth == .failed {
            connectionHealth = .unchecked
            lastHealthCheck = nil
        }
        return (ok: result.0, output: result.1)
    }

    /// Generation of the *running* helper — nil if it can't be reached.
    static func runningGeneration() async -> Int? {
        let conn = makeConnection()
        conn.resume()
        defer { conn.invalidate() }

        let result: Int? = await withCheckedContinuation { continuation in
            let shot = OneShot<Int?>(continuation)
            let proxy = conn.remoteObjectProxyWithErrorHandler { @Sendable _ in
                shot.fire(nil)
            } as? LongbrewHelperProtocol

            guard let proxy else { shot.fire(nil); return }
            proxy.protocolGeneration { @Sendable in shot.fire($0) }

            Task {
                try? await Task.sleep(for: callTimeout)
                shot.fire(nil)
            }
        }
        let next: HelperHealth = result == nil ? .failed
            : (result == LongbrewHelperInfo.protocolGeneration ? .ready : .updateNeeded)
        if next != connectionHealth, next == .failed || next == .updateNeeded {
            Diagnostics.recordError(next == .failed ? "Helper connection failed." : "Running helper needs an update.")
        }
        connectionHealth = next
        lastHealthCheck = .now
        return result
    }

    // MARK: - Registration

    static func register() throws {
        try requireStableLocation()
        try service.register()
        connectionHealth = .unchecked
        lastHealthCheck = nil
    }

    static func requireStableLocation() throws {
        guard isInStableLocation else {
            throw HelperError(message: "Move Longbrew to Applications before installing or reinstalling its helper.")
        }
    }

    static func reinstall() async throws {
        // Check before unregistering: a movable copy must not disturb a working job.
        try requireStableLocation()
        try await unregister()
        try await Task.sleep(for: .milliseconds(500))
        try register()
    }

    /// Unregister and wait for launchd to confirm — registering again before the old
    /// job is gone is exactly how a stale root helper survives an update.
    ///
    /// Bounded, like every other call here: launchd not calling back must surface as
    /// a failure the user sees, not a Task that never finishes.
    static let unregisterTimeout: Duration = .seconds(30)

    static func unregister() async throws {
        let result: Result<Void, HelperError> = await withCheckedContinuation { continuation in
            let shot = OneShot<Result<Void, HelperError>>(continuation)
            service.unregister { @Sendable error in
                if let error {
                    shot.fire(.failure(HelperError(message: error.localizedDescription)))
                } else {
                    shot.fire(.success(()))
                }
            }
            Task {
                try? await Task.sleep(for: unregisterTimeout)
                shot.fire(.failure(HelperError(message: "Timed out waiting for launchd.")))
            }
        }
        try result.get()
        connectionHealth = .unchecked
        lastHealthCheck = nil
    }

    /// Replacing the app does NOT restart an already-running helper, so an old root
    /// binary can keep serving a new app. Detect that and cycle the registration.
    /// Returns true if a re-registration was performed.
    @discardableResult
    static func reregisterIfStale() async -> Bool {
        guard isInStableLocation, isEnabled else { return false }
        let running = await runningGeneration()
        // Reachable and current → nothing to do. Unreachable (nil) is also worth a
        // cycle: the registration exists but nothing is answering on it.
        if running == LongbrewHelperInfo.protocolGeneration { return false }

        NSLog("Longbrew: helper generation \(running.map(String.init) ?? "unreachable") "
              + "≠ \(LongbrewHelperInfo.protocolGeneration) — re-registering")
        do {
            try await reinstall()
            return true
        } catch {
            Diagnostics.recordError("Helper repair failed: " + error.localizedDescription)
            NSLog("Longbrew: helper re-registration failed: \(error.localizedDescription)")
            return false
        }
    }
}
