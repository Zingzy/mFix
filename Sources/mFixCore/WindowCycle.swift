import AppKit

/// Steps through one app's windows on repeated clicks or presses. The order is fixed when the
/// stepping starts: re-reading most-recent-first after each focus only bounces between the
/// two newest windows.
@MainActor
enum WindowCycle {
    private static var order: [CGWindowID] = []
    private static var index = 0
    private static var pid: pid_t = 0
    private static var last = Date.distantPast

    static func next(of windows: [AXWindow], pid app: pid_t) -> AXWindow? {
        guard windows.count > 1 else { return windows.first }
        let ids = windows.map(\.id)
        let fresh = Date().timeIntervalSince(last) > 3 || pid != app || Set(order) != Set(ids)
        if fresh {
            order = ids
            index = 0
            pid = app
        }
        last = Date()
        index = (index + 1) % order.count
        return windows.first { $0.id == order[index] }
    }
}
