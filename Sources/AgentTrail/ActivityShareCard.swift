import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AgentTrailCore

/// A local, path-free portrait of one scope and period. It reads only a
/// `PortraitSummary`, which carries day totals and no hours, slots or paths, so
/// rhythm and folder names can never reach an exported image. Every color is
/// fixed: ImageRenderer carries no NSAppearance.
struct ActivityShareCard: View, Equatable {
    static let size = CGSize(width: 1000, height: 700)

    private let summary: PortraitSummary
    private let sampleData: Bool
    private let tree: ShareCardTreeModel
    private let strip: ShareCardStripModel

    init(summary: PortraitSummary, sources: [AgentSource], sampleData: Bool = false) {
        self.summary = summary
        self.sampleData = sampleData
        self.tree = ShareCardTreeModel(summary: summary, sources: sources)
        self.strip = ShareCardStripModel(strip: summary.strip, busiestDay: summary.busiestDay, calendar: summary.calendar)
    }

    /// The tree model carries the resolved profile colors, so it covers `sources`.
    static func == (lhs: ActivityShareCard, rhs: ActivityShareCard) -> Bool {
        guard lhs.sampleData == rhs.sampleData, lhs.summary == rhs.summary else { return false }
        return lhs.tree == rhs.tree
    }

    var body: some View {
        ZStack {
            Theme.Palette.Share.background
            ShareCardBackdrop()
            content
            ShareCardBackdrop.panelShape
                .stroke(Theme.Palette.Share.stroke, lineWidth: 1)
                .padding(ShareCardBackdrop.inset)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, .dark)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ShareCardBrandRow(sampleData: sampleData)
            HStack(alignment: .top, spacing: 0) {
                ShareCardIntroduction(summary: summary, strip: strip)
                    .frame(width: ShareCardLayout.leftColumn, alignment: .topLeading)
                ShareCardTree(model: tree)
                    .frame(width: ShareCardLayout.treeWidth, height: ShareCardLayout.treeHeight)
                    .padding(.top, 6)
            }
            .padding(.top, 30)
            Spacer(minLength: 0)
            ShareCardMetrics(summary: summary)
            ShareCardFootnote(namesShown: summary.namesShown)
        }
        .padding(.horizontal, ShareCardLayout.horizontalPadding)
        .padding(.top, 42)
        .padding(.bottom, 34)
    }
}

// MARK: - Layout

private enum ShareCardLayout {
    /// 40 + 380 + 540 + 40 = 1000.
    static let horizontalPadding: CGFloat = 40
    static let leftColumn: CGFloat = 380
    static let treeWidth: CGFloat = 540
    static let treeHeight: CGFloat = 340
}

/// Ink for the card. Everything derives from the fixed share constants.
private enum ShareCardInk {
    static let brandName = Theme.Palette.Share.headline.opacity(0.97)
    static let guide = Theme.Palette.Share.hairline.opacity(0.35)
    static let rootHalo = Theme.Palette.Share.hairline.opacity(0.4)
    static let nodeRing = Theme.Palette.Share.faintText.opacity(0.67)
    static let sessionDot = Theme.Palette.Share.text.opacity(0.78)
    static let laneName = Theme.Palette.Share.text.opacity(0.85)
    static let divider: [Color] = [Theme.Palette.Share.hairline, Theme.Palette.Share.hairline.opacity(0.3)]

    static func ramp(_ level: Int) -> Color {
        let ramp = Theme.Palette.Share.inkRamp
        return ramp[min(max(level, 0), ramp.count - 1)]
    }
}

/// Nearest-rank quartiles of the non-zero values, the same rule the app's
/// calendar uses (spec §9 row 16).
private enum ShareCardLevels {
    static func thresholds(_ values: [Int]) -> LevelThresholds {
        let sorted = values.filter { $0 > 0 }.sorted()
        guard !sorted.isEmpty else { return .empty }
        func rank(_ percent: Int) -> Int {
            let position = (percent * sorted.count + 99) / 100
            return sorted[min(sorted.count - 1, max(0, position - 1))]
        }
        return LevelThresholds(q1: rank(25), q2: rank(50), q3: rank(75))
    }
}

// MARK: - Backdrop

