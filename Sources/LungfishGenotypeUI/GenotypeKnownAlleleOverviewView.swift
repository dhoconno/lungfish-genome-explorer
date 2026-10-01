import AppKit
import LungfishIO
import LungfishKit

/// Compact, record-backed overview of one known MHC reference allele.
///
/// The view deliberately renders only precomputed reference annotations. It does not infer
/// exons, coding regions, translations, or candidate-relative differences.
@MainActor
final class GenotypeKnownAlleleOverviewView: NSView {
    var onFeatureInspection: ((ONTMHCReferenceVisualizationFeature?) -> Void)?

    private let coordinateRuler = CoordinateRulerView()
    private let nucleotideStrip = NucleotideStripView()
    private let geneLane = FeatureLaneView(kind: "gene", color: .systemTeal)
    private let cdsLane = FeatureLaneView(kind: "CDS", color: .systemBlue)
    private let exonLane = FeatureLaneView(kind: "exon", color: .systemPurple)
    private let translationLane = FeatureLaneView(kind: "translation", color: .systemOrange)
    private var selectedFeature: ONTMHCReferenceVisualizationFeature?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("knownAlleleOverview")
        setAccessibilityRole(.group)
        buildHierarchy()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityIdentifier("knownAlleleOverview")
        setAccessibilityRole(.group)
        buildHierarchy()
    }

    func configure(record: ONTMHCReferenceVisualizationRecord) {
        selectedFeature = nil
        refreshHighlight()
        onFeatureInspection?(nil)
        let sequenceLength = record.sequence.count
        coordinateRuler.sequenceLength = sequenceLength
        nucleotideStrip.sequence = record.sequence

        geneLane.configure(
            features: record.features.filter { $0.type.caseInsensitiveCompare("gene") == .orderedSame },
            sequenceLength: sequenceLength
        )
        cdsLane.configure(
            features: record.features.filter { $0.type.caseInsensitiveCompare("CDS") == .orderedSame },
            sequenceLength: sequenceLength
        )
        exonLane.configure(
            features: record.features.filter { $0.type.caseInsensitiveCompare("exon") == .orderedSame },
            sequenceLength: sequenceLength
        )

        let codingFeatures = record.features.filter {
            $0.type.caseInsensitiveCompare("CDS") == .orderedSame
        }
        if let translation = record.annotatedTranslation,
           !translation.isEmpty,
           let sourceOrdinal = translationSourceOrdinal(
               for: translation,
               features: record.features
           ) {
            let translationFeatures = codingFeatures.filter {
                $0.sourceOrdinal == sourceOrdinal
            }
            let labelsBySource = sourceLabels(for: translationFeatures)
            translationLane.setAccessibilityValue(translation)
            translationLane.configure(
                blocks: translationFeatures.map {
                    .init(
                        start: $0.start,
                        end: $0.end,
                        sourceOrdinal: $0.sourceOrdinal,
                        label: labelsBySource[$0.sourceOrdinal] ?? featureLabel(for: $0),
                        help: featureHelp(for: $0, annotatedTranslation: translation),
                        feature: $0
                    )
                },
                sequenceLength: sequenceLength
            )
        } else {
            translationLane.setAccessibilityValue(nil)
            translationLane.configure(blocks: [], sequenceLength: sequenceLength)
        }
    }

    /// Tells every lane which feature is highlighted so exactly one block,
    /// across all lanes, reports and draws the highlighted state.
    private func refreshHighlight() {
        for lane in [geneLane, cdsLane, exonLane, translationLane] {
            lane.highlightedFeature = selectedFeature
        }
    }

    private func buildHierarchy() {
        for lane in [geneLane, cdsLane, exonLane, translationLane] {
            lane.onFeatureHover = { [weak self] feature in
                guard let self else { return }
                self.onFeatureInspection?(feature ?? self.selectedFeature)
            }
            lane.onFeatureSelect = { [weak self] feature in
                guard let self else { return }
                self.selectedFeature = feature
                self.refreshHighlight()
                self.onFeatureInspection?(feature)
            }
            lane.onFeatureClear = { [weak self] in
                guard let self else { return }
                self.selectedFeature = nil
                self.refreshHighlight()
                self.onFeatureInspection?(nil)
            }
        }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let rows = [
            makeRow(title: "Coordinates", track: coordinateRuler, height: 30),
            makeRow(title: "Sequence", track: nucleotideStrip, height: 28),
            makeRow(title: "Gene", track: geneLane, height: 26),
            makeRow(title: "CDS", track: cdsLane, height: 26),
            makeRow(title: "Exon", track: exonLane, height: 26),
            makeRow(title: "Translation", track: translationLane, height: 30),
        ]
        for row in rows {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
        ])
    }

    private func makeRow(title: String, track: NSView, height: CGFloat) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 76).isActive = true

        track.translatesAutoresizingMaskIntoConstraints = false
        track.heightAnchor.constraint(equalToConstant: height).isActive = true

        let row = NSStackView(views: [label, track])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.translatesAutoresizingMaskIntoConstraints = false
        track.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }
}

