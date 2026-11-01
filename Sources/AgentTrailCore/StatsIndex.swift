import Foundation

/// One confirmed edit, decoded once into its local activity day and hour.
/// About 12 bytes, so a query is a linear scan over contiguous rows.
struct EditRow: Sendable {
    var day: Int32
    var slot: UInt8
    var hour: UInt8
    var weekday: UInt8
    var source: UInt8
    var project: UInt16
    var delegated: Bool
}

struct SessionRow: Sendable {
    var day: Int32
    var source: UInt8
    var project: UInt16
}

/// Every statistic the UI shows, derived from raw edit moments and session
/// starts in local activity days. Building decodes each moment once; a time-zone
/// change needs a rebuild, never a rescan. It never reads `ProjectSummary.history`.
public struct StatsIndex: Sendable {
    /// Anchored at day 0 in UTC so it never reads the clock.
    public static let empty = StatsIndex.build(projects: [], sources: [], calendar: .utcMidnight,
                                               now: Date(timeIntervalSince1970: 0))

    public let calendar: ActivityCalendar
    public let today: DayKey
    /// Configured sources in order, then unconfigured IDs found in history, sorted.
    public let sourceOrder: [String]
    /// Projects with at least one edit or session, in input order.
    public let projectPaths: [String]
    /// Keyed by `ProjectSummary.path`, which equals `ProjectOverview.path`.
    public let trends: [String: ProjectTrend]
    public let pulse: PulseSummary
    /// The earliest local day with a saved edit or session, in any project.
    /// A comparison with an earlier window is made only when history starts on
    /// or before that window: assistants delete old sessions, so a gap before
    /// this day means "not recorded", not "no work".
    public let historyStart: DayKey?

    /// Both sorted by day.
    let edits: [EditRow]
    let sessions: [SessionRow]
    let sourceNames: [String]
    let reportsDelegation: [Bool]
    let projectNames: [String]
    let projectLookup: [String: Int]
    /// Earliest edit or session per project; Int.max when there is none.
    let projectFirstDay: [Int]

    public var isEmpty: Bool { projectPaths.isEmpty }

    /// `projects` must already be de-duplicated, as overview histories are.
    public static func build(projects: [ProjectSummary], sources: [AgentSource], calendar: ActivityCalendar, now: Date) -> StatsIndex {
        var order: [String] = []
        var configured: [String: AgentSource] = [:]
        for source in sources where configured[source.id] == nil {
            configured[source.id] = source
            order.append(source.id)
        }
        let recorded = Set(projects.flatMap { $0.activities.map(\.sourceID) })
        order += recorded.subtracting(order).sorted()
        // Rows store the source in a byte; real setups have a handful of profiles.
        order = Array(order.prefix(Int(UInt8.max) + 1))
        var sourceLookup: [String: Int] = [:]
        for (index, id) in order.enumerated() { sourceLookup[id] = index }

        var paths: [String] = []
        var names: [String] = []
        var projectLookup: [String: Int] = [:]
        var edits: [EditRow] = []
        var sessions: [SessionRow] = []
        let momentCount = projects.reduce(0) { total, project in
            total + project.activities.reduce(0) { $0 + $1.editMoments.count }
        }
        edits.reserveCapacity(momentCount)
        for project in projects {
            let activities = project.activities.filter {
                sourceLookup[$0.sourceID] != nil && (!$0.editMoments.isEmpty || !$0.sessionStarts.isEmpty)
            }
            guard !activities.isEmpty else { continue }
            let projectIndex: Int
            if let known = projectLookup[project.path] {
                projectIndex = known
            } else {
                guard paths.count <= Int(UInt16.max) else { continue }
                projectIndex = paths.count
                projectLookup[project.path] = projectIndex
                paths.append(project.path)
                names.append(project.name)
            }
            for activity in activities {
                guard let sourceIndex = sourceLookup[activity.sourceID] else { continue }
                let source = UInt8(sourceIndex), projectID = UInt16(projectIndex)
                var editClock = LocalClock(calendar: calendar)
                for moment in activity.editMoments {
                    let local = editClock.decode(moment.date)
                    edits.append(EditRow(day: Int32(clamping: local.day), slot: UInt8(local.slot), hour: UInt8(local.hour),
                                         weekday: UInt8(DayKey(index: local.day).weekday), source: source,
                                         project: projectID, delegated: moment.delegated))
                }
                var sessionClock = LocalClock(calendar: calendar)
                for start in activity.sessionStarts {
                    sessions.append(SessionRow(day: Int32(clamping: sessionClock.decode(start).day), source: source, project: projectID))
                }
            }
        }
        edits.sort { $0.day < $1.day }
        sessions.sort { $0.day < $1.day }

        let today = calendar.day(of: now)
        let starts = [edits.first.map { Int($0.day) }, sessions.first.map { Int($0.day) }].compactMap { $0 }
        let historyStart = starts.min()
        let summary = Self.summarize(edits: edits, sessions: sessions, paths: paths, sourceOrder: order,
                                     today: today.index, historyStart: historyStart)
        let sourceNames: [String] = order.map { (id: String) -> String in
            guard let name = configured[id]?.name, !name.isEmpty else { return "Unknown profile" }
            return name
        }
        // Grok records no subagents; an unconfigured ID keeps the default assistant.
        let reportsDelegation: [Bool] = order.map { (id: String) -> Bool in configured[id]?.assistant != .grok }
        return StatsIndex(calendar: calendar, today: today, sourceOrder: order, projectPaths: paths,
                          trends: summary.trends, pulse: summary.pulse,
                          historyStart: historyStart.map(DayKey.init(index:)), edits: edits, sessions: sessions,
                          sourceNames: sourceNames, reportsDelegation: reportsDelegation,
                          projectNames: names, projectLookup: projectLookup,
                          projectFirstDay: summary.firstDay)
    }