private struct ShareCardBackdrop: View {
    static let inset: CGFloat = 12
    static let panelShape = RoundedRectangle(cornerRadius: 29, style: .continuous)

    var body: some View {
        ZStack {
            Self.panelShape.fill(LinearGradient(colors: [Theme.Palette.Share.panelTop, Theme.Palette.Share.panelBottom],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
            Ellipse()
                .fill(Theme.Palette.Share.glowIndigo)
                .frame(width: 520, height: 300)
                .blur(radius: 110)
                .offset(x: 250, y: -170)
            Ellipse()
                .fill(Theme.Palette.Share.glowViolet)
                .frame(width: 440, height: 260)
                .blur(radius: 100)
                .offset(x: -240, y: 200)
        }
        .clipShape(Self.panelShape)
        .padding(Self.inset)
    }
}

// MARK: - Brand row

private struct ShareCardBrandRow: View {
    let sampleData: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Theme.Palette.Share.brand)
            Text("Agent Trail")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ShareCardInk.brandName)
            Spacer()
            Text(sampleData ? "SAMPLE DATA · ACTIVITY PORTRAIT" : "ACTIVITY PORTRAIT")
                .font(.system(size: 10, weight: .semibold))
                .tracking(2.1)
                .foregroundStyle(Theme.Palette.Share.secondaryText)
        }
    }
}

// MARK: - Left column

private struct ShareCardIntroduction: View {
    let summary: PortraitSummary
    let strip: ShareCardStripModel

    private var periodLine: String {
        "\(summary.periodTitle) · \(summary.dateRangeText) · local days"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(summary.headline)
                .font(.system(size: 54, weight: .semibold, design: .rounded))
                .tracking(-2)
                .lineSpacing(-2)
                .foregroundStyle(Theme.Palette.Share.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.55)
                .allowsTightening(true)
            ShareCardScopeLine(title: summary.scopeTitle)
                .padding(.top, 18)
            Text(periodLine)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Palette.Share.secondaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 7)
            ShareCardStrip(model: strip)
                .padding(.top, 26)
        }
    }
}

