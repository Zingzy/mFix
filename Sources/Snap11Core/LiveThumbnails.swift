import AppKit

/// Keeps the thumbnails of a visible panel live: while it is open, the windows that are on
/// screen are captured again at card size a few times a second, one round at a time.
/// Minimized windows and windows on other Spaces can't change visibly and keep their
/// snapshot. Nothing runs while no panel is open.
@MainActor
final class LiveThumbnails {
    private let interval: TimeInterval = 0.33
    private var timer: Timer?
    private var busy = false
    private var windows: [AXWindow] = []
    private var points: CGFloat = 300
    private var onImage: ((CGWindowID, CGImage) -> Void)?

    func start(_ windows: [AXWindow], points: CGFloat, onImage: @escaping (CGWindowID, CGImage) -> Void) {
        stop()
        guard Settings.liveThumbnails else { return }
        self.windows = windows
        self.points = points
        self.onImage = onImage
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        busy = false
        windows = []
        onImage = nil
    }

    private func tick() {
        guard !busy, let onImage else { return }
        let onScreen = Set((CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []).compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        let live = windows.filter { onScreen.contains($0.id) }
        guard !live.isEmpty else { return }
        busy = true
        Thumbnails.shared.capture(live, points: points, done: { [weak self] in self?.busy = false }, onImage: onImage)
    }
}
