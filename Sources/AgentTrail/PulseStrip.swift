import SwiftUI
import AgentTrailCore

/// Four glanceable tiles above the project list: live sessions now, edits over
/// the last 7 local days, projects touched this week, and the day streak. Every
/// value is read from AppStore's precomputed `pulse` and `liveSummary`.
struct PulseStrip: View {
    static let tileHeight: CGFloat = 74

    private let pulse: PulseSummary
    private let live: LiveSummary
    private let lastLiveScan: Date?
    private let isFirstIndex: Bool
    private let onLive: () -> Void
    private let onOpenGrowth: (StatsPeriod?, GrowthAnchor) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill

    /// `onLive` turns on a live filter; `onOpenGrowth` opens Growth at a period
    /// (nil keeps the current one) and scrolls to an anchor.
    init(pulse: PulseSummary, live: LiveSummary, lastLiveScan: Date?, isFirstIndex: Bool,
         onLive: @escaping () -> Void, onOpenGrowth: @escaping (StatsPeriod?, GrowthAnchor) -> Void) {
        self.pulse = pulse
        self.live = live
        self.lastLiveScan = lastLiveScan
        self.isFirstIndex = isFirstIndex
        self.onLive = onLive
        self.onOpenGrowth = onOpenGrowth
    }

    /// History tiles wait for the first index instead of showing zeros.
    private var isPlaceholder: Bool { isFirstIndex && pulse.projectCount == 0 }
    private var redaction: RedactionReasons { isPlaceholder ? .placeholder : [] }

    private var valueAnimation: Animation? {
        Theme.Motion.animation(Theme.Motion.standard, reduceMotion: reduceMotion, still: rendersStill)
    }

    var body: some View {
        HStack(spacing: Theme.Space.cardGap) {
            liveTile
            editsTile
            projectsTile
            streakTile
        }
        .frame(height: PulseStrip.tileHeight)
        .animation(valueAnimation, value: pulse)
        .animation(valueAnimation, value: live)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pulse")
    }

    // MARK: Live now

    private var liveTile: some View {
        PulseStripTile(sentence: liveSentence, help: liveHelp, action: liveAction) {
            PulseStripLiveFace(live: live, hasScanned: lastLiveScan != nil)
        }
    }

    private var liveAction: (() -> Void)? {
        guard lastLiveScan != nil, live.waiting + live.working > 0 else { return nil }
        return onLive
    }

    private var liveSentence: String {
        guard lastLiveScan != nil else { return "Live now, checking live status." }
        guard live.reportingProjects > 0 else { return "Live now, no live reports." }
        let waiting = live.waiting == 1 ? "1 session needs input" : "\(live.waiting) sessions need input"
        let projects = live.reportingProjects == 1 ? "1 project reporting" : "\(live.reportingProjects) projects reporting"
        return "Live now: \(waiting), \(live.working) working, \(live.idle) idle, \(live.unknown) unknown, \(projects)."
    }

    private var liveHelp: String {
        let base = "Active turns and reported busy sessions, checked every 3 seconds. Expand a project's live details for workspace and report age. A project without a live report is not counted as idle."
        if live.waiting > 0 {
            return "An assistant reported a request needing attention. Check the corresponding assistant to respond.\n"
                + base + "\nClick to show projects that need input."
        }
        if live.working > 0 { return base + "\nClick to show projects with working sessions." }
        return base
    }

    // MARK: Edits · 7 days

