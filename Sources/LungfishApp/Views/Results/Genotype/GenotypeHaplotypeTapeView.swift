import AppKit
import LungfishCore

@MainActor
final class GenotypeHaplotypeTapeView: NSView {
    enum Cell: Equatable {
        case reference(tokenIndex: Int, label: String)
        case manual(tokenIndex: Int, label: String)
        case recombinant(tokenIndexA: Int, tokenIndexB: Int, label: String)
        case error(label: String)
        case empty
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
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
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
        case .error:
            NSColor.controlBackgroundColor.setFill()
            path.fill()
            NSColor.lungfishDanger.setStroke()
            path.lineWidth = 1.5
            path.stroke()
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

    override func accessibilityChildren() -> [Any]? {
        if let cache = accessibilityElementsCache { return cache }
        var children: [NSAccessibilityElement] = []
        for slot in slots {
            children.append(makeAccessibilityElement(for: slot, slot: .h1))
            children.append(makeAccessibilityElement(for: slot, slot: .h2))
        }
        accessibilityElementsCache = children
        return children
    }

    private func makeAccessibilityElement(for slot: Slot, slot tapeSlot: HaplotypeSlot) -> NSAccessibilityElement {
        let value = cellLabel(tapeSlot == .h1 ? slot.h1 : slot.h2)
        let element = NSAccessibilityElement()
        element.setAccessibilityRole(.button)
        element.setAccessibilityFrameInParentSpace(bounds)
        let label = [sampleAccessibilityLabel, slot.locus, tapeSlot.displayName, value]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        element.setAccessibilityLabel(label)
        element.setAccessibilityParent(self)
        return element
    }

    private func cellLabel(_ cell: Cell) -> String {
        switch cell {
        case .empty: return "absent"
        case .reference(_, let l), .manual(_, let l): return l
        case .recombinant(_, _, let l): return l
        case .error(let l): return l
        }
    }
}

extension AnnotationColor {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}
