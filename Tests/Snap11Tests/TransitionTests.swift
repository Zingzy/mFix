import CoreGraphics
import Testing
@testable import Snap11Core

/// Rows of the Win+Arrow table in the Windows 11 spec, section 1.3.
@Suite struct TransitionTests {
    @Test func restored() {
        #expect(decide(.restored, .up) == .snap(.full))
        #expect(decide(.restored, .down) == .minimize)
        #expect(decide(.restored, .left) == .snap(.left))
        #expect(decide(.restored, .right) == .snap(.right))
    }

    @Test func maximized() {
        #expect(decide(.maximized, .up) == .none)
        #expect(decide(.maximized, .down) == .restore)
        #expect(decide(.maximized, .left) == .snap(.left))
        #expect(decide(.maximized, .right) == .snap(.right))
    }

    @Test func halves() {
        #expect(decide(.arranged(.left), .up) == .snap(.topLeft))
        #expect(decide(.arranged(.left), .down) == .snap(.bottomLeft))
        #expect(decide(.arranged(.left), .right) == .restore)
        #expect(decide(.arranged(.left), .left) == .snapOnNextScreen(.right))
        #expect(decide(.arranged(.right), .up) == .snap(.topRight))
        #expect(decide(.arranged(.right), .down) == .snap(.bottomRight))
        #expect(decide(.arranged(.right), .left) == .restore)
        #expect(decide(.arranged(.right), .right) == .snapOnNextScreen(.left))
    }

    @Test func quarters() {
        #expect(decide(.arranged(.topLeft), .down) == .snap(.left))
        #expect(decide(.arranged(.topLeft), .up) == .snap(.full))
        #expect(decide(.arranged(.topLeft), .right) == .snap(.topRight))
        #expect(decide(.arranged(.topLeft), .left) == .snapOnNextScreen(.topRight))
        #expect(decide(.arranged(.topRight), .down) == .snap(.right))
        #expect(decide(.arranged(.topRight), .left) == .snap(.topLeft))
        #expect(decide(.arranged(.bottomLeft), .up) == .snap(.left))
        #expect(decide(.arranged(.bottomLeft), .down) == .minimize)
        #expect(decide(.arranged(.bottomLeft), .right) == .snap(.bottomRight))
        #expect(decide(.arranged(.bottomRight), .up) == .snap(.right))
        #expect(decide(.arranged(.bottomRight), .left) == .snap(.bottomLeft))
        #expect(decide(.arranged(.bottomRight), .right) == .snapOnNextScreen(.bottomLeft))
    }

    @Test func verticalHalves() {
        #expect(decide(.arranged(.top), .left) == .snap(.topLeft))
        #expect(decide(.arranged(.top), .right) == .snap(.topRight))
        #expect(decide(.arranged(.top), .up) == .snap(.full))
        #expect(decide(.arranged(.top), .down) == .restore)
        #expect(decide(.arranged(.bottom), .up) == .restore)
        #expect(decide(.arranged(.bottom), .down) == .minimize)
        #expect(decide(.arranged(.bottom), .left) == .snap(.bottomLeft))
    }

    @Test func layoutColumnsHalveVertically() {
        let middleThird = Layout.thirds.zones[1]
        #expect(decide(.arranged(middleThird), .up) == .snap(middleThird.topHalf))
        #expect(decide(.arranged(middleThird.topHalf), .down) == .snap(middleThird))
        #expect(decide(.arranged(middleThird), .left) == .snap(.left))
    }

    @Test func zoneFramesTileTheWorkArea() {
        let work = CGRect(x: 0, y: 25, width: 1512, height: 900)
        let l = Zone.left.frame(in: work), r = Zone.right.frame(in: work)
        #expect(l.maxX == r.minX)
        #expect(l.minY == 25 && l.height == 900)
        #expect(Zone.from(frame: Zone.topRight.frame(in: work), in: work) == .topRight)
    }

    @Test func layoutSetFollowsWidth() {
        #expect(Layout.standard(for: CGRect(x: 0, y: 0, width: 1512, height: 945)).count == 4)
        #expect(Layout.standard(for: CGRect(x: 0, y: 0, width: 1920, height: 1050)).count == 6)
        #expect(Layout.standard(for: CGRect(x: 0, y: 0, width: 1080, height: 1890)).first?.zones == [Zone.top, Zone.bottom])
    }
}

