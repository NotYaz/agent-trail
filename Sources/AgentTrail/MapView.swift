import SwiftUI
import AgentTrailCore

// MARK: - Map tab

/// The Map tab: one project's branches as lanes off the trunk, each session's
/// runs of edits on the lane where they landed, and the commits and merged
/// pull requests Git recorded. Time runs left to right with idle hours folded.
struct MapView: View {
    @ObservedObject private var store: AppStore
    @Environment(\.rendersStill) private var rendersStill
    /// What the pointer is over, and what a click pinned, by identity: each
    /// rebuild of the map resolves them again, so a pinned item never goes stale.
    /// Hover and selection, deliberately not observed here: a hover redraws
    /// only the views that show it (each mode's overlay and the inspector),
    /// never the header, the summary or a mode's static drawing.
    private let hover: MapHoverModel
    /// Shown in the Map window rather than the panel; live effects follow that window.
    private let inWindow: Bool
    @State private var focusSourceID: String?
    /// The view's width, which decides whether the window has room for the details panel.
    @State private var width: CGFloat = 0
    @AppStorage(AppSettings.Key.mapShowsDetails) private var showsDetails = true

    /// The panel uses the store's hover model; the window passes its own, so a
    /// hover in one never highlights the other.
    init(store: AppStore, hover: MapHoverModel? = nil, inWindow: Bool = false) {
        _store = ObservedObject(wrappedValue: store)
        self.hover = hover ?? store.mapHover
        self.inWindow = inWindow
    }

    private var isShown: Bool { inWindow ? store.isMapWindowVisible : store.isPanelVisible }

    /// The narrowest Map window that keeps the details panel beside the map; a narrower one
    /// describes items in the strip under the map, as the panel does.
    static let detailsMinimumWidth: CGFloat = 980

    /// The window is wide enough for the details panel, and the user keeps it open.
    private var hasRoomForDetails: Bool { inWindow && width >= Self.detailsMinimumWidth }
    private var showsDetailPanel: Bool { hasRoomForDetails && showsDetails }

    /// The panel takes about a quarter of a wide window.
    private var detailPanelWidth: CGFloat { min(400, max(320, (width * 0.28).rounded())) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
                .padding(.bottom, Theme.Space.xs)
            if let map = currentMap {
                MapSummaryRow(map: map, showsAll: $store.mapShowsAllBranches, foldsLanes: store.mapMode == .lanes) {
                    select(MapHit.live($0).id)
                }
                    .padding(.bottom, Theme.Space.s)
                if inWindow {
                    // The card keeps its place whether or not the panel shows, so hiding the
                    // panel or crossing its width only resizes the map; open families, the
                    // pinned day and the Log's scroll survive.
                    HStack(alignment: .top, spacing: Theme.Space.s) {
                        card(map)
                        if showsDetailPanel {
                            MapDetailPanel(map: map, hover: hover, store: store, focusSourceID: $focusSourceID,
                                           animatesLive: isShown && store.liveIsFresh && !rendersStill)
                                .frame(width: detailPanelWidth)
                                .frame(maxHeight: .infinity)
                        }
                    }
                } else {
                    card(map)
                }
            } else {
                emptyState
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, Theme.Space.m)
        .padding(.bottom, Theme.Space.m)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { value in
            // Only the window can make room for the details panel.
            if inWindow { width = value }
        }
        .onChange(of: store.mapProject) { _, _ in clearSelection() }
        .onChange(of: store.mapRange) { _, _ in clearSelection() }
    }

    /// The previous range's map stays up while the new one builds.
    private var currentMap: ProjectMap? {
        guard let map = store.projectMap, map.projectPath == store.mapProject else { return nil }
        return map
    }

    private func select(_ hit: MapHitID?) {
        hover.select(hit)
    }

    private func clearSelection() {
        hover.hovered = nil
        hover.selected = nil
        focusSourceID = nil
    }

    // MARK: Header

    private var titleRow: some View {
        HStack(spacing: Theme.Space.xs) {
            Text("Map")
                .font(Theme.Typeface.title)
                .accessibilityAddTraits(.isHeader)
            if !store.projects.isEmpty {
                projectMenu
            }
            Spacer(minLength: Theme.Space.xs)
            MapModePicker(selection: $store.mapMode)
            PillSegmented(selection: $store.mapRange, options: Self.rangeOptions, label: "Range", fillsWidth: true,
                          accessibilityLabels: Self.rangeAccessibilityLabels)
                .frame(width: 216)
            if hasRoomForDetails {
                detailsToggle
            }
            InfoButton { MapAboutText() }
        }
        .frame(height: 26)
    }

    /// Shows or hides the window's details panel.
    private var detailsToggle: some View {
        Button { showsDetails.toggle() } label: {
            Image(systemName: "sidebar.right")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 26)
                .background(showsDetails ? Theme.Palette.raised : Theme.Palette.sunken,
                            in: Theme.Radius.shape(Theme.Radius.control))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(showsDetails ? Color.primary : Color.secondary)
        .help(showsDetails ? "Hide the details panel" : "Show the details panel")
        .accessibilityLabel("Details panel")
        .accessibilityAddTraits(showsDetails ? .isSelected : [])
    }

    private static let rangeOptions: [(value: MapRange, title: String)] = MapRange.allCases.map {
        (value: $0, title: $0.rawValue)
    }

    private static let rangeAccessibilityLabels: [MapRange: String] = Dictionary(
        uniqueKeysWithValues: MapRange.allCases.map { ($0, $0.title) })

