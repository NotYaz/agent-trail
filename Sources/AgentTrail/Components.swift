import AppKit
import SwiftUI
import AgentTrailCore

// MARK: - Sparkline

/// A small trend line: a faint area, a 1.5pt secondary line and a dot on the
/// last value. It draws in once per mount; Reduce Motion and still renders show
/// the final state. Values are drawn as given; callers pass precomputed series.
struct Sparkline: View, Equatable {
    private let values: [Int]
    /// How many trailing values are at full ink; earlier values draw at 0.35. Nil means all.
    private let emphasizeLast: Int?
    private let height: CGFloat
    private let label: String
    private let reveals: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill
    @State private var progress: CGFloat = 0

    init(values: [Int], emphasizeLast: Int? = nil, height: CGFloat = 20, accessibilityLabel: String,
         reveals: Bool = true) {
        self.values = values
        self.emphasizeLast = emphasizeLast
        self.height = height
        self.label = accessibilityLabel
        self.reveals = reveals
    }

    /// Comma-separated conditions keep each comparison a separate, cheap type-check.
    static func == (lhs: Sparkline, rhs: Sparkline) -> Bool {
        guard lhs.values == rhs.values, lhs.emphasizeLast == rhs.emphasizeLast else { return false }
        return lhs.height == rhs.height && lhs.label == rhs.label && lhs.reveals == rhs.reveals
    }

    private var isStill: Bool { reduceMotion || rendersStill || !reveals }

    var body: some View {
        Canvas { context, size in
            Sparkline.draw(values: values, emphasizeLast: emphasizeLast, in: &context, size: size)
        }
        .frame(height: height)
        .mask(alignment: .leading) {
            Rectangle().scaleEffect(x: isStill ? 1 : progress, y: 1, anchor: .leading)
        }
        .onAppear(perform: reveal)
        .accessibilityElement()
        .accessibilityLabel(label)
    }

    /// Still views finish the drawing at once, so turning Reduce Motion off later
    /// never leaves the mask stuck at zero.
    private func reveal() {
        guard !isStill else {
            progress = 1
            return
        }
        guard progress < 1 else { return }
        withAnimation(Theme.Motion.sparklineDraw) { progress = 1 }
    }

    private static func draw(values: [Int], emphasizeLast: Int?, in context: inout GraphicsContext, size: CGSize) {
        let points = plotPoints(values, size: size)
        guard let last = points.last else { return }
        let emphasized = min(max(emphasizeLast ?? points.count, 1), points.count)
        let split = points.count - emphasized
        if split > 0 {
            drawSegment(Array(points[0...split]), opacity: 0.35, bottom: size.height, in: &context)
        }
        drawSegment(Array(points[split...]), opacity: 1, bottom: size.height, in: &context)
        let dot = CGRect(x: last.x - 2, y: last.y - 2, width: 4, height: 4)
        context.fill(Path(ellipseIn: dot), with: .color(.primary))
    }

