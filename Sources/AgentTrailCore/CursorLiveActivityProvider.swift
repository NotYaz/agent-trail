import Darwin
import Foundation

/// Live status for Cursor app agent chats (Cursor 3.29 and later), from the
/// transcript Cursor writes for each chat and the running Cursor app.
///
/// Cursor keeps each chat's transcript in the Cursor home (`~/.cursor`):
/// `projects/<slug>/agent-transcripts/<id>/<id>.jsonl`. The app writes it
/// itself: about a second into a turn it writes the turn so far, ending with
/// your message, and when the turn ends it appends the rest and a
/// `{"type":"turn_ended",...}` line (status `success`, `error` or `aborted`;
/// Stop ends a turn too), as a live trace on 3.29.15 and Cursor's code show.
/// So a chat whose transcript ends with a message line is in a turn.
///
/// A turn whose app quit or crashed never gets its `turn_ended`. So a chat
/// counts only while a Cursor app instance for the profile's data folder is
/// running and started no later than the transcript was written; a relaunched
/// Cursor starts after a stale write. The chat's folder comes from Cursor's
/// own chat header (`composerHeaders`, else `composerData:<id>`) in the
/// profile's `state.vscdb`, opened under the history reader's rules (a WAL
/// database only while its `-wal` and `-shm` exist) and only for chats in an
/// open turn. Only the opening bytes of a transcript's last line are read, so
/// prompts are never loaded.
///
/// Not detectable, so never claimed: Needs input (no line marks an approval
/// or a question, and 3.29 runs tools without asking by default), cloud and
/// background agents (no local transcript), and Cursor CLI sessions.
/// Subagent transcripts are not listed: their parent's turn stays Working
/// while they run. Cursor's saved chat status is not used: it reads `aborted`
/// for the whole of a running turn. A turn whose closing write failed while
/// Cursor kept running shows as Working until the chat's next turn ends.
/// Nothing is written anywhere.
public final class CursorLiveActivityProvider {
    private let processStartTimes: (Set<Int32>) -> [Int32: UInt64]
    private let cursorApps: () -> [CursorApp]
    private let folderLookup: (URL, [String]) -> [String: String]
    private let files = FileManager.default

    /// File times and process start times are compared with this much slack.
    static let clockSlack: TimeInterval = 2
    /// Cursor's app, which Jump brings forward.
    static let cursorBundleID = "com.todesktop.230313mzl4w4u92"
    /// How far back from a transcript's end the reader looks for the start of
    /// its last line before giving up on it.
    static let maximumLineScan = 4 << 20

    /// A running Cursor app instance: its PID, start time in microseconds, and
    /// the data folder it was started with (`--user-data-dir`), if any.
    public struct CursorApp: Equatable {
        public let pid: Int32
        public let start: UInt64
        public let userDataDirectory: String?

        public init(pid: Int32, start: UInt64, userDataDirectory: String?) {
            self.pid = pid
            self.start = start
            self.userDataDirectory = userDataDirectory
        }

        var started: Date { Date(timeIntervalSince1970: Double(start) / 1_000_000) }
    }

    /// `folderLookup` maps chat ids to their folders from a Cursor data
    /// folder; tests inject it, the app reads `state.vscdb`.
    public init(processStartTimes: ((Set<Int32>) -> [Int32: UInt64])? = nil,
                cursorApps: (() -> [CursorApp])? = nil,
                folderLookup: ((URL, [String]) -> [String: String])? = nil) {
        self.processStartTimes = processStartTimes ?? GrokLiveActivityProvider.readProcessStartTimes
        self.cursorApps = cursorApps ?? Self.readCursorApps
        self.folderLookup = folderLookup ?? { Self.readFolders($0, ids: $1) }
    }

