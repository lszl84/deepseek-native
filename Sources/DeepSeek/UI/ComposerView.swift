import AppKit

protocol ComposerDelegate: AnyObject {
    func composerSend(_ text: String, images: [ContentBlock.ImageData])
    func composerStop()
    func composerHeightChanged()
    func composerPermissionChanged(_ mode: PermissionMode)
    func composerModelChanged(model: String, effort: ReasoningEffort)
    func composerSlashCommand(_ command: String)
    var composerWorkspacePath: String? { get }
}

/// Text view that sends on Return and routes navigation keys to the completion popup.
final class ComposerTextView: NSTextView {
    var onReturn: (() -> Void)?
    var completion: CompletionPopup?
    var onPasteImage: ((NSImage) -> Bool)?
    var onFilesDropped: (([URL]) -> Void)?

    override func keyDown(with event: NSEvent) {
        if let c = completion, c.isVisible {
            switch event.keyCode {
            case 125: c.move(1); return          // down
            case 126: c.move(-1); return         // up
            case 36, 76, 48: c.accept(); return  // return, enter, tab
            case 53: c.hide(); return            // escape
            default: break
            }
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            let shift = event.modifierFlags.contains(.shift)
            let opt = event.modifierFlags.contains(.option)
            let cmd = event.modifierFlags.contains(.command)
            if cmd || (!shift && !opt && Settings.shared.sendOnEnter) || (!Settings.shared.sendOnEnter && cmd) {
                if hasMarkedText() { super.keyDown(with: event); return }
                onReturn?()
                return
            }
            insertNewlineIgnoringFieldEditor(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onFilesDropped?(urls)
            return
        }
        if pb.types?.contains(.string) != true, let img = NSImage(pasteboard: pb), onPasteImage?(img) == true { return }
        pasteAsPlainText(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            onFilesDropped?(urls)
            return true
        }
        return super.performDragOperation(sender)
    }
}

final class ComposerView: NSView, NSTextViewDelegate {
    weak var delegate: ComposerDelegate?
    private let glass = NSGlassEffectView()
    private let content = NSView()
    private let scroll = NSScrollView()
    let textView = ComposerTextView()
    private let placeholder = PassthroughLabel(labelWithString: "")
    private let attachButton = NSButton()
    private let permissionButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let modelButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let sendButton = CircleButton()
    private let chips = NSStackView()
    private(set) var images: [ContentBlock.ImageData] = []
    private let completion = CompletionPopup()

    var running = false { didSet { updateSend() } }
    var placeholderText = "Message or run a task, / commands, @ files" { didSet { placeholder.stringValue = placeholderText } }
    var permission: PermissionMode = .workspaceWrite { didSet { rebuildPermissionMenu() } }
    var model: String = "deepseek-flash" { didSet { rebuildModelMenu() } }
    var effort: ReasoningEffort = .high { didSet { rebuildModelMenu() } }

    private let minTextH: CGFloat = 22
    private let maxTextH: CGFloat = 220
    private let barH: CGFloat = 40

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.cornerRadius = 22
        glass.style = .regular
        addSubview(glass)
        glass.contentView = content

        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = Theme.bodyFont
        textView.textColor = Theme.text
        textView.insertionPointColor = Theme.accent
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainerInset = NSSize(width: 0, height: 2)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 4
        textView.defaultParagraphStyle = p
        textView.typingAttributes = [.font: Theme.bodyFont, .foregroundColor: Theme.text, .paragraphStyle: p]
        textView.delegate = self
        textView.registerForDraggedTypes([.fileURL])
        textView.onReturn = { [weak self] in self?.send() }
        textView.completion = completion
        textView.onFilesDropped = { [weak self] urls in self?.addFiles(urls) }
        textView.onPasteImage = { [weak self] img in self?.addPastedImage(img) ?? false }
        scroll.documentView = textView
        content.addSubview(scroll)

        placeholder.stringValue = placeholderText
        placeholder.textColor = Theme.quaternaryText
        placeholder.font = Theme.bodyFont
        placeholder.lineBreakMode = .byTruncatingTail
        content.addSubview(placeholder)

        chips.orientation = .horizontal
        chips.spacing = 6
        content.addSubview(chips)

        attachButton.isBordered = false
        attachButton.bezelStyle = .accessoryBarAction
        attachButton.contentTintColor = Theme.secondaryText
        attachButton.image = Theme.symbol("plus", size: 14, weight: .medium)
        attachButton.imagePosition = .imageOnly
        attachButton.target = self
        attachButton.action = #selector(attach)
        attachButton.toolTip = "Attach files or images"
        content.addSubview(attachButton)

