import AppKit

/// A blurred, tinted panel background with smooth corners. A 9-slice mask instead of a
/// layer corner radius, which aliases on NSVisualEffectView.
@MainActor
func acrylicView(radius: CGFloat) -> NSVisualEffectView {
    let v = NSVisualEffectView()
    v.material = .hudWindow
    v.blendingMode = .behindWindow
    v.state = .active
    v.appearance = Theme.appearance
    let edge = radius * 2 + 1
    let mask = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
        NSColor.black.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        return true
    }
    mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    mask.resizingMode = .stretch
    v.maskImage = mask
    return v
}

/// The Windows 11 Alt+Tab switcher on Cmd+Tab: one centred acrylic panel of window cards in
/// most-recently-used order. Holding Cmd keeps it open, releasing Cmd switches.
@MainActor
final class Switcher {
    static let shared = Switcher()


    let panel = OverlayPanel(takesKeyboard: true)
    private var background: NSVisualEffectView?
    private let content = FlippedView()
    private let ring = SelectionRing()
    private let scroll: NSScrollView = {
        let s = NSScrollView()
        s.drawsBackground = false
        s.hasVerticalScroller = true
        s.scrollerStyle = .overlay
        s.autohidesScrollers = true
        s.verticalScrollElasticity = .none
        return s
    }()

    var windows: [AXWindow] = []
    /// A snap group stands in the list as its most recent member; this maps that member to
    /// the group, whose other members are left out of the list.
    private var groupOf: [CGWindowID: SnapGroups.Group] = [:]
    private var cards: [WindowCard] = []
    private var flow = CardFlow()
    private var selected = 0
    private var sticky = false
    private var showTimer: Timer?
    private var dragHoverTimer: Timer?
    private var dragHoverIndex: Int?
    private var generation = 0
    private let live = LiveThumbnails()
    private(set) var isOpen = false

    private init() {
        content.wantsLayer = true
        ring.attach(to: content.layer)
        panel.onKey = { [weak self] e in self?.key(e) ?? false }
        panel.onResignKey = { [weak self] in
            DispatchQueue.main.async { if self?.isOpen == true && self?.panel.isKeyWindow == false { self?.cancel() } }
        }
    }

    // MARK: Opening and stepping

    func step(backward: Bool, sticky: Bool = false) {
        if isOpen {
            move(backward ? -1 : 1)
            return
        }
        windows = collapseGroups(Settings.allSpaces ? WindowList.allSpaces() : WindowList.currentSpace())
        if Hotkeys.debug { NSLog("Snap11: switcher windows %d", windows.count) }
        guard !windows.isEmpty else { return }
        isOpen = true
        // Mid-drag the panel must not take the keyboard, or the drag can drop out from under
        // the pointer; Tab still steps through the hotkey and Cmd-up still commits.
        let dragging = DragDrop.shared.isDragging
        panel.takesKeyboard = !dragging
        panel.becomesKeyOnlyIfNeeded = dragging
        self.sticky = sticky
        generation += 1
        selected = windows.count > 1 ? (backward ? windows.count - 1 : 1) : 0
        if sticky || Settings.showDelay <= 0 {
            show()
        } else {
            let g = generation
            showTimer = Timer.scheduledTimer(withTimeInterval: Settings.showDelay, repeats: false) { _ in
                MainActor.assumeIsolated { if self.generation == g && self.isOpen { self.show() } }
            }
        }
    }

    /// Cmd went up: switch to the selection, unless the switcher was opened sticky.
    func modifiersReleased() {
        guard isOpen, !sticky else { return }
        commit()
    }

    private func collapseGroups(_ list: [AXWindow]) -> [AXWindow] {
        groupOf = [:]
        guard Settings.snapGroups else { return list }
        let present = Set(list.filter { !$0.isMinimized }.map(\.id))
        var seen: [ObjectIdentifier] = []
        var out: [AXWindow] = []
        for w in list {
            guard let g = SnapGroups.shared.group(containing: w.id), g.members.allSatisfy({ present.contains($0.id) }) else {
                out.append(w)
                continue
            }
            if seen.contains(ObjectIdentifier(g)) { continue }
            seen.append(ObjectIdentifier(g))
            groupOf[w.id] = g
            out.append(w)
        }
        return out
    }

