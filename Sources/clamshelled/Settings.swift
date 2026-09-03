import Foundation

/// Persisted preferences. Plain UserDefaults — nothing here is a secret, and the
/// system already handles the file, the migration and the flushing.
@MainActor
enum Settings {
    private static let store = UserDefaults.standard

    // The stored key is historical — the tint used to mark Keep Me Awake, now it
    // marks lid-closed mode. Renaming a UserDefaults key silently resets the
    // preference behind it, and the string is invisible to users, so it stays.
    private enum Key {
        static let tintWhenLidClosed = "TintIconWhenKeepAwake"
        static let autoOffMinutes   = "ClamshellAutoOffMinutes"
    }

    /// Call once at launch, before anything reads a value.
    static func registerDefaults() {
        store.register(defaults: [
            Key.tintWhenLidClosed: true,
            Key.autoOffMinutes: 0,         // 0 = never
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

    /// Menu titles and their stored values, in display order.
    static let autoOffChoices: [(title: String, minutes: Int)] = [
        ("Never", 0),
        ("After 1 hour", 60),
        ("After 2 hours", 120),
        ("After 4 hours", 240),
        ("After 8 hours", 480),
    ]
}
