import Foundation
import XCTest
@testable import AgentTrailCore

final class CompositeActivityProviderTests: XCTestCase {
    func testTheSameFolderFromCodexAndGrokIsOneSharedProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-trail-composite-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: Date(timeIntervalSince1970: 1_761_782_400))
        let codexHome = root.appendingPathComponent("codex-home", isDirectory: true)
        let rollout = codexHome.appendingPathComponent("sessions/2026/10/30/rollout-one.jsonl")
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        let codexLines: [[String: Any]] = [
            ["timestamp": stamp, "type": "session_meta", "payload": ["id": "session-1", "timestamp": stamp, "cwd": project.path, "runtime_workspace_roots": [project.path]]],
            ["timestamp": stamp, "type": "event_msg", "payload": ["type": "item_completed", "item": ["type": "FileChange", "id": "edit-1", "status": "completed", "changes": [project.appendingPathComponent("file.swift").path: ["type": "update"]]]]]
        ]
        var codexData = Data()
        for line in codexLines {
            codexData.append(try JSONSerialization.data(withJSONObject: line))
            codexData.append(0x0A)
        }
        try codexData.write(to: rollout)

        let grokHome = root.appendingPathComponent("grok-home", isDirectory: true)
        let session = grokHome.appendingPathComponent("sessions/slug/session-9")
        try FileManager.default.createDirectory(at: session, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["info": ["id": "session-9", "cwd": project.path], "created_at": stamp, "last_active_at": stamp]).write(to: session.appendingPathComponent("summary.json"))

        let claude = AgentSource(id: "claude-primary", name: "Claude", configDirectory: root.appendingPathComponent("missing-claude").path, userDataDirectory: root.appendingPathComponent("missing-desktop").path)
        let codex = AgentSource(id: "codex", name: "Codex", configDirectory: codexHome.path, assistant: .codex)
        let grok = AgentSource(id: "grok", name: "Grok", configDirectory: grokHome.path, assistant: .grok)
        let result = CompositeActivityProvider().scan(sources: [claude, codex, grok])
        XCTAssertEqual(result.projects.count, 1)
        XCTAssertEqual(result.projects[0].path, project.path)
        XCTAssertTrue(result.projects[0].isShared)
        XCTAssertEqual(result.projects[0].recordedEditCount, 1)
        XCTAssertEqual(Set(result.projects[0].activities.map(\.sourceID)), ["codex", "grok"])
        XCTAssertTrue(result.notices.contains { $0.contains("Claude") && $0.contains("no local Claude") })
        XCTAssertFalse(result.notices.contains { $0.contains("Codex") && $0.contains("desktop data folder") })
    }

    func testProgressKeepsPendingAssistantsVisibleWithoutDuplicatingSessions() throws {
        let fixture = try CompositeFixture()
        defer { fixture.remove() }
        let provider = CompositeActivityProvider()
        let metadata = provider.metadata(sources: fixture.sources)
        let expectedPaths = Set(metadata.projects.map(\.path))
        XCTAssertEqual(expectedPaths.count, 3)
        var snapshots: [ScanResult] = []

        let result = provider.scan(sources: fixture.sources) { partial, _, _ in
            snapshots.append(partial)
        }

        XCTAssertEqual(snapshots.count, 3)
        for snapshot in snapshots + [result] {
            XCTAssertEqual(Set(snapshot.projects.map(\.path)), expectedPaths)
            XCTAssertEqual(Set(snapshot.projects.flatMap(\.activities).map(\.sourceID)), Set(fixture.sources.map(\.id)))
            XCTAssertEqual(snapshot.projects.reduce(0) { $0 + $1.sessionCount }, 3)
            XCTAssertTrue(snapshot.projects.allSatisfy { $0.sessionCount == 1 })
        }
        XCTAssertEqual(result.projects.reduce(0) { $0 + $1.recordedEditCount }, 2)
        XCTAssertEqual(snapshots.last?.projects.reduce(0) { $0 + $1.recordedEditCount }, 2)
    }

    func testCustomCacheBasenamesKeepAdapterCachesIsolated() throws {
        let fixture = try CompositeFixture()
        defer { fixture.remove() }
        let directory = fixture.root.appendingPathComponent("cache")
        let first = directory.appendingPathComponent("first.json")
        let second = directory.appendingPathComponent("second.json")
        _ = CompositeActivityProvider(cacheURL: first).scan(sources: fixture.sources)
        let firstNames = ["first.json", "first-codex.json", "first-grok.json"]
        let original = try firstNames.map { try Data(contentsOf: directory.appendingPathComponent($0)) }

        _ = CompositeActivityProvider(cacheURL: second).scan(sources: fixture.sources)

        for (name, data) in zip(firstNames, original) {
            XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(name)), data)
        }
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       Set(firstNames + ["second.json", "second-codex.json", "second-grok.json"]))
    }

    func testDerivedCachesStaySeparateForDefaultAndFormerlyCollidingBasenames() throws {
        let fixture = try CompositeFixture()
        defer { fixture.remove() }
        for stem in ["activity-cache", "activity-cache-codex", "activity-cache-grok"] {
            let directory = fixture.root.appendingPathComponent(stem)
            let cache = directory.appendingPathComponent("\(stem).json")
            _ = CompositeActivityProvider(cacheURL: cache).scan(sources: fixture.sources)

            let names = ["\(stem).json", "\(stem)-codex.json", "\(stem)-grok.json"]
            XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), Set(names))
            for (index, name) in names.enumerated() {
                let data = try Data(contentsOf: directory.appendingPathComponent(name))
                let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                // Claude keeps its transcript cache; Codex and Grok store raw evidence.
                XCTAssertEqual(object["version"] as? Int, index == 0 ? 2 : 4)
                XCTAssertNotNil(object[index == 0 ? "transcripts" : "files"])
            }
        }
    }
}

