import SwiftUI
import Charts
import AgentTrailCore

struct ActivityGardenView: View {
    @ObservedObject var store: AppStore
    let compact: Bool
    let animatesCharts: Bool
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var selectedProject = ""
    @State private var period: GardenPeriod = .month
    @State private var inspection: GardenInspection?
    @State private var chartInspection: GardenChartInspection?

    init(store: AppStore, compact: Bool = false, animatesCharts: Bool = true) {
        self.store = store
        self.compact = compact
        self.animatesCharts = animatesCharts
    }

    private var reduceMotion: Bool { accessibilityReduceMotion || !animatesCharts }

    private var context: GardenContext {
        GardenContext(projectID: selectedProject, period: period, start: startDate, end: endDate)
    }
    private var inspectedDay: GardenRecord? {
        guard let inspection, inspection.context == context else { return nil }
        return records.first { $0.id == inspection.recordID }
    }
    private var selectedChartDate: Date? {
        guard let chartInspection, chartInspection.context == context else { return nil }
        return chartInspection.date
    }
    private var contextAnimation: Animation? { reduceMotion ? nil : .smooth(duration: GardenMotion.duration) }
    private var projectSelection: Binding<String> {
        Binding(get: { selectedProject }, set: { value in
            guard value != selectedProject else { return }
            clearInspection()
            selectedProject = value
        })
    }
    private var periodSelection: Binding<GardenPeriod> {
        Binding(get: { period }, set: { value in
            guard value != period else { return }
            clearInspection()
            period = value
        })
    }

    private var projects: [ProjectSummary] {
        selectedProject.isEmpty ? store.projects : store.projects.filter { $0.id == selectedProject }
    }

    private var allRecords: [GardenRecord] {
        let records = projects.flatMap { project in
            project.activities.flatMap { activity in
                activity.history.map { GardenRecord(sourceID: activity.sourceID, day: $0.day,
                                                     edits: $0.editCount, sessions: $0.sessionCount) }
            }
        }
        return Dictionary(grouping: records, by: \.id).values.compactMap { values in
            guard let first = values.first else { return nil }
            return GardenRecord(sourceID: first.sourceID, day: first.day,
                                edits: values.reduce(0) { $0 + $1.edits },
                                sessions: values.reduce(0) { $0 + $1.sessions })
        }.sorted {
            if $0.day == $1.day { return $0.sourceID < $1.sourceID }
            return $0.day < $1.day
        }
    }

    private var startDate: Date {
        if let days = period.days { return today.addingTimeInterval(-Double(days - 1) * 86_400) }
        return min(allRecords.first?.day ?? today, today)
    }
    private var today: Date { ActivityDay.start(of: Date()) }
    private var endDate: Date {
        max(today, period == .all ? (allRecords.last?.day ?? today) : today).addingTimeInterval(86_400)
    }
    private var records: [GardenRecord] {
        allRecords.filter { $0.day >= startDate && $0.day < endDate && ($0.edits > 0 || $0.sessions > 0) }
    }
    private var series: [GardenSeries] {
        let grouped = Dictionary(grouping: records, by: \.sourceID)
        let sourceOrder = store.sources.map(\.id)
        return grouped.keys.sorted {
            (sourceOrder.firstIndex(of: $0) ?? Int.max, $0) < (sourceOrder.firstIndex(of: $1) ?? Int.max, $1)
        }.map { id in
            GardenSeries(id: id, name: sourceName(id), color: GardenPalette.color(id, sources: store.sources),
                         records: grouped[id]!.sorted { $0.day < $1.day })
        }
    }
    private var editCount: Int { records.reduce(0) { $0 + $1.edits } }
    private var sessionCount: Int { records.reduce(0) { $0 + $1.sessions } }
    private var rootName: String {
        if projects.count == 1 { return projects[0].name }
        return "\(projects.count) projects"
    }
    private var exportProjects: [ProjectSummary] {
        projects.map { project in
            var result = project
            result.activities = project.activities.map { activity in
                var updated = activity
                updated.history = activity.history.filter { $0.day >= startDate && $0.day < endDate }
                updated.sessionCount = updated.history.reduce(0) { $0 + $1.sessionCount }
                return updated
            }
            return result
        }
    }

