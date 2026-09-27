import AppKit

/// Result of clicking an interactive transcript element.
enum Hit: Equatable {
    case toggle(String)
    case copy(String, key: String)
    case link(String)
    case approve(String, ApprovalDecision)
    case chooseOption(request: String, question: String, label: String)
    case submitAnswers(String)
    case dismissQuestion(String)
    case openFile(String)
    case retry
    case cancelQueued(Int)
}

/// Per-draw state shared by elements.
final class DrawEnv {
    var hoverKey: String?
    var hoverItem: String?
    var selection: [ObjectIdentifier: NSRange] = [:]
    var spinnerPhase: CGFloat = 0
    var copiedKey: String?
    var pressedKey: String?
    var selectedOptions: [String: Set<String>] = [:] // "request/question" -> labels
}

struct TextRef {
    let layout: TextLayout
    let origin: CGPoint
}

struct HitResult {
    let hit: Hit
    let rect: CGRect  // local rect for hover feedback
    let key: String
}

/// A laid-out, drawable piece of transcript content. Coordinates are flipped (y down), relative to the element's top-left.
class Element {
    var size: CGSize = .zero
    func layout(width: CGFloat) -> CGSize { size = CGSize(width: width, height: 0); return size }
    func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) {}
    func hit(_ p: CGPoint) -> HitResult? { nil }
    func texts(_ o: CGPoint, _ out: inout [TextRef]) {}
    /// Whether this element shows an animation (spinner) and needs periodic redraw.
    var animating: Bool { false }
}

// MARK: - Icons

enum Icons {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
        let key = "\(name)|\(size)|\(weight.rawValue)"
        if let i = cache[key] { return i }
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
        img.isTemplate = true
        cache[key] = img
        return img
    }

    /// Symbol pre-tinted with a resolved color, cached; drawing it needs no offscreen compositing.
    static func tinted(_ name: String, size: CGFloat, color: NSColor, weight: NSFont.Weight) -> NSImage? {
        let c = color.usingColorSpace(.sRGB) ?? color
        let key = String(format: "%@|%.1f|%.2f|%.3f,%.3f,%.3f,%.3f", name, size, weight.rawValue, c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent)
        if let i = cache[key] { return i }
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight).applying(NSImage.SymbolConfiguration(paletteColors: [c]))
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
        if cache.count > 400 { cache.removeAll() }
        cache[key] = img
        return img
    }

    /// Draws a symbol tinted with `color`, centered in `rect`.
    static func draw(_ name: String, in rect: CGRect, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular, ctx: CGContext) {
        guard let img = tinted(name, size: size, color: color, weight: weight) else { return }
        let s = img.size
        let r = CGRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height).integral
        img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

func drawIcon(_ name: String, in rect: CGRect, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular, ctx: CGContext) {
    Icons.draw(name, in: rect, size: size, color: color, weight: weight, ctx: ctx)
}

func drawSpinner(_ ctx: CGContext, center: CGPoint, radius: CGFloat, phase: CGFloat, color: NSColor) {
    ctx.saveGState()
    ctx.setLineWidth(1.6)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(color.withAlphaComponent(0.2).cgColor)
    ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    ctx.setStrokeColor(color.cgColor)
    let a = phase * .pi * 2
    ctx.addArc(center: center, radius: radius, startAngle: a, endAngle: a + .pi * 0.6, clockwise: false)
    ctx.strokePath()
    ctx.restoreGState()
}

func fillRounded(_ ctx: CGContext, _ r: CGRect, _ radius: CGFloat, _ color: NSColor) {
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(radius, r.height / 2), cornerHeight: min(radius, r.height / 2), transform: nil))
    ctx.setFillColor(color.cgColor)
    ctx.fillPath()
}

