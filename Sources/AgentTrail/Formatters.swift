import Foundation
import AgentTrailCore

/// Formatters are costly to build, and views format on every body pass, so each
/// configuration is built once and used under one lock.
private final class FormatterCache: @unchecked Sendable {
    static let shared = FormatterCache()

    private let lock = NSLock()
    private var dateFormatters: [String: DateFormatter] = [:]
    private var weekdaySymbols: [String: [[String]]] = [:]
    private let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    func string(from date: Date, template: String, timeZone: TimeZone) -> String {
        lock.lock()
        defer { lock.unlock() }
        let locale = Locale.current
        let key = "\(template)|\(timeZone.identifier)|\(locale.identifier)"
        if let formatter = dateFormatters[key] { return formatter.string(from: date) }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        dateFormatters[key] = formatter
        return formatter.string(from: date)
    }

    func relativeString(for date: Date, relativeTo now: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        relative.locale = Locale.current
        return relative.localizedString(for: date, relativeTo: now)
    }

    /// Full, short and very short weekday names, Sunday first as Foundation returns them.
    func weekdayNames() -> [[String]] {
        lock.lock()
        defer { lock.unlock() }
        let locale = Locale.current
        if let names = weekdaySymbols[locale.identifier] { return names }
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        let names = [calendar.weekdaySymbols, calendar.shortWeekdaySymbols, calendar.veryShortWeekdaySymbols]
        weekdaySymbols[locale.identifier] = names
        return names
    }
}

/// Home-relative paths for display. Replaces the per-view copies.
enum PathFormat {
    private static let home = NSHomeDirectory()

    static func abbreviate(_ path: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

/// Short relative ages such as "5 min. ago", with "just now" under a minute.
enum RelativeTime {
    static func string(for date: Date, now: Date) -> String {
        if abs(date.timeIntervalSince(now)) < 60 { return "just now" }
        return FormatterCache.shared.relativeString(for: date, relativeTo: now)
    }
}

/// Activity-day labels. Days are formatted at local noon in the activity
/// calendar's time zone, so the 05:00 rollover never shifts a label.
enum DayFormat {
    enum WeekdayStyle {
        case full
        case short
        case narrow
    }

    /// "Oct 21"
    static func short(_ day: DayKey, calendar: ActivityCalendar) -> String {
        format(day, template: "MMM d", calendar: calendar)
    }

    /// "Tue, Oct 21"
    static func long(_ day: DayKey, calendar: ActivityCalendar) -> String {
        format(day, template: "EEE MMM d", calendar: calendar)
    }

    /// "Oct 21, 2026"
    static func withYear(_ day: DayKey, calendar: ActivityCalendar) -> String {
        format(day, template: "MMM d yyyy", calendar: calendar)
    }

    /// "October 2026"
    static func month(_ day: DayKey, calendar: ActivityCalendar) -> String {
        format(day, template: "MMMM yyyy", calendar: calendar)
    }

    /// "Oct"; month labels above calendar columns.
    static func monthAbbreviation(_ day: DayKey, calendar: ActivityCalendar) -> String {
        format(day, template: "MMM", calendar: calendar)
    }

    /// "Oct 2 – Oct 31, 2026", or "Oct 31, 2026" for a single day. The year is
    /// repeated only when the range crosses one.
    static func range(_ range: DayRange, calendar: ActivityCalendar) -> String {
        if range.first == range.last { return withYear(range.last, calendar: calendar) }
        let start = range.first.year == range.last.year ? short(range.first, calendar: calendar)
            : withYear(range.first, calendar: calendar)
        return "\(start) – \(withYear(range.last, calendar: calendar))"
    }

    /// A wall-clock hour label such as "06" or "23", locale-aware.
    static func hour(_ hour: Int) -> String {
        let utc = TimeZone(secondsFromGMT: 0) ?? .current
        let date = Date(timeIntervalSince1970: Double(((hour % 24) + 24) % 24) * 3_600)
        return FormatterCache.shared.string(from: date, template: "HH", timeZone: utc)
    }

    /// Weekday names with 0 = Monday … 6 = Sunday, matching `DayKey.weekday`.
    static func weekday(_ weekday: Int, style: WeekdayStyle = .short) -> String {
        let names = FormatterCache.shared.weekdayNames()
        let list: [String]
        switch style {
        case .full: list = names[0]
        case .short: list = names[1]
        case .narrow: list = names[2]
        }
        guard list.count == 7 else { return "" }
        return list[(((weekday % 7) + 7) % 7 + 1) % 7]
    }

    private static func format(_ day: DayKey, template: String, calendar: ActivityCalendar) -> String {
        FormatterCache.shared.string(from: calendar.noon(of: day), template: template, timeZone: calendar.timeZone)
    }
}

/// Compact counts for axes and tight tiles: "950", "1.2K", "12K".
enum CompactNumber {
    static func string(_ value: Int) -> String {
        if abs(value) < 1_000 { return value.formatted() }
        return string(Double(value))
    }

    static func string(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}

/// Period-over-period change labels. Always shown in neutral ink: more edits
/// are not better and fewer are not worse.
enum PercentChange {
    /// Rounded percent change, or nil when there is nothing to compare against.
    static func percent(current: Int, previous: Int?) -> Int? {
        guard let previous, previous > 0 else { return nil }
        return Int((Double(current - previous) / Double(previous) * 100).rounded())
    }

    /// "▲18%", "▼9%", "±0%" or "New"; nil when hidden.
    static func label(current: Int, previous: Int?) -> String? {
        guard let previous else { return nil }
        if previous == 0 { return current > 0 ? "New" : nil }
        guard let change = percent(current: current, previous: previous) else { return nil }
        if change > 0 { return "▲\(change)%" }
        if change < 0 { return "▼\(-change)%" }
        return "±0%"
    }

    /// "up 18 percent", "down 9 percent", "no change" or "new"; nil when hidden.
    static func accessibility(current: Int, previous: Int?) -> String? {
        guard let previous else { return nil }
        if previous == 0 { return current > 0 ? "new" : nil }
        guard let change = percent(current: current, previous: previous) else { return nil }
        if change > 0 { return "up \(change) percent" }
        if change < 0 { return "down \(-change) percent" }
        return "no change"
    }

    /// Share change in percentage points: "+4 pts", "−3 pts" or "±0 pts"; nil without a previous share.
    static func points(share: Double, previous: Double?) -> String? {
        guard let previous else { return nil }
        let change = Int(((share - previous) * 100).rounded())
        if change > 0 { return "+\(change) pts" }
        if change < 0 { return "\u{2212}\(-change) pts" }
        return "±0 pts"
    }
}

/// Share labels such as "54%", with "<1%" for a share that rounds to zero.
enum PercentFormat {
    static func share(_ fraction: Double) -> String {
        guard fraction > 0 else { return "0%" }
        let percent = Int((fraction * 100).rounded())
        return percent == 0 ? "<1%" : "\(percent)%"
    }
}
