import AppKit
import SwiftUI
import AgentTrailCore

@MainActor
final class AppStore: ObservableObject {
    @Published var projects: [ProjectSummary] = []
    @Published var sources: [AgentSource] = []
    @Published var notices: [String] = []
    @Published var isScanning = false
    @Published var lastScan: Date?
    @Published var errorMessage: String?
    @Published var runningSourceIDs: Set<String> = []
    @Published var scanProgress: String?
    @Published var refreshInterval: Double = 15
    let demoMode: Bool
    let configurationURL = ProfileConfiguration.defaultURL
    var showProfiles: (() -> Void)?

    private let indexer = LocalIndexer()
    private var timer: Timer?
    private let cacheURL: URL
    private var generation = UUID()
    private var configurationIsValid = false

    init(demoMode: Bool = CommandLine.arguments.contains("--demo")) {
        self.demoMode = demoMode
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentTrail", isDirectory: true)
        cacheURL = support.appendingPathComponent("activity-cache.json")
        if demoMode {
            sources = DemoData.sources
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
        scheduleRefresh()
        refresh()
    }

    func refresh() {
        if demoMode {
            let result = DemoData.result()
            projects = result.projects
            lastScan = result.scannedAt
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

    func reveal(_ project: ProjectSummary) {
        guard !demoMode else { return }
        let url = URL(fileURLWithPath: project.path)
        guard FileManager.default.fileExists(atPath: project.path) else {
            errorMessage = "This project folder is no longer available: \(project.path)"
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copyPath(_ project: ProjectSummary) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(project.path, forType: .string)
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
