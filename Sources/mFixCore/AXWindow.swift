import AppKit
import ApplicationServices

extension AXUIElement {
    func attr<T>(_ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    func point(_ name: String) -> CGPoint? { value(name, .cgPoint, CGPoint.zero) }

    func size(_ name: String) -> CGSize? { value(name, .cgSize, CGSize.zero) }

    var frame: CGRect? {
        guard let p = point(kAXPositionAttribute), let s = size(kAXSizeAttribute) else { return nil }
        return CGRect(origin: p, size: s)
    }

    private func value<T: BitwiseCopyable>(_ name: String, _ type: AXValueType, _ empty: T) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, name as CFString, &value) == .success, let value else { return nil }
        var result = empty
        return AXValueGetValue(value as! AXValue, type, &result) ? result : nil
    }

    @discardableResult
    func set(_ name: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(self, name as CFString, value)
    }
}

/// A top-level window of another app, addressed through Accessibility. Frames are in
/// AX coordinates: origin at the top-left of the primary screen, y grows downward.
/// Windows on other Spaces have no AX element (AX only lists the current Space's windows);
/// they carry what WindowServer reported and can only be focused, which switches Space.
final class AXWindow: Hashable {
    let element: AXUIElement?
    let pid: pid_t
    let id: CGWindowID
    private let reportedTitle: String
    private let reportedFrame: CGRect

    init(element: AXUIElement, pid: pid_t) {
        self.element = element
        self.pid = pid
        var wid: CGWindowID = 0
        _AXUIElementGetWindow(element, &wid)
        self.id = wid
        reportedTitle = ""
        reportedFrame = .zero
    }

    init(offSpace id: CGWindowID, pid: pid_t, title: String, frame: CGRect) {
        element = nil
        self.pid = pid
        self.id = id
        reportedTitle = title
        reportedFrame = frame
    }

    static func == (a: AXWindow, b: AXWindow) -> Bool {
        if a.id != 0 || b.id != 0 { return a.id == b.id }
        guard let x = a.element, let y = b.element else { return false }
        return CFEqual(x, y)
    }

    func hash(into h: inout Hasher) { h.combine(id) }

    var hasElement: Bool { element != nil }
    var app: NSRunningApplication? { NSRunningApplication(processIdentifier: pid) }
    var title: String { element?.attr(kAXTitleAttribute) ?? reportedTitle }
    var role: String? { element?.attr(kAXRoleAttribute) }
    var subrole: String? { element?.attr(kAXSubroleAttribute) }
    var isMinimized: Bool { element?.attr(kAXMinimizedAttribute) ?? false }
    var isFullScreen: Bool { element?.attr("AXFullScreen") ?? false }

    var isStandard: Bool {
        role == kAXWindowRole && subrole == kAXStandardWindowSubrole
    }

    var frame: CGRect {
        guard let element else { return reportedFrame }
        return CGRect(origin: element.point(kAXPositionAttribute) ?? .zero, size: element.size(kAXSizeAttribute) ?? .zero)
    }

    /// Size, then position, then size again: the first size can be clamped by the screen
    /// edge at the old position, and some apps only accept a position once the size fits.
    /// AXEnhancedUserInterface makes Chromium and others animate every write, so it is off
    /// for the duration.
    func setFrame(_ target: CGRect) {
        guard let element else { return }
        let appElement = AXUIElementCreateApplication(pid)
        let enhanced: Bool = appElement.attr("AXEnhancedUserInterface") ?? false
        if enhanced { appElement.set("AXEnhancedUserInterface", kCFBooleanFalse) }
        defer { if enhanced { appElement.set("AXEnhancedUserInterface", kCFBooleanTrue) } }

        var size = target.size
        var origin = target.origin
        let sizeValue = AXValueCreate(.cgSize, &size)!
        let originValue = AXValueCreate(.cgPoint, &origin)!
        element.set(kAXSizeAttribute, sizeValue)
        element.set(kAXPositionAttribute, originValue)
        element.set(kAXSizeAttribute, sizeValue)
    }

    func minimize() { element?.set(kAXMinimizedAttribute, kCFBooleanTrue) }

    func unminimize() { element?.set(kAXMinimizedAttribute, kCFBooleanFalse) }

    func focus() {
        if isMinimized { unminimize() }
        let fronted = SkyLight.makeFront(pid: pid, window: id)
        if Hotkeys.debug {
            NSLog("mFix: makeFront pid %d wid %u -> %d", pid, id, fronted ? 1 : 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NSLog("mFix: front after 200ms: %@", NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")
            }
        }
        if !fronted {
            app?.activate(options: [])
        }
        if let element {
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        } else if let e = RemoteWindows.shared.find(pid: pid, id: id) {
            AXUIElementPerformAction(e, kAXRaiseAction as CFString)
        } else {
            // Fronting switched Space; once there the window has an AX element to raise.
            let pid = self.pid, id = self.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                if let w = AXWindow.windows(of: pid).first(where: { $0.id == id }), let e = w.element {
                    AXUIElementPerformAction(e, kAXRaiseAction as CFString)
                }
            }
        }
    }

    func close() {
        guard let button: AXUIElement = element?.attr(kAXCloseButtonAttribute) else { return }
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }

    /// The green traffic light. Its subrole is AXFullScreenButton; AXZoomButton is the
    /// Option-click variant.
    var fullScreenButtonFrame: CGRect? {
        (element?.attr(kAXFullScreenButtonAttribute) as AXUIElement?)?.frame
    }

    static func focused() -> AXWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        if let w: AXUIElement = appElement.attr(kAXFocusedWindowAttribute) {
            return AXWindow(element: w, pid: app.processIdentifier)
        }
        if let w: AXUIElement = appElement.attr(kAXMainWindowAttribute) {
            return AXWindow(element: w, pid: app.processIdentifier)
        }
        return nil
    }

    static func windows(of pid: pid_t) -> [AXWindow] {
        let appElement = AXUIElementCreateApplication(pid)
        let list: [AXUIElement] = appElement.attr(kAXWindowsAttribute) ?? []
        return list.map { AXWindow(element: $0, pid: pid) }
    }
}

/// One app's Accessibility notifications on the main run loop, each handed over with the id
/// of the window it came from.
final class AXWatcher {
    private let observer: AXObserver
    private let mode: CFRunLoopMode
    private let handler: (CGWindowID, String) -> Void

    init?(pid: pid_t, mode: CFRunLoopMode = .commonModes, _ handler: @escaping (CGWindowID, String) -> Void) {
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, element, notification, refcon in
            var id: CGWindowID = 0
            _AXUIElementGetWindow(element, &id)
            Unmanaged<AXWatcher>.fromOpaque(refcon!).takeUnretainedValue().handler(id, notification as String)
        }, &observer) == .success, let observer else { return nil }
        self.observer = observer
        self.mode = mode
        self.handler = handler
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), mode)
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), mode)
    }

    func watch(_ element: AXUIElement, _ notifications: [String]) {
        for n in notifications {
            AXObserverAddNotification(observer, element, n as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
    }
}
