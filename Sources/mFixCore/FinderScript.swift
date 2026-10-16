import AppKit

/// Finder through its scripting interface, for what its keys and menus can't do.
enum FinderScript {
    private static func run(_ source: String) -> NSAppleEventDescriptor? {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { NSLog("mFix: finder script failed: %@", error) }
        return error == nil ? result : nil
    }

    /// The front window's folder and the selected items.
    static func windowAndSelection() -> (URL?, [URL]) {
        guard let r = run("""
            tell application "Finder"
                set top to ""
                if (count of Finder windows) > 0 then set top to POSIX path of (target of front Finder window as alias)
                set picked to {}
                repeat with i in (selection as alias list)
                    set end of picked to POSIX path of i
                end repeat
                return {top} & picked
            end tell
            """), r.numberOfItems >= 1 else { return (nil, []) }
        let paths = (1...r.numberOfItems).compactMap { r.atIndex($0)?.stringValue }
        let top = paths.first.flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        return (top, paths.dropFirst().map { URL(fileURLWithPath: $0) })
    }

    /// Finder moves them, so a name already there gets Finder's own handling.
    static func move(_ items: [URL], to folder: URL) -> Bool {
        func quoted(_ p: String) -> String { "\"" + p.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let list = items.map { "POSIX file " + quoted($0.path) }.joined(separator: ", ")
        return run("""
            tell application "Finder" to move {\(list)} to (POSIX file \(quoted(folder.path)) as alias)
            """) != nil
    }
}
