import Foundation
import XCTest
@testable import AgentTrailCore

final class OpenCodeLiveActivityProviderTests: XCTestCase {
    /// Ten seconds ago, in the fixture's seconds (its base is two hours ago).
    private let recent: TimeInterval = 7_190

    @discardableResult
    private func register(_ f: OpenCodeFixture, pid: Any = 4242) throws -> URL {
        let folder = f.home.appendingPathComponent(".local/state/opencode", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("service.json")
        let object: [String: Any] = ["id": "svc_1", "version": "2.2.6", "url": "http://127.0.0.1:4096", "pid": pid,
                                     "password": "PRIVATE_PASSWORD_MARKER"]
        try JSONSerialization.data(withJSONObject: object).write(to: file)
        return file
    }

    /// A service process that started `offset` seconds after its registration was written.
    /// `otherServers` lists other OpenCode servers; by default there are none.
    private func provider(_ f: OpenCodeFixture, registration: URL, pid: Int32 = 4242, offset: TimeInterval = -60,
                          alive: Bool = true,
                          otherServers: @escaping () -> [Int32: UInt64]? = { [:] }) -> OpenCodeLiveActivityProvider {
        let written = FileStat.of(registration.path)?.modified ?? Date()
        let start = UInt64((written.timeIntervalSince1970 + offset) * 1_000_000)
        return OpenCodeLiveActivityProvider(processStartTimes: { pids in alive && pids.contains(pid) ? [pid: start] : [:] },
                                            otherServers: otherServers, home: f.home.path)
    }

    /// One row of OpenCode's event log, which it writes only with event persistence on.
    private func event(_ f: OpenCodeFixture, session: String, seq: Int, _ type: String, reason: String? = nil) throws {
        try f.exec("CREATE TABLE IF NOT EXISTS event (id text PRIMARY KEY, aggregate_id text NOT NULL, seq integer NOT NULL, created integer NOT NULL DEFAULT 0, type text NOT NULL, data text NOT NULL); CREATE UNIQUE INDEX IF NOT EXISTS event_aggregate_seq_idx ON event (aggregate_id, seq)")
        var data: [String: Any] = ["sessionID": session]
        if let reason { data["reason"] = reason }
        let text = try f.json(data)
        try f.run("INSERT INTO event (id, aggregate_id, seq, created, type, data) VALUES (?, ?, ?, ?, ?, ?)",
                  ["evt_\(session)_\(seq)", session, seq, f.ms(recent), type, text])
    }

    func testExecutingSessionsAreWorkingAndAnOpenQuestionNeedsInput() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        try f.createV2()
        // Executing, with an edit that started two seconds ago.
        try f.session("ses_work", directory: f.project, created: 0, busy: recent)
        try f.message("msg_w", session: "ses_work", seq: 1, created: recent, data: f.assistant([
            f.tool("call_w", "edit", status: "running", ran: recent + 8, input: ["path": "a.txt"])], created: recent))
        // Executing, and its current step asks the user a question.
        try f.session("ses_ask", directory: f.project, created: 0, busy: recent)
        try f.message("msg_a1", session: "ses_ask", seq: 1, created: 10, data: f.assistant([
            f.question("call_old", status: "completed")], created: 10, completed: 11))
        try f.message("msg_a2", session: "ses_ask", seq: 2, created: recent, data: f.assistant([
            f.question("call_q", status: "running", ran: recent + 1)], created: recent))
        // The same through a part row.
        try f.session("ses_part", directory: f.project, created: 0, busy: recent)
        try f.message("msg_p", session: "ses_part", seq: 1, created: recent, data: f.assistant([], created: recent))
        try f.part("msg_p", session: "ses_part", ordinal: 0, item: f.question("call_p", status: "running", ran: recent + 2))
        // Finished: idle after busy. An answered question no longer waits.
        try f.session("ses_idle", directory: f.project, created: 0, busy: recent, idle: recent + 1)
        try f.session("ses_answered", directory: f.project, created: 0, busy: recent)
        try f.message("msg_n", session: "ses_answered", seq: 1, created: recent, data: f.assistant([
            f.question("call_n", status: "completed")], created: recent))
        let registration = try register(f)
        let snapshot = provider(f, registration: registration).scan(sources: [f.source])
        let statuses = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.sessionID, $0.status) })
        XCTAssertEqual(statuses, ["ses_work": .working, "ses_ask": .waiting, "ses_part": .waiting, "ses_answered": .working])
        XCTAssertEqual(snapshot.sessions.first { $0.sessionID == "ses_ask" }?.details.stateSince, f.date(recent + 1))
        XCTAssertEqual(snapshot.sessions.first { $0.sessionID == "ses_work" }?.details.stateSince, f.date(recent))
        XCTAssertEqual(snapshot.sessions.first?.status, .waiting)
        XCTAssertEqual(snapshot.sessions.first?.pid, 4242)
        XCTAssertEqual(snapshot.sessions.first?.projectPath, canonicalPath(f.project.path))
        XCTAssertEqual(snapshot.notices, [])
    }

    /// OpenCode stores a call held by an approval prompt exactly like one that
    /// runs: `running`, with `ran` set when the prompt opens (seen on 2.2.7).
    func testAQuickFileCallRunningForSecondsWaitsForApproval() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        try f.createV2()
        func step(_ session: String, _ items: [[String: Any]], seq: Int = 1) throws {
            try f.message("msg_\(session)_\(seq)", session: session, seq: seq, created: recent,
                          data: f.assistant(items, created: recent))
        }
        for id in ["ses_write", "ses_read", "ses_patch", "ses_fresh", "ses_long", "ses_older", "ses_text"] {
            try f.session(id, directory: f.project, created: 0, busy: recent)
        }
        // A write held for ten seconds, and a read outside the project held as long.
        try step("ses_write", [f.tool("call_w", "write", status: "running", ran: recent, input: ["path": "a.txt"], metadata: [:])])
        try step("ses_read", [f.tool("call_r", "read", status: "completed", ran: recent, completed: recent),
                              f.tool("call_r2", "read", status: "running", ran: recent + 1, input: ["path": "/etc/hosts"])])
        // A patch held through a part row.
        try step("ses_patch", [])
        try f.part("msg_ses_patch_1", session: "ses_patch", ordinal: 0,
                   item: f.tool("call_p", "patch", status: "running", ran: recent + 2))
        // Started two seconds ago: the write itself, or its formatter.
        try step("ses_fresh", [f.tool("call_f", "edit", status: "running", ran: recent + 8)])
        // Shell commands and subagents run for minutes on their own.
        try step("ses_long", [f.tool("call_s", "shell", status: "running", ran: recent),
                              f.tool("call_a", "subagent", status: "running", ran: recent)])
        // Only the current step counts.
        try step("ses_older", [f.tool("call_o", "write", status: "running", ran: recent)])
        try step("ses_older", [f.tool("call_o2", "read", status: "completed", ran: recent, completed: recent)], seq: 2)
        // A time that is not a number is not a time.
        var odd = f.tool("call_t", "write", status: "running")
        odd["time"] = ["created": "soon", "ran": "soon"]
        try step("ses_text", [odd])
        let registration = try register(f)
        let snapshot = provider(f, registration: registration).scan(sources: [f.source])
        let statuses = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.sessionID, $0.status) })
        XCTAssertEqual(statuses, ["ses_write": .waiting, "ses_read": .waiting, "ses_patch": .waiting, "ses_fresh": .working,
                                  "ses_long": .working, "ses_older": .working, "ses_text": .working])
        let since = Dictionary(uniqueKeysWithValues: snapshot.sessions.map { ($0.sessionID, $0.details.stateSince) })
        XCTAssertEqual(since["ses_write"], f.date(recent))
        XCTAssertEqual(since["ses_read"], f.date(recent + 1))
        XCTAssertEqual(since["ses_patch"], f.date(recent + 2))
        XCTAssertEqual(since["ses_fresh"], f.date(recent))
        // The same write, read five seconds into its wait, has just started waiting.
        let early = provider(f, registration: registration).scan(sources: [f.source], now: f.date(recent + 4.5))
        XCTAssertEqual(early.sessions.first { $0.sessionID == "ses_write" }?.status, .working)
        let due = provider(f, registration: registration).scan(sources: [f.source], now: f.date(recent + 5))
        XCTAssertEqual(due.sessions.first { $0.sessionID == "ses_write" }?.status, .waiting)
    }

    func testDeadReusedAndStaleServicesShowNothing() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        try f.createV2()
        try f.session("ses_a", directory: f.project, created: 0, busy: recent)
        // A turn a dead process left mid-way two hours ago, before this service started.
        try f.session("ses_stale", directory: f.project, created: 0, busy: 0)
        let unregistered = OpenCodeLiveActivityProvider(processStartTimes: { _ in [4242: 1] }, otherServers: { [:] },
                                                        home: f.home.path)
        XCTAssertEqual(unregistered.scan(sources: [f.source]).sessions, [], "no registered service")
        let registration = try register(f)
        XCTAssertEqual(provider(f, registration: registration).scan(sources: [f.source]).sessions.map(\.sessionID), ["ses_a"])
        XCTAssertEqual(provider(f, registration: registration, alive: false).scan(sources: [f.source]).sessions, [],
                       "dead service")
        XCTAssertEqual(provider(f, registration: registration, offset: 600).scan(sources: [f.source]).sessions, [],
                       "PID reused by a later process")
        // A profile for another data folder: its service registers elsewhere.
        let other = AgentSource(id: "opencode-2", name: "Other", configDirectory: f.root.appendingPathComponent("data").path,
                                assistant: .opencode)
        XCTAssertEqual(provider(f, registration: registration).scan(sources: [other]).sessions, [])
    }

    func testRegistrationPIDMustBeANumber() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        try f.createV2()
        try f.session("ses_a", directory: f.project, created: 0, busy: recent)
        // `true` also reads as the number 1, which is launchd.
        let registration = try register(f, pid: true)
        let snapshot = provider(f, registration: registration, pid: 1).scan(sources: [f.source])
        XCTAssertEqual(snapshot.sessions, [])
        XCTAssertEqual(snapshot.notices, ["OpenCode: the OpenCode service registration could not be read; live status is unavailable."])
        XCTAssertEqual(OpenCodeLiveActivityProvider.registeredPID(Data("{\"pid\": 4242, \"password\": \"x\"}".utf8)), 4242)
        XCTAssertNil(OpenCodeLiveActivityProvider.registeredPID(Data("{\"pid\": 1}".utf8)))
        XCTAssertNil(OpenCodeLiveActivityProvider.registeredPID(Data("{\"pid\": 42.5}".utf8)))
        XCTAssertNil(OpenCodeLiveActivityProvider.registeredPID(Data("{\"pid\": \"4242\"}".utf8)))
    }

    func testATurnLeftByAServerShutdownIsNotShown() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        try f.createV2()
        // A private server shut down mid-turn and kept the execution for its next start.
        try f.session("ses_left", directory: f.project, created: 0, busy: recent)
        try event(f, session: "ses_left", seq: 1, "session.execution.started.1")
        try event(f, session: "ses_left", seq: 2, "session.execution.interrupted.1", reason: "shutdown")
        // The service resumed such a turn, which records a newer start.
        try f.session("ses_resumed", directory: f.project, created: 0, busy: recent)
        try event(f, session: "ses_resumed", seq: 1, "session.execution.interrupted.1", reason: "shutdown")
        try event(f, session: "ses_resumed", seq: 2, "session.execution.started.1")
        try event(f, session: "ses_resumed", seq: 3, "session.instructions.updated.2")
        // Only a shutdown keeps a turn executing for a later start.
        try f.session("ses_again", directory: f.project, created: 0, busy: recent)
        try event(f, session: "ses_again", seq: 1, "session.execution.interrupted.1", reason: "user")
        // Nothing logged: event persistence is off, as it is by default.
        try f.session("ses_plain", directory: f.project, created: 0, busy: recent)
        let registration = try register(f)
        let snapshot = provider(f, registration: registration).scan(sources: [f.source])
        XCTAssertEqual(Set(snapshot.sessions.map(\.sessionID)), ["ses_resumed", "ses_again", "ses_plain"])
        XCTAssertEqual(Set(snapshot.sessions.map(\.status)), [.working])
    }

    func testAnotherOpenCodeServerOnTheDatabaseKeepsItsPossibleTurnsFromWorking() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        try f.createV2()
        try f.session("ses_a", directory: f.project, created: 0, busy: recent)
        let registration = try register(f)
        let written = FileStat.of(registration.path)?.modified ?? Date()
        func started(_ offset: TimeInterval) -> UInt64 { UInt64((written.timeIntervalSince1970 + offset) * 1_000_000) }
        // `opencode acp` started a private server after this turn began, so it is not running it.
        let later = provider(f, registration: registration, otherServers: { [5151: started(0)] })
        XCTAssertEqual(later.scan(sources: [f.source]).sessions.map(\.status), [.working])

        // One running since before the turn began might be running it.
        var running: [Int32: UInt64]? = [5151: started(-30)]
        let live = provider(f, registration: registration, otherServers: { running })
        let unknown = live.scan(sources: [f.source]).sessions
        XCTAssertEqual(unknown.map(\.status), [.unknown])
        XCTAssertEqual(unknown.first?.pid, 4242)
        // That server is gone and the turn is still executing: it may be one its shutdown left behind.
        running = [:]
        XCTAssertEqual(live.scan(sources: [f.source]).sessions, [])
        // The session's next turn is the service's.
        try f.run("UPDATE session_v2 SET time_busy = ? WHERE id = 'ses_a'", [f.ms(recent + 1)])
        XCTAssertEqual(live.scan(sources: [f.source]).sessions.map(\.status), [.working])
        // When processes cannot be listed, no turn is verified as the service's.
        running = nil
        XCTAssertEqual(live.scan(sources: [f.source]).sessions.map(\.status), [.unknown])

        XCTAssertTrue(OpenCodeLiveActivityProvider.isOtherServer(["/opt/homebrew/bin/opencode", "serve", "--stdio", "--port", "0"]))
        XCTAssertTrue(OpenCodeLiveActivityProvider.isOtherServer(["opencode", "serve", "--port", "4096"]))
        XCTAssertFalse(OpenCodeLiveActivityProvider.isOtherServer(["/Applications/OpenCode.app/Contents/Resources/opencode-cli", "serve", "--service"]))
        XCTAssertFalse(OpenCodeLiveActivityProvider.isOtherServer(["opencode", "acp"]))
        XCTAssertFalse(OpenCodeLiveActivityProvider.isOtherServer(["opencode"]))
    }
}
