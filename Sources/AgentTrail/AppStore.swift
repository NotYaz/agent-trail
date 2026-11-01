import AppKit
import SwiftUI
import AgentTrailCore

enum PanelSection: String, CaseIterable {
    case projects = "Projects"
    case growth = "Growth"

    var symbol: String {
        switch self {
        case .projects: return "square.stack.3d.up"
        case .growth: return "chart.line.uptrend.xyaxis"
        }
    }
}

/// A Growth section another view can ask to scroll to. Growth consumes it once.
enum GrowthAnchor: Hashable {
    case chart, calendar, rhythm, profiles, projects
}

@MainActor
final class AppStore: ObservableObject {
    @Published var projects: [ProjectSummary] = [] {
        didSet {
            rebuildProjectOverviews()
            scheduleStatistics()
        }
    }
    @Published private(set) var projectOverviews: [ProjectOverview] = []
    @Published var sources: [AgentSource] = []
    @Published var notices: [String] = []
    @Published var isScanning = false
    @Published var lastScan: Date?
    @Published var errorMessage: String?
    @Published var runningSourceIDs: Set<String> = []
    @Published var scanProgress: String?
    @Published var refreshInterval: Double = 15
    @Published var panelSection: PanelSection = .projects
    @Published var liveSessions: [LiveAgentSession] = [] {
        didSet { rebuildProjectOverviews() }
    }
    @Published var liveNotices: [String] = []
    @Published var lastLiveScan: Date?
    /// Where each re-homed session was started, and the project it worked in.
    @Published private(set) var sessionProjects: [SessionProjectAssociation] = []
    /// Learned earlier locations of moved checkouts.
    @Published private(set) var projectLocations = ProjectLocationRegistry()
    @Published private(set) var missingFolders: [MissingFolder] = []
    @Published private(set) var unavailableProjects: Set<String> = []
    /// A project path whose new location is being linked.
    @Published private(set) var pendingLocationLink: String?
    @Published var infoMessage: String?
    /// Every statistic the UI shows. Rebuilt only when history evidence, the
    /// activity day or the time zone changes; live ticks never touch it.
    @Published private(set) var stats: StatsIndex = .empty
    /// Copied out of `stats` so project cards read a dictionary, not the index.
    @Published private(set) var trends: [String: ProjectTrend] = [:]
    @Published private(set) var pulse: PulseSummary = .empty
    /// Rebuilt with the overview, so it always describes the current live snapshot.
    @Published private(set) var liveSummary: LiveSummary = .empty
    /// Increments each time a new index is published, so views can key work on
    /// history changes instead of on every live tick.
    @Published private(set) var historyRevision = 0
    /// Growth selection lives here because Growth unmounts while it is hidden.
    @Published var growthProjectPath: String?
    @Published var growthPeriod: StatsPeriod = .month
    @Published var growthFocusSourceID: String?
    @Published var growthAnchor: GrowthAnchor?
    /// False while the popover is closed, so continuous effects can stop.
    @Published var isPanelVisible = true
    let demoMode: Bool
    /// A fixed clock for deterministic renders; nil follows the system clock.
    let pinnedNow: Date?
    var now: Date { pinnedNow ?? Date() }
    /// A snapshot of the system time zone, replaced when that changes.
    private(set) var activityCalendar = ActivityCalendar.current
    let configurationURL = ProfileConfiguration.defaultURL
    var showProfiles: (() -> Void)?
    /// Reopens the floating panel, which closes while a folder picker is up.
    var showPanel: (() -> Void)?

