import Foundation
import XCTest
@testable import AgentTrailCore

final class CopilotActivityProviderTests: XCTestCase {
    // MARK: VS Code chat

    func testAppliedEditToolCallCountsAtItsRequestsCompletion() throws {
        let f = try ChatFixture()
        defer { f.remove() }
        let file = f.project.appendingPathComponent("Sources/App.swift").path
        try f.chat("s1", lines: [
            f.snapshot("s1", created: 0),
            f.pushRequest("r1", started: 10),
            f.pushParts(0, [f.markdown(), f.editCall("call-1", file: file)]),
            f.setModelState(0, completed: 30)
        ])
        try f.editing("s1", operations: [f.operation("r1", file: file, epoch: 1)], currentEpoch: 2)
        let result = f.provider().scan(sources: [f.source])
        let project = try XCTUnwrap(result.projects.first { $0.path == canonicalPath(f.project.path) })
        XCTAssertEqual(project.recordedEditCount, 1)
        XCTAssertEqual(project.sessionCount, 1)
        XCTAssertEqual(project.activities.first?.editMoments.map(\.date), [f.date(30)])
        XCTAssertEqual(result.notices, [])
    }

    func testOnlyAppliedKeptEditsCount() throws {
        let f = try ChatFixture()
        defer { f.remove() }
        let kept = f.project.appendingPathComponent("kept.txt").path
        let restored = f.project.appendingPathComponent("restored.txt").path
        let rejected = f.project.appendingPathComponent("rejected.txt").path
        let undone = f.project.appendingPathComponent("undone.txt").path
        let proposed = f.project.appendingPathComponent("never-applied.txt").path
        try f.chat("s1", lines: [
            f.snapshot("s1", created: 0),
            f.pushRequest("r1", started: 10),
            f.pushParts(0, [f.editCall("a", file: kept), f.editCall("b", file: restored), f.editCall("c", file: rejected),
                            f.editCall("d", file: undone), f.editCall("e", file: proposed)]),
            f.setModelState(0, completed: 20),
            // The next request records that the user undid one file.
            f.pushRequest("r2", started: 40, undone: [undone]),
            f.setModelState(1, completed: 50)
        ])
        try f.editing("s1", operations: [
            f.operation("r1", file: kept, epoch: 1),
            // At or after the current epoch: undone by restoring a checkpoint.
            f.operation("r1", file: restored, epoch: 5),
            f.operation("r1", file: rejected, epoch: 2),
            f.operation("r1", file: undone, epoch: 3)
        ], currentEpoch: 5, rejected: [("r1", rejected)])
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 1)
        XCTAssertEqual(result.sessionTrails.first?.edits.count, 1)
    }

    func testEachCallIsOneEditAndUnnamedAppliedFilesCountOncePerRequest() throws {
        let f = try ChatFixture()
        defer { f.remove() }
        let one = f.project.appendingPathComponent("one.txt").path
        let two = f.project.appendingPathComponent("two.txt").path
        try f.chat("s1", lines: [
            f.snapshot("s1", created: 0),
            f.pushRequest("r1", started: 10),
            // Two calls on one file, and a call whose message names no file (older logs).
            f.pushParts(0, [f.editCall("a", file: one), f.editCall("b", file: one), f.editCall("c", file: nil)]),
            f.setModelState(0, completed: 20)
        ])
        try f.editing("s1", operations: [
            f.operation("r1", file: one, epoch: 1), f.operation("r1", file: one, epoch: 1),
            f.operation("r1", file: two, epoch: 2), f.operation("r1", file: two, epoch: 2)
        ], currentEpoch: 3)
        XCTAssertEqual(f.provider().scan(sources: [f.source]).projects.first?.recordedEditCount, 3)
    }

    func testMutationLogReplayFollowsTruncationIndexesAndCompaction() throws {
        let f = try ChatFixture()
        defer { f.remove() }
        let file = f.project.appendingPathComponent("a.txt").path
        let other = f.project.appendingPathComponent("b.txt").path
        // Request indexes 0 and 1 are the JSON numbers 0 and 1, which Foundation
        // also bridges to Bool; they must still address the requests.
        try f.chat("s1", lines: [
            f.snapshot("s1", created: 0),
            f.pushRequest("r1", started: 10),
            f.pushParts(0, [f.markdown(), f.editCall("gone", file: other)]),
            // Rewrites the tail from index 1: the first call is replaced.
            f.pushParts(0, [f.editCall("kept", file: file)], truncate: 1),
            f.setModelState(0, completed: 20),
            f.pushRequest("r2", started: 30),
            f.setModelState(1, completed: 40)
        ])
        try f.editing("s1", operations: [f.operation("r1", file: file, epoch: 1), f.operation("r1", file: other, epoch: 1)],
                      currentEpoch: 2)
        let provider = f.provider()
        var result = provider.scan(sources: [f.source])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 2, "kept call plus the unnamed applied file")
        XCTAssertEqual(result.sessionTrails.first?.latestActivity, f.date(40))
        XCTAssertEqual(result.notices, [])

        // Compaction replaces the file with one snapshot holding the same chat.
        var compacted = f.snapshot("s1", created: 0)
        var v = compacted["v"] as! [String: Any]
        v["requests"] = [f.request("r1", started: 10, completed: 20, parts: [f.markdown(), f.editCall("kept", file: file)])]
        compacted["v"] = v
        try f.chat("s1", lines: [compacted])
        result = provider.scan(sources: [f.source])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 2)
        XCTAssertEqual(result.sessionTrails.first?.latestActivity, f.date(20))
    }

    func testRemoteFolderlessAndEmptyChatsAreSkipped() throws {
        let f = try ChatFixture()
        defer { f.remove() }
        let file = f.project.appendingPathComponent("a.txt").path
        let lines = [f.snapshot("s1", created: 0), f.pushRequest("r1", started: 10),
                     f.pushParts(0, [f.editCall("a", file: file)]), f.setModelState(0, completed: 20)]
        try f.chat("s1", lines: lines, workspace: ["folder": "vscode-remote://ssh-remote+7b7d/home/me/project"])
        try f.editing("s1", operations: [f.operation("r1", file: file, epoch: 1)], currentEpoch: 2)
        try f.chat("s2", lines: lines, workspace: [:], storage: "folderless")
        try f.chat("s3", lines: [f.snapshot("s3", created: 0)], storage: "empty-chat")
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects, [])
        XCTAssertEqual(result.notices, [])
    }

    func testMultiRootWorkspaceFileWithCommentsAndTrailingCommas() throws {
        let f = try ChatFixture()
        defer { f.remove() }
        let second = f.root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let workspaceFile = f.root.appendingPathComponent("pair.code-workspace")
        try """
        {
          // Two folders, one relative.
          "folders": [
            { "path": "project" },
            { "path": "\(second.path)", },
          ],
          /* settings */ "settings": {},
        }
        """.write(to: workspaceFile, atomically: true, encoding: .utf8)
        let file = second.appendingPathComponent("b.txt").path
        try f.chat("s1", lines: [f.snapshot("s1", created: 0), f.pushRequest("r1", started: 10),
                                 f.pushParts(0, [f.editCall("a", file: file)]), f.setModelState(0, completed: 20)],
                   workspace: ["workspace": URL(fileURLWithPath: workspaceFile.path).absoluteString])
        try f.editing("s1", operations: [f.operation("r1", file: file, epoch: 1)], currentEpoch: 2)
        XCTAssertEqual(VSCodeWorkspace.codeWorkspaceFolders(workspaceFile),
                       [ProjectLocationRegistry.lexicalPath(f.project.path)!, ProjectLocationRegistry.lexicalPath(second.path)!])
        let result = f.provider().scan(sources: [f.source])
        // The second folder is no checkout, so its edit stays with the window's first folder.
        let trail = try XCTUnwrap(result.sessionTrails.first)
        XCTAssertEqual(trail.edits.count, 1)
        XCTAssertEqual(trail.edits.first?.projectPath, canonicalPath(f.project.path))
    }

    func testCacheKeepsNoContentAndSurvivesReload() throws {
        let f = try ChatFixture()
        defer { f.remove() }
        let file = f.project.appendingPathComponent("a.txt").path
        try f.chat("s1", lines: [f.snapshot("s1", created: 0), f.pushRequest("r1", started: 10),
                                 f.pushParts(0, [f.markdown(), f.editCall("a", file: file)]), f.setModelState(0, completed: 20)])
        try f.editing("s1", operations: [f.operation("r1", file: file, epoch: 1)], currentEpoch: 2)
        let provider = f.provider()
        XCTAssertEqual(provider.scan(sources: [f.source]).projects.first?.recordedEditCount, 1)
        XCTAssertNil(provider.saveCache())
        let saved = try String(contentsOf: f.cache, encoding: .utf8)
        XCTAssertFalse(saved.contains("PRIVATE_PROMPT_MARKER"))
        XCTAssertFalse(saved.contains("PRIVATE_CONTENT_MARKER"))
        let reloaded = f.provider()
        XCTAssertEqual(reloaded.metadata(sources: [f.source]).projects.first?.recordedEditCount, 1)
        XCTAssertEqual(reloaded.scan(sources: [f.source]).projects.first?.recordedEditCount, 1)
    }

    func testUnknownEditingStateVersionIsReportedNotGuessed() throws {
        let f = try ChatFixture()
        defer { f.remove() }
        let file = f.project.appendingPathComponent("a.txt").path
        try f.chat("s1", lines: [f.snapshot("s1", created: 0), f.pushRequest("r1", started: 10),
                                 f.pushParts(0, [f.editCall("a", file: file)]), f.setModelState(0, completed: 20)])
        try f.editing("s1", operations: [f.operation("r1", file: file, epoch: 1)], currentEpoch: 2, version: 9)
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 0)
        XCTAssertEqual(result.projects.first?.sessionCount, 1)
        XCTAssertTrue(result.notices.contains { $0.contains("format this version doesn't read") }, "\(result.notices)")
    }

    // MARK: Copilot CLI

    func testCLISuccessfulEditsCountAndFailuresShellAndReplaysDoNot() throws {
        let f = try ChatFixture()
        defer { f.remove() }
        let edited = f.project.appendingPathComponent("edited.txt").path
        let created = f.project.appendingPathComponent("created.txt").path
        let failed = f.project.appendingPathComponent("failed.txt").path
        let id = "8b2f9c1e-3a4d-4e5f-9a6b-7c8d9e0f1a2b"
        try f.cli(id, events: [
            f.event("session.start", seconds: 0, data: ["sessionId": id, "context": ["cwd": f.project.path]]),
            f.event("assistant.turn_start", seconds: 1, data: ["turnId": "t1"]),
            f.event("tool.execution_start", seconds: 2, data: ["toolCallId": "e1", "toolName": "edit",
                "arguments": ["path": edited, "old_str": "PRIVATE_CONTENT_MARKER", "new_str": "x"]]),
            f.event("tool.execution_complete", seconds: 3, data: ["toolCallId": "e1", "success": true]),
            // fileEdits names the committed files, whatever the tool.
            f.event("tool.execution_start", seconds: 4, data: ["toolCallId": "e2", "toolName": "apply_patch", "arguments": [:]]),
            f.event("tool.execution_complete", seconds: 5, data: ["toolCallId": "e2", "success": true,
                "fileEdits": [["path": created, "kind": "create"]]]),
            f.event("tool.execution_start", seconds: 6, data: ["toolCallId": "e3", "toolName": "create", "arguments": ["path": failed]]),
            f.event("tool.execution_complete", seconds: 7, data: ["toolCallId": "e3", "success": false, "error": ["code": "denied"]]),
            f.event("tool.execution_start", seconds: 8, data: ["toolCallId": "e4", "toolName": "bash", "arguments": ["command": "touch x"]]),
            f.event("tool.execution_complete", seconds: 9, data: ["toolCallId": "e4", "success": true]),
            // A subagent's edit is delegated.
            f.event("tool.execution_start", seconds: 10, data: ["toolCallId": "e5", "toolName": "edit", "arguments": ["path": edited]],
                    agentID: "agent-1"),
            f.event("tool.execution_complete", seconds: 11, data: ["toolCallId": "e5", "success": true], agentID: "agent-1"),
            // Replayed history at a rotated journal's head is not new evidence.
            f.event("tool.execution_complete", seconds: 12, data: ["toolCallId": "e6", "success": true,
                "fileEdits": [["path": edited, "kind": "edit"]]], checkpoint: true)
        ])
        try f.cli("optimistic-chat-1", events: [f.event("session.start", seconds: 0, data: ["context": ["cwd": f.project.path]])])
        let result = f.provider().scan(sources: [f.source])
        let project = try XCTUnwrap(result.projects.first)
        XCTAssertEqual(project.recordedEditCount, 3)
        XCTAssertEqual(project.sessionCount, 1)
        XCTAssertEqual(project.activities.first?.editMoments.filter(\.delegated).map(\.date), [f.date(11)])
        XCTAssertEqual(result.sessionTrails.first?.sessionID, id)
        XCTAssertNil(f.provider().saveCache())
    }

    func testCLIFallsBackToWorkspaceYAMLWhenEventsNameNoFolder() throws {
        let f = try ChatFixture()
        defer { f.remove() }
        let id = "1b2f9c1e-3a4d-4e5f-9a6b-7c8d9e0f1a2b"
        let file = f.project.appendingPathComponent("a.txt").path
        try f.cli(id, events: [
            f.event("tool.execution_start", seconds: 2, data: ["toolCallId": "e1", "toolName": "create", "arguments": ["path": file]]),
            f.event("tool.execution_complete", seconds: 3, data: ["toolCallId": "e1", "success": true])
        ], yaml: "id: \(id)\ncwd: \"\(f.project.path)\"\nsummary: |\n  multi\n  line\n")
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects.first?.path, canonicalPath(f.project.path))
        XCTAssertEqual(result.projects.first?.recordedEditCount, 1)
    }

    func testMissingStoresGiveOneNotice() throws {
        let f = try ChatFixture()
        defer { f.remove() }
        let source = AgentSource(id: "copilot", name: "Copilot", configDirectory: f.root.appendingPathComponent("none").path,
                                 userDataDirectory: f.root.appendingPathComponent("no-code").path, assistant: .copilot)
        XCTAssertEqual(f.provider().scan(sources: [source]).notices,
                       ["Copilot: no local Copilot Chat or Copilot CLI history was found."])
    }

    func testDefaultProfileReadsVSCodeDefaultFolder() {
        let source = AgentSource(id: "copilot", name: "Copilot", configDirectory: "~/.copilot", assistant: .copilot)
        XCTAssertEqual(CopilotActivityProvider.vsCodeFolder(source)?.path,
                       ("~/Library/Application Support/Code" as NSString).expandingTildeInPath)
        let custom = AgentSource(id: "copilot-work", name: "Work", configDirectory: "~/.copilot-work", assistant: .copilot)
        XCTAssertNil(CopilotActivityProvider.vsCodeFolder(custom))
    }
}

