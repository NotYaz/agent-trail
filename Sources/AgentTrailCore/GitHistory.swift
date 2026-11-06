import Foundation

/// A checkout's history as Git keeps it locally: commits on every branch,
/// branch heads, and each working tree's timestamped HEAD reflog. Author
/// names and e-mail addresses are never kept.
public struct GitHistory: Codable, Equatable, Sendable {
    public struct Commit: Codable, Equatable, Sendable {
        public var sha: String
        public var parents: [String]
        /// The tree it records. A squash merge records its branch head's tree.
        public var tree: String
        /// Committer date: when the commit reached this branch.
        public var date: Date
        public var subject: String
        /// `Co-Authored-By` names, without addresses.
        public var coAuthors: [String]
        /// GitHub made the commit: a pull request merged on GitHub. Only the
        /// fact is kept, never the committer's name.
        public var viaGitHub: Bool
        /// The Claude Code cloud session that made it ("session_…"), from its
        /// `Claude-Session` trailer. Cloud sessions leave no local record.
        public var cloudSession: String?

        public init(sha: String, parents: [String], tree: String = "", date: Date, subject: String,
                    coAuthors: [String] = [], viaGitHub: Bool = true, cloudSession: String? = nil) {
            self.sha = sha
            self.parents = parents
            self.tree = tree
            self.date = date
            self.subject = subject
            self.coAuthors = coAuthors
            self.viaGitHub = viaGitHub
            self.cloudSession = cloudSession
        }

        private enum CodingKeys: String, CodingKey { case sha, parents, tree, date, subject, coAuthors, viaGitHub, cloudSession }

        /// Snapshots saved before `viaGitHub` was read decode as GitHub merges, as they were drawn then.
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            sha = try values.decode(String.self, forKey: .sha)
            parents = try values.decode([String].self, forKey: .parents)
            tree = try values.decodeIfPresent(String.self, forKey: .tree) ?? ""
            date = try values.decode(Date.self, forKey: .date)
            subject = try values.decode(String.self, forKey: .subject)
            coAuthors = try values.decodeIfPresent([String].self, forKey: .coAuthors) ?? []
            viaGitHub = try values.decodeIfPresent(Bool.self, forKey: .viaGitHub) ?? true
            cloudSession = try values.decodeIfPresent(String.self, forKey: .cloudSession)
        }

