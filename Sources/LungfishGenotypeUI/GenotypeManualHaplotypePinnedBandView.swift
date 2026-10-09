import AppKit
import LungfishCore
import LungfishIO

@MainActor
private final class GenotypeManualHaplotypeDisclosureButton: NSButton {
    override var acceptsFirstResponder: Bool { true }

    override func isAccessibilityExpanded() -> Bool {
        state == .on
    }

    override func accessibilityValue() -> Any? {
        NSNumber(value: state == .on)
    }

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
}

@MainActor
final class GenotypeManualHaplotypePinnedBandView: NSView {
    static let disclosureTitle = "Manual haplotypes (7 loci)"

    static func requiredDisclosureHeight(
        font _: NSFont,
        availableWidth _: CGFloat,
        minimumHeight: CGFloat
    ) -> CGFloat {
        ceil(minimumHeight)
    }

    var font = NSFont.systemFont(ofSize: 11) {
        didSet {
            disclosureButton.font = font
            needsLayout = true
            needsDisplay = true
        }
    }
    var rowHeight: CGFloat = 22 {
        didSet {
            needsLayout = true
            needsDisplay = true
        }
    }
    var disclosureHeight: CGFloat = 22 {
        didSet {
            needsLayout = true
            needsDisplay = true
        }
    }
    var availableDisclosureWidth: CGFloat = 360 {
        didSet {
            needsLayout = true
        }
    }
    var isExpanded = true {
        didSet {
            disclosureButton.state = isExpanded ? .on : .off
            needsDisplay = true
        }
    }
    var onDisclosureChanged: ((Bool) -> Void)?
    private(set) var bandMode: GenotypeHaplotypeBandMode = .manualAssignments
    private var locusLabels = GenotypeManualHaplotypeAssignmentBandSnapshot.loci
        .map(\.workbookLabel)
    private var currentDisclosureTitle = disclosureTitle

    private let disclosureButton = GenotypeManualHaplotypeDisclosureButton(
        title: "Haplotypes",
        target: nil,
        action: nil
    )

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        disclosureButton.target = self
        disclosureButton.action = #selector(toggleDisclosure(_:))
        disclosureButton.setButtonType(.pushOnPushOff)
        disclosureButton.isBordered = false
        disclosureButton.image = Self.makeDisclosureIcon(
            expanded: false
        )
        disclosureButton.alternateImage = Self.makeDisclosureIcon(
            expanded: true
        )
        disclosureButton.imagePosition = .imageLeading
        disclosureButton.imageScaling = .scaleProportionallyDown
        disclosureButton.toolTip = Self.disclosureTitle
        disclosureButton.font = font
        disclosureButton.cell?.lineBreakMode = .byTruncatingTail
        disclosureButton.cell?.usesSingleLineMode = true
        disclosureButton.state = .on
        disclosureButton.setAccessibilityElement(true)
        disclosureButton.setAccessibilityRole(.button)
        disclosureButton.setAccessibilityLabel(
            "Manual haplotypes (7 loci)"
        )
        disclosureButton.setAccessibilityHelp(
            "Shows seven locus-level manual haplotype assignment rows below the sample names."
        )
        disclosureButton.setAccessibilityIdentifier(
            "manual-haplotype-band-disclosure"
        )
        addSubview(disclosureButton)
    }

    func setHaplotypeBand(
        mode: GenotypeHaplotypeBandMode,
        snapshot: GenotypeHaplotypeCallBandSnapshot?
    ) {
        bandMode = mode
        switch mode {
        case .none:
            locusLabels = []
            currentDisclosureTitle = "Haplotypes"
            disclosureButton.setAccessibilityHelp(nil)
        case .manualAssignments:
            locusLabels = GenotypeManualHaplotypeAssignmentBandSnapshot.loci
                .map(\.workbookLabel)
            currentDisclosureTitle = Self.disclosureTitle
            disclosureButton.setAccessibilityHelp(
                "Shows seven locus-level manual haplotype assignment rows below the sample names."
            )
        case .effectiveMiSeqCalls:
            let snapshot = snapshot ?? .empty
            locusLabels = snapshot.orderedLoci
            currentDisclosureTitle = snapshot.disclosureTitle
            disclosureButton.setAccessibilityHelp(
                "Shows effective H1 and H2 haplotype calls for each included locus below the sample names."
            )
        }
        disclosureButton.title = mode == .effectiveMiSeqCalls
            ? currentDisclosureTitle
            : "Haplotypes"
        disclosureButton.toolTip = currentDisclosureTitle
        disclosureButton.setAccessibilityLabel(currentDisclosureTitle)
        disclosureButton.setAccessibilityIdentifier(
            mode == .effectiveMiSeqCalls
                ? "haplotype-call-band-disclosure"
                : "manual-haplotype-band-disclosure"
        )
        needsLayout = true
        needsDisplay = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        let intrinsicWidth = disclosureButton.cell?.cellSize.width
            ?? disclosureButton.intrinsicContentSize.width
        disclosureButton.frame = NSRect(
            x: 0,
            y: 0,
            width: max(
                0,
                min(
                    bounds.width,
                    availableDisclosureWidth,
                    ceil(intrinsicWidth + 6)
                )
            ),
            height: min(disclosureHeight, bounds.height)
        )
    }

    @objc private func toggleDisclosure(_ sender: NSButton) {
        let expanded = sender.state == .on
        isExpanded = expanded
        onDisclosureChanged?(expanded)
    }

    var disclosureLabel: String { currentDisclosureTitle }