/// Synthetic VS Code and Copilot CLI stores in a temporary folder.
final class ChatFixture {
    let root: URL
    let project: URL
    let userData: URL
    let home: URL
    let cache: URL
    let source: AgentSource
    let base = Date(timeIntervalSince1970: 1_793_000_000)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-trail-copilot-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        userData = root.appendingPathComponent("Code", isDirectory: true)
        home = root.appendingPathComponent("copilot-home", isDirectory: true)
        cache = root.appendingPathComponent("cache/activity-cache-copilot.json")
        source = AgentSource(id: "copilot", name: "Copilot", configDirectory: home.path, userDataDirectory: userData.path,
                             assistant: .copilot)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func provider() -> CopilotActivityProvider { CopilotActivityProvider(cacheURL: cache) }
    func date(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }
    func ms(_ seconds: TimeInterval) -> Int { Int(date(seconds).timeIntervalSince1970 * 1000) }

    // Chat log records.

    func snapshot(_ id: String, created: TimeInterval) -> [String: Any] {
        ["kind": 0, "v": ["version": 3, "sessionId": id, "creationDate": ms(created), "requests": [],
                          "inputState": ["inputText": "PRIVATE_PROMPT_MARKER"]]]
    }

    func request(_ id: String, started: TimeInterval, completed: TimeInterval? = nil, parts: [[String: Any]] = [],
                 undone: [String] = []) -> [String: Any] {
        var request: [String: Any] = ["requestId": id, "timestamp": ms(started), "response": parts,
                                      "message": ["text": "PRIVATE_PROMPT_MARKER"]]
        if let completed { request["modelState"] = ["value": 1, "completedAt": ms(completed)] }
        if !undone.isEmpty {
            request["editedFileEvents"] = undone.map { ["uri": ["$mid": 1, "scheme": "file", "path": $0], "eventKind": 2] }
        }
        return request
    }