        /// The pull request a commit GitHub made names: a squash's "Title (#18)",
        /// or the first "#N" of a merge commit's title ("Merge pull request #18
        /// from owner/branch"). Elsewhere "(#N)" is an issue reference.
        public var pullRequest: Int? {
            guard viaGitHub else { return nil }
            if parents.count > 1 {
                guard let hash = subject.firstIndex(of: "#") else { return nil }
                let digits = subject[subject.index(after: hash)...].prefix { $0.isNumber }
                return Int(digits).flatMap { $0 > 0 ? $0 : nil }
            }
            guard subject.hasSuffix(")"), let open = subject.range(of: "(#", options: .backwards) else { return nil }
            let digits = subject[open.upperBound..<subject.index(before: subject.endIndex)]
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
            return Int(digits).flatMap { $0 > 0 ? $0 : nil }
        }
    }

    public struct Branch: Codable, Equatable, Sendable {
        /// "main" for a local branch, "origin/main" for a remote-tracking one.
        public var name: String
        public var head: String
        public var isRemote: Bool

        public init(name: String, head: String, isRemote: Bool) {
            self.name = name
            self.head = head
            self.isRemote = isRemote
        }

        /// The branch name without its remote, so "origin/main" is "main".
        public var shortName: String {
            guard isRemote, let slash = name.firstIndex(of: "/") else { return name }
            return String(name[name.index(after: slash)...])
        }
    }

    /// One line of a working tree's HEAD reflog.
    public struct HeadMove: Codable, Equatable, Sendable {
        public enum Kind: Codable, Equatable, Sendable {
            case checkout(from: String, to: String)
            case commit
            /// `commit --amend`: the commit it replaced (`old`) is gone.
            case amend
            /// A merge commit made here.
            case merge
            /// A fast-forward to commits made elsewhere.
            case fastForward
            case pull
            case other
        }

        public var date: Date
        /// The working tree whose HEAD moved.
        public var worktree: String
        public var old: String
        public var new: String
        public var kind: Kind

        public init(date: Date, worktree: String, old: String, new: String, kind: Kind) {
            self.date = date
            self.worktree = worktree
            self.old = old
            self.new = new
            self.kind = kind
        }
    }

    public var checkout: String
    /// Oldest first.
    public var commits: [Commit]
    public var branches: [Branch]
    /// Tag names, so a checkout of a tag is not taken for a branch.
    public var tags: [String]
    /// The branch each working tree has checked out now, from its HEAD file.
    /// A new worktree's reflog starts with a reset, so this names its branch.
    public var worktreeHeads: [String: String]
    /// Oldest first, across every working tree that still exists.
    public var headMoves: [HeadMove]

    public init(checkout: String, commits: [Commit] = [], branches: [Branch] = [], tags: [String] = [],
                headMoves: [HeadMove] = [], worktreeHeads: [String: String] = [:]) {
        self.checkout = checkout
        self.commits = commits
        self.branches = branches
        self.tags = tags
        self.headMoves = headMoves
        self.worktreeHeads = worktreeHeads
    }

    private enum CodingKeys: String, CodingKey { case checkout, commits, branches, tags, headMoves, worktreeHeads }

    /// Snapshots saved before tags were read decode with none.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        checkout = try values.decode(String.self, forKey: .checkout)
        commits = try values.decode([Commit].self, forKey: .commits)
        branches = try values.decode([Branch].self, forKey: .branches)
        tags = try values.decodeIfPresent([String].self, forKey: .tags) ?? []
        headMoves = try values.decode([HeadMove].self, forKey: .headMoves)
        worktreeHeads = try values.decodeIfPresent([String: String].self, forKey: .worktreeHeads) ?? [:]
    }

    /// The branch checked out in `worktree` at `date`. See `GitBranchIndex`;
    /// build one index to answer many questions.
    public func branch(in worktree: String, at date: Date) -> String? {
        GitBranchIndex(self).branch(in: worktree, at: date)
    }

    /// The branch an edit made in `worktree` at `date` landed on. See `GitBranchIndex`.
    public func capturedBranch(in worktree: String, at date: Date, limit: TimeInterval) -> String? {
        GitBranchIndex(self).capturedBranch(in: worktree, at: date, limit: limit)
    }
}

/// Branch questions about one history, answered from indexes built once.
public struct GitBranchIndex: Sendable {
    private struct Move: Sendable {
        let date: Date
        let kind: GitHistory.HeadMove.Kind
        /// A checkout that created its target: same commit, a name no earlier move mentioned.
        let creates: Bool
    }

    private let moves: [String: [Move]]
    private let local: Set<String>
    private let remote: Set<String>
    private let tags: Set<String>
    /// Names a checkout moved away from. Leaving a detached HEAD records its
    /// commit, so these were all branches.
    private let left: Set<String>
    private let created: [String: Date]
    private let createdFrom: [String: String]
    private let refsKnown: Bool
    private let heads: [String: String]

    public init(_ history: GitHistory) {
        local = Set(history.branches.filter { !$0.isRemote }.map(\.name))
        remote = Set(history.branches.filter(\.isRemote).map(\.name))
        tags = Set(history.tags)
        refsKnown = !history.branches.isEmpty
        heads = history.worktreeHeads
        var moves: [String: [Move]] = [:]
        var mentioned = Set<String>()
        var left = Set<String>()
        var created: [String: Date] = [:]
        var createdFrom: [String: String] = [:]
        for move in history.headMoves {
            var creates = false
            if case .checkout(let from, let to) = move.kind {
                creates = move.old == move.new && !mentioned.contains(to)
                if creates, created[to] == nil {
                    created[to] = move.date
                    createdFrom[to] = from
                }
                left.insert(from)
                mentioned.insert(from)
                mentioned.insert(to)
            }
            moves[move.worktree, default: []].append(Move(date: move.date, kind: move.kind, creates: creates))
        }
        self.moves = moves
        self.left = left
        self.created = created
        self.createdFrom = createdFrom
    }

