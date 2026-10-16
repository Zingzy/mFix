import Foundation

/// An in-memory index of file names, the way fsearch and Everything work: one scan of the
/// home folder and /Applications at start, kept current from FSEvents, and searched by
/// scanning lowercased names, which takes milliseconds for a million files. Generated
/// folders (node_modules, .git, build caches, anything holding a CACHEDIR.TAG) are skipped;
/// app bundles and other packages count as one item, as Finder shows them.
final class FileIndex: @unchecked Sendable {
    static let shared = FileIndex()

    struct Entry {
        var name: Range<Int32>
        /// Into `lowers`, or into `names` when the name is already lowercase.
        var lower: Range<Int32>
        var parent: Int32
        var isDir: Bool
        var deleted: Bool
        var lowerInNames: Bool
    }

    struct Hit {
        let path: String
        let name: String
        let isDir: Bool
    }

    static let skipped: Set<String> = ["node_modules", ".git", ".build", "DerivedData", ".next", ".turbo", ".cache",
                                       "__pycache__", ".venv", "venv", "Pods", ".gradle", ".Trash", ".npm", ".pnpm-store"]
    /// Reading other apps' containers makes macOS ask for "data from other apps"; Caches is a cache.
    static let guarded: Set<String> = ["Library/Containers", "Library/Group Containers", "Library/Caches"]
        .reduce(into: Set<String>()) { $0.insert(NSHomeDirectory() + "/" + $1) }
    private static let packages: Set<String> = ["app", "bundle", "framework", "photoslibrary", "plugin", "kext", "xcarchive",
                                                "pkg", "mpkg", "rtfd", "pages", "numbers", "key", "logicx", "fcpbundle"]

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var names: [UInt8] = []
    private var lowers: [UInt8] = []
    private var dirs: [Int: Int32] = [:]
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "snap11.file-index", qos: .utility)
    private(set) var ready = false
    private(set) var count = 0

    var roots: [String] {
        if let custom = ProcessInfo.processInfo.environment["SNAP11_INDEX_ROOTS"] { return custom.split(separator: ":").map(String.init) }
        return [NSHomeDirectory(), "/Applications"]
    }

    func start() {
        queue.async { self.build() }
    }

    // MARK: Building

    private func build() {
        var b = Builder()
        for root in roots {
            let r = b.add(name: root, parent: -1, isDir: true)
            b.dirs[root.hashValue] = r
            b.scan(root, index: r)
        }
        lock.lock()
        entries = b.entries
        names = b.names
        lowers = b.lowers
        dirs = b.dirs
        count = b.entries.count
        ready = true
        lock.unlock()
        DispatchQueue.main.async { self.watch() }
    }

    private struct Builder {
        var entries: [Entry] = []
        var names: [UInt8] = []
        var lowers: [UInt8] = []
        var dirs: [Int: Int32] = [:]

        mutating func add(name: String, parent: Int32, isDir: Bool) -> Int32 {
            let n0 = Int32(names.count)
            names.append(contentsOf: name.utf8)
            let nameRange = n0..<Int32(names.count)
            let low = name.lowercased()
            if low == name {
                entries.append(Entry(name: nameRange, lower: nameRange, parent: parent, isDir: isDir, deleted: false, lowerInNames: true))
            } else {
                let l0 = Int32(lowers.count)
                lowers.append(contentsOf: low.utf8)
                entries.append(Entry(name: nameRange, lower: l0..<Int32(lowers.count), parent: parent, isDir: isDir, deleted: false, lowerInNames: false))
            }
            return Int32(entries.count - 1)
        }

        /// Children of `path`, recursing into folders. readdir's d_type says whether an
        /// entry is a folder without a stat per file.
        mutating func scan(_ path: String, index: Int32) {
            if FileIndex.guarded.contains(path) { return }
            for (name, isDir) in FileIndex.list(path) {
                let child = path == "/" ? "/" + name : path + "/" + name
                let folder = isDir && !FileIndex.isPackage(name)
                let i = add(name: name, parent: index, isDir: isDir)
                if folder && !FileIndex.skipped.contains(name) {
                    dirs[child.hashValue] = i
                    scan(child, index: i)
                }
            }
        }
    }

    static func isPackage(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return packages.contains(String(name[name.index(after: dot)...]).lowercased())
    }

    /// One folder's entries; empty for a folder that is unreadable or holds a CACHEDIR.TAG.
    static func list(_ path: String) -> [(String, Bool)] {
        guard let d = opendir(path) else { return [] }
        defer { closedir(d) }
        var out: [(String, Bool)] = []
        while let e = readdir(d) {
            let name = withUnsafePointer(to: e.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(e.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            if name == "CACHEDIR.TAG" { return [] }
            out.append((name, e.pointee.d_type == DT_DIR))
        }
        return out
    }

    // MARK: Staying current

    private func watch() {
        let paths = roots as CFArray
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            let me = Unmanaged<FileIndex>.fromOpaque(info!).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.queue.async { me.refresh(Set(list.prefix(count))) }
        }
        guard let s = FSEventStreamCreate(nil, callback, &context, paths, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }

    /// FSEvents names folders whose contents changed. Each is read again: children that are
    /// gone are marked deleted, new ones are added, and a new folder is scanned whole.
    private func refresh(_ changed: Set<String>) {
        for raw in changed {
            let path = raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            if path.split(separator: "/").contains(where: { FileIndex.skipped.contains(String($0)) }) { continue }
            lock.lock()
            guard let dirIndex = dirs[path.hashValue] else { lock.unlock(); continue }
            var existing: [String: Int] = [:]
            for i in entries.indices where entries[i].parent == dirIndex && !entries[i].deleted {
                existing[name(at: i)] = i
            }
            lock.unlock()

            let now = Dictionary(FileIndex.list(path), uniquingKeysWith: { a, _ in a })
            lock.lock()
            for (n, i) in existing where now[n] == nil {
                entries[i].deleted = true
                dirs[(path + "/" + n).hashValue] = nil
            }
            lock.unlock()
            for (n, isDir) in now where existing[n] == nil {
                var b = Builder()
                _ = b.add(name: n, parent: dirIndex, isDir: isDir)
                if isDir && !FileIndex.isPackage(n) && !FileIndex.skipped.contains(n) {
                    b.dirs[(path + "/" + n).hashValue] = 0
                    b.scan(path + "/" + n, index: 0)
                }
                append(b)
            }
        }
    }

    /// Adds a builder's entries. Its first entry hangs off a folder already in the index;
    /// every other parent and every name offset is local to the builder and gets shifted.
    private func append(_ b: Builder) {
        lock.lock()
        defer { lock.unlock() }
        let base = Int32(entries.count)
        let nBase = Int32(names.count)
        let lBase = Int32(lowers.count)
        names.append(contentsOf: b.names)
        lowers.append(contentsOf: b.lowers)
        for (k, e) in b.entries.enumerated() {
            var e = e
            e.name = (e.name.lowerBound + nBase)..<(e.name.upperBound + nBase)
            let shift = e.lowerInNames ? nBase : lBase
            e.lower = (e.lower.lowerBound + shift)..<(e.lower.upperBound + shift)
            if k > 0 { e.parent += base }
            entries.append(e)
        }
        for (p, i) in b.dirs { dirs[p] = i + base }
        count = entries.count
    }

    var sizes: String {
        lock.lock(); defer { lock.unlock() }
        let mb = { (b: Int) in String(format: "%.1f MB", Double(b) / 1_048_576) }
        return "entries \(entries.count) x \(MemoryLayout<Entry>.stride) B, capacity \(mb(entries.capacity * MemoryLayout<Entry>.stride)); "
            + "names \(mb(names.capacity)); lowers \(mb(lowers.capacity)); folders \(dirs.count) (capacity \(dirs.capacity))"
    }

    // MARK: Searching

    private func name(at i: Int) -> String {
        let r = entries[i].name
        return String(decoding: names[Int(r.lowerBound)..<Int(r.upperBound)], as: UTF8.self)
    }

    private func path(at i: Int) -> String {
        var parts: [String] = []
        var j = i
        while j >= 0 {
            parts.append(name(at: j))
            j = Int(entries[j].parent)
        }
        let root = parts.removeLast()
        return ([root] + parts.reversed()).joined(separator: "/")
    }

    /// Items whose name holds every word of `query`, best matches first: the whole name,
    /// then a prefix, then a word start, shorter names before longer.
    func search(_ query: String, limit: Int = 300) -> [Hit] {
        let words = query.lowercased().split(separator: " ").map { Array($0.utf8) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }
        lock.lock()
        defer { lock.unlock() }
        var scored: [(score: Int, index: Int)] = []
        lowers.withUnsafeBufferPointer { lowBuf in names.withUnsafeBufferPointer { nameBuf in
            let lowBase = lowBuf.baseAddress ?? UnsafePointer(bitPattern: 1)!
            let nameBase = nameBuf.baseAddress!
            for i in entries.indices where !entries[i].deleted && entries[i].parent >= 0 {
                let r = entries[i].lower
                let start = (entries[i].lowerInNames ? nameBase : lowBase) + Int(r.lowerBound)
                let len = Int(r.upperBound - r.lowerBound)
                var best = 3
                var all = true
                for (k, w) in words.enumerated() {
                    guard let hit = w.withUnsafeBufferPointer({ memmem(start, len, $0.baseAddress!, w.count) }) else { all = false; break }
                    if k == 0 {
                        let at = UnsafePointer<UInt8>(hit.assumingMemoryBound(to: UInt8.self)) - start
                        if at == 0 { best = len == w.count && words.count == 1 ? 0 : 1 }
                        else if [UInt8(ascii: " "), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: ".")].contains(start[at - 1]) { best = 2 }
                    }
                }
                if all {
                    scored.append((best * 10_000 + min(len, 9_999), i))
                    if scored.count > 20_000 { break }
                }
            }
        } }
        scored.sort { $0.score < $1.score }
        return scored.prefix(limit).map { Hit(path: path(at: $0.index), name: name(at: $0.index), isDir: entries[$0.index].isDir) }
    }
}
