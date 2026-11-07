import Foundation

/// Read-only adapter for OpenCode: the `opencode` TUI and CLI, `opencode
/// serve`, and the OpenCode desktop app, which all write one store.
///
/// The profile's folder is OpenCode's data folder (`~/.local/share/opencode`,
/// or `$XDG_DATA_HOME/opencode`), or a database file it names (`OPENCODE_DB`).
/// The folder's `opencode.db`, and `opencode-<channel>.db` for other release
/// channels, is one SQLite database read strictly through `ReadOnlySQLite`.
/// `opencode-next.db` is skipped: OpenCode 2 imports it into `opencode.db`.
/// Two schema generations can share a file, so each is recognized by its
/// tables and columns, never by a version number:
///
/// - OpenCode 1.2 to 1.x: `session`, `message` and `part`. A `tool` part in
///   state `completed` is one edit when its tool is `edit`, `write`,
///   `multiedit` or `apply_patch`. Its files are `metadata.files[]`
///   (`apply_patch`, with `movePath`), else the absolute `metadata.filepath`
///   (`write`) or `metadata.filediff.file` (`edit`), else `input.filePath`
///   joined to the message's `path.cwd`. Its time is `state.time.end`.
/// - OpenCode 2: `session_v2` and `session_message`, whose assistant rows hold
///   their tool items in `content[]`, plus `session_part` rows (2.2.2 and
///   later, when part rows are enabled). A `tool` item in state `completed` is
///   one edit when its tool is `edit`, `write` or `patch`, or a 1.x edit tool
///   OpenCode 2 imported. Its files are `metadata.files[].file`, else
///   `input.path` (or an imported `input.filePath`), relative to the session's
///   location when that step ran: `location-switched` messages move it. Its
///   time is `time.completed`.
///
/// OpenCode 2 imports the 1.x tables into its own under the same ids and
/// leaves them in place. A session in both is read from OpenCode 2's copy,
/// which holds its reverts and deletions, plus 1.x edits completed after the
/// import finished (`kv` `migration.v1-v2`). A 1.x session missing from
/// OpenCode 2's tables and older than the import was deleted there. The edits
/// of a staged revert do not count; a committed revert deletes them. A
/// subagent session names its parent; a fork's copied edits keep their call id
/// and time, so they count once. Shell commands, failed, denied or unfinished
/// tools and file modification times are never evidence. The cache keeps ids,
/// times and folder paths only: no prompts, tool input, diffs or file content.
public final class OpenCodeActivityProvider: ActivityProvider {
    static let cacheVersion = 1
    private let cache: HistoryCache<OpenCodeStore>
    private let resolver: GitProjectResolver
    private let ownsResolver: Bool

    public var projectLocations: ProjectLocationRegistry {
        get { resolver.locations }
        set { resolver.reset(locations: newValue) }
    }

    public convenience init(cacheURL: URL? = nil, projectLocations: ProjectLocationRegistry = .init()) {
        self.init(cacheURL: cacheURL, resolver: GitProjectResolver(locations: projectLocations), ownsResolver: true)
    }

    /// A shared resolver is reset by its owner once per scan.
    init(cacheURL: URL?, resolver: GitProjectResolver, ownsResolver: Bool = false) {
        cache = HistoryCache(url: cacheURL, version: Self.cacheVersion, name: "OpenCode")
        self.resolver = resolver
        self.ownsResolver = ownsResolver
    }

    /// Sessions from cached evidence only, so they appear where the last scan put them.
    public func metadata(sources: [AgentSource]) -> ScanResult {
        if ownsResolver { resolver.reset() }
        let discovered = discover(sources: sources)
        return result(discovered, parsed: cache.files, notices: discovered.notices)
    }

    public func scan(sources: [AgentSource]) -> ScanResult {
        scan(sources: sources, progress: nil)
    }

    public func scan(sources: [AgentSource], progress: ((ScanResult, Int, Int) -> Void)?) -> ScanResult {
        if ownsResolver { resolver.reset() }
        let discovered = discover(sources: sources)
        var notices = discovered.notices + (cache.takeLoadNotice().map { [$0] } ?? [])
        var parsed: [String: OpenCodeStore] = [:]
        let tasks = discovered.tasks
        var lastProgress = Date.distantPast
        for (index, task) in tasks.enumerated() {
            let path = task.url.path
            let cached = cache[path]
            let store = cached ?? OpenCodeStore()
            let outcome = OpenCodeDatabase.refresh(store, url: task.url, now: Date())
            if let notice = Self.notice(outcome, source: task.source, keptHistory: !store.isEmpty) {
                notices.append(notice)
            }
            // A database that cannot be read keeps the evidence of its last read.
            cache.store(store, at: path, changed: cached == nil || outcome.changesStore)
            parsed[path] = store
            let completed = index + 1
            if let progress, completed == tasks.count || Date().timeIntervalSince(lastProgress) >= 0.5 {
                progress(result(discovered, parsed: parsed, notices: notices), completed, tasks.count)
                lastProgress = Date()
            }
        }
        cache.prune(keeping: Set(tasks.map(\.url.path)))
        if let notice = cache.saveIfDue() { notices.append(notice) }
        return result(discovered, parsed: parsed, notices: notices)
    }

