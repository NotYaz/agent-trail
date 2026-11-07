import Darwin
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
///
/// `opencode acp`, `opencode --standalone` and a hand-run `opencode serve` run
/// a private server on the same database, and nothing on disk says which server
/// runs a turn. A server that shuts down mid-turn leaves its row executing, so
/// its next start can resume it. So a turn whose newest recorded execution
/// event is a shutdown interrupt is not shown (OpenCode records these events
/// only when event persistence is on). While another server that started before
/// a turn began is running, that turn is Unknown, not Working under the
/// service; once that server is gone, a turn seen while it ran is not shown,
/// since a turn it left behind looks the same.
public final class OpenCodeLiveActivityProvider {
    private let processStartTimes: (Set<Int32>) -> [Int32: UInt64]
    private let otherServers: () -> [Int32: UInt64]?
    private let home: String
    /// Executions, by session id and `time_busy`, seen while another OpenCode
    /// server could have been running them. Memory only.
    private var unattributed: [String: Date] = [:]

    /// The service registers itself just after starting; this allows for clock rounding.
    static let registrationSlack: TimeInterval = 2

    /// `otherServers` lists this user's OpenCode servers other than the shared
    /// service, by PID with their start times in microseconds, or nil when
    /// processes cannot be listed.
    public init(processStartTimes: ((Set<Int32>) -> [Int32: UInt64])? = nil,
                otherServers: (() -> [Int32: UInt64]?)? = nil, home: String = NSHomeDirectory()) {
        self.processStartTimes = processStartTimes ?? GrokLiveActivityProvider.readProcessStartTimes
        self.otherServers = otherServers ?? Self.readOtherServers
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
        // Replaces `unattributed` only after a database read succeeded.
        var seen: [String: Date]?
        let folder = canonicalPath("\(home)/.local/share/opencode")
        for source in sources where source.assistant == .opencode {
            guard canonicalPath(source.configDirectory) == folder,
                  let service = verifiedService(source: source, notices: &notices) else { continue }
            let database = URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("opencode.db")
            guard let db = ReadOnlySQLite(url: database) else { continue }
            let executing: [Busy]
            do {
                let since = service.started.addingTimeInterval(-Self.registrationSlack)
                executing = try Self.busySessions(db, since: since, now: now)
            } catch ReadOnlySQLite.Failure.busy {
                continue // Read again on the next scan.
            } catch ReadOnlySQLite.Failure.interrupted {
                continue // Read again on the next scan.
            } catch {
                notices.append("\(source.name): the OpenCode database could not be read; live status is unavailable.")
                continue
            }
            var others: [Int32: UInt64]? = [:]
            if !executing.isEmpty { others = otherServers()?.filter { $0.key != service.pid } }
            var attributed = seen ?? [:]
            for busy in executing {
                guard let reported = status(of: busy, others: others, seen: &attributed) else { continue }
                starts[service.pid] = service.start
                let stateSince = reported == .waiting ? (busy.waitingSince ?? busy.busySince) : busy.busySince
                sessions.append(LiveAgentSession(sourceID: source.id, projectPath: busy.workspace,
                    workspacePath: busy.workspace, sessionID: busy.id, status: reported,
                    updatedAt: stateSince, pid: service.pid, details: LiveSessionDetails(stateSince: stateSince)))
            }
            seen = attributed
        }
        if let seen { unattributed = seen }
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

    /// An executing session's status, or nil to leave it out. The service runs
    /// it only when no other server could: one that started before the turn
    /// began and is running makes it Unknown, and so does a process list that
    /// cannot be read. A turn seen while such a server ran is left out once that
    /// server is gone, since a turn its shutdown left behind looks the same; its
    /// next turn sets a new `time_busy`.
    private func status(of busy: Busy, others: [Int32: UInt64]?, seen: inout [String: Date]) -> LiveStatus? {
        let remembered = unattributed[busy.id] == busy.busySince
        if remembered { seen[busy.id] = busy.busySince }
        guard let others else { return .unknown }
        let began = busy.busySince.timeIntervalSince1970 + Self.registrationSlack
        if others.values.contains(where: { Double($0) / 1_000_000 <= began }) {
            seen[busy.id] = busy.busySince
            return .unknown
        }
        if remembered { return nil }
        return busy.waiting ? .waiting : .working
    }

    /// This user's OpenCode servers other than the shared service, by PID with
    /// their start times in microseconds: an `opencode` or `opencode-cli`
    /// process whose arguments include `serve` but not `--service`, as
    /// `opencode acp` and `--standalone` start them. A process whose arguments
    /// cannot be read counts as one. Only process names, owners, start times
    /// and arguments are kept; the environment is dropped with the buffer.
    /// Nil when processes cannot be listed.
    static func readOtherServers() -> [Int32: UInt64]? {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        // Returns a count of PIDs, not bytes.
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return nil }
        var name = [UInt8](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        var servers: [Int32: UInt64] = [:]
        for pid in pids.prefix(min(Int(count), pids.count)) where pid > 0 {
            let length = proc_name(pid, &name, UInt32(name.count))
            guard length > 0,
                  let process = String(bytes: name[..<min(Int(length), name.count)], encoding: .utf8),
                  process == "opencode" || process == "opencode-cli" else { continue }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            // Another user's server writes that user's database.
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_status != SZOMB,
                  info.pbi_start_tvusec < 1_000_000,
                  info.pbi_start_tvsec <= UInt64.max / 1_000_000 else { continue }
            if let identity = ProcessIdentity.read(pid: pid), !isOtherServer(identity.arguments) { continue }
            servers[pid] = info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
        }
        return servers
    }

    /// `serve` without `--service`: the service runs `serve --service`, while
    /// `opencode acp` and `--standalone` run `serve --stdio`, and a hand-run
    /// server plain `serve`. Erring towards a server never claims Working.
    static func isOtherServer(_ arguments: [String]) -> Bool {
        let options = arguments.dropFirst()
        return options.contains("serve") && !options.contains("--service")
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
        let events = db.columns(of: "event").isSuperset(of: ["aggregate_id", "seq", "type", "data"])
        var result: [Busy] = []
        for row in rows where row.count == 3 {
            guard let id = row[0].string, OpenCodeDatabase.isSafeID(id), let raw = row[1].string,
                  let workspace = CheckoutPath.absolute(raw), let busySince = OpenCodeDatabase.moment(row[2]),
                  busySince <= now.addingTimeInterval(5) else { continue }
            if events, try stoppedByShutdown(db, session: id) { continue }
            let question = try openQuestion(db, session: id, parts: parts)
            result.append(Busy(id: id, workspace: workspace, busySince: busySince, waiting: question.open,
                               waitingSince: question.since))
        }
        return result
    }

    /// Whether the session's newest recorded execution event is a shutdown
    /// interrupt: its server stopped mid-turn and kept the execution for its
    /// next start, which records a new `started` event when it resumes. Event
    /// types carry a version suffix (`session.execution.interrupted.1`).
    static func stoppedByShutdown(_ db: ReadOnlySQLite, session: String) throws -> Bool {
        let kinds = ["started", "succeeded", "failed", "interrupted"].map { "'session.execution.\($0)'" }.joined(separator: ", ")
        let sql = "SELECT type, CASE WHEN json_valid(data) THEN json_extract(data, '$.reason') END FROM event WHERE aggregate_id = ?1 AND type GLOB 'session.execution.*' AND rtrim(rtrim(type, '0123456789'), '.') IN (\(kinds)) ORDER BY seq DESC LIMIT 1"
        guard let row = try db.rows(sql, bindings: [.text(session)], maximumColumnBytes: 1_024).first, row.count == 2,
              let type = row[0].string else { return false }
        return type.hasPrefix("session.execution.interrupted") && row[1].string == "shutdown"
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
