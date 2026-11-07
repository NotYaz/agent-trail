import Foundation
import XCTest
@testable import AgentTrailCore

final class QwenActivityProviderTests: XCTestCase {
    private let id = "b1c2d3e4-f5a6-4b7c-8d9e-0f1a2b3c4d5e"

    func testSuccessfulEditToolResultsCountAtTheirRecordTimes() throws {
        let f = try QwenFixture()
        defer { f.remove() }
        let edited = f.project.appendingPathComponent("Sources/App.swift").path
        let created = f.project.appendingPathComponent("README.md").path
        let notebook = f.project.appendingPathComponent("analysis.ipynb").path
        try f.chat(id, [
            f.user(id, seconds: 1),
            f.call("e1", session: id, seconds: 2, file: edited),
            f.call("w1", name: "write_file", session: id, seconds: 3, file: created),
            f.toolResult("e1", session: id, seconds: 10, file: edited),
            f.toolResult("w1", name: "write_file", session: id, seconds: 11, file: created),
            f.call("n1", name: "notebook_edit", session: id, seconds: 12, file: notebook, argument: "notebook_path"),
            f.toolResult("n1", name: "notebook_edit", session: id, seconds: 13, file: notebook),
            // The legacy name of `edit`.
            f.call("r1", name: "replace", session: id, seconds: 14, file: edited),
            f.toolResult("r1", name: "replace", session: id, seconds: 15, file: edited)
        ])
        let result = f.provider().scan(sources: [f.source])
        let project = try XCTUnwrap(result.projects.first { $0.path == canonicalPath(f.project.path) })
        XCTAssertEqual(project.recordedEditCount, 4)
        XCTAssertEqual(project.sessionCount, 1)
        XCTAssertEqual(project.activities.first?.editMoments.map(\.date), [f.date(10), f.date(11), f.date(13), f.date(15)])
        XCTAssertEqual(result.sessionTrails.first?.sessionID, id)
        XCTAssertEqual(result.sessionTrails.first?.createdAt, f.date(1))
        XCTAssertEqual(result.notices, [])
    }