@MainActor
private final class CoordinateRulerView: NSView {
    var sequenceLength = 0 {
        didSet {
            setAccessibilityValue(sequenceLength > 0 ? "1–\(sequenceLength)" : "")
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("knownAlleleCoordinateRuler")
        setAccessibilityRole(.valueIndicator)
        setAccessibilityLabel("1-based sequence coordinates")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityIdentifier("knownAlleleCoordinateRuler")
        setAccessibilityRole(.valueIndicator)
        setAccessibilityLabel("1-based sequence coordinates")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard sequenceLength > 0, bounds.width > 0 else { return }

        let lineY: CGFloat = 8
        NSColor.separatorColor.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 0, y: lineY))
        line.line(to: NSPoint(x: bounds.maxX, y: lineY))
        line.stroke()

        let positions = Array(Set([1, max(1, (sequenceLength + 1) / 2), sequenceLength])).sorted()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for position in positions {
            let fraction = sequenceLength == 1 ? 0 : CGFloat(position - 1) / CGFloat(sequenceLength - 1)
            let x = fraction * bounds.width
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: x, y: lineY - 3))
            tick.line(to: NSPoint(x: x, y: lineY + 3))
            tick.stroke()

            let string = "\(position)" as NSString
            let size = string.size(withAttributes: attributes)
            let textX = min(max(0, x - size.width / 2), max(0, bounds.width - size.width))
            string.draw(at: NSPoint(x: textX, y: 15), withAttributes: attributes)
        }
    }
}

@MainActor
private final class NucleotideStripView: NSView {
    var sequence = "" {
        didSet {
            setAccessibilityValue(sequence)
            needsDisplay = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityIdentifier("knownAlleleNucleotideStrip")
        setAccessibilityRole(.valueIndicator)
        setAccessibilityLabel("Nucleotide sequence")
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityIdentifier("knownAlleleNucleotideStrip")
        setAccessibilityRole(.valueIndicator)
        setAccessibilityLabel("Nucleotide sequence")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !sequence.isEmpty else { return }

        let bases = Array(sequence.uppercased())
        let baseWidth = bounds.width / CGFloat(bases.count)
        for (index, base) in bases.enumerated() {
            let rect = NSRect(
                x: CGFloat(index) * baseWidth,
                y: 2,
                width: max(1, baseWidth),
                height: max(0, bounds.height - 4)
            )
            color(for: base).withAlphaComponent(0.78).setFill()
            rect.fill()

            if baseWidth >= 11 {
                let text = String(base) as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
                    .foregroundColor: NSColor.textColor,
                ]
                let size = text.size(withAttributes: attributes)
                text.draw(
                    at: NSPoint(
                        x: rect.midX - size.width / 2,
                        y: rect.midY - size.height / 2
                    ),
                    withAttributes: attributes
                )
            }
        }
    }

    private func color(for base: Character) -> NSColor {
        switch base {
        case "A": return .systemGreen
        case "C": return .systemBlue
        case "G": return .systemOrange
        case "T", "U": return .lungfishDanger
        default: return .systemGray
        }
    }
}

@MainActor
private final class FeatureLaneView: NSView {
    struct Block {
        let start: Int
        let end: Int
        let sourceOrdinal: Int
        let label: String
        let help: String?
        let feature: ONTMHCReferenceVisualizationFeature
    }

    var onFeatureHover: ((ONTMHCReferenceVisualizationFeature?) -> Void)?
    var onFeatureSelect: ((ONTMHCReferenceVisualizationFeature) -> Void)?
    var onFeatureClear: (() -> Void)?

    /// The feature the overview has highlighted, which may live in any lane.
    var highlightedFeature: ONTMHCReferenceVisualizationFeature? {
        didSet {
            for (block, view) in zip(blocks, blockViews) {
                view.isHighlighted = highlightedFeature == block.feature
            }
        }
    }