private final class CompositeFixture {
    let root: URL
    let sources: [AgentSource]

    init() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("agent-trail-composite-\(UUID().uuidString)", isDirectory: true)
        sources = [
            AgentSource(id: "claude", name: "Claude", configDirectory: root.appendingPathComponent("claude-home").path,
                        userDataDirectory: root.appendingPathComponent("claude-desktop").path),
            AgentSource(id: "codex", name: "Codex", configDirectory: root.appendingPathComponent("codex-home").path, assistant: .codex),
            AgentSource(id: "grok", name: "Grok", configDirectory: root.appendingPathComponent("grok-home").path, assistant: .grok)
        ]
        let stamp = "2026-10-30T00:00:00Z"
        let claudeProject = root.appendingPathComponent("claude-project")
        let codexProject = root.appendingPathComponent("codex-project")
        let grokProject = root.appendingPathComponent("grok-project")
        for project in [claudeProject, codexProject, grokProject] {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        }
        let desktop = root.appendingPathComponent("claude-desktop/claude-code-sessions/account/local_session.json")
        try FileManager.default.createDirectory(at: desktop.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "sessionId": "local-session", "cliSessionId": "claude-session", "cwd": claudeProject.path,
            "createdAt": 1_793_318_400_000, "lastActivityAt": 1_793_318_400_000
        ]).write(to: desktop)
        try write([
            ["type": "assistant", "cwd": claudeProject.path,
             "message": ["content": [["type": "tool_use", "id": "claude-edit", "name": "Edit", "input": ["file_path": "file.swift"]]]]],
            ["type": "user", "cwd": claudeProject.path, "timestamp": stamp,
             "message": ["content": [["type": "tool_result", "tool_use_id": "claude-edit"]]],
             "toolUseResult": ["filePath": claudeProject.appendingPathComponent("file.swift").path]]
        ], to: root.appendingPathComponent("claude-home/projects/project/claude-session.jsonl"))
        try write([
            ["timestamp": stamp, "type": "session_meta", "payload": ["id": "codex-session", "timestamp": stamp, "cwd": codexProject.path]],
            ["timestamp": stamp, "type": "event_msg", "payload": ["type": "item_completed", "item": ["type": "FileChange", "id": "codex-edit", "status": "completed", "changes": ["file.swift": ["type": "update"]]]]]
        ], to: root.appendingPathComponent("codex-home/sessions/rollout-one.jsonl"))
        let grokSession = root.appendingPathComponent("grok-home/sessions/slug/grok-session")
        try FileManager.default.createDirectory(at: grokSession, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: [
            "info": ["id": "grok-session", "cwd": grokProject.path], "created_at": stamp, "last_active_at": stamp
        ]).write(to: grokSession.appendingPathComponent("summary.json"))
        try Data().write(to: grokSession.appendingPathComponent("updates.jsonl"))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    private func write(_ records: [[String: Any]], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data()
        for record in records {
            data.append(try JSONSerialization.data(withJSONObject: record))
            data.append(0x0A)
        }
        try data.write(to: url)
    }
}