    private static func drawSegment(_ points: [CGPoint], opacity: Double, bottom: CGFloat,
                                    in context: inout GraphicsContext) {
        guard let first = points.first, let last = points.last else { return }
        var line = Path()
        line.move(to: first)
        for point in points.dropFirst() { line.addLine(to: point) }
        var area = line
        area.addLine(to: CGPoint(x: last.x, y: bottom))
        area.addLine(to: CGPoint(x: first.x, y: bottom))
        area.closeSubpath()
        context.fill(area, with: .color(Color.primary.opacity(0.12 * opacity)))
        context.stroke(line, with: .color(Color.secondary.opacity(opacity)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
    }

    private static func plotPoints(_ values: [Int], size: CGSize) -> [CGPoint] {
        let inset: CGFloat = 2.5
        let width = max(size.width - inset * 2, 1)
        let height = max(size.height - inset * 2, 1)
        let maximum = CGFloat(max(values.max() ?? 0, 1))
        let step = values.count > 1 ? width / CGFloat(values.count - 1) : 0
        return values.enumerated().map { index, value in
            let x = values.count > 1 ? inset + CGFloat(index) * step : inset + width
            return CGPoint(x: x, y: inset + height * (1 - CGFloat(max(value, 0)) / maximum))
        }
    }
}

// MARK: - Mix bar

/// A thin stacked capsule of shares, with 2pt gaps that show the surface.
/// Each segment carries its own help text.
struct MixBar: View, Equatable {
    struct Segment: Identifiable, Equatable {
        let id: String
        let color: Color
        let value: Int
        let help: String

        init(id: String, color: Color, value: Int, help: String) {
            self.id = id
            self.color = color
            self.value = value
            self.help = help
        }
    }

    private let segments: [Segment]
    private let height: CGFloat
    private let label: String?
    private let gap: CGFloat = 2

    init(segments: [Segment], height: CGFloat = 4, accessibilityLabel: String? = nil) {
        self.segments = segments.filter { $0.value > 0 }
        self.height = height
        self.label = accessibilityLabel
    }

    static func == (lhs: MixBar, rhs: MixBar) -> Bool {
        lhs.segments == rhs.segments && lhs.height == rhs.height && lhs.label == rhs.label
    }

    private var total: Int { segments.reduce(0) { $0 + $1.value } }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: gap) {
                ForEach(segments) { (segment: Segment) in
                    Rectangle()
                        .fill(segment.color)
                        .frame(width: width(of: segment, in: proxy.size.width))
                        .help(segment.help)
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .background {
            if segments.isEmpty { Capsule().fill(Theme.Palette.sunken) }
        }
        .accessibilityElement()
        .accessibilityLabel(label ?? segments.map(\.help).joined(separator: "; "))
    }

    private func width(of segment: Segment, in available: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        let usable = max(0, available - gap * CGFloat(max(segments.count - 1, 0)))
        return usable * CGFloat(segment.value) / CGFloat(total)
    }
}

// MARK: - Delta badge

/// Period-over-period change in neutral ink: "▲18%", "▼9%", "±0%" or "New".
/// Renders nothing when there is no comparison.
struct DeltaBadge: View, Equatable {
    private let current: Int
    private let previous: Int?

    init(current: Int, previous: Int?) {
        self.current = current
        self.previous = previous
    }

    var body: some View {
        if let text = PercentChange.label(current: current, previous: previous) {
            Text(text)
                .font(Theme.Typeface.micro.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(Theme.Palette.sunken, in: Capsule())
                .fixedSize()
                .accessibilityLabel(PercentChange.accessibility(current: current, previous: previous) ?? text)
        }
    }
}

// MARK: - Stat tile

/// Value size for a tile: Pulse tiles use the metric face, Growth KPIs the display face.
enum TileProminence: Equatable {
    case pulse
    case kpi
}

/// Where a tile's accessory sits: beside the value or on its own row below it.
enum TileAccessoryPlacement: Equatable {
    case trailing
    case below
}

/// A surface tile with a title, value, optional caption, delta and accessory.
/// It is one accessibility element; pass a full sentence for VoiceOver.
struct StatTile<Accessory: View>: View {
    private let title: String
    private let value: String
    private let numericValue: Double?
    private let symbol: String?
    private let symbolTint: Color?
    private let caption: String?
    private let delta: DeltaBadge?
    private let prominence: TileProminence
    private let placement: TileAccessoryPlacement
    private let help: String?
    private let sentence: String?
    private let action: (() -> Void)?
    private let accessory: Accessory

    init(title: String, value: String, numericValue: Double? = nil, symbol: String? = nil,
         symbolTint: Color? = nil, caption: String? = nil, delta: DeltaBadge? = nil,
         prominence: TileProminence = .kpi, accessoryPlacement: TileAccessoryPlacement = .below,
         help: String? = nil, accessibilityLabel: String? = nil, action: (() -> Void)? = nil,
         @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.value = value
        self.numericValue = numericValue
        self.symbol = symbol
        self.symbolTint = symbolTint
        self.caption = caption
        self.delta = delta
        self.prominence = prominence
        self.placement = accessoryPlacement
        self.help = help
        self.sentence = accessibilityLabel
        self.action = action
        self.accessory = accessory()
    }

    var body: some View {
        if let action {
            Button(action: action) { tile }
                .buttonStyle(TilePressStyle())
        } else {
            tile
        }
    }

    private var tile: some View {
        VStack(alignment: .leading, spacing: prominence == .kpi ? 4 : 2) {
            Text(title)
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            valueRow
            if placement == .below { accessory }
            if let caption {
                // Real totals run to four digits; shrink a little before truncating.
                Text(caption)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
        }
        .padding(prominence == .kpi ? Theme.Space.cardPadding : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface()
        .contentShape(Theme.Radius.shape(Theme.Radius.card))
        .help(help ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(sentence ?? defaultSentence)
    }

    private var valueRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: prominence == .kpi ? 15 : 12, weight: .semibold))
                    .foregroundStyle(symbolTint ?? Color.secondary)
            }
            Text(value)
                .font(prominence == .kpi ? Theme.Typeface.display : Theme.Typeface.metric)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .contentTransition(.numericText(value: numericValue ?? 0))
            if let delta { delta }
            if placement == .trailing {
                Spacer(minLength: 4)
                accessory
            }
        }
    }

    private var defaultSentence: String {
        [title, value, caption].compactMap { $0 }.joined(separator: ", ")
    }
}

extension StatTile where Accessory == EmptyView {
    init(title: String, value: String, numericValue: Double? = nil, symbol: String? = nil,
         symbolTint: Color? = nil, caption: String? = nil, delta: DeltaBadge? = nil,
         prominence: TileProminence = .kpi, help: String? = nil, accessibilityLabel: String? = nil,
         action: (() -> Void)? = nil) {
        self.init(title: title, value: value, numericValue: numericValue, symbol: symbol, symbolTint: symbolTint,
                  caption: caption, delta: delta, prominence: prominence, accessoryPlacement: .below, help: help,
                  accessibilityLabel: accessibilityLabel, action: action) { EmptyView() }
    }
}

/// Tiles that open something dim slightly while pressed instead of drawing a button bezel.
private struct TilePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.75 : 1)
    }
}

