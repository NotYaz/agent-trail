import Foundation
import XCTest
@testable import AgentTrailCore

final class ProjectLiveActivityTests: XCTestCase {
    func testProjectAndSourceCountsKeepUnknownDistinctFromIdle() throws {
        let records = [
            session(source: "main", id: "working", pid: 10, status: .working),
            session(source: "main", id: "unknown", pid: 11, status: .unknown),
            session(source: "second", id: "idle", pid: 12, status: .idle)
        ]
        let project = try XCTUnwrap(ProjectLiveActivity.group(records)["/Demo/Project"])
        XCTAssertEqual(project.sessions.count, 3)
        XCTAssertEqual(project.workingCount, 1)
        XCTAssertEqual(project.idleCount, 1)
        XCTAssertEqual(project.unknownCount, 1)
        XCTAssertEqual(project.sources.map(\.sourceID), ["main", "second"])
        XCTAssertEqual(project.sources[0].workingCount, 1)
        XCTAssertEqual(project.sources[0].idleCount, 0)
        XCTAssertEqual(project.sources[0].unknownCount, 1)
        XCTAssertEqual(project.sources[1].idleCount, 1)
    }

    func testCanonicalOriginJoinsAliasesWhilePreservingActualWorktreesAndIDs() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("AgentTrailGrouping-" + UUID().uuidString)
        let project = root.appendingPathComponent("real")
        let alias = root.appendingPathComponent("alias")
        let firstWorktree = project.appendingPathComponent(".claude/worktrees/first")
        let secondWorktree = project.appendingPathComponent(".claude/worktrees/second")
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [firstWorktree, secondWorktree] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        let records = [
            session(project: alias.path, workspace: alias.appendingPathComponent(".claude/worktrees/first").path, id: "first", pid: 10),
            session(project: project.appendingPathComponent("../real").path, workspace: secondWorktree.path, id: "second", pid: 11)
        ]
        let grouped = ProjectLiveActivity.group(records)
        XCTAssertEqual(grouped.count, 1)
        let live = try XCTUnwrap(grouped[project.path])
        XCTAssertEqual(live.workspacePaths, [firstWorktree.path, secondWorktree.path])
        XCTAssertEqual(Set(live.sessions.map(\.id)), Set(records.map(\.id)))
        XCTAssertEqual(live.sources[0].workspacePaths, live.workspacePaths)
    }

    func testRepeatedCopiesDoNotInflateCountsAndNewestCopyWins() throws {
        let old = session(status: .idle, updated: 100)
        let newest = session(project: "/Demo/../Demo/Project", status: .working, updated: 200)
        let records = [old, newest, newest, old]
        let live = try XCTUnwrap(ProjectLiveActivity.group(records)["/Demo/Project"])
        XCTAssertEqual(live.sessions.count, 1)
        XCTAssertEqual(live.workingCount, 1)
        XCTAssertEqual(live.idleCount, 0)
        XCTAssertEqual(live.sessions[0].id, old.id)
        XCTAssertEqual(live.sessions[0].updatedAt, Date(timeIntervalSince1970: 200))
    }

    func testDistinctPIDsAndSourcesKeepTheirOwnSessionIdentity() throws {
        let records = [
            session(source: "main", id: "shared-cli-id", pid: 10),
            session(source: "main", id: "shared-cli-id", pid: 11),
            session(source: "second", id: "shared-cli-id", pid: 10)
        ]
        let live = try XCTUnwrap(ProjectLiveActivity.group(records)["/Demo/Project"])
        XCTAssertEqual(live.sessions.count, 3)
        XCTAssertEqual(Set(live.sessions.map(\.id)).count, 3)
        XCTAssertEqual(live.sources[0].sessions.count, 2)
        XCTAssertEqual(live.sources[1].sessions.count, 1)
    }

    func testEqualTimeStatusConflictBecomesUnknownRatherThanWorking() throws {
        let records = [session(status: .working), session(status: .idle)]
        let first = try XCTUnwrap(ProjectLiveActivity.group(records)["/Demo/Project"])
        let reversed = try XCTUnwrap(ProjectLiveActivity.group(records.reversed())["/Demo/Project"])
        XCTAssertEqual(first.sessions.count, 1)
        XCTAssertEqual(first.workingCount, 0)
        XCTAssertEqual(first.idleCount, 0)
        XCTAssertEqual(first.unknownCount, 1)
        XCTAssertEqual(first.sessions[0].status, reversed.sessions[0].status)
    }

    func testMovedSessionIsAssignedOnlyToNewestOriginAndAmbiguousClaimsAreOmitted() {
        let old = session(project: "/Demo/Old", updated: 100)
        let newest = session(project: "/Demo/New", updated: 200)
        let moved = ProjectLiveActivity.group([old, newest])
        XCTAssertNil(moved["/Demo/Old"])
        XCTAssertEqual(moved["/Demo/New"]?.sessions.count, 1)
        XCTAssertTrue(ProjectLiveActivity.group([old, session(project: "/Demo/Other", updated: 100)]).isEmpty)
    }

    func testMissingProjectAndRecentHistoryNeverManufactureIdleOrWorking() throws {
        XCTAssertTrue(ProjectLiveActivity.group([]).isEmpty)
        let summary = history(path: "/Demo/Project", source: "main", activity: 1_000)
        let overview = try XCTUnwrap(ProjectOverview.merge(projects: [summary], sessions: []).first)
        XCTAssertNotNil(overview.history)
        XCTAssertNil(overview.live)
        XCTAssertEqual(overview.sourceIDs, ["main"])
        let unknown = session(status: .unknown, updated: 10)
        let withUnknown = try XCTUnwrap(ProjectOverview.merge(projects: [summary], sessions: [unknown]).first)
        XCTAssertEqual(withUnknown.live?.workingCount, 0)
        XCTAssertEqual(withUnknown.live?.idleCount, 0)
        XCTAssertEqual(withUnknown.live?.unknownCount, 1)
    }

    func testLiveOnlyProjectHasNoFabricatedHistoricalActivityOrEditCount() throws {
        let live = session(project: "/Demo/LiveOnly", status: .working)
        let overview = try XCTUnwrap(ProjectOverview.merge(projects: [], sessions: [live]).first)
        XCTAssertEqual(overview.path, "/Demo/LiveOnly")
        XCTAssertEqual(overview.id, overview.path)
        XCTAssertEqual(overview.name, "LiveOnly")
        XCTAssertNil(overview.history)
        XCTAssertEqual(overview.live?.workingCount, 1)
        XCTAssertFalse(overview.isShared)
    }

    func testOverviewUnionsHistoricalAndLiveSourcesWithoutConflatingSameBasenames() throws {
        let histories = [history(path: "/Demo/First/Project", source: "main", activity: 100),
                         history(path: "/Demo/Second/Project", source: "other", activity: 100)]
        let records = [session(source: "second", project: "/Demo/First/Project", id: "second", status: .idle)]
        let overview = ProjectOverview.merge(projects: histories, sessions: records)
        XCTAssertEqual(overview.count, 2)
        XCTAssertEqual(Set(overview.map(\.name)), ["Project"])
        let shared = try XCTUnwrap(overview.first { $0.path == "/Demo/First/Project" })
        XCTAssertEqual(shared.sourceIDs, ["main", "second"])
        XCTAssertTrue(shared.isShared)
        XCTAssertEqual(shared.live?.sources.map(\.sourceID), ["second"])
        XCTAssertNil(overview.first { $0.path == "/Demo/Second/Project" }?.live)
    }

    func testOverviewWorkingPresenceSortsFirstThenHistoryDateAndStablePath() {
        let histories = [history(path: "/Demo/A", activity: 300), history(path: "/Demo/B", activity: 200),
                         history(path: "/Demo/C", activity: 900), history(path: "/Demo/F", activity: 900),
                         ProjectSummary(path: "/Demo/D", activities: [])]
        let records = [session(project: "/Demo/A", id: "a", pid: 1, updated: 1),
                       session(project: "/Demo/B", id: "b", pid: 2, updated: 999),
                       session(project: "/Demo/B", id: "b", pid: 3, updated: 999),
                       session(project: "/Demo/B", id: "b", pid: 4, updated: 999),
                       session(project: "/Demo/E", id: "e", pid: 5, status: .idle, updated: 1_000)]
        let result = ProjectOverview.merge(projects: histories, sessions: records)
        XCTAssertEqual(result.map(\.path), ["/Demo/A", "/Demo/B", "/Demo/E", "/Demo/C", "/Demo/F", "/Demo/D"])
        XCTAssertEqual(ProjectOverview.merge(projects: histories.reversed(), sessions: records.reversed()).map(\.path), result.map(\.path))
        XCTAssertEqual(result.first { $0.path == "/Demo/D" }?.history?.activities.count, 0)
    }

    func testCanonicalHistoricalCopiesDoNotMultiplyExistingStatistics() throws {
        let original = history(path: "/Demo/Project", activity: 100, edits: 3, sessions: 2)
        let copy = history(path: "/Demo/../Demo/Project", activity: 100, edits: 3, sessions: 2)
        let live = session(project: "/Demo/Project", status: .idle)
        let overview = try XCTUnwrap(ProjectOverview.merge(projects: [original, copy, original], sessions: [live]).first)
        XCTAssertEqual(overview.history?.recordedEditCount, 3)
        XCTAssertEqual(overview.history?.sessionCount, 2)
        XCTAssertEqual(overview.live?.sessions.count, 1)
    }

    func testCanonicalHistoricalCopiesPreserveIndependentActivityAndEditLeaders() throws {
        let editWorkspace = "/Demo/Project/.claude/worktrees/edit-leader"
        let activityWorkspace = "/Demo/Project/.claude/worktrees/activity-leader"
        let edited = ProjectActivity(sourceID: "main", projectPath: "/Demo/Project",
            latestActivity: Date(timeIntervalSince1970: 200), latestEdit: Date(timeIntervalSince1970: 190),
            sessionCount: 2, workspacePath: editWorkspace, latestEditWorkspacePath: editWorkspace)
        let active = ProjectActivity(sourceID: "main", projectPath: "/Demo/../Demo/Project",
            latestActivity: Date(timeIntervalSince1970: 300), latestEdit: Date(timeIntervalSince1970: 100),
            sessionCount: 3, workspacePath: activityWorkspace, latestEditWorkspacePath: activityWorkspace)
        let snapshots = [ProjectSummary(path: "/Demo/Project", activities: [edited]),
                         ProjectSummary(path: "/Demo/../Demo/Project", activities: [active])]
        let result = ProjectOverview.merge(projects: snapshots, sessions: [])
        let summary = try XCTUnwrap(result.first?.history)
        XCTAssertEqual(summary.latestActivity.latestActivity, Date(timeIntervalSince1970: 300))
        XCTAssertEqual(summary.latestActivity.workspacePath, activityWorkspace)
        XCTAssertEqual(summary.latestEdit?.latestEdit, Date(timeIntervalSince1970: 190))
        XCTAssertEqual(summary.latestEdit?.latestEditWorkspacePath, editWorkspace)
        XCTAssertEqual(summary.sessionCount, 3)
        let reversed = ProjectOverview.merge(projects: snapshots.reversed(), sessions: [])
        XCTAssertEqual(reversed.first?.history?.latestEdit?.latestEditWorkspacePath, editWorkspace)
    }

    func testInvalidProjectPathsDoNotBecomeCurrentDirectoryGroups() {
        let records = [session(project: ""), session(project: "relative-project", id: "relative")]
        XCTAssertTrue(ProjectLiveActivity.group(records).isEmpty)
        XCTAssertTrue(ProjectOverview.merge(projects: [], sessions: records).isEmpty)
    }

    private func session(source: String = "main", project: String = "/Demo/Project", workspace: String? = nil,
                         id: String = "session", pid: Int32 = 10, status: LiveStatus = .working,
                         updated: TimeInterval = 100) -> LiveAgentSession {
        LiveAgentSession(sourceID: source, projectPath: project, workspacePath: workspace ?? project,
            sessionID: id, status: status, updatedAt: Date(timeIntervalSince1970: updated), pid: pid)
    }

    private func history(path: String, source: String = "main", activity: TimeInterval,
                         edits: Int = 0, sessions: Int = 1) -> ProjectSummary {
        ProjectSummary.merge([ProjectActivity(sourceID: source, projectPath: path,
            latestActivity: Date(timeIntervalSince1970: activity), sessionCount: sessions,
            history: [ActivityDay(day: Date(timeIntervalSince1970: activity), editCount: edits, sessionCount: sessions)])])[0]
    }
}
