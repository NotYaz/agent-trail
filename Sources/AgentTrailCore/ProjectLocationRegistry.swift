import Darwin
import Foundation

/// An earlier path of a checkout that history may still mention. Previous
/// locations are learned from evidence (a symbolic link left at the old path,
/// or a bookmark that followed a physical move) or added explicitly by the user.
public struct PreviousLocation: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable {
        /// A symbolic link at this path pointed at the checkout's root.
        case link
        /// The checkout's own folder was observed to move away from this path.
        case move
        /// The user chose the checkout for this path.
        case manual
    }

    public let path: String
    public let origin: Origin
    public let observedAt: Date
    /// When this checkout took the path over from another folder that owned it
    /// before; nil when no earlier owner is known.
    public internal(set) var since: Date?
    /// When the checkout was last confirmed at, or through, this path.
    public internal(set) var lastSeenAt: Date?
    /// When another folder took the path over. Evidence recorded at the path
    /// from then on is not this checkout's. Kept once observed, so it still
    /// holds after that other folder leaves too.
    public internal(set) var shadowedSince: Date?

    init(path: String, origin: Origin, observedAt: Date, since: Date? = nil, lastSeenAt: Date? = nil) {
        self.path = path
        self.origin = origin
        self.observedAt = observedAt
        self.since = since
        self.lastSeenAt = lastSeenAt
    }

    /// Whether evidence recorded at `date` (nil: now) belongs to this tenure.
    func applies(at date: Date?) -> Bool {
        if let since, let date, date < since { return false }
        if let shadowedSince {
            guard let date, date < shadowedSince else { return false }
        }
        return true
    }
}

/// One local checkout identified by folder identity (device, inode, creation
/// date) and a macOS bookmark, so it can be followed when the folder moves.
/// Unrelated clones remain distinct even when their names match.
public struct ProjectLocation: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public internal(set) var currentPath: String
    public internal(set) var previousLocations: [PreviousLocation]
    public let firstObservedAt: Date
    /// Coarse persisted record of when the folder was last confirmed at its
    /// current path; updated at most every few hours to avoid constant saves.
    public internal(set) var lastSeenAt: Date?
    var bookmarkData: Data
    var identity: ProjectFileIdentity
    /// Transient: false while the folder cannot be found at `currentPath`.
    public internal(set) var isPresent = true
    /// Transient: a different folder now occupies `currentPath` and the original
    /// could not be found. Its previous locations stop applying, so history of a
    /// vanished folder is never merged into an unrelated checkout.
    public internal(set) var isReplaced = false
    /// Transient: last failed bookmark lookup, so a folder that stays missing
    /// is not looked up on every scan.
    var lastBookmarkAttempt: Date?
    /// Transient: precise last confirmation while the app is running.
    var lastPresentAt: Date?

    public var previousPaths: [String] { previousLocations.map(\.path) }

    var lastConfirmed: Date { max(lastPresentAt ?? .distantPast, lastSeenAt ?? firstObservedAt) }

    private enum CodingKeys: String, CodingKey {
        case id, currentPath, previousLocations, firstObservedAt, lastSeenAt, bookmarkData, identity
    }
}

/// A private local catalog of checkout locations. It stores folder identity,
/// bookmarks, and paths only, never assistant messages or file contents.
/// Evidence-derived entries are added automatically; nothing here scans the
/// disk for repositories or compares folder names or remotes.
public struct ProjectLocationRegistry: Codable, Equatable, Sendable {
    public private(set) var locations: [ProjectLocation]
    private var version = 1

