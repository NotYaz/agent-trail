import Foundation

/// How a session's working folder relates to the project it is counted on.
/// A worktree is a separate checkout of the project; a subfolder is inside it;
/// an outside folder is where an assistant was started before its edits
/// landed in the project.
enum WorkspaceLabel: Equatable {
    case worktree(name: String)
    case subfolder(relative: String)
    case launchedFrom(path: String)

    static func make(workspace: String?, project: String) -> WorkspaceLabel? {
        guard let workspace, !workspace.isEmpty, workspace != project else { return nil }
        let prefix = project == "/" ? "/" : project + "/"
        if workspace.hasPrefix(prefix) {
            let relative = String(workspace.dropFirst(prefix.count))
            if let name = worktreeName(relative) { return .worktree(name: name) }
            return .subfolder(relative: relative)
        }
        // A folder outside the project is where the session was started, even
        // if it is some other project's worktree.
        return .launchedFrom(path: workspace)
    }

    /// `.claude/worktrees/<name>`, `.codex/worktrees/<name>`, or
    /// `.worktrees/<name>` inside the project; the name follows the marker.
    private static func worktreeName(_ relative: String) -> String? {
        let components = relative.split(separator: "/").map(String.init)
        for index in components.indices {
            let isMarker = components[index] == ".worktrees"
                || (components[index] == "worktrees" && index > 0 && [".claude", ".codex"].contains(components[index - 1]))
            if isMarker, index + 1 < components.count { return components[index + 1] }
        }
        return nil
    }

    /// Short title for small session rows.
    var shortTitle: String {
        switch self {
        case .worktree: return "Worktree"
        case .subfolder: return "Subfolder"
        case .launchedFrom: return "Launched outside"
        }
    }

    func title(abbreviate: (String) -> String) -> String {
        switch self {
        case .worktree(let name): return "Worktree · \(name)"
        case .subfolder(let relative): return "Launched in · \(relative)"
        case .launchedFrom(let path): return "Launched from · \(abbreviate(path))"
        }
    }

    var symbol: String {
        switch self {
        case .worktree: return "arrow.triangle.branch"
        case .subfolder: return "arrow.turn.right.down"
        case .launchedFrom: return "arrow.turn.down.right"
        }
    }

    func help(workspace: String, project: String) -> String {
        switch self {
        case .worktree:
            return "This edit was made in a separate worktree: \(workspace)\nProject origin: \(project)"
        case .subfolder:
            return "The session was started inside the project, in \(workspace)."
        case .launchedFrom:
            return "The session was started outside the project folder, in \(workspace). Its confirmed edits landed in this checkout, so they count here.\nProject: \(project)"
        }
    }
}
