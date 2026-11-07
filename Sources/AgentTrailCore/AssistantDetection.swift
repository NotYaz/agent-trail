import Foundation

/// Assistants whose session stores exist on this Mac. Only fixed folders are
/// checked, with lstat and at most one folder listing per assistant; nothing in
/// privacy-protected folders is read, and nothing is written.
public enum AssistantDetection {
    /// A suggested profile for each assistant that has local sessions but no
    /// profile reading it, in `AssistantKind.allCases` order.
    public static func suggestions(configured: [AgentSource], home: String = NSHomeDirectory()) -> [AgentSource] {
        let covered = Set(configured.map(\.assistant))
        let folders = Set(configured.map { canonicalPath($0.configDirectory) })
        var ids = Set(configured.map(\.id))
        return AssistantKind.allCases.compactMap { kind in
            guard !covered.contains(kind), hasSessions(kind, home: home) else { return nil }
            let descriptor = kind.descriptor
            let folder = descriptor.defaultHome(home: "~")
            guard !folders.contains(canonicalPath(folder)) else { return nil }
            var id = kind.rawValue
            var number = 2
            while ids.contains(id) {
                id = "\(kind.rawValue)-\(number)"
                number += 1
            }
            ids.insert(id)
            return AgentSource(id: id, name: descriptor.displayName, configDirectory: folder, assistant: kind)
        }
    }

    /// True when the assistant's default stores hold at least one session.
    public static func hasSessions(_ kind: AssistantKind, home: String = NSHomeDirectory()) -> Bool {
        switch kind {
        case .claude: return nonEmptyFolder("\(home)/.claude/projects")
        case .codex: return nonEmptyFolder("\(home)/.codex/sessions")
        case .grok: return nonEmptyFolder("\(home)/.grok/sessions")
        case .copilot:
            if nonEmptyFolder("\(home)/.copilot/session-state") { return true }
            let storage = "\(home)/Library/Application Support/Code/User/workspaceStorage"
            guard FileStat.of(storage)?.kind == .directory,
                  let workspaces = try? FileManager.default.contentsOfDirectory(atPath: storage) else { return false }
            return workspaces.contains { nonEmptyFolder("\(storage)/\($0)/chatSessions") }
        case .opencode:
            // OpenCode 1.2 and later keep every session in this one database.
            guard let stat = FileStat.of("\(home)/.local/share/opencode/opencode.db") else { return false }
            return stat.kind == .regular && stat.size > 0
        case .cursor:
            if nonEmptyFolder("\(home)/.cursor/chats") { return true }
            return FileStat.of("\(home)/Library/Application Support/Cursor/User/globalStorage/state.vscdb")?.kind == .regular
        case .gemini:
            // ~/.cache/.gemini is where the CLI writes under the macOS sandbox (Seatbelt).
            return ["\(home)/.gemini/tmp", "\(home)/.cache/.gemini/tmp"].contains { tmp in
                guard FileStat.of(tmp)?.kind == .directory,
                      let folders = try? FileManager.default.contentsOfDirectory(atPath: tmp) else { return false }
                return folders.contains { nonEmptyFolder("\(tmp)/\($0)/chats") }
            }
        case .qwen:
            let projects = "\(home)/.qwen/projects"
            guard FileStat.of(projects)?.kind == .directory,
                  let folders = try? FileManager.default.contentsOfDirectory(atPath: projects) else { return false }
            return folders.contains { nonEmptyFolder("\(projects)/\($0)/chats") }
        }
    }

    private static func nonEmptyFolder(_ path: String) -> Bool {
        guard FileStat.of(path)?.kind == .directory,
              let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return false }
        return names.contains { !$0.hasPrefix(".") }
    }
}
