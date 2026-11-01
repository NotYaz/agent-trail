import Foundation

/// A civil date, counted in days since 1970-01-01. It carries no time zone, so
/// statistics compare and step days with integer math instead of a Calendar.
public struct DayKey: Hashable, Comparable, Sendable {
    public let index: Int

    public init(index: Int) {
        self.index = index
    }

    public init(year: Int, month: Int, day: Int) {
        index = Self.daysFromCivil(year: year, month: month, day: day)
    }

    public var year: Int { Self.civilFromDays(index).year }
    public var month: Int { Self.civilFromDays(index).month }
    public var day: Int { Self.civilFromDays(index).day }
    /// 0 = Monday … 6 = Sunday. 1970-01-01 was a Thursday.
    public var weekday: Int { ((index % 7) + 7 + 3) % 7 }

    public func adding(days: Int) -> DayKey {
        DayKey(index: index + days)
    }

    public func days(to other: DayKey) -> Int {
        other.index - index
    }

    /// The Monday on or before this day.
    public var weekStart: DayKey { adding(days: -weekday) }

    public var monthStart: DayKey {
        let civil = Self.civilFromDays(index)
        return DayKey(year: civil.year, month: civil.month, day: 1)
    }

    /// The first day of the following month.
    var nextMonthStart: DayKey {
        let civil = Self.civilFromDays(index)
        return civil.month == 12 ? DayKey(year: civil.year + 1, month: 1, day: 1)
            : DayKey(year: civil.year, month: civil.month + 1, day: 1)
    }

    public static func < (lhs: DayKey, rhs: DayKey) -> Bool {
        lhs.index < rhs.index
    }

    // Howard Hinnant's proleptic Gregorian algorithms.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shifted = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shifted + 2) / 5 + 1
        let month = shifted < 10 ? shifted + 3 : shifted - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }
}

/// An inclusive run of days.
public struct DayRange: Hashable, Sendable {
    public let first: DayKey
    public let last: DayKey

    public init(first: DayKey, last: DayKey) {
        self.first = first
        self.last = last
    }

    public var count: Int { max(0, last.index - first.index + 1) }

    public func contains(_ day: DayKey) -> Bool {
        first <= day && day <= last
    }

    public var days: [DayKey] {
        guard first <= last else { return [] }
        return (first.index...last.index).map(DayKey.init(index:))
    }
}

/// Local activity days: a day runs from `rolloverHour` to just before it on the
/// next morning, so late-night work counts toward the evening it started.
public struct ActivityCalendar: Sendable, Equatable {
    public static let defaultRolloverHour = 5

    public let timeZone: TimeZone
    public let rolloverHour: Int
    /// Monday-first ISO weeks in `timeZone`, for Charts' calendar environment.
    public let gregorian: Calendar

    public init(timeZone: TimeZone, rolloverHour: Int = ActivityCalendar.defaultRolloverHour) {
        self.timeZone = timeZone
        self.rolloverHour = min(23, max(0, rolloverHour))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        gregorian = calendar
    }

    /// A snapshot of the Mac's current time zone; rebuild it when the zone changes.
    public static var current: ActivityCalendar { ActivityCalendar(timeZone: TimeZone.current) }

    /// Plain UTC days, for tests and fixtures.
    public static let utcMidnight = ActivityCalendar(timeZone: TimeZone(secondsFromGMT: 0)!, rolloverHour: 0)

    public func day(of date: Date) -> DayKey {
        let local = Self.wallClock(date, offset: timeZone.secondsFromGMT(for: date))
        return activityDay(civilDay: local.day, hour: local.hour)
    }

    /// The wall-clock hour, 0…23.
    public func hour(of date: Date) -> Int {
        Self.wallClock(date, offset: timeZone.secondsFromGMT(for: date)).hour
    }

    /// The hour counted from the rollover, so a night stays contiguous.
    public func hourSlot(of date: Date) -> Int {
        (hour(of: date) - rolloverHour + 24) % 24
    }

    /// 12:00 local on that date, used as the plotting x-value.
    public func noon(of day: DayKey) -> Date {
        date(on: day, hour: 12)
    }

    /// The rollover hour on that civil date, when the activity day begins.
    public func start(of day: DayKey) -> Date {
        date(on: day, hour: rolloverHour)
    }

    public static func == (lhs: ActivityCalendar, rhs: ActivityCalendar) -> Bool {
        lhs.timeZone.identifier == rhs.timeZone.identifier && lhs.rolloverHour == rhs.rolloverHour
    }

    func activityDay(civilDay: Int, hour: Int) -> DayKey {
        DayKey(index: hour < rolloverHour ? civilDay - 1 : civilDay)
    }

    private func date(on day: DayKey, hour: Int) -> Date {
        let components = DateComponents(year: day.year, month: day.month, day: day.day, hour: hour)
        if let date = gregorian.date(from: components) { return date }
        let local = Double(day.index * 86_400 + hour * 3_600)
        return Date(timeIntervalSince1970: local - Double(timeZone.secondsFromGMT()))
    }

    /// Civil day and hour of an instant at a known UTC offset. This equals the
    /// Gregorian calendar's components in the zone, at the cost of one offset lookup.
    static func wallClock(_ date: Date, offset: Int) -> (day: Int, hour: Int) {
        let local = date.timeIntervalSince1970 + Double(offset)
        let day = Int((local / 86_400).rounded(.down))
        let hour = Int((local - Double(day) * 86_400) / 3_600)
        return (day, min(23, max(0, hour)))
    }
}

/// Decodes many ascending instants with one offset lookup per time-zone
/// transition instead of one per instant.
struct LocalClock {
    let calendar: ActivityCalendar
    private var validFrom = Date.distantFuture
    private var validUntil = Date.distantPast
    private var offset = 0

    init(calendar: ActivityCalendar) {
        self.calendar = calendar
    }

    /// Activity day, wall-clock hour and rollover-based slot.
    mutating func decode(_ date: Date) -> (day: Int, hour: Int, slot: Int) {
        if date < validFrom || date >= validUntil {
            offset = calendar.timeZone.secondsFromGMT(for: date)
            validFrom = date
            validUntil = calendar.timeZone.nextDaylightSavingTimeTransition(after: date) ?? .distantFuture
        }
        let local = ActivityCalendar.wallClock(date, offset: offset)
        let day = calendar.activityDay(civilDay: local.day, hour: local.hour).index
        return (day, local.hour, (local.hour - calendar.rolloverHour + 24) % 24)
    }
}
