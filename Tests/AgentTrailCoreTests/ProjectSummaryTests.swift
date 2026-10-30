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
}
