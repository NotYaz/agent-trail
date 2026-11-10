import Foundation

/// Read-only adapter for Qwen Code (the `qwen` CLI, and the VS Code
/// companion, Zed and Qwen Code Desktop, which run the same core). Sessions
/// live under the runtime folder: the profile's `userDataDirectory` when set
/// (`QWEN_RUNTIME_DIR` or `advanced.runtimeOutputDir`), else its home
/// (`~/.qwen`, or `$QWEN_HOME`). Each is `projects/<folder>/chats/<id>.jsonl`
/// (archived ones in `chats/archive/`), an append-only log of records that
/// each carry the folder Qwen was working in (`cwd`). The folder name is
/// never decoded.
///
/// One confirmed edit is a `tool_result` record of an `edit` (formerly
/// `replace`), `write_file` or `notebook_edit` call whose tool ran
/// successfully, called directly or through the `tool_call` bridge (which
/// reaches deferred tools). How the tool ran is `toolCallResult.
/// executionStatus`; records without it give only `status`. The two differ
/// when a PostToolUse hook stops a call after its change was applied (status
/// `error`, execution `success`: counts) and for a call the headless loop
/// skipped without running (status `success`, execution `not_started`: never
/// counts). Its file is the result's `resultDisplay.filePath`, else the
/// call's own absolute path argument; its time is the record's. Records
/// `/branch` and `--fork-session` copied from another session (`forkedFrom`)
/// are skipped, so an edit counts for the session that made it.
///
/// A subagent's transcript, `projects/<folder>/subagents/<session id>/
/// agent-<id>.jsonl`, records no status. From Qwen Code 0.27 it writes each
/// tool's ended `tool_lifecycle` record, with its `executionStatus`, before
/// the result; without one, an edit counts when Qwen answered the call with
/// `output` and no `error`, which is how it reports every successful call
/// (failed and cancelled ones carry `error`). Those edits join the parent
/// session as delegated. A subagent run by an external executor (another ACP
/// agent) answers every call with `{input, toolName, output, content,
/// status}`, failed ones included; those never count, and that agent's own
/// history records its edits.
///
/// Not read: the experimental Managed engine's sessions (their messages sit
/// in separate resource files), `qwen serve --managed` (its own store), and
/// the inner calls of a code-mode `exec` script in a terminal session, which
/// Qwen does not record.
///
/// Shell commands, failed or cancelled calls and file modification times are
/// never evidence, and nothing in a session's working folder is read: paths
/// stay the strings Qwen recorded. The cache keeps ids, statuses, times and
/// folder paths only: no prompts, code, diffs or file content.
public final class QwenActivityProvider: ActivityProvider {
    static let cacheVersion = 3
    private let cache: HistoryCache<QwenFile>
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
        cache = HistoryCache(url: cacheURL, version: Self.cacheVersion, name: "Qwen Code")
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
        var parsed: [String: QwenFile] = [:]
        let tasks = discovered.tasks
        var lastProgress = Date.distantPast
        for (index, task) in tasks.enumerated() {
            let cached = cache[task.url.path]
            let file = cached ?? QwenFile()
            let before = file.tail
            let sidechain = task.parentFolder != nil
            do {
                try JSONLTail.read(url: task.url, state: &file.tail, reset: { file.log = QwenLog() }) { line in
                    guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return false }
                    file.log.apply(object, sidechainFile: sidechain)
                    return true
                }
                // Parsed evidence changes only with the tail.
                cache.store(file, at: task.url.path, changed: cached == nil || file.tail != before)
                parsed[task.url.path] = file
                if file.tail.malformedLines > 0 {
                    notices.append("\(task.source.name): skipped unreadable records in a Qwen Code session history.")
                }
                if file.tail.oversizedLines > 0 {
                    notices.append("\(task.source.name): a Qwen Code session history record was too large to index safely.")
                }
            } catch {
                notices.append("\(task.source.name): could not read a Qwen Code session's history.")
            }
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

    // MARK: Discovery

    private struct ScanTask {
        let source: AgentSource
        let url: URL
        /// The session id: the chat file's name, or the subagent's own id.
        let id: String
        /// For a subagent transcript, the folder it sits in: its parent session's id.
        let parentFolder: String?
    }

    private struct Discovered {
        var tasks: [ScanTask] = []
        var notices: [String] = []
    }

    /// The folder holding `projects/`: the runtime folder when the profile
    /// names one, else the home.
    static func runtimeFolder(_ source: AgentSource) -> URL {
        let folder = source.userDataDirectory ?? source.configDirectory
        return URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
    }

