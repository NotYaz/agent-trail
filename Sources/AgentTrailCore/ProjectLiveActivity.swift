import Foundation

public struct SourceLiveActivity: Identifiable, Sendable {
    public var id: String { sourceID }
    public let sourceID: String
    public let sessions: [LiveAgentSession]
    public var waitingCount: Int { sessions.filter { $0.status == .waiting }.count }
    public var workingCount: Int { sessions.filter { $0.status == .working }.count }
    public var idleCount: Int { sessions.filter { $0.status == .idle }.count }
    public var unknownCount: Int { sessions.filter { $0.status == .unknown }.count }
    public var workspacePaths: [String] { Array(Set(sessions.map(\.workspacePath))).sorted() }
}

/// Live evidence for one canonical origin project. An absent group means no live
/// report, never idle. Status and checkout context come only from supplied live
/// sessions, without consulting historical activity or edit timestamps.
public struct ProjectLiveActivity: Identifiable, Sendable {
    public var id: String { projectPath }
    public let projectPath: String
    public let sessions: [LiveAgentSession]
    public var waitingCount: Int { sessions.filter { $0.status == .waiting }.count }
    public var workingCount: Int { sessions.filter { $0.status == .working }.count }
    public var idleCount: Int { sessions.filter { $0.status == .idle }.count }
    public var unknownCount: Int { sessions.filter { $0.status == .unknown }.count }
    public var workspacePaths: [String] { Array(Set(sessions.map(\.workspacePath))).sorted() }
    public var sources: [SourceLiveActivity] {
        Dictionary(grouping: sessions, by: \.sourceID).map { sourceID, records in
            SourceLiveActivity(sourceID: sourceID, sessions: records)
        }.sorted { $0.sourceID < $1.sourceID }
    }

    /// Repeated copies of a source/session/PID are one process report; distinct
    /// PIDs remain distinct. The newest copy wins. Equally recent conflicting
    /// statuses become unknown; conflicting project/checkout claims are omitted.
    public static func group(_ sessions: [LiveAgentSession]) -> [String: ProjectLiveActivity] {
        var candidates: [LiveIdentity: [LiveAgentSession]] = [:]
        for session in sessions {
            guard let project = liveCanonicalPath(session.projectPath),
                  let workspace = liveCanonicalPath(session.workspacePath) else { continue }
            let normalized = session.relocated(projectPath: project, workspacePath: workspace)
            let key = LiveIdentity(sourceID: session.sourceID, sessionID: session.sessionID, pid: session.pid)
            candidates[key, default: []].append(normalized)
        }
        let deduplicated = candidates.values.compactMap { copies -> LiveAgentSession? in
            guard let newestDate = copies.map(\.updatedAt).max() else { return nil }
            let newest = copies.filter { $0.updatedAt == newestDate }
            guard let record = newest.first,
                  Set(newest.map(\.projectPath)).count == 1,
                  Set(newest.map(\.workspacePath)).count == 1 else { return nil }
            let status = Set(newest.map { $0.status.rawValue }).count == 1 ? record.status : .unknown
            // Like status: equally recent copies that disagree keep no details,
            // so the result never depends on input order.
            let details = Set(newest.map(\.details)).count == 1 ? record.details : LiveSessionDetails.none
            return LiveAgentSession(sourceID: record.sourceID, projectPath: record.projectPath,
                workspacePath: record.workspacePath, sessionID: record.sessionID,
                status: status, updatedAt: newestDate, pid: record.pid, details: details)
        }
        return Dictionary(grouping: deduplicated, by: \.projectPath).mapValues { records in
            ProjectLiveActivity(projectPath: records[0].projectPath, sessions: records.sorted(by: liveSessionOrder))
        }
    }
}

