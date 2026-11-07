import Foundation

/// Read-only adapter for GitHub Copilot. One profile reads two stores.
///
/// Copilot Chat in VS Code, under the profile's VS Code user-data folder
/// (`~/Library/Application Support/Code` unless the profile names another).
/// Each `User/workspaceStorage/<hash>/` holds `workspace.json`, the folder or
/// `.code-workspace` file that window opened; `chatSessions/<id>.jsonl`, an
/// append-only mutation log of one chat since VS Code 1.109 (`<id>.json`, a
/// whole snapshot, before it); and `chatEditingSessions/<id>/state.json`, the
/// edits VS Code applied for that chat. An edit tool call counts once VS Code
/// recorded an operation on its file in the same request, before the
/// timeline's current epoch (so a restored checkpoint undoes it), and the
/// user did not reject or undo it. The edit's time is the tool call's
/// completion when VS Code records it, else the request's. Remote windows and
/// windows without a folder are skipped: their files are not on this Mac.
///
/// The Copilot CLI, under the profile's home (`~/.copilot`):
/// `session-state/<id>/events.jsonl`, which the Copilot app and VS Code's
/// Copilot CLI sessions also write. A successful edit tool completion is one
/// edit; its `fileEdits` name the files it committed, else the tool's `path`
/// argument does. Replayed `checkpoint` records are skipped.
///
/// Shell commands and file modification times are never evidence. The cache
/// keeps ids, times and file paths only: no prompts, code or file content.
public final class CopilotActivityProvider: ActivityProvider {
    static let cacheVersion = 1
    private let cache: HistoryCache<CopilotFile>
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
        cache = HistoryCache(url: cacheURL, version: Self.cacheVersion, name: "Copilot")
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
        var parsed: [String: CopilotFile] = [:]
        let tasks = discovered.tasks
        var lastProgress = Date.distantPast
        for (index, task) in tasks.enumerated() {
            let cached = cache[task.url.path]
            let file = cached ?? CopilotFile()
            let before = (file.tail, file.stamp)
            do {
                switch task.kind {
                case .chatLog:
                    try JSONLTail.read(url: task.url, state: &file.tail, reset: { file.chat = ChatLog() }) { line in
                        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return false }
                        if file.chat == nil { file.chat = ChatLog() }
                        return file.chat!.apply(object)
                    }
                case .chatSnapshot:
                    try readWhole(task.url, file: file) { object in
                        var chat = ChatLog()
                        chat.reset(from: object)
                        file.chat = chat
                    }
                case .editingState:
                    try readWhole(task.url, file: file) { object in
                        file.editing = EditingState(object)
                    }
                case .cliEvents:
                    try JSONLTail.read(url: task.url, state: &file.tail, reset: { file.cli = CLILog() }) { line in
                        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return false }
                        if file.cli == nil { file.cli = CLILog() }
                        return file.cli!.apply(object)
                    }
                }
                // Parsed evidence changes only with the tail or stamp.
                cache.store(file, at: task.url.path, changed: cached == nil || file.tail != before.0 || file.stamp != before.1)
                parsed[task.url.path] = file
                if file.tail.malformedLines > 0 {
                    notices.append("\(task.source.name): skipped unreadable records in a Copilot session history.")
                }
                if file.tail.oversizedLines > 0 {
                    notices.append("\(task.source.name): a Copilot session history record was too large to index safely.")
                }
            } catch {
                notices.append("\(task.source.name): could not read a Copilot session's change history.")
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

    /// Whole-file JSON stores are reparsed only when their identity, size or
    /// modification time changes.
    private func readWhole(_ url: URL, file: CopilotFile, parse: ([String: Any]) -> Void) throws {
        let stat = try FileStat.required(url)
        let stamp = FileStamp(stat)
        guard stamp != file.stamp else { return }
        guard stat.size <= UInt64(JSONLTail.maximumLineBytes) else {
            file.stamp = stamp
            file.tail.oversizedLines = 1
            return
        }
        let data = try Data(contentsOf: url)
        file.stamp = stamp
        file.tail.oversizedLines = 0
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // Possibly mid-write; the next scan rereads it.
            file.stamp = nil
            return
        }
        parse(object)
    }

    // MARK: Discovery

    private enum TaskKind { case chatLog, chatSnapshot, editingState, cliEvents }

    private struct ScanTask {
        let source: AgentSource
        let url: URL
        let kind: TaskKind
    }

    private struct ChatSession {
        let source: AgentSource
        let id: String
        let log: URL
        let editing: URL?
        let roots: [String]
    }

    private struct CLISession {
        let source: AgentSource
        let id: String
        let events: [URL]
        /// workspace.yaml `cwd`, for files whose events name no folder.
        let recordedCwd: String?
    }

    private struct Discovered {
        var chats: [ChatSession] = []
        var cli: [CLISession] = []
        var tasks: [ScanTask] = []
        var notices: [String] = []
    }

    private func discover(sources: [AgentSource]) -> Discovered {
        var discovered = Discovered()
        for source in sources where source.assistant == .copilot {
            var found = false
            if let userData = Self.vsCodeFolder(source) {
                found = discoverChats(source, userData: userData, into: &discovered) || found
            }
            found = discoverCLI(source, into: &discovered) || found
            if !found {
                discovered.notices.append("\(source.name): no local Copilot Chat or Copilot CLI history was found.")
            }
        }
        return discovered
    }

    /// The profile's VS Code user-data folder: the one it names, or VS Code's
    /// default for a profile with the default Copilot home.
    static func vsCodeFolder(_ source: AgentSource) -> URL? {
        let descriptor = AssistantKind.copilot.descriptor
        let usesDefaultHome = canonicalPath(source.configDirectory) == canonicalPath(descriptor.defaultHome(home: "~"))
        guard let folder = source.userDataDirectory ?? (usesDefaultHome ? descriptor.defaultUserDataDirectory : nil) else {
            return nil
        }
        return URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Returns true when the folder holds Copilot Chat storage.
    private func discoverChats(_ source: AgentSource, userData: URL, into discovered: inout Discovered) -> Bool {
        let storage = userData.appendingPathComponent("User/workspaceStorage", isDirectory: true)
        guard let workspaces = try? files.contentsOfDirectory(at: storage, includingPropertiesForKeys: nil,
                                                              options: [.skipsHiddenFiles]) else { return false }
        var unreadableWorkspaces = 0
        for workspace in workspaces.sorted(by: { $0.path < $1.path }) {
            let chats = workspace.appendingPathComponent("chatSessions", isDirectory: true)
            guard let names = try? files.contentsOfDirectory(atPath: chats.path), !names.isEmpty else { continue }
            guard let roots = VSCodeWorkspace.roots(of: workspace.appendingPathComponent("workspace.json")) else {
                unreadableWorkspaces += 1
                continue
            }
            // Remote and folderless windows: their edits are not on this Mac.
            guard !roots.isEmpty else { continue }
            var byID: [String: (url: URL, legacy: Bool)] = [:]
            for name in names {
                let url = chats.appendingPathComponent(name)
                if name.hasSuffix(".jsonl") {
                    byID[String(name.dropLast(6))] = (url, false)
                } else if name.hasSuffix(".json") {
                    let id = String(name.dropLast(5))
                    // VS Code reads the log first, so a leftover snapshot never wins.
                    if byID[id] == nil { byID[id] = (url, true) }
                }
            }
            for (id, log) in byID.sorted(by: { $0.key < $1.key }) where Self.isSafeID(id) {
                let state = workspace.appendingPathComponent("chatEditingSessions/\(id)/state.json")
                let editing = FileStat.of(state.path)?.kind == .regular ? state : nil
                discovered.chats.append(ChatSession(source: source, id: id, log: log.url, editing: editing, roots: roots))
                discovered.tasks.append(ScanTask(source: source, url: log.url, kind: log.legacy ? .chatSnapshot : .chatLog))
                if let editing { discovered.tasks.append(ScanTask(source: source, url: editing, kind: .editingState)) }
            }
        }
        if unreadableWorkspaces > 0 {
            discovered.notices.append("\(source.name): \(unreadableWorkspaces) VS Code workspace record(s) could not be read; their Copilot chats were skipped.")
        }
        return true
    }

    /// Returns true when the home holds Copilot CLI sessions.
    private func discoverCLI(_ source: AgentSource, into discovered: inout Discovered) -> Bool {
        let home = URL(fileURLWithPath: (source.configDirectory as NSString).expandingTildeInPath, isDirectory: true)
        let root = home.appendingPathComponent("session-state", isDirectory: true)
        guard let folders = try? files.contentsOfDirectory(atPath: root.path) else { return false }
        for id in folders.sorted() where Self.isSessionUUID(id) {
            let folder = root.appendingPathComponent(id, isDirectory: true)
            guard let names = try? files.contentsOfDirectory(atPath: folder.path) else { continue }
            // events.jsonl, plus rotated events.<n>.jsonl journals.
            let events = names.filter { $0 == "events.jsonl" || ($0.hasPrefix("events.") && $0.hasSuffix(".jsonl")
                && Int($0.dropFirst(7).dropLast(6)) != nil) }.sorted().map { folder.appendingPathComponent($0) }
            guard !events.isEmpty else { continue }
            let cwd = Self.yamlScalar("cwd", in: folder.appendingPathComponent("workspace.yaml"))
            discovered.cli.append(CLISession(source: source, id: id, events: events, recordedCwd: cwd))
            discovered.tasks += events.map { ScanTask(source: source, url: $0, kind: .cliEvents) }
        }
        return true
    }

    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func isSessionUUID(_ id: String) -> Bool {
        UUID(uuidString: id) != nil
    }

    /// One flat `key: value` scalar from a small YAML file. Multi-line values
    /// and nested keys are ignored.
    static func yamlScalar(_ key: String, in url: URL) -> String? {
        guard let stat = FileStat.of(url.path), stat.kind == .regular, stat.size <= 262_144,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix("\(key):") {
            var value = line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }
            return value.isEmpty ? nil : value
        }
        return nil
    }

    // MARK: Folding

    private func result(_ discovered: Discovered, parsed: [String: CopilotFile], notices: [String]) -> ScanResult {
        var sessions: [HistorySession] = []
        var unreadableStates = 0
        for chat in discovered.chats {
            guard let log = parsed[chat.log.path]?.chat, !log.requests.isEmpty else { continue }
            let editingFile = chat.editing.flatMap { parsed[$0.path] }
            if editingFile != nil, editingFile?.editing == nil, editingFile?.stamp != nil { unreadableStates += 1 }
            guard let session = Self.session(chat, log: log, editing: editingFile?.editing) else { continue }
            sessions.append(session)
        }
        for cli in discovered.cli {
            if let session = Self.session(cli, logs: cli.events.compactMap { parsed[$0.path]?.cli }) {
                sessions.append(session)
            }
        }
        var notices = notices
        if unreadableStates > 0 {
            notices.append("Copilot: \(unreadableStates) VS Code chat edit record(s) use a format this version doesn't read; their edits are not counted.")
        }
        let folded = HistoryFold.fold(sessions, resolver: resolver)
        return ScanResult(projects: ProjectSummary.merge(folded.activity), notices: Array(Set(notices)).sorted(),
            sessionProjects: folded.associations, missingFolders: folded.missingFolders,
            sessionTrails: SessionTrail.merge(folded.trails))
    }

    private static func session(_ chat: ChatSession, log: ChatLog, editing: EditingState?) -> HistorySession? {
        let starts = log.requests.compactMap(\.started)
        guard let created = log.created ?? starts.min(), let workspace = chat.roots.first else { return nil }
        let latest = ([created] + starts + log.requests.compactMap(\.completed)).max() ?? created
        var edits: [String: StoredEdit] = [:]
        var delegated: Set<String> = []
        for (id, edit, isDelegated) in confirmedEdits(log, editing: editing, roots: chat.roots) {
            edits[id] = edits[id]?.earlier(than: edit) ?? edit
            if isDelegated { delegated.insert(id) }
        }
        var session = HistorySession(sourceID: chat.source.id, sessionID: log.sessionID ?? chat.id,
            recordedWorkspace: workspace, roots: chat.roots, createdAt: created, latestActivity: latest, edits: edits)
        session.delegatedEdits = delegated
        return session
    }

    /// Each edit tool call whose file VS Code applied in that request is one
    /// edit. Applied files no call names (older logs) count once per request.
    static func confirmedEdits(_ log: ChatLog, editing: EditingState?, roots: [String]) -> [(String, StoredEdit, Bool)] {
        guard let editing else { return [] }
        var applied: [Int: Set<String>] = [:]
        for (index, request) in log.requests.enumerated() {
            var paths = Set(editing.confirmed[request.id] ?? [])
            paths.subtract(editing.rejected[request.id] ?? [])
            if !paths.isEmpty { applied[index] = paths }
        }
        // An Undo in a later request reverts the latest earlier request's edits to that file.
        for (index, request) in log.requests.enumerated() {
            for path in request.undone {
                if let earlier = applied.keys.filter({ $0 < index && applied[$0]!.contains(path) }).max() {
                    applied[earlier]!.remove(path)
                }
            }
        }
        var result: [(String, StoredEdit, Bool)] = []
        for (index, paths) in applied.sorted(by: { $0.key < $1.key }) where !paths.isEmpty {
            let request = log.requests[index]
            var covered: Set<String> = []
            for (position, call) in request.calls.sorted(by: { $0.key < $1.key }) {
                let targets = call.paths.filter { paths.contains($0) }
                guard !targets.isEmpty, let date = call.completed ?? request.completed ?? request.started else { continue }
                covered.formUnion(targets)
                let id = call.id.isEmpty ? "\(request.id)#\(position)" : call.id
                result.append(("vscode:\(id)", edit(date: date, targets: targets, roots: roots), call.delegated))
            }
            guard let date = request.completed ?? request.started else { continue }
            for path in paths.subtracting(covered).sorted() {
                result.append(("vscode:\(request.id)\u{0}\(path)", edit(date: date, targets: [path], roots: roots), false))
            }
        }
        return result
    }

    /// The edit's working folder is the workspace folder holding its files.
    private static func edit(date: Date, targets: [String], roots: [String]) -> StoredEdit {
        let workspace = roots.filter { root in targets.allSatisfy { CheckoutPath.contains(root: root, path: $0) } }
            .max { $0.count < $1.count } ?? roots[0]
        let directories = Array(Set(targets.map { ($0 as NSString).deletingLastPathComponent })).sorted()
        return StoredEdit(date: date, workspace: workspace, targetDirectories: directories)
    }

    private static func session(_ cli: CLISession, logs: [CLILog]) -> HistorySession? {
        let recorded = cli.recordedCwd.flatMap(ProjectLocationRegistry.lexicalPath)
        guard let workspace = logs.compactMap(\.firstCwd).first ?? recorded,
              let created = logs.compactMap(\.created).min() ?? logs.compactMap(\.latest).min() else { return nil }
        let latest = logs.compactMap(\.latest).max() ?? created
        var edits: [String: StoredEdit] = [:]
        var delegated: Set<String> = []
        for log in logs {
            for (id, var edit) in log.edits {
                // A rotated journal can begin before any event names the folder.
                if edit.workspace.isEmpty { edit.workspace = workspace }
                edits[id] = edits[id]?.earlier(than: edit) ?? edit
            }
            delegated.formUnion(log.delegated)
        }
        let roots = Array(Set(logs.flatMap(\.roots) + [workspace])).sorted()
        var session = HistorySession(sourceID: cli.source.id, sessionID: cli.id, recordedWorkspace: workspace,
            roots: roots, createdAt: created, latestActivity: max(created, latest), edits: edits)
        session.delegatedEdits = delegated.intersection(edits.keys)
        return session
    }
}

