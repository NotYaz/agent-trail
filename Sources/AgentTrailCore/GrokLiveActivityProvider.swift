import Darwin
import Foundation

/// Grok's active-session registry proves presence, not work. Only lifecycle events
/// written after this particular session was opened establish a live state. The
/// registry's microsecond PID birth time must match the current native process.
/// Nothing is written to Grok's home and no process signals or commands are used.
/// The hosting terminal comes from two inherited environment hints, read at most
/// twice per verified process and trusted only when they agree.
public final class GrokLiveActivityProvider {
    private let processStartTimes: (Set<Int32>) -> [Int32: UInt64]
    private let terminalHints: (Int32) -> ProcessIdentity.TerminalHints?
    private let files = FileManager.default
    private var readers: [String: GrokLiveTail] = [:]
    /// Terminal bundle id (or a settled nil) per PID and PID birth time.
    private var terminalHosts: [String: String?] = [:]
    /// Failed hint reads per PID and PID birth time, until they settle.
    private var failedHostReads: [String: Int] = [:]

    /// `terminalHints` receives only PIDs whose birth time matched the registry.
    public init(processStartTimes: ((Set<Int32>) -> [Int32: UInt64])? = nil,
                terminalHints: ((Int32) -> ProcessIdentity.TerminalHints?)? = nil) {
        self.processStartTimes = processStartTimes ?? Self.readProcessStartTimes
        self.terminalHints = terminalHints ?? { ProcessIdentity.readTerminalHints(pid: $0) }
    }

