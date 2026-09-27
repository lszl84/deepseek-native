import AppKit

protocol SidebarDelegate: AnyObject {
    func sidebarSelectSession(_ id: String)
    func sidebarNewSession(in workspace: String?)
    func sidebarAddWorkspace()
    func sidebarOpenSettings()
    func sidebarRename(_ id: String)
}

final class SidebarViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate, NSMenuDelegate {
    weak var delegate: SidebarDelegate?

    final class WSNode { let ws: Workspace; var sessions: [SessionIndexEntry] = []; init(_ w: Workspace) { ws = w } }
    final class SNode { let entry: SessionIndexEntry; init(_ e: SessionIndexEntry) { entry = e } }

    private let outline = NSOutlineView()
    private let scroll = NSScrollView()
    private let search = NSSearchField()
    private let newButton = PillButton(title: "New Session", symbol: "plus.circle")
    private let settingsButton = NSButton()
    private let addWSButton = NSButton()
    private let header = NSTextField(labelWithString: "Workspaces")
    private let brand = NSTextField(labelWithString: "DeepSeek Harness")
    private let version = NSTextField(labelWithString: "native")
    private let logo = LogoView()
    private var nodes: [WSNode] = []
    private var sessionNodes: [String: SNode] = [:]
    private var selectedId: String?
    private var suppressSelection = false
    private var refreshTimer: Timer?

