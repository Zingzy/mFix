import AppKit

/// `Snap11 --drive <pid>`: presses the real chords at a running Snap11 (pid) the way a
/// person would, against a throwaway test window, and checks what happened on screen.
@MainActor
public enum DriveCheck {
    private static let source = CGEventSource(stateID: .hidSystemState)

    private static func key(_ code: Int64, down: Bool, flags: CGEventFlags) {
        let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
        // Hardware arrow keys always carry the numeric-pad and Fn bits.
        let arrow = [Key.left, Key.right, Key.up, Key.down].contains(code)
        e?.flags = arrow ? flags.union([.maskNumericPad, .maskSecondaryFn]) : flags
        e?.post(tap: .cghidEventTap)
        usleep(30_000)
    }

    private static func modifiers(_ flags: CGEventFlags) {
        let e = CGEvent(source: source)
        e?.type = .flagsChanged
        e?.flags = flags
        e?.post(tap: .cghidEventTap)
        usleep(30_000)
    }

    private static func panels(of pid: pid_t) -> [CGRect] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return info.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let l = w[kCGWindowLayer as String] as? Int, l == level || l == level + 1,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
                  r.width > 40 else { return nil }
            return r
        }
    }

    /// NSWorkspace only refreshes the frontmost app from run-loop notifications, and this
    /// check blocks its run loop, so ask Accessibility, which answers live.
    private static func frontPID() -> pid_t? {
        guard let app: AXUIElement = AXUIElementCreateSystemWide().attr(kAXFocusedApplicationAttribute) else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        return pid
    }

    private static func name(_ pid: pid_t?) -> String {
        pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName } ?? "?"
    }

    private static func mouse(_ type: CGEventType, _ p: CGPoint) {
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
        if type == .leftMouseDown || type == .leftMouseUp { e?.setIntegerValueField(.mouseEventClickState, value: 1) }
        e?.post(tap: .cghidEventTap)
        usleep(30_000)
    }

    public static func run(snap11 pid: pid_t) {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--test-window"]
        try? child.run()
        var failures = 0
        defer {
            modifiers([])
            child.terminate()
            print(failures == 0 ? "drive check passed" : "drive check: \(failures) failed")
            exit(failures == 0 ? 0 : 1)
        }
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "ok  " : "FAIL", what)
            if !ok { failures += 1 }
        }
        var window: AXWindow?
        for _ in 0..<40 where window == nil {
            usleep(100_000)
            window = AXWindow.windows(of: child.processIdentifier).first(where: { $0.isStandard })
        }
        guard let window else { check(false, "test window appeared"); return }
        usleep(500_000)
        check(frontPID() == child.processIdentifier, "test window is frontmost (\(name(frontPID())))")
        let work = Geo.workArea(Geo.screen(containing: window.frame))

        let win: CGEventFlags = [.maskCommand, .maskAlternate]
        modifiers(win)
        key(Key.left, down: true, flags: win)
        key(Key.left, down: false, flags: win)
        usleep(300_000)
        check(window.frame.isClose(to: Zone.left.frame(in: work), tolerance: 2), "Cmd+Option+Left snapped the window to the left half (\(window.frame))")
        check(panels(of: pid).isEmpty, "Snap Assist waits while the chord is held")
        modifiers([])
        usleep(600_000)
        let assist = panels(of: pid)
        check(assist.contains { $0.isClose(to: Zone.right.frame(in: work), tolerance: 2) }, "Snap Assist covers the right half after release (\(assist))")
        key(Key.escape, down: true, flags: [])
        key(Key.escape, down: false, flags: [])
        usleep(400_000)
        check(panels(of: pid).isEmpty, "Esc closed Snap Assist")

        // Snap Layouts: hover the green button, click the right zone of the halves layout.
        let home = CGEvent(source: nil)?.location ?? .zero
        defer { mouse(.mouseMoved, home) }
        window.focus()
        usleep(300_000)
        if let button = window.fullScreenButtonFrame {
            let c = CGPoint(x: button.midX, y: button.midY)
            mouse(.mouseMoved, CGPoint(x: c.x + 40, y: c.y + 40))
            mouse(.mouseMoved, c)
            usleep(250_000)
            check(panels(of: pid).isEmpty, "flyout waits for the hover delay")
            usleep(700_000)
            let flyout = panels(of: pid).first
            let screenLeft = Geo.workArea(Geo.screen(containing: window.frame)).minX
            check(flyout.map { $0.minY > button.maxY && (abs($0.midX - c.x) < 2 || abs($0.minX - screenLeft - 8) < 1) } ?? false, "hovering the green button opens the flyout under it, centred or held 8pt inside the screen (\(flyout ?? .zero))")
            usleep(1_000_000)
            let native = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                .contains { ($0[kCGWindowOwnerName as String] as? String) == "ThemeWidgetControlViewService" && ($0[kCGWindowLayer as String] as? Int) == 101 }
            check(!native, "macOS's own green-button popover stayed away a second later")
            if let f = flyout {
                // One suggestion row (cmux is on this Space), then halves at the start of row two.
                let target = CGPoint(x: f.minX + 12 + 72, y: f.minY + 12 + 56 + 12 + 28)
                mouse(.mouseMoved, CGPoint(x: target.x, y: f.minY + 4))
                mouse(.mouseMoved, target)
                usleep(150_000)
                let stack = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).filter {
                    CGRect(dictionaryRepresentation: ($0[kCGWindowBounds as String] as? NSDictionary) ?? [:])?.contains(target) ?? false
                }.prefix(3).map { "\($0[kCGWindowOwnerName as String] ?? "?")@\($0[kCGWindowLayer as String] ?? "?")" }
                print("     windows at the click point, front first:", stack)
                mouse(.leftMouseDown, target)
                mouse(.leftMouseUp, target)
                usleep(500_000)
                check(window.frame.isClose(to: Zone.right.frame(in: work), tolerance: 2), "clicking the right zone of halves snapped right (\(window.frame))")
                let assist = panels(of: pid)
                check(assist.contains { $0.isClose(to: Zone.left.frame(in: work), tolerance: 2) }, "Snap Assist took the left half (\(assist))")
                key(Key.escape, down: true, flags: [])
                key(Key.escape, down: false, flags: [])
                usleep(400_000)
            }
        } else {
            check(false, "test window exposes its green button")
        }

        let before = frontPID()
        modifiers(.maskCommand)
        key(Key.tab, down: true, flags: .maskCommand)
        key(Key.tab, down: false, flags: .maskCommand)
        usleep(500_000)
        let switcher = panels(of: pid)
        check(!switcher.isEmpty, "Cmd+Tab held open shows the switcher (\(switcher))")
        modifiers([])
        var trail: [String] = []
        for _ in 0..<15 {
            usleep(100_000)
            trail.append(name(frontPID()))
        }
        print("     front after release, every 100 ms:", trail.joined(separator: " "))
        check(panels(of: pid).isEmpty, "releasing Cmd closed the switcher")
        let after = frontPID()
        check(after != before, "releasing Cmd switched from \(name(before)) to \(name(after))")
    }
}
