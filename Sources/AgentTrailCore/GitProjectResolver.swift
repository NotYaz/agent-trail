import Foundation

/// A per-scan view of where recorded paths physically are and which Git
/// checkout contains them. It never searches children, compares repository
/// names, or runs Git; only ancestor `.git` metadata is read. Call `reset()`
/// before each scan so moved, created, or deleted folders are observed.
/// Linked worktrees deliberately retain their own checkout root.
final class GitProjectResolver {
    private enum CachedRepository {
        case checkout(String)
        case none

        var path: String? {
            if case let .checkout(path) = self { return path }
            return nil
        }
    }

    private enum Marker {
        case absent
        case valid
        case invalid
    }

    private let files = FileManager.default
    private let home: String
    private(set) var locations: ProjectLocationRegistry
    private var repositories: [String: CachedRepository] = [:]
    private var physicalPaths: [String: String] = [:]
    private var existence: [String: Bool] = [:]
    private var symbolicLinks: [String: Bool] = [:]
    /// Symbolic links met while resolving recorded paths: link path → target.
    private var linkTargets: [String: String] = [:]
    private var origins: [String: String] = [:]

    init(locations: ProjectLocationRegistry = .init(), homeDirectory: String = NSHomeDirectory()) {
        self.locations = locations
        home = canonicalPath(homeDirectory)
    }

    func reset() {
        repositories.removeAll(keepingCapacity: true)
        physicalPaths.removeAll(keepingCapacity: true)
        existence.removeAll(keepingCapacity: true)
        symbolicLinks.removeAll(keepingCapacity: true)
        linkTargets.removeAll(keepingCapacity: true)
        origins.removeAll(keepingCapacity: true)
    }

    func reset(locations: ProjectLocationRegistry) {
        self.locations = locations
        reset()
    }

    /// Where a recorded path is now: earlier locations are rewritten to their
    /// checkout's current path, then the longest existing prefix is resolved
    /// through symbolic links. Missing trailing components (deleted files,
    /// vanished folders) are kept as recorded, so containment checks compare
    /// like with like. `date` is when the path was recorded.
    func physical(_ raw: String, at date: Date? = nil) -> String? {
        guard raw.utf8.count <= 32_768, let lexical = ProjectLocationRegistry.lexicalPath(raw) else { return nil }
        let relocated = locations.rewrite(lexical, at: date)
        var result = resolvingExistingPrefix(relocated)
        // An earlier location is stored the way the folder was found, which can
        // differ from the recorded spelling when a parent folder is a link. Only
        // a path no earlier location matched is tried again: chaining a rewrite
        // would hand one swapped folder's history to the other.
        if relocated == lexical {
            let again = locations.rewrite(result, at: date)
            if again != result { result = resolvingExistingPrefix(again) }
        }
        return result
    }

    private func resolvingExistingPrefix(_ path: String) -> String {
        if let known = physicalPaths[path] { return known }
        var existing = path
        var missing: [String] = []
        while existing != "/", !exists(existing), missing.count < 1_024 {
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
            if existing.isEmpty { existing = "/" }
        }
        let resolved = canonicalPath(existing)
        if resolved != existing { noteLinks(in: existing) }
        var result = resolved
        for component in missing { result = (result as NSString).appendingPathComponent(component) }
        if physicalPaths.count > 50_000 { physicalPaths.removeAll(keepingCapacity: true) }
        physicalPaths[path] = result
        return result
    }

    /// The project a folder belongs to: its checkout, except that a linked
    /// worktree kept inside its own main checkout (for example
    /// `.claude/worktrees/<name>`) belongs to that main checkout. `physical` must
    /// already be a result of `physical(_:at:)`; it is not rewritten again.
    func owner(of physical: String) -> String? {
        guard let checkout = walk(from: physical) else { return nil }
        if let known = origins[checkout] { return known }
        var owner = checkout
        let parent = (checkout as NSString).deletingLastPathComponent
        if parent != checkout, let outer = walk(from: parent),
           let common = linkedWorktreeCommonDirectory(checkout),
           canonicalPath(common) == canonicalPath((outer as NSString).appendingPathComponent(".git")) {
            owner = outer
        }
        origins[checkout] = owner
        return owner
    }

