import Foundation

/// Everything the Map draws for one project, as read at one moment.
public struct MapSnapshot: Codable, Sendable {
    /// A session that reported live status when the snapshot was taken.
    public struct LiveMark: Codable, Hashable, Sendable {
        public var sourceID: String
        public var sessionID: String
        /// A `LiveStatus` raw value.
        public var status: String

        public init(sourceID: String, sessionID: String, status: String) {
            self.sourceID = sourceID
            self.sessionID = sessionID
            self.status = status
        }
    }

    public var projectPath: String
    public var takenAt: Date
    public var sources: [AgentSource]
    public var trails: [SessionTrail]
    public var git: GitHistory?
    public var live: [LiveMark]

    public init(projectPath: String, takenAt: Date, sources: [AgentSource], trails: [SessionTrail],
                git: GitHistory?, live: [LiveMark] = []) {
        self.projectPath = projectPath
        self.takenAt = takenAt
        self.sources = sources
        self.trails = trails
        self.git = git
        self.live = live
    }

    /// The trails of sessions that count on `projectPath` or made an edit there.
    public static func trails(_ trails: [SessionTrail], for projectPath: String) -> [SessionTrail] {
        trails.filter { trail in
            trail.projectPath == projectPath || trail.edits.contains { $0.projectPath == projectPath }
        }
    }
}

/// How far back the Map reaches, in local activity days ending now.
public enum MapRange: String, CaseIterable, Codable, Sendable {
    case today = "Today"
    case week = "7D"
    case month = "30D"
    case all = "All"

    public var title: String {
        switch self {
        case .today: return "Today"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .all: return "All saved history"
        }
    }

    /// The first moment inside the range; nil for all saved history.
    public func start(now: Date, calendar: ActivityCalendar) -> Date? {
        let today = calendar.day(of: now)
        switch self {
        case .today: return calendar.start(of: today)
        case .week: return calendar.start(of: today.adding(days: -6))
        case .month: return calendar.start(of: today.adding(days: -29))
        case .all: return nil
        }
    }

    /// Pauses shorter than this stay on the axis; longer ones fold.
    public var minimumGap: TimeInterval {
        switch self {
        case .today: return 30 * 60
        case .week: return 60 * 60
        case .month, .all: return 3 * 3_600
        }
    }

    /// A session's edits further apart than this are separate runs.
    public var runBreak: TimeInterval {
        switch self {
        case .today: return 20 * 60
        case .week: return 30 * 60
        case .month, .all: return 60 * 60
        }
    }

    /// Active time kept around each edit and commit on the axis.
    public var pad: TimeInterval {
        switch self {
        case .today: return 4 * 60
        case .week: return 8 * 60
        case .month, .all: return 15 * 60
        }
    }
}

/// One project's Map: a lane for each branch its edits landed in, each
/// session's runs of edits on those lanes, and the commits and merges Git
/// recorded, over a time axis whose idle stretches are folded.
public struct ProjectMap: Equatable, Sendable {
    public enum LaneKind: Equatable, Sendable {
        /// The default branch.
        case trunk
        case branch
        /// A Claude worktree whose branch is unknown.
        case folder
    }

    public struct Merge: Equatable, Sendable {
        public enum Match: Equatable, Sendable {
            /// The trunk commit records the branch head's tree.
            case tree
            /// The trunk commit has the branch head as a parent.
            case parent
            /// The trunk commit's subject is a branch commit's, plus " (#N)".
            case subject
        }

        public var date: Date
        public var sha: String
        public var pullRequest: Int?
        public var match: Match
        /// The lane it merged into: the trunk, or an integration branch.
        public var intoLaneID: String

        public init(date: Date, sha: String, pullRequest: Int?, match: Match, intoLaneID: String) {
            self.date = date
            self.sha = sha
            self.pullRequest = pullRequest
            self.match = match
            self.intoLaneID = intoLaneID
        }
    }

    public struct Lane: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var kind: LaneKind
        /// Packed row; the trunk is row 0 and lanes that never overlap share rows.
        public var row: Int
        public var start: Date
        public var end: Date
        /// When the branch left the trunk, from its first checkout in the window.
        public var forkedAt: Date?
        public var merge: Merge?
        /// No branch ref exists for it any more; the reflog or a session still names it.
        public var deleted: Bool
        /// Checked out in the main working tree now.
        public var isHead: Bool
        /// A session reporting live status works on it.
        public var isLive: Bool
        /// It began before the window, so it enters at the left edge.
        public var enteredBeforeWindow: Bool
        public var editCount: Int
        public var delegatedCount: Int
        public var commitCount: Int
        /// The lane it forked from and returns to; nil for the trunk.
        public var parentID: String? = nil
        /// A stream: the branches folded into this row, by title. Empty for one branch.
        public var members: [String] = []
        /// A stream's merges, one per member that merged.
        public var returns: [Merge] = []
        /// The bundle it is one strand of, by id; nil for a branch on a row of its own.
        public var bundle: String? = nil
        /// Its place among its bundle's strands, from the top.
        public var strand: Int = 0

        public var isStream: Bool { !members.isEmpty }
    }

    /// Branches one session worked on side by side, such as a workflow's agents, drawn as
    /// thin strands on one row. Each stays a lane of its own, with its runs and merge.
    public struct Bundle: Identifiable, Equatable, Sendable {
        /// The first strand's lane id.
        public var id: String
        public var title: String
        /// Its lanes in strand order: by start, then id.
        public var laneIDs: [String]
        /// The lane most of its strands merged into, else the trunk; it sits below that lane.
        public var parentID: String
    }

    /// One session's run of edits on one lane. A session that pauses or works on
    /// several branches has several runs, joined by `sessionKey` and numbered by
    /// start; runs on different lanes overlap where it worked on them side by side.
    /// Codex threads spawned by a session in this project fold into its key.
    public struct Span: Identifiable, Equatable, Sendable {
        public var id: String { sessionKey + "\u{0}" + String(index) }
        public var sessionKey: String
        public var index: Int
        public var sourceID: String
        /// The root session: the thread that spawned the others.
        public var sessionID: String
        /// Claude Desktop's CLI ids for that session, which live reports use.
        public var otherIDs: [String]
        public var laneID: String
        public var start: Date
        public var end: Date
        public var direct: [Date]
        public var delegated: [Date]
        /// Spawned threads folded into this session, counted on its first run.
        public var spawnedThreads: Int
        /// The session's live status (working or waiting); only the run with its latest edit carries it.
        public var live: String?
        /// Stacking position inside the lane where sessions overlap, 0…2.
        public var slot: Int
        /// Further runs stacked into the last slot.
        public var overflow: Int

        public var editCount: Int { direct.count + delegated.count }
        public var edits: [Date] { (direct + delegated).sorted() }
    }

    public struct Marker: Identifiable, Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case commit
            /// A commit on the trunk that names a pull request, merged by squash.
            case squash
            /// A commit with two or more parents.
            case merge
        }

        public var id: String { sha }
        public var sha: String
        public var laneID: String
        public var date: Date
        public var kind: Kind
        public var subject: String
        public var pullRequest: Int?
        public var coAuthors: [String]
        /// On the trunk: the lane this commit merged, when it is drawn.
        public var mergedLaneID: String?
        /// On the trunk: the branch it merged, when no session edited that branch.
        public var quietBranch: String?
        /// The Claude Code cloud session that made it, from its `Claude-Session` trailer.
        public var cloudSession: String? = nil

        /// Where a branch landed on the trunk: a pull request or a merge commit.
        public var isBead: Bool { kind != .commit || mergedLaneID != nil || quietBranch != nil }
    }

    public var projectPath: String
    public var range: MapRange
    public var now: Date
    public var lanes: [Lane]
    public var spans: [Span]
    public var markers: [Marker]
    public var axis: TimeAxis
    /// Sessions active in the window, spawned threads included, as Projects counts them.
    public var sessionCount: Int
    /// Cloud sessions with a commit drawn in the window; not in `sessionCount`.
    public var cloudSessionCount: Int = 0
    /// Edits made outside this project by its sessions; not drawn or counted.
    public var outsideEdits: Int
    public var isGitCheckout: Bool
    public var hasCommits: Bool
    /// The repository's first commit, when it falls inside the history read;
    /// work before it predates Git.
    public var rootCommitDate: Date?
    /// Branch lanes before folding into streams; nil when nothing was folded.
    public var unfoldedBranchCount: Int? = nil
    /// Branches drawn as strands of one row; empty unless the build groups branches.
    public var bundles: [Bundle] = []

    public var rowCount: Int { Set(lanes.map(\.row)).count }
    public func bundle(_ id: String) -> Bundle? { bundles.first { $0.id == id } }
    public var editCount: Int { spans.reduce(0) { $0 + $1.editCount } }
    public var quietMergeCount: Int { markers.filter { $0.quietBranch != nil }.count }
    public var mergeCount: Int { markers.filter { $0.laneID == trunkID && $0.isBead }.count }
    public var trunkID: String { lanes.first { $0.kind == .trunk }?.id ?? "" }

    public func lane(_ id: String) -> Lane? { lanes.first { $0.id == id } }

    /// Claude Code sessions that ran on claude.ai. They leave no local record,
    /// so their runs come from commits with a `Claude-Session` trailer.
    public static let cloudSourceID = "claude-cloud"
    public static let cloudSource = AgentSource(id: cloudSourceID, name: "Claude · Cloud", configDirectory: "")

    /// The profiles that name and color this map's sessions: `sources`, and
    /// the cloud last, so configured profiles keep their colors.
    public func sources(_ sources: [AgentSource]) -> [AgentSource] {
        guard spans.contains(where: { $0.sourceID == Self.cloudSourceID }),
              !sources.contains(where: { $0.id == Self.cloudSourceID }) else { return sources }
        return sources + [Self.cloudSource]
    }

    /// The claude.ai page of a cloud session's run; nil for any other run.
    public static func cloudURL(_ span: Span) -> URL? {
        guard span.sourceID == cloudSourceID else { return nil }
        return URL(string: "https://claude.ai/code/" + span.sessionID)
    }
}