    private let indexer = LocalIndexer()
    private let liveReader = LiveReader()
    private var timer: Timer?
    private var liveTimer: Timer?
    private var isLiveScanning = false
    private let cacheURL: URL
    private let locationsURL: URL
    private var generation = UUID()
    private var configurationIsValid = false
    private let statisticsQueue = DispatchQueue(label: "app.agenttrail.stats", qos: .utility)
    /// Inputs of the newest build started, so unchanged history never rebuilds.
    private var statisticsFingerprint: Int?
    private var isBuildingStatistics = false
    private var statisticsPending = false
    private var statisticsPendingForce = false
    /// Not published: views fill it while rendering, which must not schedule another update.
    private var statisticsCache: [StatisticsKey: ActivityStatistics] = [:]
    private var timeZoneObserver: NSObjectProtocol?

    private func rebuildProjectOverviews() {
        let locations = projectLocations
        projectOverviews = ProjectOverview.merge(projects: projects, sessions: liveSessions,
            sessionProjects: sessionProjects,
            relocate: locations.locations.isEmpty ? nil : { locations.relocatedPath($0) })
        let summary = LiveSummary.make(projectOverviews)
        // The menu-bar tint subscribes to this; an unchanged snapshot stays quiet.
        if summary != liveSummary { liveSummary = summary }
    }

    /// Identity state must be in place before `projects` changes, because that
    /// assignment rebuilds the overview.
    private func applyIdentity(_ result: ScanResult) {
        sessionProjects = result.sessionProjects
        projectLocations = result.projectLocations
        missingFolders = result.missingFolders
        unavailableProjects = result.unavailableProjects
    }

    func location(for path: String) -> ProjectLocation? {
        projectLocations.location(forCurrentPath: path)
    }

    /// The largest group of edits under a vanished folder for this project.
    func missingFolder(for path: String) -> MissingFolder? {
        missingFolders.filter { $0.projectPath == path }.max { $0.editCount < $1.editCount }
    }

    init(demoMode: Bool = CommandLine.arguments.contains("--demo"), now: Date? = nil) {
        self.demoMode = demoMode
        pinnedNow = now
        AppSettings.registerDefaults()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentTrail", isDirectory: true)
        cacheURL = support.appendingPathComponent("activity-cache.json")
        locationsURL = support.appendingPathComponent("project-locations.json")
        observeTimeZone()
        if demoMode {
            sources = DemoData.sources
            scheduleRefresh()
            refresh()
        } else {
            reloadProfiles()
        }
    }

