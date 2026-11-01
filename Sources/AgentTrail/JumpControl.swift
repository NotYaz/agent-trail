import AppKit
import SwiftUI
import AgentTrailCore

/// The card's way into the work. With live sessions it is a split control:
/// the primary half opens the most urgent session ("● Main ✋ Answer · title ·
/// 4m ↗") and the chevron lists every session, the folder actions and the
/// profile apps. Without live sessions it is a single "Open ⌄" menu for the
/// project folder. Both halves are 22 pt tall with a hit area at least 44 pt
/// tall and wide.
struct JumpControl: View {
    /// One live session, already labeled with the "Show session titles" setting applied.
    struct Entry: Identifiable {
        let session: LiveAgentSession
        /// Title, else branch, else folder.
        let label: String
        /// The full title, nil when hidden or missing.
        let title: String?
        let needsAction: String?
        let profileName: String
        let tint: Color
        /// Compact time in the current state ("4m"), when recorded.
        let age: String?
        let spokenAge: String?

        var id: String { session.id }
        var kind: StatusGlyph.Kind { StatusGlyph.Kind(session.status) }

        init(session: LiveAgentSession, label: String, title: String?, needsAction: String?,
             profileName: String, tint: Color, age: String?, spokenAge: String?) {
            self.session = session
            self.label = label
            self.title = title
            self.needsAction = needsAction
            self.profileName = profileName
            self.tint = tint
            self.age = age
            self.spokenAge = spokenAge
        }
    }

    /// A profile on the project with a desktop app to bring forward.
    struct Profile: Identifiable {
        let source: AgentSource
        let tint: Color
        let isRunning: Bool
        var id: String { source.id }

        init(source: AgentSource, tint: Color, isRunning: Bool) {
            self.source = source
            self.tint = tint
            self.isRunning = isRunning
        }
    }

    /// ViewThatFits drops detail in this order.
    private enum Density {
        case full, monogram, noTime, verbOnly
    }

    /// Added above and below each 22 pt face, so hit areas are 44 pt tall. The
    /// chevron, at least 22 pt wide, also gets it on both sides, so it is 44 pt wide too.
    private static let hitSlop: CGFloat = 11

    private let entries: [Entry]
    private let projectName: String
    private let projectPath: String
    private let profiles: [Profile]
    private let jump: (LiveAgentSession) -> Void
    private let perform: (WorkspaceAction) -> Void
    private let focus: (AgentSource) -> Void

    @State private var anchor = MenuAnchorBox()
    @State private var isHovered = false

    /// `entries` must already be ranked (LiveSessionRanking); the first is the target.
    init(entries: [Entry], projectName: String, projectPath: String, profiles: [Profile],
         jump: @escaping (LiveAgentSession) -> Void, perform: @escaping (WorkspaceAction) -> Void,
         focus: @escaping (AgentSource) -> Void) {
        self.entries = entries
        self.projectName = projectName
        self.projectPath = projectPath
        self.profiles = profiles
        self.jump = jump
        self.perform = perform
        self.focus = focus
    }

    var body: some View {
        Group {
            if let target = entries.first {
                split(target)
            } else {
                openButton
            }
        }
        .background(MenuAnchor(box: anchor))
    }

    // MARK: Split control

    private func split(_ target: Entry) -> some View {
        HStack(spacing: 1) {
            primaryButton(target)
            // Above the primary, so its leading slop wins over the primary's last few points.
            chevronButton(target)
                .zIndex(1)
        }
        .overlay { attentionRing(target) }
    }