func strokeRounded(_ ctx: CGContext, _ r: CGRect, _ radius: CGFloat, _ color: NSColor, width: CGFloat = 1) {
    let rr = r.insetBy(dx: width / 2, dy: width / 2)
    ctx.addPath(CGPath(roundedRect: rr, cornerWidth: min(radius, rr.height / 2), cornerHeight: min(radius, rr.height / 2), transform: nil))
    ctx.setStrokeColor(color.cgColor)
    ctx.setLineWidth(width)
    ctx.strokePath()
}

func drawString(_ s: String, at p: CGPoint, font: NSFont, color: NSColor) {
    (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
}

/// Draws a single line truncated to `width`.
func drawLabel(_ s: String, in r: CGRect, font: NSFont, color: NSColor, alignment: NSTextAlignment = .left) {
    let p = NSMutableParagraphStyle()
    p.lineBreakMode = .byTruncatingTail
    p.alignment = alignment
    let h = ceil(font.ascender - font.descender)
    let rr = CGRect(x: r.minX, y: r.midY - h / 2 - 0.5, width: r.width, height: h + 2)
    (s as NSString).draw(with: rr, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                         attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
}

// MARK: - Basic elements

final class TextEl: Element {
    let text: TextLayout
    var insets: NSEdgeInsets

    init(_ s: NSAttributedString, insets: NSEdgeInsets = NSEdgeInsets(), maxLines: Int = 0) {
        text = TextLayout(s, maxLines: maxLines)
        self.insets = insets
    }

    override func layout(width: CGFloat) -> CGSize {
        let s = text.layout(width: max(10, width - insets.left - insets.right))
        size = CGSize(width: width, height: s.height + insets.top + insets.bottom)
        return size
    }

    override func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) {
        let origin = CGPoint(x: o.x + insets.left, y: o.y + insets.top)
        text.draw(in: ctx, at: origin, clip: clip, selection: env.selection[ObjectIdentifier(text)], selectionColor: Theme.selection)
    }

    override func hit(_ p: CGPoint) -> HitResult? {
        let lp = CGPoint(x: p.x - insets.left, y: p.y - insets.top)
        if let link = text.attribute(.mdLink, at: lp) as? String {
            return HitResult(hit: .link(link), rect: .zero, key: "link:" + link)
        }
        return nil
    }

    override func texts(_ o: CGPoint, _ out: inout [TextRef]) {
        out.append(TextRef(layout: text, origin: CGPoint(x: o.x + insets.left, y: o.y + insets.top)))
    }
}

final class SpacerEl: Element {
    let h: CGFloat
    init(_ h: CGFloat) { self.h = h }
    override func layout(width: CGFloat) -> CGSize { size = CGSize(width: width, height: h); return size }
}

final class RuleEl: Element {
    let margin: CGFloat
    init(margin: CGFloat = 12) { self.margin = margin }
    override func layout(width: CGFloat) -> CGSize { size = CGSize(width: width, height: margin * 2 + 1); return size }
    override func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) {
        ctx.setFillColor(Theme.separator.cgColor)
        ctx.fill(CGRect(x: o.x, y: o.y + margin, width: size.width, height: 1))
    }
}

/// Vertical stack of children with spacing and insets.
class VStackEl: Element {
    var children: [Element]
    var spacing: CGFloat
    var insets: NSEdgeInsets
    private(set) var offsets: [CGFloat] = []

    init(_ children: [Element], spacing: CGFloat = 0, insets: NSEdgeInsets = NSEdgeInsets()) {
        self.children = children
        self.spacing = spacing
        self.insets = insets
    }

    override func layout(width: CGFloat) -> CGSize {
        var y = insets.top
        offsets = []
        let inner = width - insets.left - insets.right
        for (i, c) in children.enumerated() {
            if i > 0 { y += spacing }
            offsets.append(y)
            y += c.layout(width: inner).height
        }
        size = CGSize(width: width, height: y + insets.bottom)
        return size
    }

