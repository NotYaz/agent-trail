import AppKit
import SwiftUI
import AgentTrailCore

enum PanelSection: String, CaseIterable {
    case projects = "Projects"
    case growth = "Growth"

    var symbol: String {
        switch self {
        case .projects: return "square.stack.3d.up"
        case .growth: return "point.3.connected.trianglepath.dotted"
        }
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var projects: [ProjectSummary] = [] {
        didSet { rebuildProjectOverviews() }
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
    let demoMode: Bool
    let configurationURL = ProfileConfiguration.defaultURL
    var showProfiles: (() -> Void)?
    var showActivity: (() -> Void)?
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

    private func rebuildProjectOverviews() {
        let locations = projectLocations
        projectOverviews = ProjectOverview.merge(projects: projects, sessions: liveSessions,
            sessionProjects: sessionProjects,
            relocate: locations.locations.isEmpty ? nil : { locations.relocatedPath($0) })
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

    init(demoMode: Bool = CommandLine.arguments.contains("--demo")) {
        self.demoMode = demoMode
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentTrail", isDirectory: true)
        cacheURL = support.appendingPathComponent("activity-cache.json")
        locationsURL = support.appendingPathComponent("project-locations.json")
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
            let result = DemoData.result()
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
        if demoMode {
            let now = Date()
            liveSessions = [
                LiveAgentSession(sourceID: sources[0].id, projectPath: "/Demo/Projects/orbit", workspacePath: "/Demo/Projects/orbit",
                                 sessionID: "sample-needs-input", status: .waiting, updatedAt: now, pid: 4101),
                LiveAgentSession(sourceID: sources[1].id, projectPath: "/Demo/Projects/orbit", workspacePath: "/Demo/Projects/orbit/.claude/worktrees/navigation",
                                 sessionID: "sample-second-working", status: .working, updatedAt: now.addingTimeInterval(-20), pid: 4102),
                LiveAgentSession(sourceID: sources[0].id, projectPath: "/Demo/Projects/orbit", workspacePath: "/Demo/Projects/orbit",
                                 sessionID: "sample-main-idle", status: .idle, updatedAt: now.addingTimeInterval(-60), pid: 4103),
                LiveAgentSession(sourceID: sources[1].id, projectPath: "/Demo/Projects/atlas", workspacePath: "/Demo/Projects/atlas/.worktrees/design",
                                 sessionID: "sample-idle", status: .idle, updatedAt: now.addingTimeInterval(-120), pid: 4104),
                LiveAgentSession(sourceID: sources[2].id, projectPath: "/Demo/Projects/orbit", workspacePath: "/Demo/Projects/orbit",
                                 sessionID: "sample-codex-working", status: .working, updatedAt: now.addingTimeInterval(-8), pid: 4105),
                LiveAgentSession(sourceID: sources[3].id, projectPath: "/Demo/Projects/orbit", workspacePath: "/Demo/Projects/orbit",
                                 sessionID: "sample-grok-idle", status: .idle, updatedAt: now.addingTimeInterval(-70), pid: 4106)
            ]
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
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
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
