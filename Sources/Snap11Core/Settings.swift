import AppKit
import ServiceManagement

/// Every switch and delay, in UserDefaults so the settings window (bound with @AppStorage
/// to the same keys) and the features read one source.
enum Settings {
    enum K {
        static let snapKeys = "snap.keys"
        static let snapAssist = "snap.assist"
        static let layoutsHover = "snap.layoutsHover"
        static let hoverDelay = "snap.hoverDelay"
        static let dragSnap = "snap.drag"
        static let animate = "snap.animate"
        static let switcher = "switcher.enabled"
        static let allSpaces = "switcher.allSpaces"
        static let showDelay = "switcher.showDelay"
        static let dragPreview = "drag.preview"
        static let dockSpring = "drag.dockSpring"
        static let springDelay = "drag.springDelay"
        static let minimizeKeys = "minimize.enabled"
        static let dockNumbers = "dock.numbers"
        static let finderKeys = "finder.keys"
    }

    static func register() {
        UserDefaults.standard.register(defaults: [
            K.snapKeys: SnapKeys.cmdOption.rawValue,
            K.snapAssist: true,
            K.layoutsHover: true,
            K.hoverDelay: 0.6,
            K.dragSnap: true,
            K.animate: true,
            K.switcher: true,
            K.allSpaces: true,
            K.showDelay: 0.09,
            K.dragPreview: true,
            K.dockSpring: true,
            K.springDelay: 0.5,
            K.minimizeKeys: true,
            K.dockNumbers: true,
            K.finderKeys: true,
        ])
    }

    private static var d: UserDefaults { .standard }
    static var snapKeys: SnapKeys { SnapKeys(rawValue: d.string(forKey: K.snapKeys) ?? "") ?? .cmdOption }
    static var snapAssist: Bool { d.bool(forKey: K.snapAssist) }
    static var layoutsHover: Bool { d.bool(forKey: K.layoutsHover) }
    static var hoverDelay: TimeInterval { d.double(forKey: K.hoverDelay) }
    static var dragSnap: Bool { d.bool(forKey: K.dragSnap) }
    static var animate: Bool { d.bool(forKey: K.animate) }
    static var switcher: Bool { d.bool(forKey: K.switcher) }
    static var allSpaces: Bool { d.bool(forKey: K.allSpaces) }
    static var showDelay: TimeInterval { d.double(forKey: K.showDelay) }
    static var dragPreview: Bool { d.bool(forKey: K.dragPreview) }
    static var dockSpring: Bool { d.bool(forKey: K.dockSpring) }
    static var springDelay: TimeInterval { d.double(forKey: K.springDelay) }
    static var minimizeKeys: Bool { d.bool(forKey: K.minimizeKeys) }
    static var dockNumbers: Bool { d.bool(forKey: K.dockNumbers) }
    static var finderKeys: Bool { d.bool(forKey: K.finderKeys) }

    /// Launch at login lives with the system, not in UserDefaults.
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Snap11: launch at login: %@", error.localizedDescription)
            }
        }
    }
}

/// Which modifiers stand in for the Windows key.
enum SnapKeys: String, CaseIterable, Identifiable {
    case cmdOption, ctrlOption, ctrlCmd

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cmdOption: "Cmd + Option"
        case .ctrlOption: "Control + Option"
        case .ctrlCmd: "Control + Cmd"
        }
    }
}
