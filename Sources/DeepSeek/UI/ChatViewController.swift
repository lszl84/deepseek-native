import AppKit

protocol ChatViewControllerDelegate: AnyObject {
    func chatDidStartSession(_ session: Session)
    func chatRequestsNewSession()
    func chatRequestsWorkspacePicker()
    func chatRequestsSettings()
    func chatRequestsRename()
}

/// Flipped clip view so short documents stay pinned to the top.
final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

final class ChatViewController: NSViewController, TranscriptViewDelegate, ComposerDelegate {
    weak var delegate: ChatViewControllerDelegate?
    private(set) var session: Session?
    /// Workspace used when the view shows the empty state (no session yet).
    var pendingWorkspace: String? { didSet { updateEmptyState() } }

    private let scroll = NSScrollView()
    private let transcript = TranscriptView(frame: .zero)
    /// Sizes the scrollable area; the transcript canvas inside it only covers the visible rect.
    private let docView = FlippedView()
    private let composer = ComposerView(frame: .zero)
    private let statusLabel = NSTextField(labelWithString: "")
    private let planBar = PlanBarView()
    private let scrollDownButton = NSButton()
    private let emptyView = EmptyStateView()
    private let scrim = ScrimView()
    private var state = TranscriptState()
    private var rebuildScheduled = false
    private var tickTimer: Timer?
    private var stickToBottom = true
    private var observers: [NSObjectProtocol] = []