/// Maps dates to 0…1 with every idle stretch folded to the same narrow width,
/// so bursts of work get the room and a quiet night does not.
public struct TimeAxis: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public var start: Date
        public var end: Date
        public var isGap: Bool
        public var lower: Double
        public var upper: Double

        public var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    public var segments: [Segment]

    public var start: Date { segments.first?.start ?? .distantPast }
    public var end: Date { segments.last?.end ?? .distantPast }
    public var gaps: [Segment] { segments.filter(\.isGap) }

    /// `active` intervals are merged; stretches between them longer than
    /// `minimumGap` fold to `gapWidth` each (shared out when there are many).
    /// Active stretches keep `floor` each and share the rest by duration,
    /// blended with their share of `marks` (edits), so a dense burst is not
    /// squeezed by a long lull.
    public init(active intervals: [ClosedRange<Date>], marks: [Date] = [], minimumGap: TimeInterval = 60 * 60,
                gapWidth: Double = 0.012, maximumGapShare: Double = 0.16, floor: Double = 0.006,
                markWeight: Double = 0.4) {
        var merged: [ClosedRange<Date>] = []
        for interval in intervals.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, interval.lowerBound.timeIntervalSince(last.upperBound) <= minimumGap {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, interval.upperBound)
            } else {
                merged.append(interval)
            }
        }
        guard !merged.isEmpty else {
            segments = []
            return
        }
        let gapCount = merged.count - 1
        let width = gapCount == 0 ? 0 : min(gapWidth, maximumGapShare / Double(gapCount))
        let activeSeconds = merged.reduce(0) { $0 + $1.upperBound.timeIntervalSince($1.lowerBound) }
        var markCounts = Array(repeating: 0, count: merged.count)
        var cursor = 0
        for mark in marks.sorted() {
            while cursor < merged.count, merged[cursor].upperBound < mark { cursor += 1 }
            guard cursor < merged.count else { break }
            if merged[cursor].contains(mark) { markCounts[cursor] += 1 }
        }
        let totalMarks = markCounts.reduce(0, +)
        let blend = totalMarks > 0 ? min(1, max(0, markWeight)) : 0
        let floorShare = min(floor, max(0, 1 - width * Double(gapCount)) / Double(merged.count))
        let activeShare = max(0, 1 - width * Double(gapCount) - floorShare * Double(merged.count))
        var position = 0.0
        var segments: [Segment] = []
        for (index, interval) in merged.enumerated() {
            if index > 0 {
                let previous = merged[index - 1].upperBound
                segments.append(Segment(start: previous, end: interval.lowerBound, isGap: true,
                                        lower: position, upper: position + width))
                position += width
            }
            // One instant with nothing else on the axis takes the whole width.
            let duration = activeSeconds > 0 ? interval.upperBound.timeIntervalSince(interval.lowerBound) / activeSeconds
                : 1 / Double(merged.count)
            let density = totalMarks > 0 ? Double(markCounts[index]) / Double(totalMarks) : 0
            let share = floorShare + activeShare * ((1 - blend) * duration + blend * density)
            segments.append(Segment(start: interval.lowerBound, end: interval.upperBound, isGap: false,
                                    lower: position, upper: min(1, position + share)))
            position += share
        }
        self.segments = segments
    }

    /// 0…1; dates outside the axis clamp to its ends.
    public func position(of date: Date) -> Double {
        guard let first = segments.first, let last = segments.last else { return 0 }
        if date <= first.start { return first.lower }
        if date >= last.end { return last.upper }
        // The first segment that ends at or after `date`.
        var low = 0
        var high = segments.count - 1
        while low < high {
            let middle = (low + high) / 2
            if segments[middle].end < date { low = middle + 1 } else { high = middle }
        }
        let segment = segments[low]
        let length = segment.duration
        guard length > 0 else { return segment.lower }
        return segment.lower + (segment.upper - segment.lower) * date.timeIntervalSince(segment.start) / length
    }

    /// The activity-day starts (05:00 local by default) inside the axis.
    public func dayStarts(calendar: ActivityCalendar) -> [Date] {
        guard !segments.isEmpty else { return [] }
        var day = calendar.day(of: start).adding(days: 1)
        var starts: [Date] = []
        while starts.count < 400 {
            let date = calendar.start(of: day)
            guard date < end else { break }
            starts.append(date)
            day = day.adding(days: 1)
        }
        return starts
    }
}

extension ProjectMap {
    /// The longest an edit waits for the commit that carries it to its branch.
    static let carryLimit: TimeInterval = 12 * 3_600
    static let maximumSlots = 3

