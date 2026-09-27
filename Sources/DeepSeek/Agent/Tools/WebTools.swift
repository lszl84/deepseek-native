import Foundation

struct WebFetchTool: AgentTool {
    let name = "web_fetch"
    let description = "Fetch the content of a specific HTTP(S) URL and return it decoded to text."
    let schema = DeepSeek.schema("""
    {"type":"object","properties":{"url":{"type":"string","description":"The HTTP(S) URL to fetch."}},"required":["url"]}
    """)
    var concurrencySafe: Bool { true }

    func run(_ input: JSON, _ ctx: ToolContext) async -> ToolResult {
        guard let s = input["url"]?.string, let url = URL(string: s), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return .error("A valid http(s) URL is required.")
        }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,text/plain,application/json;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let body = data.prefix(8_000_000)
            var text: String
            if type.contains("html") || (type.isEmpty && body.prefix(512).range(of: Data("<html".utf8)) != nil) {
                text = HTMLText.markdown(String(decoding: body, as: UTF8.self), base: url)
            } else if type.hasPrefix("image/") || type.contains("pdf") || type.contains("octet-stream") || type.hasPrefix("video/") || type.hasPrefix("audio/") {
                return .error("\(url.absoluteString) returned binary content (\(type), \(data.count) bytes) that cannot be decoded to text.")
            } else {
                text = String(decoding: body, as: UTF8.self)
            }
            var header = "URL: \(http?.url?.absoluteString ?? url.absoluteString)\nStatus: \(status)\n\n"
            if text.count > 100_000 {
                let saved = spill(text, name: "fetch")
                text = String(text.prefix(100_000))
                header += "[content truncated to 100000 characters\(saved.map { "; full text saved to \($0)" } ?? "")]\n\n"
            }
            return ToolResult(text: header + text, isError: status >= 400, meta: ["status": .number(Double(status))])
        } catch {
            return .error("Fetch failed: \(error.localizedDescription)")
        }
    }
}

struct WebSearchTool: AgentTool {
    let name = "web_search"
    let description = "Search the web for current information. Returns an optional summary answer and a list of source URLs."
    let schema = DeepSeek.schema("""
    {"type":"object","properties":{"queries":{"type":"array","description":"1–4 search queries; their results are merged.","items":{"type":"string"}}},"required":["queries"]}
    """)
    var concurrencySafe: Bool { true }

    func run(_ input: JSON, _ ctx: ToolContext) async -> ToolResult {
        let queries = (input["queries"]?.array?.compactMap { $0.string } ?? input["query"]?.string.map { [$0] } ?? []).prefix(4)
        guard !queries.isEmpty else { return .error("queries must contain 1–4 search queries.") }
        let results = await withTaskGroup(of: (Int, Result<(String, [(String, String)]), Error>).self) { group in
            for (i, q) in queries.enumerated() {
                group.addTask { do { return (i, .success(try await search(q))) } catch { return (i, .failure(error)) } }
            }
            var out: [(Int, Result<(String, [(String, String)]), Error>)] = []
            for await r in group { out.append(r) }
            return out.sorted { $0.0 < $1.0 }.map { $0.1 }
        }
        var answers: [String] = []
        var sources: [(String, String)] = []
        var seen = Set<String>()
        var errors: [String] = []
        for r in results {
            switch r {
            case .success(let (answer, src)):
                if !answer.isEmpty { answers.append(answer) }
                for s in src where !seen.contains(s.1) { seen.insert(s.1); sources.append(s) }
            case .failure(let e): errors.append((e as? LLMError)?.message ?? e.localizedDescription)
            }
        }
        if sources.isEmpty && answers.isEmpty {
            return .error("Web search failed: " + (errors.first ?? "no results"))
        }
        var text = ""
        if !answers.isEmpty { text += "Summary:\n" + answers.joined(separator: "\n\n") + "\n\n" }
        text += "Sources:\n" + sources.enumerated().map { "\($0.offset + 1). [\($0.element.0)](\($0.element.1))" }.joined(separator: "\n")
        let meta: JSON = ["sources": .array(sources.prefix(20).map { ["title": .string($0.0), "url": .string($0.1)] })]
        return ToolResult(text: text, meta: meta)
    }

