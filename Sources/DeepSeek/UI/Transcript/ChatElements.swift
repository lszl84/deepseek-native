import AppKit

final class UserBubbleEl: Element {
    let text: TextLayout
    let key: String
    let time: String
    let raw: String
    let faded: Bool
    let images: [String]
    private var bubble: CGRect = .zero
    private let padX: CGFloat = 16, padY: CGFloat = 8
    private let metaH: CGFloat = 26

    init(text: String, time: String, key: String, faded: Bool = false, images: [String] = []) {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 5
        p.lineBreakMode = .byWordWrapping
        let s = NSAttributedString(string: text, attributes: [.font: Theme.bodyFont, .foregroundColor: faded ? Theme.tertiaryText : Theme.text, .paragraphStyle: p])
        self.text = TextLayout(s)
        self.key = key
        self.time = time
        self.raw = text
        self.faded = faded
        self.images = images
    }

    override func layout(width: CGFloat) -> CGSize {
        let maxW = min(width * 0.8, 620)
        let t = text.layout(width: maxW - padX * 2)
        let w = max(t.width, 20) + padX * 2
        let h = t.height + padY * 2 + 6
        bubble = CGRect(x: width - w, y: 0, width: w, height: h)
        size = CGSize(width: width, height: h + metaH)
        return size
    }

    private var copyRect: CGRect { CGRect(x: bubble.maxX - 28, y: bubble.maxY + 3, width: 24, height: 22) }

    override func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) {
        let b = bubble.offsetBy(dx: o.x, dy: o.y)
        fillRounded(ctx, b, 20, faded ? Theme.userBubble.withAlphaComponent(0.5) : Theme.userBubble)
        text.draw(in: ctx, at: CGPoint(x: b.minX + padX, y: b.minY + padY + 3), clip: clip, selection: env.selection[ObjectIdentifier(text)], selectionColor: Theme.selection)
        if env.hoverItem == key || env.hoverKey == key + ".copy" {
            let cr = copyRect.offsetBy(dx: o.x, dy: o.y)
            if env.hoverKey == key + ".copy" { fillRounded(ctx, cr, 6, Theme.hover) }
            drawIcon(env.copiedKey == key ? "checkmark" : "doc.on.doc", in: cr, size: 12, color: Theme.tertiaryText, ctx: ctx)
            drawLabel(time, in: CGRect(x: cr.minX - 60, y: cr.minY, width: 54, height: cr.height), font: Theme.captionFont, color: Theme.tertiaryText, alignment: .right)
        }
    }

    override func hit(_ p: CGPoint) -> HitResult? {
        if copyRect.contains(p) { return HitResult(hit: .copy(raw, key: key), rect: copyRect, key: key + ".copy") }
        if let link = text.attribute(.mdLink, at: CGPoint(x: p.x - bubble.minX - padX, y: p.y - padY - 3)) as? String {
            return HitResult(hit: .link(link), rect: .zero, key: "link:" + link)
        }
        return nil
    }

    override func texts(_ o: CGPoint, _ out: inout [TextRef]) {
        out.append(TextRef(layout: text, origin: CGPoint(x: o.x + bubble.minX + padX, y: o.y + padY + 3)))
    }
}

/// "Took 12s" / "Working 5s" line with a hairline underneath.
final class TurnHeaderEl: Element {
    let label: String
    let color: NSColor
    let spinning: Bool
    /// When set, " · <elapsed>" is appended at draw time.
    let liveSince: Double?
    init(label: String, color: NSColor = Theme.tertiaryText, spinning: Bool = false, liveSince: Double? = nil) {
        self.label = label
        self.color = color
        self.spinning = spinning
        self.liveSince = liveSince
    }
    override func layout(width: CGFloat) -> CGSize { size = CGSize(width: width, height: 40); return size }
    override func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) {
        var x = o.x
        if spinning {
            drawSpinner(ctx, center: CGPoint(x: x + 6, y: o.y + 14), radius: 5, phase: env.spinnerPhase, color: Theme.tertiaryText)
            x += 18
        }
        let text = liveSince.map { label + " · " + Fmt.duration(Date().timeIntervalSince1970 - $0) } ?? label
        drawLabel(text, in: CGRect(x: x, y: o.y + 2, width: size.width - (x - o.x), height: 24), font: Theme.smallFont, color: color)
        ctx.setFillColor(Theme.separator.cgColor)
        ctx.fill(CGRect(x: o.x, y: o.y + 39, width: size.width, height: 1))
    }
    override var animating: Bool { spinning }
}

