import AppKit
import Snap11Core

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let args = CommandLine.arguments
var delegate: AppDelegate?
if let i = args.firstIndex(of: "--render"), args.count > i + 1 {
    MainActor.assumeIsolated { RenderCheck.run(into: args[i + 1]) }
} else if args.contains("--test-window") {
    MainActor.assumeIsolated { SnapCheck.showTestWindow() }
} else if let i = args.firstIndex(of: "--drive"), args.count > i + 1, let pid = pid_t(args[i + 1]) {
    MainActor.assumeIsolated { DriveCheck.run(snap11: pid) }
} else if args.contains("--snap-check") {
    MainActor.assumeIsolated { SnapCheck.run() }
} else {
    delegate = AppDelegate()
    app.delegate = delegate
}
app.run()
