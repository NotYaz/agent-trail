import AppKit
import Combine
import QuartzCore
import SwiftUI
import AgentTrailCore

/// What the menu-bar icon says. Needs input wins over working; finished is a
/// short acknowledgement after the last working session goes idle.
private enum StatusItemState: Equatable {
    case idle
    case working
    case waiting
    case finished
}

/// The menu-bar item: a glyph for the live state, the optional needs-input
/// count, a right-click menu of live sessions, and the anchor HintHUD shows
/// under. It reacts only to the store's live snapshot. Its only clocks are the
/// finished state's dismissal and the Core Animation trail, which runs only
/// while something works and motion is allowed.
///
/// Session titles and needs-action text reach menu items and tooltips only.
/// Nothing here logs a session or its details.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private static let finishedDuration: TimeInterval = 4
    /// Rows per menu section; the rest are one "N more" row that opens the panel.
    private static let sectionLimit = 8

    private let store: AppStore
    private let statusItem: NSStatusItem
    private let overlay: StatusTrailOverlay
    private let togglePanel: () -> Void
    private let showPanel: () -> Void
    private let closePanel: () -> Void

    private var cancellables: Set<AnyCancellable> = []
    /// Notification tokens. The controller lives as long as the app.
    private var observers: [NSObjectProtocol] = []
    private var snapshotScheduled = false
    /// Status per live session id in the last snapshot, to see working → idle.
    private var statuses: [String: LiveStatus] = [:]
    private var summary = LiveSummary.empty
    /// Sessions that needed input at the last scan. Nil until a scan arrives (at
    /// launch and after each profile reload), so that scan sets a baseline instead
    /// of bouncing for sessions that were already waiting.
    private var waitingIDs: Set<String>?
    private var finishedTimer: Timer?
    private var settings = StatusSettings.read()
    private var motion: StatusMotion
    private var rendered: StatusRendering?

    /// The status button, for positioning the panel.
    var button: NSStatusBarButton? { statusItem.button }

    /// `togglePanel` runs on a plain click, `showPanel` for "Open Agent Trail",
    /// and `closePanel` before the session menu opens.
    init(store: AppStore, togglePanel: @escaping () -> Void, showPanel: @escaping () -> Void,
         closePanel: @escaping () -> Void) {
        self.store = store
        self.togglePanel = togglePanel
        self.showPanel = showPanel
        self.closePanel = closePanel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        overlay = StatusTrailOverlay(frame: .zero)
        motion = StatusMotion.read(screensAsleep: false)
        super.init()
        configureButton()
        observeEnvironment()
        applySnapshot()
        observeStore()
        HintHUD.anchorProvider = { [weak self] in self?.anchorRect() }
    }

    // MARK: Setup

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusButtonClicked(_:))
        _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageOnly
        button.imageHugsTitle = true
        button.image = StatusSymbols.plain
        overlay.frame = button.bounds
        overlay.autoresizingMask = [.width, .height]
        overlay.glyph = StatusSymbols.plain
        button.addSubview(overlay)
        button.setAccessibilityHelp("Click to open Agent Trail. Right-click or Control-click to jump to a live session.")
        let sessions = NSAccessibilityCustomAction(name: "Show live sessions", target: self,
                                                   selector: #selector(showSessionsForAccessibility))
        button.setAccessibilityCustomActions([sessions])
    }

    private func observeStore() {
        let sessions = store.$liveSessions.map { _ in () }
        let summary = store.$liveSummary.map { _ in () }
        sessions.merge(with: summary)
            .sink { [weak self] _ in
                // AppStore is main-actor isolated, so every value arrives on the main thread.
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.scheduleSnapshot()
                }
            }
            .store(in: &cancellables)
    }

    private func observeEnvironment() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) { controller in
            controller.motionChanged()
        }
        observe(workspace, NSWorkspace.screensDidSleepNotification) { controller in
            controller.motion.screensAsleep = true
            controller.render()
        }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { controller in
            controller.motion.screensAsleep = false
            controller.render()
        }
        observe(NotificationCenter.default, .NSProcessInfoPowerStateDidChange) { controller in
            controller.motionChanged()
        }
        observe(NotificationCenter.default, UserDefaults.didChangeNotification) { controller in
            controller.settingsChanged()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (StatusItemController) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append(token)
    }

    // MARK: Live snapshot

    /// @Published sends before the store assigns, and liveSessions rebuilds
    /// liveSummary in didSet, so both are read once this run-loop turn ends.
    private func scheduleSnapshot() {
        guard !snapshotScheduled else { return }
        snapshotScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.snapshotScheduled = false
            self.applySnapshot()
        }
    }

    private func applySnapshot() {
        var next: [String: LiveStatus] = [:]
        for session in liveSessions() {
            next[session.id] = session.status
        }
        let finished = Self.didFinish(previous: statuses, current: next)
        statuses = next
        summary = store.liveSummary
        if summary.waiting > 0 || summary.working > 0 {
            endFinished()
        } else if finished {
            beginFinished()
        }
        let waiting = Set(next.filter { entry in entry.value == .waiting }.keys)
        var rose = false
        if store.lastLiveScan != nil {
            // Only a session that was not waiting at the last scan is new.
            if let previous = waitingIDs { rose = !waiting.isSubset(of: previous) }
            waitingIDs = waiting
        } else {
            // An empty or reset store, not a quiet one.
            waitingIDs = nil
        }
        render()
        if rose { bounce() }
    }

    /// The panel's view of live sessions: deduplicated and counted on their projects.
    private func liveSessions() -> [LiveAgentSession] {
        store.projectOverviews.flatMap { overview -> [LiveAgentSession] in overview.live?.sessions ?? [] }
    }

    /// A session went from working to idle, and nothing works or waits now.
    private static func didFinish(previous: [String: LiveStatus], current: [String: LiveStatus]) -> Bool {
        let busy = current.values.contains { status in status == .working || status == .waiting }
        guard !busy else { return false }
        return previous.contains { entry in entry.value == .working && current[entry.key] == .idle }
    }

    private func beginFinished() {
        finishedTimer?.invalidate()
        let timer = Timer(timeInterval: Self.finishedDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.finishedTimer = nil
                self.render()
            }
        }
        // Common modes, so it also fires while a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        finishedTimer = timer
    }

    private func endFinished() {
        finishedTimer?.invalidate()
        finishedTimer = nil
    }

    private var state: StatusItemState {
        if summary.waiting > 0 { return .waiting }
        if summary.working > 0 { return .working }
        return finishedTimer == nil ? .idle : .finished
    }

    // MARK: Settings and motion

    private func settingsChanged() {
        let next = StatusSettings.read()
        guard next != settings else { return }
        settings = next
        render()
    }

    private func motionChanged() {
        let next = StatusMotion.read(screensAsleep: motion.screensAsleep)
        guard next != motion else { return }
        motion = next
        render()
    }

    /// Bounces and crossfades: one-shot, but still motion.
    private var allowsOneShotMotion: Bool { settings.animates && !motion.reduceMotion }

    private func overlayMode(for state: StatusItemState) -> StatusOverlayMode {
        guard state == .working, overlay.canDrawGlyph else { return .hidden }
        return settings.animates && motion.allowsContinuous ? .trail : .badge
    }

    // MARK: Rendering

    /// Cheap when nothing changed, because the live snapshot arrives every few seconds.
    private func render() {
        guard let button = statusItem.button else { return }
        let state = self.state
        let rendering = StatusRendering(state: state, waiting: summary.waiting, working: summary.working,
                                        showsCount: settings.showsCount, overlay: overlayMode(for: state))
        guard rendering != rendered else { return }
        let previous = rendered
        rendered = rendering
        if let previous, previous.state != state { crossfade(button) }
        apply(rendering, to: button)
    }

    private func apply(_ rendering: StatusRendering, to button: NSStatusBarButton) {
        // Only the trail draws its own glyph; the still badge sits on the button's system-drawn one.
        let image = StatusSymbols.buttonImage(for: rendering.state, overlayDrawsGlyph: rendering.overlay == .trail)
        if button.image !== image { button.image = image }
        let count = rendering.state == .waiting && rendering.showsCount ? rendering.waiting : 0
        if count > 0 {
            button.font = StatusSymbols.countFont
            button.title = count.formatted()
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
        overlay.mode = rendering.overlay
        overlay.needsLayout = true
        let words = StatusWording.label(finished: rendering.state == .finished,
                                        waiting: rendering.waiting, working: rendering.working)
        button.setAccessibilityLabel(words)
        button.toolTip = words + "\n" + StatusWording.clickHint
    }

    private func crossfade(_ button: NSStatusBarButton) {
        guard allowsOneShotMotion, let layer = button.layer else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(fade, forKey: "statusState")
    }

    /// One bounce, 1 → 1.15 → 1 over 0.35 s, about the button's center.
    private func bounce() {
        guard allowsOneShotMotion, state == .waiting, let layer = statusItem.button?.layer else { return }
        let bounds = layer.bounds
        let dx = bounds.midX - (bounds.minX + layer.anchorPoint.x * bounds.width)
        let dy = bounds.midY - (bounds.minY + layer.anchorPoint.y * bounds.height)
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = [Self.scaling(1, dx: dx, dy: dy), Self.scaling(1.15, dx: dx, dy: dy),
                            Self.scaling(1, dx: dx, dy: dy)]
        animation.keyTimes = [NSNumber(value: 0), NSNumber(value: 0.45), NSNumber(value: 1)]
        animation.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut)]
        animation.duration = 0.35
        layer.add(animation, forKey: "statusBounce")
    }

    /// Scales about a point `dx`, `dy` away from the layer's anchor.
    private static func scaling(_ scale: CGFloat, dx: CGFloat, dy: CGFloat) -> NSValue {
        var transform = CATransform3DMakeTranslation(dx, dy, 0)
        transform = CATransform3DScale(transform, scale, scale, 1)
        transform = CATransform3DTranslate(transform, -dx, -dy, 0)
        return NSValue(caTransform3D: transform)
    }

    private func anchorRect() -> NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    // MARK: Clicks

    @objc private func statusButtonClicked(_ sender: Any?) {
        if Self.wantsMenu(NSApp.currentEvent) {
            showSessionsMenu()
        } else {
            togglePanel()
        }
    }

    private static func wantsMenu(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        if event.type == .rightMouseUp || event.type == .rightMouseDown { return true }
        return event.modifierFlags.contains(.control)
    }

    /// Menu tracking would hold VoiceOver's action open until the menu closes,
    /// so the menu opens on the next run-loop turn.
    @objc private func showSessionsForAccessibility() -> Bool {
        DispatchQueue.main.async { [weak self] in self?.showSessionsMenu() }
        return true
    }

    /// Built fresh each time, so it always lists the current snapshot.
    private func showSessionsMenu() {
        closePanel()
        let menu = makeMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    func menuDidClose(_ menu: NSMenu) {
        if statusItem.menu === menu { statusItem.menu = nil }
    }

    // MARK: Session menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Agent Trail")
        menu.autoenablesItems = false
        let ordered = LiveSessionRanking.ordered(liveSessions())
        let names = profileNames()
        let showTitles = StatusSettings.flag(AppSettings.Key.showSessionTitles)
        for section in StatusMenuSection.allCases {
            let members = ordered.filter { session in section.includes(session.status) }
            guard !members.isEmpty else { continue }
            menu.addItem(NSMenuItem.sectionHeader(title: section.title))
            for session in members.prefix(Self.sectionLimit) {
                let profile = names[session.sourceID] ?? session.sourceID
                menu.addItem(sessionItem(session, profile: profile, showTitles: showTitles))
            }
            if members.count > Self.sectionLimit {
                menu.addItem(openItem(title: "\(members.count - Self.sectionLimit) more in Agent Trail…"))
            }
        }
        if ordered.isEmpty { menu.addItem(placeholderItem()) }
        menu.addItem(.separator())
        menu.addItem(openItem(title: "Open Agent Trail"))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Agent Trail", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    /// "{project} · {title, branch or folder}", the profile's dot, and the time
    /// in this state as a trailing badge when the assistant records it.
    private func sessionItem(_ session: LiveAgentSession, profile: String, showTitles: Bool) -> NSMenuItem {
        let project = StatusWording.projectName(session.projectPath)
        let label = StatusWording.singleLine(store.sessionLabel(session))
        let item = NSMenuItem(title: StatusWording.menuTitle(project: project, label: label),
                              action: #selector(jumpFromMenu(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = session
        item.image = StatusSymbols.profileDot(profileColor(session.sourceID), name: profile)
        if let age = store.sessionAge(session) {
            item.badge = NSMenuItemBadge(string: age)
        }
        item.toolTip = sessionHelp(session, profile: profile, showTitles: showTitles)
        return item
    }

    /// Profile and state, then the needs-action sentence (waiting) or the title,
    /// then the folder. Conversation text is left out while titles are hidden.
    private func sessionHelp(_ session: LiveAgentSession, profile: String, showTitles: Bool) -> String {
        var lines = ["\(profile) · \(StatusMenuSection.word(for: session.status))"]
        // SessionLabel strips control and bidi characters and hides both while titles are off.
        let detail = SessionLabel.needsAction(session, showTitles: showTitles)
            ?? SessionLabel.title(session, showTitles: showTitles)
        if let detail { lines.append(detail) }
        lines.append(PathFormat.abbreviate(session.workspacePath))
        return lines.joined(separator: "\n")
    }

    private func openItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(openPanelFromMenu(_:)), keyEquivalent: "")
        item.target = self
        return item
    }

    private func placeholderItem() -> NSMenuItem {
        let title: String
        // A valid configuration has at least one profile, so none means it failed
        // to load and no live scan will run until it is fixed.
        if store.sources.isEmpty && !store.demoMode {
            title = "Live status unavailable: check profiles"
        } else if store.lastLiveScan == nil {
            title = "Checking live sessions…"
        } else {
            title = "No live sessions"
        }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// The session may have changed or ended while the menu was open, so the
    /// jump uses the current copy, matched by id.
    @objc private func jumpFromMenu(_ sender: NSMenuItem) {
        guard let chosen = sender.representedObject as? LiveAgentSession else { return }
        guard let current = liveSessions().first(where: { $0.id == chosen.id }) else {
            HintHUD.show("That session is no longer live")
            return
        }
        store.jump(current)
    }

    @objc private func openPanelFromMenu(_ sender: Any?) {
        showPanel()
    }

    private func profileNames() -> [String: String] {
        var names: [String: String] = [:]
        for source in store.sources where names[source.id] == nil {
            names[source.id] = source.name
        }
        return names
    }

    private func profileColor(_ id: String) -> NSColor {
        NSColor(ProfileColor.color(id, sources: store.sources))
    }
}

