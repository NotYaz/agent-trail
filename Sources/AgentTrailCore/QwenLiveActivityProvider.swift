import Darwin
import Foundation

/// Live presence for Qwen Code sessions. Each running session publishes
/// `sessions/<pid>.json` (or `<pid>-<8 hex>.json` when one process hosts
/// several) under the Qwen home, Qwen's documented cross-session registry
/// (schema 1), and removes it on exit. A crash leaves the record behind and
/// PIDs are reused, while on macOS the record carries no process start token,
/// so a record counts only while its PID is alive and that process started no
/// later than the record's `startedAt`.
///
/// The registry records no state, and Qwen writes a tool call to disk only
/// once it completed, so neither an approval waiting for you nor a turn in
/// progress can be read. Every session is reported as Unknown: running, state
/// not reported. Nothing is inferred from history, file times or CPU use.
/// Records of `kind: external` (other programs joining the registry) are
/// skipped. A record's `ipcToken` and `ipcPath` are never kept, logged or
/// used, and nothing is written to the Qwen home.
public final class QwenLiveActivityProvider {
    private let processStartTimes: (Set<Int32>) -> [Int32: UInt64]
    private let terminalHints: (Int32) -> ProcessIdentity.TerminalHints?
    private let files = FileManager.default
    /// Terminal bundle id (or a settled nil) per PID and start time.
    private var terminalHosts: [String: String?] = [:]
    private var failedHostReads: [String: Int] = [:]

    /// A record may be written up to this long before its process's recorded
    /// start (clock rounding).
    static let registrationSlack: TimeInterval = 2

    /// Kinds that are Qwen Code sessions: `tui` (a terminal; also an absent
    /// kind from older builds), `headless` (`qwen -p`, ACP) and `serve`.
    static let sessionKinds: Set<String> = ["tui", "headless", "serve"]

    public init(processStartTimes: ((Set<Int32>) -> [Int32: UInt64])? = nil,
                terminalHints: ((Int32) -> ProcessIdentity.TerminalHints?)? = nil) {
        self.processStartTimes = processStartTimes ?? GrokLiveActivityProvider.readProcessStartTimes
        self.terminalHints = terminalHints ?? { ProcessIdentity.readTerminalHints(pid: $0) }
    }

    /// The fields of one registry record this reader uses.
    struct Record: Equatable {
        let pid: Int32
        let sessionID: String
        let workspace: String
        let startedAt: Date
        let kind: String
    }

    enum Parsed: Equatable {
        case record(Record)
        /// A well-formed record of another kind, or of a newer schema.
        case skipped
        case unreadable
    }

    private struct Candidate {
        let source: AgentSource
        let record: Record
    }