    /// False for what a checkout can name besides a local branch: a commit,
    /// a remote-tracking branch, a tag or an expression such as `HEAD~3`.
    /// A deleted branch still counts when the reflog shows it was one.
    public func isBranchName(_ name: String) -> Bool {
        if name.isEmpty || name == "HEAD" || name.contains(where: { "~^:@{ ".contains($0) }) { return false }
        if local.contains(name) { return true }
        if tags.contains(name) || remote.contains(name) || name.hasPrefix("refs/") || name.hasPrefix("tags/") { return false }
        if name.count >= 4, name.allSatisfy(\.isHexDigit) { return false }
        return !refsKnown || left.contains(name) || created[name] != nil
    }

    /// When `branch` was created by a checkout in any working tree.
    public func creation(of branch: String) -> Date? { created[branch] }

    /// The branch checked out when `branch` was created from it.
    public func creationParent(of branch: String) -> String? {
        createdFrom[branch].flatMap { isBranchName($0) ? $0 : nil }
    }

    /// The branch checked out in `worktree` at `date`, from the reflog's
    /// checkout entries; before the first one, the branch it moved from.
    /// Nil when the reflog records no checkout there, or HEAD was detached.
    public func branch(in worktree: String, at date: Date) -> String? {
        var current: String?
        var first: String?
        for move in moves[worktree] ?? [] {
            guard case .checkout(let from, let to) = move.kind else { continue }
            if first == nil { first = from }
            guard move.date <= date else { break }
            current = to
        }
        // No checkout recorded there: the branch it has out now.
        return (current ?? first ?? heads[worktree]).flatMap { isBranchName($0) ? $0 : nil }
    }

    /// The branch an edit made in `worktree` at `date` landed on. Uncommitted
    /// changes travel with `checkout -b` to a new branch and through pulls, so
    /// it is the branch of the next commit there when that commit follows
    /// within `limit` with only such moves between. Any other move, such as a
    /// checkout of an existing branch or a reset, leaves the branch checked
    /// out at `date`.
    public func capturedBranch(in worktree: String, at date: Date, limit: TimeInterval) -> String? {
        for move in moves[worktree] ?? [] where move.date >= date {
            guard move.date.timeIntervalSince(date) <= limit else { break }
            switch move.kind {
            case .commit, .amend, .merge:
                return branch(in: worktree, at: move.date)
            case .checkout where move.creates, .pull, .fastForward:
                continue
            case .checkout, .other:
                return branch(in: worktree, at: date)
            }
        }
        return branch(in: worktree, at: date)
    }
}

public enum GitHistoryReader {
    /// Reads the history of the checkout at `checkout`. Reflogs are read as
    /// files; commits and branches need a Git executable. Nil when the folder
    /// is not a checkout.
    /// Commits come from every branch and every reflog, so a deleted branch's
    /// commits stay visible while its reflog entries last. `since` bounds the
    /// walk by commit date.
    public static func read(checkout: String, since: Date? = nil, git: URL? = GitExecutable.locate(),
                            commitLimit: Int = 4000, timeout: TimeInterval = 10) -> GitHistory? {
        guard let layout = layout(of: checkout) else { return nil }
        var history = GitHistory(checkout: checkout, headMoves: headMoves(layout), worktreeHeads: worktreeHeads(layout))
        guard let git else {
            // Without Git, branch names and heads still come from the ref files.
            history.branches = diskBranches(common: layout.common)
            return history
        }
        let refs = run(git, ["-C", checkout, "for-each-ref", "--format=%(refname)%00%(objectname)",
                             "refs/heads", "refs/remotes", "refs/tags"], timeout: timeout)
        history.branches = refs.map(parseBranches) ?? []
        history.tags = refs.map(parseTags) ?? []
        var arguments = ["-C", checkout, "log", "--all", "--reflog", "--date-order", "-n", String(commitLimit),
                         "--format=%H%x00%P%x00%T%x00%ct%x00%s%x00%(trailers:key=Co-Authored-By,valueonly,separator=%x1f)%x00%cn"
                            + "%x00%(trailers:key=Claude-Session,valueonly,separator=%x1f)%x1e"]
        if let since { arguments.append("--since=\(Int(since.timeIntervalSince1970))") }
        let log = run(git, arguments, timeout: timeout)
        history.commits = log.map(parseCommits) ?? []
        return history
    }