    override func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) {
        for (i, c) in children.enumerated() {
            let y = o.y + offsets[i]
            if y > clip.maxY { break }
            if y + c.size.height < clip.minY { continue }
            c.draw(ctx, CGPoint(x: o.x + insets.left, y: y), env, clip)
        }
    }

    override func hit(_ p: CGPoint) -> HitResult? {
        for (i, c) in children.enumerated() {
            let y = offsets[i]
            if p.y >= y && p.y < y + c.size.height {
                if let h = c.hit(CGPoint(x: p.x - insets.left, y: p.y - y)) {
                    return HitResult(hit: h.hit, rect: h.rect.offsetBy(dx: insets.left, dy: y), key: h.key)
                }
                return nil
            }
        }
        return nil
    }

    override func texts(_ o: CGPoint, _ out: inout [TextRef]) {
        for (i, c) in children.enumerated() { c.texts(CGPoint(x: o.x + insets.left, y: o.y + offsets[i]), &out) }
    }

    override var animating: Bool { children.contains { $0.animating } }
}

/// Background/border decoration around a child.
final class BoxEl: Element {
    let child: Element
    let padding: NSEdgeInsets
    let background: NSColor?
    let border: NSColor?
    let radius: CGFloat

    init(_ child: Element, padding: NSEdgeInsets, background: NSColor?, border: NSColor? = nil, radius: CGFloat = 10) {
        self.child = child
        self.padding = padding
        self.background = background
        self.border = border
        self.radius = radius
    }

    override func layout(width: CGFloat) -> CGSize {
        let c = child.layout(width: width - padding.left - padding.right)
        size = CGSize(width: width, height: c.height + padding.top + padding.bottom)
        return size
    }

    override func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) {
        let r = CGRect(origin: o, size: size)
        if let background { fillRounded(ctx, r, radius, background) }
        if let border { strokeRounded(ctx, r, radius, border) }
        child.draw(ctx, CGPoint(x: o.x + padding.left, y: o.y + padding.top), env, clip)
    }

    override func hit(_ p: CGPoint) -> HitResult? {
        guard let h = child.hit(CGPoint(x: p.x - padding.left, y: p.y - padding.top)) else { return nil }
        return HitResult(hit: h.hit, rect: h.rect.offsetBy(dx: padding.left, dy: padding.top), key: h.key)
    }

    override func texts(_ o: CGPoint, _ out: inout [TextRef]) {
        child.texts(CGPoint(x: o.x + padding.left, y: o.y + padding.top), &out)
    }

    override var animating: Bool { child.animating }
}

// MARK: - Markdown elements

final class CodeBlockEl: Element {
    let lang: String
    let code: String
    let body: TextLayout
    let key: String
    private let headerH: CGFloat = 32
    private let pad: CGFloat = 14

    init(lang: String, code: String, key: String) {
        self.lang = lang
        self.code = code
        self.key = key
        body = TextLayout(Syntax.highlight(code.isEmpty ? " " : code, lang: lang))
    }

    override func layout(width: CGFloat) -> CGSize {
        let s = body.layout(width: width - pad * 2)
        size = CGSize(width: width, height: headerH + s.height + pad + 2)
        return size
    }

    private var copyRect: CGRect { CGRect(x: size.width - 72, y: 4, width: 66, height: 24) }