// MARK: - State inputs

/// Everything the button shows. Equal renderings change nothing.
private struct StatusRendering: Equatable {
    let state: StatusItemState
    let waiting: Int
    let working: Int
    let showsCount: Bool
    let overlay: StatusOverlayMode
}

/// The two menu-bar switches. Both default to on, registered or not.
private struct StatusSettings: Equatable {
    var animates: Bool
    var showsCount: Bool

    static func read() -> StatusSettings {
        StatusSettings(animates: flag(AppSettings.Key.statusAnimates), showsCount: flag(AppSettings.Key.statusShowsCount))
    }

    static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

/// Continuous motion stops for Reduce Motion, Low Power Mode and sleeping screens.
private struct StatusMotion: Equatable {
    var reduceMotion: Bool
    var lowPower: Bool
    var screensAsleep: Bool

    var allowsContinuous: Bool { !reduceMotion && !lowPower && !screensAsleep }

    @MainActor static func read(screensAsleep: Bool) -> StatusMotion {
        StatusMotion(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                     lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
                     screensAsleep: screensAsleep)
    }
}

/// Menu sections in urgency order. Unknown gets its own section rather than
/// being counted as idle.
private enum StatusMenuSection: CaseIterable {
    case needsInput
    case working
    case idle
    case unknown

