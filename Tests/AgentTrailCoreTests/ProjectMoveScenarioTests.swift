import Foundation
import XCTest
@testable import AgentTrailCore

/// Reconstructs a real sequence: a repository created inside Codex's output
/// folder, edited by Codex (started in a parent folder) and Grok (started in
/// another parent folder), then moved with `mv` and a link left behind, then
/// edited again by the same Codex session and by Claude at the new path.
final class ProjectMoveScenarioTests: XCTestCase {
    func testMovedRepositoryShowsAsOneProjectAcrossAllAssistants() throws {
        let scene = try Scene()
        defer { scene.remove() }
        let result = scene.composite().scan(sources: scene.sources)
        let byPath = Dictionary(uniqueKeysWithValues: result.projects.map { ($0.path, $0) })
        let project = try XCTUnwrap(byPath[scene.current.path])
        XCTAssertEqual(Set(project.activities.map(\.sourceID)), ["claude-primary", "codex", "grok"])
        XCTAssertTrue(project.isShared)
        let edits = Dictionary(uniqueKeysWithValues: project.activities.map { ($0.sourceID, $0.history.reduce(0) { $0 + $1.editCount }) })
        XCTAssertEqual(edits, ["codex": 3, "grok": 2, "claude-primary": 1])
        let sessions = Dictionary(uniqueKeysWithValues: project.activities.map { ($0.sourceID, $0.sessionCount) })
        // The main Codex thread, its reviewer thread with no edits of its own,
        // and its editing helper all belong to the project.
        XCTAssertEqual(sessions, ["codex": 3, "grok": 1, "claude-primary": 1])
        XCTAssertEqual(project.latestEdit?.sourceID, "claude-primary")
        XCTAssertEqual(project.activities.first { $0.sourceID == "codex" }?.latestEditWorkspacePath, scene.codexLaunch.path)
        XCTAssertNil(byPath[scene.grokLaunch.path], "the Grok launch folder is not a project of its own")

        // Release notes Codex wrote beside the repository stay with that folder.
        let scratch = try XCTUnwrap(byPath[scene.codexLaunch.path])
        XCTAssertEqual(scratch.sessionCount, 0)
        XCTAssertEqual(scratch.recordedEditCount, 1)

        // The link was learned so grouping no longer depends on it.
        let location = try XCTUnwrap(result.projectLocations.location(forCurrentPath: scene.current.path))
        XCTAssertEqual(location.previousLocations.map(\.path), [scene.original.path])
        XCTAssertEqual(location.previousLocations.first?.origin, .link)
        XCTAssertTrue(result.missingFolders.isEmpty)
        XCTAssertTrue(result.unavailableProjects.isEmpty)
    }

    func testGroupingSurvivesDeletingTheLeftoverLink() throws {
        let scene = try Scene()
        defer { scene.remove() }
        let before = scene.composite().scan(sources: scene.sources)
        try FileManager.default.removeItem(at: scene.original)
        let after = scene.composite().scan(sources: scene.sources)
        XCTAssertEqual(Set(after.projects.map(\.path)), Set(before.projects.map(\.path)))
        XCTAssertEqual(after.projects.first { $0.path == scene.current.path }?.recordedEditCount, 6)
        XCTAssertTrue(after.missingFolders.isEmpty)
    }

    func testLiveSessionsJoinTheProjectTheirHistoryLandedIn() throws {
        let scene = try Scene()
        defer { scene.remove() }
        let result = scene.composite().scan(sources: scene.sources)
        let now = Date()
        let live = [
            LiveAgentSession(sourceID: "codex", projectPath: scene.codexLaunch.path, workspacePath: scene.codexLaunch.path,
                             sessionID: "main-thread", status: .working, updatedAt: now, pid: 101),
            LiveAgentSession(sourceID: "grok", projectPath: scene.grokLaunch.path, workspacePath: scene.grokLaunch.path,
                             sessionID: "grok-session", status: .waiting, updatedAt: now, pid: 102),
            LiveAgentSession(sourceID: "claude-primary", projectPath: scene.current.path, workspacePath: scene.current.path,
                             sessionID: "claude-cli", status: .idle, updatedAt: now, pid: 103)
        ]
        let overviews = ProjectOverview.merge(projects: result.projects, sessions: live, sessionProjects: result.sessionProjects)
        let project = try XCTUnwrap(overviews.first { $0.path == scene.current.path })
        XCTAssertEqual(project.live?.sessions.count, 3)
        XCTAssertEqual(project.live?.waitingCount, 1)
        XCTAssertEqual(project.live?.workingCount, 1)
        XCTAssertEqual(Set(project.live?.workspacePaths ?? []), [scene.codexLaunch.path, scene.grokLaunch.path, scene.current.path])
        XCTAssertNil(overviews.first { $0.path == scene.codexLaunch.path }?.live)
        XCTAssertEqual(overviews.first?.path, scene.current.path, "the project needing input sorts first")
    }

