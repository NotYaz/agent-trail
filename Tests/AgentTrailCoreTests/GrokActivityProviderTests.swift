import Foundation
import XCTest
@testable import AgentTrailCore

final class GrokActivityProviderTests: XCTestCase {
    func testWriteAndSearchReplaceCountButShellAndOutsidePathsDoNot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inside = fixture.project.appendingPathComponent("source.swift").path
        let outside = fixture.root.appendingPathComponent("elsewhere.swift").path
        try fixture.write(summary: true, updates: [
            fixture.call("write-1", name: "write", file: inside, seconds: 10),
            fixture.finish("write-1", status: "completed", absolute: inside, output: "SearchReplace", seconds: 11),
            fixture.call("shell", name: "run_terminal_command", file: inside, seconds: 12, extraInput: ["command": "PRIVATE_COMMAND_MARKER"]),
            fixture.finish("shell", status: "completed", absolute: nil, output: "Bash", seconds: 13),
            fixture.call("outside", name: "search_replace", file: outside, seconds: 14),
            fixture.finish("outside", status: "completed", absolute: outside, output: "SearchReplace", seconds: 15),
            fixture.call("pending", name: "write", file: inside, seconds: 16),
            fixture.finish("pending", status: "in_progress", absolute: nil, output: "SearchReplace", seconds: 17),
            fixture.call("failed", name: "search_replace", file: inside, seconds: 18),
            fixture.finish("failed", status: "failed", absolute: inside, output: "error", seconds: 19)
        ])
        let metadata = GrokActivityProvider().metadata(sources: [fixture.source])
        XCTAssertEqual(metadata.projects.count, 1)
        XCTAssertNil(metadata.projects[0].latestEdit)
        XCTAssertEqual(metadata.projects[0].path, fixture.project.path)
        let project = try XCTUnwrap(GrokActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.recordedEditCount, 1)
        XCTAssertEqual(project.sessionCount, 1)
        XCTAssertEqual(project.latestEdit?.latestEdit, fixture.date(11))
        XCTAssertNotEqual(project.path, fixture.slug)
    }

    func testEncodedDirectoryNameIsNotTheProjectAndContentStaysOutOfTheCache() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.project.appendingPathComponent("notes.swift").path
        try fixture.write(summary: true, title: "PRIVATE_TITLE_MARKER", updates: [
            fixture.call("edit", name: "search_replace", file: "notes.swift", seconds: 5, content: "PRIVATE_CONTENT_MARKER"),
            fixture.finish("edit", status: "completed", absolute: path, output: "SearchReplace", seconds: 6)
        ])
        let provider = GrokActivityProvider(cacheURL: fixture.cache)
        let project = try XCTUnwrap(provider.scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.path, fixture.project.path)
        XCTAssertEqual(project.recordedEditCount, 1)
        let cacheText = try String(contentsOf: fixture.cache, encoding: .utf8)
        XCTAssertFalse(cacheText.contains("PRIVATE_CONTENT_MARKER"))
        XCTAssertFalse(cacheText.contains("PRIVATE_TITLE_MARKER"))
        XCTAssertFalse(cacheText.contains("PRIVATE_COMMAND_MARKER"))
        XCTAssertEqual(provider.scan(sources: [fixture.source]).projects[0].recordedEditCount, 1)
    }

    func testMissingUpdatesStillListTheSession() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(summary: true, updates: nil)
        let result = GrokActivityProvider().scan(sources: [fixture.source])
        XCTAssertEqual(result.projects[0].sessionCount, 1)
        XCTAssertNil(result.projects[0].latestEdit)
        XCTAssertTrue(result.notices.contains { $0.contains("edit history is unavailable") })
    }

    func testSummaryWithoutAProjectPathIsOmitted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let summary = fixture.sessionDir.appendingPathComponent("summary.json")
        try FileManager.default.createDirectory(at: fixture.sessionDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["info": ["id": "ses", "cwd": "relative"], "created_at": fixture.stamp(0)]).write(to: summary)
        let result = GrokActivityProvider().scan(sources: [fixture.source])
        XCTAssertTrue(result.projects.isEmpty)
        XCTAssertTrue(result.notices.contains { $0.contains("no project path") })
    }

    func testUTCSessionDayUsesCreationAndEditsUseTheResult() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.project.appendingPathComponent("source.swift").path
        try fixture.write(summary: true, created: "2026-10-29T23:30:00Z", active: "2026-10-31T03:00:00Z", updates: [
            fixture.call("edit", name: "write", file: path, seconds: 0),
            fixture.finish("edit", status: "completed", absolute: path, output: "SearchReplace", timestamp: "2026-10-30T00:01:00.654321Z")
        ])
        let project = try XCTUnwrap(GrokActivityProvider().scan(sources: [fixture.source]).projects.first)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let creation = try XCTUnwrap(formatter.date(from: "2026-10-29T00:00:00Z"))
        let editDay = try XCTUnwrap(formatter.date(from: "2026-10-30T00:00:00Z"))
        XCTAssertEqual(project.history.first { $0.day == creation }?.sessionCount, 1)
        XCTAssertEqual(project.history.first { $0.day == editDay }?.editCount, 1)
        XCTAssertEqual(project.recordedEditCount, 1)
    }

    func testUnixSecondAndMillisecondTimestampsCount() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.project.appendingPathComponent("source.swift").path
        let seconds = Int(fixture.date(40).timeIntervalSince1970)
        let milliseconds = seconds * 1000 + 500
        try fixture.write(summary: true, updates: [
            fixture.call("seconds", name: "search_replace", file: path, seconds: 30),
            fixture.finish("seconds", status: "completed", absolute: path, output: "SearchReplace", timestamp: seconds),
            fixture.call("millis", name: "write", file: path, seconds: 31),
            fixture.finish("millis", status: "completed", absolute: path, output: "SearchReplace", timestamp: milliseconds)
        ])
        let project = try XCTUnwrap(GrokActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.recordedEditCount, 2)
        XCTAssertEqual(project.latestEdit?.latestEdit, Date(timeIntervalSince1970: Double(milliseconds) / 1000))
    }

    func testCompletedResultsRequirePositiveEditEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.project.appendingPathComponent("source.swift").path
        let outputs: [[String: Any]] = [
            [:],
            ["type": "SearchReplace"],
            ["type": "SearchReplace", "InvalidInput": "not applied"],
            ["type": "SearchReplace", "NoMatchesFound": [:]],
            ["type": "SearchReplace", "MultipleMatchesFound": [:]],
            ["type": "SearchReplace", "FileAlreadyExists": [:]],
            ["type": "SearchReplace", "FilenameTooLong": [:]],
            ["type": "SearchReplace", "EditsApplied": ["absolute_path": "relative.swift"]],
            ["type": "error", "EditsApplied": ["absolute_path": path]],
            ["type": "SearchReplace", "is_error": true, "EditsApplied": ["absolute_path": path]]
        ]
        var updates: [[String: Any]] = []
        for (index, output) in outputs.enumerated() {
            let id = "unconfirmed-\(index)"
            updates.append(fixture.call(id, name: index.isMultiple(of: 2) ? "write" : "search_replace", file: path, seconds: Double(index * 2)))
            updates.append(fixture.finish(id, status: "completed", rawOutput: output, seconds: Double(index * 2 + 1)))
        }
        try fixture.write(summary: true, updates: updates)
        let project = try XCTUnwrap(GrokActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.recordedEditCount, 0)
        XCTAssertNil(project.latestEdit)
    }

    func testEditsAppliedListRequiresEveryPathAndCountsOneOperation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.project.appendingPathComponent("source.swift").path
        let second = fixture.project.appendingPathComponent("second.swift").path
        let outside = fixture.root.appendingPathComponent("outside.swift").path
        let applied: [Any] = [
            [["absolute_path": path], ["absolute_path": second]],
            [["absolute_path": path], ["absolute_path": "relative.swift"]],
            [["absolute_path": path], [:]],
            [["absolute_path": path], "invalid member"],
            [["absolute_path": path], ["absolute_path": outside]],
            []
        ]
        var updates: [[String: Any]] = []
        for (index, paths) in applied.enumerated() {
            let id = "list-\(index)"
            updates.append(fixture.call(id, name: "search_replace", file: path, seconds: Double(index * 2)))
            updates.append(fixture.finish(id, status: "completed", rawOutput: ["type": "SearchReplace", "EditsApplied": paths], seconds: Double(index * 2 + 1)))
        }
        try fixture.write(summary: true, updates: updates)
        let project = try XCTUnwrap(GrokActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.recordedEditCount, 1)
        XCTAssertEqual(project.latestEdit?.latestEdit, fixture.date(1))
    }

    func testPendingCallAndPartialResultSurviveCacheReload() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.project.appendingPathComponent("source.swift").path
        try fixture.write(summary: true, updates: [fixture.call("edit", name: "write", file: path, seconds: 5)])
        let initial = GrokActivityProvider(cacheURL: fixture.cache)
        XCTAssertEqual(initial.scan(sources: [fixture.source]).projects[0].recordedEditCount, 0)

        let result = try JSONSerialization.data(withJSONObject: fixture.finish("edit", status: "completed", absolute: path, output: "SearchReplace", seconds: 6))
        let split = result.count / 2
        try fixture.append(Data(result.prefix(split)))
        let reloaded = GrokActivityProvider(cacheURL: fixture.cache)
        XCTAssertEqual(reloaded.scan(sources: [fixture.source]).projects[0].recordedEditCount, 0)
        try fixture.append(Data(result.suffix(result.count - split)))
        XCTAssertEqual(reloaded.scan(sources: [fixture.source]).projects[0].recordedEditCount, 0)
        try fixture.append(Data([0x0A]))
        let project = try XCTUnwrap(reloaded.scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.recordedEditCount, 1)
        XCTAssertEqual(project.latestEdit?.latestEdit, fixture.date(6))
        XCTAssertEqual(GrokActivityProvider(cacheURL: fixture.cache).scan(sources: [fixture.source]).projects[0].recordedEditCount, 1)
    }

    func testReplayedAndForkCopiedEditsKeepTheirFirstDate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.project.appendingPathComponent("source.swift").path
        try fixture.write(summary: true, updates: [
            fixture.call("original", name: "write", file: path, seconds: 5),
            fixture.finish("original", status: "completed", absolute: path, output: "SearchReplace", seconds: 6),
            fixture.call("original", name: "write", file: path, seconds: 86_405),
            fixture.finish("original", status: "completed", absolute: path, output: "SearchReplace", seconds: 86_406)
        ])
        try fixture.write(summary: true, updates: [
            fixture.call("original", name: "write", file: path, seconds: 172_805),
            fixture.finish("original", status: "completed", absolute: path, output: "SearchReplace", seconds: 172_806),
            fixture.call("fork-edit", name: "search_replace", file: path, seconds: 172_807),
            fixture.finish("fork-edit", status: "completed", absolute: path, output: "SearchReplace", seconds: 172_808)
        ], sessionID: "session-2")
        let provider = GrokActivityProvider(cacheURL: fixture.cache)
        let project = try XCTUnwrap(provider.scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.sessionCount, 2)
        XCTAssertEqual(project.recordedEditCount, 2)
        XCTAssertEqual(project.history.first { $0.day == ActivityDay.start(of: fixture.date(6)) }?.editCount, 1)
        XCTAssertNil(project.history.first { $0.day == ActivityDay.start(of: fixture.date(86_406)) })
        XCTAssertEqual(project.latestEdit?.latestEdit, fixture.date(172_808))
        XCTAssertEqual(GrokActivityProvider(cacheURL: fixture.cache).scan(sources: [fixture.source]).projects[0].recordedEditCount, 2)
    }

    func testPreviousCacheVersionRebuildsUnverifiedStoredEdits() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.project.appendingPathComponent("source.swift").path
        try fixture.write(summary: true, updates: [
            fixture.call("edit", name: "write", file: path, seconds: 5),
            fixture.finish("edit", status: "completed", absolute: path, output: "SearchReplace", seconds: 6)
        ])
        XCTAssertEqual(GrokActivityProvider(cacheURL: fixture.cache).scan(sources: [fixture.source]).projects[0].recordedEditCount, 1)
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cache)) as? [String: Any])
        var entries = try XCTUnwrap(saved["files"] as? [String: [String: Any]])
        let key = try XCTUnwrap(entries.keys.first)
        var entry = try XCTUnwrap(entries[key])
        var edits = try XCTUnwrap(entry["edits"] as? [String: Any])
        edits["unverified-old-edit"] = try XCTUnwrap(edits["edit"])
        entry["edits"] = edits
        entries[key] = entry
        saved["files"] = entries
        saved["version"] = 1
        try JSONSerialization.data(withJSONObject: saved).write(to: fixture.cache)

        let result = GrokActivityProvider(cacheURL: fixture.cache).scan(sources: [fixture.source])
        XCTAssertEqual(result.projects[0].recordedEditCount, 1)
        XCTAssertTrue(result.notices.contains { $0.contains("rebuilt once") })
    }
}

