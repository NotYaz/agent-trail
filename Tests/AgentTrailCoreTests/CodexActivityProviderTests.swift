import Foundation
import XCTest
@testable import AgentTrailCore

final class CodexActivityProviderTests: XCTestCase {
    func testOnlyCompletedFileChangesInsideTheCheckoutCount() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inside = fixture.project.appendingPathComponent("source.swift").path
        let outside = fixture.root.appendingPathComponent("elsewhere/file.swift").path
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("good", status: "completed", files: [inside: "update"], seconds: 10),
            fixture.fileChange("failed", status: "failed", files: [inside: "update"], seconds: 20),
            fixture.fileChange("outside", status: "completed", files: [outside: "add"], seconds: 30),
            fixture.shell(seconds: 40)
        ])
        let metadata = CodexActivityProvider().metadata(sources: [fixture.source])
        XCTAssertEqual(metadata.projects.count, 1)
        XCTAssertNil(metadata.projects[0].latestEdit)
        XCTAssertEqual(metadata.projects[0].sessionCount, 1)
        let project = try XCTUnwrap(CodexActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.path, fixture.project.path)
        XCTAssertEqual(project.recordedEditCount, 1)
        XCTAssertEqual(project.latestEdit?.latestEdit, fixture.date(10))
        XCTAssertEqual(project.latestEdit?.latestEditWorkspacePath, fixture.project.path)
        XCTAssertEqual(project.sessionCount, 1)
    }

    func testReplayAppendAndCacheDoNotStoreTheDiff() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.project.appendingPathComponent("source.swift").path
        let change = fixture.fileChange("replayed", status: "completed", files: [path: "update"], seconds: 10)
        try fixture.write(fixture.sessionLines() + [change, change])
        let copied = fixture.root.appendingPathComponent("archived_sessions/2026/10/30/rollout-copy.jsonl")
        try fixture.write(fixture.sessionLines() + [change], to: copied)
        let provider = CodexActivityProvider(cacheURL: fixture.cache)
        XCTAssertEqual(provider.scan(sources: [fixture.source]).projects[0].recordedEditCount, 1)
        let cacheText = try String(contentsOf: fixture.cache, encoding: .utf8)
        XCTAssertFalse(cacheText.contains("PRIVATE_DIFF_MARKER"))
        XCTAssertFalse(cacheText.contains("PRIVATE_COMMAND_MARKER"))
        try fixture.append([change])
        let relaunched = CodexActivityProvider(cacheURL: fixture.cache)
        XCTAssertEqual(relaunched.scan(sources: [fixture.source]).projects[0].recordedEditCount, 1)
        try fixture.append([fixture.fileChange("added", status: "completed", files: [path: "add"], seconds: 50)])
        XCTAssertEqual(relaunched.scan(sources: [fixture.source]).projects[0].recordedEditCount, 2)
    }

    func testUTCHistoryAndExternalTurnAreSeparate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.project.appendingPathComponent("source.swift").path
        var created = fixture.sessionLines(timestamp: "2026-10-29T23:30:00Z")
        created.append(fixture.fileChange("before", status: "completed", files: [path: "update"],
            timestamp: "2026-10-30T02:59:00.000+03:00"))
        created.append(fixture.fileChange("after", status: "completed", files: [path: "update"],
            timestamp: "2026-10-30T00:01:00Z"))
        try fixture.write(created)
        let project = try XCTUnwrap(CodexActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.recordedEditCount, 2)
        XCTAssertEqual(project.sessionCount, 1)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let creationDay = try XCTUnwrap(formatter.date(from: "2026-10-29T00:00:00Z"))
        let editDay = try XCTUnwrap(formatter.date(from: "2026-10-30T00:00:00Z"))
        XCTAssertEqual(project.history.first { $0.day == creationDay }?.sessionCount, 1)
        XCTAssertEqual(project.history.first { $0.day == creationDay }?.editCount, 1)
        XCTAssertEqual(project.history.first { $0.day == editDay }?.editCount, 1)

        let external = fixture.root.appendingPathComponent("other-repository")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let outside = external.appendingPathComponent("outside.swift").path
        try fixture.append([
            fixture.turn(external.path),
            fixture.fileChange("external", status: "completed", files: [outside: "add"], seconds: 80)
        ])
        let rescanned = try XCTUnwrap(CodexActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(rescanned.recordedEditCount, 2)
        XCTAssertEqual(rescanned.path, fixture.project.path)
    }

    func testWorktreeTurnKeepsTheSessionProject() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let worktree = fixture.project.appendingPathComponent(".codex/worktrees/feature")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let edited = worktree.appendingPathComponent("new.swift").path
        try fixture.write(fixture.sessionLines(roots: [fixture.project.path, worktree.path]) + [
            fixture.turn(worktree.path),
            fixture.fileChange("tree", status: "completed", files: [edited: "add"], seconds: 15)
        ])
        let project = try XCTUnwrap(CodexActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.path, fixture.project.path)
        XCTAssertEqual(project.recordedEditCount, 1)
        XCTAssertEqual(project.latestEdit?.latestEditWorkspacePath, worktree.path)
    }

    func testMoveOutsideTheCheckoutDoesNotCount() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.project.appendingPathComponent("source.swift").path
        let destination = fixture.root.appendingPathComponent("elsewhere/source.swift").path
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("outside-move", status: "completed", files: [path: "update"],
                moves: [path: destination], seconds: 10)
        ])
        let project = try XCTUnwrap(CodexActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.recordedEditCount, 0)
        XCTAssertNil(project.latestEdit)
    }

    func testMoveWithinTheCheckoutCounts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.project.appendingPathComponent("source.swift").path
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("inside-move", status: "completed", files: [path: "update"],
                moves: [path: "renamed.swift"], seconds: 10)
        ])
        let project = try XCTUnwrap(CodexActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.recordedEditCount, 1)
        XCTAssertEqual(project.latestEdit?.latestEditWorkspacePath, fixture.project.path)
    }

    func testVersionOneCacheIsRebuiltForDestinationAndWorkspaceValidation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.project.appendingPathComponent("source.swift").path
        let destination = fixture.root.appendingPathComponent("elsewhere/source.swift").path
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("old-outside-move", status: "completed", files: [path: "update"],
                moves: [path: destination], seconds: 10)
        ])
        _ = CodexActivityProvider(cacheURL: fixture.cache).scan(sources: [fixture.source])
        var oldCache = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cache)) as? [String: Any])
        var oldFiles = try XCTUnwrap(oldCache["files"] as? [String: Any])
        let rolloutKey = try XCTUnwrap(oldFiles.keys.first { canonicalPath($0) == canonicalPath(fixture.rollout.path) })
        var oldFile = try XCTUnwrap(oldFiles[rolloutKey] as? [String: Any])
        oldFile["edits"] = ["old-outside-move": ["date": fixture.date(10).timeIntervalSinceReferenceDate, "workspace": fixture.project.path]]
        oldFiles[rolloutKey] = oldFile
        oldCache["files"] = oldFiles
        oldCache["version"] = 1
        try JSONSerialization.data(withJSONObject: oldCache).write(to: fixture.cache)

        let result = CodexActivityProvider(cacheURL: fixture.cache).scan(sources: [fixture.source])
        let project = try XCTUnwrap(result.projects.first)
        XCTAssertEqual(project.recordedEditCount, 0)
        XCTAssertNil(project.latestEdit)
        XCTAssertTrue(result.notices.contains { $0.contains("rebuilt once") })
        let rebuiltCache = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cache)) as? [String: Any])
        XCTAssertEqual(rebuiltCache["version"] as? Int, 2)
    }

    func testNestedWorkspaceRootIsPreservedWithoutATurnCwdChange() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let worktree = fixture.project.appendingPathComponent(".codex/worktrees/feature")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let path = worktree.appendingPathComponent("source.swift").path
        try fixture.write(fixture.sessionLines(roots: [fixture.project.path, worktree.path]) + [
            fixture.fileChange("nested", status: "completed", files: [path: "add"], seconds: 10)
        ])
        let project = try XCTUnwrap(CodexActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.path, fixture.project.path)
        XCTAssertEqual(project.recordedEditCount, 1)
        XCTAssertEqual(project.latestEdit?.latestEditWorkspacePath, worktree.path)
    }

    func testChangesAcrossKnownWorkspacesAreOmitted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.project.appendingPathComponent(".codex/worktrees/first")
        let second = fixture.project.appendingPathComponent(".codex/worktrees/second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let originPath = fixture.project.appendingPathComponent("source.swift").path
        let firstPath = first.appendingPathComponent("source.swift").path
        let secondPath = second.appendingPathComponent("source.swift").path
        try fixture.write(fixture.sessionLines(roots: [fixture.project.path, first.path, second.path]) + [
            fixture.fileChange("origin-and-tree", status: "completed", files: [originPath: "update", firstPath: "update"], seconds: 10),
            fixture.fileChange("two-trees", status: "completed", files: [firstPath: "update", secondPath: "update"], seconds: 20),
            fixture.fileChange("cross-tree-move", status: "completed", files: [firstPath: "update"],
                moves: [firstPath: secondPath], seconds: 30)
        ])
        let project = try XCTUnwrap(CodexActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.recordedEditCount, 0)
        XCTAssertNil(project.latestEdit)
    }

    func testPartialLineSurvivesTheCacheAndSixDigitFractionsParse() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.project.appendingPathComponent("source.swift").path
        let change = try fixture.line(fixture.fileChange("pending", status: "completed", files: [path: "add"],
            timestamp: "2026-10-30T00:00:12.123456Z"))
        var initial = try fixture.line(fixture.sessionLines()[0])
        initial.append(change.prefix(change.count / 2))
        try initial.write(to: fixture.rollout)
        let provider = CodexActivityProvider(cacheURL: fixture.cache)
        XCTAssertNil(provider.scan(sources: [fixture.source]).projects[0].latestEdit)
        try fixture.appendData(Data(change.suffix(from: change.count / 2)))
        let result = CodexActivityProvider(cacheURL: fixture.cache).scan(sources: [fixture.source])
        XCTAssertEqual(result.projects[0].recordedEditCount, 1)
        let expected = try XCTUnwrap(RecordedDate.parse("2026-10-30T00:00:12.123456Z"))
        XCTAssertEqual(result.projects[0].latestEdit?.latestEdit, expected)
    }

    func testMissingHomeIsANotice() {
        let source = AgentSource(id: "codex", name: "Codex", configDirectory: "/tmp/agent-trail-missing-codex-\(UUID().uuidString)", assistant: .codex)
        let result = CodexActivityProvider().scan(sources: [source])
        XCTAssertTrue(result.projects.isEmpty)
        XCTAssertTrue(result.notices.contains { $0.contains("no local Codex home") })
    }

    func testDuplicateSessionIDCountsOnce() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let lines = fixture.sessionLines()
        try fixture.write(lines)
        try fixture.write(lines, to: fixture.root.appendingPathComponent("archived_sessions/2026/10/30/rollout-same.jsonl"))
        let project = try XCTUnwrap(CodexActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.sessionCount, 1)
    }
}

