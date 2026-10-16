import AppKit

/// Explorer keys in Finder: Enter opens, F2 renames, Delete trashes, Shift+Delete deletes for
/// good after asking, Cmd+X then Cmd+V moves, Cmd+L types a path. Only while Finder is in front and focus is on files (not a name being
/// edited, the search field, a path box or a dialog), so text editing keeps every key.
///
/// It needs an active tap to swallow the original key. The tap only exists while Finder is
/// frontmost, since an active tap is in the path of every keystroke.
@MainActor
final class FinderKeys {
    static let shared = FinderKeys()

    /// Marks the keys Snap11 posts so its own tap lets them through.
    private static let tag: Int64 = 0x534e_3131
    private var tap: CFMachPort?
    private var swallowedUps: Set<Int64> = []
    private var cutCount: Int?

    private enum Code {
        static let returnKey: Int64 = 36, enter: Int64 = 76, f2: Int64 = 120
        static let delete: Int64 = 51, forwardDelete: Int64 = 117
        static let x: Int64 = 7, c: Int64 = 8, v: Int64 = 9, l: Int64 = 37, down: Int64 = 125
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let finder = app?.bundleIdentifier == "com.apple.finder"
            MainActor.assumeIsolated { self?.setActive(finder && Settings.finderKeys) }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        setActive(NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" && Settings.finderKeys)
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
        let plain = mods.isEmpty
        let cmdOnly = mods == .maskCommand
        let shiftOnly = mods == .maskShift
        let deleteKey = code == Code.delete || code == Code.forwardDelete
        let interesting = (plain && [Code.returnKey, Code.enter, Code.f2, Code.delete, Code.forwardDelete].contains(code))
            || (cmdOnly && [Code.x, Code.v, Code.l].contains(code)) || (shiftOnly && deleteKey)
        if Hotkeys.debug && (interesting || !mods.isEmpty) {
            NSLog("Snap11: finder key %lld mods %llx interesting %d", code, mods.rawValue, interesting ? 1 : 0)
        }
        guard interesting, focusIsOnFiles() else { return false }

        if shiftOnly && deleteKey {
            // Delete Immediately, which asks before it deletes, like Shift+Delete in Explorer.
            guard press(Self.deleteImmediately) else { return false }
            swallowedUps.insert(code)
            return true
        }
        switch (code, plain) {
        case (Code.returnKey, true), (Code.enter, true): post(Code.down, .maskCommand)
        case (Code.f2, true): post(Code.returnKey, [])
        case (Code.delete, true), (Code.forwardDelete, true): post(Code.delete, .maskCommand)
        case (Code.x, false):
            post(Code.c, .maskCommand)
            // Finder writes the pasteboard on the main loop after the copy lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                MainActor.assumeIsolated { FinderKeys.shared.cutCount = NSPasteboard.general.changeCount }
            }
        case (Code.v, false):
            if Hotkeys.debug { NSLog("Snap11: finder paste, cut %ld now %ld", cutCount ?? -1, NSPasteboard.general.changeCount) }
            guard let cut = cutCount, cut == NSPasteboard.general.changeCount else { return false }
            cutCount = nil
            guard press(Self.moveItemHere) else { return false }
        case (Code.l, false):
            guard press(Self.goToFolder) else { return false }
        default: return false
        }
        swallowedUps.insert(code)
        return true
    }

    private func post(_ code: Int64, _ flags: CGEventFlags) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
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
    private static let deleteImmediately = Shortcut(char: 8, mods: 2)
    nonisolated(unsafe) private var menuItems: [Shortcut: AXUIElement] = [:]

    private func readMenu() {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else { return }
        let pid = finder.processIdentifier
        let wanted: Set<Shortcut> = [Self.moveItemHere, Self.goToFolder, Self.deleteImmediately]
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
            DispatchQueue.main.async { MainActor.assumeIsolated { FinderKeys.shared.menuItems = found } }
        }
    }

    @discardableResult
    private func press(_ s: Shortcut) -> Bool {
        guard let item = menuItems[s] else { readMenu(); return false }
        if AXUIElementPerformAction(item, kAXPressAction as CFString) == .success { return true }
        readMenu()
        return false
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