    public func scan(sources: [AgentSource], now: Date = Date()) -> LiveSnapshot {
        var sessions: [LiveAgentSession] = []
        var starts: [Int32: UInt64] = [:]
        let apps = cursorApps()
        for source in sources where source.assistant == .cursor {
            guard let data = CursorActivityProvider.cursorFolder(source),
                  let app = Self.instance(for: data, among: apps) else { continue }
            let home = URL(fileURLWithPath: canonicalPath(source.configDirectory), isDirectory: true)
            let open = openTurns(home: home, since: app.started.addingTimeInterval(-Self.clockSlack), now: now)
            guard !open.isEmpty else { continue }
            let folders = folderLookup(data, open.map(\.id))
            for turn in open {
                guard let folder = folders[turn.id] else { continue }
                starts[app.pid] = app.start
                sessions.append(LiveAgentSession(sourceID: source.id, projectPath: folder, workspacePath: folder,
                    sessionID: turn.id, status: .working, updatedAt: turn.written, pid: app.pid,
                    details: LiveSessionDetails(stateSince: turn.written, hostBundleID: Self.cursorBundleID)))
            }
        }
        // Verify presence again after reading the transcripts.
        let finalStarts = processStartTimes(Set(sessions.map(\.pid)))
        sessions.removeAll { finalStarts[$0.pid] != starts[$0.pid] }
        sessions.sort {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        return LiveSnapshot(sessions: sessions, notices: [], scannedAt: now)
    }

    /// The earliest-started running Cursor instance that uses `data`: one
    /// started with that `--user-data-dir`, or without one for Cursor's
    /// default folder. Any instance started before a write could have made it.
    static func instance(for data: URL, among apps: [CursorApp]) -> CursorApp? {
        let wanted = canonicalPath(data.path)
        let defaultFolder = AssistantKind.cursor.descriptor.defaultUserDataDirectory.map {
            canonicalPath(($0 as NSString).expandingTildeInPath)
        }
        return apps.filter { app in
            if let folder = app.userDataDirectory { return canonicalPath((folder as NSString).expandingTildeInPath) == wanted }
            return wanted == defaultFolder
        }.min { $0.start < $1.start }
    }

    struct OpenTurn: Equatable {
        let id: String
        let written: Date
    }

    /// Chats whose transcript ends with a message line written since `since`.
    func openTurns(home: URL, since: Date, now: Date) -> [OpenTurn] {
        let projects = home.appendingPathComponent("projects", isDirectory: true)
        guard let slugs = try? files.contentsOfDirectory(atPath: projects.path) else { return [] }
        var turns: [OpenTurn] = []
        for slug in slugs where !slug.hasPrefix(".") {
            let folder = projects.appendingPathComponent(slug, isDirectory: true)
                .appendingPathComponent("agent-transcripts", isDirectory: true)
            guard FileStat.of(folder.path)?.kind == .directory,
                  let chats = try? files.contentsOfDirectory(atPath: folder.path) else { continue }
            for id in chats where CursorActivityProvider.isSafeID(id) {
                let transcript = folder.appendingPathComponent(id, isDirectory: true).appendingPathComponent("\(id).jsonl")
                guard let stat = FileStat.of(transcript.path), stat.kind == .regular,
                      stat.modified >= since, stat.modified <= now.addingTimeInterval(5),
                      Self.lastLine(of: transcript, size: stat.size) == .message else { continue }
                turns.append(OpenTurn(id: id, written: stat.modified))
            }
        }
        return turns
    }

    /// Running Cursor app processes of this user: the `Cursor` executable
    /// inside an app bundle, with start times and `--user-data-dir`. Only
    /// names, owners, start times, the executable path and that argument are
    /// kept.
    static func readCursorApps() -> [CursorApp] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        // Returns a count of PIDs, not bytes.
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        var name = [UInt8](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        var apps: [CursorApp] = []
        for pid in pids.prefix(min(Int(count), pids.count)) where pid > 0 {
            let length = proc_name(pid, &name, UInt32(name.count))
            guard length > 0, String(bytes: name[..<min(Int(length), name.count)], encoding: .utf8) == "Cursor" else { continue }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_status != SZOMB,
                  info.pbi_start_tvusec < 1_000_000, info.pbi_start_tvsec <= UInt64.max / 1_000_000,
                  let identity = ProcessIdentity.read(pid: pid),
                  identity.executablePath.hasSuffix(".app/Contents/MacOS/Cursor") else { continue }
            apps.append(CursorApp(pid: pid, start: info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec,
                                  userDataDirectory: identity.userDataDirectory))
        }
        return apps
    }

    /// Each chat's folder from Cursor's chat header, else its chat record:
    /// `workspaceIdentifier.uri.fsPath` for a `file` workspace, else the first
    /// tracked Git repository. Values are reduced inside SQLite.
    static func readFolders(_ data: URL, ids: [String]) -> [String: String] {
        let database = data.appendingPathComponent("User/globalStorage/state.vscdb")
        // A rollback-journal database is left alone within 5 s of a change, as history does.
        let opened = CursorActivityProvider.open(database, quietInterval: 5)
        guard let reader = opened.reader, !ids.isEmpty else { return [:] }
        let ids = Array(ids.prefix(opened.limits.batchSize))
        let folder = """
            CASE WHEN json_valid(v) THEN coalesce(
                CASE WHEN json_extract(v, '$.workspaceIdentifier.uri.scheme') = 'file'
                    THEN json_extract(v, '$.workspaceIdentifier.uri.fsPath') END,
                json_extract(v, '$.trackedGitRepos[0].repoPath')) END
            """
        var folders: [String: String] = [:]
        func add(_ rows: [[ReadOnlySQLite.Value]]) {
            for row in rows where row.count == 2 {
                guard let id = row[0].string, folders[id] == nil, let raw = row[1].string,
                      let path = CheckoutPath.absolute(raw) else { continue }
                folders[id] = path
            }
        }
        if reader.tableExists("composerHeaders") {
            let marks = Array(repeating: "?", count: ids.count).joined(separator: ", ")
            let sql = "SELECT composerId, \(folder) FROM (SELECT composerId, CAST(value AS TEXT) AS v FROM composerHeaders WHERE composerId IN (\(marks)))"
            add((try? reader.rows(sql, bindings: ids.map { .text($0) }, maximumColumnBytes: 4_096,
                                  deadline: opened.limits.deadline)) ?? [])
        }
        let missing = ids.filter { folders[$0] == nil }
        if !missing.isEmpty {
            let marks = Array(repeating: "?", count: missing.count).joined(separator: ", ")
            let sql = "SELECT substr(k, 14), \(folder) FROM (SELECT key AS k, CAST(value AS TEXT) AS v FROM cursorDiskKV WHERE key IN (\(marks)))"
            add((try? reader.rows(sql, bindings: missing.map { .text("composerData:" + $0) }, maximumColumnBytes: 4_096,
                                  deadline: opened.limits.deadline)) ?? [])
        }
        return folders
    }

    enum LastLine: Equatable {
        /// `{"role":...}`: a message. The turn is open.
        case message
        /// `{"type":"turn_ended",...}`.
        case turnEnded
        /// Empty, unreadable, or a kind this version does not know.
        case other
    }

    /// The kind of a transcript's last non-empty line, from its opening bytes
    /// only. The line's start is found by reading backwards from the end in
    /// chunks, up to `maximumLineScan`.
    static func lastLine(of url: URL, size: UInt64) -> LastLine {
        guard size > 0, let handle = try? FileHandle(forReadingFrom: url) else { return .other }
        defer { try? handle.close() }
        let chunk = 65_536
        var end = Int64(clamping: size)
        var start: Int64?
        var scanned = 0
        var sawContent = false
        while end > 0, scanned < maximumLineScan {
            let from = max(0, end - Int64(chunk))
            guard (try? handle.seek(toOffset: UInt64(from))) != nil,
                  let data = try? handle.read(upToCount: Int(end - from)), !data.isEmpty else { return .other }
            scanned += data.count
            var index = data.endIndex
            while index > data.startIndex {
                let previous = data.index(before: index)
                let byte = data[previous]
                if byte == 0x0A {
                    if sawContent {
                        start = from + Int64(data.distance(from: data.startIndex, to: index))
                        break
                    }
                } else if byte != 0x0D && byte != 0x20 && byte != 0x09 {
                    sawContent = true
                }
                index = previous
            }
            if start != nil { break }
            end = from
        }
        if start == nil {
            // The whole file is one line, or its start lies beyond the scan.
            guard sawContent, end == 0 else { return .other }
            start = 0
        }
        guard let lineStart = start, (try? handle.seek(toOffset: UInt64(lineStart))) != nil,
              let opening = try? handle.read(upToCount: 32) else { return .other }
        let text = String(decoding: opening, as: UTF8.self)
        if text.hasPrefix("{\"type\":\"turn_ended\"") { return .turnEnded }
        if text.hasPrefix("{\"role\":") { return .message }
        return .other
    }
}
