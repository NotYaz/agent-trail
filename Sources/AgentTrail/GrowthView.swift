import SwiftUI
import AgentTrailCore

// MARK: - Growth selection types

/// What the Recorded edits chart counts.
enum GrowthMeasure: String, Hashable, CaseIterable {
    case edits
    case sessions

    /// The chart card's title.
    var chartTitle: String {
        switch self {
        case .edits: return "Recorded edits"
        case .sessions: return "Saved sessions"
        }
    }

    /// The segmented-control and axis label.
    var title: String {
        switch self {
        case .edits: return "Edits"
        case .sessions: return "Sessions"
        }
    }

    /// "1 edit", "64 edits", "3 sessions".
    func describe(_ count: Int) -> String {
        switch self {
        case .edits: return GrowthText.edits(count)
        case .sessions: return GrowthText.sessions(count)
        }
    }
}

/// How the Recorded edits chart draws: bars per bucket, or a stacked running total.
enum GrowthChartMode: Hashable {
    case bars
    case runningTotal
}

/// Identity of one reveal. Fields left nil never re-reveal that surface, and a
/// history revision is never part of it, so a rescan updates values in place.
struct GrowthKey: Hashable {
    let projectPath: String?
    let period: StatsPeriod?
    let measure: GrowthMeasure?
    let mode: GrowthChartMode?

    init(projectPath: String?, period: StatsPeriod? = nil, measure: GrowthMeasure? = nil,
         mode: GrowthChartMode? = nil) {
        self.projectPath = projectPath
        self.period = period
        self.measure = measure
        self.mode = mode
    }
}

/// One chart series: a profile, or every slate profile folded into "Other profiles".
struct GrowthSeries: Identifiable, Equatable {
    let id: String
    let name: String
    let color: Color
    /// The source IDs drawn in this series.
    let sourceIDs: [String]
    let edits: Int
    let sessions: Int
    let editShare: Double
    let sessionShare: Double

    func share(for measure: GrowthMeasure) -> Double {
        measure == .edits ? editShare : sessionShare
    }

    /// Series in sources order. Profiles past the six palette slots, and IDs no
    /// profile configures, fold into one "Other profiles" series at the end.
    static func make(shares: [SourceShare], sources: [AgentSource]) -> [GrowthSeries] {
        let totalEdits = shares.reduce(0) { $0 + $1.edits }
        let totalSessions = shares.reduce(0) { $0 + $1.sessions }
        var result: [GrowthSeries] = []
        var folded: [SourceShare] = []
        for share in shares {
            if ProfileColor.seriesID(share.sourceID, sources: sources) == ProfileColor.otherSeriesID {
                folded.append(share)
                continue
            }
            result.append(series(id: share.sourceID, name: name(of: share.sourceID, sources: sources),
                                 color: ProfileColor.color(share.sourceID, sources: sources), members: [share],
                                 totalEdits: totalEdits, totalSessions: totalSessions))
        }
        if !folded.isEmpty {
            result.append(series(id: ProfileColor.otherSeriesID, name: ProfileColor.otherSeriesName,
                                 color: ProfileColor.color(for: .other), members: folded,
                                 totalEdits: totalEdits, totalSessions: totalSessions))
        }
        return result
    }

    /// The configured profile name, or "Unknown profile" like the statistics index.
    static func name(of sourceID: String, sources: [AgentSource]) -> String {
        guard let name = sources.first(where: { $0.id == sourceID })?.name, !name.isEmpty else {
            return "Unknown profile"
        }
        return name
    }

    private static func series(id: String, name: String, color: Color, members: [SourceShare],
                               totalEdits: Int, totalSessions: Int) -> GrowthSeries {
        let edits = members.reduce(0) { $0 + $1.edits }
        let sessions = members.reduce(0) { $0 + $1.sessions }
        let editShare = totalEdits > 0 ? Double(edits) / Double(totalEdits) : 0
        let sessionShare = totalSessions > 0 ? Double(sessions) / Double(totalSessions) : 0
        return GrowthSeries(id: id, name: name, color: color, sourceIDs: members.map(\.sourceID), edits: edits,
                            sessions: sessions, editShare: editShare, sessionShare: sessionShare)
    }
}

