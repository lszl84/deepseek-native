import AppKit

/// Test automation driven by environment variables (no effect in normal use):
/// DSN_WORKSPACE=<dir>  start a new session in that workspace
/// DSN_AUTOSEND=<text>  send a prompt once the window is up
/// DSN_SNAPSHOT=<path>  write window snapshots to <path>-N.png every DSN_SNAPSHOT_INTERVAL seconds (default 5)
/// DSN_OPEN=<session-id> open that session
enum DebugHooks {
    static func run(_ main: MainWindowController) {
        let env = ProcessInfo.processInfo.environment
        if let a = env["DSN_APPEARANCE"] { NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }
        if let id = env["DSN_OPEN"] {
            main.openSession(id)
            if env["DSN_EXPAND_ALL"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { main.chat.debugExpandAll() } }
            if let y = env["DSN_SCROLL"].flatMap(Double.init) { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { main.chat.debugScroll(to: CGFloat(y)) } }
        }
        if let p = env["DSN_PERMISSION"], let mode = PermissionMode(rawValue: p) { Settings.shared.permissionMode = mode }
        if let ws = env["DSN_WORKSPACE"] {
            let w = SessionStore.shared.addWorkspace(path: ws)
            SessionStore.shared.lastWorkspaceId = w.id
            main.newSession(in: w.path)
        }
        if let text = env["DSN_AUTOSEND"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                main.chat.composerSend(text, images: [])
            }
        }
        if let d = env["DSN_AUTOANSWER"].flatMap(Double.init) {
            NotificationCenter.default.addObserver(forName: Agent.attentionNeeded, object: nil, queue: .main) { n in
                guard let s = n.object as? Session else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                    for a in s.pendingApprovals { s.agent?.resolveApproval(a.id, .allowOnce) }
                    for q in s.pendingQuestions {
                        var ans: [String: [String]] = [:]
                        for qq in q.questions { ans[qq.id] = [qq.options.dropFirst().first?.label ?? qq.options.first?.label ?? "yes"] }
                        s.agent?.resolveQuestion(q.id, ans)
                    }
                }
            }
        }
        if let path = env["DSN_SNAPSHOT_SETTINGS"] {
            SettingsWindowController.shared.showWindow(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { snapshot(SettingsWindowController.shared.window, to: path) }
        }
        if env["DSN_NEW"] != nil { main.newSession(in: nil) }
        if env["DSN_PROBE"] != nil {
            for t in [0.5, 2.0, 5.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    guard let w = main.window, let root = w.contentView else { return }
                    FileHandle.standardError.write(Data("[probe \(t)s] key=\(w.isKeyWindow) firstResponder=\(String(describing: w.firstResponder))\n".utf8))
                    if let comp = main.chat.debugComposer {
                        let c = comp.convert(NSPoint(x: comp.bounds.midX, y: comp.bounds.maxY - 30), to: nil)
                        let hit = root.superview?.hitTest(c) ?? root.hitTest(root.convert(c, from: nil))
                        FileHandle.standardError.write(Data("  composer frame=\(comp.frame) text frame=\(comp.textView.frame) hit=\(String(describing: hit))\n".utf8))
                        var v: NSView? = hit
                        var chain = ""
                        while let x = v { chain += " < \(type(of: x))"; v = x.superview }
                        FileHandle.standardError.write(Data("  chain:\(chain)\n".utf8))
                    }
                }
            }
        }
        if let t = env["DSN_COMPOSE"] { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { main.chat.insertIntoComposer(t) } }
        if let path = env["DSN_SNAPSHOT"] {
            let interval = Double(env["DSN_SNAPSHOT_INTERVAL"] ?? "5") ?? 5
            var n = 0
            Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                n += 1
                snapshot(main.window, to: "\(path)-\(n).png")
                for (k, w) in NSApp.windows.enumerated() where w.isVisible && w !== main.window {
                    snapshot(w, to: "\(path)-\(n)-w\(k).png")
                }
            }
        }
    }

    static func snapshot(_ window: NSWindow?, to path: String) {
        guard let window, let view = window.contentView?.superview ?? window.contentView else { return }
        // Prefer the window server image (includes glass); fall back to view caching.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", path]
        if (try? p.run()) != nil {
            p.waitUntilExit()
            if p.terminationStatus == 0, FileManager.default.fileExists(atPath: path) { return }
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let data = rep.representation(using: .png, properties: [:]) { try? data.write(to: URL(fileURLWithPath: path)) }
    }
}

let debugLogging = ProcessInfo.processInfo.environment["DSN_DEBUG"] != nil
func dlog(_ s: @autoclosure () -> String) {
    if debugLogging { FileHandle.standardError.write(Data(("[dsn] " + s() + "\n").utf8)) }
}
