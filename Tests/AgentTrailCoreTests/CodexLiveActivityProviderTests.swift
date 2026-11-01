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
            serverStartedAt: { _ in fixture.now.addingTimeInterval(-1000) }, hostBundleIdentifier: { _ in nil })
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
            serverStartedAt: { _ in fixture.now.addingTimeInterval(-100000) }, hostBundleIdentifier: { _ in nil })
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

    func testLoadedThreadsCarryNameBranchParentAndOneHostLookupPerServer() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(Fixture.first, status: "inProgress", began: -60)
        try fixture.session(Fixture.second, status: "completed", began: -30, ended: -20)
        try fixture.details(Fixture.first, name: "  Tighten\nsync retries ", title: "Opening prompt",
                            branch: "feature/sync", source: "vscode")
        try fixture.details(Fixture.second, name: nil, title: "", branch: nil,
            source: #"{"subagent":{"thread_spawn":{"parent_thread_id":"\#(Fixture.first)","depth":1,"agent_role":null}}}"#)
        var asked: [Int32] = []
        let provider = CodexLiveActivityProvider(openSessionOwners: { _ in [Fixture.first: 101, Fixture.second: 101] },
            serverStartedAt: { _ in fixture.now.addingTimeInterval(-1000) },
            hostBundleIdentifier: { pid in
                asked.append(pid)
                return "com.openai.codex"
            })
        let sessions = provider.scan(sources: [fixture.source], now: fixture.now).sessions
        let parent = try XCTUnwrap(sessions.first { $0.sessionID == Fixture.first }?.details)
        XCTAssertEqual(parent.title, "Tighten sync retries")
        XCTAssertEqual(parent.branch, "feature/sync")
        XCTAssertNil(parent.parentThreadID)
        XCTAssertEqual(parent.hostBundleID, "com.openai.codex")
        let child = try XCTUnwrap(sessions.first { $0.sessionID == Fixture.second }?.details)
        XCTAssertNil(child.title)
        XCTAssertNil(child.branch)
        XCTAssertEqual(child.parentThreadID, Fixture.first)
        XCTAssertEqual(child.hostBundleID, "com.openai.codex")
        XCTAssertEqual(asked, [101])
    }

    func testUnnamedThreadFallsBackToItsTitleAsOneShortLine() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(Fixture.first, status: "inProgress", began: -10)
        try fixture.details(Fixture.first, name: " \n ", title: "Line one\n\tline two " + String(repeating: "x", count: 200),
                            branch: "HEAD", source: "{")
        let details = try XCTUnwrap(fixture.provider(owners: [Fixture.first: 101], host: nil)
            .scan(sources: [fixture.source], now: fixture.now).sessions.first?.details)
        let title = try XCTUnwrap(details.title)
        XCTAssertTrue(title.hasPrefix("Line one line two x"))
        XCTAssertEqual(title.count, 120)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertNil(details.branch)
        XCTAssertNil(details.parentThreadID)
        XCTAssertNil(details.hostBundleID)
    }

    func testOlderProjectionWithoutDetailColumnsKeepsTheSession() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(Fixture.first, status: "inProgress", began: -10)
        let snapshot = fixture.provider(owners: [Fixture.first: 101], host: nil)
            .scan(sources: [fixture.source], now: fixture.now)
        XCTAssertEqual(snapshot.sessions.map(\.status), [.working])
        XCTAssertEqual(snapshot.sessions.first?.details, LiveSessionDetails.none)
        XCTAssertTrue(snapshot.notices.isEmpty)
    }

    func testHostIsNeverLookedUpForAnUnverifiedServer() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session(Fixture.first, status: "inProgress", began: -10)
        let provider = CodexLiveActivityProvider(openSessionOwners: { _ in [Fixture.first: 101] },
            serverStartedAt: { _ in nil },
            hostBundleIdentifier: { _ in
                XCTFail("an unverified owner must not be resolved")
                return "com.openai.codex"
            })
        XCTAssertTrue(provider.scan(sources: [fixture.source], now: fixture.now).sessions.isEmpty)
    }

    func testParentThreadComesOnlyFromOneAgreeingUUIDInSourceJSON() {
        let parent = Fixture.first
        func parentOf(_ source: String?) -> String? {
            CodexLiveActivityProvider.parentThreadID(source: source, threadID: Fixture.second)
        }
        XCTAssertEqual(parentOf(#"{"subagent":{"thread_spawn":{"parent_thread_id":"\#(parent)","depth":1}}}"#), parent)
        XCTAssertEqual(parentOf(#"{"parent_thread_id":"\#(parent)","subagent":{"thread_spawn":{"parent_thread_id":"\#(parent)"}}}"#), parent)
        for source in [
            nil, "vscode", "{", "[1]", #""vscode""#,
            #"{"subagent":{"other":"guardian_review"}}"#,
            #"{"subagent":{"thread_spawn":{"parent_thread_id":"not-a-thread"}}}"#,
            #"{"subagent":{"thread_spawn":{"parent_thread_id":7}}}"#,
            #"{"subagent":{"thread_spawn":{"parent_thread_id":"\#(Fixture.second)"}}}"#,
            #"{"parent_thread_id":"\#(parent)","subagent":{"thread_spawn":{"parent_thread_id":"\#(Fixture.third)"}}}"#,
            #"{"parent_thread_id":"\#(parent)","subagent":{"thread_spawn":{"parent_thread_id":"\#(parent.uppercased())"}}}"#,
            #"{"a":{"b":{"c":{"d":{"e":{"parent_thread_id":"\#(parent)"}}}}}}"#
        ] { XCTAssertNil(parentOf(source), source ?? "nil") }
        XCTAssertNil(parentOf(#"{"subagent":{"thread_spawn":{"parent_thread_id":null}}}"#))
    }

    func testTitlesAndBranchesAreSingleLineAndBounded() {
        XCTAssertEqual(CodexLiveActivityProvider.displayTitle(" Fix\u{0007} the\r\nlogin  flow "), "Fix the login flow")
        XCTAssertNil(CodexLiveActivityProvider.displayTitle(" \n\t "))
        XCTAssertNil(CodexLiveActivityProvider.displayTitle(nil))
        XCTAssertEqual(CodexLiveActivityProvider.displayTitle(String(repeating: "a", count: 120))?.count, 120)
        XCTAssertEqual(CodexLiveActivityProvider.displayTitle(String(repeating: "a", count: 121))?.last, "…")
        XCTAssertEqual(CodexLiveActivityProvider.branchName(" codex/fix-sync\n"), "codex/fix-sync")
        for branch in [nil, "", "HEAD", "two words", "tab\tbranch", "bell\u{0007}", String(repeating: "b", count: 256)] {
            XCTAssertNil(CodexLiveActivityProvider.branchName(branch))
        }
    }

    func testHostAppIsTheBundleThatOwnsTheServerParentsExecutable() {
        let home = "/Users/example"
        let plists: [String: [String: Any]] = [
            "/Applications/ChatGPT.app/Contents/Info.plist":
                ["CFBundleIdentifier": "com.openai.codex", "CFBundleExecutable": "ChatGPT"],
            "/Applications/Visual Studio Code.app/Contents/Info.plist":
                ["CFBundleIdentifier": "com.microsoft.VSCode", "CFBundleExecutable": "Electron"],
            "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/Info.plist":
                ["CFBundleIdentifier": "com.microsoft.VSCode.helper", "CFBundleExecutable": "Code Helper (Plugin)"],
            "/Applications/Broken.app/Contents/Frameworks/Helper.app/Contents/Info.plist":
                ["CFBundleIdentifier": "com.example.broken.helper", "CFBundleExecutable": "Helper"],
            "/Applications/Odd.app/Contents/Info.plist":
                ["CFBundleIdentifier": "not a bundle id", "CFBundleExecutable": "Odd"],
            "\(home)/Applications/Tool.app/Contents/Info.plist":
                ["CFBundleIdentifier": "com.example.tool", "CFBundleExecutable": "Tool"],
            "\(home)/Documents/Build.app/Contents/Info.plist":
                ["CFBundleIdentifier": "com.example.build", "CFBundleExecutable": "Build"]
        ]
        func owner(_ path: String) -> String? {
            CodexLiveActivityProvider.applicationBundleIdentifier(executablePath: path, homeDirectory: home,
                infoPlist: { plists[$0.path] })
        }
        XCTAssertEqual(owner("/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"), "com.openai.codex")
        XCTAssertEqual(owner("/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"),
                       "com.microsoft.VSCode")
        XCTAssertEqual(owner("\(home)/Applications/Tool.app/Contents/MacOS/Tool"), "com.example.tool")
        for path in [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/ChatGPT.app/Contents/MacOS/Other",
            "/Applications/Broken.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper",
            "/Applications/Odd.app/Contents/MacOS/Odd",
            "/Applications/Missing.app/Contents/MacOS/Missing",
            "\(home)/Documents/Build.app/Contents/MacOS/Build",
            "/Applications/../\(home)/Documents/Build.app/Contents/MacOS/Build",
            "/bin/zsh",
            "/sbin/launchd",
            "relative/ChatGPT.app/Contents/MacOS/ChatGPT"
        ] { XCTAssertNil(owner(path), path) }
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

        /// Fixture PIDs are not real servers, so the host is never looked up.
        func provider(owners: [String: Int32], verified: Bool = true) -> CodexLiveActivityProvider {
            CodexLiveActivityProvider(openSessionOwners: { directory in
                XCTAssertEqual(directory.path, self.locks.path)
                return owners
            }, serverStartedAt: { _ in verified ? self.now.addingTimeInterval(-1000) : nil },
            hostBundleIdentifier: { _ in nil })
        }

        /// Never resolves a real process: the host answer is fixed by the test.
        func provider(owners: [String: Int32], host: String?) -> CodexLiveActivityProvider {
            CodexLiveActivityProvider(openSessionOwners: { _ in owners },
                serverStartedAt: { _ in self.now.addingTimeInterval(-1000) },
                hostBundleIdentifier: { _ in host })
        }

        private var detailed = false

        /// Newer projections add display columns; the base table is the older shape.
        /// Call after the session rows exist: `session` inserts the four base columns.
        func details(_ id: String, name: String?, title: String?, branch: String?, source: String?) throws {
            if !detailed {
                for column in ["name", "title", "git_branch", "source"] {
                    try sql(state, "ALTER TABLE threads ADD COLUMN \(column) TEXT")
                }
                detailed = true
            }
            func value(_ text: String?) -> String { text.map { quote($0) } ?? "NULL" }
            try sql(state, "UPDATE threads SET name = \(value(name)), title = \(value(title)), git_branch = \(value(branch)), source = \(value(source)) WHERE id = \(quote(id))")
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
