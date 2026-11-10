import AppKit
import Foundation
import AgentTrailCore

// MARK: - Labels

/// How a live session is named in cards, menus and hints. Titles and
/// needs-action sentences come from conversations: they are shown, never
/// logged, cached or written anywhere.
enum SessionLabel {
    /// The conversation title when titles are shown, cleaned to one line.
    static func title(_ session: LiveAgentSession, showTitles: Bool, limit: Int = 120) -> String? {
        guard showTitles else { return nil }
        return clean(session.details.title, limit: limit)
    }

    /// Claude's "needs you to…" sentence. Hidden together with titles.
    static func needsAction(_ session: LiveAgentSession, showTitles: Bool) -> String? {
        guard showTitles, session.status == .waiting else { return nil }
        return clean(session.details.needsAction, limit: 240)
    }

    static func branch(_ session: LiveAgentSession) -> String? {
        clean(session.details.branch, limit: 80)
    }

    /// The worktree name for a worktree, otherwise the session folder's name.
    static func folder(_ session: LiveAgentSession) -> String {
        if case .worktree(let name) = WorkspaceLabel.make(workspace: session.workspacePath, project: session.projectPath) {
            return name
        }
        let path = session.workspacePath.isEmpty ? session.projectPath : session.workspacePath
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// Title, else branch, else folder.
    static func make(_ session: LiveAgentSession, showTitles: Bool, limit: Int = 120) -> String {
        title(session, showTitles: showTitles, limit: limit) ?? branch(session) ?? folder(session)
    }

    /// `word` for the status, or "Working in background" while a command from a
    /// finished turn still runs.
    static func state(_ session: LiveAgentSession, word: String) -> String {
        session.status == .working && session.details.backgroundSince != nil ? "Working in background" : word
    }

    /// The action word on the Jump button.
    static func verb(_ status: LiveStatus) -> String {
        switch status {
        case .waiting: return "Answer"
        case .working: return "Open"
        case .idle, .unknown: return "Resume"
        }
    }

    /// One line without control or bidirectional-override characters, collapsed
    /// spaces, and an ellipsis past `limit` characters. Empty text becomes nil.
    static func clean(_ text: String?, limit: Int) -> String? {
        guard let text else { return nil }
        let scalars = text.unicodeScalars.map { (scalar: Unicode.Scalar) -> Unicode.Scalar in
            CharacterSet.newlines.contains(scalar) || scalar == "\t" ? " " : scalar
        }.filter { !CharacterSet.controlCharacters.contains($0) }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        let collapsed = String(view).split(separator: " ").joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard limit > 1, collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

/// Time in the current state, when the assistant records when it began.
enum ElapsedFormat {
    /// "<1m", "4m", "2h", "1d". Nil without a start or for a start in the future.
    static func compact(since: Date?, now: Date) -> String? {
        guard let seconds = elapsed(since: since, now: now) else { return nil }
        if seconds < 60 { return "<1m" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds / 86_400))d"
    }

    /// "less than a minute", "4 minutes", "2 hours", "1 day".
    static func spoken(since: Date?, now: Date) -> String? {
        guard let seconds = elapsed(since: since, now: now) else { return nil }
        if seconds < 60 { return "less than a minute" }
        let parts: (value: Int, unit: String)
        if seconds < 3_600 {
            parts = (Int(seconds / 60), "minute")
        } else if seconds < 86_400 {
            parts = (Int(seconds / 3_600), "hour")
        } else {
            parts = (Int(seconds / 86_400), "day")
        }
        return "\(parts.value) \(parts.value == 1 ? parts.unit : parts.unit + "s")"
    }

    /// A small clock skew still reads as "<1m"; anything further ahead is not trusted.
    private static func elapsed(since: Date?, now: Date) -> TimeInterval? {
        guard let since else { return nil }
        let seconds = now.timeIntervalSince(since)
        guard seconds.isFinite, seconds > -60 else { return nil }
        return max(0, seconds)
    }
}

// MARK: - Workspace actions

/// An editor or terminal Agent Trail can hand a folder to.
struct ExternalApp: Hashable, Identifiable {
    enum Kind: Hashable {
        case editor
        case terminal
    }

    let bundleID: String
    let name: String
    let kind: Kind
    let url: URL
    var id: String { bundleID }
}

/// One action on a session's or a project's folder. None needs a permission.
enum WorkspaceAction: Hashable {
    case openWith(path: String, app: ExternalApp)
    case revealInFinder(path: String)
    case copyPath(String)
    case openPullRequest(URL)
}

/// What a jump did, for the store to report.
enum JumpOutcome: Equatable {
    /// The session opened, or its app came forward and needs nothing more.
    case done
    /// The app came forward, but the user still has to pick the session there.
    case hint(String, symbol: String)
    case failed(String)
}

/// Facts the launcher needs beyond the session, already filtered by the
/// "Show session titles" setting.
struct JumpContext {
    let profileName: String
    /// Shown in hints. Nil when titles are hidden or missing.
    let title: String?
    /// Folder or worktree name, used when there is no title.
    let folder: String
    /// When the live scan that reported this session finished.
    let verifiedAt: Date?
}

// MARK: - Launcher

/// Opens the work behind a live session. It uses only NSWorkspace and
/// NSRunningApplication: no Apple Events, AppleScript, Accessibility or
/// Automation. A session link is opened only in an app that is already
/// running, addressed by that app's bundle; an assistant is never launched.
@MainActor
enum SessionLauncher {
    static let claudeBundleID = "com.anthropic.claudefordesktop"
    static let codexBundleID = "com.openai.codex"
    static let cursorBundleID = "com.todesktop.230313mzl4w4u92"

    /// Detection order; the first installed app is the default choice.
    static let editorCatalog: [(bundleID: String, name: String)] = [
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.microsoft.VSCode", "VS Code"),
        ("dev.zed.Zed", "Zed"),
        ("com.apple.dt.Xcode", "Xcode")
    ]
    static let terminalCatalog: [(bundleID: String, name: String)] = [
        ("com.apple.Terminal", "Terminal"),
        ("com.googlecode.iterm2", "iTerm2"),
        ("com.mitchellh.ghostty", "Ghostty")
    ]
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "com.mitchellh.ghostty", "dev.warp.Warp-Stable"
    ]

    // MARK: Jump

    /// The launcher order: (1) a Claude Desktop link, sent only when this
    /// profile's instance is the one macOS hands links to (the one launched
    /// first), else the profile's instance comes forward with a hint; a Claude
    /// session started in a terminal skips this and goes to its terminal; (2) a Codex thread link
    /// when the ChatGPT app owns the thread and runs; (3) the running host app,
    /// the instance the session runs under when several run;
    /// (4) the session's own app, else the folder in a running preferred
    /// editor, else Finder. `report` is called once, possibly later.
    static func jump(_ session: LiveAgentSession, source: AgentSource?, context: JumpContext,
                     report: @escaping (JumpOutcome) -> Void) {
        // `claude` in a terminal belongs to that terminal, not to Claude Desktop.
        if let source, source.assistant == .claude, !source.bundleIdentifier.isEmpty, !session.details.startedInTerminal {
            jumpToClaude(session, source: source, context: context, report: report)
            return
        }
        if let source, source.assistant == .codex,
           openCodexThread(session, context: context, report: report) {
            return
        }
        if let source, source.assistant == .cursor,
           openCursorChat(session, context: context, report: report) {
            return
        }
        if let outcome = activateHost(of: session, source: source, context: context) {
            report(outcome)
            return
        }
        if activateSessionApp(session, verifiedAt: context.verifiedAt) {
            report(.done)
            return
        }
        report(openFolderFallback(workspaceFolder(for: session), context: context))
    }

    private static func jumpToClaude(_ session: LiveAgentSession, source: AgentSource, context: JumpContext,
                                     report: @escaping (JumpOutcome) -> Void) {
        let hint = pickHint(app: source.name, title: context.title, noun: "session", folder: context.folder)
        guard source.bundleIdentifier == claudeBundleID,
              let sessionID = session.details.desktopSessionID, isDesktopSessionID(sessionID),
              let url = URL(string: "claude://code/continue?session=\(sessionID)") else {
            // No usable link: bring the profile's own instance forward and say what to pick.
            report(focusProfile(source, hint: hint))
            return
        }
        // Several Claude instances share one bundle id, and macOS hands every link
        // to the one launched first, whichever is in front. A link for another
        // instance's session would reach that first instance, which opens its own
        // Code home, so those sessions get a hint instead.
        guard let instance = linkRecipient(for: source), let bundleURL = instance.bundleURL else {
            report(focusProfile(source, hint: hint))
            return
        }
        openLink(url, in: bundleURL) { recipient in
            // Nil when the link failed. Another pid means the instances changed since
            // the check, and that instance already has the link: say what to pick.
            guard recipient == instance.processIdentifier else {
                report(focusProfile(source, hint: hint))
                return
            }
            // Claude shows its own window for a link; this makes sure the
            // verified instance is the one in front.
            _ = InstanceController.focus(source: source)
            report(.done)
        }
    }

    private static func focusProfile(_ source: AgentSource, hint: String) -> JumpOutcome {
        if let error = InstanceController.focus(source: source) { return .failed(error) }
        return .hint(hint, symbol: "sidebar.left")
    }

    /// The running Claude that receives claude:// links, and only when it is
    /// this profile's instance.
    private static func linkRecipient(for source: AgentSource) -> NSRunningApplication? {
        let running = runningApplications(claudeBundleID)
        let instances = running.map { LinkRecipient.Instance(pid: $0.processIdentifier, launchDate: $0.launchDate) }
        guard let pid = LinkRecipient.pid(among: instances),
              InstanceController.runningInstances(sources: [source])[source.id] == pid else { return nil }
        return running.first { $0.processIdentifier == pid }
    }

    /// Returns false when step 2 does not apply, so the next step runs.
    private static func openCodexThread(_ session: LiveAgentSession, context: JumpContext,
                                        report: @escaping (JumpOutcome) -> Void) -> Bool {
        guard session.details.hostBundleID == codexBundleID else { return false }
        let running = runningApplications(codexBundleID)
        guard running.count == 1, let app = running.first, let bundleURL = app.bundleURL,
              let thread = threadID(session.details.parentThreadID) ?? threadID(session.sessionID),
              let url = URL(string: "codex://threads/\(thread)") else { return false }
        openLink(url, in: bundleURL) { recipient in
            report(recipient != nil ? .done : activateWithHint(app, context: context))
        }
        return true
    }

    /// A Cursor app chat opens with Cursor's own link in the one running
    /// Cursor: `cursor://anysphere.cursor-deeplink/agent?id=<chat>` brings
    /// Cursor forward and selects the chat in its Agents window (Cursor 3.29;
    /// no link reaches an editor window's chat pane). With several Cursor
    /// instances, or when the link can't be opened, Cursor is brought forward
    /// instead. Returns false when this step does not apply.
    private static func openCursorChat(_ session: LiveAgentSession, context: JumpContext,
                                       report: @escaping (JumpOutcome) -> Void) -> Bool {
        guard session.details.hostBundleID == cursorBundleID else { return false }
        let running = runningApplications(cursorBundleID).filter { $0.activationPolicy == .regular }
        guard running.count == 1, let app = running.first, let bundleURL = app.bundleURL,
              let url = cursorChatURL(session.sessionID) else { return false }
        openLink(url, in: bundleURL) { recipient in
            report(recipient != nil ? .done : activateWithHint(app, context: context))
        }
        return true
    }

    /// `cursor://anysphere.cursor-deeplink/agent?id=<chat>` for a chat id of
    /// ASCII letters, digits and `-` (Cursor's chat ids are UUIDs).
    nonisolated static func cursorChatURL(_ id: String) -> URL? {
        let bytes = Array(id.utf8)
        guard (1...128).contains(bytes.count),
              bytes.allSatisfy({ isASCIIAlphanumeric($0) || $0 == UInt8(ascii: "-") }) else { return nil }
        var components = URLComponents()
        components.scheme = "cursor"
        components.host = "anysphere.cursor-deeplink"
        components.path = "/agent"
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url
    }

    /// Step 3: the app that owns the session (a terminal for Grok or terminal Claude, Claude
    /// Desktop when either runs in its terminal pane, an editor or the ChatGPT app for Codex),
    /// when it is running.
    private static func activateHost(of session: LiveAgentSession, source: AgentSource?,
                                     context: JumpContext) -> JumpOutcome? {
        guard let bundleID = session.details.hostBundleID, isBundleIdentifier(bundleID) else { return nil }
        let running = runningApplications(bundleID)
        guard let app = enclosingInstance(of: session.pid, among: running) ?? preferredInstance(running) else {
            return nil
        }
        // These hosts were named by terminal hints, so the session sits in a
        // terminal even when the host is an editor or Claude Desktop.
        let inTerminal = session.details.startedInTerminal || source?.assistant.descriptor.hosting == .terminal
        return activateWithHint(app, inTerminal: inTerminal, context: context)
    }

    /// With several instances of the host running (two Claude profiles, each
    /// with its own terminal pane), the one the session process runs under.
    private static func enclosingInstance(of pid: pid_t, among apps: [NSRunningApplication]) -> NSRunningApplication? {
        guard apps.count > 1, pid > 0 else { return nil }
        var current = pid
        // claude → shell → Claude Helper → Claude is three steps; 16 bounds a loop.
        for _ in 0..<16 {
            guard let parent = ProcessIdentity.parentProcessID(of: current) else { return nil }
            if let app = apps.first(where: { $0.processIdentifier == parent }) { return app }
            current = parent
        }
        return nil
    }

    private static func activateWithHint(_ app: NSRunningApplication, inTerminal: Bool = false,
                                         context: JumpContext) -> JumpOutcome {
        let name = app.localizedName ?? "the app"
        let isTerminal = app.bundleIdentifier.map { terminalBundleIDs.contains($0) } ?? false
        let brought = isTerminal || inTerminal ? activate(app) : bringForward(app)
        guard brought else { return .failed("macOS did not accept the request to bring \(name) forward.") }
        // A terminal app's sessions are tabs; an editor's or Claude Desktop's are its terminal panes.
        let noun = isTerminal ? "tab" : inTerminal ? "terminal" : "session"
        let hint = pickHint(app: name, title: context.title, noun: noun, folder: context.folder)
        return .hint(hint, symbol: isTerminal || inTerminal ? "terminal" : "macwindow")
    }

    /// Step 4a: the session process itself, when it is a regular app that was
    /// already running when the scan reported it (a reused pid is not trusted).
    private static func activateSessionApp(_ session: LiveAgentSession, verifiedAt: Date?) -> Bool {
        guard session.pid > 0, let verifiedAt,
              let app = NSRunningApplication(processIdentifier: session.pid), !app.isTerminated,
              app.activationPolicy == .regular,
              let launched = app.launchDate, launched <= verifiedAt else { return false }
        return activate(app)
    }

    /// Step 4b: a running preferred editor gets the folder; otherwise Finder
    /// shows it. An editor that is not running is never launched here.
    private static func openFolderFallback(_ folder: String, context: JumpContext) -> JumpOutcome {
        guard folderExists(folder) else { return .failed("This folder is no longer available: \(folder)") }
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        if let editor = preferredApp(.editor), !runningApplications(editor.bundleID).isEmpty {
            openFolder(url, with: editor.url) { _ in }
            return .hint("No app to switch to · opened \(context.folder) in \(editor.name)", symbol: "folder")
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        return .hint("No app to switch to · showing \(context.folder) in Finder", symbol: "folder")
    }

    // MARK: Workspace actions

    /// `report` receives a message to show when an action fails.
    static func perform(_ action: WorkspaceAction, report: @escaping (String) -> Void) {
        switch action {
        case .openWith(let path, let app):
            guard folderExists(path) else { return report("This folder is no longer available: \(path)") }
            // Re-resolve, in case the app moved or was removed since the menu opened.
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID) else {
                return report("\(app.name) is no longer installed.")
            }
            remember(app)
            openFolder(URL(fileURLWithPath: path, isDirectory: true), with: appURL) { opened in
                if !opened { report("\(app.name) could not open \(URL(fileURLWithPath: path).lastPathComponent).") }
            }
        case .revealInFinder(let path):
            guard folderExists(path) else { return report("This folder is no longer available: \(path)") }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path, isDirectory: true)])
        case .copyPath(let path):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        case .openPullRequest(let url):
            guard let safe = pullRequestURL(url) else { return report("Only https pull request links can be opened.") }
            NSWorkspace.shared.open(safe)
        }
    }

    /// The folder workspace actions use: the session's worktree or folder, or
    /// the project when the session was started outside it.
    nonisolated static func workspaceFolder(for session: LiveAgentSession) -> String {
        if case .launchedFrom = WorkspaceLabel.make(workspace: session.workspacePath, project: session.projectPath) {
            return session.projectPath
        }
        return session.workspacePath.isEmpty ? session.projectPath : session.workspacePath
    }

    // MARK: Editors and terminals

    private static var detected: [ExternalApp.Kind: (apps: [ExternalApp], at: Date)] = [:]
    private static var icons: [String: NSImage] = [:]

    /// Installed apps in catalog order, re-checked at most once a minute.
    static func installedApps(_ kind: ExternalApp.Kind) -> [ExternalApp] {
        if let cached = detected[kind], Date().timeIntervalSince(cached.at) < 60 { return cached.apps }
        let catalog = kind == .editor ? editorCatalog : terminalCatalog
        let apps = catalog.compactMap { (entry: (bundleID: String, name: String)) -> ExternalApp? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID) else { return nil }
            return ExternalApp(bundleID: entry.bundleID, name: entry.name, kind: kind, url: url)
        }
        detected[kind] = (apps, Date())
        return apps
    }

    /// The remembered choice when it is still installed, else the first installed.
    static func preferredApp(_ kind: ExternalApp.Kind) -> ExternalApp? {
        let apps = installedApps(kind)
        let stored = kind == .editor ? AppSettings.preferredEditorBundleID : AppSettings.preferredTerminalBundleID
        return apps.first { $0.bundleID == stored } ?? apps.first
    }

    /// The last app chosen for a folder becomes the default for its kind.
    static func remember(_ app: ExternalApp) {
        switch app.kind {
        case .editor: AppSettings.preferredEditorBundleID = app.bundleID
        case .terminal: AppSettings.preferredTerminalBundleID = app.bundleID
        }
    }

    /// The app's Finder icon at menu size.
    static func icon(for app: ExternalApp) -> NSImage {
        if let cached = icons[app.bundleID] { return cached }
        let image = (NSWorkspace.shared.icon(forFile: app.url.path).copy() as? NSImage) ?? NSImage()
        image.size = NSSize(width: 16, height: 16)
        icons[app.bundleID] = image
        return image
    }

    // MARK: Validation

    /// ASCII ^local_[A-Za-z0-9-]{1,64}$, checked byte by byte.
    nonisolated static func isDesktopSessionID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        let prefix = Array("local_".utf8)
        guard bytes.count > prefix.count, bytes.count <= prefix.count + 64,
              Array(bytes.prefix(prefix.count)) == prefix else { return false }
        return bytes.dropFirst(prefix.count).allSatisfy { byte in
            isASCIIAlphanumeric(byte) || byte == UInt8(ascii: "-")
        }
    }

    /// A canonical 36-character UUID, returned as given.
    nonisolated static func threadID(_ value: String?) -> String? {
        guard let value, value.utf8.count == 36,
              value.utf8.allSatisfy({ isASCIIHex($0) || $0 == UInt8(ascii: "-") }),
              UUID(uuidString: value) != nil else { return nil }
        return value
    }

    /// https with a host and no user or password.
    nonisolated static func pullRequestURL(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }
        return url
    }

    nonisolated static func isBundleIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (3...255).contains(bytes.count), bytes.contains(UInt8(ascii: ".")) else { return false }
        return bytes.allSatisfy { isASCIIAlphanumeric($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") }
    }

    // MARK: Helpers

    /// "In Claude · Second, pick “Landing copy pass”" or "…, pick the tab in orbit".
    private static func pickHint(app: String, title: String?, noun: String, folder: String) -> String {
        if let title = SessionLabel.clean(title, limit: 60) { return "In \(app), pick “\(title)”" }
        return "In \(app), pick the \(noun) in \(folder)"
    }

    private static func runningApplications(_ bundleID: String) -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { !$0.isTerminated }
    }

    /// A regular (Dock) instance wins over a helper with the same bundle id.
    private static func preferredInstance(_ apps: [NSRunningApplication]) -> NSRunningApplication? {
        apps.first { $0.activationPolicy == .regular } ?? apps.first
    }

    /// A desktop app, brought forward the way a Dock click does: through
    /// LaunchServices, on the running app's own bundle, which also switches to
    /// its Space. A cooperative `activate` can be accepted and still change
    /// nothing (seen with Cursor 3.29), as can one aimed at an app whose
    /// windows are elsewhere. With several instances of the bundle running,
    /// LaunchServices could pick another one, so the chosen instance is
    /// activated directly. This never launches an app: it runs only for an
    /// app found running, and checks it again first.
    private static func bringForward(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated, let bundle = app.bundleURL, let id = app.bundleIdentifier,
              runningApplications(id).filter({ $0.activationPolicy == .regular }).count == 1,
              app.activationPolicy == .regular else { return activate(app) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSApp.yieldActivation(to: app)
        guard !app.isTerminated else { return false }
        NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in }
        return true
    }

    private static func activate(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated else { return false }
        NSApp.yieldActivation(to: app)
        return app.activate(from: NSRunningApplication.current, options: [])
    }

    /// Opens a link in one specific, already running app bundle, so no other
    /// handler of the scheme can receive it. `completion` gets the pid NSWorkspace
    /// reports as the recipient (it matched the receiving Claude in the system
    /// log), or nil when the link could not be opened.
    private static func openLink(_ url: URL, in bundleURL: URL, completion: @escaping (pid_t?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.open([url], withApplicationAt: bundleURL, configuration: configuration) { application, error in
            let recipient = error == nil ? application?.processIdentifier : nil
            DispatchQueue.main.async { completion(recipient) }
        }
    }

    private static func openFolder(_ folder: URL, with appURL: URL, completion: @escaping (Bool) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.open([folder], withApplicationAt: appURL, configuration: configuration) { application, error in
            let opened = application != nil && error == nil
            DispatchQueue.main.async { completion(opened) }
        }
    }

    private static func folderExists(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private nonisolated static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    private nonisolated static func isASCIIHex(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
    }
}
