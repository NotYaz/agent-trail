import Foundation
import SQLite3
import XCTest
@testable import AgentTrailCore

final class OpenCodeActivityProviderTests: XCTestCase {
    // MARK: OpenCode 2

    func testCompletedEditToolsCountAtTheirCompletionTimes() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        try f.createV2()
        try f.session("ses_a", directory: f.project, created: 0)
        try f.message("msg_1", session: "ses_a", type: "user", seq: 1, created: 1, data: f.user(created: 1))
        try f.message("msg_2", session: "ses_a", seq: 2, created: 10, data: f.assistant([
            f.text(),
            f.tool("call_edit", "edit", completed: 20,
                   input: ["path": "Sources/App.swift", "oldString": "PRIVATE_CONTENT_MARKER", "newString": "x"],
                   metadata: ["files": [f.diff("Sources/App.swift")]]),
            f.tool("call_write", "write", completed: 30,
                   input: ["path": f.project.appendingPathComponent("notes.txt").path, "content": "PRIVATE_CONTENT_MARKER"]),
            f.tool("call_shell", "shell", completed: 31, input: ["command": "touch made-by-shell.txt"]),
            // A rejected approval ends as an error.
            f.tool("call_denied", "write", status: "error", completed: 32, input: ["path": "denied.txt"]),
            // An approval still open: the call waits in `running`.
            f.tool("call_pending", "edit", status: "running", input: ["path": "pending.txt"]),
            f.tool("call_read", "read", completed: 33, input: ["path": "Sources/App.swift"]),
            // A patch whose result names no file finds nothing to count.
            f.tool("call_patch", "patch", completed: 34, input: ["patchText": "PRIVATE_CONTENT_MARKER"])
        ], created: 10, completed: 40))
        let result = f.provider().scan(sources: [f.source])
        let project = try XCTUnwrap(result.projects.first { $0.path == canonicalPath(f.project.path) })
        XCTAssertEqual(project.recordedEditCount, 2)
        XCTAssertEqual(project.sessionCount, 1)
        XCTAssertEqual(project.activities.first?.editMoments.map(\.date), [f.date(20), f.date(30)])
        XCTAssertEqual(result.sessionTrails.first?.sessionID, "ses_a")
        XCTAssertEqual(result.notices, [])
    }

    func testPartRowsAndInlineCopiesOfOneCallCountOnce() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        try f.createV2()
        try f.session("ses_a", directory: f.project, created: 0)
        let edit = f.tool("call_1", "edit", completed: 20, input: ["path": "a.txt"], metadata: ["files": [f.diff("a.txt")]])
        // Before 2.2.2 tool items are inline; a part row can repeat one.
        try f.message("msg_1", session: "ses_a", seq: 1, created: 10, data: f.assistant([edit], created: 10, completed: 21))
        try f.part("msg_1", session: "ses_a", ordinal: 0, item: edit)
        try f.message("msg_2", session: "ses_a", seq: 2, created: 22, data: f.assistant([], created: 22, completed: 40))
        try f.part("msg_2", session: "ses_a", ordinal: 0, item: f.tool("call_2", "patch", completed: 30,
            input: ["patchText": "PRIVATE_CONTENT_MARKER"], metadata: ["files": [f.diff("b/c.txt"), f.diff("d.txt")]]))
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 2)
        XCTAssertEqual(result.projects.first?.activities.first?.editMoments.map(\.date), [f.date(20), f.date(30)])
    }

    func testLocationSwitchMovesWhereLaterRelativePathsLand() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        let other = f.root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try f.git(other)
        try f.createV2()
        // session_v2.directory is where the session is now, after its move.
        try f.session("ses_a", directory: other, created: 0)
        try f.message("msg_1", session: "ses_a", seq: 1, created: 10, data: f.assistant([
            f.tool("call_1", "write", completed: 11, input: ["path": "before.txt", "content": "PRIVATE_CONTENT_MARKER"])
        ], created: 10, completed: 12))
        try f.message("msg_2", session: "ses_a", type: "location-switched", seq: 2, created: 20, data: [
            "location": ["directory": other.path],
            "previous": ["location": ["directory": f.project.path]],
            "time": ["created": f.ms(20)]
        ])
        try f.message("msg_3", session: "ses_a", seq: 3, created: 30, data: f.assistant([
            f.tool("call_3", "write", completed: 31, input: ["path": "after.txt", "content": "PRIVATE_CONTENT_MARKER"])
        ], created: 30, completed: 32))
        let result = f.provider().scan(sources: [f.source])
        let trail = try XCTUnwrap(result.sessionTrails.first)
        XCTAssertEqual(trail.edits.map(\.projectPath), [canonicalPath(f.project.path), canonicalPath(other.path)])
        // Started in the project folder; the one checkout it edited is where it moved.
        XCTAssertEqual(trail.projectPath, canonicalPath(other.path))
    }

    func testStagedRevertHidesLaterEditsUntilItIsCleared() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        try f.createV2()
        try f.session("ses_a", directory: f.project, created: 0, revert: "msg_2")
        try f.message("msg_1", session: "ses_a", seq: 1, created: 10, data: f.assistant([
            f.tool("call_1", "write", completed: 11, input: ["path": "kept.txt"])], created: 10, completed: 12))
        try f.message("msg_2", session: "ses_a", type: "user", seq: 2, created: 20, data: f.user(created: 20))
        try f.message("msg_3", session: "ses_a", seq: 3, created: 30, data: f.assistant([
            f.tool("call_3", "write", completed: 31, input: ["path": "reverted.txt"])], created: 30, completed: 32))
        let provider = f.provider()
        XCTAssertEqual(provider.scan(sources: [f.source]).projects.first?.recordedEditCount, 1)
        // Unrevert puts the files back and clears the revert.
        try f.run("UPDATE session_v2 SET revert = NULL, time_updated = ? WHERE id = 'ses_a'", [f.ms(40)])
        XCTAssertEqual(provider.scan(sources: [f.source]).projects.first?.recordedEditCount, 2)
    }

    func testSubagentEditsAreDelegatedAndForkCopiesCountOnce() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        try f.createV2()
        let shared = f.tool("call_1", "write", completed: 11, input: ["path": "a.txt"])
        try f.session("ses_parent", directory: f.project, created: 0)
        try f.message("msg_1", session: "ses_parent", seq: 1, created: 10, data: f.assistant([shared], created: 10, completed: 12))
        try f.session("ses_child", directory: f.project, created: 15, parent: "ses_parent")
        try f.message("msg_2", session: "ses_child", seq: 1, created: 16, data: f.assistant([
            f.tool("call_2", "write", completed: 20, input: ["path": "b.txt"])], created: 16, completed: 21))
        // A fork copies the parent's settled messages, tool ids and times included.
        try f.session("ses_fork", directory: f.project, created: 25, fork: "ses_parent")
        try f.message("msg_1_fork", session: "ses_fork", seq: 1, created: 10, data: f.assistant([shared], created: 10, completed: 12))
        try f.message("msg_3", session: "ses_fork", seq: 2, created: 26, data: f.assistant([
            f.tool("call_3", "write", completed: 30, input: ["path": "c.txt"])], created: 26, completed: 31))
        let result = f.provider().scan(sources: [f.source])
        let project = try XCTUnwrap(result.projects.first)
        XCTAssertEqual(project.sessionCount, 3)
        XCTAssertEqual(project.recordedEditCount, 3)
        XCTAssertEqual(project.activities.first?.editMoments.filter(\.delegated).map(\.date), [f.date(20)])
        XCTAssertEqual(result.sessionTrails.first { $0.sessionID == "ses_child" }?.parentSessionID, "ses_parent")
        XCTAssertEqual(result.sessionTrails.first { $0.sessionID == "ses_parent" }?.edits.count, 1)
        XCTAssertEqual(result.sessionTrails.first { $0.sessionID == "ses_fork" }?.edits.count, 1)
    }

    func testForkCopiesResolveWhereTheParentRanThemAfterTheParentMoves() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        let other = f.root.appendingPathComponent("other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try f.git(other)
        try f.createV2()
        // The parent edits in the project, then moves to another checkout.
        let copied = f.tool("call_1", "write", completed: 11, input: ["path": "a.txt"])
        try f.session("ses_parent", directory: other, created: 0)
        try f.message("msg_1", session: "ses_parent", seq: 1, created: 10, data: f.assistant([copied], created: 10, completed: 12))
        try f.message("msg_2", session: "ses_parent", type: "user", seq: 2, created: 15, data: f.user(created: 15))
        try f.message("msg_3", session: "ses_parent", type: "location-switched", seq: 3, created: 20, data: [
            "location": ["directory": other.path],
            "previous": ["location": ["directory": f.project.path]],
            "time": ["created": f.ms(20)]
        ])
        // Forked before msg_2 after the move: it copies msg_1 but not the
        // move, and is made in the folder the parent is in now.
        try f.session("ses_fork", directory: other, created: 25, fork: "ses_parent")
        try f.message("msg_1_fork", session: "ses_fork", seq: 1, created: 10, data: f.assistant([copied], created: 10, completed: 12))
        try f.message("msg_4", session: "ses_fork", seq: 2, created: 26, data: f.assistant([
            f.tool("call_4", "write", completed: 27, input: ["path": "b.txt"])], created: 26, completed: 28))
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects.first { $0.path == canonicalPath(f.project.path) }?.recordedEditCount, 1)
        XCTAssertEqual(result.projects.first { $0.path == canonicalPath(other.path) }?.recordedEditCount, 1)
        // The copy stays the parent's; the fork keeps its own edit.
        XCTAssertEqual(result.sessionTrails.first { $0.sessionID == "ses_parent" }?.edits.map(\.projectPath),
                       [canonicalPath(f.project.path)])
        XCTAssertEqual(result.sessionTrails.first { $0.sessionID == "ses_fork" }?.edits.map(\.projectPath),
                       [canonicalPath(other.path)])
    }

    func testForkOwnStepsStartWhereTheForkWasMade() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        let second = f.root.appendingPathComponent("second", isDirectory: true)
        let third = f.root.appendingPathComponent("third", isDirectory: true)
        for folder in [second, third] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try f.git(folder)
        }
        try f.createV2()
        func move(_ id: String, session: String, seq: Int, created: TimeInterval, from: URL, to: URL) throws {
            try f.message(id, session: session, type: "location-switched", seq: seq, created: created, data: [
                "location": ["directory": to.path],
                "previous": ["location": ["directory": from.path]],
                "time": ["created": f.ms(created)]
            ])
        }
        let first = f.tool("call_1", "write", completed: 11, input: ["path": "a.txt"])
        let moved = f.tool("call_2", "write", completed: 14, input: ["path": "b.txt"])
        // The parent moves to `second` and edits there, then moves on to `third`.
        try f.session("ses_parent", directory: third, created: 0)
        try f.message("msg_1", session: "ses_parent", seq: 1, created: 10, data: f.assistant([first], created: 10, completed: 12))
        try move("msg_2", session: "ses_parent", seq: 2, created: 12, from: f.project, to: second)
        try f.message("msg_3", session: "ses_parent", seq: 3, created: 13, data: f.assistant([moved], created: 13, completed: 15))
        try f.message("msg_4", session: "ses_parent", type: "user", seq: 4, created: 16, data: f.user(created: 16))
        try move("msg_5", session: "ses_parent", seq: 5, created: 18, from: second, to: third)
        // Forked before msg_4: it copies the first move, and is made in `third`.
        try f.session("ses_fork", directory: third, created: 25, fork: "ses_parent")
        try f.message("msg_1_fork", session: "ses_fork", seq: 1, created: 10, data: f.assistant([first], created: 10, completed: 12))
        try move("msg_2_fork", session: "ses_fork", seq: 2, created: 12, from: f.project, to: second)
        try f.message("msg_3_fork", session: "ses_fork", seq: 3, created: 13, data: f.assistant([moved], created: 13, completed: 15))
        try f.message("msg_6", session: "ses_fork", seq: 4, created: 26, data: f.assistant([
            f.tool("call_3", "write", completed: 27, input: ["path": "c.txt"])], created: 26, completed: 28))
        let result = f.provider().scan(sources: [f.source])
        for (folder, count) in [(f.project, 1), (second, 1), (third, 1)] {
            XCTAssertEqual(result.projects.first { $0.path == canonicalPath(folder.path) }?.recordedEditCount, count,
                           folder.lastPathComponent)
        }
        XCTAssertEqual(result.sessionTrails.first { $0.sessionID == "ses_parent" }?.edits.map(\.projectPath),
                       [f.project, second].map { canonicalPath($0.path) })
        XCTAssertEqual(result.sessionTrails.first { $0.sessionID == "ses_fork" }?.edits.map(\.projectPath),
                       [canonicalPath(third.path)])
    }

    func testEditsOutsideTheSessionFolderAndAnyCheckoutDoNotCount() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        try f.createV2()
        try f.session("ses_a", directory: f.project, created: 0)
        try f.message("msg_1", session: "ses_a", seq: 1, created: 10, data: f.assistant([
            f.tool("call_1", "write", completed: 11, input: ["path": f.root.appendingPathComponent("scratch/x.txt").path]),
            f.tool("call_2", "edit", completed: 12, input: ["path": "../scratch/y.txt"])
        ], created: 10, completed: 13))
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 0)
        XCTAssertEqual(result.projects.first?.sessionCount, 1)
    }

    func testIncrementalRescanAfterARewriteAnAppendAndACommittedRevert() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        try f.createV2()
        try f.session("ses_a", directory: f.project, created: 0, busy: 5)
        try f.message("msg_1", session: "ses_a", seq: 1, created: 10, data: f.assistant([
            f.tool("call_1", "write", status: "running", input: ["path": "a.txt"])], created: 10))
        let provider = f.provider()
        XCTAssertEqual(provider.scan(sources: [f.source]).projects.first?.recordedEditCount, 0, "waiting for approval")

        // The call completes in place: same row and counts, the session still busy.
        let done = try f.json(f.assistant([f.tool("call_1", "write", completed: 20, input: ["path": "a.txt"])], created: 10))
        try f.run("UPDATE session_message SET data = ?, time_updated = ? WHERE id = 'msg_1'", [done, f.ms(20)])
        XCTAssertEqual(provider.scan(sources: [f.source]).projects.first?.recordedEditCount, 1)

        // A new step appends a message, then the turn ends.
        try f.message("msg_2", session: "ses_a", seq: 2, created: 30, data: f.assistant([
            f.tool("call_2", "edit", completed: 31, input: ["path": "b.txt"])], created: 30, completed: 32))
        try f.run("UPDATE session_v2 SET time_idle = ?, time_updated = ? WHERE id = 'ses_a'", [f.ms(33), f.ms(33)])
        XCTAssertEqual(provider.scan(sources: [f.source]).projects.first?.recordedEditCount, 2)

        // A committed revert deletes that step.
        try f.run("DELETE FROM session_message WHERE session_id = 'ses_a' AND seq >= 2", [])
        try f.run("UPDATE session_v2 SET time_updated = ? WHERE id = 'ses_a'", [f.ms(40)])
        XCTAssertEqual(provider.scan(sources: [f.source]).projects.first?.recordedEditCount, 1)
    }

    func testCacheKeepsNoContentAndSurvivesReload() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        try f.createV2()
        try f.session("ses_a", directory: f.project, created: 0, revert: "msg_missing")
        try f.message("msg_0", session: "ses_a", type: "user", seq: 1, created: 1, data: f.user(created: 1))
        try f.message("msg_1", session: "ses_a", seq: 2, created: 10, data: f.assistant([f.text(),
            f.tool("call_1", "edit", completed: 11,
                   input: ["path": "a.txt", "oldString": "PRIVATE_CONTENT_MARKER", "newString": "PRIVATE_CONTENT_MARKER"],
                   metadata: ["files": [f.diff("a.txt")]])], created: 10, completed: 12))
        let provider = f.provider()
        XCTAssertEqual(provider.scan(sources: [f.source]).projects.first?.recordedEditCount, 1)
        XCTAssertNil(provider.saveCache())
        let saved = try String(contentsOf: f.cache, encoding: .utf8)
        for marker in ["PRIVATE_PROMPT_MARKER", "PRIVATE_CONTENT_MARKER", "PRIVATE_OUTPUT_MARKER"] {
            XCTAssertFalse(saved.contains(marker), marker)
        }
        let reloaded = f.provider()
        XCTAssertEqual(reloaded.metadata(sources: [f.source]).projects.first?.recordedEditCount, 1)
        XCTAssertEqual(reloaded.scan(sources: [f.source]).projects.first?.recordedEditCount, 1)
    }

    // MARK: OpenCode 1.x

    func testOpenCode1PartsUseFilePathsAndTheMessageFolder() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        let sub = f.project.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try f.git(sub)
        try f.createV1()
        let p = f.project.path
        try f.legacySession("ses_1", directory: f.project, created: 0)
        try f.legacyMessage("msg_a", session: "ses_1", role: "user", created: 1)
        try f.legacyMessage("msg_b", session: "ses_1", created: 10, completed: 20, cwd: sub)
        try f.legacyMessage("msg_c", session: "ses_1", created: 30, completed: 60, cwd: f.project)
        // A relative filePath joins the folder its message ran in.
        try f.legacyPart("prt_1", message: "msg_b", session: "ses_1", created: 11,
            data: f.legacyTool("c1", "edit", end: 12, input: ["filePath": "rel/a.txt", "oldString": "PRIVATE_CONTENT_MARKER"]))
        try f.legacyPart("prt_2", message: "msg_b", session: "ses_1", created: 11, data: f.legacyText())
        try f.legacyPart("prt_3", message: "msg_c", session: "ses_1", created: 31,
            data: f.legacyTool("c3", "write", end: 32, input: ["filePath": "\(p)/b.txt", "content": "PRIVATE_CONTENT_MARKER"],
                               metadata: ["filepath": "\(p)/b.txt", "exists": false]))
        try f.legacyPart("prt_4", message: "msg_c", session: "ses_1", created: 33,
            data: f.legacyTool("c4", "apply_patch", end: 34, input: ["patchText": "PRIVATE_CONTENT_MARKER"],
                               metadata: ["diff": "PRIVATE_CONTENT_MARKER", "files": [[
                                   "filePath": "\(p)/m.txt", "movePath": "\(p)/moved/m.txt", "type": "move",
                                   "patch": "PRIVATE_CONTENT_MARKER"]]]))
        try f.legacyPart("prt_5", message: "msg_c", session: "ses_1", created: 35,
            data: f.legacyTool("c5", "multiedit", end: 36, input: ["filePath": "\(p)/c.txt"]))
        // OpenCode 1.0's patch names its files only inside the patch text.
        try f.legacyPart("prt_6", message: "msg_c", session: "ses_1", created: 37,
            data: f.legacyTool("c6", "patch", end: 38, input: ["patchText": "*** Update File: \(p)/d.txt"]))
        try f.legacyPart("prt_7", message: "msg_c", session: "ses_1", created: 39,
            data: f.legacyTool("c7", "edit", status: "error", end: 40, input: ["filePath": "\(p)/denied.txt"]))
        try f.legacyPart("prt_8", message: "msg_c", session: "ses_1", created: 41,
            data: f.legacyTool("c8", "bash", end: 42, input: ["command": "touch \(p)/shell.txt"]))
        try f.legacyPart("prt_9", message: "msg_c", session: "ses_1", created: 43,
            data: f.legacyTool("c9", "write", status: "running", input: ["filePath": "\(p)/pending.txt"]))
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects.reduce(0) { $0 + $1.recordedEditCount }, 4)
        XCTAssertEqual(result.projects.first { $0.path == canonicalPath(sub.path) }?.recordedEditCount, 1)
        XCTAssertEqual(result.sessionTrails.first?.edits.map(\.date), [f.date(12), f.date(32), f.date(34), f.date(36)])
        XCTAssertEqual(result.notices, [])
    }

    func testOpenCode1StagedRevertHidesItsPartAndLaterMessages() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        try f.createV1()
        let p = f.project.path
        try f.legacySession("ses_1", directory: f.project, created: 0, revert: (message: "msg_b", part: "prt_2"))
        try f.legacyMessage("msg_b", session: "ses_1", created: 10, completed: 20, cwd: f.project)
        try f.legacyPart("prt_1", message: "msg_b", session: "ses_1", created: 11,
            data: f.legacyTool("c1", "write", end: 12, input: ["filePath": "\(p)/kept.txt"]))
        try f.legacyPart("prt_2", message: "msg_b", session: "ses_1", created: 13,
            data: f.legacyTool("c2", "write", end: 14, input: ["filePath": "\(p)/reverted.txt"]))
        try f.legacyMessage("msg_c", session: "ses_1", created: 30, completed: 40, cwd: f.project)
        try f.legacyPart("prt_3", message: "msg_c", session: "ses_1", created: 31,
            data: f.legacyTool("c3", "write", end: 32, input: ["filePath": "\(p)/later.txt"]))
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects.first?.activities.first?.editMoments.map(\.date), [f.date(12)])
    }

    func testImportedSessionsCountOnceAndDeletedOnesStayDeleted() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        try f.createV1()
        try f.createV2()
        let p = f.project.path
        try f.imported(at: 100)
        // Imported: OpenCode 2's copy keeps the 1.x tool name, input and metadata.
        try f.legacySession("ses_a", directory: f.project, created: 0)
        try f.legacyMessage("msg_a1", session: "ses_a", created: 10, completed: 20, cwd: f.project)
        try f.legacyPart("prt_a1", message: "msg_a1", session: "ses_a", created: 11,
            data: f.legacyTool("c1", "write", end: 12, input: ["filePath": "\(p)/a.txt"], metadata: ["filepath": "\(p)/a.txt"]))
        try f.session("ses_a", directory: f.project, created: 0)
        try f.message("msg_a1", session: "ses_a", seq: 1, created: 10, data: f.assistant([
            f.tool("c1", "write", completed: 12, input: ["filePath": "\(p)/a.txt"], metadata: ["filepath": "\(p)/a.txt"])
        ], created: 10, completed: 20))
        // OpenCode 1.x went on in the same session after the import.
        try f.legacyMessage("msg_a2", session: "ses_a", created: 150, completed: 160, cwd: f.project)
        try f.legacyPart("prt_a2", message: "msg_a2", session: "ses_a", created: 151,
            data: f.legacyTool("c2", "edit", end: 152, input: ["filePath": "\(p)/b.txt"]))
        // Imported, then deleted in OpenCode 2.
        try f.legacySession("ses_b", directory: f.project, created: 5)
        try f.legacyMessage("msg_b1", session: "ses_b", created: 6, completed: 8, cwd: f.project)
        try f.legacyPart("prt_b1", message: "msg_b1", session: "ses_b", created: 7,
            data: f.legacyTool("c3", "edit", end: 7, input: ["filePath": "\(p)/c.txt"]))
        // Started in OpenCode 1.x after the import.
        try f.legacySession("ses_c", directory: f.project, created: 120)
        try f.legacyMessage("msg_c1", session: "ses_c", created: 121, completed: 125, cwd: f.project)
        try f.legacyPart("prt_c1", message: "msg_c1", session: "ses_c", created: 122,
            data: f.legacyTool("c4", "edit", end: 123, input: ["filePath": "\(p)/d.txt"]))
        let result = f.provider().scan(sources: [f.source])
        let project = try XCTUnwrap(result.projects.first)
        XCTAssertEqual(project.sessionCount, 2)
        XCTAssertEqual(project.recordedEditCount, 3)
        XCTAssertEqual(Set(result.sessionTrails.map(\.sessionID)), ["ses_a", "ses_c"])
        XCTAssertEqual(project.activities.first?.editMoments.map(\.date), [f.date(12), f.date(123), f.date(152)])
    }

    // MARK: Stores

    func testMissingStoreGivesOneNotice() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        let missing = AgentSource(id: "opencode", name: "OpenCode", configDirectory: f.root.appendingPathComponent("none").path,
                                  assistant: .opencode)
        XCTAssertEqual(f.provider().scan(sources: [missing]).notices, ["OpenCode: no local OpenCode history was found."])
        // OpenCode before 1.2 kept JSON files, which 1.2 moves into opencode.db.
        try FileManager.default.createDirectory(at: f.data.appendingPathComponent("storage/session/global"),
                                                withIntermediateDirectories: true)
        let notices = f.provider().scan(sources: [f.source]).notices
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices.first?.contains("before 1.2") == true, "\(notices)")
    }

    func testADatabaseFileTheProfileNamesIsReadWhateverItIsCalled() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        // OPENCODE_DB takes any file name.
        try f.createV2(in: "history.sqlite")
        try f.session("ses_a", directory: f.project, created: 0, in: "history.sqlite")
        try f.message("msg_1", session: "ses_a", seq: 1, created: 10, data: f.assistant([
            f.tool("call_1", "write", completed: 11, input: ["path": "a.txt"])], created: 10, completed: 12),
            in: "history.sqlite")
        let named = AgentSource(id: "opencode", name: "OpenCode",
                                configDirectory: f.data.appendingPathComponent("history.sqlite").path, assistant: .opencode)
        let result = f.provider().scan(sources: [named])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 1)
        XCTAssertEqual(result.notices, [])
        // A named file that is not a database says so, not that no history exists.
        let notes = f.root.appendingPathComponent("notes.txt")
        try Data(String(repeating: "not a database\n", count: 400).utf8).write(to: notes)
        let text = AgentSource(id: "opencode", name: "OpenCode", configDirectory: notes.path, assistant: .opencode)
        let notices = f.provider().scan(sources: [text]).notices
        XCTAssertTrue(notices.contains { $0.contains("could not be opened read-only") }, "\(notices)")
        XCTAssertFalse(notices.contains { $0.contains("no local OpenCode history") }, "\(notices)")
    }

    func testUnknownTablesAreReportedNotGuessed() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        try f.exec("CREATE TABLE something_else (id text)")
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects, [])
        XCTAssertTrue(result.notices.contains { $0.contains("format this version doesn't read") }, "\(result.notices)")
    }

    func testChannelDatabasesAreReadAndTheImportedNextDatabaseIsNot() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        for name in ["opencode.db", "opencode-local.db", "opencode-next.db"] {
            try f.createV2(in: name)
            let id = "ses_" + name.replacingOccurrences(of: ".", with: "_").replacingOccurrences(of: "-", with: "_")
            try f.session(id, directory: f.project, created: 0, in: name)
        }
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(Set(result.sessionTrails.map(\.sessionID)), ["ses_opencode_db", "ses_opencode_local_db"])
        XCTAssertTrue(OpenCodeActivityProvider.isDatabaseName("opencode-beta.db"))
        XCTAssertFalse(OpenCodeActivityProvider.isDatabaseName("opencode-next.db"))
        XCTAssertFalse(OpenCodeActivityProvider.isDatabaseName("opencode.db-wal"))
        XCTAssertFalse(OpenCodeActivityProvider.isDatabaseName("opencode-.db"))
        XCTAssertFalse(OpenCodeActivityProvider.isDatabaseName("drafts.sqlite"))
    }

    func testPathsResolveAsOpenCodeResolvesThem() {
        XCTAssertEqual(OpenCodeDatabase.resolve("src/../a.txt", base: "/w/p", expandsHome: true), "/w/p/a.txt")
        XCTAssertEqual(OpenCodeDatabase.resolve("../c.txt", base: "/w/p/sub", expandsHome: false), "/w/p/c.txt")
        XCTAssertEqual(OpenCodeDatabase.resolve("/abs/d.txt", base: "/w/p", expandsHome: false), "/abs/d.txt")
        // OpenCode 2 expands `~`; 1.x joins it like any other relative path.
        XCTAssertEqual(OpenCodeDatabase.resolve("~/x.txt", base: "/w/p", expandsHome: true),
                       ProjectLocationRegistry.lexicalPath("~/x.txt"))
        XCTAssertEqual(OpenCodeDatabase.resolve("~/x.txt", base: "/w/p", expandsHome: false), "/w/p/~/x.txt")
        XCTAssertNil(OpenCodeDatabase.resolve("", base: "/w/p", expandsHome: true))
    }
}

