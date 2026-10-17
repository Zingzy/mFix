import AppKit

/// Timings behind the numbers people feel: `--snap-bench` (a test window snapped across
/// zones), `--thumb-bench` (one round of thumbnails for this Space) and `--switcher-bench`
/// (listing windows and building the Cmd+Tab panel, kept off screen). Posts no input.
@MainActor
public enum PerfBench {
    private static func ms(since t: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6 }

    private static func report(_ label: String, _ values: [Double]) {
        let s = values.sorted()
        guard !s.isEmpty else { print("\(label): no samples"); return }
        let p95 = s[min(s.count - 1, Int((Double(s.count) * 0.95).rounded(.up)) - 1)]
        print(String(format: "%@: n %d  median %.1f ms  p95 %.1f ms  max %.1f ms", label, s.count, s[s.count / 2], p95, s.last!))
    }

    /// The call is the AX writes returning; landed is WindowServer listing the window at
    /// its new bounds, which is when the move can be on screen.
    public static func snap(count: Int = 50) {
        let check = Check()
        guard let window = check.testWindows([["--test-window"]], count: 1, pump: false).first else {
            print("test window never appeared"); exit(1)
        }
        let screen = Geo.screen(containing: window.frame)
        let work = Geo.workArea(screen)
        let zones: [Zone] = [.left, .topLeft, .topRight, .right, .bottomRight, .bottomLeft, .full] + Layout.thirds.zones
        var call: [Double] = [], landed: [Double] = []
        var missed = 0
        for i in 0..<count {
            let zone = zones[i % zones.count]
            let target = zone.frame(in: work)
            let t = DispatchTime.now().uptimeNanoseconds
            SnapEngine.shared.place(window, zone: zone, on: screen)
            call.append(ms(since: t))
            var done = false
            while ms(since: t) < 1000 {
                if let b = WindowInfo.list(.optionIncludingWindow, relativeTo: window.id).first(where: { $0.id == window.id })?.bounds,
                   b.isClose(to: target, tolerance: 2) {
                    done = true
                    break
                }
                usleep(500)
            }
            if done { landed.append(ms(since: t)) } else { missed += 1 }
            usleep(50_000)
        }
        report("snap call", call)
        report("snap landed", landed)
        print("did not land within 1 s: \(missed)")
        check.finish()
    }

    /// A fresh process's first listing can go past the wait before apps answer and come back
    /// short; the running app is always past that.
    static func warmList() {
        _ = WindowList.currentSpace()
        Check.pump(0.5)
    }

    public static func thumbnails(rounds: Int = 5) {
        warmList()
        let windows = WindowList.currentSpace()
        print("windows on this Space:", windows.count)
        var perWindow: [Double] = [], batch: [Double] = []
        for r in 0..<rounds {
            var finished = false
            var arrivals: [Double] = []
            let t = DispatchTime.now().uptimeNanoseconds
            Thumbnails.shared.capture(windows, points: 260, done: { finished = true }) { _, _ in arrivals.append(ms(since: t)) }
            while !finished && ms(since: t) < 10_000 { Check.pump(0.002) }
            let total = ms(since: t)
            print(String(format: "round %d: %d images, all in %.1f ms", r, arrivals.count, total))
            if r > 0 {
                perWindow += arrivals
                batch.append(total)
            }
            Check.pump(0.3)
        }
        report("one window's image after the request (rounds 1+)", perWindow)
        report("every window's image (rounds 1+)", batch)
        exit(0)
    }

    public static func switcher(runs: Int = 10) {
        OverlayPanel.offscreen = true
        FocusHistory.shared.start()
        warmList()
        var list: [Double] = [], build: [Double] = []
        for _ in 0..<runs {
            let t = DispatchTime.now().uptimeNanoseconds
            Switcher.shared.windows = WindowList.currentSpace()
            list.append(ms(since: t))
            let t2 = DispatchTime.now().uptimeNanoseconds
            Switcher.shared.show()
            build.append(ms(since: t2))
            Check.pump(0.4)
            Switcher.shared.cancel()
            Check.pump(0.2)
        }
        print("windows:", Switcher.shared.windows.count)
        report("list windows", list)
        report("build panel", build)
        report("both", zip(list, build).map(+))
        exit(0)
    }
}
