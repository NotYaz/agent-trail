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
    private func provider(_ f: OpenCodeFixture, registration: URL, pid: Int32 = 4242, offset: TimeInterval = -60,
                          alive: Bool = true) -> OpenCodeLiveActivityProvider {
        let written = FileStat.of(registration.path)?.modified ?? Date()
        let start = UInt64((written.timeIntervalSince1970 + offset) * 1_000_000)
        return OpenCodeLiveActivityProvider(processStartTimes: { pids in alive && pids.contains(pid) ? [pid: start] : [:] },
                                            home: f.home.path)
    }

    func testExecutingSessionsAreWorkingAndAnOpenQuestionNeedsInput() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        try f.createV2()
        // Executing, with an edit waiting for approval: approvals are not on disk.
        try f.session("ses_work", directory: f.project, created: 0, busy: recent)
        try f.message("msg_w", session: "ses_work", seq: 1, created: recent, data: f.assistant([
            f.tool("call_w", "edit", status: "running", input: ["path": "a.txt"])], created: recent))
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

    func testDeadReusedAndStaleServicesShowNothing() throws {
        let f = try OpenCodeFixture()
        defer { f.remove() }
        try f.createV2()
        try f.session("ses_a", directory: f.project, created: 0, busy: recent)
        // A turn a dead process left mid-way two hours ago, before this service started.
        try f.session("ses_stale", directory: f.project, created: 0, busy: 0)
        let unregistered = OpenCodeLiveActivityProvider(processStartTimes: { _ in [4242: 1] }, home: f.home.path)
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
}