    override func loadView() {
        let root = ChatRootView()
        root.wantsLayer = true
        view = root

        scroll.contentView = FlippedClipView()
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.background
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.automaticallyAdjustsContentInsets = true
        docView.addSubview(transcript)
        scroll.documentView = docView
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        transcript.delegate = self
        transcript.onContentHeightChange = { [weak self] in self?.syncDocumentSize() }
        root.addSubview(scroll)

        root.addSubview(emptyView)
        emptyView.onWorkspace = { [weak self] in self?.delegate?.chatRequestsWorkspacePicker() }

        planBar.isHidden = true
        planBar.onToggle = { [weak self] in self?.view.needsLayout = true }
        root.addSubview(scrim)
        root.addSubview(planBar)

        composer.delegate = self
        root.addSubview(composer)

        statusLabel.font = Theme.captionFont
        statusLabel.textColor = Theme.tertiaryText
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingTail
        root.addSubview(statusLabel)

        scrollDownButton.bezelStyle = .glass
        scrollDownButton.borderShape = .circle
        scrollDownButton.image = Theme.symbol("chevron.down", size: 12, weight: .semibold)
        scrollDownButton.imagePosition = .imageOnly
        scrollDownButton.target = self
        scrollDownButton.action = #selector(scrollToBottomAction)
        scrollDownButton.isHidden = true
        root.addSubview(scrollDownButton)

        root.onLayout = { [weak self] in self?.layoutViews() }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in self?.scrolled() })
        observers.append(nc.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in self?.syncDocumentSize() })
        observers.append(nc.addObserver(forName: Session.changed, object: nil, queue: .main) { [weak self] n in self?.sessionChanged(n) })
        observers.append(nc.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in self?.scheduleRebuild() })
        updateEmptyState()
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    // MARK: Session

    func show(session: Session?) {
        if session === self.session { return }
        self.session = session
        state = TranscriptState()
        transcript.clearSelection()
        if let s = session {
            s.load()
            composer.permission = s.permission
            composer.model = s.model
            composer.effort = s.effort
        } else {
            composer.permission = Settings.shared.permissionMode
            composer.model = Settings.shared.model
            composer.effort = Settings.shared.effort
        }
        rebuild()
        stickToBottom = true
        scrollToBottom()
        updateEmptyState()
        updateTicker()
        composer.focus()
    }

    private func sessionChanged(_ n: Notification) {
        guard let s = n.object as? Session, s === session else { return }
        scheduleRebuild()
        if case .meta = (n.userInfo?["change"] as? Session.Change) ?? .reset { updateTicker() }
    }

    private func scheduleRebuild() {
        guard !rebuildScheduled else { return }
        rebuildScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rebuildScheduled = false
            self.rebuild()
        }
    }

    private func rebuild() {
        guard let s = session else {
            transcript.apply([])
            updateStatus()
            planBar.isHidden = true
            composer.running = false
            return
        }
        let specs = TranscriptBuilder.build(session: s, state: &state, now: Date().timeIntervalSince1970)
        transcript.apply(specs)
        composer.running = s.isRunning
        composer.placeholderText = !s.pendingQuestions.isEmpty ? "Type your answer…" : (s.isRunning ? "Send a message to steer the agent…" : "Message or run a task, / commands, @ files")
        planBar.todos = s.todos
        planBar.isHidden = s.todos.isEmpty || s.todos.allSatisfy { $0.status == "completed" } && !s.isRunning
        updateStatus()
        updateEmptyState()
        view.needsLayout = true
        if stickToBottom { scrollToBottom() }
    }

    private func updateTicker() {
        let running = session?.isRunning == true
        if running && tickTimer == nil {
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, let t = self.session?.turns.last else { return }
                self.transcript.invalidateItem(key: "h\(t.index)")
            }
        } else if !running {
            tickTimer?.invalidate()
            tickTimer = nil
        }
    }

    private func updateStatus() {
        guard let s = session, !s.messages.isEmpty else { statusLabel.stringValue = ""; return }
        var parts: [String] = []
        parts.append("\(s.turns.count) turn\(s.turns.count == 1 ? "" : "s") \(s.stepCount) steps")
        if let r = s.outputRate { parts.append("\(Int(r)) tok/s") }
        let u = s.totalUsage
        parts.append(Fmt.tokens(u.total) + " tok")
        if let c = s.cacheHitRate { parts.append("Cache hit \(Int(c * 100))%") }
        let ctx = Double(s.lastPromptTokens) / Double(max(1, Settings.shared.contextWindow))
        parts.append("Context \(max(0, Int((ctx * 100).rounded())))%")
        statusLabel.stringValue = parts.joined(separator: "  ·  ")
    }

    private func updateEmptyState() {
        let empty = session == nil || session!.messages.isEmpty
        emptyView.isHidden = !empty
        scroll.isHidden = empty
        emptyView.workspaceName = (session?.cwd ?? pendingWorkspace).map { ($0 as NSString).lastPathComponent }
        view.needsLayout = true
    }

    // MARK: Layout

    private func layoutViews() {
        let b = view.bounds
        scroll.frame = b
        let colW = min(transcript.maxColumnWidth + 24, b.width - 32)
        let compH = composer.preferredHeight
        let empty = !emptyView.isHidden
        var compY: CGFloat
        if empty {
            emptyView.frame = NSRect(x: (b.width - colW) / 2, y: b.height / 2 + 10, width: colW, height: 120)
            compY = b.height / 2 - compH + 4
            statusLabel.isHidden = true
        } else {
            compY = 30
            statusLabel.isHidden = false
            statusLabel.frame = NSRect(x: (b.width - colW) / 2, y: 7, width: colW, height: 18)
        }
        composer.frame = NSRect(x: (b.width - colW) / 2, y: compY, width: colW, height: compH)
        var top = composer.frame.maxY + 8
        if !planBar.isHidden {
            let ph = planBar.preferredHeight
            planBar.frame = NSRect(x: (b.width - colW) / 2 + 12, y: top, width: colW - 24, height: ph)
            top += ph + 8
        }
        scrollDownButton.frame = NSRect(x: b.width / 2 - 16, y: top + 4, width: 32, height: 32)
        scrim.isHidden = empty
        scrim.frame = NSRect(x: 0, y: 0, width: b.width - 14, height: composer.frame.minY + compH * 0.55)
        transcript.bottomInset = (top - 0) + 40
        syncDocumentSize()
    }

    private func syncDocumentSize() {
        let clip = scroll.contentView.bounds
        let h = max(transcript.contentHeight, clip.height)
        if abs(docView.frame.width - clip.width) > 0.5 || abs(docView.frame.height - h) > 0.5 {
            docView.setFrameSize(NSSize(width: clip.width, height: h))
        }
        positionCanvas()
        if stickToBottom { scrollToBottom() }
        updateScrollButton()
    }

    private var isAtBottom: Bool {
        let clip = scroll.contentView.bounds
        return clip.maxY >= docView.frame.height - 60
    }

    private var programmaticScroll = false

    /// Keeps the canvas exactly over the visible part of the document, in document coordinates.
    private func positionCanvas() {
        let clip = scroll.contentView.bounds
        let r = NSRect(x: 0, y: max(0, clip.minY), width: clip.width, height: clip.height)
        if transcript.frame != r {
            transcript.frame = r
            transcript.setBoundsOrigin(r.origin)
            transcript.needsDisplay = true
        }
    }

    private func scrolled() {
        positionCanvas()
        if !programmaticScroll { stickToBottom = isAtBottom }
        updateScrollButton()
    }

    private func updateScrollButton() {
        scrollDownButton.isHidden = isAtBottom || !emptyView.isHidden
    }

    private func scrollToBottom() {
        let clip = scroll.contentView
        let y = max(-clip.contentInsets.top, docView.frame.height - clip.bounds.height)
        guard abs(clip.bounds.origin.y - y) > 0.5 else { return }
        programmaticScroll = true
        clip.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(clip)
        programmaticScroll = false
    }

    @objc private func scrollToBottomAction() {
        stickToBottom = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            let clip = scroll.contentView
            clip.animator().setBoundsOrigin(NSPoint(x: 0, y: max(0, docView.frame.height - clip.bounds.height)))
        }
    }

    // MARK: Transcript hits

    func transcript(_ view: TranscriptView, didHit hit: Hit) {
        guard let s = session else { return }
        switch hit {
        case .toggle(let key):
            if state.effectiveExpanded.contains(key) { state.expanded.remove(key); state.collapsed.insert(key) }
            else { state.expanded.insert(key); state.collapsed.remove(key) }
            let wasBottom = stickToBottom
            stickToBottom = false
            rebuild()
            stickToBottom = wasBottom && isAtBottom
        case .link(let url): openLink(url, cwd: s.cwd)
        case .openFile(let p): openLink("file://" + p, cwd: s.cwd)
        case .approve(let id, let d): s.agent?.resolveApproval(id, d)
        case .chooseOption(let req, let q, let label):
            guard let request = s.pendingQuestions.first(where: { $0.id == req }), let qq = request.questions.first(where: { $0.id == q }) else { return }
            let k = req + "/" + q
            var set = state.selectedOptions[k] ?? []
            if qq.multiSelect { if set.contains(label) { set.remove(label) } else { set.insert(label) } } else { set = [label] }
            state.selectedOptions[k] = set
            if request.questions.count == 1 && !qq.multiSelect {
                s.agent?.resolveQuestion(req, [q: [label]])
            } else { rebuild() }
        case .submitAnswers(let req):
            guard let request = s.pendingQuestions.first(where: { $0.id == req }) else { return }
            var answers: [String: [String]] = [:]
            for q in request.questions { answers[q.id] = Array(state.selectedOptions[req + "/" + q.id] ?? []) }
            s.agent?.resolveQuestion(req, answers)
        case .dismissQuestion(let req): s.agent?.resolveQuestion(req, nil)
        case .retry: retry()
        case .cancelQueued(let i):
            if i < s.queuedInputs.count { s.queuedInputs.remove(at: i); s.metaChanged() }
        case .copy: break
        }
    }

    private func openLink(_ url: String, cwd: String) {
        if url.hasPrefix("file://") {
            var path = String(url.dropFirst(7))
            if let hash = path.firstIndex(of: "#") { path = String(path[..<hash]) }
            path = path.removingPercentEncoding ?? path
            if FileManager.default.fileExists(atPath: path) {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            } else { NSSound.beep() }
        } else if let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
    }

    // MARK: Actions

    func agentFor(_ s: Session) -> Agent { s.agent ?? Agent(session: s) }

    func retry() {
        guard let s = session, !s.isRunning else { return }
        // Resend the last human message as a fresh turn.
        if let last = s.messages.last(where: { $0.role == .user && $0.isToolResults != true && $0.notice != true }) {
            agentFor(s).submit(last.text)
        }
    }

    func stop() { session?.agent?.cancel() }

    var lastResponseText: String? { session?.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty })?.text }

    func focusComposer() { composer.focus() }

    var debugComposer: ComposerView? { composer }

    func debugExpandAll() {
        guard let s = session else { return }
        for it in transcript.items where it.key.hasPrefix("g.") { state.expanded.insert(it.key) }
        for id in s.toolRuns.keys { state.expanded.insert(id) }
        rebuild()
        stickToBottom = false
    }

    func debugScroll(to y: CGFloat) {
        stickToBottom = false
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    func insertIntoComposer(_ text: String) { composer.setText(text); composer.focus() }

    // MARK: ComposerDelegate

    var composerWorkspacePath: String? { session?.cwd ?? pendingWorkspace }

    func composerSend(_ text: String, images: [ContentBlock.ImageData]) {
        var s = session
        if s == nil {
            guard let ws = pendingWorkspace else { delegate?.chatRequestsWorkspacePicker(); return }
            let ns = SessionStore.shared.newSession(cwd: ws)
            ns.permission = composer.permission
            ns.model = composer.model
            ns.effort = composer.effort
            ns.saveConfig()
            s = ns
            session = ns
            delegate?.chatDidStartSession(ns)
        }
        guard let s else { return }
        // Answer a pending question with free text.
        if let q = s.pendingQuestions.first {
            var answers: [String: [String]] = [:]
            for (i, qq) in q.questions.enumerated() { answers[qq.id] = i == 0 ? [text] : Array(state.selectedOptions[q.id + "/" + qq.id] ?? []) }
            s.agent?.resolveQuestion(q.id, answers)
            return
        }
        stickToBottom = true
        agentFor(s).submit(text, images: images)
        updateTicker()
    }

    func composerStop() { stop() }

    func composerHeightChanged() { view.needsLayout = true }

    func composerPermissionChanged(_ mode: PermissionMode) {
        if let s = session { s.permission = mode; s.saveConfig() }
        Settings.shared.permissionMode = mode
        Settings.shared.save(notify: false)
    }

    func composerModelChanged(model: String, effort: ReasoningEffort) {
        if let s = session { s.model = model; s.effort = effort; s.saveConfig() }
        Settings.shared.model = model
        Settings.shared.effort = effort
        Settings.shared.save(notify: false)
    }

    func composerSlashCommand(_ command: String) {
        switch command {
        case "/new": delegate?.chatRequestsNewSession()
        case "/stop": stop()
        case "/retry": retry()
        case "/rename": delegate?.chatRequestsRename()
        case "/copy":
            if let t = lastResponseText { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string) }
        case "/export": exportMarkdown()
        case "/settings": delegate?.chatRequestsSettings()
        case "/workspace": delegate?.chatRequestsWorkspacePicker()
        default: break
        }
    }

    func exportMarkdown() {
        guard let s = session, let window = view.window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = s.title.replacingOccurrences(of: "/", with: "-") + ".md"
        panel.beginSheetModal(for: window) { r in
            guard r == .OK, let url = panel.url else { return }
            try? TranscriptExport.markdown(s).write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

/// Fades transcript content out behind the composer and status line.
final class ScrimView: NSView {
    private let gradient = CAGradientLayer()
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(gradient)
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        gradient.frame = bounds
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); updateColors() }
    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let c = Theme.background
            self.gradient.colors = [c.cgColor, c.cgColor, c.withAlphaComponent(0).cgColor]
            self.gradient.locations = [0, 0.55, 1]
            self.gradient.startPoint = CGPoint(x: 0.5, y: 0)
            self.gradient.endPoint = CGPoint(x: 0.5, y: 1)
        }
    }
}

