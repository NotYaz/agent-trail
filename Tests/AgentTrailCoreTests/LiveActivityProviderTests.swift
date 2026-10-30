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

        func desktop(_ cliID: String, workspace: URL? = nil, priorIDs: [String] = []) throws {
            let cwd = workspace ?? project
            let record: [String: Any] = ["sessionId": "local_" + cliID, "cliSessionId": cliID,
                "priorCliSessionIds": priorIDs, "originCwd": project.path, "cwd": cwd.path,
                "lastActivityAt": now.timeIntervalSince1970 * 1000,
                "gitAnchors": [["gitRoot": project.path], ["gitRoot": cwd.path]],
                "title": "PRIVATE_PROMPT_MARKER"]
            try JSONSerialization.data(withJSONObject: record).write(to: desktopRoot.appendingPathComponent("local_" + cliID + ".json"))
        }

        func live(_ cliID: String, pid: Int32, status: String?, secondsAgo: TimeInterval,
                  statusSecondsAgo: TimeInterval? = nil, cwd: URL? = nil,
                  entrypoint: String = "claude-desktop", domain: String = "darwin", filename: String? = nil,
                  procStart: String? = nil) throws {
            var record: [String: Any] = ["pid": Int(pid), "sessionId": cliID, "cwd": (cwd ?? project).path,
                "entrypoint": entrypoint, "pidDomain": domain,
                "updatedAt": now.addingTimeInterval(-secondsAgo).timeIntervalSince1970 * 1000,
                "statusUpdatedAt": now.addingTimeInterval(-(statusSecondsAgo ?? secondsAgo)).timeIntervalSince1970 * 1000,
                "name": "PRIVATE_PROMPT_MARKER"]
            if let status { record["status"] = status }
            if let procStart { record["procStart"] = procStart }
            try JSONSerialization.data(withJSONObject: record).write(to: registry.appendingPathComponent(filename ?? "\(pid).json"))
        }
    }
}