private struct ShareCardScopeLine: View {
    let title: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(LinearGradient(colors: Theme.Palette.Share.underline, startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.Palette.Share.text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

// MARK: - Mini strip

/// The window's days, ready to draw: seven bars for 7D, otherwise a
/// Monday-first calendar of the window's weeks only.
private struct ShareCardStripModel: Equatable {
    struct Bar: Identifiable, Equatable {
        let id: Int
        let title: String
        let edits: Int
        let level: Int
        let height: CGFloat
    }

    struct Cell: Equatable {
        let column: Int
        let row: Int
        let level: Int
        let inWindow: Bool
    }

    struct Tick: Equatable {
        let index: Int
        let text: String
    }

    struct Weeks: Equatable {
        let columns: Int
        let cells: [Cell]
        let months: [Tick]
        let rows: [Tick]
    }

    enum Graphic: Equatable {
        case bars([Bar])
        case weeks(Weeks)
    }

    static let barMaxHeight: CGFloat = 90

    let graphic: Graphic
    let caption: String

    var showsLegend: Bool {
        if case .weeks = graphic { return true }
        return false
    }

    /// The caption comes from the summary's `busiestDay`, which covers the
    /// whole range; a weeks strip keeps only the latest 26 weeks.
    init(strip: PortraitStrip, busiestDay: PortraitDay?, calendar: ActivityCalendar) {
        switch strip {
        case .days(let days):
            graphic = .bars(Self.bars(days))
        case .weeks(let firstDay, let weeks, let days):
            graphic = .weeks(Self.weeks(firstDay: firstDay, count: weeks, days: days, calendar: calendar))
        }
        caption = Self.caption(busiestDay, calendar: calendar)
    }

    private static func bars(_ days: [PortraitDay]) -> [Bar] {
        let thresholds = ShareCardLevels.thresholds(days.map(\.edits))
        let peak = CGFloat(max(days.map(\.edits).max() ?? 0, 1))
        var bars: [Bar] = []
        for day in days {
            let height: CGFloat = day.edits > 0 ? max(4, barMaxHeight * CGFloat(day.edits) / peak) : 0
            bars.append(Bar(id: day.day.index, title: DayFormat.weekday(day.day.weekday, style: .short),
                            edits: day.edits, level: thresholds.level(day.edits), height: height))
        }
        return bars
    }

    /// Cells before the window draw empty at 30%; days after it (the rest of
    /// the current week) are not drawn, as in the app's Trail calendar.
    private static func weeks(firstDay: DayKey, count: Int, days: [PortraitDay], calendar: ActivityCalendar) -> Weeks {
        let columns = max(1, min(count, 26))
        let windowFirst = days.first?.day
        let windowLast = days.last?.day
        var edits: [Int: Int] = [:]
        for day in days { edits[day.day.index, default: 0] += day.edits }
        let thresholds = ShareCardLevels.thresholds(days.map(\.edits))

        var cells: [Cell] = []
        for column in 0..<columns {
            for row in 0..<7 {
                let day = firstDay.adding(days: column * 7 + row)
                if let windowLast, day > windowLast { continue }
                let inWindow = windowFirst.map { day >= $0 } ?? false
                let level = inWindow ? thresholds.level(edits[day.index] ?? 0) : 0
                cells.append(Cell(column: column, row: row, level: level, inWindow: inWindow))
            }
        }
        let rows = [0, 2, 4].map { (row: Int) -> Tick in Tick(index: row, text: DayFormat.weekday(row, style: .narrow)) }
        return Weeks(columns: columns, cells: cells, months: monthTicks(firstDay: firstDay, columns: columns, calendar: calendar),
                     rows: rows)
    }

    /// A label where the column's Monday starts a new month. A label closer
    /// than three columns to the next one is dropped, so the later, true month
    /// change wins.
    private static func monthTicks(firstDay: DayKey, columns: Int, calendar: ActivityCalendar) -> [Tick] {
        var candidates: [Tick] = []
        var previousMonth: Int?
        for column in 0..<columns {
            let monday = firstDay.adding(days: column * 7)
            let month = monday.year * 12 + monday.month
            if month != previousMonth {
                candidates.append(Tick(index: column, text: DayFormat.monthAbbreviation(monday, calendar: calendar)))
            }
            previousMonth = month
        }
        var ticks: [Tick] = []
        for (position, tick) in candidates.enumerated() {
            if position + 1 < candidates.count, candidates[position + 1].index - tick.index < 3 { continue }
            ticks.append(tick)
        }
        return ticks
    }

    /// The busiest day of the whole range, not just the drawn weeks.
    private static func caption(_ busiest: PortraitDay?, calendar: ActivityCalendar) -> String {
        guard let busiest, busiest.edits > 0 else { return "No recorded edits in this window" }
        let noun = busiest.edits == 1 ? "edit" : "edits"
        return "Busiest day \(DayFormat.long(busiest.day, calendar: calendar)) · \(busiest.edits.formatted(.number)) \(noun)"
    }
}

private struct ShareCardStrip: View {
    let model: ShareCardStripModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            graphic
            HStack(spacing: 14) {
                if model.showsLegend {
                    ShareCardLegend()
                }
                Text(model.caption)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Palette.Share.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }

    @ViewBuilder private var graphic: some View {
        switch model.graphic {
        case .bars(let bars):
            ShareCardBars(bars: bars)
        case .weeks(let weeks):
            ShareCardWeeks(weeks: weeks)
        }
    }
}

private struct ShareCardBars: View {
    static let barWidth: CGFloat = 28
    let bars: [ShareCardStripModel.Bar]

    var body: some View {
        HStack(alignment: .bottom, spacing: 18) {
            ForEach(bars) { (bar: ShareCardStripModel.Bar) in
                ShareCardBarColumn(bar: bar)
            }
        }
    }
}

private struct ShareCardBarColumn: View {
    let bar: ShareCardStripModel.Bar

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 6, style: .continuous) }
    private var valueText: String { bar.edits > 0 ? CompactNumber.string(bar.edits) : "–" }
    private var valueColor: Color { bar.edits > 0 ? Theme.Palette.Share.secondaryText : Theme.Palette.Share.faintText }

    var body: some View {
        VStack(spacing: 6) {
            Text(valueText)
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .fixedSize()
            ZStack(alignment: .bottom) {
                shape.fill(ShareCardInk.ramp(0))
                shape.fill(ShareCardInk.ramp(bar.level))
                    .frame(height: bar.height)
            }
            .frame(width: ShareCardBars.barWidth, height: ShareCardStripModel.barMaxHeight)
            Text(bar.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.Palette.Share.faintText)
                .lineLimit(1)
                .fixedSize()
        }
        .frame(width: ShareCardBars.barWidth)
    }
}

/// A Canvas calendar: month labels above, M/W/F on the left, 11pt cells with
/// 3pt gaps, capped at 26 weeks (375pt wide with the label column).
private struct ShareCardWeeks: View {
    static let cell: CGFloat = 11
    static let gap: CGFloat = 3
    static let labelColumn: CGFloat = 14
    static let monthRow: CGFloat = 16

