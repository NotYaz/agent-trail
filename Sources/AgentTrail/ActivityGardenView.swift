import SwiftUI
import Charts
import AgentTrailCore

struct ActivityGardenView: View {
    @ObservedObject var store: AppStore
    @State private var selectedProject = ""
    @State private var period: GardenPeriod = .month
    @State private var inspectedDay: GardenRecord?
    @State private var selectedChartDate: Date?

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
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                header
                metrics
                if records.isEmpty {
                    emptyGarden
                } else {
                    growthMap
                    dailyChart
                }
                footer
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            LinearGradient(colors: [Color(red: 0.065, green: 0.081, blue: 0.107),
                                    Color(red: 0.042, green: 0.052, blue: 0.073)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .preferredColorScheme(.dark)
        .frame(minWidth: 820, minHeight: 650)
        .onChange(of: selectedProject) { _, _ in clearInspection() }
        .onChange(of: period) { _, _ in clearInspection() }
        .onChange(of: store.projects.map(\.id)) { _, ids in
            if !selectedProject.isEmpty && !ids.contains(selectedProject) { selectedProject = "" }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 9) {
                    Text("Project growth")
                        .font(.system(size: 26, weight: .semibold))
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
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Picker("Project", selection: $selectedProject) {
                Text("All projects").tag("")
                ForEach(store.projects) { project in
                    Text(project.name).tag(project.id).help(project.path)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 160)
            .controlSize(.regular)
            Picker("Period", selection: $period) {
                ForEach(GardenPeriod.allCases) { option in Text(option.rawValue).tag(option) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 180)
            .help("Filter the recorded UTC days shown in the map, chart, and export")
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
    }

    private var metrics: some View {
        HStack(spacing: 0) {
            GardenMetric(value: editCount, title: "RECORDED EDITS", note: "Successful file operations", color: .white)
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1, height: 35)
            GardenMetric(value: sessionCount, title: "SESSIONS", note: "Counted on their first UTC day", color: .white)
            Rectangle().fill(.white.opacity(0.07)).frame(width: 1, height: 35)
            GardenMetric(value: series.count, title: "ACTIVE PROFILES", note: "With recorded activity in this period", color: .white)
        }
        .padding(.vertical, 16)
        .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.055), lineWidth: 1))
    }

    private var growthMap: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                        Text("\(GardenFormat.day(inspectedDay.day)) · \(sourceName(inspectedDay.sourceID))")
                            .font(.system(size: 10, weight: .medium))
                        Text("\(inspectedDay.edits) \(inspectedDay.edits == 1 ? "edit" : "edits") · \(inspectedDay.sessions) \(inspectedDay.sessions == 1 ? "session" : "sessions")")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                } else {
                    Text("Explore a node to see the day")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 17)

            GardenMap(rootName: rootName, series: series, start: startDate, end: endDate,
                      inspectedID: inspectedDay?.id, inspect: { inspectedDay = $0 })
                .frame(height: max(174, CGFloat(series.count) * 65))
                .padding(.horizontal, 14)

            HStack(spacing: 14) {
                HStack(spacing: 5) {
                    Circle().fill(.white.opacity(0.65)).frame(width: 5, height: 5)
                    Text("Larger nodes · more edits")
                }
                HStack(spacing: 5) {
                    Circle().stroke(.white.opacity(0.5), lineWidth: 1).frame(width: 5, height: 5)
                    Text("Hollow nodes · sessions only")
                }
                Spacer()
                Text("UTC days →")
            }
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 20)
            .padding(.bottom, 15)
        }
        .background(GardenPalette.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.055), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Growth map. Recorded activity grouped by project, profile, and UTC day. Connections do not represent Git ancestry.")
    }

    private var dailyChart: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Daily edits").font(.system(size: 13, weight: .semibold))
                Spacer()
                if let date = selectedChartDate {
                    let day = ActivityDay.start(of: date)
                    let total = records.filter { $0.day == day }.reduce(0) { $0 + $1.edits }
                    Text("\(GardenFormat.day(day)) · \(total) recorded \(total == 1 ? "edit" : "edits")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 12) {
                        ForEach(series) { item in
                            HStack(spacing: 5) {
                                Circle().fill(item.color).frame(width: 5, height: 5)
                                Text(item.name)
                            }
                        }
                    }
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            if editCount == 0 {
                Text("No successful Edit/Write operations recorded in this period")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 86)
            } else {
                Chart {
                    ForEach(records.filter { $0.edits > 0 }) { record in
                        BarMark(x: .value("UTC day", record.day, unit: .day),
                                y: .value("Recorded edits", record.edits), width: .ratio(0.65))
                            .foregroundStyle(by: .value("Profile", record.sourceID))
                            .cornerRadius(2)
                            .accessibilityLabel("\(sourceName(record.sourceID)), \(GardenFormat.day(record.day))")
                            .accessibilityValue("\(record.edits) recorded edits")
                    }
                    if let date = selectedChartDate {
                        RuleMark(x: .value("Selected day", date))
                            .foregroundStyle(.white.opacity(0.35))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartForegroundStyleScale(domain: series.map(\.id), range: series.map(\.color))
                .chartLegend(.hidden)
                .chartXScale(domain: startDate...endDate)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: axisStride)) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(GardenFormat.shortDay(date)).foregroundStyle(Color.white.opacity(0.45))
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(.white.opacity(0.045))
                        AxisValueLabel {
                            if let count = value.as(Int.self) {
                                Text(count.formatted()).foregroundStyle(Color.white.opacity(0.35))
                            }
                        }
                    }
                }
                .chartXSelection(value: $selectedChartDate)
                .environment(\.calendar, GardenFormat.utcCalendar)
                .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                .frame(height: 90)
            }
        }
        .padding(18)
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
        .frame(maxWidth: .infinity, minHeight: 330)
        .background(GardenPalette.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.055), lineWidth: 1))
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
            Text("Successful recorded Edit/Write operations · Dates in UTC")
            Spacer()
            if store.isScanning {
                Text("History is still indexing…")
            } else {
                Text("Connections group activity, not commits")
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
    private func clearInspection() { inspectedDay = nil; selectedChartDate = nil }
}

