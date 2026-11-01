import SwiftUI
import AgentTrailCore

/// The Share popover: a live preview of the exported card, the scope and
/// period it covers, a names toggle (off by default), what the image never
/// contains, and the export button. There is no rhythm option: the portrait
/// carries day totals only, so hours can never reach an image.
struct ShareOptionsView: View {
    @ObservedObject private var store: AppStore
    @State private var showNames = false
    @State private var memo: ShareOptionsMemo
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill

    init(store: AppStore) {
        self.store = store
        _memo = State(initialValue: ShareOptionsMemo())
    }

    private var key: ShareOptionsKey {
        ShareOptionsKey(projectPath: store.growthProjectPath, period: store.growthPeriod,
                        showNames: showNames, revision: store.historyRevision)
    }

    /// Memoized per scope, period, names and index revision, so live ticks
    /// while the popover is open never rescan.
    private var summary: PortraitSummary {
        memo.summary(for: key, store: store)
    }

    private var motion: Animation? {
        Theme.Motion.animation(Theme.Motion.quick, reduceMotion: reduceMotion, still: rendersStill)
    }

    var body: some View {
        let summary = self.summary
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            header
            // A ZStack, so the crossfade on the names toggle never stacks two previews.
            ZStack(alignment: .topLeading) {
                ShareOptionsPreview(summary: summary, sources: store.sources, sampleData: store.demoMode)
                    .id(summary.namesShown)
                    .transition(.opacity)
            }
            .frame(width: ShareOptionsPreview.size.width, height: ShareOptionsPreview.size.height)
            ShareOptionsScopeLine(scope: scopeName, summary: summary)
            namesToggle
            ShareOptionsPrivacyNote()
            exportRow(summary)
        }
        .padding(Theme.Space.m)
        .frame(width: ShareOptionsPreview.size.width + Theme.Space.m * 2, alignment: .leading)
        .animation(motion, value: showNames)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
            Text("Share activity portrait")
                .font(Theme.Typeface.headline)
            Spacer(minLength: Theme.Space.xs)
            if store.demoMode {
                Pill(text: "Sample data")
            }
        }
    }

    /// The real scope, for the person sharing; the card itself follows the toggle.
    private var scopeName: String {
        guard let path = store.growthProjectPath else { return "All projects" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty || name == "/" ? "Project" : name
    }

    private var namesHint: String {
        showNames ? "Project and profile names appear on the image."
            : "Names are replaced with “My project” and “Agent 1”, “Agent 2”…"
    }

    private var namesToggle: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Theme.Space.xs) {
                Text("Show project and profile names")
                    .font(Theme.Typeface.body)
                    .accessibilityHidden(true)
                Spacer(minLength: Theme.Space.xs)
                Toggle("Show project and profile names", isOn: $showNames)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }
            Text(namesHint)
                .font(Theme.Typeface.note)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func exportRow(_ summary: PortraitSummary) -> some View {
        let isEmpty = summary.edits == 0 && summary.sessions == 0
        return HStack(spacing: Theme.Space.xs) {
            Text("PNG · 2000 × 1400")
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: Theme.Space.xs)
            Button("Export PNG…") { export(summary) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(store.isScanning || isEmpty)
                .help(exportHelp(isEmpty: isEmpty))
        }
    }

    private func exportHelp(isEmpty: Bool) -> String {
        if store.isScanning { return "Wait for history indexing to finish before exporting" }
        if isEmpty { return "There is no recorded activity to export in this period" }
        return "Save the image to a location you choose. Nothing is uploaded."
    }

    /// The popover closes first so the save panel is not stacked over it.
    private func export(_ summary: PortraitSummary) {
        let sources = store.sources
        let sampleData = store.demoMode
        dismiss()
        Task { @MainActor in
            ActivityShareExporter.export(summary: summary, sources: sources, sampleData: sampleData)
        }
    }
}

// MARK: - Pieces

private struct ShareOptionsKey: Equatable {
    let projectPath: String?
    let period: StatsPeriod
    let showNames: Bool
    let revision: Int
}

/// One cached portrait. Writing to it from `body` is safe: nothing observes it.
@MainActor
private final class ShareOptionsMemo {
    private var key: ShareOptionsKey?
    private var cached: PortraitSummary?

    func summary(for key: ShareOptionsKey, store: AppStore) -> PortraitSummary {
        if let cached, self.key == key { return cached }
        let made = store.portrait(projectPath: key.projectPath, period: key.period, showNames: key.showNames)
        self.key = key
        cached = made
        return made
    }
}

/// The 1000×700 card at 0.35 scale in a 350×245 frame.
private struct ShareOptionsPreview: View {
    static let scale: CGFloat = 0.35
    static let size = CGSize(width: 350, height: 245)

    let summary: PortraitSummary
    let sources: [AgentSource]
    let sampleData: Bool

    private var shape: RoundedRectangle { Theme.Radius.shape(Theme.Radius.control) }

    private var accessibilityDescription: String {
        let headline = summary.headline.replacingOccurrences(of: "\n", with: " ")
        let names = summary.namesShown ? "names included" : "names hidden"
        return "\(headline) \(summary.scopeTitle), \(summary.periodTitle), \(summary.dateRangeText), \(names)"
    }

    var body: some View {
        ActivityShareCard(summary: summary, sources: sources, sampleData: sampleData)
            .equatable()
            .scaleEffect(Self.scale, anchor: .topLeading)
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Theme.Palette.hairline, lineWidth: 0.5) }
            .shadow(color: Theme.Palette.surfaceShadow, radius: 6, x: 0, y: 2)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preview of the exported image")
            .accessibilityValue(accessibilityDescription)
    }
}

private struct ShareOptionsScopeLine: View {
    let scope: String
    let summary: PortraitSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "calendar")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("\(scope) · \(summary.periodTitle) · \(summary.dateRangeText)")
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ShareOptionsPrivacyNote: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "eye.slash")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Folder paths are never included. Dates, totals and day patterns remain visible.")
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sunkenField()
    }
}
