// AssemblyContigDetailPane.swift - Detail presentation for selected assembly contigs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow
import LungfishAppKit

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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("assembly-result-detail")
        setAccessibilityLabel("Assembly contig detail")

        sequenceView.isEditable = false
        sequenceView.isSelectable = true
        sequenceView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        sequenceView.setAccessibilityIdentifier("assembly-result-detail-sequence-text")
        sequenceView.setAccessibilityLabel("Contig sequence")

        [overviewSectionLabel, sequenceSectionLabel].forEach {
            $0.font = .systemFont(ofSize: 11, weight: .semibold)
            $0.textColor = .secondaryLabelColor
        }

        let sequenceScrollView = NSScrollView()
        sequenceScrollView.translatesAutoresizingMaskIntoConstraints = false
        sequenceScrollView.hasVerticalScroller = true
        sequenceScrollView.autohidesScrollers = true
        sequenceScrollView.documentView = sequenceView
        sequenceScrollView.setAccessibilityIdentifier("assembly-result-detail-sequence-area")

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.setAccessibilityIdentifier("assembly-result-detail-title")

        lengthLabel.setAccessibilityIdentifier("assembly-result-detail-length")
        gcLabel.setAccessibilityIdentifier("assembly-result-detail-gc")
        rankLabel.setAccessibilityIdentifier("assembly-result-detail-rank")
        shareLabel.setAccessibilityIdentifier("assembly-result-detail-share")

        let metricsRow = NSStackView(views: [lengthLabel, gcLabel, rankLabel, shareLabel])
        metricsRow.orientation = .horizontal
        metricsRow.spacing = 12

        let stack = NSStackView(
            views: [
                overviewSectionLabel,
                titleLabel,
                metricsRow,
                sequenceSectionLabel,
                sequenceScrollView,
            ]
        )
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            sequenceScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
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
#endif
}
