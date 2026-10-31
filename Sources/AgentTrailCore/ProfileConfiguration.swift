import Foundation
import Darwin

/// User-owned profile settings. Invalid settings throw before any profile is scanned.
/// Paths stay as entered (including `~/`) so an example can be shared across machines.
public struct ProfileConfiguration: Codable, Equatable, Sendable {
    public var sources: [AgentSource]
    public var refreshInterval: TimeInterval

    public static let minimumRefreshInterval: TimeInterval = 5
    public static let maximumRefreshInterval: TimeInterval = 300

    public init(sources: [AgentSource], refreshInterval: TimeInterval = 15) {
        self.sources = sources
        self.refreshInterval = refreshInterval
    }

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/AgentTrail", isDirectory: true)
            .appendingPathComponent("profiles.json")
    }

    public static func defaults(home: String = "~") -> ProfileConfiguration {
        ProfileConfiguration(sources: [
            AgentSource(id: "claude-primary", name: "Claude · Main",
                configDirectory: "\(home)/.claude",
                userDataDirectory: "\(home)/Library/Application Support/Claude"),
            AgentSource(id: "claude-second", name: "Claude · Second",
                configDirectory: "\(home)/.claude-second",
                userDataDirectory: "\(home)/Library/Application Support/Claude-Second"),
            AgentSource(id: "codex", name: "Codex",
                configDirectory: AssistantKind.codex.defaultHome(home: home), assistant: .codex),
            AgentSource(id: "grok", name: "Grok",
                configDirectory: AssistantKind.grok.defaultHome(home: home), assistant: .grok)
        ])
    }

    private enum CodingKeys: String, CodingKey { case sources, refreshInterval }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sources = try values.decode([AgentSource].self, forKey: .sources)
        refreshInterval = try values.decodeIfPresent(TimeInterval.self, forKey: .refreshInterval) ?? 15
    }

    /// Only an absent file uses defaults. A present, unreadable or invalid file fails closed.
    public static func load(from url: URL) throws -> ProfileConfiguration {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain && failure.code == NSFileReadNoSuchFileError {
                return defaults()
            }
            throw ProfileConfigurationError.reading(path: url.path, reason: error.localizedDescription)
        }
        guard data.count <= 1_048_576 else {
            throw ProfileConfigurationError.reading(path: url.path,
                reason: "The file exceeds 1 MB. Keep only profile settings in this file.")
        }
        let configuration: ProfileConfiguration
        do {
            configuration = try JSONDecoder().decode(ProfileConfiguration.self, from: data)
        } catch {
            throw ProfileConfigurationError.reading(path: url.path,
                reason: "Invalid JSON or missing profile fields. Check sources, refreshInterval and each profile's id, name, assistant, configDirectory, userDataDirectory and bundleIdentifier.")
        }
        do {
            try configuration.validate()
        } catch {
            throw ProfileConfigurationError.reading(path: url.path, reason: error.localizedDescription)
        }
        return configuration
    }

    public func validate() throws {
        guard (1...16).contains(sources.count) else {
            throw ProfileConfigurationError.invalid("Add between 1 and 16 profiles to sources.")
        }
        guard refreshInterval.isFinite,
              (Self.minimumRefreshInterval...Self.maximumRefreshInterval).contains(refreshInterval) else {
            throw ProfileConfigurationError.invalid("Set refreshInterval to a number between 5 and 300 seconds.")
        }
        var ids = Set<String>()
        var configPaths: [String: String] = [:]
        var userDataPaths: [String: String] = [:]
        for (index, source) in sources.enumerated() {
            let label = "Profile \(index + 1)"
            guard source.id.count <= 64,
                  source.id.range(of: "^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$", options: .regularExpression) != nil else {
                throw ProfileConfigurationError.invalid("\(label): use an id of up to 64 lowercase letters, digits and single hyphens, starting with a letter (for example claude-work). Keep ids stable after setup.")
            }
            guard ids.insert(source.id).inserted else {
                throw ProfileConfigurationError.invalid("Duplicate id '\(source.id)'. Give each profile a unique, stable id.")
            }
            guard Self.isLabel(source.name), source.name.count <= 80 else {
                throw ProfileConfigurationError.invalid("\(label) (\(source.id)): set name to 1–80 characters without leading/trailing whitespace or control characters.")
            }
            if source.assistant == .claude {
                guard Self.isLabel(source.bundleIdentifier),
                      source.bundleIdentifier.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                      source.bundleIdentifier.count <= 255 else {
                    throw ProfileConfigurationError.invalid("\(source.name): set a nonempty bundleIdentifier without spaces (Claude uses com.anthropic.claudefordesktop).")
                }
            } else if source.bundleIdentifier == "com.anthropic.claudefordesktop" {
                throw ProfileConfigurationError.invalid("\(source.name): leave bundleIdentifier empty or set that assistant's own app. Claude's bundle identifier would focus the wrong app.")
            } else if !source.bundleIdentifier.isEmpty {
                guard Self.isLabel(source.bundleIdentifier),
                      source.bundleIdentifier.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                      source.bundleIdentifier.count <= 255 else {
                    throw ProfileConfigurationError.invalid("\(source.name): set bundleIdentifier without spaces, or leave it empty when the assistant has no desktop app to focus.")
                }
            }
            let config = try Self.checkedPath(source.configDirectory, field: "configDirectory", source: source.name)
            if let other = configPaths[config] {
                throw ProfileConfigurationError.invalid("\(source.name) and \(other) share a configDirectory. Set distinct folders so their activity can be attributed correctly.")
            }
            configPaths[config] = source.name
            if source.assistant != .claude {
                guard source.userDataDirectory == nil else {
                    throw ProfileConfigurationError.invalid("\(source.name): userDataDirectory applies to Claude profiles only. Remove it for \(source.assistant.displayName).")
                }
                continue
            }
            let defaultConfig = canonicalPath("~/.claude")
            let desktopDirectory = source.userDataDirectory
                ?? (config == defaultConfig ? "~/Library/Application Support/Claude" : nil)
            guard let desktopDirectory else {
                throw ProfileConfigurationError.invalid("\(source.name): set userDataDirectory to this Claude instance's desktop data folder. The main instance uses ~/Library/Application Support/Claude.")
            }
            let userData = try Self.checkedPath(desktopDirectory, field: "userDataDirectory", source: source.name)
            if let other = userDataPaths[userData] {
                throw ProfileConfigurationError.invalid("\(source.name) and \(other) share a userDataDirectory. Set distinct desktop data folders so their activity can be attributed correctly.")
            }
            userDataPaths[userData] = source.name
        }
    }

    /// Writes atomically with mode 0600 in a dedicated mode-0700 settings folder.
    /// The immediate parent directory is restricted to the current user.
    public func save(to url: URL) throws {
        try validate()
        let files = FileManager.default
        let parent = url.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".profiles-\(UUID().uuidString).tmp")
        do {
            try files.createDirectory(at: parent, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            var data = try encoder.encode(self)
            data.append(0x0A)
            guard files.createFile(atPath: temporary.path, contents: nil,
                                   attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { try? files.removeItem(at: temporary) }
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            guard rename(temporary.path, url.path) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        } catch {
            throw ProfileConfigurationError.writing(path: url.path, reason: error.localizedDescription)
        }
    }

    private static func isLabel(_ value: String) -> Bool {
        !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func checkedPath(_ value: String, field: String, source: String) throws -> String {
        guard isLabel(value), value.hasPrefix("/") || value.hasPrefix("~/"),
              !value.contains("$") else {
            throw ProfileConfigurationError.invalid("\(source): \(field) must be an absolute path or start with ~/. Expand environment variables such as $HOME yourself; relative paths are not supported.")
        }
        return canonicalPath(value)
    }
}

public enum ProfileConfigurationError: LocalizedError {
    case invalid(String)
    case reading(path: String, reason: String)
    case writing(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let reason):
            return reason
        case .reading(let path, let reason):
            return "Could not load profiles at \(path). \(reason) Fix this file, then reload profiles."
        case .writing(let path, let reason):
            return "Could not save profiles at \(path). \(reason) Check that the settings folder is writable."
        }
    }
}