    private func discover(sources: [AgentSource]) -> Discovered {
        var discovered = Discovered()
        for source in sources where source.assistant == .qwen {
            let projects = Self.runtimeFolder(source).appendingPathComponent("projects", isDirectory: true)
            guard let folders = try? files.contentsOfDirectory(atPath: projects.path) else {
                discovered.notices.append("\(source.name): no local Qwen Code history was found.")
                continue
            }
            for name in folders.sorted() where !name.hasPrefix(".") {
                let folder = projects.appendingPathComponent(name, isDirectory: true)
                let chats = folder.appendingPathComponent("chats", isDirectory: true)
                for directory in [chats, chats.appendingPathComponent("archive", isDirectory: true)] {
                    guard let names = try? files.contentsOfDirectory(atPath: directory.path) else { continue }
                    // `<id>.jsonl` only: not `<id>.runtime.json` or other sidecars.
                    for entry in names.sorted() where entry.hasSuffix(".jsonl") {
                        let id = String(entry.dropLast(6))
                        guard Self.isSafeID(id) else { continue }
                        discovered.tasks.append(ScanTask(source: source, url: directory.appendingPathComponent(entry),
                                                         id: id, parentFolder: nil))
                    }
                }
                let subagents = folder.appendingPathComponent("subagents", isDirectory: true)
                guard let parents = try? files.contentsOfDirectory(atPath: subagents.path) else { continue }
                for parent in parents.sorted() where Self.isSafeID(parent) {
                    let directory = subagents.appendingPathComponent(parent, isDirectory: true)
                    guard let names = try? files.contentsOfDirectory(atPath: directory.path) else { continue }
                    // `agent-<id>.jsonl`; never the `.meta.json` sidecar or the live `.jsonl.stream`.
                    for entry in names.sorted() where entry.hasPrefix("agent-") && entry.hasSuffix(".jsonl") {
                        let id = String(entry.dropLast(6))
                        guard Self.isSafeID(id) else { continue }
                        discovered.tasks.append(ScanTask(source: source, url: directory.appendingPathComponent(entry),
                                                         id: id, parentFolder: parent))
                    }
                }
            }
        }
        return discovered
    }

    /// Letters, digits, `-` and `_`: what Qwen keeps of an id in a file name.
    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// A JSON boolean. `as? Bool` also accepts the numbers 0 and 1.
    static func flag(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    // MARK: Folding

    private struct Part {
        let source: AgentSource
        let log: QwenLog
        let delegated: Bool
    }

    private struct Subagent {
        let part: Part
        let parent: String
        let id: String
    }

    private func result(_ discovered: Discovered, parsed: [String: QwenFile], notices: [String]) -> ScanResult {
        var mains: [String: [Part]] = [:]
        var order: [(key: String, id: String)] = []
        var subagents: [Subagent] = []
        for task in discovered.tasks {
            guard let log = parsed[task.url.path]?.log else { continue }
            if let parent = task.parentFolder {
                subagents.append(Subagent(part: Part(source: task.source, log: log, delegated: true), parent: parent, id: task.id))
                continue
            }
            // An archived copy and an active one are the same session.
            let key = task.source.id + "\u{0}" + task.id
            if mains[key] == nil { order.append((key: key, id: task.id)) }
            mains[key, default: []].append(Part(source: task.source, log: log, delegated: false))
        }
        var orphans: [Subagent] = []
        for subagent in subagents {
            let key = subagent.part.source.id + "\u{0}" + subagent.parent
            if mains[key] != nil {
                mains[key, default: []].append(subagent.part)
            } else {
                orphans.append(subagent)
            }
        }
        var sessions: [HistorySession] = []
        for entry in order {
            if let parts = mains[entry.key], let session = Self.session(id: entry.id, parts: parts, spawnedBy: nil) {
                sessions.append(session)
            }
        }
        // A subagent whose session is gone stands alone, every edit delegated.
        for orphan in orphans {
            if let session = Self.session(id: orphan.id, parts: [orphan.part], spawnedBy: orphan.parent) {
                sessions.append(session)
            }
        }
        let folded = HistoryFold.fold(sessions, resolver: resolver)
        return ScanResult(projects: ProjectSummary.merge(folded.activity), notices: Array(Set(notices)).sorted(),
            sessionProjects: folded.associations, missingFolders: folded.missingFolders,
            sessionTrails: SessionTrail.merge(folded.trails))
    }

    /// One session from its files. A file with no prompt or reply of its own
    /// (a CLI that was opened and closed, a branch nobody continued) is not a
    /// session.
    private static func session(id: String, parts: [Part], spawnedBy: String?) -> HistorySession? {
        let mains = parts.filter { !$0.delegated }
        let anchors = mains.isEmpty ? parts : mains
        guard anchors.contains(where: \.log.hasTurn) else { return nil }
        var first: (date: Date, workspace: String)?
        for part in anchors {
            guard let date = part.log.created, let workspace = part.log.firstCwd else { continue }
            if first == nil || date < (first?.date ?? date) { first = (date: date, workspace: workspace) }
        }
        guard let first, let source = parts.first?.source else { return nil }
        let created = first.date
        let latest = parts.compactMap(\.log.latest).max() ?? created
        var edits: [String: StoredEdit] = [:]
        var delegated: Set<String> = []
        for part in parts {
            for (key, edit) in part.log.edits {
                edits[key] = edits[key]?.earlier(than: edit) ?? edit
                if part.delegated || spawnedBy != nil || part.log.delegated.contains(key) { delegated.insert(key) }
            }
        }
        let roots = Array(Set(parts.flatMap(\.log.roots) + [first.workspace])).sorted()
        var session = HistorySession(sourceID: source.id, sessionID: id, recordedWorkspace: first.workspace, roots: roots,
            createdAt: created, latestActivity: max(created, latest), edits: edits)
        session.parentSessionID = spawnedBy ?? mains.compactMap(\.log.parentSessionID).first
        session.delegatedEdits = delegated.intersection(edits.keys)
        return session
    }
}

// MARK: - Cached evidence

final class QwenFile: Codable {
    var tail = TailState()
    var log = QwenLog()

