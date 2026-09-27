import Foundation

struct LLMError: Error, LocalizedError {
    var message: String
    var status: Int?
    var retryable: Bool
    var retryAfter: Double?
    var errorDescription: String? { message }
}

struct ToolSpec {
    let name: String
    let description: String
    let schema: JSON
    var wire: JSON { ["name": .string(name), "description": .string(description), "input_schema": schema] }
}

struct LLMRequest {
    var model: String
    var system: String
    var messages: [Message]
    var tools: [ToolSpec]
    var maxTokens: Int
    var effort: ReasoningEffort
    var sessionId: String?

    var body: JSON {
        var o: [String: JSON] = [
            "model": .string(model),
            "stream": true,
            "max_tokens": .number(Double(maxTokens)),
            "messages": .array(messages.map { $0.wire }),
            "thinking": ["type": effort == .off ? "disabled" : "enabled"],
        ]
        if effort != .off { o["output_config"] = ["effort": .string(effort.rawValue)] }
        if !system.isEmpty { o["system"] = .string(system) }
        if !tools.isEmpty { o["tools"] = .array(tools.map { $0.wire }) }
        return .object(o)
    }
}

/// Assistant message assembled from stream events.
struct StreamDraft {
    enum Block {
        case text(String)
        case thinking(String, signature: String)
        case toolUse(id: String, name: String, json: String)
    }
    var blocks: [Block] = []
    var usage = Usage()
    var stopReason: String?
    /// Wall time when the first content token arrived.
    var firstTokenAt: Double?

    var contentBlocks: [ContentBlock] {
        blocks.map {
            switch $0 {
            case .text(let t): return .text(t)
            case .thinking(let t, let s): return .thinking(text: t, signature: s.isEmpty ? nil : s)
            case .toolUse(let id, let name, let json): return .toolUse(id: id, name: name, input: json.isEmpty ? "{}" : json)
            }
        }
    }
}