    override func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) {
        let r = CGRect(origin: o, size: size)
        fillRounded(ctx, r, 12, Theme.codeBackground)
        strokeRounded(ctx, r, 12, Theme.codeBorder)
        drawLabel(lang.isEmpty ? "text" : lang, in: CGRect(x: o.x + pad, y: o.y, width: 200, height: headerH), font: Theme.captionFont, color: Theme.tertiaryText)
        let cr = copyRect.offsetBy(dx: o.x, dy: o.y)
        let copied = env.copiedKey == key
        if env.hoverKey == key { fillRounded(ctx, cr, 6, Theme.hover) }
        drawIcon(copied ? "checkmark" : "doc.on.doc", in: CGRect(x: cr.minX + 4, y: cr.minY, width: 18, height: cr.height), size: 11, color: Theme.tertiaryText, ctx: ctx)
        drawLabel(copied ? "Copied" : "Copy", in: CGRect(x: cr.minX + 24, y: cr.minY, width: 44, height: cr.height), font: Theme.captionFont, color: Theme.tertiaryText)
        body.draw(in: ctx, at: CGPoint(x: o.x + pad, y: o.y + headerH), clip: clip, selection: env.selection[ObjectIdentifier(body)], selectionColor: Theme.selection)
    }

    override func hit(_ p: CGPoint) -> HitResult? {
        if copyRect.contains(p) { return HitResult(hit: .copy(code, key: key), rect: copyRect, key: key) }
        return nil
    }

    override func texts(_ o: CGPoint, _ out: inout [TextRef]) {
        out.append(TextRef(layout: body, origin: CGPoint(x: o.x + pad, y: o.y + headerH)))
    }
}

final class TableEl: Element {
    let header: [TextLayout]
    let rows: [[TextLayout]]
    let aligns: [NSTextAlignment]
    private var colX: [CGFloat] = []
    private var colW: [CGFloat] = []
    private var rowY: [CGFloat] = []
    private var rowH: [CGFloat] = []
    private let padX: CGFloat = 12, padY: CGFloat = 8

    init(header: [NSAttributedString], rows: [[NSAttributedString]], aligns: [NSTextAlignment]) {
        let cols = max(header.count, rows.map { $0.count }.max() ?? 0)
        func pad(_ r: [NSAttributedString]) -> [NSAttributedString] { r + Array(repeating: NSAttributedString(string: ""), count: max(0, cols - r.count)) }
        func align(_ s: NSAttributedString, _ i: Int) -> NSAttributedString {
            guard i < aligns.count, aligns[i] != .left else { return s }
            let m = NSMutableAttributedString(attributedString: s)
            let p = NSMutableParagraphStyle()
            p.alignment = aligns[i]
            p.lineSpacing = 4
            m.addAttribute(.paragraphStyle, value: p, range: NSRange(location: 0, length: m.length))
            return m
        }
        self.header = pad(header).enumerated().map { TextLayout(align($0.element, $0.offset)) }
        self.rows = rows.map { pad($0).enumerated().map { TextLayout(align($0.element, $0.offset)) } }
        self.aligns = aligns
    }

    override func layout(width: CGFloat) -> CGSize {
        let cols = header.count
        guard cols > 0 else { size = .zero; return size }
        // Natural widths from unconstrained layout; minimum widths from the longest word.
        var natural = [CGFloat](repeating: 30, count: cols)
        var minW = [CGFloat](repeating: 40, count: cols)
        for row in [header] + rows {
            for (i, c) in row.enumerated() {
                natural[i] = max(natural[i], c.layout(width: 10_000).width + padX * 2)
                minW[i] = max(minW[i], min(180, TableEl.longestWord(c.string) + padX * 2))
            }
        }
        let total = natural.reduce(0, +)
        let minTotal = minW.reduce(0, +)
        if total <= width {
            colW = natural
        } else if minTotal >= width {
            colW = minW.map { $0 * width / minTotal }
        } else {
            let extra = width - minTotal
            let flex = zip(natural, minW).map { max(0, $0 - $1) }
            let flexTotal = max(1, flex.reduce(0, +))
            colW = zip(minW, flex).map { $0 + extra * $1 / flexTotal }
        }
        colX = []
        var x: CGFloat = 0
        for w in colW { colX.append(x); x += w }
        rowY = []; rowH = []
        var y: CGFloat = 0
        for row in [header] + rows {
            var h: CGFloat = 0
            for (i, c) in row.enumerated() { h = max(h, c.layout(width: colW[i] - padX * 2).height) }
            rowY.append(y); rowH.append(h + padY * 2)
            y += h + padY * 2
        }
        size = CGSize(width: min(width, x), height: y)
        return size
    }

