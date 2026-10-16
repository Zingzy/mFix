import AppKit

/// Keeps on-screen checks off the person's own windows. A check starts only after the
/// keyboard and mouse have been idle for a while, every event it posts carries `tag`, and
/// the first event without it (a real key, click or scroll) ends the run on the spot.
public enum CheckGuard {
    static let tag: Int64 = 0x534e_4348
    private static var tap: CFMachPort?

    public static func begin(idle: TimeInterval = 10) {
        let quiet = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard quiet >= idle else {
            print("not starting: keyboard or mouse used \(Int(quiet)) s ago; a check needs \(Int(idle)) s of no input")
            exit(3)
        }
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .mouseMoved, .leftMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly, eventsOfInterest: mask,
                                callback: { _, type, event, _ in
            let from = event.getIntegerValueField(.eventSourceUserData)
            // Snap11's own Finder replacements carry its tag; anything else is the person.
            if type != .tapDisabledByTimeout, type != .tapDisabledByUserInput, from != CheckGuard.tag, from != 0x534e_3131 {
                print("ABORT: real input (\(type.rawValue)) during the check; stopping before the next step")
                exit(4)
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil)
        if let tap {
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    /// The tap's callback only runs when the run loop does; checks sleep between steps, so
    /// each step drains it first.
    public static func poll() {
        CFRunLoopRunInMode(.defaultMode, 0, false)
    }

    static func mark(_ e: CGEvent?) {
        e?.setIntegerValueField(.eventSourceUserData, value: tag)
    }
}
