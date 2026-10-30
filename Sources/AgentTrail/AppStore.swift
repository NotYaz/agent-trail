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
    let demoMode: Bool
    let configurationURL = ProfileConfiguration.defaultURL
    var showProfiles: (() -> Void)?
    var showActivity: (() -> Void)?

    private let indexer = LocalIndexer()
    private let liveReader = LiveReader()
    private var timer: Timer?
    private var liveTimer: Timer?
    private var isLiveScanning = false
    private let cacheURL: URL
    private var generation = UUID()
    private var configurationIsValid = false

    private func rebuildProjectOverviews() {
        projectOverviews = ProjectOverview.merge(projects: projects, sessions: liveSessions)
    }

    init(demoMode: Bool = CommandLine.arguments.contains("--demo")) {
        self.demoMode = demoMode
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentTrail", isDirectory: true)
        cacheURL = support.appendingPathComponent("activity-cache.json")
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
        indexer.scan(sources: currentSources, cacheURL: targetCache, metadata: { [weak self] initial in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                // Keep already indexed edit evidence visible during refresh.
                if self.projects.isEmpty { self.projects = initial.projects }
                self.notices = initial.notices
                self.scanProgress = "Reading local change history…"
            }
        }, progress: { [weak self] partial, completed, total in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == currentGeneration else { return }
                    self.applyProgress(partial.projects)
                    self.scanProgress = "Indexing \(completed) of \(total) session logs…"
                }
        }, completion: { [weak self] result in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
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

    private func applyProgress(_ incoming: [ProjectSummary]) {
        // Routine refreshes must keep the last complete history intact. Publishing
        // partial daily bins here made graphs briefly shrink and lose selection.
        guard lastScan == nil else { return }
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
                                 sessionID: "sample-working", status: .working, updatedAt: now, pid: 4101),
                LiveAgentSession(sourceID: sources[1].id, projectPath: "/Demo/Projects/orbit", workspacePath: "/Demo/Projects/orbit/.claude/worktrees/navigation",
                                 sessionID: "sample-second-working", status: .working, updatedAt: now.addingTimeInterval(-20), pid: 4102),
                LiveAgentSession(sourceID: sources[0].id, projectPath: "/Demo/Projects/orbit", workspacePath: "/Demo/Projects/orbit",
                                 sessionID: "sample-main-idle", status: .idle, updatedAt: now.addingTimeInterval(-60), pid: 4103),
                LiveAgentSession(sourceID: sources[1].id, projectPath: "/Demo/Projects/atlas", workspacePath: "/Demo/Projects/atlas/.worktrees/design",
                                 sessionID: "sample-idle", status: .idle, updatedAt: now.addingTimeInterval(-120), pid: 4104)
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

    func reveal(path: String) {
        guard !demoMode else { return }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
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
    private let provider = LiveActivityProvider()

    func scan(sources: [AgentSource], completion: @escaping (LiveSnapshot) -> Void) {
        worker.async { completion(self.provider.scan(sources: sources)) }
    }
}

/// Owns the index on one background queue. UI state stays on the main actor.
private final class LocalIndexer: @unchecked Sendable {
    private let worker = DispatchQueue(label: "app.agenttrail.index", qos: .utility)
    private var provider: ClaudeActivityProvider?

    func scan(sources: [AgentSource], cacheURL: URL,
              metadata: @escaping (ScanResult) -> Void,
              progress: @escaping (ScanResult, Int, Int) -> Void,
              completion: @escaping (ScanResult) -> Void) {
        worker.async {
            let provider: ClaudeActivityProvider
            if let existing = self.provider {
                provider = existing
            } else {
                provider = ClaudeActivityProvider(cacheURL: cacheURL)
                self.provider = provider
            }
            metadata(provider.metadata(sources: sources))
            completion(provider.scan(sources: sources, progress: progress))
        }
    }
}
