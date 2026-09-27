import Foundation

/// Durable session log entry; one JSON object per line.
enum SessionEvent: Codable {
    case header(id: String, cwd: String, createdAt: Double)
    case message(Message)
    case toolRun(id: String, run: ToolRun)
    case turnStart(TurnRecord)
    case turnEnd(index: Int, endedAt: Double, end: TurnEnd)
    case title(String)
    case todos([TodoItem])
    case observed(path: String)
    case compaction(index: Int, summary: String)
    case config(model: String, effort: ReasoningEffort, permission: PermissionMode)
}

struct ApprovalRequest {
    let id = UUID().uuidString
    let callId: String
    let title: String
    let detail: String
    let continuation: CheckedContinuation<ApprovalDecision, Never>
}

enum ApprovalDecision { case allowOnce, allowSession, deny }

struct QuestionRequest {
    let id = UUID().uuidString
    let callId: String
    let questions: [Question]
    let continuation: CheckedContinuation<[String: [String]]?, Never>

    struct Question {
        let id: String
        let header: String?
        let question: String
        let options: [(label: String, description: String?)]
        let multiSelect: Bool
    }
}

/// A conversation with its runtime state. Accessed on the main thread only.
final class Session {
    enum Change {
        case reset          // messages list structurally changed
        case draft          // streaming assistant draft changed
        case tool(String)   // tool run state changed
        case meta           // title, running state, usage, todos, approvals
    }
    static let changed = Notification.Name("SessionChanged")

    let id: String
    private(set) var cwd: String
    private(set) var createdAt: Double
    private(set) var title: String = "New Session"
    private(set) var hasTitle = false
    var updatedAt: Double

    private(set) var messages: [Message] = []
    private(set) var toolRuns: [String: ToolRun] = [:]
    private(set) var turns: [TurnRecord] = []
    private(set) var todos: [TodoItem] = []
    private(set) var observedFiles: Set<String> = []
    /// Messages before `index` are replaced on the wire by `summary`.
    private(set) var compaction: (index: Int, summary: String)?
    var model: String
    var effort: ReasoningEffort
    var permission: PermissionMode

    // Runtime only
    var draft: StreamDraft?
    /// Message id the current draft will be committed under.
    var draftId: String?
    var draftStartedAt: Double?
    var isRunning = false
    var statusLine: String?
    var pendingApprovals: [ApprovalRequest] = []
    var pendingQuestions: [QuestionRequest] = []
    var queuedInputs: [String] = []
    var sessionApprovals: Set<String> = []
    var lastError: String?
    /// Strong: the session owns its agent (the agent's own reference back is also strong; `unload` breaks it).
    var agent: Agent?

    private let fileURL: URL
    private var handle: FileHandle?
    private let ioQueue = DispatchQueue(label: "session.io", qos: .utility)
    private var loaded = false

