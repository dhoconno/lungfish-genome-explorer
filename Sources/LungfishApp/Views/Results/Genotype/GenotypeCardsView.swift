import AppKit
import LungfishCore
import LungfishIO

@MainActor
final class GenotypeCardsView: NSView {
    enum Density: String, Equatable {
        case compact
        case comfortable
        case roomy

        var cardWidth: CGFloat {
            switch self {
            case .compact:     return 200
            case .comfortable: return 260
            case .roomy:       return 320
            }
        }

        var cardHeight: CGFloat {
            switch self {
            case .compact:     return 88
            case .comfortable: return 124
            case .roomy:       return 156
            }
        }

        var showComment: Bool {
            self != .compact
        }

        var tapeHeight: CGFloat {
            switch self {
            case .compact:     return 22
            case .comfortable: return 26
            case .roomy:       return 30
            }
        }
    }

    struct Card: Equatable {
        let animalId: String
        let gsId: String?
        let loci: [String]
        let tapeSlots: [GenotypeHaplotypeTapeView.Slot]
        let blockKind: GenotypeBlockKind
        let commentSummary: String

        static func == (lhs: Card, rhs: Card) -> Bool {
            lhs.animalId == rhs.animalId && lhs.gsId == rhs.gsId &&
            lhs.loci == rhs.loci && lhs.blockKind == rhs.blockKind &&
            lhs.commentSummary == rhs.commentSummary
        }
    }

    var onCardSelected: ((String) -> Void)?
    /// Threshold above which automatic-density mode collapses to `.compact`.
    var autoDensityThreshold: Int = 30
    /// User-pinned density. When `nil`, density is chosen automatically based
    /// on `cards.count` vs `autoDensityThreshold`.
    var pinnedDensity: Density?

    private(set) var numberOfCards: Int = 0
    private(set) var effectiveDensity: Density = .comfortable

    private var cards: [Card] = []
    private let scrollView = NSScrollView()
    private let documentView = NSView()
    private let containerStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildSubviews()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildSubviews()
    }

    private func buildSubviews() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        documentView.translatesAutoresizingMaskIntoConstraints = false

        containerStack.translatesAutoresizingMaskIntoConstraints = false
        containerStack.orientation = .vertical
        containerStack.alignment = .leading
        containerStack.spacing = 10
        containerStack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        scrollView.documentView = documentView
        documentView.addSubview(containerStack)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            containerStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            containerStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            containerStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            containerStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
    }

    private var lastLayoutBoundsSize: NSSize = .zero
    private var lastLayoutDensity: Density?

    func configure(cards: [Card]) {
        self.cards = cards
        self.numberOfCards = cards.count
        self.effectiveDensity = resolveDensity()
        lastLayoutBoundsSize = .zero
        lastLayoutDensity = nil
        rebuild()
    }

    private func resolveDensity() -> Density {
        if let pinnedDensity { return pinnedDensity }
        return cards.count > autoDensityThreshold ? .compact : .comfortable
    }

    override func layout() {
        super.layout()
        // AppKit invokes `layout()` continuously during window resize and
        // split-divider drag. Rebuilding the entire NSView hierarchy from
        // scratch on each tick is O(N) NSView allocation. Skip the rebuild
        // when neither the bounds nor the effective density changed.
        if bounds.size == lastLayoutBoundsSize && lastLayoutDensity == effectiveDensity {
            return
        }
        lastLayoutBoundsSize = bounds.size
        lastLayoutDensity = effectiveDensity
        rebuild()
    }

    private func rebuild() {
        containerStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !cards.isEmpty else { return }
        let availableWidth = max(0, bounds.width - containerStack.edgeInsets.left - containerStack.edgeInsets.right)
        let columnSpacing: CGFloat = 10
        let cardWidth = effectiveDensity.cardWidth
        let columns = max(1, Int(((availableWidth + columnSpacing) / (cardWidth + columnSpacing)).rounded(.down)))
        var index = 0
        while index < cards.count {
            let rowEnd = min(index + columns, cards.count)
            let rowStack = NSStackView()
            rowStack.translatesAutoresizingMaskIntoConstraints = false
            rowStack.orientation = .horizontal
            rowStack.alignment = .top
            rowStack.spacing = columnSpacing
            for card in cards[index..<rowEnd] {
                rowStack.addArrangedSubview(makeCard(card))
            }
            containerStack.addArrangedSubview(rowStack)
            index = rowEnd
        }
    }

    private func makeCard(_ card: Card) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.layer?.borderColor = NSColor.separatorColor.cgColor
        container.layer?.borderWidth = 1
        container.layer?.cornerRadius = 6

        let header = NSStackView()
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 6

        let blockGlyph = NSTextField(labelWithString: blockGlyphSymbol(card.blockKind))
        blockGlyph.font = NSFont.systemFont(ofSize: 11)
        blockGlyph.textColor = blockGlyphColor(card.blockKind)
        blockGlyph.toolTip = blockGlyphTooltip(card.blockKind)

        let animal = NSTextField(labelWithString: card.animalId)
        animal.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold)
        animal.textColor = .labelColor

        header.addArrangedSubview(blockGlyph)
        header.addArrangedSubview(animal)
        if let gsId = card.gsId {
            let trailing = NSTextField(labelWithString: gsId)
            trailing.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            trailing.textColor = .secondaryLabelColor
            header.addArrangedSubview(NSView())
            header.addArrangedSubview(trailing)
        }

        let tape = GenotypeHaplotypeTapeView()
        tape.translatesAutoresizingMaskIntoConstraints = false
        tape.configure(loci: card.loci, slots: card.tapeSlots)
        tape.sampleAccessibilityLabel = card.animalId
        NSLayoutConstraint.activate([
            tape.heightAnchor.constraint(equalToConstant: effectiveDensity.tapeHeight)
        ])

        let bodyStack = NSStackView()
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyStack.orientation = .vertical
        bodyStack.alignment = .leading
        bodyStack.spacing = 6
        bodyStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        bodyStack.addArrangedSubview(header)
        bodyStack.addArrangedSubview(tape)
        if effectiveDensity.showComment, !card.commentSummary.isEmpty {
            let comment = NSTextField(labelWithString: card.commentSummary)
            comment.font = NSFont.systemFont(ofSize: 10)
            comment.textColor = .secondaryLabelColor
            comment.lineBreakMode = .byTruncatingTail
            comment.maximumNumberOfLines = 2
            comment.preferredMaxLayoutWidth = effectiveDensity.cardWidth - 20
            bodyStack.addArrangedSubview(comment)
        }

        container.addSubview(bodyStack)
        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(equalToConstant: effectiveDensity.cardWidth),
            container.heightAnchor.constraint(greaterThanOrEqualToConstant: effectiveDensity.cardHeight),
            bodyStack.topAnchor.constraint(equalTo: container.topAnchor),
            bodyStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bodyStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bodyStack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        container.addGestureRecognizer(click)
        container.identifier = NSUserInterfaceItemIdentifier(card.animalId)
        return container
    }

    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        guard let view = recognizer.view,
              let id = view.identifier?.rawValue else { return }
        onCardSelected?(id)
    }

    private func blockGlyphSymbol(_ kind: GenotypeBlockKind) -> String {
        switch kind {
        case .blockCoherent:        return "▮"
        case .regionalRecombinant:  return "▰▱"
        case .atypical:             return "▱▰▱"
        case .unknown:              return "·"
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
}
