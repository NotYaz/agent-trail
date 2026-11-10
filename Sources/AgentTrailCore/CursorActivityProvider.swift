import Foundation

/// Read-only adapter for Cursor. One profile reads two stores.
///
/// The Cursor app, under the profile's Cursor user-data folder
/// (`~/Library/Application Support/Cursor` unless the profile names another):
/// `User/globalStorage/state.vscdb`, a SQLite database Cursor keeps open while
/// it runs. Its `cursorDiskKV` table holds `composerData:<id>`, one chat with
/// its ordered bubble list `fullConversationHeadersOnly`, and
/// `bubbleId:<id>:<bubble>`, one message or tool call. Cursor 3.29 (chat
/// version 18) leaves that list empty and keeps it instead in pages,
/// `composerConvHeaders:<id>:<page>` (`000000` first), each a JSON array of
/// the same headers; its bubble ids may carry a `/s:<n>` or `/t:<call id>`
/// suffix, and a call id can hold a newline. A chat with
/// pages is read from its pages. `cursorDiskKV` and
/// `ItemTable` are queried by key and key range only. The `composerHeaders`
/// table has no key range and is read in full. Every value is reduced with
/// `json_extract` inside SQLite (a header to its folder, parent, times and
/// flags), and only the bubbles a chat lists are read, so prompts, chat
/// titles, code and file contents never reach this process.
///
/// A listing reads each chat key with `octet_length(value)`, which SQLite
/// (3.43 and later) answers from the record header without loading the value.
/// It parses a chat's value only when the chat is new, its value's length
/// changed, its header's `lastUpdatedAt` moved past the recorded one, or it was
/// updated within the last day. The first listing after launch, and one an
/// hour after that, parses every chat.
///
/// The database header's bytes 18 and 19 give the journal mode: 2 for WAL, 1
/// for a rollback journal.
/// - WAL (Cursor 3.x): readers never block Cursor's writes. The database is
///   opened only while its `-wal` and `-shm` files exist (Cursor is using it),
///   because a read-only connection would otherwise create a `-shm` file
///   there. A statement may run 10 s, look up 64 keys and read values up to
///   64 MB.
/// - Rollback journal (Cursor 2.x, or 3.x with WAL off): a statement holds a
///   shared lock that blocks Cursor's commits while it runs. Cursor gives up on
///   a write after 1 s busy, and a failed write makes it rebuild state.vscdb
///   without its chats when it quits; at launch it replaces the file with its
///   backup. So the database is read whether or not Cursor is open, but never
///   within 5 s of a change to it or to its `-journal` file (Cursor may be
///   launching or committing), checked before the listing and before each
///   chat. Each statement is interrupted after 200 ms (SQLite checks the
///   deadline every 1,000 steps), looks up at most 8 keys, and fails before
///   loading any value over 8 MB, which is reported as too large to index. No
///   lock is held between statements. Pre-3.0 workspace databases are read
///   the same way.
/// A busy database, or a statement interrupted at its deadline, stops the pass
/// for that database: nothing is marked unreadable, the cache keeps what it
/// had, and the next scan lists the database again. A chat whose reread was
/// interrupted waits behind the others next time. File modification times only
/// schedule reads; they never date or confirm an edit.
///
/// A chat's folder is, in order: the header's or chat's
/// `workspaceIdentifier` (a folder, or a `.code-workspace` file's folders),
/// `agentLocation.environment.uri`, `trackedGitRepos[0].repoPath`, the
/// `workspaceStorage/<id>/workspace.json` its header names, and for chats from
/// before Cursor 3.0 the workspace database whose `composer.composerData`
/// lists it. Remote, folderless and cloud-agent chats are skipped.
///
/// An `edit_file_v2` or `delete_file` bubble counts once its status is
/// `completed` and Cursor recorded a success artifact: the result's
/// `afterContentId` (3.x), `fileDeletedSuccessfully`, or (2.x) the chat's
/// `codeBlockData` entry for the bubble's code block with a `diffId` and
/// `lastAppliedAt`, not later rejected; else the file in `newlyCreatedFiles`.
/// `completed` alone is not proof. The edit id is the `toolCallId`, so copies of
/// one call in forked chats count once. The time is the bubble's `createdAt`,
/// else the code block's `lastAppliedAt`, else the nearest earlier bubble's
/// `createdAt`, else the chat's `lastUpdatedAt`. Cursor writes a new tool call
/// into the chat's last bubble while that bubble is still empty, so the call
/// keeps the `createdAt` the empty bubble got when the previous call started,
/// and a bubble with no tool name among a chat's last `pendingTail` is read
/// again with the chat's next change.
///
/// The Cursor CLI, under the profile's home (`~/.cursor`):
/// `chats/<md5>/<chatId>/meta.json` gives each session's folder (`cwd`) and
/// times. Its `store.db` is not read, so CLI sessions carry no edits.
///
/// Shell commands and file modification times are never evidence. The cache
/// keeps ids, times, hashes and file paths only.
public final class CursorActivityProvider: ActivityProvider {
    /// 2: nameless bubbles near a chat's end stay pending, and chats record
    /// their value's length.
    static let cacheVersion = 2
    /// Cursor's edit tools as its bubble store names them.
    static let editTools: Set<String> = ["edit_file_v2", "delete_file"]
    /// Tool statuses after which a bubble no longer changes.
    static let finalStatuses: Set<String> = ["completed", "error", "cancelled", "aborted", "rejected"]
    /// A listed bubble this close to the end of its chat may still change: its
    /// row may be on its way, or Cursor may still write a tool call into it
    /// while it has none. It is read again with the chat's next change.
    static let pendingTail = 16
    /// A chat updated this recently is parsed on every listing, since a change
    /// can keep its value's length.
    static let recentChat: TimeInterval = 86_400

    /// How hard one pass may read a database.
    struct ReadLimits: Equatable {
        /// Per statement. SQLite checks it every 1,000 steps.
        var deadline: TimeInterval
        /// Keys per batched lookup.
        var batchSize: Int
        /// The connection's largest value. A larger one fails before it is loaded.
        var maximumValueBytes: Int32

        static let wal = ReadLimits(deadline: 10, batchSize: 64, maximumValueBytes: 64 * 1_048_576)
        /// Far below Cursor's 1 s busy timeout: see the type's comment.
        static let rollback = ReadLimits(deadline: 0.2, batchSize: 8, maximumValueBytes: 8 * 1_048_576)
    }

    private let cache: HistoryCache<CursorFile>
    private let files = FileManager.default
    private let resolver: GitProjectResolver
    private let ownsResolver: Bool
    /// A database that changed is listed again at most this often. An open
    /// Cursor writes its database often; a listing reads every chat's header.
    var minimumRelistInterval: TimeInterval = 30
    /// Every chat is parsed again this often, beside the first listing after launch.
    var fullRelistInterval: TimeInterval = 3_600
    /// How a pass reads a rollback-journal database.
    var rollbackLimits = ReadLimits.rollback
    /// A rollback-journal database changed this recently is left alone: Cursor
    /// may be launching or committing.
    var rollbackQuietInterval: TimeInterval = 5
    private var lastListing: [String: Date] = [:]
    private var lastFullListing: [String: Date] = [:]
    /// Chats whose reread hit its deadline, by cache key: they are reread last.
    private var deferrals: [String: Int] = [:]

    public var projectLocations: ProjectLocationRegistry {
        get { resolver.locations }
        set { resolver.reset(locations: newValue) }
    }

    public convenience init(cacheURL: URL? = nil, projectLocations: ProjectLocationRegistry = .init()) {
        self.init(cacheURL: cacheURL, resolver: GitProjectResolver(locations: projectLocations), ownsResolver: true)
    }

    /// A shared resolver is reset by its owner once per scan.
    init(cacheURL: URL?, resolver: GitProjectResolver, ownsResolver: Bool = false) {
        cache = HistoryCache(url: cacheURL, version: Self.cacheVersion, name: "Cursor")
        self.resolver = resolver
        self.ownsResolver = ownsResolver
    }

    /// Sessions from cached evidence only, so they appear where the last scan put them.
    public func metadata(sources: [AgentSource]) -> ScanResult {
        if ownsResolver { resolver.reset() }
        let discovered = discover(sources: sources)
        return result(discovered, notices: discovered.notices)
    }

    public func scan(sources: [AgentSource]) -> ScanResult {
        scan(sources: sources, progress: nil)
    }

