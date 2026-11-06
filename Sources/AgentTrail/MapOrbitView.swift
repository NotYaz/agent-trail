import AppKit
import SwiftUI
import AgentTrailCore

// MARK: - Orbit

/// The Map as a ring clock. The window runs clockwise around the main ring,
/// from just right of 12 o'clock to now in the notch at the top, with idle
/// hours folded into "//" seams. Branches bloom outward as petals that leave
/// the ring at their fork and come back at their merge; integration branches
/// are outer orbits with petals of their own, and parallel waves open as fans.
/// Inside the ring run the sessions as profile-colored tracks, an edit-rhythm
/// sunburst, and a dial with the totals or whatever is hovered.
struct MapOrbitView: View {
    let context: MapCanvasContext
    /// Written on hover and click, never observed here: only the overlay follows it.
    let hover: MapHoverModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast
    /// The layout lasts until the map, the size or an opened family changes, so hovering only redraws the overlay.
    @State private var cache = MapOrbitCache()
    /// The slice of time under the pointer over empty space or the edit rhythm. Held here, never
    /// observed here: only the overlay follows it.
    @State private var cursor = MapOrbitCursor()
    /// Families opened or closed by a click, by family key.
    @State private var expanded: Set<String> = []
    @State private var collapsed: Set<String> = []

    var body: some View {
        let map = context.map
        let layout = cache.layout(map: map, size: context.size, calendar: context.calendar,
                                  expanded: expanded, collapsed: collapsed)
        let sources: [AgentSource] = context.sources
        let sourceIDs: Set<String> = Set(map.spans.map(\.sourceID))
        let colors: [String: Color] = Dictionary(uniqueKeysWithValues: sourceIDs.map { ($0, context.color($0)) })
        let slots: [String: ProfileSlot] = Dictionary(uniqueKeysWithValues: sourceIDs.map {
            ($0, ProfileColor.slot(for: $0, sources: sources))
        })
        let names: [String: String] = Dictionary(uniqueKeysWithValues: sourceIDs.map {
            ($0, GrowthSeries.name(of: $0, sources: sources))
        })
        let base = MapStaticKey(layout: cache.generation, focusSourceID: context.focusSourceID, colorScheme: colorScheme)
        let key = MapOrbitKey(base: base, contrast: contrast, theme: ColorTheme.current, slots: slots, names: names)
        let rest = MapOrbitEmphasis(layout: layout, item: nil, cursorBin: nil, focusSourceID: context.focusSourceID)
        let words = MapOrbitDialText(map: map, sources: context.sources, calendar: context.calendar, layout: layout)
        let isDark = colorScheme == .dark
        let hover = self.hover
        let cursor = self.cursor
        ZStack(alignment: .topLeading) {
            MapStaticCanvas(key: key) { graphics, _ in
                let palette = MapOrbitPalette(colors: colors, in: graphics.environment)
                MapOrbitPainter.drawStatic(layout, palette: palette, emphasis: rest, isDark: isDark, in: &graphics)
            }
            .equatable()
            MapOrbitOverlay(layout: layout, key: key, colors: colors, words: words, focusSourceID: context.focusSourceID,
                            isDark: isDark, animatesLive: context.animatesLive, hover: hover, cursor: cursor)
        }
        .frame(width: max(1, context.size.width), height: max(1, context.size.height), alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                let hit = layout.hit(at: point)
                hover.hover(hit.id)
                cursor.move(hit.bin, in: layout)
            case .ended:
                hover.hover(nil)
                cursor.move(nil, in: layout)
            }
        }
        .gesture(SpatialTapGesture().onEnded { value in
            let hit = layout.hit(at: value.location)
            if let key = hit.familyKey {
                toggleFamily(key, in: layout)
            } else if let key = hit.memberOf, NSEvent.modifierFlags.contains(.option) {
                // Option-click on a branch of an open family folds it back, also where its title has no room.
                toggleFamily(key, in: layout)
            }
            hover.select(hit.id)
        })
        .onChange(of: context.map.projectPath) { _, _ in resetFamilies() }
        .onChange(of: context.map.range) { _, _ in resetFamilies() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Orbit map of \((map.projectPath as NSString).lastPathComponent), \(map.range.title.lowercased())")
        .accessibilityValue(words.summary)
    }

    /// A folded family opens in place; an open one folds back into a glyph.
    private func toggleFamily(_ key: String, in layout: MapOrbitLayout) {
        let folded = layout.families.first { $0.key == key }?.folded ?? false
        if folded {
            expanded.insert(key)
            collapsed.remove(key)
        } else {
            collapsed.insert(key)
            expanded.remove(key)
        }
    }

    /// Opened and folded families belong to one project and range.
    private func resetFamilies() {
        if !expanded.isEmpty { expanded = [] }
        if !collapsed.isEmpty { collapsed = [] }
    }
}

/// One layout per map, size and set of opened families. A reference, so a redraw reuses it;
/// `generation` changes with each new layout, an opened or folded family included, and keys the
/// static drawing.
private final class MapOrbitCache {
    private var key: (map: ProjectMap, size: CGSize, calendar: ActivityCalendar, expanded: Set<String>,
                      collapsed: Set<String>)?
    private var cached: MapOrbitLayout?
    private(set) var generation = 0

    func layout(map: ProjectMap, size: CGSize, calendar: ActivityCalendar, expanded: Set<String>,
                collapsed: Set<String>) -> MapOrbitLayout {
        if let key, let cached, key.size == size, key.expanded == expanded, key.collapsed == collapsed,
           key.calendar == calendar, key.map == map {
            return cached
        }
        let layout = MapOrbitLayout(map: map, size: size, calendar: calendar, expanded: expanded, collapsed: collapsed)
        key = (map, size, calendar, expanded, collapsed)
        cached = layout
        generation += 1
        return layout
    }
}

/// The slice of time under the pointer. Only the overlay observes it, so moving the cursor never
/// records the static picture again. A slice without edits lights nothing, so what the last lit
/// slice lit stays for `MapMotion.leaveDelay`: sliding across a quiet slice hands the veil over to
/// the next lit one instead of dropping it. Used on the main thread only; not main-actor
/// isolated, so the view's `@State` default value needs no isolated context.
private final class MapOrbitCursor: ObservableObject {
    /// The slice under the pointer, which the spoke and the dial follow.
    @Published private(set) var bin: Int?
    /// The slice whose activity is lit: `bin` while it has edits, else for a moment the last one that had.
    @Published private(set) var litBin: Int?
    /// Lets go of `litBin` once the pointer has been off lit slices for `MapMotion.leaveDelay`.
    private var release: Task<Void, Never>?

    /// Publishes only a real change: the pointer moving within one slice does nothing.
    func move(_ bin: Int?, in layout: MapOrbitLayout) {
        guard self.bin != bin else { return }
        self.bin = bin
        if let bin, layout.active(atBin: bin) != nil {
            release?.cancel()
            release = nil
            if litBin != bin { litBin = bin }
            return
        }
        guard litBin != nil, release == nil else { return }
        release = Task { @MainActor [weak self] in
            try? await Task.sleep(for: MapMotion.leaveDelay)
            guard !Task.isCancelled, let self else { return }
            self.release = nil
            if self.litBin != nil { self.litBin = nil }
        }
    }
}

/// What the orbit's fixed layers depend on: the layout, the focused profile and the appearance,
/// plus the theme, contrast and profile slots, which recolor the picture while the layout stays,
/// and the profile names a session's dial shows.
private struct MapOrbitKey: Equatable {
    let base: MapStaticKey
    let contrast: ColorSchemeContrast
    let theme: ColorTheme
    let slots: [String: ProfileSlot]
    let names: [String: String]
}

/// What one overlay layer depends on besides the fixed layers.
private struct MapOrbitOverlayKey: Equatable {
    let base: MapOrbitKey
    let item: MapHitID?
    var cursorBin: Int? = nil
    /// What the time cursor lights, which stays the same across many of its slices.
    var cursorLanes: Set<String>? = nil
    var cursorSessions: Set<String>? = nil

    /// Every run of a session lights the same things and shows the same card, so sliding along a
    /// session's runs records nothing again.
    static func identity(of item: MapHit?) -> MapHitID? {
        guard let item else { return nil }
        switch item {
        case .live(let span), .span(let span): return .run(span.sessionKey, 0)
        default: return item.id
        }
    }
}

/// What an overlay layer shows, by identity: the hovered or pinned item, what the time cursor
/// lights, and for the center whether the cursor's spoke and card show. A new identity is a new
/// layer that crossfades in over the last one; within one identity a layer updates in place.
private struct MapOrbitLayerID: Hashable {
    var item: MapHitID?
    var lanes: Set<String>? = nil
    var sessions: Set<String>? = nil
    var cursor = false
}

/// A layer of a crossfade that adds onto the other layers of its stack instead of covering them,
/// so two layers whose opacities sum to one show exactly a blend of their two pictures: what both
/// draw, the veil above all, holds steady instead of thinning halfway. Still renders and Reduce
/// Motion, which never crossfade, draw the layer as it is.
private struct MapOrbitDissolve: ViewModifier {
    let active: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if active { content.blendMode(.plusLighter) } else { content }
    }
}

/// The stack those layers add up in, flattened before it is drawn over the picture beneath.
private struct MapOrbitDissolveStack: ViewModifier {
    let active: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if active { content.compositingGroup() } else { content }
    }
}

/// Everything that follows the pointer, over the static picture: the lit subset under a veil,
/// the day labels, now and the key (which never dim), the center with its rhythm and dial, and
/// the live glyphs. Each layer records again only when what it shows changes, and no change lands
/// in one frame. An emphasis and its veil are one layer that fades in and out whole, so the lit
/// item never dips while the veil comes up; one emphasis hands over to the next by a crossfade
/// that adds the two up, so the veil holds. Only the opacity of layers already recorded moves.
private struct MapOrbitOverlay: View {
    let layout: MapOrbitLayout
    let key: MapOrbitKey
    let colors: [String: Color]
    let words: MapOrbitDialText
    let focusSourceID: String?
    let isDark: Bool
    let animatesLive: Bool
    @ObservedObject var hover: MapHoverModel
    @ObservedObject var cursor: MapOrbitCursor
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill

    var body: some View {
        let layout = self.layout
        let colors = self.colors
        let words = self.words
        let isDark = self.isDark
        let item: MapHit? = hover.emphasized.flatMap { MapHit.resolve($0, in: layout.map) }
        let bin: Int? = cursor.bin
        // What the cursor lights outlasts a quiet slice for a moment; its spoke and card follow the pointer.
        let emphasis = MapOrbitEmphasis(layout: layout, item: item, cursorBin: cursor.litBin,
                                        focusSourceID: focusSourceID)
        let pointer: MapOrbitEmphasis = emphasis.spoke(at: bin)
        let identity: MapHitID? = MapOrbitOverlayKey.identity(of: item)
        // The cursor lights things only while nothing is hovered or pinned.
        let cursorLanes: Set<String>? = item == nil ? emphasis.litLanes : nil
        let cursorSessions: Set<String>? = item == nil ? emphasis.litSessions : nil
        let emphasisKey = MapOrbitOverlayKey(base: key, item: identity, cursorLanes: cursorLanes,
                                             cursorSessions: cursorSessions)
        let centerKey = MapOrbitOverlayKey(base: key, item: identity, cursorBin: bin)
        // Nothing lit at rest: no emphasis layer at all.
        let lit: MapOrbitLayerID? = emphasis.isResting ? nil
            : MapOrbitLayerID(item: identity, lanes: cursorLanes, sessions: cursorSessions)
        let center = MapOrbitLayerID(item: identity, cursor: bin != nil)
        let veiled: Bool = emphasis.dims
        let veil: Animation? = MapMotion.animation(MapMotion.veil, reduceMotion: reduceMotion, still: rendersStill)
        let crossfade: Animation? = MapMotion.animation(MapMotion.crossfade, reduceMotion: reduceMotion,
                                                        still: rendersStill)
        let dissolves: Bool = crossfade != nil
        // A new layout lands at once: its items have moved, and a fade would show the old
        // emphasis where they were. The innermost animation wins, then the veil's, then the handover's.
        let generation: Int = key.base.layout
        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                if let lit {
                    MapStaticCanvas(key: emphasisKey) { graphics, size in
                        guard !emphasis.isResting else { return }
                        let palette = MapOrbitPalette(colors: colors, in: graphics.environment)
                        MapOrbitPainter.drawEmphasis(layout, size: size, palette: palette, emphasis: emphasis,
                                                     isDark: isDark, in: &graphics)
                    }
                    .equatable()
                    .modifier(MapOrbitDissolve(active: dissolves))
                    .id(lit)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(MapOrbitDissolveStack(active: dissolves))
            .animation(nil, value: generation)
            .animation(veil, value: veiled)
            .animation(crossfade, value: lit)
            MapStaticCanvas(key: key) { graphics, _ in
                let palette = MapOrbitPalette(colors: colors, in: graphics.environment)
                MapOrbitPainter.drawFixed(layout, palette: palette, in: &graphics)
            }
            .equatable()
            // A card hands over to the next; within one, the spoke and a slice's card follow the pointer.
            ZStack(alignment: .topLeading) {
                MapStaticCanvas(key: centerKey) { graphics, _ in
                    let palette = MapOrbitPalette(colors: colors, in: graphics.environment)
                    let dial = words.dial(item: item, cursorBin: bin, palette: palette)
                    MapOrbitPainter.drawCenter(layout, palette: palette, emphasis: pointer, dial: dial, in: &graphics)
                }
                .equatable()
                .modifier(MapOrbitDissolve(active: dissolves))
                .id(center)
                .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .modifier(MapOrbitDissolveStack(active: dissolves))
            .animation(nil, value: generation)
            .animation(crossfade, value: center)
            ForEach(layout.liveMarks) { mark in
                StatusGlyph(kind: mark.waiting ? .needsInput : .working, size: 10, animates: animatesLive)
                    .opacity(emphasis.sessionOpacity(mark.span.sessionKey, source: mark.span.sourceID))
                    .animation(nil, value: generation)
                    .animation(veil, value: veiled)
                    .animation(crossfade, value: lit)
                    .position(mark.point)
            }
        }
        .allowsHitTesting(false)
    }
}

/// The colors one draw pass uses, each resolved once: theme and profile colors are dynamic, and
/// resolving one for every stroke was a large share of the orbit's drawing time.
private struct MapOrbitPalette {
    let profiles: [String: Color]
    let gray: Color
    let working: Color
    let needsInput: Color
    let workingText: Color
    let needsInputText: Color
    /// The veil: the card's color over the panel canvas.
    let canvas: Color
    let surface: Color

    init(colors: [String: Color], in environment: EnvironmentValues) {
        profiles = colors.mapValues { $0.flattened(in: environment) }
        gray = Color.gray.flattened(in: environment)
        working = Theme.Palette.working.flattened(in: environment)
        needsInput = Theme.Palette.needsInput.flattened(in: environment)
        workingText = Theme.Palette.workingText.flattened(in: environment)
        needsInputText = Theme.Palette.needsInputText.flattened(in: environment)
        canvas = Theme.Palette.canvas.flattened(in: environment)
        surface = Theme.Palette.surface.flattened(in: environment)
    }

    func profile(_ id: String) -> Color { profiles[id] ?? gray }

    func status(_ live: String) -> Color { live == LiveStatus.waiting.rawValue ? needsInput : working }

    func statusText(_ live: String) -> Color { live == LiveStatus.waiting.rawValue ? needsInputText : workingText }
}

// MARK: - Geometry

/// Angles run clockwise from 12 o'clock in radians; the notch at the top holds now.
private struct MapOrbitGeometry {
    let center: CGPoint
    let notch: Double

    var sweep: Double { 2 * Double.pi - notch }

    /// The angle of an axis position 0…1.
    func angle(_ position: Double) -> Double { notch / 2 + min(1, max(0, position)) * sweep }

    /// The axis position of an angle; outside 0…1 inside the notch.
    func position(_ angle: Double) -> Double { (angle - notch / 2) / sweep }

    func point(_ radius: CGFloat, _ angle: Double) -> CGPoint {
        CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y - radius * CGFloat(cos(angle)))
    }

    func polar(_ point: CGPoint) -> (radius: CGFloat, angle: Double) {
        let dx = Double(point.x - center.x)
        let dy = Double(point.y - center.y)
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * Double.pi }
        let radius = CGFloat((dx * dx + dy * dy).squareRoot())
        return (radius: radius, angle: angle)
    }

    /// Points along a circle every 2.5pt or so, from `start` to `end`.
    func points(_ radius: CGFloat, from start: Double, to end: Double) -> [CGPoint] {
        let steps = max(2, Int(abs(end - start) * Double(radius) / 2.5))
        return (0...steps).map { point(radius, start + (end - start) * Double($0) / Double(steps)) }
    }

    func arc(_ radius: CGFloat, from start: Double, to end: Double) -> Path {
        var path = Path()
        path.addLines(points(radius, from: start, to: end))
        return path
    }

    /// The outward unit vector at `angle`.
    static func radial(_ angle: Double) -> CGPoint { CGPoint(x: sin(angle), y: -cos(angle)) }

    /// The clockwise unit tangent at `angle`.
    static func tangent(_ angle: Double) -> CGPoint { CGPoint(x: cos(angle), y: sin(angle)) }
}

private enum MapOrbitMath {
    static func radians(_ degrees: Double) -> Double { degrees * Double.pi / 180 }

    static func add(_ point: CGPoint, _ vector: CGPoint, _ scale: CGFloat = 1) -> CGPoint {
        CGPoint(x: point.x + vector.x * scale, y: point.y + vector.y * scale)
    }

    static func sub(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }

    static func unit(_ vector: CGPoint) -> CGPoint {
        let length = max(hypot(vector.x, vector.y), 0.0001)
        return CGPoint(x: vector.x / length, y: vector.y / length)
    }