@Suite struct CardFlowTests {
    @Test func wrapsAndCentres() {
        let flow = CardFlow.layout(aspects: [1.5, 1.5, 1.5], cardHeight: 140, strip: 40, gap: CGSize(width: 20, height: 20), maxWidth: 340)
        #expect(flow.rowOf == [0, 0, 1])
        #expect(flow.frames[2].midX == flow.size.width / 2)
    }

    @Test func fitShrinksUntilEverythingFits() {
        let aspects = Array(repeating: CGFloat(1.6), count: 12)
        let box = CGSize(width: 1300, height: 700)
        let flow = CardFlow.fit(aspects: aspects, box: box, minHeight: 100, maxHeight: 260, strip: 40, gap: CGSize(width: 26, height: 26))
        #expect(flow.size.width <= box.width && flow.size.height <= box.height)
        #expect(flow.frames.allSatisfy { $0.height > 100 })
    }

    @Test func downWrapsToTopRow() {
        let flow = CardFlow.layout(aspects: [1, 1, 1, 1], cardHeight: 140, strip: 40, gap: CGSize(width: 10, height: 10), maxWidth: 340)
        #expect(flow.neighbour(of: 3, .down) == 1)
        #expect(flow.neighbour(of: 0, .down) == 2)
    }
}

@Suite struct ScalingTests {
    @Test func manyWindowsShrinkTheStripAndStillFit() {
        let box = CGSize(width: 1167, height: 772)
        let few = CardFlow.fit(aspects: Array(repeating: 1.7, count: 4), box: box, minHeight: 98, maxHeight: 261,
                               strip: 40, gap: CGSize(width: 26, height: 26), scaled: true)
        let many = CardFlow.fit(aspects: Array(repeating: 1.7, count: 30), box: box, minHeight: 98, maxHeight: 261,
                                strip: 40, gap: CGSize(width: 26, height: 26), scaled: true)
        #expect(few.strip == 40)
        #expect(many.strip < few.strip)
        #expect(many.fits(box))
        #expect(many.frames[0].height < few.frames[0].height)
    }

    @Test func pastTheFloorTheFlowOverflowsForScrolling() {
        let box = CGSize(width: 1167, height: 772)
        let flow = CardFlow.fit(aspects: Array(repeating: 1.7, count: 200), box: box, minHeight: 98, maxHeight: 261,
                                strip: 40, gap: CGSize(width: 26, height: 26), scaled: true)
        #expect(flow.frames[0].height == 98)
        #expect(flow.size.height > box.height)
    }
}

@Suite struct DragZoneTests {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    var one: [CGRect] { [screen] }

    @Test func edgesAndCorners() {
        #expect(dragZone(cursor: CGPoint(x: 0, y: 500), screen: screen, screens: one) == .left)
        #expect(dragZone(cursor: CGPoint(x: 1511, y: 500), screen: screen, screens: one) == .right)
        #expect(dragZone(cursor: CGPoint(x: 700, y: 0), screen: screen, screens: one) == .full)
        #expect(dragZone(cursor: CGPoint(x: 0, y: 10), screen: screen, screens: one) == .topLeft)
        #expect(dragZone(cursor: CGPoint(x: 10, y: 0), screen: screen, screens: one) == .topLeft)
        #expect(dragZone(cursor: CGPoint(x: 1511, y: 975), screen: screen, screens: one) == .bottomRight)
        #expect(dragZone(cursor: CGPoint(x: 0, y: 975), screen: screen, screens: one) == .bottomLeft)
        #expect(dragZone(cursor: CGPoint(x: 700, y: 500), screen: screen, screens: one) == nil)
        #expect(dragZone(cursor: CGPoint(x: 700, y: 981), screen: screen, screens: one) == nil)
    }

    @Test func sharedEdgeWithAnotherMonitorDoesNotSnap() {
        let second = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        #expect(dragZone(cursor: CGPoint(x: 1511, y: 500), screen: screen, screens: [screen, second]) == nil)
        #expect(dragZone(cursor: CGPoint(x: 0, y: 500), screen: screen, screens: [screen, second]) == .left)
    }

    @Test func dragOutKeepsTheGrabPointUnderThePointer() {
        let snapped = CGRect(x: 0, y: 33, width: 756, height: 890)
        let f = dragOutFrame(current: snapped.offsetBy(dx: 40, dy: 20), restoreSize: CGSize(width: 600, height: 400),
                             grab: CGPoint(x: 378, y: 45), grabbedFrame: snapped, cursor: CGPoint(x: 418, y: 65))
        #expect(f.size == CGSize(width: 600, height: 400))
        #expect(abs((418 - f.minX) / f.width - 0.5) < 0.01)
        #expect(f.minY == 53)
    }
}
