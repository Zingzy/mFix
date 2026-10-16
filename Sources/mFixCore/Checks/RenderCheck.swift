import AppKit
import SwiftUI

/// `mFix --render <dir>`: builds the switcher, Snap Assist, the layouts flyout, the Dock cards
/// and the settings window from the real windows on this Space without showing them, and
/// writes each as a PNG. Registers no hotkeys and leaves the system Cmd+Tab alone.
///
/// MFIX_RENDER_PIDS (comma separated) leaves every other app's windows out and lets the render
/// snap the front one to the left half, MFIX_RENDER_WALLPAPER draws over that image instead of
/// the desktop picture, and MFIX_RENDER_APPEARANCE (light or dark) overrides the system's.
@MainActor
public enum RenderCheck {
    private static var settingsWindows: [(name: String, window: NSWindow)] = []
    private static var scenes: [(name: String, window: NSWindow)] = []
    private static var frontPicture: CGImage?

    public static func run(into dir: String) {
        OverlayPanel.offscreen = true
        FocusHistory.shared.start()
        let env = ProcessInfo.processInfo.environment
        let screen = NSScreen.screens[0]
        if let look = env["MFIX_RENDER_APPEARANCE"] { NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua) }
        if let pids = env["MFIX_RENDER_PIDS"] { WindowList.allowed = Set(pids.split(separator: ",").compactMap { pid_t($0) }) }
        if let path = env["MFIX_RENDER_WALLPAPER"] {
            guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                print("can't read the wallpaper at", path)
                exit(1)
            }
            Wallpaper.cache[screen.displayID] = image
        }
        let look = Theme.dark ? "dark" : "light"
        let windows = WindowList.currentSpace()
        print("windows on this Space:", windows.count)
        for w in windows.prefix(12) { print(" ", w.id, w.app?.localizedName ?? "?", "|", w.title.prefix(40), w.isMinimized ? "(min)" : "") }

        if env["MFIX_LIST_ALL"] != nil {
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                for w in AXWindow.windows(of: app.processIdentifier) {
                    print("  all:", w.id, app.localizedName ?? "?", w.subrole ?? "-", "fs=\(w.isFullScreen)", "min=\(w.isMinimized)",
                          "hidden=\(app.isHidden)", "spaces=\(SkyLight.spaces(for: w.id))", "active=\(SkyLight.activeSpace)")
                }
            }
            let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            for w in info where (w[kCGWindowLayer as String] as? Int) == 0 {
                let id = w[kCGWindowNumber as String] as? CGWindowID ?? 0
                let b = CGRect(dictionaryRepresentation: (w[kCGWindowBounds as String] as? NSDictionary) ?? [:]) ?? .zero
                print("  cg:", id, w[kCGWindowOwnerName as String] ?? "?", "|", w[kCGWindowName as String] ?? "-",
                      "alpha=\(w[kCGWindowAlpha as String] ?? 0)", "on=\(w[kCGWindowIsOnscreen as String] ?? 0)",
                      "size=\(Int(b.width))x\(Int(b.height))", "spaces=\(SkyLight.spaces(for: id))")
            }
        }
        if WindowList.allowed != nil && windows.count < WindowList.allSpaces().count {
            print("some of the windows are on another Space; stay on one Space while this runs")
            exit(1)
        }
        // The app with the most windows goes in front, so its Dock cards have several to show.
        let counts = Dictionary(grouping: windows.filter { !$0.isMinimized }, by: \.pid).mapValues(\.count)
        let front = windows.first { $0.pid == counts.max { $0.value < $1.value }?.key }
        if let front, WindowList.allowed != nil {
            takeTurns(windows, front: front)
            SnapEngine.shared.place(front, zone: .left, on: screen)
        }
        let all = WindowList.allSpaces()
        print("windows on all Spaces:", all.count)
        for w in all { print(" ", w.id, w.app?.localizedName ?? "?", "|", w.title.prefix(40), w.hasElement ? "" : "(no AX element)") }

        // After the app finishes launching, or the settings window's glass comes out dark.
        onMain(after: 0.5) {
            settings()
            Switcher.shared.windows = all
            Switcher.shared.show()
            if let front { showPanels(for: front, others: all.filter { $0.id != front.id }, screen: screen) }
            // Thumbnails arrive asynchronously; give them a moment before composing.
            onMain(after: 3.5) { finish(look, front: front, screen: screen, dir: dir) }
        }
    }

    /// Composes and writes once the front window's picture is in, asking for it again while not.
    private static func finish(_ look: String, front: AXWindow?, screen: NSScreen, dir: String, tries: Int = 10) {
        if let front, frontPicture == nil, tries > 0 {
            print("waiting for a picture of the front window")
            capturePicture(of: front)
            onMain(after: 0.5) { finish(look, front: front, screen: screen, dir: dir, tries: tries - 1) }
            return
        }
        compose(look, front: front, screen: screen)
        onMain(after: 0.5) { write(into: dir) }
    }

    /// The cards' live captures replace the cached thumbnail with a small one, so this keeps its own.
    private static func capturePicture(of window: AXWindow) {
        let f = window.frame
        Thumbnails.shared.capture([window], points: max(f.width, f.height)) { _, image in frontPicture = frontPicture ?? image }
    }

    private static func showPanels(for front: AXWindow, others: [AXWindow], screen: NSScreen) {
        SnapAssist.shared.build(zone: .right, screen: screen, candidates: others)
        let f = front.frame
        LayoutFlyout.shared.open(for: front, anchor: front.fullScreenButtonFrame ?? CGRect(x: f.minX + 60, y: f.minY + 12, width: 14, height: 14),
                                 keyboard: false)
        let url = front.app?.bundleURL?.standardizedFileURL
        if let icon = DockItems.read().first(where: { $0.url.standardizedFileURL == url })?.frame {
            _ = DockPreview.shared.show(front.pid, icon: icon)
        }
        capturePicture(of: front)
    }

    private static func compose(_ look: String, front: AXWindow?, screen: NSScreen) {
        let margin: CGFloat = 40
        let around = { (r: CGRect) in r.insetBy(dx: -margin, dy: -margin).intersection(screen.axFrame) }
        add("switcher-\(look)", [Switcher.shared.panel], windows: [], crop: around(Geo.flip(Switcher.shared.panel.frame)), screen: screen)
        guard let front else { return }
        if frontPicture == nil { print("no picture of the front window") }
        let pictures = frontPicture.map { [($0, front.frame)] } ?? []
        add("snap-assist-\(look)", [SnapAssist.shared.panel], windows: pictures, crop: screen.axFrame, screen: screen)
        // Out to the window's corner, so its green button shows above the flyout.
        let flyout = Geo.flip(LayoutFlyout.shared.panel.frame).union(CGRect(origin: front.frame.origin, size: .zero))
        add("layouts-\(look)", [LayoutFlyout.shared.panel], windows: pictures, crop: around(flyout), screen: screen)
        if DockPreview.shared.panel.contentView?.subviews.isEmpty == false {
            add("dock-\(look)", [DockPreview.shared.panel], windows: [], crop: around(Geo.flip(DockPreview.shared.panel.frame)), screen: screen)
        }
    }

    private static func write(into dir: String) {
        for (name, w) in settingsWindows + scenes {
            guard let image = SkyLight.captureWindow(CGWindowID(w.windowNumber)) else { print("no capture:", name); continue }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
            print("wrote", name, image.width, "x", image.height)
        }
        NSApp.terminate(nil)
    }

    /// Most recent first: `front`, then each app's windows taking turns, so neighbouring cards
    /// and the suggested layouts' icons come from different apps.
    private static func takeTurns(_ windows: [AXWindow], front: AXWindow) {
        var queues: [[AXWindow]] = []
        for w in [front] + windows.filter({ $0 != front }) {
            let app = w.app?.bundleIdentifier
            if let i = queues.firstIndex(where: { $0[0].app?.bundleIdentifier == app }) { queues[i].append(w) } else { queues.append([w]) }
        }
        var order: [AXWindow] = []
        while queues.contains(where: { !$0.isEmpty }) {
            for i in queues.indices where !queues[i].isEmpty { order.append(queues[i].removeFirst()) }
        }
        for w in order.reversed() { FocusHistory.shared.touch(w.id) }
    }

    /// Each section at the window's own size, and tall enough to show the whole page.
    private static func settings() {
        for (look, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for section in SettingsSection.allCases {
                for (suffix, height) in [("", SettingsWindow.size.height), ("-full", 1100)] {
                    let w = SettingsWindow.make(SettingsView(pinned: section))
                    w.appearance = NSAppearance(named: appearance)
                    w.setContentSize(NSSize(width: SettingsWindow.size.width, height: height))
                    orderInBelowDesktop(w)
                    settingsWindows.append(("settings-\(look)-\(section.rawValue)\(suffix)", w))
                }
            }
        }
    }

    /// Ordered in so the split view and its glass draw, but below the wallpaper.
    private static func orderInBelowDesktop(_ w: NSWindow) {
        w.level = NSWindow.Level(Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        w.ignoresMouseEvents = true
        w.orderFrontRegardless()
    }

    /// The panels' content where it sits on screen, over the wallpaper and the pictures of
    /// `windows`, in one window cut to `crop` (AX coordinates). Inside one window the glass
    /// blurs what really is behind it, which a capture of the panel alone can't show.
    private static func add(_ name: String, _ panels: [NSPanel], windows: [(CGImage, CGRect)], crop: CGRect, screen: NSScreen) {
        let w = NSWindow(contentRect: Geo.flip(crop), styleMask: .borderless, backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        let content = FlippedView(frame: NSRect(origin: .zero, size: crop.size))
        content.wantsLayer = true
        content.layer?.masksToBounds = true
        let wall = CALayer()
        wall.contents = Wallpaper.image(for: screen)
        wall.contentsGravity = .resizeAspectFill
        wall.frame = screen.axFrame.offsetBy(dx: -crop.minX, dy: -crop.minY)
        content.layer?.addSublayer(wall)
        for (image, frame) in windows {
            let l = CALayer()
            l.contents = image
            l.frame = frame.offsetBy(dx: -crop.minX, dy: -crop.minY)
            l.shadowOpacity = 0.45
            l.shadowRadius = 22
            l.shadowOffset = CGSize(width: 0, height: 14)
            content.layer?.addSublayer(l)
        }
        for panel in panels {
            guard let root = panel.contentView else { continue }
            panel.contentView = NSView()
            root.frame = Geo.flip(panel.frame).offsetBy(dx: -crop.minX, dy: -crop.minY)
            behindToWithin(root)
            if panel.hasShadow {
                root.wantsLayer = true
                root.layer?.shadowPath = CGPath(roundedRect: root.bounds, cornerWidth: 8, cornerHeight: 8, transform: nil)
                root.layer?.shadowOpacity = 0.3
                root.layer?.shadowRadius = 16
                root.layer?.shadowOffset = CGSize(width: 0, height: -6)
                root.layer?.masksToBounds = false
            }
            content.addSubview(root)
        }
        w.contentView = content
        w.appearance = NSApp.effectiveAppearance
        orderInBelowDesktop(w)
        scenes.append((name, w))
    }

    private static func behindToWithin(_ view: NSView) {
        if let v = view as? NSVisualEffectView, v.blendingMode == .behindWindow { v.blendingMode = .withinWindow }
        view.subviews.forEach(behindToWithin)
    }
}
