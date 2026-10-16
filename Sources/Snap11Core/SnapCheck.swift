import AppKit

/// `Snap11 --snap-check`: starts a second copy of Snap11 that shows a plain window, runs a
/// Win+Arrow sequence on it through the real engine, and prints where each step left it
/// next to where the Windows table says it goes. Exits non-zero on any mismatch.
@MainActor
public enum SnapCheck {
    /// `count` windows in one process, like an app with several windows open.
    public static func showTestWindow(count: Int = 1) {
        NSApp.setActivationPolicy(.regular)
        let windows = (0..<count).map { i -> NSWindow in
            let w = NSWindow(contentRect: NSRect(x: 300 + i * 40, y: 300 - i * 40, width: 600, height: 400),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = count == 1 ? "Snap11 check" : "Snap11 check \(i + 1)"
            w.contentView = DragSourceView()
            w.makeKeyAndOrderFront(nil)
            return w
        }
        NSApp.activate()
        objc_setAssociatedObject(NSApp!, "testWindow", windows, .OBJC_ASSOCIATION_RETAIN)
    }

    /// `Snap11 --minimize-check`: two throwaway windows, minimize all but one, then toggle back.
    public static func minimizeCheck() {
        let children = (0..<2).map { _ -> Process in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            p.arguments = ["--test-window"]
            try? p.run()
            return p
        }
        defer { children.forEach { $0.terminate() } }
        var windows: [AXWindow] = []
        for _ in 0..<40 where windows.count < 2 {
            usleep(100_000)
            windows = children.compactMap { c in AXWindow.windows(of: c.processIdentifier).first(where: { $0.isStandard }) }
        }
        guard windows.count == 2 else { print("test windows never appeared"); exit(1) }
        let (keep, other) = (windows[0], windows[1])
        MinimizeAll.shared.toggle(keepActive: true, among: windows, active: keep)
        usleep(900_000)
        let first = other.isMinimized && !keep.isMinimized
        print(first ? "ok  " : "FAIL", "first press minimized the other window and kept the active one")
        MinimizeAll.shared.toggle(keepActive: true, among: windows, active: keep)
        usleep(900_000)
        let second = !other.isMinimized && !keep.isMinimized
        print(second ? "ok  " : "FAIL", "second press brought it back")
        MinimizeAll.shared.toggle(keepActive: false, among: windows, active: keep)
        usleep(900_000)
        let third = other.isMinimized && keep.isMinimized
        print(third ? "ok  " : "FAIL", "show desktop minimized both")
        MinimizeAll.shared.toggle(keepActive: false, among: windows, active: keep)
        usleep(900_000)
        let fourth = !other.isMinimized && !keep.isMinimized
        print(fourth ? "ok  " : "FAIL", "pressing again restored both")
        children.forEach { $0.terminate() }
        exit(first && second && third && fourth ? 0 : 1)
    }

    public static func run() {
        Settings.register()
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

/// The test window's content: dragging anywhere in it starts a file drag, like dragging a
/// document out of Finder. It accepts no drops, so a drop back on it goes nowhere.
final class DragSourceView: NSView, NSDraggingSource {
    static let file: URL = {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snap11-drag-test.txt")
        try? "Snap11 drag test".write(to: url, atomically: true, encoding: .utf8)
        return url
    }()

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: DragSourceView.file as NSURL)
        item.setDraggingFrame(NSRect(x: 0, y: 0, width: 32, height: 32), contents: NSWorkspace.shared.icon(forFile: DragSourceView.file.path))
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