    private struct BuildSummary {
        var trends: [String: ProjectTrend]
        var pulse: PulseSummary
        var firstDay: [Int]
    }

    /// Card trends and the Pulse strip, from one pass over the sorted rows.
    private static func summarize(edits: [EditRow], sessions: [SessionRow], paths: [String], sourceOrder: [String],
                                  today: Int, historyStart: Int?) -> BuildSummary {
        let hasPrevious7 = historyStart.map { $0 <= today - 13 } ?? false
        let hasPrevious30 = historyStart.map { $0 <= today - 59 } ?? false
        let projectCount = paths.count, sourceCount = sourceOrder.count
        var firstDay = [Int](repeating: Int.max, count: projectCount)
        var firstEdit = [Int](repeating: Int.max, count: projectCount)
        var lastEdit = [Int](repeating: Int.min, count: projectCount)
        var totalEdits = [Int](repeating: 0, count: projectCount)
        var totalSessions = [Int](repeating: 0, count: projectCount)
        var edits7 = [Int](repeating: 0, count: projectCount)
        var previous7 = [Int](repeating: 0, count: projectCount)
        var previous30 = [Int](repeating: 0, count: projectCount)
        var daily30 = [Int](repeating: 0, count: projectCount * 30)
        var recentMix = [Int](repeating: 0, count: projectCount * sourceCount)
        var allTimeMix = [Int](repeating: 0, count: projectCount * sourceCount)
        var streaks = [StreakTracker](repeating: StreakTracker(), count: projectCount)
        var overall = StreakTracker()
        var daily14 = [Int](repeating: 0, count: 14)
        for row in edits {
            let project = Int(row.project), day = Int(row.day)
            totalEdits[project] += 1
            allTimeMix[project * sourceCount + Int(row.source)] += 1
            firstEdit[project] = min(firstEdit[project], day)
            lastEdit[project] = max(lastEdit[project], day)
            let ago = today - day
            guard ago >= 0 else { continue }
            streaks[project].add(day)
            overall.add(day)
            if ago < 30 {
                daily30[project * 30 + 29 - ago] += 1
                recentMix[project * sourceCount + Int(row.source)] += 1
            } else if ago < 60 {
                previous30[project] += 1
            }
            if ago < 7 { edits7[project] += 1 } else if ago < 14 { previous7[project] += 1 }
            if ago < 14 { daily14[13 - ago] += 1 }
        }
        for row in sessions {
            let project = Int(row.project)
            totalSessions[project] += 1
            firstDay[project] = min(firstDay[project], Int(row.day))
        }

        var trends: [String: ProjectTrend] = [:]
        for project in 0..<projectCount {
            firstDay[project] = min(firstDay[project], firstEdit[project])
            let window = Array(daily30[(project * 30)..<(project * 30 + 30)])
            let recent = recentMix[(project * sourceCount)..<(project * sourceCount + sourceCount)]
            let isAllTime = recent.reduce(0, +) == 0
            let counts = isAllTime ? allTimeMix[(project * sourceCount)..<(project * sourceCount + sourceCount)] : recent
            var mix: [SourceCount] = []
            for (offset, count) in counts.enumerated() where count > 0 {
                mix.append(SourceCount(sourceID: sourceOrder[offset], edits: count))
            }
            let hasEdits = totalEdits[project] > 0
            var momentum: Momentum?
            if hasEdits && firstEdit[project] >= today - 6 {
                momentum = .new
            } else if hasEdits && lastEdit[project] <= today - 14 {
                momentum = .dormant
            }
            trends[paths[project]] = ProjectTrend(
                path: paths[project], daily30: window, edits7: edits7[project], previous7: previous7[project],
                edits30: window.reduce(0, +), previous30: previous30[project], totalEdits: totalEdits[project],
                totalSessions: totalSessions[project], currentStreak: streaks[project].summary(today: today).current,
                mix: mix, mixIsAllTime: isAllTime, momentum: momentum,
                firstEditDay: hasEdits ? DayKey(index: firstEdit[project]) : nil,
                lastEditDay: hasEdits ? DayKey(index: lastEdit[project]) : nil,
                hasPrevious7: hasPrevious7, hasPrevious30: hasPrevious30)
        }
        let pulse = PulseSummary(edits7: edits7.reduce(0, +), previous7: previous7.reduce(0, +), daily14: daily14,
                                 activeProjects7: edits7.filter { $0 > 0 }.count, projectCount: projectCount,
                                 streaks: overall.summary(today: today), hasPrevious7: hasPrevious7)
        return BuildSummary(trends: trends, pulse: pulse, firstDay: firstDay)
    }

