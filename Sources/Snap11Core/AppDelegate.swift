import AppKit
import Carbon.HIToolbox

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var modifierWatch: ModifierWatch?
    private var statusItem: NSStatusItem?
    /// Snap Assist waits for the chord's modifiers to go up, so holding them and pressing
    /// arrows steers the window first, as on Windows.
    private var pendingAssist: (AXWindow, Zone, NSScreen)?

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ note: Notification) {
        installExitHandlers()
        let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if !Thumbnails.permitted { CGRequestScreenCaptureAccess() }
        setUpStatusItem()
        FocusHistory.shared.start()
        LayoutFlyout.shared.start()
        registerHotkeys()
        SkyLight.setSystemSwitcherEnabled(false)
        modifierWatch = ModifierWatch { [weak self] flags in
            MainActor.assumeIsolated { self?.modifiersChanged(flags) }
        }
        let tapStarted = modifierWatch?.start() ?? false
        if Hotkeys.debug { NSLog("Snap11: modifier tap started=%d trusted=%d", tapStarted ? 1 : 0, trusted ? 1 : 0) }
        if !tapStarted {
            NSLog("Snap11: modifier tap failed; Accessibility trusted = %d", trusted ? 1 : 0)
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Wallpaper.invalidate() }
        }
    }

    public func applicationWillTerminate(_ note: Notification) {
        SkyLight.setSystemSwitcherEnabled(true)
    }

    /// Turning off the system Cmd+Tab outlives the process, so put it back on every way out.
    private func installExitHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP] {
            signal(sig) { s in
                SkyLight.setSystemSwitcherEnabled(true)
                signal(s, SIG_DFL)
                raise(s)
            }
        }
        NSSetUncaughtExceptionHandler { _ in SkyLight.setSystemSwitcherEnabled(true) }
    }

    private func registerHotkeys() {
        let win = cmdKey | optionKey
        let hk = Hotkeys.shared
        let arrows: [(Int64, Arrow)] = [(Key.left, .left), (Key.right, .right), (Key.up, .up), (Key.down, .down)]
        for (code, arrow) in arrows {
            hk.register(Int(code), win) { [weak self] in
                MainActor.assumeIsolated {
                    SnapAssist.shared.end(focusLast: false)
                    LayoutFlyout.shared.close()
                    self?.pendingAssist = SnapEngine.shared.handle(arrow)
                }
            }
        }
        hk.register(Int(Key.up), win | controlKey) { [weak self] in
            MainActor.assumeIsolated { self?.pendingAssist = SnapEngine.shared.snapVertical(top: true) }
        }
        hk.register(Int(Key.down), win | controlKey) { [weak self] in
            MainActor.assumeIsolated { self?.pendingAssist = SnapEngine.shared.snapVertical(top: false) }
        }
        hk.register(Int(Key.left), win | shiftKey) { MainActor.assumeIsolated { SnapEngine.shared.moveToScreen(towardLeft: true) } }
        hk.register(Int(Key.right), win | shiftKey) { MainActor.assumeIsolated { SnapEngine.shared.moveToScreen(towardLeft: false) } }
        hk.register(Int(Key.up), win | shiftKey) { MainActor.assumeIsolated { SnapEngine.shared.stretchVertically() } }
        hk.register(Int(Key.down), win | shiftKey) { MainActor.assumeIsolated { SnapEngine.shared.restoreFocused() } }
        hk.register(Int(Key.z), win) {
            MainActor.assumeIsolated {
                SnapAssist.shared.end(focusLast: false)
                LayoutFlyout.shared.openForFocused()
            }
        }

        hk.register(Int(Key.tab), cmdKey, repeats: true) { MainActor.assumeIsolated { Switcher.shared.step(backward: false) } }
        hk.register(Int(Key.tab), cmdKey | shiftKey, repeats: true) { MainActor.assumeIsolated { Switcher.shared.step(backward: true) } }
        hk.register(Int(Key.tab), cmdKey | controlKey, repeats: true) {
            MainActor.assumeIsolated { Switcher.shared.step(backward: false, sticky: true) }
        }
    }

    @MainActor
    private func modifiersChanged(_ flags: CGEventFlags) {
        if Hotkeys.debug { NSLog("Snap11: flags %llx pending=%d", flags.rawValue, pendingAssist == nil ? 0 : 1) }
        if !flags.contains(.maskCommand) {
            Switcher.shared.modifiersReleased()
        }
        if !flags.contains(.maskCommand) || !flags.contains(.maskAlternate), let (w, z, s) = pendingAssist {
            pendingAssist = nil
            SnapAssist.shared.begin(after: w, zone: z, on: s)
        }
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: "Snap11")
        let menu = NSMenu()
        menu.addItem(withTitle: "Snap11", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        let ax = menu.addItem(withTitle: "Accessibility permission…", action: #selector(openAccessibility), keyEquivalent: "")
        ax.target = self
        let sr = menu.addItem(withTitle: "Screen Recording permission…", action: #selector(openScreenRecording), keyEquivalent: "")
        sr.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Snap11", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openScreenRecording() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