    func testFailedCancelledShellAndUnconfirmedResultsDoNotCount() throws {
        let f = try QwenFixture()
        defer { f.remove() }
        let file = f.project.appendingPathComponent("a.txt").path
        var unconfirmed = f.toolResult("e5", session: id, seconds: 15, file: file)
        unconfirmed["toolCallResult"] = ["callId": "e5"]
        try f.chat(id, [
            f.user(id, seconds: 1),
            f.call("e1", session: id, seconds: 2, file: file),
            f.toolResult("e1", status: "error", session: id, seconds: 11, file: nil, error: true),
            // A rejected approval is recorded as cancelled.
            f.call("e2", name: "write_file", session: id, seconds: 3, file: file),
            f.toolResult("e2", name: "write_file", status: "cancelled", session: id, seconds: 12, file: nil, error: true),
            f.call("e3", name: "run_shell_command", session: id, seconds: 4, file: file),
            f.toolResult("e3", name: "run_shell_command", session: id, seconds: 13, file: nil),
            f.call("e4", name: "read_file", session: id, seconds: 5, file: file),
            f.toolResult("e4", name: "read_file", session: id, seconds: 14, file: nil),
            // Outside a subagent transcript a result without a status is not confirmation.
            f.call("e5", session: id, seconds: 6, file: file),
            unconfirmed,
            // An approval still waiting: the call was never answered.
            f.call("e6", session: id, seconds: 7, file: file)
        ])
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 0)
        XCTAssertEqual(result.projects.first?.sessionCount, 1)
        XCTAssertEqual(result.notices, [])
    }

    func testEditsOutsideTheProjectDoNotCount() throws {
        let f = try QwenFixture()
        defer { f.remove() }
        let inside = f.project.appendingPathComponent("a.txt").path
        let outside = f.root.appendingPathComponent("elsewhere/b.txt").path
        try f.chat(id, [
            f.user(id, seconds: 1),
            f.call("e1", session: id, seconds: 2, file: inside),
            f.toolResult("e1", session: id, seconds: 10, file: inside),
            f.call("e2", session: id, seconds: 3, file: outside),
            f.toolResult("e2", session: id, seconds: 11, file: outside)
        ])
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects.count, 1)
        XCTAssertEqual(result.projects.first?.path, canonicalPath(f.project.path))
        XCTAssertEqual(result.projects.first?.activities.first?.editMoments.map(\.date), [f.date(10)])
    }

    func testCacheKeepsNoContentAndSurvivesReload() throws {
        let f = try QwenFixture()
        defer { f.remove() }
        let file = f.project.appendingPathComponent("a.txt").path
        var title = f.record("system", session: id, seconds: 20)
        title["subtype"] = "custom_title"
        title["systemPayload"] = ["customTitle": "PRIVATE_PROMPT_MARKER"]
        try f.chat(id, [
            f.user(id, seconds: 1),
            f.call("e1", session: id, seconds: 2, file: file),
            // A call still waiting for its result keeps only its name and folder.
            f.call("e2", session: id, seconds: 3, file: file),
            f.toolResult("e1", session: id, seconds: 10, file: file),
            title
        ])
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

    func testAppendAndRewrite() throws {
        let f = try QwenFixture()
        defer { f.remove() }
        let a = f.project.appendingPathComponent("a.txt").path
        let b = f.project.appendingPathComponent("b.txt").path
        try f.chat(id, [f.user(id, seconds: 1), f.call("e1", session: id, seconds: 2, file: a),
                        f.toolResult("e1", session: id, seconds: 10, file: a)])
        let provider = f.provider()
        XCTAssertEqual(provider.scan(sources: [f.source]).projects.first?.recordedEditCount, 1)
        // A result whose call came in an earlier scan still finds it.
        try f.chat(id, [f.call("e2", session: id, seconds: 20, file: b)], append: true)
        XCTAssertEqual(provider.scan(sources: [f.source]).projects.first?.recordedEditCount, 1)
        var result = f.toolResult("e2", session: id, seconds: 21, file: nil)
        result["toolCallResult"] = ["callId": "e2", "status": "success", "resultDisplay": "Updated b.txt"]
        try f.chat(id, [result], append: true)
        XCTAssertEqual(provider.scan(sources: [f.source]).projects.first?.recordedEditCount, 2)
        try f.chat(id, [f.user(id, seconds: 30), f.call("e3", session: id, seconds: 31, file: b),
                        f.toolResult("e3", session: id, seconds: 32, file: b)], atomic: true)
        let scanned = provider.scan(sources: [f.source])
        XCTAssertEqual(scanned.projects.first?.recordedEditCount, 1)
        XCTAssertEqual(scanned.projects.first?.activities.first?.editMoments.map(\.date), [f.date(32)])
    }

    func testMissingStoreGivesOneNotice() throws {
        let f = try QwenFixture()
        defer { f.remove() }
        let source = AgentSource(id: "qwen", name: "Qwen", configDirectory: f.root.appendingPathComponent("none").path,
                                 assistant: .qwen)
        XCTAssertEqual(f.provider().scan(sources: [source]).notices, ["Qwen: no local Qwen Code history was found."])
    }

    func testFileWithoutATurnIsNotASession() throws {
        let f = try QwenFixture()
        defer { f.remove() }
        // A CLI that was opened and closed writes only its startup records.
        var startup = f.record("system", session: id, seconds: 1)
        startup["subtype"] = "session_source"
        startup["systemPayload"] = ["sourceType": "cli"]
        try f.chat(id, [startup])
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects, [])
        XCTAssertEqual(result.notices, [])
    }

    func testForkedCopiesCountForTheSessionThatMadeThem() throws {
        let f = try QwenFixture()
        defer { f.remove() }
        let a = f.project.appendingPathComponent("a.txt").path
        let b = f.project.appendingPathComponent("b.txt").path
        let original = [f.user(id, seconds: 1), f.call("e1", session: id, seconds: 2, file: a),
                        f.toolResult("e1", session: id, seconds: 10, file: a)]
        try f.chat(id, original)
        // /branch copies every record under the new id, original times included.
        let fork = "f0f1f2f3-0000-4000-8000-000000000001"
        let copies = original.map { record -> [String: Any] in
            var copy = record
            copy["sessionId"] = fork
            let lineage: [String: Any] = ["sessionId": id, "messageUuid": record["uuid"] ?? ""]
            copy["forkedFrom"] = lineage
            return copy
        }
        try f.chat(fork, copies + [f.user(fork, seconds: 100), f.call("e2", session: fork, seconds: 101, file: b),
                                   f.toolResult("e2", session: fork, seconds: 105, file: b)])
        // A branch nobody continued holds only copies.
        try f.chat("f0f1f2f3-0000-4000-8000-000000000002", copies)
        let result = f.provider().scan(sources: [f.source])
        let project = try XCTUnwrap(result.projects.first)
        XCTAssertEqual(project.recordedEditCount, 2)
        XCTAssertEqual(project.sessionCount, 2)
        let trail = try XCTUnwrap(result.sessionTrails.first { $0.sessionID == fork })
        XCTAssertEqual(trail.createdAt, f.date(100))
        XCTAssertEqual(trail.edits.map(\.date), [f.date(105)])
        XCTAssertEqual(result.sessionTrails.first { $0.sessionID == id }?.edits.map(\.date), [f.date(10)])
    }

    func testSubagentTranscriptEditsAreDelegated() throws {
        let f = try QwenFixture()
        defer { f.remove() }
        let a = f.project.appendingPathComponent("a.txt").path
        let b = f.project.appendingPathComponent("b.txt").path
        try f.chat(id, [f.user(id, seconds: 1), f.call("e1", session: id, seconds: 2, file: a),
                        f.toolResult("e1", session: id, seconds: 10, file: a)])
        // Subagent transcripts record no status: `output` answers success, `error` failure.
        func sidechain(_ record: [String: Any]) -> [String: Any] {
            var record = record
            record["isSidechain"] = true
            record["agentId"] = "explore-7f3c"
            return record
        }
        var succeeded = f.toolResult("s1", session: id, seconds: 20, file: nil)
        succeeded["toolCallResult"] = ["callId": "s1", "durationMs": 12]
        var failed = f.toolResult("s2", session: id, seconds: 21, file: nil, error: true)
        failed["toolCallResult"] = ["callId": "s2", "durationMs": 3]
        try f.subagent(parent: id, agent: "explore-7f3c", [
            sidechain(f.call("s1", session: id, seconds: 15, file: b)),
            sidechain(succeeded),
            sidechain(f.call("s2", session: id, seconds: 16, file: a)),
            sidechain(failed)
        ])
        // A transcript whose session is gone stands alone.
        let gone = "deadbeef-0000-4000-8000-000000000000"
        var orphan = f.toolResult("s3", session: gone, seconds: 40, file: nil)
        orphan["toolCallResult"] = ["callId": "s3"]
        try f.subagent(parent: gone, agent: "plan-1", [sidechain(f.call("s3", session: gone, seconds: 39, file: b)), sidechain(orphan)])
        let result = f.provider().scan(sources: [f.source])
        let project = try XCTUnwrap(result.projects.first)
        XCTAssertEqual(project.recordedEditCount, 3)
        XCTAssertEqual(project.sessionCount, 2)
        XCTAssertEqual(project.activities.first?.editMoments.filter(\.delegated).map(\.date), [f.date(20), f.date(40)])
        XCTAssertEqual(result.sessionTrails.first { $0.sessionID == "agent-plan-1" }?.parentSessionID, gone)
    }

    func testArchivedSessionsAreRead() throws {
        let f = try QwenFixture()
        defer { f.remove() }
        let a = f.project.appendingPathComponent("a.txt").path
        let archived = "a0a1a2a3-0000-4000-8000-000000000003"
        try f.chat(id, [f.user(id, seconds: 1), f.call("e1", session: id, seconds: 2, file: a),
                        f.toolResult("e1", session: id, seconds: 10, file: a)])
        try f.chat(archived, [f.user(archived, seconds: 50), f.call("e2", session: archived, seconds: 51, file: a),
                              f.toolResult("e2", session: archived, seconds: 55, file: a)], archive: true)
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 2)
        XCTAssertEqual(result.projects.first?.sessionCount, 2)
    }

    func testParentSessionRecordMarksASpawnedSession() throws {
        let f = try QwenFixture()
        defer { f.remove() }
        let a = f.project.appendingPathComponent("a.txt").path
        let child = "c1c2c3c4-0000-4000-8000-000000000004"
        try f.chat(id, [f.user(id, seconds: 1)])
        var link = f.record("system", session: child, seconds: 5)
        link["subtype"] = "parent_session"
        link["systemPayload"] = ["parentSessionId": id]
        try f.chat(child, [link, f.call("e1", session: child, seconds: 6, file: a), f.toolResult("e1", session: child, seconds: 7, file: a)])
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.sessionTrails.first { $0.sessionID == child }?.parentSessionID, id)
        XCTAssertEqual(result.projects.first?.activities.first?.editMoments.filter(\.delegated).map(\.date), [f.date(7)])
    }

    func testRuntimeFolderOverrideIsRead() throws {
        let f = try QwenFixture()
        defer { f.remove() }
        let runtime = f.root.appendingPathComponent("runtime", isDirectory: true)
        let a = f.project.appendingPathComponent("a.txt").path
        try f.chat(id, [f.user(id, seconds: 1), f.call("e1", session: id, seconds: 2, file: a),
                        f.toolResult("e1", session: id, seconds: 10, file: a)], runtime: runtime)
        let source = AgentSource(id: "qwen", name: "Qwen", configDirectory: f.home.path, userDataDirectory: runtime.path,
                                 assistant: .qwen)
        XCTAssertEqual(f.provider().scan(sources: [source]).projects.first?.recordedEditCount, 1)
        XCTAssertEqual(f.provider().scan(sources: [f.source]).notices, ["Qwen: no local Qwen Code history was found."])
    }

    func testFlagsMustBeJSONBooleans() throws {
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"{"yes": true, "one": 1, "no": false}"#.utf8)) as? [String: Any])
        XCTAssertEqual(QwenActivityProvider.flag(object["yes"]), true)
        XCTAssertEqual(QwenActivityProvider.flag(object["no"]), false)
        XCTAssertNil(QwenActivityProvider.flag(object["one"]))
        XCTAssertNil(QwenActivityProvider.flag(object["missing"]))
    }
}

