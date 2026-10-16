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

    /// Windows shows the panel at once; a short wait keeps a quick Cmd+Tab from flashing it.
    private let showDelay: TimeInterval = 0.09

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
    private var cards: [WindowCard] = []
    private var flow = CardFlow()
    private var selected = 0
    private var sticky = false
    private var showTimer: Timer?
    private var dragHoverTimer: Timer?
    private var dragHoverIndex: Int?
    private var generation = 0
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
        windows = WindowList.allSpaces()
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
        if sticky || showDelay <= 0 {
            show()
        } else {
            let g = generation
            showTimer = Timer.scheduledTimer(withTimeInterval: showDelay, repeats: false) { _ in
                MainActor.assumeIsolated { if self.generation == g && self.isOpen { self.show() } }
            }
        }
    }

    /// Cmd went up: switch to the selection, unless the switcher was opened sticky.
    func modifiersReleased() {
        guard isOpen, !sticky else { return }
        commit()
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
        flow = CardFlow.fit(aspects: windows.map(CardFlow.aspect), box: box,
                            minHeight: (sf.height * 0.1).rounded(), maxHeight: (sf.height * 0.266).rounded(),
                            strip: 40, gap: CGSize(width: 26, height: 26), scaled: true)
        let strip = flow.strip

        cards.forEach { $0.removeFromSuperview() }
        cards = windows.enumerated().map { i, w in
            let card = WindowCard(window: w, stripHeight: strip, fontSize: strip < 34 ? 11 : 12)
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
        Thumbnails.shared.capture(windows, points: max(flow.frames.first?.width ?? 300, flow.frames.first?.height ?? 300)) { [weak self] id, image in
            guard let self, self.generation == g else { return }
            self.cards.first(where: { $0.target.id == id })?.setThumbnail(image)
        }
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
        target.focus()
        FocusHistory.shared.touch(target.id)
        close()
    }

    func cancel() { close() }

    private func close() {
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