    public func scan(sources: [AgentSource], progress: ((ScanResult, Int, Int) -> Void)?) -> ScanResult {
        if ownsResolver { resolver.reset() }
        let discovered = discover(sources: sources)
        var notices = discovered.notices + (cache.takeLoadNotice().map { [$0] } ?? [])
        var active: Set<String> = []
        for session in discovered.cli {
            active.insert(session.meta.path)
            refreshMeta(session.meta)
        }
        var listings: [StoreListing] = []
        for store in discovered.stores {
            active.insert(store.database.path)
            if let listing = list(store, active: &active, notices: &notices) { listings.append(listing) }
        }
        var tasks: [(Int, ComposerTask)] = []
        for (offset, listing) in listings.enumerated() {
            tasks += listing.tasks.map { (offset, $0) }
        }
        var interrupted: Set<Int> = []
        var lastProgress = Date.distantPast
        for (index, task) in tasks.enumerated() {
            let listing = listings[task.0]
            if !interrupted.contains(task.0) {
                let key = Self.composerKey(listing.store.database, task.1.id)
                do {
                    // Cursor may be launching or committing: leave the database alone.
                    if listing.rollback, Self.recentlyWritten(listing.store.database, within: rollbackQuietInterval) {
                        throw ReadOnlySQLite.Failure.busy
                    }
                    try reread(task.1, in: listing)
                    deferrals[key] = nil
                } catch {
                    // Busy, or past a statement's deadline: the rest of this
                    // database waits for the next refresh, and a chat that ran
                    // out of time waits behind the others.
                    if case .interrupted? = error as? ReadOnlySQLite.Failure { deferrals[key, default: 0] += 1 }
                    interrupted.insert(task.0)
                    notices.append("\(listing.store.source.name): Cursor's chat database was busy; the next refresh reads the rest.")
                }
            }
            let completed = index + 1
            if let progress, completed == tasks.count || Date().timeIntervalSince(lastProgress) >= 0.5 {
                progress(result(discovered, notices: notices), completed, tasks.count)
                lastProgress = Date()
            }
        }
        // Only a finished pass records the database's stamp, so an
        // interrupted one is listed again.
        for (offset, listing) in listings.enumerated() where !interrupted.contains(offset) {
            let key = listing.store.database.path
            let entry = cache[key] ?? CursorFile()
            var state = entry.store ?? CursorStoreState()
            state.stamp = listing.stamp
            entry.store = state
            cache.store(entry, at: key, changed: true)
        }
        cache.prune(keeping: active)
        if let notice = cache.saveIfDue() { notices.append(notice) }
        return result(discovered, notices: notices)
    }

    @discardableResult
    public func saveCache() -> String? {
        cache.save()
    }

    // MARK: Discovery

    private struct IDEStore {
        let source: AgentSource
        /// `User/globalStorage/state.vscdb`.
        let database: URL
        /// The `User` folder.
        let user: URL
    }

    private struct CLISession {
        let source: AgentSource
        let id: String
        let meta: URL
    }

    private struct Discovered {
        var stores: [IDEStore] = []
        var cli: [CLISession] = []
        var notices: [String] = []
    }

    private func discover(sources: [AgentSource]) -> Discovered {
        var discovered = Discovered()
        for source in sources where source.assistant == .cursor {
            var found = false
            if let userData = Self.cursorFolder(source) {
                let user = userData.appendingPathComponent("User", isDirectory: true)
                let database = user.appendingPathComponent("globalStorage/state.vscdb")
                if FileStat.of(database.path)?.kind == .regular {
                    discovered.stores.append(IDEStore(source: source, database: database, user: user))
                    found = true
                }
            }
            found = discoverCLI(source, into: &discovered) || found
            if !found {
                discovered.notices.append("\(source.name): no local Cursor chat history was found.")
            }
        }
        return discovered
    }

    /// The profile's Cursor user-data folder: the one it names, or Cursor's
    /// default for a profile with the default Cursor home.
    static func cursorFolder(_ source: AgentSource) -> URL? {
        let descriptor = AssistantKind.cursor.descriptor
        let usesDefaultHome = canonicalPath(source.configDirectory) == canonicalPath(descriptor.defaultHome(home: "~"))
        guard let folder = source.userDataDirectory ?? (usesDefaultHome ? descriptor.defaultUserDataDirectory : nil) else {
            return nil
        }
        return URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Returns true when the home holds a CLI chats folder.
    private func discoverCLI(_ source: AgentSource, into discovered: inout Discovered) -> Bool {
        let home = URL(fileURLWithPath: (source.configDirectory as NSString).expandingTildeInPath, isDirectory: true)
        let root = home.appendingPathComponent("chats", isDirectory: true)
        guard let buckets = try? files.contentsOfDirectory(atPath: root.path) else { return false }
        for bucket in buckets.sorted() where Self.isBucket(bucket) {
            let folder = root.appendingPathComponent(bucket, isDirectory: true)
            guard let chats = try? files.contentsOfDirectory(atPath: folder.path) else { continue }
            for id in chats.sorted() where UUID(uuidString: id) != nil {
                let meta = folder.appendingPathComponent(id, isDirectory: true).appendingPathComponent("meta.json")
                guard FileStat.of(meta.path)?.kind == .regular else { continue }
                discovered.cli.append(CLISession(source: source, id: id, meta: meta))
            }
        }
        return true
    }

    /// A CLI workspace bucket: the MD5 of the workspace path in hex.
    static func isBucket(_ name: String) -> Bool {
        name.count == 32 && name.allSatisfy { $0.isHexDigit }
    }

    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Whether `composerSQL`'s header-page summary, `[count, first, last,
    /// length]`, lists at least one bubble.
    static func pagesListBubbles(_ summary: String?) -> Bool {
        guard let summary, let values = (try? JSONSerialization.jsonObject(with: Data(summary.utf8))) as? [Any],
              values.count == 4, let count = values[0] as? NSNumber, count.intValue > 0 else { return false }
        return values[1] is String
    }

    /// A bubble id. Cursor 3.29 names a reply's steps `<uuid>/s:<n>` and its
    /// tool calls `<uuid>/t:<toolCallId>`, and a tool call id can hold a
    /// newline (`call-<uuid>-0` and `fc_<uuid>_0` on two lines). Bubble ids
    /// are only bound as SQL parameters and used as cache keys, never as
    /// paths, so any visible ASCII character or a newline is accepted.
    static func isSafeBubbleID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 256 && id.unicodeScalars.allSatisfy { $0 == "\n" || (0x21...0x7E).contains($0.value) }
    }

    static func composerKey(_ database: URL, _ id: String) -> String {
        "\(database.path)#composer:\(id)"
    }

    // MARK: CLI sessions

