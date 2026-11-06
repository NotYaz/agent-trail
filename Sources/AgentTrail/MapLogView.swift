import AppKit
import SwiftUI
import AgentTrailCore

// MARK: - Branch log

/// The Map as a vertical git log, newest on top. Each branch is a column from
/// its fork to its merge, and a column is reused once its branch has landed.
/// Sessions are thick profile segments on their branch's column, a list beside
/// the graph names each branch at its tip, indented under the branch it merged
/// into, and idle stretches fold into thin bands.
struct MapLogView: View {
    let context: MapCanvasContext
    /// Written on hover and click, never observed here: only the tiles, the list
    /// overlay and the fold watch follow it, so a hover never re-runs this body.
    let hover: MapHoverModel
    /// The layout lasts until the map, the size or the unfolded stretch changes, so hovering only redraws overlays.
    @State private var cache = MapLogCache()
    /// The scroll offset. Only the header, the minimap's box and the Now pill observe it.
    @State private var scroll = MapLogScroll()
    /// The fold a click opened. `MapLogFoldWatch` keeps it on the selection, so it folds again once the selection moves on.
    @State private var unfolded: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    fileprivate static let space = "mapLogScroll"

    /// Private state makes the memberwise initializer private, and MapView builds this view from another file.
    init(context: MapCanvasContext, hover: MapHoverModel) {
        self.context = context
        self.hover = hover
    }

    var body: some View {
        let map = context.map
        let viewport = max(80, context.size.height - MapLogLayout.headerHeight)
        let width = min(context.size.width, MapLogLayout.maxContentWidth)
        let layout = cache.layout(map: map, sources: context.sources, calendar: context.calendar,
                                  width: width, viewport: viewport, unfolded: unfolded)
        let key = MapLogStaticKey(base: MapStaticKey(layout: cache.generation, focusSourceID: context.focusSourceID,
                                                     colorScheme: colorScheme),
                                  contrast: contrast, theme: ColorTheme.current)
        let colors: [String: Color] = Dictionary(uniqueKeysWithValues: Set(map.spans.map(\.sourceID)).map {
            ($0, context.color($0))
        })
        let projectName: String = (map.projectPath as NSString).lastPathComponent
        let label: String = "Branch log of " + projectName + ", " + map.range.title.lowercased()
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                MapLogHeader(layout: layout, scroll: scroll)
                    .frame(width: layout.width, height: MapLogLayout.headerHeight)
                ScrollView(.vertical) {
                    content(layout, colors: colors, key: key)
                }
                .coordinateSpace(NamedCoordinateSpace.named(Self.space))
                .scrollDisabled(!layout.scrolls)
                .scrollIndicators(.never)
                .mask { MapLogFade(active: layout.scrolls) }
                .overlay(alignment: .topTrailing) {
                    if layout.scrolls {
                        minimap(layout, colors: colors, key: key, proxy: proxy)
                    }
                }
                .overlay(alignment: .top) {
                    MapLogNowPill(scroll: scroll) { scrollToNow(proxy) }
                }
            }
            .background { MapLogFoldWatch(hover: hover, unfolded: $unfolded) }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(MapLogText.summary(layout))
            .accessibilityAction(named: "Scroll to now") { scrollToNow(proxy) }
            // The clamped log, centered; up to `maxContentWidth` both frames are the full width.
            .frame(width: layout.width)
            .frame(width: context.size.width)
        }
    }

    private func scrollToNow(_ proxy: ScrollViewProxy) {
        let animation = Theme.Motion.animation(Theme.Motion.standard, reduceMotion: reduceMotion, still: rendersStill)
        withAnimation(animation) { proxy.scrollTo(MapLogAnchor(index: 0), anchor: .top) }
    }

    // MARK: Content

    private func content(_ layout: MapLogLayout, colors: [String: Color], key: MapLogStaticKey) -> some View {
        let hover = self.hover
        let focusSourceID = context.focusSourceID
        return ZStack(alignment: .topLeading) {
            MapLogAnchors(count: layout.anchorCount, step: layout.anchorStep)
            // Tiles, so a long window draws only what is on screen.
            LazyVStack(spacing: 0) {
                ForEach(layout.tiles) { tile in
                    MapLogTile(layout: layout, tile: tile, colors: colors, key: key, focusSourceID: focusSourceID,
                               hover: hover)
                }
            }
            ForEach(layout.glyphs) { glyph in
                StatusGlyph(kind: glyph.kind, size: 10, animates: context.animatesLive)
                    .position(glyph.point)
            }
            MapLogListOverlay(layout: layout, colors: colors, key: key, sources: context.sources,
                              calendar: context.calendar, focusSourceID: focusSourceID, scroll: scroll,
                              showsCard: !context.showsDetailPanel, hover: hover)
        }
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
        .background(alignment: .top) { MapLogOffsetReader(scroll: scroll) }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            // Only the graph holds a run across the lines between its bars; the list's rows,
            // every one of which keeps the graph dimmed, hand over at once.
            case .active(let point): hover.hover(layout.hit(at: point), holdsRun: point.x < layout.labelX - 10)
            case .ended: hover.hover(nil)
            }
        }
        .gesture(SpatialTapGesture().onEnded { value in hover.select(layout.hit(at: value.location)) })
    }

    // MARK: Minimap

    /// The whole window in a 9pt strip; a click or drag jumps there.
    private func minimap(_ layout: MapLogLayout, colors: [String: Color], key: MapLogStaticKey,
                         proxy: ScrollViewProxy) -> some View {
        let height = max(20, layout.viewport - 10)
        let scale = height / max(layout.contentHeight, 1)
        return ZStack(alignment: .top) {
            MapStaticCanvas(key: key) { graphics, size in
                let inks = layout.inks(for: key, colors: colors, in: graphics.environment)
                MapLogPainter.drawMinimap(layout, inks: inks, size: size, in: &graphics)
            }
            .equatable()
            MapLogViewport(scroll: scroll, scale: scale, viewport: layout.viewport, height: height)
        }
        .frame(width: MapLogLayout.minimapWidth, height: height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
            let target = value.location.y / scale - layout.viewport / 2
            proxy.scrollTo(MapLogAnchor(index: layout.anchor(at: target)), anchor: .top)
        })
        .help("Click or drag to move through the window")
        .padding(.top, 5)
        .padding(.trailing, 7)
    }
}

// MARK: - Hover

/// What the static layers depend on besides the layout, the focused profile and
/// the appearance: contrast and the color theme recolor the log without a new layout.
private struct MapLogStaticKey: Equatable {
    let base: MapStaticKey
    let contrast: ColorSchemeContrast
    let theme: ColorTheme
}

/// What a hover layer depends on: the look of the static layers and the item it
/// lights. A layer keyed by it records once per item, however often the hover publishes.
private struct MapLogLitKey: Equatable {
    let look: MapLogStaticKey
    let id: MapHitID?
}

/// Fades a lit layer by adding it to what lies under it in its compositing group:
/// lit marks to the dimming graph and the marks they replace, rings to the rings
/// they replace. What both light keeps its full strength through the fade, where
/// a plain crossfade would dim it midway.
private struct MapLogAdditiveFade: ViewModifier {
    let opacity: Double

    static var transition: AnyTransition {
        .modifier(active: MapLogAdditiveFade(opacity: 0), identity: MapLogAdditiveFade(opacity: 1))
    }

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .blendMode(.plusLighter)
    }
}

/// The group the graph and its lit marks add up in, flattened before it is drawn
/// over the folds and gutter beneath. The live log always has it, so a fade never
/// changes the graph's identity; a still render has it only while something is
/// lit, so its resting log draws the graph exactly as it did without one.
private struct MapLogAdditiveStack: ViewModifier {
    let active: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if active { content.compositingGroup() } else { content }
    }
}

/// One band of the log. Its static layers (folds and the gutter, the graph,
/// each row) record once per layout and look; a hover changes only the graph's
/// dimming, the rows' opacity and the lit layers among them, and every one of
/// those eases. The graph dims on the veil's curve and stays down while the
/// emphasis moves from one lit item to the next; rows and lit layers hand over
/// by identity, the old one fading out as the new one fades in. The lit marks
/// add onto the graph at the strength the veil takes from it, so the lit item
/// holds its full strength through every fade.
private struct MapLogTile: View {
    let layout: MapLogLayout
    let tile: MapLogLayout.Tile
    let colors: [String: Color]
    let key: MapLogStaticKey
    let focusSourceID: String?
    @ObservedObject var hover: MapHoverModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill

    var body: some View {
        let layout = self.layout
        let colors = self.colors
        let key = self.key
        let top = tile.minY
        let band = MapLogBand(top: top, bottom: top + tile.height)
        let resting = MapLogEmphasis(focusSourceID: focusSourceID)
        let lit = hover.emphasized
        let emphasis = layout.emphasis(for: lit, focusSourceID: focusSourceID)
        let graphOpacity: Double = emphasis.dims ? MapLogEmphasis.dimmed : 1
        let veil = MapMotion.animation(MapMotion.veil, reduceMotion: reduceMotion, still: rendersStill)
        let crossfade = MapMotion.animation(MapMotion.crossfade, reduceMotion: reduceMotion, still: rendersStill)
        ZStack(alignment: .topLeading) {
            // A focused fold's shade, under the band it darkens.
            foldFocus(emphasis, band: band)
                .animation(crossfade, value: emphasis.foldStart)
            MapStaticCanvas(key: key) { graphics, _ in
                graphics.translateBy(x: 0, y: -top)
                let inks = layout.inks(for: key, colors: colors, in: graphics.environment)
                MapLogPainter.drawBackground(layout, inks: inks, band: band, in: &graphics)
            }
            .equatable()
            // The graph and what the pointer lights, summed in one group. The lit marks fade
            // on the veil's curve, so what they gain is what the graph loses.
            ZStack(alignment: .topLeading) {
                MapStaticCanvas(key: key) { graphics, _ in
                    graphics.translateBy(x: 0, y: -top)
                    let inks = layout.inks(for: key, colors: colors, in: graphics.environment)
                    MapLogPainter.drawGraph(layout, inks: inks, emphasis: resting, band: band, in: &graphics)
                }
                .equatable()
                .opacity(graphOpacity)
                .animation(veil, value: emphasis.dims)
                litMarks(emphasis, lit: lit, band: band)
                    .animation(veil, value: lit)
            }
            .modifier(MapLogAdditiveStack(active: !rendersStill || emphasis.dims))
            ForEach(layout.tileRows[tile.id], id: \.self) { index in
                let row = layout.rows[index]
                let patch = layout.rowFrame(row)
                MapStaticCanvas(key: key) { graphics, _ in
                    graphics.translateBy(x: -patch.minX, y: -patch.minY)
                    let inks = layout.inks(for: key, colors: colors, in: graphics.environment)
                    MapLogPainter.drawRow(row, layout, inks: inks, emphasis: resting, focused: false, alpha: 1,
                                          in: &graphics)
                }
                .equatable()
                .frame(width: patch.width, height: patch.height)
                // Only the opacity animates; the offset sits outside the animation.
                .opacity(emphasis.rowOpacity(row))
                .animation(crossfade, value: lit)
                .offset(x: patch.minX, y: patch.minY - top)
            }
            // The rings that mark the lit item, over everything and never dimmed.
            litRings(emphasis, lit: lit, band: band)
                .animation(veil, value: lit)
        }
        .frame(width: layout.width, height: tile.height, alignment: .topLeading)
    }

    /// The shade of a hovered or pinned fold, which fades in and out with the fold's emphasis.
    /// Nothing is drawn at rest.
    private func foldFocus(_ emphasis: MapLogEmphasis, band: MapLogBand) -> some View {
        let layout = self.layout
        let key = self.key
        let top = tile.minY
        return ZStack {
            if let start = emphasis.foldStart {
                MapStaticCanvas(key: MapLogLitKey(look: key, id: .fold(start))) { graphics, _ in
                    graphics.translateBy(x: 0, y: -top)
                    MapLogPainter.drawFoldFocus(layout, emphasis: emphasis, band: band, in: &graphics)
                }
                .equatable()
                .id(start)
                .transition(.opacity)
            }
        }
    }

    /// What `emphasis` lights, drawn again at the strength the dimmed graph gives up and
    /// recorded once per item. It adds onto the graph, as does the layer it hands over to,
    /// so a mark both light sums to full strength as the veil comes and goes and as the
    /// emphasis moves. Nothing is drawn at rest.
    private func litMarks(_ emphasis: MapLogEmphasis, lit: MapHitID?, band: MapLogBand) -> some View {
        let layout = self.layout
        let colors = self.colors
        let key = self.key
        let top = tile.minY
        return ZStack {
            if emphasis.dims {
                MapStaticCanvas(key: MapLogLitKey(look: key, id: lit)) { graphics, _ in
                    graphics.translateBy(x: 0, y: -top)
                    let inks = layout.inks(for: key, colors: colors, in: graphics.environment)
                    MapLogPainter.drawGraph(layout, inks: inks, emphasis: emphasis, band: band, in: &graphics)
                }
                .equatable()
                .opacity(1 - MapLogEmphasis.dimmed)
                .id(lit)
                .transition(MapLogAdditiveFade.transition)
            }
        }
    }

    /// The rings around the lit branch, session or commits, recorded once per item. The
    /// rings leaving and those arriving add up in their own group, so a ring both draw
    /// holds steady as the emphasis moves. Nothing is drawn at rest.
    private func litRings(_ emphasis: MapLogEmphasis, lit: MapHitID?, band: MapLogBand) -> some View {
        let layout = self.layout
        let key = self.key
        let top = tile.minY
        return ZStack {
            if emphasis.highlights {
                MapStaticCanvas(key: MapLogLitKey(look: key, id: lit)) { graphics, _ in
                    graphics.translateBy(x: 0, y: -top)
                    MapLogPainter.drawHighlight(layout, emphasis: emphasis, band: band, in: &graphics)
                }
                .equatable()
                .id(lit)
                .transition(MapLogAdditiveFade.transition)
            }
        }
        .compositingGroup()
    }
}

/// The list's part of the emphasis: a focused row drawn bold in place of its
/// hidden static copy, and the card beside a hovered branch, both crossfading
/// as the emphasis moves. Beside the window's details panel, which describes
/// the branch itself, the card is left out.
private struct MapLogListOverlay: View {
    let layout: MapLogLayout
    let colors: [String: Color]
    let key: MapLogStaticKey
    let sources: [AgentSource]
    let calendar: ActivityCalendar
    let focusSourceID: String?
    /// Read, not observed: the card is placed where the log was scrolled when the hover changed.
    let scroll: MapLogScroll
    /// False while the window's details panel describes the emphasized item.
    let showsCard: Bool
    @ObservedObject var hover: MapHoverModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill

