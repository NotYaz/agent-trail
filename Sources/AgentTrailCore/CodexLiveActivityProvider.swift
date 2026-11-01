import Darwin
import Foundation
import SQLite3

/// Local Codex presence comes from an open thread-writer handle owned by a
/// verified `codex app-server`, never from a leftover lock file or recent edit.
/// The newest native turn projection supplies Working / Idle. Codex's persisted
/// projection does not expose pending approvals or input requests, so an active
/// turn can include those waits; this adapter never invents a Needs input state.
/// All databases are opened read-only and queries retain no messages or tools.
/// A thread's name, branch and parent are read as display details only; the
/// app that started the verified server is its host, and nothing else is guessed.
public final class CodexLiveActivityProvider {
    private let openSessionOwners: (URL) -> [String: Int32]?
    private let serverStartedAt: (Int32) -> Date?
    private let hostBundleIdentifier: (Int32) -> String?
    private let files = FileManager.default

    /// `hostBundleIdentifier` receives only a verified app-server PID and returns
    /// the bundle id of the app that started it, or nil when that is not certain.
    public init(openSessionOwners: ((URL) -> [String: Int32]?)? = nil,
                serverStartedAt: ((Int32) -> Date?)? = nil,
                hostBundleIdentifier: ((Int32) -> String?)? = nil) {
        self.openSessionOwners = openSessionOwners ?? Self.readOpenSessionOwners
        self.serverStartedAt = serverStartedAt ?? Self.readServerStartedAt
        let resolver = HostResolver()
        self.hostBundleIdentifier = hostBundleIdentifier ?? { resolver.bundleIdentifier(owning: $0) }
    }

