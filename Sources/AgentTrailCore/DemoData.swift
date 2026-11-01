import Foundation

/// Synthetic presentation data. Never opens a provider, process, or cache, and
/// reads the clock only through the `now` default, so renders repeat exactly.
public enum DemoData {
    public static var sources: [AgentSource] { AgentSource.defaults(home: "/Demo") }

    /// The pinned render clock: 2026-10-30 18:40 in the calendar's time zone.
    public static func referenceDate(calendar: Calendar = .current) -> Date {
        ActivityCalendar(timeZone: calendar.timeZone).gregorian
            .date(from: DateComponents(year: 2026, month: 10, day: 30, hour: 18, minute: 40))!
    }

    /// About six months of edit moments and session starts for five projects,
    /// generated per local activity day in the calendar's time zone. The UTC
    /// history is derived from those moments, so both views always agree.
    public static func result(now: Date = Date(), calendar: Calendar = .current) -> ScanResult {
        let activityCalendar = ActivityCalendar(timeZone: calendar.timeZone)
        let records: [ProjectActivity] = plans.enumerated().map { index, plan in
            activity(plan, index: index, now: now, calendar: activityCalendar)
        }
        // Atlas was moved; Agent Trail remembers where it used to be.
        let locations = ProjectLocationRegistry.demo([(atlas, [("/Demo/Archive/atlas", .move)])], now: now)
        return ScanResult(projects: ProjectSummary.merge(records), scannedAt: now, projectLocations: locations)
    }

    private struct Plan: Sendable {
        var sourceID: String
        var project: String
        /// Edits on a full-weight weekday once the ramp has peaked.
        var base: Double
        /// Days ago of the first and last day this profile worked here.
        var since: Int
        var until: Int = 0
        var workspace: String? = nil
        var editWorkspace: String? = nil
        /// Seconds before `now` of a configured latest edit and latest activity.
        var latestEdit: TimeInterval? = nil
        var latestActivity: TimeInterval? = nil
    }

    private static let main = "claude-primary", second = "claude-second"
    private static let orbit = "/Demo/Projects/orbit", atlas = "/Demo/Projects/atlas", notes = "/Demo/Projects/field-notes"
    private static let harbor = "/Demo/Projects/harbor", lumen = "/Demo/Projects/lumen"

    /// A record's position is its seed, so reordering changes every number.
    private static let plans: [Plan] = [
        Plan(sourceID: second, project: orbit, base: 6, since: 120, workspace: orbit + "/.claude/worktrees/navigation",
             editWorkspace: orbit + "/.claude/worktrees/navigation", latestEdit: 120, latestActivity: 35),
        Plan(sourceID: main, project: orbit, base: 9, since: 182, latestEdit: 540, latestActivity: 420),
        Plan(sourceID: main, project: atlas, base: 5, since: 182, latestEdit: 900, latestActivity: 240),
        Plan(sourceID: second, project: atlas, base: 4, since: 120, latestEdit: 1_800, latestActivity: 600),
        // Field notes went quiet three weeks ago, so it reads as dormant.
        Plan(sourceID: main, project: notes, base: 3, since: 160, until: 21),
        Plan(sourceID: "codex", project: orbit, base: 7, since: 70, workspace: "/Demo/Codex/2026-10-30/launch",
             editWorkspace: "/Demo/Codex/2026-10-30/launch", latestEdit: 80, latestActivity: 15),
        Plan(sourceID: "grok", project: orbit, base: 3, since: 35, latestEdit: 150, latestActivity: 70),
        Plan(sourceID: "codex", project: harbor, base: 4, since: 70, latestEdit: 1_200),
        Plan(sourceID: "grok", project: harbor, base: 2, since: 35, latestEdit: 10_800),
        // Lumen started four days ago, so it reads as new.
        Plan(sourceID: main, project: lumen, base: 6, since: 4, latestEdit: 3_000)
    ]

    /// Monday first.
    private static let weekdayWeights: [Double] = [1.0, 1.25, 1.3, 0.9, 1.1, 0.45, 0.15]
    /// Wall-clock hours 0-23: late evenings and a midday peak.
    private static let hourWeights: [Double] = [5, 2, 2, 1, 0, 0, 0, 1, 2, 4, 7, 10, 11, 10, 6, 5, 4, 5, 7, 5, 6, 6, 9, 12]
    /// A four-day break, and one missed day that holds the current streak at 8.
    private static let quietDays: Set<Int> = [8, 40, 41, 42, 43]

