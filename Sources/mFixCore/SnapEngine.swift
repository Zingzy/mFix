import AppKit
import Carbon.HIToolbox

/// Windows 11 keyboard snapping. A window is restored, maximized, minimized or arranged in a
/// zone; one restore frame per window survives every trip through arranged and maximized.
@MainActor
final class SnapEngine {
    static let shared = SnapEngine()

    private struct Record {
        var restore: CGRect
        var lastSet: CGRect
        var zone: Zone
        var screenID: CGDirectDisplayID
        var window: AXWindow
    }

    private var records: [CGWindowID: Record] = [:]
    private var lastMinimized: AXWindow?

    // MARK: State

    func state(of window: AXWindow) -> (SnapState, NSScreen) {
        let frame = window.frame
        let screen = Geo.screen(containing: frame)
        let work = Geo.workArea(screen)
        if let r = records[window.id], r.lastSet.isClose(to: frame) {
            return (r.zone == .full ? .maximized : .arranged(r.zone), screen)
        }
        if frame.isClose(to: work) { return (.maximized, screen) }
        let known: [Zone] = [.left, .right, .top, .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight]
            + Layout.thirds.zones + Layout.twoThirds.zones
        if let k = known.first(where: { $0.frame(in: work).isClose(to: frame) }) {
            return (.arranged(k), screen)
        }
        return (.restored, screen)
    }

    // MARK: Actions

    func place(_ window: AXWindow, zone: Zone, on screen: NSScreen) {
        let frame = window.frame
        let previous = records[window.id]
        let restore: CGRect
        if let previous, previous.lastSet.isClose(to: frame) {
            restore = previous.restore
        } else if case .maximized = state(of: window).0, let previous {
            restore = previous.restore
        } else {
            restore = frame
        }
        let work = Geo.workArea(screen)
        let target = zone.frame(in: work)
        // Snapping a member somewhere else takes it out of its group; Snap Assist and
        // suggested layouts put it back in right after.
        SnapGroups.shared.leave(window)
        SnapGroups.shared.settle(window.id)
        window.setFrame(target)
        var actual = window.frame
        if !work.contains(actual) && actual.width <= work.width && actual.height <= work.height {
            // The app kept a bigger minimum size than the zone; keep it on screen.
            actual.origin.x = min(max(actual.minX, work.minX), work.maxX - actual.width)
            actual.origin.y = min(max(actual.minY, work.minY), work.maxY - actual.height)
            window.setFrame(actual)
            actual = window.frame
        }
        records[window.id] = Record(restore: restore, lastSet: actual, zone: zone, screenID: screen.displayID, window: window)
    }

    func restore(_ window: AXWindow) {
        SnapGroups.shared.leave(window)
        guard let r = records.removeValue(forKey: window.id) else { return }
        var target = r.restore
        let screen = Geo.screen(containing: window.frame)
        let work = Geo.workArea(screen)
        if !Geo.workArea(Geo.screen(containing: target)).intersects(work) || Geo.screen(containing: target) != screen {
            // The window crossed monitors while snapped: keep the restore size, centre it here.
            target.origin = CGPoint(x: work.midX - target.width / 2, y: work.midY - target.height / 2)
        }
        window.setFrame(target)
    }

    func minimize(_ window: AXWindow) {
        lastMinimized = window
        window.minimize()
    }

    /// Windows mFix snapped on a screen, at the frames it last put them at. Cheap: no app
    /// is asked, so the divider can look on every pointer move.
    func snapped(on screen: NSScreen) -> [(window: AXWindow, frame: CGRect)] {
        records.values.filter { $0.screenID == screen.displayID && $0.zone != .full }.map { ($0.window, $0.lastSet) }
    }

    /// A snapped window resized in place (its group's divider, or its edge): it stays
    /// arranged at its new size and keeps its restore frame.
    func adopt(_ window: AXWindow) {
        guard var r = records[window.id] else { return }
        let frame = window.frame
        let screen = Geo.screen(containing: frame)
        r.lastSet = frame
        r.zone = Zone.from(frame: frame, in: Geo.workArea(screen))
        records[window.id] = r
    }

    /// Dragging a snapped or maximized window out of place: hands back its restore frame and
    /// forgets the snap, if mFix put it at `frame`.
    func takeRestoreFrame(for window: AXWindow, snappedAt frame: CGRect) -> CGRect? {
        guard let r = records[window.id], r.lastSet.isClose(to: frame, tolerance: 2) else { return nil }
        records[window.id] = nil
        SnapGroups.shared.leave(window)
        return r.restore
    }

    // MARK: Win+Arrow

    /// Returns the zone the window landed in, so the caller can offer Snap Assist.
    @discardableResult
    func handle(_ arrow: Arrow, window target: AXWindow? = nil) -> (AXWindow, Zone, NSScreen)? {
        guard let window = target ?? AXWindow.focused(), window.isStandard || window.subrole == "AXDialog" else {
            if arrow == .up, let w = lastMinimized, w.isMinimized { w.focus(); lastMinimized = nil }
            return nil
        }
        if window.isFullScreen { return nil }
        let (state, screen) = self.state(of: window)
        FocusHistory.shared.touch(window.id)

        switch decide(state, arrow) {
        case let .snap(zone):
            place(window, zone: zone, on: screen)
            return zone == .full ? nil : (window, zone, screen)
        case let .snapOnNextScreen(zone):
            guard let next = adjacentScreen(of: screen, towardLeft: arrow == .left) else { return nil }
            place(window, zone: zone, on: next)
            return (window, zone, next)
        case .restore:
            restore(window)
        case .minimize:
            minimize(window)
        case .none:
            break
        }
        return nil
    }

