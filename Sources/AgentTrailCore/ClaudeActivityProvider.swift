import Foundation

/// A read-only adapter for Claude Code sessions: Claude Desktop's Code tab and
/// `claude` in a terminal. Call on a background queue: the first history scan can
/// read substantial JSONL files. Only successful Edit/Write tools are attributed;
/// shell commands and file mtimes are not evidence.
public final class ClaudeActivityProvider: ActivityProvider {
    private let cacheURL: URL?
    private var cache: [String: TranscriptCache] = [:]
    /// True when `cache` differs from the saved file.
    private var cacheDirty = false
    private var lastCacheSave = Date.distantPast
    private var cacheLoadNotice: String?
    /// Where and how each transcript's session started, by path. In memory only.
    private var heads: [String: (identity: String, size: UInt64, head: TranscriptHead?)] = [:]
    private let files = FileManager.default
    private let isoDate = ISO8601DateFormatter()
    private let plainISODate = ISO8601DateFormatter()
    private let resolver: GitProjectResolver
    private let ownsResolver: Bool

    /// Earlier locations of moved checkouts. Applied when folding, so the
    /// transcript cache never depends on them.
    public var projectLocations: ProjectLocationRegistry {
        get { resolver.locations }
        set { resolver.reset(locations: newValue) }
    }

    public convenience init(cacheURL: URL? = nil, projectLocations: ProjectLocationRegistry = .init()) {
        self.init(cacheURL: cacheURL, resolver: GitProjectResolver(locations: projectLocations), ownsResolver: true)
    }

    /// A shared resolver is reset by its owner once per scan.
    init(cacheURL: URL?, resolver: GitProjectResolver, ownsResolver: Bool = false) {
        self.cacheURL = cacheURL
        self.resolver = resolver
        self.ownsResolver = ownsResolver
        isoDate.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        plainISODate.formatOptions = [.withInternetDateTime]
        if let cacheURL, FileManager.default.fileExists(atPath: cacheURL.path) {
            do {
                let data = try Data(contentsOf: cacheURL)
                let header = try JSONDecoder().decode(CacheHeader.self, from: data)
                if header.version == 2 {
                    cache = try JSONDecoder().decode(SavedCache.self, from: data).transcripts
                } else {
                    cacheLoadNotice = "Local activity history is being rebuilt once to include daily edit statistics."
                    cacheDirty = true
                }
            } catch {
                cacheLoadNotice = "The local activity cache could not be read; change history will be rebuilt."
                cacheDirty = true
            }
        }
    }

    /// Fast project/activity listing without reading conversation transcripts.
    public func metadata(sources: [AgentSource]) -> ScanResult {
        if ownsResolver { resolver.reset() }
        let metadata = readMetadata(sources: sources)
        // Terminal sessions are placed by their edits, so the cached ones keep
        // each session on the project its last full scan chose.
        return result(metadata: metadata, edits: [:], terminalEdits: cachedTerminalEdits(metadata), extraNotices: [])
    }

    public func scan(sources: [AgentSource]) -> ScanResult {
        scan(sources: sources, progress: nil)
    }

