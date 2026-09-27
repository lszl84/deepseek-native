import Foundation

struct ToolResult {
    var text: String
    var isError = false
    var images: [ContentBlock.ImageData]? = nil
    var meta: JSON? = nil

    static func error(_ s: String) -> ToolResult { ToolResult(text: s, isError: true) }
}

protocol AgentTool {
    var name: String { get }
    var description: String { get }
    var schema: JSON { get }
    /// Whether calls may overlap with other concurrency-safe calls in the same step.
    var concurrencySafe: Bool { get }
    func run(_ input: JSON, _ ctx: ToolContext) async -> ToolResult
}

extension AgentTool {
    var concurrencySafe: Bool { false }
    var spec: ToolSpec { ToolSpec(name: name, description: description, schema: schema) }
}

/// Per-call environment handed to tools.
final class ToolContext {
    let agent: Agent
    let callId: String
    let cwd: String

    init(agent: Agent, callId: String, cwd: String) {
        self.agent = agent
        self.callId = callId
        self.cwd = cwd
    }

    var session: Session { agent.session }
    var jobs: JobManager { agent.jobs }

    /// Resolves `path` against the working directory, expanding `~`.
    func resolve(_ path: String?) -> String {
        guard var p = path?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty else { return cwd }
        if p.hasPrefix("@") { p.removeFirst() }
        p = (p as NSString).expandingTildeInPath
        if !p.hasPrefix("/") { p = (cwd as NSString).appendingPathComponent(p) }
        return (p as NSString).standardizingPath
    }

    func isInsideWorkspace(_ path: String) -> Bool {
        let p = path.hasSuffix("/") ? path : path + "/"
        let roots = [cwd, NSTemporaryDirectory(), "/tmp", "/private/tmp"]
        return roots.contains { r in
            let root = (r as NSString).standardizingPath
            return p.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    func progress(_ text: String) {
        let id = callId
        let s = session
        DispatchQueue.main.async { s.updateToolProgress(id, text) }
    }

    func setMeta(_ meta: JSON) {
        let id = callId
        let s = session
        DispatchQueue.main.async {
            if var r = s.toolRuns[id] { r.meta = meta; s.setToolRun(id, r, persistNow: false) }
        }
    }

    /// Asks the user to approve an action. `key` lets "allow for session" cover later identical requests.
    func requestApproval(title: String, detail: String, key: String) async -> Bool {
        await agent.requestApproval(callId: callId, title: title, detail: detail, key: key)
    }

    /// Marks a file as read so later write/edit calls pass the observation policy.
    func observe(_ path: String) {
        let s = session
        DispatchQueue.main.async { s.markObserved(path) }
    }

    func hasObserved(_ path: String) async -> Bool {
        await MainActor.run { session.observedFiles.contains(path) }
    }
}
