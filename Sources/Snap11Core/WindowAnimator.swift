import AppKit
import ScreenCaptureKit

/// Slides a window into its snap frame the way Windows' compositor does, without asking the
/// app to redraw on every frame (moving another app's window step by step through
/// Accessibility stutters, because each step is a relayout in that app).
///
/// Two snapshots are taken first: the window, and the target area as it looks without the
/// window. The background snapshot covers the target, the real window goes straight to its
/// frame behind it, and the window snapshot slides there in a GPU layer at 60 fps. Then both
/// snapshots go and the real window is in place. If a snapshot fails, the window just moves.
@MainActor
final class WindowAnimator {
    static let shared = WindowAnimator()

    private let duration: TimeInterval = 0.18

    /// Only touched on the main thread; the animation completion hops back there.
    private final class Run: @unchecked Sendable {
        let window: AXWindow
        let to: CGRect
        let done: (CGRect) -> Void
        var panels: [NSPanel] = []
        var finished = false

        init(window: AXWindow, to: CGRect, done: @escaping (CGRect) -> Void) {
            self.window = window
            self.to = to
            self.done = done
        }
    }

    private var runs: [CGWindowID: Run] = [:]

    func animate(_ window: AXWindow, to target: CGRect, done: @escaping (CGRect) -> Void) {
        finish(window)
        let from = window.frame
        guard Settings.animate, window.id != 0, from.width > 0, !from.isClose(to: target, tolerance: 2),
              let snapshot = SkyLight.captureWindow(window.id) else {
            window.setFrame(target)
            done(window.frame)
            return
        }
        let run = Run(window: window, to: target, done: done)
        runs[window.id] = run
        let asked = Date()
        Task { @MainActor in
            let background = await Self.capture(target, excluding: window.id)
            if Hotkeys.debug || CommandLine.arguments.contains("--snap-check") {
                NSLog("Snap11: animation snapshots ready in %.0f ms (background %@)", Date().timeIntervalSince(asked) * 1000, background == nil ? "failed" : "ok")
            }
            guard !run.finished else { return }
            guard let background else {
                self.complete(run)
                return
            }
            let cover = Self.panel(Geo.flip(target), image: background, level: .floating)
            let ghost = Self.panel(Geo.flip(from), image: snapshot, level: NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1))
            run.panels = [cover, ghost]
            cover.orderFrontRegardless()
            ghost.orderFrontRegardless()
            window.setFrame(target)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = self.duration
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.1, 0.9, 0.2, 1)
                ghost.animator().setFrame(Geo.flip(target), display: true)
            }, completionHandler: {
                MainActor.assumeIsolated { self.complete(run) }
            })
        }
    }

    /// Ends a window's animation at once, at its target; called before acting on it again.
    func finish(_ window: AXWindow) {
        guard let run = runs[window.id] else { return }
        complete(run)
    }

    private func complete(_ run: Run) {
        guard !run.finished else { return }
        run.finished = true
        runs[run.window.id] = nil
        if !run.window.frame.isClose(to: run.to, tolerance: 1) { run.window.setFrame(run.to) }
        run.panels.forEach { $0.orderOut(nil) }
        run.done(run.window.frame)
    }

    private static func panel(_ frame: NSRect, image: CGImage, level: NSWindow.Level) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = level
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.animationBehavior = .none
        p.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        let v = NSView(frame: NSRect(origin: .zero, size: frame.size))
        v.wantsLayer = true
        v.layer?.contents = image
        v.layer?.contentsGravity = .resize
        v.autoresizingMask = [.width, .height]
        p.contentView = v
        return p
    }

    /// Listing shareable content is most of a capture's cost; a few seconds' reuse is safe as
    /// long as the moving window is in it.
    private static var content: (SCShareableContent, Date)?

    private static func shareable(containing id: CGWindowID) async -> SCShareableContent? {
        if let (c, at) = content, Date().timeIntervalSince(at) < 3, c.windows.contains(where: { $0.windowID == id }) { return c }
        guard let c = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
        content = (c, Date())
        return c
    }

    /// The target area of its display as it looks without the moving window.
    private static func capture(_ rect: CGRect, excluding id: CGWindowID) async -> CGImage? {
        guard let content = await shareable(containing: id),
              let display = content.displays.first(where: { $0.frame.intersects(rect) }) else { return nil }
        let own = ProcessInfo.processInfo.processIdentifier
        let excluded = content.windows.filter { $0.windowID == id || $0.owningApplication?.processID == own }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        let config = SCScreenshotConfiguration()
        let scale = NSScreen.screens.first { $0.displayID == display.displayID }?.backingScaleFactor ?? 2
        config.sourceRect = rect.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
        config.width = Int(rect.width * scale)
        config.height = Int(rect.height * scale)
        config.showsCursor = false
        return await withCheckedContinuation { cont in
            SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config) { output, _ in
                cont.resume(returning: output?.sdrImage)
            }
        }
    }
}