    /// meta.json is small and rewritten whole; it is reread when its stamp changes.
    private func refreshMeta(_ url: URL) {
        let key = url.path
        let cached = cache[key]
        let file = cached ?? CursorFile()
        let before = (file.stamp, file.cli)
        if let stat = FileStat.of(url.path), stat.kind == .regular {
            let stamp = FileStamp(stat)
            if stamp != file.stamp {
                if stat.size > 262_144 {
                    file.stamp = stamp
                    file.cli = nil
                } else if let data = try? Data(contentsOf: url),
                          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    file.stamp = stamp
                    file.cli = CursorCLIMeta(object)
                }
                // Otherwise possibly mid-write: the next scan reads it again.
            }
        }
        cache.store(file, at: key, changed: cached == nil || file.stamp != before.0 || file.cli != before.1)
    }

    // MARK: Opening Cursor's databases

    /// One of Cursor's databases, opened for one pass, with the limits that
    /// pass reads it under.
    struct OpenedDatabase {
        var reader: ReadOnlySQLite?
        var limits = ReadLimits.wal
        /// False for a rollback journal.
        var wal = false
        /// Nothing was opened: a WAL database without its `-wal` and `-shm` files.
        var closedWAL = false
        /// Nothing was opened: a rollback-journal database that just changed.
        var settling = false
    }

    /// Opens one of Cursor's databases read-only. A database in WAL mode is
    /// opened only while its `-wal` and `-shm` files exist: without them a
    /// read-only connection would create a `-shm` file in Cursor's folder, or
    /// fail to open. A rollback-journal database is opened under `rollback`'s
    /// value cap, unless it changed within `quietInterval`.
    static func open(_ url: URL, rollback: ReadLimits = .rollback, quietInterval: TimeInterval = 0) -> OpenedDatabase {
        guard let wal = usesWAL(url) else { return OpenedDatabase() }
        if wal {
            guard FileStat.of(url.path + "-wal")?.kind == .regular,
                  FileStat.of(url.path + "-shm")?.kind == .regular else { return OpenedDatabase(wal: true, closedWAL: true) }
            return OpenedDatabase(reader: ReadOnlySQLite(url: url, maximumValueBytes: ReadLimits.wal.maximumValueBytes),
                                  limits: .wal, wal: true)
        }
        if recentlyWritten(url, within: quietInterval) { return OpenedDatabase(limits: rollback, settling: true) }
        return OpenedDatabase(reader: ReadOnlySQLite(url: url, maximumValueBytes: rollback.maximumValueBytes), limits: rollback)
    }

    /// True when a rollback-journal database or its `-journal` file changed
    /// within `interval`, so Cursor may be launching or committing. This only
    /// schedules a read; no edit is ever dated or confirmed by a file time.
    static func recentlyWritten(_ url: URL, within interval: TimeInterval, now: Date = Date()) -> Bool {
        guard interval > 0 else { return false }
        return [url.path, url.path + "-journal"].contains { path in
            guard let modified = FileStat.of(path)?.modified else { return false }
            return abs(now.timeIntervalSince(modified)) < interval
        }
    }

    /// Busy, or interrupted at a statement's deadline: stop the pass, keep the
    /// cache, and try again on the next scan. Never "unreadable".
    static func isTransient(_ error: Error) -> Bool {
        switch error as? ReadOnlySQLite.Failure {
        case .busy?, .interrupted?: return true
        default: return false
        }
    }

    /// True when the database header says WAL mode (bytes 18 and 19 are 2),
    /// false for a rollback journal (1); nil when the file is not a SQLite
    /// database.
    static func usesWAL(_ url: URL) -> Bool? {
        guard FileStat.of(url.path)?.kind == .regular, let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 100), data.count >= 20,
              Data(data.prefix(16)) == Data("SQLite format 3\u{0}".utf8) else { return nil }
        let start = data.startIndex
        return data[start + 18] == 2 || data[start + 19] == 2
    }

    // MARK: Listing

    private struct StoreListing {
        let store: IDEStore
        let reader: ReadOnlySQLite
        let stamp: CursorStoreStamp
        let tasks: [ComposerTask]
        let limits: ReadLimits
        /// A rollback-journal database: each chat waits while Cursor writes.
        let rollback: Bool
    }

    private struct ComposerTask {
        let id: String
        let fingerprint: UInt64
        /// The value's length, recorded once the reread finishes.
        let length: Int64?
    }

    /// A chat key the database lists. `length` is nil when this SQLite cannot
    /// tell it without loading the value.
    private struct ListedChat {
        let id: String
        let length: Int64?
    }

    /// One chat's header, from the `composerHeaders` table or ItemTable list,
    /// as `headerTableSQL` and `headerListSQL` reduce it.
    private struct Header {
        var identifier: Any?
        var location: Any?
        var repo: String?
        var workspaceIDs: [String] = []
        var parent: String?
        var created: Date?
        var updated: Date?
        var background = false

        /// `values`: the header's fields in the SQL's path order. `origin`:
        /// its `createdFromBackgroundAgent` is a non-empty object.
        init(_ values: [Any], origin: Bool, workspaceID: String?) {
            func field(_ index: Int) -> Any? {
                guard index < values.count, !(values[index] is NSNull) else { return nil }
                return values[index]
            }
            identifier = field(0)
            location = field(1)
            repo = field(2) as? String
            parent = (field(3) as? String).flatMap { CursorActivityProvider.isSafeID($0) ? $0 : nil }
            created = RecordedDate.milliseconds(field(4))
            updated = RecordedDate.milliseconds(field(5))
            background = origin || field(6) as? String == "background"
            var ids: [String] = []
            if let workspaceID, !workspaceID.isEmpty { ids.append(workspaceID) }
            if let id = (identifier as? [String: Any])?["id"] as? String, !id.isEmpty, !ids.contains(id) { ids.append(id) }
            workspaceIDs = ids
        }
    }

    /// The fields one listing reads from a chat's `composerData`, in the
    /// order of `composerSQL`'s paths.
    private struct ComposerFields {
        var created: Date?
        var updated: Date?
        var hasBubbles = false
        var identifier: Any?
        var location: Any?
        var repo: String?
        var worktree: String?
        var parent: String?
        var background = false

        init(_ values: [Any]) {
            func field(_ index: Int) -> Any? {
                guard index < values.count, !(values[index] is NSNull) else { return nil }
                return values[index]
            }
            created = RecordedDate.milliseconds(field(0))
            updated = [field(1), field(2)].compactMap { RecordedDate.milliseconds($0) }.max()
            hasBubbles = field(5) is String
            identifier = field(7)
            location = field(8)
            repo = field(9) as? String
            worktree = (field(10) as? String).flatMap { $0.hasPrefix("/") ? ProjectLocationRegistry.lexicalPath($0) : nil }
            parent = (field(11) as? String).flatMap { CursorActivityProvider.isSafeID($0) ? $0 : nil }
            let origin = (field(13) as? [String: Any]).map { !$0.isEmpty } ?? false
            background = field(12) as? String == "background" || origin
        }
    }

    /// Lists the store's chats when its database changed, and returns the
    /// chats to reread. Every chat the store keeps is added to `active`.
    private func list(_ store: IDEStore, active: inout Set<String>, notices: inout [String]) -> StoreListing? {
        let previous = cache[store.database.path]?.store
        var kept = previous?.composers ?? []
        var context = PlacementContext(user: store.user)
        let listing = listChanged(store, previous: previous, kept: &kept, context: &context, notices: &notices)
        for id in kept { active.insert(Self.composerKey(store.database, id)) }
        if context.legacy != nil {
            active.formUnion(context.legacyKeys)
        } else {
            // Workspace databases were not consulted: keep what they listed before.
            let prefix = store.user.appendingPathComponent("workspaceStorage", isDirectory: true).path + "/"
            for (key, file) in cache.files where file.legacy != nil && key.hasPrefix(prefix) { active.insert(key) }
        }
        return listing
    }

    private func listChanged(_ store: IDEStore, previous: CursorStoreState?, kept: inout [String],
                             context: inout PlacementContext, notices: inout [String]) -> StoreListing? {
        let key = store.database.path
        guard let stamp = CursorStoreStamp(store.database), previous?.stamp != stamp else { return nil }
        if let last = lastListing[key], Date().timeIntervalSince(last) < minimumRelistInterval { return nil }
        let opened = Self.open(store.database, rollback: rollbackLimits, quietInterval: rollbackQuietInterval)
        let busy = "\(store.source.name): Cursor's chat database was busy; the next refresh tries again."
        guard let reader = opened.reader else {
            if previous == nil {
                if opened.closedWAL {
                    notices.append("\(store.source.name): Cursor's chat history is read while Cursor is open. Open Cursor once to index it.")
                } else if opened.settling {
                    notices.append(busy)
                } else {
                    notices.append("\(store.source.name): Cursor's chat database could not be opened.")
                }
            }
            return nil
        }
        let limits = opened.limits
        let now = Date()
        lastListing[key] = now
        let full = lastFullListing[key].map { now.timeIntervalSince($0) >= fullRelistInterval } ?? true
        let chats: [ListedChat]
        let headers: [String: Header]
        let listed: KeyedRows
        // Chats whose value is parsed this time, and those too large to load.
        var parse: Set<String> = []
        var tooLarge: Set<String> = []
        do {
            chats = try Self.listComposers(reader, limits: limits)
            headers = try readHeaders(reader, limits: limits)
            var keys: [String] = []
            for chat in chats {
                let cached = cache[Self.composerKey(store.database, chat.id)]?.composer
                guard full || Self.needsParse(cached, length: chat.length, headerUpdated: headers[chat.id]?.updated, now: now) else {
                    continue
                }
                parse.insert(chat.id)
                if let length = chat.length, length > Int64(limits.maximumValueBytes) {
                    tooLarge.insert(chat.id)
                } else {
                    keys.append("composerData:" + chat.id)
                }
            }
            listed = try Self.keyedRows(reader, keys: keys, sql: Self.composerSQL, limits: limits)
        } catch let error where Self.isTransient(error) {
            if previous == nil { notices.append(busy) }
            return nil
        } catch ReadOnlySQLite.Failure.query(let message) where message.contains("no such table") {
            notices.append("\(store.source.name): Cursor's chat database has a layout this version doesn't read.")
            return nil
        } catch {
            notices.append("\(store.source.name): Cursor's chat database could not be read.")
            return nil
        }
        if full { lastFullListing[key] = now }

        var tasks: [ComposerTask] = []
        var next: [String] = []
        var unreadable = 0
        var oversized = 0
        for chat in chats {
            let id = chat.id
            let dataKey = "composerData:" + id
            let composerKey = Self.composerKey(store.database, id)
            let cached = cache[composerKey]
            guard parse.contains(id) else {
                // Unchanged since its value was last parsed.
                next.append(id)
                continue
            }
            guard let row = listed.rows[dataKey] else {
                let large = tooLarge.contains(id) || listed.oversized.contains(dataKey)
                if large || listed.failed.contains(dataKey) {
                    if large { oversized += 1 } else { unreadable += 1 }
                    // Keep what an earlier scan recorded for this chat, and parse it again next time.
                    if let file = cached, var composer = file.composer {
                        let changed = composer.length != nil
                        composer.length = nil
                        file.composer = composer
                        cache.store(file, at: composerKey, changed: changed)
                        next.append(id)
                    }
                }
                continue
            }
            // A NULL value is a deleted chat's tombstone.
            guard let text = row.first?.string,
                  let values = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [Any] else { continue }
            let fields = ComposerFields(values)
            let header = headers[id]
            let placement = place(fields, header: header, id: id, context: &context)
            // Header pages (Cursor 3.29) stand in for the inline list. A chat
            // without pages keeps the fingerprint it had before pages existed.
            let pages = row.count > 1 ? row[1].string : nil
            let paged = Self.pagesListBubbles(pages)
            let hasBubbles = fields.hasBubbles || paged
            let fingerprint = paged ? Self.hash([text, pages ?? ""]) : Self.hash([text])
            let file = cached ?? CursorFile()
            let before = file.composer
            var composer = before ?? CursorComposer()
            var roots: [String] = []
            var skipped: String?
            switch placement {
            case .roots(let folders): roots = folders
            case .skipped(let reason): skipped = reason
            }
            // Edit paths were resolved against the chat's folders: start over when they change.
            if composer.roots != roots || composer.skipped != skipped || composer.worktree != fields.worktree {
                composer = CursorComposer()
                composer.roots = roots
                composer.skipped = skipped
                composer.worktree = fields.worktree
            }
            composer.parent = fields.parent ?? header?.parent
            composer.created = fields.created ?? header?.created
            composer.updated = [fields.updated, header?.updated].compactMap { $0 }.max()
            composer.hasHeaders = hasBubbles
            if skipped != nil {
                composer.fingerprint = fingerprint
                composer.length = chat.length
            } else if !hasBubbles {
                // An emptied chat (a draft, or one cleared) is no session.
                composer.resetBubbles()
                composer.fingerprint = fingerprint
                composer.length = chat.length
            } else if composer.fingerprint != fingerprint {
                // The length is recorded when the reread finishes, so a chat
                // whose reread was interrupted is parsed again next time.
                composer.length = nil
                tasks.append(ComposerTask(id: id, fingerprint: fingerprint, length: chat.length))
            } else {
                composer.length = chat.length
            }
            file.composer = composer
            cache.store(file, at: composerKey, changed: before != composer)
            next.append(id)
        }
        kept = next
        let entry = cache[key] ?? CursorFile()
        let beforeState = entry.store
        var state = beforeState ?? CursorStoreState()
        state.composers = next
        state.unreadable = unreadable
        state.oversized = oversized
        entry.store = state
        cache.store(entry, at: key, changed: beforeState != state)
        if !deferrals.isEmpty {
            // A chat whose reread ran out of time goes after the others.
            tasks = tasks.enumerated().sorted { left, right in
                let a = deferrals[Self.composerKey(store.database, left.element.id)] ?? 0
                let b = deferrals[Self.composerKey(store.database, right.element.id)] ?? 0
                return a != b ? a < b : left.offset < right.offset
            }.map(\.element)
        }
        return StoreListing(store: store, reader: reader, stamp: stamp, tasks: tasks, limits: limits, rollback: !opened.wal)
    }

    /// The chats the database lists, each with its value's length, which
    /// `octet_length` reads from the record header (SQLite 3.43 and later).
    /// A deleted chat (a NULL value) is left out. On an older SQLite the
    /// lengths are unknown, so every listing parses every chat.
    private static func listComposers(_ reader: ReadOnlySQLite, limits: ReadLimits) throws -> [ListedChat] {
        do {
            let rows = try reader.rows(Self.composerListSQL, maximumColumnBytes: 4_096, deadline: limits.deadline)
            return rows.compactMap { row -> ListedChat? in
                guard row.count == 2, let id = row[0].string, Self.isSafeID(id), let length = row[1].int else { return nil }
                return ListedChat(id: id, length: length)
            }
        } catch ReadOnlySQLite.Failure.query(let message) where message.contains("no such function") {
            return try reader.rows(Self.composerKeysSQL, maximumColumnBytes: 4_096, deadline: limits.deadline)
                .compactMap { $0.first?.string }.filter { Self.isSafeID($0) }.map { ListedChat(id: $0, length: nil) }
        }
    }

    /// Whether a listing parses this chat's value: it is new, its length
    /// changed or is unknown, its header's `lastUpdatedAt` passed the recorded
    /// time, or it was updated within `recentChat`.
    static func needsParse(_ cached: CursorComposer?, length: Int64?, headerUpdated: Date?, now: Date) -> Bool {
        guard let cached, let length, cached.length == length else { return true }
        if let headerUpdated, headerUpdated > (cached.updated ?? .distantPast) { return true }
        guard let latest = cached.updated ?? cached.created else { return true }
        return now.timeIntervalSince(latest) < recentChat
    }

    /// Chat headers: Cursor 3.0 to about 3.9 keep a list in ItemTable; later
    /// versions keep a `composerHeaders` table, which wins. Both are reduced
    /// inside SQLite, so titles and subtitles stay there.
    private func readHeaders(_ reader: ReadOnlySQLite, limits: ReadLimits) throws -> [String: Header] {
        var headers: [String: Header] = [:]
        func add(_ id: ReadOnlySQLite.Value, workspaceID: String?, fields: ReadOnlySQLite.Value, origin: ReadOnlySQLite.Value) {
            guard let id = id.string, Self.isSafeID(id) else { return }
            let values = fields.string.flatMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [Any] } ?? []
            headers[id] = Header(values, origin: origin.int == 1, workspaceID: workspaceID)
        }
        do {
            let rows = try reader.rows(Self.headerListSQL, bindings: [.text("composer.composerHeaders")],
                                       maximumColumnBytes: 65_536, deadline: limits.deadline)
            for row in rows where row.count == 3 {
                add(row[0], workspaceID: nil, fields: row[1], origin: row[2])
            }
        } catch let error where Self.isTransient(error) {
            throw error
        } catch {
            // No ItemTable or no list: nothing to add.
        }
        do {
            let rows = try reader.rows(Self.headerTableSQL, maximumColumnBytes: 65_536, deadline: limits.deadline)
            for row in rows where row.count == 4 {
                add(row[0], workspaceID: row[1].string, fields: row[2], origin: row[3])
            }
        } catch let error where Self.isTransient(error) {
            throw error
        } catch {
            // Databases from before the table existed.
        }
        return headers
    }

    // MARK: Placement

    private enum Placement: Equatable {
        case roots([String])
        /// "remote", "folderless", "background" or "unknown".
        case skipped(String)
    }

    private enum URIKind {
        case local(String)
        case remote
        case missing
    }

    private struct PlacementContext {
        let user: URL
        /// workspaceStorage id to its window's folders; empty for a remote or folderless window.
        var workspaces: [String: [String]] = [:]
        var unknownWorkspaces: Set<String> = []
        var workspaceFiles: [String: [String]] = [:]
        /// Chat id to the workspaceStorage id whose database lists it (pre-3.0).
        var legacy: [String: String]?
        var legacyKeys: Set<String> = []

        init(user: URL) {
            self.user = user
        }
    }

    private func place(_ fields: ComposerFields, header: Header?, id: String, context: inout PlacementContext) -> Placement {
        if fields.background || header?.background == true { return .skipped("background") }
        // The workspace the chat was opened in.
        for identifier in [header?.identifier, fields.identifier] {
            guard let object = identifier as? [String: Any] else { continue }
            if let uri = object["uri"], !(uri is NSNull) {
                switch Self.location(uri) {
                case .local(let path): return .roots([path])
                case .remote: return .skipped("remote")
                case .missing: break
                }
            }
            if let configuration = object["configPath"], !(configuration is NSNull) {
                switch Self.location(configuration) {
                case .local(let file):
                    let folders = workspaceFileFolders(file, context: &context)
                    if !folders.isEmpty { return .roots(folders) }
                case .remote: return .skipped("remote")
                case .missing: break
                }
            }
        }
        // Where the agent ran.
        for location in [header?.location, fields.location] {
            guard let location else { continue }
            switch Self.location(location) {
            case .local(let path): return .roots([path])
            case .remote: return .skipped("remote")
            case .missing: break
            }
        }
        // The first Git repository the chat tracked.
        for repo in [header?.repo, fields.repo] {
            if let repo, repo.hasPrefix("/"), let path = ProjectLocationRegistry.lexicalPath(repo) { return .roots([path]) }
        }
        // The window Cursor's own storage names.
        var folderless = false
        var workspaceIDs = header?.workspaceIDs ?? []
        if let id = (fields.identifier as? [String: Any])?["id"] as? String, !id.isEmpty, !workspaceIDs.contains(id) {
            workspaceIDs.append(id)
        }
        for workspaceID in workspaceIDs {
            if workspaceID == "empty-window" || Int(workspaceID) != nil {
                folderless = true
                continue
            }
            guard let roots = workspaceRoots(workspaceID, context: &context) else { continue }
            return roots.isEmpty ? .skipped("folderless") : .roots(roots)
        }
        // Chats from before Cursor 3.0: the workspace database that lists them.
        if context.legacy == nil {
            let index = buildLegacyIndex(&context)
            context.legacy = index
        }
        if let hash = context.legacy?[id], let roots = workspaceRoots(hash, context: &context) {
            return roots.isEmpty ? .skipped("folderless") : .roots(roots)
        }
        return .skipped(folderless ? "folderless" : "unknown")
    }

    /// A URI object or string: a local folder, another scheme or host, or neither.
    private static func location(_ value: Any) -> URIKind {
        if let path = VSCodeURI.localPath(value) { return .local(path) }
        if let object = value as? [String: Any] {
            if let scheme = object["scheme"] as? String, !scheme.isEmpty { return .remote }
            return .missing
        }
        if let text = value as? String {
            if text.hasPrefix("/") {
                guard let path = ProjectLocationRegistry.lexicalPath(text) else { return .missing }
                return .local(path)
            }
            if let url = URL(string: text), let scheme = url.scheme, !scheme.isEmpty { return .remote }
        }
        return .missing
    }

    private func workspaceRoots(_ id: String, context: inout PlacementContext) -> [String]? {
        guard Self.isSafeID(id) else { return nil }
        if let known = context.workspaces[id] { return known }
        if context.unknownWorkspaces.contains(id) { return nil }
        let record = context.user.appendingPathComponent("workspaceStorage/\(id)/workspace.json")
        guard let roots = VSCodeWorkspace.roots(of: record) else {
            context.unknownWorkspaces.insert(id)
            return nil
        }
        context.workspaces[id] = roots
        return roots
    }

    private func workspaceFileFolders(_ file: String, context: inout PlacementContext) -> [String] {
        if let known = context.workspaceFiles[file] { return known }
        let folders = VSCodeWorkspace.codeWorkspaceFolders(URL(fileURLWithPath: file))
        context.workspaceFiles[file] = folders
        return folders
    }

    /// Chat id to workspaceStorage id, from each workspace database's
    /// `composer.composerData.allComposers` (Cursor before 3.0). Each database
    /// is reread only when its stamp changes.
    private func buildLegacyIndex(_ context: inout PlacementContext) -> [String: String] {
        let storage = context.user.appendingPathComponent("workspaceStorage", isDirectory: true)
        guard let names = try? files.contentsOfDirectory(atPath: storage.path) else { return [:] }
        var index: [String: String] = [:]
        for name in names.sorted() where Self.isSafeID(name) {
            let database = storage.appendingPathComponent(name, isDirectory: true).appendingPathComponent("state.vscdb")
            guard let stamp = CursorStoreStamp(database) else { continue }
            let key = database.path
            context.legacyKeys.insert(key)
            let entry = cache[key] ?? CursorFile()
            // Cursor 2.x keeps these databases in rollback-journal mode, under the same limits.
            let opened = entry.legacy?.stamp != stamp
                ? Self.open(database, rollback: rollbackLimits, quietInterval: rollbackQuietInterval) : nil
            if let opened, let reader = opened.reader {
                do {
                    let rows = try reader.rows(Self.legacySQL, bindings: [.text("composer.composerData")], maximumColumnBytes: 4_096,
                                               deadline: opened.limits.deadline)
                    let composers = rows.compactMap { $0.first?.string }.filter { Self.isSafeID($0) }
                    entry.legacy = CursorLegacyIndex(stamp: stamp, composers: Array(Set(composers)).sorted())
                    cache.store(entry, at: key, changed: true)
                } catch ReadOnlySQLite.Failure.query(let message) where message.contains("no such table") {
                    entry.legacy = CursorLegacyIndex(stamp: stamp, composers: [])
                    cache.store(entry, at: key, changed: true)
                } catch {
                    // Busy, interrupted or unreadable: keep what it listed before.
                }
            }
            for composer in entry.legacy?.composers ?? [] where index[composer] == nil { index[composer] = name }
        }
        return index
    }

    // MARK: Reading one chat

    /// Rereads one chat that changed: its bubble list, its proofs of applied
    /// code blocks and created files, and the bubbles it gained, plus the
    /// bubbles still in flight or near the end. Throws only when the database
    /// is busy or a statement hit its deadline.
    private func reread(_ task: ComposerTask, in listing: StoreListing) throws {
        let key = Self.composerKey(listing.store.database, task.id)
        let file = cache[key] ?? CursorFile()
        let before = file.composer
        var composer = before ?? CursorComposer()
        let reader = listing.reader
        let deadline = listing.limits.deadline
        let dataKey: ReadOnlySQLite.Value = .text("composerData:" + task.id)
        var ids: [String] = []
        var blocks: [String: CursorBlockProof] = [:]
        var created: Set<String> = []
        do {
            // A chat with header pages (Cursor 3.29) lists its bubbles there; its
            // inline list is empty.
            let pageRange: [ReadOnlySQLite.Value] = [.text("composerConvHeaders:\(task.id):"),
                                                      .text("composerConvHeaders:\(task.id);")]
            for row in try reader.rows(Self.pagedBubbleListSQL, bindings: pageRange, maximumColumnBytes: 4_096,
                                       deadline: deadline) {
                if let id = row.first?.string, Self.isSafeBubbleID(id) { ids.append(id) }
            }
            if ids.isEmpty {
                for row in try reader.rows(Self.bubbleListSQL, bindings: [dataKey], maximumColumnBytes: 4_096,
                                           deadline: deadline) {
                    if let id = row.first?.string, Self.isSafeBubbleID(id) { ids.append(id) }
                }
            }
            let blockRows = try reader.rows(Self.codeBlockSQL, bindings: [dataKey], maximumColumnBytes: 65_536, deadline: deadline)
            for row in blockRows where row.count == 5 {
                guard let block = row[0].string, let diff = row[2].string, !diff.isEmpty,
                      let milliseconds = row[3].double, let applied = RecordedDate.milliseconds(milliseconds) else { continue }
                var path: String?
                if let uri = row[1].string { path = Self.uriPath(uri) }
                blocks[block] = CursorBlockProof(path: path, applied: applied, rejected: row[4].string == "rejected")
            }
            for row in try reader.rows(Self.createdFilesSQL, bindings: [dataKey], maximumColumnBytes: 65_536, deadline: deadline) {
                if let uri = row.first?.string, let path = Self.uriPath(uri) { created.insert(path) }
            }
        } catch let error where Self.isTransient(error) {
            throw error
        } catch {
            // The chat's record no longer reads: keep what was recorded, and try
            // again when it changes.
            composer.unreadable = max(composer.unreadable, 1)
            file.composer = composer
            cache.store(file, at: key, changed: before != composer)
            return
        }

        // The list grows at its end. Anything else (a restored checkpoint, a
        // regenerated reply) rereads the whole chat.
        let prefixMatches = composer.readCount <= ids.count
            && Self.hash(ids.prefix(composer.readCount)) == composer.readHash
        if !prefixMatches { composer.resetBubbles() }
        let listed = Set(ids)
        composer.edits = composer.edits.filter { listed.contains($0.key) }
        let queued = composer.pending.filter { listed.contains($0.id) }
        let fresh = Array(ids[composer.readCount...])
        let keys = (queued.map(\.id) + fresh).map { "bubbleId:\(task.id):\($0)" }
        let fetched = try Self.keyedRows(reader, keys: keys, sql: Self.bubbleSQL, limits: listing.limits)
        composer.blocks = blocks
        composer.createdFiles = created.sorted()
        composer.pending = []
        composer.unreadable = 0

        func absorb(_ id: String, before stamp: Date?, position: Int) -> Date? {
            let bubbleKey = "bubbleId:\(task.id):\(id)"
            let nearEnd = position >= ids.count - Self.pendingTail
            if fetched.oversized.contains(bubbleKey) {
                composer.oversized += 1
                return nil
            }
            if fetched.failed.contains(bubbleKey) {
                composer.unreadable += 1
                composer.pending.append(CursorPendingBubble(id: id, before: stamp))
                return nil
            }
            guard let row = fetched.rows[bubbleKey] else {
                // Possibly listed before it was written.
                if nearEnd { composer.pending.append(CursorPendingBubble(id: id, before: stamp)) }
                return nil
            }
            let time = composer.absorb(row, bubble: id, composerID: task.id, before: stamp)
            // Cursor writes its next tool call into the chat's last bubble while
            // that bubble is still empty, keeping its id: a bubble near the end
            // with no tool name is read again with the chat's next change.
            if nearEnd, row.first?.string == nil {
                composer.pending.append(CursorPendingBubble(id: id, before: stamp))
            }
            return time
        }

        let positions = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for item in queued {
            _ = absorb(item.id, before: item.before, position: positions[item.id] ?? 0)
        }
        var running = composer.runningStamp
        for (offset, id) in fresh.enumerated() {
            if let stamp = absorb(id, before: running, position: composer.readCount + offset) { running = stamp }
        }
        composer.runningStamp = running
        composer.readCount = ids.count
        composer.readHash = Self.hash(ids)
        composer.fingerprint = task.fingerprint
        composer.length = task.length
        file.composer = composer
        cache.store(file, at: key, changed: before != composer)
    }

    /// A target path as a lexical absolute path. A relative path resolves
    /// against the chat's first folder. In a worktree chat, a path under that
    /// folder moves into the worktree, as Cursor maps it before writing.
    static func target(_ raw: String, roots: [String], worktree: String?) -> String? {
        guard !raw.isEmpty, !raw.contains("\u{0}") else { return nil }
        let path: String
        if raw.hasPrefix("/") {
            guard let lexical = ProjectLocationRegistry.lexicalPath(raw) else { return nil }
            path = lexical
        } else if raw.hasPrefix("file:") {
            guard let local = VSCodeURI.localPath(raw) else { return nil }
            path = local
        } else {
            guard let root = roots.first, !raw.hasPrefix("~"),
                  let lexical = ProjectLocationRegistry.lexicalPath((root as NSString).appendingPathComponent(raw)) else { return nil }
            path = lexical
        }
        guard let worktree, let root = roots.first, root != "/", !CheckoutPath.contains(root: worktree, path: path),
              CheckoutPath.contains(root: root, path: path) else { return path }
        return ProjectLocationRegistry.lexicalPath(worktree + String(path.dropFirst(root.count)))
    }

    /// A file URI as `newlyCreatedFiles` or `codeBlockData` stores it: a
    /// serialized URI object, a URI string, or a path.
    static func uriPath(_ text: String) -> String? {
        if text.hasPrefix("{") {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
            return VSCodeURI.localPath(object)
        }
        if text.hasPrefix("/") { return ProjectLocationRegistry.lexicalPath(text) }
        return VSCodeURI.localPath(text)
    }

    static func date(_ value: ReadOnlySQLite.Value) -> Date? {
        switch value {
        case .text(let text): return RecordedDate.parse(text)
        case .integer(let number): return RecordedDate.any(Double(number))
        case .real(let number): return RecordedDate.any(number)
        default: return nil
        }
    }

    /// FNV-1a over the items, each followed by a newline. Stable across launches.
    static func hash<S: Sequence>(_ items: S) -> UInt64 where S.Element == String {
        var value: UInt64 = 14695981039346656037
        for item in items {
            for byte in item.utf8 { value = (value ^ UInt64(byte)) &* 1099511628211 }
            value = (value ^ 10) &* 1099511628211
        }
        return value
    }

    // MARK: Batched lookups

    struct KeyedRows {
        var rows: [String: [ReadOnlySQLite.Value]] = [:]
        var failed: Set<String> = []
        var oversized: Set<String> = []
    }

    /// Runs `sql`, whose first column is the key, for `keys` in batches of
    /// `limits.batchSize`, each statement under `limits.deadline`. A batch
    /// that fails (one malformed or oversized value fails it) is read again one
    /// key at a time. Throws only when the database is busy or a statement hit
    /// its deadline, never marking those keys failed.
    static func keyedRows(_ reader: ReadOnlySQLite, keys: [String], sql: String, limits: ReadLimits) throws -> KeyedRows {
        var result = KeyedRows()
        let size = max(1, limits.batchSize)
        var start = 0
        while start < keys.count {
            let batch = Array(keys[start..<min(start + size, keys.count)])
            start += size
            let placeholders = Array(repeating: "?", count: batch.count).joined(separator: ", ")
            do {
                let rows = try reader.rows(sql.replacingOccurrences(of: "%KEYS%", with: placeholders),
                                           bindings: batch.map { .text($0) }, deadline: limits.deadline)
                for row in rows {
                    guard let key = row.first?.string else { continue }
                    result.rows[key] = Array(row.dropFirst())
                }
            } catch let error where isTransient(error) {
                throw error
            } catch {
                for key in batch {
                    do {
                        let rows = try reader.rows(sql.replacingOccurrences(of: "%KEYS%", with: "?"), bindings: [.text(key)],
                                                   deadline: limits.deadline)
                        for row in rows { result.rows[key] = Array(row.dropFirst()) }
                    } catch let error where isTransient(error) {
                        throw error
                    } catch ReadOnlySQLite.Failure.query(let message) where message.contains("too big") {
                        result.oversized.insert(key)
                    } catch {
                        result.failed.insert(key)
                    }
                }
            }
        }
        return result
    }

    // MARK: SQL

    /// Chat keys only: the key index alone answers it. For SQLite before 3.43.
    static let composerKeysSQL = "SELECT substr(key, 14) FROM cursorDiskKV WHERE key >= 'composerData:' AND key < 'composerData;'"

    /// Chat keys with each value's length in bytes. `octet_length` of a plain
    /// column reads the length from the record header and never loads the
    /// value, so this neither parses nor hits the value cap.
    static let composerListSQL = """
        SELECT substr(key, 14), octet_length(value) FROM cursorDiskKV
        WHERE key >= 'composerData:' AND key < 'composerData;'
        """

    /// Per `composerHeaders` row: chat id, workspace id, the fields `Header`
    /// reads (by position), and whether `createdFromBackgroundAgent` is a
    /// non-empty object. Titles, subtitles and the rest stay in SQLite. The
    /// table has no key range, so it is read in full; a malformed row reads
    /// as empty.
    static let headerTableSQL = """
        SELECT composerId, workspaceId,
            json_extract(v, '$.workspaceIdentifier', '$.agentLocation.environment.uri', '$.trackedGitRepos[0].repoPath',
                '$.subagentInfo.parentComposerId', '$.createdAt', '$.lastUpdatedAt', '$.unifiedMode'),
            coalesce(json_type(v, '$.createdFromBackgroundAgent') = 'object'
                AND json_extract(v, '$.createdFromBackgroundAgent') <> '{}', 0)
        FROM (SELECT composerId, workspaceId,
                CASE WHEN json_valid(CAST(value AS TEXT)) THEN CAST(value AS TEXT) END AS v
            FROM composerHeaders)
        """

    /// The same per header in ItemTable's `allComposers` list (Cursor 3.0 to about 3.9).
    static let headerListSQL = """
        SELECT json_extract(e.value, '$.composerId'),
            json_extract(e.value, '$.workspaceIdentifier', '$.agentLocation.environment.uri', '$.trackedGitRepos[0].repoPath',
                '$.subagentInfo.parentComposerId', '$.createdAt', '$.lastUpdatedAt', '$.unifiedMode'),
            coalesce(json_type(e.value, '$.createdFromBackgroundAgent') = 'object'
                AND json_extract(e.value, '$.createdFromBackgroundAgent') <> '{}', 0)
        FROM ItemTable AS t, json_each(CAST(t.value AS TEXT), '$.allComposers') AS e
        WHERE t.key = ? AND e.type = 'object'
        """

    /// One small JSON array per chat. `ComposerFields` reads it by position.
    /// The third column summarizes the chat's header pages (Cursor 3.29):
    /// their count, the first page's first and the last page's last bubble id,
    /// and the last page's length, so a page change changes the fingerprint
    /// the way the inline list's first and last ids do. Each page is looked up
    /// by key range.
    static let composerSQL = """
        SELECT k, json_extract(v, '$.createdAt', '$.lastUpdatedAt', '$.conversationCheckpointLastUpdatedAt', '$.status',
            '$._v', '$.fullConversationHeadersOnly[0].bubbleId', '$.fullConversationHeadersOnly[#-1].bubbleId',
            '$.workspaceIdentifier', '$.agentLocation.environment.uri', '$.trackedGitRepos[0].repoPath',
            '$.gitWorktree.worktreePath', '$.subagentInfo.parentComposerId', '$.unifiedMode', '$.createdFromBackgroundAgent'),
            (SELECT json_array(
                (SELECT count(*) FROM cursorDiskKV AS c WHERE c.key >= p.lo AND c.key < p.hi),
                (SELECT CASE WHEN json_valid(CAST(c.value AS TEXT)) THEN json_extract(CAST(c.value AS TEXT), '$[0].bubbleId') END
                    FROM cursorDiskKV AS c WHERE c.key >= p.lo AND c.key < p.hi ORDER BY c.key LIMIT 1),
                (SELECT CASE WHEN json_valid(CAST(c.value AS TEXT)) THEN json_extract(CAST(c.value AS TEXT), '$[#-1].bubbleId') END
                    FROM cursorDiskKV AS c WHERE c.key >= p.lo AND c.key < p.hi ORDER BY c.key DESC LIMIT 1),
                (SELECT CASE WHEN json_valid(CAST(c.value AS TEXT)) THEN json_array_length(CAST(c.value AS TEXT)) END
                    FROM cursorDiskKV AS c WHERE c.key >= p.lo AND c.key < p.hi ORDER BY c.key DESC LIMIT 1))
             FROM (SELECT 'composerConvHeaders:' || substr(k, 14) || ':' AS lo,
                          'composerConvHeaders:' || substr(k, 14) || ';' AS hi) AS p)
        FROM (SELECT key AS k, CAST(value AS TEXT) AS v FROM cursorDiskKV WHERE key IN (%KEYS%))
        """

    /// The bubble ids a chat lists, in order.
    static let bubbleListSQL = """
        SELECT json_extract(e.value, '$.bubbleId')
        FROM cursorDiskKV AS kv, json_each(CAST(kv.value AS TEXT), '$.fullConversationHeadersOnly') AS e
        WHERE kv.key = ? AND e.type = 'object' ORDER BY e.key
        """

    /// The bubble ids a chat's header pages list (Cursor 3.29), in page order
    /// then position. Bound to the chat's page key range.
    static let pagedBubbleListSQL = """
        SELECT json_extract(e.value, '$.bubbleId')
        FROM cursorDiskKV AS kv, json_each(CAST(kv.value AS TEXT)) AS e
        WHERE kv.key >= ? AND kv.key < ? AND e.type = 'object' ORDER BY kv.key, e.key
        """

    /// Applied code blocks (Cursor 2.x): block id, file URI, diff id, apply time, status.
    static let codeBlockSQL = """
        SELECT b.key, f.key, json_extract(b.value, '$.diffId'), json_extract(b.value, '$.lastAppliedAt'),
            json_extract(b.value, '$.status')
        FROM cursorDiskKV AS kv, json_each(CAST(kv.value AS TEXT), '$.codeBlockData') AS f,
            json_each(CASE WHEN f.type = 'object' THEN f.value ELSE '{}' END) AS b
        WHERE kv.key = ? AND b.type = 'object'
        """

    /// Files the chat created, as URIs.
    static let createdFilesSQL = """
        SELECT json_extract(e.value, '$.uri')
        FROM cursorDiskKV AS kv, json_each(CAST(kv.value AS TEXT), '$.newlyCreatedFiles') AS e
        WHERE kv.key = ? AND e.type = 'object'
        """

    /// Per bubble: tool name, status, call id, createdAt, first code block id,
    /// approval decision, then for edit tools only the target path, the cloud
    /// flag, and the result's success fields. Parameters and results are JSON
    /// strings in recent versions and objects in some; both parse here.
    static let bubbleSQL = """
        SELECT k, name, status, call, created, block, decision,
            coalesce(json_extract(p, '$.relativeWorkspacePath'), json_extract(p, '$.path')),
            json_extract(p, '$.cloudAgentEdit'), json_extract(r, '$.afterContentId'),
            json_extract(r, '$.fileDeletedSuccessfully'), json_extract(r, '$.rejected')
        FROM (SELECT k, name, status, call, created, block, decision,
                CASE WHEN json_valid(pt) THEN pt END AS p, CASE WHEN json_valid(rt) THEN rt END AS r
            FROM (SELECT k, json_extract(v, '$.toolFormerData.name') AS name,
                    json_extract(v, '$.toolFormerData.status') AS status,
                    json_extract(v, '$.toolFormerData.toolCallId') AS call,
                    json_extract(v, '$.createdAt') AS created,
                    json_extract(v, '$.codeBlocks[0].codeblockId') AS block,
                    json_extract(v, '$.toolFormerData.userDecision') AS decision,
                    CASE WHEN json_extract(v, '$.toolFormerData.name') IN ('edit_file_v2', 'delete_file')
                        THEN json_extract(v, '$.toolFormerData.params') END AS pt,
                    CASE WHEN json_extract(v, '$.toolFormerData.name') IN ('edit_file_v2', 'delete_file')
                        THEN json_extract(v, '$.toolFormerData.result') END AS rt
                FROM (SELECT key AS k, CAST(value AS TEXT) AS v FROM cursorDiskKV WHERE key IN (%KEYS%))))
        """

    /// Chat ids a pre-3.0 workspace database lists.
    static let legacySQL = """
        SELECT json_extract(e.value, '$.composerId')
        FROM ItemTable AS t, json_each(CAST(t.value AS TEXT), '$.allComposers') AS e
        WHERE t.key = ? AND e.type = 'object'
        """

    // MARK: Folding

    private func result(_ discovered: Discovered, notices: [String]) -> ScanResult {
        var sessions: [HistorySession] = []
        var notices = notices
        for store in discovered.stores {
            guard let state = cache[store.database.path]?.store else { continue }
            var unknown = 0
            var unreadable = state.unreadable
            var oversized = state.oversized
            for id in state.composers {
                guard let composer = cache[Self.composerKey(store.database, id)]?.composer else { continue }
                if composer.skipped == "unknown", composer.hasHeaders { unknown += 1 }
                unreadable += composer.unreadable
                oversized += composer.oversized
                if let session = Self.session(composer, id: id, source: store.source) { sessions.append(session) }
            }
            if unknown > 0 {
                notices.append("\(store.source.name): \(unknown) Cursor chat(s) record no workspace folder; they are not counted.")
            }
            if unreadable > 0 {
                notices.append("\(store.source.name): skipped unreadable records in Cursor's chat database.")
            }
            if oversized > 0 {
                notices.append("\(store.source.name): a Cursor chat record was too large to index safely.")
            }
        }
        var folderless: [String: Int] = [:]
        for chat in discovered.cli {
            guard let meta = cache[chat.meta.path]?.cli, !meta.empty else { continue }
            guard let cwd = meta.cwd else {
                folderless[chat.source.name, default: 0] += 1
                continue
            }
            guard let created = meta.created ?? meta.updated else { continue }
            sessions.append(HistorySession(sourceID: chat.source.id, sessionID: chat.id, recordedWorkspace: cwd,
                roots: [cwd], createdAt: created, latestActivity: max(created, meta.updated ?? created), edits: [:]))
        }
        for (name, count) in folderless {
            notices.append("\(name): \(count) Cursor CLI session(s) record no folder; they are not counted.")
        }
        let folded = HistoryFold.fold(sessions, resolver: resolver)
        return ScanResult(projects: ProjectSummary.merge(folded.activity), notices: Array(Set(notices)).sorted(),
            sessionProjects: folded.associations, missingFolders: folded.missingFolders,
            sessionTrails: SessionTrail.merge(folded.trails))
    }

    private static func session(_ composer: CursorComposer, id: String, source: AgentSource) -> HistorySession? {
        guard composer.skipped == nil, let workspace = composer.roots.first, composer.hasHeaders, composer.hasBubbleRows,
              let created = composer.firstBubbleAt ?? composer.created ?? composer.updated else { return nil }
        let latest = ([created] + [composer.lastBubbleAt, composer.updated].compactMap { $0 }).max() ?? created
        var roots = composer.roots
        if let worktree = composer.worktree, !roots.contains(worktree) { roots.append(worktree) }
        var edits: [String: StoredEdit] = [:]
        for (_, record) in composer.edits.sorted(by: { $0.key < $1.key }) {
            guard let path = composer.confirmedPath(record) else { continue }
            let folder = roots.filter { CheckoutPath.contains(root: $0, path: path) }.max { $0.count < $1.count } ?? workspace
            let edit = StoredEdit(date: record.date, workspace: folder,
                                  targetDirectories: [(path as NSString).deletingLastPathComponent])
            edits[record.id] = edits[record.id]?.earlier(than: edit) ?? edit
        }
        var session = HistorySession(sourceID: source.id, sessionID: id, recordedWorkspace: workspace, roots: roots,
                                     createdAt: created, latestActivity: latest, edits: edits)
        session.parentSessionID = composer.parent
        return session
    }
}