// MARK: - Filter chip

/// A toggle capsule with an optional glyph and project count. On, it takes a
/// light wash of `tint` (ink when nil); the word and glyph always carry the meaning.
struct FilterChip: View {
    private let title: String
    private let count: Int?
    private let symbol: String?
    private let tint: Color?
    @Binding private var isOn: Bool
    private let help: String?

    init(title: String, count: Int? = nil, symbol: String? = nil, tint: Color? = nil,
         isOn: Binding<Bool>, help: String? = nil) {
        self.title = title
        self.count = count
        self.symbol = symbol
        self.tint = tint
        _isOn = isOn
        self.help = help
    }

    private var accent: Color { tint ?? Color.primary }

    var body: some View {
        Button { isOn.toggle() } label: { chip }
            .buttonStyle(.plain)
            .help(help ?? "")
            .accessibilityLabel(title)
            .accessibilityValue(countDescription)
            .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private var chip: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isOn ? accent : Color.secondary)
            }
            Text(title)
                .font(Theme.Typeface.caption.weight(.medium))
            if let count {
                Text(count.formatted())
                    .font(Theme.Typeface.caption.monospacedDigit())
                    .contentTransition(.numericText(value: Double(count)))
            }
        }
        .foregroundStyle(isOn ? Color.primary : Color.secondary)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(isOn ? accent.opacity(0.16) : Theme.Palette.sunken, in: Capsule())
        .overlay { Capsule().strokeBorder(isOn ? accent.opacity(0.45) : Color.clear, lineWidth: 1) }
        .contentShape(Capsule())
    }

    private var countDescription: String {
        guard let count else { return "" }
        return count == 1 ? "1 project" : "\(count) projects"
    }
}

// MARK: - Segmented pills

/// A compact segmented control on a sunken track. The selected pill slides with
/// `matchedGeometryEffect`; only the control animates, not the content it drives.
struct PillSegmented<Value: Hashable>: View {
    @Binding private var selection: Value
    private let options: [(value: Value, title: String)]
    private let label: String
    private let fillsWidth: Bool
    /// Spoken names for terse titles, such as "Last 30 days" for "30D". Missing values read the title.
    private let accessibilityLabels: [Value: String]
    @Namespace private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill

