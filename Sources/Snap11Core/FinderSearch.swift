import AppKit

/// Cmd+F in Finder: Snap11's search over the front Finder window, fed by the file index.
/// Every word typed must appear in the name. Enter opens, Cmd+Enter shows it in Finder,
/// Esc or a click elsewhere closes.
@MainActor
final class FinderSearch: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static let shared = FinderSearch()

    /// Size and date are read when a row first comes into view, not for every match.
    private final class Row {
        let hit: FileIndex.Hit
        private var read = false
        private var _size: Int?
        private var _modified: Date?

        init(hit: FileIndex.Hit) { self.hit = hit }

        private func load() {
            guard !read else { return }
            read = true
            let a = try? FileManager.default.attributesOfItem(atPath: hit.path)
            _size = hit.isDir ? nil : (a?[.size] as? NSNumber)?.intValue
            _modified = a?[.modificationDate] as? Date
        }

        var size: Int? { load(); return _size }
        var modified: Date? { load(); return _modified }
    }

    private let panel = OverlayPanel(takesKeyboard: true)
    private let field = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private var rows: [Row] = []
    private var generation = 0
    private let queue = DispatchQueue(label: "snap11.finder-search", qos: .userInteractive)
    private let dates: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private override init() {
        super.init()
        let root = NSView()
        let bg = NSVisualEffectView()
        bg.material = .windowBackground
        bg.blendingMode = .withinWindow
        bg.state = .active
        bg.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(bg)

        field.placeholderString = "Search every file by name"
        field.font = .systemFont(ofSize: 15)
        field.delegate = self
        field.focusRingType = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(field)

        for (id, title, width) in [("name", "Name", 300.0), ("where", "Location", 320.0), ("size", "Size", 80.0), ("date", "Modified", 150.0)] {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title
            c.width = width
            table.addTableColumn(c)
        }
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.style = .fullWidth
        table.usesAlternatingRowBackgroundColors = false
        table.doubleAction = #selector(openSelected)
        table.target = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(scroll)

        status.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.textColor = .secondaryLabelColor
        status.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(status)

        NSLayoutConstraint.activate([
            bg.leadingAnchor.constraint(equalTo: root.leadingAnchor), bg.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bg.topAnchor.constraint(equalTo: root.topAnchor), bg.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        root.wantsLayer = true
        root.layer?.cornerRadius = 10
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = root
        panel.onKey = { [weak self] e in self?.key(e) ?? false }
        panel.onResignKey = { [weak self] in
            DispatchQueue.main.async { if self?.panel.isKeyWindow == false { self?.close() } }
        }
    }

    /// Over the front Finder window's content, below its toolbar.
    func show(over finderWindow: CGRect) {
        var area = finderWindow
        area.origin.y += 52
        area.size.height -= 52
        if area.width < 560 || area.height < 300 {
            area = CGRect(x: finderWindow.midX - 380, y: finderWindow.minY + 60, width: 760, height: 460)
        }
        panel.appearance = nil
        panel.show(frame: Geo.flip(area))
        panel.makeFirstResponder(field)
        field.selectText(nil)
        update()
    }

    /// For the render check: show and type a query without a Finder window.
    func preview(query: String) {
        show(over: CGRect(x: 100, y: 100, width: 900, height: 560))
        field.stringValue = query
        update()
    }

    var panelForRender: NSPanel { panel }

    func close() {
        generation += 1
        panel.hide()
    }

    // MARK: Searching

    func controlTextDidChange(_ obj: Notification) { update() }

    private func update() {
        generation += 1
        let g = generation
        let query = field.stringValue
        let index = FileIndex.shared
        guard index.ready else {
            rows = []
            table.reloadData()
            status.stringValue = "Building the index, \(index.count) items so far"
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                MainActor.assumeIsolated { if self?.generation == g && self?.panel.isVisible == true { self?.update() } }
            }
            return
        }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else {
            rows = []
            table.reloadData()
            status.stringValue = "\(index.count) items indexed"
            return
        }
        queue.async {
            let t = Date()
            let hits = index.search(query)
            let ms = Int(Date().timeIntervalSince(t) * 1000)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.generation == g else { return }
                    let found = hits.map(Row.init)
                    self.rows = found
                    self.table.reloadData()
                    if !found.isEmpty { self.table.selectRowIndexes([0], byExtendingSelection: false) }
                    self.status.stringValue = found.count == 300 ? "first 300 matches, \(ms) ms" : "\(found.count) matches, \(ms) ms"
                }
            }
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue, rows.indices.contains(row) else { return nil }
        let r = rows[row]
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = id == "where" ? .byTruncatingMiddle : .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        var leading: CGFloat = 4
        switch id {
        case "name":
            let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: r.hit.path))
            icon.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(icon)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16), icon.heightAnchor.constraint(equalToConstant: 16),
            ])
            leading = 26
            text.stringValue = r.hit.name
            text.font = .systemFont(ofSize: 13)
        case "where":
            text.stringValue = (r.hit.path as NSString).deletingLastPathComponent.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            text.font = .systemFont(ofSize: 12)
            text.textColor = .secondaryLabelColor
        case "size":
            text.stringValue = r.size.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) } ?? "folder"
            text.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            text.textColor = .secondaryLabelColor
            text.alignment = .right
        default:
            text.stringValue = r.modified.map { dates.string(from: $0) } ?? ""
            text.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            text.textColor = .secondaryLabelColor
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: Keys

    /// The search field gets arrows, Enter and Esc before the panel does.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): step(1)
        case #selector(NSResponder.moveUp(_:)): step(-1)
        case #selector(NSResponder.insertNewline(_:)):
            if NSEvent.modifierFlags.contains(.command) { revealSelected() } else { openSelected() }
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func step(_ by: Int) {
        guard !rows.isEmpty else { return }
        let next = min(max(table.selectedRow + by, 0), rows.count - 1)
        table.selectRowIndexes([next], byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    private func key(_ e: NSEvent) -> Bool {
        let row = table.selectedRow
        switch Int64(e.keyCode) {
        case Key.escape:
            close()
        case Key.down, Key.up:
            guard !rows.isEmpty else { return true }
            let next = Int64(e.keyCode) == Key.down ? min(row + 1, rows.count - 1) : max(row - 1, 0)
            table.selectRowIndexes([next], byExtendingSelection: false)
            table.scrollRowToVisible(next)
        case Key.returnKey, Key.enter:
            if e.modifierFlags.contains(.command) { revealSelected() } else { openSelected() }
        default:
            return false
        }
        return true
    }

    @objc private func openSelected() {
        guard rows.indices.contains(table.selectedRow) else { return }
        let path = rows[table.selectedRow].hit.path
        close()
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func revealSelected() {
        guard rows.indices.contains(table.selectedRow) else { return }
        let path = rows[table.selectedRow].hit.path
        close()
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }
}
