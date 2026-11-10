import Foundation
import XCTest
@testable import AgentTrailCore

/// Every assistant must be complete: a descriptor, a history adapter, its own
/// cache file and home, so adding a kind cannot silently skip a scan.
final class AssistantRegistryTests: XCTestCase {
    func testEveryAssistantHasADescriptorAdapterAndOwnCache() {
        let base = URL(fileURLWithPath: "/tmp/agent-trail-tests/activity-cache.json")
        let resolver = GitProjectResolver(locations: .init())
        var caches: Set<String> = []
        var homes: Set<String> = []
        var variables: Set<String> = []
        for kind in AssistantKind.allCases {
            let descriptor = kind.descriptor
            XCTAssertEqual(descriptor.kind, kind)
            XCTAssertFalse(descriptor.displayName.isEmpty)
            XCTAssertFalse(descriptor.homeTitle.isEmpty)
            XCTAssertFalse(descriptor.editEvidence.isEmpty)
            XCTAssertEqual(descriptor.reportsDelegation, descriptor.delegationOrigin != nil, "\(kind)")
            XCTAssertEqual(descriptor.requiresBundleIdentifier, !descriptor.defaultBundleIdentifier.isEmpty, "\(kind)")
            _ = AssistantRegistry.history(kind, cacheURL: nil, resolver: resolver)
            let cache = AssistantRegistry.cacheURL(kind, base: base)
            XCTAssertNotNil(cache)
            XCTAssertTrue(caches.insert(cache!.lastPathComponent).inserted, "\(kind) shares a cache file")
            XCTAssertTrue(homes.insert(kind.defaultHome(home: "~")).inserted, "\(kind) shares a home")
            if let variable = descriptor.homeEnvironmentVariable {
                XCTAssertTrue(variables.insert(variable).inserted, "\(kind) shares a home variable")
            }
        }
    }

    func testExistingCacheFileNamesAreKept() {
        let base = URL(fileURLWithPath: "/support/activity-cache.json")
        XCTAssertEqual(AssistantRegistry.cacheURL(.claude, base: base)?.path, "/support/activity-cache.json")
        XCTAssertEqual(AssistantRegistry.cacheURL(.codex, base: base)?.path, "/support/activity-cache-codex.json")
        XCTAssertEqual(AssistantRegistry.cacheURL(.grok, base: base)?.path, "/support/activity-cache-grok.json")
        XCTAssertNil(AssistantRegistry.cacheURL(.codex, base: nil))
    }

    func testDescriptorsKeepEarlierBehavior() {
        XCTAssertEqual(AssistantKind.claude.defaultHome(home: "~"), "~/.claude")
        XCTAssertEqual(AssistantKind.codex.defaultHome(home: "/Users/a"), "/Users/a/.codex")
        XCTAssertEqual(AssistantKind.grok.defaultHome(home: "~"), "~/.grok")
        XCTAssertEqual(AgentSource(id: "c", name: "C", configDirectory: "~/.claude").bundleIdentifier,
                       "com.anthropic.claudefordesktop")
        XCTAssertEqual(AgentSource(id: "x", name: "X", configDirectory: "~/.codex", assistant: .codex).bundleIdentifier, "")
        XCTAssertFalse(AssistantKind.grok.descriptor.reportsDelegation)
        XCTAssertEqual(AssistantKind.grok.descriptor.hosting, .terminal)
        XCTAssertEqual(AssistantKind.homeEnvironmentVariables, ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "GROK_HOME", "COPILOT_HOME"])
    }

    func testListedNames() {
        XCTAssertEqual(AssistantKind.listed([]), "")
        XCTAssertEqual(AssistantKind.listed(["A"]), "A")
        XCTAssertEqual(AssistantKind.listed(["A", "B"], conjunction: "or"), "A or B")
        XCTAssertEqual(AssistantKind.listed(["A", "B", "C"]), "A, B, and C")
        XCTAssertEqual(AssistantKind.listedNames(), "Claude, Codex, Grok, Copilot, and OpenCode")
    }

    func testStatsIndexReadsDelegationFromDescriptor() {
        let sources = [
            AgentSource(id: "claude-primary", name: "Claude", configDirectory: "/x/.claude"),
            AgentSource(id: "grok", name: "Grok", configDirectory: "/x/.grok", assistant: .grok)
        ]
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let projects = ProjectSummary.merge(sources.map { source in
            ProjectActivity(sourceID: source.id, projectPath: "/x/project", latestActivity: now, latestEdit: now,
                history: [ActivityDay(day: now, editCount: 1, sessionCount: 1)],
                editMoments: [EditMoment(date: now)], sessionStarts: [now])
        })
        let index = StatsIndex.build(projects: projects, sources: sources,
                                     calendar: ActivityCalendar(timeZone: TimeZone(identifier: "UTC")!), now: now)
        let reported = Dictionary(uniqueKeysWithValues: zip(index.sourceOrder, index.reportsDelegation))
        XCTAssertEqual(reported["claude-primary"], true)
        XCTAssertEqual(reported["grok"], false)
    }
}

final class AssistantDetectionTests: XCTestCase {
    func testSuggestsOnlyAssistantsWithSessionsAndNoProfile() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("agent-trail-detect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let files = FileManager.default
        // An empty VS Code storage folder is not Copilot use.
        try files.createDirectory(at: home.appendingPathComponent("Library/Application Support/Code/User/workspaceStorage/a/chatSessions"),
                                  withIntermediateDirectories: true)
        try files.createDirectory(at: home.appendingPathComponent(".grok/sessions/x"), withIntermediateDirectories: true)
        let configured = [AgentSource(id: "claude-primary", name: "Claude", configDirectory: "~/.claude")]
        XCTAssertEqual(AssistantDetection.suggestions(configured: configured, home: home.path).map(\.assistant), [.grok])
        try Data("{}".utf8).write(to: home.appendingPathComponent("Library/Application Support/Code/User/workspaceStorage/a/chatSessions/s.jsonl"))
        let found = AssistantDetection.suggestions(configured: configured, home: home.path)
        XCTAssertEqual(found.map(\.assistant), [.grok, .copilot])
        let copilot = try XCTUnwrap(found.last)
        XCTAssertEqual(copilot.id, "copilot")
        XCTAssertEqual(copilot.configDirectory, "~/.copilot")
        try ProfileConfiguration(sources: configured + found).validate()
        // A profile of that assistant, whatever its id, covers it; ids never collide.
        let taken = configured + [AgentSource(id: "copilot", name: "Mine", configDirectory: "~/x", assistant: .claude)]
        XCTAssertEqual(AssistantDetection.suggestions(configured: taken, home: home.path).last?.id, "copilot-2")
        let covered = configured + [AgentSource(id: "work", name: "Work", configDirectory: "~/w", assistant: .copilot)]
        XCTAssertFalse(AssistantDetection.suggestions(configured: covered, home: home.path).contains { $0.assistant == .copilot })
    }
}
