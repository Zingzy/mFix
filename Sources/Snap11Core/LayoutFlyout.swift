import AppKit

/// The Snap Layouts flyout: hover a window's green button (or press the Win+Z chord) and
/// a grid of layouts drops below it. Hovering a zone lights it in the accent colour,
/// clicking snaps the window there and Snap Assist fills the rest.
@MainActor
final class LayoutFlyout {
    static let shared = LayoutFlyout()

    /// Windows waits 600 ms on the maximize button (known only from reverse engineering);
    /// macOS's own Move & Resize popover takes a second or more, so this one wins.
    private let hoverDelay: TimeInterval = 0.6

    let panel = OverlayPanel(takesKeyboard: false)
    /// Sits over the green button while the flyout is open, so the app sees the pointer leave
    /// its button and macOS never starts its own Move & Resize popover there.
    private let shield = OverlayPanel(takesKeyboard: false)
    private var grid: LayoutGrid?
    private var target: AXWindow?
    private var screen: NSScreen?
    private var anchor: CGRect = .zero
    private var hoverTimer: Timer?
    private var hoverWindow: CGWindowID = 0
    private var leaveTimer: Timer?
    private var buttonCache: [CGWindowID: (bounds: CGRect, button: CGRect?)] = [:]
    private var lastMove = Date.distantPast
    private var trailing: Timer?
    private(set) var isOpen = false