    private var editsTile: some View {
        PulseStripTile(sentence: editsSentence, help: editsHelp, action: historyAction { onOpenGrowth(.week, .chart) }) {
            VStack(alignment: .leading, spacing: 3) {
                PulseStripTitle(text: "Edits · 7 days")
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    PulseStripValue(value: pulse.edits7)
                    DeltaBadge(current: pulse.edits7, previous: pulse.hasPrevious7 ? pulse.previous7 : nil)
                    Spacer(minLength: 0)
                }
                Sparkline(values: pulse.daily14, emphasizeLast: 7, height: 15, accessibilityLabel: sparklineLabel)
            }
        }
        .redacted(reason: redaction)
    }

    private var editsSentence: String {
        guard !isPlaceholder else { return "Edits in the last 7 days, loading." }
        let count = pulse.edits7 == 1 ? "1 recorded edit" : "\(pulse.edits7.formatted()) recorded edits"
        guard pulse.hasPrevious7 else { return "Edits in the last 7 days: \(count)." }
        if pulse.previous7 == 0 {
            return pulse.edits7 > 0 ? "Edits in the last 7 days: \(count), none in the 7 days before."
                : "Edits in the last 7 days: none."
        }
        guard let change = PercentChange.accessibility(current: pulse.edits7, previous: pulse.previous7) else {
            return "Edits in the last 7 days: \(count)."
        }
        return "Edits in the last 7 days: \(count), \(change) from the 7 days before."
    }

    private var sparklineLabel: String {
        "Recorded edits per local day over the last 14 days"
    }

    private var editsHelp: String {
        "Recorded edits on local days (05:00–05:00) over the last 7 days, compared with the 7 days before. The faint line is the week before.\nClick to open Growth."
    }

    // MARK: Active projects

    private var projectsTile: some View {
        PulseStripTile(sentence: projectsSentence, help: projectsHelp, action: historyAction { onOpenGrowth(.week, .projects) }) {
            VStack(alignment: .leading, spacing: 3) {
                PulseStripTitle(text: "Active projects")
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    PulseStripValue(value: pulse.activeProjects7)
                    Text("of \(pulse.projectCount.formatted())")
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.trailing, 22)
                PulseStripCaption(text: "edits this week")
            }
            .overlay(alignment: .trailing) {
                PulseStripRatioRing(fraction: activeFraction)
                    .padding(.top, 6)
            }
        }
        .redacted(reason: redaction)
    }

    private var activeFraction: Double {
        guard pulse.projectCount > 0 else { return 0 }
        return min(1, Double(pulse.activeProjects7) / Double(pulse.projectCount))
    }

    private var projectsSentence: String {
        guard !isPlaceholder else { return "Active projects, loading." }
        return "Active projects: \(pulse.activeProjects7) of \(pulse.projectCount) had recorded edits in the last 7 days."
    }

    private var projectsHelp: String {
        "Projects with at least one recorded edit in the last 7 local days, out of every project in saved history.\nClick to see where edits landed."
    }

    // MARK: Day streak

    private var streakTile: some View {
        PulseStripTile(sentence: streakSentence, help: streakHelp, action: historyAction { onOpenGrowth(nil, .calendar) }) {
            VStack(alignment: .leading, spacing: 3) {
                PulseStripTitle(text: "Day streak")
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(flameStyle)
                        .accessibilityHidden(true)
                    Text(PulseStrip.days(pulse.streaks.current))
                        .font(Theme.Typeface.metric)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .contentTransition(.numericText(value: Double(pulse.streaks.current)))
                    Spacer(minLength: 0)
                }
                PulseStripCaption(text: "Longest \(pulse.streaks.longest.formatted())")
            }
        }
        .redacted(reason: redaction)
    }

    /// The trail gradient while a streak runs; plain ink when it is broken.
    private var flameStyle: AnyShapeStyle {
        guard pulse.streaks.current > 0 else { return AnyShapeStyle(Color.secondary) }
        return AnyShapeStyle(LinearGradient(colors: Theme.Palette.Share.underline, startPoint: .bottomLeading, endPoint: .topTrailing))
    }

    private var streakSentence: String {
        guard !isPlaceholder else { return "Day streak, loading." }
        return "Day streak: \(PulseStrip.days(pulse.streaks.current)). Longest \(PulseStrip.days(pulse.streaks.longest))."
    }

    private var streakHelp: String {
        "Local days (05:00–05:00) with at least one recorded edit, in saved history. Today counts once it has an edit; until then yesterday keeps the streak."
    }

    // MARK: Helpers

    /// History tiles do nothing until the first index lands.
    private func historyAction(_ action: @escaping () -> Void) -> (() -> Void)? {
        isPlaceholder ? nil : action
    }

    private static func days(_ count: Int) -> String {
        count == 1 ? "1 day" : "\(count.formatted()) days"
    }
}