        for b in [permissionButton, modelButton] {
            b.isBordered = false
            b.bezelStyle = .accessoryBarAction
            (b.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
            b.font = Theme.smallFont
            b.contentTintColor = Theme.secondaryText
            content.addSubview(b)
        }

        sendButton.target = self
        sendButton.action = #selector(sendOrStop)
        content.addSubview(sendButton)

        rebuildPermissionMenu()
        rebuildModelMenu()
        updateSend()
        completion.onAccept = { [weak self] item in self?.acceptCompletion(item) }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Clicks on empty parts of the message box (padding, placeholder) focus the text view.
    override func mouseDown(with event: NSEvent) { focus() }

    // MARK: Layout

    var preferredHeight: CGFloat {
        let textH = min(maxTextH, max(minTextH, textContentHeight()))
        return 14 + (images.isEmpty ? 0 : 34) + textH + 6 + barH
    }

    private func textContentHeight() -> CGFloat {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return minTextH }
        if abs(tc.size.width - max(10, scroll.frame.width)) > 1 { tc.size = NSSize(width: max(10, scroll.frame.width), height: .greatestFiniteMagnitude) }
        lm.ensureLayout(for: tc)
        return ceil(lm.usedRect(for: tc).height) + 4
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        content.frame = glass.bounds
        let w = bounds.width
        var y: CGFloat = 12
        // content is not flipped: lay out from the bottom.
        let barY: CGFloat = 6
        attachButton.frame = NSRect(x: 10, y: barY + 5, width: 28, height: 28)
        let pw = permissionButton.intrinsicContentSize.width + 6
        permissionButton.frame = NSRect(x: 46, y: barY + 6, width: pw, height: 26)
        sendButton.frame = NSRect(x: w - 44, y: barY + 2, width: 34, height: 34)
        let mw = modelButton.intrinsicContentSize.width + 6
        modelButton.frame = NSRect(x: w - 50 - mw, y: barY + 6, width: mw, height: 26)
        y = barY + barH
        let textH = min(maxTextH, max(minTextH, textContentHeight()))
        scroll.frame = NSRect(x: 16, y: y, width: w - 32, height: textH)
        placeholder.frame = NSRect(x: 16, y: y + textH - 21, width: w - 32, height: 20)
        if !images.isEmpty {
            chips.frame = NSRect(x: 14, y: y + textH + 4, width: w - 28, height: 28)
        }
        chips.isHidden = images.isEmpty
    }

    private func updateHeight() {
        needsLayout = true
        delegate?.composerHeightChanged()
    }

    // MARK: Menus