    @discardableResult
    public func saveCache() -> String? {
        cache.save()
    }

    private static func notice(_ outcome: OpenCodeDatabase.Outcome, source: AgentSource, keptHistory: Bool) -> String? {
        let kept = keptHistory ? " History shows what was last indexed." : ""
        switch outcome {
        case .unchanged:
            return nil
        case .refreshed(let skipped):
            guard skipped > 0 else { return nil }
            return "\(source.name): \(skipped) OpenCode session(s) could not be read; they are read again when they change."
        case .busy:
            return "\(source.name): the OpenCode database was busy; its newest history is read on the next scan."
        case .unreadable:
            return "\(source.name): the OpenCode database could not be opened read-only.\(kept)"
        case .unknownFormat:
            return "\(source.name): the OpenCode database uses a format this version doesn't read.\(kept)"
        }
    }

    // MARK: Discovery

    private struct ScanTask {
        let source: AgentSource
        let url: URL
    }

    private struct Discovered {
        var tasks: [ScanTask] = []
        var notices: [String] = []
    }

    private func discover(sources: [AgentSource]) -> Discovered {
        var discovered = Discovered()
        for source in sources where source.assistant == .opencode {
            let databases = Self.databases(source)
            if databases.isEmpty { discovered.notices.append(Self.missingNotice(source)) }
            discovered.tasks += databases.map { ScanTask(source: source, url: $0) }
        }
        return discovered
    }

    /// The profile's databases: `opencode.db` first, then other channels'
    /// `opencode-<channel>.db`; or the database file the profile names.
    static func databases(_ source: AgentSource) -> [URL] {
        let path = canonicalPath(source.configDirectory)
        guard let stat = FileStat.of(path) else { return [] }
        if stat.kind == .regular { return path.hasSuffix(".db") ? [URL(fileURLWithPath: path)] : [] }
        guard stat.kind == .directory, let names = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return []
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let sorted = names.filter(isDatabaseName).sorted()
        let ordered = sorted.filter { $0 == "opencode.db" } + sorted.filter { $0 != "opencode.db" }
        return ordered.map { folder.appendingPathComponent($0) }.filter { FileStat.of($0.path)?.kind == .regular }
    }

    /// `opencode.db`, or `opencode-<channel>.db` for a channel other than
    /// `next`, whose database OpenCode 2 imports into `opencode.db`.
    static func isDatabaseName(_ name: String) -> Bool {
        if name == "opencode.db" { return true }
        guard name.hasPrefix("opencode-"), name.hasSuffix(".db") else { return false }
        let channel = name.dropFirst("opencode-".count).dropLast(3)
        return !channel.isEmpty && channel.count <= 64 && channel != "next"
            && channel.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ".") }
    }

    private static func missingNotice(_ source: AgentSource) -> String {
        let storage = (canonicalPath(source.configDirectory) as NSString).appendingPathComponent("storage/session")
        if FileStat.of(storage)?.kind == .directory {
            return "\(source.name): this OpenCode history is kept in the JSON files of OpenCode before 1.2, which Agent Trail doesn't read; OpenCode 1.2 and later move it into opencode.db."
        }
        return "\(source.name): no local OpenCode history was found."
    }

    // MARK: Folding

    private func result(_ discovered: Discovered, parsed: [String: OpenCodeStore], notices: [String]) -> ScanResult {
        // Channel databases and the two schema generations can hold one session
        // more than once; its copies merge, and edits keep one record per call.
        var merged: [String: (source: AgentSource, id: String, session: OpenCodeSession)] = [:]
        var order: [String] = []
        for task in discovered.tasks {
            guard let store = parsed[task.url.path] else { continue }
            for (id, session) in Self.sessions(in: store) {
                let key = task.source.id + "\u{0}" + id
                if let existing = merged[key] {
                    merged[key] = (source: existing.source, id: id, session: Self.merge(existing.session, session))
                } else {
                    merged[key] = (source: task.source, id: id, session: session)
                    order.append(key)
                }
            }
        }
        var sessions: [HistorySession] = []
        for key in order {
            guard let entry = merged[key] else { continue }
            let session = entry.session
            // A session bound to an OpenCode workspace whose folder is not on
            // this Mac ran somewhere else.
            if session.boundToWorkspace, FileStat.of(session.directory) == nil { continue }
            let latest = ([session.created, session.latest] + session.edits.values.map(\.date)).max() ?? session.created
            var history = HistorySession(sourceID: entry.source.id, sessionID: entry.id,
                recordedWorkspace: session.directory, roots: session.roots, createdAt: session.created,
                latestActivity: latest, edits: session.edits)
            history.parentSessionID = session.parentID
            sessions.append(history)
        }
        let folded = HistoryFold.fold(sessions, resolver: resolver)
        return ScanResult(projects: ProjectSummary.merge(folded.activity), notices: Array(Set(notices)).sorted(),
            sessionProjects: folded.associations, missingFolders: folded.missingFolders,
            sessionTrails: SessionTrail.merge(folded.trails))
    }

    /// One record per session id in a database. OpenCode 2's copy wins, plus
    /// 1.x edits completed after the import; a 1.x session the import predates
    /// that OpenCode 2 no longer has was deleted there.
    static func sessions(in store: OpenCodeStore) -> [(String, OpenCodeSession)] {
        var sessions = store.v2
        for (id, legacy) in store.v1 {
            if let current = sessions[id] {
                guard let imported = store.importedAt else { continue }
                var later = legacy
                later.edits = legacy.edits.filter { $0.value.date >= imported }
                sessions[id] = merge(current, later)
            } else if store.hasV2, let imported = store.importedAt, legacy.created < imported {
                continue
            } else {
                sessions[id] = legacy
            }
        }
        return sessions.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    static func merge(_ first: OpenCodeSession, _ second: OpenCodeSession) -> OpenCodeSession {
        var merged = first
        for (id, edit) in second.edits {
            merged.edits[id] = merged.edits[id]?.earlier(than: edit) ?? edit
        }
        merged.roots = Array(Set(first.roots + second.roots)).sorted()
        merged.created = min(first.created, second.created)
        merged.latest = max(first.latest, second.latest)
        if merged.parentID == nil { merged.parentID = second.parentID }
        return merged
    }
}

