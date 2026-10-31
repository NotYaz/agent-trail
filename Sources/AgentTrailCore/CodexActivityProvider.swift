import Foundation

/// Read-only adapter for Codex rollout transcripts under `$CODEX_HOME`
/// (`~/.codex` unless the profile sets another home). A completed `FileChange`
/// item is one confirmed edit. Shell commands, `apply_patch` calls without a
/// completed FileChange, and file modification times are not evidence.
public final class CodexActivityProvider: ActivityProvider {
    private let cacheURL: URL?
    private var cache: [String: CodexFile] = [:]
    private var cacheLoadNotice: String?
    private let files = FileManager.default

    public init(cacheURL: URL? = nil) {
        self.cacheURL = cacheURL
        guard let cacheURL, files.fileExists(atPath: cacheURL.path) else { return }
        do {
            let data = try Data(contentsOf: cacheURL)
            let header = try JSONDecoder().decode(CacheHeader.self, from: data)
            if header.version == 2 {
                cache = try JSONDecoder().decode(SavedCache.self, from: data).files
            } else {
                cacheLoadNotice = "Codex edit history is being rebuilt once for the current indexer."
            }
        } catch {
            cacheLoadNotice = "The Codex activity cache could not be read; change history will be rebuilt."
        }
    }

    public func metadata(sources: [AgentSource]) -> ScanResult {
        fold(files: discover(sources: sources), parsed: nil, notices: [])
    }

    public func scan(sources: [AgentSource]) -> ScanResult {
        scan(sources: sources, progress: nil)
    }

    public func scan(sources: [AgentSource], progress: ((ScanResult, Int, Int) -> Void)?) -> ScanResult {
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
                let data = try JSONEncoder().encode(SavedCache(version: 2, files: cache))
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
        var sessions: [String: SessionFold] = [:]
        var edits: [String: EditFold] = [:]
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
            if var existing = sessions[key] {
                if existing.projectPath == project {
                    if created < existing.createdAt { existing.createdAt = created }
                    if latest > existing.latestActivity { existing.latestActivity = latest }
                    sessions[key] = existing
                }
            } else {
                sessions[key] = SessionFold(sourceID: task.source.id, sessionID: sessionID, projectPath: project,
                    createdAt: created, latestActivity: latest, workspace: project)
            }
            guard parsed != nil, sessions[key]?.projectPath == project else { continue }
            let editKeyPrefix = task.source.id + "\u{0}" + project + "\u{0}"
            for (id, edit) in file.edits {
                let key = editKeyPrefix + id
                if let existing = edits[key] {
                    edits[key] = EditFold(sourceID: task.source.id, projectPath: project, id: id, edit: existing.edit.earlier(than: edit))
                } else {
                    edits[key] = EditFold(sourceID: task.source.id, projectPath: project, id: id, edit: edit)
                }
            }
        }
        var notices = discovered.notices + extra
        if missingProject > 0 {
            notices.append("Codex: \(missingProject) session history file(s) had no project path and were omitted.")
        }
        var activity: [ProjectActivity] = sessions.values.map { session in
            ProjectActivity(sourceID: session.sourceID, projectPath: session.projectPath,
                latestActivity: session.latestActivity, sessionCount: 1, workspacePath: session.workspace,
                history: [ActivityDay(day: session.createdAt, sessionCount: 1)])
        }
        let grouped = Dictionary(grouping: edits.values, by: { $0.sourceID + "\u{0}" + $0.projectPath })
        for records in grouped.values {
            guard let latest = records.max(by: { $0.edit.date < $1.edit.date }) else { continue }
            let days = Dictionary(grouping: records, by: { ActivityDay.start(of: $0.edit.date) })
                .map { ActivityDay(day: $0.key, editCount: $0.value.count) }
            activity.append(ProjectActivity(sourceID: latest.sourceID, projectPath: latest.projectPath,
                latestActivity: latest.edit.date, latestEdit: latest.edit.date, sessionCount: 0,
                workspacePath: latest.edit.workspace, latestEditWorkspacePath: latest.edit.workspace, history: days))
        }
        return ScanResult(projects: ProjectSummary.merge(activity), notices: Array(Set(notices)).sorted())
    }

    private struct SessionFold {
        var sourceID: String
        var sessionID: String
        var projectPath: String
        var createdAt: Date
        var latestActivity: Date
        var workspace: String
    }

    private struct EditFold {
        var sourceID: String
        var projectPath: String
        var id: String
        var edit: StoredEdit
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
            guard file.sessionID == nil, let project = CheckoutPath.absolute(payload["cwd"] as? String) else { return true }
            let identifier = payload["id"] as? String
            file.sessionID = (identifier?.isEmpty == false ? identifier : nil) ?? fallbackID
            file.projectPath = project
            file.createdAt = (payload["timestamp"] as? String).flatMap(RecordedDate.parse) ?? file.latestActivity
            var roots = [project]
            if let extra = payload["runtime_workspace_roots"] as? [String] {
                roots.append(contentsOf: extra.compactMap(CheckoutPath.absolute))
            }
            file.roots = Array(Set(roots)).sorted { $0.count > $1.count }
            if file.turnCwd == nil { file.turnCwd = project }
        case "turn_context":
            if let cwd = CheckoutPath.absolute(payload["cwd"] as? String) { file.turnCwd = cwd }
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
        let roots = file.roots.isEmpty ? [project] : file.roots
        let eventCwd = file.turnCwd ?? project
        guard roots.contains(where: { CheckoutPath.contains(root: $0, path: eventCwd) }) else { return }
        var paths = changes.keys.compactMap { CheckoutPath.resolve($0, base: eventCwd) }
        guard paths.count == changes.count else { return }
        for change in changes.values {
            guard let update = change as? [String: Any], update["type"] as? String == "update",
                  let destination = update["move_path"], !(destination is NSNull) else { continue }
            guard let destination = destination as? String,
                  let path = CheckoutPath.resolve(destination, base: eventCwd) else { return }
            paths.append(path)
        }
        guard paths.allSatisfy({ CheckoutPath.contains(root: eventCwd, path: $0) }) else { return }
        let workspaces = Set(paths.map { path in
            roots.first(where: {
                CheckoutPath.contains(root: eventCwd, path: $0) && CheckoutPath.contains(root: $0, path: path)
            }) ?? eventCwd
        })
        guard workspaces.count == 1, let workspace = workspaces.first else { return }
        guard let date = RecordedDate.milliseconds(payload["completed_at_ms"])
            ?? (object["timestamp"] as? String).flatMap(RecordedDate.parse) else { return }
        let edit = StoredEdit(date: date, workspace: workspace)
        file.edits[id] = file.edits[id]?.earlier(than: edit) ?? edit
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

    init() {}

    func resetDerived() {
        sessionID = nil
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