    var body: some View {
        let layout = self.layout
        let colors = self.colors
        let key = self.key
        let lit = hover.emphasized
        let emphasis = layout.emphasis(for: lit, focusSourceID: focusSourceID)
        let card = showsCard ? cardModel(emphasis) : nil
        let crossfade = MapMotion.animation(MapMotion.crossfade, reduceMotion: reduceMotion, still: rendersStill)
        ZStack(alignment: .topLeading) {
            ForEach(emphasis.focusedRows, id: \.self) { index in
                let row = layout.rows[index]
                let patch = layout.rowFrame(row)
                MapStaticCanvas(key: MapLogLitKey(look: key, id: lit)) { graphics, _ in
                    graphics.translateBy(x: -patch.minX, y: -patch.minY)
                    let inks = layout.inks(for: key, colors: colors, in: graphics.environment)
                    MapLogPainter.drawRow(row, layout, inks: inks, emphasis: emphasis, focused: true,
                                          alpha: emphasis.rowAlpha(row), in: &graphics)
                }
                .equatable()
                .frame(width: patch.width, height: patch.height)
                .offset(x: patch.minX, y: patch.minY)
                .transition(.opacity)
            }
            if let card {
                MapLogCard(model: card, color: card.sourceID.flatMap { colors[$0] })
                    .offset(x: card.origin.x, y: card.origin.y)
                    .id(card.laneID)
                    .transition(.opacity)
            }
        }
        // Each bold row and card fades in step with its static row; the frame sits outside the animation.
        .animation(crossfade, value: lit)
        .frame(width: layout.width, height: layout.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// A branch's life, beside the list: where it forked, how long it lived,
    /// and where it landed among the branches merged with it.
    private func cardModel(_ emphasis: MapLogEmphasis) -> MapLogCardModel? {
        guard let laneID = emphasis.focusLaneID, let position = layout.branchIndex[laneID],
              let rowIndex = layout.rows.firstIndex(where: { $0.laneID == laneID && $0.style != .session })
        else { return nil }
        let branch = layout.branches[position]
        let lane = branch.lane
        var profile: String?
        var lines: [String] = []
        let shares = layout.laneProfiles[laneID] ?? []
        if lane.editCount > 0, let top = shares.first {
            var text = GrowthSeries.name(of: top.sourceID, sources: sources)
            if shares.count > 1 { text += " +\(shares.count - 1)" }
            text += " · " + GrowthText.edits(lane.editCount)
            if lane.delegatedCount > 0 { text += ", \(lane.delegatedCount.formatted()) by subagents" }
            profile = text
        } else {
            lines.append("No edits recorded by an assistant")
        }
        let parent = MapLogText.short(layout.title(of: branch.forkParentID))
        var fork: String = lane.enteredBeforeWindow ? "Began before the window, from \(parent)"
            : "Forked \(MapLogText.day(branch.fork, calendar)) \(MapLogText.clock(branch.fork, calendar)) from \(parent)"
        let life = branch.tip.timeIntervalSince(branch.fork)
        if life >= 600, !lane.enteredBeforeWindow { fork += " · lived \(MapLogText.span(life))" }
        lines.append(fork)
        var landing: String = lane.commitCount == 0 ? "No commits" : lane.commitCount == 1 ? "1 commit" : "\(lane.commitCount) commits"
        if let merge = lane.merge, let target = branch.targetID {
            landing += " · merged \(MapLogText.clock(merge.date, calendar)) into \(MapLogText.short(layout.title(of: target)))"
            let siblings = layout.branches.filter { other in
                guard other.targetID == target, let date = other.lane.merge?.date else { return false }
                return abs(date.timeIntervalSince(merge.date)) <= 3_600
            }.sorted { lhs, rhs in
                let left = lhs.lane.merge?.date ?? .distantPast
                let right = rhs.lane.merge?.date ?? .distantPast
                return left != right ? left < right : lhs.lane.id < rhs.lane.id
            }
            if siblings.count >= 2, let rank = siblings.firstIndex(where: { $0.lane.id == laneID }) {
                landing += ", \(MapLogText.ordinal(rank + 1)) of \(siblings.count)"
            }
        } else if branch.live {
            landing += " · working now"
        } else if lane.isHead {
            landing += " · checked out"
        } else if lane.deleted {
            landing += " · deleted"
        } else {
            landing += " · open"
        }
        lines.append(landing)

        // Below the row's sibling group when it fits there, else above it, kept on screen.
        let rows = layout.rows
        let lineCount = CGFloat(lines.count + (profile == nil ? 0 : 1))
        // Wider in the Map window; up to about 810pt wide 30% is under 244, so the popover keeps 244.
        let roomyWidth: CGFloat = max(244, min(380, layout.width * 0.3))
        let fittedWidth: CGFloat = min(roomyWidth, max(160, layout.editsRight - layout.labelX - 8))
        let size = CGSize(width: max(40, min(fittedWidth, layout.bandRight - 4)), height: 30 + lineCount * 15)
        let rowY = rows[rowIndex].y
        var groupEnd = rowY
        var next = rowIndex + 1
        while next < rows.count, rows[next].y - groupEnd <= 14.5 {
            groupEnd = rows[next].y
            next += 1
        }
        let nextY = next < rows.count ? rows[next].y : CGFloat.infinity
        var y = groupEnd + 11
        if y + size.height > nextY - 8 {
            var groupStart = rowY
            var previous = rowIndex - 1
            while previous >= 0, groupStart - rows[previous].y <= 14.5 {
                groupStart = rows[previous].y
                previous -= 1
            }
            let previousY = previous >= 0 ? rows[previous].y : -CGFloat.infinity
            let above = groupStart - 11 - size.height
            if above >= previousY + 8 { y = above }
        }
        let visibleTop = scroll.offset + 6
        let visibleBottom = scroll.offset + layout.viewport - size.height - 6
        y = min(max(y, visibleTop), max(visibleTop, visibleBottom))
        y = min(max(4, y), max(4, layout.height - size.height - 4))
        var x: CGFloat = max(layout.labelX + 8, min(layout.labelX + 24, layout.editsRight - size.width))
        // Never past the bands' right end, so it clears the minimap and the scroll view never cuts it off.
        x = max(4, min(x, layout.bandRight - size.width))
        return MapLogCardModel(laneID: laneID, title: MapText.title(lane),
                               sourceID: profile == nil ? nil : shares.first?.sourceID,
                               profile: profile, lines: lines, origin: CGPoint(x: x, y: y), size: size)
    }
}

/// Opens the fold a click selected, and folds it again once the selection moves
/// on, wherever the selection changes. Only this empty view observes the hover for it.
private struct MapLogFoldWatch: View {
    @ObservedObject var hover: MapHoverModel
    @Binding var unfolded: Date?

    var body: some View {
        Color.clear
            .onChange(of: Self.foldStart(hover.selected), initial: true) { _, start in
                if unfolded != start { unfolded = start }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private static func foldStart(_ id: MapHitID?) -> Date? {
        if case .fold(let start)? = id { return start }
        return nil
    }
}

/// Theme and profile colors resolved for one look. They are dynamic system
/// colors, and resolving one for every stroke was a quarter of the log's drawing.
private struct MapLogInks {
    let profiles: [String: Color]
    let working: Color
    let needsInput: Color
    let workingText: Color
    let needsInputText: Color

    init(colors: [String: Color], in environment: EnvironmentValues) {
        profiles = colors.mapValues { $0.flattened(in: environment) }
        working = Theme.Palette.working.flattened(in: environment)
        needsInput = Theme.Palette.needsInput.flattened(in: environment)
        workingText = Theme.Palette.workingText.flattened(in: environment)
        needsInputText = Theme.Palette.needsInputText.flattened(in: environment)
    }

    func profile(_ sourceID: String?) -> Color { sourceID.flatMap { profiles[$0] } ?? Color.gray }

    /// A live state's fill, as `StatusGlyph.Kind.color` gives it.
    func color(_ kind: StatusGlyph.Kind) -> Color {
        switch kind {
        case .needsInput: return needsInput
        case .working: return working
        default: return kind.color
        }
    }

    /// A live state's wording, as `StatusGlyph.Kind.textColor` gives it.
    func text(_ kind: StatusGlyph.Kind) -> Color {
        switch kind {
        case .needsInput: return needsInputText
        case .working: return workingText
        default: return kind.textColor
        }
    }
}

/// The inks for the current look. Every static layer of a layout, its overlays
/// and its minimap share them, so a look resolves its colors once.
private final class MapLogInkCache {
    private var key: MapLogStaticKey?
    private var cached: MapLogInks?

    func inks(for key: MapLogStaticKey, colors: [String: Color], in environment: EnvironmentValues) -> MapLogInks {
        if let cached, self.key == key { return cached }
        let inks = MapLogInks(colors: colors, in: environment)
        self.key = key
        cached = inks
        return inks
    }
}

/// The last emphasis a layout built. After a hover every tile, the list
/// overlay and the card ask for the same one, so it is built once.
private final class MapLogEmphasisMemo {
    var id: MapHitID?
    var focusSourceID: String?
    var value: MapLogEmphasis?
}

// MARK: - Scroll tracking

/// The vertical scroll offset, published apart from the view so a scroll
/// redraws only what shows it, never the graph.
private final class MapLogScroll: ObservableObject {
    @Published private(set) var offset: CGFloat = 0

    func update(_ value: CGFloat) {
        let rounded = (max(0, value) * 2).rounded() / 2
        if rounded != offset { offset = rounded }
    }
}

private struct MapLogAnchor: Hashable {
    let index: Int
}

/// Invisible stops down the content that the minimap and the Now pill scroll
/// to. Plain values, so a hover's redraw skips them.
private struct MapLogAnchors: View {
    let count: Int
    let step: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                Color.clear
                    .frame(height: step)
                    .id(MapLogAnchor(index: index))
            }
        }
        .allowsHitTesting(false)
    }
}

private struct MapLogOffsetReader: View {
    let scroll: MapLogScroll

    var body: some View {
        GeometryReader { proxy in
            let offset = -proxy.frame(in: NamedCoordinateSpace.named(MapLogView.space)).minY
            Color.clear
                .onChange(of: offset, initial: true) { _, value in scroll.update(value) }
        }
    }
}

/// The sticky header: the day at the top of the view, the lane count and the list's column titles.
private struct MapLogHeader: View {
    let layout: MapLogLayout
    @ObservedObject var scroll: MapLogScroll

    var body: some View {
        let day = layout.dayTitle(atY: scroll.offset + 4)
        Canvas { graphics, size in
            MapLogPainter.drawHeader(layout, day: day, size: size, in: &graphics)
        }
        .allowsHitTesting(false)
    }
}

/// The minimap's box over the part of the window on screen.
private struct MapLogViewport: View {
    @ObservedObject var scroll: MapLogScroll
    let scale: CGFloat
    let viewport: CGFloat
    let height: CGFloat

    var body: some View {
        let boxHeight = min(height, max(8, viewport * scale))
        let y = min(max(0, scroll.offset * scale), max(0, height - boxHeight))
        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .overlay {
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.4), lineWidth: 0.8)
            }
            .frame(width: MapLogLayout.minimapWidth + 3, height: boxHeight)
            .offset(y: y)
            .allowsHitTesting(false)
    }
}

/// "Now ↑" once Now has scrolled out of sight.
private struct MapLogNowPill: View {
    @ObservedObject var scroll: MapLogScroll
    let action: () -> Void

    var body: some View {
        if scroll.offset > 48 {
            Button(action: action) {
                HStack(spacing: 3) {
                    Text("Now")
                        .font(Theme.Typeface.micro.weight(.semibold))
                    Image(systemName: "arrow.up")
                        .font(.system(size: 8, weight: .bold))
                }
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(Theme.Palette.raised, in: Capsule())
                .overlay { Capsule().strokeBorder(Theme.Palette.hairline, lineWidth: 1) }
                .shadow(color: Color.black.opacity(0.12), radius: 4, y: 1)
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Scroll back to now")
            .padding(.top, 6)
        }
    }
}

/// A soft bottom edge while the log scrolls, so cut-off rows read as more below.
private struct MapLogFade: View {
    let active: Bool

    var body: some View {
        if active {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [Color.black, Color.black.opacity(0)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 16)
            }
        } else {
            Color.black
        }
    }
}

// MARK: - Hover card

private struct MapLogCardModel {
    /// The branch it describes, which names the card: another branch's card crossfades in.
    let laneID: String
    let title: String
    let sourceID: String?
    let profile: String?
    let lines: [String]
    let origin: CGPoint
    let size: CGSize
}