// MARK: - Cached evidence

/// A whole-file store's identity, size and modification time.
struct FileStamp: Codable, Equatable {
    var identity: String
    var size: UInt64
    var modified: TimeInterval

    init(_ stat: FileStat) {
        identity = stat.identity
        size = stat.size
        modified = stat.modified.timeIntervalSince1970
    }
}

final class CopilotFile: Codable {
    var tail = TailState()
    var stamp: FileStamp?
    var chat: ChatLog?
    var editing: EditingState?
    var cli: CLILog?

    init() {}
}

/// A path into the chat object, as the mutation log writes it.
enum ChatKey: Equatable {
    case key(String)
    case index(Int)

    static func path(_ value: Any?) -> [ChatKey]? {
        guard let items = value as? [Any] else { return value == nil ? [] : nil }
        var path: [ChatKey] = []
        for item in items {
            if let text = item as? String { path.append(.key(text)) }
            // `is Bool` is also true for the numbers 0 and 1, so test the CF type.
            else if let number = item as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                path.append(.index(number.intValue))
            }
            else { return nil }
        }
        return path
    }
}

/// The parts of one VS Code chat that edit attribution needs, kept in step
/// with its mutation log: kind 0 replaces the chat, 1 sets a path, 2 pushes
/// onto an array (first truncating it to `i` when given), 3 deletes a key.
struct ChatLog: Codable, Equatable {
    var sessionID: String?
    var created: Date?
    var requests: [ChatRequest] = []

