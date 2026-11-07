import Foundation

/// An `agenttrail://` link, for launchers, Shortcuts, Stream Deck buttons and
/// scripts. A link only picks among the live sessions Agent Trail already
/// shows. It never names a file to open or a command to run, and anything
/// outside these four forms is rejected:
///
/// - `agenttrail://jump`: the most urgent live session
/// - `agenttrail://jump?project=NAME`: the most urgent live session in a
///   project, by folder name (any case) or full path
/// - `agenttrail://jump?session=ID`: one session, by the assistant's session or
///   thread id (`AgentTrailInspect --live` lists them)
/// - `agenttrail://switcher`: the session switcher
public enum AgentTrailLink: Equatable, Sendable {
    case jumpMostUrgent
    case jumpProject(String)
    case jumpSession(String)
    case switcher

    public static let scheme = "agenttrail"
    /// Whole links longer than this are rejected before parsing.
    static let maxLinkLength = 2048
    static let maxProjectLength = 1024
    static let maxSessionLength = 128

    public static func parse(_ url: URL) -> AgentTrailLink? {
        guard url.absoluteString.utf8.count <= maxLinkLength,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.user == nil, components.password == nil, components.port == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        let items = components.queryItems ?? []
        switch components.host?.lowercased() {
        case "switcher":
            return items.isEmpty ? .switcher : nil
        case "jump":
            guard let item = items.first else { return .jumpMostUrgent }
            guard items.count == 1, let value = item.value else { return nil }
            switch item.name {
            case "project": return project(value).map { AgentTrailLink.jumpProject($0) }
            case "session": return sessionID(value).map { AgentTrailLink.jumpSession($0) }
            default: return nil
            }
        default:
            return nil
        }
    }

    /// The live session this link opens: the most urgent of those it allows, in
    /// `LiveSessionRanking` order. Nil when none matches, and always for the switcher.
    public func pick(from sessions: [LiveAgentSession]) -> LiveAgentSession? {
        let allowed: [LiveAgentSession]
        switch self {
        case .switcher:
            return nil
        case .jumpMostUrgent:
            allowed = sessions
        case .jumpProject(let project):
            let wanted = Self.isPath(project) ? canonicalPath(project) : project
            allowed = sessions.filter { session in Self.session(session, isIn: wanted) }
        case .jumpSession(let id):
            allowed = sessions.filter { session in session.sessionID == id || session.details.desktopSessionID == id }
        }
        return LiveSessionRanking.ordered(allowed).first
    }

    // MARK: Values

    /// Trimmed, 1–1024 UTF-8 bytes, no control or bidi characters. A path
    /// starts with / or ~; a name has no slash.
    static func project(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxProjectLength,
              !trimmed.unicodeScalars.contains(where: isDisallowed) else { return nil }
        if isPath(trimmed) { return trimmed }
        return trimmed.contains("/") ? nil : trimmed
    }

    /// ASCII letters, digits, `_`, `-` and `.`, up to 128 characters: UUIDs,
    /// Claude Desktop's `local_` ids and thread ids all fit.
    static func sessionID(_ value: String) -> String? {
        let bytes = Array(value.utf8)
        guard (1...maxSessionLength).contains(bytes.count), bytes.allSatisfy(isSessionByte) else { return nil }
        return value
    }

    // MARK: Matching

    /// A path, already canonical, matches the project folder or the session's
    /// own worktree, symlinks resolved on both sides; a name matches the
    /// project folder's name, ignoring case.
    static func session(_ session: LiveAgentSession, isIn project: String) -> Bool {
        if isPath(project) {
            return canonicalPath(session.projectPath) == project || canonicalPath(session.workspacePath) == project
        }
        let name = URL(fileURLWithPath: session.projectPath).lastPathComponent
        return name.caseInsensitiveCompare(project) == .orderedSame
    }

    private static func isPath(_ value: String) -> Bool {
        value.hasPrefix("/") || value.hasPrefix("~")
    }

    private static func isDisallowed(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.generalCategory == .control { return true }
        // Bidi embeddings, overrides and isolates, and the directional marks.
        switch scalar.value {
        case 0x200E, 0x200F, 0x061C, 0x202A...0x202E, 0x2066...0x2069: return true
        default: return false
        }
    }

    private static func isSessionByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
    }
}
