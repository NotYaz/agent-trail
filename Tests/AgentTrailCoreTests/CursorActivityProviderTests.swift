import Foundation
import SQLite3
import XCTest
@testable import AgentTrailCore

final class CursorActivityProviderTests: XCTestCase {
    // MARK: Cursor app

    func testCompletedEditWithContentIDsCountsAtItsBubbleTime() throws {
        let f = try CursorFixture()
        defer { f.remove() }
        let file = f.project.appendingPathComponent("Sources/App.swift").path
        try f.put([
            ("composerData:c1", f.composer("c1", bubbles: ["u1", "t1", "a1"], created: 0, updated: 40)),
            ("bubbleId:c1:u1", f.userBubble("u1", at: 10)),
            ("bubbleId:c1:t1", f.tool("t1", name: "edit_file_v2", call: "tool_1", path: file, at: 20, result: f.applied())),
            ("bubbleId:c1:a1", f.textBubble("a1", at: 30))
        ])
        try f.headerTable([("c1", nil, f.head("c1", folder: f.project.path))])
        let result = f.provider().scan(sources: [f.source])
        let project = try XCTUnwrap(result.projects.first { $0.path == canonicalPath(f.project.path) })
        XCTAssertEqual(project.recordedEditCount, 1)
        XCTAssertEqual(project.sessionCount, 1)
        XCTAssertEqual(project.activities.first?.editMoments.map(\.date), [f.date(20)])
        XCTAssertEqual(result.sessionTrails.first?.sessionID, "c1")
        XCTAssertEqual(result.sessionTrails.first?.createdAt, f.date(10), "a chat starts at its first message")
        XCTAssertEqual(result.notices, [])
    }

    func testOnlyCompletedCallsWithASuccessArtifactCount() throws {
        let f = try CursorFixture()
        defer { f.remove() }
        func path(_ name: String) -> String { f.project.appendingPathComponent(name).path }
        let created = path("created.txt")
        try f.put([
            ("composerData:c1", f.composer("c1", bubbles: ["u1"] + (1...12).map { "t\($0)" }, created: 0, updated: 90,
                                           extra: ["newlyCreatedFiles": [["uri": f.uri(created)]]])),
            ("bubbleId:c1:u1", f.userBubble("u1", at: 1)),
            // Counted: a 3.x content id, a confirmed delete, a created file the chat lists.
            ("bubbleId:c1:t1", f.tool("t1", name: "edit_file_v2", call: "tool_1", path: path("a.txt"), at: 10, result: f.applied())),
            ("bubbleId:c1:t2", f.tool("t2", name: "delete_file", call: "tool_2", path: path("gone.txt"), at: 11,
                                      result: ["fileDeletedSuccessfully": true])),
            ("bubbleId:c1:t3", f.tool("t3", name: "edit_file_v2", call: "tool_3", path: created, at: 12, result: [:])),
            // Not counted.
            ("bubbleId:c1:t4", f.tool("t4", name: "edit_file_v2", status: "error", call: "tool_4", path: path("b.txt"), at: 13, result: nil)),
            ("bubbleId:c1:t5", f.tool("t5", name: "edit_file_v2", status: "cancelled", call: "tool_5", path: path("c.txt"), at: 14,
                                      result: nil)),
            ("bubbleId:c1:t6", f.tool("t6", name: "edit_file_v2", call: "tool_6", path: path("d.txt"), at: 15, result: [:])),
            ("bubbleId:c1:t7", f.tool("t7", name: "edit_file_v2", call: "tool_7", path: path("e.txt"), at: 16, result: f.applied(),
                                      former: ["userDecision": "rejected"])),
            ("bubbleId:c1:t8", f.tool("t8", name: "edit_file_v2", call: "tool_8", path: path("f.txt"), at: 17, result: f.applied(),
                                      params: ["cloudAgentEdit": true])),
            ("bubbleId:c1:t9", f.tool("t9", name: "run_terminal_command_v2", call: "tool_9", path: nil, at: 18,
                                      result: ["output": "PRIVATE_CONTENT_MARKER", "exitCode": 0], params: ["command": "touch g.txt"])),
            // An agent-backend delete stores an empty result: no proof.
            ("bubbleId:c1:t10", f.tool("t10", name: "delete_file", call: "tool_10", path: path("h.txt"), at: 19, result: [:])),
            ("bubbleId:c1:t11", f.tool("t11", name: "edit_file_v2", call: "tool_11", path: path("i.txt"), at: 20,
                                       result: ["rejected": true])),
            // The nameless form Cursor leaves after some errors.
            ("bubbleId:c1:t12", ["_v": 3, "type": 2, "createdAt": f.iso(21),
                                 "toolFormerData": ["additionalData": ["status": "error"]]] as [String: Any])
        ])
        try f.headerTable([("c1", nil, f.head("c1", folder: f.project.path))])
        let result = f.provider().scan(sources: [f.source])
        let project = try XCTUnwrap(result.projects.first)
        XCTAssertEqual(project.recordedEditCount, 3)
        XCTAssertEqual(project.activities.first?.editMoments.map(\.date), [f.date(10), f.date(11), f.date(12)])
        XCTAssertEqual(result.notices, [])
    }

