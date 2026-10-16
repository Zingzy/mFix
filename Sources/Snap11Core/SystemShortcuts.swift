import Foundation

/// macOS's own shortcuts that fire before any app's hotkey and so must be switched off
/// for Snap11 to own the chord: 1 and 2 are Cmd+Tab and Cmd+Shift+Tab, 52 is Cmd+Option+D
/// (Dock hiding). The switch outlives the process, so each one's original state is saved
/// to disk before Snap11 first turns it off, and put back on every way out, including the
/// launch after a kill -9.
enum SystemShortcuts {
    static let switcher: [Int32] = [1, 2]
    static let dockHiding: Int32 = 52
    private static let key = "system.shortcutsBeforeSnap11"

    /// Read by the signal handlers, so a plain array rather than anything that allocates.
    nonisolated(unsafe) private static var saved: [(Int32, Bool)] = []

    static func recoverAfterCrash() {
        guard let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] else { return }
        for (id, on) in stored { if let i = Int32(id) { SkyLight.setSymbolicHotKey(i, enabled: on) } }
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// Turns off exactly the ids in `off`; any id Snap11 turned off earlier and no longer
    /// needs goes back to how it was.
    static func suspend(_ off: [Int32]) {
        for (id, on) in saved where !off.contains(id) { SkyLight.setSymbolicHotKey(id, enabled: on) }
        saved = saved.filter { off.contains($0.0) }
        for id in off where !saved.contains(where: { $0.0 == id }) {
            saved.append((id, SkyLight.isSymbolicHotKeyEnabled(id)))
        }
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: saved.map { ("\($0.0)", $0.1) }), forKey: key)
        for id in off { SkyLight.setSymbolicHotKey(id, enabled: false) }
    }

    static func restoreAll() {
        for (id, on) in saved { SkyLight.setSymbolicHotKey(id, enabled: on) }
        saved = []
        UserDefaults.standard.removeObject(forKey: key)
    }

    /// From a signal handler: no Foundation, just the SkyLight calls.
    static func restoreFromSignal() {
        for (id, on) in saved { SkyLight.setSymbolicHotKey(id, enabled: on) }
    }
}
