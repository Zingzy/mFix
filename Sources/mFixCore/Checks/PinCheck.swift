import AppKit

/// `mFix --pin-check`: two test apps; the first is pinned on top, the second brought
/// forward, and the first must end up above it again, its border on it. Posts no input.
@MainActor
public enum PinCheck {
    public static func run() {
        // Which app is in front is what this checks, so the person's own clicks would spoil it.
        if ProcessInfo.processInfo.environment["MFIX_CHECK_NOW"] == nil { CheckGuard.begin() }
        let check = Check("pin check")
        defer { check.finish() }
        let w = check.testWindows([["--test-window"], ["--test-window"]], count: 2, pump: true)
        guard w.count == 2 else { check(false, "two test windows appeared"); return }
        let (pinned, other) = (w[0], w[1])
        func order() -> [CGWindowID] { WindowInfo.onScreen.map(\.id) }
        func above(_ a: CGWindowID, _ b: CGWindowID) -> Bool {
            let o = order()
            guard let i = o.firstIndex(of: a), let j = o.firstIndex(of: b) else { return false }
            return i < j
        }
        func frontPID() -> pid_t { Check.frontPID() ?? 0 }
        func state(_ label: String) {
            let o = order()
            print("     \(label): front pid \(frontPID()) (pinned \(pinned.pid), other \(other.pid)); pinned at \(o.firstIndex(of: pinned.id) ?? -1), other at \(o.firstIndex(of: other.id) ?? -1)")
        }
        FocusHistory.shared.start()
        AlwaysOnTop.shared.start()
        pinned.focus()
        Check.pump(0.5)
        AlwaysOnTop.shared.toggle(pinned)
        check(AlwaysOnTop.shared.pinnedIDs.contains(pinned.id), "the window is pinned")
        check(!AlwaysOnTop.shared.isMirrored(pinned.id), "while it has focus, no mirror shows")
        other.focus()
        Check.pump(1.0)
        state("1 s after the other app comes forward")
        check(frontPID() == other.pid, "the other app has the keyboard")
        check(AlwaysOnTop.shared.isMirrored(pinned.id), "the mirror shows over the pinned window")
        let own = ProcessInfo.processInfo.processIdentifier
        let rows = WindowInfo.onScreen
        let mirrorIndex = rows.firstIndex { $0.pid == own && $0.bounds.isClose(to: pinned.frame, tolerance: 2) }
        let otherIndex = rows.firstIndex { $0.id == other.id }
        check(mirrorIndex != nil && otherIndex != nil && mirrorIndex! < otherIndex!, "the mirror sits above the other app's window (\(mirrorIndex ?? -1) vs \(otherIndex ?? -1))")
        if ProcessInfo.processInfo.environment["MFIX_PIN_BENCH"] != nil {
            let cpu = LiveBench.measure(10)
            print(String(format: "     mirroring for 10 s: this process %.1f%%, WindowServer %.1f%%, replayd %.1f%% of one core",
                         cpu.me, cpu.ws, cpu.replayd))
        }
        AlwaysOnTop.shared.toggle(pinned)
        Check.pump(0.3)
        check(!AlwaysOnTop.shared.isMirrored(pinned.id), "unpinned, the mirror is gone")

        AlwaysOnTop.shared.toggle(pinned)
        pinned.focus()
        Check.pump(0.4)
        check(AlwaysOnTop.shared.hasBorder(pinned.id), "pinned again, the border shows")
        pinned.close()
        for t in [0.05, 0.15, 0.35] {
            Check.pump(t == 0.05 ? 0.05 : t == 0.15 ? 0.1 : 0.2)
            let listed = !WindowInfo.list(.optionIncludingWindow, relativeTo: pinned.id).isEmpty
            print("     \(t) s after close: listed \(listed), ordered in \(SkyLight.isOrderedIn(pinned.id)), minimized \(pinned.isMinimized), border \(AlwaysOnTop.shared.hasBorder(pinned.id))")
        }
        check(!AlwaysOnTop.shared.hasBorder(pinned.id) && !AlwaysOnTop.shared.pinnedIDs.contains(pinned.id),
              "closing the pinned window takes the border away within 0.35 s")

    }
}
