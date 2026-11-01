import Foundation

public enum StatsPeriod: String, CaseIterable, Identifiable, Equatable, Sendable {
    case week = "7D"
    case month = "30D"
    case quarter = "90D"
    case all = "All"

    public var id: String { rawValue }

    /// Nil for all saved history, which starts at the scope's first recorded day.
    public var dayCount: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .all: return nil
        }
    }

    public var title: String {
        switch self {
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        case .quarter: return "Last 90 days"
        case .all: return "All saved history"
        }
    }
}

public enum BucketUnit: Equatable, Sendable {
    case day
    case week
    case month
}

public struct PeriodTotals: Equatable, Sendable {
    public var edits: Int
    public var delegatedEdits: Int
    public var sessions: Int
    /// Days with at least one edit. Sessions alone never make a day active.
    public var activeDays: Int
    public var dayCount: Int

    public init(edits: Int, delegatedEdits: Int, sessions: Int, activeDays: Int, dayCount: Int) {
        self.edits = edits
        self.delegatedEdits = delegatedEdits
        self.sessions = sessions
        self.activeDays = activeDays
        self.dayCount = dayCount
    }

    public var editsPerActiveDay: Double? {
        activeDays > 0 ? Double(edits) / Double(activeDays) : nil
    }
}

public struct StreakSummary: Equatable, Sendable {
    /// The run ending today, or yesterday while today has no edit yet.
    public var current: Int
    public var longest: Int
    /// Last day of the longest run; the latest run wins a tie.
    public var longestEnd: DayKey?

    public init(current: Int, longest: Int, longestEnd: DayKey?) {
        self.current = current
        self.longest = longest
        self.longestEnd = longestEnd
    }

    public static let empty = StreakSummary(current: 0, longest: 0, longestEnd: nil)
}

public struct DayTotal: Equatable, Sendable {
    public var day: DayKey
    public var edits: Int
    public var sessions: Int
    /// Profiles with an edit or a session that day.
    public var profiles: Int

    public init(day: DayKey, edits: Int, sessions: Int, profiles: Int) {
        self.day = day
        self.edits = edits
        self.sessions = sessions
        self.profiles = profiles
    }
}

/// One profile's share of a chart bucket. `start` is the true week or month
/// start even when the range clips it; `isPartial` marks the clipped ones.
public struct Bucket: Identifiable, Equatable, Sendable {
    public var start: DayKey
    public var sourceID: String
    public var edits: Int
    public var sessions: Int
    public var isPartial: Bool

    public init(start: DayKey, sourceID: String, edits: Int, sessions: Int, isPartial: Bool) {
        self.start = start
        self.sourceID = sourceID
        self.edits = edits
        self.sessions = sessions
        self.isPartial = isPartial
    }

    public var id: String { "\(sourceID)|\(start.index)" }
}

public struct AveragePoint: Equatable, Sendable {
    public var day: DayKey
    public var value: Double

    public init(day: DayKey, value: Double) {
        self.day = day
        self.value = value
    }
}

/// Nearest-rank quartiles of non-zero values, mapping a count to levels 0-4.
public struct LevelThresholds: Equatable, Sendable {
    public var q1: Int
    public var q2: Int
    public var q3: Int

    public init(q1: Int, q2: Int, q3: Int) {
        self.q1 = q1
        self.q2 = q2
        self.q3 = q3
    }

    public static let empty = LevelThresholds(q1: 0, q2: 0, q3: 0)

    public func level(_ count: Int) -> Int {
        if count <= 0 { return 0 }
        if count <= q1 { return 1 }
        if count <= q2 { return 2 }
        if count <= q3 { return 3 }
        return 4
    }

    /// Zeros are ignored, so empty days never pull the quartiles down.
    static func make(_ values: [Int]) -> LevelThresholds {
        let sorted = values.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return .empty }
        func rank(_ percent: Int) -> Int {
            let position = (percent * sorted.count + 99) / 100
            return sorted[min(sorted.count - 1, max(0, position - 1))]
        }
        return LevelThresholds(q1: rank(25), q2: rank(50), q3: rank(75))
    }
}

