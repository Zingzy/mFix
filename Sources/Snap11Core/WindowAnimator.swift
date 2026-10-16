import AppKit

/// Slides a window to its snap frame the way Windows does, over about 200 ms with an ease-out.
/// Steps follow the clock, so a slow app gets fewer steps rather than a longer animation.
@MainActor
final class WindowAnimator {
    static let shared = WindowAnimator()

    private struct Run {
        let window: AXWindow
        let from: CGRect
        let to: CGRect
        let start: Date
        let done: (CGRect) -> Void
    }

    private let duration: TimeInterval = 0.2
    private var runs: [CGWindowID: Run] = [:]
    private var timer: Timer?

    func animate(_ window: AXWindow, to target: CGRect, done: @escaping (CGRect) -> Void) {
        finish(window)
        let from = window.frame
        guard Settings.animate, from.width > 0, !from.isClose(to: target, tolerance: 2) else {
            window.setFrame(target)
            done(window.frame)
            return
        }
        runs[window.id] = Run(window: window, from: from, to: target, start: Date(), done: done)
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
        }
    }

    /// Ends a window's animation at once, at its target; called before acting on it again.
    func finish(_ window: AXWindow) {
        guard let run = runs.removeValue(forKey: window.id) else { return }
        run.window.setFrame(run.to)
        run.done(run.window.frame)
    }

    private func tick() {
        let now = Date()
        for (id, run) in runs {
            let t = min(1, now.timeIntervalSince(run.start) / duration)
            if t >= 1 {
                runs[id] = nil
                run.window.setFrame(run.to)
                run.done(run.window.frame)
                continue
            }
            let e = 1 - pow(1 - t, 3)
            func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { (a + (b - a) * e).rounded() }
            run.window.setFrameQuickly(CGRect(x: mix(run.from.minX, run.to.minX), y: mix(run.from.minY, run.to.minY),
                                              width: mix(run.from.width, run.to.width), height: mix(run.from.height, run.to.height)))
        }
        if runs.isEmpty {
            timer?.invalidate()
            timer = nil
        }
    }
}
