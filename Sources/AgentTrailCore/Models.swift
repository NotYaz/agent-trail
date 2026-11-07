import Foundation

/// Which local assistant a profile reads. Missing values in older settings stay Claude.
/// Everything that differs per assistant lives in its `descriptor`.
public enum AssistantKind: String, Codable, CaseIterable, Sendable {
    case claude
    case codex
    case grok
    case copilot
    case opencode
    case cursor

    public var displayName: String { descriptor.displayName }

    /// Standard home used for new profiles. Set configDirectory explicitly when
    /// an assistant is launched with a custom home environment variable.
    public func defaultHome(home: String) -> String { descriptor.defaultHome(home: home) }
}

public struct AgentSource: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var configDirectory: String
    public var userDataDirectory: String?
    public var bundleIdentifier: String
    public var assistant: AssistantKind

    public init(id: String, name: String, configDirectory: String, userDataDirectory: String? = nil, bundleIdentifier: String? = nil, assistant: AssistantKind = .claude) {
        self.id = id
        self.name = name
        self.configDirectory = configDirectory
        self.userDataDirectory = userDataDirectory
        self.assistant = assistant
        self.bundleIdentifier = bundleIdentifier ?? assistant.descriptor.defaultBundleIdentifier
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, configDirectory, userDataDirectory, bundleIdentifier, assistant
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        configDirectory = try values.decode(String.self, forKey: .configDirectory)
        userDataDirectory = try values.decodeIfPresent(String.self, forKey: .userDataDirectory)
        if let raw = try values.decodeIfPresent(String.self, forKey: .assistant) {
            guard let kind = AssistantKind(rawValue: raw) else {
                // A newer build's assistant: name it, so the settings error can say so.
                throw DecodingError.dataCorruptedError(forKey: .assistant, in: values,
                    debugDescription: "Unknown assistant '\(raw.prefix(40))'")
            }
            assistant = kind
        } else {
            assistant = .claude
        }
        bundleIdentifier = try values.decodeIfPresent(String.self, forKey: .bundleIdentifier)
            ?? assistant.descriptor.defaultBundleIdentifier
    }

    public static func defaults(home: String = NSHomeDirectory()) -> [AgentSource] {
        [
            AgentSource(id: "claude-primary", name: "Claude · Main", configDirectory: "\(home)/.claude"),
            AgentSource(id: "claude-second", name: "Claude · Second", configDirectory: "\(home)/.claude-second", userDataDirectory: "\(home)/Library/Application Support/Claude-Second"),
            AgentSource(id: "codex", name: "Codex", configDirectory: AssistantKind.codex.defaultHome(home: home), assistant: .codex),
            AgentSource(id: "grok", name: "Grok", configDirectory: AssistantKind.grok.defaultHome(home: home), assistant: .grok)
        ]
    }
}

/// Calendar-day counts in UTC, with sessions counted on their creation day.
public struct ActivityDay: Identifiable, Codable, Equatable, Sendable {
    public var id: Date { day }
    public var day: Date
    public var editCount: Int
    public var sessionCount: Int

    public init(day: Date, editCount: Int = 0, sessionCount: Int = 0) {
        self.day = Self.start(of: day)
        self.editCount = editCount
        self.sessionCount = sessionCount
    }

    // Cached: history merges call this for every record on each overview rebuild.
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    public static func start(of date: Date) -> Date {
        utcCalendar.startOfDay(for: date)
    }

    public static func merge(_ records: [ActivityDay]) -> [ActivityDay] {
        Dictionary(grouping: records, by: { start(of: $0.day) }).map { day, values in
            ActivityDay(day: day, editCount: values.reduce(0) { $0 + $1.editCount },
                        sessionCount: values.reduce(0) { $0 + $1.sessionCount })
        }.sorted { $0.day < $1.day }
    }
}