public struct CalendarCell: Equatable, Sendable {
    public var day: DayKey
    public var edits: Int
    public var sessions: Int
    public var profiles: Int
    /// Edits by source ID; sources without edits that day are absent.
    public var bySource: [String: Int]
    public var isFuture: Bool
    /// Before the scope's first recorded edit or session.
    public var beforeHistory: Bool
    public var inRange: Bool

    public init(day: DayKey, edits: Int, sessions: Int, profiles: Int, bySource: [String: Int],
                isFuture: Bool, beforeHistory: Bool, inRange: Bool) {
        self.day = day
        self.edits = edits
        self.sessions = sessions
        self.profiles = profiles
        self.bySource = bySource
        self.isFuture = isFuture
        self.beforeHistory = beforeHistory
        self.inRange = inRange
    }
}

/// 26 Monday-first weeks ending with the current week.
public struct CalendarGrid: Equatable, Sendable {
    public var firstDay: DayKey
    public var weeks: Int
    /// Column-major: `cells[week * 7 + weekday]`.
    public var cells: [CalendarCell]
    public var thresholds: LevelThresholds
    public var sourceThresholds: [String: LevelThresholds]
    /// Edits by weekday (Monday first) over the grid's non-future days.
    public var weekdayTotals: [Int]
    public var weekdayShare: [Double]

    public init(firstDay: DayKey, weeks: Int, cells: [CalendarCell], thresholds: LevelThresholds,
                sourceThresholds: [String: LevelThresholds], weekdayTotals: [Int], weekdayShare: [Double]) {
        self.firstDay = firstDay
        self.weeks = weeks
        self.cells = cells
        self.thresholds = thresholds
        self.sourceThresholds = sourceThresholds
        self.weekdayTotals = weekdayTotals
        self.weekdayShare = weekdayShare
    }
}

public enum Chronotype: String, Equatable, Sendable {
    case earlyBird
    case daytime
    case evening
    case nightOwl
    case roundTheClock

    public var title: String {
        switch self {
        case .earlyBird: return "Early bird"
        case .daytime: return "Daytime"
        case .evening: return "Evening"
        case .nightOwl: return "Night owl"
        case .roundTheClock: return "Round the clock"
        }
    }
}

public struct RhythmSummary: Equatable, Sendable {
    /// 7 × 24, row-major `weekday * 24 + slot`: the activity day's weekday and
    /// the hour counted from the rollover.
    public var grid: [Int]
    /// Wall-clock hours 0-23.
    public var hourTotals: [Int]
    public var total: Int
    public var peakHour: Int?
    public var peakCell: Int?
    /// Share of edits between 22:00 and 05:00.
    public var nightShare: Double
    public var busiestWeekday: Int?
    public var quietestWeekday: Int?
    /// Nil below 50 edits, where a rhythm would be noise.
    public var chronotype: Chronotype?
    public var levels: LevelThresholds

    public init(grid: [Int], hourTotals: [Int], total: Int, peakHour: Int?, peakCell: Int?, nightShare: Double,
                busiestWeekday: Int?, quietestWeekday: Int?, chronotype: Chronotype?, levels: LevelThresholds) {
        self.grid = grid
        self.hourTotals = hourTotals
        self.total = total
        self.peakHour = peakHour
        self.peakCell = peakCell
        self.nightShare = nightShare
        self.busiestWeekday = busiestWeekday
        self.quietestWeekday = quietestWeekday
        self.chronotype = chronotype
        self.levels = levels
    }
}

public struct SourceShare: Identifiable, Equatable, Sendable {
    public var sourceID: String
    public var edits: Int
    public var delegatedEdits: Int
    public var sessions: Int
    public var activeDays: Int
    public var share: Double
    /// Nil without a previous window or when it had no edits.
    public var previousShare: Double?
    /// Earliest edit or session over the scope's full saved history.
    public var firstDay: DayKey?
    /// Grok records no subagents, so its delegated count means "unknown", not zero.
    public var delegationReported: Bool