    init() {}
}

/// An edit tool call awaiting its result: its name, and the folder of its
/// absolute path argument.
struct QwenCall: Codable, Equatable {
    var name: String
    var directory: String?
}

/// What one Qwen Code session file proves, record by record.
struct QwenLog: Codable, Equatable {
    /// The first and last record times, copied records excluded.
    var created: Date?
    var latest: Date?
    /// The first record's working folder, and every one the session used.
    var firstCwd: String?
    var roots: [String] = []
    /// True once a user, assistant or tool result record was written here.
    var hasTurn = false
    /// `system/parent_session`: the session that created this one.
    var parentSessionID: String?
    /// Edit tool calls by id until their result arrives.
    var pending: [String: QwenCall] = [:]
    /// Confirmed edits by call id and time.
    var edits: [String: StoredEdit] = [:]
    /// Edits recorded by a subagent (`isSidechain`).
    var delegated: Set<String> = []
    /// A subagent's ended `tool_lifecycle` records: `executionStatus` by
    /// call id, until the call's result arrives.
    var ran: [String: String] = [:]

    /// `edit` (and its old name `replace`), `write_file`, `notebook_edit`.
    static let editTools: Set<String> = ["edit", "replace", "write_file", "notebook_edit"]

    mutating func apply(_ object: [String: Any], sidechainFile: Bool) {
        guard let type = object["type"] as? String else { return }
        // Copied from another session by /branch or --fork-session.
        if let fork = object["forkedFrom"], !(fork is NSNull) { return }
        let date = (object["timestamp"] as? String).flatMap(RecordedDate.parse)
        if let date {
            created = min(created ?? date, date)
            latest = max(latest ?? date, date)
        }
        var cwd: String?
        if let raw = object["cwd"] as? String, raw.hasPrefix("/"), let path = ProjectLocationRegistry.lexicalPath(raw) {
            cwd = path
            if firstCwd == nil { firstCwd = path }
            if !roots.contains(path), roots.count < 256 { roots.append(path) }
        }
        let sidechain = sidechainFile || QwenActivityProvider.flag(object["isSidechain"]) == true
        if type == "user" || type == "assistant" || type == "tool_result" { hasTurn = true }
        switch type {
        case "assistant":
            calls(object["message"])
        case "tool_result":
            if let date { result(object, date: date, cwd: cwd ?? firstCwd, sidechain: sidechain) }
        case "system":
            let payload = object["systemPayload"] as? [String: Any]
            switch object["subtype"] as? String {
            case "parent_session":
                if let parent = payload?["parentSessionId"] as? String, QwenActivityProvider.isSafeID(parent) {
                    parentSessionID = parent
                }
            case "ui_telemetry" where sidechain:
                // A subagent writes each tool's end, with how it ran, before the tool's result.
                guard let event = payload?["uiEvent"] as? [String: Any], event["event.name"] as? String == "tool_lifecycle",
                      event["phase"] as? String == "ended", let id = event["callId"] as? String, !id.isEmpty,
                      id.utf8.count <= 512, let status = event["executionStatus"] as? String, status.utf8.count <= 32 else { break }
                if ran.count >= 4_096 { ran.removeAll() }
                ran[id] = status
            default:
                break
            }
        default:
            break
        }
    }

