import AppKit
import SwiftUI
import AgentTrailCore

/// Live session state belongs to its project; saved activity remains a separate signal.
struct ProjectLiveStatusView: View {
    let activity: ProjectLiveActivity
    let sources: [AgentSource]
    let lastScan: Date?
    var isActive: Bool = true
    var demoMode: Bool = false
    let focus: (AgentSource) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showDetails = false

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

    var body: some View {
        if !activity.sessions.isEmpty {
            TimelineView(.periodic(from: .now, by: 3)) { context in
                content(now: context.date)
            }
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                countSummary(waiting: activity.waitingCount, working: activity.workingCount,
                             idle: activity.idleCount, unknown: activity.unknownCount, prominent: true,
                             canPulseWorking: isActive && isFreshScan(now: now))
                Spacer(minLength: 3)
                Text("LIVE")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.tertiary)
                Button {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) {
                        showDetails.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showDetails ? 180 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 19, height: 19)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showDetails ? "Hide live session details" : "Show live session details")
                .accessibilityLabel(showDetails ? "Hide live session details" : "Show live session details")
            }

            VStack(alignment: .leading, spacing: showDetails ? 10 : 5) {
                ForEach(profileGroups, id: \.sourceID) { group in
                    profileRow(group, now: now)
                }
            }
            .padding(.leading, 3)

            if showDetails && activity.unknownCount > 0 {
                Text("Unknown means no recognized or verified live state is available.")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(overviewTint.opacity(activity.waitingCount > 0 ? 0.055 : activity.workingCount > 0 ? 0.045 : 0.025),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(overviewTint.opacity(activity.waitingCount > 0 ? 0.16 : activity.workingCount > 0 ? 0.12 : 0.045),
                    lineWidth: 0.7))
    }

    private func profileRow(_ group: SourceLiveActivity, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    profileIdentity(group.sourceID).fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 3)
                    countSummary(waiting: group.waitingCount, working: group.workingCount,
                                 idle: group.idleCount, unknown: group.unknownCount, prominent: false)
                    focusButton(group.sourceID)
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        profileIdentity(group.sourceID)
                        Spacer(minLength: 3)
                        focusButton(group.sourceID)
                    }
                    countSummary(waiting: group.waitingCount, working: group.workingCount,
                                 idle: group.idleCount, unknown: group.unknownCount, prominent: false)
                        .padding(.leading, 10)
                }
            }

            if showDetails {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(orderedSessions(group.sessions)) { session in
                        sessionDetail(session, now: now)
                    }
                }
                .padding(.leading, 10)
                .padding(.bottom, 2)
            }
        }
    }

    private func profileIdentity(_ sourceID: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(profileColor(sourceID)).frame(width: 4, height: 4)
            Text(sourceName(sourceID))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    @ViewBuilder private func focusButton(_ sourceID: String) -> some View {
        if showDetails, let source = sources.first(where: { $0.id == sourceID }), !source.bundleIdentifier.isEmpty {
            Button { focus(source) } label: {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 17, height: 17)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(demoMode)
            .help("Focus the running \(source.name) instance")
            .accessibilityLabel("Focus \(source.name)")
        }
    }

    private func countSummary(waiting: Int, working: Int, idle: Int, unknown: Int,
                              prominent: Bool, canPulseWorking: Bool = false) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                activeCounts(waiting: waiting, working: working, prominent: prominent,
                             canPulseWorking: canPulseWorking)
                if (waiting > 0 || working > 0) && (idle > 0 || unknown > 0) { countSeparator }
                quietCounts(idle: idle, unknown: unknown, prominent: prominent)
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 3) {
                if waiting > 0 || working > 0 {
                    activeCounts(waiting: waiting, working: working, prominent: prominent,
                                 canPulseWorking: canPulseWorking)
                }
                if idle > 0 || unknown > 0 {
                    quietCounts(idle: idle, unknown: unknown, prominent: prominent)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func activeCounts(waiting: Int, working: Int, prominent: Bool, canPulseWorking: Bool) -> some View {
        HStack(spacing: 4) {
            if waiting > 0 {
                if prominent {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                countText(waiting, status: "needs input", color: .orange, prominent: prominent)
                    .help(waitingExplanation)
            }
            if working > 0 {
                if waiting > 0 { countSeparator }
                if prominent { ProjectLivePulse(color: .green, shouldPulse: canPulseWorking) }
                countText(working, status: "working", color: .green, prominent: prominent)
            }
        }
    }

    private func quietCounts(idle: Int, unknown: Int, prominent: Bool) -> some View {
        HStack(spacing: 4) {
            if idle > 0 {
                countText(idle, status: "idle", color: .secondary, prominent: prominent)
                    .help("The assistant reported a finished turn or idle state, with no explicit request for input.")
            }
            if unknown > 0 {
                if idle > 0 { countSeparator }
                countText(unknown, status: "unknown", color: .secondary, prominent: prominent)
            }
        }
    }

    private func countText(_ count: Int, status: String, color: Color, prominent: Bool) -> some View {
        Text("\(count) \(status)")
            .font(.system(size: prominent ? 10 : 9, weight: prominent ? .semibold : .regular))
            .foregroundStyle(color)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: count)
    }

    private var countSeparator: some View {
        Text("·")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
    }

    private func sessionDetail(_ session: LiveAgentSession, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if session.status == .waiting {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                Text(statusName(session.status))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(statusColor(session.status))
                if session.workspacePath != session.projectPath {
                    Label("Worktree", systemImage: "arrow.triangle.branch")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 3)
                Text(reportAge(session.updatedAt, now: now))
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Text(abbreviated(session.workspacePath))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help("Recorded workspace: \(session.workspacePath)")
        }
        .help(sessionHelp(session))
    }

    private var overviewTint: Color {
        if activity.waitingCount > 0 { return .orange }
        if activity.workingCount > 0 { return .green }
        return .primary
    }

    private func isFreshScan(now: Date) -> Bool {
        guard let lastScan else { return false }
        let age = now.timeIntervalSince(lastScan)
        return age >= -5 && age <= 10
    }

    private func sourceName(_ id: String) -> String {
        sources.first { $0.id == id }?.name ?? "Unknown profile"
    }

    private func profileColor(_ id: String) -> Color {
        ProfileColor.color(id, sources: sources)
    }

    private func orderedSessions(_ sessions: [LiveAgentSession]) -> [LiveAgentSession] {
        sessions.sorted { first, second in
            let firstOrder = statusOrder(first.status), secondOrder = statusOrder(second.status)
            if firstOrder != secondOrder { return firstOrder < secondOrder }
            if first.workspacePath != second.workspacePath { return first.workspacePath < second.workspacePath }
            return first.id < second.id
        }
    }

    private func statusOrder(_ status: LiveStatus) -> Int {
        switch status {
        case .waiting: return 0
        case .working: return 1
        case .idle: return 2
        case .unknown: return 3
        }
    }

    private func statusName(_ status: LiveStatus) -> String {
        switch status {
        case .waiting: return "Needs input"
        case .working: return "Working"
        case .idle: return "Idle"
        case .unknown: return "Unknown"
        }
    }

    private func statusColor(_ status: LiveStatus) -> Color {
        switch status {
        case .waiting: return .orange
        case .working: return .green
        case .idle: return .secondary
        case .unknown: return .secondary
        }
    }

    private func reportAge(_ date: Date, now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "Reported just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Reported \(formatter.localizedString(for: date, relativeTo: now))"
    }

    private func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    private func sessionHelp(_ session: LiveAgentSession) -> String {
        let date = session.updatedAt.formatted(date: .abbreviated, time: .standard)
        let explanation: String
        switch session.status {
        case .waiting: explanation = waitingExplanation
        case .working: explanation = "\(sourceName(session.sourceID)) has an active turn or reports working. This does not claim a file is being written."
        case .idle: explanation = "\(sourceName(session.sourceID)) reported a finished turn or idle state, with no explicit request for input."
        case .unknown: explanation = "No recognized or verified runtime status is available. Recent edits alone do not establish a live state."
        }
        return "\(explanation)\nLast report: \(date)\nSession process: PID \(String(session.pid))"
    }

    private var waitingExplanation: String {
        "The assistant reports an input request, approval request, or dialog waiting for attention. Idle alone does not imply that input is needed."
    }
}

private struct ProjectLivePulse: View {
    let color: Color
    let shouldPulse: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var isExpanded = false

    private var pulseAllowed: Bool { shouldPulse && isVisible && !reduceMotion }

    var body: some View {
        ZStack {
            if pulseAllowed {
                Circle()
                    .fill(color.opacity(isExpanded ? 0.035 : 0.22))
                    .frame(width: 6, height: 6)
                    .scaleEffect(isExpanded ? 2 : 1)
            }
            Circle().fill(color).frame(width: 5, height: 5)
        }
        .frame(width: 12, height: 12)
        .animation(pulseAllowed ? .easeInOut(duration: 1.35).repeatForever(autoreverses: true) : nil,
                   value: isExpanded)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; isExpanded = false }
        .onChange(of: pulseAllowed, initial: true) { _, active in isExpanded = active }
        .accessibilityHidden(true)
    }
}
