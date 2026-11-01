import SwiftUI
import AgentTrailCore

// MARK: - Heatmap grid

/// A calendar-style grid drawn in one Canvas, with no per-cell views. Cells are
/// column-major (`column * rows + row`), matching `CalendarGrid.cells`. Hover and
/// clicks report cell indexes; the caller owns the text they produce.
struct HeatmapGrid: View, Equatable, Animatable {
    let columns: Int
    let rows: Int
    /// Level 0-4 per cell; a negative level is not drawn (future days).
    let levels: [Int]
    /// Cells drawn at 40% opacity, such as days before the first recorded day.
    let dimmed: [Bool]
    /// Five colors for levels 0-4: `Theme.Palette.heatRamp` or `ProfileColor.ramp(for:sources:)`.
    let ramp: [Color]
    let cellSize: CGFloat
    let gap: CGFloat
    /// Columns that intersect the selected period get a 2pt bracket underneath.
    let bracket: Range<Int>?
    /// 0…1. Columns fade in left to right with a capped stagger; 1 is the final state.
    var revealProgress: Double
    private let onHover: (Int?) -> Void
    private let onSelect: ((Int) -> Void)?
    @State private var hovered: Int?

    /// Space reserved under the grid for the bracket, so the layout never jumps.
    static let bracketSpace: CGFloat = 6
    private static let fadeDuration = 0.2

    init(columns: Int, rows: Int = 7, levels: [Int], dimmed: [Bool] = [], ramp: [Color],
         cellSize: CGFloat = 13, gap: CGFloat = 3, bracket: Range<Int>? = nil, revealProgress: Double = 1,
         onHover: @escaping (Int?) -> Void = { _ in }, onSelect: ((Int) -> Void)? = nil) {
        self.columns = max(0, columns)
        self.rows = max(1, rows)
        self.levels = levels
        self.dimmed = dimmed
        self.ramp = ramp.isEmpty ? Theme.Palette.heatRamp : ramp
        self.cellSize = cellSize
        self.gap = gap
        self.bracket = bracket
        self.revealProgress = revealProgress
        self.onHover = onHover
        self.onSelect = onSelect
    }

    var animatableData: Double {
        get { revealProgress }
        set { revealProgress = newValue }
    }

    /// Closures are excluded. Guard clauses keep each comparison a separate type-check.
    static func == (lhs: HeatmapGrid, rhs: HeatmapGrid) -> Bool {
        guard lhs.columns == rhs.columns, lhs.rows == rhs.rows else { return false }
        guard lhs.cellSize == rhs.cellSize, lhs.gap == rhs.gap else { return false }
        guard lhs.bracket == rhs.bracket, lhs.revealProgress == rhs.revealProgress else { return false }
        guard lhs.levels == rhs.levels, lhs.dimmed == rhs.dimmed else { return false }
        return lhs.ramp == rhs.ramp
    }

    private var pitch: CGFloat { cellSize + gap }
    var gridWidth: CGFloat { max(0, CGFloat(columns) * pitch - gap) }
    var gridHeight: CGFloat { max(0, CGFloat(rows) * pitch - gap) }

    var body: some View {
        Canvas { context, _ in
            draw(in: &context)
        }
        .frame(width: gridWidth, height: gridHeight + Self.bracketSpace)
        .contentShape(Rectangle())
        .onContinuousHover { phase in hover(phase) }
        .onTapGesture { location in select(at: location) }
    }

    /// The cell under a point, or nil outside the grid or over an undrawn cell. A gap
    /// counts toward the cell before it, so hover does not flicker between cells.
    func cellIndex(at location: CGPoint) -> Int? {
        guard location.x >= 0, location.y >= 0, pitch > 0 else { return nil }
        let column = Int(location.x / pitch)
        let row = Int(location.y / pitch)
        guard column < columns, row < rows else { return nil }
        let index = column * rows + row
        guard levels.indices.contains(index), levels[index] >= 0 else { return nil }
        return index
    }

    private func hover(_ phase: HoverPhase) {
        let index: Int?
        switch phase {
        case .active(let location): index = cellIndex(at: location)
        case .ended: index = nil
        }
        guard index != hovered else { return }
        hovered = index
        onHover(index)
    }

    private func select(at location: CGPoint) {
        guard let onSelect, let index = cellIndex(at: location) else { return }
        onSelect(index)
    }