private final class Fixture {
    let root: URL
    let project: URL
    let rollout: URL
    let cache: URL
    let source: AgentSource
    let base: Date

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-trail-codex-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        rollout = root.appendingPathComponent("sessions/2026/10/30/rollout-session.jsonl")
        cache = root.appendingPathComponent("cache/activity-cache-codex.json")
        source = AgentSource(id: "codex", name: "Codex", configDirectory: root.path, assistant: .codex)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        base = try XCTUnwrap(formatter.date(from: "2026-10-30T00:00:00Z"))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func date(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    func stamp(_ seconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date(seconds))
    }

    func sessionLines(timestamp: String? = nil, roots: [String]? = nil) -> [[String: Any]] {
        [[
            "timestamp": timestamp ?? stamp(0),
            "ordinal": 1,
            "type": "session_meta",
            "payload": [
                "id": "session-1",
                "timestamp": timestamp ?? stamp(0),
                "cwd": project.path,
                "runtime_workspace_roots": roots ?? [project.path]
            ]
        ]]
    }

    func turn(_ cwd: String) -> [String: Any] {
        ["timestamp": stamp(1), "ordinal": 2, "type": "turn_context", "payload": ["cwd": cwd, "turn_id": "turn-1"]]
    }

    func fileChange(_ id: String, status: String, files: [String: String], moves: [String: String] = [:], seconds: TimeInterval = 0, timestamp: String? = nil) -> [String: Any] {
        var changes: [String: Any] = [:]
        for (path, kind) in files {
            var change = ["type": kind, "unified_diff": "PRIVATE_DIFF_MARKER"]
            if let destination = moves[path] { change["move_path"] = destination }
            changes[path] = change
        }
        let when = timestamp ?? stamp(seconds)
        var payload: [String: Any] = [
            "type": "item_completed",
            "item": ["type": "FileChange", "id": id, "status": status, "changes": changes]
        ]
        if timestamp == nil {
            payload["completed_at_ms"] = Int(date(seconds).timeIntervalSince1970 * 1000)
        }
        return ["timestamp": when, "ordinal": 3, "type": "event_msg", "payload": payload]
    }

    func shell(seconds: TimeInterval) -> [String: Any] {
        ["timestamp": stamp(seconds), "ordinal": 4, "type": "response_item",
         "payload": ["type": "custom_tool_call", "name": "exec", "input": "PRIVATE_COMMAND_MARKER"]]
    }

    func line(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }

    func write(_ objects: [[String: Any]], to url: URL? = nil) throws {
        var data = Data()
        for object in objects { data.append(try line(object)) }
        let destination = url ?? rollout
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
    }

    func append(_ objects: [[String: Any]]) throws {
        var data = try Data(contentsOf: rollout)
        for object in objects { data.append(try line(object)) }
        try data.write(to: rollout)
    }

    func appendData(_ data: Data) throws {
        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }
}