    var title: String {
        switch self {
        case .needsInput: return "Needs input"
        case .working: return "Working"
        case .idle: return "Idle"
        case .unknown: return "Unknown"
        }
    }

    func includes(_ status: LiveStatus) -> Bool {
        switch self {
        case .needsInput: return status == .waiting
        case .working: return status == .working
        case .idle: return status == .idle
        case .unknown: return status == .unknown
        }
    }

    static func word(for status: LiveStatus) -> String {
        switch status {
        case .waiting: return "Needs input"
        case .working: return "Working"
        case .idle: return "Idle"
        case .unknown: return "Status unknown"
        }
    }
}

// MARK: - Wording

private enum StatusWording {
    static let clickHint = "Click to open · Right-click for live sessions"

    /// "Agent Trail, 1 session needs input, 2 working". Counts are always words.
    static func label(finished: Bool, waiting: Int, working: Int) -> String {
        var parts = ["Agent Trail"]
        if waiting > 0 {
            parts.append(waiting == 1 ? "1 session needs input" : "\(waiting) sessions need input")
        }
        if working > 0 {
            if waiting > 0 {
                parts.append("\(working) working")
            } else {
                parts.append(working == 1 ? "1 session working" : "\(working) sessions working")
            }
        }
        if finished { parts.append("a session just finished") }
        return parts.joined(separator: ", ")
    }

