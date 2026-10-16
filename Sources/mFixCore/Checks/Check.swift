import AppKit

/// What the checks share: copies of mFix showing test windows, one ok or FAIL line per
/// step, and the exit code, after a summary line when the check has a name.
@MainActor
final class Check {
    private let name: String?
    private var children: [Process] = []
    private(set) var failures = 0

    init(_ name: String? = nil) { self.name = name }

    func callAsFunction(_ ok: Bool, _ what: String) {
        print(ok ? "ok  " : "FAIL", what)
        if !ok { failures += 1 }
    }

    /// Starts a copy of mFix for each list of arguments and waits up to 4 s for `count`
    /// standard windows among them. `pump` runs the run loop while waiting instead of sleeping.
    func testWindows(_ arguments: [[String]], count: Int, pump: Bool) -> [AXWindow] {
        children = arguments.map { args in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            p.arguments = args
            try? p.run()
            return p
        }
        var windows: [AXWindow] = []
        for _ in 0..<40 where windows.count < count {
            if pump { Check.pump(0.1) } else { usleep(100_000) }
            windows = children.flatMap { AXWindow.windows(of: $0.processIdentifier).filter(\.isStandard) }
        }
        return windows
    }

    func finish() -> Never {
        children.forEach { $0.terminate() }
        if let name { print(failures == 0 ? "\(name) passed" : "\(name): \(failures) failed") }
        exit(failures == 0 ? 0 : 1)
    }

    static func pump(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    /// NSWorkspace only refreshes the frontmost app from run-loop notifications, and checks
    /// block their run loop, so ask Accessibility, which answers live.
    static func frontPID() -> pid_t? {
        guard let app: AXUIElement = AXUIElementCreateSystemWide().attr(kAXFocusedApplicationAttribute) else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        return pid
    }
}