    let weeks: ShareCardStripModel.Weeks

    private var width: CGFloat { Self.labelColumn + CGFloat(weeks.columns) * (Self.cell + Self.gap) - Self.gap }
    private var height: CGFloat { Self.monthRow + 7 * (Self.cell + Self.gap) - Self.gap }

    var body: some View {
        let weeks = self.weeks
        Canvas { context, _ in
            ShareCardWeeks.draw(weeks, in: &context)
        }
        .frame(width: max(width, 1), height: height)
    }

    private static func draw(_ weeks: ShareCardStripModel.Weeks, in context: inout GraphicsContext) {
        let pitch = cell + gap
        for tick in weeks.months {
            let origin = CGPoint(x: labelColumn + CGFloat(tick.index) * pitch, y: 0)
            drawLabel(tick.text, at: origin, anchor: .topLeading, in: &context)
        }
        for tick in weeks.rows {
            let origin = CGPoint(x: 0, y: monthRow + CGFloat(tick.index) * pitch + cell / 2)
            drawLabel(tick.text, at: origin, anchor: .leading, in: &context)
        }
        for item in weeks.cells {
            let rect = CGRect(x: labelColumn + CGFloat(item.column) * pitch, y: monthRow + CGFloat(item.row) * pitch,
                              width: cell, height: cell)
            let color = item.inWindow ? ShareCardInk.ramp(item.level) : ShareCardInk.ramp(0).opacity(0.3)
            context.fill(Path(roundedRect: rect, cornerRadius: 3, style: .continuous), with: .color(color))
        }
    }

    private static func drawLabel(_ text: String, at point: CGPoint, anchor: UnitPoint, in context: inout GraphicsContext) {
        var resolved = context.resolve(Text(text).font(.system(size: 10, weight: .medium)))
        resolved.shading = .color(Theme.Palette.Share.faintText)
        context.draw(resolved, at: point, anchor: anchor)
    }
}

private struct ShareCardLegend: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("Less")
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { (level: Int) in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(ShareCardInk.ramp(level))
                        .frame(width: 9, height: 9)
                }
            }
            Text("More")
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.Palette.Share.faintText)
        .fixedSize()
    }
}

// MARK: - Activity tree

/// Every constant the tree is drawn with. `drawTree` and `interpolatedY` both
/// read these, so twig origins always sit on their own branch.
private enum ShareCardTreeGeometry {
    static let canvasHeight: CGFloat = 287
    static let root = CGPoint(x: 25, y: 149)
    /// Where a branch finishes its fan-out from the root and runs flat as a lane.
    static let laneStartX: CGFloat = 112
    static let terminalX: CGFloat = 414
    /// Each twig leaves its lane this far before its node.
    static let twigReach: CGFloat = 47
    /// The first node sits one twig past the lane start, so every twig origin
    /// is on the flat part of its own lane, never on the shared fan-out.
    static let firstNodeX: CGFloat = laneStartX + twigReach
    static let lastNodeX: CGFloat = 400
    static let bend: CGFloat = 14
    static let labelX: CGFloat = 428
    static let labelWidth: CGFloat = 108
    static let guideTop: CGFloat = 19
    static let guideBottom: CGFloat = 263
    static let dateLabelY: CGFloat = 277
    static let maximumLanes = 4
    static let maximumDays = 14

    static func laneY(_ index: Int, count: Int) -> CGFloat {
        count <= 1 ? 135 : 45 + CGFloat(index) * (190 / CGFloat(max(1, count - 1)))
    }

