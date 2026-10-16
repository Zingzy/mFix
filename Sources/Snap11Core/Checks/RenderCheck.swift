import AppKit
import SwiftUI

/// `Snap11 --render <dir>`: builds the switcher, Snap Assist and the layouts flyout from the
/// real windows on this Space without showing them, and writes each as a PNG. Registers no
/// hotkeys and leaves the system Cmd+Tab alone.
@MainActor
public enum RenderCheck {
    private static var settingsHosts: [NSHostingView<SettingsView>] = []

    public static func run(into dir: String) {
        OverlayPanel.offscreen = true
        FocusHistory.shared.start()
        let screen = NSScreen.screens[0]
        let windows = WindowList.currentSpace()
        print("windows on this Space:", windows.count)
        for w in windows.prefix(12) { print(" ", w.id, w.app?.localizedName ?? "?", "|", w.title.prefix(40), w.isMinimized ? "(min)" : "") }

        if ProcessInfo.processInfo.environment["SNAP11_LIST_ALL"] != nil {
            for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
                for w in AXWindow.windows(of: app.processIdentifier) {
                    print("  all:", w.id, app.localizedName ?? "?", w.subrole ?? "-", "fs=\(w.isFullScreen)", "min=\(w.isMinimized)",
                          "hidden=\(app.isHidden)", "spaces=\(SkyLight.spaces(for: w.id))", "active=\(SkyLight.activeSpace)")
                }
            }
        }
        if ProcessInfo.processInfo.environment["SNAP11_LIST_ALL"] != nil {
            let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
            for w in info where (w[kCGWindowLayer as String] as? Int) == 0 {
                let id = w[kCGWindowNumber as String] as? CGWindowID ?? 0
                let b = CGRect(dictionaryRepresentation: (w[kCGWindowBounds as String] as? NSDictionary) ?? [:]) ?? .zero
                print("  cg:", id, w[kCGWindowOwnerName as String] ?? "?", "|", w[kCGWindowName as String] ?? "-",
                      "alpha=\(w[kCGWindowAlpha as String] ?? 0)", "on=\(w[kCGWindowIsOnscreen as String] ?? 0)",
                      "size=\(Int(b.width))x\(Int(b.height))", "spaces=\(SkyLight.spaces(for: id))")
            }
        }
        let all = WindowList.allSpaces()
        print("windows on all Spaces:", all.count)
        for w in all { print(" ", w.id, w.app?.localizedName ?? "?", "|", w.title.prefix(40), w.hasElement ? "" : "(no AX element)") }
        Switcher.shared.windows = all
        Switcher.shared.show()
        if let front = windows.first {
            SnapAssist.shared.build(zone: .right, screen: screen, candidates: all.filter { $0.id != front.id })
            let anchor = front.fullScreenButtonFrame ?? CGRect(x: 200, y: 40, width: 14, height: 14)
            LayoutFlyout.shared.open(for: front, anchor: anchor, keyboard: true)
        }
        for tab in 0..<5 {
            let host = NSHostingView(rootView: SettingsView(tab: tab))
            host.frame = NSRect(x: 0, y: 0, width: 520, height: 440)
            let w = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            w.contentView = host
            settingsHosts.append(host)
        }
        // Thumbnails arrive asynchronously; give them a moment before drawing.
        onMain(after: 2.5) {
            write(Switcher.shared.panel, to: "\(dir)/switcher.png")
            write(SnapAssist.shared.panel, to: "\(dir)/snap-assist.png")
            write(LayoutFlyout.shared.panel, to: "\(dir)/flyout.png")
            for (i, host) in settingsHosts.enumerated() {
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/settings-\(i).png"))
            }
            NSApp.terminate(nil)
        }
    }

    private static func write(_ panel: NSPanel, to path: String) {
        guard let view = panel.contentView, view.bounds.width > 0 else { print("empty:", path); return }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale: CGFloat = 2
        let w = Int(view.bounds.width * scale), h = Int(view.bounds.height * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(NSColor(white: Theme.dark ? 0.16 : 0.86, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.scaleBy(x: scale, y: scale)
        if view.layer?.isGeometryFlipped == true {
            ctx.translateBy(x: 0, y: view.bounds.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        view.layer?.render(in: ctx)
        guard let image = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("wrote", path, view.bounds.size)
    }
}