    static func menuTitle(project: String, label: String) -> String {
        let short = middleTruncated(label, limit: 44)
        guard !short.isEmpty, short != project else { return project }
        return "\(project) · \(short)"
    }

    static func projectName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty || name == "/" ? path : name
    }

    static func singleLine(_ text: String) -> String {
        let pieces = text.split { (character: Character) -> Bool in character.isNewline || character == "\t" }
        return pieces.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    static func middleTruncated(_ text: String, limit: Int) -> String {
        guard limit > 2, text.count > limit else { return text }
        let head = limit / 2
        let tail = limit - head - 1
        return String(text.prefix(head)) + "…" + String(text.suffix(tail))
    }
}

// MARK: - Images

@MainActor
private enum StatusSymbols {
    private static let plainName = "point.3.connected.trianglepath.dotted"
    private static let filledName = "point.3.filled.connected.trianglepath.dotted"

    /// Template glyphs, so the menu bar tints them for light and dark bars.
    static let plain: NSImage? = symbol(plainName)
    /// Only used to find the plain glyph's nodes; its filled discs separate cleanly.
    static let filledProbe: NSImage? = symbol(filledName)
    /// Filled and amber, on the plain glyph's canvas. Not a template.
    static let waiting: NSImage? = makeWaiting()
    static let finished: NSImage? = makeFinished()
    /// Holds the item's width while the overlay draws the working glyph itself.
    static let spacer: NSImage? = makeSpacer()
    static let countFont = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .medium)

    static func buttonImage(for state: StatusItemState, overlayDrawsGlyph: Bool) -> NSImage? {
        switch state {
        case .idle: return plain
        case .working: return overlayDrawsGlyph ? (spacer ?? plain) : plain
        case .waiting: return waiting ?? plain
        case .finished: return finished ?? plain
        }
    }

