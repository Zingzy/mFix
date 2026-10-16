import AppKit

/// Snap groups: windows snapped together by filling a layout. Resizing one member from an
/// edge it shares with another drags that neighbour's edge along, and hovering the shared
/// edge shows Windows' divider handle, which resizes both at once. Moving a member out of
/// place or closing it takes it out; minimizing does not.
@MainActor
final class SnapGroups: Feature {
    static let shared = SnapGroups()

    final class Group {
        var members: [AXWindow]
        var frames: [CGWindowID: CGRect]
        let screenID: CGDirectDisplayID

        var screen: NSScreen { NSScreen.screens.first { $0.displayID == screenID } ?? NSScreen.screens[0] }

        init(members: [AXWindow], screenID: CGDirectDisplayID) {
            self.members = members
            self.screenID = screenID
            frames = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.frame) })
        }
    }

    private(set) var groups: [Group] = []
    private var watchers: [pid_t: AXWatcher] = [:]
    /// Frames Snap11 itself just set; their move and resize notifications are ignored.
    private var settling: [CGWindowID: Date] = [:]
    private let divider = DividerHandle()

    func start() {
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
    }

    func group(containing id: CGWindowID) -> Group? {
        groups.first { g in g.members.contains { $0.id == id } }
    }

    /// Adds windows to the group of `anchor`, or starts one.
    func join(_ windows: [AXWindow], with anchor: AXWindow, on screen: NSScreen) {
        if let g = group(containing: anchor.id) {
            for w in windows where !g.members.contains(w) {
                for other in groups where other !== g { other.members.removeAll { $0 == w } }
                g.members.append(w)
                g.frames[w.id] = w.frame
                watch(w)
            }
        } else {
            for w in [anchor] + windows { for other in groups { other.members.removeAll { $0 == w } } }
            let g = Group(members: [anchor] + windows, screenID: screen.displayID)
            groups.append(g)
            g.members.forEach(watch)
        }
        groups.removeAll { $0.members.count < 2 }
    }

    func leave(_ w: AXWindow) {
        for g in groups { g.members.removeAll { $0 == w }; g.frames[w.id] = nil }
        groups.removeAll { $0.members.count < 2 }
    }

    /// Snap11 is about to set this window's frame; don't treat it as the person resizing.
    func settle(_ id: CGWindowID) { settling[id] = Date() }

    // MARK: Following resizes

    private func watch(_ w: AXWindow) {
        guard let element = w.element else { return }
        if watchers[w.pid] == nil {
            watchers[w.pid] = AXWatcher(pid: w.pid) { id, name in onMain { SnapGroups.shared.changed(id, name) } }
        }
        watchers[w.pid]?.watch(element, [kAXResizedNotification, kAXMovedNotification, kAXUIElementDestroyedNotification])
    }

    private func changed(_ id: CGWindowID, _ notification: String) {
        guard let g = group(containing: id), let w = g.members.first(where: { $0.id == id }) else { return }
        if notification == kAXUIElementDestroyedNotification as String {
            leave(w)
            return
        }
        if let t = settling[id], Date().timeIntervalSince(t) < 0.4 {
            g.frames[id] = w.frame
            return
        }
        guard let old = g.frames[id] else { return }
        let new = w.frame
        if w.isMinimized { return }
        if new.size == old.size {
            // A move, not a resize: it left its place in the group.
            if new.origin != old.origin { leave(w) }
            return
        }
        g.frames[id] = new
        follow(g, resized: w, from: old, to: new)
    }

    /// Every member that shared a moved edge of `w` has that edge moved with it.
    private func follow(_ g: Group, resized w: AXWindow, from old: CGRect, to new: CGRect) {
        for other in g.members where other != w && !other.isMinimized {
            guard var f = g.frames[other.id] else { continue }
            let tol: CGFloat = 3
            let overlapsY = f.minY < old.maxY - tol && f.maxY > old.minY + tol
            let overlapsX = f.minX < old.maxX - tol && f.maxX > old.minX + tol
            var moved = false
            if overlapsY, abs(f.minX - old.maxX) <= tol, old.maxX != new.maxX {
                f = CGRect(x: new.maxX, y: f.minY, width: f.maxX - new.maxX, height: f.height); moved = true
            } else if overlapsY, abs(f.maxX - old.minX) <= tol, old.minX != new.minX {
                f = CGRect(x: f.minX, y: f.minY, width: new.minX - f.minX, height: f.height); moved = true
            }
            if overlapsX, abs(f.minY - old.maxY) <= tol, old.maxY != new.maxY {
                f = CGRect(x: f.minX, y: new.maxY, width: f.width, height: f.maxY - new.maxY); moved = true
            } else if overlapsX, abs(f.maxY - old.minY) <= tol, old.minY != new.minY {
                f = CGRect(x: f.minX, y: f.minY, width: f.width, height: new.minY - f.minY); moved = true
            }
            guard moved, f.width > 120, f.height > 80 else { continue }
            settle(other.id)
            other.setFrame(f)
            g.frames[other.id] = other.frame
            SnapEngine.shared.adopt(other)
        }
        SnapEngine.shared.adopt(w)
    }

    // MARK: The divider handle

    /// A line two or more snapped windows share, vertical (side by side) or horizontal (one
    /// above another), if the pointer is on it. Any snapped windows that touch count, grouped or
    /// not, as on Windows. `before` are the windows left of or above it. Apps that size in
    /// steps (a terminal's whole character cells) leave a gap, so touching allows 12 pt.
    private struct Edge {
        let vertical: Bool
        let at: CGFloat
        let before: [(window: AXWindow, frame: CGRect)]
        let after: [(window: AXWindow, frame: CGRect)]
    }

    private static let touch: CGFloat = 12

    private func sharedEdge(at p: CGPoint) -> Edge? {
        guard let screen = Geo.screen(at: p) else { return nil }
        let live = SnapEngine.shared.snapped(on: screen).filter { !$0.window.isMinimized }
        for a in live {
            let fa = a.frame
            for vertical in [true, false] {
                let line = vertical ? fa.maxX : fa.maxY
                let after = live.filter { b in
                    b.window != a.window && abs((vertical ? b.frame.minX : b.frame.minY) - line) <= Self.touch
                }
                // Something must actually sit across the line from the window under the pointer.
                guard after.contains(where: { b in vertical ? (b.frame.minY < fa.maxY && b.frame.maxY > fa.minY)
                                                            : (b.frame.minX < fa.maxX && b.frame.maxX > fa.minX) }) else { continue }
                guard let far = after.map({ vertical ? $0.frame.minX : $0.frame.minY }).max() else { continue }
                let inGap = vertical ? p.x >= line - 6 && p.x <= far + 6 && p.y > fa.minY && p.y < fa.maxY
                                     : p.y >= line - 6 && p.y <= far + 6 && p.x > fa.minX && p.x < fa.maxX
                guard inGap else { continue }
                let before = live.filter { abs((vertical ? $0.frame.maxX : $0.frame.maxY) - line) <= Self.touch }
                return Edge(vertical: vertical, at: (line + far) / 2, before: before, after: after)
            }
        }
        return nil
    }

    /// For the divider check: drag whatever line passes through `p` to `line`, as the handle does.
    @discardableResult
    func dragLine(at p: CGPoint, to line: CGFloat) -> Bool {
        guard let edge = sharedEdge(at: p) else { return false }
        drag(edge, to: line, done: true)
        return true
    }

    private func pointerMoved() {
        guard !divider.dragging else { return }
        let p = Geo.pointer
        guard let edge = sharedEdge(at: p) else {
            divider.hide()
            return
        }
        divider.show(vertical: edge.vertical, at: edge.at, along: edge.vertical ? p.y : p.x) { [weak self] moved, done in
            self?.drag(edge, to: moved, done: done)
        }
    }

    /// The windows on each side keep their far edges; their shared edges meet at `line`.
    private func drag(_ edge: Edge, to line: CGFloat, done: Bool) {
        let minimum: CGFloat = edge.vertical ? 160 : 120
        for w in edge.before where line - (edge.vertical ? w.frame.minX : w.frame.minY) <= minimum { return }
        for w in edge.after where (edge.vertical ? w.frame.maxX : w.frame.maxY) - line <= minimum { return }
        for w in edge.before {
            var f = w.frame
            if edge.vertical { f.size.width = line - f.minX } else { f.size.height = line - f.minY }
            settle(w.window.id)
            w.window.setFrame(f)
        }
        for w in edge.after {
            let f = w.frame
            settle(w.window.id)
            w.window.setFrame(edge.vertical ? CGRect(x: line, y: f.minY, width: f.maxX - line, height: f.height)
                                            : CGRect(x: f.minX, y: line, width: f.width, height: f.maxY - line))
        }
        if done {
            for w in edge.before + edge.after {
                SnapEngine.shared.adopt(w.window)
                if let g = group(containing: w.window.id) { g.frames[w.window.id] = w.window.frame }
            }
        }
    }
}