    public func scan(sources: [AgentSource], progress: ((ScanResult, Int, Int) -> Void)?) -> ScanResult {
        if ownsResolver { resolver.reset() }
        let metadata = readMetadata(sources: sources)
        var notices: [String] = cacheLoadNotice.map { [$0] } ?? []
        cacheLoadNotice = nil
        let tasks = discoverTranscripts(metadata: metadata, notices: &notices)
        var edits: [String: ProjectEdits] = [:]
        var terminalEdits: [String: ProjectEdits] = [:]
        // Progress keeps a session not read yet where its cached edits put it.
        let cachedTerminal = cachedTerminalEdits(metadata)
        var readTerminal = Set<String>()
        var lastProgress = Date.distantPast
        for (index, task) in tasks.enumerated() {
            // Path and string objects bridged while reading are freed per log, not once per scan.
            autoreleasepool {
                do {
                    let entry = try readTranscript(task)
                    switch task.owner {
                    case .desktop(let session):
                        if !entry.confirmedEdits.isEmpty {
                            let key = session.source.id + "\u{0}" + session.projectPath
                            if edits[key] == nil {
                                edits[key] = ProjectEdits(sourceID: session.source.id, projectPath: session.projectPath)
                            }
                            for (id, edit) in entry.confirmedEdits {
                                edits[key]?.record(id, edit, delegated: task.delegated)
                            }
                        }
                    case .terminal(let session):
                        // Folded per session below, so each edit counts where it landed.
                        let key = session.source.id + "\u{0}" + session.id
                        readTerminal.insert(key)
                        for (id, edit) in entry.confirmedEdits {
                            terminalEdits[key, default: ProjectEdits(sourceID: session.source.id, projectPath: session.workspace)]
                                .record(id, edit, delegated: task.delegated)
                        }
                    }
                    if entry.malformedLines > 0 {
                        notices.append("\(task.source.name): skipped unreadable records in session history \(task.url.deletingPathExtension().lastPathComponent).")
                    }
                    if entry.oversizedLines > 0 {
                        notices.append("\(task.source.name): a session history record was too large to index safely.")
                    }
                } catch {
                    notices.append("\(task.source.name): could not read a session's change history (\(error.localizedDescription)).")
                }
                let completed = index + 1
                if let progress, completed == tasks.count || Date().timeIntervalSince(lastProgress) >= 0.5 {
                    let placed = cachedTerminal.filter { !readTerminal.contains($0.key) }.merging(terminalEdits) { _, read in read }
                    progress(result(metadata: metadata, edits: edits, terminalEdits: placed, extraNotices: notices),
                             completed, tasks.count)
                    lastProgress = Date()
                }
            }
        }
        // Prune histories no longer belonging to a configured session.
        let activePaths = Set(tasks.map { $0.url.path })
        let kept = cache.filter { activePaths.contains($0.key) }
        if kept.count != cache.count {
            cache = kept
            cacheDirty = true
        }
        if Date().timeIntervalSince(lastCacheSave) >= historyCacheSaveInterval, let notice = saveCache() {
            notices.append(notice)
        }
        return result(metadata: metadata, edits: edits, terminalEdits: terminalEdits, extraNotices: notices)
    }

    /// Writes the transcript cache if a scan changed it since the last save.
    /// Returns a notice when it could not be saved; a later scan tries again.
    @discardableResult
    public func saveCache() -> String? {
        guard cacheDirty, let cacheURL else { return nil }
        do {
            try files.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(SavedCache(version: 2, transcripts: cache))
            try data.write(to: cacheURL, options: .atomic)
            try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
            cacheDirty = false
            lastCacheSave = Date()
            return nil
        } catch {
            return "The local activity cache could not be saved; the next launch may reindex change history."
        }
    }

    private struct DesktopSession {
        let source: AgentSource
        let id: String
        let cliIDs: Set<String>
        let projectPath: String
        let workspacePath: String
        let checkoutRoots: [String]
        let latestActivity: Date
        let createdAt: Date
    }

    /// A `claude` session started in a terminal. With no Desktop record, its own
    /// transcript says where it started, and its edits are folded like Codex's.
    private struct TerminalSession {
        let source: AgentSource
        let id: String
        /// The folder `claude` was started in, as recorded (lexical).
        let workspace: String
        let createdAt: Date
        let latestActivity: Date
        let files: SessionFiles
    }

    /// A session's logs under `projects`: `<id>.jsonl` and `<id>/subagents/…`.
    private struct SessionFiles {
        var transcripts: [URL] = []
        var subagents: [URL] = []
    }

    /// The first record that names the session's entrypoint and folder.
    private struct TranscriptHead {
        let entrypoint: String
        let cwd: String
        let createdAt: Date
    }

    private struct Metadata {
        var sessions: [DesktopSession] = []
        var terminal: [TerminalSession] = []
        /// Logs on disk, by source id and session id.
        var files: [String: [String: SessionFiles]] = [:]
        var notices: [String] = []
    }

    private struct DesktopRecord: Decodable {
        var sessionId: String?
        var cliSessionId: String?
        var priorCliSessionIds: [String]?
        var cwd: String?
        var originCwd: String?
        var worktreePath: String?
        var createdAt: Double?
        var lastActivityAt: Double?
        var gitAnchors: [Anchor]?
        struct Anchor: Decodable { var gitRoot: String? }
    }