    static func laneStart(laneY: CGFloat) -> CGPoint { CGPoint(x: laneStartX, y: laneY) }

    /// The cubic fan-out from the root to the lane start. Control x values keep
    /// x(t) monotonic, which `interpolatedY` relies on.
    static func controls(laneY: CGFloat) -> (first: CGPoint, second: CGPoint) {
        (CGPoint(x: root.x + 45, y: root.y), CGPoint(x: laneStartX - 40, y: laneY))
    }

    static func branchPath(laneY: CGFloat) -> Path {
        let control = controls(laneY: laneY)
        var path = Path()
        path.move(to: root)
        path.addCurve(to: laneStart(laneY: laneY), control1: control.first, control2: control.second)
        path.addLine(to: CGPoint(x: terminalX, y: laneY))
        return path
    }

    /// The branch's y at `x`: flat on the lane after `laneStartX`, otherwise the
    /// fan-out cubic solved for x by bisection (x is monotonic in t).
    static func interpolatedY(x: CGFloat, laneY: CGFloat) -> CGFloat {
        if x >= laneStartX { return laneY }
        if x <= root.x { return root.y }
        let control = controls(laneY: laneY)
        let end = laneStart(laneY: laneY)
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for _ in 0..<24 {
            let t = (lower + upper) / 2
            if cubic(t, root.x, control.first.x, control.second.x, end.x) < x { lower = t } else { upper = t }
        }
        return cubic((lower + upper) / 2, root.y, control.first.y, control.second.y, end.y)
    }

    static func cubic(_ t: CGFloat, _ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
        // Split into typed terms: one 15-operator expression with integer
        // literals is slow for the type checker.
        let u: CGFloat = 1 - t
        let first: CGFloat = u * u * u * a
        let second: CGFloat = 3 * u * u * t * b
        let third: CGFloat = 3 * u * t * t * c
        let fourth: CGFloat = t * t * t * d
        return first + second + third + fourth
    }

    static func nodeX(dayIndex: Int, dayCount: Int) -> CGFloat {
        let progress: CGFloat = dayCount <= 1 ? 0.65 : CGFloat(dayIndex) / CGFloat(dayCount - 1)
        return firstNodeX + progress * (lastNodeX - firstNodeX)
    }

    static func node(dayIndex: Int, dayCount: Int, laneIndex: Int, laneY: CGFloat, day: PortraitDay) -> ShareCardTreeModel.Node {
        let progress: CGFloat = dayCount <= 1 ? 0.65 : CGFloat(dayIndex) / CGFloat(dayCount - 1)
        let x = nodeX(dayIndex: dayIndex, dayCount: dayCount)
        let direction: CGFloat = laneIndex.isMultiple(of: 2) ? -1 : 1
        let wave: CGFloat = sin(progress * CGFloat.pi) * bend * direction
        let center = CGPoint(x: x, y: laneY + wave)
        let originX = max(root.x, x - twigReach)
        let origin = CGPoint(x: originX, y: interpolatedY(x: originX, laneY: laneY))
        let radius: CGFloat = day.edits > 0 ? min(12, 3.5 + sqrt(CGFloat(day.edits)) * 0.82) : 3.5
        return ShareCardTreeModel.Node(center: center, origin: origin, radius: radius,
                                       hasEdits: day.edits > 0, hasSessions: day.sessions > 0)
    }
}

/// The tree's lanes and nodes, laid out once per summary.
private struct ShareCardTreeModel: Equatable {
    struct Node: Equatable {
        let center: CGPoint
        let origin: CGPoint
        let radius: CGFloat
        let hasEdits: Bool
        let hasSessions: Bool
    }

    struct Lane: Identifiable, Equatable {
        let id: String
        let name: String
        let caption: String
        let color: Color
        let y: CGFloat
        let nodes: [Node]
    }

    struct DateTick: Identifiable, Equatable {
        let id: Int
        let x: CGFloat
        let text: String
    }

    let lanes: [Lane]
    let agentCount: Int
    let dateTicks: [DateTick]
    let dayCaption: String