    func testPlainMoveWithoutALinkIsFollowedOnceTheCheckoutWasSeen() throws {
        let scene = try Scene()
        defer { scene.remove() }
        _ = scene.composite().scan(sources: scene.sources)
        // Move again, this time without leaving anything behind.
        let next = scene.root.appendingPathComponent("Projects/agent-trail")
        try FileManager.default.createDirectory(at: next.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: scene.original)
        try FileManager.default.moveItem(at: scene.current, to: next)
        let result = scene.composite().scan(sources: scene.sources)
        let moved = try XCTUnwrap(result.projects.first { $0.path == canonicalPath(next.path) })
        XCTAssertEqual(Set(moved.activities.map(\.sourceID)), ["claude-primary", "codex", "grok"])
        XCTAssertEqual(moved.recordedEditCount, 6)
        let location = try XCTUnwrap(result.projectLocations.location(forCurrentPath: canonicalPath(next.path)))
        XCTAssertEqual(Set(location.previousPaths), [scene.original.path, scene.current.path])
        XCTAssertNil(result.projects.first { $0.path == scene.current.path })
        // A Claude window still reporting the old folder follows it too.
        let live = LiveAgentSession(sourceID: "claude-primary", projectPath: scene.current.path, workspacePath: scene.current.path,
                                    sessionID: "claude-cli", status: .working, updatedAt: Date(), pid: 103)
        let overviews = ProjectOverview.merge(projects: result.projects, sessions: [live],
            sessionProjects: result.sessionProjects, relocate: { result.projectLocations.relocatedPath($0) })
        XCTAssertEqual(overviews.first { $0.live != nil }?.path, canonicalPath(next.path))
    }

    func testUnrelatedCloneWithTheSameNameStaysSeparate() throws {
        let scene = try Scene()
        defer { scene.remove() }
        let clone = scene.root.appendingPathComponent("Elsewhere/agent-trail")
        try Scene.git(clone)
        try scene.writeClaude(origin: clone, sessionID: "clone-session", cli: "clone-cli", file: "clone.swift", seconds: 70)
        let result = scene.composite().scan(sources: scene.sources)
        let paths = Set(result.projects.map(\.path))
        XCTAssertTrue(paths.contains(scene.current.path))
        XCTAssertTrue(paths.contains(canonicalPath(clone.path)))
        XCTAssertEqual(result.projects.first { $0.path == canonicalPath(clone.path) }?.activities.map(\.sourceID), ["claude-primary"])
    }

    private final class Scene {
        let root: URL
        let codexLaunch: URL
        let grokLaunch: URL
        let original: URL
        let current: URL
        let sources: [AgentSource]
        let locations: URL
        let cache: URL
        private let base = Date(timeIntervalSince1970: 1_800_000_000)

        init() throws {
            root = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory
                .appendingPathComponent("agent-trail-move-\(UUID().uuidString)").path), isDirectory: true)
            codexLaunch = root.appendingPathComponent("Documents/Codex/2026-10-30/hey")
            grokLaunch = codexLaunch.appendingPathComponent("outputs")
            original = grokLaunch.appendingPathComponent("AgentTrail")
            current = root.appendingPathComponent("Dev/agent-trail")
            locations = root.appendingPathComponent("support/project-locations.json")
            cache = root.appendingPathComponent("support/activity-cache.json")
            sources = [
                AgentSource(id: "claude-primary", name: "Claude · Main", configDirectory: root.appendingPathComponent("claude").path,
                            userDataDirectory: root.appendingPathComponent("claude-desktop").path),
                AgentSource(id: "codex", name: "Codex", configDirectory: root.appendingPathComponent("codex-home").path, assistant: .codex),
                AgentSource(id: "grok", name: "Grok", configDirectory: root.appendingPathComponent("grok-home").path, assistant: .grok)
            ]
            try Self.git(original)
            try FileManager.default.createDirectory(at: codexLaunch.appendingPathComponent("work"), withIntermediateDirectories: true)

            // Before the move: Codex from its output folder, Grok from outputs/.
            let roots = [root.appendingPathComponent("Documents/Codex").path, codexLaunch.path]
            try writeCodex("main", parent: nil, roots: roots, edits: [
                ("code-1", original.appendingPathComponent("Sources/App.swift").path, 10),
                ("notes", codexLaunch.appendingPathComponent("work/release-notes.md").path, 20)
            ])
            try writeCodex("reviewer", parent: "main-thread", roots: roots, edits: [])
            try writeCodex("helper", parent: "main-thread", roots: roots, edits: [
                ("helper-1", original.appendingPathComponent("Tests/AppTests.swift").path, 25)
            ])
            try writeGrok([
                ("grok-1", original.appendingPathComponent("README.md").path, 30),
                ("grok-2", original.appendingPathComponent("Sources/Model.swift").path, 31)
            ])

