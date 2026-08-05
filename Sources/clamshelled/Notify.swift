import UserNotifications

/// Banner notifications for the two states this app owns. Both are invisible once
/// the menu closes, and auto-off flips one of them hours later with nobody watching
/// — the banner is the only thing that says so.
@MainActor
enum Notify {

    /// `UNUserNotificationCenter.current()` raises an ObjC exception — uncatchable
    /// from Swift — when the process has no bundle. That's exactly how this binary
    /// runs under `swift build` and `--self-test`, so every entry point checks.
    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    static func start(delegate: any UNUserNotificationCenterDelegate) {
        guard let center else { return }
        center.delegate = delegate
        // Alert only. A menu-bar toggle that beeps at you is a toggle you turn off.
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    /// `id` is stable per kind on purpose: flip a switch twice and you get one
    /// banner showing where it ended up, not two racing each other.
    static func post(_ id: String, _ title: String, _ body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }
}
