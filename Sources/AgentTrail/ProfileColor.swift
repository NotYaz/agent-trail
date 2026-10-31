import SwiftUI
import AgentTrailCore

/// A profile keeps the same visual identity in Projects, Growth, and exports.
enum ProfileColor {
    private static let colors: [Color] = [
        Color(red: 0.36, green: 0.65, blue: 1),
        Color(red: 1, green: 0.67, blue: 0.36),
        .pink, .cyan, .purple, .mint
    ]

    static func color(_ id: String, sources: [AgentSource]) -> Color {
        let defaults = ["claude-primary", "claude-second", "codex", "grok"]
        let index = defaults.firstIndex(of: id) ?? sources.firstIndex { $0.id == id } ?? 4
        return colors[index % colors.count]
    }
}