    static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat { hypot(lhs.x - rhs.x, lhs.y - rhs.y) }

    static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
    }

    static func bezier(_ points: [CGPoint], _ t: CGFloat) -> CGPoint {
        guard points.count == 4 else { return points.first ?? .zero }
        let u = 1 - t
        let a = u * u * u
        let b = 3 * u * u * t
        let c = 3 * u * t * t
        let d = t * t * t
        return CGPoint(x: a * points[0].x + b * points[1].x + c * points[2].x + d * points[3].x,
                       y: a * points[0].y + b * points[1].y + c * points[2].y + d * points[3].y)
    }

    /// Distance from `origin` along `angle` to where the ray enters `box`, if it does.
    static func ray(from origin: CGPoint, angle: Double, box: CGRect) -> CGFloat? {
        let axes: [(origin: Double, direction: Double, low: Double, high: Double)] = [
            (Double(origin.x), sin(angle), Double(box.minX), Double(box.maxX)),
            (Double(origin.y), -cos(angle), Double(box.minY), Double(box.maxY))
        ]
        var near = 0.0
        var far = Double.infinity
        for axis in axes {
            if abs(axis.direction) < 1e-9 {
                if axis.origin < axis.low || axis.origin > axis.high { return nil }
                continue
            }
            var first = (axis.low - axis.origin) / axis.direction
            var second = (axis.high - axis.origin) / axis.direction
            if first > second { swap(&first, &second) }
            near = max(near, first)
            far = min(far, second)
            if near > far { return nil }
        }
        return CGFloat(near)
    }
}

/// Text widths for the layout, which is built outside a Canvas. The Canvas
/// draws with the same system font at 10pt, so the two agree.
private enum MapOrbitMeasure {
    /// One 10pt line's height, as the Canvas measures a petal label.
    static let lineHeight: CGFloat = {
        let font = NSFont.systemFont(ofSize: 10, weight: .medium)
        return ceil(font.ascender - font.descender + font.leading)
    }()