    private func scheduleRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        liveTimer?.invalidate()
        liveTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshLive() }
        }
    }

    func reloadProfiles() {
        guard !demoMode else { return }
        do {
            let configuration = try ProfileConfiguration.load(from: configurationURL)
            apply(configuration)
        } catch {
            generation = UUID()
            configurationIsValid = false
            sources = []
            applyIdentity(ScanResult(projects: []))
            projects = []
            isScanning = false
            scanProgress = nil
            notices = []
            lastScan = nil
            runningSourceIDs = []
            timer?.invalidate()
            liveTimer?.invalidate()
            resetLive()
            errorMessage = error.localizedDescription
        }
    }

    func saveProfiles(_ sources: [AgentSource], refreshInterval: Double) throws {
        guard !demoMode else { throw ProfileConfigurationError.invalid("Demo mode does not save profiles.") }
        let configuration = ProfileConfiguration(sources: sources, refreshInterval: refreshInterval)
        try configuration.save(to: configurationURL)
        apply(configuration)
    }

    private func apply(_ configuration: ProfileConfiguration) {
        generation = UUID()
        sources = configuration.sources
        refreshInterval = configuration.refreshInterval
        configurationIsValid = true
        applyIdentity(ScanResult(projects: []))
        projects = []
        notices = []
        errorMessage = nil
        isScanning = false
        scanProgress = nil
        lastScan = nil
        resetLive()
        scheduleRefresh()
        refreshLive()
        refresh()
    }

    func refresh() {
        if demoMode {
            let result = DemoData.result(now: now, calendar: .current)
            applyIdentity(result)
            projects = result.projects
            lastScan = result.scannedAt
            refreshLive()
            return
        }
        guard configurationIsValid else { return }
        guard !isScanning else { return }
        isScanning = true
        runningSourceIDs = Set(InstanceController.runningInstances(sources: sources).keys)
        let currentSources = sources
        let targetCache = cacheURL
        let currentGeneration = generation
        indexer.scan(sources: currentSources, cacheURL: targetCache, locationsURL: locationsURL, metadata: { [weak self] initial in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                // Keep already indexed edit evidence visible during refresh.
                if self.projects.isEmpty {
                    self.applyIdentity(initial)
                    self.projects = initial.projects
                }
                self.notices = initial.notices
                self.scanProgress = "Reading local change history…"
            }
        }, progress: { [weak self] partial, completed, total in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == currentGeneration else { return }
                    self.applyProgress(partial)
                    self.scanProgress = "Indexing \(completed) of \(total) session logs…"
                }
        }, completion: { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.applyIdentity(result)
                self.projects = result.projects
                self.notices = result.notices
                self.lastScan = result.scannedAt
                self.isScanning = false
                self.scanProgress = nil
            }
        })
    }

    func focus(_ source: AgentSource) {
        guard !demoMode else { return }
        errorMessage = InstanceController.focus(source: source)
        runningSourceIDs = Set(InstanceController.runningInstances(sources: sources).keys)
    }

    // MARK: Jump

    /// Title, else branch, else folder, honoring "Show session titles".
    /// Conversation-derived: show it, never log or store it.
    func sessionLabel(_ session: LiveAgentSession) -> String {
        SessionLabel.make(session, showTitles: AppSettings.showSessionTitles)
    }

    /// Compact time in the current state ("4m"), when the assistant records when it began.
    func sessionAge(_ session: LiveAgentSession, now: Date? = nil) -> String? {
        ElapsedFormat.compact(since: session.details.stateSince, now: now ?? self.now)
    }

    /// Opens the work behind one live session, in SessionLauncher's order.
    /// Called only from an explicit click or menu choice. It opens a link or
    /// activates an app only when that app is already running.
    func jump(_ session: LiveAgentSession) {
        let showTitles = AppSettings.showSessionTitles
        let source = sources.first { $0.id == session.sourceID }
        guard let source else {
            // Also reaches the status-item menu, where the panel toast is not visible.
            reportLaunchFailure("The profile for this session is no longer configured.")
            return
        }
        let context = JumpContext(profileName: source.name,
                                  title: SessionLabel.title(session, showTitles: showTitles, limit: 60),
                                  folder: SessionLabel.folder(session), verifiedAt: lastLiveScan)
        if demoMode {
            let label = SessionLabel.make(session, showTitles: showTitles, limit: 60)
            showDemoNotice("Sample data · \(SessionLabel.verb(session.status)) “\(label)” in \(source.name)")
            return
        }
        SessionLauncher.jump(session, source: source, context: context) { [weak self] outcome in
            self?.applyJump(outcome)
        }
    }

    /// Open in an editor or terminal, reveal, copy the path or open a PR.
    func perform(_ action: WorkspaceAction) {
        if demoMode {
            if case .copyPath(let path) = action {
                copyPath(path)
            } else {
                showDemoNotice("Not available with sample data")
            }
            return
        }
        SessionLauncher.perform(action) { [weak self] message in
            self?.reportLaunchFailure(message)
        }
    }

    private func applyJump(_ outcome: JumpOutcome) {
        runningSourceIDs = Set(InstanceController.runningInstances(sources: sources).keys)
        switch outcome {
        case .done:
            errorMessage = nil
        case .hint(let text, let symbol):
            errorMessage = nil
            HintHUD.show(text, symbol: symbol)
        case .failed(let message):
            reportLaunchFailure(message)
        }
    }

    /// Demo jumps switch to no app, so the panel stays open: a hint under the
    /// icon would sit on the popover's arrow, and the info toast says it instead.
    private func showDemoNotice(_ text: String) {
        if isPanelVisible {
            errorMessage = nil
            infoMessage = text
        } else {
            HintHUD.show(text, symbol: "sparkles")
        }
    }

    /// The panel toast when the panel is open; the menu-bar hint otherwise,
    /// for jumps started from the status item's menu.
    private func reportLaunchFailure(_ message: String) {
        infoMessage = nil
        errorMessage = message
        if !isPanelVisible { HintHUD.show(message, symbol: "exclamationmark.triangle", duration: 5) }
    }

    private func applyProgress(_ partial: ScanResult) {
        // Routine refreshes must keep the last complete history intact. Publishing
        // partial daily bins here made graphs briefly shrink and lose selection.
        guard lastScan == nil else { return }
        let incoming = partial.projects
        applyIdentity(partial)
        let previous = Dictionary(uniqueKeysWithValues: projects.map { ($0.path, $0) })
        projects = incoming.map { project in
            var updated = project
            guard let old = previous[project.path] else { return updated }
            for index in updated.activities.indices {
                guard let oldActivity = old.activities.first(where: { $0.sourceID == updated.activities[index].sourceID }),
                      let oldEdit = oldActivity.latestEdit,
                      oldEdit > (updated.activities[index].latestEdit ?? .distantPast) else { continue }
                updated.activities[index].latestEdit = oldEdit
                updated.activities[index].latestEditWorkspacePath = oldActivity.latestEditWorkspacePath
            }
            return updated
        }
    }

    private func resetLive() {
        isLiveScanning = false
        liveSessions = []
        liveNotices = []
        lastLiveScan = nil
    }

    func refreshLive() {
        // The 3 s tick doubles as the day-rollover clock; it never rebuilds otherwise.
        checkDayRollover()
        if demoMode {
            let now = self.now
            liveSessions = Self.demoLiveSessions(sources: sources, now: now)
            lastLiveScan = now
            return
        }
        guard configurationIsValid, !isLiveScanning else { return }
        isLiveScanning = true
        let currentGeneration = generation
        liveReader.scan(sources: sources) { [weak self] snapshot in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.liveSessions = snapshot.sessions
                self.liveNotices = snapshot.notices
                self.lastLiveScan = snapshot.scannedAt
                self.isLiveScanning = false
                self.runningSourceIDs = Set(InstanceController.runningInstances(sources: self.sources).keys)
            }
        }
    }

    /// Ask where a moved folder is now, check it against the recorded evidence,
    /// and remember the earlier path so its history follows it.
    func locateMovedFolder(projectPath: String, missing: MissingFolder?) {
        guard !demoMode, pendingLocationLink == nil else { return }
        let earlier = missing?.path ?? projectPath
        let name = URL(fileURLWithPath: earlier).lastPathComponent
        let panel = NSOpenPanel()
        panel.title = "Where is “\(name)” now?"
        panel.message = "Choose the folder that used to be at \(abbreviate(earlier)). It must contain the project's .git folder. Agent Trail only reads Git metadata and changes nothing."
        panel.prompt = "Link folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        var nearest = URL(fileURLWithPath: earlier)
        while !FileManager.default.fileExists(atPath: nearest.path), nearest.path != "/" {
            nearest.deleteLastPathComponent()
        }
        panel.directoryURL = nearest
        NSApp.activate()
        let response = panel.runModal()
        showPanel?()
        guard response == .OK, let chosen = panel.url?.path else { return }
        let previous: String
        if let missing {
            guard let root = missing.previousRoot(forChosenFolder: chosen) else {
                infoMessage = nil
                errorMessage = LocationError.noMatchingFiles.localizedDescription
                return
            }
            previous = root
        } else {
            // Offered only for a folder Agent Trail knew as a checkout.
            guard location(for: projectPath) != nil else { return }
            previous = projectPath
        }
        pendingLocationLink = projectPath
        errorMessage = nil
        infoMessage = nil
        indexer.registerLocation(path: chosen, previousPaths: [previous]) { [weak self] error in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pendingLocationLink = nil
                if let error {
                    self.infoMessage = nil
                    self.errorMessage = error.localizedDescription
                } else {
                    self.errorMessage = nil
                    self.infoMessage = "Linked \(self.abbreviate(chosen)) · its earlier location is remembered"
                    self.refresh()
                }
            }
        }
    }

    func forgetPreviousLocations(of path: String) {
        guard !demoMode else { return }
        indexer.forgetLocations(of: path) { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }
    }

    func abbreviate(_ path: String) -> String {
        PathFormat.abbreviate(path)
    }

    /// Sample live sessions with synthetic details: one waiting with a
    /// needs-action sentence, a Codex thread owned by the desktop app, and a
    /// Grok session in a terminal without a title. Nothing here is real.
    private static func demoLiveSessions(sources: [AgentSource], now: Date) -> [LiveAgentSession] {
        guard sources.count >= 4 else { return [] }
        let main = sources[0].id, second = sources[1].id, codex = sources[2].id, grok = sources[3].id
        let orbit = "/Demo/Projects/orbit", atlas = "/Demo/Projects/atlas"
        let minute: TimeInterval = 60
        var pulls: [LivePullRequest] = []
        if let url = URL(string: "https://git.example.com/orbit/pull/42") {
            pulls.append(LivePullRequest(number: 42, url: url))
        }
        let waiting = LiveSessionDetails(title: "Run the sync migration",
                                         desktopSessionID: "local_00000000-0000-4000-8000-000000004101",
                                         needsAction: "Approve running the migration",
                                         stateSince: now.addingTimeInterval(-4 * minute), branch: "sync-migration",
                                         pullRequests: pulls)
        let working = LiveSessionDetails(title: "Tighten sync retries",
                                         desktopSessionID: "local_00000000-0000-4000-8000-000000004102",
                                         stateSince: now.addingTimeInterval(-12 * minute), branch: "navigation")
        let idle = LiveSessionDetails(title: "Landing copy pass",
                                      desktopSessionID: "local_00000000-0000-4000-8000-000000004103",
                                      stateSince: now.addingTimeInterval(-25 * minute), branch: "main")
        let atlasIdle = LiveSessionDetails(title: "Design token cleanup",
                                           desktopSessionID: "local_00000000-0000-4000-8000-000000004104",
                                           stateSince: now.addingTimeInterval(-120 * minute), branch: "design")
        let codexWorking = LiveSessionDetails(title: "Refactor onboarding flow", branch: "onboarding",
                                              hostBundleID: SessionLauncher.codexBundleID)
        let grokIdle = LiveSessionDetails(hostBundleID: "com.mitchellh.ghostty")
        var sessions: [LiveAgentSession] = []
        sessions.append(LiveAgentSession(sourceID: main, projectPath: orbit, workspacePath: orbit,
                                         sessionID: "sample-needs-input", status: .waiting, updatedAt: now,
                                         pid: 4101, details: waiting))
        sessions.append(LiveAgentSession(sourceID: second, projectPath: orbit,
                                         workspacePath: orbit + "/.claude/worktrees/navigation",
                                         sessionID: "sample-second-working", status: .working,
                                         updatedAt: now.addingTimeInterval(-20), pid: 4102, details: working))
        sessions.append(LiveAgentSession(sourceID: main, projectPath: orbit, workspacePath: orbit,
                                         sessionID: "sample-main-idle", status: .idle,
                                         updatedAt: now.addingTimeInterval(-60), pid: 4103, details: idle))
        sessions.append(LiveAgentSession(sourceID: second, projectPath: atlas, workspacePath: atlas + "/.worktrees/design",
                                         sessionID: "sample-idle", status: .idle,
                                         updatedAt: now.addingTimeInterval(-120), pid: 4104, details: atlasIdle))
        sessions.append(LiveAgentSession(sourceID: codex, projectPath: orbit, workspacePath: orbit,
                                         sessionID: "sample-codex-working", status: .working,
                                         updatedAt: now.addingTimeInterval(-8), pid: 4105, details: codexWorking))
        sessions.append(LiveAgentSession(sourceID: grok, projectPath: orbit, workspacePath: orbit,
                                         sessionID: "sample-grok-idle", status: .idle,
                                         updatedAt: now.addingTimeInterval(-70), pid: 4106, details: grokIdle))
        return sessions
    }

    func reveal(path: String) {
        guard !demoMode else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            infoMessage = nil
            errorMessage = "This project folder is no longer available: \(path)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    // MARK: Statistics

    /// Memoized until the next index, so views can call it from `body`.
    func statistics(projectPath: String?, period: StatsPeriod) -> ActivityStatistics {
        let key = StatisticsKey(projectPath: projectPath ?? "", period: period)
        if let cached = statisticsCache[key] { return cached }
        let computed = stats.statistics(projectPath: projectPath, period: period)
        statisticsCache[key] = computed
        return computed
    }

    func portrait(projectPath: String?, period: StatsPeriod, showNames: Bool) -> PortraitSummary {
        stats.portrait(projectPath: projectPath, period: period, showNames: showNames)
    }

    /// Opens Growth on a scope. A nil period keeps the one already chosen.
    func showGrowth(projectPath: String?, period: StatsPeriod?, anchor: GrowthAnchor?) {
        growthProjectPath = projectPath
        if let period { growthPeriod = period }
        growthFocusSourceID = nil
        growthAnchor = anchor
        panelSection = .growth
    }

    /// Builds from overview histories, which already fold canonical aliases
    /// into one project, so no edit is counted twice. Overviews follow live
    /// attention, so inputs are sorted by path: a live reorder alone must not
    /// change the fingerprint or the index's project order.
    private func scheduleStatistics(force: Bool = false) {
        let inputs = projectOverviews.compactMap(\.history)
            .filter { !$0.activities.isEmpty }
            .sorted { $0.path < $1.path }
        let fingerprint = statisticsInputFingerprint(inputs)
        guard force || fingerprint != statisticsFingerprint else { return }
        if demoMode {
            // Demo and render output must be complete on the first frame.
            statisticsFingerprint = fingerprint
            applyStatistics(StatsIndex.build(projects: inputs, sources: sources, calendar: activityCalendar, now: now))
            return
        }
        guard !isBuildingStatistics else {
            // One build in flight, one pending: a scan's progress bursts collapse into a single rebuild.
            statisticsPending = true
            statisticsPendingForce = statisticsPendingForce || force
            return
        }
        statisticsFingerprint = fingerprint
        isBuildingStatistics = true
        let currentSources = sources
        let calendar = activityCalendar
        let date = now
        let currentGeneration = generation
        statisticsQueue.async { [weak self] in
            let index = StatsIndex.build(projects: inputs, sources: currentSources, calendar: calendar, now: date)
            DispatchQueue.main.async { [weak self] in
                self?.finishStatistics(index, generation: currentGeneration)
            }
        }
    }

    private func finishStatistics(_ index: StatsIndex, generation built: UUID) {
        isBuildingStatistics = false
        if generation == built {
            applyStatistics(index)
        } else {
            // A profile change replaced the inputs; never publish the old index.
            statisticsFingerprint = nil
            statisticsPending = true
        }
        guard statisticsPending else { return }
        let force = statisticsPendingForce
        statisticsPending = false
        statisticsPendingForce = false
        scheduleStatistics(force: force)
    }

    private func applyStatistics(_ index: StatsIndex) {
        stats = index
        trends = index.trends
        pulse = index.pulse
        statisticsCache = [:]
        historyRevision += 1
        if let path = growthProjectPath, !index.projectPaths.contains(path) {
            growthProjectPath = nil
        }
    }

    /// Counts and newest instants stand in for the full moment arrays, which
    /// are only ever appended to by a scan. Today is included so a rollover
    /// with unchanged history still differs.
    private func statisticsInputFingerprint(_ inputs: [ProjectSummary]) -> Int {
        var hasher = Hasher()
        hasher.combine(inputs.count)
        for project in inputs {
            hasher.combine(project.path)
            hasher.combine(project.activities.count)
            for activity in project.activities {
                hasher.combine(activity.sourceID)
                hasher.combine(activity.editMoments.count)
                hasher.combine(activity.sessionStarts.count)
                hasher.combine(activity.editMoments.last?.date)
                hasher.combine(activity.sessionStarts.last)
            }
        }
        hasher.combine(activityCalendar.timeZone.identifier)
        hasher.combine(activityCalendar.rolloverHour)
        hasher.combine(activityCalendar.day(of: now).index)
        hasher.combine(sources.map(\.id))
        return hasher.finalize()
    }

    /// A build already in flight is left alone; the next tick checks its result.
    private func checkDayRollover() {
        guard !stats.isEmpty, !isBuildingStatistics, activityCalendar.day(of: now) != stats.today else { return }
        scheduleStatistics(force: true)
    }

    /// Moments are raw instants, so a new time zone needs a rebuild, never a rescan.
    private func observeTimeZone() {
        timeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.timeZoneDidChange() }
        }
    }

    private func timeZoneDidChange() {
        // Swift's TimeZone has no reset; the NSTimeZone one also refreshes TimeZone.current.
        NSTimeZone.resetSystemTimeZone()
        activityCalendar = .current
        scheduleStatistics(force: true)
    }
}

