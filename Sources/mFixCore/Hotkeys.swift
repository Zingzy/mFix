import AppKit
import Carbon.HIToolbox

/// Global chords through Carbon hotkeys: no permission needed and the key never reaches
/// the frontmost app. Since macOS 15 a chord needs Cmd or Ctrl among its modifiers.
final class Hotkeys {
    static let shared = Hotkeys()
    static let debug = ProcessInfo.processInfo.environment["MFIX_DEBUG"] != nil

    private var actions: [UInt32: @MainActor () -> Void] = [:]
    private var repeating: Set<UInt32> = []
    private var refs: [EventHotKeyRef] = []
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    private var repeatTimer: Timer?
    private var heldID: UInt32?

    func register(_ hotkey: Hotkey) {
        installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x534e_3131), id: nextID)
        guard RegisterEventHotKey(UInt32(hotkey.key), UInt32(hotkey.modifiers), id, GetEventDispatcherTarget(), 0, &ref) == noErr,
              let ref else {
            NSLog("mFix: hotkey %d/%d is taken", Int(hotkey.key), hotkey.modifiers)
            return
        }
        if Hotkeys.debug { NSLog("mFix: hotkey %u = key %d mods %d", nextID, Int(hotkey.key), hotkey.modifiers) }
        refs.append(ref)
        actions[nextID] = hotkey.action
        if hotkey.repeats { repeating.insert(nextID) }
        nextID += 1
    }

    func unregisterAll() {
        stopRepeating()
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        actions = [:]
        repeating = []
    }

    func stopRepeating() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        heldID = nil
    }

    private func pressed(_ id: UInt32) {
        if Hotkeys.debug { NSLog("mFix: hotkey %u pressed", id) }
        stopRepeating()
        fire(id)
        guard repeating.contains(id) else { return }
        heldID = id
        repeatTimer = Timer.scheduledTimer(withTimeInterval: NSEvent.keyRepeatDelay, repeats: false) { [weak self] _ in
            guard let self, self.heldID == id else { return }
            self.fire(id)
            self.repeatTimer = Timer.scheduledTimer(withTimeInterval: NSEvent.keyRepeatInterval, repeats: true) { [weak self] _ in
                guard let self, self.heldID == id else { return }
                self.fire(id)
            }
        }
    }

    private func fire(_ id: UInt32) {
        guard let action = actions[id] else { return }
        MainActor.assumeIsolated { action() }
    }

    private func released(_ id: UInt32) {
        if heldID == id { stopRepeating() }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) {
                Hotkeys.shared.pressed(id.id)
            } else {
                Hotkeys.shared.released(id.id)
            }
            return noErr
        }, 2, &specs, nil, nil)
    }
}

struct Hotkey {
    /// Win+Alt: the third of Cmd, Option and Control on top of the Win chord.
    static let winAlt = cmdKey | optionKey | controlKey

    let key: Int64
    let modifiers: Int
    /// Holding the chord fires it again at the system key-repeat delay and rate, since Carbon
    /// delivers one press per physical press and no auto-repeat.
    let repeats: Bool
    /// macOS's own shortcuts on the same chord, switched off while it is bound.
    let replaces: [Int32]
    let action: @MainActor () -> Void

    init(_ key: Int64, _ modifiers: Int, repeats: Bool = false, replaces: [Int32] = [], _ action: @escaping @MainActor () -> Void) {
        self.key = key
        self.modifiers = modifiers
        self.repeats = repeats
        self.replaces = replaces
        self.action = action
    }
}

/// A listen-only session event tap: sees every event of the given types on its way through
/// WindowServer, including the mouse drags WindowServer runs itself for title-bar moves,
/// which never reach an app and so never reach an NSEvent global monitor.
/// Listen-only on purpose: an active tap hangs all input if Accessibility is revoked.
final class ListenTap {
    private var tap: CFMachPort?
    private let handler: (CGEventType, CGEvent) -> Void

    init(_ types: [CGEventType], handler: @escaping (CGEventType, CGEvent) -> Void) {
        self.handler = handler
        let me = Unmanaged.passUnretained(self).toOpaque()
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let me = Unmanaged<ListenTap>.fromOpaque(refcon!).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = me.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                } else {
                    me.handler(type, event)
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: me
        )
        guard let tap else {
            NSLog("mFix: event tap failed; Accessibility trusted = %d", AXIsProcessTrusted() ? 1 : 0)
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}

enum Key {
    static let tab: Int64 = 48
    static let escape: Int64 = 53
    static let returnKey: Int64 = 36
    static let enter: Int64 = 76
    static let left: Int64 = 123
    static let right: Int64 = 124
    static let down: Int64 = 125
    static let up: Int64 = 126
    static let z: Int64 = 6
    static let d: Int64 = 2
    static let home: Int64 = 115
    static let t: Int64 = 17
    static let w: Int64 = 13
    static let delete: Int64 = 51
    static let forwardDelete: Int64 = 117
    static let digits: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25]
}