    private var projectTitle: String {
        guard let path = store.mapProject else { return "Choose a project" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.count > 26 ? String(name.prefix(24)) + "…" : name
    }

    private var projectBinding: Binding<String> {
        Binding(get: { store.mapProject ?? "" }, set: { value in store.mapProjectPath = value.isEmpty ? nil : value })
    }

    private var projectMenu: some View {
        Menu {
            Picker("Project", selection: projectBinding) {
                ForEach(store.projects.prefix(40)) { (project: ProjectSummary) in
                    Text(project.name).tag(project.path)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(projectTitle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Theme.Palette.sunken, in: Capsule())
        .help("Choose the project the Map draws")
        .accessibilityLabel("Project")
        .accessibilityValue(projectTitle)
    }

    @ViewBuilder private var emptyState: some View {
        if store.demoMode {
            emptyText("The Map draws your own sessions and Git branches, so the demo has none.")
        } else if store.projects.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("No project to map yet")
                    .font(Theme.Typeface.headline)
                emptyText("The Map shows a project's branches and sessions once an assistant has edited it.")
            }
            .padding(.top, Theme.Space.s)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                emptyText("Reading history…")
            }
            .padding(.top, Theme.Space.s)
        }
    }

    /// Nothing was edited or committed in the range.
    private func emptyRange(_ map: ProjectMap) -> some View {
        VStack(spacing: Theme.Space.xs) {
            Text("Nothing recorded \(map.range == .today ? "today" : "in the \(map.range.title.lowercased())")")
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
            if map.range != .all {
                Button("Show all history") { store.mapRange = .all }
                    .buttonStyle(.borderless)
                    .font(Theme.Typeface.caption)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyText(_ text: String) -> some View {
        Text(text)
            .font(Theme.Typeface.caption)
            .foregroundStyle(.secondary)
    }

    // MARK: Card

    private func card(_ map: ProjectMap) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if map.axis.segments.isEmpty {
                emptyRange(map)
            } else {
                GeometryReader { proxy in
                    let context = MapCanvasContext(map: map, sources: map.sources(store.sources), calendar: store.activityCalendar,
                                                   size: proxy.size, selected: nil, focusSourceID: focusSourceID,
                                                   animatesLive: isShown && store.liveIsFresh && !rendersStill,
                                                   showsDetailPanel: showsDetailPanel)
                    switch store.mapMode {
                    case .lanes:
                        MapField(map: map, sources: context.sources, calendar: store.activityCalendar,
                                 size: proxy.size, hover: hover, focusSourceID: focusSourceID,
                                 animatesLive: context.animatesLive, scrollsWide: inWindow,
                                 allBranches: store.mapShowsAllBranches, openBundles: store.mapOpenBundles) { bundle in
                            // Folding forgets every strand, as the bundle may have been opened under another id.
                            if store.mapOpenBundles.isDisjoint(with: bundle.laneIDs) {
                                store.mapOpenBundles.insert(bundle.id)
                            } else {
                                store.mapOpenBundles.subtract(bundle.laneIDs)
                            }
                        }
                    case .tree:
                        MapTreeView(context: context, hover: hover)
                    case .orbit:
                        MapOrbitView(context: context, hover: hover)
                    case .log:
                        MapLogView(context: context, hover: hover)
                    }
                }
            }
            if !showsDetailPanel {
                MapInspectorHost(map: map, hover: hover, store: store)
                    .padding(.top, Theme.Space.xs)
            }
            MapLegend(map: map, sources: map.sources(store.sources), focus: $focusSourceID)
                .padding(.top, Theme.Space.xs)
        }
        .padding(Theme.Space.sectionPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardSurface(radius: Theme.Radius.section)
    }
}

// MARK: - Summary row

private struct MapSummaryRow: View {
    let map: ProjectMap
    @Binding var showsAll: Bool
    let foldsLanes: Bool
    let selectLive: (ProjectMap.Span) -> Void

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Text(summary)
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            if !map.isGitCheckout {
                Pill(text: "Not a Git checkout")
            }
            if foldsLanes && (map.unfoldedBranchCount != nil || !map.bundles.isEmpty || showsAll) {
                Button(showsAll ? "Group" : "Show all") { showsAll.toggle() }
                    .buttonStyle(.borderless)
                    .font(Theme.Typeface.caption.weight(.medium))
                    .help(showsAll ? "Bundle branches worked on side by side, and fold related ones into streams"
                          : "Draw every branch on its own lane")
            }
            Spacer(minLength: Theme.Space.xs)
            if let live = liveRun {
                Button { selectLive(live) } label: {
                    HStack(spacing: 4) {
                        StatusGlyph(kind: kind(live), size: 9)
                        Text(liveText)
                            .font(Theme.Typeface.caption.weight(.medium))
                            .foregroundStyle(kind(live).textColor)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .help("Show this session")
            }
        }
        .frame(height: 16)
    }

    private var summary: String {
        // A bundle's strands share its row.
        let rows = map.lanes.filter { $0.kind != .trunk && ($0.bundle == nil || $0.bundle == $0.id) }.count
        let branches = map.unfoldedBranchCount ?? map.lanes.filter { $0.kind != .trunk }.count
        // The range control already names the period.
        var parts = [GrowthText.sessions(map.sessionCount), GrowthText.edits(map.editCount)]
        if map.cloudSessionCount > 0 {
            parts.insert("\(map.cloudSessionCount) cloud", at: 1)
        }
        parts.append(branches == 1 ? "1 branch" : "\(branches) branches")
        if map.unfoldedBranchCount != nil { parts[parts.count - 1] += " in \(rows) streams" }
        if map.mergeCount > 0 { parts.append("\(map.mergeCount) merged") }
        return parts.joined(separator: " · ")
    }

    private var liveRuns: [ProjectMap.Span] { map.spans.filter { $0.live != nil } }

    /// Needs input outranks working.
    private var liveRun: ProjectMap.Span? {
        liveRuns.first { $0.live == LiveStatus.waiting.rawValue } ?? liveRuns.last
    }

    private func kind(_ span: ProjectMap.Span) -> StatusGlyph.Kind {
        span.live == LiveStatus.waiting.rawValue ? .needsInput : .working
    }

    private var liveText: String {
        let waiting = liveRuns.filter { $0.live == LiveStatus.waiting.rawValue }.count
        let word = waiting > 0 ? "needs input" : "working"
        let count = waiting > 0 ? waiting : liveRuns.count
        guard count == 1, let run = liveRun else { return "\(count) \(word)" }
        return "1 \(word) · \(map.lane(run.laneID).map(MapText.title) ?? "")"
    }
}

// MARK: - Layout

/// Something on the Map the inspector can describe.
enum MapHit: Equatable {
    case live(ProjectMap.Span)
    case span(ProjectMap.Span)
    case commit(ProjectMap.Marker)
    /// Trunk beads closer than a bead's width, drawn as one capsule.
    case cluster([ProjectMap.Marker])
    case lane(ProjectMap.Lane)
    /// Branches a view draws as one node, such as a family of worktrees.
    case group([ProjectMap.Lane])
    case fold(TimeAxis.Segment)

    var sessionKey: String? {
        switch self {
        case .live(let span), .span(let span): return span.sessionKey
        default: return nil
        }
    }

    var id: MapHitID {
        switch self {
        case .live(let span), .span(let span): return .run(span.sessionKey, span.index)
        case .commit(let marker): return .commit(marker.sha)
        case .cluster(let markers): return .cluster(markers.map(\.sha))
        case .lane(let lane): return .lane(lane.id)
        case .group(let lanes): return .group(lanes.map(\.id))
        case .fold(let gap): return .fold(gap.start)
        }
    }

    /// The item `id` names in `map`, or nil when the map no longer has it.
    static func resolve(_ id: MapHitID, in map: ProjectMap) -> MapHit? {
        switch id {
        case .run(let key, let index):
            let runs = map.spans.filter { $0.sessionKey == key }
            guard let run = runs.first(where: { $0.index == index }) ?? runs.max(by: { $0.index < $1.index }) else { return nil }
            return run.live != nil ? .live(run) : .span(run)
        case .commit(let sha):
            return map.markers.first { $0.sha == sha }.map(MapHit.commit)
        case .cluster(let shas):
            let wanted = Set(shas)
            let markers = map.markers.filter { wanted.contains($0.sha) }
            return markers.isEmpty ? nil : markers.count == 1 ? .commit(markers[0]) : .cluster(markers)
        case .lane(let id):
            return map.lane(id).map(MapHit.lane)
        case .group(let ids):
            let lanes = ids.compactMap(map.lane)
            return lanes.isEmpty ? nil : lanes.count == 1 ? .lane(lanes[0]) : .group(lanes)
        case .fold(let start):
            return map.axis.gaps.first { $0.start == start }.map(MapHit.fold)
        }
    }
}

enum MapHitID: Hashable {
    case run(String, Int)
    case commit(String)
    case cluster([String])
    case lane(String)
    case group([String])
    case fold(Date)

    var isRun: Bool {
        if case .run = self { return true }
        return false
    }
}

/// How the Map's emphasis changes: a veil fades in and out, and one lit item hands over to
/// the next in a short crossfade, so sliding across the map never flashes. Still renders and
/// Reduce Motion switch at once.
///
/// Both are springs without bounce. A spring that is interrupted retargets the running one,
/// where a timing curve adds another animation on top: sweeping the Log's hundreds of rows
/// stacked about eight curves per row and cost 22 ms a move, against 5.5 ms with springs.
enum MapMotion {
    /// The veil that dims what an emphasis leaves out, fading in or out.
    static let veil: Animation = .smooth(duration: 0.18)
    /// One emphasized item handing over to the next: the lit layer, its rings and its words.
    static let crossfade: Animation = .smooth(duration: 0.16)
    /// How long the pointer may be off an item before its emphasis lets go, so crossing the
    /// gap between two rows hands over from one to the next instead of dropping the veil.
    static let leaveDelay: Duration = .milliseconds(150)

    /// `base`, or nil (an instant change) under Reduce Motion and in still renders.
    static func animation(_ base: Animation, reduceMotion: Bool, still: Bool) -> Animation? {
        Theme.Motion.animation(base, reduceMotion: reduceMotion, still: still)
    }
}

/// What the pointer is over on the Map, and what a click pinned, by identity.
@MainActor
final class MapHoverModel: ObservableObject {
    @Published var hovered: MapHitID?
    @Published var selected: MapHitID?
    /// Lets go of `hovered` once the pointer has been off it for `MapMotion.leaveDelay`.
    private var release: Task<Void, Never>?
    /// What `release` publishes: where the pointer is now.
    private var pending: MapHitID?

    /// The item to emphasize: a pinned one, else the hovered one.
    var emphasized: MapHitID? { selected ?? hovered }

    /// True while `hovered` is kept for a pointer that has already left it.
    var isHolding: Bool { release != nil }

    /// Publishes only a real change: the pointer moving within one item does nothing. Leaving
    /// an item keeps it for a moment, and the next item the pointer reaches replaces it directly.
    /// With `holdsRun`, a session's run is kept the same way while the pointer crosses what lies
    /// between its runs (a lane line, a commit on the bar, an empty day), so its veil does not
    /// drop at each one. A list, where each item keeps the veil, hands over directly.
    func hover(_ id: MapHitID?, holdsRun: Bool = true) {
        if id == nil || (holdsRun && hovered?.isRun == true && id?.isRun != true) {
            guard let hovered, hovered != id else {
                release?.cancel()
                release = nil
                return
            }
            pending = id
            guard release == nil else { return }
            release = Task { [weak self] in
                try? await Task.sleep(for: MapMotion.leaveDelay)
                guard !Task.isCancelled, let self else { return }
                self.release = nil
                if self.hovered != self.pending { self.hovered = self.pending }
            }
            return
        }
        release?.cancel()
        release = nil
        if hovered != id { hovered = id }
    }

    /// A click pins an item; clicking it again, or empty space, unpins.
    func select(_ id: MapHitID?) {
        selected = id == selected ? nil : id
    }
}

/// A Canvas that records its drawing again only when `key` changes. A hover
/// changes only an overlay, so the full picture under it is not redrawn; a
/// plain Canvas re-runs its closure whenever its parent's body runs.
struct MapStaticCanvas<Key: Equatable>: View, Equatable {
    let key: Key
    let draw: (inout GraphicsContext, CGSize) -> Void

    nonisolated static func == (lhs: MapStaticCanvas, rhs: MapStaticCanvas) -> Bool { lhs.key == rhs.key }

    var body: some View {
        Canvas { context, size in draw(&context, size) }
    }
}

/// What a static layer depends on besides its layout: the focused profile and the appearance.
struct MapStaticKey: Equatable {
    let layout: Int
    let focusSourceID: String?
    let colorScheme: ColorScheme
}

extension Color {
    /// This color resolved for `environment`. Theme and profile colors are
    /// dynamic system colors, and resolving one for every stroke was most of
    /// the Map's drawing time; a flattened color costs nothing to draw.
    func flattened(in environment: EnvironmentValues) -> Color {
        Color(resolve(in: environment))
    }
}

/// The inspector under every mode; the only part of the card besides each
/// mode's overlay that follows the hover.
private struct MapInspectorHost: View {
    let map: ProjectMap
    @ObservedObject var hover: MapHoverModel
    let store: AppStore

    var body: some View {
        let item = hover.emphasized.flatMap { MapHit.resolve($0, in: map) } ?? MapInspector.defaultItem(map)
        MapInspector(map: map, item: item, store: store)
    }
}

/// How the Map draws a project.
enum MapMode: String, CaseIterable, Hashable {
    /// Branch lanes over a folded timeline.
    case lanes
    /// Branches as a tree off main, families folded into nodes.
    case tree
    /// The week as a ring, branches blooming at their time of day.
    case orbit
    /// A vertical git log, newest on top, with agent work on each branch.
    case log

    var title: String {
        switch self {
        case .lanes: return "Lanes"
        case .tree: return "Tree"
        case .orbit: return "Orbit"
        case .log: return "Log"
        }
    }

    var symbol: String {
        switch self {
        case .lanes: return "line.3.horizontal"
        case .tree: return "point.3.connected.trianglepath.dotted"
        case .orbit: return "circle.dashed"
        case .log: return "list.bullet.indent"
        }
    }
}

/// Everything a Map mode draws from. Hover and clicks are reported as
/// `MapHitID`s, which the inspector under every mode describes.
struct MapCanvasContext {
    let map: ProjectMap
    let sources: [AgentSource]
    let calendar: ActivityCalendar
    /// The space the mode may fill; it scrolls inside itself if it needs more.
    let size: CGSize
    /// A clicked item; the mode emphasizes it as it does the hovered one.
    let selected: MapHitID?
    /// A profile chosen in the legend; the mode dims every other profile.
    let focusSourceID: String?
    /// Continuous effects (the working pulse) may run.
    let animatesLive: Bool
    /// The window's details panel describes the emphasized item, so a mode leaves out its own
    /// floating card for it.
    var showsDetailPanel = false

    func color(_ sourceID: String) -> Color { ProfileColor.color(sourceID, sources: sources) }
}

/// Icons for the Map's modes, on a sunken track like the range control.
private struct MapModePicker: View {
    @Binding var selection: MapMode

    var body: some View {
        HStack(spacing: 2) {
            ForEach(MapMode.allCases, id: \.self) { mode in
                Button { selection = mode } label: {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 22)
                        .background(selection == mode ? Theme.Palette.raised : Color.clear,
                                    in: Theme.Radius.shape(6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selection == mode ? Color.primary : Color.secondary)
                .help(mode.title)
                .accessibilityLabel(mode.title)
                .accessibilityAddTraits(selection == mode ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Theme.Palette.sunken, in: Theme.Radius.shape(Theme.Radius.control))
    }
}

/// Every position the field draws, computed once per map and size.
struct MapLayout {
    static let axisHeight: CGFloat = 34
    static let barHeight: CGFloat = 8
    static let slotStep: CGFloat = 10
    /// The live head and its halo need room past now.
    static let trailingInset: CGFloat = 12
    /// An open bundle's title has a line of its own above its strands' names.
    static let bundleTitleLine: CGFloat = 14

    struct Bead {
        let markers: [ProjectMap.Marker]
        let minX: CGFloat
        let maxX: CGFloat
        var center: CGFloat { (minX + maxX) / 2 }
    }

    /// A bundle as drawn: its strands, folded close together or open as lanes with names.
    struct BundleShape {
        let bundle: ProjectMap.Bundle
        let lanes: [ProjectMap.Lane]
        let isOpen: Bool
        /// Where its first strand leaves, where its last line ends, and where its lines reach.
        let start: CGFloat
        let end: CGFloat
        let reach: CGFloat
        /// Its title's baseline, and its last strand's y.
        let titleY: CGFloat
        let bottom: CGFloat
        /// Its strands' bar height.
        let bar: CGFloat
        let enteredBeforeWindow: Bool
    }

    /// What names a row's stretch: a branch of its own, or a bundle under its title.
    struct LabelUnit {
        let title: String
        let row: Int
        /// Where its line leaves and ends, and where its lines reach (to now, while live).
        let start: CGFloat
        let end: CGFloat
        let reach: CGFloat
        let baseline: CGFloat
        let enteredBeforeWindow: Bool
        let primary: Bool
        let italic: Bool
        let merged: Bool
        /// The lane it names, or the bundle, which a chevron after its title opens and folds.
        let laneID: String?
        let bundle: BundleShape?
        /// Where it is drawn, worked out once so its hover and click target match: its text
        /// (a bundle's short title when the full one does not fit), left edge, the width it may
        /// take and the width it takes. Nil when there is no room to name it.
        var place: Place? = nil
    }

    struct Place {
        let text: String
        let left: CGFloat
        let width: CGFloat
        let drawn: CGFloat
    }

    let map: ProjectMap
    let width: CGFloat
    let calendar: ActivityCalendar
    let laneByID: [String: ProjectMap.Lane]
    /// Row number to the y of its lane line.
    let laneY: [Int: CGFloat]
    let fieldHeight: CGFloat
    let beads: [Bead]
    /// Each run's 2pt density bins from its left edge: direct and delegated edits.
    let bins: [String: [(bin: Int, direct: Int, delegated: Int)]]
    /// Quartile thresholds for edit-density bins, over every bin in the map.
    let binLevels: [Int]
    /// How far apart a long lane's name repeats in a field wider than the window, or nil.
    let labelRepeat: CGFloat?
    /// Label widths measured while drawing, kept for the layout's other strips and redraws.
    let textWidths = MapTextWidths()
    /// Bundles by id, and the names on each row in order of row and start.
    let bundleShapes: [String: BundleShape]
    let labelUnits: [LabelUnit]
    /// Open bundles' strand names, by lane id.
    let strandLabels: [String: Place]
    /// Each strand's y, and for every lane the y its fork leaves from.
    private let strandY: [String: CGFloat]
    private let forkFrom: [String: CGFloat]
    /// Hit targets, computed once: a hover runs `hit(at:)` on every mouse move.
    private let commitPoints: [(marker: ProjectMap.Marker, point: CGPoint, reach: CGFloat)]
    private let runTargets: [(span: ProjectMap.Span, rect: CGRect, y: CGFloat)]
    private let laneTargets: [(lane: ProjectMap.Lane, start: CGFloat, end: CGFloat, y: CGFloat, reach: CGFloat,
                               label: ClosedRange<CGFloat>?)]
    private let bundleTargets: [(lanes: [ProjectMap.Lane], start: CGFloat, end: CGFloat, y: CGFloat)]

    /// Folded strands this far apart, with bars this tall; closer when there are many.
    static func strandPitch(_ count: Int) -> CGFloat { count <= 12 ? 6 : max(3, (66 / CGFloat(count - 1)).rounded(.down)) }
    static func strandBar(_ count: Int) -> CGFloat { max(2, strandPitch(count) - 2) }

    init(map: ProjectMap, width: CGFloat, availableHeight: CGFloat, calendar: ActivityCalendar,
         labelRepeat: CGFloat? = nil, openBundles: Set<String> = []) {
        self.map = map
        self.width = width
        self.calendar = calendar
        self.labelRepeat = labelRepeat
        let laneByID = Dictionary(map.lanes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        self.laneByID = laneByID
        // A row is as tall as its tallest lane: its stacked runs, or a bundle's strands.
        let slots = Dictionary(grouping: map.spans, by: \.laneID).mapValues { ($0.map(\.slot).max() ?? 0) + 1 }
        func laneHeight(_ id: String) -> CGFloat { 28 + 10 * CGFloat((slots[id] ?? 1) - 1) }
        let bundleByID = Dictionary(map.bundles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Open by any of its strands, so a bundle stays open when a rebuild gives it another first strand.
        func isOpen(_ bundle: ProjectMap.Bundle) -> Bool { !openBundles.isDisjoint(with: bundle.laneIDs) }
        let rows = Set(map.lanes.map(\.row)).sorted()
        let heights = rows.map { row -> CGFloat in
            var height: CGFloat = 28
            for lane in map.lanes where lane.row == row {
                if lane.bundle == nil {
                    height = max(height, laneHeight(lane.id))
                } else if let id = lane.bundle, lane.id == id, let bundle = bundleByID[id] {
                    let count = bundle.laneIDs.count
                    height = max(height, isOpen(bundle)
                                 ? Self.bundleTitleLine + bundle.laneIDs.reduce(0) { $0 + laneHeight($1) }
                                 : 28 + Self.strandPitch(count) * CGFloat(count - 1))
                }
            }
            return height
        }
        let natural = heights.reduce(0, +) + 8
        let fit = min(1.4, max(1, availableHeight / natural))
        var y: CGFloat = 2
        var laneY: [Int: CGFloat] = [:]
        for (row, height) in zip(rows, heights) {
            laneY[row] = y + 12 * fit + 5
            y += height * fit
        }
        self.laneY = laneY
        fieldHeight = y + 6
        // Strands: folded, a few points apart under the row's line; open, a lane's height
        // apart under the bundle's title.
        var strandY: [String: CGFloat] = [:]
        for bundle in map.bundles {
            guard let row = laneByID[bundle.id]?.row, let base = laneY[row] else { continue }
            var offset = Self.bundleTitleLine
            for (strand, id) in bundle.laneIDs.enumerated() {
                if isOpen(bundle) {
                    strandY[id] = base + offset * fit
                    offset += laneHeight(id)
                } else {
                    strandY[id] = base + Self.strandPitch(bundle.laneIDs.count) * CGFloat(strand)
                }
            }
        }
        self.strandY = strandY
        // Beads closer than one bead's width share a capsule.
        let plot = width - Self.trailingInset
        let trunk = map.trunkID
        var beads: [Bead] = []
        for marker in map.markers where marker.laneID == trunk && marker.isBead {
            let x = CGFloat(map.axis.position(of: marker.date)) * plot
            if let last = beads.last, x - last.maxX < 10 {
                beads[beads.count - 1] = Bead(markers: last.markers + [marker], minX: last.minX, maxX: x)
            } else {
                beads.append(Bead(markers: [marker], minX: x, maxX: x))
            }
        }
        self.beads = beads
        var totals: [Int] = []
        var allBins: [String: [(bin: Int, direct: Int, delegated: Int)]] = [:]
        for span in map.spans {
            let left = CGFloat(map.axis.position(of: span.start)) * plot
            var counts: [Int: (direct: Int, delegated: Int)] = [:]
            for edit in span.direct {
                counts[Int((CGFloat(map.axis.position(of: edit)) * plot - left) / 2), default: (0, 0)].direct += 1
            }
            for edit in span.delegated {
                counts[Int((CGFloat(map.axis.position(of: edit)) * plot - left) / 2), default: (0, 0)].delegated += 1
            }
            allBins[span.id] = counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value.direct, $0.value.delegated) }
            totals += counts.values.map { $0.direct + $0.delegated }
        }
        bins = allBins
        totals.sort()
        func quantile(_ p: Double) -> Int { totals.isEmpty ? 1 : totals[min(totals.count - 1, Int(p * Double(totals.count)))] }
        binLevels = [quantile(0.25), quantile(0.5), quantile(0.75)]
        // Targets for hit testing, so a mouse move does no searching or allocating.
        let rowY = laneY
        let trunkY = laneY[0] ?? 19
        func yOf(_ lane: ProjectMap.Lane) -> CGFloat { strandY[lane.id] ?? rowY[lane.row] ?? 0 }
        func xOf(_ date: Date) -> CGFloat { CGFloat(map.axis.position(of: date)) * plot }
        func extentOf(_ lane: ProjectMap.Lane) -> (start: CGFloat, end: CGFloat) {
            let start = lane.enteredBeforeWindow ? 0 : xOf(lane.start)
            return (start, max(xOf(lane.merge?.date ?? lane.end), start + 10))
        }
        func reachOf(_ lane: ProjectMap.Lane) -> CGFloat {
            let extent = extentOf(lane)
            let end = lane.merge == nil && (lane.isLive || lane.isHead) ? xOf(map.now) : extent.end
            return max(end, extent.start, lane.returns.map { xOf($0.date) }.max() ?? end)
        }
        // Bundles, and where each strand forks: the first from the lane the bundle sits under
        // when that lane is there yet, else the trunk; each next from the nearest strand above
        // still running, so the strands split off one another.
        var shapes: [String: BundleShape] = [:]
        var forkFrom: [String: CGFloat] = [:]
        for bundle in map.bundles {
            let lanes = bundle.laneIDs.compactMap { laneByID[$0] }
            guard let first = lanes.first else { continue }
            let open = isOpen(bundle)
            let start = lanes.map { extentOf($0).start }.min() ?? 0
            let parent = laneByID[bundle.parentID].flatMap { extentOf($0).start <= start + 1 ? $0 : nil }
            let source = parent.map(yOf) ?? trunkY
            for (strand, lane) in lanes.enumerated() {
                let x = extentOf(lane).start
                let above = lanes[..<strand].last { extentOf($0).start <= x + 1 && reachOf($0) >= x }
                forkFrom[lane.id] = above.map(yOf) ?? source
            }
            shapes[bundle.id] = BundleShape(bundle: bundle, lanes: lanes, isOpen: open, start: start,
                                            end: lanes.map { extentOf($0).end }.max() ?? start,
                                            reach: lanes.map(reachOf).max() ?? start,
                                            titleY: (rowY[first.row] ?? 0) - 7, bottom: lanes.last.map(yOf) ?? 0,
                                            bar: open ? Self.barHeight : Self.strandBar(lanes.count),
                                            enteredBeforeWindow: first.enteredBeforeWindow)
        }
        bundleShapes = shapes
        self.forkFrom = forkFrom
        func folded(_ laneID: String) -> Bool { laneByID[laneID]?.bundle.flatMap { shapes[$0] }.map { !$0.isOpen } ?? false }
        // On a folded strand, targets reach only halfway to the next strand.
        func half(_ laneID: String) -> CGFloat? {
            guard folded(laneID), let shape = laneByID[laneID]?.bundle.flatMap({ shapes[$0] }) else { return nil }
            return Self.strandPitch(shape.lanes.count) / 2
        }
        commitPoints = map.markers.compactMap { marker in
            laneByID[marker.laneID].map { (marker, CGPoint(x: xOf(marker.date), y: yOf($0)), min(6, half($0.id).map { $0 + 1 } ?? 6)) }
        }
        runTargets = map.spans.compactMap { span in
            guard let lane = laneByID[span.laneID] else { return nil }
            let thin = folded(lane.id)
            let height = thin ? lane.bundle.flatMap { shapes[$0]?.bar } ?? Self.barHeight : Self.barHeight
            let y = yOf(lane) + (thin ? 0 : CGFloat(span.slot) * Self.slotStep)
            let left = xOf(span.start)
            let right = max(xOf(span.end), left + 4)
            return (span, CGRect(x: left - 2, y: y - height / 2 - 2, width: right - left + 4, height: height + 4), y)
        }
        // The names on each row: its own lanes, and each bundle once.
        var units: [LabelUnit] = map.lanes.filter { $0.kind != .trunk && $0.bundle == nil }.map { lane in
            let extent = extentOf(lane)
            return LabelUnit(title: MapText.title(lane), row: lane.row, start: extent.start, end: extent.end,
                             reach: reachOf(lane), baseline: yOf(lane) - 7, enteredBeforeWindow: lane.enteredBeforeWindow,
                             primary: lane.isLive || lane.isHead, italic: lane.deleted, merged: lane.merge != nil,
                             laneID: lane.id, bundle: nil)
        }
        for shape in shapes.values {
            guard let row = shape.lanes.first?.row else { continue }
            units.append(LabelUnit(title: shape.bundle.title, row: row, start: shape.start, end: shape.end, reach: shape.reach,
                                   baseline: shape.titleY, enteredBeforeWindow: shape.enteredBeforeWindow,
                                   primary: shape.lanes.contains { $0.isLive || $0.isHead }, italic: false,
                                   merged: shape.lanes.contains { $0.merge != nil }, laneID: nil, bundle: shape))
        }
        units.sort { ($0.row, $0.start, $0.title) < ($1.row, $1.start, $1.title) }
        // Where each name goes. The last name on a row may slide left to fit at the right edge,
        // but never over the previous name or its merge back; a name without room for four
        // letters is left out. A bundle's title that does not fit gives way to its short form,
        // which keeps the count.
        func measure(_ text: String, primary: Bool, italic: Bool) -> CGFloat {
            let font = NSFont.systemFont(ofSize: 10, weight: primary ? .semibold : .medium)
            return ceil((text as NSString).size(withAttributes: [.font: font]).width) * (italic ? 1.05 : 1)
        }
        var rowRight: [Int: CGFloat] = [:]
        var nextStart: [String: CGFloat] = [:]
        for index in units.indices {
            let unit = units[index]
            let x = unit.start + (unit.enteredBeforeWindow ? 2 : 8)
            let next = units[(index + 1)...].first { $0.row == unit.row && $0.start > unit.start }?.start ?? width
            if let shape = unit.bundle { nextStart[shape.bundle.id] = next }
            let previous = rowRight[unit.row] ?? -.infinity
            let chevron: CGFloat = unit.bundle == nil ? 0 : 10
            let atEdge = next >= width
            func spot(_ full: CGFloat) -> (left: CGFloat, width: CGFloat) {
                let left = atEdge ? max(previous, min(x, width - full - chevron)) : x
                return (left, (atEdge ? width : next - 6) - left - chevron)
            }
            var text = unit.title
            var full = measure(text, primary: unit.primary, italic: unit.italic)
            var room = spot(full)
            if let shape = unit.bundle, full > room.width {
                text = ProjectMap.bundleShortTitle(shape.lanes.map(\.title))
                full = measure(text, primary: unit.primary, italic: false)
                room = spot(full)
            }
            let lineEnd = unit.end + 4
            guard room.left >= previous, room.width >= measure("abcd", primary: unit.primary, italic: unit.italic) else {
                // A bundle keeps at least its chevron, its only way to open.
                let left = max(previous, min(x, width - chevron))
                if unit.bundle != nil, left >= previous, left + chevron <= (atEdge ? width : next - 6) {
                    units[index].place = Place(text: "", left: left, width: 0, drawn: 0)
                    rowRight[unit.row] = max(left + chevron + 4, lineEnd)
                    continue
                }
                rowRight[unit.row] = max(previous, lineEnd)
                continue
            }
            let drawn = min(full, room.width)
            units[index].place = Place(text: text, left: room.left, width: room.width, drawn: drawn)
            let labelEnd = room.left + drawn + chevron + 4
            rowRight[unit.row] = unit.merged ? max(labelEnd, lineEnd) : labelEnd
        }
        labelUnits = units
        // An open bundle names each strand on its own line, from its fork, stopping before the
        // next name on its row, whose strands may run at the same depth.
        var strandLabels: [String: Place] = [:]
        for shape in shapes.values where shape.isOpen {
            let titles = shape.lanes.map(\.title)
            for lane in shape.lanes {
                let text = ProjectMap.strandTitle(lane.title, among: titles)
                let primary = lane.isLive || lane.isHead
                let full = measure(text, primary: primary, italic: lane.deleted)
                let fork = extentOf(lane).start
                let limit = min(width, (nextStart[shape.bundle.id] ?? width) - 6)
                let left = max(fork, min(fork + (lane.enteredBeforeWindow ? 2 : 8), limit - full))
                guard limit - left >= measure("abcd", primary: primary, italic: lane.deleted) else { continue }
                strandLabels[lane.id] = Place(text: text, left: left, width: limit - left, drawn: min(full, limit - left))
            }
        }
        self.strandLabels = strandLabels
        let placeByLane = Dictionary(units.compactMap { unit in unit.laneID.flatMap { id in unit.place.map { (id, $0) } } },
                                     uniquingKeysWith: { first, _ in first })
        // The trunk's name, drawn from the left edge.
        let trunkName = map.isGitCheckout ? map.lane(trunk)?.title ?? "" : (map.projectPath as NSString).lastPathComponent
        let trunkLabel: ClosedRange<CGFloat> = -2...min(200, measure(trunkName, primary: true, italic: false)) + 2
        laneTargets = map.lanes.map { lane in
            let extent = extentOf(lane)
            // A folded strand is only its line, reaching halfway to its neighbours.
            let place = lane.bundle == nil ? placeByLane[lane.id] : strandLabels[lane.id]
            return (lane, extent.start, extent.end, yOf(lane), half(lane.id) ?? 3,
                    lane.kind == .trunk ? trunkLabel : place.map { $0.left - 2...$0.left + $0.drawn + 2 })
        }
        bundleTargets = units.compactMap { unit in
            guard let shape = unit.bundle, let place = unit.place else { return nil }
            return (shape.lanes, place.left - 2, place.left + place.drawn + 12, shape.titleY + 7)
        }
    }

    var plotWidth: CGFloat { width - Self.trailingInset }

    /// The widest field the Map window scrolls through.
    static let maximumWidth: CGFloat = 8_000
    /// A field wider than the window is drawn in strips this wide, and only near what shows.
    static let stripWidth: CGFloat = 512
    /// The room each branch and each commit on the trunk adds to the Map window's field.
    static let roomPerItem: CGFloat = 32

    /// The field's width in the Map window, where it scrolls sideways: about `roomPerItem`
    /// for each branch and each commit on the trunk, and more where that leaves a lane's full
    /// label no room before the next lane on its row, a working day no room for its name, or
    /// most idle stretches no room for their length. The axis still gives busy hours the most
    /// of it, so a burst of commits minutes apart can share a capsule.
    static func naturalWidth(map: ProjectMap, calendar: ActivityCalendar) -> CGFloat {
        let axis = map.axis
        func position(_ date: Date) -> Double { axis.position(of: date) }
        func textWidth(_ text: String, _ weight: NSFont.Weight) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 10, weight: weight)]).width)
        }
        /// The plot width that gives `room` points to a stretch `share` of the axis wide.
        func plot(_ room: CGFloat, over share: Double) -> CGFloat? { share > 1e-6 ? room / CGFloat(share) : nil }
        // Each row's names: its own branches, and each bundle once, under its title and chevron.
        let lanes = map.lanes.filter { $0.kind != .trunk }
        var units = lanes.filter { $0.bundle == nil }.map { lane in
            (row: lane.row, start: lane.start, entered: lane.enteredBeforeWindow,
             room: textWidth(MapText.title(lane), lane.isLive || lane.isHead ? .semibold : .medium) * (lane.deleted ? 1.05 : 1))
        }
        for bundle in map.bundles {
            let strands = bundle.laneIDs.compactMap(map.lane)
            guard let first = strands.first else { continue }
            let weight: NSFont.Weight = strands.contains { $0.isLive || $0.isHead } ? .semibold : .medium
            units.append((row: first.row, start: strands.map(\.start).min() ?? first.start, entered: first.enteredBeforeWindow,
                          room: textWidth(bundle.title, weight) + 12))
        }
        let commits = map.markers.filter { $0.laneID == map.trunkID && $0.isBead }
        var needs = [CGFloat(units.count + commits.count) * Self.roomPerItem]
        // A lane's label starts 8 points in and must end 6 before the next lane on its row.
        for row in Dictionary(grouping: units, by: \.row).values {
            let ordered = row.sorted { $0.start < $1.start }
            for (unit, next) in zip(ordered, ordered.dropFirst()) {
                let start = unit.entered ? 0 : position(unit.start)
                plot(unit.room + 16, over: position(next.start) - start).map { needs.append($0) }
            }
        }
        // Day names as the axis draws them, from its start. Of the days that start inside one
        // fold, the first and, in a wide fold, the last can show: the day before needs room up
        // to the first, and the day after needs room from the last.
        func fold(_ date: Date) -> Int? { axis.segments.firstIndex { $0.isGap && $0.start < date && date < $0.end } }
        func name(_ date: Date) -> String {
            let day = calendar.day(of: date)
            return "\(DayFormat.weekday(day.weekday)) \(day.day)"
        }
        var days: [(date: Date, fold: Int?, width: CGFloat)] = []
        for date in [axis.start] + axis.dayStarts(calendar: calendar) {
            let day = (date: date, fold: fold(date), width: textWidth(name(date), .medium))
            if let current = day.fold, let last = days.last, last.fold == current {
                // Keep the fold's first and its latest start, measured by the wider name.
                if days.count >= 2, days[days.count - 2].fold == current { days.removeLast() }
                days.append((date, current, max(day.width, last.width)))
            } else {
                days.append(day)
            }
        }
        for (day, next) in zip(days, days.dropFirst()) where day.fold == nil || day.fold != next.fold {
            plot(day.width + 6, over: position(next.date) - position(day.date)).map { needs.append($0) }
        }
        // The last name must also end clear of "Now". A day only just begun would ask for any
        // width, so this asks for at most half as much again as the rest.
        if let last = days.last,
           let need = plot(last.width + textWidth("Now", .semibold) + 9 - Self.trailingInset, over: 1 - position(last.date)) {
            needs.append(min(need, (needs.max() ?? 0) * 1.5))
        }
        // Idle-stretch lengths: the axis shows the longest first, so most of them are enough.
        let idle = axis.gaps.filter { $0.duration >= 2 * 3_600 }
            .map { (center: ($0.lower + $0.upper) / 2, width: textWidth(MapText.idle($0.duration), .medium)) }
        let spacing = zip(idle, idle.dropFirst()).compactMap { plot(($0.width + $1.width) / 2 + 6, over: $1.center - $0.center) }
            .sorted()
        if !spacing.isEmpty { needs.append(spacing[Int(Double(spacing.count - 1) * 0.85)]) }
        return min(Self.maximumWidth, ceil((needs.max() ?? 0) + Self.trailingInset))
    }

    /// Where `item` sits, for bringing it into view: `x`, the stretch to show (a lane's start,
    /// where its label is, or a run's first stretch); `reach`, all of it, any of which showing
    /// is enough; and its y extent, or nil for something the field draws nowhere.
    func frame(of item: MapHit) -> (x: ClosedRange<CGFloat>, reach: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>?)? {
        switch item {
        case .live(let span):
            let bar = barRect(span)
            return (nowX - 10...nowX + 10, min(bar.minX, nowX - 10)...max(bar.maxX, nowX + 10), bar.minY - 6...bar.maxY + 6)
        case .span(let span):
            let bar = barRect(span)
            return (bar.minX...min(bar.maxX, bar.minX + 400), bar.minX...bar.maxX, bar.minY - 4...bar.maxY + 4)
        case .commit(let marker):
            guard let lane = lane(marker.laneID) else { return nil }
            let point = x(marker.date)
            return (point - 6...point + 6, point - 6...point + 6, y(of: lane) - 6...y(of: lane) + 6)
        case .cluster(let markers):
            let xs = markers.map { x($0.date) }
            let span = (xs.min() ?? 0) - 6...(xs.max() ?? 0) + 6
            return (span, span, trunkY - 6...trunkY + 6)
        case .lane(let lane):
            let extent = extent(of: lane)
            let reach = reach(of: lane)
            return (extent.start...min(extent.end, extent.start + 260), reach.start...reach.end,
                    y(of: lane) - 18...y(of: lane) + 6)
        case .fold(let gap):
            let span = CGFloat(gap.lower) * plotWidth...CGFloat(gap.upper) * plotWidth
            return (span, span, nil)
        case .group(let lanes):
            guard let shape = bundleShape(of: lanes) else { return nil }
            return (shape.start...min(shape.end, shape.start + 260), shape.start...shape.reach,
                    shape.titleY - 12...shape.bottom + 6)
        }
    }

    /// The bundle `lanes` are, when they are all of one.
    func bundleShape(of lanes: [ProjectMap.Lane]) -> BundleShape? {
        guard let id = lanes.first?.bundle, let shape = bundleShapes[id], shape.lanes.count == lanes.count,
              lanes.allSatisfy({ $0.bundle == id }) else { return nil }
        return shape
    }

    /// A strand of a folded bundle: a thin line close under its neighbour, without a name.
    func isFolded(_ laneID: String) -> Bool {
        laneByID[laneID]?.bundle.flatMap { bundleShapes[$0] }.map { !$0.isOpen } ?? false
    }

    /// The y a lane's fork leaves from: the strand above it in a bundle, else the lane it came from.
    func forkY(of lane: ProjectMap.Lane) -> CGFloat {
        forkFrom[lane.id] ?? lane.parentID.flatMap(self.lane).map(y(of:)) ?? trunkY
    }

    func x(_ date: Date) -> CGFloat { CGFloat(map.axis.position(of: date)) * plotWidth }

    var nowX: CGFloat { x(map.now) }

    func lane(_ id: String) -> ProjectMap.Lane? { laneByID[id] }

    func y(of lane: ProjectMap.Lane) -> CGFloat { strandY[lane.id] ?? laneY[lane.row] ?? 0 }

    var trunkY: CGFloat { laneY[0] ?? 19 }

    /// A run's y: its lane's, stacked by slot, except on a folded strand, where runs overlap.
    func y(of span: ProjectMap.Span) -> CGFloat {
        guard let lane = lane(span.laneID) else { return 0 }
        return y(of: lane) + (isFolded(lane.id) ? 0 : CGFloat(span.slot) * Self.slotStep)
    }

    func barRect(_ span: ProjectMap.Span) -> CGRect {
        let left = x(span.start)
        let right = max(x(span.end), left + 4)
        let height = isFolded(span.laneID) ? lane(span.laneID)?.bundle.flatMap { bundleShapes[$0]?.bar } ?? Self.barHeight
            : Self.barHeight
        return CGRect(x: left, y: y(of: span) - height / 2, width: right - left, height: height)
    }

    /// The x where a branch leaves the trunk (its fork, or its first work
    /// when that came earlier), and where its line ends.
    func extent(of lane: ProjectMap.Lane) -> (start: CGFloat, end: CGFloat) {
        let start = lane.enteredBeforeWindow ? 0 : x(lane.start)
        let end = max(x(lane.merge?.date ?? lane.end), start + 10)
        return (start, end)
    }

    /// Everything a lane's line covers: its fork, its line to its merge or to now, and each return.
    func reach(of lane: ProjectMap.Lane) -> (start: CGFloat, end: CGFloat) {
        let extent = extent(of: lane)
        let end = lane.merge == nil && (lane.isLive || lane.isHead) ? nowX : extent.end
        return (extent.start, max(end, extent.start, lane.returns.map { x($0.date) }.max() ?? end))
    }

    /// 1–4 for a density bin holding `count` edits.
    func level(_ count: Int) -> Int {
        count <= binLevels[0] ? 1 : count <= binLevels[1] ? 2 : count <= binLevels[2] ? 3 : 4
    }

    /// Live head first, then beads and commits, runs, bundle titles, lanes, and folds.
    func hit(at point: CGPoint) -> MapHit? {
        for span in map.spans where span.live != nil {
            if hypot(nowX - point.x, y(of: span) - point.y) <= 9 { return .live(span) }
        }
        for bead in beads where point.x >= bead.minX - 6 && point.x <= bead.maxX + 6 && abs(point.y - trunkY) <= 6 {
            return bead.markers.count == 1 ? .commit(bead.markers[0]) : .cluster(bead.markers)
        }
        var nearest: (marker: ProjectMap.Marker, distance: CGFloat)?
        for target in commitPoints where abs(target.point.y - point.y) <= target.reach {
            let distance = hypot(target.point.x - point.x, target.point.y - point.y)
            if distance <= target.reach, distance < (nearest?.distance ?? .infinity) { nearest = (target.marker, distance) }
        }
        if let nearest { return .commit(nearest.marker) }
        var closest: (span: ProjectMap.Span, offset: CGFloat)?
        // Of runs drawn over one another, the later is on top.
        for target in runTargets where target.rect.contains(point) {
            let offset = abs(target.y - point.y)
            if offset <= (closest?.offset ?? .infinity) { closest = (target.span, offset) }
        }
        if let run = closest?.span { return run.live != nil ? .live(run) : .span(run) }
        for target in bundleTargets where point.x >= target.start && point.x <= target.end && point.y >= target.y - 18
            && point.y < target.y - 3 {
            return .group(target.lanes)
        }
        var line: (lane: ProjectMap.Lane, offset: CGFloat)?
        for target in laneTargets {
            if let label = target.label, label.contains(point.x), point.y >= target.y - 18, point.y < target.y - 3 {
                return .lane(target.lane)
            }
            let offset = abs(target.y - point.y)
            if point.x >= target.start - 4, point.x <= target.end + 4, offset <= target.reach, offset < (line?.offset ?? .infinity) {
                line = (target.lane, offset)
            }
        }
        if let line { return .lane(line.lane) }
        for gap in map.axis.gaps where point.x >= CGFloat(gap.lower) * plotWidth && point.x <= CGFloat(gap.upper) * plotWidth {
            return .fold(gap)
        }
        return nil
    }
}

// MARK: - Field

/// The pinned axis over the lanes, which scroll when there are more than fit. In the Map
/// window the field also takes the width its labels and marks need, and scrolls sideways
/// when that is wider than the card.
private struct MapField: View {
    let map: ProjectMap
    let sources: [AgentSource]
    let calendar: ActivityCalendar
    let size: CGSize
    /// Written on hover and click, never observed here: only the overlay follows it.
    let hover: MapHoverModel
    let focusSourceID: String?
    let animatesLive: Bool
    /// Shown in the Map window, where the field may be wider than the card.
    let scrollsWide: Bool
    /// Every branch on its own lane rather than folded into streams.
    let allBranches: Bool
    /// Bundles drawn open, a lane per strand; a click on a bundle's title opens or folds it.
    let openBundles: Set<String>
    let toggleBundle: (ProjectMap.Bundle) -> Void
    /// The layout lasts until the map or the size changes, so hovering only redraws.
    @State private var cache = MapLayoutCache()
    @State private var scrollerStyle = NSScroller.preferredScrollerStyle
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let width = scrollsWide ? max(size.width, cache.naturalWidth(map: map, calendar: calendar)) : size.width
        // An always-shown sideways scroller takes the bottom of a wide field.
        let scroller = width > size.width && scrollerStyle == .legacy
            ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        let fieldAvailable = max(60, size.height - MapLayout.axisHeight - scroller)
        // About once a visible width, in steps, so a resize lays the field out again only now and then.
        let labelRepeat = width > size.width ? max(480, ((size.width * 0.85) / 160).rounded(.down) * 160) : nil
        let layout = cache.layout(map: map, width: width, availableHeight: fieldAvailable, calendar: calendar,
                                  labelRepeat: labelRepeat, openBundles: openBundles)
        let colors = Dictionary(uniqueKeysWithValues: Set(map.spans.map(\.sourceID)).map {
            ($0, ProfileColor.color($0, sources: sources))
        })
        let key = MapStaticKey(layout: cache.generation, focusSourceID: focusSourceID, colorScheme: colorScheme)
        let resting = MapEmphasis(sessionKey: nil, focusSourceID: focusSourceID, item: nil)
        let hover = self.hover
        let height = max(layout.fieldHeight, fieldAvailable)
        Group {
            if width > size.width {
                // The strips a window showing the field's end needs, until its scroll view reports.
                let last = Int((width - 1) / MapLayout.stripWidth)
                let first = Int(max(0, width - size.width - MapLayout.stripWidth / 2) / MapLayout.stripWidth)
                MapWideField(layout: layout, hover: hover, axis: axis(layout, key: key, hover: hover)) { scrollers in
                    lanes(layout, height: height, hover: hover) {
                        MapFieldStrips(layout: layout, key: key, colors: colors, resting: resting, hover: hover,
                                       opening: min(first, last)...last, scrollers: scrollers)
                    }
                }
                .id(MapScrollIdentity(projectPath: map.projectPath, range: map.range, allBranches: allBranches))
            } else {
                VStack(spacing: 0) {
                    axis(layout, key: key, hover: hover)
                    ScrollView(.vertical) {
                        lanes(layout, height: height, hover: hover) {
                            MapStaticCanvas(key: key) { context, size in
                                let flat = colors.mapValues { $0.flattened(in: context.environment) }
                                MapFieldPainter.draw(layout, colors: flat, emphasis: resting, height: size.height, in: &context)
                            }
                            .equatable()
                            MapFieldOverlay(layout: layout, key: key, colors: colors, hover: hover)
                        }
                    }
                    .scrollDisabled(layout.fieldHeight <= fieldAvailable)
                    .scrollIndicators(.automatic)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Branch map of \((map.projectPath as NSString).lastPathComponent), \(map.range.title.lowercased())")
        .accessibilityValue(accessibilitySummary)
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scrollerStyle = NSScroller.preferredScrollerStyle
        }
    }

    /// The days and folds over the lanes; a fold names its length on hover.
    private func axis(_ layout: MapLayout, key: MapStaticKey, hover: MapHoverModel) -> some View {
        MapStaticCanvas(key: key) { context, _ in
            MapAxisPainter.draw(layout, in: &context)
        }
        .equatable()
        .frame(height: MapLayout.axisHeight)
        .onContinuousHover { phase in
            if case .active(let point) = phase, let gap = layout.map.axis.gaps.first(where: {
                point.x >= CGFloat($0.lower) * layout.plotWidth - 3 && point.x <= CGFloat($0.upper) * layout.plotWidth + 3
            }) {
                hover.hover(MapHit.fold(gap).id)
            } else {
                hover.hover(nil)
            }
        }
    }

    /// The lanes' `drawing`, with the live sessions' glyphs, hover and clicks.
    private func lanes<Drawing: View>(_ layout: MapLayout, height: CGFloat, hover: MapHoverModel,
                                      @ViewBuilder drawing: () -> Drawing) -> some View {
        ZStack(alignment: .topLeading) {
            drawing()
            ForEach(map.spans.filter { $0.live != nil }) { (span: ProjectMap.Span) in
                StatusGlyph(kind: span.live == LiveStatus.waiting.rawValue ? .needsInput : .working,
                            size: 10, animates: animatesLive)
                    .position(x: layout.nowX, y: layout.y(of: span))
            }
        }
        .frame(width: layout.width, height: height, alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): hover.hover(layout.hit(at: point)?.id)
            case .ended: hover.hover(nil)
            }
        }
        .gesture(SpatialTapGesture().onEnded { value in
            let hit = layout.hit(at: value.location)
            if case .group(let lanes)? = hit, let shape = layout.bundleShape(of: lanes) { toggleBundle(shape.bundle) }
            hover.select(hit?.id)
        })
    }

