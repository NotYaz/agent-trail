import Foundation
import XCTest
@testable import AgentTrailCore

final class GitHistoryTests: XCTestCase {
    private let zero = String(repeating: "0", count: 40)
    private let one = String(repeating: "1", count: 40)
    private let two = String(repeating: "2", count: 40)

    func testReflogKeepsMovesButNoIdentity() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("HEAD")
        try """
        \(zero) \(one) Private Person <private@example.com> 1000 +0300\tcommit (initial): First
        \(one) \(one) Private Person <private@example.com> 2000 +0300\tcheckout: moving from main to feature/a
        \(one) \(two) Private Person <private@example.com> 3000 +0300\tcommit: Second
        \(two) \(one) Private Person <private@example.com> 4000 +0300\tcheckout: moving from feature/a to main
        \(one) \(two) Private Person <private@example.com> 5000 +0300\tpull --ff-only: Fast-forward
        \(one) \(two) Private Person <private@example.com> 6000 +0300\tmerge origin/main: Fast-forward
        broken line without a tab
        """.write(to: log, atomically: true, encoding: .utf8)
        let moves = GitHistoryReader.parseReflog(at: log.path, worktree: "/repo")
        XCTAssertEqual(moves.map(\.kind), [.commit, .checkout(from: "main", to: "feature/a"), .commit,
                                           .checkout(from: "feature/a", to: "main"), .pull, .fastForward])
        XCTAssertEqual(moves.map(\.date.timeIntervalSince1970), [1000, 2000, 3000, 4000, 5000, 6000])
        XCTAssertEqual(moves[2].old, one)
        XCTAssertEqual(moves[2].new, two)
        let encoded = String(decoding: try JSONEncoder().encode(GitHistory(checkout: "/repo", headMoves: moves)), as: UTF8.self)
        XCTAssertFalse(encoded.contains("Private"))
        XCTAssertFalse(encoded.contains("example.com"))

