import Foundation
import XCTest
@testable import AgentTrailCore

final class CodexActivityProviderTests: XCTestCase {
    func testOnlyCompletedFileChangesInsideTheCheckoutCount() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inside = fixture.project.appendingPathComponent("source.swift").path
        let outside = fixture.root.appendingPathComponent("elsewhere/file.swift").path
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("good", status: "completed", files: [inside: "update"], seconds: 10),
            fixture.fileChange("failed", status: "failed", files: [inside: "update"], seconds: 20),
            fixture.fileChange("outside", status: "completed", files: [outside: "add"], seconds: 30),
            fixture.shell(seconds: 40)
        ])
        let metadata = CodexActivityProvider().metadata(sources: [fixture.source])
        XCTAssertEqual(metadata.projects.count, 1)
        XCTAssertNil(metadata.projects[0].latestEdit)
        XCTAssertEqual(metadata.projects[0].sessionCount, 1)
        let project = try XCTUnwrap(CodexActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.path, fixture.project.path)
        XCTAssertEqual(project.recordedEditCount, 1)
        XCTAssertEqual(project.latestEdit?.latestEdit, fixture.date(10))
        XCTAssertEqual(project.latestEdit?.latestEditWorkspacePath, fixture.project.path)
        XCTAssertEqual(project.sessionCount, 1)
    }

    func testReplayAppendAndCacheDoNotStoreTheDiff() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.project.appendingPathComponent("source.swift").path
        let change = fixture.fileChange("replayed", status: "completed", files: [path: "update"], seconds: 10)
        try fixture.write(fixture.sessionLines() + [change, change])
        let copied = fixture.root.appendingPathComponent("archived_sessions/2026/10/30/rollout-copy.jsonl")
        try fixture.write(fixture.sessionLines() + [change], to: copied)
        let provider = CodexActivityProvider(cacheURL: fixture.cache)
        XCTAssertEqual(provider.scan(sources: [fixture.source]).projects[0].recordedEditCount, 1)
        let cacheText = try String(contentsOf: fixture.cache, encoding: .utf8)
        XCTAssertFalse(cacheText.contains("PRIVATE_DIFF_MARKER"))
        XCTAssertFalse(cacheText.contains("PRIVATE_COMMAND_MARKER"))
        try fixture.append([change])
        let relaunched = CodexActivityProvider(cacheURL: fixture.cache)
        XCTAssertEqual(relaunched.scan(sources: [fixture.source]).projects[0].recordedEditCount, 1)
        try fixture.append([fixture.fileChange("added", status: "completed", files: [path: "add"], seconds: 50)])
        XCTAssertEqual(relaunched.scan(sources: [fixture.source]).projects[0].recordedEditCount, 2)
    }

    func testUTCHistoryAndExternalTurnAreSeparate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.project.appendingPathComponent("source.swift").path
        var created = fixture.sessionLines(timestamp: "2026-10-29T23:30:00Z")
        created.append(fixture.fileChange("before", status: "completed", files: [path: "update"],
            timestamp: "2026-10-30T02:59:00.000+03:00"))
        created.append(fixture.fileChange("after", status: "completed", files: [path: "update"],
            timestamp: "2026-10-30T00:01:00Z"))
        try fixture.write(created)
        let project = try XCTUnwrap(CodexActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.recordedEditCount, 2)
        XCTAssertEqual(project.sessionCount, 1)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let creationDay = try XCTUnwrap(formatter.date(from: "2026-10-29T00:00:00Z"))
        let editDay = try XCTUnwrap(formatter.date(from: "2026-10-30T00:00:00Z"))
        XCTAssertEqual(project.history.first { $0.day == creationDay }?.sessionCount, 1)
        XCTAssertEqual(project.history.first { $0.day == creationDay }?.editCount, 1)
        XCTAssertEqual(project.history.first { $0.day == editDay }?.editCount, 1)

        let external = fixture.root.appendingPathComponent("other-repository")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let outside = external.appendingPathComponent("outside.swift").path
        try fixture.append([
            fixture.turn(external.path),
            fixture.fileChange("external", status: "completed", files: [outside: "add"], seconds: 80)
        ])
        let rescanned = try XCTUnwrap(CodexActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(rescanned.recordedEditCount, 2)
        XCTAssertEqual(rescanned.path, fixture.project.path)
    }

    func testWorktreeTurnKeepsTheSessionProject() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let worktree = fixture.project.appendingPathComponent(".codex/worktrees/feature")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let edited = worktree.appendingPathComponent("new.swift").path
        try fixture.write(fixture.sessionLines(roots: [fixture.project.path, worktree.path]) + [
            fixture.turn(worktree.path),
            fixture.fileChange("tree", status: "completed", files: [edited: "add"], seconds: 15)
        ])
        let project = try XCTUnwrap(CodexActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.path, fixture.project.path)
        XCTAssertEqual(project.recordedEditCount, 1)
        XCTAssertEqual(project.latestEdit?.latestEditWorkspacePath, worktree.path)
    }

    func testMoveOutsideTheCheckoutDoesNotCount() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.project.appendingPathComponent("source.swift").path
        let destination = fixture.root.appendingPathComponent("elsewhere/source.swift").path
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("outside-move", status: "completed", files: [path: "update"],
                moves: [path: destination], seconds: 10)
        ])
        let project = try XCTUnwrap(CodexActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.recordedEditCount, 0)
        XCTAssertNil(project.latestEdit)
    }

    func testMoveWithinTheCheckoutCounts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.project.appendingPathComponent("source.swift").path
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("inside-move", status: "completed", files: [path: "update"],
                moves: [path: "renamed.swift"], seconds: 10)
        ])
        let project = try XCTUnwrap(CodexActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.recordedEditCount, 1)
        XCTAssertEqual(project.latestEdit?.latestEditWorkspacePath, fixture.project.path)
    }

    func testVersionOneCacheIsRebuiltForDestinationAndWorkspaceValidation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.project.appendingPathComponent("source.swift").path
        let destination = fixture.root.appendingPathComponent("elsewhere/source.swift").path
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("old-outside-move", status: "completed", files: [path: "update"],
                moves: [path: destination], seconds: 10)
        ])
        _ = CodexActivityProvider(cacheURL: fixture.cache).scan(sources: [fixture.source])
        var oldCache = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cache)) as? [String: Any])
        var oldFiles = try XCTUnwrap(oldCache["files"] as? [String: Any])
        let rolloutKey = try XCTUnwrap(oldFiles.keys.first { canonicalPath($0) == canonicalPath(fixture.rollout.path) })
        var oldFile = try XCTUnwrap(oldFiles[rolloutKey] as? [String: Any])
        oldFile["edits"] = ["old-outside-move": ["date": fixture.date(10).timeIntervalSinceReferenceDate, "workspace": fixture.project.path]]
        oldFiles[rolloutKey] = oldFile
        oldCache["files"] = oldFiles
        oldCache["version"] = 1
        try JSONSerialization.data(withJSONObject: oldCache).write(to: fixture.cache)

        let result = CodexActivityProvider(cacheURL: fixture.cache).scan(sources: [fixture.source])
        let project = try XCTUnwrap(result.projects.first)
        XCTAssertEqual(project.recordedEditCount, 0)
        XCTAssertNil(project.latestEdit)
        XCTAssertTrue(result.notices.contains { $0.contains("rebuilt once") })
        let rebuiltCache = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cache)) as? [String: Any])
        XCTAssertEqual(rebuiltCache["version"] as? Int, 4)
    }

    func testNestedWorkspaceRootIsPreservedWithoutATurnCwdChange() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let worktree = fixture.project.appendingPathComponent(".codex/worktrees/feature")
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let path = worktree.appendingPathComponent("source.swift").path
        try fixture.write(fixture.sessionLines(roots: [fixture.project.path, worktree.path]) + [
            fixture.fileChange("nested", status: "completed", files: [path: "add"], seconds: 10)
        ])
        let project = try XCTUnwrap(CodexActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.path, fixture.project.path)
        XCTAssertEqual(project.recordedEditCount, 1)
        XCTAssertEqual(project.latestEdit?.latestEditWorkspacePath, worktree.path)
    }

    func testChangesAcrossKnownWorkspacesAreOmitted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = fixture.project.appendingPathComponent(".codex/worktrees/first")
        let second = fixture.project.appendingPathComponent(".codex/worktrees/second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let originPath = fixture.project.appendingPathComponent("source.swift").path
        let firstPath = first.appendingPathComponent("source.swift").path
        let secondPath = second.appendingPathComponent("source.swift").path
        try fixture.write(fixture.sessionLines(roots: [fixture.project.path, first.path, second.path]) + [
            fixture.fileChange("origin-and-tree", status: "completed", files: [originPath: "update", firstPath: "update"], seconds: 10),
            fixture.fileChange("two-trees", status: "completed", files: [firstPath: "update", secondPath: "update"], seconds: 20),
            fixture.fileChange("cross-tree-move", status: "completed", files: [firstPath: "update"],
                moves: [firstPath: secondPath], seconds: 30)
        ])
        let project = try XCTUnwrap(CodexActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.recordedEditCount, 0)
        XCTAssertNil(project.latestEdit)
    }

    func testPartialLineSurvivesTheCacheAndSixDigitFractionsParse() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let path = fixture.project.appendingPathComponent("source.swift").path
        let change = try fixture.line(fixture.fileChange("pending", status: "completed", files: [path: "add"],
            timestamp: "2026-10-30T00:00:12.123456Z"))
        var initial = try fixture.line(fixture.sessionLines()[0])
        initial.append(change.prefix(change.count / 2))
        try initial.write(to: fixture.rollout)
        let provider = CodexActivityProvider(cacheURL: fixture.cache)
        XCTAssertNil(provider.scan(sources: [fixture.source]).projects[0].latestEdit)
        try fixture.appendData(Data(change.suffix(from: change.count / 2)))
        let result = CodexActivityProvider(cacheURL: fixture.cache).scan(sources: [fixture.source])
        XCTAssertEqual(result.projects[0].recordedEditCount, 1)
        let expected = try XCTUnwrap(RecordedDate.parse("2026-10-30T00:00:12.123456Z"))
        XCTAssertEqual(result.projects[0].latestEdit?.latestEdit, expected)
    }

    func testMissingHomeIsANotice() {
        let source = AgentSource(id: "codex", name: "Codex", configDirectory: "/tmp/agent-trail-missing-codex-\(UUID().uuidString)", assistant: .codex)
        let result = CodexActivityProvider().scan(sources: [source])
        XCTAssertTrue(result.projects.isEmpty)
        XCTAssertTrue(result.notices.contains { $0.contains("no local Codex home") })
    }

    func testDuplicateSessionIDCountsOnce() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let lines = fixture.sessionLines()
        try fixture.write(lines)
        try fixture.write(lines, to: fixture.root.appendingPathComponent("archived_sessions/2026/10/30/rollout-same.jsonl"))
        let project = try XCTUnwrap(CodexActivityProvider().scan(sources: [fixture.source]).projects.first)
        XCTAssertEqual(project.sessionCount, 1)
    }

    func testParentWorkspaceUsesTheOneCheckoutContainingEveryConfirmedTarget() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.git("repository")
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("repo-edit", status: "completed", files: [repository.appendingPathComponent("Sources/main.swift").path: "add"], seconds: 10)
        ])
        let result = CodexActivityProvider().scan(sources: [fixture.source])
        let project = try XCTUnwrap(result.projects.first)
        XCTAssertEqual(project.path, repository.path)
        XCTAssertEqual(project.recordedEditCount, 1)
        XCTAssertEqual(project.sessionCount, 1)
        XCTAssertEqual(project.latestEdit?.latestEditWorkspacePath, fixture.project.path)
        XCTAssertEqual(result.sessionProjects.count, 1)
        XCTAssertEqual(result.sessionProjects.first?.recordedWorkspace, fixture.project.path)
        XCTAssertEqual(result.sessionProjects.first?.projectPath, repository.path)
        XCTAssertEqual(result.sessionProjects.first?.sessionID, "session-1")
    }

    func testMetadataDoesNotGuessAChildRepositoryFromFolderContents() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.git("repository")
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("repo-edit", status: "completed", files: [repository.appendingPathComponent("main.swift").path: "add"], seconds: 10)
        ])
        let metadata = CodexActivityProvider().metadata(sources: [fixture.source])
        XCTAssertEqual(metadata.projects.first?.path, fixture.project.path)
        XCTAssertTrue(metadata.sessionProjects.isEmpty)
        XCTAssertNil(metadata.projects.first?.latestEdit)
    }

    func testDifferentRecordedSubfoldersOfOneCheckoutMergeWithSeparateSessions() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.git("repository")
        let sourceDirectory = repository.appendingPathComponent("Sources")
        let testDirectory = repository.appendingPathComponent("Tests")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        try fixture.write(fixture.sessionLines(cwd: sourceDirectory.path) + [
            fixture.fileChange("source-edit", status: "completed", files: [sourceDirectory.appendingPathComponent("main.swift").path: "add"], seconds: 10)
        ])
        try fixture.write(fixture.sessionLines(cwd: testDirectory.path, sessionID: "session-2") + [
            fixture.fileChange("test-edit", status: "completed", files: [testDirectory.appendingPathComponent("main.swift").path: "add"], seconds: 20)
        ], to: fixture.root.appendingPathComponent("sessions/rollout-second.jsonl"))
        let result = CodexActivityProvider().scan(sources: [fixture.source])
        XCTAssertEqual(result.projects.count, 1)
        XCTAssertEqual(result.projects.first?.path, repository.path)
        XCTAssertEqual(result.projects.first?.sessionCount, 2)
        XCTAssertEqual(result.projects.first?.recordedEditCount, 2)
        XCTAssertEqual(result.projects.first?.latestEdit?.latestEditWorkspacePath, testDirectory.path)
        XCTAssertEqual(result.sessionProjects.count, 2)
    }

    func testSessionTouchingTwoCheckoutsCountsEachEditWhereItLanded() throws {
        // Each edit belongs to the checkout it physically landed in. With two
        // checkouts there is no single home, so the session stays where it began.
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.git("first")
        let second = try fixture.git("second")
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("first-edit", status: "completed", files: [first.appendingPathComponent("main.swift").path: "add"], seconds: 10),
            fixture.fileChange("second-edit", status: "completed", files: [second.appendingPathComponent("main.swift").path: "add"], seconds: 20)
        ])
        let result = CodexActivityProvider().scan(sources: [fixture.source])
        let byPath = Dictionary(uniqueKeysWithValues: result.projects.map { ($0.path, $0) })
        XCTAssertEqual(byPath[first.path]?.recordedEditCount, 1)
        XCTAssertEqual(byPath[second.path]?.recordedEditCount, 1)
        XCTAssertEqual(byPath[first.path]?.sessionCount, 0)
        XCTAssertEqual(byPath[fixture.project.path]?.sessionCount, 1)
        XCTAssertEqual(byPath[fixture.project.path]?.recordedEditCount, 0)
        XCTAssertTrue(result.sessionProjects.isEmpty)
    }

    func testAppendingASecondCheckoutReturnsTheSessionButKeepsEachEdit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.git("first")
        let second = try fixture.git("second")
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("first-edit", status: "completed", files: [first.appendingPathComponent("main.swift").path: "add"], seconds: 10)
        ])
        let provider = CodexActivityProvider(cacheURL: fixture.cache)
        let initial = provider.scan(sources: [fixture.source])
        XCTAssertEqual(initial.projects.map(\.path), [first.path])
        XCTAssertEqual(initial.sessionProjects.first?.projectPath, first.path)
        try fixture.append([fixture.fileChange("second-edit", status: "completed", files: [second.appendingPathComponent("main.swift").path: "add"], seconds: 20)])
        let rescanned = provider.scan(sources: [fixture.source])
        let byPath = Dictionary(uniqueKeysWithValues: rescanned.projects.map { ($0.path, $0) })
        XCTAssertEqual(byPath[fixture.project.path]?.sessionCount, 1)
        XCTAssertEqual(byPath[first.path]?.recordedEditCount, 1)
        XCTAssertEqual(byPath[second.path]?.recordedEditCount, 1)
        XCTAssertTrue(rescanned.sessionProjects.isEmpty)
        let reloaded = CodexActivityProvider(cacheURL: fixture.cache).scan(sources: [fixture.source])
        XCTAssertEqual(Set(reloaded.projects.map(\.path)), Set(rescanned.projects.map(\.path)))
    }

    func testDuplicateRolloutsAggregateAllEvidenceBeforeChoosingTheSessionHome() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let first = try fixture.git("first")
        let second = try fixture.git("second")
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("first-edit", status: "completed", files: [first.appendingPathComponent("main.swift").path: "add"], seconds: 10)
        ])
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("second-edit", status: "completed", files: [second.appendingPathComponent("main.swift").path: "add"], seconds: 20)
        ], to: fixture.root.appendingPathComponent("archived_sessions/rollout-copy.jsonl"))
        let result = CodexActivityProvider().scan(sources: [fixture.source])
        let byPath = Dictionary(uniqueKeysWithValues: result.projects.map { ($0.path, $0) })
        XCTAssertEqual(byPath[fixture.project.path]?.sessionCount, 1)
        XCTAssertEqual(result.projects.reduce(0) { $0 + $1.sessionCount }, 1)
        XCTAssertEqual(byPath[first.path]?.recordedEditCount, 1)
        XCTAssertEqual(byPath[second.path]?.recordedEditCount, 1)
        XCTAssertTrue(result.sessionProjects.isEmpty)
    }

    func testPreviousCacheVersionRebuildsRawEvidence() throws {
        // Version 3 dropped edits through links and to moved paths while
        // parsing. Version 4 keeps recorded evidence and decides when folding.
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.git("repository")
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("repo-edit", status: "completed", files: [repository.appendingPathComponent("main.swift").path: "add"], seconds: 10)
        ])
        _ = CodexActivityProvider(cacheURL: fixture.cache).scan(sources: [fixture.source])
        var cache = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cache)) as? [String: Any])
        cache["version"] = 3
        var cachedFiles = try XCTUnwrap(cache["files"] as? [String: [String: Any]])
        for key in cachedFiles.keys {
            var file = try XCTUnwrap(cachedFiles[key])
            file["edits"] = [String: Any]()
            cachedFiles[key] = file
        }
        cache["files"] = cachedFiles
        try JSONSerialization.data(withJSONObject: cache).write(to: fixture.cache)
        let result = CodexActivityProvider(cacheURL: fixture.cache).scan(sources: [fixture.source])
        XCTAssertEqual(result.projects.first?.path, repository.path)
        XCTAssertEqual(result.projects.first?.recordedEditCount, 1)
        XCTAssertTrue(result.notices.contains { $0.contains("rebuilt once") })
        let rebuilt = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cache)) as? [String: Any])
        XCTAssertEqual(rebuilt["version"] as? Int, 4)
    }

    func testSymlinkedMoveGroupsOldAndNewTargetsWithoutRegistration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oldRepository = try fixture.git("old-repository")
        let newRepository = fixture.root.appendingPathComponent("Dev/current-repository")
        try FileManager.default.createDirectory(at: newRepository.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: oldRepository, to: newRepository)
        try FileManager.default.createSymbolicLink(at: oldRepository, withDestinationURL: newRepository)
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("old-path", status: "completed", files: [oldRepository.appendingPathComponent("old.swift").path: "add"], seconds: 10),
            fixture.fileChange("new-path", status: "completed", files: [newRepository.appendingPathComponent("new.swift").path: "add"], seconds: 20)
        ])
        let provider = CodexActivityProvider(cacheURL: fixture.cache)
        let result = provider.scan(sources: [fixture.source])
        XCTAssertEqual(result.projects.map(\.path), [newRepository.path])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 2)
        XCTAssertEqual(result.projects.first?.sessionCount, 1)
        XCTAssertEqual(result.projects.first?.latestEdit?.latestEditWorkspacePath, fixture.project.path)
        XCTAssertEqual(result.sessionProjects.first?.recordedWorkspace, fixture.project.path)
        XCTAssertEqual(result.sessionProjects.first?.projectPath, newRepository.path)
        // The cache keeps the recorded spelling, so a learned location can
        // regroup it later without reading the log again.
        let cached = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cache)) as? [String: Any])
        let directories = ((cached["files"] as? [String: [String: Any]])?.values.compactMap { $0["edits"] as? [String: [String: Any]] } ?? [])
            .flatMap(\.values).flatMap { ($0["targetDirectories"] as? [String]) ?? [] }
        XCTAssertTrue(directories.contains(oldRepository.path))
        XCTAssertTrue(directories.contains(newRepository.path))
    }

    func testEditThroughASymlinkCountsWhereTheWriteLanded() throws {
        // A link inside the launch folder pointing at another checkout is where
        // the write physically landed; that checkout gets the edit.
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outsideRepository = try fixture.git("outside", in: fixture.root)
        let link = fixture.project.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideRepository)
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("through-link", status: "completed", files: [link.appendingPathComponent("main.swift").path: "add"], seconds: 10)
        ])
        let result = CodexActivityProvider().scan(sources: [fixture.source])
        XCTAssertEqual(result.projects.map(\.path), [outsideRepository.path])
        XCTAssertEqual(result.projects.first?.recordedEditCount, 1)
        XCTAssertEqual(result.sessionProjects.first?.projectPath, outsideRepository.path)
    }

    func testScratchFilesBesideACheckoutStayWithTheLaunchFolder() throws {
        // A session started in a plain folder that mostly edits one checkout
        // belongs to that checkout. Notes it wrote outside any checkout are
        // still counted, on the launch folder, and never inflate the checkout.
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.git("repository")
        let notes = fixture.project.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("code", status: "completed", files: [repository.appendingPathComponent("Sources/main.swift").path: "add"], seconds: 10),
            fixture.fileChange("more-code", status: "completed", files: [repository.appendingPathComponent("README.md").path: "update"], seconds: 20),
            fixture.fileChange("notes", status: "completed", files: [notes.appendingPathComponent("release-notes.md").path: "add"], seconds: 30)
        ])
        let result = CodexActivityProvider().scan(sources: [fixture.source])
        let byPath = Dictionary(uniqueKeysWithValues: result.projects.map { ($0.path, $0) })
        XCTAssertEqual(byPath[repository.path]?.sessionCount, 1)
        XCTAssertEqual(byPath[repository.path]?.recordedEditCount, 2)
        XCTAssertEqual(byPath[fixture.project.path]?.sessionCount, 0)
        XCTAssertEqual(byPath[fixture.project.path]?.recordedEditCount, 1)
        XCTAssertEqual(result.sessionProjects.first?.projectPath, repository.path)
    }

    func testSpawnedThreadWithoutRepositoryEditsJoinsItsParentsCheckout() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.git("repository")
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("code", status: "completed", files: [repository.appendingPathComponent("main.swift").path: "add"], seconds: 10)
        ])
        try fixture.write(fixture.sessionLines(sessionID: "reviewer", parent: "session-1"),
                          to: fixture.root.appendingPathComponent("sessions/rollout-reviewer.jsonl"))
        let other = fixture.root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try fixture.write(fixture.sessionLines(cwd: other.path, sessionID: "unrelated", parent: "session-1"),
                          to: fixture.root.appendingPathComponent("sessions/rollout-unrelated.jsonl"))
        let result = CodexActivityProvider().scan(sources: [fixture.source])
        let byPath = Dictionary(uniqueKeysWithValues: result.projects.map { ($0.path, $0) })
        XCTAssertEqual(byPath[repository.path]?.sessionCount, 2)
        XCTAssertNil(byPath[fixture.project.path])
        // A thread started somewhere else is not pulled in by its parent.
        XCTAssertEqual(byPath[other.path]?.sessionCount, 1)
        XCTAssertEqual(Set(result.sessionProjects.map(\.sessionID)), ["session-1", "reviewer"])
    }

    func testEditsUnderAMissingFolderAreReportedForLocating() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let vanished = fixture.project.appendingPathComponent("outputs/AgentTrail")
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("a", status: "completed", files: [vanished.appendingPathComponent("Sources/a.swift").path: "add"], seconds: 10),
            fixture.fileChange("b", status: "completed", files: [vanished.appendingPathComponent("README.md").path: "add"], seconds: 20)
        ])
        let result = CodexActivityProvider().scan(sources: [fixture.source])
        XCTAssertEqual(result.projects.first?.path, fixture.project.path)
        XCTAssertEqual(result.projects.first?.recordedEditCount, 2)
        let missing = try XCTUnwrap(result.missingFolders.first)
        XCTAssertEqual(result.missingFolders.count, 1)
        XCTAssertEqual(missing.path, fixture.project.appendingPathComponent("outputs").path)
        XCTAssertEqual(missing.projectPath, fixture.project.path)
        XCTAssertEqual(missing.editCount, 2)
    }

    func testQuickListingUsesCachedEvidenceSoSessionsDoNotJumpBetweenProjects() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let repository = try fixture.git("repository")
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("code", status: "completed", files: [repository.appendingPathComponent("main.swift").path: "add"], seconds: 10)
        ])
        _ = CodexActivityProvider(cacheURL: fixture.cache).scan(sources: [fixture.source])
        let relaunched = CodexActivityProvider(cacheURL: fixture.cache).metadata(sources: [fixture.source])
        XCTAssertEqual(relaunched.projects.map(\.path), [repository.path])
        XCTAssertEqual(relaunched.sessionProjects.first?.projectPath, repository.path)
    }

    func testLearnedEarlierLocationRegroupsWithoutReparsing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oldRepository = try fixture.git("old-repository")
        try fixture.write(fixture.sessionLines() + [
            fixture.fileChange("before-move", status: "completed", files: [oldRepository.appendingPathComponent("a.swift").path: "add"], seconds: 10)
        ])
        let provider = CodexActivityProvider(cacheURL: fixture.cache)
        XCTAssertEqual(provider.scan(sources: [fixture.source]).projects.map(\.path), [oldRepository.path])
        let newRepository = fixture.root.appendingPathComponent("Dev/moved")
        try FileManager.default.createDirectory(at: newRepository.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: oldRepository, to: newRepository)
        var locations = ProjectLocationRegistry()
        try locations.register(path: newRepository.path, previousPaths: [oldRepository.path])
        provider.projectLocations = locations
        let rescanned = provider.scan(sources: [fixture.source])
        XCTAssertEqual(rescanned.projects.map(\.path), [newRepository.path])
        XCTAssertEqual(rescanned.projects.first?.recordedEditCount, 1)
        XCTAssertFalse(rescanned.notices.contains { $0.contains("rebuilt") })
    }
}

