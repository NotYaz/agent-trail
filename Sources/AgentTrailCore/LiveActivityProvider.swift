import Darwin
import Foundation

public enum LiveStatus: String, Sendable {
    case waiting
    case working
    case idle
    case unknown
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

    public init(sourceID: String, projectPath: String, workspacePath: String, sessionID: String,
                status: LiveStatus, updatedAt: Date, pid: Int32) {
        self.sourceID = sourceID
        self.projectPath = projectPath
        self.workspacePath = workspacePath
        self.sessionID = sessionID
        self.status = status
        self.updatedAt = updatedAt
        self.pid = pid
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
                        candidates.append(Candidate(source: source, projectPath: project.projectPath, workspacePath: cwd,
                            sessionID: cliID, pid: pid, status: record.status, procStart: record.procStart,
                            updatedAt: Date(timeIntervalSince1970: milliseconds / 1000)))
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
            let item = LiveAgentSession(sourceID: candidate.source.id, projectPath: candidate.projectPath,
                workspacePath: candidate.workspacePath, sessionID: candidate.sessionID, status: status,
                updatedAt: candidate.updatedAt, pid: candidate.pid)
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
        let lastActivityAt: Double?
        struct Anchor: Decodable { let gitRoot: String? }
    }

    private struct DesktopProject {
        let projectPath: String
        let checkoutRoots: [String]
        let activity: Double
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
                    let project = DesktopProject(projectPath: projectPath, checkoutRoots: Array(Set(roots)),
                        activity: record.lastActivityAt ?? 0)
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