// MARK: - Cached evidence

/// One cache entry: a CLI session's meta.json, a Cursor database's listing,
/// one chat, or one pre-3.0 workspace database's chat list.
final class CursorFile: Codable {
    var stamp: FileStamp?
    var cli: CursorCLIMeta?
    var store: CursorStoreState?
    var composer: CursorComposer?
    var legacy: CursorLegacyIndex?

    init() {}
}

/// A database's identity, size and modification time, with its WAL file's.
struct CursorStoreStamp: Codable, Equatable {
    var database: FileStamp
    var wal: FileStamp?

    init?(_ url: URL) {
        guard let stat = FileStat.of(url.path), stat.kind == .regular else { return nil }
        database = FileStamp(stat)
        wal = FileStat.of(url.path + "-wal").map { FileStamp($0) }
    }
}

struct CursorStoreState: Codable, Equatable {
    /// Set when a listing and its rereads finished.
    var stamp: CursorStoreStamp?
    var composers: [String] = []
    /// Chat records the last listing could not read.
    var unreadable = 0
    /// Chat records the last listing found too large to load.
    var oversized = 0
}

struct CursorLegacyIndex: Codable, Equatable {
    var stamp: CursorStoreStamp
    var composers: [String]
}

/// A Cursor CLI session's meta.json: its folder and times, never its title.
struct CursorCLIMeta: Codable, Equatable {
    var cwd: String?
    var created: Date?
    var updated: Date?
    /// `hasConversation: false`: opened and left without a message.
    var empty = false