    private func adjacentScreen(of screen: NSScreen, towardLeft: Bool) -> NSScreen? {
        let screens = Geo.screensLeftToRight
        guard let i = screens.firstIndex(of: screen) else { return nil }
        let j = towardLeft ? i - 1 : i + 1
        return screens.indices.contains(j) ? screens[j] : nil
    }

    // MARK: Win+Shift and Win+Alt

    func snapVertical(top: Bool) -> (AXWindow, Zone, NSScreen)? {
        guard let window = AXWindow.focused(), !window.isFullScreen else { return nil }
        let screen = Geo.screen(containing: window.frame)
        let zone: Zone = top ? .top : .bottom
        place(window, zone: zone, on: screen)
        return (window, zone, screen)
    }

    func moveToScreen(towardLeft: Bool) {
        guard let window = AXWindow.focused(), !window.isFullScreen else { return }
        let (state, screen) = self.state(of: window)
        guard let next = adjacentScreen(of: screen, towardLeft: towardLeft) else { return }
        switch state {
        case .maximized: place(window, zone: .full, on: next)
        case let .arranged(z): place(window, zone: z, on: next)
        case .restored:
            let from = Geo.workArea(screen), to = Geo.workArea(next)
            let f = window.frame
            let rx = (f.minX - from.minX) / max(from.width - f.width, 1)
            let ry = (f.minY - from.minY) / max(from.height - f.height, 1)
            let size = CGSize(width: min(f.width, to.width), height: min(f.height, to.height))
            window.setFrame(CGRect(x: to.minX + rx * (to.width - size.width),
                                   y: to.minY + ry * (to.height - size.height), width: size.width, height: size.height))
        }
    }

    func stretchVertically() {
        guard let window = AXWindow.focused(), !window.isFullScreen else { return }
        let f = window.frame
        let work = Geo.workArea(Geo.screen(containing: f))
        let zone = Zone.from(frame: CGRect(x: f.minX, y: work.minY, width: f.width, height: work.height), in: work)
        place(window, zone: zone, on: Geo.screen(containing: f))
    }

    func restoreFocused() {
        guard let window = AXWindow.focused() else { return }
        if case .restored = state(of: window).0 { return }
        restore(window)
    }

    // MARK: Occupancy, for Snap Assist

    /// Zones still empty on `screen` once `zone` holds a window, in the order Snap Assist
    /// should fill them.
    func emptyZones(after zone: Zone, layout: Layout?, on screen: NSScreen, ignoring: Set<CGWindowID>) -> [Zone] {
        let candidates: [Zone]
        if let layout {
            candidates = layout.zones.filter { $0 != zone }
        } else if zone == .left || zone == .right || zone == .top || zone == .bottom {
            candidates = [zone == .left ? .right : zone == .right ? .left : zone == .top ? .bottom : .top]
        } else if abs(zone.w - 0.5) < 0.01 && abs(zone.h - 0.5) < 0.01 {
            let partner = Zone(x: zone.x, y: zone.y < 0.01 ? 0.5 : 0, w: 0.5, h: 0.5)
            let others = Layout.quarters.zones.filter { $0 != zone && $0 != partner }
            candidates = [partner] + others
        } else {
            candidates = []
        }
        let work = Geo.workArea(screen)
        let arranged = arrangedFrames(on: screen, ignoring: ignoring)
        return candidates.filter { z in
            let f = z.frame(in: work)
            let covered = arranged.reduce(CGFloat(0)) { $0 + $1.intersection(f).area }
            return covered < f.area * 0.6
        }
    }

    private func arrangedFrames(on screen: NSScreen, ignoring: Set<CGWindowID>) -> [CGRect] {
        let work = Geo.workArea(screen)
        var frames: [CGRect] = []
        let knownZones = [Zone.left, .right, .top, .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight]
            + Layout.thirds.zones + Layout.twoThirds.zones + Layout.quarterHalfQuarter.zones
        for w in WindowInfo.onScreen where w.layer == 0 && !ignoring.contains(w.id) {
            if let r = records[w.id], r.lastSet.isClose(to: w.bounds), r.zone != .full {
                frames.append(w.bounds)
            } else if knownZones.contains(where: { $0.frame(in: work).isClose(to: w.bounds) }) {
                frames.append(w.bounds)
            }
        }
        return frames
    }
}

extension SnapEngine: Feature {
    func hotkeys(win: Int) -> [Hotkey] {
        let arrows: [(Int64, Arrow)] = [(Key.left, .left), (Key.right, .right), (Key.up, .up), (Key.down, .down)]
        return arrows.map { code, arrow in
            Hotkey(code, win) {
                SnapAssist.shared.end(focusLast: false)
                LayoutFlyout.shared.close()
                SnapAssist.shared.pending = self.handle(arrow)
            }
        } + [
            Hotkey(Key.up, Hotkey.winAlt) { SnapAssist.shared.pending = self.snapVertical(top: true) },
            Hotkey(Key.down, Hotkey.winAlt) { SnapAssist.shared.pending = self.snapVertical(top: false) },
            Hotkey(Key.left, win | shiftKey) { self.moveToScreen(towardLeft: true) },
            Hotkey(Key.right, win | shiftKey) { self.moveToScreen(towardLeft: false) },
            Hotkey(Key.up, win | shiftKey) { self.stretchVertically() },
            Hotkey(Key.down, win | shiftKey) { self.restoreFocused() },
        ]
    }
}
