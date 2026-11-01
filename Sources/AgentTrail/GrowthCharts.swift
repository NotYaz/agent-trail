import SwiftUI
import Charts
import Accessibility
import AgentTrailCore

// MARK: - Bucket math

/// Chart buckets on local activity days. Buckets are keyed by their true day,
/// week (Monday) or month start, and plotted on civil dates in the activity
/// calendar's zone, which is also the Charts calendar environment.
enum GrowthChartMath {
    static func component(_ unit: BucketUnit) -> Calendar.Component {
        switch unit {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    static func bucketStart(of day: DayKey, unit: BucketUnit) -> DayKey {
        switch unit {
        case .day: return day
        case .week: return day.weekStart
        case .month: return day.monthStart
        }
    }

    /// The start of the bucket holding `day`, or nil outside the range.
    static func bucketStart(containing day: DayKey, unit: BucketUnit, range: DayRange) -> DayKey? {
        guard range.contains(day) else { return nil }
        return bucketStart(of: day, unit: unit)
    }

    /// The first day after the bucket that starts on `start`.
    static func bucketEnd(_ start: DayKey, unit: BucketUnit) -> DayKey {
        switch unit {
        case .day:
            return start.adding(days: 1)
        case .week:
            return start.adding(days: 7)
        case .month:
            if start.month == 12 { return DayKey(year: start.year + 1, month: 1, day: 1) }
            return DayKey(year: start.year, month: start.month + 1, day: 1)
        }
    }

    /// True when the range clips the bucket.
    static func isPartial(_ start: DayKey, unit: BucketUnit, range: DayRange) -> Bool {
        start < range.first || bucketEnd(start, unit: unit).adding(days: -1) > range.last
    }

    /// Civil midnight in the calendar's zone, where Charts starts a date bin.
    static func midnight(_ day: DayKey, calendar: ActivityCalendar) -> Date {
        let components = DateComponents(year: day.year, month: day.month, day: day.day)
        return calendar.gregorian.date(from: components) ?? calendar.noon(of: day).addingTimeInterval(-43_200)
    }

    /// The middle of a bucket's bin, where its bar, rule and label sit.
    static func center(_ start: DayKey, unit: BucketUnit, calendar: ActivityCalendar) -> Date {
        if unit == .day { return calendar.noon(of: start) }
        let lower = midnight(start, calendar: calendar)
        let upper = midnight(bucketEnd(start, unit: unit), calendar: calendar)
        return lower.addingTimeInterval(upper.timeIntervalSince(lower) / 2)
    }

    /// The civil date a plotted instant falls on.
    static func civilDay(of date: Date, calendar: ActivityCalendar) -> DayKey {
        let parts = calendar.gregorian.dateComponents([.year, .month, .day], from: date)
        return DayKey(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// "Tue, Oct 21", "Week of Oct 6 (partial)" or "October 2026".
    static func bucketTitle(_ start: DayKey, unit: BucketUnit, range: DayRange, calendar: ActivityCalendar) -> String {
        let suffix = isPartial(start, unit: unit, range: range) ? " (partial)" : ""
        switch unit {
        case .day: return DayFormat.long(start, calendar: calendar)
        case .week: return "Week of \(DayFormat.short(start, calendar: calendar))\(suffix)"
        case .month: return DayFormat.month(start, calendar: calendar) + suffix
        }
    }

    static func unitPhrase(_ unit: BucketUnit) -> String {
        switch unit {
        case .day: return "by day"
        case .week: return "by week"
        case .month: return "by month"
        }
    }

    static func axisLabel(_ value: Double?) -> String {
        guard let value else { return "" }
        return CompactNumber.string(value)
    }
}

// MARK: - Chart descriptor

/// An audio-graph and VoiceOver description: categories along x, one numeric
/// series per profile, weekday or measure.
struct GrowthChartDescriptor: AXChartDescriptorRepresentable {
    struct Series {
        let name: String
        let values: [Double]

        init(name: String, values: [Double]) {
            self.name = name
            self.values = values
        }
    }

    let title: String
    let summary: String
    let xTitle: String
    let categories: [String]
    let yTitle: String
    let series: [Series]

    init(title: String, summary: String, xTitle: String, categories: [String], yTitle: String, series: [Series]) {
        self.title = title
        self.summary = summary
        self.xTitle = xTitle
        self.categories = categories
        self.yTitle = yTitle
        self.series = series
    }

    func makeChartDescriptor() -> AXChartDescriptor {
        let maximum = max(1, series.flatMap(\.values).max() ?? 0)
        let unit = yTitle.lowercased()
        let xAxis = AXCategoricalDataAxisDescriptor(title: xTitle, categoryOrder: categories)
        let yAxis = AXNumericDataAxisDescriptor(title: yTitle, range: 0...maximum, gridlinePositions: []) { value in
            "\(Int(value.rounded())) \(unit)"
        }
        let data = series.map { (item: Series) -> AXDataSeriesDescriptor in
            var points: [AXDataPoint] = []
            for (index, category) in categories.enumerated() where index < item.values.count {
                points.append(AXDataPoint(x: category, y: item.values[index]))
            }
            return AXDataSeriesDescriptor(name: item.name, isContinuous: false, dataPoints: points)
        }
        return AXChartDescriptor(title: title, summary: summary, xAxis: xAxis, yAxis: yAxis,
                                 additionalAxes: [], series: data)
    }
}

// MARK: - Recorded edits

/// Bars per day, week or month stacked by profile, with the 7-day average, the
/// peak and a selection popover; or a stacked running total. Only the plot
/// reveals, so the measure control keeps its sliding pill.
struct RecordedEditsCard: View, Equatable {
    private let stats: ActivityStatistics
    private let calendar: ActivityCalendar
    private let series: [GrowthSeries]
    private let measure: GrowthMeasure
    private let mode: GrowthChartMode
    private let focus: String?
    private let selection: DayKey?
    private let revealKey: GrowthKey
    private let animates: Bool
    private let onMeasure: (GrowthMeasure) -> Void
    private let onMode: (GrowthChartMode) -> Void
    private let onSelect: (DayKey?) -> Void
    private let onFocus: (String?) -> Void

    private static let measureOptions: [(value: GrowthMeasure, title: String)] = [
        (value: GrowthMeasure.edits, title: "Edits"),
        (value: GrowthMeasure.sessions, title: "Sessions")
    ]

    init(stats: ActivityStatistics, calendar: ActivityCalendar, series: [GrowthSeries], measure: GrowthMeasure,
         mode: GrowthChartMode, focus: String?, selection: DayKey?, revealKey: GrowthKey, animates: Bool,
         onMeasure: @escaping (GrowthMeasure) -> Void, onMode: @escaping (GrowthChartMode) -> Void,
         onSelect: @escaping (DayKey?) -> Void, onFocus: @escaping (String?) -> Void) {
        self.stats = stats
        self.calendar = calendar
        self.series = series
        self.measure = measure
        self.mode = mode
        self.focus = focus
        self.selection = selection
        self.revealKey = revealKey
        self.animates = animates
        self.onMeasure = onMeasure
        self.onMode = onMode
        self.onSelect = onSelect
        self.onFocus = onFocus
    }

    /// Closures are excluded. Guard clauses keep each comparison a separate type-check.
    static func == (lhs: RecordedEditsCard, rhs: RecordedEditsCard) -> Bool {
        guard lhs.measure == rhs.measure, lhs.mode == rhs.mode else { return false }
        guard lhs.focus == rhs.focus, lhs.selection == rhs.selection else { return false }
        guard lhs.revealKey == rhs.revealKey, lhs.animates == rhs.animates else { return false }
        guard lhs.calendar == rhs.calendar, lhs.series == rhs.series else { return false }
        return lhs.stats == rhs.stats
    }

    var body: some View {
        let model = GrowthChartModel(stats: stats, series: series, measure: measure, mode: mode, calendar: calendar)
        return SectionCard(title: measure.chartTitle, subtitle: readout(model)) {
            controls
        } content: {
            plot(model)
            legend(model)
        }
    }

    // MARK: Header

    private var measureBinding: Binding<GrowthMeasure> {
        Binding(get: { measure }, set: { value in onMeasure(value) })
    }

    private var controls: some View {
        HStack(spacing: 6) {
            PillSegmented(selection: measureBinding, options: Self.measureOptions, label: "Chart measure")
            runningTotalButton
        }
    }

    private var runningTotalButton: some View {
        let isOn = mode == .runningTotal
        return Button { onMode(isOn ? .bars : .runningTotal) } label: {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
                .frame(width: 26, height: 26)
                .background(isOn ? Theme.Palette.raised : Theme.Palette.sunken,
                            in: Theme.Radius.shape(Theme.Radius.control))
                .contentShape(Theme.Radius.shape(Theme.Radius.control))
        }
        .buttonStyle(.plain)
        .help(isOn ? "Show bars per period" : "Show running total")
        .accessibilityLabel("Show running total")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func readout(_ model: GrowthChartModel) -> String {
        let unit = GrowthChartMath.unitPhrase(stats.unit)
        if mode == .runningTotal {
            return "Running total · \(measure.describe(model.measureTotal)) · \(unit)"
        }
        if let start = selection, model.contains(start) {
            let title = GrowthChartMath.bucketTitle(start, unit: stats.unit, range: stats.range, calendar: calendar)
            return "\(title) · \(measure.describe(model.totals[start.index] ?? 0))"
        }
        if measure == .sessions {
            return "\(measure.describe(stats.current.sessions)) · \(unit)"
        }
        return "\(GrowthText.count(stats.current.activeDays, "active day", "active days")) · \(unit)"
    }

    // MARK: Plot

    @ViewBuilder private func plot(_ model: GrowthChartModel) -> some View {
        if model.measureTotal == 0 {
            emptyPlot
        } else {
            RevealSurface(key: revealKey, animates: animates) { progress in
                chart(model, progress: progress)
            }
            .frame(height: 150)
        }
    }

    @ViewBuilder private func chart(_ model: GrowthChartModel, progress: Double) -> some View {
        if mode == .runningTotal {
            runningChart(model, progress: progress)
        } else {
            barsChart(model, progress: progress)
        }
    }

    private var emptyPlot: some View {
        VStack(spacing: 4) {
            Image(systemName: "calendar")
                .font(.system(size: 16))
                .foregroundStyle(.secondary)
            Text(measure == .edits ? "No recorded edits in this period" : "No saved sessions in this period")
                .font(Theme.Typeface.body)
            Text("Try another project or a wider period.")
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 150)
        .sunkenField(radius: Theme.Radius.control)
        .accessibilityElement(children: .combine)
    }

    private func barsChart(_ model: GrowthChartModel, progress: Double) -> some View {
        let active: DayKey? = model.contains(selection) ? selection : nil
        let peak: GrowthChartModel.Total? = active == nil ? model.peak : nil
        let selectedDate: Date? = active.flatMap { model.centers[$0.index] }
        return Chart {
            ForEach(model.bars) { (bar: GrowthChartModel.Bar) in
                barMark(bar, model: model, progress: progress, selected: active)
            }
            ForEach(model.average) { (point: GrowthChartModel.Point) in
                averageMark(point, progress: progress)
            }
            if let peak {
                peakMark(peak, progress: progress)
            }
            if let selectedDate, let active {
                selectionRule(selectedDate, start: active)
            }
        }
        .chartForegroundStyleScale(domain: model.seriesIDs, range: model.colors)
        .chartLegend(.hidden)
        .chartXSelection(value: selectionBinding(model))
        .modifier(GrowthAxesModifier(model: model))
        .accessibilityChartDescriptor(descriptor(model))
    }

    private func runningChart(_ model: GrowthChartModel, progress: Double) -> some View {
        Chart {
            ForEach(model.areas) { (point: GrowthChartModel.Point) in
                AreaMark(x: .value("Date", point.date), y: .value("Running total", point.value),
                         stacking: .standard)
                    .foregroundStyle(by: .value("Profile", point.seriesID))
                    .interpolationMethod(.monotone)
                    .opacity(seriesOpacity(point.seriesID))
                    .accessibilityLabel(markLabel(point.seriesID, start: point.start, model: model))
                    .accessibilityValue(runningValue(point))
            }
        }
        .chartForegroundStyleScale(domain: model.seriesIDs, range: model.gradients)
        .chartLegend(.hidden)
        .modifier(GrowthAxesModifier(model: model))
        .mask(alignment: .leading) {
            // Running totals sweep in from the left instead of growing upward.
            Rectangle().scaleEffect(x: CGFloat(max(0.001, progress)), y: 1, anchor: .leading)
        }
        .accessibilityChartDescriptor(descriptor(model))
    }

    private func seriesOpacity(_ seriesID: String) -> Double {
        guard let focus else { return 1 }
        return focus == seriesID ? 1 : 0.35
    }

    private func barOpacity(_ bar: GrowthChartModel.Bar, selected: DayKey?) -> Double {
        if let selected, bar.start != selected { return 0.35 }
        return seriesOpacity(bar.seriesID)
    }

    private func barMark(_ bar: GrowthChartModel.Bar, model: GrowthChartModel, progress: Double,
                         selected: DayKey?) -> some ChartContent {
        BarMark(x: .value("Date", bar.date, unit: model.component),
                y: .value("Count", bar.value * progress),
                width: model.barWidth)
            .foregroundStyle(by: .value("Profile", bar.seriesID))
            .cornerRadius(Theme.Radius.cell)
            .opacity(barOpacity(bar, selected: selected))
            .accessibilityLabel(markLabel(bar.seriesID, start: bar.start, model: model))
            .accessibilityValue(measure.describe(Int(bar.value)))
    }

    /// "Claude · Main, Tue, Oct 21": VoiceOver hears the profile name, not its
    /// series ID. Values use the unscaled count, not the reveal height.
    private func markLabel(_ seriesID: String, start: DayKey, model: GrowthChartModel) -> String {
        let name = model.names[seriesID] ?? seriesID
        let title = model.titles[start.index] ?? ""
        return "\(name), \(title)"
    }

    private func runningValue(_ point: GrowthChartModel.Point) -> String {
        "Running total of \(measure.describe(Int(point.value)))"
    }

    private func averageMark(_ point: GrowthChartModel.Point, progress: Double) -> some ChartContent {
        LineMark(x: .value("Date", point.date), y: .value("7-day average", point.value * progress))
            .foregroundStyle(Color.primary.opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [4, 3]))
            .interpolationMethod(.monotone)
    }

    private func peakMark(_ peak: GrowthChartModel.Total, progress: Double) -> some ChartContent {
        PointMark(x: .value("Date", peak.date), y: .value("Count", Double(peak.value) * progress))
            .symbolSize(24)
            .foregroundStyle(Color.primary)
            .annotation(position: .top, spacing: 3,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                Text("Peak \(peak.value.formatted())")
                    .font(Theme.Typeface.micro)
                    .foregroundStyle(.secondary)
                    .opacity(progress)
            }
    }

    /// The popover fits inside the chart, so it is never clipped by the scroll
    /// view or drawn over the KPI tiles and header controls above the card.
    private func selectionRule(_ date: Date, start: DayKey) -> some ChartContent {
        RuleMark(x: .value("Selected", date))
            .foregroundStyle(Color.primary.opacity(0.35))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .annotation(position: .top, spacing: 4,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                popover(start)
            }
    }

    private func popover(_ start: DayKey) -> some View {
        GrowthBucketPopover(rows: popoverRows(start))
    }

    /// Every series active in the bucket, with both edits and sessions.
    private func popoverRows(_ start: DayKey) -> [GrowthBucketPopover.Row] {
        var rows: [GrowthBucketPopover.Row] = []
        for item in series {
            var edits = 0
            var sessions = 0
            for bucket in stats.buckets where bucket.start == start && item.sourceIDs.contains(bucket.sourceID) {
                edits += bucket.edits
                sessions += bucket.sessions
            }
            guard edits > 0 || sessions > 0 else { continue }
            rows.append(GrowthBucketPopover.Row(id: item.id, name: item.name, color: item.color,
                                                edits: edits, sessions: sessions))
        }
        return rows
    }

    /// Snaps the pointer to its bucket; only a change of bucket is reported.
    private func selectionBinding(_ model: GrowthChartModel) -> Binding<Date?> {
        let current = selection
        return Binding(get: { current.flatMap { model.centers[$0.index] } }, set: { date in
            let start = date.flatMap { model.bucket(containing: $0) }
            guard start != current else { return }
            onSelect(start)
        })
    }

    private func descriptor(_ model: GrowthChartModel) -> GrowthChartDescriptor {
        let categories = model.starts.map { (start: DayKey) -> String in
            GrowthChartMath.bucketTitle(start, unit: stats.unit, range: stats.range, calendar: calendar)
        }
        let rows = series.map { (item: GrowthSeries) -> GrowthChartDescriptor.Series in
            GrowthChartDescriptor.Series(name: item.name, values: model.table[item.id] ?? [])
        }
        let title = mode == .runningTotal ? "Running total of \(measure.chartTitle.lowercased())" : measure.chartTitle
        let summary = "\(measure.describe(model.measureTotal)) over \(stats.period.title.lowercased()), "
            + GrowthChartMath.unitPhrase(stats.unit)
        return GrowthChartDescriptor(title: title, summary: summary, xTitle: "Date", categories: categories,
                                     yTitle: measure.title, series: rows)
    }

    // MARK: Legend

    private func legend(_ model: GrowthChartModel) -> some View {
        GrowthLegendFlow(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(series) { (item: GrowthSeries) in
                legendChip(item)
            }
            if !model.average.isEmpty {
                averageKey
            }
        }
    }

    private func legendChip(_ item: GrowthSeries) -> some View {
        let isFocused = focus == item.id
        let share = PercentFormat.share(item.share(for: measure))
        return Button { onFocus(isFocused ? nil : item.id) } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(item.color)
                    .frame(width: 7, height: 7)
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(share)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(Theme.Typeface.caption)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(isFocused ? Theme.Palette.raised : Theme.Palette.sunken, in: Capsule())
            .overlay { Capsule().strokeBorder(isFocused ? Theme.Palette.glassEdgeTop : Color.clear, lineWidth: 1) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(focus == nil || isFocused ? 1 : 0.55)
        .help(isFocused ? "Show every profile again" : "Highlight \(item.name) across Growth")
        .accessibilityLabel("\(item.name), \(share) of \(measure.title.lowercased())")
        .accessibilityHint(isFocused ? "Clears the profile focus" : "Highlights this profile across Growth")
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    private var averageKey: some View {
        HStack(spacing: 5) {
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(path, with: .color(Color.primary.opacity(0.7)),
                               style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            .frame(width: 16, height: 6)
            Text("7-day average")
        }
        .font(Theme.Typeface.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
        .frame(height: 22)
        .help("Average recorded edits over the trailing seven local days, empty days included")
        .accessibilityElement(children: .combine)
    }
}

/// Chart-ready values for one card state. Built in the card's body, which runs
/// only when its inputs change.
private struct GrowthChartModel {
    struct Bar: Identifiable {
        let id: String
        let start: DayKey
        let date: Date
        let seriesID: String
        let value: Double
    }

    struct Point: Identifiable {
        let id: String
        let start: DayKey
        let date: Date
        let seriesID: String
        let value: Double
    }

    struct Total {
        let start: DayKey
        let date: Date
        let value: Int
    }

    let calendar: ActivityCalendar
    let unit: BucketUnit
    let component: Calendar.Component
    let starts: [DayKey]
    let seriesIDs: [String]
    let colors: [Color]
    /// Bucket start index → the middle of its bin.
    let centers: [Int: Date]
    /// Bucket start index → its title, for mark accessibility labels.
    let titles: [Int: String]
    /// Series ID → profile name, so VoiceOver never reads raw IDs.
    let names: [String: String]
    let bars: [Bar]
    let areas: [Point]
    let average: [Point]
    /// Bucket start index → the measure's total there.
    let totals: [Int: Int]
    let peak: Total?
    /// Per series, one value per bucket start, for the chart descriptor.
    let table: [String: [Double]]
    let measureTotal: Int
    let yTop: Double
    let yTicks: [Double]
    let domain: ClosedRange<Date>
    let labelDates: [Date]
    let barWidth: MarkDimension

    init(stats: ActivityStatistics, series: [GrowthSeries], measure: GrowthMeasure, mode: GrowthChartMode,
         calendar: ActivityCalendar) {
        let starts = stats.bucketStarts.isEmpty ? [stats.range.first] : stats.bucketStarts
        let ids = series.map(\.id)
        var centers: [Int: Date] = [:]
        var titles: [Int: String] = [:]
        for start in starts {
            centers[start.index] = GrowthChartMath.center(start, unit: stats.unit, calendar: calendar)
            titles[start.index] = GrowthChartMath.bucketTitle(start, unit: stats.unit, range: stats.range,
                                                              calendar: calendar)
        }
        var names: [String: String] = [:]
        for item in series where names[item.id] == nil {
            names[item.id] = item.name
        }
        let lookup = Self.lookup(series)
        let perBucket = Self.sums(stats.buckets, lookup: lookup, measure: measure)
        let running = Self.sums(stats.cumulative, lookup: lookup, measure: measure)
        let totals = Self.totals(perBucket)
        let showsBars = mode == .bars
        let averagePoints = showsBars && measure == .edits ? Self.average(stats.rollingAverage, calendar: calendar) : []
        let total = measure == .edits ? stats.current.edits : stats.current.sessions
        let largest: Double
        if showsBars {
            largest = max(Double(totals.values.max() ?? 0), averagePoints.map(\.value).max() ?? 0)
        } else {
            largest = Double(total)
        }
        let scale = NiceScale.ticks(maximum: largest, count: 3)
        let first = starts.first ?? stats.range.first
        let last = starts.last ?? stats.range.last

        self.calendar = calendar
        unit = stats.unit
        component = GrowthChartMath.component(stats.unit)
        self.starts = starts
        seriesIDs = ids
        colors = series.map(\.color)
        self.centers = centers
        self.titles = titles
        self.names = names
        bars = showsBars ? Self.bars(perBucket, starts: starts, ids: ids, centers: centers) : []
        areas = showsBars ? [] : Self.points(running, starts: starts, ids: ids, centers: centers)
        average = averagePoints
        self.totals = totals
        peak = showsBars ? Self.peak(totals, starts: starts, centers: centers) : nil
        table = Self.table(showsBars ? perBucket : running, starts: starts, ids: ids)
        measureTotal = total
        yTop = scale.top
        yTicks = scale.values
        let lower = GrowthChartMath.midnight(first, calendar: calendar)
        let upper = GrowthChartMath.midnight(GrowthChartMath.bucketEnd(last, unit: stats.unit), calendar: calendar)
        domain = lower...max(lower, upper)
        labelDates = Self.labelStarts(starts, unit: stats.unit).compactMap { centers[$0.index] }
        // Cap bars at 24pt when there are few buckets, so 7D never reads as blocks.
        barWidth = starts.count <= 14 ? MarkDimension.fixed(24) : MarkDimension.ratio(0.7)
    }

    /// The running total fades from 0.85 to 0.35 down each profile's band.
    var gradients: [LinearGradient] {
        colors.map { (color: Color) -> LinearGradient in
            LinearGradient(colors: [color.opacity(0.85), color.opacity(0.35)], startPoint: .top, endPoint: .bottom)
        }
    }

    func contains(_ start: DayKey?) -> Bool {
        guard let start else { return false }
        return centers[start.index] != nil
    }

    func bucket(containing date: Date) -> DayKey? {
        let day = GrowthChartMath.civilDay(of: date, calendar: calendar)
        let start = GrowthChartMath.bucketStart(of: day, unit: unit)
        return centers[start.index] == nil ? nil : start
    }

    func label(for date: Date?) -> String {
        guard let date else { return "" }
        let day = GrowthChartMath.civilDay(of: date, calendar: calendar)
        switch unit {
        case .day: return DayFormat.short(day, calendar: calendar)
        case .week: return DayFormat.short(day.weekStart, calendar: calendar)
        case .month: return DayFormat.monthAbbreviation(day, calendar: calendar)
        }
    }

    private static func lookup(_ series: [GrowthSeries]) -> [String: String] {
        var lookup: [String: String] = [:]
        for item in series {
            for sourceID in item.sourceIDs { lookup[sourceID] = item.id }
        }
        return lookup
    }

    /// Series ID → bucket start index → measure, with folded profiles summed.
    private static func sums(_ buckets: [Bucket], lookup: [String: String],
                             measure: GrowthMeasure) -> [String: [Int: Int]] {
        var result: [String: [Int: Int]] = [:]
        for bucket in buckets {
            guard let seriesID = lookup[bucket.sourceID] else { continue }
            let value = measure == .edits ? bucket.edits : bucket.sessions
            result[seriesID, default: [:]][bucket.start.index, default: 0] += value
        }
        return result
    }

    private static func totals(_ sums: [String: [Int: Int]]) -> [Int: Int] {
        var totals: [Int: Int] = [:]
        for values in sums.values {
            for (start, value) in values { totals[start, default: 0] += value }
        }
        return totals
    }

    /// Sparse bars in bucket order, then series order, so stacks follow sources order.
    private static func bars(_ sums: [String: [Int: Int]], starts: [DayKey], ids: [String],
                             centers: [Int: Date]) -> [Bar] {
        var bars: [Bar] = []
        for start in starts {
            guard let date = centers[start.index] else { continue }
            for id in ids {
                let value = sums[id]?[start.index] ?? 0
                guard value > 0 else { continue }
                bars.append(Bar(id: "\(id)|\(start.index)", start: start, date: date, seriesID: id,
                                value: Double(value)))
            }
        }
        return bars
    }

    /// Dense points, every series at every bucket, so the areas stack cleanly.
    private static func points(_ sums: [String: [Int: Int]], starts: [DayKey], ids: [String],
                               centers: [Int: Date]) -> [Point] {
        var points: [Point] = []
        for start in starts {
            guard let date = centers[start.index] else { continue }
            for id in ids {
                let value = sums[id]?[start.index] ?? 0
                points.append(Point(id: "\(id)|\(start.index)", start: start, date: date, seriesID: id,
                                    value: Double(value)))
            }
        }
        return points
    }

    private static func average(_ points: [AveragePoint], calendar: ActivityCalendar) -> [Point] {
        points.map { (point: AveragePoint) -> Point in
            Point(id: "average|\(point.day.index)", start: point.day, date: calendar.noon(of: point.day),
                  seriesID: "average", value: point.value)
        }
    }

    /// The busiest bucket; a tie goes to the later one.
    private static func peak(_ totals: [Int: Int], starts: [DayKey], centers: [Int: Date]) -> Total? {
        var best: Total?
        for start in starts {
            let value = totals[start.index] ?? 0
            guard value > 0, value >= (best?.value ?? 0), let date = centers[start.index] else { continue }
            best = Total(start: start, date: date, value: value)
        }
        return best
    }

    private static func table(_ sums: [String: [Int: Int]], starts: [DayKey], ids: [String]) -> [String: [Double]] {
        var table: [String: [Double]] = [:]
        for id in ids {
            table[id] = starts.map { (start: DayKey) -> Double in Double(sums[id]?[start.index] ?? 0) }
        }
        return table
    }

    /// Labels count back from the newest bucket, so today is always labeled.
    private static func labelStarts(_ starts: [DayKey], unit: BucketUnit) -> [DayKey] {
        let step = labelStep(count: starts.count, unit: unit)
        var labels: [DayKey] = []
        // Labels count back from the newest bucket. When labels are spaced out, the
        // newest one is skipped: it sits on the plot's trailing edge and would clip.
        for (offset, start) in starts.enumerated()
        where (starts.count - 1 - offset) % step == 0 && (step == 1 || offset != starts.count - 1) {
            labels.append(start)
        }
        return labels
    }

    /// Every day at 7D, every 5 days at 30D, every 2+ weeks, monthly.
    private static func labelStep(count: Int, unit: BucketUnit) -> Int {
        switch unit {
        case .day:
            if count <= 8 { return 1 }
            return count <= 16 ? 2 : 5
        case .week:
            if count <= 8 { return 1 }
            return max(2, (count + 7) / 8)
        case .month:
            if count <= 12 { return 1 }
            return (count + 7) / 8
        }
    }
}

/// Scales, axes, the sunken plot well and the local calendar, shared by the bar
/// and running-total charts so toggling never moves the axes.
private struct GrowthAxesModifier: ViewModifier {
    let model: GrowthChartModel

    func body(content: Content) -> some View {
        content
            .chartXScale(domain: model.domain)
            .chartYScale(domain: 0...model.yTop)
            .chartXAxis { xAxis }
            .chartYAxis { yAxis }
            .chartPlotStyle { plot in
                plot.background(Theme.Palette.sunken, in: Theme.Radius.shape(Theme.Radius.control))
            }
            .environment(\.calendar, model.calendar.gregorian)
            .environment(\.timeZone, model.calendar.timeZone)
    }

    private var xAxis: some AxisContent {
        AxisMarks(values: model.labelDates) { (value: AxisValue) in
            AxisValueLabel(anchor: .top) {
                Text(model.label(for: value.as(Date.self)))
                    .font(Theme.Typeface.micro)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var yAxis: some AxisContent {
        AxisMarks(position: .leading, values: model.yTicks) { (value: AxisValue) in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                .foregroundStyle(Theme.Palette.hairline)
            AxisValueLabel {
                Text(GrowthChartMath.axisLabel(value.as(Double.self)))
                    .font(Theme.Typeface.micro)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// The selection card: a row per profile and the total. The bucket title is
/// already in the card subtitle, so it is left out to keep the card inside
/// the 150pt plot.
private struct GrowthBucketPopover: View {
    struct Row: Identifiable {
        let id: String
        let name: String
        let color: Color
        let edits: Int
        let sessions: Int
    }

    let rows: [Row]

    /// Four profile lines fit the plot; past that the three busiest show and
    /// the rest fold into "+N more", while the total still counts them all.
    private static let maxLines = 4

    private var shape: RoundedRectangle { Theme.Radius.shape(Theme.Radius.card) }

    private var shownRows: [Row] {
        guard rows.count > Self.maxLines else { return rows }
        let busiest = rows.sorted { (lhs: Row, rhs: Row) -> Bool in
            (lhs.edits, lhs.sessions) > (rhs.edits, rhs.sessions)
        }
        let kept = Set(busiest.prefix(Self.maxLines - 1).map(\.id))
        return rows.filter { kept.contains($0.id) }
    }

    var body: some View {
        content
            .padding(10)
            .frame(width: 212, alignment: .leading)
            .background(.regularMaterial, in: shape)
            .overlay { shape.strokeBorder(Theme.Palette.hairline, lineWidth: 0.5) }
            .shadow(color: Theme.Palette.surfaceShadow, radius: 6, x: 0, y: 2)
    }

    @ViewBuilder private var content: some View {
        if rows.isEmpty {
            Text("No recorded activity")
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
        } else {
            table
        }
    }

    private var table: some View {
        let shown = shownRows
        let hidden = rows.count - shown.count
        return Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                headerText("Profile")
                headerText("Edits")
                    .gridColumnAlignment(.trailing)
                headerText("Sessions")
                    .gridColumnAlignment(.trailing)
            }
            ForEach(shown) { (row: Row) in
                GridRow {
                    identity(row)
                    Text(row.edits.formatted())
                    Text(row.sessions.formatted())
                }
            }
            if hidden > 0 {
                headerText("+\(hidden) more")
            }
            Divider()
            GridRow {
                Text("Total")
                    .fontWeight(.semibold)
                Text(rows.reduce(0) { $0 + $1.edits }.formatted())
                    .fontWeight(.semibold)
                Text(rows.reduce(0) { $0 + $1.sessions }.formatted())
                    .fontWeight(.semibold)
            }
        }
        .font(Theme.Typeface.caption.monospacedDigit())
    }

    private func headerText(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typeface.micro)
            .foregroundStyle(.secondary)
    }

    private func identity(_ row: Row) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(row.color)
                .frame(width: 7, height: 7)
            Text(row.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// Legend chips wrap as whole items, so long profile names never squeeze the plot.
private struct GrowthLegendFlow: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrangement(width: bounds.width, subviews: subviews).frames
        for (index, frame) in frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                  anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrangement(width: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        let available = width.flatMap { $0.isFinite ? max(0, $0) : nil }
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(ProposedViewSize(width: available, height: nil))
            if x > 0, let available, x + size.width > available {
                x = 0
                y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            usedWidth = max(usedWidth, x + size.width)
            x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: available ?? usedWidth, height: y + rowHeight), frames)
    }
}

// MARK: - Trail calendar

/// 26 Monday-first weeks of local days in one Canvas, with month and weekday
/// labels, a bracket under the selected period and weekday totals beside it.
/// Hover writes the subtitle; clicking a day in the period selects it in the chart.
struct TrailCalendarCard: View, Equatable {
    private let grid: CalendarGrid
    private let range: DayRange
    private let calendar: ActivityCalendar
    /// A focused profile with edits in the grid; nil shows every profile.
    private let focus: String?
    private let focusName: String?
    private let ramp: [Color]
    private let progress: Double
    private let onSelectDay: (DayKey) -> Void
    @State private var hovered: Int?

    private static let cellSize: CGFloat = 13
    private static let gap: CGFloat = 3
    private static let rowLabelWidth: CGFloat = 16
    private static let barWidth: CGFloat = 44

    init(grid: CalendarGrid, range: DayRange, calendar: ActivityCalendar, focus: String?, focusName: String?,
         ramp: [Color], progress: Double, onSelectDay: @escaping (DayKey) -> Void) {
        self.grid = grid
        self.range = range
        self.calendar = calendar
        self.focus = focus
        self.focusName = focusName
        self.ramp = ramp
        self.progress = progress
        self.onSelectDay = onSelectDay
    }

    /// The closure is excluded. Guard clauses keep each comparison a separate type-check.
    static func == (lhs: TrailCalendarCard, rhs: TrailCalendarCard) -> Bool {
        guard lhs.range == rhs.range, lhs.progress == rhs.progress else { return false }
        guard lhs.focus == rhs.focus, lhs.focusName == rhs.focusName else { return false }
        guard lhs.calendar == rhs.calendar, lhs.ramp == rhs.ramp else { return false }
        return lhs.grid == rhs.grid
    }

    var body: some View {
        let layout = GrowthCalendarLayout(grid: grid, range: range, focus: focus, calendar: calendar)
        return SectionCard(title: "Trail calendar", subtitle: subtitle) {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                calendarColumn(layout)
                weekdayColumn
            }
            footer
        }
    }

    // MARK: Grid

    private func calendarColumn(_ layout: GrowthCalendarLayout) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            monthLabels(layout)
            HStack(alignment: .top, spacing: 4) {
                rowLabels
                HeatmapGrid(columns: grid.weeks, rows: 7, levels: layout.levels, dimmed: layout.dimmed, ramp: ramp,
                            cellSize: Self.cellSize, gap: Self.gap, bracket: layout.bracket,
                            revealProgress: progress,
                            onHover: { index in hovered = index },
                            onSelect: { index in select(index) })
                    .accessibilityElement()
                    .accessibilityLabel("Trail calendar")
                    .accessibilityValue(accessibilitySummary)
                    .accessibilityChartDescriptor(descriptor)
            }
        }
    }

    private func monthLabels(_ layout: GrowthCalendarLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.months) { (month: GrowthCalendarLayout.Month) in
                Text(month.title)
                    .font(Theme.Typeface.micro)
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .offset(x: CGFloat(month.column) * (Self.cellSize + Self.gap))
            }
        }
        .frame(width: layout.gridWidth(cellSize: Self.cellSize, gap: Self.gap), height: 12, alignment: .topLeading)
        .padding(.leading, Self.rowLabelWidth + 4)
        .accessibilityHidden(true)
    }

    private var rowLabels: some View {
        VStack(alignment: .leading, spacing: Self.gap) {
            ForEach(0..<7, id: \.self) { (row: Int) in
                Text(Self.showsRowLabel(row) ? DayFormat.weekday(row, style: .narrow) : "")
                    .font(Theme.Typeface.micro)
                    .foregroundStyle(.secondary)
                    .frame(width: Self.rowLabelWidth, height: Self.cellSize, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }

    /// Monday, Wednesday and Friday.
    private static func showsRowLabel(_ row: Int) -> Bool {
        row == 0 || row == 2 || row == 4
    }

    private func select(_ index: Int) {
        guard grid.cells.indices.contains(index) else { return }
        let cell = grid.cells[index]
        guard cell.inRange, !cell.isFuture else { return }
        onSelectDay(cell.day)
    }

    // MARK: Weekday totals

    private var weekdayColumn: some View {
        let maximum = max(grid.weekdayTotals.max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Weekday totals")
                .font(Theme.Typeface.micro)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(height: 12)
            VStack(alignment: .leading, spacing: Self.gap) {
                ForEach(0..<7, id: \.self) { (weekday: Int) in
                    weekdayBar(weekday, maximum: maximum)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Weekday totals")
        .accessibilityValue(weekdaySummary)
    }

    private func weekdayTotal(_ weekday: Int) -> Int {
        grid.weekdayTotals.indices.contains(weekday) ? grid.weekdayTotals[weekday] : 0
    }

    private func weekdayShare(_ weekday: Int) -> Double {
        grid.weekdayShare.indices.contains(weekday) ? grid.weekdayShare[weekday] : 0
    }

    private func weekdayBar(_ weekday: Int, maximum: Int) -> some View {
        let total = weekdayTotal(weekday)
        let share = weekdayShare(weekday)
        let length = Self.barWidth * CGFloat(total) / CGFloat(maximum) * CGFloat(progress)
        return HStack(spacing: 4) {
            Capsule()
                .fill(Theme.Palette.heat(3))
                .frame(width: total > 0 ? max(2, length) : 0, height: 7)
                .frame(width: Self.barWidth, alignment: .leading)
            Text(PercentFormat.share(share))
                .font(Theme.Typeface.micro.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(height: Self.cellSize)
        .help("\(DayFormat.weekday(weekday, style: .full)) · \(GrowthText.edits(total)) · \(PercentFormat.share(share))")
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Theme.Space.xs) {
            legendRamp
            Spacer(minLength: Theme.Space.xs)
            if let caption = busiestWeekdayCaption {
                Text(caption)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var legendRamp: some View {
        HStack(spacing: 3) {
            Text("Less")
            ForEach(0..<5, id: \.self) { (level: Int) in
                Theme.Radius.shape(2)
                    .fill(rampColor(level))
                    .frame(width: 9, height: 9)
            }
            Text("More")
        }
        .font(Theme.Typeface.micro)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(legendDescription)
    }

    private var legendDescription: String {
        guard let focusName else { return "Color shows recorded edits per day, from less to more" }
        return "Color shows \(focusName) edits per day, from less to more"
    }

    private func rampColor(_ level: Int) -> Color {
        ramp.indices.contains(level) ? ramp[level] : Theme.Palette.heat(level)
    }

    private var busiestWeekdayCaption: String? {
        let totals = grid.weekdayTotals
        guard let best = totals.indices.max(by: { totals[$0] < totals[$1] }), totals[best] > 0 else { return nil }
        return "Busiest weekday: \(DayFormat.weekday(best, style: .full)) · \(PercentFormat.share(weekdayShare(best)))"
    }

    // MARK: Text

    private var subtitle: String {
        guard let hovered, grid.cells.indices.contains(hovered) else { return "\(grid.weeks) weeks · local days" }
        return describe(grid.cells[hovered])
    }

    /// "Tue, Oct 21 · 64 edits · 3 sessions · 2 profiles", plus the focused profile's count.
    private func describe(_ cell: CalendarCell) -> String {
        let day = DayFormat.long(cell.day, calendar: calendar)
        if cell.beforeHistory { return "\(day) · before saved history" }
        var parts = [day, GrowthText.edits(cell.edits), GrowthText.sessions(cell.sessions),
                     GrowthText.profiles(cell.profiles)]
        if let focus, let focusName {
            parts.append("\(focusName) \((cell.bySource[focus] ?? 0).formatted())")
        }
        return parts.joined(separator: " · ")
    }

    private var weekdaySummary: String {
        (0..<7).map { (weekday: Int) -> String in
            "\(DayFormat.weekday(weekday, style: .full)) \(PercentFormat.share(weekdayShare(weekday)))"
        }
        .joined(separator: ", ")
    }

    /// The count a cell is colored by: the focused profile's edits, or every profile's.
    private func shownEdits(_ cell: CalendarCell) -> Int {
        focus.map { cell.bySource[$0] ?? 0 } ?? cell.edits
    }

    /// Follows the focus, so VoiceOver hears the same days sighted users see colored.
    private var accessibilitySummary: String {
        let active = grid.cells.filter { !$0.isFuture && shownEdits($0) > 0 }.count
        let days = GrowthText.count(active, "active day", "active days")
        guard let focusName else { return "\(days) in the last \(grid.weeks) weeks" }
        return "\(days) for \(focusName) in the last \(grid.weeks) weeks"
    }

    private var descriptor: GrowthChartDescriptor {
        let weeks = (0..<grid.weeks).map { (column: Int) -> String in
            let index = column * 7
            guard grid.cells.indices.contains(index) else { return "" }
            return "Week of \(DayFormat.short(grid.cells[index].day, calendar: calendar))"
        }
        let rows = (0..<7).map { (weekday: Int) -> GrowthChartDescriptor.Series in
            let values = (0..<grid.weeks).map { (column: Int) -> Double in
                let index = column * 7 + weekday
                guard grid.cells.indices.contains(index) else { return 0 }
                let cell = grid.cells[index]
                return cell.isFuture ? 0 : Double(shownEdits(cell))
            }
            return GrowthChartDescriptor.Series(name: DayFormat.weekday(weekday, style: .full), values: values)
        }
        let title = focusName.map { "Trail calendar, \($0)" } ?? "Trail calendar"
        return GrowthChartDescriptor(title: title, summary: accessibilitySummary, xTitle: "Week",
                                     categories: weeks, yTitle: "Edits", series: rows)
    }
}

/// Levels, dimming, the period bracket and month labels for the calendar.
private struct GrowthCalendarLayout {
    struct Month: Identifiable {
        let column: Int
        let title: String

        var id: Int { column }
    }

    let levels: [Int]
    let dimmed: [Bool]
    let bracket: Range<Int>?
    let months: [Month]
    let columns: Int

    init(grid: CalendarGrid, range: DayRange, focus: String?, calendar: ActivityCalendar) {
        let thresholds = focus.flatMap { grid.sourceThresholds[$0] } ?? grid.thresholds
        var levels: [Int] = []
        var dimmed: [Bool] = []
        var firstColumn: Int?
        var lastColumn: Int?
        levels.reserveCapacity(grid.cells.count)
        dimmed.reserveCapacity(grid.cells.count)
        for (index, cell) in grid.cells.enumerated() {
            if cell.isFuture {
                // Future days are not drawn.
                levels.append(-1)
                dimmed.append(false)
                continue
            }
            let count = focus.map { cell.bySource[$0] ?? 0 } ?? cell.edits
            levels.append(cell.beforeHistory ? 0 : thresholds.level(count))
            dimmed.append(cell.beforeHistory)
            if cell.inRange {
                let column = index / 7
                firstColumn = min(firstColumn ?? column, column)
                lastColumn = max(lastColumn ?? column, column)
            }
        }
        self.levels = levels
        self.dimmed = dimmed
        if let firstColumn, let lastColumn {
            bracket = firstColumn..<(lastColumn + 1)
        } else {
            bracket = nil
        }
        months = Self.monthLabels(grid: grid, calendar: calendar)
        columns = grid.weeks
    }

    func gridWidth(cellSize: CGFloat, gap: CGFloat) -> CGFloat {
        max(0, CGFloat(columns) * (cellSize + gap) - gap)
    }

    /// A label above each column where the month changes; one squeezed in
    /// fewer than three columns before the next label is dropped.
    private static func monthLabels(grid: CalendarGrid, calendar: ActivityCalendar) -> [Month] {
        var candidates: [Month] = []
        for column in 0..<grid.weeks {
            let index = column * 7
            guard grid.cells.indices.contains(index) else { break }
            let day = grid.cells[index].day
            let isNewMonth = column == 0 || day.month != grid.cells[index - 7].day.month
            if isNewMonth {
                candidates.append(Month(column: column, title: DayFormat.monthAbbreviation(day, calendar: calendar)))
            }
        }
        var months: [Month] = []
        for (offset, candidate) in candidates.enumerated() {
            let next = offset + 1 < candidates.count ? candidates[offset + 1].column : Int.max
            if next - candidate.column >= 3 { months.append(candidate) }
        }
        return months
    }
}

// MARK: - Profile mix

/// A donut of each profile's share of edits, a table with share change and
/// delegation, and the shared-days footer.
struct ProfileMixCard: View, Equatable {
    private let shares: [SourceShare]
    private let series: [GrowthSeries]
    private let profiles: [AgentSource]
    private let sharedDays: Int
    private let showsChange: Bool
    private let calendar: ActivityCalendar
    private let focus: String?
    private let progress: Double
    private let onFocus: (String?) -> Void
    /// The slice under the current click or drag, so one gesture focuses once.
    @State private var gestureSlice: String?

    private static let donutSize: CGFloat = 140

    init(shares: [SourceShare], series: [GrowthSeries], profiles: [AgentSource], sharedDays: Int, showsChange: Bool,
         calendar: ActivityCalendar, focus: String?, progress: Double, onFocus: @escaping (String?) -> Void) {
        self.shares = shares
        self.series = series
        self.profiles = profiles
        self.sharedDays = sharedDays
        self.showsChange = showsChange
        self.calendar = calendar
        self.focus = focus
        self.progress = progress
        self.onFocus = onFocus
    }

    /// The closure is excluded. Guard clauses keep each comparison a separate type-check.
    static func == (lhs: ProfileMixCard, rhs: ProfileMixCard) -> Bool {
        guard lhs.sharedDays == rhs.sharedDays, lhs.showsChange == rhs.showsChange else { return false }
        guard lhs.focus == rhs.focus, lhs.progress == rhs.progress else { return false }
        guard lhs.calendar == rhs.calendar, lhs.profiles == rhs.profiles else { return false }
        guard lhs.series == rhs.series else { return false }
        return lhs.shares == rhs.shares
    }

    private var slices: [GrowthSeries] { series.filter { $0.edits > 0 } }

    var body: some View {
        SectionCard(title: "Profile mix", subtitle: "Share of recorded edits in this period") {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                donut
                table
            }
            footer
        }
        .onChange(of: focus) { _, value in
            if value == nil { gestureSlice = nil }
        }
    }

    // MARK: Donut

    private var donut: some View {
        let slices = self.slices
        return ZStack {
            if slices.isEmpty {
                Circle()
                    .strokeBorder(Theme.Palette.sunken, lineWidth: Self.donutSize * 0.19)
            } else {
                donutChart(slices)
            }
            donutCenter(slices)
        }
        .frame(width: Self.donutSize, height: Self.donutSize)
    }

    private func donutChart(_ slices: [GrowthSeries]) -> some View {
        Chart {
            ForEach(slices) { (slice: GrowthSeries) in
                SectorMark(angle: .value("Edits", slice.edits), innerRadius: .ratio(0.62), angularInset: 1.5)
                    .cornerRadius(Theme.Radius.cell)
                    .foregroundStyle(by: .value("Profile", slice.id))
                    .opacity(sliceOpacity(slice.id))
                    .accessibilityLabel(slice.name)
                    .accessibilityValue(sliceValue(slice))
            }
        }
        .chartForegroundStyleScale(domain: slices.map(\.id), range: slices.map(\.color))
        .chartLegend(.hidden)
        .chartAngleSelection(value: angleBinding(slices))
        .scaleEffect(CGFloat(0.92 + 0.08 * progress))
        .opacity(progress)
        .accessibilityChartDescriptor(descriptor(slices))
    }

    /// "62% of edits, 1,234 edits", matching the table row's wording.
    private func sliceValue(_ slice: GrowthSeries) -> String {
        "\(PercentFormat.share(slice.editShare)) of edits, \(GrowthText.edits(slice.edits))"
    }

    private func sliceOpacity(_ seriesID: String) -> Double {
        guard let focus else { return 1 }
        return focus == seriesID ? 1 : 0.35
    }

    /// A click focuses the slice under it; clicking the focused slice again clears it.
    private func angleBinding(_ slices: [GrowthSeries]) -> Binding<Int?> {
        Binding(get: { nil }, set: { value in
            guard let value else {
                gestureSlice = nil
                return
            }
            guard let id = Self.slice(at: value, in: slices), id != gestureSlice else { return }
            let startsGesture = gestureSlice == nil
            gestureSlice = id
            onFocus(startsGesture && id == focus ? nil : id)
        })
    }

    /// The slice whose cumulative edit range holds `value`.
    private static func slice(at value: Int, in slices: [GrowthSeries]) -> String? {
        var running = 0
        for slice in slices {
            running += slice.edits
            if value < running { return slice.id }
        }
        return slices.last?.id
    }

    private func donutCenter(_ slices: [GrowthSeries]) -> some View {
        let focused = slices.first { $0.id == focus }
        let total = slices.reduce(0) { $0 + $1.edits }
        // The full count fits inside the ring up to five digits.
        let totalText = total < 100_000 ? total.formatted() : CompactNumber.string(total)
        let value = focused.map { PercentFormat.share($0.editShare) } ?? totalText
        return VStack(spacing: 1) {
            Text(value)
                .font(Theme.Typeface.metric)
                .contentTransition(.numericText())
            Text(focused?.name ?? "edits")
                .font(Theme.Typeface.micro)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 76)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Table

    private var table: some View {
        VStack(alignment: .leading, spacing: 2) {
            tableHeader
            ForEach(shares) { (share: SourceShare) in
                row(share)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tableHeader: some View {
        HStack(spacing: 6) {
            Text("Profile")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Share")
                .frame(width: GrowthMixColumn.share, alignment: .trailing)
            Text("Edits")
                .frame(width: GrowthMixColumn.edits, alignment: .trailing)
            if showsChange {
                Text("Change")
                    .frame(width: GrowthMixColumn.change, alignment: .trailing)
            }
            Text("Delegated")
                .frame(width: GrowthMixColumn.delegation, alignment: .leading)
            Text("Since")
                .frame(width: GrowthMixColumn.since, alignment: .trailing)
        }
        .font(Theme.Typeface.micro)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, 4)
        .accessibilityHidden(true)
    }

    private func row(_ share: SourceShare) -> some View {
        let seriesID = ProfileColor.seriesID(share.sourceID, sources: profiles)
        let isFocused = focus == seriesID
        return Button { onFocus(isFocused ? nil : seriesID) } label: {
            rowContent(share)
                .padding(.horizontal, 4)
                .frame(height: 22)
                .background(isFocused ? Theme.Palette.sunken : Color.clear, in: Theme.Radius.shape(6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(focus == nil || isFocused ? 1 : 0.55)
        .accessibilityLabel(sentence(share))
        .accessibilityHint(isFocused ? "Clears the profile focus" : "Highlights this profile across Growth")
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    private func rowContent(_ share: SourceShare) -> some View {
        HStack(spacing: 6) {
            identity(share.sourceID)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(PercentFormat.share(share.share))
                .frame(width: GrowthMixColumn.share, alignment: .trailing)
            Text(share.edits.formatted())
                .frame(width: GrowthMixColumn.edits, alignment: .trailing)
            if showsChange {
                Text(PercentChange.points(share: share.share, previous: share.previousShare) ?? "—")
                    .foregroundStyle(.secondary)
                    .frame(width: GrowthMixColumn.change, alignment: .trailing)
            }
            GrowthDelegationCell(color: ProfileColor.color(share.sourceID, sources: profiles), edits: share.edits,
                                 delegated: share.delegatedEdits, reported: share.delegationReported)
                .frame(width: GrowthMixColumn.delegation, alignment: .leading)
            Text(since(share))
                .font(Theme.Typeface.micro)
                .foregroundStyle(.secondary)
                .frame(width: GrowthMixColumn.since, alignment: .trailing)
                .help(firstSeenHelp(share))
        }
        .font(Theme.Typeface.caption.monospacedDigit())
        .lineLimit(1)
    }

    /// A dot, plus a monogram for slate profiles that share one color.
    private func identity(_ sourceID: String) -> some View {
        let name = GrowthSeries.name(of: sourceID, sources: profiles)
        let isOther = ProfileColor.slot(for: sourceID, sources: profiles) == .other
        return HStack(spacing: 5) {
            Circle()
                .fill(ProfileColor.color(sourceID, sources: profiles))
                .frame(width: 7, height: 7)
            if isOther {
                Text(ProfileColor.monogram(name))
                    .font(Theme.Typeface.micro)
                    .foregroundStyle(.secondary)
            }
            Text(name)
                .truncationMode(.middle)
        }
    }

    private func since(_ share: SourceShare) -> String {
        guard let first = share.firstDay else { return "" }
        return DayFormat.short(first, calendar: calendar)
    }

    private func firstSeenHelp(_ share: SourceShare) -> String {
        guard let first = share.firstDay else { return "" }
        return "First recorded \(DayFormat.withYear(first, calendar: calendar)), in saved history"
    }

    private func sentence(_ share: SourceShare) -> String {
        let name = GrowthSeries.name(of: share.sourceID, sources: profiles)
        var parts = [name, "\(PercentFormat.share(share.share)) of edits", GrowthText.edits(share.edits)]
        if showsChange, let points = PercentChange.points(share: share.share, previous: share.previousShare) {
            parts.append("\(points) versus the previous period")
        }
        if !share.delegationReported {
            parts.append("delegation not reported")
        } else if share.edits > 0 {
            let fraction = Double(share.delegatedEdits) / Double(share.edits)
            parts.append("\(PercentFormat.share(fraction)) delegated")
        }
        if let first = share.firstDay {
            parts.append("since \(DayFormat.withYear(first, calendar: calendar))")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: Footer

    private var footer: some View {
        Text("\(GrowthText.count(sharedDays, "shared day", "shared days")) · two or more profiles edited the same project on one day")
            .font(Theme.Typeface.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func descriptor(_ slices: [GrowthSeries]) -> GrowthChartDescriptor {
        let total = slices.reduce(0) { $0 + $1.edits }
        return GrowthChartDescriptor(title: "Profile mix", summary: "\(GrowthText.edits(total)) by profile",
                                     xTitle: "Profile", categories: slices.map(\.name), yTitle: "Edits",
                                     series: [GrowthChartDescriptor.Series(name: "Recorded edits",
                                                                           values: slices.map { Double($0.edits) })])
    }
}

/// Fixed column widths, so rows line up under the header.
private enum GrowthMixColumn {
    static let share: CGFloat = 32
    static let edits: CGFloat = 38
    static let change: CGFloat = 48
    static let delegation: CGFloat = 70
    static let since: CGFloat = 44
}

/// The delegation capsule: direct edits solid, delegated edits hatched; a dashed
/// outline with "not reported" for Grok, which records no subagents.
private struct GrowthDelegationCell: View {
    let color: Color
    let edits: Int
    let delegated: Int
    let reported: Bool

    private var fraction: Double {
        edits > 0 ? min(1, Double(delegated) / Double(edits)) : 0
    }

    var body: some View {
        content
            .help(help)
    }

    @ViewBuilder private var content: some View {
        if !reported {
            // An empty dashed capsule in the same slot as the others; the help
            // and accessibility text say it is not reported.
            HStack(spacing: 4) {
                Capsule()
                    .strokeBorder(Color.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: 40, height: 6)
                Text("—")
                    .font(Theme.Typeface.micro)
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("Delegation not reported")
        } else if edits == 0 {
            Text("—")
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 4) {
                GrowthHatchedCapsule(color: color, fraction: fraction)
                    .frame(width: 40, height: 6)
                Text(PercentFormat.share(fraction))
                    .font(Theme.Typeface.micro.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var help: String {
        if !reported { return "Grok does not report delegated edits" }
        guard edits > 0 else { return "No recorded edits in this period" }
        return "\(PercentFormat.share(fraction)) delegated: first recorded in a subagent (Claude) or a spawned thread (Codex)"
    }
}

/// 40×6 capsule: the direct share solid, the delegated share at 0.45 with 45° hatching.
private struct GrowthHatchedCapsule: View {
    let color: Color
    let fraction: Double

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            context.clip(to: Path(roundedRect: bounds, cornerRadius: size.height / 2))
            let directWidth = size.width * CGFloat(1 - fraction)
            context.fill(Path(CGRect(x: 0, y: 0, width: directWidth, height: size.height)), with: .color(color))
            let delegatedRect = CGRect(x: directWidth, y: 0, width: size.width - directWidth, height: size.height)
            guard delegatedRect.width > 0 else { return }
            context.fill(Path(delegatedRect), with: .color(color.opacity(0.45)))
            var hatch = context
            hatch.clip(to: Path(delegatedRect))
            var lines = Path()
            var x = delegatedRect.minX - size.height
            while x < delegatedRect.maxX {
                lines.move(to: CGPoint(x: x, y: size.height))
                lines.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 3
            }
            hatch.stroke(lines, with: .color(color), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Where edits landed

/// All projects only: the projects edited in the period, each with a
/// profile-stacked bar scaled to the top row. Clicking a row scopes Growth to it.
struct WhereEditsLandedCard: View, Equatable {
    private let rows: [ProjectRow]
    private let touched: Int
    private let count: Int
    private let profiles: [AgentSource]
    private let progress: Double
    private let select: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill
    @State private var isExpanded = false
    @State private var hoveredPath: String?

    private static let collapsedCount = 6

    init(rows: [ProjectRow], touched: Int, count: Int, profiles: [AgentSource], progress: Double,
         select: @escaping (String) -> Void) {
        self.rows = rows
        self.touched = touched
        self.count = count
        self.profiles = profiles
        self.progress = progress
        self.select = select
    }

    /// The closure is excluded. Guard clauses keep each comparison a separate type-check.
    static func == (lhs: WhereEditsLandedCard, rhs: WhereEditsLandedCard) -> Bool {
        guard lhs.touched == rhs.touched, lhs.count == rhs.count else { return false }
        guard lhs.progress == rhs.progress, lhs.profiles == rhs.profiles else { return false }
        return lhs.rows == rhs.rows
    }

    private var visibleRows: [ProjectRow] {
        isExpanded ? rows : Array(rows.prefix(Self.collapsedCount))
    }

    var body: some View {
        let maximum = max(rows.first?.edits ?? 0, 1)
        return SectionCard(title: "Where edits landed",
                           subtitle: "\(touched.formatted()) of \(GrowthText.count(count, "project", "projects")) touched") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(visibleRows) { (row: ProjectRow) in
                    rowButton(row, maximum: maximum)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityChartDescriptor(descriptor)
            if rows.count > Self.collapsedCount {
                expander
            }
        }
    }

    private func rowButton(_ row: ProjectRow, maximum: Int) -> some View {
        Button { select(row.path) } label: {
            HStack(spacing: Theme.Space.xs) {
                Text(row.name)
                    .font(Theme.Typeface.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 128, alignment: .leading)
                bar(row, maximum: maximum)
                Text(row.edits.formatted())
                    .font(Theme.Typeface.cardMetric)
                    .frame(width: 48, alignment: .trailing)
                DeltaBadge(current: row.edits, previous: row.previousEdits)
                    .frame(width: 50, alignment: .trailing)
            }
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(hoveredPath == row.path ? Theme.Palette.sunken : Color.clear,
                        in: Theme.Radius.shape(Theme.Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hover(row.path, inside: inside) }
        .help(PathFormat.abbreviate(row.path))
        .accessibilityLabel(sentence(row))
        .accessibilityHint("Shows this project in Growth")
    }

    private func hover(_ path: String, inside: Bool) {
        if inside {
            hoveredPath = path
        } else if hoveredPath == path {
            hoveredPath = nil
        }
    }

    private func bar(_ row: ProjectRow, maximum: Int) -> some View {
        let fraction = CGFloat(row.edits) / CGFloat(maximum) * CGFloat(progress)
        let parts = segments(row)
        // MixBar spends 2pt between drawn segments, so the floor adds room for
        // those gaps and every row keeps 4pt of color.
        let drawn = parts.filter { $0.value > 0 }.count
        let minimum: CGFloat = 4 + 2 * CGFloat(max(drawn - 1, 0))
        return GeometryReader { proxy in
            MixBar(segments: parts, height: 6)
                .frame(width: max(minimum, proxy.size.width * fraction))
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private func segments(_ row: ProjectRow) -> [MixBar.Segment] {
        row.bySource.map { (count: SourceCount) -> MixBar.Segment in
            let name = GrowthSeries.name(of: count.sourceID, sources: profiles)
            return MixBar.Segment(id: count.sourceID, color: ProfileColor.color(count.sourceID, sources: profiles),
                                  value: count.edits, help: "\(name) · \(GrowthText.edits(count.edits))")
        }
    }

    private var expander: some View {
        Button {
            let animation = Theme.Motion.animation(Theme.Motion.standard, reduceMotion: reduceMotion, still: rendersStill)
            withAnimation(animation) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text(isExpanded ? "Show fewer" : "+\(rows.count - Self.collapsedCount) more")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
            .font(Theme.Typeface.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Show fewer projects" : "Show \(rows.count - Self.collapsedCount) more projects")
    }

    private func sentence(_ row: ProjectRow) -> String {
        var parts = [row.name, "\(row.edits.formatted()) recorded edits"]
        if let change = PercentChange.accessibility(current: row.edits, previous: row.previousEdits) {
            parts.append(change)
        }
        return parts.joined(separator: ", ")
    }

    private var descriptor: GrowthChartDescriptor {
        GrowthChartDescriptor(title: "Where edits landed",
                              summary: "\(touched) of \(GrowthText.count(count, "project", "projects")) touched",
                              xTitle: "Project", categories: rows.map(\.name), yTitle: "Edits",
                              series: [GrowthChartDescriptor.Series(name: "Recorded edits",
                                                                    values: rows.map { Double($0.edits) })])
    }
}
