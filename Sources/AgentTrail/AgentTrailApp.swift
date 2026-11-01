import AppKit
import Combine
import SwiftUI
import AgentTrailCore

@main
enum AgentTrailApp {
    private static let renderFlags = ["--render-demo", "--render-growth-demo", "--render-live-demo", "--render-share-demo",
                                      "--render-status-demo"]
    private static let usage = """
        Usage: AgentTrail --render-demo|--render-growth-demo|--render-live-demo|--render-share-demo|--render-status-demo OUTPUT.png [--light] [--height N]
          --light     render the light appearance (panels only; the share card is always dark)
          --height N  panel render height in points, 200-4000 (default 680; the width stays 600)

        """

    @MainActor static func main() {
        let application = NSApplication.shared
        if let index = CommandLine.arguments.firstIndex(where: { renderFlags.contains($0) }) {
            application.setActivationPolicy(.prohibited)
            guard index + 1 < CommandLine.arguments.count else {
                fputs(usage, stderr)
                exit(2)
            }
            do {
                try renderDemo(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), kind: CommandLine.arguments[index])
            } catch {
                fputs("Could not render sample data: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        let delegate = AgentTrailApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        installMainMenu(application)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    @MainActor private static func installMainMenu(_ application: NSApplication) {
        let menu = NSMenu()
        let appMenu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let quit = NSMenuItem(title: "Quit Agent Trail", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = application
        appMenu.addItem(quit)
        let windowMenu = NSMenu()
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        menu.addItem(windowItem)
        windowMenu.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        application.mainMenu = menu
        application.windowsMenu = windowMenu
    }

    /// Renders are deterministic: the clock is pinned, continuous effects stop
    /// and reveals jump to their final state.
    @MainActor private static func renderDemo(to output: URL, kind: String) throws {
        if kind == "--render-status-demo" {
            let preview = StatusIconPreview.image()
            guard let tiff = preview.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try write(png, to: output)
            return
        }
        let store = AppStore(demoMode: true, now: DemoData.referenceDate())
        if kind == "--render-share-demo" {
            let summary = store.portrait(projectPath: nil, period: .month, showNames: false)
            let card = ActivityShareCard(summary: summary, sources: store.sources, sampleData: true)
                .environment(\.rendersStill, true)
            let renderer = ImageRenderer(content: card)
            renderer.scale = 2
            renderer.isOpaque = true
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
            try write(png, to: output)
            return
        }
        // The former Live render flag stays an alias for Projects, which carries live status.
        store.panelSection = kind == "--render-growth-demo" ? .growth : .projects
        let height = renderHeight()
        let root = AgentTrailShell(store: store, animatesCharts: false, height: height)
            .environment(\.rendersStill, true)
            .environment(\.referenceNow, store.now)
        let view = NSHostingView(rootView: root)
        view.appearance = NSAppearance(named: CommandLine.arguments.contains("--light") ? .aqua : .darkAqua)
        view.frame = NSRect(x: 0, y: 0, width: AgentTrailShell.panelWidth, height: height)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try write(png, to: output)
    }

    /// `--height N` for panel renders. A missing or out-of-range value is a usage error.
    @MainActor private static func renderHeight() -> CGFloat {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--height") else { return AgentTrailShell.panelHeight }
        guard index + 1 < arguments.count, let value = Double(arguments[index + 1]), value >= 200, value <= 4000 else {
            fputs(usage, stderr)
            exit(2)
        }
        return CGFloat(value.rounded())
    }

    private static func write(_ png: Data, to output: URL) throws {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: output, options: .atomic)
    }
}

// MARK: - Application delegate

@MainActor
private final class AgentTrailApplicationDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusController: StatusItemController?
    private var popover: NSPopover?
    private var store: AppStore?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let store = AppStore()
        self.store = store
        store.showProfiles = { [weak self] in self?.showProfileSettings() }
        store.showPanel = { [weak self] in self?.showPanel() }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: AgentTrailShell.panelWidth, height: AgentTrailShell.panelHeight)
        popover.contentViewController = NSHostingController(rootView: AgentTrailShell(store: store))
        popover.delegate = self
        self.popover = popover

        // The menu-bar item: live-state glyph, right-click session menu and the hint anchor.
        statusController = StatusItemController(store: store,
            togglePanel: { [weak self] in self?.togglePanel() },
            showPanel: { [weak self] in self?.showPanel() },
            closePanel: { [weak self] in self?.closePanel() })