    func testFilesOutsideTheWorkspaceDoNotCountAndRelativePathsResolveInIt() throws {
        let f = try CursorFixture()
        defer { f.remove() }
        let outside = f.root.appendingPathComponent("outside/x.txt").path
        try f.put([
            ("composerData:c1", f.composer("c1", bubbles: ["t1", "t2"], created: 0, updated: 30)),
            ("bubbleId:c1:t1", f.tool("t1", name: "edit_file_v2", call: "tool_1", path: outside, at: 10, result: f.applied())),
            ("bubbleId:c1:t2", f.tool("t2", name: "edit_file_v2", call: "tool_2", path: "Sources/rel.swift", at: 20, result: f.applied()))
        ])
        try f.headerTable([("c1", nil, f.head("c1", folder: f.project.path))])
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects.map(\.path), [canonicalPath(f.project.path)])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 1)
        XCTAssertEqual(result.projects.first?.activities.first?.editMoments.map(\.date), [f.date(20)])
    }

    func testCacheKeepsNoContentAndSurvivesReload() throws {
        let f = try CursorFixture()
        defer { f.remove() }
        let file = f.project.appendingPathComponent("a.txt").path
        try f.put([
            ("composerData:c1", f.composer("c1", bubbles: ["u1", "t1"], created: 0, updated: 30)),
            ("bubbleId:c1:u1", f.userBubble("u1", at: 10)),
            // Cursor 2.x parameters carry the whole new file.
            ("bubbleId:c1:t1", f.tool("t1", name: "edit_file_v2", call: "tool_1", path: file, at: 20, result: f.applied(),
                                      params: ["contentsAfterEdit": "PRIVATE_CONTENT_MARKER"]))
        ])
        try f.headerTable([("c1", nil, f.head("c1", folder: f.project.path))])
        let provider = f.provider()
        XCTAssertEqual(provider.scan(sources: [f.source]).projects.first?.recordedEditCount, 1)
        XCTAssertNil(provider.saveCache())
        let saved = try String(contentsOf: f.cache, encoding: .utf8)
        for marker in ["PRIVATE_PROMPT_MARKER", "PRIVATE_CONTENT_MARKER", "PRIVATE_TITLE_MARKER"] {
            XCTAssertFalse(saved.contains(marker), marker)
        }
        let reloaded = f.provider()
        XCTAssertEqual(reloaded.metadata(sources: [f.source]).projects.first?.recordedEditCount, 1)
        XCTAssertEqual(reloaded.scan(sources: [f.source]).projects.first?.recordedEditCount, 1)
    }

    func testIncrementalRescanFollowsAppendsCompletionsAndRewrites() throws {
        let f = try CursorFixture()
        defer { f.remove() }
        func path(_ name: String) -> String { f.project.appendingPathComponent(name).path }
        try f.headerTable([("c1", nil, f.head("c1", folder: f.project.path))])
        try f.put([
            ("composerData:c1", f.composer("c1", bubbles: ["u1", "t1", "t2"], created: 0, updated: 20)),
            ("bubbleId:c1:u1", f.userBubble("u1", at: 1)),
            ("bubbleId:c1:t1", f.tool("t1", name: "edit_file_v2", call: "tool_1", path: path("a.txt"), at: 10, result: f.applied())),
            // Still running when Cursor flushed the chat.
            ("bubbleId:c1:t2", f.tool("t2", name: "edit_file_v2", status: "loading", call: "tool_2", path: path("b.txt"), at: 20,
                                      result: nil))
        ])
        let provider = f.provider()
        XCTAssertEqual(provider.scan(sources: [f.source]).projects.first?.recordedEditCount, 1)

        // The call completes and the chat gains another edit.
        try f.put([
            ("composerData:c1", f.composer("c1", bubbles: ["u1", "t1", "t2", "t3"], created: 0, updated: 40)),
            ("bubbleId:c1:t2", f.tool("t2", name: "edit_file_v2", call: "tool_2", path: path("b.txt"), at: 20, result: f.applied())),
            ("bubbleId:c1:t3", f.tool("t3", name: "edit_file_v2", call: "tool_3", path: path("c.txt"), at: 30, result: f.applied()))
        ])
        var result = provider.scan(sources: [f.source])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 3)
        XCTAssertEqual(result.projects.first?.activities.first?.editMoments.map(\.date), [f.date(10), f.date(20), f.date(30)])

        // Restoring a checkpoint rewrites the list; the dropped bubbles' rows stay behind.
        try f.put([("composerData:c1", f.composer("c1", bubbles: ["u1", "t1"], created: 0, updated: 50))])
        result = provider.scan(sources: [f.source])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 1)
        XCTAssertNil(provider.saveCache())
        XCTAssertEqual(f.provider().scan(sources: [f.source]).projects.first?.recordedEditCount, 1)
    }

    func testMissingStoresGiveOneNotice() throws {
        let f = try CursorFixture()
        defer { f.remove() }
        let source = AgentSource(id: "cursor", name: "Cursor", configDirectory: f.root.appendingPathComponent("none").path,
                                 userDataDirectory: f.root.appendingPathComponent("no-cursor").path, assistant: .cursor)
        XCTAssertEqual(f.provider().scan(sources: [source]).notices, ["Cursor: no local Cursor chat history was found."])
    }

    func testCopiesOfOneCallInForkedChatsCountOnce() throws {
        let f = try CursorFixture()
        defer { f.remove() }
        let file = f.project.appendingPathComponent("a.txt").path
        let edit = f.tool("t1", name: "edit_file_v2", call: "tool_same", path: file, at: 10, result: f.applied())
        try f.put([
            ("composerData:c1", f.composer("c1", bubbles: ["t1"], created: 0, updated: 20)),
            ("composerData:c2", f.composer("c2", bubbles: ["t1"], created: 5, updated: 20)),
            ("bubbleId:c1:t1", edit),
            ("bubbleId:c2:t1", edit)
        ])
        try f.headerTable([("c1", nil, f.head("c1", folder: f.project.path)), ("c2", nil, f.head("c2", folder: f.project.path))])
        let project = try XCTUnwrap(f.provider().scan(sources: [f.source]).projects.first)
        XCTAssertEqual(project.recordedEditCount, 1)
        XCTAssertEqual(project.sessionCount, 2)
    }

    func testOnlyBubblesTheChatListsAreRead() throws {
        let f = try CursorFixture()
        defer { f.remove() }
        let file = f.project.appendingPathComponent("a.txt").path
        try f.put([
            ("composerData:c1", f.composer("c1", bubbles: ["u1"], created: 0, updated: 20)),
            ("bubbleId:c1:u1", f.userBubble("u1", at: 1)),
            // A row in the chat's key range that its list does not name (a fork's leftover).
            ("bubbleId:c1:t9", f.tool("t9", name: "edit_file_v2", call: "tool_9", path: file, at: 10, result: f.applied()))
        ])
        try f.headerTable([("c1", nil, f.head("c1", folder: f.project.path))])
        let project = try XCTUnwrap(f.provider().scan(sources: [f.source]).projects.first)
        XCTAssertEqual(project.recordedEditCount, 0)
        XCTAssertEqual(project.sessionCount, 1)
    }

    func testWorkspaceComesFromHeadersReposStorageAndLegacyDatabases() throws {
        let f = try CursorFixture()
        defer { f.remove() }
        let folders = ["a", "b", "c", "d"].map { f.root.appendingPathComponent("folder-\($0)", isDirectory: true) }
        for folder in folders { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let ids = (1...8).map { "c\($0)" }
        var rows: [(String, Any?)] = []
        for (offset, id) in ids.enumerated() {
            var extra: [String: Any] = [:]
            switch id {
            case "c2":
                extra["trackedGitRepos"] = [["repoPath": folders[1].path, "branches": [String]()]] as [[String: Any]]
            case "c5":
                extra["workspaceIdentifier"] = ["id": "empty-window"]
            case "c7":
                extra["createdFromBackgroundAgent"] = ["bcId": "bc-1"]
                extra["workspaceIdentifier"] = ["id": "w7", "uri": f.uri(folders[0].path)] as [String: Any]
            default:
                break
            }
            rows.append(("composerData:\(id)", f.composer(id, bubbles: ["u1"], created: Double(offset), updated: 50, extra: extra)))
            rows.append(("bubbleId:\(id):u1", f.userBubble("u1", at: Double(10 + offset))))
        }
        try f.put(rows)
        // c1: the header names a workspace folder; c4: a remote window.
        try f.workspace("ws1", folder: folders[0].path)
        try f.headerTable([
            ("c1", "ws1", ["type": "head", "composerId": "c1"]),
            ("c4", "remote1", ["type": "head", "composerId": "c4", "workspaceIdentifier": ["id": "remote1",
                "uri": ["$mid": 1, "scheme": "vscode-remote", "authority": "ssh-remote+box", "path": "/home/me/p", "fsPath": "/home/me/p"]]])
        ])
        // c3: a pre-3.0 chat, listed by its workspace's database.
        try f.legacyWorkspace("legacyhash", folder: folders[2].path, composers: ["c3"])
        // c8: Cursor 3.0's header list in ItemTable.
        let list: [String: Any] = ["allComposers": [["type": "head", "composerId": "c8",
            "workspaceIdentifier": ["id": "w8", "uri": f.uri(folders[3].path)] as [String: Any]] as [String: Any]]]
        try f.put([("composer.composerHeaders", list)], table: "ItemTable")
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(Set(result.projects.map(\.path)), Set(folders.map { canonicalPath($0.path) }))
        XCTAssertEqual(result.projects.map(\.sessionCount), [1, 1, 1, 1])
        // c5 has no folder and c7 ran in the cloud: skipped quietly. c6 records nothing.
        XCTAssertEqual(result.notices, ["Cursor: 1 Cursor chat(s) record no workspace folder; they are not counted."])
    }

    func testWorktreeChatEditsLandInTheWorktree() throws {
        let f = try CursorFixture()
        defer { f.remove() }
        let worktree = f.root.appendingPathComponent("worktrees/project/w1", isDirectory: true)
        try f.git(f.project)
        try f.git(worktree)
        // The agent names the file under the window's folder; Cursor writes it in the worktree.
        let named = f.project.appendingPathComponent("Sources/A.swift").path
        try f.put([
            ("composerData:c1", f.composer("c1", bubbles: ["t1"], created: 0, updated: 20,
                extra: ["gitWorktree": ["worktreePath": worktree.path, "branchName": "w1", "commitHash": "abc"]])),
            ("bubbleId:c1:t1", f.tool("t1", name: "edit_file_v2", call: "tool_1", path: named, at: 10, result: f.applied()))
        ])
        try f.headerTable([("c1", nil, f.head("c1", folder: f.project.path))])
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects.first { $0.path == canonicalPath(worktree.path) }?.recordedEditCount, 1)
        XCTAssertEqual(result.projects.first { $0.path == canonicalPath(f.project.path) }?.recordedEditCount, 0)
        XCTAssertEqual(CursorActivityProvider.target("Sources/B.swift", roots: [f.project.path], worktree: worktree.path),
                       worktree.appendingPathComponent("Sources/B.swift").path)
        XCTAssertEqual(CursorActivityProvider.target(worktree.appendingPathComponent("x").path, roots: [f.project.path],
                                                      worktree: worktree.path), worktree.appendingPathComponent("x").path)
        XCTAssertNil(CursorActivityProvider.target("~/x", roots: [f.project.path], worktree: nil))
    }

    func testCursor2CodeBlockProofCountsAtItsApplyTimeUnlessRejected() throws {
        let f = try CursorFixture()
        defer { f.remove() }
        let kept = f.project.appendingPathComponent("kept.txt").path
        let undone = f.project.appendingPathComponent("undone.txt").path
        let never = f.project.appendingPathComponent("never.txt").path
        func block(_ id: String) -> [String: Any] { ["codeBlocks": [["codeblockId": id, "content": "PRIVATE_CONTENT_MARKER"]]] }
        try f.put([
            ("composerData:c1", f.composer("c1", bubbles: ["t1", "t2", "t3"], created: 0, updated: 90, extra: ["codeBlockData": [
                URL(fileURLWithPath: kept).absoluteString: ["blk1": ["diffId": "d1", "lastAppliedAt": f.ms(50), "status": "accepted",
                                                                     "content": "PRIVATE_CONTENT_MARKER"]],
                URL(fileURLWithPath: undone).absoluteString: ["blk2": ["diffId": "d2", "lastAppliedAt": f.ms(60), "status": "rejected"]]
            ]])),
            // Cursor 2.x leaves an empty result and no time on the bubble.
            ("bubbleId:c1:t1", f.tool("t1", name: "edit_file_v2", call: "tool_1", path: kept, at: nil, result: [:], extra: block("blk1"))),
            ("bubbleId:c1:t2", f.tool("t2", name: "edit_file_v2", call: "tool_2", path: undone, at: nil, result: [:], extra: block("blk2"))),
            ("bubbleId:c1:t3", f.tool("t3", name: "edit_file_v2", call: "tool_3", path: never, at: nil, result: [:], extra: block("blk3")))
        ])
        try f.headerTable([("c1", nil, f.head("c1", folder: f.project.path))])
        let result = f.provider().scan(sources: [f.source])
        let project = try XCTUnwrap(result.projects.first)
        XCTAssertEqual(project.recordedEditCount, 1)
        XCTAssertEqual(project.activities.first?.editMoments.map(\.date), [f.date(50)])
    }

    func testBubbleWithoutTimeUsesTheNearestEarlierBubble() throws {
        let f = try CursorFixture()
        defer { f.remove() }
        let file = f.project.appendingPathComponent("a.txt").path
        try f.put([
            ("composerData:c1", f.composer("c1", bubbles: ["u1", "t1"], created: 0, updated: 90)),
            ("bubbleId:c1:u1", f.userBubble("u1", at: 15)),
            ("bubbleId:c1:t1", f.tool("t1", name: "edit_file_v2", call: "tool_1", path: file, at: nil, result: f.applied()))
        ])
        try f.headerTable([("c1", nil, f.head("c1", folder: f.project.path))])
        let project = try XCTUnwrap(f.provider().scan(sources: [f.source]).projects.first)
        XCTAssertEqual(project.activities.first?.editMoments.map(\.date), [f.date(15)])
    }

    func testSubagentEditsAreDelegated() throws {
        let f = try CursorFixture()
        defer { f.remove() }
        let file = f.project.appendingPathComponent("a.txt").path
        try f.put([
            ("composerData:parent", f.composer("parent", bubbles: ["u1"], created: 0, updated: 30)),
            ("bubbleId:parent:u1", f.userBubble("u1", at: 1)),
            ("composerData:child", f.composer("child", bubbles: ["t1"], created: 5, updated: 30,
                extra: ["subagentInfo": ["parentComposerId": "parent", "subagentType": 1, "conversationLengthAtSpawn": 1]])),
            ("bubbleId:child:t1", f.tool("t1", name: "edit_file_v2", call: "tool_1", path: file, at: 10, result: f.applied()))
        ])
        try f.headerTable([("parent", nil, f.head("parent", folder: f.project.path)),
                           ("child", nil, f.head("child", folder: f.project.path))])
        let result = f.provider().scan(sources: [f.source])
        let project = try XCTUnwrap(result.projects.first)
        XCTAssertEqual(project.activities.first?.editMoments, [EditMoment(date: f.date(10), delegated: true)])
        XCTAssertEqual(result.sessionTrails.first { $0.sessionID == "child" }?.parentSessionID, "parent")
    }

    func testUnreadableBubbleIsReportedAndTheOthersStillCount() throws {
        let f = try CursorFixture()
        defer { f.remove() }
        let file = f.project.appendingPathComponent("a.txt").path
        try f.put([
            ("composerData:c1", f.composer("c1", bubbles: ["t1", "t2"], created: 0, updated: 30)),
            ("bubbleId:c1:t1", f.tool("t1", name: "edit_file_v2", call: "tool_1", path: file, at: 10, result: f.applied())),
            ("bubbleId:c1:t2", "{broken")
        ])
        try f.headerTable([("c1", nil, f.head("c1", folder: f.project.path))])
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 1)
        XCTAssertEqual(result.notices, ["Cursor: skipped unreadable records in Cursor's chat database."])
    }

    func testWALDatabaseIsReadOnlyWhileItsSidecarsExist() throws {
        let f = try CursorFixture()
        defer { f.remove() }
        // Cursor keeps the database open in WAL mode while it runs.
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(f.database.path, &writer), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(writer, "PRAGMA journal_mode=WAL;", nil, nil, nil), SQLITE_OK)
        let file = f.project.appendingPathComponent("a.txt").path
        try f.put([
            ("composerData:c1", f.composer("c1", bubbles: ["t1"], created: 0, updated: 30)),
            ("bubbleId:c1:t1", f.tool("t1", name: "edit_file_v2", call: "tool_1", path: file, at: 10, result: f.applied()))
        ])
        try f.headerTable([("c1", nil, f.head("c1", folder: f.project.path))])
        XCTAssertEqual(CursorActivityProvider.usesWAL(f.database), true)
        let provider = f.provider()
        XCTAssertEqual(provider.scan(sources: [f.source]).projects.first?.recordedEditCount, 1)
        XCTAssertNil(provider.saveCache())

        // Cursor quit: its -wal and -shm files are gone.
        sqlite3_close(writer)
        try? FileManager.default.removeItem(atPath: f.database.path + "-wal")
        try? FileManager.default.removeItem(atPath: f.database.path + "-shm")
        let cold = CursorActivityProvider(cacheURL: nil).scan(sources: [f.source])
        XCTAssertEqual(cold.projects, [])
        XCTAssertEqual(cold.notices, ["Cursor: Cursor's chat history is read while Cursor is open. Open Cursor once to index it."])
        XCTAssertNil(FileStat.of(f.database.path + "-shm"), "no file is created in Cursor's folder")
        XCTAssertNil(FileStat.of(f.database.path + "-wal"))
        // With a cache, the last scan's history stays, without a notice.
        let warm = f.provider().scan(sources: [f.source])
        XCTAssertEqual(warm.projects.first?.recordedEditCount, 1)
        XCTAssertEqual(warm.notices, [])
    }

    // MARK: Cursor CLI

    func testCLISessionsComeFromMetaJSON() throws {
        let f = try CursorFixture()
        defer { f.remove() }
        let bucket = "0123456789abcdef0123456789abcdef"
        try f.cli("8b2f9c1e-3a4d-4e5f-9a6b-7c8d9e0f1a2b", bucket: bucket, meta: ["schemaVersion": 1, "createdAtMs": f.ms(0),
            "updatedAtMs": f.ms(60), "cwd": f.project.path, "hasConversation": true, "title": "PRIVATE_TITLE_MARKER"])
        // Older builds wrote no cwd.
        try f.cli("1b2f9c1e-3a4d-4e5f-9a6b-7c8d9e0f1a2b", bucket: bucket, meta: ["schemaVersion": 1, "createdAtMs": f.ms(0)])
        // Opened and left without a message.
        try f.cli("2b2f9c1e-3a4d-4e5f-9a6b-7c8d9e0f1a2b", bucket: bucket, meta: ["schemaVersion": 1, "createdAtMs": f.ms(0),
            "cwd": f.project.path, "hasConversation": false])
        try f.cli("not-a-chat", bucket: bucket, meta: ["createdAtMs": f.ms(0), "cwd": f.project.path])
        let provider = f.provider()
        let result = provider.scan(sources: [f.source])
        let project = try XCTUnwrap(result.projects.first)
        XCTAssertEqual(project.path, canonicalPath(f.project.path))
        XCTAssertEqual(project.sessionCount, 1)
        XCTAssertEqual(project.recordedEditCount, 0)
        XCTAssertEqual(result.sessionTrails.first?.latestActivity, f.date(60))
        XCTAssertEqual(result.notices, ["Cursor: 1 Cursor CLI session(s) record no folder; they are not counted."])
        XCTAssertNil(provider.saveCache())
        XCTAssertFalse(try String(contentsOf: f.cache, encoding: .utf8).contains("PRIVATE_TITLE_MARKER"))
    }

    func testDefaultProfileReadsCursorsDefaultFolder() {
        let source = AgentSource(id: "cursor", name: "Cursor", configDirectory: "~/.cursor", assistant: .cursor)
        XCTAssertEqual(CursorActivityProvider.cursorFolder(source)?.path,
                       ("~/Library/Application Support/Cursor" as NSString).expandingTildeInPath)
        let custom = AgentSource(id: "cursor-work", name: "Work", configDirectory: "~/.cursor-work", assistant: .cursor)
        XCTAssertNil(CursorActivityProvider.cursorFolder(custom))
    }
}

