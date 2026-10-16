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

    /// A fresh image of each window now, then live ones until `stop`.
    func show(_ windows: [AXWindow], points: CGFloat, onImage: @escaping (CGWindowID, CGImage) -> Void) {
        Thumbnails.shared.capture(windows, points: points, onImage: onImage)
        start(windows, points: points, onImage: onImage)
    }

    func start(_ windows: [AXWindow], points: CGFloat, onImage: @escaping (CGWindowID, CGImage) -> Void) {
        stop()
        guard Settings.liveThumbnails.value else { return }
        self.windows = windows
        self.points = points
        self.onImage = onImage
        timer = Timer.onMain(after: interval, repeats: true) { [weak self] in self?.tick() }
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
        let onScreen = Set(WindowInfo.onScreen.map(\.id))
        let live = windows.filter { onScreen.contains($0.id) }
        guard !live.isEmpty else { return }
        busy = true
        Thumbnails.shared.capture(live, points: points, done: { [weak self] in self?.busy = false }, onImage: onImage)
    }
}
