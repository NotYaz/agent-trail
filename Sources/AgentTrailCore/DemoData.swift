import Foundation

/// Synthetic presentation data. Never opens a provider, process, or cache.
public enum DemoData {
    /// Demo projects belong to the two Claude profiles. Codex and Grok stay out of the sample.
    public static var sources: [AgentSource] { Array(AgentSource.defaults(home: "/Demo").prefix(2)) }

    public static func result(now: Date = Date()) -> ScanResult {
        let main = "claude-primary", second = "claude-second"
        let orbit = "/Demo/Projects/orbit", atlas = "/Demo/Projects/atlas", notes = "/Demo/Projects/field-notes"
        var records = [
            ProjectActivity(sourceID: second, projectPath: orbit, latestActivity: now.addingTimeInterval(-35), latestEdit: now.addingTimeInterval(-120), workspacePath: orbit + "/.claude/worktrees/navigation", latestEditWorkspacePath: orbit + "/.claude/worktrees/navigation"),
            ProjectActivity(sourceID: main, projectPath: orbit, latestActivity: now.addingTimeInterval(-420), latestEdit: now.addingTimeInterval(-540), workspacePath: orbit),
            ProjectActivity(sourceID: main, projectPath: atlas, latestActivity: now.addingTimeInterval(-240), latestEdit: now.addingTimeInterval(-900), workspacePath: atlas),
            ProjectActivity(sourceID: second, projectPath: atlas, latestActivity: now.addingTimeInterval(-600), latestEdit: now.addingTimeInterval(-1_800), workspacePath: atlas),
            ProjectActivity(sourceID: main, projectPath: notes, latestActivity: now.addingTimeInterval(-3_600), latestEdit: now.addingTimeInterval(-4_800), workspacePath: notes)
        ]
        for index in records.indices {
            let history = (0..<28).map { ago -> ActivityDay in
                let value = (ago * 7 + index * 11) % 13
                let edits = (ago + index) % 6 == 0 ? 0 : value % 9 + 1
                return ActivityDay(day: now.addingTimeInterval(-Double(ago) * 86_400),
                    editCount: edits, sessionCount: edits == 0 ? 0 : value % 3 + 1)
            }
            records[index].history = history
            records[index].sessionCount = history.reduce(0) { $0 + $1.sessionCount }
        }
        return ScanResult(projects: ProjectSummary.merge(records), scannedAt: now)
    }
}
