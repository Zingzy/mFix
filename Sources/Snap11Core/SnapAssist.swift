import AppKit

/// The desktop picture behind a screen, for views that hide the windows behind them the way
/// Snap Assist shows bare wallpaper in the empty zone.
@MainActor
enum Wallpaper {
    private static var cache: [CGDirectDisplayID: CGImage] = [:]

    static func image(for screen: NSScreen) -> CGImage? {
        if let c = cache[screen.displayID] { return c }
        let frame = Geo.flip(screen.frame)
        let desktopLevel = Int(CGWindowLevelForKey(.desktopWindow))
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in info where (w[kCGWindowLayer as String] as? Int) == desktopLevel {
            guard let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: b), bounds.isClose(to: frame, tolerance: 2),
                  let image = SkyLight.captureWindow(id) else { continue }
            cache[screen.displayID] = image
            return image
        }
        if let url = NSWorkspace.shared.desktopImageURL(for: screen),
           let image = NSImage(contentsOf: url)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            cache[screen.displayID] = image
            return image
        }
        return nil
    }

    static func invalidate() { cache = [:] }
}

/// Snap Assist: after a window snaps, each empty zone in turn shows cards of the other
/// windows on this Space; picking one snaps it there. Esc or a click elsewhere stops.
@MainActor
final class SnapAssist {
    static let shared = SnapAssist()

    let panel = OverlayPanel(takesKeyboard: true)
    private let content = FlippedView()
    private let ring = SelectionRing()
    private var cards: [WindowCard] = []
    private var flow = CardFlow()
    private var selected = 0

    private var screen: NSScreen?
    private var queue: [Zone] = []
    private var zone: Zone?
    private var placed: Set<CGWindowID> = []
    private var lastPicked: AXWindow?
    private var anchor: AXWindow?
    private var generation = 0
    private(set) var isOpen = false

    private init() {
        content.wantsLayer = true
        panel.onKey = { [weak self] e in self?.key(e) ?? false }
        panel.onResignKey = { [weak self] in
            DispatchQueue.main.async { if self?.isOpen == true && self?.panel.isKeyWindow == false { self?.end() } }
        }
    }

    func begin(after window: AXWindow, zone snapped: Zone, on screen: NSScreen, layout: Layout? = nil) {
        guard Settings.snapAssist else { return }
        if isOpen { end(focusLast: false) }
        let zones = SnapEngine.shared.emptyZones(after: snapped, layout: layout, on: screen, ignoring: [window.id])
        if Hotkeys.debug { NSLog("Snap11: assist zones %d", zones.count) }
        guard !zones.isEmpty else { return }
        self.screen = screen
        queue = zones
        placed = [window.id]
        lastPicked = window
        anchor = window
        isOpen = true
        showNext()
    }

    private func showNext() {
        guard let screen else { end(); return }
        // Re-check each zone; something may have filled it since the queue was built.
        while let next = queue.first {
            queue.removeFirst()
            let still = SnapEngine.shared.emptyZones(after: .full, layout: Layout(zones: [next]), on: screen, ignoring: placed)
            if !still.isEmpty { zone = next; break }
            zone = nil
        }
        guard let zone else { end(); return }
        let candidates = WindowList.currentSpace(excluding: placed)
        guard !candidates.isEmpty else { end(); return }
        build(zone: zone, screen: screen, candidates: candidates)
    }

