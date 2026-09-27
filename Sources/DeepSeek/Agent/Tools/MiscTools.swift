import Foundation

struct TodoWriteTool: AgentTool {
    let name = "todo_write"
    let description = "Record and update a task list to plan multi-step work and show progress; skip it for trivial single-step tasks. Add one todo per concrete step before you start. While work remains, keep the todos being worked on `in_progress`, several only when work runs in parallel. Mark each todo `completed` as soon as it is done."
    let schema = DeepSeek.schema("""
    {"type":"object","properties":{"todos":{"type":"array","description":"The COMPLETE task list, replacing any previous list.","items":{"type":"object","additionalProperties":false,"properties":{"content":{"type":"string","description":"What the task is — a short imperative line."},"status":{"type":"string","description":"pending (not started) | in_progress (now) | completed (done).","enum":["pending","in_progress","completed"]}},"required":["content","status"]}}},"required":["todos"]}
    """)

    func run(_ input: JSON, _ ctx: ToolContext) async -> ToolResult {
        guard let arr = input["todos"]?.array else { return .error("todos must be an array") }
        let todos = arr.compactMap { t -> TodoItem? in
            guard let c = t["content"]?.string else { return nil }
            let s = t["status"]?.string ?? "pending"
            return TodoItem(content: c, status: ["pending", "in_progress", "completed"].contains(s) ? s : "pending")
        }
        let previous = await MainActor.run { () -> [TodoItem] in
            let p = ctx.session.todos
            ctx.session.setTodos(todos)
            return p
        }
        let done = todos.filter { $0.status == "completed" }.count
        let added = todos.filter { t in !previous.contains { $0.content == t.content } }.count
        return ToolResult(text: "Todo list updated: \(done)/\(todos.count) completed.",
                          meta: ["done": .number(Double(done)), "total": .number(Double(todos.count)), "added": .number(Double(added))])
    }
}

struct AskUserTool: AgentTool {
    let name = "ask_user_question"
    let description = "Ask the user a concise question when you need confirmation, a choice, or missing information before proceeding."
    let schema = DeepSeek.schema("""
    {"type":"object","properties":{"questions":{"type":"array","description":"Questions to ask the user before continuing.","items":{"type":"object","additionalProperties":true,"properties":{"id":{"type":"string","description":"Stable id for this question; echoed in the answer."},"question":{"type":"string","description":"The specific question to ask the user."},"header":{"type":"string","description":"Optional short heading for the question, such as \\"Confirm\\" or \\"Choose Mode\\"."},"options":{"type":"array","description":"Optional choices to show the user. If you recommend one, put it first and append \\"(Recommended)\\" to that label.","items":{"type":"object","additionalProperties":true,"properties":{"label":{"type":"string","description":"Short user-facing option label."},"description":{"type":"string","description":"One sentence explaining the tradeoff or impact."}},"required":["label"]}},"multi_select":{"type":"boolean","description":"Whether the user may select more than one option. Defaults to false."}},"required":["id","question"]}}},"required":["questions"]}
    """)

    func run(_ input: JSON, _ ctx: ToolContext) async -> ToolResult {
        let qs = (input["questions"]?.array ?? []).enumerated().compactMap { (i, q) -> QuestionRequest.Question? in
            guard let text = q["question"]?.string else { return nil }
            let opts = (q["options"]?.array ?? []).compactMap { o -> (String, String?)? in
                guard let l = o["label"]?.string else { return nil }
                return (l, o["description"]?.string)
            }
            return QuestionRequest.Question(id: q["id"]?.string ?? "q\(i + 1)", header: q["header"]?.string, question: text,
                                            options: opts.map { (label: $0.0, description: $0.1) }, multiSelect: q["multi_select"]?.bool ?? false)
        }
        guard !qs.isEmpty else { return .error("questions must contain at least one question") }
        guard let answers = await ctx.agent.askUser(callId: ctx.callId, questions: qs) else {
            return .error("The user dismissed the question without answering.")
        }
        var lines: [String] = []
        var meta: [String: JSON] = [:]
        for q in qs {
            let a = answers[q.id] ?? []
            lines.append("\(q.id): \(q.question)\nAnswer: \(a.isEmpty ? "(no answer)" : a.joined(separator: ", "))")
            meta[q.id] = .array(a.map { .string($0) })
        }
        return ToolResult(text: lines.joined(separator: "\n\n"), meta: ["answers": .object(meta)])
    }
}