    public func scan(sources: [AgentSource], now: Date = Date()) -> LiveSnapshot {
        var sessions: [LiveAgentSession] = []
        var notices: [String] = []
        var starts: [Int32: Date] = [:]
        var rejected = Set<Int32>()
        var hosts: [Int32: String?] = [:]
        for source in sources where source.assistant == .codex {
            let home = URL(fileURLWithPath: canonicalPath(source.configDirectory), isDirectory: true)
            let lockDirectory = home.appendingPathComponent("thread-writer-locks", isDirectory: true)
            guard files.fileExists(atPath: lockDirectory.path) else { continue }
            guard let owners = openSessionOwners(lockDirectory) else {
                notices.append("\(source.name): loaded local Codex sessions could not be verified.")
                continue
            }
            guard !owners.isEmpty else { continue }
            guard let stateURL = database(prefix: "state_", home: home),
                  let historyURL = database(prefix: "thread_history_", home: home),
                  let state = CodexLiveDatabase(url: stateURL),
                  let history = CodexLiveDatabase(url: historyURL) else {
                notices.append("\(source.name): the local Codex live projection is unavailable.")
                continue
            }
            var unreadable = 0
            var unknown = 0
            var unverifiedOwner = false
            // A bounded set of loaded sessions; historical rows are never scanned.
            for (id, pid) in owners.sorted(by: { $0.key < $1.key }).prefix(256) {
                guard UUID(uuidString: id) != nil, pid > 0 else { continue }
                if rejected.contains(pid) { unverifiedOwner = true; continue }
                if starts[pid] == nil {
                    guard let start = serverStartedAt(pid), start <= now.addingTimeInterval(5) else {
                        rejected.insert(pid)
                        unverifiedOwner = true
                        continue
                    }
                    starts[pid] = start
                }
                guard let start = starts[pid],
                      let metadata = state.row("SELECT cwd, rollout_path, updated_at FROM threads WHERE id = ? LIMIT 1", id: id),
                      metadata.count == 3,
                      let project = CheckoutPath.absolute(metadata[0]),
                      let rollout = CheckoutPath.absolute(metadata[1]),
                      ["sessions", "archived_sessions"].contains(where: {
                          CheckoutPath.contains(root: home.appendingPathComponent($0).path, path: rollout)
                      }),
                      URL(fileURLWithPath: rollout).lastPathComponent.hasSuffix("-\(id).jsonl") else {
                    unreadable += 1
                    continue
                }
                let row = history.row("SELECT status, started_at, completed_at FROM thread_turns WHERE thread_id = ? ORDER BY rollout_ordinal DESC LIMIT 1", id: id)
                let recorded = row.flatMap { $0.count == 3 ? $0 : nil }
                let began = recorded.flatMap { seconds($0[1]) }
                let ended = recorded.flatMap { seconds($0[2]) }
                let report = ended ?? began ?? seconds(metadata[2])
                guard let report else { unreadable += 1; continue }
                let status: LiveStatus
                if report > now.addingTimeInterval(5)
                    || began.map({ $0 > now.addingTimeInterval(5) }) == true
                    || (began != nil && ended != nil && ended! < began!) {
                    status = .unknown
                } else {
                    switch recorded?[0] {
                    case "inProgress":
                        // A process restarted after this turn began may have
                        // inherited an interrupted projection. Do not call it busy.
                        status = ended == nil && began.map({ $0 >= start.addingTimeInterval(-1) }) == true
                            ? .working : .unknown
                    case "completed", "interrupted", "failed":
                        status = ended != nil ? .idle : .unknown
                    default:
                        status = .unknown
                    }
                }
                if status == .unknown { unknown += 1 }
                let host: String?
                if let known = hosts[pid] { host = known } else {
                    host = hostBundleIdentifier(pid)
                    hosts.updateValue(host, forKey: pid)
                }
                sessions.append(LiveAgentSession(sourceID: source.id, projectPath: project,
                    workspacePath: project, sessionID: id, status: status, updatedAt: report, pid: pid,
                    details: details(state: state, id: id, host: host)))
            }
            if owners.count > 256 { notices.append("\(source.name): only the first 256 loaded Codex sessions are shown.") }
            if unreadable > 0 { notices.append("\(source.name): some loaded Codex sessions had no readable local project projection.") }
            if unknown > 0 { notices.append("\(source.name): some loaded Codex sessions have no verified current turn state.") }
            if unverifiedOwner { notices.append("\(source.name): a local session owner could not be verified as a Codex app-server.") }
        }
        sessions.sort {
            if $0.status != $1.status { return rank($0.status) < rank($1.status) }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        return LiveSnapshot(sessions: sessions, notices: Array(Set(notices)).sorted(), scannedAt: now)
    }

    /// Each column is its own query: an older projection without one keeps the
    /// session and loses only that detail. Column names are fixed literals.
    private func details(state: CodexLiveDatabase, id: String, host: String?) -> LiveSessionDetails {
        func column(_ name: String) -> String? {
            state.row("SELECT \(name) FROM threads WHERE id = ? LIMIT 1", id: id)?.first ?? nil
        }
        return LiveSessionDetails(title: Self.displayTitle(column("name")) ?? Self.displayTitle(column("title")),
            branch: Self.branchName(column("git_branch")), hostBundleID: host,
            parentThreadID: Self.parentThreadID(source: column("source"), threadID: id))
    }

    private func database(prefix: String, home: URL) -> URL? {
        guard let urls = try? files.contentsOfDirectory(at: home, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return nil }
        return urls.compactMap { url -> (URL, Int)? in
            let name = url.deletingPathExtension().lastPathComponent
            guard url.pathExtension == "sqlite", name.hasPrefix(prefix),
                  let version = Int(name.dropFirst(prefix.count)), version > 0 else { return nil }
            return (url, version)
        }.max(by: { $0.1 < $1.1 })?.0
    }

    private func seconds(_ value: String?) -> Date? {
        guard let value, let number = Double(value), number.isFinite, number > 0 else { return nil }
        return Date(timeIntervalSince1970: number)
    }

    private func rank(_ status: LiveStatus) -> Int {
        switch status { case .waiting: return 0; case .working: return 1; case .idle: return 2; case .unknown: return 3 }
    }

    /// lsof observes existing handles without opening, locking, or writing the
    /// assistant's lock files. Exact parent paths prevent cross-profile matches.
    static func parseOpenSessionOwners(_ output: String, directory: URL) -> [String: Int32] {
        let root = canonicalPath(directory.path)
        var currentPID: Int32?
        var owners: [String: Int32] = [:]
        var conflicts = Set<String>()
        for line in output.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            if field == "p" { currentPID = Int32(value) }
            guard field == "n", let pid = currentPID, pid > 0 else { continue }
            let url = URL(fileURLWithPath: value)
            guard url.pathExtension == "lock", canonicalPath(url.deletingLastPathComponent().path) == root,
                  canonicalPath(value) == root + "/" + url.lastPathComponent else { continue }
            let id = url.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: id) != nil, !conflicts.contains(id) else { continue }
            if let previous = owners[id], previous != pid {
                owners.removeValue(forKey: id)
                conflicts.insert(id)
            } else { owners[id] = pid }
        }
        return owners
    }

    private static func readOpenSessionOwners(directory: URL) -> [String: Int32]? {
        guard let output = run("/usr/sbin/lsof", arguments: ["-n", "-P", "-F", "pn", "+d", directory.path],
                               acceptedExitCodes: [0, 1], maximumBytes: 1_048_576) else { return nil }
        return parseOpenSessionOwners(output, directory: directory)
    }

    private static func readServerStartedAt(pid: Int32) -> Date? {
        guard let identity = ProcessIdentity.read(pid: pid),
              URL(fileURLWithPath: identity.executablePath).lastPathComponent == "codex",
              isAppServerArguments(identity.arguments),
              let output = run("/bin/ps", arguments: ["-p", String(pid), "-o", "lstart="],
                               acceptedExitCodes: [0], maximumBytes: 4096) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        let normalized = output.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return formatter.date(from: normalized)
    }

    /// The desktop app places global `-c key=value` overrides before its command.
    /// Consume only documented global options, never search arbitrary prompt or
    /// tool arguments for the string `app-server`.
    static func isAppServerArguments(_ arguments: [String]) -> Bool {
        let valueOptions: Set<String> = ["-c", "--config", "--enable", "--disable", "-p", "--profile"]
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "app-server" { return true }
            if argument == "--strict-config" { index += 1; continue }
            if valueOptions.contains(argument) {
                guard index + 1 < arguments.count, !arguments[index + 1].isEmpty,
                      !arguments[index + 1].hasPrefix("-") else { return false }
                if argument == "-c" || argument == "--config" {
                    guard arguments[index + 1].contains("=") else { return false }
                }
                index += 2
                continue
            }
            if let option = valueOptions.first(where: { $0.hasPrefix("--") && argument.hasPrefix($0 + "=") }) {
                let value = String(argument.dropFirst(option.count + 1))
                guard !value.isEmpty, option != "--config" || value.contains("=") else { return false }
                index += 1
                continue
            }
            if argument.hasPrefix("-c"), argument.count > 2, argument.dropFirst(2).contains("=") {
                index += 1
                continue
            }
            return false
        }
        return false
    }

    /// Codex names a thread briefly; until it does, the `title` column holds the
    /// opening prompt. Either way the result is one short line, kept in memory only.
    static func displayTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let words = value.split(whereSeparator: \.isWhitespace).map { word -> String in
            var kept = ""
            kept.unicodeScalars.append(contentsOf: word.unicodeScalars.filter { $0.properties.generalCategory != .control })
            return kept
        }.filter { !$0.isEmpty }
        let line = words.joined(separator: " ")
        guard !line.isEmpty else { return nil }
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }

    /// Git refuses whitespace and control characters in branch names, so a value
    /// holding them is not a branch. A detached checkout reports HEAD, also not one.
    static func branchName(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty,
              trimmed.utf8.count <= 255, trimmed != "HEAD",
              !trimmed.unicodeScalars.contains(where: {
                  $0.properties.isWhitespace || $0.properties.generalCategory == .control
              }) else { return nil }
        return trimmed
    }

    /// A subagent thread records its parent in the `source` JSON, at
    /// subagent.thread_spawn.parent_thread_id today. Any parent_thread_id key in
    /// the first few object levels is read, and all of them must spell the same
    /// thread UUID, other than this thread. Plain-text sources such as `vscode`
    /// and malformed JSON have no parent.
    static func parentThreadID(source: String?, threadID: String) -> String? {
        guard let source, source.utf8.count <= 8192, let data = source.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var found: [String] = []
        var malformed = false
        var visited = 0
        func visit(_ dictionary: [String: Any], depth: Int) {
            for (key, value) in dictionary {
                visited += 1
                guard visited <= 256 else { return }
                if key == "parent_thread_id" {
                    if let text = value as? String { found.append(text) } else if !(value is NSNull) { malformed = true }
                } else if depth < 4, let child = value as? [String: Any] {
                    visit(child, depth: depth + 1)
                }
            }
        }
        guard let root = object as? [String: Any] else { return nil }
        visit(root, depth: 0)
        guard !malformed, visited <= 256, let parent = found.first, Set(found).count == 1,
              UUID(uuidString: parent) != nil,
              parent.lowercased() != threadID.lowercased() else { return nil }
        return parent
    }

    /// The app that owns an executable: the `X.app` whose Contents/MacOS holds it
    /// and whose Info.plist names it as the bundle executable, widened to the
    /// outermost enclosing app so an editor's nested helper (VS Code runs
    /// extensions in Code Helper (Plugin).app) maps to the editor itself. Only
    /// application folders are considered: reading a plist under Documents or
    /// Downloads from a background poll could raise a privacy prompt.
    static func applicationBundleIdentifier(executablePath: String, homeDirectory: String = NSHomeDirectory(),
                                            infoPlist: (URL) -> [String: Any]?) -> String? {
        let roots = ["/Applications/", "/System/Applications/", homeDirectory + "/Applications/"]
        let components = (executablePath as NSString).pathComponents
        let count = components.count
        guard executablePath.hasPrefix("/"), roots.contains(where: { executablePath.hasPrefix($0) }),
              !components.contains(".."), !components.contains("."),
              count >= 5, components[count - 2] == "MacOS", components[count - 3] == "Contents",
              isApplicationName(components[count - 4]) else { return nil }
        guard let inner = bundleInfo(components, through: count - 4, infoPlist),
              inner["CFBundleExecutable"] as? String == components[count - 1],
              let innerID = inner["CFBundleIdentifier"] as? String, isBundleIdentifier(innerID) else { return nil }
        guard let outer = (1..<(count - 4)).first(where: {
            isApplicationName(components[$0]) && components[$0 + 1] == "Contents"
        }) else { return innerID }
        // The enclosing app is the owner; if it cannot be read, the owner is unknown.
        guard let outerInfo = bundleInfo(components, through: outer, infoPlist),
              let outerID = outerInfo["CFBundleIdentifier"] as? String, isBundleIdentifier(outerID) else { return nil }
        return outerID
    }

    /// The Info.plist of the bundle whose last path component is `components[index]`.
    private static func bundleInfo(_ components: [String], through index: Int,
                                   _ infoPlist: (URL) -> [String: Any]?) -> [String: Any]? {
        let bundle = NSString.path(withComponents: Array(components[...index]))
        return infoPlist(URL(fileURLWithPath: bundle, isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist"))
    }

    private static func isApplicationName(_ component: String) -> Bool {
        component.count > 4 && component.hasSuffix(".app")
    }

    /// Reverse-DNS characters only, as LaunchServices bundle ids use.
    static func isBundleIdentifier(_ value: String) -> Bool {
        (3...255).contains(value.utf8.count) && value.contains(".")
            && !value.hasPrefix(".") && !value.hasSuffix(".") && value.utf8.allSatisfy { byte in
                switch byte {
                case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                     UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"):
                    return true
                default:
                    return false
                }
            }
    }

    private static func readInfoPlist(_ url: URL) -> [String: Any]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 1_048_577), data.count <= 1_048_576 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// Finds the app that started a verified app-server: its parent process, then
    /// the app bundle of that parent's executable. The parent PID is read again
    /// after the executable path, because an exited parent's orphans move to
    /// launchd; an unchanged parent PID proves the path belongs to the same parent.
    private final class HostResolver {
        private var bundles: [String: String] = [:]

        func bundleIdentifier(owning pid: Int32) -> String? {
            guard let parent = ProcessIdentity.parentProcessID(of: pid),
                  let executable = ProcessIdentity.executablePath(of: parent),
                  ProcessIdentity.parentProcessID(of: pid) == parent else { return nil }
            if let known = bundles[executable] { return known }
            guard let identifier = CodexLiveActivityProvider.applicationBundleIdentifier(
                executablePath: executable, infoPlist: CodexLiveActivityProvider.readInfoPlist) else { return nil }
            // Only answers are kept, so an app caught mid-update is read again next poll.
            if bundles.count >= 32 { bundles.removeAll() }
            bundles[executable] = identifier
            return identifier
        }
    }

    private static func run(_ path: String, arguments: [String], acceptedExitCodes: Set<Int32>, maximumBytes: Int) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = ["LC_ALL": "C", "TZ": "UTC", "PATH": "/usr/bin:/bin:/usr/sbin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            let flags = fcntl(descriptor, F_GETFL)
            guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
            try process.run()
            // A wedged system helper must not occupy the live reader forever.
            // This handle belongs only to the lsof / ps child launched above.
            let deadline = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
            defer { try? pipe.fileHandleForReading.close() }
            var output = Data()
            var oversized = false
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            var reachedEOF = false
            while DispatchTime.now().uptimeNanoseconds < deadline {
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                if count > 0 {
                    if output.count + count <= maximumBytes { output.append(contentsOf: bytes[..<count]) }
                    else { oversized = true }
                } else if count == 0 {
                    reachedEOF = true
                    if !process.isRunning { break }
                    _ = Darwin.poll(nil, 0, 10)
                } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    stopOwnHelper(process)
                    return nil
                } else {
                    var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
                    _ = Darwin.poll(&pollDescriptor, 1, 25)
                }
            }
            guard reachedEOF, !process.isRunning else {
                stopOwnHelper(process)
                return nil
            }
            guard !oversized, acceptedExitCodes.contains(process.terminationStatus) else { return nil }
            return String(data: output, encoding: .utf8)
        } catch { return nil }
    }

    private static func stopOwnHelper(_ process: Process) {
        // Never use any session owner's PID here. Only this exact child Process
        // is eligible, and it must still be a direct child of Agent Trail.
        guard process.isRunning, isOwnChild(process.processIdentifier) else { return }
        process.terminate()
        let deadline = DispatchTime.now().uptimeNanoseconds + 200_000_000
        while process.isRunning, DispatchTime.now().uptimeNanoseconds < deadline {
            _ = Darwin.poll(nil, 0, 10)
        }
        if process.isRunning, isOwnChild(process.processIdentifier) {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
    }

    private static func isOwnChild(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var information = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        return sysctl(&mib, u_int(mib.count), &information, &size, nil, 0) == 0
            && size == MemoryLayout<kinfo_proc>.size && information.kp_eproc.e_ppid == getpid()
    }
}

