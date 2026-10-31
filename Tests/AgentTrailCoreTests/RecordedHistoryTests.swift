import Foundation
import XCTest
@testable import AgentTrailCore

final class RecordedHistoryTests: XCTestCase {
    func testCompleteRecordJustOverLimitIsSkippedBeforeParsingAndNextRecordSurvives() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try writeRecord(bytes: JSONLTail.maximumLineBytes + 1, to: file)
        try append(Data("{\"ok\":true}\n".utf8), to: file)
        var state = TailState()
        var parsed: [Data] = []

        try JSONLTail.read(url: file, state: &state, reset: {}) { parsed.append($0); return true }

        XCTAssertEqual(parsed, [Data("{\"ok\":true}".utf8)])
        XCTAssertEqual(state.oversizedLines, 1)
        XCTAssertEqual(state.malformedLines, 0)
        XCTAssertEqual(state.offset, UInt64(JSONLTail.maximumLineBytes + 2 + 12))
    }

    func testCompleteRecordAtLimitStillParses() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try writeRecord(bytes: JSONLTail.maximumLineBytes, to: file)
        var state = TailState()
        var parsedSizes: [Int] = []

        try JSONLTail.read(url: file, state: &state, reset: {}) { parsedSizes.append($0.count); return true }

        XCTAssertEqual(parsedSizes, [JSONLTail.maximumLineBytes])
        XCTAssertEqual(state.oversizedLines, 0)
        XCTAssertEqual(state.offset, UInt64(JSONLTail.maximumLineBytes + 1))
    }

    func testOversizedPartialRecordRemainsSkippedAfterASecondPoll() throws {
        let file = try temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try writeRecord(bytes: JSONLTail.maximumLineBytes + 1, to: file, newline: false)
        var state = TailState()
        var parsed: [Data] = []
        try JSONLTail.read(url: file, state: &state, reset: {}) { parsed.append($0); return true }
        XCTAssertTrue(parsed.isEmpty)
        XCTAssertTrue(state.droppingOversizedLine)

        try append(Data("tail\n{\"ok\":true}\n".utf8), to: file)
        try JSONLTail.read(url: file, state: &state, reset: {}) { parsed.append($0); return true }

        XCTAssertEqual(parsed, [Data("{\"ok\":true}".utf8)])
        XCTAssertEqual(state.oversizedLines, 1)
        XCTAssertFalse(state.droppingOversizedLine)
    }

    private func temporaryFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentTrailRecordedHistoryTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("session.jsonl")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        return file
    }

    private func writeRecord(bytes: Int, to file: URL, newline: Bool = true) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let prefix = Data("{\"value\":\"".utf8), suffix = Data("\"}".utf8)
        try handle.write(contentsOf: prefix)
        var remaining = bytes - prefix.count - suffix.count
        let chunk = Data(repeating: 0x61, count: 1_048_576)
        while remaining > 0 {
            let count = min(remaining, chunk.count)
            try handle.write(contentsOf: chunk.prefix(count))
            remaining -= count
        }
        try handle.write(contentsOf: suffix)
        if newline { try handle.write(contentsOf: Data([0x0A])) }
    }

    private func append(_ data: Data, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
