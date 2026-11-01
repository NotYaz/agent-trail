import Foundation
import XCTest
@testable import AgentTrailCore

final class LiveSessionRankingTests: XCTestCase {
    func testWaitingComesFirstThenWorkingIdleAndUnknown() {
        let sessions = [
            session("unknown", status: .unknown, updated: 900),
            session("idle", status: .idle, updated: 800),
            session("working", status: .working, updated: 100),
            session("waiting", status: .waiting, updated: 50)
        ]
        XCTAssertEqual(LiveSessionRanking.ordered(sessions).map(\.sessionID), ["waiting", "working", "idle", "unknown"])
    }

    func testLongestWaitComesFirstByStateSinceFallingBackToUpdatedAt() {
        let sessions = [
            // Reported recently, but it has been waiting the longest.
            session("asked-first", status: .waiting, updated: 500, since: 100),
            session("asked-last", status: .waiting, updated: 300, since: 290),
            // No recorded start: its report time stands in for it.
            session("no-start", status: .waiting, updated: 200)
        ]
        XCTAssertEqual(LiveSessionRanking.ordered(sessions).map(\.sessionID), ["asked-first", "no-start", "asked-last"])
    }

    func testWorkingIdleAndUnknownPutTheNewestReportFirst() {
        let sessions = [
            session("old-work", status: .working, updated: 100, since: 1_000),
            session("new-work", status: .working, updated: 200, since: 10),
            session("old-idle", status: .idle, updated: 300),
            session("new-idle", status: .idle, updated: 400),
            session("old-unknown", status: .unknown, updated: 500),
            session("new-unknown", status: .unknown, updated: 600)
        ]
        XCTAssertEqual(LiveSessionRanking.ordered(sessions).map(\.sessionID),
            ["new-work", "old-work", "new-idle", "old-idle", "new-unknown", "old-unknown"])
    }

    func testTiesBreakBySessionIDThenByIdentity() {
        let sessions = [
            session("b", status: .working, updated: 100),
            session("a", status: .working, updated: 100, pid: 2),
            session("a", status: .working, updated: 100, pid: 1),
            session("d", status: .waiting, updated: 100, since: 40),
            session("c", status: .waiting, updated: 900, since: 40)
        ]
        let ordered = LiveSessionRanking.ordered(sessions)
        XCTAssertEqual(ordered.map(\.sessionID), ["c", "d", "a", "a", "b"])
        XCTAssertEqual(ordered.map(\.pid), [10, 10, 1, 2, 10])
    }

    func testOrderDoesNotDependOnInputOrder() {
        let sessions = [
            session("waiting", status: .waiting, updated: 10, since: 5),
            session("working", status: .working, updated: 20),
            session("idle", status: .idle, updated: 30),
            session("unknown", status: .unknown, updated: 40),
            session("other", source: "second", status: .working, updated: 20)
        ]
        let expected = LiveSessionRanking.ordered(sessions).map(\.id)
        XCTAssertEqual(LiveSessionRanking.ordered(sessions.reversed()).map(\.id), expected)
        XCTAssertEqual(LiveSessionRanking.ordered([sessions[2], sessions[4], sessions[0], sessions[3], sessions[1]]).map(\.id), expected)
        XCTAssertTrue(LiveSessionRanking.ordered([]).isEmpty)
    }

    private func session(_ id: String, source: String = "main", status: LiveStatus, updated: TimeInterval,
                         since: TimeInterval? = nil, pid: Int32 = 10) -> LiveAgentSession {
        LiveAgentSession(sourceID: source, projectPath: "/Demo/Project", workspacePath: "/Demo/Project",
            sessionID: id, status: status, updatedAt: Date(timeIntervalSince1970: updated), pid: pid,
            details: LiveSessionDetails(stateSince: since.map { Date(timeIntervalSince1970: $0) }))
    }
}
