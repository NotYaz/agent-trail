import Foundation

public struct AgentSource: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var configDirectory: String
    public var userDataDirectory: String?
    public var bundleIdentifier: String

    public init(id: String, name: String, configDirectory: String, userDataDirectory: String? = nil, bundleIdentifier: String = "com.anthropic.claudefordesktop") {
        self.id = id
        self.name = name
        self.configDirectory = configDirectory
        self.userDataDirectory = userDataDirectory
        self.bundleIdentifier = bundleIdentifier
    }

    public static func defaults(home: String = NSHomeDirectory()) -> [AgentSource] {
        [
            AgentSource(id: "claude-primary", name: "Claude · Main", configDirectory: "\(home)/.claude"),
            AgentSource(id: "claude-second", name: "Claude · Second", configDirectory: "\(home)/.claude-second", userDataDirectory: "\(home)/Library/Application Support/Claude-Second")
        ]
    }
}

public struct ProjectActivity: Sendable {
    public var sourceID: String
    public var projectPath: String
    public var latestActivity: Date
    public var latestEdit: Date?
    public var sessionCount: Int
    public var workspacePath: String?
    public var latestEditWorkspacePath: String?

    public init(sourceID: String, projectPath: String, latestActivity: Date, latestEdit: Date? = nil, sessionCount: Int = 1, workspacePath: String? = nil, latestEditWorkspacePath: String? = nil) {
        self.sourceID = sourceID
        self.projectPath = projectPath
        self.latestActivity = latestActivity
        self.latestEdit = latestEdit
        self.sessionCount = sessionCount
        self.workspacePath = workspacePath
        self.latestEditWorkspacePath = latestEditWorkspacePath
    }
}

public struct ProjectSummary: Identifiable, Sendable {
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
                    latestEditWorkspacePath: lastEdited?.latestEditWorkspacePath ?? lastEdited?.workspacePath)
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

public struct ScanResult: Sendable {
    public var projects: [ProjectSummary]
    public var notices: [String]
    public var scannedAt: Date

    public init(projects: [ProjectSummary], notices: [String] = [], scannedAt: Date = Date()) {
        self.projects = projects
        self.notices = notices
        self.scannedAt = scannedAt
    }
}

// Add other assistants by translating their local records into ProjectActivity.
public protocol ActivityProvider {
    func scan(sources: [AgentSource]) -> ScanResult
}
