import Foundation

/// Which running instance of an app receives a link opened with that app.
/// With several instances of one bundle, such as Claude · Main and Claude ·
/// Second, LaunchServices hands every link to the instance launched first,
/// whichever is in front (seen on macOS 15 with Claude), and to the next oldest
/// once that one quits (seen with a two-instance test app). A link meant for a
/// later instance therefore reaches the wrong one: Claude then shows its Code
/// home, because the session belongs to another instance.
public enum LinkRecipient {
    public struct Instance: Equatable, Sendable {
        public let pid: Int32
        public let launchDate: Date?

        public init(pid: Int32, launchDate: Date?) {
            self.pid = pid
            self.launchDate = launchDate
        }
    }

    /// The instance launched first. Nil without instances, or when the order is
    /// unknown: a launch date is missing, or two instances share the earliest one.
    public static func pid(among instances: [Instance]) -> Int32? {
        var earliest: (pid: Int32, launchDate: Date)?
        var tied = false
        for instance in instances {
            guard let launchDate = instance.launchDate else { return nil }
            if let current = earliest, launchDate >= current.launchDate {
                if launchDate == current.launchDate { tied = true }
                continue
            }
            earliest = (instance.pid, launchDate)
            tied = false
        }
        return tied ? nil : earliest?.pid
    }
}
