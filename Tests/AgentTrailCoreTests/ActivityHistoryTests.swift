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

    func testSampleHistoryContainsNoPersonalPathsAndCountsAgree() throws {
        let now = DemoData.referenceDate(calendar: Self.gmtPlus3)
        let demo = DemoData.result(now: now, calendar: Self.gmtPlus3)
        XCTAssertEqual(demo.projects.count, 5)
        XCTAssertEqual(demo.projects.filter(\.isShared).count, 3)
        for project in demo.projects {
            XCTAssertTrue(project.path.hasPrefix("/Demo/"))
            XCTAssertEqual(project.sessionCount, project.history.reduce(0) { $0 + $1.sessionCount })
            XCTAssertGreaterThan(project.recordedEditCount, 0)
            for activity in project.activities {
                let dates = activity.editMoments.map(\.date)
                XCTAssertEqual(dates.count, activity.history.reduce(0) { $0 + $1.editCount })
                XCTAssertEqual(activity.sessionStarts.count, activity.history.reduce(0) { $0 + $1.sessionCount })
                XCTAssertEqual(dates, dates.sorted())
                XCTAssertEqual(activity.sessionStarts, activity.sessionStarts.sorted())
                XCTAssertTrue(dates.allSatisfy { $0 <= now })
                XCTAssertEqual(activity.latestEdit, dates.last)
            }
        }
        let days = demo.projects.flatMap(\.history).map(\.day)
        let first = try XCTUnwrap(days.min()), last = try XCTUnwrap(days.max())
        XCTAssertGreaterThanOrEqual(last.timeIntervalSince(first), 150 * 86_400)
        XCTAssertTrue(demo.projects.contains { $0.history.contains { $0.editCount == 0 && $0.sessionCount > 0 } })

        let local = ActivityCalendar(timeZone: Self.gmtPlus3.timeZone)
        let codex = demo.projects.flatMap(\.activities).filter { $0.sourceID == "codex" }.flatMap(\.editMoments)
        let firstCodex = try XCTUnwrap(codex.map(\.date).min())
        let codexAge = local.day(of: firstCodex).days(to: local.day(of: now))
        XCTAssertTrue((60...70).contains(codexAge), "Codex adopted \(codexAge) days ago")
    }

    func testSampleTrendsShowTheStreakAndMomentum() {
        let now = DemoData.referenceDate(calendar: Self.gmtPlus3)
        let demo = DemoData.result(now: now, calendar: Self.gmtPlus3)
        let index = StatsIndex.build(projects: demo.projects, sources: DemoData.sources,
                                     calendar: ActivityCalendar(timeZone: Self.gmtPlus3.timeZone), now: now)
        // The local day eight days ago has no edits; every day since has some.
        XCTAssertEqual(index.pulse.streaks.current, 8)
        XCTAssertEqual(index.trends["/Demo/Projects/field-notes"]?.momentum, .dormant)
        XCTAssertEqual(index.trends["/Demo/Projects/lumen"]?.momentum, .new)
    }

    func testSampleDataRepeatsAtThePinnedClock() {
        let now = DemoData.referenceDate(calendar: Self.gmtPlus3)
        let parts = Self.gmtPlus3.dateComponents([.year, .month, .day, .hour, .minute, .second], from: now)
        XCTAssertEqual([parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second], [2026, 10, 30, 18, 40, 0])

        let first = DemoData.result(now: now, calendar: Self.gmtPlus3)
        let second = DemoData.result(now: now, calendar: Self.gmtPlus3)
        XCTAssertEqual(first.projects.map(\.path), second.projects.map(\.path))
        for (lhs, rhs) in zip(first.projects, second.projects) {
            XCTAssertEqual(lhs.activities.map(\.sourceID), rhs.activities.map(\.sourceID))
            XCTAssertEqual(lhs.activities.map(\.editMoments), rhs.activities.map(\.editMoments))
            XCTAssertEqual(lhs.activities.map(\.sessionStarts), rhs.activities.map(\.sessionStarts))
            XCTAssertEqual(lhs.activities.map(\.history), rhs.activities.map(\.history))
            XCTAssertEqual(lhs.activities.map(\.latestActivity), rhs.activities.map(\.latestActivity))
        }
    }

    /// A fixed zone east of UTC, so local activity days and UTC days disagree.
    private static let gmtPlus3: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 3 * 3_600)!
        return calendar
    }()
}