final class ChatRootView: NSView {
    var onLayout: (() -> Void)?
    override func layout() {
        super.layout()
        onLayout?()
    }
}

enum TranscriptExport {
    static func markdown(_ s: Session) -> String {
        var out = "# \(s.title)\n\n_Workspace: \(s.cwd)_\n\n"
        for m in s.messages {
            switch m.role {
            case .user:
                for b in m.blocks {
                    switch b {
                    case .text(let t): out += (m.isToolResults == true ? "**User (steer):** " : "## User\n\n") + t + "\n\n"
                    case .toolResult(_, let c, let err, _): out += "<details><summary>Tool result\(err ? " (error)" : "")</summary>\n\n```\n\(c.prefix(4000))\n```\n</details>\n\n"
                    default: break
                    }
                }
            case .assistant:
                for b in m.blocks {
                    switch b {
                    case .text(let t): out += t + "\n\n"
                    case .toolUse(_, let name, let input): out += "**\(ToolPresentation.displayName(name))** `\(input.prefix(300))`\n\n"
                    default: break
                    }
                }
            }
        }
        return out
    }
}

/// Collapsible to-do progress pill shown above the composer.
final class PlanBarView: NSView {
    var todos: [TodoItem] = [] { didSet { if todos != oldValue { needsDisplay = true; onToggle?() } } }
    var expanded = false
    var onToggle: (() -> Void)?
    private let glass = NSGlassEffectView()
    private let canvas = PlanCanvas()

