import AppKit

@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ token: CFData) -> Unmanaged<AXUIElement>?

/// Accessibility only lists an app's windows on the current Space. Every window still has
/// an element, addressed by a small internal id, so AltTab's trick builds candidate elements
/// from a 20-byte token (pid, zero, "coco", element id) and keeps the ones that are the
/// windows it wants. Searches run in the background, under a time budget, and the results
/// are kept until the window goes away.
final class RemoteWindows: @unchecked Sendable {
    static let shared = RemoteWindows()

    private let lock = NSLock()
    private var found: [CGWindowID: AXUIElement] = [:]
    private var searched: [pid_t: Date] = [:]
    private let queue = DispatchQueue(label: "snap11.remote-windows", qos: .userInitiated)

    func element(for id: CGWindowID) -> AXUIElement? {
        lock.lock(); defer { lock.unlock() }
        return found[id]
    }

    /// Looks for `ids` of `pid` in the background, at most once every 10 s per app.
    func prefetch(pid: pid_t, ids: [CGWindowID]) {
        lock.lock()
        let missing = ids.filter { found[$0] == nil }
        let recent = searched[pid].map { Date().timeIntervalSince($0) < 10 } ?? false
        if !missing.isEmpty && !recent { searched[pid] = Date() }
        lock.unlock()
        guard !missing.isEmpty, !recent else { return }
        queue.async { self.search(pid: pid, ids: Set(missing), budget: 0.25) }
    }

    /// Right now, for a window about to be focused.
    func find(pid: pid_t, id: CGWindowID) -> AXUIElement? {
        if let e = element(for: id) { return e }
        search(pid: pid, ids: [id], budget: 0.25)
        return element(for: id)
    }

    private func search(pid: pid_t, ids: Set<CGWindowID>, budget: TimeInterval) {
        let start = Date()
        var remaining = ids
        var token = [UInt8](repeating: 0, count: 20)
        var p = pid
        withUnsafeBytes(of: &p) { for i in 0..<4 { token[i] = $0[i] } }
        var magic: Int32 = 0x636f_636f
        withUnsafeBytes(of: &magic) { for i in 0..<4 { token[8 + i] = $0[i] } }
        var elementID: UInt64 = 0
        while !remaining.isEmpty, elementID < 1000, Date().timeIntervalSince(start) < budget {
            var e = elementID
            withUnsafeBytes(of: &e) { for i in 0..<8 { token[12 + i] = $0[i] } }
            elementID += 1
            guard let element = _AXUIElementCreateWithRemoteToken(Data(token) as CFData)?.takeRetainedValue() else { continue }
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(element, &wid) == .success, remaining.contains(wid),
                  // Every element inside a window reports the window's id; only the window counts.
                  (element.attr(kAXRoleAttribute) as String?) == kAXWindowRole else { continue }
            remaining.remove(wid)
            lock.lock()
            found[wid] = element
            lock.unlock()
        }
    }

    func forget(_ id: CGWindowID) {
        lock.lock(); defer { lock.unlock() }
        found[id] = nil
    }
}
