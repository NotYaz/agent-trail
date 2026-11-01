import AppKit
import SwiftUI

/// Design tokens shared by the panel, Growth and the Profiles window. Views use
/// these names instead of literal sizes and colors so both tabs read as one app.
enum Theme {
    /// The spacing scale. One 16pt gutter is used everywhere.
    enum Space {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let l: CGFloat = 20
        static let xl: CGFloat = 24
        static let gutter: CGFloat = 16
        static let cardPadding: CGFloat = 12
        static let sectionPadding: CGFloat = 14
        static let cardGap: CGFloat = 8
        static let sectionGap: CGFloat = 12
    }

    /// Corner radii. Every rounded shape is continuous.
    enum Radius {
        static let cell: CGFloat = 3
        static let control: CGFloat = 8
        static let card: CGFloat = 12
        static let section: CGFloat = 16

        static func shape(_ radius: CGFloat) -> RoundedRectangle {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
        }
    }

    /// System type ramp with a 10pt floor. Counts use monospaced digits so they
    /// do not jitter while they change.
    enum Typeface {
        static let display = Font.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit()
        static let metric = Font.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit()
        static let cardMetric = Font.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit()
        static let title = Font.system(size: 15, weight: .semibold)
        static let headline = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 12)
        static let caption = Font.system(size: 11)
        static let micro = Font.system(size: 10, weight: .medium)
        /// Paths and identifiers; pair it with `.secondary`.
        static let mono = Font.system(size: 10.5, design: .monospaced)
        /// Helper copy under form fields, at the 10pt floor.
        static let note = Font.system(size: 10)
    }

    /// Dynamic colors. Each resolves for light, dark and both Increase Contrast
    /// appearances, so the live panel and the render path's `view.appearance` agree.
    enum Palette {
        // Surfaces
        static let canvas = Color(light: Theme.nsColor(hex: 0xF4F5F8), dark: Theme.nsColor(hex: 0x14161B))
        static let surface = Color(light: NSColor(white: 1, alpha: 0.80), dark: NSColor(white: 1, alpha: 0.045),
                                   highContrastLight: NSColor(white: 1, alpha: 0.90),
                                   highContrastDark: NSColor(white: 1, alpha: 0.145))
        /// The selected pill or tab on a sunken track; plain surface is too faint there in dark mode.
        static let raised = Color(light: NSColor(white: 1, alpha: 0.96), dark: NSColor(white: 1, alpha: 0.11),
                                  highContrastLight: NSColor(white: 1, alpha: 1),
                                  highContrastDark: NSColor(white: 1, alpha: 0.20))
        static let sunken = Color(light: NSColor(white: 0, alpha: 0.045), dark: NSColor(white: 1, alpha: 0.04),
                                  highContrastLight: NSColor(white: 0, alpha: 0.09),
                                  highContrastDark: NSColor(white: 1, alpha: 0.08))
        static let hairline = Color(light: NSColor(white: 0, alpha: 0.08), dark: NSColor(white: 1, alpha: 0.08),
                                    highContrastLight: NSColor(white: 0, alpha: 0.16),
                                    highContrastDark: NSColor(white: 1, alpha: 0.16))
        /// Card edge, top of the gradient. Light mode uses one flat stroke, so top and bottom match there.
        static let glassEdgeTop = Color(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.14),
                                        highContrastLight: NSColor(white: 0, alpha: 0.14),
                                        highContrastDark: NSColor(white: 1, alpha: 0.28))
        static let glassEdgeBottom = Color(light: NSColor(white: 0, alpha: 0.07), dark: NSColor(white: 1, alpha: 0.04),
                                           highContrastLight: NSColor(white: 0, alpha: 0.14),
                                           highContrastDark: NSColor(white: 1, alpha: 0.08))
        /// Light mode lifts cards with a soft shadow; dark mode has none.
        static let surfaceShadow = Color(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 0, alpha: 0))

        // Status, reserved for live state. Always paired with a glyph and a word.
        static let needsInput = Color(light: Theme.nsColor(hex: 0xFAB219), dark: Theme.nsColor(hex: 0xFAB219))
        static let needsInputText = Color(light: Theme.nsColor(hex: 0x8A5300), dark: Theme.nsColor(hex: 0xFAB219),
                                          highContrastLight: Theme.nsColor(hex: 0x6B4000))
        static let working = Color(light: Theme.nsColor(hex: 0x0CA30C), dark: Theme.nsColor(hex: 0x0CA30C))
        static let workingText = Color(light: Theme.nsColor(hex: 0x006300), dark: Theme.nsColor(hex: 0x3DDC6F),
                                       highContrastLight: Theme.nsColor(hex: 0x004D00))
        static let unknown = Color(light: Theme.nsColor(hex: 0x8A93A6), dark: Theme.nsColor(hex: 0x8A93A6))
        static let error = Color(light: Theme.nsColor(hex: 0xD03B3B), dark: Theme.nsColor(hex: 0xD03B3B))
        /// Error wording; the fill alone is under 4.5:1 on dark window backgrounds.
        static let errorText = Color(light: Theme.nsColor(hex: 0xB3261E), dark: Theme.nsColor(hex: 0xFF6961))

        // Static aurora. It never animates and never reacts to live state.
        static let auroraIndigo = Color(light: Theme.nsColor(hex: 0x4F6BED, alpha: 0.05),
                                        dark: Theme.nsColor(hex: 0x4F6BED, alpha: 0.08))
        static let auroraViolet = Color(light: Theme.nsColor(hex: 0xA178FF, alpha: 0.03),
                                        dark: Theme.nsColor(hex: 0xA178FF, alpha: 0.05))

        /// Single-hue slate magnitude ramp: level 0 is empty, 1-4 are quartiles.
        /// Level 0 is a translucent ink, about 1.2:1 over the card surface whether
        /// it sits on the opaque canvas or the live material, so empty days, dimmed
        /// days before history and undrawn future days stay apart. Increase Contrast
        /// dark keeps the solid, which reads as a darker hole on its brighter surface
        /// and stays below level 1.
        static let heatRamp: [Color] = [
            Color(light: Theme.nsColor(hex: 0x2B3140, alpha: 0.11), dark: NSColor(white: 1, alpha: 0.08),
                  highContrastLight: Theme.nsColor(hex: 0x2B3140, alpha: 0.14),
                  highContrastDark: Theme.nsColor(hex: 0x1F2430)),
            Color(light: Theme.nsColor(hex: 0xC9CED8), dark: Theme.nsColor(hex: 0x39404F)),
            Color(light: Theme.nsColor(hex: 0x9AA2B2), dark: Theme.nsColor(hex: 0x5F6879)),
            Color(light: Theme.nsColor(hex: 0x646D80), dark: Theme.nsColor(hex: 0x98A0B1)),
            Color(light: Theme.nsColor(hex: 0x2B3140), dark: Theme.nsColor(hex: 0xE3E6EC))
        ]

        static func heat(_ level: Int) -> Color {
            heatRamp[min(max(level, 0), heatRamp.count - 1)]
        }

        /// The menu-bar tint while a session needs input. AppKit needs an NSColor.
        static let needsInputNSColor = Theme.nsColor(hex: 0xFAB219)

        /// Fixed colors for the exported share card. ImageRenderer carries no
        /// NSAppearance, so nothing here is dynamic.
        enum Share {
            static let background = Theme.color(hex: 0x0B0F17)
            static let panelTop = Theme.color(hex: 0x111725)
            static let panelBottom = Theme.color(hex: 0x0A0E16)
            static let indigo = Theme.color(hex: 0x4F6BED)
            static let violet = Theme.color(hex: 0xA178FF)
            static let glowIndigo = Theme.color(hex: 0x4F6BED, opacity: 0.12)
            static let glowViolet = Theme.color(hex: 0xA178FF, opacity: 0.07)
            static let brand = Theme.color(hex: 0x8ABAFF)
            static let stroke = Color.white.opacity(0.075)
            static let hairline = Color.white.opacity(0.10)
            static let headline = Color.white.opacity(0.96)
            static let numeral = Color.white.opacity(0.96)
            static let text = Color.white.opacity(0.83)
            static let secondaryText = Color.white.opacity(0.45)
            static let faintText = Color.white.opacity(0.30)
            /// The trail underline under each metric, leading to trailing.
            static let underline: [Color] = [indigo, violet]
            /// White-ink magnitude ramp for the mini strip: level 0 is empty.
            static let inkRamp: [Color] = [
                Color.white.opacity(0.06), Color.white.opacity(0.22), Color.white.opacity(0.42),
                Color.white.opacity(0.66), Color.white.opacity(0.92)
            ]
        }
    }

    /// Animation tokens. Use `animation(_:reduceMotion:still:)` so Reduce Motion
    /// and still renders always get the final state immediately.
    enum Motion {
        static let quick: Animation = .snappy(duration: 0.2)
        static let standard: Animation = .smooth(duration: 0.35)
        static let reveal: Animation = .smooth(duration: 0.45)
        /// Tab switches: opacity plus a 5pt offset.
        static let tab: Animation = .easeOut(duration: 0.22)
        /// Sparkline draw-in, once per mount.
        static let sparklineDraw: Animation = .easeOut(duration: 0.5)
        /// Trail calendar column fade-in: 12ms per column, capped at 0.3s in total.
        static let calendarStagger: Double = 0.012
        static let calendarStaggerCap: Double = 0.3

        static func animation(_ base: Animation, reduceMotion: Bool, still: Bool) -> Animation? {
            reduceMotion || still ? nil : base
        }
    }

    /// The appearances every dynamic color distinguishes.
    static let appearanceNames: [NSAppearance.Name] = [
        .aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua
    ]

    /// An sRGB NSColor from a 0xRRGGBB literal.
    static func nsColor(hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// A fixed (non-adaptive) sRGB Color from a 0xRRGGBB literal.
    static func color(hex: UInt32, opacity: Double = 1) -> Color {
        Color(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

extension Color {
    /// A color that follows the effective appearance, including Increase Contrast.
    /// High-contrast variants fall back to the plain light or dark value.
    init(light: NSColor, dark: NSColor, highContrastLight: NSColor? = nil, highContrastDark: NSColor? = nil) {
        let resolved = NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: Theme.appearanceNames)
            if match == NSAppearance.Name.darkAqua { return dark }
            if match == NSAppearance.Name.accessibilityHighContrastAqua { return highContrastLight ?? light }
            if match == NSAppearance.Name.accessibilityHighContrastDarkAqua { return highContrastDark ?? dark }
            return light
        }
        self.init(nsColor: resolved)
    }
}

// MARK: - Environment

private struct RendersStillKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ReferenceNowKey: EnvironmentKey {
    static let defaultValue: Date? = nil
}

extension EnvironmentValues {
    /// True for offscreen renders: continuous effects stop and reveals jump to the end.
    var rendersStill: Bool {
        get { self[RendersStillKey.self] }
        set { self[RendersStillKey.self] = newValue }
    }

    /// A pinned clock for deterministic renders. Nil means use the real time.
    var referenceNow: Date? {
        get { self[ReferenceNowKey.self] }
        set { self[ReferenceNowKey.self] = newValue }
    }
}

// MARK: - Surfaces

/// The leading edge a card shows for live attention. There is no tinted wash.
enum AttentionEdge: Equatable {
    case needsInput
    case working

    var color: Color {
        switch self {
        case .needsInput: return Theme.Palette.needsInput
        case .working: return Theme.Palette.working
        }
    }

    /// Needs input wins over working; no live sessions means no edge.
    static func make(waiting: Int, working: Int) -> AttentionEdge? {
        if waiting > 0 { return .needsInput }
        if working > 0 { return .working }
        return nil
    }
}

extension View {
    /// Card, tile and section surface: a light shadow in light mode, a glass-edge
    /// stroke in dark mode, and an optional 3pt attention edge clipped to the shape.
    func cardSurface(radius: CGFloat = Theme.Radius.card, attention: AttentionEdge? = nil) -> some View {
        modifier(CardSurfaceModifier(radius: radius, attention: attention))
    }

    /// Search fields, segmented tracks, chart wells and empty cells.
    func sunkenField(radius: CGFloat = Theme.Radius.control) -> some View {
        modifier(SunkenFieldModifier(radius: radius))
    }

    /// Material plus the static aurora live; the opaque canvas plus the aurora
    /// for renders, because cacheDisplay flattens materials.
    func panelBackground(opaque: Bool) -> some View {
        background { PanelBackdrop(opaque: opaque) }
    }

    /// Pinned bars: material live, opaque canvas when `rendersStill` is set.
    func chromeSurface() -> some View {
        modifier(ChromeSurfaceModifier())
    }
}

private struct CardSurfaceModifier: ViewModifier {
    let radius: CGFloat
    let attention: AttentionEdge?
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle { Theme.Radius.shape(radius) }

    /// 0.5pt light, 0.75pt dark, 1pt with Increase Contrast.
    private var strokeWidth: CGFloat {
        if contrast == .increased { return 1 }
        return colorScheme == .dark ? 0.75 : 0.5
    }

    func body(content: Content) -> some View {
        content
            .background { fill }
            .overlay { edge }
    }

    private var fill: some View {
        ZStack(alignment: .leading) {
            shape.fill(Theme.Palette.surface)
            if let attention {
                Rectangle().fill(attention.color).frame(width: 3)
            }
        }
        .clipShape(shape)
        .shadow(color: Theme.Palette.surfaceShadow, radius: 6, x: 0, y: 2)
    }

    private var edge: some View {
        shape.strokeBorder(LinearGradient(colors: [Theme.Palette.glassEdgeTop, Theme.Palette.glassEdgeBottom],
                                          startPoint: .top, endPoint: .bottom),
                           lineWidth: strokeWidth)
            .allowsHitTesting(false)
    }
}

private struct SunkenFieldModifier: ViewModifier {
    let radius: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .background(Theme.Palette.sunken, in: Theme.Radius.shape(radius))
            .overlay {
                if contrast == .increased {
                    Theme.Radius.shape(radius).strokeBorder(Theme.Palette.hairline, lineWidth: 1)
                }
            }
    }
}

private struct ChromeSurfaceModifier: ViewModifier {
    @Environment(\.rendersStill) private var rendersStill

    func body(content: Content) -> some View {
        content.background {
            if rendersStill {
                Theme.Palette.canvas
            } else {
                Rectangle().fill(.regularMaterial)
            }
        }
    }
}

/// The panel backdrop. Exposed so a window or popover can place it directly.
struct PanelBackdrop: View {
    private let opaque: Bool

    init(opaque: Bool) {
        self.opaque = opaque
    }

    var body: some View {
        ZStack {
            if opaque {
                Theme.Palette.canvas
            } else {
                Rectangle().fill(.regularMaterial)
            }
            RadialGradient(colors: [Theme.Palette.auroraIndigo, Theme.Palette.auroraIndigo.opacity(0)],
                           center: .topLeading, startRadius: 0, endRadius: 340)
            RadialGradient(colors: [Theme.Palette.auroraViolet, Theme.Palette.auroraViolet.opacity(0)],
                           center: .bottomTrailing, startRadius: 0, endRadius: 300)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
