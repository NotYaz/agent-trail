import Accessibility
import AppKit
import SwiftUI
import AgentTrailCore

// MARK: - Details panel

/// The Map window's details panel, beside the map when the window is wide enough.
///
/// A quiet reading pane in two parts. The lens on top keeps one fixed shape and always
/// describes one subject: the project, the item the pointer rests on, or the item a click
/// pinned. When the subject changes its words crossfade and its bars change length; nothing
/// moves. The body under it scrolls: the project's lists while nothing is pinned, the pinned
/// item's deep view once something is. A hover reaches only the lens, and only once the
/// pointer has settled; the body changes on deliberate acts alone.
struct MapDetailPanel: View {
    let map: ProjectMap
    @ObservedObject var hover: MapHoverModel
    @ObservedObject var store: AppStore
    @Binding var focusSourceID: String?
    let animatesLive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    @AppStorage(AppSettings.Key.showSessionTitles) private var showTitles = true
    /// The current map's index, which every hover reuses.
    @State private var cache = MapDetailCache()
    /// The hovered item the lens shows, adopted once the pointer rests on it.
    @State private var previewID: MapHitID?
    /// The pointer is over the panel, so a cleared hover leaves the lens alone.
    @State private var inside = false
    /// Pins made from this panel, so Back can retrace them.
    @State private var trail: [MapDetailStep] = []
    /// Sections opened past their first cap, by section id.
    @State private var opened: Set<String> = []
    /// Narrower than 360pt: shorter labels and no row bars.
    @State private var compact = true
    @State private var copiedToken = 0
    @State private var copied = false
    /// VoiceOver follows a pin, Back or unpin to the lens, since each one replaces the row it was on.
    @AccessibilityFocusState private var lensFocused: Bool

    /// Spelled out: the private state above would otherwise make the memberwise initializer private.
    init(map: ProjectMap, hover: MapHoverModel, store: AppStore, focusSourceID: Binding<String?>, animatesLive: Bool) {
        self.map = map
        _hover = ObservedObject(wrappedValue: hover)
        _store = ObservedObject(wrappedValue: store)
        _focusSourceID = focusSourceID
        self.animatesLive = animatesLive
    }