    override func loadView() {
        let v = NSView()
        view = v

        v.addSubview(logo)
        brand.font = .systemFont(ofSize: 13, weight: .semibold)
        brand.textColor = Theme.text
        v.addSubview(brand)
        version.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        version.textColor = Theme.tertiaryText
        v.addSubview(version)

        newButton.target = self
        newButton.action = #selector(newSession)
        v.addSubview(newButton)

        search.placeholderString = "Search sessions"
        search.delegate = self
        search.controlSize = .regular
        search.sendsSearchStringImmediately = true
        v.addSubview(search)

        header.font = Theme.smallFont
        header.textColor = Theme.tertiaryText
        v.addSubview(header)

        addWSButton.image = Theme.symbol("folder.badge.plus", size: 13)
        addWSButton.isBordered = false
        addWSButton.bezelStyle = .accessoryBarAction
        addWSButton.contentTintColor = Theme.tertiaryText
        addWSButton.toolTip = "Add workspace"
        addWSButton.target = self
        addWSButton.action = #selector(addWorkspace)
        v.addSubview(addWSButton)

        let col = NSTableColumn(identifier: .init("main"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.selectionHighlightStyle = .none
        outline.rowSizeStyle = .custom
        outline.rowHeight = 30
        outline.indentationPerLevel = 10
        outline.floatsGroupRows = false
        outline.dataSource = self
        outline.delegate = self
        outline.backgroundColor = .clear
        outline.autosaveExpandedItems = false
        let menu = NSMenu()
        menu.delegate = self
        outline.menu = menu
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        v.addSubview(scroll)

        settingsButton.title = "Settings"
        settingsButton.image = Theme.symbol("gearshape", size: 13)
        settingsButton.imagePosition = .imageLeading
        settingsButton.isBordered = false
        settingsButton.bezelStyle = .accessoryBarAction
        settingsButton.font = Theme.bodyFont
        settingsButton.contentTintColor = Theme.text
        settingsButton.target = self
        settingsButton.action = #selector(openSettings)
        v.addSubview(settingsButton)

        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: SessionStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionMeta(_:)), name: Session.changed, object: nil)
        // Relative times refresh once a minute.
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.outline.reloadData(); self?.restoreSelection() }
        reload()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let b = view.bounds
        let top = b.height - (view.safeAreaInsets.top > 0 ? view.safeAreaInsets.top : 40)
        logo.frame = NSRect(x: 16, y: top - 30, width: 26, height: 26)
        brand.frame = NSRect(x: 48, y: top - 22, width: b.width - 60, height: 18)
        version.frame = NSRect(x: 49, y: top - 34, width: 80, height: 12)
        newButton.frame = NSRect(x: 12, y: top - 76, width: b.width - 24, height: 34)
        search.frame = NSRect(x: 12, y: top - 112, width: b.width - 24, height: 26)
        header.frame = NSRect(x: 16, y: top - 142, width: 120, height: 18)
        addWSButton.frame = NSRect(x: b.width - 38, y: top - 145, width: 26, height: 24)
        settingsButton.frame = NSRect(x: 10, y: 10, width: 110, height: 30)
        scroll.frame = NSRect(x: 0, y: 48, width: b.width, height: max(0, top - 150 - 48))
    }

    // MARK: Data

    @objc func reload() {
        let q = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let store = SessionStore.shared
        nodes = store.workspaces.map { w in
            let n = WSNode(w)
            n.sessions = store.sessions(in: w).filter { q.isEmpty || $0.title.lowercased().contains(q) }
            return n
        }
        if !q.isEmpty { nodes = nodes.filter { !$0.sessions.isEmpty } }
        sessionNodes = [:]
        suppressSelection = true
        outline.reloadData()
        for n in nodes where n.ws.collapsed != true || !q.isEmpty { outline.expandItem(n) }
        suppressSelection = false
        restoreSelection()
    }

    private func snode(_ e: SessionIndexEntry) -> SNode {
        if let n = sessionNodes[e.id], n.entry == e { return n }
        let n = SNode(e)
        sessionNodes[e.id] = n
        return n
    }

    @objc private func sessionMeta(_ n: Notification) {
        guard let s = n.object as? Session, !s.ephemeral, case .meta = (n.userInfo?["change"] as? Session.Change) ?? .reset else { return }
        if let node = sessionNodes[s.id] {
            let row = outline.row(forItem: node)
            if row >= 0 { outline.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0)) }
        }
    }

    func select(sessionId: String?) {
        selectedId = sessionId
        restoreSelection()
    }

    private func restoreSelection() {
        suppressSelection = true
        defer { suppressSelection = false }
        guard let id = selectedId else { outline.deselectAll(nil); return }
        for n in nodes {
            if let e = n.sessions.first(where: { $0.id == id }) {
                outline.expandItem(n)
                let row = outline.row(forItem: snode(e))
                if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); return }
            }
        }
        outline.deselectAll(nil)
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return nodes.count }
        if let w = item as? WSNode { return w.sessions.count }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return nodes[index] }
        return snode((item as! WSNode).sessions[index])
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { item is WSNode }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        if let w = item as? WSNode {
            let cell = outlineView.makeView(withIdentifier: .init("ws"), owner: self) as? WorkspaceCell ?? WorkspaceCell()
            cell.identifier = .init("ws")
            cell.configure(w.ws.title, path: w.ws.path)
            return cell
        }
        guard let s = item as? SNode else { return nil }
        let cell = outlineView.makeView(withIdentifier: .init("s"), owner: self) as? SessionCell ?? SessionCell()
        cell.identifier = .init("s")
        let live = SessionStore.shared.runningSessions.contains { $0.id == s.entry.id }
        let attention = SessionStore.shared.runningSessions.first { $0.id == s.entry.id }.map { !$0.pendingApprovals.isEmpty || !$0.pendingQuestions.isEmpty } ?? false
        cell.configure(title: s.entry.title, time: Fmt.relative(s.entry.updatedAt), running: live, attention: attention, pinned: s.entry.pinned == true)
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { SidebarRowView() }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat { item is WSNode ? 32 : 30 }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { item is SNode }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelection, let s = outline.item(atRow: outline.selectedRow) as? SNode else { return }
        selectedId = s.entry.id
        delegate?.sidebarSelectSession(s.entry.id)
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        if !suppressSelection, let w = notification.userInfo?["NSObject"] as? WSNode { SessionStore.shared.setCollapsed(w.ws.id, true) }
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        if !suppressSelection, let w = notification.userInfo?["NSObject"] as? WSNode { SessionStore.shared.setCollapsed(w.ws.id, false) }
    }

    func controlTextDidChange(_ obj: Notification) { reload() }

    // MARK: Actions

    @objc private func newSession() {
        var ws: String?
        if let id = selectedId, let e = SessionStore.shared.entry(id: id) { ws = e.cwd }
        delegate?.sidebarNewSession(in: ws)
    }
    @objc private func addWorkspace() { delegate?.sidebarAddWorkspace() }
    @objc private func openSettings() { delegate?.sidebarOpenSettings() }

    // MARK: Context menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = outline.clickedRow
        guard row >= 0 else { return }
        let item = outline.item(atRow: row)
        func add(_ title: String, _ sel: Selector, _ obj: Any) {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            it.target = self
            it.representedObject = obj
            menu.addItem(it)
        }
        if let s = item as? SNode {
            add("Rename…", #selector(renameItem(_:)), s.entry.id)
            add(s.entry.pinned == true ? "Unpin" : "Pin", #selector(pinItem(_:)), s.entry.id)
            add("Archive", #selector(archiveItem(_:)), s.entry.id)
            menu.addItem(.separator())
            add("Reveal Session Log in Finder", #selector(revealLog(_:)), s.entry.id)
            menu.addItem(.separator())
            add("Delete…", #selector(deleteItem(_:)), s.entry.id)
        } else if let w = item as? WSNode {
            add("New Session", #selector(newInWorkspace(_:)), w.ws.path)
            add("Reveal in Finder", #selector(revealWorkspace(_:)), w.ws.path)
            add("Open in Terminal", #selector(openTerminal(_:)), w.ws.path)
            let archived = SessionStore.shared.sessions(in: w.ws, includeArchived: true).filter { $0.archived == true }
            if !archived.isEmpty {
                let sub = NSMenu()
                for a in archived {
                    let it = NSMenuItem(title: a.title, action: #selector(unarchiveItem(_:)), keyEquivalent: "")
                    it.target = self
                    it.representedObject = a.id
                    sub.addItem(it)
                }
                let parent = NSMenuItem(title: "Restore Archived", action: nil, keyEquivalent: "")
                parent.submenu = sub
                menu.addItem(parent)
            }
            menu.addItem(.separator())
            add("Remove Workspace", #selector(removeWorkspace(_:)), w.ws.id)
        }
    }

    @objc private func renameItem(_ s: NSMenuItem) { if let id = s.representedObject as? String { delegate?.sidebarRename(id) } }
    @objc private func pinItem(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        SessionStore.shared.setPinned(id, SessionStore.shared.entry(id: id)?.pinned != true)
    }
    @objc private func archiveItem(_ s: NSMenuItem) { if let id = s.representedObject as? String { SessionStore.shared.setArchived(id, true) } }
    @objc private func unarchiveItem(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        SessionStore.shared.setArchived(id, false)
        delegate?.sidebarSelectSession(id)
        select(sessionId: id)
    }
    @objc private func revealLog(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String else { return }
        NSWorkspace.shared.activateFileViewerSelecting([Paths.sessions.appendingPathComponent(id + ".jsonl")])
    }
    @objc private func deleteItem(_ s: NSMenuItem) {
        guard let id = s.representedObject as? String, let window = view.window else { return }
        let a = NSAlert()
        a.messageText = "Delete “\(SessionStore.shared.entry(id: id)?.title ?? "session")”?"
        a.informativeText = "The session transcript will be permanently removed."
        a.addButton(withTitle: "Delete").hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { r in
            if r == .alertFirstButtonReturn { SessionStore.shared.delete(id) }
        }
    }
    @objc private func newInWorkspace(_ s: NSMenuItem) { delegate?.sidebarNewSession(in: s.representedObject as? String) }
    @objc private func revealWorkspace(_ s: NSMenuItem) {
        if let p = s.representedObject as? String { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p) }
    }
    @objc private func openTerminal(_ s: NSMenuItem) {
        guard let p = s.representedObject as? String else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        if let term = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
            NSWorkspace.shared.open([URL(fileURLWithPath: p)], withApplicationAt: term, configuration: cfg)
        }
    }
    @objc private func removeWorkspace(_ s: NSMenuItem) { if let id = s.representedObject as? String { SessionStore.shared.removeWorkspace(id) } }
}

final class WorkspaceCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    init() {
        super.init(frame: .zero)
        icon.image = Theme.symbol("folder", size: 13)
        icon.contentTintColor = Theme.accent
        addSubview(icon)
        label.font = Theme.bodyFont
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        textField = label
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ title: String, path: String) { label.stringValue = title; toolTip = path }
    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 2, y: (bounds.height - 16) / 2, width: 18, height: 16)
        label.frame = NSRect(x: 26, y: (bounds.height - 18) / 2, width: bounds.width - 30, height: 18)
    }
}

final class SessionCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let dot = NSView()
    private let pin = NSImageView()
    init() {
        super.init(frame: .zero)
        label.font = Theme.bodyFont
        label.textColor = Theme.text
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        textField = label
        time.font = .systemFont(ofSize: 11)
        time.textColor = Theme.tertiaryText
        time.alignment = .right
        addSubview(time)
        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = Theme.warning.cgColor
        addSubview(dot)
        pin.image = Theme.symbol("pin.fill", size: 9)
        pin.contentTintColor = Theme.tertiaryText
        addSubview(pin)
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(title: String, time t: String, running: Bool, attention: Bool, pinned: Bool) {
        label.stringValue = title
        time.stringValue = t
        time.isHidden = running
        if running { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        dot.isHidden = !attention
        pin.isHidden = !pinned
        toolTip = title
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let h = bounds.height
        let right: CGFloat = 44
        pin.frame = NSRect(x: 2, y: (h - 12) / 2, width: 10, height: 12)
        label.frame = NSRect(x: pin.isHidden ? 4 : 14, y: (h - 18) / 2, width: bounds.width - right - (pin.isHidden ? 6 : 16), height: 18)
        time.frame = NSRect(x: bounds.width - right, y: (h - 14) / 2, width: right - 6, height: 14)
        spinner.frame = NSRect(x: bounds.width - 22, y: (h - 12) / 2, width: 12, height: 12)
        dot.frame = NSRect(x: bounds.width - 38, y: (h - 7) / 2, width: 7, height: 7)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        dot.layer?.backgroundColor = Theme.warning.cgColor
    }
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            let emphasized = backgroundStyle == .emphasized
            label.textColor = emphasized ? .alternateSelectedControlTextColor : Theme.text
            time.textColor = emphasized ? NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.75) : Theme.tertiaryText
            pin.contentTintColor = emphasized ? .alternateSelectedControlTextColor : Theme.tertiaryText
        }
    }
}

/// Bordered rounded button matching the web sidebar's "New Session".
final class PillButton: NSControl {
    let title: String
    let symbol: String
    private var hovering = false
    private var pressed = false
    init(title: String, symbol: String) {
        self.title = title
        self.symbol = symbol
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { pressed = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)), let action { NSApp.sendAction(action, to: target, from: self) }
    }
    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let r = self.bounds.insetBy(dx: 0.5, dy: 0.5)
            fillRounded(ctx, r, 12, self.pressed ? Theme.pressed : (self.hovering ? Theme.hover : Theme.cardBackground.withAlphaComponent(0.7)))
            strokeRounded(ctx, r, 12, Theme.cardBorder)
            let font = Theme.bodyFont
            let tw = textWidth(self.title, font)
            let total = tw + 22
            let x = (self.bounds.width - total) / 2
            drawIcon(self.symbol, in: CGRect(x: x, y: 0, width: 16, height: self.bounds.height), size: 13, color: Theme.text, ctx: ctx)
            drawLabel(self.title, in: CGRect(x: x + 22, y: 0, width: tw + 2, height: self.bounds.height), font: font, color: Theme.text)
        }
    }
}

/// Soft gray rounded selection like the web sidebar, independent of the system accent color.
final class SidebarRowView: NSTableRowView {
    override var isSelected: Bool { didSet { needsDisplay = true } }
    override func drawBackground(in dirtyRect: NSRect) {
        guard isSelected else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let r = self.bounds.insetBy(dx: 8, dy: 1)
            Theme.pressed.setFill()
            NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8).fill()
        }
    }
}
