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
        CheckGuard.poll()
        CheckGuard.mark(e)
        e?.post(tap: .cghidEventTap)
        usleep(30_000)
    }

    private static func modifiers(_ flags: CGEventFlags) {
        let e = CGEvent(source: source)
        e?.type = .flagsChanged
        e?.flags = flags
        CheckGuard.mark(e)
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

    private static func windows(of pid: pid_t, level: Int) -> [CGRect] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.compactMap { w in
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid, (w[kCGWindowLayer as String] as? Int) == level,
                  let b = w[kCGWindowBounds as String] as? NSDictionary else { return nil }
            return CGRect(dictionaryRepresentation: b)
        }
    }

    private static func dockIcon(named title: String) -> CGRect? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        for list in (app.attr(kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            for item in (list.attr(kAXChildrenAttribute) as [AXUIElement]?) ?? [] where (item.attr(kAXTitleAttribute) as String?) == title {
                if let p = item.point(kAXPositionAttribute), let s = item.size(kAXSizeAttribute) { return CGRect(origin: p, size: s) }
            }
        }
        return nil
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
        pid.map { "\(NSRunningApplication(processIdentifier: $0)?.localizedName ?? "?") (pid \($0))" } ?? "?"
    }

    private static func mouse(_ type: CGEventType, _ p: CGPoint) {
        let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: .left)
        if type == .leftMouseDown || type == .leftMouseUp { e?.setIntegerValueField(.mouseEventClickState, value: 1) }
        CheckGuard.poll()
        CheckGuard.mark(e)
        e?.post(tap: .cghidEventTap)
        usleep(30_000)
    }

    public static func run(snap11 pid: pid_t) {
        CheckGuard.begin()
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
        if frontPID() != child.processIdentifier {
            _ = SkyLight.makeFront(pid: child.processIdentifier, window: window.id)
            usleep(400_000)
        }
        let front = frontPID() == child.processIdentifier
        check(front, "test window is frontmost (\(name(frontPID())))")
        // Every chord below acts on the frontmost window; never let that be one of the person's.
        guard front else { return }
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
        usleep(600_000)
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

        // Drag to snap: float the window, then drag its title bar to the left edge.
        window.setFrame(CGRect(x: 300, y: 250, width: 600, height: 432))
        usleep(300_000)
        let floating = window.frame
        let grab = CGPoint(x: floating.midX, y: floating.minY + 12)
        mouse(.mouseMoved, grab)
        mouse(.leftMouseDown, grab)
        var p = grab
        while p.x > 1 {
            p.x = max(0, p.x - 40)
            mouse(.leftMouseDragged, p)
        }
        usleep(400_000)
        let previews = windows(of: pid, level: 0)
        check(previews.contains { $0.isClose(to: Zone.left.frame(in: work).insetBy(dx: 8, dy: 8), tolerance: 3) },
              "dragging to the left edge shows the preview (\(previews))")
        mouse(.leftMouseUp, p)
        usleep(600_000)
        check(window.frame.isClose(to: Zone.left.frame(in: work), tolerance: 2), "releasing on the edge snapped left (\(window.frame))")
        check(panels(of: pid).contains { $0.isClose(to: Zone.right.frame(in: work), tolerance: 2) }, "Snap Assist opened on the right")
        key(Key.escape, down: true, flags: [])
        key(Key.escape, down: false, flags: [])
        usleep(300_000)

        // Drag it back out: the pre-snap size comes back under the pointer.
        let snapped = window.frame
        let grab2 = CGPoint(x: snapped.midX, y: snapped.minY + 12)
        mouse(.mouseMoved, grab2)
        mouse(.leftMouseDown, grab2)
        for i in 1...8 { mouse(.leftMouseDragged, CGPoint(x: grab2.x + CGFloat(i * 30), y: grab2.y + CGFloat(i * 20))) }
        mouse(.leftMouseUp, CGPoint(x: grab2.x + 240, y: grab2.y + 160))
        usleep(400_000)
        let out = window.frame
        check(abs(out.width - floating.width) < 2 && abs(out.height - floating.height) < 2,
              "dragging the snapped window out restored its size (\(out.size), want \(floating.size))")

        // Drag and drop: preview under the pointer, Dock spring-loading, the switcher mid-drag.
        window.setFrame(CGRect(x: 300, y: 250, width: 600, height: 432))
        window.focus()
        usleep(500_000)
        let start = CGPoint(x: 600, y: 450)
        mouse(.mouseMoved, start)
        mouse(.leftMouseDown, start)
        var q = start
        for _ in 0..<6 { q.x += 12; q.y += 8; mouse(.leftMouseDragged, q) }
        usleep(400_000)
        let previewLevel = Int(CGWindowLevelForKey(.floatingWindow))
        let shown = windows(of: pid, level: previewLevel)
        let expected = CGPoint(x: q.x + 4, y: q.y + 6)
        let follows = shown.contains { abs($0.minX - expected.x) < 3 && abs($0.minY - expected.y) < 3 }
        check(follows, "a file drag shows the preview under the pointer (\(shown), pointer \(q))")
        if let cmuxIcon = dockIcon(named: "cmux") {
            let target = CGPoint(x: cmuxIcon.midX, y: cmuxIcon.midY)
            while abs(q.y - target.y) > 10 || abs(q.x - target.x) > 10 {
                q.x += (target.x - q.x) / 6
                q.y += (target.y - q.y) / 6
                mouse(.leftMouseDragged, q)
            }
            for _ in 0..<15 { mouse(.leftMouseDragged, q); usleep(40_000) }
            usleep(300_000)
            check(name(frontPID()).hasPrefix("cmux"), "holding the drag on cmux's Dock icon brought cmux forward (\(name(frontPID())))")
        } else {
            check(false, "cmux is in the Dock")
        }
        // Cmd+Tab mid-drag, then hold over the test window's card to switch back to it.
        modifiers(.maskCommand)
        key(Key.tab, down: true, flags: .maskCommand)
        key(Key.tab, down: false, flags: .maskCommand)
        usleep(500_000)
        let midDrag = panels(of: pid)
        check(!midDrag.isEmpty, "Cmd+Tab mid-drag opens the switcher (\(midDrag))")
        if let panel = midDrag.first {
            // cmux is front now, so the test window is the second most recent: its card is
            // second in the first row, past the 56pt padding and the first card.
            let card = CGPoint(x: panel.minX + 56 + 375 + 26 + 100, y: panel.minY + 56 + 130)
            while abs(q.y - card.y) > 10 || abs(q.x - card.x) > 10 {
                q.x += (card.x - q.x) / 5
                q.y += (card.y - q.y) / 5
                mouse(.leftMouseDragged, q)
            }
            for _ in 0..<18 { mouse(.leftMouseDragged, q); usleep(40_000) }
            usleep(300_000)
            check(frontPID() == child.processIdentifier, "holding the drag over a card switched to it (\(name(frontPID())))")
        }
        modifiers([])
        usleep(200_000)
        let back = CGPoint(x: window.frame.midX, y: window.frame.midY)
        mouse(.leftMouseDragged, back)
        mouse(.leftMouseUp, back)
        usleep(500_000)
        check(windows(of: pid, level: Int(CGWindowLevelForKey(.floatingWindow))).isEmpty, "the preview went away on drop")

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
