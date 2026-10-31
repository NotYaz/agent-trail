import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AgentTrailCore

/// A local, path-free portrait of the history supplied by the activity garden.
struct ActivityShareCard: View {
    let projects: [ProjectSummary]
    let sources: [AgentSource]
    var anonymize: Bool = true
    var sampleData: Bool = false

    private var history: [ActivityDay] { ActivityDay.merge(projects.flatMap(\.history)) }
    private var editCount: Int { history.reduce(0) { $0 + $1.editCount } }
    private var sessionCount: Int { history.reduce(0) { $0 + $1.sessionCount } }
    private var portraits: [SharePortraitSource] {
        let activities = projects.flatMap(\.activities)
        let knownOrder = sources.map(\.id)
        let ids = Set(activities.map(\.sourceID)).sorted { first, second in
            let firstIndex = knownOrder.firstIndex(of: first) ?? Int.max
            let secondIndex = knownOrder.firstIndex(of: second) ?? Int.max
            return firstIndex == secondIndex ? first < second : firstIndex < secondIndex
        }
        return ids.enumerated().compactMap { index, id in
            let days = ActivityDay.merge(activities.filter { $0.sourceID == id }.flatMap(\.history))
                .filter { $0.editCount > 0 || $0.sessionCount > 0 }
            guard !days.isEmpty else { return nil }
            let name = anonymize ? "Agent \(index + 1)"
                : (sources.first { $0.id == id }?.name ?? "Unknown profile")
            return SharePortraitSource(id: id, name: name, days: days,
                                       color: ProfileColor.color(id, sources: sources))
        }
    }

    private var projectTitle: String {
        guard !projects.isEmpty else { return "No projects selected" }
        guard projects.count == 1 else { return "\(projects.count) projects" }
        return anonymize ? "My project" : (projects[0].name.isEmpty ? "Project" : projects[0].name)
    }

    var body: some View {
        ZStack {
            Color(red: 0.025, green: 0.038, blue: 0.065)
            RoundedRectangle(cornerRadius: 29)
                .fill(LinearGradient(colors: [Color(red: 0.055, green: 0.079, blue: 0.12),
                                              Color(red: 0.028, green: 0.043, blue: 0.071)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .padding(12)
            Ellipse()
                .fill(Color.blue.opacity(0.10))
                .frame(width: 470, height: 280)
                .blur(radius: 100)
                .offset(x: 240, y: -80)
            Ellipse()
                .fill(Color.orange.opacity(0.055))
                .frame(width: 330, height: 220)
                .blur(radius: 80)
                .offset(x: -230, y: 200)

            VStack(alignment: .leading, spacing: 0) {
                brand
                HStack(alignment: .top, spacing: 0) {
                    introduction
                        .frame(width: 350, alignment: .leading)
                    ActivityPortraitTree(sources: portraits, history: history)
                        .frame(width: 540, height: 340)
                        .padding(.top, 8)
                }
                .padding(.top, 35)
                Spacer(minLength: 0)
                metrics
                footnote
            }
            .padding(.horizontal, 55)
            .padding(.top, 43)
            .padding(.bottom, 37)
            RoundedRectangle(cornerRadius: 29)
                .stroke(.white.opacity(0.075), lineWidth: 1)
                .padding(12)
        }
        .frame(width: 1000, height: 700)
        .environment(\.colorScheme, .dark)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(Color(red: 0.54, green: 0.73, blue: 1))
            Text("Agent Trail")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.93))
            Spacer()
            Text(sampleData ? "SAMPLE DATA · ACTIVITY PORTRAIT" : "ACTIVITY PORTRAIT")
                .font(.system(size: 10, weight: .semibold))
                .tracking(2.1)
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 21) {
            Text("A project.\nMany minds.")
                .font(.system(size: 53, weight: .semibold, design: .rounded))
                .tracking(-2.4)
                .lineSpacing(-2)
                .foregroundStyle(.white.opacity(0.96))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color(red: 0.45, green: 0.68, blue: 1))
                        .frame(width: 6, height: 6)
                    Text(projectTitle)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white.opacity(0.83))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(dateRange)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.41))
            }
            Text("A little picture of\nthe work that adds up.")
                .font(.system(size: 15))
                .lineSpacing(5)
                .foregroundStyle(.white.opacity(0.44))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
        }
    }

    private var metrics: some View {
        HStack(alignment: .top, spacing: 0) {
            metric(editCount, label: "RECORDED EDITS", tint: Color(red: 0.53, green: 0.73, blue: 1))
            metric(sessionCount, label: "SAVED SESSIONS", tint: Color(red: 1, green: 0.67, blue: 0.40))
            metric(portraits.count, label: "ACTIVE AGENTS", tint: Color(red: 0.62, green: 0.84, blue: 0.76))
        }
        .padding(.top, 24)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LinearGradient(colors: [.white.opacity(0.13), .white.opacity(0.035)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
        }
    }

    private func metric(_ value: Int, label: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(value.formatted(.number.grouping(.automatic)))
                .font(.system(size: 41, weight: .medium, design: .rounded))
                .tracking(-1.5)
                .monospacedDigit()
                .foregroundStyle(tint)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(.white.opacity(0.43))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var footnote: some View {
        HStack(alignment: .bottom) {
            Text("From local session records · Edits exclude shell and external changes")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.30))
            Spacer(minLength: 10)
            Label(anonymize ? "Names hidden" : "Names included", systemImage: anonymize ? "eye.slash" : "eye")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.30))
        }
        .padding(.top, 30)
    }

    private var dateRange: String {
        guard let first = history.first?.day, let last = history.last?.day else { return "No recorded history yet" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d, yyyy"
        if first == last { return "\(formatter.string(from: first)) · UTC" }
        return "\(formatter.string(from: first)) – \(formatter.string(from: last)) · UTC"
    }
}

