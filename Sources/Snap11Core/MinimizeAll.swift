import AppKit

/// Win+Home (minimize every window on this Space but the active one) and Win+D (show the
/// desktop). Each is a toggle: the second press brings back the windows the first one
/// minimized, if they are still minimized.
@MainActor
final class MinimizeAll {
    static let shared = MinimizeAll()

    private var minimized: [AXWindow] = []
    private var refocus: AXWindow?

    func toggle(keepActive: Bool, among candidates: [AXWindow]? = nil, active given: AXWindow? = nil) {
        if restoreIfPending() { return }
        let active = given ?? AXWindow.focused()
        let others = (candidates ?? WindowList.currentSpace()).filter { w in
            !w.isMinimized && !(w.app?.isHidden ?? false) && !w.isFullScreen && !(keepActive && w == active)
        }
        guard !others.isEmpty else { return }
        refocus = active
        minimized = others
        for w in others { w.minimize() }
    }

    private func restoreIfPending() -> Bool {
        let pending = minimized.filter(\.isMinimized)
        let target = refocus
        minimized = []
        refocus = nil
        guard !pending.isEmpty else { return false }
        for w in pending.reversed() { w.unminimize() }
        target?.focus()
        return true
    }
}