    static func width(_ text: String, weight: NSFont.Weight = .medium, digits: Bool = false) -> CGFloat {
        let font = digits ? NSFont.monospacedDigitSystemFont(ofSize: 10, weight: weight)
            : NSFont.systemFont(ofSize: 10, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Fits `text` into `width`: first without a short generic prefix such as
    /// "claude/", then middle-truncated with both ends readable.
    static func fitted(_ text: String, width: CGFloat, weight: NSFont.Weight = .medium) -> String {
        guard Self.width(text, weight: weight) > width else { return text }
        if let slash = text.firstIndex(of: "/"), text.distance(from: text.startIndex, to: slash) <= 8,
           text.index(after: slash) < text.endIndex {
            return fitted(String(text[text.index(after: slash)...]), width: width, weight: weight)
        }
        func candidate(_ keep: Int) -> String { "\(text.prefix((keep + 1) / 2))…\(text.suffix(keep / 2))" }
        var low = 2
        var high = text.count - 1
        var best = String(text.prefix(1)) + "…"
        while low <= high {
            let middle = (low + high) / 2
            if Self.width(candidate(middle), weight: weight) <= width {
                best = candidate(middle)
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return best
    }
}

private enum MapOrbitText {
    /// "wf_14f4…-1" for a workflow agent's branch "wf_14f483e0-224-1".
    static func compactWorkflow(_ name: String) -> String {
        guard name.hasPrefix("wf_"), let dash = name.lastIndex(of: "-") else { return name }
        let run = name.dropFirst(3)
        guard run.count > 8 else { return name }
        return "wf_" + String(run.prefix(4)) + "…" + String(name[dash...])
    }

    /// The prefix up to a "/" or "-" that every name shares and none is only.
    static func sharedPrefix(_ names: [String]) -> String {
        guard names.count >= 2, var prefix = names.first else { return "" }
        for name in names.dropFirst() {
            while !prefix.isEmpty && !name.hasPrefix(prefix) { prefix.removeLast() }
        }
        guard let cut = prefix.lastIndex(where: { $0 == "/" || $0 == "-" }) else { return "" }
        let result = String(prefix[...cut])
        guard result.count >= 2, names.allSatisfy({ $0.count > result.count }) else { return "" }
        return result
    }

    /// "wa-" for "wave-a/", "mob-" for "mob/": a worktree folder prefix and its branches' prefix.
    static func folderPrefix(_ folder: String, matches branch: String) -> Bool {
        let stem = String(folder.dropLast())
        let branchStem = String(branch.dropLast())
        let initials = branchStem.split(separator: "-").compactMap(\.first).map(String.init).joined()
        return stem == branchStem || (initials.count >= 2 && stem == initials)
    }

    static func ordinal(_ value: Int) -> String {
        let tens = value % 100
        let suffix = (11...13).contains(tens) ? "th" : ([1: "st", 2: "nd", 3: "rd"][value % 10] ?? "th")
        return "\(value)\(suffix)"
    }
}

// MARK: - Layout

/// Every position the orbit draws and hit-tests, computed once per map and size.
private struct MapOrbitLayout {
    /// An angular extent, for hit testing a run along a circle.
    struct ArcSpan {
        let start: Double
        let end: Double

        /// How far `direction` lies outside the extent; 0 inside it.
        func distance(_ direction: Double) -> Double {
            if direction < start { return start - direction }
            if direction > end { return direction - end }
            return 0
        }
    }

    /// One profile's bars of the edit rhythm, as one path.
    struct SourcePath {
        let source: String
        let path: Path
    }

    struct Track {
        let sessionKey: String
        let sourceID: String
        let runs: [ProjectMap.Span]
        let start: Double
        let end: Double
        let slot: Int
        let radius: CGFloat
        let live: String?
        /// The faint thread over the session's life.
        let thread: Path
        /// The runs as arcs: solid ones, and combed ones where subagents made most edits.
        let solid: Path
        let comb: Path
        /// Where the live dot sits.
        let endPoint: CGPoint
        /// Each run's extent, in `runs` order.
        let runReach: [ArcSpan]
    }

    struct Orbit {
        let lane: ProjectMap.Lane
        let radius: CGFloat
        let parentRadius: CGFloat
        let start: Double
        let end: Double
        let runs: [ProjectMap.Span]
        let label: String?
        /// The orbit and the spurs that join it to its parent.
        let path: Path
        /// Each run's arc and extent, in `runs` order.
        let runPaths: [Path]
        let runReach: [ArcSpan]
        /// The orbit's lane and the branches that hang from it, which light it.
        let laneIDs: [String]
        let sources: Set<String>
    }

    struct PetalRun {
        let span: ProjectMap.Span
        let from: CGFloat
        let to: CGFloat
    }

    struct Ray {
        let base: CGPoint
        let control: CGPoint
        let tip: CGPoint
    }

    /// A branch, or a folded family drawn as one glyph petal with a ray per member.
    struct Petal {
        let id: String
        let laneIDs: [String]
        let familyKey: String?
        let isGlyph: Bool
        let fork: CGPoint
        let tip: CGPoint
        let tipAngle: Double
        let tipRadius: CGFloat
        /// Merged: it returns to its parent and can be filled.
        let closed: Bool
        let cubics: [[CGPoint]]
        let samples: [CGPoint]
        /// Each sample's share of the outline's length, for runs placed by lifetime.
        let fractions: [CGFloat]
        let area: CGFloat
        let sourceID: String?
        let sources: Set<String>
        let label: String
        let count: Int
        let labelRadius: CGFloat
        let labelWidth: CGFloat
        /// False where a crowded ring dropped this petal's label; the dial still names it on hover.
        let showsLabel: Bool
        let live: String?
        let noCommits: Bool
        let deleted: Bool
        let runs: [PetalRun]
        let rays: [Ray]
        let outline: Path
        let fillPath: Path
        /// The fill as a CGPath, which hit testing asks without building a path on every move.
        let fillShape: CGPath
        /// Each run's stretch of the outline, in `runs` order.
        let runPaths: [Path]
        let rayPath: Path
        let rayDots: Path
        /// The samples' bounding box, so hit testing skips far petals.
        let bounds: CGRect
        /// The label's frame: its anchor, its turn and the turn's inverse for hit testing.
        let labelAnchor: CGPoint
        let labelAngle: Double
        let labelFlipped: Bool
        let labelCos: CGFloat
        let labelSin: CGFloat
        /// The box knocked out under the label, where the label alone shows.
        let labelFootprint: Path
    }

    struct Family {
        let key: String
        let title: String
        let laneIDs: [String]
        let folded: Bool
        /// Where the curved title sits; nil when it is not drawn.
        let titleRadius: CGFloat?
        let titleStart: Double
        let titleEnd: Double
        let bracketStart: Double
        let bracketEnd: Double
        /// The band holding the title and its bracket, when they are drawn.
        var reveal: Path? = nil
    }

    struct Mark {
        enum Style {
            /// Pull request numbers: "#5", "#7–11".
            case pill
            /// Several local merges: a ring with their count.
            case count
            /// One local merge: a ring with a dot.
            case ring
            /// A merged branch no session edited.
            case quiet
        }

        let shas: [String]
        let laneIDs: [String]
        let point: CGPoint
        let style: Style
        let text: String
        let quiet: Bool
        let size: CGSize
        /// What the mark knocks out of the lines beneath, and the shape it strokes.
        let footprint: Path
        let shape: Path
    }

    struct Day {
        let text: String
        let mid: Double
        let isToday: Bool
    }

    struct Wedge {
        let start: Double
        let end: Double
    }

    struct Live: Identifiable {
        let id: String
        let span: ProjectMap.Span
        let point: CGPoint
        let waiting: Bool
    }

    struct KeyRow {
        enum Kind {
            case comb
            case noCommits
            case fold
        }

        let kind: Kind
        let text: String
    }

    struct Hit {
        var id: MapHitID? = nil
        var bin: Int? = nil
        /// A family to open or fold when clicked.
        var familyKey: String? = nil
        /// The open family a hit branch belongs to, which an Option-click folds.
        var memberOf: String? = nil
    }

    /// A leaf or folded family before its tip is placed.
    struct Candidate {
        let id: String
        let laneIDs: [String]
        let familyKey: String?
        let isGlyph: Bool
        let desired: Double
        let group: Double
        let fork: Double
        let merge: Double?
        /// What the tip's length is measured from: the orbit it hangs from, or the ring.
        let parentRadius: CGFloat
        /// Where it leaves at `fork` and comes home at `merge`; a branch merged into an
        /// integration branch may have started from main before that branch's orbit begins.
        let forkRadius: CGFloat
        let mergeRadius: CGFloat
        let edits: Int
        let name: String
        let nameWidth: CGFloat
        let countWidth: CGFloat
        let titled: Bool
        /// False once a crowded ring drops this petal's label, so it needs only room for its tip dot.
        var labeled: Bool = true

        var labelWidth: CGFloat { nameWidth + countWidth }
    }

    struct MergeEvent {
        let angle: Double
        let sha: String
        let pullRequest: Int?
        let quiet: Bool
        let laneID: String?
    }

    let map: ProjectMap
    let geometry: MapOrbitGeometry
    let ring: CGFloat
    let trackOuter: CGFloat
    let trackStep: CGFloat
    let slotCount: Int
    let dayRadius: CGFloat
    let sunOuter: CGFloat
    let sunLength: CGFloat
    let dialRadius: CGFloat
    /// False when nearly every edit is a subagent's; the comb then carries no information.
    let hatches: Bool
    let delegatedShare: Double
    let tracks: [Track]
    let binCount: Int
    let bins: [[String: Int]]
    let binTotals: [Int]
    let binMax: Int
    let sessionBins: [String: [Int: Int]]
    let laneBins: [String: [Int: Int]]
    let sourceOrder: [String]
    let orbits: [Orbit]
    let petals: [Petal]
    /// Petals from the most edited to the least, so small ones stay on top.
    let drawOrder: [Int]
    let families: [Family]
    let marks: [Mark]
    let days: [Day]
    let todayWedge: Wedge?
    let liveMarks: [Live]
    let liveStatus: String?
    let nowRun: ProjectMap.Span?
    let nowClock: String
    let trunkRuns: [ProjectMap.Span]
    /// Main's runs as arcs on the ring, and their extents, in `trunkRuns` order.
    let trunkPaths: [Path]
    let trunkReach: [ArcSpan]
    let sessionLanes: [String: Set<String>]
    let laneSessions: [String: Set<String>]
    let laneSources: [String: Set<String>]
    let children: [String: [String]]
    let keyRows: [KeyRow]
    let keyRect: CGRect?
    /// The axis's folds, kept so hit testing does not filter the segments on every move.
    let gaps: [TimeAxis.Segment]
    /// The ring broken at each fold, the folds' "//" ticks and the day ticks across it.
    let ringPath: Path
    let ringTicks: Path
    let dayTicks: Path
    /// Day spokes inside the rhythm's outer edge, which the center draws under its dial, and out
    /// from there, which continue the dash pattern from `spokePhase`.
    let innerSpokes: Path
    let outerSpokes: Path
    let spokePhase: CGFloat
    /// The edit rhythm's bars, one path per profile in `sourceOrder`.
    let sunburst: [SourcePath]
    /// Every mark's and every shown label's footprint, as one path each.
    let markFootprints: Path
    let labelFootprints: Path

    var trackInner: CGFloat { trackOuter - trackStep * CGFloat(slotCount - 1) }

    init(map: ProjectMap, size: CGSize, calendar: ActivityCalendar, expanded: Set<String>, collapsed: Set<String>) {
        let width = max(size.width, 160)
        let height = max(size.height, 160)
        let geo = MapOrbitGeometry(center: CGPoint(x: width / 2, y: height / 2 + 2), notch: MapOrbitMath.radians(20))
        // Up to 220 in a window; the popover's ring stays near 100, below the old 150 cap.
        let ringRadius: CGFloat = max(60, min(220, min(height, width / 1.18) * 0.24))
        let scale = ringRadius / 108
        // Past a ring of 150, which the popover never reaches, the caps on label room and on the
        // rhythm's slices grow with the ring; exactly 1 below that, so the popover is unchanged.
        let grow: CGFloat = max(1, ringRadius / 150)
        let trunkID = map.trunkID
        let laneByID = Dictionary(map.lanes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let waiting = LiveStatus.waiting.rawValue

        func angle(_ date: Date) -> Double { geo.angle(map.axis.position(of: date)) }
        func laneEnd(_ lane: ProjectMap.Lane) -> Date {
            lane.merge?.date ?? (lane.isLive || lane.isHead ? map.now : lane.end)
        }
        /// The lane a branch hangs from, when that is not the trunk.
        func parentOf(_ lane: ProjectMap.Lane) -> String? {
            guard let parent = lane.parentID, parent != trunkID, parent != lane.id, laneByID[parent] != nil else {
                return nil
            }
            return parent
        }

        // Structure: integration branches are lanes other branches hang from.
        let branches = map.lanes.filter { $0.kind != .trunk }
        var children: [String: [String]] = [:]
        for lane in branches {
            if let parent = parentOf(lane) { children[parent, default: []].append(lane.id) }
        }
        let integration = Set(children.keys)
        func depth(_ lane: ProjectMap.Lane) -> Int {
            var count = 0
            var seen: Set<String> = [lane.id]
            var current = parentOf(lane)
            while let parent = current, count < 6, seen.insert(parent).inserted {
                count += 1
                current = laneByID[parent].flatMap(parentOf)
            }
            return count
        }

        // Sessions and edits.
        let spans = map.spans
        let spansByLane = Dictionary(grouping: spans, by: \.laneID)
        let totalEdits = spans.reduce(0) { $0 + $1.editCount }
        let delegatedEdits = spans.reduce(0) { $0 + $1.delegated.count }
        let share = totalEdits > 0 ? Double(delegatedEdits) / Double(totalEdits) : 0
        let hatches = share <= 0.8
        var sessionLanes: [String: Set<String>] = [:]
        var laneSessions: [String: Set<String>] = [:]
        var laneSources: [String: Set<String>] = [:]
        var sourceTotals: [String: Int] = [:]
        var laneSourceEdits: [String: [String: Int]] = [:]
        for span in spans {
            sessionLanes[span.sessionKey, default: []].insert(span.laneID)
            laneSessions[span.laneID, default: []].insert(span.sessionKey)
            laneSources[span.laneID, default: []].insert(span.sourceID)
            sourceTotals[span.sourceID, default: 0] += span.editCount
            laneSourceEdits[span.laneID, default: [:]][span.sourceID, default: 0] += span.editCount
        }
        let sourceOrder = sourceTotals.keys.sorted { lhs, rhs in
            let left = sourceTotals[lhs] ?? 0
            let right = sourceTotals[rhs] ?? 0
            return left != right ? left > right : lhs < rhs
        }

        // Radii, from the ring inward: tracks, day labels, the sunburst, the dial. A small ring
        // keeps fewer track slots, so the dial shrinks with the sunburst instead of covering it.
        let trackStep: CGFloat = max(3.8, 4.6 * scale)
        let trackOuter: CGFloat = ringRadius - 8 * scale
        let sunLength: CGFloat = max(7, 10 * scale)
        let innerBands: CGFloat = 9 + 7.5 + sunLength + 1
        let slotRoom: CGFloat = trackOuter - innerBands - 34 + 0.5
        let slotLimit: Int = max(1, min(5, Int((slotRoom / trackStep).rounded(.down)) + 1))

        // Session tracks: greedy packing on angle, five slots at most, fewer on a small ring.
        let bySession = Dictionary(grouping: spans, by: \.sessionKey)
        let sessions = bySession.keys.sorted().compactMap { key -> (key: String, start: Date, runs: [ProjectMap.Span])? in
            guard let runs = bySession[key]?.sorted(by: { ($0.start, $0.index) < ($1.start, $1.index) }),
                  let first = runs.first else { return nil }
            return (key, first.start, runs)
        }.sorted { ($0.start, $0.key) < ($1.start, $1.key) }
        let trackGap = MapOrbitMath.radians(1.2)
        var slotEnds: [Double] = []
        var packed: [(key: String, runs: [ProjectMap.Span], start: Double, end: Double, slot: Int, live: String?)] = []
        for session in sessions {
            let live = session.runs.last(where: { $0.live != nil })?.live
            let start = angle(session.start)
            let last = session.runs.map(\.end).max() ?? session.start
            let finish = max(angle(live != nil ? map.now : last), start + MapOrbitMath.radians(0.6))
            let slot: Int
            if let free = slotEnds.firstIndex(where: { $0 + trackGap < start }) {
                slotEnds[free] = finish
                slot = free
            } else if slotEnds.count < slotLimit {
                slotEnds.append(finish)
                slot = slotEnds.count - 1
            } else {
                let earliest = slotEnds.indices.min { slotEnds[$0] < slotEnds[$1] } ?? 0
                slotEnds[earliest] = max(slotEnds[earliest], finish)
                slot = earliest
            }
            packed.append((session.key, session.runs, start, finish, slot, live))
        }
        let slotCount = max(1, slotEnds.count)
        let trackInner: CGFloat = trackOuter - trackStep * CGFloat(slotCount - 1)
        let dayRadius: CGFloat = trackInner - 9
        let sunOuter: CGFloat = dayRadius - 7.5
        // 34 or more wherever the ring has room; below that the dial gives way to the sunburst.
        let dialRadius: CGFloat = max(24, sunOuter - sunLength - 1)
        /// A run's extent on a circle: padded either side, and never shorter than `minimum`.
        func extent(_ run: ProjectMap.Span, pad: Double, minimum: Double) -> ArcSpan {
            let start = angle(run.start) - MapOrbitMath.radians(pad)
            return ArcSpan(start: start, end: max(angle(run.end) + MapOrbitMath.radians(pad), start + MapOrbitMath.radians(minimum)))
        }
        func combs(_ run: ProjectMap.Span) -> Bool { hatches && run.delegated.count > run.direct.count }
        let tracks = packed.map { entry -> Track in
            let radius = trackOuter - trackStep * CGFloat(entry.slot)
            var solid = Path()
            var comb = Path()
            let reach = entry.runs.map { extent($0, pad: 0.25, minimum: 0.8) }
            for (run, span) in zip(entry.runs, reach) {
                let arc = geo.arc(radius, from: span.start, to: span.end)
                if combs(run) { comb.addPath(arc) } else { solid.addPath(arc) }
            }
            let sourceID: String = entry.runs.first?.sourceID ?? ""
            let thread: Path = geo.arc(radius, from: entry.start, to: entry.end)
            let endPoint: CGPoint = geo.point(radius, entry.end)
            return Track(sessionKey: entry.key, sourceID: sourceID, runs: entry.runs,
                         start: entry.start, end: entry.end, slot: entry.slot, radius: radius, live: entry.live,
                         thread: thread, solid: solid, comb: comb, endPoint: endPoint, runReach: reach)
        }

        // The edit rhythm: one bar per slice of the axis, stacked by profile.
        let binCount = max(96, min(Int(240 * grow), Int(2 * Double.pi * Double(sunOuter) / 2.3)))
        var bins = Array(repeating: [String: Int](), count: binCount)
        var sessionBins: [String: [Int: Int]] = [:]
        var laneBins: [String: [Int: Int]] = [:]
        for span in spans {
            for edit in span.direct + span.delegated {
                let bin = min(binCount - 1, max(0, Int(map.axis.position(of: edit) * Double(binCount))))
                bins[bin][span.sourceID, default: 0] += 1
                sessionBins[span.sessionKey, default: [:]][bin, default: 0] += 1
                laneBins[span.laneID, default: [:]][bin, default: 0] += 1
            }
        }
        let binTotals = bins.map { $0.values.reduce(0, +) }

        // Integration orbits, nested by depth and bumped apart where they overlap.
        let integrationLanes = integration.compactMap { laneByID[$0] }
            .sorted { (depth($0), $0.start, $0.id) < (depth($1), $1.start, $1.id) }
        var orbitRadius: [String: CGFloat] = [:]
        var occupied: [(radius: CGFloat, start: Double, end: Double)] = []
        var orbitBases: [(lane: ProjectMap.Lane, radius: CGFloat, parent: CGFloat, start: Double, end: Double)] = []
        for lane in integrationLanes {
            let start = angle(lane.start)
            let finish = max(angle(laneEnd(lane)), start + MapOrbitMath.radians(2))
            let hangsFrom = parentOf(lane)
            let baseRadius = hangsFrom.flatMap { orbitRadius[$0] } ?? ringRadius
            var radius = baseRadius + (hangsFrom == nil ? 21 * scale : 14 * scale)
            while occupied.contains(where: { other in
                let near = abs(other.radius - radius) < 4 * scale
                return near && start < other.end + 0.03 && finish > other.start - 0.03
            }) {
                radius += 8 * scale
            }
            occupied.append((radius, start, finish))
            orbitRadius[lane.id] = radius
            orbitBases.append((lane, radius, baseRadius, start, finish))
        }
        func parentRadius(_ lane: ProjectMap.Lane) -> CGFloat {
            parentOf(lane).flatMap { orbitRadius[$0] } ?? ringRadius
        }
        var orbitSpans: [String: (start: Double, end: Double)] = [:]
        for base in orbitBases { orbitSpans[base.lane.id] = (start: base.start, end: base.end) }
        /// Where a branch leaves at `fork`: the orbit it hangs from once that orbit is drawn, else
        /// the nearest orbit out from it that is, else the ring. A branch merged into an integration
        /// branch may have been started from main before that branch existed.
        func forkRadius(_ lane: ProjectMap.Lane, at fork: Double) -> CGFloat {
            var seen: Set<String> = [lane.id]
            var current = parentOf(lane)
            while let id = current, seen.insert(id).inserted {
                if let radius = orbitRadius[id], let span = orbitSpans[id],
                   fork >= span.start - 0.002, fork <= span.end + 0.002 {
                    return radius
                }
                current = laneByID[id].flatMap(parentOf)
            }
            return ringRadius
        }

        // Families: an integration branch's branches, or three or more at the
        // trunk sharing a prefix or a workflow run.
        let leaves = branches.filter { !integration.contains($0.id) }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        // A workflow agent keeps its raw "wf_…-3" here, rebuilt from the branch, for compactWorkflow
        // and the family labels below to shorten; MapText.title spells it out in full.
        func shortName(_ lane: ProjectMap.Lane) -> String {
            if let agent = ProjectMap.workflowAgent(lane.title) { return "wf_\(agent.run)-\(agent.agent)" }
            return MapText.title(lane)
        }
        let genericPrefixes: Set<String> = ["claude/", "codex/"]
        func prefixKey(_ lane: ProjectMap.Lane) -> String? {
            guard let prefix = ProjectMap.streamPrefix(lane.title), !genericPrefixes.contains(prefix) else { return nil }
            return prefix
        }
        let branchPrefixes = Set((leaves + integrationLanes).compactMap(prefixKey).filter { $0.hasSuffix("/") }).sorted()
        var integrationByPrefix: [String: String] = [:]
        for lane in integrationLanes {
            if let prefix = prefixKey(lane), integrationByPrefix[prefix] == nil { integrationByPrefix[prefix] = lane.id }
        }
        var familyMembers: [String: [String]] = [:]
        var familyOrder: [String] = []
        for leaf in leaves {
            var key: String?
            if let parent = parentOf(leaf) {
                key = "lane:" + parent
            } else if var prefix = prefixKey(leaf) {
                if prefix.hasSuffix("-"),
                   let branch = branchPrefixes.first(where: { MapOrbitText.folderPrefix(prefix, matches: $0) }) {
                    prefix = branch
                }
                key = integrationByPrefix[prefix].map { "lane:" + $0 } ?? ("prefix:" + prefix)
            }
            guard let key else { continue }
            if familyMembers[key] == nil { familyOrder.append(key) }
            familyMembers[key, default: []].append(leaf.id)
        }
        let familyKeys = familyOrder.filter { key in
            let count = familyMembers[key]?.count ?? 0
            if key.hasPrefix("lane:") { return count >= 2 }
            return count >= (key.hasPrefix("prefix:wf_") ? 2 : 3)
        }
        var familyOf: [String: String] = [:]
        for key in familyKeys {
            for id in familyMembers[key] ?? [] where familyOf[id] == nil { familyOf[id] = key }
        }
        func familyTitle(_ key: String, count: Int) -> String {
            if key.hasPrefix("lane:"), let lane = laneByID[String(key.dropFirst("lane:".count))] {
                return "\(shortName(lane)) · \(count) branches"
            }
            let prefix = String(key.dropFirst("prefix:".count))
            if prefix.hasPrefix("wf_") { return ProjectMap.streamTitle(prefix, count: count) }
            return "\(prefix)* · \(count) branches"
        }

        // Labels: inside a family, without the family's shared prefix.
        var labelOf: [String: String] = [:]
        var familyShared: [String: String] = [:]
        for lane in leaves { labelOf[lane.id] = MapOrbitText.compactWorkflow(shortName(lane)) }
        for key in familyKeys {
            let lanes = (familyMembers[key] ?? []).compactMap { laneByID[$0] }
            var names = lanes.map(shortName)
            if key.hasPrefix("lane:"), let parent = laneByID[String(key.dropFirst("lane:".count))] {
                let parentName = shortName(parent)
                names = names.map { (name: String) -> String in
                    for separator in ["/", "-"] where name.hasPrefix(parentName + separator) && name.count > parentName.count + 1 {
                        return String(name.dropFirst(parentName.count + 1))
                    }
                    return name
                }
            }
            if key.hasPrefix("prefix:wf_") {
                names = lanes.map { (lane: ProjectMap.Lane) -> String in
                    ProjectMap.workflowAgent(lane.title).map { "agent " + $0.agent } ?? shortName(lane)
                }
            } else {
                let shared = MapOrbitText.sharedPrefix(names.filter { !$0.hasPrefix("wf_") })
                familyShared[key] = shared
                if !shared.isEmpty {
                    names = names.map { $0.hasPrefix(shared) ? String($0.dropFirst(shared.count)) : $0 }
                }
            }
            for (lane, name) in zip(lanes, names) { labelOf[lane.id] = MapOrbitText.compactWorkflow(name) }
        }
        func glyphName(_ key: String, count: Int) -> String {
            if key.hasPrefix("prefix:") {
                let prefix = String(key.dropFirst("prefix:".count))
                if prefix.hasPrefix("wf_") { return "wf_" + String(prefix.dropFirst(3).prefix(4)) + "… ×\(count)" }
                return "\(prefix)* ×\(count)"
            }
            let shared = familyShared[key] ?? ""
            return shared.isEmpty ? "\(count) branches" : "\(shared)* ×\(count)"
        }

        // The corner key, and the room each ray has before the card edge or the key. In a wide or tall
        // window the key sits by the drawing, three rings out from the center, not in a far corner;
        // never inside 600x680, the popover's own size, so there it keeps the card's corner.
        var keyRows: [KeyRow] = []
        if hatches && spans.contains(where: { $0.delegated.count > $0.direct.count }) {
            keyRows.append(KeyRow(kind: .comb, text: "subagent edits"))
        }
        if leaves.contains(where: { $0.commitCount == 0 && $0.merge == nil && !$0.isLive }) {
            keyRows.append(KeyRow(kind: .noCommits, text: "no commits"))
        }
        if !map.axis.gaps.isEmpty { keyRows.append(KeyRow(kind: .fold, text: "idle folded")) }
        let keyWidth = 22 + (keyRows.map { MapOrbitMeasure.width($0.text, weight: .regular) }.max() ?? 0)
        let keyHeight = CGFloat(keyRows.count) * 13
        let keyRight: CGFloat = min(width, max(600, geo.center.x + 3 * ringRadius))
        let keyBottom: CGFloat = min(height, max(680, geo.center.y + 3 * ringRadius))
        let keyRect: CGRect? = keyRows.isEmpty ? nil
            : CGRect(x: keyRight - 2 - keyWidth, y: keyBottom - 2 - keyHeight, width: keyWidth, height: keyHeight)
        let margin: CGFloat = 4
        func room(_ direction: Double) -> CGFloat {
            let dx = sin(direction)
            let dy = -cos(direction)
            let cx = Double(geo.center.x)
            let cy = Double(geo.center.y)
            var reach = Double.infinity
            if dx > 1e-6 { reach = min(reach, (Double(width - margin) - cx) / dx) }
            if dx < -1e-6 { reach = min(reach, (Double(margin) - cx) / dx) }
            if dy > 1e-6 { reach = min(reach, (Double(height - margin) - cy) / dy) }
            if dy < -1e-6 { reach = min(reach, (Double(margin) - cy) / dy) }
            var result = CGFloat(reach.isFinite ? reach : 400)
            if let box = keyRect, let hit = MapOrbitMath.ray(from: geo.center, angle: direction, box: box.insetBy(dx: -4, dy: -4)) {
                result = min(result, hit)
            }
            return result
        }

        // Candidates: every leaf, or one glyph per folded family.
        var widthMemo: [String: CGFloat] = [:]
        func measured(_ text: String, _ weight: NSFont.Weight) -> CGFloat {
            let key = (weight == .semibold ? "s\u{0}" : weight == .regular ? "r\u{0}" : "m\u{0}") + text
            if let known = widthMemo[key] { return known }
            let value = MapOrbitMeasure.width(text, weight: weight)
            widthMemo[key] = value
            return value
        }
        func desired(_ lane: ProjectMap.Lane) -> Double { 0.7 * angle(lane.start) + 0.3 * angle(laneEnd(lane)) }
        var familyMean: [String: Double] = [:]
        for key in familyKeys {
            let values = (familyMembers[key] ?? []).compactMap { laneByID[$0] }.map(desired)
            familyMean[key] = values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
        }
        func candidates(folded: Set<String>) -> [Candidate] {
            var result: [Candidate] = []
            for key in familyKeys where folded.contains(key) {
                let lanes = (familyMembers[key] ?? []).compactMap { laneByID[$0] }
                guard !lanes.isEmpty else { continue }
                let merges = lanes.compactMap(\.merge)
                // The earliest member sets where the glyph leaves, the last to merge where it comes home.
                let earliest = lanes.min { ($0.start, $0.id) < ($1.start, $1.id) }
                var lastMerged: ProjectMap.Lane?
                for lane in lanes {
                    guard let date = lane.merge?.date else { continue }
                    if let latest = lastMerged?.merge?.date, latest >= date { continue }
                    lastMerged = lane
                }
                let fork = earliest.map { angle($0.start) } ?? geo.angle(0)
                let forkFrom: CGFloat = earliest.map { forkRadius($0, at: fork) } ?? ringRadius
                let merge: Double? = merges.count == lanes.count ? merges.map { angle($0.date) }.max() : nil
                // The integration orbit only for a family with branches that hang from it.
                let laneKey: String? = key.hasPrefix("lane:") ? String(key.dropFirst("lane:".count)) : nil
                let hangs: Bool = laneKey.map { id in lanes.contains { parentOf($0) == id } } ?? false
                let parent: CGFloat = hangs ? (laneKey.flatMap { orbitRadius[$0] } ?? ringRadius) : ringRadius
                let home: CGFloat = lastMerged.map(parentRadius) ?? parent
                let edits = lanes.reduce(0) { $0 + $1.editCount }
                let name = glyphName(key, count: lanes.count)
                let mean = familyMean[key] ?? fork
                result.append(Candidate(id: "family:" + key, laneIDs: lanes.map(\.id), familyKey: key, isGlyph: true,
                                        desired: mean, group: mean, fork: fork, merge: merge, parentRadius: parent,
                                        forkRadius: min(forkFrom, parent), mergeRadius: min(home, parent),
                                        edits: edits, name: name, nameWidth: measured(name, .semibold),
                                        countWidth: edits > 0 ? measured(" \(edits.formatted())", .regular) : 0,
                                        titled: false))
            }
            for lane in leaves {
                let key = familyOf[lane.id]
                if let key, folded.contains(key) { continue }
                let want = desired(lane)
                let name = labelOf[lane.id] ?? MapText.title(lane)
                let weight: NSFont.Weight = lane.isLive ? .semibold : .medium
                let forkAngle = angle(lane.start)
                let parent = parentRadius(lane)
                result.append(Candidate(id: lane.id, laneIDs: [lane.id], familyKey: key, isGlyph: false, desired: want,
                                        group: key.flatMap { familyMean[$0] } ?? want, fork: forkAngle,
                                        merge: lane.merge.map { angle($0.date) }, parentRadius: parent,
                                        forkRadius: min(forkRadius(lane, at: forkAngle), parent), mergeRadius: parent,
                                        edits: lane.editCount, name: name, nameWidth: measured(name, weight),
                                        countWidth: lane.editCount > 0 ? measured(" \(lane.editCount.formatted())", .regular) : 0,
                                        titled: key != nil))
            }
            return result.sorted { ($0.group, $0.desired, $0.id) < ($1.group, $1.desired, $1.id) }
        }

        // Tips: length by the square root of edits, capped by the room left for the label.
        let tipMax = ringRadius * 1.85
        let minLength = 14 * scale
        func tipRadius(_ item: Candidate, at direction: Double, emax: Int) -> CGFloat {
            let reach = room(direction)
            // A full name beats a long petal: the label may take all but the shortest petal.
            let spare: CGFloat = reach - item.parentRadius - minLength - 12
            let labelCap: CGFloat = max(64, min(150 * grow, spare))
            let label = min(item.labelWidth, labelCap)
            let titleRoom: CGFloat = item.titled ? 16 : 0
            let cap: CGFloat = min(tipMax, reach - label - 12 - titleRoom)
            let fraction = 0.16 + 0.84 * (Double(item.edits) / Double(max(1, emax))).squareRoot()
            return item.parentRadius + max(minLength, (cap - item.parentRadius) * CGFloat(fraction))
        }

        // Relaxation: neighbours push apart until their labels clear, each pulled
        // back toward its own time. The spreading is what opens a wave into a fan.
        let lowest = geo.angle(0) + MapOrbitMath.radians(4)
        let highest = geo.angle(1) - MapOrbitMath.radians(4)
        /// The angle two neighbouring tips need: half a label's height for each, or a tip dot's
        /// radius for a petal whose label was dropped.
        func spacing(_ lhs: Candidate, _ rhs: Candidate, _ left: CGFloat, _ right: CGFloat) -> Double {
            let extent: Double = (lhs.labeled ? 7.25 : 2.5) + (rhs.labeled ? 7.25 : 2.5)
            return extent / Double(min(left, right) + 8)
        }
        func relax(_ items: [Candidate], from start: [Double], tips: [CGFloat], passes: Int) -> [Double] {
            var angles = start
            let count = min(angles.count, tips.count, items.count)
            guard count > 0 else { return angles }
            for pass in 0..<passes {
                var moved = false
                for index in 0..<max(0, count - 1) {
                    let minimum = spacing(items[index], items[index + 1], tips[index], tips[index + 1])
                    let gap = angles[index + 1] - angles[index]
                    if gap < minimum {
                        let shift = (minimum - gap) / 2
                        angles[index] -= shift
                        angles[index + 1] += shift
                        moved = true
                    }
                }
                for index in 0..<count { angles[index] = min(max(angles[index], lowest), highest) }
                if pass < passes - 150 {
                    for index in 0..<count { angles[index] += (items[index].desired - angles[index]) * 0.015 }
                } else if !moved {
                    break
                }
            }
            return angles
        }
        func solve(_ items: [Candidate], rounds: Int) -> (angles: [Double], tips: [CGFloat]) {
            let emax = max(1, items.map(\.edits).max() ?? 1)
            var tips = items.map { tipRadius($0, at: $0.desired, emax: emax) }
            var angles = relax(items, from: items.map(\.desired), tips: tips, passes: 600)
            for _ in 0..<rounds {
                tips = zip(items, angles).map { pair in tipRadius(pair.0, at: pair.1, emax: emax) }
                angles = relax(items, from: angles, tips: tips, passes: 400)
            }
            tips = zip(items, angles).map { pair in tipRadius(pair.0, at: pair.1, emax: emax) }
            return (angles, tips)
        }
        func strain(_ items: [Candidate], _ angles: [Double], _ tips: [CGFloat])
            -> (needed: Double, drift: Double, byFamily: [String: Double]) {
            var needed = 0.0
            var drift = 0.0
            var byFamily: [String: Double] = [:]
            for index in items.indices where index < angles.count && index < tips.count {
                let moved = abs(angles[index] - items[index].desired)
                drift = max(drift, moved)
                if let key = items[index].familyKey, !items[index].isGlyph { byFamily[key, default: 0] += moved }
                if index + 1 < items.count, index + 1 < tips.count {
                    needed += spacing(items[index], items[index + 1], tips[index], tips[index + 1])
                }
            }
            return (needed, drift, byFamily)
        }

        // Fold families into glyphs while the ring is too crowded or a fan drifts
        // too far from its time; 30D and All start folded. Clicks override both.
        let available = highest - lowest
        let broad = map.range == .month || map.range == .all
        var folded = Set(familyKeys.filter { collapsed.contains($0) || (broad && !expanded.contains($0)) })
        var items = candidates(folded: folded)
        var solved = solve(items, rounds: 0)
        var attempts = 0
        while attempts < familyKeys.count {
            attempts += 1
            let fit = strain(items, solved.angles, solved.tips)
            let crowded = fit.needed > available * 0.8
            let drifting = fit.drift > MapOrbitMath.radians(24)
            guard crowded || drifting else { break }
            func score(_ key: String) -> Double {
                (fit.byFamily[key] ?? 0) + 0.05 * Double(familyMembers[key]?.count ?? 0)
            }
            let foldable = familyKeys.filter { !folded.contains($0) && !expanded.contains($0) }
            guard let pick = foldable.max(by: { lhs, rhs in
                let left = score(lhs)
                let right = score(rhs)
                return left != right ? left < right : lhs > rhs
            }) else { break }
            if !crowded && score(pick) < MapOrbitMath.radians(30) { break }
            folded.insert(pick)
            items = candidates(folded: folded)
            solved = solve(items, rounds: 0)
        }
        // Still more labels than the ring holds once every family that may fold has, as with dozens
        // of loose claude/* branches: the least edited petals drop their labels (the dial still names
        // them on hover), so the rest stay readable and every petal stays near its time.
        var crowding = strain(items, solved.angles, solved.tips)
        if crowding.needed > available {
            let quiet = items.indices.filter { index in
                !items[index].isGlyph && !(laneByID[items[index].id]?.isLive ?? false)
            }.sorted { lhs, rhs in
                let left = items[lhs]
                let right = items[rhs]
                return left.edits != right.edits ? left.edits < right.edits : left.id < right.id
            }
            for index in quiet where crowding.needed > available * 0.9 {
                items[index].labeled = false
                crowding = strain(items, solved.angles, solved.tips)
            }
        }
        solved = solve(items, rounds: 2)

        // Petals: two cubics out to the tip and back to the merge, or one for an open branch.
        let labelHeight = MapOrbitMeasure.lineHeight
        var petals: [Petal] = []
        for (index, item) in items.enumerated() {
            guard index < solved.angles.count, index < solved.tips.count else { continue }
            let tipAngle = solved.angles[index]
            let tipDistance = solved.tips[index]
            let lanes = item.laneIDs.compactMap { laneByID[$0] }
            let tip = geo.point(tipDistance, tipAngle)
            let fork = geo.point(item.forkRadius + 1.5, item.fork)
            let cubics: [[CGPoint]]
            if let merge = item.merge {
                let back = geo.point(item.mergeRadius + 1.5, merge)
                let sign: CGFloat = merge >= item.fork ? 1 : -1
                let spread: CGFloat = 0.3 * CGFloat(abs(merge - item.fork)) * tipDistance + 3
                var half: CGFloat = max(3.5, min(8.5, spread))
                if item.isGlyph {
                    let members: CGFloat = 2.5 * CGFloat(lanes.count)
                    half = max(half, min(15, members))
                }
                let tangent = MapOrbitGeometry.tangent(tipAngle)
                let out = MapOrbitMath.unit(MapOrbitMath.sub(tip, fork))
                let home = MapOrbitMath.unit(MapOrbitMath.sub(tip, back))
                let reachOut = 0.5 * MapOrbitMath.distance(tip, fork)
                let reachHome = 0.5 * MapOrbitMath.distance(tip, back)
                let first = MapOrbitMath.add(fork, MapOrbitMath.unit(MapOrbitMath.add(MapOrbitGeometry.radial(item.fork), out)),
                                             reachOut)
                let second = MapOrbitMath.add(tip, tangent, -half * sign)
                let third = MapOrbitMath.add(tip, tangent, half * sign)
                let fourth = MapOrbitMath.add(back, MapOrbitMath.unit(MapOrbitMath.add(MapOrbitGeometry.radial(merge), home)),
                                              reachHome)
                cubics = [[fork, first, second, tip], [tip, third, fourth, back]]
            } else {
                let length = tipDistance - item.forkRadius
                let first = MapOrbitMath.add(fork, MapOrbitGeometry.radial(item.fork), 0.5 * length)
                let second = MapOrbitMath.add(tip, MapOrbitGeometry.radial(tipAngle), -0.32 * length)
                cubics = [[fork, first, second, tip]]
            }
            var samples: [CGPoint] = []
            var lengths: [CGFloat] = []
            var total: CGFloat = 0
            for cubic in cubics {
                for step in 0...16 {
                    if step == 0 && !samples.isEmpty { continue }
                    let point = MapOrbitMath.bezier(cubic, CGFloat(step) / 16)
                    if let last = samples.last { total += MapOrbitMath.distance(last, point) }
                    samples.append(point)
                    lengths.append(total)
                }
            }
            let pathLength = max(total, 1)
            let xs = samples.map(\.x)
            let ys = samples.map(\.y)
            let spanX: CGFloat = (xs.max() ?? 0) - (xs.min() ?? 0)
            let spanY: CGFloat = (ys.max() ?? 0) - (ys.min() ?? 0)
            let area: CGFloat = spanX * spanY

            // Runs sit along the outline at their share of the branch's lifetime.
            let t0 = lanes.map(\.start).min() ?? map.now
            let t1 = lanes.map(laneEnd).max() ?? map.now
            let life = max(60, t1.timeIntervalSince(t0))
            let shortest: CGFloat = min(0.5, 6 / pathLength)
            let laneSpans = item.laneIDs.flatMap { spansByLane[$0] ?? [] }
                .sorted { ($0.start, $0.sessionKey, $0.index) < ($1.start, $1.sessionKey, $1.index) }
            let runs = laneSpans.map { span -> PetalRun in
                var from = CGFloat(max(0, min(1, span.start.timeIntervalSince(t0) / life)))
                var to = CGFloat(max(0, min(1, span.end.timeIntervalSince(t0) / life)))
                if to - from < shortest {
                    to = min(1, from + shortest)
                    from = max(0, to - shortest)
                }
                return PetalRun(span: span, from: from, to: to)
            }
            var bySource: [String: Int] = [:]
            for id in item.laneIDs {
                for (source, count) in laneSourceEdits[id] ?? [:] { bySource[source, default: 0] += count }
            }
            let dominant = bySource.filter { $0.value > 0 }.max { lhs, rhs in
                lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
            }?.key
            let liveStates = laneSpans.compactMap(\.live)
            let live = liveStates.contains(waiting) ? waiting : liveStates.first

            var rays: [Ray] = []
            if item.isGlyph {
                let ordered = lanes.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
                let count = Double(max(1, ordered.count))
                for (position, lane) in ordered.enumerated() {
                    let offset = (Double(position) + 0.5) / count - 0.5
                    let end = geo.point(tipDistance - 5 - 9 * CGFloat(abs(offset)),
                                        tipAngle + offset * min(0.5, 19 / Double(tipDistance)))
                    let laneFork = angle(lane.start)
                    let base = geo.point(forkRadius(lane, at: laneFork) + 1.5, laneFork)
                    let control = MapOrbitMath.add(base, MapOrbitGeometry.radial(laneFork),
                                                   0.45 * (tipDistance - item.parentRadius))
                    rays.append(Ray(base: base, control: control, tip: end))
                }
            }

            // The label reads outward from the tip, cut to the room it has.
            let labelRadius: CGFloat = tipDistance + (item.merge == nil ? 7 : 5)
            let reach = room(tipAngle)
            let spare: CGFloat = reach - item.parentRadius - minLength - 12
            let labelCap: CGFloat = min(max(64, min(150 * grow, spare)), reach - labelRadius - 2)
            let weight: NSFont.Weight = item.isGlyph || live != nil ? .semibold : .medium
            var name = item.name
            var nameWidth: CGFloat = item.labeled ? item.nameWidth : 0
            let countWidth: CGFloat = item.labeled ? item.countWidth : 0
            if item.labeled, nameWidth + countWidth > labelCap {
                name = MapOrbitMeasure.fitted(item.name, width: max(24, labelCap - countWidth), weight: weight)
                nameWidth = MapOrbitMeasure.width(name, weight: weight)
            }

            // The paths the painters and the hit test reuse.
            var outline = Path()
            if let first = cubics.first, first.count == 4 {
                outline.move(to: first[0])
                for cubic in cubics where cubic.count == 4 {
                    outline.addCurve(to: cubic[3], control1: cubic[1], control2: cubic[2])
                }
            }
            var fillPath = outline
            if item.merge != nil { fillPath.closeSubpath() }
            var rayPath = Path()
            var rayDots = Path()
            for ray in rays {
                rayPath.move(to: ray.base)
                rayPath.addQuadCurve(to: ray.tip, control: ray.control)
                rayDots.addPath(MapOrbitMath.circle(ray.tip, 1.2))
            }
            let labelWidth: CGFloat = nameWidth + countWidth
            let rotation = Self.labelRotation(tipAngle)
            let anchor: CGPoint = geo.point(labelRadius, tipAngle)
            let left: CGFloat = rotation.flipped ? -labelWidth : 0
            let labelBox = CGRect(x: left - 1.5, y: -labelHeight / 2, width: labelWidth + 3, height: labelHeight)
            let labelTurn: CGAffineTransform = CGAffineTransform(translationX: anchor.x, y: anchor.y)
                .rotated(by: CGFloat(rotation.angle))
            let labelKnockout: Path = Path(roundedRect: labelBox, cornerRadius: 2).applying(labelTurn)
            // Each piece typed on its own, so the long initializer below stays cheap to type-check.
            let fractions: [CGFloat] = lengths.map { $0 / pathLength }
            let noCommits: Bool = !lanes.isEmpty && lanes.allSatisfy { $0.commitCount == 0 && $0.merge == nil }
            let deleted: Bool = !lanes.isEmpty && lanes.allSatisfy(\.deleted)
            let fillShape: CGPath = fillPath.cgPath
            let trimmed: [Path] = runs.map { outline.trimmedPath(from: $0.from, to: $0.to) }
            let minX: CGFloat = xs.min() ?? 0
            let minY: CGFloat = ys.min() ?? 0
            let sampleBounds = CGRect(x: minX, y: minY, width: spanX, height: spanY)
            let inverse: Double = -rotation.angle
            let labelCos: CGFloat = CGFloat(cos(inverse))
            let labelSin: CGFloat = CGFloat(sin(inverse))
            let petal = Petal(id: item.id, laneIDs: item.laneIDs, familyKey: item.familyKey, isGlyph: item.isGlyph,
                              fork: fork, tip: tip, tipAngle: tipAngle, tipRadius: tipDistance,
                              closed: item.merge != nil, cubics: cubics, samples: samples,
                              fractions: fractions, area: area, sourceID: dominant,
                              sources: Set(bySource.keys), label: name, count: item.edits,
                              labelRadius: labelRadius, labelWidth: labelWidth,
                              showsLabel: item.labeled, live: live,
                              noCommits: noCommits, deleted: deleted, runs: runs, rays: rays,
                              outline: outline, fillPath: fillPath, fillShape: fillShape,
                              runPaths: trimmed, rayPath: rayPath, rayDots: rayDots, bounds: sampleBounds,
                              labelAnchor: anchor, labelAngle: rotation.angle, labelFlipped: rotation.flipped,
                              labelCos: labelCos, labelSin: labelSin, labelFootprint: labelKnockout)
            petals.append(petal)
        }
        let drawOrder = petals.indices.sorted { lhs, rhs in
            petals[lhs].count != petals[rhs].count ? petals[lhs].count > petals[rhs].count : lhs < rhs
        }

        // Family titles: curved outside the fan, with a bracket, where they fit.
        var families: [Family] = []
        for key in familyKeys {
            let ids = familyMembers[key] ?? []
            let isFolded = folded.contains(key)
            let title = familyTitle(key, count: ids.count)
            var family = Family(key: key, title: title, laneIDs: ids, folded: isFolded, titleRadius: nil,
                                titleStart: 0, titleEnd: 0, bracketStart: 0, bracketEnd: 0)
            let members = petals.filter { $0.familyKey == key && !$0.isGlyph }
            if !isFolded, members.count >= 2, let first = members.map(\.tipAngle).min(),
               let last = members.map(\.tipAngle).max() {
                let outer = (members.map { $0.labelRadius + $0.labelWidth }.max() ?? ringRadius) + 12
                let longest = min(220 * grow, max(80, CGFloat(last - first) * outer + 50))
                let fitted = MapOrbitMeasure.fitted(title, width: longest, weight: .semibold)
                let titleWidth = MapOrbitMeasure.width(fitted, weight: .semibold) + CGFloat(fitted.count) * 0.3
                let half = Double(titleWidth / 2 + 4) / Double(outer)
                let mid = (first + last) / 2
                if [mid - half, mid, mid + half].allSatisfy({ room($0) >= outer + 7 }) {
                    // The band from the bracket (7 in, 1 wide, round caps) to the title's outer edge.
                    let pad = 0.6 / Double(outer)
                    let low = min(mid - half, first - 0.012) - pad
                    let high = max(mid + half, last + 0.012) + pad
                    let bandOuter: [CGPoint] = geo.points(outer + 6.5, from: low, to: high)
                    let bandInner: [CGPoint] = geo.points(outer - 7.75, from: high, to: low)
                    // One run of points: a second addLines would start a new subpath.
                    let bandPoints: [CGPoint] = bandOuter + bandInner
                    var band = Path()
                    band.addLines(bandPoints)
                    band.closeSubpath()
                    family = Family(key: key, title: fitted, laneIDs: ids, folded: false, titleRadius: outer,
                                    titleStart: mid - half, titleEnd: mid + half,
                                    bracketStart: first - 0.012, bracketEnd: last + 0.012, reveal: band)
                }
            }
            families.append(family)
        }
        let titled = Set(families.compactMap { family -> String? in
            guard family.titleRadius != nil, family.key.hasPrefix("lane:") else { return nil }
            return String(family.key.dropFirst("lane:".count))
        })
        let orbits = orbitBases.map { base -> Orbit in
            var label: String?
            if !titled.contains(base.lane.id) {
                let arc = CGFloat(base.end - base.start) * (base.radius - 8) - 8
                if arc >= 36 { label = MapOrbitMeasure.fitted(MapText.title(base.lane), width: arc) }
            }
            var path = geo.arc(base.radius, from: base.start, to: base.end)
            path.move(to: geo.point(base.parent + 1, base.start))
            path.addLine(to: geo.point(base.radius, base.start))
            if base.lane.merge != nil {
                path.move(to: geo.point(base.parent + 1, base.end))
                path.addLine(to: geo.point(base.radius, base.end))
            }
            let runs: [ProjectMap.Span] = spansByLane[base.lane.id] ?? []
            let runPaths = runs.map { run -> Path in
                let drawn = extent(run, pad: 0.3, minimum: 0.9)
                return geo.arc(base.radius, from: drawn.start, to: drawn.end)
            }
            let runReach: [ArcSpan] = runs.map { extent($0, pad: 0.25, minimum: 0.8) }
            let hanging: [String] = children[base.lane.id] ?? []
            let laneIDs: [String] = [base.lane.id] + hanging
            let sources: Set<String> = laneSources[base.lane.id] ?? []
            return Orbit(lane: base.lane, radius: base.radius, parentRadius: base.parent, start: base.start,
                         end: base.end, runs: runs, label: label, path: path, runPaths: runPaths,
                         runReach: runReach, laneIDs: laneIDs, sources: sources)
        }

        // Merges: close ones into one lane share a pill, a count or a ring.
        var events: [String: [MergeEvent]] = [:]
        for marker in map.markers where marker.laneID == trunkID && marker.isBead {
            events[trunkID, default: []].append(MergeEvent(angle: angle(marker.date), sha: marker.sha,
                                                           pullRequest: marker.pullRequest,
                                                           quiet: marker.quietBranch != nil, laneID: marker.mergedLaneID))
        }
        for lane in branches {
            guard let merge = lane.merge, merge.intoLaneID != trunkID, orbitRadius[merge.intoLaneID] != nil else { continue }
            events[merge.intoLaneID, default: []].append(MergeEvent(angle: angle(merge.date), sha: merge.sha,
                                                                    pullRequest: merge.pullRequest, quiet: false,
                                                                    laneID: lane.id))
        }
        func shape(_ group: [MergeEvent], onTrunk: Bool) -> (style: Mark.Style, text: String, size: CGSize) {
            let numbers = Array(Set(group.compactMap(\.pullRequest))).sorted()
            if let low = numbers.first, let high = numbers.last {
                let text = low == high ? "#\(low)" : "#\(low)–\(high)"
                let pillWidth: CGFloat = max(20, MapOrbitMeasure.width(text, weight: .semibold, digits: true) + 9)
                return (style: Mark.Style.pill, text: text, size: CGSize(width: pillWidth, height: 13))
            }
            if group.count > 1 {
                let text = "\(group.count)"
                let diameter: CGFloat = max(12, MapOrbitMeasure.width(text, weight: .semibold, digits: true) + 6)
                return (style: Mark.Style.count, text: text, size: CGSize(width: diameter, height: diameter))
            }
            if group.first?.quiet == true {
                return (style: Mark.Style.quiet, text: "", size: CGSize(width: 6, height: 6))
            }
            let diameter: CGFloat = onTrunk ? 9 : 7
            return (style: Mark.Style.ring, text: "", size: CGSize(width: diameter, height: diameter))
        }
        func footprint(_ size: CGSize, _ direction: Double) -> CGFloat {
            abs(size.width * CGFloat(cos(direction))) + abs(size.height * CGFloat(sin(direction)))
        }
        var marks: [Mark] = []
        for target in events.keys.sorted() {
            let onTrunk = target == trunkID
            let radius = onTrunk ? ringRadius : (orbitRadius[target] ?? ringRadius)
            let ordered = (events[target] ?? []).sorted { ($0.angle, $0.sha) < ($1.angle, $1.sha) }
            var groups: [[MergeEvent]] = []
            for event in ordered {
                if var last = groups.last, !last.isEmpty {
                    let center = last.map(\.angle).reduce(0, +) / Double(last.count)
                    let current = shape(last, onTrunk: onTrunk)
                    let next = shape([event], onTrunk: onTrunk)
                    let reach = (footprint(current.size, center) + footprint(next.size, event.angle)) / 2 + 2
                    let apart = event.angle - center
                    if apart * Double(radius) < Double(reach) || apart < MapOrbitMath.radians(2.4) {
                        if !last.contains(where: { $0.sha == event.sha }) { last.append(event) }
                        groups[groups.count - 1] = last
                        continue
                    }
                }
                groups.append([event])
            }
            for group in groups where !group.isEmpty {
                let center = group.map(\.angle).reduce(0, +) / Double(group.count)
                let form = shape(group, onTrunk: onTrunk)
                let point = geo.point(radius, center)
                let knockout: Path
                let outline: Path
                switch form.style {
                case .pill:
                    let rect = CGRect(x: point.x - form.size.width / 2, y: point.y - form.size.height / 2,
                                      width: form.size.width, height: form.size.height)
                    knockout = Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: rect.height / 2 + 1.5)
                    outline = Path(roundedRect: rect, cornerRadius: rect.height / 2)
                case .count, .ring:
                    knockout = MapOrbitMath.circle(point, form.size.width / 2 + 1.5)
                    outline = MapOrbitMath.circle(point, form.size.width / 2)
                case .quiet:
                    knockout = MapOrbitMath.circle(point, 4)
                    outline = MapOrbitMath.circle(point, 2.7)
                }
                marks.append(Mark(shas: group.map(\.sha), laneIDs: group.compactMap(\.laneID),
                                  point: point, style: form.style, text: form.text,
                                  quiet: group.allSatisfy(\.quiet), size: form.size,
                                  footprint: knockout, shape: outline))
            }
        }

        // Days: a spoke and a ring tick at each 05:00, curved labels where the sector is wide enough.
        let dayStarts = Self.everyDayStart(map.axis, calendar: calendar)
        let bounds = [map.axis.start] + dayStarts
        let today = calendar.day(of: map.now)
        var days: [Day] = []
        for (index, start) in bounds.enumerated() {
            let finish = index + 1 < bounds.count ? bounds[index + 1] : map.now
            let from = angle(start)
            let to = angle(finish)
            let minimum = MapOrbitMath.radians(map.range == .week || map.range == .today ? 10 : 6)
            // Most days of a long history sit in folded seams; skip them before measuring any text.
            guard to - from >= minimum else { continue }
            let day = calendar.day(of: start)
            let isToday = day == today
            var text: String
            if isToday {
                text = "Today"
            } else if map.range == .today || map.range == .week {
                text = "\(DayFormat.weekday(day.weekday)) \(day.day)"
            } else if index == 0 || day.day == 1 {
                text = "\(DayFormat.monthAbbreviation(day, calendar: calendar)) \(day.day)"
            } else {
                text = "\(day.day)"
            }
            text = text.uppercased()
            let textWidth = MapOrbitMeasure.width(text, weight: .semibold) + CGFloat(max(0, text.count - 1))
            guard Double(textWidth + 6) <= (to - from) * Double(dayRadius) else { continue }
            days.append(Day(text: text, mid: (from + to) / 2, isToday: isToday))
        }
        // A long idle seam folds months of days into a sliver; spokes closer than a fraction of a
        // point draw as one, so one stands for them.
        var spokes: [Double] = []
        for start in dayStarts {
            let value = angle(start)
            if let last = spokes.last, value - last < 0.001 { continue }
            spokes.append(value)
        }
        var todayWedge: Wedge?
        if map.range != .today {
            let start = calendar.start(of: today)
            if start > map.axis.start { todayWedge = Wedge(start: angle(start), end: angle(map.now)) }
        }

        // Live sessions: a status glyph where their branch is now.
        func urgency(_ span: ProjectMap.Span) -> Int { span.live == waiting ? 0 : 1 }
        let liveSpans = spans.filter { $0.live != nil }
            .sorted { (urgency($0), $0.sessionKey) < (urgency($1), $1.sessionKey) }
        var liveMarks: [Live] = []
        for span in liveSpans {
            let point: CGPoint
            if let petal = petals.first(where: { $0.laneIDs.contains(span.laneID) }) {
                point = petal.tip
            } else if let radius = orbitRadius[span.laneID] {
                point = geo.point(radius, geo.angle(1))
            } else {
                point = geo.point(ringRadius, geo.angle(1))
            }
            guard !liveMarks.contains(where: { MapOrbitMath.distance($0.point, point) < 4 }) else { continue }
            liveMarks.append(Live(id: span.id, span: span, point: point, waiting: span.live == waiting))
        }

        // Paths every hover would otherwise build again: main's runs, the ring, the spokes, the rhythm.
        let trunkRuns = spans.filter { $0.laneID == trunkID || laneByID[$0.laneID] == nil }
        let trunkPaths = trunkRuns.map { run -> Path in
            let drawn = extent(run, pad: 0.3, minimum: 0.9)
            return geo.arc(ringRadius, from: drawn.start, to: drawn.end)
        }
        let gaps = map.axis.gaps
        var parts: [(start: Double, end: Double)] = []
        var previous = 0.0
        for gap in gaps {
            parts.append((previous, gap.lower + (gap.upper - gap.lower) * 0.2))
            previous = gap.lower + (gap.upper - gap.lower) * 0.8
        }
        parts.append((previous, 1))
        var ringPath = Path()
        for part in parts where part.end > part.start {
            ringPath.addPath(geo.arc(ringRadius, from: geo.angle(part.start), to: geo.angle(part.end)))
        }
        var ringTicks = Path()
        for gap in gaps {
            let mid = geo.angle((gap.lower + gap.upper) / 2)
            for side in [-1.0, 1.0] {
                let tick = mid + side * 1.7 / Double(ringRadius)
                let tangent = MapOrbitGeometry.tangent(tick)
                ringTicks.move(to: MapOrbitMath.add(geo.point(ringRadius - 4, tick), tangent, -1.3))
                ringTicks.addLine(to: MapOrbitMath.add(geo.point(ringRadius + 4, tick), tangent, 1.3))
            }
        }
        var dayTicks = Path()
        for spoke in spokes {
            dayTicks.move(to: geo.point(ringRadius - 5, spoke))
            dayTicks.addLine(to: geo.point(ringRadius + 5, spoke))
        }
        // Spokes run from just outside the dial; the part under the dial's words is the center's,
        // so the dial can clear it.
        let spokeStart = dialRadius + 3
        let spokeSplit = max(spokeStart, sunOuter + 2.5)
        var innerSpokes = Path()
        var outerSpokes = Path()
        for spoke in spokes {
            if spokeSplit > spokeStart {
                innerSpokes.move(to: geo.point(spokeStart, spoke))
                innerSpokes.addLine(to: geo.point(spokeSplit, spoke))
            }
            outerSpokes.move(to: geo.point(spokeSplit, spoke))
            outerSpokes.addLine(to: geo.point(ringRadius * 2.4, spoke))
        }
        let binPeak = max(1, binTotals.max() ?? 1)
        var sunPaths: [String: Path] = [:]
        if bins.count == binCount, binTotals.count == binCount {
            for bin in 0..<binCount {
                let total = binTotals[bin]
                guard total > 0 else { continue }
                let direction = geo.angle((Double(bin) + 0.5) / Double(binCount))
                let length = sunLength * CGFloat((Double(total) / Double(binPeak)).squareRoot())
                var radius = sunOuter
                for source in sourceOrder {
                    guard let edits = bins[bin][source], edits > 0 else { continue }
                    let segment = length * CGFloat(edits) / CGFloat(total)
                    sunPaths[source, default: Path()].move(to: geo.point(radius, direction))
                    sunPaths[source, default: Path()].addLine(to: geo.point(radius - segment, direction))
                    radius -= segment
                }
            }
        }
        var markFootprints = Path()
        for mark in marks { markFootprints.addPath(mark.footprint) }
        var labelFootprints = Path()
        for petal in petals where petal.showsLabel { labelFootprints.addPath(petal.labelFootprint) }

        self.map = map
        geometry = geo
        ring = ringRadius
        self.trackOuter = trackOuter
        self.trackStep = trackStep
        self.slotCount = slotCount
        self.dayRadius = dayRadius
        self.sunOuter = sunOuter
        self.sunLength = sunLength
        self.dialRadius = dialRadius
        self.hatches = hatches
        delegatedShare = share
        self.tracks = tracks
        self.binCount = binCount
        self.bins = bins
        self.binTotals = binTotals
        binMax = binPeak
        self.sessionBins = sessionBins
        self.laneBins = laneBins
        self.sourceOrder = sourceOrder
        self.orbits = orbits
        self.petals = petals
        self.drawOrder = drawOrder
        self.families = families
        self.marks = marks
        self.days = days
        self.todayWedge = todayWedge
        self.liveMarks = liveMarks
        liveStatus = liveSpans.first?.live
        nowRun = liveSpans.first
        nowClock = MomentFormat.string(map.now, template: "HH:mm", timeZone: calendar.timeZone)
        self.trunkRuns = trunkRuns
        self.trunkPaths = trunkPaths
        trunkReach = trunkRuns.map { extent($0, pad: 0.25, minimum: 0.8) }
        self.sessionLanes = sessionLanes
        self.laneSessions = laneSessions
        self.laneSources = laneSources
        self.children = children
        self.keyRows = keyRows
        self.keyRect = keyRect
        self.gaps = gaps
        self.ringPath = ringPath
        self.ringTicks = ringTicks
        self.dayTicks = dayTicks
        self.innerSpokes = innerSpokes
        self.outerSpokes = outerSpokes
        spokePhase = spokeSplit - spokeStart
        sunburst = sourceOrder.compactMap { source in sunPaths[source].map { SourcePath(source: source, path: $0) } }
        self.markFootprints = markFootprints
        self.labelFootprints = labelFootprints
    }

    func angle(_ date: Date) -> Double { geometry.angle(map.axis.position(of: date)) }

    /// Every day start inside the axis. TimeAxis.dayStarts stops after 400 days, which an
    /// all-history ring can pass; this stops at the axis end, or past a century of days.
    static func everyDayStart(_ axis: TimeAxis, calendar: ActivityCalendar) -> [Date] {
        guard !axis.segments.isEmpty else { return [] }
        let end = axis.end
        var day = calendar.day(of: axis.start).adding(days: 1)
        var starts: [Date] = []
        while starts.count < 40_000 {
            let date = calendar.start(of: day)
            guard date < end else { break }
            starts.append(date)
            day = day.adding(days: 1)
        }
        return starts
    }

    /// The moment at an axis position, inverting the folded axis.
    static func date(at position: Double, axis: TimeAxis) -> Date {
        for segment in axis.segments where position <= segment.upper {
            let span = segment.upper - segment.lower
            guard span > 0 else { return segment.start }
            let fraction = max(0, min(1, (position - segment.lower) / span))
            return segment.start.addingTimeInterval(segment.duration * fraction)
        }
        return axis.end
    }

    /// Radial labels read outward on the right half and inward on the left.
    static func labelRotation(_ angle: Double) -> (angle: Double, flipped: Bool) {
        var value = angle.truncatingRemainder(dividingBy: 2 * Double.pi)
        if value < 0 { value += 2 * Double.pi }
        if value > Double.pi { return (angle: value + Double.pi / 2, flipped: true) }
        return (angle: value - Double.pi / 2, flipped: false)
    }

    /// Curved text on the lower half is turned over so it reads left to right.
    static func readsUpsideDown(_ angle: Double) -> Bool {
        var value = angle.truncatingRemainder(dividingBy: 2 * Double.pi)
        if value < 0 { value += 2 * Double.pi }
        return value > Double.pi / 2 && value < 3 * Double.pi / 2
    }

    /// The branches and sessions with edits in one slice of the axis.
    func active(atBin bin: Int) -> (lanes: Set<String>, sessions: Set<String>)? {
        guard binCount > 0 else { return nil }
        let from = Self.date(at: Double(bin) / Double(binCount), axis: map.axis)
        let to = Self.date(at: Double(bin + 1) / Double(binCount), axis: map.axis)
        var lanes = Set<String>()
        var sessions = Set<String>()
        for span in map.spans {
            let end = span.live != nil ? map.now : span.end
            guard span.start <= to, end >= from else { continue }
            lanes.insert(span.laneID)
            sessions.insert(span.sessionKey)
        }
        guard !lanes.isEmpty else { return nil }
        return (lanes: lanes, sessions: sessions)
    }

    // MARK: Hit testing

    /// Live glyphs and now in the notch first, then merges, labels and titles, then by band:
    /// tracks, the rest of now's box, the ring, orbits, petals; anything else is a time cursor.
    func hit(at point: CGPoint) -> Hit {
        for mark in liveMarks where MapOrbitMath.distance(mark.point, point) <= 9 {
            return Hit(id: .run(mark.span.sessionKey, mark.span.index))
        }
        let center = geometry.center
        let polar = geometry.polar(point)
        let radius = polar.radius
        let direction = polar.angle
        let position = geometry.position(direction)
        // NOW and its clock: first inside the notch; past its edges the box lies over the newest and
        // oldest track runs, so there it waits until the tracks have been tried.
        let besideNow: Bool = abs(point.x - center.x) <= 18
        let ringTop: CGFloat = center.y - ring
        let inNowBox: Bool = besideNow && point.y >= ringTop + 5 && point.y <= ringTop + 31
        if inNowBox, position < 0 || position > 1, let live = nowRun {
            return Hit(id: .run(live.sessionKey, live.index))
        }
        var nearestMark: (index: Int, distance: CGFloat)?
        for (index, mark) in marks.enumerated() {
            let dx = abs(point.x - mark.point.x)
            let dy = abs(point.y - mark.point.y)
            guard dx <= mark.size.width / 2 + 2.5, dy <= mark.size.height / 2 + 2.5 else { continue }
            let distance = hypot(dx, dy)
            if nearestMark.map({ distance < $0.distance }) ?? true { nearestMark = (index, distance) }
        }
        if let index = nearestMark?.index {
            let mark = marks[index]
            if mark.shas.count == 1, let sha = mark.shas.first { return Hit(id: .commit(sha)) }
            return Hit(id: .cluster(mark.shas))
        }
        for petal in petals.reversed() where labelContains(petal, point) { return petalHit(petal) }
        for family in families {
            guard let titleRadius = family.titleRadius else { continue }
            if radius >= titleRadius - 8, radius <= titleRadius + 6, direction >= family.titleStart,
               direction <= family.titleEnd {
                return Hit(id: .group(family.laneIDs), familyKey: family.key)
            }
        }
        if radius < dialRadius { return Hit() }
        let tolerance = MapOrbitMath.radians(1)
        if radius >= trackInner - 3, radius <= trackOuter + 3 {
            let slot = max(0, min(slotCount - 1, Int(((trackOuter - radius) / trackStep).rounded())))
            var best: (track: Int, run: Int, distance: Double)?
            for (trackIndex, track) in tracks.enumerated() where track.slot == slot
                && direction >= track.start - tolerance && direction <= track.end + tolerance {
                for (runIndex, reach) in track.runReach.enumerated() {
                    let distance = reach.distance(direction)
                    if best.map({ distance < $0.distance }) ?? true { best = (trackIndex, runIndex, distance) }
                }
            }
            if let best {
                let run = tracks[best.track].runs[best.run]
                return Hit(id: .run(run.sessionKey, run.index))
            }
        }
        if inNowBox, let live = nowRun { return Hit(id: .run(live.sessionKey, live.index)) }
        if abs(radius - ring) <= 5 {
            if let index = trunkReach.firstIndex(where: { $0.distance(direction) <= tolerance }) {
                let run = trunkRuns[index]
                return Hit(id: .run(run.sessionKey, run.index))
            }
            if let gap = gaps.first(where: {
                direction >= geometry.angle($0.lower) - 0.01 && direction <= geometry.angle($0.upper) + 0.01
            }) {
                return Hit(id: .fold(gap.start))
            }
            if direction >= geometry.angle(0), direction <= geometry.angle(1) { return Hit(id: .lane(map.trunkID)) }
        }
        for orbit in orbits where abs(radius - orbit.radius) <= 4 && direction >= orbit.start - tolerance
            && direction <= orbit.end + tolerance {
            if let index = orbit.runReach.firstIndex(where: { $0.distance(direction) <= tolerance }) {
                let run = orbit.runs[index]
                return Hit(id: .run(run.sessionKey, run.index))
            }
            return Hit(id: .lane(orbit.lane.id))
        }
        // The nearest outline sample within 5pt, skipping petals whose samples lie farther off.
        var nearest: (petal: Int, sample: Int, distance: CGFloat)?
        for (index, petal) in petals.enumerated() where petal.bounds.insetBy(dx: -5, dy: -5).contains(point) {
            for (sampleIndex, sample) in petal.samples.enumerated() {
                let distance = MapOrbitMath.distance(sample, point)
                guard distance <= 5 else { continue }
                if nearest.map({ distance < $0.distance }) ?? true { nearest = (index, sampleIndex, distance) }
            }
        }
        if let nearest, nearest.petal < petals.count {
            let petal = petals[nearest.petal]
            if nearest.sample < petal.fractions.count {
                let fraction = petal.fractions[nearest.sample]
                if let run = petal.runs.first(where: { fraction >= $0.from - 0.03 && fraction <= $0.to + 0.03 }) {
                    let family: String? = petal.isGlyph ? nil : petal.familyKey
                    return Hit(id: .run(run.span.sessionKey, run.span.index), memberOf: family)
                }
            }
            return petalHit(petal)
        }
        // Inside a merged petal: the smallest that holds the point.
        var smallest: (petal: Int, area: CGFloat)?
        for (index, petal) in petals.enumerated() where petal.closed && petal.area > 0
            && petal.bounds.insetBy(dx: -1, dy: -1).contains(point) && petal.fillShape.contains(point) {
            if smallest.map({ petal.area < $0.area }) ?? true { smallest = (index, petal.area) }
        }
        if let smallest { return petalHit(petals[smallest.petal]) }
        guard position >= 0, position <= 1, binCount > 0 else { return Hit() }
        let bin = min(binCount - 1, max(0, Int(position * Double(binCount))))
        let gap = gaps.first { position >= $0.lower && position <= $0.upper }
        return Hit(id: gap.map { MapHitID.fold($0.start) }, bin: bin)
    }

    private func petalHit(_ petal: Petal) -> Hit {
        if petal.isGlyph { return Hit(id: .group(petal.laneIDs), familyKey: petal.familyKey) }
        return Hit(id: .lane(petal.id), memberOf: petal.familyKey)
    }

    private func labelContains(_ petal: Petal, _ point: CGPoint) -> Bool {
        guard petal.showsLabel else { return false }
        let dx: CGFloat = point.x - petal.labelAnchor.x
        let dy: CGFloat = point.y - petal.labelAnchor.y
        let x: CGFloat = dx * petal.labelCos - dy * petal.labelSin
        let y: CGFloat = dx * petal.labelSin + dy * petal.labelCos
        let left: CGFloat = petal.labelFlipped ? -petal.labelWidth : 0
        let right: CGFloat = left + petal.labelWidth
        return x >= left - 3 && x <= right + 3 && abs(y) <= 7
    }
}

// MARK: - Emphasis

/// What stands out: a hovered or selected item lights its branches and
/// sessions and dims the rest; a time cursor lights what was active then;
/// a focused profile dims every other profile.
private struct MapOrbitEmphasis {
    let item: MapHit?
    let focusSourceID: String?
    let litLanes: Set<String>?
    let litSessions: Set<String>?
    /// Edits per sunburst slice of the emphasized session or branches.
    let focusBins: [Int: Int]?
    let focusSource: String?
    /// The slice the time cursor's spoke marks.
    private(set) var cursorBin: Int?
    let dim: Double
    /// Lit petals get a brighter outline (not for the time cursor).
    let outlines: Bool

    init(layout: MapOrbitLayout, item: MapHit?, cursorBin: Int?, focusSourceID: String?) {
        var lanes: Set<String>?
        var sessions: Set<String>?
        var bins: [Int: Int]?
        var source: String?
        var dim = 0.18
        var outlines = true
        func focus(on ids: [String]) {
            let set = Set(ids)
            lanes = set
            sessions = set.reduce(into: Set<String>()) { $0.formUnion(layout.laneSessions[$1] ?? []) }
            var merged: [Int: Int] = [:]
            for id in set.sorted() {
                for (bin, count) in layout.laneBins[id] ?? [:] { merged[bin, default: 0] += count }
            }
            bins = merged.isEmpty ? nil : merged
            var bySource: [String: Int] = [:]
            for span in layout.map.spans where set.contains(span.laneID) { bySource[span.sourceID, default: 0] += span.editCount }
            source = bySource.max { lhs, rhs in lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key }?.key
        }
        if let item {
            switch item {
            case .live(let span), .span(let span):
                sessions = [span.sessionKey]
                lanes = layout.sessionLanes[span.sessionKey] ?? [span.laneID]
                bins = layout.sessionBins[span.sessionKey]
                source = span.sourceID
            case .lane(let lane):
                if lane.kind == .trunk {
                    sessions = layout.laneSessions[lane.id] ?? []
                    bins = layout.laneBins[lane.id]
                } else {
                    focus(on: [lane.id] + (layout.children[lane.id] ?? []))
                }
            case .group(let group):
                focus(on: group.map(\.id))
            case .commit(let marker):
                if let merged = marker.mergedLaneID {
                    focus(on: [merged])
                    bins = nil
                }
            case .cluster(let markers):
                let merged = markers.compactMap(\.mergedLaneID)
                if !merged.isEmpty {
                    focus(on: merged)
                    bins = nil
                }
            case .fold:
                break
            }
        } else if let cursorBin, let active = layout.active(atBin: cursorBin) {
            lanes = active.lanes
            sessions = active.sessions
            dim = 0.42
            outlines = false
        }
        self.item = item
        self.focusSourceID = focusSourceID
        litLanes = lanes
        litSessions = sessions
        focusBins = bins
        focusSource = source
        self.cursorBin = cursorBin
        self.dim = dim
        self.outlines = outlines
    }

    /// Something is lit, so everything else dims under the overlay's veil.
    var dims: Bool { litLanes != nil || litSessions != nil }

    /// Nothing lit and nothing to ring: the overlay draws no emphasis.
    var isResting: Bool { !dims && item == nil }

    /// The same emphasis with the spoke at `bin`: the spoke follows the pointer's own slice while
    /// what an earlier slice lit lingers.
    func spoke(at bin: Int?) -> MapOrbitEmphasis {
        var copy = self
        copy.cursorBin = bin
        return copy
    }

    func sessionLit(_ key: String) -> Bool { litSessions.map { $0.contains(key) } ?? true }

    func lanesLit(_ ids: [String]) -> Bool { litLanes.map { lanes in ids.contains { lanes.contains($0) } } ?? true }

    func sourceOpacity(_ id: String) -> Double {
        guard let focusSourceID else { return 1 }
        return id == focusSourceID ? 1 : 0.25
    }

    func sessionOpacity(_ key: String, source: String) -> Double {
        (sessionLit(key) ? 1 : dim) * sourceOpacity(source)
    }

    func laneOpacity(_ ids: [String], sources: Set<String>) -> Double {
        var value = lanesLit(ids) ? 1 : dim
        if let focusSourceID, !sources.isEmpty, !sources.contains(focusSourceID) { value *= 0.25 }
        return value
    }

    func petalOpacity(_ petal: MapOrbitLayout.Petal) -> Double { laneOpacity(petal.laneIDs, sources: petal.sources) }

    func highlights(_ petal: MapOrbitLayout.Petal) -> Bool {
        guard outlines, let litLanes else { return false }
        return petal.laneIDs.contains { litLanes.contains($0) }
    }

    func markOpacity(_ mark: MapOrbitLayout.Mark) -> Double { lanesLit(mark.laneIDs) ? 1 : dim }
}

// MARK: - Dial

/// The center's words: the totals, or a card for whatever is hovered.
private struct MapOrbitDial {
    var caption: String
    var captionColor: Color
    var tracking: CGFloat = 0
    var big: String
    var lines: [String]
    var status: String? = nil
    var statusColor: Color = .secondary
    /// A profile-colored ring around a session's card.
    var ring: Color? = nil
}

private struct MapOrbitDialText {
    let map: ProjectMap
    let sources: [AgentSource]
    let calendar: ActivityCalendar
    let layout: MapOrbitLayout

    func dial(item: MapHit?, cursorBin: Int?, palette: MapOrbitPalette) -> MapOrbitDial {
        guard let item else {
            if let cursorBin, let card = cursor(cursorBin) { return card }
            return overview(palette: palette)
        }
        switch item {
        case .live(let span), .span(let span): return session(span, palette: palette)
        case .lane(let lane): return lane.kind == .trunk ? trunk(lane) : branch(lane, palette: palette)
        case .group(let lanes): return group(lanes)
        case .fold(let gap): return fold(gap)
        case .commit, .cluster: return overview(palette: palette)
        }
    }

    private func overview(palette: MapOrbitPalette) -> MapOrbitDial {
        var caption = "ALL HISTORY"
        switch map.range {
        case .today: caption = "TODAY"
        case .week: caption = "LAST 7 DAYS"
        case .month: caption = "LAST 30 DAYS"
        case .all: caption = "ALL HISTORY"
        }
        let count = map.lanes.filter { $0.kind != .trunk }.count
        let branches = count == 1 ? "1 branch" : "\(count) branches"
        let lines: [String]
        if layout.hatches {
            lines = ["\(noun(map.editCount)) · \(GrowthText.sessions(map.sessionCount))",
                     "\(branches) · \(map.mergeCount) merged"]
        } else {
            // Nearly all subagent work: the share is said once here instead of hatching everything.
            let percent = Int((layout.delegatedShare * 100).rounded())
            lines = ["\(noun(map.editCount)) · \(percent)% by subagents",
                     "\(GrowthText.sessions(map.sessionCount)) · \(branches)"]
        }
        var dial = MapOrbitDial(caption: caption, captionColor: Color.primary.opacity(0.45), tracking: 1.2,
                                big: map.editCount.formatted(), lines: lines)
        let live = map.spans.filter { $0.live != nil }
        let waiting = live.filter { $0.live == LiveStatus.waiting.rawValue }
        if !live.isEmpty {
            let shown = waiting.isEmpty ? live : waiting
            var text = "● \(shown.count) \(waiting.isEmpty ? "working" : "needs input")"
            if shown.count == 1, let run = shown.first, let lane = map.lane(run.laneID) {
                text += " · " + MapText.title(lane)
            }
            dial.status = text
            dial.statusColor = waiting.isEmpty ? palette.workingText : palette.needsInputText
        }
        return dial
    }

    private func session(_ span: ProjectMap.Span, palette: MapOrbitPalette) -> MapOrbitDial {
        let runs = map.spans.filter { $0.sessionKey == span.sessionKey }
            .sorted { ($0.start, $0.index) < ($1.start, $1.index) }
        let edits = runs.reduce(0) { $0 + $1.editCount }
        let delegated = runs.reduce(0) { $0 + $1.delegated.count }
        let color = palette.profiles[span.sourceID] ?? Color.secondary
        let first = runs.first?.start ?? span.start
        let last = runs.contains(where: { $0.live != nil }) ? map.now : (runs.map(\.end).max() ?? span.end)
        var perLane: [String: Int] = [:]
        for run in runs { perLane[run.laneID, default: 0] += run.editCount }
        var lines = [delegated > 0 ? "\(noun(edits)) · \(delegated) by subagents" : noun(edits), range(first, last)]
        if let top = perLane.max(by: { lhs, rhs in lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key }),
           let lane = map.lane(top.key) {
            lines.append(perLane.count == 1 ? "on \(MapText.title(lane))"
                         : "\(perLane.count) branches · most on \(MapText.title(lane))")
        }
        return MapOrbitDial(caption: GrowthSeries.name(of: span.sourceID, sources: sources), captionColor: color,
                            big: edits.formatted(), lines: lines, ring: color)
    }

    private func trunk(_ lane: ProjectMap.Lane) -> MapOrbitDial {
        let sessions = layout.laneSessions[lane.id]?.count ?? 0
        let commits = map.markers.filter { $0.laneID == lane.id }.count
        return MapOrbitDial(caption: lane.title, captionColor: Color.primary.opacity(0.9), big: lane.editCount.formatted(),
                            lines: ["\(noun(lane.editCount)) · \(GrowthText.sessions(sessions))",
                                    "\(commits == 1 ? "1 commit" : "\(commits) commits") · \(map.mergeCount) merged"])
    }

    /// A branch's lifetime, commits and where its merge falls among its siblings'.
    private func branch(_ lane: ProjectMap.Lane, palette: MapOrbitPalette) -> MapOrbitDial {
        let sessions = layout.laneSessions[lane.id]?.count ?? 0
        let commits = lane.commitCount == 1 ? "1 commit" : "\(lane.commitCount) commits"
        let start = lane.forkedAt ?? lane.start
        let isOpen = lane.merge == nil && (lane.isLive || lane.isHead)
        let end = lane.merge?.date ?? (isOpen ? map.now : lane.end)
        let lived = MapText.duration(end.timeIntervalSince(start))
        var lines = ["\(noun(lane.editCount)) · \(GrowthText.sessions(sessions)) · \(commits)",
                     isOpen ? "\(moment(start)) → now" : range(start, end)]
        if let merge = lane.merge {
            if merge.intoLaneID == map.trunkID {
                lines.append([merge.pullRequest.map { "#\($0)" }, "merged after \(lived)"].compactMap { $0 }
                    .joined(separator: " · "))
            } else {
                let siblings = map.lanes.compactMap(\.merge).filter { $0.intoLaneID == merge.intoLaneID }.map(\.date).sorted()
                let order = (siblings.firstIndex(of: merge.date) ?? 0) + 1
                let into = map.lane(merge.intoLaneID).map(MapText.title) ?? ""
                lines.append("into \(into) · \(MapOrbitText.ordinal(order)) of \(siblings.count)")
            }
        } else if lane.deleted {
            lines.append("deleted · lived \(lived)")
        } else {
            lines.append(lane.kind == .folder ? "worktree · \(lived)" : "open · \(lived)")
        }
        var dial = MapOrbitDial(caption: MapText.title(lane), captionColor: Color.primary.opacity(0.9),
                                big: lane.editCount.formatted(), lines: lines)
        if let live = map.spans.first(where: { $0.laneID == lane.id && $0.live != nil })?.live {
            let waiting = live == LiveStatus.waiting.rawValue
            dial.status = waiting ? "● needs input" : "● working"
            dial.statusColor = waiting ? palette.needsInputText : palette.workingText
        }
        return dial
    }

    private func group(_ lanes: [ProjectMap.Lane]) -> MapOrbitDial {
        let ids = Set(lanes.map(\.id))
        let title = layout.families.first { Set($0.laneIDs) == ids }?.title ?? MapText.groupTitle(lanes)
        let edits = lanes.reduce(0) { $0 + $1.editCount }
        let landed = lanes.filter { $0.merge != nil }.count
        let start = lanes.map { $0.forkedAt ?? $0.start }.min() ?? map.now
        let end = lanes.map { $0.merge?.date ?? $0.end }.max() ?? map.now
        let sessions = lanes.reduce(into: Set<String>()) { $0.formUnion(layout.laneSessions[$1.id] ?? []) }.count
        return MapOrbitDial(caption: title, captionColor: Color.primary.opacity(0.9), big: edits.formatted(),
                            lines: ["\(noun(edits)) · \(lanes.count) branches · \(GrowthText.sessions(sessions))",
                                    range(start, end), "\(landed) of \(lanes.count) landed"])
    }

    private func fold(_ gap: TimeAxis.Segment) -> MapOrbitDial {
        MapOrbitDial(caption: "IDLE", captionColor: Color.primary.opacity(0.45), tracking: 1.2,
                     big: MapText.idle(gap.duration), lines: ["from \(moment(gap.start))", "to \(moment(gap.end))"])
    }

    /// The slice of time under the cursor: when, how many edits, what was active.
    private func cursor(_ bin: Int) -> MapOrbitDial? {
        guard bin >= 0, bin < layout.binCount, bin < layout.binTotals.count else { return nil }
        let from = MapOrbitLayout.date(at: Double(bin) / Double(layout.binCount), axis: map.axis)
        let to = MapOrbitLayout.date(at: Double(bin + 1) / Double(layout.binCount), axis: map.axis)
        let edits = layout.binTotals[bin]
        var lines = ["\(noun(edits)) · \(clock(from))–\(clock(to))"]
        if let active = layout.active(atBin: bin) {
            lines.append(active.lanes.count == 1 ? "1 branch active" : "\(active.lanes.count) branches active")
        }
        return MapOrbitDial(caption: moment(from).uppercased(), captionColor: Color.primary.opacity(0.5), tracking: 0.8,
                            big: edits.formatted(), lines: lines)
    }

    var summary: String {
        let branches = map.lanes.filter { $0.kind != .trunk }
        var text = "\(GrowthText.edits(map.editCount)) in \(GrowthText.sessions(map.sessionCount)) on "
            + "\(branches.count == 1 ? "1 branch" : "\(branches.count) branches"), \(map.mergeCount) merged"
        if let live = map.spans.last(where: { $0.live != nil }), let lane = map.lane(live.laneID) {
            text += ", 1 \(live.live == LiveStatus.waiting.rawValue ? "needs input" : "working") on \(MapText.title(lane))"
        }
        let busiest = branches.sorted { ($1.editCount, $0.id) < ($0.editCount, $1.id) }.prefix(5)
            .map { "\(MapText.title($0)) \($0.editCount)" }
        if !busiest.isEmpty { text += ". Busiest branches: " + busiest.joined(separator: ", ") }
        let folded = layout.families.filter(\.folded).map(\.title)
        if !folded.isEmpty { text += ". Folded: " + folded.joined(separator: ", ") }
        return text
    }

    private func noun(_ edits: Int) -> String { edits == 1 ? "edit" : "edits" }

    /// "Mon 2 22:02–23:40", "Mon 22:02 – Tue 02:24", or "Fri 30 – Tue 3" for longer stretches.
    private func range(_ from: Date, _ to: Date) -> String {
        let first = calendar.day(of: from)
        let last = calendar.day(of: to)
        switch first.days(to: last) {
        case ...0: return "\(moment(from))–\(clock(to))"
        case 1: return "\(DayFormat.weekday(first.weekday)) \(clock(from)) – \(DayFormat.weekday(last.weekday)) \(clock(to))"
        default: return "\(DayFormat.weekday(first.weekday)) \(first.day) – \(DayFormat.weekday(last.weekday)) \(last.day)"
        }
    }

    /// "Mon 2 22:02", on the activity day.
    private func moment(_ date: Date) -> String {
        let day = calendar.day(of: date)
        return "\(DayFormat.weekday(day.weekday)) \(day.day) \(clock(date))"
    }

    private func clock(_ date: Date) -> String {
        MomentFormat.string(date, template: "HH:mm", timeZone: calendar.timeZone)
    }
}

// MARK: - Painter

/// The orbit in four passes: the static picture at rest (recorded once per layout), the hover's
/// emphasis over it, the parts that never dim, and the center. Each draws only what it owns.
private enum MapOrbitPainter {
    private static func ink(_ opacity: Double) -> Color { Color.primary.opacity(opacity) }

    private static func circle(_ center: CGPoint, _ radius: CGFloat) -> Path { MapOrbitMath.circle(center, radius) }

    // MARK: Passes

    /// Everything but the center, the day labels, now and the key, at rest.
    static func drawStatic(_ layout: MapOrbitLayout, palette: MapOrbitPalette, emphasis: MapOrbitEmphasis,
                           isDark: Bool, in context: inout GraphicsContext) {
        // One layer, so knockouts clear only marks drawn here, never the card behind.
        context.drawLayer { layer in
            drawBackground(layout, in: &layer)
            for track in layout.tracks { drawTrack(track, palette: palette, emphasis: emphasis, in: &layer) }
            drawPetalFills(layout, palette: palette, emphasis: emphasis, isDark: isDark, onlyLit: false, in: &layer)
            for orbit in layout.orbits { drawOrbit(orbit, layout, palette: palette, emphasis: emphasis, in: &layer) }
            drawRing(layout, in: &layer)
            for (run, path) in zip(layout.trunkRuns, layout.trunkPaths) {
                drawTrunkRun(run, path: path, layout, palette: palette, emphasis: emphasis, in: &layer)
            }
            for index in layout.drawOrder where index < layout.petals.count {
                drawPetal(layout.petals[index], layout, palette: palette, emphasis: emphasis, isDark: isDark, in: &layer)
            }
            drawMarks(layout, emphasis: emphasis, in: &layer)
            for petal in layout.petals where petal.showsLabel {
                drawLabel(petal, palette: palette, emphasis: emphasis, in: &layer)
            }
            for family in layout.families { drawFamily(family, layout, emphasis: emphasis, in: &layer) }
        }
    }

    /// What never dims, over the hover's veil: the day labels, now and the key.
    static func drawFixed(_ layout: MapOrbitLayout, palette: MapOrbitPalette, in context: inout GraphicsContext) {
        drawDayLabels(layout, in: &context)
        drawNow(layout, palette: palette, in: &context)
        drawKey(layout, in: &context)
    }

    /// The center, which follows every hover: the spokes under the dial, the edit rhythm, the time
    /// cursor and the dial, whose words are knocked out of the bars beneath.
    static func drawCenter(_ layout: MapOrbitLayout, palette: MapOrbitPalette, emphasis: MapOrbitEmphasis,
                           dial: MapOrbitDial, in context: inout GraphicsContext) {
        context.drawLayer { layer in
            if !layout.innerSpokes.isEmpty {
                layer.stroke(layout.innerSpokes, with: .color(ink(0.09)), style: StrokeStyle(lineWidth: 0.75, dash: [1.5, 3]))
            }
            drawSunburst(layout, palette: palette, emphasis: emphasis, in: &layer)
            drawCursor(layout, emphasis: emphasis, in: &layer)
            drawDial(layout, dial: dial, in: &layer)
        }
    }

    /// A hovered, pinned or time-cursor emphasis over the static picture: a veil in the card's
    /// color dims everything, the lit subset is drawn again at full strength, and lit marks, labels
    /// and family titles, which look as they do at rest, show through holes in the veil. Then the
    /// rings around a commit, or a fold's band.
    static func drawEmphasis(_ layout: MapOrbitLayout, size: CGSize, palette: MapOrbitPalette,
                             emphasis: MapOrbitEmphasis, isDark: Bool, in context: inout GraphicsContext) {
        context.drawLayer { layer in
            if emphasis.dims {
                drawLit(layout, size: size, palette: palette, emphasis: emphasis, isDark: isDark, in: &layer)
            }
            drawHighlight(layout, emphasis: emphasis, in: &layer)
        }
    }

    private static func drawLit(_ layout: MapOrbitLayout, size: CGSize, palette: MapOrbitPalette,
                                emphasis: MapOrbitEmphasis, isDark: Bool, in layer: inout GraphicsContext) {
        let full = Path(CGRect(origin: .zero, size: size))
        var veil = layer
        veil.opacity = 1 - emphasis.dim
        veil.drawLayer { card in
            card.fill(full, with: .color(palette.canvas))
            card.fill(full, with: .color(palette.surface))
        }
        // The glow, today's wedge and the spokes never dim.
        drawBackground(layout, in: &layer)
        // Fills blend with the veil as they did with the picture.
        drawPetalFills(layout, palette: palette, emphasis: emphasis, isDark: isDark, onlyLit: true, in: &layer)
        // A layer of its own, so clearing the lines under marks and labels keeps the veil.
        layer.drawLayer { lit in
            for orbit in layout.orbits where emphasis.lanesLit(orbit.laneIDs) {
                drawOrbit(orbit, layout, palette: palette, emphasis: emphasis, in: &lit)
            }
            // The ring never dims; main's runs on it follow their sessions.
            drawRing(layout, in: &lit)
            for (run, path) in zip(layout.trunkRuns, layout.trunkPaths) where emphasis.sessionLit(run.sessionKey) {
                drawTrunkRun(run, path: path, layout, palette: palette, emphasis: emphasis, in: &lit)
            }
            for track in layout.tracks where emphasis.sessionLit(track.sessionKey) {
                drawTrack(track, palette: palette, emphasis: emphasis, in: &lit)
            }
            for index in layout.drawOrder where index < layout.petals.count {
                let petal = layout.petals[index]
                if emphasis.lanesLit(petal.laneIDs) {
                    drawPetal(petal, layout, palette: palette, emphasis: emphasis, isDark: isDark, in: &lit)
                } else if let live = petal.live, !petal.closed {
                    // A live tip's glow never dims.
                    halo(petal.tip, radius: 11, color: palette.status(live), in: &lit)
                }
            }
            knockout(layout.markFootprints, in: &lit)
            knockout(layout.labelFootprints, in: &lit)
            // A lit label of a highlighted petal is brighter than at rest, so it is drawn again.
            for petal in layout.petals where petal.showsLabel && relabels(petal, emphasis) {
                drawLabel(petal, palette: palette, emphasis: emphasis, in: &lit)
            }
        }
        var reveal = Path()
        for mark in layout.marks where emphasis.lanesLit(mark.laneIDs) { reveal.addPath(mark.footprint) }
        for petal in layout.petals where petal.showsLabel && emphasis.lanesLit(petal.laneIDs) && !relabels(petal, emphasis) {
            reveal.addPath(petal.labelFootprint)
        }
        for family in layout.families where emphasis.lanesLit(family.laneIDs) {
            if let band = family.reveal { reveal.addPath(band) }
        }
        if !reveal.isEmpty { knockout(reveal, in: &layer) }
    }

    /// A lit label whose tone differs from the one at rest (a live one keeps its status color).
    private static func relabels(_ petal: MapOrbitLayout.Petal, _ emphasis: MapOrbitEmphasis) -> Bool {
        petal.live == nil && (petal.count > 0 || petal.isGlyph) && emphasis.highlights(petal)
    }

    private static func knockout(_ path: Path, in context: inout GraphicsContext) {
        var clear = context
        clear.blendMode = .destinationOut
        clear.fill(path, with: .color(.black))
    }

    /// A static glow; nothing here animates.
    private static func halo(_ center: CGPoint, radius: CGFloat, color: Color, in context: inout GraphicsContext) {
        let gradient = Gradient(colors: [color.opacity(0.45), color.opacity(0)])
        context.fill(circle(center, radius), with: .radialGradient(gradient, center: center, startRadius: 0, endRadius: radius))
    }

    /// Solid for direct edits; a comb of ticks over a thin core where subagents made most of them.
    private static func strokeRun(_ path: Path, color: Color, opacity: Double, width: CGFloat, comb: Bool,
                                  in context: inout GraphicsContext) {
        guard !path.isEmpty else { return }
        if comb {
            context.stroke(path, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: width + 1.5, dash: [0.9, 0.85]))
            context.stroke(path, with: .color(color.opacity(opacity)), lineWidth: max(0.9, width * 0.34))
        } else {
            context.stroke(path, with: .color(color.opacity(opacity)), style: StrokeStyle(lineWidth: width, lineCap: .round))
        }
    }

    private static func combs(_ run: ProjectMap.Span, _ layout: MapOrbitLayout) -> Bool {
        layout.hatches && run.delegated.count > run.direct.count
    }

    // MARK: Background

    private static func drawBackground(_ layout: MapOrbitLayout, in context: inout GraphicsContext) {
        let geometry = layout.geometry
        let center = geometry.center
        let reach = layout.ring * 2.4
        let glow = Gradient(stops: [
            .init(color: ink(0), location: 0), .init(color: ink(0), location: 0.34),
            .init(color: ink(0.035), location: 0.42), .init(color: ink(0), location: 0.78)
        ])
        context.fill(circle(center, reach), with: .radialGradient(glow, center: center, startRadius: 0, endRadius: reach))
        let core = Gradient(colors: [ink(0.03), ink(0)])
        context.fill(circle(center, layout.ring - 1),
                     with: .radialGradient(core, center: center, startRadius: 0, endRadius: layout.ring))
        // Today: a soft spotlight wedge from 05:00 to now.
        if let wedge = layout.todayWedge {
            var path = Path()
            path.move(to: center)
            for point in geometry.points(reach, from: wedge.start, to: wedge.end) { path.addLine(to: point) }
            path.closeSubpath()
            let light = Gradient(stops: [
                .init(color: ink(0), location: 0.2), .init(color: ink(0.045), location: 0.42),
                .init(color: ink(0.02), location: 0.62), .init(color: ink(0), location: 0.92)
            ])
            context.fill(path, with: .radialGradient(light, center: center, startRadius: 0, endRadius: reach))
        }
        // The spokes past the rhythm; the center draws the rest, continuing the dashes.
        context.stroke(layout.outerSpokes, with: .color(ink(0.09)),
                       style: StrokeStyle(lineWidth: 0.75, dash: [1.5, 3], dashPhase: layout.spokePhase))
    }

    // MARK: Sunburst

    /// One bar per slice of the axis, pointing inward, as long as the square
    /// root of its edits and stacked by profile.
    private static func drawSunburst(_ layout: MapOrbitLayout, palette: MapOrbitPalette, emphasis: MapOrbitEmphasis,
                                     in context: inout GraphicsContext) {
        let geometry = layout.geometry
        let count = layout.binCount
        guard count > 0, layout.binTotals.count == count else { return }
        let peak = Double(max(1, layout.binMax))
        let focused = emphasis.focusBins != nil
        for entry in layout.sunburst {
            let opacity = 0.78 * emphasis.sourceOpacity(entry.source) * (focused ? 0.28 : 1)
            context.stroke(entry.path, with: .color(palette.profile(entry.source).opacity(opacity)), lineWidth: 1.4)
        }
        if let focus = emphasis.focusBins {
            var path = Path()
            for (bin, edits) in focus where bin >= 0 && bin < count && edits > 0 {
                let total: Int = max(1, layout.binTotals[bin])
                let angle: Double = geometry.angle((Double(bin) + 0.5) / Double(count))
                let full: CGFloat = layout.sunLength * CGFloat((Double(total) / peak).squareRoot())
                let share: CGFloat = CGFloat(min(edits, total)) / CGFloat(total)
                let length: CGFloat = full * share
                path.move(to: geometry.point(layout.sunOuter, angle))
                path.addLine(to: geometry.point(layout.sunOuter - length, angle))
            }
            let color = emphasis.focusSource.flatMap { palette.profiles[$0] } ?? ink(0.85)
            context.stroke(path, with: .color(color), lineWidth: 1.6)
        }
        context.stroke(circle(geometry.center, layout.sunOuter + 2.5), with: .color(ink(0.06)), lineWidth: 0.75)
    }

    private static func drawDayLabels(_ layout: MapOrbitLayout, in context: inout GraphicsContext) {
        for day in layout.days {
            drawCurved(day.text, radius: layout.dayRadius, mid: day.mid, font: Theme.Typeface.micro.weight(.semibold),
                       color: ink(day.isToday ? 0.58 : 0.36), tracking: 1, geometry: layout.geometry, in: &context)
        }
    }

    /// Text along a circle, glyph by glyph; turned over on the lower half.
    private static func drawCurved(_ text: String, radius: CGFloat, mid: Double, font: Font, color: Color,
                                   tracking: CGFloat, geometry: MapOrbitGeometry, in context: inout GraphicsContext) {
        guard radius > 1, !text.isEmpty else { return }
        let glyphs = text.map { character -> (text: GraphicsContext.ResolvedText, width: CGFloat) in
            let resolved = context.resolve(Text(String(character)).font(font).foregroundColor(color))
            return (resolved, resolved.measure(in: CGSize(width: 100, height: 40)).width)
        }
        let widths: CGFloat = glyphs.reduce(CGFloat(0)) { $0 + $1.width }
        let gaps: CGFloat = tracking * CGFloat(max(0, glyphs.count - 1))
        let total: CGFloat = widths + gaps
        let upsideDown = MapOrbitLayout.readsUpsideDown(mid)
        let span = Double(total) / Double(radius)
        var offset: CGFloat = 0
        for glyph in glyphs {
            let along = Double(offset + glyph.width / 2) / Double(radius)
            let angle = upsideDown ? mid + span / 2 - along : mid - span / 2 + along
            let point = geometry.point(radius, angle)
            var turned = context
            turned.translateBy(x: point.x, y: point.y)
            turned.rotate(by: .radians(upsideDown ? angle + Double.pi : angle))
            turned.draw(glyph.text, at: .zero, anchor: .center)
            offset += glyph.width + tracking
        }
    }

    // MARK: Sessions

    /// A faint thread over a session's life, thick arcs for its runs, a dot at now while live.
    private static func drawTrack(_ track: MapOrbitLayout.Track, palette: MapOrbitPalette, emphasis: MapOrbitEmphasis,
                                  in context: inout GraphicsContext) {
        let color = palette.profile(track.sourceID)
        let opacity = emphasis.sessionOpacity(track.sessionKey, source: track.sourceID)
        context.stroke(track.thread, with: .color(color.opacity(0.3 * opacity)), lineWidth: 0.8)
        strokeRun(track.solid, color: color, opacity: opacity, width: 3.25, comb: false, in: &context)
        strokeRun(track.comb, color: color, opacity: opacity, width: 3.25, comb: true, in: &context)
        if let live = track.live {
            context.fill(circle(track.endPoint, 2.4), with: .color(palette.status(live).opacity(opacity)))
        }
    }

    // MARK: Structure

    /// Petal fills glow where blooms overlap: screen in dark mode, multiply in light.
    private static func drawPetalFills(_ layout: MapOrbitLayout, palette: MapOrbitPalette, emphasis: MapOrbitEmphasis,
                                       isDark: Bool, onlyLit: Bool, in context: inout GraphicsContext) {
        var fills = context
        fills.blendMode = isDark ? .screen : .multiply
        for index in layout.drawOrder where index < layout.petals.count {
            let petal = layout.petals[index]
            guard petal.closed, let source = petal.sourceID else { continue }
            if onlyLit && !emphasis.lanesLit(petal.laneIDs) { continue }
            let opacity = emphasis.petalOpacity(petal)
            fills.fill(petal.fillPath, with: .color(palette.profile(source).opacity((isDark ? 0.14 : 0.10) * opacity)))
        }
    }

    /// An integration branch's orbit, its spurs and label, and the runs of lit sessions on it; a
    /// dimmed session's runs are left to the veiled picture beneath.
    private static func drawOrbit(_ orbit: MapOrbitLayout.Orbit, _ layout: MapOrbitLayout, palette: MapOrbitPalette,
                                  emphasis: MapOrbitEmphasis, in context: inout GraphicsContext) {
        let opacity = emphasis.laneOpacity(orbit.laneIDs, sources: orbit.sources)
        context.stroke(orbit.path, with: .color(ink(0.5 * opacity)),
                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        for (run, path) in zip(orbit.runs, orbit.runPaths) where emphasis.sessionLit(run.sessionKey) {
            strokeRun(path, color: palette.profile(run.sourceID),
                      opacity: min(opacity, emphasis.sessionOpacity(run.sessionKey, source: run.sourceID)),
                      width: 3, comb: combs(run, layout), in: &context)
        }
        if let label = orbit.label {
            drawCurved(label, radius: orbit.radius - 8, mid: (orbit.start + orbit.end) / 2, font: Theme.Typeface.micro,
                       color: ink(0.55 * opacity), tracking: 0.2, geometry: layout.geometry, in: &context)
        }
    }

    /// The main ring, broken at each fold with a "//", ticked at each day.
    private static func drawRing(_ layout: MapOrbitLayout, in context: inout GraphicsContext) {
        context.stroke(layout.ringPath, with: .color(ink(0.55)), lineWidth: 2.25)
        context.stroke(layout.ringTicks, with: .color(ink(0.4)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        context.stroke(layout.dayTicks, with: .color(ink(0.42)), lineWidth: 1)
    }

    /// One of main's own runs on the ring.
    private static func drawTrunkRun(_ run: ProjectMap.Span, path: Path, _ layout: MapOrbitLayout, palette: MapOrbitPalette,
                                     emphasis: MapOrbitEmphasis, in context: inout GraphicsContext) {
        strokeRun(path, color: palette.profile(run.sourceID),
                  opacity: emphasis.sessionOpacity(run.sessionKey, source: run.sourceID), width: 3.5,
                  comb: combs(run, layout), in: &context)
    }

    /// An outline, the lit sessions' runs along it, member rays inside a glyph, the fork dot and the tip.
    private static func drawPetal(_ petal: MapOrbitLayout.Petal, _ layout: MapOrbitLayout, palette: MapOrbitPalette,
                                  emphasis: MapOrbitEmphasis, isDark: Bool, in context: inout GraphicsContext) {
        let opacity = emphasis.petalOpacity(petal)
        let lit = emphasis.highlights(petal)
        let color = petal.sourceID.flatMap { palette.profiles[$0] }
        let stroke = color.map { $0.opacity((lit ? 1 : 0.72) * opacity) } ?? ink(0.36 * opacity)
        context.stroke(petal.outline, with: .color(stroke), lineWidth: lit ? 1.4 : 0.9)
        for (run, segment) in zip(petal.runs, petal.runPaths) where emphasis.sessionLit(run.span.sessionKey) {
            let runColor = palette.profile(run.span.sourceID)
            let runOpacity = min(opacity, emphasis.sessionOpacity(run.span.sessionKey, source: run.span.sourceID))
            if isDark {
                context.stroke(segment, with: .color(runColor.opacity(0.22 * runOpacity)),
                               style: StrokeStyle(lineWidth: 6, lineCap: .round))
            }
            strokeRun(segment, color: runColor, opacity: runOpacity, width: 2.6, comb: combs(run.span, layout), in: &context)
        }
        let tone = color ?? ink(0.55)
        if !petal.rays.isEmpty {
            context.stroke(petal.rayPath, with: .color(tone.opacity(0.5 * opacity)), lineWidth: 0.8)
            context.fill(petal.rayDots, with: .color(tone.opacity(opacity)))
        }
        context.fill(circle(petal.fork, 1.7), with: .color(tone.opacity(opacity)))
        guard !petal.closed else { return }
        if let live = petal.live {
            // The status glyph sits on top; this is its static glow.
            halo(petal.tip, radius: 11, color: palette.status(live), in: &context)
        } else if petal.noCommits {
            knockout(circle(petal.tip, 3.4), in: &context)
            context.stroke(circle(petal.tip, 2.6), with: .color(tone.opacity(opacity)),
                           style: StrokeStyle(lineWidth: 1.1, dash: [1.2, 1]))
        } else {
            context.fill(circle(petal.tip, 2.6), with: .color(tone.opacity(opacity)))
        }
    }

    private static func drawMarks(_ layout: MapOrbitLayout, emphasis: MapOrbitEmphasis, in context: inout GraphicsContext) {
        let digits = Theme.Typeface.micro.weight(.semibold).monospacedDigit()
        for mark in layout.marks {
            let opacity = emphasis.markOpacity(mark)
            let stroke = ink((mark.quiet ? 0.5 : 0.9) * opacity)
            knockout(mark.footprint, in: &context)
            switch mark.style {
            case .pill:
                context.stroke(mark.shape, with: .color(stroke), lineWidth: 1.2)
                let text = context.resolve(Text(mark.text).font(digits)
                    .foregroundColor(ink((mark.quiet ? 0.6 : 0.95) * opacity)))
                context.draw(text, at: mark.point, anchor: .center)
            case .count:
                context.stroke(mark.shape, with: .color(stroke), lineWidth: 1.3)
                let text = context.resolve(Text(mark.text).font(digits).foregroundColor(ink(0.95 * opacity)))
                context.draw(text, at: mark.point, anchor: .center)
            case .ring:
                context.stroke(mark.shape, with: .color(stroke), lineWidth: 1.4)
                context.fill(circle(mark.point, 1.3), with: .color(ink(0.9 * opacity)))
            case .quiet:
                context.stroke(mark.shape, with: .color(stroke), lineWidth: 1)
            }
        }
    }

    // MARK: Labels

    /// A radial label at a tip, the edit count after the name, knocked out of the lines beneath.
    private static func drawLabel(_ petal: MapOrbitLayout.Petal, palette: MapOrbitPalette, emphasis: MapOrbitEmphasis,
                                  in context: inout GraphicsContext) {
        let opacity = emphasis.petalOpacity(petal)
        let tone: Double
        if petal.count > 0 || petal.isGlyph {
            tone = emphasis.highlights(petal) ? 1 : 0.86
        } else {
            tone = 0.5
        }
        let base: Color = petal.live.map { palette.statusText($0) } ?? ink(tone)
        let strong = petal.isGlyph || petal.live != nil
        var name = Text(petal.label).font(strong ? Theme.Typeface.micro.weight(.semibold) : Theme.Typeface.micro)
        if petal.deleted { name = name.italic() }
        var label = name.foregroundColor(base.opacity(opacity))
        if petal.count > 0 {
            label = label + Text(" \(petal.count.formatted())").font(Theme.Typeface.note)
                .foregroundColor(ink(0.42 * opacity))
        }
        knockout(petal.labelFootprint, in: &context)
        var turned = context
        turned.translateBy(x: petal.labelAnchor.x, y: petal.labelAnchor.y)
        turned.rotate(by: .radians(petal.labelAngle))
        turned.draw(turned.resolve(label), at: .zero, anchor: petal.labelFlipped ? .trailing : .leading)
    }

    /// A curved bold title outside an open family, with a bracket over its fan.
    private static func drawFamily(_ family: MapOrbitLayout.Family, _ layout: MapOrbitLayout, emphasis: MapOrbitEmphasis,
                                   in context: inout GraphicsContext) {
        guard let radius = family.titleRadius else { return }
        let geometry = layout.geometry
        let opacity = emphasis.laneOpacity(family.laneIDs, sources: [])
        context.stroke(geometry.arc(radius - 7, from: family.bracketStart, to: family.bracketEnd),
                       with: .color(ink(0.22 * opacity)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        drawCurved(family.title, radius: radius, mid: (family.titleStart + family.titleEnd) / 2,
                   font: Theme.Typeface.micro.weight(.semibold), color: ink(0.72 * opacity), tracking: 0.3,
                   geometry: geometry, in: &context)
    }

    /// The notch: where the window starts, now, and its time; green or amber while a session is live.
    private static func drawNow(_ layout: MapOrbitLayout, palette: MapOrbitPalette, in context: inout GraphicsContext) {
        let geometry = layout.geometry
        let center = geometry.center
        let ring = layout.ring
        context.fill(circle(geometry.point(ring, geometry.angle(0)), 1.75), with: .color(ink(0.5)))
        let end = geometry.point(ring, geometry.angle(1))
        if let live = layout.liveStatus { halo(end, radius: 9, color: palette.status(live), in: &context) }
        context.fill(circle(end, 3), with: .color(layout.liveStatus.map(palette.status) ?? ink(0.85)))
        let word = context.resolve(Text("NOW").font(Theme.Typeface.micro.weight(.bold)).tracking(1)
            .foregroundColor(layout.liveStatus.map(palette.statusText) ?? ink(0.62)))
        context.draw(word, at: CGPoint(x: center.x, y: center.y - ring + 13), anchor: .center)
        let time = context.resolve(Text(layout.nowClock).font(Theme.Typeface.micro.weight(.semibold).monospacedDigit())
            .foregroundColor(ink(0.78)))
        context.draw(time, at: CGPoint(x: center.x, y: center.y - ring + 25), anchor: .center)
    }

    /// A spoke at the time under the pointer.
    private static func drawCursor(_ layout: MapOrbitLayout, emphasis: MapOrbitEmphasis, in context: inout GraphicsContext) {
        guard let bin = emphasis.cursorBin, layout.binCount > 0 else { return }
        let geometry = layout.geometry
        let angle = geometry.angle((Double(bin) + 0.5) / Double(layout.binCount))
        var spoke = Path()
        spoke.move(to: geometry.point(layout.dialRadius + 1, angle))
        spoke.addLine(to: geometry.point(layout.ring + 9, angle))
        context.stroke(spoke, with: .color(ink(0.5)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        context.fill(circle(geometry.point(layout.ring, angle), 2), with: .color(ink(0.85)))
    }

    /// The dial's rows, each fitted to the circle's chord at its height.
    private static func drawDial(_ layout: MapOrbitLayout, dial: MapOrbitDial, in context: inout GraphicsContext) {
        let center = layout.geometry.center
        let radius = layout.dialRadius
        // A session's card is a disc in its profile color, reaching over the rhythm's inner edge.
        if let ring = dial.ring {
            let disc = circle(center, radius + 5)
            knockout(disc, in: &context)
            context.fill(disc, with: .color(ring.opacity(0.07)))
            context.stroke(disc, with: .color(ring.opacity(0.85)), lineWidth: 1.25)
        }
        var rows: [(text: String, font: Font, tracking: CGFloat, color: Color, height: CGFloat)] = []
        rows.append((dial.caption, Theme.Typeface.micro.weight(.semibold), dial.tracking, dial.captionColor, 13))
        rows.append((dial.big, Theme.Typeface.display, 0, Color.primary.opacity(0.95), 27))
        for line in dial.lines { rows.append((line, Theme.Typeface.micro, 0, Color.primary.opacity(0.6), 12)) }
        if let status = dial.status {
            rows.append((status, Theme.Typeface.micro.weight(.semibold), 0, dial.statusColor, 13))
        }
        let total = rows.reduce(CGFloat(0)) { $0 + $1.height }
        // Text may reach a little into the rhythm; each row is knocked out of the bars beneath.
        let reach = radius + (dial.ring == nil ? 10 : 4)
        var y = -total / 2
        for row in rows {
            let middle: CGFloat = y + row.height / 2
            let halfChord: CGFloat = max(0, reach * reach - middle * middle).squareRoot()
            let chord: CGFloat = 2 * halfChord - 2
            drawLine(row.text, at: CGPoint(x: center.x, y: center.y + middle), font: row.font, tracking: row.tracking,
                     color: row.color, width: max(24, chord), in: &context)
            y += row.height
        }
    }

    /// One dial row: resolved once when it fits, tail-truncated when it does not.
    private static func drawLine(_ text: String, at point: CGPoint, font: Font, tracking: CGFloat, color: Color,
                                 width: CGFloat, in context: inout GraphicsContext) {
        guard !text.isEmpty else { return }
        var resolved = context.resolve(Text(text).font(font).tracking(tracking).foregroundColor(color))
        var size = resolved.measure(in: CGSize(width: 600, height: 60))
        if size.width > width {
            let value = truncated(text, width: width, font: font, tracking: tracking, context: context)
            resolved = context.resolve(Text(value).font(font).tracking(tracking).foregroundColor(color))
            size = resolved.measure(in: CGSize(width: 600, height: 60))
        }
        let boxHeight: CGFloat = max(0, size.height - 2)
        let box = CGRect(x: point.x - size.width / 2 - 2, y: point.y - size.height / 2 + 1,
                         width: size.width + 4, height: boxHeight)
        knockout(Path(roundedRect: box, cornerRadius: 3), in: &context)
        context.draw(resolved, at: point, anchor: .center)
    }

    /// Tail-truncates `text`, already too wide, to `width`; a binary search measures a handful of candidates.
    private static func truncated(_ text: String, width: CGFloat, font: Font, tracking: CGFloat,
                                  context: GraphicsContext) -> String {
        func measure(_ value: String) -> CGFloat {
            context.resolve(Text(value).font(font).tracking(tracking)).measure(in: CGSize(width: 2000, height: 60)).width
        }
        var low = 1
        var high = text.count - 1
        var best = String(text.prefix(1)) + "…"
        while low <= high {
            let middle = (low + high) / 2
            let candidate = String(text.prefix(middle)).trimmingCharacters(in: .whitespaces) + "…"
            if measure(candidate) <= width {
                best = candidate
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return best
    }

    // MARK: Highlight and key

    private static func drawHighlight(_ layout: MapOrbitLayout, emphasis: MapOrbitEmphasis, in context: inout GraphicsContext) {
        guard let item = emphasis.item else { return }
        switch item {
        case .commit(let marker):
            for mark in layout.marks where mark.shas.contains(marker.sha) { outline(mark, in: &context) }
        case .cluster(let markers):
            let shas = Set(markers.map(\.sha))
            for mark in layout.marks where mark.shas.contains(where: { shas.contains($0) }) { outline(mark, in: &context) }
        case .fold(let gap):
            let geometry = layout.geometry
            let start = geometry.angle(gap.lower)
            let end = geometry.angle(gap.upper)
            var band = Path()
            let outer = geometry.points(layout.ring + 8, from: start, to: end)
            let inner = Array(geometry.points(layout.sunOuter + 2, from: start, to: end).reversed())
            band.addLines(outer + inner)
            band.closeSubpath()
            context.fill(band, with: .color(ink(0.08)))
        case .live, .span, .lane, .group:
            break
        }
    }

    private static func outline(_ mark: MapOrbitLayout.Mark, in context: inout GraphicsContext) {
        let rect = CGRect(x: mark.point.x - mark.size.width / 2 - 3, y: mark.point.y - mark.size.height / 2 - 3,
                          width: mark.size.width + 6, height: mark.size.height + 6)
        context.stroke(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(ink(0.85)), lineWidth: 1)
    }

    /// The orbit's own encodings, in the bottom-right corner; the legend under the card names the profiles.
    private static func drawKey(_ layout: MapOrbitLayout, in context: inout GraphicsContext) {
        guard let rect = layout.keyRect else { return }
        for (index, row) in layout.keyRows.enumerated() {
            let y = rect.minY + 6.5 + CGFloat(index) * 13
            let x = rect.minX + 9
            switch row.kind {
            case .comb:
                var line = Path()
                line.move(to: CGPoint(x: x - 7, y: y))
                line.addLine(to: CGPoint(x: x + 7, y: y))
                context.stroke(line, with: .color(ink(0.6)), style: StrokeStyle(lineWidth: 5, dash: [0.9, 0.85]))
                context.stroke(line, with: .color(ink(0.6)), lineWidth: 1)
            case .noCommits:
                context.stroke(circle(CGPoint(x: x, y: y), 2.6), with: .color(ink(0.6)),
                               style: StrokeStyle(lineWidth: 1.1, dash: [1.2, 1]))
            case .fold:
                var ticks = Path()
                for offset in [-2.0, 2.0] as [CGFloat] {
                    ticks.move(to: CGPoint(x: x + offset - 1.5, y: y + 3.5))
                    ticks.addLine(to: CGPoint(x: x + offset + 1.5, y: y - 3.5))
                }
                context.stroke(ticks, with: .color(ink(0.55)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
            }
            let text = context.resolve(Text(row.text).font(Theme.Typeface.micro).foregroundColor(ink(0.5)))
            context.draw(text, at: CGPoint(x: rect.minX + 20, y: y), anchor: .leading)
        }
    }
}
