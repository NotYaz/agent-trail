import Foundation
import XCTest
@testable import AgentTrailCore

final class ActivityCalendarTests: XCTestCase {
    private let moscow = ActivityCalendar(timeZone: TimeZone(identifier: "Europe/Moscow")!)
    private let berlin = ActivityCalendar(timeZone: TimeZone(identifier: "Europe/Berlin")!)

    func testDayKeyCivilMathRoundTrips() {
        XCTAssertEqual(DayKey(year: 1970, month: 1, day: 1).index, 0)
        XCTAssertEqual(DayKey(year: 1969, month: 12, day: 31).index, -1)
        XCTAssertEqual(DayKey(index: -1).weekday, 2)
        let day = DayKey(year: 2026, month: 10, day: 31)
        XCTAssertEqual(day.index, 20_757)
        XCTAssertEqual(day.year, 2026)
        XCTAssertEqual(day.month, 10)
        XCTAssertEqual(day.day, 31)
        XCTAssertEqual(day.weekday, 5)
        XCTAssertEqual(DayKey(year: 1970, month: 1, day: 1).weekday, 3)
        XCTAssertEqual(day.weekStart, DayKey(year: 2026, month: 10, day: 26))
        XCTAssertEqual(day.weekStart.weekday, 0)
        XCTAssertEqual(DayKey(year: 2026, month: 10, day: 26).weekStart, DayKey(year: 2026, month: 10, day: 26))
        XCTAssertEqual(day.monthStart, DayKey(year: 2026, month: 10, day: 1))
        XCTAssertEqual(DayKey(year: 2026, month: 12, day: 9).nextMonthStart, DayKey(year: 2027, month: 1, day: 1))
        XCTAssertEqual(day.adding(days: 1), DayKey(year: 2026, month: 11, day: 1))
        XCTAssertEqual(DayKey(year: 2026, month: 10, day: 1).days(to: day), 30)
        XCTAssertEqual(DayKey(year: 2024, month: 2, day: 29).adding(days: 1), DayKey(year: 2024, month: 3, day: 1))
        XCTAssertLessThan(DayKey(year: 2026, month: 10, day: 30), day)
        for index in stride(from: -800_000, through: 800_000, by: 997) {
            let key = DayKey(index: index)
            XCTAssertEqual(DayKey(year: key.year, month: key.month, day: key.day), key)
        }
    }

    func testDayRangeCountsInclusiveDays() {
        let range = DayRange(first: DayKey(year: 2026, month: 10, day: 25), last: DayKey(year: 2026, month: 10, day: 31))
        XCTAssertEqual(range.count, 7)
        XCTAssertEqual(range.days.count, 7)
        XCTAssertEqual(range.days.first, range.first)
        XCTAssertEqual(range.days.last, range.last)
        XCTAssertTrue(range.contains(range.first))
        XCTAssertTrue(range.contains(range.last))
        XCTAssertFalse(range.contains(range.last.adding(days: 1)))
        XCTAssertFalse(range.contains(range.first.adding(days: -1)))
        let inverted = DayRange(first: range.last, last: range.first)
        XCTAssertEqual(inverted.count, 0)
        XCTAssertEqual(inverted.days, [])
    }

    func testMoscowLateNightBelongsToTheEveningItStarted() {
        let evening = utc("2026-10-30T20:30:00Z")
        XCTAssertEqual(moscow.day(of: evening), DayKey(year: 2026, month: 10, day: 30))
        XCTAssertEqual(moscow.hour(of: evening), 23)

        let afterMidnight = utc("2026-10-30T23:30:00Z")
        XCTAssertEqual(moscow.day(of: afterMidnight), DayKey(year: 2026, month: 10, day: 30))
        XCTAssertEqual(moscow.hourSlot(of: afterMidnight), 21)
        XCTAssertEqual(moscow.hour(of: afterMidnight), 2)

        let rollover = utc("2026-10-31T02:00:00Z")
        XCTAssertEqual(moscow.day(of: rollover), DayKey(year: 2026, month: 10, day: 31))
        XCTAssertEqual(moscow.hourSlot(of: rollover), 0)
        XCTAssertEqual(moscow.hour(of: rollover), 5)
    }

