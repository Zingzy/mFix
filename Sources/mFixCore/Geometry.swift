import AppKit

/// Converts between AppKit coordinates (bottom-left origin) and AX/CG coordinates
/// (top-left origin of the primary screen). Both are in points.
enum Geo {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func flip(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x, y: primaryHeight - p.y)
    }

    static var pointer: CGPoint { flip(NSEvent.mouseLocation) }

    /// The screen's usable area (minus menu bar and Dock) in AX coordinates.
    static func workArea(_ screen: NSScreen) -> CGRect { flip(screen.visibleFrame) }

    static func screen(containing axRect: CGRect) -> NSScreen {
        let center = CGPoint(x: axRect.midX, y: axRect.midY)
        if let s = NSScreen.screens.first(where: { $0.axFrame.contains(center) }) { return s }
        return NSScreen.screens.max(by: {
            $0.axFrame.intersection(axRect).area < $1.axFrame.intersection(axRect).area
        }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func screen(at axPoint: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { $0.axFrame.contains(axPoint) })
    }

    static func backingScale(of axRect: CGRect) -> CGFloat {
        NSScreen.screens.first { $0.axFrame.intersects(axRect) }?.backingScaleFactor ?? 2
    }

    /// Screens ordered left to right, for moving windows across monitors.
    static var screensLeftToRight: [NSScreen] {
        NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
    }
}

extension NSScreen {
    var axFrame: CGRect { Geo.flip(frame) }

    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }

    func isClose(to other: CGRect, tolerance: CGFloat = 12) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