// MARK: - Cached evidence

/// The database and its `-wal` file at the last complete read. While both are
/// unchanged, the database is not opened.
struct OpenCodeStamp: Codable, Equatable {
    var database: FileStamp
    var wal: FileStamp?

    /// Nil when the database is not a regular file.
    init?(_ url: URL) {
        guard let database = FileStat.of(url.path), database.kind == .regular else { return nil }
        self.database = FileStamp(database)
        wal = FileStat.of(url.path + "-wal").flatMap { $0.kind == .regular ? FileStamp($0) : nil }
    }
}

/// One database's sessions, by generation.
final class OpenCodeStore: Codable {
    var stamp: OpenCodeStamp?
    /// True when OpenCode 2's tables were present at the last read.
    var hasV2 = false
    /// When OpenCode 2 finished importing the 1.x tables; nil until it has.
    var importedAt: Date?
    var v1: [String: OpenCodeSession] = [:]
    var v2: [String: OpenCodeSession] = [:]

    init() {}

    var isEmpty: Bool { v1.isEmpty && v2.isEmpty }
}

/// One session's evidence. Paths are lexical, as recorded.
struct OpenCodeSession: Codable, Equatable {
    var parentID: String?
    /// The folder the session started in.
    var directory: String
    /// Every folder the session worked in.
    var roots: [String]
    /// True when OpenCode bound the session to a workspace, which may run elsewhere.
    var boundToWorkspace: Bool
    var created: Date
    var latest: Date
    var edits: [String: StoredEdit]
    /// The session row and its message and part counts at the last read.
    var fingerprint: String
    /// Mid-turn at the last read, so it is read again on the next change.
    var volatile: Bool
}

// MARK: - Database reader

/// Reads one OpenCode database into its cached evidence. An unchanged file is
/// not opened. Otherwise every session row is listed with cheap index counts,
/// and only sessions whose row or counts changed, or that were mid-turn, are
/// read again. JSON is taken apart inside SQLite, so only ids, times and paths
/// reach Agent Trail: never prompts, tool input, output or diffs.
enum OpenCodeDatabase {
    enum Outcome: Equatable {
        case unchanged
        case refreshed(skippedSessions: Int)
        case busy
        case unreadable
        case unknownFormat

        var changesStore: Bool {
            if case .refreshed = self { return true }
            return false
        }
    }

    /// Tools whose completed calls are edits: OpenCode 2's `edit`, `write` and
    /// `patch`, and 1.x's `edit`, `write`, `multiedit` and `apply_patch`. The
    /// `patch` tool of OpenCode 1.0 names its files only inside the patch text,
    /// so its calls find no file and never count.
    static let editTools = ["edit", "write", "patch", "apply_patch", "multiedit"]
    /// A session left mid-turn within this long is read again on every change.
    static let volatileWindow: TimeInterval = 24 * 60 * 60
    /// The largest value read: ids, times, paths and lists of paths.
    static let valueCap = 4 * 1_048_576

