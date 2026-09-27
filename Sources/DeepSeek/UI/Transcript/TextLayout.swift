import AppKit
import CoreText

/// Core Text line layout of an attributed string at a fixed width, drawn in flipped coordinates.
final class TextLayout {
    struct Line {
        let line: CTLine
        let range: NSRange
        let x: CGFloat        // pen offset (alignment)
        let baseline: CGFloat // from top
        let top: CGFloat
        let bottom: CGFloat
        let width: CGFloat
    }

    let string: NSAttributedString
    private(set) var lines: [Line] = []
    private(set) var size: CGSize = .zero
    private(set) var layoutWidth: CGFloat = -1
    let maxLines: Int
    private(set) var truncated = false
    private let hasCode: Bool
    private let hasStrike: Bool

    init(_ string: NSAttributedString, maxLines: Int = 0) {
        self.string = string
        self.maxLines = maxLines
        var code = false, strike = false
        string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { a, _, stop in
            if a[.mdCode] != nil { code = true }
            if a[.strikethroughStyle] != nil { strike = true }
            if code && strike { stop.pointee = true }
        }
        hasCode = code
        hasStrike = strike
    }

    var length: Int { string.length }

    @discardableResult
    func layout(width: CGFloat) -> CGSize {
        if abs(width - layoutWidth) < 0.5 { return size }
        layoutWidth = width
        lines.removeAll(keepingCapacity: true)
        truncated = false
        let len = string.length
        guard len > 0 else { size = .zero; return size }
        let typesetter = CTTypesetterCreateWithAttributedString(string as CFAttributedString)
        let ns = string.string as NSString
        var start = 0
        var y: CGFloat = 0
        var maxW: CGFloat = 0
        while start < len {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(1, width)))
            if count <= 0 { count = 1 }
            let range = NSRange(location: start, length: count)
            var line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            let isLast = start + count >= len
            if maxLines > 0 && lines.count == maxLines - 1 && !isLast {
                // Truncate with an ellipsis.
                let rest = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: len - start))
                let attrs = string.attributes(at: start, effectiveRange: nil)
                let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: attrs))
                line = CTLineCreateTruncatedLine(rest, Double(width), .end, token) ?? line
                truncated = true
            }
            var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
            let w = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let trailingWS = CGFloat(CTLineGetTrailingWhitespaceWidth(line))
            let para = string.attribute(.paragraphStyle, at: start, effectiveRange: nil) as? NSParagraphStyle
            let spacing = para?.lineSpacing ?? 0
            let font = string.attribute(.font, at: start, effectiveRange: nil) as? NSFont
            // Keep a stable line box based on the primary font, so inline code or emoji do not jitter lines.
            if let font {
                ascent = max(ascent, font.ascender)
                descent = max(descent, -font.descender)
            }
            let top = y
            let baseline = y + ceil(ascent)
            let bottom = baseline + ceil(descent)
            var flush: CGFloat = 0
            if let a = para?.alignment, a == .center || a == .right {
                flush = CGFloat(CTLineGetPenOffsetForFlush(line, a == .center ? 0.5 : 1.0, Double(width)))
            }
            lines.append(Line(line: line, range: range, x: flush, baseline: baseline, top: top, bottom: bottom, width: w - trailingWS))
            maxW = max(maxW, w - trailingWS)
            y = bottom
            start += count
            if truncated { break }
            if start < len {
                y += spacing
                let lastChar = ns.character(at: start - 1)
                if lastChar == 10 || lastChar == 0x2029 { y += para?.paragraphSpacing ?? 0 }
            }
        }
        size = CGSize(width: ceil(maxW), height: ceil(y))
        return size
    }

    func draw(in ctx: CGContext, at origin: CGPoint, clip: CGRect, selection: NSRange? = nil, selectionColor: NSColor? = nil) {
        guard !lines.isEmpty else { return }
        ctx.saveGState()
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for l in lines {
            let top = origin.y + l.top - 4, bottom = origin.y + l.bottom + 4
            if bottom < clip.minY { continue }
            if top > clip.maxY { break }
            if let sel = selection, let color = selectionColor {
                let inter = NSIntersectionRange(sel, l.range)
                if inter.length > 0 || (sel.location <= l.range.location && NSMaxRange(sel) > NSMaxRange(l.range)) {
                    let x1 = CTLineGetOffsetForStringIndex(l.line, max(sel.location, l.range.location), nil)
                    var x2 = CTLineGetOffsetForStringIndex(l.line, min(NSMaxRange(sel), NSMaxRange(l.range)), nil)
                    if NSMaxRange(sel) > NSMaxRange(l.range) { x2 = max(x2, l.width + 4) }
                    ctx.setFillColor(color.cgColor)
                    ctx.fill(CGRect(x: origin.x + l.x + x1, y: origin.y + l.top - 1, width: max(2, x2 - x1), height: l.bottom - l.top + 2))
                }
            }
            if hasCode { drawCodeBackgrounds(ctx, l, origin) }
            ctx.textPosition = CGPoint(x: origin.x + l.x, y: origin.y + l.baseline)
            CTLineDraw(l.line, ctx)
            if hasStrike { drawStrikes(ctx, l, origin) }
        }
        ctx.restoreGState()
    }

    private func drawCodeBackgrounds(_ ctx: CGContext, _ l: Line, _ origin: CGPoint) {
        let runs = CTLineGetGlyphRuns(l.line) as! [CTRun]
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard attrs[NSAttributedString.Key.mdCode] != nil else { continue }
            var pos = CGPoint.zero
            CTRunGetPositions(run, CFRange(location: 0, length: 1), &pos)
            var a: CGFloat = 0, d: CGFloat = 0
            let w = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &a, &d, nil))
            let r = CGRect(x: origin.x + l.x + pos.x - 3, y: origin.y + l.baseline - a - 2.5, width: w + 6, height: a + d + 5)
            let path = CGPath(roundedRect: r, cornerWidth: 5, cornerHeight: 5, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(Theme.inlineCodeBackground.cgColor)
            ctx.fillPath()
        }
    }

    private func drawStrikes(_ ctx: CGContext, _ l: Line, _ origin: CGPoint) {
        let runs = CTLineGetGlyphRuns(l.line) as! [CTRun]
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard attrs[NSAttributedString.Key.strikethroughStyle] != nil else { continue }
            var pos = CGPoint.zero
            CTRunGetPositions(run, CFRange(location: 0, length: 1), &pos)
            var a: CGFloat = 0
            let w = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &a, nil, nil))
            let color = (attrs[NSAttributedString.Key.foregroundColor] as? NSColor) ?? Theme.text
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: origin.x + l.x + pos.x, y: origin.y + l.baseline - a * 0.32, width: w, height: 1))
        }
    }

    /// Character index nearest to a point in local coordinates.
    func index(at p: CGPoint) -> Int {
        guard !lines.isEmpty else { return 0 }
        if p.y < lines[0].top { return 0 }
        if p.y > lines.last!.bottom { return string.length }
        var best = lines.last!
        for (i, l) in lines.enumerated() {
            let nextTop = i + 1 < lines.count ? lines[i + 1].top : .greatestFiniteMagnitude
            if p.y < (l.bottom + nextTop) / 2 || i == lines.count - 1 { best = l; break }
        }
        let idx = CTLineGetStringIndexForPosition(best.line, CGPoint(x: p.x - best.x, y: 0))
        if idx == kCFNotFound { return best.range.location }
        return min(max(idx, best.range.location), NSMaxRange(best.range))
    }

    /// Whether `p` lies over the actual glyph area of a line.
    func contains(_ p: CGPoint) -> Bool {
        for l in lines where p.y >= l.top - 2 && p.y <= l.bottom + 2 {
            return p.x >= l.x - 2 && p.x <= l.x + l.width + 2
        }
        return false
    }

    func attribute(_ key: NSAttributedString.Key, at p: CGPoint) -> Any? {
        guard let l = lines.first(where: { p.y >= $0.top - 2 && p.y <= $0.bottom + 2 }) else { return nil }
        for run in CTLineGetGlyphRuns(l.line) as! [CTRun] {
            var pos = CGPoint.zero
            CTRunGetPositions(run, CFRange(location: 0, length: 1), &pos)
            let w = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), nil, nil, nil))
            if p.x >= l.x + pos.x - 1 && p.x <= l.x + pos.x + w + 1 {
                let r = CTRunGetStringRange(run)
                if let v = string.attribute(key, at: r.location, effectiveRange: nil) { return v }
            }
        }
        return nil
    }

    func wordRange(at index: Int) -> NSRange {
        let s = string.string as NSString
        guard s.length > 0 else { return NSRange(location: 0, length: 0) }
        let i = min(max(0, index), s.length - 1)
        let set = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        func isWord(_ k: Int) -> Bool { UnicodeScalar(s.character(at: k)).map { set.contains($0) } ?? false }
        guard isWord(i) else { return NSRange(location: i, length: 1) }
        var a = i, b = i
        while a > 0 && isWord(a - 1) { a -= 1 }
        while b < s.length - 1 && isWord(b + 1) { b += 1 }
        return NSRange(location: a, length: b - a + 1)
    }

    func lineRange(at index: Int) -> NSRange {
        let s = string.string as NSString
        return s.paragraphRange(for: NSRange(location: min(index, max(0, s.length - 1)), length: 0))
    }
}

/// Measures a one-line label cheaply (used for pills and row labels).
func textWidth(_ s: String, _ font: NSFont) -> CGFloat {
    ceil((s as NSString).size(withAttributes: [.font: font]).width)
}