    private init() {
        // macOS's own green-button popover lives at the pop-up menu level; stay above it.
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        shield.level = panel.level
        let catcher = BackdropView()
        catcher.wantsLayer = true
        catcher.layer?.backgroundColor = NSColor(white: 0, alpha: 0.004).cgColor
        catcher.onClick = { [weak self] in self?.pressCoveredButton() }
        shield.contentView = catcher
        panel.onKey = { [weak self] e in self?.grid?.key(e) ?? false }
        panel.onResignKey = { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.isOpen, self.panel.takesKeyboard, !self.panel.isKeyWindow else { return }
                self.close()
            }
        }
    }

    func start() {
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] e in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return e
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isOpen == true { self?.close() } }
        }
    }

    // MARK: Hover detection

    private func mouseMoved() {
        let now = Date()
        guard now.timeIntervalSince(lastMove) > 0.025 else {
            // Check the last position too, or a pointer that stops right after a quick move
            // onto the button is never looked at.
            if trailing == nil {
                trailing = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.trailing = nil
                        self?.mouseMoved()
                    }
                }
            }
            return
        }
        lastMove = now
        let p = Geo.flip(NSEvent.mouseLocation)

        if isOpen {
            let overPanel = panel.frame.contains(NSEvent.mouseLocation)
            if overPanel || anchor.insetBy(dx: -6, dy: -6).contains(p) || panel.takesKeyboard {
                leaveTimer?.invalidate()
                leaveTimer = nil
            } else if leaveTimer == nil {
                leaveTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.close() }
                }
            }
            return
        }

        let under = WindowList.windowAt(p)
        guard let (wid, pid, bounds) = under,
              p.x < bounds.minX + 120, p.y < bounds.minY + 64,
              let button = greenButton(wid: wid, pid: pid, bounds: bounds),
              button.insetBy(dx: -1, dy: -1).contains(p) else {
            if Hotkeys.debug, let (wid, pid, bounds) = under, p.x < bounds.minX + 120, p.y < bounds.minY + 64 {
                NSLog("Snap11: hover near title bar of %u (%@) at %@, button %@", wid,
                      NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?", NSStringFromPoint(p),
                      buttonCache[wid]?.button.map { NSStringFromRect($0) } ?? "none")
            }
            cancelHover()
            return
        }
        guard hoverWindow != wid || hoverTimer == nil else { return }
        if Hotkeys.debug { NSLog("Snap11: hover on green button of %u, timer started", wid) }
        cancelHover()
        hoverWindow = wid
        hoverTimer = Timer.scheduledTimer(withTimeInterval: hoverDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.hoverTimer = nil
                let now = Geo.flip(NSEvent.mouseLocation)
                guard button.insetBy(dx: -2, dy: -2).contains(now), NSEvent.pressedMouseButtons == 0,
                      let window = AXWindow.windows(of: pid).first(where: { $0.id == wid }) else {
                    if Hotkeys.debug { NSLog("Snap11: hover timer fired but pointer left or window gone") }
                    return
                }
                self.open(for: window, anchor: button, keyboard: false)
            }
        }
    }

    private func cancelHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        hoverWindow = 0
    }

    /// The green button's frame, from Accessibility once per window position.
    private func greenButton(wid: CGWindowID, pid: pid_t, bounds: CGRect) -> CGRect? {
        if let c = buttonCache[wid], c.bounds == bounds { return c.button }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        let window = AXWindow.windows(of: pid).first(where: { $0.id == wid })
        let rect = window?.fullScreenButtonFrame
        buttonCache[wid] = (bounds, rect)
        if buttonCache.count > 200 { buttonCache = [wid: (bounds, rect)] }
        return rect
    }

    // MARK: Showing

    /// The Win+Z chord: open for the focused window with number badges and keyboard control.
    func openForFocused() {
        if isOpen { close(); return }
        guard let window = AXWindow.focused(), !window.isFullScreen else { return }
        let f = window.frame
        let anchor = window.fullScreenButtonFrame ?? CGRect(x: f.midX - 10, y: f.minY + 4, width: 20, height: 20)
        open(for: window, anchor: anchor, keyboard: true)
    }

    func open(for window: AXWindow, anchor: CGRect, keyboard: Bool) {
        let screen = Geo.screen(containing: window.frame)
        let work = Geo.workArea(screen)
        target = window
        self.screen = screen
        self.anchor = anchor

        var layouts: [Layout] = []
        let others = WindowList.currentSpace(excluding: [window.id])
        let portrait = work.height > work.width
        if others.count >= 1 {
            layouts.append(Layout(zones: portrait ? [.top, .bottom] : [.left, .right], suggested: [window.id, others[0].id]))
        }
        if others.count >= 2 {
            let zones: [Zone] = portrait ? [.top, .bottomLeft, .bottomRight] : [.left, .topRight, .bottomRight]
            layouts.append(Layout(zones: zones, suggested: [window.id, others[0].id, others[1].id]))
        }
        let suggestionCount = layouts.count
        layouts += Layout.standard(for: work)
        let columns = Layout.standard(for: work).count == 6 ? 3 : 2
        let icons = Dictionary(others.prefix(2).map { ($0.id, $0.app?.icon) }, uniquingKeysWith: { a, _ in a })

        let grid = LayoutGrid(layouts: layouts, suggestionCount: suggestionCount, columns: columns,
                              icons: icons, aspect: work.width / work.height, badges: keyboard)
        grid.onPick = { [weak self] l, z in self?.apply(layouts[l], zone: z) }
        self.grid = grid

        let size = grid.fittingSize
        let bg = acrylicView(radius: 8)
        bg.frame = NSRect(origin: .zero, size: size)
        let root = NSView(frame: bg.frame)
        root.addSubview(bg)
        grid.frame = bg.frame
        root.addSubview(grid)
        let border = CALayer()
        border.frame = bg.frame
        border.cornerRadius = 8
        border.cornerCurve = .continuous
        border.borderWidth = 1
        border.borderColor = (Theme.dark ? NSColor(white: 1, alpha: 0.14) : NSColor(white: 0, alpha: 0.12)).cgColor
        root.wantsLayer = true
        root.layer?.addSublayer(border)

        let anchorApp = Geo.flip(anchor)
        let visible = screen.visibleFrame
        var x = anchorApp.midX - size.width / 2
        x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
        var y = anchorApp.minY - 6 - size.height
        if y < visible.minY + 8 { y = anchorApp.maxY + 6 }

        panel.takesKeyboard = keyboard
        panel.becomesKeyOnlyIfNeeded = !keyboard
        panel.contentView = root
        panel.appearance = Theme.appearance
        panel.hasShadow = true
        isOpen = true
        panel.show(frame: NSRect(x: x, y: y, width: size.width, height: size.height))
        if !keyboard { shield.show(frame: anchorApp.insetBy(dx: -2, dy: -2)) }
        panel.invalidateShadow()
    }

    func close() {
        if Hotkeys.debug && isOpen { NSLog("Snap11: flyout close %@", Thread.callStackSymbols.dropFirst().prefix(2).joined(separator: " | ")) }
        isOpen = false
        leaveTimer?.invalidate()
        leaveTimer = nil
        cancelHover()
        panel.hide()
        shield.hide()
        grid = nil
    }

    /// A click on the shield is a click on the green button underneath.
    private func pressCoveredButton() {
        let window = target
        close()
        guard let button: AXUIElement = window?.element?.attr(kAXFullScreenButtonAttribute) else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    private func apply(_ layout: Layout, zone index: Int) {
        guard let target, let screen else { close(); return }
        close()
        if layout.isSuggestion {
            let windows = WindowList.currentSpace()
            for (i, id) in layout.suggested.enumerated() {
                guard let id, let w = (id == target.id ? target : windows.first(where: { $0.id == id })) else { continue }
                if w.isMinimized { w.unminimize() }
                SnapEngine.shared.place(w, zone: layout.zones[i], on: screen)
            }
            target.focus()
            return
        }
        let zone = layout.zones[index]
        SnapEngine.shared.place(target, zone: zone, on: screen)
        target.focus()
        SnapAssist.shared.begin(after: target, zone: zone, on: screen, layout: layout)
    }
}

