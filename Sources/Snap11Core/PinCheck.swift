import AppKit

/// `Snap11 --pin-check`: two test apps; the first is pinned on top, the second brought
/// forward, and the first must end up above it again, its border on it. Posts no input.
@MainActor
public enum PinCheck {
    public static func run() {
        // Which app is in front is what this checks, so the person's own clicks would spoil it.
        if ProcessInfo.processInfo.environment["SNAP11_CHECK_NOW"] == nil { CheckGuard.begin() }
        Settings.register()
        let apps = (0..<2).map { _ -> Process in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            p.arguments = ["--test-window"]
            try? p.run()
            return p
        }
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "ok  " : "FAIL", what)
            if !ok { failures += 1 }
        }
        defer {
            apps.forEach { $0.terminate() }
            print(failures == 0 ? "pin check passed" : "pin check: \(failures) failed")
            exit(failures == 0 ? 0 : 1)
        }
        var w: [AXWindow] = []
        for _ in 0..<40 where w.count < 2 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            w = apps.compactMap { a in AXWindow.windows(of: a.processIdentifier).first(where: { $0.isStandard }) }
        }
        guard w.count == 2 else { check(false, "two test windows appeared"); return }
        let (pinned, other) = (w[0], w[1])
        func order() -> [CGWindowID] {
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
                .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        }
        func above(_ a: CGWindowID, _ b: CGWindowID) -> Bool {
            let o = order()
            guard let i = o.firstIndex(of: a), let j = o.firstIndex(of: b) else { return false }
            return i < j
        }
        func frontPID() -> pid_t {
            guard let app: AXUIElement = AXUIElementCreateSystemWide().attr(kAXFocusedApplicationAttribute) else { return 0 }
            var pid: pid_t = 0
            AXUIElementGetPid(app, &pid)
            return pid
        }
        func state(_ label: String) {
            let o = order()
            print("     \(label): front pid \(frontPID()) (pinned \(pinned.pid), other \(other.pid)); pinned at \(o.firstIndex(of: pinned.id) ?? -1), other at \(o.firstIndex(of: other.id) ?? -1)")
        }
        FocusHistory.shared.start()
        AlwaysOnTop.shared.start()
        pinned.focus()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        AlwaysOnTop.shared.toggle(pinned)
        check(AlwaysOnTop.shared.pinnedIDs.contains(pinned.id), "the window is pinned")
        check(!AlwaysOnTop.shared.isMirrored(pinned.id), "while it has focus, no mirror shows")
        other.focus()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        state("1 s after the other app comes forward")
        check(frontPID() == other.pid, "the other app has the keyboard")
        check(AlwaysOnTop.shared.isMirrored(pinned.id), "the mirror shows over the pinned window")
        let own = ProcessInfo.processInfo.processIdentifier
        let rows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
        let mirrorIndex = rows.firstIndex { ($0[kCGWindowOwnerPID as String] as? pid_t) == own
            && (CGRect(dictionaryRepresentation: ($0[kCGWindowBounds as String] as? NSDictionary) ?? [:]) ?? .zero).isClose(to: pinned.frame, tolerance: 2) }
        let otherIndex = rows.firstIndex { ($0[kCGWindowNumber as String] as? CGWindowID) == other.id }
        check(mirrorIndex != nil && otherIndex != nil && mirrorIndex! < otherIndex!, "the mirror sits above the other app's window (\(mirrorIndex ?? -1) vs \(otherIndex ?? -1))")
        if ProcessInfo.processInfo.environment["SNAP11_PIN_BENCH"] != nil {
            func cpu() -> Double {
                var u = rusage()
                getrusage(RUSAGE_SELF, &u)
                return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6
            }
            func sys(_ name: String) -> Double {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/ps")
                p.arguments = ["-A", "-o", "time=,comm="]
                let out = Pipe()
                p.standardOutput = out
                try? p.run()
                p.waitUntilExit()
                let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return text.split(separator: "\n").filter { $0.hasSuffix(name) }.reduce(0) { t, line in
                    let parts = (line.split(separator: " ").first.map(String.init) ?? "0:0").split(separator: ":").compactMap { Double($0) }
                    return t + (parts.count == 2 ? parts[0] * 60 + parts[1] : parts.first ?? 0)
                }
            }
            let (c0, w0, r0) = (cpu(), sys("WindowServer"), sys("replayd"))
            RunLoop.current.run(until: Date().addingTimeInterval(10))
            let (c1, w1, r1) = (cpu(), sys("WindowServer"), sys("replayd"))
            print(String(format: "     mirroring for 10 s: this process %.1f%%, WindowServer %.1f%%, replayd %.1f%% of one core",
                         (c1 - c0) * 10, (w1 - w0) * 10, (r1 - r0) * 10))
        }
        AlwaysOnTop.shared.toggle(pinned)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        check(!AlwaysOnTop.shared.isMirrored(pinned.id), "unpinned, the mirror is gone")

        AlwaysOnTop.shared.toggle(pinned)
        pinned.focus()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        check(AlwaysOnTop.shared.hasBorder(pinned.id), "pinned again, the border shows")
        pinned.close()
        for t in [0.05, 0.15, 0.35] {
            RunLoop.current.run(until: Date().addingTimeInterval(t == 0.05 ? 0.05 : t == 0.15 ? 0.1 : 0.2))
            let listed = !(CGWindowListCopyWindowInfo(.optionIncludingWindow, pinned.id) as? [[String: Any]] ?? []).isEmpty
            print("     \(t) s after close: listed \(listed), ordered in \(SkyLight.isOrderedIn(pinned.id)), minimized \(pinned.isMinimized), border \(AlwaysOnTop.shared.hasBorder(pinned.id))")
        }
        check(!AlwaysOnTop.shared.hasBorder(pinned.id) && !AlwaysOnTop.shared.pinnedIDs.contains(pinned.id),
              "closing the pinned window takes the border away within 0.35 s")

    }
}