    private func draw(in context: inout GraphicsContext) {
        for column in 0..<columns {
            let alpha = columnAlpha(column)
            guard alpha > 0 else { continue }
            for row in 0..<rows {
                drawCell(column: column, row: row, alpha: alpha, in: &context)
            }
        }
        if let hovered, let rect = cellRect(hovered) {
            let outline = Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: Theme.Radius.cell + 1,
                               style: .continuous)
            context.stroke(outline, with: .color(Color.primary.opacity(0.6)), lineWidth: 1)
        }
        drawBracket(in: &context)
    }

    private func drawCell(column: Int, row: Int, alpha: Double, in context: inout GraphicsContext) {
        let index = column * rows + row
        guard levels.indices.contains(index), levels[index] >= 0 else { return }
        let level = min(levels[index], ramp.count - 1)
        let isDimmed = dimmed.indices.contains(index) && dimmed[index]
        let rect = CGRect(x: CGFloat(column) * pitch, y: CGFloat(row) * pitch, width: cellSize, height: cellSize)
        let path = Path(roundedRect: rect, cornerRadius: Theme.Radius.cell, style: .continuous)
        context.fill(path, with: .color(ramp[level].opacity(alpha * (isDimmed ? 0.4 : 1))))
    }

    private func drawBracket(in context: inout GraphicsContext) {
        guard let bracket else { return }
        let lower = min(max(bracket.lowerBound, 0), columns)
        let upper = min(max(bracket.upperBound, 0), columns)
        guard upper > lower else { return }
        let rect = CGRect(x: CGFloat(lower) * pitch, y: gridHeight + 3,
                          width: CGFloat(upper - lower) * pitch - gap, height: 2)
        context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Color.primary.opacity(0.5)))
    }

    private func cellRect(_ index: Int) -> CGRect? {
        guard index >= 0 else { return nil }
        let column = index / rows, row = index % rows
        guard column < columns else { return nil }
        return CGRect(x: CGFloat(column) * pitch, y: CGFloat(row) * pitch, width: cellSize, height: cellSize)
    }

    /// Column opacity during the reveal: a 12ms stagger per column, capped at
    /// 0.3s in total, then a 0.2s fade per column.
    private func columnAlpha(_ column: Int) -> Double {
        guard revealProgress < 1 else { return 1 }
        let stagger = min(Theme.Motion.calendarStaggerCap, Theme.Motion.calendarStagger * Double(max(columns - 1, 0)))
        let time = max(0, revealProgress) * (stagger + Self.fadeDuration)
        let start = columns > 1 ? stagger * Double(column) / Double(columns - 1) : 0
        return min(1, max(0, (time - start) / Self.fadeDuration))
    }
}

// MARK: - Punch card

/// Edits by weekday row and hour column in one Canvas. Circle area follows the
/// count (radius 7·√(count/max), at least 1.5pt), and the fill uses the ramp by
/// level. Empty cells show a faint level-0 dot so the grid stays readable.
struct PunchCard: View, Equatable, Animatable {
    static let columns = 24

    /// Row-major counts: `row * 24 + column`, as `RhythmSummary.grid`.
    let grid: [Int]
    let levels: LevelThresholds
    let ramp: [Color]
    /// One label per row, such as "Mon"…"Sun".
    let rowLabels: [String]
    /// Labels under chosen columns, keyed by column (rollover slot).
    let columnLabels: [Int: String]
    let pitch: CGFloat
    /// 0…1. Circles grow to their final radius.
    var revealProgress: Double
    private let onHover: (Int?) -> Void
    @State private var hovered: Int?

    static let labelWidth: CGFloat = 30
    static let footerHeight: CGFloat = 16

    init(grid: [Int], levels: LevelThresholds, ramp: [Color], rowLabels: [String],
         columnLabels: [Int: String], pitch: CGFloat = 17, revealProgress: Double = 1,
         onHover: @escaping (Int?) -> Void = { _ in }) {
        self.grid = grid
        self.levels = levels
        self.ramp = ramp.isEmpty ? Theme.Palette.heatRamp : ramp
        self.rowLabels = rowLabels
        self.columnLabels = columnLabels
        self.pitch = pitch
        self.revealProgress = revealProgress
        self.onHover = onHover
    }

    /// Labels at the given wall-clock hours (06, 12, 18, 00 by default), placed
    /// in the columns of a grid that starts at the rollover hour.
    static func hourLabels(rolloverHour: Int = ActivityCalendar.defaultRolloverHour,
                           hours: [Int] = [6, 12, 18, 0]) -> [Int: String] {
        var labels: [Int: String] = [:]
        for hour in hours {
            labels[(hour - rolloverHour + 48) % 24] = DayFormat.hour(hour)
        }
        return labels
    }

