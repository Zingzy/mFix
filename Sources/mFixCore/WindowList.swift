import AppKit

/// The windows on the current Space, most recently focused first. Minimized and hidden
/// windows go last, matching Windows, where minimizing sends a window to the end of the
/// Alt+Tab list. Windows never focused since launch fall back to z-order.
enum WindowList {
    /// Set by the render check: every other app's windows are left out.
    static var allowed: Set<pid_t>?

    /// The topmost ordinary window of another app under `p` (AX coordinates), skipping
    /// menus, panels, the menu bar and invisible windows above it.
    static func windowAt(_ p: CGPoint) -> (id: CGWindowID, pid: pid_t, bounds: CGRect)? {
        guard let w = WindowInfo.onScreen.first(where: { $0.bounds.contains(p) && $0.layer == 0 && $0.alpha != 0 }),
              w.pid != ProcessInfo.processInfo.processIdentifier else { return nil }
        return (w.id, w.pid, w.bounds)
    }

    /// `only`: just this app's windows, which skips asking every other app.
    static func currentSpace(excluding: Set<CGWindowID> = [], only: pid_t? = nil) -> [AXWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var zOrder: [CGWindowID] = []
        var pids: [pid_t] = []
        for w in WindowInfo.onScreen where w.layer == 0 && w.pid != ownPID {
            zOrder.append(w.id)
            if !pids.contains(w.pid) { pids.append(w.pid) }
        }

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID
        }
        for app in apps where !pids.contains(app.processIdentifier) { pids.append(app.processIdentifier) }
        if let only { pids = pids.filter { $0 == only } }
        if let allowed { pids = pids.filter(allowed.contains) }

        let space = SkyLight.activeSpace
        var visible: [CGWindowID: AXWindow] = [:]
        var tail: [AXWindow] = []
        let listed = AXWindow.windows(of: pids, wait: 0.08)
        for pid in pids {
            let hidden = NSRunningApplication(processIdentifier: pid)?.isHidden ?? false
            for w in listed[pid] ?? [] where w.id != 0 && w.isStandard && !excluding.contains(w.id) {
                if zOrder.contains(w.id) {
                    visible[w.id] = w
                } else if w.isMinimized || hidden {
                    let spaces = SkyLight.spaces(for: w.id)
                    if spaces.isEmpty || spaces.contains(space) { tail.append(w) }
                }
            }
        }
        let history = FocusHistory.shared
        func byRecency(_ list: [AXWindow]) -> [AXWindow] {
            list.enumerated().sorted { a, b in
                switch (history.stamp(a.element.id), history.stamp(b.element.id)) {
                case let (x?, y?): return x > y
                case (.some, nil): return true
                case (nil, .some): return false
                case (nil, nil): return a.offset < b.offset
                }
            }.map(\.element)
        }
        return byRecency(zOrder.compactMap { visible[$0] }) + byRecency(tail)
    }

    /// Every Space, the way Windows lists windows "On all desktops". This Space's windows
    /// come from Accessibility; the rest from WindowServer, kept only if they belong to a
    /// Space and are ordered in, which drops menu bar strips, offscreen helpers and windows
    /// an app closed but kept alive in the Dock.
    static func allSpaces(only: pid_t? = nil) -> [AXWindow] {
        let here = currentSpace(only: only)
        let known = Set(here.map(\.id))
        let own = ProcessInfo.processInfo.processIdentifier
        let regular = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        var elsewhere: [AXWindow] = []
        for w in WindowInfo.list([.optionAll, .excludeDesktopElements]) {
            guard w.layer == 0, !known.contains(w.id), w.pid != own, regular.contains(w.pid), only == nil || only == w.pid,
                  allowed?.contains(w.pid) ?? true,
                  w.alpha > 0, w.bounds.width >= 100, w.bounds.height >= 100,
                  !SkyLight.spaces(for: w.id).isEmpty, SkyLight.isOrderedIn(w.id) else { continue }
            if let e = RemoteWindows.shared.element(for: w.id) {
                elsewhere.append(AXWindow(element: e, pid: w.pid))
            } else {
                elsewhere.append(AXWindow(offSpace: w.id, pid: w.pid, title: w.name ?? "", frame: w.bounds))
            }
        }
        let unreached = Dictionary(grouping: elsewhere.filter { !$0.hasElement }, by: \.pid)
        for (pid, windows) in unreached { RemoteWindows.shared.prefetch(pid: pid, ids: windows.map(\.id)) }
        let history = FocusHistory.shared
        let visibleHere = here.filter { !$0.isMinimized && !($0.app?.isHidden ?? false) }
        let tail = here.filter { $0.isMinimized || ($0.app?.isHidden ?? false) }
        let stamped = (visibleHere + elsewhere).filter { history.stamp($0.id) != nil }
            .sorted { history.stamp($0.id)! > history.stamp($1.id)! }
        let rest = (visibleHere + elsewhere).filter { history.stamp($0.id) == nil }
        return stamped + rest + tail
    }
}

/// One window as WindowServer lists it, front to back; bounds in AX coordinates.
struct WindowInfo {
    let id: CGWindowID
    let pid: pid_t
    let layer: Int
    let alpha: Double
    let bounds: CGRect
    let name: String?
    let owner: String?

    static var onScreen: [WindowInfo] { list([.optionOnScreenOnly, .excludeDesktopElements]) }

    static func list(_ options: CGWindowListOption, relativeTo window: CGWindowID = kCGNullWindowID) -> [WindowInfo] {
        (CGWindowListCopyWindowInfo(options, window) as? [[String: Any]] ?? []).compactMap(WindowInfo.init)
    }

    init?(_ row: [String: Any]) {
        guard let id = row[kCGWindowNumber as String] as? CGWindowID, let pid = row[kCGWindowOwnerPID as String] as? pid_t,
              let b = row[kCGWindowBounds as String] as? NSDictionary, let bounds = CGRect(dictionaryRepresentation: b) else { return nil }
        self.id = id
        self.pid = pid
        self.bounds = bounds
        layer = row[kCGWindowLayer as String] as? Int ?? 0
        alpha = row[kCGWindowAlpha as String] as? Double ?? 1
        name = row[kCGWindowName as String] as? String
        owner = row[kCGWindowOwnerName as String] as? String
    }
}
