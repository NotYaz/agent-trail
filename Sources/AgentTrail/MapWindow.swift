import AppKit
import SwiftUI
import AgentTrailCore

// MARK: - Map window

/// The Map in its own resizable window, for a closer look than the panel's
/// 600pt allows. It shares the store's map, project, range and mode with the
/// panel's Map tab and keeps its own hover and selection. Closing it releases
/// the window; the next open restores its last frame.
@MainActor
final class MapWindowController: NSObject, NSWindowDelegate {
    static let defaultSize = NSSize(width: 1180, height: 800)
    /// The Map's area below the title bar is never smaller than the panel's,
    /// so every mode keeps the room it was drawn for.
    static let minimumSize = NSSize(width: 640, height: 640)
    private static let frameName = "AgentTrailMapWindow"

    private let store: AppStore
    private var window: NSWindow?

    init(store: AppStore) {
        self.store = store
    }

    /// True while the window exists, visible or not.
    var isOpen: Bool { window != nil }

    /// A window set up as the Map window, holding `content`. Renders and the
    /// benchmark use it too, so they lay out under the same title bar.
    static func makeWindow<Content: View>(_ content: Content, size: NSSize) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Agent Trail · Map"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.tabbingMode = .disallowed
        let host = NSHostingController(rootView: content)
        // The user sizes the window; SwiftUI's fitting size never resizes it.
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(size)
        // The content runs under the title bar, which takes its height as safe area.
        let titleBar = window.frame.height - window.contentLayoutRect.height
        window.contentMinSize = NSSize(width: minimumSize.width, height: minimumSize.height + titleBar)
        return window
    }

    /// "W x H" in points, as `--window` takes it, from the minimum to 4000 a side.
    static func size(parsing text: String) -> NSSize? {
        let parts = text.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
              width >= minimumSize.width, height >= minimumSize.height, width <= 4000, height <= 4000 else { return nil }
        return NSSize(width: width.rounded(), height: height.rounded())
    }

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = Self.makeWindow(MapWindowRoot(store: store, hover: MapHoverModel()), size: Self.defaultSize)
        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.setFrameAutosaveName(Self.frameName)
        window.delegate = self
        self.window = window
        store.isMapWindowVisible = true
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        store.isMapWindowVisible = false
        store.isMapWindowKey = false
        // Dropping the hosting view stops it following the store while closed.
        window?.delegate = nil
        let closing = window
        window = nil
        DispatchQueue.main.async { closing?.contentViewController = nil }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        store.isMapWindowKey = true
    }

    func windowDidResignKey(_ notification: Notification) {
        store.isMapWindowKey = false
    }

    /// A covered, minimized or off-Space window stops building the map and pulsing.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window else { return }
        let visible = window.occlusionState.contains(.visible)
        if store.isMapWindowVisible != visible { store.isMapWindowVisible = visible }
    }
}

/// The window's content: the Map tab's view over the panel backdrop, with the
/// panel's toasts. A theme or contrast change rebuilds it, as it does the panel.
struct MapWindowRoot: View {
    let store: AppStore
    let hover: MapHoverModel
    @AppStorage(AppSettings.Key.colorTheme) private var colorTheme: ColorTheme = .classic
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.rendersStill) private var rendersStill

    var body: some View {
        // The backdrop sits inside the id: its aurora colors come from the theme too.
        MapView(store: store, hover: hover, inWindow: true)
            .safeAreaInset(edge: .bottom, spacing: 0) { MapWindowToasts(store: store) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { PanelBackdrop(opaque: rendersStill) }
            .id(MapWindowLook(theme: colorTheme, contrast: contrast))
            .background { shortcuts }
    }

    /// ⌘R refreshes, as in the panel; ⌘W closes through the Window menu.
    private var shortcuts: some View {
        Button("Refresh") { store.refresh() }
            .keyboardShortcut("r", modifiers: .command)
            .buttonStyle(.plain)
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct MapWindowLook: Hashable {
    let theme: ColorTheme
    let contrast: ColorSchemeContrast
}

/// The panel's error and info toasts, so a failed Jump from the window shows in it.
private struct MapWindowToasts: View {
    @ObservedObject var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            if let error = store.errorMessage, !error.isEmpty {
                Toast(message: error, style: .error) { store.errorMessage = nil }
                    .transition(transition)
            }
            if let info = store.infoMessage, !info.isEmpty {
                Toast(message: info, style: .info, autoDismissAfter: .seconds(6)) {
                    if store.infoMessage == info { store.infoMessage = nil }
                }
                .transition(transition)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.bottom, hasToast ? Theme.Space.s : 0)
        .animation(animation, value: store.errorMessage)
        .animation(animation, value: store.infoMessage)
    }

    private var hasToast: Bool {
        !(store.errorMessage ?? "").isEmpty || !(store.infoMessage ?? "").isEmpty
    }

    private var animation: Animation? {
        Theme.Motion.animation(Theme.Motion.standard, reduceMotion: reduceMotion, still: rendersStill)
    }

    private var transition: AnyTransition {
        reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: .bottom).combined(with: .opacity)
    }
}

/// The item `--pin` asks a render to pin, chosen from the map as a person might click it: the
/// busiest of its kind, or the latest.
enum MapRenderPin: String {
    case live, session, lane, trunk, commit, merge, group, bundle, fold

    func id(in map: ProjectMap) -> MapHitID? {
        switch self {
        case .live:
            return map.spans.last { $0.live != nil }.map { MapHit.live($0).id }
        case .session:
            let sessions = Dictionary(grouping: map.spans, by: \.sessionKey)
            let busiest = sessions.max { lhs, rhs in
                lhs.value.reduce(0) { $0 + $1.editCount } < rhs.value.reduce(0) { $0 + $1.editCount }
            }
            return busiest?.value.min { $0.index < $1.index }.map { MapHit.span($0).id }
        case .lane:
            return map.lanes.filter { $0.kind != .trunk && !$0.isStream }.max { $0.editCount < $1.editCount }
                .map { MapHit.lane($0).id }
        case .trunk:
            return map.lane(map.trunkID).map { MapHit.lane($0).id }
        case .commit:
            return map.markers.filter { $0.mergedLaneID == nil && $0.quietBranch == nil }.max { $0.date < $1.date }
                .map { MapHit.commit($0).id }
        case .merge:
            return map.markers.filter { $0.mergedLaneID != nil }.max { $0.date < $1.date }.map { MapHit.commit($0).id }
        case .group:
            let families = Dictionary(grouping: map.lanes.filter { $0.kind != .trunk }) { ProjectMap.streamPrefix($0.title) }
            let largest = families.filter { $0.key != nil && $0.value.count > 1 }.max { $0.value.count < $1.value.count }
            return largest.map { MapHit.group($0.value).id }
        case .bundle:
            return map.bundles.max { $0.laneIDs.count < $1.laneIDs.count }
                .map { MapHit.group($0.laneIDs.compactMap(map.lane)).id }
        case .fold:
            return map.axis.gaps.max { $0.duration < $1.duration }.map { MapHit.fold($0).id }
        }
    }
}
