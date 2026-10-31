import Foundation
import XCTest
@testable import AgentTrailCore

final class ProjectLocationRegistryTests: XCTestCase {
    func testObservedCheckoutFollowsAPlainMoveThroughItsIdentity() throws {
        let fixture = try LocationFixture()
        defer { fixture.remove() }
        let original = try fixture.repository("Documents/outputs/AgentTrail")
        var registry = ProjectLocationRegistry()
        XCTAssertTrue(registry.observe(checkout: original.path, now: fixture.now))
        XCTAssertFalse(registry.observe(checkout: original.path, now: fixture.now))
        let moved = fixture.root.appendingPathComponent("Dev/agent-trail")
        try fixture.move(original, to: moved)
        XCTAssertTrue(registry.refresh(now: fixture.now))
        let location = try XCTUnwrap(registry.locations.first)
        XCTAssertEqual(location.currentPath, moved.path)
        XCTAssertEqual(location.previousPaths, [original.path])
        XCTAssertEqual(location.previousLocations.first?.origin, .move)
        XCTAssertTrue(location.isPresent)
        XCTAssertEqual(registry.rewrite(original.appendingPathComponent("Sources/a.swift").path),
                       moved.appendingPathComponent("Sources/a.swift").path)
        XCTAssertEqual(registry.rewrite(fixture.root.appendingPathComponent("Documents/outputs/AgentTrailOther/x").path),
                       fixture.root.appendingPathComponent("Documents/outputs/AgentTrailOther/x").path)
    }

    func testSameFolderSeenThroughAnotherSpellingIsNotAMove() throws {
        let fixture = try LocationFixture()
        defer { fixture.remove() }
        let checkout = try fixture.repository("repo")
        var registry = ProjectLocationRegistry()
        registry.observe(checkout: checkout.path, now: fixture.now)
        // /var and /private/var name the same folder; neither is a move.
        let alternate = checkout.path.hasPrefix("/private/") ? String(checkout.path.dropFirst("/private".count))
            : "/private" + checkout.path
        XCTAssertFalse(registry.observe(checkout: alternate, now: fixture.now))
        XCTAssertEqual(registry.locations.map(\.currentPath), [checkout.path])
        XCTAssertTrue(registry.locations[0].previousLocations.isEmpty)
    }

    func testNewFolderAtAnEarlierPathOwnsOnlyLaterEvidence() throws {
        let fixture = try LocationFixture()
        defer { fixture.remove() }
        let original = try fixture.repository("old/AgentTrail")
        var registry = ProjectLocationRegistry()
        let seen = Date().addingTimeInterval(-3_600)
        registry.observe(checkout: original.path, now: seen)
        let moved = fixture.root.appendingPathComponent("Dev/agent-trail")
        try fixture.move(original, to: moved)
        registry.refresh(now: Date().addingTimeInterval(-120))
        let before = Date().addingTimeInterval(-600)
        // A fresh clone now occupies the earlier path.
        _ = try fixture.repository("old/AgentTrail")
        registry.refresh(now: Date())
        let recorded = original.appendingPathComponent("a.swift").path
        XCTAssertEqual(registry.rewrite(recorded, at: before), moved.appendingPathComponent("a.swift").path)
        XCTAssertEqual(registry.rewrite(recorded, at: Date().addingTimeInterval(60)), recorded)
        XCTAssertEqual(registry.rewrite(recorded, at: nil), recorded)
        // The clone gets its own entry, and the moved checkout keeps its history.
        XCTAssertTrue(registry.observe(checkout: original.path, now: Date()))
        XCTAssertEqual(Set(registry.locations.map(\.currentPath)), [original.path, moved.path])
        XCTAssertEqual(registry.location(forCurrentPath: moved.path)?.previousPaths, [original.path])
    }