    private var blockViews: [FeatureBlockView] { subviews.compactMap { $0 as? FeatureBlockView } }
    private var focusedIndex: Int?
    private let kind: String
    private let blockColor: NSColor
    private var blocks: [Block] = []
    private var sequenceLength = 0

    init(kind: String, color: NSColor) {
        self.kind = kind
        self.blockColor = color
        super.init(frame: .zero)
        setAccessibilityIdentifier("knownAllele\(kind)Lane")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(kind) annotation lane")
        focusRingType = .default
    }

    required init?(coder: NSCoder) {
        nil
    }

    // MARK: Keyboard

    // A lane with no blocks has nothing to focus, so Tab skips it.
    override var acceptsFirstResponder: Bool { !blocks.isEmpty }

    override func becomeFirstResponder() -> Bool {
        guard !blocks.isEmpty else { return false }
        if focusedIndex == nil || focusedIndex! >= blocks.count {
            focusedIndex = blocks.firstIndex { $0.feature == highlightedFeature } ?? 0
        }
        focusChanged()
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        noteFocusRingMaskChanged()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard !blocks.isEmpty else { return super.keyDown(with: event) }
        let index = min(focusedIndex ?? 0, blocks.count - 1)
        switch event.keyCode {
        case 123: // Left
            focusedIndex = max(0, index - 1)
            focusChanged()
        case 124: // Right
            focusedIndex = min(blocks.count - 1, index + 1)
            focusChanged()
        case 36, 76, 49: // Return, Enter, Space
            focusedIndex = index
            onFeatureSelect?(blocks[index].feature)
        case 53 where highlightedFeature != nil: // Escape
            onFeatureClear?()
        default:
            super.keyDown(with: event)
        }
    }

    /// Moving the keyboard focus shows the feature the way hovering it does.
    private func focusChanged() {
        needsDisplay = true
        noteFocusRingMaskChanged()
        if let index = focusedIndex, index < blocks.count {
            onFeatureHover?(blocks[index].feature)
        }
    }

    override var focusRingMaskBounds: NSRect {
        guard let index = focusedIndex, index < subviews.count else { return bounds }
        return subviews[index].frame.insetBy(dx: -2, dy: -2)
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 4, yRadius: 4).fill()
    }

    func configure(features: [ONTMHCReferenceVisualizationFeature], sequenceLength: Int) {
        let labelsBySource = sourceLabels(for: features)
        configure(
            blocks: features.map {
                Block(
                    start: $0.start,
                    end: $0.end,
                    sourceOrdinal: $0.sourceOrdinal,
                    label: labelsBySource[$0.sourceOrdinal] ?? featureLabel(for: $0),
                    help: featureHelp(for: $0),
                    feature: $0
                )
            },
            sequenceLength: sequenceLength
        )
    }

    func configure(blocks: [Block], sequenceLength: Int) {
        self.blocks = blocks
        self.sequenceLength = sequenceLength
        focusedIndex = nil
        subviews.forEach { $0.removeFromSuperview() }

        for block in blocks {
            let blockView = FeatureBlockView(
                color: blockColor,
                label: block.label,
                help: block.help,
                onHover: { [weak self] isHovering in
                    self?.onFeatureHover?(isHovering ? block.feature : nil)
                },
                onSelect: { [weak self] in
                    self?.onFeatureSelect?(block.feature)
                },
                onClear: { [weak self] in
                    self?.onFeatureClear?()
                }
            )
            blockView.setAccessibilityIdentifier(
                "knownAlleleFeatureBlock.\(kind).\(block.sourceOrdinal).\(block.start).\(block.end)"
            )
            blockView.setAccessibilityLabel(block.label)
            blockView.setAccessibilityHelp(block.help)
            blockView.isHighlighted = highlightedFeature == block.feature
            addSubview(blockView)
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        guard sequenceLength > 0 else {
            subviews.forEach { $0.frame = .zero }
            return
        }

        for (block, view) in zip(blocks, subviews) {
            let startFraction = CGFloat(block.start) / CGFloat(sequenceLength)
            let endFraction = CGFloat(block.end) / CGFloat(sequenceLength)
            let x = bounds.width * startFraction
            view.frame = NSRect(
                x: x,
                y: 3,
                width: max(2, bounds.width * (endFraction - startFraction)),
                height: max(0, bounds.height - 6)
            )
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: bounds.midY - 0.5, width: bounds.width, height: 1).fill()
    }
}

