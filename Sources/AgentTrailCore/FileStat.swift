import Foundation

/// File metadata read with `lstat`. `FileManager.attributesOfItem` also reads
/// every extended attribute: that is slow, and inside privacy-protected folders
/// such as ~/Documents it makes macOS ask the user for access and blocks the
/// scan until someone answers. Only type, identity, size and dates are needed.
struct FileStat {
    enum Kind { case directory, regular, symbolicLink, other }

    let kind: Kind
    let device: Int32
    let inode: UInt64
    let size: UInt64
    let created: Date
    let modified: Date

    /// Like `attributesOfItem(atPath:)`, a final symbolic link is not followed.
    static func of(_ path: String) -> FileStat? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let kind: Kind
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .regular
        case S_IFLNK: kind = .symbolicLink
        default: kind = .other
        }
        return FileStat(kind: kind, device: info.st_dev, inode: info.st_ino, size: UInt64(max(0, info.st_size)),
                        created: date(info.st_birthtimespec), modified: date(info.st_mtimespec))
    }

    /// Throws the same "no such file" error a Foundation read would.
    static func required(_ url: URL) throws -> FileStat {
        guard let value = of(url.path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        return value
    }

    /// The same text earlier versions stored from Foundation's attributes, so
    /// existing cache entries keep matching.
    var identity: String { "\(device):\(inode):\(created.timeIntervalSince1970)" }

    /// Built exactly as Foundation builds file dates, so saved folder identities
    /// compare equal bit for bit.
    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(time.tv_sec) - Date.timeIntervalBetween1970AndReferenceDate
             + Double(time.tv_nsec) / 1_000_000_000)
    }
}
