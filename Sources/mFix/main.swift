import AppKit
import mFixCore

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let args = CommandLine.arguments
var delegate: AppDelegate?
if let i = args.firstIndex(of: "--render"), args.count > i + 1 {
    MainActor.assumeIsolated { RenderCheck.run(into: args[i + 1]) }
} else if let i = args.firstIndex(of: "--test-windows"), args.count > i + 1, let n = Int(args[i + 1]) {
    MainActor.assumeIsolated { SnapCheck.showTestWindow(count: n) }
} else if args.contains("--test-window") {
    MainActor.assumeIsolated { SnapCheck.showTestWindow() }
} else if let i = args.firstIndex(of: "--assist-check"), args.count > i + 1, let pid = pid_t(args[i + 1]) {
    MainActor.assumeIsolated { DriveCheck.assist(app: pid) }
} else if let i = args.firstIndex(of: "--drive"), args.count > i + 1, let pid = pid_t(args[i + 1]) {
    MainActor.assumeIsolated { DriveCheck.run(app: pid) }
} else if args.contains("--guard-test") {
    MainActor.assumeIsolated {
        CheckGuard.begin()
        print("guard armed: no recent input; watching for 5 s without sending anything")
        for _ in 0..<50 { CheckGuard.poll(); usleep(100_000) }
        print("no real input seen")
        exit(0)
    }
} else if args.contains("--live-bench") {
    MainActor.assumeIsolated { LiveBench.run() }
} else if args.contains("--finder-probe") {
    MainActor.assumeIsolated { FinderProbe.run() }
} else if let i = args.firstIndex(of: "--dock-check"), args.count > i + 1, let pid = pid_t(args[i + 1]) {
    MainActor.assumeIsolated { DockCheck.run(app: pid) }
} else if args.contains("--corners") {
    MainActor.assumeIsolated { WindowCorners.report() }
} else if args.contains("--pin-check") {
    MainActor.assumeIsolated { PinCheck.run() }
} else if args.contains("--divider-check") {
    MainActor.assumeIsolated { DividerCheck.run() }
} else if args.contains("--finder-check") {
    MainActor.assumeIsolated { FinderCheck.run() }
} else if args.contains("--minimize-check") {
    MainActor.assumeIsolated { SnapCheck.minimizeCheck() }
} else if args.contains("--assist-repro") {
    DispatchQueue.main.async { MainActor.assumeIsolated { AssistRepro.run() } }
} else if args.contains("--snap-check") {
    MainActor.assumeIsolated { SnapCheck.run() }
} else if let unknown = args.dropFirst().first(where: { $0.hasPrefix("--") }) {
    // A typo or a flag from a newer build must never start a second copy of the app.
    FileHandle.standardError.write("mFix: unknown flag \(unknown)\n".data(using: .utf8)!)
    exit(64)
} else {
    delegate = AppDelegate()
    app.delegate = delegate
}
app.run()