    func testOlderFolderMovedIntoAnEarlierPathDoesNotClaimTheMovedCheckoutsHistory() throws {
        // A folder moved in keeps its original creation date. Its claim on the
        // path starts when the moved checkout was seen leaving, not earlier.
        let fixture = try LocationFixture()
        defer { fixture.remove() }
        let older = try fixture.repository("archive/older")
        let checkout = try fixture.repository("work/app")
        var registry = ProjectLocationRegistry()
        registry.observe(checkout: checkout.path, now: Date().addingTimeInterval(-7_200))
        let leftAt = Date().addingTimeInterval(-600)
        try fixture.move(checkout, to: fixture.root.appendingPathComponent("Dev/app"))
        registry.refresh(now: leftAt)
        try fixture.move(older, to: checkout)
        registry.refresh(now: Date())
        let recorded = checkout.appendingPathComponent("a.swift").path
        let movedPath = canonicalPath(fixture.root.appendingPathComponent("Dev/app").path)
        XCTAssertEqual(registry.rewrite(recorded, at: leftAt.addingTimeInterval(-60)), movedPath + "/a.swift")
        XCTAssertEqual(registry.rewrite(recorded, at: Date().addingTimeInterval(60)), recorded)
    }

    func testSwappedFoldersAreBothFollowedWhateverTheirOrder() throws {
        let fixture = try LocationFixture()
        defer { fixture.remove() }
        let first = try fixture.repository("d/app")
        let second = try fixture.repository("d/app-new")
        for order in [[first, second], [second, first]] {
            var registry = ProjectLocationRegistry()
            for checkout in order { registry.observe(checkout: checkout.path, now: Date()) }
            // app → app-old, then app-new → app.
            let old = fixture.root.appendingPathComponent("d/app-old")
            try FileManager.default.moveItem(at: first, to: old)
            try FileManager.default.moveItem(at: second, to: first)
            registry.refresh(now: Date())
            XCTAssertEqual(Set(registry.locations.map(\.currentPath)), [canonicalPath(old.path), first.path])
            XCTAssertEqual(registry.locations.count, 2)
            // Restore for the second ordering.
            try FileManager.default.moveItem(at: first, to: second)
            try FileManager.default.moveItem(at: old, to: first)
        }
    }

    func testFolderMovedToTheTrashIsMissingNotMoved() throws {
        let fixture = try LocationFixture()
        defer { fixture.remove() }
        let checkout = try fixture.repository("repo")
        var registry = ProjectLocationRegistry()
        registry.observe(checkout: checkout.path, now: Date())
        try fixture.move(checkout, to: fixture.root.appendingPathComponent(".Trash/repo"))
        registry.refresh(now: Date())
        XCTAssertEqual(registry.locations.first?.currentPath, checkout.path)
        XCTAssertEqual(registry.locations.first?.isPresent, false)
    }

    func testNewRepositoryCreatedWhileTheAppWasClosedKeepsItsOwnHistory() throws {
        // The move is noticed only at the next launch; the new repository's own
        // records from before that launch must stay with it.
        let fixture = try LocationFixture()
        defer { fixture.remove() }
        let app = try fixture.repository("Dev/app")
        var registry = ProjectLocationRegistry()
        registry.observe(checkout: app.path, now: Date().addingTimeInterval(-86_400))
        registry.refresh(now: Date().addingTimeInterval(-86_000))
        try fixture.move(app, to: fixture.root.appendingPathComponent("Dev/app-legacy"))
        let createdNew = Date()
        _ = try fixture.repository("Dev/app")
        let launch = Date().addingTimeInterval(3_600)
        registry.refresh(now: launch)
        let recorded = app.appendingPathComponent("a.swift").path
        let legacy = canonicalPath(fixture.root.appendingPathComponent("Dev/app-legacy").path)
        XCTAssertEqual(registry.rewrite(recorded, at: createdNew.addingTimeInterval(60)), recorded)
        XCTAssertEqual(registry.rewrite(recorded, at: Date().addingTimeInterval(-86_200)), legacy + "/a.swift")
    }