    private var accessibilitySummary: String {
        let branches = map.lanes.filter { $0.kind != .trunk }.map(\.title)
        let profiles = Set(map.spans.map(\.sourceID)).count
        var text = "\(branches.count) branches with edits, \(map.mergeCount) merged into \(map.lane(map.trunkID)?.title ?? "main"), "
            + "\(map.sessionCount) sessions by \(profiles) profiles"
        if let live = map.spans.last(where: { $0.live != nil }), let lane = map.lane(live.laneID) {
            text += ", 1 \(live.live == LiveStatus.waiting.rawValue ? "needs input" : "working") on \(lane.title)"
        }
        return text + ". Branches: " + branches.joined(separator: ", ")
    }
}

/// The Map window's field when it is wider than the card. The lanes scroll both ways in one
/// scroll view, so its scrollers sit on the card's edges, and the axis above follows them
/// sideways rather than scrolling on its own. It opens at now; a new project or range is a
/// new field, which opens at now again.
private struct MapWideField<Axis: View, Lanes: View>: View {
    let layout: MapLayout
    let hover: MapHoverModel
    let axis: Axis
    @ViewBuilder let lanes: (MapScrollers) -> Lanes
    /// Not observed here: only the strips follow what shows.
    @State private var scrollers = MapScrollers()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal) {
                // Room past the end, so the axis can follow lanes that a vertical scroller narrows.
                axis
                    .frame(width: layout.width)
                    .padding(.trailing, 24)
                    .background(MapScrollProbe(scrollers: scrollers, role: .axis))
            }
            .scrollDisabled(true)
            .scrollIndicators(.never)
            .defaultScrollAnchor(.trailing)
            .frame(height: MapLayout.axisHeight)
            ScrollView([.horizontal, .vertical]) {
                lanes(scrollers)
                    .background(MapScrollProbe(scrollers: scrollers, role: .field))
            }
            .scrollBounceBehavior(.basedOnSize)
            .defaultScrollAnchor(.topTrailing)
        }
        .onReceive(hover.$selected) { reveal($0) }
    }

    /// Brings a pinned item into view when none of it shows, such as a branch the details
    /// panel pinned, scrolling only as far as that takes; one in view stays where it is.
    private func reveal(_ id: MapHitID?) {
        guard let id, let item = MapHit.resolve(id, in: layout.map), let frame = layout.frame(of: item) else { return }
        let animated = !reduceMotion && !rendersStill
        // After this update's layout, so a new map's positions are in place.
        DispatchQueue.main.async { [scrollers] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = animated ? 0.3 : 0
                context.allowsImplicitAnimation = animated
                scrollers.reveal(x: frame.x, reach: frame.reach, y: frame.y)
            }
        }
    }
}