/// One confirmed edit's completion time. `delegated` is true when the edit's earliest
/// record came from a Claude subagent transcript or a Codex spawned thread. Grok never sets it.
public struct EditMoment: Hashable, Sendable {
    public var date: Date
    public var delegated: Bool

    public init(date: Date, delegated: Bool = false) {
        self.date = date
        self.delegated = delegated
    }

    /// Date order. Direct edits go first at the same instant, so merged
    /// arrays never depend on dictionary iteration order.
    static func chronological(_ lhs: EditMoment, _ rhs: EditMoment) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        return !lhs.delegated && rhs.delegated
    }
}

public struct ProjectActivity: Equatable, Sendable {
    public var sourceID: String
    public var projectPath: String
    public var latestActivity: Date
    public var latestEdit: Date?
    public var sessionCount: Int
    public var workspacePath: String?
    public var latestEditWorkspacePath: String?
    public var history: [ActivityDay]
    /// Every confirmed edit counted in `history`, ascending. Raw instants, so
    /// local days can be derived in any time zone without rescanning.
    public var editMoments: [EditMoment]
    /// Creation time of every session counted in `history`, ascending.
    public var sessionStarts: [Date]

    public init(sourceID: String, projectPath: String, latestActivity: Date, latestEdit: Date? = nil, sessionCount: Int = 1, workspacePath: String? = nil, latestEditWorkspacePath: String? = nil, history: [ActivityDay] = [], editMoments: [EditMoment] = [], sessionStarts: [Date] = []) {
        self.sourceID = sourceID
        self.projectPath = projectPath
        self.latestActivity = latestActivity
        self.latestEdit = latestEdit
        self.sessionCount = sessionCount
        self.workspacePath = workspacePath
        self.latestEditWorkspacePath = latestEditWorkspacePath
        self.history = history
        self.editMoments = editMoments
        self.sessionStarts = sessionStarts
    }
}

public struct ProjectSummary: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public var path: String
    public var activities: [ProjectActivity]
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var isShared: Bool { Set(activities.map(\.sourceID)).count > 1 }
    public var latestActivity: ProjectActivity { activities.max { $0.latestActivity < $1.latestActivity }! }
    public var latestEdit: ProjectActivity? {
        activities.filter { $0.latestEdit != nil }.max { $0.latestEdit! < $1.latestEdit! }
    }
    public var sortDate: Date { latestActivity.latestActivity }
    public var history: [ActivityDay] { ActivityDay.merge(activities.flatMap(\.history)) }
    public var recordedEditCount: Int { history.reduce(0) { $0 + $1.editCount } }
    public var sessionCount: Int { activities.reduce(0) { $0 + $1.sessionCount } }

    public static func merge(_ activities: [ProjectActivity]) -> [ProjectSummary] {
        let byPath = Dictionary(grouping: activities) { canonicalPath($0.projectPath) }
        return byPath.map { path, records in
            let bySource = Dictionary(grouping: records, by: \.sourceID)
            let merged = bySource.map { sourceID, records in
                let lastActive = records.max { $0.latestActivity < $1.latestActivity }!
                let lastEdited = records.filter { $0.latestEdit != nil }.max { $0.latestEdit! < $1.latestEdit! }
                return ProjectActivity(sourceID: sourceID, projectPath: path,
                    latestActivity: records.map(\.latestActivity).max()!,
                    latestEdit: records.compactMap(\.latestEdit).max(),
                    sessionCount: records.reduce(0) { $0 + $1.sessionCount },
                    workspacePath: lastActive.workspacePath,
                    latestEditWorkspacePath: lastEdited?.latestEditWorkspacePath ?? lastEdited?.workspacePath,
                    history: ActivityDay.merge(records.flatMap(\.history)),
                    editMoments: records.flatMap(\.editMoments).sorted(by: EditMoment.chronological),
                    sessionStarts: records.flatMap(\.sessionStarts).sorted())
            }.sorted { $0.latestActivity > $1.latestActivity }
            return ProjectSummary(path: path, activities: merged)
        }.sorted {
            if $0.sortDate == $1.sortDate { return $0.path < $1.path }
            return $0.sortDate > $1.sortDate
        }
    }
}

