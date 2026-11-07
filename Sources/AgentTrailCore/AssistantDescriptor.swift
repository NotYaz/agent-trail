import Foundation

/// Where an assistant's sessions run, which decides how Jump reaches them.
public enum AssistantHosting: Sendable, Equatable {
    /// Its own desktop app; a single session may still run in a terminal (Claude).
    case desktopApp
    /// Its own app or a terminal; the live reader names the host per session (Codex).
    case appOrTerminal
    /// A command-line agent running in a terminal (Grok, the Copilot CLI).
    case terminal
}

/// What differs between assistants outside their adapters. Shared code reads
/// these fields where they apply; the few paths that still name an assistant
/// (Claude and Codex links in Jump, Claude's process match and desktop-folder
/// default) are listed in CONTRIBUTING.md.
public struct AssistantDescriptor: Sendable {
    public let kind: AssistantKind
    public let displayName: String
    /// Settings label for the profile's main folder.
    public let homeTitle: String
    /// The home folder, relative to the user's home folder.
    let homeFolder: String
    /// The environment variable that moves the home, read from a live process to
    /// match it to a profile. Nil when the home cannot be moved.
    public let homeEnvironmentVariable: String?
    public let hosting: AssistantHosting
    /// The app a new profile focuses; empty when the assistant has no desktop app.
    public let defaultBundleIdentifier: String
    /// True when a profile must name the assistant's desktop app.
    public let requiresBundleIdentifier: Bool
    /// True when a profile pairs its home with an app's data folder (Claude
    /// Desktop's, or VS Code's for Copilot).
    public let usesUserDataDirectory: Bool
    /// The data folder a profile with the default home reads when it names none.
    public let defaultUserDataDirectory: String?
    /// True when a profile with a custom home must name its data folder.
    public let requiresUserDataDirectory: Bool
    /// Settings copy for the data folder field.
    public let userDataTitle: String?
    public let userDataPlaceholder: String?
    public let userDataNote: String?
    /// False when the assistant records no subagents or spawned sessions, so
    /// Growth shows "not reported" instead of a false 0% delegated.
    public let reportsDelegation: Bool
    /// Where delegated edits come from, for Growth copy ("a Claude subagent").
    public let delegationOrigin: String?
    /// What counts as one edit, for Growth copy ("Claude's Edit and Write tools").
    public let editEvidence: String
    /// The folder inside a project that holds this assistant's worktrees, as
    /// `<folder>/worktrees/<name>`. Nil when it keeps none there.
    public let worktreeFolder: String?

    public func defaultHome(home: String) -> String {
        "\(home)/\(homeFolder)"
    }
}

