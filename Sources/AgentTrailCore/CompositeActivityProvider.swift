import Foundation

/// Routes each profile to the adapter for its assistant and merges projects
/// that share a canonical folder. Codex and Grok scans do not read Claude's cache.
public final class CompositeActivityProvider: ActivityProvider {
    private let claude: ClaudeActivityProvider
    private let codex: CodexActivityProvider
    private let grok: GrokActivityProvider

    public init(cacheURL: URL? = nil) {
        claude = ClaudeActivityProvider(cacheURL: cacheURL)
        func adapterCache(_ assistant: AssistantKind) -> URL? {
            guard let cacheURL else { return nil }
            let stem = cacheURL.deletingPathExtension().lastPathComponent
            return cacheURL.deletingLastPathComponent()
                .appendingPathComponent("\(stem)-\(assistant.rawValue).json")
        }
        codex = CodexActivityProvider(cacheURL: adapterCache(.codex))
        grok = GrokActivityProvider(cacheURL: adapterCache(.grok))
    }

    public func metadata(sources: [AgentSource]) -> ScanResult {
        merge([
            claude.metadata(sources: sources.filter { $0.assistant == .claude }),
            codex.metadata(sources: sources.filter { $0.assistant == .codex }),
            grok.metadata(sources: sources.filter { $0.assistant == .grok })
        ])
    }

    public func scan(sources: [AgentSource]) -> ScanResult {
        scan(sources: sources, progress: nil)
    }

    public func scan(sources: [AgentSource], progress: ((ScanResult, Int, Int) -> Void)?) -> ScanResult {
        let claudeSources = sources.filter { $0.assistant == .claude }
        let codexSources = sources.filter { $0.assistant == .codex }
        let grokSources = sources.filter { $0.assistant == .grok }
        var pending: [AssistantKind: ScanResult] = [:]
        if progress != nil {
            pending[.claude] = claude.metadata(sources: claudeSources)
            pending[.codex] = codex.metadata(sources: codexSources)
            pending[.grok] = grok.metadata(sources: grokSources)
        }
        var completed: [ScanResult] = []
        func run(_ assistant: AssistantKind, _ matched: [AgentSource],
                 _ scan: ([AgentSource], ((ScanResult, Int, Int) -> Void)?) -> ScanResult) {
            guard !matched.isEmpty else { return }
            // Current/completed scans replace their metadata; only adapters that
            // have not started retain metadata in progressive results.
            pending.removeValue(forKey: assistant)
            let callback: ((ScanResult, Int, Int) -> Void)? = progress.map { outer in
                { partial, done, total in
                    let waiting = AssistantKind.allCases.compactMap { pending[$0] }
                    outer(self.merge(completed + [partial] + waiting), done, total)
                }
            }
            completed.append(scan(matched, callback))
        }
        run(.claude, claudeSources) { matched, callback in
            self.claude.scan(sources: matched, progress: callback)
        }
        run(.codex, codexSources) { matched, callback in
            self.codex.scan(sources: matched, progress: callback)
        }
        run(.grok, grokSources) { matched, callback in
            self.grok.scan(sources: matched, progress: callback)
        }
        return merge(completed)
    }

    private func merge(_ results: [ScanResult]) -> ScanResult {
        let activity = results.flatMap { $0.projects.flatMap(\.activities) }
        let notices = Array(Set(results.flatMap(\.notices))).sorted()
        return ScanResult(projects: ProjectSummary.merge(activity), notices: notices,
            scannedAt: results.map(\.scannedAt).max() ?? Date())
    }
}
