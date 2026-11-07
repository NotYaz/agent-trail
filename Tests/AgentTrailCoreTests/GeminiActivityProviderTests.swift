import Foundation
import XCTest
@testable import AgentTrailCore

final class GeminiActivityProviderTests: XCTestCase {
    private let sessionID = "5f0c2d1e-8a7b-4c3d-9e2f-1a2b3c4d5e6f"
    private let fileName = "session-2026-10-26T08-00-5f0c2d1e.jsonl"

    func testSuccessfulWriteAndReplaceCountAtTheirToolCallTimes() throws {
        let f = try GeminiFixture()
        defer { f.remove() }
        let folder = try f.folder()
        let edited = f.project.appendingPathComponent("Sources/App.swift").path
        let created = f.project.appendingPathComponent("README.md").path
        let first = f.call("replace-1", seconds: 20, file: edited)
        let second = f.call("write-1", name: "write_file", seconds: 30, file: created)
        try f.write([
            f.header(sessionID),
            f.user("u1", seconds: 1),
            f.reply("m1", seconds: 2, calls: [first]),
            // Every change appends the whole message again, earlier calls included.
            f.reply("m1", seconds: 2, calls: [first, second]),
            ["$set": ["lastUpdated": f.iso(40)]],
            f.reply("m1", seconds: 2, calls: [first, second])
        ], to: fileName, in: folder)
        let result = f.provider().scan(sources: [f.source])
        let project = try XCTUnwrap(result.projects.first { $0.path == canonicalPath(f.project.path) })
        XCTAssertEqual(project.recordedEditCount, 2)
        XCTAssertEqual(project.sessionCount, 1)
        XCTAssertEqual(project.activities.first?.editMoments.map(\.date), [f.date(20), f.date(30)])
        XCTAssertEqual(result.sessionTrails.first?.sessionID, sessionID)
        XCTAssertEqual(result.sessionTrails.first?.createdAt, f.date(0))
        XCTAssertEqual(result.sessionTrails.first?.latestActivity, f.date(40))
        XCTAssertEqual(result.notices, [])
    }