enum CursorFixtureError: Error { case sqlite(String) }

/// Synthetic Cursor databases and Cursor CLI sessions in a temporary folder.
final class CursorFixture {
    let root: URL
    let project: URL
    let userData: URL
    let home: URL
    let cache: URL
    let source: AgentSource
    let base = Date(timeIntervalSince1970: 1_793_000_000)

    static let schema = """
        CREATE TABLE IF NOT EXISTS ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
        CREATE TABLE IF NOT EXISTS cursorDiskKV (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);
        """

    var user: URL { userData.appendingPathComponent("User", isDirectory: true) }
    var database: URL { user.appendingPathComponent("globalStorage/state.vscdb") }

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-trail-cursor-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        userData = root.appendingPathComponent("Cursor", isDirectory: true)
        home = root.appendingPathComponent("cursor-home", isDirectory: true)
        cache = root.appendingPathComponent("cache/activity-cache-cursor.json")
        source = AgentSource(id: "cursor", name: "Cursor", configDirectory: home.path, userDataDirectory: userData.path,
                             assistant: .cursor)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userData.appendingPathComponent("User/globalStorage", isDirectory: true),
                                                withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    func provider() -> CursorActivityProvider {
        let provider = CursorActivityProvider(cacheURL: cache)
        provider.minimumRelistInterval = 0
        return provider
    }

