import Foundation

/// Keeps assistant-specific runtime evidence independent. Reuse on a serial
/// background queue so lifecycle readers can retain bounded in-memory cursors.
public final class CompositeLiveActivityProvider {
    private let readers: [AssistantKind: ([AgentSource], Date) -> LiveSnapshot]

    public init() {
        let claude = LiveActivityProvider()
        let codex = CodexLiveActivityProvider()
        let grok = GrokLiveActivityProvider()
        readers = [
            .claude: { claude.scan(sources: $0, now: $1) },
            .codex: { codex.scan(sources: $0, now: $1) },
            .grok: { grok.scan(sources: $0, now: $1) }
        ]
    }

    init(readers: [AssistantKind: ([AgentSource], Date) -> LiveSnapshot]) {
        self.readers = readers
    }

    public func scan(sources: [AgentSource], now: Date = Date()) -> LiveSnapshot {
        var sessions: [LiveAgentSession] = []
        var notices: [String] = []
        for assistant in AssistantKind.allCases {
            let matching = sources.filter { $0.assistant == assistant }
            guard !matching.isEmpty, let reader = readers[assistant] else { continue }
            let snapshot = reader(matching, now)
            sessions += snapshot.sessions
            notices += snapshot.notices
        }
        sessions.sort {
            let left = Self.rank($0.status), right = Self.rank($1.status)
            if left != right { return left < right }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id < $1.id
        }
        return LiveSnapshot(sessions: sessions, notices: Array(Set(notices)).sorted(), scannedAt: now)
    }

    private static func rank(_ status: LiveStatus) -> Int {
        switch status {
        case .waiting: return 0
        case .working: return 1
        case .idle: return 2
        case .unknown: return 3
        }
    }
}
