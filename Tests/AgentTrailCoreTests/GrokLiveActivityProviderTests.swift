import Darwin
import Foundation
import XCTest
@testable import AgentTrailCore

final class GrokLiveActivityProviderTests: XCTestCase {
    func testExplicitTurnPermissionAndCompletionTransitionsWhileProcessRemainsAlive() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.register()
        let provider = f.provider()
        try f.events([f.event("turn_started", seconds: 1)])
        XCTAssertEqual(f.status(provider), .working)
        try f.append([f.event("permission_requested", seconds: 2, extra: ["tool_name": "write"])])
        XCTAssertEqual(f.status(provider), .waiting)
        try f.append([f.event("permission_resolved", seconds: 3, extra: ["tool_name": "write", "decision": "allow"])])
        XCTAssertEqual(f.status(provider), .working)
        try f.append([f.event("turn_ended", seconds: 4, extra: ["outcome": "completed"])])
        XCTAssertEqual(f.status(provider), .idle)
        // Reports are transitions; idle and a long-running turn do not expire.
        XCTAssertEqual(provider.scan(sources: [f.source], now: f.now.addingTimeInterval(86_400)).sessions.first?.status, .idle)
        try f.append([f.event("turn_started", seconds: 5)])
        XCTAssertEqual(provider.scan(sources: [f.source], now: f.now.addingTimeInterval(86_400)).sessions.first?.status, .working)
    }

    func testCancellationAndFailureEndTheTurnRatherThanClaimingNeedsInput() throws {
        for outcome in ["cancelled", "failed"] {
            let f = try Fixture()
            defer { f.remove() }
            try f.register()
            try f.events([f.event("turn_started", seconds: 1),
                          f.event("permission_requested", seconds: 2),
                          f.event("turn_ended", seconds: 3, extra: ["outcome": outcome])])
            XCTAssertEqual(f.status(f.provider()), .idle)
        }
    }

    func testPermissionResolutionMatchesToolAndRequestIDAndCannotResurrectEndedTurn() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.register()
        let provider = f.provider()
        try f.events([f.event("turn_started", seconds: 1),
                      f.event("permission_requested", seconds: 2, extra: ["tool_name": "write", "tool_call_id": "call-1"])])
        XCTAssertEqual(f.status(provider), .waiting)
        try f.append([f.event("permission_resolved", seconds: 3, extra: ["tool_name": "read_file"])])
        XCTAssertEqual(f.status(provider), .waiting)
        try f.append([f.event("permission_resolved", seconds: 4, extra: ["tool_name": "write", "tool_call_id": "call-2"])])
        XCTAssertEqual(f.status(provider), .waiting)
        try f.append([f.event("permission_resolved", seconds: 4, extra: ["tool_name": "read_file", "tool_call_id": "call-1"])])
        XCTAssertEqual(f.status(provider), .waiting)
        try f.append([f.event("permission_resolved", seconds: 5, extra: ["tool_name": "write", "tool_call_id": "call-1"])])
        XCTAssertEqual(f.status(provider), .working)
        try f.append([f.event("turn_ended", seconds: 6)])
        try f.append([f.event("permission_resolved", seconds: 7, extra: ["tool_name": "write"])])
        XCTAssertEqual(f.status(provider), .idle)
        try f.append([f.event("phase_changed", seconds: 8, extra: ["phase": "permission_prompt"])])
        XCTAssertEqual(f.status(provider), .waiting)
        try f.append([f.event("permission_resolved", seconds: 9, extra: ["tool_name": "write"])])
        XCTAssertEqual(f.status(provider), .working)
    }

    func testExplicitPhaseIsEnoughInBoundedTailButWaitingForModelIsWorking() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.register()
        let provider = f.provider()
        for (index, pair) in [("waiting_for_model", LiveStatus.working), ("streaming_reasoning", .working),
                              ("streaming_text", .working), ("tool_execution", .working),
                              ("permission_prompt", .waiting), ("future_phase", .unknown)].enumerated() {
            try f.append([f.event("phase_changed", seconds: index + 1, extra: ["phase": pair.0])])
            XCTAssertEqual(f.status(provider), pair.1)
        }
    }

    func testDeadReusedAndUnverifiablePIDsAreOmittedEvenWithFreshEvents() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.register()
        try f.events([f.event("turn_started", seconds: 1)])
        XCTAssertTrue(GrokLiveActivityProvider(processStartTimes: { _ in [:] })
            .scan(sources: [f.source], now: f.now).sessions.isEmpty)
        XCTAssertTrue(GrokLiveActivityProvider(processStartTimes: { _ in [101: f.birth + 1] })
            .scan(sources: [f.source], now: f.now).sessions.isEmpty)
        var calls = 0
        let exiting = GrokLiveActivityProvider(processStartTimes: { _ in
            calls += 1
            return calls == 1 ? [101: f.birth] : [:]
        })
        XCTAssertTrue(exiting.scan(sources: [f.source], now: f.now).sessions.isEmpty)
    }

    func testOpeningAndOldHistoryDoNotEstablishAStateForResumedRuntime() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.register()
        XCTAssertEqual(f.status(f.provider()), .unknown)
        try f.events([f.event("turn_started", seconds: -50), f.event("turn_ended", seconds: -10)])
        XCTAssertEqual(f.status(f.provider()), .unknown)
        try f.append([f.event("turn_started", seconds: 1)])
        XCTAssertEqual(f.status(f.provider()), .working)
    }

    func testSummaryIDWorkspaceAndHomeMustMatchProfileRegistry() throws {
        for changed in ["id", "cwd", "home"] {
            let f = try Fixture()
            defer { f.remove() }
            try f.register()
            var summary: [String: Any] = ["info": ["id": changed == "id" ? "foreign" : f.sessionID,
                "cwd": changed == "cwd" ? "/elsewhere" : f.project.path]]
            if changed == "home" { summary["grok_home"] = "/other-profile" }
            try f.json(summary, at: f.directory.appendingPathComponent("summary.json"))
            try f.events([f.event("turn_started", seconds: 1)])
            XCTAssertTrue(f.provider().scan(sources: [f.source], now: f.now).sessions.isEmpty)
        }
    }

    func testForeignAssistantAndSymlinkOutsideTheProfileAreOmitted() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.register()
        try f.events([f.event("turn_started", seconds: 1)])
        var source = f.source
        source.assistant = .codex
        XCTAssertTrue(f.provider().scan(sources: [source], now: f.now).sessions.isEmpty)
        let moved = f.root.appendingPathComponent("foreign-session")
        try FileManager.default.moveItem(at: f.directory, to: moved)
        try FileManager.default.createSymbolicLink(at: f.directory, withDestinationURL: moved)
        XCTAssertTrue(f.provider().scan(sources: [f.source], now: f.now).sessions.isEmpty)
    }

    func testUnfinishedMalformedOversizedAndFutureRecordsCannotRetainWorkingState() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.register()
        let provider = f.provider()
        try f.events([f.event("turn_started", seconds: 1)])
        XCTAssertEqual(f.status(provider), .working)
        let ended = try JSONSerialization.data(withJSONObject: f.event("turn_ended", seconds: 2))
        try f.appendBytes(ended.prefix(ended.count / 2))
        XCTAssertEqual(f.status(provider), .unknown)
        try f.appendBytes(ended.suffix(ended.count - ended.count / 2) + Data([10]))
        XCTAssertEqual(f.status(provider), .idle)
        try f.appendBytes(Data("{bad json}\n".utf8))
        XCTAssertEqual(f.status(provider), .unknown)
        try f.append([f.event("turn_started", seconds: 3)])
        XCTAssertEqual(f.status(provider), .working)
        try f.appendBytes(Data(repeating: 120, count: 70_000) + Data([10]))
        XCTAssertEqual(f.status(provider), .unknown)
        try f.append([f.event("turn_started", seconds: 4)])
        XCTAssertEqual(f.status(provider), .working)
        try f.append([f.event("turn_ended", seconds: 500)])
        XCTAssertEqual(f.status(provider), .unknown)
        try f.append([f.event("turn_ended", seconds: 5)])
        XCTAssertEqual(f.status(provider), .idle)
    }

    func testForeignSessionIDsAndCopiedEventBlobsCannotChangeTheRuntimeState() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.register()
        let provider = f.provider()
        try f.events([f.event("turn_ended", seconds: 1)])
        for type in ["turn_started", "turn_ended", "permission_requested", "permission_resolved", "phase_changed"] {
            try f.append([f.event(type, seconds: 2, extra: ["session_id": "foreign", "phase": "permission_prompt"])])
            XCTAssertEqual(f.status(provider), .idle)
        }
        try f.append([["ts": f.stamp(3), "type": "user_message", "message": f.event("turn_started", seconds: 3)],
                      ["ts": f.stamp(4), "type": "tool_completed", "output": "{\"type\":\"turn_started\"}"]])
        XCTAssertEqual(f.status(provider), .idle)
    }

    func testIndividualEventAndSummarySymlinksCannotReadAnotherProfile() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.register()
        try f.events([f.event("turn_started", seconds: 1)])
        let foreign = f.root.appendingPathComponent("foreign-events.jsonl")
        try FileManager.default.moveItem(at: f.eventsURL, to: foreign)
        try FileManager.default.createSymbolicLink(at: f.eventsURL, withDestinationURL: foreign)
        XCTAssertEqual(f.status(f.provider()), .unknown)
        let summary = f.directory.appendingPathComponent("summary.json")
        let foreignSummary = f.root.appendingPathComponent("foreign-summary.json")
        try FileManager.default.moveItem(at: summary, to: foreignSummary)
        try FileManager.default.createSymbolicLink(at: summary, withDestinationURL: foreignSummary)
        XCTAssertTrue(f.provider().scan(sources: [f.source], now: f.now).sessions.isEmpty)
    }

    func testReplacementTruncationAndRegistryRemovalDiscardCachedState() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.register()
        let provider = f.provider()
        try f.events([f.event("turn_started", seconds: 1)])
        XCTAssertEqual(f.status(provider), .working)
        try Data().write(to: f.eventsURL, options: .atomic)
        XCTAssertEqual(f.status(provider), .unknown)
        try f.events([f.event("turn_ended", seconds: 2)])
        XCTAssertEqual(f.status(provider), .idle)
        try f.json([], at: f.home.appendingPathComponent("active_sessions.json"))
        XCTAssertTrue(provider.scan(sources: [f.source], now: f.now).sessions.isEmpty)
        try f.register(openedSeconds: 10)
        XCTAssertEqual(f.status(provider), .unknown)
    }

    func testBoundedWindowFindsLatestPhaseWithoutLoadingLargePromptRecords() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.register()
        try f.events([f.event("turn_started", seconds: 1)])
        try f.appendBytes(Data(repeating: 120, count: 2_100_000) + Data([10]))
        try f.append([f.event("phase_changed", seconds: 2, extra: ["phase": "permission_prompt"])])
        let result = f.provider().scan(sources: [f.source], now: f.now)
        XCTAssertEqual(result.sessions.first?.status, .waiting)
        XCTAssertTrue(result.notices.isEmpty)
    }

    func testConflictingDuplicateRegistrationsAreOmittedAndExactCopiesDeduplicate() throws {
        let f = try Fixture()
        defer { f.remove() }
        try f.register()
        try f.events([f.event("turn_started", seconds: 1)])
        let record = f.record()
        try f.json([record, record], at: f.home.appendingPathComponent("active_sessions.json"))
        XCTAssertEqual(f.provider().scan(sources: [f.source], now: f.now).sessions.count, 1)
        var conflict = record
        conflict["pid_start"] = f.birth + 1
        try f.json([record, conflict], at: f.home.appendingPathComponent("active_sessions.json"))
        let result = f.provider().scan(sources: [f.source], now: f.now)
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertTrue(result.notices.contains { $0.contains("conflicting") })
    }

    private final class Fixture {
        let root: URL
        let home: URL
        let project: URL
        let directory: URL
        let sessionID = "01a18e8e-4feb-7fb1-9580-73d7fce36f23"
        let opened = Date(timeIntervalSince1970: 1_793_391_400)
        let birth: UInt64 = 1_793_391_394_407_292
        var now: Date { opened.addingTimeInterval(100) }
        var source: AgentSource { AgentSource(id: "grok", name: "Grok", configDirectory: home.path, assistant: .grok) }
        var eventsURL: URL { directory.appendingPathComponent("events.jsonl") }

        init() throws {
            root = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory
                .appendingPathComponent("agent-trail-grok-live-" + UUID().uuidString).path), isDirectory: true)
            home = root.appendingPathComponent("grok", isDirectory: true)
            project = root.appendingPathComponent("project", isDirectory: true)
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            directory = home.appendingPathComponent("sessions", isDirectory: true)
                .appendingPathComponent(project.path.addingPercentEncoding(withAllowedCharacters: allowed)!, isDirectory: true)
                .appendingPathComponent(sessionID, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try json(["info": ["id": sessionID, "cwd": project.path], "grok_home": home.path],
                at: directory.appendingPathComponent("summary.json"))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
        func provider() -> GrokLiveActivityProvider { GrokLiveActivityProvider(processStartTimes: { _ in [101: self.birth] }) }
        func status(_ provider: GrokLiveActivityProvider) -> LiveStatus? { provider.scan(sources: [source], now: now).sessions.first?.status }
        func stamp(_ seconds: Int) -> String { ISO8601DateFormatter().string(from: opened.addingTimeInterval(Double(seconds))) }
        func record(openedSeconds: Int = 0) -> [String: Any] {
            ["session_id": sessionID, "pid": 101, "pid_start": birth, "cwd": project.path, "opened_at": stamp(openedSeconds)]
        }
        func register(openedSeconds: Int = 0) throws { try json([record(openedSeconds: openedSeconds)], at: home.appendingPathComponent("active_sessions.json")) }
        func json(_ object: Any, at url: URL) throws { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic) }
        func event(_ type: String, seconds: Int, extra: [String: Any] = [:]) -> [String: Any] {
            var result: [String: Any] = ["type": type, "ts": stamp(seconds)]
            if type == "turn_started" { result["session_id"] = sessionID }
            result.merge(extra, uniquingKeysWith: { _, new in new })
            return result
        }
        func events(_ records: [[String: Any]]) throws {
            try Data().write(to: eventsURL, options: .atomic)
            try append(records)
        }
        func append(_ records: [[String: Any]]) throws {
            for record in records { try appendBytes(JSONSerialization.data(withJSONObject: record) + Data([10])) }
        }
        func appendBytes(_ bytes: Data) throws {
            if !FileManager.default.fileExists(atPath: eventsURL.path) { try Data().write(to: eventsURL) }
            let handle = try FileHandle(forWritingTo: eventsURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: bytes)
        }
    }
}
