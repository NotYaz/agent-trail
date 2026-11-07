import Foundation

/// Live status for OpenCode 2, whose sessions all run inside one shared
/// background service, whatever client (terminal, desktop app, browser) shows
/// them. The service registers itself in `~/.local/state/opencode/service.json`
/// as `{id, version, url, pid, password}`; only the PID is read, and the file
/// is never kept. A registration outlives a crash and PIDs are reused, so it
/// counts only while that process is alive and started no later than the
/// registration was written.
///
/// With a verified service, the profile's `opencode.db` says which sessions are
/// executing: `time_busy` past `time_idle` (OpenCode 2.2.2 and later), else an
/// unreleased execution claim (`time_suspended`), set since the service
/// started, so a turn a dead process left behind is not shown. Such a session
/// is Working; it Needs input while its current step's `question` call is
/// running, which waits for the user's answer. Approval prompts live only in
/// the service's memory, so a session waiting for one stays Working. Sessions
/// that are not executing are not listed: nothing on disk says a client has
/// them open. Nothing is inferred from file times or activity, and OpenCode 1.x
/// (no service) has no live status. Only the default data folder is read,
/// because the service registers under the default state folder.
public final class OpenCodeLiveActivityProvider {
    private let processStartTimes: (Set<Int32>) -> [Int32: UInt64]
    private let home: String

    /// The service registers itself just after starting; this allows for clock rounding.
    static let registrationSlack: TimeInterval = 2

    public init(processStartTimes: ((Set<Int32>) -> [Int32: UInt64])? = nil, home: String = NSHomeDirectory()) {
        self.processStartTimes = processStartTimes ?? GrokLiveActivityProvider.readProcessStartTimes
        self.home = home
    }

    private struct Service {
        let pid: Int32
        let start: UInt64
        var started: Date { Date(timeIntervalSince1970: Double(start) / 1_000_000) }
    }

    public func scan(sources: [AgentSource], now: Date = Date()) -> LiveSnapshot {
        var sessions: [LiveAgentSession] = []
        var notices: [String] = []
        var starts: [Int32: UInt64] = [:]
        let folder = canonicalPath("\(home)/.local/share/opencode")
        for source in sources where source.assistant == .opencode {
            guard canonicalPath(source.configDirectory) == folder,
                  let service = verifiedService(source: source, notices: &notices) else { continue }
            let database = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("opencode.db")
            guard let db = ReadOnlySQLite(url: database) else { continue }
            do {
                let since = service.started.addingTimeInterval(-Self.registrationSlack)
                for busy in try Self.busySessions(db, since: since, now: now) {
                    starts[service.pid] = service.start
                    let stateSince = busy.waiting ? (busy.waitingSince ?? busy.busySince) : busy.busySince
                    sessions.append(LiveAgentSession(sourceID: source.id, projectPath: busy.workspace,
                        workspacePath: busy.workspace, sessionID: busy.id, status: busy.waiting ? .waiting : .working,
                        updatedAt: stateSince, pid: service.pid, details: LiveSessionDetails(stateSince: stateSince)))
                }
            } catch {
                notices.append("\(source.name): the OpenCode database could not be read; live status is unavailable.")
            }
        }
        // Verify presence again after reading the database.
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

    /// The registered service, when its process is alive and started before it
    /// registered (a later process holding the PID reused a dead service's).
    private func verifiedService(source: AgentSource, notices: inout [String]) -> Service? {
        let registration = URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".local/state/opencode/service.json")
        guard let stat = FileStat.of(registration.path) else { return nil }
        guard stat.kind == .regular, stat.size <= 65_536, let data = try? Data(contentsOf: registration),
              let pid = Self.registeredPID(data) else {
            notices.append("\(source.name): the OpenCode service registration could not be read; live status is unavailable.")
            return nil
        }
        guard let start = processStartTimes([pid])[pid] else { return nil }
        let service = Service(pid: pid, start: start)
        guard service.started <= stat.modified.addingTimeInterval(Self.registrationSlack) else { return nil }
        return service
    }

