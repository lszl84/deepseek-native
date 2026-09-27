import AppKit

struct ItemSpec {
    let key: String
    let sig: Int
    let gapBefore: CGFloat
    let make: () -> Element
}

/// UI state for the transcript that survives rebuilds.
struct TranscriptState {
    var expanded: Set<String> = []
    var collapsed: Set<String> = []
    var selectedOptions: [String: Set<String>] = [:]
    /// Keys that the last build rendered expanded.
    var effectiveExpanded: Set<String> = []
}

enum Fmt {
    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        if t < 60 { return "\(max(t, 0))s" }
        if t < 3600 { return "\(t / 60)m \(t % 60)s" }
        return "\(t / 3600)h \((t % 3600) / 60)m"
    }
    static func tokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1000 { return String(format: n >= 100_000 ? "%.0fK" : "%.1fK", Double(n) / 1000).replacingOccurrences(of: ".0K", with: "K") }
        return "\(n)"
    }
    static let timeFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    static func time(_ t: Double) -> String { timeFormatter.string(from: Date(timeIntervalSince1970: t)) }
    static func relative(_ t: Double) -> String {
        let d = Date().timeIntervalSince1970 - t
        if d < 60 { return "now" }
        if d < 3600 { return "\(Int(d / 60))min" }
        if d < 86400 { return "\(Int(d / 3600))h" }
        if d < 86400 * 7 { return "\(Int(d / 86400))d" }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}

enum TranscriptBuilder {
    private enum Seg {
        case thinking(text: String, key: String, streaming: Bool)
        case tool(id: String, name: String, input: String)
    }

    private final class Ctx {
        let session: Session
        var state: TranscriptState
        let now: Double
        var items: [ItemSpec] = []
        var group: [Seg] = []
        var groupStreaming = false
        var turn: TurnRecord?
        var turnTexts: [String] = []
        var turnUsage = Usage()
        var presented: [(String, String)] = []
        init(session: Session, state: TranscriptState, now: Double) { self.session = session; self.state = state; self.now = now }
    }

    static func build(session: Session, state: inout TranscriptState, now: Double) -> [ItemSpec] {
        let c = Ctx(session: session, state: state, now: now)
        c.state.effectiveExpanded = []
        let msgs = session.messages
        var turnsByStart: [Int: TurnRecord] = [:]
        for t in session.turns { turnsByStart[t.messageIndex] = t }
        let cwd = session.cwd

        let compactedAt = session.compaction?.index
        for (i, m) in msgs.enumerated() {
            if i == compactedAt {
                c.items.append(ItemSpec(key: "compact.\(i)", sig: 1, gapBefore: 24) {
                    RowEl(icon: "rectangle.compress.vertical", title: "Earlier context was compacted into a summary", key: "compact.\(i)", hit: nil,
                          titleColor: Theme.tertiaryText, titleFont: Theme.smallFont, height: 26)
                })
            }
            if let t = turnsByStart[i] {
                if let prev = c.turn { endTurn(c, prev) }
                c.turn = t
                c.turnTexts = []
                c.turnUsage = Usage()
                c.presented = []
                if m.notice == true { addNotice(c, m.text, key: m.id) } else { addUser(c, m) }
                addHeader(c, t)
                continue
            }
            switch m.role {
            case .assistant:
                addAssistantBlocks(c, id: m.id, blocks: m.blocks.map { b -> DraftBlock in
                    switch b {
                    case .text(let t): return .text(t)
                    case .thinking(let t, _): return .thinking(t)
                    case .toolUse(let id, let name, let input): return .tool(id, name, input)
                    default: return .text("")
                    }
                }, streaming: false, cwd: cwd)
                if let u = m.usage { c.turnUsage = c.turnUsage + u }
            case .user:
                if m.isToolResults == true {
                    for (j, b) in m.blocks.enumerated() {
                        guard case .text(let t) = b else { continue }
                        flushGroup(c, cwd: cwd)
                        if t.hasPrefix("<background-job-finished") { addNotice(c, t, key: "\(m.id).\(j)") }
                        else { addUserText(c, t, time: m.time, key: "\(m.id).\(j)") }
                    }
                } else if m.notice == true {
                    addNotice(c, m.text, key: m.id)
                } else {
                    flushGroup(c, cwd: cwd)
                    addUser(c, m)
                }
            }
        }
        if let d = session.draft, session.isRunning {
            addAssistantBlocks(c, id: session.draftId ?? "draft", blocks: d.blocks.map { b -> DraftBlock in
                switch b {
                case .text(let t): return .text(t)
                case .thinking(let t, _): return .thinking(t)
                case .toolUse(let id, let name, let json): return .tool(id, name, json)
                }
            }, streaming: true, cwd: cwd)
        }
        if let t = c.turn { endTurn(c, session.turns.last(where: { $0.index == t.index }) ?? t) }
        addPending(c)
        state = c.state
        return c.items
    }