        let history = GitHistory(checkout: "/repo", headMoves: moves)
        // Before the first checkout, the branch it moved from.
        XCTAssertEqual(history.branch(in: "/repo", at: Date(timeIntervalSince1970: 1500)), "main")
        XCTAssertEqual(history.branch(in: "/repo", at: Date(timeIntervalSince1970: 3500)), "feature/a")
        XCTAssertEqual(history.branch(in: "/repo", at: Date(timeIntervalSince1970: 9000)), "main")
        XCTAssertNil(history.branch(in: "/elsewhere", at: Date(timeIntervalSince1970: 3500)))
    }

    func testCommitsKeepTreesPullRequestsAndCoAuthorNamesOnly() {
        let output = "\(two)\0\(one)\0tree-b\02000\0Ship it (#18)\0Claude Opus <noreply@anthropic.com>\u{1f}Pat"
            + "\u{1f}<bare@example.com>\u{1f}jane@example.com\0GitHub\u{1e}\n"
            + "\(one)\0\0tree-a\01000\0First (#x)\0\u{1e}\n"
            + "short\0\0tree\01500\0Broken\0\u{1e}\n"
        let commits = GitHistoryReader.parseCommits(output)
        XCTAssertEqual(commits.map(\.sha), [one, two])
        XCTAssertEqual(commits[0].parents, [])
        XCTAssertEqual(commits[1].parents, [one])
        XCTAssertEqual(commits.map(\.tree), ["tree-a", "tree-b"])
        XCTAssertEqual(commits[1].coAuthors, ["Claude Opus", "Pat"])
        XCTAssertEqual(commits.map(\.pullRequest), [nil, 18])
        let merge = GitHistory.Commit(sha: one, parents: [zero, two], date: Date(), subject: "Merge pull request #42 from me/x")
        XCTAssertEqual(merge.pullRequest, 42)
        XCTAssertNil(GitHistory.Commit(sha: one, parents: [], date: Date(), subject: "Odd (#-3)").pullRequest)
        // Only commits GitHub made name pull requests; elsewhere "(#146)" is an issue reference.
        let local = GitHistoryReader.parseCommits("\(one)\0\0t\01000\0Fix layout (#146)\0\0Ivan\u{1e}\n")
        XCTAssertEqual(local.map(\.viaGitHub), [false])
        XCTAssertEqual(local.map(\.pullRequest), [nil])
        let merged = GitHistory.Commit(sha: one, parents: [zero, two], date: Date(),
                                       subject: "Слияние PR #151: журнал (#148), сметы (#149)")
        XCTAssertEqual(merged.pullRequest, 151)
    }

    func testClaudeSessionTrailerKeepsOnlyACloudSessionID() throws {
        let output = "\(one)\0\0t\01000\0Cloud work\0\0Claude\0https://claude.ai/code/session_017gAbC\u{1e}\n"
            + "\(two)\0\(one)\0t\02000\0Odd links\0\0Claude\0http://claude.ai/code/session_x\u{1f}"
            + "https://claude.ai/code/session_a/../b\u{1f}https://example.com/code/session_y\u{1f}https://claude.ai/code/session_\u{1e}\n"
            + "\(zero)\0\0t\0500\0Read before the trailer was\0\0Ivan\u{1e}\n"
        let commits = GitHistoryReader.parseCommits(output)
        XCTAssertEqual(commits.map(\.cloudSession), [nil, "session_017gAbC", nil])
        let decoded = try JSONDecoder().decode(GitHistory.Commit.self, from: JSONEncoder().encode(commits[1]))
        XCTAssertEqual(decoded, commits[1])
        // The oldest commit whose trailer names a session; a body that only quotes the link does not count.
        let first = "2000\0https://claude.ai/code/session_B\u{1e}\n" + "900\0\u{1e}\n"
            + "1500\0https://claude.ai/code/session_A\u{1f}https://claude.ai/code/session_C\u{1e}\n" + "bad\0https://claude.ai/code/session_D\u{1e}\n"
        XCTAssertEqual(GitHistoryReader.parseFirstCloudCommit(first), Date(timeIntervalSince1970: 1500))
        XCTAssertNil(GitHistoryReader.parseFirstCloudCommit("900\0\u{1e}\n"))
        XCTAssertNil(GitHistoryReader.firstCloudCommit(checkout: "/nonexistent", git: nil))
        // Snapshots saved before the trailer was read have no cloud session.
        let old = try JSONDecoder().decode(GitHistory.Commit.self, from: Data(#"{"sha":"\#(one)","parents":[],"date":0,"subject":"x"}"#.utf8))
        XCTAssertNil(old.cloudSession)
    }

    func testANewWorktreeNamesItsBranchThroughItsHeadFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("repo")
        let common = main.appendingPathComponent(".git")
        let worktree = main.appendingPathComponent(".claude/worktrees/nv-billing")
        let administrative = common.appendingPathComponent("worktrees/nv-billing")
        for directory in [administrative.appendingPathComponent("logs"), worktree] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "ref: refs/heads/main\n".write(to: common.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/nv/billing\n".write(to: administrative.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "\(worktree.path)/.git\n".write(to: administrative.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8)
        try "\(zero) \(one) A <a@b> 1000 +0000\treset: moving to HEAD\n"
            .write(to: administrative.appendingPathComponent("logs/HEAD"), atomically: true, encoding: .utf8)
        let history = try XCTUnwrap(GitHistoryReader.read(checkout: main.path, git: nil))
        XCTAssertEqual(history.worktreeHeads[worktree.path], "nv/billing")
        XCTAssertEqual(history.branch(in: worktree.path, at: Date(timeIntervalSince1970: 2000)), "nv/billing")
        XCTAssertEqual(history.branch(in: main.path, at: Date(timeIntervalSince1970: 2000)), "main")
    }

    func testBranchesSkipRemoteHEAD() {
        let output = "refs/heads/main\0\(one)\nrefs/remotes/origin/perf/smooth\0\(two)\nrefs/remotes/origin/HEAD\0\(one)\nrefs/tags/v1\0\(one)\n"
        let branches = GitHistoryReader.parseBranches(output)
        XCTAssertEqual(branches.map(\.name), ["main", "origin/perf/smooth"])
        XCTAssertEqual(branches.map(\.shortName), ["main", "perf/smooth"])
        XCTAssertEqual(branches.map(\.isRemote), [false, true])
    }

    func testLinkedWorktreeReflogsAreReadThroughTheCommonDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("repo")
        let common = main.appendingPathComponent(".git")
        let worktree = main.appendingPathComponent(".claude/worktrees/feature")
        let administrative = common.appendingPathComponent("worktrees/feature")
        for directory in [common.appendingPathComponent("logs"), administrative.appendingPathComponent("logs"), worktree] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "\(zero) \(one) A <a@b> 1000 +0000\tcommit (initial): First\n"
            .write(to: common.appendingPathComponent("logs/HEAD"), atomically: true, encoding: .utf8)
        try "\(one) \(one) A <a@b> 2000 +0000\tcheckout: moving from main to worktree-feature\n"
            .write(to: administrative.appendingPathComponent("logs/HEAD"), atomically: true, encoding: .utf8)
        try "\(worktree.path)/.git\n".write(to: administrative.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: administrative.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
        try "gitdir: \(administrative.path)\n".write(to: worktree.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        XCTAssertEqual(GitHistoryReader.commonDirectory(of: worktree.path), common.path)
        XCTAssertNil(GitHistoryReader.commonDirectory(of: root.path))
        let history = try XCTUnwrap(GitHistoryReader.read(checkout: worktree.path, git: nil))
        XCTAssertEqual(history.headMoves.map(\.worktree), [main.path, worktree.path])
        XCTAssertEqual(history.branch(in: worktree.path, at: Date(timeIntervalSince1970: 3000)), "worktree-feature")
        XCTAssertTrue(history.commits.isEmpty)

        // Git 2.48 may write the worktree's path relative to its administrative folder.
        try "../../../.claude/worktrees/feature/.git\n".write(to: administrative.appendingPathComponent("gitdir"),
                                                              atomically: true, encoding: .utf8)
        XCTAssertEqual(GitHistoryReader.headMoves(try XCTUnwrap(GitHistoryReader.layout(of: main.path))).map(\.worktree),
                       [main.path, worktree.path])
    }

    func testSubmoduleGitDirectoryWithoutCommondirIsItsOwnCommonDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let checkout = root.appendingPathComponent("sub")
        let gitDirectory = root.appendingPathComponent("parent/.git/modules/sub")
        for directory in [checkout, gitDirectory.appendingPathComponent("logs")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try "gitdir: ../parent/.git/modules/sub\n".write(to: checkout.appendingPathComponent(".git"), atomically: true,
                                                         encoding: .utf8)
        try "\(zero) \(one) A <a@b> 1000 +0000\tcheckout: moving from main to topic\n"
            .write(to: gitDirectory.appendingPathComponent("logs/HEAD"), atomically: true, encoding: .utf8)
        let layout = try XCTUnwrap(GitHistoryReader.layout(of: checkout.path))
        XCTAssertEqual(layout.common, gitDirectory.path)
        XCTAssertEqual(layout.mainWorktree, checkout.path)
        XCTAssertEqual(GitHistoryReader.headMoves(layout).map(\.worktree), [checkout.path])
        // Only regular files are read.
        XCTAssertNil(GitHistoryReader.smallText(gitDirectory.path))
    }

    func testTagsAndShortHashesAreNotBranchesButDeletedBranchesAre() {
        let history = GitHistory(checkout: "/repo", branches: [GitHistory.Branch(name: "main", head: one, isRemote: false)],
                                 tags: ["v1.2"], headMoves: [
            GitHistory.HeadMove(date: Date(timeIntervalSince1970: 10), worktree: "/repo", old: one, new: two,
                                kind: .checkout(from: "main", to: "v1.2")),
            GitHistory.HeadMove(date: Date(timeIntervalSince1970: 20), worktree: "/repo", old: two, new: one,
                                kind: .checkout(from: two, to: "e0d7f")),
            GitHistory.HeadMove(date: Date(timeIntervalSince1970: 30), worktree: "/repo", old: one, new: one,
                                kind: .checkout(from: two, to: "gone-branch")),
            GitHistory.HeadMove(date: Date(timeIntervalSince1970: 40), worktree: "/repo", old: one, new: one,
                                kind: .checkout(from: "gone-branch", to: "main"))
        ])
        XCTAssertNil(history.branch(in: "/repo", at: Date(timeIntervalSince1970: 15)))
        XCTAssertNil(history.branch(in: "/repo", at: Date(timeIntervalSince1970: 25)))
        // Created by `checkout -b`, later deleted: still a branch.
        XCTAssertEqual(history.branch(in: "/repo", at: Date(timeIntervalSince1970: 35)), "gone-branch")
    }

    func testWithoutGitBranchesComeFromRefFilesAndReflogsDecodeLeniently() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let common = root.appendingPathComponent(".git")
        for directory in ["refs/heads/feature", "refs/remotes/origin", "logs"] {
            try FileManager.default.createDirectory(at: common.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try "\(one)\n".write(to: common.appendingPathComponent("refs/heads/feature/a"), atomically: true, encoding: .utf8)
        try "ref: refs/remotes/origin/main\n".write(to: common.appendingPathComponent("refs/remotes/origin/HEAD"),
                                                   atomically: true, encoding: .utf8)
        try "# pack-refs with: peeled\n\(two) refs/heads/main\n\(one) refs/remotes/origin/main\n"
            .write(to: common.appendingPathComponent("packed-refs"), atomically: true, encoding: .utf8)
        var reflog = Data("\(zero) \(one) Jos\u{e9} <j@x> 1000 +0000\tcommit (initial): caf".utf8)
        reflog.append(0xE9) // ISO-8859-1 "é", invalid as UTF-8
        reflog.append(Data("\n\(one) \(one) J <j@x> 2000 +0000\tcheckout: moving from main to feature/a\n".utf8))
        try reflog.write(to: common.appendingPathComponent("logs/HEAD"))
        let history = try XCTUnwrap(GitHistoryReader.read(checkout: root.path, git: nil))
        XCTAssertEqual(history.branches.map(\.name).sorted(), ["feature/a", "main", "origin/main"])
        XCTAssertEqual(history.headMoves.count, 2)
        XCTAssertEqual(history.branch(in: root.path, at: Date(timeIntervalSince1970: 2500)), "feature/a")
    }

    func testDetachedCheckoutsAreNotBranches() {
        let history = GitHistory(checkout: "/repo", branches: [GitHistory.Branch(name: "main", head: one, isRemote: false),
                                                               GitHistory.Branch(name: "origin/main", head: one, isRemote: true)],
                                 headMoves: [
            GitHistory.HeadMove(date: Date(timeIntervalSince1970: 10), worktree: "/repo", old: one, new: two,
                                kind: .checkout(from: "main", to: "origin/main")),
            GitHistory.HeadMove(date: Date(timeIntervalSince1970: 20), worktree: "/repo", old: two, new: one,
                                kind: .checkout(from: "origin/main", to: String(two.prefix(12)))),
            GitHistory.HeadMove(date: Date(timeIntervalSince1970: 30), worktree: "/repo", old: one, new: one,
                                kind: .checkout(from: String(two.prefix(12)), to: "main"))
        ])
        XCTAssertEqual(history.branch(in: "/repo", at: Date(timeIntervalSince1970: 5)), "main")
        XCTAssertNil(history.branch(in: "/repo", at: Date(timeIntervalSince1970: 15)))
        XCTAssertNil(history.branch(in: "/repo", at: Date(timeIntervalSince1970: 25)))
        XCTAssertEqual(history.branch(in: "/repo", at: Date(timeIntervalSince1970: 35)), "main")
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitHistoryTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Resolve /var → /private/var so paths compare equal to what the reader builds.
        return URL(fileURLWithPath: directory.resolvingSymlinksInPath().path)
    }
}