    public init() {
        locations = []
    }

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/AgentTrail", isDirectory: true)
            .appendingPathComponent("project-locations.json")
    }

    public static func load(from url: URL) throws -> ProjectLocationRegistry {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 16 * 1_024 * 1_024 + 1) ?? Data()
        guard data.count <= 16 * 1_024 * 1_024 else { throw LocationError.invalidCatalog }
        // Dates use the default encoding: folder identity compares creation
        // dates exactly, and ISO-8601 would drop their fractional seconds.
        var result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        result.refreshDerivedState()
        return result
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func save(to url: URL) throws {
        try validate()
        let files = FileManager.default
        let directory = url.deletingLastPathComponent()
        try files.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try encoded().write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Queries

    public func location(forCurrentPath path: String) -> ProjectLocation? {
        let canonical = canonicalPath(path)
        return locations.first { $0.currentPath == canonical || $0.currentPath == path }
    }

    /// Pure string rewrite of a recorded path through the longest earlier
    /// location whose tenure covers `date`, the time the path was recorded. One
    /// path can be several folders' earlier location, each for its own period.
    /// A nil date means now, which a shadowed tenure never covers.
    public func rewrite(_ lexical: String, at date: Date? = nil) -> String {
        var best: (old: String, current: String, since: Date)?
        for location in locations where !location.isReplaced {
            for previous in location.previousLocations
                where CheckoutPath.contains(root: previous.path, path: lexical) && previous.applies(at: date) {
                let since = previous.since ?? .distantPast
                if let current = best, previous.path.count < current.old.count
                    || (previous.path.count == current.old.count && since <= current.since) { continue }
                best = (previous.path, location.currentPath, since)
            }
        }
        guard let best else { return lexical }
        return best.current + lexical.dropFirst(best.old.count)
    }

    /// The canonical current path for a recorded path. Used for live sessions,
    /// which report the folder their process was started in.
    public func relocatedPath(_ raw: String, at date: Date? = nil) -> String {
        guard let lexical = Self.lexicalPath(raw) else { return canonicalPath(raw) }
        return canonicalPath(rewrite(lexical, at: date))
    }

    // MARK: Automatic maintenance

    /// Remember a checkout root that history attributed work to, so a later
    /// physical move of the same folder can be followed. Returns true when the
    /// persisted catalog changed.
    @discardableResult
    mutating func observe(checkout path: String, now: Date) -> Bool {
        guard path != "/", let identity = ProjectFileIdentity.read(path) else { return false }
        if let index = locations.firstIndex(where: { $0.identity == identity }) {
            guard locations[index].currentPath != path else { return false }
            // The same folder reached through another spelling (a firmlink or a
            // second mount) while it is still at its known path is not a move.
            if ProjectFileIdentity.read(locations[index].currentPath) == identity { return false }
            // Another entry still claiming this path describes a folder that is
            // no longer here; this folder is.
            let id = locations[index].id
            locations.removeAll { $0.id != id && $0.currentPath == path }
            guard let moving = locations.firstIndex(where: { $0.id == id }) else { return true }
            move(moving, to: path, now: now)
            return true
        }
        let entry = ProjectLocation(id: UUID(), currentPath: path, previousLocations: [],
            firstObservedAt: now, lastSeenAt: now, bookmarkData: (try? Self.bookmark(for: path)) ?? Data(),
            identity: identity, lastPresentAt: now)
        if let index = locations.firstIndex(where: { $0.currentPath == path }) {
            // A different folder now lives at a known path and the original was
            // not found elsewhere. Its previous locations described a folder that
            // is gone, so they are not transferred to this unrelated checkout.
            locations[index] = entry
            return true
        }
        if locations.count >= Self.maximumLocations {
            // Make room by forgetting the oldest folder that is gone and has
            // no earlier locations to remember.
            guard let stale = locations.indices.filter({ !locations[$0].isPresent && locations[$0].previousLocations.isEmpty })
                .min(by: { locations[$0].firstObservedAt < locations[$1].firstObservedAt }) else { return false }
            locations.remove(at: stale)
        }
        locations.append(entry)
        return true
    }

    /// Remember a symbolic link that pointed at a checkout's root, so evidence
    /// recorded through the link still groups with the checkout after the link
    /// is deleted. Returns true when the persisted catalog changed.
    @discardableResult
    mutating func observe(link: String, checkout: String, now: Date) -> Bool {
        guard link != "/", link != checkout, !CheckoutPath.contains(root: link, path: checkout),
              !CheckoutPath.contains(root: checkout, path: link) else { return false }
        var changed = observe(checkout: checkout, now: now)
        guard let index = locations.firstIndex(where: { $0.currentPath == checkout }) else { return changed }
        guard !locations[index].previousPaths.contains(link),
              !locations.contains(where: { $0.currentPath == link }) else { return changed }
        // Another folder's earlier tenure at this path must have ended.
        let others = locations.flatMap { $0.previousLocations }.filter { $0.path == link }
        guard others.allSatisfy({ $0.shadowedSince != nil }) else { return changed }
        locations[index].previousLocations.append(PreviousLocation(path: link, origin: .link, observedAt: now,
            since: others.compactMap(\.shadowedSince).max(), lastSeenAt: now))
        locations[index].previousLocations = Self.capped(locations[index].previousLocations)
        changed = true
        return changed
    }

    /// Follow folders that moved and recompute transient state. Every entry is
    /// resolved before any is changed, so the order of entries never decides
    /// which of two swapped folders survives, and one unreadable bookmark
    /// cannot stop the rest. Returns true when the persisted catalog changed.
    @discardableResult
    public mutating func refresh(now: Date = Date()) -> Bool {
        enum Resolution { case present, moved(String), missing, replaced }
        var resolutions: [Resolution] = []
        var searched = Set<Int>()
        var changed = false
        for index in locations.indices {
            let location = locations[index]
            if let found = ProjectFileIdentity.read(location.currentPath), found == location.identity {
                locations[index].lastBookmarkAttempt = nil
                locations[index].lastPresentAt = now
                if found.device != location.identity.device {
                    // A remounted volume can get a new device number.
                    locations[index].identity = found
                    changed = true
                }
                if location.lastSeenAt.map({ now.timeIntervalSince($0) >= Self.lastSeenInterval || $0 > now }) ?? true {
                    locations[index].lastSeenAt = now
                    changed = true
                }
                resolutions.append(.present)
                continue
            }
            let due = location.lastBookmarkAttempt.map { now.timeIntervalSince($0) >= 300 || $0 > now } ?? true
            if due, let moved = findMoved(location), moved != location.currentPath {
                locations[index].lastBookmarkAttempt = nil
                searched.insert(index)
                resolutions.append(.moved(moved))
            } else {
                if due {
                    locations[index].lastBookmarkAttempt = now
                    searched.insert(index)
                }
                resolutions.append(Self.isOccupied(location.currentPath) ? .replaced : .missing)
            }
        }
        // An entry about to be declared stale because another folder moved onto
        // its path is searched first, even if its last search was recent.
        for (index, resolution) in resolutions.enumerated() {
            guard case .moved(let path) = resolution else { continue }
            for other in resolutions.indices where other != index && locations[other].currentPath == path && !searched.contains(other) {
                if case .moved = resolutions[other] { continue }
                searched.insert(other)
                if let moved = findMoved(locations[other]), moved != locations[other].currentPath {
                    resolutions[other] = .moved(moved)
                }
            }
        }
        var stale = Set<UUID>()
        for (index, resolution) in resolutions.enumerated() {
            switch resolution {
            case .present:
                locations[index].isPresent = true
                locations[index].isReplaced = false
            case .missing:
                locations[index].isPresent = false
                locations[index].isReplaced = false
            case .replaced:
                locations[index].isPresent = false
                locations[index].isReplaced = true
            case .moved(let path):
                // An entry still claiming the destination is stale unless its own
                // folder moved away too.
                for other in resolutions.indices where other != index && locations[other].currentPath == path {
                    if case .moved = resolutions[other] { continue }
                    stale.insert(locations[other].id)
                }
                move(index, to: path, now: now)
                changed = true
            }
        }
        if !stale.isEmpty {
            locations.removeAll { stale.contains($0.id) }
            changed = true
        }
        if refreshShadows(now: now) { changed = true }
        return changed
    }

    /// Presence from folder identity alone (no bookmark lookups) and shadows.
    /// Cheap enough to run after loading and after learning.
    mutating func refreshDerivedState(now: Date = Date()) {
        for index in locations.indices {
            let location = locations[index]
            let present = ProjectFileIdentity.read(location.currentPath) == location.identity
            locations[index].isPresent = present
            locations[index].isReplaced = !present && Self.isOccupied(location.currentPath)
            if present { locations[index].lastPresentAt = now }
        }
        refreshShadows(now: now)
    }

    // MARK: User actions

    /// Link earlier paths to a checkout the user chose. The chosen folder must be
    /// a valid checkout root. Each earlier path must be gone or be a link into
    /// that checkout, so an existing folder is never claimed by another one.
    public mutating func register(path: String, previousPaths: [String], now: Date = Date()) throws {
        guard let lexical = Self.lexicalPath(path) else { throw LocationError.invalidPath }
        let resolver = GitProjectResolver()
        guard let checkout = resolver.physical(lexical), resolver.isCheckoutRoot(checkout),
              let identity = ProjectFileIdentity.read(checkout) else { throw LocationError.notRepository }
        var aliases: [String] = []
        for raw in previousPaths {
            guard let alias = Self.lexicalPath(raw), alias != "/" else { throw LocationError.invalidPath }
            guard alias != checkout else { continue }
            guard !CheckoutPath.contains(root: alias, path: checkout),
                  !CheckoutPath.contains(root: checkout, path: alias) else { throw LocationError.overlappingAlias }
            if let metadata = FileStat.of(alias) {
                // A link into the checkout, or one left dangling by the move, is
                // fine. Anything else at that path is another folder's.
                let isLink = metadata.kind == .symbolicLink
                let target = canonicalPath(alias)
                guard isLink, CheckoutPath.contains(root: checkout, path: target)
                        || !FileManager.default.fileExists(atPath: target) else {
                    throw LocationError.previousLocationStillExists
                }
            }
            aliases.append(alias)
        }
        var next = self
        var inherited: [PreviousLocation] = []
        // A stale entry whose folder used to be at one of these paths is the
        // same project seen before a cross-volume move; fold it into this one.
        for alias in aliases {
            if let stale = next.locations.firstIndex(where: { $0.currentPath == alias && $0.identity != identity }) {
                inherited += next.locations[stale].previousLocations
                next.locations.remove(at: stale)
            }
        }
        _ = next.observe(checkout: checkout, now: now)
        guard let index = next.locations.firstIndex(where: { $0.currentPath == checkout }) else {
            throw LocationError.catalogFull
        }
        for alias in aliases where next.locations[index].previousPaths.contains(where: {
            $0 != alias && CheckoutPath.contains(root: alias, path: $0)
        }) {
            // It would also capture files that were never in this checkout.
            throw LocationError.broaderThanEarlierLocation
        }
        for var previous in inherited + aliases.map({ PreviousLocation(path: $0, origin: .manual, observedAt: now) }) {
            guard !next.locations[index].previousPaths.contains(previous.path),
                  !CheckoutPath.contains(root: previous.path, path: checkout),
                  !CheckoutPath.contains(root: checkout, path: previous.path) else { continue }
            let others = next.locations.filter { $0.id != next.locations[index].id }
                .flatMap(\.previousLocations).filter { $0.path == previous.path }
            // Another folder's tenure at this path must have ended first.
            guard others.allSatisfy({ $0.shadowedSince != nil }) else { throw LocationError.conflictingAlias }
            if previous.since == nil { previous.since = others.compactMap(\.shadowedSince).max() }
            next.locations[index].previousLocations.append(previous)
        }
        next.locations[index].previousLocations = Self.capped(next.locations[index].previousLocations)
        next.refreshDerivedState(now: now)
        try next.validate()
        self = next
    }

    /// Stop grouping earlier paths with this checkout. The bookmark is kept so a
    /// future move is still followed. A link still present is learned again.
    @discardableResult
    public mutating func forgetPreviousLocations(of path: String) -> Bool {
        guard let index = locations.firstIndex(where: { $0.currentPath == path || $0.currentPath == canonicalPath(path) }),
              !locations[index].previousLocations.isEmpty else { return false }
        locations[index].previousLocations.removeAll()
        return true
    }

    /// Standardize a path without following symlinks. This preserves the
    /// recorded spelling, which is what earlier locations are matched against.
    public static func lexicalPath(_ raw: String) -> String? {
        guard !raw.isEmpty, !raw.contains("\0"), raw.utf8.count <= 32_768 else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }

    // MARK: Internals

    static let maximumLocations = 1_024

    /// Synthetic catalog for demo mode. Never validated or saved.
    static func demo(_ entries: [(current: String, previous: [(String, PreviousLocation.Origin)])], now: Date) -> ProjectLocationRegistry {
        var registry = ProjectLocationRegistry()
        registry.locations = entries.enumerated().map { offset, entry in
            ProjectLocation(id: UUID(), currentPath: entry.current,
                previousLocations: entry.previous.map { PreviousLocation(path: $0.0, origin: $0.1, observedAt: now.addingTimeInterval(-86_400)) },
                firstObservedAt: now.addingTimeInterval(-86_400 * 30), lastSeenAt: now, bookmarkData: Data(),
                identity: ProjectFileIdentity(device: 0, inode: UInt64(offset), created: now))
        }
        return registry
    }

    private mutating func move(_ index: Int, to path: String, now: Date) {
        let old = locations[index].currentPath
        var previous = locations[index].previousLocations.filter {
            $0.path != path && !CheckoutPath.contains(root: $0.path, path: path)
                && !CheckoutPath.contains(root: path, path: $0.path)
        }
        if !previous.contains(where: { $0.path == old }),
           !CheckoutPath.contains(root: old, path: path), !CheckoutPath.contains(root: path, path: old) {
            // If another folder owned the old path before this one, this
            // checkout's tenure there began when that one's ended.
            let earlier = locations.filter { $0.id != locations[index].id }.flatMap(\.previousLocations)
                .filter { $0.path == old }.compactMap(\.shadowedSince).max()
            previous.append(PreviousLocation(path: old, origin: .move, observedAt: now,
                                             since: earlier, lastSeenAt: locations[index].lastConfirmed))
        }
        locations[index].previousLocations = Self.capped(previous)
        locations[index].currentPath = path
        locations[index].lastSeenAt = now
        locations[index].lastPresentAt = now
        locations[index].isPresent = true
        locations[index].isReplaced = false
        if let bookmark = try? Self.bookmark(for: path) { locations[index].bookmarkData = bookmark }
    }

    /// Where a tracked folder went. The kernel can name a folder by volume and
    /// inode wherever it moved on that volume, even when something else now
    /// sits at the old path; a bookmark covers volumes whose device number
    /// changed. A folder moved to the Trash is gone, not moved.
    private func findMoved(_ location: ProjectLocation) -> String? {
        if let path = Self.path(device: location.identity.device, inode: location.identity.inode) {
            let found = canonicalPath(path)
            if ProjectFileIdentity.read(found) == location.identity, !Self.isInTrash(found),
               GitProjectResolver().isCheckoutRoot(found) { return found }
        }
        return resolveBookmark(location)
    }

    private static func path(device: UInt64, inode: UInt64) -> String? {
        var fsid = fsid_t(val: (Int32(truncatingIfNeeded: device), 0))
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fsgetpath(&buffer, buffer.count, &fsid, inode) > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func isInTrash(_ path: String) -> Bool {
        (path as NSString).pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    private func resolveBookmark(_ location: ProjectLocation) -> String? {
        guard !location.bookmarkData.isEmpty else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: location.bookmarkData,
                                 options: [.withoutUI, .withoutMounting], relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        let path = canonicalPath(url.path)
        guard ProjectFileIdentity.read(path) == location.identity, !Self.isInTrash(path),
              GitProjectResolver().isCheckoutRoot(path) else { return nil }
        return path
    }

    /// Shadowing: another folder took an earlier path over. Its claim starts at
    /// the later of its creation and the last time this checkout was confirmed
    /// at (or through) that path; a folder moved in keeps an old creation date,
    /// and the moment a move was noticed can be much later than the move. A
    /// shadow is kept once observed. A link into the checkout, or a link left
    /// dangling by a later move, does not shadow; a link to any other existing
    /// folder does. Returns true when the persisted catalog changed.
    @discardableResult
    private mutating func refreshShadows(now: Date) -> Bool {
        let files = FileManager.default
        var changed = false
        for index in locations.indices {
            let location = locations[index]
            for previousIndex in location.previousLocations.indices {
                let previous = location.previousLocations[previousIndex]
                guard previous.shadowedSince == nil,
                      let metadata = FileStat.of(previous.path) else { continue }
                if metadata.kind == .symbolicLink {
                    let target = canonicalPath(previous.path)
                    if CheckoutPath.contains(root: location.currentPath, path: target) {
                        if previous.lastSeenAt.map({ now.timeIntervalSince($0) >= Self.lastSeenInterval || $0 > now }) ?? true {
                            locations[index].previousLocations[previousIndex].lastSeenAt = now
                            changed = true
                        }
                        continue
                    }
                    if !files.fileExists(atPath: target) { continue }
                }
                let created = metadata.created
                let confirmed = previous.origin == .move ? (previous.lastSeenAt ?? previous.observedAt)
                    : max(previous.lastSeenAt ?? .distantPast, previous.observedAt)
                locations[index].previousLocations[previousIndex].shadowedSince = max(created, confirmed, previous.since ?? .distantPast)
                changed = true
            }
        }
        return changed
    }

    private static let lastSeenInterval: TimeInterval = 6 * 3_600

    private static func isOccupied(_ path: String) -> Bool {
        FileStat.of(path) != nil
    }

    private static func capped(_ previous: [PreviousLocation]) -> [PreviousLocation] {
        guard previous.count > 256 else { return previous }
        return Array(previous.sorted { $0.observedAt < $1.observedAt }.suffix(256))
    }

    private static func bookmark(for path: String) throws -> Data {
        try URL(fileURLWithPath: path, isDirectory: true).bookmarkData(options: .minimalBookmark,
            includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    private func validate() throws {
        guard version == 1, locations.count <= Self.maximumLocations,
              Set(locations.map(\.id)).count == locations.count,
              Set(locations.map(\.currentPath)).count == locations.count else { throw LocationError.invalidCatalog }
        for location in locations {
            guard Self.lexicalPath(location.currentPath) == location.currentPath, location.currentPath != "/",
                  location.previousLocations.count <= 256, location.bookmarkData.count <= 1_048_576 else {
                throw LocationError.invalidCatalog
            }
            for path in location.previousPaths {
                guard Self.lexicalPath(path) == path, path != "/",
                      !CheckoutPath.contains(root: path, path: location.currentPath),
                      !CheckoutPath.contains(root: location.currentPath, path: path) else { throw LocationError.invalidCatalog }
            }
            guard Set(location.previousPaths).count == location.previousLocations.count else { throw LocationError.invalidCatalog }
        }
    }
}

struct ProjectFileIdentity: Codable, Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let created: Date

    /// The device number is kept for diagnostics only: macOS can assign an
    /// external volume a different one after a remount. Inode and creation
    /// date together identify a folder.
    static func == (left: ProjectFileIdentity, right: ProjectFileIdentity) -> Bool {
        left.inode == right.inode && left.created == right.created
    }

    static func read(_ path: String) -> ProjectFileIdentity? {
        guard let metadata = FileStat.of(path), metadata.kind == .directory else { return nil }
        return ProjectFileIdentity(device: UInt64(bitPattern: Int64(metadata.device)), inode: metadata.inode,
                                   created: metadata.created)
    }
}

public enum LocationError: LocalizedError, Equatable {
    case invalidPath, notRepository, invalidCatalog, overlappingAlias, conflictingAlias
    case previousLocationStillExists, catalogFull, noMatchingFiles, broaderThanEarlierLocation

    public var errorDescription: String? {
        switch self {
        case .invalidPath: return "A project location must be an absolute folder path."
        case .notRepository: return "Choose the folder that contains the project's .git folder."
        case .invalidCatalog: return "The saved project location catalog is invalid or unsupported."
        case .overlappingAlias: return "An earlier location cannot contain, or be inside, the chosen folder."
        case .conflictingAlias: return "That earlier location is already linked to another project."
        case .previousLocationStillExists:
            return "A folder still exists at the earlier location. Agent Trail links an earlier path only when it is gone or is a link to the chosen folder."
        case .catalogFull: return "Agent Trail is already tracking the maximum number of project locations."
        case .noMatchingFiles: return "The chosen folder does not contain the folders recorded at the earlier location. Choose the folder that used to be there."
        case .broaderThanEarlierLocation:
            return "That earlier location contains one this project already has, so it would also claim files that were never in the project."
        }
    }
}
