import Foundation

/// Runs the model/tool loop for one session.
final class Agent {
    let session: Session
    let jobs = JobManager()
    let depth: Int
    private(set) var tools: [AgentTool] = []
    private var task: Task<Void, Never>?

    /// Subagents route approvals through their parent's tool call.
    weak var parent: Agent?
    var parentCallId: String?
    /// Subagent activity callback (tool summaries).
    var onActivity: ((String) -> Void)?

    private let draftLock = NSLock()
    private var pendingDraft: StreamDraft?
    private var flushScheduled = false
    private var pendingNotices: [String] = []

    init(session: Session, depth: Int = 0) {
        self.session = session
        self.depth = depth
        session.agent = self
        tools = ToolRegistry.tools(depth: depth)
        jobs.onFinish = { [weak self] job in
            guard let self else { return }
            let text = "<background-job-finished id=\"\(job.id)\" kind=\"\(job.kind.rawValue)\" status=\"\(job.state.rawValue)\">\(job.label)</background-job-finished>\nCollect it with job_output if still relevant."
            DispatchQueue.main.async { self.deliverNotice(text) }
        }
    }

    deinit { jobs.killAll() }

    var isRunning: Bool { session.isRunning }

    // MARK: Control (main thread)

    /// Starts a turn with the user's text, or queues it for the running turn.
    func submit(_ text: String, images: [ContentBlock.ImageData] = []) {
        if session.isRunning {
            session.queuedInputs.append(text)
            session.metaChanged()
            return
        }
        var blocks: [ContentBlock] = images.map { .image($0) }
        blocks.append(.text(text))
        start(with: Message(role: .user, blocks: blocks))
    }

    private func deliverNotice(_ text: String) {
        if session.isRunning {
            pendingNotices.append(text)
        } else if depth == 0 {
            start(with: Message(role: .user, blocks: [.text(text)], notice: true))
        }
    }