    /// An 8 pt profile dot on a 14 pt canvas; dynamic colors resolve when the menu draws.
    static func profileDot(_ color: NSColor, name: String) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14), flipped: false) { rect in
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 4, y: rect.midY - 4, width: 8, height: 8)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = name
        return image
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Agent Trail")
        image?.isTemplate = true
        return image
    }

    /// The filled variant backs onto the plain one should a system lack it.
    private static func makeWaiting() -> NSImage? {
        guard let base = symbol(filledName) ?? symbol(plainName) else { return nil }
        let configuration = NSImage.SymbolConfiguration(paletteColors: [Theme.Palette.needsInputNSColor])
        guard let tinted = base.withSymbolConfiguration(configuration) else { return nil }
        tinted.isTemplate = false
        return onCanvas(tinted, template: false)
    }

    private static func makeFinished() -> NSImage? {
        guard let check = symbol("checkmark.circle") else { return nil }
        return onCanvas(check, template: true)
    }

    private static func makeSpacer() -> NSImage? {
        guard let size = plain?.size else { return nil }
        let image = NSImage(size: size, flipped: false) { _ in true }
        image.isTemplate = true
        return image
    }

    /// Centers `image` on the plain glyph's canvas, scaled down to fit, so the
    /// item keeps its width and the menu bar never shifts between states.
    private static func onCanvas(_ image: NSImage, template: Bool) -> NSImage {
        guard let canvas = plain?.size, canvas != image.size, image.size.width > 0, image.size.height > 0 else {
            return image
        }
        let fit = min(1, canvas.width / image.size.width, canvas.height / image.size.height)
        let drawn = NSSize(width: image.size.width * fit, height: image.size.height * fit)
        let result = NSImage(size: canvas, flipped: false) { rect in
            let origin = NSPoint(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2)
            image.draw(in: NSRect(origin: origin, size: drawn))
            return true
        }
        result.isTemplate = template
        return result
    }
}

/// The working badge: green, brighter on dark bars.
private enum StatusPalette {
    static let working = NSColor(name: nil) { appearance in
        let match = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
        let dark = match == .darkAqua || match == .vibrantDark
        return dark ? Theme.nsColor(hex: 0x3DDC6F) : Theme.nsColor(hex: 0x0CA30C)
    }
}

// MARK: - Trail overlay

private enum StatusOverlayMode: Equatable {
    /// The button draws its own image.
    case hidden
    /// The glyph with a highlight travelling over its three nodes.
    case trail
    /// The button's own still glyph with a small working dot at the bottom-right.
    case badge
}

