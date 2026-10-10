import CoreWLAN
import Foundation
import Network
import Security

/// Travel failover: while Longbrew is keeping the Mac awake and the network drops,
/// join the user's phone hotspot so a long job's API calls find a way out again.
/// Idea and CoreWLAN approach from krishhgg/Insomnia (MIT).
///
/// ponytail: Insomnia also nudges tmux panes, freezes apps and builds a per-build
/// Keychain ACL for ad-hoc signing. Longbrew is Developer ID signed, so the default
/// Keychain ACL already follows the app across updates; the rest is out of scope.
@MainActor
final class HotspotFailover {
    /// Watches every interface, not just Wi-Fi: a Mac on Ethernet with Wi-Fi idle
    /// is online, and hopping to a phone then would be a downgrade.
    private let monitor = NWPathMonitor()
    private(set) var downSince: Date?
    private var nextTry: Date?
    private var attempt = 0
    private var joining = false
    private var notifiedThisOutage = false

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.pathChanged(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "longbrew.path"))
    }

    private func pathChanged(online: Bool) {
        if online {
            downSince = nil; nextTry = nil; attempt = 0; notifiedThisOutage = false
        } else if downSince == nil {
            downSince = .now
        }
    }

    /// Called from the 5 s poll — that loop already runs, so no timer of our own.
    func tick(awake: Bool) {
        guard awake, !joining, let downSince,
              let ssid = Settings.hotspotSSID,
              Self.isDue(now: .now, downSince: downSince, nextTry: nextTry) else { return }
        guard let password = HotspotPassword.read(ssid: ssid) else {
            NSLog("Longbrew: hotspot \(ssid) configured but no password in the Keychain")
            return
        }
        joining = true
        attempt += 1
        nextTry = Date.now.addingTimeInterval(Self.backoff(after: attempt))
        Task {
            let result = await Self.join(ssid: ssid, password: password)
            joining = false
            switch result {
            case .joined:
                Notify.post("hotspot", "Switched to \(ssid)",
                            "Wi-Fi dropped, so Longbrew joined your hotspot.")
            case .notFound where !notifiedThisOutage:
                notifiedThisOutage = true
                Notify.post("hotspot", "Network down",
                            "Looking for \(ssid). Turn on Personal Hotspot on your phone.")
            case .failed(let error):
                NSLog("Longbrew: hotspot join failed: \(error)")
            default: break
            }
        }
    }

    enum JoinResult: Sendable { case joined, notFound, failed(String) }

    /// Off the main actor: a CoreWLAN scan blocks for a few seconds.
    private nonisolated static func join(ssid: String, password: String) async -> JoinResult {
        await Task.detached {
            guard let wifi = CWWiFiClient.shared().interface(), wifi.powerOn() else {
                return .failed("Wi-Fi is off")
            }
            do {
                // SSID-filtered scan: association works with the returned network
                // even when macOS redacts its name for lack of Location permission.
                guard let network = try wifi.scanForNetworks(withSSID: Data(ssid.utf8)).first else {
                    return .notFound
                }
                try wifi.associate(to: network, password: password)
                return .joined
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value
    }

    /// First try 5 s into an outage, then back off 10, 20, 30, 30… seconds.
    nonisolated static func isDue(now: Date, downSince: Date, nextTry: Date?) -> Bool {
        now >= (nextTry ?? downSince.addingTimeInterval(5))
    }

    nonisolated static func backoff(after attempt: Int) -> TimeInterval {
        [10, 20, 30][min(attempt, 3) - 1]
    }
}

/// The hotspot password lives in the login Keychain, never in UserDefaults and
/// never in a process argument.
enum HotspotPassword {
    private static let service = "com.brandon.clamshelled.hotspot"

    private static func query(_ ssid: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: ssid]
    }

    static func read(ssid: String) -> String? {
        var q = query(ssid)
        q[kSecReturnData as String] = true
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    @discardableResult
    static func save(_ password: String, ssid: String) -> Bool {
        SecItemDelete(query(ssid) as CFDictionary)
        guard !password.isEmpty else { return true }
        var q = query(ssid)
        q[kSecValueData as String] = Data(password.utf8)
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}
