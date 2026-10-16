import AppKit

/// Colours that follow the system light/dark mode, as Windows 11 does since build 22538.
@MainActor
enum Theme {
    static var dark: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    static var appearance: NSAppearance? { NSAppearance(named: dark ? .darkAqua : .aqua) }
    static var accent: NSColor { .controlAccentColor }
    static var strip: NSColor {
        dark ? NSColor(white: 0.17, alpha: 0.96) : NSColor(srgbRed: 0.937, green: 0.949, blue: 0.957, alpha: 0.96)
    }
    static var stripHover: NSColor {
        dark ? NSColor(white: 0.22, alpha: 0.98) : NSColor(srgbRed: 0.965, green: 0.972, blue: 0.98, alpha: 0.98)
    }
    static var thumbBackground: NSColor { dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.88, alpha: 1) }
    static var cardEdge: NSColor { dark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.10) }
    static var ringInner: NSColor {
        dark ? NSColor(white: 0.08, alpha: 0.9) : NSColor(srgbRed: 0.906, green: 0.941, blue: 0.965, alpha: 1)
    }
    static var text: NSColor { dark ? NSColor(white: 1, alpha: 0.92) : NSColor(white: 0, alpha: 0.9) }
}

/// Flips coordinates so cards lay out top to bottom like the Windows grids they copy.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Background that reports clicks landing outside its cards.
final class BackdropView: FlippedView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One window as a Windows 11 card: a title strip with the app icon and window title over a
/// live thumbnail. Shared by Alt+Tab and Snap Assist.
@MainActor
final class WindowCard: FlippedView {
    let target: AXWindow
    let stripHeight: CGFloat
    var onClick: (() -> Void)?
    var onClose: (() -> Void)?
    var onHover: (() -> Void)?

    private let strip = NSView()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let thumb = CALayer()
    private let placeholder = NSImageView()
    private let closeButton = CloseButton()
    private var tracking: NSTrackingArea?

    /// A snap group shows every member's icon and a "Group | …" title instead.
    private var extraIcons: [NSImageView] = []
    var closable = true

