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
        let commentSummary: String

        init(
            animalId: String,
            gsId: String?,
            loci: [String],
            tapeSlots: [GenotypeHaplotypeTapeView.Slot],
            blockKind: GenotypeBlockKind,
            commentSummary: String
        ) {
            self.animalId = animalId
            self.gsId = gsId
            self.loci = loci
            self.tapeSlots = tapeSlots
            self.blockKind = blockKind
            self.commentSummary = commentSummary
        }

        static func == (lhs: Row, rhs: Row) -> Bool {
            lhs.animalId == rhs.animalId && lhs.gsId == rhs.gsId &&
            lhs.loci == rhs.loci && lhs.blockKind == rhs.blockKind &&
            lhs.commentSummary == rhs.commentSummary
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
        wantsLayer = true
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

    private func rebuild() {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
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
        let tapeWidth = max(140, CGFloat(row.loci.count) * 36)
        NSLayoutConstraint.activate([
            tape.widthAnchor.constraint(equalToConstant: tapeWidth),
            tape.heightAnchor.constraint(equalToConstant: 22),
        ])

        let commentLabel = NSTextField(labelWithString: row.commentSummary)
        commentLabel.font = NSFont.systemFont(ofSize: 10)
        commentLabel.textColor = .secondaryLabelColor
        commentLabel.lineBreakMode = .byTruncatingTail

        container.addArrangedSubview(disclosure)
        container.addArrangedSubview(blockGlyph)
        container.addArrangedSubview(animalLabel)
        container.addArrangedSubview(tape)
        container.addArrangedSubview(commentLabel)

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
        case .atypical:            return NSColor.systemRed
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
