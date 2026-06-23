import AppKit
import LungfishCore
import LungfishIO

@MainActor
final class GenotypeOutlineView: NSView {
    struct Row: Equatable {
        let animalId: String
        let gsId: String?
        let loci: [String]
        let tapeSlots: [GenotypeHaplotypeTapeView.Slot]
        let blockKind: GenotypeBlockKind
        /// Full notes text — hidden by default, surfaced as a tooltip on the
        /// progressive-disclosure alert glyph when non-empty.
        let commentSummary: String
        /// Number of distinct review-worthy notes (TMH / NO HAP / TMG /
        /// special-case). Zero means no alert glyph renders.
        let noteIssueCount: Int
        /// Per-locus haplotype call text (e.g. "M2A / M3A", "ERR: TMH (...)").
        /// Kept as row data for callers that need per-locus call text.
        let perLocusCallText: [(locus: String, h1: String, h2: String, status: GenotypeHaplotypeCallStatus)]

        init(
            animalId: String,
            gsId: String?,
            loci: [String],
            tapeSlots: [GenotypeHaplotypeTapeView.Slot],
            blockKind: GenotypeBlockKind,
            commentSummary: String,
            noteIssueCount: Int,
            perLocusCallText: [(locus: String, h1: String, h2: String, status: GenotypeHaplotypeCallStatus)] = []
        ) {
            self.animalId = animalId
            self.gsId = gsId
            self.loci = loci
            self.tapeSlots = tapeSlots
            self.blockKind = blockKind
            self.commentSummary = commentSummary
            self.noteIssueCount = noteIssueCount
            self.perLocusCallText = perLocusCallText
        }

        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.animalId == rhs.animalId && lhs.gsId == rhs.gsId &&
            lhs.loci == rhs.loci && lhs.blockKind == rhs.blockKind &&
            lhs.commentSummary == rhs.commentSummary &&
            lhs.noteIssueCount == rhs.noteIssueCount &&
            lhs.tapeSlots == rhs.tapeSlots &&
            lhs.perLocusCallText.elementsEqual(rhs.perLocusCallText, by: { lhs, rhs in
                lhs.locus == rhs.locus && lhs.h1 == rhs.h1 && lhs.h2 == rhs.h2 && lhs.status == rhs.status
            })
        }
    }

    var onRowSelected: ((String) -> Void)?
    /// Fires when the analyst clicks a single locus cell in the tape.
    /// Passes (animalId, locusName). The controller updates the persistent
    /// Review inspector with `GenotypeCallEvidenceView` for that cell.
    var onLocusCellClicked: ((String, String) -> Void)?
    private(set) var numberOfRows: Int = 0
    private var rows: [Row] = []
    private var reviewSelection = ReviewSelection()
    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    private let documentView = FlippedDocumentView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildSubviews()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); buildSubviews() }

    private func buildSubviews() {

        translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        documentView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        // Stretch rows full-width so the tape gets all available horizontal
        // space; otherwise rows align leading and end at the natural width
        // of their fixed widgets, leaving a big empty gutter on the right.
        stack.alignment = .leading
        stack.distribution = .fill
        // Whitespace between rows so adjacent samples don't blur together
        // visually — especially important when many samples have similar
        // tape colours.
        stack.spacing = 4

        scrollView.documentView = documentView
        documentView.addSubview(stack)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    func configure(rows: [Row]) {
        self.rows = rows
        numberOfRows = rows.count
        rebuild()
    }

    func setReviewSelection(sample: String?, locus: String?) {
        let selection = ReviewSelection(sample: sample, locus: locus)
        guard selection != reviewSelection else { return }
        reviewSelection = selection
        rebuild()
    }

    /// Fixed-width gutter for the leading fixed widgets (block glyph +
    /// animal label). All rows + the header share this so
    /// the locus columns align vertically across the whole table.
    private static let leadingGutter: CGFloat = 16 + 6 + 80
    private func makeHeaderRow(loci: [String]) -> NSView {
        let container = NSStackView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 6
        container.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)

        // Single fixed-width leading container holding block-glyph spacer +
        // "Animal" label. Using one container keeps the gutter width
        // identical across rows.
        let leading = NSStackView()
        leading.orientation = .horizontal
        leading.spacing = 6
        leading.alignment = .centerY
        let blockSpacer = NSTextField(labelWithString: " ")
        blockSpacer.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let animalHeader = NSTextField(labelWithString: "Animal")
        animalHeader.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        animalHeader.textColor = .secondaryLabelColor
        animalHeader.widthAnchor.constraint(equalToConstant: 80).isActive = true
        leading.addArrangedSubview(blockSpacer)
        leading.addArrangedSubview(animalHeader)
        leading.widthAnchor.constraint(equalToConstant: Self.leadingGutter).isActive = true

        // Locus header columns — one label per locus, evenly distributed
        // across whatever horizontal space the row gets. The tape view
        // in each row uses the exact same column layout so the swatches
        // line up under the headers. Each label is wrapped in an NSView
        // so .fillEqually distributes the wrappers (not the intrinsic
        // text size) and the label centers inside its column.
        let lociHeader = NSStackView()
        lociHeader.translatesAutoresizingMaskIntoConstraints = false
        lociHeader.orientation = .horizontal
        lociHeader.distribution = .fillEqually
        lociHeader.spacing = 0
        for locus in loci {
            let column = NSView()
            column.translatesAutoresizingMaskIntoConstraints = false
            let shortLabel = shortLocusLabel(locus)
            let label = NSTextField(labelWithString: shortLabel)
            let isSelected = reviewSelection.locus == locus
            let font = NSFont.systemFont(ofSize: 10, weight: isSelected ? .bold : .semibold)
            label.font = font
            label.textColor = isSelected ? .controlAccentColor : .secondaryLabelColor
            if isSelected {
                label.attributedStringValue = NSAttributedString(
                    string: shortLabel,
                    attributes: [
                        .font: font,
                        .foregroundColor: NSColor.controlAccentColor,
                        .underlineStyle: NSUnderlineStyle.single.rawValue,
                    ]
                )
                label.setAccessibilityLabel("\(locus) selected")
            }
            label.alignment = .center
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = isSelected ? "\(locus) selected for review" : locus
            label.translatesAutoresizingMaskIntoConstraints = false
            column.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: column.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: column.centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: column.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(lessThanOrEqualTo: column.trailingAnchor, constant: -2),
            ])
            lociHeader.addArrangedSubview(column)
        }

        container.addArrangedSubview(leading)
        container.addArrangedSubview(lociHeader)
        // Let the locus header expand to consume all leftover width so
        // the columns line up edge-to-edge with the tape below.
        lociHeader.setContentHuggingPriority(.defaultLow, for: .horizontal)
        lociHeader.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return container
    }

    private func shortLocusLabel(_ locus: String) -> String {
        // Strip the leading "MHC-" prefix; otherwise return the locus name.
        if locus.hasPrefix("MHC-") {
            return String(locus.dropFirst("MHC-".count))
        }
        return locus
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if let first = rows.first, !first.loci.isEmpty {
            let header = makeHeaderRow(loci: first.loci)
            stack.addArrangedSubview(header)
            header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        for row in rows {
            let view = makeRow(row)
            stack.addArrangedSubview(view)
            // Pin each row's width to the stack's so the locus columns
            // line up across the whole table and the tape gets all
            // available horizontal space.
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func makeRow(_ row: Row) -> NSView {
        // Outer vertical container so selection highlighting and row sizing
        // stay consistent with other outline rows.
        let outer = NSStackView()
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 2
        outer.identifier = NSUserInterfaceItemIdentifier(row.animalId)

        let container = SelectionRowStackView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 6
        container.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)
        let isSelectedSample = reviewSelection.sample == row.animalId
        container.isReviewSelected = isSelectedSample

        // Fixed-width leading gutter so every row's locus columns start at
        // the same x-coordinate as the header. Block glyph + animal label
        // live inside one width-anchored NSStackView.
        let leading = NSStackView()
        leading.orientation = .horizontal
        leading.spacing = 6
        leading.alignment = .centerY
        let blockGlyph = NSTextField(labelWithString: blockGlyphSymbol(row.blockKind))
        blockGlyph.font = NSFont.systemFont(ofSize: 11)
        blockGlyph.textColor = blockGlyphColor(row.blockKind)
        blockGlyph.toolTip = blockGlyphTooltip(row.blockKind)
        blockGlyph.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let animalLabel = NSTextField(labelWithString: row.animalId)
        animalLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: isSelectedSample ? .bold : .semibold)
        animalLabel.textColor = .labelColor
        animalLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true
        animalLabel.lineBreakMode = .byTruncatingTail
        leading.addArrangedSubview(blockGlyph)
        leading.addArrangedSubview(animalLabel)
        leading.widthAnchor.constraint(equalToConstant: Self.leadingGutter).isActive = true

        let tape = GenotypeHaplotypeTapeView()
        tape.translatesAutoresizingMaskIntoConstraints = false
        tape.configure(loci: row.loci, slots: row.tapeSlots)
        tape.sampleAccessibilityLabel = row.animalId
        tape.isReviewSelected = isSelectedSample
        tape.selectedLocus = isSelectedSample ? reviewSelection.locus : nil
        // No fixed width — let the tape expand to consume all available
        // horizontal space so locus columns line up under the headers.
        // The tape draws columns as `bounds.width / slots.count`, so wider
        // frames produce proportionally wider swatches.
        tape.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tape.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            tape.heightAnchor.constraint(equalToConstant: 26),
        ])

        container.addArrangedSubview(leading)
        container.addArrangedSubview(tape)

        // Row-level click selects the row; cell-level click on the tape
        // opens a per-locus evidence popover so the analyst can inspect
        // a call without going through the Selection tab.
        let rowClick = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        leading.addGestureRecognizer(rowClick)
        let tapeClick = TapeClickRecognizer(
            target: self,
            action: #selector(handleTapeClick(_:))
        )
        tapeClick.loci = row.loci
        tapeClick.animalId = row.animalId
        tape.addGestureRecognizer(tapeClick)
        container.identifier = NSUserInterfaceItemIdentifier(row.animalId)

        outer.addArrangedSubview(container)
        // Pin the container's width to the outer's so the row fills the
        // table's column width. Without this the inner container shrinks
        // to its intrinsic content.
        container.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true

        return outer
    }

    @objc private func handleTapeClick(_ recognizer: NSClickGestureRecognizer) {
        guard let recognizer = recognizer as? TapeClickRecognizer,
              let tape = recognizer.view as? GenotypeHaplotypeTapeView,
              !recognizer.loci.isEmpty else { return }
        let location = recognizer.location(in: tape)
        let columnWidth = tape.bounds.width / CGFloat(recognizer.loci.count)
        guard columnWidth > 0 else { return }
        let index = max(0, min(recognizer.loci.count - 1, Int(location.x / columnWidth)))
        let locus = recognizer.loci[index]
        onLocusCellClicked?(recognizer.animalId, locus)
    }

    /// Specialised gesture recognizer that carries the row's locus list
    /// and animal id, so the handler can compute which cell was clicked
    /// without storing per-tape state.
    private final class TapeClickRecognizer: NSClickGestureRecognizer {
        var loci: [String] = []
        var animalId: String = ""
    }

    private struct ReviewSelection: Equatable {
        var sample: String?
        var locus: String?
    }

    private final class SelectionRowStackView: NSStackView {
        var isReviewSelected: Bool = false {
            didSet {
                guard oldValue != isReviewSelected else { return }
                needsDisplay = true
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            if isReviewSelected {
                let active = window?.isKeyWindow ?? true
                let base = active
                    ? NSColor.selectedContentBackgroundColor
                    : NSColor.unemphasizedSelectedContentBackgroundColor
                base.withAlphaComponent(0.14).setFill()
                let rect = bounds.insetBy(dx: 2, dy: 1)
                NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            }
            super.draw(dirtyRect)
        }
    }

    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        guard let view = recognizer.view,
              let id = view.identifier?.rawValue else { return }
        onRowSelected?(id)
    }

    private func blockGlyphSymbol(_ kind: GenotypeBlockKind) -> String {
        switch kind {
        case .blockCoherent:        return "\u{25AE}"
        case .regionalRecombinant:  return "\u{25B0}\u{25B1}"
        case .atypical:             return "\u{25B1}\u{25B0}\u{25B1}"
        case .unknown:              return "\u{00B7}"
        }
    }
    private func blockGlyphColor(_ kind: GenotypeBlockKind) -> NSColor {
        switch kind {
        case .blockCoherent:       return NSColor.systemGreen
        case .regionalRecombinant: return NSColor.lungfishDanger
        case .atypical:            return NSColor.lungfishDanger
        case .unknown:             return NSColor.secondaryLabelColor
        }
    }
    private func blockGlyphTooltip(_ kind: GenotypeBlockKind) -> String {
        switch kind {
        case .blockCoherent:       return "Block coherent"
        case .regionalRecombinant: return "Regional recombinant"
        case .atypical:            return "Atypical"
        case .unknown:             return "Unknown"
        }
    }

    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }
}