extension AssistantKind {
    public var descriptor: AssistantDescriptor {
        switch self {
        case .claude:
            return AssistantDescriptor(kind: self, displayName: "Claude", homeTitle: "Claude config folder",
                homeFolder: ".claude", homeEnvironmentVariable: "CLAUDE_CONFIG_DIR", hosting: .desktopApp,
                defaultBundleIdentifier: "com.anthropic.claudefordesktop", requiresBundleIdentifier: true,
                usesUserDataDirectory: true, defaultUserDataDirectory: "~/Library/Application Support/Claude",
                requiresUserDataDirectory: true, userDataTitle: "Desktop user-data folder",
                userDataPlaceholder: "Default Claude desktop profile",
                userDataNote: "Leave blank only for the default Claude profile. For custom config folders, enter the matching --user-data-dir folder.",
                reportsDelegation: true, delegationOrigin: "a Claude subagent",
                editEvidence: "Claude's Edit and Write tools", worktreeFolder: ".claude")
        case .codex:
            return AssistantDescriptor(kind: self, displayName: "Codex", homeTitle: "Codex home",
                homeFolder: ".codex", homeEnvironmentVariable: "CODEX_HOME", hosting: .appOrTerminal,
                defaultBundleIdentifier: "", requiresBundleIdentifier: false,
                usesUserDataDirectory: false, defaultUserDataDirectory: nil, requiresUserDataDirectory: false,
                userDataTitle: nil, userDataPlaceholder: nil, userDataNote: nil,
                reportsDelegation: true, delegationOrigin: "a spawned Codex thread",
                editEvidence: "Codex's completed file changes", worktreeFolder: ".codex")
        case .grok:
            return AssistantDescriptor(kind: self, displayName: "Grok", homeTitle: "Grok home",
                homeFolder: ".grok", homeEnvironmentVariable: "GROK_HOME", hosting: .terminal,
                defaultBundleIdentifier: "", requiresBundleIdentifier: false,
                usesUserDataDirectory: false, defaultUserDataDirectory: nil, requiresUserDataDirectory: false,
                userDataTitle: nil, userDataPlaceholder: nil, userDataNote: nil,
                reportsDelegation: false, delegationOrigin: nil,
                editEvidence: "Grok's completed write and search-replace calls", worktreeFolder: nil)
        case .copilot:
            // One profile reads the Copilot CLI's home and VS Code's chat storage.
            return AssistantDescriptor(kind: self, displayName: "Copilot", homeTitle: "Copilot CLI home",
                homeFolder: ".copilot", homeEnvironmentVariable: "COPILOT_HOME", hosting: .terminal,
                defaultBundleIdentifier: "", requiresBundleIdentifier: false,
                usesUserDataDirectory: true, defaultUserDataDirectory: "~/Library/Application Support/Code",
                requiresUserDataDirectory: false, userDataTitle: "VS Code user-data folder",
                userDataPlaceholder: "VS Code's default folder, with the default home",
                userDataNote: "Copilot Chat sessions are read from this VS Code folder, and Copilot CLI sessions from the home above. With the default ~/.copilot home, leave it blank to read VS Code's default folder; with another home, enter the VS Code folder whose chats to read. Insiders uses ~/Library/Application Support/Code - Insiders.",
                reportsDelegation: true, delegationOrigin: "a Copilot subagent",
                editEvidence: "Copilot's applied edit and create-file calls", worktreeFolder: nil)
        case .opencode:
            // The profile's folder is OpenCode's data folder, which holds opencode.db.
            return AssistantDescriptor(kind: self, displayName: "OpenCode", homeTitle: "OpenCode data folder",
                homeFolder: ".local/share/opencode", homeEnvironmentVariable: nil, hosting: .appOrTerminal,
                defaultBundleIdentifier: "", requiresBundleIdentifier: false,
                usesUserDataDirectory: false, defaultUserDataDirectory: nil, requiresUserDataDirectory: false,
                userDataTitle: nil, userDataPlaceholder: nil, userDataNote: nil,
                reportsDelegation: true, delegationOrigin: "an OpenCode subagent",
                editEvidence: "OpenCode's completed edit, write and patch calls", worktreeFolder: nil)
        case .cursor:
            // One profile reads the Cursor CLI's home and the Cursor app's data folder.
            return AssistantDescriptor(kind: self, displayName: "Cursor", homeTitle: "Cursor CLI home",
                homeFolder: ".cursor", homeEnvironmentVariable: "CURSOR_CONFIG_DIR", hosting: .desktopApp,
                defaultBundleIdentifier: "", requiresBundleIdentifier: false,
                usesUserDataDirectory: true, defaultUserDataDirectory: "~/Library/Application Support/Cursor",
                requiresUserDataDirectory: false, userDataTitle: "Cursor user-data folder",
                userDataPlaceholder: "Cursor's default folder, with the default home",
                userDataNote: "Cursor app chats are read from this folder, and Cursor CLI sessions from the home above. With the default ~/.cursor home, leave it blank to read Cursor's default folder.",
                reportsDelegation: true, delegationOrigin: "a Cursor subagent",
                editEvidence: "Cursor's applied edit and delete calls", worktreeFolder: nil)
        case .gemini:
            // GEMINI_CLI_HOME names the folder that holds `.gemini`, not the home
            // itself, so it cannot be compared with a profile's home.
            return AssistantDescriptor(kind: self, displayName: "Gemini CLI", homeTitle: "Gemini CLI home",
                homeFolder: ".gemini", homeEnvironmentVariable: nil, hosting: .terminal,
                defaultBundleIdentifier: "", requiresBundleIdentifier: false,
                usesUserDataDirectory: false, defaultUserDataDirectory: nil, requiresUserDataDirectory: false,
                userDataTitle: nil, userDataPlaceholder: nil, userDataNote: nil,
                reportsDelegation: true, delegationOrigin: "a Gemini CLI subagent",
                editEvidence: "Gemini CLI's successful write_file and replace calls", worktreeFolder: ".gemini")
        case .qwen:
            return AssistantDescriptor(kind: self, displayName: "Qwen Code", homeTitle: "Qwen Code home",
                homeFolder: ".qwen", homeEnvironmentVariable: "QWEN_HOME", hosting: .terminal,
                defaultBundleIdentifier: "", requiresBundleIdentifier: false,
                usesUserDataDirectory: true, defaultUserDataDirectory: nil, requiresUserDataDirectory: false,
                userDataTitle: "Qwen runtime folder", userDataPlaceholder: "Same as the Qwen Code home",
                userDataNote: "Set this only if QWEN_RUNTIME_DIR or advanced.runtimeOutputDir moved Qwen's session files: the folder that holds projects/. Live status always reads sessions/ in the home above.",
                reportsDelegation: true, delegationOrigin: "a Qwen Code subagent",
                editEvidence: "Qwen Code's successful edit, write_file and notebook_edit calls", worktreeFolder: ".qwen")
        }
    }

