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

    /// The screen's usable area (minus menu bar and Dock) in AX coordinates.
    static func workArea(_ screen: NSScreen) -> CGRect { flip(screen.visibleFrame) }

    static func screen(containing axRect: CGRect) -> NSScreen {
        let center = CGPoint(x: axRect.midX, y: axRect.midY)
        if let s = NSScreen.screens.first(where: { flip($0.frame).contains(center) }) { return s }
        return NSScreen.screens.max(by: {
            flip($0.frame).intersection(axRect).area < flip($1.frame).intersection(axRect).area
        }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    static func screen(at axPoint: CGPoint) -> NSScreen? {
        NSScreen.screens.first(where: { flip($0.frame).contains(axPoint) })
    }

    /// Screens ordered left to right, for moving windows across monitors.
    static var screensLeftToRight: [NSScreen] {
        NSScreen.screens.sorted { $0.frame.minX < $1.frame.minX }
    }
}

extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }

    func isClose(to other: CGRect, tolerance: CGFloat = 12) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }
}