    /// Builds the Map of `snapshot.projectPath` over `range`. Pure: the same
    /// snapshot, range, calendar and `now` give the same map. `plotWidth` is
    /// the width rows are packed for, so lane labels fit.
    /// Past `collapseAbove` branch lanes, related branches fold into streams; nil never folds.
    public static func build(_ snapshot: MapSnapshot, range: MapRange = .week, calendar: ActivityCalendar = .current,
                             now: Date? = nil, plotWidth: Double = 528, collapseAbove: Int? = nil) -> ProjectMap {
        let now = now ?? snapshot.takenAt
        let project = snapshot.projectPath
        let git = snapshot.git ?? GitHistory(checkout: project)
        let index = GitBranchIndex(git)
        let trunk = trunkName(git, index: index)
        let since = range.start(now: now, calendar: calendar)
        let floor = since ?? .distantPast
        let liveByID = Dictionary(snapshot.live.map { ($0.sourceID + "\u{0}" + $0.sessionID, $0.status) },
                                  uniquingKeysWith: { first, _ in first })
        let trails = MapSnapshot.trails(snapshot.trails, for: project)
        let trailIDs = Set(trails.map { $0.sourceID + "\u{0}" + $0.sessionID })

        // Session keys: a spawned thread whose parent is here folds into it.
        func key(of trail: SessionTrail) -> String {
            if let parent = trail.parentSessionID, trailIDs.contains(trail.sourceID + "\u{0}" + parent) {
                return trail.sourceID + "\u{0}" + parent
            }
            return trail.sourceID + "\u{0}" + trail.sessionID
        }
        func liveStatus(_ trail: SessionTrail) -> String? {
            ([trail.sessionID] + trail.otherIDs).lazy
                .compactMap { liveByID[trail.sourceID + "\u{0}" + $0] }
                .first { $0 == LiveStatus.working.rawValue || $0 == LiveStatus.waiting.rawValue }
        }
        // Folders whose branch a session recorded, across every session.
        var recordedBranch: [String: String] = [:]
        for trail in trails {
            for written in trail.writtenBranches where written.workspacePath != project {
                recordedBranch[written.workspacePath] = written.branch
            }
        }
        let knownNames = Set(git.branches.map(\.shortName)).union(git.headMoves.compactMap { move -> String? in
            if case .checkout(_, let to) = move.kind { return to }
            return nil
        }).sorted()
        // Linked worktrees kept inside the checkout, deepest first; Claude's
        // `.claude/worktrees` are recognised even after they are removed.
        let worktrees = Set(git.headMoves.map(\.worktree))
            .filter { $0 != project && CheckoutPath.contains(root: project, path: $0) }
            .sorted { $0.count > $1.count }

        func laneID(branch: String) -> String { "branch:" + branch }
        var laneInfo: [String: (title: String, kind: LaneKind)] = [laneID(branch: trunk): (trunk, .trunk)]
        func branchLane(_ branch: String) -> String {
            let id = laneID(branch: branch)
            if laneInfo[id] == nil { laneInfo[id] = (branch, branch == trunk ? .trunk : .branch) }
            return id
        }

        /// The working folder an edit was made in: a linked worktree, else the checkout.
        func folder(of edit: TrailEdit) -> String {
            claudeWorktree(edit.workspacePath)
                ?? worktrees.first { CheckoutPath.contains(root: $0, path: edit.workspacePath) } ?? project
        }

        func lane(for edit: TrailEdit, trail: SessionTrail) -> String {
            let path = edit.workspacePath
            guard let worktree = claudeWorktree(path) ?? worktrees.first(where: { CheckoutPath.contains(root: $0, path: path) })
            else {
                return branchLane(index.capturedBranch(in: project, at: edit.date, limit: carryLimit) ?? trunk)
            }
            let name = (worktree as NSString).lastPathComponent
            func named(_ candidates: [String]) -> String? { folderBranch(name, among: candidates) }
            let branch = trail.writtenBranches.last { $0.workspacePath == worktree }?.branch
                ?? index.capturedBranch(in: worktree, at: edit.date, limit: carryLimit)
                ?? recordedBranch[worktree]
                // A branch named for this worktree: the session's own first, then any Git knows.
                ?? named(trail.writtenBranches.map(\.branch))
                ?? named(knownNames)
            if let branch { return branchLane(branch) }
            let id = "folder:" + worktree
            laneInfo[id] = ("Worktree · " + name, .folder)
            return id
        }

        // Runs: each session's edits in this project, one run per lane until it pauses there.
        struct Pending {
            var trail: SessionTrail
            var edits: [(date: Date, lane: String, folder: String, delegated: Bool)] = []
            /// Started in this project, rather than reaching into it from another.
            var based = false
        }
        var outsideEdits = 0
        var byKey: [String: Pending] = [:]
        var keyOrder: [String] = []
        var spawned: [String: Int] = [:]
        var liveByKey: [String: String] = [:]
        var activeSessions = 0
        for trail in trails {
            let sessionKey = key(of: trail)
            let isChild = sessionKey != trail.sourceID + "\u{0}" + trail.sessionID
            let based = trail.projectPath == project
            let here = trail.edits.filter { $0.projectPath == project }
            outsideEdits += trail.edits.count - here.count
            // A session based elsewhere counts here only for its edits here, and
            // is live here only while it is still editing here.
            let inWindow = based ? trail.latestActivity >= floor || here.contains { $0.date >= floor }
                : here.contains { $0.date >= floor }
            var live = liveStatus(trail)
            if !based, !here.contains(where: { now.timeIntervalSince($0.date) <= range.runBreak }) { live = nil }
            if inWindow || live != nil { activeSessions += 1 }
            if let live { liveByKey[sessionKey] = liveByKey[sessionKey] ?? live }
            if isChild { spawned[sessionKey, default: 0] += 1 }
            if byKey[sessionKey] == nil {
                keyOrder.append(sessionKey)
                byKey[sessionKey] = Pending(trail: trail)
            }
            // The root's own trail names the run, when it is here.
            if !isChild { byKey[sessionKey]?.trail = trail }
            if based { byKey[sessionKey]?.based = true }
            for edit in here where edit.date >= floor {
                byKey[sessionKey]?.edits.append((edit.date, lane(for: edit, trail: trail), folder(of: edit), edit.delegated || isChild))
            }
        }

        var spans: [Span] = []
        for sessionKey in keyOrder {
            guard let pending = byKey[sessionKey] else { continue }
            let trail = pending.trail
            let live = liveByKey[sessionKey]
            let edits = pending.edits.sorted { ($0.date, $0.lane) < ($1.date, $1.lane) }
            // An edit joins its lane's open run, so a session working on several branches at
            // once, such as a workflow's agents in worktrees, keeps one run on each rather than
            // a new one at every switch. A folder holds one branch at a time, so a checkout in
            // it ends the run on the branch it left. Runs are made in the order they start.
            var runs: [Span] = []
            var open: [String: Int] = [:]
            var fed: [String: String] = [:]
            for edit in edits {
                if let left = fed[edit.folder], left != edit.lane { open[left] = nil }
                fed[edit.folder] = edit.lane
                if let position = open[edit.lane], edit.date.timeIntervalSince(runs[position].end) <= range.runBreak {
                    runs[position].end = edit.date
                    if edit.delegated { runs[position].delegated.append(edit.date) } else { runs[position].direct.append(edit.date) }
                } else {
                    open[edit.lane] = runs.count
                    runs.append(Span(sessionKey: sessionKey, index: runs.count, sourceID: trail.sourceID,
                                     sessionID: trail.sessionID, otherIDs: trail.otherIDs, laneID: edit.lane,
                                     start: edit.date, end: edit.date,
                                     direct: edit.delegated ? [] : [edit.date], delegated: edit.delegated ? [edit.date] : [],
                                     spawnedThreads: 0, live: nil, slot: 0, overflow: 0))
                }
            }
            if runs.isEmpty {
                // A session without edits here is drawn only while it works, and
                // only when it was started here.
                guard live != nil, pending.based else { continue }
                // One that began before the range shows only where it is now.
                let start = trail.createdAt >= floor ? trail.createdAt : now
                let written = trail.writtenBranches.last { CheckoutPath.contains(root: project, path: $0.workspacePath) }
                let branch = written?.branch ?? index.branch(in: project, at: now) ?? trunk
                runs.append(Span(sessionKey: sessionKey, index: 0, sourceID: trail.sourceID, sessionID: trail.sessionID,
                                 otherIDs: trail.otherIDs, laneID: branchLane(branch), start: start, end: start,
                                 direct: [], delegated: [], spawnedThreads: 0, live: nil, slot: 0, overflow: 0))
            } else {
                // The session's start and last activity, when they are close to its edits.
                if trail.createdAt < runs[0].start, runs[0].start.timeIntervalSince(trail.createdAt) <= range.runBreak {
                    runs[0].start = max(trail.createdAt, floor)
                }
                let last = latestRun(runs)
                if trail.latestActivity > runs[last].end,
                   trail.latestActivity.timeIntervalSince(runs[last].end) <= range.runBreak {
                    runs[last].end = min(trail.latestActivity, now)
                }
            }
            runs[0].spawnedThreads = spawned[sessionKey] ?? 0
            // The bar ends at the last edit; the view draws a thread on to now.
            if let live { runs[latestRun(runs)].live = live }
            spans += runs
        }

        // Commits: the branch each was made on, from the reflog where it was
        // made locally, otherwise from first-parent chains of branch heads.
        let bySHA = Dictionary(git.commits.map { ($0.sha, $0) }, uniquingKeysWith: { first, _ in first })
        var commitBranch: [String: String] = [:]
        // A fast-forward only moves the branch; it makes no commit there.
        for move in git.headMoves where [.commit, .amend, .merge].contains(move.kind) {
            guard bySHA[move.new] != nil, let branch = index.branch(in: move.worktree, at: move.date) else { continue }
            commitBranch[move.new] = branch
        }
        let heads = git.branches.sorted { lhs, rhs in
            // The trunk claims its chain first; then local branches before their remote copies.
            let left = (lhs.shortName == trunk ? 0 : 1, lhs.isRemote ? 1 : 0, lhs.name)
            let right = (rhs.shortName == trunk ? 0 : 1, rhs.isRemote ? 1 : 0, rhs.name)
            return left < right
        }
        for head in heads {
            var sha: String? = head.head
            var steps = 0
            let isTrunk = head.shortName == trunk
            // A branch claims its first-parent chain up to another branch's
            // commit. The trunk walks its whole chain and skips commits the
            // reflog gave a branch merged into it by fast-forward.
            while let current = sha, let commit = bySHA[current], steps < 10_000 {
                if let owner = commitBranch[current], owner != head.shortName {
                    guard isTrunk else { break }
                } else {
                    commitBranch[current] = head.shortName
                }
                sha = commit.parents.first
                steps += 1
            }
        }
        // Commits no branch reaches any more are left out while their branch
        // exists (rebased away), and amended ones always.
        var reachable = Set<String>()
        var stack = git.branches.map(\.head)
        while let sha = stack.popLast() {
            guard reachable.insert(sha).inserted, let commit = bySHA[sha] else { continue }
            stack += commit.parents
        }
        let amended = Set(git.headMoves.filter { $0.kind == .amend }.map(\.old)).subtracting(reachable)
        let refNames = Set(git.branches.map(\.shortName))

        // The window: the range's start, or for all history the first session
        // or commit that was read.
        let earliest = [spans.map(\.start).min(), git.commits.first?.date].compactMap { $0 }.min()
            ?? now.addingTimeInterval(-86_400)
        let windowStart = since ?? earliest.addingTimeInterval(-range.pad)
        var markers: [Marker] = []
        for commit in git.commits where commit.date >= windowStart && commit.date <= now {
            guard let branch = commitBranch[commit.sha], !amended.contains(commit.sha) else { continue }
            if !reachable.contains(commit.sha) && refNames.contains(branch) { continue }
            let kind: Marker.Kind = commit.parents.count > 1 ? .merge
                : (branch == trunk && commit.pullRequest != nil ? .squash : .commit)
            markers.append(Marker(sha: commit.sha, laneID: branchLane(branch), date: commit.date, kind: kind,
                                  subject: commit.subject, pullRequest: commit.pullRequest, coAuthors: commit.coAuthors,
                                  mergedLaneID: nil, quietBranch: nil, cloudSession: commit.cloudSession))
        }
        markers.sort { ($0.date, $0.sha) < ($1.date, $1.sha) }

        // Cloud sessions: a run on each lane of their commits, until they paused
        // or moved on. Commits are not edits, so the runs count none. A commit GitHub
        // made marks when a pull request merged, not when the session worked.
        var cloudSpans: [Span] = []
        var openCloudRun: [String: Int] = [:]
        var cloudRunCount: [String: Int] = [:]
        var cloudLane: [String: String] = [:]
        for marker in markers {
            guard let session = marker.cloudSession, bySHA[marker.sha]?.viaGitHub == false else { continue }
            let sessionKey = cloudSourceID + "\u{0}" + session
            let open = sessionKey + "\u{0}" + marker.laneID
            // A cloud session works in one checkout, so moving to another branch ends the run it left.
            if let left = cloudLane[sessionKey], left != marker.laneID { openCloudRun[sessionKey + "\u{0}" + left] = nil }
            cloudLane[sessionKey] = marker.laneID
            if let position = openCloudRun[open], marker.date.timeIntervalSince(cloudSpans[position].end) <= range.runBreak {
                cloudSpans[position].end = marker.date
                continue
            }
            openCloudRun[open] = cloudSpans.count
            cloudSpans.append(Span(sessionKey: sessionKey, index: cloudRunCount[sessionKey, default: 0], sourceID: cloudSourceID,
                                   sessionID: session, otherIDs: [], laneID: marker.laneID, start: marker.date, end: marker.date,
                                   direct: [], delegated: [], spawnedThreads: 0, live: nil, slot: 0, overflow: 0))
            cloudRunCount[sessionKey, default: 0] += 1
        }
        spans += cloudSpans
        let cloudLanes = Set(cloudSpans.map(\.laneID))

        // Lanes, with their fork from the reflog.
        let trunkLane = laneID(branch: trunk)
        let headBranch = index.branch(in: project, at: now)
        let liveLanes = Set(spans.filter { $0.live != nil }.map(\.laneID))
        var lanes: [Lane] = []
        for (id, info) in laneInfo.sorted(by: { $0.key < $1.key }) {
            let laneSpans = spans.filter { $0.laneID == id }
            let laneMarkers = markers.filter { $0.laneID == id }
            guard id == trunkLane || !laneSpans.isEmpty || !laneMarkers.isEmpty else { continue }
            let dates = laneSpans.flatMap { [$0.start, $0.end] } + laneMarkers.map(\.date)
            var lane = Lane(id: id, title: info.title, kind: info.kind, row: 0, start: dates.min() ?? windowStart,
                            end: dates.max() ?? now, forkedAt: nil, merge: nil,
                            deleted: info.kind == .branch && !git.branches.isEmpty && !refNames.contains(info.title),
                            isHead: info.kind != .folder && info.title == headBranch,
                            isLive: liveLanes.contains(id), enteredBeforeWindow: false,
                            editCount: laneSpans.reduce(0) { $0 + $1.editCount },
                            delegatedCount: laneSpans.reduce(0) { $0 + $1.delegated.count },
                            commitCount: laneMarkers.count)
            if info.kind == .branch, let created = index.creation(of: info.title) {
                // Only the checkout that created the branch is its fork, and not
                // after its first commit. Edits may come first: they travel with it.
                let latestFork = (laneMarkers.first?.date ?? dates.max() ?? now).addingTimeInterval(1)
                if created >= windowStart && created <= latestFork {
                    lane.forkedAt = created
                    lane.start = min(lane.start, created)
                }
            }
            lanes.append(lane)
        }

        // Merges, assigned across all lanes at once: a merge commit on any
        // lane that has the branch's commit as a later parent; then trunk
        // commits recording the branch head's tree; then subject matches.
        let trunkIndices = markers.indices.filter { markers[$0].laneID == trunkLane }
        struct Candidate {
            let lane: Int
            let after: Date
            let shas: Set<String>
            let heads: Set<String>
            let trees: Set<String>
            let headSubject: String?
            let subjects: Set<String>
        }
        var candidates: [Candidate] = []
        for (position, lane) in lanes.enumerated() where lane.kind != .trunk {
            let laneMarkers = markers.filter { $0.laneID == lane.id }
            let parentsOnLane = Set(laneMarkers.flatMap { bySHA[$0.sha]?.parents ?? [] })
            // Every ref head on the lane (local and remote may differ), else the
            // tip of its chain; commits in the same second sort in no useful order.
            let refHeads = Set(git.branches.filter { $0.shortName == lane.title }.map(\.head))
            var heads = laneMarkers.filter { refHeads.contains($0.sha) }
            if heads.isEmpty, let tip = laneMarkers.last(where: { !parentsOnLane.contains($0.sha) }) ?? laneMarkers.last {
                heads = [tip]
            }
            guard !heads.isEmpty else { continue }
            let newest = heads.max { $0.date < $1.date }!
            candidates.append(Candidate(lane: position, after: heads.map(\.date).min()!, shas: Set(laneMarkers.map(\.sha)),
                                        heads: Set(heads.map(\.sha)), trees: Set(heads.compactMap { bySHA[$0.sha]?.tree }),
                                        headSubject: bySHA[newest.sha]?.subject,
                                        subjects: Set(laneMarkers.compactMap { bySHA[$0.sha]?.subject })))
        }
        candidates.sort { lanes[$0.lane].start < lanes[$1.lane].start }
        var claimed = Set<Int>()
        func land(_ candidate: Candidate, at markerIndex: Int, match: Merge.Match) {
            let marker = markers[markerIndex]
            lanes[candidate.lane].merge = Merge(date: marker.date, sha: marker.sha, pullRequest: marker.pullRequest,
                                                match: match, intoLaneID: marker.laneID)
            lanes[candidate.lane].end = max(lanes[candidate.lane].end, marker.date)
            if marker.laneID == trunkLane { markers[markerIndex].mergedLaneID = lanes[candidate.lane].id }
            claimed.insert(markerIndex)
        }
        for candidate in candidates {
            let laneID = lanes[candidate.lane].id
            let match = markers.indices.first { index in
                guard !claimed.contains(index), markers[index].laneID != laneID, markers[index].date >= candidate.after,
                      let commit = bySHA[markers[index].sha], commit.parents.count > 1 else { return false }
                return !candidate.shas.isDisjoint(with: commit.parents.dropFirst())
            }
            if let match { land(candidate, at: match, match: .parent) }
        }
        for candidate in candidates where lanes[candidate.lane].merge == nil {
            let match = trunkIndices.first { index in
                guard !claimed.contains(index), markers[index].date >= candidate.after,
                      let commit = bySHA[markers[index].sha] else { return false }
                return candidate.trees.contains(commit.tree)
            }
            if let match { land(candidate, at: match, match: .tree) }
        }
        func strippedSubject(_ marker: Marker) -> String? {
            guard let number = marker.pullRequest else { return nil }
            let suffix = " (#\(number))"
            return marker.subject.hasSuffix(suffix) ? String(marker.subject.dropLast(suffix.count)) : nil
        }
        for pass in 0..<2 {
            for candidate in candidates where lanes[candidate.lane].merge == nil {
                let match = trunkIndices.first { index in
                    guard !claimed.contains(index), markers[index].date >= candidate.after,
                          let subject = strippedSubject(markers[index]) else { return false }
                    return pass == 0 ? subject == candidate.headSubject : candidate.subjects.contains(subject)
                }
                if let match { land(candidate, at: match, match: .subject) }
            }
        }
        let laneIDs = Set(lanes.map(\.id))
        for position in lanes.indices where lanes[position].kind != .trunk {
            // A branch returns to where it merged; else it came from where it was created.
            let from = index.creationParent(of: lanes[position].title).map(laneID(branch:))
            lanes[position].parentID = lanes[position].merge?.intoLaneID
                ?? from.flatMap { laneIDs.contains($0) && $0 != lanes[position].id ? $0 : nil } ?? trunkLane
        }
        for position in lanes.indices {
            if lanes[position].merge == nil && (lanes[position].isLive || lanes[position].isHead) { lanes[position].end = now }
            if lanes[position].start < windowStart {
                lanes[position].start = windowStart
                lanes[position].enteredBeforeWindow = true
            }
            if lanes[position].id == trunkLane {
                lanes[position].start = windowStart
                lanes[position].end = now
            }
        }

        // A branch merged into the trunk that no session edited is a quiet bead there, not a lane.
        // An integration branch with branches merged into it stays a lane, and
        // so does a cloud session's branch.
        let parents = Set(lanes.compactMap { $0.merge?.intoLaneID })
        let quiet = Set(lanes.filter {
            $0.kind == .branch && $0.editCount == 0 && $0.merge?.intoLaneID == trunkLane && !$0.isLive
                && !parents.contains($0.id) && !cloudLanes.contains($0.id)
        }.map(\.id))
        for position in markers.indices {
            if let merged = markers[position].mergedLaneID, quiet.contains(merged) {
                markers[position].quietBranch = laneInfo[merged]?.title
                markers[position].mergedLaneID = nil
            }
        }
        markers.removeAll { quiet.contains($0.laneID) }
        lanes.removeAll { quiet.contains($0.id) }

        // Bundles: wherever the build groups branches, those one session worked on side by
        // side share a row as strands.
        var bundles: [Bundle] = []
        func applyBundles() {
            let strands = Dictionary(uniqueKeysWithValues: bundles.flatMap { bundle in
                bundle.laneIDs.enumerated().map { ($0.element, (bundle.id, $0.offset)) }
            })
            for position in lanes.indices {
                lanes[position].bundle = strands[lanes[position].id]?.0
                lanes[position].strand = strands[lanes[position].id]?.1 ?? 0
            }
        }
        if collapseAbove != nil {
            bundles = Self.bundles(spans, lanes: lanes, trunkID: trunkLane)
            applyBundles()
        }

        // Streams: past `collapseAbove` rows, branches that merged into the same
        // integration branch, or share a prefix or a workflow run, share one row.
        // A bundle is one row, and its strands never fold into a stream.
        var unfolded: Int?
        let rows = lanes.filter { $0.kind != .trunk && ($0.bundle == nil || $0.bundle == $0.id) }.count
        if let collapseAbove, rows > collapseAbove {
            unfolded = lanes.count - 1
            var root: [String: String] = [:]
            let stranded = Set(lanes.filter { $0.bundle != nil }.map(\.id))
            func rootOf(_ id: String) -> String {
                var current = id
                var seen = Set<String>()
                while let parent = lanes.first(where: { $0.id == current })?.parentID, parent != trunkLane,
                      !stranded.contains(parent), seen.insert(current).inserted {
                    current = parent
                }
                return current
            }
            for lane in lanes where lane.kind != .trunk && lane.bundle == nil { root[lane.id] = rootOf(lane.id) }
            // Lanes at the trunk with no integration parent group by prefix or
            // workflow run, joining a family whose integration branch shares it.
            // A worktree folder prefix ("wa-") joins its branches' ("wave-a/").
            let tops = lanes.filter { $0.kind != .trunk && $0.bundle == nil && root[$0.id] == $0.id }
            let families = Set(lanes.compactMap { lane in root[lane.id].flatMap { $0 != lane.id ? $0 : nil } })
            let branchPrefixes = Set(tops.compactMap { streamPrefix($0.title) }.filter { $0.hasSuffix("/") })
            func key(_ lane: Lane) -> String? {
                guard var prefix = streamPrefix(lane.title) else { return nil }
                if prefix.hasSuffix("-"), let branch = branchPrefixes.first(where: { folderPrefix(prefix, matches: $0) }) {
                    prefix = branch
                }
                return prefix
            }
            // A prefix two families share (such as "claude/") names neither.
            let familyByPrefix = Dictionary(families.compactMap { id in
                lanes.first { $0.id == id }.flatMap { lane in streamPrefix(lane.title).map { ($0, Optional(id)) } }
            }, uniquingKeysWith: { _, _ in nil }).compactMapValues { $0 }
            // Branches with the prefix all of a bundle's strands share join it as strands, rather
            // than make a stream of the same name beside it.
            var bundleByPrefix: [String: Int] = [:]
            for (position, bundle) in bundles.enumerated() {
                let prefixes = Set(bundle.laneIDs.compactMap { id in lanes.first { $0.id == id } }.map(key))
                if prefixes.count == 1, let prefix = prefixes.first ?? nil, bundleByPrefix[prefix] == nil {
                    bundleByPrefix[prefix] = position
                }
            }
            var joining: [Int: (prefix: String, lanes: [Lane])] = [:]
            // A branch others merged into keeps its own row, as when bundles form.
            let targets = Set(lanes.compactMap { $0.merge?.intoLaneID })
            let prefixed = Dictionary(grouping: tops.filter { !families.contains($0.id) }, by: { key($0) ?? "" })
            for (prefix, members) in prefixed where !prefix.isEmpty {
                if let family = familyByPrefix[prefix] {
                    for member in members { root[member.id] = family }
                } else if let position = bundleByPrefix[prefix],
                          case let joiners = members.filter({ !targets.contains($0.id) }), !joiners.isEmpty {
                    joining[position] = (prefix, joiners)
                } else if members.count >= 2 {
                    for member in members { root[member.id] = "stream:" + prefix }
                }
            }
            if !joining.isEmpty {
                for (position, joiners) in joining {
                    let members = bundles[position].laneIDs.compactMap { id in lanes.first { $0.id == id } } + joiners.lanes
                    bundles[position] = Self.bundle(of: members, trunkID: trunkLane)
                    // Folders and branches of one prefix ("mob-", "mob/") go by the branches'.
                    bundles[position].title = streamTitle(joiners.prefix, count: members.count)
                }
                bundles.sort { $0.id < $1.id }
                applyBundles()
            }
            var folded: [Lane] = []
            for (key, group) in Dictionary(grouping: lanes.filter { $0.kind != .trunk && $0.bundle == nil },
                                           by: { root[$0.id] ?? $0.id }) {
                guard group.count >= 2 else {
                    folded += group
                    continue
                }
                let ordered = group.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
                let head = group.first { $0.id == key }
                let title = head.map { "\($0.title) +\(group.count - 1)" }
                    ?? streamTitle(String(key.dropFirst("stream:".count)), count: group.count)
                let returns = ordered.compactMap { lane -> Merge? in
                    guard let merge = lane.merge, !group.contains(where: { $0.id == merge.intoLaneID }) else { return nil }
                    return merge
                }
                var stream = Lane(id: head?.id ?? key, title: title, kind: .branch, row: 0,
                                  start: ordered.map(\.start).min()!, end: ordered.map(\.end).max()!,
                                  forkedAt: ordered.compactMap(\.forkedAt).min(),
                                  merge: head?.merge ?? (returns.count == group.count ? returns.max { $0.date < $1.date } : nil),
                                  deleted: group.allSatisfy(\.deleted), isHead: group.contains(where: \.isHead),
                                  isLive: group.contains(where: \.isLive),
                                  enteredBeforeWindow: group.contains(where: \.enteredBeforeWindow),
                                  editCount: group.reduce(0) { $0 + $1.editCount },
                                  delegatedCount: group.reduce(0) { $0 + $1.delegatedCount },
                                  commitCount: group.reduce(0) { $0 + $1.commitCount },
                                  parentID: head?.parentID ?? trunkLane)
                // The integration branch first, then its branches in order.
                stream.members = (head.map { [$0] } ?? []).map(\.title) + ordered.filter { $0.id != head?.id }.map(\.title)
                stream.returns = returns
                let memberIDs = Set(group.map(\.id))
                for position in spans.indices where memberIDs.contains(spans[position].laneID) {
                    spans[position].laneID = stream.id
                }
                for position in markers.indices {
                    if memberIDs.contains(markers[position].laneID) { markers[position].laneID = stream.id }
                    if let merged = markers[position].mergedLaneID, memberIDs.contains(merged) {
                        markers[position].mergedLaneID = stream.id
                    }
                }
                folded.append(stream)
            }
            let streamOf = Dictionary(uniqueKeysWithValues: folded.flatMap { lane in
                (lane.isStream ? lane.members : [lane.title]).map { (laneID(branch: $0), lane.id) }
            })
            for position in folded.indices {
                if let parent = folded[position].parentID, let stream = streamOf[parent], stream != folded[position].id {
                    folded[position].parentID = stream
                }
            }
            // Strands that merged into a branch now folded return to its stream.
            var strands = lanes.filter { $0.bundle != nil }
            for position in strands.indices {
                if let parent = strands[position].parentID, let stream = streamOf[parent] { strands[position].parentID = stream }
                if let into = strands[position].merge?.intoLaneID, let stream = streamOf[into] {
                    strands[position].merge?.intoLaneID = stream
                }
            }
            for position in bundles.indices {
                if let stream = streamOf[bundles[position].parentID] { bundles[position].parentID = stream }
            }
            lanes = lanes.filter { $0.kind == .trunk } + folded + strands
            spans = rejoined(spans, runBreak: range.runBreak)
        }

        // The axis keeps room around every run, drawn commit, fork and live session.
        var active: [ClosedRange<Date>] = spans.map { $0.start.addingTimeInterval(-range.pad)...$0.end.addingTimeInterval(range.pad) }
        active += markers.map { $0.date.addingTimeInterval(-range.pad)...$0.date.addingTimeInterval(range.pad) }
        active += lanes.compactMap { lane in lane.forkedAt.map { $0.addingTimeInterval(-range.pad)...$0 } }
        if spans.contains(where: { $0.live != nil }) { active.append(now.addingTimeInterval(-range.pad)...now) }
        active = active.map { max($0.lowerBound, windowStart)...max($0.upperBound, windowStart) }
            .map { $0.lowerBound...min($0.upperBound, max($0.lowerBound, now)) }
        let axis = TimeAxis(active: active, marks: spans.flatMap(\.edits), minimumGap: range.minimumGap,
                            gapWidth: 6 / plotWidth, maximumGapShare: 0.16, floor: 3 / plotWidth)
        if let first = lanes.firstIndex(where: { $0.id == trunkLane }), !axis.segments.isEmpty {
            lanes[first].start = axis.start
        }

        // Rows: the trunk on top; branches off the trunk in order of their start,
        // each in the first row with room for it (its runs, merge and label); a
        // branch of an integration branch goes below its parent, into the first
        // row free there, even before lanes that came earlier. A bundle takes one
        // row for all its strands, under its title.
        lanes.sort { ($0.kind == .trunk ? 0 : 1, $0.start, $0.id) < ($1.kind == .trunk ? 0 : 1, $1.start, $1.id) }
        var taken: [[ClosedRange<Double>]] = []
        var placed: [String: Int] = [trunkLane: 0]
        let bundleByID = Dictionary(uniqueKeysWithValues: bundles.map { ($0.id, $0) })
        func parent(of lane: Lane) -> String? { lane.bundle.flatMap { bundleByID[$0]?.parentID } ?? lane.parentID }
        let depth = Dictionary(uniqueKeysWithValues: lanes.map { lane -> (String, Int) in
            var count = 0
            var current = parent(of: lane)
            while let id = current, id != trunkLane, count < 8 {
                count += 1
                current = lanes.first { $0.id == id }.flatMap(parent(of:))
            }
            return (lane.id, count)
        })
        let positionByID = Dictionary(uniqueKeysWithValues: lanes.enumerated().map { ($0.element.id, $0.offset) })
        // Each row's first lane: a branch of its own, or a bundle's first strand.
        let order = lanes.indices.filter { lanes[$0].kind != .trunk && (lanes[$0].bundle == nil || lanes[$0].bundle == lanes[$0].id) }
            .sorted { (depth[lanes[$0].id] ?? 0, lanes[$0].start) < (depth[lanes[$1].id] ?? 0, lanes[$1].start) }
        for position in order {
            let lane = lanes[position]
            let bundle = lane.bundle.flatMap { bundleByID[$0] }
            let members = bundle.map { $0.laneIDs.compactMap { positionByID[$0] } } ?? [position]
            let start = members.map { lanes[$0].start }.min() ?? lane.start
            let x0 = axis.position(of: start) * plotWidth
            let last = members.map { member -> Date in
                let lane = lanes[member]
                return max(lane.merge?.date ?? lane.end, lane.end, lane.returns.map(\.date).max() ?? lane.end,
                           lane.isLive ? now : lane.end)
            }.max() ?? lane.end
            let x1 = max(axis.position(of: last) * plotWidth, x0 + 10)
            let label = min(66, 5.7 * Double((bundle?.title ?? lane.title).count))
            let occupied = max(x1, x0 + 8 + label) + 8
            let lowest = parent(of: lane).flatMap { placed[$0] } ?? 0
            var row = lowest + 1
            while row - 1 < taken.count, taken[row - 1].contains(where: { $0.overlaps((x0 - 2)...occupied) }) { row += 1 }
            while taken.count < row { taken.append([]) }
            taken[row - 1].append(x0...occupied)
            for member in members {
                lanes[member].row = row
                placed[lanes[member].id] = row
            }
        }

        // Slots: overlapping runs on one lane stack, three deep at most. A live
        // session's thread runs on to now in its slot.
        spans.sort { ($0.start, $0.sessionKey, $0.index) < ($1.start, $1.sessionKey, $1.index) }
        var slotEnds: [String: [Double]] = [:]
        for position in spans.indices {
            let x0 = axis.position(of: spans[position].start) * plotWidth
            let end = spans[position].live != nil ? now : spans[position].end
            let x1 = max(axis.position(of: end) * plotWidth, x0 + 4)
            var ends = slotEnds[spans[position].laneID] ?? []
            if let slot = ends.firstIndex(where: { $0 + 2 <= x0 }) {
                ends[slot] = x1
                spans[position].slot = slot
            } else if ends.count < maximumSlots {
                ends.append(x1)
                spans[position].slot = ends.count - 1
            } else {
                ends[maximumSlots - 1] = max(ends[maximumSlots - 1], x1)
                spans[position].slot = maximumSlots - 1
                spans[position].overflow = 1
            }
            slotEnds[spans[position].laneID] = ends
        }

        return ProjectMap(projectPath: project, range: range, now: now, lanes: lanes, spans: spans, markers: markers,
                          axis: axis, sessionCount: activeSessions,
                          cloudSessionCount: Set(cloudSpans.map(\.sessionKey)).count, outsideEdits: outsideEdits,
                          isGitCheckout: snapshot.git != nil, hasCommits: !git.commits.isEmpty,
                          rootCommitDate: git.commits.filter(\.parents.isEmpty).map(\.date).min(),
                          unfoldedBranchCount: unfolded, bundles: bundles)
    }

