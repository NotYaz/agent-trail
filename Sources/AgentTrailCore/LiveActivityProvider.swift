import Darwin
import Foundation

public enum LiveStatus: String, Sendable {
    case waiting
    case working
    case idle
    case unknown
}

/// A pull request an assistant recorded for a session. Readers keep only https
/// links, so opening one never hands a custom scheme to another app.
public struct LivePullRequest: Hashable, Sendable {
    public let number: Int
    public let url: URL

    public init(number: Int, url: URL) {
        self.number = number
        self.url = url
    }
}

/// Extra, best-effort facts about a live session. Every field is optional:
/// assistants record different things, and formats are private.
/// Deliberately not Codable: titles and needs-action text stay in memory.
public struct LiveSessionDetails: Hashable, Sendable {
    /// Conversation title. In memory only.
    public var title: String?
    /// Claude Desktop `local_…` session id: the registry record's hostSessionId,
    /// equal to the Desktop record's sessionId, matching ^local_[A-Za-z0-9-]{1,64}$,
    /// and not archived. Nil when any check fails.
    public var desktopSessionID: String?
    /// Claude's postTurnSummary.needs_action sentence. In memory only.
    public var needsAction: String?
    /// When the current status began, when the assistant records it.
    public var stateSince: Date?
    /// Git branch the assistant recorded for the session.
    public var branch: String?
    /// Recorded pull requests, https links only, in the assistant's order.
    public var pullRequests: [LivePullRequest]
    /// Bundle id of the app that owns the session: com.openai.codex for a Codex
    /// thread owned by the desktop app, or a terminal for Grok. Nil when unknown.
    public var hostBundleID: String?
    /// Codex subagent thread's parent thread id.
    public var parentThreadID: String?

    public init(title: String? = nil, desktopSessionID: String? = nil, needsAction: String? = nil,
                stateSince: Date? = nil, branch: String? = nil, pullRequests: [LivePullRequest] = [],
                hostBundleID: String? = nil, parentThreadID: String? = nil) {
        self.title = title
        self.desktopSessionID = desktopSessionID
        self.needsAction = needsAction
        self.stateSince = stateSince
        self.branch = branch
        self.pullRequests = pullRequests
        self.hostBundleID = hostBundleID
        self.parentThreadID = parentThreadID
    }

    public static let none = LiveSessionDetails()
}

public struct LiveAgentSession: Identifiable, Sendable {
    public var id: String { "\(sourceID):\(sessionID):\(pid)" }
    public let sourceID: String
    public let projectPath: String
    public let workspacePath: String
    public let sessionID: String
    public let status: LiveStatus
    public let updatedAt: Date
    public let pid: Int32
    /// Never part of identity or status: two reports of one process are the
    /// same session whatever their details say.
    public let details: LiveSessionDetails

    public init(sourceID: String, projectPath: String, workspacePath: String, sessionID: String,
                status: LiveStatus, updatedAt: Date, pid: Int32, details: LiveSessionDetails = .none) {
        self.sourceID = sourceID
        self.projectPath = projectPath
        self.workspacePath = workspacePath
        self.sessionID = sessionID
        self.status = status
        self.updatedAt = updatedAt
        self.pid = pid
        self.details = details
    }

    /// The same report under another project identity. Status, report time,
    /// PID and details still come from the live reader.
    public func relocated(projectPath: String, workspacePath: String) -> LiveAgentSession {
        LiveAgentSession(sourceID: sourceID, projectPath: projectPath, workspacePath: workspacePath,
            sessionID: sessionID, status: status, updatedAt: updatedAt, pid: pid, details: details)
    }
}

public struct LiveSnapshot: Sendable {
    public let sessions: [LiveAgentSession]
    public let notices: [String]
    public let scannedAt: Date

    public init(sessions: [LiveAgentSession], notices: [String] = [], scannedAt: Date = Date()) {
        self.sessions = sessions
        self.notices = notices
        self.scannedAt = scannedAt
    }
}

/// Reads Claude's small process-registry records, never transcript/history files.
/// Explicit `waiting` means a request/dialog needs attention; `busy` becomes
/// `working` and `idle` remains `idle`. Idle alone never implies input is needed.
/// Claude
/// writes these flags on state transitions, not on a heartbeat. A record whose
/// procStart matches that PID's current UTC/C-locale launch time retains its last
/// reported state while that process exists. Otherwise the short freshness TTL
/// applies. A reused PID is omitted. Recent project activity, CPU usage and file
/// mtimes never establish a working status; updatedAt exposes the report's age.
public final class LiveActivityProvider {
    public let freshnessTTL: TimeInterval
    private let isProcessAlive: (Int32) -> Bool
    private let processStartTimes: (Set<Int32>) -> [Int32: String]
    private let files = FileManager.default