    static func longestWord(_ s: NSAttributedString) -> CGFloat {
        let ns = s.string as NSString
        var best: CGFloat = 0
        var start = 0
        for i in 0...ns.length {
            let isSpace = i == ns.length || ns.character(at: i) == 32 || ns.character(at: i) == 10
            if isSpace {
                if i > start { best = max(best, ceil(s.attributedSubstring(from: NSRange(location: start, length: i - start)).size().width)) }
                start = i + 1
            }
        }
        return best
    }

    override func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) {
        guard !colW.isEmpty else { return }
        let r = CGRect(origin: o, size: size)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil))
        ctx.clip()
        ctx.setFillColor(Theme.codeHeader.cgColor)
        ctx.fill(CGRect(x: o.x, y: o.y, width: size.width, height: rowH[0]))
        ctx.setFillColor(Theme.separator.cgColor)
        for (ri, y) in rowY.enumerated() where ri > 0 { ctx.fill(CGRect(x: o.x, y: o.y + y, width: size.width, height: 1)) }
        for (ci, x) in colX.enumerated() where ci > 0 { ctx.fill(CGRect(x: o.x + x, y: o.y, width: 1, height: size.height)) }
        ctx.restoreGState()
        strokeRounded(ctx, r, 10, Theme.cardBorder)
        for (ri, row) in ([header] + rows).enumerated() {
            let y = o.y + rowY[ri]
            if y > clip.maxY { break }
            if y + rowH[ri] < clip.minY { continue }
            for (ci, c) in row.enumerated() {
                c.draw(in: ctx, at: CGPoint(x: o.x + colX[ci] + padX, y: y + padY), clip: clip, selection: env.selection[ObjectIdentifier(c)], selectionColor: Theme.selection)
            }
        }
    }

    override func hit(_ p: CGPoint) -> HitResult? {
        for (ri, row) in ([header] + rows).enumerated() where p.y >= rowY[ri] && p.y < rowY[ri] + rowH[ri] {
            for (ci, c) in row.enumerated() where p.x >= colX[ci] && p.x < colX[ci] + colW[ci] {
                if let link = c.attribute(.mdLink, at: CGPoint(x: p.x - colX[ci] - padX, y: p.y - rowY[ri] - padY)) as? String {
                    return HitResult(hit: .link(link), rect: .zero, key: "link:" + link)
                }
            }
        }
        return nil
    }

    override func texts(_ o: CGPoint, _ out: inout [TextRef]) {
        for (ri, row) in ([header] + rows).enumerated() {
            for (ci, c) in row.enumerated() { out.append(TextRef(layout: c, origin: CGPoint(x: o.x + colX[ci] + padX, y: o.y + rowY[ri] + padY))) }
        }
    }
}

/// A table wider than the column scrolls horizontally in the web UI; here it shrinks columns and wraps.
final class ListEl: Element {
    struct Item { let marker: String; let task: Bool?; let content: Element }
    let items: [Item]
    let font: NSFont
    let color: NSColor
    private var markerW: CGFloat = 22
    private var offsets: [CGFloat] = []
    let spacing: CGFloat = 5

    init(items: [Item], font: NSFont, color: NSColor) {
        self.items = items
        self.font = font
        self.color = color
    }

    override func layout(width: CGFloat) -> CGSize {
        let longest = items.map { $0.task != nil ? 22 : textWidth($0.marker, font) }.max() ?? 10
        markerW = max(20, longest + 8)
        var y: CGFloat = 0
        offsets = []
        for (i, it) in items.enumerated() {
            if i > 0 { y += spacing }
            offsets.append(y)
            y += it.content.layout(width: width - markerW).height
        }
        size = CGSize(width: width, height: y)
        return size
    }