    /// A waiting target draws a thin amber ring, so the question reads first.
    @ViewBuilder private func attentionRing(_ target: Entry) -> some View {
        if target.kind == .needsInput {
            Theme.Radius.shape(Theme.Radius.control)
                .strokeBorder(Theme.Palette.needsInput.opacity(0.6), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private func primaryButton(_ target: Entry) -> some View {
        Button { jump(target.session) } label: {
            primaryFace(target)
        }
        .buttonStyle(JumpPressStyle())
        .padding(.vertical, -Self.hitSlop)
        .onHover { hovering in isHovered = hovering }
        .help(primaryHelp(target))
        .accessibilityLabel(primaryAccessibilityLabel(target))
        .accessibilityValue(primaryAccessibilityValue(target))
        .accessibilityHint(target.needsAction ?? "")
    }

    private func primaryFace(_ target: Entry) -> some View {
        ViewThatFits(in: .horizontal) {
            primaryLabel(target, density: .full)
            primaryLabel(target, density: .monogram)
            primaryLabel(target, density: .noTime)
            primaryLabel(target, density: .verbOnly)
        }
        .padding(.leading, 7)
        .padding(.trailing, 6)
        .frame(height: 22)
        .background(target.tint.opacity(isHovered ? 0.18 : 0.10), in: leadingShape)
        .padding(.vertical, Self.hitSlop)
        .contentShape(Rectangle())
    }

    private func primaryLabel(_ entry: Entry, density: Density) -> some View {
        HStack(spacing: 5) {
            profileTag(entry, monogram: density != .full)
            StatusGlyph(kind: entry.kind, size: 10, bounceValue: entry.kind == .needsInput ? waitingCount : nil)
            Text(SessionLabel.verb(entry.session.status))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Self.verbColor(entry.kind))
            if density != .verbOnly {
                separator
                titleText(entry, limit: density == .noTime ? 22 : 34)
            }
            if density == .full || density == .monogram, let age = entry.age {
                separator
                Text(age)
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "arrow.up.right")
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }

    private func profileTag(_ entry: Entry, monogram: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(entry.tint)
                .frame(width: 6, height: 6)
            Text(monogram ? ProfileColor.monogram(entry.profileName) : Self.shortName(entry.profileName))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    /// The character cap keeps the ideal width honest for ViewThatFits; the
    /// middle truncation mode covers any squeeze left after that.
    private func titleText(_ entry: Entry, limit: Int) -> some View {
        Text(Self.middleTruncated(entry.label, limit: limit))
            .font(.system(size: 11))
            .foregroundStyle(.primary)
            .truncationMode(.middle)
    }

    private var separator: some View {
        Text("·")
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private func chevronButton(_ target: Entry) -> some View {
        Button(action: showMenu) {
            chevronFace(target)
        }
        .buttonStyle(JumpPressStyle())
        .padding(-Self.hitSlop)
        .help(chevronHelp)
        .accessibilityLabel("More ways to open \(projectName)")
        .accessibilityValue(chevronAccessibilityValue)
    }

    private func chevronFace(_ target: Entry) -> some View {
        HStack(spacing: 2) {
            if otherCount > 0 {
                Text("+\(otherCount)")
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(othersWaiting ? Theme.Palette.needsInputText : Color.secondary)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .padding(.horizontal, 6)
        .frame(minWidth: 22)
        .frame(height: 22)
        .background(target.tint.opacity(0.06), in: trailingShape)
        // The trailing slop sits in the card's 12 pt padding, the leading slop over the
        // primary's trailing edge; the button's negative padding keeps the layout unchanged.
        .padding(Self.hitSlop)
        .contentShape(Rectangle())
    }

    // MARK: Open menu (no live sessions)

    private var openButton: some View {
        Button(action: showMenu) {
            openFace
        }
        .buttonStyle(JumpPressStyle())
        .padding(.vertical, -Self.hitSlop)
        .onHover { hovering in isHovered = hovering }
        .help("Open \(projectName) in an editor, a terminal or Finder")
        .accessibilityLabel("Ways to open \(projectName)")
    }

    private var openFace: some View {
        HStack(spacing: 4) {
            Text("Open")
                .font(.system(size: 11, weight: .medium))
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(isHovered ? Theme.Palette.hairline : Theme.Palette.sunken,
                    in: Theme.Radius.shape(Theme.Radius.control))
        .padding(.vertical, Self.hitSlop)
        .contentShape(Rectangle())
    }

    // MARK: Menu

    private func showMenu() {
        guard let view = anchor.view, view.window != nil else { return }
        let target = entries.first?.session
        let folder = target.map { SessionLauncher.workspaceFolder(for: $0) } ?? projectPath
        let requests = (target?.details.pullRequests ?? []).filter { SessionLauncher.pullRequestURL($0.url) != nil }
        let content = JumpMenuContent(entries: entries, folder: folder, projectPath: projectPath,
                                      pullRequests: requests, profiles: profiles,
                                      jump: jump, perform: perform, focus: focus)
        JumpMenu.present(content.makeMenu(), under: view)
    }

    // MARK: Wording

    private var otherCount: Int { max(entries.count - 1, 0) }
    private var othersWaiting: Bool { entries.dropFirst().contains { $0.kind == .needsInput } }
    private var waitingCount: Int { entries.filter { $0.kind == .needsInput }.count }

    private var chevronHelp: String {
        otherCount > 0 ? "Other live sessions, folder actions and apps" : "Folder actions and apps"
    }

    private var chevronAccessibilityValue: String {
        guard otherCount > 0 else { return "" }
        let noun = otherCount == 1 ? "other live session" : "other live sessions"
        return othersWaiting ? "\(otherCount) \(noun), needs input" : "\(otherCount) \(noun)"
    }

    /// "Answer {title} in {profile} for {project}".
    private func primaryAccessibilityLabel(_ entry: Entry) -> String {
        "\(SessionLabel.verb(entry.session.status)) \(entry.label) in \(entry.profileName) for \(projectName)"
    }

    private func primaryAccessibilityValue(_ entry: Entry) -> String {
        guard let spoken = entry.spokenAge else { return entry.kind.title }
        return "\(entry.kind.title) for \(spoken)"
    }

    /// Waiting sessions lead with the needs-action sentence.
    private func primaryHelp(_ entry: Entry) -> String {
        var lines: [String] = []
        if entry.kind == .needsInput { lines.append(entry.needsAction ?? "Needs input") }
        lines.append(entry.title ?? entry.label)
        lines.append(PathFormat.abbreviate(entry.session.workspacePath))
        var status = "\(entry.kind.title) · \(entry.profileName)"
        if let spoken = entry.spokenAge { status += " · for \(spoken)" }
        lines.append(status)
        return lines.joined(separator: "\n")
    }

    private static func verbColor(_ kind: StatusGlyph.Kind) -> Color {
        switch kind {
        case .needsInput: return Theme.Palette.needsInputText
        case .working: return Theme.Palette.workingText
        case .idle, .unknown: return Color.primary
        }
    }

    private var leadingShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.control, bottomLeadingRadius: Theme.Radius.control,
                               bottomTrailingRadius: 3, topTrailingRadius: 3, style: .continuous)
    }

    private var trailingShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3,
                               bottomTrailingRadius: Theme.Radius.control, topTrailingRadius: Theme.Radius.control,
                               style: .continuous)
    }

    /// "Claude · Main" → "Main"; a name without a dot separator stays whole.
    static func shortName(_ name: String) -> String {
        let parts = name.components(separatedBy: "·")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.last ?? name
    }

    /// "Tighten the sync … retry window" for text past `limit` characters.
    static func middleTruncated(_ text: String, limit: Int) -> String {
        guard limit > 4, text.count > limit else { return text }
        let tail = (limit - 1) / 2
        let head = limit - 1 - tail
        let start = String(text.prefix(head)).trimmingCharacters(in: .whitespaces)
        let end = String(text.suffix(tail)).trimmingCharacters(in: .whitespaces)
        return start + "…" + end
    }
}

/// Inline controls dim while pressed instead of drawing a bezel.
private struct JumpPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Menu

/// Builds the chevron menu at click time, so editor detection and folder
/// checks never run during a render pass.
@MainActor
private struct JumpMenuContent {
    let entries: [JumpControl.Entry]
    let folder: String
    let projectPath: String
    let pullRequests: [LivePullRequest]
    let profiles: [JumpControl.Profile]
    let jump: (LiveAgentSession) -> Void
    let perform: (WorkspaceAction) -> Void
    let focus: (AgentSource) -> Void

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if !entries.isEmpty { addSessions(to: menu) }
        addWorkspace(to: menu)
        if !profiles.isEmpty { addProfiles(to: menu) }
        return menu
    }

    private func addSessions(to menu: NSMenu) {
        menu.addItem(NSMenuItem.sectionHeader(title: "Live sessions"))
        for entry in entries {
            menu.addItem(sessionItem(entry))
        }
    }

    private func sessionItem(_ entry: JumpControl.Entry) -> NSMenuItem {
        let session = entry.session
        let jump = self.jump
        let item = ActionMenuItem(title: entry.label) { jump(session) }
        // The status is in words as well as the glyph: VoiceOver reads the title, not the image.
        item.attributedTitle = MenuText.title(JumpControl.middleTruncated(entry.label, limit: 60),
                                              detail: "\(entry.kind.title) · \(entry.profileName)")
        item.image = MenuGlyph.status(entry.kind)
        if let age = entry.age { item.badge = NSMenuItemBadge(string: age) }
        // Spoken age, so "4m" is not read as metres.
        item.setAccessibilityLabel("\(entry.kind.title), \(entry.label), \(entry.profileName)"
                                   + (entry.spokenAge.map { ", for \($0)" } ?? ""))
        item.toolTip = "\(entry.profileName) · \(entry.kind.title)\n"
            + (entry.needsAction ?? PathFormat.abbreviate(session.workspacePath))
        return item
    }

    private func addWorkspace(to menu: NSMenu) {
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        menu.addItem(NSMenuItem.sectionHeader(title: folderHeader))
        let available = Self.isFolder(folder)
        let editor = SessionLauncher.preferredApp(.editor)
        let terminal = SessionLauncher.preferredApp(.terminal)
        if let editor { menu.addItem(openItem(editor, enabled: available)) }
        if let terminal { menu.addItem(openItem(terminal, enabled: available)) }
        if let openWith = openWithItem(editor: editor, terminal: terminal, enabled: available) {
            menu.addItem(openWith)
        }
        let path = folder
        let perform = self.perform
        menu.addItem(symbolItem("Reveal in Finder", symbol: "folder", enabled: available) {
            perform(.revealInFinder(path: path))
        })
        menu.addItem(symbolItem("Copy path", symbol: "doc.on.doc", enabled: true) {
            perform(.copyPath(path))
        })
        for request in pullRequests.prefix(5) {
            let item = symbolItem("Open PR #\(request.number)", symbol: "arrow.triangle.pull", enabled: true) {
                perform(.openPullRequest(request.url))
            }
            item.toolTip = request.url.absoluteString
            menu.addItem(item)
        }
    }

    private func addProfiles(to menu: NSMenu) {
        menu.addItem(.separator())
        menu.addItem(NSMenuItem.sectionHeader(title: "Apps"))
        let focus = self.focus
        for profile in profiles {
            let source = profile.source
            let title = "Bring \(source.name) forward"
            let item = ActionMenuItem(title: title) { focus(source) }
            item.attributedTitle = MenuText.title(title, detail: profile.isRunning ? nil : "not running")
            item.image = MenuGlyph.dot(NSColor(profile.tint), filled: profile.isRunning)
            item.toolTip = profile.isRunning
                ? "Brings the running \(source.name) instance to the front"
                : "\(source.name) is not currently identified as running. Choose to check again."
            menu.addItem(item)
        }
    }

    private func openItem(_ app: ExternalApp, enabled: Bool) -> NSMenuItem {
        let path = folder
        let perform = self.perform
        let item = ActionMenuItem(title: "Open in \(app.name)") { perform(.openWith(path: path, app: app)) }
        item.image = SessionLauncher.icon(for: app)
        item.isEnabled = enabled
        return item
    }

    /// Every installed editor and terminal, the defaults checked. Choosing one
    /// opens the folder there and makes it the default for its kind.
    private func openWithItem(editor: ExternalApp?, terminal: ExternalApp?, enabled: Bool) -> NSMenuItem? {
        let editors = SessionLauncher.installedApps(.editor)
        let terminals = SessionLauncher.installedApps(.terminal)
        guard editors.count > 1 || terminals.count > 1 else { return nil }
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for app in editors {
            submenu.addItem(choiceItem(app, chosen: app.bundleID == editor?.bundleID, enabled: enabled))
        }
        if !editors.isEmpty && !terminals.isEmpty { submenu.addItem(.separator()) }
        for app in terminals {
            submenu.addItem(choiceItem(app, chosen: app.bundleID == terminal?.bundleID, enabled: enabled))
        }
        let item = NSMenuItem(title: "Open with", action: nil, keyEquivalent: "")
        item.image = NSImage(systemSymbolName: "square.and.arrow.up.on.square", accessibilityDescription: nil)
        item.submenu = submenu
        item.isEnabled = enabled
        return item
    }

    private func choiceItem(_ app: ExternalApp, chosen: Bool, enabled: Bool) -> NSMenuItem {
        let path = folder
        let perform = self.perform
        let item = ActionMenuItem(title: app.name) { perform(.openWith(path: path, app: app)) }
        item.image = SessionLauncher.icon(for: app)
        item.state = chosen ? .on : .off
        item.isEnabled = enabled
        item.toolTip = chosen ? "The default for this kind of app" : "Opens the folder and makes \(app.name) the default"
        return item
    }

    private func symbolItem(_ title: String, symbol: String, enabled: Bool,
                            action: @escaping () -> Void) -> NSMenuItem {
        let item = ActionMenuItem(title: title, handler: action)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        item.isEnabled = enabled
        return item
    }

    /// "Worktree · navigation" or "Folder · orbit".
    private var folderHeader: String {
        if case .worktree(let name) = WorkspaceLabel.make(workspace: folder, project: projectPath) {
            return "Worktree · \(name)"
        }
        let name = URL(fileURLWithPath: folder).lastPathComponent
        return name.isEmpty ? "Folder" : "Folder · \(name)"
    }

    private static func isFolder(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// Pops a menu under a view, right-aligned with it.
@MainActor
private enum JumpMenu {
    /// Kept until the next menu, so no item outlives the menu that sends its action.
    private static var current: NSMenu?

    static func present(_ menu: NSMenu, under view: NSView) {
        current = menu
        let x = view.bounds.width - menu.size.width
        let y: CGFloat = view.isFlipped ? view.bounds.height + 4 : -4
        menu.popUp(positioning: nil, at: NSPoint(x: x, y: y), in: view)
    }
}

/// A menu item that runs a closure. The menu retains the item, and the item is its own target.
final class ActionMenuItem: NSMenuItem {
    private var handler: () -> Void = {}

    convenience init(title: String, handler: @escaping () -> Void) {
        self.init(title: title, action: #selector(fire(_:)), keyEquivalent: "")
        self.handler = handler
        target = self
    }

    @objc private func fire(_ sender: Any?) {
        handler()
    }
}

/// Menu titles with a quieter trailing detail, such as the profile name.
@MainActor
enum MenuText {
    static func title(_ main: String, detail: String?) -> NSAttributedString {
        let font = NSFont.menuFont(ofSize: 0)
        let text = NSMutableAttributedString(string: main, attributes: [.font: font])
        if let detail, !detail.isEmpty {
            text.append(NSAttributedString(string: "  " + detail,
                                           attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return text
    }
}

/// Small colored images for menu items. Menus render SF Symbols as templates,
/// so status and profile colors are drawn into fixed 14 pt canvases instead;
/// dynamic colors resolve when the menu draws.
@MainActor
enum MenuGlyph {
    private static let canvas = NSSize(width: 14, height: 14)

    /// Amber hand, green dot, hollow dot or dashed ring, as on the cards.
    static func status(_ kind: StatusGlyph.Kind) -> NSImage {
        let spec = symbolSpec(kind)
        let configuration = NSImage.SymbolConfiguration(pointSize: spec.size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [spec.color]))
        let symbol = NSImage(systemSymbolName: spec.name, accessibilityDescription: kind.title)?
            .withSymbolConfiguration(configuration)
        let image = NSImage(size: canvas, flipped: false) { rect in
            guard let symbol else { return false }
            let size = symbol.size
            symbol.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                                   width: size.width, height: size.height))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = kind.title
        return image
    }

    /// A profile dot: filled while its app is running, a ring otherwise.
    static func dot(_ color: NSColor, filled: Bool = true) -> NSImage {
        let image = NSImage(size: canvas, flipped: false) { rect in
            let circle = NSRect(x: rect.midX - 4, y: rect.midY - 4, width: 8, height: 8)
            if filled {
                color.setFill()
                NSBezierPath(ovalIn: circle).fill()
            } else {
                color.setStroke()
                let ring = NSBezierPath(ovalIn: circle.insetBy(dx: 0.75, dy: 0.75))
                ring.lineWidth = 1.5
                ring.stroke()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func symbolSpec(_ kind: StatusGlyph.Kind) -> (name: String, size: CGFloat, color: NSColor) {
        switch kind {
        case .needsInput: return ("hand.raised.fill", 11, Theme.Palette.needsInputNSColor)
        case .working: return ("circle.fill", 7.5, Theme.nsColor(hex: 0x0CA30C))
        case .idle: return ("circle", 9, NSColor.secondaryLabelColor)
        case .unknown: return ("circle.dashed", 9, Theme.nsColor(hex: 0x8A93A6))
        }
    }
}

// MARK: - Anchor

/// Holds the NSView a menu pops up under. A reference type, so @State keeps one box.
final class MenuAnchorBox {
    weak var view: NSView?
}

private struct MenuAnchor: NSViewRepresentable {
    let box: MenuAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = MenuAnchorView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}

/// Never takes a click: it only marks where the control sits.
private final class MenuAnchorView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
