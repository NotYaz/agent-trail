import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI
import AgentTrailCore

// MARK: - Shortcut presets

/// The session switcher's system-wide shortcut. The same chord with ⇧ jumps
/// straight to the most urgent session. Presets, not a recorder, keep both
/// chords clear of common ones: ⌃⌥Space switches input sources and ⌥⌘J opens
/// browser consoles.
enum SessionShortcut: String, CaseIterable, Identifiable {
    case off
    case controlOptionJ
    case controlOptionA
    case controlOptionCommandJ

    static let standard = SessionShortcut.controlOptionJ

    var id: String { rawValue }

    /// "⌃⌥J"; empty when off.
    var symbols: String { symbols(shift: false) }
    /// "⌃⌥⇧J"; empty when off.
    var mostUrgentSymbols: String { symbols(shift: true) }
    var menuTitle: String { self == .off ? "Off" : symbols }

    /// The chords for the keys that type these letters in the user's Latin
    /// layout, so the chord shown is the chord that works. Empty when off.
    var chords: [GlobalHotKeys.Chord] {
        guard let letter, let ansiCode else { return [] }
        let keyCode = GlobalHotKeys.keyCode(typing: letter, fallback: ansiCode)
        var modifiers = UInt32(controlKey | optionKey)
        if modifierFlags.contains(.command) { modifiers |= UInt32(cmdKey) }
        return [GlobalHotKeys.Chord(keyCode: keyCode, modifiers: modifiers),
                GlobalHotKeys.Chord(keyCode: keyCode, modifiers: modifiers | UInt32(shiftKey))]
    }

    /// For menu items that show the shortcut. Empty when off.
    var keyEquivalent: String { letter.map { String($0) } ?? "" }
    var modifierFlags: NSEvent.ModifierFlags {
        switch self {
        case .off: return []
        case .controlOptionJ, .controlOptionA: return [.control, .option]
        case .controlOptionCommandJ: return [.control, .option, .command]
        }
    }

    private var letter: Character? {
        switch self {
        case .off: return nil
        case .controlOptionJ, .controlOptionCommandJ: return "j"
        case .controlOptionA: return "a"
        }
    }

    /// The letter's key on a US keyboard, used when the layout has no key for it.
    private var ansiCode: UInt32? {
        switch self {
        case .off: return nil
        case .controlOptionJ, .controlOptionCommandJ: return UInt32(kVK_ANSI_J)
        case .controlOptionA: return UInt32(kVK_ANSI_A)
        }
    }

    /// In the system's order: ⌃⌥⇧⌘.
    private func symbols(shift: Bool) -> String {
        guard let letter else { return "" }
        return "⌃⌥" + (shift ? "⇧" : "") + (modifierFlags.contains(.command) ? "⌘" : "") + letter.uppercased()
    }
}

extension AppStore {
    /// The panel's view of live sessions: deduplicated and counted on their projects.
    var panelLiveSessions: [LiveAgentSession] {
        projectOverviews.flatMap { overview -> [LiveAgentSession] in overview.live?.sessions ?? [] }
    }

    /// No profile loaded, so no live scan runs until profiles are fixed.
    var liveStatusUnavailable: Bool { sources.isEmpty && !demoMode }
}

// MARK: - Controller