private struct MapLogCard: View {
    let model: MapLogCardModel
    let color: Color?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        VStack(alignment: .leading, spacing: 3) {
            Text(model.title)
                .font(Theme.Typeface.caption.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if let profile = model.profile {
                HStack(spacing: 5) {
                    Circle().fill(color ?? Color.secondary).frame(width: 6, height: 6)
                    Text(profile)
                        .font(Theme.Typeface.note)
                        .foregroundStyle(Color.primary.opacity(0.78))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            ForEach(model.lines.indices, id: \.self) { index in
                Text(model.lines[index])
                    .font(Theme.Typeface.note)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: model.size.width, height: model.size.height, alignment: .topLeading)
        .background {
            ZStack {
                shape.fill(Theme.Palette.canvas)
                shape.fill(Theme.Palette.raised.opacity(0.7))
            }
        }
        .overlay { shape.strokeBorder(Theme.Palette.hairline, lineWidth: 1) }
        .shadow(color: Color.black.opacity(0.16), radius: 7, y: 3)
    }
}

// MARK: - Layout

/// One layout per map, size and unfolded stretch. A reference, so a hover's redraw
/// reuses it; `generation` changes with each new layout and keys the static drawing.
private final class MapLogCache {
    private struct Key: Equatable {
        let width: CGFloat
        let viewport: CGFloat
        let unfolded: Date?
        let calendar: ActivityCalendar
        let sources: [AgentSource]
        let map: ProjectMap
    }

    private var key: Key?
    private var cached: MapLogLayout?
    private(set) var generation = 0

    func layout(map: ProjectMap, sources: [AgentSource], calendar: ActivityCalendar, width: CGFloat,
                viewport: CGFloat, unfolded: Date?) -> MapLogLayout {
        let next = Key(width: width, viewport: viewport, unfolded: unfolded, calendar: calendar, sources: sources, map: map)
        if let cached, key == next { return cached }
        let layout = MapLogLayout(map: map, sources: sources, calendar: calendar, width: width, viewport: viewport,
                                  unfolded: unfolded)
        key = next
        cached = layout
        generation += 1
        return layout
    }
}

/// Every position the log draws, from one sweep down the window, newest first.
///
/// Time runs down at a fixed rate per active hour, but each event that needs
/// room (a branch's tip row, a session row, a fork, a day change) keeps a
/// minimum gap from the one above it, and every idle stretch folds into one
/// thin band. Branches then take the lowest free column right of the branch
/// they forked from, so columns are reused once a branch has landed.
private struct MapLogLayout {
    static let headerHeight: CGFloat = 22
    static let top: CGFloat = 12
    static let rowGap: CGFloat = 13
    static let foldHeight: CGFloat = 13
    static let timeRight: CGFloat = 41
    static let graphLeft: CGFloat = 54
    static let minimapWidth: CGFloat = 9
    static let tileHeight: CGFloat = 480
    static let indentStep: CGFloat = 11
    /// The widest the log lays out. A wider Map window centers it, so the counts stay near the names.
    static let maxContentWidth: CGFloat = 920
    /// Wider than the popover, the minimap's gutter stays reserved even while nothing
    /// scrolls, so a height drag that starts or stops the scrolling never moves the counts.
    static let gutterReserveWidth: CGFloat = 600

    struct Branch {
        let lane: ProjectMap.Lane
        /// The lane it merged into, else the one it was created from, else the trunk.
        let parentID: String
        let targetID: String?
        let fork: Date
        let tip: Date
        /// Commits but no assistant edits.
        let quiet: Bool
        let live: Bool
        /// Open at now: live, or checked out and unmerged.
        let atNow: Bool
        /// The profile that made most of its edits.
        let tint: String?
        /// The nearest ancestor that already existed when it forked.
        var forkParentID: String
        var column = 0
        var yTop: CGFloat = 0
        var yBot: CGFloat = 0
        /// The top of its line: the tip, raised to the forks of its children.
        var yExt: CGFloat = 0
        /// A short quiet branch drawn as a ring on its target, with no column.
        var bead = false
        var depth = 1
    }

    struct Run {
        let id: MapHitID
        let sessionKey: String
        let sourceID: String
        let laneID: String
        /// The column it sits on.
        let column: Int
        let direct: Int
        let delegated: Int
        let rect: CGRect
    }

    struct Dot {
        let laneID: String
        let column: Int
        let shas: [String]
        let rect: CGRect
        let quiet: Bool
    }

    struct Ring {
        let id: MapHitID
        let sha: String
        let laneID: String
        /// The column it sits on: its target's.
        let column: Int
        let center: CGPoint
        let radius: CGFloat
        let strong: Bool
        /// A pull request landed on the trunk.
        let centerDot: Bool
    }

    struct Fold {
        let start: Date
        let end: Date
        let y: CGFloat
        /// What its clicks report: the start of the Map axis's gap that overlaps
        /// it most, which names it to the inspector, else a date of its own.
        let id: Date
        let title: String
        /// The day below, when the day changes inside the fold.
        let dayTitle: String?
    }

    struct Unfolded {
        let top: CGFloat
        let bottom: CGFloat
        let title: String
        /// The selection that opened it, so a click folds it again.
        let id: Date
    }

    struct DayRule {
        let y: CGFloat
        let title: String
    }

    struct Tick {
        let y: CGFloat
        let text: String
    }

    struct Glyph: Identifiable {
        /// The lane the live session works on.
        let id: String
        let hit: MapHitID
        let kind: StatusGlyph.Kind
        let point: CGPoint
    }

    struct Tile: Identifiable {
        let id: Int
        let minY: CGFloat
        let height: CGFloat
    }

    struct Share {
        let sourceID: String
        let edits: Int
    }

    struct Chip {
        let sourceID: String
        let hatched: Bool
    }

    struct Row {
        enum Style: Equatable {
            case trunk
            case branch
            case live
            case quiet
            case session
            /// A pull request whose branch Git no longer names.
            case unnamed
        }

        enum Meta {
            case empty
            case text(String)
            case chip(String)
            case status(String, StatusGlyph.Kind)
        }

        let id: MapHitID
        let laneID: String?
        let sessionKey: String?
        let sourceID: String?
        let y: CGFloat
        let x: CGFloat
        let indent: Int
        let name: String
        /// A prefix the row shares with its siblings, drawn muted.
        var mutedPrefix: String
        let style: Style
        let meta: Meta
        let commits: Int
        let edits: Int
        let chips: [Chip]
        /// The gutter time, nil where it repeats the row above.
        let time: String?
        let isNow: Bool
        let liveKind: StatusGlyph.Kind?
    }

    struct TimeAnchor {
        let t: Date
        let y: CGFloat
    }

    let map: ProjectMap
    let calendar: ActivityCalendar
    let width: CGFloat
    let viewport: CGFloat
    let contentHeight: CGFloat
    let nowY: CGFloat
    let trunkID: String
    let pitch: CGFloat
    let columnCount: Int
    let labelX: CGFloat
    let commitsRight: CGFloat
    let editsRight: CGFloat
    let scrolls: Bool
    let hatches: Bool
    /// The trunk is solid above this y and dashed below: work before Git.
    let trunkSolidBottom: CGFloat
    let branches: [Branch]
    let branchIndex: [String: Int]
    let laneProfiles: [String: [Share]]
    let runs: [Run]
    let dots: [Dot]
    let rings: [Ring]
    let rows: [Row]
    let folds: [Fold]
    let unfolded: Unfolded?
    let dayRules: [DayRule]
    let ticks: [Tick]
    let glyphs: [Glyph]
    let tiles: [Tile]
    let anchorCount: Int
    let anchorStep: CGFloat
    /// Where each commit is drawn: its ring, else its dot, once per mark.
    let markCenters: [CGPoint]
    /// A commit's index into `markCenters`; the commits of one dot share it.
    let markIndex: [String: Int]
    private let anchors: [TimeAnchor]
    /// Each tile's rows, by index. Rows run down the window, so a tile holds one stretch of them.
    let tileRows: [Range<Int>]
    /// The branch lines on each column, by index into `branches`, for hit tests.
    let columnBranches: [[Int]]
    let runBuckets: MapLogBuckets
    let dotBuckets: MapLogBuckets
    let ringBuckets: MapLogBuckets
    /// The emphasis last asked for, which every tile and overlay shares after a hover.
    private let memo = MapLogEmphasisMemo()
    /// Colors resolved for the current look, which every layer drawn from this layout shares.
    private let inkCache = MapLogInkCache()

    var height: CGFloat { max(contentHeight, viewport) }
    var bandRight: CGFloat { scrolls || width > Self.gutterReserveWidth ? editsRight + 6 : width - 7 }
    var liveKind: StatusGlyph.Kind? {
        glyphs.first(where: { $0.kind == .needsInput })?.kind ?? glyphs.first?.kind
    }

    init(map: ProjectMap, sources: [AgentSource], calendar: ActivityCalendar, width: CGFloat, viewport: CGFloat,
         unfolded unfoldedStart: Date?) {
        let now = map.now
        let trunkID = map.trunkID
        let laneByID = Dictionary(map.lanes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let axisStart = map.axis.segments.isEmpty ? now.addingTimeInterval(-86_400) : map.axis.start
        let windowStart = min(axisStart, map.lanes.filter { $0.kind != .trunk }.map(\.start).min() ?? axisStart, now)
        let nowY = Self.top

        // Profiles per lane, most edits first.
        var laneEdits: [String: [String: Int]] = [:]
        for span in map.spans where span.editCount > 0 {
            laneEdits[span.laneID, default: [:]][span.sourceID, default: 0] += span.editCount
        }
        let laneProfiles: [String: [Share]] = laneEdits.mapValues { counts in
            counts.map { Share(sourceID: $0.key, edits: $0.value) }
                .sorted { $0.edits != $1.edits ? $0.edits > $1.edits : $0.sourceID < $1.sourceID }
        }

        // Runs: one session's work on one branch, joined where it paused briefly.
        struct PendingRun {
            var sessionKey: String
            var sourceID: String
            var laneID: String
            var start: Date
            var end: Date
            var direct: Int
            var delegated: Int
            var firstIndex: Int
            var liveIndex: Int?
        }
        var pending: [PendingRun] = []
        let bySessionLane = Dictionary(grouping: map.spans, by: { $0.sessionKey + "\u{0}" + $0.laneID })
        for key in bySessionLane.keys.sorted() {
            guard let spans = bySessionLane[key] else { continue }
            var current: PendingRun?
            for span in spans.sorted(by: { ($0.start, $0.index) < ($1.start, $1.index) }) {
                if var run = current, span.start.timeIntervalSince(run.end) <= map.range.runBreak {
                    run.end = max(run.end, span.end)
                    run.direct += span.direct.count
                    run.delegated += span.delegated.count
                    if span.live != nil { run.liveIndex = span.index }
                    current = run
                } else {
                    if let run = current { pending.append(run) }
                    current = PendingRun(sessionKey: span.sessionKey, sourceID: span.sourceID, laneID: span.laneID,
                                         start: span.start, end: span.end, direct: span.direct.count,
                                         delegated: span.delegated.count, firstIndex: span.index,
                                         liveIndex: span.live != nil ? span.index : nil)
                }
            }
            if let run = current { pending.append(run) }
        }

        // Branches, newest tip first.
        var branches: [Branch] = []
        for lane in map.lanes where lane.kind != .trunk {
            let atNow = lane.merge == nil && (lane.isLive || lane.isHead)
            let fork = lane.enteredBeforeWindow ? windowStart : min(lane.start, lane.forkedAt ?? lane.start)
            let tip = max(fork, lane.merge?.date ?? (atNow ? now : lane.end))
            let parent = lane.parentID.flatMap { id -> String? in
                laneByID[id] == nil || id == lane.id ? nil : id
            } ?? trunkID
            let target = lane.merge.map { merge -> String in
                laneByID[merge.intoLaneID] == nil || merge.intoLaneID == lane.id ? trunkID : merge.intoLaneID
            }
            branches.append(Branch(lane: lane, parentID: parent, targetID: target, fork: fork, tip: tip,
                                   quiet: lane.editCount == 0, live: lane.isLive && lane.merge == nil, atNow: atNow,
                                   tint: laneProfiles[lane.id]?.first?.sourceID, forkParentID: parent))
        }
        branches.sort { $0.tip != $1.tip ? $0.tip > $1.tip : $0.lane.id < $1.lane.id }
        var branchIndex: [String: Int] = [:]
        for (position, branch) in branches.enumerated() { branchIndex[branch.lane.id] = position }
        var children: [String: Int] = [:]
        for branch in branches where branch.parentID != trunkID { children[branch.parentID, default: 0] += 1 }

        // Trunk merges with a list row of their own: quiet branches and pull requests Git has no branch for.
        let mergedSHAs = Set(map.lanes.compactMap { $0.merge?.sha })
        let trunkMarkers = map.markers.filter { $0.laneID == trunkID }
        let beadRows = trunkMarkers.filter { marker in
            marker.isBead && marker.mergedLaneID == nil && !mergedSHAs.contains(marker.sha)
                && (marker.quietBranch != nil || marker.pullRequest != nil)
        }

        // Sessions with a row at their first edit; the live ones speak on their branch's row.
        struct Session {
            let key: String
            let sourceID: String
            let first: Date
            let edits: Int
            let delegated: Int
            let lanes: Int
            let index: Int
        }
        var sessions: [Session] = []
        for (key, spans) in Dictionary(grouping: map.spans, by: \.sessionKey) {
            guard !spans.contains(where: { $0.live != nil }) else { continue }
            let edits = spans.reduce(0) { $0 + $1.editCount }
            guard edits >= 3, let firstSpan = spans.min(by: { ($0.start, $0.index) < ($1.start, $1.index) }) else { continue }
            sessions.append(Session(key: key, sourceID: firstSpan.sourceID,
                                    first: spans.compactMap { $0.edits.first }.min() ?? firstSpan.start, edits: edits,
                                    delegated: spans.reduce(0) { $0 + $1.delegated.count },
                                    lanes: Set(spans.map(\.laneID)).count, index: firstSpan.index))
        }
        sessions.sort { $0.first != $1.first ? $0.first > $1.first : $0.key < $1.key }

        // Active time: runs, forks of edited branches, tips and now. Plain
        // commits stay out, so a quiet commit never breaks up a fold.
        let pad = map.range.pad
        var cover: [(start: Date, end: Date)] = pending.map {
            (start: $0.start.addingTimeInterval(-pad), end: $0.end.addingTimeInterval(pad))
        }
        for branch in branches {
            if !branch.quiet {
                cover.append((start: branch.fork.addingTimeInterval(-pad), end: branch.fork.addingTimeInterval(pad)))
            }
            cover.append((start: branch.tip.addingTimeInterval(-pad), end: branch.tip.addingTimeInterval(pad)))
        }
        for marker in beadRows {
            cover.append((start: marker.date.addingTimeInterval(-pad), end: marker.date.addingTimeInterval(pad)))
        }
        cover.append((start: now.addingTimeInterval(-pad), end: now.addingTimeInterval(5)))
        cover.sort { $0.start < $1.start }
        var covered: [(start: Date, end: Date)] = []
        for interval in cover {
            if let last = covered.last, interval.start <= last.end {
                covered[covered.count - 1].end = max(last.end, interval.end)
            } else {
                covered.append(interval)
            }
        }
        var idle: [(start: Date, end: Date)] = []
        var cursor = windowStart
        for interval in covered {
            if interval.end <= cursor { continue }
            if interval.start > cursor { idle.append((start: cursor, end: interval.start)) }
            cursor = max(cursor, interval.end)
        }
        idle = idle.filter { $0.end.timeIntervalSince($0.start) >= map.range.minimumGap }
        // Names come from every idle stretch, so they hold whichever fold is open.
        let names = Self.foldNames(idle, gaps: map.axis.gaps)
        var stretches: [(start: Date, end: Date, name: Date)] = []
        stretches.reserveCapacity(idle.count)
        for (stretch, name) in zip(idle, names) {
            stretches.append((start: stretch.start, end: stretch.end, name: name))
        }
        // The clicked fold opens instead of folding: the one its click named,
        // else the one around that moment.
        var slowStretch: (start: Date, end: Date)?
        if let unfoldedStart {
            let named = stretches.firstIndex(where: { $0.name == unfoldedStart })
            let around = stretches.firstIndex(where: { $0.start <= unfoldedStart && unfoldedStart < $0.end })
            if let position = named ?? around {
                let opened = stretches.remove(at: position)
                slowStretch = (start: opened.start, end: opened.end)
            }
        }
        let slow = slowStretch
        // Oldest first and apart, so a binary search finds the one around a moment.
        let remaining = stretches
        let gaps = remaining.sorted { $0.end > $1.end }
        /// Inside a stretch that stays folded, where the fold names the day itself.
        func isFolded(_ date: Date) -> Bool {
            var low = 0
            var high = remaining.count
            while low < high {
                let middle = (low + high) / 2
                if remaining[middle].start < date { low = middle + 1 } else { high = middle }
            }
            guard low > 0 else { return false }
            return date < remaining[low - 1].end
        }

        // Events, newest first.
        enum EventKind {
            case now
            case tip(Int)
            case bead(Int)
            case day(Int)
            case session(Int)
            case mark
            case fork(Int)
        }
        struct Event {
            let t: Date
            let gap: CGFloat
            let order: Int
            let key: String
            let kind: EventKind
        }
        var events: [Event] = [Event(t: now.addingTimeInterval(2), gap: 0, order: 0, key: "", kind: .now)]
        for (position, branch) in branches.enumerated() {
            events.append(Event(t: branch.tip, gap: Self.rowGap, order: 2, key: branch.lane.id, kind: .tip(position)))
            events.append(Event(t: branch.fork, gap: 6, order: 7, key: branch.lane.id, kind: .fork(position)))
        }
        for (position, marker) in beadRows.enumerated() {
            events.append(Event(t: marker.date, gap: Self.rowGap, order: 2, key: marker.sha, kind: .bead(position)))
        }
        for marker in map.markers {
            events.append(Event(t: marker.date, gap: 0, order: 5, key: marker.sha, kind: .mark))
        }
        for run in pending {
            events.append(Event(t: run.start, gap: 0, order: 6, key: run.sessionKey, kind: .mark))
            events.append(Event(t: run.end, gap: 0, order: 6, key: run.sessionKey, kind: .mark))
        }
        for (position, session) in sessions.enumerated() {
            events.append(Event(t: session.first.addingTimeInterval(1), gap: Self.rowGap, order: 4, key: session.key,
                                kind: .session(position)))
        }
        if let slow {
            events.append(Event(t: slow.end, gap: 0, order: 6, key: "", kind: .mark))
            events.append(Event(t: slow.start, gap: 0, order: 6, key: "", kind: .mark))
        }
        var dayStarts: [Date] = []
        // At most 400 days back from now; older day changes keep no rule.
        var dayCursor = calendar.day(of: max(windowStart, now.addingTimeInterval(-400 * 86_400))).adding(days: 1)
        while dayStarts.count < 400 {
            let start = calendar.start(of: dayCursor)
            guard start < now else { break }
            dayStarts.append(start)
            dayCursor = dayCursor.adding(days: 1)
        }
        // Every day change gets a rule, unless it falls inside a fold, which names the day itself.
        for (position, start) in dayStarts.enumerated() where start > windowStart && !isFolded(start) {
            events.append(Event(t: start, gap: 15, order: 3, key: "", kind: .day(position)))
        }
        events.sort { lhs, rhs in
            if lhs.t != rhs.t { return lhs.t > rhs.t }
            if lhs.order != rhs.order { return lhs.order < rhs.order }
            return lhs.key < rhs.key
        }

        // The sweep: time runs down at `rate` points per hour; each event
        // keeps its gap from the one above; idle stretches fold into bands.
        struct Sweep {
            var ys: [CGFloat]
            var folds: [(start: Date, end: Date, y: CGFloat, name: Date)]
            var height: CGFloat
        }
        func sweep(_ rate: CGFloat) -> Sweep {
            let perSecond: CGFloat = rate / 3_600
            var slowPerSecond = perSecond
            if let slow {
                let seconds: TimeInterval = max(60, slow.end.timeIntervalSince(slow.start))
                slowPerSecond = min(perSecond, 300 / CGFloat(seconds))
            }
            func advance(_ from: Date, _ to: Date) -> CGFloat {
                let total = max(0, from.timeIntervalSince(to))
                guard let slow else { return CGFloat(total) * perSecond }
                let overlap = max(0, min(from, slow.end).timeIntervalSince(max(to, slow.start)))
                return CGFloat(total - overlap) * perSecond + CGFloat(overlap) * slowPerSecond
            }
            var ys = Array(repeating: Self.top, count: events.count)
            var folds: [(start: Date, end: Date, y: CGFloat, name: Date)] = []
            var gapIndex = 0
            var currentT = events.first?.t ?? now
            var currentY = Self.top
            var lastY = Self.top
            for position in events.indices.dropFirst() {
                let event = events[position]
                while gapIndex < gaps.count, gaps[gapIndex].end > event.t {
                    let gap = gaps[gapIndex]
                    if gap.end <= currentT.addingTimeInterval(1) {
                        let y = currentY + advance(currentT, gap.end) + 3
                        folds.append((start: gap.start, end: gap.end, y: y, name: gap.name))
                        currentY = y + Self.foldHeight + 4
                        currentT = gap.start
                    }
                    gapIndex += 1
                }
                if let fold = folds.last, fold.start < event.t, event.t < fold.end {
                    let share = CGFloat(fold.end.timeIntervalSince(event.t) / fold.end.timeIntervalSince(fold.start))
                    ys[position] = fold.y + 2 + (Self.foldHeight - 4) * share
                    continue
                }
                let y = max(currentY + advance(currentT, event.t), lastY + event.gap)
                ys[position] = y
                currentY = y
                currentT = event.t
                lastY = y
            }
            return Sweep(ys: ys, folds: folds, height: (ys.max() ?? Self.top) + 18)
        }
        // A short window stretches to fill the card, up to six times the base rate.
        let baseRate = Self.baseRate(map.range)
        var rate = baseRate
        var result = sweep(rate)
        var pass = 0
        while pass < 3, result.height < viewport - 8 {
            let next = min(baseRate * 6, rate * (viewport - 8) / max(result.height, 1))
            guard next > rate * 1.02 else { break }
            rate = next
            result = sweep(rate)
            pass += 1
        }

        var tipY = Array(repeating: nowY, count: branches.count)
        var forkY = Array(repeating: nowY, count: branches.count)
        var beadY = Array(repeating: nowY, count: beadRows.count)
        var sessionY = Array(repeating: nowY, count: sessions.count)
        var dayY: [Int: CGFloat] = [:]
        for (position, event) in events.enumerated() {
            let y = result.ys[position]
            switch event.kind {
            case .tip(let index): tipY[index] = y
            case .fork(let index): forkY[index] = y
            case .bead(let index): beadY[index] = y
            case .session(let index): sessionY[index] = y
            case .day(let index): dayY[index] = y
            case .now, .mark: break
            }
        }
        var anchors = events.indices.map { TimeAnchor(t: events[$0].t, y: result.ys[$0]) }
        for fold in result.folds {
            anchors.append(TimeAnchor(t: fold.end, y: fold.y + 1))
            anchors.append(TimeAnchor(t: fold.start, y: fold.y + Self.foldHeight - 1))
        }
        anchors.sort { $0.t != $1.t ? $0.t > $1.t : $0.y < $1.y }
        let timeline = anchors
        func yAt(_ date: Date) -> CGFloat { Self.position(of: date, in: timeline) }
        let contentHeight = result.height

        // Columns: a branch's interval runs from its tip down to its fork.
        for position in branches.indices {
            branches[position].yTop = tipY[position]
            branches[position].yBot = max(forkY[position], tipY[position] + 10)
        }
        // It forks from the nearest ancestor that already existed then.
        for position in branches.indices {
            var parent = branches[position].parentID
            var steps = 0
            while parent != trunkID, let index = branchIndex[parent], branches[index].yBot < branches[position].yBot - 1,
                  steps < 8 {
                parent = branches[index].parentID
                steps += 1
            }
            branches[position].forkParentID = parent == branches[position].lane.id ? trunkID : parent
        }
        for position in branches.indices {
            branches[position].yExt = branches[position].live ? nowY : branches[position].yTop
        }
        for position in branches.indices {
            if let parent = branchIndex[branches[position].forkParentID] {
                branches[parent].yExt = min(branches[parent].yExt, branches[position].yBot - 9)
            }
            if let target = branches[position].targetID, let index = branchIndex[target] {
                branches[index].yExt = min(branches[index].yExt, branches[position].yTop)
            }
        }
        var hasChildren = Set<String>()
        for branch in branches {
            hasChildren.insert(branch.parentID)
            hasChildren.insert(branch.forkParentID)
            if let target = branch.targetID { hasChildren.insert(target) }
        }
        for position in branches.indices {
            let branch = branches[position]
            let short = branch.yBot - branch.yTop < 24 || branch.tip.timeIntervalSince(branch.fork) < 30 * 60
            branches[position].bead = branch.quiet && branch.targetID != nil && !branch.atNow
                && !hasChildren.contains(branch.lane.id) && short
        }
        // Oldest fork first. Forks close together off one parent take columns
        // by merge order, earliest nearest, so the merge fan nests.
        let order = branches.indices.filter { !branches[$0].bead }.sorted { lhs, rhs in
            branches[lhs].yBot != branches[rhs].yBot ? branches[lhs].yBot > branches[rhs].yBot
                : branches[lhs].lane.id < branches[rhs].lane.id
        }
        var sequence: [Int] = []
        var groupStart = 0
        while groupStart < order.count {
            var groupEnd = groupStart
            while groupEnd + 1 < order.count,
                  branches[order[groupStart]].yBot - branches[order[groupEnd + 1]].yBot < 30,
                  branches[order[groupEnd + 1]].forkParentID == branches[order[groupStart]].forkParentID {
                groupEnd += 1
            }
            sequence += order[groupStart...groupEnd].sorted { lhs, rhs in
                branches[lhs].yTop != branches[rhs].yTop ? branches[lhs].yTop > branches[rhs].yTop
                    : branches[lhs].lane.id < branches[rhs].lane.id
            }
            groupStart = groupEnd + 1
        }
        var columnTop: [Int: CGFloat] = [:]
        var columnCount = 1
        for position in sequence {
            let parentColumn = branchIndex[branches[position].forkParentID].map { branches[$0].column } ?? 0
            var candidate = parentColumn + 1
            while let top = columnTop[candidate], top - branches[position].yBot < 12 { candidate += 1 }
            branches[position].column = candidate
            columnTop[candidate] = branches[position].yExt
            columnCount = max(columnCount, candidate + 1)
        }
        for position in branches.indices where branches[position].bead {
            var targetColumn = 0
            if let target = branches[position].targetID, let index = branchIndex[target] {
                targetColumn = branches[index].column
            }
            branches[position].column = targetColumn
        }
        // List depth: merge targets (or creation parents) up to the trunk.
        for position in branches.indices {
            var depth = 1
            var parent = branches[position].parentID
            while parent != trunkID, let index = branchIndex[parent], depth < 5 {
                depth += 1
                parent = branches[index].parentID
            }
            branches[position].depth = depth
        }

        let pitch = Self.columnPitch(columns: columnCount, width: width)
        let graphRight: CGFloat = Self.graphLeft + CGFloat(columnCount - 1) * pitch + 17
        // The list never starts past half the width, however many columns are open.
        let labelX: CGFloat = min(graphRight, max(Self.graphLeft + 17, width * 0.5))
        let scrolls = contentHeight > viewport + 0.5
        let editsRight = scrolls || width > Self.gutterReserveWidth ? width - Self.minimapWidth - 7 - 11 : width - 10
        let commitsRight = editsRight - 46
        let finalBranches = branches
        func columnX(_ column: Int) -> CGFloat { Self.graphLeft + CGFloat(column) * pitch }
        func column(of laneID: String) -> Int {
            laneID == trunkID ? 0 : branchIndex[laneID].map { finalBranches[$0].column } ?? 0
        }

        // Run capsules, side by side where sessions overlap on one branch.
        var runs: [Run] = []
        let runsByLane = Dictionary(grouping: pending, by: \.laneID)
        for laneID in runsByLane.keys.sorted() {
            guard let laneRuns = runsByLane[laneID] else { continue }
            let laneColumn = column(of: laneID)
            let x = columnX(laneColumn)
            var placed: [(run: PendingRun, top: CGFloat, bottom: CGFloat, slot: Int)] = []
            var slotBottoms: [CGFloat] = []
            for run in laneRuns.sorted(by: { $0.start != $1.start ? $0.start > $1.start : $0.sessionKey < $1.sessionKey }) {
                var top = yAt(run.end)
                var bottom = yAt(run.start)
                if bottom - top < 3.4 {
                    let middle = (top + bottom) / 2
                    top = middle - 1.7
                    bottom = middle + 1.7
                }
                let slot = slotBottoms.firstIndex(where: { $0 + 1 <= top }) ?? slotBottoms.count
                if slot == slotBottoms.count {
                    slotBottoms.append(bottom)
                } else {
                    slotBottoms[slot] = max(slotBottoms[slot], bottom)
                }
                placed.append((run: run, top: top, bottom: bottom, slot: min(slot, 2)))
            }
            let slots = min(3, (placed.map(\.slot).max() ?? 0) + 1)
            // Under 6pt between columns, capsules narrow with the pitch so they keep to their column.
            let squeeze: CGFloat = min(1, pitch / 6)
            let barWidth: CGFloat = (slots == 1 ? 5 : 3.3) * squeeze
            for entry in placed {
                let slotOffset: CGFloat = CGFloat(entry.slot) - CGFloat(slots - 1) / 2
                let offset: CGFloat = slots == 1 ? 0 : slotOffset * 3.6 * squeeze
                runs.append(Run(id: .run(entry.run.sessionKey, entry.run.liveIndex ?? entry.run.firstIndex),
                                sessionKey: entry.run.sessionKey, sourceID: entry.run.sourceID, laneID: laneID,
                                column: laneColumn, direct: entry.run.direct, delegated: entry.run.delegated,
                                rect: CGRect(x: x + offset - barWidth / 2, y: entry.top, width: barWidth,
                                             height: entry.bottom - entry.top)))
            }
        }

        // Commit dots; dots closer than 4pt share a capsule. Merges are rings.
        var dots: [Dot] = []
        let markersByLane = Dictionary(grouping: map.markers, by: \.laneID)
        for laneID in markersByLane.keys.sorted() {
            guard let markers = markersByLane[laneID] else { continue }
            let isTrunk = laneID == trunkID
            var quiet = false
            if !isTrunk {
                guard let index = branchIndex[laneID], !finalBranches[index].bead else { continue }
                quiet = finalBranches[index].quiet
            }
            let points = markers.filter { !(isTrunk && $0.isBead) && !mergedSHAs.contains($0.sha) }
                .map { (sha: $0.sha, y: yAt($0.date)) }
                .sorted { $0.y < $1.y }
            var clusters: [[(sha: String, y: CGFloat)]] = []
            for point in points {
                if let last = clusters.last?.last, point.y - last.y < 4 {
                    clusters[clusters.count - 1].append(point)
                } else {
                    clusters.append([point])
                }
            }
            let laneColumn = column(of: laneID)
            let x = columnX(laneColumn)
            for cluster in clusters {
                guard let first = cluster.first, let last = cluster.last else { continue }
                dots.append(Dot(laneID: laneID, column: laneColumn, shas: cluster.map(\.sha),
                                rect: CGRect(x: x - 1.9, y: first.y - 1.9, width: 3.8, height: last.y - first.y + 3.8),
                                quiet: quiet))
            }
        }

        var rings: [Ring] = []
        let markerSHAs = Set(map.markers.map(\.sha))
        for branch in finalBranches {
            guard let target = branch.targetID, let merge = branch.lane.merge else { continue }
            let targetColumn = column(of: target)
            rings.append(Ring(id: markerSHAs.contains(merge.sha) ? .commit(merge.sha) : .lane(branch.lane.id),
                              sha: merge.sha, laneID: branch.lane.id, column: targetColumn,
                              center: CGPoint(x: columnX(targetColumn), y: branch.yTop),
                              radius: branch.bead ? 3.1 : 3.4, strong: !branch.quiet,
                              centerDot: target == trunkID && merge.pullRequest != nil))
        }
        for (position, marker) in beadRows.enumerated() {
            rings.append(Ring(id: .commit(marker.sha), sha: marker.sha, laneID: trunkID, column: 0,
                              center: CGPoint(x: Self.graphLeft, y: beadY[position]), radius: 3.1, strong: false,
                              centerDot: marker.pullRequest != nil))
        }
        let rowSHAs = Set(beadRows.map(\.sha))
        for marker in trunkMarkers where marker.isBead && !mergedSHAs.contains(marker.sha) && !rowSHAs.contains(marker.sha) {
            rings.append(Ring(id: .commit(marker.sha), sha: marker.sha, laneID: trunkID, column: 0,
                              center: CGPoint(x: Self.graphLeft, y: yAt(marker.date)), radius: 2.8, strong: false,
                              centerDot: marker.pullRequest != nil))
        }
        // One center per mark, so highlighting a cluster rings its capsule once.
        var markCenters: [CGPoint] = []
        var markIndex: [String: Int] = [:]
        for ring in rings where markIndex[ring.sha] == nil {
            markIndex[ring.sha] = markCenters.count
            markCenters.append(ring.center)
        }
        for dot in dots {
            let unseen = dot.shas.filter { markIndex[$0] == nil }
            guard !unseen.isEmpty else { continue }
            let index = markCenters.count
            markCenters.append(CGPoint(x: dot.rect.midX, y: dot.rect.midY))
            for sha in unseen { markIndex[sha] = index }
        }

        // Live heads at now, on their branch's column.
        var glyphs: [Glyph] = []
        let liveSpans = map.spans.filter { $0.live != nil }
        for entry in Dictionary(grouping: liveSpans, by: \.laneID).sorted(by: { $0.key < $1.key }) {
            guard let span = entry.value.first(where: { $0.live == LiveStatus.waiting.rawValue }) ?? entry.value.first
            else { continue }
            glyphs.append(Glyph(id: entry.key, hit: .run(span.sessionKey, span.index),
                                kind: span.live == LiveStatus.waiting.rawValue ? .needsInput : .working,
                                point: CGPoint(x: columnX(column(of: entry.key)), y: nowY)))
        }

        // List rows: the trunk at now, each branch at its tip, quiet merges, session starts.
        let totalEdits = map.spans.reduce(0) { $0 + $1.editCount }
        let totalDelegated = map.spans.reduce(0) { $0 + $1.delegated.count }
        let delegatedShare = totalEdits > 0 ? Double(totalDelegated) / Double(totalEdits) : 0
        // When subagents made nearly everything, hatching every mark says nothing.
        let hatches = delegatedShare <= 0.8
        func chips(_ laneID: String, delegated: Int, edits: Int) -> [Chip] {
            (laneProfiles[laneID] ?? []).prefix(3).map { Chip(sourceID: $0.sourceID, hatched: hatches && delegated * 2 > edits) }
        }
        func liveStatus(_ laneID: String) -> (text: String, kind: StatusGlyph.Kind)? {
            let spans = liveSpans.filter { $0.laneID == laneID }
            guard let span = spans.first(where: { $0.live == LiveStatus.waiting.rawValue }) ?? spans.first else { return nil }
            let kind: StatusGlyph.Kind = span.live == LiveStatus.waiting.rawValue ? .needsInput : .working
            let word = kind == .needsInput ? "needs input" : "working"
            return ("\(GrowthSeries.name(of: span.sourceID, sources: sources)) · \(word)", kind)
        }
        func title(_ id: String) -> String { laneByID[id].map(MapText.title) ?? "" }
        func clock(_ date: Date) -> String { MapLogText.clock(date, calendar) }

        enum RowKind {
            case trunk
            case branch(Int)
            case bead(Int)
            case session(Int)
        }
        struct RowSpec {
            let y: CGFloat
            let order: Int
            let kind: RowKind
        }
        var specs = [RowSpec(y: nowY, order: 0, kind: .trunk)]
        for position in finalBranches.indices {
            specs.append(RowSpec(y: finalBranches[position].yTop, order: 1, kind: .branch(position)))
        }
        for position in beadRows.indices { specs.append(RowSpec(y: beadY[position], order: 1, kind: .bead(position))) }
        for position in sessions.indices { specs.append(RowSpec(y: sessionY[position], order: 2, kind: .session(position))) }
        specs.sort { $0.y != $1.y ? $0.y < $1.y : $0.order < $1.order }

        var rows: [Row] = []
        var rowParents: [String?] = []
        var previousLane: String?
        var previousTarget: String?
        var lastTime: String?
        func timeLabel(_ text: String) -> String? {
            defer { lastTime = text }
            return text == lastTime ? nil : text
        }
        for spec in specs {
            switch spec.kind {
            case .trunk:
                let trunk = laneByID[trunkID]
                let name = map.isGitCheckout ? (trunk.map(MapText.title) ?? "main")
                    : (map.projectPath as NSString).lastPathComponent
                var meta = Row.Meta.empty
                var liveKind: StatusGlyph.Kind?
                if let live = liveStatus(trunkID) {
                    meta = .status(live.text, live.kind)
                    liveKind = live.kind
                } else if !hatches {
                    meta = .text("\(Int((delegatedShare * 100).rounded()))% of edits by subagents")
                }
                let available = max(70, commitsRight - 22 - labelX - MapLogMeasure.width(of: meta))
                rows.append(Row(id: .lane(trunkID), laneID: trunkID, sessionKey: nil, sourceID: nil, y: spec.y, x: labelX,
                                indent: 0, name: MapLogMeasure.fitted(name, width: available, weight: .semibold),
                                mutedPrefix: "", style: .trunk, meta: meta, commits: trunk?.commitCount ?? 0,
                                edits: trunk?.editCount ?? 0,
                                chips: chips(trunkID, delegated: trunk?.delegatedCount ?? 0, edits: trunk?.editCount ?? 0),
                                time: timeLabel("Now"), isNow: true, liveKind: liveKind))
                rowParents.append(nil)
            case .branch(let position):
                let branch = finalBranches[position]
                let lane = branch.lane
                let life = branch.tip.timeIntervalSince(branch.fork)
                let lifeText: String? = life >= 600 && !lane.enteredBeforeWindow ? MapLogText.span(life) : nil
                var meta = Row.Meta.empty
                var liveKind: StatusGlyph.Kind?
                if branch.live, let live = liveStatus(lane.id) {
                    meta = .status(live.text, live.kind)
                    liveKind = live.kind
                } else if lane.kind == .folder {
                    meta = .text("worktree · no branch")
                } else if let target = branch.targetID, let merge = lane.merge {
                    if target == trunkID {
                        if let number = merge.pullRequest {
                            meta = .chip("#\(number)")
                        } else {
                            meta = .text(lifeText ?? "merged")
                        }
                    } else if previousLane == target || previousTarget == target {
                        meta = lifeText.map { Row.Meta.text($0) } ?? Row.Meta.empty
                    } else {
                        meta = .text("→ " + MapLogText.short(title(target)))
                    }
                } else if lane.isHead {
                    meta = .text("checked out")
                } else if let count = children[lane.id], count >= 2 {
                    meta = .text("base of \(count) branches")
                } else if lane.deleted {
                    meta = .text("deleted")
                } else if lane.commitCount == 0 {
                    meta = .text("no commits")
                } else {
                    meta = .text("open")
                }
                let indent = min(4, branch.depth - 1)
                let x = labelX + CGFloat(indent) * Self.indentStep
                let style: Row.Style = branch.live ? .live : branch.quiet ? .quiet : .branch
                let available = max(70, commitsRight - 22 - x - MapLogMeasure.width(of: meta))
                rows.append(Row(id: .lane(lane.id), laneID: lane.id, sessionKey: nil, sourceID: nil, y: spec.y, x: x,
                                indent: indent,
                                name: MapLogMeasure.fitted(MapText.title(lane), width: available, weight: .semibold),
                                mutedPrefix: "", style: style, meta: meta, commits: lane.commitCount, edits: lane.editCount,
                                chips: chips(lane.id, delegated: lane.delegatedCount, edits: lane.editCount),
                                time: timeLabel(branch.atNow ? "Now" : clock(branch.tip)), isNow: branch.atNow,
                                liveKind: liveKind))
                rowParents.append(branch.parentID == trunkID ? nil : branch.parentID)
                previousLane = lane.id
                previousTarget = branch.targetID
            case .bead(let position):
                let marker = beadRows[position]
                let meta = marker.pullRequest.map { Row.Meta.chip("#\($0)") } ?? Row.Meta.text("merged")
                let available = max(70, commitsRight - 22 - labelX - MapLogMeasure.width(of: meta))
                let name = marker.quietBranch ?? MapLogText.subject(marker)
                rows.append(Row(id: .commit(marker.sha), laneID: nil, sessionKey: nil, sourceID: nil, y: spec.y, x: labelX,
                                indent: 0, name: MapLogMeasure.fitted(name, width: available, weight: .semibold),
                                mutedPrefix: "", style: marker.quietBranch == nil ? .unnamed : .quiet, meta: meta,
                                commits: 0, edits: 0, chips: [], time: timeLabel(clock(marker.date)), isNow: false,
                                liveKind: nil))
                rowParents.append(nil)
                previousLane = nil
                previousTarget = trunkID
            case .session(let position):
                let session = sessions[position]
                let name = GrowthSeries.name(of: session.sourceID, sources: sources)
                let branchCount = session.lanes == 1 ? "1 branch" : "\(session.lanes) branches"
                var rest = "session · \(branchCount) · \(GrowthText.edits(session.edits))"
                let room = editsRight - labelX - 10 - MapLogMeasure.width(name, weight: .semibold) - 4
                if session.delegated * 2 > session.edits,
                   MapLogMeasure.width(rest + " · subagents", weight: .regular) <= room {
                    rest += " · subagents"
                }
                if MapLogMeasure.width(rest, weight: .regular) > room { rest = GrowthText.edits(session.edits) }
                rows.append(Row(id: .run(session.key, session.index), laneID: nil, sessionKey: session.key,
                                sourceID: session.sourceID, y: spec.y, x: labelX, indent: 0, name: name, mutedPrefix: "",
                                style: .session, meta: .text(rest), commits: 0, edits: 0, chips: [],
                                time: timeLabel(clock(session.first)), isNow: false, liveKind: nil))
                rowParents.append(nil)
            }
        }
        // Inside a family, the prefix its siblings share is drawn muted: "nv/" before "billing".
        for position in rows.indices {
            guard let parent = rowParents[position], rows[position].style != .session,
                  let prefix = ProjectMap.streamPrefix(rows[position].name), rows[position].name.hasPrefix(prefix),
                  rows[position].name.count > prefix.count else { continue }
            let shared = [position - 1, position + 1].contains { neighbour -> Bool in
                guard rows.indices.contains(neighbour), rowParents[neighbour] == parent else { return false }
                return ProjectMap.streamPrefix(rows[neighbour].name) == prefix
            }
            if shared { rows[position].mutedPrefix = prefix }
        }

        // Faint hour ticks between labelled rows, inside active time.
        let labelYs: [CGFloat] = rows.filter { $0.time != nil }.map(\.y).sorted()
        let rawBands: [(lower: CGFloat, upper: CGFloat)] = result.folds.map { fold in
            (lower: fold.y - 2, upper: fold.y + Self.foldHeight + 2)
        }
        let bands = Self.mergedBands(rawBands)
        func nearLabel(_ y: CGFloat) -> Bool {
            let index = Self.firstIndex(above: y - 11, in: labelYs)
            return index < labelYs.count && labelYs[index] < y + 11
        }
        func inFold(_ y: CGFloat) -> Bool {
            let index = Self.firstIndex(above: y, in: bands.lowers) - 1
            return index >= 0 && index < bands.uppers.count && y <= bands.uppers[index]
        }
        var ticks: [Tick] = []
        // Ticks reach back at most 20,000 hours from now.
        let tickStart = max(windowStart, now.addingTimeInterval(-19_999 * 3_600))
        let shift = TimeInterval(calendar.timeZone.secondsFromGMT(for: tickStart) % 3_600)
        func firstHour(atOrAfter date: Date) -> Date {
            let hours: TimeInterval = ((date.timeIntervalSince1970 + shift) / 3_600).rounded(.up)
            return Date(timeIntervalSince1970: hours * 3_600 - shift)
        }
        // Only active time gets ticks: the covered stretches and the open fold,
        // oldest first, so the idle hours a long window is mostly made of cost nothing.
        var active = covered
        if let slow { active.append(slow) }
        active.sort { $0.start < $1.start }
        // Hours run oldest first, so each tick sits above the last one: only the last needs a gap check.
        var lastTickY = CGFloat.infinity
        var lastHour = Date.distantPast
        var steps = 0
        for interval in active where interval.end >= tickStart && interval.start < now {
            // Past the last hour visited, so a stretch that touches the one before never repeats it.
            var hour = firstHour(atOrAfter: max(interval.start, tickStart, lastHour.addingTimeInterval(1)))
            while hour <= interval.end, hour < now, steps < 20_000 {
                steps += 1
                let tickY = yAt(hour)
                if tickY > nowY + 9, abs(lastTickY - tickY) >= 13, !inFold(tickY), !nearLabel(tickY) {
                    ticks.append(Tick(y: tickY, text: clock(hour)))
                    lastTickY = tickY
                }
                lastHour = hour
                hour = hour.addingTimeInterval(3_600)
            }
        }

        // Day changes outside folds get a rule; folds name the day below them.
        let dayRules = dayY.sorted { $0.key < $1.key }.compactMap { entry -> DayRule? in
            guard dayStarts.indices.contains(entry.key) else { return nil }
            return DayRule(y: entry.value, title: MapLogText.day(dayStarts[entry.key].addingTimeInterval(-60), calendar))
        }
        var folds: [Fold] = []
        for fold in result.folds {
            let changesDay = calendar.day(of: fold.start) != calendar.day(of: fold.end)
            let dayTitle: String? = changesDay ? MapLogText.day(fold.start, calendar) : nil
            let title = MapLogText.span(fold.end.timeIntervalSince(fold.start)) + " idle"
            folds.append(Fold(start: fold.start, end: fold.end, y: fold.y, id: fold.name, title: title,
                              dayTitle: dayTitle))
        }
        var unfolded: Unfolded?
        if let slow, let unfoldedStart {
            unfolded = Unfolded(top: yAt(slow.end), bottom: yAt(slow.start),
                                title: MapLogText.span(slow.end.timeIntervalSince(slow.start)) + " idle",
                                id: unfoldedStart)
        }

        let height = max(contentHeight, viewport)
        let tileCount = max(1, Int((height / Self.tileHeight).rounded(.up)))
        let tiles = (0..<tileCount).map { index in
            Tile(id: index, minY: CGFloat(index) * Self.tileHeight,
                 height: min(Self.tileHeight, height - CGFloat(index) * Self.tileHeight))
        }
        let anchorCount = max(1, min(400, Int((height / 16).rounded(.up))))
        // Each tile's rows: rows run down the window, so a tile holds one stretch of them.
        var tileRows: [Range<Int>] = []
        var rowStart = 0
        for tile in tiles {
            let tileBottom = tile.minY + tile.height
            let isLast = tile.id == tiles.count - 1
            var rowEnd = rowStart
            while rowEnd < rows.count, isLast || rows[rowEnd].y < tileBottom { rowEnd += 1 }
            tileRows.append(rowStart..<rowEnd)
            rowStart = rowEnd
        }
        // What the hit test reads on every mouse move: lines by column, marks by band of y.
        var columnBranches = Array(repeating: [Int](), count: max(1, columnCount))
        for (position, branch) in finalBranches.enumerated()
        where !branch.bead && branch.column >= 0 && branch.column < columnBranches.count {
            columnBranches[branch.column].append(position)
        }
        let runBuckets = MapLogBuckets(count: runs.count, height: height) { index in
            (lower: runs[index].rect.minY - 2, upper: runs[index].rect.maxY + 2)
        }
        let dotBuckets = MapLogBuckets(count: dots.count, height: height) { index in
            (lower: dots[index].rect.minY - 2.5, upper: dots[index].rect.maxY + 2.5)
        }
        let ringBuckets = MapLogBuckets(count: rings.count, height: height) { index in
            (lower: rings[index].center.y - 5.5, upper: rings[index].center.y + 5.5)
        }

        var trunkSolidBottom = contentHeight - 4
        if !map.isGitCheckout || !map.hasCommits {
            trunkSolidBottom = nowY
        } else if let root = map.rootCommitDate, root > windowStart {
            trunkSolidBottom = yAt(root)
        }

        self.map = map
        self.calendar = calendar
        self.width = width
        self.viewport = viewport
        self.contentHeight = contentHeight
        self.nowY = nowY
        self.trunkID = trunkID
        self.pitch = pitch
        self.columnCount = columnCount
        self.labelX = labelX
        self.commitsRight = commitsRight
        self.editsRight = editsRight
        self.scrolls = scrolls
        self.hatches = hatches
        self.trunkSolidBottom = trunkSolidBottom
        self.branches = finalBranches
        self.branchIndex = branchIndex
        self.laneProfiles = laneProfiles
        self.runs = runs
        self.dots = dots
        self.rings = rings
        self.rows = rows
        self.folds = folds
        self.unfolded = unfolded
        self.dayRules = dayRules
        self.ticks = ticks
        self.glyphs = glyphs
        self.tiles = tiles
        self.anchorCount = anchorCount
        self.anchorStep = height / CGFloat(anchorCount)
        self.markCenters = markCenters
        self.markIndex = markIndex
        self.anchors = anchors
        self.tileRows = tileRows
        self.columnBranches = columnBranches
        self.runBuckets = runBuckets
        self.dotBuckets = dotBuckets
        self.ringBuckets = ringBuckets
    }

    /// The date each idle stretch's clicks report: the start of the Map axis's
    /// gap that overlaps it most, so the inspector can describe it. The two
    /// timelines pad forks and Now differently, so the dates rarely match. A gap
    /// names one stretch only, the one it overlaps most, so a click opens the
    /// fold it landed on; a stretch left without one, such as the quiet time
    /// before Now, is named by its own start. Both lists run oldest first and
    /// never overlap themselves.
    private static func foldNames(_ stretches: [(start: Date, end: Date)], gaps: [TimeAxis.Segment]) -> [Date] {
        var best: [Int?] = Array(repeating: nil, count: stretches.count)
        var bestOverlap: [TimeInterval] = Array(repeating: 0, count: stretches.count)
        var first = 0
        for (position, stretch) in stretches.enumerated() {
            while first < gaps.count, gaps[first].end <= stretch.start { first += 1 }
            var index = first
            while index < gaps.count, gaps[index].start < stretch.end {
                let overlapEnd: Date = min(gaps[index].end, stretch.end)
                let overlapStart: Date = max(gaps[index].start, stretch.start)
                let overlap: TimeInterval = overlapEnd.timeIntervalSince(overlapStart)
                if overlap > bestOverlap[position] {
                    bestOverlap[position] = overlap
                    best[position] = index
                }
                index += 1
            }
        }
        // A gap shared by several stretches stays with the one it overlaps most.
        var owner: [Int: Int] = [:]
        for position in stretches.indices {
            guard let gap = best[position] else { continue }
            if let current = owner[gap], bestOverlap[current] >= bestOverlap[position] { continue }
            owner[gap] = position
        }
        let gapStarts = Set(gaps.map(\.start))
        var names: [Date] = []
        names.reserveCapacity(stretches.count)
        for (position, stretch) in stretches.enumerated() {
            if let gap = best[position], owner[gap] == position {
                names.append(gaps[gap].start)
            } else {
                // Never another fold's name, so it cannot open that one.
                var own = stretch.start
                while gapStarts.contains(own) { own = own.addingTimeInterval(1) }
                names.append(own)
            }
        }
        return names
    }

    /// Sorted, with overlapping bands joined, as two lists for a binary search.
    private static func mergedBands(_ bands: [(lower: CGFloat, upper: CGFloat)])
        -> (lowers: [CGFloat], uppers: [CGFloat]) {
        var lowers: [CGFloat] = []
        var uppers: [CGFloat] = []
        for band in bands.sorted(by: { $0.lower < $1.lower }) {
            if let last = uppers.last, band.lower <= last {
                uppers[uppers.count - 1] = max(last, band.upper)
            } else {
                lowers.append(band.lower)
                uppers.append(band.upper)
            }
        }
        return (lowers: lowers, uppers: uppers)
    }

    /// The first index in ascending `values` whose value is above `bound`, else `values.count`.
    private static func firstIndex(above bound: CGFloat, in values: [CGFloat]) -> Int {
        var low = 0
        var high = values.count
        while low < high {
            let middle = (low + high) / 2
            if values[middle] > bound { high = middle } else { low = middle + 1 }
        }
        return low
    }

    /// Points per active hour.
    private static func baseRate(_ range: MapRange) -> CGFloat {
        switch range {
        case .today: return 30
        case .week: return 15
        case .month: return 6
        case .all: return 4
        }
    }

    /// 11pt between columns, 8pt past 16 columns, and never more than about 40% of the width for the graph.
    /// The 4pt floor gives way once the graph would pass half the width, so the list keeps the other half.
    private static func columnPitch(columns: Int, width: CGFloat) -> CGFloat {
        let preferred: CGFloat = columns > 16 ? 8 : 11
        guard columns > 1 else { return preferred }
        let spaces = CGFloat(columns - 1)
        let fitted: CGFloat = max(4, min(preferred, (width * 0.42 - graphLeft - 17) / spaces))
        let ceiling: CGFloat = max(0.5, (width * 0.5 - graphLeft - 17) / spaces)
        return min(fitted, ceiling)
    }

    /// The y of `date`, between the sweep's anchors; anchors run newest first.
    private static func position(of date: Date, in anchors: [TimeAnchor]) -> CGFloat {
        guard let first = anchors.first, let last = anchors.last else { return top }
        if date >= first.t { return first.y }
        if date <= last.t { return last.y }
        var low = 0
        var high = anchors.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if anchors[middle].t >= date { low = middle } else { high = middle }
        }
        let upper = anchors[low]
        let lower = anchors[high]
        let span = upper.t.timeIntervalSince(lower.t)
        guard span > 0 else { return upper.y }
        return upper.y + (lower.y - upper.y) * CGFloat(upper.t.timeIntervalSince(date) / span)
    }

    // MARK: Queries

    func y(_ date: Date) -> CGFloat { Self.position(of: date, in: anchors) }

    /// The moment drawn at `y`.
    func time(atY y: CGFloat) -> Date {
        guard let first = anchors.first, let last = anchors.last else { return map.now }
        if y <= first.y { return first.t }
        if y >= last.y { return last.t }
        var low = 0
        var high = anchors.count - 1
        while high - low > 1 {
            let middle = (low + high) / 2
            if anchors[middle].y <= y { low = middle } else { high = middle }
        }
        let upper = anchors[low]
        let lower = anchors[high]
        guard lower.y > upper.y else { return upper.t }
        return upper.t.addingTimeInterval(-upper.t.timeIntervalSince(lower.t) * Double((y - upper.y) / (lower.y - upper.y)))
    }

    func dayTitle(atY y: CGFloat) -> String { MapLogText.day(time(atY: y), calendar) }

    func columnX(_ column: Int) -> CGFloat { Self.graphLeft + CGFloat(column) * pitch }

    func column(of laneID: String) -> Int {
        laneID == trunkID ? 0 : branchIndex[laneID].map { branches[$0].column } ?? 0
    }

    func title(of laneID: String) -> String { map.lane(laneID).map(MapText.title) ?? "" }

    func anchor(at y: CGFloat) -> Int { max(0, min(anchorCount - 1, Int((y / anchorStep).rounded()))) }

    /// A branch, the branches it descends from, and its direct children.
    func lineage(_ laneID: String) -> Set<String> {
        var lit: Set<String> = [laneID, trunkID]
        if let index = branchIndex[laneID] { lit.insert(branches[index].forkParentID) }
        var current = branchIndex[laneID].map { branches[$0].parentID }
        var steps = 0
        while let parent = current, steps < 8 {
            lit.insert(parent)
            current = branchIndex[parent].map { branches[$0].parentID }
            steps += 1
        }
        for branch in branches
        where branch.parentID == laneID || branch.forkParentID == laneID || branch.targetID == laneID {
            lit.insert(branch.lane.id)
        }
        return lit
    }

    /// Live heads first, then rings, commits, runs and columns in the graph,
    /// rows in the list, and folds. It runs on every mouse move, so it looks
    /// only near the pointer and allocates nothing.
    func hit(at point: CGPoint) -> MapHitID? {
        func distance(_ center: CGPoint) -> CGFloat { hypot(center.x - point.x, center.y - point.y) }
        for glyph in glyphs where distance(glyph.point) <= 8 { return glyph.hit }
        if point.x < labelX - 10 {
            var nearestRing: Int?
            var nearestDistance = CGFloat.infinity
            for index in ringBuckets.near(point.y) {
                let gap = distance(rings[index].center)
                if gap <= 5.5, gap < nearestDistance {
                    nearestRing = index
                    nearestDistance = gap
                }
            }
            if let nearestRing { return rings[nearestRing].id }
            for index in dotBuckets.near(point.y) where dots[index].rect.insetBy(dx: -2.5, dy: -2.5).contains(point) {
                let shas = dots[index].shas
                if shas.count == 1, let sha = shas.first { return .commit(sha) }
                return .cluster(shas)
            }
            for index in runBuckets.near(point.y) where runs[index].rect.insetBy(dx: -2, dy: -2).contains(point) {
                return runs[index].id
            }
            if let branch = branchHit(at: point) { return .lane(branches[branch].lane.id) }
            if abs(point.x - Self.graphLeft) <= max(3, pitch / 2), point.y >= nowY - 4, point.y <= contentHeight {
                return .lane(trunkID)
            }
        } else if let row = rowHit(atY: point.y) {
            return rows[row].id
        }
        if let fold = foldHit(atY: point.y) { return .fold(folds[fold].id) }
        if let unfolded, point.y >= unfolded.top, point.y <= unfolded.bottom, point.x >= labelX - 10 {
            return .fold(unfolded.id)
        }
        return nil
    }

    /// The nearest branch line within reach of the pointer; between lines at the
    /// same distance, the first in `branches`. Only the columns near it are read.
    private func branchHit(at point: CGPoint) -> Int? {
        let reach = max(3, pitch / 2)
        let nearest = ((point.x - Self.graphLeft) / pitch).rounded()
        guard nearest.isFinite, pitch > 0 else { return nil }
        let middle = Int(max(-1_000_000, min(1_000_000, nearest)))
        let spread = Int((reach / pitch).rounded(.up)) + 1
        let low = max(0, middle - spread)
        let high = min(columnBranches.count - 1, middle + spread)
        guard low <= high else { return nil }
        var best: Int?
        var bestDistance = CGFloat.infinity
        for column in low...high {
            let gap = abs(columnX(column) - point.x)
            guard gap <= reach else { continue }
            for position in columnBranches[column] {
                let branch = branches[position]
                let top = branch.live ? nowY : min(branch.yExt, branch.yTop)
                guard point.y >= top - 4, point.y <= branch.yBot + 4 else { continue }
                if gap < bestDistance || (gap == bestDistance && position < (best ?? Int.max)) {
                    best = position
                    bestDistance = gap
                }
            }
        }
        return best
    }

    /// The row nearest `y` within 6.5pt; rows run down the window, so a binary search finds the first.
    private func rowHit(atY y: CGFloat) -> Int? {
        var low = 0
        var high = rows.count
        while low < high {
            let middle = (low + high) / 2
            if rows[middle].y < y - 6.5 { low = middle + 1 } else { high = middle }
        }
        var best: Int?
        var bestGap = CGFloat.infinity
        var index = low
        while index < rows.count, rows[index].y <= y + 6.5 {
            let gap = abs(rows[index].y - y)
            if gap < bestGap {
                best = index
                bestGap = gap
            }
            index += 1
        }
        return best
    }

    /// The fold band around `y`; folds run down the window and never overlap.
    private func foldHit(atY y: CGFloat) -> Int? {
        var low = 0
        var high = folds.count
        while low < high {
            let middle = (low + high) / 2
            if folds[middle].y + Self.foldHeight + 1 < y { low = middle + 1 } else { high = middle }
        }
        guard low < folds.count, y >= folds[low].y - 1 else { return nil }
        return low
    }

    /// The emphasis for `id`, built once per hover however many tiles and overlays ask.
    func emphasis(for id: MapHitID?, focusSourceID: String?) -> MapLogEmphasis {
        if let value = memo.value, memo.id == id, memo.focusSourceID == focusSourceID { return value }
        let item = id.flatMap { MapHit.resolve($0, in: map) }
        let value = MapLogEmphasis(item: item, id: id, layout: self, focusSourceID: focusSourceID)
        memo.id = id
        memo.focusSourceID = focusSourceID
        memo.value = value
        return value
    }

    /// The theme and profile colors for `key`'s look, resolved once for every layer drawn from this layout.
    func inks(for key: MapLogStaticKey, colors: [String: Color], in environment: EnvironmentValues) -> MapLogInks {
        inkCache.inks(for: key, colors: colors, in: environment)
    }

    /// The patch a row is drawn in, from its elbow to the edits column, with room for pills.
    func rowFrame(_ row: Row) -> CGRect {
        let left = labelX - 12
        return CGRect(x: left, y: row.y - 9, width: max(1, width - left), height: 18)
    }
}

/// Item indices by 32pt band of y, so a hit test looks only at what is near the pointer.
private struct MapLogBuckets {
    private static let step: CGFloat = 32
    private let lists: [[Int]]

    /// `span` gives each item's reach in y, padded as far as its hit test looks.
    init(count: Int, height: CGFloat, span: (Int) -> (lower: CGFloat, upper: CGFloat)) {
        let extent: CGFloat = height.isFinite ? min(max(height, 0), 4_000_000) : 0
        let total = max(1, Int(extent / Self.step) + 1)
        var lists = Array(repeating: [Int](), count: total)
        for index in 0..<max(0, count) {
            let reach = span(index)
            let first = Self.bucket(reach.lower, total)
            let last = Self.bucket(reach.upper, total)
            guard first <= last else { continue }
            for slot in first...last { lists[slot].append(index) }
        }
        self.lists = lists
    }

    private static func bucket(_ y: CGFloat, _ total: Int) -> Int {
        guard y.isFinite else { return y > 0 ? total - 1 : 0 }
        return Int(min(max(y / step, 0), CGFloat(total - 1)))
    }

    /// Every item whose reach may hold `y`, lowest index first. The list is shared, never copied.
    func near(_ y: CGFloat) -> [Int] { lists[Self.bucket(y, lists.count)] }
}

// MARK: - Emphasis

/// What stands out: a hovered or pinned branch and its lineage, a session and
/// every branch it wrote, a commit, a fold, and a profile chosen in the legend.
///
/// The static layers draw the log at rest, with only the profile focus. A lit
/// item dims the graph to `dimmed` and the tile overlays add what it lights
/// back up to full strength; rows fade one by one, and a focused row is drawn
/// bold by the list overlay in place of its hidden static copy.
private struct MapLogEmphasis {
    /// How much of the graph shows behind a lit item.
    static let dimmed: Double = 0.25

    var lit: Set<String>?
    var sessionKey: String?
    var focusSourceID: String?
    var focusLaneID: String?
    var shas: Set<String> = []
    /// Where the highlighted commits are drawn, one per ring or capsule.
    var markCenters: [CGPoint] = []
    var foldStart: Date?
    var itemID: MapHitID?
    /// Columns the overlay draws lines on; a mark elsewhere has nothing of the overlay's to cut.
    var litColumns: [Bool] = []
    /// The lit session's runs, by index into the layout's runs.
    var sessionRuns: [Int] = []
    /// Rows the list overlay draws bold, by index into the layout's rows.
    var focusedRows: [Int] = []

    /// The log at rest: nothing lit, only the profile focus.
    init(focusSourceID: String?) {
        self.focusSourceID = focusSourceID
    }

    /// `id` is what was hovered or clicked; a fold the inspector has no gap for
    /// still lights up from it, though `item` is nil.
    init(item: MapHit?, id: MapHitID?, layout: MapLogLayout, focusSourceID: String?) {
        self.focusSourceID = focusSourceID
        itemID = item?.id
        if case .fold(let start)? = id { foldStart = start }
        guard let item else { return }
        switch item {
        case .live(let span), .span(let span):
            sessionKey = span.sessionKey
            var lanes: Set<String> = [layout.trunkID]
            for (index, run) in layout.runs.enumerated() where run.sessionKey == span.sessionKey {
                sessionRuns.append(index)
                lanes.insert(run.laneID)
            }
            lit = lanes
        case .commit(let marker):
            shas = [marker.sha]
            markCenters = Self.centers(of: shas, in: layout)
            var lanes = layout.lineage(marker.laneID)
            if let merged = marker.mergedLaneID { lanes.formUnion(layout.lineage(merged)) }
            for branch in layout.branches where branch.lane.merge?.sha == marker.sha {
                lanes.formUnion(layout.lineage(branch.lane.id))
            }
            lit = lanes
        case .cluster(let markers):
            shas = Set(markers.map(\.sha))
            markCenters = Self.centers(of: shas, in: layout)
        case .lane(let lane):
            lit = layout.lineage(lane.id)
            if lane.id != layout.trunkID { focusLaneID = lane.id }
        case .group(let lanes):
            lit = lanes.reduce(into: Set<String>()) { $0.formUnion(layout.lineage($1.id)) }
        case .fold(let gap):
            foldStart = gap.start
        }
        if let lit {
            var columns = Array(repeating: false, count: max(1, layout.columnCount))
            for laneID in lit {
                var reached = [laneID]
                // Fork and merge curves reach the columns of a branch's parent and target.
                if let index = layout.branchIndex[laneID] {
                    reached.append(layout.branches[index].forkParentID)
                    if let target = layout.branches[index].targetID { reached.append(target) }
                }
                for id in reached {
                    let column = layout.column(of: id)
                    if column >= 0, column < columns.count { columns[column] = true }
                }
            }
            litColumns = columns
        }
        for (index, row) in layout.rows.enumerated() where focuses(row) { focusedRows.append(index) }
    }

    /// Each distinct mark of `shas` once, so a cluster of hundreds rings its capsule once.
    private static func centers(of shas: Set<String>, in layout: MapLogLayout) -> [CGPoint] {
        let indices: Set<Int> = Set(shas.compactMap { layout.markIndex[$0] })
        return indices.sorted().compactMap { index -> CGPoint? in
            layout.markCenters.indices.contains(index) ? layout.markCenters[index] : nil
        }
    }

    /// Something is lit, so the graph dims behind it and the tile overlays draw it again.
    var dims: Bool { lit != nil }

    /// The tile overlays ring something: the lit branch, the session's runs or the commits.
    var highlights: Bool { focusLaneID != nil || !sessionRuns.isEmpty || !markCenters.isEmpty }

    func showsLane(_ id: String) -> Bool { lit?.contains(id) ?? true }

    func showsRun(_ run: MapLogLayout.Run) -> Bool {
        if let sessionKey { return run.sessionKey == sessionKey }
        return showsLane(run.laneID)
    }

    func showsRing(_ ring: MapLogLayout.Ring) -> Bool { shas.contains(ring.sha) || showsLane(ring.laneID) }

    /// Whether a mark on `column` cuts the lines under it. At rest every mark
    /// does; in the overlay only marks on a lit line's column have lines to cut.
    func carves(_ column: Int) -> Bool {
        guard !litColumns.isEmpty else { return true }
        return column >= 0 && column < litColumns.count && litColumns[column]
    }

    /// Profile focus dims every other profile's marks.
    func sourceAlpha(_ id: String?) -> Double {
        guard let focusSourceID else { return 1 }
        return id == focusSourceID ? 1 : 0.3
    }

    func rowAlpha(_ row: MapLogLayout.Row) -> Double {
        if let itemID, row.id == itemID { return 1 }
        var alpha = 1.0
        if row.style == .session { alpha *= sourceAlpha(row.sourceID) }
        if let sessionKey, row.style == .session {
            alpha *= row.sessionKey == sessionKey ? 1 : 0.3
        } else if let lit {
            let shown = row.laneID.map { lit.contains($0) } ?? false
            if !shown { alpha *= 0.28 }
        }
        return alpha
    }

    /// A branch or merge row the pointer names, drawn bold and in full ink.
    func focuses(_ row: MapLogLayout.Row) -> Bool {
        guard row.style != .session else { return false }
        if let focusLaneID, row.laneID == focusLaneID { return true }
        if let itemID, row.id == itemID { return true }
        return false
    }

    /// A row's static copy: hidden while the list overlay draws it focused.
    func rowOpacity(_ row: MapLogLayout.Row) -> Double { focuses(row) ? 0 : rowAlpha(row) }
}

// MARK: - Painter

/// One band of the log. Each layer draws in one transparency layer, so
/// knockouts clear only marks drawn there, never the card behind.
private struct MapLogBand {
    let top: CGFloat
    let bottom: CGFloat

    func shows(_ minY: CGFloat, _ maxY: CGFloat) -> Bool { maxY >= top - 14 && minY <= bottom + 14 }
}

/// Draws the log in layers: folds, day rules and the gutter under the graph;
/// the graph; each row on its own; and the hover's overlays. The static layers
/// draw at rest, with only the profile focus; the overlays draw what a hover lights.
private enum MapLogPainter {
    private static func ink(_ opacity: Double) -> Color { Color.primary.opacity(opacity) }

    private static func knockout(_ path: Path, in context: inout GraphicsContext) {
        var clear = context
        clear.blendMode = .destinationOut
        clear.fill(path, with: .color(.black))
    }

    /// The static layer under the graph: folds, day rules and the time gutter.
    static func drawBackground(_ layout: MapLogLayout, inks: MapLogInks, band: MapLogBand,
                               in context: inout GraphicsContext) {
        context.drawLayer { layer in
            drawBands(layout, band: band, in: &layer)
            drawGutter(layout, inks: inks, band: band, in: &layer)
        }
    }

    /// The graph: the Now edge, lines, runs, commits and rings, every one that
    /// `emphasis` shows. The static layer draws it at rest and dims as a whole
    /// behind a lit item; the hover overlay draws what the item lights, cut by
    /// the marks on its columns as the static graph is, and adds it back.
    static func drawGraph(_ layout: MapLogLayout, inks: MapLogInks, emphasis: MapLogEmphasis, band: MapLogBand,
                          in context: inout GraphicsContext) {
        context.drawLayer { layer in
            drawMarks(layout, inks: inks, emphasis: emphasis, band: band, in: &layer)
        }
    }

    /// A hovered or pinned fold a shade darker. It sits under the static band,
    /// so the two make 0.075 (0.04 for the open stretch) under the band's label.
    static func drawFoldFocus(_ layout: MapLogLayout, emphasis: MapLogEmphasis, band: MapLogBand,
                              in context: inout GraphicsContext) {
        guard let start = emphasis.foldStart else { return }
        let right = layout.bandRight
        for fold in layout.folds where fold.id == start && band.shows(fold.y, fold.y + MapLogLayout.foldHeight) {
            let rect = CGRect(x: 7, y: fold.y, width: right - 7, height: MapLogLayout.foldHeight)
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(ink(0.0415)))
        }
        if let unfolded = layout.unfolded, unfolded.id == start, band.shows(unfolded.top, unfolded.bottom) {
            let rect = CGRect(x: 7, y: unfolded.top, width: right - 7,
                              height: max(MapLogLayout.foldHeight, unfolded.bottom - unfolded.top))
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(ink(0.0154)))
        }
    }

    /// The graph's marks, in the order their knockouts cut one another.
    private static func drawMarks(_ layout: MapLogLayout, inks: MapLogInks, emphasis: MapLogEmphasis,
                                  band: MapLogBand, in context: inout GraphicsContext) {
        drawNowEdge(layout, inks: inks, band: band, in: &context)
        drawLines(layout, inks: inks, emphasis: emphasis, band: band, in: &context)
        drawRuns(layout, inks: inks, emphasis: emphasis, band: band, in: &context)
        drawCommits(layout, emphasis: emphasis, band: band, in: &context)
        drawRings(layout, emphasis: emphasis, band: band, in: &context)
    }

    // MARK: Bands

    private static func drawBands(_ layout: MapLogLayout, band: MapLogBand, in context: inout GraphicsContext) {
        let right = layout.bandRight
        for fold in layout.folds where band.shows(fold.y, fold.y + MapLogLayout.foldHeight) {
            let rect = CGRect(x: 7, y: fold.y, width: right - 7, height: MapLogLayout.foldHeight)
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(ink(0.035)))
            let label = context.resolve(Text(fold.title).font(Theme.Typeface.note).foregroundColor(ink(0.42)))
            let size = label.measure(in: CGSize(width: 300, height: 20))
            context.draw(label, at: CGPoint(x: layout.labelX, y: rect.midY), anchor: .leading)
            var rule = Path()
            rule.move(to: CGPoint(x: layout.labelX + size.width + 8, y: rect.midY))
            rule.addLine(to: CGPoint(x: layout.editsRight, y: rect.midY))
            context.stroke(rule, with: .color(ink(0.13)), style: StrokeStyle(lineWidth: 0.6, dash: [1, 2.4]))
            if let day = fold.dayTitle {
                let text = context.resolve(Text(day).font(Theme.Typeface.micro.weight(.semibold)).foregroundColor(ink(0.78)))
                context.draw(text, at: CGPoint(x: MapLogLayout.timeRight, y: rect.midY), anchor: .trailing)
            }
        }
        if let unfolded = layout.unfolded, band.shows(unfolded.top, unfolded.bottom) {
            let rect = CGRect(x: 7, y: unfolded.top, width: right - 7,
                              height: max(MapLogLayout.foldHeight, unfolded.bottom - unfolded.top))
            context.fill(Path(roundedRect: rect, cornerRadius: 4), with: .color(ink(0.025)))
            let label = context.resolve(Text(unfolded.title + " · click to fold").font(Theme.Typeface.note)
                .foregroundColor(ink(0.42)))
            context.draw(label, at: CGPoint(x: layout.labelX, y: rect.minY + 8), anchor: .leading)
        }
        for rule in layout.dayRules where band.shows(rule.y - 7, rule.y + 7) {
            var line = Path()
            line.move(to: CGPoint(x: MapLogLayout.graphLeft - 6, y: rule.y))
            line.addLine(to: CGPoint(x: layout.editsRight, y: rule.y))
            context.stroke(line, with: .color(ink(0.1)), lineWidth: 0.6)
            knockout(Path(roundedRect: CGRect(x: 6, y: rule.y - 6.5, width: MapLogLayout.timeRight - 2, height: 13),
                          cornerRadius: 3), in: &context)
            let text = context.resolve(Text(rule.title).font(Theme.Typeface.micro.weight(.semibold)).foregroundColor(ink(0.78)))
            context.draw(text, at: CGPoint(x: MapLogLayout.timeRight, y: rule.y), anchor: .trailing)
        }
    }