    /// The position of the run with a session's latest edit, the one its live status and
    /// last activity belong to; of runs ending together, the one that started last.
    static func latestRun(_ runs: [Span]) -> Int {
        runs.indices.max { (runs[$0].end, runs[$0].start, $0) < (runs[$1].end, runs[$1].start, $1) } ?? 0
    }

    /// Whether two runs of one session overlap enough to be work side by side, rather than
    /// one handing over to the next: by a minute, and by a quarter of the shorter run.
    public static func sideBySide(_ a: ClosedRange<Date>, _ b: ClosedRange<Date>) -> Bool {
        let overlap = min(a.upperBound, b.upperBound).timeIntervalSince(max(a.lowerBound, b.lowerBound))
        let shorter = min(a.upperBound.timeIntervalSince(a.lowerBound), b.upperBound.timeIntervalSince(b.lowerBound))
        return overlap >= max(60, shorter / 4)
    }

    /// Branches worked on side by side, linked across sessions, with every agent of a
    /// workflow run they include: three or more, or two agents of one run. A workflow run's
    /// agents bundle on their own too. The trunk, and a branch others merged into, where the
    /// side-by-side work met, keep rows of their own.
    static func bundles(_ spans: [Span], lanes: [Lane], trunkID: String) -> [Bundle] {
        let laneByID = Dictionary(lanes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let targets = Set(lanes.compactMap { $0.merge?.intoLaneID })
        func eligible(_ id: String) -> Bool { id != trunkID && !targets.contains(id) && laneByID[id] != nil }
        var link: [String: String] = [:]
        func root(_ id: String) -> String {
            var current = id
            while let next = link[current], next != current { current = next }
            return current
        }
        func join(_ a: String, _ b: String) {
            let (left, right) = (root(a), root(b))
            link[left] = left
            link[right] = right
            if left != right { link[max(left, right)] = min(left, right) }
        }
        for runs in Dictionary(grouping: spans, by: \.sessionKey).values {
            let candidates = runs.filter { eligible($0.laneID) }.sorted { ($0.start, $0.index) < ($1.start, $1.index) }
            for (position, run) in candidates.enumerated() {
                for other in candidates[(position + 1)...] {
                    guard other.start < run.end else { break }
                    if other.laneID != run.laneID, sideBySide(run.start...run.end, other.start...other.end) {
                        join(run.laneID, other.laneID)
                    }
                }
            }
        }
        let agents = Dictionary(grouping: lanes.filter { eligible($0.id) }, by: { workflowAgent($0.title)?.run ?? "" })
        for (run, members) in agents where !run.isEmpty && members.count >= 2 {
            for member in members.dropFirst() { join(members[0].id, member.id) }
        }
        let groups = Dictionary(grouping: link.keys.compactMap { laneByID[$0] }, by: { root($0.id) })
        return groups.values.compactMap { group -> Bundle? in
            let runs = Set(group.compactMap { workflowAgent($0.title)?.run })
            let oneRun = runs.count == 1 && group.allSatisfy { workflowAgent($0.title) != nil }
            guard group.count >= 3 || (group.count == 2 && oneRun) else { return nil }
            return bundle(of: group, trunkID: trunkID)
        }.sorted { $0.id < $1.id }
    }

    /// The bundle `members` make: strands by start, under the lane most of them merged into.
    static func bundle(of members: [Lane], trunkID: String) -> Bundle {
        let ordered = members.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        let ids = Set(ordered.map(\.id))
        let parents = Dictionary(grouping: ordered.compactMap(\.parentID).filter { !ids.contains($0) }, by: { $0 })
        let parent = parents.max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }?.key ?? trunkID
        return Bundle(id: ordered[0].id, title: bundleTitle(ordered.map(\.title)), laneIDs: ordered.map(\.id), parentID: parent)
    }