private struct GardenMap: View {
    let rootName: String
    let series: [GardenSeries]
    let start: Date
    let end: Date
    let inspectedID: String?
    let inspect: (GardenRecord) -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let root = CGPoint(x: 76, y: size.height / 2 - 1)
            ZStack(alignment: .topLeading) {
                Canvas { context, canvasSize in
                    for (index, item) in series.enumerated() {
                        let baseline = branchY(index, height: canvasSize.height)
                        let points = item.records.map { point($0, index: index, size: canvasSize) }
                        var path = Path()
                        path.move(to: CGPoint(x: root.x + 16, y: root.y))
                        let branch = CGPoint(x: 241, y: baseline)
                        path.addCurve(to: branch, control1: CGPoint(x: 160, y: root.y),
                                      control2: CGPoint(x: 165, y: baseline))
                        var previous = branch
                        for next in points {
                            let middleX = (previous.x + next.x) / 2
                            path.addCurve(to: next, control1: CGPoint(x: middleX, y: previous.y),
                                          control2: CGPoint(x: middleX, y: next.y))
                            previous = next
                        }
                        context.stroke(path, with: .color(item.color.opacity(0.26)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    }
                }
                .accessibilityHidden(true)

                VStack(spacing: 10) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 23, weight: .light))
                        .foregroundStyle(Color(red: 0.63, green: 0.77, blue: 0.90))
                        .frame(width: 43, height: 43)
                        .background(.white.opacity(0.035), in: Circle())
                        .overlay(Circle().stroke(.white.opacity(0.10), lineWidth: 1))
                    Text(rootName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(width: 130)
                }
                .position(x: root.x, y: root.y + 13)

                ForEach(Array(series.enumerated()), id: \.element.id) { index, item in
                    HStack(spacing: 5) {
                        Circle().fill(item.color).frame(width: 5, height: 5)
                        Text(item.name).lineLimit(1)
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(item.color.opacity(0.95))
                    .frame(width: 130, alignment: .leading)
                    .position(x: 231, y: branchY(index, height: size.height) - 16)
                    ForEach(item.records) { record in
                        let location = point(record, index: index, size: size)
                        let radius = nodeRadius(record)
                        Button { inspect(record) } label: {
                            Circle()
                                .fill(record.edits > 0 ? item.color : GardenPalette.card)
                                .overlay(Circle().stroke(item.color.opacity(0.9), lineWidth: record.edits > 0 ? 0.5 : 1.1))
                                .frame(width: radius * 2, height: radius * 2)
                                .shadow(color: item.color.opacity(inspectedID == record.id ? 0.7 : 0.15), radius: inspectedID == record.id ? 8 : 4)
                                .overlay(Circle().stroke(.white.opacity(inspectedID == record.id ? 0.8 : 0), lineWidth: 1).padding(-3))
                                .frame(width: max(20, radius * 2 + 8), height: max(20, radius * 2 + 8))
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .position(location)
                        .onHover { inside in if inside { inspect(record) } }
                        .help("\(GardenFormat.day(record.day)) UTC · \(item.name)\n\(record.edits) recorded edits · \(record.sessions) sessions")
                        .accessibilityLabel("\(item.name), \(GardenFormat.day(record.day)), \(record.edits) recorded edits and \(record.sessions) sessions")
                    }
                }
            }
        }
    }

    private func branchY(_ index: Int, height: CGFloat) -> CGFloat {
        let available = height - 54
        return 32 + available * CGFloat(index + 1) / CGFloat(series.count + 1)
    }
    private func point(_ record: GardenRecord, index: Int, size: CGSize) -> CGPoint {
        let duration = max(86_400, end.timeIntervalSince(start))
        let fraction = record.day.addingTimeInterval(43_200).timeIntervalSince(start) / duration
        let x = 316 + (size.width - 340) * fraction
        let maxEdits = max(1, series[index].records.map(\.edits).max() ?? 1)
        let activityHeight = CGFloat(record.edits) / CGFloat(maxEdits) * 32
        return CGPoint(x: x, y: branchY(index, height: size.height) + 14 - activityHeight)
    }
    private func nodeRadius(_ record: GardenRecord) -> CGFloat {
        record.edits == 0 ? 3 : min(8, 2.9 + CGFloat(sqrt(Double(record.edits))) * 0.48)
    }
}

private struct GardenMetric: View {
    let value: Int
    let title: String
    let note: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Text(value.formatted()).font(.system(size: 28, weight: .medium, design: .rounded))
                    .foregroundStyle(color)
                    .contentTransition(.numericText())
                Text(title).font(.system(size: 9, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(.secondary)
            }
            Text(note).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
    }
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