    init(window: AXWindow, stripHeight: CGFloat, fontSize: CGFloat, title custom: String? = nil, icons: [NSImage] = []) {
        self.target = window
        self.stripHeight = stripHeight
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = Theme.cardEdge.cgColor
        layer?.backgroundColor = Theme.thumbBackground.cgColor

        strip.wantsLayer = true
        strip.layer?.backgroundColor = Theme.strip.cgColor
        addSubview(strip)

        let app = window.app
        iconView.image = app?.icon
        iconView.imageScaling = .scaleProportionallyUpOrDown
        strip.addSubview(iconView)

        let title = window.title.isEmpty ? (app?.localizedName ?? "") : window.title
        titleField.stringValue = custom ?? title
        for icon in icons.dropFirst() {
            let v = NSImageView()
            v.image = icon
            v.imageScaling = .scaleProportionallyUpOrDown
            strip.addSubview(v)
            extraIcons.append(v)
        }
        if let first = icons.first { iconView.image = first }
        titleField.font = .systemFont(ofSize: fontSize)
        titleField.textColor = Theme.text
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.truncatesLastVisibleLine = true
        strip.addSubview(titleField)

        thumb.contentsGravity = .resizeAspect
        thumb.masksToBounds = true
        layer?.addSublayer(thumb)

        placeholder.image = app?.icon
        placeholder.imageScaling = .scaleProportionallyUpOrDown
        addSubview(placeholder)

        closeButton.isHidden = true
        closeButton.onPress = { [weak self] in self?.onClose?() }
        strip.addSubview(closeButton)

        if let cached = Thumbnails.shared.cached(window.id) { setThumbnail(cached) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func setThumbnail(_ image: CGImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumb.contents = image
        placeholder.isHidden = true
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        let s = stripHeight
        let pad = (s * 0.3).rounded()
        let iconSize = (s * 0.4).rounded()
        strip.frame = CGRect(x: 0, y: 0, width: bounds.width, height: s)
        iconView.frame = CGRect(x: pad, y: (s - iconSize) / 2, width: iconSize, height: iconSize)
        var lastIcon = iconView.frame
        for v in extraIcons {
            v.frame = lastIcon.offsetBy(dx: iconSize + 4, dy: 0)
            lastIcon = v.frame
        }
        let closeSize = s * 0.7
        closeButton.frame = CGRect(x: bounds.width - closeSize - (s - closeSize) / 2, y: (s - closeSize) / 2,
                                   width: closeSize, height: closeSize)
        let titleX = lastIcon.maxX + pad * 0.66
        let titleRight = closeButton.isHidden ? bounds.width - pad : closeButton.frame.minX - 4
        let textHeight = titleField.intrinsicContentSize.height
        titleField.frame = CGRect(x: titleX, y: (s - textHeight) / 2, width: max(0, titleRight - titleX), height: textHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        thumb.frame = CGRect(x: 0, y: s, width: bounds.width, height: bounds.height - s)
        CATransaction.commit()
        let p = min(48, (bounds.height - s) * 0.4)
        placeholder.frame = CGRect(x: (bounds.width - p) / 2, y: s + (bounds.height - s - p) / 2, width: p, height: p)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) {
        closeButton.isHidden = !target.hasElement || !closable
        strip.layer?.backgroundColor = Theme.stripHover.cgColor
        needsLayout = true
        onHover?()
    }

    override func mouseExited(with event: NSEvent) {
        closeButton.isHidden = true
        strip.layer?.backgroundColor = Theme.strip.cgColor
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) { onClick?() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The X in a card's title strip. Plain glyph with a red fill on hover, like Windows.
@MainActor
final class CloseButton: NSView {
    var onPress: (() -> Void)?
    private var hover = false
    private var tracking: NSTrackingArea?

    override func draw(_ dirtyRect: NSRect) {
        if hover {
            NSColor(srgbRed: 0.77, green: 0.17, blue: 0.11, alpha: 1).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        let c = bounds.insetBy(dx: bounds.width * 0.32, dy: bounds.height * 0.32)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: c.minX, y: c.minY)); path.line(to: CGPoint(x: c.maxX, y: c.maxY))
        path.move(to: CGPoint(x: c.minX, y: c.maxY)); path.line(to: CGPoint(x: c.maxX, y: c.minY))
        path.lineWidth = 1.1
        (hover ? NSColor.white : Theme.text).setStroke()
        path.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onPress?() }
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The two-band accent focus ring Windows 11 draws around the selected card: a 4pt accent
/// band outside a 2pt light band, its outer edge 11pt outside the card.
@MainActor
final class SelectionRing {
    let outer = CALayer()
    let inner = CALayer()

    init() {
        for l in [outer, inner] {
            l.cornerCurve = .continuous
            l.backgroundColor = NSColor.clear.cgColor
        }
        outer.borderWidth = 4
        inner.borderWidth = 2
        outer.cornerRadius = 16
        inner.cornerRadius = 12
    }

    func attach(to layer: CALayer?) {
        layer?.addSublayer(outer)
        layer?.addSublayer(inner)
    }

    func move(around frame: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        outer.borderColor = Theme.accent.cgColor
        inner.borderColor = Theme.ringInner.cgColor
        if let frame {
            outer.isHidden = false
            inner.isHidden = false
            outer.frame = frame.insetBy(dx: -11, dy: -11)
            inner.frame = frame.insetBy(dx: -7, dy: -7)
        } else {
            outer.isHidden = true
            inner.isHidden = true
        }
        CATransaction.commit()
    }
}

/// Rows of equal-height cards whose widths follow each window's aspect ratio, each row
/// centred, the block centred too. Shared by Alt+Tab and Snap Assist.
struct CardFlow {
    var frames: [CGRect] = []
    var size: CGSize = .zero
    var rowOf: [Int] = []
    var strip: CGFloat = 40

    func fits(_ box: CGSize) -> Bool { size.width <= box.width && size.height <= box.height }

    static func aspect(of window: AXWindow) -> CGFloat {
        let f = window.frame
        guard f.height > 0 else { return 1.4 }
        return min(max(f.width / f.height, 0.55), 2.4)
    }

    /// Title strip and gaps shrink with the card so small cards stay mostly thumbnail:
    /// 40pt strip and 26pt gaps at Windows' full size, down to 26pt and 14pt.
    static func strip(for cardHeight: CGFloat) -> CGFloat { min(40, max(26, (cardHeight * 0.153).rounded())) }
    static func gap(for cardHeight: CGFloat) -> CGFloat { min(26, max(14, (cardHeight * 0.1).rounded())) }

    static func layout(aspects: [CGFloat], cardHeight: CGFloat, strip: CGFloat, gap: CGSize, maxWidth: CGFloat) -> CardFlow {
        var rows: [[(Int, CGFloat)]] = [[]]
        var rowWidth: CGFloat = 0
        for (i, a) in aspects.enumerated() {
            let w = max(strip * 4, ((cardHeight - strip) * a).rounded())
            let needed = rows[rows.count - 1].isEmpty ? w : rowWidth + gap.width + w
            if needed > maxWidth && !rows[rows.count - 1].isEmpty {
                rows.append([(i, w)])
                rowWidth = w
            } else {
                rows[rows.count - 1].append((i, w))
                rowWidth = needed
            }
        }
        var flow = CardFlow()
        flow.frames = Array(repeating: .zero, count: aspects.count)
        flow.rowOf = Array(repeating: 0, count: aspects.count)
        let widths = rows.map { r in r.reduce(0) { $0 + $1.1 } + gap.width * CGFloat(max(0, r.count - 1)) }
        let total = min(maxWidth, widths.max() ?? 0)
        for (ri, row) in rows.enumerated() {
            var x = (total - widths[ri]) / 2
            let y = CGFloat(ri) * (cardHeight + gap.height)
            for (i, w) in row {
                flow.frames[i] = CGRect(x: x, y: y, width: w, height: cardHeight)
                flow.rowOf[i] = ri
                x += w + gap.width
            }
        }
        flow.size = CGSize(width: total, height: CGFloat(rows.count) * cardHeight + CGFloat(max(0, rows.count - 1)) * gap.height)
        return flow
    }

    /// The largest card height between `minHeight` and `maxHeight` whose flow fits `box`.
    /// When even `minHeight` overflows, the flow at `minHeight` comes back taller than `box`
    /// and the caller scrolls. Pass `scaled` to shrink the strip and gaps with the cards.
    /// `maxRows`: shrink the cards to stay within this many rows, and only add rows once the
    /// cards are at `minHeight`. Windows' switcher keeps seven windows in two rows.
    static func fit(aspects: [CGFloat], box: CGSize, minHeight: CGFloat, maxHeight: CGFloat, strip: CGFloat, gap: CGSize,
                    scaled: Bool = false, maxRows: Int = .max) -> CardFlow {
        if maxRows < .max {
            let limited = fit(aspects: aspects, box: box, minHeight: minHeight, maxHeight: maxHeight, strip: strip, gap: gap,
                              scaled: scaled, rows: maxRows)
            if let limited { return limited }
        }
        return fit(aspects: aspects, box: box, minHeight: minHeight, maxHeight: maxHeight, strip: strip, gap: gap,
                   scaled: scaled, rows: .max) ?? layout(aspects: aspects, cardHeight: minHeight, strip: strip, gap: gap, maxWidth: box.width)
    }

    private static func fit(aspects: [CGFloat], box: CGSize, minHeight: CGFloat, maxHeight: CGFloat, strip: CGFloat, gap: CGSize,
                            scaled: Bool, rows maxRows: Int) -> CardFlow? {
        func at(_ h: CGFloat) -> CardFlow {
            let s = scaled ? CardFlow.strip(for: h) : strip
            let g = scaled ? CGSize(width: CardFlow.gap(for: h), height: CardFlow.gap(for: h)) : gap
            var f = layout(aspects: aspects, cardHeight: h, strip: s, gap: g, maxWidth: box.width)
            f.strip = s
            return f
        }
        func ok(_ f: CardFlow) -> Bool { f.fits(box) && (f.rowOf.max() ?? 0) < maxRows }
        var lo = minHeight, hi = maxHeight
        if ok(at(maxHeight)) { return at(maxHeight) }
        guard ok(at(minHeight)) || maxRows == .max else { return nil }
        var best = at(minHeight)
        for _ in 0..<14 {
            let mid = (lo + hi) / 2
            let f = at(mid)
            if ok(f) {
                best = f
                lo = mid
            } else {
                hi = mid
            }
        }
        return best
    }

    /// Index of the card to move to with an arrow key: same row neighbours for Left/Right
    /// (wrapping through rows), the horizontally closest card in the next row for Up/Down,
    /// wrapping from the bottom row to the top as Windows does since build 22563.
    func neighbour(of i: Int, _ arrow: Arrow) -> Int {
        let n = frames.count
        guard n > 0 else { return i }
        switch arrow {
        case .left: return (i - 1 + n) % n
        case .right: return (i + 1) % n
        case .up, .down:
            let rows = (rowOf.max() ?? 0) + 1
            guard rows > 1 else { return i }
            let target = (rowOf[i] + (arrow == .down ? 1 : rows - 1)) % rows
            let x = frames[i].midX
            return frames.indices.filter { rowOf[$0] == target }
                .min(by: { abs(frames[$0].midX - x) < abs(frames[$1].midX - x) }) ?? i
        }
    }
}
