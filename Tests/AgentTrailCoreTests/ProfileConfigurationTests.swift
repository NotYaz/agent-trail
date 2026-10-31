import Foundation
import XCTest
@testable import AgentTrailCore

final class ProfileConfigurationTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentTrail-profile-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
    }

    private var file: URL { temporary.appendingPathComponent("settings/profiles.json") }

    private func profile(id: String = "claude-work", config: String = "~/custom-claude",
                         desktop: String? = "~/Library/Application Support/Claude-Work") -> AgentSource {
        AgentSource(id: id, name: "Claude Work", configDirectory: config, userDataDirectory: desktop)
    }

    private func assertInvalid(_ configuration: ProfileConfiguration, containing text: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try configuration.validate(), file: file, line: line) { error in
            XCTAssertTrue(error.localizedDescription.contains(text), error.localizedDescription, file: file, line: line)
        }
    }

    func testMissingFileUsesPortableDefaultsWithoutCreatingAnything() throws {
        let configuration = try ProfileConfiguration.load(from: file)
        XCTAssertEqual(configuration, .defaults())
        XCTAssertEqual(configuration.refreshInterval, 15)
        XCTAssertEqual(configuration.sources.count, 4)
        XCTAssertEqual(configuration.sources[0].configDirectory, "~/.claude")
        XCTAssertEqual(configuration.sources[0].userDataDirectory, "~/Library/Application Support/Claude")
        XCTAssertEqual(configuration.sources[0].assistant, .claude)
        XCTAssertEqual(configuration.sources[2].assistant, .codex)
        XCTAssertEqual(configuration.sources[2].configDirectory, "~/.codex")
        XCTAssertNil(configuration.sources[2].userDataDirectory)
        XCTAssertEqual(configuration.sources[3].assistant, .grok)
        XCTAssertEqual(configuration.sources[3].configDirectory, "~/.grok")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        try configuration.validate()
    }

    func testRoundtripPreservesTildePathsAndUsesPrivatePermissions() throws {
        let original = ProfileConfiguration(sources: [profile()], refreshInterval: 42)
        try original.save(to: file)
        XCTAssertEqual(try ProfileConfiguration.load(from: file), original)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)
        XCTAssertEqual((fileAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertTrue(try String(contentsOf: file, encoding: .utf8).contains("~/custom-claude"))
    }

    func testSaveReplacesExistingConfigurationAndLeavesNoTemporaryFiles() throws {
        try ProfileConfiguration.defaults().save(to: file)
        let replacement = ProfileConfiguration(sources: [profile()], refreshInterval: 60)
        try replacement.save(to: file)
        XCTAssertEqual(try ProfileConfiguration.load(from: file), replacement)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path), ["profiles.json"])
    }

    func testInvalidSaveDoesNotReplaceExistingFile() throws {
        let valid = ProfileConfiguration.defaults()
        try valid.save(to: file)
        let invalid = ProfileConfiguration(sources: [], refreshInterval: 1)
        XCTAssertThrowsError(try invalid.save(to: file))
        XCTAssertEqual(try ProfileConfiguration.load(from: file), valid)
    }

    func testInvalidJSONFailsClosedWithActionablePath() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: file)
        XCTAssertThrowsError(try ProfileConfiguration.load(from: file)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Invalid JSON"))
            XCTAssertTrue(error.localizedDescription.contains(self.file.path))
            XCTAssertTrue(error.localizedDescription.contains("reload profiles"))
        }
    }

    func testValidJSONWithInvalidValuesFailsClosed() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = ProfileConfiguration(sources: [profile(config: "relative-path")])
        try JSONEncoder().encode(invalid).write(to: file)
        XCTAssertThrowsError(try ProfileConfiguration.load(from: file)) { error in
            XCTAssertTrue(error.localizedDescription.contains("configDirectory"))
        }
    }

    func testIntervalMayBeOmittedFromJSON() throws {
        let sourceData = try JSONEncoder().encode([profile()])
        let sourceJSON = String(decoding: sourceData, as: UTF8.self)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"sources\":\(sourceJSON)}".utf8).write(to: file)
        XCTAssertEqual(try ProfileConfiguration.load(from: file).refreshInterval, 15)
    }

    func testProfileCountBounds() throws {
        assertInvalid(ProfileConfiguration(sources: []), containing: "1 and 16")
        let sources = (0..<17).map { index in
            profile(id: "profile-\(index)", config: "/tmp/config-\(index)", desktop: "/tmp/desktop-\(index)")
        }
        assertInvalid(ProfileConfiguration(sources: sources), containing: "1 and 16")
        try ProfileConfiguration(sources: Array(sources.prefix(16))).validate()
    }

    func testRefreshIntervalBoundsAndNonfiniteValues() throws {
        for interval in [5.0, 15, 300] {
            try ProfileConfiguration(sources: [profile()], refreshInterval: interval).validate()
        }
        for interval in [4.99, 300.01, 0, -1, .infinity, -.infinity, .nan] {
            assertInvalid(ProfileConfiguration(sources: [profile()], refreshInterval: interval), containing: "5 and 300")
        }
    }

    func testIDsAreUniqueStableSlugs() throws {
        for id in ["", "Claude", "two words", "-claude", "claude-", "claude--work", "1claude", "../claude", String(repeating: "a", count: 65)] {
            assertInvalid(ProfileConfiguration(sources: [profile(id: id)]), containing: "id of up to 64")
        }
        assertInvalid(ProfileConfiguration(sources: [profile(), profile(config: "/tmp/other-config", desktop: "/tmp/other-desktop")]), containing: "Duplicate id")
        try ProfileConfiguration(sources: [profile(id: "claude-team-2")]).validate()
    }

    func testNamesAndBundleIdentifiersMustBeUsableLabels() throws {
        for name in ["", "  ", " Work", "Work\nMachine", String(repeating: "x", count: 81)] {
            var source = profile()
            source.name = name
            assertInvalid(ProfileConfiguration(sources: [source]), containing: "set name")
        }
        for bundle in ["", " ", "com.example app", "com.example\napp"] {
            var source = profile()
            source.bundleIdentifier = bundle
            assertInvalid(ProfileConfiguration(sources: [source]), containing: "bundleIdentifier")
        }
    }

    func testRelativeOtherUserTildeAndEnvironmentPathsAreRejected() throws {
        for path in ["", ".claude", "../claude", "~other/.claude", "~", "$HOME/.claude", "/tmp/$USER/claude", "~/claude\nsecond", "file:///tmp/claude"] {
            assertInvalid(ProfileConfiguration(sources: [profile(config: path)]), containing: "configDirectory")
            assertInvalid(ProfileConfiguration(sources: [profile(desktop: path)]), containing: "userDataDirectory")
        }
        try ProfileConfiguration(sources: [profile(config: "/tmp/Claude Config", desktop: "~/Library/Application Support/Claude Work")]).validate()
    }

    func testCanonicalDuplicatePathsAreRejected() throws {
        let first = profile(id: "first", config: "~/claude-test", desktop: "/tmp/claude-desktop-test")
        let duplicateConfig = profile(id: "second", config: NSHomeDirectory() + "/claude-test/../claude-test/", desktop: "/tmp/other-desktop")
        assertInvalid(ProfileConfiguration(sources: [first, duplicateConfig]), containing: "share a configDirectory")
        let duplicateDesktop = profile(id: "second", config: "/tmp/other-config", desktop: "/tmp/claude-desktop-test/./")
        assertInvalid(ProfileConfiguration(sources: [first, duplicateDesktop]), containing: "share a userDataDirectory")
    }

    func testSymlinkAliasesCannotDuplicateProfiles() throws {
        let target = temporary.appendingPathComponent("target", isDirectory: true)
        let alias = temporary.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let sources = [profile(id: "first", config: target.path, desktop: "/tmp/desktop-a"),
                       profile(id: "second", config: alias.path, desktop: "/tmp/desktop-b")]
        assertInvalid(ProfileConfiguration(sources: sources), containing: "share a configDirectory")
    }

    func testLegacyProfileWithoutAssistantRemainsClaude() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
        {"refreshInterval":15,"sources":[{"bundleIdentifier":"com.anthropic.claudefordesktop","configDirectory":"~/custom-claude","id":"claude-work","name":"Claude Work","userDataDirectory":"~/Library/Application Support/Claude-Work"}]}
        """
        try Data(json.utf8).write(to: file)
        let loaded = try ProfileConfiguration.load(from: file)
        XCTAssertEqual(loaded.sources[0].assistant, .claude)
        XCTAssertEqual(loaded.sources[0].bundleIdentifier, "com.anthropic.claudefordesktop")
    }

    func testCodexAndGrokProfilesDoNotUseClaudeDesktopFields() throws {
        let codex = AgentSource(id: "codex", name: "Codex", configDirectory: "~/.codex", assistant: .codex)
        let grok = AgentSource(id: "grok", name: "Grok", configDirectory: "~/.grok", assistant: .grok)
        try ProfileConfiguration(sources: [codex, grok]).validate()
        var desktop = codex
        desktop.userDataDirectory = "~/Library/Application Support/Codex"
        assertInvalid(ProfileConfiguration(sources: [desktop]), containing: "userDataDirectory")
        var claudeBundle = grok
        claudeBundle.bundleIdentifier = "com.anthropic.claudefordesktop"
        assertInvalid(ProfileConfiguration(sources: [claudeBundle]), containing: "bundle identifier")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{\"sources\":[{\"id\":\"codex\",\"name\":\"Codex\",\"configDirectory\":\"~/.codex\",\"bundleIdentifier\":\"\",\"assistant\":\"gemini\"}]}".utf8).write(to: file)
        XCTAssertThrowsError(try ProfileConfiguration.load(from: file))
    }

    func testOnlyKnownPrimaryCanOmitDesktopFolder() throws {
        assertInvalid(ProfileConfiguration(sources: [profile(desktop: nil)]), containing: "set userDataDirectory")
        var primary = ProfileConfiguration.defaults().sources[0]
        primary.userDataDirectory = nil
        try ProfileConfiguration(sources: [primary]).validate()
        let duplicate = profile(id: "duplicate", desktop: "~/Library/Application Support/Claude")
        assertInvalid(ProfileConfiguration(sources: [primary, duplicate]), containing: "share a userDataDirectory")
    }
}