    public func scan(sources: [AgentSource], now: Date = Date()) -> LiveSnapshot {
        var candidates: [Candidate] = []
        var notices: [String] = []
        for source in sources where source.assistant == .qwen {
            let home = URL(fileURLWithPath: (source.configDirectory as NSString).expandingTildeInPath, isDirectory: true)
            let folder = home.appendingPathComponent("sessions", isDirectory: true)
            guard let names = try? files.contentsOfDirectory(atPath: folder.path) else { continue }
            for name in names.sorted() {
                guard let pid = Self.recordPID(name) else { continue }
                let url = folder.appendingPathComponent(name)
                guard let stat = FileStat.of(url.path), stat.kind == .regular else { continue }
                guard stat.size <= 65_536, let data = Self.boundedData(url, maximum: 65_536) else {
                    notices.append("\(source.name): a Qwen Code session registry record could not be read; that session is not shown.")
                    continue
                }
                switch Self.parse(data, pid: pid) {
                case .record(let record):
                    guard record.startedAt <= now.addingTimeInterval(5) else { continue }
                    candidates.append(Candidate(source: source, record: record))
                case .skipped:
                    continue
                case .unreadable:
                    notices.append("\(source.name): a Qwen Code session registry record could not be read; that session is not shown.")
                }
            }
        }
        let starts = processStartTimes(Set(candidates.map { $0.record.pid }))
        var sessions: [LiveAgentSession] = []
        var retainedHosts: Set<String> = []
        var seen: Set<String> = []
        for candidate in candidates.sorted(by: { $0.record.startedAt > $1.record.startedAt }) {
            let record = candidate.record
            // Missing includes dead and zombie processes.
            guard let start = starts[record.pid] else { continue }
            let started = Date(timeIntervalSince1970: Double(start) / 1_000_000)
            // A process that began after the record was written reused a dead session's PID.
            guard started <= record.startedAt.addingTimeInterval(Self.registrationSlack) else { continue }
            guard seen.insert("\(candidate.source.id)\u{0}\(record.sessionID)\u{0}\(record.pid)").inserted else { continue }
            let hostKey = "\(record.pid)\u{0}\(start)"
            retainedHosts.insert(hostKey)
            let host = record.kind == "tui" ? terminalHost(pid: record.pid, key: hostKey) : nil
            sessions.append(LiveAgentSession(sourceID: candidate.source.id, projectPath: record.workspace,
                workspacePath: record.workspace, sessionID: record.sessionID, status: .unknown,
                updatedAt: record.startedAt, pid: record.pid, details: LiveSessionDetails(hostBundleID: host)))
        }
        terminalHosts = terminalHosts.filter { retainedHosts.contains($0.key) }
        failedHostReads = failedHostReads.filter { retainedHosts.contains($0.key) }
        // Verify presence again after reading files.
        let finalStarts = processStartTimes(Set(sessions.map(\.pid)))
        sessions.removeAll { finalStarts[$0.pid] != starts[$0.pid] }
        sessions.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        return LiveSnapshot(sessions: sessions, notices: Array(Set(notices)).sorted(), scannedAt: now)
    }

    /// `<pid>.json` or `<pid>-<8 lowercase hex>.json`, the PID in canonical
    /// decimal form (no leading zero).
    static func recordPID(_ name: String) -> Int32? {
        guard name.hasSuffix(".json") else { return nil }
        var digits = name.dropLast(5)
        if let dash = digits.firstIndex(of: "-") {
            let suffix = digits[digits.index(after: dash)...]
            guard suffix.count == 8, suffix.allSatisfy({ "0123456789abcdef".contains($0) }) else {
                return nil
            }
            digits = digits[..<dash]
        }
        guard !digits.isEmpty, digits.count <= 10, digits.first != "0",
              digits.allSatisfy({ $0.isASCII && $0.isNumber }), let pid = Int32(digits), pid > 0 else { return nil }
        return pid
    }

    /// One registry record. The PID must match the file name's.
    static func parse(_ data: Data, pid: Int32) -> Parsed {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = integer(object["schemaVersion"]) else { return .unreadable }
        // A newer schema is skipped, never guessed at.
        guard version == 1 else { return version > 1 ? .skipped : .unreadable }
        let kind = object["kind"] as? String ?? "tui"
        guard sessionKinds.contains(kind) else { return .skipped }
        guard let recorded = integer(object["pid"]), recorded == Int64(pid),
              let sessionID = object["sessionId"] as? String, QwenActivityProvider.isSafeID(sessionID),
              let cwd = object["cwd"] as? String, cwd.hasPrefix("/"),
              let workspace = ProjectLocationRegistry.lexicalPath(cwd),
              let milliseconds = integer(object["startedAt"]), milliseconds > 0 else { return .unreadable }
        let startedAt = Date(timeIntervalSince1970: Double(milliseconds) / 1000)
        return .record(Record(pid: pid, sessionID: sessionID, workspace: workspace, startedAt: startedAt, kind: kind))
    }

    /// A JSON integer. `as? Int` would also accept `true` and `false`.
    static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double == double.rounded(), abs(double) < 9_000_000_000_000_000 else { return nil }
        return Int64(double)
    }

    private static func boundedData(_ url: URL, maximum: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximum + 1), data.count <= maximum else { return nil }
        return data
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
