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
// `--map-summary SNAPSHOT.json`: the Map built from a saved snapshot, as text.
if let index = arguments.firstIndex(of: "--map-summary") {
    guard index + 1 < arguments.count else {
        fputs("--map-summary requires a snapshot path\n", stderr)
        exit(2)
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let snapshot = try decoder.decode(MapSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: arguments[index + 1])))
    let rangeIndex = arguments.firstIndex(of: "--range")
    let range = rangeIndex.flatMap { index in
        MapRange.allCases.first { index + 1 < arguments.count && $0.rawValue.lowercased() == arguments[index + 1].lowercased() }
    } ?? .week
    let map = ProjectMap.build(snapshot, range: range, collapseAbove: arguments.contains("--all-branches") ? nil : 14)
    let clock = DateFormatter()
    clock.dateFormat = "MM-dd HH:mm"
    func position(_ date: Date) -> String { String(format: "%.3f", map.axis.position(of: date)) }
    print("\(range.title): edits \(map.editCount) sessions \(map.sessionCount) cloud \(map.cloudSessionCount) rows \(map.rowCount) gaps \(map.axis.gaps.count) outside \(map.outsideEdits) merges \(map.mergeCount) quiet \(map.quietMergeCount)")
    for lane in map.lanes {
        let merge = lane.merge.map { " merged \(clock.string(from: $0.date)) #\($0.pullRequest.map(String.init) ?? "-")" } ?? ""
        let parent = lane.parentID.map { $0 == map.trunkID ? "" : " ⟵ \($0.dropFirst(7))" } ?? ""
        let strand = lane.bundle.map { " strand \(lane.strand) of \(map.bundle($0)?.title ?? $0)" } ?? ""
        print("row \(lane.row) \(lane.kind) \(lane.title) \(clock.string(from: lane.start))…\(clock.string(from: lane.end)) [\(position(lane.start))–\(position(lane.end))] edits \(lane.editCount)\(merge)\(lane.deleted ? " deleted" : "")\(parent)\(lane.isStream ? " members \(lane.members.count)" : "")\(strand)")
    }
    for bundle in map.bundles {
        print("bundle \(bundle.title) · \(bundle.laneIDs.count) strands under \(bundle.parentID)")
    }
    for span in map.spans {
        print("  \(span.sourceID) \(span.sessionID.prefix(10)) \(span.laneID) \(clock.string(from: span.start))…\(clock.string(from: span.end)) edits \(span.editCount) (\(span.delegated.count) delegated) slot \(span.slot)\(span.spawnedThreads > 0 ? " +\(span.spawnedThreads) threads" : "")\(span.live.map { " live \($0)" } ?? "")")
    }
    for marker in map.markers {
        print("  * \(marker.kind) \(marker.laneID) \(clock.string(from: marker.date)) \(marker.subject.prefix(50))\(marker.quietBranch.map { " quiet:\($0)" } ?? "")\(marker.cloudSession != nil ? " cloud" : "")")
    }
    exit(0)
}
let sources = try ProfileConfiguration.load(from: profileURL).sources
let started = Date()
if arguments.contains("--live") {
    let snapshot = CompositeLiveActivityProvider().scan(sources: sources)
    let report: [String: Any] = [
        "elapsedSeconds": Date().timeIntervalSince(started),
        "notices": snapshot.notices,
        "sessions": snapshot.sessions.map { session -> [String: Any] in
            var entry: [String: Any] = ["sourceID": session.sourceID, "project": session.projectPath,
             "workspace": session.workspacePath, "sessionID": session.sessionID,
             "status": session.status.rawValue, "pid": session.pid,
             "updatedAt": ISO8601DateFormatter().string(from: session.updatedAt)]
            if let since = session.details.backgroundSince {
                entry["backgroundSince"] = ISO8601DateFormatter().string(from: since)
            }
            if session.details.startedInTerminal {
                entry["startedInTerminal"] = true
                if let host = session.details.hostBundleID { entry["host"] = host }
            }
            return entry
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
// `--map PATH`: one project's session trails, Git history and live sessions,
// as the snapshot `AgentTrail --render-map` draws.
if let index = arguments.firstIndex(of: "--map") {
    guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
        fputs("--map requires a project path\n", stderr)
        exit(2)
    }
    let project = canonicalPath(arguments[index + 1])
    let live = CompositeLiveActivityProvider().scan(sources: sources).sessions
        .map { MapSnapshot.LiveMark(sourceID: $0.sourceID, sessionID: $0.sessionID, status: $0.status.rawValue) }
    let trails = MapSnapshot.trails(result.sessionTrails, for: project)
    // A day of history before the first session, local or cloud, shows where its branches started.
    let first = (trails.map(\.createdAt) + [GitHistoryReader.firstCloudCommit(checkout: project)].compactMap { $0 }).min()
    let since = (first ?? Date()).addingTimeInterval(-86_400)
    let snapshot = MapSnapshot(projectPath: project, takenAt: Date(), sources: sources, trails: trails,
                               git: GitHistoryReader.read(checkout: project, since: since), live: live)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(snapshot))
    FileHandle.standardOutput.write(Data([10]))
    exit(0)
}
let formatter = ISO8601DateFormatter()
let activityCalendar = ActivityCalendar.current
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
    // Local activity days come from the raw moments, so they never inherit UTC boundaries.
    var localEdits: [DayKey: Int] = [:], localSessions: [DayKey: Int] = [:]
    for moment in project.activities.flatMap(\.editMoments) { localEdits[activityCalendar.day(of: moment.date), default: 0] += 1 }
    for start in project.activities.flatMap(\.sessionStarts) { localSessions[activityCalendar.day(of: start), default: 0] += 1 }
    item["localDays"] = Set(localEdits.keys).union(localSessions.keys).sorted().map { day -> [String: Any] in
        ["day": String(format: "%04ld-%02ld-%02ld", day.year, day.month, day.day),
         "edits": localEdits[day] ?? 0, "sessions": localSessions[day] ?? 0]
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
    "dayBoundary": String(format: "%02ld:00 local", activityCalendar.rolloverHour),
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
