import Foundation
import SQLite3
import XCTest
@testable import AgentTrailCore

final class CodexLiveActivityProviderTests: XCTestCase {
    func testDesktopServerCommandAcceptsGlobalOverridesBeforeAppServer() {
        XCTAssertTrue(CodexLiveActivityProvider.isAppServerArguments(["codex", "-c", "features.code_mode_host=true", "app-server", "--analytics-default-enabled"]))
        XCTAssertTrue(CodexLiveActivityProvider.isAppServerArguments(["codex", "--config=features.code_mode_host=true", "--enable", "example", "--disable=other", "--profile", "work", "--strict-config", "app-server"]))
        XCTAssertTrue(CodexLiveActivityProvider.isAppServerArguments(["codex", "-cfeatures.example=true", "app-server"]))
        XCTAssertTrue(CodexLiveActivityProvider.isAppServerArguments(["codex", "app-server"]))
    }

    func testAppServerStringInsideAnotherCommandOrOptionValueDoesNotVerify() {
        for arguments in [
            ["codex", "exec", "app-server"],
            ["codex", "--enable", "app-server"],
            ["codex", "--config", "app-server"],
            ["codex", "--unknown-option", "app-server"],
            ["codex", "--", "app-server"],
            ["codex", "-c"],
            ["codex", "--enable=", "app-server"]
        ] { XCTAssertFalse(CodexLiveActivityProvider.isAppServerArguments(arguments)) }
    }

