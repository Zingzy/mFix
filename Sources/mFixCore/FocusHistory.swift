import AppKit
import ApplicationServices

/// Most-recently-focused order of windows, fed by app activation and one AX observer per
/// app. z-order is only the starting guess: activating an app from the Dock raises all of
/// its windows, which is not what Alt+Tab order means.
final class FocusHistory {
    static let shared = FocusHistory()

    private var stamps: [CGWindowID: UInt64] = [:]
    private var clock: UInt64 = 0
    private var watchers: [pid_t: AXWatcher] = [:]

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.observe(app)
            self?.touchFocused(of: app.processIdentifier)
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.watchers[app.processIdentifier] = nil
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular { observe(app) }
        if let front = NSWorkspace.shared.frontmostApplication { touchFocused(of: front.processIdentifier) }
    }

    /// Told after every focus change, for features that react to it (Always on Top).
    var onFocus: ((CGWindowID) -> Void)?

    func touch(_ id: CGWindowID) {
        guard id != 0 else { return }
        clock += 1
        stamps[id] = clock
        onFocus?(id)
    }

    func stamp(_ id: CGWindowID) -> UInt64? { stamps[id] }

    private func touchFocused(of pid: pid_t) {
        let app = AXUIElementCreateApplication(pid)
        if let w: AXUIElement = app.attr(kAXFocusedWindowAttribute) {
            var id: CGWindowID = 0
            _AXUIElementGetWindow(w, &id)
            touch(id)
        }
    }

    private func observe(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard watchers[pid] == nil, pid != ProcessInfo.processInfo.processIdentifier,
              let watcher = AXWatcher(pid: pid, mode: .defaultMode, { id, _ in FocusHistory.shared.touch(id) }) else { return }
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        watcher.watch(appElement, [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification])
        watchers[pid] = watcher
    }
}

extension FocusHistory: Feature {}
