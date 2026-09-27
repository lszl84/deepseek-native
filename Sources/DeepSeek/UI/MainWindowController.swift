import AppKit

final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, SidebarDelegate, ChatViewControllerDelegate {
    private let split = NSSplitViewController()
    private let sidebar = SidebarViewController()
    let chat = ChatViewController()
    private var observers: [NSObjectProtocol] = []

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "DeepSeek"
        window.titleVisibility = .visible
        window.minSize = NSSize(width: 720, height: 480)
        window.setFrameAutosaveName("MainWindow")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self

        sidebar.delegate = self
        chat.delegate = self
        let sideItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sideItem.minimumThickness = 220
        sideItem.maximumThickness = 380
        sideItem.canCollapse = true
        sideItem.allowsFullHeightLayout = true
        let contentItem = NSSplitViewItem(viewController: chat)
        contentItem.minimumThickness = 440
        split.addSplitViewItem(sideItem)
        split.addSplitViewItem(contentItem)
        split.splitView.autosaveName = "MainSplit"
        window.contentViewController = split
        if !window.setFrameUsingName("MainWindow") {
            window.setContentSize(NSSize(width: 1280, height: 820))
            window.center()
        }

        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: Session.changed, object: nil, queue: .main) { [weak self] n in
            guard let s = n.object as? Session, s === self?.chat.session else { return }
            switch (n.userInfo?["change"] as? Session.Change) ?? .reset {
            case .meta, .reset: self?.updateTitle()
            default: break
            }
        })
        observers.append(nc.addObserver(forName: Agent.attentionNeeded, object: nil, queue: .main) { _ in
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        })
        observers.append(nc.addObserver(forName: Agent.turnFinished, object: nil, queue: .main) { [weak self] n in
            guard let s = n.object as? Session, !s.ephemeral else { return }
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
            if s !== self?.chat.session { SessionStore.shared.trim(keep: self?.chat.session?.id) }
            self?.updateDockBadge()
        })

        // Restore the last workspace or session.
        if let ws = SessionStore.shared.workspace(id: SessionStore.shared.lastWorkspaceId) ?? SessionStore.shared.workspaces.first {
            if let recent = SessionStore.shared.sessions(in: ws).first {
                openSession(recent.id)
            } else {
                chat.pendingWorkspace = ws.path
                chat.show(session: nil)
            }
        } else {
            chat.show(session: nil)
        }
        updateTitle()
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    // MARK: Sessions

    func openSession(_ id: String) {
        guard let s = SessionStore.shared.session(id: id) else { return }
        chat.pendingWorkspace = s.cwd
        chat.show(session: s)
        sidebar.select(sessionId: id)
        if let w = SessionStore.shared.workspace(forPath: s.cwd) { SessionStore.shared.lastWorkspaceId = w.id }
        SessionStore.shared.trim(keep: id)
        updateTitle()
    }

    func newSession(in workspace: String?) {
        let ws = workspace ?? chat.session?.cwd ?? chat.pendingWorkspace ?? SessionStore.shared.workspaces.first?.path
        guard let ws else { pickWorkspace(); return }
        chat.pendingWorkspace = ws
        chat.show(session: nil)
        sidebar.select(sessionId: nil)
        updateTitle()
        chat.focusComposer()
    }

    func pickWorkspace() {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose Workspace"
        panel.message = "Choose the project folder the agent will work in."
        panel.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let url = panel.url, let self else { return }
            let w = SessionStore.shared.addWorkspace(path: url.path)
            SessionStore.shared.lastWorkspaceId = w.id
            self.newSession(in: w.path)
        }
    }

    func renameSession(_ id: String) {
        guard let window, let entry = SessionStore.shared.entry(id: id) else { return }
        let a = NSAlert()
        a.messageText = "Rename Session"
        let tf = NSTextField(string: entry.title)
        tf.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        a.accessoryView = tf
        a.addButton(withTitle: "Rename")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = tf
        a.beginSheetModal(for: window) { r in
            let t = tf.stringValue.trimmingCharacters(in: .whitespaces)
            if r == .alertFirstButtonReturn, !t.isEmpty { SessionStore.shared.rename(id, to: t) }
        }
    }

    private func updateTitle() {
        guard let window else { return }
        if let s = chat.session, !s.messages.isEmpty {
            window.title = s.title
            window.subtitle = (s.cwd as NSString).abbreviatingWithTildeInPath + (s.isRunning ? "  ·  Working…" : "")
        } else {
            window.title = "New Session"
            window.subtitle = chat.pendingWorkspace.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
        }
    }

    private func updateDockBadge() {
        let n = SessionStore.shared.runningSessions.count
        NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
    }

    // MARK: SidebarDelegate

    func sidebarSelectSession(_ id: String) { openSession(id) }
    func sidebarNewSession(in workspace: String?) { newSession(in: workspace) }
    func sidebarAddWorkspace() { pickWorkspace() }
    func sidebarOpenSettings() { SettingsWindowController.shared.showWindow(nil) }
    func sidebarRename(_ id: String) { renameSession(id) }

    // MARK: ChatViewControllerDelegate

    func chatDidStartSession(_ session: Session) {
        sidebar.select(sessionId: session.id)
        if let w = SessionStore.shared.workspace(forPath: session.cwd) { SessionStore.shared.lastWorkspaceId = w.id }
        updateTitle()
        updateDockBadge()
    }
    func chatRequestsNewSession() { newSession(in: nil) }
    func chatRequestsWorkspacePicker() { pickWorkspace() }
    func chatRequestsSettings() { SettingsWindowController.shared.showWindow(nil) }
    func chatRequestsRename() { if let s = chat.session { renameSession(s.id) } }

    // MARK: Toolbar

    private static let newItem = NSToolbarItem.Identifier("new")
    private static let moreItem = NSToolbarItem.Identifier("more")
    private static let stopItem = NSToolbarItem.Identifier("stop")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, .flexibleSpace, Self.newItem, Self.moreItem]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { toolbarDefaultItemIdentifiers(toolbar) }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.newItem:
            let it = NSToolbarItem(itemIdentifier: id)
            it.image = Theme.symbol("square.and.pencil", size: 14)
            it.label = "New Session"
            it.toolTip = "New Session (⌘N)"
            it.target = self
            it.action = #selector(newSessionAction)
            return it
        case Self.moreItem:
            let it = NSMenuToolbarItem(itemIdentifier: id)
            it.image = Theme.symbol("ellipsis", size: 14)
            it.label = "More"
            it.showsIndicator = false
            let m = NSMenu()
            m.addItem(withTitle: "Rename Session…", action: #selector(renameAction), keyEquivalent: "").target = self
            m.addItem(withTitle: "Export as Markdown…", action: #selector(exportAction), keyEquivalent: "").target = self
            m.addItem(withTitle: "Copy Last Response", action: #selector(copyLastAction), keyEquivalent: "").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Reveal Workspace in Finder", action: #selector(revealWorkspaceAction), keyEquivalent: "").target = self
            m.addItem(withTitle: "Reveal Session Log", action: #selector(revealLogAction), keyEquivalent: "").target = self
            m.addItem(.separator())
            m.addItem(withTitle: "Delete Session…", action: #selector(deleteAction), keyEquivalent: "").target = self
            it.menu = m
            return it
        default: return nil
        }
    }

    @objc func newSessionAction() { newSession(in: nil) }
    @objc func renameAction() { chatRequestsRename() }
    @objc func exportAction() { chat.exportMarkdown() }
    @objc func copyLastAction() {
        if let t = chat.lastResponseText { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string) }
    }
    @objc func revealWorkspaceAction() {
        if let p = chat.session?.cwd ?? chat.pendingWorkspace { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: p) }
    }
    @objc func revealLogAction() {
        guard let s = chat.session else { return }
        NSWorkspace.shared.activateFileViewerSelecting([s.fileURLForExport])
    }
    @objc func deleteAction() {
        guard let s = chat.session, let window else { return }
        let a = NSAlert()
        a.messageText = "Delete “\(s.title)”?"
        a.informativeText = "The session transcript will be permanently removed."
        a.addButton(withTitle: "Delete").hasDestructiveAction = true
        a.addButton(withTitle: "Cancel")
        a.beginSheetModal(for: window) { [weak self] r in
            guard r == .alertFirstButtonReturn else { return }
            SessionStore.shared.delete(s.id)
            self?.newSession(in: s.cwd)
        }
    }
    @objc func stopAction() { chat.stop() }
    @objc func openWorkspaceAction() { pickWorkspace() }
    @objc func focusComposerAction() { chat.focusComposer() }
    @objc func retryAction() { chat.retry() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}