    /// The Now edge: green while something works, otherwise plain ink. It sits
    /// with the graph, so the trunk's Now dot cuts it.
    private static func drawNowEdge(_ layout: MapLogLayout, inks: MapLogInks, band: MapLogBand,
                                    in context: inout GraphicsContext) {
        guard band.shows(layout.nowY - 2, layout.nowY + 2) else { return }
        var edge = Path()
        edge.move(to: CGPoint(x: MapLogLayout.graphLeft - 8, y: layout.nowY))
        edge.addLine(to: CGPoint(x: layout.labelX - 7, y: layout.nowY))
        let color: Color = layout.liveKind.map { kind -> Color in inks.color(kind).opacity(0.6) } ?? ink(0.3)
        context.stroke(edge, with: .color(color), style: StrokeStyle(lineWidth: 0.8, dash: [2, 2.6]))
    }

    // MARK: Lines

    /// A vertical line, dotted where it crosses a fold.
    private static func strokeColumn(_ layout: MapLogLayout, x: CGFloat, from top: CGFloat, to bottom: CGFloat,
                                     color: Color, width: CGFloat, dash: [CGFloat], in context: inout GraphicsContext) {
        guard bottom > top else { return }
        var solid = Path()
        var dotted = Path()
        var cursor = top
        for fold in layout.folds where fold.y + MapLogLayout.foldHeight > cursor && fold.y < bottom {
            let foldTop = fold.y
            let foldBottom = fold.y + MapLogLayout.foldHeight
            if foldTop > cursor {
                solid.move(to: CGPoint(x: x, y: cursor))
                solid.addLine(to: CGPoint(x: x, y: foldTop))
            }
            dotted.move(to: CGPoint(x: x, y: max(foldTop, cursor)))
            dotted.addLine(to: CGPoint(x: x, y: min(foldBottom, bottom)))
            cursor = min(foldBottom, bottom)
        }
        if cursor < bottom {
            solid.move(to: CGPoint(x: x, y: cursor))
            solid.addLine(to: CGPoint(x: x, y: bottom))
        }
        context.stroke(solid, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: dash))
        context.stroke(dotted, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, dash: [0.1, 3]))
    }

    private static func drawLines(_ layout: MapLogLayout, inks: MapLogInks, emphasis: MapLogEmphasis,
                                  band: MapLogBand, in context: inout GraphicsContext) {
        let bottom = layout.contentHeight - 4
        if emphasis.showsLane(layout.trunkID), band.shows(layout.nowY, bottom) {
            let trunk = ink(0.5 * emphasis.sourceAlpha(nil).squareRoot())
            let solid = min(max(layout.nowY, layout.trunkSolidBottom), bottom)
            strokeColumn(layout, x: MapLogLayout.graphLeft, from: layout.nowY, to: solid, color: trunk, width: 2, dash: [],
                         in: &context)
            strokeColumn(layout, x: MapLogLayout.graphLeft, from: solid, to: bottom, color: trunk, width: 2, dash: [3, 3],
                         in: &context)
            if layout.glyphs.allSatisfy({ $0.id != layout.trunkID }) {
                let dot = CGRect(x: MapLogLayout.graphLeft - 2.7, y: layout.nowY - 2.7, width: 5.4, height: 5.4)
                knockout(Path(ellipseIn: dot.insetBy(dx: -1, dy: -1)), in: &context)
                context.fill(Path(ellipseIn: dot), with: .color(ink(0.75)))
            }
        }
        for branch in layout.branches where !branch.bead && emphasis.showsLane(branch.lane.id) {
            let lineTop = branch.live ? layout.nowY : min(branch.yExt, branch.yTop)
            guard band.shows(lineTop - 10, branch.yBot + 2) else { continue }
            let x = layout.columnX(branch.column)
            let alpha: Double
            if let focus = emphasis.focusSourceID, branch.tint != focus {
                alpha = 0.35
            } else {
                alpha = 1
            }
            let color: Color
            if branch.quiet || branch.tint == nil {
                color = ink(0.34 * alpha)
            } else {
                color = inks.profile(branch.tint).opacity(0.55 * alpha)
            }
            let liveKind = layout.glyphs.first(where: { $0.id == branch.lane.id })?.kind
            let liveColor: Color = liveKind.map { inks.color($0) } ?? inks.working
            let live: Color = liveColor.opacity(0.85 * alpha)
            let width: CGFloat = branch.quiet ? 1.15 : 1.5
            let radius = min(9, max(3, (branch.yBot - branch.yTop) / 2))
            let dash: [CGFloat] = branch.lane.kind == .folder ? [2.2, 2.2] : branch.lane.deleted ? [3, 2] : []
            let entered = branch.lane.enteredBeforeWindow
            let lineBottom = entered ? branch.yBot : branch.yBot - radius
            if branch.live {
                strokeColumn(layout, x: x, from: layout.nowY, to: lineBottom, color: live, width: 1.6, dash: [], in: &context)
            } else {
                let top = branch.targetID != nil && branch.yExt >= branch.yTop - 0.5 ? branch.yTop + radius : branch.yExt
                strokeColumn(layout, x: x, from: top, to: lineBottom, color: color, width: width, dash: dash, in: &context)
            }
            let stroke = StrokeStyle(lineWidth: branch.live ? 1.6 : width, lineCap: .round)
            if !entered {
                let parentX = layout.columnX(layout.column(of: branch.forkParentID))
                var fork = Path()
                fork.move(to: CGPoint(x: parentX, y: branch.yBot))
                fork.addCurve(to: CGPoint(x: x, y: branch.yBot - radius),
                              control1: CGPoint(x: parentX, y: branch.yBot - radius * 0.6),
                              control2: CGPoint(x: x, y: branch.yBot - radius * 0.4))
                context.stroke(fork, with: .color(branch.live ? live : color), style: stroke)
            }
            if let target = branch.targetID {
                let targetX = layout.columnX(layout.column(of: target))
                var merge = Path()
                merge.move(to: CGPoint(x: x, y: branch.yTop + radius))
                merge.addCurve(to: CGPoint(x: targetX, y: branch.yTop),
                               control1: CGPoint(x: x, y: branch.yTop + radius * 0.4),
                               control2: CGPoint(x: targetX, y: branch.yTop + radius * 0.6))
                context.stroke(merge, with: .color(color), style: stroke)
            } else if !branch.live {
                // An open tip: a small hollow dot.
                let tip = CGRect(x: x - 2.3, y: branch.yTop - 2.3, width: 4.6, height: 4.6)
                knockout(Path(ellipseIn: tip.insetBy(dx: -1, dy: -1)), in: &context)
                context.stroke(Path(ellipseIn: tip), with: .color(branch.quiet ? ink(0.4 * alpha) : color), lineWidth: 1.2)
            }
        }
    }

    // MARK: Runs

    /// A capsule per run in the profile color, hatched where subagents made most of it.
    /// A run the overlay does not light still cuts the lit lines on its column.
    private static func drawRuns(_ layout: MapLogLayout, inks: MapLogInks, emphasis: MapLogEmphasis,
                                 band: MapLogBand, in context: inout GraphicsContext) {
        for run in layout.runs where band.shows(run.rect.minY, run.rect.maxY) {
            let shows = emphasis.showsRun(run)
            guard shows || emphasis.carves(run.column) else { continue }
            let rect = run.rect
            knockout(Path(roundedRect: rect.insetBy(dx: -1, dy: -1), cornerRadius: rect.width / 2 + 1), in: &context)
            guard shows else { continue }
            let color = inks.profile(run.sourceID)
            let shape = Path(roundedRect: rect, cornerRadius: rect.width / 2)
            var layer = context
            layer.opacity = emphasis.sourceAlpha(run.sourceID)
            guard layout.hatches, run.delegated > run.direct else {
                layer.fill(shape, with: .color(color))
                continue
            }
            layer.drawLayer { inner in
                inner.clip(to: shape)
                inner.fill(shape, with: .color(color.opacity(0.34)))
                var hatch = Path()
                var y = rect.minY - rect.width
                while y < rect.maxY + rect.width {
                    hatch.move(to: CGPoint(x: rect.minX - 1, y: y + rect.width + 2))
                    hatch.addLine(to: CGPoint(x: rect.maxX + 1, y: y))
                    y += 3
                }
                inner.stroke(hatch, with: .color(color), lineWidth: 1.5)
            }
        }
    }

    // MARK: Git

    private static func drawCommits(_ layout: MapLogLayout, emphasis: MapLogEmphasis, band: MapLogBand,
                                    in context: inout GraphicsContext) {
        for dot in layout.dots where band.shows(dot.rect.minY, dot.rect.maxY) {
            let shows = emphasis.showsLane(dot.laneID)
            guard shows || emphasis.carves(dot.column) else { continue }
            knockout(Path(roundedRect: dot.rect.insetBy(dx: -1, dy: -1), cornerRadius: 2.9), in: &context)
            guard shows else { continue }
            let opacity: Double = dot.shas.count > 1 ? (dot.quiet ? 0.36 : 0.62) : (dot.quiet ? 0.45 : 0.78)
            context.fill(Path(roundedRect: dot.rect, cornerRadius: 1.9), with: .color(ink(opacity)))
        }
    }

    /// Merge rings in the card's color, bold for edited branches, with a center
    /// dot where a pull request landed on the trunk.
    private static func drawRings(_ layout: MapLogLayout, emphasis: MapLogEmphasis, band: MapLogBand,
                                  in context: inout GraphicsContext) {
        for ring in layout.rings where band.shows(ring.center.y - 6, ring.center.y + 6) {
            let shows = emphasis.showsRing(ring)
            guard shows || emphasis.carves(ring.column) else { continue }
            let radius = ring.radius
            let rect = CGRect(x: ring.center.x - radius, y: ring.center.y - radius, width: radius * 2, height: radius * 2)
            knockout(Path(ellipseIn: rect.insetBy(dx: -1.2, dy: -1.2)), in: &context)
            guard shows else { continue }
            let color = ink(ring.strong ? 0.85 : 0.5)
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: radius > 3.2 ? 1.45 : 1.2)
            if ring.centerDot {
                context.fill(Path(ellipseIn: CGRect(x: ring.center.x - 1.25, y: ring.center.y - 1.25, width: 2.5, height: 2.5)),
                             with: .color(color))
            }
        }
    }

    // MARK: List

    private static func nameColor(_ row: MapLogLayout.Row, focused: Bool, inks: MapLogInks) -> Color {
        if focused { return .primary }
        switch row.style {
        case .trunk: return ink(0.95)
        case .live: return row.liveKind.map { inks.text($0) } ?? inks.workingText
        case .branch: return ink(0.86)
        case .quiet: return ink(0.45)
        case .unnamed: return ink(0.4)
        case .session: return ink(0.86)
        }
    }

    /// One list row at `alpha`: its static copy at 1, faded by its view, or
    /// `focused` in the list overlay, bold and in full ink.
    static func drawRow(_ row: MapLogLayout.Row, _ layout: MapLogLayout, inks: MapLogInks, emphasis: MapLogEmphasis,
                        focused: Bool, alpha: Double, in context: inout GraphicsContext) {
        var rowContext = context
        rowContext.opacity = alpha
        if row.style == .session {
            let color = inks.profile(row.sourceID)
            rowContext.stroke(Path(ellipseIn: CGRect(x: row.x, y: row.y - 3.1, width: 6.2, height: 6.2)),
                              with: .color(color), lineWidth: 1.3)
            var rest = ""
            if case .text(let value) = row.meta { rest = value }
            let text = Text(row.name).font(Theme.Typeface.micro.weight(.semibold)).foregroundColor(color)
                + Text(" " + rest).font(Theme.Typeface.note).foregroundColor(ink(0.45))
            rowContext.draw(rowContext.resolve(text), at: CGPoint(x: row.x + 10, y: row.y), anchor: .leading)
            return
        }
        if row.indent > 0 {
            var elbow = Path()
            elbow.move(to: CGPoint(x: row.x - 9.5, y: row.y - 5.5))
            elbow.addLine(to: CGPoint(x: row.x - 9.5, y: row.y))
            elbow.addLine(to: CGPoint(x: row.x - 4.3, y: row.y))
            rowContext.stroke(elbow, with: .color(ink(0.25)),
                              style: StrokeStyle(lineWidth: 0.9, lineCap: .round, lineJoin: .round))
        }
        let weight: Font.Weight = row.style == .trunk || row.style == .live || focused ? .semibold : .medium
        let color = nameColor(row, focused: focused, inks: inks)
        var name: Text
        if !row.mutedPrefix.isEmpty {
            name = Text(row.mutedPrefix).foregroundColor(ink(0.4))
                + Text(String(row.name.dropFirst(row.mutedPrefix.count))).foregroundColor(color)
        } else {
            name = Text(row.name).foregroundColor(color)
        }
        name = name.font(Theme.Typeface.micro.weight(weight))
        if row.style == .unnamed { name = name.italic() }
        let resolved = rowContext.resolve(name)
        // Never narrower than the layout, so a long name in a wide one never measures short of what it draws.
        let nameWidth = resolved.measure(in: CGSize(width: max(1_000, layout.width), height: 20)).width
        rowContext.draw(resolved, at: CGPoint(x: row.x, y: row.y), anchor: .leading)
        let metaX = row.x + nameWidth + 6
        switch row.meta {
        case .empty:
            break
        case .text(let value):
            let text = rowContext.resolve(Text(value).font(Theme.Typeface.note).foregroundColor(ink(0.42)))
            rowContext.draw(text, at: CGPoint(x: metaX, y: row.y), anchor: .leading)
        case .chip(let value):
            let text = rowContext.resolve(Text(value).font(Theme.Typeface.micro.weight(.semibold)).foregroundColor(ink(0.62)))
            let size = text.measure(in: CGSize(width: 200, height: 20))
            let pill = CGRect(x: metaX - 1, y: row.y - 6, width: size.width + 10, height: 12)
            rowContext.stroke(Path(roundedRect: pill, cornerRadius: 6), with: .color(ink(0.26)), lineWidth: 0.8)
            rowContext.draw(text, at: CGPoint(x: metaX + 4, y: row.y), anchor: .leading)
        case .status(let value, let kind):
            let text = rowContext.resolve(Text(value).font(Theme.Typeface.micro.weight(.semibold))
                .foregroundColor(inks.text(kind)))
            rowContext.draw(text, at: CGPoint(x: metaX, y: row.y), anchor: .leading)
        }
        if row.commits > 0 {
            let commits = rowContext.resolve(Text("\(row.commits)").font(Theme.Typeface.micro.monospacedDigit())
                .foregroundColor(ink(0.42)))
            rowContext.draw(commits, at: CGPoint(x: layout.commitsRight, y: row.y), anchor: .trailing)
        }
        guard row.edits > 0 else { return }
        let edits = rowContext.resolve(Text(row.edits.formatted()).font(Theme.Typeface.micro.monospacedDigit())
            .foregroundColor(ink(0.85)))
        let editsWidth = edits.measure(in: CGSize(width: 200, height: 20)).width
        rowContext.draw(edits, at: CGPoint(x: layout.editsRight, y: row.y), anchor: .trailing)
        var chipX = layout.editsRight - editsWidth - 8
        for chip in row.chips {
            let rect = CGRect(x: chipX - 2.5, y: row.y - 3.75, width: 5, height: 7.5)
            drawChip(rect, color: inks.profile(chip.sourceID), hatched: chip.hatched,
                     opacity: emphasis.sourceAlpha(chip.sourceID), in: &rowContext)
            chipX -= 7
        }
    }

    private static func drawChip(_ rect: CGRect, color: Color, hatched: Bool, opacity: Double,
                                 in context: inout GraphicsContext) {
        let shape = Path(roundedRect: rect, cornerRadius: 1.5)
        var layer = context
        layer.opacity = opacity
        guard hatched else {
            layer.fill(shape, with: .color(color))
            return
        }
        layer.drawLayer { inner in
            inner.clip(to: shape)
            inner.fill(shape, with: .color(color.opacity(0.34)))
            var hatch = Path()
            var y = rect.minY - rect.width
            while y < rect.maxY + rect.width {
                hatch.move(to: CGPoint(x: rect.minX - 1, y: y + rect.width + 2))
                hatch.addLine(to: CGPoint(x: rect.maxX + 1, y: y))
                y += 3
            }
            inner.stroke(hatch, with: .color(color), lineWidth: 1.4)
        }
    }

    // MARK: Gutter

    private static func drawGutter(_ layout: MapLogLayout, inks: MapLogInks, band: MapLogBand,
                                   in context: inout GraphicsContext) {
        let nowColor: Color = layout.liveKind.map { inks.text($0) } ?? ink(0.7)
        for row in layout.rows where band.shows(row.y - 8, row.y + 8) {
            guard let time = row.time else { continue }
            let text: Text
            if row.isNow {
                text = Text(time).font(Theme.Typeface.micro.weight(.semibold)).foregroundColor(nowColor)
            } else {
                text = Text(time).font(Theme.Typeface.micro.monospacedDigit()).foregroundColor(ink(0.42))
            }
            context.draw(context.resolve(text), at: CGPoint(x: MapLogLayout.timeRight, y: row.y), anchor: .trailing)
        }
        for tick in layout.ticks where band.shows(tick.y - 8, tick.y + 8) {
            let text = context.resolve(Text(tick.text).font(Theme.Typeface.micro.monospacedDigit()).foregroundColor(ink(0.22)))
            context.draw(text, at: CGPoint(x: MapLogLayout.timeRight, y: tick.y), anchor: .trailing)
            var mark = Path()
            mark.move(to: CGPoint(x: MapLogLayout.timeRight + 3, y: tick.y))
            mark.addLine(to: CGPoint(x: MapLogLayout.timeRight + 6, y: tick.y))
            context.stroke(mark, with: .color(ink(0.22)), lineWidth: 0.6)
        }
    }

    // MARK: Highlight

    /// The hover's rings around the lit branch, its session's runs or its
    /// commits. They are not part of the graph, so they never dim.
    static func drawHighlight(_ layout: MapLogLayout, emphasis: MapLogEmphasis, band: MapLogBand,
                              in context: inout GraphicsContext) {
        let ring = ink(0.6)
        if let laneID = emphasis.focusLaneID, let index = layout.branchIndex[laneID] {
            let branch = layout.branches[index]
            if branch.bead {
                let center = CGPoint(x: layout.columnX(branch.column), y: branch.yTop)
                if band.shows(center.y - 8, center.y + 8) {
                    context.stroke(Path(ellipseIn: CGRect(x: center.x - 6.5, y: center.y - 6.5, width: 13, height: 13)),
                                   with: .color(ring), lineWidth: 1)
                }
            } else {
                let x = layout.columnX(branch.column)
                let top = (branch.live ? layout.nowY : min(branch.yExt, branch.yTop)) - 5
                let rect = CGRect(x: x - 4.5, y: top, width: 9, height: branch.yBot + 5 - top)
                if band.shows(rect.minY, rect.maxY) {
                    context.stroke(Path(roundedRect: rect, cornerRadius: 4.5), with: .color(ring), lineWidth: 1)
                }
            }
        }
        for index in emphasis.sessionRuns where index < layout.runs.count {
            let run = layout.runs[index]
            guard band.shows(run.rect.minY, run.rect.maxY) else { continue }
            let rect = run.rect.insetBy(dx: -2, dy: -2)
            context.stroke(Path(roundedRect: rect, cornerRadius: rect.width / 2), with: .color(ink(0.85)), lineWidth: 1)
        }
        for center in emphasis.markCenters where band.shows(center.y - 8, center.y + 8) {
            context.stroke(Path(ellipseIn: CGRect(x: center.x - 6.5, y: center.y - 6.5, width: 13, height: 13)),
                           with: .color(ink(0.85)), lineWidth: 1)
        }
    }

    // MARK: Header and minimap

    static func drawHeader(_ layout: MapLogLayout, day: String, size: CGSize, in context: inout GraphicsContext) {
        let middle = size.height / 2 - 1
        let dayText = context.resolve(Text(day).font(Theme.Typeface.micro.weight(.semibold)).foregroundColor(ink(0.85)))
        context.draw(dayText, at: CGPoint(x: MapLogLayout.timeRight, y: middle), anchor: .trailing)
        let lanesTitle: String = layout.columnCount == 1 ? "1 LANE" : "\(layout.columnCount) LANES"
        let lanes = context.resolve(Text(lanesTitle)
            .font(Theme.Typeface.micro.weight(.semibold)).kerning(0.6).foregroundColor(ink(0.34)))
        let lanesLeft = MapLogLayout.graphLeft - 3
        if lanesLeft + lanes.measure(in: CGSize(width: 200, height: 20)).width + 10 <= layout.labelX {
            context.draw(lanes, at: CGPoint(x: lanesLeft, y: middle), anchor: .leading)
        }
        let branch = context.resolve(Text("BRANCH").font(Theme.Typeface.micro.weight(.semibold)).kerning(0.6)
            .foregroundColor(ink(0.34)))
        context.draw(branch, at: CGPoint(x: layout.labelX, y: middle), anchor: .leading)
        let commits = context.resolve(Text("COMMITS").font(Theme.Typeface.micro.weight(.semibold)).kerning(0.6)
            .foregroundColor(ink(0.34)))
        context.draw(commits, at: CGPoint(x: layout.commitsRight, y: middle), anchor: .trailing)
        let edits = context.resolve(Text("EDITS").font(Theme.Typeface.micro.weight(.semibold)).kerning(0.6)
            .foregroundColor(ink(0.34)))
        context.draw(edits, at: CGPoint(x: layout.editsRight, y: middle), anchor: .trailing)
        var hairline = Path()
        hairline.move(to: CGPoint(x: 6, y: size.height - 0.5))
        hairline.addLine(to: CGPoint(x: size.width - 6, y: size.height - 0.5))
        context.stroke(hairline, with: .color(ink(0.08)), lineWidth: 1)
    }

    static func drawMinimap(_ layout: MapLogLayout, inks: MapLogInks, size: CGSize,
                            in context: inout GraphicsContext) {
        let scale = size.height / max(layout.contentHeight, 1)
        context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3), with: .color(ink(0.04)))
        let columnWidth = (size.width - 2) / CGFloat(max(layout.columnCount, 1))
        func x(_ column: Int) -> CGFloat { 1 + (CGFloat(column) + 0.5) * columnWidth }
        for fold in layout.folds {
            let y = (fold.y + MapLogLayout.foldHeight / 2) * scale
            context.fill(Path(CGRect(x: 1, y: y, width: size.width - 2, height: 0.6)), with: .color(ink(0.14)))
        }
        var lines = Path()
        lines.move(to: CGPoint(x: x(0), y: layout.nowY * scale))
        lines.addLine(to: CGPoint(x: x(0), y: (layout.contentHeight - 4) * scale))
        for branch in layout.branches where !branch.bead {
            let top = branch.live ? layout.nowY : min(branch.yExt, branch.yTop)
            lines.move(to: CGPoint(x: x(branch.column), y: top * scale))
            lines.addLine(to: CGPoint(x: x(branch.column), y: branch.yBot * scale))
        }
        context.stroke(lines, with: .color(ink(0.28)), lineWidth: 0.5)
        for run in layout.runs {
            let center = x(run.column)
            let rect = CGRect(x: center - columnWidth * 0.45, y: run.rect.minY * scale, width: max(1, columnWidth * 0.9),
                              height: max(0.8, run.rect.height * scale))
            context.fill(Path(rect), with: .color(inks.profile(run.sourceID)))
        }
    }
}

