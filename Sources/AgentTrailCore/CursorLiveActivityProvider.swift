import Darwin
import Foundation

/// Live status for Cursor app agent chats (Cursor 3.29 and later), from the
/// running Cursor app, its chat database, and each chat's transcript.
///
/// Cursor marks a chat's run in the chat's record, `composerData:<id>` in the
/// profile's `state.vscdb`. When you send a message it saves the chat with
/// `unfinishedRunAt`, the time you sent it (its `status` then reads
/// `aborted`, so a crash leaves an honest record); when the turn ends or you
/// press Stop, it saves the chat again without it (after a quit mid-turn, the
/// relaunched Cursor does, within a minute). A chat with
/// `unfinishedRunAt` is Working since that time. A chat is Needs input while
/// its newest message is an `ask_question` call whose answer is still
/// `pending`, or while its row in Cursor's chat-header table says
/// `hasBlockingPendingActions` (a question or an approval waiting; Cursor
/// sets it for an approval about 8 s after the prompt opens). A live trace on
/// 3.29.15 and Cursor's code agree on all of this.
///
/// Only runs since the profile's running Cursor app started count: an app
/// that quit or crashed mid-turn left markers older than the app now running.
/// That app is a launchd-parented `Cursor` process matched to the profile's
/// data folder by `--user-data-dir`. The chats read are the most recently
/// updated main-chat and side-chat rows of the chat-header table, chats shown on the last
/// scan, and (capped) chats whose transcript changed or ends with a message;
/// each is read by key and reduced inside SQLite. The database is read only
/// while its `-wal` and `-shm` exist (lstat) and only in WAL mode, asked of
/// SQLite; no file handle of ours touches it, since closing one would drop
/// this process's SQLite locks on the file.
///
/// Each chat's transcript, `~/.cursor/projects/<slug>/agent-transcripts/<id>/<id>.jsonl`
/// (the app writes there whatever Cursor CLI home a profile names), ends with
/// `{"type":"turn_ended",...}` when a turn ends; one written more than
/// `endMargin` after a run was sent ends that run before the record is saved
/// again. While the database is busy the last scan's report stays; when it
/// can't be read, a transcript ending with a message line, written since the
/// app started, shows a chat whose folder is known as Working. To find a transcript's last line the reader reads backwards from
/// its end, so a prompt can pass through memory; only the line's first 32
/// bytes are compared, nothing else is kept, and a transcript is read again
/// only after its size or time changes.
///
/// A subagent the agent's Task tool starts shows through its parent: the
/// parent is Working while it runs, and Needs input while it waits for
/// approval (Cursor ORs a subagent's `hasBlockingPendingActions` into its
/// parent's header, up to the root). A subagent sent to the background
/// outlives its parent's turn; while the task's entry in the parent's header
/// pages reads `grouping.taskStatus` "running", the parent is Working in
/// background (the entry may sit on any page written since the app started,
/// up to `maximumPagesRead`). A side chat is stored like a subagent (type
/// "side-chat") but you drive it yourself and it runs on its own, so it shows
/// on its own; Jump opens it through its parent. A side chat's transcript sits
/// in its parent's `subagents` folder and is not read.
///
/// Not shown: Task subagents themselves, cloud
/// and background agents (`createdFromBackgroundAgent`), remote and
/// multi-root workspaces, and Cursor CLI
/// sessions. A run orphaned by a window crash or reload while Cursor keeps
/// running keeps its marker until Cursor saves that chat again, and stays
/// Working until then. Nothing is written anywhere.
public final class CursorLiveActivityProvider {
    private let processStartTimes: (Set<Int32>) -> [Int32: UInt64]
    private let cursorApps: () -> [CursorApp]
    private let transcriptHome: URL
    private let files = FileManager.default
    /// Each transcript's last-line kind, by path, while its size and time stay the same.
    private var lines: [String: (size: UInt64, modified: Date, kind: LastLine)] = [:]
    /// Chats shown on the last scan, by profile: they are read again until they end.
    private var shown: [String: Set<String>] = [:]
    /// Chat folders seen, by profile and chat id, for scans the database can't serve.
    private var folders: [String: String] = [:]
    /// When a chat was first seen blocked, by profile and chat id: the flag records no time.
    private var blockedSince: [String: Date] = [:]
    /// The last scan's report per profile, kept through a scan the database is busy for.
    private var lastReport: [String: [Reported]] = [:]