    func pushRequest(_ id: String, started: TimeInterval, undone: [String] = []) -> [String: Any] {
        ["kind": 2, "k": ["requests"], "v": [request(id, started: started, undone: undone)]]
    }

    func pushParts(_ index: Int, _ parts: [[String: Any]], truncate: Int? = nil) -> [String: Any] {
        var entry: [String: Any] = ["kind": 2, "k": ["requests", index, "response"], "v": parts]
        if let truncate { entry["i"] = truncate }
        return entry
    }

    func setModelState(_ index: Int, completed: TimeInterval) -> [String: Any] {
        ["kind": 1, "k": ["requests", index, "modelState"], "v": ["value": 1, "completedAt": ms(completed)]]
    }

    func markdown() -> [String: Any] { ["value": "PRIVATE_PROMPT_MARKER"] }

    func editCall(_ id: String, file: String?) -> [String: Any] {
        var message: [String: Any] = ["value": "Editing"]
        if let file {
            message["uris"] = [URL(fileURLWithPath: file).absoluteString: ["$mid": 1, "scheme": "file", "path": file]]
        }
        return ["kind": "toolInvocationSerialized", "toolId": "copilot_replaceString", "toolCallId": id,
                "invocationMessage": message, "isComplete": true, "isConfirmed": ["type": 1]]
    }