    static func refresh(_ store: OpenCodeStore, url: URL, now: Date) -> Outcome {
        // Stamped before reading, so a write during the read is read next time.
        guard let stamp = OpenCodeStamp(url) else { return .unreadable }
        if store.stamp == stamp { return .unchanged }
        guard let db = ReadOnlySQLite(url: url) else { return .unreadable }
        do {
            // A WAL database whose -wal file is gone fails on its first read, not on open.
            let tables = try db.rows("SELECT count(*) FROM sqlite_master WHERE type = 'table'", deadline: 5)
            guard let count = tables.first?.first?.int else { return .unreadable }
            guard count > 0 else {
                // A database OpenCode has only just created.
                store.v1 = [:]
                store.v2 = [:]
                store.hasV2 = false
                store.importedAt = nil
                store.stamp = stamp
                return .refreshed(skippedSessions: 0)
            }
            let layout = Layout(db)
            guard layout.v1 != nil || layout.v2 != nil else { return .unknownFormat }
            var skipped = 0
            var v2: [String: OpenCodeSession] = [:]
            var importedAt: Date?
            if let columns = layout.v2 {
                v2 = try readV2(db, layout: layout, columns: columns, previous: store.v2, now: now, skipped: &skipped)
                if layout.kv { importedAt = try importTime(db) }
            }
            var v1: [String: OpenCodeSession] = [:]
            if let columns = layout.v1 {
                v1 = try readV1(db, layout: layout, columns: columns, previous: store.v1, now: now, skipped: &skipped)
            }
            store.v1 = v1
            store.v2 = v2
            store.hasV2 = layout.v2 != nil
            store.importedAt = importedAt
            store.stamp = stamp
            return .refreshed(skippedSessions: skipped)
        } catch ReadOnlySQLite.Failure.busy {
            return .busy
        } catch {
            return .unreadable
        }
    }

    /// Which generations' tables the database has.
    struct Layout {
        /// OpenCode 2's session columns, when its tables are present.
        var v2: Set<String>?
        var v2Parts = false
        var v2Projects = false
        /// OpenCode 1.x's session columns, when its tables are present.
        var v1: Set<String>?
        var v1Projects = false
        var kv = false

        init(_ db: ReadOnlySQLite) {
            let projects = db.columns(of: "project").isSuperset(of: ["id", "worktree"])
            let current = db.columns(of: "session_v2")
            if current.isSuperset(of: ["id", "directory", "time_created", "time_updated"]),
               db.columns(of: "session_message").isSuperset(of: ["id", "session_id", "type", "seq", "time_created", "data"]) {
                v2 = current
                v2Parts = db.columns(of: "session_part").isSuperset(of: ["message_id", "session_id", "ordinal", "type", "data"])
                v2Projects = projects && current.contains("project_id")
                kv = db.columns(of: "kv").isSuperset(of: ["key", "value", "time_updated"])
            }
            let legacy = db.columns(of: "session")
            if legacy.isSuperset(of: ["id", "directory", "time_created", "time_updated"]),
               db.columns(of: "message").isSuperset(of: ["id", "session_id", "time_created", "data"]),
               db.columns(of: "part").isSuperset(of: ["id", "message_id", "session_id", "time_created", "data"]) {
                v1 = legacy
                v1Projects = projects && legacy.contains("project_id")
            }
        }
    }

    // MARK: OpenCode 2

    private static func readV2(_ db: ReadOnlySQLite, layout: Layout, columns: Set<String>,
                               previous: [String: OpenCodeSession], now: Date,
                               skipped: inout Int) throws -> [String: OpenCodeSession] {
        func column(_ name: String) -> String { columns.contains(name) ? "s.\(name)" : "NULL" }
        let revert = columns.contains("revert")
            ? "CASE WHEN json_valid(s.revert) THEN json_extract(s.revert, '$.messageID') END" : "NULL"
        let worktree = layout.v2Projects ? "p.worktree" : "NULL"
        let join = layout.v2Projects ? " LEFT JOIN project p ON p.id = s.project_id" : ""
        let rows = try db.rows("SELECT s.id, \(column("parent_id")), s.directory, s.time_created, \(column("time_busy")), \(column("time_idle")), \(column("time_suspended")), \(column("workspace_id")), \(revert), \(worktree), s.time_updated FROM session_v2 s\(join)",
                               maximumColumnBytes: 65_536)
        let messages = try counts(db, "SELECT session_id, count(*), max(time_created) FROM session_message GROUP BY session_id")
        var parts: [String: (count: Int64, latest: Int64)] = [:]
        if layout.v2Parts {
            parts = try counts(db, "SELECT session_id, count(*) FROM session_part GROUP BY session_id")
        }
        var result: [String: OpenCodeSession] = [:]
        for row in rows where row.count == 11 {
            guard let id = row[0].string, isSafeID(id), let created = moment(row[3]) else { continue }
            let message = messages[id]
            let fingerprint = (row.dropFirst().map { Self.describe($0) }
                + ["\(message?.count ?? 0)", "\(message?.latest ?? 0)", "\(parts[id]?.count ?? 0)"]).joined(separator: "|")
            let busyAt = row[4].int
            let idleAt = row[5].int
            let suspendedAt = row[6].int
            // An execution in flight: time_busy past time_idle (2.2.2 and later),
            // else an unreleased execution claim.
            let busy = busyAt.map { $0 > (idleAt ?? 0) } ?? (suspendedAt != nil)
            let touched = [row[10].int, busyAt, suspendedAt, message?.latest].compactMap { $0 }.max() ?? 0
            let recent = now.timeIntervalSince1970 * 1000 - Double(touched) < volatileWindow * 1000
            if let old = previous[id], old.fingerprint == fingerprint, !old.volatile {
                result[id] = old
                continue
            }
            let latest = message.flatMap { Self.milliseconds($0.latest) } ?? created
            do {
                guard var session = try extractV2(db, layout: layout, id: id,
                        recorded: row[2].string.flatMap(ProjectLocationRegistry.lexicalPath),
                        worktree: usableWorktree(row[9]), revertMessage: row[8].string, parentID: row[1].string,
                        boundToWorkspace: row[7] != .null, created: created, latest: max(created, latest), now: now) else {
                    continue
                }
                session.fingerprint = fingerprint
                session.volatile = session.volatile || (busy && recent)
                result[id] = session
            } catch ReadOnlySQLite.Failure.busy {
                throw ReadOnlySQLite.Failure.busy
            } catch {
                skipped += 1
                // Keep what was read before; it is read again when the session changes.
                if var old = previous[id] {
                    old.fingerprint = fingerprint
                    old.volatile = false
                    result[id] = old
                }
            }
        }
        return result
    }

