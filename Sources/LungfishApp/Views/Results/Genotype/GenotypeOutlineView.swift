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
        stack.alignment = .leading
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

    private func makeHeaderRow(loci: [String]) -> NSView {
        let perLocus: CGFloat = loci.count > 12 ? 22 : (loci.count > 8 ? 28 : 36)
        let tapeWidth = max(140, CGFloat(loci.count) * perLocus)
        let container = NSStackView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 6
        container.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)

        let spacer = NSTextField(labelWithString: " ")
        spacer.font = NSFont.systemFont(ofSize: 9)
        spacer.widthAnchor.constraint(equalToConstant: 24).isActive = true

        let blockSpacer = NSTextField(labelWithString: " ")
        blockSpacer.font = NSFont.systemFont(ofSize: 9)
        blockSpacer.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let animalHeader = NSTextField(labelWithString: "Animal")
        animalHeader.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        animalHeader.textColor = .secondaryLabelColor

        // Locus header strip — one short label per column, sized to match the
        // tape's per-locus width so labels line up over their swatches.
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
        lociHeader.widthAnchor.constraint(equalToConstant: tapeWidth).isActive = true

        let noteHeader = NSTextField(labelWithString: "!")
        noteHeader.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        noteHeader.textColor = .secondaryLabelColor
        noteHeader.toolTip = "Notes — hover the alert glyph on a row to see review issues."
        noteHeader.widthAnchor.constraint(equalToConstant: 18).isActive = true
        noteHeader.alignment = .center

        container.addArrangedSubview(spacer)
        container.addArrangedSubview(blockSpacer)
        container.addArrangedSubview(animalHeader)
        container.addArrangedSubview(lociHeader)
        container.addArrangedSubview(noteHeader)
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
            stack.addArrangedSubview(makeHeaderRow(loci: first.loci))
        }
        for row in rows {
            stack.addArrangedSubview(makeRow(row))
        }
    }

    private func makeRow(_ row: Row) -> NSView {
        let container = NSStackView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 6
        container.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 4, right: 8)

        let disclosure = NSTextField(labelWithString: "\u{25B6}")
        disclosure.font = NSFont.systemFont(ofSize: 10)
        disclosure.textColor = .secondaryLabelColor

        let blockGlyph = NSTextField(labelWithString: blockGlyphSymbol(row.blockKind))
        blockGlyph.font = NSFont.systemFont(ofSize: 11)
        blockGlyph.textColor = blockGlyphColor(row.blockKind)
        blockGlyph.toolTip = blockGlyphTooltip(row.blockKind)

        let animalLabel = NSTextField(labelWithString: row.animalId)
        animalLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        animalLabel.textColor = .labelColor

        let tape = GenotypeHaplotypeTapeView()
        tape.translatesAutoresizingMaskIntoConstraints = false
        tape.configure(loci: row.loci, slots: row.tapeSlots)
        tape.sampleAccessibilityLabel = row.animalId
        // Adaptive per-locus width: keep cells readable at 7 loci (36pt each)
        // but scale down to 22pt minimum once the bundle has many observed
        // loci so a 17-locus run fits without horizontally crowding the
        // comment column.
        let perLocus: CGFloat = row.loci.count > 12 ? 22 : (row.loci.count > 8 ? 28 : 36)
        let tapeWidth = max(140, CGFloat(row.loci.count) * perLocus)
        NSLayoutConstraint.activate([
            tape.widthAnchor.constraint(equalToConstant: tapeWidth),
            tape.heightAnchor.constraint(equalToConstant: 22),
        ])

        let noteGlyph = makeNoteGlyph(for: row)

        container.addArrangedSubview(disclosure)
        container.addArrangedSubview(blockGlyph)
        container.addArrangedSubview(animalLabel)
        container.addArrangedSubview(tape)
        container.addArrangedSubview(noteGlyph)

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        container.addGestureRecognizer(click)
        container.identifier = NSUserInterfaceItemIdentifier(row.animalId)
        return container
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
        label.textColor = row.noteIssueCount > 0 ? NSColor.systemOrange : .clear
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
        case .regionalRecombinant: return NSColor.systemOrange
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
