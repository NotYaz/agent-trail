import Darwin
import Foundation

/// Live status for Copilot CLI sessions (also the Copilot app and VS Code's
/// Copilot CLI sessions, which share the runtime). A process that has a
/// session open holds `session-state/<id>/inuse.<pid>.lock`. Locks survive
/// crashes and PIDs are reused, so a lock counts only while its PID is alive
/// and that process started no later than the lock was created.
///
/// State comes only from events persisted after the lock was created:
/// an unanswered `permission.requested`, or an open `ask_user` or
/// `exit_plan_mode` call, is Needs input; an open turn or tool call is Working;
/// `session.shutdown` ends the session; otherwise it is Idle. Copilot's own
/// idle and input events are never written to disk, so nothing is inferred
/// from them, from file times or from CPU use. Copilot Chat in VS Code has no
/// live reader. Nothing is written to the Copilot home.
public final class CopilotLiveActivityProvider {
    private let processStartTimes: (Set<Int32>) -> [Int32: UInt64]
    private let terminalHints: (Int32) -> ProcessIdentity.TerminalHints?
    private let files = FileManager.default
    private var readers: [String: CopilotLiveTail] = [:]
    /// Terminal bundle id (or a settled nil) per PID and start time.
    private var terminalHosts: [String: String?] = [:]
    private var failedHostReads: [String: Int] = [:]

    /// Locks may be created up to this long after their process started being
    /// checked, and a little before the process's recorded start (clock rounding).
    static let lockSlack: TimeInterval = 2

    public init(processStartTimes: ((Set<Int32>) -> [Int32: UInt64])? = nil,
                terminalHints: ((Int32) -> ProcessIdentity.TerminalHints?)? = nil) {
        self.processStartTimes = processStartTimes ?? GrokLiveActivityProvider.readProcessStartTimes
        self.terminalHints = terminalHints ?? { ProcessIdentity.readTerminalHints(pid: $0) }
    }

    private struct Candidate {
        let source: AgentSource
        let sessionID: String
        let folder: URL
        let pid: Int32
        let lockCreated: Date
        let workspace: String
        var key: String { "\(source.id)\u{0}\(sessionID)\u{0}\(pid)\u{0}\(lockCreated.timeIntervalSince1970)" }
    }