    private static func extractV2(_ db: ReadOnlySQLite, layout: Layout, id: String, recorded: String?,
                                  worktree: String?, revertMessage: String?, parentID: String?,
                                  boundToWorkspace: Bool, created: Date, latest: Date,
                                  now: Date) throws -> OpenCodeSession? {
        // Moves, in order. The first one's `previous` is where the session started.
        var switches: [(seq: Int64, directory: String)] = []
        var initial: String?
        var sawSwitch = false
        try db.each("SELECT seq, CASE WHEN json_valid(data) THEN json_extract(data, '$.location.directory') END, CASE WHEN json_valid(data) THEN json_extract(data, '$.previous.location.directory') END FROM session_message WHERE session_id = ?1 AND type = 'location-switched' ORDER BY seq",
                    bindings: [.text(id)], maximumColumnBytes: 65_536) { row in
            guard row.count == 3, let seq = row[0].int else { return true }
            if !sawSwitch {
                sawSwitch = true
                initial = row[2].string.flatMap(ProjectLocationRegistry.lexicalPath)
            }
            if let directory = row[1].string.flatMap(ProjectLocationRegistry.lexicalPath) {
                switches.append((seq: seq, directory: directory))
            }
            return true
        }
        // Legacy rows may hold an empty folder; the project's root stands in.
        let current = recorded ?? worktree
        guard let start = initial ?? current else { return nil }

        // A staged revert restored the files of every later step.
        var boundary: Int64?
        if let revertMessage {
            boundary = try db.rows("SELECT seq FROM session_message WHERE session_id = ?1 AND id = ?2",
                                   bindings: [.text(id), .text(revertMessage)], maximumColumnBytes: 1_024).first?.first?.int
        }

        let names = editTools.map { "'\($0)'" }.joined(separator: ", ")
        var tools: [ToolRow] = []
        let inline = "SELECT m.id, m.seq, m.time_created, j.key, \(toolColumns("j.value", id: "$.id", name: "$.name", time: "$.time.completed")) FROM session_message m, json_each(CASE WHEN json_valid(m.data) THEN m.data ELSE '{}' END, '$.content') j WHERE m.session_id = ?1 AND m.type = 'assistant' AND (CASE WHEN j.type = 'object' THEN json_extract(j.value, '$.type') = 'tool' AND json_extract(j.value, '$.name') IN (\(names)) ELSE 0 END)"
        try db.each(inline, bindings: [.text(id)], maximumColumnBytes: valueCap) { row in
            if let tool = ToolRow(row) { tools.append(tool) }
            return true
        }
        if layout.v2Parts {
            let parts = "SELECT sp.message_id, m.seq, m.time_created, sp.ordinal, \(toolColumns("sp.data", id: "$.id", name: "$.name", time: "$.time.completed")) FROM session_part sp LEFT JOIN session_message m ON m.id = sp.message_id WHERE sp.session_id = ?1 AND sp.type = 'tool' AND (CASE WHEN json_valid(sp.data) THEN json_extract(sp.data, '$.name') IN (\(names)) ELSE 0 END)"
            try db.each(parts, bindings: [.text(id)], maximumColumnBytes: valueCap) { row in
                if let tool = ToolRow(row) { tools.append(tool) }
                return true
            }
        }

        var edits: [String: StoredEdit] = [:]
        var volatile = false
        for tool in tools {
            if tool.status == "streaming" || tool.status == "running" {
                if let at = tool.messageCreated, now.timeIntervalSince(at) < volatileWindow { volatile = true }
                continue
            }
            guard tool.status == "completed", let completed = tool.completed,
                  let stamp = tool.completedMilliseconds else { continue }
            if let boundary, let seq = tool.seq, seq > boundary { continue }
            let location: String
            if let seq = tool.seq {
                location = switches.last(where: { $0.seq < seq })?.directory ?? start
            } else {
                location = current ?? start
            }
            guard let change = Self.edit(tool, base: location, date: completed) else { continue }
            let key = Self.editID(tool, milliseconds: stamp)
            edits[key] = edits[key]?.earlier(than: change) ?? change
        }
        var roots = Set([start] + switches.map { $0.directory })
        if let current { roots.insert(current) }
        return OpenCodeSession(parentID: parentID, directory: start, roots: roots.sorted(),
            boundToWorkspace: boundToWorkspace, created: created, latest: latest, edits: edits,
            fingerprint: "", volatile: volatile)
    }

