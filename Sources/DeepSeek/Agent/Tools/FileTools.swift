import Foundation
import ImageIO
import UniformTypeIdentifiers

func schema(_ text: String) -> JSON { JSON.parse(text) ?? .object([:]) }

enum FSPolicy {
    /// Returns an error result when the current permission mode forbids writing `path` and the user declines.
    static func checkWrite(_ path: String, _ ctx: ToolContext, verb: String) async -> ToolResult? {
        let mode = await MainActor.run { ctx.session.permission }
        switch mode {
        case .fullAccess: return nil
        case .workspaceWrite where ctx.isInsideWorkspace(path): return nil
        default:
            let where_ = mode == .readOnly ? "in read-only mode" : "outside the workspace"
            let ok = await ctx.requestApproval(title: "\(verb) \((path as NSString).lastPathComponent) \(where_)?", detail: path, key: "write:\(path)")
            return ok ? nil : .error("The user denied \(verb.lowercased()) \(path). Do not retry another way; ask the user how to proceed if it is required.")
        }
    }
}

struct ReadTool: AgentTool {
    let name = "read"
    let description = "Read a UTF-8 text file and return line-numbered content."
    let schema = DeepSeek.schema("""
    {"type":"object","properties":{"file_path":{"type":"string","description":"Path to read, resolved by the filesystem backend."},"offset":{"type":"number","description":"1-based first line to return. Defaults to 1."},"limit":{"type":"number","description":"Maximum number of lines to return. Defaults to 2000."}},"required":["file_path"]}
    """)
    var concurrencySafe: Bool { true }

    func run(_ input: JSON, _ ctx: ToolContext) async -> ToolResult {
        let path = ctx.resolve(input["file_path"]?.string)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            ctx.observe(path)
            return .error("File not found: \(path)")
        }
        if isDir.boolValue {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: path))?.sorted() ?? []
            return .error("\(path) is a directory. Entries:\n" + items.prefix(500).map { item -> String in
                var d: ObjCBool = false
                FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(item), isDirectory: &d)
                return d.boolValue ? item + "/" : item
            }.joined(separator: "\n"))
        }
        guard let data = FileManager.default.contents(atPath: path) else { return .error("Cannot read \(path)") }
        if data.prefix(8192).contains(0) {
            return .error("\(path) is a binary file (\(data.count) bytes); it cannot be read as text.")
        }
        let text = String(decoding: data, as: UTF8.self)
        ctx.observe(path)
        let offset = max(1, input["offset"]?.int ?? 1)
        let limit = max(1, input["limit"]?.int ?? 2000)
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        if lines.isEmpty { return ToolResult(text: "(empty file)", meta: ["lines": 0]) }
        guard offset <= lines.count else { return .error("offset \(offset) is past the end of the file (\(lines.count) lines).") }
        let end = min(lines.count, offset - 1 + limit)
        var out = ""
        out.reserveCapacity(min(data.count, 400_000))
        var chars = 0
        var lastLine = offset - 1
        for i in (offset - 1)..<end {
            var l = lines[i]
            if l.count > 2000 { l = String(l.prefix(2000)) + " … [line truncated]" }
            let row = String(format: "%6d\t", i + 1) + l + "\n"
            chars += row.count
            if chars > 250_000 { break }
            out += row
            lastLine = i + 1
        }
        if lastLine < lines.count {
            out += "\n[Showing lines \(offset)-\(lastLine) of \(lines.count). Use offset \(lastLine + 1) to continue.]"
        }
        return ToolResult(text: out, meta: ["lines": .number(Double(lastLine - offset + 1)), "total": .number(Double(lines.count))])
    }
}

struct WriteTool: AgentTool {
    let name = "write"
    let description = "Create or fully replace a UTF-8 text file."
    let schema = DeepSeek.schema("""
    {"type":"object","properties":{"file_path":{"type":"string","description":"Path to write, resolved by the filesystem backend."},"content":{"type":"string","description":"Full UTF-8 text content to write."}},"required":["file_path","content"]}
    """)

    func run(_ input: JSON, _ ctx: ToolContext) async -> ToolResult {
        let path = ctx.resolve(input["file_path"]?.string)
        guard let content = input["content"]?.string else { return .error("content is required") }
        let exists = FileManager.default.fileExists(atPath: path)
        if exists, !(await ctx.hasObserved(path)) {
            return .error("\(path) already exists and has not been read in this session. Read it before overwriting it, or use edit for targeted changes.")
        }
        if let denied = await FSPolicy.checkWrite(path, ctx, verb: exists ? "Overwrite" : "Create") { return denied }
        let old = exists ? (try? String(contentsOfFile: path, encoding: .utf8)) : nil
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try content.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            return .error("Failed to write \(path): \(error.localizedDescription)")
        }
        ctx.observe(path)
        let lines = content.isEmpty ? 0 : content.components(separatedBy: "\n").count
        let oldLines = old.map { $0.components(separatedBy: "\n").count } ?? 0
        return ToolResult(text: "\(exists ? "Overwrote" : "Created") \(path) (\(lines) lines).",
                          meta: ["added": .number(Double(lines)), "removed": .number(Double(oldLines)), "created": .bool(!exists)])
    }
}

