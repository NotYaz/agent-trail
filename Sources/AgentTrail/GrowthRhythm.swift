import SwiftUI
import AgentTrailCore

/// When edits land: a punch card of activity-day weekday × local hour, with
/// columns from the rollover (05:00) so a night stays in one row, and a summary
/// column with the chronotype. In-app only; it is never part of an export.
struct RhythmCard: View, Equatable {
    /// Below this many edits a rhythm would be noise.
    static let minimumEdits = 50

    private let rhythm: RhythmSummary
    private let periodTitle: String
    private let rolloverHour: Int
    private let progress: Double
    @State private var hovered: Int?

    private static let pitch: CGFloat = 17

    init(rhythm: RhythmSummary, periodTitle: String, rolloverHour: Int = ActivityCalendar.defaultRolloverHour,
         progress: Double = 1) {
        self.rhythm = rhythm
        self.periodTitle = periodTitle
        self.rolloverHour = rolloverHour
        self.progress = progress
    }

    /// Guard clauses keep each comparison a separate type-check.
    static func == (lhs: RhythmCard, rhs: RhythmCard) -> Bool {
        guard lhs.periodTitle == rhs.periodTitle, lhs.rolloverHour == rhs.rolloverHour else { return false }
        guard lhs.progress == rhs.progress else { return false }
        return lhs.rhythm == rhs.rhythm
    }

    var body: some View {
        SectionCard(title: "When edits land", subtitle: subtitle) {
            if rhythm.total < Self.minimumEdits {
                emptyState
            } else {
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    plot
                    summary
                }
            }
        }
    }

    // MARK: Plot

    private var rowLabels: [String] {
        (0..<7).map { (weekday: Int) -> String in DayFormat.weekday(weekday) }
    }

    private var plot: some View {
        VStack(alignment: .leading, spacing: 2) {
            PunchCard(grid: rhythm.grid, levels: rhythm.levels, ramp: Theme.Palette.heatRamp, rowLabels: rowLabels,
                      columnLabels: PunchCard.hourLabels(rolloverHour: rolloverHour), pitch: Self.pitch,
                      revealProgress: progress, onHover: { index in hovered = index })
                .accessibilityElement()
                .accessibilityLabel("Edits by weekday and hour")
                .accessibilityValue(accessibilitySummary)
                .accessibilityChartDescriptor(descriptor)
            Text("\(clock(rolloverHour)) → \(DayFormat.hour(rolloverHour - 1)):59 · rows are activity days")
                .font(Theme.Typeface.micro)
                .foregroundStyle(.secondary)
                .padding(.leading, PunchCard.labelWidth)
        }
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(rhythm.chronotype?.title ?? Chronotype.roundTheClock.title)
                .font(Theme.Typeface.headline)
                .foregroundStyle(.primary)
            if let peak = rhythm.peakHour {
                Text("Peak \(clock(peak))")
            }
            Text("\(PercentFormat.share(rhythm.nightShare)) between \(clock(22)) and \(clock(rolloverHour))")
            if let line = weekdayLine {
                Text(line)
            }
        }
        .font(Theme.Typeface.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var weekdayLine: String? {
        guard let busiest = rhythm.busiestWeekday, let quietest = rhythm.quietestWeekday else { return nil }
        return "Busiest \(DayFormat.weekday(busiest)) · quietest \(DayFormat.weekday(quietest))"
    }

    private var emptyState: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not enough edits for a rhythm yet")
                    .font(Theme.Typeface.body)
                Text("\(GrowthText.edits(rhythm.total)) in this period · a rhythm needs \(Self.minimumEdits)")
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Space.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sunkenField(radius: Theme.Radius.control)
        .accessibilityElement(children: .combine)
    }

    // MARK: Text

    /// "23:00", with the locale's hour digits.
    private func clock(_ hour: Int) -> String {
        "\(DayFormat.hour(hour)):00"
    }

    private var subtitle: String {
        guard let hovered, rhythm.grid.indices.contains(hovered) else {
            return "\(periodTitle) · local time · never included in exported images"
        }
        return describe(hovered)
    }

    /// "Wed · 23:00–24:00 · 412 edits", noting hours after midnight that belong to the evening before.
    private func describe(_ index: Int) -> String {
        let weekday = index / PunchCard.columns
        let hour = (index % PunchCard.columns + rolloverHour) % 24
        let end = hour == 23 ? "24:00" : clock(hour + 1)
        let note = hour < rolloverHour ? " (after midnight)" : ""
        return "\(DayFormat.weekday(weekday)) · \(clock(hour))–\(end) · \(GrowthText.edits(rhythm.grid[index]))\(note)"
    }

    private var accessibilitySummary: String {
        var parts = [GrowthText.edits(rhythm.total)]
        if let chronotype = rhythm.chronotype { parts.append(chronotype.title) }
        if let peak = rhythm.peakHour { parts.append("peak hour \(clock(peak))") }
        parts.append("\(PercentFormat.share(rhythm.nightShare)) between \(clock(22)) and \(clock(rolloverHour))")
        return parts.joined(separator: ", ")
    }

    /// Hours in rollover order along x, one series per activity-day weekday.
    private var descriptor: GrowthChartDescriptor {
        let hours = (0..<PunchCard.columns).map { (slot: Int) -> String in clock((slot + rolloverHour) % 24) }
        let rows = (0..<7).map { (weekday: Int) -> GrowthChartDescriptor.Series in
            let values = (0..<PunchCard.columns).map { (slot: Int) -> Double in
                let index = weekday * PunchCard.columns + slot
                return rhythm.grid.indices.contains(index) ? Double(rhythm.grid[index]) : 0
            }
            return GrowthChartDescriptor.Series(name: DayFormat.weekday(weekday, style: .full), values: values)
        }
        return GrowthChartDescriptor(title: "When edits land", summary: accessibilitySummary, xTitle: "Local hour",
                                     categories: hours, yTitle: "Edits", series: rows)
    }
}
