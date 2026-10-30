import AppKit
import SwiftUI
import AgentTrailCore

@main
enum AgentTrailApp {
    @MainActor static func main() {
        let application = NSApplication.shared
        if let index = CommandLine.arguments.firstIndex(of: "--render-demo") {
            guard index + 1 < CommandLine.arguments.count else {
                fputs("Usage: AgentTrail --render-demo OUTPUT.png [--light]\n", stderr)
                exit(2)
            }
            do {
                try renderDemo(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            } catch {
                fputs("Could not render sample data: \(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }
        let delegate = AgentTrailApplicationDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) {
            application.run()
        }
    }

    @MainActor private static func renderDemo(to output: URL) throws {
        let view = NSHostingView(rootView: AgentTrailPanel(store: AppStore(demoMode: true)))
        view.appearance = NSAppearance(named: CommandLine.arguments.contains("--light") ? .aqua : .darkAqua)
        view.frame = NSRect(x: 0, y: 0, width: 470, height: 640)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: output, options: .atomic)
    }
}

@MainActor
private final class AgentTrailApplicationDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var store: AppStore?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let store = AppStore()
        self.store = store
        store.showProfiles = { [weak self] in self?.showProfileSettings() }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 470, height: 640)
        popover.contentViewController = NSHostingController(rootView: AgentTrailPanel(store: store))
        self.popover = popover

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted",
                                   accessibilityDescription: "Agent Trail")
            button.image?.isTemplate = true
            button.toolTip = "Agent Trail"
            button.setAccessibilityLabel("Agent Trail")
            button.target = self
            button.action = #selector(togglePanel(_:))
        }
        self.statusItem = statusItem

        DispatchQueue.main.async { [weak self] in self?.showPanel() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc private func togglePanel(_ sender: Any?) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let button = statusItem?.button, let popover else { return }
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

private struct AgentTrailPanel: View {
    @ObservedObject var store: AppStore
    @State private var search = ""
    @State private var sharedOnly = false
    @State private var showNotices = false

    private var visibleProjects: [ProjectSummary] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.projects.filter { project in
            (!sharedOnly || project.isShared) &&
            (query.isEmpty || project.path.localizedCaseInsensitiveContains(query) ||
             project.activities.contains { activity in
                 sourceName(activity.sourceID).localizedCaseInsensitiveContains(query)
             })
        }
    }

    private var sharedCount: Int { store.projects.filter(\.isShared).count }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchAndFilters

            if let error = store.errorMessage, !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
            }

            if store.projects.isEmpty && store.isScanning {
                loadingState
            } else if visibleProjects.isEmpty {
                emptyState
            } else {
                projectList
            }

            if !store.notices.isEmpty { notices }
            footer
        }
        .frame(width: 470, height: 640)
        .background(.regularMaterial)
        .task { store.refresh() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 42, height: 42)
                    .background(.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Agent Trail")
                        .font(.system(size: 19, weight: .semibold))
                    Text(store.demoMode ? "Sample data · no local history" : "Your projects, across assistants")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if store.isScanning {
                    ProgressView().controlSize(.small).padding(.top, 9)
                        .help("Reading local activity records")
                }
            }

            HStack(spacing: 6) {
                Text("\(store.projects.count)")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Text(store.projects.count == 1 ? "project" : "projects")
                Text("·").padding(.horizontal, 3)
                Text("\(sharedCount)")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Text("shared")
                Spacer()
                Text(store.demoMode ? "\(store.sources.count) sample profiles" : "\(store.sources.count) profiles · \(store.runningSourceIDs.count) running")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 15)
    }

    private var searchAndFilters: some View {
        VStack(spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Find a project or profile", text: $search)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .accessibilityLabel("Find a project or profile")
                if !search.isEmpty {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.primary.opacity(0.07), lineWidth: 1))

            HStack {
                Text("RECENT PROJECTS")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle(isOn: $sharedOnly) {
                    Label("Shared only", systemImage: "square.on.square")
                        .font(.system(size: 11, weight: .medium))
                }
                .toggleStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Show projects found in more than one assistant profile")
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 12)
    }

    private var projectList: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(visibleProjects) { project in
                    ProjectCard(project: project, sources: store.sources,
                                runningSourceIDs: store.runningSourceIDs,
                                isScanning: store.isScanning,
                                open: store.focus, reveal: { store.reveal(project) },
                                copyPath: { store.copyPath(project) })
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.automatic)
    }

    private var loadingState: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.regular)
            Text("Finding your projects…")
                .font(.system(size: 13, weight: .medium))
            Text("Reading the activity saved by your assistant profiles.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: search.isEmpty ? "folder.badge.questionmark" : "magnifyingglass")
                .font(.system(size: 31, weight: .light))
                .foregroundStyle(.tertiary)
            Text(search.isEmpty ? (sharedOnly ? "No shared projects yet" : "No projects found yet") : "No matching projects")
                .font(.system(size: 14, weight: .semibold))
            Text(search.isEmpty
                 ? (sharedOnly ? "A project appears here when more than one profile works in the same folder."
                    : "Projects appear when Claude saves a local coding session. Check the profile notices below for details.")
                 : "Try a different folder name or assistant profile.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if sharedOnly || !search.isEmpty {
                Button("Show all projects") { search = ""; sharedOnly = false }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .padding(38)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notices: some View {
        DisclosureGroup(isExpanded: $showNotices) {
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(store.notices.enumerated()), id: \.offset) { _, notice in
                        Text(notice)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 7)
            }
            .frame(maxHeight: 100)
        } label: {
            Label("\(store.notices.count) profile \(store.notices.count == 1 ? "notice" : "notices")", systemImage: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.primary.opacity(0.025))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button { store.refresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .disabled(store.isScanning)
                .help("Read the latest local activity")
                Spacer(minLength: 4)
                if let progress = store.scanProgress {
                    Text(progress)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(progress)
                } else if let lastScan = store.lastScan {
                    Text(lastScan, style: .time)
                        .foregroundStyle(.tertiary)
                        .help("Last refreshed \(lastScan.formatted(date: .abbreviated, time: .standard))")
                }
                Menu {
                    Button("Profiles…") { store.showProfiles?() }
                        .disabled(store.demoMode)
                    Button("Reload profiles") { store.reloadProfiles() }
                        .disabled(store.demoMode)
                    Divider()
                    Link("Project on GitHub", destination: URL(string: "https://github.com/NotYaz/agent-trail")!)
                    Link("Support development", destination: URL(string: "https://github.com/NotYaz/agent-trail/blob/main/docs/SUPPORT.md")!)
                    Divider()
                    Button("Quit Agent Trail", role: .destructive) {
                        NSApplication.shared.terminate(nil)
                    }
                    .keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("About and quit Agent Trail")
            }
            .font(.system(size: 11))
            .padding(.horizontal, 20)
            .padding(.vertical, 13)
        }
    }

    private func sourceName(_ id: String) -> String {
        store.sources.first { $0.id == id }?.name ?? id
    }
}