    init(selection: Binding<Value>, options: [(value: Value, title: String)], label: String = "",
         fillsWidth: Bool = false, accessibilityLabels: [Value: String] = [:]) {
        _selection = selection
        self.options = options
        self.label = label
        self.fillsWidth = fillsWidth
        self.accessibilityLabels = accessibilityLabels
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                segment(value: options[index].value, title: options[index].title)
            }
        }
        .padding(2)
        .background(Theme.Palette.sunken, in: Theme.Radius.shape(Theme.Radius.control))
        .animation(Theme.Motion.animation(Theme.Motion.quick, reduceMotion: reduceMotion, still: rendersStill),
                   value: selection)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    private func segment(value: Value, title: String) -> some View {
        let isSelected = value == selection
        return Button { selection = value } label: {
            Text(title)
                .font(Theme.Typeface.caption.weight(.medium))
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .frame(maxWidth: fillsWidth ? CGFloat.infinity : nil, minHeight: 22)
                .background { selectionPill(isSelected) }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabels[value] ?? title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private func selectionPill(_ isSelected: Bool) -> some View {
        if isSelected {
            Theme.Radius.shape(6)
                .fill(Theme.Palette.raised)
                .shadow(color: Theme.Palette.surfaceShadow, radius: 2, x: 0, y: 1)
                .matchedGeometryEffect(id: "selection", in: namespace)
        }
    }
}

// MARK: - Section card

/// A Growth section: title, optional subtitle and trailing controls over content,
/// on a 16pt-radius surface with 14pt padding.
struct SectionCard<Trailing: View, Content: View>: View {
    private let title: String
    private let subtitle: String?
    private let trailing: Trailing
    private let content: Content

    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            header
            content
        }
        .padding(Theme.Space.sectionPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(radius: Theme.Radius.section)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typeface.headline)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: Theme.Space.xs)
            trailing
        }
    }
}

extension SectionCard where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}

// MARK: - Pill

/// A small neutral label on a sunken capsule, such as "Demo", "Shared" or "Dormant".
struct Pill: View, Equatable {
    private let text: String
    private let symbol: String?
    private let tint: Color?

    init(text: String, symbol: String? = nil, tint: Color? = nil) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
    }

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tint ?? Color.secondary)
            }
            Text(text)
                .font(Theme.Typeface.micro)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background(Theme.Palette.sunken, in: Capsule())
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Status glyph

/// The glyph for a live status. It is decorative: callers always pair it with
/// the status word or a sentence, so color is never the only cue.
struct StatusGlyph: View {
    enum Kind: Equatable {
        case needsInput
        case working
        case idle
        case unknown

        init(_ status: LiveStatus) {
            switch status {
            case .waiting: self = .needsInput
            case .working: self = .working
            case .idle: self = .idle
            case .unknown: self = .unknown
            }
        }

        var symbol: String {
            switch self {
            case .needsInput: return "hand.raised.fill"
            case .working: return "circle.fill"
            case .idle: return "circle"
            case .unknown: return "circle.dashed"
            }
        }

        var title: String {
            switch self {
            case .needsInput: return "Needs input"
            case .working: return "Working"
            case .idle: return "Idle"
            case .unknown: return "Unknown"
            }
        }

        /// Glyph and fill color.
        var color: Color {
            switch self {
            case .needsInput: return Theme.Palette.needsInput
            case .working: return Theme.Palette.working
            case .idle: return Color.secondary
            case .unknown: return Theme.Palette.unknown
            }
        }

        /// Text color for the status word; amber and green switch to readable variants.
        var textColor: Color {
            switch self {
            case .needsInput: return Theme.Palette.needsInputText
            case .working: return Theme.Palette.workingText
            case .idle, .unknown: return Color.secondary
            }
        }
    }

    private let kind: Kind
    private let size: CGFloat
    private let animates: Bool
    private let bounceValue: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill
    @State private var bounceTrigger = 0

    /// `animates` allows the working pulse; callers pass it only while the tab is
    /// active, the panel is visible and the scan is fresh. `bounceValue` (the
    /// waiting count) bounces the hand only when it rises.
    init(kind: Kind, size: CGFloat = 11, animates: Bool = false, bounceValue: Int? = nil) {
        self.kind = kind
        self.size = size
        self.animates = animates
        self.bounceValue = bounceValue
    }

    private var motionAllowed: Bool { !reduceMotion && !rendersStill }

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.system(size: kind == .working ? size * 0.72 : size, weight: .semibold))
            .foregroundStyle(kind.color)
            .symbolEffect(.bounce, options: .nonRepeating, value: bounceTrigger)
            .frame(width: size + 2, height: size + 2)
            .background {
                if kind == .working {
                    PulseHalo(color: kind.color, diameter: size * 0.72, active: animates && motionAllowed)
                }
            }
            .onChange(of: bounceValue) { old, new in
                guard motionAllowed, let old, let new, new > old else { return }
                bounceTrigger += 1
            }
            .accessibilityHidden(true)
    }
}

/// A soft expanding halo behind a working dot. It runs only while `active`.
/// The halo animates in Core Animation: a repeating SwiftUI animation redraws
/// the whole panel every display frame, which kept the main thread busy for as
/// long as anything was working.
private struct PulseHalo: View {
    let color: Color
    let diameter: CGFloat
    let active: Bool

