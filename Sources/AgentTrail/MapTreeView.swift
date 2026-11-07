import AppKit
import SwiftUI
import AgentTrailCore

// MARK: - Tree mode

/// The Map as a tree of branches off main, families folded into nodes.
///
/// Depth runs left to right: main, then integration branches, then the
/// branches merged into them. Each link is a river as wide as the edits that
/// flowed back through it; each node is a ring split by profile, hatched where
/// subagents made the edits. Families of related branches stack into one node
/// until a click opens them, and a day strip on the right keeps when the work
/// happened.
///
/// A hover never runs this body. The tree is recorded once per layout, focused
/// profile and appearance; only the layers that draw an emphasis follow the
/// pointer: a row highlight under the tree, and over it a veil with the lit
/// items drawn again, the hovered item's path to main and its ring. Each of them
/// fades or crossfades rather than switching in one frame.
struct MapTreeView: View {
    let context: MapCanvasContext
    /// Written on hover and click, never observed here: only the emphasis layers follow it.
    let hover: MapHoverModel

    @Environment(\.colorScheme) private var colorScheme
    /// The layout lasts until the map, the size or the opened families change, so hovering only redraws.
    @State private var cache = MapTreeCache()
    /// Families opened by a click, keyed by their parent branch and family.
    @State private var expanded: Set<String> = []
    /// The day column under the pointer and the day a click pinned. A reference this view
    /// never observes, so a hovered column redraws only the layers that show the filter.
    @State private var pointer = MapTreePointer()

    /// Spelled out: the private state above would otherwise make the memberwise initializer private.
    init(context: MapCanvasContext, hover: MapHoverModel) {
        self.context = context
        self.hover = hover
    }

    var body: some View {
        // Clamped here too, so widening a wide window reuses the cached layout.
        let layoutSize = CGSize(width: min(context.size.width, MapTreeLayout.maxLayoutWidth), height: context.size.height)
        let layout = cache.layout(map: context.map, sourceIDs: context.sources.map(\.id), calendar: context.calendar,
                                  size: layoutSize, expanded: expanded)
        let key = MapStaticKey(layout: cache.generation, focusSourceID: context.focusSourceID, colorScheme: colorScheme)
        let projectName = (context.map.projectPath as NSString).lastPathComponent
        let rangeName = context.map.range.title.lowercased()
        let colors = Dictionary(layout.sourceIDs.map { ($0, context.color($0)) }, uniquingKeysWith: { first, _ in first })
        let hover = self.hover
        let pointer = self.pointer
        VStack(spacing: 0) {
            header(layout, key: key, colors: colors)
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    MapTreeRowUnderlay(layout: layout, generation: key.layout, hover: hover, pointer: pointer)
                    MapStaticCanvas(key: key) { graphics, size in
                        let style = MapTreeStyle(hatches: layout.hatches, colors: colors, in: graphics.environment)
                        let pass = MapTreePass(layout: layout, focusSourceID: key.focusSourceID, kept: nil)
                        MapTreePainter.drawBody(layout, style: style, pass: pass, thread: nil, size: size, in: &graphics)
                    }
                    .equatable()
                    MapTreeBodyOverlay(layout: layout, key: key, colors: colors, hover: hover, pointer: pointer)
                    ForEach(layout.liveMarks.filter { !$0.inHeader }) { mark in
                        StatusGlyph(kind: mark.kind, size: 10, animates: context.animatesLive)
                            .position(mark.point)
                    }
                }
                .frame(width: layout.width, height: layout.bodyHeight, alignment: .topLeading)
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point): hover.hover(layout.target(at: point)?.id)
                    case .ended: hover.hover(nil)
                    }
                }
                .gesture(SpatialTapGesture().onEnded { value in tap(layout.target(at: value.location), layout: layout) })
                // Centered under the header, which the stack centers, when the layout stops short of a
                // wide window. The pointer handlers above read the layout's own coordinates.
                .frame(maxWidth: .infinity)
            }
            .scrollDisabled(!layout.scrolls)
            // Never: a legacy scroller would take its width from the trailing edge, over today's
            // column, while the header above still draws that column in full.
            .scrollIndicators(.never)
        }
        .frame(width: context.size.width, height: context.size.height, alignment: .topLeading)
        .onChange(of: context.map.projectPath) { _, _ in
            expanded = []
            pointer.pin(nil)
        }
        .onChange(of: context.map.range) { _, _ in
            pointer.pin(nil)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Branch tree of \(projectName), \(rangeName)")
        .accessibilityValue(layout.accessibilitySummary)
    }

    /// The caption, the day columns and the trunk's own edits, pinned over the tree.
    private func header(_ layout: MapTreeLayout, key: MapStaticKey, colors: [String: Color]) -> some View {
        let hover = self.hover
        let pointer = self.pointer
        return ZStack(alignment: .topLeading) {
            MapTreeHeaderColumns(layout: layout, key: key, pointer: pointer)
            MapStaticCanvas(key: key) { graphics, size in
                let style = MapTreeStyle(hatches: layout.hatches, colors: colors, in: graphics.environment)
                MapTreePainter.drawHeader(layout, style: style, focusSourceID: key.focusSourceID, size: size, in: &graphics)
            }
            .equatable()
            ForEach(layout.liveMarks.filter(\.inHeader)) { mark in
                StatusGlyph(kind: mark.kind, size: 10, animates: context.animatesLive)
                    .position(mark.point)
            }
        }
        .frame(width: layout.width, height: layout.headerHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let target = layout.headerTarget(at: point)
                pointer.hoverColumn(target.column)
                hover.hover(target.id)
            case .ended:
                pointer.hoverColumn(nil)
                hover.hover(nil)
            }
        }
        .gesture(SpatialTapGesture().onEnded { value in
            let target = layout.headerTarget(at: value.location)
            if let column = target.column, layout.columns.indices.contains(column) {
                let current: Int? = layout.columnIndex(holding: pointer.pinnedDay)
                pointer.pin(current == column ? nil : layout.columns[column].first)
            } else {
                hover.select(target.id)
            }
        })
    }

    /// A family opens or closes in place; anything else selects.
    private func tap(_ target: MapTreeTarget?, layout: MapTreeLayout) {
        guard let key = target?.toggle else {
            hover.select(target?.id)
            return
        }
        if NSEvent.modifierFlags.contains(.option) {
            // Option-click opens every family, or closes them all when any is open. It asks the
            // layout, since `expanded` may still hold families this map no longer forms.
            expanded = layout.openedKeys.isEmpty ? Set(layout.groupKeys) : []
        } else if expanded.contains(key) {
            expanded.remove(key)
        } else {
            expanded.insert(key)
        }
    }
}

/// The day filter's pointer state: a header column under the pointer, and a day a click pinned.
/// Only the layers that draw the filter observe it. Used on the main thread only; not
/// main-actor isolated, so the view's `@State` default value needs no isolated context.
private final class MapTreePointer: ObservableObject {
    /// A day column under the pointer in the header: rows with no edits that day dim.
    @Published private(set) var hoveredColumn: Int?
    /// The pinned column's first day rather than its index, so the pin keeps its day when the
    /// columns move at the 05:00 rollover and lapses once that day leaves the strip.
    @Published private(set) var pinnedDay: DayKey?
    /// Lets go of `hoveredColumn` once the pointer has been off the day heads for `MapMotion.leaveDelay`.
    private var release: Task<Void, Never>?

    /// Publishes only a real change, like `MapHoverModel.hover(_:)`, and like it keeps a column
    /// for a moment after the pointer leaves it, so slipping between the heads and the band
    /// does not drop the filter and veil the rows again. The next column replaces it directly.
    func hoverColumn(_ column: Int?) {
        guard let column else {
            guard hoveredColumn != nil, release == nil else { return }
            release = Task { @MainActor [weak self] in
                try? await Task.sleep(for: MapMotion.leaveDelay)
                guard !Task.isCancelled, let self else { return }
                self.release = nil
                if self.hoveredColumn != nil { self.hoveredColumn = nil }
            }
            return
        }
        release?.cancel()
        release = nil
        if hoveredColumn != column { hoveredColumn = column }
    }

    func pin(_ day: DayKey?) {
        if pinnedDay != day { pinnedDay = day }
    }

    /// The column the rows are filtered by: the pinned day's, else the hovered one inside the range.
    func filterColumn(in layout: MapTreeLayout) -> Int? {
        layout.columnIndex(holding: pinnedDay) ?? layout.inRangeColumn(hoveredColumn)
    }
}

/// The day heads and their bands, under the header's static drawing: the only part of the
/// header a filtered day changes. The resting heads are recorded once per layout; a filtered
/// day is drawn over them in a layer of its own, which crossfades from one day to the next.
private struct MapTreeHeaderColumns: View {
    let layout: MapTreeLayout
    /// The static drawing's key, which also keys the resting heads.
    let key: MapStaticKey
    @ObservedObject var pointer: MapTreePointer
    @State private var memory = MapTreeMotionMemory()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill

