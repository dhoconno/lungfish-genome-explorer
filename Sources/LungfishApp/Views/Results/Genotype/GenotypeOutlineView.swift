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

        init(
            animalId: String,
            gsId: String?,
            loci: [String],
            tapeSlots: [GenotypeHaplotypeTapeView.Slot],
            blockKind: GenotypeBlockKind,
            commentSummary: String,
            noteIssueCount: Int
        ) {
            self.animalId = animalId
            self.gsId = gsId
            self.loci = loci
            self.tapeSlots = tapeSlots
            self.blockKind = blockKind
            self.commentSummary = commentSummary
            self.noteIssueCount = noteIssueCount
        }

        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.animalId == rhs.animalId && lhs.gsId == rhs.gsId &&
            lhs.loci == rhs.loci && lhs.blockKind == rhs.blockKind &&
            lhs.commentSummary == rhs.commentSummary &&
            lhs.noteIssueCount == rhs.noteIssueCount &&
            lhs.tapeSlots == rhs.tapeSlots
        }
    }

    var onRowSelected: ((String) -> Void)?
    var onRowDisclosure: ((String, Bool) -> Void)?
    /// Fires when the analyst clicks a single locus cell in the tape.
    /// Passes (animalId, locusName). The controller shows a popover at
    /// that cell's frame with `GenotypeCallEvidenceView`.
    var onLocusCellClicked: ((String, String, NSView, NSRect) -> Void)?
    private(set) var numberOfRows: Int = 0
    private var rows: [Row] = []
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
        stack.spacing = 1

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

    /// Fixed-width gutter for the leading "fixed" widgets (disclosure +
    /// block glyph + animal label). All rows + the header share this so
    /// the locus columns align vertically across the whole table.
    private static let leadingGutter: CGFloat = 24 + 6 + 16 + 6 + 80
    /// Fixed-width trailing column for the progressive-disclosure note
    /// glyph. Matches the per-row note column.
    private static let trailingGutter: CGFloat = 18

    private func makeHeaderRow(loci: [String]) -> NSView {
        let container = NSStackView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 6
        container.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)

        // Single fixed-width leading container holding disclosure +
        // block-glyph spacer + "Animal" label. Using one container keeps
        // the gutter width identical across rows even when the disclosure
        // glyph changes width.
        let leading = NSStackView()
        leading.orientation = .horizontal
        leading.spacing = 6
        leading.alignment = .centerY
        let spacer = NSTextField(labelWithString: " ")
        spacer.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let blockSpacer = NSTextField(labelWithString: " ")
        blockSpacer.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let animalHeader = NSTextField(labelWithString: "Animal")
        animalHeader.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        animalHeader.textColor = .secondaryLabelColor
        animalHeader.widthAnchor.constraint(equalToConstant: 80).isActive = true
        leading.addArrangedSubview(spacer)
        leading.addArrangedSubview(blockSpacer)
        leading.addArrangedSubview(animalHeader)
        leading.widthAnchor.constraint(equalToConstant: Self.leadingGutter).isActive = true

        // Locus header columns — one label per locus, evenly distributed
        // across whatever horizontal space the row gets. The tape view
        // in each row uses the exact same column layout so the swatches
        // line up under the headers.
        let lociHeader = NSStackView()
        lociHeader.translatesAutoresizingMaskIntoConstraints = false
        lociHeader.orientation = .horizontal
        lociHeader.distribution = .fillEqually
        lociHeader.spacing = 0
        for locus in loci {
            let label = NSTextField(labelWithString: shortLocusLabel(locus))
            label.font = NSFont.systemFont(ofSize: 9, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            label.lineBreakMode = .byTruncatingMiddle
            label.toolTip = locus
            lociHeader.addArrangedSubview(label)
        }

        let noteHeader = NSTextField(labelWithString: "!")
        noteHeader.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        noteHeader.textColor = .secondaryLabelColor
        noteHeader.toolTip = "Notes — hover the alert glyph on a row to see review issues."
        noteHeader.widthAnchor.constraint(equalToConstant: Self.trailingGutter).isActive = true
        noteHeader.alignment = .center

        container.addArrangedSubview(leading)
        container.addArrangedSubview(lociHeader)
        container.addArrangedSubview(noteHeader)
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
        let container = NSStackView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 6
        container.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        // Fixed-width leading gutter so every row's locus columns start at
        // the same x-coordinate as the header. Disclosure + block glyph +
        // animal label all live inside one width-anchored NSStackView.
        let leading = NSStackView()
        leading.orientation = .horizontal
        leading.spacing = 6
        leading.alignment = .centerY
        let disclosure = NSTextField(labelWithString: "\u{25B6}")
        disclosure.font = NSFont.systemFont(ofSize: 10)
        disclosure.textColor = .secondaryLabelColor
        disclosure.widthAnchor.constraint(equalToConstant: 24).isActive = true
        let blockGlyph = NSTextField(labelWithString: blockGlyphSymbol(row.blockKind))
        blockGlyph.font = NSFont.systemFont(ofSize: 11)
        blockGlyph.textColor = blockGlyphColor(row.blockKind)
        blockGlyph.toolTip = blockGlyphTooltip(row.blockKind)
        blockGlyph.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let animalLabel = NSTextField(labelWithString: row.animalId)
        animalLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        animalLabel.textColor = .labelColor
        animalLabel.widthAnchor.constraint(equalToConstant: 80).isActive = true
        animalLabel.lineBreakMode = .byTruncatingTail
        leading.addArrangedSubview(disclosure)
        leading.addArrangedSubview(blockGlyph)
        leading.addArrangedSubview(animalLabel)
        leading.widthAnchor.constraint(equalToConstant: Self.leadingGutter).isActive = true

        let tape = GenotypeHaplotypeTapeView()
        tape.translatesAutoresizingMaskIntoConstraints = false
        tape.configure(loci: row.loci, slots: row.tapeSlots)
        tape.sampleAccessibilityLabel = row.animalId
        // No fixed width — let the tape expand to consume all available
        // horizontal space so locus columns line up under the headers.
        // The tape draws columns as `bounds.width / slots.count`, so wider
        // frames produce proportionally wider swatches.
        tape.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tape.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            tape.heightAnchor.constraint(equalToConstant: 26),
        ])

        let noteGlyph = makeNoteGlyph(for: row)

        container.addArrangedSubview(leading)
        container.addArrangedSubview(tape)
        container.addArrangedSubview(noteGlyph)

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
        return container
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
        let rect = NSRect(x: CGFloat(index) * columnWidth, y: 0,
                          width: columnWidth, height: tape.bounds.height)
        onLocusCellClicked?(recognizer.animalId, locus, tape, rect)
    }

    /// Specialised gesture recognizer that carries the row's locus list
    /// and animal id, so the handler can compute which cell was clicked
    /// without storing per-tape state.
    private final class TapeClickRecognizer: NSClickGestureRecognizer {
        var loci: [String] = []
        var animalId: String = ""
    }

    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        guard let view = recognizer.view,
              let id = view.identifier?.rawValue else { return }
        onRowSelected?(id)
    }

    private func makeNoteGlyph(for row: Row) -> NSView {
        // Progressive-disclosure marker for review-worthy notes. Empty rows
        // render an 18pt placeholder so the column stays aligned with the
        // header. Non-empty rows show a small filled circle with the issue
        // count as a tooltip carrying the original commentSummary text.
        let label = NSTextField(labelWithString: row.noteIssueCount > 0 ? "\u{26A0}\u{FE0E}" : "")
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = row.noteIssueCount > 0 ? NSColor.lungfishDanger : .clear
        label.alignment = .center
        label.widthAnchor.constraint(equalToConstant: 18).isActive = true
        if row.noteIssueCount > 0 {
            let tooltip = row.commentSummary.isEmpty
                ? "\(row.noteIssueCount) review note\(row.noteIssueCount == 1 ? "" : "s")"
                : row.commentSummary
            label.toolTip = tooltip
            label.setAccessibilityLabel("\(row.noteIssueCount) review notes: \(tooltip)")
        }
        return label
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