final class MessagesClient {
    static let shared = MessagesClient()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 60 * 60 * 6
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.urlCache = nil
        return URLSession(configuration: cfg)
    }()

    private func makeRequest(body: JSON, sessionId: String?, stream: Bool) throws -> URLRequest {
        let settings = Settings.shared
        guard !settings.apiKey.isEmpty else {
            throw LLMError(message: "No DeepSeek API key configured. Open Settings → Models to add one.", status: nil, retryable: false)
        }
        var req = URLRequest(url: settings.messagesEndpoint)
        req.httpMethod = "POST"
        req.setValue(settings.apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "accept")
        req.setValue("deepseek-harness-native/1.0", forHTTPHeaderField: "user-agent")
        if let sessionId { req.setValue(sessionId, forHTTPHeaderField: "x-deepseek-harness-session-id") }
        req.httpBody = Data(body.serialized().utf8)
        return req
    }

    private static func error(from data: Data, status: Int, headers: [AnyHashable: Any]) -> LLMError {
        var message = "DeepSeek request failed (HTTP \(status))"
        if let j = JSON.parse(data), let m = j["error"]?["message"]?.string { message = m + " (HTTP \(status))" }
        else if let s = String(data: data.prefix(400), encoding: .utf8), !s.isEmpty { message += ": " + s }
        var retryAfter: Double?
        if let ra = headers["Retry-After"] as? String ?? headers["retry-after"] as? String { retryAfter = Double(ra) }
        let retryable = status == 429 || status >= 500 || status == 408
        return LLMError(message: message, status: status, retryable: retryable, retryAfter: retryAfter)
    }

    /// Streams one Messages request. `onEvent` receives the running draft after each content event.
    func stream(_ request: LLMRequest, onEvent: @escaping (StreamDraft) -> Void) async throws -> StreamDraft {
        let req = try makeRequest(body: request.body, sessionId: request.sessionId, stream: true)
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: req)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            throw LLMError(message: error.localizedDescription, status: nil, retryable: true)
        }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status < 200 || status >= 300 {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 64_000 { break } }
            throw Self.error(from: data, status: status, headers: http?.allHeaderFields ?? [:])
        }

        var draft = StreamDraft()
        var indexMap: [Int: Int] = [:]
        // Deltas are coalesced: handing out a copy on every token would force an O(n) string copy per token.
        var lastEmit = 0.0
        func emit(force: Bool = false) {
            let now = CFAbsoluteTimeGetCurrent()
            if force || now - lastEmit > 0.045 { lastEmit = now; onEvent(draft) }
        }
        var stopped = false
        do {
            for try await line in bytes.lines {
                try Task.checkCancellation()
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                guard let event = JSON.parse(payload), let type = event["type"]?.string else { continue }
                switch type {
                case "message_start":
                    Self.applyUsage(event["message"]?["usage"], to: &draft.usage)
                case "content_block_start":
                    guard let wi = event["index"]?.int, let cb = event["content_block"] else { continue }
                    indexMap[wi] = draft.blocks.count
                    switch cb["type"]?.string {
                    case "thinking": draft.blocks.append(.thinking(cb["thinking"]?.string ?? "", signature: cb["signature"]?.string ?? ""))
                    case "tool_use": draft.blocks.append(.toolUse(id: cb["id"]?.string ?? UUID().uuidString, name: cb["name"]?.string ?? "", json: ""))
                    case "text": draft.blocks.append(.text(cb["text"]?.string ?? ""))
                    default: indexMap[wi] = nil
                    }
                    emit(force: true)
                case "content_block_delta":
                    guard let wi = event["index"]?.int, let i = indexMap[wi], let d = event["delta"] else { continue }
                    if draft.firstTokenAt == nil { draft.firstTokenAt = Date().timeIntervalSince1970 }
                    switch (d["type"]?.string, draft.blocks[i]) {
                    case ("text_delta", .text(let t)): draft.blocks[i] = .text(t + (d["text"]?.string ?? ""))
                    case ("thinking_delta", .thinking(let t, let s)): draft.blocks[i] = .thinking(t + (d["thinking"]?.string ?? ""), signature: s)
                    case ("signature_delta", .thinking(let t, let s)): draft.blocks[i] = .thinking(t, signature: s + (d["signature"]?.string ?? ""))
                    case ("input_json_delta", .toolUse(let id, let name, let j)): draft.blocks[i] = .toolUse(id: id, name: name, json: j + (d["partial_json"]?.string ?? ""))
                    default: break
                    }
                    emit()
                case "content_block_stop":
                    break
                case "message_delta":
                    if let r = event["delta"]?["stop_reason"]?.string { draft.stopReason = r }
                    Self.applyUsage(event["usage"], to: &draft.usage)
                case "message_stop":
                    stopped = true
                case "error":
                    let msg = event["error"]?["message"]?.string ?? "Stream error"
                    let et = event["error"]?["type"]?.string ?? ""
                    throw LLMError(message: msg, status: nil, retryable: et == "overloaded_error" || et == "api_error" || et == "rate_limit_error")
                default: break
                }
                if stopped { break }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as LLMError {
            throw e
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw LLMError(message: "Stream interrupted: \(error.localizedDescription)", status: nil, retryable: true)
        }
        if !stopped {
            if Task.isCancelled { throw CancellationError() }
            throw LLMError(message: "Stream ended before message_stop", status: nil, retryable: true)
        }
        return draft
    }

    private static func applyUsage(_ u: JSON?, to usage: inout Usage) {
        guard let u else { return }
        if let v = u["input_tokens"]?.int { usage.input = v }
        if let v = u["output_tokens"]?.int { usage.output = v }
        if let v = u["cache_read_input_tokens"]?.int { usage.cacheRead = v }
        if let v = u["cache_creation_input_tokens"]?.int { usage.cacheWrite = v }
    }

    /// Non-streaming JSON request used by auxiliary calls (titles, web search).
    func complete(body: JSON, sessionId: String? = nil) async throws -> JSON {
        let req = try makeRequest(body: body, sessionId: sessionId, stream: false)
        let (data, response) = try await session.data(for: req)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if status < 200 || status >= 300 { throw Self.error(from: data, status: status, headers: http?.allHeaderFields ?? [:]) }
        guard let j = JSON.parse(data) else { throw LLMError(message: "Invalid JSON response", status: status, retryable: false) }
        return j
    }

    /// Generates a short session title with thinking disabled.
    func title(for text: String) async -> String? {
        let prompt = "Write a short title (3-6 words, no quotes, no trailing punctuation) that summarizes this request. Reply with the title only, in the request's language.\n\nRequest:\n" + String(text.prefix(2000))
        let body: JSON = [
            "model": .string(Settings.shared.model),
            "max_tokens": 60,
            "stream": false,
            "thinking": ["type": "disabled"],
            "messages": [["role": "user", "content": [["type": "text", "text": .string(prompt)]]]],
        ]
        guard let j = try? await complete(body: body) else { return nil }
        let t = (j["content"]?.array ?? []).compactMap { $0["type"]?.string == "text" ? $0["text"]?.string : nil }.joined()
        let cleaned = t.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'.#*"))
        return cleaned.isEmpty ? nil : String(cleaned.prefix(80))
    }
}
