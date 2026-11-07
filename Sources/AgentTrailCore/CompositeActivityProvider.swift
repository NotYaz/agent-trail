import Foundation

/// Routes each profile to the adapter for its assistant (`AssistantRegistry`)
/// and merges projects that share a canonical folder. Each adapter keeps its own cache.
///
/// It also owns the project location catalog. Each scan first follows folders
/// that moved, then folds every adapter against one filesystem view, then
/// remembers the checkouts work was attributed to and any symbolic link seen
/// pointing at a checkout root, so grouping survives the link's removal.
/// Use one instance from one serial queue.
public final class CompositeActivityProvider: ActivityProvider {
    /// One adapter per assistant, in `AssistantKind.allCases` order.
    private let adapters: [(kind: AssistantKind, adapter: any HistoryAdapter)]
    private let resolver: GitProjectResolver
    private let locationsURL: URL?
    private var registry: ProjectLocationRegistry
    private var registryWritable: Bool
    private var registryNotice: String?
    private var savedRegistry: Data?

    /// `locationsURL` persists learned locations there; nil keeps them in
    /// memory only. A catalog that cannot be read is never overwritten.
    public init(cacheURL: URL? = nil, locationsURL: URL? = nil, projectLocations: ProjectLocationRegistry? = nil) {
        self.locationsURL = locationsURL
        var registry = projectLocations ?? .init()
        var writable = locationsURL != nil
        if projectLocations == nil, let locationsURL {
            do {
                registry = try ProjectLocationRegistry.load(from: locationsURL)
            } catch {
                writable = false
                registryNotice = "Project locations could not be read, so moved folders are not grouped. Fix or remove \(locationsURL.lastPathComponent) in Agent Trail's support folder."
            }
        }
        self.registry = registry
        registryWritable = writable
        savedRegistry = try? registry.encoded()
        let resolver = GitProjectResolver(locations: registry)
        self.resolver = resolver
        adapters = AssistantKind.allCases.map { kind in
            (kind, AssistantRegistry.history(kind, cacheURL: AssistantRegistry.cacheURL(kind, base: cacheURL),
                                             resolver: resolver))
        }
    }

    public var projectLocations: ProjectLocationRegistry { registry }

    public func setProjectLocations(_ locations: ProjectLocationRegistry) {
        registry = locations
        resolver.reset(locations: locations)
    }

    /// Link earlier paths to a folder the user chose, then save.
    public func registerProjectLocation(path: String, previousPaths: [String]) throws {
        guard registryWritable || locationsURL == nil else { throw LocationError.invalidCatalog }
        var next = registry
        try next.register(path: path, previousPaths: previousPaths)
        registry = next
        resolver.reset(locations: registry)
        if let notice = persist() { throw ProjectLocationSaveError(message: notice) }
    }

    /// Stop grouping a project's earlier paths with it, then save.
    @discardableResult
    public func forgetPreviousLocations(of path: String) -> Bool {
        guard registry.forgetPreviousLocations(of: path) else { return false }
        resolver.reset(locations: registry)
        _ = persist()
        return true
    }

    public func metadata(sources: [AgentSource]) -> ScanResult {
        resolver.reset(locations: registry)
        return finish(merge(adapters.map { kind, adapter in
            adapter.metadata(sources: sources.filter { $0.assistant == kind })
        }), learn: false)
    }

    public func scan(sources: [AgentSource]) -> ScanResult {
        scan(sources: sources, progress: nil)
    }

    public func scan(sources: [AgentSource], progress: ((ScanResult, Int, Int) -> Void)?) -> ScanResult {
        registry.refresh()
        resolver.reset(locations: registry)
        let matching = Dictionary(uniqueKeysWithValues: adapters.map { kind, _ in
            (kind, sources.filter { $0.assistant == kind })
        })
        var pending: [AssistantKind: ScanResult] = [:]
        if progress != nil {
            for (kind, adapter) in adapters { pending[kind] = adapter.metadata(sources: matching[kind] ?? []) }
        }
        var completed: [ScanResult] = []
        for (assistant, adapter) in adapters {
            let matched = matching[assistant] ?? []
            guard !matched.isEmpty else { continue }
            // Current/completed scans replace their metadata; only adapters that
            // have not started retain metadata in progressive results.
            pending.removeValue(forKey: assistant)
            let callback: ((ScanResult, Int, Int) -> Void)? = progress.map { outer in
                { partial, done, total in
                    let waiting = AssistantKind.allCases.compactMap { pending[$0] }
                    outer(self.finish(self.merge(completed + [partial] + waiting), learn: false), done, total)
                }
            }
            completed.append(adapter.scan(sources: matched, progress: callback))
        }
        return finish(merge(completed), learn: true)
    }

    /// Saves every adapter cache a scan changed but has not written yet.
    /// Scans write them at most every few minutes; call this before quitting.
    public func flushCaches() {
        for (_, adapter) in adapters { adapter.saveCache() }
    }

    private func merge(_ results: [ScanResult]) -> ScanResult {
        let activity = results.flatMap { $0.projects.flatMap(\.activities) }
        let notices = Array(Set(results.flatMap(\.notices))).sorted()
        return ScanResult(projects: ProjectSummary.merge(activity), notices: notices,
            scannedAt: results.map(\.scannedAt).max() ?? Date(),
            sessionProjects: Array(Set(results.flatMap(\.sessionProjects)))
                .sorted { ($0.sourceID, $0.sessionID) < ($1.sourceID, $1.sessionID) },
            missingFolders: results.flatMap(\.missingFolders),
            sessionTrails: SessionTrail.merge(results.flatMap(\.sessionTrails)))
    }

    /// Attach catalog state. After a complete scan, also remember checkouts and
    /// links that this scan's evidence identified, then save if anything changed.
    private func finish(_ result: ScanResult, learn: Bool) -> ScanResult {
        var result = result
        var notices = result.notices
        if learn {
            let now = Date()
            for path in result.projects.map(\.path) where resolver.isCheckoutRoot(path) {
                registry.observe(checkout: path, now: now)
            }
            for alias in resolver.linkAliases() {
                registry.observe(link: alias.link, checkout: alias.checkout, now: now)
            }
            registry.refreshDerivedState()
            if let notice = persist() { notices.append(notice) }
        }
        if let registryNotice { notices.append(registryNotice) }
        result.notices = Array(Set(notices)).sorted()
        result.projectLocations = registry
        result.unavailableProjects = Set(result.projects.map(\.path).filter { !resolver.exists($0) })
        return result
    }

    /// Returns a notice when the catalog could not be saved.
    private func persist() -> String? {
        guard registryWritable, let locationsURL, let data = try? registry.encoded(), data != savedRegistry else { return nil }
        do {
            try registry.save(to: locationsURL)
            savedRegistry = data
            return nil
        } catch {
            return "Project locations could not be saved; moved folders may need to be located again after relaunch."
        }
    }
}

public struct ProjectLocationSaveError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}
