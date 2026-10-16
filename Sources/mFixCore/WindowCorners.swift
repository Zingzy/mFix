import AppKit

/// A window's corner radii as drawn, which on macOS 26 depend on the window's style and in
/// some apps (Arc) differ between top and bottom. Read off a snapshot: walking the diagonal
/// in from a corner, alpha crosses half r * (1 - 1/sqrt 2) in from each edge of a corner of
/// radius r.
public enum WindowCorners {
    public struct Radii: Equatable {
        public var topLeft, topRight, bottomLeft, bottomRight: CGFloat

        static let fallback = Radii(topLeft: 16, topRight: 16, bottomLeft: 16, bottomRight: 16)
    }

    public static func radii(of id: CGWindowID, frameWidth: CGFloat) -> Radii? {
        guard frameWidth > 0, let image = SkyLight.captureWindow(id), image.width > 64, image.height > 64,
              image.bitsPerPixel == 32, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let info = CGImageAlphaInfo(rawValue: image.bitmapInfo.rawValue & CGBitmapInfo.alphaInfoMask.rawValue)
        let little = image.bitmapInfo.contains(.byteOrder32Little)
        let alphaFirst = info == .premultipliedFirst || info == .first
        let a = alphaFirst ? (little ? 3 : 0) : (little ? 0 : 3)
        let scale = CGFloat(image.width) / frameWidth
        func alpha(_ x: Int, _ y: Int) -> CGFloat { CGFloat(bytes[y * image.bytesPerRow + x * 4 + a]) }
        func corner(_ dx: Int, _ dy: Int) -> CGFloat? {
            let x0 = dx > 0 ? 0 : image.width - 1, y0 = dy > 0 ? 0 : image.height - 1
            var last: CGFloat = 0
            for d in 0..<min(image.width, image.height, 120) {
                let v = alpha(x0 + d * dx, y0 + d * dy)
                if v > 128 {
                    guard d > 0 else { return 0 }
                    let edge = CGFloat(d - 1) + (128 - last) / max(v - last, 1)
                    return ((edge + 0.5) / scale / (1 - 1 / 2.0.squareRoot()) * 2).rounded() / 2
                }
                last = v
            }
            return nil
        }
        guard let tl = corner(1, 1), let tr = corner(-1, 1), let bl = corner(1, -1), let br = corner(-1, -1) else { return nil }
        return Radii(topLeft: tl, topRight: tr, bottomLeft: bl, bottomRight: br)
    }
}