    /// A session's runs in time order, as stages: one lane, or the lanes it worked on side by
    /// side. A run joins the stage it begins in when it ends inside it or is side by side
    /// with it; one that only begins as the stage winds down is the next stage.
    public static func stages(_ runs: [Span]) -> [[String]] {
        var stages: [(lanes: [String], range: ClosedRange<Date>)] = []
        for run in runs.sorted(by: { ($0.start, $0.index) < ($1.start, $1.index) }) {
            let range = run.start...run.end
            if let last = stages.last, last.lanes == [run.laneID]
                || (run.start < last.range.upperBound && (run.end <= last.range.upperBound || sideBySide(last.range, range))) {
                let lanes = last.lanes.contains(run.laneID) ? last.lanes : last.lanes + [run.laneID]
                stages[stages.count - 1] = (lanes, last.range.lowerBound...max(last.range.upperBound, range.upperBound))
            } else {
                stages.append(([run.laneID], range))
            }
        }
        return stages.map(\.lanes)
    }

    /// The time `runs` cover, counting time they overlap once.
    public static func activeTime(_ runs: [Span]) -> TimeInterval {
        var total: TimeInterval = 0
        var reach: Date?
        for run in runs.sorted(by: { $0.start < $1.start }) {
            let from = max(run.start, reach ?? run.start)
            if run.end > from { total += run.end.timeIntervalSince(from) }
            reach = max(reach ?? run.end, run.end)
        }
        return total
    }