private struct SharePortraitSource: Identifiable {
    let id: String
    let name: String
    let days: [ActivityDay]
    let color: Color

}

private struct ActivityPortraitTree: View {
    let sources: [SharePortraitSource]
    let history: [ActivityDay]

    /// The last 14 active days keep the portrait legible; totals cover the supplied history.
    private var visibleDays: [Date] {
        Array(history.filter { $0.editCount > 0 || $0.sessionCount > 0 }.map(\.day).suffix(14))
    }
    private var shownSources: [SharePortraitSource] { Array(sources.prefix(4)) }

    var body: some View {
        VStack(spacing: 0) {
            if shownSources.isEmpty {
                emptyTree
            } else {
                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        drawTree(context: context, size: size)
                    }
                    ForEach(Array(shownSources.enumerated()), id: \.element.id) { index, source in
                        HStack(spacing: 6) {
                            Circle().fill(source.color).frame(width: 5, height: 5)
                            Text(source.name)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.67))
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                        .frame(width: 110, alignment: .leading)
                        .offset(x: 427, y: laneY(index) - 6)
                    }
                }
                .frame(height: 287)
                HStack(spacing: 8) {
                    Circle().fill(.white.opacity(0.30)).frame(width: 4, height: 4)
                    Circle().fill(.white.opacity(0.45)).frame(width: 7, height: 7)
                    Text("Node size = recorded edits")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.35))
                    Spacer()
                    Text(visibleDays.count == history.filter { $0.editCount > 0 || $0.sessionCount > 0 }.count
                         ? "\(visibleDays.count) ACTIVE \(visibleDays.count == 1 ? "DAY" : "DAYS")"
                         : "LAST \(visibleDays.count) ACTIVE DAYS")
                        .font(.system(size: 8, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.30))
                }
                .padding(.leading, 33)
                .padding(.trailing, 3)
                .padding(.top, 12)
                if sources.count > shownSources.count {
                    Text("Showing \(shownSources.count) of \(sources.count) agent branches · totals include all agents")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.30))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.top, 8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTree: some View {
        VStack(spacing: 17) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.12))
            Text("Every trail starts somewhere.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func laneY(_ index: Int) -> CGFloat {
        let count = shownSources.count
        return count == 1 ? 135 : 45 + CGFloat(index) * (190 / CGFloat(max(1, count - 1)))
    }

    private func drawTree(context: GraphicsContext, size: CGSize) {
        let root = CGPoint(x: 25, y: 149)
        let terminalX: CGFloat = 412
        // Quiet guides reveal chronology without turning the card into a dashboard.
        for index in 0..<5 {
            let x = 90 + CGFloat(index) * 79
            var guide = Path()
            guide.move(to: CGPoint(x: x, y: 19))
            guide.addLine(to: CGPoint(x: x, y: 263))
            context.stroke(guide, with: .color(.white.opacity(0.035)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 7]))
        }

        for (index, source) in shownSources.enumerated() {
            let y = laneY(index)
            var trunk = Path()
            trunk.move(to: root)
            trunk.addCurve(to: CGPoint(x: terminalX, y: y),
                           control1: CGPoint(x: 155, y: 149),
                           control2: CGPoint(x: 155, y: y))
            context.stroke(trunk, with: .color(source.color.opacity(0.045)),
                           style: StrokeStyle(lineWidth: 17, lineCap: .round))
            context.stroke(trunk, with: .linearGradient(Gradient(colors: [source.color.opacity(0.08), source.color.opacity(0.65)]),
                                                       startPoint: root, endPoint: CGPoint(x: terminalX, y: y)),
                           style: StrokeStyle(lineWidth: 1.5, lineCap: .round))

            let records = Dictionary(grouping: source.days, by: \.day)
            for (dayIndex, day) in visibleDays.enumerated() {
                guard let record = records[day]?.first else { continue }
                let progress = visibleDays.count <= 1 ? 0.65 : CGFloat(dayIndex) / CGFloat(visibleDays.count - 1)
                let x = 110 + progress * 288
                let bend = sin(progress * .pi) * (index.isMultiple(of: 2) ? -14.0 : 14.0)
                let node = CGPoint(x: x, y: y + bend)
                let radius = min(12, 3.5 + sqrt(CGFloat(max(0, record.editCount))) * 0.82)

                var twig = Path()
                let branchOrigin = CGPoint(x: max(72, x - 47), y: interpolatedY(x: max(72, x - 47), target: y))
                twig.move(to: branchOrigin)
                twig.addQuadCurve(to: node, control: CGPoint(x: x - 11, y: branchOrigin.y))
                context.stroke(twig, with: .color(source.color.opacity(0.37)),
                               style: StrokeStyle(lineWidth: 1, lineCap: .round))

                let halo = CGRect(x: node.x - radius * 2.0, y: node.y - radius * 2.0,
                                  width: radius * 4.0, height: radius * 4.0)
                context.fill(Path(ellipseIn: halo), with: .color(source.color.opacity(0.055)))
                let circle = CGRect(x: node.x - radius, y: node.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: circle), with: .color(source.color.opacity(0.84)))
                context.stroke(Path(ellipseIn: circle), with: .color(.white.opacity(0.20)), lineWidth: 0.7)
                if record.sessionCount > 0 {
                    let center = CGRect(x: node.x - 1.4, y: node.y - 1.4, width: 2.8, height: 2.8)
                    context.fill(Path(ellipseIn: center), with: .color(.white.opacity(0.65)))
                }
            }
        }

        context.fill(Path(ellipseIn: CGRect(x: root.x - 14, y: root.y - 14, width: 28, height: 28)),
                     with: .color(.white.opacity(0.04)))
        context.fill(Path(ellipseIn: CGRect(x: root.x - 5, y: root.y - 5, width: 10, height: 10)),
                     with: .color(Color(red: 0.73, green: 0.82, blue: 0.96)))
    }

    private func interpolatedY(x: CGFloat, target: CGFloat) -> CGFloat {
        // Find the actual cubic trunk point at x so every twig stays attached.
        var lower: CGFloat = 0
        var upper: CGFloat = 1
        for _ in 0..<24 {
            let t = (lower + upper) / 2
            let u = 1 - t
            let curveX = u * u * u * 25 + 3 * u * u * t * 155 + 3 * u * t * t * 155 + t * t * t * 412
            if curveX < x { lower = t } else { upper = t }
        }
        let progress = (lower + upper) / 2
        let smooth = progress * progress * (3 - 2 * progress)
        return 149 + (target - 149) * smooth
    }
}

@MainActor
enum ActivityShareExporter {
    /// Exports only to a location selected by the user. No upload or assistant access.
    static func export(projects: [ProjectSummary], sources: [AgentSource], anonymize: Bool = true, sampleData: Bool = false) {
        let panel = NSSavePanel()
        panel.title = "Export activity portrait"
        panel.nameFieldStringValue = "Agent-Trail-activity.png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.message = anonymize
            ? "Project and profile names are hidden. Your portrait contains activity totals and dates."
            : "Project and profile names are included. Folder paths are never included."
        panel.prompt = "Export PNG"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let renderer = ImageRenderer(content: ActivityShareCard(projects: projects, sources: sources,
                                                                    anonymize: anonymize, sampleData: sampleData))
            renderer.scale = 2
            renderer.isOpaque = true
            guard let image = renderer.cgImage,
                  let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                showError("The activity portrait could not be rendered.")
                return
            }
            do {
                try png.write(to: url, options: .atomic)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Could not export activity portrait"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