    public init(sourceID: String, edits: Int, delegatedEdits: Int, sessions: Int, activeDays: Int, share: Double,
                previousShare: Double?, firstDay: DayKey?, delegationReported: Bool) {
        self.sourceID = sourceID
        self.edits = edits
        self.delegatedEdits = delegatedEdits
        self.sessions = sessions
        self.activeDays = activeDays
        self.share = share
        self.previousShare = previousShare
        self.firstDay = firstDay
        self.delegationReported = delegationReported
    }

    public var id: String { sourceID }
}

public struct SourceCount: Equatable, Sendable {
    public var sourceID: String
    public var edits: Int

    public init(sourceID: String, edits: Int) {
        self.sourceID = sourceID
        self.edits = edits
    }
}

public struct ProjectRow: Identifiable, Equatable, Sendable {
    public var path: String
    public var name: String
    public var edits: Int
    /// Nil for all saved history, which has no previous window.
    public var previousEdits: Int?
    public var bySource: [SourceCount]
    public var latestEditDay: DayKey?

    public init(path: String, name: String, edits: Int, previousEdits: Int?, bySource: [SourceCount], latestEditDay: DayKey?) {
        self.path = path
        self.name = name
        self.edits = edits
        self.previousEdits = previousEdits
        self.bySource = bySource
        self.latestEditDay = latestEditDay
    }

    public var id: String { path }
}

/// Everything the Growth tab shows for one scope and period, computed once.
public struct ActivityStatistics: Equatable, Sendable {
    public var period: StatsPeriod
    public var projectPath: String?
    public var range: DayRange
    public var previousRange: DayRange?
    public var unit: BucketUnit
    public var current: PeriodTotals
    public var previous: PeriodTotals?
    /// Over the scope's full saved history, not only the range.
    public var streaks: StreakSummary
    public var busiestDay: DayTotal?
    public var longestQuietStretch: Int
    /// Sparse: a source appears in a bucket only with an edit or a session there.
    public var buckets: [Bucket]
    public var bucketStarts: [DayKey]
    public var rollingAverage: [AveragePoint]
    /// Dense running totals per source, one entry per bucket start.
    public var cumulative: [Bucket]
    public var calendar: CalendarGrid
    public var rhythm: RhythmSummary
    public var sources: [SourceShare]
    /// All projects only.
    public var projects: [ProjectRow]
    public var projectsTouched: Int
    public var projectCount: Int
    public var sharedDays: Int
    public var firstRecordedDay: DayKey?

    public init(period: StatsPeriod, projectPath: String?, range: DayRange, previousRange: DayRange?, unit: BucketUnit,
                current: PeriodTotals, previous: PeriodTotals?, streaks: StreakSummary, busiestDay: DayTotal?,
                longestQuietStretch: Int, buckets: [Bucket], bucketStarts: [DayKey], rollingAverage: [AveragePoint],
                cumulative: [Bucket], calendar: CalendarGrid, rhythm: RhythmSummary, sources: [SourceShare],
                projects: [ProjectRow], projectsTouched: Int, projectCount: Int, sharedDays: Int, firstRecordedDay: DayKey?) {
        self.period = period
        self.projectPath = projectPath
        self.range = range
        self.previousRange = previousRange
        self.unit = unit
        self.current = current
        self.previous = previous
        self.streaks = streaks
        self.busiestDay = busiestDay
        self.longestQuietStretch = longestQuietStretch
        self.buckets = buckets
        self.bucketStarts = bucketStarts
        self.rollingAverage = rollingAverage
        self.cumulative = cumulative
        self.calendar = calendar
        self.rhythm = rhythm
        self.sources = sources
        self.projects = projects
        self.projectsTouched = projectsTouched
        self.projectCount = projectCount
        self.sharedDays = sharedDays
        self.firstRecordedDay = firstRecordedDay
    }

    /// Statistics of an empty index, anchored at day 0 so it never reads the clock.
    public static func empty(period: StatsPeriod) -> ActivityStatistics {
        StatsIndex.empty.statistics(projectPath: nil, period: period)
    }
}

