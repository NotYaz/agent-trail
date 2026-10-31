import Foundation

/// Read-only adapter for Grok sessions under `$GROK_HOME` (`~/.grok` by default).
/// The folder a session was started in comes from `summary.json` `info.cwd`,
/// never from the encoded directory name. A completed `write` or
/// `search_replace` tool call with an `EditsApplied` result is one edit, and it
/// counts for the Git checkout its files physically landed in.
/// Shell commands and file modification times are not evidence. Live status is
/// not inferred from `active_sessions.json`. The cache keeps recorded evidence
/// only, so learned project locations never force a reparse.
public final class GrokActivityProvider: ActivityProvider {
    static let cacheVersion = 4
    private let cacheURL: URL?
    private var cache: [String: GrokFile] = [:]
    private var cacheLoadNotice: String?
    private let files = FileManager.default
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
        self.cacheURL = cacheURL
        self.resolver = resolver
        self.ownsResolver = ownsResolver
        guard let cacheURL, files.fileExists(atPath: cacheURL.path) else { return }
        do {
            let data = try Data(contentsOf: cacheURL)
            let header = try JSONDecoder().decode(GrokCacheHeader.self, from: data)
            if header.version == Self.cacheVersion {
                cache = try JSONDecoder().decode(GrokSavedCache.self, from: data).files
            } else {
                cacheLoadNotice = "Grok edit history is being rebuilt once for the current indexer."
            }
        } catch {
            cacheLoadNotice = "The Grok activity cache could not be read; change history will be rebuilt."
        }
    }

    public func metadata(sources: [AgentSource]) -> ScanResult {
        if ownsResolver { resolver.reset() }
        let discovered = discover(sources: sources)
        // Reuse cached edit evidence so sessions land where the last scan put them.
        return result(sessions: discovered.sessions, parsed: cache, includeEdits: true, extraNotices: discovered.notices)
    }

    public func scan(sources: [AgentSource]) -> ScanResult {
        scan(sources: sources, progress: nil)
    }

    public func scan(sources: [AgentSource], progress: ((ScanResult, Int, Int) -> Void)?) -> ScanResult {
        if ownsResolver { resolver.reset() }
        let discovered = discover(sources: sources)
        let sessions = discovered.sessions
        var notices = discovered.notices + (cacheLoadNotice.map { [$0] } ?? [])
        cacheLoadNotice = nil
        var parsed: [String: GrokFile] = [:]
        let tasks = sessions.flatMap { session in session.updates.map { (session, $0) } }
        var lastProgress = Date.distantPast
        for (index, task) in tasks.enumerated() {
            let file = cache[task.1.path] ?? GrokFile()
            if file.projectPath != task.0.projectPath {
                file.projectPath = task.0.projectPath
                file.tail = TailState()
                file.resetDerived()
            }
            do {
                try JSONLTail.read(url: task.1, state: &file.tail, reset: { file.resetDerived() }) { line in
                    parse(line, file: file)
                }
                cache[task.1.path] = file
                parsed[task.1.path] = file
                if file.tail.malformedLines > 0 {
                    notices.append("\(task.0.source.name): skipped unreadable records in a Grok session history.")
                }
                if file.tail.oversizedLines > 0 {
                    notices.append("\(task.0.source.name): a Grok session history record was too large to index safely.")
                }
            } catch {
                notices.append("\(task.0.source.name): could not read a Grok session's change history.")
            }
            let completed = index + 1
            if let progress, completed == tasks.count || Date().timeIntervalSince(lastProgress) >= 0.5 {
                progress(result(sessions: sessions, parsed: parsed, includeEdits: true, extraNotices: notices), completed, tasks.count)
                lastProgress = Date()
            }
        }
        let active = Set(tasks.map { $0.1.path })
        cache = cache.filter { active.contains($0.key) }
        if let cacheURL {
            do {
                try files.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(GrokSavedCache(version: Self.cacheVersion, files: cache))
                try data.write(to: cacheURL, options: .atomic)
                try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
            } catch {
                notices.append("The Grok activity cache could not be saved; the next launch may reindex change history.")
            }
        }
        return result(sessions: sessions, parsed: parsed, includeEdits: true, extraNotices: notices)
    }

    private struct GrokSession {
        var source: AgentSource
        var id: String
        var projectPath: String
        var createdAt: Date
        var latestActivity: Date
        var updates: [URL]
    }

    private func discover(sources: [AgentSource]) -> (sessions: [GrokSession], notices: [String]) {
        var sessions: [GrokSession] = []
        var notices: [String] = []
        var seen: [String: Int] = [:]
        for source in sources where source.assistant == .grok {
            let home = URL(fileURLWithPath: (source.configDirectory as NSString).expandingTildeInPath, isDirectory: true)
            let root = home.appendingPathComponent("sessions", isDirectory: true)
            guard files.fileExists(atPath: home.path) else {
                notices.append("\(source.name): no local Grok home was found.")
                continue
            }
            guard files.fileExists(atPath: root.path) else {
                notices.append("\(source.name): no local Grok session history was found.")
                continue
            }
            var unreadable = false
            guard let enumerator = files.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in unreadable = true; return true }) else {
                notices.append("\(source.name): the Grok session folder could not be read.")
                continue
            }
            var omitted = 0
            for case let url as URL in enumerator where url.lastPathComponent == "summary.json" {
                guard let session = readSummary(url, source: source) else {
                    omitted += 1
                    continue
                }
                let key = source.id + "\u{0}" + session.id
                if let index = seen[key] {
                    if sessions[index].projectPath == session.projectPath {
                        if session.createdAt < sessions[index].createdAt { sessions[index].createdAt = session.createdAt }
                        if session.latestActivity > sessions[index].latestActivity { sessions[index].latestActivity = session.latestActivity }
                        sessions[index].updates = Array(Set(sessions[index].updates + session.updates)).sorted { $0.path < $1.path }
                    }
                    continue
                }
                seen[key] = sessions.count
                sessions.append(session)
            }
            if omitted > 0 { notices.append("\(source.name): \(omitted) Grok session summary file(s) had no project path and were omitted.") }
            if unreadable { notices.append("\(source.name): some Grok session folders could not be read.") }
        }
        return (sessions.sorted { $0.latestActivity > $1.latestActivity }, notices)
    }

    private func readSummary(_ url: URL, source: AgentSource) -> GrokSession? {
        guard let data = try? Data(contentsOf: url), data.count <= 1_048_576,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let info = object["info"] as? [String: Any],
              let id = info["id"] as? String, !id.isEmpty,
              let cwd = info["cwd"] as? String,
              let project = ProjectLocationRegistry.lexicalPath(cwd),
              let created = (object["created_at"] as? String).flatMap(RecordedDate.parse) else { return nil }
        let updated = (object["last_active_at"] as? String).flatMap(RecordedDate.parse)
            ?? (object["updated_at"] as? String).flatMap(RecordedDate.parse)
            ?? created
        let updates = url.deletingLastPathComponent().appendingPathComponent("updates.jsonl")
        return GrokSession(source: source, id: id, projectPath: project, createdAt: created,
            latestActivity: max(created, updated), updates: files.fileExists(atPath: updates.path) ? [updates] : [])
    }

    private func result(sessions: [GrokSession], parsed: [String: GrokFile], includeEdits: Bool, extraNotices: [String]) -> ScanResult {
        let history = sessions.map { session -> HistorySession in
            var edits: [String: StoredEdit] = [:]
            if includeEdits {
                // Copies of the same session may contain different portions of
                // history. Combine all of their evidence before attributing it.
                for path in session.updates.map(\.path) {
                    guard let file = parsed[path], file.projectPath == session.projectPath else { continue }
                    for (id, edit) in file.edits { edits[id] = edits[id]?.earlier(than: edit) ?? edit }
                }
            }
            return HistorySession(sourceID: session.source.id, sessionID: session.id,
                recordedWorkspace: session.projectPath, roots: [session.projectPath], createdAt: session.createdAt,
                latestActivity: session.latestActivity, edits: edits)
        }
        let folded = HistoryFold.fold(history, resolver: resolver)
        var notices = extraNotices
        let missingHistory = sessions.filter { $0.updates.isEmpty }.count
        if missingHistory > 0 {
            notices.append("Grok: edit history is unavailable for \(missingHistory) session(s).")
        }
        return ScanResult(projects: ProjectSummary.merge(folded.activity), notices: Array(Set(notices)).sorted(),
            sessionProjects: folded.associations, missingFolders: folded.missingFolders)
    }

    @discardableResult
    private func parse(_ line: Data, file: GrokFile) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return false }
        guard let params = object["params"] as? [String: Any],
              let update = params["update"] as? [String: Any] else { return true }
        let event = update["sessionUpdate"] as? String
        guard event == "tool_call" || event == "tool_call_update" else { return true }
        guard let id = update["toolCallId"] as? String, !id.isEmpty else { return true }
        if let name = toolName(update), name == "write" || name == "search_replace",
           let path = (update["rawInput"] as? [String: Any])?["file_path"] as? String, !path.isEmpty {
            file.pending[id] = path
        }
        guard let status = update["status"] as? String else { return true }
        guard status == "completed" else {
            if status != "in_progress" { file.pending.removeValue(forKey: id) }
            return true
        }
        guard file.pending.removeValue(forKey: id) != nil else { return true }
        // Record evidence only; where the files physically are is decided when folding.
        guard let output = update["rawOutput"] as? [String: Any],
              output["type"] as? String == "SearchReplace", output["is_error"] as? Bool != true,
              let paths = editedPaths(output) else { return true }
        guard let date = RecordedDate.any(object["timestamp"]) else { return true }
        let directories = Array(Set(paths.map { ($0 as NSString).deletingLastPathComponent })).sorted()
        let edit = StoredEdit(date: date, workspace: file.projectPath, targetDirectories: directories)
        file.edits[id] = file.edits[id]?.earlier(than: edit) ?? edit
        return true
    }

    private func toolName(_ update: [String: Any]) -> String? {
        guard let meta = update["_meta"] as? [String: Any],
              let tool = meta["x.ai/tool"] as? [String: Any] else { return nil }
        return tool["name"] as? String
    }

    private func editedPaths(_ output: [String: Any]) -> [String]? {
        // Native write and search_replace successes both use SearchReplace /
        // EditsApplied. A completed status alone does not prove a file changed.
        if let one = output["EditsApplied"] as? [String: Any] {
            return (one["absolute_path"] as? String).flatMap(ProjectLocationRegistry.lexicalPath).map { [$0] }
        }
        guard let many = output["EditsApplied"] as? [[String: Any]], !many.isEmpty else { return nil }
        var paths: [String] = []
        for edit in many {
            guard let raw = edit["absolute_path"] as? String,
                  let path = ProjectLocationRegistry.lexicalPath(raw) else { return nil }
            paths.append(path)
        }
        return paths
    }
}

private final class GrokFile: Codable {
    var tail = TailState()
    var projectPath: String = ""
    var pending: [String: String] = [:]
    var edits: [String: StoredEdit] = [:]

    init() {}

    func resetDerived() {
        pending = [:]
        edits = [:]
    }
}

private struct GrokSavedCache: Codable {
    var version: Int
    var files: [String: GrokFile]
}

private struct GrokCacheHeader: Decodable { let version: Int }
