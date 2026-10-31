import Foundation

/// Read-only adapter for Codex rollout transcripts under `$CODEX_HOME`
/// (`~/.codex` unless the profile sets another home). A completed `FileChange`
/// item is one confirmed edit. Shell commands, `apply_patch` calls without a
/// completed FileChange, and file modification times are not evidence.
/// The cache keeps recorded evidence only; which project an edit belongs to is
/// decided when folding, so learned project locations never force a reparse.
public final class CodexActivityProvider: ActivityProvider {
    static let cacheVersion = 4
    private let cacheURL: URL?
    private var cache: [String: CodexFile] = [:]
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
            let header = try JSONDecoder().decode(CacheHeader.self, from: data)
            if header.version == Self.cacheVersion {
                cache = try JSONDecoder().decode(SavedCache.self, from: data).files
            } else {
                cacheLoadNotice = "Codex edit history is being rebuilt once for the current indexer."
            }
        } catch {
            cacheLoadNotice = "The Codex activity cache could not be read; change history will be rebuilt."
        }
    }

    /// A quick listing that reads session headers and reuses edit evidence
    /// already in the cache, so sessions appear on the same project the last
    /// full scan chose instead of briefly on the folder they were started in.
    public func metadata(sources: [AgentSource]) -> ScanResult {
        if ownsResolver { resolver.reset() }
        let discovered = discover(sources: sources)
        var known: [String: CodexFile] = [:]
        var unreadable = 0
        for task in discovered.files {
            if let file = cache[task.url.path] ?? readHeader(task.url) { known[task.url.path] = file } else { unreadable += 1 }
        }
        let notices = unreadable > 0 ? ["Codex: \(unreadable) session history file(s) had no project path and were omitted."] : []
        return fold(files: discovered, parsed: known, notices: notices)
    }

    public func scan(sources: [AgentSource]) -> ScanResult {
        scan(sources: sources, progress: nil)
    }

    public func scan(sources: [AgentSource], progress: ((ScanResult, Int, Int) -> Void)?) -> ScanResult {
        if ownsResolver { resolver.reset() }
        let discovered = discover(sources: sources)
        var notices = cacheLoadNotice.map { [$0] } ?? []
        cacheLoadNotice = nil
        let tasks = discovered.files
        var parsed: [String: CodexFile] = [:]
        var lastProgress = Date.distantPast
        for (index, task) in tasks.enumerated() {
            let file = cache[task.url.path] ?? CodexFile()
            do {
                try JSONLTail.read(url: task.url, state: &file.tail, reset: { file.resetDerived() }) { line in
                    parse(line, file: file, fallbackID: task.url.deletingPathExtension().lastPathComponent)
                }
                cache[task.url.path] = file
                parsed[task.url.path] = file
                if file.tail.malformedLines > 0 {
                    notices.append("\(task.source.name): skipped unreadable records in a Codex session history.")
                }
                if file.tail.oversizedLines > 0 {
                    notices.append("\(task.source.name): a Codex session history record was too large to index safely.")
                }
            } catch {
                notices.append("\(task.source.name): could not read a Codex session's change history.")
            }
            let completed = index + 1
            if let progress, completed == tasks.count || Date().timeIntervalSince(lastProgress) >= 0.5 {
                progress(fold(files: discovered, parsed: parsed, notices: notices), completed, tasks.count)
                lastProgress = Date()
            }
        }
        let active = Set(tasks.map { $0.url.path })
        cache = cache.filter { active.contains($0.key) }
        if let cacheURL {
            do {
                try files.createDirectory(at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(SavedCache(version: Self.cacheVersion, files: cache))
                try data.write(to: cacheURL, options: .atomic)
                try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cacheURL.path)
            } catch {
                notices.append("The Codex activity cache could not be saved; the next launch may reindex change history.")
            }
        }
        return fold(files: discovered, parsed: parsed, notices: notices)
    }

    private struct Rollout {
        let source: AgentSource
        let url: URL
    }

    private struct Discovered {
        var files: [Rollout] = []
        var notices: [String] = []
    }

    private func discover(sources: [AgentSource]) -> Discovered {
        var discovered = Discovered()
        for source in sources where source.assistant == .codex {
            let root = URL(fileURLWithPath: (source.configDirectory as NSString).expandingTildeInPath, isDirectory: true)
            guard files.fileExists(atPath: root.path) else {
                discovered.notices.append("\(source.name): no local Codex home was found.")
                continue
            }
            var foundFolder = false
            var unreadable = false
            var compressed = 0
            for name in ["sessions", "archived_sessions"] {
                let directory = root.appendingPathComponent(name, isDirectory: true)
                guard files.fileExists(atPath: directory.path) else { continue }
                foundFolder = true
                guard let enumerator = files.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles], errorHandler: { _, _ in unreadable = true; return true }) else {
                    unreadable = true
                    continue
                }
                for case let url as URL in enumerator {
                    if url.lastPathComponent.hasPrefix("rollout-"), url.pathExtension == "jsonl" {
                        discovered.files.append(Rollout(source: source, url: url))
                    } else if url.pathExtension == "zst" {
                        compressed += 1
                    }
                }
            }
            if !foundFolder { discovered.notices.append("\(source.name): no local Codex session history was found.") }
            if unreadable { discovered.notices.append("\(source.name): some Codex session folders could not be read.") }
            if compressed > 0 { discovered.notices.append("\(source.name): compressed Codex session archives were left unread.") }
        }
        discovered.files.sort { $0.url.path < $1.url.path }
        return discovered
    }

    /// `parsed == nil` reads only session headers and does not report edits.
    private func fold(files discovered: Discovered, parsed: [String: CodexFile]?, notices extra: [String]) -> ScanResult {
        var sessions: [String: HistorySession] = [:]
        var order: [String] = []
        var missingProject = 0
        for task in discovered.files {
            let file: CodexFile
            if let parsed {
                guard let ready = parsed[task.url.path] else { continue }
                file = ready
            } else if let header = readHeader(task.url) {
                file = header
            } else {
                missingProject += 1
                continue
            }
            guard let project = file.projectPath, let sessionID = file.sessionID, let created = file.createdAt else {
                missingProject += 1
                continue
            }
            let key = task.source.id + "\u{0}" + sessionID
            let latest = file.latestActivity ?? created
            guard var session = sessions[key] else {
                order.append(key)
                sessions[key] = HistorySession(sourceID: task.source.id, sessionID: sessionID, recordedWorkspace: project,
                    roots: file.roots.isEmpty ? [project] : file.roots, createdAt: created, latestActivity: latest,
                    edits: parsed == nil ? [:] : file.edits, parentSessionID: file.parentSessionID)
                continue
            }
            guard session.recordedWorkspace == project else {
                // Contradictory copies cannot prove where the session worked.
                session.canMove = false
                sessions[key] = session
                continue
            }
            // Combine every copy's evidence before attributing the session.
            var merged = HistorySession(sourceID: session.sourceID, sessionID: sessionID, recordedWorkspace: project,
                roots: Array(Set(session.roots + file.roots)).sorted(), createdAt: min(session.createdAt, created),
                latestActivity: max(session.latestActivity, latest), edits: session.edits,
                parentSessionID: session.parentSessionID ?? file.parentSessionID, canMove: session.canMove)
            if parsed != nil {
                for (id, edit) in file.edits { merged.edits[id] = merged.edits[id]?.earlier(than: edit) ?? edit }
            }
            sessions[key] = merged
        }
        var notices = discovered.notices + extra
        if missingProject > 0 {
            notices.append("Codex: \(missingProject) session history file(s) had no project path and were omitted.")
        }
        let folded = HistoryFold.fold(order.compactMap { sessions[$0] }, resolver: resolver)
        return ScanResult(projects: ProjectSummary.merge(folded.activity), notices: Array(Set(notices)).sorted(),
                          sessionProjects: folded.associations, missingFolders: folded.missingFolders)
    }

    private func readHeader(_ url: URL) -> CodexFile? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let file = CodexFile()
        var buffer = Data()
        var lines = 0
        while lines < 32, buffer.count < 1_048_576 {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            buffer.append(chunk)
            while let found = buffer.range(of: Data([0x0A]))?.lowerBound {
                let line = buffer[..<found]
                buffer.removeSubrange(..<buffer.index(after: found))
                lines += 1
                if !line.isEmpty {
                    _ = parse(Data(line), file: file, fallbackID: url.deletingPathExtension().lastPathComponent)
                }
                if file.sessionID != nil { return file.projectPath == nil ? nil : file }
            }
        }
        return file.projectPath == nil ? nil : file
    }

    @discardableResult
    private func parse(_ line: Data, file: CodexFile, fallbackID: String) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return false }
        if let stamp = (object["timestamp"] as? String).flatMap(RecordedDate.parse) {
            if file.latestActivity == nil || stamp > file.latestActivity! { file.latestActivity = stamp }
        }
        guard let type = object["type"] as? String, let payload = object["payload"] as? [String: Any] else { return true }
        switch type {
        case "session_meta":
            guard file.sessionID == nil, let cwd = payload["cwd"] as? String,
                  let project = ProjectLocationRegistry.lexicalPath(cwd) else { return true }
            let identifier = payload["id"] as? String
            file.sessionID = (identifier?.isEmpty == false ? identifier : nil) ?? fallbackID
            file.projectPath = project
            if let parent = payload["parent_thread_id"] as? String, !parent.isEmpty, parent != file.sessionID {
                file.parentSessionID = parent
            }
            file.createdAt = (payload["timestamp"] as? String).flatMap(RecordedDate.parse) ?? file.latestActivity
            var roots = [project]
            if let extra = payload["runtime_workspace_roots"] as? [String] {
                roots.append(contentsOf: extra.compactMap(ProjectLocationRegistry.lexicalPath))
            }
            file.roots = Array(Set(roots)).sorted { $0.count > $1.count }
            if file.turnCwd == nil { file.turnCwd = project }
        case "turn_context":
            if let raw = payload["cwd"] as? String, let cwd = ProjectLocationRegistry.lexicalPath(raw) { file.turnCwd = cwd }
        case "event_msg":
            recordFileChange(object: object, payload: payload, file: file)
        default:
            break
        }
        return true
    }

    private func recordFileChange(object: [String: Any], payload: [String: Any], file: CodexFile) {
        guard payload["type"] as? String == "item_completed",
              let item = payload["item"] as? [String: Any],
              item["type"] as? String == "FileChange",
              item["status"] as? String == "completed",
              let id = item["id"] as? String, !id.isEmpty,
              let changes = item["changes"] as? [String: Any], !changes.isEmpty,
              let project = file.projectPath else { return }
        // Record evidence only. Whether the working directory was declared and
        // where each target physically is are decided when folding.
        let eventCwd = file.turnCwd ?? project
        var paths = changes.keys.compactMap { lexicalTarget($0, base: eventCwd) }
        guard paths.count == changes.count else { return }
        for change in changes.values {
            guard let update = change as? [String: Any], update["type"] as? String == "update",
                  let destination = update["move_path"], !(destination is NSNull) else { continue }
            guard let destination = destination as? String,
                  let path = lexicalTarget(destination, base: eventCwd) else { return }
            paths.append(path)
        }
        guard let date = RecordedDate.milliseconds(payload["completed_at_ms"])
            ?? (object["timestamp"] as? String).flatMap(RecordedDate.parse) else { return }
        let directories = Array(Set(paths.map { ($0 as NSString).deletingLastPathComponent })).sorted()
        let edit = StoredEdit(date: date, workspace: eventCwd, targetDirectories: directories)
        file.edits[id] = file.edits[id]?.earlier(than: edit) ?? edit
    }

    private func lexicalTarget(_ path: String, base: String) -> String? {
        guard !path.isEmpty, !path.contains("\0"), !path.hasPrefix("-") else { return nil }
        if path.hasPrefix("/") || path.hasPrefix("~/") { return ProjectLocationRegistry.lexicalPath(path) }
        return ProjectLocationRegistry.lexicalPath((base as NSString).appendingPathComponent(path))
    }
}

private final class CodexFile: Codable {
    var tail = TailState()
    var sessionID: String?
    var projectPath: String?
    var createdAt: Date?
    var latestActivity: Date?
    var turnCwd: String?
    var roots: [String] = []
    var edits: [String: StoredEdit] = [:]
    var parentSessionID: String?

    init() {}

    func resetDerived() {
        sessionID = nil
        parentSessionID = nil
        projectPath = nil
        createdAt = nil
        latestActivity = nil
        turnCwd = nil
        roots = []
        edits = [:]
    }
}

private struct SavedCache: Codable {
    var version: Int
    var files: [String: CodexFile]
}

private struct CacheHeader: Decodable { let version: Int }
