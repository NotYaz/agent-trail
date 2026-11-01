import Foundation
import XCTest
@testable import AgentTrailCore

final class PortraitSummaryTests: XCTestCase {
    private let calendar = ActivityCalendar(timeZone: TimeZone(identifier: "Europe/Moscow")!)
    /// Saturday 2026-10-31, 12:00 in Moscow.
    private let now = Date(timeIntervalSince1970: Double(20_757 * 86_400 + 9 * 3_600))
    private let today = DayKey(year: 2026, month: 10, day: 31)
    private let sources = AgentSource.defaults(home: "/Demo")
    private let english = Locale(identifier: "en_US")
    private let main = "claude-primary", codex = "codex", grok = "grok"
    private let orbit = "/Demo/Projects/orbit", harbor = "/Demo/Projects/harbor"

    func testAnonymizedPortraitHidesProjectAndProfileNames() {
        let index = sample()
        let all = index.portrait(projectPath: nil, period: .month, showNames: false, locale: english)
        XCTAssertFalse(all.namesShown)
        XCTAssertEqual(all.agents.map(\.name), ["Agent 1", "Agent 2", "Agent 3"])
        XCTAssertEqual(all.agents.map(\.sourceID), [main, codex, grok])
        XCTAssertEqual(all.scopeTitle, "2 projects")
        let single = index.portrait(projectPath: orbit, period: .month, showNames: false, locale: english)
        XCTAssertEqual(single.scopeTitle, "My project")
        for portrait in [all, single] {
            for text in renderedStrings(portrait) {
                for secret in ["orbit", "harbor", "Demo", "Claude", "Codex", "Grok", "Main", "/"] {
                    XCTAssertFalse(text.contains(secret), "\(text) contains \(secret)")
                }
            }
        }
    }

    func testNamesShownStillCarryNoPaths() {
        let index = sample()
        let all = index.portrait(projectPath: nil, period: .month, showNames: true, locale: english)
        XCTAssertTrue(all.namesShown)
        XCTAssertEqual(all.agents.map(\.name), ["Claude · Main", "Codex", "Grok"])
        XCTAssertEqual(all.scopeTitle, "2 projects")
        let single = index.portrait(projectPath: orbit, period: .month, showNames: true, locale: english)
        XCTAssertEqual(single.scopeTitle, "orbit")
        for portrait in [all, single] {
            for text in renderedStrings(portrait) + portrait.agents.map(\.sourceID) {
                XCTAssertFalse(text.contains("/"), text)
            }
        }
    }

    func testStripNeverLeavesTheRange() {
        let index = sample()
        let week = index.portrait(projectPath: nil, period: .week, showNames: false, locale: english)
        guard case .days(let days) = week.strip else { return XCTFail("7D should be a day strip") }
        XCTAssertEqual(days.map(\.day), (0..<7).map { today.adding(days: $0 - 6) })
        XCTAssertEqual(days.last?.edits, 2)

        let month = index.portrait(projectPath: nil, period: .month, showNames: false, locale: english)
        guard case .weeks(let firstDay, let weeks, let monthDays) = month.strip else { return XCTFail("30D should be weeks") }
        let range = DayRange(first: today.adding(days: -29), last: today)
        XCTAssertEqual(firstDay, range.first.weekStart)
        XCTAssertEqual(firstDay.weekday, 0)
        XCTAssertEqual(weeks, 5)
        XCTAssertEqual(monthDays.map(\.day), range.days)
        XCTAssertTrue(month.agents.allSatisfy { $0.days.allSatisfy { range.contains($0.day) } })
        XCTAssertFalse(month.agents.flatMap(\.days).contains { $0.day == today.adding(days: -40) })

        let long = build([project(orbit, [activity(main, edits: edits(300) + edits(0))])])
            .portrait(projectPath: nil, period: .all, showNames: false, locale: english)
        guard case .weeks(let longFirst, let longWeeks, let longDays) = long.strip else { return XCTFail("All should be weeks") }
        XCTAssertEqual(longWeeks, 26)
        XCTAssertEqual(longFirst, today.weekStart.adding(days: -25 * 7))
        XCTAssertTrue(longDays.allSatisfy { $0.day >= longFirst && $0.day <= today })
        XCTAssertEqual(longDays.first?.day, longFirst)
        XCTAssertEqual(long.edits, 2)
    }

    /// The All strip keeps 26 weeks, but the caption's busiest day must cover
    /// the whole range the card names.
    func testBusiestDayCoversTheWholeRangeNotJustTheStrip() {
        let index = build([project(orbit, [activity(main, edits: edits(300, count: 3) + edits(200, count: 3) + edits(0, count: 2))])])
        let all = index.portrait(projectPath: nil, period: .all, showNames: false, locale: english)
        guard case .weeks(let firstDay, _, let days) = all.strip else { return XCTFail("All should be weeks") }
        XCTAssertLessThan(today.adding(days: -200), firstDay)
        XCTAssertEqual(days.map(\.edits).max(), 2)
        // Ties go to the latest day, as in the Growth tile.
        XCTAssertEqual(all.busiestDay, PortraitDay(day: today.adding(days: -200), edits: 3, sessions: 0))
        XCTAssertEqual(all.edits, 8)

        let week = index.portrait(projectPath: nil, period: .week, showNames: false, locale: english)
        XCTAssertEqual(week.busiestDay, PortraitDay(day: today, edits: 2, sessions: 0))
        let quiet = build([project(orbit, [activity(main, edits: edits(40), sessions: [at(1)])])])
            .portrait(projectPath: nil, period: .week, showNames: false, locale: english)
        XCTAssertNil(quiet.busiestDay)
    }