    override func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) {
        let lineH = ceil(font.ascender - font.descender)
        for (i, it) in items.enumerated() {
            let y = o.y + offsets[i]
            if y > clip.maxY { break }
            if y + it.content.size.height < clip.minY { continue }
            if let task = it.task {
                let box = CGRect(x: o.x + 3, y: y + (lineH - 14) / 2 + 1, width: 14, height: 14)
                if task {
                    fillRounded(ctx, box, 4, Theme.accent)
                    drawIcon("checkmark", in: box, size: 9, color: .white, weight: .bold, ctx: ctx)
                } else {
                    strokeRounded(ctx, box, 4, Theme.tertiaryText, width: 1.2)
                }
            } else if it.marker == "•" {
                let d: CGFloat = 5
                ctx.setFillColor(color.withAlphaComponent(0.7).cgColor)
                ctx.fillEllipse(in: CGRect(x: o.x + 6, y: y + lineH / 2 - d / 2 + 1, width: d, height: d))
            } else if it.marker == "◦" {
                let d: CGFloat = 5
                ctx.setStrokeColor(color.withAlphaComponent(0.7).cgColor)
                ctx.setLineWidth(1)
                ctx.strokeEllipse(in: CGRect(x: o.x + 6, y: y + lineH / 2 - d / 2 + 1, width: d, height: d))
            } else {
                drawString(it.marker, at: CGPoint(x: o.x + markerW - 6 - textWidth(it.marker, font), y: y), font: font, color: Theme.secondaryText)
            }
            it.content.draw(ctx, CGPoint(x: o.x + markerW, y: y), env, clip)
        }
    }

    override func hit(_ p: CGPoint) -> HitResult? {
        for (i, it) in items.enumerated() where p.y >= offsets[i] && p.y < offsets[i] + it.content.size.height {
            guard let h = it.content.hit(CGPoint(x: p.x - markerW, y: p.y - offsets[i])) else { return nil }
            return HitResult(hit: h.hit, rect: h.rect.offsetBy(dx: markerW, dy: offsets[i]), key: h.key)
        }
        return nil
    }

    override func texts(_ o: CGPoint, _ out: inout [TextRef]) {
        for (i, it) in items.enumerated() { it.content.texts(CGPoint(x: o.x + markerW, y: o.y + offsets[i]), &out) }
    }
}

final class QuoteEl: Element {
    let child: Element
    init(_ child: Element) { self.child = child }
    override func layout(width: CGFloat) -> CGSize {
        size = CGSize(width: width, height: child.layout(width: width - 16).height)
        return size
    }
    override func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) {
        fillRounded(ctx, CGRect(x: o.x, y: o.y, width: 3, height: size.height), 1.5, Theme.separator)
        child.draw(ctx, CGPoint(x: o.x + 16, y: o.y), env, clip)
    }
    override func hit(_ p: CGPoint) -> HitResult? {
        guard let h = child.hit(CGPoint(x: p.x - 16, y: p.y)) else { return nil }
        return HitResult(hit: h.hit, rect: h.rect.offsetBy(dx: 16, dy: 0), key: h.key)
    }
    override func texts(_ o: CGPoint, _ out: inout [TextRef]) { child.texts(CGPoint(x: o.x + 16, y: o.y), &out) }
}

/// Local image referenced from Markdown; decoded lazily as a bounded thumbnail.
final class ImageEl: Element {
    let path: String
    let alt: String
    private var image: CGImage?
    private var pixelSize: CGSize = .zero
    private var loaded = false
    private static let cache = NSCache<NSString, CGImage>()

