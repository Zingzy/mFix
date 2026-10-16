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
    @AppStorage(Settings.K.snapKeys) private var snapKeys = SnapKeys.cmdOption.rawValue
    @AppStorage(Settings.K.minimizeKeys) private var minimizeKeys = true
    @AppStorage(Settings.K.dockNumbers) private var dockNumbers = true
    @AppStorage(Settings.K.finderKeys) private var finderKeys = true
    @AppStorage(Settings.K.finderZoom) private var finderZoom = true

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
            }
            Section {
                Toggle("Finder keys work like Explorer", isOn: $finderKeys)
                Text("Enter opens, F2 renames, Delete moves to the Trash, Shift+Delete deletes for good after asking, Cmd+X then Cmd+V moves files, Cmd+L types a path. Text fields keep their usual keys.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Pinch or Cmd+scroll steps from icons to list view", isOn: $finderZoom)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SnappingTab: View {
    @AppStorage(Settings.K.snapAssist) private var snapAssist = true
    @AppStorage(Settings.K.layoutsHover) private var layoutsHover = true
    @AppStorage(Settings.K.hoverDelay) private var hoverDelay = 0.6
    @AppStorage(Settings.K.dragSnap) private var dragSnap = true
    @AppStorage(Settings.K.snapGroups) private var snapGroups = true
    @AppStorage(Settings.K.animate) private var animate = true

    var body: some View {
        Form {
            Section {
                Toggle("When I snap a window, show what I can snap next to it", isOn: $snapAssist)
                Toggle("Snap a window by dragging it to a screen edge or corner", isOn: $dragSnap)
                Toggle("Slide windows into place when they snap", isOn: $animate)
                Toggle("Group windows I snap together; resize them together and show the group in the switcher", isOn: $snapGroups)
            }
            Section {
                Toggle("Show snap layouts when I hover over a window's green button", isOn: $layoutsHover)
                LabeledContent("Hover delay") {
                    HStack {
                        Slider(value: $hoverDelay, in: 0.1...1.5)
                        Text("\(Int((hoverDelay * 100).rounded()) * 10) ms").monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                }
                .disabled(!layoutsHover)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SwitcherTab: View {
    @AppStorage(Settings.K.switcher) private var switcher = true
    @AppStorage(Settings.K.allSpaces) private var allSpaces = true
    @AppStorage(Settings.K.showDelay) private var showDelay = 0.09
    @AppStorage(Settings.K.liveThumbnails) private var liveThumbnails = true

    var body: some View {
        Form {
            Section {
                Toggle("Replace Cmd+Tab with the Windows switcher", isOn: $switcher)
                Picker("Show windows from", selection: $allSpaces) {
                    Text("All Spaces").tag(true)
                    Text("Only the Space I'm on").tag(false)
                }
                .disabled(!switcher)
                LabeledContent("Wait before showing") {
                    HStack {
                        Slider(value: $showDelay, in: 0...0.4)
                        Text("\(Int((showDelay * 100).rounded()) * 10) ms").monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                }
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
    @AppStorage(Settings.K.dockPreviews) private var dockPreviews = true
    @AppStorage(Settings.K.dockClicks) private var dockClicks = true
    @AppStorage(Settings.K.dockDelay) private var dockDelay = 0.25

    var body: some View {
        Form {
            Section {
                Toggle("Show an app's windows when I hover its Dock icon", isOn: $dockPreviews)
                LabeledContent("Hover delay") {
                    HStack {
                        Slider(value: $dockDelay, in: 0...0.8)
                        Text("\(Int((dockDelay * 100).rounded()) * 10) ms").monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                }
                .disabled(!dockPreviews)
                Text("Windows waits 400 ms. Once one preview is open, moving to another icon switches at once.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Clicking the app I'm in minimizes it, or steps through its windows", isOn: $dockClicks)
            }
        }
        .formStyle(.grouped)
    }
}

private struct DragTab: View {
    @AppStorage(Settings.K.dragPreview) private var dragPreview = true
    @AppStorage(Settings.K.dockSpring) private var dockSpring = true
    @AppStorage(Settings.K.springDelay) private var springDelay = 0.5

    var body: some View {
        Form {
            Section {
                Toggle("Show a preview of what I'm dragging", isOn: $dragPreview)
                Toggle("Holding a drag on a Dock icon brings that app forward", isOn: $dockSpring)
                LabeledContent("Hold for") {
                    HStack {
                        Slider(value: $springDelay, in: 0.2...1.5)
                        Text("\(Int((springDelay * 100).rounded()) * 10) ms").monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                }
                .disabled(!dockSpring)
            }
        }
        .formStyle(.grouped)
    }
}