    struct Reported: Equatable {
        let id: String
        let status: LiveStatus
        let since: Date
        let folder: String
        var parent: String?
        var background: Date?
    }

    /// What `readStates` found.
    enum ReadResult {
        case states([String: ChatState])
        /// Busy or past a deadline: try again next scan.
        case busy
        /// Not a WAL database with its `-wal` and `-shm` now, or unreadable.
        case unavailable
    }

    /// File times and process start times are compared with this much slack.
    static let clockSlack: TimeInterval = 2
    /// How many of a chat's header pages, newest first, one scan reads looking
    /// for a subagent still running in the background: 256 messages each.
    static let maximumPagesRead = 8
    /// `subagentInfo.subagentTypeName` of a side chat: a chat you open beside an
    /// agent and drive yourself. It runs on its own, not in its parent's turn.
    static let sideChatType = "side-chat"
    /// Cursor's app, which Jump brings forward.
    static let cursorBundleID = "com.todesktop.230313mzl4w4u92"
    /// How far back from a transcript's end the reader looks for the start of
    /// its last line before giving up on it.
    static let maximumLineScan = 1 << 20
    /// How many recently updated chats one scan reads, and at most how many
    /// more it adds for transcripts that changed or end with a message.
    static let candidateLimit = 32
    /// A transcript's `turn_ended` ends a run only when written this long
    /// after the run was sent, so the previous turn's end line, landing just
    /// after you send again, doesn't hide the new run.
    static let endMargin: TimeInterval = 2

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

    /// One chat's live markers, as `readStates` reduces them.
    struct ChatState: Equatable {
        var unfinishedRunAt: Int64?
        /// `lastUpdatedAt`: when the latest turn was sent.
        var updatedAt: Int64?
        /// A subagent a tool call started: it works for its parent, which shows instead.
        var isSubagent = false
        /// A side chat's parent chat. You drive a side chat yourself, so it shows on its own.
        var parent: String?
        /// The start of the oldest subagent this chat sent to the background that
        /// Cursor still marks running (`grouping.taskStatus` "running"), since `since`.
        var backgroundSince: Int64?
        /// A cloud or background agent's chat: its run is on Cursor's servers.
        var isBackground = false
        var folder: String?
        var blocking = false
        /// The newest message's tool, and whether its answer is still pending.
        var lastTool: String?
        var lastToolPending = false
        /// When the newest message started (`startedAtMs`).
        var lastStartedAt: Int64?
    }

    /// `transcriptHome` is where the app writes transcripts, `~/.cursor`.
    public init(processStartTimes: ((Set<Int32>) -> [Int32: UInt64])? = nil,
                cursorApps: (() -> [CursorApp])? = nil,
                transcriptHome: URL? = nil) {
        self.processStartTimes = processStartTimes ?? GrokLiveActivityProvider.readProcessStartTimes
        let scanner = CursorAppScanner()
        self.cursorApps = cursorApps ?? { scanner.scan() }
        self.transcriptHome = transcriptHome
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent(".cursor", isDirectory: true)
    }

