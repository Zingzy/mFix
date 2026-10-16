import AppKit

/// `mFix --assist-repro`: three windows of one app, like Ghostty. Snaps the first right
/// through the engine, opens Snap Assist in this process, picks the next window by id and
/// checks the pick lands left, the first stays right, and Snap Assist does not come back.
/// Sends no keyboard or mouse events.
@MainActor
public enum AssistRepro {
    public static func run() {
        let check = Check("assist repro")
        func finish() -> Never {
            SnapAssist.shared.end(focusLast: false)
            check.finish()
        }
        let windows = check.testWindows([["--test-windows", "3"]], count: 3, pump: true)
        guard windows.count == 3 else { check(false, "three test windows appeared"); finish() }
        Check.pump(0.5)
        let ours = Set(windows.map(\.id))
        let first = windows[0]
        let screen = Geo.screen(containing: first.frame)
        let work = Geo.workArea(screen)
        let left = Zone.left.frame(in: work), right = Zone.right.frame(in: work)
        func frames() -> String { windows.map { "\($0.id)=\($0.frame)" }.joined(separator: " ") }

        guard let (w, zone, s) = SnapEngine.shared.handle(.right, window: first) else {
            check(false, "Cmd+Option+Right snapped the first window"); finish()
        }
        Check.pump(0.3)
        check(first.frame.isClose(to: right, tolerance: 2), "first window \(first.id) snapped right (\(first.frame))")
        SnapAssist.shared.begin(after: w, zone: zone, on: s)
        Check.pump(0.5)
        let cards = SnapAssist.shared.cardIDs
        check(SnapAssist.shared.isOpen, "Snap Assist opened")
        let mine = cards.filter { ours.contains($0) }
        check(Set(mine) == ours.subtracting([first.id]), "its cards hold the other two test windows (cards \(cards))")
        guard let pickID = mine.first, let picked = windows.first(where: { $0.id == pickID }) else { finish() }
        print("     picking \(pickID); frames before:", frames())
        SnapAssist.shared.pick(window: pickID)
        let open = SnapAssist.shared.isOpen
        Check.pump(1.0)
        print("     frames after the pick:", frames())
        check(picked.frame.isClose(to: left, tolerance: 2), "the picked window \(pickID) is on the left (\(picked.frame))")
        check(first.frame.isClose(to: right, tolerance: 2), "the first window stayed on the right (\(first.frame))")
        check(!open && !SnapAssist.shared.isOpen, "Snap Assist closed once both halves were filled (open right after pick \(open), now \(SnapAssist.shared.isOpen), cards \(SnapAssist.shared.cardIDs))")
        finish()
    }
}
