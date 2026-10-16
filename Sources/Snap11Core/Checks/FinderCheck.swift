import AppKit

/// `Snap11 --finder-check`: drives the Explorer keys in a real Finder window on a scratch
/// folder in /tmp, and Win+1 for the first Dock app, checking the file system and Finder's
/// own state after each key. Needs a running Snap11 to own the keys.
@MainActor
public enum FinderCheck {
    private static let source = CGEventSource(stateID: .hidSystemState)

    /// The only windows a key may ever go to. On 2026-10-16 a run that printed FAIL for the
    /// scratch folder kept typing into whatever Finder window was in front, and Delete sent
    /// ~/wsp-work to the Trash. Every key now checks first and the run ends on a mismatch.
    private static let scratchTitles: Set<String> = ["snap11-finder-check", "alpha"]

    private static func key(_ code: Int64, _ flags: CGEventFlags = []) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let title = frontTitle
        guard front == "com.apple.finder", scratchTitles.contains(title) || focusedRole == "AXTextField" && scratchTitles.contains(lastScratchTitle) else {
            print("ABORT: front window is \"\(title)\" in \(front ?? "?"), not the scratch folder; no key sent")
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)
                CheckGuard.mark(e)
                e?.post(tap: .cghidEventTap)
            }
            exit(2)
        }
        if scratchTitles.contains(title) { lastScratchTitle = title }
        CheckGuard.poll()
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
            e?.flags = flags
            CheckGuard.mark(e)
            e?.post(tap: .cghidEventTap)
            usleep(40_000)
        }
    }

    private static func type(_ s: String) {
        let codes: [Character: Int64] = ["a": 0, "m": 46, "z": 6]
        for c in s { if let k = codes[c] { key(k) } }
    }

    nonisolated(unsafe) private static var lastScratchTitle = ""

    private static var finder: AXUIElement? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
            .map { AXUIElementCreateApplication($0.processIdentifier) }
    }

    private static var frontTitle: String {
        guard let w: AXUIElement = finder?.attr(kAXFocusedWindowAttribute) else { return "" }
        return w.attr(kAXTitleAttribute) ?? ""
    }

    private static var focusedRole: String {
        guard let e: AXUIElement = finder?.attr(kAXFocusedUIElementAttribute) else { return "" }
        return e.attr(kAXRoleAttribute) ?? ""
    }

    private static var sheetOpen: Bool {
        guard let w: AXUIElement = finder?.attr(kAXFocusedWindowAttribute) else { return false }
        let kids: [AXUIElement] = w.attr(kAXChildrenAttribute) ?? []
        return kids.contains { ($0.attr(kAXRoleAttribute) as String?) == "AXSheet" }
            || (w.attr(kAXSubroleAttribute) as String?) == "AXDialog"
    }

    public static func run() {
        CheckGuard.begin()
        let check = Check("finder check")
        let fm = FileManager.default
        let root = URL(fileURLWithPath: "/tmp/snap11-finder-check")
        try? fm.removeItem(at: root)
        try? fm.createDirectory(at: root.appendingPathComponent("alpha"), withIntermediateDirectories: true)
        fm.createFile(atPath: root.appendingPathComponent("move-me.txt").path, contents: Data("m".utf8))
        fm.createFile(atPath: root.appendingPathComponent("zz-trash-me.txt").path, contents: Data("z".utf8))
        defer {
            if let w: AXUIElement = finder?.attr(kAXFocusedWindowAttribute), frontTitle == "alpha" || frontTitle == "snap11-finder-check",
               let close: AXUIElement = w.attr(kAXCloseButtonAttribute) {
                AXUIElementPerformAction(close, kAXPressAction as CFString)
            }
            try? fm.removeItem(at: root)
            check.finish()
        }

        NSWorkspace.shared.open(root)
        for _ in 0..<30 where frontTitle != "snap11-finder-check" { usleep(100_000) }
        usleep(600_000)
        guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder", frontTitle == "snap11-finder-check" else {
            print("ABORT: Finder did not bring the scratch folder to the front (\(frontTitle)); no key sent")
            exit(2)
        }
        check(true, "Finder shows the scratch folder")

        type("z")
        usleep(300_000)
        key(51)
        usleep(900_000)
        check(!fm.fileExists(atPath: root.appendingPathComponent("zz-trash-me.txt").path), "Delete moved the selected file to the Trash")

        type("m")
        usleep(300_000)
        key(120)
        usleep(500_000)
        check(focusedRole == "AXTextField", "F2 started renaming (focus: \(focusedRole))")
        key(51)
        usleep(500_000)
        check(fm.fileExists(atPath: root.appendingPathComponent("move-me.txt").path) && focusedRole == "AXTextField",
              "Delete while renaming edits the name and leaves the file alone")
        key(53)
        usleep(400_000)

        type("m")
        usleep(300_000)
        key(7, .maskCommand)
        usleep(500_000)
        type("a")
        usleep(300_000)
        key(36)
        usleep(900_000)
        check(frontTitle == "alpha", "Enter opened the folder (window: \(frontTitle))")
        key(9, .maskCommand)
        usleep(1_200_000)
        check(fm.fileExists(atPath: root.appendingPathComponent("alpha/move-me.txt").path)
              && !fm.fileExists(atPath: root.appendingPathComponent("move-me.txt").path), "Cmd+X then Cmd+V moved the file")

        type("m")
        usleep(300_000)
        key(51, .maskShift)
        usleep(900_000)
        check(sheetOpen || focusedRole == "AXButton", "Shift+Delete asked before deleting for good (focus: \(focusedRole))")
        key(53)
        usleep(500_000)
        check(fm.fileExists(atPath: root.appendingPathComponent("alpha/move-me.txt").path), "cancelling it kept the file")

        key(37, .maskCommand)
        usleep(800_000)
        check(focusedRole == "AXTextField" || sheetOpen, "Cmd+L opened Go to Folder (focus: \(focusedRole))")
        key(53)
        usleep(400_000)
    }
}