    // MARK: Statistics

    public func statistics(projectPath: String?, period: StatsPeriod) -> ActivityStatistics {
        let scope = self.scope(for: projectPath)
        let todayIndex = today.index
        let first = firstDay(of: scope)
        let range = Self.range(for: period, today: todayIndex, firstDay: first)
        let previousRange = period.dayCount.map {
            DayRange(first: range.first.adding(days: -$0), last: range.first.adding(days: -1))
        }
        // Changes compare against the previous window only when saved history covers it.
        let comparison = previousRange.flatMap { window -> DayRange? in
            guard let start = historyStart, start <= window.first else { return nil }
            return window
        }
        let gridFirst = today.weekStart.index - 25 * 7
        let gridLast = gridFirst + 26 * 7 - 1
        // One dense window covers full history (streaks), the grid, both
        // ranges, and the six days that seed the rolling average.
        var lo = min(range.first.index - 6, gridFirst)
        if let previousRange { lo = min(lo, previousRange.first.index) }
        if let first { lo = min(lo, first) }
        let scan = self.scan(scope, lo: lo, hi: max(todayIndex, gridLast), range: range, previous: comparison)

        let current = totals(scan, range, delegated: scan.delegated)
        let previous = comparison.map { totals(scan, $0, delegated: scan.previousDelegated) }
        var streak = StreakTracker()
        for day in lo...todayIndex where scan.edits(day) > 0 { streak.add(day) }
        let unit = Self.unit(forDayCount: range.count)
        let series = activeSources(scan, range)
        let charts = buckets(scan, range: range, unit: unit, sources: series)
        let rows = scope.project == nil ? projectRows(scan, compares: comparison != nil) : []
        return ActivityStatistics(
            period: period, projectPath: projectPath, range: range, previousRange: previousRange, unit: unit,
            current: current, previous: previous, streaks: streak.summary(today: todayIndex),
            busiestDay: busiestDay(scan, range), longestQuietStretch: quietStretch(scan, range),
            buckets: charts.buckets, bucketStarts: charts.starts,
            rollingAverage: unit == .day && range.count >= 14 ? rollingAverage(scan, range) : [],
            cumulative: charts.cumulative,
            calendar: calendarGrid(scan, firstDay: gridFirst, range: range, historyStart: first),
            rhythm: rhythm(scan), sources: shares(scan, range: range, previous: comparison, sources: series),
            projects: rows, projectsTouched: scan.projectEdits.filter { $0 > 0 }.count,
            projectCount: projectPaths.count, sharedDays: scan.sharedDays,
            firstRecordedDay: first.map(DayKey.init(index:)))
    }