/// Draws the layout grid and tracks which zone is under the pointer or keyboard focus.
@MainActor
final class LayoutGrid: FlippedView {
    var onPick: ((Int, Int) -> Void)?

    private let layouts: [Layout]
    private let suggestionCount: Int
    private let columns: Int
    private let icons: [CGWindowID: NSImage?]
    private let badges: Bool
    private var blocks: [CGRect] = []
    private var focus: (layout: Int, zone: Int)?
    private var typedLayout: Int?
    private var tracking: NSTrackingArea?

    private let blockSize: CGSize
    private let pad: CGFloat = 12
    private let gap: CGFloat = 12
    private let zoneGap: CGFloat = 4

    init(layouts: [Layout], suggestionCount: Int, columns: Int, icons: [CGWindowID: NSImage?], aspect: CGFloat, badges: Bool) {
        self.layouts = layouts
        self.suggestionCount = suggestionCount
        self.columns = columns
        self.icons = icons
        self.badges = badges
        let w: CGFloat = columns == 3 ? 92 : 96
        blockSize = CGSize(width: w, height: (w / max(aspect, 1.2) * 1.0).rounded())
        super.init(frame: .zero)
        var y = pad
        var row: [Int] = []
        func flush() {
            for (c, i) in row.enumerated() {
                blocks[i] = CGRect(x: pad + CGFloat(c) * (blockSize.width + gap), y: y, width: blockSize.width, height: blockSize.height)
            }
            if !row.isEmpty { y += blockSize.height + gap }
            row = []
        }
        blocks = Array(repeating: .zero, count: layouts.count)
        for i in 0..<suggestionCount { row.append(i) }
        flush()
        for i in suggestionCount..<layouts.count {
            row.append(i)
            if row.count == columns { flush() }
        }
        flush()
        if badges { focus = (0, 0) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        let width = pad * 2 + CGFloat(columns) * blockSize.width + CGFloat(columns - 1) * gap
        let height = (blocks.map(\.maxY).max() ?? 0) + pad
        return NSSize(width: width, height: height)
    }

    private func zoneRects(_ i: Int) -> [CGRect] {
        let b = blocks[i]
        return layouts[i].zones.map { z in
            CGRect(x: b.minX + z.x * b.width, y: b.minY + z.y * b.height, width: z.w * b.width, height: z.h * b.height)
                .insetBy(dx: zoneGap / 2, dy: zoneGap / 2)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let dark = Theme.dark
        let fill = dark ? NSColor(white: 0.30, alpha: 0.85) : NSColor(white: 0.85, alpha: 1)
        let suggestFill = dark ? NSColor(white: 0.40, alpha: 0.85) : NSColor(white: 0.945, alpha: 1)
        let stroke = dark ? NSColor(white: 0.55, alpha: 0.9) : NSColor(white: 0.53, alpha: 1)
        for i in layouts.indices {
            let layout = layouts[i]
            for (zi, r) in zoneRects(i).enumerated() {
                let path = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
                let lit = focus.map { $0.layout == i && $0.zone == zi } ?? false
                let suggestedID = layout.isSuggestion && zi > 0 ? layout.suggested[zi] : nil
                (lit ? Theme.accent : (suggestedID != nil ? suggestFill : fill)).setFill()
                path.fill()
                if !lit {
                    stroke.setStroke()
                    path.lineWidth = 1
                    path.stroke()
                }
                if let id = suggestedID, let icon = icons[id] ?? nil {
                    let s = min(22, r.width * 0.55, r.height * 0.55)
                    icon.draw(in: CGRect(x: r.midX - s / 2, y: r.midY - s / 2, width: s, height: s),
                              from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                }
                if badges, typedLayout == i {
                    drawBadge("\(zi + 1)", in: r)
                }
            }
            if badges, typedLayout == nil, i < 9 {
                drawBadge("\(i + 1)", in: blocks[i])
            }
        }
    }

    private func drawBadge(_ text: String, in r: CGRect) {
        let s: CGFloat = 18
        let box = CGRect(x: r.midX - s / 2, y: r.midY - s / 2, width: s, height: s)
        (Theme.dark ? NSColor(white: 0.22, alpha: 0.95) : NSColor(white: 0.97, alpha: 0.97)).setFill()
        NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: Theme.text]
        let str = NSAttributedString(string: text, attributes: attrs)
        let ts = str.size()
        str.draw(at: CGPoint(x: box.midX - ts.width / 2, y: box.midY - ts.height / 2))
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private func hit(_ p: CGPoint) -> (Int, Int)? {
        for i in layouts.indices {
            for (zi, r) in zoneRects(i).enumerated() where r.insetBy(dx: -zoneGap / 2, dy: -zoneGap / 2).contains(p) {
                return (i, zi)
            }
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let h = hit(convert(event.locationInWindow, from: nil))
        if h?.0 != focus?.layout || h?.1 != focus?.zone {
            focus = h.map { ($0.0, $0.1) }
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if !badges { focus = nil; needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        if Hotkeys.debug { NSLog("Snap11: grid mouseDown %@", NSStringFromPoint(convert(event.locationInWindow, from: nil))) }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if Hotkeys.debug { NSLog("Snap11: grid mouseUp %@ hit %d", NSStringFromPoint(p), hit(p) == nil ? 0 : 1) }
        if let (l, z) = hit(p) { onPick?(l, z) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Keyboard (Win+Z mode)

    func key(_ e: NSEvent) -> Bool {
        let code = Int64(e.keyCode)
        if let d = Key.digits.firstIndex(of: code) {
            if let l = typedLayout {
                if d < layouts[l].zones.count { onPick?(l, d) }
            } else if d < layouts.count {
                typedLayout = d
                focus = (d, 0)
                needsDisplay = true
            }
            return true
        }
        var f = focus ?? (0, 0)
        switch code {
        case Key.tab:
            let n = layouts.count
            f = ((f.layout + (e.modifierFlags.contains(.shift) ? n - 1 : 1)) % n, 0)
        case Key.right:
            if f.zone + 1 < layouts[f.layout].zones.count { f.zone += 1 } else { f = ((f.layout + 1) % layouts.count, 0) }
        case Key.left:
            if f.zone > 0 { f.zone -= 1 } else {
                let l = (f.layout - 1 + layouts.count) % layouts.count
                f = (l, layouts[l].zones.count - 1)
            }
        case Key.down, Key.up:
            let b = blocks[f.layout]
            let candidates = layouts.indices.filter { code == Key.down ? blocks[$0].minY > b.maxY : blocks[$0].maxY < b.minY }
            let rowY = code == Key.down ? candidates.map { blocks[$0].minY }.min() : candidates.map { blocks[$0].minY }.max()
            if let rowY, let l = candidates.filter({ blocks[$0].minY == rowY }).min(by: { abs(blocks[$0].midX - b.midX) < abs(blocks[$1].midX - b.midX) }) {
                f = (l, 0)
            }
        case Key.returnKey, Key.enter, 49:
            onPick?(f.layout, f.zone)
            return true
        case Key.escape:
            LayoutFlyout.shared.close()
            return true
        default:
            return true
        }
        focus = f
        typedLayout = nil
        needsDisplay = true
        return true
    }
}
