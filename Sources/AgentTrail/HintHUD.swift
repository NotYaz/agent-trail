import AppKit

/// A short hint under the menu-bar icon, such as "In Claude · Second, pick
/// “Landing copy pass”". It is a borderless, non-activating panel: it never
/// becomes key or main, ignores the mouse, and fades out on its own. A newer
/// hint replaces the one on screen.
///
/// Hint text can carry a conversation title. It is shown and announced only;
/// never log it.
@MainActor
enum HintHUD {
    /// The status button's frame in screen coordinates. The status item sets it;
    /// without it the hint sits at the top-right of the main screen.
    static var anchorProvider: (() -> NSRect?)?

    static func show(_ text: String, duration: TimeInterval = 3.5) {
        show(text, symbol: nil, duration: duration)
    }

    /// `symbol` is an SF Symbol shown before the text in secondary ink.
    static func show(_ text: String, symbol: String?, duration: TimeInterval = 3.5) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        controller.present(trimmed, symbol: symbol, duration: min(max(duration, 1), 15))
    }

    /// Fades the current hint out early, for example when the panel opens.
    static func dismiss() {
        controller.dismissNow()
    }

    private static let controller = HintHUDController()
}

/// Owns the one panel. Every hint bumps `generation`, so a timer or fade from
/// an earlier hint can never hide a newer one.
@MainActor
private final class HintHUDController {
    private static let cornerRadius: CGFloat = 10
    private static let maxTextWidth: CGFloat = 320
    private static let insets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    private static let gapBelowAnchor: CGFloat = 6

    private var panel: HintPanel?
    private let label = NSTextField(wrappingLabelWithString: "")
    private let icon = NSImageView()
    private var generation = 0

    func present(_ text: String, symbol: String?, duration: TimeInterval) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        configure(text: text, symbol: symbol)
        let size = contentSize()
        panel.setFrame(frame(for: size), display: true)
        panel.invalidateShadow()

        generation += 1
        let current = generation
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        announce(text)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            self?.fadeOut(generation: current)
        }
    }

    func dismissNow() {
        fadeOut(generation: generation)
    }

    private func fadeOut(generation expected: Int) {
        guard expected == generation, let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == expected else { return }
                self.panel?.orderOut(nil)
            }
        })
    }

    // MARK: Building

    private func makePanel() -> HintPanel {
        let panel = HintPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 32),
                              styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.setAccessibilityElement(false)
        panel.contentView = makeContent()
        return panel
    }

    private func makeContent() -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.maskImage(radius: Self.cornerRadius)

        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.preferredMaxLayoutWidth = Self.maxTextWidth
        label.isSelectable = false

        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        let insets = Self.insets
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: insets.left),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -insets.right),
            stack.topAnchor.constraint(equalTo: effect.topAnchor, constant: insets.top),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor, constant: -insets.bottom)
        ])
        return effect
    }

    private func configure(text: String, symbol: String?) {
        label.stringValue = text
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            icon.image = image
            icon.isHidden = false
        } else {
            icon.image = nil
            icon.isHidden = true
        }
    }

    private func contentSize() -> NSSize {
        let textSize = label.sizeThatFits(NSSize(width: Self.maxTextWidth, height: 200))
        let textWidth = min(ceil(textSize.width), Self.maxTextWidth)
        let iconWidth: CGFloat = icon.isHidden ? 0 : ceil(icon.intrinsicContentSize.width) + 7
        let insets = Self.insets
        let height = max(ceil(textSize.height), 16) + insets.top + insets.bottom
        return NSSize(width: textWidth + iconWidth + insets.left + insets.right, height: height)
    }

    /// Centered under the anchor and kept inside that screen's visible frame.
    private func frame(for size: NSSize) -> NSRect {
        let anchor = HintHUD.anchorProvider?()
        let screen = anchor.flatMap(Self.screen(containing:)) ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 875)
        var origin: NSPoint
        if let anchor, anchor.width > 0, anchor.height > 0 {
            origin = NSPoint(x: anchor.midX - size.width / 2, y: anchor.minY - Self.gapBelowAnchor - size.height)
        } else {
            origin = NSPoint(x: visible.maxX - size.width - 12, y: visible.maxY - Self.gapBelowAnchor - size.height)
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }

    private static func screen(containing rect: NSRect) -> NSScreen? {
        let point = NSPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(point) }
    }

    /// VoiceOver users hear the hint, since they may not find the panel.
    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: text,
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// A stretchable rounded mask, so the behind-window blur is clipped cleanly.
    private static func maskImage(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Never key, never main: showing a hint must not take focus from the app the
/// user just switched to.
private final class HintPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
