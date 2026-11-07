import AppKit
import SwiftUI
import AgentTrailCore

/// `--benchmark-map-hover SNAPSHOT.json [--mode lanes|tree|orbit|log] [--range …] [--all-branches] [--sweeps N] [--gapless] [--pace MS] [--idle S] [--window WxH] [--resize-sweep]`:
/// shows the panel's Map in a window, sweeps the pointer across the Map card
/// with synthetic mouse moves, renders after each move, and prints the main
/// thread's CPU and wall time per move. It also counts the moves that changed
/// the inspector's text, which confirms the moves reach the hover handlers.
/// `--gapless` goes from item to item with no empty space between, as a pointer
/// sliding along the map does; by default every item is followed by none.
/// `--pace MS` waits that long after each move, untimed, as a real pointer
/// leaves the renderer time between events; by default moves follow at once.
/// It prints the process's memory footprint before and after the sweeps, and
/// `--idle S` then leaves the Map alone for S seconds and prints the CPU it used.
@MainActor
enum MapHoverBenchmark {
    private static var window: NSWindow?

    static func run(arguments: [String]) {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let path = value("--benchmark-map-hover") else {
            fputs("--benchmark-map-hover requires a snapshot path\n", stderr)
            exit(2)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = FileManager.default.contents(atPath: path),
              let snapshot = try? decoder.decode(MapSnapshot.self, from: data) else {
            fputs("Could not read \(path)\n", stderr)
            exit(1)
        }
        let mode = value("--mode").flatMap(MapMode.init(rawValue:)) ?? .lanes
        let range = value("--range").flatMap { name in MapRange.allCases.first { $0.rawValue.lowercased() == name.lowercased() } }
            ?? .week
        let sweeps = value("--sweeps").flatMap(Int.init) ?? 2
        let pace = value("--pace").flatMap(Double.init) ?? 0

        let store = AppStore(demoMode: true, now: snapshot.takenAt, refreshesPeriodically: false)
        store.sources = snapshot.sources
        store.mapProjectPath = snapshot.projectPath
        store.mapRange = range
        store.mapMode = mode
        let foldsBranches = mode == .lanes && !arguments.contains("--all-branches")
        store.projectMap = ProjectMap.build(snapshot, range: range, calendar: .current,
                                            collapseAbove: foldsBranches ? AppStore.mapFoldThreshold : nil)
        store.panelSection = .map

        // `--window WxH` measures the Map window itself, which has its own hover model.
        var windowSize: NSSize?
        if arguments.contains("--window") {
            guard let size = value("--window").flatMap(MapWindowController.size(parsing:)) else {
                fputs("--window takes WxH in points, from 640x640 to 4000x4000\n", stderr)
                exit(2)
            }
            windowSize = size
        }
        if arguments.contains("--resize-sweep") && windowSize == nil {
            fputs("--resize-sweep needs --window WxH\n", stderr)
            exit(2)
        }
        let hover = windowSize == nil ? store.mapHover : MapHoverModel()
        let window: NSWindow
        let host: NSView
        if let windowSize {
            window = MapWindowController.makeWindow(MapWindowRoot(store: store, hover: hover), size: windowSize)
            window.setFrameOrigin(NSPoint(x: 80, y: 80))
            host = window.contentView ?? NSView()
        } else {
            let size = NSSize(width: AgentTrailShell.panelWidth, height: AgentTrailShell.panelHeight)
            host = NSHostingView(rootView: AgentTrailShell(store: store, animatesCharts: false))
            host.frame = NSRect(origin: .zero, size: size)
            let frame = NSRect(x: 80, y: 80, width: size.width, height: size.height)
            window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = host
            window.isReleasedWhenClosed = false
        }
        window.appearance = NSAppearance(named: .darkAqua)
        window.acceptsMouseMovedEvents = true
        window.orderFrontRegardless()
        self.window = window
        settle(host, seconds: 1.0)
        let footprintBefore = footprint()

        // Hover every item a sweep would reach: branches, runs and commits, in time order.
        guard let map = store.projectMap else { exit(1) }
        var ids: [MapHitID] = []
        for lane in map.lanes { ids.append(.lane(lane.id)) }
        for span in map.spans.sorted(by: { $0.start < $1.start }) { ids.append(.run(span.sessionKey, span.index)) }
        for marker in map.markers.prefix(120) { ids.append(.commit(marker.sha)) }
        var sequence: [MapHitID?] = []
        let gapless = arguments.contains("--gapless")
        for _ in 0..<sweeps {
            for id in ids {
                sequence.append(id)
                if !gapless { sequence.append(nil) }
            }
        }

        var cpu: [Double] = []
        var wall: [Double] = []
        var update: [Double] = []
        var draw: [Double] = []
        let changes = sequence.count
        // A pool per move, as the event loop drains one per event; without it a long run
        // keeps every move's autoreleased objects and reads as a leak.
        for id in sequence { autoreleasepool {
            let startCPU = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            let startWall = DispatchTime.now().uptimeNanoseconds
            hover.hovered = id
            RunLoop.main.run(until: Date())
            host.layoutSubtreeIfNeeded()
            let afterUpdate = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            host.displayIfNeeded()
            let end = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            update.append(Double(afterUpdate - startCPU) / 1e6)
            draw.append(Double(end - afterUpdate) / 1e6)
            cpu.append(Double(end - startCPU) / 1e6)
            wall.append(Double(DispatchTime.now().uptimeNanoseconds - startWall) / 1e6)
            if pace > 0 { RunLoop.main.run(until: Date(timeIntervalSinceNow: pace / 1000)) }
        } }
        let points = sequence
        func stats(_ values: [Double]) -> String {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return "n/a" }
            let mean = sorted.reduce(0, +) / Double(sorted.count)
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            return String(format: "mean %.2f ms · p95 %.2f ms · max %.2f ms", mean, p95, sorted.last ?? 0)
        }
        let hosted = windowSize.map { "Map window \(Int($0.width))x\(Int($0.height))" } ?? "panel"
        print("mode \(mode.rawValue) in the \(hosted) · \(points.count) hover changes · \(ids.count) items × \(sweeps) sweeps (\(changes) updates)")
        print("  main-thread CPU per move: \(stats(cpu))")
        print("    view update and layout:  \(stats(update))")
        print("    drawing:                 \(stats(draw))")
        print("  wall time per move:       \(stats(wall))")
        let over = wall.filter { $0 > 8.3 }.count
        print(String(format: "  moves over a 120 Hz frame (8.3 ms): %d (%.0f%%)", over, 100 * Double(over) / Double(max(1, wall.count))))
        // The slowest moves, with their main-thread CPU: a gap to the wall time is waiting, not work.
        for index in wall.indices.sorted(by: { wall[$0] > wall[$1] }).prefix(3) {
            let from = index > 0 ? sequence[index - 1].map { "\($0)" } ?? "nothing" : "rest"
            let to = sequence[index].map { "\($0)" } ?? "nothing"
            print(String(format: "  slow move #%d, %.2f ms (CPU %.2f, update %.2f): ", index, wall[index], cpu[index],
                         update[index]) + "\(from) → \(to)")
        }
        hover.hovered = nil
        settle(host, seconds: 1.0)
        print(String(format: "  memory footprint: %.1f MB before the sweeps, %.1f MB after", footprintBefore, footprint()))
        if let idle = value("--idle").flatMap(Double.init), idle > 0 {
            let start = processCPU()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: idle))
            let used = processCPU() - start
            print(String(format: "  idle for %.0f s: %.3f s of CPU (%.2f%%), footprint %.1f MB", idle, used,
                         100 * used / idle, footprint()))
        }
        if arguments.contains("--resize-sweep") { resizeSweep(window, host: host, stats: stats) }
        exit(0)
    }

    /// The memory Activity Monitor shows for this process, in MB.
    private static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    /// CPU time of every thread in this process, in seconds.
    private static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// Resizes the window as a live drag would: wider in 16pt steps to 2560,
    /// then taller in 16pt steps to 1400, rendering after each step.
    private static func resizeSweep(_ window: NSWindow, host: NSView, stats: ([Double]) -> String) {
        var steps: [NSSize] = []
        for width in stride(from: 640.0, through: 2560, by: 16) { steps.append(NSSize(width: width, height: 800)) }
        for height in stride(from: 640.0, through: 1400, by: 16) { steps.append(NSSize(width: 1600, height: height)) }
        var wall: [Double] = []
        for size in steps {
            let start = DispatchTime.now().uptimeNanoseconds
            window.setContentSize(size)
            RunLoop.main.run(until: Date())
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            wall.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        print("resize sweep · \(steps.count) sizes from 640x800 to 2560x800, then 1600x640 to 1600x1400")
        print("  wall time per size:       \(stats(wall))")
        let over = wall.filter { $0 > 16.7 }.count
        print(String(format: "  sizes over a 60 Hz frame (16.7 ms): %d (%.0f%%)", over, 100 * Double(over) / Double(max(1, wall.count))))
    }

    private static func settle(_ view: NSView, seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }
    }

    /// The accessibility text under the Map card, which the inspector fills.
    private static func inspectorText(_ view: NSView) -> String {
        var parts: [String] = []
        func walk(_ element: Any, depth: Int) {
            guard depth < 40, let object = element as? NSAccessibilityProtocol else { return }
            if let label = object.accessibilityLabel(), !label.isEmpty { parts.append(label) }
            for child in object.accessibilityChildren() ?? [] { walk(child, depth: depth + 1) }
        }
        walk(view, depth: 0)
        return parts.joined(separator: "|")
    }
}