    static let editTools: Set<String> = [
        "copilot_replaceString", "copilot_multiReplaceString", "copilot_insertEdit", "copilot_createFile",
        "copilot_applyPatch", "copilot_editNotebook", "copilot_editFiles"
    ]

    /// Returns false for a record that is not a mutation.
    mutating func apply(_ entry: [String: Any]) -> Bool {
        guard let kind = (entry["kind"] as? NSNumber)?.intValue, let path = ChatKey.path(entry["k"]) else { return false }
        switch kind {
        case 0:
            guard let object = entry["v"] as? [String: Any] else { return false }
            reset(from: object)
        case 1:
            set(path, entry["v"])
        case 2:
            push(path, entry["v"] as? [Any] ?? [], truncate: (entry["i"] as? NSNumber)?.intValue)
        case 3:
            set(path, nil)
        default:
            break
        }
        return true
    }

    mutating func reset(from object: [String: Any]) {
        sessionID = object["sessionId"] as? String
        created = RecordedDate.milliseconds(object["creationDate"])
        requests = (object["requests"] as? [Any] ?? []).map(ChatRequest.init)
    }

    private mutating func set(_ path: [ChatKey], _ value: Any?) {
        switch path.first {
        case nil:
            if let object = value as? [String: Any] { reset(from: object) }
        case .key("sessionId")?:
            if path.count == 1 { sessionID = value as? String }
        case .key("creationDate")?:
            if path.count == 1 { created = RecordedDate.milliseconds(value) }
        case .key("requests")?:
            guard path.count > 1 else {
                requests = (value as? [Any] ?? []).map(ChatRequest.init)
                return
            }
            guard case .index(let index) = path[1], index >= 0 else { return }
            if path.count == 2 {
                guard let value else { return }
                if index < requests.count { requests[index] = ChatRequest(value) }
                else if index == requests.count { requests.append(ChatRequest(value)) }
                return
            }
            guard index < requests.count else { return }
            requests[index].set(Array(path.dropFirst(2)), value)
        default:
            break
        }
    }

