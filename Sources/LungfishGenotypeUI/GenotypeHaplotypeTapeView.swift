import AppKit
import LungfishCore
import LungfishIO
import LungfishKit

@MainActor
final class GenotypeHaplotypeTapeView: NSView {
    enum Cell: Equatable {
        case reference(tokenIndex: Int, label: String)
        case weakReference(tokenIndex: Int, label: String)
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
        let h1Semantics: TargetSemantics?
        let h2Semantics: TargetSemantics?

        init(
            locus: String,
            h1: Cell,
            h2: Cell,
            h1Semantics: TargetSemantics? = nil,
            h2Semantics: TargetSemantics? = nil
        ) {
            self.locus = locus
            self.h1 = h1
            self.h2 = h2
            self.h1Semantics = h1Semantics
            self.h2Semantics = h2Semantics
        }

        /// Scientific cell equality intentionally excludes presentation-only
        /// accessibility metadata so existing row snapshots remain stable
        /// when editability/source narration changes.
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.locus == rhs.locus
                && lhs.h1 == rhs.h1
                && lhs.h2 == rhs.h2
        }
    }

    struct TargetSemantics: Equatable {
        let value: String
        let status: GenotypeHaplotypeCallStatus
        let source: GenotypeEffectiveHaplotypeValue.Source
        let isEditable: Bool
    }

    private(set) var swatchCount: Int = 0
    var sampleAccessibilityLabel: String = "" {
        didSet { refreshTargetButtons() }
    }
    var onTargetActivated: ((String, HaplotypeSlot) -> Void)?
    var showOverrideHatching: ((Slot, HaplotypeSlot) -> Bool)? = nil
    var isReviewSelected: Bool = false {
        didSet {
            guard oldValue != isReviewSelected else { return }
            accessibilityElementsCache = nil
            refreshTargetButtons()
            setNeedsDisplay(bounds)
        }
    }
    var selectedLocus: String? {
        didSet {
            guard oldValue != selectedLocus else { return }
            accessibilityElementsCache = nil
            refreshTargetButtons()
            setNeedsDisplay(bounds)
        }
    }

    private var slots: [Slot] = []
    private struct TargetKey: Hashable {
        let locus: String
        let slot: HaplotypeSlot
    }
    private var targetButtons: [TargetKey: HaplotypeTapeTargetButton] = [:]

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
        refreshTargetButtons()
        setNeedsDisplay(bounds)
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        refreshTargetButtons()
    }

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
        drawSelectedLocusIndicator(columnWidth: columnWidth)
    }

    private func drawSelectedLocusIndicator(columnWidth: CGFloat) {
        guard isReviewSelected,
              let selectedLocus,
              let index = slots.firstIndex(where: { $0.locus == selectedLocus }) else {
            return
        }
        let x = CGFloat(index) * columnWidth
        let rect = NSRect(
            x: x + 1.5,
            y: 1.5,
            width: max(0, columnWidth - 3.0),
            height: max(0, bounds.height - 3.0)
        )
        guard rect.width > 0, rect.height > 0 else { return }

        let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        let separator = selectionSeparatorColor()
        separator.setStroke()
        path.lineWidth = 4.0
        path.stroke()

        NSColor.keyboardFocusIndicatorColor.setStroke()
        path.lineWidth = 2.0
        path.stroke()
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
        case .weakReference(let i, _):
            weakSupportColor(forTokenIndex: i).setFill()
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
        if label == "?" { return "?" }
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

    private func weakSupportColor(forTokenIndex tokenIndex: Int) -> NSColor {
        tokenNSColor(tokenIndex: tokenIndex).withAlphaComponent(0.5)
    }

    private func selectionSeparatorColor() -> NSColor {
        if let match = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
           match == .darkAqua {
            return NSColor.black.withAlphaComponent(0.72)
        }
        return NSColor.white.withAlphaComponent(0.86)
    }

    // MARK: Accessibility

    private var accessibilityElementsCache: [NSView]?
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
        let children = slots.flatMap { slot in
            HaplotypeSlot.allCases.compactMap {
                targetButtons[.init(locus: slot.locus, slot: $0)]
            }
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

    private func refreshTargetButtons() {
        guard !slots.isEmpty, bounds.width > 0, bounds.height > 0 else {
            if slots.isEmpty {
                for button in targetButtons.values {
                    button.removeFromSuperview()
                }
                targetButtons.removeAll()
                accessibilityElementsCache = []
            }
            return
        }
        let columnWidth = bounds.width / CGFloat(slots.count)
        let halfHeight = bounds.height / 2
        var active = Set<TargetKey>()
        for (index, value) in slots.enumerated() {
            for slot in HaplotypeSlot.allCases {
                let key = TargetKey(locus: value.locus, slot: slot)
                active.insert(key)
                let button: HaplotypeTapeTargetButton
                if let existing = targetButtons[key] {
                    button = existing
                } else {
                    button = HaplotypeTapeTargetButton(
                        locus: value.locus,
                        slot: slot
                    )
                    button.onActivate = { [weak self] locus, slot in
                        self?.onTargetActivated?(locus, slot)
                    }
                    targetButtons[key] = button
                    addSubview(button)
                }
                let cell = slot == .h1 ? value.h1 : value.h2
                let semantics = slot == .h1
                    ? value.h1Semantics : value.h2Semantics
                let status = semantics?.status
                    ?? inferredStatus(for: cell)
                let source = semantics?.source
                    ?? inferredSource(for: cell)
                let effectiveValue = semantics?.value ?? cellLabel(cell)
                let selected = isReviewSelected
                    && selectedLocus == value.locus
                button.frame = NSRect(
                    x: CGFloat(index) * columnWidth,
                    y: slot == .h1 ? 0 : halfHeight,
                    width: columnWidth,
                    height: halfHeight
                )
                button.setAccessibilityLabel(
                    [
                        sampleAccessibilityLabel,
                        value.locus,
                        slot.displayName,
                        effectiveValue,
                        "status",
                        GenotypeHaplotypeCallBandSnapshot.statusLabel(status),
                        "source",
                        GenotypeHaplotypeCallBandSnapshot.sourceLabel(source),
                        selected ? "selected" : "",
                    ]
                    .filter { !$0.isEmpty }
                    .joined(separator: " ")
                )
                button.setAccessibilitySelected(selected)
                button.setAccessibilityHelp(
                    semantics?.isEditable == false
                        ? "Opens read-only call evidence."
                        : "Opens call evidence and override editing."
                )
                button.setAccessibilityIdentifier(
                    "haplotype-call-\(sampleAccessibilityLabel)-\(value.locus)-\(slot.rawValue)"
                )
            }
        }
        for key in Set(targetButtons.keys).subtracting(active) {
            targetButtons.removeValue(forKey: key)?.removeFromSuperview()
        }
        accessibilityElementsCache = nil
    }

    private func inferredStatus(
        for cell: Cell
    ) -> GenotypeHaplotypeCallStatus {
        switch cell {
        case .notAssayed:
            return .notAssayed
        case .error:
            return .noHaplotype
        case .unanalyzed:
            return .noHaplotype
        case .empty, .reference, .weakReference, .manual, .recombinant:
            return .called
        }
    }

    private func inferredSource(
        for cell: Cell
    ) -> GenotypeEffectiveHaplotypeValue.Source {
        if case .manual = cell {
            return .analystOverride
        }
        return .pipeline
    }

    private func cellLabel(_ cell: Cell) -> String {
        switch cell {
        case .empty: return "not observed"
        case .reference(_, let l), .weakReference(_, let l), .manual(_, let l): return l
        case .recombinant(_, _, let l): return l
        case .error(let l): return l
        case .notAssayed(let l): return l
        case .unanalyzed(let count):
            return count > 0 ? "unanalyzed (\(count) genotypes observed)" : "unanalyzed"
        }
    }
}

@MainActor
private final class HaplotypeTapeTargetButton: NSButton {
    let locus: String
    let haplotypeSlot: HaplotypeSlot
    var onActivate: ((String, HaplotypeSlot) -> Void)?

    init(locus: String, slot: HaplotypeSlot) {
        self.locus = locus
        self.haplotypeSlot = slot
        super.init(frame: .zero)
        title = ""
        isBordered = false
        focusRingType = .exterior
        target = self
        action = #selector(activate(_:))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { true }

    override func accessibilityPerformPress() -> Bool {
        performClick(nil)
        return true
    }

    override func keyDown(with event: NSEvent) {
        let characters = event.charactersIgnoringModifiers
        if event.keyCode == 36
            || event.keyCode == 76
            || event.keyCode == 49
            || characters == "\r"
            || characters == "\n"
            || characters == " " {
            performClick(nil)
            return
        }
        super.keyDown(with: event)
    }

    @objc private func activate(_ sender: NSButton) {
        onActivate?(locus, haplotypeSlot)
    }

    override func draw(_ dirtyRect: NSRect) {
        if window?.firstResponder === self {
            NSFocusRingPlacement.only.set()
            bounds.fill()
        }
    }
}

#if DEBUG
extension GenotypeHaplotypeTapeView {
    var testingSelectedLocus: String? { selectedLocus }
    var testingIsReviewSelected: Bool { isReviewSelected }

    func testingTargetButton(
        locus: String,
        slot: HaplotypeSlot
    ) -> NSButton? {
        refreshTargetButtons()
        return targetButtons[.init(locus: locus, slot: slot)]
    }

    func testingFillColor(for cell: Cell) -> NSColor? {
        switch cell {
        case .empty:
            return tokenNSColor(tokenIndex: 0)
        case .reference(let i, _), .manual(let i, _):
            return tokenNSColor(tokenIndex: i)
        case .weakReference(let i, _):
            return weakSupportColor(forTokenIndex: i)
        case .error, .notAssayed, .unanalyzed:
            return NSColor.controlBackgroundColor
        case .recombinant:
            return nil
        }
    }
}
#endif

extension AnnotationColor {
    var nsColor: NSColor {
        NSColor(srgbRed: CGFloat(red), green: CGFloat(green), blue: CGFloat(blue), alpha: CGFloat(alpha))
    }
}
