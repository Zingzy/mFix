import AppKit
import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// One switch or delay in UserDefaults, with its default. The settings window binds the same
/// key through @AppStorage, so the window and the features read one source.
struct Setting<Value> {
    let key: String
    let initial: Value

    var value: Value { UserDefaults.standard.object(forKey: key) as? Value ?? initial }
}

extension AppStorage where Value == Bool {
    init(_ setting: Setting<Bool>) { self.init(wrappedValue: setting.initial, setting.key) }
}

extension AppStorage where Value == Double {
    init(_ setting: Setting<Double>) { self.init(wrappedValue: setting.initial, setting.key) }
}

extension AppStorage where Value == String {
    init(_ setting: Setting<String>) { self.init(wrappedValue: setting.initial, setting.key) }
}

enum Settings {
    static let snapKeys = Setting(key: "snap.keys", initial: SnapKeys.cmdOption.rawValue)
    static let snapAssist = Setting(key: "snap.assist", initial: true)
    static let layoutsHover = Setting(key: "snap.layoutsHover", initial: true)
    static let hoverDelay = Setting(key: "snap.hoverDelay", initial: 0.6)
    static let dragSnap = Setting(key: "snap.drag", initial: true)
    static let switcher = Setting(key: "switcher.enabled", initial: true)
    static let allSpaces = Setting(key: "switcher.allSpaces", initial: true)
    static let showDelay = Setting(key: "switcher.showDelay", initial: 0.09)
    static let dragPreview = Setting(key: "drag.preview", initial: true)
    static let dockSpring = Setting(key: "drag.dockSpring", initial: true)
    static let springDelay = Setting(key: "drag.springDelay", initial: 0.5)
    static let minimizeKeys = Setting(key: "minimize.enabled", initial: true)
    static let dockNumbers = Setting(key: "dock.numbers", initial: true)
    static let finderKeys = Setting(key: "finder.keys", initial: true)
    static let dockPreviews = Setting(key: "dock.previews", initial: true)
    static let dockClicks = Setting(key: "dock.clicks", initial: true)
    static let dockDelay = Setting(key: "dock.delay", initial: 0.25)
    static let snapGroups = Setting(key: "snap.groups", initial: true)
    static let liveThumbnails = Setting(key: "thumbnails.live", initial: true)
    static let terminal = Setting(key: "finder.terminal", initial: "com.mitchellh.ghostty")
    static let alwaysOnTop = Setting(key: "pin.enabled", initial: true)

    /// Launch at login lives with the system, not in UserDefaults.
    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("mFix: launch at login: %@", error.localizedDescription)
            }
        }
    }
}

/// Which modifiers stand in for the Windows key.
enum SnapKeys: String, CaseIterable, Identifiable {
    case cmdOption, ctrlOption, ctrlCmd

    static var current: SnapKeys { SnapKeys(rawValue: Settings.snapKeys.value) ?? .cmdOption }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cmdOption: "Cmd + Option"
        case .ctrlOption: "Control + Option"
        case .ctrlCmd: "Control + Cmd"
        }
    }

    var modifiers: Int {
        switch self {
        case .cmdOption: cmdKey | optionKey
        case .ctrlOption: controlKey | optionKey
        case .ctrlCmd: controlKey | cmdKey
        }
    }
}
