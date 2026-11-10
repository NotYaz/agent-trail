import Foundation
import SQLite3
import XCTest
@testable import AgentTrailCore

final class ReadOnlySQLiteTests: XCTestCase {
    func testReadsRowsAndNeverWrites() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("agent-trail-sqlite-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: url) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "PRAGMA journal_mode=WAL; CREATE TABLE t(id TEXT, n INTEGER, data TEXT); INSERT INTO t VALUES ('a', 1, '{\"x\":1}'), ('b', NULL, 'long-value');", nil, nil, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        let reader = try XCTUnwrap(ReadOnlySQLite(url: url))
        XCTAssertEqual(reader.columns(of: "t"), ["id", "n", "data"])
        XCTAssertFalse(reader.tableExists("missing"))
        let rows = try reader.rows("SELECT id, n, data FROM t WHERE id >= ? ORDER BY id", bindings: [.text("a")], maximumColumnBytes: 8)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0][0].string, "a")
        XCTAssertEqual(rows[0][1].int, 1)
        XCTAssertEqual(rows[0][2].string, "{\"x\":1}")
        XCTAssertEqual(rows[1][1], .null)
        XCTAssertEqual(rows[1][2], .blob(Data(), truncated: true), "values over the cap are never half-read")
        XCTAssertThrowsError(try reader.rows("INSERT INTO t VALUES ('c', 2, 'x')"))
        XCTAssertThrowsError(try reader.rows("SELECT nope FROM t"))
        XCTAssertNil(ReadOnlySQLite(url: url.appendingPathExtension("missing")))
    }
}