    func testShadowOutlivesTheOccupantSoItsHistoryIsNotAbsorbed() throws {
        let fixture = try LocationFixture()
        defer { fixture.remove() }
        let path = try fixture.repository("p")
        var registry = ProjectLocationRegistry()
        registry.observe(checkout: path.path, now: Date().addingTimeInterval(-7_200))
        try fixture.move(path, to: fixture.root.appendingPathComponent("x"))
        registry.refresh(now: Date().addingTimeInterval(-3_600))
        _ = try fixture.repository("p")
        registry.refresh(now: Date())
        registry.observe(checkout: path.path, now: Date())
        let occupantDate = Date().addingTimeInterval(60)
        // The occupant leaves for /y; its records at /p stay its own.
        try fixture.move(path, to: fixture.root.appendingPathComponent("y"))
        registry.refresh(now: Date().addingTimeInterval(120))
        let recorded = path.appendingPathComponent("a.swift").path
        let y = canonicalPath(fixture.root.appendingPathComponent("y").path)
        let x = canonicalPath(fixture.root.appendingPathComponent("x").path)
        XCTAssertEqual(registry.rewrite(recorded, at: occupantDate), y + "/a.swift")
        XCTAssertEqual(registry.rewrite(recorded, at: Date().addingTimeInterval(-5_400)), x + "/a.swift")
        // With the occupant deleted instead, its records do not fall to /x.
        var deleted = registry
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("y"))
        deleted.refresh(now: Date().addingTimeInterval(180))
        XCTAssertNotEqual(deleted.rewrite(recorded, at: occupantDate), x + "/a.swift")
        XCTAssertNoThrow(try deleted.save(to: fixture.root.appendingPathComponent("support/locations.json")))
    }

    func testLinkIntoAnOccupiedEarlierPathShadows() throws {
        let fixture = try LocationFixture()
        defer { fixture.remove() }
        let app = try fixture.repository("Dev/app")
        let link = fixture.root.appendingPathComponent("outputs/App")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        var registry = ProjectLocationRegistry()
        registry.observe(link: link.path, checkout: app.path, now: Date().addingTimeInterval(-7_200))
        registry.refresh(now: Date().addingTimeInterval(-7_100))
        try fixture.move(app, to: fixture.root.appendingPathComponent("Dev/app2"))
        registry.refresh(now: Date().addingTimeInterval(-3_600))
        _ = try fixture.repository("Dev/app")   // a new clone where the link points
        registry.refresh(now: Date())
        let recorded = link.appendingPathComponent("a.swift").path
        XCTAssertEqual(registry.rewrite(recorded, at: Date().addingTimeInterval(60)), recorded)
    }

    func testRetargetedLinkStopsApplyingToLaterEvidence() throws {
        let fixture = try LocationFixture()
        defer { fixture.remove() }
        let first = try fixture.repository("first")
        let second = try fixture.repository("second")
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: first)
        var registry = ProjectLocationRegistry()
        XCTAssertTrue(registry.observe(link: link.path, checkout: first.path, now: Date().addingTimeInterval(-3_600)))
        registry.refresh(now: Date())
        XCTAssertNil(registry.locations.first?.previousLocations.first?.shadowedSince)
        let before = Date().addingTimeInterval(-60)
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: second)
        registry.refresh(now: Date())
        let recorded = link.appendingPathComponent("a.swift").path
        XCTAssertEqual(registry.rewrite(recorded, at: before), first.appendingPathComponent("a.swift").path)
        XCTAssertEqual(registry.rewrite(recorded, at: Date().addingTimeInterval(60)), recorded)
    }

    func testLeftoverLinkThatDanglesAfterASecondMoveStillApplies() throws {
        let fixture = try LocationFixture()
        defer { fixture.remove() }
        let checkout = try fixture.repository("Dev/agent-trail")
        let link = fixture.root.appendingPathComponent("outputs/AgentTrail")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: checkout)
        var registry = ProjectLocationRegistry()
        registry.observe(link: link.path, checkout: checkout.path, now: Date().addingTimeInterval(-3_600))
        let next = fixture.root.appendingPathComponent("Projects/agent-trail")
        try fixture.move(checkout, to: next)
        registry.refresh(now: Date())
        let location = try XCTUnwrap(registry.location(forCurrentPath: canonicalPath(next.path)))
        XCTAssertTrue(location.previousLocations.allSatisfy { $0.shadowedSince == nil })
        XCTAssertEqual(registry.rewrite(link.path + "/Sources/a.swift", at: Date()), canonicalPath(next.path) + "/Sources/a.swift")
        // A dangling link may also be named as an earlier location by hand.
        var manual = ProjectLocationRegistry()
        try manual.register(path: next.path, previousPaths: [link.path])
    }

    func testLinkPutWhereADeletedCheckoutWasIsAReplacement() throws {
        let fixture = try LocationFixture()
        defer { fixture.remove() }
        let checkout = try fixture.repository("old/app")
        let other = try fixture.repository("other")
        var registry = ProjectLocationRegistry()
        let earlier = fixture.root.appendingPathComponent("older/app").path
        try registry.register(path: checkout.path, previousPaths: [earlier])
        try FileManager.default.removeItem(at: checkout)
        try FileManager.default.createSymbolicLink(at: checkout, withDestinationURL: other)
        registry.refresh(now: Date())
        XCTAssertEqual(registry.locations.first?.isReplaced, true)
        XCTAssertEqual(registry.rewrite(earlier + "/a.swift", at: Date().addingTimeInterval(-60)), earlier + "/a.swift")
    }

    func testIdentitySurvivesADeviceNumberChange() {
        let created = Date(timeIntervalSince1970: 1_700_000_000.123456)
        XCTAssertEqual(ProjectFileIdentity(device: 16_777_230, inode: 42, created: created),
                       ProjectFileIdentity(device: 16_777_241, inode: 42, created: created))
        XCTAssertNotEqual(ProjectFileIdentity(device: 1, inode: 42, created: created),
                          ProjectFileIdentity(device: 1, inode: 43, created: created))
    }

    func testLoadedCatalogKnowsWhichFoldersAreMissingBeforeTheFirstScan() throws {
        let fixture = try LocationFixture()
        defer { fixture.remove() }
        let checkout = try fixture.repository("repo")
        var registry = ProjectLocationRegistry()
        registry.observe(checkout: checkout.path, now: Date())
        let url = fixture.root.appendingPathComponent("support/project-locations.json")
        try registry.save(to: url)
        try FileManager.default.removeItem(at: checkout)
        let loaded = try ProjectLocationRegistry.load(from: url)
        XCTAssertEqual(loaded.locations.first?.isPresent, false)
    }

    func testLinksToSubfoldersOrOverlappingPathsAreNotEarlierLocations() throws {
        let fixture = try LocationFixture()
        defer { fixture.remove() }
        let checkout = try fixture.repository("repo")
        var registry = ProjectLocationRegistry()
        XCTAssertFalse(registry.observe(link: checkout.appendingPathComponent("inner").path, checkout: checkout.path, now: fixture.now))
        XCTAssertFalse(registry.observe(link: fixture.root.path, checkout: checkout.path, now: fixture.now))
        XCTAssertFalse(registry.observe(link: "/", checkout: checkout.path, now: fixture.now))
        XCTAssertTrue(registry.locations.allSatisfy { $0.previousLocations.isEmpty })
    }

    func testManualRegistrationRequiresACheckoutAndAVacatedEarlierPath() throws {
        let fixture = try LocationFixture()
        defer { fixture.remove() }
        let checkout = try fixture.repository("Dev/agent-trail")
        let plain = fixture.root.appendingPathComponent("plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        var registry = ProjectLocationRegistry()
        XCTAssertThrowsError(try registry.register(path: plain.path, previousPaths: [])) {
            XCTAssertEqual($0 as? LocationError, .notRepository)
        }
        XCTAssertThrowsError(try registry.register(path: checkout.path, previousPaths: [plain.path])) {
            XCTAssertEqual($0 as? LocationError, .previousLocationStillExists)
        }
        XCTAssertThrowsError(try registry.register(path: checkout.path, previousPaths: [checkout.appendingPathComponent("Sources").path])) {
            XCTAssertEqual($0 as? LocationError, .overlappingAlias)
        }
        let vanished = fixture.root.appendingPathComponent("Documents/outputs/AgentTrail").path
        try registry.register(path: checkout.path, previousPaths: [vanished])
        // An earlier path that would swallow another earlier path is refused.
        XCTAssertThrowsError(try registry.register(path: checkout.path,
            previousPaths: [fixture.root.appendingPathComponent("Documents").path])) {
            XCTAssertEqual($0 as? LocationError, .broaderThanEarlierLocation)
        }
        XCTAssertEqual(registry.locations.first?.previousLocations.first?.origin, .manual)
        XCTAssertEqual(registry.relocatedPath(vanished + "/Sources/a.swift"), checkout.path + "/Sources/a.swift")
        XCTAssertTrue(registry.forgetPreviousLocations(of: checkout.path))
        XCTAssertEqual(registry.relocatedPath(vanished + "/a.swift"), vanished + "/a.swift")
        XCTAssertEqual(registry.locations.map(\.currentPath), [checkout.path])
    }

    func testReplacedFolderDoesNotInheritEarlierLocations() throws {
        let fixture = try LocationFixture()
        defer { fixture.remove() }
        let checkout = try fixture.repository("repo")
        var registry = ProjectLocationRegistry()
        let earlier = fixture.root.appendingPathComponent("earlier").path
        try registry.register(path: checkout.path, previousPaths: [earlier])
        try FileManager.default.removeItem(at: checkout)
        _ = try fixture.repository("repo")
        registry.refresh(now: Date())
        XCTAssertEqual(registry.locations.first?.isReplaced, true)
        XCTAssertEqual(registry.rewrite(earlier + "/a.swift", at: fixture.now), earlier + "/a.swift")
        XCTAssertTrue(registry.observe(checkout: checkout.path, now: Date()))
        XCTAssertEqual(registry.locations.count, 1)
        XCTAssertTrue(registry.locations[0].previousLocations.isEmpty)
    }

    func testCatalogRoundTripsWithPrivatePermissionsAndExactIdentity() throws {
        let fixture = try LocationFixture()
        defer { fixture.remove() }
        let checkout = try fixture.repository("repo")
        var registry = ProjectLocationRegistry()
        try registry.register(path: checkout.path, previousPaths: [fixture.root.appendingPathComponent("gone").path])
        let url = fixture.root.appendingPathComponent("support/project-locations.json")
        try registry.save(to: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var loaded = try ProjectLocationRegistry.load(from: url)
        XCTAssertEqual(loaded.locations.map(\.previousPaths), registry.locations.map(\.previousPaths))
        // Folder identity must survive encoding exactly, or every reload would
        // look like a move and fire a bookmark lookup.
        XCTAssertFalse(loaded.refresh(now: Date()))
        XCTAssertEqual(loaded.locations.first?.isPresent, true)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("PRIVATE"))
    }

    func testUnreadableCatalogIsReportedAndNeverOverwritten() throws {
        let fixture = try LocationFixture()
        defer { fixture.remove() }
        let url = fixture.root.appendingPathComponent("support/project-locations.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let corrupt = Data("{ not json".utf8)
        try corrupt.write(to: url)
        let provider = CompositeActivityProvider(locationsURL: url)
        let result = provider.scan(sources: [])
        XCTAssertTrue(result.notices.contains { $0.contains("Project locations could not be read") })
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
        let checkout = try fixture.repository("repo")
        XCTAssertThrowsError(try provider.registerProjectLocation(path: checkout.path, previousPaths: []))
        XCTAssertEqual(try Data(contentsOf: url), corrupt)
    }
}

extension ProjectLocationRegistryTests {
    func testLocatingAFolderFindsTheEarlierRootFromRecordedSubfolders() throws {
        let fixture = try LocationFixture()
        defer { fixture.remove() }
        let chosen = try fixture.repository("Dev/agent-trail")
        try FileManager.default.createDirectory(at: chosen.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        let launch = fixture.root.appendingPathComponent("hey").path
        let missing = MissingFolder(sourceID: "codex", projectPath: launch, path: launch + "/outputs", editCount: 2,
            sampleDirectories: [launch + "/outputs/AgentTrail/Sources", launch + "/outputs/AgentTrail"])
        XCTAssertEqual(missing.previousRoot(forChosenFolder: chosen.path), launch + "/outputs/AgentTrail")
        let unrelated = try fixture.repository("Elsewhere/other")
        XCTAssertNil(missing.previousRoot(forChosenFolder: unrelated.path))
    }
}

final class LocationFixture {
    let root: URL
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        root = URL(fileURLWithPath: canonicalPath(FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-trail-locations-\(UUID().uuidString)").path), isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func repository(_ relative: String) throws -> URL {
        let checkout = root.appendingPathComponent(relative, isDirectory: true)
        let git = checkout.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: git.appendingPathComponent("objects"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: git.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: git.appendingPathComponent("HEAD"))
        return URL(fileURLWithPath: canonicalPath(checkout.path), isDirectory: true)
    }

    func move(_ source: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: destination)
    }
}
