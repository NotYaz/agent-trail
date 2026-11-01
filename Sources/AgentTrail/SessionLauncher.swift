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

    /// The launcher order: (1) a Claude Desktop link, sent to this profile's
    /// instance (directly when it is the only Claude, else once it is frontmost),
    /// falling back to that instance plus a hint; (2) a Codex thread link
    /// when the ChatGPT app owns the thread and runs; (3) the running host app;
    /// (4) the session's own app, else the folder in a running preferred
    /// editor, else Finder. `report` is called once, possibly later.
    static func jump(_ session: LiveAgentSession, source: AgentSource?, context: JumpContext,
                     report: @escaping (JumpOutcome) -> Void) {
        if let source, source.assistant == .claude, !source.bundleIdentifier.isEmpty {
            jumpToClaude(session, source: source, context: context, report: report)
            return
        }
        if let source, source.assistant == .codex,
           openCodexThread(session, context: context, report: report) {
            return
        }
        if let outcome = activateHost(of: session, context: context) {
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
        guard let instance = soleClaudeInstance(for: source), let bundleURL = instance.bundleURL else {
            jumpToClaudeInstance(url, source: source, hint: hint, report: report)
            return
        }
        openLink(url, in: bundleURL) { opened in
            if opened {
                // Claude shows its own window for a link; this makes sure the
                // verified instance is the one in front.
                _ = InstanceController.focus(source: source)
                report(.done)
            } else {
                report(focusProfile(source, hint: hint))
            }
        }
    }

    /// Several Claude instances share one bundle id, so a link cannot name one.
    /// macOS hands a claude:// link to the frontmost instance (checked with
    /// Claude · Main and Claude · Second running), so this profile's instance is
    /// brought forward first and the link is sent only once it is frontmost.
    /// If it does not come forward in time, no link is sent and a hint names the
    /// session to pick; if another instance takes the front after the link, the
    /// profile's instance is focused again with the same hint.
    private static func jumpToClaudeInstance(_ url: URL, source: AgentSource, hint: String,
                                             report: @escaping (JumpOutcome) -> Void) {
        guard let pid = InstanceController.runningInstances(sources: [source])[source.id],
              let app = NSRunningApplication(processIdentifier: pid), let bundleURL = app.bundleURL else {
            report(focusProfile(source, hint: hint))
            return
        }
        if let error = InstanceController.focus(source: source) {
            report(.failed(error))
            return
        }
        whenFrontmost(pid, timeout: 1.5) { frontmost in
            guard frontmost else {
                report(.hint(hint, symbol: "sidebar.left"))
                return
            }
            openLink(url, in: bundleURL) { opened in
                guard opened else {
                    report(focusProfile(source, hint: hint))
                    return
                }
                // The instance that handled the link shows its window; check it
                // was this profile's before calling the jump done.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                        report(.done)
                    } else {
                        report(focusProfile(source, hint: hint))
                    }
                }
            }
        }
    }

    /// Calls back once `pid` is the frontmost app, or with false after `timeout`.
    /// Runs only after a click, for at most `timeout` seconds.
    private static func whenFrontmost(_ pid: pid_t, timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        func check() {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                completion(true)
            } else if Date() >= deadline {
                completion(false)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { check() }
            }
        }
        check()
    }

    private static func focusProfile(_ source: AgentSource, hint: String) -> JumpOutcome {
        if let error = InstanceController.focus(source: source) { return .failed(error) }
        return .hint(hint, symbol: "sidebar.left")
    }

    /// The one running Claude, and only when it is this profile's instance.
    private static func soleClaudeInstance(for source: AgentSource) -> NSRunningApplication? {
        let running = runningApplications(claudeBundleID)
        guard running.count == 1 else { return nil }
        let instance = running[0]
        guard InstanceController.runningInstances(sources: [source])[source.id] == instance.processIdentifier else {
            return nil
        }
        return instance
    }

    /// Returns false when step 2 does not apply, so the next step runs.
    private static func openCodexThread(_ session: LiveAgentSession, context: JumpContext,
                                        report: @escaping (JumpOutcome) -> Void) -> Bool {
        guard session.details.hostBundleID == codexBundleID else { return false }
        let running = runningApplications(codexBundleID)
        guard running.count == 1, let app = running.first, let bundleURL = app.bundleURL,
              let thread = threadID(session.details.parentThreadID) ?? threadID(session.sessionID),
              let url = URL(string: "codex://threads/\(thread)") else { return false }
        openLink(url, in: bundleURL) { opened in
            report(opened ? .done : activateWithHint(app, context: context))
        }
        return true
    }

    /// Step 3: the app that owns the session (a terminal for Grok, an editor or
    /// the ChatGPT app for Codex), when it is running.
    private static func activateHost(of session: LiveAgentSession, context: JumpContext) -> JumpOutcome? {
        guard let bundleID = session.details.hostBundleID, isBundleIdentifier(bundleID),
              let app = preferredInstance(runningApplications(bundleID)) else { return nil }
        return activateWithHint(app, context: context)
    }

    private static func activateWithHint(_ app: NSRunningApplication, context: JumpContext) -> JumpOutcome {
        let name = app.localizedName ?? "the app"
        guard activate(app) else { return .failed("macOS did not accept the request to bring \(name) forward.") }
        let isTerminal = app.bundleIdentifier.map { terminalBundleIDs.contains($0) } ?? false
        let hint = pickHint(app: name, title: context.title, noun: isTerminal ? "tab" : "session", folder: context.folder)
        return .hint(hint, symbol: isTerminal ? "terminal" : "macwindow")
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

    private static func activate(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated else { return false }
        NSApp.yieldActivation(to: app)
        return app.activate(from: NSRunningApplication.current, options: [])
    }

    /// Opens a link in one specific, already running app bundle, so no other
    /// handler of the scheme can receive it.
    private static func openLink(_ url: URL, in bundleURL: URL, completion: @escaping (Bool) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.open([url], withApplicationAt: bundleURL, configuration: configuration) { application, error in
            let opened = application != nil && error == nil
            DispatchQueue.main.async { completion(opened) }
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