/// Text widths by style and text, measured once per layout.
final class MapTextWidths {
    private var widths: [String: CGFloat] = [:]

    func width(of text: String, style: String, measure: () -> CGFloat) -> CGFloat {
        let key = style + "\u{0}" + text
        if let width = widths[key] { return width }
        let width = measure()
        widths[key] = width
        return width
    }
}

/// A field wider than the window, drawn in strips `MapLayout.stripWidth` wide and only near
/// the part that shows, so its memory follows the window rather than the field. Each strip
/// records once until the layout changes and has its own hover layer.
private struct MapFieldStrips: View {
    let layout: MapLayout
    let key: MapStaticKey
    let colors: [String: Color]
    let resting: MapEmphasis
    let hover: MapHoverModel
    /// The strips for a window showing the field's end, until the scroll view reports what shows.
    let opening: ClosedRange<Int>
    @ObservedObject var scrollers: MapScrollers

    var body: some View {
        let last = Int((layout.width - 1) / MapLayout.stripWidth)
        // Strips past the end were measured before the field narrowed, which leaves it at its end.
        let measured = scrollers.strips.flatMap { $0.upperBound <= last ? $0 : nil }
        let strips = (measured ?? opening).clamped(to: 0...max(0, last))
        ZStack(alignment: .topLeading) {
            ForEach(Array(strips), id: \.self) { index in
                let minX = CGFloat(index) * MapLayout.stripWidth
                let visible = minX...min(layout.width, minX + MapLayout.stripWidth)
                ZStack(alignment: .topLeading) {
                    MapStaticCanvas(key: key) { context, size in
                        let flat = colors.mapValues { $0.flattened(in: context.environment) }
                        context.translateBy(x: -minX, y: 0)
                        MapFieldPainter.draw(layout, colors: flat, emphasis: resting, height: size.height, visible: visible,
                                             in: &context)
                    }
                    .equatable()
                    MapFieldOverlay(layout: layout, key: key, colors: colors, hover: hover, strip: visible)
                }
                .frame(width: visible.upperBound - minX)
                .clipShape(MapStripClip())
                .offset(x: minX)
            }
        }
        .frame(width: layout.width, alignment: .topLeading)
    }
}