    /// Runs of one session that now share a lane, such as a workflow's
    /// agents in a folded stream, join again where they are close in time,
    /// unless the session went to another lane in between.
    static func rejoined(_ spans: [Span], runBreak: TimeInterval) -> [Span] {
        var result: [Span] = []
        for (_, runs) in Dictionary(grouping: spans, by: \.sessionKey) {
            var joined: [Span] = []
            let threads = runs.reduce(0) { $0 + $1.spawnedThreads }
            for run in runs.sorted(by: { ($0.start, $0.index) < ($1.start, $1.index) }) {
                if let last = joined.indices.last(where: { joined[$0].laneID == run.laneID }),
                   run.start.timeIntervalSince(joined[last].end) <= runBreak,
                   run.start <= joined[last].end || !runs.contains(where: {
                       $0.laneID != run.laneID && $0.start > joined[last].end && $0.start < run.start
                   }) {
                    joined[last].end = max(joined[last].end, run.end)
                    joined[last].direct = (joined[last].direct + run.direct).sorted()
                    joined[last].delegated = (joined[last].delegated + run.delegated).sorted()
                    joined[last].live = joined[last].live ?? run.live
                } else {
                    joined.append(run)
                }
            }
            joined.sort { $0.start < $1.start }
            for position in joined.indices {
                joined[position].index = position
                joined[position].spawnedThreads = position == 0 ? threads : 0
            }
            // Only the run with the session's latest edit carries its live status.
            if let live = joined.compactMap(\.live).first {
                for position in joined.indices { joined[position].live = nil }
                joined[latestRun(joined)].live = live
            }
            result += joined
        }
        return result
    }

