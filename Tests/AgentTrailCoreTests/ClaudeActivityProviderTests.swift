import Foundation
import XCTest
@testable import AgentTrailCore

final class ClaudeActivityProviderTests: XCTestCase {
    func testMetadataIsImmediateAndOnlySuccessfulExplicitToolsCount() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session()
        let path = fixture.project.appendingPathComponent("source.swift").path
        try fixture.write([
            fixture.request("good", path: path), fixture.response("good", seconds: 10, path: path),
            fixture.request("failed", path: path), fixture.response("failed", seconds: 20, path: path, isError: true),
            fixture.request("human", path: path), fixture.response("human", seconds: 30, path: path, userModified: true),
            fixture.request("shell", name: "Bash", path: path), fixture.response("shell", seconds: 40, path: path),
            fixture.request("outside", path: fixture.root.appendingPathComponent("elsewhere/file.swift").path),
            fixture.response("outside", seconds: 50, path: fixture.root.appendingPathComponent("elsewhere/file.swift").path)
        ])
        let provider = ClaudeActivityProvider()
        let metadata = provider.metadata(sources: [fixture.source])
        XCTAssertEqual(metadata.projects.count, 1)
        XCTAssertNil(metadata.projects[0].latestEdit)
        let result = provider.scan(sources: [fixture.source])
        XCTAssertEqual(result.projects[0].latestEdit?.latestEdit, fixture.date(10))
        XCTAssertEqual(result.projects[0].recordedEditCount, 1)
        XCTAssertEqual(result.projects[0].activities[0].sessionCount, 1)
        XCTAssertEqual(result.projects[0].latestEdit?.latestEditWorkspacePath, fixture.project.path)
    }

    func testSubagentWritesCountButUnrelatedTerminalHistoryDoesNot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session()
        let path = fixture.project.appendingPathComponent("subagent.swift").path
        try fixture.write([])
        let subagent = fixture.projectLogs.appendingPathComponent("cli-session/subagents/workflows/flow/agent-one.jsonl")
        try fixture.write([fixture.request("worker", name: "Write", path: path),
            fixture.response("worker", seconds: 20, path: path, isError: false)], to: subagent)
        try fixture.write([fixture.request("terminal", name: "Write", path: path),
            fixture.response("terminal", seconds: 90, path: path)],
            to: fixture.projectLogs.appendingPathComponent("terminal-only.jsonl"))
        let result = ClaudeActivityProvider().scan(sources: [fixture.source])
        XCTAssertEqual(result.projects[0].latestEdit?.latestEdit, fixture.date(20))
        XCTAssertEqual(result.projects[0].recordedEditCount, 1)
    }

    func testReplayAndCopiedLogsCountEachToolOnceAcrossCacheAndAppend() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session()
        let path = fixture.project.appendingPathComponent("source.swift").path
        let pair = [fixture.request("replayed", path: path), fixture.response("replayed", seconds: 10, path: path)]
        try fixture.write(pair + pair + [fixture.request("unique", name: "Write", path: path),
            fixture.response("unique", seconds: 20, path: path)])
        try fixture.write(pair + [fixture.request("replayed", path: path),
            fixture.response("replayed", seconds: 90, path: path)],
            to: fixture.projectLogs.appendingPathComponent("cli-session/subagents/agent-copy.jsonl"))
        let provider = ClaudeActivityProvider(cacheURL: fixture.cache)
        let first = provider.scan(sources: [fixture.source])
        XCTAssertEqual(first.projects[0].recordedEditCount, 2)
        XCTAssertEqual(first.projects[0].latestEdit?.latestEdit, fixture.date(20))
        XCTAssertEqual(provider.scan(sources: [fixture.source]).projects[0].recordedEditCount, 2)
        try fixture.append(pair)
        let relaunched = ClaudeActivityProvider(cacheURL: fixture.cache)
        XCTAssertEqual(relaunched.scan(sources: [fixture.source]).projects[0].recordedEditCount, 2)
        try fixture.append([fixture.request("appended", path: path), fixture.response("appended", seconds: 30, path: path)])
        XCTAssertEqual(relaunched.scan(sources: [fixture.source]).projects[0].recordedEditCount, 3)
        XCTAssertEqual(ClaudeActivityProvider(cacheURL: fixture.cache).scan(sources: [fixture.source]).projects[0].recordedEditCount, 3)
    }

    func testUTCHistoryBinsSessionsOnCreationDayAndEditsOnResultDay() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session()
        let formatter = ISO8601DateFormatter()
        let creation = try XCTUnwrap(formatter.date(from: "2026-10-29T23:30:00Z"))
        let lastActivity = try XCTUnwrap(formatter.date(from: "2026-10-31T03:00:00Z"))
        var session = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.metadata)) as? [String: Any])
        session["createdAt"] = creation.timeIntervalSince1970 * 1000
        session["lastActivityAt"] = lastActivity.timeIntervalSince1970 * 1000
        let sessionData = try JSONSerialization.data(withJSONObject: session)
        try sessionData.write(to: fixture.metadata)
        // A copied metadata file for the same desktop session is still one session.
        try sessionData.write(to: fixture.metadata.deletingLastPathComponent().appendingPathComponent("local_duplicate.json"))
        session["sessionId"] = "local_fallback"
        session["cliSessionId"] = "no-transcript"
        session.removeValue(forKey: "createdAt")
        try JSONSerialization.data(withJSONObject: session).write(to: fixture.metadata.deletingLastPathComponent().appendingPathComponent("local_fallback.json"))
        let path = fixture.project.appendingPathComponent("source.swift").path
        var beforeMidnight = fixture.response("before", seconds: 1, path: path)
        beforeMidnight["timestamp"] = "2026-10-30T02:59:00.000+03:00"
        var afterMidnight = fixture.response("after", seconds: 2, path: path)
        afterMidnight["timestamp"] = "2026-10-30T00:01:00Z"
        try fixture.write([fixture.request("before", path: path), beforeMidnight,
            fixture.request("after", path: path), afterMidnight])
        let provider = ClaudeActivityProvider()
        let metadata = provider.metadata(sources: [fixture.source]).projects[0]
        XCTAssertEqual(metadata.sessionCount, 2)
        XCTAssertEqual(metadata.recordedEditCount, 0)
        let project = provider.scan(sources: [fixture.source]).projects[0]
        XCTAssertEqual(project.sessionCount, 2)
        XCTAssertEqual(project.recordedEditCount, 2)
        let expectedDays = try ["2026-10-29T00:00:00Z", "2026-10-30T00:00:00Z", "2026-10-31T00:00:00Z"].map {
            try XCTUnwrap(formatter.date(from: $0))
        }
        XCTAssertEqual(project.history.map(\.day), expectedDays)
        XCTAssertEqual(project.history.map(\.editCount), [1, 1, 0])
        XCTAssertEqual(project.history.map(\.sessionCount), [1, 0, 1])
    }

    func testVersionOneCacheReindexesOnceForTrustworthyCounts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session()
        let path = fixture.project.appendingPathComponent("source.swift").path
        try fixture.write([fixture.request("first", path: path), fixture.response("first", seconds: 10, path: path)])
        try FileManager.default.createDirectory(at: fixture.cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Older caches retained only a latest edit, so they cannot supply counts.
        try JSONSerialization.data(withJSONObject: ["version": 1, "transcripts": [:]]).write(to: fixture.cache)
        let upgraded = ClaudeActivityProvider(cacheURL: fixture.cache).scan(sources: [fixture.source])
        XCTAssertEqual(upgraded.projects[0].recordedEditCount, 1)
        XCTAssertTrue(upgraded.notices.contains { $0.contains("rebuilt once") })
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cache)) as? [String: Any])
        XCTAssertEqual(saved["version"] as? Int, 2)
        let reopened = ClaudeActivityProvider(cacheURL: fixture.cache).scan(sources: [fixture.source])
        XCTAssertEqual(reopened.projects[0].recordedEditCount, 1)
        XCTAssertFalse(reopened.notices.contains { $0.contains("rebuilt once") })
    }

    func testOriginGroupingRetainsHistoricalAndCurrentCheckoutProvenance() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let worktree = fixture.project.appendingPathComponent(".claude/worktrees/feature")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try fixture.session(workspace: worktree)
        let originalPath = fixture.project.appendingPathComponent("original.swift").path
        let worktreePath = worktree.appendingPathComponent("new.swift").path
        // This session's cwd changed after the first edit. Event cwd preserves the
        // historical checkout instead of projecting its current cwd backwards.
        try fixture.write([
            fixture.request("old", path: originalPath, cwd: fixture.project.path),
            fixture.response("old", seconds: 10, path: originalPath, cwd: fixture.project.path)
        ])
        let provider = ClaudeActivityProvider()
        var result = provider.scan(sources: [fixture.source])
        XCTAssertEqual(result.projects[0].path, fixture.project.path)
        XCTAssertEqual(result.projects[0].latestEdit?.latestEditWorkspacePath, fixture.project.path)
        try fixture.append([fixture.request("new", path: worktreePath, cwd: worktree.path),
            fixture.response("new", seconds: 20, path: worktreePath, cwd: worktree.path)])
        result = provider.scan(sources: [fixture.source])
        XCTAssertEqual(result.projects.count, 1)
        XCTAssertEqual(result.projects[0].latestEdit?.latestEditWorkspacePath, worktree.path)
    }

    func testExternalEventCwdIsNotAttributedToOriginalProject() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session()
        let external = fixture.root.appendingPathComponent("other-repository")
        let path = external.appendingPathComponent("outside.swift").path
        try fixture.write([fixture.request("outside", path: path, cwd: external.path),
            fixture.response("outside", seconds: 30, path: path, cwd: external.path)])
        XCTAssertNil(ClaudeActivityProvider().scan(sources: [fixture.source]).projects[0].latestEdit)
    }

    func testPartialLineAndPendingToolSurvivePersistedCacheAndAppend() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session()
        let path = fixture.project.appendingPathComponent("written.swift").path
        let response = try fixture.line(fixture.response("pending", seconds: 20, path: path))
        let split = response.count / 2
        var initial = try fixture.line(fixture.request("pending", name: "Write", path: path))
        initial.append(response.prefix(split))
        try initial.write(to: fixture.transcript)
        let provider = ClaudeActivityProvider(cacheURL: fixture.cache)
        XCTAssertNil(provider.scan(sources: [fixture.source]).projects[0].latestEdit)
        let cacheText = try String(contentsOf: fixture.cache, encoding: .utf8)
        XCTAssertFalse(cacheText.contains("PRIVATE_CONTENT_MARKER"))
        XCTAssertFalse(cacheText.contains("PRIVATE_COMMAND_MARKER"))
        XCTAssertFalse(cacheText.contains("PRIVATE_PROMPT_MARKER"))
        try fixture.appendData(Data(response.suffix(from: split)))
        let relaunched = ClaudeActivityProvider(cacheURL: fixture.cache)
        let result = relaunched.scan(sources: [fixture.source])
        XCTAssertEqual(result.projects[0].latestEdit?.latestEdit, fixture.date(20))
        XCTAssertEqual(relaunched.scan(sources: [fixture.source]).projects[0].latestEdit?.latestEdit, fixture.date(20))
    }

    func testTruncationAndAtomicReplacementInvalidateCachedEdit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session()
        let path = fixture.project.appendingPathComponent("source.swift").path
        try fixture.write([fixture.request("first", path: path), fixture.response("first", seconds: 20, path: path)])
        let provider = ClaudeActivityProvider(cacheURL: fixture.cache)
        XCTAssertNotNil(provider.scan(sources: [fixture.source]).projects[0].latestEdit)
        let handle = try FileHandle(forWritingTo: fixture.transcript)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: fixture.line(["type": "system", "timestamp": fixture.stamp(30)]))
        try handle.close()
        XCTAssertNil(provider.scan(sources: [fixture.source]).projects[0].latestEdit)
        var replacement = try fixture.line(fixture.request("replacement", name: "Write", path: path))
        replacement.append(try fixture.line(fixture.response("replacement", seconds: 40, path: path)))
        try replacement.write(to: fixture.transcript, options: .atomic)
        XCTAssertEqual(provider.scan(sources: [fixture.source]).projects[0].latestEdit?.latestEdit, fixture.date(40))
    }

    func testOversizedPartialRecordStaysSkippedAcrossRestart() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session()
        // Leave an oversized incomplete line. Its suffix happens to look like a
        // tool request, and must never become an independent event after restart.
        try Data(repeating: 0x78, count: 64 * 1024 * 1024 + 1).write(to: fixture.transcript)
        let provider = ClaudeActivityProvider(cacheURL: fixture.cache)
        XCTAssertNil(provider.scan(sources: [fixture.source]).projects[0].latestEdit)
        let path = fixture.project.appendingPathComponent("ghost.swift").path
        try fixture.append([fixture.request("ghost", path: path), fixture.response("ghost", seconds: 30, path: path)])
        let relaunched = ClaudeActivityProvider(cacheURL: fixture.cache)
        let result = relaunched.scan(sources: [fixture.source])
        XCTAssertNil(result.projects[0].latestEdit)
        XCTAssertTrue(result.notices.contains { $0.contains("too large") })
    }

    func testCopiedToolsInsideAPIBlobCannotCreateEditEvidence() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session()
        let path = fixture.project.appendingPathComponent("source.swift").path
        let copiedRequest: [String: Any] = ["type": "api-request-blob", "payload": fixture.request("copied", path: path)]
        try fixture.write([copiedRequest, fixture.response("copied", seconds: 20, path: path)])
        XCTAssertNil(ClaudeActivityProvider().scan(sources: [fixture.source]).projects[0].latestEdit)
    }

    func testUnreadableHistoryAddsNoticeWithoutLeakingRecordContent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.session()
        try Data("{\"type\":\"assistant\",\"message\":\"tool_use\",PRIVATE_PROMPT_MARKER\n".utf8).write(to: fixture.transcript)
        let result = ClaudeActivityProvider().scan(sources: [fixture.source])
        XCTAssertTrue(result.notices.contains { $0.contains("unreadable records") })
        XCTAssertFalse(result.notices.joined().contains("PRIVATE_PROMPT_MARKER"))
        try FileManager.default.removeItem(at: fixture.transcript)
        XCTAssertTrue(ClaudeActivityProvider().scan(sources: [fixture.source]).notices.contains { $0.contains("unavailable") })
    }

    private final class Fixture {
        let root: URL
        let project: URL
        let projectLogs: URL
        let transcript: URL
        let cache: URL
        let source: AgentSource
        let metadata: URL
        let formatter: ISO8601DateFormatter

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("AgentTrailTests-" + UUID().uuidString)
            project = root.appendingPathComponent("project")
            projectLogs = root.appendingPathComponent("config/projects/encoded-project")
            transcript = projectLogs.appendingPathComponent("cli-session.jsonl")
            metadata = root.appendingPathComponent("desktop/claude-code-sessions/account/org/local_session.json")
            cache = root.appendingPathComponent("cache/activity.json")
            source = AgentSource(id: "main", name: "Test Claude", configDirectory: root.appendingPathComponent("config").path,
                userDataDirectory: root.appendingPathComponent("desktop").path)
            formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            for directory in [project, projectLogs, metadata.deletingLastPathComponent()] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
        func date(_ seconds: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(1000 + seconds)) }
        func stamp(_ seconds: Int) -> String { formatter.string(from: date(seconds)) }

        func session(workspace: URL? = nil) throws {
            let cwd = workspace ?? project
            let record: [String: Any] = ["sessionId": "local_session", "cliSessionId": "cli-session",
                "cwd": cwd.path, "originCwd": project.path, "createdAt": 1_000_000, "lastActivityAt": 1_000_000,
                "gitAnchors": [["gitRoot": project.path], ["gitRoot": cwd.path]]]
            try JSONSerialization.data(withJSONObject: record).write(to: metadata)
        }

        func request(_ id: String, name: String = "Edit", path: String, cwd: String? = nil) -> [String: Any] {
            ["type": "assistant", "cwd": cwd ?? project.path,
             "message": ["role": "assistant", "content": [["type": "tool_use", "id": id, "name": name,
                "input": ["file_path": path, "content": "PRIVATE_CONTENT_MARKER", "command": "PRIVATE_COMMAND_MARKER"]]]]]
        }

        func response(_ id: String, seconds: Int, path: String, isError: Bool? = nil,
                      userModified: Bool = false, cwd: String? = nil) -> [String: Any] {
            var block: [String: Any] = ["type": "tool_result", "tool_use_id": id, "content": "PRIVATE_PROMPT_MARKER"]
            if let isError { block["is_error"] = isError }
            return ["type": "user", "cwd": cwd ?? project.path, "timestamp": stamp(seconds),
                "message": ["role": "user", "content": [block]],
                "toolUseResult": ["filePath": path, "userModified": userModified, "content": "PRIVATE_CONTENT_MARKER"]]
        }

        func line(_ record: [String: Any]) throws -> Data {
            var data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            data.append(0x0A)
            return data
        }

        func write(_ records: [[String: Any]], to url: URL? = nil) throws {
            let target = url ?? transcript
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data()
            for record in records { data.append(try line(record)) }
            try data.write(to: target)
        }

        func append(_ records: [[String: Any]]) throws {
            var data = Data()
            for record in records { data.append(try line(record)) }
            try appendData(data)
        }

        func appendData(_ data: Data) throws {
            let handle = try FileHandle(forWritingTo: transcript)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
    }
}