/// A clickable single-line row: icon, title, subtitle, trailing status.
final class RowEl: Element {
    enum Trailing { case none, spinner, text(String, NSColor), diff(Int, Int), icon(String, NSColor) }
    let icon: String
    let title: String
    let subtitle: String
    let trailing: Trailing
    let key: String
    let hitAction: Hit?
    let expanded: Bool?
    let titleColor: NSColor
    let titleFont: NSFont
    let height: CGFloat

    init(icon: String, title: String, subtitle: String = "", trailing: Trailing = .none, key: String, hit: Hit?, expanded: Bool? = nil,
         titleColor: NSColor = Theme.secondaryText, titleFont: NSFont = Theme.bodyFont, height: CGFloat = 30) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.key = key
        self.hitAction = hit
        self.expanded = expanded
        self.titleColor = titleColor
        self.titleFont = titleFont
        self.height = height
    }

    override func layout(width: CGFloat) -> CGSize { size = CGSize(width: width, height: height); return size }

    override func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) {
        let hovered = env.hoverKey == key
        let r = CGRect(x: o.x - 6, y: o.y + 1, width: size.width + 12, height: size.height - 2)
        if hovered && hitAction != nil { fillRounded(ctx, r, 8, Theme.hover) }
        let iconRect = CGRect(x: o.x, y: o.y, width: 16, height: size.height)
        let showChevron = expanded != nil && (hovered || expanded == true)
        if showChevron {
            drawIcon(expanded == true ? "chevron.up" : "chevron.down", in: iconRect, size: 10, color: Theme.tertiaryText, weight: .semibold, ctx: ctx)
        } else {
            drawIcon(icon, in: iconRect, size: 12, color: Theme.tertiaryText, ctx: ctx)
        }
        var x = o.x + 22
        var trailingW: CGFloat = 0
        switch trailing {
        case .none: break
        case .spinner: trailingW = 20
        case .text(let s, _): trailingW = textWidth(s, Theme.captionFont) + 8
        case .diff(let a, let d): trailingW = textWidth("+\(a) −\(d)", Theme.captionFont) + 8
        case .icon: trailingW = 20
        }
        let avail = size.width - (x - o.x) - trailingW
        let tw = min(textWidth(title, titleFont), avail)
        drawLabel(title, in: CGRect(x: x, y: o.y, width: tw + 1, height: size.height), font: titleFont, color: titleColor)
        x += tw
        if !subtitle.isEmpty && avail - tw > 30 {
            drawLabel("  ·  " + subtitle, in: CGRect(x: x, y: o.y, width: avail - tw, height: size.height), font: Theme.smallFont, color: Theme.tertiaryText)
        }
        let tx = o.x + size.width - trailingW
        switch trailing {
        case .none: break
        case .spinner: drawSpinner(ctx, center: CGPoint(x: o.x + size.width - 8, y: o.y + size.height / 2), radius: 5, phase: env.spinnerPhase, color: Theme.tertiaryText)
        case .text(let s, let c): drawLabel(s, in: CGRect(x: tx, y: o.y, width: trailingW, height: size.height), font: Theme.captionFont, color: c, alignment: .right)
        case .diff(let a, let d):
            let add = "+\(a)", rem = " −\(d)"
            let wa = textWidth(add, Theme.captionFont)
            drawLabel(add, in: CGRect(x: tx + 8, y: o.y, width: wa + 2, height: size.height), font: Theme.captionFont, color: Theme.diffAddText)
            drawLabel(rem, in: CGRect(x: tx + 8 + wa, y: o.y, width: trailingW, height: size.height), font: Theme.captionFont, color: Theme.diffRemoveText)
        case .icon(let n, let c): drawIcon(n, in: CGRect(x: o.x + size.width - 16, y: o.y, width: 16, height: size.height), size: 12, color: c, ctx: ctx)
        }
    }

    override func hit(_ p: CGPoint) -> HitResult? {
        guard let hitAction else { return nil }
        return HitResult(hit: hitAction, rect: CGRect(x: -6, y: 1, width: size.width + 12, height: size.height - 2), key: key)
    }

    override var animating: Bool { if case .spinner = trailing { return true }; return false }
}

