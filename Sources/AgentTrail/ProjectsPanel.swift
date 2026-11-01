import SwiftUI
import AgentTrailCore

/// How the project list is ordered. Under every order, projects with a session
/// that needs input stay first, in attention order.
enum ProjectSort: String, CaseIterable {
    /// The overview order: needs input, then working, then most recent activity.
    case attention
    case edits30
    /// Edits in the last 7 days minus the 7 days before.
    case trending
    case name

    var title: String {
        switch self {
        case .attention: return "Attention"
        case .edits30: return "Most edits · 30D"
        case .trending: return "Trending"
        case .name: return "Name"
        }
    }

    /// Stable: ties keep the incoming (attention) order.
    static func order(_ projects: [ProjectOverview], by sort: ProjectSort,
                      trends: [String: ProjectTrend]) -> [ProjectOverview] {
        guard sort != .attention, projects.count > 1 else { return projects }
        let ranked: [(offset: Int, element: ProjectOverview)] = Array(projects.enumerated())
        let sorted: [(offset: Int, element: ProjectOverview)] = ranked.sorted {
            precedes($0.element, at: $0.offset, $1.element, at: $1.offset, sort: sort, trends: trends)
        }
        return sorted.map { $0.element }
    }

    private static func precedes(_ lhs: ProjectOverview, at lhsIndex: Int, _ rhs: ProjectOverview, at rhsIndex: Int,
                                 sort: ProjectSort, trends: [String: ProjectTrend]) -> Bool {
        let lhsWaiting = (lhs.live?.waitingCount ?? 0) > 0
        let rhsWaiting = (rhs.live?.waitingCount ?? 0) > 0
        if lhsWaiting != rhsWaiting { return lhsWaiting }
        if lhsWaiting { return lhsIndex < rhsIndex }
        let lhsTrend = trends[lhs.path]
        let rhsTrend = trends[rhs.path]
        switch sort {
        case .attention:
            break
        case .edits30:
            let left = lhsTrend?.edits30 ?? 0
            let right = rhsTrend?.edits30 ?? 0
            if left != right { return left > right }
        case .trending:
            let left = change(lhsTrend)
            let right = change(rhsTrend)
            if left != right { return left > right }
            let leftWeek = lhsTrend?.edits7 ?? 0
            let rightWeek = rhsTrend?.edits7 ?? 0
            if leftWeek != rightWeek { return leftWeek > rightWeek }
        case .name:
            let result = displayName(lhs).localizedStandardCompare(displayName(rhs))
            if result != .orderedSame { return result == .orderedAscending }
        }
        return lhsIndex < rhsIndex
    }

    private static func change(_ trend: ProjectTrend?) -> Int {
        guard let trend else { return 0 }
        return trend.edits7 - trend.previous7
    }

    private static func displayName(_ project: ProjectOverview) -> String {
        project.name.isEmpty ? project.path : project.name
    }
}

/// The Projects tab: the Pulse strip, a toolbar that pins under the nav bar,
/// then one card per project and the profile notices.
struct AgentTrailPanel: View {
    private static let scrollSpace = "projectsScroll"

    @ObservedObject private var store: AppStore
    private let isActive: Bool
    @Binding private var focusSearch: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill
    @AppStorage("projectSort") private var storedSort: ProjectSort = .attention
    @State private var search = ""
    @State private var sharedOnly = false
    @State private var workingOnly = false
    @State private var waitingOnly = false
    @State private var showNotices = false
    @State private var toolbarPinned = false
    @FocusState private var searchFocused: Bool

    /// `focusSearch` is a token: each change focuses the search field (⌘F).
    init(store: AppStore, isActive: Bool, focusSearch: Binding<Int>) {
        _store = ObservedObject(wrappedValue: store)
        self.isActive = isActive
        _focusSearch = focusSearch
    }

    var body: some View {
        let projects = visibleProjects()
        let notices = combinedNotices
        ScrollView {
            LazyVStack(spacing: Theme.Space.cardGap, pinnedViews: [.sectionHeaders]) {
                pulseStrip
                Section {
                    rows(projects, notices: notices)
                } header: {
                    toolbar
                }
            }
            .padding(.bottom, Theme.Space.m)
            .animation(listAnimation, value: projects.map(\.id))
        }
        .coordinateSpace(NamedCoordinateSpace.named(AgentTrailPanel.scrollSpace))
        .scrollIndicators(.automatic)
        .onChange(of: focusSearch) { _, _ in focusSearchField() }
    }

    // MARK: Pulse

    private var pulseStrip: some View {
        PulseStrip(pulse: store.pulse, live: store.liveSummary, lastLiveScan: store.lastLiveScan,
                   isFirstIndex: store.lastScan == nil && store.isScanning,
                   onLive: { applyLiveFilter() },
                   onOpenGrowth: { (period: StatsPeriod?, anchor: GrowthAnchor) in
                       store.showGrowth(projectPath: nil, period: period, anchor: anchor)
                   })
            .padding(.horizontal, Theme.Space.gutter)
            .padding(.top, Theme.Space.s)
    }