    init(summary: PortraitSummary, sources: [AgentSource]) {
        let shown = Array(summary.agents.prefix(ShareCardTreeGeometry.maximumLanes))
        var activeDays = Set<DayKey>()
        for agent in summary.agents {
            for day in agent.days { activeDays.insert(day.day) }
        }
        let allDays = activeDays.sorted()
        let visible = Array(allDays.suffix(ShareCardTreeGeometry.maximumDays))
        var position: [DayKey: Int] = [:]
        for (index, day) in visible.enumerated() { position[day] = index }

        var lanes: [Lane] = []
        for (index, agent) in shown.enumerated() {
            let y = ShareCardTreeGeometry.laneY(index, count: shown.count)
            var nodes: [Node] = []
            for day in agent.days {
                guard let dayIndex = position[day.day] else { continue }
                nodes.append(ShareCardTreeGeometry.node(dayIndex: dayIndex, dayCount: visible.count,
                                                        laneIndex: index, laneY: y, day: day))
            }
            lanes.append(Lane(id: agent.sourceID, name: agent.name, caption: Self.caption(agent),
                              color: ProfileColor.fixed(agent.sourceID, sources: sources, dark: true), y: y, nodes: nodes))
        }
        self.lanes = lanes
        agentCount = summary.agents.count
        dateTicks = Self.dateTicks(visible, calendar: summary.calendar)
        dayCaption = Self.dayCaption(visible: visible.count, total: allDays.count)
    }

    private static func caption(_ agent: PortraitAgent) -> String {
        var edits = 0
        var sessions = 0
        for day in agent.days {
            edits += day.edits
            sessions += day.sessions
        }
        if edits > 0 { return "\(edits.formatted(.number)) \(edits == 1 ? "edit" : "edits")" }
        return "\(sessions.formatted(.number)) \(sessions == 1 ? "session" : "sessions")"
    }

    private static func dateTicks(_ visible: [DayKey], calendar: ActivityCalendar) -> [DateTick] {
        guard let first = visible.first, let last = visible.last else { return [] }
        let firstX = ShareCardTreeGeometry.nodeX(dayIndex: 0, dayCount: visible.count)
        let firstTick = DateTick(id: first.index, x: firstX, text: DayFormat.short(first, calendar: calendar))
        guard visible.count > 1 else { return [firstTick] }
        let lastX = ShareCardTreeGeometry.nodeX(dayIndex: visible.count - 1, dayCount: visible.count)
        return [firstTick, DateTick(id: last.index, x: lastX, text: DayFormat.short(last, calendar: calendar))]
    }

    private static func dayCaption(visible: Int, total: Int) -> String {
        if visible < total { return "Last \(visible) days with activity" }
        return "\(visible) \(visible == 1 ? "day" : "days") with activity"
    }
}

private struct ShareCardTree: View {
    let model: ShareCardTreeModel

