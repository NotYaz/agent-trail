import Foundation
import SQLite3
import XCTest
@testable import AgentTrailCore

/// Cursor 3.29 live status, as a live trace on 3.29.15 recorded it: sending a
/// message saves the chat with `unfinishedRunAt` (and `status` "aborted"); the
/// turn's end, Stop or quit saves it without; a question waiting for you is an
/// `ask_question` message whose `additionalData.status` is "pending", with the
/// header's `hasBlockingPendingActions` set; each turn's transcript ends with
/// `turn_ended`.
final class CursorLiveActivityProviderTests: XCTestCase {
    private var f: CursorFixture!
    private var writer: OpaquePointer?
    private var transcriptHome: URL!
    private let pid: Int32 = 44_383
    /// The Cursor app started at fixture second 100.
    private let appStart: TimeInterval = 100

    override func setUpWithError() throws {
        f = try CursorFixture()
        transcriptHome = f.root.appendingPathComponent("user-home/.cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: transcriptHome, withIntermediateDirectories: true)
        try f.headerTable([])
        // Cursor keeps the database open in WAL mode while it runs.
        XCTAssertEqual(sqlite3_open(f.database.path, &writer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL;", nil, nil, nil), SQLITE_OK)
    }

    override func tearDownWithError() throws {
        sqlite3_close(writer)
        f.remove()
    }

    private func micros(_ seconds: TimeInterval) -> UInt64 { UInt64(f.date(seconds).timeIntervalSince1970 * 1_000_000) }

    /// A Cursor app for the fixture's data folder, started at `appStart`.
    private func provider(apps: [CursorLiveActivityProvider.CursorApp]? = nil, alive: Bool = true) -> CursorLiveActivityProvider {
        let apps = apps ?? [.init(pid: pid, start: micros(appStart), userDataDirectory: f.userData.path)]
        let starts = Dictionary(uniqueKeysWithValues: apps.map { ($0.pid, $0.start) })
        return CursorLiveActivityProvider(processStartTimes: { pids in alive ? starts.filter { pids.contains($0.key) } : [:] },
                                          cursorApps: { apps }, transcriptHome: transcriptHome)
    }

    // Records, as Cursor 3.29 saves them.

    /// `type`: the subagent's `subagentTypeName` ("general-purpose" for a Task
    /// subagent, "side-chat" for a side chat); nil for a main chat.
    private func header(_ id: String, updated: TimeInterval?, blocking: Bool = false, subagent: Bool = false,
                        type: String? = nil) throws {
        var value = f.head(id, folder: f.project.path)
        value["hasBlockingPendingActions"] = blocking
        try f.insert("INSERT OR REPLACE INTO composerHeaders (composerId, workspaceId, lastUpdatedAt, isArchived, isSubagent, subagentTypeName, value) VALUES (?, NULL, ?, 0, ?, ?, ?)",
                     rows: [[id, updated.map { f.ms($0) }, subagent || type != nil ? 1 : 0, type ?? "", value]])
    }

    private func chat(_ id: String, updated: TimeInterval, running: TimeInterval? = nil, created: TimeInterval = 0,
                      extra: [String: Any] = [:]) throws {
        var fields: [String: Any] = ["_v": 18, "workspaceIdentifier": ["id": "w", "uri": f.uri(f.project.path)]]
        if let running {
            fields["unfinishedRunAt"] = f.ms(running)
            fields["status"] = "aborted"
        }
        for (key, value) in extra { fields[key] = value }
        try f.put([("composerData:\(id)", f.composer(id, bubbles: [], created: created, updated: updated, extra: fields))])
    }

    /// The chat's newest message: a header page entry and its body.
    private func last(_ id: String, bubble: String, started: TimeInterval, tool: String?, answer: String? = nil) throws {
        var body: [String: Any] = ["_v": 3, "type": 2, "bubbleId": bubble, "text": ""]
        if let tool {
            var former: [String: Any] = ["name": tool, "status": "completed"]
            if let answer { former["additionalData"] = ["status": answer] }
            body["toolFormerData"] = former
        }
        try f.put([("composerConvHeaders:\(id):000000", [["bubbleId": "u1", "type": 1],
                                                         ["bubbleId": bubble, "type": 2, "startedAtMs": f.ms(started)]]),
                   ("bubbleId:\(id):\(bubble)", body)])
    }

    @discardableResult
    private func transcript(_ id: String, ending: String, at seconds: TimeInterval) throws -> URL {
        let folder = transcriptHome.appendingPathComponent("projects/Users-someone-app/agent-transcripts/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(id).jsonl")
        let opening = "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"PRIVATE_PROMPT_MARKER\"}]}}"
        let lines = ending == "turn_ended" ? [opening, "{\"type\":\"turn_ended\",\"status\":\"success\"}"] : [opening]
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: f.date(seconds)], ofItemAtPath: file.path)
        return file
    }

    private func statuses(_ snapshot: LiveSnapshot) -> [String: LiveStatus] {
        Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.sessionID, $0.status) })
    }

    // Tests.

    func testARunSinceTheAppStartedIsWorking() throws {
        try header("c1", updated: 200)
        try chat("c1", updated: 200, running: 200)
        // Left by a Cursor that quit or crashed before this one started.
        try header("c2", updated: 50)
        try chat("c2", updated: 50, running: 50)
        // A subagent's run: its parent shows instead.
        try header("c3", updated: 200)
        try chat("c3", updated: 200, running: 200, extra: ["subagentInfo": ["parentComposerId": "c1"]])
        // Finished.
        try header("c4", updated: 210)
        try chat("c4", updated: 210)
        let snapshot = provider().scan(sources: [f.source])
        XCTAssertEqual(statuses(snapshot), ["c1": .working])
        let session = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(session.details.stateSince, f.date(200))
        XCTAssertEqual(session.projectPath, canonicalPath(f.project.path))
        XCTAssertEqual(session.pid, pid)
        XCTAssertEqual(session.details.hostBundleID, "com.todesktop.230313mzl4w4u92")
    }

    func testAPendingQuestionNeedsInputUntilItIsAnswered() throws {
        try header("c1", updated: 300, blocking: true)
        try chat("c1", updated: 300)
        try last("c1", bubble: "q1", started: 305, tool: "ask_question", answer: "pending")
        let reader = provider()
        var snapshot = reader.scan(sources: [f.source])
        XCTAssertEqual(statuses(snapshot), ["c1": .waiting])
        XCTAssertEqual(snapshot.sessions.first?.details.stateSince, f.date(305))
        // Answered: the agent goes on.
        try header("c1", updated: 300)
        try chat("c1", updated: 300, running: 320)
        try last("c1", bubble: "q1", started: 305, tool: "ask_question", answer: "submitted")
        snapshot = reader.scan(sources: [f.source])
        XCTAssertEqual(statuses(snapshot), ["c1": .working])
        XCTAssertEqual(snapshot.sessions.first?.details.stateSince, f.date(320))
    }

    func testABlockedChatNeedsInputFromWhenItWasFirstSeen() throws {
        try header("c1", updated: 300, blocking: true)
        try chat("c1", updated: 300, running: 300)
        let reader = provider()
        let first = Date()
        XCTAssertEqual(reader.scan(sources: [f.source], now: first).sessions.first?.status, .waiting)
        let again = reader.scan(sources: [f.source], now: first.addingTimeInterval(9))
        XCTAssertEqual(again.sessions.first?.details.stateSince, first)
        // An old flag from before this app started claims nothing.
        try header("c1", updated: 50, blocking: true)
        try chat("c1", updated: 50)
        XCTAssertEqual(reader.scan(sources: [f.source]).sessions, [])
    }

    /// A subagent waiting for approval, as traced on 3.29.15: Cursor copies the
    /// subagent's blocked flag to its parent's header, so the parent shows
    /// Needs input. The subagent itself (its header has no `lastUpdatedAt`,
    /// its transcript sits in the parent's `subagents` folder) never shows.
    func testASubagentsApprovalShowsAsNeedsInputOnItsParent() throws {
        try header("p1", updated: 300, blocking: true)
        try chat("p1", updated: 300, running: 300)
        try last("p1", bubble: "t1", started: 302, tool: "task_v2", answer: "loading")
        try header("s1", updated: nil, blocking: true, subagent: true)
        try chat("s1", updated: 303, running: 303, extra: ["subagentInfo": ["parentComposerId": "p1", "rootParentConversationId": "p1"]])
        try last("s1", bubble: "x1", started: 309, tool: "run_terminal_command_v2", answer: "pending")
        let folder = transcriptHome.appendingPathComponent("projects/Users-someone-app/agent-transcripts/p1/subagents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "{\"role\":\"user\"}\n".write(to: folder.appendingPathComponent("s1.jsonl"), atomically: true, encoding: .utf8)
        let reader = provider()
        XCTAssertEqual(statuses(reader.scan(sources: [f.source])), ["p1": .waiting])
        // Allowed: both flags clear, and the parent works on.
        try header("p1", updated: 300)
        try header("s1", updated: nil, subagent: true)
        XCTAssertEqual(statuses(reader.scan(sources: [f.source])), ["p1": .working])
    }

    /// A side chat, as traced on 3.29.15: its header row is a subagent's
    /// (`isSubagent` 1, type "side-chat") but carries `lastUpdatedAt`, its run
    /// marker and blocked flag are its own, and its parent isn't flagged. It
    /// shows on its own, and Jump goes through its parent.
    func testASideChatShowsOnItsOwn() throws {
        let side: [String: Any] = ["parentComposerId": "p1", "subagentType": 0, "subagentTypeName": "side-chat"]
        try header("p1", updated: 300)
        try chat("p1", updated: 300)
        try header("s1", updated: 320, type: "side-chat")
        try chat("s1", updated: 320, running: 320, extra: ["subagentInfo": side])
        // A Task subagent running beside it still shows through its parent only,
        // even when a transcript of its own makes it a candidate.
        try header("t1", updated: nil, type: "general-purpose")
        try chat("t1", updated: 322, running: 322, extra: ["subagentInfo": ["parentComposerId": "p1", "subagentTypeName": "general-purpose"]])
        try transcript("t1", ending: "message", at: 323)
        let reader = provider()
        var snapshot = reader.scan(sources: [f.source])
        XCTAssertEqual(statuses(snapshot), ["s1": .working])
        XCTAssertEqual(snapshot.sessions.first?.details.parentThreadID, "p1")
        XCTAssertEqual(snapshot.sessions.first?.details.stateSince, f.date(320))
        // Its approval flags only the side chat.
        try header("s1", updated: 320, blocking: true, type: "side-chat")
        snapshot = reader.scan(sources: [f.source])
        XCTAssertEqual(statuses(snapshot), ["s1": .waiting])
        XCTAssertEqual(snapshot.sessions.first?.details.parentThreadID, "p1")
    }

    /// A subagent sent to the background, as traced on 3.29.15: the parent's
    /// turn ends (no run marker) while the task's page entry reads
    /// `grouping.taskStatus` "running"; when the subagent ends it reads
    /// "success" and the parent wakes for a turn of its own.
    private func task(_ status: String, started: TimeInterval) -> [String: Any] {
        ["bubbleId": "t\(Int(started))", "type": 2, "startedAtMs": f.ms(started), "completedAtMs": f.ms(started + 1),
         "grouping": ["toolCallCase": "taskToolCall", "toolFormerStatus": "loading", "taskStatus": status]]
    }

    private func message(_ bubble: String, at seconds: TimeInterval) -> [String: Any] {
        ["bubbleId": bubble, "type": 2, "startedAtMs": f.ms(seconds)]
    }

    private func pages(_ id: String, _ pages: [[[String: Any]]]) throws {
        try f.put(pages.enumerated().map { ("composerConvHeaders:\(id):" + String(format: "%06d", $0.offset), $0.element) })
    }

    func testABackgroundSubagentKeepsItsParentWorking() throws {
        try header("p1", updated: 300)
        try chat("p1", updated: 300)
        try pages("p1", [[message("u1", at: 300), task("running", started: 305), message("a1", at: 307)]])
        let reader = provider()
        let snapshot = reader.scan(sources: [f.source])
        XCTAssertEqual(statuses(snapshot), ["p1": .working])
        XCTAssertEqual(snapshot.sessions.first?.details.backgroundSince, f.date(305))
        XCTAssertEqual(snapshot.sessions.first?.details.stateSince, f.date(305))
        // The subagent ended.
        try pages("p1", [[message("u1", at: 300), task("success", started: 305), message("a1", at: 307)]])
        XCTAssertEqual(reader.scan(sources: [f.source]).sessions, [])
        // A task left running by a Cursor that quit before this one started claims nothing.
        try pages("p1", [[message("u0", at: 40), task("running", started: 50), message("a1", at: 52)]])
        XCTAssertEqual(reader.scan(sources: [f.source]).sessions, [])
    }

    /// Pages hold 256 messages; a task still running on an earlier page counts
    /// while that page was written since the app started.
    func testABackgroundSubagentOnAnEarlierPageStillCounts() throws {
        try header("p1", updated: 400)
        try chat("p1", updated: 400)
        try pages("p1", [[message("u1", at: 300), task("running", started: 305)],
                         [message("u2", at: 400), message("a2", at: 402)]])
        let snapshot = provider().scan(sources: [f.source])
        XCTAssertEqual(statuses(snapshot), ["p1": .working])
        XCTAssertEqual(snapshot.sessions.first?.details.backgroundSince, f.date(305))
    }

    /// A fork copies its original's page entries, and nothing updates the
    /// copy: a running task from before the chat was created doesn't count.
    func testAForkedCopyOfARunningTaskDoesNotCount() throws {
        try header("f1", updated: 330)
        try chat("f1", updated: 330, created: 320)
        try pages("f1", [[message("u1", at: 300), task("running", started: 305), message("u2", at: 330)]])
        XCTAssertEqual(provider().scan(sources: [f.source]).sessions, [])
    }

    /// A run of its own comes first; once a transcript ends that run, the
    /// background subagent still keeps the chat Working in background.
    func testARunComesBeforeABackgroundSubagent() throws {
        try header("p1", updated: 300)
        try chat("p1", updated: 300, running: 310)
        try pages("p1", [[message("u1", at: 300), task("running", started: 305), message("u2", at: 310)]])
        let reader = provider()
        var snapshot = reader.scan(sources: [f.source])
        XCTAssertEqual(statuses(snapshot), ["p1": .working])
        XCTAssertNil(snapshot.sessions.first?.details.backgroundSince)
        XCTAssertEqual(snapshot.sessions.first?.details.stateSince, f.date(310))
        try transcript("p1", ending: "turn_ended", at: 320)
        snapshot = reader.scan(sources: [f.source])
        XCTAssertEqual(statuses(snapshot), ["p1": .working])
        XCTAssertEqual(snapshot.sessions.first?.details.backgroundSince, f.date(305))
    }

    func testATurnEndedInTheTranscriptEndsTheRun() throws {
        try header("c1", updated: 300)
        try chat("c1", updated: 300, running: 300)
        try transcript("c1", ending: "turn_ended", at: 310)
        XCTAssertEqual(provider().scan(sources: [f.source]).sessions, [])
        // A turn_ended from before this run doesn't end it.
        try transcript("c1", ending: "turn_ended", at: 290)
        XCTAssertEqual(statuses(provider().scan(sources: [f.source])), ["c1": .working])
    }

    /// The previous turn's end line can land just after you send again; it
    /// doesn't hide the new run.
    func testATurnEndedRightAfterASendDoesNotHideTheNewRun() throws {
        try header("c1", updated: 300)
        try chat("c1", updated: 300, running: 300)
        try transcript("c1", ending: "turn_ended", at: 301)
        XCTAssertEqual(statuses(provider().scan(sources: [f.source])), ["c1": .working])
    }

    func testCloudAndBackgroundAgentChatsAreNotShown() throws {
        try header("b1", updated: 300)
        try chat("b1", updated: 300, running: 300, extra: ["createdFromBackgroundAgent": ["bcId": "bc-1"]])
        try header("b2", updated: 300)
        try chat("b2", updated: 300, running: 300, extra: ["createdFromBackgroundAgent": [:]])
        XCTAssertEqual(statuses(provider().scan(sources: [f.source])), ["b2": .working], "an empty marker is a local chat")
    }

    /// A rollback-journal database with stray -wal and -shm files is not read;
    /// the journal mode comes from SQLite, not from a file handle of ours.
    func testOnlyAWALDatabaseIsRead() throws {
        try header("c1", updated: 300)
        try chat("c1", updated: 300, running: 300)
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=DELETE;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(writer)
        writer = nil
        FileManager.default.createFile(atPath: f.database.path + "-wal", contents: Data())
        FileManager.default.createFile(atPath: f.database.path + "-shm", contents: Data())
        guard case .unavailable = CursorLiveActivityProvider.readStates(f.database, since: 0, extra: []) else {
            return XCTFail("a rollback-journal database must not be read")
        }
    }

    func testAChatWhoseHeaderIsBehindIsFoundThroughItsTranscript() throws {
        try header("c1", updated: nil)
        try chat("c1", updated: 300, running: 300)
        try transcript("c1", ending: "message", at: 303)
        XCTAssertEqual(statuses(provider().scan(sources: [f.source])), ["c1": .working])
    }

    func testWithoutTheDatabaseATranscriptKeepsAKnownChatWorking() throws {
        try header("c1", updated: 300)
        try chat("c1", updated: 300, running: 300)
        try transcript("c1", ending: "message", at: 303)
        try transcript("c2", ending: "message", at: 303)
        let reader = provider()
        XCTAssertEqual(statuses(reader.scan(sources: [f.source])), ["c1": .working])
        // Cursor's database can't be read now (its WAL files are gone).
        sqlite3_close(writer)
        writer = nil
        try? FileManager.default.removeItem(atPath: f.database.path + "-wal")
        try? FileManager.default.removeItem(atPath: f.database.path + "-shm")
        let snapshot = reader.scan(sources: [f.source])
        XCTAssertEqual(statuses(snapshot), ["c1": .working], "c2's folder was never known")
        XCTAssertEqual(snapshot.sessions.first?.details.stateSince, f.date(303))
        XCTAssertNil(FileStat.of(f.database.path + "-shm"), "no file is created in Cursor's folder")
    }

    func testRemoteAndMultiRootWorkspacesAreNotShown() throws {
        for id in ["r1", "m1", "p1"] { try header(id, updated: 300) }
        try chat("r1", updated: 300, running: 300, extra: [
            "workspaceIdentifier": ["id": "z", "uri": ["scheme": "vscode-remote", "path": "/srv/app"]],
            "trackedGitRepos": [["repoPath": "/srv/app"]]])
        try chat("m1", updated: 300, running: 300, extra: [
            "workspaceIdentifier": ["id": "w", "configPath": ["scheme": "file", "fsPath": "/Users/someone/both.code-workspace"]],
            "trackedGitRepos": [["repoPath": f.project.path]]])
        // A file URI saved without fsPath still names its folder.
        try chat("p1", updated: 300, running: 300, extra: [
            "workspaceIdentifier": ["id": "y", "uri": ["scheme": "file", "path": f.project.path]]])
        XCTAssertEqual(statuses(provider().scan(sources: [f.source])), ["p1": .working])
    }

    func testOnlyARunningCursorForTheProfilesDataFolderCounts() throws {
        try header("c1", updated: 300)
        try chat("c1", updated: 300, running: 300)
        XCTAssertEqual(provider(apps: []).scan(sources: [f.source]).sessions, [])
        let other = CursorLiveActivityProvider.CursorApp(pid: pid, start: micros(appStart), userDataDirectory: "/tmp/elsewhere")
        XCTAssertEqual(provider(apps: [other]).scan(sources: [f.source]).sessions, [])
        // Gone (or its PID reused) by the time the database was read.
        XCTAssertEqual(provider(alive: false).scan(sources: [f.source]).sessions, [])
        // Started after this run: the run was left by an earlier Cursor.
        let later = CursorLiveActivityProvider.CursorApp(pid: pid, start: micros(400), userDataDirectory: f.userData.path)
        XCTAssertEqual(provider(apps: [later]).scan(sources: [f.source]).sessions, [])
    }

    func testTheInstanceMustUseTheProfilesDataFolder() {
        let custom = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Cursor-Work", isDirectory: true)
        let standard = URL(fileURLWithPath: ("~/Library/Application Support/Cursor" as NSString).expandingTildeInPath, isDirectory: true)
        let plain = CursorLiveActivityProvider.CursorApp(pid: 10, start: 200, userDataDirectory: nil)
        let older = CursorLiveActivityProvider.CursorApp(pid: 11, start: 100, userDataDirectory: nil)
        let work = CursorLiveActivityProvider.CursorApp(pid: 12, start: 50, userDataDirectory: custom.path)
        XCTAssertEqual(CursorLiveActivityProvider.instance(for: standard, among: [plain, older, work])?.pid, 11)
        XCTAssertEqual(CursorLiveActivityProvider.instance(for: custom, among: [plain, older, work])?.pid, 12)
        XCTAssertNil(CursorLiveActivityProvider.instance(for: custom, among: [plain, older]))
    }

    func testTheLastLineIsFoundFromItsOpeningBytes() throws {
        let file = transcriptHome.appendingPathComponent("line.jsonl")
        func kind(_ raw: String) throws -> CursorLiveActivityProvider.LastLine {
            try raw.write(to: file, atomically: true, encoding: .utf8)
            return CursorLiveActivityProvider.lastLine(of: file, size: UInt64(try Data(contentsOf: file).count))
        }
        let end = "{\"type\":\"turn_ended\",\"status\":\"success\"}"
        let message = "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"PRIVATE\"}]}}"
        XCTAssertEqual(try kind(message), .message, "a file of one line")
        XCTAssertEqual(try kind(end + "\n" + message + "\n\n"), .message, "trailing newlines")
        XCTAssertEqual(try kind(message + "\r\n" + end + "\r\n"), .turnEnded)
        XCTAssertEqual(try kind(message + "\n{\"type\":\"turn_ended\",\"status\":\"aborted\"}\n"), .turnEnded)
        // A prompt longer than one read chunk still opens with its role.
        let long = "{\"role\":\"user\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"" + String(repeating: "x", count: 200_000) + "\"}]}}"
        XCTAssertEqual(try kind(end + "\n" + long + "\n"), .message)
        // A kind this version does not know never claims a running turn.
        XCTAssertEqual(try kind(message + "\n{\"type\":\"turn_paused\"}\n"), .other)
        XCTAssertEqual(try kind("\n\n"), .other)
    }
}