    private func rebuildPermissionMenu() {
        let m = NSMenu()
        m.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        for mode in PermissionMode.allCases {
            let it = NSMenuItem(title: mode.label, action: #selector(pickPermission(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = mode.rawValue
            it.image = Theme.symbol(mode.symbol, size: 13)
            it.state = mode == permission ? .on : .off
            it.toolTip = mode.detail
            let sub = NSMenuItem(title: mode.detail, action: nil, keyEquivalent: "")
            sub.isEnabled = false
            sub.attributedTitle = NSAttributedString(string: mode.detail, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            sub.indentationLevel = 2
            m.addItem(it)
            m.addItem(sub)
        }
        permissionButton.menu = m
        let first = m.items[0]
        first.title = permission.label
        first.image = Theme.symbol(permission.symbol, size: 12)
        permissionButton.contentTintColor = permission == .fullAccess ? Theme.warning : Theme.secondaryText
        needsLayout = true
    }

    private func rebuildModelMenu() {
        let m = NSMenu()
        let head = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        m.addItem(head)
        let title = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        title.isEnabled = false
        m.addItem(title)
        for info in ModelInfo.all {
            let it = NSMenuItem(title: info.name, action: #selector(pickModel(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = info.id
            it.state = info.id == model ? .on : .off
            it.toolTip = info.detail
            m.addItem(it)
        }
        m.addItem(.separator())
        let et = NSMenuItem(title: "Reasoning effort", action: nil, keyEquivalent: "")
        et.isEnabled = false
        m.addItem(et)
        for e in ReasoningEffort.allCases {
            let it = NSMenuItem(title: e.label, action: #selector(pickEffort(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = e.rawValue
            it.state = e == effort ? .on : .off
            m.addItem(it)
        }
        modelButton.menu = m
        let a = NSMutableAttributedString(string: ModelInfo.name(for: model), attributes: [.font: Theme.smallFont, .foregroundColor: Theme.secondaryText])
        a.append(NSAttributedString(string: " " + effort.label, attributes: [.font: Theme.smallFont, .foregroundColor: Theme.tertiaryText]))
        head.attributedTitle = a
        head.title = ModelInfo.name(for: model) + " " + effort.label
        needsLayout = true
    }

    @objc private func pickPermission(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = PermissionMode(rawValue: raw) else { return }
        permission = mode
        delegate?.composerPermissionChanged(mode)
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model = id
        delegate?.composerModelChanged(model: model, effort: effort)
    }

    @objc private func pickEffort(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let e = ReasoningEffort(rawValue: raw) else { return }
        effort = e
        delegate?.composerModelChanged(model: model, effort: effort)
    }

    // MARK: Send

    private func updateSend() {
        let empty = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
        if running && empty {
            sendButton.symbol = "stop.fill"
            sendButton.toolTip = "Stop (⌘.)"
            sendButton.isEnabled = true
        } else {
            sendButton.symbol = "arrow.up"
            sendButton.toolTip = running ? "Send to the running agent" : "Send (Return)"
            sendButton.isEnabled = !empty
        }
        placeholder.isHidden = !textView.string.isEmpty
    }

    @objc private func sendOrStop() {
        let empty = textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty
        if running && empty { delegate?.composerStop() } else { send() }
    }

    private func send() {
        completion.hide()
        let text = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !images.isEmpty else { return }
        if text.hasPrefix("/"), !text.contains(" "), images.isEmpty, SlashCommands.all.contains(where: { $0.0 == text }) {
            delegate?.composerSlashCommand(text)
            textView.string = ""
            textDidChange(Notification(name: NSText.didChangeNotification))
            return
        }
        delegate?.composerSend(text, images: images)
        textView.string = ""
        images = []
        rebuildChips()
        textDidChange(Notification(name: NSText.didChangeNotification))
    }

    func setText(_ s: String) {
        textView.string = s
        textDidChange(Notification(name: NSText.didChangeNotification))
    }

    func focus() { window?.makeFirstResponder(textView) }

    func textDidChange(_ notification: Notification) {
        updateSend()
        updateHeight()
        updateCompletion()
    }

    // MARK: Attachments

    @objc private func attach() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if let cwd = delegate?.composerWorkspacePath { panel.directoryURL = URL(fileURLWithPath: cwd) }
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] r in
            if r == .OK { self?.addFiles(panel.urls) }
        }
    }

    private static let imageExts: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]

    func addFiles(_ urls: [URL]) {
        var mentions: [String] = []
        for u in urls {
            if Self.imageExts.contains(u.pathExtension.lowercased()), let img = ImageEncoding.load(path: u.path) {
                images.append(img.data)
            } else {
                var p = u.path
                if let cwd = delegate?.composerWorkspacePath, p.hasPrefix(cwd + "/") { p = String(p.dropFirst(cwd.count + 1)) }
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
                if isDir.boolValue { p += "/" }
                mentions.append(p.contains(" ") ? "@\"\(p)\"" : "@" + p)
            }
        }
        if !mentions.isEmpty {
            let prefix = textView.string.isEmpty || textView.string.hasSuffix(" ") ? "" : " "
            textView.insertText(prefix + mentions.joined(separator: " ") + " ", replacementRange: textView.selectedRange())
        }
        rebuildChips()
        updateSend()
        updateHeight()
        focus()
    }

    private func addPastedImage(_ img: NSImage) -> Bool {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return false }
        let url = Paths.spill.appendingPathComponent("pasted-\(UUID().uuidString.prefix(8)).png")
        guard (try? png.write(to: url)) != nil, let enc = ImageEncoding.load(path: url.path) else { return false }
        images.append(enc.data)
        rebuildChips()
        updateSend()
        updateHeight()
        return true
    }