/// Growth copy shared by the tab and its cards.
enum GrowthText {
    static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(value.formatted()) \(value == 1 ? singular : plural)"
    }

    static func edits(_ value: Int) -> String { count(value, "edit", "edits") }
    static func sessions(_ value: Int) -> String { count(value, "session", "sessions") }
    static func days(_ value: Int) -> String { count(value, "day", "days") }
    static func profiles(_ value: Int) -> String { count(value, "profile", "profiles") }

    static func perActiveDay(_ value: Double?) -> String {
        guard let value else { return "No active days" }
        return "\(value.formatted(.number.precision(.fractionLength(1)))) per active day"
    }

    static func quietStretch(_ days: Int) -> String {
        guard days > 0 else { return "No quiet stretch between active days" }
        return "Longest quiet stretch \(GrowthText.days(days))"
    }

    static let streakHelp = "Local days (05:00–05:00) with at least one recorded edit, in saved history. "
        + "Today counts once it has an edit; until then yesterday keeps the streak."
    static let sessionsHelp = "Sessions mean different things per assistant: a Claude Desktop session can span "
        + "many hours; Codex counts every thread. Don't compare across assistants."
}

// MARK: - Growth tab

/// The Growth tab: KPI tiles, the Recorded edits chart, the Trail calendar, the
/// rhythm punch card, the profile mix and where edits landed. Every number comes
/// from `store.statistics(projectPath:period:)`; the selection lives in AppStore
/// because this view unmounts while another tab is shown.
struct GrowthView: View {
    @ObservedObject private var store: AppStore
    private let animatesCharts: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rendersStill) private var rendersStill
    @State private var measure: GrowthMeasure = .edits
    @State private var mode: GrowthChartMode = .bars
    /// The start of the selected chart bucket. Cleared whenever the scope changes.
    @State private var selectedBucket: DayKey?
    @State private var isSharing = false

    private static let periodOptions: [(value: StatsPeriod, title: String)] = StatsPeriod.allCases.map {
        (period: StatsPeriod) -> (value: StatsPeriod, title: String) in (value: period, title: period.rawValue)
    }

    /// VoiceOver reads "Last 30 days" where the segment shows "30D".
    private static let periodAccessibilityLabels: [StatsPeriod: String] = Dictionary(
        uniqueKeysWithValues: StatsPeriod.allCases.map { (period: StatsPeriod) -> (StatsPeriod, String) in
            (period, period.title)
        })

    init(store: AppStore, animatesCharts: Bool = true) {
        _store = ObservedObject(wrappedValue: store)
        self.animatesCharts = animatesCharts
    }

    var body: some View {
        let stats = currentStatistics
        let series = GrowthSeries.make(shares: stats.sources, sources: store.sources)
        return ScrollViewReader { proxy in
            ScrollView {
                sections(stats, series: series)
                    .padding(.horizontal, Theme.Space.gutter)
                    .padding(.vertical, Theme.Space.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: store.growthAnchor, initial: true) { _, anchor in
                consume(anchor, proxy: proxy)
            }
        }
        .onChange(of: store.growthProjectPath) { _, _ in selectedBucket = nil }
        .onChange(of: store.growthPeriod) { _, _ in selectedBucket = nil }
    }

    // MARK: State helpers

    private var currentStatistics: ActivityStatistics {
        store.statistics(projectPath: store.growthProjectPath, period: store.growthPeriod)
    }

    /// Reveals run only live; Reduce Motion and still renders get the final state.
    private var chartsAnimate: Bool { animatesCharts && !reduceMotion && !rendersStill }

    private func motion(_ base: Animation) -> Animation? {
        Theme.Motion.animation(base, reduceMotion: reduceMotion, still: rendersStill || !animatesCharts)
    }

    private var isLoading: Bool {
        if store.isScanning || store.scanProgress != nil { return true }
        if store.lastScan == nil && !store.sources.isEmpty { return true }
        // History is in, but the first index has not been applied yet.
        return store.historyRevision == 0 && !store.projects.isEmpty
    }

    private func changePeriod(_ value: StatsPeriod) {
        guard value != store.growthPeriod else { return }
        withAnimation(motion(Theme.Motion.standard)) {
            selectedBucket = nil
            store.growthFocusSourceID = nil
            store.growthPeriod = value
        }
    }

    private func selectProject(_ path: String?) {
        guard path != store.growthProjectPath else { return }
        withAnimation(motion(Theme.Motion.standard)) {
            selectedBucket = nil
            store.growthFocusSourceID = nil
            store.growthProjectPath = path
        }
    }

    private func changeMeasure(_ value: GrowthMeasure) {
        guard value != measure else { return }
        withAnimation(motion(Theme.Motion.quick)) { measure = value }
    }

    private func changeMode(_ value: GrowthChartMode) {
        guard value != mode else { return }
        withAnimation(motion(Theme.Motion.quick)) { mode = value }
    }

    private func changeFocus(_ sourceID: String?) {
        withAnimation(motion(Theme.Motion.quick)) { store.growthFocusSourceID = sourceID }
    }

    /// Selects the chart bucket holding `day`, switching back to bars if needed.
    private func selectDay(_ day: DayKey) {
        let stats = currentStatistics
        guard let start = GrowthChartMath.bucketStart(containing: day, unit: stats.unit, range: stats.range) else {
            return
        }
        withAnimation(motion(Theme.Motion.quick)) {
            mode = .bars
            selectedBucket = start
        }
    }

    private func showSection(_ anchor: GrowthAnchor) {
        store.growthAnchor = anchor
    }

    /// Scrolls to a section another view asked for, then consumes the request.
    private func consume(_ anchor: GrowthAnchor?, proxy: ScrollViewProxy) {
        guard let anchor else { return }
        let animation = motion(Theme.Motion.standard)
        Task { @MainActor in
            // A short pause lets a freshly mounted Growth lay out its sections first.
            try? await Task.sleep(for: .milliseconds(40))
            withAnimation(animation) { proxy.scrollTo(anchor, anchor: .top) }
            if store.growthAnchor == anchor { store.growthAnchor = nil }
        }
    }

    // MARK: Layout

    private func sections(_ stats: ActivityStatistics, series: [GrowthSeries]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.sectionGap) {
            header(stats)
            if store.stats.isEmpty {
                emptyState
            } else {
                kpiRow(stats)
                chartCard(stats, series: series)
                    .id(GrowthAnchor.chart)
                calendarCard(stats)
                    .id(GrowthAnchor.calendar)
                rhythmCard(stats)
                    .id(GrowthAnchor.rhythm)
                lowerSections(stats, series: series)
                footnote
            }
        }
    }

    @ViewBuilder private func lowerSections(_ stats: ActivityStatistics, series: [GrowthSeries]) -> some View {
        if !stats.sources.isEmpty {
            mixCard(stats, series: series)
                .id(GrowthAnchor.profiles)
        }
        if stats.projectPath == nil && !stats.projects.isEmpty {
            landedCard(stats)
                .id(GrowthAnchor.projects)
        }
    }

    // MARK: Header

    private func header(_ stats: ActivityStatistics) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .center, spacing: Theme.Space.xs) {
                titleBlock
                Spacer(minLength: Theme.Space.xs)
                shareButton(stats)
            }
            HStack(spacing: Theme.Space.xs) {
                projectMenu
                PillSegmented(selection: periodBinding, options: Self.periodOptions, label: "Period",
                              fillsWidth: true, accessibilityLabels: Self.periodAccessibilityLabels)
                    .frame(width: 200)
                InfoButton { GrowthAboutText(timeZone: store.activityCalendar.timeZone) }
                Spacer(minLength: 0)
            }
        }
    }

    private var titleBlock: some View {
        HStack(alignment: .center, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.xs) {
                Text("Growth")
                    .font(Theme.Typeface.title)
                    .accessibilityAddTraits(.isHeader)
                Text(scopeCaption)
                    .font(Theme.Typeface.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if store.demoMode {
                Pill(text: "Demo")
            }
            if store.isScanning {
                ProgressView()
                    .controlSize(.mini)
                    .help(store.scanProgress ?? "Indexing recorded history")
            }
        }
    }

    private var scopeCaption: String {
        let scope = store.growthProjectPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "All projects"
        return "\(scope) · \(store.growthPeriod.title) · local days"
    }

    private var projectTitle: String {
        guard let path = store.growthProjectPath else { return "All projects" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.count > 26 ? String(name.prefix(24)) + "…" : name
    }

    private var periodBinding: Binding<StatsPeriod> {
        Binding(get: { store.growthPeriod }, set: { value in changePeriod(value) })
    }

    private var projectBinding: Binding<String> {
        Binding(get: { store.growthProjectPath ?? "" }, set: { value in
            selectProject(value.isEmpty ? nil : value)
        })
    }

    private var projectMenu: some View {
        Menu {
            Picker("Project", selection: projectBinding) {
                Text("All projects").tag("")
                ForEach(GrowthProjectChoice.make(paths: store.stats.projectPaths)) { (choice: GrowthProjectChoice) in
                    Text(choice.title).tag(choice.path)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(projectTitle)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Theme.Palette.sunken, in: Capsule())
        .help("Choose the project Growth describes")
        .accessibilityLabel("Project")
        .accessibilityValue(projectTitle)
    }

    private func shareButton(_ stats: ActivityStatistics) -> some View {
        let isEmpty = stats.current.edits == 0 && stats.current.sessions == 0
        let isDisabled = store.isScanning || isEmpty
        return Button { isSharing = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .semibold))
                Text("Share")
                    .font(Theme.Typeface.caption.weight(.medium))
            }
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(Theme.Palette.sunken, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.45 : 1)
        .help(shareHelp(scanning: store.isScanning, empty: isEmpty))
        .accessibilityLabel("Share activity portrait")
        .popover(isPresented: $isSharing, arrowEdge: .bottom) {
            ShareOptionsView(store: store)
        }
    }

    private func shareHelp(scanning: Bool, empty: Bool) -> String {
        if scanning { return "Wait for history indexing to finish before exporting" }
        if empty { return "Nothing is recorded for this selection yet" }
        return "Export an image of this selection. Names are hidden unless you include them."
    }

    // MARK: KPI tiles

    private func kpiRow(_ stats: ActivityStatistics) -> some View {
        HStack(spacing: Theme.Space.cardGap) {
            editsTile(stats)
            activeDaysTile(stats)
            sessionsTile(stats)
            busiestTile(stats)
        }
        // Tiles fill their row, so the row takes the tallest tile's natural
        // height: equal tiles, and the value keeps its full display size.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func delta(_ current: Int, _ previous: Int?) -> DeltaBadge? {
        guard let previous else { return nil }
        return DeltaBadge(current: current, previous: previous)
    }

    private func editsTile(_ stats: ActivityStatistics) -> some View {
        let edits = stats.current.edits
        let previous = stats.previous?.edits
        let caption = GrowthText.perActiveDay(stats.current.editsPerActiveDay)
        let change = PercentChange.accessibility(current: edits, previous: previous)
        let sentence = ["Recorded edits", edits.formatted(), change, caption].compactMap { $0 }.joined(separator: ", ")
        return StatTile(title: "Recorded edits", value: edits.formatted(), numericValue: Double(edits),
                        caption: caption, delta: delta(edits, previous),
                        help: GrowthText.quietStretch(stats.longestQuietStretch), accessibilityLabel: sentence)
    }

    private func activeDaysTile(_ stats: ActivityStatistics) -> some View {
        let current = stats.current
        let streaks = stats.streaks
        let sentence = "Active days, \(current.activeDays) of \(GrowthText.days(current.dayCount)), "
            + "current streak \(GrowthText.days(streaks.current)), longest \(GrowthText.days(streaks.longest))"
        return StatTile(title: "Active days", value: "\(current.activeDays) / \(current.dayCount)",
                        numericValue: Double(current.activeDays),
                        caption: "Streak \(streaks.current) · best \(streaks.longest)",
                        help: GrowthText.streakHelp, accessibilityLabel: sentence,
                        action: { showSection(.calendar) })
    }

    private func sessionsTile(_ stats: ActivityStatistics) -> some View {
        let sessions = stats.current.sessions
        let previous = stats.previous?.sessions
        let change = PercentChange.accessibility(current: sessions, previous: previous)
        let sentence = ["Saved sessions", sessions.formatted(), change, "counted on start day"]
            .compactMap { $0 }.joined(separator: ", ")
        return StatTile(title: "Saved sessions", value: sessions.formatted(), numericValue: Double(sessions),
                        caption: "counted on start day", delta: delta(sessions, previous),
                        help: GrowthText.sessionsHelp, accessibilityLabel: sentence)
    }

    private func busiestTile(_ stats: ActivityStatistics) -> some View {
        guard let busiest = stats.busiestDay else {
            return StatTile(title: "Busiest day", value: "—", caption: "No edits in this period",
                            accessibilityLabel: "Busiest day, none in this period")
        }
        let calendar = store.stats.calendar
        let caption = "\(GrowthText.edits(busiest.edits)) · \(GrowthText.profiles(busiest.profiles))"
        let help = "\(DayFormat.withYear(busiest.day, calendar: calendar)) · \(GrowthText.edits(busiest.edits)) · "
            + "\(GrowthText.sessions(busiest.sessions)). Click to show it in the chart."
        return StatTile(title: "Busiest day", value: DayFormat.long(busiest.day, calendar: calendar),
                        caption: caption, help: help,
                        accessibilityLabel: "Busiest day, \(DayFormat.long(busiest.day, calendar: calendar)), \(caption)",
                        action: { selectDay(busiest.day) })
    }

    // MARK: Sections

    private func chartCard(_ stats: ActivityStatistics, series: [GrowthSeries]) -> some View {
        RecordedEditsCard(stats: stats, calendar: store.stats.calendar, series: series, measure: measure, mode: mode,
                          focus: store.growthFocusSourceID, selection: selectedBucket,
                          revealKey: GrowthKey(projectPath: store.growthProjectPath, period: store.growthPeriod,
                                               measure: measure, mode: mode),
                          animates: chartsAnimate,
                          onMeasure: { value in changeMeasure(value) },
                          onMode: { value in changeMode(value) },
                          onSelect: { start in selectedBucket = start },
                          onFocus: { sourceID in changeFocus(sourceID) })
            .equatable()
    }

    /// The calendar follows a focused profile only when it has edits in the grid.
    private func calendarFocus(_ grid: CalendarGrid) -> String? {
        guard let id = store.growthFocusSourceID, grid.sourceThresholds[id] != nil else { return nil }
        return id
    }

    private func calendarCard(_ stats: ActivityStatistics) -> some View {
        let focus = calendarFocus(stats.calendar)
        let ramp = focus.map { ProfileColor.ramp(for: $0, sources: store.sources) } ?? Theme.Palette.heatRamp
        let focusName = focus.map { GrowthSeries.name(of: $0, sources: store.sources) }
        let calendar = store.stats.calendar
        return RevealSurface(key: GrowthKey(projectPath: store.growthProjectPath), animates: chartsAnimate) { progress in
            TrailCalendarCard(grid: stats.calendar, range: stats.range, calendar: calendar, focus: focus,
                              focusName: focusName, ramp: ramp, progress: progress,
                              onSelectDay: { day in selectDay(day) })
                .equatable()
        }
    }

    private func rhythmCard(_ stats: ActivityStatistics) -> some View {
        let rollover = store.stats.calendar.rolloverHour
        return RevealSurface(key: GrowthKey(projectPath: store.growthProjectPath, period: store.growthPeriod),
                             animates: chartsAnimate) { progress in
            RhythmCard(rhythm: stats.rhythm, periodTitle: stats.period.title, rolloverHour: rollover,
                       progress: progress)
                .equatable()
        }
    }

    private func mixCard(_ stats: ActivityStatistics, series: [GrowthSeries]) -> some View {
        let focus = store.growthFocusSourceID
        let profiles = store.sources
        let calendar = store.stats.calendar
        return RevealSurface(key: GrowthKey(projectPath: store.growthProjectPath, period: store.growthPeriod),
                             animates: chartsAnimate) { progress in
            ProfileMixCard(shares: stats.sources, series: series, profiles: profiles, sharedDays: stats.sharedDays,
                           showsChange: stats.previous != nil, calendar: calendar, focus: focus,
                           progress: progress, onFocus: { sourceID in changeFocus(sourceID) })
                .equatable()
        }
    }

    private func landedCard(_ stats: ActivityStatistics) -> some View {
        let profiles = store.sources
        return RevealSurface(key: GrowthKey(projectPath: nil, period: store.growthPeriod),
                             animates: chartsAnimate) { progress in
            WhereEditsLandedCard(rows: stats.projects, touched: stats.projectsTouched, count: stats.projectCount,
                                 profiles: profiles, progress: progress,
                                 select: { path in
                                     selectProject(path)
                                     showSection(.chart)
                                 })
                .equatable()
        }
    }

    private var footnote: some View {
        HStack(alignment: .top, spacing: Theme.Space.xxs) {
            Text("Counts are confirmed tool edits on local days (05:00–05:00), not lines, commits or productivity")
                .font(Theme.Typeface.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            InfoButton { GrowthAboutText(timeZone: store.activityCalendar.timeZone) }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Space.xxs)
    }

    @ViewBuilder private var emptyState: some View {
        if isLoading {
            ContentUnavailableView {
                Label("Your history is taking shape", systemImage: "clock.arrow.circlepath")
            } description: {
                Text(store.scanProgress ?? "Growth fills in as local session history is indexed.")
            } actions: {
                ProgressView().controlSize(.small)
            }
            .frame(maxWidth: .infinity, minHeight: 380)
            .cardSurface(radius: Theme.Radius.section)
        } else {
            ContentUnavailableView {
                Label("A little work becomes a trail", systemImage: "chart.line.uptrend.xyaxis")
            } description: {
                Text("No recorded activity yet. Growth fills in once an assistant edits a file in one of your projects.")
            }
            .frame(maxWidth: .infinity, minHeight: 380)
            .cardSurface(radius: Theme.Radius.section)
        }
    }
}

// MARK: - Reveal

/// Grows its content once per key: a new key mounts a fresh stage at progress 0
/// and animates it to 1 against the final, fixed scales. Keys never include the
/// history revision, so a rescan updates values in place without re-revealing.
/// Reduce Motion, still renders and `animates == false` show the final state.
struct RevealSurface<Key: Hashable, Content: View>: View {
    private let key: Key
    private let animates: Bool
    private let content: (Double) -> Content

    init(key: Key, animates: Bool, @ViewBuilder content: @escaping (Double) -> Content) {
        self.key = key
        self.animates = animates
        self.content = content
    }

    var body: some View {
        // A ZStack keeps a departing stage from taking layout space during a crossfade.
        ZStack(alignment: .top) {
            GrowthRevealStage(animates: animates, content: content)
                .id(key)
                .transition(.opacity)
        }
    }
}

/// One reveal's own progress. Each key gets a new stage, so a departing stage
/// can finish fading without resetting the next one's progress.
private struct GrowthRevealStage<Content: View>: View {
    let animates: Bool
    let content: (Double) -> Content
    @State private var progress = 0.0

    var body: some View {
        content(animates ? progress : 1)
            .transaction { transaction in
                if !animates { transaction.animation = nil }
            }
            .task(id: animates) { await reveal() }
    }

    private func reveal() async {
        guard animates else {
            progress = 1
            return
        }
        guard progress < 1 else { return }
        // Commit one frame at zero against the final, fixed axes, then grow.
        do { try await Task.sleep(for: .milliseconds(24)) } catch { return }
        guard !Task.isCancelled else { return }
        withAnimation(Theme.Motion.reveal) { progress = 1 }
    }
}

// MARK: - Helpers

/// A project in the scope menu. Names that repeat get their parent folder.
private struct GrowthProjectChoice: Identifiable {
    let path: String
    let title: String

    var id: String { path }

    /// Sorted by name as Finder sorts, so the menu never follows index order.
    static func make(paths: [String]) -> [GrowthProjectChoice] {
        var counts: [String: Int] = [:]
        for path in paths {
            counts[URL(fileURLWithPath: path).lastPathComponent, default: 0] += 1
        }
        var choices: [GrowthProjectChoice] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent
            if counts[name, default: 0] > 1 {
                let parent = PathFormat.abbreviate(url.deletingLastPathComponent().path)
                choices.append(GrowthProjectChoice(path: path, title: "\(name) — \(parent)"))
            } else {
                choices.append(GrowthProjectChoice(path: path, title: name))
            }
        }
        return choices.sorted { (lhs: GrowthProjectChoice, rhs: GrowthProjectChoice) -> Bool in
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
        }
    }
}

/// The caveats behind every Growth number.
private struct GrowthAboutText: View {
    let timeZone: TimeZone

    private var zoneName: String {
        timeZone.localizedName(for: .generic, locale: .current) ?? timeZone.identifier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            paragraph("What counts as an edit",
                      "Claude's Edit and Write tools, Codex's completed file changes, and Grok's completed write and "
                      + "search-replace calls. One operation is one edit. Shell commands don't count.")
            paragraph("Local activity days",
                      "Days start at 05:00 (\(zoneName)), so late-night work counts toward the evening it began.")
            paragraph("Sessions",
                      "Sessions count on the day they started, and a session means different things per assistant.")
            paragraph("Delegated edits",
                      "Edits first recorded in a Claude subagent or a spawned Codex thread. Grok does not report them.")
            paragraph("Saved history",
                      "Totals cover only what assistants still keep on disk, so totals and streaks can shrink. "
                      + "Changes appear only when saved history reaches back over the previous period.")
            paragraph("What this is not",
                      "Nothing here measures productivity, code quality, lines of code or Git ancestry.")
        }
    }

    private func paragraph(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.Typeface.headline)
            Text(text)
                .font(Theme.Typeface.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