// MARK: - Tile frame

/// One surface tile. It is a single accessibility element carrying a full
/// sentence; with an action it becomes a button that lifts slightly on hover.
private struct PulseStripTile<Content: View>: View {
    private let sentence: String
    private let help: String
    private let action: (() -> Void)?
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill
    @State private var isHovered = false

    init(sentence: String, help: String, action: (() -> Void)?, @ViewBuilder content: () -> Content) {
        self.sentence = sentence
        self.help = help
        self.action = action
        self.content = content()
    }

    var body: some View {
        if let action {
            Button(action: action) { face }
                .buttonStyle(PulseStripPressStyle())
                .onHover { hovering in isHovered = hovering }
                .help(help)
                .accessibilityLabel(sentence)
        } else {
            face
                .help(help)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(sentence)
        }
    }

    private var face: some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .topTrailing) { hoverGlyph }
            .cardSurface()
            .overlay { hoverWash }
            .contentShape(Theme.Radius.shape(Theme.Radius.card))
            .animation(Theme.Motion.animation(Theme.Motion.quick, reduceMotion: reduceMotion, still: rendersStill),
                       value: isHovered)
    }

    private var showsHover: Bool { action != nil && isHovered }

    private var hoverGlyph: some View {
        Image(systemName: "arrow.up.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .padding(7)
            .opacity(showsHover ? 1 : 0)
            .accessibilityHidden(true)
    }

    private var hoverWash: some View {
        Theme.Radius.shape(Theme.Radius.card)
            .fill(Color.primary.opacity(showsHover ? 0.035 : 0))
            .allowsHitTesting(false)
    }
}

/// Tiles dim and settle a touch while pressed instead of drawing a bezel.
private struct PulseStripPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

// MARK: - Tile parts

private struct PulseStripTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typeface.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

private struct PulseStripCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.Typeface.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

private struct PulseStripValue: View {
    let value: Int

    var body: some View {
        Text(value.formatted())
            .font(Theme.Typeface.metric)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .contentTransition(.numericText(value: Double(value)))
    }
}

/// How much of the project list was touched this week, as a small ink ring.
private struct PulseStripRatioRing: View {
    let fraction: Double

    var body: some View {
        // A visible full track and flat ends keep a partial ring from reading
        // as a loading spinner.
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.14), lineWidth: 4)
            Circle()
                .trim(from: 0, to: CGFloat(min(1, max(0, fraction))))
                .stroke(Color.primary.opacity(0.82), style: StrokeStyle(lineWidth: 4, lineCap: .butt))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

// MARK: - Live face

/// Needs input and working are separate rows with their own glyph and word, so
/// color is never the only cue. Idle and unknown sessions sit in the bar and caption.
private struct PulseStripLiveFace: View {
    let live: LiveSummary
    let hasScanned: Bool

