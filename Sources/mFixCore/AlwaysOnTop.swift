import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit

/// PowerToys' Always on Top: Win+Ctrl+T pins the window in front, and again unpins it, with an
/// accent border around it. Nothing public lets one app lift another app's window over the
/// app in front (Accessibility's raise only reorders within the window's own app), so while
/// another window has focus mFix lays a live mirror of the pinned one exactly over it, in a
/// panel of its own that does stay on top. Clicking the mirror brings the real window forward
/// and the mirror goes; it streams only while it shows. Closing the window unpins it.
@MainActor
final class AlwaysOnTop: Feature {
    static let shared = AlwaysOnTop()

    @MainActor
    private final class Pin {
        let window: AXWindow
        let border = OverlayPanel(level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1), clickThrough: true)
        let mirror = MirrorPanel()
        var watcher: AXWatcher?
        var stream: SCStream?
        var output: FrameSink?
        var starting = false
        /// Set when the person asks it to close, so the border goes before the window's own
        /// close finishes; cleared if the window is still there a second later.
        var closing: Date?

        init(window: AXWindow) { self.window = window }
    }

    private var pins: [CGWindowID: Pin] = [:] {
        didSet { watchClosing() }
    }
    private var closeWatch: Timer?
    private var closeTap: ListenTap?

    /// Some apps report a closed window late, and some keep it alive hidden; WindowServer
    /// knows at once that it is no longer shown. Only runs while something is pinned.
    private func watchClosing() {
        if pins.isEmpty {
            closeWatch?.invalidate()
            closeWatch = nil
            return
        }
        guard closeWatch == nil else { return }
        closeWatch = Timer.onMain(after: 0.05, repeats: true) { [weak self] in
            guard let self else { return }
            let gone = self.pins.filter { id, pin in
                WindowInfo.list(.optionIncludingWindow, relativeTo: id).isEmpty
                    || (!SkyLight.isOrderedIn(id) && !pin.window.isMinimized && !(pin.window.app?.isHidden ?? false))
            }
            for (id, pin) in gone {
                self.stopMirror(pin)
                pin.border.hide()
                self.pins[id] = nil
            }
            for pin in self.pins.values {
                if let t = pin.closing, Date().timeIntervalSince(t) > 1 {
                    pin.closing = nil
                    self.refresh(pin)
                }
            }
        }
    }

    /// The red button or Cmd+W on a pinned window: take the border away now.
    private func closeAsked(_ type: CGEventType, _ event: CGEvent) {
        if type == .leftMouseUp {
            let p = event.location
            for pin in pins.values {
                guard let button: AXUIElement = pin.window.element?.attr(kAXCloseButtonAttribute),
                      button.frame?.insetBy(dx: -2, dy: -2).contains(p) == true else { continue }
                closing(pin)
            }
        } else if event.getIntegerValueField(.keyboardEventKeycode) == Key.w,
                  event.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl]) == .maskCommand,
                  let front = AXWindow.focused(), let pin = pins[front.id] {
            closing(pin)
        }
    }

    private func closing(_ pin: Pin) {
        pin.closing = Date()
        stopMirror(pin)
        pin.border.hide()
    }

    func start() {
        closeTap = ListenTap([.leftMouseUp, .keyDown]) { [weak self] type, event in
            MainActor.assumeIsolated { if self?.pins.isEmpty == false { self?.closeAsked(type, event) } }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
        FocusHistory.shared.onFocus = { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAll() }
        }
    }

    func hotkeys(win: Int) -> [Hotkey] {
        // PowerToys' Always on Top is Win+Ctrl+T.
        Settings.alwaysOnTop.value ? [Hotkey(Key.t, Hotkey.winAlt) { self.toggleFocused() }] : []
    }

    var pinnedIDs: Set<CGWindowID> { Set(pins.keys) }

    func isMirrored(_ id: CGWindowID) -> Bool { pins[id]?.mirror.isVisible ?? false }

    func hasBorder(_ id: CGWindowID) -> Bool { pins[id]?.border.isVisible ?? false }

    func toggleFocused() {
        guard let w = AXWindow.focused(), w.id != 0, !w.isFullScreen else { return }
        toggle(w)
    }

    func toggle(_ w: AXWindow) {
        if let pin = pins.removeValue(forKey: w.id) {
            stopMirror(pin)
            pin.border.hide()
            return
        }
        let pin = Pin(window: w)
        let border = BorderView()
        border.radii = WindowCorners.radii(of: w.id, frameWidth: w.frame.width) ?? .fallback
        pin.border.contentView = border
        // On the pinned window's own Space only, as a pinned window stays on its own desktop
        // on Windows; the panels join the Space they first appear on.
        pin.border.collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        pin.mirror.onClick = { [weak self] in self?.bringBack(w.id) }
        pins[w.id] = pin
        follow(pin)
        refresh(pin)
    }

    // MARK: Which of the two it shows

    private func refreshAll() {
        for pin in pins.values { refresh(pin) }
    }

    /// The real window when it has focus, the mirror over it otherwise.
    private func refresh(_ pin: Pin) {
        if pin.closing != nil { return }
        let f = pin.window.frame
        // A panel shown while another Space is up moves to that Space, so a pinned window on
        // another Space keeps its border and mirror hidden until its Space is back.
        let onThisSpace = SkyLight.spaces(for: pin.window.id).contains(SkyLight.activeSpace)
        guard f.width > 0, !pin.window.isMinimized, pin.window.hasElement, onThisSpace else {
            stopMirror(pin)
            pin.border.hide()
            return
        }
        let inFront = AXWindow.focused().map { $0.id == pin.window.id } ?? false
        pin.border.appearance = Theme.appearance
        pin.border.show(frame: Geo.flip(f))
        if inFront {
            stopMirror(pin)
        } else {
            showMirror(pin, at: f)
        }
    }

    private func bringBack(_ id: CGWindowID) {
        guard let pin = pins[id] else { return }
        stopMirror(pin)
        pin.window.focus()
    }

    // MARK: The mirror

    private func showMirror(_ pin: Pin, at frame: CGRect) {
        pin.mirror.setFrame(Geo.flip(frame), display: false)
        if pin.stream == nil && !pin.starting {
            pin.starting = true
            Task { @MainActor in
                defer { pin.starting = false }
                guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
                      let scw = content.windows.first(where: { $0.windowID == pin.window.id }),
                      self.pins[pin.window.id] === pin else { return }
                let config = SCStreamConfiguration()
                let scale = Geo.backingScale(of: frame)
                config.width = Int(frame.width * scale)
                config.height = Int(frame.height * scale)
                config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.showsCursor = false
                config.queueDepth = 3
                let sink = FrameSink(layer: pin.mirror.surface)
                let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: scw), configuration: config, delegate: nil)
                try? stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: sink.queue)
                do { try await stream.startCapture() } catch { return }
                pin.stream = stream
                pin.output = sink
                // The person may have come back to the window while the stream started.
                if AXWindow.focused().map({ $0.id == pin.window.id }) ?? false { self.stopMirror(pin) }
            }
        }
        pin.mirror.orderFrontRegardless()
    }

    private func stopMirror(_ pin: Pin) {
        pin.mirror.orderOut(nil)
        if let stream = pin.stream { Task { try? await stream.stopCapture() } }
        pin.stream = nil
        pin.output = nil
    }

    // MARK: Following the window

    private func follow(_ pin: Pin) {
        guard let element = pin.window.element else { return }
        pin.watcher = AXWatcher(pid: pin.window.pid) { id, name in onMain { AlwaysOnTop.shared.changed(id, name) } }
        pin.watcher?.watch(element, [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
                                     kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification])
    }

    private func changed(_ id: CGWindowID, _ notification: String) {
        guard let pin = pins[id] else { return }
        if notification == kAXUIElementDestroyedNotification as String {
            stopMirror(pin)
            pin.border.hide()
            pins[id] = nil
            return
        }
        if notification == kAXResizedNotification as String { stopMirror(pin) }
        refresh(pin)
    }

    // MARK: Views

    /// An accent outline just inside the window's edge, following its own four corners; inside
    /// so that no part of it runs under the Dock or off the screen.
    private final class BorderView: NSView {
        var radii = WindowCorners.Radii.fallback

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            let r = bounds.insetBy(dx: 1.5, dy: 1.5)
            let (tl, tr, bl, br) = (max(radii.topLeft - 1.5, 0), max(radii.topRight - 1.5, 0),
                                    max(radii.bottomLeft - 1.5, 0), max(radii.bottomRight - 1.5, 0))
            let path = NSBezierPath()
            path.move(to: CGPoint(x: r.minX + tl, y: r.minY))
            path.line(to: CGPoint(x: r.maxX - tr, y: r.minY))
            path.appendArc(withCenter: CGPoint(x: r.maxX - tr, y: r.minY + tr), radius: tr, startAngle: 270, endAngle: 360)
            path.line(to: CGPoint(x: r.maxX, y: r.maxY - br))
            path.appendArc(withCenter: CGPoint(x: r.maxX - br, y: r.maxY - br), radius: br, startAngle: 0, endAngle: 90)
            path.line(to: CGPoint(x: r.minX + bl, y: r.maxY))
            path.appendArc(withCenter: CGPoint(x: r.minX + bl, y: r.maxY - bl), radius: bl, startAngle: 90, endAngle: 180)
            path.line(to: CGPoint(x: r.minX, y: r.minY + tl))
            path.appendArc(withCenter: CGPoint(x: r.minX + tl, y: r.minY + tl), radius: tl, startAngle: 180, endAngle: 270)
            path.close()
            path.lineWidth = 3
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
    }

    /// The panel the mirror draws in, above every app; a click on it hands back to the window.
    final class MirrorPanel: NSPanel {
        let surface = CALayer()
        var onClick: (() -> Void)?

        init() {
            super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            level = .floating
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
            animationBehavior = .none
            collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
            let v = ClickView()
            v.wantsLayer = true
            v.layer?.addSublayer(surface)
            surface.contentsGravity = .resize
            v.onClick = { [weak self] in self?.onClick?() }
            contentView = v
        }

        override func setFrame(_ frameRect: NSRect, display flag: Bool) {
            super.setFrame(frameRect, display: flag)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surface.frame = CGRect(origin: .zero, size: frameRect.size)
            CATransaction.commit()
        }

        final class ClickView: NSView {
            var onClick: (() -> Void)?
            override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
            override func mouseDown(with event: NSEvent) { onClick?() }
        }
    }
}

/// Puts each complete stream frame's IOSurface straight into the mirror's layer, with no
/// image made from it.
final class FrameSink: NSObject, SCStreamOutput, @unchecked Sendable {
    let queue = DispatchQueue(label: "mfix.mirror", qos: .userInteractive)
    private weak var layer: CALayer?

    init(layer: CALayer) {
        self.layer = layer
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              (info[.status] as? Int).flatMap(SCFrameStatus.init(rawValue:)) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(buffer),
              let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() else { return }
        DispatchQueue.main.async { [weak self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self?.layer?.contents = surface
            CATransaction.commit()
        }
    }
}
