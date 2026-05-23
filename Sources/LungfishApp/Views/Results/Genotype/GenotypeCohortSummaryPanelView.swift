import AppKit

@MainActor
final class GenotypeCohortSummaryPanelView: NSView {
    struct Summary {
        let sampleCount: Int
        let qcCounts: [(String, Int)]
        let errorTypeCounts: [(String, Int)]
        let blockCounts: [(String, Int)]
        let readBudget: (median: String, belowThreshold: String)
        let annotationCounts: [(String, Int)]
        let isReadOnlyBundle: Bool

        init(
            sampleCount: Int,
            qcCounts: [(String, Int)],
            errorTypeCounts: [(String, Int)],
            blockCounts: [(String, Int)],
            readBudget: (median: String, belowThreshold: String),
            annotationCounts: [(String, Int)],
            isReadOnlyBundle: Bool = false
        ) {
            self.sampleCount = sampleCount
            self.qcCounts = qcCounts
            self.errorTypeCounts = errorTypeCounts
            self.blockCounts = blockCounts
            self.readBudget = readBudget
            self.annotationCounts = annotationCounts
            self.isReadOnlyBundle = isReadOnlyBundle
        }
    }

    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    private let documentView = FlippedDocumentView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); build()
    }
    required init?(coder: NSCoder) { super.init(coder: coder); build() }

    private func build() {

        translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        documentView.translatesAutoresizingMaskIntoConstraints = false

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        scrollView.documentView = documentView
        documentView.addSubview(stack)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
        ])
    }

    func configure(summary: Summary) {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if summary.isReadOnlyBundle {
            stack.addArrangedSubview(makeReadOnlyBanner())
        }
        stack.addArrangedSubview(makeSection(title: "Cohort summary",
                                             content: [("Samples", "\(summary.sampleCount)")]))
        stack.addArrangedSubview(makeSection(title: "QC distribution",
                                             content: summary.qcCounts.map { ($0.0, "\($0.1)") }))
        stack.addArrangedSubview(makeSection(title: "Errors",
                                             content: summary.errorTypeCounts.map { ($0.0, "\($0.1)") }))
        stack.addArrangedSubview(makeSection(title: "Block coherence",
                                             content: summary.blockCounts.map { ($0.0, "\($0.1)") }))
        stack.addArrangedSubview(makeSection(title: "Read budget",
                                             content: [("Median", summary.readBudget.median),
                                                       ("Below threshold", summary.readBudget.belowThreshold)]))
        stack.addArrangedSubview(makeSection(title: "Annotations",
                                             content: summary.annotationCounts.map { ($0.0, "\($0.1)") }))
    }

    private func makeReadOnlyBanner() -> NSView {
        let container = NSBox()
        container.boxType = .custom
        container.borderWidth = 1
        container.borderColor = NSColor.systemOrange.withAlphaComponent(0.5)
        container.fillColor = NSColor.systemOrange.withAlphaComponent(0.1)
        container.cornerRadius = 6
        container.titlePosition = .noTitle
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString:
            "Read-only bundle. Edits and annotations are kept in memory only — they will not persist."
        )
        label.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -8),
        ])
        return container
    }

    private func makeSection(title: String, content: [(String, String)]) -> NSView {
        let v = NSStackView()
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 6
        let titleLabel = NSTextField(labelWithString: title.uppercased())
        titleLabel.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        v.addArrangedSubview(titleLabel)
        for (key, value) in content {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 8
            let k = NSTextField(labelWithString: key)
            k.font = NSFont.systemFont(ofSize: 11)
            k.textColor = .secondaryLabelColor
            let val = NSTextField(labelWithString: value)
            val.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            val.textColor = .labelColor
            row.addArrangedSubview(k)
            row.addArrangedSubview(val)
            v.addArrangedSubview(row)
        }
        return v
    }

    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }
}
