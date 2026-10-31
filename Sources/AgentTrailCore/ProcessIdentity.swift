import Foundation

/// The small portion of a process's KERN_PROCARGS2 record needed to identify a profile.
/// Unrelated environment variables are deliberately discarded.
public struct ProcessIdentity: Sendable {
    public let executablePath: String
    public let arguments: [String]
    public let claudeConfigDirectory: String?
    public let userDataDirectory: String?
    public let codexHome: String?
    public let grokHome: String?

    /// Parses the native macOS layout: argc, executable, padding, argv, environment.
    /// Truncated records and conflicting or empty profile overrides fail closed.
    public static func parseKernelArguments(_ data: Data) -> ProcessIdentity? {
        let bytes = [UInt8](data)
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let argumentCount = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argumentCount > 0, argumentCount <= 65_536 else { return nil }
        var cursor = MemoryLayout<Int32>.size

        func readCString() -> [UInt8]? {
            guard cursor < bytes.count,
                  let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
            let value = Array(bytes[cursor..<end])
            cursor = end + 1
            return value
        }

        guard let executableBytes = readCString(),
              let executable = String(bytes: executableBytes, encoding: .utf8),
              !executable.isEmpty else { return nil }
        while cursor < bytes.count && bytes[cursor] == 0 { cursor += 1 }

        var arguments: [String] = []
        for _ in 0..<Int(argumentCount) {
            guard let argumentBytes = readCString(),
                  let argument = String(bytes: argumentBytes, encoding: .utf8) else { return nil }
            arguments.append(argument)
        }

        let claudePrefix = Array("CLAUDE_CONFIG_DIR=".utf8)
        let codexPrefix = Array("CODEX_HOME=".utf8)
        let grokPrefix = Array("GROK_HOME=".utf8)
        var configDirectory: String?
        var codexHome: String?
        var grokHome: String?
        while cursor < bytes.count, bytes[cursor] != 0 {
            guard let entry = readCString() else { return nil }
            if entry.starts(with: claudePrefix) {
                guard configDirectory == nil, let value = environmentValue(entry, prefix: claudePrefix) else { return nil }
                configDirectory = value
            } else if entry.starts(with: codexPrefix) {
                guard codexHome == nil, let value = environmentValue(entry, prefix: codexPrefix) else { return nil }
                codexHome = value
            } else if entry.starts(with: grokPrefix) {
                guard grokHome == nil, let value = environmentValue(entry, prefix: grokPrefix) else { return nil }
                grokHome = value
            }
        }

        var userDataDirectory: String?
        var index = 1 // argv[0] is the executable, not an option.
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--user-data-dir" {
                guard userDataDirectory == nil, index + 1 < arguments.count else { return nil }
                index += 1
                let value = arguments[index]
                guard !value.isEmpty, !value.hasPrefix("--") else { return nil }
                userDataDirectory = value
            } else if argument.hasPrefix("--user-data-dir=") {
                guard userDataDirectory == nil else { return nil }
                let value = String(argument.dropFirst("--user-data-dir=".count))
                guard !value.isEmpty else { return nil }
                userDataDirectory = value
            }
            index += 1
        }
        return ProcessIdentity(executablePath: executable, arguments: arguments,
                               claudeConfigDirectory: configDirectory,
                               userDataDirectory: userDataDirectory,
                               codexHome: codexHome, grokHome: grokHome)
    }

    private static func environmentValue(_ entry: [UInt8], prefix: [UInt8]) -> String? {
        guard let value = String(bytes: entry.dropFirst(prefix.count), encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    /// Compare the directories that identify this assistant. Claude still requires
    /// both its config directory and desktop data folder. Codex and Grok match
    /// only their own home variable, or the default home when that variable is absent.
    public func matches(source: AgentSource, homeDirectory: String = NSHomeDirectory()) -> Bool {
        switch source.assistant {
        case .claude:
            return matchesClaude(source, homeDirectory: homeDirectory)
        case .codex:
            return matchesHome(recorded: codexHome, configured: source.configDirectory,
                defaultHome: "\(homeDirectory)/.codex")
        case .grok:
            return matchesHome(recorded: grokHome, configured: source.configDirectory,
                defaultHome: "\(homeDirectory)/.grok")
        }
    }

    private func matchesClaude(_ source: AgentSource, homeDirectory: String) -> Bool {
        let expectedConfig = canonicalPath(source.configDirectory)
        let defaultConfig = canonicalPath("\(homeDirectory)/.claude")
        let defaultDesktop = canonicalPath("\(homeDirectory)/Library/Application Support/Claude")
        guard let expectedDesktop = source.userDataDirectory.map(canonicalPath)
            ?? (expectedConfig == defaultConfig ? defaultDesktop : nil) else { return false }
        if let config = claudeConfigDirectory, !config.hasPrefix("/") { return false }
        if let desktop = userDataDirectory, !desktop.hasPrefix("/") { return false }
        return (claudeConfigDirectory.map(canonicalPath) ?? defaultConfig) == expectedConfig
            && (userDataDirectory.map(canonicalPath) ?? defaultDesktop) == expectedDesktop
    }

    private func matchesHome(recorded: String?, configured: String, defaultHome: String) -> Bool {
        if let recorded {
            guard recorded.hasPrefix("/") else { return false }
            return canonicalPath(recorded) == canonicalPath(configured)
        }
        return canonicalPath(configured) == canonicalPath(defaultHome)
    }
}