/// The keyboard way to a session. A system-wide shortcut opens a panel of live
/// sessions in the menu-bar menu's urgency order; the same chord with ⇧ jumps
/// straight to the most urgent one; `agenttrail://` links do either for
/// launchers and scripts. Every jump goes through `AppStore.jump`, so it keeps
/// a click's rules: it opens links and activates apps only when they already
/// run. Lives as long as the app.
@MainActor
final class SessionSwitcher: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    private static let width: CGFloat = 600
    private static let searchHeight: CGFloat = 50
    /// A link that arrives before the first live scan waits this long for it.
    private static let linkWait: TimeInterval = 8

    private let store: AppStore
    private let closePopover: () -> Void
    private let hotKeys = GlobalHotKeys()
    private let model: SwitcherModel
    /// The preset and chords that are registered; nil until the first registration.
    private var registered: (shortcut: SessionShortcut, chords: [GlobalHotKeys.Chord])?
    private var panel: SwitcherPanel?
    private var field: NSTextField?
    /// The app most recently in front other than Agent Trail. A jump that goes
    /// nowhere gives it focus back.
    private var lastOtherApp: NSRunningApplication?
    /// The app in front when the switcher opened, nil when it was Agent Trail. Escape returns to it.
    private var openedFrom: NSRunningApplication?
    private var pendingLink: AgentTrailLink?
    private var pendingGeneration = 0
    private var cancellables: Set<AnyCancellable> = []
    /// Notification tokens. The switcher lives as long as the app.
    private var observers: [NSObjectProtocol] = []

    init(store: AppStore, closePopover: @escaping () -> Void) {
        self.store = store
        self.closePopover = closePopover
        model = SwitcherModel(store: store)
        super.init()
        noteFrontmost(NSWorkspace.shared.frontmostApplication)
        applyShortcut(announce: false)
        observe(NotificationCenter.default, UserDefaults.didChangeNotification) { switcher, _ in
            switcher.applyShortcut(announce: true)
        }
        // A new layout can move the letter to another key. AppKit holds distributed
        // notifications while the app is inactive, which this one nearly always is.
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(inputSourceChanged(_:)),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil,
            suspensionBehavior: .deliverImmediately)
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didActivateApplicationNotification) { switcher, note in
            switcher.noteFrontmost(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        store.$liveSessions
            .sink { [weak self] _ in
                // @Published sends before the store assigns and rebuilds its projects.
                DispatchQueue.main.async { self?.liveSessionsChanged() }
            }
            .store(in: &cancellables)
        model.$rows
            .sink { [weak self] _ in DispatchQueue.main.async { self?.fitPanel() } }
            .store(in: &cancellables)
    }

    var isShowing: Bool { panel?.isVisible == true }

    /// The panel's content, laid out but never shown, for `--render-switcher-demo`.
    func previewView() -> NSView? {
        let panel = self.panel ?? makePanel()
        model.open()
        guard let view = panel.contentView else { return nil }
        view.frame = NSRect(x: 0, y: 0, width: Self.width, height: panelHeight)
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name,
                         _ handler: @escaping @MainActor (SessionSwitcher, Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self, note)
            }
        }
        observers.append(token)
    }

    @objc private func inputSourceChanged(_ notification: Notification) {
        applyShortcut(announce: true)
    }

    private func noteFrontmost(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastOtherApp = app
    }

    // MARK: Shortcut

    /// Registers the chosen preset's two chords when the choice or the keys
    /// change. Demo copies register none, so they never take the chords from
    /// the real app.
    private func applyShortcut(announce: Bool) {
        let wanted = store.demoMode ? .off : AppSettings.sessionShortcut
        let chords = wanted.chords
        if let registered, registered.shortcut == wanted, registered.chords == chords { return }
        registered = (wanted, chords)
        hotKeys.unregisterAll()
        guard chords.count == 2 else {
            store.shortcutIssue = nil
            return
        }
        let opens = hotKeys.register(chords[0]) { [weak self] in self?.toggle() }
        let jumps = hotKeys.register(chords[1]) { [weak self] in self?.open(.jumpMostUrgent) }
        let taken = [opens ? nil : wanted.symbols, jumps ? nil : wanted.mostUrgentSymbols].compactMap { $0 }
        switch taken.count {
        case 0: store.shortcutIssue = nil
        case 1: store.shortcutIssue = "Another app already uses \(taken[0])"
        default: store.shortcutIssue = "Another app already uses \(taken.joined(separator: " and "))"
        }
        if announce, let issue = store.shortcutIssue {
            HintHUD.show(issue, symbol: "keyboard")
        }
    }

    // MARK: Links

    /// An `agenttrail://` link. One that cannot be read gets a hint, never an echo of its text.
    func open(_ url: URL) {
        guard let link = AgentTrailLink.parse(url) else {
            HintHUD.show("Agent Trail can't open that link")
            returnFocus()
            return
        }
        open(link)
    }

    /// Jumps for a link or the ⇧ chord. Before the first live scan the request
    /// waits for it, up to `linkWait`.
    func open(_ link: AgentTrailLink) {
        if link == .switcher {
            show()
            return
        }
        if store.liveStatusUnavailable {
            HintHUD.show(SwitcherModel.unavailable)
            returnFocus()
            return
        }
        guard store.lastLiveScan != nil else {
            pendingLink = link
            pendingGeneration &+= 1
            let generation = pendingGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.linkWait) { [weak self] in
                guard let self, self.pendingGeneration == generation, self.pendingLink != nil else { return }
                self.pendingLink = nil
                HintHUD.show("Live sessions are still loading; try again in a moment")
                self.returnFocus()
            }
            return
        }
        guard let session = link.pick(from: store.panelLiveSessions) else {
            HintHUD.show(Self.noMatch(link))
            returnFocus()
            return
        }
        dismiss()
        jumpWhenActive(session)
    }

    private func liveSessionsChanged() {
        if let link = pendingLink, store.lastLiveScan != nil {
            pendingLink = nil
            open(link)
        }
        if isShowing { model.rebuild() }
    }

    private static func noMatch(_ link: AgentTrailLink) -> String {
        switch link {
        case .jumpProject: return "No live session in that project"
        case .jumpSession: return "That session is not live"
        case .jumpMostUrgent, .switcher: return "No live sessions to jump to"
        }
    }

    // MARK: Panel

    func toggle() {
        if isShowing {
            cancel()
        } else {
            show()
        }
    }

    /// Agent Trail becomes the active app, as when its icon is clicked, so the
    /// jump may hand activation to the session's app. The panel can still take
    /// keys if macOS keeps another app active. An open switcher keeps its filter.
    func show() {
        if let panel, panel.isVisible {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(field)
            return
        }
        let front = NSWorkspace.shared.frontmostApplication
        openedFrom = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
        closePopover()
        HintHUD.dismiss()
        let panel = self.panel ?? makePanel()
        field?.stringValue = ""
        model.open()
        place(panel)
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    /// Escape, or the shortcut again: closes and hands focus back to the app
    /// that was in front when the switcher opened.
    private func cancel() {
        dismiss()
        guard let app = openedFrom, !app.isTerminated, NSApp.isActive else { return }
        NSApp.yieldActivation(to: app)
        app.activate(from: NSRunningApplication.current, options: [])
    }

    /// Closes without moving focus: a jump or a click elsewhere decides it.
    private func dismiss() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        model.close()
    }

    /// After a jump that went nowhere, Agent Trail may be active with no window
    /// to type into; the last other app gets focus back. An open Agent Trail
    /// window keeps it.
    private func returnFocus() {
        guard NSApp.isActive, !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeKey }),
              let app = lastOtherApp, !app.isTerminated else { return }
        NSApp.yieldActivation(to: app)
        app.activate(from: NSRunningApplication.current, options: [])
    }

    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }

    private func pick(_ id: String) {
        guard let session = store.panelLiveSessions.first(where: { $0.id == id }) else {
            HintHUD.show("That session is no longer live")
            return
        }
        dismiss()
        jumpWhenActive(session)
    }

    /// Numbers stay with their sessions while the panel is open, so a live
    /// update cannot move a number under the key.
    private func pick(number: Int) {
        guard let row = model.rows.first(where: { $0.number == number }) else {
            NSSound.beep()
            return
        }
        pick(row.id)
    }

    /// A shortcut or link may arrive while another app is active. Bringing a
    /// terminal or editor forward needs Agent Trail active to hand activation
    /// over, so the jump waits up to half a second for that, then goes ahead.
    private func jumpWhenActive(_ session: LiveAgentSession) {
        let jump: () -> Void = { [weak self] in
            guard let self else { return }
            self.store.jump(session) { [weak self] outcome in
                if case .failed = outcome { self?.returnFocus() }
            }
        }
        guard !NSApp.isActive else {
            jump()
            return
        }
        NSApp.activate()
        let deadline = Date().addingTimeInterval(0.5)
        func check() {
            if NSApp.isActive || Date() >= deadline {
                jump()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { check() }
            }
        }
        check()
    }

    // MARK: Keys

    func controlTextDidChange(_ notification: Notification) {
        guard let field else { return }
        let text = field.stringValue
        // A digit typed (not pasted) into an empty filter picks that row.
        let typed = NSApp.currentEvent?.type == .keyDown
            && NSApp.currentEvent?.modifierFlags.contains(.command) == false
        if typed, model.query.isEmpty, text.count == 1, let number = Int(text), (1...9).contains(number) {
            field.stringValue = ""
            pick(number: number)
            return
        }
        model.query = text
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.insertBacktab(_:)):
            model.move(by: -1)
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertTab(_:)):
            model.move(by: 1)
        case #selector(NSResponder.insertNewline(_:)):
            if let selection = model.selection { pick(selection) }
        case #selector(NSResponder.cancelOperation(_:)):
            if model.query.isEmpty {
                cancel()
            } else {
                field?.stringValue = ""
                model.query = ""
            }
        default:
            return false
        }
        return true
    }

    // MARK: Window

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.title = "Session switcher"
        panel.delegate = self
        panel.onCommandNumber = { [weak self] number in self?.pick(number: number) }

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.maskImage = Self.maskImage(radius: 12)
        panel.contentView = background

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 18)
        field.placeholderString = "Jump to a session"
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        field.setAccessibilityLabel("Filter live sessions")
        field.delegate = self
        self.field = field
        let separator = NSBox()
        separator.boxType = .separator
        let list = NSHostingView(rootView: SwitcherBody(model: model, onPick: { [weak self] id in self?.pick(id) }))
        list.sizingOptions = []

        for view in [icon, field, separator, list] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            background.addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: background.topAnchor, constant: Self.searchHeight / 2),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -18),
            field.centerYAnchor.constraint(equalTo: icon.centerYAnchor),
            separator.topAnchor.constraint(equalTo: background.topAnchor, constant: Self.searchHeight),
            separator.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            list.topAnchor.constraint(equalTo: separator.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            list.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        self.panel = panel
        return panel
    }

    /// Centered on the screen under the pointer, a fifth of the way down, like Spotlight.
    private func place(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else {
            return
        }
        let visible = screen.visibleFrame
        let height = panelHeight
        let top = visible.maxY - (visible.height * 0.2).rounded()
        panel.setFrame(NSRect(x: (visible.midX - Self.width / 2).rounded(), y: top - height,
                              width: Self.width, height: height), display: false)
    }

    /// Grows or shrinks downward as rows come and go; the search field stays put.
    private func fitPanel() {
        guard let panel, panel.isVisible else { return }
        let height = panelHeight
        guard abs(panel.frame.height - height) > 0.5 else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }

    private var panelHeight: CGFloat { Self.searchHeight + 1 + model.bodyHeight }

    /// A stretchable rounded mask, so the behind-window blur is clipped cleanly.
    private static func maskImage(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Borderless, so it opts in to key status. ⌘1–⌘9 pick rows by key position,
/// so the keypad, Caps Lock and AZERTY's top row all work.
private final class SwitcherPanel: NSPanel {
    private static let digits: [UInt16: Int] = [
        UInt16(kVK_ANSI_1): 1, UInt16(kVK_ANSI_2): 2, UInt16(kVK_ANSI_3): 3, UInt16(kVK_ANSI_4): 4,
        UInt16(kVK_ANSI_5): 5, UInt16(kVK_ANSI_6): 6, UInt16(kVK_ANSI_7): 7, UInt16(kVK_ANSI_8): 8,
        UInt16(kVK_ANSI_9): 9, UInt16(kVK_ANSI_Keypad1): 1, UInt16(kVK_ANSI_Keypad2): 2, UInt16(kVK_ANSI_Keypad3): 3,
        UInt16(kVK_ANSI_Keypad4): 4, UInt16(kVK_ANSI_Keypad5): 5, UInt16(kVK_ANSI_Keypad6): 6,
        UInt16(kVK_ANSI_Keypad7): 7, UInt16(kVK_ANSI_Keypad8): 8, UInt16(kVK_ANSI_Keypad9): 9
    ]

    var onCommandNumber: ((Int) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if modifiers == .command, let number = Self.digits[event.keyCode] {
            onCommandNumber?(number)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Model

/// What the switcher lists: live sessions in urgency order, filtered by the
/// query, and the selected row. The order and numbers are fixed when the panel
/// opens or the query changes; live updates refresh rows in place, add new
/// sessions at the end and drop ended ones. It reads the store only while the
/// panel shows. Rows carry conversation titles when titles are shown: on
/// screen only.
@MainActor
final class SwitcherModel: ObservableObject {
    struct Row: Identifiable, Equatable {
        let id: String
        /// 1–9, kept for as long as the order is.
        let number: Int?
        let kind: StatusGlyph.Kind
        let project: String
        let label: String
        /// Profile and state, or Claude's needs-action sentence while it waits.
        let detail: String
        let age: String?
        let tint: Color
        let verb: String
        let spoken: String
    }

    static let rowHeight: CGFloat = 46
    static let listPadding: CGFloat = 6
    static let maxVisibleRows = 8
    static let placeholderHeight: CGFloat = 64
    static let footerHeight: CGFloat = 30
    static let unavailable = "Live status unavailable: check profiles"

    @Published private(set) var rows: [Row] = []
    @Published private(set) var selection: String?
    @Published private(set) var placeholder = ""
    /// The shortcut, for the footer.
    @Published private(set) var shortcut = SessionShortcut.off
    var query = "" {
        didSet { if query != oldValue { rebuild(reorder: true) } }
    }

    private let store: AppStore
    private var isOpen = false
    /// Session ids in display order, and their numbers.
    private var order: [String] = []
    private var numbers: [String: Int] = [:]
    private var announcement: DispatchWorkItem?

    init(store: AppStore) {
        self.store = store
    }

    /// The list under the search field, footer included.
    var bodyHeight: CGFloat {
        let list = rows.isEmpty ? Self.placeholderHeight
            : CGFloat(min(rows.count, Self.maxVisibleRows)) * Self.rowHeight + Self.listPadding * 2
        return list + 1 + Self.footerHeight
    }

    func open() {
        isOpen = true
        shortcut = store.demoMode ? .off : AppSettings.sessionShortcut
        query = ""
        rebuild(reorder: true)
    }

    func close() {
        isOpen = false
        announcement?.cancel()
        rows = []
        order = []
        numbers = [:]
        selection = nil
    }

    func move(by offset: Int) {
        guard !rows.isEmpty else { return }
        let current = rows.firstIndex { $0.id == selection } ?? 0
        let next = min(max(current + offset, 0), rows.count - 1)
        selection = rows[next].id
        announce(rows[next].spoken, after: 0)
    }

    /// `reorder` ranks afresh and renumbers, selecting the first row. Otherwise
    /// the selected session stays selected while it is listed.
    func rebuild(reorder: Bool = false) {
        guard isOpen else { return }
        let showTitles = AppSettings.showSessionTitles
        let names = Dictionary(store.sources.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        var matches: [String: (session: LiveAgentSession, project: String, label: String, profile: String)] = [:]
        var ranked: [String] = []
        for session in LiveSessionRanking.ordered(store.panelLiveSessions) {
            let project = Self.projectName(session.projectPath)
            let label = store.sessionLabel(session)
            let profile = names[session.sourceID] ?? session.sourceID
            let fields = [project, label, profile, SessionLabel.branch(session) ?? "", SessionLabel.folder(session)]
            guard SessionSearch.matches(query, fields: fields), matches[session.id] == nil else { continue }
            matches[session.id] = (session, project, label, profile)
            ranked.append(session.id)
        }
        if reorder {
            order = ranked
            numbers = [:]
        } else {
            let kept = Set(order)
            order = order.filter { matches[$0] != nil } + ranked.filter { !kept.contains($0) }
        }
        for id in order where numbers[id] == nil {
            let next = (numbers.values.max() ?? 0) + 1
            if next <= 9 { numbers[id] = next }
        }
        let next = order.compactMap { id -> Row? in
            guard let match = matches[id] else { return nil }
            return row(match.session, number: numbers[id], project: match.project, label: match.label,
                       profile: match.profile, showTitles: showTitles)
        }
        if next != rows { rows = next }
        placeholder = placeholderText
        let previous = selection
        if reorder || !next.contains(where: { $0.id == selection }) {
            selection = next.first?.id
        }
        if reorder || selection != previous {
            announceSelection()
        }
    }

    private func row(_ session: LiveAgentSession, number: Int?, project: String, label: String,
                     profile: String, showTitles: Bool) -> Row {
        let kind = StatusGlyph.Kind(session.status)
        let state = SessionLabel.state(session, word: kind.title)
        let detail = SessionLabel.needsAction(session, showTitles: showTitles).map { "\(profile) · \($0)" }
            ?? "\(profile) · \(state)"
        let age = store.sessionAge(session)
        let spoken = [project, label == project ? nil : label, profile, state].compactMap { $0 }.joined(separator: ", ")
        return Row(id: session.id, number: number, kind: kind, project: project,
                   label: label == project ? "" : label, detail: detail, age: age,
                   tint: ProfileColor.color(session.sourceID, sources: store.sources),
                   verb: SessionLabel.verb(session.status), spoken: spoken)
    }

    private var placeholderText: String {
        if store.liveStatusUnavailable { return Self.unavailable }
        if store.lastLiveScan == nil { return "Checking live sessions…" }
        return query.isEmpty ? "No live sessions" : "No live session matches"
    }

    /// VoiceOver hears the match count and the selected session once typing pauses.
    private func announceSelection() {
        guard let selected = rows.first(where: { $0.id == selection }) else {
            announce(placeholder, after: 0.3)
            return
        }
        let count = rows.count == 1 ? "1 session" : "\(rows.count) sessions"
        announce("\(count). \(selected.spoken)", after: 0.3)
    }

    private func announce(_ text: String, after delay: TimeInterval) {
        announcement?.cancel()
        let item = DispatchWorkItem {
            NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                                 userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        announcement = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private static func projectName(_ path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty || name == "/" ? path : name
    }
}

// MARK: - Views

/// The rows, or a placeholder, over a footer of keys.
private struct SwitcherBody: View {
    @ObservedObject var model: SwitcherModel
    let onPick: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            if model.rows.isEmpty {
                Text(model.placeholder)
                    .font(Theme.Typeface.body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: SwitcherModel.placeholderHeight)
            } else {
                rows
            }
            Divider()
            footer
        }
    }

    private var rows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        SwitcherRow(row: row, selected: row.id == model.selection) { onPick(row.id) }
                            .id(row.id)
                    }
                }
                .padding(SwitcherModel.listPadding)
            }
            .scrollIndicators(model.rows.count > SwitcherModel.maxVisibleRows ? .automatic : .never)
            .onChange(of: model.selection) { _, selection in
                guard let selection else { return }
                proxy.scrollTo(selection)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Theme.Space.s) {
            Text("↑↓ select · ↩ jump · ⌘1–9 pick · esc close")
            Spacer(minLength: Theme.Space.xs)
            if model.shortcut != .off {
                Text("\(model.shortcut.mostUrgentSymbols) jumps to the most urgent")
            }
        }
        .font(Theme.Typeface.note)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Theme.Space.m)
        .frame(height: SwitcherModel.footerHeight)
    }
}