struct EditTool: AgentTool {
    let name = "edit"
    let description = "Edit an existing UTF-8 text file by replacing literal text."
    let schema = DeepSeek.schema("""
    {"type":"object","properties":{"file_path":{"type":"string","description":"Path to edit, resolved by the filesystem backend."},"old_string":{"type":"string","description":"Literal text to replace."},"new_string":{"type":"string","description":"Literal replacement text. Use an empty string to delete the match."},"replace_all":{"type":"boolean","description":"Replace all matches. Defaults to false; when false, old_string must appear exactly once."}},"required":["file_path","old_string","new_string"]}
    """)

    func run(_ input: JSON, _ ctx: ToolContext) async -> ToolResult {
        let path = ctx.resolve(input["file_path"]?.string)
        guard let old = input["old_string"]?.string, let new = input["new_string"]?.string else { return .error("old_string and new_string are required") }
        guard FileManager.default.fileExists(atPath: path) else { return .error("File not found: \(path). Use write to create a new file.") }
        guard await ctx.hasObserved(path) else { return .error("\(path) has not been read in this session. Read it before editing.") }
        guard !old.isEmpty else { return .error("old_string must not be empty.") }
        guard old != new else { return .error("old_string and new_string are identical.") }
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return .error("Cannot read \(path) as UTF-8.") }
        let count = text.components(separatedBy: old).count - 1
        let all = input["replace_all"]?.bool ?? false
        if count == 0 { return .error("old_string was not found in \(path). Read the file again to get the exact current text, including whitespace.") }
        if count > 1 && !all { return .error("old_string appears \(count) times in \(path). Include more surrounding context to make it unique, or set replace_all.") }
        if let denied = await FSPolicy.checkWrite(path, ctx, verb: "Edit") { return denied }
        let updated: String
        if all { updated = text.replacingOccurrences(of: old, with: new) }
        else if let r = text.range(of: old) { updated = text.replacingCharacters(in: r, with: new) }
        else { updated = text }
        do { try updated.write(toFile: path, atomically: true, encoding: .utf8) } catch {
            return .error("Failed to write \(path): \(error.localizedDescription)")
        }
        ctx.observe(path)
        let startLine = text.range(of: old).map { text[..<$0.lowerBound].filter { $0 == "\n" }.count + 1 } ?? 1
        let removed = old.components(separatedBy: "\n").count * (all ? count : 1)
        let added = new.isEmpty ? 0 : new.components(separatedBy: "\n").count * (all ? count : 1)
        return ToolResult(text: "Edited \(path): replaced \(all ? count : 1) occurrence\(all && count > 1 ? "s" : "").",
                          meta: ["added": .number(Double(added)), "removed": .number(Double(removed)), "line": .number(Double(startLine))])
    }
}

struct ReadImageTool: AgentTool {
    let name = "read_image"
    let description = "Read a PNG/JPEG/WebP/GIF file and return the image itself. Large images are downscaled automatically; do not install image libraries or create thumbnails to inspect an image."
    let schema = DeepSeek.schema("""
    {"type":"object","properties":{"file_path":{"type":"string","description":"Path to the image file, resolved by the filesystem backend."}},"required":["file_path"]}
    """)
    var concurrencySafe: Bool { true }

    func run(_ input: JSON, _ ctx: ToolContext) async -> ToolResult {
        let path = ctx.resolve(input["file_path"]?.string)
        guard let img = ImageEncoding.load(path: path) else { return .error("Cannot decode image at \(path)") }
        return ToolResult(text: "Image \(path) (\(img.width)×\(img.height)):", images: [img.data], meta: ["width": .number(Double(img.width)), "height": .number(Double(img.height))])
    }
}

enum ImageEncoding {
    /// Loads an image file, downscaling to at most `maxSide` pixels, re-encoded as JPEG or PNG.
    static func load(path: String, maxSide: Int = 1568) -> (data: ContentBlock.ImageData, width: Int, height: Int)? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(cg.alphaInfo)
        let type = hasAlpha ? UTType.png : UTType.jpeg
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        return (ContentBlock.ImageData(mediaType: hasAlpha ? "image/png" : "image/jpeg", base64: (out as Data).base64EncodedString(), path: path), cg.width, cg.height)
    }
}

