// AssemblyContigDetailPane.swift - Detail presentation for selected assembly contigs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow
import LungfishKit

@MainActor
final class AssemblyContigDetailPane: NSView {
    private let overviewSectionLabel = NSTextField(labelWithString: "Contig Preview")
    private let titleLabel = AssemblyQuickCopyTextField(labelWithString: "")
    private let lengthLabel = AssemblyQuickCopyTextField(labelWithString: "")
    private let gcLabel = AssemblyQuickCopyTextField(labelWithString: "")
    private let rankLabel = AssemblyQuickCopyTextField(labelWithString: "")
    private let shareLabel = AssemblyQuickCopyTextField(labelWithString: "")
    private let sequenceSectionLabel = NSTextField(labelWithString: "Sequence")
    private let sequenceView = NSTextView()
    private let sequenceScrollView = NSScrollView()
    private let metricsStack = NSStackView()
    private let rootStack = NSStackView()
    private var sequenceMinimumHeightConstraint: NSLayoutConstraint?
    private var contentTypographyObservation: AssemblyContentTypographyObservation?
    private var preferredFontProvider: any ContentPreferredFontProviding =
        AppKitContentPreferredFontProvider()
    private var metricFields: [AssemblyQuickCopyTextField] {
        [lengthLabel, gcLabel, rankLabel, shareLabel]
    }
    private var currentMetricGroups: [[Int]] = []
    private var lastMetricLayoutSignature: String?
#if DEBUG
    private var typographyApplicationCount = 0
#endif

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("assembly-result-detail")
        setAccessibilityLabel("Assembly contig detail")

        sequenceView.isEditable = false
        sequenceView.isSelectable = true
        sequenceView.setAccessibilityIdentifier("assembly-result-detail-sequence-text")
        sequenceView.setAccessibilityLabel("Contig sequence")

        [overviewSectionLabel, sequenceSectionLabel].forEach {
            $0.textColor = .secondaryLabelColor
        }

        sequenceScrollView.translatesAutoresizingMaskIntoConstraints = false
        sequenceScrollView.hasVerticalScroller = true
        sequenceScrollView.autohidesScrollers = true
        sequenceScrollView.documentView = sequenceView
        sequenceScrollView.setAccessibilityIdentifier("assembly-result-detail-sequence-area")

        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.maximumNumberOfLines = 0
        titleLabel.setAccessibilityIdentifier("assembly-result-detail-title")

        lengthLabel.setAccessibilityIdentifier("assembly-result-detail-length")
        gcLabel.setAccessibilityIdentifier("assembly-result-detail-gc")
        rankLabel.setAccessibilityIdentifier("assembly-result-detail-rank")
        shareLabel.setAccessibilityIdentifier("assembly-result-detail-share")

        for field in [lengthLabel, gcLabel, rankLabel, shareLabel] {
            field.lineBreakMode = .byWordWrapping
            field.maximumNumberOfLines = 2
        }
        metricsStack.orientation = .vertical
        metricsStack.alignment = .leading
        metricsStack.spacing = 4