private final class Fixture {
    let root: URL
    let project: URL
    let slug = "not-the-project-path"
    let sessionDir: URL
    let cache: URL
    let source: AgentSource
    let base: Date

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-trail-grok-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        sessionDir = root.appendingPathComponent("sessions/\(slug)/session-1")
        cache = root.appendingPathComponent("cache/activity-cache-grok.json")
        source = AgentSource(id: "grok", name: "Grok", configDirectory: root.path, assistant: .grok)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        base = try XCTUnwrap(formatter.date(from: "2026-10-30T00:00:00Z"))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func date(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }
    func stamp(_ seconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date(seconds))
    }

    func call(_ id: String, name: String, file: String, seconds: TimeInterval, content: String = "body", extraInput: [String: Any] = [:]) -> [String: Any] {
        var input: [String: Any] = ["file_path": file, "content": content, "old_string": "old", "new_string": "new"]
        extraInput.forEach { input[$0] = $1 }
        return [
            "timestamp": stamp(seconds),
            "method": "session/update",
            "params": ["update": [
                "sessionUpdate": "tool_call",
                "toolCallId": id,
                "rawInput": input,
                "_meta": ["x.ai/tool": ["name": name, "kind": name == "run_terminal_command" ? "execute" : "write"]]
            ]]
        ]
    }

    func finish(_ id: String, status: String, absolute: String?, output: String, seconds: TimeInterval = 0, timestamp: Any? = nil) -> [String: Any] {
        var raw: [String: Any] = ["type": output]
        if let absolute { raw["EditsApplied"] = ["absolute_path": absolute, "new_string": "PRIVATE_CONTENT_MARKER"] }
        return finish(id, status: status, rawOutput: raw, seconds: seconds, timestamp: timestamp)
    }

    func finish(_ id: String, status: String, rawOutput: [String: Any], seconds: TimeInterval = 0, timestamp: Any? = nil) -> [String: Any] {
        return [
            "timestamp": timestamp ?? stamp(seconds),
            "method": "session/update",
            "params": ["update": [
                "sessionUpdate": "tool_call_update",
                "toolCallId": id,
                "status": status,
                "rawOutput": rawOutput
            ]]
        ]
    }

    func write(summary: Bool, title: String = "title", created: String? = nil, active: String? = nil, updates: [[String: Any]]?, sessionID: String = "session-1") throws {
        let directory = sessionDir.deletingLastPathComponent().appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if summary {
            let object: [String: Any] = [
                "info": ["id": sessionID, "cwd": project.path],
                "created_at": created ?? stamp(0),
                "last_active_at": active ?? stamp(30),
                "generated_title": title
            ]
            try JSONSerialization.data(withJSONObject: object).write(to: directory.appendingPathComponent("summary.json"))
        }
        guard let updates else { return }
        var data = Data()
        for update in updates {
            data.append(try JSONSerialization.data(withJSONObject: update))
            data.append(0x0A)
        }
        try data.write(to: directory.appendingPathComponent("updates.jsonl"))
    }

    func append(_ data: Data) throws {
        let handle = try FileHandle(forWritingTo: sessionDir.appendingPathComponent("updates.jsonl"))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
