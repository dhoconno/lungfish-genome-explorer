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
            field.maximumNumberOfLines = 0
        }
        metricsStack.orientation = .vertical
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

    private func applyContentTypography() {
        let typography = ContentTypography.current()
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
            180,
            ceil(sequenceFont.boundingRectForFont.height * 8 + 24)
        )
        rebuildMetricRows(useTwoRows: typography.preference.scaleFactor >= 1.75)

        sequenceView.setSelectedRange(selectedRange)
        sequenceScrollView.layoutSubtreeIfNeeded()
        sequenceScrollView.contentView.scroll(to: scrollOrigin)
        sequenceScrollView.reflectScrolledClipView(sequenceScrollView.contentView)
        needsLayout = true
#if DEBUG
        typographyApplicationCount += 1
#endif
    }

    private func rebuildMetricRows(useTwoRows: Bool) {
        for row in metricsStack.arrangedSubviews {
            metricsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        let groups: [[AssemblyQuickCopyTextField]] = useTwoRows
            ? [[lengthLabel, gcLabel], [rankLabel, shareLabel]]
            : [[lengthLabel, gcLabel, rankLabel, shareLabel]]
        for fields in groups {
            let row = NSStackView(views: fields)
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.distribution = .fillEqually
            row.spacing = 12
            metricsStack.addArrangedSubview(row)
        }
    }

    func configureQuickCopy(pasteboard: PasteboardWriting) {
        [titleLabel, lengthLabel, gcLabel, rankLabel, shareLabel].forEach { field in
            field.pasteboard = pasteboard
            field.copiedValue = { [weak field] in field?.stringValue ?? "" }
        }
    }

    func showEmptyState(contigCount: Int) {
        titleLabel.stringValue = "Select a contig"
        lengthLabel.stringValue = ""
        gcLabel.stringValue = ""
        rankLabel.stringValue = ""
        shareLabel.stringValue = ""
        sequenceView.string = ""
        overviewSectionLabel.stringValue = contigCount == 1 ? "1 contig available" : "\(contigCount) contigs available"
    }

    func showSingleSelection(record: AssemblyContigRecord, fastaPreview: String) {
        overviewSectionLabel.stringValue = "Contig Preview"
        titleLabel.stringValue = record.header
        lengthLabel.stringValue = "\(record.lengthBP) bp"
        gcLabel.stringValue = String(format: "%.1f%%", record.gcPercent)
        rankLabel.stringValue = "#\(record.rank)"
        shareLabel.stringValue = String(format: "%.2f%% of assembly", record.shareOfAssemblyPercent)
        sequenceView.string = fastaPreview
    }

    func showMultiSelection(summary: AssemblyContigSelectionSummary, fastaPreview: String) {
        overviewSectionLabel.stringValue = "Selection Preview"
        titleLabel.stringValue = "\(summary.selectedContigCount) contigs selected"
        lengthLabel.stringValue = "\(summary.totalSelectedBP) bp total"
        gcLabel.stringValue = String(format: "%.1f%% weighted GC", summary.lengthWeightedGCPercent)
        rankLabel.stringValue = "Longest: \(summary.longestContigBP) bp"
        shareLabel.stringValue = "Shortest: \(summary.shortestContigBP) bp"
        sequenceView.string = fastaPreview
    }

    func showUnavailableSelectionSummary(selectedContigCount: Int, fastaPreview: String) {
        overviewSectionLabel.stringValue = "Selection Preview"
        titleLabel.stringValue = "\(selectedContigCount) contigs selected"
        lengthLabel.stringValue = ""
        gcLabel.stringValue = ""
        rankLabel.stringValue = ""
        shareLabel.stringValue = ""
        sequenceView.string = fastaPreview
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

    func testSetSequenceSelection(_ range: NSRange) {
        sequenceView.setSelectedRange(range)
    }

    func testSetSequenceScrollOrigin(_ origin: NSPoint) {
        sequenceScrollView.contentView.scroll(to: origin)
        sequenceScrollView.reflectScrolledClipView(sequenceScrollView.contentView)
    }
#endif
}
