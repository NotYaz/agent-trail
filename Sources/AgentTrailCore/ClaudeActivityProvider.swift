import Foundation

/// A read-only adapter for Claude Desktop's two local profiles. Call on a background
/// queue: the first history scan can read substantial JSONL files. Only successful
/// Edit/Write tools are attributed; shell commands and file mtimes are not evidence.
public final class ClaudeActivityProvider: ActivityProvider {
    private let cacheURL: URL?
    private var cache: [String: TranscriptCache] = [:]
    private var cacheLoadNotice: String?
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
                }
            } catch {
                cacheLoadNotice = "The local activity cache could not be read; change history will be rebuilt."
            }
        }
    }

    /// Fast project/activity listing without reading conversation transcripts.
    public func metadata(sources: [AgentSource]) -> ScanResult {
        if ownsResolver { resolver.reset() }
        let metadata = readMetadata(sources: sources)
        return result(metadata: metadata, edits: [:], extraNotices: [])
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
        var lastProgress = Date.distantPast
        for (index, task) in tasks.enumerated() {
            do {
                let entry = try readTranscript(task)
                if !entry.confirmedEdits.isEmpty {
                    let key = task.session.source.id + "\u{0}" + task.session.projectPath
                    if edits[key] == nil {
                        edits[key] = ProjectEdits(sourceID: task.session.source.id, projectPath: task.session.projectPath)
                    }
                    for (id, edit) in entry.confirmedEdits {
                        edits[key]?.record(id, edit, delegated: task.delegated)
                    }
                }
                if entry.malformedLines > 0 {
                    notices.append("\(task.session.source.name): skipped unreadable records in session history \(task.url.deletingPathExtension().lastPathComponent).")
                }
                if entry.oversizedLines > 0 {
                    notices.append("\(task.session.source.name): a session history record was too large to index safely.")
                }
            } catch {
                notices.append("\(task.session.source.name): could not read a session's change history (\(error.localizedDescription)).")
            }
            let completed = index + 1
            if let progress, completed == tasks.count || Date().timeIntervalSince(lastProgress) >= 0.5 {
                progress(result(metadata: metadata, edits: edits, extraNotices: notices), completed, tasks.count)
                lastProgress = Date()
            }
        }
        // Prune histories no longer belonging to the configured desktop sessions.
        let activePaths = Set(tasks.map { $0.url.path })
        cache = cache.filter { activePaths.contains($0.key) }
        if let cacheURL {
            do {
                try files.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(SavedCache(version: 2, transcripts: cache))
                try data.write(to: cacheURL, options: .atomic)
                try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
            } catch {
                notices.append("The local activity cache could not be saved; the next launch may reindex change history.")
            }
        }
        return result(metadata: metadata, edits: edits, extraNotices: notices)
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

    private struct Metadata {
        var sessions: [DesktopSession] = []
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
            let desktopRoot = source.userDataDirectory.map { ($0 as NSString).expandingTildeInPath }
                ?? (NSHomeDirectory() + "/Library/Application Support/Claude")
            let root = URL(fileURLWithPath: desktopRoot).appendingPathComponent("claude-code-sessions", isDirectory: true)
            guard files.fileExists(atPath: root.path) else {
                result.notices.append("\(source.name): no local Claude Desktop coding-session metadata was found.")
                continue
            }
            var enumerationFailed = false
            guard let enumerator = files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in enumerationFailed = true; return true }) else {
                result.notices.append("\(source.name): the coding-session folder could not be read.")
                continue
            }
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
                    result.sessions.append(DesktopSession(source: source, id: id, cliIDs: cliIDs,
                        projectPath: project, workspacePath: workspace,
                        checkoutRoots: Array(Set(roots)).sorted { $0.count > $1.count },
                        latestActivity: Date(timeIntervalSince1970: milliseconds / 1000),
                        createdAt: Date(timeIntervalSince1970: creationMilliseconds / 1000)))
                } catch { unreadable += 1 }
            }
            if unreadable > 0 { result.notices.append("\(source.name): \(unreadable) coding-session metadata file(s) could not be read.") }
            if enumerationFailed { result.notices.append("\(source.name): some coding-session folders could not be read.") }
        }
        result.sessions.sort { $0.latestActivity > $1.latestActivity }
        return result
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

    private func result(metadata: Metadata, edits: [String: ProjectEdits], extraNotices: [String]) -> ScanResult {
        // Claude records the checkout itself. A checkout that has since moved
        // is found at its current path through learned earlier locations.
        func located(_ path: String, _ date: Date) -> String { resolver.physical(path, at: date) ?? path }
        var relocated: [String: ProjectEdits] = [:]
        for project in edits.values {
            for (id, edit) in project.byToolID {
                let path = located(project.projectPath, edit.date)
                let key = project.sourceID + "\u{0}" + path
                let moved = ConfirmedEdit(date: edit.date, workspace: located(edit.workspace, edit.date))
                relocated[key, default: ProjectEdits(sourceID: project.sourceID, projectPath: path)]
                    .record(id, moved, delegated: project.delegated.contains(id))
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
        return ScanResult(projects: ProjectSummary.merge(sessionActivity + editActivity),
            notices: Array(Set(metadata.notices + extraNotices)).sorted())
    }

    private struct TranscriptTask {
        let url: URL
        let session: DesktopSession
        /// Read from the session's `subagents` folder. Taken from the location
        /// at scan time, so the transcript cache needs no new field.
        let delegated: Bool
    }

    private func discoverTranscripts(metadata: Metadata, notices: inout [String]) -> [TranscriptTask] {
        var tasks: [TranscriptTask] = []
        let grouped = Dictionary(grouping: metadata.sessions, by: { $0.source.id })
        for sessions in grouped.values {
            guard let source = sessions.first?.source else { continue }
            let root = URL(fileURLWithPath: (source.configDirectory as NSString).expandingTildeInPath)
                .appendingPathComponent("projects", isDirectory: true)
            var byCLI: [String: DesktopSession] = [:]
            for session in sessions { for id in session.cliIDs where byCLI[id] == nil { byCLI[id] = session } }
            var foundSessions = Set<String>()
            var failed = false
            do {
                let directories = try files.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
                for directory in directories {
                    guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                    do {
                        for url in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                            if url.pathExtension == "jsonl", let session = byCLI[url.deletingPathExtension().lastPathComponent] {
                                tasks.append(TranscriptTask(url: url, session: session, delegated: false))
                                foundSessions.insert(session.id)
                            } else if let session = byCLI[url.lastPathComponent],
                                      (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                                let subagents = url.appendingPathComponent("subagents", isDirectory: true)
                                if files.fileExists(atPath: subagents.path),
                                   let enumerator = files.enumerator(at: subagents, includingPropertiesForKeys: [.isRegularFileKey],
                                    options: [.skipsHiddenFiles], errorHandler: { _, _ in failed = true; return true }) {
                                    for case let transcript as URL in enumerator where transcript.pathExtension == "jsonl" {
                                        tasks.append(TranscriptTask(url: transcript, session: session, delegated: true))
                                        foundSessions.insert(session.id)
                                    }
                                }
                            }
                        }
                    } catch { failed = true }
                }
            } catch { failed = true }
            let missing = sessions.filter { !foundSessions.contains($0.id) }.count
            if missing > 0 { notices.append("\(source.name): edit history is unavailable for \(missing) desktop session(s).") }
            if failed { notices.append("\(source.name): some local change-history folders could not be read.") }
        }
        // Do not index terminal-only Claude logs from the same config directory.
        return tasks.sorted {
            if $0.session.latestActivity != $1.session.latestActivity { return $0.session.latestActivity > $1.session.latestActivity }
            return $0.url.path < $1.url.path
        }
    }

    private struct PendingTool: Codable {
        let name: String
        let path: String
    }
    private struct ConfirmedEdit: Codable {
        let date: Date
        let workspace: String
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
        var entry = cache[task.url.path] ?? TranscriptCache(identity: identity)
        let sameIdentity = entry.identity == identity
        var reusable = sameIdentity && size >= entry.offset && size >= entry.size
        if reusable, size == entry.size, modified != entry.modified { reusable = false }
        if reusable, entry.offset > 0, try checkpoint(handle, offset: entry.offset) != entry.checkpoint { reusable = false }
        if !reusable { entry = TranscriptCache(identity: identity) }
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
                      let date = isoDate.date(from: timestamp) ?? plainISODate.date(from: timestamp),
                      let workspace = editWorkspace(path: details?["filePath"] as? String ?? pending.path,
                          cwd: event["cwd"] as? String, session: task.session) else { continue }
                let edit = ConfirmedEdit(date: date, workspace: workspace)
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
