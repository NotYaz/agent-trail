import Foundation
import XCTest
@testable import AgentTrailCore

final class CopilotLiveActivityProviderTests: XCTestCase {
    private let id = "8b2f9c1e-3a4d-4e5f-9a6b-7c8d9e0f1a2b"

    private func setUp(_ f: ChatFixture, pid: Int32 = 4242) throws -> URL {
        let folder = try f.cli(id, events: [], yaml: "id: \(id)\ncwd: \(f.project.path)\n")
        let lock = folder.appendingPathComponent("inuse.\(pid).lock")
        try "\(pid)".write(to: lock, atomically: false, encoding: .utf8)
        return lock
    }

    private func lockCreated(_ lock: URL) -> Date { FileStat.of(lock.path)!.created }

    /// A process that started `offset` seconds after the lock was created.
    private func provider(_ lock: URL, pid: Int32 = 4242, offset: TimeInterval = -60, alive: Bool = true) -> CopilotLiveActivityProvider {
        let start = UInt64((lockCreated(lock).timeIntervalSince1970 + offset) * 1_000_000)
        return CopilotLiveActivityProvider(processStartTimes: { pids in alive && pids.contains(pid) ? [pid: start] : [:] },
                                           terminalHints: { _ in nil })
    }

    private func events(_ f: ChatFixture, _ lock: URL, _ items: [(String, [String: Any])], from second: TimeInterval = 1) throws {
        let created = lockCreated(lock)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let lines = items.enumerated().map { index, item -> [String: Any] in
            ["type": item.0, "data": item.1,
             "timestamp": formatter.string(from: created.addingTimeInterval(second + Double(index)))]
        }
        try f.cli(id, events: lines, append: true)
    }

    private func status(_ provider: CopilotLiveActivityProvider, _ f: ChatFixture, now: Date = Date()) -> LiveStatus? {
        provider.scan(sources: [f.source], now: now.addingTimeInterval(600)).sessions.first?.status
    }

    func testTurnsToolsAndPermissionsDriveTheState() throws {
        let f = try ChatFixture()
        defer { f.remove() }
        let lock = try setUp(f)
        let provider = provider(lock)
        XCTAssertEqual(status(provider, f), .idle, "a session held open with no turn yet")
        try events(f, lock, [("assistant.turn_start", ["turnId": "t1"])])
        XCTAssertEqual(status(provider, f), .working)
        try events(f, lock, [("tool.execution_start", ["toolCallId": "c1", "toolName": "edit"]),
                             ("permission.requested", ["requestId": "p1", "permissionRequest": ["kind": "write"]])], from: 2)
        XCTAssertEqual(status(provider, f), .waiting)
        try events(f, lock, [("permission.completed", ["requestId": "p1", "result": ["kind": "approved"]]),
                             ("tool.execution_complete", ["toolCallId": "c1", "success": true])], from: 4)
        XCTAssertEqual(status(provider, f), .working)
        try events(f, lock, [("tool.execution_start", ["toolCallId": "c2", "toolName": "ask_user"])], from: 6)
        XCTAssertEqual(status(provider, f), .waiting)
        try events(f, lock, [("tool.execution_complete", ["toolCallId": "c2", "success": true]),
                             ("assistant.turn_end", ["turnId": "t1"])], from: 7)
        XCTAssertEqual(status(provider, f), .idle)
        try events(f, lock, [("session.shutdown", ["shutdownType": "routine"])], from: 9)
        XCTAssertNil(status(provider, f))
    }

    func testStaleLocksReusedPIDsAndOlderEventsAreIgnored() throws {
        let f = try ChatFixture()
        defer { f.remove() }
        let lock = try setUp(f)
        // Events written before this process opened the session describe an earlier run.
        try events(f, lock, [("assistant.turn_start", ["turnId": "old"]),
                             ("permission.requested", ["requestId": "old"])], from: -3_600)
        XCTAssertEqual(status(provider(lock), f), .idle)
        XCTAssertNil(status(provider(lock, alive: false), f), "dead holder")
        XCTAssertNil(status(provider(lock, offset: 600), f), "PID reused by a later process")
        let session = try XCTUnwrap(provider(lock).scan(sources: [f.source]).sessions.first)
        XCTAssertEqual(session.sessionID, id)
        XCTAssertEqual(session.projectPath, canonicalPath(f.project.path))
    }

    func testRewrittenJournalStartsOver() throws {
        let f = try ChatFixture()
        defer { f.remove() }
        let lock = try setUp(f)
        let provider = provider(lock)
        try events(f, lock, [("assistant.turn_start", ["turnId": "t1"]), ("permission.requested", ["requestId": "p1"])])
        XCTAssertEqual(status(provider, f), .waiting)
        // /rewind rewrites the journal to end before the turn.
        try f.cli(id, events: [])
        try events(f, lock, [("assistant.turn_start", ["turnId": "t2"]), ("assistant.turn_end", ["turnId": "t2"])], from: 20)
        XCTAssertEqual(status(provider, f), .idle)
    }

    func testLockNames() {
        XCTAssertEqual(CopilotLiveActivityProvider.lockPID("inuse.123.lock"), 123)
        XCTAssertNil(CopilotLiveActivityProvider.lockPID("inuse..lock"))
        XCTAssertNil(CopilotLiveActivityProvider.lockPID("inuse.-1.lock"))
        XCTAssertNil(CopilotLiveActivityProvider.lockPID("inuse.12a.lock"))
        XCTAssertNil(CopilotLiveActivityProvider.lockPID(".workspace-fork.lock"))
    }
}
