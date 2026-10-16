import AppKit
import Carbon.HIToolbox
import Testing
@testable import Snap11Core

@MainActor
@Suite struct HotkeyTests {
    init() { _ = NSApplication.shared }

    private func chords(_ keys: SnapKeys) -> [Hotkey] { allFeatures.flatMap { $0.hotkeys(win: keys.modifiers) } }

    @Test func defaultsBindTheWholeWindowsTable() {
        let win = cmdKey | optionKey
        var expected = [Key.left, Key.right, Key.up, Key.down].map { "\($0)/\(win)" }
        expected += ["\(Key.up)/\(Hotkey.winAlt)", "\(Key.down)/\(Hotkey.winAlt)"]
        expected += [Key.left, Key.right, Key.up, Key.down].map { "\($0)/\(win | shiftKey)" }
        expected += [Key.home, Key.d].map { "\($0)/\(win)" } + Key.digits.map { "\($0)/\(win)" }
        expected += ["\(Key.escape)/\(cmdKey | shiftKey)", "\(Key.t)/\(Hotkey.winAlt)", "\(Key.z)/\(win)"]
        expected += ["\(Key.tab)/\(cmdKey)", "\(Key.tab)/\(cmdKey | shiftKey)", "\(Key.tab)/\(cmdKey | controlKey)"]
        let bound = chords(.cmdOption).map { "\($0.key)/\($0.modifiers)" }
        #expect(bound.count == expected.count)
        #expect(Set(bound) == Set(expected))
    }

    @Test func onlyTheSwitcherRepeats() {
        #expect(chords(.cmdOption).filter(\.repeats).allSatisfy { $0.key == Key.tab })
        #expect(chords(.cmdOption).filter(\.repeats).count == 3)
    }

    /// Cmd+Option+D is macOS's Dock hiding chord, so only that Windows key turns it off.
    @Test func systemShortcutsFollowTheWindowsKey() {
        #expect(Set(chords(.cmdOption).flatMap(\.replaces)) == [SystemShortcuts.cmdTab, SystemShortcuts.cmdShiftTab, SystemShortcuts.dockHiding])
        #expect(Set(chords(.ctrlCmd).flatMap(\.replaces)) == [SystemShortcuts.cmdTab, SystemShortcuts.cmdShiftTab])
    }

    @Test func windowsKeyChoices() {
        #expect(SnapKeys.cmdOption.modifiers == cmdKey | optionKey)
        #expect(SnapKeys.ctrlOption.modifiers == controlKey | optionKey)
        #expect(SnapKeys.ctrlCmd.modifiers == controlKey | cmdKey)
    }
}

@Suite struct SettingTests {
    @Test func unsetKeyReadsItsDefault() {
        #expect(Setting<Double>(key: "snap11.test.unset", initial: 0.25).value == 0.25)
        #expect(Setting(key: "snap11.test.unset", initial: true).value)
    }

    @Test func storedValueWins() {
        let key = "snap11.test.stored"
        UserDefaults.standard.set(false, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }
        #expect(Setting(key: key, initial: true).value == false)
    }
}

@Suite struct WindowInfoTests {
    @Test func readsAWindowServerRow() {
        let row: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: 42), kCGWindowOwnerPID as String: NSNumber(value: 7),
            kCGWindowLayer as String: NSNumber(value: 0), kCGWindowAlpha as String: NSNumber(value: 1.0),
            kCGWindowBounds as String: CGRect(x: 10, y: 20, width: 300, height: 200).dictionaryRepresentation,
            kCGWindowName as String: "Notes", kCGWindowOwnerName as String: "TextEdit",
        ]
        let w = WindowInfo(row)
        #expect(w?.id == 42 && w?.pid == 7 && w?.layer == 0 && w?.alpha == 1)
        #expect(w?.bounds == CGRect(x: 10, y: 20, width: 300, height: 200))
        #expect(w?.name == "Notes" && w?.owner == "TextEdit")
    }

    @Test func aRowWithoutBoundsIsSkipped() {
        #expect(WindowInfo([kCGWindowNumber as String: NSNumber(value: 1), kCGWindowOwnerPID as String: NSNumber(value: 2)]) == nil)
    }
}