    init(_ object: [String: Any]) {
        cwd = (object["cwd"] as? String).flatMap { $0.hasPrefix("/") ? ProjectLocationRegistry.lexicalPath($0) : nil }
        created = RecordedDate.milliseconds(object["createdAtMs"])
        updated = RecordedDate.milliseconds(object["updatedAtMs"])
        empty = (object["hasConversation"] as? NSNumber).map { !$0.boolValue } ?? false
    }
}

/// An edit tool bubble that completed. `proof` nil: its result proves it;
/// `block:<id>`: confirmed while that code block stays applied and not
/// rejected; `created`: confirmed when the chat lists its file as created.
struct CursorEdit: Codable, Equatable {
    var id: String
    var date: Date
    var path: String
    var proof: String?
}

struct CursorPendingBubble: Codable, Equatable {
    var id: String
    /// The nearest earlier bubble's time, for a bubble that records none.
    var before: Date?
}

struct CursorBlockProof: Codable, Equatable {
    var path: String?
    var applied: Date
    var rejected: Bool
}

/// One chat's recorded evidence.
struct CursorComposer: Codable, Equatable {
    /// Hash of the chat's listing fields; a change triggers a reread.
    var fingerprint: UInt64 = 0
    /// The byte length of the chat's value when `fingerprint` was recorded;
    /// nil while a reread is due. A listing skips a chat whose length held.
    var length: Int64?
    var roots: [String] = []
    /// Why the chat is not counted: remote, folderless, background or unknown.
    var skipped: String?
    var worktree: String?
    var parent: String?
    var created: Date?
    var updated: Date?
    /// The chat lists at least one bubble.
    var hasHeaders = false
    /// At least one listed bubble was found.
    var hasBubbleRows = false
    var firstBubbleAt: Date?
    var lastBubbleAt: Date?
    /// The latest bubble time in list order, for the bubbles read so far.
    var runningStamp: Date?
    /// The listed bubbles read so far, and the hash of their ids.
    var readCount = 0
    var readHash: UInt64 = CursorActivityProvider.hash([String]())
    /// Edit bubbles still in flight, unreadable ones, and missing ones or ones
    /// with no tool name near the end.
    var pending: [CursorPendingBubble] = []
    /// Completed edit tool calls by bubble id.
    var edits: [String: CursorEdit] = [:]
    /// Applied code blocks by block id (Cursor 2.x).
    var blocks: [String: CursorBlockProof] = [:]
    /// Paths in the chat's `newlyCreatedFiles`.
    var createdFiles: [String] = []
    var unreadable = 0
    var oversized = 0

