import Foundation

/// One assistant session's recorded evidence, exactly as its logs state it.
/// Paths are lexical (symbolic links unresolved); policy is applied only when
/// folding, so caches never depend on folder layout or learned locations.
struct HistorySession {
    let sourceID: String
    let sessionID: String
    /// The folder the assistant was started in.
    let recordedWorkspace: String
    /// Folders the assistant declared as its workspace, including the above.
    let roots: [String]
    let createdAt: Date
    let latestActivity: Date
    /// Confirmed edits. `workspace` is the assistant's working directory when
    /// the edit completed; `targetDirectories` are the targets' parent folders.
    var edits: [String: StoredEdit]
    /// The thread that spawned this one, when the assistant records it.
    var parentSessionID: String?
    /// False when copies of this session disagree about where it started.
    /// Such a session is never moved to another project.
    var canMove = true
}

/// Folds sessions into project activity. A confirmed edit counts for the Git
/// checkout it physically landed in. A session (its session count and live
/// status) belongs to the single checkout that received its edits; otherwise
/// it stays with the folder it was started in. Nothing is matched by name.
enum HistoryFold {
    struct Result {
        var activity: [ProjectActivity] = []
        var associations: [SessionProjectAssociation] = []
        var missingFolders: [MissingFolder] = []
    }

    private struct Attributed {
        let session: HistorySession
        /// Where the session was started, as a physical path.
        let launch: String
        /// The launch folder, or the checkout that contains it.
        let base: String
        let baseIsCheckout: Bool
        var edits: [(id: String, project: String, edit: StoredEdit)] = []
        var checkouts: Set<String> = []
        var missing: [String: Set<String>] = [:]
        var home: String
    }

    static func fold(_ sessions: [HistorySession], resolver: GitProjectResolver) -> Result {
        var attributed = sessions.map { attribute($0, resolver: resolver) }
        // A spawned thread that made no repository edits of its own works on
        // its parent's task: it joins the parent's checkout when both were
        // started in the same folder. Only one level, never a guess by name.
        let homes = Dictionary(attributed.map { ($0.session.sourceID + "\u{0}" + $0.session.sessionID, $0) },
                               uniquingKeysWith: { first, _ in first })
        for index in attributed.indices {
            let item = attributed[index]
            guard item.session.canMove, !item.baseIsCheckout, item.checkouts.isEmpty,
                  let parentID = item.session.parentSessionID,
                  let parent = homes[item.session.sourceID + "\u{0}" + parentID],
                  parent.base == item.base, parent.home != parent.base else { continue }
            attributed[index].home = parent.home
        }

        var result = Result()
        var edits: [String: (source: String, project: String, id: String, edit: StoredEdit, delegated: Bool)] = [:]
        var missing: [String: (sourceID: String, project: String, folder: String, edits: Int, directories: Set<String>)] = [:]
        for item in attributed {
            let session = item.session
            let isDelegated = session.parentSessionID != nil
            result.activity.append(ProjectActivity(sourceID: session.sourceID, projectPath: item.home,
                latestActivity: session.latestActivity, sessionCount: 1, workspacePath: item.launch,
                history: [ActivityDay(day: session.createdAt, sessionCount: 1)], sessionStarts: [session.createdAt]))
            if item.home != canonicalPath(session.recordedWorkspace) {
                result.associations.append(SessionProjectAssociation(sourceID: session.sourceID,
                    sessionID: session.sessionID, recordedWorkspace: session.recordedWorkspace, projectPath: item.home))
            }
            for entry in item.edits {
                let key = session.sourceID + "\u{0}" + entry.project + "\u{0}" + entry.id
                guard let old = edits[key] else {
                    edits[key] = (session.sourceID, entry.project, entry.id, entry.edit, isDelegated)
                    continue
                }
                // The same winner `earlier(than:)` keeps. A spawned thread's
                // identical copy of a parent edit stays the parent's.
                let incomingWins = entry.edit.date < old.edit.date
                    || (entry.edit.date == old.edit.date && entry.edit.workspace < old.edit.workspace)
                let identical = entry.edit.date == old.edit.date && entry.edit.workspace == old.edit.workspace
                let delegated = incomingWins ? isDelegated : (identical ? (old.delegated && isDelegated) : old.delegated)
                edits[key] = (session.sourceID, entry.project, entry.id, old.edit.earlier(than: entry.edit), delegated)
            }
            for (folder, directories) in item.missing {
                let key = session.sourceID + "\u{0}" + item.base + "\u{0}" + folder
                var record = missing[key] ?? (session.sourceID, item.base, folder, 0, [])
                record.directories.formUnion(directories)
                missing[key] = record
            }
        }
        let grouped = Dictionary(grouping: edits.values, by: { $0.source + "\u{0}" + $0.project })
        for records in grouped.values {
            guard let latest = records.max(by: { ($0.edit.date, $0.id) < ($1.edit.date, $1.id) }) else { continue }
            let days = Dictionary(grouping: records, by: { ActivityDay.start(of: $0.edit.date) })
                .map { ActivityDay(day: $0.key, editCount: $0.value.count) }
            let moments: [EditMoment] = records.map { EditMoment(date: $0.edit.date, delegated: $0.delegated) }
                .sorted(by: EditMoment.chronological)
            result.activity.append(ProjectActivity(sourceID: latest.source, projectPath: latest.project,
                latestActivity: latest.edit.date, latestEdit: latest.edit.date, sessionCount: 0,
                workspacePath: latest.edit.workspace, latestEditWorkspacePath: latest.edit.workspace, history: days,
                editMoments: moments))
        }
        // Count each missing folder's edits from the deduplicated set.
        for value in edits.values {
            for (key, record) in missing where record.sourceID == value.source && record.project == value.project
                && value.edit.targetDirectories.contains(where: { record.directories.contains($0) }) {
                missing[key]?.edits += 1
            }
        }
        result.missingFolders = missing.values.filter { $0.edits > 0 }.map {
            MissingFolder(sourceID: $0.sourceID, projectPath: $0.project, path: $0.folder, editCount: $0.edits,
                          sampleDirectories: Array($0.directories.sorted().prefix(32)))
        }.sorted { ($0.projectPath, $0.path, $0.sourceID) < ($1.projectPath, $1.path, $1.sourceID) }
        result.associations.sort { ($0.sourceID, $0.sessionID) < ($1.sourceID, $1.sessionID) }
        return result
    }