    // MARK: OpenCode 1.x

    private static func readV1(_ db: ReadOnlySQLite, layout: Layout, columns: Set<String>,
                               previous: [String: OpenCodeSession], now: Date,
                               skipped: inout Int) throws -> [String: OpenCodeSession] {
        func column(_ name: String) -> String { columns.contains(name) ? "s.\(name)" : "NULL" }
        let hasRevert = columns.contains("revert")
        let revertMessage = hasRevert ? "CASE WHEN json_valid(s.revert) THEN json_extract(s.revert, '$.messageID') END" : "NULL"
        let revertPart = hasRevert ? "CASE WHEN json_valid(s.revert) THEN json_extract(s.revert, '$.partID') END" : "NULL"
        let worktree = layout.v1Projects ? "p.worktree" : "NULL"
        let join = layout.v1Projects ? " LEFT JOIN project p ON p.id = s.project_id" : ""
        let rows = try db.rows("SELECT s.id, \(column("parent_id")), s.directory, s.time_created, \(column("workspace_id")), \(revertMessage), \(revertPart), \(worktree), s.time_updated FROM session s\(join)",
                               maximumColumnBytes: 65_536)
        let messages = try counts(db, "SELECT session_id, count(*), max(time_created) FROM message GROUP BY session_id")
        let parts = try counts(db, "SELECT session_id, count(*) FROM part GROUP BY session_id")
        var result: [String: OpenCodeSession] = [:]
        for row in rows where row.count == 9 {
            guard let id = row[0].string, isSafeID(id), let created = moment(row[3]) else { continue }
            let message = messages[id]
            let fingerprint = (row.dropFirst().map { Self.describe($0) }
                + ["\(message?.count ?? 0)", "\(message?.latest ?? 0)", "\(parts[id]?.count ?? 0)"]).joined(separator: "|")
            if let old = previous[id], old.fingerprint == fingerprint, !old.volatile {
                result[id] = old
                continue
            }
            let latest = message.flatMap { Self.milliseconds($0.latest) } ?? created
            do {
                guard var session = try extractV1(db, id: id,
                        recorded: row[2].string.flatMap(ProjectLocationRegistry.lexicalPath),
                        worktree: usableWorktree(row[7]), revertMessage: row[5].string, revertPart: row[6].string,
                        parentID: row[1].string, boundToWorkspace: row[4] != .null, created: created,
                        latest: max(created, latest), now: now) else { continue }
                session.fingerprint = fingerprint
                result[id] = session
            } catch ReadOnlySQLite.Failure.busy {
                throw ReadOnlySQLite.Failure.busy
            } catch {
                skipped += 1
                if var old = previous[id] {
                    old.fingerprint = fingerprint
                    old.volatile = false
                    result[id] = old
                }
            }
        }
        return result
    }