    /// Rows a query covers. `project == nil` with `matchesNothing == false` is every project.
    struct Scope {
        var project: UInt16?
        var matchesNothing: Bool
    }

    func scope(for projectPath: String?) -> Scope {
        guard let projectPath else { return Scope(project: nil, matchesNothing: false) }
        guard let index = projectLookup[projectPath] else { return Scope(project: nil, matchesNothing: true) }
        return Scope(project: UInt16(index), matchesNothing: false)
    }

    func firstDay(of scope: Scope) -> Int? {
        if scope.matchesNothing { return nil }
        if let project = scope.project {
            let day = projectFirstDay[Int(project)]
            return day == Int.max ? nil : day
        }
        let days = [edits.first.map { Int($0.day) }, sessions.first.map { Int($0.day) }].compactMap { $0 }
        return days.min()
    }

    /// Fixed windows end today; all saved history starts at the scope's first recorded day.
    static func range(for period: StatsPeriod, today: Int, firstDay: Int?) -> DayRange {
        if let count = period.dayCount {
            return DayRange(first: DayKey(index: today - (count - 1)), last: DayKey(index: today))
        }
        return DayRange(first: DayKey(index: min(firstDay ?? today, today)), last: DayKey(index: today))
    }

    static func unit(forDayCount count: Int) -> BucketUnit {
        if count <= 45 { return .day }
        return count <= 400 ? .week : .month
    }

    /// Per-day counts for one scope over `lo...hi`, plus the range-only tallies
    /// (rhythm, delegation, shared days, project rows) gathered in the same pass.
    func scan(_ scope: Scope, lo: Int, hi: Int, range: DayRange, previous: DayRange?) -> ScopeScan {
        var scan = ScopeScan(lo: lo, hi: hi, sourceCount: sourceOrder.count, projectCount: projectPaths.count)
        guard !scope.matchesNothing else { return scan }
        let sourceCount = sourceOrder.count
        let everyProject = scope.project == nil, onlyProject = scope.project ?? 0
        let first = range.first.index, last = range.last.index
        let previousFirst = previous?.first.index ?? Int.max, previousLast = previous?.last.index ?? Int.min
        // Rows are sorted by day, so each range day's rows arrive together.
        var sharedDay = Int.min, sharedNow = false
        var firstSource = [Int](repeating: -1, count: projectPaths.count)
        var touched: [Int] = []
        var position = Self.firstIndex(of: edits, atOrAfter: lo) { $0.day }
        while position < edits.count {
            let row = edits[position]
            position += 1
            let day = Int(row.day)
            if day > hi { break }
            guard everyProject || row.project == onlyProject else { continue }
            let source = Int(row.source), project = Int(row.project), offset = day - lo
            scan.dayEdits[offset] += 1
            scan.sourceDayEdits[offset * sourceCount + source] += 1
            scan.sourceFirstDay[source] = min(scan.sourceFirstDay[source], day)
            if day >= first && day <= last {
                if row.delegated {
                    scan.delegated += 1
                    scan.sourceDelegated[source] += 1
                }
                scan.rhythm[Int(row.weekday) * 24 + Int(row.slot)] += 1
                scan.hours[Int(row.hour)] += 1
                scan.projectEdits[project] += 1
                scan.projectSourceEdits[project * sourceCount + source] += 1
                scan.projectLatest[project] = day
                scan.projectActive[project] = true
                if day != sharedDay {
                    if sharedNow { scan.sharedDays += 1 }
                    for index in touched { firstSource[index] = -1 }
                    touched.removeAll(keepingCapacity: true)
                    sharedDay = day
                    sharedNow = false
                }
                if firstSource[project] < 0 {
                    firstSource[project] = source
                    touched.append(project)
                } else if firstSource[project] != source {
                    sharedNow = true
                }
            } else if day >= previousFirst && day <= previousLast {
                if row.delegated { scan.previousDelegated += 1 }
                scan.projectPrevious[project] += 1
            }
        }
        if sharedNow { scan.sharedDays += 1 }

        position = Self.firstIndex(of: sessions, atOrAfter: lo) { $0.day }
        while position < sessions.count {
            let row = sessions[position]
            position += 1
            let day = Int(row.day)
            if day > hi { break }
            guard everyProject || row.project == onlyProject else { continue }
            let source = Int(row.source), offset = day - lo
            scan.daySessions[offset] += 1
            scan.sourceDaySessions[offset * sourceCount + source] += 1
            scan.sourceFirstDay[source] = min(scan.sourceFirstDay[source], day)
            if day >= first && day <= last { scan.projectActive[Int(row.project)] = true }
        }
        return scan
    }