    private mutating func push(_ path: [ChatKey], _ values: [Any], truncate: Int?) {
        guard path.first == .key("requests") else { return }
        if path.count == 1 {
            if let truncate, truncate >= 0, truncate < requests.count { requests.removeSubrange(truncate...) }
            requests += values.map(ChatRequest.init)
            return
        }
        guard case .index(let index) = path[1], index >= 0, index < requests.count else { return }
        requests[index].push(Array(path.dropFirst(2)), values, truncate: truncate)
    }
}

struct ChatRequest: Codable, Equatable {
    var id = ""
    var started: Date?
    var completed: Date?
    /// The response's length, so pushes and truncations keep indexes aligned.
    var parts = 0
    /// Edit tool calls by their index in the response.
    var calls: [Int: ChatEditCall] = [:]
    /// Files the user undid when sending this request (editedFileEvents).
    var undone: [String] = []

    init(_ value: Any) {
        guard let object = value as? [String: Any] else { return }
        id = object["requestId"] as? String ?? ""
        started = RecordedDate.milliseconds(object["timestamp"])
        completed = Self.completion(object["modelState"])
        setParts(object["response"] as? [Any] ?? [], from: 0)
        undone = Self.undone(object["editedFileEvents"] as? [Any] ?? [])
    }

    mutating func set(_ path: [ChatKey], _ value: Any?) {
        switch path.first {
        case .key("requestId")?:
            if path.count == 1, let text = value as? String { id = text }
        case .key("timestamp")?:
            if path.count == 1 { started = RecordedDate.milliseconds(value) }
        case .key("modelState")?:
            if path.count == 1 { completed = Self.completion(value) }
            else if path.count == 2, path[1] == .key("completedAt") { completed = RecordedDate.milliseconds(value) }
        case .key("response")?:
            guard path.count > 1 else {
                setParts(value as? [Any] ?? [], from: 0)
                return
            }
            guard case .index(let index) = path[1], index >= 0, index <= parts else { return }
            if path.count == 2 {
                if index == parts {
                    guard let value else { return }
                    parts += 1
                    calls[index] = ChatEditCall(value)
                } else {
                    calls[index] = value.flatMap(ChatEditCall.init)
                }
            } else {
                calls[index]?.update(Array(path.dropFirst(2)), value)
            }
        case .key("editedFileEvents")?:
            if path.count == 1 { undone = Self.undone(value as? [Any] ?? []) }
        default:
            break
        }
    }