    var body: some View {
        Group {
            if model.lanes.isEmpty {
                ShareCardEmptyTree()
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var content: some View {
        VStack(spacing: 0) {
            ShareCardTreePlot(model: model)
                .frame(height: ShareCardTreeGeometry.canvasHeight)
            ShareCardTreeLegend(caption: model.dayCaption)
                .padding(.top, 10)
            if model.agentCount > model.lanes.count {
                Text("Showing \(model.lanes.count) of \(model.agentCount) agent branches · totals include all agents")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Palette.Share.faintText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.top, 6)
            }
        }
    }
}

private struct ShareCardTreePlot: View {
    let model: ShareCardTreeModel

    var body: some View {
        let model = self.model
        ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                ShareCardTreePlot.drawTree(model, in: &context)
            }
            ForEach(model.lanes) { (lane: ShareCardTreeModel.Lane) in
                ShareCardLaneLabel(lane: lane)
                    .offset(x: ShareCardTreeGeometry.labelX, y: lane.y - 8)
            }
            ForEach(model.dateTicks) { (tick: ShareCardTreeModel.DateTick) in
                Text(tick.text)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.Palette.Share.faintText)
                    .fixedSize()
                    .position(x: tick.x, y: ShareCardTreeGeometry.dateLabelY)
            }
        }
    }

    private static func drawTree(_ model: ShareCardTreeModel, in context: inout GraphicsContext) {
        drawGuides(in: &context)
        for lane in model.lanes {
            drawBranch(lane, in: &context)
        }
        for lane in model.lanes {
            for node in lane.nodes { drawNode(node, color: lane.color, in: &context) }
        }
        drawRoot(in: &context)
    }

    /// Quiet guides reveal chronology without turning the card into a dashboard.
    private static func drawGuides(in context: inout GraphicsContext) {
        let first = ShareCardTreeGeometry.firstNodeX
        let step = (ShareCardTreeGeometry.lastNodeX - first) / 4
        for index in 0..<5 {
            let x = first + CGFloat(index) * step
            var guide = Path()
            guide.move(to: CGPoint(x: x, y: ShareCardTreeGeometry.guideTop))
            guide.addLine(to: CGPoint(x: x, y: ShareCardTreeGeometry.guideBottom))
            context.stroke(guide, with: .color(ShareCardInk.guide), style: StrokeStyle(lineWidth: 1, dash: [2, 7]))
        }
    }

    private static func drawBranch(_ lane: ShareCardTreeModel.Lane, in context: inout GraphicsContext) {
        let root = ShareCardTreeGeometry.root
        let end = CGPoint(x: ShareCardTreeGeometry.terminalX, y: lane.y)
        let branch = ShareCardTreeGeometry.branchPath(laneY: lane.y)
        context.stroke(branch, with: .color(lane.color.opacity(0.045)),
                       style: StrokeStyle(lineWidth: 17, lineCap: .round, lineJoin: .round))
        let gradient = Gradient(colors: [lane.color.opacity(0.08), lane.color.opacity(0.65)])
        context.stroke(branch, with: .linearGradient(gradient, startPoint: root, endPoint: end),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        let terminus = CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5)
        context.fill(Path(ellipseIn: terminus), with: .color(lane.color.opacity(0.7)))

        for node in lane.nodes {
            var twig = Path()
            twig.move(to: node.origin)
            twig.addQuadCurve(to: node.center, control: CGPoint(x: node.center.x - 11, y: node.origin.y))
            context.stroke(twig, with: .color(lane.color.opacity(0.37)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
    }

    /// Filled nodes are days with edits (size = edits); a hollow ring is a
    /// sessions-only day; the white center marks a day a session started.
    private static func drawNode(_ node: ShareCardTreeModel.Node, color: Color, in context: inout GraphicsContext) {
        let radius = node.radius
        let halo = CGRect(x: node.center.x - radius * 2, y: node.center.y - radius * 2, width: radius * 4, height: radius * 4)
        context.fill(Path(ellipseIn: halo), with: .color(color.opacity(0.055)))
        let circle = Path(ellipseIn: CGRect(x: node.center.x - radius, y: node.center.y - radius,
                                            width: radius * 2, height: radius * 2))
        guard node.hasEdits else {
            context.fill(circle, with: .color(color.opacity(0.14)))
            context.stroke(circle, with: .color(color.opacity(0.85)), lineWidth: 1.2)
            return
        }
        context.fill(circle, with: .color(color.opacity(0.84)))
        context.stroke(circle, with: .color(ShareCardInk.nodeRing), lineWidth: 0.7)
        if node.hasSessions {
            let center = CGRect(x: node.center.x - 1.4, y: node.center.y - 1.4, width: 2.8, height: 2.8)
            context.fill(Path(ellipseIn: center), with: .color(ShareCardInk.sessionDot))
        }
    }

    private static func drawRoot(in context: inout GraphicsContext) {
        let root = ShareCardTreeGeometry.root
        context.fill(Path(ellipseIn: CGRect(x: root.x - 14, y: root.y - 14, width: 28, height: 28)),
                     with: .color(ShareCardInk.rootHalo))
        context.fill(Path(ellipseIn: CGRect(x: root.x - 5, y: root.y - 5, width: 10, height: 10)),
                     with: .color(Theme.Palette.Share.brand))
    }
}

private struct ShareCardLaneLabel: View {
    let lane: ShareCardTreeModel.Lane

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle().fill(lane.color).frame(width: 6, height: 6)
                Text(lane.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ShareCardInk.laneName)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Text(lane.caption)
                .font(.system(size: 10).monospacedDigit())
                .foregroundStyle(Theme.Palette.Share.faintText)
                .lineLimit(1)
                .padding(.leading, 12)
        }
        .frame(width: ShareCardTreeGeometry.labelWidth, alignment: .leading)
    }
}

