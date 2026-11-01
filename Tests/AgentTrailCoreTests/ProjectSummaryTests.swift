import XCTest
@testable import AgentTrailCore

final class ProjectSummaryTests: XCTestCase {
    func testSharedProjectKeepsEditAuthorSeparateFromActivity() {
        let records = [
            ProjectActivity(sourceID: "main", projectPath: "/tmp/example", latestActivity: Date(timeIntervalSince1970: 100), latestEdit: Date(timeIntervalSince1970: 90)),
            ProjectActivity(sourceID: "second", projectPath: "/tmp/example", latestActivity: Date(timeIntervalSince1970: 200), latestEdit: Date(timeIntervalSince1970: 80))
        ]
        let project = ProjectSummary.merge(records)[0]
        XCTAssertTrue(project.isShared)
        XCTAssertEqual(project.latestActivity.sourceID, "second")
        XCTAssertEqual(project.latestEdit?.sourceID, "main")
    }

    func testMergesSameSourceSessionsWithoutFalseSharing() {
        let records = [
            ProjectActivity(sourceID: "main", projectPath: "/tmp/example", latestActivity: Date(timeIntervalSince1970: 10), latestEdit: Date(timeIntervalSince1970: 9)),
            ProjectActivity(sourceID: "main", projectPath: "/tmp/example/../example", latestActivity: Date(timeIntervalSince1970: 20))
        ]
        let project = ProjectSummary.merge(records)[0]
        XCTAssertFalse(project.isShared)
        XCTAssertEqual(project.activities.count, 1)
        XCTAssertEqual(project.activities[0].sessionCount, 2)
        XCTAssertEqual(project.latestEdit?.latestEdit, Date(timeIntervalSince1970: 9))
    }

    func testDoesNotMergeDistinctCheckoutsWithSameName() {
        let records = [
            ProjectActivity(sourceID: "main", projectPath: "/tmp/one/repo", latestActivity: Date(timeIntervalSince1970: 10)),
            ProjectActivity(sourceID: "second", projectPath: "/tmp/two/repo", latestActivity: Date(timeIntervalSince1970: 20))
        ]
        let projects = ProjectSummary.merge(records)
        XCTAssertEqual(projects.count, 2)
        XCTAssertFalse(projects.contains(where: \.isShared))
        XCTAssertEqual(projects[0].path, "/tmp/two/repo")
    }

    func testResolvesSymlinksToSameCheckout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("real"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: root.appendingPathComponent("real"))
        let records = [
            ProjectActivity(sourceID: "main", projectPath: root.appendingPathComponent("real").path, latestActivity: Date()),
            ProjectActivity(sourceID: "second", projectPath: root.appendingPathComponent("alias").path, latestActivity: Date())
        ]
        XCTAssertEqual(ProjectSummary.merge(records).count, 1)
        XCTAssertTrue(ProjectSummary.merge(records)[0].isShared)
    }

    func testPreservesEditWorktreeWhenLatestActivityMovedElsewhere() {
        let records = [
            ProjectActivity(sourceID: "main", projectPath: "/tmp/repo", latestActivity: Date(timeIntervalSince1970: 100), latestEdit: Date(timeIntervalSince1970: 90), workspacePath: "/tmp/repo/.claude/worktrees/feature", latestEditWorkspacePath: "/tmp/repo/.claude/worktrees/feature"),
            ProjectActivity(sourceID: "main", projectPath: "/tmp/repo", latestActivity: Date(timeIntervalSince1970: 200), workspacePath: "/tmp/repo")
        ]
        let project = ProjectSummary.merge(records)[0]
        XCTAssertEqual(project.latestActivity.workspacePath, "/tmp/repo")
        XCTAssertEqual(project.latestEdit?.latestEditWorkspacePath, "/tmp/repo/.claude/worktrees/feature")
    }

    func testMergeConcatenatesAndSortsMomentsPerSource() throws {
        func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }
        let records: [ProjectActivity] = [
            ProjectActivity(sourceID: "main", projectPath: "/tmp/example", latestActivity: at(100), latestEdit: at(90),
                editMoments: [EditMoment(date: at(30)), EditMoment(date: at(60), delegated: true), EditMoment(date: at(90), delegated: true)],
                sessionStarts: [at(50)]),
            ProjectActivity(sourceID: "main", projectPath: "/tmp/example/../example", latestActivity: at(80), latestEdit: at(60),
                editMoments: [EditMoment(date: at(10)), EditMoment(date: at(60))], sessionStarts: [at(5), at(70)]),
            ProjectActivity(sourceID: "second", projectPath: "/tmp/example", latestActivity: at(40), latestEdit: at(20),
                editMoments: [EditMoment(date: at(20), delegated: true)], sessionStarts: [at(15)])
        ]
        let project = try XCTUnwrap(ProjectSummary.merge(records).first)
        let main = try XCTUnwrap(project.activities.first { $0.sourceID == "main" })
        let second = try XCTUnwrap(project.activities.first { $0.sourceID == "second" })
        // At the same instant a direct edit sorts before a delegated one.
        XCTAssertEqual(main.editMoments, [EditMoment(date: at(10)), EditMoment(date: at(30)), EditMoment(date: at(60)),
            EditMoment(date: at(60), delegated: true), EditMoment(date: at(90), delegated: true)])
        XCTAssertEqual(main.sessionStarts, [at(5), at(50), at(70)])
        XCTAssertEqual(second.editMoments, [EditMoment(date: at(20), delegated: true)])
        XCTAssertEqual(second.sessionStarts, [at(15)])
    }

    func testOverviewOfCanonicalAliasesKeepsOneActivitysMoments() throws {
        func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }
        let older = ProjectActivity(sourceID: "main", projectPath: "/Demo/Project",
            latestActivity: at(200), latestEdit: at(150), sessionCount: 1,
            history: [ActivityDay(day: at(100), editCount: 2, sessionCount: 1)],
            editMoments: [EditMoment(date: at(100)), EditMoment(date: at(150), delegated: true)], sessionStarts: [at(50)])
        let newer = ProjectActivity(sourceID: "main", projectPath: "/Demo/../Demo/Project",
            latestActivity: at(300), latestEdit: at(250), sessionCount: 2,
            history: [ActivityDay(day: at(100), editCount: 3, sessionCount: 2)],
            editMoments: [EditMoment(date: at(100)), EditMoment(date: at(150), delegated: true), EditMoment(date: at(250))],
            sessionStarts: [at(50), at(260)])
        let snapshots = [ProjectSummary(path: "/Demo/Project", activities: [older]),
                         ProjectSummary(path: "/Demo/../Demo/Project", activities: [newer])]
        let orders: [[ProjectSummary]] = [snapshots, snapshots.reversed()]
        for input in orders {
            let overviews = ProjectOverview.merge(projects: input, sessions: [])
            XCTAssertEqual(overviews.count, 1)
            let activity = try XCTUnwrap(overviews.first?.history?.activities.first)
            XCTAssertEqual(activity.editMoments, newer.editMoments)
            XCTAssertEqual(activity.sessionStarts, newer.sessionStarts)
            XCTAssertEqual(activity.editMoments.count, activity.history.reduce(0) { $0 + $1.editCount })
        }
    }
}
