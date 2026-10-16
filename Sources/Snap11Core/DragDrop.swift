import AppKit
import QuickLookThumbnailing

/// Help while dragging files, images or text between apps, the way Windows does it:
/// a preview of what's being dragged under the pointer, holding the drag over an app's Dock
/// icon brings that app's window forward (into its Space or full-screen Space too), and the
/// switcher works mid-drag. A content drag is spotted by the drag pasteboard changing after
/// a mouse-down; window moves and plain clicks never touch it.
@MainActor
final class DragDrop {
    static let shared = DragDrop()

    /// Windows springs a taskbar button after about half a second of hovering with a drag.
    private let springDelay: TimeInterval = 0.5

    private var tap: ListenTap?
    private var downCount = 0
    private var buttonDown = false
    private(set) var isDragging = false
    private let preview = OverlayPanel(takesKeyboard: false)
    private var previewSize: CGSize = .zero
    private var dockItems: [(frame: CGRect, url: URL)] = []
    private var dockRead = Date.distantPast
    private var springTimer: Timer?
    private var springURL: URL?
    private var generation = 0

    private init() {
        preview.ignoresMouseEvents = true
        preview.level = .floating
    }

    func start() {
        let tap = ListenTap([.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] type, event in
            let location = event.location
            MainActor.assumeIsolated {
                guard let self else { return }
                switch type {
                case .leftMouseDown:
                    self.buttonDown = true
                    self.downCount = NSPasteboard(name: .drag).changeCount
                case .leftMouseDragged: self.dragged(to: location)
                case .leftMouseUp: self.ended()
                default: break
                }
            }
        }
        tap.start()
        self.tap = tap
    }

    private func dragged(to p: CGPoint) {
        guard buttonDown else { return }
        if !isDragging {
            let pb = NSPasteboard(name: .drag)
            guard pb.changeCount != downCount, let content = DragContent(pb) else { return }
            isDragging = true
            generation += 1
            showPreview(content)
            readDock(force: true)
        }
        movePreview(to: p)
        spring(at: p)
        Switcher.shared.dragMoved(to: p)
    }

    private func ended() {
        buttonDown = false
        guard isDragging else { return }
        isDragging = false
        generation += 1
        preview.orderOut(nil)
        springTimer?.invalidate()
        springTimer = nil
        springURL = nil
        Switcher.shared.dragEnded()
    }

    // MARK: Preview

    private func showPreview(_ content: DragContent) {
        let view = DragPreviewView(content: content)
        previewSize = view.fittingSize
        view.frame = NSRect(origin: .zero, size: previewSize)
        preview.contentView = view
        preview.appearance = Theme.appearance
        let g = generation
        if case let .files(urls) = content {
            for (i, url) in urls.prefix(3).enumerated() {
                let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 96, height: 96), scale: 2,
                                                           representationTypes: .thumbnail)
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                    guard let image = rep?.nsImage else { return }
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard self.generation == g else { return }
                            view.setThumbnail(image, at: i)
                        }
                    }
                }
            }
        }
        preview.orderFrontRegardless()
    }

    /// Just below and right of the pointer's tip.
    private func movePreview(to p: CGPoint) {
        let origin = Geo.flip(CGRect(x: p.x + 4, y: p.y + 6, width: previewSize.width, height: previewSize.height))
        preview.setFrame(origin, display: false)
    }

    // MARK: Dock spring-loading

    private func readDock(force: Bool = false) {
        guard force || Date().timeIntervalSince(dockRead) > 1 else { return }
        dockRead = Date()
        dockItems = []
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.2)
        for list in (app.attr(kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            for item in (list.attr(kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                guard (item.attr(kAXSubroleAttribute) as String?) == "AXApplicationDockItem",
                      let url: URL = item.attr(kAXURLAttribute),
                      let pos = item.point(kAXPositionAttribute), let size = item.size(kAXSizeAttribute) else { continue }
                dockItems.append((CGRect(origin: pos, size: size), url))
            }
        }
    }

    private func spring(at p: CGPoint) {
        if dockItems.isEmpty || !(dockItems.contains { $0.frame.insetBy(dx: 0, dy: -8).contains(p) }) {
            // An auto-hidden Dock only has real frames once it slides in.
            if Geo.screen(at: p).map({ p.y > Geo.flip($0.frame).maxY - 90 }) ?? false { readDock() }
        }
        let url = dockItems.first { $0.frame.contains(p) }?.url
        guard url != springURL else { return }
        springURL = url
        springTimer?.invalidate()
        springTimer = nil
        guard let url else { return }
        springTimer = Timer.scheduledTimer(withTimeInterval: springDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isDragging, self.springURL == url else { return }
                self.bringForward(appAt: url)
            }
        }
    }

    private func bringForward(appAt url: URL) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL })
        else { return }
        // Not running: leave it to the Dock, which opens the dropped item with the app.
        if let window = WindowList.allSpaces().first(where: { $0.pid == app.processIdentifier }) {
            window.focus()
            FocusHistory.shared.touch(window.id)
        } else {
            app.activate(options: [])
        }
    }
}