    /// Index after the last blank line that is outside a fenced code block (nil when there is none).
    private static func stableSplit(_ t: String) -> String.Index? {
        var inFence = false
        var lastSplit: String.Index?
        var lineStart = t.startIndex
        var prevBlank = false
        while lineStart < t.endIndex {
            let lineEnd = t[lineStart...].firstIndex(of: "\n") ?? t.endIndex
            let line = t[lineStart..<lineEnd]
            let trimmed = line.drop(while: { $0 == " " })
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            let blank = line.allSatisfy { $0 == " " || $0 == "\t" }
            if blank && !inFence && !prevBlank && lineEnd < t.endIndex { lastSplit = t.index(after: lineEnd) }
            prevBlank = blank
            lineStart = lineEnd < t.endIndex ? t.index(after: lineEnd) : t.endIndex
        }
        guard let sp = lastSplit, sp > t.startIndex, sp < t.endIndex else { return nil }
        // Do not split inside a list or table that continues past the blank line.
        return sp
    }

    private enum DraftBlock { case text(String), thinking(String), tool(String, String, String) }

    // MARK: Items

    private static func sig(_ values: AnyHashable...) -> Int {
        var h = Hasher()
        for v in values { h.combine(v) }
        return h.finalize()
    }

    private static func addUser(_ c: Ctx, _ m: Message) {
        let images = m.blocks.compactMap { b -> String? in if case .image(let i) = b { return i.path ?? "image" }; return nil }
        var text = m.text
        if !images.isEmpty { text = images.map { "🖼 " + ($0 as NSString).lastPathComponent }.joined(separator: "  ") + (text.isEmpty ? "" : "\n" + text) }
        addUserText(c, text, time: m.time, key: m.id)
    }

    private static func addUserText(_ c: Ctx, _ text: String, time: Double, key: String) {
        let t = Fmt.time(time)
        c.items.append(ItemSpec(key: key, sig: sig(text, t), gapBefore: c.items.isEmpty ? 8 : 28) {
            UserBubbleEl(text: text, time: t, key: key)
        })
    }

    private static func addNotice(_ c: Ctx, _ text: String, key: String) {
        var title = "Notice"
        var sub = text
        if text.hasPrefix("<background-job-finished") {
            func attr(_ n: String) -> String? {
                guard let r = text.range(of: "\(n)=\"") else { return nil }
                return String(text[r.upperBound...].prefix { $0 != "\"" })
            }
            title = "Background job \(attr("id") ?? "") \(attr("status") ?? "finished")"
            if let s = text.range(of: ">"), let e = text.range(of: "</background-job-finished>") { sub = String(text[s.upperBound..<e.lowerBound]) }
        }
        c.items.append(ItemSpec(key: key, sig: sig(title, sub), gapBefore: 20) {
            RowEl(icon: "bell", title: title, subtitle: sub, key: key, hit: nil, titleColor: Theme.tertiaryText, titleFont: Theme.smallFont, height: 26)
        })
    }

    private static func addHeader(_ c: Ctx, _ t: TurnRecord) {
        let running = t.end == nil && c.session.isRunning
        var label: String
        var color = Theme.tertiaryText
        var liveSince: Double?
        switch t.end {
        case .none:
            label = running ? "Working" : "Stopped"
            if running { liveSince = t.startedAt }
            if running, let s = c.session.statusLine { label = s; color = Theme.warning; liveSince = nil }
        case .completed?: label = "Took \(Fmt.duration((t.endedAt ?? t.startedAt) - t.startedAt))"
        case .stopped?: label = "Stopped"
        case .error?: label = "Failed after \(Fmt.duration((t.endedAt ?? t.startedAt) - t.startedAt))"; color = Theme.error
        }
        let key = "h\(t.index)"
        let l = label, col = color
        // The elapsed time is drawn live, so the ticker only repaints this line.
        c.items.append(ItemSpec(key: key, sig: sig(label, running, liveSince ?? 0), gapBefore: 20) {
            TurnHeaderEl(label: l, color: col, spinning: running, liveSince: liveSince)
        })
    }