    public func scan(sources: [AgentSource], now: Date = Date()) -> LiveSnapshot {
        var sessions: [LiveAgentSession] = []
        var starts: [Int32: UInt64] = [:]
        let apps = cursorApps()
        var seenLines: Set<String> = []
        var nextShown: [String: Set<String>] = [:]
        var nextFolders: [String: String] = [:]
        var nextBlocked: [String: Date] = [:]
        var nextReport: [String: [Reported]] = [:]
        /// Chats whose folder stays remembered: a recent transcript, or shown.
        var keep: Set<String> = []
        for source in sources where source.assistant == .cursor {
            guard let data = CursorActivityProvider.cursorFolder(source),
                  let app = Self.instance(for: data, among: apps) else { continue }
            let since = app.started.addingTimeInterval(-Self.clockSlack)
            let sinceMs = Int64((since.timeIntervalSince1970 * 1000).rounded(.down))
            let transcripts = recentTranscripts(since: since, now: now, seen: &seenLines)
            let key = { (id: String) in "\(source.id)\u{0}\(id)" }
            keep.formUnion(transcripts.keys.map(key))
            // Besides recently updated chats: chats shown last scan, then transcripts
            // that changed or end with a message, newest first, capped.
            let fresh = transcripts.filter { $0.value.changed || $0.value.kind == .message }
                .sorted { $0.value.written > $1.value.written }.prefix(Self.candidateLimit).map(\.key)
            let extra = Array(shown[source.id] ?? []).sorted() + fresh
            var reported: [Reported] = []
            let database = data.appendingPathComponent("User/globalStorage/state.vscdb")
            switch Self.readStates(database, since: sinceMs, extra: extra) {
            case .states(let states):
                for (id, state) in states where !state.isSubagent && !state.isBackground {
                    guard let folder = state.folder else { continue }
                    nextFolders[key(id)] = folder
                    let current = (state.updatedAt ?? 0) >= sinceMs || (state.unfinishedRunAt ?? 0) >= sinceMs
                    if current, state.lastTool == "ask_question", state.lastToolPending {
                        let at = Self.date(state.lastStartedAt ?? state.updatedAt) ?? now
                        reported.append(Reported(id: id, status: .waiting, since: at, folder: folder, parent: state.parent))
                    } else if current, state.blocking {
                        let first = blockedSince[key(id)] ?? now
                        nextBlocked[key(id)] = first
                        reported.append(Reported(id: id, status: .waiting, since: first, folder: folder, parent: state.parent))
                    } else if let run = state.unfinishedRunAt, run >= sinceMs,
                              !Self.endedEarly(transcripts[id], run: run, updatedAt: state.updatedAt) {
                        reported.append(Reported(id: id, status: .working, since: Self.date(run) ?? now, folder: folder,
                                                 parent: state.parent))
                    } else if let background = state.backgroundSince.flatMap(Self.date) {
                        // The turn ended, but a subagent it sent to the background still runs.
                        reported.append(Reported(id: id, status: .working, since: background, folder: folder,
                                                 parent: state.parent, background: background))
                    }
                }
            case .busy:
                // Cursor is writing: keep the last report, and when each wait began.
                reported = lastReport[source.id] ?? []
                for item in reported where item.status == .waiting {
                    if let first = blockedSince[key(item.id)] { nextBlocked[key(item.id)] = first }
                }
            case .unavailable:
                // The transcripts alone, for chats whose folder is known.
                for (id, transcript) in transcripts where transcript.kind == .message {
                    guard let folder = folders[key(id)] else { continue }
                    nextFolders[key(id)] = folder
                    reported.append(Reported(id: id, status: .working, since: transcript.written, folder: folder))
                }
            }
            nextReport[source.id] = reported
            for item in reported {
                starts[app.pid] = app.start
                nextShown[source.id, default: []].insert(item.id)
                keep.insert(key(item.id))
                sessions.append(LiveAgentSession(sourceID: source.id, projectPath: item.folder, workspacePath: item.folder,
                    sessionID: item.id, status: item.status, updatedAt: item.since, pid: app.pid,
                    details: LiveSessionDetails(stateSince: item.since, hostBundleID: Self.cursorBundleID,
                                                parentThreadID: item.parent, backgroundSince: item.background)))
            }
        }
        lines = lines.filter { seenLines.contains($0.key) }
        shown = nextShown
        folders = folders.merging(nextFolders) { $1 }.filter { keep.contains($0.key) }
        blockedSince = nextBlocked
        lastReport = nextReport
        // Verify presence again after reading the database and transcripts.
        let finalStarts = processStartTimes(Set(sessions.map(\.pid)))
        sessions.removeAll { finalStarts[$0.pid] != starts[$0.pid] }
        sessions.sort {
            let left = LiveSessionRanking.order($0.status), right = LiveSessionRanking.order($1.status)
            if left != right { return left < right }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        return LiveSnapshot(sessions: sessions, notices: [], scannedAt: now)
    }

    static func date(_ milliseconds: Int64?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }

    /// The transcript's `turn_ended`, written more than `endMargin` after the
    /// run was sent, has ended the run before Cursor saved the record again.
    static func endedEarly(_ transcript: (written: Date, kind: LastLine, changed: Bool)?, run: Int64, updatedAt: Int64?) -> Bool {
        guard let transcript, transcript.kind == .turnEnded else { return false }
        let sent = Double(max(run, updatedAt ?? run)) / 1000
        return transcript.written.timeIntervalSince1970 > sent + endMargin
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

    /// Main-chat transcripts written since `since`: when, and their last line's kind.
    /// `seen` collects the transcripts looked at, to prune the memo.
    func recentTranscripts(since: Date, now: Date, seen: inout Set<String>)
        -> [String: (written: Date, kind: LastLine, changed: Bool)] {
        let projects = transcriptHome.appendingPathComponent("projects", isDirectory: true)
        guard let slugs = try? files.contentsOfDirectory(atPath: projects.path) else { return [:] }
        var found: [String: (written: Date, kind: LastLine, changed: Bool)] = [:]
        for slug in slugs where !slug.hasPrefix(".") {
            let folder = projects.appendingPathComponent(slug, isDirectory: true)
                .appendingPathComponent("agent-transcripts", isDirectory: true)
            guard FileStat.of(folder.path)?.kind == .directory,
                  let chats = try? files.contentsOfDirectory(atPath: folder.path) else { continue }
            for id in chats where CursorActivityProvider.isSafeID(id) {
                let transcript = folder.appendingPathComponent(id, isDirectory: true).appendingPathComponent("\(id).jsonl")
                guard let stat = FileStat.of(transcript.path), stat.kind == .regular,
                      stat.modified >= since, stat.modified <= now.addingTimeInterval(5) else { continue }
                seen.insert(transcript.path)
                let kind: LastLine
                let changed: Bool
                if let known = lines[transcript.path], known.size == stat.size, known.modified == stat.modified {
                    kind = known.kind
                    changed = false
                } else {
                    kind = Self.lastLine(of: transcript, size: stat.size)
                    lines[transcript.path] = (stat.size, stat.modified, kind)
                    changed = true
                }
                if let earlier = found[id], earlier.written >= stat.modified { continue }
                found[id] = (stat.modified, kind, changed)
            }
        }
        return found
    }

    /// The chat's folder, reduced inside SQLite from a chat record `v`: the
    /// folder of a `file` workspace (`fsPath`, else `path`), or, for a chat
    /// with no workspace folder, its first tracked Git repository. A remote
    /// workspace (any other scheme) has no folder on this Mac, and a
    /// multi-root workspace (`configPath`) no single one.
    static let folderSQL = """
        CASE WHEN json_type(v, '$.workspaceIdentifier.uri') IS NOT NULL THEN
                CASE WHEN json_extract(v, '$.workspaceIdentifier.uri.scheme') = 'file'
                    THEN coalesce(json_extract(v, '$.workspaceIdentifier.uri.fsPath'),
                                  json_extract(v, '$.workspaceIdentifier.uri.path')) END
            WHEN json_type(v, '$.workspaceIdentifier.configPath') IS NOT NULL THEN NULL
            ELSE json_extract(v, '$.trackedGitRepos[0].repoPath') END
        """

    /// Live markers of the chats to look at: the `candidateLimit` most
    /// recently updated main-chat and side-chat header rows since `since` (milliseconds),
    /// then `extra`. The database is opened only when its `-wal` and `-shm`
    /// exist (checked with lstat), and its journal mode is read through SQLite,
    /// never through a file handle of our own: closing one would drop this
    /// process's SQLite locks on the file.
    static func readStates(_ database: URL, since: Int64, extra: [String]) -> ReadResult {
        guard FileStat.of(database.path)?.kind == .regular,
              FileStat.of(database.path + "-wal")?.kind == .regular,
              FileStat.of(database.path + "-shm")?.kind == .regular,
              let reader = ReadOnlySQLite(url: database, maximumValueBytes: CursorActivityProvider.ReadLimits.wal.maximumValueBytes) else {
            return .unavailable
        }
        let limits = CursorActivityProvider.ReadLimits.wal
        let deadline = limits.deadline
        do {
            guard try reader.rows("PRAGMA journal_mode", maximumColumnBytes: 64, deadline: deadline).first?.first?.string?
                    .lowercased() == "wal" else { return .unavailable }
            var ids: [String] = []
            let headers = reader.columns(of: "composerHeaders")
            if headers.isSuperset(of: ["composerId", "value"]) {
                let updated = headers.contains("recency") ? "coalesce(lastUpdatedAt, recency, 0)" : "coalesce(lastUpdatedAt, 0)"
                // Main chats and side chats; a tool call's subagent shows through its parent.
                let side = headers.contains("subagentTypeName") ? " OR subagentTypeName = '\(sideChatType)'" : ""
                let main = headers.contains("isSubagent") ? " AND (coalesce(isSubagent, 0) = 0\(side))" : ""
                for row in try reader.rows("SELECT composerId FROM composerHeaders WHERE \(updated) >= ?1\(main) ORDER BY \(updated) DESC LIMIT \(candidateLimit)",
                                           bindings: [.integer(since)], maximumColumnBytes: 4_096, deadline: deadline) {
                    if let id = row.first?.string, CursorActivityProvider.isSafeID(id) { ids.append(id) }
                }
            }
            for id in extra where CursorActivityProvider.isSafeID(id) && !ids.contains(id) { ids.append(id) }
            // The blocked flag, parsed only for the chats read.
            var blocking: [String: Bool] = [:]
            if headers.isSuperset(of: ["composerId", "value"]) {
                let flag = "CASE WHEN json_valid(value) THEN coalesce(json_extract(value, '$.hasBlockingPendingActions'), 0) ELSE 0 END"
                for start in stride(from: 0, to: ids.count, by: max(1, limits.batchSize)) {
                    let batch = Array(ids[start..<min(start + limits.batchSize, ids.count)])
                    let marks = Array(repeating: "?", count: batch.count).joined(separator: ", ")
                    for row in try reader.rows("SELECT composerId, \(flag) FROM composerHeaders WHERE composerId IN (\(marks))",
                                               bindings: batch.map { .text($0) }, maximumColumnBytes: 4_096, deadline: deadline)
                        where row.count == 2 {
                        if let id = row[0].string { blocking[id] = row[1].int == 1 }
                    }
                }
            }
            let recordSQL = """
                SELECT k, json_extract(v, '$.unfinishedRunAt'), json_extract(v, '$.lastUpdatedAt'),
                    json_extract(v, '$.subagentInfo.parentComposerId') IS NOT NULL
                        AND coalesce(json_extract(v, '$.subagentInfo.subagentTypeName'), '') <> '\(sideChatType)',
                    CASE WHEN json_extract(v, '$.subagentInfo.subagentTypeName') = '\(sideChatType)'
                        THEN json_extract(v, '$.subagentInfo.parentComposerId') END,
                    coalesce(json_type(v, '$.createdFromBackgroundAgent') = 'object'
                        AND json_extract(v, '$.createdFromBackgroundAgent') <> '{}', 0),
                    \(folderSQL),
                    json_extract(v, '$.fullConversationHeadersOnly[#-1].bubbleId'),
                    json_extract(v, '$.fullConversationHeadersOnly[#-1].startedAtMs'),
                    json_extract(v, '$.createdAt')
                FROM (SELECT key AS k, CAST(value AS TEXT) AS v FROM cursorDiskKV WHERE key IN (%KEYS%)) WHERE json_valid(v)
                """
            let records = try CursorActivityProvider.keyedRows(reader, keys: ids.map { "composerData:" + $0 },
                                                               sql: recordSQL, limits: limits)
            // Cursor 3.29 keeps a chat's message list in header pages of 256
            // entries, in time order. Per page: its newest message, the start of
            // its first, and its oldest subagent task still marked running in the
            // background that started since `?2`.
            let pageKeysSQL = "SELECT key FROM cursorDiskKV WHERE key >= ?1 AND key < ?2 ORDER BY key DESC LIMIT \(maximumPagesRead)"
            let pageSQL = """
                SELECT json_extract(v, '$[#-1].bubbleId'), json_extract(v, '$[#-1].startedAtMs'), json_extract(v, '$[0].startedAtMs'),
                    (SELECT min(json_extract(e.value, '$.startedAtMs')) FROM json_each(v) AS e
                        WHERE e.type = 'object' AND json_extract(e.value, '$.grouping.toolCallCase') = 'taskToolCall'
                            AND json_extract(e.value, '$.grouping.taskStatus') = 'running'
                            AND json_extract(e.value, '$.startedAtMs') >= ?2)
                FROM (SELECT CAST(value AS TEXT) AS v FROM cursorDiskKV WHERE key = ?1)
                WHERE json_valid(v) AND json_type(v) = 'array'
                """
            let bubbleSQL = "SELECT json_extract(v, '$.toolFormerData.name'), json_extract(v, '$.toolFormerData.additionalData.status') FROM (SELECT CAST(value AS TEXT) AS v FROM cursorDiskKV WHERE key = ?1) WHERE json_valid(v)"
            var states: [String: ChatState] = [:]
            for id in ids {
                guard let row = records.rows["composerData:" + id], row.count == 9 else { continue }
                var state = ChatState(unfinishedRunAt: row[0].int, updatedAt: row[1].int, isSubagent: row[2].int == 1,
                                      parent: row[3].string.flatMap { CursorActivityProvider.isSafeID($0) ? $0 : nil },
                                      isBackground: row[4].int == 1, folder: row[5].string.flatMap { CheckoutPath.absolute($0) },
                                      blocking: blocking[id] ?? false)
                guard !state.isSubagent, !state.isBackground else { states[id] = state; continue }
                // The newest message: the last header page (Cursor 3.29), else the inline list.
                var bubble = row[6].string
                state.lastStartedAt = row[7].int
                // A task counts only if it started since `since` and after the chat
                // itself was created: a fork copies its original's entries, and
                // nothing updates the copies.
                let taskBound = max(since, row[8].int ?? since)
                let pages = try reader.rows(pageKeysSQL, bindings: [.text("composerConvHeaders:\(id):"), .text("composerConvHeaders:\(id);")],
                                            maximumColumnBytes: 4_096, deadline: deadline).compactMap { $0.first?.string }
                for (index, key) in pages.enumerated() {
                    guard let page = try reader.rows(pageSQL, bindings: [.text(key), .integer(taskBound)], maximumColumnBytes: 4_096,
                                                     deadline: deadline).first, page.count == 4 else { continue }
                    if index == 0, let last = page[0].string {
                        bubble = last
                        state.lastStartedAt = page[1].int
                    }
                    if let start = page[3].int { state.backgroundSince = min(state.backgroundSince ?? start, start) }
                    // Pages before this one hold only messages from before `since`.
                    if let first = page[2].int, first < since { break }
                }
                if let bubble, CursorActivityProvider.isSafeBubbleID(bubble),
                   let body = try reader.rows(bubbleSQL, bindings: [.text("bubbleId:\(id):\(bubble)")], maximumColumnBytes: 4_096,
                                              deadline: deadline).first, body.count == 2 {
                    state.lastTool = body[0].string
                    state.lastToolPending = body[1].string == "pending"
                }
                states[id] = state
            }
            return .states(states)
        } catch let error where CursorActivityProvider.isTransient(error) {
            return .busy
        } catch {
            return .unavailable
        }
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

/// This user's running Cursor apps: a `Cursor` executable inside an app
/// bundle whose parent is launchd, as the GUI app's is (a `cursor` command run
/// from a terminal has a shell parent). Each process's arguments are read
/// once per PID and start time, for `--user-data-dir` only; its environment is
/// never parsed.
final class CursorAppScanner {
    /// By PID and start time: the app, or nil for a process that is not one.
    private var known: [String: CursorLiveActivityProvider.CursorApp?] = [:]

    func scan() -> [CursorLiveActivityProvider.CursorApp] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 64)
        // Returns a count of PIDs, not bytes.
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        var name = [UInt8](repeating: 0, count: 2 * Int(MAXCOMLEN) + 1)
        var apps: [CursorLiveActivityProvider.CursorApp] = []
        var seen: [String: CursorLiveActivityProvider.CursorApp?] = [:]
        for pid in pids.prefix(min(Int(count), pids.count)) where pid > 0 {
            let length = proc_name(pid, &name, UInt32(name.count))
            guard length > 0, String(bytes: name[..<min(Int(length), name.count)], encoding: .utf8) == "Cursor" else { continue }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_status != SZOMB,
                  info.pbi_ppid == 1,
                  info.pbi_start_tvusec < 1_000_000, info.pbi_start_tvsec <= UInt64.max / 1_000_000 else { continue }
            let start = info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
            let key = "\(pid):\(start)"
            let app: CursorLiveActivityProvider.CursorApp?
            if let remembered = known[key] {
                app = remembered
            } else if let identity = ProcessIdentity.readArguments(pid: pid),
                      identity.executablePath.hasSuffix(".app/Contents/MacOS/Cursor") {
                app = CursorLiveActivityProvider.CursorApp(pid: pid, start: start, userDataDirectory: identity.userDataDirectory)
            } else {
                app = nil
            }
            seen[key] = app
            if let app { apps.append(app) }
        }
        known = seen
        return apps
    }
}