enum Ripgrep {
    static let path: String? = {
        var candidates: [String] = []
        if let r = Bundle.main.resourcePath { candidates.append(r + "/rg") }
        candidates += ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func run(_ args: [String], cwd: String) async -> (String, Int32) {
        guard let rg = path else { return ("ripgrep is not available", 127) }
        do {
            let p = try ChildProcess.spawn([rg] + args, cwd: cwd, env: ProcessInfo.processInfo.environment)
            let code = await withTaskCancellationHandler {
                await p.wait(timeout: 60)
            } onCancel: { p.terminate() }
            if code == nil { p.terminate() }
            return (p.output(maxChars: 2_000_000).text, code ?? -1)
        } catch {
            return ("Failed to run ripgrep: \(error.localizedDescription)", 127)
        }
    }
}

func spill(_ text: String, name: String) -> String? {
    let url = Paths.spill.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8)).txt")
    do { try text.write(to: url, atomically: true, encoding: .utf8); return url.path } catch { return nil }
}

struct GlobTool: AgentTool {
    let name = "glob"
    let description = "Find files, not directories, whose paths match a glob pattern, including hidden and ignored files. Returns up to 100 paths in modification-time order; a larger result is sampled across top-level entries and reports where the complete list was saved."
    let schema = DeepSeek.schema("""
    {"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern to match file paths against (e.g. \\"**/*.ts\\", \\"src/**/*.test.js\\"). A pattern with no \\"/\\" matches the basename at any depth, so \\"*\\" and \\"*.ts\\" both search the whole tree; include a separator to anchor the depth."},"path":{"type":"string","description":"Directory to search in. Defaults to the session workspace; a relative path resolves against it."}},"required":["pattern"]}
    """)
    var concurrencySafe: Bool { true }

    func run(_ input: JSON, _ ctx: ToolContext) async -> ToolResult {
        guard let pattern = input["pattern"]?.string, !pattern.isEmpty else { return .error("pattern is required") }
        let root = ctx.resolve(input["path"]?.string)
        var files: [String]
        if Ripgrep.path != nil {
            let (out, code) = await Ripgrep.run(["--files", "--hidden", "--no-ignore", "--no-messages", "-g", pattern, "-g", "!.git/"], cwd: root)
            if code > 1 { return .error(out) }
            files = out.split(separator: "\n").map(String.init)
        } else {
            files = FallbackSearch.glob(pattern: pattern, root: root)
        }
        if files.isEmpty { return ToolResult(text: "No files found matching \(pattern) in \(root).", meta: ["count": 0]) }
        let fm = FileManager.default
        let withTime: [(String, Date)] = files.prefix(20_000).map { f in
            let full = (root as NSString).appendingPathComponent(f)
            let d = (try? fm.attributesOfItem(atPath: full)[.modificationDate] as? Date) ?? .distantPast
            return (f, d)
        }
        let sorted = withTime.sorted { $0.1 > $1.1 }.map { $0.0 }
        var text: String
        if sorted.count > 100 {
            // Sample across top-level entries so one huge directory does not hide the rest.
            var buckets: [String: [String]] = [:]
            var order: [String] = []
            for f in sorted {
                let top = f.split(separator: "/").first.map(String.init) ?? f
                if buckets[top] == nil { order.append(top) }
                buckets[top, default: []].append(f)
            }
            var picked: [String] = []
            var round = 0
            while picked.count < 100 {
                var added = false
                for t in order where round < buckets[t]!.count && picked.count < 100 { picked.append(buckets[t]![round]); added = true }
                if !added { break }
                round += 1
            }
            text = picked.joined(separator: "\n")
            let saved = spill(sorted.joined(separator: "\n"), name: "glob")
            text += "\n\n[\(sorted.count) files matched; showing a sample of 100.\(saved.map { " Complete list saved to \($0)" } ?? "")]"
        } else {
            text = sorted.joined(separator: "\n")
        }
        return ToolResult(text: text, meta: ["count": .number(Double(sorted.count))])
    }
}

struct GrepTool: AgentTool {
    let name = "grep"
    let description = "Search file contents with a ripgrep regular expression. Returns matching lines with line numbers, grouped by file. Returns up to 250 matches; a larger result reports where the complete match list was saved."
    let schema = DeepSeek.schema("""
    {"type":"object","properties":{"pattern":{"type":"string","description":"Regular expression to search for (ripgrep syntax)."},"path":{"type":"string","description":"File or directory to search. Defaults to the session workspace; a relative path resolves against it."},"include":{"type":"string","description":"One glob filter for which files to search (e.g. \\"*.ts\\", \\"*.{js,jsx}\\"). Not a list; negation is not supported."}},"required":["pattern"]}
    """)
    var concurrencySafe: Bool { true }