#if DEBUG
    var testingDisclosureFrame: NSRect { disclosureButton.frame }
    var testingDisclosureIsBordered: Bool { disclosureButton.isBordered }
    var testingStripBackgroundColor: NSColor { .windowBackgroundColor }
    var testingStripSeparatorColor: NSColor { .separatorColor }
#endif

    private static func makeDisclosureIcon(
        expanded: Bool
    ) -> NSImage {
        let size = NSSize(width: 26, height: 12)
        let image = NSImage(
            size: size,
            flipped: false
        ) { _ in
            let chevron = NSBezierPath()
            if expanded {
                chevron.move(to: NSPoint(x: 0.5, y: 7.5))
                chevron.line(to: NSPoint(x: 3.25, y: 4.5))
                chevron.line(to: NSPoint(x: 6, y: 7.5))
            } else {
                chevron.move(to: NSPoint(x: 1.5, y: 10))
                chevron.line(to: NSPoint(x: 4.5, y: 6))
                chevron.line(to: NSPoint(x: 1.5, y: 2))
            }
            chevron.lineWidth = 1.5
            chevron.lineCapStyle = .round
            chevron.lineJoinStyle = .round
            NSColor.black.setStroke()
            chevron.stroke()

            NSColor.black.setFill()
            let segmentWidth: CGFloat = 5
            let segmentHeight: CGFloat = 4.5
            let horizontalGap: CGFloat = 1.5
            let verticalGap: CGFloat = 1.5
            let segmentOriginX: CGFloat = 8
            let lowerY = (size.height
                - segmentHeight * 2
                - verticalGap) / 2
            for row in 0..<2 {
                for column in 0..<3 {
                    let rect = NSRect(
                        x: segmentOriginX
                            + CGFloat(column)
                            * (segmentWidth + horizontalGap),
                        y: lowerY
                            + CGFloat(row)
                            * (segmentHeight + verticalGap),
                        width: segmentWidth,
                        height: segmentHeight
                    )
                    NSBezierPath(
                        roundedRect: rect,
                        xRadius: segmentHeight / 2,
                        yRadius: segmentHeight / 2
                    ).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawStripChrome(in: dirtyRect)
        guard isExpanded else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        for (index, locus) in locusLabels.enumerated() {
            let rowRect = NSRect(
                x: 6,
                y: disclosureHeight + rowHeight * CGFloat(index),
                width: max(0, bounds.width - 12),
                height: rowHeight
            )
            guard rowRect.intersects(dirtyRect) else { continue }
            locus.draw(
                in: rowRect.insetBy(dx: 0, dy: max(1, (rowHeight - font.boundingRectForFont.height) / 2)),
                withAttributes: attributes
            )
        }
    }

    private func drawStripChrome(in dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.intersection(bounds).fill()
        let separatorRect = NSRect(
            x: bounds.minX,
            y: max(bounds.minY, bounds.maxY - 1),
            width: bounds.width,
            height: 1
        )
        guard separatorRect.intersects(dirtyRect) else { return }
        NSColor.separatorColor.setFill()
        separatorRect.fill()
    }
}