    private static func extractV1(_ db: ReadOnlySQLite, id: String, recorded: String?, worktree: String?,
                                  revertMessage: String?, revertPart: String?, parentID: String?,
                                  boundToWorkspace: Bool, created: Date, latest: Date,
                                  now: Date) throws -> OpenCodeSession? {
        guard let directory = recorded ?? worktree else { return nil }
        // Each assistant message records the folder OpenCode ran in.
        var folders: [String: String] = [:]
        var roots: Set<String> = [directory]
        var volatile = false
        try db.each("SELECT id, time_created, CASE WHEN json_valid(data) THEN json_extract(data, '$.role') END, CASE WHEN json_valid(data) THEN json_extract(data, '$.path.cwd') END, CASE WHEN json_valid(data) THEN json_extract(data, '$.time.completed') END FROM message WHERE session_id = ?1",
                    bindings: [.text(id)], maximumColumnBytes: 65_536) { row in
            guard row.count == 5, let message = row[0].string else { return true }
            if let folder = row[3].string.flatMap(ProjectLocationRegistry.lexicalPath) {
                folders[message] = folder
                roots.insert(folder)
            }
            if row[2].string == "assistant", row[4] == .null, let at = Self.moment(row[1]),
               now.timeIntervalSince(at) < Self.volatileWindow {
                volatile = true
            }
            return true
        }

        let names = editTools.map { "'\($0)'" }.joined(separator: ", ")
        var tools: [ToolRow] = []
        let parts = "SELECT p.message_id, NULL, p.time_created, p.id, \(toolColumns("p.data", id: "$.callID", name: "$.tool", time: "$.state.time.end")) FROM part p WHERE p.session_id = ?1 AND (CASE WHEN json_valid(p.data) THEN json_extract(p.data, '$.type') = 'tool' AND json_extract(p.data, '$.tool') IN (\(names)) ELSE 0 END)"
        try db.each(parts, bindings: [.text(id)], maximumColumnBytes: valueCap) { row in
            if let tool = ToolRow(row) { tools.append(tool) }
            return true
        }

        var edits: [String: StoredEdit] = [:]
        for tool in tools {
            if tool.status == "pending" || tool.status == "running" {
                if let at = tool.messageCreated, now.timeIntervalSince(at) < volatileWindow { volatile = true }
                continue
            }
            guard tool.status == "completed", let completed = tool.completed,
                  let stamp = tool.completedMilliseconds else { continue }
            // A staged revert restored the files from its message (or its part) on.
            // Message and part ids ascend in creation order.
            if let revertMessage, tool.message > revertMessage
                || (tool.message == revertMessage && (revertPart.map { tool.position >= $0 } ?? true)) {
                continue
            }
            guard let change = Self.edit(tool, base: folders[tool.message] ?? directory, date: completed) else { continue }
            let key = Self.editID(tool, milliseconds: stamp)
            edits[key] = edits[key]?.earlier(than: change) ?? change
        }
        return OpenCodeSession(parentID: parentID, directory: directory, roots: roots.sorted(),
            boundToWorkspace: boundToWorkspace, created: created, latest: latest, edits: edits,
            fingerprint: "", volatile: volatile)
    }

    // MARK: Tool calls

    /// The columns both generations' tool JSON share, read from `item` inside
    /// SQLite: call id, tool, status, completion time, the input's path keys,
    /// and the paths (never the diffs) in `metadata`.
    static func toolColumns(_ item: String, id: String, name: String, time: String) -> String {
        let files = "CASE WHEN json_type(\(item), '$.state.metadata.files') = 'array' THEN (SELECT json_group_array(CASE WHEN f.type = 'object' THEN coalesce(json_extract(f.value, '$.file'), json_extract(f.value, '$.filePath')) WHEN f.type = 'text' THEN f.value END) FROM json_each(\(item), '$.state.metadata.files') f) END"
        let moves = "CASE WHEN json_type(\(item), '$.state.metadata.files') = 'array' THEN (SELECT json_group_array(CASE WHEN f.type = 'object' THEN json_extract(f.value, '$.movePath') END) FROM json_each(\(item), '$.state.metadata.files') f) END"
        return [
            "json_extract(\(item), '\(id)')", "json_extract(\(item), '\(name)')",
            "json_extract(\(item), '$.state.status')", "json_extract(\(item), '\(time)')",
            "json_extract(\(item), '$.state.input.path')", "json_extract(\(item), '$.state.input.filePath')",
            "json_extract(\(item), '$.state.metadata.filepath')", "json_extract(\(item), '$.state.metadata.filediff.file')",
            files, moves
        ].joined(separator: ", ")
    }

    /// One edit-tool call: four leading columns (message id, its sequence
    /// number, a creation time, the item's position), then `toolColumns`.
    struct ToolRow {
        let message: String
        let seq: Int64?
        let messageCreated: Date?
        let position: String
        let callID: String?
        let name: String
        let status: String
        let completed: Date?
        let completedMilliseconds: Int64?
        let inputPath: String?
        let inputFilePath: String?
        let metadataFilepath: String?
        let filediffFile: String?
        let files: [String]
        let moves: [String]

        init?(_ row: [ReadOnlySQLite.Value]) {
            guard row.count == 14, let message = row[0].string, let name = row[5].string,
                  let status = row[6].string else { return nil }
            self.message = message
            seq = row[1].int
            messageCreated = OpenCodeDatabase.moment(row[2])
            position = row[3].string ?? row[3].int.map { String($0) } ?? ""
            callID = row[4].string
            self.name = name
            self.status = status
            completed = OpenCodeDatabase.moment(row[7])
            completedMilliseconds = row[7].int
            inputPath = row[8].string
            inputFilePath = row[9].string
            metadataFilepath = row[10].string
            filediffFile = row[11].string
            files = Self.strings(row[12])
            moves = Self.strings(row[13])
        }

        /// A JSON array's strings; nulls and other values are dropped.
        private static func strings(_ value: ReadOnlySQLite.Value) -> [String] {
            guard let text = value.string,
                  let array = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [Any] else { return [] }
            return array.compactMap { $0 as? String }.filter { !$0.isEmpty }
        }
    }

