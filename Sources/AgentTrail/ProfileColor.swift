import AppKit
import SwiftUI
import AgentTrailCore

/// Where a profile sits in the identity palette. The seventh profile onward
/// shares `.other` (slate), and charts fold those into one series.
enum ProfileSlot: Equatable, Hashable {
    case slot(Int)
    case other
}

/// A profile keeps the same visual identity in Projects, Growth, Settings and
/// exports. The palette is validated for color-vision deficiency on white and
/// on #161A22, keeps teal clear of Working green, and has no amber or red slot,
/// so identity never reads as a status.
enum ProfileColor {
    /// Default ids keep fixed slots, so their colors never move.
    static let defaultSlots: [String: Int] = ["claude-primary": 0, "claude-second": 1, "codex": 2, "grok": 3]
    static let slotCount = 6
    /// The folded chart series for `.other` profiles.
    static let otherSeriesID = "other"
    static let otherSeriesName = "Other profiles"

    /// (light, dark) per slot: blue, magenta, violet, teal, plum, umber.
    private static let slotHex: [(light: UInt32, dark: UInt32)] = [
        (0x2A78D6, 0x3987E5),
        (0xD4498C, 0xD55181),
        (0x6250D6, 0x9085E9),
        (0x1B9690, 0x33A397),
        (0x793974, 0x7860A0),
        (0x7D460B, 0xAD721C)
    ]
    private static let slateHex: UInt32 = 0x8A93A6

    private static let dynamicColors: [Color] = slotHex.map { pair in
        Color(light: Theme.nsColor(hex: pair.light), dark: Theme.nsColor(hex: pair.dark))
    }
    private static let slate = Color(light: Theme.nsColor(hex: slateHex), dark: Theme.nsColor(hex: slateHex))

    /// Custom profiles, in sources order, take the lowest slot not held by a
    /// configured default id or by an earlier custom profile. Ids that are not
    /// configured, and profiles past six slots, get `.other`.
    static func slot(for id: String, sources: [AgentSource]) -> ProfileSlot {
        if let fixed = defaultSlots[id] { return .slot(fixed) }
        guard sources.contains(where: { $0.id == id }) else { return .other }
        var taken = Set(sources.compactMap { defaultSlots[$0.id] })
        for source in sources where defaultSlots[source.id] == nil {
            guard let free = (0..<slotCount).first(where: { !taken.contains($0) }) else { return .other }
            if source.id == id { return .slot(free) }
            taken.insert(free)
        }
        return .other
    }

    /// The adaptive identity color for a profile id.
    static func color(_ id: String, sources: [AgentSource]) -> Color {
        color(for: slot(for: id, sources: sources))
    }

    static func color(for slot: ProfileSlot) -> Color {
        switch slot {
        case .slot(let index) where dynamicColors.indices.contains(index): return dynamicColors[index]
        case .slot, .other: return slate
        }
    }

    /// A non-adaptive color for ImageRenderer output, which has no appearance.
    static func fixed(_ id: String, sources: [AgentSource], dark: Bool) -> Color {
        let hex: UInt32
        switch slot(for: id, sources: sources) {
        case .slot(let index) where slotHex.indices.contains(index):
            hex = dark ? slotHex[index].dark : slotHex[index].light
        case .slot, .other:
            hex = slateHex
        }
        return Theme.color(hex: hex)
    }

    /// The focus ramp for heatmaps and the punch card: level 0 stays the empty
    /// ink, levels 1-4 use the profile color at rising opacity.
    static func ramp(for id: String, sources: [AgentSource]) -> [Color] {
        let base = color(id, sources: sources)
        return [Theme.Palette.heat(0), base.opacity(0.22), base.opacity(0.45), base.opacity(0.70), base.opacity(0.95)]
    }

    /// The chart series a profile belongs to: its own id, or the folded "other" series.
    static func seriesID(_ id: String, sources: [AgentSource]) -> String {
        slot(for: id, sources: sources) == .other ? otherSeriesID : id
    }

    /// Two letters that tell slate profiles apart in lists: "Claude · Work" → "CW", "Codex" → "CO".
    static func monogram(_ name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        if words.count >= 2, let first = words[0].first, let second = words[1].first {
            return String([first, second]).uppercased()
        }
        guard let word = words.first else { return "?" }
        return String(word.prefix(2)).uppercased()
    }
}
