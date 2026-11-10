import Foundation
import XCTest
@testable import AgentTrailCore

/// Cursor 3.29 live status from each chat's transcript and the running Cursor
/// app, as seen on 3.29.15: about a second into a turn the transcript ends
/// with your message; `turn_ended` closes it, with status `error` after Stop.
final class CursorLiveActivityProviderTests: XCTestCase {
    private var root: URL!
    private var home: URL!
    private var data: URL!
    private let pid: Int32 = 44_383
    /// The Cursor app started ten minutes ago.
    private let appStart = Date().addingTimeInterval(-600)
    private let project = "/Users/someone/Dev/cursor-trail-test"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cursor-live-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home/.cursor", isDirectory: true)
        data = root.appendingPathComponent("Cursor", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var source: AgentSource {
        AgentSource(id: "cursor", name: "Cursor", configDirectory: home.path, userDataDirectory: data.path, assistant: .cursor)
    }

    private func micros(_ date: Date) -> UInt64 { UInt64(date.timeIntervalSince1970 * 1_000_000) }

    private func setTime(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func line(_ object: [String: Any]) throws -> String {
        // Cursor writes keys in this order: role or type first.
        if let role = object["role"] as? String {
            let message = try JSONSerialization.data(withJSONObject: object["message"] ?? [:])
            return "{\"role\":\"\(role)\",\"message\":\(String(decoding: message, as: UTF8.self))}"
        }
        return "{\"type\":\"\(object["type"] ?? "")\",\"status\":\"\(object["status"] ?? "")\"}"
    }

    private func user(_ text: String = "PRIVATE_PROMPT_MARKER") -> [String: Any] {
        ["role": "user", "message": ["content": [["type": "text", "text": text]]]]
    }

    private func assistant() -> [String: Any] {
        ["role": "assistant", "message": ["content": [["type": "tool_use", "name": "Shell", "input": ["command": "PRIVATE"]]]]]
    }

    private let ended: [String: Any] = ["type": "turn_ended", "status": "success"]

    /// Writes a chat's transcript under `slug` and dates it.
    @discardableResult
    private func transcript(_ id: String, slug: String = "Users-someone-Dev-cursor-trail-test", lines: [[String: Any]],
                            at date: Date, subagentOf parent: String? = nil, raw: String? = nil) throws -> URL {
        var folder = home.appendingPathComponent("projects/\(slug)/agent-transcripts/\(parent ?? id)", isDirectory: true)
        if parent != nil { folder = folder.appendingPathComponent("subagents", isDirectory: true) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(id).jsonl")
        let text = try raw ?? (lines.map { try line($0) }.joined(separator: "\n") + "\n")
        try text.write(to: file, atomically: true, encoding: .utf8)
        try setTime(file, date)
        return file
    }

    /// A Cursor app for this profile's data folder, started at `appStart`;
    /// every chat id maps to `project`.
    /// Folder lookups, by the chat ids asked for.
    private var lookups: [[String]] = []

    private func provider(apps: [CursorLiveActivityProvider.CursorApp]? = nil, alive: Bool = true,
                          folders: [String: String]? = nil) -> CursorLiveActivityProvider {
        let apps = apps ?? [.init(pid: pid, start: micros(appStart), userDataDirectory: data.path)]
        let starts = Dictionary(uniqueKeysWithValues: apps.map { ($0.pid, $0.start) })
        let project = self.project
        return CursorLiveActivityProvider(
            processStartTimes: { pids in alive ? starts.filter { pids.contains($0.key) } : [:] },
            cursorApps: { apps },
            folderLookup: { [weak self] _, ids in
                self?.lookups.append(ids)
                if let folders { return folders.filter { ids.contains($0.key) } }
                return Dictionary(uniqueKeysWithValues: ids.map { ($0, canonicalPath(project)) })
            },
            transcriptHome: home)
    }

    func testATranscriptEndingWithYourMessageIsWorkingUntilItsTurnEnds() throws {
        let opened = Date().addingTimeInterval(-10)
        // Running: this turn's message is the last line.
        try transcript("8aae7e0e-fa5c-4409-aa06-26615e7adc92", lines: [user(), assistant(), ended, user()], at: opened)
        // Finished, and stopped (Stop writes status error).
        try transcript("11111111-1111-4111-8111-111111111111", lines: [user(), assistant(), ended], at: opened)
        try transcript("22222222-2222-4222-8222-222222222222",
                       lines: [user(), ["type": "turn_ended", "status": "error"]], at: opened)
        // An assistant line last: the turn's closing write is under way.
        try transcript("33333333-3333-4333-8333-333333333333", lines: [user(), assistant()], at: opened)
        // A subagent's transcript is not a chat of its own.
        try transcript("44444444-4444-4444-8444-444444444444", lines: [user()], at: opened,
                       subagentOf: "11111111-1111-4111-8111-111111111111")
        let snapshot = provider().scan(sources: [source])
        XCTAssertEqual(Set(snapshot.sessions.map(\.sessionID)),
                       ["8aae7e0e-fa5c-4409-aa06-26615e7adc92", "33333333-3333-4333-8333-333333333333"])
        let session = try XCTUnwrap(snapshot.sessions.first { $0.sessionID.hasPrefix("8aae") })
        XCTAssertEqual(session.status, .working)
        XCTAssertEqual(session.projectPath, canonicalPath(project))
        XCTAssertEqual(session.pid, pid)
        XCTAssertEqual(session.details.hostBundleID, "com.todesktop.230313mzl4w4u92")
        XCTAssertEqual(session.details.stateSince.map { Int($0.timeIntervalSince1970) }, Int(opened.timeIntervalSince1970))
        XCTAssertEqual(snapshot.notices, [])
    }

    func testOnlyARunningCursorStartedBeforeTheWriteVouchesForTheTurn() throws {
        // Left open when an earlier Cursor quit mid-turn: written before this app started.
        try transcript("55555555-5555-4555-8555-555555555555", lines: [user()], at: appStart.addingTimeInterval(-60))
        try transcript("66666666-6666-4666-8666-666666666666", lines: [user()], at: Date().addingTimeInterval(-5))
        XCTAssertEqual(provider().scan(sources: [source]).sessions.map(\.sessionID), ["66666666-6666-4666-8666-666666666666"])
        // Cursor not running.
        XCTAssertEqual(provider(apps: []).scan(sources: [source]).sessions, [])
        // Cursor running for another data folder only.
        let other = CursorLiveActivityProvider.CursorApp(pid: pid, start: micros(appStart), userDataDirectory: "/tmp/elsewhere")
        XCTAssertEqual(provider(apps: [other]).scan(sources: [source]).sessions, [])
        // Gone (or its PID reused) by the time the transcripts were read.
        XCTAssertEqual(provider(alive: false).scan(sources: [source]).sessions, [])
    }

    func testAChatWithoutAKnownFolderIsNotShown() throws {
        try transcript("77777777-7777-4777-8777-777777777777", lines: [user()], at: Date().addingTimeInterval(-5))
        XCTAssertEqual(provider(folders: [:]).scan(sources: [source]).sessions, [])
    }

    /// The app writes transcripts to ~/.cursor whatever CLI home the profile
    /// names, a chat's folder is looked up once, and a transcript that did not
    /// change is not read again.
    func testFoldersAreLookedUpOnceAndTranscriptsFollowTheirChanges() throws {
        let custom = AgentSource(id: "cursor", name: "Cursor", configDirectory: root.appendingPathComponent("cli-home").path,
                                 userDataDirectory: data.path, assistant: .cursor)
        let id = "88888888-8888-4888-8888-888888888888"
        let file = try transcript(id, lines: [user()], at: Date().addingTimeInterval(-20))
        let reader = provider()
        XCTAssertEqual(reader.scan(sources: [custom]).sessions.map(\.sessionID), [id])
        XCTAssertEqual(reader.scan(sources: [custom]).sessions.map(\.sessionID), [id])
        XCTAssertEqual(lookups, [[id]], "the folder is remembered")
        // The turn ends: the file changes, so it is read again.
        try (try line(user()) + "\n" + line(ended) + "\n").write(to: file, atomically: true, encoding: .utf8)
        try setTime(file, Date().addingTimeInterval(-10))
        XCTAssertEqual(reader.scan(sources: [custom]).sessions, [])
    }

    func testTheInstanceMustUseTheProfilesDataFolder() {
        let custom = URL(fileURLWithPath: "/Users/someone/Library/Application Support/Cursor-Work", isDirectory: true)
        let standard = URL(fileURLWithPath: ("~/Library/Application Support/Cursor" as NSString).expandingTildeInPath, isDirectory: true)
        let plain = CursorLiveActivityProvider.CursorApp(pid: 10, start: 200, userDataDirectory: nil)
        let older = CursorLiveActivityProvider.CursorApp(pid: 11, start: 100, userDataDirectory: nil)
        let work = CursorLiveActivityProvider.CursorApp(pid: 12, start: 50, userDataDirectory: custom.path)
        XCTAssertEqual(CursorLiveActivityProvider.instance(for: standard, among: [plain, older, work])?.pid, 11)
        XCTAssertEqual(CursorLiveActivityProvider.instance(for: custom, among: [plain, older, work])?.pid, 12)
        XCTAssertNil(CursorLiveActivityProvider.instance(for: custom, among: [plain, older]))
    }

    func testFoldersComeFromCursorsChatHeaderThenItsRecord() throws {
        let f = try CursorFixture()
        defer { f.remove() }
        try f.headerTable([("h1", nil, f.head("h1", folder: f.project.path))])
        var remote = f.head("r1", folder: "/home/someone/app")
        remote["workspaceIdentifier"] = ["id": "x", "uri": ["scheme": "vscode-remote", "fsPath": "/home/someone/app",
                                                              "path": "/home/someone/app"]]
        try f.headerTable([("r1", nil, remote)])
        try f.put([("composerData:c1", f.composer("c1", bubbles: [], created: 0, updated: 1,
                                                    extra: ["trackedGitRepos": [["repoPath": f.project.path]]]))])
        // A file URI saved without fsPath, a remote chat with a repository, and a multi-root workspace.
        var bare = f.head("p1", folder: f.project.path)
        bare["workspaceIdentifier"] = ["id": "y", "uri": ["scheme": "file", "path": f.project.path]]
        try f.headerTable([("p1", nil, bare)])
        try f.put([("composerData:r2", f.composer("r2", bubbles: [], created: 0, updated: 1, extra: [
            "workspaceIdentifier": ["id": "z", "uri": ["scheme": "vscode-remote", "path": "/srv/app"]],
            "trackedGitRepos": [["repoPath": "/srv/app"]]])),
                   ("composerData:m1", f.composer("m1", bubbles: [], created: 0, updated: 1, extra: [
            "workspaceIdentifier": ["id": "w", "configPath": ["scheme": "file", "fsPath": "/Users/someone/both.code-workspace"]],
            "trackedGitRepos": [["repoPath": f.project.path]]]))])
        // History leaves a rollback-journal database alone just after a change; so does this.
        XCTAssertEqual(CursorLiveActivityProvider.readFolders(f.userData, ids: ["h1"]), [:])
        try setTime(f.database, Date().addingTimeInterval(-30))
        let folders = CursorLiveActivityProvider.readFolders(f.userData, ids: ["h1", "r1", "c1", "missing", "p1", "r2", "m1"])
        XCTAssertEqual(folders, ["h1": canonicalPath(f.project.path), "c1": canonicalPath(f.project.path),
                                 "p1": canonicalPath(f.project.path)])
    }

    func testTheLastLineIsFoundFromItsOpeningBytes() throws {
        func kind(_ raw: String) throws -> CursorLiveActivityProvider.LastLine {
            let file = try transcript("99999999-9999-4999-8999-999999999999", lines: [], at: Date(), raw: raw)
            return CursorLiveActivityProvider.lastLine(of: file, size: UInt64(try Data(contentsOf: file).count))
        }
        let end = try line(ended)
        let message = try line(user())
        XCTAssertEqual(try kind(message), .message, "a file of one line")
        XCTAssertEqual(try kind(end + "\n" + message + "\n\n"), .message, "trailing newlines")
        XCTAssertEqual(try kind(message + "\r\n" + end + "\r\n"), .turnEnded)
        XCTAssertEqual(try kind(message + "\n{\"type\":\"turn_ended\",\"status\":\"aborted\"}\n"), .turnEnded)
        // A prompt longer than one read chunk still opens with its role.
        let long = try line(user(String(repeating: "x", count: 200_000)))
        XCTAssertEqual(try kind(end + "\n" + long + "\n"), .message)
        // A kind this version does not know never claims a running turn.
        XCTAssertEqual(try kind(message + "\n{\"type\":\"turn_paused\"}\n"), .other)
        XCTAssertEqual(try kind("\n\n"), .other)
    }
}
