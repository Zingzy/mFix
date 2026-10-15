import ApplicationServices
import CoreGraphics
import Foundation

@_silgen_name("GetProcessForPID")
func GetProcessForPID(_ pid: pid_t, _ psn: UnsafeMutablePointer<ProcessSerialNumber>) -> OSStatus

@_silgen_name("_AXUIElementGetWindow")
@discardableResult
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

typealias CGSConnectionID = UInt32

enum SkyLight {
    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)

    private static func sym<T>(_ name: String, as: T.Type) -> T? {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let p = handle.flatMap({ dlsym($0, name) }) ?? dlsym(rtldDefault, name) else { return nil }
        return unsafeBitCast(p, to: T.self)
    }

    private typealias MainConnectionFn = @convention(c) () -> CGSConnectionID
    private typealias SetSymbolicHotKeyFn = @convention(c) (Int32, Bool) -> CGError
    private typealias CopySpacesForWindowsFn = @convention(c) (CGSConnectionID, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias GetActiveSpaceFn = @convention(c) (CGSConnectionID) -> UInt64
    private typealias SetFrontProcessFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32) -> CGError
    private typealias PostEventRecordFn = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError

    private typealias HWCaptureFn = @convention(c) (CGSConnectionID, UnsafeMutablePointer<CGWindowID>, UInt32, UInt32) -> Unmanaged<CFArray>?
    private static let hwCapture = sym("CGSHWCaptureWindowList", as: HWCaptureFn.self)

    private typealias OrderedInFn = @convention(c) (CGSConnectionID, CGWindowID, UnsafeMutablePointer<Bool>) -> CGError
    private static let orderedIn = sym("SLSWindowIsOrderedIn", as: OrderedInFn.self)

    private static let mainConnection = sym("SLSMainConnectionID", as: MainConnectionFn.self)
    private static let setSymbolicHotKey = sym("SLSSetSymbolicHotKeyEnabled", as: SetSymbolicHotKeyFn.self)
    private static let copySpacesForWindows = sym("SLSCopySpacesForWindows", as: CopySpacesForWindowsFn.self)
    private static let getActiveSpace = sym("SLSGetActiveSpace", as: GetActiveSpaceFn.self)
    private static let setFrontProcess = sym("_SLPSSetFrontProcessWithOptions", as: SetFrontProcessFn.self)
    private static let postEventRecord = sym("SLPSPostEventRecordTo", as: PostEventRecordFn.self)

    static var connection: CGSConnectionID { mainConnection?() ?? 0 }

    // Symbolic hotkey ids: 1 = Cmd+Tab, 2 = Cmd+Shift+Tab, 6 = Cmd+` (com.apple.symbolichotkeys).
    static func setSystemSwitcherEnabled(_ enabled: Bool) {
        for id: Int32 in [1, 2] { _ = setSymbolicHotKey?(id, enabled) }
    }

    /// Captures a window even while it is minimized, which ScreenCaptureKit can't.
    /// Options: ignore global clip shape (1<<11), best resolution (1<<8), full size (1<<19).
    static func captureWindow(_ id: CGWindowID) -> CGImage? {
        guard let hwCapture else { return nil }
        var wid = id
        guard let list = hwCapture(connection, &wid, 1, (1 << 11) | (1 << 8) | (1 << 19))?.takeRetainedValue() as? [CGImage]
        else { return nil }
        return list.first
    }

    /// False for a window its app closed but kept alive (Cap, Discord and many Electron apps
    /// do this), which still belongs to a Space. A window on another Space stays ordered in.
    static func isOrderedIn(_ id: CGWindowID) -> Bool {
        guard let orderedIn else { return true }
        var result = false
        return orderedIn(connection, id, &result) == .success ? result : true
    }

    static var activeSpace: UInt64 { getActiveSpace?(connection) ?? 0 }

    // Mask 0x7 = all spaces the window belongs to (current, other, fullscreen).
    static func spaces(for window: CGWindowID) -> [UInt64] {
        guard let fn = copySpacesForWindows else { return [] }
        let ids = [NSNumber(value: window)] as CFArray
        guard let result = fn(connection, 0x7, ids)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return result.map { $0.uint64Value }
    }

    // Fronts one window of another app the way AltTab does on macOS 26: front the process
    // with only that window raised, then post a mouse-down record so it becomes key. The
    // buffer is 0x100 long because WindowServer reads past the declared 0xf8; the up event
    // is left out and the point sits far off-screen so no control gets clicked.
    static func makeFront(pid: pid_t, window: CGWindowID) -> Bool {
        guard let setFrontProcess, let postEventRecord else { return false }
        var psn = ProcessSerialNumber()
        guard GetProcessForPID(pid, &psn) == noErr else { return false }
        let err = setFrontProcess(&psn, window, 0x200)
        if Hotkeys.debug { NSLog("Snap11: setFrontProcess psn %u.%u -> %d", psn.highLongOfPSN, psn.lowLongOfPSN, err.rawValue) }
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x04] = 0xf8
        bytes[0x08] = 0x01
        bytes[0x3a] = 0x10
        var wid = window
        withUnsafeBytes(of: &wid) { for i in 0..<4 { bytes[0x3c + i] = $0[i] } }
        var point = CGPoint(x: 300_000, y: 300_000)
        withUnsafeBytes(of: &point) { for i in 0..<16 { bytes[0x20 + i] = $0[i] } }
        _ = bytes.withUnsafeMutableBufferPointer { postEventRecord(&psn, $0.baseAddress!) }
        return true
    }
}