    static func firstIndex<Row>(of rows: [Row], atOrAfter day: Int, _ key: (Row) -> Int32) -> Int {
        var low = 0, high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if Int(key(rows[middle])) < day { low = middle + 1 } else { high = middle }
        }
        return low
    }

    private func totals(_ scan: ScopeScan, _ range: DayRange, delegated: Int) -> PeriodTotals {
        var edits = 0, sessions = 0, active = 0
        for day in range.first.index...range.last.index {
            let count = scan.edits(day)
            edits += count
            sessions += scan.sessions(day)
            if count > 0 { active += 1 }
        }
        return PeriodTotals(edits: edits, delegatedEdits: delegated, sessions: sessions, activeDays: active, dayCount: range.count)
    }

    /// Ties go to the latest day.
    private func busiestDay(_ scan: ScopeScan, _ range: DayRange) -> DayTotal? {
        var best: DayTotal?
        for day in range.first.index...range.last.index {
            let count = scan.edits(day)
            guard count > 0, count >= (best?.edits ?? 0) else { continue }
            best = DayTotal(day: DayKey(index: day), edits: count, sessions: scan.sessions(day), profiles: scan.profiles(day))
        }
        return best
    }

    /// The longest run of edit-free days between the range's first and last active day.
    private func quietStretch(_ scan: ScopeScan, _ range: DayRange) -> Int {
        var previousActive: Int?
        var longest = 0
        for day in range.first.index...range.last.index where scan.edits(day) > 0 {
            if let previousActive { longest = max(longest, day - previousActive - 1) }
            previousActive = day
        }
        return longest
    }

    /// Sources with an edit or a session in the range, in source order.
    private func activeSources(_ scan: ScopeScan, _ range: DayRange) -> [Int] {
        (0..<sourceOrder.count).filter { source in
            (range.first.index...range.last.index).contains { day in
                scan.sourceEdits(day, source) > 0 || scan.sourceSessions(day, source) > 0
            }
        }
    }

    private func buckets(_ scan: ScopeScan, range: DayRange, unit: BucketUnit, sources: [Int])
        -> (starts: [DayKey], buckets: [Bucket], cumulative: [Bucket]) {
        var spans: [(start: DayKey, end: DayKey)] = []
        switch unit {
        case .day:
            spans = range.days.map { (start: $0, end: $0) }
        case .week:
            var start = range.first.weekStart
            while start <= range.last {
                spans.append((start: start, end: start.adding(days: 6)))
                start = start.adding(days: 7)
            }
        case .month:
            var start = range.first.monthStart
            while start <= range.last {
                let next = start.nextMonthStart
                spans.append((start: start, end: next.adding(days: -1)))
                start = next
            }
        }
        var buckets: [Bucket] = []
        var cumulative: [Bucket] = []
        var runningEdits = [Int](repeating: 0, count: sourceOrder.count)
        var runningSessions = [Int](repeating: 0, count: sourceOrder.count)
        for span in spans {
            let first = max(span.start.index, range.first.index), last = min(span.end.index, range.last.index)
            let isPartial = span.start < range.first || span.end > range.last
            for source in sources {
                var edits = 0, sessions = 0
                for day in first...last {
                    edits += scan.sourceEdits(day, source)
                    sessions += scan.sourceSessions(day, source)
                }
                let id = sourceOrder[source]
                if edits > 0 || sessions > 0 {
                    buckets.append(Bucket(start: span.start, sourceID: id, edits: edits, sessions: sessions, isPartial: isPartial))
                }
                runningEdits[source] += edits
                runningSessions[source] += sessions
                cumulative.append(Bucket(start: span.start, sourceID: id, edits: runningEdits[source],
                                         sessions: runningSessions[source], isPartial: isPartial))
            }
        }
        return (spans.map { $0.start }, buckets, cumulative)
    }

    /// Trailing seven days with zeros included, seeded from days before the range.
    private func rollingAverage(_ scan: ScopeScan, _ range: DayRange) -> [AveragePoint] {
        let first = range.first.index
        var sum = 0
        for day in (first - 6)..<first { sum += scan.edits(day) }
        var points: [AveragePoint] = []
        points.reserveCapacity(range.count)
        for day in first...range.last.index {
            sum += scan.edits(day)
            points.append(AveragePoint(day: DayKey(index: day), value: Double(sum) / 7))
            sum -= scan.edits(day - 6)
        }
        return points
    }

    private func calendarGrid(_ scan: ScopeScan, firstDay: Int, range: DayRange, historyStart: Int?) -> CalendarGrid {
        let weeks = 26, todayIndex = today.index, sourceCount = sourceOrder.count
        var cells: [CalendarCell] = []
        cells.reserveCapacity(weeks * 7)
        var weekdayTotals = [Int](repeating: 0, count: 7)
        var values: [Int] = []
        var sourceValues = [[Int]](repeating: [], count: sourceCount)
        for offset in 0..<(weeks * 7) {
            let day = firstDay + offset
            let isFuture = day > todayIndex
            var bySource: [String: Int] = [:]
            for source in 0..<sourceCount {
                let count = scan.sourceEdits(day, source)
                guard count > 0 else { continue }
                bySource[sourceOrder[source]] = count
                if !isFuture { sourceValues[source].append(count) }
            }
            let count = scan.edits(day)
            if !isFuture {
                weekdayTotals[offset % 7] += count
                if count > 0 { values.append(count) }
            }
            cells.append(CalendarCell(day: DayKey(index: day), edits: count, sessions: scan.sessions(day),
                                      profiles: scan.profiles(day), bySource: bySource, isFuture: isFuture,
                                      beforeHistory: historyStart.map { day < $0 } ?? true,
                                      inRange: day >= range.first.index && day <= range.last.index))
        }
        var sourceThresholds: [String: LevelThresholds] = [:]
        for source in 0..<sourceCount where !sourceValues[source].isEmpty {
            sourceThresholds[sourceOrder[source]] = LevelThresholds.make(sourceValues[source])
        }
        let total = weekdayTotals.reduce(0, +)
        return CalendarGrid(firstDay: DayKey(index: firstDay), weeks: weeks, cells: cells,
                            thresholds: LevelThresholds.make(values), sourceThresholds: sourceThresholds,
                            weekdayTotals: weekdayTotals,
                            weekdayShare: weekdayTotals.map { total > 0 ? Double($0) / Double(total) : 0 })
    }

    private func rhythm(_ scan: ScopeScan) -> RhythmSummary {
        let grid = scan.rhythm, hours = scan.hours
        let total = grid.reduce(0, +)
        var peakHour: Int?, peakCell: Int?, busiest: Int?, quietest: Int?
        if total > 0 {
            // Columns run from the rollover, so a tie goes to the earlier column.
            var best = -1
            for slot in 0..<24 {
                let hour = (slot + calendar.rolloverHour) % 24
                if hours[hour] > best { best = hours[hour]; peakHour = hour }
            }
            peakCell = grid.indices.max { grid[$0] < grid[$1] || (grid[$0] == grid[$1] && $0 > $1) }
            let weekdays = (0..<7).map { weekday in grid[(weekday * 24)..<(weekday * 24 + 24)].reduce(0, +) }
            busiest = weekdays.indices.max { weekdays[$0] < weekdays[$1] || (weekdays[$0] == weekdays[$1] && $0 > $1) }
            quietest = weekdays.indices.min { weekdays[$0] < weekdays[$1] || (weekdays[$0] == weekdays[$1] && $0 < $1) }
        }
        let night = [22, 23, 0, 1, 2, 3, 4].reduce(0) { $0 + hours[$1] }
        return RhythmSummary(grid: grid, hourTotals: hours, total: total, peakHour: peakHour, peakCell: peakCell,
                             nightShare: total > 0 ? Double(night) / Double(total) : 0,
                             busiestWeekday: busiest, quietestWeekday: quietest,
                             chronotype: total >= 50 ? Self.chronotype(hourTotals: hours, total: total) : nil,
                             levels: LevelThresholds.make(grid))
    }

    /// The band whose share of edits most exceeds its share of the day's hours.
    /// Under 1.2× no band stands out, so the rhythm is round the clock.
    static func chronotype(hourTotals: [Int], total: Int) -> Chronotype {
        let bands: [(type: Chronotype, hours: [Int])] = [
            (.earlyBird, Array(5...8)), (.daytime, Array(9...16)),
            (.evening, Array(17...21)), (.nightOwl, [22, 23, 0, 1, 2, 3, 4])
        ]
        var best: (type: Chronotype, intensity: Double) = (.roundTheClock, 0)
        for band in bands {
            let share = Double(band.hours.reduce(0) { $0 + hourTotals[$1] }) / Double(total)
            let intensity = share / (Double(band.hours.count) / 24)
            if intensity > best.intensity { best = (band.type, intensity) }
        }
        return best.intensity >= 1.2 ? best.type : .roundTheClock
    }

    private func shares(_ scan: ScopeScan, range: DayRange, previous: DayRange?, sources: [Int]) -> [SourceShare] {
        func editCount(_ source: Int, _ range: DayRange) -> Int {
            (range.first.index...range.last.index).reduce(0) { $0 + scan.sourceEdits($1, source) }
        }
        let total = sources.reduce(0) { $0 + editCount($1, range) }
        let previousTotal = previous.map { window in (0..<sourceOrder.count).reduce(0) { $0 + editCount($1, window) } } ?? 0
        return sources.map { (source: Int) -> SourceShare in
            var sessions = 0, active = 0
            for day in range.first.index...range.last.index {
                sessions += scan.sourceSessions(day, source)
                if scan.sourceEdits(day, source) > 0 { active += 1 }
            }
            let edits = editCount(source, range)
            var previousShare: Double?
            if let previous, previousTotal > 0 {
                previousShare = Double(editCount(source, previous)) / Double(previousTotal)
            }
            let first = scan.sourceFirstDay[source]
            return SourceShare(sourceID: sourceOrder[source], edits: edits, delegatedEdits: scan.sourceDelegated[source],
                               sessions: sessions, activeDays: active, share: total > 0 ? Double(edits) / Double(total) : 0,
                               previousShare: previousShare, firstDay: first == Int.max ? nil : DayKey(index: first),
                               delegationReported: reportsDelegation[source])
        }
    }

    /// Edits descending, then name, then path.
    private func projectRows(_ scan: ScopeScan, compares: Bool) -> [ProjectRow] {
        let sourceCount = sourceOrder.count
        var rows: [ProjectRow] = []
        for project in 0..<projectPaths.count where scan.projectEdits[project] > 0 {
            var bySource: [SourceCount] = []
            for source in 0..<sourceCount {
                let count = scan.projectSourceEdits[project * sourceCount + source]
                if count > 0 { bySource.append(SourceCount(sourceID: sourceOrder[source], edits: count)) }
            }
            rows.append(ProjectRow(path: projectPaths[project], name: projectNames[project],
                                   edits: scan.projectEdits[project],
                                   previousEdits: compares ? scan.projectPrevious[project] : nil,
                                   bySource: bySource, latestEditDay: DayKey(index: scan.projectLatest[project])))
        }
        return rows.sorted { left, right in
            if left.edits != right.edits { return left.edits > right.edits }
            let order = left.name.localizedStandardCompare(right.name)
            if order != .orderedSame { return order == .orderedAscending }
            return left.path < right.path
        }
    }
}

