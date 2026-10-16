import Foundation

/// `Snap11 --index-bench`: builds the file index over SNAP11_INDEX_ROOTS and reports scan
/// time, item count, memory and search speed, then checks a new file shows up through
/// FSEvents and a deleted one goes away.
public enum IndexBench {
    /// Physical footprint, the figure Activity Monitor shows as Memory.
    private static func residentMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        _ = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return Double(info.phys_footprint) / 1_048_576
    }

    public static func run() {
        let index = FileIndex.shared
        let mem0 = residentMB()
        let t0 = Date()
        index.start()
        while !index.ready { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        print("  ", index.sizes)
        print(String(format: "indexed %d items in %.1f s, memory %.0f MB -> %.0f MB", index.count, Date().timeIntervalSince(t0), mem0, residentMB()))
        for q in ["snap", "package.json", "readme", "a", "switcher swift", "zzzz-nothing"] {
            let t = Date()
            let hits = index.search(q)
            print(String(format: "  %-16@ %4d hits in %5.1f ms  first: %@", q as NSString, hits.count, Date().timeIntervalSince(t) * 1000, (hits.first?.path ?? "-") as NSString))
        }
        guard let root = index.roots.first else { exit(1) }
        let probe = root + "/snap11-index-probe-\(getpid()).txt"
        FileManager.default.createFile(atPath: probe, contents: Data("x".utf8))
        let t1 = Date()
        var seen = false
        while Date().timeIntervalSince(t1) < 8, !seen {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            seen = index.search("snap11-index-probe-\(getpid())").contains { $0.path == probe }
        }
        print(seen ? String(format: "ok   new file found after %.1f s", Date().timeIntervalSince(t1)) : "FAIL new file never showed up")
        try? FileManager.default.removeItem(atPath: probe)
        let t2 = Date()
        var gone = false
        while Date().timeIntervalSince(t2) < 8, !gone {
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            gone = !index.search("snap11-index-probe-\(getpid())").contains { $0.path == probe }
        }
        print(gone ? String(format: "ok   deleted file gone after %.1f s", Date().timeIntervalSince(t2)) : "FAIL deleted file still listed")
        exit(seen && gone ? 0 : 1)
    }
}
