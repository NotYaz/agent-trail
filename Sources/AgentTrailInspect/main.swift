import Foundation
import AgentTrailCore

// Read-only diagnostics. Cache writes, if requested, go only to the supplied path.
let arguments = Array(CommandLine.arguments.dropFirst())
let cacheIndex = arguments.firstIndex(of: "--cache")
let cacheURL: URL? = cacheIndex.flatMap { index in
    guard index + 1 < arguments.count else { return nil }
    return URL(fileURLWithPath: arguments[index + 1])
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
let provider = ClaudeActivityProvider(cacheURL: cacheURL)
let sources = try ProfileConfiguration.load(from: profileURL).sources
let started = Date()
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
    "projects": records
]
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([10]))
