import AppKit

/// Explorer keys in Finder: Enter opens, F2 renames, Delete trashes, Shift+Delete deletes for
/// good after asking, Cmd+X then Cmd+V moves, Cmd+L types a path. Only while Finder is in front and focus is on files (not a name being
/// edited, the search field, a path box or a dialog), so text editing keeps every key.
///
/// It needs an active tap to swallow the original key. The tap only exists while Finder is
/// frontmost, since an active tap is in the path of every keystroke.
@MainActor
final class FinderKeys: Feature {
    static let shared = FinderKeys()

    /// Marks the keys mFix posts so its own tap lets them through.
    nonisolated static let tag: Int64 = 0x534e_3131
    private var tap: CFMachPort?
    private var swallowedUps: Set<Int64> = []
    private var cutCount: Int?

    private enum Code {
        static let returnKey: Int64 = 36, enter: Int64 = 76, f2: Int64 = 120
        static let delete: Int64 = 51, forwardDelete: Int64 = 117
        static let x: Int64 = 7, c: Int64 = 8, v: Int64 = 9, l: Int64 = 37, t: Int64 = 17, down: Int64 = 125
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let finder = app?.bundleIdentifier == "com.apple.finder"
            MainActor.assumeIsolated { self?.setActive(finder && Settings.finderKeys.value) }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        setActive(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" && Settings.finderKeys.value)
    }

