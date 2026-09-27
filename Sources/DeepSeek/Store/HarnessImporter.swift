import Foundation

/// Imports sessions written by the Node DeepSeek Harness (~/.dsh/sessions/*/session-*/session.v4.jsonl.zstd).
enum HarnessImporter {
    static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/sessions") }

    static func candidates() -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        for ws in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for s in (try? fm.contentsOfDirectory(at: ws, includingPropertiesForKeys: nil)) ?? [] where s.lastPathComponent.hasPrefix("session-") {
                let f = s.appendingPathComponent("session.v4.jsonl.zstd")
                if fm.fileExists(atPath: f.path) { out.append(f) }
            }
        }
        return out
    }

    private static func decompress(_ url: URL) -> Data? {
        let tools: [[String]] = [
            ["/opt/homebrew/bin/zstd", "-dc", url.path],
            ["/usr/local/bin/zstd", "-dc", url.path],
            ["/usr/bin/env", "node", "-e", "process.stdout.write(require('zlib').zstdDecompressSync(require('fs').readFileSync(process.argv[1])))", url.path],
        ]
        for argv in tools where FileManager.default.isExecutableFile(atPath: argv[0]) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: argv[0])
            p.arguments = Array(argv.dropFirst())
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0, !data.isEmpty { return data }
        }
        return nil
    }

    /// Imports every harness session not yet present. Returns the number imported.
    @discardableResult
    static func importAll() -> Int {
        var count = 0
        for url in candidates() {
            let id = url.deletingLastPathComponent().lastPathComponent
            let exists = Thread.isMainThread ? SessionStore.shared.entry(id: id) != nil : DispatchQueue.main.sync { SessionStore.shared.entry(id: id) != nil }
            if exists { continue }
            if importSession(url, id: id) { count += 1 }
        }
        return count
    }

    private static func importSession(_ url: URL, id: String) -> Bool {
        guard let data = decompress(url) else { return false }
        var events: [SessionEvent] = []
        var cwd = ""
        var createdAt = 0.0
        var title = "Imported session"
        var messages: [Message] = []
        var toolRuns: [String: ToolRun] = [:]
        var turnIndex = 0
        var lastTime = 0.0

        func appendUser(_ blocks: [ContentBlock], time: Double, toolResults: Bool) {
            if let last = messages.last, last.role == .user {
                messages[messages.count - 1].blocks += blocks
                if toolResults { messages[messages.count - 1].isToolResults = true }
                return
            }
            messages.append(Message(role: .user, blocks: blocks, time: time, isToolResults: toolResults ? true : nil))
        }

        for line in data.split(separator: 0x0A) {
            guard let e = JSON.parse(Data(line)) else { continue }
            let type = e["type"]?.string ?? ""
            let time = (e["time"]?.double ?? 0) / 1000
            if time > 0 { lastTime = time }
            let d = e["data"]
            switch type {
            case "session":
                cwd = e["cwd"]?.string ?? ""
                createdAt = (e["createdAt"]?.double ?? 0) / 1000
            case "user/message":
                let text = (d?["content"]?.array ?? []).compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
                guard !text.isEmpty else { continue }
                let startsTurn = messages.last?.role != .user || messages.isEmpty
                if startsTurn || events.isEmpty {
                    messages.append(Message(role: .user, blocks: [.text(text)], time: time))
                } else {
                    appendUser([.text(text)], time: time, toolResults: false)
                }
            case "turn/start":
                turnIndex += 1
                if let mi = messages.lastIndex(where: { $0.role == .user && $0.isToolResults != true }) {
                    events.append(.turnStart(TurnRecord(index: turnIndex, startedAt: time, endedAt: nil, end: nil, messageIndex: mi)))
                }
            case "turn/end":
                let kind = d?["reason"]?["kind"]?.string ?? "completed"
                let end: TurnEnd = kind == "completed" ? .completed : (kind == "error" ? .error(d?["reason"]?["message"]?.string ?? "Error") : .stopped)
                events.append(.turnEnd(index: turnIndex, endedAt: time, end: end))
            case "assistant/message":
                guard let m = d?["message"] else { continue }
                var blocks: [ContentBlock] = []
                for b in m["content"]?.array ?? [] {
                    switch b["type"]?.string {
                    case "text": if let t = b["text"]?.string, !t.isEmpty { blocks.append(.text(t)) }
                    case "reasoning": if let t = b["text"]?.string, !t.isEmpty { blocks.append(.thinking(text: t, signature: nil)) }
                    case "tool-call":
                        let cid = b["id"]?.string ?? UUID().uuidString
                        blocks.append(.toolUse(id: cid, name: b["name"]?.string ?? "tool", input: b["arguments"]?.string ?? "{}"))
                        toolRuns[cid] = ToolRun(status: .done, startedAt: time)
                    default: break
                    }
                }
                let u = d?["usage"]
                let usage = Usage(input: u?["inputTokens"]?.int ?? 0, output: u?["outputTokens"]?.int ?? 0,
                                  cacheRead: u?["cacheReadTokens"]?.int ?? 0, cacheWrite: u?["cacheWriteTokens"]?.int ?? 0)
                messages.append(Message(role: .assistant, blocks: blocks, time: time, usage: usage, model: m["source"]?["model"]?.string))
            case "tool/result":
                guard let m = d?["message"], let cid = m["toolCallId"]?.string else { continue }
                let text = (m["content"]?.array ?? []).compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined(separator: "\n")
                let isError = m["isError"]?.bool ?? false
                appendUser([.toolResult(id: cid, content: text, isError: isError, images: nil)], time: time, toolResults: true)
                var r = toolRuns[cid] ?? ToolRun(status: .done)
                r.status = isError ? .error : .done
                r.finishedAt = time
                r.output = String(text.prefix(200_000))
                toolRuns[cid] = r
            case "session/title":
                if let t = d?["title"]?.string, !t.isEmpty { title = t }
            case "todo/write":
                let todos = (d?["todos"]?.array ?? []).compactMap { t -> TodoItem? in
                    guard let c = t["content"]?.string else { return nil }
                    return TodoItem(content: c, status: t["status"]?.string ?? "pending")
                }
                events.append(.todos(todos))
            default: break
            }
        }
        guard !cwd.isEmpty, !messages.isEmpty else { return false }
        // Durable order: header, messages interleaved with turn markers by message index.
        var out: [SessionEvent] = [.header(id: id, cwd: cwd, createdAt: createdAt), .title(title)]
        let turnStarts = events.compactMap { e -> TurnRecord? in if case .turnStart(let t) = e { return t }; return nil }
        var ends: [Int: SessionEvent] = [:]
        for e in events { if case .turnEnd(let i, _, _) = e { ends[i] = e } }
        for (i, m) in messages.enumerated() {
            out.append(.message(m))
            if let t = turnStarts.first(where: { $0.messageIndex == i }) {
                if t.index > 1, let e = ends[t.index - 1] { out.insert(e, at: out.count - 1) }
                out.append(.turnStart(t))
            }
        }
        if let last = turnStarts.last, let e = ends[last.index] { out.append(e) }
        for (k, r) in toolRuns { out.append(.toolRun(id: k, run: r)) }
        for e in events { if case .todos = e { out.append(e) } }

        let enc = JSONEncoder()
        var file = Data()
        for e in out { if let d = try? enc.encode(e) { file.append(d); file.append(0x0A) } }
        let dest = Paths.sessions.appendingPathComponent(id + ".jsonl")
        guard (try? file.write(to: dest)) != nil else { return false }
        SessionStore.shared.addImported(SessionIndexEntry(id: id, cwd: cwd, title: title, createdAt: createdAt, updatedAt: max(lastTime, createdAt)))
        return true
    }
}