    func testOwnedLoadedTurnsReportWorkingAndIdleWithoutReadingMessages() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(Fixture.first, status: "inProgress", began: -60)
        try fixture.session(Fixture.second, status: "completed", began: -3600, ended: -3500)
        let provider = fixture.provider(owners: [Fixture.first: 101, Fixture.second: 101])
        let snapshot = provider.scan(sources: [fixture.source], now: fixture.now)
        XCTAssertEqual(snapshot.sessions.map(\.status), [.working, .idle])
        XCTAssertEqual(snapshot.sessions.map(\.pid), [101, 101])
        XCTAssertEqual(snapshot.sessions.first?.projectPath, fixture.project.path)
        XCTAssertTrue(snapshot.notices.isEmpty)
    }

    func testHistoricalAndUnownedInProgressTurnsDoNotBecomeLive() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(Fixture.first, status: "inProgress", began: -10)
        try Data().write(to: fixture.locks.appendingPathComponent(Fixture.first + ".lock"))
        XCTAssertTrue(fixture.provider(owners: [:]).scan(sources: [fixture.source], now: fixture.now).sessions.isEmpty)
        XCTAssertTrue(fixture.provider(owners: [Fixture.first: 101], verified: false)
            .scan(sources: [fixture.source], now: fixture.now).sessions.isEmpty)
    }

    func testPresenceDisappearsImmediatelyWhenTheWriterCloses() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(Fixture.first, status: "completed", began: -20, ended: -10)
        var owners: [String: Int32] = [Fixture.first: 101]
        let provider = CodexLiveActivityProvider(openSessionOwners: { _ in owners },
            serverStartedAt: { _ in fixture.now.addingTimeInterval(-1000) })
        XCTAssertEqual(provider.scan(sources: [fixture.source], now: fixture.now).sessions.count, 1)
        owners = [:]
        XCTAssertTrue(provider.scan(sources: [fixture.source], now: fixture.now).sessions.isEmpty)
    }

    func testAnInterruptedProjectionFromBeforeServerRestartIsUnknown() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(Fixture.first, status: "inProgress", began: -2000)
        let snapshot = fixture.provider(owners: [Fixture.first: 101])
            .scan(sources: [fixture.source], now: fixture.now)
        XCTAssertEqual(snapshot.sessions.first?.status, .unknown)
        XCTAssertTrue(snapshot.notices.contains { $0.contains("no verified current turn state") })
    }

    func testLongRunningTurnDoesNotExpireWhileItsOriginalServerOwnsIt() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(Fixture.first, status: "inProgress", began: -86400)
        let provider = CodexLiveActivityProvider(openSessionOwners: { _ in [Fixture.first: 101] },
            serverStartedAt: { _ in fixture.now.addingTimeInterval(-100000) })
        XCTAssertEqual(provider.scan(sources: [fixture.source], now: fixture.now).sessions.first?.status, .working)
    }

    func testLatestTurnWinsAndForksStayIsolatedByThreadID() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(Fixture.first, status: "inProgress", began: -30)
        try fixture.session(Fixture.second, status: "completed", began: -20, ended: -10)
        try fixture.turn(Fixture.first, ordinal: 10, status: "interrupted", began: -10, ended: -5)
        let snapshot = fixture.provider(owners: [Fixture.first: 101])
            .scan(sources: [fixture.source], now: fixture.now)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions.first?.sessionID, Fixture.first)
        XCTAssertEqual(snapshot.sessions.first?.status, .idle)
        XCTAssertEqual(snapshot.sessions.first?.updatedAt, fixture.now.addingTimeInterval(-5))
    }

    func testFutureContradictoryAndUnrecognizedProjectionsAreUnknown() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(Fixture.first, status: "inProgress", began: 60)
        try fixture.session(Fixture.second, status: "inProgress", began: -10, ended: -5)
        try fixture.session(Fixture.third, status: "waitingOnApproval", began: -10)
        let snapshot = fixture.provider(owners: [Fixture.first: 101, Fixture.second: 101, Fixture.third: 101])
            .scan(sources: [fixture.source], now: fixture.now)
        XCTAssertEqual(snapshot.sessions.count, 3)
        XCTAssertTrue(snapshot.sessions.allSatisfy { $0.status == .unknown })
    }

    func testFailedCompletedAndInterruptedTurnsAreIdleOnlyWithAnEndTime() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(Fixture.first, status: "failed", began: -20, ended: -10)
        try fixture.session(Fixture.second, status: "interrupted", began: -20, ended: -10)
        try fixture.session(Fixture.third, status: "completed", began: -20)
        let snapshot = fixture.provider(owners: [Fixture.first: 101, Fixture.second: 101, Fixture.third: 101])
            .scan(sources: [fixture.source], now: fixture.now)
        XCTAssertEqual(snapshot.sessions.filter { $0.status == .idle }.count, 2)
        XCTAssertEqual(snapshot.sessions.first { $0.sessionID == Fixture.third }?.status, .unknown)
    }

    func testEndedTurnsRejectFutureStartsAndEndBeforeStart() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(Fixture.first, status: "completed", began: 60, ended: -10)
        try fixture.session(Fixture.second, status: "interrupted", began: -10, ended: -20)
        try fixture.session(Fixture.third, status: "failed", began: 60, ended: -10)
        let snapshot = fixture.provider(owners: [Fixture.first: 101, Fixture.second: 101, Fixture.third: 101])
            .scan(sources: [fixture.source], now: fixture.now)
        XCTAssertEqual(snapshot.sessions.count, 3)
        XCTAssertTrue(snapshot.sessions.allSatisfy { $0.status == .unknown })
    }

    func testMissingDatabasesAreNotCreatedAndSourceKindIsRespected() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.history)
        let before = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        let result = fixture.provider(owners: [Fixture.first: 101]).scan(sources: [fixture.source], now: fixture.now)
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertTrue(result.notices.contains { $0.contains("projection is unavailable") })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path), before)
        let claude = AgentSource(id: "claude", name: "Claude", configDirectory: fixture.root.path, assistant: .claude)
        XCTAssertTrue(fixture.provider(owners: [Fixture.first: 101]).scan(sources: [claude], now: fixture.now).sessions.isEmpty)
    }

    func testForeignRolloutAndInvalidProjectMetadataAreOmitted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(Fixture.first, status: "inProgress", began: -10, rollout: "/another-profile/sessions/rollout-\(Fixture.first).jsonl")
        try fixture.session(Fixture.second, status: "inProgress", began: -10, project: "relative/project")
        let result = fixture.provider(owners: [Fixture.first: 101, Fixture.second: 101])
            .scan(sources: [fixture.source], now: fixture.now)
        XCTAssertTrue(result.sessions.isEmpty)
    }

    func testReadingProjectionLeavesDatabaseContentsAndModificationDatesUntouched() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(Fixture.first, status: "inProgress", began: -10)
        let before = try [fixture.state, fixture.history].map { (try Data(contentsOf: $0), try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) }
        _ = fixture.provider(owners: [Fixture.first: 101]).scan(sources: [fixture.source], now: fixture.now)
        for (index, url) in [fixture.state, fixture.history].enumerated() {
            XCTAssertEqual(try Data(contentsOf: url), before[index].0)
            XCTAssertEqual(try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, before[index].1)
        }
    }

    func testOwnerParserRejectsOtherProfilesInvalidIDsAndConflictingOwners() throws {
        let directory = URL(fileURLWithPath: "/profiles/codex/thread-writer-locks")
        let root = directory.path
        let output = """
        p101
        f10
        n\(root)/\(Fixture.first).lock
        n/profiles/other/thread-writer-locks/\(Fixture.second).lock
        n\(root)/not-a-thread.lock
        n\(root)/nested/\(Fixture.third).lock
        p102
        n\(root)/\(Fixture.first).lock
        n\(root)/\(Fixture.second).lock
        """
        XCTAssertEqual(CodexLiveActivityProvider.parseOpenSessionOwners(output, directory: directory), [Fixture.second: 102])
    }

    private final class Fixture {
        static let first = "01a18dcb-3538-7eb3-86f7-d8738aeb179e"
        static let second = "01a19149-4eb5-7bc0-b630-c8201fe63f41"
        static let third = "01a19149-69df-76a1-bdd5-039dcd49c425"
        let root: URL
        let project: URL
        let locks: URL
        let state: URL
        let history: URL
        let now = Date(timeIntervalSince1970: 1_793_438_800)
        var source: AgentSource { AgentSource(id: "codex", name: "Codex", configDirectory: root.path, assistant: .codex) }

        init() throws {
            root = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path))
            project = root.appendingPathComponent("project")
            locks = root.appendingPathComponent("thread-writer-locks")
            state = root.appendingPathComponent("state_5.sqlite")
            history = root.appendingPathComponent("thread_history_1.sqlite")
            try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try sql(state, "CREATE TABLE threads (id TEXT PRIMARY KEY, cwd TEXT, rollout_path TEXT, updated_at INTEGER)")
            try sql(history, "CREATE TABLE thread_turns (thread_id TEXT, rollout_ordinal INTEGER, status TEXT, started_at INTEGER, completed_at INTEGER)")
        }

        func session(_ id: String, status: String, began: TimeInterval, ended: TimeInterval? = nil,
                     rollout: String? = nil, project customProject: String? = nil) throws {
            let path = rollout ?? root.appendingPathComponent("sessions/rollout-2026-10-31T00-00-00-\(id).jsonl").path
            try sql(state, "INSERT INTO threads VALUES (\(quote(id)), \(quote(customProject ?? project.path)), \(quote(path)), \(Int(now.timeIntervalSince1970)))")
            try turn(id, ordinal: 1, status: status, began: began, ended: ended)
        }

        func turn(_ id: String, ordinal: Int, status: String, began: TimeInterval, ended: TimeInterval?) throws {
            let end = ended.map { String(Int(now.addingTimeInterval($0).timeIntervalSince1970)) } ?? "NULL"
            try sql(history, "INSERT INTO thread_turns VALUES (\(quote(id)), \(ordinal), \(quote(status)), \(Int(now.addingTimeInterval(began).timeIntervalSince1970)), \(end))")
        }

        func provider(owners: [String: Int32], verified: Bool = true) -> CodexLiveActivityProvider {
            CodexLiveActivityProvider(openSessionOwners: { directory in
                XCTAssertEqual(directory.path, self.locks.path)
                return owners
            }, serverStartedAt: { _ in verified ? self.now.addingTimeInterval(-1000) : nil })
        }

        private func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }

        private func sql(_ url: URL, _ text: String) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(url.path, &handle) == SQLITE_OK else { throw NSError(domain: "FixtureDB", code: 1) }
            defer { sqlite3_close(handle) }
            guard sqlite3_exec(handle, text, nil, nil, nil) == SQLITE_OK else { throw NSError(domain: "FixtureDB", code: 2) }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