/// Push-button drawn in the transcript.
final class ButtonEl: Element {
    enum Style { case primary, secondary, plain, danger }
    let title: String
    let symbol: String?
    let style: Style
    let action: Hit
    let key: String
    init(_ title: String, symbol: String? = nil, style: Style = .secondary, action: Hit, key: String) {
        self.title = title
        self.symbol = symbol
        self.style = style
        self.action = action
        self.key = key
    }
    var intrinsicWidth: CGFloat { textWidth(title, Theme.smallFont) + (symbol == nil ? 24 : 42) }
    override func layout(width: CGFloat) -> CGSize { size = CGSize(width: min(width, intrinsicWidth), height: 30); return size }
    override func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) {
        let r = CGRect(origin: o, size: size)
        let hovered = env.hoverKey == key
        var fg = Theme.text
        switch style {
        case .primary:
            fillRounded(ctx, r, 9, hovered ? Theme.accent.blended(withFraction: 0.12, of: .black)! : Theme.accent)
            fg = .white
        case .secondary:
            fillRounded(ctx, r, 9, hovered ? Theme.pressed : Theme.hover)
        case .plain:
            if hovered { fillRounded(ctx, r, 9, Theme.hover) }
            fg = Theme.secondaryText
        case .danger:
            fillRounded(ctx, r, 9, hovered ? Theme.errorSoft.blended(withFraction: 0.3, of: Theme.error)! : Theme.errorSoft)
            fg = Theme.error
        }
        var x = r.minX + 12
        if let symbol {
            drawIcon(symbol, in: CGRect(x: x, y: r.minY, width: 14, height: r.height), size: 11, color: fg, weight: .medium, ctx: ctx)
            x += 18
        }
        drawLabel(title, in: CGRect(x: x, y: r.minY, width: r.maxX - x - 8, height: r.height), font: Theme.smallFont, color: fg)
    }
    override func hit(_ p: CGPoint) -> HitResult? { HitResult(hit: action, rect: CGRect(origin: .zero, size: size), key: key) }
}

final class ButtonRowEl: Element {
    let buttons: [ButtonEl]
    let spacing: CGFloat = 8
    private var xs: [CGFloat] = []
    init(_ buttons: [ButtonEl]) { self.buttons = buttons }
    override func layout(width: CGFloat) -> CGSize {
        xs = []
        var x: CGFloat = 0
        for b in buttons { xs.append(x); x += b.layout(width: width).width + spacing }
        size = CGSize(width: width, height: 30)
        return size
    }
    override func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) {
        for (i, b) in buttons.enumerated() { b.draw(ctx, CGPoint(x: o.x + xs[i], y: o.y), env, clip) }
    }
    override func hit(_ p: CGPoint) -> HitResult? {
        for (i, b) in buttons.enumerated() where p.x >= xs[i] && p.x < xs[i] + b.size.width {
            guard let h = b.hit(CGPoint(x: p.x - xs[i], y: p.y)) else { return nil }
            return HitResult(hit: h.hit, rect: h.rect.offsetBy(dx: xs[i], dy: 0), key: h.key)
        }
        return nil
    }
}