    private func readMetadata(sources: [AgentSource]) -> Metadata {
        var result = Metadata()
        for source in sources {
            let desktop = readDesktopSessions(source: source, notices: &result.notices)
            let logs = listSessionFiles(source: source, required: desktop?.isEmpty == false, notices: &result.notices)
            result.files[source.id] = logs
            // A Desktop session's log is never also a terminal session, whatever
            // the log says; logs Desktop no longer lists stay unindexed, as before.
            let desktopIDs = Set((desktop ?? []).flatMap(\.cliIDs))
            var terminal: [TerminalSession] = []
            for (id, files) in logs where !desktopIDs.contains(id) {
                guard let transcript = files.transcripts.first,
                      let head = head(of: transcript), head.entrypoint == "cli",
                      let modified = try? FileStat.required(transcript).modified else { continue }
                terminal.append(TerminalSession(source: source, id: id, workspace: head.cwd, createdAt: head.createdAt,
                    latestActivity: max(modified, head.createdAt), files: files))
            }
            if desktop == nil && terminal.isEmpty {
                result.notices.append("\(source.name): no local Claude Code sessions were found.")
            }
            result.sessions += desktop ?? []
            result.terminal += terminal
        }
        result.sessions.sort { $0.latestActivity > $1.latestActivity }
        result.terminal.sort { $0.latestActivity != $1.latestActivity ? $0.latestActivity > $1.latestActivity : $0.id < $1.id }
        return result
    }

    /// Terminal sessions' edits as the transcript cache last saw them.
    private func cachedTerminalEdits(_ metadata: Metadata) -> [String: ProjectEdits] {
        var result: [String: ProjectEdits] = [:]
        for session in metadata.terminal {
            let key = session.source.id + "\u{0}" + session.id
            for (urls, delegated) in [(session.files.transcripts, false), (session.files.subagents, true)] {
                for url in urls {
                    guard let entry = cache[url.path], entry.terminal == true else { continue }
                    for (id, edit) in entry.confirmedEdits {
                        result[key, default: ProjectEdits(sourceID: session.source.id, projectPath: session.workspace)]
                            .record(id, edit, delegated: delegated)
                    }
                }
            }
        }
        return result
    }