    /// The registration's PID. The password beside it is not kept.
    static func registeredPID(_ data: Data) -> Int32? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let number = object["pid"] as? NSNumber,
              // `true` would also read as the number 1.
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.int64Value
        guard Double(value) == number.doubleValue, value > 1, value <= Int64(Int32.max) else { return nil }
        return Int32(value)
    }

    struct Busy {
        let id: String
        let workspace: String
        let busySince: Date
        let waiting: Bool
        let waitingSince: Date?
    }

    /// Sessions executing since `since`, and whether each waits on a question.
    static func busySessions(_ db: ReadOnlySQLite, since: Date, now: Date) throws -> [Busy] {
        let columns = db.columns(of: "session_v2")
        guard columns.isSuperset(of: ["id", "directory"]),
              db.columns(of: "session_message").isSuperset(of: ["id", "session_id", "type", "seq", "data"]) else { return [] }
        let started: String
        let condition: String
        if columns.contains("time_busy") {
            started = "time_busy"
            condition = "time_busy IS NOT NULL AND time_busy > \(columns.contains("time_idle") ? "coalesce(time_idle, 0)" : "0")"
        } else if columns.contains("time_suspended") {
            started = "time_suspended"
            condition = "time_suspended IS NOT NULL"
        } else {
            return []
        }
        let threshold = Int64((since.timeIntervalSince1970 * 1000).rounded(.down))
        let rows = try db.rows("SELECT id, directory, \(started) FROM session_v2 WHERE \(condition) AND \(started) >= ?1",
                               bindings: [.integer(threshold)], maximumColumnBytes: 65_536)
        let parts = db.columns(of: "session_part").isSuperset(of: ["message_id", "session_id", "type", "data"])
        var result: [Busy] = []
        for row in rows where row.count == 3 {
            guard let id = row[0].string, OpenCodeDatabase.isSafeID(id), let raw = row[1].string,
                  let workspace = CheckoutPath.absolute(raw), let busySince = OpenCodeDatabase.moment(row[2]),
                  busySince <= now.addingTimeInterval(5) else { continue }
            let question = try openQuestion(db, session: id, parts: parts)
            result.append(Busy(id: id, workspace: workspace, busySince: busySince, waiting: question.open,
                               waitingSince: question.since))
        }
        return result
    }

    /// Whether the session's current step has a `question` call still running,
    /// and since when.
    static func openQuestion(_ db: ReadOnlySQLite, session: String, parts: Bool) throws -> (open: Bool, since: Date?) {
        let latest = "(SELECT max(seq) FROM session_message WHERE session_id = ?1 AND type = 'assistant')"
        let inline = "SELECT coalesce(json_extract(j.value, '$.time.ran'), json_extract(j.value, '$.time.created')) FROM session_message m, json_each(CASE WHEN json_valid(m.data) THEN m.data ELSE '{}' END, '$.content') j WHERE m.session_id = ?1 AND m.type = 'assistant' AND m.seq = \(latest) AND (CASE WHEN j.type = 'object' THEN json_extract(j.value, '$.type') = 'tool' AND json_extract(j.value, '$.name') = 'question' AND json_extract(j.value, '$.state.status') = 'running' ELSE 0 END) LIMIT 1"
        if let row = try db.rows(inline, bindings: [.text(session)], maximumColumnBytes: 1_024).first {
            return (true, row.first.flatMap { OpenCodeDatabase.moment($0) })
        }
        guard parts else { return (false, nil) }
        let current = "(SELECT id FROM session_message WHERE session_id = ?1 AND type = 'assistant' ORDER BY seq DESC LIMIT 1)"
        let stored = "SELECT coalesce(json_extract(sp.data, '$.time.ran'), json_extract(sp.data, '$.time.created')) FROM session_part sp WHERE sp.session_id = ?1 AND sp.type = 'tool' AND sp.message_id = \(current) AND (CASE WHEN json_valid(sp.data) THEN json_extract(sp.data, '$.name') = 'question' AND json_extract(sp.data, '$.state.status') = 'running' ELSE 0 END) LIMIT 1"
        if let row = try db.rows(stored, bindings: [.text(session)], maximumColumnBytes: 1_024).first {
            return (true, row.first.flatMap { OpenCodeDatabase.moment($0) })
        }
        return (false, nil)
    }
}