    /// The default branch: main, then master (as a ref, else as the reflog
    /// names them), then the branch the checkout has out now.
    static func trunkName(_ git: GitHistory, index: GitBranchIndex) -> String {
        let names = Set(git.branches.map(\.shortName))
        if names.contains("main") { return "main" }
        if names.contains("master") { return "master" }
        let mentioned = Set(git.headMoves.flatMap { move -> [String] in
            if case .checkout(let from, let to) = move.kind { return [from, to] }
            return []
        })
        if mentioned.contains("main") { return "main" }
        if mentioned.contains("master") { return "master" }
        if let last = git.headMoves.last(where: { $0.worktree == git.checkout }),
           let branch = index.branch(in: git.checkout, at: last.date) { return branch }
        return "main"
    }

    /// The branch a removed worktree folder held, from the forms tools use
    /// to name worktrees after branches: `claude/x` or `worktree-x` for `x`,
    /// `nv/billing` for `nv-billing`, `r2/webkit` for `mob-r2webkit` and
    /// `wave-a/c0` for `wa-c0`. A looser form must name exactly one branch.
    public static func folderBranch(_ name: String, among candidates: [String]) -> String? {
        if let exact = candidates.first(where: { $0 == name || $0.hasSuffix("/" + name) || $0.hasSuffix("-" + name) }) {
            return exact
        }
        // Strongest form first; within a form, exactly one branch may fit.
        let forms: [(String) -> Bool] = [
            { $0.replacingOccurrences(of: "/", with: "-") == name },
            { branch in
                guard let slash = branch.firstIndex(of: "/") else { return false }
                let initials = branch[..<slash].split(separator: "-").compactMap(\.first).map(String.init).joined()
                let leaf = branch[branch.index(after: slash)...].replacingOccurrences(of: "/", with: "-")
                return initials.count >= 2 && name == initials + "-" + leaf
            },
            { $0.contains("/") && name.hasSuffix("-" + $0.replacingOccurrences(of: "/", with: "")) }
        ]
        for form in forms {
            let matches = candidates.filter(form)
            if !matches.isEmpty { return matches.count == 1 ? matches[0] : nil }
        }
        return nil
    }

