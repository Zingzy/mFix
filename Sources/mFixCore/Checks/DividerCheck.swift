import AppKit

/// `mFix --divider-check`: four windows of one test app in quarters as a snap group; the
/// horizontal line and then the vertical line are dragged through the group's own code, and
/// every window's frame is checked. Posts no input.
@MainActor
public enum DividerCheck {
    public static func run() {
        let check = Check("divider check")
        defer { check.finish() }
        let w = check.testWindows([["--test-windows", "4"]], count: 4, pump: true)
        guard w.count == 4 else { check(false, "four test windows appeared"); return }
        let screen = Geo.screen(containing: w[0].frame)
        let work = Geo.workArea(screen)
        let midX = work.minX + work.width / 2, midY = work.minY + work.height / 2

        // Quarters as a group.
        for (win, zone) in zip(w, Layout.quarters.zones) { SnapEngine.shared.place(win, zone: zone, on: screen) }
        SnapGroups.shared.join(Array(w.dropFirst()), with: w[0], on: screen)
        Check.pump(0.5)
        let lower = (midY + 120).rounded()
        check(SnapGroups.shared.dragLine(at: CGPoint(x: work.minX + 200, y: midY), to: lower), "quarters: a handle on the horizontal line")
        Check.pump(0.4)
        let tops = w.filter { $0.frame.minY < midY - 50 }, bottoms = w.filter { $0.frame.minY > midY - 50 }
        check(tops.count == 2 && tops.allSatisfy { abs($0.frame.maxY - lower) <= 2 }
              && bottoms.count == 2 && bottoms.allSatisfy { abs($0.frame.minY - lower) <= 2 }, "quarters: windows above and below follow the line")

        // Your layout: left half and two right quarters, never grouped, the left one a few
        // points short of the line the way a terminal sized in whole cells leaves it.
        w[3].minimize()
        let (left, top, bottom) = (w[0], w[1], w[2])
        for g in [left, top, bottom] { SnapGroups.shared.leave(g) }
        SnapEngine.shared.place(left, zone: .left, on: screen)
        SnapEngine.shared.place(top, zone: .topRight, on: screen)
        SnapEngine.shared.place(bottom, zone: .bottomRight, on: screen)
        var short = left.frame
        short.size.width -= 7
        left.setFrame(short)
        SnapEngine.shared.adopt(left)
        Check.pump(0.5)
        check(SnapGroups.shared.group(containing: left.id) == nil, "half and quarters: not a group")
        let right = (midX + 150).rounded()
        check(SnapGroups.shared.dragLine(at: CGPoint(x: midX - 3, y: work.minY + 300), to: right), "half and quarters: a handle in the 7 pt gap")
        Check.pump(0.4)
        check(abs(left.frame.maxX - right) <= 2 && abs(top.frame.minX - right) <= 2 && abs(bottom.frame.minX - right) <= 2,
              "half and quarters: the left window and both quarters meet at the new line (\(left.frame.maxX) \(top.frame.minX) \(bottom.frame.minX))")
        let down = (midY + 80).rounded()
        check(SnapGroups.shared.dragLine(at: CGPoint(x: right + 200, y: midY), to: down), "half and quarters: a handle between the two quarters")
        Check.pump(0.4)
        check(abs(top.frame.maxY - down) <= 2 && abs(bottom.frame.minY - down) <= 2 && abs(left.frame.maxY - work.maxY) <= 2,
              "half and quarters: the quarters meet at it and the left window keeps its height")
    }
}