    /// Needs input wins, because it is the state that waits on the user.
    private func applyLiveFilter() {
        if store.liveSummary.waiting > 0 {
            waitingOnly = true
        } else {
            workingOnly = true
        }
    }

    // MARK: Rows

    @ViewBuilder private func rows(_ projects: [ProjectOverview], notices: [String]) -> some View {
        if showsIndexingCaption { indexingCaption }
        if store.projectOverviews.isEmpty && store.isScanning {
            loadingState
        } else if projects.isEmpty {
            emptyState
        } else {
            ForEach(projects) { (project: ProjectOverview) in
                card(project)
            }
        }
        if !notices.isEmpty { noticesRow(notices) }
    }

    private func card(_ project: ProjectOverview) -> some View {
        ProjectCard(project: project, trend: store.trends[project.path], sources: store.sources,
                    runningSourceIDs: store.runningSourceIDs, isScanning: store.isScanning,
                    lastLiveScan: store.lastLiveScan, isActive: isActive && store.isPanelVisible,
                    demoMode: store.demoMode, location: store.location(for: project.path),
                    missingFolder: store.missingFolder(for: project.path),
                    isUnavailable: store.unavailableProjects.contains(project.path),
                    isLinking: store.pendingLocationLink == project.path,
                    open: { (source: AgentSource) in store.focus(source) },
                    reveal: { store.reveal(path: project.path) },
                    copyPath: { (path: String) in store.copyPath(path) },
                    locate: { (missing: MissingFolder?) in store.locateMovedFolder(projectPath: project.path, missing: missing) },
                    forget: { store.forgetPreviousLocations(of: project.path) },
                    showInGrowth: { store.showGrowth(projectPath: project.path, period: nil, anchor: .chart) })
            .padding(.horizontal, Theme.Space.gutter)
    }

    private var showsIndexingCaption: Bool { store.scanProgress != nil && store.lastScan == nil }

    private var indexingCaption: some View {
        Text(store.scanProgress ?? "")
            .font(Theme.Typeface.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.Space.gutter)
            .help(store.scanProgress ?? "")
    }