    /// When the oldest commit with a `Claude-Session` trailer was made, so a
    /// history read can reach back to cloud sessions older than any local
    /// one. Nil when there is none, or the walk outlasts `timeout`.
    public static func firstCloudCommit(checkout: String, git: URL? = GitExecutable.locate(),
                                        timeout: TimeInterval = 3) -> Date? {
        guard let git, layout(of: checkout) != nil else { return nil }
        // The grep only narrows the walk; the trailer itself must name a session.
        let output = run(git, ["-C", checkout, "log", "--all", "--reflog", "--fixed-strings",
                               "--grep=Claude-Session: https://claude.ai/code/session_",
                               "--format=%ct%x00%(trailers:key=Claude-Session,valueonly,separator=%x1f)%x1e"],
                         timeout: timeout)
        return output.flatMap(parseFirstCloudCommit)
    }

    static func parseFirstCloudCommit(_ output: String) -> Date? {
        output.split(separator: "\u{1e}").compactMap { record -> Date? in
            let fields = record.trimmingCharacters(in: .newlines).split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 2, let seconds = TimeInterval(fields[0]), cloudSession(fields[1]) != nil else { return nil }
            return Date(timeIntervalSince1970: seconds)
        }.min()
    }

    // MARK: Reflogs

    /// Where a checkout's Git data lives: the shared directory, and the
    /// working tree whose reflog is `logs/HEAD` there.
    struct Layout: Equatable {
        let common: String
        let mainWorktree: String
    }

