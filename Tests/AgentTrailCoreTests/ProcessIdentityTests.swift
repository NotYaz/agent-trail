import XCTest
@testable import AgentTrailCore

final class ProcessIdentityTests: XCTestCase {
    private let home = "/tmp/agent-trail-test-user"
    private var sources: [AgentSource] { AgentSource.defaults(home: home) }

    private func record(arguments: [String] = [], environment: [String] = []) -> Data {
        rawRecord(arguments: arguments.map { Array($0.utf8) }, environment: environment.map { Array($0.utf8) })
    }

    /// Byte entries, so a test can include values that are not UTF-8.
    private func rawRecord(arguments: [[UInt8]], environment: [[UInt8]]) -> Data {
        let executable = "/Applications/Claude.app/Contents/MacOS/Claude"
        let argv = [Array(executable.utf8)] + arguments
        var count = Int32(argv.count)
        var data = withUnsafeBytes(of: &count) { Data($0) }
        data.append(contentsOf: executable.utf8)
        data.append(contentsOf: [0, 0, 0])
        for value in argv + environment {
            data.append(contentsOf: value)
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

    func testCodexAndGrokHomesDoNotMatchClaudeProfiles() throws {
        let home = self.home
        let codex = AgentSource(id: "codex", name: "Codex", configDirectory: "\(home)/.codex", assistant: .codex)
        let custom = AgentSource(id: "codex-work", name: "Codex Work", configDirectory: "/tmp/codex-work", assistant: .codex)
        let grok = AgentSource(id: "grok", name: "Grok", configDirectory: "\(home)/.grok", assistant: .grok)
        let plain = try XCTUnwrap(ProcessIdentity.parseKernelArguments(record()))
        XCTAssertTrue(plain.matches(source: codex, homeDirectory: home))
        XCTAssertFalse(plain.matches(source: custom, homeDirectory: home))
        XCTAssertTrue(plain.matches(source: grok, homeDirectory: home))
        XCTAssertTrue(plain.matches(source: sources[0], homeDirectory: home))

        let codexOverride = try XCTUnwrap(ProcessIdentity.parseKernelArguments(record(environment: ["CODEX_HOME=/tmp/codex-work"])))
        XCTAssertTrue(codexOverride.matches(source: custom, homeDirectory: home))
        XCTAssertFalse(codexOverride.matches(source: codex, homeDirectory: home))
        XCTAssertTrue(codexOverride.matches(source: sources[0], homeDirectory: home))

        let relative = try XCTUnwrap(ProcessIdentity.parseKernelArguments(record(environment: ["GROK_HOME=relative-home"])))
        let customGrok = AgentSource(id: "grok-work", name: "Grok Work", configDirectory: "/tmp/grok-work", assistant: .grok)
        XCTAssertFalse(relative.matches(source: customGrok, homeDirectory: home))
        XCTAssertFalse(relative.matches(source: grok, homeDirectory: home))
        XCTAssertNil(ProcessIdentity.parseKernelArguments(record(environment: ["CODEX_HOME=/tmp/one", "CODEX_HOME=/tmp/two"])))
        XCTAssertNil(ProcessIdentity.parseKernelArguments(record(environment: ["GROK_HOME="])))
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

    func testOnlyTheTwoTerminalHintsAreKeptFromTheEnvironment() throws {
        let data = record(environment: [
            "TERM_PROGRAM_VERSION=3.7.6", "TERM_PROGRAM=iTerm.app", "ITERM_SESSION_ID=w0t0p0:example",
            "__CFBundleIdentifier=com.googlecode.iterm2", "__CFBundleIdentifierExtra=com.example.other"
        ])
        let hints = try XCTUnwrap(ProcessIdentity.parseTerminalHints(data))
        XCTAssertEqual(hints.termProgram, "iTerm.app")
        XCTAssertEqual(hints.bundleIdentifier, "com.googlecode.iterm2")
        XCTAssertEqual(hints.terminalBundleIdentifier, "com.googlecode.iterm2")
        let identity = try XCTUnwrap(ProcessIdentity.parseKernelArguments(data))
        XCTAssertTrue(identity.matches(source: sources[0], homeDirectory: home))
    }

    func testRepeatedEmptyOrOversizedTerminalHintsAreUnknownWithoutFailingTheRecord() throws {
        for environment in [
            ["TERM_PROGRAM=Apple_Terminal", "TERM_PROGRAM=Apple_Terminal", "__CFBundleIdentifier=com.apple.Terminal"],
            ["TERM_PROGRAM=Apple_Terminal", "__CFBundleIdentifier=com.apple.Terminal", "__CFBundleIdentifier=com.apple.Terminal"],
            ["TERM_PROGRAM=", "__CFBundleIdentifier=com.apple.Terminal"],
            ["TERM_PROGRAM=Apple_Terminal", "__CFBundleIdentifier=" + String(repeating: "a", count: 256)],
            ["TERM_PROGRAM=Apple_Terminal"],
            []
        ] {
            let data = record(environment: environment)
            let hints = try XCTUnwrap(ProcessIdentity.parseTerminalHints(data))
            XCTAssertNil(hints.terminalBundleIdentifier, environment.joined(separator: " "))
            let identity = try XCTUnwrap(ProcessIdentity.parseKernelArguments(data))
            XCTAssertTrue(identity.matches(source: sources[0], homeDirectory: home))
        }
        let invalid = try XCTUnwrap(ProcessIdentity.parseTerminalHints(rawRecord(arguments: [], environment: [
            Array("TERM_PROGRAM=".utf8) + [0xFF, 0xFE], Array("__CFBundleIdentifier=com.apple.Terminal".utf8)
        ])))
        XCTAssertNil(invalid.termProgram)
        XCTAssertEqual(invalid.bundleIdentifier, "com.apple.Terminal")
    }

    func testTerminalHintsSurviveRecordsTheProfileParserRejects() {
        let terminal = [Array("TERM_PROGRAM=Apple_Terminal".utf8), Array("__CFBundleIdentifier=com.apple.Terminal".utf8)]
        let cases: [(arguments: [[UInt8]], environment: [[UInt8]])] = [
            ([], [Array("CODEX_HOME=".utf8)]),
            ([], [Array("GROK_HOME=".utf8)]),
            ([], [Array("CLAUDE_CONFIG_DIR=/tmp/one".utf8), Array("CLAUDE_CONFIG_DIR=/tmp/two".utf8)]),
            ([], [Array("CLAUDE_CONFIG_DIR=/tmp/".utf8) + [0xFF]]),
            ([Array("--user-data-dir".utf8)], []),
            // An argument that is not UTF-8 is skipped as raw bytes.
            ([[0x2D, 0xFF, 0xFE]], [])
        ]
        for (index, entry) in cases.enumerated() {
            let data = rawRecord(arguments: entry.arguments, environment: entry.environment + terminal)
            XCTAssertNil(ProcessIdentity.parseKernelArguments(data), "case \(index)")
            XCTAssertEqual(ProcessIdentity.parseTerminalHints(data)?.terminalBundleIdentifier, "com.apple.Terminal", "case \(index)")
        }
    }

    func testTruncatedRecordsHaveNoTerminalHints() throws {
        let data = record(arguments: ["--flag"], environment: ["TERM_PROGRAM=Apple_Terminal", "__CFBundleIdentifier=com.apple.Terminal"])
        XCTAssertEqual(ProcessIdentity.parseTerminalHints(data)?.terminalBundleIdentifier, "com.apple.Terminal")
        let argument = try XCTUnwrap(data.range(of: Data("--flag".utf8)))
        for truncated in [Data(), Data([1, 0]), data.prefix(12), data.prefix(argument.lowerBound + 3), data.dropLast(2)] {
            XCTAssertNil(ProcessIdentity.parseTerminalHints(Data(truncated)), "\(truncated.count) bytes")
        }
    }

    func testTerminalHintsMustAgreeOnAKnownTerminal() {
        func host(_ program: String?, _ bundle: String?) -> String? {
            ProcessIdentity.agreeingTerminalBundleIdentifier(termProgram: program, bundleIdentifier: bundle)
        }
        for (program, bundle) in [
            ("Apple_Terminal", "com.apple.Terminal"), ("iTerm.app", "com.googlecode.iterm2"),
            ("ghostty", "com.mitchellh.ghostty"), ("WarpTerminal", "dev.warp.Warp-Stable"),
            ("vscode", "com.microsoft.VSCode"), ("vscode", "com.todesktop.230313mzl4w4u92")
        ] { XCTAssertEqual(host(program, bundle), bundle) }
        XCTAssertEqual(host("iTerm.app", "COM.googlecode.iTerm2"), "com.googlecode.iterm2")
        for (program, bundle) in [
            ("iTerm.app", "com.anthropic.claudefordesktop"), ("Apple_Terminal", "com.googlecode.iterm2"),
            ("vscode", "com.apple.Terminal"), ("ghostty", "com.mitchellh.ghostty.debug"),
            ("tmux", "com.apple.Terminal"), ("apple_terminal", "com.apple.Terminal"),
            ("claude-desktop", "com.anthropic.claudefordesktop")
        ] { XCTAssertNil(host(program, bundle), program) }
        XCTAssertNil(host(nil, "com.apple.Terminal"))
        XCTAssertNil(host("Apple_Terminal", nil))
        XCTAssertNil(host(nil, nil))
    }

    func testProcessHelpersReadOnlyLiveProcesses() {
        let parent = getppid()
        XCTAssertEqual(ProcessIdentity.parentProcessID(of: getpid()), parent > 1 ? parent : nil)
        // launchd's parent is the kernel, and launchd itself owns nothing.
        XCTAssertNil(ProcessIdentity.parentProcessID(of: 1))
        XCTAssertNil(ProcessIdentity.parentProcessID(of: 0))
        XCTAssertNil(ProcessIdentity.parentProcessID(of: -1))
        XCTAssertNil(ProcessIdentity.parentProcessID(of: Int32.max))
        XCTAssertEqual(ProcessIdentity.executablePath(of: getpid())?.hasPrefix("/"), true)
        XCTAssertNil(ProcessIdentity.executablePath(of: -1))
        XCTAssertNil(ProcessIdentity.executablePath(of: Int32.max))
        // An empty profile override makes any record fail closed, this one included.
        let environment = ProcessInfo.processInfo.environment
        if ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "GROK_HOME"].allSatisfy({ environment[$0]?.isEmpty != true }) {
            XCTAssertNotNil(ProcessIdentity.read(pid: getpid()))
        }
        // The hints reader ignores profile overrides, so it reads any live record.
        XCTAssertNotNil(ProcessIdentity.readTerminalHints(pid: getpid()))
        XCTAssertNil(ProcessIdentity.read(pid: 0))
        XCTAssertNil(ProcessIdentity.read(pid: Int32.max))
        XCTAssertNil(ProcessIdentity.readTerminalHints(pid: 0))
        XCTAssertNil(ProcessIdentity.readTerminalHints(pid: Int32.max))
    }
}