    var body: some View {
        // A departing surface keeps its own immutable records while the next one
        // reveals, rather than asking Charts to morph unrelated project data.
        let presentation = GardenPresentation(context: context, rootName: rootName, records: records,
                                              series: series, axisStride: axisStride)
        return ScrollView {
            VStack(alignment: .leading, spacing: compact ? 14 : 19) {
                header
                metrics
                ZStack(alignment: .top) {
                    GardenRevealSurface(reduceMotion: reduceMotion) { progress in
                        VStack(spacing: compact ? 14 : 19) {
                            if presentation.records.isEmpty {
                                emptyGarden
                            } else {
                                growthMap(presentation, progress: progress)
                                dailyChart(presentation, progress: progress)
                            }
                        }
                    }
                    .id(context)
                    .transition(.opacity)
                }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: context)
                footer
            }
            .padding(compact ? 18 : 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            LinearGradient(colors: [Color(red: 0.065, green: 0.081, blue: 0.107),
                                    Color(red: 0.042, green: 0.052, blue: 0.073)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .environment(\.colorScheme, .dark)
        .frame(minWidth: compact ? 0 : 820, minHeight: compact ? 0 : 650)
        .onChange(of: store.projects.map(\.id)) { _, ids in
            if !selectedProject.isEmpty && !ids.contains(selectedProject) { projectSelection.wrappedValue = "" }
        }
    }

    @ViewBuilder
    private var header: some View {
        if compact {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    heading
                    Spacer(minLength: 8)
                    shareButton
                }
                HStack(spacing: 12) {
                    projectPicker.frame(maxWidth: .infinity)
                    periodPicker.frame(width: 180)
                }
            }
        } else {
            HStack(alignment: .center, spacing: 16) {
                heading
                Spacer(minLength: 12)
                projectPicker.frame(width: 160)
                periodPicker.frame(width: 180)
                shareButton
            }
        }
    }

    private var heading: some View {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Text("Project growth")
                        .font(.system(size: compact ? 22 : 26, weight: .semibold))
                        .tracking(-0.6)
                    if store.demoMode {
                        Text("DEMO")
                            .font(.system(size: 9, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 4)
                            .background(.white.opacity(0.06), in: Capsule())
                    }
                }
                HStack(spacing: 6) {
                    Text("Recorded work, over time")
                    if store.isScanning {
                        ProgressView().controlSize(.mini)
                            .help(store.scanProgress ?? "Indexing recorded history")
                    }
                }
                .font(.system(size: compact ? 11 : 12))
                .foregroundStyle(.secondary)
            }
    }

