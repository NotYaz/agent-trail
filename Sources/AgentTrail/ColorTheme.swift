import AppKit
import SwiftUI
import os

/// The panel's color themes. A theme recolors the canvas, the aurora, status,
/// sparklines, the Trail calendar and profile identity; layout and glass never
/// change. Views read colors through `Theme.Palette` and `ProfileColor`, which
/// follow `current`.
enum ColorTheme: String, CaseIterable, Identifiable {
    /// Neutral slate, a faint indigo wash and the original profile colors.
    case classic
    /// Cooler, brighter surfaces, indigo sparklines and a blue-slate calendar.
    case gentle
    /// Gentle plus brighter profile colors.
    case vivid
    /// Vivid plus an indigo calendar and a stronger three-color wash.
    case aurora

    var id: String { rawValue }

    var title: String {
        switch self {
        case .classic: return "Classic"
        case .gentle: return "Gentle"
        case .vivid: return "Vivid"
        case .aurora: return "Aurora"
        }
    }

    /// The theme views draw with. It lives in memory so drawing never reads
    /// defaults; renders set it without storing a choice.
    static var current: ColorTheme {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }

    private static let state = OSAllocatedUnfairLock(initialState: stored)

    /// The saved choice. Anything unknown reads as Classic.
    static var stored: ColorTheme {
        UserDefaults.standard.string(forKey: AppSettings.Key.colorTheme).flatMap(ColorTheme.init(rawValue:)) ?? .classic
    }

    var palette: ThemePalette {
        switch self {
        case .classic: return ThemePalette.classic
        case .gentle: return ThemePalette.gentle
        case .vivid: return ThemePalette.vivid
        case .aurora: return ThemePalette.aurora
        }
    }
}

/// The colors a theme changes. Each is built once, so switching costs a lookup.
struct ThemePalette {
    let canvas: Color
    let auroraIndigo: Color
    let auroraViolet: Color
    /// Aurora's third glow, at the panel's bottom edge; clear elsewhere.
    let auroraPink: Color
    let needsInput: Color
    let needsInputNSColor: NSColor
    let needsInputText: Color
    let working: Color
    let workingText: Color
    let heatRamp: [Color]
    let sparkline: Color
    let sparklineFill: Color
    /// (light, dark) per profile slot: blue, magenta, violet, teal, plum, umber.
    let profileHex: [(light: UInt32, dark: UInt32)]
    let profileColors: [Color]

    init(canvas: (light: UInt32, dark: UInt32), aurora: (indigo: (CGFloat, CGFloat), violet: (CGFloat, CGFloat)),
         auroraPink: (light: UInt32, dark: UInt32, alpha: (CGFloat, CGFloat))? = nil,
         needsInput: (light: UInt32, dark: UInt32), working: (light: UInt32, dark: UInt32),
         workingText: (light: UInt32, dark: UInt32), heat: (light: [UInt32], dark: [UInt32]),
         sparkline: (light: UInt32, dark: UInt32)?, profiles: [(light: UInt32, dark: UInt32)]) {
        self.canvas = Color(light: Theme.nsColor(hex: canvas.light), dark: Theme.nsColor(hex: canvas.dark))
        auroraIndigo = Color(light: Theme.nsColor(hex: 0x4F6BED, alpha: aurora.indigo.0),
                             dark: Theme.nsColor(hex: 0x4F6BED, alpha: aurora.indigo.1))
        auroraViolet = Color(light: Theme.nsColor(hex: 0xA178FF, alpha: aurora.violet.0),
                             dark: Theme.nsColor(hex: 0xA178FF, alpha: aurora.violet.1))
        self.auroraPink = auroraPink.map {
            Color(light: Theme.nsColor(hex: $0.light, alpha: $0.alpha.0), dark: Theme.nsColor(hex: $0.dark, alpha: $0.alpha.1))
        } ?? .clear
        needsInputNSColor = NSColor(light: Theme.nsColor(hex: needsInput.light), dark: Theme.nsColor(hex: needsInput.dark))
        self.needsInput = Color(nsColor: needsInputNSColor)
        // The light wording stays dark amber in every theme; dark mode reuses the fill.
        needsInputText = Color(light: Theme.nsColor(hex: 0x8A5300), dark: Theme.nsColor(hex: needsInput.dark),
                               highContrastLight: Theme.nsColor(hex: 0x6B4000))
        self.working = Color(light: Theme.nsColor(hex: working.light), dark: Theme.nsColor(hex: working.dark))
        self.workingText = Color(light: Theme.nsColor(hex: workingText.light), dark: Theme.nsColor(hex: workingText.dark),
                                 highContrastLight: Theme.nsColor(hex: 0x004D00))
        // Level 0 is the same translucent ink everywhere; see `Theme.Palette.heatRamp`.
        heatRamp = [Color(light: Theme.nsColor(hex: 0x2B3140, alpha: 0.11), dark: NSColor(white: 1, alpha: 0.08),
                          highContrastLight: Theme.nsColor(hex: 0x2B3140, alpha: 0.14),
                          highContrastDark: Theme.nsColor(hex: 0x1F2430))]
            + zip(heat.light, heat.dark).map { Color(light: Theme.nsColor(hex: $0), dark: Theme.nsColor(hex: $1)) }
        if let sparkline {
            let color = Color(light: Theme.nsColor(hex: sparkline.light), dark: Theme.nsColor(hex: sparkline.dark))
            self.sparkline = color
            sparklineFill = color.opacity(0.14)
        } else {
            self.sparkline = .secondary
            sparklineFill = Color.primary.opacity(0.12)
        }
        profileHex = profiles
        profileColors = profiles.map { Color(light: Theme.nsColor(hex: $0.light), dark: Theme.nsColor(hex: $0.dark)) }
    }

