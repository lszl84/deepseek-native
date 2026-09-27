import AppKit

protocol TranscriptViewDelegate: AnyObject {
    func transcript(_ view: TranscriptView, didHit hit: Hit)
}

/// Custom-drawn chat transcript. Items are laid out once per width and drawn only when visible.
final class TranscriptView: NSView {
    final class Item {
        let key: String
        var sig: Int
        var gap: CGFloat
        var element: Element
        var y: CGFloat = 0
        var height: CGFloat = 0
        var laidOutWidth: CGFloat = -1
        init(key: String, sig: Int, gap: CGFloat, element: Element) {
            self.key = key; self.sig = sig; self.gap = gap; self.element = element
        }
    }

    weak var delegate: TranscriptViewDelegate?
    private(set) var items: [Item] = []
    private var byKey: [String: Item] = [:]
    let env = DrawEnv()
    var maxColumnWidth: CGFloat = 780
    var sidePadding: CGFloat = 32
    var topInset: CGFloat = 16 { didSet { relayoutPositions() } }
    var bottomInset: CGFloat = 160 { didSet { relayoutPositions() } }
    private(set) var contentHeight: CGFloat = 0
    var onContentHeightChange: (() -> Void)?

    // Selection
    private var refs: [TextRef] = []
    private var refIndex: [ObjectIdentifier: Int] = [:]
    private var refsDirty = true
    private var anchor: (ObjectIdentifier, Int)?
    private var focus: (ObjectIdentifier, Int)?
    private var mouseDownHit: HitResult?
    private var mouseDownPoint: CGPoint = .zero
    private var selecting = false
    private var clickGranularity = 1