private struct ShareCardTreeLegend: View {
    let caption: String

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Theme.Palette.Share.faintText).frame(width: 4, height: 4)
            Circle().fill(Theme.Palette.Share.secondaryText).frame(width: 7, height: 7)
            Text("Node size = recorded edits")
            Circle()
                .strokeBorder(Theme.Palette.Share.secondaryText, lineWidth: 1)
                .frame(width: 7, height: 7)
                .padding(.leading, 6)
            Text("Sessions only")
            Spacer(minLength: 8)
            Text(caption)
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.Palette.Share.faintText)
        .lineLimit(1)
        .padding(.leading, 18)
        .padding(.trailing, 3)
    }
}

private struct ShareCardEmptyTree: View {
    var body: some View {
        VStack(spacing: 17) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(Theme.Palette.Share.hairline)
            Text("Every trail starts somewhere.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Palette.Share.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Metrics and footnote

private struct ShareCardMetrics: View {
    let summary: PortraitSummary

    private var streakUnit: String { summary.longestStreak == 1 ? "day" : "days" }
    private var agentLabel: String { summary.agents.count == 1 ? "Agent" : "Agents" }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ShareCardMetric(value: summary.edits, unit: nil, label: "Recorded edits")
            ShareCardMetric(value: summary.activeDays, unit: nil, label: "Active days")
            ShareCardMetric(value: summary.longestStreak, unit: streakUnit, label: "Longest streak")
            ShareCardMetric(value: summary.agents.count, unit: nil, label: agentLabel)
        }
        .padding(.top, 22)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LinearGradient(colors: ShareCardInk.divider, startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
        }
    }
}

/// A white numeral over a 2pt indigo-to-violet trail underline. No profile hues.
private struct ShareCardMetric: View {
    let value: Int
    let unit: String?
    let label: String

    private var numeral: Text {
        let number = Text(value.formatted(.number))
            .font(.system(size: 41, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.Palette.Share.numeral)
        guard let unit else { return number }
        let suffix = Text(" " + unit)
            .font(.system(size: 17, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.Palette.Share.secondaryText)
        return number + suffix
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            numeral
                .tracking(-1.5)
                .monospacedDigit()
                .lineLimit(1)
                .padding(.bottom, 9)
                .frame(minWidth: 40, alignment: .leading)
                .overlay(alignment: .bottomLeading) { underline }
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.Palette.Share.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var underline: some View {
        Capsule()
            .fill(LinearGradient(colors: Theme.Palette.Share.underline, startPoint: .leading, endPoint: .trailing))
            .frame(height: 2)
    }
}

private struct ShareCardFootnote: View {
    let namesShown: Bool

    var body: some View {
        HStack(alignment: .bottom) {
            Text("From local session records · Edits exclude shell and external changes")
            Spacer(minLength: 10)
            Label(namesShown ? "Names included" : "Names hidden", systemImage: namesShown ? "eye" : "eye.slash")
        }
        .font(.system(size: 10))
        .foregroundStyle(Theme.Palette.Share.faintText)
        .padding(.top, 24)
    }
}

// MARK: - Export

@MainActor
enum ActivityShareExporter {
    /// Exports only to a location the user picks. No upload or assistant access.
    static func export(summary: PortraitSummary, sources: [AgentSource], sampleData: Bool) {
        let panel = NSSavePanel()
        panel.title = "Export activity portrait"
        panel.nameFieldStringValue = "Agent-Trail-activity.png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.message = summary.namesShown
            ? "Project and profile names are included. Your portrait contains activity totals, dates and day patterns. Folder paths are never included."
            : "Project and profile names are hidden. Your portrait contains activity totals, dates and day patterns. Folder paths are never included."
        panel.prompt = "Export PNG"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let card = ActivityShareCard(summary: summary, sources: sources, sampleData: sampleData)
            let renderer = ImageRenderer(content: card)
            renderer.scale = 2
            renderer.isOpaque = true
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                showError("The activity portrait could not be rendered.")
                return
            }
            do {
                try png.write(to: url, options: .atomic)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not export activity portrait"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
