import Foundation
import XCTest
@testable import AgentTrailCore

final class ActivityStatisticsTests: XCTestCase {
    private let calendar = ActivityCalendar(timeZone: TimeZone(identifier: "Europe/Moscow")!)
    /// Saturday 2026-10-31, 12:00 in Moscow.
    private let now = Date(timeIntervalSince1970: Double(20_757 * 86_400 + 9 * 3_600))
    private let today = DayKey(year: 2026, month: 10, day: 31)
    private let sources = AgentSource.defaults(home: "/Demo")
    private let main = "claude-primary", second = "claude-second", codex = "codex", grok = "grok"
    private let orbit = "/Demo/Projects/orbit", harbor = "/Demo/Projects/harbor", atlas = "/Demo/Projects/atlas"

    // MARK: Windows and totals

    func testWindowsEndTodayAndPreviousWindowIsAdjacent() {
        let index = build([project(orbit, [activity(main, edits: edits(0) + edits(6) + edits(7) + edits(13) + edits(14),
                                                    sessions: [at(40)])])])
        let week = index.statistics(projectPath: nil, period: .week)
        XCTAssertEqual(week.range, DayRange(first: today.adding(days: -6), last: today))
        XCTAssertEqual(week.previousRange, DayRange(first: today.adding(days: -13), last: today.adding(days: -7)))
        XCTAssertEqual(week.current, PeriodTotals(edits: 2, delegatedEdits: 0, sessions: 0, activeDays: 2, dayCount: 7))
        XCTAssertEqual(week.previous?.edits, 2)
        XCTAssertEqual(week.previous?.dayCount, 7)

        let month = index.statistics(projectPath: nil, period: .month)
        XCTAssertEqual(month.range.first, today.adding(days: -29))
        XCTAssertEqual(month.previousRange?.last, today.adding(days: -30))
        XCTAssertEqual(month.current.edits, 5)
        XCTAssertEqual(index.statistics(projectPath: nil, period: .quarter).range.count, 90)

        let all = index.statistics(projectPath: nil, period: .all)
        XCTAssertNil(all.previousRange)
        XCTAssertNil(all.previous)
        XCTAssertEqual(all.range, DayRange(first: today.adding(days: -40), last: today))
        XCTAssertEqual(all.firstRecordedDay, today.adding(days: -40))
        XCTAssertEqual(all.current.edits, 5)
        XCTAssertEqual(all.current.sessions, 1)
    }

    func testChangesNeedSavedHistoryCoveringThePreviousWindow() {
        // History starts 20 days ago: the 7-day comparison is covered, 30 days is not.
        let index = build([project(orbit, [activity(main, edits: edits(20) + edits(10) + edits(1))])])
        XCTAssertEqual(index.historyStart, today.adding(days: -20))
        XCTAssertNotNil(index.statistics(projectPath: nil, period: .week).previous)
        let month = index.statistics(projectPath: nil, period: .month)
        XCTAssertNotNil(month.previousRange)
        XCTAssertNil(month.previous)
        XCTAssertTrue(month.sources.allSatisfy { $0.previousShare == nil })
        XCTAssertTrue(month.projects.allSatisfy { $0.previousEdits == nil })
        XCTAssertEqual(index.trends[orbit]?.hasPrevious7, true)
        XCTAssertEqual(index.trends[orbit]?.hasPrevious30, false)
        XCTAssertTrue(index.pulse.hasPrevious7)

        // Any project's older record extends coverage to every scope.
        let covered = build([project(orbit, [activity(main, edits: edits(1))]),
                             project(harbor, [activity(codex, sessions: [at(70)])])])
        XCTAssertEqual(covered.statistics(projectPath: orbit, period: .month).previous?.edits, 0)
        XCTAssertEqual(covered.trends[orbit]?.hasPrevious30, true)
        XCTAssertFalse(build([]).pulse.hasPrevious7)
    }

    func testSessionsOnlyDaysAreNotActive() {
        let index = build([project(orbit, [activity(main, edits: edits(1), sessions: [at(1), at(2), at(3)])])])
        let week = index.statistics(projectPath: nil, period: .week)
        XCTAssertEqual(week.current.activeDays, 1)
        XCTAssertEqual(week.current.sessions, 3)
        XCTAssertEqual(week.current.editsPerActiveDay, 1)
        XCTAssertEqual(week.streaks.current, 1)
        let sessionDay = week.calendar.cells.first { $0.day == today.adding(days: -2) }
        XCTAssertEqual(sessionDay?.edits, 0)
        XCTAssertEqual(sessionDay?.sessions, 1)
        XCTAssertNil(build([project(orbit, [activity(main, sessions: [at(1)])])])
            .statistics(projectPath: nil, period: .week).current.editsPerActiveDay)
    }

