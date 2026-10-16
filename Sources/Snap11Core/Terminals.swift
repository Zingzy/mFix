import AppKit

/// The terminals Open in Terminal can use: whichever of these is installed.
enum Terminals {
    static let known: [(name: String, bundleID: String)] = [
        ("Ghostty", "com.mitchellh.ghostty"),
        ("cmux", "com.cmuxterm.app"),
        ("iTerm", "com.googlecode.iterm2"),
        ("Warp", "dev.warp.Warp-Stable"),
        ("Terminal", "com.apple.Terminal"),
    ]

    static var installed: [(name: String, bundleID: String)] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    static var chosen: String {
        let pick = Settings.terminal.value
        return installed.contains { $0.bundleID == pick } ? pick : installed.first?.bundleID ?? "com.apple.Terminal"
    }

    static func open(_ folder: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: chosen) else { return }
        NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