/// Dense per-day counts for one scope, indexed from `lo`.
struct ScopeScan {
    let lo: Int
    let sourceCount: Int
    var dayEdits: [Int]
    var daySessions: [Int]
    /// Day-major: `(day - lo) * sourceCount + source`.
    var sourceDayEdits: [Int]
    var sourceDaySessions: [Int]
    /// Int.max for a source without rows in the window.
    var sourceFirstDay: [Int]
    var delegated = 0
    var previousDelegated = 0
    var sourceDelegated: [Int]
    var rhythm: [Int]
    var hours: [Int]
    var sharedDays = 0
    var projectEdits: [Int]
    var projectPrevious: [Int]
    var projectLatest: [Int]
    var projectSourceEdits: [Int]
    /// An edit or a session in the range.
    var projectActive: [Bool]

    init(lo: Int, hi: Int, sourceCount: Int, projectCount: Int) {
        let span = max(0, hi - lo + 1)
        self.lo = lo
        self.sourceCount = sourceCount
        dayEdits = Array(repeating: 0, count: span)
        daySessions = Array(repeating: 0, count: span)
        sourceDayEdits = Array(repeating: 0, count: span * sourceCount)
        sourceDaySessions = Array(repeating: 0, count: span * sourceCount)
        sourceFirstDay = Array(repeating: Int.max, count: sourceCount)
        sourceDelegated = Array(repeating: 0, count: sourceCount)
        rhythm = Array(repeating: 0, count: 7 * 24)
        hours = Array(repeating: 0, count: 24)
        projectEdits = Array(repeating: 0, count: projectCount)
        projectPrevious = Array(repeating: 0, count: projectCount)
        projectLatest = Array(repeating: Int.min, count: projectCount)
        projectSourceEdits = Array(repeating: 0, count: projectCount * sourceCount)
        projectActive = Array(repeating: false, count: projectCount)
    }