    override init(frame: NSRect) {
        super.init(frame: frame)
        glass.cornerRadius = 14
        addSubview(glass)
        canvas.owner = self
        glass.contentView = canvas
    }
    required init?(coder: NSCoder) { fatalError() }

    var preferredHeight: CGFloat { expanded ? CGFloat(36 + min(todos.count, 12) * 24 + 6) : 36 }

    override func layout() {
        super.layout()
        glass.frame = bounds
        canvas.frame = glass.bounds
        canvas.needsDisplay = true
    }

    override var needsDisplay: Bool { didSet { canvas.needsDisplay = true } }

    override func mouseDown(with event: NSEvent) {
        expanded.toggle()
        onToggle?()
    }

    final class PlanCanvas: NSView {
        weak var owner: PlanBarView?
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance { self.drawPlan() }
        }
        private func drawPlan() {
            guard let o = owner, let ctx = NSGraphicsContext.current?.cgContext else { return }
            let done = o.todos.filter { $0.status == "completed" }.count
            let current = o.todos.first { $0.status == "in_progress" } ?? o.todos.first { $0.status == "pending" }
            drawIcon("checklist", in: CGRect(x: 12, y: 0, width: 16, height: 36), size: 12, color: Theme.secondaryText, ctx: ctx)
            let head = "Plan  \(done)/\(o.todos.count)"
            drawLabel(head, in: CGRect(x: 34, y: 0, width: 100, height: 36), font: Theme.bodyBold, color: Theme.text)
            let hw = textWidth(head, Theme.bodyBold)
            if let c = current, !o.expanded {
                drawLabel(c.content, in: CGRect(x: 44 + hw, y: 0, width: bounds.width - hw - 80, height: 36), font: Theme.smallFont, color: Theme.secondaryText)
            }
            drawIcon(o.expanded ? "chevron.down" : "chevron.up", in: CGRect(x: bounds.width - 28, y: 0, width: 16, height: 36), size: 10, color: Theme.tertiaryText, weight: .semibold, ctx: ctx)
            guard o.expanded else { return }
            var y: CGFloat = 36
            for t in o.todos.prefix(12) {
                let box = CGRect(x: 14, y: y + 5, width: 14, height: 14)
                switch t.status {
                case "completed":
                    fillRounded(ctx, box, 4, Theme.accent)
                    drawIcon("checkmark", in: box, size: 9, color: .white, weight: .bold, ctx: ctx)
                case "in_progress":
                    strokeRounded(ctx, box, 4, Theme.accent, width: 1.4)
                    fillRounded(ctx, box.insetBy(dx: 4, dy: 4), 2, Theme.accent)
                default:
                    strokeRounded(ctx, box, 4, Theme.tertiaryText, width: 1.2)
                }
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: t.status == "in_progress" ? Theme.bodyBold : Theme.smallFont,
                    .foregroundColor: t.status == "completed" ? Theme.tertiaryText : Theme.text,
                    .strikethroughStyle: t.status == "completed" ? 1 : 0,
                ]
                let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingTail
                var a = attrs; a[.paragraphStyle] = p
                (t.content as NSString).draw(with: CGRect(x: 36, y: y + 3, width: bounds.width - 50, height: 18), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: a)
                y += 24
            }
        }
    }
}