    public init(freshnessTTL: TimeInterval = 90, isProcessAlive: ((Int32) -> Bool)? = nil,
                processStartTimes: ((Set<Int32>) -> [Int32: String])? = nil) {
        self.freshnessTTL = freshnessTTL.isFinite && freshnessTTL > 0 ? freshnessTTL : 90
        self.isProcessAlive = isProcessAlive ?? { pid in pid > 0 && getpgid(pid) >= 0 }
        self.processStartTimes = processStartTimes ?? Self.readProcessStartTimes
    }

    /// Suitable for a small background poll every 2–3 seconds. No files are written,
    /// no signals are sent, and terminal-only/foreign-profile sessions are omitted.
    public func scan(sources: [AgentSource], now: Date = Date()) -> LiveSnapshot {
        var sessions: [String: LiveAgentSession] = [:]
        var notices: [String] = []
        var candidates: [Candidate] = []
        for source in sources {
            // This process-registry schema belongs to Claude. Other assistants
            // have separate runtime readers in CompositeLiveActivityProvider.
            guard source.assistant == .claude else { continue }
            let desktop = desktopSessions(source: source, notices: &notices)
            guard !desktop.isEmpty else { continue }
            let root = URL(fileURLWithPath: (source.configDirectory as NSString).expandingTildeInPath)
                .appendingPathComponent("sessions", isDirectory: true)
            let urls: [URL]
            do { urls = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) }
            catch {
                notices.append("\(source.name): live session metadata is unavailable.")
                continue
            }
            var unreadable = 0
            var unexpectedWorkspace = 0
            for url in urls where url.pathExtension == "json" {
                autoreleasepool {
                    do {
                        let record = try JSONDecoder().decode(ProcessRecord.self, from: Data(contentsOf: url))
                        guard record.entrypoint == "claude-desktop",
                              record.pidDomain == nil || record.pidDomain == "darwin",
                              let cliID = record.sessionId, let project = desktop[cliID],
                              let rawPID = record.pid, rawPID > 0, rawPID <= Int(Int32.max),
                              url.deletingPathExtension().lastPathComponent == String(rawPID) else { return }
                        let pid = Int32(rawPID)
                        guard isProcessAlive(pid) else { return }
                        guard let cwd = absolutePath(record.cwd),
                              project.checkoutRoots.contains(where: { contains(root: $0, path: cwd) }) else {
                            unexpectedWorkspace += 1
                            return
                        }
                        guard let milliseconds = record.statusUpdatedAt ?? record.updatedAt,
                              milliseconds.isFinite, milliseconds > 0 else {
                            unreadable += 1
                            return
                        }
                        var details = project.details
                        // The registry names its Desktop host; a link is offered only
                        // when that host is the very record this session matched.
                        if let host = record.hostSessionId?.value, host == project.linkableSessionID {
                            details.desktopSessionID = host
                        }
                        let stateSince = record.statusUpdatedAt.flatMap { value in
                            value.isFinite && value > 0 ? Date(timeIntervalSince1970: value / 1000) : nil
                        }
                        candidates.append(Candidate(source: source, projectPath: project.projectPath, workspacePath: cwd,
                            sessionID: cliID, pid: pid, status: record.status, procStart: record.procStart,
                            updatedAt: Date(timeIntervalSince1970: milliseconds / 1000),
                            stateSince: stateSince, details: details))
                    } catch { unreadable += 1 }
                }
            }
            if unreadable > 0 { notices.append("\(source.name): \(unreadable) live status record(s) could not be read.") }
            if unexpectedWorkspace > 0 {
                notices.append("\(source.name): a session outside its known desktop checkout was omitted.")
            }
        }
        // One ps invocation for the entire poll, without reading argv/environment.
        let starts = processStartTimes(Set(candidates.filter { $0.procStart?.isEmpty == false }.map(\.pid)))
        var staleBySource: [String: Int] = [:]
        var reusedBySource: [String: Int] = [:]
        for candidate in candidates {
            var identityVerified = false
            if let recorded = candidate.procStart, !recorded.isEmpty, let current = starts[candidate.pid] {
                guard normalizeStart(recorded) == normalizeStart(current) else {
                    reusedBySource[candidate.source.id, default: 0] += 1
                    continue
                }
                identityVerified = true
            }
            let age = now.timeIntervalSince(candidate.updatedAt)
            // Verified transition-based flags do not expire during long jobs.
            // Future-dated reports and unverified old reports remain unknown.
            let authoritative = age >= -5 && (identityVerified || age <= freshnessTTL)
            let status: LiveStatus
            if authoritative {
                switch candidate.status {
                case "waiting": status = .waiting
                case "busy": status = .working
                case "idle": status = .idle
                default: status = .unknown
                }
            } else {
                status = .unknown
                staleBySource[candidate.source.id, default: 0] += 1
            }
            var details = candidate.details
            // Only a recognized, trusted flag has a known start. An unknown state
            // did not begin at the old report's time.
            details.stateSince = status == .unknown ? nil : candidate.stateSince
            let item = LiveAgentSession(sourceID: candidate.source.id, projectPath: candidate.projectPath,
                workspacePath: candidate.workspacePath, sessionID: candidate.sessionID, status: status,
                updatedAt: candidate.updatedAt, pid: candidate.pid, details: details)
            sessions[item.id] = item
        }
        for source in sources {
            if let count = staleBySource[source.id] {
                notices.append("\(source.name): \(count) live session(s) have an unverified old status report; current work is unknown.")
            }
            if reusedBySource[source.id] != nil {
                notices.append("\(source.name): an old session record referred to a reused PID and was omitted.")
            }
        }
        let ordered = sessions.values.sorted {
            let left = rank($0.status), right = rank($1.status)
            if left != right { return left < right }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        return LiveSnapshot(sessions: ordered, notices: Array(Set(notices)).sorted(), scannedAt: now)
    }

