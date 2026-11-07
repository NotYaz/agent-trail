import Foundation

/// Read-only adapter for Google's Gemini CLI under the profile's home
/// (`~/.gemini`, or `$GEMINI_CLI_HOME/.gemini`). Under the macOS sandbox
/// (Seatbelt) the CLI writes the same layout to the sibling `.cache/.gemini`,
/// which is read too.
///
/// Sessions live in `tmp/<folder>/chats/session-*.jsonl` (append-only since
/// v0.39; a whole `session-*.json` before it). A subagent writes its own file
/// in `chats/<root session id>/<agent id>.jsonl`; its edits join that session
/// as delegated. A session names its folder only as `projectHash`, the SHA-256
/// of the folder Gemini was started in. That folder comes from Gemini's own
/// records (`tmp/<folder>/.project_root` and `projects.json`), accepted only
/// when its hash matches; the folder name is never decoded.
///
/// One confirmed edit is a `write_file` or `replace` tool call recorded with
/// status `success`. Its file is the call's `resultDisplay.filePath` (v0.25
/// and later), else its `file_path` argument; a relative argument (v0.20 to
/// v0.24) is resolved against the session's folder. Its time is the call's
/// own timestamp, written when its batch completed. Every update appends the
/// whole message again, so calls are deduplicated by id. Rewinds and
/// `$patch` removals are not replayed: they hide messages from the model, and
/// the edits they hid still happened. Files under Gemini's own folders (plan
/// mode writes plans there) never count.
///
/// Shell commands, failed or cancelled calls and file modification times are
/// never evidence. The cache keeps ids, times and folder paths only: no
/// prompts, code, diffs or file content.
public final class GeminiActivityProvider: ActivityProvider {
    static let cacheVersion = 1
    private let cache: HistoryCache<GeminiFile>
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
        cache = HistoryCache(url: cacheURL, version: Self.cacheVersion, name: "Gemini CLI")
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
        var parsed: [String: GeminiFile] = [:]
        let tasks = discovered.tasks
        var lastProgress = Date.distantPast
        for (index, task) in tasks.enumerated() {
            let cached = cache[task.url.path]
            let file = cached ?? GeminiFile()
            let before = (file.tail, file.stamp)
            do {
                if task.legacy {
                    try readWhole(task.url, file: file)
                } else {
                    try JSONLTail.read(url: task.url, state: &file.tail, reset: { file.log = GeminiLog() }) { line in
                        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return false }
                        file.log.apply(object)
                        return true
                    }
                }
                // Parsed evidence changes only with the tail or stamp.
                cache.store(file, at: task.url.path, changed: cached == nil || file.tail != before.0 || file.stamp != before.1)
                parsed[task.url.path] = file
                if file.tail.malformedLines > 0 {
                    notices.append("\(task.source.name): skipped unreadable records in a Gemini CLI session history.")
                }
                if file.tail.oversizedLines > 0 {
                    notices.append("\(task.source.name): a Gemini CLI session history record was too large to index safely.")
                }
            } catch {
                notices.append("\(task.source.name): could not read a Gemini CLI session's history.")
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

    /// A legacy `session-*.json` is rewritten whole on every update, so it is
    /// reparsed only when its identity, size or modification time changes.
    private func readWhole(_ url: URL, file: GeminiFile) throws {
        let stat = try FileStat.required(url)
        let stamp = FileStamp(stat)
        guard stamp != file.stamp else { return }
        guard stat.size <= UInt64(JSONLTail.maximumLineBytes) else {
            file.stamp = stamp
            file.log = GeminiLog()
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
        var log = GeminiLog()
        log.apply(object)
        file.log = log
    }

    // MARK: Discovery

    private struct ScanTask {
        let source: AgentSource
        let url: URL
        /// A whole-file `session-*.json`.
        let legacy: Bool
        /// For a subagent file, the folder it sits in: its root session's id.
        let parentFolder: String?
    }

    private struct Discovered {
        var tasks: [ScanTask] = []
        var notices: [String] = []
        /// Each project folder Gemini recorded, by the SHA-256 of its path.
        var roots: [String: String] = [:]
        /// Gemini's own folders per profile; files there are never project edits.
        var internalFolders: [String: [String]] = [:]
    }

    private func discover(sources: [AgentSource]) -> Discovered {
        var discovered = Discovered()
        for source in sources where source.assistant == .gemini {
            var found = false
            var ownFolders: [String] = []
            for runtime in Self.runtimeFolders(source) {
                ownFolders.append(runtime.path)
                let physical = canonicalPath(runtime.path)
                if physical != runtime.path { ownFolders.append(physical) }
                found = discoverRuntime(source, runtime: runtime, into: &discovered) || found
            }
            discovered.internalFolders[source.id] = ownFolders
            if !found {
                discovered.notices.append("\(source.name): no local Gemini CLI history was found.")
            }
        }
        return discovered
    }

    /// The profile's home and, for a home named `.gemini`, the sibling
    /// `.cache/.gemini` the CLI uses under the macOS sandbox.
    static func runtimeFolders(_ source: AgentSource) -> [URL] {
        let expanded = (source.configDirectory as NSString).expandingTildeInPath
        let home = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        var folders = [home]
        if home.lastPathComponent == ".gemini" {
            folders.append(home.deletingLastPathComponent()
                .appendingPathComponent(".cache", isDirectory: true)
                .appendingPathComponent(".gemini", isDirectory: true))
        }
        return folders
    }

    /// Returns true when the folder holds Gemini CLI project storage.
    private func discoverRuntime(_ source: AgentSource, runtime: URL, into discovered: inout Discovered) -> Bool {
        let tmp = runtime.appendingPathComponent("tmp", isDirectory: true)
        guard let folders = try? files.contentsOfDirectory(atPath: tmp.path) else { return false }
        for path in Self.registeredProjects(runtime.appendingPathComponent("projects.json")) {
            discovered.roots[GeminiSHA256.hex(Array(path.utf8))] = ProjectLocationRegistry.lexicalPath(path)
        }
        for name in folders.sorted() where !name.hasPrefix(".") {
            let folder = tmp.appendingPathComponent(name, isDirectory: true)
            if let marker = Self.projectRoot(folder.appendingPathComponent(".project_root")) {
                discovered.roots[marker.hash] = marker.path
            }
            let chats = folder.appendingPathComponent("chats", isDirectory: true)
            guard let names = try? files.contentsOfDirectory(atPath: chats.path) else { continue }
            let logs = Set(names.filter { $0.hasSuffix(".jsonl") }.map { String($0.dropLast(6)) })
            for entry in names.sorted() {
                let url = chats.appendingPathComponent(entry)
                // Exact suffixes skip `.tmp-<pid>` and `.unreadable-<ms>` leftovers.
                if entry.hasPrefix("session-"), entry.hasSuffix(".jsonl") {
                    discovered.tasks.append(ScanTask(source: source, url: url, legacy: false, parentFolder: nil))
                } else if entry.hasPrefix("session-"), entry.hasSuffix(".json") {
                    // Resuming a legacy session copies it whole to `<name>.jsonl`, which wins.
                    guard !logs.contains(String(entry.dropLast(5))) else { continue }
                    discovered.tasks.append(ScanTask(source: source, url: url, legacy: true, parentFolder: nil))
                } else if Self.isSafeID(entry), FileStat.of(url.path)?.kind == .directory,
                          let nested = try? files.contentsOfDirectory(atPath: url.path) {
                    for child in nested.sorted() where child.hasSuffix(".jsonl") && Self.isSafeID(String(child.dropLast(6))) {
                        discovered.tasks.append(ScanTask(source: source, url: url.appendingPathComponent(child),
                                                         legacy: false, parentFolder: entry))
                    }
                }
            }
        }
        return true
    }

    /// Letters, digits, `-` and `_`: what Gemini keeps of an id in a file name.
    static func isSafeID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// `.project_root`: the folder's project path as plain text, and the
    /// SHA-256 of exactly those bytes.
    static func projectRoot(_ url: URL) -> (path: String, hash: String)? {
        guard let stat = FileStat.of(url.path), stat.kind == .regular, stat.size <= 65_536,
              let data = try? Data(contentsOf: url) else { return nil }
        var bytes = [UInt8](data)
        while let last = bytes.last, last == 0x0A || last == 0x0D || last == 0x20 || last == 0x09 { bytes.removeLast() }
        while let first = bytes.first, first == 0x0A || first == 0x0D || first == 0x20 || first == 0x09 { bytes.removeFirst() }
        guard let text = String(bytes: bytes, encoding: .utf8), text.hasPrefix("/"),
              let path = ProjectLocationRegistry.lexicalPath(text) else { return nil }
        return (path, GeminiSHA256.hex(bytes))
    }

    /// The absolute project paths `projects.json` maps to their folders.
    static func registeredProjects(_ url: URL) -> [String] {
        guard let stat = FileStat.of(url.path), stat.kind == .regular, stat.size <= 4_194_304,
              let data = try? Data(contentsOf: url),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let projects = object["projects"] as? [String: Any] else { return [] }
        return projects.keys.filter { $0.hasPrefix("/") && $0.utf8.count <= 32_768 }.sorted()
    }

    // MARK: Folding

    private struct Part {
        let source: AgentSource
        let log: GeminiLog
        /// The verified folder the file's session was started in.
        let root: String
        let delegated: Bool
    }

    private struct Subagent {
        let part: Part
        /// The folder it sits in (its root session's id), when nested.
        let parent: String?
        let id: String
    }

    private func result(_ discovered: Discovered, parsed: [String: GeminiFile], notices: [String]) -> ScanResult {
        var mains: [String: [Part]] = [:]
        var order: [(key: String, id: String)] = []
        var subagents: [Subagent] = []
        var unmatched: Set<String> = []
        for task in discovered.tasks {
            guard let log = parsed[task.url.path]?.log, let id = log.sessionID, let hash = log.projectHash else { continue }
            guard let root = discovered.roots[hash] else {
                unmatched.insert(task.source.name)
                continue
            }
            let isSubagent = task.parentFolder != nil || log.kind == "subagent"
            let part = Part(source: task.source, log: log, root: root, delegated: isSubagent)
            if isSubagent {
                subagents.append(Subagent(part: part, parent: task.parentFolder, id: id))
                continue
            }
            let key = task.source.id + "\u{0}" + id
            if mains[key] == nil { order.append((key: key, id: id)) }
            mains[key, default: []].append(part)
        }
        // A subagent's edits join its root session as delegated. One whose
        // session is gone stands alone, every edit delegated.
        var orphans: [Subagent] = []
        for subagent in subagents {
            if let parent = subagent.parent, mains[subagent.part.source.id + "\u{0}" + parent] != nil {
                mains[subagent.part.source.id + "\u{0}" + parent, default: []].append(subagent.part)
            } else {
                orphans.append(subagent)
            }
        }
        var sessions: [HistorySession] = []
        for entry in order {
            guard let parts = mains[entry.key],
                  let session = self.session(id: entry.id, parts: parts, parent: nil,
                                             excludedFolders: discovered.internalFolders) else { continue }
            sessions.append(session)
        }
        for orphan in orphans {
            if let session = self.session(id: orphan.id, parts: [orphan.part], parent: orphan.parent,
                                          excludedFolders: discovered.internalFolders) {
                sessions.append(session)
            }
        }
        var notices = notices
        for name in unmatched {
            notices.append("\(name): some Gemini CLI sessions name a project folder that Gemini's own records on this Mac don't list; they are skipped.")
        }
        let folded = HistoryFold.fold(sessions, resolver: resolver)
        return ScanResult(projects: ProjectSummary.merge(folded.activity), notices: Array(Set(notices)).sorted(),
            sessionProjects: folded.associations, missingFolders: folded.missingFolders,
            sessionTrails: SessionTrail.merge(folded.trails))
    }

    /// One session from its files. A file with no user or model message (a
    /// CLI that has not been sent a prompt yet) is not a session.
    private func session(id: String, parts: [Part], parent: String?, excludedFolders: [String: [String]]) -> HistorySession? {
        let mains = parts.filter { !$0.delegated }
        let anchors = mains.isEmpty ? parts : mains
        guard anchors.contains(where: \.log.hasTurn) else { return nil }
        var first: (date: Date, part: Part)?
        for part in anchors {
            guard let date = part.log.started ?? part.log.firstMessage else { continue }
            if first == nil || date < (first?.date ?? date) { first = (date: date, part: part) }
        }
        guard let first, let source = parts.first?.source else { return nil }
        let created = first.date
        let workspace = first.part.root
        let latest = parts.compactMap(\.log.latest).max() ?? created
        let excluded = excludedFolders[source.id] ?? []
        var edits: [String: StoredEdit] = [:]
        var delegated: Set<String> = []
        for part in parts {
            for (callID, edit) in part.log.edits {
                guard let stored = Self.stored(edit, root: part.root, excluded: excluded) else { continue }
                // The same call copied into another file (a migrated legacy
                // session, an imported one) keeps its id and time.
                let key = callID + "\u{0}" + String(edit.date.timeIntervalSince1970)
                edits[key] = edits[key]?.earlier(than: stored) ?? stored
                if part.delegated || parent != nil { delegated.insert(key) }
            }
        }
        let roots = Array(Set(parts.map(\.root) + parts.flatMap(\.log.directories))).sorted()
        var session = HistorySession(sourceID: source.id, sessionID: id, recordedWorkspace: workspace, roots: roots,
            createdAt: created, latestActivity: max(created, latest), edits: edits)
        session.parentSessionID = parent
        session.canMove = Set(mains.map(\.root)).count <= 1
        session.delegatedEdits = delegated.intersection(edits.keys)
        return session
    }

    /// The edit as folded: relative files resolved against the session's
    /// folder, Gemini's own folders dropped. The working folder is the one
    /// Gemini was started in, which is where it resolves files.
    static func stored(_ edit: GeminiEdit, root: String, excluded: [String]) -> StoredEdit? {
        var directories = edit.directories
        for relative in edit.relative {
            if let path = ProjectLocationRegistry.lexicalPath((root as NSString).appendingPathComponent(relative)) {
                directories.append(path)
            }
        }
        let kept = Set(directories).filter { directory in
            !excluded.contains { CheckoutPath.contains(root: $0, path: directory) }
        }
        guard !kept.isEmpty else { return nil }
        return StoredEdit(date: edit.date, workspace: root, targetDirectories: kept.sorted())
    }
}

// MARK: - Cached evidence

final class GeminiFile: Codable {
    var tail = TailState()
    /// Set for a whole-file legacy `.json` session.
    var stamp: FileStamp?
    var log = GeminiLog()

    init() {}
}

/// One confirmed edit call, before folding.
struct GeminiEdit: Codable, Equatable {
    var date: Date
    /// Absolute parent folders of the edited file, as recorded.
    var directories: [String] = []
    /// Parent folders of a relative `file_path`, resolved when folding.
    var relative: [String] = []

    func earlier(than other: GeminiEdit) -> GeminiEdit {
        var kept = date <= other.date ? self : other
        kept.directories = Array(Set(directories + other.directories)).sorted()
        kept.relative = Array(Set(relative + other.relative)).sorted()
        return kept
    }
}

/// What one Gemini CLI session file proves, replayed line by line. Every
/// line kind is read raw: a header, a message (appended whole again on each
/// change; the same tool call id repeats), `$set` metadata (whose deprecated
/// `messages` checkpoint is scanned like messages), and `$rewindTo` or
/// `$patch`, which are skipped. A legacy `.json` is one header with `messages`.
struct GeminiLog: Codable, Equatable {
    var sessionID: String?
    var projectHash: String?
    /// `main` or `subagent`.
    var kind: String?
    var started: Date?
    var firstMessage: Date?
    var latest: Date?
    /// True once a user or model message was recorded.
    var hasTurn = false
    /// Workspace folders the session declared (`/directory add`, subagents).
    var directories: [String] = []
    /// Confirmed edits by tool call id.
    var edits: [String: GeminiEdit] = [:]

    /// `write_file` and `replace` (EDIT_TOOL_NAMES). The 2025 smart-edit tool
    /// was registered as `replace` too.
    static let editTools: Set<String> = ["write_file", "replace"]

    mutating func apply(_ object: [String: Any]) {
        // The order Gemini's own loader tells record kinds apart in.
        if object["$rewindTo"] is String { return }
        if object["$patch"] is [String: Any] { return }
        if object["id"] is String {
            message(object)
            return
        }
        if let set = object["$set"] as? [String: Any] {
            metadata(set)
            messages(set["messages"])
            return
        }
        if object["sessionId"] is String, object["projectHash"] is String {
            metadata(object)
            messages(object["messages"])
        }
    }

    private mutating func note(_ date: Date) {
        latest = max(latest ?? date, date)
    }

    private mutating func metadata(_ object: [String: Any]) {
        if let id = object["sessionId"] as? String, GeminiActivityProvider.isSafeID(id) { sessionID = id }
        if let raw = object["projectHash"] as? String {
            let hash = raw.lowercased()
            if hash.count == 64, hash.allSatisfy({ $0.isASCII && $0.isHexDigit }) { projectHash = hash }
        }
        if let value = object["kind"] as? String, value == "main" || value == "subagent" { kind = value }
        if let date = (object["startTime"] as? String).flatMap(RecordedDate.parse) {
            started = min(started ?? date, date)
            note(date)
        }
        if let date = (object["lastUpdated"] as? String).flatMap(RecordedDate.parse) { note(date) }
        for case let raw as String in object["directories"] as? [Any] ?? [] where raw.hasPrefix("/") {
            guard directories.count < 64, let path = ProjectLocationRegistry.lexicalPath(raw),
                  !directories.contains(path) else { continue }
            directories.append(path)
        }
    }

    private mutating func messages(_ value: Any?) {
        for case let message as [String: Any] in value as? [Any] ?? [] where message["id"] is String {
            self.message(message)
        }
    }

    private mutating func message(_ object: [String: Any]) {
        let date = (object["timestamp"] as? String).flatMap(RecordedDate.parse)
        if let date {
            firstMessage = min(firstMessage ?? date, date)
            note(date)
        }
        let type = object["type"] as? String
        if type == "user" || type == "gemini" { hasTurn = true }
        guard type == "gemini", let calls = object["toolCalls"] as? [Any] else { return }
        for case let call as [String: Any] in calls {
            toolCall(call, messageDate: date)
        }
    }

    private mutating func toolCall(_ call: [String: Any], messageDate: Date?) {
        guard let id = call["id"] as? String, !id.isEmpty, id.utf8.count <= 512 else { return }
        let callDate = (call["timestamp"] as? String).flatMap(RecordedDate.parse)
        if let callDate { note(callDate) }
        guard let name = call["name"] as? String, Self.editTools.contains(name),
              call["status"] as? String == "success", let date = callDate ?? messageDate else { return }
        var folders: [String] = []
        var relative: [String] = []
        if let display = call["resultDisplay"] as? [String: Any], let raw = display["filePath"] as? String,
           raw.hasPrefix("/"), let path = ProjectLocationRegistry.lexicalPath(raw) {
            folders = [(path as NSString).deletingLastPathComponent]
        } else if let raw = (call["args"] as? [String: Any])?["file_path"] as? String, !raw.isEmpty,
                  !raw.contains("\0"), raw.utf8.count <= 32_768 {
            // `replace` creating a file shows only "Created <relative path>";
            // v0.20 to v0.24 record no `filePath` at all.
            if raw.hasPrefix("/") {
                if let path = ProjectLocationRegistry.lexicalPath(raw) {
                    folders = [(path as NSString).deletingLastPathComponent]
                }
            } else if !raw.hasPrefix("~"), !raw.contains("://") {
                relative = [(raw as NSString).deletingLastPathComponent]
            }
        }
        guard !folders.isEmpty || !relative.isEmpty else { return }
        let edit = GeminiEdit(date: date, directories: folders, relative: relative)
        edits[id] = edits[id]?.earlier(than: edit) ?? edit
    }
}

// MARK: - SHA-256

/// SHA-256, for checking a folder against a session's `projectHash`.
/// Foundation has no digest API, and the app links nothing else.
enum GeminiSHA256 {
    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
    ]

    /// Lowercase hex, as Node's `digest('hex')` writes it.
    static func hex(_ bytes: [UInt8]) -> String {
        var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
                               0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var message = bytes
        let bitLength = UInt64(bytes.count) &* 8
        message.append(0x80)
        while message.count % 64 != 56 { message.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            message.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        var w = [UInt32](repeating: 0, count: 64)
        var offset = 0
        while offset < message.count {
            for i in 0..<16 {
                let b0 = UInt32(message[offset + i * 4]) << 24
                let b1 = UInt32(message[offset + i * 4 + 1]) << 16
                let b2 = UInt32(message[offset + i * 4 + 2]) << 8
                let b3 = UInt32(message[offset + i * 4 + 3])
                w[i] = b0 | b1 | b2 | b3
            }
            for i in 16..<64 {
                let s0 = rotate(w[i - 15], 7) ^ rotate(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotate(w[i - 2], 17) ^ rotate(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var a = state[0], b = state[1], c = state[2], d = state[3]
            var e = state[4], f = state[5], g = state[6], h = state[7]
            for i in 0..<64 {
                let sum1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choice = (e & f) ^ (~e & g)
                let t1 = h &+ sum1 &+ choice &+ k[i] &+ w[i]
                let sum0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let t2 = sum0 &+ majority
                h = g
                g = f
                f = e
                e = d &+ t1
                d = c
                c = b
                b = a
                a = t1 &+ t2
            }
            state[0] = state[0] &+ a
            state[1] = state[1] &+ b
            state[2] = state[2] &+ c
            state[3] = state[3] &+ d
            state[4] = state[4] &+ e
            state[5] = state[5] &+ f
            state[6] = state[6] &+ g
            state[7] = state[7] &+ h
            offset += 64
        }
        let digits: [Character] = Array("0123456789abcdef")
        var text = ""
        text.reserveCapacity(64)
        for word in state {
            for shift in stride(from: 28, through: 0, by: -4) {
                text.append(digits[Int((word >> UInt32(shift)) & 0xF)])
            }
        }
        return text
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }
}