    private static func activity(_ plan: Plan, index: Int, now: Date, calendar: ActivityCalendar) -> ProjectActivity {
        let today = calendar.day(of: now)
        let share = delegatedShare(plan.sourceID)
        var moments: [EditMoment] = []
        var starts: [Date] = []
        for ago in stride(from: plan.since, through: plan.until, by: -1) {
            var random = SplitMix64(seed: (UInt64(index) << 32) | UInt64(ago))
            let day = today.adding(days: -ago)
            let ramp = 0.4 + 0.6 * (1 - Double(ago) / 182)
            let expected = plan.base * weekdayWeights[day.weekday] * ramp * (0.5 + random.unit())
            let count = quietDays.contains(ago) ? 0 : max(0, Int(expected.rounded()))
            var edits: [EditMoment] = []
            for _ in 0..<count {
                let hour = random.pick(hourWeights)
                let minute = random.integer(in: 0...59)
                let delegated = random.unit() < share
                if let date = time(on: day, hour: hour, minute: minute, in: calendar), date <= now {
                    edits.append(EditMoment(date: date, delegated: delegated))
                }
            }
            if ago == 0, let offset = plan.latestEdit {
                edits.append(EditMoment(date: now.addingTimeInterval(-offset)))
            }
            edits.sort { $0.date < $1.date }
            if let first = edits.first {
                starts.append(first.date.addingTimeInterval(-Double(random.integer(in: 5...20) * 60)))
                if edits.count > 8 {
                    starts.append(edits[edits.count / 2].date.addingTimeInterval(-Double(random.integer(in: 5...20) * 60)))
                }
            } else if random.unit() < 0.08, let start = time(on: day, hour: 14, minute: 0, in: calendar), start <= now {
                starts.append(start)
            }
            moments += edits
        }
        moments.sort { $0.date < $1.date }
        starts.sort()
        let editDays: [ActivityDay] = moments.map { ActivityDay(day: $0.date, editCount: 1) }
        let sessionDays: [ActivityDay] = starts.map { ActivityDay(day: $0, sessionCount: 1) }
        let latestEdit = moments.last?.date
        let candidates: [Date?] = [latestEdit, starts.last, plan.latestActivity.map { now.addingTimeInterval(-$0) }]
        return ProjectActivity(sourceID: plan.sourceID, projectPath: plan.project,
            latestActivity: candidates.compactMap { $0 }.max() ?? now, latestEdit: latestEdit,
            sessionCount: starts.count, workspacePath: plan.workspace ?? plan.project,
            latestEditWorkspacePath: plan.editWorkspace, history: ActivityDay.merge(editDays + sessionDays),
            editMoments: moments, sessionStarts: starts)
    }

    /// Share of edits first recorded in a subagent or spawned thread. Grok reports none.
    private static func delegatedShare(_ sourceID: String) -> Double {
        switch sourceID {
        case "codex": return 0.2
        case "grok": return 0
        default: return 0.7
        }
    }

    /// Hours before the rollover fall on the next civil date, so a late night
    /// stays with the evening it started.
    private static func time(on day: DayKey, hour: Int, minute: Int, in calendar: ActivityCalendar) -> Date? {
        let civil = hour < calendar.rolloverHour ? day.adding(days: 1) : day
        return calendar.gregorian.date(from: DateComponents(year: civil.year, month: civil.month, day: civil.day,
                                                        hour: hour, minute: minute))
    }
}

/// SplitMix64, seeded per record and day so every day stands on its own.
private struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1) from the top 53 bits.
    mutating func unit() -> Double {
        Double(next() >> 11) * 0x1p-53
    }

    mutating func integer(in range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(unit() * Double(range.count))
    }

    mutating func pick(_ weights: [Double]) -> Int {
        var remaining = unit() * weights.reduce(0, +)
        for (index, weight) in weights.enumerated() {
            if remaining < weight { return index }
            remaining -= weight
        }
        return weights.count - 1
    }
}
