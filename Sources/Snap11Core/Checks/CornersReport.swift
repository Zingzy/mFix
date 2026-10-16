import AppKit

extension WindowCorners {
    /// `Snap11 --corners`: every window's measured radii, to check the measuring.
    @MainActor
    public static func report() {
        for w in WindowList.allSpaces() {
            let r = radii(of: w.id, frameWidth: w.frame.width)
            print(w.app?.localizedName ?? "?", "| radii", r.map { "tl \($0.topLeft) tr \($0.topRight) bl \($0.bottomLeft) br \($0.bottomRight)" } ?? "unknown")
        }
        exit(0)
    }
}