    var body: some View {
        let layout = self.layout
        let filtered = pointer.filterColumn(in: layout)
        let motion = MapTreeMotion(newLayout: memory.isNewLayout(key.layout), reduceMotion: reduceMotion, still: rendersStill)
        ZStack(alignment: .topLeading) {
            MapStaticCanvas(key: key) { context, size in
                MapTreePainter.drawHeaderColumns(layout, size: size, in: &context)
            }
            .equatable()
            // Nothing is here at rest, so the strip looks exactly as it does without it.
            MapTreeCrossfade(id: filtered, animation: motion.crossfade) { column in
                Canvas { context, size in
                    MapTreePainter.drawFilteredHeads(layout, column: column, size: size, in: &context)
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// The hovered or selected row's highlight, under the static tree as the full drawing had
/// it. Once an emphasis veils the tree, the overlay draws the highlight over its veil instead:
/// this one fades out as the veil fades in, so the highlight hands over without a step.
private struct MapTreeRowUnderlay: View {
    let layout: MapTreeLayout
    /// The layout's generation: a new layout moves the highlight at once rather than fading it.
    let generation: Int
    @ObservedObject var hover: MapHoverModel
    @ObservedObject var pointer: MapTreePointer
    @State private var memory = MapTreeMotionMemory()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill

    var body: some View {
        let layout = self.layout
        let emphasis = MapTreeEmphasis(layout: layout, id: hover.emphasized, column: pointer.filterColumn(in: layout))
        let motion = MapTreeMotion(newLayout: memory.isNewLayout(generation), reduceMotion: reduceMotion, still: rendersStill)
        MapTreeCrossfade(id: emphasis.ring, animation: motion.crossfade) { ring in
            Canvas { context, _ in
                MapTreePainter.drawRowHighlight(layout, ring: ring, in: &context)
            }
        }
        .opacity(emphasis.veiled ? 0 : 1)
        .animation(motion.veil, value: emphasis.veiled)
        .allowsHitTesting(false)
    }
}

/// What a hover or a day filter adds over the static tree. A hovered session or a filtered
/// day veils the tree and draws the items it leaves lit again at full strength, recorded once
/// per session and day; the hovered item's path to main and its ring are drawn on every change.
///
/// The veil fades in and out as one group with what it lets through, so the lit items hold
/// their strength while the rest of the tree dims, and it stays up while one veiling item
/// hands over to the next. The lit items, the filtered day, the row highlight and the ring
/// each crossfade by what they show. Only opacities animate: no layer records its drawing
/// again during a fade, and a new layout switches at once.
private struct MapTreeBodyOverlay: View {
    let layout: MapTreeLayout
    let key: MapStaticKey
    let colors: [String: Color]
    @ObservedObject var hover: MapHoverModel
    @ObservedObject var pointer: MapTreePointer
    @State private var memory = MapTreeMotionMemory()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill

    var body: some View {
        let emphasis = MapTreeEmphasis(layout: layout, id: hover.emphasized, column: pointer.filterColumn(in: layout))
        let motion = MapTreeMotion(newLayout: memory.isNewLayout(key.layout), reduceMotion: reduceMotion, still: rendersStill)
        let lit = litLayer(emphasis, motion: motion)
        ZStack(alignment: .topLeading) {
            veilGroup(emphasis, motion: motion, litKey: lit.dim, litAnimation: lit.animation)
                // One group, so what the veil lets through covers it before the group fades.
                // Fully transparent at rest, so the tree looks exactly as it does without it.
                .compositingGroup()
                .opacity(emphasis.veiled ? 1 : 0)
                .animation(motion.veil, value: emphasis.veiled)
            hoverPath(emphasis, motion: motion)
        }
        .allowsHitTesting(false)
    }

    /// The veil, then over it the filtered day's band, the row highlight and the lit items.
    private func veilGroup(_ emphasis: MapTreeEmphasis, motion: MapTreeMotion, litKey: MapTreeDimKey?,
                           litAnimation: Animation?) -> some View {
        let layout = self.layout
        let colors = self.colors
        return ZStack(alignment: .topLeading) {
            MapStaticCanvas(key: key) { context, size in
                let veil = Theme.Palette.canvas.flattened(in: context.environment).opacity(MapTreePainter.veilOpacity)
                MapTreePainter.drawVeil(layout, color: veil, size: size, in: &context)
            }
            .equatable()
            MapTreeCrossfade(id: emphasis.column, animation: motion.crossfade) { column in
                Canvas { context, size in
                    context.clip(to: Path(CGRect(origin: .zero, size: size)))
                    MapTreePainter.drawFilteredBand(layout, column: column, from: -12, to: size.height - 2, in: &context)
                }
            }
            MapTreeCrossfade(id: emphasis.ring, animation: motion.crossfade) { ring in
                Canvas { context, _ in
                    MapTreePainter.drawRowHighlight(layout, ring: ring, in: &context)
                }
            }
            MapTreeCrossfade(id: litKey?.lit, animation: litAnimation, adds: true) { _ in
                if let litKey {
                    MapStaticCanvas(key: litKey) { context, size in
                        guard litKey.isVeiled else { return }
                        let style = MapTreeStyle(hatches: layout.hatches, colors: colors, in: context.environment)
                        let pass = MapTreePass(layout: layout, focusSourceID: litKey.base.focusSourceID,
                                               kept: MapTreePass.lit(layout, session: litKey.session?.key,
                                                                     column: litKey.column))
                        MapTreePainter.drawBody(layout, style: style, pass: pass, thread: litKey.thread(in: layout),
                                                size: size, in: &context)
                    }
                    .equatable()
                }
            }
        }
    }

    /// The hovered or selected item's path to main and its ring, over everything. Paths that
    /// share their way to main add up as they crossfade, so the shared part holds steady.
    private func hoverPath(_ emphasis: MapTreeEmphasis, motion: MapTreeMotion) -> some View {
        let layout = self.layout
        return MapTreeCrossfade(id: emphasis.ring, animation: motion.crossfade, adds: true) { ring in
            Canvas { context, _ in
                MapTreePainter.drawHover(layout, ring: ring, in: &context)
            }
        }
    }

    /// What the lit layer shows, and how it changes to it. A veil coming up shows its lit items
    /// at once, while the veil itself still lets the whole tree through; one veiling item
    /// handing over to another crossfades; a veil going down keeps the items it lit until it
    /// has faded, redrawn where a new layout puts them. The next change after that empties
    /// the layer, unseen.
    private func litLayer(_ emphasis: MapTreeEmphasis, motion: MapTreeMotion)
        -> (dim: MapTreeDimKey?, animation: Animation?) {
        let now = ProcessInfo.processInfo.systemUptime
        if emphasis.veiled {
            let showing = now < memory.veiledUntil
            let dim = MapTreeDimKey(base: key, session: emphasis.session, column: emphasis.column)
            memory.veiledUntil = .infinity
            memory.lit = dim
            return (dim, showing ? motion.crossfade : nil)
        }
        if memory.veiledUntil == .infinity {
            // The veil goes down now: at once when nothing fades, else over the veil's fade.
            memory.veiledUntil = motion.isInstant ? 0 : now + MapTreeMotionMemory.veilFade
        }
        guard now < memory.veiledUntil, let last = memory.lit else {
            memory.lit = nil
            return (nil, nil)
        }
        let kept = last.rebased(key)
        memory.lit = kept
        return (kept, nil)
    }
}

/// What the veiled layer depends on: the static drawing's key, the hovered session whose
/// branches stay lit, and the filtered day. Hovering another run of the same session, or
/// another branch while a day is filtered, keeps it.
private struct MapTreeDimKey: Equatable {
    /// What the lit items are, apart from where the layout puts them: a new one crossfades
    /// in, while a new layout or appearance redraws the same one in place.
    struct Lit: Hashable {
        let session: String?
        let column: Int?
    }

    let base: MapStaticKey
    let session: MapTreeSession?
    let column: Int?

    var isVeiled: Bool { session != nil || column != nil }

    var lit: Lit { Lit(session: session?.key, column: column) }

    /// The same lit items over another static drawing.
    func rebased(_ base: MapStaticKey) -> MapTreeDimKey {
        MapTreeDimKey(base: base, session: session, column: column)
    }

    /// The dotted arc through the branches the session moved between.
    func thread(in layout: MapTreeLayout) -> MapTreeLayout.SessionThread? {
        guard let session, let path = layout.sessionPaths[session.key], path.count >= 2 else { return nil }
        return MapTreeLayout.SessionThread(sourceID: session.sourceID, path: path)
    }
}

/// A hovered session with branches in the tree.
private struct MapTreeSession: Equatable {
    let key: String
    let sourceID: String
}

/// The two animations of an emphasis layer, or nil (an instant change) under Reduce Motion, in
/// still renders and on a new layout: its items have moved, and a fade would show the old
/// emphasis where its item no longer is.
private struct MapTreeMotion {
    let veil: Animation?
    let crossfade: Animation?

    init(newLayout: Bool, reduceMotion: Bool, still: Bool) {
        veil = MapMotion.animation(MapMotion.veil, reduceMotion: reduceMotion, still: still || newLayout)
        crossfade = MapMotion.animation(MapMotion.crossfade, reduceMotion: reduceMotion, still: still || newLayout)
    }

    /// Every change is instant.
    var isInstant: Bool { veil == nil }
}

/// What an emphasis layer showed when its body last ran, in a reference the layer writes as it
/// draws and never observes. Used on the main thread only; not main-actor isolated, like
/// `MapTreePointer`.
private final class MapTreeMotionMemory {
    /// How long a veil going down may still show: a little longer than `MapMotion.veil`.
    static let veilFade: TimeInterval = 0.25

    private var generation: Int?
    /// The lit items of the last veil, kept while it fades out.
    var lit: MapTreeDimKey?
    /// Until when the veil may still show, in system uptime: forever while it is up.
    var veiledUntil: TimeInterval = 0

    /// Whether `generation` names a layout this layer has not drawn yet, which it then remembers.
    func isNewLayout(_ generation: Int) -> Bool {
        defer { self.generation = generation }
        return self.generation != generation
    }
}

/// A layer drawn for one emphasis and handed over to the next by a crossfade: when `id`
/// changes, the old drawing fades out as the new one fades in. Nil draws nothing, so the
/// layer is empty at rest. With `adds`, the two drawings add up in a group of their own
/// rather than stack, so what both draw, such as the root or a shared path to main, keeps
/// its strength through the handover instead of dipping. The frame never depends on what is
/// drawn, so a handover changes opacities only.
private struct MapTreeCrossfade<ID: Hashable, Content: View>: View {
    let id: ID?
    let animation: Animation?
    var adds = false
    @ViewBuilder let content: (ID) -> Content

    var body: some View {
        let stack = ZStack(alignment: .topLeading) {
            if let id {
                content(id)
                    .blendMode(adds ? .plusLighter : .normal)
                    .id(id)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        if adds {
            stack
                .compositingGroup()
                .animation(animation, value: id)
        } else {
            stack
                .animation(animation, value: id)
        }
    }
}

/// One layout per map, size and set of opened families. A reference, so a hover's redraw reuses it;
/// `generation` changes with each new layout and keys the static drawing.
private final class MapTreeCache {
    private struct Key: Equatable {
        let size: CGSize
        let expanded: Set<String>
        let sourceIDs: [String]
        let calendar: ActivityCalendar
        let map: ProjectMap
    }

    private var key: Key?
    private var cached: MapTreeLayout?
    private(set) var generation = 0

    func layout(map: ProjectMap, sourceIDs: [String], calendar: ActivityCalendar, size: CGSize,
                expanded: Set<String>) -> MapTreeLayout {
        let key = Key(size: size, expanded: expanded, sourceIDs: sourceIDs, calendar: calendar, map: map)
        if let cached, self.key == key { return cached }
        let layout = MapTreeLayout(map: map, sourceIDs: sourceIDs, calendar: calendar, size: size, expanded: expanded)
        self.key = key
        cached = layout
        generation += 1
        return layout
    }
}

/// What a point on the tree names, and the family a click there opens or closes.
private struct MapTreeTarget {
    var id: MapHitID?
    var toggle: String?
}

// MARK: - Layout

/// Every position the tree draws, computed once per map, size and opened families.
private struct MapTreeLayout {
    static let columnCount = 7
    static let columnWidth: CGFloat = 15
    /// The widest the tree lays out; a wider window centers it, so the day strip stays beside
    /// the labels. The popover is always narrower.
    static let maxLayoutWidth: CGFloat = 860
    /// Rows stay centered up to this inner height, more than the popover ever has; past it a
    /// small tree rises toward the header instead of floating mid-window.
    static let centeredHeight: CGFloat = 650
    /// Branch prefixes that name a tool or a habit, not a family of related work.
    static let genericPrefixes: Set<String> = [
        "claude/", "codex/", "cursor/", "copilot/", "fix/", "feat/", "feature/", "chore/", "bugfix/", "hotfix/",
        "dependabot/", "renovate/"
    ]
    /// Workflow agents whose own run is too small to fold gather under this key.
    static let runsKey = "runs:*"

    enum Kind {
        case root
        case lane
        case group
        /// Branches with no edits, and on main the merges of branches no session edited.
        case quiet
    }

    enum Status {
        case merged
        case open
        case noCommits
        /// A worktree whose branch is unknown.
        case folder
        case deleted

        var isDashed: Bool { self == .noCommits || self == .folder || self == .deleted }
        var isFaded: Bool { self == .deleted }
    }

    struct Piece {
        var text: String
        var alpha: Double
    }

    /// A word after a label: a count, a pull request or a status.
    struct Meta {
        enum Tone {
            case count
            case tag
            case working
            case waiting
        }

        var text: String
        var tone: Tone
    }

    struct Column {
        let first: DayKey
        let top: String
        let bottom: String
        let isToday: Bool
        let inRange: Bool
    }

    struct Bead {
        let id: MapHitID
        let center: CGPoint
        let merged: Bool
    }

    struct LiveMark: Identifiable {
        let id: String
        let run: MapHitID
        let kind: StatusGlyph.Kind
        let point: CGPoint
        /// On the trunk's band in the header rather than in the tree.
        let inHeader: Bool
    }

    /// A session's moves between branches, in the order of its runs.
    struct SessionThread {
        let sourceID: String
        let path: [Int]
    }

    struct Item {
        let kind: Kind
        var lanes: [ProjectMap.Lane]
        var markers: [ProjectMap.Marker] = []
        let parent: Int?
        var children: [Int] = []
        let depth: Int
        var hitID: MapHitID
        /// A folded family, or the family an opened member belongs to.
        var groupKey: String?
        /// Over the first member of an opened family: "nv/* · 8".
        var caption: String?
        var captionHitID: MapHitID?
        var name: [Piece] = []
        var status: Status = .open
        var landed = 0
        var live: ProjectMap.Span?
        var edits = 0
        var direct: [String: Int] = [:]
        var delegated: [String: Int] = [:]
        var subtreeEdits = 0
        var subtreeBySource: [String: Int] = [:]
        var dominant: String?
        var columns = Array(repeating: 0, count: MapTreeLayout.columnCount)
        var columnSources = Array(repeating: [String: Int](), count: MapTreeLayout.columnCount)
        var subtreeColumns = Array(repeating: 0, count: MapTreeLayout.columnCount)
        var mergeColumns = Set<Int>()
        /// Columns from the fork to the merge, or to now while it is open.
        var lifetime: ClosedRange<Int>?
        var cellRuns: [Int: MapHitID] = [:]
        var cellCommits: [Int: MapHitID] = [:]
        var x: CGFloat = 0
        var y: CGFloat = 0
        var r: CGFloat = 0
        /// Where the children fan out, at the end of the line under an internal node's label.
        var departX: CGFloat = 0
        var rowTop: CGFloat = 0
        var rowBottom: CGFloat = 0
        var linkStart = CGPoint.zero
        var linkEnd = CGPoint.zero
        var linkWidth: CGFloat = 0
        var segmentWidth: CGFloat = 0
        var labelX: CGFloat = 0
        var meta: [Meta] = []
        var pill: String?
        var labelRect = CGRect.null
        var captionRect = CGRect.null
        var beads: [Bead] = []
        var quietText = ""
        var quietPills: [String] = []
        var quietNames = ""
        /// Where the label's knocked-out words sit, as the painter clears them from the links
        /// beneath. A veiled overlay clears a dimmed label's with these, unmeasured.
        var knocks: [CGRect] = []

        init(kind: Kind, lanes: [ProjectMap.Lane], parent: Int?, depth: Int, hitID: MapHitID) {
            self.kind = kind
            self.lanes = lanes
            self.parent = parent
            self.depth = depth
            self.hitID = hitID
        }

        var isLeaf: Bool { kind != .root && children.isEmpty }
        var isLanded: Bool { status == .merged }
    }

    let map: ProjectMap
    let width: CGFloat
    let headerHeight: CGFloat
    /// The center line of the trunk's own edits in the header, when it has any.
    let bandY: CGFloat?
    let bodyHeight: CGFloat
    let scrolls: Bool
    let stripX: CGFloat
    let columns: [Column]
    let bucketDays: Int
    let items: [Item]
    let leafIndices: [Int]
    let laneItem: [String: Int]
    let quietMarkerItem: [String: Int]
    /// Families drawn folded.
    let groupKeys: [String]
    /// Families drawn open; unlike the opened set passed in, never a family this map does not form.
    let openedKeys: [String]
    let sourceIDs: [String]
    let sourceRank: [String: Int]
    let hatches: Bool
    let trunkTitle: String
    let trunkEdits: Int
    let totalEdits: Int
    let rootDirect: [String: Int]
    let rootDelegated: [String: Int]
    let trunkColumns: [[String: Int]]
    let trunkCellRuns: [Int: MapHitID]
    let liveMarks: [LiveMark]
    let livePath: Set<Int>
    let liveThreads: [SessionThread]
    let captionTitle: String
    let captionHint: String
    let rootLabelRect: CGRect
    /// The root's words as the painter knocks them out, so a path drawn over the tree clears them too.
    let rootKnockouts: [CGRect]
    /// Per session, the items its runs moved between, in the order of its runs.
    let sessionPaths: [String: [Int]]
    /// Folded families by their members' sorted lane ids.
    let groupIndex: [[String]: Int]
    let hits: Hits
    let accessibilitySummary: String

    /// What hit testing reads on every pointer move, flattened once per layout so a move
    /// allocates nothing and copies no items.
    struct Hits {
        struct Point {
            let center: CGPoint
            let id: MapHitID
        }

        struct Disc {
            let center: CGPoint
            let reachSquared: CGFloat
            let index: Int
        }

        struct Row {
            let top: CGFloat
            let bottom: CGFloat
            /// Left of this, a point in the row names nothing.
            let minX: CGFloat
            let leaf: Int
        }

        struct Box {
            let rect: CGRect
            let index: Int
        }

        struct Caption {
            let rect: CGRect
            let target: MapTreeTarget
        }

        struct Line {
            let minX: CGFloat
            let maxX: CGFloat
            let y: CGFloat
            let index: Int
        }

        var marks: [Point] = []
        /// Leaf rows top to bottom, each starting where the one above ends.
        var rows: [Row] = []
        /// Per row and column, the run or the commit a day cell names.
        var cells: [MapHitID?] = []
        var captions: [Caption] = []
        var discs: [Disc] = []
        var beads: [Point] = []
        var labels: [Box] = []
        var lines: [Line] = []
        /// Per item, what pointing at it names.
        var targets: [MapTreeTarget] = []

        /// The row holding `y`.
        func row(at y: CGFloat) -> Int? {
            var low = 0
            var high = rows.count - 1
            while low <= high {
                let middle = (low + high) / 2
                let row = rows[middle]
                if y < row.top {
                    high = middle - 1
                } else if y >= row.bottom {
                    low = middle + 1
                } else {
                    return middle
                }
            }
            return nil
        }
    }

    var stripEnd: CGFloat { stripX + CGFloat(Self.columnCount) * Self.columnWidth }

    func columnX(_ index: Int) -> CGFloat { stripX + Self.columnWidth * (CGFloat(index) + 0.5) }

    /// `index` when it names a column inside the range, else nil.
    func inRangeColumn(_ index: Int?) -> Int? {
        guard let index, columns.indices.contains(index), columns[index].inRange else { return nil }
        return index
    }

    /// The column inside the range whose days hold `day`, or nil once it has left the strip.
    func columnIndex(holding day: DayKey?) -> Int? {
        guard let day else { return nil }
        return columns.indices.first { index in
            let candidate = columns[index]
            let end: DayKey = candidate.first.adding(days: bucketDays)
            return candidate.inRange && candidate.first <= day && day < end
        }
    }

    // swiftlint:disable:next function_body_length cyclomatic_complexity
    init(map: ProjectMap, sourceIDs configured: [String], calendar: ActivityCalendar, size: CGSize,
         expanded: Set<String>) {
        let count = Self.columnCount
        let columnWidth = Self.columnWidth
        let width = max(1, min(size.width, Self.maxLayoutWidth))
        let trunkID = map.trunkID
        let laneByID = Dictionary(map.lanes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let branches = map.lanes.filter { $0.id != trunkID }

        // Profiles in the configured order, then any others by id.
        let present = Set(map.spans.map(\.sourceID))
        var sources: [String] = []
        var rank: [String: Int] = [:]
        for id in configured.filter({ present.contains($0) }) + present.subtracting(configured).sorted() where rank[id] == nil {
            rank[id] = sources.count
            sources.append(id)
        }

        // Columns: the last seven activity days, or seven equal spans of a longer range.
        let today = calendar.day(of: map.now)
        let rangeStart = map.range.start(now: map.now, calendar: calendar).map { calendar.day(of: $0) }
            ?? calendar.day(of: map.axis.start)
        let spanDays = min(3_650, max(1, rangeStart.days(to: today) + 1))
        let daysPerColumn: Double = (Double(spanDays) / Double(count)).rounded(.up)
        let bucket: Int = spanDays <= count ? 1 : Int(daysPerColumn)
        let firstDay = today.adding(days: -(count * bucket - 1))
        var columns: [Column] = []
        for index in 0..<count {
            let start = firstDay.adding(days: index * bucket)
            let last = start.adding(days: bucket - 1)
            let top: String
            if bucket == 1 {
                top = DayFormat.weekday(start.weekday, style: .narrow)
            } else if index == 0 || columns[index - 1].first.month != start.month {
                top = DayFormat.monthAbbreviation(start, calendar: calendar)
            } else {
                top = ""
            }
            columns.append(Column(first: start, top: top, bottom: "\(start.day)", isToday: last >= today,
                                  inRange: last >= rangeStart))
        }
        func column(_ date: Date) -> Int? {
            let offset = firstDay.days(to: calendar.day(of: date))
            guard offset >= 0 else { return nil }
            return min(count - 1, offset / bucket)
        }

        // Edits per lane: by profile, by column, and the run that made most of each column.
        struct Tally {
            var direct: [String: Int] = [:]
            var delegated: [String: Int] = [:]
            var columns = Array(repeating: 0, count: MapTreeLayout.columnCount)
            var columnSources = Array(repeating: [String: Int](), count: MapTreeLayout.columnCount)
            var best: [Int: (id: MapHitID, edits: Int)] = [:]
        }
        var tallies: [String: Tally] = [:]
        for span in map.spans {
            var tally = tallies[span.laneID] ?? Tally()
            tally.direct[span.sourceID, default: 0] += span.direct.count
            tally.delegated[span.sourceID, default: 0] += span.delegated.count
            var perColumn = Array(repeating: 0, count: count)
            for edit in span.edits {
                if let index = column(edit) { perColumn[index] += 1 }
            }
            let id = MapHitID.run(span.sessionKey, span.index)
            for index in 0..<count where perColumn[index] > 0 {
                tally.columns[index] += perColumn[index]
                tally.columnSources[index][span.sourceID, default: 0] += perColumn[index]
                if perColumn[index] > (tally.best[index]?.edits ?? -1) { tally.best[index] = (id, perColumn[index]) }
            }
            // A live session with no edits yet still answers for its column.
            if span.editCount == 0, let index = column(span.live != nil ? map.now : span.start), tally.best[index] == nil {
                tally.best[index] = (id, 0)
            }
            tallies[span.laneID] = tally
        }
        var liveByLane: [String: ProjectMap.Span] = [:]
        for span in map.spans where span.live != nil {
            if let existing = liveByLane[span.laneID], existing.live == LiveStatus.waiting.rawValue { continue }
            liveByLane[span.laneID] = span
        }

        // Parents: where a branch merged, else where it was created; a cycle falls back to the trunk.
        var parentOf: [String: String] = [:]
        for lane in branches {
            let parent = lane.parentID ?? trunkID
            parentOf[lane.id] = parent != lane.id && laneByID[parent] != nil ? parent : trunkID
        }
        for lane in branches {
            var seen: Set<String> = [lane.id]
            var current = parentOf[lane.id]
            while let id = current, id != trunkID {
                guard seen.insert(id).inserted else {
                    parentOf[lane.id] = trunkID
                    break
                }
                current = parentOf[id]
            }
        }

        // Families: a shared prefix ("nv/"), a worktree folder's prefix joining its branches'
        // ("wa-" to "wave-a/"), or one workflow run.
        let branchPrefixes = Set(branches.compactMap { ProjectMap.streamPrefix($0.title) }
            .filter { $0.hasSuffix("/") && !Self.genericPrefixes.contains($0) }).sorted()
        var familyKeys: [String: String] = [:]
        for lane in branches {
            guard let prefix = ProjectMap.streamPrefix(lane.title) else { continue }
            if prefix.hasPrefix("wf_") {
                familyKeys[lane.id] = "run:" + prefix
            } else if prefix.hasSuffix("/") {
                if !Self.genericPrefixes.contains(prefix) { familyKeys[lane.id] = prefix }
            } else {
                familyKeys[lane.id] = branchPrefixes.first { Self.folderMatches(prefix, branch: $0) } ?? prefix
            }
        }

        // A branch left at the trunk joins the integration branch its family hangs under;
        // when several do, the one nearest the trunk.
        func depthOf(_ id: String) -> Int {
            var steps = 0
            var current = parentOf[id]
            while let parent = current, parent != trunkID, steps < 32 {
                steps += 1
                current = parentOf[parent]
            }
            return steps
        }
        let parents = Set(parentOf.values)
        var owners: [String: Set<String>] = [:]
        for lane in branches {
            guard let key = familyKeys[lane.id] else { continue }
            if let parent = parentOf[lane.id], parent != trunkID { owners[key, default: []].insert(parent) }
            if parents.contains(lane.id) { owners[key, default: []].insert(lane.id) }
        }
        for lane in branches where parentOf[lane.id] == trunkID && !parents.contains(lane.id) {
            guard let key = familyKeys[lane.id], let candidates = owners[key], !candidates.contains(lane.id) else { continue }
            let depths = candidates.map { (id: $0, depth: depthOf($0)) }
            guard let nearest = depths.map({ $0.depth }).min() else { continue }
            let shallowest = depths.filter { $0.depth == nearest }
            if shallowest.count == 1, let family = shallowest.first { parentOf[lane.id] = family.id }
        }
        var kids: [String: [String]] = [:]
        for lane in branches { kids[parentOf[lane.id] ?? trunkID, default: []].append(lane.id) }

        var firstMemo: [String: Date] = [:]
        func firstActivity(_ id: String) -> Date {
            if let known = firstMemo[id] { return known }
            var date: Date = map.now
            if let lane = laneByID[id] { date = min(lane.start, lane.forkedAt ?? lane.start) }
            for child in kids[id] ?? [] { date = min(date, firstActivity(child)) }
            firstMemo[id] = date
            return date
        }
        func hasWork(_ id: String) -> Bool { (laneByID[id]?.editCount ?? 0) > 0 || liveByLane[id] != nil }

        // Items: one per drawn node, in depth-first order, children oldest first.
        var items: [Item] = []
        var laneItem: [String: Int] = [:]
        var quietMarkerItem: [String: Int] = [:]
        var groupKeys: [String] = []
        var familyMembers: [String: [String]] = [:]
        var opened: [String] = []
        var openedKeys: [String] = []
        let quietMarkers = map.markers.filter { $0.quietBranch != nil && $0.laneID == trunkID }

        func build(_ laneID: String, parent: Int?, depth: Int,
                   family: (key: String, groupKey: String, caption: String?)?) -> Int {
            let lane = laneByID[laneID]
            let kind: Kind = parent == nil ? .root : .lane
            var item = Item(kind: kind, lanes: lane.map { [$0] } ?? [], parent: parent, depth: depth, hitID: .lane(laneID))
            if let lane, kind == .lane {
                // Under an integration branch of the same family, its prefix dims and goes first when space is short.
                var shared: String?
                if let parent, items[parent].kind == .lane, let parentLane = items[parent].lanes.first,
                   let prefix = ProjectMap.streamPrefix(parentLane.title),
                   prefix.hasSuffix("/"), !Self.genericPrefixes.contains(prefix) {
                    shared = prefix
                }
                if let family {
                    item.name = Self.memberPieces(lane, familyKey: family.key)
                } else {
                    item.name = Self.namePieces(lane, shared: shared)
                }
            }
            item.groupKey = family?.groupKey
            item.caption = family?.caption
            if let family, family.caption != nil { item.captionHitID = .group(familyMembers[family.groupKey] ?? []) }
            items.append(item)
            let index = items.count - 1
            laneItem[laneID] = index

            let children = (kids[laneID] ?? []).sorted { (firstActivity($0), $0) < (firstActivity($1), $1) }
            let leaves = children.filter { (kids[$0] ?? []).isEmpty }
            var candidates: [String: [String]] = [:]
            for id in leaves {
                if let key = familyKeys[id] { candidates[key, default: []].append(id) }
            }
            var formed: [String: [String]] = [:]
            for (key, members) in candidates where members.count >= (key.hasPrefix("run:") ? 2 : 3)
                && members.contains(where: hasWork) {
                formed[key] = members
            }
            // Workflow agents whose run stayed too small gather into one family of runs.
            let strays = leaves.filter { id in
                guard let key = familyKeys[id], key.hasPrefix("run:") else { return false }
                return formed[key] == nil
            }
            var familyOf: [String: String] = [:]
            for (key, members) in formed {
                for member in members { familyOf[member] = key }
            }
            if strays.count >= 3 && strays.contains(where: hasWork) {
                formed[Self.runsKey] = strays
                for member in strays { familyOf[member] = Self.runsKey }
            }

            var emitted = Set<String>()
            var childIndices: [Int] = []
            var quiet: [ProjectMap.Lane] = []
            for id in children {
                if let key = familyOf[id] {
                    guard emitted.insert(key).inserted, let members = formed[key] else { continue }
                    let ordered = members.sorted { (firstActivity($0), $0) < (firstActivity($1), $1) }
                    let memberLanes = ordered.compactMap { laneByID[$0] }
                    let groupKey = laneID + "|" + key
                    let title = Self.familyTitle(key, members: memberLanes)
                    familyMembers[groupKey] = ordered
                    if expanded.contains(groupKey) {
                        opened.append(title.name)
                        openedKeys.append(groupKey)
                        for (position, member) in ordered.enumerated() {
                            let caption: String? = position == 0 ? "\(title.name) · \(ordered.count)" : nil
                            childIndices.append(build(member, parent: index, depth: depth + 1,
                                                      family: (key: key, groupKey: groupKey, caption: caption)))
                        }
                    } else {
                        groupKeys.append(groupKey)
                        var group = Item(kind: .group, lanes: memberLanes, parent: index, depth: depth + 1,
                                         hitID: .group(ordered))
                        group.groupKey = groupKey
                        group.name = title.pieces
                        items.append(group)
                        for member in ordered { laneItem[member] = items.count - 1 }
                        childIndices.append(items.count - 1)
                    }
                    continue
                }
                if (kids[id] ?? []).isEmpty, !hasWork(id), let lane = laneByID[id] {
                    quiet.append(lane)
                    continue
                }
                childIndices.append(build(id, parent: index, depth: depth + 1, family: nil))
            }
            let markers = parent == nil ? quietMarkers : []
            if !quiet.isEmpty || !markers.isEmpty {
                let hitID: MapHitID
                if let marker = markers.first {
                    hitID = markers.count == 1 ? .commit(marker.sha) : .cluster(markers.map(\.sha))
                } else if quiet.count == 1, let lane = quiet.first {
                    hitID = .lane(lane.id)
                } else {
                    hitID = .group(quiet.map(\.id))
                }
                var row = Item(kind: .quiet, lanes: quiet, parent: index, depth: depth + 1, hitID: hitID)
                row.markers = markers
                items.append(row)
                for lane in quiet { laneItem[lane.id] = items.count - 1 }
                for marker in markers { quietMarkerItem[marker.sha] = items.count - 1 }
                childIndices.append(items.count - 1)
            }
            items[index].children = childIndices
            return index
        }
        _ = build(trunkID, parent: nil, depth: 0, family: nil)
        var groupIndex: [[String]: Int] = [:]
        for index in items.indices where items[index].kind == .group {
            let ids = items[index].lanes.map(\.id).sorted()
            if groupIndex[ids] == nil { groupIndex[ids] = index }
        }

        // Each session's moves between items, in the order of its runs.
        var runsBySession: [String: [ProjectMap.Span]] = [:]
        for span in map.spans { runsBySession[span.sessionKey, default: []].append(span) }
        var sessionPaths: [String: [Int]] = [:]
        for (key, runs) in runsBySession {
            var path: [Int] = []
            for run in runs.sorted(by: { $0.index < $1.index }) {
                if let index = laneItem[run.laneID], path.last != index { path.append(index) }
            }
            sessionPaths[key] = path
        }

        // Own edits, status, live state and days.
        for index in items.indices {
            var item = items[index]
            var best: [Int: Int] = [:]
            for lane in item.lanes {
                guard let tally = tallies[lane.id] else { continue }
                for (id, edits) in tally.direct { item.direct[id, default: 0] += edits }
                for (id, edits) in tally.delegated { item.delegated[id, default: 0] += edits }
                for position in 0..<count {
                    item.columns[position] += tally.columns[position]
                    for (id, edits) in tally.columnSources[position] { item.columnSources[position][id, default: 0] += edits }
                    if let run = tally.best[position], run.edits > (best[position] ?? -1) {
                        best[position] = run.edits
                        item.cellRuns[position] = run.id
                    }
                }
            }
            item.edits = item.direct.values.reduce(0, +) + item.delegated.values.reduce(0, +)
            let lives = item.lanes.compactMap { liveByLane[$0.id] }
            item.live = lives.first { $0.live == LiveStatus.waiting.rawValue } ?? lives.first
            switch item.kind {
            case .root:
                item.status = .open
            case .lane:
                item.status = item.lanes.first.map(Self.status) ?? .open
            case .group:
                item.landed = item.lanes.filter { $0.merge != nil }.count
                let idle = item.lanes.filter { $0.merge == nil && ($0.commitCount == 0 || $0.kind == .folder) }.count
                item.status = item.landed * 2 > item.lanes.count ? .merged
                    : idle == item.lanes.count ? .noCommits : .open
            case .quiet:
                item.status = .merged
            }
            for lane in item.lanes {
                guard let merge = lane.merge, let position = column(merge.date) else { continue }
                item.mergeColumns.insert(position)
                item.cellCommits[position] = .commit(merge.sha)
            }
            for marker in item.markers {
                guard let position = column(marker.date) else { continue }
                item.mergeColumns.insert(position)
                item.cellCommits[position] = .commit(marker.sha)
            }
            if item.kind == .lane || item.kind == .group {
                let starts: [Int] = item.lanes.map { lane -> Int in
                    if lane.enteredBeforeWindow { return 0 }
                    return column(lane.forkedAt ?? lane.start) ?? 0
                }
                let ends: [Int] = item.lanes.map { lane -> Int in
                    let openEnd: Date = lane.isLive || lane.isHead ? map.now : lane.end
                    return column(lane.merge?.date ?? openEnd) ?? 0
                }
                if let low = starts.min(), let high = ends.max(), high > low { item.lifetime = low...high }
            }
            items[index] = item
        }
        // Subtrees, children first: they always come after their parent.
        for index in items.indices.reversed() {
            var item = items[index]
            var bySource: [String: Int] = [:]
            for (id, edits) in item.direct { bySource[id, default: 0] += edits }
            for (id, edits) in item.delegated { bySource[id, default: 0] += edits }
            var subtree = item.edits
            var columnTotals = item.columns
            for child in item.children {
                subtree += items[child].subtreeEdits
                for (id, edits) in items[child].subtreeBySource { bySource[id, default: 0] += edits }
                for position in 0..<count { columnTotals[position] += items[child].subtreeColumns[position] }
            }
            item.subtreeEdits = subtree
            item.subtreeBySource = bySource
            item.subtreeColumns = columnTotals
            item.dominant = Self.dominant(bySource, rank: rank)
            items[index] = item
        }

        // The whole project for the root ring, and the hatch rule: when subagents made
        // nearly every edit, hatching says nothing, so the caption says it once.
        var rootDirect: [String: Int] = [:]
        var rootDelegated: [String: Int] = [:]
        for span in map.spans {
            rootDirect[span.sourceID, default: 0] += span.direct.count
            rootDelegated[span.sourceID, default: 0] += span.delegated.count
        }
        let totalDirect: Int = rootDirect.values.reduce(0, +)
        let totalDelegated: Int = rootDelegated.values.reduce(0, +)
        let totalEdits = totalDirect + totalDelegated
        let delegatedShare: Double = totalEdits > 0 ? Double(totalDelegated) / Double(totalEdits) : 0
        let hatches = delegatedShare <= 0.8

        // Vertical: leaves stack top to bottom; rows shrink until they fit, then the tree scrolls.
        let stripX = width - CGFloat(count) * columnWidth - 2
        let labelMax = stripX - 10
        let trunkEdits = laneByID[trunkID]?.editCount ?? 0
        let hasBand = trunkEdits > 0 || liveByLane[trunkID] != nil
        let headerHeight: CGFloat = hasBand ? 50 : 30
        let bandY: CGFloat? = hasBand ? 37 : nil
        let available = max(80, size.height - headerHeight)
        let leafIndices = items.indices.filter { items[$0].isLeaf }

        var rScale: CGFloat = 0.6
        var rCap: CGFloat = 13
        var minRow: CGFloat = 21
        var quietRow: CGFloat = 16
        var pad: CGFloat = 13
        var rootR: CGFloat = 15
        func radius(_ item: Item) -> CGFloat {
            switch item.kind {
            case .root: return rootR
            case .quiet: return 0
            case .lane, .group:
                guard item.edits > 0 else { return 2.75 }
                let grown: CGFloat = 2.5 + rScale * CGFloat(item.edits).squareRoot()
                return min(rCap, grown)
            }
        }
        /// Room over a leaf for the label of a single-child chain above it, and under it for that
        /// chain's counts; and over the first member of an opened family for its caption.
        func pads(_ leaf: Int) -> (top: CGFloat, bottom: CGFloat) {
            var top: CGFloat = 0
            var bottom: CGFloat = 0
            var current = leaf
            while let parent = items[current].parent, items[parent].kind != .root, items[parent].children.count == 1 {
                top = pad
                bottom = pad - 2
                current = parent
            }
            if items[leaf].caption != nil { top += 12 }
            return (top, bottom)
        }
        func rowHeight(_ leaf: Int) -> CGFloat {
            let item = items[leaf]
            let room = pads(leaf)
            let padding: CGFloat = room.top + room.bottom
            if item.kind == .quiet { return quietRow + padding }
            let clearance: CGFloat = item.kind == .group ? 10 : 6
            let node: CGFloat = 2 * radius(item) + clearance
            return max(minRow, node) + padding
        }
        let inner = available - 8
        var heights = leafIndices.map(rowHeight)
        for _ in 0..<14 where heights.reduce(0, +) > inner {
            rScale *= 0.94
            rCap = max(8, rCap - 0.75)
            // Never below a label's height: past that the tree scrolls instead of overlapping.
            minRow = max(18, minRow - 0.6)
            quietRow = max(14, quietRow - 0.5)
            pad = max(12, pad - 0.5)
            rootR = max(12, rootR - 0.5)
            heights = leafIndices.map(rowHeight)
        }
        let natural = heights.reduce(0, +)
        let grow: CGFloat = natural > 0 && natural < inner ? min(1.5, inner / natural) : 1
        let contentHeight = max(available, natural * grow + 8)
        let scrolls: Bool = contentHeight > available + 0.5
        for index in items.indices { items[index].r = radius(items[index]) }
        // The most room over the rows: up to `centeredHeight`, half of it, more than centering
        // leaves; past it, two points less per point of height, down to 40 under the header.
        let past: CGFloat = max(0, inner - Self.centeredHeight)
        let slackCap: CGFloat = max(40, Self.centeredHeight / 2 - 2 * past)
        let slack: CGFloat = min(max(0, (inner - natural * grow) / 2), slackCap)
        var cursor: CGFloat = 4 + slack
        for (position, leaf) in leafIndices.enumerated() {
            let height: CGFloat = heights[position] * grow
            let room = pads(leaf)
            let top: CGFloat = room.top * grow
            let core: CGFloat = height - (room.top + room.bottom) * grow
            items[leaf].rowTop = cursor
            items[leaf].rowBottom = cursor + height
            items[leaf].y = cursor + top + core / 2
            cursor += height
        }
        for index in items.indices.reversed() where !items[index].children.isEmpty {
            let children = items[index].children
            if let first = children.first, let last = children.last {
                items[index].y = (items[first].y + items[last].y) / 2
            }
        }
        if !items.isEmpty {
            // When the tree scrolls, the root stays in the part shown first, not mid-content.
            let visible: CGFloat = scrolls ? available : contentHeight
            // A lone root is centered like the rows, under the same cap.
            if items[0].children.isEmpty { items[0].y = min(visible / 2, 4 + slackCap) }
            let low: CGFloat = rootR + 24
            let roof: CGFloat = scrolls ? visible / 2 : visible - rootR - 44
            let high: CGFloat = max(low, roof)
            items[0].y = min(high, max(low, items[0].y))
        }

        // Horizontal: the root, a fixed column for its children, and deeper levels just past
        // the end of their parent's label line. When that pushes a node past `deepestX`, as a
        // deep chain of stacked branches does, the tree is placed again with each node's
        // children held to an even share of the room left between it and `deepestX`, split over
        // the levels its subtree still has, so every node and label stays clear of the day strip.
        let depthOneX = min(112, max(84, width * 0.19))
        let deepestX: CGFloat = labelMax - 60
        var subtreeDepth: [Int] = items.map(\.depth)
        for index in items.indices.reversed() {
            for child in items[index].children where subtreeDepth[child] > subtreeDepth[index] {
                subtreeDepth[index] = subtreeDepth[child]
            }
        }
        func placeHorizontally(capped: Bool) {
            /// The farthest right an internal node's children may sit, once capped.
            var childCap = [CGFloat?](repeating: nil, count: items.count)
            for index in items.indices {
                var item = items[index]
                if let parent = item.parent {
                    let parentIsRoot = items[parent].kind == .root
                    // A wider fan of children leaves a little more run for its links.
                    let siblings = items[parent].children
                    var spread: CGFloat = 0
                    if let first = siblings.first, let last = siblings.last { spread = abs(items[last].y - items[first].y) }
                    let reach: CGFloat = min(22, spread * 0.1)
                    let depart: CGFloat = items[parent].departX
                    let lead: CGFloat = item.kind == .quiet ? 0 : item.r
                    if parentIsRoot {
                        item.x = item.kind == .quiet ? depthOneX - 4 : depthOneX
                    } else {
                        item.x = depart + 18 + reach + lead
                        if let cap = childCap[parent] { item.x = max(depart + 6 + lead, min(item.x, cap)) }
                        // Never into the strip, where a point names a day cell rather than a node.
                        let edge: CGFloat = stripX - 14 - item.r
                        item.x = min(item.x, edge)
                    }
                } else {
                    item.x = rootR + 1
                }
                if capped, item.kind != .root, !item.children.isEmpty {
                    let levels = CGFloat(max(1, subtreeDepth[index] - item.depth))
                    let share: CGFloat = max(0, deepestX - item.x) / levels
                    childCap[index] = item.x + share
                }
                switch item.kind {
                case .root:
                    break
                case .lane, .group:
                    let departMax: CGFloat = childCap[index].map { $0 - 24 } ?? CGFloat.greatestFiniteMagnitude
                    Self.placeLabel(&item, labelMax: labelMax, departMax: departMax)
                    if let caption = item.caption {
                        let bottom = item.y - max(item.r, 5) - 3
                        item.captionRect = CGRect(x: item.x - item.r - 2, y: bottom - 12,
                                                  width: MapTreeText.meta(caption) + 16, height: 13)
                    }
                case .quiet:
                    Self.placeQuiet(&item, labelMax: labelMax)
                }
                items[index] = item
            }
        }
        // Placing fits names and fills a quiet row's pills, so the capped pass starts from scratch.
        let unplaced = items
        placeHorizontally(capped: false)
        if items.contains(where: { $0.depth >= 2 && $0.x > deepestX }) {
            items = unplaced
            placeHorizontally(capped: true)
        }

        // Links: widths add up, so the children's rivers stack where they leave their parent.
        var rootFlows: [CGFloat] = []
        if let root = items.first {
            for child in root.children where items[child].kind != .quiet {
                rootFlows.append(CGFloat(items[child].subtreeEdits))
            }
        }
        let largestFlow: CGFloat = max(1, rootFlows.max() ?? 1)
        let totalFlow: CGFloat = max(1, rootFlows.reduce(0, +))
        let scale: CGFloat = min(7 / largestFlow, 1.55 * rootR / totalFlow)
        func flow(_ edits: Int) -> CGFloat { max(0.7, CGFloat(edits) * scale) }
        for index in items.indices where !items[index].children.isEmpty {
            let parent = items[index]
            let start = parent.kind == .root ? parent.x + parent.r * 0.55 : parent.departX
            if parent.kind != .root { items[index].segmentWidth = flow(parent.subtreeEdits - parent.edits) }
            let widths: [CGFloat] = parent.children.map { child -> CGFloat in
                items[child].kind == .quiet ? 0.65 : flow(items[child].subtreeEdits)
            }
            let gaps: CGFloat = 0.5 * CGFloat(max(0, widths.count - 1))
            let stack: CGFloat = widths.reduce(0, +) + gaps
            var top = parent.y - stack / 2
            for (child, linkWidth) in zip(parent.children, widths) {
                items[child].linkStart = CGPoint(x: start, y: top + linkWidth / 2)
                items[child].linkWidth = linkWidth
                let end = items[child].kind == .quiet ? items[child].x : items[child].x - items[child].r - 0.5
                items[child].linkEnd = CGPoint(x: end, y: items[child].y)
                top += linkWidth + 0.5
            }
        }

        // Live sessions: a glyph in today's column of their row, a lit path to main and their thread.
        func columnCenter(_ index: Int) -> CGFloat { stripX + columnWidth * (CGFloat(index) + 0.5) }
        /// Needs input before working, then oldest first.
        func liveRank(_ span: ProjectMap.Span) -> Int { span.live == LiveStatus.waiting.rawValue ? 0 : 1 }
        let liveSpans = map.spans.filter { $0.live != nil }.sorted { lhs, rhs in
            let left = liveRank(lhs)
            let right = liveRank(rhs)
            return left != right ? left < right : lhs.start < rhs.start
        }
        var livePath = Set<Int>()
        var liveMarks: [LiveMark] = []
        var marked = Set<Int>()
        for span in liveSpans {
            guard let index = laneItem[span.laneID] else { continue }
            var walk: Int? = index
            while let current = walk {
                livePath.insert(current)
                walk = items[current].parent
            }
            guard marked.insert(index).inserted else { continue }
            let kind: StatusGlyph.Kind = span.live == LiveStatus.waiting.rawValue ? .needsInput : .working
            let run = MapHitID.run(span.sessionKey, span.index)
            let item = items[index]
            if item.kind == .root, let bandY {
                liveMarks.append(LiveMark(id: span.id, run: run, kind: kind, point: CGPoint(x: columnCenter(count - 1), y: bandY),
                                          inHeader: true))
            } else if item.isLeaf {
                liveMarks.append(LiveMark(id: span.id, run: run, kind: kind, point: CGPoint(x: columnCenter(count - 1), y: item.y),
                                          inHeader: false))
            } else {
                liveMarks.append(LiveMark(id: span.id, run: run, kind: kind, point: CGPoint(x: item.x, y: item.y), inHeader: false))
            }
        }
        let liveThreads = Set(liveSpans.map(\.sessionKey)).sorted().compactMap { key -> SessionThread? in
            let path = sessionPaths[key] ?? []
            guard path.count >= 2, let source = runsBySession[key]?.first?.sourceID else { return nil }
            return SessionThread(sourceID: source, path: path)
        }

        // The root's words.
        let trunkTitle = map.isGitCheckout ? (laneByID[trunkID].map(MapText.title) ?? "main")
            : (map.projectPath as NSString).lastPathComponent
        var rootLabelRect = CGRect.null
        if let root = items.first {
            let titleWidth: CGFloat = min(150, MapTreeText.width(trunkTitle, size: 13, weight: .semibold)) + 4
            let title = CGRect(x: root.x - root.r - 2, y: root.y - root.r - 22, width: titleWidth, height: 18)
            let counts = CGRect(x: root.x - root.r - 2, y: root.y + root.r + 4, width: 64, height: 42)
            rootLabelRect = title.union(counts)
        }
        // The same words and places as `MapTreePainter.drawRootLabels`, measured with AppKit.
        var rootKnockouts: [CGRect] = []
        if let root = items.first {
            let left = root.x - root.r
            func knock(_ size: CGSize, top: CGFloat) -> CGRect {
                CGRect(x: left - 2, y: top, width: size.width + 4, height: size.height)
            }
            let shown = MapTreeText.width(trunkTitle, size: 13, weight: .semibold) > 150
                ? String(trunkTitle.prefix(18)) + "…" : trunkTitle
            let title = MapTreeText.size(shown, size: 13, weight: .semibold)
            rootKnockouts.append(knock(title, top: root.y - root.r - 5 - title.height))
            var top = root.y + root.r + 5
            let edits = MapTreeText.size(totalEdits.formatted(), size: 11, weight: .regular, digits: true)
            rootKnockouts.append(knock(edits, top: top))
            top += edits.height
            let word = MapTreeText.size(totalEdits == 1 ? "edit" : "edits", size: 10, weight: .medium)
            rootKnockouts.append(knock(word, top: top))
            top += word.height + 3
            if trunkEdits > 0, trunkEdits != totalEdits {
                let share = MapTreeText.size("\(trunkEdits.formatted()) on \(trunkTitle)", size: 10, weight: .medium,
                                             digits: true)
                rootKnockouts.append(knock(share, top: top))
            }
        }

        // Each label's knocked-out words, where `MapTreePainter` draws them.
        let labelHeight = MapTreeText.lineHeight(size: 11, weight: .semibold)
        let metaHeight = MapTreeText.lineHeight(size: 10, weight: .medium)
        for index in items.indices {
            let item = items[index]
            switch item.kind {
            case .root:
                continue
            case .quiet:
                let width = MapTreeText.meta(item.quietText)
                items[index].knocks = [CGRect(x: item.labelX - 2, y: item.y - metaHeight / 2, width: width + 4,
                                              height: metaHeight)]
            case .lane, .group:
                let name = MapTreeText.label(item.name.map(\.text).joined())
                guard !item.children.isEmpty else {
                    items[index].knocks = [CGRect(x: item.labelX - 2, y: item.y - labelHeight / 2, width: name + 4,
                                                  height: labelHeight)]
                    continue
                }
                let clearance = max(3, item.segmentWidth / 2 + 1.5)
                var knocks = [CGRect(x: item.labelX - 2, y: item.y - clearance - labelHeight, width: name + 4,
                                     height: labelHeight)]
                if !item.meta.isEmpty {
                    var width: CGFloat = 0
                    for (position, meta) in item.meta.enumerated() {
                        width += MapTreeText.meta(meta.text, digits: meta.tone == .count)
                            + (position > 0 ? MapTreeText.meta(" · ") : 0)
                    }
                    knocks.append(CGRect(x: item.labelX - 2, y: item.y + clearance, width: width + 4, height: metaHeight))
                }
                items[index].knocks = knocks
            }
        }

        // Hit testing's tables, in the order `target(at:)` searches them.
        var hits = Hits()
        for mark in liveMarks where !mark.inHeader { hits.marks.append(Hits.Point(center: mark.point, id: mark.run)) }
        for leaf in leafIndices {
            let item = items[leaf]
            hits.rows.append(Hits.Row(top: item.rowTop, bottom: item.rowBottom, minX: item.x - max(item.r, 3) - 4,
                                      leaf: leaf))
            for position in 0..<count { hits.cells.append(item.cellRuns[position] ?? item.cellCommits[position]) }
        }
        for index in items.indices {
            let item = items[index]
            hits.targets.append(MapTreeTarget(id: item.hitID, toggle: item.kind == .group ? item.groupKey : nil))
            if !item.captionRect.isNull {
                hits.captions.append(Hits.Caption(rect: item.captionRect,
                                                  target: MapTreeTarget(id: item.captionHitID, toggle: item.groupKey)))
            }
            if item.kind == .quiet {
                for bead in item.beads { hits.beads.append(Hits.Point(center: bead.center, id: bead.id)) }
            } else {
                let reach = max(item.r, 3) + 3
                hits.discs.append(Hits.Disc(center: CGPoint(x: item.x, y: item.y), reachSquared: reach * reach, index: index))
            }
            if !item.labelRect.isNull { hits.labels.append(Hits.Box(rect: item.labelRect, index: index)) }
            if item.kind != .root, !item.children.isEmpty {
                hits.lines.append(Hits.Line(minX: item.x, maxX: item.departX, y: item.y, index: index))
            }
        }

        // The caption over the tree, fitted beside the day columns.
        let captionTitle = "Branches"
        var hints: [String] = []
        if !opened.isEmpty {
            hints.append(opened.joined(separator: ", ") + " opened")
        } else if !groupKeys.isEmpty {
            hints.append("grouped by family")
        }
        if !hatches { hints.append("\(Int((delegatedShare * 100).rounded()))% by subagents") }
        hints.append("oldest first")
        if !groupKeys.isEmpty {
            hints.append("click a family to open it")
        } else if items.contains(where: { $0.kind == .lane && $0.lanes.first?.merge?.pullRequest != nil }) {
            hints.append("PR numbers where they merged")
        }
        let hintRoom = stripX - 12 - MapTreeText.width(captionTitle, size: 11, weight: .semibold) - 6
        while !hints.isEmpty, MapTreeText.caption(hints.joined(separator: " · ")) > hintRoom { hints.removeLast() }

        // One sentence for VoiceOver.
        let mergedCount = branches.filter { $0.merge != nil }.count + quietMarkers.count
        let branchTotal = branches.count + quietMarkers.count
        let sessionsText = GrowthText.sessions(map.sessionCount)
        let profilesText = GrowthText.profiles(present.count)
        var summary: String = "\(branchTotal) branches in \(leafIndices.count) rows, "
        summary += "\(mergedCount) merged into \(trunkTitle), \(sessionsText) by \(profilesText)"
        let families = items.filter { $0.kind == .group }.map { group in
            "\(group.name.map(\.text).joined()) \(group.lanes.count) branches, \(group.landed) landed"
        }
        if !families.isEmpty { summary += ". Families: " + families.joined(separator: "; ") }
        let working = liveSpans.filter { $0.live != LiveStatus.waiting.rawValue }.count
        let waiting = liveSpans.count - working
        if waiting > 0 { summary += ". \(waiting) needs input" }
        if working > 0 { summary += ". \(working) working" }
        let rows = leafIndices.compactMap { index -> String? in
            items[index].kind == .lane ? items[index].lanes.first.map(MapText.title) : nil
        }
        if !rows.isEmpty { summary += ". Branches: " + rows.joined(separator: ", ") }

        self.map = map
        self.width = width
        self.headerHeight = headerHeight
        self.bandY = bandY
        self.bodyHeight = contentHeight
        self.scrolls = scrolls
        self.stripX = stripX
        self.columns = columns
        self.bucketDays = bucket
        self.items = items
        self.leafIndices = leafIndices
        self.laneItem = laneItem
        self.quietMarkerItem = quietMarkerItem
        self.groupKeys = groupKeys
        self.openedKeys = openedKeys
        self.sourceIDs = sources
        self.sourceRank = rank
        self.hatches = hatches
        self.trunkTitle = trunkTitle
        self.trunkEdits = trunkEdits
        self.totalEdits = totalEdits
        self.rootDirect = rootDirect
        self.rootDelegated = rootDelegated
        self.trunkColumns = tallies[trunkID]?.columnSources ?? Array(repeating: [:], count: count)
        self.trunkCellRuns = (tallies[trunkID]?.best ?? [:]).mapValues { $0.id }
        self.liveMarks = liveMarks
        self.livePath = livePath
        self.liveThreads = liveThreads
        self.captionTitle = captionTitle
        self.captionHint = hints.joined(separator: " · ")
        self.rootLabelRect = rootLabelRect
        self.rootKnockouts = rootKnockouts
        self.sessionPaths = sessionPaths
        self.groupIndex = groupIndex
        self.hits = hits
        self.accessibilitySummary = summary
    }

    // MARK: Labels

    /// A node's label: beside a leaf, or over the line an internal node's children leave from.
    /// `departMax` bounds where that line ends, so the levels under it keep their share of the width.
    private static func placeLabel(_ item: inout Item, labelMax: CGFloat, departMax: CGFloat) {
        let internalNode = !item.children.isEmpty
        let labelX = item.x + item.r + 6 + (item.kind == .group ? 7 : 0)
        item.labelX = labelX
        let extras = metas(for: item, internalNode: internalNode)
        if internalNode {
            let natural = MapTreeText.label(item.name.map(\.text).joined())
            let wanted: CGFloat = min(labelX + natural + 8, labelMax - 140)
            let least: CGFloat = labelX + min(natural, 56) + 8
            let nearest: CGFloat = item.x + item.r + 2
            item.departX = max(nearest, min(max(wanted, least), departMax))
            let room = item.departX - 7 - labelX
            item.name = MapTreeText.fit(item.name, width: room)
            var kept: [Meta] = []
            var used: CGFloat = 0
            for meta in extras {
                let width = MapTreeText.meta(meta.text, digits: meta.tone == .count)
                    + (kept.isEmpty ? 0 : MapTreeText.meta(" · "))
                guard used + width <= room else { continue }
                kept.append(meta)
                used += width
            }
            item.meta = kept
            let nameWidth = MapTreeText.label(item.name.map(\.text).joined())
            item.labelRect = CGRect(x: labelX - 2, y: item.y - 17, width: max(nameWidth, used) + 4, height: 32)
            return
        }
        var pillWidth: CGFloat = 0
        if item.kind == .group {
            let pill = "×\(item.lanes.count)"
            item.pill = pill
            pillWidth = MapTreeText.width(pill, size: 10, weight: .semibold) + 8 + 4 + 9
        }
        let room = labelMax - labelX
        item.name = MapTreeText.fit(item.name, width: max(36, room - pillWidth))
        var used = MapTreeText.label(item.name.map(\.text).joined()) + 5 + pillWidth
        var kept: [Meta] = []
        for meta in extras {
            var shown = meta
            var width = MapTreeText.meta(shown.text, digits: shown.tone == .count) + 5
            if used + width > room, shown.text.hasSuffix(" landed") {
                shown.text = String(shown.text.dropLast(" landed".count))
                width = MapTreeText.meta(shown.text, digits: true) + 5
            }
            guard used + width <= room else { continue }
            kept.append(shown)
            used += width
        }
        item.meta = kept
        item.labelRect = CGRect(x: labelX - 2, y: item.y - 9, width: min(used, room) + 4, height: 18)
    }

    /// Counts, the pull request and the status after a label, most important first.
    private static func metas(for item: Item, internalNode: Bool) -> [Meta] {
        var metas: [Meta] = []
        if item.edits > 0 {
            metas.append(Meta(text: internalNode ? GrowthText.edits(item.edits) : item.edits.formatted(), tone: .count))
        }
        if item.kind == .lane, let number = item.lanes.first?.merge?.pullRequest {
            metas.append(Meta(text: "#\(number)", tone: .count))
        }
        if let live = item.live {
            let waiting = live.live == LiveStatus.waiting.rawValue
            metas.append(Meta(text: waiting ? "needs input" : "working", tone: waiting ? .waiting : .working))
            return metas
        }
        switch item.kind {
        case .group:
            if item.status == .noCommits {
                metas.append(Meta(text: "no commits", tone: .tag))
            } else if item.landed < item.lanes.count {
                metas.append(Meta(text: "\(item.landed)/\(item.lanes.count) landed", tone: .tag))
            }
        case .lane:
            switch item.status {
            case .folder: metas.append(Meta(text: "branch unknown", tone: .tag))
            case .deleted: metas.append(Meta(text: "deleted", tone: .tag))
            case .noCommits: metas.append(Meta(text: "no commits", tone: .tag))
            case .merged, .open: break
            }
        case .root, .quiet:
            break
        }
        return metas
    }

    /// Hollow beads, "6 merged, no edits", the pull requests as ranges and the names.
    private static func placeQuiet(_ item: inout Item, labelMax: CGFloat) {
        struct Entry {
            let id: MapHitID
            let merged: Bool
        }
        let entries = item.markers.map { Entry(id: .commit($0.sha), merged: true) }
            + item.lanes.map { Entry(id: .lane($0.id), merged: $0.merge != nil) }
        let shown = min(6, entries.count)
        let origin = CGPoint(x: item.x + 2, y: item.y)
        item.beads = (0..<shown).map { position in
            Bead(id: entries[position].id, center: CGPoint(x: origin.x + CGFloat(position) * 4.5, y: origin.y),
                 merged: entries[position].merged)
        }
        item.labelX = origin.x + CGFloat(shown) * 4.5 + 3
        let merged = entries.filter { $0.merged }.count
        let deleted = item.lanes.filter(\.deleted).count
        item.quietText = merged == entries.count ? "\(entries.count) merged, no edits"
            : deleted == entries.count ? "\(entries.count) deleted" : "\(entries.count) with no edits"
        var room = labelMax - item.labelX - MapTreeText.meta(item.quietText) - 6
        let numbers = Set(item.markers.compactMap(\.pullRequest) + item.lanes.compactMap { $0.merge?.pullRequest }).sorted()
        for pill in ranges(numbers) {
            let width = MapTreeText.meta(pill, digits: true) + 8 + 3
            guard width <= room else { break }
            item.quietPills.append(pill)
            room -= width
        }
        let names = item.markers.compactMap(\.quietBranch) + item.lanes.map(MapText.title)
        let joined = names.map(shortName).joined(separator: " · ")
        if room > 30 { item.quietNames = MapTreeText.fittedTail(joined, width: room - 4) }
        item.labelRect = CGRect(x: item.x - 2, y: item.y - 8, width: max(20, labelMax - item.x + 2), height: 16)
    }

    /// "#3–4", "#7", "#14–16".
    private static func ranges(_ numbers: [Int]) -> [String] {
        var result: [String] = []
        var run: (low: Int, high: Int)?
        for number in numbers {
            if let current = run, number == current.high + 1 {
                run = (current.low, number)
                continue
            }
            if let current = run { result.append(current.low == current.high ? "#\(current.low)" : "#\(current.low)–\(current.high)") }
            run = (number, number)
        }
        if let current = run { result.append(current.low == current.high ? "#\(current.low)" : "#\(current.low)–\(current.high)") }
        return result
    }

    private static func shortName(_ name: String) -> String {
        for prefix in ["claude/", "codex/"] where name.hasPrefix(prefix) && name.count > prefix.count {
            return String(name.dropFirst(prefix.count))
        }
        return name
    }

    /// A branch's name with the tool's prefix and a random suffix dimmed: "claude/" + "navigator-redesign" + "-ea237c".
    /// A prefix it shares with its parent ("wave-a/") dims the same way.
    static func namePieces(_ lane: ProjectMap.Lane, shared: String? = nil) -> [Piece] {
        var rest = MapText.title(lane)
        var pieces: [Piece] = []
        for prefix in ["claude/", "codex/", "worktree-"] + (shared.map { [$0] } ?? [])
        where rest.hasPrefix(prefix) && rest.count > prefix.count {
            pieces.append(Piece(text: prefix, alpha: 0.45))
            rest = String(rest.dropFirst(prefix.count))
            break
        }
        var tail: String?
        if let dash = rest.lastIndex(of: "-"), rest.distance(from: rest.startIndex, to: dash) >= 3 {
            let suffix = rest[rest.index(after: dash)...]
            if suffix.count == 6, suffix.allSatisfy(\.isHexDigit), suffix.contains(where: \.isNumber) {
                tail = String(rest[dash...])
                rest = String(rest[..<dash])
            }
        }
        pieces.append(Piece(text: rest, alpha: lane.kind == .folder ? 0.75 : 1))
        if let tail { pieces.append(Piece(text: tail, alpha: 0.45)) }
        return pieces
    }

    /// Inside an opened family the shared prefix goes: "billing" under nv/*, "agent 2" in a workflow run.
    static func memberPieces(_ lane: ProjectMap.Lane, familyKey: String) -> [Piece] {
        // The number comes from the raw branch: the display title already reads "workflow 28a8e52d · agent 3".
        if familyKey.hasPrefix("run:"), let agent = ProjectMap.workflowAgent(lane.title) {
            return [Piece(text: "agent ", alpha: 0.5), Piece(text: agent.agent, alpha: 1)]
        }
        let title = MapText.title(lane)
        if !familyKey.hasPrefix("run"), let prefix = ProjectMap.streamPrefix(lane.title), title.hasPrefix(prefix),
           title.count > prefix.count {
            return [Piece(text: String(title.dropFirst(prefix.count)), alpha: lane.kind == .folder ? 0.75 : 1)]
        }
        return namePieces(lane)
    }

    /// A folded family's label pieces, and its plain name for captions.
    static func familyTitle(_ key: String, members: [ProjectMap.Lane]) -> (pieces: [Piece], name: String) {
        if key == runsKey {
            let runs = Set(members.compactMap { ProjectMap.streamPrefix($0.title) }).count
            return ([Piece(text: "worktree-", alpha: 0.45), Piece(text: "wf_*", alpha: 1),
                     Piece(text: " · \(runs) runs", alpha: 0.5)], "workflow runs")
        }
        if key.hasPrefix("run:") {
            let run = String(key.dropFirst("run:".count))
            let dimmed = members.contains { $0.title.hasPrefix("worktree-") }
            return ((dimmed ? [Piece(text: "worktree-", alpha: 0.45)] : []) + [Piece(text: run + "-*", alpha: 1)], run + "-*")
        }
        return ([Piece(text: key + "*", alpha: 1)], key + "*")
    }

    private static func status(_ lane: ProjectMap.Lane) -> Status {
        if lane.merge != nil { return .merged }
        if lane.kind == .folder { return .folder }
        if lane.deleted { return .deleted }
        if lane.commitCount == 0 { return .noCommits }
        return .open
    }

    /// "wa-" for "wave-a/", "mob-" for "mob/": a worktree folder prefix and its branches'.
    private static func folderMatches(_ folder: String, branch: String) -> Bool {
        let stem = String(folder.dropLast())
        let branchStem = String(branch.dropLast())
        let initials = branchStem.split(separator: "-").compactMap(\.first).map(String.init).joined()
        return stem == branchStem || (initials.count >= 2 && stem == initials)
    }

    /// The profile with the most edits; ties go to legend order, then id.
    static func dominant(_ counts: [String: Int], rank: [String: Int]) -> String? {
        var best: (id: String, edits: Int, rank: Int)?
        for (id, edits) in counts where edits > 0 {
            let order = rank[id] ?? Int.max
            if let current = best {
                if edits < current.edits { continue }
                if edits == current.edits {
                    if order > current.rank { continue }
                    if order == current.rank, id >= current.id { continue }
                }
            }
            best = (id: id, edits: edits, rank: order)
        }
        return best?.id
    }

    func dominant(_ counts: [String: Int]) -> String? { Self.dominant(counts, rank: sourceRank) }

    /// Profiles in legend order.
    func ordered<S: Sequence>(_ ids: S) -> [String] where S.Element == String {
        ids.sorted { lhs, rhs in
            let left = sourceRank[lhs] ?? Int.max
            let right = sourceRank[rhs] ?? Int.max
            return left != right ? left < right : lhs < rhs
        }
    }

    // MARK: Hit testing

    /// Live heads first, then the strip's day cells, captions, nodes, beads, labels and rows.
    /// It runs on every pointer move, so it reads only the flat `hits` tables.
    func target(at point: CGPoint) -> MapTreeTarget? {
        func near(_ center: CGPoint, within reachSquared: CGFloat) -> Bool {
            let dx = center.x - point.x
            let dy = center.y - point.y
            return dx * dx + dy * dy <= reachSquared
        }
        for mark in hits.marks where near(mark.center, within: 64) { return MapTreeTarget(id: mark.id) }
        if point.x >= stripX - 2 {
            guard let row = hits.row(at: point.y) else { return nil }
            let column = min(Self.columnCount - 1, max(0, Int((point.x - stripX) / Self.columnWidth)))
            if let cell = hits.cells[row * Self.columnCount + column] { return MapTreeTarget(id: cell) }
            return hits.targets[hits.rows[row].leaf]
        }
        for caption in hits.captions where caption.rect.contains(point) { return caption.target }
        for disc in hits.discs where near(disc.center, within: disc.reachSquared) { return hits.targets[disc.index] }
        if rootLabelRect.contains(point), !hits.targets.isEmpty { return hits.targets[0] }
        for bead in hits.beads where near(bead.center, within: 3.5 * 3.5) { return MapTreeTarget(id: bead.id) }
        for label in hits.labels where label.rect.contains(point) { return hits.targets[label.index] }
        if let row = hits.row(at: point.y), point.x >= hits.rows[row].minX { return hits.targets[hits.rows[row].leaf] }
        for line in hits.lines where point.x >= line.minX && point.x <= line.maxX && abs(point.y - line.y) <= 5 {
            return hits.targets[line.index]
        }
        return nil
    }

    /// A day column for the time filter, or a run on the trunk's band.
    func headerTarget(at point: CGPoint) -> (id: MapHitID?, column: Int?) {
        guard point.x >= stripX - 2, point.x <= stripEnd + 2 else { return (nil, nil) }
        let column = min(Self.columnCount - 1, max(0, Int((point.x - stripX) / Self.columnWidth)))
        if let bandY, abs(point.y - bandY) <= 9 {
            if let mark = liveMarks.first(where: { $0.inHeader && abs($0.point.x - point.x) <= 7 }) { return (mark.run, nil) }
            return (trunkCellRuns[column], nil)
        }
        // The day heads sit above the band; with no band the whole header names a day.
        // Days before the range have nothing to filter, so they never name one.
        let overHeads: Bool = bandY.map { point.y < $0 - 9 } ?? true
        let named: Bool = overHeads && inRangeColumn(column) != nil
        return (nil, named ? column : nil)
    }
}

// MARK: - Text

/// Widths for layout, measured with the same system fonts the painter draws with.
private enum MapTreeText {
    static func width(_ text: String, size: CGFloat, weight: NSFont.Weight, digits: Bool = false) -> CGFloat {
        self.size(text, size: size, weight: weight, digits: digits).width
    }

    static func size(_ text: String, size: CGFloat, weight: NSFont.Weight, digits: Bool = false) -> CGSize {
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        let measured = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(measured.width), height: ceil(measured.height))
    }

    /// One line's height in the system font.
    static func lineHeight(size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        self.size("Ag", size: size, weight: weight).height
    }

    /// Node labels: 11 pt semibold.
    static func label(_ text: String) -> CGFloat { width(text, size: 11, weight: .semibold) }

    /// Counts and tags: `Theme.Typeface.micro`.
    static func meta(_ text: String, digits: Bool = false) -> CGFloat {
        width(text, size: 10, weight: .medium, digits: digits)
    }

    static func caption(_ text: String) -> CGFloat { width(text, size: 11, weight: .regular) }

    /// Fits a label: first without its dimmed tool prefix, then without its random suffix,
    /// then middle-truncated with both ends readable.
    static func fit(_ pieces: [MapTreeLayout.Piece], width: CGFloat) -> [MapTreeLayout.Piece] {
        func total(_ value: [MapTreeLayout.Piece]) -> CGFloat { label(value.map(\.text).joined()) }
        guard total(pieces) > width else { return pieces }
        var trimmed = pieces
        if trimmed.count > 1, let first = trimmed.first, first.alpha < 0.6 {
            trimmed.removeFirst()
            if total(trimmed) <= width { return trimmed }
        }
        if trimmed.count > 1, let last = trimmed.last, last.alpha < 0.6 {
            trimmed.removeLast()
            if total(trimmed) <= width { return trimmed }
        }
        let joined = trimmed.map(\.text).joined()
        let alpha = trimmed.map(\.alpha).max() ?? 1
        return [MapTreeLayout.Piece(text: middleTruncated(joined, width: width), alpha: alpha)]
    }

    static func middleTruncated(_ text: String, width: CGFloat) -> String {
        guard label(text) > width else { return text }
        func candidate(_ keep: Int) -> String { "\(text.prefix((keep + 1) / 2))…\(text.suffix(keep / 2))" }
        var low = 2
        var high = text.count - 1
        var best: String?
        while low <= high {
            let middle = (low + high) / 2
            if label(candidate(middle)) <= width {
                best = candidate(middle)
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return best ?? String(text.prefix(1)) + "…"
    }

    static func fittedTail(_ text: String, width: CGFloat) -> String {
        guard meta(text) > width else { return text }
        var low = 0
        var high = text.count
        var best = ""
        while low <= high {
            let middle = (low + high) / 2
            let candidate = String(text.prefix(middle)).trimmingCharacters(in: .whitespaces) + "…"
            if meta(candidate) <= width {
                best = candidate
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return best
    }
}

// MARK: - Emphasis

/// What stands out: the hovered or selected item with its path to main, a session's
/// branches and a filtered day. A focused profile belongs to the static drawing.
private struct MapTreeEmphasis {
    /// The hovered or selected item's node.
    let ring: Int?
    /// A hovered session with branches in the tree: they stay lit with their paths to main.
    let session: MapTreeSession?
    /// A filtered day: rows with no edits that day dim.
    let column: Int?

    /// Something dims, so the overlay veils the static tree.
    var veiled: Bool { session != nil || column != nil }

    init(layout: MapTreeLayout, id: MapHitID?, column: Int?) {
        var ring: Int?
        var session: MapTreeSession?
        if let item = id.flatMap({ MapHit.resolve($0, in: layout.map) }) {
            switch item {
            case .live(let span), .span(let span):
                ring = layout.laneItem[span.laneID]
                if let path = layout.sessionPaths[span.sessionKey], !path.isEmpty {
                    session = MapTreeSession(key: span.sessionKey, sourceID: span.sourceID)
                }
            case .commit(let marker):
                ring = layout.quietMarkerItem[marker.sha] ?? layout.laneItem[marker.mergedLaneID ?? marker.laneID]
            case .cluster(let markers):
                for marker in markers {
                    let laneID = marker.mergedLaneID ?? marker.laneID
                    if let found = layout.quietMarkerItem[marker.sha] ?? layout.laneItem[laneID] {
                        ring = found
                        break
                    }
                }
            case .lane(let lane):
                ring = layout.laneItem[lane.id]
            case .group(let lanes):
                ring = layout.groupIndex[lanes.map(\.id).sorted()] ?? lanes.first.flatMap { layout.laneItem[$0.id] }
            case .fold:
                break
            }
        }
        self.ring = ring
        self.session = session
        self.column = column
    }
}

/// Which items one drawing of the body draws in full, and at what strength.
private struct MapTreePass {
    let focusSourceID: String?
    /// Per item: 1, or 0.28 where the focused profile made none of the subtree's edits.
    let alphas: [Double]
    /// Per item: drawn in full. Nil keeps every item, as the static drawing does; over its
    /// veil the overlay keeps only what an emphasis leaves lit.
    let kept: [Bool]?

    init(layout: MapTreeLayout, focusSourceID: String?, kept: [Bool]?) {
        self.focusSourceID = focusSourceID
        self.kept = kept
        alphas = layout.items.map { item -> Double in
            guard item.kind != .root, let focusSourceID else { return 1 }
            return (item.subtreeBySource[focusSourceID] ?? 0) == 0 ? 0.28 : 1
        }
    }

    var isOverlay: Bool { kept != nil }

    func keeps(_ index: Int) -> Bool { kept?[index] ?? true }

    /// What a hovered session and a filtered day leave lit: the session's branches with their
    /// paths to main, and the rows with edits that day. The root always stays lit.
    static func lit(_ layout: MapTreeLayout, session: String?, column: Int?) -> [Bool] {
        let items = layout.items
        var onPath: [Bool]?
        if let session, let path = layout.sessionPaths[session], !path.isEmpty {
            var marks = [Bool](repeating: false, count: items.count)
            for index in path {
                var walk: Int? = index
                while let current = walk, !marks[current] {
                    marks[current] = true
                    walk = items[current].parent
                }
            }
            onPath = marks
        }
        return items.indices.map { index -> Bool in
            guard items[index].kind != .root else { return true }
            if let onPath, !onPath[index] { return false }
            if let column, items[index].subtreeColumns[column] == 0 { return false }
            return true
        }
    }
}

/// Appearance-dependent choices, with every dynamic color flattened once per drawing.
private struct MapTreeStyle {
    let dark: Bool
    let hatches: Bool
    let colors: [String: Color]
    let working: Color
    let needsInput: Color
    let workingText: Color
    let needsInputText: Color

    init(hatches: Bool, colors: [String: Color], in environment: EnvironmentValues) {
        dark = environment.colorScheme == .dark
        self.hatches = hatches
        self.colors = colors.mapValues { $0.flattened(in: environment) }
        working = Theme.Palette.working.flattened(in: environment)
        needsInput = Theme.Palette.needsInput.flattened(in: environment)
        workingText = Theme.Palette.workingText.flattened(in: environment)
        needsInputText = Theme.Palette.needsInputText.flattened(in: environment)
    }

    func color(_ id: String?) -> Color { id.flatMap { colors[$0] } ?? Color.primary.opacity(0.45) }

    func live(_ span: ProjectMap.Span) -> Color { span.live == LiveStatus.waiting.rawValue ? needsInput : working }

    var landedLink: Double { dark ? 0.40 : 0.34 }
    var openLink: Double { dark ? 0.20 : 0.16 }
    var hatchBase: Double { dark ? 0.38 : 0.30 }
    var disc: Double { dark ? 0.06 : 0.04 }
}

// MARK: - Painter

private enum MapTreePainter {
    /// Leaves what it covers at 0.3, the strength the full drawing gave what an emphasis left out.
    static let veilOpacity = 0.7

    private static func ink(_ opacity: Double) -> Color { Color.primary.opacity(opacity) }

    private static var labelFont: Font { Font.system(size: 11, weight: .semibold) }

    private static func knockout(_ path: Path, in context: inout GraphicsContext) {
        var clear = context
        clear.blendMode = .destinationOut
        clear.fill(path, with: .color(.black))
    }

    /// Clears words' places without measuring them again.
    private static func clear(_ rects: [CGRect], in context: inout GraphicsContext) {
        for rect in rects { knockout(Path(roundedRect: rect, cornerRadius: 3), in: &context) }
    }

    private static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    private static func measure(_ text: GraphicsContext.ResolvedText) -> CGSize {
        text.measure(in: CGSize(width: 1_000, height: 40))
    }

    // MARK: Header

    /// The caption and the trunk's own edits: the header but its day heads.
    static func drawHeader(_ layout: MapTreeLayout, style: MapTreeStyle, focusSourceID: String?, size: CGSize,
                           in context: inout GraphicsContext) {
        context.clip(to: Path(CGRect(origin: .zero, size: size)))
        let title = context.resolve(Text(layout.captionTitle).font(Theme.Typeface.caption.weight(.semibold))
            .foregroundColor(ink(0.85)))
        context.draw(title, at: CGPoint(x: 0, y: 2), anchor: .topLeading)
        if !layout.captionHint.isEmpty {
            let hint = context.resolve(Text(layout.captionHint).font(Theme.Typeface.caption).foregroundColor(ink(0.4)))
            context.draw(hint, at: CGPoint(x: measure(title).width + 6, y: 2), anchor: .topLeading)
        }
        guard let bandY = layout.bandY else { return }
        let label = context.resolve(Text("on \(layout.trunkTitle)").font(Theme.Typeface.micro).foregroundColor(ink(0.4)))
        context.draw(label, at: CGPoint(x: layout.stripX - 4, y: bandY), anchor: .trailing)
        let headerLive = layout.liveMarks.first(where: \.inHeader)
        for index in 0..<MapTreeLayout.columnCount {
            let center = CGPoint(x: layout.columnX(index), y: bandY)
            var counts = layout.trunkColumns[index]
            if let focus = focusSourceID { counts = counts.filter { $0.key == focus } }
            let edits = counts.values.reduce(0, +)
            var radius: CGFloat = 0
            if edits == 0 {
                context.fill(circle(center, 0.8), with: .color(ink(0.13)))
            } else {
                let perDay: Double = Double(edits) / Double(layout.bucketDays)
                let grown: CGFloat = 1.4 + 0.5 * CGFloat(perDay.squareRoot())
                radius = min(5.5, grown)
                let order = layout.ordered(counts.keys)
                if order.count > 1 {
                    // A small pie when several assistants edited main that day.
                    var angle: Double = -90
                    for id in order {
                        let share: Int = counts[id] ?? 0
                        let sweep: Double = 360 * Double(share) / Double(edits)
                        var wedge = Path()
                        wedge.move(to: center)
                        wedge.addArc(center: center, radius: radius, startAngle: .degrees(angle),
                                     endAngle: .degrees(angle + sweep), clockwise: false)
                        wedge.closeSubpath()
                        context.fill(wedge, with: .color(style.color(id)))
                        angle += sweep
                    }
                } else {
                    context.fill(circle(center, radius), with: .color(style.color(order.first)))
                }
            }
            if index == MapTreeLayout.columnCount - 1, let mark = headerLive {
                let color = mark.kind == .needsInput ? style.needsInput : style.working
                context.stroke(circle(center, max(5.5, radius + 2)), with: .color(color), lineWidth: 1.1)
            }
        }
        var hairline = Path()
        hairline.move(to: CGPoint(x: layout.stripX + 3, y: bandY + 10.5))
        hairline.addLine(to: CGPoint(x: layout.stripEnd - 3, y: bandY + 10.5))
        context.stroke(hairline, with: .color(ink(0.08)), lineWidth: 1)
    }

    /// The strength of today's band down the strip, and of a filtered day's.
    private static let todayBand = 0.035
    private static let filteredBand = 0.07
    /// A filtered day's heads.
    private static let filteredHead = 0.95

    /// The strength that, drawn in the same ink over `base`, adds up to `target`. A filtered
    /// day is drawn over the resting strip rather than in place of it, so the rest of the
    /// strip never changes while the filter fades in and out.
    private static func over(_ base: Double, reaching target: Double) -> Double {
        1 - (1 - target) / (1 - base)
    }

    /// The day heads over the strip, at rest, and the band down today's column. A filtered
    /// day adds its own layer, `drawFilteredHeads`. Nothing else in the header overlaps them.
    static func drawHeaderColumns(_ layout: MapTreeLayout, size: CGSize, in context: inout GraphicsContext) {
        context.clip(to: Path(CGRect(origin: .zero, size: size)))
        drawTodayBand(layout, from: 0, to: size.height + 12, in: &context)
        for (index, column) in layout.columns.enumerated() {
            let weight: Font.Weight = column.isToday ? .semibold : .medium
            drawHeads(column, x: layout.columnX(index), opacity: restingHead(column), weight: weight, in: &context)
        }
    }

    /// A filtered day over the resting heads: its band and its heads in semibold, at strengths
    /// that add up over the resting drawing to what a filtered day shows.
    static func drawFilteredHeads(_ layout: MapTreeLayout, column index: Int, size: CGSize,
                                  in context: inout GraphicsContext) {
        guard layout.columns.indices.contains(index) else { return }
        context.clip(to: Path(CGRect(origin: .zero, size: size)))
        drawFilteredBand(layout, column: index, from: 0, to: size.height + 12, in: &context)
        let column = layout.columns[index]
        drawHeads(column, x: layout.columnX(index), opacity: over(restingHead(column), reaching: filteredHead),
                  weight: .semibold, in: &context)
    }

    /// A day head's strength at rest: today bright, days before the range faint.
    private static func restingHead(_ column: MapTreeLayout.Column) -> Double {
        if column.isToday { return 0.85 }
        return column.inRange ? 0.42 : 0.2
    }

    /// A column's two heads, the weekday or month over the day of the month.
    private static func drawHeads(_ column: MapTreeLayout.Column, x: CGFloat, opacity: Double, weight: Font.Weight,
                                  in context: inout GraphicsContext) {
        if !column.top.isEmpty {
            let top = context.resolve(Text(column.top).font(Theme.Typeface.micro.weight(weight)).foregroundColor(ink(opacity)))
            context.draw(top, at: CGPoint(x: x, y: 1), anchor: .top)
        }
        let bottom = context.resolve(Text(column.bottom).font(Theme.Typeface.micro.weight(weight).monospacedDigit())
            .foregroundColor(ink(opacity)))
        context.draw(bottom, at: CGPoint(x: x, y: 13), anchor: .top)
    }

    /// A column's band down the strip, from `top` to `bottom`.
    private static func bandRect(_ layout: MapTreeLayout, column index: Int, from top: CGFloat, to bottom: CGFloat) -> CGRect {
        CGRect(x: layout.stripX + CGFloat(index) * MapTreeLayout.columnWidth + 1, y: top,
               width: MapTreeLayout.columnWidth - 2, height: max(0, bottom - top))
    }

    /// Today's column as a soft band down the strip.
    private static func drawTodayBand(_ layout: MapTreeLayout, from top: CGFloat, to bottom: CGFloat,
                                      in context: inout GraphicsContext) {
        for (index, column) in layout.columns.enumerated() where column.isToday {
            let rect = bandRect(layout, column: index, from: top, to: bottom)
            context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(ink(todayBand)))
        }
    }

    /// A filtered day's band, over today's where it is today, so the two add up to one band.
    static func drawFilteredBand(_ layout: MapTreeLayout, column index: Int, from top: CGFloat, to bottom: CGFloat,
                                 in context: inout GraphicsContext) {
        guard layout.columns.indices.contains(index) else { return }
        let strength = layout.columns[index].isToday ? over(todayBand, reaching: filteredBand) : filteredBand
        let rect = bandRect(layout, column: index, from: top, to: bottom)
        context.fill(Path(roundedRect: rect, cornerRadius: 5), with: .color(ink(strength)))
    }

    // MARK: Body

    /// The tree. The static drawing draws every item; over its veil the overlay draws the items
    /// `pass` keeps, and again whatever no emphasis dims: the root, live paths and status,
    /// session threads and opened families' captions.
    static func drawBody(_ layout: MapTreeLayout, style: MapTreeStyle, pass: MapTreePass,
                         thread: MapTreeLayout.SessionThread?, size: CGSize, in context: inout GraphicsContext) {
        context.clip(to: Path(CGRect(origin: .zero, size: size)))
        // The overlay's veil layer draws its own bands, over the veil.
        if !pass.isOverlay { drawTodayBand(layout, from: -12, to: size.height - 2, in: &context) }
        drawStripGuides(layout, pass: pass, in: &context)
        // Dimmed labels left out of the overlay must still clear the threads it draws again.
        let clearsDimmed = pass.isOverlay && (thread != nil || !layout.liveThreads.isEmpty)
        // One layer, so knockouts clear only marks drawn here, never the card or the bands behind.
        context.drawLayer { layer in
            drawLinks(layout, style: style, pass: pass, in: &layer)
            drawThreads(layout, style: style, focused: thread, in: &layer)
            for index in layout.items.indices {
                drawNode(index, layout, style: style, pass: pass, in: &layer)
            }
            drawLabels(layout, style: style, pass: pass, clearsDimmed: clearsDimmed, in: &layer)
        }
        drawStripDots(layout, style: style, pass: pass, in: &context)
    }

    /// Over the static tree once something dims: the veil, then today's band, which the full
    /// drawing keeps under its items, at full strength. The filtered day's band and the row
    /// highlight join it over the veil in layers of their own, which crossfade.
    static func drawVeil(_ layout: MapTreeLayout, color: Color, size: CGSize, in context: inout GraphicsContext) {
        context.clip(to: Path(CGRect(origin: .zero, size: size)))
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color))
        drawTodayBand(layout, from: -12, to: size.height - 2, in: &context)
    }

    /// The hovered or selected row, highlighted across into the strip.
    static func drawRowHighlight(_ layout: MapTreeLayout, ring: Int?, in context: inout GraphicsContext) {
        guard let ring, layout.items[ring].kind != .root else { return }
        let item = layout.items[ring]
        let half = max(item.r + 3.5, 8)
        let left = item.x - max(item.r, 3) - 5
        let rect = CGRect(x: left, y: item.y - half, width: layout.stripEnd + 1 - left, height: half * 2)
        context.fill(Path(roundedRect: rect, cornerRadius: half), with: .color(ink(0.05)))
    }

    /// The hovered or selected item's path to main in ink, then its ring. The path's nodes and
    /// the root's words clear the path, as they clear the links under them in the full drawing.
    static func drawHover(_ layout: MapTreeLayout, ring: Int?, in context: inout GraphicsContext) {
        guard let ring else { return }
        let items = layout.items
        let color = ink(0.85)
        context.drawLayer { layer in
            var below: Int?
            var walk: Int? = ring
            while let current = walk {
                let item = items[current]
                if item.kind != .root {
                    layer.stroke(linkPath(item), with: .color(color), lineWidth: 0.9)
                    if below != nil { layer.stroke(segmentPath(item), with: .color(color), lineWidth: 0.9) }
                }
                below = current
                walk = item.parent
            }
            walk = ring
            while let current = walk {
                let item = items[current]
                if item.kind == .quiet {
                    for bead in item.beads { knockout(circle(bead.center, 2.5), in: &layer) }
                } else {
                    knockout(circle(CGPoint(x: item.x, y: item.y), item.r + 1), in: &layer)
                }
                walk = item.parent
            }
            clear(layout.rootKnockouts, in: &layer)
            let item = items[ring]
            // A quiet row's beads take no ring.
            guard item.kind != .quiet else { return }
            layer.stroke(circle(CGPoint(x: item.x, y: item.y), item.r + (item.live != nil ? 4.2 : 2.6)),
                         with: .color(ink(0.9)), lineWidth: 1.1)
        }
    }

    /// A faint guide per row in the strip, and the branch's lifetime from fork to merge under its dots.
    private static func drawStripGuides(_ layout: MapTreeLayout, pass: MapTreePass, in context: inout GraphicsContext) {
        for leaf in layout.leafIndices where pass.keeps(leaf) {
            let item = layout.items[leaf]
            let alpha = pass.alphas[leaf]
            var guide = Path()
            guide.move(to: CGPoint(x: layout.stripX + 3, y: item.y))
            guide.addLine(to: CGPoint(x: layout.stripEnd - 3, y: item.y))
            context.stroke(guide, with: .color(ink(0.05 * alpha)), lineWidth: 1)
            guard let lifetime = item.lifetime else { continue }
            var line = Path()
            line.move(to: CGPoint(x: layout.columnX(lifetime.lowerBound), y: item.y))
            line.addLine(to: CGPoint(x: layout.columnX(lifetime.upperBound), y: item.y))
            context.stroke(line, with: .color(ink(0.2 * alpha)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
    }

    // MARK: Links

    private static func linkPath(_ item: MapTreeLayout.Item) -> Path {
        let start = item.linkStart
        let end = item.linkEnd
        var path = Path()
        path.move(to: start)
        path.addCurve(to: end, control1: CGPoint(x: start.x + (end.x - start.x) * 0.55, y: start.y),
                      control2: CGPoint(x: start.x + (end.x - start.x) * 0.45, y: end.y))
        return path
    }

    private static func segmentPath(_ item: MapTreeLayout.Item) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: item.x, y: item.y))
        path.addLine(to: CGPoint(x: item.departX, y: item.y))
        return path
    }

    /// Rivers to each child, solid where the branch landed and faint with a dashed core where
    /// it did not, and the live sessions' paths to main in green.
    private static func drawLinks(_ layout: MapTreeLayout, style: MapTreeStyle, pass: MapTreePass,
                                  in context: inout GraphicsContext) {
        let items = layout.items
        if style.dark {
            context.drawLayer { glow in
                glow.addFilter(.blur(radius: 1.6))
                for index in items.indices where pass.keeps(index) {
                    let item = items[index]
                    let color = style.color(item.dominant).opacity(0.22 * pass.alphas[index])
                    if item.parent != nil, item.kind != .quiet, item.subtreeEdits > 0, item.linkWidth > 1.5 {
                        glow.stroke(linkPath(item), with: .color(color), lineWidth: item.linkWidth + 3)
                    }
                    if item.kind != .root, !item.children.isEmpty, item.segmentWidth > 1.5 {
                        glow.stroke(segmentPath(item), with: .color(color), lineWidth: item.segmentWidth + 3)
                    }
                }
            }
        }
        for index in items.indices where pass.keeps(index) {
            let item = items[index]
            let alpha = pass.alphas[index]
            if item.kind != .root, !item.children.isEmpty {
                let color = style.color(item.dominant)
                let opacity = (item.isLanded ? style.landedLink : style.openLink) * alpha
                context.stroke(segmentPath(item), with: .color(color.opacity(opacity)), lineWidth: item.segmentWidth)
                context.fill(circle(CGPoint(x: item.departX, y: item.y), max(1.25, item.segmentWidth / 2)),
                             with: .color(color.opacity(opacity)))
            }
            guard item.parent != nil else { continue }
            let path = linkPath(item)
            if item.kind == .quiet || item.subtreeEdits == 0 {
                context.stroke(path, with: .color(ink(0.26 * alpha)),
                               style: StrokeStyle(lineWidth: 0.65, lineCap: .round, dash: [1, 2]))
                continue
            }
            let color = style.color(item.dominant)
            context.stroke(path, with: .color(color.opacity((item.isLanded ? style.landedLink : style.openLink) * alpha)),
                           lineWidth: item.linkWidth)
            if !item.isLanded {
                context.stroke(path, with: .color(color.opacity(0.8 * alpha)),
                               style: StrokeStyle(lineWidth: 0.75, lineCap: .round, dash: [1.5, 2.5]))
            }
        }
        drawPath(layout.livePath, layout, color: style.working.opacity(0.9), in: &context)
    }

    private static func drawPath(_ path: Set<Int>, _ layout: MapTreeLayout, color: Color,
                                 in context: inout GraphicsContext) {
        for index in path.sorted() {
            let item = layout.items[index]
            guard item.kind != .root else { continue }
            if item.parent != nil { context.stroke(linkPath(item), with: .color(color), lineWidth: 0.9) }
            if !item.children.isEmpty, item.children.contains(where: path.contains) {
                context.stroke(segmentPath(item), with: .color(color), lineWidth: 0.9)
            }
        }
    }

    /// A dotted arc in the profile color through the branches one session moved between: the
    /// live sessions', and the hovered session's, which takes the label.
    private static func drawThreads(_ layout: MapTreeLayout, style: MapTreeStyle,
                                    focused: MapTreeLayout.SessionThread?, in context: inout GraphicsContext) {
        var threads = layout.liveThreads
        if let focused, !threads.contains(where: { $0.path == focused.path }) { threads.append(focused) }
        let labelled = focused?.path ?? threads.first?.path
        let items = layout.items
        func anchor(_ index: Int) -> CGPoint {
            let item = items[index]
            return CGPoint(x: item.kind == .quiet ? item.x - 2 : item.x - max(item.r, 2.5) - 2, y: item.y)
        }
        for thread in threads {
            let color = style.color(thread.sourceID)
            var bendMin = CGFloat.infinity
            for (from, to) in zip(thread.path, thread.path.dropFirst()) {
                let start = anchor(from)
                let end = anchor(to)
                let lean: CGFloat = min(24, abs(end.y - start.y) * 0.12)
                let left: CGFloat = min(start.x, end.x) - 10 - lean
                let bend: CGFloat = max(4, left)
                bendMin = min(bendMin, bend)
                var arc = Path()
                arc.move(to: start)
                arc.addCurve(to: end, control1: CGPoint(x: bend, y: start.y), control2: CGPoint(x: bend, y: end.y))
                context.stroke(arc, with: .color(color.opacity(0.9)),
                               style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0.5, 2.6]))
            }
            guard thread.path == labelled, let first = thread.path.first, let last = thread.path.last,
                  let root = items.first, bendMin.isFinite else { continue }
            // Left of the arc's bulge, clear of the root; shorter when the room is short.
            let right = bendMin + 2
            var chosen: GraphicsContext.ResolvedText?
            for word in ["same session", "session"] {
                let candidate = context.resolve(Text(word).font(Theme.Typeface.micro).foregroundColor(color.opacity(0.9)))
                if right - measure(candidate).width >= root.x + root.r + 4 {
                    chosen = candidate
                    break
                }
            }
            guard let text = chosen else { continue }
            let size = measure(text)
            let point = CGPoint(x: right, y: (items[first].y + items[last].y) / 2)
            knockout(Path(roundedRect: CGRect(x: point.x - size.width - 2, y: point.y - size.height / 2,
                                              width: size.width + 4, height: size.height), cornerRadius: 3), in: &context)
            context.draw(text, at: point, anchor: .trailing)
        }
    }

    // MARK: Nodes

    /// A ring split by profile with hatched subagent shares, a center dot once it landed, a
    /// dashed halo when it never committed, and a status ring while a session is live.
    private static func drawNode(_ index: Int, _ layout: MapTreeLayout, style: MapTreeStyle, pass: MapTreePass,
                                 in context: inout GraphicsContext) {
        guard pass.keeps(index) else {
            // The veiled drawing beneath keeps the dimmed node. Over the veil a live session's
            // glow and status ring stay bright, and the live path must not cross the node.
            // Read field by field: the overlay passes over every item it leaves out.
            let center = CGPoint(x: layout.items[index].x, y: layout.items[index].y)
            let r = layout.items[index].r
            if let live = layout.items[index].live {
                drawLiveGlow(center, r, color: style.live(live), style: style, in: &context)
                knockout(circle(center, r + 1), in: &context)
                context.stroke(circle(center, r + 2.25), with: .color(style.live(live).opacity(0.6)), lineWidth: 1.3)
            } else if layout.items[index].kind != .quiet, layout.livePath.contains(index) {
                knockout(circle(center, r + 1), in: &context)
            }
            return
        }
        let item = layout.items[index]
        let center = CGPoint(x: item.x, y: item.y)
        let r = item.r
        let alpha = pass.alphas[index] * (item.status.isFaded ? 0.5 : 1)
        switch item.kind {
        case .quiet:
            for bead in item.beads {
                knockout(circle(bead.center, 2.5), in: &context)
                context.stroke(circle(bead.center, 1.8), with: .color(ink(0.45 * alpha)), lineWidth: 0.7)
                if bead.merged { context.fill(circle(bead.center, 0.6), with: .color(ink(0.6 * alpha))) }
            }
            return
        case .root:
            context.fill(circle(center, r + 16), with: .radialGradient(Gradient(colors: [ink(0.10), ink(0)]), center: center,
                                                                       startRadius: r * 0.5, endRadius: r + 16))
        case .group:
            // A ghost stack: the folded members behind the family's ring.
            for offset in [6, 3] as [CGFloat] {
                let ghost = CGPoint(x: center.x + offset, y: center.y - offset * 0.62)
                knockout(circle(ghost, r + 0.6), in: &context)
                context.fill(circle(ghost, r), with: .color(ink(style.disc)))
                context.stroke(circle(ghost, r), with: .color(ink(0.18 * alpha)), lineWidth: 0.7)
            }
        case .lane:
            break
        }
        if let live = item.live { drawLiveGlow(center, r, color: style.live(live), style: style, in: &context) }
        knockout(circle(center, r + 1), in: &context)
        context.fill(circle(center, r), with: .color(ink(style.disc)))
        drawRing(item, layout, style: style, focusSourceID: pass.focusSourceID, alpha: alpha, in: &context)
        if item.kind != .root, item.status.isDashed {
            context.stroke(circle(center, r + 2), with: .color(ink(0.42 * alpha)),
                           style: StrokeStyle(lineWidth: 0.7, dash: [1.5, 1.75]))
        }
        if item.kind == .root {
            context.fill(circle(center, r * 0.34), with: .color(ink(0.92)))
        } else if let live = item.live {
            context.fill(circle(center, max(1.2, r * 0.22)), with: .color(style.live(live).opacity(alpha)))
        } else if item.isLanded {
            context.fill(circle(center, item.edits > 0 ? max(1.1, r * 0.2) : 0.9), with: .color(ink(0.88 * alpha)))
        }
        if let live = item.live {
            context.stroke(circle(center, r + 2.25), with: .color(style.live(live).opacity(max(alpha, 0.6))), lineWidth: 1.3)
        }
    }

    /// A live node's soft glow, in dark mode.
    private static func drawLiveGlow(_ center: CGPoint, _ r: CGFloat, color: Color, style: MapTreeStyle,
                                      in context: inout GraphicsContext) {
        guard style.dark else { return }
        context.drawLayer { glow in
            glow.addFilter(.blur(radius: 3))
            glow.fill(circle(center, r + 4), with: .color(color.opacity(0.32)))
        }
    }

    private static func drawRing(_ item: MapTreeLayout.Item, _ layout: MapTreeLayout, style: MapTreeStyle,
                                 focusSourceID: String?, alpha: Double, in context: inout GraphicsContext) {
        let center = CGPoint(x: item.x, y: item.y)
        let r = item.r
        let direct = item.kind == .root ? layout.rootDirect : item.direct
        let delegated = item.kind == .root ? layout.rootDelegated : item.delegated
        var segments: [(source: String, count: Int, hatched: Bool)] = []
        for id in layout.ordered(Set(direct.keys).union(delegated.keys)) {
            let own = direct[id] ?? 0
            let agents = delegated[id] ?? 0
            if style.hatches {
                if own > 0 { segments.append((id, own, false)) }
                if agents > 0 { segments.append((id, agents, true)) }
            } else if own + agents > 0 {
                segments.append((id, own + agents, false))
            }
        }
        let total = segments.reduce(0) { $0 + $1.count }
        guard total > 0 else {
            context.stroke(circle(center, max(1, r - 0.4)), with: .color(ink(0.45 * alpha)), lineWidth: 0.8)
            return
        }
        func segmentAlpha(_ source: String?) -> Double {
            guard let focus = focusSourceID else { return alpha }
            return focus == source ? alpha : alpha * 0.25
        }
        if r < 4 {
            var bySource: [String: Int] = [:]
            for segment in segments { bySource[segment.source, default: 0] += segment.count }
            let main = layout.dominant(bySource)
            context.fill(circle(center, r), with: .color(style.color(main).opacity(segmentAlpha(main))))
            return
        }
        let thickness: CGFloat = max(1.6, r * 0.36)
        let radius: CGFloat = r - thickness / 2
        let gap: Double = segments.count > 1 && r >= 5 ? 2.2 : 0
        var angle: Double = -90
        for segment in segments {
            let sweep = 360 * Double(segment.count) / Double(total)
            let start = angle + gap / 2
            let end = angle + sweep - gap / 2
            angle += sweep
            guard end > start else { continue }
            var arc = Path()
            if sweep >= 359.9 {
                arc.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            } else {
                arc.addArc(center: center, radius: radius, startAngle: .degrees(start), endAngle: .degrees(end), clockwise: false)
            }
            var layer = context
            layer.opacity = segmentAlpha(segment.source)
            let color = style.color(segment.source)
            if segment.hatched {
                hatch(arc.strokedPath(StrokeStyle(lineWidth: thickness)), color: color, base: style.hatchBase, in: &layer)
            } else {
                layer.stroke(arc, with: .color(color), lineWidth: thickness)
            }
        }
    }

    /// Diagonal stripes over a faint fill of the same color, as the Lanes view hatches subagent edits.
    private static func hatch(_ shape: Path, color: Color, base: Double, in context: inout GraphicsContext) {
        var inner = context
        inner.clip(to: shape)
        inner.fill(shape, with: .color(color.opacity(base)))
        let bounds = shape.boundingRect
        var stripes = Path()
        var x = bounds.minX - bounds.height
        while x < bounds.maxX {
            stripes.move(to: CGPoint(x: x, y: bounds.maxY))
            stripes.addLine(to: CGPoint(x: x + bounds.height, y: bounds.minY))
            x += 2.6
        }
        inner.stroke(stripes, with: .color(color), lineWidth: 1.1)
    }

    // MARK: Labels

    private static func nameText(_ pieces: [MapTreeLayout.Piece], alpha: Double) -> Text {
        pieces.reduce(Text(verbatim: "")) { text, piece in
            text + Text(piece.text).foregroundColor(ink(0.92 * piece.alpha * alpha))
        }
        .font(labelFont)
    }

    private static func metaText(_ meta: MapTreeLayout.Meta, style: MapTreeStyle, alpha: Double) -> Text {
        switch meta.tone {
        case .count:
            return Text(meta.text).font(Theme.Typeface.micro.monospacedDigit()).foregroundColor(ink(0.45 * alpha))
        case .tag:
            return Text(meta.text).font(Theme.Typeface.micro).foregroundColor(ink(0.5 * alpha))
        case .working:
            return Text(meta.text).font(Theme.Typeface.micro.weight(.semibold))
                .foregroundColor(style.workingText.opacity(max(alpha, 0.6)))
        case .waiting:
            return Text(meta.text).font(Theme.Typeface.micro.weight(.semibold))
                .foregroundColor(style.needsInputText.opacity(max(alpha, 0.6)))
        }
    }

    /// Draws `text` knocked out of the links beneath, at `point` with `anchor`. Returns its size.
    @discardableResult
    private static func drawKnocked(_ text: Text, at point: CGPoint, anchor: UnitPoint,
                                    in context: inout GraphicsContext) -> CGSize {
        let resolved = context.resolve(text)
        let size = measure(resolved)
        let origin = CGPoint(x: point.x - size.width * anchor.x, y: point.y - size.height * anchor.y)
        knockout(Path(roundedRect: CGRect(x: origin.x - 2, y: origin.y, width: size.width + 4, height: size.height),
                      cornerRadius: 3), in: &context)
        context.draw(resolved, at: point, anchor: anchor)
        return size
    }

    /// Every label, or in the overlay the kept items' labels and what no emphasis dims: opened
    /// families' captions and live status words. A live item left out draws its label at 0, so
    /// its status word lands where it did. `clearsDimmed` clears the other left-out labels' words.
    private static func drawLabels(_ layout: MapTreeLayout, style: MapTreeStyle, pass: MapTreePass,
                                   clearsDimmed: Bool, in context: inout GraphicsContext) {
        for index in layout.items.indices {
            let kept = pass.keeps(index)
            // Most items an overlay leaves out draw nothing, so it reads them field by field.
            guard kept || layout.items[index].live != nil || layout.items[index].caption != nil else {
                if clearsDimmed { clear(layout.items[index].knocks, in: &context) }
                continue
            }
            let item = layout.items[index]
            let fade: Double = item.status.isFaded ? 0.65 : 1
            let alpha: Double = kept ? pass.alphas[index] * fade : 0
            switch item.kind {
            case .root:
                drawRootLabels(item, layout, in: &context)
            case .quiet:
                if kept { drawQuietLabel(item, alpha: alpha, in: &context) }
            case .lane, .group:
                if let caption = item.caption { drawCaption(caption, item, in: &context) }
                if kept || item.live != nil {
                    if item.children.isEmpty {
                        drawLeafLabel(item, style: style, alpha: alpha, in: &context)
                    } else {
                        drawInternalLabel(item, style: style, alpha: alpha, in: &context)
                    }
                } else if clearsDimmed {
                    clear(item.knocks, in: &context)
                }
            }
        }
    }

    /// "main" over the root, the project's edits and the trunk's own share under it.
    /// `MapTreeLayout.rootKnockouts` repeats these words and places.
    private static func drawRootLabels(_ item: MapTreeLayout.Item, _ layout: MapTreeLayout,
                                       in context: inout GraphicsContext) {
        let left = item.x - item.r
        let title = MapTreeText.width(layout.trunkTitle, size: 13, weight: .semibold) > 150
            ? String(layout.trunkTitle.prefix(18)) + "…" : layout.trunkTitle
        drawKnocked(Text(title).font(Theme.Typeface.headline).foregroundColor(ink(0.95)),
                    at: CGPoint(x: left, y: item.y - item.r - 5), anchor: .bottomLeading, in: &context)
        var y = item.y + item.r + 5
        let edits = drawKnocked(Text(layout.totalEdits.formatted()).font(Theme.Typeface.caption.monospacedDigit())
            .foregroundColor(ink(0.6)), at: CGPoint(x: left, y: y), anchor: .topLeading, in: &context)
        y += edits.height
        let word = drawKnocked(Text(verbatim: layout.totalEdits == 1 ? "edit" : "edits").font(Theme.Typeface.micro)
            .foregroundColor(ink(0.4)), at: CGPoint(x: left, y: y), anchor: .topLeading, in: &context)
        y += word.height + 3
        guard layout.trunkEdits > 0, layout.trunkEdits != layout.totalEdits else { return }
        drawKnocked(Text("\(layout.trunkEdits.formatted()) on \(layout.trunkTitle)").font(Theme.Typeface.micro.monospacedDigit())
            .foregroundColor(ink(0.4)), at: CGPoint(x: left, y: y), anchor: .topLeading, in: &context)
    }

    /// "⌄ nv/* · 8" over the first member of an opened family; a click there closes it.
    private static func drawCaption(_ caption: String, _ item: MapTreeLayout.Item, in context: inout GraphicsContext) {
        let bottom = item.y - max(item.r, 5) - 3
        let left = item.x - item.r
        var chevron = Path()
        chevron.move(to: CGPoint(x: left, y: bottom - 7))
        chevron.addLine(to: CGPoint(x: left + 3, y: bottom - 4))
        chevron.addLine(to: CGPoint(x: left + 6, y: bottom - 7))
        context.stroke(chevron, with: .color(ink(0.45)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
        drawKnocked(Text(caption).font(Theme.Typeface.micro).foregroundColor(ink(0.45)),
                    at: CGPoint(x: left + 10, y: bottom), anchor: .bottomLeading, in: &context)
    }

    /// Beside a leaf: the name, a family's ×N pill and chevron, then counts and status.
    private static func drawLeafLabel(_ item: MapTreeLayout.Item, style: MapTreeStyle, alpha: Double,
                                      in context: inout GraphicsContext) {
        var x = item.labelX
        let size = drawKnocked(nameText(item.name, alpha: alpha), at: CGPoint(x: x, y: item.y), anchor: .leading,
                               in: &context)
        x += size.width + 5
        if let pill = item.pill {
            let text = context.resolve(Text(pill).font(Theme.Typeface.micro.weight(.semibold)).foregroundColor(ink(0.85 * alpha)))
            let width = measure(text).width + 8
            context.fill(Path(roundedRect: CGRect(x: x, y: item.y - 6.5, width: width, height: 13), cornerRadius: 6.5),
                         with: .color(ink(0.1 * alpha)))
            context.draw(text, at: CGPoint(x: x + width / 2, y: item.y), anchor: .center)
            x += width + 4
            var chevron = Path()
            chevron.move(to: CGPoint(x: x + 1, y: item.y - 3))
            chevron.addLine(to: CGPoint(x: x + 4, y: item.y))
            chevron.addLine(to: CGPoint(x: x + 1, y: item.y + 3))
            context.stroke(chevron, with: .color(ink(0.45 * alpha)),
                           style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
            x += 9
        }
        for meta in item.meta {
            let text = context.resolve(metaText(meta, style: style, alpha: alpha))
            context.draw(text, at: CGPoint(x: x, y: item.y), anchor: .leading)
            x += measure(text).width + 5
        }
    }

    /// Over an internal node's line: its name; under it, its own edits and status.
    private static func drawInternalLabel(_ item: MapTreeLayout.Item, style: MapTreeStyle, alpha: Double,
                                          in context: inout GraphicsContext) {
        // Clear of the river under the label, however wide it runs.
        let clearance = max(3, item.segmentWidth / 2 + 1.5)
        drawKnocked(nameText(item.name, alpha: alpha), at: CGPoint(x: item.labelX, y: item.y - clearance),
                    anchor: .bottomLeading, in: &context)
        guard !item.meta.isEmpty else { return }
        var line = Text(verbatim: "")
        for (position, meta) in item.meta.enumerated() {
            if position > 0 { line = line + Text(" · ").font(Theme.Typeface.micro).foregroundColor(ink(0.35 * alpha)) }
            line = line + metaText(meta, style: style, alpha: alpha)
        }
        drawKnocked(line, at: CGPoint(x: item.labelX, y: item.y + clearance), anchor: .topLeading, in: &context)
    }

    /// "7 merged, no edits", the pull requests as pills, then the branch names.
    private static func drawQuietLabel(_ item: MapTreeLayout.Item, alpha: Double, in context: inout GraphicsContext) {
        var x = item.labelX
        let size = drawKnocked(Text(item.quietText).font(Theme.Typeface.micro).foregroundColor(ink(0.5 * alpha)),
                               at: CGPoint(x: x, y: item.y), anchor: .leading, in: &context)
        x += size.width + 6
        for pill in item.quietPills {
            let text = context.resolve(Text(pill).font(Theme.Typeface.micro.monospacedDigit()).foregroundColor(ink(0.5 * alpha)))
            let width = measure(text).width + 8
            context.fill(Path(roundedRect: CGRect(x: x, y: item.y - 6, width: width, height: 12), cornerRadius: 6),
                         with: .color(ink(0.07 * alpha)))
            context.draw(text, at: CGPoint(x: x + width / 2, y: item.y), anchor: .center)
            x += width + 3
        }
        guard !item.quietNames.isEmpty else { return }
        let names = context.resolve(Text(item.quietNames).font(Theme.Typeface.micro).foregroundColor(ink(0.32 * alpha)))
        context.draw(names, at: CGPoint(x: x + 2, y: item.y), anchor: .leading)
    }

    // MARK: Strip

    /// Per row and day, a dot as large as that day's edits in the row's main profile; a ring
    /// on the day it merged and around today's dot while a session works there. Over a veil a
    /// row left out draws only that live ring, which no emphasis dims.
    private static func drawStripDots(_ layout: MapTreeLayout, style: MapTreeStyle, pass: MapTreePass,
                                      in context: inout GraphicsContext) {
        let last = MapTreeLayout.columnCount - 1
        for leaf in layout.leafIndices {
            let kept = pass.keeps(leaf)
            guard kept || layout.items[leaf].live != nil else { continue }
            let item = layout.items[leaf]
            let alpha = pass.alphas[leaf]
            let rowRoom: CGFloat = (item.rowBottom - item.rowTop) / 2 - 1.5
            let columnRoom: CGFloat = MapTreeLayout.columnWidth / 2 - 0.5
            let largest: CGFloat = min(6.25, rowRoom, columnRoom)
            var lastRadius: CGFloat = 0
            for position in (kept ? 0 : last)...last {
                let center = CGPoint(x: layout.columnX(position), y: item.y)
                let counts = item.columnSources[position]
                // A focused profile keeps only its own edits, so it is the main one wherever it has any.
                let edits: Int = pass.focusSourceID.map { counts[$0] ?? 0 } ?? counts.values.reduce(0, +)
                let merged = item.mergeColumns.contains(position)
                if edits > 0 {
                    let perDay: Double = Double(edits) / Double(layout.bucketDays)
                    let grown: CGFloat = 1.6 + 0.55 * CGFloat(perDay.squareRoot())
                    let radius: CGFloat = max(1.6, min(largest, grown))
                    if position == last { lastRadius = radius }
                    guard kept else { continue }
                    let main = pass.focusSourceID ?? layout.dominant(counts)
                    context.fill(circle(center, radius), with: .color(style.color(main).opacity(0.92 * alpha)))
                    if merged {
                        context.stroke(circle(center, radius + 1.5), with: .color(ink(0.7 * alpha)), lineWidth: 0.8)
                    }
                } else if !kept {
                    continue
                } else if merged {
                    context.stroke(circle(center, 2.1), with: .color(ink(0.55 * alpha)), lineWidth: 0.8)
                } else {
                    context.fill(circle(center, 0.8), with: .color(ink(0.13 * alpha)))
                }
            }
            if let live = item.live {
                context.stroke(circle(CGPoint(x: layout.columnX(last), y: item.y), max(5.5, lastRadius + 2)),
                               with: .color(style.live(live)), lineWidth: 1.1)
            }
        }
    }
}
