import Foundation

/// Session counts across every project in the current live snapshot. Needs
/// input and working stay separate, and a project without a live report is
/// left out entirely, never counted as idle.
public struct LiveSummary: Equatable, Sendable {
    public var waiting: Int
    public var working: Int
    public var idle: Int
    public var unknown: Int
    public var reportingProjects: Int
    public var waitingProjects: Int
    public var workingProjects: Int

    public init(waiting: Int = 0, working: Int = 0, idle: Int = 0, unknown: Int = 0,
                reportingProjects: Int = 0, waitingProjects: Int = 0, workingProjects: Int = 0) {
        self.waiting = waiting
        self.working = working
        self.idle = idle
        self.unknown = unknown
        self.reportingProjects = reportingProjects
        self.waitingProjects = waitingProjects
        self.workingProjects = workingProjects
    }

    public var sessions: Int { waiting + working + idle + unknown }

    public static let empty = LiveSummary()

    public static func make(_ overviews: [ProjectOverview]) -> LiveSummary {
        var summary = LiveSummary()
        for live in overviews.compactMap(\.live) {
            summary.reportingProjects += 1
            var waiting = 0, working = 0
            for session in live.sessions {
                switch session.status {
                case .waiting: waiting += 1
                case .working: working += 1
                case .idle: summary.idle += 1
                case .unknown: summary.unknown += 1
                }
            }
            summary.waiting += waiting
            summary.working += working
            if waiting > 0 { summary.waitingProjects += 1 }
            if working > 0 { summary.workingProjects += 1 }
        }
        return summary
    }
}
