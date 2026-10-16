import Foundation

/// `mFix --list-bench`: how long listing windows takes, as the app does it. A hung app shows
/// up here as seconds. MFIX_BENCH_PAUSE waits that many seconds between runs, like an idle app.
public enum ListBench {
    @MainActor
    public static func run() {
        AXWindow.limitWaits()
        let pause = Double(ProcessInfo.processInfo.environment["MFIX_BENCH_PAUSE"] ?? "") ?? 0
        for i in 0..<3 {
            if i > 0 && pause > 0 { RunLoop.main.run(until: Date().addingTimeInterval(pause)) }
            let t = Date()
            let all = WindowList.allSpaces()
            let t2 = Date()
            let here = WindowList.currentSpace()
            print("run \(i): all Spaces \(all.count) windows in \(ms(t, t2)) ms, this Space \(here.count) in \(ms(t2, Date())) ms")
        }
        exit(0)
    }

    private static func ms(_ a: Date, _ b: Date) -> Int { Int(b.timeIntervalSince(a) * 1000) }
}
