import Foundation
import XCTest
@testable import AgentTrailCore

final class GitProjectResolverTests: XCTestCase {
    func testParentDirectoryDoesNotGuessAChildRepository() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let checkout = try fixture.repository("outputs/AgentTrail")
        let resolver = GitProjectResolver()
        XCTAssertNil(resolver.repository(containingDirectory: fixture.root.path))
        XCTAssertNil(resolver.repository(containingDirectory: checkout.deletingLastPathComponent().path))
        XCTAssertEqual(resolver.repository(forFiles: [checkout.appendingPathComponent("Sources/new.swift").path]), checkout.path)
    }

    func testSubfolderAndDeletedFileResolveToExactCheckout() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let checkout = try fixture.repository("repo")
        let resolver = GitProjectResolver()
        XCTAssertEqual(resolver.repository(containingDirectory: checkout.appendingPathComponent("Sources/Deleted").path), checkout.path)
        XCTAssertEqual(resolver.repository(forFiles: [
            checkout.appendingPathComponent("Sources/deleted.swift").path,
            checkout.appendingPathComponent("README.md").path
        ]), checkout.path)
    }

    func testWholeSessionResolutionRequiresOneProvenChildCheckout() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.repository("outputs/first")
        let second = try fixture.repository("outputs/second")
        let resolver = GitProjectResolver()
        let source = first.appendingPathComponent("Sources").path
        XCTAssertEqual(resolver.project(recordedWorkspace: fixture.root.path, confirmedDirectories: [source, first.path, source]), first.path)
        XCTAssertEqual(resolver.project(recordedWorkspace: fixture.root.path, confirmedDirectories: []), fixture.root.path)
        XCTAssertEqual(resolver.project(recordedWorkspace: fixture.root.path, confirmedDirectories: [source, second.path]), fixture.root.path)
        XCTAssertEqual(resolver.project(recordedWorkspace: fixture.root.path, confirmedDirectories: [source, fixture.root.path]), fixture.root.path)
        XCTAssertEqual(resolver.project(recordedWorkspace: source, confirmedDirectories: []), first.path)
    }

    func testSameNamesAndMixedCheckoutsNeverMerge() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.repository("one/repo")
        let second = try fixture.repository("two/repo")
        let resolver = GitProjectResolver()
        XCTAssertEqual(resolver.repository(containingDirectory: first.path), first.path)
        XCTAssertEqual(resolver.repository(containingDirectory: second.path), second.path)
        XCTAssertNil(resolver.repository(forFiles: [first.appendingPathComponent("a.swift").path, second.appendingPathComponent("b.swift").path]))
        XCTAssertNil(resolver.repository(forFiles: []))
    }

    func testSiblingPathsAndUngittedFilesHaveNoRepository() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.repository("repo")
        let resolver = GitProjectResolver()
        XCTAssertNil(resolver.repository(forFiles: [fixture.root.appendingPathComponent("repo-other/file.swift").path]))
        XCTAssertNil(resolver.repository(forFiles: [fixture.root.appendingPathComponent("loose.swift").path]))
        XCTAssertNil(resolver.repository(containingDirectory: "relative"))
        XCTAssertNil(resolver.repository(forFiles: ["relative.swift"]))
    }

    func testLinkedWorktreeGitFileKeepsItsOwnCheckout() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let main = try fixture.repository("main")
        let checkout = fixture.root.appendingPathComponent("feature")
        let gitDirectory = main.appendingPathComponent(".git/worktrees/feature")
        try fixture.directory(checkout)
        try fixture.directory(gitDirectory)
        try fixture.write("ref: refs/heads/feature\n", at: gitDirectory.appendingPathComponent("HEAD"))
        try fixture.write("../..\n", at: gitDirectory.appendingPathComponent("commondir"))
        try fixture.write("gitdir: ../main/.git/worktrees/feature\n", at: checkout.appendingPathComponent(".git"))
        let resolver = GitProjectResolver()
        XCTAssertEqual(resolver.repository(containingDirectory: checkout.path), checkout.path)
        XCTAssertEqual(resolver.repository(forFiles: [checkout.appendingPathComponent("Sources/new.swift").path]), checkout.path)
        XCTAssertNil(resolver.repository(forFiles: [main.appendingPathComponent("a.swift").path, checkout.appendingPathComponent("a.swift").path]))
    }

    func testStandaloneGitFileRequiresValidMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let storage = try fixture.repository("storage")
        let checkout = fixture.root.appendingPathComponent("checkout")
        try fixture.directory(checkout)
        try fixture.write("gitdir: \(storage.appendingPathComponent(".git").path)\n", at: checkout.appendingPathComponent(".git"))
        XCTAssertEqual(GitProjectResolver().repository(containingDirectory: checkout.path), checkout.path)
        try FileManager.default.removeItem(at: storage.appendingPathComponent(".git/HEAD"))
        XCTAssertNil(GitProjectResolver().repository(containingDirectory: checkout.path))
    }

    func testBogusOrOversizedGitMarkersDoNotMatch() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let main = try fixture.repository("main")
        let nested = main.appendingPathComponent("nested")
        try fixture.directory(nested)
        let marker = nested.appendingPathComponent(".git")
        try fixture.write("this is not Git metadata\n", at: marker)
        XCTAssertNil(GitProjectResolver().repository(containingDirectory: nested.path))
        try fixture.write("gitdir: missing\n", at: marker)
        XCTAssertNil(GitProjectResolver().repository(containingDirectory: nested.path))
        try fixture.write("gitdir: " + String(repeating: "a", count: 4_097), at: marker)
        XCTAssertNil(GitProjectResolver().repository(containingDirectory: nested.path))
        try FileManager.default.removeItem(at: marker)
        try fixture.directory(marker)
        XCTAssertNil(GitProjectResolver().repository(containingDirectory: nested.path))
    }

    func testResetObservesNewMetadataAndCanonicalAliases() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let checkout = fixture.root.appendingPathComponent("repo")
        try fixture.directory(checkout)
        let resolver = GitProjectResolver()
        XCTAssertNil(resolver.repository(containingDirectory: checkout.path))
        _ = try fixture.repository("repo")
        resolver.reset()
        XCTAssertEqual(resolver.repository(containingDirectory: checkout.path), checkout.path)
        let alias = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: checkout)
        XCTAssertEqual(resolver.repository(forFiles: [alias.appendingPathComponent("new.swift").path]), checkout.path)
    }

    func testPathsOutsideAnyCheckoutStopAtTheFilesystemRoot() throws {
        // Walking past "/" once looped forever and exhausted memory.
        let fixture = try Fixture()
        defer { fixture.remove() }
        let resolver = GitProjectResolver()
        let deep = fixture.root.appendingPathComponent("a/b/c/d/e").path
        XCTAssertNil(resolver.repository(containingDirectory: deep))
        XCTAssertNil(resolver.repository(containingDirectory: "/"))
        XCTAssertNil(resolver.repository(containingDirectory: "/.."))
        XCTAssertNil(resolver.repository(forFiles: ["/", "/missing.swift", deep + "/file.swift"]))
        XCTAssertEqual(resolver.project(recordedWorkspace: deep, confirmedDirectories: [deep, "/"]), deep)
    }

    func testHomeFolderRepositoryNeverClaimsLaunchFolders() throws {
        // A dotfiles repository at the home folder must not make every folder an
        // assistant was started in part of one giant project.
        let fixture = try Fixture()
        defer { fixture.remove() }
        let home = try fixture.repository("home")
        let project = try fixture.repository("home/Dev/project")
        let resolver = GitProjectResolver(homeDirectory: home.path)
        XCTAssertNil(resolver.repository(containingDirectory: home.appendingPathComponent("Documents/Codex/launch").path))
        XCTAssertNil(resolver.repository(containingDirectory: home.path))
        XCTAssertEqual(resolver.repository(containingDirectory: project.appendingPathComponent("Sources").path), project.path)
    }

    func testPhysicalPathFollowsLinksEvenForDeletedFiles() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let real = try fixture.repository("Dev/agent-trail")
        let link = fixture.root.appendingPathComponent("outputs/AgentTrail")
        try fixture.directory(link.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let resolver = GitProjectResolver()
        XCTAssertEqual(resolver.physical(link.appendingPathComponent("Sources/deleted.swift").path),
                       real.appendingPathComponent("Sources/deleted.swift").path)
        XCTAssertEqual(resolver.repository(containingDirectory: link.appendingPathComponent("Sources/Gone").path), real.path)
        XCTAssertEqual(resolver.linkAliases().map(\.link), [link.path])
        XCTAssertEqual(resolver.linkAliases().map(\.checkout), [real.path])
    }

    func testLinksIntoSubfoldersOrPlainFoldersAreNotAliases() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let real = try fixture.repository("repo")
        let plain = fixture.root.appendingPathComponent("plain")
        try fixture.directory(plain.appendingPathComponent("inner"))
        let sources = real.appendingPathComponent("Sources")
        try fixture.directory(sources)
        let toSubfolder = fixture.root.appendingPathComponent("to-sources")
        let toPlain = fixture.root.appendingPathComponent("to-plain")
        try FileManager.default.createSymbolicLink(at: toSubfolder, withDestinationURL: sources)
        try FileManager.default.createSymbolicLink(at: toPlain, withDestinationURL: plain)
        let resolver = GitProjectResolver()
        XCTAssertEqual(resolver.physical(toSubfolder.appendingPathComponent("a.swift").path), sources.appendingPathComponent("a.swift").path)
        XCTAssertNotNil(resolver.physical(toPlain.appendingPathComponent("inner").path))
        XCTAssertTrue(resolver.linkAliases().isEmpty)
    }

    func testWorktreeInsideItsMainCheckoutBelongsToThatCheckout() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let main = try fixture.repository("main")
        let worktree = main.appendingPathComponent(".claude/worktrees/feature")
        let gitDirectory = main.appendingPathComponent(".git/worktrees/feature")
        try fixture.directory(worktree)
        try fixture.directory(gitDirectory)
        try fixture.write("ref: refs/heads/feature\n", at: gitDirectory.appendingPathComponent("HEAD"))
        try fixture.write("../..\n", at: gitDirectory.appendingPathComponent("commondir"))
        try fixture.write("gitdir: \(gitDirectory.path)\n", at: worktree.appendingPathComponent(".git"))
        let resolver = GitProjectResolver()
        XCTAssertEqual(resolver.repository(containingDirectory: worktree.appendingPathComponent("Sources").path), worktree.path)
        XCTAssertEqual(resolver.owner(of: worktree.appendingPathComponent("Sources").path), main.path)
        // A submodule's .git file has no shared directory; it stays its own project.
        let submodule = main.appendingPathComponent("vendor/library")
        let moduleDirectory = main.appendingPathComponent(".git/modules/library")
        try fixture.directory(submodule)
        try fixture.directory(moduleDirectory.appendingPathComponent("objects"))
        try fixture.directory(moduleDirectory.appendingPathComponent("refs"))
        try fixture.write("ref: refs/heads/main\n", at: moduleDirectory.appendingPathComponent("HEAD"))
        try fixture.write("gitdir: \(moduleDirectory.path)\n", at: submodule.appendingPathComponent(".git"))
        XCTAssertEqual(resolver.owner(of: submodule.path), submodule.path)
    }

    func testNestedWorktreeStaysWithItsMainCheckoutAfterTheMainCheckoutMoves() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let main = try fixture.repository("old/main")
        let worktree = main.appendingPathComponent(".claude/worktrees/feature")
        let gitDirectory = main.appendingPathComponent(".git/worktrees/feature")
        try fixture.directory(worktree)
        try fixture.directory(gitDirectory)
        try fixture.write("ref: refs/heads/feature\n", at: gitDirectory.appendingPathComponent("HEAD"))
        try fixture.write("../..\n", at: gitDirectory.appendingPathComponent("commondir"))
        try fixture.write("gitdir: \(gitDirectory.path)\n", at: worktree.appendingPathComponent(".git"))
        let moved = fixture.root.appendingPathComponent("new/main")
        try fixture.directory(moved.deletingLastPathComponent())
        try FileManager.default.moveItem(at: main, to: moved)
        var registry = ProjectLocationRegistry()
        try registry.register(path: moved.path, previousPaths: [main.path])
        let resolver = GitProjectResolver(locations: registry)
        let inside = moved.appendingPathComponent(".claude/worktrees/feature/Sources").path
        XCTAssertEqual(resolver.owner(of: inside), moved.path)
    }

    func testEarlierLocationStoredResolvedMatchesEvidenceRecordedThroughALinkedParent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let volume = fixture.root.appendingPathComponent("Volumes/Work/Dev")
        try fixture.directory(volume)
        let alias = fixture.root.appendingPathComponent("Dev")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: volume)
        let current = try fixture.repository("Projects/app")
        var registry = ProjectLocationRegistry()
        try registry.register(path: current.path, previousPaths: [volume.appendingPathComponent("app").path])
        let resolver = GitProjectResolver(locations: registry)
        XCTAssertEqual(resolver.physical(alias.appendingPathComponent("app/a.swift").path, at: Date()),
                       current.appendingPathComponent("a.swift").path)
    }

    private struct Fixture {
        let root: URL

        init() throws {
            root = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.appendingPathComponent("GitProjectResolver-\(UUID().uuidString)").path), isDirectory: true)
            try directory(root)
        }

        func directory(_ url: URL) throws {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        func write(_ text: String, at url: URL) throws {
            try Data(text.utf8).write(to: url)
        }

        func repository(_ relative: String) throws -> URL {
            let checkout = root.appendingPathComponent(relative, isDirectory: true)
            let git = checkout.appendingPathComponent(".git", isDirectory: true)
            try directory(git.appendingPathComponent("objects", isDirectory: true))
            try directory(git.appendingPathComponent("refs", isDirectory: true))
            try write("ref: refs/heads/main\n", at: git.appendingPathComponent("HEAD"))
            return checkout
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
