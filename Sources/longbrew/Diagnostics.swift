import Foundation

@MainActor
enum Diagnostics {
    private(set) static var lastPowerCheck: Date?
    private(set) static var sleepDisabled: Bool?
    private(set) static var powerReadFailed = false
    private(set) static var recentErrors: [String] = []

    static func recordPowerRead(_ state: Bool?) {
        if let state {
            lastPowerCheck = .now
            sleepDisabled = state
        } else if !powerReadFailed {
            recordError("Power state could not be read; the last known state is retained.")
        }
        powerReadFailed = state == nil
    }

    static func recordError(_ message: String) {
        let safe = String(message.replacingOccurrences(of: NSHomeDirectory(), with: "~").prefix(1000))
        let entry = "\(Date.now.formatted(date: .abbreviated, time: .standard)): \(safe)"
        recentErrors.append(entry)
        if recentErrors.count > 20 { recentErrors.removeFirst(recentErrors.count - 20) }
    }

    static func report() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "Development"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let checked = lastPowerCheck?.formatted(date: .abbreviated, time: .standard) ?? "No successful check yet"
        let power = sleepDisabled.map { $0 ? "Disabled (awake)" : "Normal" } ?? "Unknown"
        return """
        Longbrew \(version) (build \(build))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        App location: \(HelperClient.isInStableLocation ? "Applications" : "Outside Applications")
        Helper: \(HelperClient.health.title)
        Registration: \(HelperClient.registrationDescription)
        Last successful power check: \(checked)
        Last known sleep state: \(power)
        Latest power read: \(powerReadFailed ? "Failed" : (lastPowerCheck == nil ? "Not checked" : "Succeeded"))
        Caffeinated: \(Caffeinated.isOn ? "On" : "Off")

        Recent errors (this session only):
        \(recentErrors.isEmpty ? "None recorded." : recentErrors.joined(separator: "\n"))
        """
    }
}