/// What a drag carries, read from the drag pasteboard.
enum DragContent {
    case files([URL])
    case image(NSImage)
    case text(String)

    init?(_ pb: NSPasteboard) {
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            self = .files(urls)
        } else if let image = NSImage(pasteboard: pb) {
            self = .image(image)
        } else if let s = pb.string(forType: .string) ?? pb.string(forType: .URL), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self = .text(s)
        } else {
            return nil
        }
    }
}

/// A small stack of thumbnails with a count badge, or a text snippet card.
@MainActor
final class DragPreviewView: FlippedView {
    private let content: DragContent
    private var tiles: [NSImageView] = []
    private let side: CGFloat = 72

    init(content: DragContent) {
        self.content = content
        super.init(frame: .zero)
        wantsLayer = true
        switch content {
        case let .files(urls):
            for (i, url) in urls.prefix(3).enumerated().reversed() {
                addTile(NSWorkspace.shared.icon(forFile: url.path), offset: CGFloat(i) * 5)
            }
            tiles.reverse()
            if urls.count > 1 { addBadge(urls.count) }
        case let .image(image):
            addTile(image, offset: 0)
        case let .text(s):
            addSnippet(s)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var fittingSize: NSSize {
        if case .text = content { return subviews.first?.frame.size ?? .zero }
        return NSSize(width: side + 10 + 12, height: side + 10 + 12)
    }

    private func addTile(_ image: NSImage, offset: CGFloat) {
        let v = NSImageView(frame: NSRect(x: 6 + offset, y: 6 + offset, width: side, height: side))
        v.image = image
        v.imageScaling = .scaleProportionallyUpOrDown
        v.wantsLayer = true
        v.layer?.cornerRadius = 6
        v.layer?.cornerCurve = .continuous
        v.layer?.masksToBounds = true
        v.layer?.backgroundColor = Theme.strip.cgColor
        v.layer?.borderWidth = 1
        v.layer?.borderColor = Theme.cardEdge.cgColor
        v.alphaValue = 0.92
        addSubview(v)
        tiles.append(v)
    }

    func setThumbnail(_ image: NSImage, at index: Int) {
        guard tiles.indices.contains(index) else { return }
        tiles[index].image = image
    }

    private func addBadge(_ count: Int) {
        let label = NSTextField(labelWithString: "\(count)")
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        let width = max(20, label.intrinsicContentSize.width + 10)
        let pill = NSView(frame: NSRect(x: fittingSize.width - width, y: 0, width: width, height: 20))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = Theme.accent.cgColor
        pill.layer?.cornerRadius = 10
        label.frame = NSRect(x: 0, y: (20 - label.intrinsicContentSize.height) / 2, width: width, height: label.intrinsicContentSize.height)
        pill.addSubview(label)
        addSubview(pill)
    }

    private func addSnippet(_ s: String) {
        let text = String(s.prefix(160)).replacingOccurrences(of: "\n", with: " ")
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = Theme.text
        label.maximumNumberOfLines = 3
        label.lineBreakMode = .byTruncatingTail
        let width = min(240, max(80, label.intrinsicContentSize.width))
        label.preferredMaxLayoutWidth = width
        let height = label.sizeThatFits(NSSize(width: width, height: 60)).height
        let card = NSView(frame: NSRect(x: 0, y: 0, width: width + 20, height: height + 16))
        card.wantsLayer = true
        card.layer?.cornerRadius = 8
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = Theme.strip.cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = Theme.cardEdge.cgColor
        label.frame = NSRect(x: 10, y: 8, width: width, height: height)
        card.addSubview(label)
        addSubview(card)
    }
}
