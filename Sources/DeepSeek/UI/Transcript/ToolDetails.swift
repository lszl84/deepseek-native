import AppKit

/// Expanded detail pane for one tool call.
enum ToolDetails {
    static func mono(_ s: String, color: NSColor = Theme.secondaryText, font: NSFont = Theme.monoSmall) -> NSAttributedString {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        p.lineBreakMode = .byCharWrapping
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
    }

    /// Keeps the last `maxLines` lines unless `showAll`; returns the text and the number of hidden lines.
    static func tail(_ s: String, maxLines: Int, showAll: Bool) -> (String, Int) {
        let trimmed = s.trimmingCharacters(in: .newlines)
        if showAll { return (String(trimmed.suffix(200_000)), 0) }
        var count = 0
        var idx = trimmed.endIndex
        while idx > trimmed.startIndex {
            let prev = trimmed.index(before: idx)
            if trimmed[prev] == "\n" { count += 1; if count >= maxLines { return (String(trimmed[idx...]), trimmed[..<idx].filter { $0 == "\n" }.count + 1) } }
            idx = prev
        }
        return (trimmed, 0)
    }

    static func head(_ s: String, maxLines: Int, showAll: Bool) -> (String, Int) {
        let lines = s.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        if showAll || lines.count <= maxLines { return (lines.joined(separator: "\n"), 0) }
        return (lines.prefix(maxLines).joined(separator: "\n"), lines.count - maxLines)
    }

    private static func moreRow(_ hidden: Int, id: String, showAll: Bool, above: Bool) -> Element? {
        if showAll { return RowEl(icon: "chevron.up", title: "Show less", key: "all:" + id, hit: .toggle("all:" + id), titleColor: Theme.accent, titleFont: Theme.captionFont, height: 22) }
        guard hidden > 0 else { return nil }
        return RowEl(icon: "ellipsis", title: "\(hidden) \(above ? "earlier" : "more") lines", key: "all:" + id, hit: .toggle("all:" + id), titleColor: Theme.accent, titleFont: Theme.captionFont, height: 22)
    }

    static func element(name: String, input: JSON, raw: String, run: ToolRun?, id: String, cwd: String, showAll: Bool) -> Element {
        let isError = run?.status == .error || run?.status == .denied
        let output = run?.output ?? run?.progress ?? ""
        let outColor = isError ? Theme.error : Theme.secondaryText
        switch name {
        case "bash":
            var children: [Element] = [TextEl(mono("$ " + (input["command"]?.string ?? ""), color: Theme.text))]
            if !output.isEmpty {
                let (t, hidden) = tail(output, maxLines: 40, showAll: showAll)
                if let m = moreRow(hidden, id: id, showAll: showAll, above: true) { children.append(m) }
                children.append(TextEl(mono(t, color: outColor)))
            } else if run?.status == .running {
                children.append(TextEl(mono("Running…", color: Theme.tertiaryText)))
            }
            return DetailBoxEl(children)

        case "edit":
            let old = input["old_string"]?.string ?? ""
            let new = input["new_string"]?.string ?? ""
            var lines: [DiffEl.Line] = []
            let ol = old.components(separatedBy: "\n"), nl = new.components(separatedBy: "\n")
            // Trim common prefix/suffix lines to show a compact hunk.
            var p = 0
            while p < ol.count && p < nl.count && ol[p] == nl[p] { p += 1 }
            var s = 0
            while s < ol.count - p && s < nl.count - p && ol[ol.count - 1 - s] == nl[nl.count - 1 - s] { s += 1 }
            for l in ol[max(0, p - 2)..<p] { lines.append(.init(text: l, kind: 0)) }
            for l in ol[p..<(ol.count - s)] { lines.append(.init(text: l, kind: -1)) }
            for l in nl[p..<(nl.count - s)] { lines.append(.init(text: l, kind: 1)) }
            for l in ol[(ol.count - s)..<min(ol.count, ol.count - s + 2)] { lines.append(.init(text: l, kind: 0)) }
            var children: [Element] = []
            let limit = showAll ? 2000 : 80
            children.append(DiffEl(lines: Array(lines.prefix(limit))))
            if let m = moreRow(max(0, lines.count - limit), id: id, showAll: showAll && lines.count > 80, above: false) { children.append(m) }
            if isError { children.append(TextEl(mono(output, color: Theme.error))) }
            return VStackEl(children, spacing: 6)

        case "write":
            let content = input["content"]?.string ?? ""
            let (t, hidden) = head(content, maxLines: 60, showAll: showAll)
            var children: [Element] = [DiffEl(lines: t.components(separatedBy: "\n").map { .init(text: $0, kind: 1) })]
            if let m = moreRow(hidden, id: id, showAll: showAll && hidden == 0 && content.components(separatedBy: "\n").count > 60, above: false) { children.append(m) }
            if isError { children.append(TextEl(mono(output, color: Theme.error))) }
            return VStackEl(children, spacing: 6)

        case "todo_write":
            let items = (input["todos"]?.array ?? []).map { t -> ListEl.Item in
                let status = t["status"]?.string ?? "pending"
                let content = t["content"]?.string ?? ""
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: status == "in_progress" ? Theme.bodyBold : Theme.bodyFont,
                    .foregroundColor: status == "completed" ? Theme.tertiaryText : Theme.text,
                    .strikethroughStyle: status == "completed" ? NSUnderlineStyle.single.rawValue : 0,
                    .paragraphStyle: Markdown.paragraphStyle(MDStyle(lineSpacing: 4)),
                ]
                let a = NSMutableAttributedString(string: content, attributes: attrs)
                if status != "completed" { a.removeAttribute(.strikethroughStyle, range: NSRange(location: 0, length: a.length)) }
                return ListEl.Item(marker: "", task: status == "completed", content: TextEl(a))
            }
            return BoxEl(ListEl(items: items, font: Theme.bodyFont, color: Theme.text), padding: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12), background: Theme.codeBackground, border: Theme.codeBorder, radius: 10)

