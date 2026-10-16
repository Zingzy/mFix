import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The settings window, laid out like System Settings: a sidebar of sections and a grouped
/// form for each. Every control is bound to the same UserDefaults keys the features read,
/// so changes apply at once.
@MainActor
final class SettingsWindow {
    static let shared = SettingsWindow()
    static let size = NSSize(width: 720, height: 520)
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = Self.make(SettingsView())
            w.center()
            w.setFrameAutosaveName("Settings")
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    static func make(_ view: SettingsView) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.toolbarStyle = .unified
        w.isReleasedWhenClosed = false
        w.contentMinSize = size
        let host = NSHostingController(rootView: view)
        host.sceneBridgingOptions = .all
        host.sizingOptions = []
        w.contentViewController = host
        w.setContentSize(size)
        return w
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, snapping, switcher, desktop, dock, dragDrop, finder, alwaysOnTop, permissions, about

    static let groups: [[SettingsSection]] = [
        [.general],
        [.snapping, .switcher, .desktop, .dock, .dragDrop, .finder, .alwaysOnTop],
        [.permissions, .about],
    ]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .snapping: "Snapping"
        case .switcher: "Switcher"
        case .desktop: "Desktop"
        case .dock: "Dock"
        case .dragDrop: "Drag and drop"
        case .finder: "Finder"
        case .alwaysOnTop: "Always on Top"
        case .permissions: "Permissions"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .snapping: "rectangle.split.2x2.fill"
        case .switcher: "rectangle.stack.fill"
        case .desktop: "macwindow.on.rectangle"
        case .dock: "dock.rectangle"
        case .dragDrop: "hand.draw.fill"
        case .finder: "folder.fill"
        case .alwaysOnTop: "pin.fill"
        case .permissions: "hand.raised.fill"
        case .about: "info"
        }
    }

    var tint: Color {
        switch self {
        case .general, .about: .gray
        case .snapping, .permissions: .blue
        case .switcher: .indigo
        case .desktop: .teal
        case .dock: .purple
        case .dragDrop: .orange
        case .finder: .cyan
        case .alwaysOnTop: .red
        }
    }

    var blurb: String {
        switch self {
        case .general: "Start Snap11 at login and pick the keys that stand in for the Windows key."
        case .snapping: "Snap windows to halves, quarters and layouts, the way Windows 11 does."
        case .switcher: "Cmd+Tab shows your windows instead of your apps, like Alt+Tab on Windows."
        case .desktop: "Clear the screen down to one window, or down to the desktop."
        case .dock: "Hover an icon to see its windows. Click icons like taskbar buttons."
        case .dragDrop: "See what you are dragging, and hold it over the Dock to bring an app forward."
        case .finder: "Finder takes the keys you know from File Explorer."
        case .alwaysOnTop: "Keep one window above all the others."
        case .permissions: "What Snap11 needs from macOS, and whether it has it."
        case .about: "Windows 11 window management for macOS."
        }
    }

    /// Words a search in the sidebar matches besides the title.
    var keywords: String {
        switch self {
        case .general: "login startup windows key win modifier command option control"
        case .snapping: "snap assist layouts drag edge corner groups hover green button delay arrow"
        case .switcher: "cmd tab alt tab spaces delay thumbnails live windows"
        case .desktop: "minimize home show desktop activity monitor task manager"
        case .dock: "previews hover delay click minimize cycle numbers taskbar"
        case .dragDrop: "preview spring loading hold delay files"
        case .finder: "explorer enter rename delete trash cut paste path terminal ghostty iterm warp"
        case .alwaysOnTop: "pin float window front"
        case .permissions: "accessibility screen recording automation privacy security"
        case .about: "version github source license"
        }
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || "\(title) \(keywords)".localizedCaseInsensitiveContains(query)
    }
}

struct SettingsView: View {
    @AppStorage("settings.section") private var stored: SettingsSection = .general
    @State private var query = ""
    /// Shows this section without touching the remembered one, for the render check.
    private let pinned: SettingsSection?

    init(pinned: SettingsSection? = nil) { self.pinned = pinned }

    var body: some View {
        let section = pinned ?? stored
        NavigationSplitView {
            List(selection: Binding<SettingsSection?>(get: { section }, set: { if let s = $0 { stored = s } })) {
                ForEach(SettingsSection.groups, id: \.self) { group in
                    Section {
                        ForEach(group.filter { $0.matches(query) }) { s in
                            Label { Text(s.title) } icon: { SectionIcon(section: s) }
                                .tag(s)
                        }
                    }
                }
            }
            .frame(minWidth: 215)
            .navigationSplitViewColumnWidth(215)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            SectionPane(section: section)
        }
        .navigationTitle(section.title)
        .searchable(text: $query, placement: .sidebar)
        .frame(minWidth: SettingsWindow.size.width, minHeight: SettingsWindow.size.height)
    }
}