    var fileSize: Int { (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0 }

    init(id: String = "session-" + UUID().uuidString.lowercased(), cwd: String) {
        self.id = id
        self.cwd = cwd
        self.createdAt = Date().timeIntervalSince1970
        self.updatedAt = createdAt
        self.model = Settings.shared.model
        self.effort = Settings.shared.effort
        self.permission = Settings.shared.permissionMode
        self.fileURL = Paths.sessions.appendingPathComponent(id + ".jsonl")
        self.loaded = true
    }

    /// Opens an existing session file lazily; `load()` parses it.
    init(existingId id: String, cwd: String, title: String, updatedAt: Double, createdAt: Double) {
        self.id = id
        self.cwd = cwd
        self.title = title
        self.hasTitle = true
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.model = Settings.shared.model
        self.effort = Settings.shared.effort
        self.permission = Settings.shared.permissionMode
        self.fileURL = Paths.sessions.appendingPathComponent(id + ".jsonl")
    }

    var isLoaded: Bool { loaded }

    func load() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            if end > start, let ev = try? dec.decode(SessionEvent.self, from: data[start..<end]) {
                apply(ev)
            }
            start = end < data.endIndex ? data.index(after: end) : end
        }
        // A turn left open by a crash or quit is marked stopped.
        if let last = turns.last, last.end == nil {
            turns[turns.count - 1].end = .stopped
            turns[turns.count - 1].endedAt = last.startedAt
        }
        for (k, r) in toolRuns where r.status == .running || r.status == .pending || r.status == .awaitingApproval {
            toolRuns[k]?.status = .cancelled
        }
        repairDanglingToolCalls(persist: false)
    }

    /// Releases transcript memory for sessions that are not visible and idle.
    func unload() {
        guard loaded, !isRunning else { return }
        agent?.jobs.killAll()
        agent = nil
        messages = []
        toolRuns = [:]
        turns = []
        todos = []
        observedFiles = []
        compaction = nil
        loaded = false
        try? handle?.close()
        handle = nil
    }

    private func apply(_ ev: SessionEvent) {
        switch ev {
        case .header(_, let cwd, let createdAt): self.cwd = cwd; self.createdAt = createdAt
        case .message(let m): messages.append(m)
        case .toolRun(let id, let run): toolRuns[id] = run
        case .turnStart(let t): turns.append(t)
        case .turnEnd(let index, let endedAt, let end):
            if let i = turns.lastIndex(where: { $0.index == index }) { turns[i].endedAt = endedAt; turns[i].end = end }
        case .title(let t): title = t; hasTitle = true
        case .todos(let t): todos = t
        case .observed(let p): observedFiles.insert(p)
        case .compaction(let i, let sum): compaction = (i, sum)
        case .config(let m, let e, let p): model = m; effort = e; permission = p
        }
    }

    /// In-memory sessions (subagents) are never written to disk.
    var ephemeral = false

    private func persist(_ ev: SessionEvent) {
        guard !ephemeral, var data = try? JSONEncoder().encode(ev) else { return }
        data.append(0x0A)
        let url = fileURL
        let isNew = !FileManager.default.fileExists(atPath: url.path)
        let header: Data? = isNew ? (try? JSONEncoder().encode(SessionEvent.header(id: id, cwd: cwd, createdAt: createdAt))).map { $0 + Data([0x0A]) } : nil
        ioQueue.async { [weak self] in
            guard let self else { return }
            if self.handle == nil {
                if !FileManager.default.fileExists(atPath: url.path) {
                    FileManager.default.createFile(atPath: url.path, contents: header ?? Data(), attributes: [.posixPermissions: 0o600])
                }
                self.handle = try? FileHandle(forWritingTo: url)
                _ = try? self.handle?.seekToEnd()
            }
            try? self.handle?.write(contentsOf: data)
        }
    }

    private func notify(_ change: Change) {
        NotificationCenter.default.post(name: Session.changed, object: self, userInfo: ["change": change])
    }

    // MARK: Mutations

    func append(_ message: Message) {
        messages.append(message)
        updatedAt = Date().timeIntervalSince1970
        persist(.message(message))
        notify(.reset)
    }

    func setToolRun(_ id: String, _ run: ToolRun, persistNow: Bool = true) {
        toolRuns[id] = run
        if persistNow { persist(.toolRun(id: id, run: run)) }
        notify(.tool(id))
    }

    func updateToolProgress(_ id: String, _ progress: String) {
        toolRuns[id]?.progress = progress
        notify(.tool(id))
    }

    func beginTurn(messageIndex: Int) -> TurnRecord {
        let t = TurnRecord(index: (turns.last?.index ?? 0) + 1, startedAt: Date().timeIntervalSince1970, endedAt: nil, end: nil, messageIndex: messageIndex)
        turns.append(t)
        persist(.turnStart(t))
        notify(.meta)
        return t
    }

    func endTurn(_ index: Int, _ end: TurnEnd) {
        let now = Date().timeIntervalSince1970
        if let i = turns.lastIndex(where: { $0.index == index }) { turns[i].endedAt = now; turns[i].end = end }
        persist(.turnEnd(index: index, endedAt: now, end: end))
        notify(.reset)
    }

    func setTitle(_ t: String) {
        title = t
        hasTitle = true
        persist(.title(t))
        notify(.meta)
        SessionStore.shared.sessionMetaChanged(self)
    }

    func setTodos(_ t: [TodoItem]) {
        todos = t
        persist(.todos(t))
        notify(.meta)
    }

    func markObserved(_ path: String) {
        guard !observedFiles.contains(path) else { return }
        observedFiles.insert(path)
        persist(.observed(path: path))
    }

    func setCompaction(index: Int, summary: String) {
        compaction = (index, summary)
        persist(.compaction(index: index, summary: summary))
        notify(.meta)
    }

    /// History sent to the model: compacted prefix replaced by its summary, and thinking blocks
    /// that cannot be replayed (unsigned, or produced by another model) removed.
    func wireMessages(for model: String) -> [Message] {
        var msgs = messages
        if let c = compaction, c.index < msgs.count, c.index >= 0 {
            msgs = Array(msgs[c.index...])
            if let first = msgs.first, first.role == .user {
                msgs[0].blocks.insert(.text("<conversation-summary>\nThe earlier part of this conversation was compacted. Summary:\n\n\(c.summary)\n</conversation-summary>"), at: 0)
            }
        }
        return msgs.map { m in
            guard m.role == .assistant else { return m }
            var m = m
            let sameModel = m.model == nil || m.model == model
            m.blocks = m.blocks.filter {
                if case .thinking(_, let sig) = $0 { return sameModel && (sig?.isEmpty == false) }
                return true
            }
            if m.blocks.isEmpty { m.blocks = [.text("(no content)")] }
            return m
        }
    }

    func saveConfig() {
        persist(.config(model: model, effort: effort, permission: permission))
        notify(.meta)
    }

    func setDraft(_ d: StreamDraft?) {
        draft = d
        notify(.draft)
    }

    func metaChanged() { notify(.meta) }

    /// Ensures every tool_use has a matching tool_result so history stays valid for the API.
    func repairDanglingToolCalls(persist doPersist: Bool = true) {
        guard let last = messages.last, last.role == .assistant else { return }
        let calls = last.blocks.compactMap { b -> String? in if case .toolUse(let id, _, _) = b { return id }; return nil }
        guard !calls.isEmpty else { return }
        let results = calls.map { ContentBlock.toolResult(id: $0, content: "Tool call was interrupted before it produced a result.", isError: true, images: nil) }
        let m = Message(role: .user, blocks: results, isToolResults: true)
        messages.append(m)
        if doPersist { persist(.message(m)) }
    }

    // MARK: Derived

    var totalUsage: Usage { messages.reduce(Usage()) { $0 + ($1.usage ?? Usage()) } }
    var lastPromptTokens: Int { messages.last(where: { $0.usage != nil })?.usage?.promptTotal ?? 0 }
    var stepCount: Int { messages.filter { $0.role == .assistant }.count }
    var outputRate: Double? {
        let rated = messages.filter { $0.role == .assistant && ($0.duration ?? 0) > 0.2 }
        let out = rated.reduce(0) { $0 + ($1.usage?.output ?? 0) }
        let dur = rated.reduce(0.0) { $0 + ($1.duration ?? 0) }
        return dur > 0 ? Double(out) / dur : nil
    }
    var cacheHitRate: Double? {
        let u = totalUsage
        return u.promptTotal > 0 ? Double(u.cacheRead) / Double(u.promptTotal) : nil
    }

    func deleteFile() {
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    var fileURLForExport: URL { fileURL }
}