    private var projectPicker: some View {
            Picker("Project", selection: projectSelection) {
                Text("All projects").tag("")
                ForEach(store.projects) { project in
                    Text(project.name).tag(project.id).help(project.path)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.regular)
    }

    private var periodPicker: some View {
            Picker("Period", selection: periodSelection) {
                ForEach(GardenPeriod.allCases) { option in Text(option.rawValue).tag(option) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .help("Filter the recorded UTC days shown in the map, chart, and export")
    }

    private var shareButton: some View {
            Button {
                ActivityShareExporter.export(projects: exportProjects, sources: store.sources,
                                             anonymize: true, sampleData: store.demoMode)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .disabled(records.isEmpty || store.isScanning)
            .help(store.isScanning ? "Wait for history indexing to finish before exporting" : "Save an anonymized image of the selected projects and period")
    }

    private var metrics: some View {
        HStack(spacing: 0) {
            GardenMetric(value: editCount, title: "RECORDED EDITS", note: "Successful file operations", color: .white, compact: compact)
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1, height: 35)
            GardenMetric(value: sessionCount, title: "SESSIONS", note: "Counted on their first UTC day", color: .white, compact: compact)
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1, height: 35)
            GardenMetric(value: series.count, title: "ACTIVE PROFILES", note: "With recorded activity in this period", color: .white, compact: compact)
        }
        .padding(.vertical, compact ? 12 : 16)
        .animation(contextAnimation, value: editCount)
        .animation(contextAnimation, value: sessionCount)
        .animation(contextAnimation, value: series.count)
        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.055), lineWidth: 1))
    }

    private func growthMap(_ presentation: GardenPresentation, progress: Double) -> some View {
        let renderedContext = presentation.context
        let inspectedDay = inspection.flatMap { value in
            value.context == renderedContext ? presentation.records.first { $0.id == value.recordID } : nil
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Growth map").font(.system(size: 13, weight: .semibold))
                    Text("Project → profile → active day")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let inspectedDay {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(GardenFormat.day(inspectedDay.day)) · \(presentation.sourceName(inspectedDay.sourceID))")
                            .font(.system(size: 10, weight: .medium))
                            .lineLimit(1).truncationMode(.middle)
                        Text("\(inspectedDay.edits) \(inspectedDay.edits == 1 ? "edit" : "edits") · \(inspectedDay.sessions) \(inspectedDay.sessions == 1 ? "session" : "sessions")")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: compact ? 205 : 320, alignment: .trailing)
                    .transition(.opacity)
                } else {
                    Text("Explore a node to see the day")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, compact ? 15 : 20)
            .padding(.top, compact ? 14 : 17)

            GardenMap(rootName: presentation.rootName, series: presentation.series,
                      start: renderedContext.start, end: renderedContext.end,
                      compact: compact, progress: progress, inspectedID: inspectedDay?.id, inspect: { record in
                          // A departing graph can still deliver a queued hover event.
                          guard renderedContext == context, records.contains(where: { $0.id == record.id }) else { return }
                          inspection = GardenInspection(context: renderedContext, recordID: record.id)
                      })
                .frame(height: max(compact ? 150 : 174, CGFloat(presentation.series.count) * (compact ? 58 : 65)))
                .padding(.horizontal, compact ? 8 : 14)
                .animation(contextAnimation, value: progress)

            HStack(spacing: compact ? 10 : 14) {
                HStack(spacing: 5) {
                    Circle().fill(.white.opacity(0.65)).frame(width: 5, height: 5)
                    Text(compact ? "Larger · more edits" : "Larger nodes · more edits")
                }
                HStack(spacing: 5) {
                    Circle().stroke(.white.opacity(0.5), lineWidth: 1).frame(width: 5, height: 5)
                    Text(compact ? "Hollow · sessions only" : "Hollow nodes · sessions only")
                }
                Spacer()
                Text("UTC days →")
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, compact ? 15 : 20)
            .padding(.bottom, compact ? 12 : 15)
        }
        .background(GardenPalette.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.055), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Growth map. Recorded activity grouped by project, profile, and UTC day. Connections do not represent Git ancestry.")
    }

    private func dailyChart(_ presentation: GardenPresentation, progress: Double) -> some View {
        let renderedContext = presentation.context
        let selectedChartDate = chartInspection.flatMap { $0.context == renderedContext ? $0.date : nil }
        return VStack(alignment: .leading, spacing: compact ? 10 : 12) {
            HStack {
                Text("Daily edits").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let date = selectedChartDate {
                    let day = ActivityDay.start(of: date)
                    let total = presentation.records.filter { $0.day == day }.reduce(0) { $0 + $1.edits }
                    Text("\(GardenFormat.day(day)) · \(total) recorded \(total == 1 ? "edit" : "edits")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(presentation.series) { item in
                                HStack(spacing: 5) {
                                    Circle().fill(item.color).frame(width: 5, height: 5)
                                    Text(item.name).fixedSize()
                                }
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: compact ? 280 : 510)
                    .frame(height: 13)
                    .font(.system(size: compact ? 9 : 10)).foregroundStyle(.secondary)
                }
            }
            if presentation.editCount == 0 {
                Text("No confirmed file edits recorded in this period")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 86)
            } else {
                Chart {
                    ForEach(presentation.records.filter { $0.edits > 0 }) { record in
                        BarMark(x: .value("UTC day", record.day, unit: .day),
                                y: .value("Recorded edits", Double(record.edits) * progress), width: .ratio(0.65))
                            .foregroundStyle(by: .value("Profile", record.sourceID))
                            .cornerRadius(2)
                            .accessibilityLabel("\(presentation.sourceName(record.sourceID)), \(GardenFormat.day(record.day))")
                            .accessibilityValue("\(record.edits) recorded edits")
                    }
                    if let date = selectedChartDate {
                        RuleMark(x: .value("Selected day", date))
                            .foregroundStyle(.white.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartForegroundStyleScale(domain: presentation.series.map(\.id), range: presentation.series.map(\.color))
                .chartLegend(.hidden)
                .chartXScale(domain: renderedContext.start...renderedContext.end)
                .chartYScale(domain: 0...presentation.chartMaximum)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: presentation.axisStride)) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(GardenFormat.shortDay(date)).foregroundStyle(Color.white.opacity(0.45))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: presentation.chartAxisValues) { value in
                        AxisGridLine().foregroundStyle(.white.opacity(0.045))
                        AxisValueLabel {
                            if let count = value.as(Double.self) {
                                Text(count.formatted(.number.precision(.fractionLength(0))))
                                    .foregroundStyle(Color.white.opacity(0.35))
                            }
                        }
                    }
                }
                .chartXSelection(value: chartSelection(for: renderedContext))
                .environment(\.calendar, GardenFormat.utcCalendar)
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                .frame(height: compact ? 80 : 90)
                .id(renderedContext)
                .animation(contextAnimation, value: progress)
            }
        }
        .padding(compact ? 14 : 18)
        .background(GardenPalette.card, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.055), lineWidth: 1))
    }

    private var emptyGarden: some View {
        VStack(spacing: 13) {
            Image(systemName: store.isScanning ? "circle.dotted.circle" : "leaf")
                .font(.system(size: 38, weight: .ultraLight))
                .foregroundStyle(Color(red: 0.48, green: 0.66, blue: 0.78))
            Text(store.isScanning ? "Your history is taking shape" : "A little work becomes a trail")
                .font(.system(size: 19, weight: .medium))
            Text(store.isScanning
                 ? "The map will fill as local session history is indexed."
                 : "No daily activity is recorded for this selection yet. Try another project or a wider period.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 390)
            if store.isScanning { ProgressView().controlSize(.small).padding(.top, 4) }
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 260 : 330)
        .background(GardenPalette.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.055), lineWidth: 1))
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Label("Confirmed recorded file edits · Dates in UTC", systemImage: "info.circle")
                Spacer()
                Text(store.isScanning ? "History is still indexing…" : "Connections group activity, not commits")
            }
            VStack(alignment: .leading, spacing: 4) {
                Label("Confirmed recorded file edits · Dates in UTC", systemImage: "info.circle")
                Text(store.isScanning ? "History is still indexing…" : "Connections group activity, not commits")
            }
        }
        .font(.system(size: 9))
        .foregroundStyle(.tertiary)
        .help("Counts describe recorded tool operations and sessions, not lines of code or code quality. Shell and external changes are not attributed. Connections group records and do not represent Git or file ancestry.")
    }

    private var axisStride: Int {
        let days = Int(endDate.timeIntervalSince(startDate) / 86_400)
        if days <= 8 { return 1 }
        if days <= 35 { return 5 }
        if days <= 100 { return 14 }
        return max(30, days / 6)
    }
    private func sourceName(_ id: String) -> String { store.sources.first { $0.id == id }?.name ?? id }
    private func clearInspection() { inspection = nil; chartInspection = nil }
    private func chartSelection(for renderedContext: GardenContext) -> Binding<Date?> {
        Binding(get: {
            guard renderedContext == context else { return nil }
            return selectedChartDate
        }, set: { value in
            // Chart can send selection events while its previous domain is departing.
            guard renderedContext == context else { return }
            guard let value, value >= renderedContext.start, value < renderedContext.end else {
                chartInspection = nil
                return
            }
            chartInspection = GardenChartInspection(context: renderedContext, date: value)
        })
    }
}