    // MARK: Streaks

    func testStreakGraceDayKeepsYesterdaysRun() {
        let index = build([project(orbit, [activity(main, edits: edits(1) + edits(2) + edits(3))])])
        let streaks = index.statistics(projectPath: nil, period: .week).streaks
        XCTAssertEqual(streaks, StreakSummary(current: 3, longest: 3, longestEnd: today.adding(days: -1)))
        XCTAssertEqual(index.pulse.streaks, streaks)
        XCTAssertEqual(index.trends[orbit]?.currentStreak, 3)
    }

    func testStreakCountsTodayOnceItHasAnEdit() {
        let index = build([project(orbit, [activity(main, edits: edits(0) + edits(1))])])
        XCTAssertEqual(index.statistics(projectPath: orbit, period: .month).streaks.current, 2)
        XCTAssertEqual(index.pulse.streaks.current, 2)
    }

    func testBrokenStreakIsZero() {
        let index = build([project(orbit, [activity(main, edits: edits(2) + edits(3), sessions: [at(0), at(1)])])])
        let streaks = index.statistics(projectPath: nil, period: .week).streaks
        XCTAssertEqual(streaks.current, 0)
        XCTAssertEqual(streaks.longest, 2)
        XCTAssertEqual(index.trends[orbit]?.currentStreak, 0)
    }

    func testLongestStreakTieGoesToTheLatestRunAndSpansFullHistory() {
        let days = [20, 19, 18, 10, 9, 8].flatMap { edits($0) }
        let index = build([project(orbit, [activity(main, edits: days)])])
        let streaks = index.statistics(projectPath: nil, period: .week).streaks
        XCTAssertEqual(streaks, StreakSummary(current: 0, longest: 3, longestEnd: today.adding(days: -8)))
    }

    func testBusiestDayTieGoesToTheLatestDay() {
        let index = build([project(orbit, [
            activity(main, edits: edits(5, count: 3) + edits(2, count: 2)),
            activity(second, edits: edits(2), sessions: [at(2)])
        ])])
        let busiest = index.statistics(projectPath: nil, period: .week).busiestDay
        XCTAssertEqual(busiest, DayTotal(day: today.adding(days: -2), edits: 3, sessions: 1, profiles: 2))
        XCTAssertNil(build([project(orbit, [activity(main, sessions: [at(1)])])])
            .statistics(projectPath: nil, period: .week).busiestDay)
    }

    func testLongestQuietStretchSitsBetweenActiveDays() {
        let index = build([project(orbit, [activity(main, edits: edits(10) + edits(6) + edits(1))])])
        XCTAssertEqual(index.statistics(projectPath: nil, period: .month).longestQuietStretch, 4)
        XCTAssertEqual(index.statistics(projectPath: nil, period: .week).longestQuietStretch, 4)
        let single = build([project(orbit, [activity(main, edits: edits(3, count: 4))])])
        XCTAssertEqual(single.statistics(projectPath: nil, period: .month).longestQuietStretch, 0)
    }

    // MARK: Chart buckets

    func testBucketUnitsFollowRangeLength() {
        func unit(firstDaysAgo: Int) -> BucketUnit {
            build([project(orbit, [activity(main, edits: edits(firstDaysAgo) + edits(0))])])
                .statistics(projectPath: nil, period: .all).unit
        }
        XCTAssertEqual(unit(firstDaysAgo: 44), .day)
        XCTAssertEqual(unit(firstDaysAgo: 45), .week)
        XCTAssertEqual(unit(firstDaysAgo: 399), .week)
        XCTAssertEqual(unit(firstDaysAgo: 400), .month)
        let index = build([project(orbit, [activity(main, edits: edits(0))])])
        XCTAssertEqual(index.statistics(projectPath: nil, period: .week).unit, .day)
        XCTAssertEqual(index.statistics(projectPath: nil, period: .month).unit, .day)
        XCTAssertEqual(index.statistics(projectPath: nil, period: .quarter).unit, .week)
    }