    /// The original set. Its blue and violet sit close for deuteranopes.
    private static let classicProfiles: [(light: UInt32, dark: UInt32)] = [
        (0x2A78D6, 0x3987E5), (0xD4498C, 0xD55181), (0x6250D6, 0x9085E9),
        (0x1B9690, 0x33A397), (0x793974, 0x7860A0), (0x7D460B, 0xAD721C)
    ]
    /// Passes every CVD and normal-vision check, all pairs, on white and on
    /// #1B1E24, and keeps teal clear of Working green.
    private static let vividProfiles: [(light: UInt32, dark: UInt32)] = [
        (0x1D80FC, 0x458FDF), (0xF43E98, 0xF0359A), (0x5F31E7, 0x6252F3),
        (0x0E8D81, 0x058C81), (0x843B87, 0xAD2DBB), (0x854A14, 0xA05D1B)
    ]
    private static let brightNeeds: (light: UInt32, dark: UInt32) = (0xFFB31F, 0xFFBA2E)
    private static let brightWorking: (light: UInt32, dark: UInt32) = (0x0CA30C, 0x2BC95A)
    private static let brightWorkingText: (light: UInt32, dark: UInt32) = (0x006300, 0x4BE07D)
    private static let blueSlateHeat: (light: [UInt32], dark: [UInt32]) = (
        [0xC5CCE2, 0x93A0C4, 0x5C6A94, 0x283257], [0x343D5E, 0x55628F, 0x8F9CCB, 0xDEE4F7]
    )

    static let classic = ThemePalette(
        canvas: (0xF4F5F8, 0x14161B), aurora: (indigo: (0.05, 0.08), violet: (0.03, 0.05)),
        needsInput: (0xFAB219, 0xFAB219), working: (0x0CA30C, 0x0CA30C), workingText: (0x006300, 0x3DDC6F),
        heat: ([0xC9CED8, 0x9AA2B2, 0x646D80, 0x2B3140], [0x39404F, 0x5F6879, 0x98A0B1, 0xE3E6EC]),
        sparkline: nil, profiles: classicProfiles)

    static let gentle = ThemePalette(
        canvas: (0xF5F6FB, 0x151821), aurora: (indigo: (0.10, 0.15), violet: (0.07, 0.09)),
        needsInput: brightNeeds, working: brightWorking, workingText: brightWorkingText, heat: blueSlateHeat,
        sparkline: (0x7086F3, 0x8C9CFF), profiles: classicProfiles)

    static let vivid = ThemePalette(
        canvas: (0xF5F6FB, 0x151821), aurora: (indigo: (0.10, 0.15), violet: (0.07, 0.09)),
        needsInput: brightNeeds, working: brightWorking, workingText: brightWorkingText, heat: blueSlateHeat,
        sparkline: (0x7086F3, 0x8C9CFF), profiles: vividProfiles)

    static let aurora = ThemePalette(
        canvas: (0xF4F5FD, 0x141725), aurora: (indigo: (0.16, 0.24), violet: (0.11, 0.15)),
        auroraPink: (0xF43E98, 0xF0359A, (0.07, 0.10)),
        needsInput: brightNeeds, working: brightWorking, workingText: brightWorkingText,
        heat: ([0xC2CCFF, 0x8EA2FF, 0x5A73F2, 0x2F3FBF], [0x2E3A78, 0x4258C4, 0x7088FA, 0xB8C4FF]),
        sparkline: (0x4A64FF, 0x8C9CFF), profiles: vividProfiles)
}
