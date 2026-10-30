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
                ProjectLivePulse(color: overviewColor,
                                 shouldPulse: activity.workingCount > 0 && isActive && isFreshScan(now: now))
                countSummary(working: activity.workingCount, idle: activity.idleCount,
                             unknown: activity.unknownCount, prominent: true)
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
        .background(activity.workingCount > 0 ? Color.green.opacity(0.045) : Color.primary.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(activity.workingCount > 0 ? Color.green.opacity(0.12) : Color.primary.opacity(0.045),
                    lineWidth: 0.7))
    }

    private func profileRow(_ group: SourceLiveActivity, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Circle().fill(profileColor(group.sourceID)).frame(width: 4, height: 4)
                Text(sourceName(group.sourceID))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 3)
                countSummary(working: group.workingCount, idle: group.idleCount,
                             unknown: group.unknownCount, prominent: false)
                if showDetails, let source = sources.first(where: { $0.id == group.sourceID }) {
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

    private func countSummary(working: Int, idle: Int, unknown: Int, prominent: Bool) -> some View {
        HStack(spacing: 4) {
            if working > 0 {
                countText(working, status: "working", color: .green, prominent: prominent)
            }
            if idle > 0 {
                if working > 0 { countSeparator }
                countText(idle, status: "idle", color: prominent && working == 0 ? .orange : .secondary,
                          prominent: prominent)
            }
            if unknown > 0 {
                if working > 0 || idle > 0 { countSeparator }
                countText(unknown, status: "unknown", color: .secondary, prominent: prominent)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
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
                .help("Actual workspace: \(session.workspacePath)")
        }
        .help(sessionHelp(session))
    }

    private var overviewColor: Color {
        if activity.workingCount > 0 { return .green }
        if activity.idleCount > 0 { return .orange }
        return .secondary
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
        let colors: [Color] = [.blue, .orange, .purple, .teal, .pink]
        return colors[(sources.firstIndex { $0.id == id } ?? 2) % colors.count]
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
        case .working: return 0
        case .idle: return 1
        case .unknown: return 2
        }
    }

    private func statusName(_ status: LiveStatus) -> String {
        switch status {
        case .working: return "Working"
        case .idle: return "Idle"
        case .unknown: return "Unknown"
        }
    }

    private func statusColor(_ status: LiveStatus) -> Color {
        switch status {
        case .working: return .green
        case .idle: return .orange
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
        let explanation = session.status == .unknown
            ? "No recognized or verified status is available. Saved history is not used to infer this state."
            : "Claude reported \(statusName(session.status).lowercased()). This does not claim a file is being written."
        return "\(explanation)\nLast report: \(date)\nSession process: PID \(String(session.pid))"
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
