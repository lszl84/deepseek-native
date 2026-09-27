import AppKit

final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func item(_ vc: NSViewController, _ label: String, _ symbol: String) -> NSTabViewItem {
            let it = NSTabViewItem(viewController: vc)
            it.label = label
            it.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            return it
        }
        tabs.addTabViewItem(item(GeneralPane(), "General", "gearshape"))
        tabs.addTabViewItem(item(ModelsPane(), "Models", "cpu"))
        tabs.addTabViewItem(item(AgentPane(), "Agent", "wand.and.stars"))
        let w = NSWindow(contentViewController: tabs)
        w.title = "Settings"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        super.init(window: w)
        w.center()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// Base pane building a two-column form with NSGridView.
class FormPane: NSViewController {
    let grid = NSGridView()
    var width: CGFloat { 520 }

    override func loadView() {
        let v = NSView()
        grid.rowSpacing = 12
        grid.columnSpacing = 12
        grid.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: v.topAnchor, constant: 24),
            grid.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 28),
            grid.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -28),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: v.bottomAnchor, constant: -24),
            v.widthAnchor.constraint(equalToConstant: width),
        ])
        view = v
        build()
        if grid.numberOfColumns > 0 {
            grid.column(at: 0).xPlacement = .trailing
        }
        grid.rowAlignment = .firstBaseline
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    func build() {}

    func row(_ label: String, _ view: NSView) {
        let l = NSTextField(labelWithString: label)
        l.alignment = .right
        grid.addRow(with: [l, view])
    }

    func note(_ text: String) {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = 340
        grid.addRow(with: [NSGridCell.emptyContentView, t])
    }

    func popup(_ items: [String], selected: Int, action: Selector) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: items)
        p.selectItem(at: max(0, selected))
        p.target = self
        p.action = action
        return p
    }

    func check(_ title: String, _ on: Bool, action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: self, action: action)
        b.state = on ? .on : .off
        return b
    }

    func save() { Settings.shared.save() }
}

final class GeneralPane: FormPane, NSTextViewDelegate {
    private var instructions = NSTextView()