    private func rebuildChips() {
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (i, img) in images.enumerated() {
            let b = NSButton(title: ((img.path ?? "image") as NSString).lastPathComponent, image: Theme.symbol("xmark.circle.fill", size: 11)!, target: self, action: #selector(removeImage(_:)))
            b.tag = i
            b.bezelStyle = .accessoryBarAction
            b.imagePosition = .imageTrailing
            b.font = Theme.captionFont
            b.controlSize = .small
            chips.addArrangedSubview(b)
        }
        needsLayout = true
    }

    @objc private func removeImage(_ sender: NSButton) {
        guard sender.tag < images.count else { return }
        images.remove(at: sender.tag)
        rebuildChips()
        updateSend()
        updateHeight()
    }

    // MARK: Completion (@ files, / commands)

    private var completionRange: NSRange?

    private func updateCompletion() {
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        guard sel.length == 0, sel.location <= ns.length else { completion.hide(); return }
        // Find the token before the caret.
        var start = sel.location
        while start > 0 {
            let c = ns.character(at: start - 1)
            if c == 32 || c == 10 || c == 9 { break }
            start -= 1
        }
        let token = ns.substring(with: NSRange(location: start, length: sel.location - start))
        if token.hasPrefix("@") {
            completionRange = NSRange(location: start, length: sel.location - start)
            let query = String(token.dropFirst())
            guard let cwd = delegate?.composerWorkspacePath else { completion.hide(); return }
            FileIndex.shared.files(in: cwd) { [weak self] files in
                guard let self else { return }
                let items = FileIndex.match(query, in: files, limit: 12).map { CompletionPopup.Item(title: $0, detail: nil, value: $0) }
                self.showCompletion(items)
            }
        } else if token.hasPrefix("/") && start == 0 {
            completionRange = NSRange(location: start, length: sel.location - start)
            let items = SlashCommands.all.filter { $0.0.hasPrefix(token) }.map { CompletionPopup.Item(title: $0.0, detail: $0.1, value: $0.0) }
            showCompletion(items)
        } else {
            completion.hide()
        }
    }

    private func showCompletion(_ items: [CompletionPopup.Item]) {
        guard !items.isEmpty, let window, let range = completionRange else { completion.hide(); return }
        var rect = textView.firstRect(forCharacterRange: NSRange(location: range.location, length: 0), actualRange: nil)
        if rect == .zero { rect = window.convertToScreen(convert(bounds, to: nil)) }
        completion.show(items, above: rect, parent: window)
    }

    private func acceptCompletion(_ item: CompletionPopup.Item) {
        guard let range = completionRange else { return }
        var value = item.value
        if value.hasPrefix("/") {
            textView.insertText(value, replacementRange: range)
            completion.hide()
            send()
            return
        }
        value = value.contains(" ") ? "@\"\(value)\" " : "@" + value + " "
        textView.insertText(value, replacementRange: range)
        completion.hide()
    }
}

enum SlashCommands {
    static let all: [(String, String)] = [
        ("/new", "Start a new session"),
        ("/stop", "Stop the running turn"),
        ("/retry", "Retry the last turn"),
        ("/rename", "Rename this session"),
        ("/copy", "Copy the last response"),
        ("/export", "Export the transcript as Markdown"),
        ("/settings", "Open settings"),
        ("/workspace", "Choose another workspace"),
    ]
}

/// Cached file list of a workspace for @-mentions.
final class FileIndex {
    static let shared = FileIndex()
    private var cache: [String: (Date, [String])] = [:]
    private var loading: Set<String> = []
    private var waiters: [String: [([String]) -> Void]] = [:]

    func files(in cwd: String, _ done: @escaping ([String]) -> Void) {
        if let (t, f) = cache[cwd], Date().timeIntervalSince(t) < 30 { done(f); return }
        if let (_, f) = cache[cwd] { done(f) } // serve stale, refresh below
        waiters[cwd, default: []].append(done)
        guard !loading.contains(cwd) else { return }
        loading.insert(cwd)
        Task.detached {
            var files: [String]
            if Ripgrep.path != nil {
                let (out, _) = await Ripgrep.run(["--files", "--hidden", "--no-messages", "-g", "!.git/", "-g", "!node_modules/", "-g", "!.build/", "-g", "!dist/", "-g", "!build/", "-g", "!.venv/", "-g", "!__pycache__/", "-g", "!target/", "-g", "!DerivedData/"], cwd: cwd)
                files = out.split(separator: "\n").prefix(50_000).map(String.init)
            } else {
                files = []
                FallbackSearch.walk(cwd) { f in files.append(f); return files.count < 50_000 }
            }
            // Include directories (with trailing slash) derived from files.
            var dirs = Set<String>()
            for f in files {
                var p = (f as NSString).deletingLastPathComponent
                while !p.isEmpty && p != "." && !dirs.contains(p + "/") { dirs.insert(p + "/"); p = (p as NSString).deletingLastPathComponent }
            }
            let all = dirs.sorted() + files.sorted()
            await MainActor.run {
                self.cache[cwd] = (Date(), all)
                self.loading.remove(cwd)
                let w = self.waiters[cwd] ?? []
                self.waiters[cwd] = nil
                w.forEach { $0(all) }
            }
        }
    }