    /// `.git` itself; for a linked worktree the directory its `gitdir` file's
    /// `commondir` names; for a submodule or a separate Git directory, the
    /// `gitdir` itself.
    static func layout(of checkout: String) -> Layout? {
        let marker = (checkout as NSString).appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: marker, isDirectory: &isDirectory) else { return nil }
        if isDirectory.boolValue { return Layout(common: marker, mainWorktree: checkout) }
        guard let text = smallText(marker), text.hasPrefix("gitdir: ") else { return nil }
        let reference = text.dropFirst("gitdir: ".count).trimmingCharacters(in: .whitespacesAndNewlines)
        let gitDirectory = resolved(reference, against: checkout)
        guard let common = smallText((gitDirectory as NSString).appendingPathComponent("commondir")) else {
            return Layout(common: gitDirectory, mainWorktree: checkout)
        }
        let path = resolved(common.trimmingCharacters(in: .whitespacesAndNewlines), against: gitDirectory)
        return Layout(common: path, mainWorktree: canonicalPath((path as NSString).deletingLastPathComponent))
    }

    static func commonDirectory(of checkout: String) -> String? {
        layout(of: checkout)?.common
    }

    /// The main working tree's reflog and every linked worktree's that still exists.
    static func headMoves(_ layout: Layout) -> [GitHistory.HeadMove] {
        let common = layout.common
        var moves = parseReflog(at: (common as NSString).appendingPathComponent("logs/HEAD"), worktree: layout.mainWorktree)
        let worktrees = (common as NSString).appendingPathComponent("worktrees")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: worktrees)) ?? [] {
            let directory = (worktrees as NSString).appendingPathComponent(name)
            guard let marker = smallText((directory as NSString).appendingPathComponent("gitdir")) else { continue }
            // Git 2.48 can write this path relative to the administrative folder.
            let file = resolved(marker.trimmingCharacters(in: .whitespacesAndNewlines), against: directory)
            let tree = canonicalPath((file as NSString).deletingLastPathComponent)
            moves += parseReflog(at: (directory as NSString).appendingPathComponent("logs/HEAD"), worktree: tree)
        }
        return moves.sorted { ($0.date, $0.worktree) < ($1.date, $1.worktree) }
    }

    /// Each working tree's checked-out branch, from `ref: refs/heads/<name>` in its HEAD.
    static func worktreeHeads(_ layout: Layout) -> [String: String] {
        func branch(_ headFile: String) -> String? {
            guard let text = smallText(headFile, limit: 4096) else { return nil }
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let prefix = "ref: refs/heads/"
            return line.hasPrefix(prefix) ? String(line.dropFirst(prefix.count)) : nil
        }
        let common = layout.common
        var heads: [String: String] = [:]
        // The main tree's HEAD is in the common directory, unless it is itself a linked worktree.
        if let main = branch((common as NSString).appendingPathComponent("HEAD")) { heads[layout.mainWorktree] = main }
        let worktrees = (common as NSString).appendingPathComponent("worktrees")
        for name in (try? FileManager.default.contentsOfDirectory(atPath: worktrees)) ?? [] {
            let directory = (worktrees as NSString).appendingPathComponent(name)
            guard let marker = smallText((directory as NSString).appendingPathComponent("gitdir")),
                  let head = branch((directory as NSString).appendingPathComponent("HEAD")) else { continue }
            let file = resolved(marker.trimmingCharacters(in: .whitespacesAndNewlines), against: directory)
            heads[canonicalPath((file as NSString).deletingLastPathComponent)] = head
        }
        return heads
    }

    private static func resolved(_ path: String, against base: String) -> String {
        ((path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)) as NSString).standardizingPath
    }

    /// The text of a regular file under `limit` bytes. A pipe or device named
    /// like a Git file could otherwise block the read forever.
    /// Invalid UTF-8, such as a name in another encoding, is repaired rather
    /// than losing the whole file.
    static func smallText(_ path: String, limit: Int = 32 * 1024 * 1024) -> String? {
        var info = stat()
        guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit,
              let data = FileManager.default.contents(atPath: path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Branches from `refs/heads`, `refs/remotes` and `packed-refs`, read as files.
    static func diskBranches(common: String) -> [GitHistory.Branch] {
        var lines: [String] = []
        for root in ["refs/heads", "refs/remotes"] {
            let base = (common as NSString).appendingPathComponent(root)
            guard let enumerator = FileManager.default.enumerator(atPath: base) else { continue }
            for case let relative as String in enumerator {
                guard let text = smallText((base as NSString).appendingPathComponent(relative), limit: 4096) else { continue }
                let sha = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard sha.count >= 40, sha.allSatisfy(\.isHexDigit) else { continue }
                lines.append("\(root)/\(relative)\u{0}\(sha)")
            }
        }
        for line in (smallText((common as NSString).appendingPathComponent("packed-refs")) ?? "").split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard fields.count == 2, fields[0].count >= 40 else { continue }
            lines.append("\(fields[1])\u{0}\(fields[0])")
        }
        var seen = Set<String>()
        return parseBranches(lines.joined(separator: "\n")).filter { seen.insert($0.name).inserted }
    }

    /// `<old> <new> <name> <<email>> <seconds> <zone>\t<message>`; the identity is skipped.
    static func parseReflog(at path: String, worktree: String) -> [GitHistory.HeadMove] {
        guard let text = smallText(path) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            let header = line[..<tab].split(separator: " ")
            guard header.count >= 4, let seconds = TimeInterval(header[header.count - 2]) else { return nil }
            let message = String(line[line.index(after: tab)...])
            return GitHistory.HeadMove(date: Date(timeIntervalSince1970: seconds), worktree: worktree,
                                       old: String(header[0]), new: String(header[1]), kind: kind(of: message))
        }
    }

    static func kind(of message: String) -> GitHistory.HeadMove.Kind {
        let checkout = "checkout: moving from "
        if message.hasPrefix(checkout), let to = message.range(of: " to ", options: .backwards) {
            let from = message[message.index(message.startIndex, offsetBy: checkout.count)..<to.lowerBound]
            return .checkout(from: String(from), to: String(message[to.upperBound...]))
        }
        if message.hasPrefix("commit (merge)") { return .merge }
        if message.hasPrefix("commit (amend)") { return .amend }
        if message.hasPrefix("merge ") { return message.hasSuffix("Fast-forward") ? .fastForward : .merge }
        if message.hasPrefix("commit") { return .commit }
        if message.hasPrefix("pull") { return .pull }
        return .other
    }

    // MARK: Git output

    static func parseBranches(_ output: String) -> [GitHistory.Branch] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count == 2 else { return nil }
            let reference = String(fields[0])
            if reference.hasPrefix("refs/heads/") {
                return GitHistory.Branch(name: String(reference.dropFirst("refs/heads/".count)), head: String(fields[1]),
                                         isRemote: false)
            }
            guard reference.hasPrefix("refs/remotes/"), !reference.hasSuffix("/HEAD") else { return nil }
            return GitHistory.Branch(name: String(reference.dropFirst("refs/remotes/".count)), head: String(fields[1]),
                                     isRemote: true)
        }
    }

    static func parseTags(_ output: String) -> [String] {
        output.split(separator: "\n").compactMap { line in
            let reference = line.split(separator: "\0", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            return reference.hasPrefix("refs/tags/") ? String(reference.dropFirst("refs/tags/".count)) : nil
        }
    }

    static func parseCommits(_ output: String) -> [GitHistory.Commit] {
        output.split(separator: "\u{1e}").compactMap { record in
            let fields = record.trimmingCharacters(in: .newlines).split(separator: "\0", omittingEmptySubsequences: false)
            guard fields.count >= 5, fields[0].count >= 40, let seconds = TimeInterval(fields[3]) else { return nil }
            // The name before "<address>"; a bare address is dropped, never kept.
            let coAuthors = fields.count > 5 ? fields[5].split(separator: "\u{1f}").compactMap { value -> String? in
                let name = value.split(separator: "<", omittingEmptySubsequences: false).first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return name.isEmpty || name.contains("@") ? nil : name
            } : []
            // The committer's name decides only whether GitHub made the commit; it is not kept.
            let viaGitHub = fields.count > 6 && fields[6] == "GitHub"
            return GitHistory.Commit(sha: String(fields[0]), parents: fields[1].split(separator: " ").map(String.init),
                                     tree: String(fields[2]), date: Date(timeIntervalSince1970: seconds),
                                     subject: String(fields[4]), coAuthors: coAuthors, viaGitHub: viaGitHub,
                                     cloudSession: fields.count > 7 ? cloudSession(fields[7]) : nil)
        }.sorted { ($0.date, $0.sha) < ($1.date, $1.sha) }
    }

    /// The session a `Claude-Session` trailer links: "session_…" from
    /// `https://claude.ai/code/session_…`. Any other value is ignored.
    static func cloudSession(_ trailer: Substring) -> String? {
        let prefix = "https://claude.ai/code/"
        for value in trailer.split(separator: "\u{1f}") {
            let link = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard link.hasPrefix(prefix) else { continue }
            let id = link.dropFirst(prefix.count)
            guard id.hasPrefix("session_"), id.count > "session_".count, id.count <= 64,
                  id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }) else { continue }
            return String(id)
        }
        return nil
    }

    /// Runs Git without a terminal, pager, optional locks, file-system
    /// monitor, network access or lazy fetches, and gives up after `timeout`
    /// even if a child of Git keeps the output open. Nil on failure.
    private static func run(_ git: URL, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = git
        process.arguments = ["--no-optional-locks", "-c", "core.fsmonitor=false", "-c", "log.showSignature=false",
                             "-c", "protocol.allow=never", "-c", "core.hooksPath=/dev/null"] + arguments
        process.environment = ["HOME": NSHomeDirectory(), "LC_ALL": "C", "GIT_TERMINAL_PROMPT": "0",
                               "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_LAZY_FETCH": "1", "GIT_ALLOW_PROTOCOL": "none",
                               "GIT_NO_REPLACE_OBJECTS": "1", "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let collected = OutputBox()
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            collected.data = output.fileHandleForReading.readDataToEndOfFile()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            if process.isRunning { process.terminate() }
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: collected.data, as: UTF8.self)
    }

    /// Output handed from the reading thread, which finishes before the semaphore signals.
    private final class OutputBox: @unchecked Sendable {
        var data = Data()
    }
}

public enum GitExecutable {
    /// A real Git executable. `/usr/bin/git` is never used: on a Mac without
    /// the developer tools, that stub asks to install them.
    public static func locate() -> URL? {
        var candidates: [String] = []
        if let developer = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            candidates.append((developer as NSString).appendingPathComponent("usr/bin/git"))
        }
        candidates += ["/Library/Developer/CommandLineTools/usr/bin/git",
                       "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
                       "/opt/homebrew/bin/git", "/usr/local/bin/git"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}