private struct ProjectCard: View {
    let project: ProjectSummary
    let sources: [AgentSource]
    let runningSourceIDs: Set<String>
    let isScanning: Bool
    let open: (AgentSource) -> Void
    let reveal: () -> Void
    let copyPath: () -> Void

    private var involvedSources: [AgentSource] {
        project.activities.compactMap { activity in sources.first { $0.id == activity.sourceID } }
    }

    private var activityMatchesEdit: Bool {
        project.latestEdit?.sourceID == project.latestActivity.sourceID
    }

    private var activityHelp: String {
        let activity = project.latestActivity
        let sourceName = sources.first { $0.id == activity.sourceID }?.name ?? activity.sourceID
        return "Latest activity · \(sourceName)\nThe most recent saved session activity, which may not include a file change.\nWorkspace: \(activity.workspacePath ?? project.path)\n\(activity.latestActivity.formatted(date: .abbreviated, time: .standard))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Image(systemName: "folder")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Text(project.name.isEmpty ? project.path : project.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if project.isShared {
                        Text("SHARED")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.6)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.primary.opacity(0.06), in: Capsule())
                            .help("The same project folder appears in multiple assistant profiles")
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Button("Reveal in Finder", systemImage: "folder") { reveal() }
                        Button("Copy project path", systemImage: "doc.on.doc") { copyPath() }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundStyle(.secondary)
                            .frame(width: 18, height: 18)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Project actions")
                }
                Text(abbreviatedPath(project.path))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(project.path)
            }

            VStack(alignment: .leading, spacing: 6) {
                if let edit = project.latestEdit, let date = edit.latestEdit {
                    activityLine(title: "Last recorded edit", sourceID: edit.sourceID, date: date, prominent: true)
                        .help("Successful recorded Edit/Write tools; shell and external changes are not attributed. \(date.formatted(date: .abbreviated, time: .standard))")
                    if let worktree = edit.latestEditWorkspacePath, worktree != project.path {
                        Label("Worktree · \(URL(fileURLWithPath: worktree).lastPathComponent)", systemImage: "arrow.triangle.branch")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help("This edit was made in a separate worktree: \(worktree)\nProject origin: \(project.path)")
                    }
                } else {
                    HStack(spacing: 5) {
                        Image(systemName: "pencil.line").font(.system(size: 10))
                        Text(isScanning ? "Checking edit history…" : "No recorded file edits").font(.system(size: 11))
                    }
                    .foregroundStyle(.tertiary)
                    .help("Successful recorded Edit/Write tools; shell and external changes are not attributed.")
                }
                if !activityMatchesEdit {
                    activityLine(title: "Latest activity", sourceID: project.latestActivity.sourceID,
                                 date: project.latestActivity.latestActivity, prominent: false)
                        .help(activityHelp)
                }
            }

            HStack(spacing: 7) {
                ForEach(involvedSources) { source in
                    Button { open(source) } label: {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(runningSourceIDs.contains(source.id) ? sourceColor(source.id) : .clear)
                                .overlay(Circle().stroke(sourceColor(source.id), lineWidth: 1))
                                .frame(width: 5, height: 5)
                            Text(openLabel(source))
                                .font(.system(size: 10, weight: .medium))
                                .lineLimit(1)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(sourceColor(source.id).opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(sourceColor(source.id).opacity(0.16), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .help(runningSourceIDs.contains(source.id)
                          ? "Focus the running \(source.name) instance"
                          : "\(source.name) is not currently identified as running. Click to check again.")
                    .accessibilityLabel("Focus \(source.name) for \(project.name)")
                }
                Spacer(minLength: 0)
                if activityMatchesEdit {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text("Active \(relativeDate(project.latestActivity.latestActivity, now: context.date))")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    .help(activityHelp)
                }
            }
        }
        .padding(13)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.055), lineWidth: 1))
        .contextMenu {
            Button("Reveal in Finder", systemImage: "folder") { reveal() }
            Button("Copy project path", systemImage: "doc.on.doc") { copyPath() }
        }
    }

    private func activityLine(title: String, sourceID: String, date: Date, prominent: Bool) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .foregroundStyle(.secondary)
                .font(.system(size: 10))
            Circle().fill(sourceColor(sourceID)).frame(width: 5, height: 5)
            Text(sources.first { $0.id == sourceID }?.name ?? sourceID)
                .font(.system(size: 10, weight: prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? .primary : .secondary)
                .lineLimit(1)
            Spacer(minLength: 3)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(relativeDate(date, now: context.date))
                    .font(.system(size: 10))
                    .foregroundStyle(prominent ? .primary : .tertiary)
                    .lineLimit(1)
            }
        }
    }

    private func sourceColor(_ sourceID: String) -> Color {
        let palette: [Color] = [.blue, .orange, .purple, .teal, .pink]
        return palette[(sources.firstIndex { $0.id == sourceID } ?? 0) % palette.count]
    }

    private func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func openLabel(_ source: AgentSource) -> String {
        switch source.id {
        case "claude-primary": return "Open Main"
        case "claude-second": return "Open Second"
        default: return source.name
        }
    }

    private func relativeDate(_ date: Date, now: Date) -> String {
        if abs(date.timeIntervalSince(now)) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
