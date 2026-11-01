import Foundation

/// Orders sessions for the Jump button: waiting first (longest wait first, by
/// stateSince, falling back to updatedAt), then working (newest updatedAt first),
/// then idle (newest first), then unknown (newest first). Ties: sessionID.
public enum LiveSessionRanking {
    public static func ordered(_ sessions: [LiveAgentSession]) -> [LiveAgentSession] {
        sessions.sorted(by: precedes)
    }

    private static func precedes(_ left: LiveAgentSession, _ right: LiveAgentSession) -> Bool {
        let leftRank = rank(left.status), rightRank = rank(right.status)
        if leftRank != rightRank { return leftRank < rightRank }
        if left.status == .waiting {
            // The question asked longest ago is most likely holding up the work.
            let leftSince = left.details.stateSince ?? left.updatedAt
            let rightSince = right.details.stateSince ?? right.updatedAt
            if leftSince != rightSince { return leftSince < rightSince }
        } else if left.updatedAt != right.updatedAt {
            return left.updatedAt > right.updatedAt
        }
        if left.sessionID != right.sessionID { return left.sessionID < right.sessionID }
        // Profiles or processes can share a session id; keep the order total.
        return left.id < right.id
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