    func build(zone: Zone, screen: NSScreen, candidates: [AXWindow]) {
        generation += 1
        let work = Geo.workArea(screen)
        let axFrame = zone.frame(in: work)
        let frame = Geo.flip(axFrame)
        let size = frame.size

        let root = BackdropView(frame: NSRect(origin: .zero, size: size))
        root.onClick = { [weak self] in self?.end() }
        root.wantsLayer = true
        root.layer?.masksToBounds = true

        // Bare wallpaper over the windows behind the zone.
        let wall = CALayer()
        wall.contents = Wallpaper.image(for: screen)
        wall.contentsGravity = .resizeAspectFill
        let sf = Geo.flip(screen.frame)
        wall.frame = CGRect(x: sf.minX - axFrame.minX, y: sf.minY - axFrame.minY, width: sf.width, height: sf.height)
        root.layer?.addSublayer(wall)

        let inset: CGFloat = 12
        let pane = NSVisualEffectView(frame: NSRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset))
        pane.material = .hudWindow
        pane.blendingMode = .withinWindow
        pane.state = .active
        pane.appearance = Theme.appearance
        pane.wantsLayer = true
        pane.layer?.cornerRadius = 8
        pane.layer?.cornerCurve = .continuous
        pane.layer?.masksToBounds = true
        pane.layer?.borderWidth = 1
        pane.layer?.borderColor = (Theme.dark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.12)).cgColor
        root.addSubview(pane)

        let strip: CGFloat = 40
        let gap = CGSize(width: 27, height: 30)
        let pad: CGFloat = 28
        let box = CGSize(width: pane.frame.width - pad * 2, height: pane.frame.height - pad * 2)
        let maxHeight = min(screen.frame.height * 0.34, box.height)
        flow = CardFlow.fit(aspects: candidates.map(CardFlow.aspect), box: box, minHeight: min(strip * 2.5, maxHeight),
                            maxHeight: maxHeight, strip: strip, gap: gap)
        let origin = CGPoint(x: pane.frame.minX + (pane.frame.width - flow.size.width) / 2,
                             y: pane.frame.minY + (pane.frame.height - flow.size.height) / 2)

        content.frame = root.bounds
        content.subviews.forEach { $0.removeFromSuperview() }
        content.layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        ring.attach(to: content.layer)
        cards = candidates.enumerated().map { i, w in
            let card = WindowCard(window: w, stripHeight: strip, fontSize: 13)
            card.frame = flow.frames[i].offsetBy(dx: origin.x, dy: origin.y)
            card.onClick = { [weak self] in self?.pick(i) }
            card.onClose = { [weak self] in self?.closeWindow(at: i) }
            card.onHover = { [weak self] in self?.selected = i; self?.updateRing() }
            content.addSubview(card)
            return card
        }
        root.addSubview(content)
        selected = 0
        updateRing()

        panel.contentView = root
        panel.appearance = Theme.appearance
        panel.show(frame: frame)

        let g = generation
        Thumbnails.shared.capture(candidates, points: max(flow.frames.first?.width ?? 300, flow.frames.first?.height ?? 300)) { [weak self] id, image in
            guard let self, self.generation == g else { return }
            self.cards.first(where: { $0.target.id == id })?.setThumbnail(image)
        }
    }

    private func updateRing() {
        ring.move(around: cards.indices.contains(selected) ? cards[selected].frame : nil)
    }

    private func pick(_ i: Int) {
        guard cards.indices.contains(i), let zone, let screen else { return }
        let window = cards[i].target
        if window.isMinimized { window.unminimize() }
        SnapEngine.shared.place(window, zone: zone, on: screen)
        if Settings.snapGroups, let anchor { SnapGroups.shared.join([window], with: anchor, on: screen) }
        placed.insert(window.id)
        lastPicked = window
        window.focus()
        FocusHistory.shared.touch(window.id)
        showNext()
    }

    private func closeWindow(at i: Int) {
        guard cards.indices.contains(i), let zone, let screen else { return }
        cards[i].target.close()
        let remaining = cards.enumerated().filter { $0.offset != i }.map(\.element.target)
        guard !remaining.isEmpty else { end(); return }
        build(zone: zone, screen: screen, candidates: remaining)
    }

    func end(focusLast: Bool = true) {
        guard isOpen else { return }
        isOpen = false
        generation += 1
        queue = []
        zone = nil
        panel.hide()
        cards.forEach { $0.removeFromSuperview() }
        cards = []
        if focusLast { lastPicked?.focus() }
    }

    private func key(_ e: NSEvent) -> Bool {
        switch Int64(e.keyCode) {
        case Key.left: selected = flow.neighbour(of: selected, .left); updateRing()
        case Key.right, Key.tab: selected = flow.neighbour(of: selected, .right); updateRing()
        case Key.up: selected = flow.neighbour(of: selected, .up); updateRing()
        case Key.down: selected = flow.neighbour(of: selected, .down); updateRing()
        case Key.returnKey, Key.enter, 49: pick(selected)
        case Key.escape: end()
        case Key.delete, Key.forwardDelete: closeWindow(at: selected)
        default: return true
        }
        return true
    }
}
