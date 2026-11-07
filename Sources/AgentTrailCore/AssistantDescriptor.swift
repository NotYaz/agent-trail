import Foundation

/// Where an assistant's sessions run, which decides how Jump reaches them.
public enum AssistantHosting: Sendable, Equatable {
    /// Its own desktop app; a single session may still run in a terminal (Claude).
    case desktopApp
    /// Its own app or a terminal; the live reader names the host per session (Codex).
    case appOrTerminal
    /// A command-line agent running in a terminal (Grok).
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
    /// True when a profile pairs its home with a desktop data folder.
    public let usesUserDataDirectory: Bool
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
                usesUserDataDirectory: true, reportsDelegation: true, delegationOrigin: "a Claude subagent",
                editEvidence: "Claude's Edit and Write tools", worktreeFolder: ".claude")
        case .codex:
            return AssistantDescriptor(kind: self, displayName: "Codex", homeTitle: "Codex home",
                homeFolder: ".codex", homeEnvironmentVariable: "CODEX_HOME", hosting: .appOrTerminal,
                defaultBundleIdentifier: "", requiresBundleIdentifier: false,
                usesUserDataDirectory: false, reportsDelegation: true, delegationOrigin: "a spawned Codex thread",
                editEvidence: "Codex's completed file changes", worktreeFolder: ".codex")
        case .grok:
            return AssistantDescriptor(kind: self, displayName: "Grok", homeTitle: "Grok home",
                homeFolder: ".grok", homeEnvironmentVariable: "GROK_HOME", hosting: .terminal,
                defaultBundleIdentifier: "", requiresBundleIdentifier: false,
                usesUserDataDirectory: false, reportsDelegation: false, delegationOrigin: nil,
                editEvidence: "Grok's completed write and search-replace calls", worktreeFolder: nil)
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

/// Builds each assistant's readers. One exhaustive switch per reader kind, so
/// a new assistant cannot be left out of scans, cache flushes or live status.
enum AssistantRegistry {
    static func history(_ kind: AssistantKind, cacheURL: URL?, resolver: GitProjectResolver) -> any HistoryAdapter {
        switch kind {
        case .claude: return ClaudeActivityProvider(cacheURL: cacheURL, resolver: resolver)
        case .codex: return CodexActivityProvider(cacheURL: cacheURL, resolver: resolver)
        case .grok: return GrokActivityProvider(cacheURL: cacheURL, resolver: resolver)
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
