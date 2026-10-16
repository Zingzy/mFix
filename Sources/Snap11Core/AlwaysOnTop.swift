import AppKit
import ScreenCaptureKit

/// PowerToys' Always on Top: Win+Ctrl+T pins the window in front, and again unpins it, with an
/// accent border around it. Nothing public lets one app lift another app's window over the
/// app in front (Accessibility's raise only reorders within the window's own app), so while
/// another window has focus Snap11 lays a live mirror of the pinned one exactly over it, in a
/// panel of its own that does stay on top. Clicking the mirror brings the real window forward
/// and the mirror goes; it streams only while it shows. Closing the window unpins it.
@MainActor
final class AlwaysOnTop {
    static let shared = AlwaysOnTop()

    @MainActor
    private final class Pin {
        let window: AXWindow
        let border = OverlayPanel(takesKeyboard: false)
        let mirror = MirrorPanel()
        var observer: AXObserver?
        var stream: SCStream?
        var output: FrameSink?
        var starting = false

        init(window: AXWindow) { self.window = window }
    }

    private var pins: [CGWindowID: Pin] = [:] {
        didSet { watchClosing() }
    }
    private var closeWatch: Timer?

    /// Some apps report a closed window late; WindowServer knows at once. Only runs while
    /// something is pinned.
    private func watchClosing() {
        if pins.isEmpty {
            closeWatch?.invalidate()
            closeWatch = nil
            return
        }
        guard closeWatch == nil else { return }
        closeWatch = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for (id, pin) in self.pins where (CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]] ?? []).isEmpty {
                    self.stopMirror(pin)
                    pin.border.hide()
                    self.pins[id] = nil
                }
            }
        }
    }

    func start() {
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

    var pinnedIDs: Set<CGWindowID> { Set(pins.keys) }

    func isMirrored(_ id: CGWindowID) -> Bool { pins[id]?.mirror.isVisible ?? false }

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
        pin.border.ignoresMouseEvents = true
        pin.border.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        let border = BorderView()
        border.radius = (WindowCorners.radius(of: w.id, frameWidth: w.frame.width) ?? 16) + 1.5
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
        pin.border.show(frame: Geo.flip(f.insetBy(dx: -3, dy: -3)))
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
                let scale = NSScreen.screens.first { Geo.flip($0.frame).intersects(frame) }?.backingScaleFactor ?? 2
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
        var obs: AXObserver?
        guard AXObserverCreate(pin.window.pid, { _, element, notification, _ in
            var id: CGWindowID = 0
            _AXUIElementGetWindow(element, &id)
            let name = notification as String
            DispatchQueue.main.async { MainActor.assumeIsolated { AlwaysOnTop.shared.changed(id, name) } }
        }, &obs) == .success, let obs else { return }
        for n in [kAXMovedNotification, kAXResizedNotification, kAXUIElementDestroyedNotification,
                  kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification] {
            AXObserverAddNotification(obs, element, n as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        pin.observer = obs
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

    /// An accent outline following the window's own corners, its stroke 1.5 pt outside them.
    private final class BorderView: NSView {
        var radius: CGFloat = 17.5

        override func draw(_ dirtyRect: NSRect) {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: radius, yRadius: radius)
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
    let queue = DispatchQueue(label: "snap11.mirror", qos: .userInteractive)
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