/// Assistant turn footer: copy · usage · time.
final class FooterEl: Element {
    let copyText: String
    let usage: String
    let time: String
    let key: String
    init(copyText: String, usage: String, time: String, key: String) {
        self.copyText = copyText
        self.usage = usage
        self.time = time
        self.key = key
    }
    override func layout(width: CGFloat) -> CGSize { size = CGSize(width: width, height: 32); return size }
    private var copyRect: CGRect { CGRect(x: -4, y: 4, width: 26, height: 24) }
    override func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) {
        let cr = copyRect.offsetBy(dx: o.x, dy: o.y)
        if env.hoverKey == key { fillRounded(ctx, cr, 6, Theme.hover) }
        drawIcon(env.copiedKey == key ? "checkmark" : "doc.on.doc", in: cr, size: 12, color: Theme.tertiaryText, ctx: ctx)
        var x = o.x + 34
        if !usage.isEmpty {
            drawIcon("cylinder", in: CGRect(x: x, y: o.y + 4, width: 14, height: 24), size: 11, color: Theme.tertiaryText, ctx: ctx)
            x += 20
            let s = "Usage " + usage
            drawLabel(s, in: CGRect(x: x, y: o.y + 4, width: 200, height: 24), font: Theme.captionFont, color: Theme.tertiaryText)
            x += textWidth(s, Theme.captionFont) + 16
        }
        drawLabel(time, in: CGRect(x: x, y: o.y + 4, width: 100, height: 24), font: Theme.captionFont, color: Theme.tertiaryText)
    }
    override func hit(_ p: CGPoint) -> HitResult? {
        copyRect.contains(p) ? HitResult(hit: .copy(copyText, key: key), rect: copyRect, key: key) : nil
    }
}

/// Monospaced text inside a rounded box, with an optional heading line; used for tool details.
final class DetailBoxEl: Element {
    let stack: VStackEl
    let box: BoxEl
    init(_ children: [Element]) {
        stack = VStackEl(children, spacing: 8)
        box = BoxEl(stack, padding: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12), background: Theme.codeBackground, border: Theme.codeBorder, radius: 10)
    }
    override func layout(width: CGFloat) -> CGSize { size = box.layout(width: width); return size }
    override func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) { box.draw(ctx, o, env, clip) }
    override func hit(_ p: CGPoint) -> HitResult? { box.hit(p) }
    override func texts(_ o: CGPoint, _ out: inout [TextRef]) { box.texts(o, &out) }
    override var animating: Bool { box.animating }
}

/// Diff view for edit/write tool details.
final class DiffEl: Element {
    struct Line { let text: String; let kind: Int } // -1 removed, 0 context, 1 added
    let text: TextLayout
    let lines: [Line]
    private var starts: [Int] = []
    init(lines: [Line]) {
        self.lines = lines
        var loc = 0
        for l in lines { starts.append(loc); loc += (l.text as NSString).length + 3 }
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        p.lineBreakMode = .byCharWrapping
        let s = NSMutableAttributedString()
        for (i, l) in lines.enumerated() {
            let prefix = l.kind < 0 ? "- " : (l.kind > 0 ? "+ " : "  ")
            let color = l.kind < 0 ? Theme.diffRemoveText : (l.kind > 0 ? Theme.diffAddText : Theme.secondaryText)
            s.append(NSAttributedString(string: prefix + l.text + (i < lines.count - 1 ? "\n" : ""), attributes: [.font: Theme.monoSmall, .foregroundColor: color, .paragraphStyle: p]))
        }
        text = TextLayout(s)
    }
    override func layout(width: CGFloat) -> CGSize {
        size = CGSize(width: width, height: text.layout(width: width - 16).height + 12)
        return size
    }
    override func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) {
        let r = CGRect(origin: o, size: size)
        fillRounded(ctx, r, 10, Theme.codeBackground)
        // Line backgrounds
        for tl in text.lines {
            if o.y + tl.bottom < clip.minY { continue }
            if o.y + tl.top > clip.maxY { break }
            // Binary search the source line containing this visual line.
            var lo = 0, hi = starts.count - 1
            while lo < hi { let mid = (lo + hi + 1) / 2; if starts[mid] <= tl.range.location { lo = mid } else { hi = mid - 1 } }
            let li = lo
            guard li < lines.count else { continue }
            let kind = lines[li].kind
            if kind != 0 {
                ctx.setFillColor((kind > 0 ? Theme.diffAdd : Theme.diffRemove).cgColor)
                ctx.fill(CGRect(x: o.x + 1, y: o.y + 6 + tl.top - 1.5, width: size.width - 2, height: tl.bottom - tl.top + 3))
            }
        }
        strokeRounded(ctx, r, 10, Theme.codeBorder)
        text.draw(in: ctx, at: CGPoint(x: o.x + 8, y: o.y + 6), clip: clip, selection: env.selection[ObjectIdentifier(text)], selectionColor: Theme.selection)
    }
    override func texts(_ o: CGPoint, _ out: inout [TextRef]) { out.append(TextRef(layout: text, origin: CGPoint(x: o.x + 8, y: o.y + 6))) }
}

