import AppKit
import LungfishCore

@MainActor
final class GenotypeHaplotypeTapeView: NSView {
    enum Cell: Equatable {
        case reference(tokenIndex: Int, label: String)
        case manual(tokenIndex: Int, label: String)
        case recombinant(tokenIndexA: Int, tokenIndexB: Int, label: String)
        case error(label: String)
        case notAssayed(label: String)
        case empty
        /// Locus was observed at the read level but the active definition
        /// set didn't include it, so the pipeline couldn't produce a
        /// haplotype call. Renders as a light dashed-border placeholder.
        case unanalyzed(observedGenotypes: Int)
    }

    struct Slot: Equatable {
        let locus: String
        let h1: Cell
        let h2: Cell
    }

    private(set) var swatchCount: Int = 0
    var sampleAccessibilityLabel: String = ""
    var showOverrideHatching: ((Slot, HaplotypeSlot) -> Bool)? = nil

    private var slots: [Slot] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)

    }

    func configure(loci: [String], slots: [Slot]) {
        self.slots = slots
        self.swatchCount = slots.count * 2
        accessibilityElementsCache = nil
        setNeedsDisplay(bounds)
    }

    override var isFlipped: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        setNeedsDisplay(bounds)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !slots.isEmpty else { return }
        let columnWidth = bounds.width / CGFloat(slots.count)
        let halfHeight = bounds.height / 2.0

        for (index, slot) in slots.enumerated() {
            let x = CGFloat(index) * columnWidth
            let topRect = NSRect(
                x: x + 0.5, y: 0.5,
                width: columnWidth - 1.5, height: halfHeight - 1
            )
            let botRect = NSRect(
                x: x + 0.5, y: halfHeight + 0.5,
                width: columnWidth - 1.5, height: halfHeight - 1
            )
            drawCell(slot.h1, in: topRect,
                     isOverridden: showOverrideHatching?(slot, .h1) == true)
            drawCell(slot.h2, in: botRect,
                     isOverridden: showOverrideHatching?(slot, .h2) == true)
        }
    }

    private func drawCell(_ cell: Cell, in rect: NSRect, isOverridden: Bool) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        switch cell {
        case .empty:
            tokenNSColor(tokenIndex: 0).setFill()
            path.fill()
        case .reference(let i, _), .manual(let i, _):
            tokenNSColor(tokenIndex: i).setFill()
            path.fill()
        case .recombinant(let a, let b, _):
            drawStripedFill(a: a, b: b, in: rect, path: path)
        case .error(let label):
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            NSColor.lungfishDanger.setStroke()
            path.lineWidth = 1.5
            path.stroke()
            drawErrorGlyph(label: label, in: rect)
        case .notAssayed(let label):
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            let dashed = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            dashed.lineWidth = 1.0
            dashed.setLineDash([4.0, 2.0], count: 2, phase: 0)
            NSColor.systemOrange.setStroke()
            dashed.stroke()
            drawUnavailableGlyph(label: label, in: rect)
        case .unanalyzed(let count):
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            // Dashed outline distinguishes unanalyzed from absent.
            let dashed = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            dashed.lineWidth = 1.0
            dashed.setLineDash([3.0, 2.0], count: 2, phase: 0)
            NSColor.secondaryLabelColor.setStroke()
            dashed.stroke()
            if count > 0 {
                drawObservedGlyph(count: count, in: rect)
            }
        }
        if isOverridden {
            drawHatchOverlay(in: rect)
        }
    }

    private func drawStripedFill(a: Int, b: Int, in rect: NSRect, path: NSBezierPath) {
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let stripeWidth: CGFloat = 4
        var x = rect.minX
        var toggle = true
        while x < rect.maxX {
            let stripe = NSBezierPath(rect: NSRect(
                x: x, y: rect.minY, width: stripeWidth, height: rect.height
            ))
            (toggle ? tokenNSColor(tokenIndex: a) : tokenNSColor(tokenIndex: b)).setFill()
            stripe.fill()
            x += stripeWidth
            toggle.toggle()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawErrorGlyph(label: String, in rect: NSRect) {
        let symbol = errorSymbol(forLabel: label)
        guard rect.height >= 8 else { return }
        let fontSize = max(7, min(11, rect.height * 0.65))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.lungfishDanger,
        ]
        let attributed = NSAttributedString(string: symbol, attributes: attrs)
        let size = attributed.size()
        let x = rect.midX - size.width / 2
        let y = rect.midY - size.height / 2
        attributed.draw(at: NSPoint(x: x, y: y))
    }

    private func drawObservedGlyph(count: Int, in rect: NSRect) {
        guard rect.height >= 10 else { return }
        let fontSize = max(7, min(10, rect.height * 0.55))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let attributed = NSAttributedString(string: "\(count)", attributes: attrs)
        let size = attributed.size()
        let x = rect.midX - size.width / 2
        let y = rect.midY - size.height / 2
        attributed.draw(at: NSPoint(x: x, y: y))
    }

    private func drawUnavailableGlyph(label: String, in rect: NSRect) {
        guard rect.height >= 10 else { return }
        let fontSize = max(7, min(10, rect.height * 0.55))
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.systemOrange,
        ]
        let attributed = NSAttributedString(string: "\u{2014}", attributes: attrs)
        let size = attributed.size()
        let x = rect.midX - size.width / 2
        let y = rect.midY - size.height / 2
        attributed.draw(at: NSPoint(x: x, y: y))
    }

    private func errorSymbol(forLabel label: String) -> String {
        if label.contains("TMH") { return "T" }
        if label.contains("TMG") { return "G" }
        if label.contains("NO HAP") { return "?" }
        return "!"
    }

    private func drawHatchOverlay(in rect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        path.addClip()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        let spacing: CGFloat = 4.0
        var x: CGFloat = rect.minX - rect.height
        while x < rect.maxX + rect.height {
            let stroke = NSBezierPath()
            stroke.move(to: NSPoint(x: x, y: rect.minY))
            stroke.line(to: NSPoint(x: x + rect.height, y: rect.maxY))
            stroke.lineWidth = 1.0
            stroke.stroke()
            x += spacing
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func tokenNSColor(tokenIndex: Int) -> NSColor {
        let palette = HaplotypeColorToken.canonicalPalette
        let safeIndex = max(0, min(palette.count - 1, tokenIndex))
        let token = palette[safeIndex]
        let isDark: Bool = {
            if let match = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) {
                return match == .darkAqua
            }
            return false
        }()
        let color: AnnotationColor = isDark ? token.darkFillColor : token.fillColor
        return color.nsColor
    }

    // MARK: Accessibility

    private var accessibilityElementsCache: [NSAccessibilityElement]?
    private var lastAccessibilityBounds: NSRect = .zero

    override func accessibilityChildren() -> [Any]? {
        if let cache = accessibilityElementsCache, lastAccessibilityBounds == bounds {
            return cache
        }
        guard !slots.isEmpty, bounds.width > 0, bounds.height > 0 else {
            accessibilityElementsCache = []
            lastAccessibilityBounds = bounds
            return []
        }
        let columnWidth = bounds.width / CGFloat(slots.count)
        let halfHeight = bounds.height / 2.0
        var children: [NSAccessibilityElement] = []
        for (index, slot) in slots.enumerated() {
            let x = CGFloat(index) * columnWidth
            let topRect = NSRect(x: x, y: 0, width: columnWidth, height: halfHeight)
            let botRect = NSRect(x: x, y: halfHeight, width: columnWidth, height: halfHeight)
            children.append(makeAccessibilityElement(for: slot, slot: .h1, frame: topRect))
            children.append(makeAccessibilityElement(for: slot, slot: .h2, frame: botRect))
        }
        accessibilityElementsCache = children
        lastAccessibilityBounds = bounds
        return children
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        if oldSize != bounds.size {
            accessibilityElementsCache = nil
        }
    }

    private func makeAccessibilityElement(
        for slot: Slot, slot tapeSlot: HaplotypeSlot, frame: NSRect
    ) -> NSAccessibilityElement {
        let value = cellLabel(tapeSlot == .h1 ? slot.h1 : slot.h2)
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(.button)
        element.setAccessibilityFrameInParentSpace(frame)
        let label = [sampleAccessibilityLabel, slot.locus, tapeSlot.displayName, value]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        element.setAccessibilityLabel(label)
        element.setAccessibilityParent(self)
        return element
    }

    private func cellLabel(_ cell: Cell) -> String {
        switch cell {
        case .empty: return "not observed"
        case .reference(_, let l), .manual(_, let l): return l
        case .recombinant(_, _, let l): return l
        case .error(let l): return l
        case .notAssayed(let l): return l
        case .unanalyzed(let count):
            return count > 0 ? "unanalyzed (\(count) genotypes observed)" : "unanalyzed"
        }
    }
}

extension AnnotationColor {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}
