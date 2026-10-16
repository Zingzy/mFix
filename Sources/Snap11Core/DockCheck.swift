import AppKit

/// `Snap11 --dock-check <pid>`: rests the pointer on cmux's Dock icon and checks a running
/// Snap11 shows that app's windows above the icon, then moves away and checks they hide.
/// Moves the pointer only: no clicks, no keys.
@MainActor
public enum DockCheck {
    public static func run(snap11 pid: pid_t) {
        CheckGuard.begin()
        var failures = 0
        func check(_ ok: Bool, _ what: String) {
            print(ok ? "ok  " : "FAIL", what)
            if !ok { failures += 1 }
        }
        func move(_ p: CGPoint) {
            CheckGuard.poll()
            let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
            CheckGuard.mark(e)
            e?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
        func panels() -> [CGRect] {
            (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []).compactMap { w in
                guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                      (w[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.popUpMenuWindow)),
                      let b = w[kCGWindowBounds as String] as? NSDictionary else { return nil }
                return CGRect(dictionaryRepresentation: b)
            }
        }
        let home = CGEvent(source: nil)?.location ?? .zero
        defer {
            move(home)
            print(failures == 0 ? "dock check passed" : "dock check: \(failures) failed")
            exit(failures == 0 ? 0 : 1)
        }
        guard let icon = DockItems.read().first(where: { $0.title == "cmux" })?.frame else { check(false, "cmux is in the Dock"); return }
        let start = CGPoint(x: icon.midX, y: icon.minY - 120)
        move(start)
        for i in 1...6 { move(CGPoint(x: icon.midX, y: start.y + CGFloat(i) * 20)) }
        move(CGPoint(x: icon.midX, y: icon.midY))
        usleep(800_000)
        for w in (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
        where ["Dock"].contains(w[kCGWindowOwnerName as String] as? String ?? "") || (w[kCGWindowOwnerPID as String] as? pid_t) == pid {
            let b = CGRect(dictionaryRepresentation: (w[kCGWindowBounds as String] as? NSDictionary) ?? [:]) ?? .zero
            if b.width < 1500 { print("     window:", w[kCGWindowOwnerName as String] ?? "?", "layer", w[kCGWindowLayer as String] ?? "?", b) }
        }
        let shown = panels()
        check(shown.contains { $0.maxY <= icon.minY + 1 && $0.minX <= icon.midX && $0.maxX >= icon.midX },
              "resting on cmux's icon shows its windows above it (\(shown), icon \(icon))")
        move(CGPoint(x: icon.midX, y: icon.minY - 400))
        move(CGPoint(x: icon.midX + 500, y: icon.minY - 400))
        usleep(700_000)
        check(panels().isEmpty, "moving away hides them")
    }
}