private final class Fixture {
    let root: URL
    let project: URL
    let rollout: URL
    let cache: URL
    let source: AgentSource
    let base: Date

    init() throws {
        root = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory.appendingPathComponent("agent-trail-codex-\(UUID().uuidString)", isDirectory: true).path), isDirectory: true)
        project = root.appendingPathComponent("project", isDirectory: true)
        rollout = root.appendingPathComponent("sessions/2026/10/30/rollout-session.jsonl")
        cache = root.appendingPathComponent("cache/activity-cache-codex.json")
        source = AgentSource(id: "codex", name: "Codex", configDirectory: root.path, assistant: .codex)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        base = try XCTUnwrap(formatter.date(from: "2026-10-30T00:00:00Z"))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func date(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    func stamp(_ seconds: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date(seconds))
    }

    func sessionLines(timestamp: String? = nil, roots: [String]? = nil, cwd: String? = nil, sessionID: String = "session-1",
                      parent: String? = nil) -> [[String: Any]] {
        var payload: [String: Any] = [
            "id": sessionID,
            "timestamp": timestamp ?? stamp(0),
            "cwd": cwd ?? project.path,
            "runtime_workspace_roots": roots ?? [cwd ?? project.path]
        ]
        if let parent { payload["parent_thread_id"] = parent }
        return [["timestamp": timestamp ?? stamp(0), "ordinal": 1, "type": "session_meta", "payload": payload]]
    }

    func git(_ name: String, in parent: URL? = nil) throws -> URL {
        let repository = (parent ?? project).appendingPathComponent(name)
        let metadata = repository.appendingPathComponent(".git")
        try FileManager.default.createDirectory(at: metadata.appendingPathComponent("objects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metadata.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: metadata.appendingPathComponent("HEAD"))
        return repository
    }

    func turn(_ cwd: String) -> [String: Any] {
        ["timestamp": stamp(1), "ordinal": 2, "type": "turn_context", "payload": ["cwd": cwd, "turn_id": "turn-1"]]
    }

    func fileChange(_ id: String, status: String, files: [String: String], moves: [String: String] = [:], seconds: TimeInterval = 0, timestamp: String? = nil) -> [String: Any] {
        var changes: [String: Any] = [:]
        for (path, kind) in files {
            var change = ["type": kind, "unified_diff": "PRIVATE_DIFF_MARKER"]
            if let destination = moves[path] { change["move_path"] = destination }
            changes[path] = change
        }
        let when = timestamp ?? stamp(seconds)
        var payload: [String: Any] = [
            "type": "item_completed",
            "item": ["type": "FileChange", "id": id, "status": status, "changes": changes]
        ]
        if timestamp == nil {
            payload["completed_at_ms"] = Int(date(seconds).timeIntervalSince1970 * 1000)
        }
        return ["timestamp": when, "ordinal": 3, "type": "event_msg", "payload": payload]
    }

    func shell(seconds: TimeInterval) -> [String: Any] {
        ["timestamp": stamp(seconds), "ordinal": 4, "type": "response_item",
         "payload": ["type": "custom_tool_call", "name": "exec", "input": "PRIVATE_COMMAND_MARKER"]]
    }

    func line(_ object: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        return data
    }

    func write(_ objects: [[String: Any]], to url: URL? = nil) throws {
        var data = Data()
        for object in objects { data.append(try line(object)) }
        let destination = url ?? rollout
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination)
    }

    func append(_ objects: [[String: Any]]) throws {
        var data = try Data(contentsOf: rollout)
        for object in objects { data.append(try line(object)) }
        try data.write(to: rollout)
    }

    func appendData(_ data: Data) throws {
        let handle = try FileHandle(forWritingTo: rollout)
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.close()
    }
}