    private static func addAssistantBlocks(_ c: Ctx, id: String, blocks: [DraftBlock], streaming: Bool, cwd: String) {
        for (j, b) in blocks.enumerated() {
            let key = "\(id).\(j)"
            let isLast = j == blocks.count - 1
            switch b {
            case .text(let t):
                let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                flushGroup(c, cwd: cwd)
                c.turnTexts.append(t)
                let live = streaming && isLast
                var style = MDStyle.body
                style.baseDir = cwd
                if live, let split = stableSplit(t) {
                    // Completed paragraphs are parsed once; only the tail re-parses per update.
                    let stable = String(t[..<split]), tail = String(t[split...])
                    c.items.append(ItemSpec(key: key, sig: sig(stable.count), gapBefore: 14) {
                        MDRender.element(Markdown.parse(stable, style: style), style: style, keyPrefix: key)
                    })
                    if !tail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        c.items.append(ItemSpec(key: key + ".tail", sig: sig(tail.count), gapBefore: 12) {
                            MDRender.element(Markdown.parse(tail, style: style), style: style, keyPrefix: key + ".tail")
                        })
                    }
                } else {
                    // Committed text never changes, so its length identifies it.
                    c.items.append(ItemSpec(key: key, sig: sig(t.count, live), gapBefore: 14) {
                        MDRender.element(Markdown.parse(t, style: style), style: style, keyPrefix: key)
                    })
                }
            case .thinking(let t):
                let live = streaming && isLast
                if t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !live { continue }
                c.group.append(.thinking(text: t, key: key, streaming: live))
                c.groupStreaming = live
            case .tool(let tid, let name, let input):
                c.group.append(.tool(id: tid, name: name, input: input))
                c.groupStreaming = streaming && isLast
            }
        }
    }

    private static func toolTrailing(_ name: String, _ run: ToolRun?, _ streamingInput: Bool) -> RowEl.Trailing {
        guard let run else { return streamingInput ? .spinner : .none }
        switch run.status {
        case .pending, .running: return .spinner
        case .awaitingApproval: return .text("Needs approval", Theme.warning)
        case .denied: return .text("Denied", Theme.error)
        case .cancelled: return .text("Cancelled", Theme.tertiaryText)
        case .error:
            if name == "bash", let code = run.meta?["exitCode"]?.int { return .text("exit \(code)", Theme.error) }
            return .text("Failed", Theme.error)
        case .done:
            let m = run.meta
            switch name {
            case "edit", "write":
                if let a = m?["added"]?.int, let r = m?["removed"]?.int { return .diff(a, name == "write" && m?["created"]?.bool == true ? 0 : r) }
            case "bash":
                if let code = m?["exitCode"]?.int, code != 0 { return .text("exit \(code)", Theme.error) }
                if let job = m?["job"]?.string { return .text(job, Theme.tertiaryText) }
                if let s = run.startedAt, let e = run.finishedAt, e - s >= 1 { return .text(Fmt.duration(e - s), Theme.tertiaryText) }
            case "grep", "glob":
                if let n = m?["count"]?.int { return .text("\(n) \(name == "grep" ? (n == 1 ? "match" : "matches") : (n == 1 ? "file" : "files"))", Theme.tertiaryText) }
            case "read":
                if let n = m?["lines"]?.int { return .text("\(n) lines", Theme.tertiaryText) }
            case "subagent":
                if let n = m?["steps"]?.int { return .text("\(n) steps", Theme.tertiaryText) }
            case "todo_write":
                if let n = m?["added"]?.int, n > 0 { return .text("\(n) added", Theme.tertiaryText) }
            case "web_search":
                if let n = m?["sources"]?.array?.count { return .text("\(n) sources", Theme.tertiaryText) }
            default: break
            }
            return .none
        }
    }

    private static func flushGroup(_ c: Ctx, cwd: String) {
        guard !c.group.isEmpty else { return }
        let segs = c.group
        let streaming = c.groupStreaming
        c.group = []
        c.groupStreaming = false
        let session = c.session
        let tools = segs.compactMap { s -> (String, String, String)? in if case .tool(let i, let n, let inp) = s { return (i, n, inp) }; return nil }
        let firstKey: String = {
            switch segs[0] { case .thinking(_, let k, _): return k; case .tool(let id, _, _): return id }
        }()
        let key = "g." + (tools.first?.0 ?? firstKey)

        if tools.isEmpty {
            // Pure reasoning: "Analysis completed" row.
            let text = segs.compactMap { s -> String? in if case .thinking(let t, _, _) = s { return t }; return nil }.joined(separator: "\n\n")
            let expanded = c.state.expanded.contains(key)
            if expanded { c.state.effectiveExpanded.insert(key) }
            c.items.append(ItemSpec(key: key, sig: sig(text.count, streaming, expanded), gapBefore: 12) {
                var children: [Element] = [RowEl(icon: "atom", title: streaming ? "Thinking" : "Analysis completed",
                                                 trailing: streaming ? .spinner : .none, key: key, hit: .toggle(key), expanded: expanded)]
                if expanded && !text.isEmpty {
                    let st = MDStyle.thinking()
                    children.append(IndentEl(MDRender.element(Markdown.parse(text, style: st), style: st, keyPrefix: key + ".t")))
                    children.append(SpacerEl(4))
                }
                return VStackEl(children, spacing: 4)
            })
            return
        }

        var statusSig = Hasher()
        var active = streaming
        for (id, _, input) in tools {
            let r = session.toolRuns[id]
            statusSig.combine(r?.status.rawValue ?? "none")
            statusSig.combine(r?.output?.count ?? 0)
            statusSig.combine(r?.progress?.count ?? 0)
            statusSig.combine(r?.meta == nil ? 0 : 1)
            statusSig.combine(input.count)
            if let s = r?.status, [.running, .pending, .awaitingApproval].contains(s) { active = true }
        }
        let awaiting = tools.contains { session.toolRuns[$0.0]?.status == .awaitingApproval }
        let categories = tools.map { ToolPresentation.category($0.1) }
        let expanded = c.state.expanded.contains(key) || ((active || awaiting) && !c.state.collapsed.contains(key))
        if expanded { c.state.effectiveExpanded.insert(key) }
        var childExpanded: [String: Bool] = [:]
        for s in segs {
            switch s {
            case .thinking(_, let k, _): childExpanded[k] = c.state.expanded.contains(k)
            case .tool(let id, _, _):
                let st = session.toolRuns[id]?.status
                let e = c.state.expanded.contains(id) || (st == .awaitingApproval && !c.state.collapsed.contains(id))
                childExpanded[id] = e
                childExpanded["all:" + id] = c.state.expanded.contains("all:" + id)
            }
        }
        for (k, v) in childExpanded where v { c.state.effectiveExpanded.insert(k) }
        // Present tool results show as cards after the reply.
        for (id, name, _) in tools where name == "present" {
            for f in session.toolRuns[id]?.meta?["files"]?.array ?? [] {
                if let p = f["path"]?.string { c.presented.append((p, f["description"]?.string ?? "")) }
            }
        }
        var ekeys = childExpanded.filter { $0.value }.map { $0.key }.sorted()
        ekeys.append(expanded ? "E" : "C")
        let s = sig(statusSig.finalize(), segs.count, active, ekeys, segs.map { seg -> Int in if case .thinking(let t, _, _) = seg { return t.count }; return 0 })
        let title = ToolPresentation.groupTitle(categories: categories, running: active)
        let symbol = ToolPresentation.groupSymbol(categories: categories)
        c.items.append(ItemSpec(key: key, sig: s, gapBefore: 12) {
            var children: [Element] = [RowEl(icon: symbol, title: title, trailing: active && !expanded ? .spinner : .none,
                                             key: key, hit: .toggle(key), expanded: expanded)]
            if expanded {
                for seg in segs {
                    switch seg {
                    case .thinking(let t, let k, let live):
                        let first = t.split(separator: "\n").first.map(String.init) ?? ""
                        let e = childExpanded[k] ?? false
                        children.append(RowEl(icon: "atom", title: "Think", subtitle: first.trimmingCharacters(in: .whitespaces), trailing: live ? .spinner : .none,
                                              key: k, hit: .toggle(k), expanded: e))
                        if e {
                            let st = MDStyle.thinking()
                            children.append(IndentEl(MDRender.element(Markdown.parse(t, style: st), style: st, keyPrefix: k + ".t")))
                        }
                    case .tool(let id, let name, let raw):
                        let input = JSON.parse(raw) ?? .object([:])
                        let run = session.toolRuns[id]
                        let e = childExpanded[id] ?? false
                        children.append(RowEl(icon: ToolPresentation.symbol(name), title: ToolPresentation.displayName(name),
                                              subtitle: ToolPresentation.summary(name: name, input: input, cwd: cwd),
                                              trailing: toolTrailing(name, run, streaming && run == nil), key: id, hit: .toggle(id), expanded: e))
                        if e {
                            children.append(IndentEl(ToolDetails.element(name: name, input: input, raw: raw, run: run, id: id, cwd: cwd,
                                                                         showAll: childExpanded["all:" + id] ?? false)))
                            children.append(SpacerEl(4))
                        }
                    }
                }
            }
            return VStackEl(children, spacing: 2)
        })
    }

    private static func endTurn(_ c: Ctx, _ t: TurnRecord) {
        let cwd = c.session.cwd
        flushGroup(c, cwd: cwd)
        for (p, d) in c.presented {
            let key = "present." + p
            c.items.append(ItemSpec(key: key, sig: sig(p, d), gapBefore: 10) { FileCardEl(path: p, detail: d, key: key) })
        }
        guard let end = t.end else { return }
        if case .error(let msg) = end {
            let key = "err\(t.index)"
            let isLastTurn = c.session.turns.last?.index == t.index
            c.items.append(ItemSpec(key: key, sig: sig(msg, isLastTurn), gapBefore: 12) {
                var children: [Element] = [TextEl(NSAttributedString(string: msg, attributes: [.font: Theme.smallFont, .foregroundColor: Theme.error, .paragraphStyle: Markdown.paragraphStyle(MDStyle(lineSpacing: 4))]))]
                if isLastTurn { children.append(ButtonRowEl([ButtonEl("Retry", symbol: "arrow.clockwise", style: .secondary, action: .retry, key: key + ".retry")])) }
                return BoxEl(VStackEl(children, spacing: 10), padding: NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14), background: Theme.errorSoft, radius: 12)
            })
        }
        let key = "f\(t.index)"
        let copy = c.turnTexts.last ?? ""
        let usage = c.turnUsage.total > 0 ? Fmt.tokens(c.turnUsage.total) + " tok" : ""
        let time = Fmt.time(t.endedAt ?? t.startedAt)
        c.items.append(ItemSpec(key: key, sig: sig(copy.count, usage, time), gapBefore: 10) {
            FooterEl(copyText: copy, usage: usage, time: time, key: key)
        })
    }

    private static func addPending(_ c: Ctx) {
        let s = c.session
        for a in s.pendingApprovals {
            let key = "ap." + a.id
            c.items.append(ItemSpec(key: key, sig: sig(a.id), gapBefore: 14) {
                let title = NSAttributedString(string: a.title, attributes: [.font: Theme.bodyBold, .foregroundColor: Theme.text])
                let detail = TextEl(NSAttributedString(string: a.detail, attributes: [.font: Theme.monoSmall, .foregroundColor: Theme.secondaryText, .paragraphStyle: Markdown.paragraphStyle(MDStyle(lineSpacing: 3))]), maxLines: 12)
                return BoxEl(VStackEl([
                    RowEl(icon: "exclamationmark.shield", title: "Approval required", subtitle: s.permission.label + " mode", key: key + ".h", hit: nil, titleColor: Theme.warning, titleFont: Theme.smallFont, height: 22),
                    TextEl(title),
                    BoxEl(detail, padding: NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10), background: Theme.codeBackground, border: Theme.codeBorder, radius: 8),
                    ButtonRowEl([
                        ButtonEl("Allow once", symbol: "checkmark", style: .primary, action: .approve(a.id, .allowOnce), key: key + ".once"),
                        ButtonEl("Allow for session", style: .secondary, action: .approve(a.id, .allowSession), key: key + ".session"),
                        ButtonEl("Deny", style: .danger, action: .approve(a.id, .deny), key: key + ".deny"),
                    ]),
                ], spacing: 10), padding: NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16), background: Theme.cardBackground, border: Theme.cardBorder, radius: 14)
            })
        }
        for q in s.pendingQuestions {
            let key = "q." + q.id
            let selected = q.questions.map { c.state.selectedOptions[q.id + "/" + $0.id] ?? [] }
            let immediate = q.questions.count == 1 && !q.questions[0].multiSelect
            c.items.append(ItemSpec(key: key, sig: sig(q.id, selected.map { $0.sorted() }), gapBefore: 14) {
                var children: [Element] = []
                for (qi, qq) in q.questions.enumerated() {
                    if qi > 0 { children.append(SpacerEl(6)) }
                    if let h = qq.header, !h.isEmpty {
                        children.append(TextEl(NSAttributedString(string: h.uppercased(), attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: Theme.tertiaryText, .kern: 0.6])))
                    }
                    children.append(TextEl(Markdown.inline(qq.question, style: MDStyle(font: Theme.bodyBold, color: Theme.text, lineSpacing: 5))))
                    for o in qq.options {
                        children.append(OptionEl(label: o.label, detail: o.description, selected: selected[qi].contains(o.label), multi: qq.multiSelect,
                                                 action: .chooseOption(request: q.id, question: qq.id, label: o.label), key: key + "/" + qq.id + "/" + o.label))
                    }
                }
                children.append(TextEl(NSAttributedString(string: "You can also type an answer in the message box.", attributes: [.font: Theme.captionFont, .foregroundColor: Theme.tertiaryText])))
                var buttons: [ButtonEl] = []
                if !immediate || q.questions[0].options.isEmpty == false && !immediate {
                    buttons.append(ButtonEl("Submit", symbol: "arrow.up", style: .primary, action: .submitAnswers(q.id), key: key + ".submit"))
                }
                buttons.append(ButtonEl("Dismiss", style: .plain, action: .dismissQuestion(q.id), key: key + ".dismiss"))
                children.append(ButtonRowEl(buttons))
                return BoxEl(VStackEl(children, spacing: 8), padding: NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16), background: Theme.cardBackground, border: Theme.cardBorder, radius: 14)
            })
        }
        for (i, text) in s.queuedInputs.enumerated() {
            let key = "queued.\(i)"
            c.items.append(ItemSpec(key: key, sig: sig(text), gapBefore: 16) {
                VStackEl([
                    UserBubbleEl(text: text, time: "Queued", key: key, faded: true),
                ])
            })
        }
    }
}