/// Windows 11's divider: a small rounded bar on the line between two snapped windows, upright
/// on a line between windows side by side and lying flat on one between windows stacked.
/// Drag it to move the line.
@MainActor
final class DividerHandle {
    private let panel = OverlayPanel()
    private let view = HandleView()
    private(set) var dragging = false
    private var onDrag: ((CGFloat, Bool) -> Void)?
    private var at: CGFloat = 0
    private var vertical = true

    init() {
        panel.contentView = view
        view.onDrag = { [weak self] delta, done in
            guard let self else { return }
            self.dragging = !done
            // AppKit's y grows up and AX's grows down.
            let moved = self.at + (self.vertical ? delta.x : -delta.y)
            self.onDrag?(moved, done)
            var f = self.panel.frame
            if self.vertical { f.origin.x = moved - f.width / 2 } else { f.origin.y = Geo.flip(CGPoint(x: 0, y: moved)).y - f.height / 2 }
            self.panel.setFrame(f, display: true)
            if done { self.at = moved }
        }
    }

    func show(vertical: Bool, at line: CGFloat, along: CGFloat, onDrag: @escaping (CGFloat, Bool) -> Void) {
        self.at = line
        self.vertical = vertical
        self.onDrag = onDrag
        view.vertical = vertical
        let size = vertical ? CGSize(width: 12, height: 64) : CGSize(width: 64, height: 12)
        let center = vertical ? CGPoint(x: line, y: along) : CGPoint(x: along, y: line)
        let frame = Geo.flip(CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height))
        panel.appearance = Theme.appearance
        panel.show(frame: frame)
        view.needsDisplay = true
        panel.invalidateCursorRects(for: view)
    }

    func hide() {
        if !dragging { panel.hide() }
    }

    final class HandleView: NSView {
        var onDrag: ((CGPoint, Bool) -> Void)?
        var vertical = true
        private var start: CGPoint = .zero

        override func draw(_ dirtyRect: NSRect) {
            let bar = vertical ? bounds.insetBy(dx: 3, dy: 4) : bounds.insetBy(dx: 4, dy: 3)
            let r = min(bar.width, bar.height) / 2
            (Theme.dark ? NSColor(white: 0.85, alpha: 0.95) : NSColor(white: 0.25, alpha: 0.9)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: r, yRadius: r).fill()
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: vertical ? .resizeLeftRight : .resizeUpDown) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { start = NSEvent.mouseLocation }
        override func mouseDragged(with event: NSEvent) { onDrag?(delta, false) }
        override func mouseUp(with event: NSEvent) { onDrag?(delta, true) }

        private var delta: CGPoint {
            let p = NSEvent.mouseLocation
            return CGPoint(x: p.x - start.x, y: p.y - start.y)
        }
    }
}
