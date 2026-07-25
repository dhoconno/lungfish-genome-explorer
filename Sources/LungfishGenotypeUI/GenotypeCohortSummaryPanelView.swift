import AppKit
import LungfishCore
import LungfishKit

@MainActor
final class GenotypeCohortSummaryPanelView: NSView {
    struct Summary {
        let qcCounts: [(String, Int)]
        let errorTypeCounts: [(String, Int)]
        let annotationCounts: [(String, Int)]
        /// Sample IDs with read totals more than one standard deviation below
        /// the cohort mean. Hovering the count reveals the list.
        let outlierSamples: [String]
        /// Sample IDs with total reads below the absolute threshold (5K by
        /// default). These are the samples we cannot reliably haplotype.
        let belowThresholdSamples: [String]
        let belowThresholdValue: Int
        let isReadOnlyBundle: Bool

        init(
            qcCounts: [(String, Int)],
            errorTypeCounts: [(String, Int)],
            annotationCounts: [(String, Int)],
            outlierSamples: [String],
            belowThresholdSamples: [String],
            belowThresholdValue: Int,
            isReadOnlyBundle: Bool = false
        ) {
            self.qcCounts = qcCounts
            self.errorTypeCounts = errorTypeCounts
            self.annotationCounts = annotationCounts
            self.outlierSamples = outlierSamples
            self.belowThresholdSamples = belowThresholdSamples
            self.belowThresholdValue = belowThresholdValue
            self.isReadOnlyBundle = isReadOnlyBundle
        }
    }

    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    private let documentView = FlippedDocumentView()
    private var contentTypographyObservation: ContentTypographyViewObservation?
    private var contentPreferredFontProvider: any ContentPreferredFontProviding =
        AppKitContentPreferredFontProvider()
    private struct TypographyField {
        let field: NSTextField
        let role: ContentTypography.Role
        let weight: NSFont.Weight?
        let usesMonospacedDigits: Bool
    }
    private var typographyFields: [TypographyField] = []
#if DEBUG
    private var configurationCount = 0
#endif

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
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

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
        installContentTypographyObservation()
    }

    func configure(summary: Summary) {
#if DEBUG
        configurationCount += 1
#endif
        typographyFields.removeAll(keepingCapacity: true)
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        if summary.isReadOnlyBundle {
            stack.addArrangedSubview(makeReadOnlyBanner())
        }
        // Flag the samples most likely to need re-runs: cohort outliers
        // (more than 1 SD below the mean) and absolute low-read samples
        // (below the configurable threshold). Both are folded together at
        // the top of the panel since this is what an analyst sees first.
        stack.addArrangedSubview(makeFlagSection(
            title: "Low-coverage samples",
            count: summary.outlierSamples.count,
            samples: summary.outlierSamples,
            footnote: "Samples > 1 SD below the cohort mean reads."
        ))
        stack.addArrangedSubview(makeFlagSection(
            title: "Below \(formatThreshold(summary.belowThresholdValue)) reads",
            count: summary.belowThresholdSamples.count,
            samples: summary.belowThresholdSamples,
            footnote: "Samples below the absolute read threshold — calls here may be unreliable."
        ))
        stack.addArrangedSubview(makeSection(title: "QC distribution",
                                             content: summary.qcCounts.map { ($0.0, "\($0.1)") }))
        stack.addArrangedSubview(makeSection(title: "Errors",
                                             content: summary.errorTypeCounts.map { ($0.0, "\($0.1)") }))
        stack.addArrangedSubview(makeSection(title: "Annotations",
                                             content: summary.annotationCounts.map { ($0.0, "\($0.1)") }))
        contentTypographyObservation?.refresh()
    }

    private func formatThreshold(_ value: Int) -> String {
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", Double(value) / 1_000) }
        return "\(value)"
    }

    private func makeFlagSection(title: String, count: Int, samples: [String], footnote: String) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 4
        let titleLabel = NSTextField(labelWithString: title.uppercased())
        register(titleLabel, role: .tableHeader)
        titleLabel.textColor = .secondaryLabelColor
        let valueRow = NSStackView()
        valueRow.orientation = .horizontal
        valueRow.spacing = 6
        let countLabel = NSTextField(labelWithString: "\(count) sample\(count == 1 ? "" : "s")")
        register(
            countLabel,
            role: .monospaced,
            weight: count > 0 ? .semibold : .regular,
            usesMonospacedDigits: true
        )
        countLabel.textColor = count > 0 ? NSColor.lungfishDanger : .labelColor
        let detail = samples.isEmpty
            ? footnote
            : "\(footnote) Hover to list: \(samples.prefix(8).joined(separator: ", "))" +
              (samples.count > 8 ? " (+\(samples.count - 8) more)" : "")
        countLabel.toolTip = detail
        valueRow.addArrangedSubview(countLabel)
        let footnoteLabel = NSTextField(labelWithString: footnote)
        register(footnoteLabel, role: .caption)
        footnoteLabel.textColor = .tertiaryLabelColor
        footnoteLabel.lineBreakMode = .byWordWrapping
        footnoteLabel.maximumNumberOfLines = 0
        container.addArrangedSubview(titleLabel)
        container.addArrangedSubview(valueRow)
        container.addArrangedSubview(footnoteLabel)
        return container
    }

    private func makeReadOnlyBanner() -> NSView {
        let container = NSBox()
        container.boxType = .custom
        container.borderWidth = 1
        container.borderColor = NSColor.lungfishDanger.withAlphaComponent(0.5)
        container.fillColor = NSColor.lungfishDanger.withAlphaComponent(0.1)
        container.cornerRadius = 6
        container.titlePosition = .noTitle
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(wrappingLabelWithString:
            "Read-only bundle. Edits and annotations are kept in memory only — they will not persist."
        )
        register(label, role: .emphasizedBody)
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
        register(titleLabel, role: .tableHeader)
        titleLabel.textColor = .secondaryLabelColor
        v.addArrangedSubview(titleLabel)
        for (key, value) in content {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 8
            let k = NSTextField(labelWithString: key)
            register(k, role: .body)
            k.textColor = .secondaryLabelColor
            let val = NSTextField(labelWithString: value)
            register(
                val,
                role: .monospaced,
                weight: .regular,
                usesMonospacedDigits: true
            )
            val.textColor = .labelColor
            row.addArrangedSubview(k)
            row.addArrangedSubview(val)
            v.addArrangedSubview(row)
        }
        return v
    }

    private func finishContentTypographyUpdate() {
        let typography = ContentTypography(
            preference: AppSettings.shared.contentTextSizePreference,
            preferredFontProvider: contentPreferredFontProvider
        )
        for entry in typographyFields {
            let resolved = typography.font(for: entry.role)
            if entry.usesMonospacedDigits {
                entry.field.font = .monospacedDigitSystemFont(
                    ofSize: resolved.pointSize,
                    weight: entry.weight ?? .regular
                )
            } else if let weight = entry.weight {
                entry.field.font = .systemFont(ofSize: resolved.pointSize, weight: weight)
            } else {
                entry.field.font = resolved
            }
        }
        for field in descendantTextFields(in: self) {
            field.maximumNumberOfLines = 0
            field.lineBreakMode = .byWordWrapping
            field.usesSingleLineMode = false
            if !field.stringValue.isEmpty {
                field.toolTip = field.stringValue
            }
        }
        documentView.needsLayout = true
        needsLayout = true
    }

    private func register(
        _ field: NSTextField,
        role: ContentTypography.Role,
        weight: NSFont.Weight? = nil,
        usesMonospacedDigits: Bool = false
    ) {
        typographyFields.append(.init(
            field: field,
            role: role,
            weight: weight,
            usesMonospacedDigits: usesMonospacedDigits
        ))
    }

    private func installContentTypographyObservation() {
        contentTypographyObservation?.cancel()
        contentTypographyObservation = ContentTypographyViewObservation(
            applicator: ContentTypographyViewApplicator(excludedSubtree: { _ in true }),
            rootProvider: { [weak self] in self },
            afterApply: { [weak self] in self?.finishContentTypographyUpdate() }
        )
    }

    private func descendantTextFields(in view: NSView) -> [NSTextField] {
        view.subviews.flatMap { subview in
            (subview as? NSTextField).map { [$0] } ?? []
                + descendantTextFields(in: subview)
        }
    }

    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }
}

#if DEBUG
extension GenotypeCohortSummaryPanelView {
    func testingSetContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        contentPreferredFontProvider = provider
        installContentTypographyObservation()
    }

    func testingFontPointSize(for role: ContentTypography.Role) -> CGFloat {
        typographyFields.first(where: { $0.role == role })?.field.font?.pointSize ?? 0
    }

    var testingLargestContentFontPointSize: CGFloat {
        descendantTextFields(in: self).compactMap { $0.font?.pointSize }.max() ?? 0
    }

    var testingAllTextFieldsAllowWrapping: Bool {
        descendantTextFields(in: self).allSatisfy {
            !$0.usesSingleLineMode && $0.maximumNumberOfLines != 1
        }
    }

    var testingConfigurationCount: Int {
        configurationCount
    }
}
#endif