    mutating func resetBubbles() {
        hasBubbleRows = false
        firstBubbleAt = nil
        lastBubbleAt = nil
        runningStamp = nil
        readCount = 0
        readHash = CursorActivityProvider.hash([String]())
        pending = []
        edits = [:]
        unreadable = 0
        oversized = 0
    }

    /// Records one bubble row from `bubbleSQL` (key column dropped). Returns
    /// the bubble's own time.
    mutating func absorb(_ row: [ReadOnlySQLite.Value], bubble: String, composerID: String, before: Date?) -> Date? {
        guard row.count >= 11 else { return nil }
        hasBubbleRows = true
        let created = CursorActivityProvider.date(row[3])
        if let created {
            firstBubbleAt = min(firstBubbleAt ?? created, created)
            lastBubbleAt = max(lastBubbleAt ?? created, created)
        }
        guard let name = row[0].string, CursorActivityProvider.editTools.contains(name) else { return created }
        let status = row[1].string ?? ""
        guard status == "completed" else {
            if !CursorActivityProvider.finalStatuses.contains(status) {
                pending.append(CursorPendingBubble(id: bubble, before: before))
            }
            return created
        }
        // A rejected approval, a cloud agent's edit on its own machine, or a
        // call without a usable target is not an edit on this Mac.
        guard row[5].string != "rejected", row[7].int != 1, let raw = row[6].string,
              let path = CursorActivityProvider.target(raw, roots: roots, worktree: worktree) else { return created }
        let block = row[4].string.flatMap { $0.isEmpty ? nil : $0 }
        let proof: String?
        if name == "delete_file" {
            guard row[9].int == 1 else { return created }
            proof = nil
        } else if let after = row[8].string, !after.isEmpty {
            proof = nil
        } else if row[10].int == 1 {
            return created
        } else if let block {
            proof = "block:" + block
        } else {
            proof = "created"
        }
        let applied = block.flatMap { blocks[$0]?.applied }
        guard let date = created ?? applied ?? before ?? updated ?? self.created else { return created }
        let callID = row[2].string.flatMap { $0.isEmpty || $0.count > 256 ? nil : $0 }
        edits[bubble] = CursorEdit(id: callID ?? "\(composerID):\(bubble)", date: date, path: path, proof: proof)
        return created
    }

    /// The edited file when the edit is confirmed.
    func confirmedPath(_ edit: CursorEdit) -> String? {
        guard let proof = edit.proof else { return edit.path }
        if proof.hasPrefix("block:") {
            guard let block = blocks[String(proof.dropFirst(6))], !block.rejected else { return nil }
            return block.path ?? edit.path
        }
        if proof == "created" { return createdFiles.contains(edit.path) ? edit.path : nil }
        return nil
    }
}