/// Synthetic Qwen Code stores in a temporary folder.
final class QwenFixture {
    let root: URL
    let project: URL
    let home: URL
    let cache: URL
    let source: AgentSource
    let base = Date(timeIntervalSince1970: 1_793_000_000)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-trail-qwen-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        home = root.appendingPathComponent("qwen-home", isDirectory: true)
        cache = root.appendingPathComponent("cache/activity-cache-qwen.json")
        source = AgentSource(id: "qwen", name: "Qwen", configDirectory: home.path, assistant: .qwen)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func provider() -> QwenActivityProvider { QwenActivityProvider(cacheURL: cache) }
    func date(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    func iso(_ seconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date(seconds))
    }

    /// `projects/<cwd with every non-alphanumeric character as "-">`, as Qwen names it.
    func projectFolder(_ cwd: String? = nil, runtime: URL? = nil) -> URL {
        let name = String((cwd ?? project.path).map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
        return (runtime ?? home).appendingPathComponent("projects", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    func record(_ type: String, session: String, seconds: TimeInterval, cwd: String? = nil) -> [String: Any] {
        ["uuid": UUID().uuidString, "parentUuid": NSNull(), "sessionId": session, "timestamp": iso(seconds), "type": type,
         "cwd": cwd ?? project.path, "version": "0.26.9", "gitBranch": "main"]
    }

    func user(_ session: String, seconds: TimeInterval) -> [String: Any] {
        var record = self.record("user", session: session, seconds: seconds)
        record["message"] = ["role": "user", "parts": [["text": "PRIVATE_PROMPT_MARKER"]]]
        return record
    }

    func call(_ id: String, name: String = "edit", session: String, seconds: TimeInterval, file: String,
              argument: String = "file_path") -> [String: Any] {
        var record = self.record("assistant", session: session, seconds: seconds)
        let call: [String: Any] = ["id": id, "name": name,
                                   "args": [argument: file, "old_string": "PRIVATE_CONTENT_MARKER", "new_string": "PRIVATE_CONTENT_MARKER"]]
        record["message"] = ["role": "model", "parts": [["text": "PRIVATE_PROMPT_MARKER"], ["functionCall": call]]]
        return record
    }

    /// One `tool_result` record as the scheduler writes it.
    func toolResult(_ id: String, name: String = "edit", status: String? = "success", session: String, seconds: TimeInterval,
                    file: String?, error: Bool = false) -> [String: Any] {
        var record = self.record("tool_result", session: session, seconds: seconds)
        let response: [String: Any] = error ? ["error": "PRIVATE_CONTENT_MARKER"] : ["output": "PRIVATE_CONTENT_MARKER"]
        let function: [String: Any] = ["id": id, "name": name, "response": response]
        record["message"] = ["role": "user", "parts": [["functionResponse": function]]]
        var info: [String: Any] = ["callId": id]
        if let status { info["status"] = status }
        if let file {
            let diff: [String: Any] = ["fileDiff": "PRIVATE_CONTENT_MARKER", "fileName": (file as NSString).lastPathComponent,
                                       "filePath": file, "originalContent": "PRIVATE_CONTENT_MARKER",
                                       "newContent": "PRIVATE_CONTENT_MARKER"]
            info["resultDisplay"] = diff
        }
        record["toolCallResult"] = info
        return record
    }

    @discardableResult
    func chat(_ id: String, _ lines: [[String: Any]], archive: Bool = false, append: Bool = false, atomic: Bool = false,
              runtime: URL? = nil) throws -> URL {
        var folder = projectFolder(runtime: runtime).appendingPathComponent("chats", isDirectory: true)
        if archive { folder = folder.appendingPathComponent("archive", isDirectory: true) }
        return try write(lines, to: folder.appendingPathComponent("\(id).jsonl"), append: append, atomic: atomic)
    }

    @discardableResult
    func subagent(parent: String, agent: String, _ lines: [[String: Any]]) throws -> URL {
        let folder = projectFolder().appendingPathComponent("subagents", isDirectory: true)
            .appendingPathComponent(parent, isDirectory: true)
        return try write(lines, to: folder.appendingPathComponent("agent-\(agent).jsonl"), append: false, atomic: false)
    }

    func write(_ lines: [[String: Any]], to url: URL, append: Bool, atomic: Bool) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for line in lines {
            data.append(try JSONSerialization.data(withJSONObject: line))
            data.append(10)
        }
        if append, let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url, options: atomic ? .atomic : [])
        }
        return url
    }
}
