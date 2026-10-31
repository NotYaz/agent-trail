import Foundation
import AgentTrailCore

// Read-only diagnostics. Cache writes, if requested, go only to the supplied path.
let arguments = Array(CommandLine.arguments.dropFirst())
let cacheIndex = arguments.firstIndex(of: "--cache")
let cacheURL: URL? = cacheIndex.flatMap { index in
    guard index + 1 < arguments.count else { return nil }
    return URL(fileURLWithPath: arguments[index + 1])
}
let locationsIndex = arguments.firstIndex(of: "--locations")
if let index = locationsIndex, index + 1 >= arguments.count || arguments[index + 1].hasPrefix("--") {
    fputs("--locations requires a project-locations.json path\n", stderr)
    exit(2)
}
let profileIndex = arguments.firstIndex(of: "--profiles")
let profileURL = profileIndex.flatMap { index -> URL? in
    guard index + 1 < arguments.count else { return nil }
    return URL(fileURLWithPath: arguments[index + 1])
} ?? ProfileConfiguration.defaultURL
if let index = profileIndex, index + 1 >= arguments.count || arguments[index + 1].hasPrefix("--") {
    fputs("--profiles requires a profiles.json path\n", stderr)
    exit(2)
}
if let index = cacheIndex, index + 1 >= arguments.count || arguments[index + 1].hasPrefix("--") {
    fputs("--cache requires a cache file path\n", stderr)
    exit(2)
}
let sources = try ProfileConfiguration.load(from: profileURL).sources
let started = Date()
if arguments.contains("--live") {
    let snapshot = CompositeLiveActivityProvider().scan(sources: sources)
    let report: [String: Any] = [
        "elapsedSeconds": Date().timeIntervalSince(started),
        "notices": snapshot.notices,
        "sessions": snapshot.sessions.map { session -> [String: Any] in
            ["sourceID": session.sourceID, "project": session.projectPath,
             "workspace": session.workspacePath, "sessionID": session.sessionID,
             "status": session.status.rawValue, "pid": session.pid,
             "updatedAt": ISO8601DateFormatter().string(from: session.updatedAt)]
        }
    ]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([10]))
    exit(0)
}
// Learned project locations are read but never written by diagnostics.
let locationsURL = locationsIndex.map { URL(fileURLWithPath: arguments[$0 + 1]) } ?? ProjectLocationRegistry.defaultURL
let savedLocations: ProjectLocationRegistry
do {
    savedLocations = try ProjectLocationRegistry.load(from: locationsURL)
} catch {
    fputs("Project locations at \(locationsURL.path) could not be read: \(error.localizedDescription)\n", stderr)
    savedLocations = ProjectLocationRegistry()
}
let provider = CompositeActivityProvider(cacheURL: cacheURL, projectLocations: savedLocations)
let result = arguments.contains("--metadata-only")
    ? provider.metadata(sources: sources)
    : provider.scan(sources: sources)
let formatter = ISO8601DateFormatter()
let records: [[String: Any]] = result.projects.map { project in
    var item: [String: Any] = [
        "project": project.path,
        "shared": project.isShared,
        "sourceIDs": project.activities.map(\.sourceID),
        "latestActivity": formatter.string(from: project.latestActivity.latestActivity),
        "latestActivitySource": project.latestActivity.sourceID
    ]
    item["recordedEditCount"] = project.recordedEditCount
    item["workspaces"] = Array(Set(project.activities.compactMap(\.workspacePath))).sorted()
    item["folderAvailable"] = !result.unavailableProjects.contains(project.path)
    item["sessionCount"] = project.sessionCount
    item["dailyHistoryUTC"] = project.history.map {
        ["day": formatter.string(from: $0.day), "edits": $0.editCount, "sessions": $0.sessionCount] as [String: Any]
    }
    if let edit = project.latestEdit, let date = edit.latestEdit {
        item["latestRecordedEdit"] = formatter.string(from: date)
        item["latestEditSource"] = edit.sourceID
        item["latestEditWorkspace"] = edit.latestEditWorkspacePath ?? project.path
    }
    return item
}
let report: [String: Any] = [
    "projectCount": records.count,
    "sharedCount": result.projects.filter(\.isShared).count,
    "elapsedSeconds": Date().timeIntervalSince(started),
    "notices": result.notices,
    "projects": records,
    "sessionProjects": result.sessionProjects.map {
        ["sourceID": $0.sourceID, "sessionID": $0.sessionID, "recordedWorkspace": $0.recordedWorkspace, "project": $0.projectPath]
    },
    "projectLocations": result.projectLocations.locations.map { location -> [String: Any] in
        ["currentPath": location.currentPath, "present": location.isPresent,
         "previousLocations": location.previousLocations.map {
             ["path": $0.path, "origin": $0.origin.rawValue, "observedAt": formatter.string(from: $0.observedAt),
              "shadowed": $0.shadowedSince != nil] as [String: Any]
         }]
    },
    "missingFolders": result.missingFolders.map {
        ["sourceID": $0.sourceID, "project": $0.projectPath, "path": $0.path, "edits": $0.editCount] as [String: Any]
    }
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([10]))
