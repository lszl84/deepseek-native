import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var main: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        ShellEnvironment.warmUp()
        AppDelegate.applyAppearance()
        buildMenu()
        let m = MainWindowController()
        main = m
        m.showWindow(nil)
        if let w = m.window, w.frame.width < 900 || w.frame.height < 600, let screen = w.screen ?? NSScreen.main {
            let vf = screen.visibleFrame
            let size = NSSize(width: min(1320, vf.width - 80), height: min(880, vf.height - 80))
            w.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height), display: true)
        }
        NSApp.activate()
        if SessionStore.shared.index.isEmpty && !HarnessImporter.candidates().isEmpty {
            DispatchQueue.global(qos: .utility).async { HarnessImporter.importAll() }
        }
        if ProcessInfo.processInfo.environment["DSN_IMPORT"] != nil { HarnessImporter.importAll() }
        DebugHooks.run(m)
        if Settings.shared.apiKey.isEmpty {
            DispatchQueue.main.async { SettingsWindowController.shared.showWindow(nil) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { main?.showWindow(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = SessionStore.shared.runningSessions
        guard !running.isEmpty else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "\(running.count) session\(running.count == 1 ? " is" : "s are") still working"
        a.informativeText = "Quitting stops the running agents."
        a.addButton(withTitle: "Quit")
        a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            running.forEach { $0.agent?.cancel(); $0.agent?.jobs.killAll() }
            return .terminateNow
        }
        return .terminateCancel
    }

    static func applyAppearance() {
        switch Settings.shared.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @objc func importHarness() {
        DispatchQueue.global(qos: .userInitiated).async {
            let n = HarnessImporter.importAll()
            DispatchQueue.main.async {
                let a = NSAlert()
                a.messageText = n == 0 ? "No new sessions to import" : "Imported \(n) session\(n == 1 ? "" : "s")"
                a.informativeText = "Sessions are read from ~/.dsh/sessions. Existing imports are skipped."
                a.runModal()
            }
        }
    }

    @objc func showSettings() { SettingsWindowController.shared.showWindow(nil) }
    @objc func showMain() { main?.showWindow(nil) }

    private func buildMenu() {
        let bar = NSMenu()
        func sub(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            item.submenu = m
            bar.addItem(item)
            return m
        }
        let app = sub("DeepSeek")
        app.addItem(withTitle: "About DeepSeek", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu()
        NSApp.servicesMenu = services.submenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(withTitle: "Hide DeepSeek", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit DeepSeek", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let file = sub("File")
        file.addItem(withTitle: "New Session", action: #selector(MainWindowController.newSessionAction), keyEquivalent: "n")
        file.addItem(withTitle: "Open Workspace…", action: #selector(MainWindowController.openWorkspaceAction), keyEquivalent: "o")
        file.addItem(withTitle: "Import DeepSeek Harness Sessions", action: #selector(importHarness), keyEquivalent: "")
        file.addItem(.separator())
        file.addItem(withTitle: "Export as Markdown…", action: #selector(MainWindowController.exportAction), keyEquivalent: "e").keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        let edit = sub("Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        find.submenu = NSMenu()
        edit.addItem(find)

        let session = sub("Session")
        session.addItem(withTitle: "Stop", action: #selector(MainWindowController.stopAction), keyEquivalent: ".")
        session.addItem(withTitle: "Retry Last Turn", action: #selector(MainWindowController.retryAction), keyEquivalent: "r")
        session.addItem(withTitle: "Focus Message Box", action: #selector(MainWindowController.focusComposerAction), keyEquivalent: "l")
        session.addItem(.separator())
        session.addItem(withTitle: "Rename…", action: #selector(MainWindowController.renameAction), keyEquivalent: "")
        session.addItem(withTitle: "Copy Last Response", action: #selector(MainWindowController.copyLastAction), keyEquivalent: "c").keyEquivalentModifierMask = [.command, .shift]
        session.addItem(withTitle: "Reveal Session Log", action: #selector(MainWindowController.revealLogAction), keyEquivalent: "")
        session.addItem(.separator())
        session.addItem(withTitle: "Delete…", action: #selector(MainWindowController.deleteAction), keyEquivalent: "")

        let view = sub("View")
        view.addItem(withTitle: "Toggle Sidebar", action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s").keyEquivalentModifierMask = [.command, .control]
        view.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f").keyEquivalentModifierMask = [.command, .control]

        let window = sub("Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "DeepSeek", action: #selector(showMain), keyEquivalent: "0")
        NSApp.windowsMenu = window

        let help = sub("Help")
        NSApp.helpMenu = help
        NSApp.mainMenu = bar
    }
}