    private var animTimer: Timer?
    private var copiedTimer: Timer?
    private var trackingArea: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Draw synchronously with CoreGraphics into the backing store; the async
        // Metal-accelerated path keeps large GPU caches alive for this view.
        layer?.drawsAsynchronously = false
    }
    required init?(coder: NSCoder) { fatalError() }

    var columnWidth: CGFloat { max(200, min(maxColumnWidth, bounds.width - sidePadding * 2)) }
    var columnX: CGFloat { floor((bounds.width - columnWidth) / 2) }

    // MARK: Items

    /// Applies new item specs, reusing elements whose key and signature are unchanged.
    func apply(_ specs: [ItemSpec]) {
        var newItems: [Item] = []
        newItems.reserveCapacity(specs.count)
        var newByKey: [String: Item] = [:]
        let w = columnWidth
        var changed: [Item] = []
        for s in specs {
            if let old = byKey[s.key], newByKey[s.key] == nil {
                if old.sig != s.sig {
                    old.element = s.make()
                    old.sig = s.sig
                    old.laidOutWidth = -1
                    changed.append(old)
                }
                old.gap = s.gapBefore
                newItems.append(old)
                newByKey[s.key] = old
            } else {
                let key = newByKey[s.key] == nil ? s.key : s.key + "#\(newItems.count)"
                let it = Item(key: key, sig: s.sig, gap: s.gapBefore, element: s.make())
                newItems.append(it)
                newByKey[key] = it
                changed.append(it)
            }
        }
        let sameList = newItems.count == items.count && zip(newItems, items).allSatisfy { $0 === $1 }
        if changed.isEmpty && sameList { return }
        // Remember old geometry to repaint only what changed or moved.
        var oldRects: [ObjectIdentifier: CGRect] = [:]
        for it in items { oldRects[ObjectIdentifier(it)] = rect(of: it) }
        let removed = items.filter { newByKey[$0.key] !== $0 }
        items = newItems
        byKey = newByKey
        for it in items where it.laidOutWidth != w {
            it.height = it.element.layout(width: w).height
            it.laidOutWidth = w
        }
        let oldHeight = contentHeight
        relayoutPositions(invalidate: false)
        var dirty = CGRect.null
        var movedFrom = CGFloat.greatestFiniteMagnitude
        for r in removed.compactMap({ oldRects[ObjectIdentifier($0)] }) { movedFrom = min(movedFrom, r.minY) }
        let changedIds = Set(changed.map { ObjectIdentifier($0) })
        for it in items {
            let nr = rect(of: it)
            if let or = oldRects[ObjectIdentifier(it)] {
                if abs(or.minY - nr.minY) > 0.5 || abs(or.height - nr.height) > 0.5 { movedFrom = min(movedFrom, min(or.minY, nr.minY)) }
                else if changedIds.contains(ObjectIdentifier(it)) { dirty = dirty.union(nr) }
            } else {
                movedFrom = min(movedFrom, nr.minY)
            }
        }
        if movedFrom < .greatestFiniteMagnitude {
            dirty = dirty.union(CGRect(x: 0, y: movedFrom, width: bounds.width, height: max(oldHeight, contentHeight) - movedFrom))
        }
        refsDirty = true
        validateSelection()
        if !dirty.isNull { setNeedsDisplay(dirty) }
        updateAnimationTimer()
    }

    /// Repaints one item in place (e.g. a live elapsed-time label).
    func invalidateItem(key: String) {
        if let it = byKey[key] { setNeedsDisplay(rect(of: it)) }
    }

    private func relayoutPositions(invalidate: Bool = true) {
        var y = topInset
        for (i, it) in items.enumerated() {
            if i > 0 { y += it.gap }
            it.y = y
            y += it.height
        }
        let h = y + bottomInset
        if abs(h - contentHeight) > 0.5 {
            contentHeight = h
            onContentHeightChange?()
        }
        if invalidate { needsDisplay = true }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let oldW = bounds.width
        super.setFrameSize(newSize)
        if abs(oldW - newSize.width) > 0.5 { relayoutAll() }
    }

    /// Invalidation rects arrive in document coordinates; clip them to the visible canvas.
    override func setNeedsDisplay(_ invalidRect: NSRect) {
        let r = invalidRect.intersection(bounds)
        if !r.isEmpty { super.setNeedsDisplay(r) }
    }

    func relayoutAll() {
        let w = columnWidth
        for it in items where it.laidOutWidth != w {
            it.height = it.element.layout(width: w).height
            it.laidOutWidth = w
        }
        relayoutPositions()
        refsDirty = true
    }

    /// Relayouts after appearance change (colors are resolved at draw time; layout is unaffected).
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    func item(forKey key: String) -> Item? { byKey[key] }

    func rect(of item: Item) -> CGRect {
        CGRect(x: 0, y: item.y - 4, width: bounds.width, height: item.height + 8)
    }

    private func itemIndex(atY y: CGFloat) -> Int? {
        var lo = 0, hi = items.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let it = items[mid]
            if y < it.y { hi = mid - 1 }
            else if y > it.y + it.height { lo = mid + 1 }
            else { return mid }
        }
        return nil
    }

    private func firstVisibleIndex(_ minY: CGFloat) -> Int {
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid].y + items[mid].height < minY { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance { self.drawContent(dirtyRect) }
    }

    private func drawContent(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(Theme.background.cgColor)
        ctx.fill(dirtyRect)
        let x = columnX
        var i = firstVisibleIndex(dirtyRect.minY - 8)
        while i < items.count {
            let it = items[i]
            if it.y > dirtyRect.maxY + 8 { break }
            it.element.draw(ctx, CGPoint(x: x, y: it.y), env, dirtyRect)
            i += 1
        }
    }

    private var visibleAnimating: [Item] {
        let vis = visibleRect
        var out: [Item] = []
        var i = firstVisibleIndex(vis.minY)
        while i < items.count, items[i].y < vis.maxY {
            if items[i].element.animating { out.append(items[i]) }
            i += 1
        }
        return out
    }

    func updateAnimationTimer() {
        let needs = items.contains { $0.element.animating }
        if needs && animTimer == nil {
            let t = Timer(timeInterval: 1.0 / 12, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.env.spinnerPhase = CGFloat(fmod(Date().timeIntervalSinceReferenceDate * 1.1, 1))
                for it in self.visibleAnimating { self.setNeedsDisplay(self.rect(of: it)) }
            }
            RunLoop.main.add(t, forMode: .common)
            animTimer = t
        } else if !needs {
            animTimer?.invalidate()
            animTimer = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { animTimer?.invalidate(); animTimer = nil } else { updateAnimationTimer() }
    }

    // MARK: Hit testing

    private func elementPoint(_ p: CGPoint) -> (Item, CGPoint)? {
        guard let i = itemIndex(atY: p.y) else { return nil }
        let it = items[i]
        return (it, CGPoint(x: p.x - columnX, y: p.y - it.y))
    }

    private func hitTestPoint(_ p: CGPoint) -> (Item, HitResult)? {
        guard let (it, lp) = elementPoint(p), let h = it.element.hit(lp) else { return nil }
        return (it, h)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate], owner: self)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        updateHover(p)
    }

    override func mouseExited(with event: NSEvent) {
        setHover(key: nil, keyItem: nil, item: nil)
        NSCursor.arrow.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        updateHover(convert(event.locationInWindow, from: nil))
    }

    private func updateHover(_ p: CGPoint) {
        let hit = hitTestPoint(p)
        let itemKey = itemIndex(atY: p.y).map { items[$0].key }
        setHover(key: hit?.1.key, keyItem: hit?.0.key, item: itemKey)
        if hit != nil { NSCursor.pointingHand.set() }
        else if isOverText(p) { NSCursor.iBeam.set() }
        else { NSCursor.arrow.set() }
    }

    private var hoverKeyItem: String?

    private func setHover(key: String?, keyItem: String?, item: String?) {
        guard key != env.hoverKey || item != env.hoverItem else { return }
        for k in Set([env.hoverItem, item, hoverKeyItem, keyItem].compactMap { $0 }) {
            if let it = byKey[k] { setNeedsDisplay(rect(of: it)) }
        }
        env.hoverKey = key
        env.hoverItem = item
        hoverKeyItem = keyItem
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let p = convert(event.locationInWindow, from: nil)
        mouseDownPoint = p
        mouseDownHit = nil
        if let (_, h) = hitTestPoint(p), event.clickCount == 1 {
            mouseDownHit = h
            env.pressedKey = h.key
            return
        }
        ensureRefs()
        guard let sp = selPoint(at: p) else { clearSelection(); return }
        clickGranularity = event.clickCount
        let layout = refs[sp.0].layout
        if event.clickCount == 2 {
            let r = layout.wordRange(at: sp.1)
            anchor = (ObjectIdentifier(layout), r.location)
            focus = (ObjectIdentifier(layout), NSMaxRange(r))
        } else if event.clickCount >= 3 {
            let r = layout.lineRange(at: sp.1)
            anchor = (ObjectIdentifier(layout), r.location)
            focus = (ObjectIdentifier(layout), NSMaxRange(r))
        } else if event.modifierFlags.contains(.shift), anchor != nil {
            focus = (ObjectIdentifier(layout), sp.1)
        } else {
            anchor = (ObjectIdentifier(layout), sp.1)
            focus = anchor
        }
        selecting = true
        updateSelectionMap()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if mouseDownHit != nil {
            if hypot(p.x - mouseDownPoint.x, p.y - mouseDownPoint.y) > 4 { mouseDownHit = nil; env.pressedKey = nil }
            else { return }
            ensureRefs()
            if let sp = selPoint(at: mouseDownPoint) { anchor = (ObjectIdentifier(refs[sp.0].layout), sp.1); selecting = true }
        }
        guard selecting else { return }
        autoscroll(with: event)
        ensureRefs()
        if let sp = selPoint(at: p) {
            focus = (ObjectIdentifier(refs[sp.0].layout), sp.1)
            updateSelectionMap()
        }
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        env.pressedKey = nil
        if let h = mouseDownHit {
            mouseDownHit = nil
            if let (_, h2) = hitTestPoint(p), h2.key == h.key {
                if case .copy(let text, let key) = h.hit {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    flashCopied(key)
                } else {
                    delegate?.transcript(self, didHit: h.hit)
                }
            }
            return
        }
        selecting = false
        if let a = anchor, let f = focus, a.0 == f.0, a.1 == f.1 { clearSelection() }
    }

    private func flashCopied(_ key: String) {
        env.copiedKey = key
        needsDisplay = true
        copiedTimer?.invalidate()
        copiedTimer = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
            self?.env.copiedKey = nil
            self?.needsDisplay = true
        }
    }

    // MARK: Selection

    private func ensureRefs() {
        guard refsDirty else { return }
        refsDirty = false
        refs = []
        let x = columnX
        for it in items { it.element.texts(CGPoint(x: x, y: it.y), &refs) }
        refIndex = [:]
        for (i, r) in refs.enumerated() { refIndex[ObjectIdentifier(r.layout)] = i }
    }

    private func isOverText(_ p: CGPoint) -> Bool {
        ensureRefs()
        for r in refs where p.y >= r.origin.y && p.y <= r.origin.y + r.layout.size.height {
            if r.layout.contains(CGPoint(x: p.x - r.origin.x, y: p.y - r.origin.y)) { return true }
        }
        return false
    }

    private func selPoint(at p: CGPoint) -> (Int, Int)? {
        guard !refs.isEmpty else { return nil }
        var best: Int?
        var bestDX = CGFloat.greatestFiniteMagnitude
        for (i, r) in refs.enumerated() {
            let top = r.origin.y - 3, bottom = r.origin.y + r.layout.size.height + 3
            if p.y >= top && p.y <= bottom {
                let dx = p.x < r.origin.x ? r.origin.x - p.x : (p.x > r.origin.x + max(r.layout.layoutWidth, r.layout.size.width) ? p.x - r.origin.x - r.layout.size.width : 0)
                if dx < bestDX { bestDX = dx; best = i }
            } else if r.origin.y > bottom + 1000 { break }
        }
        if let b = best {
            let r = refs[b]
            return (b, r.layout.index(at: CGPoint(x: p.x - r.origin.x, y: p.y - r.origin.y)))
        }
        // Between text blocks: snap to the start of the next one below.
        if let next = refs.firstIndex(where: { $0.origin.y > p.y }) {
            if next > 0 && p.y > refs[next - 1].origin.y { return (next - 1, refs[next - 1].layout.length) }
            return (next, 0)
        }
        return (refs.count - 1, refs.last!.layout.length)
    }

    private func orderedSelection() -> ((Int, Int), (Int, Int))? {
        guard let a = anchor, let f = focus, let ai = refIndex[a.0], let fi = refIndex[f.0] else { return nil }
        let s = (ai, a.1), e = (fi, f.1)
        return (s.0 < e.0 || (s.0 == e.0 && s.1 <= e.1)) ? (s, e) : (e, s)
    }

    private func updateSelectionMap() {
        env.selection = [:]
        if let (s, e) = orderedSelection() {
            for i in s.0...e.0 {
                let l = refs[i].layout
                let start = i == s.0 ? s.1 : 0
                let end = i == e.0 ? e.1 : l.length
                if end > start { env.selection[ObjectIdentifier(l)] = NSRange(location: start, length: end - start) }
            }
        }
        needsDisplay = true
    }

    private func validateSelection() {
        guard anchor != nil else { return }
        ensureRefs()
        if orderedSelection() == nil { clearSelection() } else { updateSelectionMap() }
    }

    func clearSelection() {
        anchor = nil
        focus = nil
        if !env.selection.isEmpty { env.selection = [:]; needsDisplay = true }
    }

    var selectedText: String {
        ensureRefs()
        guard let (s, e) = orderedSelection() else { return "" }
        var parts: [String] = []
        for i in s.0...e.0 {
            let l = refs[i].layout
            let start = i == s.0 ? s.1 : 0
            let end = i == e.0 ? e.1 : l.length
            if end > start { parts.append((l.string.string as NSString).substring(with: NSRange(location: start, length: end - start))) }
        }
        return parts.joined(separator: "\n").replacingOccurrences(of: "\u{2009}", with: "").replacingOccurrences(of: "\u{2028}", with: "\n")
    }

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityLabel() -> String? { "Conversation" }
    override func accessibilityValue() -> Any? {
        ensureRefs()
        return refs.map { $0.layout.string.string }.joined(separator: "\n")
    }
    override func accessibilitySelectedText() -> String? { selectedText }

    @objc func copy(_ sender: Any?) {
        let t = selectedText
        guard !t.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(t, forType: .string)
    }

    override func selectAll(_ sender: Any?) {
        ensureRefs()
        guard let first = refs.first, let last = refs.last else { return }
        anchor = (ObjectIdentifier(first.layout), 0)
        focus = (ObjectIdentifier(last.layout), last.layout.length)
        updateSelectionMap()
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !env.selection.isEmpty }
        return true
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let p = convert(event.locationInWindow, from: nil)
        if let (_, h) = hitTestPoint(p), case .link(let url) = h.hit {
            m.addItem(withTitle: "Open Link", action: #selector(openLinkItem(_:)), keyEquivalent: "").representedObject = url
            m.addItem(withTitle: "Copy Link", action: #selector(copyLinkItem(_:)), keyEquivalent: "").representedObject = url
            m.addItem(.separator())
        }
        m.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
        m.addItem(withTitle: "Select All", action: #selector(selectAll(_:)), keyEquivalent: "a")
        return m
    }

    @objc private func openLinkItem(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String { delegate?.transcript(self, didHit: .link(s)) }
    }

    @objc private func copyLinkItem(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s.hasPrefix("file://") ? String(s.dropFirst(7)) : s, forType: .string)
    }
}
