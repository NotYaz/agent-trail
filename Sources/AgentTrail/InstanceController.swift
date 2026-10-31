import AppKit
import Darwin
import Foundation
import AgentTrailCore

/// Resolves already-running instances only. It never launches, quits, or restarts an app.
@MainActor
final class InstanceController {
    private struct Snapshot {
        let application: NSRunningApplication
        let launchDate: Date
        let executablePath: String
        let identity: ProcessIdentity
    }

    private struct Scan {
        var matches: [Snapshot] = []
        var unreadableCount = 0
        var runningCount = 0
    }

    static func runningInstances(sources: [AgentSource]) -> [String: pid_t] {
        var result: [String: pid_t] = [:]
        for source in sources {
            let scan = scan(source: source)
            if scan.matches.count == 1 {
                result[source.id] = scan.matches[0].application.processIdentifier
            }
        }
        return result
    }

    /// Call only in response to an explicit user action. A nil result means the
    /// system accepted an activation request; macOS may still decline to focus it.
    static func focus(source: AgentSource) -> String? {
        guard !source.bundleIdentifier.isEmpty else {
            return "\(source.name) keeps local history only. It has no desktop app for Agent Trail to focus."
        }
        let scan = scan(source: source)
        guard scan.matches.count == 1 else {
            if scan.matches.count > 1 {
                return "More than one running app matches \(source.name). AgentTrail cannot safely choose an instance."
            }
            if scan.unreadableCount > 0 {
                return "AgentTrail could not read the launch details for \(source.name). It cannot safely identify the correct instance."
            }
            if scan.runningCount > 0 {
                return "The app is running, but no instance matches the profile for \(source.name)."
            }
            return "\(source.name) is not running. Open it normally, then try again."
        }

        let snapshot = scan.matches[0]
        let pid = snapshot.application.processIdentifier
        // Re-read both app identity and arguments immediately before activation.
        // This also guards against a closed instance's PID being reused.
        guard let application = NSRunningApplication(processIdentifier: pid),
              !application.isTerminated,
              application.bundleIdentifier == source.bundleIdentifier,
              application.launchDate == snapshot.launchDate,
              let executable = application.executableURL?.path,
              canonicalPath(executable) == snapshot.executablePath,
              let identity = processIdentity(pid: pid),
              canonicalPath(identity.executablePath) == snapshot.executablePath,
              identity.matches(source: source) else {
            return "\(source.name) changed or closed before it could be focused. Refresh and try again."
        }
        NSApp.yieldActivation(to: application)
        guard application.activate(from: NSRunningApplication.current,
                                   options: [.activateAllWindows]) else {
            return "macOS did not accept the request to focus \(source.name)."
        }
        return nil
    }

    private static func scan(source: AgentSource) -> Scan {
        guard !source.bundleIdentifier.isEmpty else { return Scan() }
        var scan = Scan()
        for application in NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleIdentifier)
            where !application.isTerminated {
            scan.runningCount += 1
            guard let launchDate = application.launchDate,
                  let executable = application.executableURL?.path,
                  let identity = processIdentity(pid: application.processIdentifier),
                  canonicalPath(identity.executablePath) == canonicalPath(executable) else {
                scan.unreadableCount += 1
                continue
            }
            guard identity.matches(source: source) else { continue }
            scan.matches.append(Snapshot(application: application, launchDate: launchDate,
                                         executablePath: canonicalPath(executable), identity: identity))
        }
        return scan
    }

    private static func processIdentity(pid: pid_t) -> ProcessIdentity? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size, size <= 16 * 1_024 * 1_024 else { return nil }
        var data = Data(count: size)
        let status = data.withUnsafeMutableBytes { buffer in
            sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0)
        }
        guard status == 0, size <= data.count else { return nil }
        data.count = size
        return ProcessIdentity.parseKernelArguments(data)
    }
}