    var animatableData: Double {
        get { revealProgress }
        set { revealProgress = newValue }
    }

    /// The hover closure is excluded. Guard clauses keep each comparison a separate type-check.
    static func == (lhs: PunchCard, rhs: PunchCard) -> Bool {
        guard lhs.pitch == rhs.pitch, lhs.revealProgress == rhs.revealProgress else { return false }
        guard lhs.grid == rhs.grid, lhs.levels == rhs.levels else { return false }
        guard lhs.rowLabels == rhs.rowLabels, lhs.columnLabels == rhs.columnLabels else { return false }
        return lhs.ramp == rhs.ramp
    }

    private var rows: Int { grid.count / Self.columns }
    private var maxCount: Int { max(grid.max() ?? 0, 1) }
    var plotWidth: CGFloat { Self.labelWidth + CGFloat(Self.columns) * pitch }
    var plotHeight: CGFloat { CGFloat(rows) * pitch + Self.footerHeight }

    var body: some View {
        Canvas { context, _ in
            draw(in: &context)
        }
        .frame(width: plotWidth, height: plotHeight)
        .contentShape(Rectangle())
        .onContinuousHover { phase in hover(phase) }
    }

    /// The cell index (`row * 24 + column`) under a point, or nil outside the grid.
    func cellIndex(at location: CGPoint) -> Int? {
        let x = location.x - Self.labelWidth
        guard x >= 0, location.y >= 0, pitch > 0 else { return nil }
        let column = Int(x / pitch), row = Int(location.y / pitch)
        guard column < Self.columns, row < rows else { return nil }
        return row * Self.columns + column
    }

    private func hover(_ phase: HoverPhase) {
        let index: Int?
        switch phase {
        case .active(let location): index = cellIndex(at: location)
        case .ended: index = nil
        }
        guard index != hovered else { return }
        hovered = index
        onHover(index)
    }

    private func center(row: Int, column: Int) -> CGPoint {
        CGPoint(x: Self.labelWidth + (CGFloat(column) + 0.5) * pitch, y: (CGFloat(row) + 0.5) * pitch)
    }

    private func draw(in context: inout GraphicsContext) {
        for row in 0..<rows {
            for column in 0..<Self.columns {
                drawCell(row: row, column: column, in: &context)
            }
        }
        if let hovered {
            let point = center(row: hovered / Self.columns, column: hovered % Self.columns)
            let rect = CGRect(x: point.x - pitch / 2 + 0.5, y: point.y - pitch / 2 + 0.5,
                              width: pitch - 1, height: pitch - 1)
            context.stroke(Path(roundedRect: rect, cornerRadius: Theme.Radius.cell, style: .continuous),
                           with: .color(Color.primary.opacity(0.5)), lineWidth: 1)
        }
        drawLabels(in: &context)
    }

    private func drawCell(row: Int, column: Int, in context: inout GraphicsContext) {
        let count = grid[row * Self.columns + column]
        let point = center(row: row, column: column)
        let progress = min(1, max(0, revealProgress))
        let radius: CGFloat
        let color: Color
        if count > 0 {
            radius = max(1.5, 7 * CGFloat((Double(count) / Double(maxCount)).squareRoot())) * progress
            color = ramp[min(levels.level(count), ramp.count - 1)]
        } else {
            radius = 1
            color = ramp[0]
        }
        guard radius > 0 else { return }
        let rect = CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        context.fill(Path(ellipseIn: rect), with: .color(color))
    }

    private func drawLabels(in context: inout GraphicsContext) {
        for (row, label) in rowLabels.prefix(rows).enumerated() {
            let text: Text = Text(label).font(Theme.Typeface.micro).foregroundStyle(Color.secondary)
            context.draw(text, at: CGPoint(x: Self.labelWidth - 6, y: (CGFloat(row) + 0.5) * pitch), anchor: .trailing)
        }
        let baseline = CGFloat(rows) * pitch + Self.footerHeight / 2 + 1
        for (column, label) in columnLabels where column >= 0 && column < Self.columns {
            let text: Text = Text(label).font(Theme.Typeface.micro).foregroundStyle(Color.secondary)
            context.draw(text, at: CGPoint(x: Self.labelWidth + (CGFloat(column) + 0.5) * pitch, y: baseline),
                         anchor: .center)
        }
    }
}
