import Foundation

/// UserDefaults keys shared by the project cards, the panel menu and the
/// menu-bar item. Views read them with @AppStorage; other code uses the
/// accessors below, which fall back to the same defaults.
enum AppSettings {
    enum Key {
        /// Show conversation titles on cards, menus and hints. Off shows the branch or folder instead.
        static let showSessionTitles = "showSessionTitles"
        /// Animate the menu-bar glyph while something is working.
        static let statusAnimates = "statusAnimates"
        /// Show the needs-input count next to the menu-bar glyph.
        static let statusShowsCount = "statusShowsCount"
        /// The editor used by "Open in {editor}" and the Jump fallback.
        static let preferredEditorBundleID = "preferredEditorBundleID"
        /// The terminal used by "Open in {terminal}".
        static let preferredTerminalBundleID = "preferredTerminalBundleID"
    }

    /// The three switches default to on. The preferred apps have no default:
    /// the first installed app in the launcher's order is used until one is chosen.
    static let boolDefaults: [String: Bool] = [
        Key.showSessionTitles: true,
        Key.statusAnimates: true,
        Key.statusShowsCount: true
    ]

    /// Safe to call more than once; registered defaults never overwrite a stored choice.
    static func registerDefaults(_ defaults: UserDefaults = .standard) {
        defaults.register(defaults: boolDefaults)
    }

    static var showSessionTitles: Bool { bool(Key.showSessionTitles) }
    static var statusAnimates: Bool { bool(Key.statusAnimates) }
    static var statusShowsCount: Bool { bool(Key.statusShowsCount) }

    static var preferredEditorBundleID: String? {
        get { string(Key.preferredEditorBundleID) }
        set { UserDefaults.standard.set(newValue, forKey: Key.preferredEditorBundleID) }
    }

    static var preferredTerminalBundleID: String? {
        get { string(Key.preferredTerminalBundleID) }
        set { UserDefaults.standard.set(newValue, forKey: Key.preferredTerminalBundleID) }
    }

    /// A stored value that is not a Bool (a hand-edited plist) reads as the default.
    private static func bool(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? boolDefaults[key] ?? true
    }

    private static func string(_ key: String) -> String? {
        guard let value = UserDefaults.standard.string(forKey: key), !value.isEmpty else { return nil }
        return value
    }
}
