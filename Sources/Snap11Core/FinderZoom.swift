import AppKit

/// Explorer's Ctrl+scroll in Finder: extra large icons, large, medium, small, then list, and
/// back. Cmd+scroll steps one stage per notch. A pinch keeps Finder's own smooth icon
/// resizing and adds only the crossing between the smallest icons and list view, which
/// Finder never does. Talks to Finder through its scripting interface.
@MainActor
public final class FinderZoom {
    static let shared = FinderZoom()

    enum Stage: Equatable {
        case icons(Int)
        case list
    }

    static let stages: [Stage] = [.icons(256), .icons(128), .icons(64), .icons(32), .list]

    /// The stage a window is at: list for list, column and gallery views; for icon view,
    /// the stage nearest its icon size.
    public static func stage(view: String, iconSize: Int) -> Int {
        guard view == "icnv" else { return stages.count - 1 }
        let sizes = stages.compactMap { if case let .icons(s) = $0 { return s } else { return nil } }
        return sizes.indices.min { abs(sizes[$0] - iconSize) < abs(sizes[$1] - iconSize) } ?? 0
    }

    private var lastStep = Date.distantPast
    private var pinch: CGFloat = 0
    private var pinchStart: (view: String, size: Int)?

    func start() {
        NSEvent.addGlobalMonitorForEvents(matching: [.magnify]) { [weak self] e in
            let phase = e.phase
            let delta = e.magnification
            MainActor.assumeIsolated { self?.magnify(phase: phase, delta: delta) }
        }
    }

    /// From the Finder key tap: Cmd+scroll. Returns true to swallow the scroll.
    func scroll(deltaY: Double) -> Bool {
        guard Settings.finderZoom, deltaY != 0 else { return false }
        guard Date().timeIntervalSince(lastStep) > 0.12 else { return true }
        lastStep = Date()
        // Scrolling up zooms in, as Ctrl+wheel does in Explorer.
        step(by: deltaY > 0 ? -1 : 1)
        return true
    }

    private func magnify(phase: NSEvent.Phase, delta: CGFloat) {
        guard Settings.finderZoom, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
        if phase.contains(.began) {
            pinch = 0
            pinchStart = Self.read()
            return
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            pinch = 0
            pinchStart = nil
            return
        }
        pinch += delta
        if Hotkeys.debug { NSLog("Snap11: finder pinch %.2f start %@", pinch, pinchStart.map { "\($0.view) \($0.size)" } ?? "none") }
        guard abs(pinch) > 0.25, let start = pinchStart else { return }
        if start.view != "icnv", pinch > 0 {
            Self.apply(.icons(32))
        } else if start.view == "icnv", pinch < 0, let now = Self.read(), now.view == "icnv", now.size <= 20 {
            Self.apply(.list)
        } else {
            return
        }
        pinch = 0
        pinchStart = Self.read()
    }

    private func step(by delta: Int) {
        let read = Self.read()
        if Hotkeys.debug { NSLog("Snap11: finder zoom step %d from %@", delta, read.map { "\($0.view) \($0.size)" } ?? "unreadable") }
        guard let now = read else { return }
        let i = Self.stage(view: now.view, iconSize: now.size)
        let target = Self.stages[min(max(i + delta, 0), Self.stages.count - 1)]
        let current: Stage = now.view == "icnv" ? .icons(now.size) : .list
        if target != current { Self.apply(target) }
    }

    // MARK: Finder

    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("Snap11: finder script failed: %@", error) }
        return result
    }

    /// The front Finder window's view as its four-letter code (icnv, lsvw, clvw, flvw) and
    /// its icon view's icon size.
    public static func read() -> (view: String, size: Int)? {
        guard let r = run("""
            tell application "Finder"
                if (count of Finder windows) is 0 then return {}
                set w to front Finder window
                return {current view of w, icon size of icon view options of w}
            end tell
            """), r.numberOfItems == 2,
            let view = r.atIndex(1)?.enumCodeValue, let size = r.atIndex(2)?.int32Value else { return nil }
        return (fourCC(view), Int(size))
    }

    static func apply(_ stage: Stage) {
        switch stage {
        case let .icons(size):
            _ = run("""
                tell application "Finder"
                    set w to front Finder window
                    set current view of w to icon view
                    set icon size of icon view options of w to \(size)
                end tell
                """)
        case .list:
            _ = run("""
                tell application "Finder" to set current view of front Finder window to list view
                """)
        }
    }

    private static func fourCC(_ code: OSType) -> String {
        String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .ascii) ?? ""
    }
}
