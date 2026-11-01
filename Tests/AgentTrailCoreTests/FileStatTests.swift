import Foundation
import XCTest
@testable import AgentTrailCore

final class FileStatTests: XCTestCase {
    /// Cache identities and saved folder identities were built from Foundation's
    /// attributes; the lstat reading must reproduce them exactly.
    func testMatchesFoundationAttributesExactly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("history.jsonl")
        try Data("{}\n".utf8).write(to: file)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)

        for url in [root, file, link] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let metadata = try XCTUnwrap(FileStat.of(url.path))
            let foundationIdentity = "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? ""):\((attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
            XCTAssertEqual(metadata.identity, foundationIdentity)
            XCTAssertEqual(metadata.created, attributes[.creationDate] as? Date)
            XCTAssertEqual(metadata.modified, attributes[.modificationDate] as? Date)
            XCTAssertEqual(metadata.size, (attributes[.size] as? NSNumber)?.uint64Value)
        }
        XCTAssertEqual(FileStat.of(root.path)?.kind, .directory)
        XCTAssertEqual(FileStat.of(file.path)?.kind, .regular)
        XCTAssertEqual(FileStat.of(link.path)?.kind, .symbolicLink)
        XCTAssertNil(FileStat.of(root.appendingPathComponent("missing").path))
        XCTAssertThrowsError(try FileStat.required(root.appendingPathComponent("missing")))
    }
}