// MARK: - Text

private enum MapLogMeasure {
    /// Width at the list's 10pt system size, matching `Theme.Typeface.micro` and `.note`.
    static func width(_ text: String, weight: NSFont.Weight) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 10, weight: weight)
        return ceil((text as NSString).size(withAttributes: [NSAttributedString.Key.font: font]).width)
    }

    static func width(of meta: MapLogLayout.Row.Meta) -> CGFloat {
        switch meta {
        case .empty: return 0
        case .text(let value): return width(value, weight: .regular) + 6
        case .chip(let value): return width(value, weight: .semibold) + 16
        case .status(let value, _): return width(value, weight: .semibold) + 6
        }
    }

    /// Middle-truncated to `width`, so both ends of a branch name stay readable.
    static func fitted(_ text: String, width maximum: CGFloat, weight: NSFont.Weight) -> String {
        guard width(text, weight: weight) > maximum else { return text }
        let characters = Array(text)
        func candidate(_ keep: Int) -> String {
            String(characters.prefix((keep + 1) / 2)) + "…" + String(characters.suffix(keep / 2))
        }
        var low = 2
        var high = characters.count - 1
        var best: String?
        while low <= high {
            let middle = (low + high) / 2
            if width(candidate(middle), weight: weight) <= maximum {
                best = candidate(middle)
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return best ?? String(characters.prefix(2)) + "…"
    }
}

private enum MapLogText {
    /// "45 m", "2 h 25 m", "3 d 4 h".
    static func span(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) m" }
        let hours = minutes / 60
        if hours >= 48 {
            let rest = hours % 24
            return rest == 0 ? "\(hours / 24) d" : "\(hours / 24) d \(rest) h"
        }
        let rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) m"
    }

    static func clock(_ date: Date, _ calendar: ActivityCalendar) -> String {
        MomentFormat.string(date, template: "HH:mm", timeZone: calendar.timeZone)
    }

    /// "Mon 2", on the activity day, so 00:49 on Nov 3 reads "Mon 2".
    static func day(_ date: Date, _ calendar: ActivityCalendar) -> String {
        let day = calendar.day(of: date)
        return "\(DayFormat.weekday(day.weekday)) \(day.day)"
    }

    /// Without a worktree's hash suffix: "claude/navigator-redesign" for "claude/navigator-redesign-ea237c".
    static func short(_ title: String) -> String {
        guard let dash = title.lastIndex(of: "-") else { return title }
        let suffix = title[title.index(after: dash)...]
        guard suffix.count == 6, suffix.allSatisfy(\.isHexDigit) else { return title }
        return String(title[..<dash])
    }

    static func ordinal(_ value: Int) -> String {
        if (11...13).contains(value % 100) { return "\(value)th" }
        switch value % 10 {
        case 1: return "\(value)st"
        case 2: return "\(value)nd"
        case 3: return "\(value)rd"
        default: return "\(value)th"
        }
    }

    /// A pull request's subject without its " (#N)".
    static func subject(_ marker: ProjectMap.Marker) -> String {
        guard let number = marker.pullRequest else { return marker.subject }
        let suffix = " (#\(number))"
        return marker.subject.hasSuffix(suffix) ? String(marker.subject.dropLast(suffix.count)) : marker.subject
    }

    static func summary(_ layout: MapLogLayout) -> String {
        let map = layout.map
        let branches = layout.branches.count
        let merged = layout.branches.filter { $0.lane.merge != nil }.count
        let branchText: String = branches == 1 ? "1 branch" : "\(branches) branches"
        let columnText: String = layout.columnCount == 1 ? "1 column" : "\(layout.columnCount) columns"
        var parts: [String] = [branchText + " in " + columnText, "\(merged) merged"]
        parts.append(GrowthText.sessions(map.sessionCount))
        parts.append(GrowthText.edits(map.editCount))
        if !layout.folds.isEmpty {
            parts.append(layout.folds.count == 1 ? "1 idle stretch folded" : "\(layout.folds.count) idle stretches folded")
        }
        for glyph in layout.glyphs {
            parts.append("\(glyph.kind == .needsInput ? "needs input" : "working") on \(layout.title(of: glyph.id))")
        }
        let names = layout.rows.filter { $0.style != .session }.prefix(12).map(\.name)
        return parts.joined(separator: ", ") + ". Newest first: " + names.joined(separator: ", ")
    }
}