/// Each selection owns its reveal state and cancellation task. Departing views
/// can finish fading without resetting the next selection's progress.
private struct GardenRevealSurface<Content: View>: View {
    let reduceMotion: Bool
    let content: (Double) -> Content
    @State private var progress = 0.0

    var body: some View {
        content(reduceMotion ? 1 : progress)
            .transaction { transaction in
                if reduceMotion {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
            .task(id: reduceMotion) {
                if reduceMotion { progress = 1; return }
                guard progress < 1 else { return }
                // Commit a zero-height first frame with the final, fixed axes.
                do { try await Task.sleep(for: .milliseconds(24)) }
                catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(.smooth(duration: GardenMotion.duration)) { progress = 1 }
            }
    }
}

private struct GardenMap: View, Animatable {
    let rootName: String
    let series: [GardenSeries]
    let start: Date
    let end: Date
    let compact: Bool
    var progress: Double
    let inspectedID: String?
    let inspect: (GardenRecord) -> Void

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let root = CGPoint(x: compact ? size.width * 0.105 : 76, y: size.height / 2 - 1)
            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    for (index, item) in series.enumerated() {
                        let baseline = branchY(index, height: canvasSize.height)
                        let maxEdits = max(1, item.records.map(\.edits).max() ?? 1)
                        let points = item.records.map { point($0, index: index, maxEdits: maxEdits, size: canvasSize) }
                        var path = Path()
                        path.move(to: CGPoint(x: root.x + 16, y: root.y))
                        let branch = CGPoint(x: compact ? canvasSize.width * 0.32 : 241, y: baseline)
                        path.addCurve(to: branch, control1: CGPoint(x: compact ? canvasSize.width * 0.22 : 160, y: root.y),
                                      control2: CGPoint(x: compact ? canvasSize.width * 0.23 : 165, y: baseline))
                        var previous = branch
                        for next in points {
                            let middleX = (previous.x + next.x) / 2
                            path.addCurve(to: next, control1: CGPoint(x: middleX, y: previous.y),
                                          control2: CGPoint(x: middleX, y: next.y))
                            previous = next
                        }
                        context.stroke(path.trimmedPath(from: 0, to: max(0, min(1, progress))),
                                       with: .color(item.color.opacity(0.26)),
                                       style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    }
                }
                .accessibilityHidden(true)

                VStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: compact ? 18 : 23, weight: .light))
                        .foregroundStyle(Color(red: 0.63, green: 0.77, blue: 0.90))
                        .frame(width: compact ? 35 : 43, height: compact ? 35 : 43)
                        .background(.white.opacity(0.035), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.10), lineWidth: 1))
                    Text(rootName)
                        .font(.system(size: compact ? 10 : 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(width: compact ? 83 : 130)
                }
                .position(x: root.x, y: root.y + 13)

                ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 5) {
                        Circle().fill(item.color).frame(width: 5, height: 5)
                        Text(item.name).lineLimit(1)
                    }
                    .font(.system(size: compact ? 9 : 10, weight: .medium))
                    .foregroundStyle(item.color.opacity(0.95))
                    .frame(width: compact ? 100 : 130, alignment: .leading)
                    .position(x: compact ? size.width * 0.32 : 231,
                              y: branchY(index, height: size.height) - (compact ? 27 : 16))
                    .opacity(0.35 + 0.65 * progress)
                    .help(item.name)
                    ForEach(item.records) { record in
                        let location = point(record, index: index,
                                             maxEdits: max(1, item.records.map(\.edits).max() ?? 1), size: size)
                        let radius = nodeRadius(record)
                        let nodeReveal = nodeProgress(record)
                        Button { inspect(record) } label: {
                            Circle()
                                .fill(record.edits > 0 ? item.color : GardenPalette.card)
                                .overlay(Circle().stroke(item.color.opacity(0.9), lineWidth: record.edits > 0 ? 0.5 : 1.1))
                                .frame(width: radius * 2, height: radius * 2)
                                .shadow(color: item.color.opacity(inspectedID == record.id ? 0.7 : 0.15), radius: inspectedID == record.id ? 8 : 4)
                                .overlay(Circle().stroke(.white.opacity(inspectedID == record.id ? 0.8 : 0), lineWidth: 1).padding(-3))
                                .scaleEffect(0.45 + 0.55 * nodeReveal)
                                .opacity(nodeReveal)
                                .frame(width: max(compact ? 12 : 20, radius * 2 + 5), height: max(compact ? 12 : 20, radius * 2 + 5))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .position(location)
                        .allowsHitTesting(nodeReveal > 0.65)
                        .accessibilityHidden(nodeReveal < 0.99)
                        .onHover { inside in if inside { inspect(record) } }
                        .help("\(GardenFormat.day(record.day)) UTC · \(item.name)\n\(record.edits) recorded edits · \(record.sessions) sessions")
                        .accessibilityLabel("\(item.name), \(GardenFormat.day(record.day)), \(record.edits) recorded edits and \(record.sessions) sessions")
                    }
                }
            }
            // The one animatable progress value drives drawing and node reveal;
            // unrelated geometry never receives an implicit morph animation.
            .transaction { $0.animation = nil }
        }
    }

    private func branchY(_ index: Int, height: CGFloat) -> CGFloat {
        let available = height - 54
        return 32 + available * CGFloat(index + 1) / CGFloat(series.count + 1)
    }
    private func point(_ record: GardenRecord, index: Int, maxEdits: Int, size: CGSize) -> CGPoint {
        let duration = max(86_400, end.timeIntervalSince(start))
        let fraction = record.day.addingTimeInterval(43_200).timeIntervalSince(start) / duration
        let plotStart = compact ? size.width * 0.45 : 316
        let plotWidth = max(1, size.width - plotStart - (compact ? 14 : 24))
        let x = plotStart + plotWidth * fraction
        let activityHeight = CGFloat(record.edits) / CGFloat(maxEdits) * 32
        return CGPoint(x: x, y: branchY(index, height: size.height) + 14 - activityHeight)
    }
    private func nodeRadius(_ record: GardenRecord) -> CGFloat {
        let radius = record.edits == 0 ? 3 : min(8, 2.9 + CGFloat(sqrt(Double(record.edits))) * 0.48)
        return radius * (compact ? 0.72 : 1)
    }
    private func nodeProgress(_ record: GardenRecord) -> Double {
        let fraction = max(0, min(1, record.day.addingTimeInterval(43_200).timeIntervalSince(start)
                                 / max(86_400, end.timeIntervalSince(start))))
        return max(0, min(1, (progress - (0.28 + fraction * 0.5)) / 0.2))
    }
}