    /// The edit a completed call made: its working folder and its files' folders.
    static func edit(_ tool: ToolRow, base: String, date: Date) -> StoredEdit? {
        let paths = targets(tool, base: base)
        guard !paths.isEmpty else { return nil }
        let directories = Array(Set(paths.map { ($0 as NSString).deletingLastPathComponent })).sorted()
        return StoredEdit(date: date, workspace: base, targetDirectories: directories)
    }

    /// The files a completed call names, branching on which keys it recorded.
    static func targets(_ tool: ToolRow, base: String) -> [String] {
        let resolved: [String]
        if !tool.files.isEmpty {
            // OpenCode 2 `edit` and `patch` name each file relative to the
            // location (absolute outside it); 1.x `apply_patch` names absolute paths.
            resolved = (tool.files + tool.moves).compactMap { resolve($0, base: base, expandsHome: false) }
        } else if tool.name == "write", let path = tool.metadataFilepath, path.hasPrefix("/") {
            resolved = [path].compactMap(ProjectLocationRegistry.lexicalPath)
        } else if let path = tool.filediffFile, path.hasPrefix("/") {
            resolved = [path].compactMap(ProjectLocationRegistry.lexicalPath)
        } else if let path = tool.inputFilePath {
            // 1.x joins a relative filePath to the folder it runs in.
            resolved = [path].compactMap { resolve($0, base: base, expandsHome: false) }
        } else if let path = tool.inputPath {
            // OpenCode 2 resolves `path` against the location, expanding `~`.
            resolved = [path].compactMap { resolve($0, base: base, expandsHome: true) }
        } else {
            resolved = []
        }
        return Array(Set(resolved)).sorted()
    }

    /// A recorded path made absolute and lexical, as OpenCode resolves it.
    static func resolve(_ raw: String, base: String, expandsHome: Bool) -> String? {
        guard !raw.isEmpty, !raw.contains("\0") else { return nil }
        if raw.hasPrefix("/") { return ProjectLocationRegistry.lexicalPath(raw) }
        if expandsHome, raw == "~" || raw.hasPrefix("~/") { return ProjectLocationRegistry.lexicalPath(raw) }
        return ProjectLocationRegistry.lexicalPath((base as NSString).appendingPathComponent(raw))
    }

    /// The call id and completion time: a fork's copy, an imported copy and a
    /// part row's copy of one call share both, so they count once.
    static func editID(_ tool: ToolRow, milliseconds: Int64) -> String {
        let call = tool.callID.flatMap { $0.isEmpty || $0.count > 256 ? nil : $0 } ?? "\(tool.message)#\(tool.position)"
        return "opencode:\(call)\u{0}\(milliseconds)"
    }

    // MARK: Values

    /// When OpenCode 2 finished importing the 1.x tables.
    static func importTime(_ db: ReadOnlySQLite) throws -> Date? {
        let rows = try db.rows("SELECT CASE WHEN json_valid(value) THEN json_extract(value, '$.phase') END, time_updated FROM kv WHERE key = 'migration.v1-v2'",
                               maximumColumnBytes: 4_096)
        guard let row = rows.first, row.count == 2, row[0].string == "completed" else { return nil }
        return moment(row[1])
    }

    /// Per-session row counts and, when selected, the newest creation time.
    private static func counts(_ db: ReadOnlySQLite, _ sql: String) throws -> [String: (count: Int64, latest: Int64)] {
        var result: [String: (count: Int64, latest: Int64)] = [:]
        try db.each(sql, maximumColumnBytes: 4_096) { row in
            if row.count >= 2, let id = row[0].string {
                result[id] = (count: row[1].int ?? 0, latest: row.count > 2 ? (row[2].int ?? 0) : 0)
            }
            return true
        }
        return result
    }

    /// A project root that can stand in for a session's folder: not the
    /// `global` project's `/`.
    private static func usableWorktree(_ value: ReadOnlySQLite.Value) -> String? {
        guard let path = value.string.flatMap(ProjectLocationRegistry.lexicalPath), path != "/" else { return nil }
        return path
    }

    /// Milliseconds since 1970.
    static func moment(_ value: ReadOnlySQLite.Value) -> Date? {
        guard let number = value.double, number.isFinite, number > 0 else { return nil }
        return Date(timeIntervalSince1970: number / 1000)
    }

    static func milliseconds(_ value: Int64) -> Date? {
        value > 0 ? Date(timeIntervalSince1970: Double(value) / 1000) : nil
    }

    static func describe(_ value: ReadOnlySQLite.Value) -> String {
        switch value {
        case .null: return "-"
        case .integer(let number): return String(number)
        case .real(let number): return String(number)
        case .text(let text): return text
        case .blob(let data, let truncated): return "blob:\(data.count):\(truncated)"
        }
    }

    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128
            && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
    }
}
