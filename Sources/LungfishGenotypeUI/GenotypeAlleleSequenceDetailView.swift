import AppKit

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
        textView.font = .monospacedSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = []
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
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

        clear()
    }

    @objc private func formatChanged(_ sender: NSSegmentedControl) {
        guard let format = Format(rawValue: sender.selectedSegment) else { return }
        currentFormat = format
        render()
    }

    private func render() {
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
        textView.sizeToFit()
    }
}