            // The move, leaving a link at the old path.
            try FileManager.default.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: original, to: current)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: current)

            // After the move: the same Codex thread edits the new path; Claude
            // is opened at the new path.
            try appendCodex("main", edits: [("code-2", current.appendingPathComponent("Sources/App.swift").path, 40)])
            try writeClaude(origin: current, sessionID: "local_main", cli: "claude-cli", file: "Sources/Live.swift", seconds: 50)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func composite() -> CompositeActivityProvider {
            CompositeActivityProvider(cacheURL: cache, locationsURL: locations)
        }

        static func git(_ directory: URL) throws {
            let metadata = directory.appendingPathComponent(".git", isDirectory: true)
            try FileManager.default.createDirectory(at: metadata.appendingPathComponent("objects"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: metadata.appendingPathComponent("refs"), withIntermediateDirectories: true)
            try Data("ref: refs/heads/main\n".utf8).write(to: metadata.appendingPathComponent("HEAD"))
        }

        private func stamp(_ seconds: TimeInterval) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: base.addingTimeInterval(seconds))
        }

        private func lines(_ records: [[String: Any]]) throws -> Data {
            var data = Data()
            for record in records {
                data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
                data.append(0x0A)
            }
            return data
        }

        private func codexRollout(_ name: String) -> URL {
            root.appendingPathComponent("codex-home/sessions/2026/10/30/rollout-\(name).jsonl")
        }

        private func codexEdits(_ edits: [(String, String, TimeInterval)]) -> [[String: Any]] {
            edits.map { id, path, seconds in
                ["timestamp": stamp(seconds), "type": "event_msg", "payload": [
                    "type": "item_completed",
                    "item": ["type": "FileChange", "id": id, "status": "completed",
                             "changes": [path: ["type": "add", "unified_diff": "PRIVATE_DIFF"]]]
                ]]
            }
        }

        private func writeCodex(_ name: String, parent: String?, roots: [String], edits: [(String, String, TimeInterval)]) throws {
            var payload: [String: Any] = ["id": "\(name)-thread", "timestamp": stamp(0), "cwd": codexLaunch.path,
                                          "runtime_workspace_roots": roots]
            if let parent { payload["parent_thread_id"] = parent }
            let url = codexRollout(name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try lines([["timestamp": stamp(0), "type": "session_meta", "payload": payload]] + codexEdits(edits)).write(to: url)
        }

        private func appendCodex(_ name: String, edits: [(String, String, TimeInterval)]) throws {
            let handle = try FileHandle(forWritingTo: codexRollout(name))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: lines(codexEdits(edits)))
        }

        private func writeGrok(_ edits: [(String, String, TimeInterval)]) throws {
            let directory = root.appendingPathComponent("grok-home/sessions/encoded-outputs/grok-session")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let summary: [String: Any] = ["info": ["id": "grok-session", "cwd": grokLaunch.path],
                                          "created_at": stamp(1), "last_active_at": stamp(35)]
            try JSONSerialization.data(withJSONObject: summary).write(to: directory.appendingPathComponent("summary.json"))
            var records: [[String: Any]] = []
            for (id, path, seconds) in edits {
                records.append(["timestamp": stamp(seconds), "params": ["update": [
                    "sessionUpdate": "tool_call", "toolCallId": id, "rawInput": ["file_path": path],
                    "_meta": ["x.ai/tool": ["name": "write"]]]]])
                records.append(["timestamp": stamp(seconds + 0.5), "params": ["update": [
                    "sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed",
                    "rawOutput": ["type": "SearchReplace", "EditsApplied": ["absolute_path": path]]]]])
            }
            try lines(records).write(to: directory.appendingPathComponent("updates.jsonl"))
        }

        func writeClaude(origin: URL, sessionID: String, cli: String, file: String, seconds: TimeInterval) throws {
            let metadata = root.appendingPathComponent("claude-desktop/claude-code-sessions/account/org/local_\(sessionID).json")
            try FileManager.default.createDirectory(at: metadata.deletingLastPathComponent(), withIntermediateDirectories: true)
            let created = base.addingTimeInterval(seconds - 5).timeIntervalSince1970 * 1000
            let record: [String: Any] = ["sessionId": sessionID, "cliSessionId": cli, "cwd": origin.path, "originCwd": origin.path,
                                         "createdAt": created, "lastActivityAt": created + 10_000,
                                         "gitAnchors": [["gitRoot": origin.path]]]
            try JSONSerialization.data(withJSONObject: record).write(to: metadata)
            let target = origin.appendingPathComponent(file).path
            let transcript = root.appendingPathComponent("claude/projects/encoded/\(cli).jsonl")
            try FileManager.default.createDirectory(at: transcript.deletingLastPathComponent(), withIntermediateDirectories: true)
            try lines([
                ["type": "assistant", "cwd": origin.path, "message": ["role": "assistant", "content": [
                    ["type": "tool_use", "id": "\(cli)-edit", "name": "Write", "input": ["file_path": target]]]]],
                ["type": "user", "cwd": origin.path, "timestamp": stamp(seconds), "message": ["role": "user", "content": [
                    ["type": "tool_result", "tool_use_id": "\(cli)-edit", "content": "ok"]]],
                 "toolUseResult": ["filePath": target]]
            ]).write(to: transcript)
        }
    }
}