    var body: some View {
        if active {
            PulseHaloLayer(color: NSColor(color), diameter: diameter)
                .frame(width: diameter * 2.2, height: diameter * 2.2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct PulseHaloLayer: NSViewRepresentable {
    let color: NSColor
    let diameter: CGFloat

    func makeNSView(context: Context) -> PulseHaloView {
        let view = PulseHaloView()
        view.configure(color: color, diameter: diameter)
        return view
    }

    func updateNSView(_ view: PulseHaloView, context: Context) {
        view.configure(color: color, diameter: diameter)
    }
}

/// One circle layer with a repeating scale-and-fade group, matching the earlier
/// SwiftUI pulse: twice the size and from 0.24 to 0.035 opacity over 1.35 s.
final class PulseHaloView: NSView {
    private let halo = CAShapeLayer()
    private var color = NSColor.clear
    private var diameter: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(halo)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(color: NSColor, diameter: CGFloat) {
        self.color = color
        self.diameter = diameter
        needsLayout = true
        applyColor()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        halo.position = CGPoint(x: bounds.midX, y: bounds.midY)
        halo.path = CGPath(ellipseIn: halo.bounds, transform: nil)
        CATransaction.commit()
        if halo.animation(forKey: "pulse") == nil { startPulse() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColor()
    }

    private func applyColor() {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { resolved = self.color.cgColor }
        halo.fillColor = resolved
    }

    private func startPulse() {
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1
        scale.toValue = 2
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.24
        fade.toValue = 0.035
        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 1.35
        group.autoreverses = true
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = false
        halo.add(group, forKey: "pulse")
    }
}

// MARK: - Profile stack

/// Overlapping profile circles in sources order. Each circle is cut out of the
/// one beneath, so its gap shows the card surface; the ring turns amber with a
/// raised-hand badge for a waiting session, green (with the pulse) for working,
/// dashed gray for unknown. The badge and the dash keep status off hue alone.
struct ProfileStack: View, Equatable {
    struct Member: Identifiable, Equatable {
        let id: String
        let color: Color
        let name: String
        /// The most urgent live status for this profile; nil when it has no live report.
        let status: LiveStatus?

        init(id: String, color: Color, name: String, status: LiveStatus? = nil) {
            self.id = id
            self.color = color
            self.name = name
            self.status = status
        }
    }

    private let members: [Member]
    private let maxVisible: Int
    private let diameter: CGFloat
    private let animates: Bool
    private let ringWidth: CGFloat = 1.5
    private let overlap: CGFloat = 6
    private let badgeDiameter: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill

    init(members: [Member], maxVisible: Int = 4, diameter: CGFloat = 16, animates: Bool = false) {
        self.members = members
        self.maxVisible = max(1, maxVisible)
        self.diameter = diameter
        self.animates = animates
    }

    static func == (lhs: ProfileStack, rhs: ProfileStack) -> Bool {
        lhs.members == rhs.members && lhs.maxVisible == rhs.maxVisible && lhs.diameter == rhs.diameter
            && lhs.animates == rhs.animates
    }

    private var visible: [Member] { Array(members.prefix(maxVisible)) }
    private var overflow: Int { max(0, members.count - maxVisible) }
    private var ringDiameter: CGFloat { diameter + ringWidth * 2 }
    private var avatarSpacing: CGFloat { diameter - overlap - ringDiameter }

    var body: some View {
        HStack(spacing: 4) {
            HStack(spacing: avatarSpacing) {
                ForEach(visible) { (member: Member) in
                    avatar(member)
                }
            }
            .overlay { waitingBadges }
            .compositingGroup()
            if overflow > 0 {
                Text("+\(overflow)")
                    .font(Theme.Typeface.micro.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func avatar(_ member: Member) -> some View {
        ZStack {
            Circle()
                .fill(Color.black)
                .frame(width: ringDiameter, height: ringDiameter)
                .blendMode(.destinationOut)
            // No pulse here: the stack is a blended compositing group, and the
            // live line already pulses for working sessions.
            Circle()
                .fill(member.color)
                .frame(width: diameter, height: diameter)
            ring(member.status)
        }
        .frame(width: ringDiameter, height: ringDiameter)
    }

    @ViewBuilder private func ring(_ status: LiveStatus?) -> some View {
        switch status {
        case .waiting?:
            Circle().strokeBorder(Theme.Palette.needsInput, lineWidth: ringWidth)
        case .working?:
            Circle().strokeBorder(Theme.Palette.working, lineWidth: ringWidth)
        case .unknown?:
            Circle().strokeBorder(Theme.Palette.unknown,
                                  style: StrokeStyle(lineWidth: ringWidth, dash: [2, 1.5]))
        case .idle?, nil:
            EmptyView()
        }
    }

    /// Badges sit in their own layer over the whole row, laid out like the
    /// avatars, so the next avatar's cutout cannot hide a bottom-trailing badge.
    private var waitingBadges: some View {
        HStack(spacing: avatarSpacing) {
            ForEach(visible) { (member: Member) in
                waitingBadge(member.status == .waiting)
                    .frame(width: ringDiameter, height: ringDiameter, alignment: .bottomTrailing)
            }
        }
        .allowsHitTesting(false)
    }

    /// A raised hand in a knockout cut like the avatar gaps, so it shows the card
    /// surface. It uses the readable amber, since the plain fill is faint at 7pt on light cards.
    @ViewBuilder private func waitingBadge(_ isWaiting: Bool) -> some View {
        if isWaiting {
            ZStack {
                Circle()
                    .fill(Color.black)
                    .frame(width: badgeDiameter, height: badgeDiameter)
                    .blendMode(.destinationOut)
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.Palette.needsInputText)
            }
            .frame(width: badgeDiameter, height: badgeDiameter)
        }
    }

    private func describe(_ member: Member) -> String {
        guard let status = member.status else { return member.name }
        return "\(member.name), \(StatusGlyph.Kind(status).title.lowercased())"
    }

    private var helpText: String {
        members.map(describe).joined(separator: "\n")
    }

    private var accessibilityText: String {
        let noun = members.count == 1 ? "Profile" : "Profiles"
        return "\(noun): " + members.map(describe).joined(separator: "; ")
    }
}

// MARK: - Toast

/// A bottom toast in a material capsule. The container owns placement and the
/// transition; `autoDismissAfter` restarts whenever the message changes.
struct Toast: View {
    enum Style: Equatable {
        case error
        case info
    }

    private let message: String
    private let style: Style
    private let autoDismissAfter: Duration?
    private let dismiss: () -> Void
    @Environment(\.rendersStill) private var rendersStill

    init(message: String, style: Style, autoDismissAfter: Duration? = nil, dismiss: @escaping () -> Void) {
        self.message = message
        self.style = style
        self.autoDismissAfter = autoDismissAfter
        self.dismiss = dismiss
    }

    private var shape: RoundedRectangle { Theme.Radius.shape(Theme.Radius.card) }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.xs) {
            Image(systemName: style == .error ? "exclamationmark.triangle.fill" : "info.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(style == .error ? Theme.Palette.error : Color.secondary)
                .accessibilityHidden(true)
            // Errors carry a path and a fix, so they get room to wrap, a tooltip
            // and selectable text; the toast grows in height to fit.
            Text(message)
                .font(Theme.Typeface.body)
                .lineLimit(style == .error ? 6 : 2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(message)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss message")
            .accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, Theme.Space.s)
        .padding(.vertical, 9)
        .background { backdrop }
        .overlay { shape.strokeBorder(Theme.Palette.hairline, lineWidth: 0.5) }
        .shadow(color: Color.black.opacity(0.10), radius: 8, x: 0, y: 3)
        .accessibilityElement(children: .contain)
        .task(id: message) { await autoDismiss() }
    }

    @ViewBuilder private var backdrop: some View {
        if rendersStill {
            shape.fill(Theme.Palette.canvas)
        } else {
            shape.fill(.regularMaterial)
        }
    }

    private func autoDismiss() async {
        guard let delay = autoDismissAfter else { return }
        do { try await Task.sleep(for: delay) } catch { return }
        guard !Task.isCancelled else { return }
        dismiss()
    }
}

// MARK: - Info button

/// An ⓘ button that opens a popover of explanatory text.
struct InfoButton<Content: View>: View {
    private let label: String
    private let content: Content
    @State private var isPresented = false

    init(label: String = "About these numbers", @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        Button { isPresented.toggle() } label: {
            Image(systemName: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                content
            }
            .font(Theme.Typeface.body)
            .padding(Theme.Space.sectionPadding)
            .frame(width: 320, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
