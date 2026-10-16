import AppKit
import ScreenCaptureKit

/// Window thumbnails. On-screen windows go through ScreenCaptureKit's one-shot screenshot
/// (the macOS 26 call; short capture streams leaked WindowServer memory). Minimized and
/// hidden windows go through the private capture call. The last image per window is kept.
@MainActor
final class Thumbnails {
    static let shared = Thumbnails()

    private var cache: [CGWindowID: CGImage] = [:]
    private var content: [CGWindowID: SCWindow] = [:]

    func cached(_ id: CGWindowID) -> CGImage? { cache[id] }

    /// Screen Recording is granted when WindowServer hands out other apps' window titles;
    /// CGPreflightScreenCaptureAccess caches its first answer for the life of the process.
    static var permitted: Bool {
        let own = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return info.contains {
            ($0[kCGWindowOwnerPID as String] as? pid_t) != own && ($0[kCGWindowLayer as String] as? Int) == 0
                && !(($0[kCGWindowName as String] as? String) ?? "").isEmpty
        }
    }

    private func scWindows(for ids: [CGWindowID]) async -> [CGWindowID: SCWindow] {
        if ids.contains(where: { content[$0] == nil }),
           let shareable = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) {
            content = Dictionary(shareable.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { a, _ in a })
        }
        return content
    }

    /// Calls back per window as images arrive, so cards show the cached image first and
    /// swap in the fresh one. `points` is the card's long side.
    func capture(_ windows: [AXWindow], points: CGFloat, onImage: @escaping (CGWindowID, CGImage) -> Void) {
        let ids = windows.map(\.id)
        let offscreen = Set(windows.filter { $0.isMinimized || ($0.app?.isHidden ?? false) }.map(\.id))
        Task { @MainActor in
            let known = await scWindows(for: ids.filter { !offscreen.contains($0) })
            for id in ids {
                // ScreenCaptureKit only captures windows on screen; minimized, hidden and
                // other-Space windows go through the private capture.
                if offscreen.contains(id) || !(known[id]?.isOnScreen ?? false) {
                    if let image = SkyLight.captureWindow(id) {
                        cache[id] = image
                        onImage(id, image)
                    }
                    continue
                }
                let window = known[id]!
                let config = SCScreenshotConfiguration()
                // Sharp on this display's real pixel ratio, whatever the Displays scaling.
                let backing = NSScreen.screens.first { Geo.flip($0.frame).intersects(window.frame) }?.backingScaleFactor ?? 2
                let scale = min(1, points / max(window.frame.width, window.frame.height, 1)) * backing
                config.width = max(1, Int(window.frame.width * scale))
                config.height = max(1, Int(window.frame.height * scale))
                config.showsCursor = false
                config.ignoreShadows = true
                let filter = SCContentFilter(desktopIndependentWindow: window)
                SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: config) { output, _ in
                    guard let image = output?.sdrImage else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            Thumbnails.shared.cache[id] = image
                            onImage(id, image)
                        }
                    }
                }
            }
        }
    }
}