    /// Nil when the profile has no Desktop session folder at all.
    private func readDesktopSessions(source: AgentSource, notices: inout [String]) -> [DesktopSession]? {
        let desktopRoot = source.userDataDirectory.map { ($0 as NSString).expandingTildeInPath }
            ?? (NSHomeDirectory() + "/Library/Application Support/Claude")
        let root = URL(fileURLWithPath: desktopRoot).appendingPathComponent("claude-code-sessions", isDirectory: true)
        guard files.fileExists(atPath: root.path) else { return nil }
        var enumerationFailed = false
        guard let enumerator = files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles], errorHandler: { _, _ in enumerationFailed = true; return true }) else {
            notices.append("\(source.name): the coding-session folder could not be read.")
            return []
        }
        var sessions: [DesktopSession] = []
        var unreadable = 0
        var seenIDs = Set<String>()
        for case let url as URL in enumerator where url.pathExtension == "json" && url.lastPathComponent.hasPrefix("local_") {
            // These files can also contain UI transcripts. Decode selected metadata
            // fields only; titles, prompts, outputs and credentials are never retained.
            do {
                let record = try JSONDecoder().decode(DesktopRecord.self, from: Data(contentsOf: url))
                guard let id = record.sessionId, !id.isEmpty, !seenIDs.contains(id),
                      let workspace = absolutePath(record.cwd ?? record.originCwd),
                      let project = absolutePath(record.originCwd) ?? absolutePath(record.cwd),
                      let milliseconds = record.lastActivityAt ?? record.createdAt,
                      milliseconds.isFinite, milliseconds > 0 else { continue }
                seenIDs.insert(id)
                let cliIDs = Set(([record.cliSessionId].compactMap { $0 } + (record.priorCliSessionIds ?? []))
                    .filter { !$0.isEmpty && !$0.contains("/") && $0 != "." && $0 != ".." })
                var roots = [project, workspace]
                roots += (record.gitAnchors ?? []).compactMap { absolutePath($0.gitRoot) }
                if let worktree = absolutePath(record.worktreePath) { roots.append(worktree) }
                let creationMilliseconds = record.createdAt.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? milliseconds
                sessions.append(DesktopSession(source: source, id: id, cliIDs: cliIDs,
                    projectPath: project, workspacePath: workspace,
                    checkoutRoots: Array(Set(roots)).sorted { $0.count > $1.count },
                    latestActivity: Date(timeIntervalSince1970: milliseconds / 1000),
                    createdAt: Date(timeIntervalSince1970: creationMilliseconds / 1000)))
            } catch { unreadable += 1 }
        }
        if unreadable > 0 { notices.append("\(source.name): \(unreadable) coding-session metadata file(s) could not be read.") }
        if enumerationFailed { notices.append("\(source.name): some coding-session folders could not be read.") }
        return sessions
    }

    /// Every session log under the profile's `projects` folder, by session id.
    /// A missing folder is reported only when Desktop sessions expect it.
    private func listSessionFiles(source: AgentSource, required: Bool, notices: inout [String]) -> [String: SessionFiles] {
        let root = URL(fileURLWithPath: (source.configDirectory as NSString).expandingTildeInPath)
            .appendingPathComponent("projects", isDirectory: true)
        var result: [String: SessionFiles] = [:]
        var failed = false
        if !required && !files.fileExists(atPath: root.path) { return result }
        do {
            let directories = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            for directory in directories.sorted(by: { $0.path < $1.path }) {
                guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                do {
                    let entries = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                    for url in entries.sorted(by: { $0.path < $1.path }) {
                        if url.pathExtension == "jsonl" {
                            result[url.deletingPathExtension().lastPathComponent, default: SessionFiles()].transcripts.append(url)
                        } else if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                            let subagents = url.appendingPathComponent("subagents", isDirectory: true)
                            guard files.fileExists(atPath: subagents.path),
                                  let enumerator = files.enumerator(at: subagents, includingPropertiesForKeys: [.isRegularFileKey],
                                    options: [.skipsHiddenFiles], errorHandler: { _, _ in failed = true; return true }) else { continue }
                            for case let transcript as URL in enumerator where transcript.pathExtension == "jsonl" {
                                result[url.lastPathComponent, default: SessionFiles()].subagents.append(transcript)
                            }
                        }
                    }
                } catch { failed = true }
            }
        } catch { failed = true }
        if failed { notices.append("\(source.name): some local change-history folders could not be read.") }
        return result
    }

    /// A transcript only grows, so its first records are read once per file.
    /// A file without them yet is read again once it grows.
    private func head(of url: URL) -> TranscriptHead? {
        guard let stat = try? FileStat.required(url) else { return nil }
        if let known = heads[url.path], known.identity == stat.identity, known.head != nil || known.size == stat.size {
            return known.head
        }
        let head = readHead(url)
        heads[url.path] = (stat.identity, stat.size, head)
        return head
    }

    /// Reads from the start of a transcript until a record names its entrypoint
    /// and folder. A line over 1 MB (an opening prompt with pasted images) is
    /// skipped unparsed, since later records carry the same fields. Only the
    /// entrypoint, folder and first timestamp are kept.
    private func readHead(_ url: URL) -> TranscriptHead? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let maxLineBytes = 1024 * 1024
        var buffer = Data()
        // Bytes at the start of `buffer` already known to hold no newline.
        var searched = 0
        var skippingLongLine = false
        var firstDate: Date?
        var consumed = 0
        while consumed < 64 * 1024 * 1024 {
            let found: TranscriptHead?? = autoreleasepool {
                guard let chunk = try? handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { return .some(nil) }
                consumed += chunk.count
                buffer.append(chunk)
                var start = buffer.startIndex
                var search = buffer.index(start, offsetBy: searched)
                defer {
                    buffer = Data(buffer[start...])
                    searched = buffer.count
                }
                while let newline = buffer[search...].firstIndex(of: 0x0A) {
                    let line = buffer[start..<newline]
                    start = buffer.index(after: newline)
                    search = start
                    if skippingLongLine {
                        skippingLongLine = false
                        continue
                    }
                    guard let record = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
                    if firstDate == nil, let stamp = record["timestamp"] as? String {
                        firstDate = isoDate.date(from: stamp) ?? plainISODate.date(from: stamp)
                    }
                    guard let entrypoint = record["entrypoint"] as? String,
                          let raw = record["cwd"] as? String, let cwd = ProjectLocationRegistry.lexicalPath(raw) else { continue }
                    guard let created = firstDate else { return .some(nil) }
                    return .some(TranscriptHead(entrypoint: entrypoint, cwd: cwd, createdAt: created))
                }
                if buffer.distance(from: start, to: buffer.endIndex) > maxLineBytes {
                    // Keep no part of an oversized line; skip to its end.
                    start = buffer.endIndex
                    skippingLongLine = true
                }
                return nil
            }
            if let found { return found }
        }
        return nil
    }

    private struct ProjectEdits {
        let sourceID: String
        let projectPath: String
        var byToolID: [String: ConfirmedEdit] = [:]
        /// Tool IDs whose earliest record exists only in subagent transcripts.
        var delegated: Set<String> = []

        /// Keeps the first occurrence, as `firstOccurrence` does. An identical
        /// root copy clears the flag, so the result is independent of order.
        mutating func record(_ id: String, _ edit: ConfirmedEdit, delegated isDelegated: Bool) {
            guard let existing = byToolID[id] else {
                byToolID[id] = edit
                if isDelegated { delegated.insert(id) }
                return
            }
            let incomingWins = edit.date < existing.date || (edit.date == existing.date && edit.workspace < existing.workspace)
            let identical = edit.date == existing.date && edit.workspace == existing.workspace
            if incomingWins {
                byToolID[id] = edit
                if isDelegated { delegated.insert(id) } else { delegated.remove(id) }
            } else if identical && !isDelegated {
                delegated.remove(id)
            }
        }
    }

    private func result(metadata: Metadata, edits: [String: ProjectEdits], terminalEdits: [String: ProjectEdits],
                        extraNotices: [String]) -> ScanResult {
        // Claude records the checkout itself. A checkout that has since moved
        // is found at its current path through learned earlier locations.
        func located(_ path: String, _ date: Date) -> String { resolver.physical(path, at: date) ?? path }
        var relocated: [String: ProjectEdits] = [:]
        for project in edits.values {
            autoreleasepool {
                for (id, edit) in project.byToolID {
                    let path = located(project.projectPath, edit.date)
                    let key = project.sourceID + "\u{0}" + path
                    let moved = ConfirmedEdit(date: edit.date, workspace: located(edit.workspace, edit.date))
                    relocated[key, default: ProjectEdits(sourceID: project.sourceID, projectPath: path)]
                        .record(id, moved, delegated: project.delegated.contains(id))
                }
            }
        }
        let sessionActivity: [ProjectActivity] = metadata.sessions.map {
            ProjectActivity(sourceID: $0.source.id, projectPath: located($0.projectPath, $0.createdAt),
                latestActivity: $0.latestActivity, workspacePath: located($0.workspacePath, $0.createdAt),
                history: [ActivityDay(day: $0.createdAt, sessionCount: 1)], sessionStarts: [$0.createdAt])
        }
        let editActivity: [ProjectActivity] = relocated.values.compactMap { project -> ProjectActivity? in
            guard let latest = project.byToolID.values.max(by: { $0.date < $1.date }) else { return nil }
            let days = Dictionary(grouping: project.byToolID.values, by: { ActivityDay.start(of: $0.date) })
                .map { ActivityDay(day: $0.key, editCount: $0.value.count) }
            let moments: [EditMoment] = project.byToolID.map {
                EditMoment(date: $0.value.date, delegated: project.delegated.contains($0.key))
            }.sorted(by: EditMoment.chronological)
            return ProjectActivity(sourceID: project.sourceID, projectPath: project.projectPath,
                latestActivity: latest.date, latestEdit: latest.date, sessionCount: 0,
                workspacePath: latest.workspace, latestEditWorkspacePath: latest.workspace,
                history: days, editMoments: moments)
        }
        // Terminal sessions have no Desktop record naming their checkout. Each
        // edit counts for the checkout it landed in, and a session started
        // above a repository joins it, exactly as for Codex and Grok.
        let terminal = metadata.terminal.map { session -> HistorySession in
            let recorded = terminalEdits[session.source.id + "\u{0}" + session.id]
            var stored: [String: StoredEdit] = [:]
            for (id, edit) in recorded?.byToolID ?? [:] {
                guard let target = edit.targetDirectory else { continue }
                // Derived again here, so edits cached by an earlier rule fold the same way.
                stored[id] = StoredEdit(date: edit.date, workspace: terminalWorkspace(target, launch: session.workspace),
                                        targetDirectories: [target])
            }
            return HistorySession(sourceID: session.source.id, sessionID: session.id, recordedWorkspace: session.workspace,
                roots: [session.workspace], createdAt: session.createdAt, latestActivity: session.latestActivity,
                edits: stored, delegatedEdits: recorded?.delegated ?? [])
        }
        let folded = HistoryFold.fold(terminal, resolver: resolver)
        return ScanResult(projects: ProjectSummary.merge(sessionActivity + editActivity + folded.activity),
            notices: Array(Set(metadata.notices + extraNotices)).sorted(),
            sessionProjects: folded.associations, missingFolders: folded.missingFolders)
    }

    private enum Owner {
        case desktop(DesktopSession)
        case terminal(TerminalSession)
    }

    private struct TranscriptTask {
        let url: URL
        let owner: Owner
        /// Read from the session's `subagents` folder. Taken from the location
        /// at scan time, so the transcript cache needs no new field.
        let delegated: Bool

        var source: AgentSource {
            switch owner {
            case .desktop(let session): return session.source
            case .terminal(let session): return session.source
            }
        }
        var isTerminal: Bool {
            if case .terminal = owner { return true }
            return false
        }
        var latestActivity: Date {
            switch owner {
            case .desktop(let session): return session.latestActivity
            case .terminal(let session): return session.latestActivity
            }
        }
    }

    private func discoverTranscripts(metadata: Metadata, notices: inout [String]) -> [TranscriptTask] {
        var tasks: [TranscriptTask] = []
        let grouped = Dictionary(grouping: metadata.sessions, by: { $0.source.id })
        for sessions in grouped.values {
            guard let source = sessions.first?.source else { continue }
            var byCLI: [String: DesktopSession] = [:]
            for session in sessions { for id in session.cliIDs where byCLI[id] == nil { byCLI[id] = session } }
            var foundSessions = Set<String>()
            for (id, files) in metadata.files[source.id] ?? [:] {
                guard let session = byCLI[id] else { continue }
                for url in files.transcripts { tasks.append(TranscriptTask(url: url, owner: .desktop(session), delegated: false)) }
                for url in files.subagents { tasks.append(TranscriptTask(url: url, owner: .desktop(session), delegated: true)) }
                if !files.transcripts.isEmpty || !files.subagents.isEmpty { foundSessions.insert(session.id) }
            }
            let missing = sessions.filter { !foundSessions.contains($0.id) }.count
            if missing > 0 { notices.append("\(source.name): edit history is unavailable for \(missing) desktop session(s).") }
        }
        for session in metadata.terminal {
            for url in session.files.transcripts { tasks.append(TranscriptTask(url: url, owner: .terminal(session), delegated: false)) }
            for url in session.files.subagents { tasks.append(TranscriptTask(url: url, owner: .terminal(session), delegated: true)) }
        }
        return tasks.sorted {
            if $0.latestActivity != $1.latestActivity { return $0.latestActivity > $1.latestActivity }
            return $0.url.path < $1.url.path
        }
    }

    private struct PendingTool: Codable {
        let name: String
        let path: String
    }
    private struct ConfirmedEdit: Codable {
        let date: Date
        /// A Desktop session's checkout, or a terminal session's working folder.
        let workspace: String
        /// Terminal sessions only: the target's parent folder, as recorded.
        /// It decides at fold time which checkout the edit landed in.
        var targetDirectory: String? = nil
    }
    private func firstOccurrence(_ first: ConfirmedEdit, _ second: ConfirmedEdit) -> ConfirmedEdit {
        if first.date != second.date { return first.date < second.date ? first : second }
        return first.workspace <= second.workspace ? first : second
    }
    private struct TranscriptCache: Codable {
        var identity: String
        var size: UInt64 = 0
        var modified: TimeInterval = 0
        var offset: UInt64 = 0
        var checkpoint: UInt64 = 0
        var pending: [String: PendingTool] = [:]
        // Tool IDs make replays idempotent. The second deduplication across files
        // prevents copied root/subagent records inflating a project's statistics.
        var confirmedEdits: [String: ConfirmedEdit] = [:]
        var malformedLines: Int = 0
        var oversizedLines: Int = 0
        var droppingOversizedLine: Bool = false
        /// True for a terminal session's log, whose edits keep their target
        /// folders. Missing in older caches, which held Desktop logs only.
        var terminal: Bool? = nil
    }
    private struct SavedCache: Codable {
        let version: Int
        let transcripts: [String: TranscriptCache]
    }
    private struct CacheHeader: Decodable { let version: Int }

    private func readTranscript(_ task: TranscriptTask) throws -> TranscriptCache {
        let metadata = try FileStat.required(task.url)
        let size = metadata.size
        let modified = metadata.modified.timeIntervalSince1970
        let identity = metadata.identity
        let handle = try FileHandle(forReadingFrom: task.url)
        defer { try? handle.close() }
        let kind: Bool? = task.isTerminal ? true : nil
        var entry = cache[task.url.path] ?? TranscriptCache(identity: identity, terminal: kind)
        // A log that changed owner kind is reread: its stored edits mean something else.
        let sameIdentity = entry.identity == identity && entry.terminal == kind
        var reusable = sameIdentity && size >= entry.offset && size >= entry.size
        if reusable, size == entry.size, modified != entry.modified { reusable = false }
        if reusable, entry.offset > 0, try checkpoint(handle, offset: entry.offset) != entry.checkpoint { reusable = false }
        if !reusable { entry = TranscriptCache(identity: identity, terminal: kind) }
        if reusable, entry.size == size, entry.modified == modified { return entry }
        try handle.seek(toOffset: entry.offset)
        var buffer = Data()
        var droppingOversizedLine = entry.droppingOversizedLine
        let maxLineBytes = 64 * 1024 * 1024
        let newlineByte = Data([0x0A])
        while true {
            let hadChunk: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { return false }
                let previouslySearched = buffer.count
                buffer.append(chunk)
                var start = buffer.startIndex
                // The old partial buffer is already known to contain no newline.
                // Search only newly read bytes, avoiding quadratic work on large lines.
                var search = buffer.index(buffer.startIndex, offsetBy: previouslySearched)
                while let newline = buffer.range(of: newlineByte, in: search..<buffer.endIndex)?.lowerBound {
                    if !droppingOversizedLine {
                        autoreleasepool {
                            parseLine(buffer[start..<newline], task: task, entry: &entry)
                        }
                    }
                    let next = buffer.index(after: newline)
                    entry.offset += UInt64(buffer.distance(from: start, to: next))
                    start = next
                    search = next
                    droppingOversizedLine = false
                }
                if start != buffer.startIndex { buffer = Data(buffer[start...]) }
                if buffer.count > maxLineBytes {
                    // Keep no transcript bytes in the cache, including partial records.
                    entry.offset += UInt64(buffer.count)
                    buffer.removeAll(keepingCapacity: false)
                    if !droppingOversizedLine { entry.oversizedLines += 1 }
                    droppingOversizedLine = true
                }
                return true
            }
            if !hadChunk { break }
        }
        // An ordinary partial line is reread after its remainder arrives, including
        // across restarts. Discarded oversized lines retain their explicit skip state.
        entry.size = size
        entry.modified = modified
        entry.droppingOversizedLine = droppingOversizedLine
        entry.checkpoint = try checkpoint(handle, offset: entry.offset)
        cache[task.url.path] = entry
        cacheDirty = true
        return entry
    }

    private func checkpoint(_ handle: FileHandle, offset: UInt64) throws -> UInt64 {
        let count = min(offset, 256)
        try handle.seek(toOffset: offset - count)
        let bytes = try handle.read(upToCount: Int(count)) ?? Data()
        // A content-free fingerprint detects replacement/truncate-and-regrow.
        return bytes.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }

    private func parseLine(_ line: Data, task: TranscriptTask, entry: inout TranscriptCache) {
        guard !line.isEmpty else { return }
        // Inspect the top-level type without decoding nested API blobs (which can
        // themselves contain copied tool events). JSON string values are skipped.
        guard let eventType = topLevelEventType(line), eventType == "assistant" || eventType == "user" else { return }
        guard line.range(of: Data("\"tool_use\"".utf8)) != nil || line.range(of: Data("\"tool_result\"".utf8)) != nil else { return }
        guard let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            entry.malformedLines += 1
            return
        }
        guard let type = event["type"] as? String, type == "assistant" || type == "user",
              let message = event["message"] as? [String: Any], let blocks = message["content"] as? [[String: Any]] else { return }
        if type == "assistant" {
            for block in blocks where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String, name == "Edit" || name == "Write",
                      let id = block["id"] as? String, let input = block["input"] as? [String: Any],
                      let path = input["file_path"] as? String, !path.isEmpty else { continue }
                entry.pending[id] = PendingTool(name: name, path: path)
            }
        } else {
            for block in blocks where block["type"] as? String == "tool_result" {
                guard let id = block["tool_use_id"] as? String, let pending = entry.pending.removeValue(forKey: id),
                      (block["is_error"] as? Bool) != true else { continue }
                let details = event["toolUseResult"] as? [String: Any]
                guard (details?["userModified"] as? Bool) != true,
                      let timestamp = event["timestamp"] as? String,
                      let date = isoDate.date(from: timestamp) ?? plainISODate.date(from: timestamp) else { continue }
                let path = details?["filePath"] as? String ?? pending.path
                let edit: ConfirmedEdit
                switch task.owner {
                case .desktop(let session):
                    guard let workspace = editWorkspace(path: path, cwd: event["cwd"] as? String, session: session) else { continue }
                    edit = ConfirmedEdit(date: date, workspace: workspace)
                case .terminal(let session):
                    // Recorded spellings only; the fold resolves links and checkouts.
                    // The shell's `cd` moves this cwd, so it only resolves a relative path.
                    let cwd = (event["cwd"] as? String).flatMap(ProjectLocationRegistry.lexicalPath) ?? session.workspace
                    guard !path.isEmpty, let target = ProjectLocationRegistry.lexicalPath(
                        path.hasPrefix("/") || path.hasPrefix("~/") ? path : (cwd as NSString).appendingPathComponent(path)) else { continue }
                    let directory = (target as NSString).deletingLastPathComponent
                    edit = ConfirmedEdit(date: date, workspace: terminalWorkspace(directory, launch: session.workspace),
                                         targetDirectory: directory)
                }
                entry.confirmedEdits[id] = entry.confirmedEdits[id].map { firstOccurrence($0, edit) } ?? edit
            }
        }
    }

    private func topLevelEventType(_ data: Data) -> String? {
        data.withUnsafeBytes { raw -> String? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 0
            var depth = 0
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 { // JSON string; respect escaped quotes.
                    let start = index + 1
                    index += 1
                    while index < bytes.count {
                        if bytes[index] == 0x5C { index += 2; continue }
                        if bytes[index] == 0x22 { break }
                        index += 1
                    }
                    let end = index
                    index += 1
                    guard depth == 1, end - start == 4,
                          bytes[start] == 0x74, bytes[start + 1] == 0x79,
                          bytes[start + 2] == 0x70, bytes[start + 3] == 0x65 else { continue }
                    while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0D { index += 1 }
                    guard index < bytes.count, bytes[index] == 0x3A else { continue }
                    index += 1
                    while index < bytes.count, bytes[index] == 0x20 || bytes[index] == 0x09 || bytes[index] == 0x0D { index += 1 }
                    guard index < bytes.count, bytes[index] == 0x22 else { return nil }
                    let valueStart = index + 1
                    index += 1
                    while index < bytes.count, bytes[index] != 0x22, bytes[index] != 0x5C { index += 1 }
                    guard index < bytes.count, bytes[index] == 0x22 else { return nil }
                    return String(decoding: bytes[valueStart..<index], as: UTF8.self)
                } else {
                    if byte == 0x7B || byte == 0x5B { depth += 1 }
                    if byte == 0x7D || byte == 0x5D { depth -= 1 }
                    index += 1
                }
            }
            return nil
        }
    }

    private func absolutePath(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return canonicalPath(expanded)
    }

    private func editWorkspace(path: String, cwd: String?, session: DesktopSession) -> String? {
        let eventCwd = absolutePath(cwd) ?? session.workspacePath
        guard let knownRoot = session.checkoutRoots.first(where: { contains($0, eventCwd) }) else { return nil }
        let root = claudeWorktreeRoot(eventCwd) ?? knownRoot
        let target = canonicalPath(path.hasPrefix("/") ? path : (eventCwd as NSString).appendingPathComponent(path))
        guard contains(root, target) else { return nil }
        // Edits under a nested Claude worktree are never claimed as edits to the
        // parent checkout. Origin grouping retains this actual workspace path.
        return claudeWorktreeRoot(target) ?? root
    }

    /// A terminal edit's workspace: the folder `claude` was started in, or the
    /// Claude worktree inside it that holds the file. The fold credits the
    /// file's own checkout either way; this keeps a `cd` elsewhere from dropping it.
    private func terminalWorkspace(_ targetDirectory: String, launch: String) -> String {
        guard let worktree = claudeWorktreeRoot(targetDirectory),
              CheckoutPath.contains(root: launch, path: worktree) else { return launch }
        return worktree
    }

    private func contains(_ root: String, _ child: String) -> Bool {
        child == root || child.hasPrefix(root == "/" ? "/" : root + "/")
    }

    private func claudeWorktreeRoot(_ path: String) -> String? {
        let parts = (path as NSString).pathComponents
        guard parts.count >= 4 else { return nil }
        for index in stride(from: parts.count - 3, through: 0, by: -1) {
            if parts[index] == ".claude", parts[index + 1] == "worktrees", index + 2 < parts.count {
                return NSString.path(withComponents: Array(parts[...(index + 2)]))
            }
        }
        return nil
    }
}