    var body: some View {
        let index = cache.index(map, calendar: store.activityCalendar, sources: store.sources)
        let shownID: MapHitID? = rendersStill ? hover.emphasized : (hover.selected ?? previewID)
        let hit: MapHit? = shownID.flatMap { index.resolve($0) }
        let isPinned = hover.selected != nil
        let mode: MapDetailMode = isPinned ? .pinned : (hit == nil ? .overview : .preview)
        let live = liveMatches(index)
        let lens = index.lens(hit, live: hit.flatMap { liveSession(of: $0, in: live) }, showTitles: showTitles)
        let actions = makeActions(index)
        VStack(alignment: .leading, spacing: 0) {
            modeLine(lens: lens, mode: mode, hit: hit, index: index)
            MapDetailLensView(lens: lens, chart: index.chart, focusSourceID: focusSourceID, compact: compact,
                              copied: copied, showsAction: mode != .overview, actions: actions)
                .equatable()
                .accessibilityFocused($lensFocused)
                .padding(.horizontal, 14)
            Rectangle().fill(Theme.Palette.hairline).frame(height: 1)
            bodyStack(index: index, pinned: isPinned ? hit : nil, live: live, actions: actions)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .cardSurface(radius: Theme.Radius.section)
        .contentShape(Rectangle())
        .onHover { inside = $0 }
        .onGeometryChange(for: Bool.self) { $0.size.width < 360 } action: { compact = $0 }
        .task(id: MapDetailFollow(hovered: hover.hovered, pinned: hover.selected != nil, inside: inside)) {
            await follow()
        }
        .task(id: copiedToken) {
            guard copied else { return }
            try? await Task.sleep(for: MapDetailTiming.copied)
            guard !Task.isCancelled else { return }
            copied = false
        }
        // "Copied" belongs to the subject that was copied.
        .onChange(of: shownID) { _, _ in
            if copied { copied = false }
        }
        .onChange(of: hover.selected) { _, new in
            opened = []
            if new == nil {
                trail = []
                // Unpinning shows what is under the pointer at once, with no settle.
                previewID = hover.hovered
            }
        }
        .onChange(of: map.projectPath) { _, _ in resetForNewMap() }
        .onChange(of: map.range) { _, _ in resetForNewMap() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Details")
    }

    // MARK: Following the hover

    /// Adopts a new hovered item once the pointer has rested on it, and lets go of a cleared
    /// one only after a linger, and never while the pointer is inside the panel. A sweep
    /// across the map restarts this on every item, so the lens settles once instead of
    /// flickering. Never animated here: the lens animates its own model.
    private func follow() async {
        guard hover.selected == nil, !rendersStill, hover.hovered != previewID else { return }
        if hover.hovered == nil {
            if inside { return }
            try? await Task.sleep(for: MapDetailTiming.linger)
        } else {
            try? await Task.sleep(for: MapDetailTiming.settle)
            // A run the pointer only crossed is still held for the map's veil; it is not
            // adopted unless the pointer comes back to it. The hold ends within 150 ms.
            while !Task.isCancelled, hover.isHolding {
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        guard !Task.isCancelled else { return }
        previewID = hover.hovered
    }

    private func resetForNewMap() {
        trail = []
        previewID = nil
        opened = []
    }

    // MARK: Pins

    private var currentIndex: MapDetailIndex? { cache.current }

    /// Pins `id` from the panel. It never calls `hover.select`, which toggles.
    private func pin(_ id: MapHitID) {
        guard id != hover.selected else { return }
        if let current = hover.selected {
            // A pin made on the map since breaks the trail.
            if trail.last?.to != current { trail = [] }
            trail.append(MapDetailStep(from: current, to: id))
            if trail.count > 32 { trail.removeFirst() }
        } else {
            trail = []
        }
        hover.selected = id
        announce("Pinned \(shortTitle(of: id))")
        lensFocused = true
    }

    private var canGoBack: Bool { hover.selected != nil && trail.last?.to == hover.selected }

    /// Retraces the last pin made from the panel, skipping items the map no longer has.
    private func back() {
        guard canGoBack, var step = trail.popLast() else { return }
        while currentIndex?.resolve(step.from) == nil {
            guard trail.last?.to == step.from, let earlier = trail.popLast() else {
                unpin()
                return
            }
            step = earlier
        }
        hover.selected = step.from
        announce("Back to \(shortTitle(of: step.from))")
        lensFocused = true
    }

    private func unpin() {
        trail = []
        hover.selected = nil
        announce("Unpinned")
        lensFocused = true
    }

    private func shortTitle(of id: MapHitID) -> String {
        guard let index = currentIndex, let hit = index.resolve(id) else { return "" }
        return index.shortTitle(hit)
    }

    /// Only pins, Back and unpins made from the panel are spoken; a hover never is.
    private func announce(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
    }

    // MARK: Live sessions

    /// The live report behind each of the map's live runs, by session key.
    private func liveMatches(_ index: MapDetailIndex) -> [String: LiveAgentSession] {
        var matches: [String: LiveAgentSession] = [:]
        for run in index.liveRuns {
            if let session = liveSession(run) { matches[run.sessionKey] = session }
        }
        return matches
    }

    private func liveSession(_ span: ProjectMap.Span) -> LiveAgentSession? {
        let ids = Set([span.sessionID] + span.otherIDs)
        return store.liveSessions.first { $0.sourceID == span.sourceID && ids.contains($0.sessionID) }
    }

    private func liveSession(of hit: MapHit, in live: [String: LiveAgentSession]) -> LiveAgentSession? {
        if case .live(let span) = hit { return live[span.sessionKey] }
        return nil
    }

    private func makeActions(_ index: MapDetailIndex) -> MapDetailActions {
        MapDetailActions(
            pin: { id in pin(id) },
            focus: { id in focusSourceID = focusSourceID == id ? nil : id },
            jump: { id in
                // Looked up again at tap time: the report may have changed since the row was drawn.
                guard case .run(let key, _) = id, let run = index.runsBySession[key]?.last,
                      let session = liveSession(run) else { return }
                store.jump(session)
            },
            open: { url in NSWorkspace.shared.open(url) },
            copy: { value in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
                copiedToken += 1
            },
            showMore: { id in
                withAnimation(motion(MapMotion.crossfade)) { _ = opened.insert(id) }
            })
    }

    // MARK: Mode line

    private func modeLine(lens: MapDetailLens, mode: MapDetailMode, hit: MapHit?, index: MapDetailIndex) -> some View {
        let back: String? = canGoBack
            ? (trail.last.flatMap { index.resolve($0.from) }.map { index.shortTitle($0) } ?? "Back") : nil
        let key = MapDetailModeKey(mode: mode, kind: lens.kind.string, back: back)
        return HStack(spacing: 6) {
            if mode == .pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            lens.kind.text
                .font(Theme.Typeface.micro)
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .contentTransition(.opacity)
                .layoutPriority(-1)
            Spacer(minLength: 6)
            modeButtons(mode: mode, hit: hit, back: back)
        }
        .frame(height: 18)
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .animation(motion(MapMotion.crossfade), value: key)
    }

    @ViewBuilder
    private func modeButtons(mode: MapDetailMode, hit: MapHit?, back: String?) -> some View {
        switch mode {
        case .overview:
            EmptyView()
        case .preview:
            if let hit {
                pinButton(hit.id)
                    .transition(.opacity)
            }
        case .pinned:
            HStack(spacing: 4) {
                if let back {
                    backButton(back)
                        .transition(.opacity)
                }
                unpinButton
            }
            .transition(.opacity)
        }
    }

    /// How a Tree family, which opens on click, gets pinned.
    private func pinButton(_ id: MapHitID) -> some View {
        Button { pin(id) } label: {
            Label("Pin", systemImage: "pin")
                .labelStyle(.titleAndIcon)
                .font(Theme.Typeface.micro)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(Theme.Palette.sunken, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Pin these details. Clicking the item on the map pins it too")
        .accessibilityLabel("Pin details")
    }

    /// The previous pin's short title, capped by characters so the capsule hugs it: about
    /// 150pt in a compact panel and 190pt in a roomy one.
    private func backButton(_ title: String) -> some View {
        Button(action: back) {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 8, weight: .semibold))
                Text(MapDetailText.clipped(title, to: compact ? 22 : 28))
                    .font(Theme.Typeface.micro.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Theme.Palette.sunken, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .keyboardShortcut("[", modifiers: .command)
        .help("Back to \(title) (⌘[)")
        .accessibilityLabel("Back to \(title)")
    }

    /// Exists only while something is pinned, so Esc is captured only then.
    private var unpinButton: some View {
        Button(action: unpin) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .background(Theme.Palette.sunken, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .keyboardShortcut(.cancelAction)
        .help("Unpin (Esc)")
        .accessibilityLabel("Unpin")
    }

    // MARK: Body

    /// One body at a time, swapped with a dip: the old one fades out quickly and the new
    /// one fades in just after, so the two never read as a double image. Its identity
    /// depends only on the pin, the range and the project, so a map rebuild keeps the
    /// scroll position.
    private func bodyStack(index: MapDetailIndex, pinned: MapHit?, live: [String: LiveAgentSession],
                           actions: MapDetailActions) -> some View {
        let pinnedID: MapHitID? = pinned == nil ? nil : hover.selected
        let key: MapDetailBodyKey = pinnedID.map { MapDetailBodyKey.pinned($0) } ?? .overview(map.range, map.projectPath)
        let ticking = animatesLive && !rendersStill
        let empty = emptyText
        return ZStack(alignment: .top) {
            if let pinned, let pinnedID {
                MapDetailBody(live: nil, nowBox: nowBox(pinned, live: live, index: index),
                              blocks: index.deepBlocks(pinned), emptyText: nil, current: pinnedID,
                              focusSourceID: focusSourceID, compact: compact, opened: opened, colorScheme: colorScheme,
                              contrast: contrast, ticking: ticking, now: store.now, actions: actions)
                    .equatable()
                    .id(key)
                    .transition(dip)
            } else {
                MapDetailBody(live: empty == nil ? liveSection(index, live: live) : nil, nowBox: nil,
                              blocks: empty == nil ? index.overviewBlocks() : [], emptyText: empty, current: nil,
                              focusSourceID: focusSourceID, compact: compact, opened: opened, colorScheme: colorScheme,
                              contrast: contrast, ticking: ticking, now: store.now, actions: actions)
                    .equatable()
                    .id(key)
                    .transition(dip)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .clipped()
        .animation(motion(MapMotion.crossfade), value: key)
    }

    private var dip: AnyTransition {
        guard !reduceMotion, !rendersStill else { return .identity }
        return .asymmetric(insertion: AnyTransition.opacity.animation(.easeInOut(duration: 0.16).delay(0.06)),
                           removal: AnyTransition.opacity.animation(.easeOut(duration: 0.10)))
    }

    private var emptyText: String? {
        guard map.axis.segments.isEmpty else { return nil }
        return "Nothing recorded \(map.range == .today ? "today" : "in the \(map.range.title.lowercased())")"
    }

    /// The overview's live sessions, built from the store on every pass and never memoized:
    /// their titles are conversation text.
    private func liveSection(_ index: MapDetailIndex, live: [String: LiveAgentSession]) -> MapDetailLiveSection? {
        guard !index.liveRuns.isEmpty else { return nil }
        let rows = index.liveRuns.prefix(8).map { run -> MapDetailLiveRow in
            let session = live[run.sessionKey]
            let status = MapDetailLive.of(run.live) ?? .working
            let title = session.flatMap { SessionLabel.title($0, showTitles: showTitles, limit: 80) }
                ?? index.name[run.sourceID] ?? ""
            let edits = index.sessions[run.sessionKey]?.edits ?? run.editCount
            let row = MapDetailRow(id: "live:" + run.sessionKey, lead: .status(status), title: title, detail: "",
                                   value: edits.formatted(), barValue: edits, barColor: index.color[run.sourceID],
                                   target: .pin(.run(run.sessionKey, run.index)),
                                   jump: session == nil ? nil : .run(run.sessionKey, run.index))
            return MapDetailLiveRow(row: row, word: status.word, since: session?.details.stateSince,
                                    lane: index.title(run.laneID))
        }
        return MapDetailLiveSection(rows: Array(rows), count: index.liveRuns.count)
    }

    /// A pinned live session's report: what it asks, how long it has been in its state, its pills.
    private func nowBox(_ hit: MapHit, live: [String: LiveAgentSession], index: MapDetailIndex) -> MapDetailNowBox? {
        guard case .live(let span) = hit, let session = live[span.sessionKey] else { return nil }
        var pills: [String] = []
        if session.details.startedInTerminal { pills.append("Terminal") }
        if let branch = SessionLabel.branch(session), branch != index.title(span.laneID) {
            pills.append(MapDetailText.clipped(branch, to: 28))
        }
        return MapDetailNowBox(title: SessionLabel.title(session, showTitles: showTitles, limit: 160),
                               asks: SessionLabel.needsAction(session, showTitles: showTitles),
                               state: SessionLabel.state(session, word: StatusGlyph.Kind(session.status).title),
                               since: session.details.stateSince, pills: pills,
                               pullRequests: Array(session.details.pullRequests.prefix(3)))
    }

    private func motion(_ base: Animation) -> Animation? {
        MapMotion.animation(base, reduceMotion: reduceMotion, still: rendersStill)
    }
}

// MARK: - State

/// One pin made from the panel, so Back can return to where it came from.
private struct MapDetailStep: Equatable {
    let from: MapHitID
    let to: MapHitID
}

/// What restarts the hover follower: a new hovered item, a pin, the pointer entering or leaving.
private struct MapDetailFollow: Equatable {
    let hovered: MapHitID?
    let pinned: Bool
    let inside: Bool
}

private enum MapDetailTiming {
    /// How long the pointer rests on an item before the lens shows it.
    static let settle: Duration = .milliseconds(90)
    /// How long a cleared hover waits before the lens fades back to the project.
    static let linger: Duration = .milliseconds(400)
    static let copied: Duration = .milliseconds(1500)
}

private enum MapDetailMode: Hashable {
    case overview
    case preview
    case pinned
}

/// What the mode line crossfades on: the state, the kind label and the Back target.
private struct MapDetailModeKey: Hashable {
    let mode: MapDetailMode
    let kind: String
    let back: String?
}

private enum MapDetailBodyKey: Hashable {
    case overview(MapRange, String)
    case pinned(MapHitID)
}

/// What the panel's rows and buttons do. Closures, so left out of every view's `==`.
private struct MapDetailActions {
    let pin: (MapHitID) -> Void
    let focus: (String) -> Void
    let jump: (MapHitID) -> Void
    let open: (URL) -> Void
    let copy: (String) -> Void
    let showMore: (String) -> Void
}

/// A live status as the map records it.
private enum MapDetailLive: Hashable {
    case working
    case waiting

    static func of(_ raw: String?) -> MapDetailLive? {
        guard let raw else { return nil }
        return raw == LiveStatus.waiting.rawValue ? .waiting : .working
    }

    var kind: StatusGlyph.Kind { self == .waiting ? .needsInput : .working }
    var word: String { kind.title }
    var ring: Color { self == .waiting ? Theme.Palette.needsInput : Theme.Palette.working }
}

/// Words with live status words in their status color, joined into one Text.
private struct MapDetailWords: Equatable {
    struct Part: Equatable {
        let text: String
        let live: MapDetailLive?
    }

    var parts: [Part]

    init(_ text: String, live: MapDetailLive? = nil) {
        parts = text.isEmpty ? [] : [Part(text: text, live: live)]
    }

    static func + (lhs: MapDetailWords, rhs: MapDetailWords) -> MapDetailWords {
        var joined = lhs
        joined.parts += rhs.parts
        return joined
    }

    var string: String { parts.map(\.text).joined() }

    var text: Text {
        var result = Text(verbatim: "")
        for part in parts {
            if let live = part.live {
                result = result + Text(part.text).foregroundColor(live.kind.textColor)
            } else {
                result = result + Text(part.text)
            }
        }
        return result
    }
}

private enum MapDetailText {
    /// `part` of `whole` in whole percent; nil when there is no whole.
    static func percent(_ part: Int, _ whole: Int) -> Int? {
        guard whole != 0 else { return nil }
        return Int((Double(part) / Double(whole) * 100).rounded())
    }

    /// At most `limit` characters, cut in the middle so both ends stay readable.
    static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit, limit > 3 else { return text }
        return "\(text.prefix((limit - 1) / 2 + (limit - 1) % 2))…\(text.suffix((limit - 1) / 2))"
    }

    /// The first `shown` names, then "+N" for the rest.
    static func list(_ names: [String], shown: Int) -> String? {
        guard !names.isEmpty else { return nil }
        let head = names.prefix(shown).joined(separator: ", ")
        return names.count > shown ? head + " +\(names.count - shown)" : head
    }

    /// A session's branches in order. A path too long for a fact row keeps its first hop and
    /// its last, the branch the session ended on or is on now, and counts the rest. Both ends
    /// are clipped short, so the row's own middle truncation never cuts the count.
    static func path(_ hops: [String]) -> String {
        let joined = hops.joined(separator: " → ")
        guard hops.count > 3, joined.count > 36, let first = hops.first, let last = hops.last else { return joined }
        return "\(clipped(first, to: 20)) → \(hops.count - 2) more → \(clipped(last, to: 20))"
    }

    /// Names that appear more than once, which their rows then tell apart.
    static func repeated(_ names: [String]) -> Set<String> {
        var seen = Set<String>()
        var twice = Set<String>()
        for name in names {
            if !seen.insert(name).inserted { twice.insert(name) }
        }
        return twice
    }

    static func runs(_ count: Int) -> String { GrowthText.count(count, "run", "runs") }
    static func commits(_ count: Int) -> String { GrowthText.count(count, "commit", "commits") }
}

private extension Array where Element == MapDetailBlock {
    mutating func add(_ block: MapDetailBlock?) {
        if let block { append(block) }
    }
}

// MARK: - Lens

/// Everything the lens shows for one subject. Every kind fills every slot, so the lens
/// keeps its shape: three figures, four facts, a Days chart and a Who bar.
private struct MapDetailLens: Equatable {
    var kind: MapDetailWords
    var glyph: MapDetailGlyph
    var title: String
    var titleMiddle: Bool
    var titleItalic: Bool
    var subtitle: MapDetailWords
    var figures: [MapDetailFigure]
    var days: MapDetailDays
    var who: MapDetailWho
    var facts: [MapDetailFact]
    var action: MapDetailLensAction?

    init(kind: MapDetailWords, glyph: MapDetailGlyph, title: String, middle: Bool = false, italic: Bool = false,
         subtitle: MapDetailWords, figures: [MapDetailFigure], days: MapDetailDays, who: MapDetailWho,
         facts: [MapDetailFact], action: MapDetailLensAction? = nil) {
        self.kind = kind
        self.glyph = glyph
        self.title = title
        titleMiddle = middle
        titleItalic = italic
        self.subtitle = subtitle
        self.figures = Array((figures + Array(repeating: MapDetailFigure(label: "", value: nil), count: 3)).prefix(3))
        self.days = days
        self.who = who
        self.facts = Array((facts + Array(repeating: MapDetailFact(label: "", value: nil), count: 4)).prefix(4))
        self.action = action
    }
}

private enum MapDetailGlyph: Hashable {
    case symbol(String, primary: Bool)
    case profile(Color, live: MapDetailLive?)
    case cloud(Color)
    /// A commit's ring; a bead's is bolder, with a center dot when it landed a drawn branch.
    case ring(bead: Bool, landed: Bool)
    case capsule
}

private struct MapDetailFigure: Equatable {
    let label: String
    /// Nil reads "—".
    let value: String?
}

private struct MapDetailFact: Equatable {
    let label: String
    /// Nil reads "—".
    let value: String?
    var middle = false
    var mono = false
}

/// The Days chart's per-subject part, by column index.
private struct MapDetailDays: Equatable {
    var ink: [Int]
    var ticks: Set<Int>
    var band: ClosedRange<Int>?
    var right: String
}

/// The Days chart's fixed part: the range's columns and the project's edits as the ghost.
private struct MapDetailChart: Equatable {
    let caption: String
    let labels: [String?]
    let ghost: [Int]
    let maximum: Int

    var count: Int { labels.count }

    func label(_ column: Int) -> String? { labels.indices.contains(column) ? labels[column] : nil }
}

private struct MapDetailWhoSegment: Equatable, Identifiable {
    let id: String
    let name: String
    let color: Color
    let direct: Int
    let delegated: Int

    var total: Int { direct + delegated }
}

/// Edits by profile, in the same profile order for every subject, so a new subject only
/// changes lengths.
private struct MapDetailWho: Equatable {
    let segments: [MapDetailWhoSegment]
    let left: String
    var right: String
}

private enum MapDetailLensAction: Equatable {
    case jump(MapHitID)
    case open(URL)
    case copy(String, help: String)
}

/// The lens: a header, three figures, the Days chart, the Who bar and four facts, each in a
/// fixed height. A new subject crossfades the words that changed and changes bar lengths in
/// the same transaction; nothing slides or resizes.
private struct MapDetailLensView: View, Equatable {
    let lens: MapDetailLens
    let chart: MapDetailChart
    let focusSourceID: String?
    let compact: Bool
    let copied: Bool
    /// Preview and pinned subjects offer their action; the project has none.
    let showsAction: Bool
    let actions: MapDetailActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill
    @Environment(\.colorSchemeContrast) private var contrast

    static func == (lhs: MapDetailLensView, rhs: MapDetailLensView) -> Bool {
        guard lhs.lens == rhs.lens, lhs.chart == rhs.chart, lhs.focusSourceID == rhs.focusSourceID else { return false }
        return lhs.compact == rhs.compact && lhs.copied == rhs.copied && lhs.showsAction == rhs.showsAction
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .frame(height: 36)
                .padding(.top, 10)
            figures
                .padding(.top, 12)
            days
                .padding(.top, 12)
            who
                .padding(.top, 10)
            facts
                .padding(.top, 12)
        }
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: 305, alignment: .top)
        .animation(motion(MapMotion.crossfade), value: lens)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(lens.title), \(lens.subtitle.string)")
        .accessibilityValue(accessibilityValue)
        .accessibilityActions {
            if showsAction, let action = lens.action {
                Button(actionTitle) { perform(action) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                MapDetailGlyphView(glyph: lens.glyph)
                    .id(lens.glyph)
                    .transition(.opacity)
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(lens.title)
                    .font(Theme.Typeface.headline)
                    .italic(lens.titleItalic)
                    .lineLimit(1)
                    .truncationMode(lens.titleMiddle ? .middle : .tail)
                    .contentTransition(.opacity)
                lens.subtitle.text
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ZStack(alignment: .trailing) {
                if showsAction, let action = lens.action {
                    actionButton(action)
                        .transition(.opacity)
                }
            }
        }
    }

    private func actionButton(_ action: MapDetailLensAction) -> some View {
        Button { perform(action) } label: {
            Text(actionTitle)
                .font(Theme.Typeface.caption.weight(.medium))
                .contentTransition(.opacity)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Theme.Palette.raised, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help(action))
        .animation(motion(MapMotion.crossfade), value: copied)
    }

    private var actionTitle: String {
        switch lens.action {
        case .jump?: return "Jump"
        case .open?: return "Open"
        case .copy?: return copied ? "Copied" : "Copy"
        case nil: return ""
        }
    }

    private func help(_ action: MapDetailLensAction) -> String {
        switch action {
        case .jump: return "Open this session"
        case .open: return "Open this cloud session on claude.ai"
        case .copy(_, let help): return help
        }
    }

    private func perform(_ action: MapDetailLensAction) {
        switch action {
        case .jump(let id): actions.jump(id)
        case .open(let url): actions.open(url)
        case .copy(let value, _): actions.copy(value)
        }
    }

    // MARK: Figures

    /// Card-sized numbers, not metric-sized: large numbers flipping at the edge of view are
    /// the loudest thing a sweep produces.
    private var figures: some View {
        HStack(spacing: 0) {
            figureCell(lens.figures[0])
            divider
            figureCell(lens.figures[1])
            divider
            figureCell(lens.figures[2])
        }
        .frame(height: 40)
        .sunkenField(radius: Theme.Radius.control)
    }

    private var divider: some View {
        Rectangle().fill(Theme.Palette.hairline).frame(width: 1, height: 22)
    }

    private func figureCell(_ figure: MapDetailFigure) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(figure.value ?? "—")
                .font(Theme.Typeface.cardMetric)
                .foregroundStyle(figure.value == nil ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.opacity)
            Text(figure.label)
                .font(Theme.Typeface.micro)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Days

    private var days: some View {
        let count = chart.count
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(chart.caption)
                    .font(Theme.Typeface.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(lens.days.right)
                    .font(Theme.Typeface.micro.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .frame(height: 14)
            bars(count)
                .frame(height: 28)
            tickLabels(count)
                .frame(height: 12)
        }
        .frame(height: 62)
        .accessibilityHidden(true)
    }

    /// One column per hour or day, each keeping its identity, so a new subject changes
    /// heights instead of swapping views.
    private func bars(_ count: Int) -> some View {
        HStack(alignment: .bottom, spacing: count > 14 ? 1 : 3) {
            ForEach(0..<count, id: \.self) { column in
                bar(column)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.10)).frame(height: 1)
        }
    }

    private func bar(_ column: Int) -> some View {
        let inBand = lens.days.band?.contains(column) ?? false
        let ghost = Color.primary.opacity(contrast == .increased ? 0.16 : 0.08)
        return ZStack(alignment: .bottom) {
            Rectangle().fill(Color.primary.opacity(0.06))
                .opacity(inBand ? 1 : 0)
            RoundedRectangle(cornerRadius: 1.5).fill(ghost)
                .frame(height: height(value(chart.ghost, column)))
            RoundedRectangle(cornerRadius: 1.5).fill(Theme.Palette.sparkline)
                .frame(height: height(value(lens.days.ink, column)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .overlay(alignment: .top) {
            Circle().strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.25)
                .frame(width: 5, height: 5)
                .opacity(lens.days.ticks.contains(column) ? 1 : 0)
        }
    }

    private func value(_ values: [Int], _ column: Int) -> Int {
        values.indices.contains(column) ? values[column] : 0
    }

    private func height(_ value: Int) -> CGFloat {
        value == 0 ? 0 : max(2, 28 * CGFloat(value) / CGFloat(max(1, chart.maximum)))
    }

    private func tickLabels(_ count: Int) -> some View {
        HStack(spacing: count > 14 ? 1 : 3) {
            ForEach(0..<count, id: \.self) { column in
                Color.clear
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: tickAlignment(column, count: count)) {
                        if let label = chart.label(column) {
                            Text(label)
                                .font(Theme.Typeface.micro)
                                .foregroundStyle(column == count - 1 ? Color.primary : Color.secondary)
                                .fixedSize()
                        }
                    }
            }
        }
    }

    private func tickAlignment(_ column: Int, count: Int) -> Alignment {
        if column == 0 { return .topLeading }
        return column == count - 1 ? .topTrailing : .top
    }

    // MARK: Who

    private var who: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                whoBar(width: proxy.size.width)
            }
            .frame(height: 6)
            HStack(spacing: 6) {
                Text(lens.who.left)
                    .font(Theme.Typeface.micro)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Spacer(minLength: 6)
                Text(lens.who.right)
                    .font(Theme.Typeface.micro.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .frame(height: 14)
        }
        .frame(height: 26)
    }

    /// Every profile keeps its segment, at zero width when it made no edits here, so the bar
    /// changes lengths and never swaps views. The sunken track shows through when it is empty.
    private func whoBar(width: CGFloat) -> some View {
        let segments = lens.who.segments
        let filled = segments.filter { $0.total > 0 }.count
        let lastFilled = segments.lastIndex { $0.total > 0 }
        let total = segments.reduce(0) { $0 + $1.total }
        let gaps = CGFloat(max(0, filled - 1)) * 1.5
        let unit = total > 0 ? max(0, width - gaps) / CGFloat(total) : 0
        return HStack(spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { pair in
                whoSegment(pair.element, unit: unit,
                           gap: pair.element.total > 0 && pair.offset != lastFilled ? 1.5 : 0)
            }
            Spacer(minLength: 0)
        }
        .frame(width: width, height: 6)
        .background(Theme.Palette.sunken)
        .clipShape(Capsule())
    }

    private func whoSegment(_ segment: MapDetailWhoSegment, unit: CGFloat, gap: CGFloat) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(segment.color.opacity(0.9))
                .frame(width: unit * CGFloat(segment.direct))
            Rectangle().fill(segment.color.opacity(0.45))
                .frame(width: unit * CGFloat(segment.delegated))
                .overlay { MapDetailHatch(color: segment.color) }
                .clipped()
            Color.clear
                .frame(width: gap)
        }
        .opacity(focusSourceID == nil || focusSourceID == segment.id ? 1 : 0.3)
        .help("\(segment.name): \(segment.direct.formatted()) direct, \(segment.delegated.formatted()) by subagents")
    }

    // MARK: Facts

    private var facts: some View {
        VStack(alignment: .leading, spacing: 3) {
            factRow(lens.facts[0])
            factRow(lens.facts[1])
            factRow(lens.facts[2])
            factRow(lens.facts[3])
        }
        .frame(height: 73, alignment: .top)
    }

    private func factRow(_ fact: MapDetailFact) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(fact.label)
                .font(Theme.Typeface.micro)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: compact ? 56 : 64, alignment: .leading)
                .contentTransition(.opacity)
            Text(fact.value ?? "—")
                .font(Theme.Typeface.caption)
                .foregroundStyle(fact.value == nil ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.primary)
                .lineLimit(1)
                .truncationMode(fact.middle ? .middle : .tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentTransition(.opacity)
        }
        .frame(height: 16)
    }

    // MARK: Accessibility

    private var accessibilityValue: String {
        var parts = [lens.kind.string]
        parts += lens.figures.filter { !$0.label.isEmpty }.map { "\($0.label) \($0.value ?? "none")" }
        parts += [chart.caption, lens.days.right, lens.who.left, lens.who.right]
        parts += lens.facts.filter { !$0.label.isEmpty }.map { "\($0.label) \($0.value ?? "none")" }
        return parts.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    private func motion(_ base: Animation) -> Animation? {
        MapMotion.animation(base, reduceMotion: reduceMotion, still: rendersStill)
    }
}

/// The lens's glyph in its fixed 20pt box.
private struct MapDetailGlyphView: View {
    let glyph: MapDetailGlyph

    var body: some View {
        switch glyph {
        case .symbol(let name, let primary):
            Image(systemName: name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(primary ? Color.primary : Color.secondary)
        case .profile(let color, let live):
            ZStack {
                if let live {
                    // Static: the panel never pulses.
                    Circle().strokeBorder(live.ring, lineWidth: 1.5).frame(width: 13, height: 13)
                }
                Circle().fill(color).frame(width: 8, height: 8)
            }
        case .cloud(let color):
            Image(systemName: "cloud.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
        case .ring(let bead, let landed):
            ZStack {
                Circle().strokeBorder(Color.primary.opacity(0.8), lineWidth: bead ? 1.75 : 1.5)
                    .frame(width: 10, height: 10)
                if landed {
                    Circle().fill(Color.primary.opacity(0.8)).frame(width: 3.2, height: 3.2)
                }
            }
        case .capsule:
            Capsule().strokeBorder(Color.primary.opacity(0.8), lineWidth: 1.5)
                .frame(width: 18, height: 10)
        }
    }
}

/// Diagonal 1pt strokes every 3pt in a profile color: edits subagents made.
private struct MapDetailHatch: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let ink = color.flattened(in: context.environment)
            var hatch = Path()
            var x = -size.height
            while x < size.width {
                hatch.move(to: CGPoint(x: x, y: size.height))
                hatch.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 3
            }
            context.stroke(hatch, with: .color(ink), lineWidth: 1)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Body

/// One block of the body, top to bottom.
private enum MapDetailBlock: Equatable {
    case section(MapDetailSection)
    case buttons([MapDetailButton])
    case message(subject: String, sha: String, with: String?)
    case strip(MapDetailStrip)
    case details([MapDetailFact])
    case hours(MapDetailHours)
    case path(String, note: String)
}

/// A titled list: `first` rows at once, up to `hard` after "Show more", the rest counted.
private struct MapDetailSection: Equatable {
    let id: String
    let title: String
    let count: Int
    let trailing: String?
    let rows: [MapDetailRow]
    let first: Int
    let hard: Int
    let note: String?
    /// The largest row value, which fills a row bar.
    let maximum: Int
}

private struct MapDetailRow: Equatable, Identifiable {
    var id: String
    var lead: MapDetailLead
    var title: String
    var italic = false
    var middle = false
    var detail: String
    var value: String? = nil
    var mono = false
    var barValue: Int? = nil
    var barColor: Color? = nil
    var target: MapDetailTarget
    /// A live session's Jump, beside the row rather than inside it.
    var jump: MapHitID? = nil

    var pins: Bool {
        if case .pin = target { return true }
        return false
    }

    func isCurrent(_ current: MapHitID?) -> Bool {
        if case .pin(let id) = target { return id == current }
        return false
    }

    func isFocused(_ focusSourceID: String?) -> Bool {
        if case .focus(let id) = target { return id == focusSourceID }
        return false
    }
}

private enum MapDetailLead: Equatable {
    case dot(Color)
    case symbol(String, dim: Bool)
    case ring
    case status(MapDetailLive)
    case cloud(Color)
}

/// What a row click does: pin an item, focus a profile, or nothing for a plain text row.
private enum MapDetailTarget: Equatable {
    case pin(MapHitID)
    case focus(String)
    case text
}

private enum MapDetailButton: Equatable {
    case focus(id: String, name: String)
    case open(URL, title: String)
}

/// The overview's live sessions. Their ages come from the clock when the rows draw.
private struct MapDetailLiveSection: Equatable {
    let rows: [MapDetailLiveRow]
    let count: Int

    func section(now: Date) -> MapDetailSection {
        let filled = rows.map { live -> MapDetailRow in
            var row = live.row
            let age = ElapsedFormat.compact(since: live.since, now: now).map { " \($0)" } ?? ""
            row.detail = "\(live.word)\(age) · on \(live.lane)"
            return row
        }
        return MapDetailSection(id: "live", title: "Live now", count: count, trailing: nil, rows: filled, first: 8,
                                hard: 8, note: nil, maximum: filled.compactMap(\.barValue).max() ?? 0)
    }
}

private struct MapDetailLiveRow: Equatable {
    let row: MapDetailRow
    let word: String
    let since: Date?
    let lane: String
}

/// A pinned live session's report. Conversation text, so it is built on every pass and
/// never memoized.
private struct MapDetailNowBox: Equatable {
    let title: String?
    let asks: String?
    let state: String
    let since: Date?
    let pills: [String]
    let pullRequests: [LivePullRequest]
}

/// Edits by hour of the activity day, from the rollover hour.
private struct MapDetailHours: Equatable {
    let values: [Int]
    let labels: [String]
    let trailing: String
    let accessibilityValue: String
}

/// Runs over time, one row per branch or session, on the map's folded axis.
private struct MapDetailStrip: Equatable {
    struct Row: Equatable {
        let label: String
        let dim: Bool
    }

    /// A run as fractions of the strip's width.
    struct Run: Equatable {
        let row: Int
        let from: Double
        let to: Double
        let color: Color
        let hatched: Bool
        let cloud: Bool
        let current: Bool
        let dim: Bool
    }

    struct Link: Equatable {
        let fromRow: Int
        let fromX: Double
        let toRow: Int
        let toX: Double
        let color: Color
    }

    let title: String
    let rows: [Row]
    let runs: [Run]
    let links: [Link]
    /// A live session's run with its latest edit, whose thread runs on to the right edge.
    let thread: Run?
    let folds: [ClosedRange<Double>]
    let accessibilityValue: String
}

/// The scrolling body: the overview's lists, or the pinned item's deep view. Its inputs never
/// depend on the hover, so a hover never redraws it.
private struct MapDetailBody: View, Equatable {
    let live: MapDetailLiveSection?
    let nowBox: MapDetailNowBox?
    let blocks: [MapDetailBlock]
    let emptyText: String?
    let current: MapHitID?
    let focusSourceID: String?
    let compact: Bool
    let opened: Set<String>
    let colorScheme: ColorScheme
    let contrast: ColorSchemeContrast
    /// Live ages tick once a minute.
    let ticking: Bool
    /// The clock for live ages while nothing ticks; left out of `==`.
    let now: Date
    let actions: MapDetailActions

    static func == (lhs: MapDetailBody, rhs: MapDetailBody) -> Bool {
        // Separate conditions keep the type checker quick.
        guard lhs.blocks == rhs.blocks, lhs.live == rhs.live, lhs.nowBox == rhs.nowBox else { return false }
        guard lhs.emptyText == rhs.emptyText, lhs.current == rhs.current, lhs.focusSourceID == rhs.focusSourceID else {
            return false
        }
        guard lhs.compact == rhs.compact, lhs.opened == rhs.opened, lhs.ticking == rhs.ticking else { return false }
        return lhs.colorScheme == rhs.colorScheme && lhs.contrast == rhs.contrast
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                if let emptyText {
                    Text(emptyText)
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(.secondary)
                }
                if let live {
                    clocked { now in sectionView(live.section(now: now)) }
                }
                if let nowBox {
                    clocked { now in MapDetailNowView(box: nowBox, now: now, actions: actions) }
                }
                ForEach(Array(blocks.enumerated()), id: \.offset) { pair in
                    block(pair.element)
                }
            }
            .padding(.top, 12)
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }

    /// Live content under a once-a-minute timeline while live effects run, else at `now`.
    @ViewBuilder
    private func clocked<Content: View>(@ViewBuilder _ content: @escaping (Date) -> Content) -> some View {
        if ticking {
            TimelineView(.everyMinute) { context in content(context.date) }
        } else {
            content(now)
        }
    }

    private func sectionView(_ section: MapDetailSection) -> some View {
        MapDetailSectionView(section: section, current: current, focusSourceID: focusSourceID, compact: compact,
                             isOpened: opened.contains(section.id), actions: actions)
    }

    @ViewBuilder
    private func block(_ block: MapDetailBlock) -> some View {
        switch block {
        case .section(let section):
            sectionView(section)
        case .buttons(let buttons):
            buttonRow(buttons)
        case .message(let subject, let sha, let with):
            message(subject: subject, sha: sha, with: with)
        case .strip(let strip):
            MapDetailStripView(strip: strip, compact: compact)
        case .details(let facts):
            details(facts)
        case .hours(let hours):
            MapDetailHoursView(hours: hours)
        case .path(let path, let note):
            pathBlock(path, note: note)
        }
    }

    private func buttonRow(_ buttons: [MapDetailButton]) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(buttons.enumerated()), id: \.offset) { pair in
                capsuleButton(pair.element)
            }
            Spacer(minLength: 0)
        }
    }

    private func capsuleButton(_ button: MapDetailButton) -> some View {
        let title: String
        let help: String
        switch button {
        case .focus(let id, let name):
            title = focusSourceID == id ? "Unfocus" : "Focus \(name)"
            help = "Dim other profiles on the map"
        case .open(_, let label):
            title = label
            help = "Open this cloud session on claude.ai"
        }
        return Button {
            switch button {
            case .focus(let id, _): actions.focus(id)
            case .open(let url, _): actions.open(url)
            }
        } label: {
            Text(title)
                .font(Theme.Typeface.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Theme.Palette.raised, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func message(subject: String, sha: String, with: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            MapDetailSectionHeader(title: "Message", count: nil, trailing: nil)
            Text(subject)
                .font(Theme.Typeface.caption)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Text(sha)
                .font(Theme.Typeface.mono)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if let with {
                Text(with)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    private func details(_ facts: [MapDetailFact]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            MapDetailSectionHeader(title: "Details", count: nil, trailing: nil)
            ForEach(Array(facts.enumerated()), id: \.offset) { pair in
                detailRow(pair.element)
            }
        }
    }

    private func detailRow(_ fact: MapDetailFact) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(fact.label)
                .font(Theme.Typeface.micro)
                .foregroundStyle(.secondary)
                .frame(width: compact ? 56 : 64, alignment: .leading)
            if fact.mono {
                Text(fact.value ?? "—")
                    .font(Theme.Typeface.mono)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(fact.value ?? "—")
                    .font(Theme.Typeface.caption)
                    .lineLimit(1)
                    .truncationMode(fact.middle ? .middle : .tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func pathBlock(_ path: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            MapDetailSectionHeader(title: "Folder", count: nil, trailing: nil)
            Text(path)
                .font(Theme.Typeface.mono)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(note)
                .font(Theme.Typeface.note)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct MapDetailSectionHeader: View {
    let title: String
    let count: Int?
    let trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(Theme.Typeface.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if let count {
                Text(count.formatted())
                    .font(Theme.Typeface.micro.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            if let trailing {
                Text(trailing)
                    .font(Theme.Typeface.micro.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

private struct MapDetailSectionView: View {
    let section: MapDetailSection
    let current: MapHitID?
    let focusSourceID: String?
    let compact: Bool
    let isOpened: Bool
    let actions: MapDetailActions

    var body: some View {
        let shown = min(section.rows.count, isOpened ? section.hard : section.first)
        VStack(alignment: .leading, spacing: 0) {
            MapDetailSectionHeader(title: section.title, count: section.count, trailing: section.trailing)
                .padding(.bottom, 4)
            ForEach(section.rows.prefix(shown)) { row in
                MapDetailRowView(row: row, isCurrent: row.isCurrent(current), isFocused: row.isFocused(focusSourceID),
                                 compact: compact, maximum: section.maximum, actions: actions)
                    .transition(.opacity)
            }
            if shown < section.rows.count {
                Button("Show \(section.rows.count - shown) more") { actions.showMore(section.id) }
                    .buttonStyle(.borderless)
                    .font(Theme.Typeface.caption.weight(.medium))
                    .padding(.top, 4)
                    .padding(.leading, 6)
            } else if section.count > shown {
                Text("+\(section.count - shown) more not listed")
                    .font(Theme.Typeface.note)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                    .padding(.leading, 6)
            }
            if let note = section.note {
                Text(note)
                    .font(Theme.Typeface.note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                    .padding(.leading, 6)
            }
        }
    }
}

/// A 30pt row. Its hover is its own and only shades its background; it never reaches the map.
private struct MapDetailRowView: View {
    let row: MapDetailRow
    let isCurrent: Bool
    let isFocused: Bool
    let compact: Bool
    let maximum: Int
    let actions: MapDetailActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovering = false

    /// Spelled out: the private state above would otherwise make the memberwise initializer private.
    init(row: MapDetailRow, isCurrent: Bool, isFocused: Bool, compact: Bool, maximum: Int, actions: MapDetailActions) {
        self.row = row
        self.isCurrent = isCurrent
        self.isFocused = isFocused
        self.compact = compact
        self.maximum = maximum
        self.actions = actions
    }

    var body: some View {
        HStack(spacing: 6) {
            if row.target == .text {
                content
                    .accessibilityElement(children: .combine)
            } else {
                Button(action: activate) { content }
                    .buttonStyle(.plain)
                    .help(isFocusRow ? "Dim other profiles on the map" : "")
                    .accessibilityLabel(accessibilityLabel)
                    .accessibilityValue(row.value ?? "")
                    .accessibilityHint(row.pins && !isCurrent ? "Pins it in the details panel and on the map" : "")
                    .accessibilityAddTraits(isCurrent || isFocused ? .isSelected : [])
            }
            if let jump = row.jump {
                Button { actions.jump(jump) } label: {
                    Text("Jump")
                        .font(Theme.Typeface.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Theme.Palette.raised, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Open this session")
                .accessibilityLabel("Jump to \(row.title)")
            }
        }
    }

    private var isFocusRow: Bool {
        if case .focus = row.target { return true }
        return false
    }

    private var accessibilityLabel: String {
        isFocusRow ? "Focus \(row.title)" : "\(row.title), \(row.detail)"
    }

    private var content: some View {
        HStack(spacing: 8) {
            MapDetailLeadView(lead: row.lead)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(Theme.Typeface.caption)
                    .italic(row.italic)
                    .lineLimit(1)
                    .truncationMode(row.middle ? .middle : .tail)
                if !row.detail.isEmpty {
                    Text(row.detail)
                        .font(Theme.Typeface.note)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !compact, let value = row.barValue {
                bar(value)
            }
            if let value = row.value {
                Text(value)
                    .font(row.mono ? Theme.Typeface.mono : Theme.Typeface.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(minWidth: 28, alignment: .trailing)
            }
            if row.pins && !isCurrent {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 30)
        .contentShape(Rectangle())
        .background(background, in: Theme.Radius.shape(6))
        .overlay {
            if contrast == .increased && (isCurrent || isFocused) {
                Theme.Radius.shape(6).strokeBorder(Theme.Palette.hairline, lineWidth: 1)
            }
        }
        .onHover { hovering = $0 }
        .animation(MapMotion.animation(MapMotion.crossfade, reduceMotion: reduceMotion, still: rendersStill),
                   value: hovering)
    }

    private var background: Color {
        if isCurrent || isFocused { return Theme.Palette.raised }
        return hovering && row.target != .text ? Theme.Palette.sunken : Color.clear
    }

    private func bar(_ value: Int) -> some View {
        let fraction = maximum > 0 ? min(1, CGFloat(value) / CGFloat(maximum)) : 0
        return Capsule().fill(Theme.Palette.sunken)
            .frame(width: 48, height: 4)
            .overlay(alignment: .leading) {
                Capsule().fill(row.barColor ?? Color.primary.opacity(0.35))
                    .frame(width: 48 * fraction, height: 4)
            }
    }

    /// The current item's row does nothing; a focus row toggles, as the legend does.
    private func activate() {
        switch row.target {
        case .pin(let id):
            if !isCurrent { actions.pin(id) }
        case .focus(let id):
            actions.focus(id)
        case .text:
            break
        }
    }
}

private struct MapDetailLeadView: View {
    let lead: MapDetailLead

    var body: some View {
        switch lead {
        case .dot(let color):
            Circle().fill(color).frame(width: 7, height: 7)
        case .symbol(let name, let dim):
            Image(systemName: name)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .opacity(dim ? 0.5 : 1)
        case .ring:
            Circle().strokeBorder(Color.primary.opacity(0.7), lineWidth: 1.25).frame(width: 9, height: 9)
        case .status(let live):
            StatusGlyph(kind: live.kind, size: 9, animates: false)
        case .cloud(let color):
            Image(systemName: "cloud.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
        }
    }
}

/// A pinned live session's report: its title, what it asks, its state and its pills.
private struct MapDetailNowView: View {
    let box: MapDetailNowBox
    let now: Date
    let actions: MapDetailActions

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = box.title {
                Text(title)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
            }
            if let asks = box.asks {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Palette.needsInputText)
                    Text(asks)
                        .font(Theme.Typeface.caption)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(box.state + (ElapsedFormat.compact(since: box.since, now: now).map { " for \($0)" } ?? ""))
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
            if !box.pills.isEmpty || !box.pullRequests.isEmpty {
                HStack(spacing: 4) {
                    ForEach(box.pills, id: \.self) { pill in
                        Pill(text: pill)
                    }
                    ForEach(box.pullRequests, id: \.self) { request in
                        Button { actions.open(request.url) } label: {
                            Text("#\(request.number)")
                                .font(Theme.Typeface.micro)
                                .padding(.horizontal, 6)
                                .frame(height: 18)
                                .background(Theme.Palette.sunken, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Open pull request #\(request.number)")
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sunkenField(radius: Theme.Radius.control)
    }
}

private struct MapDetailHoursView: View {
    let hours: MapDetailHours

    var body: some View {
        let maximum = CGFloat(max(1, hours.values.max() ?? 1))
        VStack(alignment: .leading, spacing: 4) {
            MapDetailSectionHeader(title: "Time of day", count: nil, trailing: hours.trailing)
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(0..<hours.values.count, id: \.self) { slot in
                    Rectangle().fill(Theme.Palette.sparkline)
                        .frame(height: 32 * CGFloat(hours.values[slot]) / maximum)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 32, alignment: .bottom)
            .padding(4)
            .sunkenField(radius: 6)
            HStack(spacing: 0) {
                ForEach(0..<hours.labels.count, id: \.self) { position in
                    Text(hours.labels[position])
                        .font(Theme.Typeface.micro)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Edits by hour of day")
        .accessibilityValue(hours.accessibilityValue)
    }
}

private struct MapDetailStripView: View {
    let strip: MapDetailStrip
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MapDetailSectionHeader(title: strip.title, count: nil, trailing: nil)
                .padding(.bottom, 4)
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(strip.rows.enumerated()), id: \.offset) { pair in
                        Text(pair.element.label)
                            .font(Theme.Typeface.micro)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .opacity(pair.element.dim ? 0.5 : 1)
                            .frame(height: 16)
                    }
                }
                .frame(width: compact ? 72 : 96, alignment: .leading)
                Canvas { context, size in
                    MapDetailStripPainter.draw(strip, size: size, in: &context)
                }
                .frame(height: 16 * CGFloat(strip.rows.count))
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(strip.title)
            .accessibilityValue(strip.accessibilityValue)
        }
    }
}

private enum MapDetailStripPainter {
    static func draw(_ strip: MapDetailStrip, size: CGSize, in context: inout GraphicsContext) {
        let width = max(1, size.width - 6)
        func x(_ fraction: Double) -> CGFloat { 3 + CGFloat(fraction) * width }
        func y(_ row: Int) -> CGFloat { CGFloat(row) * 16 + 8 }
        let environment = context.environment
        for fold in strip.folds {
            let left = x(fold.lowerBound)
            context.fill(Path(CGRect(x: left, y: 0, width: max(1, x(fold.upperBound) - left), height: size.height)),
                         with: .color(Color.primary.opacity(0.035)))
        }
        for link in strip.links {
            let start = CGPoint(x: x(link.fromX), y: y(link.fromRow))
            let end = CGPoint(x: x(link.toX), y: y(link.toRow))
            guard end.x - start.x > 1 || start.y != end.y else { continue }
            var path = Path()
            path.move(to: start)
            let middle = (start.x + end.x) / 2
            path.addCurve(to: end, control1: CGPoint(x: middle, y: start.y), control2: CGPoint(x: middle, y: end.y))
            context.stroke(path, with: .color(link.color.flattened(in: environment).opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 2.5]))
        }
        if let thread = strip.thread {
            var path = Path()
            path.move(to: CGPoint(x: max(x(thread.to), x(thread.from) + 3), y: y(thread.row)))
            path.addLine(to: CGPoint(x: size.width - 1, y: y(thread.row)))
            context.stroke(path, with: .color(thread.color.flattened(in: environment).opacity(0.5)),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        for run in strip.runs {
            drawRun(run, left: x(run.from), right: max(x(run.to), x(run.from) + 3), y: y(run.row),
                    environment: environment, in: &context)
        }
    }

    private static func drawRun(_ run: MapDetailStrip.Run, left: CGFloat, right: CGFloat, y: CGFloat,
                                environment: EnvironmentValues, in context: inout GraphicsContext) {
        let rect = CGRect(x: left, y: y - 3, width: right - left, height: 6)
        let shape = Path(roundedRect: rect, cornerRadius: 3)
        let color = run.color.flattened(in: environment)
        var layer = context
        layer.opacity = run.dim ? 0.5 : 1
        if run.cloud {
            layer.fill(shape, with: .color(color.opacity(0.45)))
            layer.stroke(Path(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2.5), with: .color(color),
                         lineWidth: 1)
        } else if run.hatched {
            layer.fill(shape, with: .color(color.opacity(0.45)))
            var hatch = Path()
            var hatchX = rect.minX - rect.height
            while hatchX < rect.maxX {
                hatch.move(to: CGPoint(x: hatchX, y: rect.maxY))
                hatch.addLine(to: CGPoint(x: hatchX + rect.height, y: rect.minY))
                hatchX += 3
            }
            var clipped = layer
            clipped.clip(to: shape)
            clipped.stroke(hatch, with: .color(color), lineWidth: 1)
        } else {
            layer.fill(shape, with: .color(color.opacity(0.85)))
        }
        if run.current {
            let ring = rect.insetBy(dx: -2, dy: -2)
            context.stroke(Path(roundedRect: ring, cornerRadius: ring.height / 2),
                           with: .color(Color.primary.opacity(0.85)), lineWidth: 1)
        }
    }
}

// MARK: - Index

/// One index per map, calendar and profile list. A reference held in @State and never
/// observed, so a hover reuses it; any rebuilt map builds a new one.
private final class MapDetailCache {
    private var cached: MapDetailIndex?

    var current: MapDetailIndex? { cached }

    /// `map ==` takes Array's identical-buffer fast path for the same value, as `MapLayoutCache` relies on.
    func index(_ map: ProjectMap, calendar: ActivityCalendar, sources: [AgentSource]) -> MapDetailIndex {
        if let cached, cached.calendar == calendar, cached.storeSources == sources, cached.map == map { return cached }
        let index = MapDetailIndex(map: map, calendar: calendar, storeSources: sources)
        cached = index
        return index
    }
}

/// One column of the Days chart: an hour, a day, or several days of all history.
private struct MapDetailColumn {
    let start: Date
    let short: String?
    let long: String
}

private struct MapDetailShare: Equatable {
    var direct = 0
    var delegated = 0

    var total: Int { direct + delegated }
}

/// A session's runs and what they add up to.
private struct MapDetailSession {
    let key: String
    let sourceID: String
    let sessionID: String
    /// By index.
    let runs: [ProjectMap.Span]
    let first: Date
    /// Now while it is live.
    let last: Date
    let live: String?
    let direct: Int
    let delegated: Int
    /// The time its runs cover, counting runs side by side once.
    let active: TimeInterval
    /// Where it went, by name: a branch, or the branches it worked on side by side.
    let lanePath: [String]
    /// Its lanes in the order it first reached them.
    let uniqueLanes: [String]
    let editsByLane: [String: Int]
    let spawned: Int
    /// Clock hours with at least one of its edits.
    let hours: Int
    let cloud: Bool
    let cloudCommits: [ProjectMap.Marker]

    var edits: Int { direct + delegated }
}

/// One session's work on one lane.
private struct MapDetailLaneSession {
    var key: String
    var sourceID: String
    var edits: Int
    var runs: Int
    var first: Date
    var last: Date
    var latestRunIndex: Int
    var live: String?
}

private struct MapDetailLaneFacts {
    var bySource: [String: MapDetailShare] = [:]
    /// Latest first.
    var sessions: [MapDetailLaneSession] = []
    var cloudSessions = 0
    var firstEdit: Date?
    var lastEdit: Date?
}

private struct MapDetailTotals {
    var direct = 0
    var delegated = 0
    var sessions = 0
}

/// A session's edits a commit carried, with the run to pin for it.
private struct MapDetailCarry {
    let key: String
    let sourceID: String
    let count: Int
    let runIndex: Int
}

private struct MapDetailCarried {
    var count = 0
    var bySource: [String: MapDetailShare] = [:]
    /// Most edits first.
    var sessions: [MapDetailCarry] = []
}

private enum MapDetailNeighbor {
    case run(ProjectMap.Span)
    case commit(ProjectMap.Marker)
}

/// What came just before an idle fold and just after it.
private struct MapDetailFoldContext {
    let before: MapDetailNeighbor?
    let after: MapDetailNeighbor?
}

/// The rollover-based hour of many instants, with one time-zone offset lookup per
/// daylight-saving period instead of one per edit.
private struct MapDetailClock {
    let calendar: ActivityCalendar
    private var validFrom = Date.distantFuture
    private var validUntil = Date.distantPast
    private var offset = 0

    init(calendar: ActivityCalendar) {
        self.calendar = calendar
    }

    mutating func slot(of date: Date) -> Int {
        if date < validFrom || date >= validUntil {
            offset = calendar.timeZone.secondsFromGMT(for: date)
            validFrom = date
            validUntil = calendar.timeZone.nextDaylightSavingTimeTransition(after: date) ?? .distantFuture
        }
        let local = date.timeIntervalSince1970 + Double(offset)
        let day = (local / 86_400).rounded(.down)
        let hour = min(23, max(0, Int((local - day * 86_400) / 3_600)))
        return (hour - calendar.rolloverHour + 24) % 24
    }
}

/// Everything the panel reads from one map, built in one pass so a hover only looks things
/// up. The lens and the bodies are memoized here, except anything holding conversation text.
private final class MapDetailIndex {
    /// The longest an edit waits for the commit that carries it, matching ProjectMap's own `carryLimit`.
    static let carryWindow: TimeInterval = 12 * 3_600

    let map: ProjectMap
    let calendar: ActivityCalendar
    let storeSources: [AgentSource]
    let sources: [AgentSource]
    let text: MapInspectorText
    let trunkID: String
    let editCount: Int
    let mergeCount: Int
    let quietMergeCount: Int
    let branchCount: Int
    let color: [String: Color]
    let name: [String: String]
    /// "Second" for "Claude · Second".
    let shortName: [String: String]
    let laneByID: [String: ProjectMap.Lane]
    let markerBySHA: [String: ProjectMap.Marker]
    /// Oldest first.
    let markersByLane: [String: [ProjectMap.Marker]]
    let positionOnLane: [String: Int]
    /// By index.
    let runsBySession: [String: [ProjectMap.Span]]
    /// By start.
    let runsByLane: [String: [ProjectMap.Span]]
    let gapByStart: [Date: TimeAxis.Segment]
    /// Longest first.
    let gapsByLength: [TimeAxis.Segment]
    /// 1 is the longest.
    let gapRank: [Date: Int]
    /// Where branches landed on the trunk, oldest first.
    let beads: [ProjectMap.Marker]
    let lanesMergedBy: [String: [String]]
    let mergedInto: [String: [String]]
    let children: [String: [String]]
    let branchesByEdits: [ProjectMap.Lane]
    /// Waiting first, then by start.
    let liveRuns: [ProjectMap.Span]
    let sessionsByRecency: [String]
    /// How long each fairly measured merged branch lived, shortest first.
    let fairLeads: [TimeInterval]
    let columns: [MapDetailColumn]
    private let starts: [Date]
    /// 0 for hourly columns, else the days in a column.
    let columnDays: Int
    let projectDays: [Int]
    let sessionDays: [String: [Int]]
    let laneDays: [String: [Int]]
    let projectHours: [Int]
    let activeHours: Int
    let sessions: [String: MapDetailSession]
    let laneFacts: [String: MapDetailLaneFacts]
    /// Profiles by edits, the legend's order, then the cloud.
    let profileOrder: [String]
    let profileTotals: [String: MapDetailTotals]
    let chart: MapDetailChart

    private var projectLens: MapDetailLens?
    private var lensMemo: [MapHitID: MapDetailLens] = [:]
    private var deepMemo: [MapHitID: [MapDetailBlock]] = [:]
    private var overviewMemo: [MapDetailBlock]?
    private var carriedMemo: [String: MapDetailCarried] = [:]
    private var foldMemo: [Date: MapDetailFoldContext] = [:]
    private var meanwhileMemo: [String: [ProjectMap.Marker]] = [:]

    init(map: ProjectMap, calendar: ActivityCalendar, storeSources: [AgentSource]) {
        self.map = map
        self.calendar = calendar
        self.storeSources = storeSources
        let sources = map.sources(storeSources)
        self.sources = sources
        text = MapInspectorText(map: map, sources: sources, calendar: calendar)
        let trunkID = map.lanes.first { $0.kind == .trunk }?.id ?? ""
        self.trunkID = trunkID
        editCount = map.spans.reduce(0) { $0 + $1.editCount }
        quietMergeCount = map.markers.filter { $0.quietBranch != nil }.count
        branchCount = map.unfoldedBranchCount ?? map.lanes.filter { $0.kind != .trunk }.count

        var color: [String: Color] = [:]
        var name: [String: String] = [:]
        var shortName: [String: String] = [:]
        for id in Set(sources.map(\.id) + map.spans.map(\.sourceID)) {
            color[id] = ProfileColor.color(id, sources: sources)
            let full = GrowthSeries.name(of: id, sources: sources)
            name[id] = full
            shortName[id] = full.components(separatedBy: " · ").last ?? full
        }
        self.color = color
        self.name = name
        self.shortName = shortName

        let laneByID = Dictionary(map.lanes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.laneByID = laneByID
        markerBySHA = Dictionary(map.markers.map { ($0.sha, $0) }, uniquingKeysWith: { first, _ in first })
        // `map.markers` is sorted by date, and grouping keeps that order.
        let markersByLane = Dictionary(grouping: map.markers, by: \.laneID)
        self.markersByLane = markersByLane
        var positionOnLane: [String: Int] = [:]
        for list in markersByLane.values {
            for (position, marker) in list.enumerated() { positionOnLane[marker.sha] = position }
        }
        self.positionOnLane = positionOnLane
        let runsBySession = Dictionary(grouping: map.spans, by: \.sessionKey)
            .mapValues { runs in runs.sorted { $0.index < $1.index } }
        self.runsBySession = runsBySession
        let runsByLane = Dictionary(grouping: map.spans, by: \.laneID)
            .mapValues { runs in runs.sorted { $0.start < $1.start } }
        self.runsByLane = runsByLane

        let gaps = map.axis.gaps
        gapByStart = Dictionary(gaps.map { ($0.start, $0) }, uniquingKeysWith: { first, _ in first })
        let gapsByLength = gaps.sorted { $0.duration != $1.duration ? $0.duration > $1.duration : $0.start < $1.start }
        self.gapsByLength = gapsByLength
        gapRank = Dictionary(gapsByLength.enumerated().map { ($0.element.start, $0.offset + 1) },
                             uniquingKeysWith: { first, _ in first })
        let beads = map.markers.filter { $0.laneID == trunkID && $0.isBead }
        self.beads = beads
        mergeCount = beads.count

        var lanesMergedBy: [String: [String]] = [:]
        var mergedInto: [String: [String]] = [:]
        var children: [String: [String]] = [:]
        for lane in map.lanes {
            if let merge = lane.merge {
                lanesMergedBy[merge.sha, default: []].append(lane.id)
                if merge.intoLaneID != lane.id { mergedInto[merge.intoLaneID, default: []].append(lane.id) }
            }
            for merge in lane.returns where merge.sha != lane.merge?.sha {
                if lanesMergedBy[merge.sha]?.contains(lane.id) != true { lanesMergedBy[merge.sha, default: []].append(lane.id) }
            }
            if let parent = lane.parentID, parent != lane.id { children[parent, default: []].append(lane.id) }
        }
        self.lanesMergedBy = lanesMergedBy
        self.mergedInto = mergedInto
        self.children = children
        branchesByEdits = map.lanes.filter { $0.kind != .trunk }.sorted { lhs, rhs in
            if lhs.editCount != rhs.editCount { return lhs.editCount > rhs.editCount }
            if lhs.end != rhs.end { return lhs.end > rhs.end }
            return lhs.id < rhs.id
        }
        liveRuns = map.spans.filter { $0.live != nil }.sorted { lhs, rhs in
            let left = lhs.live == LiveStatus.waiting.rawValue ? 0 : 1
            let right = rhs.live == LiveStatus.waiting.rawValue ? 0 : 1
            return left != right ? left < right : lhs.start < rhs.start
        }
        fairLeads = map.lanes.compactMap { lane -> TimeInterval? in
            guard !lane.isStream, !lane.enteredBeforeWindow, let merge = lane.merge else { return nil }
            return merge.date.timeIntervalSince(lane.forkedAt ?? lane.start)
        }.sorted()

        // Columns, then one pass over every edit.
        let layout = Self.makeColumns(map, calendar: calendar)
        columns = layout.columns
        columnDays = layout.days
        let starts = layout.columns.map(\.start)
        self.starts = starts
        let count = max(1, layout.columns.count)
        var projectDays = [Int](repeating: 0, count: count)
        var sessionDays: [String: [Int]] = [:]
        var laneDays: [String: [Int]] = [:]
        var projectHours = [Int](repeating: 0, count: 24)
        var projectHourSet = Set<Int>()
        var sessionHourSets: [String: Set<Int>] = [:]
        var clock = MapDetailClock(calendar: calendar)
        for span in map.spans {
            var days = [Int](repeating: 0, count: count)
            var hours = sessionHourSets[span.sessionKey] ?? []
            // Never `span.edits`, which sorts.
            for list in [span.direct, span.delegated] {
                for date in list {
                    days[Self.column(of: date, in: starts)] += 1
                    projectHours[clock.slot(of: date)] += 1
                    let bucket = Int(date.timeIntervalSince1970 / 3_600)
                    hours.insert(bucket)
                    projectHourSet.insert(bucket)
                }
            }
            sessionHourSets[span.sessionKey] = hours
            guard span.editCount > 0 else { continue }
            projectDays = Self.sum(projectDays, days)
            sessionDays[span.sessionKey] = Self.sum(sessionDays[span.sessionKey] ?? [Int](repeating: 0, count: count), days)
            laneDays[span.laneID] = Self.sum(laneDays[span.laneID] ?? [Int](repeating: 0, count: count), days)
        }
        self.projectDays = projectDays
        self.sessionDays = sessionDays
        self.laneDays = laneDays
        self.projectHours = projectHours
        activeHours = projectHourSet.count
        let caption: String
        switch layout.days {
        case 0: caption = "Edits by hour"
        case 1: caption = "Edits by day"
        default: caption = "Edits per \(layout.days) days"
        }
        chart = MapDetailChart(caption: caption, labels: layout.columns.map(\.short), ghost: projectDays,
                               maximum: max(1, projectDays.max() ?? 0))

        let sessions = Self.makeSessions(map, runsBySession: runsBySession, hours: sessionHourSets)
        self.sessions = sessions
        sessionsByRecency = sessions.values.sorted { $0.last != $1.last ? $0.last > $1.last : $0.key < $1.key }.map(\.key)
        laneFacts = Self.makeLaneFacts(map, runsByLane: runsByLane)

        var totals: [String: MapDetailTotals] = [:]
        var keysBySource: [String: Set<String>] = [:]
        for span in map.spans where span.sourceID != ProjectMap.cloudSourceID {
            totals[span.sourceID, default: MapDetailTotals()].direct += span.direct.count
            totals[span.sourceID, default: MapDetailTotals()].delegated += span.delegated.count
            keysBySource[span.sourceID, default: []].insert(span.sessionKey)
        }
        for (id, keys) in keysBySource { totals[id]?.sessions = keys.count }
        var order = totals.keys.filter { (totals[$0]?.direct ?? 0) + (totals[$0]?.delegated ?? 0) > 0 }
            .sorted { lhs, rhs in
                let left = (totals[lhs]?.direct ?? 0) + (totals[lhs]?.delegated ?? 0)
                let right = (totals[rhs]?.direct ?? 0) + (totals[rhs]?.delegated ?? 0)
                return left != right ? left > right : lhs < rhs
            }
        if map.cloudSessionCount > 0 {
            order.append(ProjectMap.cloudSourceID)
            totals[ProjectMap.cloudSourceID] = MapDetailTotals(direct: 0, delegated: 0, sessions: map.cloudSessionCount)
        }
        profileOrder = order
        profileTotals = totals
    }

    // MARK: Building

    private static func makeColumns(_ map: ProjectMap, calendar: ActivityCalendar) -> (columns: [MapDetailColumn], days: Int) {
        let today = calendar.day(of: map.now)
        switch map.range {
        case .today:
            let start = calendar.start(of: today)
            let count = min(24, max(1, Int((map.now.timeIntervalSince(start) / 3_600).rounded(.up))))
            let columns = (0..<count).map { offset -> MapDetailColumn in
                let date = start.addingTimeInterval(Double(offset) * 3_600)
                let hour = DayFormat.hour(calendar.hour(of: date))
                return MapDetailColumn(start: date, short: offset % 3 == 0 ? hour : nil, long: "\(hour):00")
            }
            return (columns, 0)
        case .week:
            return (daily(from: today.adding(days: -6), to: today, calendar: calendar), 1)
        case .month:
            return (daily(from: today.adding(days: -29), to: today, calendar: calendar), 1)
        case .all:
            let first = map.axis.segments.isEmpty ? today : min(today, calendar.day(of: map.axis.start))
            let days = first.days(to: today) + 1
            if days <= 30 { return (daily(from: first, to: today, calendar: calendar), 1) }
            let size = Int((Double(days) / 30).rounded(.up))
            let count = Int((Double(days) / Double(size)).rounded(.up))
            let columns = (0..<count).map { offset -> MapDetailColumn in
                let last = today.adding(days: -(count - 1 - offset) * size)
                let start = last.adding(days: -(size - 1))
                let short = (count - 1 - offset) % 7 == 0 ? DayFormat.short(start, calendar: calendar) : nil
                return MapDetailColumn(start: calendar.start(of: start), short: short,
                                       long: "\(DayFormat.short(start, calendar: calendar)) – \(DayFormat.short(last, calendar: calendar))")
            }
            return (columns, size)
        }
    }

    private static func daily(from first: DayKey, to last: DayKey, calendar: ActivityCalendar) -> [MapDetailColumn] {
        let count = max(1, first.days(to: last) + 1)
        return (0..<count).map { offset -> MapDetailColumn in
            let day = first.adding(days: offset)
            let short: String?
            if count <= 10 {
                short = DayFormat.weekday(day.weekday, style: .narrow) + " \(day.day)"
            } else {
                short = (count - 1 - offset) % 7 == 0 ? DayFormat.short(day, calendar: calendar) : nil
            }
            return MapDetailColumn(start: calendar.start(of: day), short: short,
                                   long: "\(DayFormat.weekday(day.weekday)) \(day.day)")
        }
    }

    private static func makeSessions(_ map: ProjectMap, runsBySession: [String: [ProjectMap.Span]],
                                     hours: [String: Set<Int>]) -> [String: MapDetailSession] {
        let cloudCommits = Dictionary(grouping: map.markers.filter { $0.cloudSession != nil }, by: { $0.cloudSession ?? "" })
        var sessions: [String: MapDetailSession] = [:]
        for (key, runs) in runsBySession {
            guard let firstRun = runs.first else { continue }
            let live = runs.compactMap(\.live).first
            var path: [String] = []
            for hop in MapText.path(runs, in: map) where path.last != hop { path.append(hop) }
            var unique: [String] = []
            var byLane: [String: Int] = [:]
            for run in runs {
                if byLane[run.laneID] == nil { unique.append(run.laneID) }
                byLane[run.laneID, default: 0] += run.editCount
            }
            let cloud = firstRun.sourceID == ProjectMap.cloudSourceID
            sessions[key] = MapDetailSession(
                key: key, sourceID: firstRun.sourceID, sessionID: firstRun.sessionID, runs: runs,
                first: runs.map(\.start).min() ?? firstRun.start,
                last: live != nil ? map.now : (runs.map(\.end).max() ?? firstRun.end), live: live,
                direct: runs.reduce(0) { $0 + $1.direct.count }, delegated: runs.reduce(0) { $0 + $1.delegated.count },
                active: ProjectMap.activeTime(runs),
                lanePath: path, uniqueLanes: unique, editsByLane: byLane,
                spawned: runs.first { $0.index == 0 }?.spawnedThreads ?? 0, hours: hours[key]?.count ?? 0,
                cloud: cloud, cloudCommits: cloud ? (cloudCommits[firstRun.sessionID] ?? []) : [])
        }
        return sessions
    }

    private static func makeLaneFacts(_ map: ProjectMap,
                                      runsByLane: [String: [ProjectMap.Span]]) -> [String: MapDetailLaneFacts] {
        var result: [String: MapDetailLaneFacts] = [:]
        for (laneID, runs) in runsByLane {
            var facts = MapDetailLaneFacts()
            var byKey: [String: MapDetailLaneSession] = [:]
            for run in runs {
                facts.bySource[run.sourceID, default: MapDetailShare()].direct += run.direct.count
                facts.bySource[run.sourceID, default: MapDetailShare()].delegated += run.delegated.count
                let last = run.live != nil ? map.now : run.end
                if var entry = byKey[run.sessionKey] {
                    entry.edits += run.editCount
                    entry.runs += 1
                    entry.first = min(entry.first, run.start)
                    entry.last = max(entry.last, last)
                    entry.latestRunIndex = max(entry.latestRunIndex, run.index)
                    entry.live = entry.live ?? run.live
                    byKey[run.sessionKey] = entry
                } else {
                    byKey[run.sessionKey] = MapDetailLaneSession(key: run.sessionKey, sourceID: run.sourceID,
                                                                 edits: run.editCount, runs: 1, first: run.start, last: last,
                                                                 latestRunIndex: run.index, live: run.live)
                }
                let edges = [run.direct.first, run.delegated.first, run.direct.last, run.delegated.last].compactMap { $0 }
                for date in edges {
                    facts.firstEdit = min(facts.firstEdit ?? date, date)
                    facts.lastEdit = max(facts.lastEdit ?? date, date)
                }
            }
            facts.sessions = byKey.values.sorted { $0.last != $1.last ? $0.last > $1.last : $0.key < $1.key }
            facts.cloudSessions = byKey.values.filter { $0.sourceID == ProjectMap.cloudSourceID }.count
            result[laneID] = facts
        }
        return result
    }

    static func sum(_ values: [Int], _ more: [Int]?) -> [Int] {
        guard let more, more.count == values.count else { return values }
        return zip(values, more).map { $0.0 + $0.1 }
    }

    static func merge(_ shares: [String: MapDetailShare], into total: inout [String: MapDetailShare]) {
        for (id, share) in shares {
            total[id, default: MapDetailShare()].direct += share.direct
            total[id, default: MapDetailShare()].delegated += share.delegated
        }
    }

    /// The last column starting at or before `date`, clamped to the chart.
    static func column(of date: Date, in starts: [Date]) -> Int {
        guard !starts.isEmpty else { return 0 }
        var low = 0
        var high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= date { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// How many of the ascending `dates` are at or before `limit`.
    static func count(_ dates: [Date], through limit: Date) -> Int {
        var low = 0
        var high = dates.count
        while low < high {
            let middle = (low + high) / 2
            if dates[middle] <= limit { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The first of the date-ordered `markers` at or after `date`.
    static func firstIndex(in markers: [ProjectMap.Marker], notBefore date: Date) -> Int {
        var low = 0
        var high = markers.count
        while low < high {
            let middle = (low + high) / 2
            if markers[middle].date < date { low = middle + 1 } else { high = middle }
        }
        return low
    }

    // MARK: Lookups

    func column(of date: Date) -> Int { Self.column(of: date, in: starts) }

    var zeros: [Int] { [Int](repeating: 0, count: chart.count) }

    func title(_ id: String) -> String { laneByID[id].map(MapText.title) ?? "" }

    /// The same item `MapHit.resolve` finds, rule for rule, by dictionary.
    func resolve(_ id: MapHitID) -> MapHit? {
        switch id {
        case .run(let key, let position):
            guard let runs = runsBySession[key],
                  let run = runs.first(where: { $0.index == position }) ?? runs.last else { return nil }
            return run.live != nil ? .live(run) : .span(run)
        case .commit(let sha):
            return markerBySHA[sha].map(MapHit.commit)
        case .cluster(let shas):
            let found = shas.compactMap { markerBySHA[$0] }.sorted { ($0.date, $0.sha) < ($1.date, $1.sha) }
            return found.isEmpty ? nil : found.count == 1 ? .commit(found[0]) : .cluster(found)
        case .lane(let laneID):
            return laneByID[laneID].map(MapHit.lane)
        case .group(let ids):
            let found = ids.compactMap { laneByID[$0] }
            return found.isEmpty ? nil : found.count == 1 ? .lane(found[0]) : .group(found)
        case .fold(let start):
            return gapByStart[start].map(MapHit.fold)
        }
    }

    func shortTitle(_ hit: MapHit) -> String {
        switch hit {
        case .live(let span), .span(let span): return "\(shortName[span.sourceID] ?? "") · \(title(span.laneID))"
        case .commit(let marker): return marker.pullRequest.map { "#\($0)" } ?? String(marker.sha.prefix(7))
        case .cluster(let markers): return "\(markers.count) merges"
        case .lane(let lane): return MapText.title(lane)
        case .group(let lanes): return MapText.groupTitle(lanes, in: map)
        case .fold(let gap): return "Idle \(MapText.idle(gap.duration))"
        }
    }

    /// The inspector's words for a lane, with the squash check by dictionary.
    func laneHeadline(_ lane: ProjectMap.Lane) -> String {
        if lane.kind == .trunk { return lane.isHead ? "Default branch · checked out" : "Default branch" }
        if let merge = lane.merge {
            let verb = markerBySHA[merge.sha]?.kind == .squash ? "Squash-merged" : "Merged"
            return merge.pullRequest.map { "\(verb) #\($0)" } ?? verb
        }
        if lane.isStream { return "\(lane.members.count) branches · \(lane.returns.count) merged" }
        if lane.deleted { return "Deleted" }
        if lane.isHead { return "Open · checked out" }
        return lane.kind == .folder ? "Worktree · branch unknown" : "Open"
    }

    /// The branch a commit landed, when it landed one that is drawn.
    func landedLane(_ marker: ProjectMap.Marker) -> ProjectMap.Lane? {
        if let id = marker.mergedLaneID, let lane = laneByID[id] { return lane }
        return lanesMergedBy[marker.sha]?.first.flatMap { laneByID[$0] }
    }

    /// "#18 nv/billing", else the short SHA.
    func label(_ marker: ProjectMap.Marker) -> String {
        let parts: [String?] = [marker.pullRequest.map { "#\($0)" },
                                marker.mergedLaneID.map { title($0) } ?? marker.quietBranch]
        let text = parts.compactMap { $0 }.joined(separator: " ")
        return text.isEmpty ? String(marker.sha.prefix(7)) : text
    }

    func liveStatus(onLane id: String) -> MapDetailLive {
        liveRuns.contains { $0.laneID == id && $0.live == LiveStatus.waiting.rawValue } ? .waiting : .working
    }

    /// How the map matched the commit that landed `lane`.
    func matchNote(_ lane: ProjectMap.Lane, sha: String) -> String? {
        let match = lane.merge?.sha == sha ? lane.merge?.match : lane.returns.first { $0.sha == sha }?.match
        switch match {
        case .tree?: return "Same tree as the branch head"
        case .parent?: return "A parent is the branch head"
        case .subject?: return "Subject matches a branch commit"
        case nil: return nil
        }
    }

    /// How `lane` ranks among the fairly measured merged branches by how long each lived:
    /// "faster than 40%", with words of their own at either end.
    func pace(_ lane: ProjectMap.Lane) -> String? {
        guard !lane.isStream, !lane.enteredBeforeWindow, let merge = lane.merge, fairLeads.count >= 3 else { return nil }
        let mine = merge.date.timeIntervalSince(lane.forkedAt ?? lane.start)
        let slower = fairLeads.filter { $0 > mine }.count
        let others = fairLeads.count - 1
        if slower == 0 { return "the slowest of \(fairLeads.count)" }
        if slower >= others { return "the fastest of \(fairLeads.count)" }
        // Rounding must not reach 0% or 100%, which only the ends may claim.
        let share: Int = min(99, max(1, MapDetailText.percent(slower, others) ?? 0))
        return "faster than \(share)%"
    }

    /// `marker` landed one member of the stream `lane`, so the stream's figures are not its own.
    /// A head stream's single landing carries the whole stream.
    func landsMember(_ marker: ProjectMap.Marker, of lane: ProjectMap.Lane) -> Bool {
        lane.isStream && (lane.returns.count > 1 || lane.merge?.sha != marker.sha)
    }

    /// A merge's edits for its row; a stream member's own edits are folded into the stream.
    func landedEdits(_ marker: ProjectMap.Marker) -> String {
        guard let lane = landedLane(marker) else { return "no edits" }
        return landsMember(marker, of: lane) ? "stream member" : GrowthText.edits(lane.editCount)
    }

    /// Commits on a session's branches while it ran, or just after a run; memoized.
    func meanwhile(_ key: String) -> [ProjectMap.Marker] {
        if let memo = meanwhileMemo[key] { return memo }
        var found: [String: ProjectMap.Marker] = [:]
        for run in sessions[key]?.runs ?? [] {
            let list = markersByLane[run.laneID] ?? []
            let limit = run.end.addingTimeInterval(map.range.runBreak)
            var position = Self.firstIndex(in: list, notBefore: run.start)
            while position < list.count, list[position].date <= limit {
                found[list[position].sha] = list[position]
                position += 1
            }
        }
        let result = found.values.sorted { ($0.date, $0.sha) < ($1.date, $1.sha) }
        meanwhileMemo[key] = result
        return result
    }

    /// The edits on a commit's branch since its previous commit there, within the carry window.
    func carried(_ marker: ProjectMap.Marker) -> MapDetailCarried {
        if let memo = carriedMemo[marker.sha] { return memo }
        let list = markersByLane[marker.laneID] ?? []
        let position = positionOnLane[marker.sha] ?? 0
        let previous = position > 0 && position - 1 < list.count ? list[position - 1].date : Date.distantPast
        let lower = max(previous, marker.date.addingTimeInterval(-Self.carryWindow))
        var result = MapDetailCarried()
        var byKey: [String: MapDetailCarry] = [:]
        for run in runsByLane[marker.laneID] ?? [] where run.end > lower && run.start <= marker.date {
            let direct = Self.count(run.direct, through: marker.date) - Self.count(run.direct, through: lower)
            let delegated = Self.count(run.delegated, through: marker.date) - Self.count(run.delegated, through: lower)
            guard direct + delegated > 0 else { continue }
            result.count += direct + delegated
            result.bySource[run.sourceID, default: MapDetailShare()].direct += direct
            result.bySource[run.sourceID, default: MapDetailShare()].delegated += delegated
            let earlier = byKey[run.sessionKey]
            byKey[run.sessionKey] = MapDetailCarry(key: run.sessionKey, sourceID: run.sourceID,
                                                   count: (earlier?.count ?? 0) + direct + delegated,
                                                   runIndex: max(earlier?.runIndex ?? run.index, run.index))
        }
        result.sessions = byKey.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }
        carriedMemo[marker.sha] = result
        return result
    }

    /// The run or commit just before an idle fold, and the one just after it; memoized.
    func foldContext(_ gap: TimeAxis.Segment) -> MapDetailFoldContext {
        if let memo = foldMemo[gap.start] { return memo }
        let runBefore = map.spans.filter { $0.end <= gap.start }.max { $0.end < $1.end }
        let markerBefore = map.markers.last { $0.date <= gap.start }
        let runAfter = map.spans.filter { $0.start >= gap.end }.min { $0.start < $1.start }
        let markerAfter = map.markers.first { $0.date >= gap.end }
        let before: MapDetailNeighbor?
        if let run = runBefore, let marker = markerBefore {
            before = marker.date > run.end ? .commit(marker) : .run(run)
        } else {
            before = runBefore.map(MapDetailNeighbor.run) ?? markerBefore.map(MapDetailNeighbor.commit)
        }
        let after: MapDetailNeighbor?
        if let run = runAfter, let marker = markerAfter {
            after = marker.date < run.start ? .commit(marker) : .run(run)
        } else {
            after = runAfter.map(MapDetailNeighbor.run) ?? markerAfter.map(MapDetailNeighbor.commit)
        }
        let context = MapDetailFoldContext(before: before, after: after)
        foldMemo[gap.start] = context
        return context
    }

    /// The cloud session run that made a commit: the one whose span holds it, else the nearest.
    func cloudRun(of marker: ProjectMap.Marker) -> ProjectMap.Span? {
        guard let session = marker.cloudSession,
              let runs = runsBySession[ProjectMap.cloudSourceID + "\u{0}" + session], !runs.isEmpty else { return nil }
        if let run = runs.first(where: { $0.start <= marker.date && marker.date <= $0.end }) { return run }
        return runs.min { abs($0.start.timeIntervalSince(marker.date)) < abs($1.start.timeIntervalSince(marker.date)) }
    }
}

// MARK: - Lens content

extension MapDetailIndex {
    /// The lens for `hit`, or the project's. Memoized per item, except a live session, whose
    /// title and question come from the store.
    func lens(_ hit: MapHit?, live session: LiveAgentSession?, showTitles: Bool) -> MapDetailLens {
        guard let hit else {
            if let cached = projectLens { return cached }
            let lens = makeProjectLens()
            projectLens = lens
            return lens
        }
        if case .live(let span) = hit { return sessionLens(span, live: session, showTitles: showTitles) }
        if let memo = lensMemo[hit.id] { return memo }
        let lens: MapDetailLens
        switch hit {
        case .live(let span), .span(let span): lens = sessionLens(span, live: nil, showTitles: showTitles)
        case .commit(let marker): lens = commitLens(marker)
        case .cluster(let markers): lens = clusterLens(markers)
        case .lane(let lane): lens = lane.kind == .trunk ? trunkLens(lane) : laneLens(lane)
        case .group(let lanes): lens = groupLens(lanes)
        case .fold(let gap): lens = foldLens(gap)
        }
        lensMemo[hit.id] = lens
        return lens
    }

    private func fig(_ label: String, _ value: String?) -> MapDetailFigure { MapDetailFigure(label: label, value: value) }

    /// A count, labeled in the singular when it is exactly 1.
    private func fig(_ count: Int, _ singular: String, _ plural: String) -> MapDetailFigure {
        MapDetailFigure(label: count == 1 ? singular : plural, value: count.formatted())
    }

    private func fact(_ label: String, _ value: String?, middle: Bool = false) -> MapDetailFact {
        MapDetailFact(label: label, value: value, middle: middle)
    }

    private func days(ink: [Int]?, ticks: [Date], band: (Date, Date)? = nil, right: String? = nil) -> MapDetailDays {
        let ink = ink ?? zeros
        let bandColumns: ClosedRange<Int>? = band.map { range in
            let from = column(of: range.0)
            let to = column(of: range.1)
            return min(from, to)...max(from, to)
        }
        return MapDetailDays(ink: ink, ticks: Set(ticks.map { column(of: $0) }), band: bandColumns,
                             right: right ?? busiest(ink))
    }

    private func busiest(_ ink: [Int]) -> String {
        guard let top = ink.indices.max(by: { ink[$0] < ink[$1] }), ink[top] > 0, columns.indices.contains(top) else {
            return "No edits in range"
        }
        return "Busiest \(columns[top].long) · \(ink[top].formatted())"
    }

    /// Every profile in the legend's order, so each subject only changes lengths.
    func who(_ shares: [String: MapDetailShare], empty: String) -> MapDetailWho {
        let segments = profileOrder.map { id -> MapDetailWhoSegment in
            let share = shares[id] ?? MapDetailShare()
            return MapDetailWhoSegment(id: id, name: name[id] ?? "", color: color[id] ?? .gray, direct: share.direct,
                                       delegated: share.delegated)
        }
        let filled = segments.filter { $0.total > 0 }.sorted { $0.total != $1.total ? $0.total > $1.total : $0.id < $1.id }
        guard let top = filled.first else { return MapDetailWho(segments: segments, left: empty, right: "") }
        if filled.count == 1 {
            return MapDetailWho(segments: segments,
                                left: "\(top.direct.formatted()) direct · \(top.delegated.formatted()) by subagents", right: "")
        }
        var left = filled.prefix(2).map { "\(shortName[$0.id] ?? $0.name) \($0.total.formatted())" }.joined(separator: " · ")
        if filled.count > 2 { left += " +\(filled.count - 2)" }
        let total = filled.reduce(0) { $0 + $1.total }
        let delegated = filled.reduce(0) { $0 + $1.delegated }
        let right = delegated == 0 ? "no subagents" : "\(MapDetailText.percent(delegated, total) ?? 0)% by subagents"
        return MapDetailWho(segments: segments, left: left, right: right)
    }

    private var profileShares: [String: MapDetailShare] {
        profileTotals.mapValues { MapDetailShare(direct: $0.direct, delegated: $0.delegated) }
    }

    // MARK: Project

    private func makeProjectLens() -> MapDetailLens {
        let waiting = liveRuns.filter { $0.live == LiveStatus.waiting.rawValue }.count
        let working = liveRuns.count - waiting
        var subtitle = MapDetailWords("")
        if waiting > 0 { subtitle = subtitle + MapDetailWords("\(waiting) needs input", live: .waiting) + MapDetailWords(" · ") }
        if working > 0 { subtitle = subtitle + MapDetailWords("\(working) working", live: .working) + MapDetailWords(" · ") }
        var rest = GrowthText.count(branchCount, "branch", "branches")
        if map.cloudSessionCount > 0 { rest += " · " + GrowthText.count(map.cloudSessionCount, "cloud session", "cloud sessions") }
        if !map.isGitCheckout { rest += " · not a Git checkout" }
        subtitle = subtitle + MapDetailWords(rest)
        var active = "\(activeHours) h with edits"
        if columnDays == 1 { active += " on \(projectDays.filter { $0 > 0 }.count) of \(columns.count) days" }
        // Lanes folds branches into streams, so the busiest row may be one.
        let busiest = branchesByEdits.first { $0.editCount > 0 }.map { lane -> String in
            let named = "\(MapText.title(lane)) · \(GrowthText.edits(lane.editCount))"
            return lane.isStream ? "Stream " + named : named
        }
        let idle = gapsByLength.first.map { "\(MapText.idle($0.duration)) from \(text.moment($0.start))" } ?? "No folded pauses"
        let head = map.isGitCheckout ? map.lanes.first { $0.isHead }.map(MapText.title) : "Not a Git checkout"
        return MapDetailLens(kind: MapDetailWords("PROJECT · " + map.range.title.uppercased()),
                             glyph: .symbol("folder", primary: false),
                             title: (map.projectPath as NSString).lastPathComponent, middle: true, subtitle: subtitle,
                             figures: [fig(editCount, "Edit", "Edits"), fig(map.sessionCount, "Session", "Sessions"),
                                       fig("Merged", mergeCount.formatted())],
                             days: days(ink: projectDays, ticks: beads.map(\.date)),
                             who: who(profileShares, empty: "No edits recorded by an assistant"),
                             facts: [fact("Active", active), fact("Busiest", busiest, middle: true),
                                     fact("Longest idle", idle), fact("Checked out", head, middle: true)])
    }

    // MARK: Session

    /// Session-level figures, so moving between one session's runs changes only the facts,
    /// the band and the subtitle.
    private func sessionLens(_ span: ProjectMap.Span, live session: LiveAgentSession?, showTitles: Bool) -> MapDetailLens {
        guard let facts = sessions[span.sessionKey] else { return makeProjectLens() }
        let run = span.index + 1
        let runs = facts.runs.count
        let status = MapDetailLive.of(span.live)
        let lane = title(span.laneID)
        let profile = name[span.sourceID] ?? ""
        let conversation = session.flatMap { SessionLabel.title($0, showTitles: showTitles, limit: 80) }
        let kind: MapDetailWords
        let subtitle: MapDetailWords
        if facts.cloud {
            kind = MapDetailWords("CLOUD SESSION · RUN \(run) OF \(runs)")
            subtitle = MapDetailWords("claude.ai · on \(lane)")
        } else if let status {
            kind = MapDetailWords("SESSION · ") + MapDetailWords(status.word.uppercased(), live: status)
            // The run's first edit, never `span.edits`, which sorts.
            let firstEdit = [span.direct.first, span.delegated.first].compactMap { $0 }.min() ?? span.start
            var rest = " · on \(lane) since \(text.clock(firstEdit))"
            if conversation != nil { rest += " · \(profile)" }
            subtitle = MapDetailWords(status.word, live: status) + MapDetailWords(rest)
        } else {
            kind = MapDetailWords("SESSION · RUN \(run) OF \(runs)")
            subtitle = MapDetailWords("\(text.moment(span.start))–\(text.clock(span.end)) on \(lane)")
        }
        let elapsed = MapText.duration(facts.last.timeIntervalSince(facts.first))
        let branches = fig(facts.uniqueLanes.count, "Branch", "Branches")
        let figures = facts.cloud
            ? [fig(facts.cloudCommits.count, "Commit", "Commits"), fig("Elapsed", elapsed), branches]
            : [fig(facts.edits, "Edit", "Edits"), fig("Elapsed", elapsed), branches]
        var who = facts.cloud ? self.who([:], empty: "Cloud sessions record commits, not edits")
            : self.who([facts.sourceID: MapDetailShare(direct: facts.direct, delegated: facts.delegated)],
                       empty: "No edits recorded yet")
        if !facts.cloud && facts.spawned > 0 { who.right = "1 + \(facts.spawned) threads" }
        let thisRun = facts.cloud ? "\(run) of \(runs) on \(lane)"
            : "\(run) of \(runs) · \(GrowthText.edits(span.editCount)) on \(lane)"
        let last: MapDetailFact
        if status == .waiting, let session, let asks = SessionLabel.needsAction(session, showTitles: showTitles) {
            last = fact("Asks", asks)
        } else {
            last = fact("Active", facts.cloud ? MapDetailText.runs(runs)
                        : "\(MapText.duration(facts.active)) in \(MapDetailText.runs(runs))")
        }
        let action: MapDetailLensAction?
        if session != nil {
            action = .jump(.run(span.sessionKey, span.index))
        } else if let url = ProjectMap.cloudURL(span) {
            action = .open(url)
        } else {
            action = nil
        }
        let tint = color[span.sourceID] ?? .gray
        return MapDetailLens(kind: kind, glyph: facts.cloud ? .cloud(tint) : .profile(tint, live: status),
                             title: conversation ?? profile, subtitle: subtitle, figures: figures,
                             days: days(ink: sessionDays[span.sessionKey],
                                        ticks: (facts.cloud ? facts.cloudCommits : meanwhile(facts.key)).map(\.date),
                                        band: (span.start, span.live != nil ? map.now : span.end)),
                             who: who,
                             facts: [fact("This run", thisRun, middle: true), fact("Started", text.moment(facts.first)),
                                     fact("Path", MapDetailText.path(facts.lanePath), middle: true), last],
                             action: action)
    }

    // MARK: Commit

    private func commitLens(_ marker: ProjectMap.Marker) -> MapDetailLens {
        let landed = landedLane(marker)
        let list = markersByLane[marker.laneID] ?? []
        let position = positionOnLane[marker.sha] ?? 0
        let sha7 = String(marker.sha.prefix(7))
        let request = marker.pullRequest.map { "#\($0)" }
        let onLane = title(marker.laneID)
        var kind: String
        if marker.quietBranch != nil {
            kind = "MERGE · NO EDITS"
        } else if marker.kind == .squash {
            kind = "SQUASH MERGE"
        } else if marker.kind == .merge {
            kind = "MERGE COMMIT"
        } else {
            kind = landed != nil ? "COMMIT · LANDED A BRANCH" : "COMMIT"
        }
        if marker.cloudSession != nil { kind += " · CLOUD" }
        let subtitle: String
        let figures: [MapDetailFigure]
        let who: MapDetailWho
        let branch: String?
        let fourth: MapDetailFact
        if let quiet = marker.quietBranch {
            subtitle = ["Merged", request, "no edits recorded"].compactMap { $0 }.joined(separator: " · ")
            figures = [fig("PR", request), fig("Edits", "0"), fig("Time", text.clock(marker.date))]
            who = self.who([:], empty: "No edits recorded by an assistant")
            branch = quiet
            fourth = fact("PR", request)
        } else if let landed {
            let verb = marker.kind == .squash ? "Squash-merged" : "Merged"
            subtitle = ["\(verb) \(MapText.title(landed))", request, sha7].compactMap { $0 }.joined(separator: " · ")
            if landsMember(marker, of: landed) {
                // One member's merge: the stream's figures, as its own lens shows them, and no
                // lifetime, which would run from another member's fork.
                figures = [fig(landed.editCount, "Stream edit", "Stream edits"),
                           fig(landed.members.count, "Branch", "Branches"), fig("Merged", landed.returns.count.formatted())]
            } else {
                let lived = (landed.enteredBeforeWindow ? "≥" : "")
                    + MapText.duration(marker.date.timeIntervalSince(landed.forkedAt ?? landed.start))
                figures = [fig(landed.editCount, "Branch edit", "Branch edits"),
                           fig(landed.commitCount, "Commit", "Commits"), fig("Lived", lived)]
            }
            who = self.who(laneFacts[landed.id]?.bySource ?? [:], empty: "No edits recorded by an assistant")
            branch = "\(MapText.title(landed)) → \(onLane)"
            fourth = fact("Matched", matchNote(landed, sha: marker.sha))
        } else {
            if marker.kind == .squash {
                subtitle = "Squash merge\(request.map { " \($0)" } ?? "") · \(sha7)"
            } else if marker.kind == .merge {
                subtitle = "Merge into \(onLane) · \(sha7)"
            } else {
                subtitle = "\(sha7) on \(onLane)"
            }
            let carried = self.carried(marker)
            figures = [fig("Carried", carried.count.formatted()), fig(carried.sessions.count, "Session", "Sessions"),
                       fig("On branch", "\(position + 1)/\(list.count)")]
            who = self.who(carried.bySource, empty: "No edits on this branch since its previous commit")
            branch = onLane
            let gap = position > 0 && position - 1 < list.count
                ? "+\(MapText.duration(marker.date.timeIntervalSince(list[position - 1].date))) after the previous one"
                : "First on \(onLane) in range"
            fourth = fact("Gap", gap)
        }
        let with = marker.cloudSession != nil ? "From a cloud session"
            : (marker.coAuthors.isEmpty ? nil : marker.coAuthors.joined(separator: ", "))
        let committedColumn = column(of: marker.date)
        let committed = columns.indices.contains(committedColumn) ? "Committed \(columns[committedColumn].long)" : ""
        return MapDetailLens(kind: MapDetailWords(kind), glyph: .ring(bead: marker.isBead, landed: landed != nil),
                             title: marker.quietBranch ?? marker.subject, middle: marker.quietBranch != nil,
                             subtitle: MapDetailWords(subtitle), figures: figures,
                             days: days(ink: marker.quietBranch != nil ? nil : laneDays[landed?.id ?? marker.laneID],
                                        ticks: [marker.date], right: committed),
                             who: who,
                             facts: [fact("When", text.moment(marker.date)), fact("Branch", branch, middle: true),
                                     fact("With", with), fourth],
                             action: .copy(marker.sha, help: "Copy the commit's SHA"))
    }

    // MARK: Merge cluster

    private func clusterLens(_ markers: [ProjectMap.Marker]) -> MapDetailLens {
        guard let first = markers.first, let last = markers.last else { return makeProjectLens() }
        // Lanes points every member's merge at its stream, so count each lane once.
        var seen = Set<String>()
        let merged = markers.compactMap(\.mergedLaneID).filter { seen.insert($0).inserted }.compactMap { laneByID[$0] }
        var shares: [String: MapDetailShare] = [:]
        var ink = zeros
        for lane in merged {
            Self.merge(laneFacts[lane.id]?.bySource ?? [:], into: &shares)
            ink = Self.sum(ink, laneDays[lane.id])
        }
        let quiet = markers.filter { $0.quietBranch != nil }.count
        // Merges of a stream's members land only part of it, as a single merge's lens says.
        let partial = markers.contains { marker in landedLane(marker).map { landsMember(marker, of: $0) } ?? false }
        return MapDetailLens(kind: MapDetailWords("MERGES · \(markers.count)"), glyph: .capsule,
                             title: text.name(.cluster(markers)),
                             subtitle: MapDetailWords("on \(title(trunkID)) · \(text.moment(first.date))"),
                             figures: [fig(markers.count, "Merge", "Merges"),
                                       fig(markers.filter { $0.pullRequest != nil }.count, "PR", "PRs"),
                                       fig(merged.reduce(0) { $0 + $1.editCount },
                                           partial ? "Stream edit" : "Branch edit",
                                           partial ? "Stream edits" : "Branch edits")],
                             days: days(ink: ink, ticks: markers.map(\.date)),
                             who: who(shares, empty: "No edits recorded by an assistant"),
                             facts: [fact("First", "\(label(first)) · \(text.clock(first.date))", middle: true),
                                     fact("Last", "\(label(last)) · \(text.clock(last.date))", middle: true),
                                     fact("Quiet", quiet > 0 ? "\(quiet) merged with no edits" : "All have edits"),
                                     fact("Span", MapText.duration(last.date.timeIntervalSince(first.date)))])
    }

    // MARK: Branch lane

    private func laneLens(_ lane: ProjectMap.Lane) -> MapDetailLens {
        let facts = laneFacts[lane.id] ?? MapDetailLaneFacts()
        let from = lane.forkedAt ?? lane.start
        var kind: MapDetailWords
        if lane.kind == .folder {
            kind = MapDetailWords("WORKTREE · BRANCH UNKNOWN")
        } else if lane.isStream {
            kind = MapDetailWords("STREAM · \(lane.members.count) BRANCHES")
        } else if lane.merge != nil {
            kind = MapDetailWords("MERGED BRANCH")
        } else {
            kind = MapDetailWords(lane.deleted ? "DELETED BRANCH" : "OPEN BRANCH")
        }
        if lane.isLive {
            let status = liveStatus(onLane: lane.id)
            kind = kind + MapDetailWords(" · ") + MapDetailWords(status.word.uppercased(), live: status)
        } else if lane.isHead {
            kind = kind + MapDetailWords(" · CHECKED OUT")
        }
        let symbol = lane.kind == .folder ? "folder" : lane.isStream ? "square.stack.3d.up" : "arrow.triangle.branch"
        let figures = lane.isStream
            ? [fig(lane.editCount, "Edit", "Edits"), fig(lane.members.count, "Branch", "Branches"),
               fig("Merged", lane.returns.count.formatted())]
            : [fig(lane.editCount, "Edit", "Edits"), fig(facts.sessions.count, "Session", "Sessions"),
               fig(lane.commitCount, "Commit", "Commits")]
        let third: MapDetailFact
        if let merge = lane.merge {
            third = fact("Landed", text.moment(merge.date) + (merge.pullRequest.map { " · #\($0)" } ?? ""))
        } else {
            third = fact("Last edit", facts.lastEdit.map { text.moment($0) } ?? "None in range")
        }
        return MapDetailLens(kind: kind, glyph: .symbol(symbol, primary: false), title: MapText.title(lane), middle: true,
                             italic: lane.deleted, subtitle: MapDetailWords(laneHeadline(lane)), figures: figures,
                             days: days(ink: laneDays[lane.id], ticks: (markersByLane[lane.id] ?? []).map(\.date),
                                        band: (from, lane.merge?.date ?? lane.end)),
                             who: who(facts.bySource, empty: facts.cloudSessions > 0 ? "Only cloud sessions worked here"
                                      : "No edits recorded by an assistant"),
                             facts: [fact("Forked", text.moment(from) + (lane.enteredBeforeWindow ? " · began earlier" : "")),
                                     fact("Parent", title(lane.parentID ?? trunkID), middle: true), third, laneFourth(lane)],
                             action: lane.kind == .branch && !lane.isStream
                                ? .copy(lane.title, help: "Copy the branch name") : nil)
    }

    private func laneFourth(_ lane: ProjectMap.Lane) -> MapDetailFact {
        let from = lane.forkedAt ?? lane.start
        if let merge = lane.merge {
            var lived = (lane.enteredBeforeWindow ? "≥" : "") + MapText.duration(merge.date.timeIntervalSince(from))
            if let rank = pace(lane) { lived += " · \(rank)" }
            return fact("Lived", lived)
        }
        if lane.kind == .folder {
            let path = String(lane.id.dropFirst("folder:".count))
            return fact("Folder", (path as NSString).lastPathComponent, middle: true)
        }
        if lane.deleted { return fact("Ref", "Deleted; a session or the reflog names it") }
        if lane.isStream { return fact("Members", MapDetailText.list(lane.members, shown: 2), middle: true) }
        if lane.isLive || lane.isHead { return fact("Open for", MapText.duration(map.now.timeIntervalSince(from))) }
        return fact("Span", MapText.duration(lane.end.timeIntervalSince(from)))
    }

    // MARK: Trunk

    private func trunkLens(_ lane: ProjectMap.Lane) -> MapDetailLens {
        let facts = laneFacts[lane.id] ?? MapDetailLaneFacts()
        let commits = (markersByLane[lane.id] ?? []).filter { !$0.isBead }.count
        return MapDetailLens(kind: MapDetailWords(lane.isHead ? "DEFAULT BRANCH · CHECKED OUT" : "DEFAULT BRANCH"),
                             glyph: .symbol("arrow.triangle.branch", primary: true),
                             title: map.isGitCheckout ? MapText.title(lane) : (map.projectPath as NSString).lastPathComponent,
                             middle: true, subtitle: MapDetailWords(laneHeadline(lane)),
                             figures: [fig(lane.editCount, "Edit", "Edits"), fig(commits, "Commit", "Commits"),
                                       fig("Merged", mergeCount.formatted())],
                             days: days(ink: laneDays[lane.id], ticks: beads.map(\.date)),
                             who: who(facts.bySource, empty: "No edits recorded by an assistant"),
                             facts: [fact("Since", map.axis.segments.isEmpty ? nil : text.moment(map.axis.start)),
                                     fact("Root", map.rootCommitDate.map { "First commit " + text.moment($0) }
                                          ?? "Before this range"),
                                     fact("Quiet", "\(quietMergeCount) merged with no edits"),
                                     fact("Branches", "\(children[lane.id]?.count ?? 0) off it")])
    }

    // MARK: Family group

    private func groupLens(_ lanes: [ProjectMap.Lane]) -> MapDetailLens {
        var shares: [String: MapDetailShare] = [:]
        var ink = zeros
        var ticks: [Date] = []
        var keys = Set<String>()
        for lane in lanes {
            Self.merge(laneFacts[lane.id]?.bySource ?? [:], into: &shares)
            ink = Self.sum(ink, laneDays[lane.id])
            ticks += (markersByLane[lane.id] ?? []).map(\.date)
            keys.formUnion((laneFacts[lane.id]?.sessions ?? []).map(\.key))
        }
        let noEdits = lanes.allSatisfy { $0.editCount == 0 }
        let start = lanes.map { $0.forkedAt ?? $0.start }.min()
        let latest = lanes.map { $0.merge?.date ?? $0.end }.max()
        // A bundle's title already names its workflow run or prefix, so its members go by
        // what tells them apart: "agent 3" rather than "workflow 28a8e52d · agent 3".
        let titles = lanes.map(\.title)
        let members = MapText.bundle(of: lanes, in: map) != nil
            ? titles.map { ProjectMap.strandTitle($0, among: titles) } : lanes.map(MapText.title)
        return MapDetailLens(kind: MapDetailWords(noEdits ? "BRANCHES · NO EDITS" : "FAMILY · \(lanes.count) BRANCHES"),
                             glyph: .symbol("square.stack.3d.up", primary: false), title: MapText.groupTitle(lanes, in: map),
                             middle: true, subtitle: MapDetailWords(text.headline(.group(lanes))),
                             figures: [fig(lanes.reduce(0) { $0 + $1.editCount }, "Edit", "Edits"),
                                       fig(lanes.count, "Branch", "Branches"),
                                       fig("Landed", lanes.filter { $0.merge != nil }.count.formatted())],
                             days: days(ink: ink, ticks: ticks),
                             who: who(shares, empty: "No edits recorded by an assistant"),
                             facts: [fact("From", start.map { text.moment($0) }), fact("Latest", latest.map { text.moment($0) }),
                                     fact("Sessions", GrowthText.sessions(keys.count)),
                                     fact("Members", MapDetailText.list(members, shown: 3))])
    }

    // MARK: Idle fold

    private func foldLens(_ gap: TimeAxis.Segment) -> MapDetailLens {
        let context = foldContext(gap)
        let resumed: String?
        if case .run(let before)? = context.before, case .run(let after)? = context.after {
            resumed = before.sessionKey == after.sessionKey ? "Same session" : "Another session"
        } else {
            resumed = nil
        }
        let share = MapDetailText.percent(Int(gap.duration), Int(map.now.timeIntervalSince(map.axis.start)))
        return MapDetailLens(kind: MapDetailWords("IDLE"), glyph: .symbol("moon.zzz", primary: false),
                             title: text.name(.fold(gap)),
                             subtitle: MapDetailWords("\(text.moment(gap.start)) → \(text.moment(gap.end))"),
                             figures: [fig("Idle", MapText.idle(gap.duration)),
                                       fig("Rank", gapRank[gap.start].map { "\($0) of \(gapsByLength.count)" }),
                                       fig("Of range", share.map { "\($0)%" })],
                             days: days(ink: nil, ticks: [], band: (gap.start, gap.end),
                                        right: "Idle \(MapText.idle(gap.duration))"),
                             who: who([:], empty: "No edits while idle"),
                             facts: [fact("Before", neighborText(context.before, after: false), middle: true),
                                     fact("After", neighborText(context.after, after: true), middle: true),
                                     fact("Resumed", resumed),
                                     fact("Folds", "Pauses over \(MapText.idle(map.range.minimumGap)) fold")])
    }

    func neighborText(_ neighbor: MapDetailNeighbor?, after: Bool) -> String {
        switch neighbor {
        case .run(let run)?:
            return "\(shortName[run.sourceID] ?? "") on \(title(run.laneID)) · \(text.clock(after ? run.start : run.end))"
        case .commit(let marker)?:
            return "\(marker.sha.prefix(7)) on \(title(marker.laneID)) · \(text.clock(marker.date))"
        case nil:
            return "Nothing"
        }
    }
}

// MARK: - Body content

extension MapDetailIndex {
    /// The project's lists, memoized; the live sessions come from the store on every pass.
    func overviewBlocks() -> [MapDetailBlock] {
        if let memo = overviewMemo { return memo }
        var blocks: [MapDetailBlock] = []
        blocks.add(section("branches", "Busiest branches", branchesByEdits.prefix(30).map { laneRow($0) },
                           first: 5, hard: 30, count: branchesByEdits.count))
        let recent = sessionsByRecency.compactMap { sessions[$0] }.filter { $0.live == nil }
        blocks.add(section("sessions", "Recent sessions", recent.prefix(30).map { sessionRow($0) },
                           first: 5, hard: 30, count: recent.count))
        if map.isGitCheckout, !beads.isEmpty {
            blocks.add(section("merged", "Merged into \(title(trunkID))", beads.reversed().prefix(30).map { beadRow($0) },
                               first: 4, hard: 30, count: beads.count))
        }
        blocks.add(section("profiles", "Profiles", profileRows(nil), first: 99, hard: 99))
        blocks.add(section("pauses", "Longest pauses", gapsByLength.prefix(3).map { foldRow($0) }, first: 3, hard: 3))
        if map.range != .today, let hours = hoursBlock() { blocks.append(.hours(hours)) }
        overviewMemo = blocks
        return blocks
    }

    /// The pinned item's deep view, memoized per item; a live session's Now box is added by the panel.
    func deepBlocks(_ hit: MapHit) -> [MapDetailBlock] {
        if let memo = deepMemo[hit.id] { return memo }
        let blocks: [MapDetailBlock]
        switch hit {
        case .live(let span), .span(let span): blocks = sessionBlocks(span)
        case .commit(let marker): blocks = commitBlocks(marker)
        case .cluster(let markers):
            let rows = markers.map { marker -> MapDetailRow in
                commitRow(marker, title: label(marker), detail: "\(text.moment(marker.date)) · \(landedEdits(marker))")
            }
            blocks = [section("merges", "Merges", rows, first: 12, hard: 40)].compactMap { $0 }
        case .lane(let lane): blocks = lane.kind == .trunk ? trunkBlocks(lane) : laneBlocks(lane)
        case .group(let lanes): blocks = groupBlocks(lanes)
        case .fold(let gap): blocks = foldBlocks(gap)
        }
        deepMemo[hit.id] = blocks
        return blocks
    }

    private func section(_ id: String, _ title: String, _ rows: [MapDetailRow], first: Int, hard: Int,
                         count: Int? = nil, note: String? = nil, trailing: String? = nil) -> MapDetailBlock? {
        guard !rows.isEmpty else { return nil }
        let kept = Array(rows.prefix(hard))
        return .section(MapDetailSection(id: id, title: title, count: count ?? rows.count, trailing: trailing, rows: kept,
                                         first: first, hard: hard, note: note,
                                         maximum: kept.compactMap(\.barValue).max() ?? 0))
    }

    // MARK: Rows

    private func laneLead(_ lane: ProjectMap.Lane) -> MapDetailLead {
        if lane.merge != nil { return .symbol("arrow.triangle.merge", dim: false) }
        if lane.isLive { return .status(liveStatus(onLane: lane.id)) }
        if lane.kind == .folder { return .symbol("folder", dim: false) }
        if lane.isStream { return .symbol("square.stack.3d.up", dim: false) }
        return .symbol("arrow.triangle.branch", dim: lane.deleted)
    }

    private func laneRow(_ lane: ProjectMap.Lane, detail: String? = nil, edits: Int? = nil) -> MapDetailRow {
        let value = edits ?? lane.editCount
        let last = laneFacts[lane.id]?.lastEdit ?? lane.end
        return MapDetailRow(id: "lane:" + lane.id, lead: laneLead(lane), title: MapText.title(lane), italic: lane.deleted,
                            middle: true, detail: detail ?? "\(laneHeadline(lane)) · \(text.moment(last))",
                            value: value > 0 ? value.formatted() : "—", barValue: value, target: .pin(.lane(lane.id)))
    }

    private func lead(_ sourceID: String) -> MapDetailLead {
        let tint = color[sourceID] ?? .gray
        return sourceID == ProjectMap.cloudSourceID ? .cloud(tint) : .dot(tint)
    }

    private func sessionRow(_ facts: MapDetailSession) -> MapDetailRow {
        let detail: String
        if facts.cloud {
            detail = "claude.ai · \(MapDetailText.commits(facts.cloudCommits.count))"
        } else {
            let others = facts.uniqueLanes.count - 1
            // A head stream's title already ends in "+N".
            let stream = facts.uniqueLanes.first.flatMap { laneByID[$0] }?.isStream == true
            let more = others > 0 ? (stream ? " and \(others) more" : " +\(others)") : ""
            detail = "\(facts.uniqueLanes.first.map { title($0) } ?? "")\(more) · \(text.moment(facts.last))"
        }
        return MapDetailRow(id: "run:" + facts.key, lead: lead(facts.sourceID), title: name[facts.sourceID] ?? "",
                            detail: detail, value: facts.cloud ? "—" : facts.edits.formatted(),
                            barValue: facts.cloud ? nil : facts.edits, barColor: color[facts.sourceID],
                            target: .pin(.run(facts.key, facts.runs.last?.index ?? 0)))
    }

    private func laneSessionRow(_ entry: MapDetailLaneSession) -> MapDetailRow {
        let cloud = entry.sourceID == ProjectMap.cloudSourceID
        let status = MapDetailLive.of(entry.live)
        return MapDetailRow(id: "run:" + entry.key, lead: status.map { MapDetailLead.status($0) } ?? lead(entry.sourceID),
                            title: name[entry.sourceID] ?? "",
                            detail: "\(MapDetailText.runs(entry.runs)) · last \(text.moment(entry.last))",
                            value: cloud ? "—" : entry.edits.formatted(), barValue: cloud ? nil : entry.edits,
                            barColor: color[entry.sourceID], target: .pin(.run(entry.key, entry.latestRunIndex)))
    }

    private func runRow(_ run: ProjectMap.Span, cloud: Bool) -> MapDetailRow {
        let detail: String
        if let status = MapDetailLive.of(run.live) {
            // Still going, so it runs to now. The status says nothing of when it began: a
            // session may have needed input for minutes of an hour-long run.
            detail = "\(text.moment(run.start))–now · \(status.word)"
        } else {
            detail = "\(text.moment(run.start))–\(text.clock(run.end)) · "
                + MapText.duration(run.end.timeIntervalSince(run.start))
        }
        return MapDetailRow(id: run.id, lead: lead(run.sourceID), title: title(run.laneID), middle: true, detail: detail,
                            value: cloud ? "—" : run.editCount.formatted(), barValue: cloud ? nil : run.editCount,
                            barColor: color[run.sourceID], target: .pin(.run(run.sessionKey, run.index)))
    }

    /// A commit row; its value is `value`, else the short SHA unless `sha` is false.
    private func commitRow(_ marker: ProjectMap.Marker, title: String? = nil, detail: String,
                           value: String? = nil, sha: Bool = true) -> MapDetailRow {
        MapDetailRow(id: "commit:" + marker.sha, lead: .ring, title: title ?? marker.subject, middle: title != nil,
                     detail: detail, value: value ?? (sha ? String(marker.sha.prefix(7)) : nil), mono: value == nil,
                     target: .pin(.commit(marker.sha)))
    }

    private func beadRow(_ marker: ProjectMap.Marker) -> MapDetailRow {
        commitRow(marker, title: label(marker), detail: text.moment(marker.date) + " · " + landedEdits(marker))
    }

    private func foldRow(_ gap: TimeAxis.Segment) -> MapDetailRow {
        MapDetailRow(id: "fold:\(gap.start.timeIntervalSince1970)", lead: .symbol("moon.zzz", dim: false),
                     title: "Idle \(MapText.idle(gap.duration))",
                     detail: "\(text.moment(gap.start)) → \(text.moment(gap.end))", target: .pin(.fold(gap.start)))
    }

    /// Profiles to focus: every one with the project's totals, or those in `shares` with theirs.
    /// A lane passes its own cloud session count, since `profileTotals` holds the project's.
    private func profileRows(_ shares: [String: MapDetailShare]?, cloudSessions: Int? = nil) -> [MapDetailRow] {
        profileOrder.filter { shares == nil || shares?[$0] != nil }.map { id -> MapDetailRow in
            let totals = profileTotals[id] ?? MapDetailTotals()
            let share = shares?[id] ?? MapDetailShare(direct: totals.direct, delegated: totals.delegated)
            let cloud = id == ProjectMap.cloudSourceID
            let detail: String
            if cloud {
                detail = "\(GrowthText.sessions(cloudSessions ?? totals.sessions)) on claude.ai"
            } else if shares != nil {
                detail = "\(share.direct.formatted()) direct · \(share.delegated.formatted()) by subagents"
            } else {
                let delegated = MapDetailText.percent(share.delegated, share.total) ?? 0
                detail = "\(GrowthText.sessions(totals.sessions)) · \(delegated)% by subagents"
            }
            return MapDetailRow(id: "profile:" + id, lead: lead(id), title: name[id] ?? "", detail: detail,
                                value: cloud ? "—" : share.total.formatted(), barValue: cloud ? nil : share.total,
                                barColor: color[id], target: .focus(id))
        }
    }

    private func hoursBlock() -> MapDetailHours? {
        guard let top = projectHours.indices.max(by: { projectHours[$0] < projectHours[$1] }),
              projectHours[top] > 0 else { return nil }
        let rollover = calendar.rolloverHour
        let most = "Most at \(DayFormat.hour((top + rollover) % 24)):00"
        return MapDetailHours(values: projectHours, labels: [0, 6, 12, 18].map { DayFormat.hour(($0 + rollover) % 24) },
                              trailing: "\(most) · \(GrowthText.edits(projectHours[top]))",
                              accessibilityValue: "\(most), \(GrowthText.edits(projectHours[top]))")
    }

    // MARK: Strips

    /// Runs over the map's folded axis, from the first run shown to the last. With `more`, the
    /// last row is a "+N more" row gathering the rest, dimmed like the session strip's.
    private func strip(_ title: String, rows: [(label: String, runs: [ProjectMap.Span])],
                       more: Bool = false) -> MapDetailBlock? {
        let all = rows.flatMap { $0.runs }
        guard let start = all.map({ $0.start }).min(),
              let end = all.map({ $0.live != nil ? map.now : $0.end }).max() else { return nil }
        let scale = MapDetailScale(axis: map.axis, from: start, to: end)
        var runs: [MapDetailStrip.Run] = []
        var spoken: [String] = []
        for (row, entry) in rows.enumerated() {
            let dim = more && row == rows.count - 1
            for run in entry.runs {
                runs.append(MapDetailStrip.Run(row: row, from: scale.x(run.start), to: scale.x(run.end),
                                               color: color[run.sourceID] ?? .gray,
                                               hatched: run.delegated.count > run.direct.count,
                                               cloud: run.sourceID == ProjectMap.cloudSourceID, current: false, dim: dim))
            }
            let edits = entry.runs.reduce(0) { $0 + $1.editCount }
            spoken.append("\(entry.label): \(MapDetailText.runs(entry.runs.count)), \(GrowthText.edits(edits))")
        }
        let stripRows = rows.enumerated().map { pair in
            MapDetailStrip.Row(label: pair.element.label, dim: more && pair.offset == rows.count - 1)
        }
        return .strip(MapDetailStrip(title: title, rows: stripRows,
                                     runs: runs, links: [], thread: nil, folds: scale.folds,
                                     accessibilityValue: spoken.joined(separator: "; ")))
    }

    /// Strip labels for lanes shown together. Workflow agents' full names clip alike in the
    /// narrow label column ("workfl…gent 1"), so agents keep only what tells them apart from
    /// the other agents shown: "agent 3", or "28a8e52d · agent 3" across runs.
    private func rowLabels(_ ids: [String]) -> [String] {
        let agents = ids.compactMap { laneByID[$0]?.title }.filter { ProjectMap.workflowAgent($0) != nil }
        return ids.map { id in
            guard let raw = laneByID[id]?.title, ProjectMap.workflowAgent(raw) != nil else { return title(id) }
            return ProjectMap.strandTitle(raw, among: agents)
        }
    }

    /// A lane's top five sessions by their edits there, with only their runs on it.
    private func sessionsStrip(_ lane: ProjectMap.Lane) -> MapDetailBlock? {
        let facts = laneFacts[lane.id] ?? MapDetailLaneFacts()
        let top = facts.sessions.sorted { $0.edits != $1.edits ? $0.edits > $1.edits : $0.key < $1.key }.prefix(5)
        let runs = runsByLane[lane.id] ?? []
        // Two sessions of one profile are told apart by when they began here.
        let repeated = MapDetailText.repeated(top.map { shortName[$0.sourceID] ?? "" })
        let rows = top.map { entry -> (label: String, runs: [ProjectMap.Span]) in
            let profile = shortName[entry.sourceID] ?? ""
            return (label: repeated.contains(profile) ? "\(profile) \(text.clock(entry.first))" : profile,
                    runs: runs.filter { $0.sessionKey == entry.key })
        }
        return strip("Sessions over time", rows: rows)
    }

    /// A session's branches, its runs joined where it moved on, the current run ringed and the
    /// live run's thread on to the right edge.
    private func sessionStrip(_ facts: MapDetailSession, current: ProjectMap.Span) -> MapDetailBlock {
        let ranked = facts.uniqueLanes.sorted { lhs, rhs in
            let left = facts.editsByLane[lhs] ?? 0
            let right = facts.editsByLane[rhs] ?? 0
            return left != right ? left > right : lhs < rhs
        }
        let shown = ranked.count > 5 ? Array(ranked.prefix(4)) : ranked
        var rowOf: [String: Int] = [:]
        for (row, id) in shown.enumerated() { rowOf[id] = row }
        var rows = rowLabels(shown).map { MapDetailStrip.Row(label: $0, dim: false) }
        if ranked.count > 5 { rows.append(MapDetailStrip.Row(label: "+\(ranked.count - 4) more", dim: true)) }
        let scale = MapDetailScale(axis: map.axis, from: facts.first, to: facts.last)
        let tint = color[facts.sourceID] ?? .gray
        let runs = facts.runs.map { run in
            MapDetailStrip.Run(row: rowOf[run.laneID] ?? 4, from: scale.x(run.start), to: scale.x(run.end), color: tint,
                               hatched: run.delegated.count > run.direct.count, cloud: facts.cloud,
                               current: run.index == current.index, dim: rowOf[run.laneID] == nil)
        }
        // The main field's thread rule: runs side by side are not a move, so a run links from the
        // one that reached furthest only when nothing of the session was still running as it
        // began. A bundle's strands are side by side work too and never link.
        var links: [MapDetailStrip.Link] = []
        var latest: ProjectMap.Span?
        for run in facts.runs.sorted(by: { ($0.start, $0.index) < ($1.start, $1.index) }) {
            defer { if run.end >= latest?.end ?? .distantPast { latest = run } }
            guard let from = latest, from.end <= run.start else { continue }
            if let bundle = laneByID[from.laneID]?.bundle, bundle == laneByID[run.laneID]?.bundle { continue }
            links.append(MapDetailStrip.Link(fromRow: rowOf[from.laneID] ?? 4, fromX: scale.x(from.end),
                                             toRow: rowOf[run.laneID] ?? 4, toX: scale.x(run.start), color: tint))
        }
        let liveRun = facts.runs.firstIndex { $0.live != nil }.map { runs[$0] }
        let spoken = rows.enumerated().map { pair -> String in
            let mine = facts.runs.filter { (rowOf[$0.laneID] ?? 4) == pair.offset }
            let edits = mine.reduce(0) { $0 + $1.editCount }
            return "\(pair.element.label): \(MapDetailText.runs(mine.count)), \(GrowthText.edits(edits))"
        }
        return .strip(MapDetailStrip(title: "Branches over time", rows: rows, runs: runs, links: links,
                                     thread: liveRun, folds: scale.folds,
                                     accessibilityValue: spoken.joined(separator: "; ")))
    }

    // MARK: Session

    private func sessionBlocks(_ span: ProjectMap.Span) -> [MapDetailBlock] {
        guard let facts = sessions[span.sessionKey] else { return [] }
        var blocks: [MapDetailBlock] = []
        blocks.append(.buttons([.focus(id: facts.sourceID, name: shortName[facts.sourceID] ?? "")]))
        blocks.append(sessionStrip(facts, current: span))
        blocks.add(section("runs", "Runs", facts.runs.reversed().map { runRow($0, cloud: facts.cloud) },
                           first: 6, hard: 40))
        let lanes = facts.uniqueLanes.compactMap { laneByID[$0] }.sorted { lhs, rhs in
            let left = facts.editsByLane[lhs.id] ?? 0
            let right = facts.editsByLane[rhs.id] ?? 0
            return left != right ? left > right : lhs.id < rhs.id
        }
        blocks.add(section("lanes", "Branches", lanes.map { lane in
            laneRow(lane, detail: laneHeadline(lane), edits: facts.editsByLane[lane.id] ?? 0)
        }, first: 6, hard: 30))
        let commits = facts.cloud ? facts.cloudCommits : meanwhile(facts.key)
        let commitRows = commits.reversed().prefix(40).map { marker in
            commitRow(marker, detail: "\(marker.sha.prefix(7)) · \(title(marker.laneID)) · \(text.clock(marker.date))",
                      sha: false)
        }
        blocks.add(section("commits", facts.cloud ? "Its commits" : "Commits on its branches while it ran",
                           Array(commitRows), first: 6, hard: 40, count: commits.count))
        blocks.append(.details([
            MapDetailFact(label: "Session", value: facts.sessionID, middle: true, mono: true),
            MapDetailFact(label: "Threads", value: facts.spawned > 0 ? "1 + \(facts.spawned) spawned" : "1"),
            MapDetailFact(label: "Edits",
                          value: "\(facts.direct.formatted()) direct · \(facts.delegated.formatted()) by subagents"),
            MapDetailFact(label: "Hours", value: "\(facts.hours) h with edits")
        ]))
        return blocks
    }

    // MARK: Commit

    private func commitBlocks(_ marker: ProjectMap.Marker) -> [MapDetailBlock] {
        var blocks: [MapDetailBlock] = []
        let with = marker.coAuthors.isEmpty ? nil : "With \(marker.coAuthors.joined(separator: ", "))"
        blocks.append(.message(subject: marker.subject, sha: marker.sha, with: with))
        let sessionRun = cloudRun(of: marker)
        if let sessionRun, let url = ProjectMap.cloudURL(sessionRun) {
            blocks.append(.buttons([.open(url, title: "Open session")]))
        }
        let landed = landedLane(marker)
        if let landed {
            blocks.add(section("landed", "Landed branch", [laneRow(landed, detail: laneHeadline(landed))], first: 1,
                               hard: 1, note: matchNote(landed, sha: marker.sha)))
        }
        let also = (lanesMergedBy[marker.sha] ?? []).filter { $0 != landed?.id }.compactMap { laneByID[$0] }
        blocks.add(section("also", "Also landed here", also.map { laneRow($0) }, first: 6, hard: 30))
        if marker.quietBranch == nil {
            let carried = self.carried(marker)
            let top = carried.sessions.prefix(5)
            // Two sessions of one profile are told apart by when they began.
            let repeated = MapDetailText.repeated(top.map { name[$0.sourceID] ?? "" })
            let rows = top.map { entry -> MapDetailRow in
                let profile = name[entry.sourceID] ?? ""
                var detail = "on \(title(marker.laneID))"
                if repeated.contains(profile), let first = sessions[entry.key]?.first {
                    detail += " · began \(text.moment(first))"
                }
                return MapDetailRow(id: "run:" + entry.key, lead: lead(entry.sourceID), title: profile, detail: detail,
                                    value: entry.count.formatted(), barValue: entry.count, barColor: color[entry.sourceID],
                                    target: .pin(.run(entry.key, entry.runIndex)))
            }
            blocks.add(section("carried", "Edits it carried", Array(rows), first: 5, hard: 5,
                               count: carried.sessions.count,
                               note: "Edits on this branch since its previous commit, within 12 h"))
        }
        let list = markersByLane[marker.laneID] ?? []
        if let position = positionOnLane[marker.sha], position < list.count {
            var rows: [MapDetailRow] = []
            if position > 0 {
                let earlier = list[position - 1]
                rows.append(commitRow(earlier, detail: "Earlier · \(text.clock(earlier.date))"))
            }
            if position + 1 < list.count {
                let later = list[position + 1]
                rows.append(commitRow(later, detail: "Later · \(text.clock(later.date))"))
            }
            blocks.add(section("neighbors", "On \(title(marker.laneID))", rows, first: 2, hard: 2))
        }
        if let sessionRun {
            blocks.add(section("cloud", "Cloud session", [runRow(sessionRun, cloud: true)], first: 1, hard: 1))
        }
        return blocks
    }

    // MARK: Lanes

    private func laneBlocks(_ lane: ProjectMap.Lane) -> [MapDetailBlock] {
        let facts = laneFacts[lane.id] ?? MapDetailLaneFacts()
        var blocks: [MapDetailBlock] = []
        blocks.add(sessionsStrip(lane))
        if let merge = lane.merge {
            let name = merge.pullRequest.map { "#\($0)" } ?? String(merge.sha.prefix(7))
            let row = MapDetailRow(id: "landing", lead: .ring, title: "\(name) into \(title(merge.intoLaneID))",
                                   middle: true, detail: text.moment(merge.date),
                                   target: markerBySHA[merge.sha] != nil ? .pin(.commit(merge.sha)) : .text)
            blocks.add(section("landing", "Landing", [row], first: 1, hard: 1, note: matchNote(lane, sha: merge.sha)))
        }
        blocks.add(section("sessions", "Sessions", facts.sessions.map { laneSessionRow($0) }, first: 6, hard: 30))
        let commits = markersByLane[lane.id] ?? []
        blocks.add(section("commits", "Commits", commits.reversed().prefix(40).map { marker in
            commitRow(marker, detail: text.moment(marker.date), value: marker.pullRequest.map { "#\($0)" })
        }, first: 6, hard: 40, count: commits.count))
        let mergedIDs = mergedInto[lane.id] ?? []
        blocks.add(section("merged", "Merged into it", mergedIDs.compactMap { laneByID[$0] }.map { laneRow($0) },
                           first: 6, hard: 30))
        let merged = Set(mergedIDs)
        let off = (children[lane.id] ?? []).filter { !merged.contains($0) }.compactMap { laneByID[$0] }
            .sorted { $0.editCount > $1.editCount }
        blocks.add(section("children", "Branches off it", off.map { laneRow($0) }, first: 6, hard: 20))
        if lane.isStream {
            // Members are not lanes in this map, so their rows pin nothing.
            let members = lane.members.enumerated().map { pair in
                MapDetailRow(id: "member:\(pair.offset)", lead: .symbol("arrow.triangle.branch", dim: false),
                             title: pair.element, middle: true, detail: "", target: .text)
            }
            blocks.add(section("members", "Members", members, first: 8, hard: 40))
            let returns = lane.returns.reversed().map { merge -> MapDetailRow in
                let name = merge.pullRequest.map { "#\($0)" } ?? String(merge.sha.prefix(7))
                return MapDetailRow(id: "commit:" + merge.sha, lead: .ring, title: "\(name) into \(title(merge.intoLaneID))",
                                    middle: true, detail: text.moment(merge.date),
                                    target: markerBySHA[merge.sha] != nil ? .pin(.commit(merge.sha)) : .text)
            }
            blocks.add(section("returns", "Its merges", returns, first: 6, hard: 40))
        }
        if lane.kind == .folder {
            let path = String(lane.id.dropFirst("folder:".count))
            blocks.append(.path((path as NSString).abbreviatingWithTildeInPath,
                                note: "Edits landed in a worktree whose branch was never recorded."))
        }
        blocks.add(section("profiles", "Profiles", profileRows(facts.bySource, cloudSessions: facts.cloudSessions),
                           first: 99, hard: 99))
        return blocks
    }

    private func trunkBlocks(_ lane: ProjectMap.Lane) -> [MapDetailBlock] {
        let facts = laneFacts[lane.id] ?? MapDetailLaneFacts()
        let name = title(lane.id)
        var blocks: [MapDetailBlock] = []
        blocks.add(sessionsStrip(lane))
        blocks.add(section("merged", "Merged into \(name)", beads.reversed().prefix(40).map { beadRow($0) },
                           first: 6, hard: 40, count: beads.count))
        let plain = (markersByLane[lane.id] ?? []).filter { !$0.isBead }
        blocks.add(section("commits", "Commits on \(name)", plain.reversed().prefix(40).map { marker in
            commitRow(marker, detail: text.moment(marker.date))
        }, first: 6, hard: 40, count: plain.count))
        let off = (children[lane.id] ?? []).compactMap { laneByID[$0] }.sorted { $0.editCount > $1.editCount }
        blocks.add(section("children", "Busiest branches off it", off.prefix(20).map { laneRow($0) }, first: 6, hard: 20,
                           count: off.count))
        blocks.add(section("sessions", "Sessions", facts.sessions.prefix(30).map { laneSessionRow($0) }, first: 6,
                           hard: 30, count: facts.sessions.count))
        blocks.add(section("profiles", "Profiles", profileRows(facts.bySource, cloudSessions: facts.cloudSessions),
                           first: 99, hard: 99))
        return blocks
    }

    private func groupBlocks(_ lanes: [ProjectMap.Lane]) -> [MapDetailBlock] {
        let members = lanes.sorted { $0.editCount != $1.editCount ? $0.editCount > $1.editCount : $0.id < $1.id }
        var blocks: [MapDetailBlock] = []
        // Five rows at most, as in a session's strip: past five, four and a dim row for the rest.
        let shown = members.count > 5 ? Array(members.prefix(4)) : members
        let labels = rowLabels(shown.map(\.id))
        var rows: [(label: String, runs: [ProjectMap.Span])] = zip(shown, labels).map { lane, label in
            (label: label, runs: runsByLane[lane.id] ?? [])
        }
        if members.count > 5 {
            rows.append((label: "+\(members.count - 4) more",
                         runs: members.dropFirst(4).flatMap { runsByLane[$0.id] ?? [] }))
        }
        blocks.add(strip("Branches over time", rows: rows, more: members.count > 5))
        blocks.add(section("members", "Branches", members.map { lane in
            laneRow(lane, detail: "\(laneHeadline(lane)) · \(text.moment(lane.end))")
        }, first: 10, hard: 40))
        var byKey: [String: MapDetailLaneSession] = [:]
        for lane in lanes {
            for entry in laneFacts[lane.id]?.sessions ?? [] {
                guard var merged = byKey[entry.key] else {
                    byKey[entry.key] = entry
                    continue
                }
                merged.edits += entry.edits
                merged.runs += entry.runs
                merged.first = min(merged.first, entry.first)
                merged.last = max(merged.last, entry.last)
                merged.latestRunIndex = max(merged.latestRunIndex, entry.latestRunIndex)
                merged.live = merged.live ?? entry.live
                byKey[entry.key] = merged
            }
        }
        let across = byKey.values.sorted { $0.last != $1.last ? $0.last > $1.last : $0.key < $1.key }
        blocks.add(section("sessions", "Sessions across them", across.map { laneSessionRow($0) }, first: 6, hard: 30))
        return blocks
    }

    // MARK: Fold

    private func foldBlocks(_ gap: TimeAxis.Segment) -> [MapDetailBlock] {
        let context = foldContext(gap)
        var rows: [MapDetailRow] = []
        if let row = neighborRow(context.before, label: "Before", after: false) { rows.append(row) }
        if let row = neighborRow(context.after, label: "After", after: true) { rows.append(row) }
        var blocks: [MapDetailBlock] = []
        blocks.add(section("around", "Around the pause", rows, first: 2, hard: 2))
        let others = gapsByLength.filter { $0.start != gap.start }.prefix(3).map { foldRow($0) }
        blocks.add(section("pauses", "Other long pauses", Array(others), first: 3, hard: 3))
        return blocks
    }

    private func neighborRow(_ neighbor: MapDetailNeighbor?, label: String, after: Bool) -> MapDetailRow? {
        switch neighbor {
        case .run(let run)?:
            return MapDetailRow(id: label, lead: lead(run.sourceID), title: "\(label) · \(name[run.sourceID] ?? "")",
                                detail: neighborText(neighbor, after: after), target: .pin(.run(run.sessionKey, run.index)))
        case .commit(let marker)?:
            return MapDetailRow(id: label, lead: .ring, title: "\(label) · \(marker.subject)",
                                detail: neighborText(neighbor, after: after), target: .pin(.commit(marker.sha)))
        case nil:
            return nil
        }
    }
}

/// The map's folded axis between two moments, as fractions of a strip's width.
private struct MapDetailScale {
    let axis: TimeAxis
    let lower: Double
    let upper: Double

    init(axis: TimeAxis, from: Date, to: Date) {
        self.axis = axis
        lower = axis.position(of: from)
        upper = axis.position(of: to)
    }

    /// Everything sits in the middle when the moments are too close to tell apart.
    func x(_ date: Date) -> Double {
        guard upper - lower >= 1e-4 else { return 0.5 }
        return min(1, max(0, (axis.position(of: date) - lower) / (upper - lower)))
    }

    var folds: [ClosedRange<Double>] {
        guard upper - lower >= 1e-4 else { return [] }
        return axis.gaps.compactMap { gap -> ClosedRange<Double>? in
            guard gap.upper > lower, gap.lower < upper else { return nil }
            let from = max(0, (gap.lower - lower) / (upper - lower))
            let to = min(1, (gap.upper - lower) / (upper - lower))
            return from <= to ? from...to : nil
        }
    }
}