    init(src: String, alt: String) {
        var p = src
        if p.hasPrefix("file://") { p = URL(string: p)?.path ?? String(p.dropFirst(7)) }
        path = p
        self.alt = alt
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let c = ImageEl.cache.object(forKey: path as NSString) { image = c; pixelSize = CGSize(width: c.width, height: c.height); return }
        guard !path.contains("://"), let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1600, kCGImageSourceCreateThumbnailWithTransform: true]
        if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            image = img
            pixelSize = CGSize(width: img.width, height: img.height)
            ImageEl.cache.setObject(img, forKey: path as NSString)
        }
    }

    override func layout(width: CGFloat) -> CGSize {
        load()
        if image != nil {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let w = min(width, pixelSize.width / scale * 1.0, 640)
            size = CGSize(width: width, height: ceil(w * pixelSize.height / max(1, pixelSize.width)))
        } else {
            size = CGSize(width: width, height: 36)
        }
        return size
    }

    override func draw(_ ctx: CGContext, _ o: CGPoint, _ env: DrawEnv, _ clip: CGRect) {
        if let image {
            let scale = NSScreen.main?.backingScaleFactor ?? 2
            let w = min(size.width, pixelSize.width / scale, 640)
            let r = CGRect(x: o.x, y: o.y, width: w, height: size.height)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 10, cornerHeight: 10, transform: nil))
            ctx.clip()
            ctx.translateBy(x: 0, y: r.maxY + r.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: r)
            ctx.restoreGState()
            strokeRounded(ctx, r, 10, Theme.codeBorder)
        } else {
            let r = CGRect(x: o.x, y: o.y, width: min(size.width, 360), height: 36)
            fillRounded(ctx, r, 8, Theme.codeBackground)
            drawIcon("photo", in: CGRect(x: r.minX + 8, y: r.minY, width: 20, height: r.height), size: 13, color: Theme.tertiaryText, ctx: ctx)
            drawLabel(alt.isEmpty ? (path as NSString).lastPathComponent : alt, in: CGRect(x: r.minX + 32, y: r.minY, width: r.width - 40, height: r.height), font: Theme.smallFont, color: Theme.secondaryText)
        }
    }

    override func hit(_ p: CGPoint) -> HitResult? {
        HitResult(hit: .openFile(path), rect: CGRect(origin: .zero, size: size), key: "img:" + path)
    }
}

// MARK: - Markdown → elements

enum MDRender {
    static func element(_ blocks: [MDBlock], style: MDStyle, keyPrefix: String) -> VStackEl {
        var out: [Element] = []
        var prevHeading = false
        for (i, b) in blocks.enumerated() {
            let key = "\(keyPrefix).\(i)"
            let el: Element
            var topExtra: CGFloat = 0
            switch b {
            case .paragraph(let s): el = TextEl(s)
            case .heading(let level, let s):
                el = TextEl(s)
                if i > 0 { topExtra = level <= 2 ? 10 : 6 }
            case .code(let lang, let code): el = CodeBlockEl(lang: lang, code: code, key: key)
            case .list(let ordered, let start, let items):
                el = ListEl(items: items.enumerated().map { (j, it) in
                    let marker = ordered ? "\(start + j)." : (keyPrefix.filter { $0 == "L" }.count % 2 == 0 ? "•" : "◦")
                    return ListEl.Item(marker: marker, task: it.task, content: element(it.blocks, style: style, keyPrefix: "\(key)L\(j)"))
                }, font: style.font, color: style.color)
            case .quote(let inner): el = QuoteEl(element(inner, style: style, keyPrefix: key + "q"))
            case .table(let h, let a, let rows): el = TableEl(header: h, rows: rows, aligns: a)
            case .hr: el = RuleEl(margin: 6)
            case .image(let alt, let src):
                var path = src
                if !path.contains("://") {
                    path = (path as NSString).expandingTildeInPath
                    if !path.hasPrefix("/"), let base = style.baseDir { path = (base as NSString).appendingPathComponent(path) }
                }
                el = ImageEl(src: path, alt: alt)
            }
            if !out.isEmpty {
                var gap: CGFloat = 12
                if case .list = b, prevHeading { gap = 8 }
                if case .paragraph = b, prevHeading { gap = 6 }
                out.append(SpacerEl(max(0, gap + topExtra - 0)))
            }
            out.append(el)
            if case .heading = b { prevHeading = true } else { prevHeading = false }
        }
        return VStackEl(out)
    }
}
