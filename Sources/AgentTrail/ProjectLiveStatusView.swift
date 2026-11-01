import AppKit
import SwiftUI
import AgentTrailCore

/// Live session state belongs to its project; saved activity remains a separate signal.
/// Collapsed, it is one sunken line of separate counts; expanded, it lists each
/// profile and session. Status comes only from the live snapshot, never from history.
struct ProjectLiveStatusView: View {
    private let activity: ProjectLiveActivity
    private let sources: [AgentSource]
    private let lastScan: Date?
    private let isActive: Bool
    private let demoMode: Bool
    private let focus: (AgentSource) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill
    @Environment(\.referenceNow) private var referenceNow
    @State private var showDetails = false
    /// Rises only when the waiting count rises, so the hand bounces once per new request.
    @State private var waitingBounce = 0

    /// `isActive` is true only while the tab is in front and the panel is visible; it gates the pulse.
    init(activity: ProjectLiveActivity, sources: [AgentSource], lastScan: Date?, isActive: Bool = true,
         demoMode: Bool = false, focus: @escaping (AgentSource) -> Void) {
        self.activity = activity
        self.sources = sources
        self.lastScan = lastScan
        self.isActive = isActive
        self.demoMode = demoMode
        self.focus = focus
    }

    var body: some View {
        if !activity.sessions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                summaryLine
                if showDetails {
                    detailsTimeline
                        .transition(.opacity)
                }
            }
            .sunkenField(radius: Theme.Radius.control)
            .onChange(of: activity.waitingCount) { old, new in
                if new > old { waitingBounce += 1 }
            }
        }
    }

    // MARK: Collapsed line

    private var summaryLine: some View {
        HStack(spacing: Theme.Space.xs) {
            counts
            Spacer(minLength: Theme.Space.xxs)
            detailsToggle
        }
        .padding(.leading, Theme.Space.xs)
        .padding(.trailing, Theme.Space.xxs)
        .frame(height: 26)
    }

    private var counts: some View {
        let items = ProjectLiveCount.items(waiting: activity.waitingCount, working: activity.workingCount,
                                           idle: activity.idleCount, unknown: activity.unknownCount)
        let firstID = items.first?.id
        return HStack(spacing: 6) {
            ForEach(items) { (item: ProjectLiveCount) in
                if item.id != firstID { separator }
                countLabel(item)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live sessions: " + items.map(\.phrase).joined(separator: ", "))
    }

    private func countLabel(_ item: ProjectLiveCount) -> some View {
        HStack(spacing: 4) {
            glyph(for: item.kind)
            Text(item.phrase)
                .font(Theme.Typeface.micro.monospacedDigit())
                .foregroundStyle(item.kind.textColor)
                .contentTransition(.numericText(value: Double(item.count)))
                .animation(motion(Theme.Motion.quick), value: item.count)
        }
        .help(Self.explanation(for: item.kind))
    }

    @ViewBuilder private func glyph(for kind: StatusGlyph.Kind) -> some View {
        switch kind {
        case .needsInput:
            StatusGlyph(kind: .needsInput, size: 11, bounceValue: waitingBounce)
        case .working:
            workingGlyph
        case .idle, .unknown:
            StatusGlyph(kind: kind, size: 10)
        }
    }

    /// The 3 s clock exists only while a pulse is possible; it re-checks scan freshness.
    @ViewBuilder private var workingGlyph: some View {
        if canPulse {
            TimelineView(.periodic(from: .now, by: 3)) { context in
                StatusGlyph(kind: .working, size: 11, animates: isFreshScan(now: context.date))
            }
        } else {
            StatusGlyph(kind: .working, size: 11)
        }
    }

    private var canPulse: Bool { isActive && !reduceMotion && !rendersStill }

    private var separator: some View {
        Text("·")
            .font(Theme.Typeface.micro)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private var detailsToggle: some View {
        Button(action: toggleDetails) {
            HStack(spacing: 3) {
                Text("Details")
                    .font(Theme.Typeface.micro)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .imageScale(.small)
                    .rotationEffect(.degrees(showDetails ? 180 : 0))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(detailsLabel)
        .accessibilityLabel(detailsLabel)
    }

    private var detailsLabel: String {
        showDetails ? "Hide live session details" : "Show live session details"
    }

    private func toggleDetails() {
        withAnimation(motion(Theme.Motion.quick)) { showDetails.toggle() }
    }

    // MARK: Expanded details

    /// Report ages refresh with the 3 s live tick while the tab is in front, and rarely otherwise.
    private var detailsTimeline: some View {
        TimelineView(.periodic(from: .now, by: detailsInterval)) { context in
            details(now: referenceNow ?? context.date)
        }
    }

    private var detailsInterval: TimeInterval { isActive ? 3 : 60 }

    private func details(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(profileGroups) { (group: SourceLiveActivity) in
                profileSection(group, now: now)
            }
            if activity.unknownCount > 0 {
                Text("Unknown means no recognized or verified live state is available.")
                    .font(Theme.Typeface.note)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Theme.Space.xs)
        .padding(.top, Theme.Space.xs)
        .padding(.bottom, Theme.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Palette.hairline)
                .frame(height: 0.5)
        }
    }

    private func profileSection(_ group: SourceLiveActivity, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            profileHeader(group)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(orderedSessions(group.sessions)) { (session: LiveAgentSession) in
                    sessionRow(session, now: now)
                }
            }
            .padding(.leading, 12)
        }
    }

    private func profileHeader(_ group: SourceLiveActivity) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ProfileColor.color(group.sourceID, sources: sources))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(sourceName(group.sourceID))
                .font(Theme.Typeface.micro)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.xxs)
            profileCounts(group)
            focusButton(group.sourceID)
        }
    }

    private func profileCounts(_ group: SourceLiveActivity) -> some View {
        let items = ProjectLiveCount.items(waiting: group.waitingCount, working: group.workingCount,
                                           idle: group.idleCount, unknown: group.unknownCount)
        let firstID = items.first?.id
        return HStack(spacing: 4) {
            ForEach(items) { (item: ProjectLiveCount) in
                if item.id != firstID { separator }
                Text(item.phrase)
                    .font(Theme.Typeface.note.monospacedDigit())
                    .foregroundStyle(item.kind.textColor)
                    .help(Self.explanation(for: item.kind))
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(items.map(\.phrase).joined(separator: ", "))
    }

    @ViewBuilder private func focusButton(_ sourceID: String) -> some View {
        if let source = sources.first(where: { $0.id == sourceID }), !source.bundleIdentifier.isEmpty {
            Button { focus(source) } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(demoMode)
            .help("Focus the running \(source.name) instance")
            .accessibilityLabel("Focus \(source.name)")
        }
    }

    private func sessionRow(_ session: LiveAgentSession, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            sessionHeader(session, now: now)
            Text(PathFormat.abbreviate(session.workspacePath))
                .font(Theme.Typeface.mono)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Started in: \(session.workspacePath)")
        }
        .help(sessionHelp(session))
    }

    private func sessionHeader(_ session: LiveAgentSession, now: Date) -> some View {
        let kind = StatusGlyph.Kind(session.status)
        return HStack(spacing: 5) {
            StatusGlyph(kind: kind, size: 10)
            Text(kind.title)
                .font(Theme.Typeface.micro)
                .foregroundStyle(kind.textColor)
            if let label = WorkspaceLabel.make(workspace: session.workspacePath, project: session.projectPath) {
                Label(label.shortTitle, systemImage: label.symbol)
                    .font(Theme.Typeface.note)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(label.help(workspace: session.workspacePath, project: session.projectPath))
            }
            Spacer(minLength: Theme.Space.xxs)
            Text("Reported \(RelativeTime.string(for: session.updatedAt, now: now))")
                .font(Theme.Typeface.note)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: Ordering and wording

    private var profileGroups: [SourceLiveActivity] {
        activity.sources.sorted { first, second in
            let firstWaiting = first.waitingCount > 0
            let secondWaiting = second.waitingCount > 0
            if firstWaiting != secondWaiting { return firstWaiting }
            let firstWorking = first.workingCount > 0
            let secondWorking = second.workingCount > 0
            if firstWorking != secondWorking { return firstWorking }
            let firstIndex = sources.firstIndex { $0.id == first.sourceID } ?? Int.max
            let secondIndex = sources.firstIndex { $0.id == second.sourceID } ?? Int.max
            return firstIndex == secondIndex ? first.sourceID < second.sourceID : firstIndex < secondIndex
        }
    }

    private func orderedSessions(_ sessions: [LiveAgentSession]) -> [LiveAgentSession] {
        sessions.sorted { first, second in
            let firstOrder = Self.statusOrder(first.status), secondOrder = Self.statusOrder(second.status)
            if firstOrder != secondOrder { return firstOrder < secondOrder }
            if first.workspacePath != second.workspacePath { return first.workspacePath < second.workspacePath }
            return first.id < second.id
        }
    }

    private static func statusOrder(_ status: LiveStatus) -> Int {
        switch status {
        case .waiting: return 0
        case .working: return 1
        case .idle: return 2
        case .unknown: return 3
        }
    }

    private func isFreshScan(now: Date) -> Bool {
        guard let lastScan else { return false }
        let age = now.timeIntervalSince(lastScan)
        return age >= -5 && age <= 10
    }

    private func sourceName(_ id: String) -> String {
        sources.first { $0.id == id }?.name ?? "Unknown profile"
    }

    private func motion(_ base: Animation) -> Animation? {
        Theme.Motion.animation(base, reduceMotion: reduceMotion, still: rendersStill)
    }

    private func sessionHelp(_ session: LiveAgentSession) -> String {
        let date = session.updatedAt.formatted(date: .abbreviated, time: .standard)
        let explanation: String
        switch session.status {
        case .waiting: explanation = Self.waitingExplanation
        case .working: explanation = "\(sourceName(session.sourceID)) has an active turn or reports working. This does not claim a file is being written."
        case .idle: explanation = "\(sourceName(session.sourceID)) reported a finished turn or idle state, with no explicit request for input."
        case .unknown: explanation = "No recognized or verified runtime status is available. Recent edits alone do not establish a live state."
        }
        return "\(explanation)\nLast report: \(date)\nSession process: PID \(String(session.pid))"
    }

    private static func explanation(for kind: StatusGlyph.Kind) -> String {
        switch kind {
        case .needsInput: return waitingExplanation
        case .working: return "The assistant has an active turn or reports working. This does not claim a file is being written."
        case .idle: return "The assistant reported a finished turn or idle state, with no explicit request for input."
        case .unknown: return "Unknown means no recognized or verified live state is available."
        }
    }

    private static let waitingExplanation =
        "The assistant reports an input request, approval request, or dialog waiting for attention. Idle alone does not imply that input is needed."
}

/// One status count in the live line, such as "2 working".
private struct ProjectLiveCount: Identifiable {
    let kind: StatusGlyph.Kind
    let count: Int

    var id: String { kind.title }
    var phrase: String { "\(count) \(kind.title.lowercased())" }

    /// Needs input, working, idle and unknown, in that order, leaving out zeros.
    static func items(waiting: Int, working: Int, idle: Int, unknown: Int) -> [ProjectLiveCount] {
        let all = [
            ProjectLiveCount(kind: .needsInput, count: waiting),
            ProjectLiveCount(kind: .working, count: working),
            ProjectLiveCount(kind: .idle, count: idle),
            ProjectLiveCount(kind: .unknown, count: unknown)
        ]
        return all.filter { $0.count > 0 }
    }
}
