import Foundation
import XCTest
@testable import AgentTrailCore

final class ProjectMapTests: XCTestCase {
    private let repo = "/repo"
    private let base = Date(timeIntervalSince1970: 1_800_000_000)
    private let utc = ActivityCalendar.utcMidnight

    private func at(_ minutes: Double) -> Date { base.addingTimeInterval(minutes * 60) }
    private func sha(_ name: String) -> String { name.padding(toLength: 40, withPad: "0", startingAt: 0) }
    private func edit(_ minutes: Double, in folder: String? = nil, delegated: Bool = false) -> TrailEdit {
        TrailEdit(date: at(minutes), projectPath: repo, workspacePath: folder ?? repo, delegated: delegated)
    }
    private func move(_ minutes: Double, _ kind: GitHistory.HeadMove.Kind, old: String = "a", new: String = "a",
                      worktree: String? = nil) -> GitHistory.HeadMove {
        GitHistory.HeadMove(date: at(minutes), worktree: worktree ?? repo, old: sha(old), new: sha(new), kind: kind)
    }
    private func build(_ trails: [SessionTrail], git: GitHistory?, live: [MapSnapshot.LiveMark] = [],
                       now: Double = 600, range: MapRange = .all) -> ProjectMap {
        ProjectMap.build(MapSnapshot(projectPath: repo, takenAt: at(now), sources: [], trails: trails, git: git, live: live),
                         range: range, calendar: utc)
    }

    // MARK: Axis

    func testAxisFoldsIdleStretchesToEqualSlivers() {
        let axis = TimeAxis(active: [at(0)...at(60), at(600)...at(660), at(661)...at(700), at(2000)...at(2030)])
        XCTAssertEqual(axis.gaps.count, 2)
        XCTAssertEqual(axis.gaps[0].upper - axis.gaps[0].lower, axis.gaps[1].upper - axis.gaps[1].lower, accuracy: 1e-9)
        XCTAssertEqual(axis.position(of: at(-10)), 0)
        XCTAssertEqual(axis.position(of: at(3000)), axis.segments.last!.upper)
        let positions = stride(from: -10.0, through: 2040, by: 7).map { axis.position(of: at($0)) }
        XCTAssertEqual(positions, positions.sorted())
        // A nine-hour night costs less width than an hour of work.
        XCTAssertLessThan(axis.position(of: at(600)) - axis.position(of: at(60)),
                          axis.position(of: at(60)) - axis.position(of: at(0)))
        XCTAssertEqual(axis.gaps[0].duration, 540 * 60)
    }

    func testAxisStaysInsideTheWidthWithHundredsOfBursts() {
        let bursts = (0..<300).map { at(Double($0) * 120)...at(Double($0) * 120 + 16) }
        let axis = TimeAxis(active: bursts, marks: bursts.map(\.lowerBound), floor: 0.004)
        XCTAssertEqual(axis.gaps.count, 299)
        XCTAssertTrue(axis.segments.allSatisfy { $0.lower <= $0.upper && $0.upper <= 1.000_001 })
        let positions = stride(from: 0.0, through: 36_000, by: 37).map { axis.position(of: at($0)) }
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertLessThanOrEqual(positions.last ?? 2, 1.000_001)
    }

    func testDayStartsFallAtTheRolloverHour() {
        let calendar = ActivityCalendar(timeZone: TimeZone(secondsFromGMT: 3 * 3_600)!)
        // 03:00 local; the next activity day starts at 05:00 local, two hours later.
        let start = Date(timeIntervalSince1970: 1_799_971_200)
        let axis = TimeAxis(active: [start...start.addingTimeInterval(30 * 3_600)])
        XCTAssertEqual(axis.dayStarts(calendar: calendar), [start.addingTimeInterval(2 * 3_600), start.addingTimeInterval(26 * 3_600)])
    }

    // MARK: Lanes and merges

    func testLanesSpansAndMergesFollowGitAndTheReflog() throws {
        let commits = [
            GitHistory.Commit(sha: sha("c0"), parents: [], tree: "t0", date: at(0), subject: "First"),
            GitHistory.Commit(sha: sha("b1"), parents: [sha("c0")], tree: "t1", date: at(50), subject: "Feature work"),
            GitHistory.Commit(sha: sha("s1"), parents: [sha("c0")], tree: "t1", date: at(60), subject: "Feature work (#3)"),
            GitHistory.Commit(sha: sha("w1"), parents: [sha("s1")], tree: "t3", date: at(70), subject: "Worktree work"),
            GitHistory.Commit(sha: sha("s2"), parents: [sha("s1")], tree: "t3", date: at(75), subject: "Worktree work (#4)")
        ]
        let moves = [
            move(0, .commit, old: "0", new: "c0"),
            move(10, .checkout(from: "main", to: "feature"), old: "c0", new: "c0"),
            move(50, .commit, old: "c0", new: "b1"),
            move(55, .checkout(from: "feature", to: "main"), old: "b1", new: "c0"),
            move(61, .fastForward, old: "c0", new: "s1"),
            move(76, .fastForward, old: "s1", new: "s2")
        ]
        let git = GitHistory(checkout: repo, commits: commits,
                             branches: [GitHistory.Branch(name: "main", head: sha("s2"), isRemote: false),
                                        GitHistory.Branch(name: "origin/feature", head: sha("b1"), isRemote: true),
                                        GitHistory.Branch(name: "origin/wt-branch", head: sha("w1"), isRemote: true)],
                             headMoves: moves)
        let worktree = repo + "/.claude/worktrees/wt"
        let trails = [
            // Edited on main before `checkout -b feature`; the change travelled with it.
            SessionTrail(sourceID: "claude", sessionID: "local_a", projectPath: repo, createdAt: at(2), latestActivity: at(41),
                         edits: [edit(5), edit(20), edit(40, delegated: true)], otherIDs: ["cli-a"]),
            SessionTrail(sourceID: "claude", sessionID: "local_b", projectPath: repo, createdAt: at(25), latestActivity: at(35),
                         edits: [edit(30, in: worktree), edit(32, in: worktree)],
                         writtenBranches: [WrittenBranch(workspacePath: worktree, branch: "wt-branch")]),
            // No edits and not live: not drawn, but counted as a session.
            SessionTrail(sourceID: "codex", sessionID: "quiet", projectPath: repo, createdAt: at(72), latestActivity: at(78)),
            SessionTrail(sourceID: "claude", sessionID: "local_live", projectPath: repo, createdAt: at(86), latestActivity: at(90),
                         edits: [edit(90)], otherIDs: ["cli-live"])
        ]
        let map = build(trails, git: git, live: [MapSnapshot.LiveMark(sourceID: "claude", sessionID: "cli-live", status: "working"),
                                                 MapSnapshot.LiveMark(sourceID: "claude", sessionID: "cli-a", status: "idle")],
                        now: 120)

        XCTAssertEqual(map.lanes.first?.id, "branch:main")
        XCTAssertEqual(map.lanes.first?.kind, .trunk)
        let feature = try XCTUnwrap(map.lane("branch:feature"))
        XCTAssertEqual(feature.forkedAt, at(10))
        XCTAssertEqual(feature.merge, ProjectMap.Merge(date: at(60), sha: sha("s1"), pullRequest: 3, match: .tree, intoLaneID: "branch:main"))
        XCTAssertEqual(feature.editCount, 3)
        XCTAssertEqual(feature.delegatedCount, 1)
        XCTAssertFalse(feature.deleted)
        let worktreeLane = try XCTUnwrap(map.lane("branch:wt-branch"))
        XCTAssertEqual(worktreeLane.editCount, 2)
        XCTAssertEqual(worktreeLane.merge?.pullRequest, 4)
        XCTAssertTrue(map.lanes.dropFirst().allSatisfy { $0.row > 0 })

        let first = map.spans.filter { $0.sessionID == "local_a" }
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.laneID, "branch:feature")
        XCTAssertEqual(first.first?.start, at(2))
        XCTAssertEqual(first.first?.end, at(41))
        XCTAssertEqual(first.first?.delegated, [at(40)])
        XCTAssertNil(first.first?.live)
        XCTAssertFalse(map.spans.contains { $0.sessionID == "quiet" })
        let live = try XCTUnwrap(map.spans.first { $0.sessionID == "local_live" })
        XCTAssertEqual(live.live, "working")
        // The bar ends at the last edit; the thread to now is drawn, not stored.
        XCTAssertEqual(live.end, at(90))
        XCTAssertEqual(live.laneID, "branch:main")
        XCTAssertEqual(map.lane("branch:main")?.end, at(120))