    func testUTCMidnightSplitsAtMidnight() {
        let calendar = ActivityCalendar.utcMidnight
        XCTAssertEqual(calendar.rolloverHour, 0)
        XCTAssertEqual(calendar.day(of: utc("2026-10-30T23:59:00Z")), DayKey(year: 2026, month: 10, day: 30))
        XCTAssertEqual(calendar.day(of: utc("2026-10-31T00:01:00Z")), DayKey(year: 2026, month: 10, day: 31))
        XCTAssertEqual(calendar.hourSlot(of: utc("2026-10-31T00:01:00Z")), 0)
        XCTAssertEqual(calendar.start(of: DayKey(year: 2026, month: 10, day: 31)), utc("2026-10-31T00:00:00Z"))
    }

    func testBerlinFallBackKeepsTheRepeatedNightOnTheSameDay() {
        // 2026-10-25: clocks go back from 03:00 CEST to 02:00 CET.
        let early = utc("2026-10-24T23:30:00Z") // 01:30 CEST
        let late = utc("2026-10-25T03:30:00Z") // 04:30 CET
        let rollover = utc("2026-10-25T04:00:00Z") // 05:00 CET
        XCTAssertEqual(berlin.hour(of: early), 1)
        XCTAssertEqual(berlin.hour(of: late), 4)
        XCTAssertEqual(berlin.day(of: early), DayKey(year: 2026, month: 10, day: 24))
        XCTAssertEqual(berlin.day(of: late), DayKey(year: 2026, month: 10, day: 24))
        XCTAssertEqual(berlin.day(of: rollover), DayKey(year: 2026, month: 10, day: 25))
        XCTAssertEqual(berlin.start(of: DayKey(year: 2026, month: 10, day: 25)), rollover)
    }

    func testBerlinSpringForwardStartsAtFiveLocal() {
        let day = DayKey(year: 2026, month: 3, day: 29)
        XCTAssertEqual(berlin.start(of: day), utc("2026-03-29T03:00:00Z"))
        XCTAssertEqual(berlin.noon(of: day), utc("2026-03-29T10:00:00Z"))
        XCTAssertEqual(berlin.start(of: day.adding(days: -1)), utc("2026-03-28T04:00:00Z"))
        XCTAssertEqual(berlin.day(of: utc("2026-03-29T02:59:00Z")), day.adding(days: -1))
        XCTAssertEqual(berlin.day(of: utc("2026-03-29T03:00:00Z")), day)
    }

    /// The index decodes with one offset per transition; it must agree with the
    /// Gregorian calendar's components on both sides of each DST change.
    func testIndexClockMatchesCalendarComponentsAcrossTransitions() {
        for calendar in [berlin, moscow, ActivityCalendar(timeZone: TimeZone(identifier: "America/St_Johns")!)] {
            var clock = LocalClock(calendar: calendar)
            for window in [("2026-03-20T00:00:00Z", "2026-04-08T00:00:00Z"), ("2026-10-20T00:00:00Z", "2026-11-08T00:00:00Z")] {
                var date = utc(window.0)
                let end = utc(window.1)
                while date < end {
                    let decoded = clock.decode(date)
                    let parts = calendar.gregorian.dateComponents([.year, .month, .day, .hour], from: date)
                    let civil = DayKey(year: parts.year!, month: parts.month!, day: parts.day!)
                    let expected = parts.hour! < calendar.rolloverHour ? civil.adding(days: -1) : civil
                    XCTAssertEqual(decoded.day, expected.index, "\(calendar.timeZone.identifier) \(date)")
                    XCTAssertEqual(decoded.hour, parts.hour!, "\(calendar.timeZone.identifier) \(date)")
                    XCTAssertEqual(decoded.slot, calendar.hourSlot(of: date))
                    XCTAssertEqual(calendar.day(of: date), expected)
                    date = date.addingTimeInterval(37 * 60)
                }
            }
        }
    }

    func testEqualityComparesZoneAndRollover() {
        XCTAssertEqual(moscow, ActivityCalendar(timeZone: TimeZone(identifier: "Europe/Moscow")!))
        XCTAssertNotEqual(moscow, ActivityCalendar(timeZone: TimeZone(identifier: "Europe/Moscow")!, rolloverHour: 4))
        XCTAssertNotEqual(moscow, berlin)
        XCTAssertEqual(moscow.rolloverHour, ActivityCalendar.defaultRolloverHour)
        XCTAssertEqual(moscow.gregorian.firstWeekday, 2)
        XCTAssertEqual(moscow.gregorian.minimumDaysInFirstWeek, 4)
        XCTAssertEqual(moscow.gregorian.timeZone.identifier, "Europe/Moscow")
        XCTAssertEqual(ActivityCalendar.current.timeZone.identifier, TimeZone.current.identifier)
        XCTAssertEqual(ActivityCalendar.current.rolloverHour, 5)
    }

    private func utc(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }
}
