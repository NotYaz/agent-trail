import AppKit
import SwiftUI
import AgentTrailCore

/// One project in the Projects list. Row A carries identity and the 30-day
/// trend, row B the location, row C the profile mix, row D the live block and
/// row E the latest edit with the Jump control. Every number comes from the
/// cached `ProjectTrend`; live state comes only from the live snapshot.
struct ProjectCard: View {
    private let project: ProjectOverview
    private let trend: ProjectTrend?
    private let sources: [AgentSource]
    private let runningSourceIDs: Set<String>
    private let isScanning: Bool
    private let lastLiveScan: Date?
    private let isActive: Bool
    private let demoMode: Bool
    private let location: ProjectLocation?
    private let missingFolder: MissingFolder?
    private let isUnavailable: Bool
    private let isLinking: Bool
    private let open: (AgentSource) -> Void
    private let jump: (LiveAgentSession) -> Void
    private let perform: (WorkspaceAction) -> Void
    private let reveal: () -> Void
    private let copyPath: (String) -> Void
    private let locate: (MissingFolder?) -> Void
    private let forget: () -> Void
    private let showInGrowth: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill
    @Environment(\.referenceNow) private var referenceNow
    @AppStorage(AppSettings.Key.showSessionTitles) private var showSessionTitles = true
    @State private var confirmForget = false