/// Draws the working glyph and its highlight in Core Animation layers over the
/// status button, which shows a same-sized clear image meanwhile (the still
/// badge mode only adds the dot over the button's own glyph). Glyph and
/// highlight share one coordinate space, so the highlight always lands on the
/// nodes. Layers do not take a template tint, so the ink is labelColor
/// resolved against the button's appearance, again whenever it changes.
private final class StatusTrailOverlay: NSView {
    private static let trailKey = "trail"
    private static let breathKey = "breath"
    /// One node to the next about every 0.6 s, resting on each node for 40% of the step.
    private static let stepDuration: CFTimeInterval = 0.6
    private static let restShare = 0.4
    private static let badgeDiameter: CGFloat = 5
    /// The menu bar needs no more; ProMotion would otherwise draw at 120 Hz.
    private static let frameRate = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 30)

    var mode: StatusOverlayMode = .hidden {
        didSet {
            guard mode != oldValue else { return }
            place()
            refresh()
        }
    }

    var glyph: NSImage? {
        didSet {
            guard glyph !== oldValue else { return }
            nodes = glyph.flatMap { image in StatusGlyphNodes.nodes(for: image, probe: StatusSymbols.filledProbe) }
            placed = []
            applyScale()
            place()
            refresh()
        }
    }

    /// False only if the view has no layer, in which case the button keeps drawing its glyph.
    var canDrawGlyph: Bool { layer != nil && glyph != nil }

    private let glyphLayer = CALayer()
    private let glyphMask = CALayer()
    private let replicator = CAReplicatorLayer()
    private let bead = CALayer()
    private let badge = CALayer()
    /// Node centers in image points (top-left origin); nil when the glyph shows no clear nodes.
    private var nodes: [StatusGlyphNodes.Node]?
    /// The same nodes in this view's coordinates, as the running animation uses them.
    private var placed: [CGPoint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setUpLayers()
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        place()
    }

    /// The item resizes when the count appears or goes; follow it at once.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        place()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyScale()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyScale()
        applyColors()
        updateAnimations()
    }

    private func setUpLayers() {
        guard let root = layer else { return }
        root.masksToBounds = false
        let still: [String: CAAction] = ["position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
                                         "hidden": NSNull(), "backgroundColor": NSNull(), "cornerRadius": NSNull()]
        let layers: [CALayer] = [glyphLayer, glyphMask, replicator, bead, badge]
        for sublayer in layers { sublayer.actions = still }
        glyphMask.contentsGravity = .resize
        glyphLayer.mask = glyphMask
        // Two fading copies follow the highlight a beat behind: the trail.
        replicator.instanceCount = 3
        replicator.instanceDelay = 0.07
        replicator.instanceAlphaOffset = -0.36
        replicator.addSublayer(bead)
        root.addSublayer(glyphLayer)
        root.addSublayer(replicator)
        root.addSublayer(badge)
        glyphLayer.isHidden = true
        replicator.isHidden = true
        badge.isHidden = true
        applyColors()
    }

    private func applyColors() {
        var ink = NSColor.labelColor.cgColor
        var live = StatusPalette.working.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ink = NSColor.labelColor.cgColor
            live = StatusPalette.working.cgColor
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphLayer.backgroundColor = ink
        bead.backgroundColor = ink
        badge.backgroundColor = live
        CATransaction.commit()
    }

    /// The mask is rasterized for the current screen's scale.
    private func applyScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphMask.contentsScale = scale
        glyphMask.contents = glyph?.layerContents(forContentsScale: scale)
        CATransaction.commit()
    }

    private func refresh() {
        let visible = mode != .hidden && glyph != nil
        // The trail draws the glyph so the highlight lands on its nodes. The
        // still badge leaves the glyph to the button, with the menu bar's own vibrancy.
        let drawsGlyph = visible && mode == .trail
        let showsTrail = drawsGlyph && nodes != nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphLayer.isHidden = !drawsGlyph
        replicator.isHidden = !showsTrail
        badge.isHidden = !visible || showsTrail
        CATransaction.commit()
        updateAnimations()
    }

    // MARK: Geometry

    private func place() {
        guard let image = glyph, image.size.width > 0, image.size.height > 0 else { return }
        let rect = glyphRect(for: image.size)
        let points = mapped(nodes ?? [], into: rect, imageSize: image.size)
        let largest = (nodes ?? []).map(\.diameter).max() ?? 0
        // A touch wider than the node ring, so the highlight covers it whole.
        let diameter = largest * rect.width / image.size.width + 0.6
        let badgeSize = Self.badgeDiameter
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        glyphLayer.frame = rect
        glyphMask.frame = glyphLayer.bounds
        replicator.frame = bounds
        bead.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        bead.cornerRadius = diameter / 2
        if let first = points.first { bead.position = first }
        badge.bounds = CGRect(x: 0, y: 0, width: badgeSize, height: badgeSize)
        badge.cornerRadius = badgeSize / 2
        badge.position = CGPoint(x: rect.maxX - badgeSize * 0.3, y: rect.minY + badgeSize * 0.3)
        CATransaction.commit()
        guard points != placed else { return }
        placed = points
        bead.removeAnimation(forKey: Self.trailKey)
        updateAnimations()
    }

    /// Where the button's cell would draw an image of `size`, in this view's coordinates.
    private func glyphRect(for size: NSSize) -> CGRect {
        var area = bounds
        if let button = superview as? NSButton, let cell = button.cell as? NSButtonCell {
            let cellRect = cell.imageRect(forBounds: button.bounds)
            if cellRect.width >= 1, cellRect.height >= 1 { area = convert(cellRect, from: button) }
        }
        let fit = min(1, area.width / size.width, area.height / size.height)
        let drawn = CGSize(width: size.width * fit, height: size.height * fit)
        let rect = CGRect(x: area.midX - drawn.width / 2, y: area.midY - drawn.height / 2,
                          width: drawn.width, height: drawn.height)
        // Pixel-aligned origin and size, so the mask is never resampled.
        let options: AlignmentOptions = [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest]
        return backingAlignedRect(rect, options: options)
    }

    /// Image points have a top-left origin; this view's layers a bottom-left one.
    private func mapped(_ nodes: [StatusGlyphNodes.Node], into rect: CGRect, imageSize: NSSize) -> [CGPoint] {
        let scaleX = rect.width / imageSize.width
        let scaleY = rect.height / imageSize.height
        return nodes.map { (node: StatusGlyphNodes.Node) -> CGPoint in
            CGPoint(x: rect.minX + node.center.x * scaleX, y: rect.maxY - node.center.y * scaleY)
        }
    }

    // MARK: Animation

    /// Animations exist only in trail mode and while the view is on screen.
    private func updateAnimations() {
        let active = window != nil && mode == .trail && glyph != nil
        if active && nodes != nil && placed.count >= 2 {
            if bead.animation(forKey: Self.trailKey) == nil { bead.add(trailAnimation(placed), forKey: Self.trailKey) }
        } else {
            bead.removeAnimation(forKey: Self.trailKey)
        }
        // Without clear nodes the badge breathes instead, so working still moves.
        if active && nodes == nil {
            if badge.animation(forKey: Self.breathKey) == nil { badge.add(breathAnimation(), forKey: Self.breathKey) }
        } else {
            badge.removeAnimation(forKey: Self.breathKey)
        }
    }

    /// Rest on a node, glide to the next while shrinking a little, bloom on arrival.
    private func trailAnimation(_ points: [CGPoint]) -> CAAnimation {
        let step = 1 / Double(points.count)
        let rest = step * Self.restShare
        let glide = CAMediaTimingFunction(name: .easeInEaseOut)
        let hold = CAMediaTimingFunction(name: .linear)
        var positions: [NSValue] = []
        var positionTimes: [NSNumber] = []
        var positionTiming: [CAMediaTimingFunction] = []
        var scales: [NSNumber] = []
        var scaleTimes: [NSNumber] = []
        for (index, point) in points.enumerated() {
            let start = Double(index) * step
            let value = NSValue(point: point)
            positions.append(value)
            positions.append(value)
            positionTimes.append(NSNumber(value: start))
            positionTimes.append(NSNumber(value: start + rest))
            positionTiming.append(hold)
            positionTiming.append(glide)
            scales.append(NSNumber(value: 1.0))
            scales.append(NSNumber(value: 1.0))
            scales.append(NSNumber(value: 0.55))
            scaleTimes.append(NSNumber(value: start))
            scaleTimes.append(NSNumber(value: start + rest))
            scaleTimes.append(NSNumber(value: start + rest + (step - rest) / 2))
        }
        positions.append(NSValue(point: points[0]))
        positionTimes.append(NSNumber(value: 1.0))
        scales.append(NSNumber(value: 1.0))
        scaleTimes.append(NSNumber(value: 1.0))

        let duration = Self.stepDuration * Double(points.count)
        let move = CAKeyframeAnimation(keyPath: "position")
        move.values = positions
        move.keyTimes = positionTimes
        move.timingFunctions = positionTiming
        move.duration = duration
        let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
        pulse.values = scales
        pulse.keyTimes = scaleTimes
        pulse.timingFunctions = Array(repeating: glide, count: scales.count - 1)
        pulse.duration = duration
        let group = CAAnimationGroup()
        group.animations = [move, pulse]
        group.duration = duration
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        group.preferredFrameRateRange = Self.frameRate
        return group
    }

    private func breathAnimation() -> CAAnimation {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0.3
        fade.duration = 0.9
        fade.autoreverses = true
        fade.repeatCount = .infinity
        fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        fade.isRemovedOnCompletion = false
        fade.preferredFrameRateRange = Self.frameRate
        return fade
    }
}

