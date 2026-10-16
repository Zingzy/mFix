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
        let level = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return WindowInfo.list(.optionOnScreenOnly)
            .filter { $0.pid == pid && ($0.layer == level || $0.layer == level + 1) && $0.bounds.width > 40 }.map(\.bounds)
    }

    private static func windows(of pid: pid_t, level: Int) -> [CGRect] {
        WindowInfo.list(.optionOnScreenOnly).filter { $0.pid == pid && $0.layer == level }.map(\.bounds)
    }

    private static func frontPID() -> pid_t? { Check.frontPID() }

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

    /// Three windows of one app: snap one right, pick the first card in Snap Assist, and
    /// check the pick lands left, the first stays right, and Snap Assist does not come back.
    public static func assist(snap11 pid: pid_t) {
        CheckGuard.begin()
        let check = Check("assist check")
        defer {
            modifiers([])
            check.finish()
        }
        let windows = check.testWindows([["--test-windows", "3"]], count: 3, pump: false)
        guard windows.count == 3 else { check(false, "three test windows appeared"); return }
        let first = windows[0]
        first.focus()
        usleep(600_000)
        guard frontPID() == first.pid else { check(false, "test windows are frontmost"); return }
        let work = Geo.workArea(Geo.screen(containing: first.frame))
        let win: CGEventFlags = [.maskCommand, .maskAlternate]
        modifiers(win)
        key(Key.right, down: true, flags: win)
        key(Key.right, down: false, flags: win)
        modifiers([])
        usleep(900_000)
        let snapped = windows.first { $0.frame.isClose(to: Zone.right.frame(in: work), tolerance: 2) }
        check(snapped != nil, "one window snapped right")
        check(panels(of: pid).contains { $0.isClose(to: Zone.left.frame(in: work), tolerance: 2) }, "Snap Assist opened on the left")
        key(Key.returnKey, down: true, flags: [])
        key(Key.returnKey, down: false, flags: [])
        usleep(900_000)
        let frames = windows.map(\.frame)
        print("     frames after the pick:", frames.map { "\($0)" }.joined(separator: " "))
        check(windows.contains { $0.frame.isClose(to: Zone.left.frame(in: work), tolerance: 2) }, "the picked window is on the left")
        check(snapped.map { $0.frame.isClose(to: Zone.right.frame(in: work), tolerance: 2) } ?? false, "the first window stayed on the right")
        check(panels(of: pid).isEmpty, "Snap Assist closed once both halves were filled")
        key(Key.escape, down: true, flags: [])
        key(Key.escape, down: false, flags: [])
    }

    public static func run(snap11 pid: pid_t) {
        CheckGuard.begin()
        let check = Check("drive check")
        defer {
            modifiers([])
            check.finish()
        }
        guard let window = check.testWindows([["--test-window"]], count: 1, pump: false).first else {
            check(false, "test window appeared"); return
        }
        usleep(500_000)
        if frontPID() != window.pid {
            _ = SkyLight.makeFront(pid: window.pid, window: window.id)
            usleep(400_000)
        }
        let front = frontPID() == window.pid
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
            let native = WindowInfo.list(.optionOnScreenOnly).contains { $0.owner == "ThemeWidgetControlViewService" && $0.layer == 101 }
            check(!native, "macOS's own green-button popover stayed away a second later")
            if let f = flyout {
                // One suggestion row (cmux is on this Space), then halves at the start of row two.
                let target = CGPoint(x: f.minX + 12 + 72, y: f.minY + 12 + 56 + 12 + 28)
                mouse(.mouseMoved, CGPoint(x: target.x, y: f.minY + 4))
                mouse(.mouseMoved, target)
                usleep(150_000)
                let stack = WindowInfo.list(.optionOnScreenOnly).filter { $0.bounds.contains(target) }
                    .prefix(3).map { "\($0.owner ?? "?")@\($0.layer)" }
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
        if let cmuxIcon = DockItems.read().first(where: { $0.title == "cmux" })?.frame {
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
            check(frontPID() == window.pid, "holding the drag over a card switched to it (\(name(frontPID())))")
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