    private struct ProcessRecord: Decodable {
        let pid: Int?
        let sessionId: String?
        let cwd: String?
        let status: String?
        let updatedAt: Double?
        let statusUpdatedAt: Double?
        let entrypoint: String?
        let pidDomain: String?
        let procStart: String?
        let hostSessionId: Lenient<String>?
    }

    private struct Candidate {
        let source: AgentSource
        let projectPath: String
        let workspacePath: String
        let sessionID: String
        let pid: Int32
        let status: String?
        let procStart: String?
        let updatedAt: Date
        let stateSince: Date?
        let details: LiveSessionDetails
    }

    /// A best-effort field: a missing, null or malformed value becomes nil instead
    /// of failing the record, so a private format change never drops a session.
    fileprivate struct Lenient<Value: Decodable>: Decodable {
        let value: Value?

        init(from decoder: Decoder) throws {
            value = try? decoder.singleValueContainer().decode(Value.self)
        }
    }

    /// Claude Desktop's own link handler accepts only this shape
    /// (^local_[A-Za-z0-9-]{1,64}$), so nothing else is offered as a link target.
    static func isDesktopSessionID(_ value: String) -> Bool {
        let prefix = "local_".utf8
        let bytes = value.utf8
        guard bytes.starts(with: prefix) else { return false }
        let suffix = bytes.dropFirst(prefix.count)
        return (1...64).contains(suffix.count) && suffix.allSatisfy { byte in
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "-"): return true
            default: return false
            }
        }
    }

    /// Recorded PR links are opened by the app, so only plain https links to a
    /// host, without credentials, are kept.
    static func pullRequestURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }

    private static func displayText(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func readProcessStartTimes(_ pids: Set<Int32>) -> [Int32: String] {
        guard !pids.isEmpty else { return [:] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", pids.sorted().map(String.init).joined(separator: ","), "-o", "pid=,lstart="]
        // Match Claude's own procStart format without inheriting user credentials.
        process.environment = ["LC_ALL": "C", "TZ": "UTC", "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8) else { return [:] }
            var result: [Int32: String] = [:]
            for line in text.split(separator: "\n") {
                let columns = line.split(whereSeparator: { $0.isWhitespace })
                guard columns.count == 6, let pid = Int32(columns[0]), pids.contains(pid) else { continue }
                result[pid] = columns.dropFirst().joined(separator: " ")
            }
            return result
        } catch { return [:] }
    }

    private func normalizeStart(_ value: String) -> String {
        value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private struct DesktopRecord: Decodable {
        let sessionId: String?
        let cliSessionId: String?
        let priorCliSessionIds: [String]?
        let cwd: String?
        let originCwd: String?
        let worktreePath: String?
        let gitAnchors: [Anchor]?
        /// Only ranks records that claim one CLI id; a malformed value ranks oldest
        /// instead of dropping the session.
        let lastActivityAt: Lenient<Double>?
        // Details for the Jump button. Each one is lenient: none may drop the session.
        let title: Lenient<String>?
        let isArchived: Lenient<Bool>?
        let branch: Lenient<String>?
        let lastAssistantUuid: Lenient<String>?
        let postTurnSummary: Lenient<Summary>?
        let prs: Lenient<[Lenient<PullRequest>]>?
        struct Anchor: Decodable { let gitRoot: String? }

        struct Summary: Decodable {
            let needsAction: Lenient<String>?
            let summarizesUuid: Lenient<String>?
            private enum CodingKeys: String, CodingKey {
                case needsAction = "needs_action"
                case summarizesUuid = "summarizes_uuid"
            }
        }

        struct PullRequest: Decodable {
            let prNumber: Lenient<Int>?
            let url: Lenient<String>?
        }
    }

    private struct DesktopProject {
        let projectPath: String
        let checkoutRoots: [String]
        let activity: Double
        /// The record's own `local_…` id, only when it has the link shape and the
        /// session is not archived (Claude opens its Code home for archived ids).
        let linkableSessionID: String?
        /// Title, needs-action, branch and PRs; the scan adds the link and timing.
        let details: LiveSessionDetails
    }

    private static func desktopDetails(_ record: DesktopRecord) -> (linkableSessionID: String?, details: LiveSessionDetails) {
        // Missing means not archived; a malformed flag cannot prove it.
        let archived = record.isArchived.map { $0.value != false } ?? false
        let linkable = record.sessionId.flatMap { !archived && isDesktopSessionID($0) ? $0 : nil }
        let summary = record.postTurnSummary?.value
        // A summary describes one finished turn. Once a newer assistant message
        // exists, its request is stale and is not shown.
        let summarized = summary?.summarizesUuid?.value
        let latest = record.lastAssistantUuid?.value
        let isCurrent = summarized == nil || latest == nil || summarized == latest
        var pullRequests: [LivePullRequest] = []
        for entry in record.prs?.value ?? [] {
            guard let number = entry.value?.prNumber?.value, number > 0,
                  let link = entry.value?.url?.value, let url = pullRequestURL(link) else { continue }
            let pullRequest = LivePullRequest(number: number, url: url)
            if !pullRequests.contains(pullRequest) { pullRequests.append(pullRequest) }
        }
        let details = LiveSessionDetails(title: displayText(record.title?.value),
            needsAction: isCurrent ? displayText(summary?.needsAction?.value) : nil,
            branch: displayText(record.branch?.value), pullRequests: pullRequests)
        return (linkable, details)
    }

    private func desktopSessions(source: AgentSource, notices: inout [String]) -> [String: DesktopProject] {
        let desktopPath: String
        if let custom = source.userDataDirectory {
            desktopPath = (custom as NSString).expandingTildeInPath
        } else if canonicalPath(source.configDirectory) == canonicalPath(NSHomeDirectory() + "/.claude") {
            desktopPath = NSHomeDirectory() + "/Library/Application Support/Claude"
        } else {
            notices.append("\(source.name): a desktop data folder is required for reliable live status.")
            return [:]
        }
        let root = URL(fileURLWithPath: desktopPath).appendingPathComponent("claude-code-sessions", isDirectory: true)
        var failed = false
        guard let enumerator = files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles], errorHandler: { _, _ in failed = true; return true }) else {
            notices.append("\(source.name): desktop projects could not be matched to live sessions.")
            return [:]
        }
        var result: [String: DesktopProject] = [:]
        for case let url as URL in enumerator where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("local_") {
            autoreleasepool {
                do {
                    let record = try JSONDecoder().decode(DesktopRecord.self, from: Data(contentsOf: url))
                    guard record.sessionId != nil,
                          let projectPath = absolutePath(record.originCwd) ?? absolutePath(record.cwd),
                          let workspace = absolutePath(record.cwd) ?? absolutePath(record.worktreePath) else { return }
                    var roots = [projectPath, workspace]
                    roots += (record.gitAnchors ?? []).compactMap { absolutePath($0.gitRoot) }
                    if let worktree = absolutePath(record.worktreePath) { roots.append(worktree) }
                    let extra = Self.desktopDetails(record)
                    let project = DesktopProject(projectPath: projectPath, checkoutRoots: Array(Set(roots)),
                        activity: record.lastActivityAt?.value ?? 0, linkableSessionID: extra.linkableSessionID,
                        details: extra.details)
                    for id in [record.cliSessionId].compactMap({ $0 }) + (record.priorCliSessionIds ?? []) where !id.isEmpty {
                        if result[id]?.activity ?? -.infinity <= project.activity { result[id] = project }
                    }
                } catch { failed = true }
            }
        }
        if failed { notices.append("\(source.name): some desktop project metadata could not be read for live status.") }
        return result
    }

    private func absolutePath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        return expanded.hasPrefix("/") ? canonicalPath(expanded) : nil
    }

    private func contains(root: String, path: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private func rank(_ status: LiveStatus) -> Int {
        switch status {
        case .waiting: return 0
        case .working: return 1
        case .idle: return 2
        case .unknown: return 3
        }
    }
}