#if DEBUG
extension GenotypeOutlineView {
    var testingVisibleText: String {
        textContent(in: self).joined(separator: "\n")
    }

    var testingReviewSelectedSample: String? {
        reviewSelection.sample
    }

    var testingReviewSelectedLocus: String? {
        reviewSelection.locus
    }

    func testingSelectedTapeLocus(sample: String) -> String? {
        tapeViews(in: self)
            .first { $0.sampleAccessibilityLabel == sample && $0.testingIsReviewSelected }?
            .testingSelectedLocus
    }

    func testingHeaderIsSelected(locus: String) -> Bool {
        reviewSelection.locus == locus
    }

    private func textContent(in view: NSView) -> [String] {
        var values: [String] = []
        if let textField = view as? NSTextField {
            values.append(textField.stringValue)
        }
        for subview in view.subviews {
            values.append(contentsOf: textContent(in: subview))
        }
        return values
    }

    private func tapeViews(in view: NSView) -> [GenotypeHaplotypeTapeView] {
        var values: [GenotypeHaplotypeTapeView] = []
        if let tape = view as? GenotypeHaplotypeTapeView {
            values.append(tape)
        }
        for subview in view.subviews {
            values.append(contentsOf: tapeViews(in: subview))
        }
        return values
    }
}
#endif