    private static func attribute(_ session: HistorySession, resolver: GitProjectResolver) -> Attributed {
        let launch = resolver.physical(session.recordedWorkspace, at: session.createdAt)
            ?? canonicalPath(session.recordedWorkspace)
        let enclosing = resolver.owner(of: launch)
        var item = Attributed(session: session, launch: launch, base: enclosing ?? launch,
                              baseIsCheckout: enclosing != nil, home: enclosing ?? launch)
        let roots = Array(Set(session.roots.compactMap { resolver.physical($0, at: session.createdAt) } + [launch]))
        for (id, edit) in session.edits.sorted(by: { $0.key < $1.key }) {
            // The working directory must be one the session declared.
            guard !edit.targetDirectories.isEmpty,
                  let cwd = resolver.physical(edit.workspace, at: edit.date),
                  roots.contains(where: { CheckoutPath.contains(root: $0, path: cwd) }) else { continue }
            let targets = edit.targetDirectories.compactMap { resolver.physical($0, at: edit.date) }
            guard targets.count == edit.targetDirectories.count else { continue }
            // Each target maps to the most specific declared root inside the
            // working directory; an operation spanning two of them is dropped.
            let workspaces = Set(targets.map { target in
                roots.filter { CheckoutPath.contains(root: cwd, path: $0) && CheckoutPath.contains(root: $0, path: target) }
                    .max { $0.count < $1.count } ?? cwd
            })
            guard workspaces.count == 1, let workspace = workspaces.first else { continue }
            let owners = targets.map { target -> String? in
                if item.baseIsCheckout, CheckoutPath.contains(root: item.base, path: target) { return item.base }
                return resolver.owner(of: target)
            }
            var stored = edit
            stored.workspace = workspace
            stored.targetDirectories = targets
            if let owner = owners.first ?? nil, owners.allSatisfy({ $0 == owner }) {
                item.edits.append((id, owner, stored))
                if owner != item.base { item.checkouts.insert(owner) }
            } else if targets.allSatisfy({ CheckoutPath.contains(root: cwd, path: $0) }) {
                // Files outside any single checkout but inside the working
                // directory stay with the folder the session was started in.
                item.edits.append((id, item.base, stored))
                if !item.baseIsCheckout {
                    for target in targets where !resolver.exists(target) {
                        if let folder = missingRoot(target, below: launch, resolver: resolver) {
                            item.missing[folder, default: []].insert(target)
                        }
                    }
                }
            }
            // Otherwise a target escaped both the working directory and every
            // checkout; the operation is not attributed to anything.
        }
        if session.canMove, !item.baseIsCheckout, item.checkouts.count == 1, let checkout = item.checkouts.first {
            item.home = checkout
        }
        return item
    }

    /// The topmost folder that no longer exists on the way to a target, when
    /// it sits below the launch folder. Its edits may belong to a moved project.
    private static func missingRoot(_ target: String, below launch: String, resolver: GitProjectResolver) -> String? {
        var current = target
        var topmostMissing: String?
        while current != launch, CheckoutPath.contains(root: launch, path: current), !resolver.exists(current) {
            topmostMissing = current
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current, !parent.isEmpty else { break }
            current = parent
        }
        return topmostMissing
    }
}