        case "web_search":
            if let sources = run?.meta?["sources"]?.array, !sources.isEmpty {
                let md = sources.map { "- [\($0["title"]?.string ?? "")](\($0["url"]?.string ?? ""))" }.joined(separator: "\n")
                var st = MDStyle.body
                st.font = Theme.smallFont
                st.lineSpacing = 4
                return BoxEl(MDRender.element(Markdown.parse(md, style: st), style: st, keyPrefix: id), padding: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12), background: Theme.codeBackground, border: Theme.codeBorder, radius: 10)
            }
            return DetailBoxEl([TextEl(mono(output.isEmpty ? "Searching…" : output, color: outColor))])

        case "subagent":
            var children: [Element] = []
            let (prompt, _) = head(input["prompt"]?.string ?? "", maxLines: showAll ? 1000 : 6, showAll: false)
            children.append(TextEl(mono(prompt, color: Theme.tertiaryText, font: Theme.captionFont)))
            if let out = run?.output {
                var st = MDStyle.body
                st.font = Theme.smallFont
                st.lineSpacing = 5
                st.baseDir = cwd
                let (t, hidden) = head(out, maxLines: 40, showAll: showAll)
                children.append(RuleEl(margin: 2))
                children.append(MDRender.element(Markdown.parse(t, style: st), style: st, keyPrefix: id + ".r"))
                if let m = moreRow(hidden, id: id, showAll: showAll, above: false) { children.append(m) }
            } else if let p = run?.progress {
                children.append(TextEl(mono(p, color: Theme.secondaryText, font: Theme.captionFont)))
            }
            return BoxEl(VStackEl(children, spacing: 8), padding: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12), background: Theme.codeBackground, border: Theme.codeBorder, radius: 10)

        case "ask_user_question":
            var md = ""
            for q in input["questions"]?.array ?? [] {
                md += "**\(q["question"]?.string ?? "")**\n\n"
            }
            if let answers = run?.meta?["answers"]?.object {
                md += answers.map { "- \($0.key): " + ($0.value.array?.compactMap { $0.string }.joined(separator: ", ") ?? "") }.sorted().joined(separator: "\n")
            } else if !output.isEmpty { md += output }
            var st = MDStyle.body
            st.font = Theme.smallFont
            st.lineSpacing = 4
            return BoxEl(MDRender.element(Markdown.parse(md, style: st), style: st, keyPrefix: id), padding: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12), background: Theme.codeBackground, border: Theme.codeBorder, radius: 10)

        case "read", "grep", "glob", "web_fetch", "job_output", "job_list", "read_image":
            let (t, hidden) = head(output.isEmpty ? (run?.status == .running ? "Running…" : "(no output)") : output, maxLines: 30, showAll: showAll)
            var children: [Element] = [TextEl(mono(t, color: outColor))]
            if let m = moreRow(hidden, id: id, showAll: showAll, above: false) { children.append(m) }
            return DetailBoxEl(children)

        default:
            let pretty = (JSON.parse(raw) ?? .null).serialized(pretty: true)
            let (t, hidden) = head(output, maxLines: 30, showAll: showAll)
            var children: [Element] = [TextEl(mono(pretty, color: Theme.tertiaryText))]
            if !t.isEmpty { children.append(TextEl(mono(t, color: outColor))) }
            if let m = moreRow(hidden, id: id, showAll: showAll, above: false) { children.append(m) }
            return DetailBoxEl(children)
        }
    }
}