/// A strip's own columns, open below like a single canvas, so the day lines, fold shading
/// and veil still run on under the lanes when the field is pulled past its end.
private struct MapStripClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + 400))
    }
}

/// A project, range, or folding of branches opens at now; other changes keep the field where
/// it was scrolled.
private struct MapScrollIdentity: Hashable {
    let projectPath: String
    let range: MapRange
    let allBranches: Bool
}

/// The wide field's scroll views: the lanes' own, which scrolls both ways, and the axis's,
/// kept at the same sideways offset. AppKit moves the axis in the same pass as the lanes, so
/// the two never part; and it reveals an item, since SwiftUI cannot scroll just far enough.
@MainActor
private final class MapScrollers: ObservableObject {
    private weak var axis: NSView?
    private weak var field: NSView?
    /// The field's strips within half a strip of what shows, by index; nil until the field is
    /// on screen.
    @Published private(set) var strips: ClosedRange<Int>?
    private var observers: [NSObjectProtocol] = []
    /// Moving the axis reports a scroll of its own, which must not move it again.
    private var isFollowing = false

    func attach(_ view: NSView, role: MapScrollProbe.Role) {
        switch role {
        case .axis:
            guard view !== axis else { return }
            axis = view
            observe(view, follow: true)
        case .field:
            guard view !== field else { return }
            field = view
            observe(view, follow: true)
            updateStrips()
        }
        follow()
    }

