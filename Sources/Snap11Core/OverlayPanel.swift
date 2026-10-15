import AppKit

/// Borderless panel that floats over every app and every Space without activating Snap11,
/// so the app the person was in stays active and its menu bar stays put.
final class OverlayPanel: NSPanel {
    var takesKeyboard: Bool
    var onKey: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?

    init(takesKeyboard: Bool) {
        self.takesKeyboard = takesKeyboard
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // isFloatingPanel resets the level to .floating, so it goes first.
        isFloatingPanel = true
        level = .popUpMenu
        hidesOnDeactivate = false
        animationBehavior = .none
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        // A clear borderless window lets clicks fall through its transparent pixels unless
        // this is set explicitly.
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        becomesKeyOnlyIfNeeded = !takesKeyboard
    }

    override var canBecomeKey: Bool { takesKeyboard }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKey?(event) ?? false
    }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// Set by the render check: build and lay out panels without putting them on screen.
    static var offscreen = false

    func show(frame: NSRect) {
        setFrame(frame, display: true)
        if OverlayPanel.offscreen { return }
        if Hotkeys.debug { NSLog("Snap11: panel show %@ level %d", NSStringFromRect(frame), level.rawValue) }
        alphaValue = 1
        if takesKeyboard { makeKeyAndOrderFront(nil) } else { orderFrontRegardless() }
    }

    func hide() {
        alphaValue = 0
        orderOut(nil)
    }
}