/// Card for a presented deliverable file.
final class FileCardEl: Element {
    let path: String
    let detail: String
    let key: String
    init(path: String, detail: String, key: String) { self.path = path; self.detail = detail; self.key = key }
    override func layout(width: CGFloat) -> CGSize { size = CGSize(width: min(width, 520), height: 58); return size }
    override func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) {
        let r = CGRect(origin: o, size: size)
        fillRounded(ctx, r, 12, env.hoverKey == key ? Theme.hover : Theme.cardBackground)
        strokeRounded(ctx, r, 12, Theme.cardBorder)
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.draw(in: CGRect(x: o.x + 12, y: o.y + 13, width: 32, height: 32), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        drawLabel((path as NSString).lastPathComponent, in: CGRect(x: o.x + 54, y: o.y + 9, width: size.width - 110, height: 20), font: Theme.bodyBold, color: Theme.text)
        drawLabel(detail.isEmpty ? ToolPresentation.shortPath(path, cwd: nil) : detail, in: CGRect(x: o.x + 54, y: o.y + 29, width: size.width - 110, height: 18), font: Theme.captionFont, color: Theme.tertiaryText)
        drawLabel("Open", in: CGRect(x: o.x + size.width - 56, y: o.y, width: 44, height: size.height), font: Theme.smallFont, color: Theme.accent, alignment: .right)
    }
    override func hit(_ p: CGPoint) -> HitResult? { HitResult(hit: .openFile(path), rect: CGRect(origin: .zero, size: size), key: key) }
}