    /// Follows the clip view around `view` as it scrolls and resizes.
    private func observe(_ view: NSView, follow: Bool) {
        guard let clip = view.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.follow()
                    self?.updateStrips()
                }
            })
        }
    }

    /// Keeps the axis scrolled sideways exactly as far as the lanes.
    private func follow() {
        guard !isFollowing, let lanes = field?.enclosingScrollView?.contentView,
              let scrollView = axis?.enclosingScrollView else { return }
        let clip = scrollView.contentView
        guard clip.bounds.origin.x != lanes.bounds.origin.x else { return }
        isFollowing = true
        defer { isFollowing = false }
        clip.setBoundsOrigin(NSPoint(x: lanes.bounds.origin.x, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Publishes the strips near what shows, on the next turn of the run loop, so a scroll or
    /// layout in progress never changes views in the middle of an update.
    func updateStrips() {
        DispatchQueue.main.async { [weak self] in
            // A field the window has just dropped, such as when it grew wide enough to show
            // all of it, reports an infinite visible rect.
            guard let self, let field = self.field, field.window != nil else { return }
            let visible = field.visibleRect.intersection(field.bounds)
            guard !visible.isNull, visible.width > 0 else { return }
            let step = MapLayout.stripWidth
            let strips = Int(max(0, visible.minX - step / 2) / step)...Int((visible.maxX + step / 2) / step)
            if strips != self.strips { self.strips = strips }
        }
    }

    /// Scrolls only if none of `reach` shows sideways, or none of `y` up and down, and then
    /// only as far as it takes to show `x` and `y` with some of what is around them.
    func reveal(x: ClosedRange<CGFloat>, reach: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>?) {
        guard let field, field.window != nil else { return }
        let visible = field.visibleRect
        let showsAcross = Self.shows(reach, within: visible.minX...visible.maxX)
        var target = CGRect(x: visible.midX, y: visible.midY, width: 1, height: 1)
        if !showsAcross {
            target.origin.x = x.lowerBound - 120
            target.size.width = x.upperBound - x.lowerBound + 240
        }
        if let y, !Self.shows(y, within: visible.minY...visible.maxY) {
            target.origin.y = y.lowerBound - 40
            target.size.height = y.upperBound - y.lowerBound + 80
        }
        field.scrollToVisible(target)
    }

    private static func shows(_ range: ClosedRange<CGFloat>, within visible: ClosedRange<CGFloat>) -> Bool {
        range.upperBound > visible.lowerBound + 8 && range.lowerBound < visible.upperBound - 8
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

/// An empty AppKit view under a scroll view's content, at the content's own coordinates,
/// through which `MapScrollers` reads what shows and scrolls.
private struct MapScrollProbe: NSViewRepresentable {
    enum Role { case axis, field }

    let scrollers: MapScrollers
    let role: Role

    final class Probe: NSView {
        var scrollers: MapScrollers?
        var role = Role.field
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { scrollers?.attach(self, role: role) }
        }

        override func setFrameSize(_ size: NSSize) {
            super.setFrameSize(size)
            if role == .field { scrollers?.updateStrips() }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.scrollers = scrollers
        probe.role = role
        return probe
    }

    func updateNSView(_ view: Probe, context: Context) {}
}

/// One layout per map and size. A reference, so a hover's redraw reuses it;
/// `generation` changes with each new layout and keys the static drawing.
private final class MapLayoutCache {
    private var key: (map: ProjectMap, width: CGFloat, height: CGFloat, labelRepeat: CGFloat?, open: Set<String>)?
    private var cached: MapLayout?
    private(set) var generation = 0
    private var natural: (map: ProjectMap, width: CGFloat)?

    func naturalWidth(map: ProjectMap, calendar: ActivityCalendar) -> CGFloat {
        if let natural, natural.map == map { return natural.width }
        let width = MapLayout.naturalWidth(map: map, calendar: calendar)
        natural = (map, width)
        return width
    }

    func layout(map: ProjectMap, width: CGFloat, availableHeight: CGFloat, calendar: ActivityCalendar,
                labelRepeat: CGFloat?, openBundles: Set<String>) -> MapLayout {
        if let key, let cached, key.width == width, key.height == availableHeight, key.labelRepeat == labelRepeat,
           key.open == openBundles, key.map == map { return cached }
        let layout = MapLayout(map: map, width: width, availableHeight: availableHeight, calendar: calendar,
                               labelRepeat: labelRepeat, openBundles: openBundles)
        key = (map, width, availableHeight, labelRepeat, openBundles)
        cached = layout
        generation += 1
        return layout
    }
}

/// What the pointer is over, drawn above the static field: a hovered or pinned
/// session veils the rest and is drawn again at full strength with its moves, a
/// lane brightens, a commit or merge gets a ring. Veil and lit item are one
/// layer, recorded once per layout and lit item, never per frame. It fades in and
/// out whole, so the lit item holds its strength while the veil comes and goes,
/// and two layers hand over by adding up, so a veil both draw stays steady while
/// one session hands over to the next. Nothing is here at rest.
private struct MapFieldOverlay: View {
    let layout: MapLayout
    /// The static drawing's key: a new layout or appearance records the layer again.
    let key: MapStaticKey
    let colors: [String: Color]
    @ObservedObject var hover: MapHoverModel
    /// In a field drawn in strips, the x range of this one's strip.
    var strip: ClosedRange<CGFloat>?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill

    var body: some View {
        let layout = self.layout
        let colors = self.colors
        let strip = self.strip
        let item = hover.emphasized.flatMap { MapHit.resolve($0, in: layout.map) }
        let lit = MapFieldLitKey.identity(of: item)
        let veiled = item?.sessionKey != nil
        let dissolves = motion(MapMotion.crossfade) != nil
        ZStack(alignment: .topLeading) {
            if let item, let lit {
                MapStaticCanvas(key: MapFieldLitKey(base: key, item: lit)) { context, size in
                    let flat = colors.mapValues { $0.flattened(in: context.environment) }
                    if let strip { context.translateBy(x: -strip.lowerBound, y: 0) }
                    MapFieldPainter.drawEmphasis(item, layout, colors: flat, height: size.height, visible: strip, in: &context)
                }
                .equatable()
                .modifier(MapDissolve(active: dissolves))
                .id(lit)
                .transition(.opacity)
            }
        }
        // The first that changed wins: a new layout lands at once, the veil coming or going
        // fades on its curve, and one lit item hands over to the next in a crossfade.
        .animation(nil, value: key)
        .animation(motion(MapMotion.veil), value: veiled)
        .animation(motion(MapMotion.crossfade), value: lit)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(MapDissolveGroup(active: dissolves))
        .allowsHitTesting(false)
    }

    /// `base`, or nil (an instant change) under Reduce Motion and in still renders.
    private func motion(_ base: Animation) -> Animation? {
        MapMotion.animation(base, reduceMotion: reduceMotion, still: rendersStill)
    }
}

/// What the overlay's lit layer depends on: the static drawing's key and the item it lights.
private struct MapFieldLitKey: Equatable {
    let base: MapStaticKey
    let item: MapHitID

    /// What `item` lights, or nil when it lights nothing in the field: a fold. Every run of
    /// a session lights the same runs, moves and rings, so
    /// sliding along one session's runs records and crossfades nothing.
    static func identity(of item: MapHit?) -> MapHitID? {
        guard let item else { return nil }
        switch item {
        case .live(let span), .span(let span): return .run(span.sessionKey, 0)
        case .commit, .cluster, .lane, .group: return item.id
        case .fold: return nil
        }
    }
}

/// What stands out: a hovered or selected session, and a focused profile.
private struct MapEmphasis {
    let sessionKey: String?
    let focusSourceID: String?
    let item: MapHit?

    func barOpacity(_ span: ProjectMap.Span) -> Double {
        if let focusSourceID, span.sourceID != focusSourceID { return 0.25 }
        if let sessionKey, span.sessionKey != sessionKey { return 0.35 }
        return 1
    }

    /// A lane drawn brighter: the hovered one, or each strand of a hovered bundle.
    func lights(_ lane: ProjectMap.Lane) -> Bool {
        switch item {
        case .lane(let hovered)?: return hovered.id == lane.id
        case .group(let lanes)?: return lanes.contains { $0.id == lane.id }
        default: return false
        }
    }
}

// MARK: - Axis

private enum MapAxisPainter {
    static func draw(_ layout: MapLayout, in context: inout GraphicsContext) {
        let width = layout.width
        let now = context.resolve(Text("Now").font(Theme.Typeface.micro.weight(.semibold)).foregroundColor(.primary))
        let nowWidth = now.measure(in: CGSize(width: 80, height: 20)).width
        context.draw(now, at: CGPoint(x: width, y: 0), anchor: .topTrailing)
        var lastRight: CGFloat = -.infinity
        let days = [layout.map.axis.start] + layout.map.axis.dayStarts(calendar: layout.calendar)
        for (index, start) in days.enumerated() {
            let day = layout.calendar.day(of: start)
            let text = "\(DayFormat.weekday(day.weekday)) \(day.day)"
            let resolved = context.resolve(Text(text).font(Theme.Typeface.micro).foregroundColor(.secondary))
            let size = resolved.measure(in: CGSize(width: 120, height: 20))
            let left = index == 0 ? 0 : layout.x(start) + 3
            guard left >= lastRight + 6, left + size.width <= width - nowWidth - 6 else { continue }
            context.draw(resolved, at: CGPoint(x: left, y: 0), anchor: .topLeading)
            lastRight = left + size.width
        }
        // Folds: a break glyph each; the longest show their true length.
        var taken: [ClosedRange<CGFloat>] = []
        for gap in layout.map.axis.gaps.sorted(by: { $0.duration > $1.duration }) {
            let center = CGFloat(gap.lower + gap.upper) / 2 * layout.plotWidth
            var glyph = Path()
            for offset in [-1.5, 1.5] as [CGFloat] {
                glyph.move(to: CGPoint(x: center + offset - 1, y: 31))
                glyph.addLine(to: CGPoint(x: center + offset + 1, y: 27))
            }
            context.stroke(glyph, with: .color(Color.primary.opacity(0.38)), lineWidth: 1)
            guard gap.duration >= 2 * 3_600 else { continue }
            let label = context.resolve(Text(MapText.idle(gap.duration)).font(Theme.Typeface.micro)
                .foregroundColor(Color.primary.opacity(0.4)))
            let labelWidth = label.measure(in: CGSize(width: 60, height: 20)).width
            let span = (center - labelWidth / 2 - 3)...(center + labelWidth / 2 + 3)
            guard span.lowerBound >= 0, span.upperBound <= width, !taken.contains(where: { $0.overlaps(span) }) else { continue }
            taken.append(span)
            context.draw(label, at: CGPoint(x: center, y: 14), anchor: .top)
        }
        var hairline = Path()
        hairline.move(to: CGPoint(x: 0, y: MapLayout.axisHeight - 0.5))
        hairline.addLine(to: CGPoint(x: width, y: MapLayout.axisHeight - 0.5))
        context.stroke(hairline, with: .color(Color.primary.opacity(0.08)), lineWidth: 1)
    }
}

// MARK: - Field painter

private enum MapFieldPainter {
    private static func ink(_ opacity: Double) -> Color { Color.primary.opacity(opacity) }

    /// `height` is the canvas's: a tall window's field runs past the lanes, and
    /// the day lines and fold shading must reach its bottom. With `visible`, the x range
    /// of one strip of a wide field, marks wholly outside it are skipped.
    static func draw(_ layout: MapLayout, colors: [String: Color], emphasis: MapEmphasis, height: CGFloat,
                     visible: ClosedRange<CGFloat>? = nil, in context: inout GraphicsContext) {
        // One layer, so knockouts clear only marks drawn here, never the card behind.
        context.drawLayer { layer in
            drawBackground(layout, height: height, in: &layer)
            for lane in layout.map.lanes where lane.kind != .trunk && reaches(layout.reach(of: lane).start, layout.reach(of: lane).end, visible) {
                drawLane(lane, layout, emphasis: emphasis, in: &layer)
            }
            drawTrunk(layout, in: &layer)
            for span in layout.map.spans where reaches(layout.barRect(span).minX, layout.barRect(span).maxX, visible) {
                drawRun(span, layout, color: colors[span.sourceID] ?? .gray, opacity: emphasis.barOpacity(span), in: &layer)
            }
            drawOverflow(layout, visible: visible, in: &layer)
            drawThreads(layout, colors: colors, emphasis: emphasis, visible: visible, in: &layer)
            drawCommits(layout, ring: Theme.Palette.canvas.flattened(in: layer.environment).opacity(0.9), visible: visible,
                        in: &layer)
            drawBeads(layout, visible: visible, in: &layer)
            drawLabels(layout, visible: visible, in: &layer)
            if let item = emphasis.item { drawHighlight(item, layout, visible: visible, in: &layer) }
        }
    }

    /// Whether marks between `a` and `b`, in either order, reach into `visible`, with room for
    /// strokes, rings and knockouts; always without a `visible` range.
    private static func reaches(_ a: CGFloat, _ b: CGFloat, _ visible: ClosedRange<CGFloat>?) -> Bool {
        guard let visible else { return true }
        return max(a, b) + 8 >= visible.lowerBound && min(a, b) - 8 <= visible.upperBound
    }

    /// The overlay: a session veils the field and is drawn again at full strength with its
    /// moves and rings; a lane is brightened; a commit or merge gets a ring.
    /// With `visible`, the x range of one strip of a wide field, it draws only that strip's part.
    static func drawEmphasis(_ item: MapHit, _ layout: MapLayout, colors: [String: Color], height: CGFloat,
                             visible: ClosedRange<CGFloat>? = nil, in context: inout GraphicsContext) {
        let emphasis = MapEmphasis(sessionKey: item.sessionKey, focusSourceID: nil, item: item)
        context.drawLayer { layer in
            if let key = item.sessionKey {
                let veil = Theme.Palette.canvas.flattened(in: layer.environment).opacity(0.62)
                let left = visible.map { $0.lowerBound - 8 } ?? 0
                let right = visible.map { $0.upperBound + 8 } ?? layout.width
                layer.fill(Path(CGRect(x: left, y: 0, width: right - left, height: max(layout.fieldHeight + 400, height))),
                           with: .color(veil))
                for span in layout.map.spans
                where span.sessionKey == key && reaches(layout.barRect(span).minX, layout.barRect(span).maxX, visible) {
                    drawRun(span, layout, color: colors[span.sourceID] ?? .gray, opacity: 1, in: &layer)
                }
                drawThreads(layout, colors: colors, emphasis: emphasis, onlySession: key, visible: visible, in: &layer)
            } else if case .lane(let lane) = item {
                drawLane(lane, layout, emphasis: emphasis, in: &layer)
                clearBars(on: [lane.id], layout, visible: visible, in: &layer)
            } else if case .group(let lanes) = item {
                for lane in lanes { drawLane(lane, layout, emphasis: emphasis, in: &layer) }
                clearBars(on: Set(lanes.map(\.id)), layout, visible: visible, in: &layer)
            }
            drawHighlight(item, layout, visible: visible, in: &layer)
        }
    }

    /// Clears the brightened lines from under the bars on `laneIDs`, so the bars below show as
    /// they were rather than crossed out.
    private static func clearBars(on laneIDs: Set<String>, _ layout: MapLayout, visible: ClosedRange<CGFloat>?,
                                  in context: inout GraphicsContext) {
        for span in layout.map.spans where laneIDs.contains(span.laneID) {
            let bar = layout.barRect(span)
            guard reaches(bar.minX, bar.maxX, visible) else { continue }
            knockout(Path(roundedRect: bar.insetBy(dx: -1, dy: -1), cornerRadius: bar.height / 2 + 1), in: &context)
        }
    }

    private static func knockout(_ path: Path, in context: inout GraphicsContext) {
        var clear = context
        clear.blendMode = .destinationOut
        clear.fill(path, with: .color(.black))
    }

    // MARK: Background

    private static func drawBackground(_ layout: MapLayout, height canvasHeight: CGFloat, in context: inout GraphicsContext) {
        let height = max(layout.fieldHeight + 400, canvasHeight)
        for gap in layout.map.axis.gaps {
            let left = CGFloat(gap.lower) * layout.plotWidth
            let right = CGFloat(gap.upper) * layout.plotWidth
            context.fill(Path(CGRect(x: left, y: 0, width: right - left, height: height)), with: .color(ink(0.035)))
        }
        for start in layout.map.axis.dayStarts(calendar: layout.calendar) {
            var line = Path()
            line.move(to: CGPoint(x: layout.x(start), y: 0))
            line.addLine(to: CGPoint(x: layout.x(start), y: height))
            context.stroke(line, with: .color(ink(0.12)), style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
        }
        var now = Path()
        now.move(to: CGPoint(x: layout.nowX, y: 0))
        now.addLine(to: CGPoint(x: layout.nowX, y: height))
        context.stroke(now, with: .color(ink(0.30)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    // MARK: Lanes

    private static func drawTrunk(_ layout: MapLayout, in context: inout GraphicsContext) {
        guard layout.lane(layout.map.trunkID) != nil else { return }
        let y = layout.trunkY
        // Dashed until the repository's first commit; a project with no Git history is dashed throughout.
        let root = layout.map.rootCommitDate.map { max(layout.x($0), 0) } ?? (layout.map.hasCommits ? 0 : layout.nowX)
        if root > 0 {
            // Before the first commit in range: work that predates the repository's history.
            var before = Path()
            before.move(to: CGPoint(x: 0, y: y))
            before.addLine(to: CGPoint(x: root, y: y))
            context.stroke(before, with: .color(ink(0.42)), style: StrokeStyle(lineWidth: 2, dash: [3, 3]))
        }
        var path = Path()
        path.move(to: CGPoint(x: root, y: y))
        path.addLine(to: CGPoint(x: layout.nowX, y: y))
        context.stroke(path, with: .color(ink(0.55)), style: StrokeStyle(lineWidth: 2.25, lineCap: .round))
    }

    private static func drawLane(_ lane: ProjectMap.Lane, _ layout: MapLayout, emphasis: MapEmphasis,
                                 in context: inout GraphicsContext) {
        let y = layout.y(of: lane)
        let radius: CGFloat = 5
        let extent = layout.extent(of: lane)
        // A branch leaves the lane it came from and returns to the lane it
        // merged into: the trunk, or an integration branch above it. A bundle's
        // strand splits off the strand above it.
        let fromY = layout.forkY(of: lane)
        let intoY = lane.merge.flatMap { layout.lane($0.intoLaneID) }.map(layout.y(of:)) ?? layout.trunkY
        var path = Path()
        if lane.enteredBeforeWindow {
            path.move(to: CGPoint(x: extent.start, y: y))
        } else {
            let turn: CGFloat = fromY < y ? -radius : radius
            path.move(to: CGPoint(x: extent.start, y: fromY))
            path.addLine(to: CGPoint(x: extent.start, y: y + turn))
            path.addQuadCurve(to: CGPoint(x: extent.start + radius, y: y), control: CGPoint(x: extent.start, y: y))
        }
        let end = lane.merge == nil && (lane.isLive || lane.isHead) ? layout.nowX : extent.end
        if lane.merge != nil {
            let turn: CGFloat = intoY < y ? -radius : radius
            path.addLine(to: CGPoint(x: end - radius, y: y))
            path.addQuadCurve(to: CGPoint(x: end, y: y + turn), control: CGPoint(x: end, y: y))
            path.addLine(to: CGPoint(x: end, y: intoY))
        } else {
            path.addLine(to: CGPoint(x: end, y: y))
        }
        let opacity = emphasis.lights(lane) ? 0.60 : 0.30
        let dash: [CGFloat] = lane.deleted ? [3, 2] : []
        context.stroke(path, with: .color(ink(opacity)),
                       style: StrokeStyle(lineWidth: layout.isFolded(lane.id) ? 1 : 1.25, lineCap: .round, dash: dash))
        // A stream's members merged one by one: a fainter return for each.
        for merge in lane.returns where merge.sha != lane.merge?.sha {
            let x = layout.x(merge.date)
            let target = layout.lane(merge.intoLaneID).map(layout.y(of:)) ?? layout.trunkY
            var back = Path()
            back.move(to: CGPoint(x: x - radius, y: y))
            back.addQuadCurve(to: CGPoint(x: x, y: y + (target < y ? -radius : radius)), control: CGPoint(x: x, y: y))
            back.addLine(to: CGPoint(x: x, y: target))
            context.stroke(back, with: .color(ink(opacity * 0.7)), style: StrokeStyle(lineWidth: 1, lineCap: .round))
        }
    }

    // MARK: Runs

    /// A presence bar in the profile color, with density bins: brighter where
    /// edits were denser, hatched where subagents made most of them.
    private static func drawRun(_ span: ProjectMap.Span, _ layout: MapLayout, color: Color, opacity: Double,
                                in context: inout GraphicsContext) {
        let bar = layout.barRect(span)
        let shape = Path(roundedRect: bar, cornerRadius: bar.height / 2)
        knockout(Path(roundedRect: bar.insetBy(dx: -1, dy: -1), cornerRadius: bar.height / 2 + 1), in: &context)
        var layer = context
        layer.opacity = opacity
        if span.sourceID == ProjectMap.cloudSourceID {
            // A cloud session records commits, not edits: an outlined bar.
            layer.fill(shape, with: .color(color.opacity(0.45)))
            layer.stroke(Path(roundedRect: bar.insetBy(dx: 0.5, dy: 0.5), cornerRadius: bar.height / 2),
                         with: .color(color), lineWidth: 1)
            return
        }
        layer.fill(shape, with: .color(color.opacity(0.26)))
        guard span.editCount > 0 else { return }
        let bins = layout.bins[span.id] ?? []
        layer.drawLayer { inner in
            inner.clip(to: shape)
            var hatched: [ClosedRange<Int>] = []
            for count in bins {
                let bin = count.bin
                let rect = CGRect(x: bar.minX + CGFloat(bin) * 2, y: bar.minY, width: 2, height: bar.height)
                if count.delegated > count.direct {
                    if let last = hatched.last, bin - last.upperBound <= 2 {
                        hatched[hatched.count - 1] = last.lowerBound...bin
                    } else {
                        hatched.append(bin...bin)
                    }
                    continue
                }
                let level = layout.level(count.direct + count.delegated)
                inner.fill(Path(rect), with: .color(color.opacity([0.5, 0.68, 0.84, 1.0][level - 1])))
            }
            for run in hatched {
                let rect = CGRect(x: bar.minX + CGFloat(run.lowerBound) * 2, y: bar.minY,
                                  width: CGFloat(run.count) * 2, height: bar.height)
                inner.fill(Path(rect), with: .color(color.opacity(0.45)))
                var hatch = Path()
                var x = rect.minX - rect.height
                while x < rect.maxX {
                    hatch.move(to: CGPoint(x: x, y: rect.maxY))
                    hatch.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                    x += 3
                }
                var clipped = inner
                clipped.clip(to: Path(rect))
                clipped.stroke(hatch, with: .color(color), lineWidth: 1)
            }
        }
    }

    /// "+N" once per cluster of runs stacked past the last slot of a lane.
    private static func drawOverflow(_ layout: MapLayout, visible: ClosedRange<CGFloat>?, in context: inout GraphicsContext) {
        let extra = layout.map.spans.filter { $0.overflow > 0 && !layout.isFolded($0.laneID) }
        for (_, spans) in Dictionary(grouping: extra, by: \.laneID) {
            var clusters: [(right: CGFloat, y: CGFloat, count: Int)] = []
            for span in spans.sorted(by: { $0.start < $1.start }) {
                let bar = layout.barRect(span)
                if let last = clusters.last, bar.minX - last.right < 24 {
                    clusters[clusters.count - 1] = (max(last.right, bar.maxX), last.y, last.count + 1)
                } else {
                    clusters.append((bar.maxX, bar.midY, 1))
                }
            }
            for cluster in clusters where reaches(cluster.right, cluster.right + 30, visible) {
                let more = context.resolve(Text("+\(cluster.count)").font(Theme.Typeface.micro).foregroundColor(.secondary))
                context.draw(more, at: CGPoint(x: cluster.right + 3, y: cluster.y), anchor: .leading)
            }
        }
    }

    /// A live session's thread to now, and the hovered session's moves between lanes: from
    /// the run it last finished to each run it began with nothing else of it still running.
    /// A run begun beside another is work side by side, which needs no thread, and so is a
    /// hop between two strands of one bundle.
    private static func drawThreads(_ layout: MapLayout, colors: [String: Color], emphasis: MapEmphasis,
                                    onlySession: String? = nil, visible: ClosedRange<CGFloat>? = nil,
                                    in context: inout GraphicsContext) {
        let spans = onlySession.map { key in layout.map.spans.filter { $0.sessionKey == key } } ?? layout.map.spans
        let bySession = Dictionary(grouping: spans, by: \.sessionKey)
        for (key, spans) in bySession {
            let live = spans.first { $0.live != nil }
            let selectedSession = emphasis.sessionKey == key
            guard live != nil || selectedSession, let first = spans.first else { continue }
            let color = colors[first.sourceID] ?? .gray
            if let live, reaches(layout.barRect(live).maxX, layout.nowX, visible) {
                let y = layout.y(of: live)
                var thread = Path()
                thread.move(to: CGPoint(x: layout.barRect(live).maxX, y: y))
                thread.addLine(to: CGPoint(x: layout.nowX, y: y))
                context.stroke(thread, with: .color(color.opacity(0.5)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
            let ordered = spans.sorted { ($0.start, $0.index) < ($1.start, $1.index) }
            var latest: ProjectMap.Span?
            for to in ordered {
                defer { if to.end >= latest?.end ?? .distantPast { latest = to } }
                guard let from = latest, from.end <= to.start,
                      selectedSession || to.start.timeIntervalSince(from.end) <= 3 * 3_600 else { continue }
                if let bundle = layout.lane(from.laneID)?.bundle, bundle == layout.lane(to.laneID)?.bundle { continue }
                let start = CGPoint(x: layout.barRect(from).maxX, y: layout.y(of: from))
                let end = CGPoint(x: layout.barRect(to).minX, y: layout.y(of: to))
                guard end.x - start.x > 1 || start.y != end.y, reaches(start.x, end.x, visible) else { continue }
                var path = Path()
                path.move(to: start)
                let middle = (start.x + end.x) / 2
                path.addCurve(to: end, control1: CGPoint(x: middle, y: start.y), control2: CGPoint(x: middle, y: end.y))
                context.stroke(path, with: .color(color.opacity(0.6)), style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 2.5]))
            }
        }
    }

    // MARK: Git

    private static func drawCommits(_ layout: MapLayout, ring: Color, visible: ClosedRange<CGFloat>?,
                                    in context: inout GraphicsContext) {
        for marker in layout.map.markers where !(marker.laneID == layout.map.trunkID && marker.isBead) {
            guard let lane = layout.lane(marker.laneID), reaches(layout.x(marker.date), layout.x(marker.date), visible)
            else { continue }
            let center = CGPoint(x: layout.x(marker.date), y: layout.y(of: lane))
            // A ring in the card's color sets the dot off from a bar beneath without cutting the bar.
            let radius: CGFloat = lane.kind == .trunk ? 2.5 : layout.isFolded(lane.id) ? 1.6 : 2
            let dot = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            context.stroke(dot, with: .color(ring), lineWidth: 1.5)
            context.fill(dot, with: .color(ink(lane.kind == .trunk ? 0.70 : 0.66)))
        }
    }

    /// Rings where branches landed: bold with a center dot when the branch is
    /// drawn, hollow otherwise (no session edited it, or it never existed
    /// here); close ones share a capsule.
    private static func drawBeads(_ layout: MapLayout, visible: ClosedRange<CGFloat>?, in context: inout GraphicsContext) {
        let y = layout.trunkY
        for bead in layout.beads where reaches(bead.minX, bead.maxX, visible) {
            let strong = bead.markers.contains { $0.mergedLaneID != nil }
            let ring = CGRect(x: bead.minX - 4.5, y: y - 4.5, width: bead.maxX - bead.minX + 9, height: 9)
            knockout(Path(roundedRect: ring.insetBy(dx: -1, dy: -1), cornerRadius: 5.5), in: &context)
            context.stroke(Path(roundedRect: ring, cornerRadius: 4.5), with: .color(ink(strong ? 0.85 : 0.48)),
                           lineWidth: strong ? 1.75 : 1.25)
            for marker in bead.markers where marker.mergedLaneID != nil {
                let x = layout.x(marker.date)
                context.fill(Path(ellipseIn: CGRect(x: x - 1.6, y: y - 1.6, width: 3.2, height: 3.2)), with: .color(ink(0.85)))
            }
        }
    }

    // MARK: Labels

    private static func drawLabels(_ layout: MapLayout, visible: ClosedRange<CGFloat>?, in context: inout GraphicsContext) {
        var rowRight: [Int: CGFloat] = [:]
        // The trunk: "main", and "before Git" when that stretch is wide enough.
        if let trunk = layout.lane(layout.map.trunkID) {
            let title = layout.map.isGitCheckout ? trunk.title : (layout.map.projectPath as NSString).lastPathComponent
            var right = drawLabel(title, at: CGPoint(x: 0, y: layout.trunkY - 7), weight: .semibold, italic: false,
                                  color: .primary, width: 200, in: &context)
            let root = layout.map.rootCommitDate.map { layout.x($0) } ?? 0
            if root - right >= 60 {
                right = drawLabel("before Git", at: CGPoint(x: right + 4, y: layout.trunkY - 7), weight: .regular,
                                  italic: false, color: ink(0.4), width: 80, in: &context)
            }
            rowRight[0] = right
        }
        drawPullRequests(layout, after: rowRight[0] ?? 0, visible: visible, in: &context)
        // Each name where the layout placed it, so what shows is what hovers and clicks.
        for unit in layout.labelUnits {
            let weight: Font.Weight = unit.primary ? .semibold : .medium
            // In a field wider than the window, a long lane says its name again about once a
            // visible width along its line, so it stays named after its start scrolls out of view.
            if let every = layout.labelRepeat {
                let full = measure(unit.title, weight: weight, italic: unit.italic, layout: layout, context: context)
                var at = unit.start + (unit.enteredBeforeWindow ? 2 : 8) + every
                while at + full <= unit.reach - 8 {
                    if reaches(at, at + full, visible) {
                        drawLabel(unit.title, at: CGPoint(x: at, y: unit.baseline), weight: weight, italic: unit.italic,
                                  color: ink(0.45), width: full + 1, in: &context)
                    }
                    at += every
                }
            }
            // A whole label outside the strip is not drawn. A bundle's title ends in a chevron
            // that opens or folds it.
            guard let place = unit.place, reaches(place.left, place.left + place.drawn + 10, visible) else { continue }
            let color: Color = unit.primary ? .primary : .secondary
            // A bundle squeezed out of its title keeps only its chevron.
            let end = place.text.isEmpty ? place.left - 3
                : drawLabel(place.text, at: CGPoint(x: place.left, y: unit.baseline), weight: weight,
                            italic: unit.italic, color: color, width: place.width, in: &context)
            if let shape = unit.bundle {
                drawChevron(open: shape.isOpen, at: CGPoint(x: end + 3, y: unit.baseline - 3.5), color: color, in: &context)
            }
        }
        // An open bundle names each strand on its own line.
        for shape in layout.bundleShapes.values where shape.isOpen {
            for lane in shape.lanes {
                guard let place = layout.strandLabels[lane.id], reaches(place.left, place.left + place.drawn, visible)
                else { continue }
                let primary = lane.isLive || lane.isHead
                drawLabel(place.text, at: CGPoint(x: place.left, y: layout.y(of: lane) - 7), weight: primary ? .semibold : .medium,
                          italic: lane.deleted, color: primary ? .primary : .secondary, width: place.width, in: &context)
            }
        }
    }

    /// A small chevron after a bundle's title: pointing right while folded, down while open.
    private static func drawChevron(open: Bool, at point: CGPoint, color: Color, in context: inout GraphicsContext) {
        var path = Path()
        if open {
            path.move(to: CGPoint(x: point.x, y: point.y - 1.5))
            path.addLine(to: CGPoint(x: point.x + 3, y: point.y + 1.5))
            path.addLine(to: CGPoint(x: point.x + 6, y: point.y - 1.5))
        } else {
            path.move(to: CGPoint(x: point.x + 1.5, y: point.y - 3))
            path.addLine(to: CGPoint(x: point.x + 4.5, y: point.y))
            path.addLine(to: CGPoint(x: point.x + 1.5, y: point.y + 3))
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
    }

    /// Draws a micro label with its baseline at `point`, knocked out of the
    /// lines beneath. Returns its right edge.
    @discardableResult
    private static func drawLabel(_ text: String, at point: CGPoint, weight: Font.Weight, italic: Bool, color: Color,
                                  width: CGFloat, in context: inout GraphicsContext) -> CGFloat {
        var label = Text(fitted(text, width: width, weight: weight, italic: italic, context: context))
            .font(Theme.Typeface.micro.weight(weight))
        if italic { label = label.italic() }
        let resolved = context.resolve(label.foregroundColor(color))
        let size = resolved.measure(in: CGSize(width: width, height: 20))
        let rect = CGRect(x: point.x - 2, y: point.y - size.height + 1, width: size.width + 4, height: size.height + 1)
        knockout(Path(roundedRect: rect, cornerRadius: 2), in: &context)
        context.draw(resolved, at: point, anchor: .bottomLeading)
        return point.x + size.width
    }

    /// "#18" over each bead; labels too close to set apart share "#7–11".
    private static func drawPullRequests(_ layout: MapLayout, after left: CGFloat, visible: ClosedRange<CGFloat>?,
                                         in context: inout GraphicsContext) {
        var groups: [(center: CGFloat, low: Int, high: Int)] = []
        var lastRight = -CGFloat.infinity
        for bead in layout.beads {
            let numbers = bead.markers.compactMap(\.pullRequest)
            guard let low = numbers.min(), let high = numbers.max() else { continue }
            let width = measure(low == high ? "#\(low)" : "#\(low)–\(high)", weight: .regular, italic: false, layout: layout,
                                context: context)
            if let last = groups.last, bead.center - width / 2 < lastRight + 4 {
                groups[groups.count - 1] = ((last.center + bead.center) / 2, min(last.low, low), max(last.high, high))
            } else {
                groups.append((bead.center, low, high))
            }
            lastRight = bead.center + width / 2
        }
        var right = left + 4
        for group in groups {
            let text = group.low == group.high ? "#\(group.low)" : "#\(group.low)–\(group.high)"
            let width = layout.textWidths.width(of: text, style: "pr") {
                context.resolve(Text(text).font(Theme.Typeface.micro.monospacedDigit())).measure(in: CGSize(width: 80, height: 20)).width
            }
            let x = max(group.center - width / 2, right)
            guard x + width <= layout.width else { continue }
            if reaches(x, x + width, visible) {
                let resolved = context.resolve(Text(text).font(Theme.Typeface.micro.monospacedDigit()).foregroundColor(ink(0.5)))
                context.draw(resolved, at: CGPoint(x: x, y: layout.trunkY - 7), anchor: .bottomLeading)
            }
            right = x + width + 4
        }
    }

    private static func measure(_ value: String, weight: Font.Weight, italic: Bool, context: GraphicsContext) -> CGFloat {
        var text = Text(value).font(Theme.Typeface.micro.weight(weight))
        if italic { text = text.italic() }
        return context.resolve(text).measure(in: CGSize(width: 1000, height: 20)).width
    }

    /// `measure`, kept for the layout: a field drawn in strips measures each label once.
    private static func measure(_ value: String, weight: Font.Weight, italic: Bool, layout: MapLayout,
                                context: GraphicsContext) -> CGFloat {
        layout.textWidths.width(of: value, style: "\(weight)\(italic ? " italic" : "")") {
            measure(value, weight: weight, italic: italic, context: context)
        }
    }

    /// Fits `text` into `width`: first without a generic prefix such as
    /// "claude/", then middle-truncated with both ends readable. A binary
    /// search over the kept length measures a handful of candidates.
    private static func fitted(_ text: String, width: CGFloat, weight: Font.Weight, italic: Bool,
                               context: GraphicsContext) -> String {
        func measure(_ value: String) -> CGFloat { MapFieldPainter.measure(value, weight: weight, italic: italic, context: context) }
        guard measure(text) > width else { return text }
        if let slash = text.firstIndex(of: "/"), text.distance(from: text.startIndex, to: slash) <= 8 {
            return fitted(String(text[text.index(after: slash)...]), width: width, weight: weight, italic: italic,
                          context: context)
        }
        func candidate(_ keep: Int) -> String { "\(text.prefix((keep + 1) / 2))…\(text.suffix(keep / 2))" }
        var low = 3
        var high = text.count - 1
        var best: String?
        while low <= high {
            let middle = (low + high) / 2
            if measure(candidate(middle)) <= width {
                best = candidate(middle)
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return best ?? String(text.prefix(2)) + "…"
    }

    // MARK: Highlight

    private static func drawHighlight(_ item: MapHit, _ layout: MapLayout, visible: ClosedRange<CGFloat>?,
                                      in context: inout GraphicsContext) {
        let ring = ink(0.85)
        switch item {
        case .live(let hovered), .span(let hovered):
            // Folded strands are too close for a ring each: the session's runs in one bundle
            // share an outline.
            var outlines: [String: CGRect] = [:]
            for span in layout.map.spans where span.sessionKey == hovered.sessionKey {
                let bar = layout.barRect(span)
                if layout.isFolded(span.laneID), let bundle = layout.lane(span.laneID)?.bundle {
                    outlines[bundle] = outlines[bundle].map { $0.union(bar) } ?? bar
                } else if reaches(bar.minX, bar.maxX, visible) {
                    let rect = bar.insetBy(dx: -2, dy: -2)
                    context.stroke(Path(roundedRect: rect, cornerRadius: rect.height / 2), with: .color(ring), lineWidth: 1)
                }
            }
            for outline in outlines.values where reaches(outline.minX, outline.maxX, visible) {
                context.stroke(Path(roundedRect: outline.insetBy(dx: -3, dy: -3), cornerRadius: 5), with: .color(ring),
                               lineWidth: 1)
            }
        case .commit(let marker):
            guard let lane = layout.lane(marker.laneID) else { return }
            let center = CGPoint(x: layout.x(marker.date), y: layout.y(of: lane))
            context.stroke(Path(ellipseIn: CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)),
                           with: .color(ring), lineWidth: 1)
        case .cluster(let markers):
            guard let first = markers.first, let last = markers.last else { return }
            let rect = CGRect(x: layout.x(first.date) - 7, y: layout.trunkY - 7,
                              width: layout.x(last.date) - layout.x(first.date) + 14, height: 14)
            context.stroke(Path(roundedRect: rect, cornerRadius: 7), with: .color(ring), lineWidth: 1)
        case .lane, .group, .fold:
            break
        }
    }
}

// MARK: - Inspector

/// Two lines under the field. Hovering changes only this text; the graph never moves.
struct MapInspector: View {
    let map: ProjectMap
    let item: MapHit?
    @ObservedObject var store: AppStore

    /// With nothing hovered: the live session, else the latest merged branch.
    static func defaultItem(_ map: ProjectMap) -> MapHit? {
        if let live = map.spans.first(where: { $0.live == LiveStatus.waiting.rawValue })
            ?? map.spans.last(where: { $0.live != nil }) {
            return .live(live)
        }
        if let merged = map.lanes.filter({ $0.merge != nil }).max(by: { $0.merge!.date < $1.merge!.date }) {
            return .lane(merged)
        }
        return nil
    }

    var body: some View {
        // A new item's glyph, words and button fade in over the old ones inside the fixed strip.
        MapInspectorCrossfade(identity: item?.id) {
            HStack(alignment: .center, spacing: Theme.Space.xs) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        glyph
                        Text(name)
                            .font(Theme.Typeface.body.weight(.semibold))
                            .lineLimit(1)
                            .layoutPriority(1)
                        Text(headline)
                            .font(Theme.Typeface.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Text(detail)
                        .font(Theme.Typeface.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
                action
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 52)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sunkenField(radius: Theme.Radius.control)
        .accessibilityElement(children: .combine)
    }

    private var text: MapInspectorText {
        MapInspectorText(map: map, sources: map.sources(store.sources), calendar: store.activityCalendar)
    }

    @ViewBuilder private var glyph: some View {
        switch item {
        case .live(let span), .span(let span):
            ZStack {
                if span.live != nil {
                    Circle().strokeBorder(span.live == LiveStatus.waiting.rawValue ? Theme.Palette.needsInput
                                          : Theme.Palette.working, lineWidth: 1.5)
                        .frame(width: 13, height: 13)
                }
                Circle().fill(ProfileColor.color(span.sourceID, sources: map.sources(store.sources))).frame(width: 8, height: 8)
            }
            .frame(width: 13, height: 13)
        case .commit, .cluster:
            Circle().strokeBorder(Color.primary.opacity(0.8), lineWidth: 1.5).frame(width: 10, height: 10)
        case .lane, .group:
            Image(systemName: "arrow.triangle.branch").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        case .fold:
            Image(systemName: "moon.zzz").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }
    }

    private var name: String { item.map(text.name) ?? "Hover a branch, session or commit" }
    private var headline: String { item.map(text.headline) ?? "" }
    private var detail: String {
        item.map(text.detail) ?? "Bars are sessions, brighter where edits were denser; hatched where subagents made them"
    }

    @ViewBuilder private var action: some View {
        if case .live(let span) = item, let session = liveSession(span) {
            inspectorButton("Jump") { store.jump(session) }
                .help("Open this session")
        } else if case .span(let span) = item, let url = ProjectMap.cloudURL(span) {
            inspectorButton("Open") { NSWorkspace.shared.open(url) }
                .help("Open this cloud session on claude.ai")
        } else if case .commit(let marker) = item {
            inspectorButton("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(marker.sha, forType: .string)
            }
            .help("Copy the commit's SHA")
        }
    }

    private func inspectorButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typeface.caption.weight(.medium))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Theme.Palette.raised, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func liveSession(_ span: ProjectMap.Span) -> LiveAgentSession? {
        let ids = Set([span.sessionID] + span.otherIDs)
        return store.liveSessions.first { $0.sourceID == span.sourceID && ids.contains($0.sessionID) }
    }
}

/// The inspector's content, crossfaded when `identity` changes: the old content fades out
/// as the new fades in, laid over it and added to it, so nothing around them moves and the
/// words, glyph and button both items share hold steady. Content that changes for the same
/// item, such as a live session's count, updates in place.
private struct MapInspectorCrossfade<Identity: Hashable, Content: View>: View {
    private let identity: Identity
    private let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill

    init(identity: Identity, @ViewBuilder content: () -> Content) {
        self.identity = identity
        self.content = content()
    }

    var body: some View {
        let animation = MapMotion.animation(MapMotion.crossfade, reduceMotion: reduceMotion, still: rendersStill)
        ZStack(alignment: .leading) {
            // Each copy is flattened first: a blend mode reaches every view inside it, and the
            // button's label would otherwise add onto its own capsule and vanish in light mode.
            content
                .modifier(MapDissolveGroup(active: animation != nil))
                .modifier(MapDissolve(active: animation != nil))
                .id(identity)
                .transition(.opacity)
        }
        .animation(animation, value: identity)
        .modifier(MapDissolveGroup(active: animation != nil))
    }
}

/// Adds a layer to the one under it inside a `MapDissolveGroup`, so while two copies
/// crossfade, what both draw keeps its full strength, where a plain crossfade dims it by
/// a quarter midway. Over the group's clear backdrop a lone layer looks as it would
/// without it. Off where nothing fades: in still renders and under Reduce Motion.
private struct MapDissolve: ViewModifier {
    let active: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if active { content.blendMode(.plusLighter) } else { content }
    }
}

/// The group `MapDissolve` layers add up in, so they never add to the card behind it.
private struct MapDissolveGroup: ViewModifier {
    let active: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if active { content.compositingGroup() } else { content }
    }
}

/// The inspector's words for each kind of item, which the window's details panel shares.
struct MapInspectorText {
    let map: ProjectMap
    let sources: [AgentSource]
    let calendar: ActivityCalendar

    func name(_ item: MapHit) -> String {
        switch item {
        case .live(let span), .span(let span): return GrowthSeries.name(of: span.sourceID, sources: sources)
        case .commit(let marker):
            if let quiet = marker.quietBranch { return quiet }
            return String(marker.sha.prefix(7))
        case .cluster(let markers):
            let span = (markers.last?.date ?? .distantPast).timeIntervalSince(markers.first?.date ?? .distantPast)
            return "\(markers.count) merged in \(MapText.duration(span))"
        case .lane(let lane): return MapText.title(lane)
        case .group(let lanes): return MapText.groupTitle(lanes, in: map)
        case .fold(let gap): return "Idle \(MapText.idle(gap.duration))"
        }
    }

    func headline(_ item: MapHit) -> String {
        switch item {
        case .live(let span):
            let status = span.live == LiveStatus.waiting.rawValue ? "Needs input" : "Working"
            return "\(status) · on \(laneTitle(span.laneID)) since \(clock(span.edits.first ?? span.start)) · "
                + GrowthText.edits(span.editCount)
        case .span(let span):
            return "\(moment(span.start))–\(clock(span.end)) · "
                + "\(MapText.duration(span.end.timeIntervalSince(span.start))) on \(laneTitle(span.laneID))"
        case .commit(let marker):
            if marker.quietBranch != nil {
                return [marker.pullRequest.map { "merged as #\($0)" } ?? "merged", moment(marker.date)].joined(separator: " · ")
            }
            let merged = marker.mergedLaneID.map(laneTitle)
            let lane = laneTitle(marker.laneID)
            return [marker.pullRequest.map { "#\($0)" }, merged, merged == nil ? lane : nil, moment(marker.date)]
                .compactMap { $0 }.joined(separator: " · ")
        case .cluster(let markers):
            return markers.first.map { moment($0.date) } ?? ""
        case .lane(let lane):
            if lane.kind == .trunk { return lane.isHead ? "Default branch · checked out" : "Default branch" }
            if let merge = lane.merge {
                let squash = map.markers.first { $0.sha == merge.sha }?.kind == .squash
                let verb = squash ? "Squash-merged" : "Merged"
                return merge.pullRequest.map { "\(verb) #\($0)" } ?? verb
            }
            if lane.isStream { return "\(lane.members.count) branches · \(lane.returns.count) merged" }
            if lane.deleted { return "Deleted" }
            if lane.isHead { return "Open · checked out" }
            return lane.kind == .folder ? "Worktree · branch unknown" : "Open"
        case .group(let lanes):
            let landed = lanes.filter { $0.merge != nil }.count
            if MapText.bundle(of: lanes, in: map) != nil { return "Bundle of \(lanes.count) branches · \(landed) merged" }
            return "\(lanes.count) branches · \(landed) landed"
        case .fold:
            return ""
        }
    }

    func detail(_ item: MapHit) -> String {
        switch item {
        case .live(let span), .span(let span):
            let runs = map.spans.filter { $0.sessionKey == span.sessionKey }.sorted { $0.index < $1.index }
            var path: [String] = []
            for hop in MapText.path(runs, in: map) where path.last != hop { path.append(hop) }
            let edits = runs.reduce(0) { $0 + $1.editCount }
            let delegated = runs.reduce(0) { $0 + $1.delegated.count }
            var parts = [path.joined(separator: " → "), GrowthText.edits(edits)]
            if span.sourceID == ProjectMap.cloudSourceID {
                // Only its commits are known.
                let commits = map.markers.filter { $0.cloudSession == span.sessionID }.count
                parts[1] = commits == 1 ? "1 commit" : "\(commits) commits"
            }
            let threads = runs.first?.spawnedThreads ?? 0
            if threads > 0 { parts.insert("1 thread + \(threads) spawned", at: 0) }
            if delegated > 0 { parts.append("\(delegated) by subagents") }
            // Runs side by side end in any order; a live session runs on to now.
            if let start = runs.map(\.start).min(), let end = runs.map(\.end).max() {
                parts.append("from \(moment(start))")
                parts.append(MapText.duration((runs.contains { $0.live != nil } ? map.now : end).timeIntervalSince(start)))
            }
            return parts.joined(separator: " · ")
        case .commit(let marker):
            if marker.quietBranch != nil { return "No edits recorded by an assistant" }
            var parts = [marker.subject]
            if !marker.coAuthors.isEmpty { parts.append("with " + marker.coAuthors.joined(separator: ", ")) }
            if marker.cloudSession != nil { parts.append("from a cloud session") }
            return parts.joined(separator: " · ")
        case .cluster(let markers):
            return markers.map { marker in
                let branch = marker.mergedLaneID.map(laneTitle) ?? marker.quietBranch
                let text = [marker.pullRequest.map { "#\($0)" }, branch].compactMap { $0 }.joined(separator: " ")
                return text.isEmpty ? String(marker.sha.prefix(7)) : text
            }.joined(separator: " · ")
        case .lane(let lane):
            let runs = map.spans.filter { $0.laneID == lane.id }
            let sessions = Set(runs.map(\.sessionKey)).count
            let cloud = Set(runs.filter { $0.sourceID == ProjectMap.cloudSourceID }.map(\.sessionKey)).count
            let profiles = Set(runs.map(\.sourceID)).subtracting([ProjectMap.cloudSourceID])
                .map { GrowthSeries.name(of: $0, sources: sources) }.sorted()
            var parts = [GrowthText.edits(lane.editCount) + (profiles.isEmpty ? "" : " by " + profiles.joined(separator: ", ")),
                         GrowthText.sessions(sessions), lane.commitCount == 1 ? "1 commit" : "\(lane.commitCount) commits"]
            if cloud > 0 {
                // Cloud sessions record no edits; a branch only they worked on leads with them.
                parts[1] += cloud == sessions ? " in the cloud" : ", \(cloud) in the cloud"
                if lane.editCount == 0 { parts.removeFirst() }
            }
            parts.append("from \(moment(lane.forkedAt ?? lane.start))")
            if let merge = lane.merge {
                let into = merge.intoLaneID == map.trunkID ? "" : " into \(laneTitle(merge.intoLaneID))"
                parts.append("merged\(into) \(moment(merge.date))")
            }
            if lane.isStream { return lane.members.joined(separator: ", ") }
            return parts.joined(separator: " · ")
        case .group(let lanes):
            let edits = lanes.reduce(0) { $0 + $1.editCount }
            return GrowthText.edits(edits) + " · " + lanes.map(MapText.title).joined(separator: ", ")
        case .fold(let gap):
            return "\(moment(gap.start)) → \(moment(gap.end))"
        }
    }

    func laneTitle(_ id: String) -> String { map.lane(id).map(MapText.title) ?? "" }

    /// "Tue 3, 15:13", on the activity day, so 00:28 on Nov 3 reads "Mon 2, 00:28".
    func moment(_ date: Date) -> String {
        let day = calendar.day(of: date)
        return "\(DayFormat.weekday(day.weekday)) \(day.day), \(clock(date))"
    }

    func clock(_ date: Date) -> String {
        MomentFormat.string(date, template: "HH:mm", timeZone: calendar.timeZone)
    }
}

enum MapText {
    /// A group's name: its bundle's title, the prefix its branches share ("nv/* · 8"), else
    /// the first and a count.
    static func groupTitle(_ lanes: [ProjectMap.Lane], in map: ProjectMap? = nil) -> String {
        if let map, let bundle = bundle(of: lanes, in: map) { return bundle.title }
        let prefixes = Set(lanes.compactMap { ProjectMap.streamPrefix($0.title) })
        if prefixes.count == 1, let prefix = prefixes.first { return ProjectMap.streamTitle(prefix, count: lanes.count) }
        return "\(lanes.first.map(title) ?? "") +\(lanes.count - 1)"
    }

    /// The bundle `lanes` make up, when they are all of one.
    static func bundle(of lanes: [ProjectMap.Lane], in map: ProjectMap) -> ProjectMap.Bundle? {
        guard let id = lanes.first?.bundle, let bundle = map.bundle(id), bundle.laneIDs.count == lanes.count,
              lanes.allSatisfy({ $0.bundle == id }) else { return nil }
        return bundle
    }

    /// A lane's label: a workflow's agent by its run and number, and a worktree whose branch
    /// is unknown by its folder name.
    static func title(_ lane: ProjectMap.Lane) -> String { ProjectMap.displayTitle(lane.title) }

    /// Where a session went, a hop per stage: a branch, or the branches it worked on side by
    /// side, named as their bundle when they are all of it, else as a bundle of their own.
    /// Stages one after another inside one bundle are one hop.
    static func path(_ runs: [ProjectMap.Span], in map: ProjectMap) -> [String] {
        var hops: [[String]] = []
        for stage in ProjectMap.stages(runs) {
            let bundles = Set((hops.last ?? []).map { map.lane($0)?.bundle } + stage.map { map.lane($0)?.bundle })
            if !hops.isEmpty, bundles.count == 1, bundles.first ?? nil != nil {
                hops[hops.count - 1] += stage.filter { !hops[hops.count - 1].contains($0) }
            } else {
                hops.append(stage)
            }
        }
        return hops.map { lanes in
            guard lanes.count > 1 else { return map.lane(lanes[0]).map(title) ?? "" }
            let bundles = Set(lanes.map { map.lane($0)?.bundle })
            if bundles.count == 1, let id = bundles.first ?? nil, let bundle = map.bundle(id),
               Set(bundle.laneIDs) == Set(lanes) { return bundle.title }
            return ProjectMap.bundleTitle(lanes.compactMap { map.lane($0)?.title })
        }
    }

    /// "4 min", "2 h 3 min", "26 h".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 || hours >= 10 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    /// A folded stretch's true length: "56m", "4.5h", "21h", "3d".
    static func idle(_ seconds: TimeInterval) -> String {
        let hours = seconds / 3_600
        if hours < 1 { return "\(Int((seconds / 60).rounded()))m" }
        if hours < 10 {
            let halves = (hours * 2).rounded() / 2
            return halves == halves.rounded() ? "\(Int(halves))h" : "\(halves)h"
        }
        if hours < 48 { return "\(Int(hours.rounded()))h" }
        return "\(Int((hours / 24).rounded()))d"
    }
}

// MARK: - Legend

private struct MapLegend: View {
    let map: ProjectMap
    let sources: [AgentSource]
    @Binding var focus: String?

    var body: some View {
        HStack(spacing: 6) {
            ForEach(shares, id: \.id) { share in
                Button { focus = focus == share.id ? nil : share.id } label: {
                    HStack(spacing: 5) {
                        if share.id == ProjectMap.cloudSourceID {
                            // Cloud sessions record no edits, so the chip carries no count.
                            Image(systemName: "cloud.fill")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(ProfileColor.color(share.id, sources: sources))
                            Text("Cloud")
                                .font(Theme.Typeface.caption)
                                .lineLimit(1)
                        } else {
                            Circle().fill(ProfileColor.color(share.id, sources: sources)).frame(width: 7, height: 7)
                            Text(GrowthSeries.name(of: share.id, sources: sources))
                                .font(Theme.Typeface.caption)
                                .lineLimit(1)
                            Text(share.edits.formatted())
                                .font(Theme.Typeface.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(focus == share.id ? Theme.Palette.raised : Theme.Palette.sunken, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(share.id == ProjectMap.cloudSourceID
                      ? "\(GrowthText.sessions(cloudSessions)) on claude.ai, drawn from their commits" : "")
                .accessibilityLabel("Focus \(GrowthSeries.name(of: share.id, sources: sources))")
                .accessibilityAddTraits(focus == share.id ? .isSelected : [])
            }
            Spacer(minLength: 4)
            HatchKey()
            Text("subagents").font(Theme.Typeface.caption).foregroundStyle(.secondary)
            Circle().strokeBorder(Color.primary.opacity(0.85), lineWidth: 1.5).frame(width: 9, height: 9)
                .padding(.leading, 4)
            Text("merged PR").font(Theme.Typeface.caption).foregroundStyle(.secondary)
        }
        .frame(height: 22)
    }

    /// Profiles by edits; cloud sessions record none, so they come last.
    private var shares: [(id: String, edits: Int)] {
        let shares = Dictionary(grouping: map.spans, by: \.sourceID)
            .map { (id: $0.key, edits: $0.value.reduce(0) { $0 + $1.editCount }) }
            .filter { $0.edits > 0 }
            .sorted { ($1.edits, $0.id) < ($0.edits, $1.id) }
        return shares + (cloudSessions > 0 ? [(id: ProjectMap.cloudSourceID, edits: 0)] : [])
    }

    private var cloudSessions: Int {
        Set(map.spans.filter { $0.sourceID == ProjectMap.cloudSourceID }.map(\.sessionKey)).count
    }
}

private struct HatchKey: View {
    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let shape = Path(roundedRect: rect, cornerRadius: size.height / 2)
            context.clip(to: shape)
            context.fill(shape, with: .color(Color.primary.opacity(0.2)))
            var hatch = Path()
            var x = -size.height
            while x < size.width {
                hatch.move(to: CGPoint(x: x, y: size.height))
                hatch.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 3
            }
            context.stroke(hatch, with: .color(Color.primary.opacity(0.6)), lineWidth: 1)
        }
        .frame(width: 16, height: 6)
        .accessibilityHidden(true)
    }
}

// MARK: - About

private struct MapAboutText: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("About the Map").font(Theme.Typeface.headline)
            Group {
                Text("Lanes are Git branches. Each bar is a session's run of edits on the branch they landed in. Uncommitted changes travel with `checkout -b`, so an edit counts for the branch of the next commit in its working tree.")
                Text("Idle hours fold into narrow seams labelled with their true length. Days start at 05:00.")
                Text("Edits come from saved session history, as on Projects. Commits and merges come from the local Git history, which needs the developer tools' git. Agent Trail never changes the repository.")
                Text("Cloud sessions on claude.ai keep no history on this Mac. Their commits link back to them, so they show as pale bars from their first fetched commit to their last.")
            }
            .font(Theme.Typeface.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.s)
        .frame(width: 300, alignment: .leading)
    }
}