    private mutating func calls(_ message: Any?) {
        guard let parts = (message as? [String: Any])?["parts"] as? [Any] else { return }
        for case let part as [String: Any] in parts {
            guard let call = part["functionCall"] as? [String: Any], let id = call["id"] as? String, !id.isEmpty,
                  id.utf8.count <= 512, let called = call["name"] as? String else { continue }
            var name = called
            var arguments = call["args"] as? [String: Any] ?? [:]
            if name == "tool_call" {
                // The bridge to a deferred tool (built-in edit tools are
                // deferred when `tools.eager` leaves them out): `{name,
                // arguments}`, the name matched without regard to case.
                guard let target = arguments["name"] as? String else { continue }
                name = target.lowercased()
                arguments = arguments["arguments"] as? [String: Any] ?? [:]
            }
            guard Self.editTools.contains(name) else { continue }
            let raw = (arguments["file_path"] as? String) ?? (arguments["notebook_path"] as? String)
            let path = raw.flatMap { $0.hasPrefix("/") ? ProjectLocationRegistry.lexicalPath($0) : nil }
            // Calls that never got a result (a crash) are dropped in bulk.
            if pending.count >= 4_096 { pending.removeAll() }
            pending[id] = QwenCall(name: name, directory: path.map { ($0 as NSString).deletingLastPathComponent })
        }
    }

    private mutating func result(_ object: [String: Any], date: Date, cwd: String?, sidechain: Bool) {
        let info = object["toolCallResult"] as? [String: Any] ?? [:]
        let callID = info["callId"] as? String
        var responseID: String?
        var responseName: String?
        var response: [String: Any]?
        let parts = (object["message"] as? [String: Any])?["parts"] as? [Any] ?? []
        for case let part as [String: Any] in parts {
            guard let function = part["functionResponse"] as? [String: Any] else { continue }
            let id = function["id"] as? String
            if callID != nil, id != callID { continue }
            responseID = id
            responseName = function["name"] as? String
            response = function["response"] as? [String: Any]
            break
        }
        guard let id = callID ?? responseID, !id.isEmpty, id.utf8.count <= 512 else { return }
        let call = pending.removeValue(forKey: id)
        let lifecycle = ran.removeValue(forKey: id)
        // A bridged call is answered as `tool_call`; its call names the tool it ran.
        let resolved = responseName == "tool_call" ? call?.name : (responseName ?? call?.name)
        guard let name = resolved, Self.editTools.contains(name) else { return }
        if let execution = info["executionStatus"] as? String {
            // How the tool itself ran. `success` means the change was
            // applied, also when a PostToolUse hook then stopped the call
            // (recorded with status `error`). `not_started` is a call skipped
            // without running (a sibling of `structured_output` in a headless
            // turn), recorded with status `success`.
            guard execution == "success" else { return }
        } else if let status = info["status"] as? String {
            guard status == "success" else { return }
        } else {
            // Subagent transcripts record no status, only the tool's ended
            // lifecycle (from Qwen Code 0.27) and its answer. An external
            // executor's `{input, toolName, output, content, status}` answer
            // looks the same whatever the outcome, so it is never evidence.
            guard sidechain, let answer = response, answer["status"] == nil, answer["toolName"] == nil,
                  answer["input"] == nil else { return }
            if let lifecycle {
                guard lifecycle == "success" else { return }
            } else {
                // Qwen answers every successful call with `output`, every
                // failed or cancelled one with `error`.
                guard answer["output"] is String, answer["error"] == nil else { return }
            }
        }
        let display = info["resultDisplay"] as? [String: Any]
        let recorded = (display?["filePath"] as? String).flatMap { $0.hasPrefix("/") ? ProjectLocationRegistry.lexicalPath($0) : nil }
        guard let directory = recorded.map({ ($0 as NSString).deletingLastPathComponent }) ?? call?.directory,
              let cwd else { return }
        let edit = StoredEdit(date: date, workspace: cwd, targetDirectories: [directory])
        let key = id + "\u{0}" + String(date.timeIntervalSince1970)
        edits[key] = edits[key]?.earlier(than: edit) ?? edit
        if sidechain { delegated.insert(key) }
    }
}