    private func screenAspect(_ g: SnapGroups.Group) -> CGFloat {
        let s = NSScreen.screens.first { $0.displayID == g.screenID } ?? NSScreen.screens[0]
        return s.frame.width / s.frame.height
    }

    private func move(_ delta: Int) {
        guard !windows.isEmpty else { return }
        selected = (selected + delta + windows.count) % windows.count
        updateRing()
    }

    // MARK: Building the panel

    func show() {
        let screen = Geo.screen(at: Geo.flip(NSEvent.mouseLocation)) ?? NSScreen.main ?? NSScreen.screens[0]
        let sf = screen.frame
        let pad: CGFloat = 56
        let box = CGSize(width: sf.width * 0.92 - pad * 2, height: sf.height * 0.9 - pad * 2)
        // Windows shrinks the cards as windows pile up, down to a floor, then scrolls.
        flow = CardFlow.fit(aspects: windows.map { groupOf[$0.id].map(screenAspect) ?? CardFlow.aspect(of: $0) }, box: box,
                            minHeight: (sf.height * 0.1).rounded(), maxHeight: (sf.height * 0.266).rounded(),
                            strip: 40, gap: CGSize(width: 26, height: 26), scaled: true, maxRows: 2)
        let strip = flow.strip

        cards.forEach { $0.removeFromSuperview() }
        cards = windows.enumerated().map { i, w in
            let card: WindowCard
            if let g = groupOf[w.id] {
                let name = w.title.isEmpty ? (w.app?.localizedName ?? "") : w.title
                let others = g.members.count - 1
                card = WindowCard(window: w, stripHeight: strip, fontSize: strip < 34 ? 11 : 12,
                                  title: "Group | \(name) and \(others) other window\(others == 1 ? "" : "s")",
                                  icons: g.members.compactMap { $0.app?.icon })
                card.closable = false
            } else {
                card = WindowCard(window: w, stripHeight: strip, fontSize: strip < 34 ? 11 : 12)
            }
            card.frame = flow.frames[i].offsetBy(dx: pad, dy: pad)
            card.onClick = { [weak self] in self?.selected = i; self?.commit() }
            card.onClose = { [weak self] in self?.closeWindow(at: i) }
            content.addSubview(card)
            return card
        }

        let full = CGSize(width: flow.size.width + pad * 2, height: flow.size.height + pad * 2)
        let size = CGSize(width: full.width, height: min(full.height, sf.height * 0.9))
        let frame = NSRect(x: sf.midX - size.width / 2, y: sf.midY - size.height / 2, width: size.width, height: size.height)

        background?.removeFromSuperview()
        let bg = acrylicView(radius: 8)
        bg.frame = NSRect(origin: .zero, size: size)
        background = bg
        let root = NSView(frame: bg.frame)
        root.addSubview(bg)
        content.frame = NSRect(origin: .zero, size: full)
        scroll.frame = bg.frame
        scroll.documentView = content
        scroll.contentView.scroll(to: .zero)
        root.addSubview(scroll)
        panel.contentView = root
        panel.appearance = Theme.appearance
        updateRing()
        panel.show(frame: frame)

        let g = generation
        let members = groupOf.values.flatMap(\.members)
        let everyone = windows + members.filter { m in !windows.contains(m) }
        for (lead, group) in groupOf { composeGroup(lead, group) }
        let onImage: (CGWindowID, CGImage) -> Void = { [weak self] id, image in
            guard let self, self.generation == g else { return }
            if let (lead, group) = self.groupOf.first(where: { $0.value.members.contains { $0.id == id } }) {
                self.composeGroup(lead, group)
            } else {
                self.cards.first(where: { $0.target.id == id })?.setThumbnail(image)
            }
        }
        let side = max(flow.frames.first?.width ?? 300, flow.frames.first?.height ?? 300)
        Thumbnails.shared.capture(everyone, points: side, onImage: onImage)
        live.start(everyone, points: side, onImage: onImage)
    }

