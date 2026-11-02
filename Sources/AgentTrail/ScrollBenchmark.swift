import AppKit
import Darwin
import SwiftUI
import os
import AgentTrailCore

/// `--benchmark-scroll projects|growth`: opens the panel in a popover, scrolls
/// it a fixed step per display frame and prints main-thread CPU per frame, frames
/// over budget and late frames, then the CPU an idle open panel spends on live
/// ticks. Sample data by default (`--copies N` repeats the five sample projects);
/// `--real` reads this Mac's history like the app does. `--quiet` stops the
/// refresh and live timers for steadier comparisons. `--offscreen` steps on a
/// 120 Hz timer and renders each step itself, for when no display link runs, as
/// on a locked screen; only CPU is meaningful there. Scrolling and idle time are
/// marked as points of interest for Instruments.
@MainActor
final class ScrollBenchmark: NSObject {
    private struct Options {
        var section: PanelSection = .projects
        var copies = 8
        var real = false
        var light = false
        var quiet = false
        var offscreen = false
        var passes = 3
        var step: CGFloat = 16
        var idleSeconds: Double = 9

        init(_ arguments: [String]) {
            func value(_ flag: String) -> String? {
                guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
                return arguments[index + 1]
            }
            if value("--benchmark-scroll") == "growth" { section = .growth }
            copies = value("--copies").flatMap(Int.init) ?? copies
            passes = value("--passes").flatMap(Int.init) ?? passes
            step = value("--step").flatMap(Double.init).map { CGFloat($0) } ?? step
            idleSeconds = value("--idle").flatMap(Double.init) ?? idleSeconds
            real = arguments.contains("--real")
            light = arguments.contains("--light")
            quiet = arguments.contains("--quiet")
            offscreen = arguments.contains("--offscreen")
        }
    }

    private struct Frame {
        let interval: Double
        let nominal: Double
        let cpu: Double
    }

    private static let log = OSLog(subsystem: "app.agenttrail.benchmark", category: .pointsOfInterest)
    private static var current: ScrollBenchmark?

    private let options: Options
    private let store: AppStore
    /// The panel is a popover in the app, so the benchmark uses one too, under a small anchor window.
    private let anchor: NSWindow
    private let popover = NSPopover()
    private var scrollView: NSScrollView?
    private var link: CADisplayLink?
    private var timer: Timer?
    private var frames: [Frame] = []
    private var firstPassFrames = 0
    private var lastTimestamp: CFTimeInterval?
    private var lastCPU: UInt64 = 0
    private var offset: CGFloat = 0
    private var direction: CGFloat = 1
    private var pass = 0
    private var startProcessCPU = 0.0
    private var startWall = 0.0

    static func start(arguments: [String]) {
        let benchmark = ScrollBenchmark(options: Options(arguments))
        current = benchmark
        benchmark.prepare()
    }

    private init(options: Options) {
        self.options = options
        store = AppStore(demoMode: !options.real, demoCopies: options.copies, refreshesPeriodically: !options.quiet)
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        anchor = NSWindow(contentRect: NSRect(x: screen.minX + 340, y: screen.maxY - 12, width: 24, height: 12),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        super.init()
    }

    private func prepare() {
        anchor.appearance = NSAppearance(named: options.light ? .aqua : .darkAqua)
        anchor.isReleasedWhenClosed = false
        anchor.orderFrontRegardless()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.appearance = anchor.appearance
        popover.contentSize = NSSize(width: AgentTrailShell.panelWidth, height: AgentTrailShell.panelHeight)
        popover.contentViewController = NSHostingController(rootView: AgentTrailShell(store: store))
        popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: .minY)
        waitUntilReady(deadline: Date().addingTimeInterval(240))
    }

    private var panel: NSView? { popover.contentViewController?.view }

    private var isReady: Bool {
        store.lastScan != nil && !store.isScanning && store.historyRevision > 0 && store.lastLiveScan != nil
    }

