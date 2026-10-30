import Foundation

/// Synthetic presentation data. Never opens a provider, process, or cache.
public enum DemoData {
    public static var sources: [AgentSource] { AgentSource.defaults(home: "/Demo") }

    public static func result(now: Date = Date()) -> ScanResult {
        let main = "claude-primary", second = "claude-second"
        let orbit = "/Demo/Projects/orbit", atlas = "/Demo/Projects/atlas", notes = "/Demo/Projects/field-notes"
        let records = [
            ProjectActivity(sourceID: second, projectPath: orbit, latestActivity: now.addingTimeInterval(-35), latestEdit: now.addingTimeInterval(-120), workspacePath: orbit + "/.claude/worktrees/navigation", latestEditWorkspacePath: orbit + "/.claude/worktrees/navigation"),
            ProjectActivity(sourceID: main, projectPath: orbit, latestActivity: now.addingTimeInterval(-420), latestEdit: now.addingTimeInterval(-540), workspacePath: orbit),
            ProjectActivity(sourceID: main, projectPath: atlas, latestActivity: now.addingTimeInterval(-240), latestEdit: now.addingTimeInterval(-900), workspacePath: atlas),
            ProjectActivity(sourceID: second, projectPath: atlas, latestActivity: now.addingTimeInterval(-600), latestEdit: now.addingTimeInterval(-1_800), workspacePath: atlas),
            ProjectActivity(sourceID: main, projectPath: notes, latestActivity: now.addingTimeInterval(-3_600), latestEdit: now.addingTimeInterval(-4_800), workspacePath: notes)
        ]
        return ScanResult(projects: ProjectSummary.merge(records), scannedAt: now)
    }
}
