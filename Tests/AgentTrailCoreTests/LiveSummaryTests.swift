import Foundation
import XCTest
@testable import AgentTrailCore

final class LiveSummaryTests: XCTestCase {
    private let orbit = "/Demo/Projects/orbit", harbor = "/Demo/Projects/harbor", atlas = "/Demo/Projects/atlas"

    func testMixedStatusesStaySeparate() {
        let overviews = ProjectOverview.merge(projects: [], sessions: [
            session(orbit, id: "a", pid: 1, status: .waiting),
            session(orbit, id: "b", pid: 2, status: .working),
            session(orbit, id: "c", pid: 3, status: .idle),
            session(orbit, id: "d", pid: 4, status: .unknown),
            session(harbor, source: "codex", id: "e", pid: 5, status: .working),
            session(harbor, source: "codex", id: "f", pid: 6, status: .working)
        ])
        let summary = LiveSummary.make(overviews)
        XCTAssertEqual(summary, LiveSummary(waiting: 1, working: 3, idle: 1, unknown: 1,
                                            reportingProjects: 2, waitingProjects: 1, workingProjects: 2))
        XCTAssertEqual(summary.sessions, 6)
    }

    func testUnknownStaysSeparateFromIdle() {
        let summary = LiveSummary.make(ProjectOverview.merge(projects: [], sessions: [
            session(orbit, id: "a", pid: 1, status: .unknown),
            session(orbit, id: "b", pid: 2, status: .unknown)
        ]))
        XCTAssertEqual(summary.unknown, 2)
        XCTAssertEqual(summary.idle, 0)
        XCTAssertEqual(summary.reportingProjects, 1)
        XCTAssertEqual(summary.waitingProjects, 0)
        XCTAssertEqual(summary.workingProjects, 0)
    }

    func testProjectsWithoutALiveReportAreExcluded() {
        let history = ProjectSummary.merge([ProjectActivity(sourceID: "claude-primary", projectPath: atlas,
                                                            latestActivity: Date(timeIntervalSince1970: 100))])
        let historyOnly = ProjectOverview.merge(projects: history, sessions: [])
        XCTAssertEqual(historyOnly.count, 1)
        XCTAssertNil(historyOnly[0].live)
        XCTAssertEqual(LiveSummary.make(historyOnly), .empty)
        XCTAssertEqual(LiveSummary.make([]), .empty)
        XCTAssertEqual(LiveSummary.empty.sessions, 0)

        let mixed = ProjectOverview.merge(projects: history, sessions: [session(orbit, id: "a", pid: 1, status: .idle)])
        XCTAssertEqual(mixed.count, 2)
        let summary = LiveSummary.make(mixed)
        XCTAssertEqual(summary.reportingProjects, 1)
        XCTAssertEqual(summary.idle, 1)
        XCTAssertEqual(summary.sessions, 1)
    }

    func testProjectCountsCountProjectsNotSessions() {
        let summary = LiveSummary.make(ProjectOverview.merge(projects: [], sessions: [
            session(orbit, id: "a", pid: 1, status: .waiting),
            session(orbit, id: "b", pid: 2, status: .waiting),
            session(orbit, source: "codex", id: "c", pid: 3, status: .working),
            session(harbor, id: "d", pid: 4, status: .waiting),
            session(atlas, id: "e", pid: 5, status: .idle)
        ]))
        XCTAssertEqual(summary.waiting, 3)
        XCTAssertEqual(summary.waitingProjects, 2)
        XCTAssertEqual(summary.working, 1)
        XCTAssertEqual(summary.workingProjects, 1)
        XCTAssertEqual(summary.reportingProjects, 3)
    }

    private func session(_ project: String, source: String = "claude-primary", id: String, pid: Int32,
                         status: LiveStatus) -> LiveAgentSession {
        LiveAgentSession(sourceID: source, projectPath: project, workspacePath: project, sessionID: id,
                         status: status, updatedAt: Date(timeIntervalSince1970: 100), pid: pid)
    }
}