    private var listAnimation: Animation? {
        Theme.Motion.animation(.smooth(duration: 0.3), reduceMotion: reduceMotion, still: rendersStill)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: Theme.Space.xs) {
            searchField
            filterChips
            sortMenu
        }
        .padding(.horizontal, Theme.Space.gutter)
        .frame(height: 40)
        .background { toolbarBackdrop }
        .background { pinTracker }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Find and filter projects")
    }

    /// At rest the toolbar sits on the panel; once pinned, cards scroll under a
    /// material bar with a hairline.
    private var toolbarBackdrop: some View {
        Color.clear
            .chromeSurface()
            .overlay(alignment: .bottom) { Theme.Palette.hairline.frame(height: 1) }
            .opacity(toolbarPinned ? 1 : 0)
            .animation(Theme.Motion.animation(Theme.Motion.quick, reduceMotion: reduceMotion, still: rendersStill),
                       value: toolbarPinned)
            .allowsHitTesting(false)
    }

    private var pinTracker: some View {
        GeometryReader { proxy in
            let pinned = proxy.frame(in: NamedCoordinateSpace.named(AgentTrailPanel.scrollSpace)).minY <= 0.5
            Color.clear
                .onChange(of: pinned, initial: true) { _, isPinned in
                    if toolbarPinned != isPinned { toolbarPinned = isPinned }
                }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Find a project or profile", text: $search)
                .textFieldStyle(.plain)
                .font(Theme.Typeface.body)
                .focused($searchFocused)
                .accessibilityLabel("Find a project or profile")
            if !search.isEmpty { clearSearchButton }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .frame(maxWidth: .infinity)
        .sunkenField()
        .overlay { searchFocusRing }
    }

    private var clearSearchButton: some View {
        Button { search = "" } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear search")
        .accessibilityLabel("Clear search")
    }

    private var searchFocusRing: some View {
        Theme.Radius.shape(Theme.Radius.control)
            .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1)
            .opacity(searchFocused ? 1 : 0)
            .allowsHitTesting(false)
    }

    /// Counts are projects, not sessions. Both live filters together match either state.
    private var filterChips: some View {
        HStack(spacing: 6) {
            FilterChip(title: "Needs input", count: store.liveSummary.waitingProjects, symbol: "hand.raised.fill",
                       tint: Theme.Palette.needsInput, isOn: $waitingOnly,
                       help: "Show projects with a reported request for user attention. Select both live filters to include either state.")
            FilterChip(title: "Working", count: store.liveSummary.workingProjects, symbol: "circle.fill",
                       tint: Theme.Palette.working, isOn: $workingOnly,
                       help: "Show projects with at least one reported working session")
            FilterChip(title: "Shared", count: sharedCount, symbol: "person.2", isOn: $sharedOnly,
                       help: "Show projects worked on by more than one assistant profile")
        }
        .fixedSize()
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort projects", selection: $storedSort) {
                ForEach(ProjectSort.allCases, id: \.self) { (option: ProjectSort) in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28, height: 24)
        .background(sortBackdrop, in: Capsule())
        .help("Sort projects · \(effectiveSort.title). Projects that need input always stay first.")
        .accessibilityLabel("Sort projects")
        .accessibilityValue(effectiveSort.title)
    }

    /// A non-default order is marked so a reordered list never looks random.
    private var sortBackdrop: Color {
        effectiveSort == .attention ? Theme.Palette.sunken : Color.primary.opacity(0.12)
    }

    /// Renders always use the attention order, whatever this Mac has stored.
    private var effectiveSort: ProjectSort { rendersStill ? .attention : storedSort }

    private func focusSearchField() {
        Task { @MainActor in searchFocused = true }
    }

    // MARK: States

    private var loadingState: some View {
        ContentUnavailableView {
            VStack(spacing: 10) {
                ProgressView().controlSize(.regular)
                Text("Finding your projects…")
            }
        } description: {
            Text("Reading the activity saved by your assistant profiles.")
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(emptyTitle, systemImage: search.isEmpty ? "questionmark.folder" : "magnifyingglass")
        } description: {
            Text(emptyDescription)
        } actions: {
            if hasActiveFilters {
                Button("Show all projects") { clearFilters() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }

    private var emptyTitle: String {
        if !search.isEmpty { return "No matching projects" }
        if waitingOnly && workingOnly { return "No matching live projects reported" }
        if waitingOnly { return "No input requests reported" }
        if workingOnly { return "No working projects reported" }
        return sharedOnly ? "No shared projects yet" : "No projects found yet"
    }

    private var emptyDescription: String {
        if !search.isEmpty { return "Try a different folder name, an earlier location, or an assistant profile." }
        if waitingOnly || workingOnly {
            return "Projects appear here when an assistant reports a matching live state. Idle sessions do not establish an outstanding request for input."
        }
        if sharedOnly { return "A project appears here when more than one profile works in the same folder." }
        return "Projects appear when Claude, Codex, or Grok saves a local coding session. Check the profile notices below for details."
    }

    private var hasActiveFilters: Bool { sharedOnly || workingOnly || waitingOnly || !search.isEmpty }

    private func clearFilters() {
        search = ""
        sharedOnly = false
        workingOnly = false
        waitingOnly = false
    }

    // MARK: Notices

    private func noticesRow(_ notices: [String]) -> some View {
        DisclosureGroup(isExpanded: $showNotices) {
            noticesList(notices)
        } label: {
            Label(notices.count == 1 ? "1 profile notice" : "\(notices.count) profile notices", systemImage: "info.circle")
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Space.cardPadding)
        .padding(.vertical, 10)
        .cardSurface()
        .padding(.horizontal, Theme.Space.gutter)
        .padding(.top, Theme.Space.xxs)
    }

    /// A few notices show in full; more scroll inside a 120pt well.
    @ViewBuilder private func noticesList(_ notices: [String]) -> some View {
        if notices.count > 3 {
            ScrollView { noticesText(notices) }
                .frame(height: 120)
        } else {
            noticesText(notices)
        }
    }

    private func noticesText(_ notices: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(notices, id: \.self) { (notice: String) in
                Text(notice)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.top, 6)
    }

    // MARK: Filtering

    private var combinedNotices: [String] { Array(Set(store.notices + store.liveNotices)).sorted() }

    private var sharedCount: Int {
        store.projectOverviews.reduce(0) { (count: Int, project: ProjectOverview) -> Int in
            count + (project.isShared ? 1 : 0)
        }
    }

    /// Called once per body.
    private func visibleProjects() -> [ProjectOverview] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = store.projectOverviews.filter { (project: ProjectOverview) -> Bool in
            passesFilters(project) && (query.isEmpty || matches(project, query: query))
        }
        return ProjectSort.order(filtered, by: effectiveSort, trends: store.trends)
    }

    /// Shared narrows; the two live filters together match either state.
    private func passesFilters(_ project: ProjectOverview) -> Bool {
        if sharedOnly && !project.isShared { return false }
        guard workingOnly || waitingOnly else { return true }
        let working = workingOnly && (project.live?.workingCount ?? 0) > 0
        let waiting = waitingOnly && (project.live?.waitingCount ?? 0) > 0
        return working || waiting
    }

    /// Folder path, profile names, live workspaces, earlier locations and
    /// recorded workspaces, as before the redesign.
    private func matches(_ project: ProjectOverview, query: String) -> Bool {
        if project.path.localizedCaseInsensitiveContains(query) { return true }
        if project.sourceIDs.contains(where: { sourceName($0).localizedCaseInsensitiveContains(query) }) { return true }
        if let live = project.live,
           live.sessions.contains(where: { $0.workspacePath.localizedCaseInsensitiveContains(query) }) { return true }
        if let location = store.location(for: project.path),
           location.previousPaths.contains(where: { $0.localizedCaseInsensitiveContains(query) }) { return true }
        guard let history = project.history else { return false }
        return history.activities.contains { (activity: ProjectActivity) -> Bool in
            (activity.workspacePath ?? "").localizedCaseInsensitiveContains(query)
                || (activity.latestEditWorkspacePath ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    private func sourceName(_ id: String) -> String {
        store.sources.first { $0.id == id }?.name ?? id
    }
}