    func repository(containingDirectory directory: String) -> String? {
        guard let directory = physical(directory) else { return nil }
        return walk(from: directory)
    }

    /// Nearest valid checkout at or above a physical path.
    private func walk(from directory: String) -> String? {
        var current = directory
        var visited: [String] = []
        var result: CachedRepository = .none
        while true {
            if let known = repositories[current] {
                result = known
                break
            }
            visited.append(current)
            if isHomeOrAncestor(current) {
                // A Git repository at the home folder (dotfiles) or above it
                // must not swallow every folder an assistant was launched in.
                result = .none
                break
            }
            switch marker(at: current) {
            case .valid:
                result = .checkout(current)
            case .invalid:
                // A broken nested checkout is an ambiguous boundary, not
                // evidence that its files belong to an outer repository.
                result = .none
            case .absent:
                // NSURL maps "/" to "/.." instead of stopping, which once looped
                // forever for any path outside a checkout. Stop at the root.
                let parent = (current as NSString).deletingLastPathComponent
                if current != "/", !parent.isEmpty, parent != current, visited.count < 1_024 {
                    current = parent
                    continue
                }
                result = .none
            }
            break
        }
        if repositories.count > 50_000 { repositories.removeAll(keepingCapacity: true) }
        for path in visited { repositories[path] = result }
        return result.path
    }

    func isCheckoutRoot(_ path: String) -> Bool {
        guard let physical = physical(path) else { return false }
        return repository(containingDirectory: physical) == physical
    }

    func exists(_ path: String) -> Bool {
        if let known = existence[path] { return known }
        let value = files.fileExists(atPath: path)
        if existence.count > 50_000 { existence.removeAll(keepingCapacity: true) }
        existence[path] = value
        return value
    }

    /// Every confirmed file target must resolve to the same actual checkout.
    /// Deleted files are supported because lookup starts at their parent path.
    func repository(forFiles paths: [String]) -> String? {
        guard !paths.isEmpty else { return nil }
        var checkout: String?
        for path in paths {
            guard let path = ProjectLocationRegistry.lexicalPath(path),
                  let found = repository(containingDirectory: (path as NSString).deletingLastPathComponent)
            else { return nil }
            if let checkout, checkout != found { return nil }
            checkout = found
        }
        return checkout
    }

    /// A recorded workspace already inside a checkout keeps that repository.
    /// A parent workspace moves to a child checkout only when every confirmed
    /// target directory identifies that same checkout.
    func project(recordedWorkspace: String, confirmedDirectories: [String]) -> String {
        let workspace = physical(recordedWorkspace) ?? canonicalPath(recordedWorkspace)
        if let checkout = repository(containingDirectory: workspace) { return checkout }
        guard !confirmedDirectories.isEmpty else { return workspace }
        var checkout: String?
        for directory in Set(confirmedDirectories) {
            guard let found = repository(containingDirectory: directory) else { return workspace }
            if let checkout, checkout != found { return workspace }
            checkout = found
        }
        return checkout ?? workspace
    }

    /// Links met during this scan whose target is exactly a checkout root.
    /// A link into a subfolder, or to anything that is not a checkout, is not
    /// an earlier location of a project.
    func linkAliases() -> [(link: String, checkout: String)] {
        linkTargets.compactMap { link, target in
            guard !isHomeOrAncestor(link), isCheckoutRoot(target),
                  !CheckoutPath.contains(root: link, path: target),
                  !CheckoutPath.contains(root: target, path: link) else { return nil }
            return (link, target)
        }.sorted { $0.link < $1.link }
    }

    private func noteLinks(in path: String) {
        var prefix = ""
        for component in (path as NSString).pathComponents where component != "/" {
            prefix += "/" + component
            let isLink: Bool
            if let known = symbolicLinks[prefix] {
                isLink = known
            } else {
                isLink = FileStat.of(prefix)?.kind == .symbolicLink
                symbolicLinks[prefix] = isLink
            }
            if isLink, linkTargets[prefix] == nil {
                linkTargets[prefix] = canonicalPath(prefix)
            }
        }
    }

