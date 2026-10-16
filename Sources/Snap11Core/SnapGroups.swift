import AppKit

/// Snap groups: windows snapped together by filling a layout. Resizing one member from an
/// edge it shares with another drags that neighbour's edge along, and hovering the shared
/// edge shows Windows' divider handle, which resizes both at once. Moving a member out of
/// place or closing it takes it out; minimizing does not.
@MainActor
final class SnapGroups {
    static let shared = SnapGroups()

    final class Group {
        var members: [AXWindow]
        var frames: [CGWindowID: CGRect]
        let screenID: CGDirectDisplayID

        init(members: [AXWindow], screenID: CGDirectDisplayID) {
            self.members = members
            self.screenID = screenID
            frames = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.frame) })
        }
    }

    private(set) var groups: [Group] = []
    private var observers: [pid_t: AXObserver] = [:]
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
        if observers[w.pid] == nil {
            var obs: AXObserver?
            guard AXObserverCreate(w.pid, { _, element, notification, _ in
                var id: CGWindowID = 0
                _AXUIElementGetWindow(element, &id)
                let name = notification as String
                DispatchQueue.main.async { MainActor.assumeIsolated { SnapGroups.shared.changed(id, name) } }
            }, &obs) == .success, let obs else { return }
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            observers[w.pid] = obs
        }
        guard let obs = observers[w.pid] else { return }
        for n in [kAXResizedNotification, kAXMovedNotification, kAXUIElementDestroyedNotification] {
            AXObserverAddNotification(obs, element, n as CFString, nil)
        }
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

    /// The vertical edge two side-by-side members share, if the pointer is on it.
    private func sharedEdge(at p: CGPoint) -> (Group, left: [AXWindow], right: [AXWindow], x: CGFloat)? {
        for g in groups {
            for a in g.members where !a.isMinimized {
                guard let fa = g.frames[a.id], abs(p.x - fa.maxX) <= 6, p.y > fa.minY, p.y < fa.maxY else { continue }
                let rights = g.members.filter { b in
                    guard b != a, !b.isMinimized, let fb = g.frames[b.id] else { return false }
                    return abs(fb.minX - fa.maxX) <= 3
                }
                guard !rights.isEmpty else { continue }
                let lefts = g.members.filter { b in
                    guard !b.isMinimized, let fb = g.frames[b.id] else { return false }
                    return abs(fb.maxX - fa.maxX) <= 3
                }
                return (g, lefts, rights, fa.maxX)
            }
        }
        return nil
    }

    private func pointerMoved() {
        guard !groups.isEmpty, !divider.dragging else { return }
        let p = Geo.flip(NSEvent.mouseLocation)
        guard let (g, lefts, rights, x) = sharedEdge(at: p),
              WindowList.windowAt(p).map({ hit in g.members.contains { $0.id == hit.id } }) ?? false else {
            divider.hide()
            return
        }
        divider.show(atX: x, y: p.y) { [weak self] newX, done in
            self?.drag(g, lefts: lefts, rights: rights, to: newX, done: done)
        }
    }

    private func drag(_ g: Group, lefts: [AXWindow], rights: [AXWindow], to x: CGFloat, done: Bool) {
        for w in lefts {
            guard var f = g.frames[w.id], x - f.minX > 160 else { return }
            f.size.width = x - f.minX
            settle(w.id)
            w.setFrame(f)
            g.frames[w.id] = f
        }
        for w in rights {
            guard var f = g.frames[w.id], f.maxX - x > 160 else { return }
            f = CGRect(x: x, y: f.minY, width: f.maxX - x, height: f.height)
            settle(w.id)
            w.setFrame(f)
            g.frames[w.id] = f
        }
        if done {
            for w in lefts + rights {
                g.frames[w.id] = w.frame
                SnapEngine.shared.adopt(w)
            }
        }
    }
}

/// Windows 11's divider: a small rounded bar on the line between two snapped windows. Drag
/// it to move the line.
@MainActor
final class DividerHandle {
    private let panel = OverlayPanel(takesKeyboard: false)
    private let view = HandleView()
    private(set) var dragging = false
    private var onDrag: ((CGFloat, Bool) -> Void)?
    private var x: CGFloat = 0

    init() {
        panel.contentView = view
        view.onDrag = { [weak self] dx, done in
            guard let self else { return }
            self.dragging = !done
            let newX = self.x + dx
            self.onDrag?(newX, done)
            var f = self.panel.frame
            f.origin.x = newX - f.width / 2
            self.panel.setFrame(f, display: true)
            if done { self.x = newX }
        }
    }

    func show(atX x: CGFloat, y: CGFloat, onDrag: @escaping (CGFloat, Bool) -> Void) {
        self.x = x
        self.onDrag = onDrag
        let size = CGSize(width: 12, height: 64)
        let frame = Geo.flip(CGRect(x: x - size.width / 2, y: y - size.height / 2, width: size.width, height: size.height))
        panel.appearance = Theme.appearance
        panel.show(frame: frame)
    }

    func hide() {
        if !dragging { panel.hide() }
    }

    final class HandleView: NSView {
        var onDrag: ((CGFloat, Bool) -> Void)?
        private var start: CGFloat = 0

        override func draw(_ dirtyRect: NSRect) {
            let bar = bounds.insetBy(dx: 3, dy: 4)
            (Theme.dark ? NSColor(white: 0.85, alpha: 0.95) : NSColor(white: 0.25, alpha: 0.9)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: bar.width / 2, yRadius: bar.width / 2).fill()
        }

        override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { start = NSEvent.mouseLocation.x }
        override func mouseDragged(with event: NSEvent) { onDrag?(NSEvent.mouseLocation.x - start, false) }
        override func mouseUp(with event: NSEvent) { onDrag?(NSEvent.mouseLocation.x - start, true) }
    }
}