private final class CodexLiveDatabase {
    private var handle: OpaquePointer?

    init?(url: URL) {
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        sqlite3_busy_timeout(handle, 25)
        sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 1_048_576)
        sqlite3_limit(handle, SQLITE_LIMIT_SQL_LENGTH, 8192)
        guard sqlite3_exec(handle, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            handle = nil
            return nil
        }
    }

    deinit { sqlite3_close(handle) }

    func row(_ sql: String, id: String) -> [String?]? {
        var deadline = Date().timeIntervalSinceReferenceDate + 0.05
        return withUnsafeMutablePointer(to: &deadline) { deadlinePointer in
            // Even a malformed or unexpectedly large projection gets a bounded poll.
            sqlite3_progress_handler(handle, 1000, { pointer in
                guard let pointer else { return 1 }
                return Date().timeIntervalSinceReferenceDate > pointer.assumingMemoryBound(to: Double.self).pointee ? 1 : 0
            }, deadlinePointer)
            defer { sqlite3_progress_handler(handle, 0, nil, nil) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return nil }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(statement, 1, id, -1, transient) == SQLITE_OK,
                  sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return (0..<sqlite3_column_count(statement)).map { index in
                guard sqlite3_column_type(statement, index) != SQLITE_NULL,
                      sqlite3_column_bytes(statement, index) <= 8192,
                      let text = sqlite3_column_text(statement, index) else { return nil }
                return String(cString: text)
            }
        }
    }
}
