import XCTest
@testable import AgentTrailCore

final class CompositeLiveActivityProviderTests: XCTestCase {
    func testRuntimeReadersAreIsolatedByAssistantAndJoinOneProject() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sources = AgentSource.defaults(home: "/Demo")
        var seen: [AssistantKind: [String]] = [:]
        let readers = Dictionary(uniqueKeysWithValues: AssistantKind.allCases.map { kind in
            (kind, { (profiles: [AgentSource], date: Date) -> LiveSnapshot in
                seen[kind] = profiles.map(\.id)
                XCTAssertEqual(date, now)
                return LiveSnapshot(sessions: profiles.map { profile in
                    LiveAgentSession(sourceID: profile.id, projectPath: "/Demo/shared", workspacePath: "/Demo/shared",
                        sessionID: profile.id, status: kind == .grok ? .waiting : .working,
                        updatedAt: date, pid: 42)
                }, notices: ["A shared notice"])
            })
        })
        let snapshot = CompositeLiveActivityProvider(readers: readers).scan(sources: sources, now: now)
        XCTAssertEqual(seen[.claude], sources.filter { $0.assistant == .claude }.map(\.id))
        XCTAssertEqual(seen[.codex], ["codex"])
        XCTAssertEqual(seen[.grok], ["grok"])
        XCTAssertEqual(snapshot.sessions.count, 4)
        XCTAssertEqual(snapshot.sessions.first?.sourceID, "grok")
        XCTAssertEqual(snapshot.notices, ["A shared notice"])
        let project = ProjectOverview.merge(projects: [], sessions: snapshot.sessions).first
        XCTAssertEqual(project?.sourceIDs.count, 4)
        XCTAssertNil(project?.history)
        XCTAssertEqual(project?.live?.workingCount, 3)
        XCTAssertEqual(project?.live?.waitingCount, 1)
    }
}