    /// Fuzzy subsequence match favoring basename and contiguous hits.
    static func match(_ q: String, in files: [String], limit: Int) -> [String] {
        if q.isEmpty { return Array(files.filter { !$0.contains("/") || ($0.hasSuffix("/") && $0.dropLast().contains("/") == false) }.prefix(limit)) }
        let ql = Array(q.lowercased())
        var scored: [(Int, String)] = []
        for f in files {
            let fl = Array(f.lowercased())
            var qi = 0, score = 0, last = -2
            let baseStart = (f.dropLast(f.hasSuffix("/") ? 1 : 0).lastIndex(of: "/").map { f.distance(from: f.startIndex, to: $0) + 1 }) ?? 0
            for (i, ch) in fl.enumerated() where qi < ql.count && ch == ql[qi] {
                score += (i == last + 1) ? 6 : 1
                if i >= baseStart { score += 3 }
                if i == baseStart { score += 8 }
                last = i
                qi += 1
            }
            if qi == ql.count { scored.append((score * 100 - fl.count, f)) }
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(limit).map { $0.1 }
    }
}

/// Borderless floating list anchored above the caret.
final class CompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    struct Item { let title: String; let detail: String?; let value: String }
    private var panel: NSPanel?
    private let table = NSTableView()
    private var items: [Item] = []
    var onAccept: ((Item) -> Void)?
    var isVisible: Bool { panel?.isVisible == true }

    override init() {
        super.init()
        let col = NSTableColumn(identifier: .init("c"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 26
        table.style = .plain
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(clicked)
        table.action = #selector(clicked)
    }

    func show(_ items: [Item], above rect: NSRect, parent: NSWindow) {
        self.items = items
        if panel == nil {
            let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.level = .popUpMenu
            let glass = NSGlassEffectView()
            glass.cornerRadius = 12
            let sc = NSScrollView()
            sc.drawsBackground = false
            sc.documentView = table
            sc.hasVerticalScroller = true
            sc.autohidesScrollers = true
            glass.contentView = sc
            p.contentView = glass
            panel = p
        }
        guard let panel else { return }
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let h = min(CGFloat(items.count) * 28 + 10, 320)
        let w: CGFloat = 420
        panel.setFrame(NSRect(x: rect.minX - 8, y: rect.maxY + 8, width: w, height: h), display: true)
        (panel.contentView as? NSGlassEffectView)?.contentView?.frame = NSRect(x: 0, y: 5, width: w, height: h - 10)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func move(_ d: Int) {
        guard !items.isEmpty else { return }
        let r = max(0, min(items.count - 1, table.selectedRow + d))
        table.selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    func accept() {
        let r = table.selectedRow
        guard r >= 0, r < items.count else { hide(); return }
        onAccept?(items[r])
    }

    @objc private func clicked() { accept() }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let it = items[row]
        let v = NSTableCellView()
        let tf = NSTextField(labelWithString: "")
        let a = NSMutableAttributedString(string: it.title, attributes: [.font: Theme.smallFont, .foregroundColor: NSColor.labelColor])
        if let d = it.detail { a.append(NSAttributedString(string: "   " + d, attributes: [.font: Theme.captionFont, .foregroundColor: NSColor.secondaryLabelColor])) }
        tf.attributedStringValue = a
        tf.lineBreakMode = .byTruncatingMiddle
        tf.frame = NSRect(x: 12, y: 4, width: max(40, tableView.bounds.width - 24), height: 18)
        tf.autoresizingMask = [.width]
        v.addSubview(tf)
        return v
    }
}

/// Filled accent circle with a symbol, used for send/stop.
final class CircleButton: NSControl {
    var symbol = "arrow.up" { didSet { needsDisplay = true } }
    var filled = true { didSet { needsDisplay = true } }
    override var isEnabled: Bool { didSet { needsDisplay = true } }
    private var hovering = false
    private var pressed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { guard isEnabled else { return }; pressed = true; needsDisplay = true }
    override func mouseUp(with event: NSEvent) {
        guard pressed else { return }
        pressed = false
        needsDisplay = true
        if bounds.contains(convert(event.locationInWindow, from: nil)), let action { NSApp.sendAction(action, to: target, from: self) }
    }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }
            let r = self.bounds.insetBy(dx: 1, dy: 1)
            var c = Theme.accent
            if !self.isEnabled { c = c.withAlphaComponent(0.35) }
            else if self.pressed { c = c.blended(withFraction: 0.2, of: .black) ?? c }
            else if self.hovering { c = c.blended(withFraction: 0.08, of: .black) ?? c }
            ctx.setFillColor(c.cgColor)
            ctx.fillEllipse(in: r)
            drawIcon(self.symbol, in: r, size: self.symbol == "stop.fill" ? 11 : 14, color: .white, weight: .bold, ctx: ctx)
        }
    }
}

/// Label that never intercepts mouse events (used for the placeholder over the text view).
final class PassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
