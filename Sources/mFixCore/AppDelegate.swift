import AppKit

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var boundKeys: [String] = []

    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ note: Notification) {
        installExitHandlers()
        AXWindow.limitWaits()
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if !Thumbnails.permitted { CGRequestScreenCaptureAccess() }
        setUpStatusItem()
        allFeatures.forEach { $0.start() }
        SystemShortcuts.recoverAfterCrash()
        bindHotkeys()
        // Key settings take effect at once: bind again whenever a change alters the chords.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.bindHotkeys() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Wallpaper.invalidate() }
        }
    }

    public func applicationWillTerminate(_ note: Notification) {
        SystemShortcuts.restoreAll()
    }

    /// Turning off the system Cmd+Tab outlives the process, so put it back on every way out.
    private func installExitHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP] {
            signal(sig) { s in
                SystemShortcuts.restoreFromSignal()
                signal(s, SIG_DFL)
                raise(s)
            }
        }
        NSSetUncaughtExceptionHandler { _ in SystemShortcuts.restoreFromSignal() }
    }

    @MainActor
    private func bindHotkeys() {
        let hotkeys = allFeatures.flatMap { $0.hotkeys(win: SnapKeys.current.modifiers) }
        let keys = hotkeys.map { "\($0.key)/\($0.modifiers)" }
        guard keys != boundKeys else { return }
        boundKeys = keys
        Hotkeys.shared.unregisterAll()
        SystemShortcuts.suspend(hotkeys.flatMap(\.replaces))
        hotkeys.forEach(Hotkeys.shared.register)
    }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.split.2x2", accessibilityDescription: "mFix")
        let menu = NSMenu()
        menu.addItem(withTitle: "mFix", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        let ax = menu.addItem(withTitle: "Accessibility permission…", action: #selector(openAccessibility), keyEquivalent: "")
        ax.target = self
        let sr = menu.addItem(withTitle: "Screen Recording permission…", action: #selector(openScreenRecording), keyEquivalent: "")
        sr.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit mFix", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func openSettings() {
        MainActor.assumeIsolated { SettingsWindow.shared.show() }
    }

    @objc private func openAccessibility() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    @objc private func openScreenRecording() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    }
}
