import AppKit

/// `Snap11 --dock-check <pid>`: rests the pointer on cmux's Dock icon and checks a running
/// Snap11 shows that app's windows above the icon, then moves away and checks they hide.
/// Moves the pointer only: no clicks, no keys.
@MainActor
public enum DockCheck {
    public static func run(snap11 pid: pid_t) {
        CheckGuard.begin()
        let check = Check("dock check")
        func move(_ p: CGPoint) {
            CheckGuard.poll()
            let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)
            CheckGuard.mark(e)
            e?.post(tap: .cghidEventTap)
            usleep(30_000)
        }
        func panels() -> [CGRect] {
            WindowInfo.list(.optionOnScreenOnly).filter { $0.pid == pid && $0.layer == Int(CGWindowLevelForKey(.popUpMenuWindow)) }.map(\.bounds)
        }
        let home = CGEvent(source: nil)?.location ?? .zero
        defer {
            move(home)
            check.finish()
        }
        guard let icon = DockItems.read().first(where: { $0.title == "cmux" })?.frame else { check(false, "cmux is in the Dock"); return }
        let start = CGPoint(x: icon.midX, y: icon.minY - 120)
        move(start)
        for i in 1...6 { move(CGPoint(x: icon.midX, y: start.y + CGFloat(i) * 20)) }
        move(CGPoint(x: icon.midX, y: icon.midY))
        usleep(800_000)
        for w in WindowInfo.list(.optionOnScreenOnly) where (w.owner == "Dock" || w.pid == pid) && w.bounds.width < 1500 {
            print("     window:", w.owner ?? "?", "layer", w.layer, w.bounds)
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