/// The white glyph on a colored rounded square that System Settings puts beside each pane.
private struct SectionIcon: View {
    let section: SettingsSection
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: section.symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(section.tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    }
}

private struct SectionPane: View {
    let section: SettingsSection

    var body: some View {
        Form {
            Section {
                VStack(spacing: 6) {
                    SectionIcon(section: section, size: 56)
                        .padding(.bottom, 4)
                    Text(section == .about ? "Snap11" : section.title).font(.title2.bold())
                    Text(section.blurb)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            switch section {
            case .general: GeneralPane()
            case .snapping: SnappingPane()
            case .switcher: SwitcherPane()
            case .desktop: DesktopPane()
            case .dock: DockPane()
            case .dragDrop: DragPane()
            case .finder: FinderPane()
            case .alwaysOnTop: AlwaysOnTopPane()
            case .permissions: PermissionsPane()
            case .about: AboutPane()
            }
        }
        .formStyle(.grouped)
    }
}

private struct GeneralPane: View {
    @State private var launchAtLogin = Settings.launchAtLogin
    @AppStorage(Settings.snapKeys) private var snapKeys: String

    var body: some View {
        Section {
            Toggle("Open Snap11 at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, on in Settings.launchAtLogin = on }
        }
        Section {
            Picker(selection: $snapKeys) {
                ForEach(SnapKeys.allCases) { Text($0.label).tag($0.rawValue) }
            } label: {
                Text("Windows key")
                Text("Every Win shortcut uses these keys, such as Win+Arrow, Win+Z and Win+D.")
            }
        } footer: {
            Text("Pick another pair if Cmd+Option clashes with an app you use.")
        }
    }
}

private struct SnappingPane: View {
    @AppStorage(Settings.snapAssist) private var snapAssist: Bool
    @AppStorage(Settings.dragSnap) private var dragSnap: Bool
    @AppStorage(Settings.snapGroups) private var snapGroups: Bool
    @AppStorage(Settings.layoutsHover) private var layoutsHover: Bool
    @AppStorage(Settings.hoverDelay) private var hoverDelay: Double

    var body: some View {
        Section {
            Toggle(isOn: $snapAssist) {
                Text("Snap Assist")
                Text("After a window snaps, pick another window to fill the rest of the screen.")
            }
            Toggle(isOn: $dragSnap) {
                Text("Drag to snap")
                Text("Drag a window to a screen edge for a half, a corner for a quarter, or the top to maximize.")
            }
            Toggle(isOn: $snapGroups) {
                Text("Snap groups")
                Text("Windows snapped together resize together and show as one card in the switcher.")
            }
        } footer: {
            Text("Turn off \"Drag windows to screen edges to tile\" in Desktop & Dock, or both will show a preview.")
        }
        Section("Snap Layouts") {
            Toggle(isOn: $layoutsHover) {
                Text("Show on hover")
                Text("Hover a window's green button to see a grid of layouts.")
            }
            DelaySlider(title: "Hover delay", value: $hoverDelay, range: 0.1...1.5)
                .disabled(!layoutsHover)
        }
        Shortcuts(rows: { win in [
            ("Snap to the left or right half", [chord(win, "←"), chord(win, "→")]),
            ("Maximize, or the top quarter from a half", [chord(win, "↑")]),
            ("Restore, the bottom quarter, or minimize", [chord(win, "↓")]),
            ("Snap to the top or bottom half", [chord(Hotkey.winAlt, "↑"), chord(Hotkey.winAlt, "↓")]),
            ("Move to the next display", [chord(win | shiftKey, "←"), chord(win | shiftKey, "→")]),
            ("Stretch to the full height", [chord(win | shiftKey, "↑")]),
            ("Restore the size before snapping", [chord(win | shiftKey, "↓")]),
            ("Open Snap Layouts with the keyboard", [chord(win, "Z")]),
        ] })
    }
}

private struct SwitcherPane: View {
    @AppStorage(Settings.switcher) private var switcher: Bool
    @AppStorage(Settings.allSpaces) private var allSpaces: Bool
    @AppStorage(Settings.showDelay) private var showDelay: Double
    @AppStorage(Settings.liveThumbnails) private var liveThumbnails: Bool

    var body: some View {
        Section {
            Toggle("Replace Cmd+Tab with the window switcher", isOn: $switcher)
            Group {
                Picker("Show windows from", selection: $allSpaces) {
                    Text("All Spaces").tag(true)
                    Text("Only the current Space").tag(false)
                }
                DelaySlider(title: "Wait before showing", value: $showDelay, range: 0...0.4)
            }
            .disabled(!switcher)
        } footer: {
            Text("A quick Cmd+Tab under this delay switches without showing the panel.")
        }
        Section {
            Toggle(isOn: $liveThumbnails) {
                Text("Live thumbnails")
                Text("Windows on screen refresh three times a second while the switcher, Snap Assist or a Dock preview is open. Nothing runs while they are closed.")
            }
        }
        Shortcuts(rows: { _ in [
            ("Next window", [chord(cmdKey, "⇥")]),
            ("Previous window", [chord(cmdKey | shiftKey, "⇥")]),
            ("Open and keep open", [chord(cmdKey | controlKey, "⇥")]),
            ("Switch to the highlighted window", ["↩"]),
            ("Close the highlighted window", ["⌫", "W"]),
            ("Close the switcher", ["⎋"]),
        ] })
        .disabled(!switcher)
    }
}

private struct DesktopPane: View {
    @AppStorage(Settings.minimizeKeys) private var minimizeKeys: Bool

    var body: some View {
        Section {
            Toggle(isOn: $minimizeKeys) {
                Text("Minimize and show the desktop")
                Text("Win+Home minimizes every window but the front one. Win+D minimizes them all. Press either again to bring them back.")
            }
        }
        Shortcuts(rows: { win in
            (minimizeKeys ? [
                ("Minimize the other windows", [chord(win, "↖")]),
                ("Show the desktop", [chord(win, "D")]),
            ] : []) + [("Open Activity Monitor", [chord(cmdKey | shiftKey, "⎋")])]
        })
    }
}

private struct DockPane: View {
    @AppStorage(Settings.dockPreviews) private var dockPreviews: Bool
    @AppStorage(Settings.dockDelay) private var dockDelay: Double
    @AppStorage(Settings.dockClicks) private var dockClicks: Bool
    @AppStorage(Settings.dockNumbers) private var dockNumbers: Bool

    var body: some View {
        Section {
            Toggle(isOn: $dockPreviews) {
                Text("Window previews")
                Text("Hover an app's icon to see its windows as cards above it.")
            }
            DelaySlider(title: "Hover delay", value: $dockDelay, range: 0...0.8)
                .disabled(!dockPreviews)
        } footer: {
            Text("Windows waits about 400 ms. Once one preview is open, moving to another icon switches at once.")
        }
        Section {
            Toggle(isOn: $dockClicks) {
                Text("Click to minimize")
                Text("Clicking the app you are in minimizes it, or steps through its windows.")
            }
            Toggle(isOn: $dockNumbers) {
                Text("Number keys open Dock apps")
                Text("Win+1 to 9 opens the app in that spot, brings it forward, or steps through its windows.")
            }
        }
        Shortcuts(rows: { win in
            dockNumbers ? [("Open an app by its place in the Dock", [chord(win, "1"), "to", chord(win, "9")])] : []
        })
    }
}

private struct DragPane: View {
    @AppStorage(Settings.dragPreview) private var dragPreview: Bool
    @AppStorage(Settings.dockSpring) private var dockSpring: Bool
    @AppStorage(Settings.springDelay) private var springDelay: Double

    var body: some View {
        Section {
            Toggle(isOn: $dragPreview) {
                Text("Drag preview")
                Text("A small preview of the files, image or text you are dragging sits next to the pointer.")
            }
        }
        Section {
            Toggle(isOn: $dockSpring) {
                Text("Spring-loaded Dock icons")
                Text("Hold a drag over an app's Dock icon to bring its window forward, then drop into it.")
            }
            DelaySlider(title: "Hold for", value: $springDelay, range: 0.2...1.5)
                .disabled(!dockSpring)
        }
    }
}

private struct FinderPane: View {
    @AppStorage(Settings.finderKeys) private var finderKeys: Bool
    @AppStorage(Settings.terminal) private var terminal: String

    var body: some View {
        Section {
            Toggle(isOn: $finderKeys) {
                Text("Explorer keys in Finder")
                Text("Only while focus is on files. Renaming, the search field and dialogs keep their usual keys.")
            }
            Picker("Open folders in", selection: $terminal) {
                ForEach(Terminals.installed, id: \.bundleID) { Text($0.name).tag($0.bundleID) }
            }
            .disabled(!finderKeys)
        }
        Shortcuts(rows: { _ in [
            ("Open", ["↩"]),
            ("Rename", ["F2"]),
            ("Move to the Trash", ["⌫"]),
            ("Delete for good, after asking", [chord(shiftKey, "⌫")]),
            ("Cut, then move the files", [chord(cmdKey, "X"), "then", chord(cmdKey, "V")]),
            ("Go to a typed path", [chord(cmdKey, "L")]),
            ("Open this folder in the terminal", [chord(cmdKey | optionKey, "T")]),
        ] })
        .disabled(!finderKeys)
    }
}

private struct AlwaysOnTopPane: View {
    @AppStorage(Settings.alwaysOnTop) private var alwaysOnTop: Bool

    var body: some View {
        Section {
            Toggle(isOn: $alwaysOnTop) {
                Text("Always on Top")
                Text("A pinned window gets an accent border and stays above other apps until you unpin or close it.")
            }
        }
        Shortcuts(rows: { _ in [("Pin or unpin the front window", [chord(Hotkey.winAlt, "T")])] })
            .disabled(!alwaysOnTop)
    }
}

private struct PermissionsPane: View {
    @State private var accessibility = AXIsProcessTrusted()
    @State private var screenRecording = Thumbnails.permitted
    @State private var automation: OSStatus = noErr

    var body: some View {
        Section {
            PermissionRow(title: "Accessibility",
                          detail: "Moves and resizes windows and watches the keys and mouse. Nothing works without it.",
                          state: accessibility ? "Allowed" : "Not allowed", pane: "Privacy_Accessibility")
            PermissionRow(title: "Screen Recording",
                          detail: "Window thumbnails, and the live copy Always on Top floats over other apps.",
                          state: screenRecording ? "Allowed" : "Not allowed", pane: "Privacy_ScreenCapture")
            PermissionRow(title: "Automation for Finder",
                          detail: "Lets Cmd+V move files into the selected folder. macOS asks the first time.",
                          state: automationState, pane: "Privacy_Automation")
        } footer: {
            Text("macOS ties these to the app's signature. If one stops working after an update, remove Snap11 from that list and add it again.")
        }
        .task {
            while !Task.isCancelled {
                accessibility = AXIsProcessTrusted()
                screenRecording = Thumbnails.permitted
                automation = await Task.detached { Self.finderAutomation() }.value
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var automationState: String {
        switch Int(automation) {
        case Int(noErr): "Allowed"
        case errAEEventNotPermitted: "Not allowed"
        default: "Not asked yet"
        }
    }

    /// askUserIfNeeded false: reads the grant without showing the consent prompt.
    nonisolated private static func finderAutomation() -> OSStatus {
        let finder = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let desc = finder.aeDesc else { return OSStatus(procNotFound) }
        return AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let state: String
    let pane: String

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                Text(state).foregroundStyle(.secondary)
                Button("Open") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
                }
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

private struct AboutPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let short = info["CFBundleShortVersionString"] as? String else { return "Development build" }
        let build = info["CFBundleVersion"] as? String ?? ""
        return build.isEmpty || build == short ? short : "\(short) (\(build))"
    }

    var body: some View {
        Section {
            LabeledContent("Version", value: version)
            LabeledContent("Source code") {
                Link("github.com/Zingzy/mFix", destination: URL(string: "https://github.com/Zingzy/mFix")!)
            }
            LabeledContent("License", value: "MIT")
        } footer: {
            Text("Not affiliated with Microsoft or Apple.")
        }
    }
}

/// Read-only rows: what a chord does on the left, the chord on the right.
private struct Shortcuts: View {
    let rows: (Int) -> [(String, [String])]
    @AppStorage(Settings.snapKeys) private var snapKeys: String

    var body: some View {
        let list = rows((SnapKeys(rawValue: snapKeys) ?? .cmdOption).modifiers)
        if !list.isEmpty {
            Section("Keyboard shortcuts") {
                ForEach(list, id: \.0) { label, keys in
                    LabeledContent(label) {
                        HStack(spacing: 6) {
                            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in Text(key) }
                        }
                        .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

/// A Carbon modifier mask and a key, written the way macOS menus write them.
func chord(_ modifiers: Int, _ key: String) -> String {
    let symbols: [(Int, String)] = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
    return symbols.filter { modifiers & $0.0 != 0 }.map(\.1).joined() + key
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
                Text("\(Int((value * 100).rounded()) * 10) ms")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }
}