    func testWeekBucketsStartOnMondayAndFlagClippedWeeks() {
        // The 90-day window starts on Monday, Aug 3; the current week runs past today.
        let index = build([project(orbit, [activity(main, edits: edits(89) + edits(50) + edits(0) + edits(-1))])])
        let quarter = index.statistics(projectPath: nil, period: .quarter)
        XCTAssertEqual(quarter.bucketStarts.count, 13)
        XCTAssertEqual(quarter.bucketStarts.first, today.adding(days: -89))
        XCTAssertEqual(quarter.bucketStarts.last, today.weekStart)
        XCTAssertTrue(quarter.bucketStarts.allSatisfy { $0.weekday == 0 })
        XCTAssertEqual(quarter.buckets.map(\.start), [today.adding(days: -89), today.adding(days: -50).weekStart, today.weekStart])
        XCTAssertEqual(quarter.buckets.map(\.isPartial), [false, false, true])
        // Tomorrow's edit is outside the range, so the clipped week counts only today.
        XCTAssertEqual(quarter.buckets.last?.edits, 1)
        XCTAssertEqual(quarter.buckets.last?.id, "\(main)|\(today.weekStart.index)")

        let clipped = build([project(orbit, [activity(main, edits: edits(100) + edits(0))])])
            .statistics(projectPath: nil, period: .all)
        XCTAssertEqual(clipped.unit, .week)
        XCTAssertEqual(clipped.bucketStarts.first, today.adding(days: -100).weekStart)
        XCTAssertLessThan(clipped.bucketStarts[0], clipped.range.first)
        XCTAssertEqual(clipped.buckets.first?.isPartial, true)
        XCTAssertEqual(clipped.buckets.first?.edits, 1)
    }

    func testMonthBucketsUseTrueMonthStarts() {
        let stats = build([project(orbit, [activity(main, edits: edits(400) + edits(0))])])
            .statistics(projectPath: nil, period: .all)
        XCTAssertEqual(stats.unit, .month)
        XCTAssertEqual(stats.bucketStarts.first, DayKey(year: 2025, month: 9, day: 1))
        XCTAssertEqual(stats.bucketStarts.last, DayKey(year: 2026, month: 10, day: 1))
        XCTAssertEqual(stats.bucketStarts.count, 14)
        XCTAssertTrue(stats.bucketStarts.allSatisfy { $0.day == 1 })
        // September 2025 is clipped; October 2026 ends today, so it is complete.
        XCTAssertEqual(stats.buckets.map(\.isPartial), [true, false])
    }

    func testRollingAverageIncludesZerosAndIsSeededBeforeTheRange() {
        let index = build([project(orbit, [activity(main, edits: edits(32, count: 7) + edits(0, count: 14))])])
        let month = index.statistics(projectPath: nil, period: .month)
        XCTAssertEqual(month.rollingAverage.count, 30)
        XCTAssertEqual(month.rollingAverage.first, AveragePoint(day: today.adding(days: -29), value: 1))
        XCTAssertEqual(month.rollingAverage.first { $0.day == today.adding(days: -26) }?.value, 1)
        XCTAssertEqual(month.rollingAverage.first { $0.day == today.adding(days: -25) }?.value, 0)
        XCTAssertEqual(month.rollingAverage.last, AveragePoint(day: today, value: 2))
        XCTAssertEqual(index.statistics(projectPath: nil, period: .week).rollingAverage, [])
        XCTAssertEqual(index.statistics(projectPath: nil, period: .quarter).rollingAverage, [])

        let fourteen = build([project(orbit, [activity(main, edits: edits(13) + edits(0))])])
        XCTAssertEqual(fourteen.statistics(projectPath: nil, period: .all).rollingAverage.count, 14)
        let thirteen = build([project(orbit, [activity(main, edits: edits(12) + edits(0))])])
        XCTAssertEqual(thirteen.statistics(projectPath: nil, period: .all).rollingAverage, [])
    }

    func testCumulativeIsDenseMonotoneAndEndsAtTheTotal() {
        let index = build([project(orbit, [
            activity(main, edits: edits(25, count: 3) + edits(10) + edits(2, count: 4), sessions: [at(25), at(2)]),
            activity(codex, edits: edits(15, count: 2) + edits(0), sessions: [at(15)])
        ])])
        let month = index.statistics(projectPath: nil, period: .month)
        XCTAssertEqual(month.cumulative.count, month.bucketStarts.count * 2)
        for source in [main, codex] {
            let series = month.cumulative.filter { $0.sourceID == source }
            XCTAssertEqual(series.map(\.start), month.bucketStarts)
            XCTAssertEqual(series.map(\.edits), series.map(\.edits).sorted())
            XCTAssertEqual(series.map(\.sessions), series.map(\.sessions).sorted())
        }
        let lastStart = month.bucketStarts.last
        let finals = month.cumulative.filter { $0.start == lastStart }
        XCTAssertEqual(finals.reduce(0) { $0 + $1.edits }, month.current.edits)
        XCTAssertEqual(finals.reduce(0) { $0 + $1.sessions }, month.current.sessions)
        XCTAssertEqual(month.buckets.reduce(0) { $0 + $1.edits }, 11)
        XCTAssertEqual(month.current.edits, 11)
        XCTAssertTrue(month.buckets.allSatisfy { $0.edits > 0 || $0.sessions > 0 })
    }

    // MARK: Trail calendar