    private func waitUntilReady(deadline: Date) {
        guard isReady else {
            guard Date() < deadline else { return fail("History did not finish indexing in time") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.waitUntilReady(deadline: deadline) }
            return
        }
        store.panelSection = options.section
        // Lets the tab transition, sparkline draw-in and Growth reveals finish.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.begin() }
    }

    /// The hidden Projects list stays mounted under Growth, so the target is the
    /// scroll view that takes a hit at the middle of the panel.
    private func begin() {
        guard let panel, let target = visibleScrollView(in: panel), range(of: target) > 0 else {
            return fail("No scrollable view found")
        }
        scrollView = target
        let pointer = NSEvent.mouseLocation
        let over = target.window.map { NSMouseInRect(pointer, $0.frame, false) } ?? false
        print("benchmark: \(options.section.rawValue) · \(options.real ? "real data" : "sample ×\(options.copies)") · "
              + "\(store.projectOverviews.count) projects · content \(Int(documentHeight(target))) pt · "
              + "step \(Int(options.step)) pt · \(options.light ? "light" : "dark") · pointer \(over ? "over" : "outside")"
              + "\(options.quiet ? " · quiet" : "")\(options.offscreen ? " · offscreen" : "")")
        print("benchmark: AppKit views in the scroll content: " + viewCensus(target.documentView))
        os_signpost(.begin, log: Self.log, name: "Scroll")
        startProcessCPU = Self.processCPU()
        startWall = CACurrentMediaTime()
        lastCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        if options.offscreen {
            let timer = Timer(timeInterval: 1.0 / 120, target: self, selector: #selector(timerTick(_:)),
                              userInfo: nil, repeats: true)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            let link = panel.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        step(timestamp: link.timestamp, nominal: link.targetTimestamp - link.timestamp)
    }

    /// No display cycle runs without a display link, so each step lays out and renders now.
    @objc private func timerTick(_ timer: Timer) {
        step(timestamp: CACurrentMediaTime(), nominal: timer.timeInterval)
        panel?.layoutSubtreeIfNeeded()
        panel?.displayIfNeeded()
        CATransaction.flush()
    }

    /// Records the main thread's CPU since the last step, then scrolls on.
    private func step(timestamp: CFTimeInterval, nominal: CFTimeInterval) {
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        if let lastTimestamp {
            frames.append(Frame(interval: timestamp - lastTimestamp, nominal: nominal,
                                cpu: Double(cpu - lastCPU) / 1_000_000))
        }
        lastTimestamp = timestamp
        lastCPU = cpu
        guard let scrollView else { return }
        let limit = range(of: scrollView)
        offset += direction * options.step
        if offset >= limit || offset <= 0 {
            offset = min(max(offset, 0), limit)
            direction = -direction
            pass += 1
            if pass == 1 { firstPassFrames = frames.count }
        }
        scroll(scrollView, to: offset)
        if pass >= options.passes { finishScrolling() }
    }

    private func finishScrolling() {
        link?.invalidate()
        link = nil
        timer?.invalidate()
        timer = nil
        os_signpost(.end, log: Self.log, name: "Scroll")
        let wall = CACurrentMediaTime() - startWall
        let processCPU = Self.processCPU() - startProcessCPU
        report(frames, title: "all passes", wall: wall, processCPU: processCPU)
        report(Array(frames.prefix(firstPassFrames)), title: "first pass", wall: nil, processCPU: nil)
        measureIdle()
    }

    /// The panel left open with nothing scrolling: live ticks and clocks only.
    private func measureIdle() {
        guard options.idleSeconds > 0 else { return finish() }
        let mainStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let processStart = Self.processCPU()
        os_signpost(.begin, log: Self.log, name: "Idle")
        DispatchQueue.main.asyncAfter(deadline: .now() + options.idleSeconds) { [weak self] in
            guard let self else { return }
            os_signpost(.end, log: Self.log, name: "Idle")
            let main = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - mainStart) / 1_000_000
            let process = (Self.processCPU() - processStart) * 1000
            print(String(format: "idle %.0fs: main thread %.1f ms CPU (%.2f ms/s) · process %.1f ms CPU",
                         self.options.idleSeconds, main, main / self.options.idleSeconds, process))
            self.finish()
        }
    }