        // Fast-forwards claim nothing: the squash commits stay on the trunk as beads.
        let trunkBeads = map.markers.filter { $0.laneID == "branch:main" && $0.isBead }
        XCTAssertEqual(trunkBeads.map(\.pullRequest), [3, 4])
        XCTAssertEqual(trunkBeads.map(\.mergedLaneID), ["branch:feature", "branch:wt-branch"])
        XCTAssertEqual(map.editCount, 6)
        XCTAssertEqual(map.sessionCount, 4)
        XCTAssertEqual(map.mergeCount, 2)
    }

    func testMergedBranchWithoutEditsIsAQuietBeadNotALane() {
        let commits = [
            GitHistory.Commit(sha: sha("c0"), parents: [], tree: "t0", date: at(0), subject: "First"),
            GitHistory.Commit(sha: sha("r1"), parents: [sha("c0")], tree: "t1", date: at(30), subject: "Release"),
            GitHistory.Commit(sha: sha("s1"), parents: [sha("c0")], tree: "t1", date: at(31), subject: "Release (#7)")
        ]
        let git = GitHistory(checkout: repo, commits: commits,
                             branches: [GitHistory.Branch(name: "main", head: sha("s1"), isRemote: false),
                                        GitHistory.Branch(name: "release", head: sha("r1"), isRemote: false)],
                             headMoves: [])
        let map = build([SessionTrail(sourceID: "claude", sessionID: "s", projectPath: repo, createdAt: at(1),
                                      latestActivity: at(5), edits: [edit(4)])], git: git, now: 60)
        XCTAssertNil(map.lane("branch:release"))
        XCTAssertEqual(map.markers.first { $0.sha == sha("s1") }?.quietBranch, "release")
        XCTAssertEqual(map.quietMergeCount, 1)
        XCTAssertFalse(map.markers.contains { $0.sha == sha("r1") })
    }

    func testCloudSessionCommitsAreRunsWithoutEditsOnTheirBranch() throws {
        func cloud(_ name: String, _ parent: String, _ minutes: Double) -> GitHistory.Commit {
            GitHistory.Commit(sha: sha(name), parents: [sha(parent)], tree: "t" + name, date: at(minutes), subject: name,
                              viaGitHub: false, cloudSession: "session_A")
        }
        let commits = [
            GitHistory.Commit(sha: sha("c0"), parents: [], tree: "t0", date: at(0), subject: "First"),
            cloud("k1", "c0", 10), cloud("k2", "k1", 15), cloud("k3", "k2", 200),
            // The squash GitHub made copies the trailer, but marks the merge, not the work.
            GitHistory.Commit(sha: sha("s1"), parents: [sha("c0")], tree: "tk3", date: at(300), subject: "Fix (#9)",
                              cloudSession: "session_A")
        ]
        let git = GitHistory(checkout: repo, commits: commits,
                             branches: [GitHistory.Branch(name: "main", head: sha("s1"), isRemote: false),
                                        GitHistory.Branch(name: "origin/claude/fix", head: sha("k3"), isRemote: true)],
                             headMoves: [])
        let map = build([SessionTrail(sourceID: "claude", sessionID: "s", projectPath: repo, createdAt: at(1),
                                      latestActivity: at(5), edits: [edit(4)])], git: git)
        // No local session edited the branch, yet it stays a lane rather than a quiet bead.
        let lane = try XCTUnwrap(map.lane("branch:claude/fix"))
        XCTAssertEqual(lane.merge?.sha, sha("s1"))
        XCTAssertNil(map.markers.first { $0.sha == sha("s1") }?.quietBranch)
        let runs = map.spans.filter { $0.sourceID == ProjectMap.cloudSourceID }.sorted { $0.index < $1.index }
        XCTAssertEqual(runs.map(\.laneID), ["branch:claude/fix", "branch:claude/fix"])
        XCTAssertEqual(runs.map(\.start), [at(10), at(200)])
        XCTAssertEqual(runs.map(\.end), [at(15), at(200)])
        XCTAssertEqual(runs.map(\.editCount), [0, 0])
        XCTAssertEqual(Set(runs.map(\.sessionKey)).count, 1)
        // Cloud sessions are counted apart from the sessions Projects counts.
        XCTAssertEqual(map.cloudSessionCount, 1)
        XCTAssertEqual(map.sessionCount, 1)
        XCTAssertEqual(map.editCount, 1)
        XCTAssertEqual(map.markers.first { $0.sha == sha("k2") }?.cloudSession, "session_A")
        XCTAssertEqual(ProjectMap.cloudURL(runs[0])?.absoluteString, "https://claude.ai/code/session_A")
        XCTAssertNil(ProjectMap.cloudURL(try XCTUnwrap(map.spans.first { $0.sourceID == "claude" })))
        let main = AgentSource(id: "claude", name: "Claude · Main", configDirectory: "/c")
        XCTAssertEqual(map.sources([main]).map(\.id), ["claude", ProjectMap.cloudSourceID])
        XCTAssertEqual(build([], git: GitHistory(checkout: repo)).sources([main]).map(\.id), ["claude"])
    }

    func testCheckoutOfAnExistingBranchStopsTheCarry() {
        // Edited on main, then switched to an existing branch and committed there:
        // those changes stayed behind, so the edit is main's.
        let commits = [
            GitHistory.Commit(sha: sha("c0"), parents: [], tree: "t0", date: at(0), subject: "First"),
            GitHistory.Commit(sha: sha("o1"), parents: [sha("c0")], tree: "t1", date: at(5), subject: "Old work"),
            GitHistory.Commit(sha: sha("o2"), parents: [sha("o1")], tree: "t2", date: at(40), subject: "More old work")
        ]
        let moves = [
            move(0, .commit, old: "0", new: "c0"),
            move(1, .checkout(from: "main", to: "old"), old: "c0", new: "c0"),
            move(5, .commit, old: "c0", new: "o1"),
            move(6, .checkout(from: "old", to: "main"), old: "o1", new: "c0"),
            move(30, .checkout(from: "main", to: "old"), old: "c0", new: "o1"),
            move(40, .commit, old: "o1", new: "o2")
        ]
        let git = GitHistory(checkout: repo, commits: commits,
                             branches: [GitHistory.Branch(name: "main", head: sha("c0"), isRemote: false),
                                        GitHistory.Branch(name: "old", head: sha("o2"), isRemote: false)],
                             headMoves: moves)
        XCTAssertEqual(git.capturedBranch(in: repo, at: at(20), limit: 3_600), "main")
        // Before the first switch, `checkout -b old` from the same commit carries it.
        XCTAssertEqual(git.capturedBranch(in: repo, at: at(0.5), limit: 3_600), "old")
    }

    func testAmendedCommitsAreDroppedWhileTheirBranchExists() {
        let commits = [
            GitHistory.Commit(sha: sha("c0"), parents: [], tree: "t0", date: at(0), subject: "First"),
            GitHistory.Commit(sha: sha("x1"), parents: [sha("c0")], tree: "t1", date: at(10), subject: "Typo"),
            GitHistory.Commit(sha: sha("x2"), parents: [sha("c0")], tree: "t2", date: at(11), subject: "Fixed")
        ]
        let moves = [
            move(0, .commit, old: "0", new: "c0"),
            move(5, .checkout(from: "main", to: "topic"), old: "c0", new: "c0"),
            move(10, .commit, old: "c0", new: "x1"),
            move(11, .commit, old: "x1", new: "x2")
        ]
        let git = GitHistory(checkout: repo, commits: commits,
                             branches: [GitHistory.Branch(name: "main", head: sha("c0"), isRemote: false),
                                        GitHistory.Branch(name: "topic", head: sha("x2"), isRemote: false)],
                             headMoves: moves)
        let map = build([SessionTrail(sourceID: "claude", sessionID: "s", projectPath: repo, createdAt: at(6),
                                      latestActivity: at(9), edits: [edit(8)])], git: git, now: 30)
        XCTAssertEqual(map.markers.filter { $0.laneID == "branch:topic" }.map(\.sha), [sha("x2")])
        XCTAssertEqual(map.lane("branch:topic")?.commitCount, 1)
    }

    func testWithoutGitRefsNoBranchReadsAsDeletedAndMainStaysTheTrunk() {
        let moves = [move(0, .checkout(from: "main", to: "feature-x"))]
        let git = GitHistory(checkout: repo, headMoves: moves)
        let map = build([SessionTrail(sourceID: "claude", sessionID: "s", projectPath: repo, createdAt: at(1),
                                      latestActivity: at(5), edits: [edit(4)])], git: git, now: 60)
        XCTAssertEqual(map.lanes.first?.title, "main")
        XCTAssertEqual(map.lane("branch:feature-x")?.deleted, false)
    }

    func testSpawnedThreadsFoldIntoTheirParentAndOutsideEditsAreNotDrawn() {
        let draft = "/drafts/idea"
        let trails = [
            SessionTrail(sourceID: "codex", sessionID: "root", projectPath: repo, createdAt: at(0), latestActivity: at(30),
                         edits: [edit(10), TrailEdit(date: at(12), projectPath: draft, workspacePath: draft)]),
            SessionTrail(sourceID: "codex", sessionID: "child-1", projectPath: repo, createdAt: at(1), latestActivity: at(30),
                         parentSessionID: "root", edits: [edit(11), edit(20)]),
            SessionTrail(sourceID: "codex", sessionID: "child-2", projectPath: repo, createdAt: at(2), latestActivity: at(30),
                         parentSessionID: "root", edits: [edit(15)])
        ]
        let map = build(trails, git: nil, now: 60)
        XCTAssertEqual(Set(map.spans.map(\.sessionKey)), ["codex\u{0}root"])
        XCTAssertEqual(map.spans.first?.spawnedThreads, 2)
        XCTAssertEqual(map.spans.first?.delegated, [at(11), at(15), at(20)])
        XCTAssertEqual(map.spans.first?.direct, [at(10)])
        XCTAssertEqual(map.outsideEdits, 1)
        XCTAssertEqual(map.editCount, 4)
        XCTAssertEqual(map.sessionCount, 3)
        XCTAssertFalse(map.isGitCheckout)
        XCTAssertEqual(map.lanes.map(\.id), ["branch:main"])
    }

    func testLinkedWorktreesInsideTheCheckoutFollowTheirOwnReflog() {
        let worktree = repo + "/.worktrees/feat"
        let git = GitHistory(checkout: repo,
                             branches: [GitHistory.Branch(name: "main", head: sha("c0"), isRemote: false),
                                        GitHistory.Branch(name: "feat", head: sha("c0"), isRemote: false)],
                             headMoves: [move(0, .checkout(from: "main", to: "feat"), old: "c0", new: "c0", worktree: worktree)])
        let map = build([SessionTrail(sourceID: "codex", sessionID: "s", projectPath: repo, createdAt: at(1),
                                      latestActivity: at(9), edits: [edit(5, in: worktree + "/Sources")])], git: git, now: 30)
        XCTAssertEqual(map.spans.map(\.laneID), ["branch:feat"])
    }

    func testASessionBasedElsewhereIsNeitherLiveNorCountedHereWithoutRecentEditsHere() {
        let elsewhere = "/other"
        let trail = SessionTrail(sourceID: "claude", sessionID: "local_x", projectPath: elsewhere, createdAt: at(0),
                                 latestActivity: at(590), edits: [edit(10),
                                    TrailEdit(date: at(580), projectPath: elsewhere, workspacePath: elsewhere)],
                                 writtenBranches: [WrittenBranch(workspacePath: elsewhere, branch: "other-branch")])
        let live = [MapSnapshot.LiveMark(sourceID: "claude", sessionID: "local_x", status: "working")]
        let map = build([trail], git: nil, live: live, now: 600)
        XCTAssertFalse(map.spans.contains { $0.live != nil })
        XCTAssertNil(map.lane("branch:other-branch"))
        XCTAssertEqual(map.spans.map(\.edits), [[at(10)]])
        XCTAssertEqual(map.outsideEdits, 1)
        // A range that starts after its edit here does not count it.
        let later = ProjectMap.build(MapSnapshot(projectPath: repo, takenAt: at(3_000), sources: [], trails: [trail],
                                                 git: nil, live: live), range: .today, calendar: utc)
        XCTAssertEqual(later.sessionCount, 0)
    }

    func testOnlyTheCheckoutThatCreatedABranchIsItsFork() {
        let commits = [GitHistory.Commit(sha: sha("c0"), parents: [], tree: "t0", date: at(0), subject: "First"),
                       GitHistory.Commit(sha: sha("f1"), parents: [sha("c0")], tree: "t1", date: at(20), subject: "Feature")]
        let moves = [
            move(0, .commit, old: "0", new: "c0"),
            move(10, .checkout(from: "main", to: "feature"), old: "c0", new: "c0"),
            move(20, .commit, old: "c0", new: "f1"),
            move(30, .checkout(from: "feature", to: "main"), old: "f1", new: "c0"),
            // A later visit, after the first commit, is not a fork.
            move(300, .checkout(from: "main", to: "feature"), old: "c0", new: "f1")
        ]
        let git = GitHistory(checkout: repo, commits: commits,
                             branches: [GitHistory.Branch(name: "main", head: sha("c0"), isRemote: false),
                                        GitHistory.Branch(name: "feature", head: sha("f1"), isRemote: false)],
                             headMoves: moves)
        let trails = [SessionTrail(sourceID: "claude", sessionID: "s", projectPath: repo, createdAt: at(301),
                                   latestActivity: at(320), edits: [edit(310)])]
        XCTAssertEqual(build(trails, git: git, now: 400).lane("branch:feature")?.forkedAt, at(10))
        // In a range that starts after the creation, the branch enters from the left edge.
        let day = 24.0 * 60
        let late = ProjectMap.build(MapSnapshot(projectPath: repo, takenAt: at(day + 400), sources: [],
            trails: [SessionTrail(sourceID: "claude", sessionID: "t", projectPath: repo, createdAt: at(day + 300),
                                  latestActivity: at(day + 320), edits: [edit(day + 310)])],
            git: GitHistory(checkout: repo, commits: commits, branches: git.branches,
                            headMoves: moves + [move(day + 300, .checkout(from: "main", to: "feature"), old: "c0", new: "f1")]),
            live: []), range: .today, calendar: utc)
        XCTAssertNil(late.lane("branch:feature")?.forkedAt)
    }

    func testMergesAreMatchedByTreeBeforeAnySubjectMatch() {
        // a-parser's later commit shares a subject with b-ci's squash; b-ci's tree match must win it.
        let commits = [
            GitHistory.Commit(sha: sha("c0"), parents: [], tree: "t0", date: at(0), subject: "First"),
            GitHistory.Commit(sha: sha("a1"), parents: [sha("c0")], tree: "ta1", date: at(5), subject: "Add parser"),
            GitHistory.Commit(sha: sha("a2"), parents: [sha("a1")], tree: "ta2", date: at(10), subject: "Fix tests"),
            GitHistory.Commit(sha: sha("b1"), parents: [sha("c0")], tree: "tb", date: at(12), subject: "Fix tests"),
            GitHistory.Commit(sha: sha("s1"), parents: [sha("c0")], tree: "tb", date: at(20), subject: "Fix tests (#39)"),
            GitHistory.Commit(sha: sha("s2"), parents: [sha("s1")], tree: "tx", date: at(30), subject: "Add parser (#40)")
        ]
        let git = GitHistory(checkout: repo, commits: commits,
                             branches: [GitHistory.Branch(name: "main", head: sha("s2"), isRemote: false),
                                        GitHistory.Branch(name: "a-parser", head: sha("a2"), isRemote: false),
                                        GitHistory.Branch(name: "b-ci", head: sha("b1"), isRemote: false)],
                             headMoves: [])
        let trails = [
            SessionTrail(sourceID: "claude", sessionID: "a", projectPath: repo, createdAt: at(1), latestActivity: at(4),
                         edits: [edit(3, in: repo + "/.claude/worktrees/a")],
                         writtenBranches: [WrittenBranch(workspacePath: repo + "/.claude/worktrees/a", branch: "a-parser")]),
            SessionTrail(sourceID: "claude", sessionID: "b", projectPath: repo, createdAt: at(6), latestActivity: at(11),
                         edits: [edit(11, in: repo + "/.claude/worktrees/b")],
                         writtenBranches: [WrittenBranch(workspacePath: repo + "/.claude/worktrees/b", branch: "b-ci")])
        ]
        let map = build(trails, git: git, now: 60)
        XCTAssertEqual(map.lane("branch:b-ci")?.merge?.pullRequest, 39)
        XCTAssertEqual(map.lane("branch:b-ci")?.merge?.match, .tree)
        XCTAssertEqual(map.lane("branch:a-parser")?.merge?.pullRequest, 40)
        XCTAssertEqual(map.lane("branch:a-parser")?.merge?.match, .subject)
    }

    func testAmendedCommitsOfADeletedBranchAreDropped() {
        let commits = [GitHistory.Commit(sha: sha("c0"), parents: [], tree: "t0", date: at(0), subject: "First"),
                       GitHistory.Commit(sha: sha("x1"), parents: [sha("c0")], tree: "t1", date: at(10), subject: "Typo"),
                       GitHistory.Commit(sha: sha("x2"), parents: [sha("c0")], tree: "t2", date: at(11), subject: "Fixed")]
        let moves = [move(0, .commit, old: "0", new: "c0"),
                     move(5, .checkout(from: "main", to: "gone"), old: "c0", new: "c0"),
                     move(10, .commit, old: "c0", new: "x1"),
                     move(11, .amend, old: "x1", new: "x2")]
        let git = GitHistory(checkout: repo, commits: commits,
                             branches: [GitHistory.Branch(name: "main", head: sha("c0"), isRemote: false)], headMoves: moves)
        let map = build([SessionTrail(sourceID: "claude", sessionID: "s", projectPath: repo, createdAt: at(6),
                                      latestActivity: at(9), edits: [edit(8)])], git: git, now: 30)
        XCTAssertEqual(map.markers.filter { $0.laneID == "branch:gone" }.map(\.sha), [sha("x2")])
        XCTAssertEqual(map.lane("branch:gone")?.deleted, true)
    }

    func testRemovedWorktreeFoldersMapToTheirBranchesByName() {
        let branches = ["claude/gifted-mclean-0b440d", "worktree-wf_88ac3168-2c7-1", "nv/billing", "wave-a/c0",
                        "wave-a/fix-gauge", "r2/webkit", "billing", "ref/billing"]
        XCTAssertEqual(ProjectMap.folderBranch("gifted-mclean-0b440d", among: branches), "claude/gifted-mclean-0b440d")
        XCTAssertEqual(ProjectMap.folderBranch("wf_88ac3168-2c7-1", among: branches), "worktree-wf_88ac3168-2c7-1")
        XCTAssertEqual(ProjectMap.folderBranch("nv-billing", among: branches), "nv/billing")
        XCTAssertEqual(ProjectMap.folderBranch("wa-c0", among: branches), "wave-a/c0")
        XCTAssertEqual(ProjectMap.folderBranch("wa-fix-gauge", among: branches), "wave-a/fix-gauge")
        XCTAssertEqual(ProjectMap.folderBranch("mob-r2webkit", among: branches), "r2/webkit")
        // The flattened name outranks a looser form that also fits.
        XCTAssertEqual(ProjectMap.folderBranch("ref-billing", among: branches), "ref/billing")
        XCTAssertNil(ProjectMap.folderBranch("pr151", among: branches))
    }

    func testBranchesMergedIntoAnIntegrationBranchFoldIntoOneStream() throws {
        // Two feature branches merge into `integration`, which merges into main;
        // fifteen unrelated branches push the map past the fold threshold.
        var commits = [GitHistory.Commit(sha: sha("c0"), parents: [], tree: "t0", date: at(0), subject: "First"),
                       GitHistory.Commit(sha: sha("i0"), parents: [sha("c0")], tree: "ti", date: at(5), subject: "Start"),
                       GitHistory.Commit(sha: sha("a1"), parents: [sha("i0")], tree: "ta", date: at(20), subject: "A"),
                       GitHistory.Commit(sha: sha("b1"), parents: [sha("i0")], tree: "tb", date: at(22), subject: "B"),
                       GitHistory.Commit(sha: sha("m1"), parents: [sha("i0"), sha("a1")], tree: "tm1", date: at(30), subject: "Merge a"),
                       GitHistory.Commit(sha: sha("m2"), parents: [sha("m1"), sha("b1")], tree: "tm2", date: at(31), subject: "Merge b"),
                       GitHistory.Commit(sha: sha("s1"), parents: [sha("c0"), sha("m2")], tree: "tm2", date: at(40),
                                         subject: "Merge integration", viaGitHub: false)]
        var branches = [GitHistory.Branch(name: "main", head: sha("s1"), isRemote: false),
                        GitHistory.Branch(name: "integration", head: sha("m2"), isRemote: false),
                        GitHistory.Branch(name: "feature-a", head: sha("a1"), isRemote: false),
                        GitHistory.Branch(name: "feature-b", head: sha("b1"), isRemote: false)]
        var trails = [
            SessionTrail(sourceID: "claude", sessionID: "workflow", projectPath: repo, createdAt: at(10), latestActivity: at(25),
                         edits: [edit(12, in: repo + "/.claude/worktrees/feature-a"), edit(13, in: repo + "/.claude/worktrees/feature-b"),
                                 edit(18, in: repo + "/.claude/worktrees/feature-a")])
        ]
        for index in 0..<15 {
            let name = "solo\(index)"
            commits.append(GitHistory.Commit(sha: sha("x\(index)"), parents: [sha("c0")], tree: "tx\(index)",
                                             date: at(Double(100 + index * 30)), subject: name))
            branches.append(GitHistory.Branch(name: name, head: sha("x\(index)"), isRemote: false))
            trails.append(SessionTrail(sourceID: "codex", sessionID: name, projectPath: repo, createdAt: at(Double(95 + index * 30)),
                                       latestActivity: at(Double(99 + index * 30)),
                                       edits: [edit(Double(98 + index * 30), in: repo + "/.claude/worktrees/" + name)]))
        }
        let git = GitHistory(checkout: repo, commits: commits, branches: branches, headMoves: [])
        let expanded = build(trails, git: git, now: 700)
        XCTAssertEqual(expanded.lane("branch:feature-a")?.merge?.intoLaneID, "branch:integration")
        XCTAssertEqual(expanded.lane("branch:feature-a")?.parentID, "branch:integration")
        XCTAssertEqual(expanded.lane("branch:integration")?.merge?.intoLaneID, "branch:main")
        // An integration branch with branches merged into it is no quiet bead, even with no edits of its own.
        XCTAssertNotNil(expanded.lane("branch:integration"))
        XCTAssertGreaterThan(try XCTUnwrap(expanded.lane("branch:feature-a")).row,
                             try XCTUnwrap(expanded.lane("branch:integration")).row)

        let folded = ProjectMap.build(MapSnapshot(projectPath: repo, takenAt: at(700), sources: [], trails: trails, git: git),
                                      range: .all, calendar: utc, collapseAbove: 14)
        let stream = try XCTUnwrap(folded.lane("branch:integration"))
        XCTAssertEqual(stream.members, ["integration", "feature-a", "feature-b"])
        XCTAssertEqual(stream.title, "integration +2")
        XCTAssertEqual(folded.unfoldedBranchCount, 18)
        XCTAssertNil(folded.lane("branch:feature-a"))
        // The workflow's runs on two folded branches join into one bar.
        XCTAssertEqual(folded.spans.filter { $0.sessionID == "workflow" }.count, 1)
        XCTAssertEqual(folded.spans.first { $0.sessionID == "workflow" }?.editCount, 3)
        XCTAssertNil(build(trails, git: git, now: 700).unfoldedBranchCount)
    }

    /// One session's edits in `branches`' worktrees, each written to its branch, at `minutes`.
    private func worktreeSession(_ id: String, _ edits: [(minutes: Double, branch: String)], live: Bool = false) -> SessionTrail {
        let folders = Dictionary(edits.map { ($0.branch, repo + "/.claude/worktrees/" + $0.branch.replacingOccurrences(of: "/", with: "-")) },
                                 uniquingKeysWith: { first, _ in first })
        return SessionTrail(sourceID: "claude", sessionID: id, projectPath: repo, createdAt: at(edits.first?.minutes ?? 0),
                            latestActivity: at(edits.last?.minutes ?? 0),
                            edits: edits.map { edit(Double($0.minutes), in: folders[$0.branch], delegated: true) },
                            writtenBranches: folders.sorted { $0.key < $1.key }.map { WrittenBranch(workspacePath: $0.value, branch: $0.key) })
    }

    func testASessionWorkingOnBranchesSideBySideKeepsOneRunOnEach() throws {
        // Three agents take turns every minute for half an hour, then one carries on alone.
        let branches = ["wave/a", "wave/b", "wave/c"]
        var edits = (0..<30).map { (minutes: Double(10 + $0), branch: branches[$0 % 3]) }
        edits += [(minutes: 45, branch: "wave/b"), (minutes: 50, branch: "wave/b")]
        let live = [MapSnapshot.LiveMark(sourceID: "claude", sessionID: "fan", status: "working")]
        let map = build([worktreeSession("fan", edits)], git: nil, live: live, now: 60)
        let runs = map.spans.sorted { $0.index < $1.index }
        XCTAssertEqual(runs.map(\.laneID), ["branch:wave/a", "branch:wave/b", "branch:wave/c"])
        XCTAssertEqual(runs.map(\.editCount), [10, 12, 10])
        XCTAssertEqual(runs.map(\.start), [at(10), at(11), at(12)])
        // The live status sits on the run with the latest edit, though another started later.
        XCTAssertEqual(runs.map(\.live), [nil, "working", nil])
        XCTAssertEqual(runs[1].end, at(50))
        XCTAssertEqual(ProjectMap.stages(runs), [["branch:wave/a", "branch:wave/b", "branch:wave/c"]])
        XCTAssertEqual(ProjectMap.activeTime(runs), 40 * 60)
        // Without grouping, each branch keeps a row of its own.
        XCTAssertTrue(map.bundles.isEmpty)
        XCTAssertEqual(Set(map.lanes.filter { $0.kind != .trunk }.map(\.row)).count, 3)
    }

    func testACheckoutInOneFolderEndsTheRunOnTheBranchItLeft() {
        // a → b → a in the main checkout, each within the run break: one folder holds one
        // branch at a time, so these are three runs one after another, not side by side.
        let commits = [GitHistory.Commit(sha: sha("c0"), parents: [], tree: "t0", date: at(0), subject: "First"),
                       GitHistory.Commit(sha: sha("a1"), parents: [sha("c0")], tree: "ta1", date: at(4), subject: "A"),
                       GitHistory.Commit(sha: sha("b1"), parents: [sha("a1")], tree: "tb1", date: at(8), subject: "B"),
                       GitHistory.Commit(sha: sha("a2"), parents: [sha("a1")], tree: "ta2", date: at(12), subject: "A again")]
        let moves = [move(0, .commit, old: "0", new: "c0"),
                     move(1, .checkout(from: "main", to: "a"), old: "c0", new: "c0"),
                     move(4, .commit, old: "c0", new: "a1"),
                     move(5, .checkout(from: "a", to: "b"), old: "a1", new: "a1"),
                     move(8, .commit, old: "a1", new: "b1"),
                     move(9, .checkout(from: "b", to: "a"), old: "b1", new: "a1"),
                     move(12, .commit, old: "a1", new: "a2")]
        let git = GitHistory(checkout: repo, commits: commits,
                             branches: [GitHistory.Branch(name: "main", head: sha("c0"), isRemote: false),
                                        GitHistory.Branch(name: "a", head: sha("a2"), isRemote: false),
                                        GitHistory.Branch(name: "b", head: sha("b1"), isRemote: false)],
                             headMoves: moves)
        let trail = SessionTrail(sourceID: "claude", sessionID: "s", projectPath: repo, createdAt: at(2), latestActivity: at(11),
                                 edits: [edit(2), edit(3), edit(6), edit(7), edit(10), edit(11)])
        let map = build([trail], git: git, now: 30)
        let runs = map.spans.sorted { $0.index < $1.index }
        XCTAssertEqual(runs.map(\.laneID), ["branch:a", "branch:b", "branch:a"])
        XCTAssertEqual(ProjectMap.stages(runs), [["branch:a"], ["branch:b"], ["branch:a"]])
    }

    func testRejoinedRunsDoNotJoinAcrossAMoveToAnotherLane() {
        func run(_ lane: String, _ from: Double, _ to: Double, _ index: Int) -> ProjectMap.Span {
            ProjectMap.Span(sessionKey: "s", index: index, sourceID: "claude", sessionID: "s", otherIDs: [], laneID: lane,
                            start: at(from), end: at(to), direct: [at(from)], delegated: [], spawnedThreads: 0, live: nil,
                            slot: 0, overflow: 0)
        }
        // Two branches folded into one stream, with a hotfix between them.
        let joined = ProjectMap.rejoined([run("stream", 0, 5, 0), run("hotfix", 7, 9, 1), run("stream", 11, 15, 2),
                                          run("stream", 16, 20, 3)], runBreak: 20 * 60)
        XCTAssertEqual(joined.sorted { $0.index < $1.index }.map(\.laneID), ["stream", "hotfix", "stream"])
    }

    func testFoldingKeepsAnIntegrationBranchOutOfTheBundleSharingItsPrefix() throws {
        // wave/a–c are worked on side by side and merge into wave/int; fifteen unrelated
        // branches push the map past the fold threshold.
        var commits = [GitHistory.Commit(sha: sha("c0"), parents: [], tree: "t0", date: at(0), subject: "First")]
        var branches = [GitHistory.Branch(name: "main", head: sha("c0"), isRemote: false)]
        var merged = sha("c0")
        for (index, name) in ["a", "b", "c"].enumerated() {
            commits.append(GitHistory.Commit(sha: sha(name + "1"), parents: [sha("c0")], tree: "t" + name, date: at(41),
                                             subject: name))
            commits.append(GitHistory.Commit(sha: sha("m\(index)"), parents: [merged, sha(name + "1")], tree: "tm\(index)",
                                             date: at(Double(42 + index)), subject: "Merge " + name))
            merged = sha("m\(index)")
            branches.append(GitHistory.Branch(name: "wave/" + name, head: sha(name + "1"), isRemote: false))
        }
        branches.append(GitHistory.Branch(name: "wave/int", head: merged, isRemote: false))
        let names = ["wave/a", "wave/b", "wave/c"]
        var trails = [worktreeSession("fan", (0..<30).map { (minutes: Double($0), branch: names[$0 % 3]) })]
        for index in 0..<15 {
            let name = "solo\(index)"
            commits.append(GitHistory.Commit(sha: sha("x\(index)"), parents: [sha("c0")], tree: "tx\(index)",
                                             date: at(Double(100 + index * 30)), subject: name))
            branches.append(GitHistory.Branch(name: name, head: sha("x\(index)"), isRemote: false))
            trails.append(worktreeSession(name, [(minutes: Double(98 + index * 30), branch: name)]))
        }
        let git = GitHistory(checkout: repo, commits: commits, branches: branches, headMoves: [])
        let map = ProjectMap.build(MapSnapshot(projectPath: repo, takenAt: at(700), sources: [], trails: trails, git: git),
                                   range: .all, calendar: utc, collapseAbove: 14)
        XCTAssertNotNil(map.unfoldedBranchCount)
        let bundle = try XCTUnwrap(map.bundles.first)
        XCTAssertEqual(bundle.laneIDs, ["branch:wave/a", "branch:wave/b", "branch:wave/c"])
        XCTAssertEqual(bundle.parentID, "branch:wave/int")
        XCTAssertNil(try XCTUnwrap(map.lane("branch:wave/int")).bundle)
    }

    func testABranchOfAnIntegrationBranchFillsAGapBelowIt() throws {
        // integrate runs all along; z starts later on the row below; k, merged into
        // integrate early on, fits on z's row before z rather than on a row of its own.
        let commits = [GitHistory.Commit(sha: sha("c0"), parents: [], tree: "t0", date: at(0), subject: "First"),
                       GitHistory.Commit(sha: sha("i0"), parents: [sha("c0")], tree: "ti0", date: at(1), subject: "Start"),
                       GitHistory.Commit(sha: sha("k1"), parents: [sha("c0")], tree: "tk", date: at(15), subject: "K"),
                       GitHistory.Commit(sha: sha("m1"), parents: [sha("i0"), sha("k1")], tree: "tm", date: at(18), subject: "Merge k"),
                       GitHistory.Commit(sha: sha("i2"), parents: [sha("m1")], tree: "ti2", date: at(99), subject: "More"),
                       GitHistory.Commit(sha: sha("z1"), parents: [sha("c0")], tree: "tz", date: at(71), subject: "Z")]
        let git = GitHistory(checkout: repo, commits: commits,
                             branches: [GitHistory.Branch(name: "main", head: sha("c0"), isRemote: false),
                                        GitHistory.Branch(name: "integrate", head: sha("i2"), isRemote: false),
                                        GitHistory.Branch(name: "k", head: sha("k1"), isRemote: false),
                                        GitHistory.Branch(name: "z", head: sha("z1"), isRemote: false)],
                             headMoves: [])
        let trails = [worktreeSession("i", stride(from: 0.0, through: 100, by: 10).map { (minutes: $0, branch: "integrate") }),
                      worktreeSession("k", [(minutes: 10, branch: "k"), (minutes: 14, branch: "k")]),
                      worktreeSession("z", [(minutes: 60, branch: "z"), (minutes: 70, branch: "z")])]
        let map = build(trails, git: git, now: 120)
        XCTAssertEqual(map.lane("branch:k")?.parentID, "branch:integrate")
        let integrate = try XCTUnwrap(map.lane("branch:integrate")).row
        XCTAssertEqual(try XCTUnwrap(map.lane("branch:z")).row, integrate + 1)
        XCTAssertEqual(try XCTUnwrap(map.lane("branch:k")).row, integrate + 1)
    }

    func testRejoinedRunsKeepTheLiveStatusOnTheLatestEdit() {
        func run(_ lane: String, _ from: Double, _ to: Double, _ index: Int, live: String? = nil) -> ProjectMap.Span {
            ProjectMap.Span(sessionKey: "s", index: index, sourceID: "claude", sessionID: "s", otherIDs: [], laneID: lane,
                            start: at(from), end: at(to), direct: [at(from), at(to)], delegated: [], spawnedThreads: 0,
                            live: live, slot: 0, overflow: 0)
        }
        // The run that started last ended first.
        let joined = ProjectMap.rejoined([run("x", 0, 50, 0, live: "working"), run("y", 20, 30, 1)], runBreak: 3_600)
        XCTAssertEqual(joined.first { $0.live != nil }?.laneID, "x")
    }

    func testBranchesWorkedOnSideBySideShareARowAsABundle() throws {
        let branches = ["wave/a", "wave/b", "wave/c"]
        var fan = (0..<30).map { (minutes: Double(10 + $0), branch: branches[$0 % 3]) }
        // Afterwards the same session works on its own branch: no side-by-side work there.
        fan += [(minutes: 60, branch: "wave/d"), (minutes: 70, branch: "wave/d")]
        // Two agents of one workflow run, one after the other, bundle as well.
        let agents = worktreeSession("wf", [(minutes: 100, branch: "worktree-wf_abc12345-111-1"),
                                            (minutes: 105, branch: "worktree-wf_abc12345-111-1"),
                                            (minutes: 140, branch: "worktree-wf_abc12345-111-2")])
        let snapshot = MapSnapshot(projectPath: repo, takenAt: at(200), sources: [], trails: [worktreeSession("fan", fan), agents],
                                   git: nil)
        let map = ProjectMap.build(snapshot, range: .all, calendar: utc, collapseAbove: 14)
        XCTAssertEqual(map.bundles.count, 2)
        let wave = try XCTUnwrap(map.bundles.first { $0.title == "wave/* · 3" })
        XCTAssertEqual(wave.laneIDs, ["branch:wave/a", "branch:wave/b", "branch:wave/c"])
        XCTAssertEqual(wave.id, "branch:wave/a")
        XCTAssertEqual(wave.parentID, "branch:main")
        let strands = wave.laneIDs.compactMap(map.lane)
        XCTAssertEqual(strands.map(\.strand), [0, 1, 2])
        XCTAssertEqual(Set(strands.map(\.row)).count, 1)
        XCTAssertNil(map.lane("branch:wave/d")?.bundle)
        let workflow = try XCTUnwrap(map.bundles.first { $0.laneIDs.count == 2 })
        XCTAssertEqual(workflow.title, "workflow abc12345 · 2 agents")
        XCTAssertNil(map.unfoldedBranchCount)
        // Every branch on its own lane: no bundles.
        XCTAssertTrue(ProjectMap.build(snapshot, range: .all, calendar: utc).bundles.isEmpty)
    }

    func testABranchTheSideBySideWorkMergedIntoKeepsItsOwnRow() throws {
        // Three agents' branches merge into `integrate`, which the same session also edited.
        var commits = [GitHistory.Commit(sha: sha("c0"), parents: [], tree: "t0", date: at(0), subject: "First")]
        var branches = [GitHistory.Branch(name: "main", head: sha("c0"), isRemote: false)]
        var merged = sha("c0")
        for (index, name) in ["a", "b", "c"].enumerated() {
            commits.append(GitHistory.Commit(sha: sha(name + "1"), parents: [sha("c0")], tree: "t" + name, date: at(41),
                                             subject: name))
            commits.append(GitHistory.Commit(sha: sha("m\(index)"), parents: [merged, sha(name + "1")], tree: "tm\(index)",
                                             date: at(Double(42 + index)), subject: "Merge " + name))
            merged = sha("m\(index)")
            branches.append(GitHistory.Branch(name: name, head: sha(name + "1"), isRemote: false))
        }
        branches.append(GitHistory.Branch(name: "integrate", head: merged, isRemote: false))
        let git = GitHistory(checkout: repo, commits: commits, branches: branches, headMoves: [])
        let names = ["a", "b", "c", "integrate"]
        let edits = (0..<40).map { (minutes: Double($0), branch: names[$0 % 4]) }
        let map = ProjectMap.build(MapSnapshot(projectPath: repo, takenAt: at(60), sources: [], trails: [worktreeSession("s", edits)],
                                               git: git), range: .all, calendar: utc, collapseAbove: 14)
        let bundle = try XCTUnwrap(map.bundles.first)
        XCTAssertEqual(bundle.laneIDs, ["branch:a", "branch:b", "branch:c"])
        XCTAssertEqual(map.lane("branch:a")?.merge?.intoLaneID, "branch:integrate")
        XCTAssertEqual(bundle.parentID, "branch:integrate")
        XCTAssertNil(map.lane("branch:integrate")?.bundle)
        XCTAssertGreaterThan(try XCTUnwrap(map.lane("branch:a")).row, try XCTUnwrap(map.lane("branch:integrate")).row)
    }

    func testWorkflowAgentsAndBundlesGoByShortNames() {
        XCTAssertEqual(ProjectMap.workflowAgent("worktree-wf_28a8e52d-996-3")?.run, "28a8e52d-996")
        XCTAssertEqual(ProjectMap.workflowAgent("Worktree · wf_28a8e52d-996-12")?.agent, "12")
        XCTAssertNil(ProjectMap.workflowAgent("feature/wf-thing"))
        XCTAssertEqual(ProjectMap.displayTitle("worktree-wf_28a8e52d-996-3"), "workflow 28a8e52d · agent 3")
        XCTAssertEqual(ProjectMap.displayTitle("Worktree · b8-editor"), "b8-editor")
        XCTAssertEqual(ProjectMap.displayTitle("nv/billing"), "nv/billing")
        let run = ["worktree-wf_28a8e52d-996-1", "worktree-wf_28a8e52d-996-2"]
        XCTAssertEqual(ProjectMap.bundleTitle(run), "workflow 28a8e52d · 2 agents")
        XCTAssertEqual(ProjectMap.strandTitle(run[1], among: run), "agent 2")
        let runs = run + ["worktree-wf_fc53c901-e94-1"]
        XCTAssertEqual(ProjectMap.bundleTitle(runs), "3 agents · 2 workflows")
        XCTAssertEqual(ProjectMap.strandTitle(runs[2], among: runs), "fc53c901 · agent 1")
        XCTAssertEqual(ProjectMap.bundleTitle(["mob/editor", "mob/shell", "mob/zoom"]), "mob/* · 3")
        XCTAssertEqual(ProjectMap.strandTitle("mob/shell", among: ["mob/editor", "mob/shell"]), "shell")
        XCTAssertEqual(ProjectMap.strandTitle("Worktree · b8-editor", among: ["Worktree · b8-editor", "Worktree · b8-hide"]),
                       "editor")
        XCTAssertEqual(ProjectMap.bundleTitle(["i162/work", "i160/work", "i161/work"]), "i162/work +2")
        XCTAssertEqual(ProjectMap.bundleShortTitle(["i162/work", "i160/work", "i161/work"]), "3 branches")
        XCTAssertEqual(ProjectMap.bundleShortTitle(runs), "3 agents")
        XCTAssertEqual(ProjectMap.bundleShortTitle(["mob/editor", "mob/shell"]), "mob/* · 2")
        // A worktree folder's "mob-" reads as its branches' "mob/".
        XCTAssertEqual(ProjectMap.bundleShortTitle(["mob/editor", "Worktree · mob-review"]), "mob/* · 2")
        XCTAssertEqual(ProjectMap.strandTitle("Worktree · mob-review", among: ["mob/editor", "Worktree · mob-review"]), "review")
        XCTAssertEqual(ProjectMap.streamTitle("wf_28a8e52d-996", count: 4), "workflow 28a8e52d · 4 agents")
    }

    func testStagesSplitWhereOneRunHandsOverToTheNext() {
        func run(_ lane: String, _ from: Double, _ to: Double, _ index: Int) -> ProjectMap.Span {
            ProjectMap.Span(sessionKey: "s", index: index, sourceID: "claude", sessionID: "s", otherIDs: [], laneID: lane,
                            start: at(from), end: at(to), direct: [], delegated: [], spawnedThreads: 0, live: nil, slot: 0,
                            overflow: 0)
        }
        // Two branches side by side, a third begun inside them, then a handover that only
        // overlaps the last minutes, then the same branch again after a pause.
        let runs = [run("a", 0, 60, 0), run("b", 5, 55, 1), run("c", 30, 30, 2), run("d", 57, 120, 3), run("d", 140, 150, 4)]
        XCTAssertEqual(ProjectMap.stages(runs), [["a", "b", "c"], ["d"]])
        XCTAssertEqual(ProjectMap.activeTime(runs), 130 * 60)
        XCTAssertTrue(ProjectMap.sideBySide(at(0)...at(60), at(5)...at(55)))
        XCTAssertFalse(ProjectMap.sideBySide(at(0)...at(60), at(57)...at(120)))
    }

    func testOverlappingSessionsStackThreeDeep() {
        let trails = (0..<4).map { index in
            SessionTrail(sourceID: "claude", sessionID: "s\(index)", projectPath: repo, createdAt: at(Double(index)),
                         latestActivity: at(30), edits: [edit(10), edit(20)])
        }
        let map = build(trails, git: nil, now: 60)
        XCTAssertEqual(map.spans.map(\.slot).sorted(), [0, 1, 2, 2])
        XCTAssertEqual(map.spans.filter { $0.overflow > 0 }.count, 1)
    }

    func testRangeKeepsOnlyWorkInsideIt() {
        let day: Double = 24 * 60
        let trails = [
            SessionTrail(sourceID: "codex", sessionID: "old", projectPath: repo, createdAt: at(0), latestActivity: at(10),
                         edits: [edit(5)]),
            SessionTrail(sourceID: "codex", sessionID: "spanning", projectPath: repo, createdAt: at(0),
                         latestActivity: at(3 * day + 130), edits: [edit(20), edit(3 * day + 120)])
        ]
        let map = build(trails, git: nil, now: 3 * day + 200, range: .today)
        XCTAssertEqual(map.spans.map(\.sessionID), ["spanning"])
        XCTAssertEqual(map.spans.first?.edits, [at(3 * day + 120)])
        let today = utc.start(of: utc.day(of: at(3 * day + 200)))
        XCTAssertGreaterThanOrEqual(map.axis.start, today)
        XCTAssertEqual(map.lanes.first?.start, map.axis.start)
        XCTAssertEqual(map.sessionCount, 1)
    }
}
