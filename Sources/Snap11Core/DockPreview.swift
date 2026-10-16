import AppKit

/// Windows taskbar behaviour on the Dock. Hovering an app's icon shows its windows as cards
/// above it; a card click focuses that window (on any Space), its X closes it. Clicking the
/// icon of the app already in front minimizes its window, or steps to the next one when it
/// has several. The Dock reports the hovered icon itself, as its list's selected child.
@MainActor
final class DockPreview {
    static let shared = DockPreview()


    private let panel = OverlayPanel(takesKeyboard: false)
    private var observer: AXObserver?
    private var list: AXUIElement?
    private var dockPID: pid_t = 0
    private var health: Timer?
    private var showTimer: Timer?
    private var hideTimer: Timer?
    private var hovered: (frame: CGRect, url: URL)?
    private var shownFor: URL?
    private var cards: [WindowCard] = []
    private var generation = 0
    private let live = LiveThumbnails()
    private var clickTap: ListenTap?
    private var down: (url: URL, wasFront: Bool, at: CGPoint)?

    func start() {
        subscribe()
        health = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkHealth() }
        }
        let tap = ListenTap([.leftMouseDown, .leftMouseUp]) { [weak self] type, event in
            let p = event.location
            MainActor.assumeIsolated { self?.click(type == .leftMouseDown, at: p) }
        }
        tap.start()
        clickTap = tap
    }

    // MARK: Following the Dock

    private func subscribe() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        dockPID = dock.processIdentifier
        let app = AXUIElementCreateApplication(dockPID)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let found = ((app.attr(kAXChildrenAttribute) as [AXUIElement]?) ?? [])
            .first(where: { ($0.attr(kAXRoleAttribute) as String?) == kAXListRole }) else { return }
        var obs: AXObserver?
        if Hotkeys.debug { NSLog("Snap11: dock list found, subscribing") }
        guard AXObserverCreate(dockPID, { _, _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { DockPreview.shared.selectionChanged() } }
        }, &obs) == .success, let obs else { return }
        AXObserverAddNotification(obs, found, kAXSelectedChildrenChangedNotification as CFString, nil)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observer = obs
        list = found
    }

    /// The Dock rebuilds its accessibility tree when it restarts or changes layout, and the
    /// old list stops sending notifications.
    private func checkHealth() {
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?.processIdentifier
        let alive = list.map { (($0.attr(kAXRoleAttribute) as String?) != nil) } ?? false
        if pid != dockPID || !alive {
            observer = nil
            list = nil
            subscribe()
        }
    }

    private func selectionChanged() {
        guard Settings.dockPreviews, let list else { return }
        let selected = (list.attr(kAXSelectedChildrenAttribute) as [AXUIElement]?)?.first
        guard let item = selected, (item.attr(kAXSubroleAttribute) as String?) == "AXApplicationDockItem",
              let url: URL = item.attr(kAXURLAttribute),
              let pos = item.point(kAXPositionAttribute), let size = item.size(kAXSizeAttribute) else {
            hovered = nil
            showTimer?.invalidate()
            scheduleHide()
            return
        }
        hovered = (CGRect(origin: pos, size: size), url)
        if Hotkeys.debug { NSLog("Snap11: dock hover %@", url.lastPathComponent) }
        if shownFor == url { return }
        showTimer?.invalidate()
        let wait = panel.isVisible ? 0 : Settings.dockDelay
        showTimer = Timer.scheduledTimer(withTimeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.show() }
        }
    }

    // MARK: Showing

    private func show() {
        guard let (icon, url) = hovered, !DragDrop.shared.isDragging, !Switcher.shared.isOpen,
              let app = DockItems.Item(frame: icon, url: url, title: "").runningApp else { hide(); return }
        let windows = WindowList.allSpaces(only: app.processIdentifier)
        if Hotkeys.debug { NSLog("Snap11: dock preview for %@: %d windows", url.lastPathComponent, windows.count) }
        guard !windows.isEmpty else { hide(); return }
        generation += 1
        shownFor = url

        let screen = Geo.screen(at: CGPoint(x: icon.midX, y: icon.midY)) ?? NSScreen.screens[0]
        let pad: CGFloat = 10
        let maxWidth = screen.frame.width - 40 - pad * 2
        let flow = CardFlow.fit(aspects: windows.map(CardFlow.aspect), box: CGSize(width: maxWidth, height: 180),
                                minHeight: 90, maxHeight: 160, strip: 32, gap: CGSize(width: 10, height: 10))
        let size = CGSize(width: flow.size.width + pad * 2, height: flow.size.height + pad * 2)

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let bg = acrylicView(radius: 8)
        bg.frame = root.bounds
        root.addSubview(bg)
        let content = FlippedView(frame: root.bounds)
        cards = windows.enumerated().map { i, w in
            let card = WindowCard(window: w, stripHeight: 32, fontSize: 12)
            card.frame = flow.frames[i].offsetBy(dx: pad, dy: pad)
            card.onClick = { [weak self] in
                w.focus()
                FocusHistory.shared.touch(w.id)
                self?.hide()
            }
            card.onClose = { [weak self] in
                w.close()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    MainActor.assumeIsolated { self?.shownFor = nil; self?.show() }
                }
            }
            content.addSubview(card)
            return card
        }
        root.addSubview(content)

        // Right against the icon, covering the Dock's own name label, which otherwise stays
        // on screen over the cards. Above it for a bottom Dock, beside it for a side Dock.
        let iconApp = Geo.flip(icon)
        let visible = screen.frame.insetBy(dx: 8, dy: 8)
        var origin: CGPoint
        switch DockEdge.current {
        case .bottom: origin = CGPoint(x: iconApp.midX - size.width / 2, y: iconApp.maxY + 2)
        case .left: origin = CGPoint(x: iconApp.maxX + 2, y: iconApp.midY - size.height / 2)
        case .right: origin = CGPoint(x: iconApp.minX - 2 - size.width, y: iconApp.midY - size.height / 2)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)

        panel.contentView = root
        panel.appearance = Theme.appearance
        panel.show(frame: NSRect(origin: origin, size: size))
        // The Dock doesn't always report the pointer leaving, so the panel watches for it.
        hideTimer?.invalidate()
        hideTimer = nil
        scheduleHide()

        let g = generation
        let onImage: (CGWindowID, CGImage) -> Void = { [weak self] id, image in
            guard let self, self.generation == g else { return }
            self.cards.first(where: { $0.target.id == id })?.setThumbnail(image)
        }
        let side = max(flow.frames.first?.width ?? 200, 200)
        Thumbnails.shared.capture(windows, points: side, onImage: onImage)
        live.start(windows, points: side, onImage: onImage)
    }

    private func scheduleHide() {
        guard panel.isVisible, hideTimer == nil else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                let overPanel = self.panel.frame.insetBy(dx: -6, dy: -6).contains(p)
                let overIcon = self.hovered.map { Geo.flip($0.frame).insetBy(dx: -8, dy: -8).contains(p) } ?? false
                if !overPanel && !overIcon { self.hide() }
            }
        }
    }

    func hide() {
        showTimer?.invalidate()
        hideTimer?.invalidate()
        hideTimer = nil
        shownFor = nil
        generation += 1
        live.stop()
        panel.hide()
        cards = []
    }

    // MARK: Clicking the icon

    private func click(_ isDown: Bool, at p: CGPoint) {
        guard Settings.dockClicks else { return }
        if isDown {
            down = nil
            guard let (icon, url) = hovered, icon.insetBy(dx: -4, dy: -4).contains(p) else { return }
            let front = NSWorkspace.shared.frontmostApplication?.bundleURL?.standardizedFileURL == url.standardizedFileURL
            down = (url, front, p)
            hide()
            return
        }
        guard let d = down, hypot(p.x - d.at.x, p.y - d.at.y) < 6, d.wasFront, !DragDrop.shared.isDragging else { down = nil; return }
        down = nil
        // After the Dock has handled its own click.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            MainActor.assumeIsolated {
                guard let app = DockItems.Item(frame: .zero, url: d.url, title: "").runningApp else { return }
                let windows = WindowList.currentSpace().filter { $0.pid == app.processIdentifier && !$0.isMinimized }
                if windows.count == 1 {
                    windows[0].minimize()
                } else if let next = WindowCycle.next(of: windows, pid: app.processIdentifier) {
                    next.focus()
                    FocusHistory.shared.touch(next.id)
                }
            }
        }
    }
}

enum DockEdge {
    case bottom, left, right

    static var current: DockEdge {
        switch UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") {
        case "left": .left
        case "right": .right
        default: .bottom
        }
    }
}