    /// `open` brings a profile's app forward, `jump` opens one live session and
    /// `perform` runs a folder action; all three come from the store.
    init(project: ProjectOverview, trend: ProjectTrend?, sources: [AgentSource], runningSourceIDs: Set<String>,
         isScanning: Bool, lastLiveScan: Date?, isActive: Bool, demoMode: Bool, location: ProjectLocation?,
         missingFolder: MissingFolder?, isUnavailable: Bool, isLinking: Bool,
         open: @escaping (AgentSource) -> Void, jump: @escaping (LiveAgentSession) -> Void,
         perform: @escaping (WorkspaceAction) -> Void, reveal: @escaping () -> Void,
         copyPath: @escaping (String) -> Void, locate: @escaping (MissingFolder?) -> Void,
         forget: @escaping () -> Void, showInGrowth: @escaping () -> Void) {
        self.project = project
        self.trend = trend
        self.sources = sources
        self.runningSourceIDs = runningSourceIDs
        self.isScanning = isScanning
        self.lastLiveScan = lastLiveScan
        self.isActive = isActive
        self.demoMode = demoMode
        self.location = location
        self.missingFolder = missingFolder
        self.isUnavailable = isUnavailable
        self.isLinking = isLinking
        self.open = open
        self.jump = jump
        self.perform = perform
        self.reveal = reveal
        self.copyPath = copyPath
        self.locate = locate
        self.forget = forget
        self.showInGrowth = showInGrowth
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: clockInterval)) { context in
            card(now: referenceNow ?? context.date)
        }
        .contextMenu { projectActions }
        .alert(forgetTitle, isPresented: $confirmForget) {
            Button("Forget", role: .destructive) { forget() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Session logs that mention those paths stop counting toward this project. A link still at an earlier path is learned again. Nothing on disk changes.")
        }
    }

    /// Relative ages refresh every 30 s while the tab is in front and rarely otherwise.
    private var clockInterval: TimeInterval { isActive ? 30 : 300 }

    private func card(now: Date) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            headerRow
            locationRows
            if let trend = visibleTrend { mixBar(trend) }
            liveRow
            lastEditRow(now: now)
            if let missingFolder { missingFolderRow(missingFolder) }
        }
        .padding(Theme.Space.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(attention: attention)
        .contentShape(Theme.Radius.shape(Theme.Radius.card))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary(now: now))
    }

    // MARK: Row A: identity and trend

    private var headerRow: some View {
        HStack(spacing: Theme.Space.xs) {
            profileStack
            Text(displayName)
                .font(Theme.Typeface.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.xxs)
            if let trend = visibleTrend { trendCluster(trend) }
            actionsMenu
        }
        .frame(minHeight: 22)
    }

    /// The live line carries the working pulse; the stack shows status rings only.
    private var profileStack: some View {
        ProfileStack(members: stackMembers)
    }

    private func trendCluster(_ trend: ProjectTrend) -> some View {
        Button(action: showInGrowth) {
            HStack(spacing: 6) {
                Sparkline(values: trend.daily30, height: 20, accessibilityLabel: sparklineLabel(trend))
                    .frame(width: 76)
                editsMetric(trend)
                DeltaBadge(current: trend.edits30, previous: badgePrevious(trend))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ProjectCardPressStyle())
        .fixedSize()
        .help(trendHelp(trend))
        .accessibilityLabel(sparklineLabel(trend))
        .accessibilityHint("Shows this project in Growth")
    }

    private func editsMetric(_ trend: ProjectTrend) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(CompactNumber.string(trend.edits30))
                .font(Theme.Typeface.cardMetric)
                .contentTransition(.numericText(value: Double(trend.edits30)))
                .animation(motion(Theme.Motion.quick), value: trend.edits30)
            Text("30D")
                .font(Theme.Typeface.micro)
                .foregroundStyle(.secondary)
        }
    }

    private var actionsMenu: some View {
        Menu {
            projectActions
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Project actions")
        .accessibilityLabel("Actions for \(displayName)")
    }

    // MARK: Row B: location

    private var locationRows: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            pathRow
            if let location, !location.previousLocations.isEmpty { previousRow(location) }
        }
    }

    private var pathRow: some View {
        HStack(spacing: 6) {
            if isUnavailable { unavailableLabel } else { pathText }
            Spacer(minLength: Theme.Space.xxs)
            if canLocateFolder { locateButton(nil) }
            badges
        }
        .frame(minHeight: 18)
    }

    private var pathText: some View {
        Text(PathFormat.abbreviate(project.path))
            .font(Theme.Typeface.mono)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(project.path)
    }

    private var unavailableLabel: some View {
        HStack(spacing: 6) {
            Label("Folder not found", systemImage: "questionmark.folder")
                .font(Theme.Typeface.micro)
                .foregroundStyle(Theme.Palette.needsInputText)
                .fixedSize()
            Text(PathFormat.abbreviate(project.path))
                .font(Theme.Typeface.mono)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Project folder not found at \(project.path)")
        .help(unavailableHelp)
    }

    @ViewBuilder private var badges: some View {
        if project.isShared {
            Pill(text: "Shared", symbol: "person.2")
                .help("More than one assistant profile worked in this project")
        }
        if let momentum = trend?.momentum { momentumPill(momentum) }
    }

    @ViewBuilder private func momentumPill(_ momentum: Momentum) -> some View {
        switch momentum {
        case .new:
            Pill(text: "New", symbol: "sparkles")
                .help("The first recorded edit in this project landed within the last 7 days.")
        case .dormant:
            Pill(text: "Dormant", symbol: "moon.zzz")
                .help("No recorded edit in this project in the last 14 days.")
        }
    }

    private func previousRow(_ location: ProjectLocation) -> some View {
        Label(previousTitle(location), systemImage: "clock.arrow.circlepath")
            .font(Theme.Typeface.note)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(previousHelp(location))
            .accessibilityLabel("Previously at \(location.previousPaths.joined(separator: ", "))")
    }

    // MARK: Row C: profile mix

    private func mixBar(_ trend: ProjectTrend) -> some View {
        MixBar(segments: mixSegments(trend), height: 4, accessibilityLabel: mixAccessibilityLabel(trend))
    }

    private func mixSegments(_ trend: ProjectTrend) -> [MixBar.Segment] {
        let total = max(trend.mix.reduce(0) { $0 + $1.edits }, 1)
        let window = trend.mixIsAllTime ? "in all saved history" : "in 30 days"
        let note = profilesWithoutEdits(trend)
        return trend.mix.map { (entry: SourceCount) -> MixBar.Segment in
            let share = PercentFormat.share(Double(entry.edits) / Double(total))
            var help = "\(sourceName(entry.sourceID)) · \(share) · \(Self.plural(entry.edits, "edit")) \(window)"
            if let note { help += "\n" + note }
            return MixBar.Segment(id: entry.sourceID, color: sourceColor(entry.sourceID), value: entry.edits, help: help)
        }
    }

    private func mixAccessibilityLabel(_ trend: ProjectTrend) -> String {
        let total = max(trend.mix.reduce(0) { $0 + $1.edits }, 1)
        let shares = trend.mix.map { (entry: SourceCount) -> String in
            let percent = Int((Double(entry.edits) / Double(total) * 100).rounded())
            let spoken = percent == 0 ? "less than 1 percent" : "\(percent) percent"
            return "\(sourceName(entry.sourceID)) \(spoken)"
        }
        let window = trend.mixIsAllTime ? "all saved history" : "30 days"
        var label = "Profile mix, \(window): " + shares.joined(separator: ", ")
        if let note = profilesWithoutEdits(trend) { label += ". " + note }
        return label
    }

    /// Profiles on the project that the mix bar cannot draw because they have no edits in its window.
    private func profilesWithoutEdits(_ trend: ProjectTrend) -> String? {
        let withEdits = Set(trend.mix.map(\.sourceID))
        let names = orderedSourceIDs.filter { !withEdits.contains($0) }.map { sourceName($0) }
        guard !names.isEmpty else { return nil }
        let heading = trend.mixIsAllTime ? "Sessions without recorded edits" : "No recorded edits in 30 days"
        return "\(heading): \(names.joined(separator: ", "))"
    }

    // MARK: Row D: live

    @ViewBuilder private var liveRow: some View {
        if let live = project.live {
            ProjectLiveStatusView(activity: live, sources: sources, lastScan: lastLiveScan,
                                  isActive: isActive, demoMode: demoMode, focus: open, jump: jump)
        } else {
            Text(noReportText)
                .font(Theme.Typeface.note)
                .foregroundStyle(.secondary)
                .help("A missing live report does not establish that a project is idle.")
        }
    }

    private var noReportText: String {
        lastLiveScan == nil ? "Checking live status…" : "No live sessions reported"
    }

    // MARK: Row E: last edit and the Jump control

    /// The Jump control wins the space: when both do not fit at full width,
    /// the edit summary shortens to "Edited ● 5 min. ago" first, keeping the
    /// workspace chip while it fits, so a worktree edit stays visible.
    private func lastEditRow(now: Date) -> some View {
        let control = jumpControl(now: now)
        return ViewThatFits(in: .horizontal) {
            lastEditLayout(now: now, style: .full, control: control)
            lastEditLayout(now: now, style: .compactWithChip, control: control)
            lastEditLayout(now: now, style: .compact, control: control)
        }
    }

    private enum EditSummaryStyle {
        case full, compactWithChip, compact
    }

    private func lastEditLayout(now: Date, style: EditSummaryStyle, control: JumpControl) -> some View {
        HStack(spacing: 6) {
            switch style {
            case .full: editSummary(now: now)
            case .compactWithChip: compactEditSummary(now: now, showChip: true)
            case .compact: compactEditSummary(now: now, showChip: false)
            }
            Spacer(minLength: Theme.Space.xs)
            control
        }
    }

    private func jumpControl(now: Date) -> JumpControl {
        JumpControl(entries: jumpEntries(now: now), projectName: displayName, projectPath: project.path,
                    profiles: jumpProfiles, jump: jump, perform: perform, focus: open)
    }

    /// Live sessions in Jump order: waiting longest first, then working, idle, unknown.
    private func jumpEntries(now: Date) -> [JumpControl.Entry] {
        guard let live = project.live else { return [] }
        return LiveSessionRanking.ordered(live.sessions).map { (session: LiveAgentSession) -> JumpControl.Entry in
            jumpEntry(session, now: now)
        }
    }

    private func jumpEntry(_ session: LiveAgentSession, now: Date) -> JumpControl.Entry {
        let since = session.details.stateSince
        return JumpControl.Entry(session: session,
                                 label: SessionLabel.make(session, showTitles: showSessionTitles),
                                 title: SessionLabel.title(session, showTitles: showSessionTitles),
                                 needsAction: SessionLabel.needsAction(session, showTitles: showSessionTitles),
                                 profileName: sourceName(session.sourceID), tint: sourceColor(session.sourceID),
                                 age: ElapsedFormat.compact(since: since, now: now),
                                 spokenAge: ElapsedFormat.spoken(since: since, now: now))
    }

    /// "Bring {profile} forward" for each profile on the project with a desktop app.
    private var jumpProfiles: [JumpControl.Profile] {
        focusSources.map { (source: AgentSource) -> JumpControl.Profile in
            JumpControl.Profile(source: source, tint: sourceColor(source.id),
                                isRunning: runningSourceIDs.contains(source.id))
        }
    }

    /// "Edited ● 5 min. ago": the profile lives in the dot's color, help and VoiceOver.
    /// Help and VoiceOver also name the workspace, since the chip may not fit.
    @ViewBuilder private func compactEditSummary(now: Date, showChip: Bool) -> some View {
        if let edit = project.history?.latestEdit, let date = edit.latestEdit {
            HStack(spacing: 5) {
                Text("Edited")
                    .foregroundStyle(.secondary)
                profileDot(edit.sourceID)
                Text(RelativeTime.string(for: date, now: now))
                    .foregroundStyle(.secondary)
                if showChip, let label = workspaceLabel(for: edit) { workspaceChip(label, edit: edit) }
            }
            .font(Theme.Typeface.caption)
            .lineLimit(1)
            .help(compactEditHelp(edit, date: date, now: now))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(compactEditAccessibilityLabel(edit, date: date, now: now))
        } else {
            editSummary(now: now)
        }
    }

    private func compactEditHelp(_ edit: ProjectActivity, date: Date, now: Date) -> String {
        let when = date.formatted(date: .abbreviated, time: .standard)
        var text = "Last edit by \(sourceName(edit.sourceID)) · \(when)"
        if let label = workspaceLabel(for: edit) { text += "\n" + workspaceHelp(label, edit: edit) }
        return withLatestActivity(text + "\n" + editExplanation, now: now)
    }

    /// "Last edit 1 min. ago by Codex, Worktree · navigation".
    private func compactEditAccessibilityLabel(_ edit: ProjectActivity, date: Date, now: Date) -> String {
        var text = "Last edit \(RelativeTime.string(for: date, now: now)) by \(sourceName(edit.sourceID))"
        if let label = workspaceLabel(for: edit) { text += ", " + label.title(abbreviate: PathFormat.abbreviate) }
        return text
    }

    @ViewBuilder private func editSummary(now: Date) -> some View {
        if let edit = project.history?.latestEdit, let date = edit.latestEdit {
            lastEditLine(edit, date: date, now: now)
        } else {
            Text(noEditText)
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(withLatestActivity(editExplanation, now: now))
        }
    }

    private func lastEditLine(_ edit: ProjectActivity, date: Date, now: Date) -> some View {
        HStack(spacing: 5) {
            Text("Last edit")
                .foregroundStyle(.secondary)
                .fixedSize()
            profileDot(edit.sourceID)
            Text(sourceName(edit.sourceID))
                .fontWeight(.medium)
                .lineLimit(1)
            Text("·")
                .foregroundStyle(.secondary)
            Text(RelativeTime.string(for: date, now: now))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
            if let label = workspaceLabel(for: edit) { workspaceChip(label, edit: edit) }
        }
        .font(Theme.Typeface.caption)
        .help(withLatestActivity("\(editExplanation) \(date.formatted(date: .abbreviated, time: .standard))", now: now))
    }

    private func workspaceLabel(for edit: ProjectActivity) -> WorkspaceLabel? {
        WorkspaceLabel.make(workspace: edit.latestEditWorkspacePath, project: project.path)
    }

    private func workspaceChip(_ label: WorkspaceLabel, edit: ProjectActivity) -> some View {
        Pill(text: label.shortTitle, symbol: label.symbol)
            .help(workspaceHelp(label, edit: edit))
    }

    /// "Worktree · navigation" and where the edit landed.
    private func workspaceHelp(_ label: WorkspaceLabel, edit: ProjectActivity) -> String {
        let workspace = edit.latestEditWorkspacePath ?? project.path
        return label.title(abbreviate: PathFormat.abbreviate) + "\n"
            + label.help(workspace: workspace, project: project.path)
    }

    private func profileDot(_ sourceID: String) -> some View {
        Circle()
            .fill(sourceColor(sourceID))
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }

    private var noEditText: String {
        if isScanning { return "Checking edit history…" }
        if project.history == nil { return "Saved history not indexed yet" }
        return "No recorded file edits"
    }

    private var editExplanation: String {
        "Confirmed recorded file edits; shell commands and external changes are not attributed."
    }

    /// Latest saved activity lives in help only, never as a second line.
    private func withLatestActivity(_ text: String, now: Date) -> String {
        guard let activity = latestActivity else { return text }
        let when = RelativeTime.string(for: activity.latestActivity, now: now)
        let details = [
            "Latest activity ● \(sourceName(activity.sourceID)) · \(when)",
            "The most recent saved session activity, which may not include a file change.",
            "Workspace: \(activity.workspacePath ?? project.path)",
            activity.latestActivity.formatted(date: .abbreviated, time: .standard)
        ]
        return text + "\n\n" + details.joined(separator: "\n")
    }

    // MARK: Missing folder

    private func missingFolderRow(_ missing: MissingFolder) -> some View {
        HStack(spacing: 6) {
            Label(missingFolderTitle(missing), systemImage: "questionmark.folder")
                .font(Theme.Typeface.note)
                .foregroundStyle(Theme.Palette.needsInputText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Space.xxs)
            locateButton(missing)
        }
        .help("\(missing.path)\nIf this folder was moved, choose its new location so these edits join that project. If it was deleted, there is nothing to do.")
    }

    private func missingFolderTitle(_ missing: MissingFolder) -> String {
        let noun = missing.editCount == 1 ? "edit" : "edits"
        let folder = URL(fileURLWithPath: missing.path).lastPathComponent
        return "\(missing.editCount) \(noun) in a folder that no longer exists · \(folder)"
    }

    @ViewBuilder private func locateButton(_ missing: MissingFolder?) -> some View {
        if isLinking {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Linking folder…")
                    .font(Theme.Typeface.note)
                    .foregroundStyle(.secondary)
            }
        } else {
            Button("Locate…") { locate(missing) }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(demoMode)
                .help(locateHelp)
                .accessibilityLabel("Locate the moved folder for \(project.name)")
        }
    }

    private var locateHelp: String {
        if demoMode { return "Not available with sample data" }
        return "Choose where this project lives now. Agent Trail checks the folder's Git metadata and links the earlier path to it."
    }

    private var unavailableHelp: String {
        if canLocateFolder {
            return "This folder is no longer at \(project.path). If it was moved, locate it so its history follows it."
        }
        return "This folder is no longer at \(project.path). Its recorded history is kept here."
    }

    // MARK: Actions

    @ViewBuilder private var projectActions: some View {
        Button("Show in Growth", systemImage: "chart.line.uptrend.xyaxis") { showInGrowth() }
            .disabled(trend == nil)
        Divider()
        Button("Reveal in Finder", systemImage: "folder") { reveal() }
            .disabled(isUnavailable)
        Button("Copy project path", systemImage: "doc.on.doc") { copyPath(project.path) }
        earlierPathActions
        if canLocateFolder || missingFolder != nil {
            Divider()
            Button("Locate moved folder…", systemImage: "questionmark.folder") { locate(locateTarget) }
                .disabled(demoMode || isLinking)
        }
        if hasPreviousLocations {
            Divider()
            Button("Forget earlier locations…", role: .destructive) { confirmForget = true }
                .disabled(demoMode)
        }
    }

    @ViewBuilder private var earlierPathActions: some View {
        if let location, !location.previousLocations.isEmpty {
            if location.previousLocations.count == 1, let earlier = location.previousPaths.first {
                Button("Copy earlier path", systemImage: "clock.arrow.circlepath") { copyPath(earlier) }
            } else {
                Menu("Copy earlier path") {
                    ForEach(location.previousPaths, id: \.self) { (earlier: String) in
                        Button(PathFormat.abbreviate(earlier)) { copyPath(earlier) }
                    }
                }
            }
        }
    }

    /// A vanished project folder can be located only when Agent Trail knew it
    /// as a checkout; a plain launch folder has no evidence to check against.
    private var canLocateFolder: Bool { isUnavailable && location != nil }

    private var locateTarget: MissingFolder? {
        if canLocateFolder { return nil }
        return missingFolder
    }

    private var hasPreviousLocations: Bool {
        guard let location else { return false }
        return !location.previousLocations.isEmpty
    }

    private var forgetTitle: String { "Forget earlier locations of “\(project.name)”?" }

    private func previousTitle(_ location: ProjectLocation) -> String {
        if location.previousLocations.count == 1, let earlier = location.previousPaths.first {
            return "Previously at · \(PathFormat.abbreviate(earlier))"
        }
        return "Previously at · \(location.previousLocations.count) earlier locations"
    }

    private func previousHelp(_ location: ProjectLocation) -> String {
        let lines = location.previousLocations.map { (earlier: PreviousLocation) -> String in
            let how: String
            switch earlier.origin {
            case .link: how = "a link pointed here"
            case .move: how = "the folder moved"
            case .manual: how = "you linked it"
            }
            let shadow = earlier.shadowedSince == nil ? "" : " · another folder is there now, so only older records count"
            return "• \(earlier.path) — \(how), noticed \(earlier.observedAt.formatted(date: .abbreviated, time: .omitted))\(shadow)"
        }
        return (["Agent Trail remembers where this folder used to be, so older session logs still count here."] + lines
                + ["Use the project menu to copy or forget these."]).joined(separator: "\n")
    }

    // MARK: Accessibility

    /// "{name}{, shared}{, live counts | , no live report}, {edits30} recorded edits in 30 days
    /// {, change}{, dormant}, last edit {relative} by {profile}".
    private func accessibilitySummary(now: Date) -> String {
        var parts = [displayName]
        if project.isShared { parts.append("shared") }
        parts.append(contentsOf: liveDescription)
        parts.append(contentsOf: historyDescription)
        if let edit = project.history?.latestEdit, let date = edit.latestEdit {
            parts.append("last edit \(RelativeTime.string(for: date, now: now)) by \(sourceName(edit.sourceID))")
        }
        return parts.joined(separator: ", ")
    }

    private var liveDescription: [String] {
        guard let live = project.live else { return ["no live report"] }
        var parts: [String] = []
        if live.waitingCount > 0 {
            parts.append(live.waitingCount == 1 ? "1 needs input" : "\(live.waitingCount) need input")
        }
        if live.workingCount > 0 { parts.append("\(live.workingCount) working") }
        if live.idleCount > 0 { parts.append("\(live.idleCount) idle") }
        if live.unknownCount > 0 { parts.append("\(live.unknownCount) unknown") }
        return parts
    }

    private var historyDescription: [String] {
        guard let trend else { return [] }
        guard trend.totalEdits > 0 else { return ["no recorded edits"] }
        var parts = ["\(Self.plural(trend.edits30, "recorded edit")) in 30 days"]
        if let change = PercentChange.accessibility(current: trend.edits30, previous: badgePrevious(trend)) {
            parts.append(change)
        }
        if trend.momentum == .dormant { parts.append("dormant") }
        return parts
    }

    // MARK: Derived values

    /// Live-only projects and projects without edits never show a trend.
    private var visibleTrend: ProjectTrend? {
        guard let trend, trend.totalEdits > 0 else { return nil }
        return trend
    }

    /// A new project's previous window is empty by definition, so its "New"
    /// chip already says what the badge would; the badge stays for every other case.
    /// Saved history that does not reach back over the previous 30 days gives no
    /// comparison: assistants delete old sessions, so that window may just be unrecorded.
    private func badgePrevious(_ trend: ProjectTrend) -> Int? {
        if trend.momentum == .new || !trend.hasPrevious30 { return nil }
        return trend.previous30
    }

    private func sparklineLabel(_ trend: ProjectTrend) -> String {
        var parts = ["30-day recorded edits", "\(trend.edits30.formatted()) in total"]
        if let change = PercentChange.accessibility(current: trend.edits30, previous: badgePrevious(trend)) {
            parts.append(change)
        }
        return parts.joined(separator: ", ")
    }

    private func trendHelp(_ trend: ProjectTrend) -> String {
        var lines = [
            "Recorded edits per local day (05:00–05:00) over the last 30 days.",
            "Last 30 days: \(Self.plural(trend.edits30, "edit")) · previous 30: \(trend.previous30.formatted())",
            "Last 7 days: \(Self.plural(trend.edits7, "edit")) · previous 7: \(trend.previous7.formatted())",
            "All saved history: \(Self.plural(trend.totalEdits, "edit")) · \(Self.plural(trend.totalSessions, "session"))"
        ]
        if trend.currentStreak > 0 { lines.append("Day streak: \(Self.plural(trend.currentStreak, "day"))") }
        lines.append("Click to show this project in Growth.")
        return lines.joined(separator: "\n")
    }

    private var attention: AttentionEdge? {
        guard let live = project.live else { return nil }
        return AttentionEdge.make(waiting: live.waitingCount, working: live.workingCount)
    }

    /// Profiles on the project (history and live) in sources order; ids missing
    /// from the configured sources follow, so no evidence is hidden.
    private var orderedSourceIDs: [String] {
        let present = project.sourceIDs
        let presentSet = Set(present)
        let known = sources.map(\.id).filter { presentSet.contains($0) }
        let knownSet = Set(known)
        return known + present.filter { !knownSet.contains($0) }
    }

    private var stackMembers: [ProfileStack.Member] {
        let groups = project.live?.sources ?? []
        return orderedSourceIDs.map { (id: String) -> ProfileStack.Member in
            let group = groups.first { $0.sourceID == id }
            return ProfileStack.Member(id: id, color: sourceColor(id), name: sourceName(id),
                                       status: Self.status(of: group))
        }
    }

    /// The most urgent live status of one profile; nil without a live report.
    private static func status(of group: SourceLiveActivity?) -> LiveStatus? {
        guard let group else { return nil }
        if group.waitingCount > 0 { return .waiting }
        if group.workingCount > 0 { return .working }
        if group.unknownCount > 0 { return .unknown }
        if group.idleCount > 0 { return .idle }
        return nil
    }

    /// Profiles on the project that have a desktop app to focus.
    private var focusSources: [AgentSource] {
        let present = Set(project.sourceIDs)
        return sources.filter { present.contains($0.id) && !$0.bundleIdentifier.isEmpty }
    }

    private var latestActivity: ProjectActivity? {
        project.history?.activities.max { $0.latestActivity < $1.latestActivity }
    }

    private var displayName: String { project.name.isEmpty ? project.path : project.name }

    private func sourceName(_ id: String) -> String {
        sources.first { $0.id == id }?.name ?? id
    }

    private func sourceColor(_ id: String) -> Color {
        ProfileColor.color(id, sources: sources)
    }

    private func motion(_ base: Animation) -> Animation? {
        Theme.Motion.animation(base, reduceMotion: reduceMotion, still: rendersStill)
    }

    private static func plural(_ count: Int, _ noun: String) -> String {
        "\(count.formatted()) \(count == 1 ? noun : noun + "s")"
    }
}

/// Inline card controls dim while pressed instead of drawing a bezel.
private struct ProjectCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}