    mutating func push(_ path: [ChatKey], _ values: [Any], truncate: Int?) {
        switch path {
        case [.key("response")]:
            setParts(values, from: truncate.map { min(max($0, 0), parts) } ?? parts)
        case [.key("editedFileEvents")]:
            undone += Self.undone(values)
        default:
            break
        }
    }

    /// Truncates the response to `start` parts, then appends `values`.
    private mutating func setParts(_ values: [Any], from start: Int) {
        calls = calls.filter { $0.key < start }
        parts = start
        for value in values {
            if let call = ChatEditCall(value) { calls[parts] = call }
            parts += 1
        }
    }

    /// ResponseModelState 1 Complete, 2 Cancelled, 3 Failed carry completedAt.
    private static func completion(_ value: Any?) -> Date? {
        (value as? [String: Any]).flatMap { RecordedDate.milliseconds($0["completedAt"]) }
    }

    /// ChatRequestEditedFileEventKind 2 is Undo.
    private static func undone(_ events: [Any]) -> [String] {
        events.compactMap { event in
            guard let object = event as? [String: Any], (object["eventKind"] as? NSNumber)?.intValue == 2 else { return nil }
            return VSCodeURI.localPath(object["uri"])
        }
    }
}

struct ChatEditCall: Codable, Equatable {
    var id: String
    var paths: [String]
    var completed: Date?
    var delegated: Bool

