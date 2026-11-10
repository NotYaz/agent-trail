import Foundation
import SQLite3

/// A read-only connection to another app's SQLite database, for history
/// scans. It opens with SQLITE_OPEN_READONLY and `PRAGMA query_only`, never
/// `immutable` (which could read a half-written WAL database) and never a
/// copy. A busy database waits briefly, then the query fails and the adapter
/// reports a notice; the next scan tries again. Each query has a deadline and
/// each value a size cap, so an unexpected schema cannot stall a scan.
final class ReadOnlySQLite {
    enum Value: Equatable {
        case null
        case integer(Int64)
        case real(Double)
        case text(String)
        /// A BLOB, or a value larger than the column cap (`truncated` true).
        case blob(Data, truncated: Bool)

        var string: String? {
            switch self {
            case .text(let text): return text
            case .blob(let data, false): return String(data: data, encoding: .utf8)
            default: return nil
            }
        }

        var int: Int64? {
            switch self {
            case .integer(let value): return value
            case .real(let value) where value.isFinite: return Int64(value)
            case .text(let text): return Int64(text)
            default: return nil
            }
        }

        var double: Double? {
            switch self {
            case .integer(let value): return Double(value)
            case .real(let value): return value
            case .text(let text): return Double(text)
            default: return nil
            }
        }
    }

    /// `busy`: another connection holds a lock; `interrupted`: the query hit
    /// its deadline. Both mean "try again on the next scan", never "unreadable".
    enum Failure: Error { case open, busy, interrupted, query(String) }

    private var handle: OpaquePointer?

    /// Nil when the file cannot be opened read-only.
    init?(url: URL, busyTimeoutMilliseconds: Int32 = 200, maximumValueBytes: Int32 = 64 * 1_048_576) {
        guard FileStat.of(url.path)?.kind == .regular,
              sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            handle = nil
            return nil
        }
        sqlite3_busy_timeout(handle, busyTimeoutMilliseconds)
        sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, maximumValueBytes)
        sqlite3_limit(handle, SQLITE_LIMIT_SQL_LENGTH, 16_384)
        guard sqlite3_exec(handle, "PRAGMA query_only = ON", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            handle = nil
            return nil
        }
    }

    deinit { sqlite3_close(handle) }

    /// The table's column names, or an empty set when it does not exist.
    func columns(of table: String) -> Set<String> {
        guard table.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              let rows = try? rows("PRAGMA table_info(\(table))", deadline: 1) else { return [] }
        return Set(rows.compactMap { $0.count > 1 ? $0[1].string : nil })
    }

    func tableExists(_ table: String) -> Bool { !columns(of: table).isEmpty }

    /// Runs one query and returns every row. Values above `maximumColumnBytes`
    /// come back as truncated blobs, so a parser never sees a partial JSON text.
    func rows(_ sql: String, bindings: [Value] = [], maximumColumnBytes: Int = 16 * 1_048_576,
              deadline seconds: TimeInterval = 10) throws -> [[Value]] {
        var rows: [[Value]] = []
        try each(sql, bindings: bindings, maximumColumnBytes: maximumColumnBytes, deadline: seconds) { row in
            rows.append(row)
            return true
        }
        return rows
    }

    /// Streams rows to `body`; return false from it to stop early.
    func each(_ sql: String, bindings: [Value] = [], maximumColumnBytes: Int = 16 * 1_048_576,
              deadline seconds: TimeInterval = 10, _ body: ([Value]) throws -> Bool) throws {
        var deadline = Date().timeIntervalSinceReferenceDate + seconds
        try withUnsafeMutablePointer(to: &deadline) { pointer in
            sqlite3_progress_handler(handle, 1000, { context in
                guard let context else { return 1 }
                return Date().timeIntervalSinceReferenceDate > context.assumingMemoryBound(to: Double.self).pointee ? 1 : 0
            }, pointer)
            defer { sqlite3_progress_handler(handle, 0, nil, nil) }
            var statement: OpaquePointer?
            let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
            guard prepared == SQLITE_OK, let statement else {
                if prepared == SQLITE_BUSY || prepared == SQLITE_LOCKED { throw Failure.busy }
                if prepared == SQLITE_INTERRUPT { throw Failure.interrupted }
                throw Failure.query(message)
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (offset, value) in bindings.enumerated() {
                let index = Int32(offset + 1)
                switch value {
                case .null: sqlite3_bind_null(statement, index)
                case .integer(let number): sqlite3_bind_int64(statement, index, number)
                case .real(let number): sqlite3_bind_double(statement, index, number)
                case .text(let text): sqlite3_bind_text(statement, index, text, -1, transient)
                case .blob(let data, _):
                    _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(data.count), transient) }
                }
            }
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return }
                if step == SQLITE_BUSY || step == SQLITE_LOCKED { throw Failure.busy }
                if step == SQLITE_INTERRUPT { throw Failure.interrupted }
                guard step == SQLITE_ROW else { throw Failure.query(message) }
                let row = (0..<sqlite3_column_count(statement)).map { column(statement, $0, cap: maximumColumnBytes) }
                guard try body(row) else { return }
            }
        }
    }

    private var message: String { handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "unknown" }

    private func column(_ statement: OpaquePointer, _ index: Int32, cap: Int) -> Value {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL: return .null
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count <= cap else { return .blob(Data(), truncated: true) }
            guard let text = sqlite3_column_text(statement, index) else { return .null }
            return .text(String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self))
        default:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count <= cap else { return .blob(Data(), truncated: true) }
            guard let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data(), truncated: false) }
            return .blob(Data(bytes: bytes, count: count), truncated: false)
        }
    }
}