/// "3  ✋ agent-trail · Landing copy pass" over "● Claude · Main · Needs input", with
/// the time in state and, on the selected row, the jump's verb.
private struct SwitcherRow: View {
    let row: SwitcherModel.Row
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Space.s) {
                Text(row.number.map(String.init) ?? "")
                    .font(Theme.Typeface.mono)
                    .foregroundStyle(.tertiary)
                    .frame(width: 12, alignment: .trailing)
                StatusGlyph(kind: row.kind, size: 12)
                VStack(alignment: .leading, spacing: 2) {
                    title
                    HStack(spacing: 5) {
                        Circle().fill(row.tint).frame(width: 7, height: 7)
                        Text(row.detail)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: Theme.Space.xs)
                if let age = row.age {
                    Text(age)
                        .font(Theme.Typeface.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                if selected {
                    Text("\(row.verb) ↩")
                        .font(Theme.Typeface.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(height: SwitcherModel.rowHeight)
            .background(selected ? Color.accentColor.opacity(0.18) : Color.clear,
                        in: Theme.Radius.shape(Theme.Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(row.spoken)
        .accessibilityHint("\(row.verb) this session")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var title: some View {
        (Text(row.project).fontWeight(.semibold)
            + Text(row.label.isEmpty ? "" : " · \(row.label)"))
            .font(Theme.Typeface.headline.weight(.regular))
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