    init?(_ value: Any) {
        guard let object = value as? [String: Any], object["kind"] as? String == "toolInvocationSerialized",
              let tool = object["toolId"] as? String, ChatLog.editTools.contains(tool) else { return nil }
        id = object["toolCallId"] as? String ?? ""
        paths = Array(Set(Self.paths(object["invocationMessage"]) + Self.paths(object["pastTenseMessage"]))).sorted()
        completed = RecordedDate.milliseconds(object["completedAt"])
        delegated = object["subAgentInvocationId"].map { !($0 is NSNull) } ?? false
    }

    mutating func update(_ path: [ChatKey], _ value: Any?) {
        guard path.count == 1, case .key(let field) = path[0] else { return }
        switch field {
        case "invocationMessage", "pastTenseMessage":
            paths = Array(Set(paths + Self.paths(value))).sorted()
        case "completedAt":
            completed = RecordedDate.milliseconds(value)
        case "subAgentInvocationId":
            delegated = value.map { !($0 is NSNull) } ?? false
        default:
            break
        }
    }

    /// The files a progress message names: its `uris` values, local files only.
    private static func paths(_ message: Any?) -> [String] {
        guard let object = message as? [String: Any], let uris = object["uris"] as? [String: Any] else { return [] }
        return uris.compactMap { key, value in VSCodeURI.localPath(value) ?? VSCodeURI.localPath(key) }
    }
}

/// What `chatEditingSessions/<id>/state.json` proves: files VS Code applied
/// per request, and files whose latest change the user rejected.
struct EditingState: Codable, Equatable {
    var confirmed: [String: [String]] = [:]
    var rejected: [String: [String]] = [:]

    static let operationTypes: Set<String> = ["textEdit", "create", "delete", "rename", "notebookEdit"]

