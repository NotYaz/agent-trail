import Foundation
import XCTest
@testable import AgentTrailCore

final class QwenLiveActivityProviderTests: XCTestCase {
    private let id = "c0ffee00-1111-4222-8333-444455556666"
    private let registered = Date(timeIntervalSince1970: 1_793_000_000)

    @discardableResult
    private func register(_ f: QwenFixture, pid: Int32 = 4242, name: String? = nil, fields: [String: Any] = [:]) throws -> URL {
        var record: [String: Any] = [
            "schemaVersion": 1, "pid": Int(pid), "procStart": NSNull(), "pidNs": NSNull(), "sessionId": id,
            "cwd": f.project.path, "name": "project-3f", "startedAt": 1_793_000_000_000, "qwenVersion": "0.26.9",
            "kind": "tui", "ipcPath": "/tmp/qwen-socks-0123456789abcdef/4242.sock", "ipcToken": "PRIVATE_TOKEN_MARKER"
        ]
        for (key, value) in fields { record[key] = value }
        let folder = f.home.appendingPathComponent("sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name ?? "\(pid).json")
        try JSONSerialization.data(withJSONObject: record).write(to: url)
        return url
    }

    /// A process alive since `offset` seconds after the record's `startedAt`.
    private func provider(pid: Int32 = 4242, offset: TimeInterval = -60, alive: Bool = true) -> QwenLiveActivityProvider {
        let start = UInt64((registered.timeIntervalSince1970 + offset) * 1_000_000)
        return QwenLiveActivityProvider(processStartTimes: { pids in alive && pids.contains(pid) ? [pid: start] : [:] },
                                        terminalHints: { _ in nil })
    }

    func testVerifiedRegisteredSessionIsPresentWithUnknownStatus() throws {
        let f = try QwenFixture()
        defer { f.remove() }
        try register(f)
        let snapshot = provider().scan(sources: [f.source], now: registered.addingTimeInterval(600))
        let session = try XCTUnwrap(snapshot.sessions.first)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(session.status, .unknown)
        XCTAssertEqual(session.sessionID, id)
        XCTAssertEqual(session.pid, 4242)
        XCTAssertEqual(session.projectPath, ProjectLocationRegistry.lexicalPath(f.project.path))
        XCTAssertEqual(session.updatedAt, registered)
        XCTAssertEqual(snapshot.notices, [])
        XCTAssertFalse(String(describing: snapshot).contains("PRIVATE_TOKEN_MARKER"))
    }

    func testDeadAndReusedProcessesAreOmitted() throws {
        let f = try QwenFixture()
        defer { f.remove() }
        try register(f)
        let now = registered.addingTimeInterval(600)
        XCTAssertEqual(provider(alive: false).scan(sources: [f.source], now: now).sessions.count, 0, "crashed: record left behind")
        XCTAssertEqual(provider(offset: 300).scan(sources: [f.source], now: now).sessions.count, 0, "PID reused by a later process")
        XCTAssertEqual(provider(offset: 1).scan(sources: [f.source], now: now).sessions.count, 1, "within clock rounding")
        XCTAssertEqual(provider().scan(sources: [f.source], now: registered.addingTimeInterval(-60)).sessions.count, 0,
                       "a record from the future")
    }

    func testRecordsMustAgreeWithTheirNamesAndKinds() throws {
        let f = try QwenFixture()
        defer { f.remove() }
        // One process hosting a second session, under a minted suffix.
        try register(f, name: "4242-0a1b2c3d.json", fields: ["sessionId": "d0d1d2d3-0000-4000-8000-000000000005", "kind": "headless"])
        try register(f, name: "4243.json")
        try register(f, name: "04242.json")
        try register(f, pid: 4244, fields: ["kind": "external"])
        try register(f, pid: 4245, fields: ["schemaVersion": 2])
        try register(f, pid: 4246, fields: ["startedAt": true])
        let snapshot = QwenLiveActivityProvider(processStartTimes: { pids in
            Dictionary(uniqueKeysWithValues: pids.map { ($0, UInt64(1_792_999_000) * 1_000_000) })
        }, terminalHints: { _ in nil }).scan(sources: [f.source], now: registered.addingTimeInterval(600))
        XCTAssertEqual(snapshot.sessions.map(\.sessionID), ["d0d1d2d3-0000-4000-8000-000000000005"])
        XCTAssertEqual(snapshot.notices.count, 1, "\(snapshot.notices)")
    }

    func testRecordsFromAnotherPIDNamespaceOrMachineAreSkipped() throws {
        let f = try QwenFixture()
        defer { f.remove() }
        // A Linux container or VM sharing this Qwen home records its PID namespace and start token.
        try register(f, pid: 4242, fields: ["pidNs": 4_026_531_836, "procStart": "6c1e0b8a-0d5f-4a8e-9b7c-1d2e3f405162:123456"])
        try register(f, pid: 4243, fields: ["pidNs": 4_026_532_001])
        try register(f, pid: 4244, fields: ["procStart": "abc:123"])
        // A Mac writer records both as null.
        try register(f, pid: 4245)
        let snapshot = QwenLiveActivityProvider(processStartTimes: { pids in
            Dictionary(uniqueKeysWithValues: pids.map { ($0, UInt64(1_792_999_000) * 1_000_000) })
        }, terminalHints: { _ in nil }).scan(sources: [f.source], now: registered.addingTimeInterval(600))
        XCTAssertEqual(snapshot.sessions.map(\.pid), [4245])
        XCTAssertEqual(snapshot.notices, [])
    }

    func testRecordNames() {
        XCTAssertEqual(QwenLiveActivityProvider.recordPID("4242.json"), 4242)
        XCTAssertEqual(QwenLiveActivityProvider.recordPID("4242-0a1b2c3d.json"), 4242)
        XCTAssertNil(QwenLiveActivityProvider.recordPID("04242.json"))
        XCTAssertNil(QwenLiveActivityProvider.recordPID("4242-0A1B2C3D.json"))
        XCTAssertNil(QwenLiveActivityProvider.recordPID("4242-0a1b2c.json"))
        XCTAssertNil(QwenLiveActivityProvider.recordPID("-1.json"))
        XCTAssertNil(QwenLiveActivityProvider.recordPID("4242.json.tmp"))
        XCTAssertNil(QwenLiveActivityProvider.recordPID("4294967296.json"))
        XCTAssertNil(QwenLiveActivityProvider.recordPID(".json"))
    }
}