    func edits(_ day: Int) -> Int { dayEdits[day - lo] }
    func sessions(_ day: Int) -> Int { daySessions[day - lo] }
    func sourceEdits(_ day: Int, _ source: Int) -> Int { sourceDayEdits[(day - lo) * sourceCount + source] }
    func sourceSessions(_ day: Int, _ source: Int) -> Int { sourceDaySessions[(day - lo) * sourceCount + source] }

    /// Profiles with an edit or a session that day.
    func profiles(_ day: Int) -> Int {
        (0..<sourceCount).filter { sourceEdits(day, $0) > 0 || sourceSessions(day, $0) > 0 }.count
    }
}

/// Runs of consecutive active days, fed in ascending order.
struct StreakTracker {
    private var previous: Int?
    private var run = 0
    private(set) var longest = 0
    private var longestEnd: Int?

    init() {}

    mutating func add(_ day: Int) {
        guard day != previous else { return }
        run = previous == day - 1 ? run + 1 : 1
        previous = day
        // `>=` hands a tie to the later run.
        if run >= longest {
            longest = run
            longestEnd = day
        }
    }

    /// Today counts once it has an edit; until then yesterday keeps the streak.
    func summary(today: Int) -> StreakSummary {
        let current = previous == today || previous == today - 1 ? run : 0
        return StreakSummary(current: current, longest: longest, longestEnd: longestEnd.map(DayKey.init(index:)))
    }
}
