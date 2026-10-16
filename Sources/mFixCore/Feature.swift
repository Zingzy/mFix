import AppKit
import Carbon.HIToolbox

/// A part of mFix the app delegate starts at launch and asks for its chords, again whenever
/// a setting changes. A new feature conforms and joins `allFeatures`.
@MainActor
protocol Feature {
    func start()
    /// `win`: the modifiers standing in for the Windows key.
    func hotkeys(win: Int) -> [Hotkey]
}

extension Feature {
    func start() {}
    func hotkeys(win: Int) -> [Hotkey] { [] }
}

/// Started in this order.
@MainActor
let allFeatures: [Feature] = [
    FocusHistory.shared, LayoutFlyout.shared, DragSnap.shared, DragDrop.shared, FinderKeys.shared, DockPreview.shared,
    SnapGroups.shared, AlwaysOnTop.shared, SnapEngine.shared, SnapAssist.shared, MinimizeAll.shared, DockApps(),
    TaskManager(), Switcher.shared,
]

/// Ctrl+Shift+Esc opens Task Manager on Windows; Cmd stands in for Ctrl.
struct TaskManager: Feature {
    func hotkeys(win: Int) -> [Hotkey] {
        [Hotkey(Key.escape, cmdKey | shiftKey) {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"),
                                               configuration: NSWorkspace.OpenConfiguration())
        }]
    }
}