public func canonicalPath(_ path: String) -> String {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        .standardizedFileURL.resolvingSymlinksInPath().path
}

/// Evidence-backed project identity for one assistant session. The recorded
/// launch directory stays separate from the repository's present location.
public struct SessionProjectAssociation: Hashable, Sendable {
    public let sourceID: String
    public let sessionID: String
    public let recordedWorkspace: String
    public let projectPath: String

    public init(sourceID: String, sessionID: String, recordedWorkspace: String, projectPath: String) {
        self.sourceID = sourceID
        self.sessionID = sessionID
        self.recordedWorkspace = recordedWorkspace
        self.projectPath = projectPath
    }
}

/// Confirmed edits recorded under a folder that no longer exists, below the
/// folder a session was started in. They may belong to a project that was
/// moved without leaving a link behind; the user can locate it.
public struct MissingFolder: Hashable, Sendable {
    public let sourceID: String
    /// The project card these edits are counted on (the launch folder).
    public let projectPath: String
    /// The topmost folder that no longer exists.
    public let path: String
    public let editCount: Int
    /// Recorded target folders, used to check a folder the user chooses.
    public let sampleDirectories: [String]

    public init(sourceID: String, projectPath: String, path: String, editCount: Int, sampleDirectories: [String] = []) {
        self.sourceID = sourceID
        self.projectPath = projectPath
        self.path = path
        self.editCount = editCount
        self.sampleDirectories = sampleDirectories
    }

    /// The earlier path of `chosen`: the folder at or below `path` whose
    /// recorded subfolders exist inside the chosen folder. Nil when none of the
    /// recorded folders can be found there, so an unrelated folder is refused.
    public func previousRoot(forChosenFolder chosen: String) -> String? {
        let files = FileManager.default
        var best: (root: String, matches: Int)?
        for depth in 0...8 {
            var matches = 0
            var root: String?
            for directory in sampleDirectories where CheckoutPath.contains(root: path, path: directory) {
                let relative = directory == path ? [] : directory.dropFirst(path.count + 1).split(separator: "/").map(String.init)
                // A recorded folder equal to the candidate root would map onto
                // the chosen folder itself and prove nothing.
                guard relative.count > depth else { continue }
                let candidate = ([path] + relative.prefix(depth)).joined(separator: "/")
                guard root == nil || root == candidate else { continue }
                let rebased = ([chosen] + relative.dropFirst(depth)).joined(separator: "/")
                if files.fileExists(atPath: rebased) {
                    root = candidate
                    matches += 1
                }
            }
            if let root, matches > (best?.matches ?? 0) { best = (root, matches) }
        }
        if let best { return best.root }
        // Edits made directly in the missing folder leave nothing deeper to
        // check; the user's explicit choice of a checkout decides.
        return !sampleDirectories.isEmpty && sampleDirectories.allSatisfy({ $0 == path }) ? path : nil
    }
}

/// One confirmed edit on a session's trail: when it completed, the checkout it
/// counts for, and the folder it landed in (that checkout, or a Claude worktree).
public struct TrailEdit: Codable, Hashable, Sendable {
    public var date: Date
    public var projectPath: String
    public var workspacePath: String
    public var delegated: Bool

    public init(date: Date, projectPath: String, workspacePath: String, delegated: Bool = false) {
        self.date = date
        self.projectPath = projectPath
        self.workspacePath = workspacePath
        self.delegated = delegated
    }
}

/// A branch a session wrote, and the folder it was checked out in.
public struct WrittenBranch: Codable, Hashable, Sendable {
    public var workspacePath: String
    public var branch: String

    public init(workspacePath: String, branch: String) {
        self.workspacePath = workspacePath
        self.branch = branch
    }
}