    private func setActive(_ on: Bool) {
        if !on, let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.tap = nil
            swallowedUps = []
            return
        }
        guard on, tap == nil, AXIsProcessTrusted() else { return }
        readMenu()
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                MainActor.assumeIsolated { FinderKeys.shared.reenable() }
                return Unmanaged.passUnretained(event)
            }
            let swallow = MainActor.assumeIsolated { FinderKeys.shared.handle(type, event) }
            return swallow ? nil : Unmanaged.passUnretained(event)
        }, userInfo: nil)
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        if e.getIntegerValueField(.eventSourceUserData) == FinderKeys.tag { return false }
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp { return swallowedUps.remove(code) != nil }

        let mods = e.flags.intersection([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        if mods == [.maskCommand, .maskAlternate], code == Code.t, let folder = currentFolder() {
            // Windows 11's "Open in Terminal" for the folder in front.
            Terminals.open(folder)
            swallowedUps.insert(code)
            return true
        }
        let plain = mods.isEmpty
        let cmdOnly = mods == .maskCommand
        let shiftOnly = mods == .maskShift
        let deleteKey = code == Code.delete || code == Code.forwardDelete
        let interesting = (plain && [Code.returnKey, Code.enter, Code.f2, Code.delete, Code.forwardDelete].contains(code))
            || (cmdOnly && [Code.x, Code.v, Code.l].contains(code)) || (shiftOnly && deleteKey)
        if Hotkeys.debug && (interesting || !mods.isEmpty) {
            NSLog("mFix: finder key %lld mods %llx interesting %d", code, mods.rawValue, interesting ? 1 : 0)
        }
        guard interesting, focusIsOnFiles() else { return false }

        if shiftOnly && deleteKey {
            // Delete Immediately, which asks before it deletes, like Shift+Delete in Explorer.
            // Its menu item is a hidden alternate that ignores a press, so the chord goes instead.
            post(Code.delete, [.maskCommand, .maskAlternate])
            swallowedUps.insert(code)
            return true
        }
        switch (code, plain) {
        case (Code.returnKey, true), (Code.enter, true): post(Code.down, .maskCommand)
        case (Code.f2, true): post(Code.returnKey, [])
        case (Code.delete, true), (Code.forwardDelete, true): post(Code.delete, .maskCommand)
        case (Code.x, false):
            let before = NSPasteboard.general.changeCount
            cutCount = nil
            post(Code.c, .maskCommand)
            awaitCopy(after: before, tries: 20)
        case (Code.v, false):
            if Hotkeys.debug { NSLog("mFix: finder paste, cut %ld now %ld", cutCount ?? -1, NSPasteboard.general.changeCount) }
            guard let cut = cutCount, cut == NSPasteboard.general.changeCount else { return false }
            cutCount = nil
            let sources = (NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            onMain { FinderKeys.shared.paste(sources) }
        case (Code.l, false):
            guard press(Self.goToFolder) else { return false }
        default: return false
        }
        swallowedUps.insert(code)
        return true
    }

    /// Finder writes the copied files to the pasteboard some time after the key; the cut
    /// counts once the pasteboard has actually changed.
    private func awaitCopy(after before: Int, tries: Int) {
        onMain(after: 0.05) {
            let now = NSPasteboard.general.changeCount
            if now != before {
                FinderKeys.shared.cutCount = now
                if Hotkeys.debug { NSLog("mFix: finder cut recorded at %ld", now) }
            } else if tries > 0 {
                FinderKeys.shared.awaitCopy(after: before, tries: tries - 1)
            } else if Hotkeys.debug {
                NSLog("mFix: finder cut: pasteboard never changed after Cmd+C")
            }
        }
    }

    /// A private source, so the keys held down (Shift for Shift+Delete) don't merge into the
    /// chord posted, which made Cmd+Option+Delete land as Cmd+Option+Shift+Delete.
    private let source = CGEventSource(stateID: .privateState)

    private func post(_ code: Int64, _ flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: FinderKeys.tag)
            e.post(tap: .cgSessionEventTap)
        }
    }

    // MARK: Finder's menu

    /// Chords with two modifiers posted from the tap never reached Finder, so those go
    /// through Finder's own menu items, found by their shortcut so any language works.
    /// AX modifier bits: 1 Shift, 2 Option, 4 Control; Cmd is implied.
    private struct Shortcut: Hashable { let char: UInt32; let mods: Int }
    private static let moveItemHere = Shortcut(char: 86, mods: 2)
    private static let goToFolder = Shortcut(char: 71, mods: 1)
    nonisolated(unsafe) private var menuItems: [Shortcut: AXUIElement] = [:]

    private func readMenu() {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }
        let pid = finder.processIdentifier
        let wanted: Set<Shortcut> = [Self.moveItemHere, Self.goToFolder]
        DispatchQueue.global(qos: .userInitiated).async {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.5)
            var found: [Shortcut: AXUIElement] = [:]
            guard let bar: AXUIElement = app.attr(kAXMenuBarAttribute) else { return }
            for top in (bar.attr(kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                for menu in (top.attr(kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                    for item in (menu.attr(kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                        guard let ch = (item.attr(kAXMenuItemCmdCharAttribute) as String?)?.unicodeScalars.first?.value,
                              let mods: Int = item.attr(kAXMenuItemCmdModifiersAttribute) else { continue }
                        let s = Shortcut(char: ch, mods: mods)
                        if wanted.contains(s) { found[s] = item }
                    }
                }
            }
            onMain { FinderKeys.shared.menuItems = found }
        }
    }

    /// Into the selected folder, or the folder of the selected files, when that is not the
    /// window's own: Finder's paste only ever goes to the top folder of a list or column view.
    private func paste(_ sources: [URL]) {
        // Off the main thread: the first script call waits on macOS asking the person.
        DispatchQueue.global(qos: .userInitiated).async {
            let (top, selected) = FinderScript.windowAndSelection()
            onMain { FinderKeys.shared.paste(sources, top: top, selected: selected) }
        }
    }

    private func paste(_ sources: [URL], top: URL?, selected: [URL]) {
        var dest = top
        let values = selected.count == 1 ? try? selected[0].resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) : nil
        if let values, values.isDirectory == true, values.isPackage != true {
            dest = selected[0]
        } else if let first = selected.first {
            let parents = Set(selected.map { $0.deletingLastPathComponent().standardizedFileURL })
            if parents.count == 1 { dest = first.deletingLastPathComponent() }
        }
        if Hotkeys.debug { NSLog("mFix: finder paste into %@ (window %@)", dest?.path ?? "-", top?.path ?? "-") }
        guard let dest, let top, dest.standardizedFileURL != top.standardizedFileURL, !sources.isEmpty else {
            press(Self.moveItemHere)
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            if !FinderScript.move(sources, to: dest) { DispatchQueue.main.async { NSSound.beep() } }
        }
    }

    @discardableResult
    private func press(_ s: Shortcut) -> Bool {
        guard let item = menuItems[s] else {
            if Hotkeys.debug { NSLog("mFix: finder menu item %u/%d not cached yet", s.char, s.mods) }
            readMenu()
            return false
        }
        let result = AXUIElementPerformAction(item, kAXPressAction as CFString)
        if Hotkeys.debug { NSLog("mFix: finder menu press %u/%d -> %d", s.char, s.mods, result.rawValue) }
        if result == .success { return true }
        readMenu()
        return false
    }

    /// The folder Finder shows in front: a single selected folder, else the front window's
    /// folder, else the desktop.
    private func currentFolder() -> URL? {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return nil }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        if let focused: AXUIElement = app.attr(kAXFocusedUIElementAttribute) {
            let selected: [AXUIElement] = focused.attr(kAXSelectedRowsAttribute) ?? focused.attr(kAXSelectedChildrenAttribute) ?? []
            let urls = selected.compactMap { item -> URL? in
                (item.attr(kAXURLAttribute) as URL?) ?? ((item.attr(kAXChildrenAttribute) as [AXUIElement]?) ?? []).lazy.compactMap { $0.attr(kAXURLAttribute) as URL? }.first
            }
            if urls.count == 1, (try? urls[0].resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { return urls[0] }
        }
        if let window: AXUIElement = app.attr(kAXFocusedWindowAttribute),
           let doc: String = window.attr(kAXDocumentAttribute), let url = URL(string: doc) {
            return url
        }
        return FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }

    /// Files have focus when Finder's focused element is a file view (icon, list, column or
    /// gallery, or the desktop), not a text field, and not inside a sheet or dialog.
    private func focusIsOnFiles() -> Bool {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return false }
        let app = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard let focused: AXUIElement = app.attr(kAXFocusedUIElementAttribute) else { return false }
        let role: String = focused.attr(kAXRoleAttribute) ?? ""
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role) { return false }
        guard ["AXList", "AXOutline", "AXBrowser", "AXGroup", "AXTable", "AXScrollArea", "AXCollection"].contains(role) else { return false }
        if let window: AXUIElement = focused.attr(kAXWindowAttribute) {
            return (window.attr(kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole
        }
        return true
    }
}