    /// One DeepSeek native search turn through the server-side `web_search_20250305` tool.
    private func search(_ query: String) async throws -> (String, [(String, String)]) {
        let body: JSON = [
            "model": .string(Settings.shared.model),
            "max_tokens": 4096,
            "stream": false,
            "messages": [["role": "user", "content": [["type": "text", "text": .string("Perform a web search for the query: \(query)")]]]],
            "tools": [["type": "web_search_20250305", "name": "web_search", "max_uses": 5]],
        ]
        let j = try await MessagesClient.shared.complete(body: body)
        var sources: [(String, String)] = []
        var answer = ""
        for block in j["content"]?.array ?? [] {
            switch block["type"]?.string {
            case "web_search_tool_result":
                for item in block["content"]?.array ?? [] where item["type"]?.string == "web_search_result" {
                    if let url = item["url"]?.string, !url.isEmpty { sources.append((item["title"]?.string ?? url, url)) }
                }
            case "text":
                answer += block["text"]?.string ?? ""
            default: break
            }
        }
        if sources.isEmpty && answer.isEmpty { throw LLMError(message: "DeepSeek returned no web search results", status: nil, retryable: false) }
        return (answer.trimmingCharacters(in: .whitespacesAndNewlines), sources)
    }
}

/// Minimal HTML → Markdown-ish text conversion for web_fetch.
enum HTMLText {
    static func markdown(_ html: String, base: URL) -> String {
        var s = html
        for tag in ["script", "style", "noscript", "svg", "head", "template", "iframe", "nav", "footer"] {
            s = s.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        var out = ""
        out.reserveCapacity(s.utf8.count / 2)
        var i = s.startIndex
        var linkStack: [String?] = []
        var inPre = 0
        while i < s.endIndex {
            if s[i] == "<", let close = s[i...].firstIndex(of: ">") {
                let raw = s[s.index(after: i)..<close]
                i = s.index(after: close)
                let closing = raw.hasPrefix("/")
                let nameEnd = raw.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "/" && !closing }) ?? raw.endIndex
                let name = raw[raw.index(raw.startIndex, offsetBy: closing ? 1 : 0)..<max(raw.index(raw.startIndex, offsetBy: closing ? 1 : 0), nameEnd)].lowercased()
                switch name {
                case "br": out += "\n"
                case "p", "div", "section", "article", "main", "header", "table", "ul", "ol", "blockquote", "figure", "form", "dl":
                    out += "\n\n"
                case "tr", "dt", "dd": out += "\n"
                case "td", "th": out += closing ? " | " : ""
                case "li": if !closing { out += "\n- " }
                case "h1", "h2", "h3", "h4", "h5", "h6":
                    if closing { out += "\n\n" } else { out += "\n\n" + String(repeating: "#", count: Int(String(name.last!)) ?? 1) + " " }
                case "pre":
                    if closing { inPre = max(0, inPre - 1); out += "\n```\n" } else { inPre += 1; out += "\n```\n" }
                case "code": if inPre == 0 { out += "`" }
                case "strong", "b": out += "**"
                case "em", "i": out += "*"
                case "hr": out += "\n\n---\n\n"
                case "a":
                    if closing {
                        if let href = linkStack.popLast() ?? nil { out += "](\(href))" }
                    } else {
                        let href = attr("href", in: String(raw)).flatMap { URL(string: $0, relativeTo: base)?.absoluteString }
                        if let href, !href.hasPrefix("javascript:") { out += "["; linkStack.append(href) } else { linkStack.append(nil) }
                    }
                case "img":
                    if let alt = attr("alt", in: String(raw)), !alt.isEmpty { out += "[image: \(alt)]" }
                default: break
                }
            } else {
                let next = s[i...].firstIndex(of: "<") ?? s.endIndex
                var chunk = decodeEntities(String(s[i..<next]))
                if inPre == 0 { chunk = chunk.replacingOccurrences(of: "[\\s]+", with: " ", options: .regularExpression) }
                out += chunk
                i = next
            }
        }
        // Normalize whitespace.
        let lines = out.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        var blank = 0
        for l in lines {
            if l.isEmpty { blank += 1; if blank <= 1 { result.append("") } } else { blank = 0; result.append(l) }
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func attr(_ name: String, in tag: String) -> String? {
        guard let r = tag.range(of: "\(name)\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", options: [.regularExpression, .caseInsensitive]) else { return nil }
        var v = String(tag[r])
        v = String(v[v.index(after: v.firstIndex(of: "=")!)...]).trimmingCharacters(in: .whitespaces)
        v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return decodeEntities(v)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = s
        let map = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“", "&copy;": "©"]
        for (k, v) in map { out = out.replacingOccurrences(of: k, with: v) }
        if out.contains("&#") {
            let rx = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
            let ns = out as NSString
            var result = ""
            var last = 0
            for m in rx.matches(in: out, range: NSRange(location: 0, length: ns.length)) {
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                let num = UInt32(ns.substring(with: m.range(at: 2)), radix: hex ? 16 : 10)
                if let num, let u = Unicode.Scalar(num) { result.unicodeScalars.append(u) }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out
    }
}
