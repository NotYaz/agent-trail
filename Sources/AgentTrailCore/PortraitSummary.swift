import Foundation

public struct PortraitDay: Equatable, Sendable {
    public let day: DayKey
    public let edits: Int
    public let sessions: Int

    public init(day: DayKey, edits: Int, sessions: Int) {
        self.day = day
        self.edits = edits
        self.sessions = sessions
    }
}

public struct PortraitAgent: Identifiable, Equatable, Sendable {
    /// For the color lookup only; the card never renders it.
    public let sourceID: String
    public let name: String
    /// Days in the range with an edit or a session from this agent.
    public let days: [PortraitDay]

    public init(sourceID: String, name: String, days: [PortraitDay]) {
        self.sourceID = sourceID
        self.name = name
        self.days = days
    }

    public var id: String { sourceID }
}

public enum PortraitStrip: Equatable, Sendable {
    /// Every day of a 7-day range.
    case days([PortraitDay])
    /// Monday-aligned weeks, at most the 26 latest. `days` holds only the
    /// range's days, so cells outside the window stay empty.
    case weeks(firstDay: DayKey, weeks: Int, days: [PortraitDay])
}

/// What an exported share card may show. It carries day totals only, with no
/// hour, slot or weekday-share field, so rhythm can never reach an image, and
/// no path in any mode.
public struct PortraitSummary: Equatable, Sendable {
    public let headline: String
    public let scopeTitle: String
    public let periodTitle: String
    public let dateRangeText: String
    public let edits: Int
    public let sessions: Int
    public let activeDays: Int
    /// The longest run of active days inside the range.
    public let longestStreak: Int
    public let agents: [PortraitAgent]
    public let strip: PortraitStrip
    public let namesShown: Bool
    public let calendar: ActivityCalendar
    /// The day with the most edits in the whole range, ties to the latest.
    /// The strip keeps at most 26 weeks, so the caption cannot use its days.
    public let busiestDay: PortraitDay?

    public init(headline: String, scopeTitle: String, periodTitle: String, dateRangeText: String, edits: Int,
                sessions: Int, activeDays: Int, longestStreak: Int, agents: [PortraitAgent], strip: PortraitStrip,
                namesShown: Bool, calendar: ActivityCalendar, busiestDay: PortraitDay? = nil) {
        self.headline = headline
        self.scopeTitle = scopeTitle
        self.periodTitle = periodTitle
        self.dateRangeText = dateRangeText
        self.edits = edits
        self.sessions = sessions
        self.activeDays = activeDays
        self.longestStreak = longestStreak
        self.agents = agents
        self.strip = strip
        self.namesShown = namesShown
        self.calendar = calendar
        self.busiestDay = busiestDay
    }
}

extension StatsIndex {
    /// Only the scope's activity inside the period's range. Profiles become
    /// "Agent N" and the project "My project" unless `showNames` is set.
    public func portrait(projectPath: String?, period: StatsPeriod, showNames: Bool, locale: Locale = .current) -> PortraitSummary {
        let scope = self.scope(for: projectPath)
        let range = Self.range(for: period, today: today.index, firstDay: firstDay(of: scope))
        let first = range.first.index, last = range.last.index
        let scan = self.scan(scope, lo: first, hi: last, range: range, previous: nil)

        var edits = 0, sessions = 0, activeDays = 0
        var streak = StreakTracker()
        var days: [PortraitDay] = []
        var busiest: PortraitDay?
        for day in first...last {
            let count = scan.edits(day), started = scan.sessions(day)
            edits += count
            sessions += started
            let portraitDay = PortraitDay(day: DayKey(index: day), edits: count, sessions: started)
            if count > 0 {
                activeDays += 1
                streak.add(day)
                // Same rule as the Growth tile: ties go to the latest day.
                if count >= (busiest?.edits ?? 0) { busiest = portraitDay }
            }
            days.append(portraitDay)
        }

        var agents: [PortraitAgent] = []
        for source in 0..<sourceOrder.count {
            var agentDays: [PortraitDay] = []
            for day in first...last {
                let count = scan.sourceEdits(day, source), started = scan.sourceSessions(day, source)
                if count > 0 || started > 0 {
                    agentDays.append(PortraitDay(day: DayKey(index: day), edits: count, sessions: started))
                }
            }
            guard !agentDays.isEmpty else { continue }
            let name = showNames ? sourceNames[source] : "Agent \(agents.count + 1)"
            agents.append(PortraitAgent(sourceID: sourceOrder[source], name: name, days: agentDays))
        }

        let strip: PortraitStrip
        if period == .week {
            strip = .days(days)
        } else {
            let lastWeek = range.last.weekStart
            let firstWeek = max(range.first.weekStart, lastWeek.adding(days: -25 * 7))
            strip = .weeks(firstDay: firstWeek, weeks: firstWeek.days(to: lastWeek) / 7 + 1,
                           days: days.filter { $0.day >= firstWeek })
        }

        return PortraitSummary(
            headline: Self.headline(edits: edits, sessions: sessions, agents: agents.count, activeDays: activeDays, locale: locale),
            scopeTitle: portraitScopeTitle(projectPath: projectPath, scope: scope, scan: scan, showNames: showNames),
            periodTitle: period.title, dateRangeText: dateRangeText(range, locale: locale),
            edits: edits, sessions: sessions, activeDays: activeDays, longestStreak: streak.longest,
            agents: agents, strip: strip, namesShown: showNames, calendar: calendar, busiestDay: busiest)
    }

    private func portraitScopeTitle(projectPath: String?, scope: Scope, scan: ScopeScan, showNames: Bool) -> String {
        if let projectPath {
            guard showNames else { return "My project" }
            let name = scope.project.map { projectNames[Int($0)] } ?? URL(fileURLWithPath: projectPath).lastPathComponent
            // A root folder's name is "/", which would read as a path.
            return name.isEmpty || name.contains("/") ? "Project" : name
        }
        let count = scan.projectActive.filter { $0 }.count
        switch count {
        case 0: return "No projects"
        case 1: return "1 project"
        default: return "\(count) projects"
        }
    }

    /// Without edits the card says what remains, so no variant reads "0 edits".
    static func headline(edits: Int, sessions: Int, agents: Int, activeDays: Int, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        func number(_ value: Int) -> String { formatter.string(from: NSNumber(value: value)) ?? String(value) }
        if edits == 0 {
            guard sessions > 0 else { return "A quiet\nstretch." }
            let noun = sessions == 1 ? "session" : "sessions"
            return "\(number(sessions)) saved\n\(noun)."
        }
        if agents >= 2 {
            let noun = edits == 1 ? "edit" : "edits"
            return "\(number(edits)) \(noun).\n\(number(agents)) agents."
        }
        let noun = activeDays == 1 ? "day" : "days"
        return "One agent.\n\(number(activeDays)) active \(noun)."
    }

    private func dateRangeText(_ range: DayRange, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM d, yyyy")
        let start = formatter.string(from: calendar.noon(of: range.first))
        let end = formatter.string(from: calendar.noon(of: range.last))
        return start == end ? start : "\(start) – \(end)"
    }
}
