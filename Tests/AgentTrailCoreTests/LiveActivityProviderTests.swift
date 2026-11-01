import Foundation
import XCTest
@testable import AgentTrailCore

final class LiveActivityProviderTests: XCTestCase {
    func testFreshExplicitBusyAndIdleFlagsWithLivePIDs() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.desktop("working")
        try fixture.desktop("idle")
        try fixture.live("working", pid: 101, status: "busy", secondsAgo: 10)
        try fixture.live("idle", pid: 102, status: "idle", secondsAgo: 20)
        let provider = LiveActivityProvider(isProcessAlive: { [101, 102].contains($0) })
        let result = provider.scan(sources: [fixture.source], now: fixture.now)
        XCTAssertEqual(result.sessions.map(\.status), [.working, .idle])
        XCTAssertEqual(result.sessions.map(\.pid), [101, 102])
        XCTAssertEqual(result.sessions[0].projectPath, fixture.project.path)
        XCTAssertEqual(result.sessions[0].workspacePath, fixture.project.path)
        XCTAssertEqual(result.scannedAt, fixture.now)
        XCTAssertTrue(result.notices.isEmpty)
    }

    func testFreshAndVerifiedLongWaitingAreExplicitAttentionStates() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.desktop("fresh-waiting")
        try fixture.desktop("long-waiting")
        let start = "Fri Oct 30 10:02:00 2026"
        try fixture.live("fresh-waiting", pid: 101, status: "waiting", secondsAgo: 10)
        try fixture.live("long-waiting", pid: 102, status: "waiting", secondsAgo: 3600, procStart: start)
        let provider = LiveActivityProvider(isProcessAlive: { _ in true }, processStartTimes: { _ in [102: start] })
        let result = provider.scan(sources: [fixture.source], now: fixture.now)
        XCTAssertEqual(result.sessions.map(\.status), [.waiting, .waiting])
        XCTAssertTrue(result.notices.isEmpty)
    }

    func testStaleFutureOrReusedWaitingCannotClaimCurrentAttention() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for id in ["stale-waiting", "future-waiting", "reused-waiting"] { try fixture.desktop(id) }
        let start = "Fri Oct 30 10:02:00 2026"
        try fixture.live("stale-waiting", pid: 101, status: "waiting", secondsAgo: 91)
        try fixture.live("future-waiting", pid: 102, status: "waiting", secondsAgo: -30, procStart: start)
        try fixture.live("reused-waiting", pid: 103, status: "waiting", secondsAgo: 1, procStart: start)
        let provider = LiveActivityProvider(isProcessAlive: { _ in true }, processStartTimes: { _ in
            [102: start, 103: "Fri Oct 30 11:30:00 2026"]
        })
        let result = provider.scan(sources: [fixture.source], now: fixture.now)
        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertTrue(result.sessions.allSatisfy { $0.status == .unknown })
        XCTAssertFalse(result.sessions.contains { $0.sessionID == "reused-waiting" })
    }

    func testProviderPrioritizesWaitingThenWorkingIdleAndUnknown() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for id in ["working", "waiting", "idle", "unknown"] { try fixture.desktop(id) }
        try fixture.live("working", pid: 101, status: "busy", secondsAgo: 1)
        try fixture.live("waiting", pid: 102, status: "waiting", secondsAgo: 60)
        try fixture.live("idle", pid: 103, status: "idle", secondsAgo: 0)
        try fixture.live("unknown", pid: 104, status: nil, secondsAgo: 0)
        let result = LiveActivityProvider(isProcessAlive: { _ in true }).scan(sources: [fixture.source], now: fixture.now)
        XCTAssertEqual(result.sessions.map(\.status), [.waiting, .working, .idle, .unknown])
    }

    func testIdleDoesNotBecomeWaitingFromAReasonOrPromptReadiness() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.desktop("idle")
        try fixture.live("idle", pid: 101, status: "idle", secondsAgo: 1, waitingFor: "input needed")
        let result = LiveActivityProvider(isProcessAlive: { _ in true }).scan(sources: [fixture.source], now: fixture.now)
        XCTAssertEqual(result.sessions[0].status, .idle)
    }

    func testStaleFlagAndFutureTimestampCannotClaimWorking() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.desktop("stale")
        try fixture.desktop("future")
        try fixture.live("stale", pid: 101, status: "busy", secondsAgo: 91)
        try fixture.live("future", pid: 102, status: "busy", secondsAgo: -30)
        let provider = LiveActivityProvider(freshnessTTL: 90, isProcessAlive: { _ in true })
        let result = provider.scan(sources: [fixture.source], now: fixture.now)
        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertTrue(result.sessions.allSatisfy { $0.status == .unknown })
        XCTAssertTrue(result.notices.contains { $0.contains("old status report") })
    }

    func testVerifiedProcessTransitionStateSurvivesLongJobsAndIdlePeriods() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.desktop("long-job")
        try fixture.desktop("long-idle")
        let workingStart = "Fri Oct 30 10:02:00 2026"
        let idleStart = "Fri Oct 30 11:02:00 2026"
        try fixture.live("long-job", pid: 101, status: "busy", secondsAgo: 3600, procStart: workingStart)
        try fixture.live("long-idle", pid: 102, status: "idle", secondsAgo: 86_400, procStart: idleStart)
        let provider = LiveActivityProvider(isProcessAlive: { _ in true }, processStartTimes: { _ in
            [101: "Fri  Oct 30 10:02:00 2026", 102: idleStart]
        })
        let result = provider.scan(sources: [fixture.source], now: fixture.now)
        XCTAssertEqual(result.sessions.map(\.status), [.working, .idle])
        XCTAssertEqual(result.sessions[0].updatedAt, fixture.now.addingTimeInterval(-3600))
        XCTAssertFalse(result.notices.contains { $0.contains("old status report") })
    }

    func testVerifiedIdentityStillRejectsFutureDatedStatus() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.desktop("future")
        let start = "Fri Oct 30 10:02:00 2026"
        try fixture.live("future", pid: 101, status: "busy", secondsAgo: -30, procStart: start)
        let provider = LiveActivityProvider(isProcessAlive: { _ in true }, processStartTimes: { _ in [101: start] })
        XCTAssertEqual(provider.scan(sources: [fixture.source], now: fixture.now).sessions[0].status, .unknown)
    }

    func testReusedPIDIsOmittedEvenWhenItsOldRecordLooksFresh() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.desktop("reused")
        try fixture.live("reused", pid: 101, status: "busy", secondsAgo: 1,
            procStart: "Fri Oct 30 10:02:00 2026")
        let provider = LiveActivityProvider(isProcessAlive: { _ in true }, processStartTimes: { _ in
            [101: "Fri Oct 30 11:30:00 2026"]
        })
        let result = provider.scan(sources: [fixture.source], now: fixture.now)
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertTrue(result.notices.contains { $0.contains("reused PID") })
    }

    func testUnavailableProcessIdentityFallsBackToShortFreshnessWindow() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.desktop("recent")
        try fixture.desktop("old")
        let start = "Fri Oct 30 10:02:00 2026"
        try fixture.live("recent", pid: 101, status: "busy", secondsAgo: 20, procStart: start)
        try fixture.live("old", pid: 102, status: "busy", secondsAgo: 120, procStart: start)
        let provider = LiveActivityProvider(isProcessAlive: { _ in true }, processStartTimes: { _ in [:] })
        let result = provider.scan(sources: [fixture.source], now: fixture.now)
        XCTAssertEqual(result.sessions.map(\.status), [.working, .unknown])
    }

    func testLaunchIdentityLookupIsBatchedOnceAcrossProfiles() throws {
        let first = try Fixture()
        let second = try Fixture()
        defer { first.remove(); second.remove() }
        try first.desktop("first")
        try second.desktop("second")
        let start = "Fri Oct 30 10:02:00 2026"
        try first.live("first", pid: 101, status: "busy", secondsAgo: 3600, procStart: start)
        try second.live("second", pid: 202, status: "idle", secondsAgo: 3600, procStart: start)
        var secondSource = second.source
        secondSource.id = "second"
        var batches: [Set<Int32>] = []
        let provider = LiveActivityProvider(isProcessAlive: { _ in true }, processStartTimes: {
            batches.append($0)
            return [101: start, 202: start]
        })
        let result = provider.scan(sources: [first.source, secondSource], now: first.now)
        XCTAssertEqual(batches, [Set([101, 202])])
        XCTAssertEqual(result.sessions.map(\.sourceID), ["main", "second"])
    }

    func testStatusTimestampWinsOverRecentUnrelatedMetadataUpdate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.desktop("old-busy")
        try fixture.live("old-busy", pid: 101, status: "busy", secondsAgo: 1, statusSecondsAgo: 120)
        let result = LiveActivityProvider(isProcessAlive: { _ in true }).scan(sources: [fixture.source], now: fixture.now)
        XCTAssertEqual(result.sessions[0].status, .unknown)
        XCTAssertEqual(result.sessions[0].updatedAt, fixture.now.addingTimeInterval(-120))
    }

    func testNoAuthoritativeFlagDoesNotInferWorkingFromFreshActivity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.desktop("missing")
        try fixture.desktop("unrecognized")
        try fixture.live("missing", pid: 101, status: nil, secondsAgo: 0)
        try fixture.live("unrecognized", pid: 102, status: "running", secondsAgo: 0)
        let result = LiveActivityProvider(isProcessAlive: { _ in true }).scan(sources: [fixture.source], now: fixture.now)
        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertTrue(result.sessions.allSatisfy { $0.status == .unknown })
    }

    func testDeadTerminalForeignDomainAndMismatchedPIDRecordsAreIgnored() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for id in ["dead", "terminal-entrypoint", "foreign", "wrong-file"] { try fixture.desktop(id) }
        try fixture.live("dead", pid: 101, status: "busy", secondsAgo: 1)
        try fixture.live("terminal-only", pid: 102, status: "busy", secondsAgo: 1)
        try fixture.live("terminal-entrypoint", pid: 103, status: "busy", secondsAgo: 1, entrypoint: "cli")
        try fixture.live("foreign", pid: 104, status: "busy", secondsAgo: 1, domain: "linux")
        try fixture.live("wrong-file", pid: 105, status: "busy", secondsAgo: 1, filename: "999.json")
        var checked: [Int32] = []
        let provider = LiveActivityProvider(isProcessAlive: { checked.append($0); return false })
        XCTAssertTrue(provider.scan(sources: [fixture.source], now: fixture.now).sessions.isEmpty)
        XCTAssertEqual(checked, [101])
    }

    func testOriginAndActualWorktreeStaySeparateIncludingPriorCLIIdentity() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let worktree = fixture.project.appendingPathComponent(".claude/worktrees/feature")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try fixture.desktop("current-cli", workspace: worktree, priorIDs: ["prior-cli"])
        try fixture.live("prior-cli", pid: 101, status: "busy", secondsAgo: 1, cwd: worktree)
        let result = LiveActivityProvider(isProcessAlive: { _ in true }).scan(sources: [fixture.source], now: fixture.now)
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions[0].projectPath, fixture.project.path)
        XCTAssertEqual(result.sessions[0].workspacePath, worktree.path)
        XCTAssertEqual(result.sessions[0].sessionID, "prior-cli")
    }

    func testWrongProfileAndExternalWorkspaceAreNotAttributed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.desktop("known")
        try fixture.live("known", pid: 101, status: "busy", secondsAgo: 1,
            cwd: fixture.root.appendingPathComponent("other-project"))
        let provider = LiveActivityProvider(isProcessAlive: { _ in true })
        let result = provider.scan(sources: [fixture.source], now: fixture.now)
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertTrue(result.notices.contains { $0.contains("outside its known desktop checkout") })
        let other = AgentSource(id: "other", name: "Other profile", configDirectory: fixture.root.appendingPathComponent("other-config").path,
            userDataDirectory: fixture.root.appendingPathComponent("other-desktop").path)
        XCTAssertTrue(provider.scan(sources: [other], now: fixture.now).sessions.isEmpty)
    }

    func testUnreadableRecordProducesContentFreeNoticeAndScanDoesNotWrite() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.desktop("known")
        let url = fixture.registry.appendingPathComponent("101.json")
        try Data("PRIVATE_PROMPT_MARKER invalid json".utf8).write(to: url)
        let before = try Data(contentsOf: url)
        let result = LiveActivityProvider(isProcessAlive: { _ in true }).scan(sources: [fixture.source], now: fixture.now)
        XCTAssertTrue(result.notices.contains { $0.contains("could not be read") })
        XCTAssertFalse(result.notices.joined().contains("PRIVATE_PROMPT_MARKER"))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.registry.path), ["101.json"])
    }

    func testDefaultPIDCheckAcceptsCurrentProcessAndFreshnessCanBeConfigured() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.desktop("self")
        try fixture.live("self", pid: ProcessInfo.processInfo.processIdentifier, status: "idle", secondsAgo: 100)
        let provider = LiveActivityProvider(freshnessTTL: 180)
        XCTAssertEqual(provider.scan(sources: [fixture.source], now: fixture.now).sessions.first?.status, .idle)
        XCTAssertEqual(LiveActivityProvider(freshnessTTL: .nan).freshnessTTL, 90)
    }

    func testCodexAndGrokProfilesAreNotReadAsClaudeLiveStatus() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-trail-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sessions"), withIntermediateDirectories: true)
        let registry = root.appendingPathComponent("sessions/101.json")
        let record: [String: Any] = ["pid": 101, "sessionId": "cli", "cwd": "/tmp/project", "status": "busy",
            "statusUpdatedAt": Date().timeIntervalSince1970 * 1000, "entrypoint": "claude-desktop"]
        try JSONSerialization.data(withJSONObject: record).write(to: registry)
        let codex = AgentSource(id: "codex", name: "Codex", configDirectory: root.path, assistant: .codex)
        let grok = AgentSource(id: "grok", name: "Grok", configDirectory: root.path, assistant: .grok)
        let result = LiveActivityProvider(isProcessAlive: { _ in true }).scan(sources: [codex, grok])
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertTrue(result.notices.isEmpty)
        try FileManager.default.removeItem(at: root)
    }

    func testDesktopLinkNeedsMatchingHostValidShapeAndUnarchivedSession() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.desktop("linked", extra: ["title": "  Tighten sync retries\n", "branch": "feature/retries", "isArchived": false])
        try fixture.desktop("archived", extra: ["isArchived": true])
        try fixture.desktop("unclear-archive", extra: ["isArchived": "no"])
        try fixture.desktop("mismatch")
        try fixture.desktop("bad-shape", extra: ["sessionId": "local_bad shape"])
        try fixture.desktop("no-host")
        try fixture.live("linked", pid: 101, status: "busy", secondsAgo: 1, extra: ["hostSessionId": "local_linked"])
        try fixture.live("archived", pid: 102, status: "busy", secondsAgo: 1, extra: ["hostSessionId": "local_archived"])
        try fixture.live("unclear-archive", pid: 103, status: "busy", secondsAgo: 1,
            extra: ["hostSessionId": "local_unclear-archive"])
        try fixture.live("mismatch", pid: 104, status: "busy", secondsAgo: 1, extra: ["hostSessionId": "local_someone-else"])
        try fixture.live("bad-shape", pid: 105, status: "busy", secondsAgo: 1, extra: ["hostSessionId": "local_bad shape"])
        try fixture.live("no-host", pid: 106, status: "busy", secondsAgo: 1)
        let result = LiveActivityProvider(isProcessAlive: { _ in true }).scan(sources: [fixture.source], now: fixture.now)
        let byID = Dictionary(uniqueKeysWithValues: result.sessions.map { ($0.sessionID, $0) })
        XCTAssertEqual(Set(byID.keys), ["linked", "archived", "unclear-archive", "mismatch", "bad-shape", "no-host"])
        XCTAssertEqual(byID["linked"]?.details.desktopSessionID, "local_linked")
        for id in ["archived", "unclear-archive", "mismatch", "bad-shape", "no-host"] {
            XCTAssertNil(byID[id]?.details.desktopSessionID, id)
        }
        XCTAssertEqual(byID["linked"]?.details.title, "Tighten sync retries")
        XCTAssertEqual(byID["linked"]?.details.branch, "feature/retries")
        // A session that cannot be linked still carries its other details.
        XCTAssertEqual(byID["archived"]?.details.title, "PRIVATE_PROMPT_MARKER")
        XCTAssertFalse(result.notices.joined().contains("PRIVATE_PROMPT_MARKER"))
        XCTAssertFalse(result.notices.joined().contains("Tighten"))
    }

    func testMalformedOptionalDetailsNeverDropTheSession() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.desktop("odd-shapes", extra: ["title": 42, "branch": ["main"], "isArchived": "yes",
            "postTurnSummary": "blocked", "prs": "none", "lastAssistantUuid": 7, "lastActivityAt": "soon"])
        let oddSummary: [String: Any] = ["needs_action": 7, "summarizes_uuid": ["x"]]
        let oddPullRequests: [Any] = [1, "pull", NSNull(),
            ["prNumber": "3", "url": "https://example.com/demo/pull/3"],
            ["prNumber": 4, "url": 5],
            ["prNumber": 6, "url": "https://example.com/demo/pull/6", "state": 1] as [String: Any]]
        try fixture.desktop("odd-items", extra: ["isArchived": NSNull(), "postTurnSummary": oddSummary,
            "prs": oddPullRequests])
        try fixture.live("odd-shapes", pid: 101, status: "idle", secondsAgo: 1, extra: ["hostSessionId": 99])
        try fixture.live("odd-items", pid: 102, status: "idle", secondsAgo: 1, extra: ["hostSessionId": "local_odd-items"])
        let result = LiveActivityProvider(isProcessAlive: { _ in true }).scan(sources: [fixture.source], now: fixture.now)
        let byID = Dictionary(uniqueKeysWithValues: result.sessions.map { ($0.sessionID, $0) })
        XCTAssertEqual(Set(byID.keys), ["odd-shapes", "odd-items"])
        XCTAssertTrue(result.notices.isEmpty)
        let shapes = try XCTUnwrap(byID["odd-shapes"]?.details)
        XCTAssertNil(shapes.title)
        XCTAssertNil(shapes.branch)
        XCTAssertNil(shapes.needsAction)
        XCTAssertNil(shapes.desktopSessionID)
        XCTAssertTrue(shapes.pullRequests.isEmpty)
        let items = try XCTUnwrap(byID["odd-items"]?.details)
        // A null archive flag means not archived, so the id still links.
        XCTAssertEqual(items.desktopSessionID, "local_odd-items")
        XCTAssertNil(items.needsAction)
        XCTAssertEqual(items.pullRequests.map(\.number), [6])
        XCTAssertEqual(byID["odd-items"]?.status, .idle)
    }

    func testNeedsActionPullRequestsAndStateSinceComeFromTheirRecords() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let summary: [String: Any] = ["status_category": "blocked",
            "needs_action": " Approve running the migration ", "summarizes_uuid": "turn-2"]
        // Kept: the first https link (once) and an upper-case scheme. Dropped: plain
        // http, other schemes, embedded credentials, number 0 and a missing host.
        let pullRequests: [[String: Any]] = [
            ["prNumber": 12, "url": "https://example.com/demo/pull/12", "state": "open"],
            ["prNumber": 12, "url": "https://example.com/demo/pull/12"],
            ["prNumber": 13, "url": "http://example.com/demo/pull/13"],
            ["prNumber": 14, "url": "javascript:alert(14)"],
            ["prNumber": 15, "url": "https://user:secret@example.com/demo/pull/15"],
            ["prNumber": 0, "url": "https://example.com/demo/pull/0"],
            ["prNumber": 16, "url": "https:///demo/pull/16"],
            ["prNumber": 17, "url": "HTTPS://example.com/demo/pull/17"]]
        try fixture.desktop("blocked", extra: ["postTurnSummary": summary, "lastAssistantUuid": "turn-2",
            "prs": pullRequests])
        try fixture.desktop("completed", extra: ["postTurnSummary": ["status_category": "completed", "needs_action": ""]])
        // The summary describes an earlier turn than the latest assistant message.
        try fixture.desktop("stale-summary", extra: [
            "postTurnSummary": ["needs_action": "Pick a layout", "summarizes_uuid": "turn-1"],
            "lastAssistantUuid": "turn-3"])
        try fixture.live("blocked", pid: 101, status: "waiting", secondsAgo: 2, statusSecondsAgo: 40)
        try fixture.live("completed", pid: 102, status: "idle", secondsAgo: 10)
        try fixture.live("stale-summary", pid: 103, status: "busy", secondsAgo: 10)
        let result = LiveActivityProvider(isProcessAlive: { _ in true }).scan(sources: [fixture.source], now: fixture.now)
        let byID = Dictionary(uniqueKeysWithValues: result.sessions.map { ($0.sessionID, $0) })
        let blocked = try XCTUnwrap(byID["blocked"])
        XCTAssertEqual(blocked.status, .waiting)
        XCTAssertEqual(blocked.details.needsAction, "Approve running the migration")
        XCTAssertEqual(blocked.details.stateSince, fixture.now.addingTimeInterval(-40))
        XCTAssertEqual(blocked.details.pullRequests.map(\.number), [12, 17])
        XCTAssertEqual(blocked.details.pullRequests.first?.url.absoluteString, "https://example.com/demo/pull/12")
        XCTAssertNil(byID["completed"]?.details.needsAction)
        XCTAssertEqual(byID["completed"]?.details.stateSince, fixture.now.addingTimeInterval(-10))
        XCTAssertEqual(byID["stale-summary"]?.status, .working)
        XCTAssertNil(byID["stale-summary"]?.details.needsAction)
    }

    func testStateSinceNeedsAStatusTimestampAndATrustedState() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for id in ["no-status-time", "unrecognized", "stale"] { try fixture.desktop(id) }
        try fixture.live("no-status-time", pid: 101, status: "busy", secondsAgo: 5, extra: ["statusUpdatedAt": NSNull()])
        try fixture.live("unrecognized", pid: 102, status: "running", secondsAgo: 5)
        try fixture.live("stale", pid: 103, status: "busy", secondsAgo: 120)
        let result = LiveActivityProvider(isProcessAlive: { _ in true }).scan(sources: [fixture.source], now: fixture.now)
        let byID = Dictionary(uniqueKeysWithValues: result.sessions.map { ($0.sessionID, $0) })
        XCTAssertEqual(byID["no-status-time"]?.status, .working)
        XCTAssertEqual(byID["no-status-time"]?.updatedAt, fixture.now.addingTimeInterval(-5))
        XCTAssertNil(byID["no-status-time"]?.details.stateSince)
        XCTAssertEqual(byID["unrecognized"]?.status, .unknown)
        XCTAssertNil(byID["unrecognized"]?.details.stateSince)
        XCTAssertEqual(byID["stale"]?.status, .unknown)
        XCTAssertNil(byID["stale"]?.details.stateSince)
    }

    func testDesktopSessionIDShapeMatchesClaudesLinkHandler() {
        XCTAssertTrue(LiveActivityProvider.isDesktopSessionID("local_0f8a-B2c"))
        XCTAssertTrue(LiveActivityProvider.isDesktopSessionID("local_" + String(repeating: "a", count: 64)))
        let rejected = ["", "local_", "local_" + String(repeating: "a", count: 65), "LOCAL_abc", "xlocal_abc",
                        "local_abc\n", "local_a b", "local_a/b", "local_a_b", "local_\u{e9}", "session_abc"]
        for value in rejected {
            XCTAssertFalse(LiveActivityProvider.isDesktopSessionID(value), value)
        }
    }

    private final class Fixture {
        let root: URL
        let project: URL
        let registry: URL
        let desktopRoot: URL
        let source: AgentSource
        let now = Date(timeIntervalSince1970: 2_000_000)

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("AgentTrailLiveTests-" + UUID().uuidString)
            project = root.appendingPathComponent("project")
            registry = root.appendingPathComponent("config/sessions")
            desktopRoot = root.appendingPathComponent("desktop/claude-code-sessions/account/org")
            source = AgentSource(id: "main", name: "Test Claude", configDirectory: root.appendingPathComponent("config").path,
                userDataDirectory: root.appendingPathComponent("desktop").path)
            for directory in [project, registry, desktopRoot] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        /// `extra` adds or replaces top-level fields of the Desktop record.
        func desktop(_ cliID: String, workspace: URL? = nil, priorIDs: [String] = [], extra: [String: Any] = [:]) throws {
            let cwd = workspace ?? project
            var record: [String: Any] = ["sessionId": "local_" + cliID, "cliSessionId": cliID,
                "priorCliSessionIds": priorIDs, "originCwd": project.path, "cwd": cwd.path,
                "lastActivityAt": now.timeIntervalSince1970 * 1000,
                "gitAnchors": [["gitRoot": project.path], ["gitRoot": cwd.path]],
                "title": "PRIVATE_PROMPT_MARKER"]
            record.merge(extra) { _, replacement in replacement }
            try JSONSerialization.data(withJSONObject: record).write(to: desktopRoot.appendingPathComponent("local_" + cliID + ".json"))
        }

        func live(_ cliID: String, pid: Int32, status: String?, secondsAgo: TimeInterval,
                  statusSecondsAgo: TimeInterval? = nil, cwd: URL? = nil,
                  entrypoint: String = "claude-desktop", domain: String = "darwin", filename: String? = nil,
                  procStart: String? = nil, waitingFor: String? = nil, extra: [String: Any] = [:]) throws {
            var record: [String: Any] = ["pid": Int(pid), "sessionId": cliID, "cwd": (cwd ?? project).path,
                "entrypoint": entrypoint, "pidDomain": domain,
                "updatedAt": now.addingTimeInterval(-secondsAgo).timeIntervalSince1970 * 1000,
                "statusUpdatedAt": now.addingTimeInterval(-(statusSecondsAgo ?? secondsAgo)).timeIntervalSince1970 * 1000,
                "name": "PRIVATE_PROMPT_MARKER"]
            if let status { record["status"] = status }
            if let procStart { record["procStart"] = procStart }
            if let waitingFor { record["waitingFor"] = waitingFor }
            record.merge(extra) { _, replacement in replacement }
            try JSONSerialization.data(withJSONObject: record).write(to: registry.appendingPathComponent(filename ?? "\(pid).json"))
        }
    }
}
