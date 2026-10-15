import AppKit

/// A snap zone as a fraction of a screen's work area, origin top-left, y down.
struct Zone: Equatable {
    var x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat

    static let full = Zone(x: 0, y: 0, w: 1, h: 1)
    static let left = Zone(x: 0, y: 0, w: 0.5, h: 1)
    static let right = Zone(x: 0.5, y: 0, w: 0.5, h: 1)
    static let top = Zone(x: 0, y: 0, w: 1, h: 0.5)
    static let bottom = Zone(x: 0, y: 0.5, w: 1, h: 0.5)
    static let topLeft = Zone(x: 0, y: 0, w: 0.5, h: 0.5)
    static let topRight = Zone(x: 0.5, y: 0, w: 0.5, h: 0.5)
    static let bottomLeft = Zone(x: 0, y: 0.5, w: 0.5, h: 0.5)
    static let bottomRight = Zone(x: 0.5, y: 0.5, w: 0.5, h: 0.5)

    var maxX: CGFloat { x + w }
    var maxY: CGFloat { y + h }
    var isFullHeight: Bool { y < 0.01 && h > 0.99 }
    var isFullWidth: Bool { x < 0.01 && w > 0.99 }
    var touchesLeft: Bool { x < 0.01 }
    var touchesRight: Bool { maxX > 0.99 }

    static func == (a: Zone, b: Zone) -> Bool {
        abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01 && abs(a.w - b.w) < 0.01 && abs(a.h - b.h) < 0.01
    }

    func frame(in work: CGRect) -> CGRect {
        CGRect(x: (work.minX + x * work.width).rounded(),
               y: (work.minY + y * work.height).rounded(),
               width: (w * work.width).rounded(),
               height: (h * work.height).rounded())
    }

    static func from(frame: CGRect, in work: CGRect) -> Zone {
        Zone(x: (frame.minX - work.minX) / work.width, y: (frame.minY - work.minY) / work.height,
             w: frame.width / work.width, h: frame.height / work.height)
    }

    var topHalf: Zone { Zone(x: x, y: y, w: w, h: h / 2) }
    var bottomHalf: Zone { Zone(x: x, y: y + h / 2, w: w, h: h / 2) }
    var column: Zone { Zone(x: x, y: 0, w: w, h: 1) }

    /// The same zone mirrored left to right, for moving a half or quarter to the other side.
    var mirrored: Zone { Zone(x: 1 - maxX, y: y, w: w, h: h) }
}

/// One entry in the Snap Layouts flyout.
struct Layout {
    var zones: [Zone]
    /// Window ids pre-placed in zones by a suggestion; index 0 is always the target window.
    var suggested: [CGWindowID?] = []

    var isSuggestion: Bool { !suggested.isEmpty }

    static let halves = Layout(zones: [.left, .right])
    static let twoThirds = Layout(zones: [Zone(x: 0, y: 0, w: 2.0 / 3, h: 1), Zone(x: 2.0 / 3, y: 0, w: 1.0 / 3, h: 1)])
    static let thirds = Layout(zones: [Zone(x: 0, y: 0, w: 1.0 / 3, h: 1), Zone(x: 1.0 / 3, y: 0, w: 1.0 / 3, h: 1),
                                       Zone(x: 2.0 / 3, y: 0, w: 1.0 / 3, h: 1)])
    static let halfAndQuarters = Layout(zones: [.left, .topRight, .bottomRight])
    static let quarters = Layout(zones: [.topLeft, .topRight, .bottomLeft, .bottomRight])
    static let quarterHalfQuarter = Layout(zones: [Zone(x: 0, y: 0, w: 0.25, h: 1), Zone(x: 0.25, y: 0, w: 0.5, h: 1),
                                                   Zone(x: 0.75, y: 0, w: 0.25, h: 1)])

    static let portraitHalves = Layout(zones: [.top, .bottom])
    static let portraitTwoThirds = Layout(zones: [Zone(x: 0, y: 0, w: 1, h: 2.0 / 3), Zone(x: 0, y: 2.0 / 3, w: 1, h: 1.0 / 3)])
    static let portraitThirds = Layout(zones: [Zone(x: 0, y: 0, w: 1, h: 1.0 / 3), Zone(x: 0, y: 1.0 / 3, w: 1, h: 1.0 / 3),
                                               Zone(x: 0, y: 2.0 / 3, w: 1, h: 1.0 / 3)])
    static let portraitHalfAndQuarters = Layout(zones: [.top, .bottomLeft, .bottomRight])

    /// Windows shows six layouts once the screen is about 1850 effective pixels wide, four
    /// below that, and stacked layouts on portrait screens.
    static func standard(for work: CGRect) -> [Layout] {
        if work.height > work.width {
            return [.portraitHalves, .portraitTwoThirds, .portraitThirds, .portraitHalfAndQuarters]
        }
        if work.width >= 1850 {
            return [.halves, .twoThirds, .thirds, .halfAndQuarters, .quarters, .quarterHalfQuarter]
        }
        return [.halves, .twoThirds, .halfAndQuarters, .quarters]
    }
}