    public func scan(sources: [AgentSource], now: Date = Date()) -> LiveSnapshot {
        var candidates: [Candidate] = []
        var notices: [String] = []
        for source in sources where source.assistant == .grok {
            let home = URL(fileURLWithPath: canonicalPath(source.configDirectory), isDirectory: true)
            let registry = home.appendingPathComponent("active_sessions.json")
            guard files.fileExists(atPath: registry.path) else { continue }
            guard CheckoutPath.contains(root: home.path, path: canonicalPath(registry.path)),
                  let data = boundedData(registry, maximum: 1_048_576),
                  let records = try? JSONDecoder().decode([RegistryRecord].self, from: data) else {
                notices.append("\(source.name): the active-session registry could not be read; live status is unavailable.")
                continue
            }
            var seen: [String: Candidate] = [:]
            var conflicts: Set<String> = []
            for record in records {
                guard record.pid > 0, record.pid <= Int(Int32.max), record.pid_start > 0,
                      safeComponent(record.session_id), record.cwd.hasPrefix("/"),
                      let workspace = CheckoutPath.absolute(record.cwd),
                      let opened = RecordedDate.parse(record.opened_at), opened <= now.addingTimeInterval(5),
                      opened.timeIntervalSince1970 + 1 >= Double(record.pid_start) / 1_000_000 else { continue }
                let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
                guard let encoded = record.cwd.addingPercentEncoding(withAllowedCharacters: allowed) else { continue }
                let session = home.appendingPathComponent("sessions", isDirectory: true)
                    .appendingPathComponent(encoded, isDirectory: true)
                    .appendingPathComponent(record.session_id, isDirectory: true)
                let summaryURL = session.appendingPathComponent("summary.json")
                guard CheckoutPath.contains(root: home.path, path: canonicalPath(session.path)),
                      CheckoutPath.contains(root: home.path, path: canonicalPath(summaryURL.path)),
                      let summaryData = boundedData(summaryURL, maximum: 1_048_576),
                      let summary = try? JSONDecoder().decode(Summary.self, from: summaryData),
                      summary.info.id == record.session_id,
                      CheckoutPath.absolute(summary.info.cwd) == workspace,
                      summary.grok_home == nil || canonicalPath(summary.grok_home!) == home.path else { continue }
                let key = source.id + "\0" + record.session_id + "\0" + String(record.pid)
                let candidate = Candidate(source: source, record: record, workspace: workspace,
                    opened: opened, directory: session, key: key)
                if let previous = seen[key], previous.record.pid_start != record.pid_start
                    || previous.workspace != workspace || previous.opened != opened {
                    conflicts.insert(key)
                } else { seen[key] = candidate }
            }
            candidates += seen.filter { !conflicts.contains($0.key) }.map(\.value)
            if !conflicts.isEmpty {
                notices.append("\(source.name): conflicting active-session records were omitted.")
            }
        }
        let starts = processStartTimes(Set(candidates.map { Int32($0.record.pid) }))
        var sessions: [LiveAgentSession] = []
        var retained: Set<String> = []
        var retainedHosts: Set<String> = []
        for candidate in candidates {
            let pid = Int32(candidate.record.pid)
            // Missing identity includes dead processes. A matching PID alone is
            // insufficient because registries can survive process termination.
            guard starts[pid] == candidate.record.pid_start else { continue }
            let hostKey = String(pid) + "\0" + String(candidate.record.pid_start)
            retainedHosts.insert(hostKey)
            let details = LiveSessionDetails(hostBundleID: terminalHost(pid: pid, key: hostKey))
            let key = candidate.key + "\0" + String(candidate.record.pid_start) + "\0" + candidate.record.opened_at
            retained.insert(key)
            let reader = readers[key] ?? GrokLiveTail(opened: candidate.opened)
            readers[key] = reader
            do {
                let eventURL = candidate.directory.appendingPathComponent("events.jsonl")
                guard CheckoutPath.contains(root: canonicalPath(candidate.source.configDirectory), path: canonicalPath(eventURL.path)) else {
                    reader.clearStatus()
                    notices.append("\(candidate.source.name): a Grok lifecycle stream outside its profile was omitted.")
                    sessions.append(LiveAgentSession(sourceID: candidate.source.id, projectPath: candidate.workspace,
                        workspacePath: candidate.workspace, sessionID: candidate.record.session_id,
                        status: .unknown, updatedAt: candidate.opened, pid: pid, details: details))
                    continue
                }
                try reader.read(eventURL,
                    sessionID: candidate.record.session_id, now: now)
                if reader.hadUnreadableRecord {
                    notices.append("\(candidate.source.name): an incomplete Grok lifecycle record leaves its state unknown until the next report.")
                }
            } catch {
                reader.clearStatus()
                // A freshly opened session may not have emitted its first turn.
                if files.fileExists(atPath: candidate.directory.appendingPathComponent("events.jsonl").path) {
                    notices.append("\(candidate.source.name): a Grok lifecycle stream could not be read.")
                }
            }
            sessions.append(LiveAgentSession(sourceID: candidate.source.id, projectPath: candidate.workspace,
                workspacePath: candidate.workspace, sessionID: candidate.record.session_id,
                status: reader.status, updatedAt: reader.updatedAt ?? candidate.opened, pid: pid, details: details))
        }
        readers = readers.filter { retained.contains($0.key) }
        terminalHosts = terminalHosts.filter { retainedHosts.contains($0.key) }
        failedHostReads = failedHostReads.filter { retainedHosts.contains($0.key) }
        // Verify presence again after reading files, without inspecting arguments.
        let finalStarts = processStartTimes(Set(sessions.map(\.pid)))
        sessions.removeAll { finalStarts[$0.pid] != starts[$0.pid] }
        sessions.sort {
            let left = rank($0.status), right = rank($1.status)
            if left != right { return left < right }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        return LiveSnapshot(sessions: sessions, notices: Array(Set(notices)).sorted(), scannedAt: now)
    }

    /// A process's launch environment does not change, so one successful read
    /// settles it for that process. An unreadable record is tried once more next
    /// poll, in case the read raced the process; a second failure settles it as
    /// unknown, so a record that never parses is not read again every poll.
    /// The final birth-time check below drops the session if the PID was reused.
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

    private struct RegistryRecord: Decodable {
        let session_id: String
        let pid: Int
        let pid_start: UInt64
        let cwd: String
        let opened_at: String
    }

    private struct Summary: Decodable {
        let info: Info
        let grok_home: String?
        struct Info: Decodable { let id: String; let cwd: String }
    }

    private struct Candidate {
        let source: AgentSource
        let record: RegistryRecord
        let workspace: String
        let opened: Date
        let directory: URL
        let key: String
    }

    private func boundedData(_ url: URL, maximum: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximum + 1), data.count <= maximum else { return nil }
        return data
    }

    private func safeComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".." && !value.contains("/")
            && !value.contains("\\") && !value.contains("\0")
    }

    private func rank(_ status: LiveStatus) -> Int {
        switch status { case .waiting: return 0; case .working: return 1; case .idle: return 2; case .unknown: return 3 }
    }

    private static func readProcessStartTimes(_ pids: Set<Int32>) -> [Int32: UInt64] {
        var result: [Int32: UInt64] = [:]
        for pid in pids where pid > 0 {
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_pid == UInt32(pid), info.pbi_status != SZOMB,
                  info.pbi_start_tvusec < 1_000_000,
                  info.pbi_start_tvsec <= UInt64.max / 1_000_000 else { continue }
            result[pid] = info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
        }
        return result
    }
}

/// A volatile, bounded reader: at most 1 MiB per changed session per poll and
/// 64 KiB per record. Only the derived state/date and a short partial line remain
/// in memory. No prompt, tool input, output, or event cache is persisted.
private final class GrokLiveTail {
    private let opened: Date
    private var identity = ""
    private var offset: UInt64 = 0
    private var modified: Date?
    private var checkpoint = Data()
    private var partial = Data()
    private var dropping = false
    private var pendingPermission: PermissionIdentity?
    private(set) var status: LiveStatus = .unknown
    private(set) var updatedAt: Date?
    private(set) var hadUnreadableRecord = false
    private let maximumBytes = 1_048_576
    private let maximumLine = 65_536