    func run(_ input: JSON, _ ctx: ToolContext) async -> ToolResult {
        guard let pattern = input["pattern"]?.string, !pattern.isEmpty else { return .error("pattern is required") }
        let target = ctx.resolve(input["path"]?.string)
        var out: String
        if Ripgrep.path != nil {
            var args = ["--heading", "-n", "--color", "never", "--max-columns", "400", "--max-columns-preview", "--no-messages", "--hidden", "-g", "!.git/"]
            if let inc = input["include"]?.string, !inc.isEmpty { args += ["-g", inc] }
            args += ["-e", pattern, target]
            let (o, code) = await Ripgrep.run(args, cwd: ctx.cwd)
            if code == 1 { return ToolResult(text: "No matches for \(pattern).", meta: ["count": 0]) }
            if code > 1 { return .error(o.isEmpty ? "grep failed (exit \(code))" : o) }
            out = o
        } else {
            out = FallbackSearch.grep(pattern: pattern, root: target, include: input["include"]?.string)
            if out.isEmpty { return ToolResult(text: "No matches for \(pattern).", meta: ["count": 0]) }
        }
        // Make file headings relative to the working directory.
        let prefix = ctx.cwd.hasSuffix("/") ? ctx.cwd : ctx.cwd + "/"
        var lines: [Substring] = out.split(separator: "\n", omittingEmptySubsequences: false)
        var matches = 0
        var shown: [Substring] = []
        var cut = false
        for (i, l) in lines.enumerated() {
            let isMatch = l.first?.isNumber == true && l.contains(":")
            if isMatch { matches += 1 }
            if matches > 250 { cut = true; lines = Array(lines[i...]); break }
            shown.append(l.hasPrefix(prefix) ? l.dropFirst(prefix.count) : l)
        }
        var text = shown.joined(separator: "\n").trimmingCharacters(in: .newlines)
        if cut {
            var total = matches
            for l in lines.dropFirst() where l.first?.isNumber == true { total += 1 }
            let saved = spill(out, name: "grep")
            text += "\n\n[\(total) matches; showing the first 250.\(saved.map { " Complete results saved to \($0)" } ?? "")]"
            matches = total
        }
        return ToolResult(text: text, meta: ["count": .number(Double(matches))])
    }
}

/// Pure-Swift search used only when ripgrep is unavailable.
enum FallbackSearch {
    static let skip: Set<String> = [".git", "node_modules", ".build", "DerivedData"]

    static func walk(_ root: String, _ body: (String) -> Bool) {
        guard let e = FileManager.default.enumerator(atPath: root) else { return }
        while let f = e.nextObject() as? String {
            if skip.contains((f as NSString).lastPathComponent) { e.skipDescendants(); continue }
            if let t = e.fileAttributes?[.type] as? FileAttributeType, t == .typeRegular { if !body(f) { return } }
        }
    }

    static func glob(pattern: String, root: String) -> [String] {
        let rx = globRegex(pattern.contains("/") ? pattern : "**/" + pattern)
        var out: [String] = []
        walk(root) { f in
            if rx?.firstMatch(in: f, range: NSRange(f.startIndex..., in: f)) != nil { out.append(f) }
            return out.count < 50_000
        }
        return out
    }

    static func globRegex(_ g: String) -> NSRegularExpression? {
        var r = "^"
        var i = g.startIndex
        while i < g.endIndex {
            let c = g[i]
            if c == "*" {
                let n = g.index(after: i)
                if n < g.endIndex && g[n] == "*" {
                    let after = g.index(after: n)
                    if after < g.endIndex && g[after] == "/" { r += "(?:.*/)?"; i = g.index(after: after); continue }
                    r += ".*"; i = after; continue
                }
                r += "[^/]*"
            } else if c == "?" { r += "[^/]" }
            else if c == "{" { r += "(?:" }
            else if c == "}" { r += ")" }
            else if c == "," { r += "|" }
            else { r += NSRegularExpression.escapedPattern(for: String(c)) }
            i = g.index(after: i)
        }
        return try? NSRegularExpression(pattern: r + "$")
    }

    static func grep(pattern: String, root: String, include: String?) -> String {
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return "" }
        let inc = include.flatMap { globRegex("**/" + $0) }
        var out = ""
        var count = 0
        walk(root) { f in
            if let inc, inc.firstMatch(in: f, range: NSRange(f.startIndex..., in: f)) == nil { return true }
            let full = (root as NSString).appendingPathComponent(f)
            guard let d = FileManager.default.contents(atPath: full), d.count < 5_000_000, !d.prefix(4096).contains(0) else { return true }
            let text = String(decoding: d, as: UTF8.self)
            var header = false
            for (n, line) in text.components(separatedBy: "\n").enumerated() {
                if rx.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    if !header { out += (out.isEmpty ? "" : "\n") + full + "\n"; header = true }
                    out += "\(n + 1):\(line.prefix(400))\n"
                    count += 1
                }
            }
            return count < 5000
        }
        return out
    }
}
