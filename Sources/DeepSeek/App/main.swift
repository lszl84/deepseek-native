import AppKit

let args = CommandLine.arguments
if let i = args.firstIndex(of: "--headless"), i + 1 < args.count {
    Headless.run(prompt: args[i + 1], cwd: args.firstIndex(of: "--cwd").map { args[$0 + 1] } ?? FileManager.default.currentDirectoryPath)
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}

/// Terminal driver used for testing the agent without the GUI.
enum Headless {
    static func run(prompt: String, cwd: String) {
        setvbuf(stdout, nil, _IOLBF, 0)
        ShellEnvironment.warmUp()
        let session = Session(cwd: cwd)
        session.ephemeral = true
        session.permission = .workspaceWrite
        let agent = Agent(session: session)
        var printedTools = Set<String>()
        NotificationCenter.default.addObserver(forName: Session.changed, object: session, queue: nil) { note in
            guard let change = note.userInfo?["change"] as? Session.Change else { return }
            if case .tool(let id) = change, let run = session.toolRuns[id], run.status == .done || run.status == .error, !printedTools.contains(id) {
                printedTools.insert(id)
                let call = session.messages.last?.blocks.compactMap { b -> (String, String)? in
                    if case .toolUse(let cid, let n, let inp) = b, cid == id { return (n, inp) }; return nil
                }.first
                print("  ⏺ \(call?.0 ?? "?") \(call?.1.prefix(160) ?? "") → \(run.status.rawValue): \((run.output ?? "").prefix(300).replacingOccurrences(of: "\n", with: "⏎"))")
            }
        }
        NotificationCenter.default.addObserver(forName: Agent.attentionNeeded, object: session, queue: nil) { _ in
            for a in session.pendingApprovals { print("  [auto-approve] \(a.title)"); agent.resolveApproval(a.id, .allowOnce) }
            for q in session.pendingQuestions {
                var ans: [String: [String]] = [:]
                for qq in q.questions { ans[qq.id] = [qq.options.first?.label ?? "yes"] }
                agent.resolveQuestion(q.id, ans)
            }
        }
        NotificationCenter.default.addObserver(forName: Agent.turnFinished, object: session, queue: nil) { _ in
            for m in session.messages where m.role == .assistant {
                for b in m.blocks {
                    switch b {
                    case .thinking(let t, _): print("💭 " + t.prefix(200).replacingOccurrences(of: "\n", with: " "))
                    case .text(let t): print("🤖 " + t)
                    default: break
                    }
                }
            }
            let u = session.totalUsage
            print("— turn end: \(session.turns.last?.end.map { "\($0)" } ?? "?") · steps \(session.stepCount) · in \(u.input) cacheRead \(u.cacheRead) out \(u.output)")
            exit(0)
        }
        DispatchQueue.main.async { agent.submit(prompt) }
        if let c = ProcessInfo.processInfo.environment["DSN_CANCEL_AFTER"].flatMap(Double.init) {
            DispatchQueue.main.asyncAfter(deadline: .now() + c) { print("  [cancel]"); agent.cancel() }
        }
        dispatchMain()
    }
}