        rootStack.setViews(
            [
                overviewSectionLabel,
                titleLabel,
                metricsStack,
                sequenceSectionLabel,
                sequenceScrollView,
            ],
            in: .top
        )
        rootStack.orientation = .vertical
        rootStack.spacing = 8
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)

        let sequenceMinimumHeightConstraint = sequenceScrollView.heightAnchor.constraint(
            greaterThanOrEqualToConstant: 180
        )
        sequenceMinimumHeightConstraint.priority = .defaultHigh
        self.sequenceMinimumHeightConstraint = sequenceMinimumHeightConstraint
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            sequenceMinimumHeightConstraint,
        ])

        applyContentTypography()
        contentTypographyObservation = AssemblyContentTypographyObservation { [weak self] in
            self?.applyContentTypography()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    isolated deinit {
        contentTypographyObservation?.cancel()
    }

    override func layout() {
        updateMetricLayout()
        super.layout()
    }

    private func applyContentTypography() {
        let typography = ContentTypography.current(
            preferredFontProvider: preferredFontProvider
        )
        let selectedRange = sequenceView.selectedRange()
        let scrollOrigin = sequenceScrollView.contentView.bounds.origin

        overviewSectionLabel.font = typography.font(for: .tableHeader)
        sequenceSectionLabel.font = typography.font(for: .tableHeader)
        titleLabel.font = typography.font(for: .emphasizedBody)
        for field in [lengthLabel, gcLabel, rankLabel, shareLabel] {
            field.font = typography.font(for: .body)
        }
        let sequenceFont = typography.font(for: .monospaced)
        sequenceView.font = sequenceFont
        sequenceMinimumHeightConstraint?.constant = max(
            96,
            min(180, ceil(sequenceFont.boundingRectForFont.height * 4 + 24))
        )
        currentMetricGroups.removeAll()
        lastMetricLayoutSignature = nil
        updateMetricLayout()

        sequenceView.setSelectedRange(selectedRange)
        sequenceScrollView.layoutSubtreeIfNeeded()
        sequenceScrollView.contentView.scroll(to: scrollOrigin)
        sequenceScrollView.reflectScrolledClipView(sequenceScrollView.contentView)
        needsLayout = true
#if DEBUG
        typographyApplicationCount += 1
#endif
    }

    private func updateMetricLayout() {
        let availableWidth = max(1, bounds.width - 24)
        let signature = [
            String(Int(availableWidth.rounded(.down))),
            metricFields.map { "\($0.font?.pointSize ?? 0):\($0.stringValue)" }.joined(separator: "|"),
        ].joined(separator: "#")
        guard signature != lastMetricLayoutSignature else { return }
        lastMetricLayoutSignature = signature
        var groups: [[Int]] = []
        var current: [Int] = []
        var currentMinimum: CGFloat = 0
        for index in metricFields.indices {
            let minimum = minimumTwoLineWidth(for: metricFields[index])
            let count = current.count + 1
            let candidateMinimum = max(currentMinimum, minimum)
            let required = candidateMinimum * CGFloat(count) + CGFloat(count - 1) * 12
            if !current.isEmpty, required > availableWidth {
                groups.append(current)
                current = [index]
                currentMinimum = minimum
            } else {
                current.append(index)
                currentMinimum = candidateMinimum
            }
        }
        if !current.isEmpty { groups.append(current) }
        guard groups != currentMetricGroups else { return }
        currentMetricGroups = groups
        rebuildMetricRows(groups: groups)
    }

    private func minimumTwoLineWidth(for field: NSTextField) -> CGFloat {
        guard let font = field.font, !field.stringValue.isEmpty else { return 64 }
        let singleLine = ceil((field.stringValue as NSString).size(withAttributes: [.font: font]).width + 2)
        var low: CGFloat = 32
        var high = max(low, singleLine)
        let maximumHeight = ceil(font.boundingRectForFont.height * 2) + 1
        for _ in 0..<10 {
            let middle = (low + high) / 2
            let height = ceil((field.stringValue as NSString).boundingRect(
                with: NSSize(width: middle, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            ).height)
            if height <= maximumHeight {
                high = middle
            } else {
                low = middle
            }
        }
        return max(64, ceil(high))
    }

    private func rebuildMetricRows(groups: [[Int]]) {
        for row in metricsStack.arrangedSubviews {
            metricsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        for group in groups {
            let row = NSStackView(views: group.map { metricFields[$0] })
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.distribution = .fillEqually
            row.spacing = 12
            metricsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: metricsStack.widthAnchor).isActive = true
        }
    }

    private func setMetric(
        _ field: AssemblyQuickCopyTextField,
        text: String,
        accessibilityLabel: String
    ) {
        field.stringValue = text
        field.toolTip = text.isEmpty ? nil : text
        field.setAccessibilityLabel(accessibilityLabel)
        field.explicitAccessibilityValue = text.isEmpty ? "Not available" : text
    }

    private func contentDidChange() {
        currentMetricGroups.removeAll()
        lastMetricLayoutSignature = nil
        needsLayout = true
    }

    func setContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        preferredFontProvider = provider
        applyContentTypography()
    }

    func configureQuickCopy(pasteboard: PasteboardWriting) {
        [titleLabel, lengthLabel, gcLabel, rankLabel, shareLabel].forEach { field in
            field.pasteboard = pasteboard
            field.copiedValue = { [weak field] in field?.stringValue ?? "" }
        }
    }

    func showEmptyState(contigCount: Int) {
        titleLabel.stringValue = "Select a contig"
        setMetric(lengthLabel, text: "", accessibilityLabel: "Contig length")
        setMetric(gcLabel, text: "", accessibilityLabel: "Contig GC percent")
        setMetric(rankLabel, text: "", accessibilityLabel: "Contig rank")
        setMetric(shareLabel, text: "", accessibilityLabel: "Share of assembly")
        sequenceView.string = ""
        overviewSectionLabel.stringValue = contigCount == 1 ? "1 contig available" : "\(contigCount) contigs available"
        contentDidChange()
    }

    func showSingleSelection(record: AssemblyContigRecord, fastaPreview: String) {
        overviewSectionLabel.stringValue = "Contig Preview"
        titleLabel.stringValue = record.header
        setMetric(lengthLabel, text: "\(record.lengthBP) bp", accessibilityLabel: "Contig length")
        setMetric(gcLabel, text: String(format: "%.1f%%", record.gcPercent), accessibilityLabel: "Contig GC percent")
        setMetric(rankLabel, text: "#\(record.rank)", accessibilityLabel: "Contig rank")
        setMetric(shareLabel, text: String(format: "%.2f%% of assembly", record.shareOfAssemblyPercent), accessibilityLabel: "Share of assembly")
        sequenceView.string = fastaPreview
        contentDidChange()
    }

    func showMultiSelection(summary: AssemblyContigSelectionSummary, fastaPreview: String) {
        overviewSectionLabel.stringValue = "Selection Preview"
        titleLabel.stringValue = "\(summary.selectedContigCount) contigs selected"
        setMetric(lengthLabel, text: "\(summary.totalSelectedBP) bp total", accessibilityLabel: "Selected total length")
        setMetric(gcLabel, text: String(format: "%.1f%% weighted GC", summary.lengthWeightedGCPercent), accessibilityLabel: "Selected weighted GC percent")
        setMetric(rankLabel, text: "Longest: \(summary.longestContigBP) bp", accessibilityLabel: "Selected longest contig")
        setMetric(shareLabel, text: "Shortest: \(summary.shortestContigBP) bp", accessibilityLabel: "Selected shortest contig")
        sequenceView.string = fastaPreview
        contentDidChange()
    }

    func showUnavailableSelectionSummary(selectedContigCount: Int, fastaPreview: String) {
        overviewSectionLabel.stringValue = "Selection Preview"
        titleLabel.stringValue = "\(selectedContigCount) contigs selected"
        setMetric(lengthLabel, text: "", accessibilityLabel: "Selected total length")
        setMetric(gcLabel, text: "", accessibilityLabel: "Selected weighted GC percent")
        setMetric(rankLabel, text: "", accessibilityLabel: "Selected longest contig")
        setMetric(shareLabel, text: "", accessibilityLabel: "Selected shortest contig")
        sequenceView.string = fastaPreview
        contentDidChange()
    }

#if DEBUG
    func copyValue(identifier: String) {
        switch identifier {
        case "assembly-result-detail-length":
            lengthLabel.copyCurrentValue()
        case "assembly-result-detail-gc":
            gcLabel.copyCurrentValue()
        case "assembly-result-detail-rank":
            rankLabel.copyCurrentValue()
        case "assembly-result-detail-share":
            shareLabel.copyCurrentValue()
        default:
            titleLabel.copyCurrentValue()
        }
    }

    var currentHeaderText: String { titleLabel.stringValue }
    var currentSequenceText: String { sequenceView.string }
    var currentSummaryTitle: String { titleLabel.stringValue }
    var currentContextText: String { "" }
    var currentArtifactsText: String { "" }
    var testSequenceFontPointSize: CGFloat { sequenceView.font?.pointSize ?? 0 }
    var testSequenceFontIsFixedPitch: Bool { sequenceView.font?.isFixedPitch ?? false }
    var testSequenceMinimumHeight: CGFloat { sequenceMinimumHeightConstraint?.constant ?? 0 }
    var testSequenceSelectedRange: NSRange { sequenceView.selectedRange() }
    var testSequenceScrollOrigin: NSPoint { sequenceScrollView.contentView.bounds.origin }
    var testMetricsRowCount: Int { metricsStack.arrangedSubviews.count }
    var testTypographyApplicationCount: Int { typographyApplicationCount }
    var testTitleMaximumNumberOfLines: Int { titleLabel.maximumNumberOfLines }
    var testTitleLineBreakMode: NSLineBreakMode { titleLabel.lineBreakMode }
    var testMetricFramesAreContained: Bool {
        metricFields.allSatisfy { bounds.contains(convert($0.bounds, from: $0)) }
    }
    var testSequenceMinimumPriority: NSLayoutConstraint.Priority {
        sequenceMinimumHeightConstraint?.priority ?? .required
    }
    var testHasAmbiguousLayout: Bool {
        hasAmbiguousLayout
            || rootStack.hasAmbiguousLayout
            || metricsStack.hasAmbiguousLayout
            || metricsStack.arrangedSubviews.contains(where: \.hasAmbiguousLayout)
    }
    var testSequenceView: NSTextView { sequenceView }

    struct MetricAccessibility: Equatable {
        let label: String
        let value: String
    }

    func testMetricAccessibility(identifier: String) -> MetricAccessibility {
        let field: AssemblyQuickCopyTextField
        switch identifier {
        case "assembly-result-detail-length": field = lengthLabel
        case "assembly-result-detail-gc": field = gcLabel
        case "assembly-result-detail-rank": field = rankLabel
        default: field = shareLabel
        }
        return MetricAccessibility(
            label: field.accessibilityLabel() ?? "",
            value: field.accessibilityValue() ?? ""
        )
    }

    func testSetContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        setContentPreferredFontProvider(provider)
    }

    func testSetSequenceSelection(_ range: NSRange) {
        sequenceView.setSelectedRange(range)
    }

    func testSetSequenceScrollOrigin(_ origin: NSPoint) {
        sequenceScrollView.contentView.scroll(to: origin)
        sequenceScrollView.reflectScrolledClipView(sequenceScrollView.contentView)
    }
#endif
}