    private func finish() {
        fflush(stdout)
        exit(0)
    }

    private func fail(_ message: String) {
        fputs("benchmark: \(message)\n", stderr)
        exit(1)
    }

    // MARK: Reporting

    /// Over budget: main-thread CPU above one frame. Late: a display frame that
    /// came more than half a frame after its time. Hitch: lateness per second.
    private func report(_ frames: [Frame], title: String, wall: Double?, processCPU: Double?) {
        guard frames.count > 2 else { return print("\(title): too few frames") }
        let cpu = frames.map(\.cpu).sorted()
        let nominal = frames.map(\.nominal).sorted()[frames.count / 2]
        let overBudget = cpu.filter { $0 > nominal * 1000 }.count
        var line = String(format: "%@: %d frames @ %.0f Hz · main CPU/frame mean %.2f p50 %.2f p95 %.2f p99 %.2f max %.2f ms · "
                          + "over budget %d (%.1f%%)",
                          title, frames.count, 1 / nominal, cpu.reduce(0, +) / Double(cpu.count),
                          Self.percentile(cpu, 0.5), Self.percentile(cpu, 0.95), Self.percentile(cpu, 0.99), cpu.last ?? 0,
                          overBudget, Self.share(overBudget, of: frames.count))
        if !options.offscreen {
            let late = frames.filter { $0.interval > nominal * 1.5 }.count
            let hitch = frames.reduce(0) { $0 + max(0, $1.interval - $1.nominal) }
            let total = frames.reduce(0) { $0 + $1.interval }
            line += String(format: " · late frames %d (%.1f%%) · hitch %.1f ms/s",
                           late, Self.share(late, of: frames.count), hitch / total * 1000)
        }
        if let wall, let processCPU {
            line += String(format: " · process CPU %.0f%% of one core", processCPU / wall * 100)
        }
        print(line)
    }

    private static func share(_ count: Int, of total: Int) -> Double {
        Double(count) / Double(max(total, 1)) * 100
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * fraction).rounded()))]
    }

    private static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    // MARK: Scroll view

    private func visibleScrollView(in panel: NSView) -> NSScrollView? {
        let middle = NSPoint(x: panel.bounds.midX, y: panel.bounds.midY)
        var view = panel.hitTest(panel.convert(middle, to: panel.superview))
        while let current = view {
            if let scrollView = current as? NSScrollView { return scrollView }
            view = current.superview
        }
        return nil
    }

    private func documentHeight(_ view: NSScrollView) -> CGFloat {
        view.documentView?.frame.height ?? 0
    }

    private func range(of view: NSScrollView) -> CGFloat {
        max(0, documentHeight(view) - view.contentView.bounds.height)
    }

    /// `offset` is measured from the top whether or not the document is flipped.
    private func scroll(_ view: NSScrollView, to offset: CGFloat) {
        let clip = view.contentView
        let y = view.documentView?.isFlipped ?? true ? offset : range(of: view) - offset
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        view.reflectScrolledClipView(clip)
    }

    /// SwiftUI gives each drawn item its own AppKit view, and every one that
    /// scrolls into sight is made and placed, so the count is worth watching.
    private func viewCensus(_ root: NSView?) -> String {
        var counts: [String: Int] = [:]
        func visit(_ view: NSView) {
            view.subviews.forEach { (child: NSView) in
                counts[String(describing: type(of: child)), default: 0] += 1
                visit(child)
            }
        }
        root.map(visit)
        let total = counts.values.reduce(0, +)
        let top = counts.sorted { $0.value > $1.value }.prefix(4).map { "\($0.key) \($0.value)" }
        return "\(total) (" + top.joined(separator: ", ") + ")"
    }
}