struct PresentTool: AgentTool {
    let name = "present"
    let description = "Declare existing files as final deliverables for the user. Use it when the user needs a separate file, especially Office documents, spreadsheets, and slide decks; prefer your final response when that suffices. The user opens the current files; their contents are not copied."
    let schema = DeepSeek.schema("""
    {"type":"object","properties":{"files":{"type":"array","description":"Usually the 1-2 most important deliverables; at most 4 per call.","items":{"type":"object","additionalProperties":false,"properties":{"path":{"type":"string","description":"Path of an existing regular file. Relative paths use the Session working directory."},"description":{"type":"string","description":"Brief description for the user."}},"required":["path"]}}},"required":["files"]}
    """)

    func run(_ input: JSON, _ ctx: ToolContext) async -> ToolResult {
        var files: [JSON] = []
        var missing: [String] = []
        for f in (input["files"]?.array ?? []).prefix(4) {
            let p = ctx.resolve(f["path"]?.string)
            var d: ObjCBool = false
            if FileManager.default.fileExists(atPath: p, isDirectory: &d), !d.boolValue {
                files.append(["path": .string(p), "description": .string(f["description"]?.string ?? "")])
            } else { missing.append(p) }
        }
        if files.isEmpty { return .error("No existing regular files to present: \(missing.joined(separator: ", "))") }
        var text = "Presented \(files.count) file(s) to the user."
        if !missing.isEmpty { text += " Missing: \(missing.joined(separator: ", "))" }
        return ToolResult(text: text, meta: ["files": .array(files)])
    }
}

struct JobListTool: AgentTool {
    let name = "job_list"
    let description = "List your background jobs (running and finished) with their ids, kinds, and statuses."
    let schema = DeepSeek.schema(#"{"type":"object","properties":{}}"#)
    var concurrencySafe: Bool { true }
    func run(_ input: JSON, _ ctx: ToolContext) async -> ToolResult { ToolResult(text: ctx.jobs.list()) }
}

struct JobOutputTool: AgentTool {
    let name = "job_output"
    let description = "Read a background job: output since the previous read for stream jobs, or the result of a finished final-output job."
    let schema = DeepSeek.schema("""
    {"type":"object","properties":{"job_id":{"type":"string","description":"Job id returned by the tool that started the background work."},"wait":{"type":"boolean","description":"Block until the job finishes or the timeout expires; a timed-out wait leaves the job running. Defaults to false."},"timeout_ms":{"type":"number","description":"Max wait in milliseconds with wait: true. Defaults to and is capped by configuration."}},"required":["job_id"]}
    """)
    var concurrencySafe: Bool { true }
    func run(_ input: JSON, _ ctx: ToolContext) async -> ToolResult {
        guard let id = input["job_id"]?.string else { return .error("job_id is required") }
        let (text, ok) = await ctx.jobs.output(id, wait: input["wait"]?.bool ?? false, timeoutMs: input["timeout_ms"]?.int)
        return ToolResult(text: text, isError: !ok)
    }
}

struct JobKillTool: AgentTool {
    let name = "job_kill"
    let description = "Request cancellation of a running background job."
    let schema = DeepSeek.schema("""
    {"type":"object","properties":{"job_id":{"type":"string","description":"Job id returned by the tool that started the background work."},"reason":{"type":"string","description":"Optional short reason, recorded in the log and forwarded to the job."}},"required":["job_id"]}
    """)
    func run(_ input: JSON, _ ctx: ToolContext) async -> ToolResult {
        guard let id = input["job_id"]?.string else { return .error("job_id is required") }
        return ToolResult(text: ctx.jobs.kill(id))
    }
}

struct SubagentTool: AgentTool {
    let name = "subagent"
    let description = "Delegate a self-contained task to a subagent (a separate agent that works in its own context) to offload focused, independent work — research, a scoped implementation, an analysis — so it does not consume this conversation's context. The subagent returns its result, not its intermediate steps. This call waits for the result by default."
    let schema = DeepSeek.schema("""
    {"type":"object","properties":{"description":{"type":"string","description":"A short (3-5 word) description of the delegated task, for display."},"prompt":{"type":"string","description":"The complete, self-contained task for the subagent. It does not share this conversation's context, so include everything it needs."},"run_in_background":{"type":"boolean","description":"Run as a background job and return its id (collect with job_output, stop with job_kill). Defaults to false."}},"required":["description","prompt"]}
    """)
    var concurrencySafe: Bool { true }

