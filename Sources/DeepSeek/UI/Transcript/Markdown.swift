import AppKit

extension NSAttributedString.Key {
    static let mdLink = NSAttributedString.Key("mdLink")
    static let mdCode = NSAttributedString.Key("mdCode")
    static let mdStrike = NSAttributedString.Key("mdStrike")
}

/// Parsed Markdown block ready for layout.
indirect enum MDBlock {
    case paragraph(NSAttributedString)
    case heading(Int, NSAttributedString)
    case code(lang: String, code: String)
    case list(ordered: Bool, start: Int, items: [MDListItem])
    case quote([MDBlock])
    case table(header: [NSAttributedString], align: [NSTextAlignment], rows: [[NSAttributedString]])
    case hr
    case image(alt: String, src: String)
}

struct MDListItem {
    var task: Bool?   // nil: not a task item; otherwise checked state
    var blocks: [MDBlock]
}

struct MDStyle {
    var font: NSFont = Theme.bodyFont
    var color: NSColor = Theme.text
    var lineSpacing: CGFloat = 7
    var paragraphSpacing: CGFloat = 0
    /// Base directory for resolving relative file links and images.
    var baseDir: String?

    static let body = MDStyle()
    static func thinking() -> MDStyle { MDStyle(font: .systemFont(ofSize: 13), color: Theme.tertiaryText, lineSpacing: 6) }
}

enum Markdown {
    // MARK: Block parsing

