import Foundation

/// Persisted preferences. Plain UserDefaults — nothing here is a secret, and the
/// system already handles the file, the migration and the flushing.
@MainActor
enum Settings {
    private static let store = UserDefaults.standard

    // The stored keys still say "KeepAwake", Espresso's old name. Renaming a
    // UserDefaults key silently resets the preference behind it, and the string is
    // invisible to users — not worth a reset to tidy up.
    private enum Key {
        static let espressoAtLaunch = "KeepAwakeAtLaunch"
        static let tintWhenEspresso = "TintIconWhenKeepAwake"
        static let autoOffMinutes   = "ClamshellAutoOffMinutes"
    }

    /// Call once at launch, before anything reads a value.
    static func registerDefaults() {
        store.register(defaults: [
            Key.espressoAtLaunch: false,   // opt-in: don't change sleep behaviour uninvited
            Key.tintWhenEspresso: true,
            Key.autoOffMinutes: 0,         // 0 = never
        ])
    }

    static var espressoAtLaunch: Bool {
        get { store.bool(forKey: Key.espressoAtLaunch) }
        set { store.set(newValue, forKey: Key.espressoAtLaunch) }
    }

    static var tintWhenEspresso: Bool {
        get { store.bool(forKey: Key.tintWhenEspresso) }
        set { store.set(newValue, forKey: Key.tintWhenEspresso) }
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
