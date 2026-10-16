import AppKit

/// A window's corner radius as macOS draws it, which on macOS 26 depends on the window's
/// style. Read off a snapshot: from the top-left corner, the first opaque pixel along the
/// diagonal sits r * (1 - 1/sqrt 2) in from each edge of a corner of radius r.
public enum WindowCorners {
    public static func radius(of id: CGWindowID, frameWidth: CGFloat) -> CGFloat? {
        guard frameWidth > 0, let image = SkyLight.captureWindow(id), image.width > 32, image.height > 32,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let bpp = image.bitsPerPixel / 8
        guard bpp == 4 else { return nil }
        let alphaFirst = [.premultipliedFirst, .first].contains(CGImageAlphaInfo(rawValue: image.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue))
        let alphaIndex = alphaFirst ? (image.bitmapInfo.contains(.byteOrder32Little) ? 3 : 0) : (image.bitmapInfo.contains(.byteOrder32Little) ? 0 : 3)
        let scale = CGFloat(image.width) / frameWidth
        func alpha(_ d: Int) -> CGFloat { CGFloat(bytes[d * image.bytesPerRow + d * bpp + alphaIndex]) }
        for d in 0..<min(image.width, image.height, 120) where alpha(d) > 128 {
            guard d > 0 else { return 0 }
            // Where alpha crosses half between the last clear pixel and the first solid one.
            let edge = CGFloat(d - 1) + (128 - alpha(d - 1)) / max(alpha(d) - alpha(d - 1), 1)
            return ((edge + 0.5) / scale / (1 - 1 / 2.0.squareRoot()) * 2).rounded() / 2
        }
        return nil
    }

    /// `Snap11 --corners`: every window's measured radius, to check the measuring.
    @MainActor
    public static func report() {
        for w in WindowList.allSpaces() {
            let r = radius(of: w.id, frameWidth: w.frame.width)
            print(w.app?.localizedName ?? "?", "|", w.title.prefix(30), "| radius", r.map { "\(Int($0)) pt" } ?? "unknown")
        }
        exit(0)
    }
}