    func date(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }
    func ms(_ seconds: TimeInterval) -> Int { Int(date(seconds).timeIntervalSince1970 * 1000) }

    func iso(_ seconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date(seconds))
    }

    func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object) else {
            return "null"
        }
        return String(decoding: data, as: UTF8.self)
    }

    func uri(_ path: String) -> [String: Any] {
        ["$mid": 1, "fsPath": path, "external": URL(fileURLWithPath: path).absoluteString, "path": path, "scheme": "file"]
    }

    // Records.

    func composer(_ id: String, bubbles: [String], created: TimeInterval, updated: TimeInterval?,
                  extra: [String: Any] = [:]) -> [String: Any] {
        var object: [String: Any] = ["_v": 17, "composerId": id, "name": "PRIVATE_TITLE_MARKER", "createdAt": ms(created),
            "fullConversationHeadersOnly": bubbles.map { ["bubbleId": $0, "type": 2] as [String: Any] },
            "text": "PRIVATE_PROMPT_MARKER", "richText": "PRIVATE_PROMPT_MARKER", "status": "completed",
            "context": ["fileSelections": [], "mentions": [:]], "codeBlockData": [:], "newlyCreatedFiles": [],
            "conversationMap": [:], "unifiedMode": "agent"]
        if let updated { object["lastUpdatedAt"] = ms(updated) }
        for (key, value) in extra { object[key] = value }
        return object
    }

    /// A header as the `composerHeaders` table keeps it.
    func head(_ id: String, folder: String) -> [String: Any] {
        ["type": "head", "composerId": id, "name": "PRIVATE_TITLE_MARKER", "unifiedMode": "agent",
         "workspaceIdentifier": ["id": "93c175a1e1761d404ef54f2a5f463464", "uri": uri(folder)]]
    }

    func userBubble(_ id: String, at seconds: TimeInterval) -> [String: Any] {
        ["_v": 3, "type": 1, "bubbleId": id, "text": "PRIVATE_PROMPT_MARKER", "richText": "PRIVATE_PROMPT_MARKER",
         "createdAt": iso(seconds)]
    }

    func textBubble(_ id: String, at seconds: TimeInterval) -> [String: Any] {
        ["_v": 3, "type": 2, "bubbleId": id, "text": "PRIVATE_PROMPT_MARKER", "createdAt": iso(seconds)]
    }

    /// A successful 3.x edit result: content-store ids.
    func applied() -> [String: Any] {
        ["beforeContentId": "composer.content.e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
         "afterContentId": "composer.content.\(UUID().uuidString)"]
    }

    /// A tool bubble. Parameters and result are JSON strings, as Cursor writes them.
    func tool(_ id: String, name: String, status: String = "completed", call: String, path: String?, at seconds: TimeInterval?,
              result: [String: Any]?, params: [String: Any] = [:], former: [String: Any] = [:],
              extra: [String: Any] = [:]) -> [String: Any] {
        var parameters = params
        if let path { parameters["relativeWorkspacePath"] = path }
        var tool: [String: Any] = ["tool": 38, "toolIndex": 0, "modelCallId": "", "toolCallId": call, "status": status,
            "name": name, "params": json(parameters), "rawArgs": "PRIVATE_CONTENT_MARKER",
            "additionalData": ["precomputedDiff": ["lines": [["type": "added", "content": "PRIVATE_CONTENT_MARKER"]]]]]
        if let result {
            tool["result"] = json(result)
        } else {
            tool["result"] = NSNull()
        }
        for (key, value) in former { tool[key] = value }
        var bubble: [String: Any] = ["_v": 3, "type": 2, "bubbleId": id, "text": "", "capabilityType": 15,
                                     "toolFormerData": tool, "codeBlocks": []]
        if let seconds { bubble["createdAt"] = iso(seconds) }
        for (key, value) in extra { bubble[key] = value }
        return bubble
    }

    // Databases.

    private func withDatabase(_ url: URL?, _ body: (OpaquePointer?) throws -> Void) throws {
        let target = url ?? database
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        guard sqlite3_open(target.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            throw CursorFixtureError.sqlite("open")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, Self.schema, nil, nil, nil) == SQLITE_OK else { throw CursorFixtureError.sqlite("schema") }
        try body(db)
    }

    func execute(_ sql: String, at url: URL? = nil) throws {
        try withDatabase(url) { db in
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CursorFixtureError.sqlite(sql) }
        }
    }

    /// Inserts rows; a String is bound as text, an Int as an integer, nil as
    /// NULL, and anything else as its JSON text.
    func insert(_ sql: String, rows: [[Any?]], at url: URL? = nil) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        try withDatabase(url) { db in
            for row in rows {
                var statement: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw CursorFixtureError.sqlite(sql)
                }
                defer { sqlite3_finalize(statement) }
                for (offset, item) in row.enumerated() {
                    let index = Int32(offset + 1)
                    guard let item else {
                        sqlite3_bind_null(statement, index)
                        continue
                    }
                    if let text = item as? String {
                        sqlite3_bind_text(statement, index, text, -1, transient)
                    } else if let number = item as? Int {
                        sqlite3_bind_int64(statement, index, Int64(number))
                    } else {
                        sqlite3_bind_text(statement, index, json(item), -1, transient)
                    }
                }
                guard sqlite3_step(statement) == SQLITE_DONE else { throw CursorFixtureError.sqlite(sql) }
            }
        }
    }

    /// Writes key-value rows into the global database (or `url`).
    func put(_ rows: [(String, Any?)], table: String = "cursorDiskKV", at url: URL? = nil) throws {
        try insert("INSERT INTO \(table) (key, value) VALUES (?, ?)", rows: rows.map { [$0.0, $0.1] }, at: url)
    }

    /// The `composerHeaders` table of Cursor 3.9 and later.
    func headerTable(_ rows: [(String, String?, [String: Any])]) throws {
        try execute("""
            CREATE TABLE IF NOT EXISTS composerHeaders (composerId TEXT PRIMARY KEY, workspaceId TEXT, createdAt INTEGER,
                lastUpdatedAt INTEGER, isArchived INTEGER, isSubagent INTEGER, recency INTEGER, checkpointAt INTEGER, value TEXT);
            """)
        try insert("INSERT OR REPLACE INTO composerHeaders (composerId, workspaceId, isArchived, isSubagent, value) VALUES (?, ?, 0, 0, ?)",
                   rows: rows.map { [$0.0, $0.1, $0.2] })
    }

    func workspace(_ id: String, folder: String) throws {
        let directory = user.appendingPathComponent("workspaceStorage/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = ["folder": URL(fileURLWithPath: folder, isDirectory: true).absoluteString]
        try JSONSerialization.data(withJSONObject: record).write(to: directory.appendingPathComponent("workspace.json"))
    }

    /// A pre-3.0 workspace database listing its chats.
    func legacyWorkspace(_ id: String, folder: String, composers: [String]) throws {
        try workspace(id, folder: folder)
        let database = user.appendingPathComponent("workspaceStorage/\(id)/state.vscdb")
        let list: [String: Any] = ["allComposers": composers.map { ["type": "head", "composerId": $0, "name": "PRIVATE_TITLE_MARKER"] },
                                   "selectedComposerIds": [], "hasMigratedComposerData": false]
        try put([("composer.composerData", list)], table: "ItemTable", at: database)
    }

    func cli(_ id: String, bucket: String, meta: [String: Any]) throws {
        let folder = home.appendingPathComponent("chats/\(bucket)/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: meta).write(to: folder.appendingPathComponent("meta.json"))
        // The CLI's own store, which the adapter never opens.
        try Data("not read".utf8).write(to: folder.appendingPathComponent("store.db"))
    }

    func git(_ directory: URL) throws {
        let metadata = directory.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata.appendingPathComponent("objects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: metadata.appendingPathComponent("HEAD"))
    }
}