/// Logo, title and workspace chooser shown for an empty session.
final class EmptyStateView: NSView {
    var onWorkspace: (() -> Void)?
    var workspaceName: String? { didSet { updateButton() } }
    private let logo = LogoView()
    private let title = NSTextField(labelWithString: "Into the Unknown")
    private let badge = NSTextField(labelWithString: "Native")
    private let workspaceButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(logo)
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        title.textColor = Theme.text
        addSubview(title)
        badge.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        badge.textColor = Theme.accent
        badge.wantsLayer = true
        badge.layer?.backgroundColor = Theme.accentSoft.cgColor
        badge.layer?.cornerRadius = 9
        badge.alignment = .center
        addSubview(badge)
        workspaceButton.bezelStyle = .accessoryBarAction
        workspaceButton.isBordered = false
        workspaceButton.font = Theme.smallFont
        workspaceButton.imagePosition = .imageLeading
        workspaceButton.target = self
        workspaceButton.action = #selector(pick)
        addSubview(workspaceButton)
        updateButton()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func updateButton() {
        workspaceButton.image = Theme.symbol(workspaceName == nil ? "folder.badge.plus" : "folder", size: 13)
        workspaceButton.title = (workspaceName ?? "Choose workspace") + "  ⌄"
        workspaceButton.contentTintColor = Theme.secondaryText
        needsLayout = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        badge.layer?.backgroundColor = Theme.accentSoft.cgColor
    }

    @objc private func pick() { onWorkspace?() }

    override func layout() {
        super.layout()
        let tw = title.intrinsicContentSize.width
        let bw = badge.intrinsicContentSize.width + 16
        let total = 44 + 10 + tw + 10 + bw
        var x = (bounds.width - total) / 2
        let y = bounds.height - 56
        logo.frame = NSRect(x: x, y: y, width: 44, height: 44)
        x += 54
        title.frame = NSRect(x: x, y: y + 6, width: tw + 4, height: 32)
        x += tw + 10
        badge.frame = NSRect(x: x, y: y + 12, width: bw, height: 20)
        let ww = workspaceButton.intrinsicContentSize.width + 8
        workspaceButton.frame = NSRect(x: 6, y: 0, width: ww, height: 28)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