// MARK: - Glyph nodes

/// Finds the trail glyph's three nodes by rendering it once and reading its
/// alpha, so the highlight lands on them whatever this macOS release draws.
/// Nil unless there are exactly three clear, round, similar blobs, each well
/// above the dotted path's dashes; the overlay then breathes its badge instead.
@MainActor
private enum StatusGlyphNodes {
    struct Node: Equatable {
        /// Image points from the top-left corner.
        let center: CGPoint
        let diameter: CGFloat
    }

    private struct Mask {
        let width: Int
        let height: Int
        let filled: [Bool]
    }

    private struct Box {
        var minX: Int
        var minY: Int
        var maxX: Int
        var maxY: Int
        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        var area: Int { width * height }
    }

    /// Analysis resolution, independent of the screen.
    private static let scale = 4
    private static var cache: [String: [Node]] = [:]
    private static var misses: Set<String> = []

    /// `probe` is a variant on the same canvas whose nodes are easier to find.
    static func nodes(for image: NSImage, probe: NSImage?) -> [Node]? {
        let key = "\(image.size.width)x\(image.size.height)"
        if let cached = cache[key] { return cached }
        if misses.contains(key) { return nil }
        var found: [Node]?
        if let probe, probe.size == image.size { found = detect(probe, canvas: image.size) }
        if found == nil { found = detect(image, canvas: image.size) }
        if let found { cache[key] = found } else { misses.insert(key) }
        return found
    }

    private static func detect(_ image: NSImage, canvas: NSSize) -> [Node]? {
        guard let mask = alphaMask(image, canvas: canvas) else { return nil }
        return pick(components(mask))
    }