    /// The prefix branches of one wave share: "nv/" for "nv/billing", the
    /// workflow run for "worktree-wf_88ac3168-2c7-1" (or its folder "wf_…-1").
    public static func streamPrefix(_ title: String) -> String? {
        let name = title.hasPrefix("Worktree · ") ? String(title.dropFirst("Worktree · ".count)) : title
        let run = name.hasPrefix("worktree-") ? String(name.dropFirst("worktree-".count)) : name
        if run.hasPrefix("wf_"), let dash = run.lastIndex(of: "-") { return String(run[..<dash]) }
        if let slash = name.firstIndex(of: "/") { return String(name[...slash]) }
        if let dash = name.firstIndex(of: "-"), title.hasPrefix("Worktree · ") { return String(name[...dash]) }
        return nil
    }

    /// "wa-" for "wave-a/", "mob-" for "mob/": a worktree folder prefix and
    /// its branches' prefix, as initials or the same stem.
    static func folderPrefix(_ folder: String, matches branch: String) -> Bool {
        let stem = String(folder.dropLast())
        let branchStem = String(branch.dropLast())
        let initials = branchStem.split(separator: "-").compactMap(\.first).map(String.init).joined()
        return stem == branchStem || (initials.count >= 2 && stem == initials)
    }

    public static func streamTitle(_ prefix: String, count: Int) -> String {
        if prefix.hasPrefix("wf_") { return "workflow \(shortRun(String(prefix.dropFirst(3)))) · \(count) agents" }
        return "\(prefix)* · \(count)"
    }

    /// The workflow run and agent number a workflow agent's branch or worktree folder
    /// names: ("28a8e52d-996", "3") for "worktree-wf_28a8e52d-996-3".
    public static func workflowAgent(_ title: String) -> (run: String, agent: String)? {
        let name = title.hasPrefix("Worktree · ") ? String(title.dropFirst("Worktree · ".count)) : title
        let run = name.hasPrefix("worktree-") ? String(name.dropFirst("worktree-".count)) : name
        guard run.hasPrefix("wf_"), let dash = run.lastIndex(of: "-") else { return nil }
        let id = String(run[run.index(run.startIndex, offsetBy: 3)..<dash])
        let agent = String(run[run.index(after: dash)...])
        guard !id.isEmpty, !agent.isEmpty else { return nil }
        return (id, agent)
    }

    /// A workflow run as people read it: its first eight characters, "28a8e52d".
    static func shortRun(_ run: String) -> String { run.split(separator: "-").first.map(String.init) ?? run }

    /// A branch as the Map names it: a workflow agent by its run and number, "workflow
    /// 28a8e52d · agent 3"; a worktree whose branch is unknown by its folder.
    public static func displayTitle(_ title: String) -> String {
        if let agent = workflowAgent(title) { return "workflow \(shortRun(agent.run)) · agent \(agent.agent)" }
        return title.hasPrefix("Worktree · ") ? String(title.dropFirst("Worktree · ".count)) : title
    }

    /// A bundle's title from its branches', first strand first: one workflow run, "workflow
    /// 28a8e52d · 6 agents"; several, "7 agents · 2 workflows"; a shared prefix, "mob/* · 12";
    /// else the first and a count, "i162/work +2", as a stream names its head.
    public static func bundleTitle(_ titles: [String]) -> String {
        let agents = titles.compactMap(workflowAgent)
        if !titles.isEmpty, agents.count == titles.count {
            let runs = Set(agents.map(\.run))
            if runs.count == 1, let run = runs.first { return "workflow \(shortRun(run)) · \(titles.count) agents" }
            return "\(titles.count) agents · \(runs.count) workflows"
        }
        if let prefix = sharedPrefix(titles) { return streamTitle(prefix, count: titles.count) }
        return "\(titles.first.map(displayTitle) ?? "") +\(titles.count - 1)"
    }

    /// A bundle's title where its full one does not fit, keeping the count: "7 agents",
    /// "mob/* · 12", "3 branches".
    public static func bundleShortTitle(_ titles: [String]) -> String {
        if !titles.isEmpty, titles.allSatisfy({ workflowAgent($0) != nil }) { return "\(titles.count) agents" }
        if let prefix = sharedPrefix(titles) { return streamTitle(prefix, count: titles.count) }
        return "\(titles.count) branches"
    }

    /// A strand's name beside its bundle's title, without what that title says: "agent 3"
    /// in one workflow run, "28a8e52d · agent 3" across runs, "editor" among "mob/*".
    public static func strandTitle(_ title: String, among titles: [String]) -> String {
        let agents = titles.compactMap(workflowAgent)
        if let agent = workflowAgent(title), agents.count == titles.count {
            return Set(agents.map(\.run)).count == 1 ? "agent \(agent.agent)" : "\(shortRun(agent.run)) · agent \(agent.agent)"
        }
        let name = displayTitle(title)
        // Its own prefix goes, "mob-" for a folder as "mob/" for a branch, when all share it.
        if sharedPrefix(titles) != nil, let own = streamPrefix(title), name.hasPrefix(own), name.count > own.count {
            return String(name.dropFirst(own.count))
        }
        return name
    }

    /// The prefix all `titles` share, a worktree folder's ("mob-") read as its branches'
    /// ("mob/") when those are among them; nil when they share none.
    static func sharedPrefix(_ titles: [String]) -> String? {
        let raw = titles.map(streamPrefix)
        let branches = Set(raw.compactMap { $0 }.filter { $0.hasSuffix("/") })
        let prefixes = Set(raw.map { prefix -> String? in
            guard let prefix, prefix.hasSuffix("-") else { return prefix }
            return branches.first { folderPrefix(prefix, matches: $0) } ?? prefix
        })
        guard prefixes.count == 1, let prefix = prefixes.first ?? nil else { return nil }
        return prefix
    }

    /// The `.claude/worktrees/<name>` folder holding `path`, if any.
    static func claudeWorktree(_ path: String) -> String? {
        let parts = (path as NSString).pathComponents
        guard parts.count >= 3 else { return nil }
        for index in stride(from: parts.count - 3, through: 0, by: -1)
        where parts[index] == ".claude" && parts[index + 1] == "worktrees" {
            return NSString.path(withComponents: Array(parts[...(index + 2)]))
        }
        return nil
    }
}
