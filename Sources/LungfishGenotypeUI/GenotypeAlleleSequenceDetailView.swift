import AppKit
import LungfishKit

@MainActor
final class GenotypeAlleleSequenceDetailView: NSView {
    enum Format: Int, CaseIterable {
        case genBank
        case fasta
        case embl
    }

    private let formatControl = NSSegmentedControl(
        labels: ["GenBank", "FASTA", "EMBL"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let scrollView = NSScrollView(frame: .zero)
    private let textView = NSTextView(frame: .zero)
    private var records: [GenotypeAlleleSequenceRecord] = []
    private var contentTypographyObservation: ContentTypographyViewObservation?
    private let sequenceFontBaseline = NSFont.monospacedSystemFont(
        ofSize: NSFont.smallSystemFontSize,
        weight: .regular
    )
    private(set) var testingRenderCount = 0

    private(set) var currentFormat: Format = .genBank

    var isEmpty: Bool {
        records.isEmpty
    }

    var renderedText: String {
        textView.string
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 320, height: 240)
    }

    func resetForNewResult() {
        currentFormat = .genBank
        formatControl.selectedSegment = Format.genBank.rawValue
        clear()
    }

    func clear() {
        records = []
        textView.string = ""
        formatControl.isHidden = true
        scrollView.isHidden = true
    }

    func show(records: [GenotypeAlleleSequenceRecord]) {
        guard !records.isEmpty else {
            clear()
            return
        }
        self.records = records
        formatControl.isHidden = false
        scrollView.isHidden = false
        render()
    }

    func testingSelectFormat(_ format: Format) {
        formatControl.selectedSegment = format.rawValue
        formatChanged(formatControl)
    }

    private func configureView() {
        setAccessibilityIdentifier("mhc-sequence-detail")

        formatControl.controlSize = .small
        formatControl.selectedSegment = Format.genBank.rawValue
        formatControl.target = self
        formatControl.action = #selector(formatChanged(_:))
        formatControl.setAccessibilityIdentifier("mhc-sequence-format")
        formatControl.setAccessibilityLabel("Sequence format")

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = false
        textView.font = resolvedSequenceFont()
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.setAccessibilityIdentifier("mhc-sequence-text")
        textView.setAccessibilityLabel("Allele sequence records")

        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        formatControl.translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(formatControl)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            formatControl.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            formatControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.topAnchor.constraint(equalTo: formatControl.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])

        contentTypographyObservation = ContentTypographyViewObservation(
            applicator: ContentTypographyViewApplicator(excludedSubtree: { _ in true }),
            rootProvider: { [weak self] in self },
            afterApply: { [weak self] in self?.applyContentTypography() }
        )
        clear()
    }

    @objc private func formatChanged(_ sender: NSSegmentedControl) {
        guard let format = Format(rawValue: sender.selectedSegment) else { return }
        currentFormat = format
        render()
    }

    private func render() {
        testingRenderCount += 1
        let values = records.map { record in
            switch currentFormat {
            case .genBank:
                record.genBankText
            case .fasta:
                record.fastaText
            case .embl:
                record.emblText
            }
        }
        textView.string = values.joined(separator: "\n")
    }

    private func applyContentTypography() {
        let resolvedFont = resolvedSequenceFont()
        guard !hasSameFontSignature(textView.font, resolvedFont) else { return }
        let selectedRange = textView.selectedRange()
        let scrollOrigin = scrollView.contentView.bounds.origin
        textView.font = resolvedFont
        textView.setSelectedRange(selectedRange)
        scrollView.contentView.setBoundsOrigin(scrollOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        needsLayout = true
    }

    private func resolvedSequenceFont() -> NSFont {
        let bodyFont = ContentTypography.current().font(for: .body)
        let scale = bodyFont.pointSize / max(NSFont.systemFontSize, 1)
        let pointSize = max(
            ContentTypography.minimumPointSize,
            sequenceFontBaseline.pointSize * scale
        )
        return NSFont(
            descriptor: sequenceFontBaseline.fontDescriptor,
            size: pointSize
        ) ?? sequenceFontBaseline
    }

    private func hasSameFontSignature(_ lhs: NSFont?, _ rhs: NSFont) -> Bool {
        guard let lhs else { return false }
        return lhs.fontName == rhs.fontName
            && abs(lhs.pointSize - rhs.pointSize) < 0.001
            && lhs.fontDescriptor.symbolicTraits == rhs.fontDescriptor.symbolicTraits
    }

#if DEBUG
    var testingTextFontPointSize: CGFloat {
        textView.font?.pointSize ?? 0
    }

    var testingSelectedRange: NSRange {
        get { textView.selectedRange() }
        set { textView.setSelectedRange(newValue) }
    }
#endif
}