public enum Momentum: String, Equatable, Sendable {
    /// First edit within the last 7 days.
    case new
    /// No edit in the last 14 days.
    case dormant
}

public struct ProjectTrend: Equatable, Sendable {
    public var path: String
    /// Edits per day, oldest first, ending today.
    public var daily30: [Int]
    public var edits7: Int
    public var previous7: Int
    public var edits30: Int
    public var previous30: Int
    public var totalEdits: Int
    public var totalSessions: Int
    public var currentStreak: Int
    /// Edits per source in sources order over 30 days, or over all history when those were empty.
    public var mix: [SourceCount]
    public var mixIsAllTime: Bool
    public var momentum: Momentum?
    public var firstEditDay: DayKey?
    public var lastEditDay: DayKey?
    /// Whether saved history reaches back over the previous 7 or 30 days.
    /// Assistants delete old sessions, so an empty earlier window often means
    /// "not recorded", not "no work"; changes are shown only when covered.
    public var hasPrevious7: Bool
    public var hasPrevious30: Bool

    public init(path: String, daily30: [Int], edits7: Int, previous7: Int, edits30: Int, previous30: Int,
                totalEdits: Int, totalSessions: Int, currentStreak: Int, mix: [SourceCount], mixIsAllTime: Bool,
                momentum: Momentum?, firstEditDay: DayKey?, lastEditDay: DayKey?,
                hasPrevious7: Bool = true, hasPrevious30: Bool = true) {
        self.path = path
        self.daily30 = daily30
        self.edits7 = edits7
        self.previous7 = previous7
        self.edits30 = edits30
        self.previous30 = previous30
        self.totalEdits = totalEdits
        self.totalSessions = totalSessions
        self.currentStreak = currentStreak
        self.mix = mix
        self.mixIsAllTime = mixIsAllTime
        self.momentum = momentum
        self.firstEditDay = firstEditDay
        self.lastEditDay = lastEditDay
        self.hasPrevious7 = hasPrevious7
        self.hasPrevious30 = hasPrevious30
    }
}

public struct PulseSummary: Equatable, Sendable {
    public var edits7: Int
    public var previous7: Int
    /// Edits per day, oldest first, ending today.
    public var daily14: [Int]
    public var activeProjects7: Int
    public var projectCount: Int
    public var streaks: StreakSummary
    /// Whether saved history reaches back over the previous 7 days.
    public var hasPrevious7: Bool

    public init(edits7: Int, previous7: Int, daily14: [Int], activeProjects7: Int, projectCount: Int, streaks: StreakSummary,
                hasPrevious7: Bool = true) {
        self.edits7 = edits7
        self.previous7 = previous7
        self.daily14 = daily14
        self.activeProjects7 = activeProjects7
        self.projectCount = projectCount
        self.streaks = streaks
        self.hasPrevious7 = hasPrevious7
    }

    public static let empty = PulseSummary(edits7: 0, previous7: 0, daily14: Array(repeating: 0, count: 14),
                                           activeProjects7: 0, projectCount: 0, streaks: .empty, hasPrevious7: false)
}

/// Round chart axes: a 1/2/2.5/5 step with 10% headroom above the maximum.
public enum NiceScale {
    public static func ticks(maximum: Double, count: Int = 3) -> (step: Double, top: Double, values: [Double]) {
        let largest = maximum.isFinite ? max(1, maximum) : 1
        let roughStep = max(1, largest * 1.10 / Double(max(1, count)))
        let power = pow(10, (log10(roughStep)).rounded(.down))
        let normalized = roughStep / power
        // Round upward: rounding 470 down to 200 creates eight cramped ticks.
        let factor = [1.0, 2.0, 2.5, 5.0, 10.0].first { $0 >= normalized } ?? 10
        let step = max(1, factor * power)
        let top = (largest * 1.10 / step).rounded(.up) * step
        return (step, top, Array(stride(from: 0.0, through: top, by: step)))
    }
}
