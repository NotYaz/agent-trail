import AppKit
import SwiftUI
import AgentTrailCore

/// A present-tense view of explicit local session status, separate from saved history.
struct LiveActivityView: View {
    @ObservedObject var store: AppStore
    var isActive: Bool = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showNotices = false

    private var workingCount: Int {
        store.liveSessions.filter { if case .working = $0.status { return true }; return false }.count
    }
    private var idleCount: Int {
        store.liveSessions.filter { if case .idle = $0.status { return true }; return false }.count
    }
    private var unknownCount: Int { store.liveSessions.count - workingCount - idleCount }

    private var groups: [LiveProfileGroup] {
        let sourceOrder = store.sources.map(\.id)
        return Dictionary(grouping: store.liveSessions, by: \.sourceID)
            .map { sourceID, sessions in
                LiveProfileGroup(id: sourceID,
                                 source: store.sources.first { $0.id == sourceID },
                                 sessions: sessions.sorted { first, second in
                                     let firstStatus = liveStatusOrder(first.status)
                                     let secondStatus = liveStatusOrder(second.status)
                                     if firstStatus != secondStatus { return firstStatus < secondStatus }
                                     let firstName = URL(fileURLWithPath: first.projectPath).lastPathComponent
                                     let secondName = URL(fileURLWithPath: second.projectPath).lastPathComponent
                                     if firstName != secondName {
                                         return firstName.localizedStandardCompare(secondName) == .orderedAscending
                                     }
                                     return first.id < second.id
                                 })
            }
            .sorted { first, second in
                let firstWorking = first.sessions.contains { liveStatusOrder($0.status) == 0 }
                let secondWorking = second.sessions.contains { liveStatusOrder($0.status) == 0 }
                if firstWorking != secondWorking { return firstWorking }
                let firstIndex = sourceOrder.firstIndex(of: first.id) ?? Int.max
                let secondIndex = sourceOrder.firstIndex(of: second.id) ?? Int.max
                return firstIndex == secondIndex ? first.id < second.id : firstIndex < secondIndex
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.liveSessions.isEmpty {
                emptyState
            } else {
                sessionList
            }
            if !store.liveNotices.isEmpty { notices }
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("Live activity")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                if store.demoMode {
                    Text("DEMO")
                        .font(.system(size: 9, weight: .semibold))
                        .tracking(0.7)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.primary.opacity(0.05), in: Capsule())
                } else if store.lastLiveScan != nil {
                    Label("Local", systemImage: "lock.shield")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help("Live state is read from local Claude session records.")
                }
            }
            HStack(spacing: 0) {
                overviewMetric(workingCount, label: "Working", color: .green)
                Divider().frame(height: 26).padding(.horizontal, 16)
                overviewMetric(idleCount, label: "Idle", color: .orange)
                Divider().frame(height: 26).padding(.horizontal, 16)
                overviewMetric(unknownCount, label: "Unknown", color: .secondary)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 13)
            .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 16)
    }

    private func overviewMetric(_ count: Int, label: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(count.formatted())
                .font(.system(size: 21, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(count > 0 ? color : .secondary)
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: count)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(label.lowercased()) sessions")
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(groups) { group in
                    profileCard(group)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .scrollIndicators(.automatic)
    }

    private func profileCard(_ group: LiveProfileGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(profileColor(group.id)).frame(width: 6, height: 6)
                Text(group.source?.name ?? "Unknown profile")
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text("\(group.sessions.count)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                Spacer(minLength: 4)
                if let source = group.source {
                    Button { store.focus(source) } label: {
                        HStack(spacing: 4) {
                            Text("Focus")
                                .font(.system(size: 10, weight: .medium))
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8, weight: .semibold))
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.demoMode)
                    .help("Focus the running \(source.name) instance")
                    .accessibilityLabel("Focus \(source.name)")
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .background(profileColor(group.id).opacity(0.035))

            VStack(spacing: 0) {
                ForEach(Array(group.sessions.enumerated()), id: \.element.id) { index, session in
                    if index > 0 {
                        Divider().padding(.horizontal, 13)
                    }
                    TimelineView(.periodic(from: .now, by: 3)) { context in
                        LiveSessionRow(session: session, lastScan: store.lastLiveScan, now: context.date,
                                       isActive: isActive)
                    }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.65),
                    in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.primary.opacity(0.065), lineWidth: 1))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No live coding sessions reported")
                .font(.system(size: 14, weight: .semibold))
            Text("Sessions appear when Claude reports local live state. Saved activity alone does not indicate whether an agent is working.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 315)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var notices: some View {
        DisclosureGroup(isExpanded: $showNotices) {
            ScrollView {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(Array(store.liveNotices.enumerated()), id: \.offset) { _, notice in
                        Text(notice)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(.top, 7)
            }
            .frame(maxHeight: 78)
        } label: {
            Label("\(store.liveNotices.count) live \(store.liveNotices.count == 1 ? "notice" : "notices")", systemImage: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(.primary.opacity(0.02))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "waveform.path")
                    .font(.system(size: 10))
                    .padding(.top, 1)
                Text("Live state from local Claude session records · updates every 3 sec")
                    .font(.system(size: 10))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private func profileColor(_ id: String) -> Color {
        let colors: [Color] = [.blue, .orange, .purple, .teal, .pink]
        return colors[(store.sources.firstIndex { $0.id == id } ?? 2) % colors.count]
    }
}

private struct LiveProfileGroup: Identifiable {
    let id: String
    let source: AgentSource?
    let sessions: [LiveAgentSession]
}

private struct LiveSessionRow: View {
    let session: LiveAgentSession
    let lastScan: Date?
    let now: Date
    let isActive: Bool

    private var projectName: String {
        let name = URL(fileURLWithPath: session.projectPath).lastPathComponent
        return name.isEmpty ? "Project" : name
    }
    private var isWorktree: Bool { session.workspacePath != session.projectPath }
    private var statusName: String {
        switch session.status {
        case .working: return "Working"
        case .idle: return "Idle"
        case .unknown: return "Unknown"
        }
    }
    private var statusColor: Color {
        switch session.status {
        case .working: return .green
        case .idle: return .orange
        case .unknown: return .secondary
        }
    }
    private var shouldPulse: Bool {
        guard isActive, case .working = session.status, let lastScan else { return false }
        let scanAge = now.timeIntervalSince(lastScan)
        return scanAge >= -5 && scanAge <= 10
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(projectName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(session.projectPath)
                Spacer(minLength: 2)
                HStack(spacing: 3) {
                    LiveStatusIndicator(color: statusColor, shouldPulse: shouldPulse)
                    Text(statusName)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(statusColor)
                }
                .help(statusHelp)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(statusName)
            }

            HStack(spacing: 5) {
                Image(systemName: isWorktree ? "arrow.triangle.branch" : "folder")
                    .font(.system(size: 9))
                Text(abbreviated(session.workspacePath))
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
            .help("Actual workspace: \(session.workspacePath)")

            HStack(spacing: 5) {
                if isWorktree {
                    Text("WORKTREE")
                        .font(.system(size: 8, weight: .medium))
                        .tracking(0.5)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 3))
                }
                Spacer()
                Text(reportAge)
                    .font(.system(size: 9))
                    .lineLimit(1)
            }
            .foregroundStyle(.tertiary)
            .help(statusHelp)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
    }

    private var statusHelp: String {
        let report = session.updatedAt.formatted(date: .abbreviated, time: .standard)
        let explanation: String
        switch session.status {
        case .working: explanation = "Claude reported working. Last status report: \(report). This does not claim a file is being written."
        case .idle: explanation = "Claude reported idle. Last status report: \(report)."
        case .unknown: explanation = "No recognized or verified status is available. Last report: \(report). Activity history is not used to infer this state."
        }
        return "\(explanation)\nSession process: PID \(String(session.pid))"
    }

    private var reportAge: String {
        let age = max(0, now.timeIntervalSince(session.updatedAt))
        if age < 60 { return "Reported just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return "Reported \(formatter.localizedString(for: session.updatedAt, relativeTo: now))"
    }

    private func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}

private func liveStatusOrder(_ status: LiveStatus) -> Int {
    switch status {
    case .working: return 0
    case .idle: return 1
    case .unknown: return 2
    }
}

private struct LiveStatusIndicator: View {
    let color: Color
    let shouldPulse: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false
    @State private var isExpanded = false

    private var pulseAllowed: Bool { shouldPulse && !reduceMotion && isVisible }

    var body: some View {
        ZStack {
            if pulseAllowed {
                Circle()
                    .fill(color.opacity(isExpanded ? 0.035 : 0.22))
                    .frame(width: 7, height: 7)
                    .scaleEffect(isExpanded ? 2.0 : 1.0)
            }
            Circle().fill(color).frame(width: 5, height: 5)
        }
        .frame(width: 14, height: 14)
        .animation(pulseAllowed ? .easeInOut(duration: 1.35).repeatForever(autoreverses: true) : nil,
                   value: isExpanded)
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false; isExpanded = false }
        .onChange(of: pulseAllowed, initial: true) { _, active in isExpanded = active }
        .accessibilityHidden(true)
    }
}