    private func isHomeOrAncestor(_ path: String) -> Bool {
        path == "/" || path == home || home.hasPrefix(path + "/")
    }

    /// The shared Git directory of a linked worktree, from its `.git` file's
    /// `gitdir:` and that directory's `commondir`. Nil for anything else,
    /// including submodules, which have no `commondir`.
    private func linkedWorktreeCommonDirectory(_ checkout: String) -> String? {
        let marker = (checkout as NSString).appendingPathComponent(".git")
        guard FileStat.of(marker)?.kind == .regular,
              let text = smallText(URL(fileURLWithPath: marker)), text.hasPrefix("gitdir: "),
              let reference = singleLine(String(text.dropFirst("gitdir: ".count))),
              let gitDirectory = gitDirectory(reference, relativeTo: checkout),
              let common = smallText(URL(fileURLWithPath: gitDirectory).appendingPathComponent("commondir")),
              let commonReference = singleLine(common) else { return nil }
        return resolve(commonReference, relativeTo: gitDirectory)
    }

    private func marker(at checkout: String) -> Marker {
        let marker = URL(fileURLWithPath: checkout, isDirectory: true).appendingPathComponent(".git")
        guard let type = FileStat.of(marker.path)?.kind else { return .absent }
        if type == .directory || type == .symbolicLink && isDirectory(marker.path) {
            return validGitDirectory(marker) ? .valid : .invalid
        }
        guard type == .regular,
              let text = smallText(marker), text.hasPrefix("gitdir: "),
              let reference = singleLine(String(text.dropFirst("gitdir: ".count))),
              gitDirectory(reference, relativeTo: checkout) != nil else { return .invalid }
        return .valid
    }

    /// A `gitdir:` reference as a valid Git directory. A worktree's reference is
    /// absolute, so after its main checkout moved it names the earlier path;
    /// that is followed through learned earlier locations.
    private func gitDirectory(_ reference: String, relativeTo checkout: String) -> String? {
        guard let path = resolve(reference, relativeTo: checkout) else { return nil }
        if validGitDirectory(URL(fileURLWithPath: path, isDirectory: true)) { return path }
        let moved = locations.rewrite(path)
        guard moved != path, validGitDirectory(URL(fileURLWithPath: moved, isDirectory: true)) else { return nil }
        return moved
    }

    private func validGitDirectory(_ directory: URL) -> Bool {
        guard isDirectory(directory.path),
              let headText = smallText(directory.appendingPathComponent("HEAD")),
              let head = singleLine(headText), validHead(head) else { return false }
        let commonURL = directory.appendingPathComponent("commondir")
        let common: URL
        if files.fileExists(atPath: commonURL.path) {
            guard let text = smallText(commonURL), let reference = singleLine(text),
                  let path = resolve(reference, relativeTo: directory.path) else { return false }
            common = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            common = directory
        }
        return isDirectory(common.appendingPathComponent("objects").path)
            && (isDirectory(common.appendingPathComponent("refs").path)
                || isDirectory(common.appendingPathComponent("reftable").path))
    }

    private func validHead(_ text: String) -> Bool {
        if text.hasPrefix("ref: ") {
            let reference = String(text.dropFirst("ref: ".count))
            return reference.hasPrefix("refs/") && !reference.hasSuffix("/")
                && !reference.contains("..") && !reference.contains(" ")
                && !reference.contains("\\") && !reference.contains("@{")
                && !reference.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }
        return (text.count == 40 || text.count == 64)
            && text.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }
    }

    private func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return files.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    private func smallText(_ url: URL) -> String? {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let metadata = FileStat.of(resolved.path), metadata.kind == .regular, metadata.size <= 4_096,
              let handle = try? FileHandle(forReadingFrom: resolved) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4_097), data.count <= 4_096 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func singleLine(_ text: String) -> String? {
        let line = text.trimmingCharacters(in: .newlines)
        guard !line.isEmpty, !line.contains("\0"), !line.contains("\n"), !line.contains("\r") else { return nil }
        return line
    }

    private func resolve(_ reference: String, relativeTo directory: String) -> String? {
        guard reference.utf8.count <= 4_096 else { return nil }
        return CheckoutPath.resolve(reference, base: directory)
    }
}
