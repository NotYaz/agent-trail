import Foundation
import XCTest
@testable import AgentTrailCore

final class AgentTrailLinkTests: XCTestCase {
    func testParsesTheFourForms() {
        XCTAssertEqual(parse("agenttrail://jump"), .jumpMostUrgent)
        XCTAssertEqual(parse("agenttrail://jump/"), .jumpMostUrgent)
        XCTAssertEqual(parse("AgentTrail://JUMP"), .jumpMostUrgent)
        XCTAssertEqual(parse("agenttrail://switcher"), .switcher)
        XCTAssertEqual(parse("agenttrail://jump?project=agent-trail"), .jumpProject("agent-trail"))
        XCTAssertEqual(parse("agenttrail://jump?project=%2FUsers%2Fivan%2FDev%2Fagent%20trail"),
                       .jumpProject("/Users/ivan/Dev/agent trail"))
        XCTAssertEqual(parse("agenttrail://jump?project=~/Dev/agent-trail"), .jumpProject("~/Dev/agent-trail"))
        XCTAssertEqual(parse("agenttrail://jump?session=local_ab12-cd"), .jumpSession("local_ab12-cd"))
        XCTAssertEqual(parse("agenttrail://jump?session=0199f1a2-7c3d-4e5f-8a9b-0c1d2e3f4a5b"),
                       .jumpSession("0199f1a2-7c3d-4e5f-8a9b-0c1d2e3f4a5b"))
    }

    func testRejectsEverythingElse() {
        let rejected = [
            "https://jump",
            "agenttrail:jump",
            "agenttrail://",
            "agenttrail://open",
            "agenttrail://jump/next",
            "agenttrail://jump?app=Terminal",
            "agenttrail://jump?project=a&session=b",
            "agenttrail://jump?project=a&project=b",
            "agenttrail://jump?project",
            "agenttrail://jump?project=",
            "agenttrail://jump?project=%20%20",
            "agenttrail://jump?project=Dev/agent-trail",
            "agenttrail://jump?project=agent%0Atrail",
            "agenttrail://jump?project=agent%E2%80%AEtrail",
            "agenttrail://jump?session=",
            "agenttrail://jump?session=..%2F..%2Fetc",
            "agenttrail://jump?session=a%20b",
            "agenttrail://jump?session=" + String(repeating: "a", count: 129),
            "agenttrail://switcher?project=a",
            "agenttrail://jump#top",
            "agenttrail://user@jump",
            "agenttrail://jump:8080",
            "agenttrail://jump?project=" + String(repeating: "a", count: 1025)
        ]
        for link in rejected {
            XCTAssertNil(parse(link), link)
        }
    }

    func testMostUrgentPicksByRanking() {
        let sessions = [
            session("idle", project: "/Dev/one", status: .idle, updated: 900),
            session("working", project: "/Dev/two", status: .working, updated: 500),
            session("waiting", project: "/Dev/three", status: .waiting, updated: 100)
        ]
        XCTAssertEqual(AgentTrailLink.jumpMostUrgent.pick(from: sessions)?.sessionID, "waiting")
        XCTAssertNil(AgentTrailLink.jumpMostUrgent.pick(from: []))
        XCTAssertNil(AgentTrailLink.switcher.pick(from: sessions))
    }

    func testProjectMatchesFolderNameOrPath() {
        let sessions = [
            session("other", project: "/Dev/other", status: .waiting, updated: 100),
            session("trail-idle", project: "/Dev/agent-trail", status: .idle, updated: 900),
            session("trail-working", project: "/Dev/agent-trail", workspace: "/Worktrees/hotkeys",
                    status: .working, updated: 500)
        ]
        XCTAssertEqual(AgentTrailLink.jumpProject("Agent-Trail").pick(from: sessions)?.sessionID, "trail-working")
        XCTAssertEqual(AgentTrailLink.jumpProject("/Dev/agent-trail/").pick(from: sessions)?.sessionID, "trail-working")
        XCTAssertEqual(AgentTrailLink.jumpProject("/Worktrees/hotkeys").pick(from: sessions)?.sessionID, "trail-working")
        XCTAssertNil(AgentTrailLink.jumpProject("trail").pick(from: sessions))
        XCTAssertNil(AgentTrailLink.jumpProject("/Dev").pick(from: sessions))
    }

    func testProjectPathResolvesSymlinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let real = root.appendingPathComponent("real-project")
        let link = root.appendingPathComponent("linked-project")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: root) }
        // Sessions report resolved paths; the temporary folder itself sits behind /var → /private/var.
        let sessions = [session("linked", project: canonicalPath(real.path), status: .idle, updated: 100)]
        XCTAssertEqual(AgentTrailLink.jumpProject(link.path).pick(from: sessions)?.sessionID, "linked")
        XCTAssertEqual(AgentTrailLink.jumpProject(real.path).pick(from: sessions)?.sessionID, "linked")
    }

    func testSessionMatchesSessionOrDesktopID() {
        let sessions = [
            session("cli-uuid", project: "/Dev/a", status: .idle, updated: 100),
            session("desktop-uuid", project: "/Dev/b", status: .idle, updated: 200, desktopID: "local_abc")
        ]
        XCTAssertEqual(AgentTrailLink.jumpSession("cli-uuid").pick(from: sessions)?.sessionID, "cli-uuid")
        XCTAssertEqual(AgentTrailLink.jumpSession("local_abc").pick(from: sessions)?.sessionID, "desktop-uuid")
        XCTAssertNil(AgentTrailLink.jumpSession("local_zzz").pick(from: sessions))
    }

    private func parse(_ string: String) -> AgentTrailLink? {
        guard let url = URL(string: string) else { return nil }
        return AgentTrailLink.parse(url)
    }

    private func session(_ id: String, project: String, workspace: String? = nil, status: LiveStatus,
                         updated: TimeInterval, desktopID: String? = nil) -> LiveAgentSession {
        LiveAgentSession(sourceID: "main", projectPath: project, workspacePath: workspace ?? project,
            sessionID: id, status: status, updatedAt: Date(timeIntervalSince1970: updated), pid: 10,
            details: LiveSessionDetails(desktopSessionID: desktopID))
    }
}