private struct GardenMetric: View {
    let value: Int
    let title: String
    let note: String
    let color: Color
    let compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if compact {
                valueText
                titleText
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    valueText
                    titleText
                }
                Text(note).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, compact ? 14 : 20)
        .help(note)
    }
    private var valueText: some View {
        Text(value.formatted()).font(.system(size: compact ? 24 : 28, weight: .medium, design: .rounded))
            .foregroundStyle(color).contentTransition(.numericText())
    }
    private var titleText: some View {
        Text(title).font(.system(size: compact ? 8 : 9, weight: .semibold)).tracking(0.8)
            .foregroundStyle(.secondary).lineLimit(1)
    }
}

private struct GardenContext: Hashable {
    let projectID: String
    let period: GardenPeriod
    let start: Date
    let end: Date
}
private struct GardenPresentation {
    let context: GardenContext
    let rootName: String
    let records: [GardenRecord]
    let series: [GardenSeries]
    let axisStride: Int
    var editCount: Int { records.reduce(0) { $0 + $1.edits } }
    var chartMaximum: Double {
        let dailyTotals = Dictionary(grouping: records, by: \.day).values.map { $0.reduce(0) { $0 + $1.edits } }
        return Double(max(1, dailyTotals.max() ?? 1)) * 1.12
    }
    var chartAxisValues: [Double] {
        let roughStep = max(1, chartMaximum / 3)
        let power = pow(10, floor(log10(roughStep)))
        let normalized = roughStep / power
        let step = (normalized >= 5 ? 5.0 : normalized >= 2 ? 2.0 : 1.0) * power
        return Array(stride(from: 0.0, through: chartMaximum, by: step))
    }
    func sourceName(_ id: String) -> String { series.first { $0.id == id }?.name ?? id }
}
private enum GardenMotion {
    static let duration = 0.42
}
private struct GardenInspection {
    let context: GardenContext
    let recordID: String
}
private struct GardenChartInspection {
    let context: GardenContext
    let date: Date
}

