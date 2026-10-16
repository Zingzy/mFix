import AppKit

/// The Dock's app icons in order, read through Accessibility: frame (AX coordinates) and app.
enum DockItems {
    struct Item {
        let frame: CGRect
        let url: URL
        let title: String

        var runningApp: NSRunningApplication? {
            NSWorkspace.shared.runningApplications.first { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
        }
    }

    static func read() -> [Item] {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return [] }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var items: [Item] = []
        for list in (app.attr(kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            for item in (list.attr(kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                guard (item.attr(kAXSubroleAttribute) as String?) == "AXApplicationDockItem",
                      let url: URL = item.attr(kAXURLAttribute),
                      let pos = item.point(kAXPositionAttribute), let size = item.size(kAXSizeAttribute) else { continue }
                items.append(Item(frame: CGRect(origin: pos, size: size), url: url, title: item.attr(kAXTitleAttribute) ?? ""))
            }
        }
        return items
    }
}

/// Win+1 to 9: the nth app in the Dock. Not running: open it. Running but not in front: bring
/// back its most recent window. Already in front: step to its next window, or minimize it
/// when it has only one, as clicking the active taskbar button does on Windows.
@MainActor
enum DockApps {
    static func activate(_ n: Int) {
        let items = DockItems.read()
        guard items.indices.contains(n - 1) else { return }
        let item = items[n - 1]
        guard let app = item.runningApp else {
            NSWorkspace.shared.openApplication(at: item.url, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        let windows = WindowList.allSpaces().filter { $0.pid == app.processIdentifier }
        guard !windows.isEmpty else {
            app.activate(options: [])
            return
        }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
        let visible = windows.filter { !$0.isMinimized }
        if front, let current = AXWindow.focused(), !current.isMinimized {
            if visible.count <= 1 {
                current.minimize()
                return
            }
            guard let next = WindowCycle.next(of: visible, pid: app.processIdentifier) else { return }
            next.focus()
            FocusHistory.shared.touch(next.id)
            return
        }
        let target = windows[0]
        target.focus()
        FocusHistory.shared.touch(target.id)
    }
}
