import XCTest
@testable import AgentTrailCore

final class ProcessIdentityTests: XCTestCase {
    private let home = "/tmp/agent-trail-test-user"
    private var sources: [AgentSource] { AgentSource.defaults(home: home) }

    private func record(arguments: [String] = [], environment: [String] = []) -> Data {
        let executable = "/Applications/Claude.app/Contents/MacOS/Claude"
        let argv = [executable] + arguments
        var count = Int32(argv.count)
        var data = withUnsafeBytes(of: &count) { Data($0) }
        data.append(contentsOf: executable.utf8)
        data.append(contentsOf: [0, 0, 0])
        for value in argv + environment {
            data.append(contentsOf: value.utf8)
            data.append(0)
        }
        data.append(0)
        return data
    }

    func testDefaultInstanceMatchesOnlyMain() throws {
        let identity = try XCTUnwrap(ProcessIdentity.parseKernelArguments(record(environment: ["IRRELEVANT=value"])))
        XCTAssertTrue(identity.matches(source: sources[0], homeDirectory: home))
        XCTAssertFalse(identity.matches(source: sources[1], homeDirectory: home))
    }

    func testSecondInstanceBothOptionSyntaxesWithSpaces() throws {
        let userData = sources[1].userDataDirectory!
        for arguments in [["--user-data-dir=\(userData)"], ["--user-data-dir", userData]] {
            let data = record(arguments: arguments, environment: ["CLAUDE_CONFIG_DIR=\(sources[1].configDirectory)"])
            let identity = try XCTUnwrap(ProcessIdentity.parseKernelArguments(data))
            XCTAssertTrue(identity.matches(source: sources[1], homeDirectory: home))
            XCTAssertFalse(identity.matches(source: sources[0], homeDirectory: home))
        }
    }

    func testConflictingOverridesFailClosed() throws {
        let data = record(arguments: ["--user-data-dir=/tmp/other-profile"], environment: ["CLAUDE_CONFIG_DIR=\(sources[1].configDirectory)"])
        let identity = try XCTUnwrap(ProcessIdentity.parseKernelArguments(data))
        XCTAssertFalse(identity.matches(source: sources[0], homeDirectory: home))
        XCTAssertFalse(identity.matches(source: sources[1], homeDirectory: home))
    }

    func testUnknownConfigDoesNotFallBackToMain() throws {
        let identity = try XCTUnwrap(ProcessIdentity.parseKernelArguments(record(environment: ["CLAUDE_CONFIG_DIR=/tmp/unknown"])))
        XCTAssertFalse(identity.matches(source: sources[0], homeDirectory: home))
        XCTAssertFalse(identity.matches(source: sources[1], homeDirectory: home))
    }

    func testMalformedAndAmbiguousOverridesAreRejected() {
        XCTAssertNil(ProcessIdentity.parseKernelArguments(Data([1, 0])))
        XCTAssertNil(ProcessIdentity.parseKernelArguments(record(arguments: ["--user-data-dir="])))
        XCTAssertNil(ProcessIdentity.parseKernelArguments(record(arguments: ["--user-data-dir"])))
        XCTAssertNil(ProcessIdentity.parseKernelArguments(record(arguments: ["--user-data-dir=/tmp/a", "--user-data-dir=/tmp/b"])))
        XCTAssertNil(ProcessIdentity.parseKernelArguments(record(environment: ["CLAUDE_CONFIG_DIR="])))
    }

    func testRelativeOverridesNeverResolveAgainstObserversWorkingDirectory() throws {
        for data in [
            record(arguments: ["--user-data-dir=relative-path"]),
            record(environment: ["CLAUDE_CONFIG_DIR=.claude-second"])
        ] {
            let identity = try XCTUnwrap(ProcessIdentity.parseKernelArguments(data))
            XCTAssertFalse(identity.matches(source: sources[0], homeDirectory: home))
            XCTAssertFalse(identity.matches(source: sources[1], homeDirectory: home))
        }
    }

    func testSecondaryRequiresBothEffectiveDirectoriesToMatch() throws {
        for data in [
            record(arguments: ["--user-data-dir=\(sources[1].userDataDirectory!)"]),
            record(environment: ["CLAUDE_CONFIG_DIR=\(sources[1].configDirectory)"])
        ] {
            let identity = try XCTUnwrap(ProcessIdentity.parseKernelArguments(data))
            XCTAssertFalse(identity.matches(source: sources[1], homeDirectory: home))
            XCTAssertFalse(identity.matches(source: sources[0], homeDirectory: home))
        }
    }

    func testExplicitPrimaryDesktopPathMatchesUnmodifiedLaunch() throws {
        var primary = sources[0]
        primary.userDataDirectory = home + "/Library/Application Support/Claude"
        let identity = try XCTUnwrap(ProcessIdentity.parseKernelArguments(record()))
        XCTAssertTrue(identity.matches(source: primary, homeDirectory: home))
    }

    func testConfigOnlyLaunchMatchesProfileWithDefaultDesktop() throws {
        var source = sources[1]
        source.userDataDirectory = home + "/Library/Application Support/Claude"
        let identity = try XCTUnwrap(ProcessIdentity.parseKernelArguments(record(environment: ["CLAUDE_CONFIG_DIR=\(source.configDirectory)"])))
        XCTAssertTrue(identity.matches(source: source, homeDirectory: home))
    }
}