private struct GardenRecord: Identifiable {
    let sourceID: String
    let day: Date
    let edits: Int
    let sessions: Int
    var id: String { "\(sourceID)|\(day.timeIntervalSince1970)" }
}
private struct GardenSeries: Identifiable {
    let id: String
    let name: String
    let color: Color
    let records: [GardenRecord]
}
private enum GardenPeriod: String, CaseIterable, Identifiable {
    case week = "7D", month = "30D", quarter = "90D", all = "All"
    var id: String { rawValue }
    var days: Int? {
        switch self { case .week: return 7; case .month: return 30; case .quarter: return 90; case .all: return nil }
    }
}
private enum GardenPalette {
    static let card = Color(red: 0.073, green: 0.091, blue: 0.120)
    static func color(_ id: String, sources: [AgentSource]) -> Color {
        if id == "claude-primary" { return Color(red: 0.36, green: 0.65, blue: 1.0) }
        if id == "claude-second" { return Color(red: 1.0, green: 0.67, blue: 0.36) }
        let palette: [Color] = [.purple, .mint, .pink, .cyan]
        return palette[(sources.firstIndex { $0.id == id } ?? 0) % palette.count]
    }
}
private enum GardenFormat {
    static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    static func day(_ date: Date) -> String { format(date, template: "MMM d, yyyy") }
    static func shortDay(_ date: Date) -> String { format(date, template: "MMM d") }
    private static func format(_ date: Date, template: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
}