    private func start(with message: Message) {
        session.repairDanglingToolCalls()
        session.append(message)
        let firstHuman = message.notice != true && !session.hasTitle
        if !session.ephemeral {
            if firstHuman {
                let fallback = message.text.split(separator: "\n").first.map { String($0.prefix(50)) } ?? "New Session"
                session.setTitle(fallback)
            }
            SessionStore.shared.register(session)
        }
        if firstHuman && !session.ephemeral {
            let s = session
            let text = message.text
            Task.detached {
                if let t = await MessagesClient.shared.title(for: text) {
                    await MainActor.run { s.setTitle(t) }
                }
            }
        }
        let turn = session.beginTurn(messageIndex: session.messages.count - 1)
        session.isRunning = true
        session.lastError = nil
        session.metaChanged()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let end = await self.loop()
            await MainActor.run { self.finishTurn(turn.index, end) }
        }
    }

    private func finishTurn(_ index: Int, _ end: TurnEnd) {
        session.isRunning = false
        session.statusLine = nil
        session.setDraft(nil)
        for a in session.pendingApprovals { a.continuation.resume(returning: .deny) }
        session.pendingApprovals = []
        for q in session.pendingQuestions { q.continuation.resume(returning: nil) }
        session.pendingQuestions = []
        if case .error(let m) = end { session.lastError = m }
        session.endTurn(index, end)
        if !session.ephemeral { SessionStore.shared.sessionMetaChanged(session) }
        task = nil
        // Inputs typed after the model's last step start the next turn.
        if !session.queuedInputs.isEmpty {
            let text = session.queuedInputs.joined(separator: "\n\n")
            session.queuedInputs = []
            submit(text)
        } else if !pendingNotices.isEmpty, end == .completed {
            let text = pendingNotices.joined(separator: "\n\n")
            pendingNotices = []
            start(with: Message(role: .user, blocks: [.text(text)], notice: true))
        }
        NotificationCenter.default.post(name: Agent.turnFinished, object: session)
    }

    static let turnFinished = Notification.Name("AgentTurnFinished")

    func cancel() {
        task?.cancel()
        for a in session.pendingApprovals { a.continuation.resume(returning: .deny) }
        session.pendingApprovals = []
        for q in session.pendingQuestions { q.continuation.resume(returning: nil) }
        session.pendingQuestions = []
        session.metaChanged()
    }

    // MARK: Loop

    /// Runs steps until the model stops calling tools. Returns how the turn ended.
    func loop() async -> TurnEnd {
        dlog("loop start")
        let system = await MainActor.run { SystemPrompt.build(session: session, tools: tools, depth: depth) }
        dlog("system built \(system.count)")
        while true {
            if Task.isCancelled { return .stopped }
            if depth == 0 { await compactIfNeeded() }
            let (messages, model, effort) = await MainActor.run { (session.wireMessages(for: session.model), session.model, session.effort) }
            let request = LLMRequest(model: model, system: system, messages: messages, tools: tools.map { $0.spec },
                                     maxTokens: Settings.shared.maxTokens, effort: effort, sessionId: session.ephemeral ? nil : session.id)
            let started = Date().timeIntervalSince1970
            let messageId = UUID().uuidString
            await MainActor.run { session.draftStartedAt = started; session.draftId = messageId; session.setDraft(StreamDraft()) }

            dlog("step start")
            var draft: StreamDraft
            do {
                draft = try await streamWithRetry(request)
            } catch is CancellationError {
                await savePartialDraft(model: model, started: started, id: messageId)
                return .stopped
            } catch {
                await savePartialDraft(model: model, started: started, id: messageId)
                if Task.isCancelled { return .stopped }
                return .error((error as? LLMError)?.message ?? error.localizedDescription)
            }
            dlog("step streamed blocks=\(draft.blocks.count)")
            let genStart = draft.firstTokenAt ?? started
            let assistant = Message(id: messageId, role: .assistant, blocks: draft.contentBlocks, usage: draft.usage, model: model,
                                    duration: max(0.001, Date().timeIntervalSince1970 - genStart))
            await MainActor.run {
                draftLock.lock(); pendingDraft = nil; draftLock.unlock()
                session.draft = nil
                session.append(assistant)
            }

            let calls = draft.contentBlocks.compactMap { b -> (String, String, String)? in
                if case .toolUse(let id, let name, let input) = b { return (id, name, input) }
                return nil
            }
            if calls.isEmpty {
                if draft.stopReason == "max_tokens" { return .error("The response hit the output token limit.") }
                return .completed
            }
            let results = await runTools(calls, truncated: draft.stopReason == "max_tokens")
            var blocks = results
            let (steer, notices): ([String], [String]) = await MainActor.run {
                let q = session.queuedInputs
                session.queuedInputs = []
                let n = pendingNotices
                pendingNotices = []
                return (q, n)
            }
            for n in notices { blocks.append(.text(n)) }
            for s in steer { blocks.append(.text(s)) }
            let resultMessage = Message(role: .user, blocks: blocks, isToolResults: true, steered: steer.isEmpty ? nil : true)
            await MainActor.run { session.append(resultMessage) }
            if Task.isCancelled { return .stopped }
        }
    }

    /// Summarizes older history once the last prompt approaches the context window.
    private func compactIfNeeded() async {
        let (prompt, msgs, cutIndex, model) = await MainActor.run { () -> (Int, [Message], Int?, String) in
            let window = Settings.shared.contextWindow
            guard session.lastPromptTokens > Int(Double(window) * 0.8) else { return (0, [], nil, "") }
            // Keep the current turn verbatim; summarize everything before it.
            let cut = session.turns.last?.messageIndex
            if let cut, let done = session.compaction?.index, done >= cut { return (0, [], nil, "") }
            return (session.lastPromptTokens, session.wireMessages(for: session.model), cut, session.model)
        }
        guard let cutIndex, cutIndex > 0, prompt > 0 else { return }
        await MainActor.run { session.statusLine = "Compacting context…"; session.metaChanged() }
        var transcript = ""
        let offset = await MainActor.run { session.compaction?.index ?? 0 }
        for m in msgs.prefix(max(0, cutIndex - offset)) {
            for b in m.blocks {
                switch b {
                case .text(let t): transcript += "\n[\(m.role.rawValue)] " + String(t.prefix(8000))
                case .toolUse(_, let name, let input): transcript += "\n[tool call \(name)] " + String(input.prefix(1500))
                case .toolResult(_, let c, let err, _): transcript += "\n[tool result\(err ? " error" : "")] " + String(c.prefix(1500))
                default: break
                }
            }
        }
        let body: JSON = [
            "model": .string(model), "max_tokens": 8000, "stream": false, "thinking": ["type": "disabled"],
            "messages": [["role": "user", "content": [["type": "text", "text": .string("Summarize this coding-agent conversation so work can continue without it. Keep: the user's goals and constraints, decisions made, files created or changed (with paths), commands and their important results, open problems, and next steps. Be specific and concise.\n\n" + String(transcript.suffix(600_000)))]]]],
        ]
        if let j = try? await MessagesClient.shared.complete(body: body, sessionId: session.id) {
            let summary = (j["content"]?.array ?? []).compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined()
            if !summary.isEmpty { await MainActor.run { session.setCompaction(index: cutIndex, summary: summary) } }
        }
        await MainActor.run { session.statusLine = nil; session.metaChanged() }
    }

    private func streamWithRetry(_ request: LLMRequest) async throws -> StreamDraft {
        var attempt = 0
        while true {
            do {
                let d = try await MessagesClient.shared.stream(request) { [weak self] d in self?.pushDraft(d) }
                await MainActor.run { if session.statusLine != nil { session.statusLine = nil; session.metaChanged() } }
                return d
            } catch let e as LLMError where e.retryable && attempt < 6 {
                attempt += 1
                let delay = min(e.retryAfter ?? pow(2, Double(attempt - 1)) * 1.5, 60)
                let n = attempt
                await MainActor.run {
                    session.statusLine = "Retrying in \(Int(delay))s (attempt \(n) of 6): \(e.message)"
                    session.setDraft(StreamDraft())
                }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Coalesces streaming updates to at most 20 UI refreshes per second.
    private func pushDraft(_ d: StreamDraft) {
        draftLock.lock()
        pendingDraft = d
        let schedule = !flushScheduled
        flushScheduled = true
        draftLock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.draftLock.lock()
            let d = self.pendingDraft
            self.flushScheduled = false
            self.draftLock.unlock()
            if let d, self.session.isRunning { self.session.setDraft(d) }
        }
    }

    private func savePartialDraft(model: String, started: Double, id: String) async {
        await MainActor.run {
            draftLock.lock(); let d = pendingDraft; pendingDraft = nil; draftLock.unlock()
            session.draft = nil
            guard let d else { session.setDraft(nil); return }
            let blocks = d.contentBlocks.filter {
                switch $0 {
                case .toolUse: return false
                case .text(let t): return !t.isEmpty
                case .thinking(let t, _): return !t.isEmpty
                default: return true
                }
            }.map { b -> ContentBlock in
                // A partial thinking block has no valid signature.
                if case .thinking(let t, _) = b { return .thinking(text: t, signature: nil) }
                return b
            }
            if blocks.isEmpty { session.setDraft(nil); return }
            session.append(Message(id: id, role: .assistant, blocks: blocks, usage: d.usage, model: model,
                                   duration: Date().timeIntervalSince1970 - started))
        }
    }

    // MARK: Tools

    private func runTools(_ calls: [(String, String, String)], truncated: Bool) async -> [ContentBlock] {
        var results = [ContentBlock?](repeating: nil, count: calls.count)
        await MainActor.run {
            for (id, _, _) in calls { session.setToolRun(id, ToolRun(status: .pending), persistNow: false) }
        }
        var i = 0
        while i < calls.count {
            if Task.isCancelled { break }
            let tool = tools.first { $0.name == calls[i].1 }
            if let tool, tool.concurrencySafe {
                var j = i
                while j < calls.count, let t = tools.first(where: { $0.name == calls[j].1 }), t.concurrencySafe { j += 1 }
                let range = i..<j
                await withTaskGroup(of: (Int, ContentBlock).self) { group in
                    for k in range {
                        group.addTask { (k, await self.execute(calls[k], truncated: truncated)) }
                    }
                    for await (k, r) in group { results[k] = r }
                }
                i = j
            } else {
                results[i] = await execute(calls[i], truncated: truncated)
                i += 1
            }
        }
        var out: [ContentBlock] = []
        for (k, c) in calls.enumerated() {
            if let r = results[k] { out.append(r); continue }
            await MainActor.run { session.setToolRun(c.0, ToolRun(status: .cancelled, finishedAt: Date().timeIntervalSince1970, output: "Cancelled")) }
            out.append(.toolResult(id: c.0, content: "The user interrupted this tool call before it ran.", isError: true, images: nil))
        }
        return out
    }

    private func execute(_ call: (String, String, String), truncated: Bool) async -> ContentBlock {
        let (id, name, raw) = call
        let started = Date().timeIntervalSince1970
        await MainActor.run { session.setToolRun(id, ToolRun(status: .running, startedAt: started), persistNow: false) }
        if let onActivity {
            onActivity(ToolPresentation.activityLine(name: name, input: JSON.parse(raw) ?? .object([:])))
        }
        var result: ToolResult
        if let tool = tools.first(where: { $0.name == name }) {
            if let input = JSON.parse(raw), input.object != nil {
                let ctx = ToolContext(agent: self, callId: id, cwd: session.cwd)
                result = await tool.run(input, ctx)
            } else {
                result = .error(truncated
                    ? "The tool input was truncated because the response hit the output token limit. Retry with smaller input (e.g. split a large write into several edits)."
                    : "Invalid JSON tool input.")
            }
        } else {
            result = .error("Unknown tool: \(name)")
        }
        if Task.isCancelled && !result.isError { result.text += "\n[the user interrupted the turn after this call]" }
        let final = result
        await MainActor.run {
            var run = session.toolRuns[id] ?? ToolRun(status: .running, startedAt: started)
            if run.status != .denied { run.status = final.isError ? .error : .done }
            run.finishedAt = Date().timeIntervalSince1970
            run.output = String(final.text.prefix(200_000))
            run.progress = nil
            if let m = final.meta { run.meta = m }
            session.setToolRun(id, run)
        }
        return .toolResult(id: id, content: final.text, isError: final.isError, images: final.images)
    }

    // MARK: Interaction

    func requestApproval(callId: String, title: String, detail: String, key: String) async -> Bool {
        if let parent, let pid = parentCallId {
            return await parent.requestApproval(callId: pid, title: title, detail: detail, key: key)
        }
        if session.permission == .fullAccess { return true }
        if await MainActor.run(body: { session.sessionApprovals.contains(key) }) { return true }
        if Task.isCancelled { return false }
        let decision: ApprovalDecision = await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                guard self.session.isRunning else { cont.resume(returning: .deny); return }
                if var r = self.session.toolRuns[callId] { r.status = .awaitingApproval; self.session.setToolRun(callId, r, persistNow: false) }
                self.session.pendingApprovals.append(ApprovalRequest(callId: callId, title: title, detail: detail, continuation: cont))
                self.session.metaChanged()
                NotificationCenter.default.post(name: Agent.attentionNeeded, object: self.session)
            }
        }
        await MainActor.run {
            if decision == .allowSession { session.sessionApprovals.insert(key) }
            if var r = session.toolRuns[callId] {
                r.status = decision == .deny ? .denied : .running
                session.setToolRun(callId, r, persistNow: false)
            }
        }
        return decision != .deny
    }

    static let attentionNeeded = Notification.Name("AgentAttentionNeeded")

    /// Main thread: resolves a pending approval from the UI.
    func resolveApproval(_ id: String, _ decision: ApprovalDecision) {
        guard let i = session.pendingApprovals.firstIndex(where: { $0.id == id }) else { return }
        let a = session.pendingApprovals.remove(at: i)
        a.continuation.resume(returning: decision)
        session.metaChanged()
    }

    func askUser(callId: String, questions: [QuestionRequest.Question]) async -> [String: [String]]? {
        if let parent, let pid = parentCallId { return await parent.askUser(callId: pid, questions: questions) }
        return await withCheckedContinuation { cont in
            DispatchQueue.main.async {
                guard self.session.isRunning else { cont.resume(returning: nil); return }
                self.session.pendingQuestions.append(QuestionRequest(callId: callId, questions: questions, continuation: cont))
                self.session.metaChanged()
                NotificationCenter.default.post(name: Agent.attentionNeeded, object: self.session)
            }
        }
    }

    func resolveQuestion(_ id: String, _ answers: [String: [String]]?) {
        guard let i = session.pendingQuestions.firstIndex(where: { $0.id == id }) else { return }
        let q = session.pendingQuestions.remove(at: i)
        q.continuation.resume(returning: answers)
        session.metaChanged()
    }
}

// Agent and Session mutate UI-visible state only on the main thread; background work hops via MainActor.run.
extension Agent: @unchecked Sendable {}
extension Session: @unchecked Sendable {}
extension ToolContext: @unchecked Sendable {}
extension ChildProcess: @unchecked Sendable {}
extension JobManager: @unchecked Sendable {}
