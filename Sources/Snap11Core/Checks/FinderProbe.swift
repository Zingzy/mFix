import AppKit

/// `Snap11 --finder-probe`: does a posted two-modifier chord reach Finder? Posts Cmd+Shift+G
/// straight at Finder, with and without a modifier flagsChanged first, and reports.
@MainActor
public enum FinderProbe {
    public static func run() {
        CheckGuard.begin()
        let finderApp = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first!
        let ax = AXUIElementCreateApplication(finderApp.processIdentifier)
        func role() -> String {
            guard let e: AXUIElement = ax.attr(kAXFocusedUIElementAttribute) else { return "-" }
            return e.attr(kAXRoleAttribute) ?? "-"
        }
        func send(_ e: CGEvent?) {
            // Keys only ever go to Finder, never to whatever else came to the front.
            guard Check.frontPID() == finderApp.processIdentifier else {
                print("ABORT: Finder is not in front; no key sent")
                exit(2)
            }
            CheckGuard.poll()
            CheckGuard.mark(e)
            e?.post(tap: .cgSessionEventTap)
        }
        func post(_ code: CGKeyCode, _ flags: CGEventFlags, source: CGEventSource?, withFlagsChanged: Bool) {
            if withFlagsChanged, let f = CGEvent(source: source) {
                f.type = .flagsChanged
                f.flags = flags
                send(f)
            }
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
                e?.flags = flags
                send(e)
            }
            if withFlagsChanged, let f = CGEvent(source: source) {
                f.type = .flagsChanged
                f.flags = []
                send(f)
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
                for down in [true, false] { send(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)) }
                usleep(500_000)
            }
        }
        try? FileManager.default.removeItem(at: root)
        exit(0)
    }
}
