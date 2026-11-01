import Darwin
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

    /// Reads one live process's KERN_PROCARGS2 record. Only the allowlisted
    /// fields above survive; the rest of the environment is dropped with the buffer.
    public static func read(pid: Int32) -> ProcessIdentity? {
        guard let data = kernelArguments(pid: pid) else { return nil }
        return parseKernelArguments(data)
    }

    /// Reads only one live process's two terminal hints. The rest of the record,
    /// profile overrides included, is dropped with the buffer.
    public static func readTerminalHints(pid: Int32) -> TerminalHints? {
        guard let data = kernelArguments(pid: pid) else { return nil }
        return parseTerminalHints(data)
    }

    private static func kernelArguments(pid: Int32) -> Data? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size, size <= 16 * 1_024 * 1_024 else { return nil }
        var data = Data(count: size)
        let status = data.withUnsafeMutableBytes { sysctl(&mib, u_int(mib.count), $0.baseAddress, &size, nil, 0) }
        guard status == 0, size <= data.count else { return nil }
        data.count = size
        return data
    }

    /// TERM_PROGRAM and __CFBundleIdentifier, the two inherited hints that can
    /// name a hosting terminal. Each is nil when absent, empty, repeated,
    /// oversized or not UTF-8; a bad hint never hides the other one.
    public struct TerminalHints: Hashable, Sendable {
        public let termProgram: String?
        /// Set when LaunchServices starts an app and inherited by everything it spawns.
        public let bundleIdentifier: String?

        /// The terminal hosting this process, when the two hints agree.
        public var terminalBundleIdentifier: String? {
            ProcessIdentity.agreeingTerminalBundleIdentifier(termProgram: termProgram, bundleIdentifier: bundleIdentifier)
        }
    }

    /// Walks the same layout as parseKernelArguments, but apart from it: hints are
    /// not identity, so an empty or repeated profile override or an argument that
    /// is not UTF-8 must not hide them. The executable, argv and every other
    /// variable are skipped as raw bytes. Only a truncated layout returns nil.
    public static func parseTerminalHints(_ data: Data) -> TerminalHints? {
        let bytes = [UInt8](data)
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let argumentCount = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard argumentCount > 0, argumentCount <= 65_536 else { return nil }
        var cursor = MemoryLayout<Int32>.size

        func nextCString() -> ArraySlice<UInt8>? {
            guard cursor < bytes.count,
                  let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
            let value = bytes[cursor..<end]
            cursor = end + 1
            return value
        }

        guard nextCString() != nil else { return nil }
        while cursor < bytes.count && bytes[cursor] == 0 { cursor += 1 }
        for _ in 0..<Int(argumentCount) {
            guard nextCString() != nil else { return nil }
        }

        let terminalPrefix = Array("TERM_PROGRAM=".utf8)
        let bundlePrefix = Array("__CFBundleIdentifier=".utf8)
        var terminalProgram: String?
        var terminalCount = 0
        var bundle: String?
        var bundleCount = 0
        while cursor < bytes.count, bytes[cursor] != 0 {
            guard let entry = nextCString() else { return nil }
            if entry.starts(with: terminalPrefix) {
                terminalCount += 1
                terminalProgram = hintValue(entry, prefix: terminalPrefix)
            } else if entry.starts(with: bundlePrefix) {
                bundleCount += 1
                bundle = hintValue(entry, prefix: bundlePrefix)
            }
        }
        // A repeated hint is ambiguous, so that hint alone becomes unknown.
        return TerminalHints(termProgram: terminalCount == 1 ? terminalProgram : nil,
                             bundleIdentifier: bundleCount == 1 ? bundle : nil)
    }

    /// A terminal name or bundle id is short. Anything longer is not one.
    private static func hintValue(_ entry: ArraySlice<UInt8>, prefix: [UInt8]) -> String? {
        let value = entry.dropFirst(prefix.count)
        guard !value.isEmpty, value.count <= 255 else { return nil }
        return String(bytes: value, encoding: .utf8)
    }

    /// The parent of a live process, from kinfo_proc. Nil for an exited or zombie
    /// process and for an orphan: launchd (PID 1) adopts orphans, so it owns nothing.
    public static func parentProcessID(of pid: Int32) -> Int32? {
        guard pid > 0 else { return nil }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var information = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        // A missing PID succeeds with zero bytes, so the size check is the existence check.
        guard sysctl(&mib, u_int(mib.count), &information, &size, nil, 0) == 0,
              size == MemoryLayout<kinfo_proc>.size,
              information.kp_proc.p_pid == pid,
              information.kp_proc.p_stat != SZOMB else { return nil }
        let parent = information.kp_eproc.e_ppid
        return parent > 1 ? parent : nil
    }

    /// The executable the kernel is running for a live process, without reading
    /// its arguments or environment.
    public static func executablePath(of pid: Int32) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0, Int(length) <= buffer.count,
              let path = String(bytes: buffer[..<Int(length)], encoding: .utf8),
              path.hasPrefix("/") else { return nil }
        return path
    }

    /// TERM_PROGRAM values each terminal sets, and the bundle ids that may
    /// accompany them. VS Code and Cursor both report `vscode`.
    static let terminalBundles: [String: [String]] = [
        "Apple_Terminal": ["com.apple.Terminal"],
        "iTerm.app": ["com.googlecode.iterm2"],
        "ghostty": ["com.mitchellh.ghostty"],
        "WarpTerminal": ["dev.warp.Warp-Stable"],
        "vscode": ["com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"]
    ]

    /// Both hints are inherited, so either can be stale: a shell inside Claude
    /// Desktop still carries TERM_PROGRAM=iTerm.app from the terminal that
    /// launched Claude. Trust them only together, and only for a known terminal.
    /// Returns the table's spelling of the bundle id, or nil.
    public static func agreeingTerminalBundleIdentifier(termProgram: String?, bundleIdentifier: String?) -> String? {
        guard let termProgram, let bundleIdentifier, let accepted = terminalBundles[termProgram] else { return nil }
        return accepted.first { $0.caseInsensitiveCompare(bundleIdentifier) == .orderedSame }
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