@MainActor
private final class FeatureBlockView: NSView {
    private let color: NSColor
    private let labelField: NSTextField
    private let onHover: (Bool) -> Void
    private let onSelect: () -> Void
    private let onClear: () -> Void

    /// True while this block's feature is the highlighted one. Drawn as a
    /// heavy outline, so the state never rests on colour alone, and
    /// reported to assistive clients as the selected state.
    var isHighlighted = false {
        didSet {
            guard isHighlighted != oldValue else { return }
            setAccessibilitySelected(isHighlighted)
            needsDisplay = true
        }
    }

    init(
        color: NSColor,
        label: String,
        help: String?,
        onHover: @escaping (Bool) -> Void,
        onSelect: @escaping () -> Void,
        onClear: @escaping () -> Void
    ) {
        self.color = color
        self.labelField = NSTextField(labelWithString: label)
        self.onHover = onHover
        self.onSelect = onSelect
        self.onClear = onClear
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityCustomActions([
            AccessibilityCellActions.makeAction(name: "Highlight Feature") { [weak self] in self?.onSelect() },
            AccessibilityCellActions.makeAction(name: "Clear Highlight") { [weak self] in self?.onClear() },
        ])
        toolTip = [label, help].compactMap { $0 }.joined(separator: " — ")
        labelField.font = .systemFont(ofSize: 9, weight: .semibold)
        labelField.textColor = .selectedControlTextColor
        labelField.alignment = .center
        labelField.lineBreakMode = .byTruncatingTail
        labelField.setAccessibilityElement(false)
        addSubview(labelField)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onHover(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover(false)
    }

    override func mouseDown(with event: NSEvent) {
        onSelect()
    }

    /// Pressing the block highlights its feature, as a click does.
    override func accessibilityPerformPress() -> Bool {
        onSelect()
        return true
    }

    override func layout() {
        super.layout()
        labelField.frame = bounds.insetBy(dx: 4, dy: 2)
        let usefulLabelWidth = min(labelField.intrinsicContentSize.width + 8, 120)
        labelField.isHidden = bounds.width < usefulLabelWidth
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        color.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        if isHighlighted {
            NSColor.labelColor.setStroke()
            let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            outline.lineWidth = 2
            outline.stroke()
        }
    }
}

private func featureLabel(for feature: ONTMHCReferenceVisualizationFeature) -> String {
    let type = feature.type.lowercased()
    if type == "exon",
       let number = firstQualifierValue(in: feature, keys: ["exon_number", "number"]) {
        return "Exon \(number)"
    }

    if let biologicalName = firstQualifierValue(
        in: feature,
        keys: ["gene", "allele", "product", "note"]
    ) {
        return biologicalName
    }
    return feature.type
}

private func featureHelp(
    for feature: ONTMHCReferenceVisualizationFeature,
    annotatedTranslation: String? = nil
) -> String? {
    var details: [String] = []
    if let location = feature.rawGenBankLocation, !location.isEmpty {
        details.append(location)
    }
    if !feature.strand.isEmpty {
        details.append("strand \(feature.strand)")
    }
    if let annotatedTranslation, !annotatedTranslation.isEmpty {
        details.append("annotated translation: \(annotatedTranslation)")
    }
    return details.isEmpty ? nil : details.joined(separator: ", ")
}

private func firstQualifierValue(
    in feature: ONTMHCReferenceVisualizationFeature,
    keys: [String]
) -> String? {
    for key in keys {
        for actualKey in feature.qualifiers.keys.sorted()
        where actualKey.caseInsensitiveCompare(key) == .orderedSame {
            if let value = feature.qualifiers[actualKey]?.first(where: { !$0.isEmpty }) {
                return value
            }
        }
    }
    return nil
}

private func sourceLabels(
    for features: [ONTMHCReferenceVisualizationFeature]
) -> [Int: String] {
    var labels: [Int: String] = [:]
    for feature in features where labels[feature.sourceOrdinal] == nil {
        labels[feature.sourceOrdinal] = featureLabel(for: feature)
    }
    return labels
}

private func translationSourceOrdinal(
    for annotatedTranslation: String,
    features: [ONTMHCReferenceVisualizationFeature]
) -> Int? {
    features.first { feature in
        feature.qualifiers.keys.sorted().contains { key in
            guard key.caseInsensitiveCompare("translation") == .orderedSame else {
                return false
            }
            return feature.qualifiers[key]?.contains(annotatedTranslation) == true
        }
    }?.sourceOrdinal
}