enum OpenCodeFixtureError: Error {
    case sql(String)
    case json
}

/// Synthetic OpenCode databases under a temporary home. Writer connections
/// stay open until `remove()`, as OpenCode's own service keeps its open.
final class OpenCodeFixture {
    let root: URL
    let home: URL
    let project: URL
    /// The profile folder: OpenCode's data folder.
    let data: URL
    let cache: URL
    let source: AgentSource
    /// Two hours ago, in whole seconds: times survive millisecond storage, and
    /// a session left mid-turn falls inside the re-read window.
    let base: Date
    private var connections: [String: OpaquePointer] = [:]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-trail-opencode-\(UUID().uuidString)",
                                                                            isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        data = home.appendingPathComponent(".local/share/opencode", isDirectory: true)
        cache = root.appendingPathComponent("cache/activity-cache-opencode.json")
        source = AgentSource(id: "opencode", name: "OpenCode", configDirectory: data.path, assistant: .opencode)
        base = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 7_200).rounded(.down))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
    }

    func remove() {
        for handle in connections.values { sqlite3_close(handle) }
        connections.removeAll()
        try? FileManager.default.removeItem(at: root)
    }

    func provider() -> OpenCodeActivityProvider { OpenCodeActivityProvider(cacheURL: cache) }
    func date(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }
    func ms(_ seconds: TimeInterval) -> Int64 { Int64((date(seconds).timeIntervalSince1970 * 1000).rounded()) }

    func git(_ directory: URL) throws {
        let metadata = directory.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata.appendingPathComponent("objects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: metadata.appendingPathComponent("HEAD"))
    }

    // MARK: SQLite

    @discardableResult
    func open(_ name: String = "opencode.db") throws -> OpaquePointer {
        if let handle = connections[name] { return handle }
        var opened: OpaquePointer?
        guard sqlite3_open(data.appendingPathComponent(name).path, &opened) == SQLITE_OK, let handle = opened else {
            if let opened { sqlite3_close(opened) }
            throw OpenCodeFixtureError.sql("cannot open \(name)")
        }
        connections[name] = handle
        guard sqlite3_exec(handle, "PRAGMA journal_mode=WAL", nil, nil, nil) == SQLITE_OK else {
            throw OpenCodeFixtureError.sql(String(cString: sqlite3_errmsg(handle)))
        }
        return handle
    }

    func exec(_ sql: String, in name: String = "opencode.db") throws {
        let handle = try open(name)
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else {
            throw OpenCodeFixtureError.sql(String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// One statement with `?` values: strings, integers or nil.
    func run(_ sql: String, _ values: [Any?], in name: String = "opencode.db") throws {
        let handle = try open(name)
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared else {
            throw OpenCodeFixtureError.sql(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            if let text = value as? String {
                sqlite3_bind_text(statement, index, text, -1, transient)
            } else if let number = value as? Int64 {
                sqlite3_bind_int64(statement, index, number)
            } else if let number = value as? Int {
                sqlite3_bind_int64(statement, index, Int64(number))
            } else {
                sqlite3_bind_null(statement, index)
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw OpenCodeFixtureError.sql(String(cString: sqlite3_errmsg(handle)))
        }
    }

    func json(_ object: Any) throws -> String {
        guard JSONSerialization.isValidJSONObject(object) else { throw OpenCodeFixtureError.json }
        let encoded = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: encoded, as: UTF8.self)
    }

    // MARK: OpenCode 2

    func createV2(in name: String = "opencode.db") throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS project (id text PRIMARY KEY, worktree text NOT NULL);
            INSERT OR IGNORE INTO project (id, worktree) VALUES ('global', '/');
            CREATE TABLE session_v2 (id text PRIMARY KEY, project_id text NOT NULL, workspace_id text, parent_id text, fork_session_id text, slug text NOT NULL DEFAULT 's', directory text NOT NULL, title text, version text NOT NULL DEFAULT '2.2.6', revert text, time_created integer NOT NULL, time_updated integer NOT NULL, time_busy integer, time_idle integer, time_suspended integer);
            CREATE TABLE session_message (id text PRIMARY KEY, session_id text NOT NULL, type text NOT NULL, seq integer NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
            CREATE UNIQUE INDEX session_message_session_seq_idx ON session_message (session_id, seq);
            CREATE INDEX session_message_session_time_created_id_idx ON session_message (session_id, time_created, id);
            CREATE TABLE session_part (message_id text NOT NULL, session_id text NOT NULL, ordinal integer NOT NULL, type text NOT NULL, call_id text, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL, PRIMARY KEY (message_id, ordinal));
            CREATE INDEX session_part_session_message_idx ON session_part (session_id, message_id, ordinal);
            CREATE TABLE kv (key text PRIMARY KEY, value text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL);
            """, in: name)
    }

    func session(_ id: String, directory: URL, created: TimeInterval, parent: String? = nil, fork: String? = nil,
                 busy: TimeInterval? = nil, idle: TimeInterval? = nil, revert: String? = nil,
                 in name: String = "opencode.db") throws {
        let revertJSON = revert.map { "{\"messageID\":\"\($0)\",\"files\":[{\"file\":\"x\",\"patch\":\"PRIVATE_CONTENT_MARKER\"}]}" }
        let busyAt: Int64? = busy.map { ms($0) }
        let idleAt: Int64? = idle.map { ms($0) }
        try run("INSERT INTO session_v2 (id, project_id, parent_id, fork_session_id, directory, title, revert, time_created, time_updated, time_busy, time_idle) VALUES (?, 'global', ?, ?, ?, 'PRIVATE_PROMPT_MARKER', ?, ?, ?, ?, ?)",
                [id, parent, fork, directory.path, revertJSON, ms(created), ms(created), busyAt, idleAt], in: name)
    }

    func message(_ id: String, session: String, type: String = "assistant", seq: Int, created: TimeInterval,
                 data: [String: Any], in name: String = "opencode.db") throws {
        let text = try json(data)
        try run("INSERT INTO session_message (id, session_id, type, seq, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?, ?, ?)",
                [id, session, type, seq, ms(created), ms(created), text], in: name)
    }

    func part(_ message: String, session: String, ordinal: Int, item: [String: Any], in name: String = "opencode.db") throws {
        let text = try json(item)
        try run("INSERT INTO session_part (message_id, session_id, ordinal, type, call_id, time_created, time_updated, data) VALUES (?, ?, ?, 'tool', ?, ?, ?, ?)",
                [message, session, ordinal, item["id"] as? String, ms(0), ms(0), text], in: name)
    }

    /// OpenCode 2 finished importing the 1.x tables at `seconds`.
    func imported(at seconds: TimeInterval, in name: String = "opencode.db") throws {
        try run("INSERT INTO kv (key, value, time_created, time_updated) VALUES ('migration.v1-v2', '{\"phase\":\"completed\"}', ?, ?)",
                [ms(seconds), ms(seconds)], in: name)
    }

    func assistant(_ content: [[String: Any]], created: TimeInterval, completed: TimeInterval? = nil) -> [String: Any] {
        var time: [String: Any] = ["created": ms(created)]
        if let completed { time["completed"] = ms(completed) }
        return ["agent": "build", "model": ["id": "model", "providerID": "provider"], "content": content, "time": time]
    }

    func user(created: TimeInterval) -> [String: Any] {
        ["text": "PRIVATE_PROMPT_MARKER", "time": ["created": ms(created)]]
    }

    func text() -> [String: Any] { ["type": "text", "text": "PRIVATE_PROMPT_MARKER"] }

    /// An OpenCode 2 tool item.
    func tool(_ id: String, _ name: String, status: String = "completed", completed: TimeInterval? = nil,
              input: [String: Any] = [:], metadata: [String: Any]? = nil) -> [String: Any] {
        var state: [String: Any] = ["status": status, "input": input]
        if status == "completed" { state["content"] = [["type": "text", "text": "PRIVATE_OUTPUT_MARKER"]] }
        if status == "error" { state["error"] = ["type": "permission.rejected", "message": "PRIVATE_OUTPUT_MARKER"] }
        if let metadata { state["metadata"] = metadata }
        var time: [String: Any] = ["created": ms(0)]
        if let completed { time["completed"] = ms(completed) }
        return ["type": "tool", "id": id, "name": name, "state": state, "time": time]
    }

    /// OpenCode 2's `question` tool, which waits for the user's answer while running.
    func question(_ id: String, status: String, ran: TimeInterval? = nil) -> [String: Any] {
        var item = tool(id, "question", status: status, completed: status == "completed" ? 11 : nil,
                        input: ["questions": [["question": "PRIVATE_PROMPT_MARKER"]]])
        if let ran, var time = item["time"] as? [String: Any] {
            time["ran"] = ms(ran)
            item["time"] = time
        }
        return item
    }

    /// A FileDiff, as OpenCode 2's edit and patch record it.
    func diff(_ file: String) -> [String: Any] {
        ["file": file, "patch": "PRIVATE_CONTENT_MARKER", "additions": 1, "deletions": 1, "status": "modified"]
    }

    // MARK: OpenCode 1.x

    func createV1(in name: String = "opencode.db") throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS project (id text PRIMARY KEY, worktree text NOT NULL);
            INSERT OR IGNORE INTO project (id, worktree) VALUES ('global', '/');
            CREATE TABLE session (id text PRIMARY KEY, project_id text NOT NULL, workspace_id text, parent_id text, slug text NOT NULL DEFAULT 's', directory text NOT NULL, title text NOT NULL DEFAULT 't', version text NOT NULL DEFAULT '1.19.5', revert text, time_created integer NOT NULL, time_updated integer NOT NULL);
            CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
            CREATE INDEX message_session_time_created_id_idx ON message (session_id, time_created, id);
            CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);
            CREATE INDEX part_session_idx ON part (session_id);
            """, in: name)
    }

    func legacySession(_ id: String, directory: URL, created: TimeInterval, parent: String? = nil,
                       revert: (message: String, part: String?)? = nil) throws {
        var revertJSON: String?
        if let revert {
            var object: [String: Any] = ["messageID": revert.message, "diff": "PRIVATE_CONTENT_MARKER"]
            if let part = revert.part { object["partID"] = part }
            revertJSON = try json(object)
        }
        try run("INSERT INTO session (id, project_id, parent_id, directory, title, revert, time_created, time_updated) VALUES (?, 'global', ?, ?, 'PRIVATE_PROMPT_MARKER', ?, ?, ?)",
                [id, parent, directory.path, revertJSON, ms(created), ms(created)])
    }

    func legacyMessage(_ id: String, session: String, role: String = "assistant", created: TimeInterval,
                       completed: TimeInterval? = nil, cwd: URL? = nil) throws {
        var time: [String: Any] = ["created": ms(created)]
        if let completed { time["completed"] = ms(completed) }
        var object: [String: Any] = ["role": role, "time": time]
        if let cwd { object["path"] = ["cwd": cwd.path, "root": cwd.path] }
        let text = try json(object)
        try run("INSERT INTO message (id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?)",
                [id, session, ms(created), ms(created), text])
    }

    func legacyPart(_ id: String, message: String, session: String, created: TimeInterval, data: [String: Any]) throws {
        let text = try json(data)
        try run("INSERT INTO part (id, message_id, session_id, time_created, time_updated, data) VALUES (?, ?, ?, ?, ?, ?)",
                [id, message, session, ms(created), ms(created), text])
    }

    /// A 1.x tool part.
    func legacyTool(_ callID: String, _ tool: String, status: String = "completed", end: TimeInterval? = nil,
                    input: [String: Any] = [:], metadata: [String: Any] = [:]) -> [String: Any] {
        var time: [String: Any] = ["start": ms(0)]
        if let end { time["end"] = ms(end) }
        var state: [String: Any] = ["status": status, "input": input, "time": time]
        if status == "completed" {
            state["output"] = "PRIVATE_OUTPUT_MARKER"
            state["title"] = "t"
            state["metadata"] = metadata
        } else if status == "error" {
            state["error"] = "PRIVATE_OUTPUT_MARKER"
        }
        return ["type": "tool", "callID": callID, "tool": tool, "state": state]
    }

    func legacyText() -> [String: Any] { ["type": "text", "text": "PRIVATE_PROMPT_MARKER"] }
}