    func testCalendarGridCellsFlagsAndQuartileLevels() {
        var mainEdits: [EditMoment] = []
        for daysAgo in 1...8 { mainEdits += edits(daysAgo, count: daysAgo) }
        let index = build([project(orbit, [
            activity(main, edits: mainEdits + edits(-1, count: 5)),
            activity(codex, edits: edits(10, count: 3) + [EditMoment(date: at(1, hour: 2, minute: 30))])
        ])])
        let grid = index.statistics(projectPath: nil, period: .month).calendar
        XCTAssertEqual(grid.weeks, 26)
        XCTAssertEqual(grid.cells.count, 182)
        XCTAssertEqual(grid.firstDay, DayKey(year: 2026, month: 5, day: 4))
        XCTAssertEqual(grid.firstDay.weekday, 0)
        for (offset, cell) in grid.cells.enumerated() {
            XCTAssertEqual(cell.day, grid.firstDay.adding(days: offset))
            XCTAssertEqual(cell.day.weekday, offset % 7)
        }
        XCTAssertEqual(grid.cells.filter(\.isFuture).map(\.day), [today.adding(days: 1)])
        XCTAssertEqual(grid.cells.filter(\.inRange).count, 30)
        XCTAssertEqual(grid.cells.filter { !$0.beforeHistory }.first?.day, today.adding(days: -10))
        // 02:30 on Saturday belongs to Friday's activity day.
        let friday = grid.cells.first { $0.day == today.adding(days: -1) }
        XCTAssertEqual(friday?.edits, 2)
        XCTAssertEqual(friday?.bySource, [main: 1, codex: 1])
        XCTAssertEqual(friday?.profiles, 2)

        // Non-future daily totals 2, 2, 3, 4, 5, 6, 7, 8 and 3: nearest rank over nine values.
        XCTAssertEqual(grid.thresholds, LevelThresholds(q1: 3, q2: 4, q3: 6))
        XCTAssertEqual(grid.thresholds.level(0), 0)
        XCTAssertEqual(grid.thresholds.level(3), 1)
        XCTAssertEqual(grid.thresholds.level(4), 2)
        XCTAssertEqual(grid.thresholds.level(6), 3)
        XCTAssertEqual(grid.thresholds.level(7), 4)
        XCTAssertEqual(grid.sourceThresholds[main], LevelThresholds(q1: 2, q2: 4, q3: 6))
        XCTAssertEqual(grid.sourceThresholds[codex], LevelThresholds(q1: 1, q2: 1, q3: 3))
        XCTAssertNil(grid.sourceThresholds[grok])

        var expected = [Int](repeating: 0, count: 7)
        for cell in grid.cells where !cell.isFuture { expected[cell.day.weekday] += cell.edits }
        XCTAssertEqual(grid.weekdayTotals, expected)
        XCTAssertEqual(grid.weekdayTotals.reduce(0, +), 36 + 4)
        XCTAssertEqual(grid.weekdayShare.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(grid.weekdayShare[4], Double(expected[4]) / 40, accuracy: 1e-9)
    }

    func testLevelThresholdsUseNearestRankOfNonZeroValues() {
        XCTAssertEqual(LevelThresholds.make(Array(1...8)), LevelThresholds(q1: 2, q2: 4, q3: 6))
        XCTAssertEqual(LevelThresholds.make([0, 0, 5]), LevelThresholds(q1: 5, q2: 5, q3: 5))
        XCTAssertEqual(LevelThresholds.make([0]), .empty)
        let levels = LevelThresholds(q1: 2, q2: 4, q3: 6)
        XCTAssertEqual([0, 1, 2, 3, 4, 5, 6, 7, 100].map(levels.level), [0, 1, 1, 2, 2, 3, 3, 4, 4])
    }

    // MARK: Profiles and projects

    func testSourceSharesSumToOneInSourceOrderWithDelegation() {
        let index = build([project(orbit, [
            activity(grok, edits: edits(3)),
            activity(codex, edits: edits(4, count: 2) + edits(4, delegated: true), sessions: [at(4)]),
            activity(main, edits: edits(2, count: 2) + edits(1, count: 4, delegated: true) + edits(40, count: 2),
                     sessions: [at(60)])
        ])])
        let month = index.statistics(projectPath: nil, period: .month)
        XCTAssertEqual(month.sources.map(\.sourceID), [main, codex, grok])
        XCTAssertEqual(month.sources.map(\.edits), [6, 3, 1])
        XCTAssertEqual(month.sources.reduce(0) { $0 + $1.share }, 1, accuracy: 1e-9)
        XCTAssertEqual(month.sources[0].share, 0.6, accuracy: 1e-9)
        XCTAssertEqual(month.sources.map(\.delegatedEdits), [4, 1, 0])
        XCTAssertEqual(month.current.delegatedEdits, 5)
        XCTAssertEqual(month.sources.map(\.delegationReported), [true, true, false])
        XCTAssertEqual(month.sources.map(\.sessions), [0, 1, 0])
        XCTAssertEqual(month.sources.map(\.activeDays), [2, 1, 1])
        XCTAssertEqual(month.sources[0].firstDay, today.adding(days: -60))
        XCTAssertEqual(month.sources[1].firstDay, today.adding(days: -4))
        XCTAssertEqual(month.sources[0].previousShare ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(month.sources[1].previousShare ?? -1, 0, accuracy: 1e-9)
        XCTAssertTrue(index.statistics(projectPath: nil, period: .all).sources.allSatisfy { $0.previousShare == nil })
    }

    func testUnconfiguredSourcesFollowConfiguredOrderSorted() {
        let index = build([project(orbit, [activity("zeta", edits: edits(1)), activity("alpha", edits: edits(1)),
                                           activity(codex, edits: edits(1))])])
        XCTAssertEqual(index.sourceOrder, sources.map(\.id) + ["alpha", "zeta"])
        XCTAssertEqual(index.statistics(projectPath: nil, period: .week).sources.map(\.sourceID), [codex, "alpha", "zeta"])
    }

    func testSharedDaysRequireTheSameProject() {
        let index = build([
            project(orbit, [activity(main, edits: edits(3) + edits(2) + edits(1, count: 2)),
                            activity(codex, edits: edits(3))]),
            project(harbor, [activity(codex, edits: edits(2))])
        ])
        XCTAssertEqual(index.statistics(projectPath: nil, period: .week).sharedDays, 1)
        XCTAssertEqual(index.statistics(projectPath: harbor, period: .week).sharedDays, 0)
        XCTAssertEqual(index.statistics(projectPath: orbit, period: .week).sharedDays, 1)
    }

    func testProjectRowsOrderByEditsThenNameForAllProjectsOnly() {
        let index = build([
            project("/Demo/Projects/beta", [activity(main, edits: edits(1, count: 3) + edits(40))]),
            project("/Demo/Projects/alpha", [activity(main, edits: edits(2, count: 3))]),
            project("/Demo/Projects/gamma", [activity(codex, edits: edits(5, count: 2)), activity(main, edits: edits(3, count: 3))]),
            project("/Demo/Projects/quiet", [activity(main, edits: edits(100))])
        ])
        let month = index.statistics(projectPath: nil, period: .month)
        XCTAssertEqual(month.projects.map(\.name), ["gamma", "alpha", "beta"])
        XCTAssertEqual(month.projects.map(\.edits), [5, 3, 3])
        XCTAssertEqual(month.projects.map(\.previousEdits), [0, 0, 1])
        XCTAssertEqual(month.projects[0].bySource, [SourceCount(sourceID: main, edits: 3), SourceCount(sourceID: codex, edits: 2)])
        XCTAssertEqual(month.projects[0].latestEditDay, today.adding(days: -3))
        XCTAssertEqual(month.projects[0].id, "/Demo/Projects/gamma")
        XCTAssertEqual(month.projectsTouched, 3)
        XCTAssertEqual(month.projectCount, 4)

        let all = index.statistics(projectPath: nil, period: .all)
        XCTAssertEqual(all.projects.map(\.name), ["gamma", "beta", "alpha", "quiet"])
        XCTAssertTrue(all.projects.allSatisfy { $0.previousEdits == nil })
        let single = index.statistics(projectPath: "/Demo/Projects/gamma", period: .month)
        XCTAssertEqual(single.projects, [])
        XCTAssertEqual(single.projectsTouched, 1)
    }

    // MARK: Rhythm

    func testLateNightEditLandsInThePreviousDaysRow() {
        let index = build([project(orbit, [activity(main, edits: [EditMoment(date: at(1, hour: 2, minute: 30))])])])
        let rhythm = index.statistics(projectPath: nil, period: .week).rhythm
        // 02:30 Saturday wall clock is Friday's activity day, 21 hours after 05:00.
        XCTAssertEqual(rhythm.grid.count, 168)
        XCTAssertEqual(rhythm.grid[4 * 24 + 21], 1)
        XCTAssertEqual(rhythm.hourTotals[2], 1)
        XCTAssertEqual(rhythm.total, 1)
        XCTAssertEqual(rhythm.peakHour, 2)
        XCTAssertEqual(rhythm.peakCell, 4 * 24 + 21)
        XCTAssertEqual(rhythm.busiestWeekday, 4)
        XCTAssertEqual(rhythm.nightShare, 1)
        XCTAssertNil(rhythm.chronotype)
    }

    func testNightHeavyRhythmIsANightOwl() {
        let index = build([project(orbit, [activity(main, edits: edits(3, count: 60, hour: 23) + edits(4, count: 40, hour: 12))])])
        let rhythm = index.statistics(projectPath: nil, period: .month).rhythm
        XCTAssertEqual(rhythm.total, 100)
        XCTAssertEqual(rhythm.chronotype, .nightOwl)
        XCTAssertEqual(rhythm.chronotype?.title, "Night owl")
        XCTAssertEqual(rhythm.nightShare, 0.6, accuracy: 1e-9)
        XCTAssertEqual(rhythm.peakHour, 23)
        XCTAssertEqual(rhythm.levels, LevelThresholds(q1: 40, q2: 40, q3: 60))
    }

    func testFlatRhythmIsRoundTheClockAndSmallSetsHaveNoChronotype() {
        let flat = (0..<24).flatMap { edits(2, count: 3, hour: $0) }
        let rhythm = build([project(orbit, [activity(main, edits: flat)])]).statistics(projectPath: nil, period: .week).rhythm
        XCTAssertEqual(rhythm.total, 72)
        XCTAssertEqual(rhythm.chronotype, .roundTheClock)
        XCTAssertEqual(rhythm.nightShare, 21.0 / 72.0, accuracy: 1e-9)
        // A full tie goes to the first column after the rollover.
        XCTAssertEqual(rhythm.peakHour, 5)

        let small = (0..<49).flatMap { edits(2, count: 1, hour: 5 + $0 % 19) }
        XCTAssertNil(build([project(orbit, [activity(main, edits: small)])]).statistics(projectPath: nil, period: .week).rhythm.chronotype)
        XCTAssertEqual(StatsIndex.chronotype(hourTotals: (0..<24).map { $0 >= 5 && $0 <= 8 ? 30 : 1 }, total: 140), .earlyBird)
    }

    func testPeakHourTieGoesToTheEarliestHourAfterTheRollover() {
        let index = build([project(orbit, [activity(main, edits: edits(2, count: 2, hour: 3) + edits(2, count: 2, hour: 6))])])
        XCTAssertEqual(index.statistics(projectPath: nil, period: .week).rhythm.peakHour, 6)
        let quiet = build([project(orbit, [activity(main, sessions: [at(1)])])]).statistics(projectPath: nil, period: .week).rhythm
        XCTAssertNil(quiet.peakHour)
        XCTAssertNil(quiet.busiestWeekday)
        XCTAssertEqual(quiet.nightShare, 0)
    }

    // MARK: Trends and pulse

    func testProjectTrendWindowsAndMixFallback() throws {
        let index = build([
            project(orbit, [activity(main, edits: edits(0, count: 2) + edits(29) + edits(30, count: 4) + edits(59) + edits(60),
                                     sessions: [at(0), at(29)])]),
            project(harbor, [activity(codex, edits: edits(40, count: 2)), activity(main, sessions: [at(1)])]),
            project(atlas, [activity(main, edits: edits(3)), activity(codex, edits: edits(45))])
        ])
        let trend = try XCTUnwrap(index.trends[orbit])
        XCTAssertEqual(trend.path, orbit)
        XCTAssertEqual(trend.daily30.count, 30)
        XCTAssertEqual(trend.daily30[29], 2)
        XCTAssertEqual(trend.daily30[0], 1)
        XCTAssertEqual(trend.daily30.reduce(0, +), 3)
        XCTAssertEqual(trend.edits30, 3)
        XCTAssertEqual(trend.previous30, 5)
        XCTAssertEqual(trend.edits7, 2)
        XCTAssertEqual(trend.previous7, 0)
        XCTAssertEqual(trend.totalEdits, 9)
        XCTAssertEqual(trend.totalSessions, 2)
        XCTAssertEqual(trend.currentStreak, 1)
        XCTAssertEqual(trend.firstEditDay, today.adding(days: -60))
        XCTAssertEqual(trend.lastEditDay, today)

        let fallback = try XCTUnwrap(index.trends[harbor])
        XCTAssertEqual(fallback.mix, [SourceCount(sourceID: codex, edits: 2)])
        XCTAssertTrue(fallback.mixIsAllTime)
        let recent = try XCTUnwrap(index.trends[atlas])
        XCTAssertEqual(recent.mix, [SourceCount(sourceID: main, edits: 1)])
        XCTAssertFalse(recent.mixIsAllTime)
    }

    func testMomentumBoundaries() {
        func momentum(_ days: [Int]) -> Momentum? {
            build([project(orbit, [activity(main, edits: days.flatMap { edits($0) })])]).trends[orbit]?.momentum
        }
        XCTAssertEqual(momentum([6, 0]), .new)
        XCTAssertNil(momentum([7, 0]))
        XCTAssertNil(momentum([20, 13]))
        XCTAssertEqual(momentum([20, 14]), .dormant)
        let sessionsOnly = build([project(orbit, [activity(main, sessions: [at(30)])])]).trends[orbit]
        XCTAssertNil(sessionsOnly?.momentum)
        XCTAssertNil(sessionsOnly?.firstEditDay)
        XCTAssertEqual(sessionsOnly?.totalSessions, 1)
    }

    func testPulseSummaryCountsActiveProjects() {
        let index = build([
            project(orbit, [activity(main, edits: edits(0, count: 2) + edits(10))]),
            project(harbor, [activity(codex, edits: edits(3))]),
            project(atlas, [activity(main, edits: edits(20))]),
            project("/Demo/Projects/lumen", [activity(main, sessions: [at(0)])])
        ])
        XCTAssertEqual(index.pulse.activeProjects7, 2)
        XCTAssertEqual(index.pulse.projectCount, 4)
        XCTAssertEqual(index.pulse.edits7, 3)
        XCTAssertEqual(index.pulse.previous7, 1)
        XCTAssertEqual(index.pulse.daily14.count, 14)
        XCTAssertEqual(index.pulse.daily14[13], 2)
        XCTAssertEqual(index.pulse.daily14[10], 1)
        XCTAssertEqual(index.pulse.daily14[3], 1)
        XCTAssertEqual(index.pulse.streaks.current, 1)
        XCTAssertEqual(index.projectPaths, [orbit, harbor, atlas, "/Demo/Projects/lumen"])
    }

    // MARK: Inputs

    func testOverviewHistoriesDoNotDoubleCountCanonicalAliases() {
        let copy = activity(main, edits: edits(1, count: 3), sessions: [at(1)])
        var alias = copy
        alias.projectPath = "/Demo/Projects/../Projects/orbit"
        let overviews = ProjectOverview.merge(projects: [project(orbit, [copy]), project(alias.projectPath, [alias])], sessions: [])
        XCTAssertEqual(overviews.count, 1)
        let index = build(overviews.compactMap(\.history).filter { !$0.activities.isEmpty })
        let all = index.statistics(projectPath: nil, period: .all)
        XCTAssertEqual(all.current.edits, 3)
        XCTAssertEqual(all.current.sessions, 1)
        XCTAssertEqual(all.projectCount, 1)
        XCTAssertEqual(index.trends[overviews[0].path]?.totalEdits, 3)
    }

    func testEmptyInputDoesNotCrash() {
        let empty = build([])
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.pulse, .empty)
        XCTAssertEqual(empty.trends.count, 0)
        for period in StatsPeriod.allCases {
            let stats = empty.statistics(projectPath: nil, period: period)
            XCTAssertEqual(stats.current.edits, 0)
            XCTAssertEqual(stats.calendar.cells.count, 182)
            XCTAssertTrue(stats.calendar.cells.allSatisfy(\.beforeHistory))
            XCTAssertNil(stats.busiestDay)
            XCTAssertNil(stats.firstRecordedDay)
            XCTAssertEqual(stats.buckets, [])
            XCTAssertEqual(stats.sources, [])
            XCTAssertEqual(stats.streaks, .empty)
            XCTAssertEqual(empty.statistics(projectPath: orbit, period: period).current.edits, 0)
            XCTAssertEqual(ActivityStatistics.empty(period: period).period, period)
        }
        XCTAssertEqual(empty.statistics(projectPath: nil, period: .all).range, DayRange(first: today, last: today))
        XCTAssertTrue(StatsIndex.empty.isEmpty)
        XCTAssertEqual(ActivityStatistics.empty(period: .month).range.count, 30)

        let noMoments = build([project(orbit, [ProjectActivity(sourceID: main, projectPath: orbit, latestActivity: now)])])
        XCTAssertTrue(noMoments.isEmpty)
        XCTAssertNil(noMoments.trends[orbit])
        let unknown = build([project(orbit, [activity(main, edits: edits(1))])])
        XCTAssertEqual(unknown.statistics(projectPath: "/Demo/Projects/missing", period: .all).current.edits, 0)
    }

    func testNiceScaleSteps() {
        let large = NiceScale.ticks(maximum: 470)
        XCTAssertEqual(large.step, 200)
        XCTAssertEqual(large.top, 600)
        XCTAssertEqual(large.values, [0, 200, 400, 600])
        XCTAssertEqual(NiceScale.ticks(maximum: 64).step, 25)
        XCTAssertEqual(NiceScale.ticks(maximum: 64).top, 75)
        XCTAssertEqual(NiceScale.ticks(maximum: 100).values, [0, 50, 100, 150])
        XCTAssertEqual(NiceScale.ticks(maximum: 10).values, [0, 5, 10, 15])
        let zero = NiceScale.ticks(maximum: 0)
        XCTAssertEqual(zero.step, 1)
        XCTAssertEqual(zero.values, [0, 1, 2])
    }

    func testStatsPeriodTitlesAndDayCounts() {
        XCTAssertEqual(StatsPeriod.allCases.map(\.rawValue), ["7D", "30D", "90D", "All"])
        XCTAssertEqual(StatsPeriod.allCases.map(\.dayCount), [7, 30, 90, nil])
        XCTAssertEqual(StatsPeriod.all.title, "All saved history")
        XCTAssertEqual(StatsPeriod.week.title, "Last 7 days")
        XCTAssertEqual(StatsPeriod.month.id, "30D")
    }

    // MARK: Performance

    func testPerformanceSmokeAtRealisticScale() {
        let ids = [main, second, codex, grok]
        let noons: [Date] = (0..<365).map { calendar.noon(of: today.adding(days: -$0)) }
        var projects: [ProjectSummary] = []
        for projectIndex in 0..<19 {
            let path = "/Demo/Projects/p\(projectIndex)"
            var activities: [ProjectActivity] = []
            for (sourceIndex, id) in ids.enumerated() {
                var moments: [EditMoment] = []
                var starts: [Date] = []
                for ago in stride(from: 364, through: 0, by: -1) {
                    let count = (projectIndex + sourceIndex + ago) % 5 + 1
                    starts.append(noons[ago].addingTimeInterval(-3_600))
                    for edit in 0..<count {
                        moments.append(EditMoment(date: noons[ago].addingTimeInterval(Double(edit * 1_800 - 7_200)), delegated: edit == 0))
                    }
                }
                activities.append(ProjectActivity(sourceID: id, projectPath: path, latestActivity: now,
                                                  sessionCount: starts.count, editMoments: moments, sessionStarts: starts))
            }
            projects.append(project(path, activities))
        }
        let expected = projects.reduce(0) { $0 + $1.activities.reduce(0) { $0 + $1.editMoments.count } }
        XCTAssertGreaterThan(expected, 80_000)

        // Generous wall-clock bounds: this runs as a debug build on shared CI
        // runners, including slower Intel machines. They catch an accidental
        // quadratic pass (seconds at this scale), not small timing noise.
        let started = Date()
        let index = build(projects)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertEqual(index.statistics(projectPath: nil, period: .all).current.edits, expected)

        var fastest = Double.infinity
        for _ in 0..<5 {
            let start = Date()
            _ = index.statistics(projectPath: nil, period: .month)
            fastest = min(fastest, Date().timeIntervalSince(start))
        }
        XCTAssertLessThan(fastest, 0.5)
        measure {
            _ = index.statistics(projectPath: nil, period: .month)
        }
    }

    // MARK: Fixtures

    private func build(_ projects: [ProjectSummary]) -> StatsIndex {
        StatsIndex.build(projects: projects, sources: sources, calendar: calendar, now: now)
    }

    private func project(_ path: String, _ activities: [ProjectActivity]) -> ProjectSummary {
        ProjectSummary(path: path, activities: activities.map { activity in
            var activity = activity
            activity.projectPath = path
            return activity
        })
    }

    /// A history derived from the moments, as providers produce it.
    private func activity(_ source: String, edits: [EditMoment] = [], sessions: [Date] = []) -> ProjectActivity {
        let moments = edits.sorted { $0.date < $1.date }
        let starts = sessions.sorted()
        let editDays: [ActivityDay] = moments.map { ActivityDay(day: $0.date, editCount: 1) }
        let sessionDays: [ActivityDay] = starts.map { ActivityDay(day: $0, sessionCount: 1) }
        let latest = (moments.map(\.date) + starts).max() ?? now
        return ProjectActivity(sourceID: source, projectPath: orbit, latestActivity: latest, latestEdit: moments.last?.date,
                               sessionCount: starts.count, history: ActivityDay.merge(editDays + sessionDays),
                               editMoments: moments, sessionStarts: starts)
    }

    /// `count` edits on the activity day `daysAgo` before today, a minute apart.
    private func edits(_ daysAgo: Int, count: Int = 1, hour: Int = 12, delegated: Bool = false) -> [EditMoment] {
        (0..<count).map { EditMoment(date: at(daysAgo, hour: hour).addingTimeInterval(Double($0 % 60) * 60), delegated: delegated) }
    }

    /// Wall-clock time on an activity day; hours before 05:00 fall on the next civil morning.
    private func at(_ daysAgo: Int, hour: Int = 12, minute: Int = 0) -> Date {
        let offset = hour < calendar.rolloverHour ? hour + 24 : hour
        return calendar.noon(of: today.adding(days: -daysAgo)).addingTimeInterval(Double((offset - 12) * 3_600 + minute * 60))
    }
}
