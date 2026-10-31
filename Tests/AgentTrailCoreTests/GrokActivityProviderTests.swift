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
        saved["version"] = 3
        try JSONSerialization.data(withJSONObject: saved).write(to: fixture.cache)

        let result = GrokActivityProvider(cacheURL: fixture.cache).scan(sources: [fixture.source])
        XCTAssertEqual(result.projects[0].recordedEditCount, 1)
        XCTAssertTrue(result.notices.contains { $0.contains("rebuilt once") })
        let rebuilt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cache)) as? [String: Any])
        XCTAssertEqual(rebuilt["version"] as? Int, 4)
    }

    func testConfirmedTargetsIdentifyOneChildRepositoryWithoutChangingRecordedWorkspace() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = fixture.project.appendingPathComponent("agent-trail", isDirectory: true)
        try fixture.git(repository)
        let path = repository.appendingPathComponent("Sources/file.swift").path
        try fixture.write(summary: true, updates: [
            fixture.call("edit", name: "write", file: path, seconds: 5),
            fixture.finish("edit", status: "completed", absolute: path, output: "SearchReplace", seconds: 6)
        ])
        let provider = GrokActivityProvider(cacheURL: fixture.cache)
        let metadata = provider.metadata(sources: [fixture.source])
        XCTAssertEqual(metadata.projects.map(\.path), [canonicalPath(fixture.project.path)])
        XCTAssertTrue(metadata.sessionProjects.isEmpty)
        let result = provider.scan(sources: [fixture.source])
        let project = try XCTUnwrap(result.projects.first)
        XCTAssertEqual(project.path, canonicalPath(repository.path))
        XCTAssertEqual(project.recordedEditCount, 1)
        XCTAssertEqual(project.sessionCount, 1)
        XCTAssertEqual(project.latestActivity.workspacePath, canonicalPath(fixture.project.path))
        XCTAssertEqual(result.sessionProjects, [SessionProjectAssociation(sourceID: fixture.source.id,
            sessionID: "session-1", recordedWorkspace: fixture.project.path, projectPath: canonicalPath(repository.path))])
        let reloaded = GrokActivityProvider(cacheURL: fixture.cache).scan(sources: [fixture.source])
        XCTAssertEqual(reloaded.projects.map(\.path), result.projects.map(\.path))
        XCTAssertEqual(reloaded.sessionProjects, result.sessionProjects)
    }

    func testRecordedWorkspaceInsideRepositoryCanResolveBeforeAnyEdit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.git(fixture.project)
        let workspace = fixture.project.appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try fixture.write(summary: true, updates: nil, recordedWorkspace: workspace.path)
        let result = GrokActivityProvider().metadata(sources: [fixture.source])
        XCTAssertEqual(result.projects.map(\.path), [canonicalPath(fixture.project.path)])
        XCTAssertEqual(result.sessionProjects.first?.recordedWorkspace, workspace.path)
        XCTAssertEqual(result.projects.first?.latestActivity.workspacePath, canonicalPath(workspace.path))
    }

    func testAppendingASecondRepositoryReturnsTheSessionButKeepsEachEdit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.project.appendingPathComponent("first", isDirectory: true)
        let second = fixture.project.appendingPathComponent("second", isDirectory: true)
        try fixture.git(first)
        try fixture.git(second)
        let firstFile = first.appendingPathComponent("file.swift").path
        let secondFile = second.appendingPathComponent("file.swift").path
        try fixture.write(summary: true, updates: [
            fixture.call("first", name: "write", file: firstFile, seconds: 1),
            fixture.finish("first", status: "completed", absolute: firstFile, output: "SearchReplace", seconds: 2)
        ])
        let provider = GrokActivityProvider(cacheURL: fixture.cache)
        XCTAssertEqual(provider.scan(sources: [fixture.source]).projects.map(\.path), [canonicalPath(first.path)])
        for record in [fixture.call("second", name: "write", file: secondFile, seconds: 3),
                       fixture.finish("second", status: "completed", absolute: secondFile, output: "SearchReplace", seconds: 4)] {
            try fixture.append(JSONSerialization.data(withJSONObject: record) + Data([10]))
        }
        let result = provider.scan(sources: [fixture.source])
        let byPath = Dictionary(uniqueKeysWithValues: result.projects.map { ($0.path, $0) })
        XCTAssertEqual(byPath[canonicalPath(fixture.project.path)]?.sessionCount, 1)
        XCTAssertEqual(byPath[canonicalPath(first.path)]?.recordedEditCount, 1)
        XCTAssertEqual(byPath[canonicalPath(second.path)]?.latestEdit?.latestEdit, fixture.date(4))
        XCTAssertTrue(result.sessionProjects.isEmpty)
        let reloaded = GrokActivityProvider(cacheURL: fixture.cache).scan(sources: [fixture.source])
        XCTAssertEqual(Set(reloaded.projects.map(\.path)), Set(result.projects.map(\.path)))
        XCTAssertEqual(reloaded.projects.reduce(0) { $0 + $1.recordedEditCount }, 2)
    }

    func testDuplicateSessionCopiesAggregateAllEvidenceBeforeChoosingTheSessionHome() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.project.appendingPathComponent("first", isDirectory: true)
        let second = fixture.project.appendingPathComponent("second", isDirectory: true)
        try fixture.git(first)
        try fixture.git(second)
        let firstFile = first.appendingPathComponent("file.swift").path
        let secondFile = second.appendingPathComponent("file.swift").path
        try fixture.write(summary: true, updates: [
            fixture.call("first", name: "write", file: firstFile, seconds: 1),
            fixture.finish("first", status: "completed", absolute: firstFile, output: "SearchReplace", seconds: 2)
        ])
        let copy = fixture.root.appendingPathComponent("sessions/other-copy/session-1", isDirectory: true)
        try fixture.write(summary: true, updates: [
            fixture.call("first", name: "write", file: firstFile, seconds: 5),
            fixture.finish("first", status: "completed", absolute: firstFile, output: "SearchReplace", seconds: 6),
            fixture.call("second", name: "write", file: secondFile, seconds: 7),
            fixture.finish("second", status: "completed", absolute: secondFile, output: "SearchReplace", seconds: 8)
        ], directoryOverride: copy)
        let result = GrokActivityProvider().scan(sources: [fixture.source])
        let byPath = Dictionary(uniqueKeysWithValues: result.projects.map { ($0.path, $0) })
        XCTAssertEqual(byPath[canonicalPath(fixture.project.path)]?.sessionCount, 1)
        XCTAssertEqual(result.projects.reduce(0) { $0 + $1.sessionCount }, 1)
        XCTAssertEqual(byPath[canonicalPath(first.path)]?.recordedEditCount, 1)
        XCTAssertEqual(byPath[canonicalPath(first.path)]?.latestEdit?.latestEdit, fixture.date(2))
        XCTAssertEqual(byPath[canonicalPath(second.path)]?.recordedEditCount, 1)
        XCTAssertTrue(result.sessionProjects.isEmpty)
    }

    func testSymlinkedMoveGroupsOldAndCurrentTargetsAndLearnedLocationOutlivesTheLink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = fixture.project.appendingPathComponent("agent-trail", isDirectory: true)
        let current = fixture.root.appendingPathComponent("Dev/agent-trail", isDirectory: true)
        try fixture.git(old)
        try FileManager.default.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: old, to: current)
        try FileManager.default.createSymbolicLink(at: old, withDestinationURL: current)
        let oldFile = old.appendingPathComponent("Sources/old.swift").path
        let newFile = current.appendingPathComponent("Sources/new.swift").path
        let outside = fixture.root.appendingPathComponent("other/outside.swift").path
        try fixture.write(summary: true, updates: [
            fixture.call("old", name: "write", file: oldFile, seconds: 1),
            fixture.finish("old", status: "completed", absolute: oldFile, output: "SearchReplace", seconds: 2),
            fixture.call("new", name: "write", file: newFile, seconds: 3),
            fixture.finish("new", status: "completed", absolute: newFile, output: "SearchReplace", seconds: 4),
            fixture.call("outside", name: "write", file: outside, seconds: 5),
            fixture.finish("outside", status: "completed", absolute: outside, output: "SearchReplace", seconds: 6)
        ])
        let locationsURL = fixture.root.appendingPathComponent("support/project-locations.json")
        let composite = CompositeActivityProvider(cacheURL: fixture.root.appendingPathComponent("support/activity-cache.json"),
                                                  locationsURL: locationsURL)
        let result = composite.scan(sources: [fixture.source])
        XCTAssertEqual(result.projects.map(\.path), [canonicalPath(current.path)])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 2)
        XCTAssertEqual(result.projects.first?.sessionCount, 1)
        XCTAssertEqual(result.projects.first?.latestEdit?.latestEdit, fixture.date(4))
        XCTAssertEqual(result.sessionProjects.first?.recordedWorkspace, fixture.project.path)
        let learned = try XCTUnwrap(result.projectLocations.location(forCurrentPath: canonicalPath(current.path)))
        XCTAssertEqual(learned.previousLocations.map(\.path), [old.path])
        XCTAssertEqual(learned.previousLocations.first?.origin, .link)

        // Deleting the link keeps the grouping, from the saved catalog alone.
        try FileManager.default.removeItem(at: old)
        let relaunched = CompositeActivityProvider(cacheURL: fixture.root.appendingPathComponent("support/activity-cache.json"),
                                                   locationsURL: locationsURL).scan(sources: [fixture.source])
        XCTAssertEqual(relaunched.projects.map(\.path), [canonicalPath(current.path)])
        XCTAssertEqual(relaunched.projects.first?.recordedEditCount, 2)

        // Without that catalog, the old edit stays with the folder it was made from.
        let forgotten = GrokActivityProvider().scan(sources: [fixture.source])
        let byPath = Dictionary(uniqueKeysWithValues: forgotten.projects.map { ($0.path, $0) })
        XCTAssertEqual(byPath[canonicalPath(current.path)]?.sessionCount, 1)
        XCTAssertEqual(byPath[canonicalPath(current.path)]?.recordedEditCount, 1)
        XCTAssertEqual(byPath[canonicalPath(fixture.project.path)]?.recordedEditCount, 1)
        XCTAssertEqual(forgotten.missingFolders.first?.path, old.path)
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

    func write(summary: Bool, title: String = "title", created: String? = nil, active: String? = nil, updates: [[String: Any]]?, sessionID: String = "session-1", recordedWorkspace: String? = nil, directoryOverride: URL? = nil) throws {
        let directory = directoryOverride ?? sessionDir.deletingLastPathComponent().appendingPathComponent(sessionID, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if summary {
            let object: [String: Any] = [
                "info": ["id": sessionID, "cwd": recordedWorkspace ?? project.path],
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

    func git(_ directory: URL) throws {
        let metadata = directory.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata.appendingPathComponent("objects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: metadata.appendingPathComponent("HEAD"))
    }
}
