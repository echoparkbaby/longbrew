import Foundation

/// Persisted preferences. Plain UserDefaults — nothing here is a secret, and the
/// system already handles the file, the migration and the flushing.
@MainActor
enum Settings {
    private static let store = UserDefaults.standard

    // Fresh key on purpose. The tint used to mark Keep Me Awake and this was
    // "TintIconWhenKeepAwake"; anyone who turned THAT off didn't turn this off.
    private enum Key {
        static let tintWhenLidClosed = "TintIconWhenLidClosed"
        static let autoOffMinutes   = "ClamshellAutoOffMinutes"
        // Stored name is historical, like autoOffMinutes below it — this was
        // "Espresso duration" before the rename. Renaming the KEY would reset it.
        static let caffeinatedDuration = "EspressoDurationMinutes"
        static let caffeinateWithLidClosed = "CaffeinateWithLidClosed"
    }

    /// Call once at launch, before anything reads a value.
    static func registerDefaults() {
        store.register(defaults: [
            Key.tintWhenLidClosed: true,
            Key.autoOffMinutes: 0,         // 0 = never
            Key.caffeinatedDuration: SessionDuration.untilQuit.rawValue,
            Key.caffeinateWithLidClosed: false,   // opt-in: lid-closed alone lets the screen sleep
        ])
    }

    static var tintWhenLidClosed: Bool {
        get { store.bool(forKey: Key.tintWhenLidClosed) }
        set { store.set(newValue, forKey: Key.tintWhenLidClosed) }
    }

    /// Minutes after which lid-closed mode turns itself off. 0 = never.
    static var autoOffMinutes: Int {
        get { store.integer(forKey: Key.autoOffMinutes) }
        set { store.set(newValue, forKey: Key.autoOffMinutes) }
    }

    /// Turn Caffeinated on alongside lid-closed mode. Off by default: lid-closed on
    /// its own keeps the machine running while letting the screen go dark, which is
    /// the point of it for most people. This is for the ones who want both.
    static var caffeinateWithLidClosed: Bool {
        get { store.bool(forKey: Key.caffeinateWithLidClosed) }
        set { store.set(newValue, forKey: Key.caffeinateWithLidClosed) }
    }

    static var caffeinatedDuration: SessionDuration {
        get { SessionDuration(rawValue: store.integer(forKey: Key.caffeinatedDuration)) ?? .untilQuit }
        set { store.set(newValue.rawValue, forKey: Key.caffeinatedDuration) }
    }

    /// Menu titles and their stored values, in display order.
    static let autoOffChoices: [(title: String, minutes: Int)] = [
        ("Until turned off", 0),
        ("Until I quit", -1),
        ("After 30 minutes", 30),
        ("After 1 hour", 60),
        ("After 2 hours", 120),
        ("After 4 hours", 240),
        ("After 8 hours", 480),
    ]
}
