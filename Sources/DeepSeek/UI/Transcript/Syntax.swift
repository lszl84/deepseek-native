import AppKit

/// Single-pass tokenizer producing a highlighted monospaced string. Language-aware only for
/// comment syntax and keyword sets; fast enough to rerun on each streaming update.
enum Syntax {
    private static let common: Set<String> = [
        "if", "else", "for", "while", "do", "return", "break", "continue", "switch", "case", "default", "in", "of",
        "true", "false", "null", "nil", "none", "None", "True", "False", "undefined", "try", "catch", "finally", "throw", "throws",
        "import", "export", "from", "as", "new", "class", "struct", "enum", "interface", "extends", "implements",
        "public", "private", "protected", "static", "final", "const", "let", "var", "func", "function", "def", "fn",
        "async", "await", "yield", "self", "this", "super", "type", "typeof", "instanceof", "void", "where", "guard",
        "protocol", "extension", "init", "deinit", "override", "mut", "pub", "impl", "trait", "use", "mod", "crate",
        "package", "go", "defer", "chan", "select", "map", "range", "lambda", "with", "pass", "raise", "except", "elif",
        "and", "or", "not", "is", "global", "nonlocal", "del", "assert", "match", "loop", "unsafe", "move", "ref",
        "int", "float", "double", "char", "bool", "string", "long", "short", "unsigned", "signed", "auto", "inline",
        "then", "fi", "esac", "done", "local", "echo", "export", "readonly", "unset", "elseif", "end", "begin",
        "select", "insert", "update", "delete", "create", "table", "into", "values", "join", "left", "right", "on",
        "group", "by", "order", "having", "limit", "SELECT", "FROM", "WHERE", "INSERT", "UPDATE", "DELETE", "CREATE",
        "TABLE", "INTO", "VALUES", "JOIN", "ON", "GROUP", "BY", "ORDER", "LIMIT", "AND", "OR", "NOT", "NULL", "AS",
        "fileprivate", "internal", "open", "some", "any", "inout", "lazy", "weak", "unowned", "mutating", "typealias",
        "associatedtype", "subscript", "get", "set", "willSet", "didSet", "readonly", "declare", "namespace", "abstract",
    ]

    enum CommentStyle { case cLike, hash, sql, none }

    static func commentStyle(_ lang: String) -> CommentStyle {
        switch lang.lowercased() {
        case "py", "python", "sh", "bash", "zsh", "shell", "console", "yaml", "yml", "toml", "rb", "ruby", "r", "perl", "pl",
             "dockerfile", "makefile", "make", "conf", "ini", "nix", "elixir", "ex", "cmake", "fish", "ps1", "powershell":
            return .hash
        case "sql", "lua", "haskell", "hs": return .sql
        case "json", "text", "txt", "plain", "plaintext", "diff", "patch", "md", "markdown", "csv", "log", "output": return .none
        default: return .cLike
        }
    }

    static func highlight(_ code: String, lang: String, font: NSFont = Theme.monoFont, lineSpacing: CGFloat = 5) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.lineSpacing = lineSpacing
        para.lineBreakMode = .byCharWrapping
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Theme.text, .paragraphStyle: para]
        let out = NSMutableAttributedString(string: code, attributes: base)
        let l = lang.lowercased()
        if l == "diff" || l == "patch" {
            var loc = 0
            for line in code.components(separatedBy: "\n") {
                let len = (line as NSString).length
                if line.hasPrefix("+") && !line.hasPrefix("+++") { out.addAttributes([.foregroundColor: Theme.diffAddText, .backgroundColor: Theme.diffAdd], range: NSRange(location: loc, length: len)) }
                else if line.hasPrefix("-") && !line.hasPrefix("---") { out.addAttributes([.foregroundColor: Theme.diffRemoveText, .backgroundColor: Theme.diffRemove], range: NSRange(location: loc, length: len)) }
                else if line.hasPrefix("@@") { out.addAttribute(.foregroundColor, value: Theme.synFunction, range: NSRange(location: loc, length: len)) }
                loc += len + 1
            }
            return out
        }
        let cs = commentStyle(l)
        if cs == .none && l != "json" { return out }
        let u = Array(code.utf16)
        let n = u.count
        var i = 0
        func color(_ start: Int, _ end: Int, _ c: NSColor) { out.addAttribute(.foregroundColor, value: c, range: NSRange(location: start, length: end - start)) }
        func isIdentStart(_ ch: UInt16) -> Bool { (ch >= 65 && ch <= 90) || (ch >= 97 && ch <= 122) || ch == 95 || ch == 36 || ch == 64 }
        func isIdent(_ ch: UInt16) -> Bool { isIdentStart(ch) || (ch >= 48 && ch <= 57) }
        while i < n {
            let ch = u[i]
            // Comments
            if cs == .cLike && ch == 47 && i + 1 < n {
                if u[i + 1] == 47 { let s = i; while i < n && u[i] != 10 { i += 1 }; color(s, i, Theme.synComment); continue }
                if u[i + 1] == 42 {
                    let s = i; i += 2
                    while i + 1 < n && !(u[i] == 42 && u[i + 1] == 47) { i += 1 }
                    i = min(n, i + 2); color(s, i, Theme.synComment); continue
                }
            }
            if cs == .hash && ch == 35 && (i == 0 || u[i - 1] == 32 || u[i - 1] == 10 || u[i - 1] == 9) {
                let s = i; while i < n && u[i] != 10 { i += 1 }; color(s, i, Theme.synComment); continue
            }
            if cs == .sql && ch == 45 && i + 1 < n && u[i + 1] == 45 {
                let s = i; while i < n && u[i] != 10 { i += 1 }; color(s, i, Theme.synComment); continue
            }
            // Strings
            if ch == 34 || ch == 39 || ch == 96 {
                // Apostrophes inside words (e.g. shell text "don't") are not strings.
                if ch == 39 && i > 0 && isIdent(u[i - 1]) && cs != .cLike { i += 1; continue }
                let q = ch, s = i
                i += 1
                while i < n && u[i] != q {
                    if u[i] == 92 { i += 1 }
                    if u[i < n ? i : n - 1] == 10 && q != 96 { break }
                    i += 1
                }
                i = min(n, i + 1)
                // JSON keys get the function color.
                if l == "json" {
                    var k = i
                    while k < n && (u[k] == 32) { k += 1 }
                    color(s, i, k < n && u[k] == 58 ? Theme.synFunction : Theme.synString)
                } else { color(s, i, Theme.synString) }
                continue
            }
            // Numbers
            if ch >= 48 && ch <= 57 && (i == 0 || !isIdent(u[i - 1])) {
                let s = i
                while i < n && (isIdent(u[i]) || u[i] == 46) { i += 1 }
                color(s, i, Theme.synNumber); continue
            }
            if isIdentStart(ch) {
                let s = i
                while i < n && isIdent(u[i]) { i += 1 }
                let word = String(utf16CodeUnits: Array(u[s..<i]), count: i - s)
                if common.contains(word) { color(s, i, Theme.synKeyword) }
                else if i < n && u[i] == 40 { color(s, i, Theme.synFunction) }
                else if let f = word.utf16.first, f >= 65 && f <= 90, word.count > 1 { color(s, i, Theme.synType) }
                continue
            }
            i += 1
        }
        return out
    }
}