    public func scan(sources: [AgentSource], now: Date = Date()) -> LiveSnapshot {
        var candidates: [Candidate] = []
        var notices: [String] = []
        for source in sources where source.assistant == .copilot {
            let home = URL(fileURLWithPath: canonicalPath(source.configDirectory), isDirectory: true)
            let root = home.appendingPathComponent("session-state", isDirectory: true)
            guard let sessions = try? files.contentsOfDirectory(atPath: root.path) else { continue }
            for id in sessions where CopilotActivityProvider.isSessionUUID(id) {
                let folder = root.appendingPathComponent(id, isDirectory: true)
                guard let names = try? files.contentsOfDirectory(atPath: folder.path) else { continue }
                for name in names {
                    guard let pid = Self.lockPID(name),
                          let stat = FileStat.of(folder.appendingPathComponent(name).path), stat.kind == .regular else { continue }
                    guard let raw = CopilotActivityProvider.yamlScalar("cwd", in: folder.appendingPathComponent("workspace.yaml")),
                          let workspace = CheckoutPath.absolute(raw) else {
                        notices.append("\(source.name): a running Copilot CLI session names no folder; it is not shown.")
                        continue
                    }
                    candidates.append(Candidate(source: source, sessionID: id, folder: folder, pid: pid,
                                                lockCreated: stat.created, workspace: workspace))
                }
            }
        }
        let starts = processStartTimes(Set(candidates.map(\.pid)))
        var sessions: [LiveAgentSession] = []
        var retained: Set<String> = []
        var retainedHosts: Set<String> = []
        var seen: Set<String> = []
        for candidate in candidates.sorted(by: { $0.lockCreated > $1.lockCreated }) {
            guard let start = starts[candidate.pid] else { continue }
            let started = Date(timeIntervalSince1970: Double(start) / 1_000_000)
            // A process that began after the lock was made reused a dead holder's PID.
            guard started <= candidate.lockCreated.addingTimeInterval(Self.lockSlack) else { continue }
            // One process may hold a session twice; report it once.
            guard seen.insert("\(candidate.source.id)\u{0}\(candidate.sessionID)\u{0}\(candidate.pid)").inserted else { continue }
            retained.insert(candidate.key)
            let hostKey = "\(candidate.pid)\u{0}\(start)"
            retainedHosts.insert(hostKey)
            let reader = readers[candidate.key] ?? CopilotLiveTail(opened: candidate.lockCreated.addingTimeInterval(-Self.lockSlack))
            readers[candidate.key] = reader
            do {
                try reader.read(candidate.folder.appendingPathComponent("events.jsonl"), now: now)
            } catch {
                reader.clearStatus()
            }
            if reader.hadUnreadableRecord {
                notices.append("\(candidate.source.name): an unreadable Copilot CLI event leaves a session's state unknown until its next event.")
            }
            guard !reader.ended else { continue }
            let details = LiveSessionDetails(hostBundleID: terminalHost(pid: candidate.pid, key: hostKey))
            sessions.append(LiveAgentSession(sourceID: candidate.source.id, projectPath: candidate.workspace,
                workspacePath: candidate.workspace, sessionID: candidate.sessionID, status: reader.status,
                updatedAt: reader.updatedAt ?? candidate.lockCreated, pid: candidate.pid, details: details))
        }
        readers = readers.filter { retained.contains($0.key) }
        terminalHosts = terminalHosts.filter { retainedHosts.contains($0.key) }
        failedHostReads = failedHostReads.filter { retainedHosts.contains($0.key) }
        // Verify presence again after reading files.
        let finalStarts = processStartTimes(Set(sessions.map(\.pid)))
        sessions.removeAll { finalStarts[$0.pid] != starts[$0.pid] }
        sessions.sort {
            let left = LiveSessionRanking.order($0.status), right = LiveSessionRanking.order($1.status)
            if left != right { return left < right }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        return LiveSnapshot(sessions: sessions, notices: Array(Set(notices)).sorted(), scannedAt: now)
    }

    /// `inuse.<pid>.lock`.
    static func lockPID(_ name: String) -> Int32? {
        guard name.hasPrefix("inuse."), name.hasSuffix(".lock") else { return nil }
        let digits = name.dropFirst(6).dropLast(5)
        guard !digits.isEmpty, digits.count <= 10, digits.allSatisfy(\.isASCII), let pid = Int32(digits), pid > 0 else { return nil }
        return pid
    }

    /// Read once per process, and twice at most when a read fails.
    private func terminalHost(pid: Int32, key: String) -> String? {
        if let known = terminalHosts[key] { return known }
        guard let hints = terminalHints(pid) else {
            let failures = (failedHostReads[key] ?? 0) + 1
            if failures >= 2 {
                failedHostReads[key] = nil
                terminalHosts.updateValue(nil, forKey: key)
            } else {
                failedHostReads[key] = failures
            }
            return nil
        }
        failedHostReads[key] = nil
        let host = hints.terminalBundleIdentifier
        terminalHosts.updateValue(host, forKey: key)
        return host
    }
}

/// A bounded, in-memory reader of one session's event journal: the last 16 MiB
/// on first sight or after a rewrite, then only new bytes. Records over 8 MiB
/// leave the state unknown. Only ids and the derived state stay in memory.
final class CopilotLiveTail {
    private let opened: Date
    private var identity = ""
    private var offset: UInt64 = 0
    private var size: UInt64 = 0
    private var modified: Date?
    /// The bytes just before `offset`, to notice a rewrite that kept the inode.
    private var checkpoint = Data()
    private var partial = Data()
    private var dropping = false
    private var turnOpen = false
    private var openTools: [String: String] = [:]
    private var pendingPermissions: Set<String> = []
    private(set) var ended = false
    private(set) var updatedAt: Date?
    private(set) var hadUnreadableRecord = false
    private var unknown = false
    private let window: UInt64 = 16 * 1_048_576
    private let maximumLine = 8 * 1_048_576

    /// Tools that wait for the user's answer.
    static let inputTools: Set<String> = ["ask_user", "exit_plan_mode"]

    init(opened: Date) { self.opened = opened }

    var status: LiveStatus {
        if unknown { return .unknown }
        if !pendingPermissions.isEmpty || openTools.values.contains(where: Self.inputTools.contains) { return .waiting }
        if turnOpen || !openTools.isEmpty { return .working }
        return .idle
    }