    init(opened: Date) { self.opened = opened }

    func clearStatus() {
        status = .unknown
        updatedAt = nil
        identity = ""
        pendingPermission = nil
        partial.removeAll(keepingCapacity: false)
    }

    func read(_ url: URL, sessionID: String, now: Date) throws {
        let metadata = try FileStat.required(url)
        let size = metadata.size
        let date: Date? = metadata.modified
        let currentIdentity = metadata.identity
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var reusable = identity == currentIdentity && !identity.isEmpty && size >= offset
        if reusable, offset > 0 {
            try handle.seek(toOffset: offset - UInt64(checkpoint.count))
            reusable = try handle.read(upToCount: checkpoint.count) == checkpoint
        }
        if reusable, size == offset, date == modified { return }
        if reusable, size == offset, date != modified { reusable = false }
        if !reusable || size - offset > UInt64(maximumBytes) {
            status = .unknown
            updatedAt = nil
            hadUnreadableRecord = false
            partial.removeAll(keepingCapacity: false)
            pendingPermission = nil
            offset = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
            // A bounded window may begin in the middle of a record.
            dropping = offset > 0
        }
        identity = currentIdentity
        try handle.seek(toOffset: offset)
        guard let bytes = try handle.read(upToCount: maximumBytes), !bytes.isEmpty else {
            offset = size
            modified = date
            checkpoint = Data()
            return
        }
        for byte in bytes {
            if byte == 10 {
                if !dropping, !partial.isEmpty {
                    autoreleasepool { parse(partial, sessionID: sessionID, now: now) }
                }
                partial.removeAll(keepingCapacity: true)
                dropping = false
            } else if !dropping {
                if partial.count < maximumLine { partial.append(byte) }
                else {
                    partial.removeAll(keepingCapacity: false)
                    dropping = true
                    status = .unknown
                    hadUnreadableRecord = true
                }
            }
        }
        if !partial.isEmpty || dropping {
            status = .unknown
            hadUnreadableRecord = true
        }
        offset += UInt64(bytes.count)
        modified = date
        let count = min(offset, 128)
        try handle.seek(toOffset: offset - count)
        checkpoint = try handle.read(upToCount: Int(count)) ?? Data()
    }

    private func parse(_ data: Data, sessionID: String, now: Date) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            status = .unknown
            hadUnreadableRecord = true
            return
        }
        guard let type = object["type"] as? String else { return }
        if let reportedSession = object["session_id"], reportedSession as? String != sessionID { return }
        let next: LiveStatus
        switch type {
        case "turn_started":
            guard object["session_id"] as? String == sessionID else { return }
            next = .working
        case "turn_ended": next = .idle // Includes completed, failed and cancelled turns.
        case "permission_requested": next = .waiting
        case "permission_resolved":
            if let pendingPermission, !pendingPermission.matches(PermissionIdentity(object)) { return }
            // A delayed permission callback cannot resurrect an ended turn.
            guard status != .idle else { return }
            next = .working
        case "phase_changed":
            switch object["phase"] as? String {
            case "permission_prompt": next = .waiting
            case "waiting_for_model", "streaming_reasoning", "streaming_text", "tool_execution": next = .working
            default: next = .unknown
            }
        default: return
        }
        guard let date = RecordedDate.any(object["ts"]) else {
            status = .unknown
            hadUnreadableRecord = true
            return
        }
        // Registry records outlive a resumed session's previous turns. Those
        // previous runtime events cannot describe this new process's state.
        guard date >= opened else { return }
        guard date <= now.addingTimeInterval(5) else {
            status = .unknown
            // Do not advance the ordering watermark with a corrupt future date:
            // the next valid report must be able to restore an authoritative state.
            hadUnreadableRecord = true
            return
        }
        if let last = updatedAt, date < last {
            status = .unknown
            hadUnreadableRecord = true
            return
        }
        status = next
        updatedAt = date
        hadUnreadableRecord = false
        if type == "permission_requested" {
            pendingPermission = PermissionIdentity(object)
        } else if type != "phase_changed" || next != .waiting {
            pendingPermission = nil
        }
    }

    private struct PermissionIdentity {
        let id: String?
        let tool: String?

        init(_ object: [String: Any]) {
            let keys = ["tool_call_id", "toolCallId", "request_id", "requestId"]
            id = keys.compactMap { object[$0] as? String }.first { !$0.isEmpty }
            tool = (object["tool_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        func matches(_ other: PermissionIdentity) -> Bool {
            if let id, let otherID = other.id, id != otherID { return false }
            if let tool, let otherTool = other.tool, tool != otherTool { return false }
            if id != nil && other.id != nil || tool != nil && other.tool != nil { return true }
            // The installed format always carries a tool name. When an unknown
            // format omits all identifiers, an explicit phase can still resolve it.
            return id == nil && tool == nil && other.id == nil && other.tool == nil
        }
    }
}