    func run(_ input: JSON, _ ctx: ToolContext) async -> ToolResult {
        guard let prompt = input["prompt"]?.string, !prompt.isEmpty else { return .error("prompt is required") }
        let label = input["description"]?.string ?? "Subagent task"
        let parent = ctx.agent
        let callId = ctx.callId
        let body: () async -> (String, Bool) = {
            let child: Agent = await MainActor.run {
                let s = Session(cwd: parent.session.cwd)
                s.ephemeral = true
                s.model = parent.session.model
                s.effort = parent.session.effort
                s.permission = parent.session.permission
                let a = Agent(session: s, depth: parent.depth + 1)
                a.parent = parent
                a.parentCallId = callId
                var steps = 0
                a.onActivity = { line in
                    steps += 1
                    ctx.progress("Step \(steps): \(line)")
                }
                s.append(Message(role: .user, blocks: [.text(prompt)]))
                s.isRunning = true
                return a
            }
            let end = await child.loop()
            return await MainActor.run {
                child.session.isRunning = false
                child.jobs.killAll()
                defer { child.session.agent = nil }
                let final = child.session.messages.last(where: { $0.role == .assistant })?.text ?? ""
                let steps = child.session.stepCount
                let usage = child.session.totalUsage
                ctx.setMeta(["steps": .number(Double(steps)), "tokens": .number(Double(usage.total))])
                switch end {
                case .completed: return (final.isEmpty ? "(the subagent returned no text)" : final, true)
                case .stopped: return ("The subagent was interrupted. Partial result:\n" + final, false)
                case .error(let m): return ("The subagent failed: \(m)\n" + final, false)
                }
            }
        }
        if input["run_in_background"]?.bool == true {
            let job = ctx.jobs.start(kind: .subagent, label: label, body: body)
            return ToolResult(text: "Started subagent as background job \(job.id). Collect its result with job_output.", meta: ["job": .string(job.id)])
        }
        let (text, ok) = await withTaskCancellationHandler {
            await body()
        } onCancel: {}
        return ToolResult(text: text, isError: !ok)
    }
}

enum ToolRegistry {
    static func tools(depth: Int) -> [AgentTool] {
        var t: [AgentTool] = [
            BashTool(), ReadTool(), WriteTool(), EditTool(), ReadImageTool(), GlobTool(), GrepTool(),
            TodoWriteTool(), WebFetchTool(),
            JobListTool(), JobOutputTool(), JobKillTool(),
        ]
        if Settings.shared.webSearchEnabled { t.append(WebSearchTool()) }
        if depth == 0 {
            t.append(AskUserTool())
            t.append(PresentTool())
            if Settings.shared.subagentsEnabled { t.append(SubagentTool()) }
        }
        return t.sorted { $0.name < $1.name }
    }
}
