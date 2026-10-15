import AppKit

/// The windows on the current Space, most recently focused first. Minimized and hidden
/// windows go last, matching Windows, where minimizing sends a window to the end of the
/// Alt+Tab list. Windows never focused since launch fall back to z-order.
enum WindowList {
    static func currentSpace(excluding: Set<CGWindowID> = []) -> [AXWindow] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var zOrder: [CGWindowID] = []
        var pids: [pid_t] = []
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID else { continue }
            zOrder.append(id)
            if !pids.contains(pid) { pids.append(pid) }
        }

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != ownPID
        }
        for app in apps where !pids.contains(app.processIdentifier) { pids.append(app.processIdentifier) }

        let space = SkyLight.activeSpace
        var visible: [CGWindowID: AXWindow] = [:]
        var tail: [AXWindow] = []
        for pid in pids {
            let hidden = NSRunningApplication(processIdentifier: pid)?.isHidden ?? false
            for w in AXWindow.windows(of: pid) where w.id != 0 && w.isStandard && !excluding.contains(w.id) {
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
    static func allSpaces() -> [AXWindow] {
        let here = currentSpace()
        let known = Set(here.map(\.id))
        let own = ProcessInfo.processInfo.processIdentifier
        let regular = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        var elsewhere: [AXWindow] = []
        // AX lists only this Space's windows, but an app's main and focused window come back
        // from any Space. With that element the focus can raise it, which is what makes macOS
        // follow to its Space for apps like Discord where fronting the process alone doesn't.
        var reachable: [pid_t: [CGWindowID: AXUIElement]] = [:]
        func element(pid: pid_t, id: CGWindowID) -> AXUIElement? {
            if reachable[pid] == nil {
                let app = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(app, 0.25)
                var found: [CGWindowID: AXUIElement] = [:]
                for name in [kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
                    guard let e: AXUIElement = app.attr(name) else { continue }
                    var wid: CGWindowID = 0
                    _AXUIElementGetWindow(e, &wid)
                    found[wid] = e
                }
                reachable[pid] = found
            }
            return reachable[pid]?[id]
        }
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let id = w[kCGWindowNumber as String] as? CGWindowID, !known.contains(id),
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != own, regular.contains(pid),
                  (w[kCGWindowAlpha as String] as? Double ?? 0) > 0,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: b), frame.width >= 100, frame.height >= 100,
                  !SkyLight.spaces(for: id).isEmpty, SkyLight.isOrderedIn(id) else { continue }
            if let e = element(pid: pid, id: id) {
                elsewhere.append(AXWindow(element: e, pid: pid))
            } else {
                elsewhere.append(AXWindow(offSpace: id, pid: pid, title: w[kCGWindowName as String] as? String ?? "", frame: frame))
            }
        }
        let history = FocusHistory.shared
        let visibleHere = here.filter { !$0.isMinimized && !($0.app?.isHidden ?? false) }
        let tail = here.filter { $0.isMinimized || ($0.app?.isHidden ?? false) }
        let stamped = (visibleHere + elsewhere).filter { history.stamp($0.id) != nil }
            .sorted { history.stamp($0.id)! > history.stamp($1.id)! }
        let rest = (visibleHere + elsewhere).filter { history.stamp($0.id) == nil }
        return stamped + rest + tail
    }
}