    /// Bitmap rows run top to bottom, so mask row 0 is the top of the image.
    private static func alphaMask(_ image: NSImage, canvas: NSSize) -> Mask? {
        let factor = CGFloat(scale)
        let width = Int((canvas.width * factor).rounded(.up))
        let height = Int((canvas.height * factor).rounded(.up))
        guard width > 0, height > 0, width <= 1_024, height <= 1_024,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: factor, y: factor)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(origin: .zero, size: canvas), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let data = context.data else { return nil }
        let count = width * height
        let bytes = data.bindMemory(to: UInt8.self, capacity: count * 4)
        var filled = [Bool](repeating: false, count: count)
        for index in 0..<count where bytes[index * 4 + 3] > 110 {
            filled[index] = true
        }
        return Mask(width: width, height: height, filled: filled)
    }

    /// Bounding boxes of 8-connected blobs.
    private static func components(_ mask: Mask) -> [Box] {
        var seen = [Bool](repeating: false, count: mask.filled.count)
        var boxes: [Box] = []
        var stack: [Int] = []
        for start in mask.filled.indices where mask.filled[start] && !seen[start] {
            var box = Box(minX: Int.max, minY: Int.max, maxX: Int.min, maxY: Int.min)
            seen[start] = true
            stack.append(start)
            while let index = stack.popLast() {
                let x = index % mask.width
                let y = index / mask.width
                box.minX = min(box.minX, x)
                box.maxX = max(box.maxX, x)
                box.minY = min(box.minY, y)
                box.maxY = max(box.maxY, y)
                for dy in -1...1 {
                    for dx in -1...1 {
                        let nx = x + dx
                        let ny = y + dy
                        guard nx >= 0, ny >= 0, nx < mask.width, ny < mask.height else { continue }
                        let neighbor = ny * mask.width + nx
                        if mask.filled[neighbor] && !seen[neighbor] {
                            seen[neighbor] = true
                            stack.append(neighbor)
                        }
                    }
                }
            }
            boxes.append(box)
        }
        return boxes
    }

    private static func pick(_ boxes: [Box]) -> [Node]? {
        let ranked = boxes.sorted { $0.area > $1.area }
        guard ranked.count >= 3 else { return nil }
        let candidates = Array(ranked.prefix(3))
        for box in candidates {
            let ratio = Double(box.width) / Double(box.height)
            guard ratio > 0.75, ratio < 1.33, box.width >= scale * 2 else { return nil }
        }
        let areas = candidates.map(\.area)
        guard let largest = areas.max(), let smallest = areas.min(), smallest * 2 >= largest else { return nil }
        if ranked.count > 3, ranked[3].area * 2 > smallest { return nil }
        let factor = CGFloat(scale)
        let found = candidates.map { (box: Box) -> Node in
            let x = CGFloat(box.minX + box.maxX + 1) / 2 / factor
            let y = CGFloat(box.minY + box.maxY + 1) / 2 / factor
            return Node(center: CGPoint(x: x, y: y), diameter: CGFloat(max(box.width, box.height)) / factor)
        }
        return clockwise(found)
    }

    /// Top node first, then clockwise on screen.
    private static func clockwise(_ nodes: [Node]) -> [Node] {
        let count = CGFloat(nodes.count)
        let centerX = nodes.reduce(CGFloat(0)) { partial, node in partial + node.center.x } / count
        let centerY = nodes.reduce(CGFloat(0)) { partial, node in partial + node.center.y } / count
        guard let top = nodes.min(by: { $0.center.y < $1.center.y }) else { return nodes }
        let start = atan2(top.center.y - centerY, top.center.x - centerX)
        func turn(_ node: Node) -> CGFloat {
            let angle = atan2(node.center.y - centerY, node.center.x - centerX) - start
            return angle < 0 ? angle + 2 * .pi : angle
        }
        return nodes.sorted { turn($0) < turn($1) }
    }
}

/// Developer preview for `--render-status-demo`: the menu-bar states drawn large
/// on a light and a dark bar (idle, idle with the trail's detected nodes marked
/// in animation order, needs input, finished). It uses the live item's images
/// and node detection, so a change that breaks the trail shows up here.
@MainActor
enum StatusIconPreview {
    static func image() -> NSImage {
        let scale: CGFloat = 8
        let glyph = StatusSymbols.plain?.size ?? NSSize(width: 18, height: 16)
        let cell = NSSize(width: glyph.width * scale + 48, height: glyph.height * scale + 40)
        let images: [NSImage?] = [StatusSymbols.plain, StatusSymbols.plain, StatusSymbols.waiting, StatusSymbols.finished]
        let size = NSSize(width: cell.width * CGFloat(images.count), height: cell.height * 2)
        return NSImage(size: size, flipped: false) { _ in
            for (row, dark) in [false, true].enumerated() {
                let y = CGFloat(1 - row) * cell.height
                (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(x: 0, y: y, width: size.width, height: cell.height).fill()
                for (column, image) in images.enumerated() {
                    guard let image else { continue }
                    let rect = NSRect(x: CGFloat(column) * cell.width + 24, y: y + 20,
                                      width: glyph.width * scale, height: glyph.height * scale)
                    draw(image, in: rect, ink: dark ? .white : .black)
                    if column == 1 { markNodes(in: rect, glyph: glyph) }
                }
            }
            return true
        }
    }

    private static func draw(_ image: NSImage, in rect: NSRect, ink: NSColor) {
        guard image.isTemplate else {
            image.draw(in: rect)
            return
        }
        let tinted = NSImage(size: rect.size, flipped: false) { bounds in
            image.draw(in: bounds)
            ink.set()
            bounds.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: rect)
    }

    /// A red cross means no nodes were found, so the live item breathes its badge instead.
    private static func markNodes(in rect: NSRect, glyph: NSSize) {
        NSColor.systemRed.setStroke()
        guard let plain = StatusSymbols.plain,
              let nodes = StatusGlyphNodes.nodes(for: plain, probe: StatusSymbols.filledProbe) else {
            let cross = NSBezierPath()
            cross.move(to: rect.origin)
            cross.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
            cross.lineWidth = 3
            cross.stroke()
            return
        }
        let sx = rect.width / glyph.width
        let sy = rect.height / glyph.height
        for (index, node) in nodes.enumerated() {
            // Node centers are image points from the top-left corner.
            let center = NSPoint(x: rect.minX + node.center.x * sx, y: rect.maxY - node.center.y * sy)
            let radius = node.diameter * sx / 2
            let ring = NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius,
                                                   width: radius * 2, height: radius * 2))
            ring.lineWidth = 2
            ring.stroke()
            let label = "\(index + 1)" as NSString
            label.draw(at: NSPoint(x: center.x + radius + 2, y: center.y),
                       withAttributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.systemRed])
        }
    }
}
