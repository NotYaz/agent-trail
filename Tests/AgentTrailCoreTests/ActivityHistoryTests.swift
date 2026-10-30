import XCTest
@testable import AgentTrailCore

final class ActivityHistoryTests: XCTestCase {
    func testUTCNormalizationAndSameDayMerge() {
        let day = Date(timeIntervalSince1970: 86_400)
        let records = [ActivityDay(day: day.addingTimeInterval(30), editCount: 2, sessionCount: 1),
                       ActivityDay(day: day.addingTimeInterval(80_000), editCount: 3, sessionCount: 2)]
        XCTAssertEqual(ActivityDay.merge(records), [ActivityDay(day: day, editCount: 5, sessionCount: 3)])
    }

    func testProjectMergePreservesPerProfileCountsAndDailyTotals() {
        let day = Date(timeIntervalSince1970: 86_400)
        let records = [
            ProjectActivity(sourceID: "main", projectPath: "/Demo/project", latestActivity: day, sessionCount: 2,
                history: [ActivityDay(day: day, editCount: 5, sessionCount: 2)]),
            ProjectActivity(sourceID: "second", projectPath: "/Demo/project", latestActivity: day, sessionCount: 3,
                history: [ActivityDay(day: day, editCount: 7, sessionCount: 3)])
        ]
        let project = ProjectSummary.merge(records)[0]
        XCTAssertEqual(project.recordedEditCount, 12)
        XCTAssertEqual(project.sessionCount, 5)
        XCTAssertEqual(project.history[0].sessionCount, 5)
        XCTAssertEqual(project.activities.first { $0.sourceID == "main" }?.history[0].editCount, 5)
    }

    func testSampleHistoryContainsNoPersonalPathsAndCountsAgree() {
        let demo = DemoData.result(now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(demo.projects.count, 3)
        XCTAssertEqual(demo.projects.filter(\.isShared).count, 2)
        for project in demo.projects {
            XCTAssertTrue(project.path.hasPrefix("/Demo/"))
            XCTAssertEqual(project.sessionCount, project.history.reduce(0) { $0 + $1.sessionCount })
            XCTAssertGreaterThan(project.recordedEditCount, 0)
        }
    }
}
