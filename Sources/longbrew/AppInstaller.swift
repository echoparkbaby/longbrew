import AppKit
import Security
import LongbrewShared

/// Stages and verifies a complete bundle before publishing it in Applications.
/// The source is retained so a failed installation never destroys the working copy.
enum AppInstaller {
    static let destination = URL(fileURLWithPath: "/Applications/Longbrew.app")

    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func verify(_ url: URL) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecRequirementCreateWithString(LongbrewHelperInfo.appRequirement as CFString,
                                             [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code,
                  SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode),
                  requirement) == errSecSuccess else {
            throw InstallError(message: "Longbrew’s signature could not be verified. Rebuild or download a fresh signed copy and try again.")
        }
    }

    /// Destination and verifier are injectable for tests using temporary folders.
    static func copyVerifiedBundle(
        from source: URL, to destination: URL,
        verify: (URL) throws -> Void = AppInstaller.verify
    ) throws {
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path) else {
            throw InstallError(message: "Longbrew already exists in Applications. Quit that copy and move it out of Applications, then try again. Your existing app has not been replaced.")
        }
        let stage = destination.deletingLastPathComponent()
            .appendingPathComponent(".Longbrew-install-\(UUID().uuidString).app")
        defer { try? files.removeItem(at: stage) }
        try files.copyItem(at: source, to: stage)
        try verify(stage)
        // moveItem refuses a destination that appeared during the copy as well.
        try files.moveItem(at: stage, to: destination)
    }

    @MainActor static func installAndOpen() async throws {
        let source = Bundle.main.bundleURL
        try await Task.detached(priority: .userInitiated) {
            try copyVerifiedBundle(from: source, to: destination)
        }.value
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--complete-install"]
        let installed = try await NSWorkspace.shared.openApplication(at: destination,
                                                                     configuration: configuration)
        guard !installed.isTerminated else {
            throw InstallError(message: "The installed copy quit while opening. Longbrew has kept this copy running. Open Applications to try the installed copy again.")
        }
    }
}