    /// The assistants' names as an English list: "Claude, Codex, and Grok".
    public static func listedNames(conjunction: String = "and") -> String {
        listed(allCases.map(\.displayName), conjunction: conjunction)
    }

    /// "a", "a and b", "a, b, and c".
    public static func listed(_ items: [String], conjunction: String = "and") -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) \(conjunction) \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + ", \(conjunction) " + items.last!
        }
    }

    /// Every environment variable that moves an assistant's home.
    static var homeEnvironmentVariables: [String] {
        allCases.compactMap(\.descriptor.homeEnvironmentVariable)
    }
}

/// The history adapter contract the composite routes profiles through.
/// Adapters record evidence and fold it with `HistoryFold`; they never decide
/// project locations themselves.
protocol HistoryAdapter: AnyObject {
    /// A quick listing that may reuse cached evidence, shown before a full scan.
    func metadata(sources: [AgentSource]) -> ScanResult
    /// A full incremental scan. `progress` receives partial results.
    func scan(sources: [AgentSource], progress: ((ScanResult, Int, Int) -> Void)?) -> ScanResult
    /// Writes the adapter's cache if a scan changed it. Returns a notice on failure.
    @discardableResult func saveCache() -> String?
}

extension ClaudeActivityProvider: HistoryAdapter {}
extension CodexActivityProvider: HistoryAdapter {}
extension GrokActivityProvider: HistoryAdapter {}
extension CopilotActivityProvider: HistoryAdapter {}
extension OpenCodeActivityProvider: HistoryAdapter {}
extension CursorActivityProvider: HistoryAdapter {}
extension GeminiActivityProvider: HistoryAdapter {}
extension QwenActivityProvider: HistoryAdapter {}

/// Builds each assistant's readers. One exhaustive switch per reader kind, so
/// a new assistant cannot be left out of scans, cache flushes or live status.
enum AssistantRegistry {
    static func history(_ kind: AssistantKind, cacheURL: URL?, resolver: GitProjectResolver) -> any HistoryAdapter {
        switch kind {
        case .claude: return ClaudeActivityProvider(cacheURL: cacheURL, resolver: resolver)
        case .codex: return CodexActivityProvider(cacheURL: cacheURL, resolver: resolver)
        case .grok: return GrokActivityProvider(cacheURL: cacheURL, resolver: resolver)
        case .copilot: return CopilotActivityProvider(cacheURL: cacheURL, resolver: resolver)
        case .opencode: return OpenCodeActivityProvider(cacheURL: cacheURL, resolver: resolver)
        case .cursor: return CursorActivityProvider(cacheURL: cacheURL, resolver: resolver)
        case .gemini: return GeminiActivityProvider(cacheURL: cacheURL, resolver: resolver)
        case .qwen: return QwenActivityProvider(cacheURL: cacheURL, resolver: resolver)
        }
    }

    /// Nil for an assistant whose live state cannot be read.
    static func live(_ kind: AssistantKind) -> (([AgentSource], Date) -> LiveSnapshot)? {
        switch kind {
        case .claude:
            let reader = LiveActivityProvider()
            return { reader.scan(sources: $0, now: $1) }
        case .codex:
            let reader = CodexLiveActivityProvider()
            return { reader.scan(sources: $0, now: $1) }
        case .grok:
            let reader = GrokLiveActivityProvider()
            return { reader.scan(sources: $0, now: $1) }
        case .copilot:
            let reader = CopilotLiveActivityProvider()
            return { reader.scan(sources: $0, now: $1) }
        case .opencode:
            let reader = OpenCodeLiveActivityProvider()
            return { reader.scan(sources: $0, now: $1) }
        case .cursor:
            // Cursor records no process per chat, and its saved chat state lags.
            return nil
        case .gemini:
            // Gemini CLI writes no live state to disk.
            return nil
        case .qwen:
            let reader = QwenLiveActivityProvider()
            return { reader.scan(sources: $0, now: $1) }
        }
    }

    /// The cache file for one assistant. Claude keeps the original name, so
    /// existing caches stay valid; the others add their raw value.
    static func cacheURL(_ kind: AssistantKind, base: URL?) -> URL? {
        guard let base else { return nil }
        guard kind != .claude else { return base }
        let stem = base.deletingPathExtension().lastPathComponent
        return base.deletingLastPathComponent().appendingPathComponent("\(stem)-\(kind.rawValue).json")
    }
}
