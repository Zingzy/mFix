import AppKit

/// `Snap11 --snap-check`: starts a second copy of Snap11 that shows a plain window, runs a
/// Win+Arrow sequence on it through the real engine, and prints where each step left it
/// next to where the Windows table says it goes. Exits non-zero on any mismatch.
@MainActor
public enum SnapCheck {
    public static func showTestWindow() {
        NSApp.setActivationPolicy(.regular)
        let w = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 600, height: 400),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = "Snap11 check"
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        objc_setAssociatedObject(NSApp!, "testWindow", w, .OBJC_ASSOCIATION_RETAIN)
    }

    public static func run() {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--test-window"]
        try? child.run()
        defer { child.terminate() }
        var window: AXWindow?
        for _ in 0..<40 where window == nil {
            usleep(100_000)
            window = AXWindow.windows(of: child.processIdentifier).first(where: { $0.isStandard })
        }
        guard let window else { print("test window never appeared"); exit(1) }
        let screen = Geo.screen(containing: window.frame)
        let work = Geo.workArea(screen)
        let start = window.frame
        print("test window", start, "work area", work)
        let steps: [(Arrow, String, CGRect)] = [
            (.left, "left half", Zone.left.frame(in: work)),
            (.up, "top-left quarter", Zone.topLeft.frame(in: work)),
            (.right, "top-right quarter", Zone.topRight.frame(in: work)),
            (.down, "right half", Zone.right.frame(in: work)),
            (.left, "restored", start),
            (.right, "right half", Zone.right.frame(in: work)),
            (.up, "top-right quarter", Zone.topRight.frame(in: work)),
            (.up, "maximized", work),
            (.down, "restored", start),
        ]
        var failures = 0
        for (arrow, name, expected) in steps {
            SnapEngine.shared.handle(arrow, window: window)
            usleep(200_000)
            let f = window.frame
            let ok = f.isClose(to: expected, tolerance: 2)
            if !ok { failures += 1 }
            print(ok ? "ok  " : "FAIL", arrow, "->", name, "got", f, ok ? "" : "want \(expected)")
        }
        SnapEngine.shared.handle(.down, window: window)
        usleep(600_000)
        let minimized = window.isMinimized
        print(minimized ? "ok   down -> minimized" : "FAIL down -> minimized")
        if !minimized { failures += 1 }
        print(failures == 0 ? "all steps match" : "\(failures) steps off")
        child.terminate()
        exit(failures == 0 ? 0 : 1)
    }
}