/// One session over time: the same edits the project cards count, kept with
/// the session that made them. Each edit appears on exactly one trail.
public struct SessionTrail: Codable, Hashable, Sendable {
    public var sourceID: String
    public var sessionID: String
    /// The project card the session itself counts on.
    public var projectPath: String
    public var createdAt: Date
    public var latestActivity: Date
    /// The thread that spawned this one, when the assistant records it.
    public var parentSessionID: String?
    /// Ascending by date.
    public var edits: [TrailEdit]
    /// Claude Desktop only: the branches the session wrote, in its own order.
    public var writtenBranches: [WrittenBranch]
    /// Claude Desktop only: the CLI session ids live reports use for this session.
    public var otherIDs: [String]

    public init(sourceID: String, sessionID: String, projectPath: String, createdAt: Date, latestActivity: Date,
                parentSessionID: String? = nil, edits: [TrailEdit] = [], writtenBranches: [WrittenBranch] = [],
                otherIDs: [String] = []) {
        self.sourceID = sourceID
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.createdAt = createdAt
        self.latestActivity = latestActivity
        self.parentSessionID = parentSessionID
        self.edits = edits
        self.writtenBranches = writtenBranches
        self.otherIDs = otherIDs
    }

    /// Paths canonicalized and edits sorted, as `ProjectSummary.merge` treats
    /// projects. Edits share a few folders, so each is resolved once.
    static func merge(_ trails: [SessionTrail]) -> [SessionTrail] {
        var resolved: [String: String] = [:]
        func canonical(_ path: String) -> String {
            if let known = resolved[path] { return known }
            let value = canonicalPath(path)
            resolved[path] = value
            return value
        }
        return trails.map { trail in
            var trail = trail
            trail.projectPath = canonical(trail.projectPath)
            trail.edits = trail.edits.map {
                TrailEdit(date: $0.date, projectPath: canonical($0.projectPath),
                          workspacePath: canonical($0.workspacePath), delegated: $0.delegated)
            }.sorted { ($0.date, $0.workspacePath) < ($1.date, $1.workspacePath) }
            trail.writtenBranches = trail.writtenBranches.map {
                WrittenBranch(workspacePath: canonical($0.workspacePath), branch: $0.branch)
            }
            return trail
        }.sorted { ($0.createdAt, $0.sourceID, $0.sessionID) < ($1.createdAt, $1.sourceID, $1.sessionID) }
    }
}

public struct ScanResult: Sendable {
    public var projects: [ProjectSummary]
    public var notices: [String]
    public var scannedAt: Date
    public var sessionProjects: [SessionProjectAssociation]
    public var projectLocations: ProjectLocationRegistry
    public var missingFolders: [MissingFolder]
    /// Projects whose own folder could not be found during the scan.
    public var unavailableProjects: Set<String>
    /// Every session with its confirmed edits, for the Map.
    public var sessionTrails: [SessionTrail]

    public init(projects: [ProjectSummary], notices: [String] = [], scannedAt: Date = Date(),
                sessionProjects: [SessionProjectAssociation] = [], projectLocations: ProjectLocationRegistry = .init(),
                missingFolders: [MissingFolder] = [], unavailableProjects: Set<String> = [],
                sessionTrails: [SessionTrail] = []) {
        self.projects = projects
        self.notices = notices
        self.scannedAt = scannedAt
        self.sessionProjects = sessionProjects
        self.projectLocations = projectLocations
        self.missingFolders = missingFolders
        self.unavailableProjects = unavailableProjects
        self.sessionTrails = sessionTrails
    }
}

/// Add another assistant with a descriptor (AssistantDescriptor.swift), a
/// `HistoryAdapter` that turns its local records into `HistorySession`s, and
/// an `AssistantRegistry` entry.
public protocol ActivityProvider {
    func scan(sources: [AgentSource]) -> ScanResult
}
