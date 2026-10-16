import AppKit

/// `Snap11 --finder-probe`: does a posted two-modifier chord reach Finder? Posts Cmd+Shift+G
/// straight at Finder, with and without a modifier flagsChanged first, and reports.
@MainActor
public enum FinderProbe {
    public static func run() {
        let finderApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first!
        let ax = AXUIElementCreateApplication(finderApp.processIdentifier)
        func role() -> String {
            guard let e: AXUIElement = ax.attr(kAXFocusedUIElementAttribute) else { return "-" }
            return e.attr(kAXRoleAttribute) ?? "-"
        }
        func post(_ code: CGKeyCode, _ flags: CGEventFlags, source: CGEventSource?, withFlagsChanged: Bool) {
            if withFlagsChanged, let f = CGEvent(source: source) {
                f.type = .flagsChanged
                f.flags = flags
                f.post(tap: .cgSessionEventTap)
            }
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
                e?.flags = flags
                e?.post(tap: .cgSessionEventTap)
            }
            if withFlagsChanged, let f = CGEvent(source: source) {
                f.type = .flagsChanged
                f.flags = []
                f.post(tap: .cgSessionEventTap)
            }
        }
        let root = URL(fileURLWithPath: "/tmp/snap11-finder-probe")
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(root)
        usleep(1_500_000)
        for (name, src, fc) in [("nil source", nil as CGEventSource?, false), ("hid source", CGEventSource(stateID: .hidSystemState), false),
                                ("nil source + flagsChanged", nil, true)] {
            post(5, [.maskCommand, .maskShift], source: src, withFlagsChanged: fc)
            usleep(800_000)
            let r = role()
            print(name, "-> focus", r)
            if r == "AXTextField" {
                for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.post(tap: .cgSessionEventTap) }
                usleep(500_000)
            }
        }
        try? FileManager.default.removeItem(at: root)
        exit(0)
    }
}