/// One memoized statistics query. A nil project path is stored as "", which no project has.
private struct StatisticsKey: Hashable {
    let projectPath: String
    let period: StatsPeriod
}

/// Live metadata has its own queue so a first history index cannot delay it.
private final class LiveReader: @unchecked Sendable {
    private let worker = DispatchQueue(label: "app.agenttrail.live", qos: .utility)
    private let provider = CompositeLiveActivityProvider()

    func scan(sources: [AgentSource], completion: @escaping (LiveSnapshot) -> Void) {
        worker.async { completion(self.provider.scan(sources: sources)) }
    }
}

/// Owns the index on one background queue. UI state stays on the main actor.
private final class LocalIndexer: @unchecked Sendable {
    private let worker = DispatchQueue(label: "app.agenttrail.index", qos: .utility)
    private var provider: CompositeActivityProvider?

    func scan(sources: [AgentSource], cacheURL: URL, locationsURL: URL,
              metadata: @escaping (ScanResult) -> Void,
              progress: @escaping (ScanResult, Int, Int) -> Void,
              completion: @escaping (ScanResult) -> Void) {
        worker.async {
            let provider = self.provider(cacheURL: cacheURL, locationsURL: locationsURL)
            metadata(provider.metadata(sources: sources))
            completion(provider.scan(sources: sources, progress: progress))
        }
    }

    /// Runs after any scan already queued, on the same queue as the catalog.
    func registerLocation(path: String, previousPaths: [String], completion: @escaping (Error?) -> Void) {
        worker.async {
            guard let provider = self.provider else { return completion(LocationError.invalidCatalog) }
            do {
                try provider.registerProjectLocation(path: path, previousPaths: previousPaths)
                completion(nil)
            } catch { completion(error) }
        }
    }

    func forgetLocations(of path: String, completion: @escaping () -> Void) {
        worker.async {
            self.provider?.forgetPreviousLocations(of: path)
            completion()
        }
    }

    private func provider(cacheURL: URL, locationsURL: URL) -> CompositeActivityProvider {
        if let provider { return provider }
        let created = CompositeActivityProvider(cacheURL: cacheURL, locationsURL: locationsURL)
        provider = created
        return created
    }
}