/// Joins the current live snapshot to historical projects without manufacturing
/// history for live-only projects or a live state for historical-only projects.
public struct ProjectOverview: Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let history: ProjectSummary?
    public let live: ProjectLiveActivity?
    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
    public var sourceIDs: [String] {
        Array(Set((history?.activities.map(\.sourceID) ?? []) + (live?.sources.map(\.sourceID) ?? []))).sorted()
    }
    public var isShared: Bool { sourceIDs.count > 1 }

    /// `sessionProjects` re-homes a live session whose history showed where its
    /// edits landed. `relocate` maps a live project path through learned earlier
    /// locations, for sessions still reporting a folder that has since moved.
    public static func merge(projects: [ProjectSummary], sessions: [LiveAgentSession],
                             sessionProjects: [SessionProjectAssociation] = [],
                             relocate: ((String) -> String)? = nil) -> [ProjectOverview] {
        // Association changes only identity. Status, PID, report time, details
        // and recorded workspace still come from the independent live reader.
        let associated = sessions.map { session -> LiveAgentSession in
            let reported = [liveCanonicalPath(session.workspacePath), liveCanonicalPath(session.projectPath)]
            let candidates = sessionProjects.filter {
                $0.sourceID == session.sourceID && $0.sessionID == session.sessionID
                    && reported.contains(liveCanonicalPath($0.recordedWorkspace))
            }
            let paths = Set(candidates.compactMap { liveCanonicalPath($0.projectPath) })
            guard paths.count == 1, let path = paths.first,
                  projects.contains(where: { liveCanonicalPath($0.path) == path
                      && $0.activities.contains(where: { $0.sourceID == session.sourceID }) }) else {
                guard let relocate, candidates.isEmpty else { return session }
                let moved = relocate(session.projectPath)
                guard moved != session.projectPath else { return session }
                return session.relocated(projectPath: moved, workspacePath: relocate(session.workspacePath))
            }
            return session.relocated(projectPath: path, workspacePath: session.workspacePath)
        }
        let live = ProjectLiveActivity.group(associated)
        var historical: [String: [ProjectSummary]] = [:]
        for project in projects {
            guard let path = liveCanonicalPath(project.path) else { continue }
            historical[path, default: []].append(project)
        }
        var joined: [ProjectOverview] = []
        for path in Set(historical.keys).union(live.keys) {
            let history: ProjectSummary?
            if let snapshots = historical[path] {
                // Input summaries are snapshots, not additional session events.
                // Canonical aliases/repeated copies must not multiply statistics.
                var bySource: [String: ProjectActivity] = [:]
                var editLeaders: [String: ProjectActivity] = [:]
                for var activity in snapshots.flatMap(\.activities) {
                    activity.projectPath = path
                    if activity.latestEdit != nil {
                        if let current = editLeaders[activity.sourceID] {
                            if preferEdit(activity, over: current) { editLeaders[activity.sourceID] = activity }
                        } else {
                            editLeaders[activity.sourceID] = activity
                        }
                    }
                    if let current = bySource[activity.sourceID], !preferHistory(activity, over: current) { continue }
                    bySource[activity.sourceID] = activity
                }
                // Activity/history snapshots and edit evidence have independent
                // leaders. A newer metadata-only snapshot must not erase an edit.
                for (sourceID, leader) in editLeaders {
                    bySource[sourceID]?.latestEdit = leader.latestEdit
                    bySource[sourceID]?.latestEditWorkspacePath = leader.latestEditWorkspacePath ?? leader.workspacePath
                }
                history = ProjectSummary.merge(Array(bySource.values)).first
                    ?? ProjectSummary(path: path, activities: [])
            } else {
                history = nil
            }
            joined.append(ProjectOverview(path: path, history: history, live: live[path]))
        }
        return joined.sorted {
            let leftPriority = overviewAttentionRank($0), rightPriority = overviewAttentionRank($1)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            let leftDate = overviewSortDate($0), rightDate = overviewSortDate($1)
            if leftDate != rightDate { return leftDate > rightDate }
            return $0.path < $1.path
        }
    }
}

private struct LiveIdentity: Hashable {
    let sourceID: String
    let sessionID: String
    let pid: Int32
}

private func liveCanonicalPath(_ path: String) -> String? {
    let expanded = (path as NSString).expandingTildeInPath
    guard !expanded.isEmpty, expanded.hasPrefix("/") else { return nil }
    return canonicalPath(expanded)
}

private func liveSessionOrder(_ left: LiveAgentSession, _ right: LiveAgentSession) -> Bool {
    func rank(_ value: LiveStatus) -> Int {
        switch value {
        case .waiting: return 0
        case .working: return 1
        case .idle: return 2
        case .unknown: return 3
        }
    }
    if rank(left.status) != rank(right.status) { return rank(left.status) < rank(right.status) }
    if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
    return left.id < right.id
}

private func overviewSortDate(_ project: ProjectOverview) -> Date {
    // Avoid ProjectSummary.sortDate's nonempty-activity precondition for empty data.
    project.history?.activities.map(\.latestActivity).max()
        ?? project.live?.sessions.map(\.updatedAt).max() ?? .distantPast
}

private func overviewAttentionRank(_ project: ProjectOverview) -> Int {
    if (project.live?.waitingCount ?? 0) > 0 { return 0 }
    if (project.live?.workingCount ?? 0) > 0 { return 1 }
    return 2
}

private func preferHistory(_ candidate: ProjectActivity, over current: ProjectActivity) -> Bool {
    if candidate.latestActivity != current.latestActivity { return candidate.latestActivity > current.latestActivity }
    if candidate.latestEdit != current.latestEdit { return (candidate.latestEdit ?? .distantPast) > (current.latestEdit ?? .distantPast) }
    let candidateEdits = candidate.history.reduce(0) { $0 + $1.editCount }
    let currentEdits = current.history.reduce(0) { $0 + $1.editCount }
    if candidateEdits != currentEdits { return candidateEdits > currentEdits }
    if candidate.sessionCount != current.sessionCount { return candidate.sessionCount > current.sessionCount }
    return (candidate.workspacePath ?? "") < (current.workspacePath ?? "")
}

private func preferEdit(_ candidate: ProjectActivity, over current: ProjectActivity) -> Bool {
    if candidate.latestEdit != current.latestEdit { return (candidate.latestEdit ?? .distantPast) > (current.latestEdit ?? .distantPast) }
    return (candidate.latestEditWorkspacePath ?? candidate.workspacePath ?? "")
        < (current.latestEditWorkspacePath ?? current.workspacePath ?? "")
}
