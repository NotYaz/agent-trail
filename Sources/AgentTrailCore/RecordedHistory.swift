import Foundation

/// Dates from assistant logs. Fractional seconds longer than three digits are
/// trimmed so Apple's ISO-8601 parser accepts them. Not a file-mtime fallback.
enum RecordedDate {
    private static let lock = NSLock()
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        if let date = fractional.date(from: value) ?? plain.date(from: value) { return date }
        let trimmed = trimmingFraction(value)
        guard trimmed != value else { return nil }
        return fractional.date(from: trimmed) ?? plain.date(from: trimmed)
    }

    static func milliseconds(_ value: Any?) -> Date? {
        guard let number = finiteNumber(value) else { return nil }
        return Date(timeIntervalSince1970: number / 1000)
    }

    /// An ISO-8601 string, Unix seconds, or Unix milliseconds. A number of at
    /// least 13 digits is milliseconds. Smaller positive numbers are seconds.
    static func any(_ value: Any?) -> Date? {
        if let text = value as? String { return parse(text) }
        guard let number = finiteNumber(value) else { return nil }
        if number >= 1_000_000_000_000 {
            return Date(timeIntervalSince1970: number / 1000)
        }
        return Date(timeIntervalSince1970: number)
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        if value is Bool { return nil }
        let number: Double?
        switch value {
        case let int as Int: number = Double(int)
        case let double as Double: number = double
        case let numberValue as NSNumber: number = numberValue.doubleValue
        default: number = nil
        }
        guard let number, number.isFinite, number > 0 else { return nil }
        return number
    }

    /// Keep the first three fractional digits and the timezone that follows them.
    static func trimmingFraction(_ value: String) -> String {
        guard let dot = value.firstIndex(of: ".") else { return value }
        var index = value.index(after: dot)
        var digits = 0
        while index < value.endIndex, value[index].isNumber {
            digits += 1
            index = value.index(after: index)
        }
        guard digits > 3 else { return value }
        let keep = value.index(dot, offsetBy: 4)
        var copy = value
        copy.removeSubrange(keep..<index)
        return copy
    }
}

enum CheckoutPath {
    static func absolute(_ path: String?) -> String? {
        guard let path, !path.isEmpty, !path.contains("\0") else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return canonicalPath(expanded)
    }

    static func resolve(_ path: String, base: String) -> String? {
        if path.hasPrefix("/") || path.hasPrefix("~/") { return absolute(path) }
        guard !path.isEmpty, !path.contains("\0"), !path.hasPrefix("-") else { return nil }
        return absolute((base as NSString).appendingPathComponent(path))
    }

    static func contains(root: String, path: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
}

struct StoredEdit: Codable, Equatable {
    var date: Date
    /// The assistant's working directory when the edit completed, as recorded.
    /// After folding, the workspace shown for the edit.
    var workspace: String
    /// Parent folders of the confirmed targets, as recorded (symbolic links
    /// unresolved). They identify the checkout an edit landed in at fold time.
    /// Never contains tool input or diffs.
    var targetDirectories: [String] = []

    func earlier(than other: StoredEdit) -> StoredEdit {
        var selected: StoredEdit
        if date != other.date { selected = date < other.date ? self : other }
        else { selected = workspace <= other.workspace ? self : other }
        selected.targetDirectories = Array(Set(targetDirectories + other.targetDirectories)).sorted()
        return selected
    }
}

struct TailState: Codable {
    var identity: String = ""
    var size: UInt64 = 0
    var modified: TimeInterval = 0
    var offset: UInt64 = 0
    var checkpoint: UInt64 = 0
    var malformedLines: Int = 0
    var oversizedLines: Int = 0
    var droppingOversizedLine: Bool = false
}

/// Incremental JSONL reader. A trailing partial line is reread next time.
/// Oversized lines are skipped and their bytes are never retained.
enum JSONLTail {
    static let maximumLineBytes = 64 * 1024 * 1024

    static func read(url: URL, state: inout TailState, reset: () -> Void, parse: (Data) -> Bool) throws {
        let metadata = try FileStat.required(url)
        let size = metadata.size
        let modified = metadata.modified.timeIntervalSince1970
        let identity = metadata.identity
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var local = state
        let sameIdentity = local.identity == identity && !local.identity.isEmpty
        var reusable = sameIdentity && size >= local.offset && size >= local.size
        if reusable, size == local.size, modified != local.modified { reusable = false }
        if reusable, local.offset > 0, try checkpoint(handle, offset: local.offset) != local.checkpoint { reusable = false }
        if !reusable {
            local = TailState(identity: identity)
            reset()
        } else if local.identity.isEmpty {
            local.identity = identity
        }
        if reusable, local.size == size, local.modified == modified {
            state = local
            return
        }
        try handle.seek(toOffset: local.offset)
        var buffer = Data()
        var dropping = local.droppingOversizedLine
        let newline = Data([0x0A])
        while true {
            let hadChunk: Bool = try autoreleasepool {
                guard let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty else { return false }
                let previouslySearched = buffer.count
                buffer.append(chunk)
                var start = buffer.startIndex
                var search = buffer.index(buffer.startIndex, offsetBy: previouslySearched)
                while let found = buffer.range(of: newline, in: search..<buffer.endIndex)?.lowerBound {
                    if !dropping {
                        let line = buffer[start..<found]
                        if line.count > maximumLineBytes {
                            local.oversizedLines += 1
                        } else if !line.isEmpty, !parse(Data(line)) {
                            local.malformedLines += 1
                        }
                    }
                    let next = buffer.index(after: found)
                    local.offset += UInt64(buffer.distance(from: start, to: next))
                    start = next
                    search = next
                    dropping = false
                }
                if start != buffer.startIndex { buffer = Data(buffer[start...]) }
                if buffer.count > maximumLineBytes {
                    local.offset += UInt64(buffer.count)
                    buffer.removeAll(keepingCapacity: false)
                    if !dropping { local.oversizedLines += 1 }
                    dropping = true
                }
                return true
            }
            if !hadChunk { break }
        }
        local.size = size
        local.modified = modified
        local.droppingOversizedLine = dropping
        local.checkpoint = try checkpoint(handle, offset: local.offset)
        state = local
    }

    private static func checkpoint(_ handle: FileHandle, offset: UInt64) throws -> UInt64 {
        let count = min(offset, 256)
        try handle.seek(toOffset: offset - count)
        let bytes = try handle.read(upToCount: Int(count)) ?? Data()
        return bytes.reduce(UInt64(14695981039346656037)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
}