    var body: some View {
        if hasScanned && live.reportingProjects > 0 {
            reporting
        } else {
            VStack(alignment: .leading, spacing: 3) {
                PulseStripTitle(text: "Live now")
                Text(hasScanned ? "No live reports" : "Checking live status…")
                    .font(Theme.Typeface.body)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private var reporting: some View {
        VStack(alignment: .leading, spacing: 3) {
            countRow(kind: .needsInput, count: live.waiting,
                     word: live.waiting == 1 ? "needs input" : "need input")
            countRow(kind: .working, count: live.working, word: "working")
            PulseStripLiveBar(waiting: live.waiting, working: live.working, idle: live.idle, unknown: live.unknown)
                .frame(height: 4)
            caption
        }
    }

    private func countRow(kind: StatusGlyph.Kind, count: Int, word: String) -> some View {
        HStack(spacing: 4) {
            StatusGlyph(kind: kind, size: 11, bounceValue: kind == .needsInput ? count : nil)
                .grayscale(count == 0 ? 1 : 0)
                .opacity(count == 0 ? 0.6 : 1)
            Text(count.formatted())
                .font(Theme.Typeface.cardMetric)
                .foregroundStyle(count == 0 ? Color.secondary : Color.primary)
                .contentTransition(.numericText(value: Double(count)))
            Text(word)
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(height: 16)
    }

    /// The longest wording that fits the tile.
    private var caption: some View {
        ViewThatFits(in: .horizontal) {
            Text(captionText(projects: true, long: true))
            Text(captionText(projects: true, long: false))
            Text(captionText(projects: false, long: false))
        }
        .font(Theme.Typeface.micro)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// "3 idle · 1 unknown · 2 projects reporting"; unknown is left out at zero.
    private func captionText(projects: Bool, long: Bool) -> String {
        var parts = ["\(live.idle) idle"]
        if live.unknown > 0 { parts.append("\(live.unknown) unknown") }
        if projects {
            let noun = live.reportingProjects == 1 ? "project" : "projects"
            parts.append(long ? "\(live.reportingProjects) \(noun) reporting" : "\(live.reportingProjects) \(noun)")
        }
        return parts.joined(separator: " · ")
    }
}

private struct PulseStripLiveSegment: Identifiable {
    let id: Int
    let kind: StatusGlyph.Kind
    let count: Int
}

/// A 4pt segmented capsule of sessions: waiting, working, idle, then unknown
/// with a dashed outline. Every non-empty segment stays at least 4pt wide.
private struct PulseStripLiveBar: View {
    let waiting: Int
    let working: Int
    let idle: Int
    let unknown: Int
    private let gap: CGFloat = 1.5
    private let minimumWidth: CGFloat = 4

    init(waiting: Int, working: Int, idle: Int, unknown: Int) {
        self.waiting = waiting
        self.working = working
        self.idle = idle
        self.unknown = unknown
    }

    private var segments: [PulseStripLiveSegment] {
        let all = [
            PulseStripLiveSegment(id: 0, kind: .needsInput, count: waiting),
            PulseStripLiveSegment(id: 1, kind: .working, count: working),
            PulseStripLiveSegment(id: 2, kind: .idle, count: idle),
            PulseStripLiveSegment(id: 3, kind: .unknown, count: unknown)
        ]
        return all.filter { $0.count > 0 }
    }

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: gap) {
                ForEach(segments) { (segment: PulseStripLiveSegment) in
                    piece(segment.kind)
                        .frame(width: width(of: segment, in: proxy.size.width))
                }
            }
        }
        .background {
            if segments.isEmpty { Capsule().fill(Theme.Palette.sunken) }
        }
        .accessibilityHidden(true)
    }

    private func width(of segment: PulseStripLiveSegment, in available: CGFloat) -> CGFloat {
        let parts = segments
        let total = parts.reduce(0) { $0 + $1.count }
        guard total > 0 else { return 0 }
        let usable = max(0, available - gap * CGFloat(max(parts.count - 1, 0)))
        let spare = max(0, usable - minimumWidth * CGFloat(parts.count))
        return minimumWidth + spare * CGFloat(segment.count) / CGFloat(total)
    }

    @ViewBuilder private func piece(_ kind: StatusGlyph.Kind) -> some View {
        switch kind {
        case .needsInput:
            Capsule().fill(Theme.Palette.needsInput)
        case .working:
            Capsule().fill(Theme.Palette.working)
        case .idle:
            Capsule().fill(Color.secondary.opacity(0.45))
        case .unknown:
            Capsule().strokeBorder(Theme.Palette.unknown, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
        }
    }
}
