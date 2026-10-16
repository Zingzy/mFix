import AppKit
import SwiftUI

/// The settings window: a plain macOS form, one tab per area. Every control is bound to
/// the same UserDefaults keys the features read, so changes apply at once.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Snap11 Settings"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: SettingsView())
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    var tab = 0

    var body: some View {
        TabView(selection: .constant(tab)) {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }.tag(0)
            SnappingTab().tabItem { Label("Snapping", systemImage: "rectangle.split.2x2") }.tag(1)
            SwitcherTab().tabItem { Label("Switcher", systemImage: "square.on.square") }.tag(2)
            DockTab().tabItem { Label("Dock", systemImage: "dock.rectangle") }.tag(3)
            DragTab().tabItem { Label("Drag and drop", systemImage: "hand.draw") }.tag(4)
        }
        .frame(width: 520, height: 440)
    }
}

private struct GeneralTab: View {
    @State private var launchAtLogin = Settings.launchAtLogin
    @AppStorage(Settings.snapKeys) private var snapKeys: String
    @AppStorage(Settings.minimizeKeys) private var minimizeKeys: Bool
    @AppStorage(Settings.dockNumbers) private var dockNumbers: Bool
    @AppStorage(Settings.alwaysOnTop) private var alwaysOnTop: Bool
    @AppStorage(Settings.finderKeys) private var finderKeys: Bool
    @AppStorage(Settings.terminal) private var terminal: String

    var body: some View {
        Form {
            Section {
                Toggle("Open Snap11 at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in Settings.launchAtLogin = on }
            }
            Section {
                Picker("Windows key", selection: $snapKeys) {
                    ForEach(SnapKeys.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Text("Stands in for the Windows key in every Win shortcut: Win+Arrow, Win+Z, Win+Home, Win+D.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Win+Home minimizes other windows, Win+D shows the desktop", isOn: $minimizeKeys)
                Toggle("Win+1 to 9 open or switch to the apps in the Dock", isOn: $dockNumbers)
                Toggle("Win+Ctrl+T keeps the window in front on top of the others", isOn: $alwaysOnTop)
            }
            Section {
                Toggle("Finder keys work like Explorer", isOn: $finderKeys)
                Text("Enter opens, F2 renames, Delete moves to the Trash, Shift+Delete deletes for good after asking, Cmd+X then Cmd+V moves files, Cmd+L types a path. Text fields keep their usual keys.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Cmd+Option+T opens the folder in", selection: $terminal) {
                    ForEach(Terminals.installed, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
                }
                .disabled(!finderKeys)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SnappingTab: View {
    @AppStorage(Settings.snapAssist) private var snapAssist: Bool
    @AppStorage(Settings.layoutsHover) private var layoutsHover: Bool
    @AppStorage(Settings.hoverDelay) private var hoverDelay: Double
    @AppStorage(Settings.dragSnap) private var dragSnap: Bool
    @AppStorage(Settings.snapGroups) private var snapGroups: Bool

    var body: some View {
        Form {
            Section {
                Toggle("When I snap a window, show what I can snap next to it", isOn: $snapAssist)
                Toggle("Snap a window by dragging it to a screen edge or corner", isOn: $dragSnap)
                Toggle("Group windows I snap together; resize them together and show the group in the switcher", isOn: $snapGroups)
            }
            Section {
                Toggle("Show snap layouts when I hover over a window's green button", isOn: $layoutsHover)
                DelaySlider(title: "Hover delay", value: $hoverDelay, range: 0.1...1.5)
                .disabled(!layoutsHover)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SwitcherTab: View {
    @AppStorage(Settings.switcher) private var switcher: Bool
    @AppStorage(Settings.allSpaces) private var allSpaces: Bool
    @AppStorage(Settings.showDelay) private var showDelay: Double
    @AppStorage(Settings.liveThumbnails) private var liveThumbnails: Bool

    var body: some View {
        Form {
            Section {
                Toggle("Replace Cmd+Tab with the Windows switcher", isOn: $switcher)
                Picker("Show windows from", selection: $allSpaces) {
                    Text("All Spaces").tag(true)
                    Text("Only the Space I'm on").tag(false)
                }
                .disabled(!switcher)
                DelaySlider(title: "Wait before showing", value: $showDelay, range: 0...0.4)
                .disabled(!switcher)
                Text("A quick Cmd+Tab under this delay switches without showing the panel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Live thumbnails", isOn: $liveThumbnails)
                Text("While the switcher, Snap Assist or a Dock preview is open, windows on screen refresh three times a second. Nothing runs while they are closed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DockTab: View {
    @AppStorage(Settings.dockPreviews) private var dockPreviews: Bool
    @AppStorage(Settings.dockClicks) private var dockClicks: Bool
    @AppStorage(Settings.dockDelay) private var dockDelay: Double

    var body: some View {
        Form {
            Section {
                Toggle("Show an app's windows when I hover its Dock icon", isOn: $dockPreviews)
                DelaySlider(title: "Hover delay", value: $dockDelay, range: 0...0.8)
                .disabled(!dockPreviews)
                Text("Windows waits about 400 ms. Once one preview is open, moving to another icon switches at once.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Clicking the app I'm in minimizes it, or steps through its windows", isOn: $dockClicks)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DragTab: View {
    @AppStorage(Settings.dragPreview) private var dragPreview: Bool
    @AppStorage(Settings.dockSpring) private var dockSpring: Bool
    @AppStorage(Settings.springDelay) private var springDelay: Double

    var body: some View {
        Form {
            Section {
                Toggle("Show a preview of what I'm dragging", isOn: $dragPreview)
                Toggle("Holding a drag on a Dock icon brings that app forward", isOn: $dockSpring)
                DelaySlider(title: "Hold for", value: $springDelay, range: 0.2...1.5)
                .disabled(!dockSpring)
            }
        }
        .formStyle(.grouped)
    }
}

/// A delay in seconds, shown in milliseconds rounded to tens.
private struct DelaySlider: View {
    let title: LocalizedStringKey
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        LabeledContent(title) {
            HStack {
                Slider(value: $value, in: range)
                Text("\(Int((value * 100).rounded()) * 10) ms").monospacedDigit().frame(width: 64, alignment: .trailing)
            }
        }
    }
}
