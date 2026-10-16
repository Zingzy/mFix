import AppKit

/// `mFix --live-bench`: what live thumbnails cost. Ten seconds idle, then ten seconds of
/// live refresh on this Space's windows at switcher card size, with no UI. Reports this
/// process's CPU and memory and the CPU of WindowServer and replayd, where captures happen.
@MainActor
public enum LiveBench {
    private static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
    }

    private static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        return Double(info.resident_size) / 1_048_576
    }

    /// Cumulative CPU time of a system process, from ps.
    private static func cpuTime(of name: String) -> Double {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-A", "-o", "time=,comm="]
        let out = Pipe()
        p.standardOutput = out
        try? p.run()
        p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").filter { $0.hasSuffix(name) }.reduce(0) { total, line in
            let t = line.split(separator: " ").first.map(String.init) ?? "0:0"
            let parts = t.split(separator: ":").compactMap { Double($0) }
            return total + (parts.count == 2 ? parts[0] * 60 + parts[1] : parts.first ?? 0)
        }
    }

    /// This process's CPU and that of WindowServer and replayd over `seconds`, in percent of one core.
    static func measure(_ seconds: Double) -> (me: Double, ws: Double, replayd: Double) {
        let (me0, ws0, rp0) = (cpuSeconds(), cpuTime(of: "WindowServer"), cpuTime(of: "replayd"))
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        let (me1, ws1, rp1) = (cpuSeconds(), cpuTime(of: "WindowServer"), cpuTime(of: "replayd"))
        return ((me1 - me0) / seconds * 100, (ws1 - ws0) / seconds * 100, (rp1 - rp0) / seconds * 100)
    }

    public static func run() {
        let windows = WindowList.currentSpace()
        print("windows on this Space:", windows.count, windows.map { "\($0.id) \($0.app?.localizedName ?? "?")" })
        let onScreen = Set(WindowInfo.onScreen.map(\.id))
        print("of those on screen:", windows.filter { onScreen.contains($0.id) }.count)
        var once = 0
        Thumbnails.shared.capture(windows, points: 260) { _, _ in once += 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        print("one-off capture returned", once, "images")
        print("ps WindowServer cpu time now:", cpuTime(of: "WindowServer"))
        let mem0 = residentMB()
        let idle = measure(10)
        let live = LiveThumbnails()
        var frames = 0
        live.start(windows, points: 260) { _, _ in frames += 1 }
        let on = measure(10)
        live.stop()
        let mem1 = residentMB()
        func pct(_ x: Double) -> String { String(format: "%.1f%%", x) }
        print("idle:  mfix \(pct(idle.me))  WindowServer \(pct(idle.ws))  replayd \(pct(idle.replayd))")
        print("live:  mfix \(pct(on.me))  WindowServer \(pct(on.ws))  replayd \(pct(on.replayd))  (\(frames) thumbnails in 10 s)")
        print(String(format: "memory: %.0f MB before, %.0f MB after", mem0, mem1))
        exit(0)
    }
}