    func testLongestStreakStaysWithinTheRange() {
        let index = build([project(orbit, [activity(main, edits: [9, 8, 7, 6, 5].flatMap { edits($0) })])])
        XCTAssertEqual(index.portrait(projectPath: nil, period: .week, showNames: false, locale: english).longestStreak, 2)
        XCTAssertEqual(index.portrait(projectPath: nil, period: .month, showNames: false, locale: english).longestStreak, 5)
        XCTAssertEqual(index.statistics(projectPath: nil, period: .week).streaks.longest, 5)
    }

    func testTotalsAndDateRangeText() {
        let portrait = sample().portrait(projectPath: nil, period: .month, showNames: false, locale: english)
        XCTAssertEqual(portrait.edits, 9)
        XCTAssertEqual(portrait.sessions, 3)
        XCTAssertEqual(portrait.activeDays, 5)
        XCTAssertEqual(portrait.periodTitle, "Last 30 days")
        XCTAssertEqual(portrait.dateRangeText, "Oct 2, 2026 – Oct 31, 2026")
        XCTAssertEqual(portrait.calendar, calendar)
        XCTAssertEqual(portrait.agents.map { $0.days.count }, [3, 2, 1])
        XCTAssertEqual(portrait.agents[2].days, [PortraitDay(day: today.adding(days: -2), edits: 0, sessions: 1)])
    }

    func testEveryHeadlineVariant() {
        let two = build([project(orbit, [activity(main, edits: edits(1, count: 5)), activity(codex, edits: edits(2, count: 3))])])
        XCTAssertEqual(two.portrait(projectPath: nil, period: .week, showNames: false, locale: english).headline, "8 edits.\n2 agents.")

        let one = build([project(orbit, [activity(main, edits: edits(1) + edits(2) + edits(4))])])
        XCTAssertEqual(one.portrait(projectPath: nil, period: .week, showNames: false, locale: english).headline, "One agent.\n3 active days.")
        let oneDay = build([project(orbit, [activity(main, edits: edits(1, count: 3))])])
        XCTAssertEqual(oneDay.portrait(projectPath: nil, period: .week, showNames: false, locale: english).headline, "One agent.\n1 active day.")

        let sessions = build([project(orbit, [activity(grok, sessions: [at(1), at(2)]), activity(main, sessions: [at(3)])])])
        XCTAssertEqual(sessions.portrait(projectPath: nil, period: .week, showNames: false, locale: english).headline, "3 saved\nsessions.")
        let session = build([project(orbit, [activity(grok, sessions: [at(1)])])])
        XCTAssertEqual(session.portrait(projectPath: nil, period: .week, showNames: false, locale: english).headline, "1 saved\nsession.")

        let quiet = build([project(orbit, [activity(main, edits: edits(40))])])
        let quietWeek = quiet.portrait(projectPath: nil, period: .week, showNames: false, locale: english)
        XCTAssertEqual(quietWeek.headline, "A quiet\nstretch.")
        XCTAssertEqual(quietWeek.agents, [])
        XCTAssertEqual(quietWeek.scopeTitle, "No projects")
        XCTAssertEqual(StatsIndex.empty.portrait(projectPath: nil, period: .month, showNames: true, locale: english).headline,
                       "A quiet\nstretch.")

        XCTAssertEqual(StatsIndex.headline(edits: 1_234, sessions: 0, agents: 2, activeDays: 3, locale: english),
                       "1,234 edits.\n2 agents.")
    }

    func testPortraitCarriesNoHourOrSlotData() {
        let portrait = sample().portrait(projectPath: nil, period: .month, showNames: true, locale: english)
        var labels = Mirror(reflecting: portrait).children.compactMap { $0.label }
        if let agent = portrait.agents.first {
            labels += Mirror(reflecting: agent).children.compactMap { $0.label }
            if let day = agent.days.first { labels += Mirror(reflecting: day).children.compactMap { $0.label } }
        }
        XCTAssertTrue(labels.contains("headline"))
        XCTAssertTrue(labels.contains("days"))
        for label in labels {
            XCTAssertFalse(label.lowercased().contains("hour"), label)
            XCTAssertFalse(label.lowercased().contains("slot"), label)
            XCTAssertFalse(label.lowercased().contains("weekday"), label)
        }
    }

    // MARK: Fixtures

    /// Orbit: Main on three days, Codex once, Grok sessions only. Harbor: one old Codex edit and a session.
    private func sample() -> StatsIndex {
        build([
            project(orbit, [
                activity(main, edits: edits(0, count: 2) + edits(3) + edits(10, count: 3), sessions: [at(10)]),
                activity(codex, edits: edits(5, count: 2)),
                activity(grok, sessions: [at(2)])
            ]),
            project(harbor, [activity(codex, edits: edits(40) + edits(12), sessions: [at(12)])])
        ])
    }

    private func renderedStrings(_ portrait: PortraitSummary) -> [String] {
        [portrait.headline, portrait.scopeTitle, portrait.periodTitle, portrait.dateRangeText] + portrait.agents.map(\.name)
    }

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

    private func edits(_ daysAgo: Int, count: Int = 1) -> [EditMoment] {
        (0..<count).map { EditMoment(date: at(daysAgo).addingTimeInterval(Double($0) * 60)) }
    }

    /// Noon on the activity day `daysAgo` before today.
    private func at(_ daysAgo: Int) -> Date {
        calendar.noon(of: today.adding(days: -daysAgo))
    }
}