    /// The group card's picture: the screen's wallpaper with each member's thumbnail where
    /// the member sits, like Windows' snap group thumbnails.
    private func composeGroup(_ lead: CGWindowID, _ g: SnapGroups.Group) {
        guard let card = cards.first(where: { $0.target.id == lead }) else { return }
        let screen = NSScreen.screens.first { $0.displayID == g.screenID } ?? NSScreen.screens[0]
        let sf = Geo.flip(screen.frame)
        let w = 640, h = Int(640 / (sf.width / sf.height))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        let scale = CGFloat(w) / sf.width
        ctx.setFillColor(Theme.thumbBackground.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if let wall = Wallpaper.image(for: screen) { ctx.draw(wall, in: CGRect(x: 0, y: 0, width: w, height: h)) }
        for m in g.members.reversed() {
            guard let image = Thumbnails.shared.cached(m.id), let f = g.frames[m.id] else { continue }
            let r = CGRect(x: (f.minX - sf.minX) * scale, y: CGFloat(h) - (f.maxY - sf.minY) * scale,
                           width: f.width * scale, height: f.height * scale)
            ctx.draw(image, in: r)
        }
        if let image = ctx.makeImage() { card.setThumbnail(image) }
    }

    private func updateRing() {
        guard cards.indices.contains(selected) else { ring.move(around: nil); return }
        let frame = cards[selected].frame
        ring.move(around: frame)
        content.scrollToVisible(frame.insetBy(dx: -24, dy: -24))
    }

    // MARK: Dragging

    /// Holding a drag over a card for half a second switches to that window, so the drop can
    /// land in it.
    func dragMoved(to p: CGPoint) {
        guard isOpen, panel.isVisible else { return }
        let point = Geo.flip(p)
        let hit = cards.firstIndex { card in
            guard let w = card.window else { return false }
            return w.convertToScreen(card.convert(card.bounds, to: nil)).contains(point)
        }
        guard hit != dragHoverIndex else { return }
        dragHoverIndex = hit
        dragHoverTimer?.invalidate()
        dragHoverTimer = nil
        guard let hit else { return }
        selected = hit
        updateRing()
        let g = generation
        dragHoverTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == g, self.dragHoverIndex == hit else { return }
                self.commit()
            }
        }
    }

    func dragEnded() {
        dragHoverTimer?.invalidate()
        dragHoverTimer = nil
        dragHoverIndex = nil
    }

    // MARK: Ending

    private func commit() {
        guard isOpen, windows.indices.contains(selected) else { cancel(); return }
        let target = windows[selected]
        if Hotkeys.debug { NSLog("Snap11: switch to %d of %d: %@ (%u)", selected, windows.count, target.app?.localizedName ?? "?", target.id) }
        if let g = groupOf[target.id] {
            // The whole group comes forward, the most recent member last so it ends on top.
            for m in g.members where m != target {
                m.focus()
                FocusHistory.shared.touch(m.id)
            }
        }
        target.focus()
        FocusHistory.shared.touch(target.id)
        close()
    }

    func cancel() { close() }

    private func close() {
        live.stop()
        Hotkeys.shared.stopRepeating()
        dragEnded()
        isOpen = false
        sticky = false
        showTimer?.invalidate()
        generation += 1
        panel.hide()
        cards.forEach { $0.removeFromSuperview() }
        cards = []
    }

    private func closeWindow(at i: Int) {
        guard windows.indices.contains(i) else { return }
        windows[i].close()
        let remaining = windows.enumerated().filter { $0.offset != i }.map(\.element)
        guard !remaining.isEmpty else { close(); return }
        windows = remaining
        selected = min(selected, windows.count - 1)
        show()
    }

    // MARK: Keys while open

    private func key(_ e: NSEvent) -> Bool {
        switch Int64(e.keyCode) {
        case Key.left: selected = flow.neighbour(of: selected, .left); updateRing()
        case Key.right: selected = flow.neighbour(of: selected, .right); updateRing()
        case Key.up: selected = flow.neighbour(of: selected, .up); updateRing()
        case Key.down: selected = flow.neighbour(of: selected, .down); updateRing()
        case Key.returnKey, Key.enter, 49: commit()
        case Key.escape: cancel()
        case Key.delete, Key.forwardDelete, Key.w: closeWindow(at: selected)
        case Key.tab: move(e.modifierFlags.contains(.shift) ? -1 : 1)
        default: return true
        }
        return true
    }
}