    func chat(_ id: String, lines: [[String: Any]], workspace: [String: Any]? = nil, storage: String = "hash1") throws {
        let folder = userData.appendingPathComponent("User/workspaceStorage/\(storage)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("chatSessions"), withIntermediateDirectories: true)
        let record = workspace ?? ["folder": URL(fileURLWithPath: project.path).absoluteString]
        try JSONSerialization.data(withJSONObject: record).write(to: folder.appendingPathComponent("workspace.json"))
        var data = Data()
        for line in lines {
            data.append(try JSONSerialization.data(withJSONObject: line))
            data.append(10)
        }
        try data.write(to: folder.appendingPathComponent("chatSessions/\(id).jsonl"))
    }

    func operation(_ request: String, file: String, epoch: Int) -> [String: Any] {
        ["type": "textEdit", "requestId": request, "epoch": epoch,
         "uri": ["$mid": 1, "scheme": "file", "path": file, "fsPath": file], "edits": [["text": "PRIVATE_CONTENT_MARKER"]]]
    }

    func editing(_ id: String, operations: [[String: Any]], currentEpoch: Int, rejected: [(String, String)] = [],
                 version: Int = 2, storage: String = "hash1") throws {
        let folder = userData.appendingPathComponent("User/workspaceStorage/\(storage)/chatEditingSessions/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let entries: [[String: Any]] = rejected.map { request, path in
            ["resource": URL(fileURLWithPath: path).absoluteString, "state": 2, "telemetryInfo": ["requestId": request]]
        }
        let object: [String: Any] = ["version": version,
            "initialFileContents": [["file:///x", "PRIVATE_CONTENT_MARKER"]],
            "timeline": ["operations": operations, "currentEpoch": currentEpoch, "checkpoints": [], "epochCounter": currentEpoch],
            "recentSnapshot": ["entries": entries]]
        try JSONSerialization.data(withJSONObject: object).write(to: folder.appendingPathComponent("state.json"))
    }

    // Copilot CLI records.

    func event(_ type: String, seconds: TimeInterval, data: [String: Any], agentID: String? = nil,
               checkpoint: Bool = false) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var event: [String: Any] = ["type": type, "id": UUID().uuidString, "timestamp": formatter.string(from: date(seconds)),
                                    "data": data]
        if let agentID { event["agentId"] = agentID }
        if checkpoint { event["checkpoint"] = true }
        return event
    }

    @discardableResult
    func cli(_ id: String, events: [[String: Any]], yaml: String? = nil, append: Bool = false) throws -> URL {
        let folder = home.appendingPathComponent("session-state/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var data = Data()
        for event in events {
            data.append(try JSONSerialization.data(withJSONObject: event))
            data.append(10)
        }
        let url = folder.appendingPathComponent("events.jsonl")
        if append, let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url)
        }
        if let yaml { try yaml.write(to: folder.appendingPathComponent("workspace.yaml"), atomically: true, encoding: .utf8) }
        return folder
    }
}