    /// Nil for a version this reader does not know.
    init?(_ object: [String: Any]) {
        guard let version = (object["version"] as? NSNumber)?.intValue, (1...2).contains(version) else { return nil }
        var confirmed: [String: Set<String>] = [:]
        if let timeline = object["timeline"] as? [String: Any] {
            // Operations at or after the current epoch were undone by restoring a checkpoint.
            let current = (timeline["currentEpoch"] as? NSNumber)?.intValue ?? Int.max
            for case let operation as [String: Any] in timeline["operations"] as? [Any] ?? [] {
                guard let type = operation["type"] as? String, Self.operationTypes.contains(type),
                      let request = operation["requestId"] as? String, !request.isEmpty,
                      let epoch = (operation["epoch"] as? NSNumber)?.intValue, epoch < current,
                      let path = VSCodeURI.localPath(operation["uri"] ?? operation["newUri"]) else { continue }
                confirmed[request, default: []].insert(path)
            }
        }
        var rejected: [String: Set<String>] = [:]
        let entries = (object["recentSnapshot"] as? [String: Any])?["entries"] as? [Any] ?? []
        for case let entry as [String: Any] in entries where (entry["state"] as? NSNumber)?.intValue == 2 {
            guard let path = VSCodeURI.localPath(entry["resource"]),
                  let request = (entry["telemetryInfo"] as? [String: Any])?["requestId"] as? String else { continue }
            rejected[request, default: []].insert(path)
        }
        self.confirmed = confirmed.mapValues { $0.sorted() }
        self.rejected = rejected.mapValues { $0.sorted() }
    }
}

/// One Copilot CLI journal's evidence.
struct CLILog: Codable, Equatable {
    var created: Date?
    var latest: Date?
    var firstCwd: String?
    var cwd: String?
    var roots: [String] = []
    var pending: [String: [String]] = [:]
    var pendingDelegated: [String] = []
    var edits: [String: StoredEdit] = [:]
    var delegated: [String] = []

    /// Tools whose `path` argument names the file when `fileEdits` is absent
    /// (CLI builds before 1.0.92). `apply_patch` paths come only from `fileEdits`.
    static let pathTools: Set<String> = ["edit", "create", "str_replace_editor", "write"]

    mutating func apply(_ object: [String: Any]) -> Bool {
        guard let type = object["type"] as? String else { return false }
        // Replayed history at the head of a rotated journal.
        if object["checkpoint"] as? Bool == true { return true }
        let date = RecordedDate.any(object["timestamp"])
        if let date { latest = max(latest ?? date, date) }
        let data = object["data"] as? [String: Any] ?? [:]
        switch type {
        case "session.start":
            created = created ?? RecordedDate.any(data["startTime"]) ?? date
            context(data["context"])
        case "session.resume":
            context(data["context"])
        case "session.context_changed":
            context(data["context"] ?? data)
        case "tool.execution_start":
            guard let id = data["toolCallId"] as? String, !id.isEmpty else { return true }
            let name = data["toolName"] as? String ?? ""
            let arguments = data["arguments"] as? [String: Any] ?? [:]
            var paths: [String] = []
            if Self.pathTools.contains(name), arguments["command"] as? String != "view",
               let path = arguments["path"] as? String, let resolved = resolve(path) {
                paths = [resolved]
            }
            pending[id] = paths
            if object["agentId"].map({ !($0 is NSNull) }) == true { pendingDelegated.append(id) }
        case "tool.execution_complete":
            guard let id = data["toolCallId"] as? String, !id.isEmpty else { return true }
            let started = pending.removeValue(forKey: id)
            let isDelegated = pendingDelegated.contains(id) || object["agentId"].map({ !($0 is NSNull) }) == true
            pendingDelegated.removeAll { $0 == id }
            guard data["success"] as? Bool == true, let date else { return true }
            let committed = (data["fileEdits"] as? [Any] ?? []).compactMap { item -> String? in
                ((item as? [String: Any])?["path"] as? String).flatMap(resolve)
            }
            let paths = committed.isEmpty ? (started ?? []) : committed
            guard !paths.isEmpty else { return true }
            let directories = Array(Set(paths.map { ($0 as NSString).deletingLastPathComponent })).sorted()
            let edit = StoredEdit(date: date, workspace: cwd ?? "", targetDirectories: directories)
            edits[id] = edits[id]?.earlier(than: edit) ?? edit
            if isDelegated, !delegated.contains(id) { delegated.append(id) }
        default:
            break
        }
        return true
    }

    private mutating func context(_ value: Any?) {
        guard let context = value as? [String: Any], let raw = context["cwd"] as? String,
              let folder = ProjectLocationRegistry.lexicalPath(raw) else { return }
        cwd = folder
        if firstCwd == nil { firstCwd = folder }
        if !roots.contains(folder) { roots.append(folder) }
    }