        DispatchQueue.main.async { [weak self] in self?.showPanel() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Continuous effects (pulses, live timelines) stop while the popover is closed.
    func popoverDidShow(_ notification: Notification) {
        store?.isPanelVisible = true
    }

    func popoverDidClose(_ notification: Notification) {
        store?.isPanelVisible = false
    }

    /// A plain left click on the menu-bar item.
    private func togglePanel() {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    /// Before the right-click session menu opens.
    private func closePanel() {
        guard let popover, popover.isShown else { return }
        popover.performClose(nil)
    }

    private func showPanel() {
        guard let button = statusController?.button, let popover else { return }
        // A hint under the icon would float over the popover's arrow.
        HintHUD.dismiss()
        NSApp.activate()
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showProfileSettings() {
        guard let store else { return }
        popover?.performClose(nil)
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = settingsWindow ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Agent Trail · Profiles"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: ProfileSettingsView(store: store, onClose: { [weak window] in window?.close() }))
        settingsWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

// MARK: - Shell

/// The floating panel: a 44pt nav bar over two tabs. Projects stays mounted so
/// its search and filters survive a tab switch; Growth mounts only while it is
/// selected and keeps its selection in AppStore.
struct AgentTrailShell: View {
    static let panelWidth: CGFloat = 600
    static let panelHeight: CGFloat = 680

    @ObservedObject private var store: AppStore
    private let animatesCharts: Bool
    private let height: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill
    @Namespace private var navigation
    /// Bumped by ⌘F; the Projects panel focuses its search field when it changes.
    @State private var focusSearch = 0
    /// The ⋯ menu's display switches. StatusItemController and the cards read the same keys.
    @AppStorage(AppSettings.Key.showSessionTitles) private var showSessionTitles = true
    @AppStorage(AppSettings.Key.statusAnimates) private var statusAnimates = true
    @AppStorage(AppSettings.Key.statusShowsCount) private var statusShowsCount = true

    /// `height` exists for `--height` renders; the live popover is always 680pt.
    init(store: AppStore, animatesCharts: Bool = true, height: CGFloat = AgentTrailShell.panelHeight) {
        _store = ObservedObject(wrappedValue: store)
        self.animatesCharts = animatesCharts
        self.height = height
    }

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            Theme.Palette.hairline.frame(height: 1)
            sections
        }
        .frame(width: AgentTrailShell.panelWidth, height: height)
        .panelBackground(opaque: !animatesCharts)
        .background { shortcuts }
        .animation(tabAnimation, value: store.panelSection)
    }

    private var isStill: Bool { rendersStill || !animatesCharts }

    private var tabAnimation: Animation? {
        Theme.Motion.animation(Theme.Motion.tab, reduceMotion: reduceMotion, still: isStill)
    }

    // MARK: Tabs

    /// Toasts are a bottom safe-area inset, so both tabs' scroll views can
    /// scroll their last row clear of a toast that waits to be dismissed.
    private var sections: some View {
        ZStack {
            projectsSection
            if store.panelSection == .growth {
                GrowthView(store: store, animatesCharts: animatesCharts)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(growthTransition)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { toasts }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var projectsSection: some View {
        let selected = store.panelSection == .projects
        return AgentTrailPanel(store: store, isActive: selected, focusSearch: $focusSearch)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(selected ? 1 : 0)
            .offset(y: hiddenOffset(selected))
            .allowsHitTesting(selected)
            .disabled(!selected)
            .accessibilityHidden(!selected)
    }

    private func hiddenOffset(_ selected: Bool) -> CGFloat {
        selected || reduceMotion ? 0 : 5
    }

    private var growthTransition: AnyTransition {
        reduceMotion ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .offset(y: 5))
    }

    // MARK: Navigation bar

    private var navigationBar: some View {
        HStack(spacing: Theme.Space.xxs) {
            tabTrack
            Spacer(minLength: Theme.Space.xs)
            if store.demoMode && store.panelSection == .projects {
                demoPill
            }
            refreshButton
            moreMenu
        }
        .padding(.horizontal, Theme.Space.gutter)
        .frame(height: 44)
    }

    private var tabTrack: some View {
        HStack(spacing: 2) {
            ForEach(PanelSection.allCases, id: \.self) { (section: PanelSection) in
                tabButton(section)
            }
        }
        .padding(2)
        .background(Theme.Palette.sunken, in: Theme.Radius.shape(Theme.Radius.control))
    }

    private func tabButton(_ section: PanelSection) -> some View {
        let selected = store.panelSection == section
        return Button { select(section) } label: {
            tabLabel(section, selected: selected)
        }
        .buttonStyle(.plain)
        .help(tabHelp(section))
        .accessibilityLabel(section.rawValue)
        .accessibilityValue(section == .projects ? liveAccessibilityValue : "")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func tabLabel(_ section: PanelSection, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: section.symbol)
                .font(.system(size: 11, weight: .medium))
            Text(section.rawValue)
                .font(Theme.Typeface.caption.weight(.medium))
            if section == .projects {
                ShellLiveBadge(waiting: store.liveSummary.waiting, working: store.liveSummary.working)
            }
        }
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background { tabPill(selected) }
        .contentShape(Theme.Radius.shape(6))
    }

    @ViewBuilder private func tabPill(_ selected: Bool) -> some View {
        if selected {
            Theme.Radius.shape(6)
                .fill(Theme.Palette.raised)
                .shadow(color: Theme.Palette.surfaceShadow, radius: 2, x: 0, y: 1)
                .matchedGeometryEffect(id: "tab", in: navigation)
        }
    }

    private func tabHelp(_ section: PanelSection) -> String {
        switch section {
        case .projects: return "Projects (⌘1)"
        case .growth: return "Growth (⌘2)"
        }
    }

    /// Always describes needs input and working separately, never as one number.
    private var liveAccessibilityValue: String {
        let live = store.liveSummary
        if store.lastLiveScan == nil { return "Checking live status" }
        guard live.reportingProjects > 0 else { return "No live reports" }
        let waiting = live.waiting == 1 ? "1 needs input" : "\(live.waiting) need input"
        return "\(waiting), \(live.working) working"
    }

    /// Projects has no header of its own, so the nav bar says the data is fake;
    /// Growth shows the same pill in its title.
    private var demoPill: some View {
        Pill(text: "Demo")
            .help("Sample data, not your local history")
            .padding(.trailing, Theme.Space.xxs)
    }

    private var refreshButton: some View {
        Button { store.refresh() } label: {
            ZStack {
                if store.isScanning {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .frame(width: 26, height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(ShellIconButtonStyle())
        .foregroundStyle(.secondary)
        .help(refreshHelp)
        .accessibilityLabel(store.isScanning ? "Refreshing local activity" : "Refresh")
    }

    private var refreshHelp: String {
        if store.isScanning { return store.scanProgress ?? "Reading local activity records" }
        if let lastScan = store.lastScan { return "Updated \(ShellTime.string(lastScan))" }
        return "Read the latest local activity"
    }

    private var updatedTitle: String {
        guard let lastScan = store.lastScan else { return "Not updated yet" }
        return "Updated \(ShellTime.string(lastScan))"
    }

    private var moreMenu: some View {
        Menu {
            moreMenuItems
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 26, height: 26)
        .help("More")
        .accessibilityLabel("More")
    }

    @ViewBuilder private var moreMenuItems: some View {
        Button("Profiles…") { store.showProfiles?() }
            .disabled(store.demoMode)
        Button("Reload profiles") { store.reloadProfiles() }
            .disabled(store.demoMode)
        Divider()
        displayMenuItems
        Divider()
        Link("Project on GitHub", destination: ShellLinks.repository)
        Link("Support development", destination: ShellLinks.support)
        Divider()
        Button(updatedTitle) {}
            .disabled(true)
        Button("Quit Agent Trail", role: .destructive) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    /// Titles affect cards, menus and hints, so that switch sits at the top
    /// level; the two icon switches live under "Menu bar".
    @ViewBuilder private var displayMenuItems: some View {
        Toggle("Show session titles", isOn: $showSessionTitles)
        Menu("Menu bar") {
            Toggle("Animate while agents work", isOn: $statusAnimates)
            Toggle("Show needs-input count", isOn: $statusShowsCount)
            if reduceMotion {
                Divider()
                Text("Reduce Motion keeps the icon still")
            }
        }
    }

    // MARK: Toasts

    private var toasts: some View {
        VStack(spacing: Theme.Space.xs) {
            if let error = store.errorMessage, !error.isEmpty {
                Toast(message: error, style: .error) { store.errorMessage = nil }
                    .transition(toastTransition)
            }
            if let info = store.infoMessage, !info.isEmpty {
                Toast(message: info, style: .info, autoDismissAfter: .seconds(6)) { dismissInfo(info) }
                    .transition(toastTransition)
            }
        }
        .padding(.horizontal, Theme.Space.gutter)
        // No toast, no inset: the scroll views keep their own bottom padding.
        .padding(.bottom, hasToast ? Theme.Space.s : 0)
        .animation(toastAnimation, value: store.errorMessage)
        .animation(toastAnimation, value: store.infoMessage)
    }

    private var hasToast: Bool {
        !(store.errorMessage ?? "").isEmpty || !(store.infoMessage ?? "").isEmpty
    }

    private var toastAnimation: Animation? {
        Theme.Motion.animation(Theme.Motion.standard, reduceMotion: reduceMotion, still: isStill)
    }

    private var toastTransition: AnyTransition {
        reduceMotion ? AnyTransition.opacity : AnyTransition.move(edge: .bottom).combined(with: .opacity)
    }

    /// A newer message may have replaced this one while its timer ran.
    private func dismissInfo(_ info: String) {
        if store.infoMessage == info { store.infoMessage = nil }
    }

    // MARK: Shortcuts

    /// Invisible buttons that carry ⌘1, ⌘2, ⌘F and ⌘R while the panel is key.
    private var shortcuts: some View {
        ZStack {
            Button("Show Projects") { select(.projects) }
                .keyboardShortcut("1", modifiers: .command)
            Button("Show Growth") { select(.growth) }
                .keyboardShortcut("2", modifiers: .command)
            Button("Find a project") { findProject() }
                .keyboardShortcut("f", modifiers: .command)
            Button("Refresh") { store.refresh() }
                .keyboardShortcut("r", modifiers: .command)
        }
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func select(_ section: PanelSection) {
        guard store.panelSection != section else { return }
        store.panelSection = section
    }

    private func findProject() {
        select(.projects)
        focusSearch &+= 1
    }
}

// MARK: - Shell helpers

private enum ShellLinks {
    static let repository = URL(string: "https://github.com/NotYaz/agent-trail")!
    static let support = URL(string: "https://github.com/NotYaz/agent-trail/blob/main/docs/SUPPORT.md")!
}

private enum ShellTime {
    /// Locale-aware hours and minutes, such as "18:28" or "6:28 PM".
    static func string(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// The Projects tab badge: an amber hand capsule with the number of sessions
/// that need input, otherwise a 6pt green dot while any session works. The tab's
/// accessibility value carries the words, so the badge itself is hidden.
private struct ShellLiveBadge: View {
    let waiting: Int
    let working: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill
    @State private var bounce = 0

    init(waiting: Int, working: Int) {
        self.waiting = waiting
        self.working = working
    }

    var body: some View {
        content
            .onChange(of: waiting) { old, new in
                guard !reduceMotion, !rendersStill, new > old else { return }
                bounce += 1
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder private var content: some View {
        if waiting > 0 {
            waitingCapsule
        } else if working > 0 {
            Circle()
                .fill(Theme.Palette.working)
                .frame(width: 6, height: 6)
                .help(working == 1 ? "1 session reported working" : "\(working) sessions reported working")
        }
    }

    private var waitingCapsule: some View {
        HStack(spacing: 2) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 9, weight: .bold))
                .symbolEffect(.bounce, options: .nonRepeating, value: bounce)
            Text(waiting.formatted())
                .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText(value: Double(waiting)))
        }
        .foregroundStyle(Color.black.opacity(0.85))
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background(Theme.Palette.needsInput, in: Capsule())
        .help(waiting == 1 ? "1 session needs input" : "\(waiting) sessions need input")
    }
}

/// Nav icon buttons show a sunken backdrop on hover and press instead of a bezel.
private struct ShellIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ShellIconButtonBody(configuration: configuration)
    }
}

private struct ShellIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovered = false

    init(configuration: ButtonStyleConfiguration) {
        self.configuration = configuration
    }

    var body: some View {
        configuration.label
            .background(backdrop, in: Theme.Radius.shape(Theme.Radius.control))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering in hovered = hovering }
    }

    private var backdrop: Color {
        hovered || configuration.isPressed ? Theme.Palette.sunken : Color.clear
    }
}