/// Indented container used for tool detail panes under a row.
final class IndentEl: Element {
    let child: Element
    let left: CGFloat
    init(_ child: Element, left: CGFloat = 22) { self.child = child; self.left = left }
    override func layout(width: CGFloat) -> CGSize {
        size = CGSize(width: width, height: child.layout(width: width - left).height)
        return size
    }
    override func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) { child.draw(ctx, CGPoint(x: o.x + left, y: o.y), env, clip) }
    override func hit(_ p: CGPoint) -> HitResult? {
        guard let h = child.hit(CGPoint(x: p.x - left, y: p.y)) else { return nil }
        return HitResult(hit: h.hit, rect: h.rect.offsetBy(dx: left, dy: 0), key: h.key)
    }
    override func texts(_ o: CGPoint, _ out: inout [TextRef]) { child.texts(CGPoint(x: o.x + left, y: o.y), &out) }
    override var animating: Bool { child.animating }
}

/// Selectable option row in a question card.
final class OptionEl: Element {
    let label: String
    let detail: String?
    let selected: Bool
    let multi: Bool
    let action: Hit
    let key: String
    private let detailLayout: TextLayout?
    init(label: String, detail: String?, selected: Bool, multi: Bool, action: Hit, key: String) {
        self.label = label
        self.detail = detail
        self.selected = selected
        self.multi = multi
        self.action = action
        self.key = key
        detailLayout = detail.map { TextLayout(NSAttributedString(string: $0, attributes: [.font: Theme.captionFont, .foregroundColor: Theme.tertiaryText])) }
    }
    override func layout(width: CGFloat) -> CGSize {
        let dh = detailLayout?.layout(width: width - 44).height ?? 0
        size = CGSize(width: width, height: 34 + (dh > 0 ? dh + 2 : 0))
        return size
    }
    override func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) {
        let r = CGRect(origin: o, size: size)
        fillRounded(ctx, r, 10, selected ? Theme.accentSoft : (env.hoverKey == key ? Theme.hover : .clear))
        strokeRounded(ctx, r, 10, selected ? Theme.accent : Theme.cardBorder)
        let ind = CGRect(x: o.x + 12, y: o.y + 10, width: 14, height: 14)
        if multi {
            if selected { fillRounded(ctx, ind, 4, Theme.accent); drawIcon("checkmark", in: ind, size: 9, color: .white, weight: .bold, ctx: ctx) }
            else { strokeRounded(ctx, ind, 4, Theme.tertiaryText, width: 1.2) }
        } else {
            ctx.setStrokeColor((selected ? Theme.accent : Theme.tertiaryText).cgColor)
            ctx.setLineWidth(1.2)
            ctx.strokeEllipse(in: ind.insetBy(dx: 0.6, dy: 0.6))
            if selected { ctx.setFillColor(Theme.accent.cgColor); ctx.fillEllipse(in: ind.insetBy(dx: 3.5, dy: 3.5)) }
        }
        drawLabel(label, in: CGRect(x: o.x + 34, y: o.y + 5, width: size.width - 44, height: 24), font: Theme.bodyFont, color: Theme.text)
        detailLayout?.draw(in: ctx, at: CGPoint(x: o.x + 34, y: o.y + 29), clip: clip)
    }
    override func hit(_ p: CGPoint) -> HitResult? { HitResult(hit: action, rect: CGRect(origin: .zero, size: size), key: key) }
}