    func testFailedCancelledShellAndOtherToolsDoNotCount() throws {
        let f = try GeminiFixture()
        defer { f.remove() }
        let folder = try f.folder()
        let file = f.project.appendingPathComponent("a.txt").path
        try f.write([
            f.header(sessionID),
            f.user("u1", seconds: 1),
            f.reply("m1", seconds: 2, calls: [
                f.call("c1", status: "error", seconds: 10, file: file),
                // A rejected confirmation is recorded as cancelled.
                f.call("c2", name: "write_file", status: "cancelled", seconds: 11, file: file),
                f.call("c3", name: "run_shell_command", seconds: 12, file: file),
                f.call("c4", name: "read_file", seconds: 13, file: file),
                // Gemini CLI has no tool by this name; an MCP server's tool could use it.
                f.call("c5", name: "edit", seconds: 14, file: file),
                f.call("c6", status: "awaiting_approval", seconds: 15, file: file)
            ])
        ], to: fileName, in: folder)
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 0)
        XCTAssertEqual(result.projects.first?.sessionCount, 1)
        XCTAssertEqual(result.notices, [])
    }

    func testWorkspaceComesOnlyFromAFolderWhoseHashMatches() throws {
        let f = try GeminiFixture()
        defer { f.remove() }
        let other = f.root.appendingPathComponent("other", isDirectory: true)
        let second = f.root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        // The folder's name and its marker name other projects: neither hashes to the session's.
        let decoy = try f.folder("project", root: other.path)
        try f.write([
            f.header(sessionID), f.user("u1", seconds: 1),
            f.reply("m1", seconds: 2, calls: [f.call("c1", seconds: 3, file: f.project.appendingPathComponent("a.txt").path)])
        ], to: fileName, in: decoy)
        var result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects, [])
        XCTAssertEqual(result.notices, [
            "Gemini: some Gemini CLI sessions name a project folder that Gemini's own records on this Mac don't list; they are skipped."
        ])

        // A folder from before 0.29 is named by the hash and has no marker; projects.json names the project.
        let hashed = try f.folder(GeminiFixture.hash(second.path), marker: false)
        let otherID = "7a6b5c4d-1111-4222-8333-944455556666"
        try f.write([
            f.header(otherID, root: second.path), f.user("u1", seconds: 1),
            f.reply("m1", seconds: 2, calls: [f.call("c2", seconds: 4, file: second.appendingPathComponent("b.txt").path)])
        ], to: "session-2026-01-05T09-30-7a6b5c4d.jsonl", in: hashed)
        try JSONSerialization.data(withJSONObject: ["projects": [second.path: "second"]])
            .write(to: f.home.appendingPathComponent("projects.json"))
        result = f.provider().scan(sources: [f.source])
        let project = try XCTUnwrap(result.projects.first)
        XCTAssertEqual(result.projects.count, 1)
        XCTAssertEqual(project.path, canonicalPath(second.path))
        XCTAssertEqual(project.recordedEditCount, 1)
        XCTAssertEqual(result.notices.count, 1, "the decoy session is still unverified")
    }

    func testFilesOutsideTheProjectAndGeminisOwnFoldersDoNotCount() throws {
        let f = try GeminiFixture()
        defer { f.remove() }
        // A checkout that also holds this profile's Gemini home, where plan mode writes plans.
        try f.git(f.project)
        let home = f.project.appendingPathComponent("tools/.gemini", isDirectory: true)
        let source = AgentSource(id: "gemini", name: "Gemini", configDirectory: home.path, assistant: .gemini)
        let folder = try f.folder(runtime: home)
        let inside = f.project.appendingPathComponent("a.txt").path
        let outside = f.root.appendingPathComponent("elsewhere/b.txt").path
        let plan = folder.appendingPathComponent("\(sessionID)/plans/plan.md").path
        try f.write([
            f.header(sessionID), f.user("u1", seconds: 1),
            f.reply("m1", seconds: 2, calls: [
                f.call("c1", seconds: 10, file: inside),
                f.call("c2", seconds: 11, file: outside),
                f.call("c3", name: "write_file", seconds: 12, file: plan)
            ])
        ], to: fileName, in: folder)
        let result = f.provider().scan(sources: [source])
        let project = try XCTUnwrap(result.projects.first { $0.path == canonicalPath(f.project.path) })
        XCTAssertEqual(project.recordedEditCount, 1)
        XCTAssertEqual(project.activities.first?.editMoments.map(\.date), [f.date(10)])
        XCTAssertEqual(result.projects.reduce(0) { $0 + $1.recordedEditCount }, 1)
    }

    func testCacheKeepsNoContentAndSurvivesReload() throws {
        let f = try GeminiFixture()
        defer { f.remove() }
        let folder = try f.folder()
        try f.write([
            f.header(sessionID), f.user("u1", seconds: 1),
            f.reply("m1", seconds: 2, calls: [f.call("c1", seconds: 10, file: f.project.appendingPathComponent("a.txt").path)]),
            ["$set": ["summary": "PRIVATE_PROMPT_MARKER", "memoryScratchpad": ["version": 1, "workflowSummary": "PRIVATE_PROMPT_MARKER"]]]
        ], to: fileName, in: folder)
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

    func testAppendRewriteAndLeftoverFiles() throws {
        let f = try GeminiFixture()
        defer { f.remove() }
        let folder = try f.folder()
        let a = f.project.appendingPathComponent("a.txt").path
        let b = f.project.appendingPathComponent("b.txt").path
        let url = try f.write([
            f.header(sessionID), f.user("u1", seconds: 1),
            f.reply("m1", seconds: 2, calls: [f.call("c1", seconds: 10, file: a)])
        ], to: fileName, in: folder)
        // What an interrupted rewrite leaves behind is never read.
        let stray = [f.header(sessionID), f.user("u9", seconds: 1),
                     f.reply("m9", seconds: 2, calls: [f.call("c9", seconds: 50, file: b)])]
        try f.write(stray, to: fileName + ".tmp-4242", in: folder)
        try f.write(stray, to: fileName + ".unreadable-1793000000000", in: folder)
        let provider = f.provider()
        XCTAssertEqual(provider.scan(sources: [f.source]).projects.first?.recordedEditCount, 1)

        try f.write([f.user("u2", seconds: 20), f.reply("m2", seconds: 21, calls: [f.call("c2", seconds: 22, file: b)])],
                    to: fileName, in: folder, append: true)
        XCTAssertEqual(provider.scan(sources: [f.source]).projects.first?.recordedEditCount, 2)

        // The CLI's fallback rewrite replaces the file (a new inode) with what it still holds.
        try f.write([f.header(sessionID), f.user("u2", seconds: 20),
                     f.reply("m2", seconds: 21, calls: [f.call("c2", seconds: 22, file: b)])],
                    to: fileName, in: folder, atomic: true)
        let result = provider.scan(sources: [f.source])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 1)
        XCTAssertEqual(result.projects.first?.activities.first?.editMoments.map(\.date), [f.date(22)])
        XCTAssertEqual(FileStat.of(url.path)?.kind, .regular)
    }

    func testMissingStoreGivesOneNotice() throws {
        let f = try GeminiFixture()
        defer { f.remove() }
        let source = AgentSource(id: "gemini", name: "Gemini", configDirectory: f.root.appendingPathComponent("none/.gemini").path,
                                 assistant: .gemini)
        XCTAssertEqual(f.provider().scan(sources: [source]).notices, ["Gemini: no local Gemini CLI history was found."])
    }

    func testFileWithoutATurnIsNotASession() throws {
        let f = try GeminiFixture()
        defer { f.remove() }
        let folder = try f.folder()
        // A CLI that was started and never prompted: a header and an info line.
        var info = f.user("i1", seconds: 1)
        info["type"] = "info"
        try f.write([f.header(sessionID), info], to: fileName, in: folder)
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects, [])
        XCTAssertEqual(result.notices, [])
    }

    func testRewindsPatchesAndCheckpointsKeepRecordedEdits() throws {
        let f = try GeminiFixture()
        defer { f.remove() }
        let folder = try f.folder()
        let a = f.project.appendingPathComponent("a.txt").path
        let b = f.project.appendingPathComponent("b.txt").path
        let c = f.project.appendingPathComponent("c.txt").path
        try f.write([
            f.header(sessionID), f.user("u1", seconds: 1),
            f.reply("m1", seconds: 2, calls: [f.call("c1", seconds: 10, file: a)]),
            // A rewind or a compression hides messages from the model; the edit still happened.
            ["$rewindTo": "u1"],
            ["$patch": ["removeIds": ["m1"], "toolCalls": [["id": "c1", "result": []]], "id": "m1"]],
            f.user("u2", seconds: 20),
            f.reply("m2", seconds: 21, calls: [f.call("c2", seconds: 22, file: b)]),
            // The deprecated full checkpoint is scanned like messages.
            ["$set": ["messages": [f.reply("m3", seconds: 30, calls: [f.call("c3", seconds: 31, file: c)])]]]
        ], to: fileName, in: folder)
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 3)
        XCTAssertEqual(result.notices, [])
    }

    func testLegacyJSONSessionAndItsMigratedLogCountOnce() throws {
        let f = try GeminiFixture()
        defer { f.remove() }
        let folder = try f.folder()
        let a = f.project.appendingPathComponent("a.txt").path
        let b = f.project.appendingPathComponent("b.txt").path
        let stem = "session-2025-12-01T10-00-5f0c2d1e"
        let messages = [f.user("u1", seconds: 1), f.reply("m1", seconds: 2, calls: [f.call("c1", seconds: 10, file: a)])]
        var record = f.header(sessionID)
        record["messages"] = messages
        record["summary"] = "PRIVATE_PROMPT_MARKER"
        try JSONSerialization.data(withJSONObject: record)
            .write(to: folder.appendingPathComponent("chats/\(stem).json"))
        let provider = f.provider()
        var result = provider.scan(sources: [f.source])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 1)
        XCTAssertEqual(result.projects.first?.sessionCount, 1)

        // Resuming copies the whole record to `<name>.jsonl` and appends there.
        try f.write([f.header(sessionID)] + messages
                    + [f.user("u2", seconds: 20), f.reply("m2", seconds: 21, calls: [f.call("c2", seconds: 22, file: b)])],
                    to: "\(stem).jsonl", in: folder)
        result = provider.scan(sources: [f.source])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 2)
        XCTAssertEqual(result.projects.first?.sessionCount, 1)
        XCTAssertEqual(result.notices, [])
    }

    func testRelativeAndCreatedPathsFromOlderBuilds() throws {
        let f = try GeminiFixture()
        defer { f.remove() }
        let folder = try f.folder()
        try f.write([
            f.header(sessionID), f.user("u1", seconds: 1),
            f.reply("m1", seconds: 2, calls: [
                // v0.20 to v0.24 record no `filePath`; the argument may be relative to the project.
                f.call("c1", name: "write_file", seconds: 10, file: "Sources/a.swift", filePath: false),
                // `replace` creating a file shows a sentence instead of a diff.
                f.call("c2", seconds: 11, file: f.project.appendingPathComponent("new.txt").path, display: "Created new.txt"),
                // A home-relative argument is not resolved.
                f.call("c3", name: "write_file", seconds: 12, file: "~/notes.txt", filePath: false)
            ])
        ], to: fileName, in: folder)
        let result = f.provider().scan(sources: [f.source])
        let trail = try XCTUnwrap(result.sessionTrails.first)
        XCTAssertEqual(trail.edits.map(\.date), [f.date(10), f.date(11)])
        XCTAssertEqual(Set(trail.edits.map(\.projectPath)), [canonicalPath(f.project.path)])
    }

    func testSubagentEditsJoinTheirRootSessionAsDelegated() throws {
        let f = try GeminiFixture()
        defer { f.remove() }
        let folder = try f.folder()
        let agentID = "9d8c7b6a-5f4e-4d3c-8b2a-190817161514"
        var invoke = f.call("agent-call", name: "codebase_investigator", seconds: 25, file: "")
        invoke["agentId"] = agentID
        try f.write([
            f.header(sessionID), f.user("u1", seconds: 1),
            f.reply("m1", seconds: 2, calls: [f.call("c1", seconds: 10, file: f.project.appendingPathComponent("a.txt").path), invoke])
        ], to: fileName, in: folder)
        var header = f.header(agentID, seconds: 15, kind: "subagent")
        header["directories"] = [f.project.path]
        try f.write([
            header, f.user("s0", seconds: 16),
            f.reply("s1", seconds: 17, calls: [f.call("c2", seconds: 20, file: f.project.appendingPathComponent("b.txt").path)])
        ], to: "\(sessionID)/\(agentID).jsonl", in: folder)
        let result = f.provider().scan(sources: [f.source])
        let project = try XCTUnwrap(result.projects.first)
        XCTAssertEqual(project.recordedEditCount, 2)
        XCTAssertEqual(project.sessionCount, 1)
        XCTAssertEqual(project.activities.first?.editMoments.filter(\.delegated).map(\.date), [f.date(20)])
        XCTAssertEqual(result.sessionTrails.map(\.sessionID), [sessionID])
    }

    func testImportedSessionCopiesAreCountedOnce() throws {
        let f = try GeminiFixture()
        defer { f.remove() }
        let folder = try f.folder()
        let a = f.project.appendingPathComponent("a.txt").path
        let b = f.project.appendingPathComponent("b.txt").path
        let copied = [f.user("u1", seconds: 1), f.reply("m1", seconds: 2, calls: [f.call("c1", seconds: 10, file: a)])]
        try f.write([f.header(sessionID)] + copied, to: fileName, in: folder)
        // `--session-file` copies the messages, ids and times included, under a new session id.
        let importedID = "0a1b2c3d-4e5f-4a6b-8c7d-8e9fa0b1c2d3"
        var info = f.user("import-1793000100000", seconds: 100)
        info["type"] = "info"
        try f.write([f.header(importedID, seconds: 100), info] + copied
                    + [f.user("u2", seconds: 110), f.reply("m2", seconds: 111, calls: [f.call("c2", seconds: 112, file: b)])],
                    to: "session-1793000100000-0a1b2c3d.jsonl", in: folder)
        let result = f.provider().scan(sources: [f.source])
        let project = try XCTUnwrap(result.projects.first)
        XCTAssertEqual(project.recordedEditCount, 2)
        XCTAssertEqual(project.sessionCount, 2)
        XCTAssertEqual(result.sessionTrails.first { $0.sessionID == sessionID }?.edits.map(\.date), [f.date(10)])
        XCTAssertEqual(result.sessionTrails.first { $0.sessionID == importedID }?.edits.map(\.date), [f.date(112)])
    }

    func testSandboxRuntimeFolderIsRead() throws {
        let f = try GeminiFixture()
        defer { f.remove() }
        // Under Seatbelt the CLI writes beside the home, in `.cache/.gemini`.
        let runtime = f.root.appendingPathComponent("user/.cache/.gemini", isDirectory: true)
        let folder = try f.folder(runtime: runtime)
        try f.write([
            f.header(sessionID), f.user("u1", seconds: 1),
            f.reply("m1", seconds: 2, calls: [f.call("c1", seconds: 10, file: f.project.appendingPathComponent("a.txt").path)])
        ], to: fileName, in: folder)
        let result = f.provider().scan(sources: [f.source])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 1)
        XCTAssertEqual(result.notices, [])
    }

    func testSHA256MatchesNodeDigests() {
        XCTAssertEqual(GeminiSHA256.hex([]), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(GeminiSHA256.hex(Array("abc".utf8)), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(GeminiSHA256.hex(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(GeminiSHA256.hex(Array(String(repeating: "a", count: 1000).utf8)),
                       "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
        let path = "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/Projects/a-rather-long-project-folder-name/with/nested/levels"
        XCTAssertEqual(GeminiSHA256.hex(Array(path.utf8)), "55704fae36a68a6ac0e4daca14576a1631efd50b2eeb773642606162a3507b16")
    }
}

/// Synthetic Gemini CLI stores in a temporary folder.
final class GeminiFixture {
    let root: URL
    let project: URL
    let home: URL
    let cache: URL
    let source: AgentSource
    let base = Date(timeIntervalSince1970: 1_793_000_000)

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("agent-trail-gemini-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        home = root.appendingPathComponent("user/.gemini", isDirectory: true)
        cache = root.appendingPathComponent("cache/activity-cache-gemini.json")
        source = AgentSource(id: "gemini", name: "Gemini", configDirectory: home.path, assistant: .gemini)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func provider() -> GeminiActivityProvider { GeminiActivityProvider(cacheURL: cache) }
    func date(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    func iso(_ seconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date(seconds))
    }

    static func hash(_ path: String) -> String { GeminiSHA256.hex(Array(path.utf8)) }

    /// `tmp/<slug>/chats`, with the `.project_root` marker Gemini 0.29 and later write.
    @discardableResult
    func folder(_ slug: String = "project", root: String? = nil, marker: Bool = true, runtime: URL? = nil) throws -> URL {
        let folder = (runtime ?? home).appendingPathComponent("tmp", isDirectory: true)
            .appendingPathComponent(slug, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("chats", isDirectory: true),
                                                withIntermediateDirectories: true)
        if marker {
            try Data((root ?? project.path).utf8).write(to: folder.appendingPathComponent(".project_root"))
        }
        return folder
    }

    func git(_ directory: URL) throws {
        let metadata = directory.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata.appendingPathComponent("objects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: metadata.appendingPathComponent("HEAD"))
    }

    // Records.

    func header(_ id: String, seconds: TimeInterval = 0, root: String? = nil, kind: String? = nil) -> [String: Any] {
        var header: [String: Any] = ["sessionId": id, "projectHash": Self.hash(root ?? project.path),
                                     "startTime": iso(seconds), "lastUpdated": iso(seconds)]
        if let kind { header["kind"] = kind }
        return header
    }

    func user(_ id: String, seconds: TimeInterval) -> [String: Any] {
        ["id": id, "timestamp": iso(seconds), "type": "user", "content": [["text": "PRIVATE_PROMPT_MARKER"]]]
    }

    func reply(_ id: String, seconds: TimeInterval, calls: [[String: Any]]) -> [String: Any] {
        ["id": id, "timestamp": iso(seconds), "type": "gemini", "content": "PRIVATE_PROMPT_MARKER", "toolCalls": calls,
         "thoughts": [["subject": "PRIVATE_PROMPT_MARKER", "description": "PRIVATE_PROMPT_MARKER", "timestamp": iso(seconds)]],
         "model": "gemini-3-pro-preview"]
    }

    /// A completed tool call as `recordCompletedToolCalls` writes it.
    func call(_ id: String, name: String = "replace", status: String = "success", seconds: TimeInterval, file: String,
              filePath: Bool = true, display: Any? = nil) -> [String: Any] {
        var diff: [String: Any] = ["fileDiff": "PRIVATE_CONTENT_MARKER", "fileName": (file as NSString).lastPathComponent,
                                   "originalContent": "PRIVATE_CONTENT_MARKER", "newContent": "PRIVATE_CONTENT_MARKER",
                                   "isNewFile": false, "isBuildFile": false]
        if filePath { diff["filePath"] = file }
        let resultDisplay: Any = display ?? diff
        return ["id": id, "name": name, "status": status, "timestamp": iso(seconds),
                "args": ["file_path": file, "old_string": "PRIVATE_CONTENT_MARKER", "new_string": "PRIVATE_CONTENT_MARKER"],
                "result": [["functionResponse": ["id": id, "name": name, "response": ["output": "PRIVATE_CONTENT_MARKER"]]]],
                "resultDisplay": resultDisplay, "displayName": "Edit", "description": "PRIVATE_PROMPT_MARKER",
                "renderOutputAsMarkdown": false]
    }

    /// Writes JSONL records to `chats/<name>`: replacing the file, appending
    /// to it, or replacing it atomically with a new inode.
    @discardableResult
    func write(_ lines: [[String: Any]], to name: String, in folder: URL, append: Bool = false, atomic: Bool = false) throws -> URL {
        let url = folder.appendingPathComponent("chats", isDirectory: true).appendingPathComponent(name)
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