    override func build() {
        let s = Settings.shared
        row("Appearance:", popup(["System", "Light", "Dark"], selected: Appearance.allCases.firstIndex(of: s.appearance) ?? 0, action: #selector(appearance(_:))))
        row("Composer:", check("Send with Return (Shift-Return for a new line)", s.sendOnEnter, action: #selector(sendOnEnter(_:))))
        let sc = NSScrollView()
        sc.hasVerticalScroller = true
        sc.borderType = .bezelBorder
        instructions.string = s.customInstructions
        instructions.font = .systemFont(ofSize: 12)
        instructions.isRichText = false
        instructions.delegate = self
        instructions.autoresizingMask = [.width]
        instructions.isVerticallyResizable = true
        sc.documentView = instructions
        sc.translatesAutoresizingMaskIntoConstraints = false
        sc.heightAnchor.constraint(equalToConstant: 110).isActive = true
        sc.widthAnchor.constraint(equalToConstant: 340).isActive = true
        row("Instructions:", sc)
        note("Added to the system prompt of every session. AGENTS.md or CLAUDE.md in the workspace root is included automatically.")
        let data = NSButton(title: "Show Data Folder", target: self, action: #selector(showData))
        row("Data:", data)
    }

    @objc private func appearance(_ p: NSPopUpButton) {
        Settings.shared.appearance = Appearance.allCases[p.indexOfSelectedItem]
        save()
        AppDelegate.applyAppearance()
    }
    @objc private func sendOnEnter(_ b: NSButton) { Settings.shared.sendOnEnter = b.state == .on; save() }
    @objc private func showData() { NSWorkspace.shared.open(Paths.appSupport) }
    func textDidChange(_ notification: Notification) {
        Settings.shared.customInstructions = instructions.string
        Settings.shared.save(notify: false)
    }
}

final class ModelsPane: FormPane, NSTextFieldDelegate {
    private let key = NSSecureTextField()
    private let base = NSTextField()
    private let status = NSTextField(labelWithString: "")

    override func build() {
        let s = Settings.shared
        key.stringValue = s.apiKey
        key.placeholderString = "sk-…"
        key.delegate = self
        key.widthAnchor.constraint(equalToConstant: 320).isActive = true
        row("DeepSeek API key:", key)
        note("Stored in the app's data folder with owner-only permissions. Imported from ~/.dsh/.credentials.yaml or $DEEPSEEK_API_KEY on first launch.")
        base.stringValue = s.baseURL
        base.delegate = self
        base.widthAnchor.constraint(equalToConstant: 320).isActive = true
        row("Base URL:", base)
        note("Anthropic-compatible Messages endpoint; /v1/messages is appended.")
        row("Default model:", popup(ModelInfo.all.map { $0.name }, selected: ModelInfo.all.firstIndex { $0.id == s.model } ?? 0, action: #selector(model(_:))))
        row("Reasoning effort:", popup(ReasoningEffort.allCases.map { $0.label }, selected: ReasoningEffort.allCases.firstIndex(of: s.effort) ?? 2, action: #selector(effort(_:))))
        let test = NSButton(title: "Test Connection", target: self, action: #selector(testConnection))
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [test, status])
        stack.spacing = 8
        row("", stack)
    }

    func controlTextDidChange(_ obj: Notification) {
        Settings.shared.apiKey = key.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.shared.baseURL = base.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        Settings.shared.save(notify: false)
    }

    @objc private func model(_ p: NSPopUpButton) { Settings.shared.model = ModelInfo.all[p.indexOfSelectedItem].id; save() }
    @objc private func effort(_ p: NSPopUpButton) { Settings.shared.effort = ReasoningEffort.allCases[p.indexOfSelectedItem]; save() }

    @objc private func testConnection() {
        status.stringValue = "Testing…"
        status.textColor = .secondaryLabelColor
        Task {
            let body: JSON = [
                "model": .string(Settings.shared.model), "max_tokens": 16, "stream": false, "thinking": ["type": "disabled"],
                "messages": [["role": "user", "content": [["type": "text", "text": "Reply with OK."]]]],
            ]
            do {
                _ = try await MessagesClient.shared.complete(body: body)
                await MainActor.run { self.status.stringValue = "Connected ✓"; self.status.textColor = .systemGreen }
            } catch {
                await MainActor.run { self.status.stringValue = (error as? LLMError)?.message ?? error.localizedDescription; self.status.textColor = .systemRed }
            }
        }
    }
}

final class AgentPane: FormPane {
    override func build() {
        let s = Settings.shared
        row("Default permissions:", popup(PermissionMode.allCases.map { $0.label }, selected: PermissionMode.allCases.firstIndex(of: s.permissionMode) ?? 1, action: #selector(perm(_:))))
        note("Read Only and Workspace Write run shell commands inside a macOS sandbox (sandbox-exec) that limits file writes. File edits outside the allowed area ask for approval.")
        let timeouts = [30, 60, 120, 300, 600]
        row("Command timeout:", popup(timeouts.map { "\($0) seconds" }, selected: timeouts.firstIndex(of: s.bashTimeoutMs / 1000) ?? 2, action: #selector(timeout(_:))))
        note("A command that runs longer moves to the background as a job instead of being killed.")
        row("Tools:", check("Web search (DeepSeek native search)", s.webSearchEnabled, action: #selector(web(_:))))
        row("", check("Subagents", s.subagentsEnabled, action: #selector(sub(_:))))
        note("Tool changes apply to new turns.")
    }
    @objc private func perm(_ p: NSPopUpButton) { Settings.shared.permissionMode = PermissionMode.allCases[p.indexOfSelectedItem]; save() }
    @objc private func timeout(_ p: NSPopUpButton) { Settings.shared.bashTimeoutMs = [30, 60, 120, 300, 600][p.indexOfSelectedItem] * 1000; save() }
    @objc private func web(_ b: NSButton) { Settings.shared.webSearchEnabled = b.state == .on; save() }
    @objc private func sub(_ b: NSButton) { Settings.shared.subagentsEnabled = b.state == .on; save() }
}