    private func resolve(_ path: String) -> String? {
        if path.hasPrefix("/") { return ProjectLocationRegistry.lexicalPath(path) }
        guard let cwd, !path.isEmpty, !path.hasPrefix("~") else { return nil }
        return ProjectLocationRegistry.lexicalPath((cwd as NSString).appendingPathComponent(path))
    }
}

// MARK: - VS Code records

enum VSCodeURI {
    /// A local file's path from a serialized URI object (`{scheme, path,
    /// fsPath}`) or a URI string. Remote, untitled and other schemes are nil;
    /// a notebook cell maps to its notebook file.
    static func localPath(_ value: Any?) -> String? {
        if let object = value as? [String: Any] {
            guard let scheme = object["scheme"] as? String, scheme == "file" || scheme == "vscode-notebook-cell",
                  (object["authority"] as? String ?? "").isEmpty,
                  let path = (object["fsPath"] as? String) ?? (object["path"] as? String) else { return nil }
            return ProjectLocationRegistry.lexicalPath(path)
        }
        guard let text = value as? String, let url = URL(string: text),
              url.scheme == "file" || url.scheme == "vscode-notebook-cell", (url.host ?? "").isEmpty else { return nil }
        return ProjectLocationRegistry.lexicalPath(url.path)
    }
}

enum VSCodeWorkspace {
    /// The local folders a window opened, from its `workspace.json`: one
    /// folder, or a `.code-workspace` file's folders. Empty for a remote or
    /// folderless window; nil when the record cannot be read.
    static func roots(of url: URL) -> [String]? {
        guard let object = smallJSON(url) else { return nil }
        if let folder = object["folder"] as? String {
            return VSCodeURI.localPath(folder).map { [$0] } ?? []
        }
        guard let workspace = object["workspace"] as? String else { return [] }
        guard let file = VSCodeURI.localPath(workspace) else { return [] }
        return codeWorkspaceFolders(URL(fileURLWithPath: file))
    }

    /// A `.code-workspace` file's folders, resolved against its own folder.
    static func codeWorkspaceFolders(_ url: URL) -> [String] {
        guard let stat = FileStat.of(url.path), stat.kind == .regular, stat.size <= 1_048_576,
              let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
              let object = (try? JSONSerialization.jsonObject(with: Data(stripJSONC(text).utf8))) as? [String: Any] else {
            return []
        }
        let base = url.deletingLastPathComponent().path
        var roots: [String] = []
        for case let folder as [String: Any] in object["folders"] as? [Any] ?? [] {
            let resolved: String?
            if let path = folder["path"] as? String {
                resolved = path.hasPrefix("/") ? ProjectLocationRegistry.lexicalPath(path)
                    : ProjectLocationRegistry.lexicalPath((base as NSString).appendingPathComponent(path))
            } else {
                resolved = VSCodeURI.localPath(folder["uri"])
            }
            if let resolved, !roots.contains(resolved) { roots.append(resolved) }
        }
        return roots
    }

    private static func smallJSON(_ url: URL) -> [String: Any]? {
        guard let stat = FileStat.of(url.path), stat.kind == .regular, stat.size <= 1_048_576,
              let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// JSON with comments and trailing commas, as VS Code writes settings.
    static func stripJSONC(_ text: String) -> String {
        var output: [Character] = []
        var characters = Array(text)
        var index = 0
        var inString = false
        while index < characters.count {
            let character = characters[index]
            if inString {
                output.append(character)
                if character == "\\", index + 1 < characters.count {
                    output.append(characters[index + 1])
                    index += 2
                    continue
                }
                if character == "\"" { inString = false }
                index += 1
                continue
            }
            if character == "\"" {
                inString = true
                output.append(character)
                index += 1
            } else if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
            } else if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2
                while index + 1 < characters.count, !(characters[index] == "*" && characters[index + 1] == "/") { index += 1 }
                index += 2
            } else if character == "," {
                // Drop a comma that only whitespace separates from a closing bracket.
                var next = index + 1
                while next < characters.count, characters[next].isWhitespace { next += 1 }
                if next < characters.count, characters[next] == "}" || characters[next] == "]" {
                    index += 1
                } else {
                    output.append(character)
                    index += 1
                }
            } else {
                output.append(character)
                index += 1
            }
        }
        characters = output
        return String(characters)
    }
}
