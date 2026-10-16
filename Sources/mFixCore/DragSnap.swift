import AppKit

/// Which zone a window dragged with the pointer at `cursor` would snap to: a side edge gives
/// a half, a corner a quarter, the top edge maximizes. The pointer itself has to reach the
/// edge, as on Windows. Edges shared with another monitor don't count, so a window can still
/// be dragged across. All rects in AX coordinates.
func dragZone(cursor p: CGPoint, screen s: CGRect, screens: [CGRect], margin: CGFloat = 5, corner: CGFloat = 30) -> Zone? {
    func open(_ q: CGPoint) -> Bool { !screens.contains { $0.contains(q) } }
    let left = p.x <= s.minX + margin && open(CGPoint(x: s.minX - 1, y: p.y))
    let right = p.x >= s.maxX - 1 - margin && open(CGPoint(x: s.maxX + 1, y: p.y))
    let top = p.y <= s.minY + margin && open(CGPoint(x: p.x, y: s.minY - 1))
    let nearTop = p.y <= s.minY + corner
    let nearBottom = p.y >= s.maxY - 1 - corner
    let nearLeft = p.x <= s.minX + corner
    let nearRight = p.x >= s.maxX - 1 - corner

    if left { return nearTop ? .topLeft : nearBottom ? .bottomLeft : .left }
    if right { return nearTop ? .topRight : nearBottom ? .bottomRight : .right }
    if top { return nearLeft ? .topLeft : nearRight ? .topRight : .full }
    return nil
}

/// Where a snapped window goes when dragged out: back to its restore size, with the grab
/// point at the same fraction along the title bar, so the pointer stays on the window.
func dragOutFrame(current: CGRect, restoreSize: CGSize, grab: CGPoint, grabbedFrame: CGRect, cursor: CGPoint) -> CGRect {
    let fraction = grabbedFrame.width > 0 ? (grab.x - grabbedFrame.minX) / grabbedFrame.width : 0.5
    let x = cursor.x - fraction * restoreSize.width
    return CGRect(x: x.rounded(), y: current.minY, width: restoreSize.width, height: restoreSize.height)
}

/// Drag-to-snap: watches title-bar drags of other apps' windows through passive mouse
/// monitors, shows the frosted preview while the pointer sits on an edge or corner, and
/// snaps on release. Esc during the drag cancels.
@MainActor
final class DragSnap: Feature {
    static let shared = DragSnap()

    private let preview = OverlayPanel(level: .normal, clickThrough: true)
    private var wid: CGWindowID = 0
    private var pid: pid_t = 0
    private var window: AXWindow?
    private var grabFrame: CGRect = .zero
    private var grabPoint: CGPoint = .zero
    private var moving = false
    private var cancelled = false
    private var zone: Zone?
    private var zoneScreen: NSScreen?

    private init() {
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glass.wantsLayer = true
        glass.layer?.cornerRadius = 8
        glass.layer?.cornerCurve = .continuous
        glass.layer?.masksToBounds = true
        glass.layer?.borderWidth = 1
        glass.layer?.borderColor = NSColor(white: 1, alpha: 0.22).cgColor
        glass.layer?.backgroundColor = NSColor(white: 1, alpha: 0.08).cgColor
        preview.contentView = glass
    }

    private var tap: ListenTap?

    func start() {
        tap = ListenTap([.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown]) { [weak self] type, event in
            let location = event.location
            let target = CGWindowID(clamping: event.getIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent))
            let key = event.getIntegerValueField(.keyboardEventKeycode)
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .leftMouseDown: self.begin(at: location, target: target)
                case .leftMouseDragged: self.dragged(to: location)
                case .leftMouseUp: self.released(at: location)
                case .keyDown where key == Key.escape && self.moving:
                    self.cancelled = true
                    self.hidePreview()
                default: break
                }
            }
        }
    }

    private func begin(at location: CGPoint, target: CGWindowID) {
        reset()
        guard Settings.dragSnap.value else { return }
        var id = target
        if id == 0 { id = WindowList.windowAt(location)?.id ?? 0 }
        if Hotkeys.debug { NSLog("mFix: drag mouseDown at %@ window %u", NSStringFromPoint(location), id) }
        guard id != 0, let info = WindowInfo.list(.optionIncludingWindow, relativeTo: id).first,
              info.pid != ProcessInfo.processInfo.processIdentifier, info.layer == 0 else { return }
        wid = id
        pid = info.pid
        grabFrame = info.bounds
        grabPoint = location
    }

    private func dragged(to cursor: CGPoint) {
        guard wid != 0, !cancelled else { return }
        if !moving {
            guard let now = WindowInfo.list(.optionIncludingWindow, relativeTo: wid).first?.bounds else { return }
            if Hotkeys.debug { NSLog("mFix: drag event, window now %@ grabbed %@", NSStringFromRect(now), NSStringFromRect(grabFrame)) }
            if now.size != grabFrame.size {
                wid = 0
                return
            }
            guard now.origin != grabFrame.origin else { return }
            guard let w = AXWindow.windows(of: pid).first(where: { $0.id == wid }), w.isStandard, !w.isFullScreen else {
                wid = 0
                return
            }
            window = w
            moving = true
            if Hotkeys.debug { NSLog("mFix: drag moving window %u", wid) }
            SnapAssist.shared.end(focusLast: false)
            LayoutFlyout.shared.close()
            if let restore = SnapEngine.shared.takeRestoreFrame(for: w, snappedAt: grabFrame) {
                w.setFrame(dragOutFrame(current: now, restoreSize: restore.size, grab: grabPoint, grabbedFrame: grabFrame, cursor: cursor))
            }
        }
        update(cursor)
    }

    private func update(_ cursor: CGPoint) {
        guard let screen = Geo.screen(at: cursor) ?? NSScreen.screens.first(where: { $0.axFrame.insetBy(dx: -1, dy: -1).contains(cursor) })
        else { hidePreview(); return }
        let next = dragZone(cursor: cursor, screen: screen.axFrame, screens: NSScreen.screens.map(\.axFrame))
        guard next != zone || screen != zoneScreen else { return }
        zone = next
        zoneScreen = screen
        guard let next else { hidePreview(); return }
        showPreview(Geo.flip(next.frame(in: Geo.workArea(screen))).insetBy(dx: 8, dy: 8))
    }

    private func released(at cursor: CGPoint) {
        defer { reset() }
        guard moving, !cancelled, let window else { return }
        update(cursor)
        guard let zone, let screen = zoneScreen else { return }
        hidePreview()
        // The app finishes its own drag after mouse-up; snap once it has let go of the window.
        onMain(after: 0.05) {
            SnapEngine.shared.place(window, zone: zone, on: screen)
            if zone != .full { SnapAssist.shared.begin(after: window, zone: zone, on: screen) }
        }
    }

    private func showPreview(_ frame: NSRect) {
        preview.appearance = Theme.appearance
        preview.setFrame(frame, display: true)
        if !preview.isVisible {
            preview.alphaValue = 1
            preview.order(.below, relativeTo: Int(wid))
        }
    }

    private func hidePreview() {
        zone = nil
        zoneScreen = nil
        preview.orderOut(nil)
    }

    private func reset() {
        if preview.isVisible { hidePreview() }
        wid = 0
        pid = 0
        window = nil
        moving = false
        cancelled = false
        zone = nil
        zoneScreen = nil
    }
}