    static func parse(_ text: String, style: MDStyle = .body) -> [MDBlock] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        return parseBlocks(lines, &i, style: style, stopAtIndent: nil)
    }

    private static func indentOf(_ s: Substring) -> Int {
        var n = 0
        for c in s { if c == " " { n += 1 } else if c == "\t" { n += 4 } else { break } }
        return n
    }

    private static func isBlank(_ s: String) -> Bool { s.allSatisfy { $0 == " " || $0 == "\t" } }

    private static func fence(_ line: String) -> (marker: String, lang: String)? {
        let t = line.drop(while: { $0 == " " })
        guard indentOf(Substring(line)) < 4 else { return nil }
        for m in ["```", "~~~"] where t.hasPrefix(m) {
            var count = 0
            for c in t { if String(c) == String(m.first!) { count += 1 } else { break } }
            let lang = t.dropFirst(count).trimmingCharacters(in: .whitespaces)
            if m == "```" && lang.contains("`") { return nil }
            return (String(repeating: String(m.first!), count: count), lang.split(separator: " ").first.map(String.init) ?? "")
        }
        return nil
    }

    private static func heading(_ line: String) -> (Int, String)? {
        let t = line.drop(while: { $0 == " " })
        guard t.hasPrefix("#"), indentOf(Substring(line)) < 4 else { return nil }
        let level = t.prefix(while: { $0 == "#" }).count
        guard level <= 6 else { return nil }
        let rest = t.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var content = rest.trimmingCharacters(in: .whitespaces)
        // Strip closing #'s
        while content.hasSuffix("#") { content.removeLast() }
        return (level, content.trimmingCharacters(in: .whitespaces))
    }

    private static func isHR(_ line: String) -> Bool {
        let t = line.filter { $0 != " " && $0 != "\t" }
        guard t.count >= 3, indentOf(Substring(line)) < 4, let f = t.first, "-*_".contains(f) else { return false }
        return t.allSatisfy { $0 == f }
    }

    private static func listMarker(_ line: String) -> (indent: Int, ordered: Bool, number: Int, contentOffset: Int)? {
        let ind = indentOf(Substring(line))
        let t = line.drop(while: { $0 == " " || $0 == "\t" })
        if let f = t.first, "-*+".contains(f) {
            let after = t.dropFirst()
            if after.isEmpty { return (ind, false, 0, line.count - t.count + 1) }
            if after.first == " " || after.first == "\t" {
                let sp = min(4, after.prefix(while: { $0 == " " }).count)
                return (ind, false, 0, line.count - t.count + 1 + max(1, sp))
            }
            return nil
        }
        let digits = t.prefix(while: { $0.isNumber })
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = t.dropFirst(digits.count)
        guard let d = after.first, d == "." || d == ")" else { return nil }
        let rest = after.dropFirst()
        guard rest.isEmpty || rest.first == " " else { return nil }
        let sp = min(4, rest.prefix(while: { $0 == " " }).count)
        return (ind, true, Int(digits) ?? 1, line.count - t.count + digits.count + 1 + max(rest.isEmpty ? 0 : 1, sp))
    }

    private static func isTableSeparator(_ line: String) -> [NSTextAlignment]? {
        var t = line.trimmingCharacters(in: .whitespaces)
        guard t.contains("-"), t.contains("|") || t.contains(":") || t.hasPrefix("-") else { return nil }
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        let cells = t.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        var aligns: [NSTextAlignment] = []
        for c in cells {
            guard !c.isEmpty, c.allSatisfy({ $0 == "-" || $0 == ":" }), c.contains("-") else { return nil }
            let l = c.hasPrefix(":"), r = c.hasSuffix(":")
            aligns.append(l && r ? .center : (r ? .right : .left))
        }
        return aligns
    }

    static func splitRow(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") && !t.hasSuffix("\\|") { t.removeLast() }
        var cells: [String] = []
        var cur = ""
        var inCode = false
        var prev: Character = " "
        for c in t {
            if c == "`" { inCode.toggle() }
            if c == "|" && !inCode && prev != "\\" { cells.append(cur); cur = "" } else { cur.append(c) }
            prev = c
        }
        cells.append(cur)
        return cells.map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|") }
    }

    private static func startsBlock(_ line: String) -> Bool {
        fence(line) != nil || heading(line) != nil || isHR(line) || line.drop(while: { $0 == " " }).hasPrefix(">") || listMarker(line) != nil
    }

    private static func parseBlocks(_ lines: [String], _ i: inout Int, style: MDStyle, stopAtIndent: Int?) -> [MDBlock] {
        var blocks: [MDBlock] = []
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) { i += 1; continue }
            if let f = fence(line) {
                let fenceIndent = indentOf(Substring(line))
                i += 1
                var code: [String] = []
                while i < lines.count {
                    let l = lines[i]
                    let t = l.drop(while: { $0 == " " })
                    if t.hasPrefix(f.marker) && t.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == f.marker.first }) { i += 1; break }
                    var s = Substring(l)
                    var drop = fenceIndent
                    while drop > 0, s.first == " " { s = s.dropFirst(); drop -= 1 }
                    code.append(String(s))
                    i += 1
                }
                blocks.append(.code(lang: f.lang, code: code.joined(separator: "\n")))
                continue
            }
            if let (level, content) = heading(line) {
                blocks.append(.heading(level, inline(content, style: headingStyle(level, style))))
                i += 1
                continue
            }
            if isHR(line) { blocks.append(.hr); i += 1; continue }
            if line.drop(while: { $0 == " " }).hasPrefix(">") {
                var inner: [String] = []
                while i < lines.count {
                    let t = lines[i].drop(while: { $0 == " " })
                    if t.hasPrefix(">") {
                        var s = t.dropFirst()
                        if s.first == " " { s = s.dropFirst() }
                        inner.append(String(s))
                        i += 1
                    } else if !isBlank(lines[i]) && !inner.isEmpty && !isBlank(inner.last!) && !startsBlock(lines[i]) {
                        inner.append(lines[i]) // lazy continuation
                        i += 1
                    } else { break }
                }
                var j = 0
                var qs = style
                qs.color = Theme.secondaryText
                blocks.append(.quote(parseBlocks(inner, &j, style: qs, stopAtIndent: nil)))
                continue
            }
            if let m = listMarker(line) {
                blocks.append(parseList(lines, &i, marker: m, style: style))
                continue
            }
            // Table
            if i + 1 < lines.count, line.contains("|"), let aligns = isTableSeparator(lines[i + 1]) {
                let header = splitRow(line)
                if header.count == aligns.count || header.count > 1 {
                    i += 2
                    var rows: [[NSAttributedString]] = []
                    while i < lines.count, !isBlank(lines[i]), lines[i].contains("|") || !startsBlock(lines[i]) {
                        if !lines[i].contains("|") { break }
                        rows.append(splitRow(lines[i]).map { inline($0, style: style) })
                        i += 1
                    }
                    var bold = style
                    bold.font = NSFont.systemFont(ofSize: style.font.pointSize, weight: .semibold)
                    blocks.append(.table(header: header.map { inline($0, style: bold) }, align: aligns, rows: rows))
                    continue
                }
            }
            // Paragraph
            var para: [String] = []
            while i < lines.count {
                let l = lines[i]
                if isBlank(l) { break }
                if !para.isEmpty && (startsBlock(l) && listMarker(l).map { !$0.ordered || $0.number == 1 } ?? true) { break }
                if !para.isEmpty, i + 1 < lines.count, l.contains("|"), isTableSeparator(lines[i + 1]) != nil { break }
                para.append(l.trimmingCharacters(in: .whitespaces) + (l.hasSuffix("  ") ? "\u{2028}" : ""))
                i += 1
            }
            let joined = para.joined(separator: "\n").replacingOccurrences(of: "\u{2028}\n", with: "\u{2028}")
            let trimmed = joined.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("!["), let img = soleImage(trimmed) {
                blocks.append(.image(alt: img.0, src: img.1))
            } else {
                blocks.append(.paragraph(inline(joined, style: style)))
            }
        }
        return blocks
    }

    private static func soleImage(_ s: String) -> (String, String)? {
        guard let rx = try? NSRegularExpression(pattern: #"^!\[([^\]]*)\]\(\s*<?([^)>]+?)>?(?:\s+"[^"]*")?\s*\)$"#),
              let m = rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        let ns = s as NSString
        return (ns.substring(with: m.range(at: 1)), ns.substring(with: m.range(at: 2)))
    }

    private static func headingStyle(_ level: Int, _ base: MDStyle) -> MDStyle {
        var s = base
        s.font = Theme.headingFont(level)
        s.lineSpacing = 4
        return s
    }

    private static func parseList(_ lines: [String], _ i: inout Int, marker first: (indent: Int, ordered: Bool, number: Int, contentOffset: Int), style: MDStyle) -> MDBlock {
        var items: [MDListItem] = []
        let baseIndent = first.indent
        while i < lines.count {
            guard let m = listMarker(lines[i]), m.ordered == first.ordered, m.indent >= baseIndent, m.indent < baseIndent + 2 || m.indent == baseIndent else { break }
            // Collect the item's lines, de-indented by its content offset.
            var itemLines: [String] = [String(lines[i].dropFirst(min(m.contentOffset, lines[i].count)))]
            i += 1
            var sawBlank = false
            while i < lines.count {
                let l = lines[i]
                if isBlank(l) { sawBlank = true; itemLines.append(""); i += 1; continue }
                let ind = indentOf(Substring(l))
                if ind >= m.contentOffset || (ind > baseIndent && listMarker(l) != nil) {
                    let drop = min(ind, m.contentOffset)
                    itemLines.append(String(l.dropFirst(drop)))
                    sawBlank = false
                    i += 1
                } else if !sawBlank && listMarker(l) == nil && !startsBlock(l) {
                    itemLines.append(l.trimmingCharacters(in: .whitespaces)) // lazy continuation
                    i += 1
                } else { break }
            }
            while itemLines.last.map(isBlank) == true { itemLines.removeLast() }
            var task: Bool?
            if let f = itemLines.first {
                if f.hasPrefix("[ ] ") || f == "[ ]" { task = false; itemLines[0] = String(f.dropFirst(min(4, f.count))) }
                else if f.lowercased().hasPrefix("[x] ") || f.lowercased() == "[x]" { task = true; itemLines[0] = String(f.dropFirst(min(4, f.count))) }
            }
            var j = 0
            items.append(MDListItem(task: task, blocks: parseBlocks(itemLines, &j, style: style, stopAtIndent: nil)))
            // Blank lines between items keep the list going.
            var k = i
            while k < lines.count, isBlank(lines[k]) { k += 1 }
            if k < lines.count, let n = listMarker(lines[k]), n.ordered == first.ordered, n.indent == baseIndent { i = k } else { break }
        }
        return .list(ordered: first.ordered, start: first.number, items: items)
    }

    // MARK: Inline parsing

    static func paragraphStyle(_ style: MDStyle, alignment: NSTextAlignment = .natural) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = style.lineSpacing
        p.paragraphSpacing = style.paragraphSpacing
        p.alignment = alignment
        p.lineBreakMode = .byWordWrapping
        return p
    }

    static func inline(_ text: String, style: MDStyle, alignment: NSTextAlignment = .natural) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: style.font, .foregroundColor: style.color, .paragraphStyle: paragraphStyle(style, alignment: alignment)]
        appendInline(Array(text), into: out, attrs: base, style: style)
        return out
    }

    private static func withTrait(_ font: NSFont, _ trait: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(trait))
        return NSFont(descriptor: d, size: font.pointSize) ?? font
    }

    private static func appendInline(_ c: [Character], into out: NSMutableAttributedString, attrs: [NSAttributedString.Key: Any], style: MDStyle) {
        var buf = ""
        func flush() {
            if !buf.isEmpty { out.append(NSAttributedString(string: buf, attributes: attrs)); buf = "" }
        }
        var i = 0
        let n = c.count
        func find(_ pattern: [Character], from: Int) -> Int? {
            guard pattern.count > 0, from <= n - pattern.count else { return nil }
            var j = from
            while j <= n - pattern.count {
                if c[j] == "\\" { j += 2; continue }
                if c[j] == pattern[0] && Array(c[j..<(j + pattern.count)]) == pattern { return j }
                j += 1
            }
            return nil
        }
        while i < n {
            let ch = c[i]
            // Escapes
            if ch == "\\", i + 1 < n, "\\`*_{}[]()#+-.!|~<>\"'".contains(c[i + 1]) {
                buf.append(c[i + 1]); i += 2; continue
            }
            if ch == "\u{2028}" { buf.append("\u{2028}"); i += 1; continue }
            // Code span
            if ch == "`" {
                var ticks = 0
                while i + ticks < n && c[i + ticks] == "`" { ticks += 1 }
                let fence = Array(repeating: Character("`"), count: ticks)
                var j = i + ticks
                var close: Int?
                while j <= n - ticks {
                    if Array(c[j..<(j + ticks)]) == fence && (j + ticks == n || c[j + ticks] != "`") { close = j; break }
                    j += 1
                }
                if let close {
                    flush()
                    var code = String(c[(i + ticks)..<close]).replacingOccurrences(of: "\n", with: " ")
                    if code.hasPrefix(" ") && code.hasSuffix(" ") && code.count > 2 { code = String(code.dropFirst().dropLast()) }
                    var a = attrs
                    a[.font] = NSFont.monospacedSystemFont(ofSize: style.font.pointSize * 0.89, weight: .regular)
                    a[.mdCode] = true
                    // Thin padding around the code background.
                    out.append(NSAttributedString(string: "\u{2009}", attributes: attrs))
                    out.append(NSAttributedString(string: code, attributes: a))
                    out.append(NSAttributedString(string: "\u{2009}", attributes: attrs))
                    i = close + ticks
                    continue
                }
                buf.append(contentsOf: String(fence)); i += ticks; continue
            }
            // Images and links
            if ch == "!" && i + 1 < n && c[i + 1] == "[" , let (label, url, end) = linkAt(c, i + 1) {
                flush()
                var a = attrs
                a[.foregroundColor] = Theme.accent
                a[.mdLink] = resolveLink(url, style)
                out.append(NSAttributedString(string: "🖼 " + (label.isEmpty ? (url as NSString).lastPathComponent : label), attributes: a))
                i = end
                continue
            }
            if ch == "[", let (label, url, end) = linkAt(c, i) {
                flush()
                var a = attrs
                a[.foregroundColor] = Theme.accent
                a[.mdLink] = resolveLink(url, style)
                appendInline(Array(label), into: out, attrs: a, style: style)
                i = end
                continue
            }
            // Autolinks <http://...>
            if ch == "<", let close = find([">"], from: i + 1) {
                let inner = String(c[(i + 1)..<close])
                if inner.hasPrefix("http://") || inner.hasPrefix("https://") || inner.hasPrefix("mailto:") {
                    flush()
                    var a = attrs
                    a[.foregroundColor] = Theme.accent
                    a[.mdLink] = inner
                    out.append(NSAttributedString(string: inner, attributes: a))
                    i = close + 1
                    continue
                }
            }
            // Bare URLs
            if ch == "h", (i == 0 || !c[i - 1].isLetter), n - i > 8 {
                let s = String(c[i..<min(n, i + 8)])
                if s.hasPrefix("https://") || s.hasPrefix("http://") {
                    var j = i
                    while j < n, !c[j].isWhitespace, c[j] != "<", c[j] != ">", c[j] != "\"", c[j] != "`" { j += 1 }
                    while j > i, ".,;:!?)]'".contains(c[j - 1]) {
                        if c[j - 1] == ")" && c[i..<j].filter({ $0 == "(" }).count >= c[i..<j].filter({ $0 == ")" }).count { break }
                        j -= 1
                    }
                    flush()
                    let url = String(c[i..<j])
                    var a = attrs
                    a[.foregroundColor] = Theme.accent
                    a[.mdLink] = url
                    out.append(NSAttributedString(string: url, attributes: a))
                    i = j
                    continue
                }
            }
            // Emphasis
            if ch == "*" || ch == "_" || ch == "~" {
                var run = 0
                while i + run < n && c[i + run] == ch { run += 1 }
                let canOpen = i + run < n && !c[i + run].isWhitespace
                let intraword = ch == "_" && i > 0 && (c[i - 1].isLetter || c[i - 1].isNumber)
                if ch == "~" && run == 2 && canOpen, let close = find(["~", "~"], from: i + 2), close > i + 2 {
                    flush()
                    var a = attrs
                    a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    appendInline(Array(c[(i + 2)..<close]), into: out, attrs: a, style: style)
                    i = close + 2
                    continue
                }
                if ch != "~" && canOpen && !intraword {
                    let r = min(run, 3)
                    let pattern = Array(repeating: ch, count: r)
                    var j = i + r
                    var close: Int?
                    while let k = find(pattern, from: j) {
                        if k > i + r && !c[k - 1].isWhitespace && (ch != "_" || k + r >= n || !(c[k + r].isLetter || c[k + r].isNumber)) {
                            // Avoid matching the start of a longer run for single emphasis.
                            if r == 1 && k + 1 < n && c[k + 1] == ch && !(k + 2 < n && c[k + 2] == ch) { j = k + 2; continue }
                            close = k; break
                        }
                        j = k + 1
                    }
                    if let close {
                        flush()
                        var a = attrs
                        let f = a[.font] as! NSFont
                        switch r {
                        case 1: a[.font] = withTrait(f, .italic)
                        case 2: a[.font] = NSFont.systemFont(ofSize: f.pointSize, weight: .semibold).withTraits(of: f, adding: [])
                        default: a[.font] = withTrait(NSFont.systemFont(ofSize: f.pointSize, weight: .semibold), .italic)
                        }
                        appendInline(Array(c[(i + r)..<close]), into: out, attrs: a, style: style)
                        i = close + r
                        continue
                    }
                }
                buf.append(contentsOf: String(repeating: ch, count: run))
                i += run
                continue
            }
            buf.append(ch)
            i += 1
        }
        flush()
    }

    /// Parses `[label](url)` starting at `i` (which points at "[").
    private static func linkAt(_ c: [Character], _ i: Int) -> (String, String, Int)? {
        let n = c.count
        var depth = 0
        var j = i
        var labelEnd: Int?
        while j < n {
            if c[j] == "\\" { j += 2; continue }
            if c[j] == "[" { depth += 1 }
            if c[j] == "]" { depth -= 1; if depth == 0 { labelEnd = j; break } }
            if c[j] == "`" {
                if let k = c[(j + 1)...].firstIndex(of: "`") { j = k }
            }
            j += 1
        }
        guard let le = labelEnd, le + 1 < n, c[le + 1] == "(" else { return nil }
        var k = le + 2
        var url = ""
        if k < n && c[k] == "<" {
            k += 1
            while k < n && c[k] != ">" { url.append(c[k]); k += 1 }
            guard k < n else { return nil }
            k += 1
            while k < n && c[k] != ")" { k += 1 }
            guard k < n else { return nil }
        } else {
            var paren = 0
            while k < n {
                if c[k] == "(" { paren += 1 }
                if c[k] == ")" { if paren == 0 { break }; paren -= 1 }
                if c[k] == " " { // title follows
                    let rest = c[k...]
                    if let close = rest.firstIndex(of: ")") { k = close }
                    break
                }
                url.append(c[k]); k += 1
            }
            guard k < n else { return nil }
        }
        return (String(c[(i + 1)..<le]), url.trimmingCharacters(in: .whitespaces), k + 1)
    }

    private static func resolveLink(_ url: String, _ style: MDStyle) -> String {
        if url.contains("://") || url.hasPrefix("mailto:") || url.hasPrefix("#") { return url }
        var path = url.removingPercentEncoding ?? url
        path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/"), let base = style.baseDir { path = (base as NSString).appendingPathComponent(path) }
        return "file://" + path
    }
}

private extension NSFont {
    func withTraits(of other: NSFont, adding: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let traits = other.fontDescriptor.symbolicTraits.intersection(.italic).union(adding)
        if traits.isEmpty { return self }
        let d = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
}