    func clearStatus() {
        resetState()
        identity = ""
        unknown = true
    }

    private func resetState() {
        turnOpen = false
        openTools = [:]
        pendingPermissions = []
        ended = false
        updatedAt = nil
        hadUnreadableRecord = false
        unknown = false
        partial.removeAll(keepingCapacity: false)
    }

    func read(_ url: URL, now: Date) throws {
        guard let stat = FileStat.of(url.path), stat.kind == .regular else {
            // A session opened a moment ago may not have written an event yet.
            resetState()
            identity = ""
            return
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var reusable = identity == stat.identity && !identity.isEmpty && stat.size >= offset
        if reusable, offset > 0, !checkpoint.isEmpty {
            try handle.seek(toOffset: offset - UInt64(checkpoint.count))
            reusable = try handle.read(upToCount: checkpoint.count) == checkpoint
        }
        if reusable, stat.size == offset, stat.modified == modified { return }
        if !reusable {
            resetState()
            offset = stat.size > window ? stat.size - window : 0
            // A window that starts mid-file begins inside a record.
            dropping = offset > 0
        }
        identity = stat.identity
        try handle.seek(toOffset: offset)
        while true {
            let chunk: Data? = try autoreleasepool { try handle.read(upToCount: 1_048_576) }
            guard let chunk, !chunk.isEmpty else { break }
            var start = chunk.startIndex
            while let newline = chunk[start...].firstIndex(of: 10) {
                let piece = chunk[start..<newline]
                if !dropping {
                    if partial.count + piece.count > maximumLine {
                        unknown = true
                        hadUnreadableRecord = true
                    } else {
                        partial.append(contentsOf: piece)
                        if !partial.isEmpty { autoreleasepool { parse(partial, now: now) } }
                    }
                }
                partial.removeAll(keepingCapacity: true)
                dropping = false
                start = chunk.index(after: newline)
            }
            if !dropping {
                let rest = chunk[start...]
                if partial.count + rest.count > maximumLine {
                    partial.removeAll(keepingCapacity: false)
                    dropping = true
                    unknown = true
                    hadUnreadableRecord = true
                } else {
                    partial.append(contentsOf: rest)
                }
            }
            offset += UInt64(chunk.count)
        }
        // A trailing partial record is reread when it completes.
        offset -= UInt64(partial.count)
        partial.removeAll(keepingCapacity: true)
        size = stat.size
        modified = stat.modified
        let count = min(offset, 128)
        if count > 0 {
            try handle.seek(toOffset: offset - count)
            checkpoint = try handle.read(upToCount: Int(count)) ?? Data()
        } else {
            checkpoint = Data()
        }
    }

    private func parse(_ data: Data, now: Date) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else {
            unknown = true
            hadUnreadableRecord = true
            return
        }
        if object["checkpoint"] as? Bool == true { return }
        guard let date = RecordedDate.any(object["timestamp"]) else { return }
        // Events from before this process opened the session describe an earlier run.
        guard date >= opened, date <= now.addingTimeInterval(5) else { return }
        let data = object["data"] as? [String: Any] ?? [:]
        switch type {
        case "assistant.turn_start":
            turnOpen = true
        case "assistant.turn_end":
            turnOpen = false
        case "tool.execution_start":
            if let id = data["toolCallId"] as? String { openTools[id] = data["toolName"] as? String ?? "" }
            turnOpen = true
        case "tool.execution_complete":
            if let id = data["toolCallId"] as? String { openTools.removeValue(forKey: id) }
        case "permission.requested":
            if let id = data["requestId"] as? String { pendingPermissions.insert(id) }
        case "permission.completed":
            if let id = data["requestId"] as? String { pendingPermissions.remove(id) }
        case "abort":
            turnOpen = false
            openTools = [:]
            pendingPermissions = []
        case "session.shutdown":
            ended = true
        case "session.start", "session.resume":
            ended = false
        case "assistant.message":
            // Only a turn writes assistant messages, so one shows a turn in progress
            // even when its start lies before the window that was read.
            turnOpen = true
        default:
            return
        }
        unknown = false
        updatedAt = max(updatedAt ?? date, date)
    }
}
