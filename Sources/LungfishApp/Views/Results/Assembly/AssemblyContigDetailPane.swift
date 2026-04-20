// AssemblyContigDetailPane.swift - Detail presentation for selected assembly contigs
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow

@MainActor
final class AssemblyContigDetailPane: NSView {
    private let overviewSectionLabel = NSTextField(labelWithString: "Contig Overview")
    private let titleLabel = AssemblyQuickCopyTextField(labelWithString: "")
    private let lengthLabel = AssemblyQuickCopyTextField(labelWithString: "")
    private let gcLabel = AssemblyQuickCopyTextField(labelWithString: "")
    private let rankLabel = AssemblyQuickCopyTextField(labelWithString: "")
    private let shareLabel = AssemblyQuickCopyTextField(labelWithString: "")
    private let sequenceSectionLabel = NSTextField(labelWithString: "Sequence")
    private let contextSectionLabel = NSTextField(labelWithString: "Assembly Context")
    private let contextLabel = NSTextField(wrappingLabelWithString: "")
    private let artifactsSectionLabel = NSTextField(labelWithString: "Source Artifacts")
    private let artifactsLabel = NSTextField(wrappingLabelWithString: "")
    private let sequenceView = NSTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityIdentifier("assembly-result-detail")

        sequenceView.isEditable = false
        sequenceView.isSelectable = true
        sequenceView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        [overviewSectionLabel, sequenceSectionLabel, contextSectionLabel, artifactsSectionLabel].forEach {
            $0.font = .systemFont(ofSize: 11, weight: .semibold)
            $0.textColor = .secondaryLabelColor
        }

        let sequenceScrollView = NSScrollView()
        sequenceScrollView.translatesAutoresizingMaskIntoConstraints = false
        sequenceScrollView.hasVerticalScroller = true
        sequenceScrollView.autohidesScrollers = true
        sequenceScrollView.documentView = sequenceView

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.setAccessibilityIdentifier("assembly-result-detail-title")

        lengthLabel.setAccessibilityIdentifier("assembly-result-detail-length")
        gcLabel.setAccessibilityIdentifier("assembly-result-detail-gc")
        rankLabel.setAccessibilityIdentifier("assembly-result-detail-rank")
        shareLabel.setAccessibilityIdentifier("assembly-result-detail-share")

        let metricsRow = NSStackView(views: [lengthLabel, gcLabel, rankLabel, shareLabel])
        metricsRow.orientation = .horizontal
        metricsRow.spacing = 12

        contextLabel.textColor = .secondaryLabelColor
        artifactsLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(
            views: [
                overviewSectionLabel,
                titleLabel,
                metricsRow,
                sequenceSectionLabel,
                sequenceScrollView,
                contextSectionLabel,
                contextLabel,
                artifactsSectionLabel,
                artifactsLabel,
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
        contextLabel.stringValue = "\(contigCount) contigs available"
        artifactsLabel.stringValue = "Use the table to inspect sequence, assembly share, and source artifacts."
    }

    func showSingleSelection(record: AssemblyContigRecord, fasta: String, result: AssemblyResult) {
        titleLabel.stringValue = record.header
        lengthLabel.stringValue = "\(record.lengthBP) bp"
        gcLabel.stringValue = String(format: "%.1f%%", record.gcPercent)
        rankLabel.stringValue = "#\(record.rank)"
        shareLabel.stringValue = String(format: "%.2f%% of assembly", record.shareOfAssemblyPercent)
        sequenceView.string = fasta

        contextLabel.stringValue = """
        Assembler: \(result.tool.displayName)
        Read Type: \(result.readType.displayName)
        Version: \(result.assemblerVersion ?? "unknown")
        Wall Time: \(String(format: "%.1fs", result.wallTimeSeconds))
        Total Assembled bp: \(result.statistics.totalLengthBP)
        N50: \(result.statistics.n50) bp
        L50: \(result.statistics.l50)
        Longest Contig: \(result.statistics.largestContigBP) bp
        Global GC: \(String(format: "%.1f%%", result.statistics.gcPercent))
        Output Directory: \(result.outputDirectory.path)
        Command: \(result.commandLine)
        """

        artifactsLabel.stringValue = """
        Contigs FASTA: \(result.contigsPath.path)
        Graph: \(result.graphPath?.path ?? "missing")
        Scaffolds: \(result.scaffoldsPath?.path ?? "missing")
        Log: \(result.logPath?.path ?? "missing")
        Params: \(result.paramsPath?.path ?? "missing")
        """
    }

    func showMultiSelection(summary: AssemblyContigSelectionSummary) {
        titleLabel.stringValue = "\(summary.selectedContigCount) contigs selected"
        lengthLabel.stringValue = "\(summary.totalSelectedBP) bp total"
        gcLabel.stringValue = String(format: "%.1f%% weighted GC", summary.lengthWeightedGCPercent)
        rankLabel.stringValue = "Longest: \(summary.longestContigBP) bp"
        shareLabel.stringValue = "Shortest: \(summary.shortestContigBP) bp"
        sequenceView.string = ""
        contextLabel.stringValue = "Selection summary for the current visible contig set."
        artifactsLabel.stringValue = "Use Copy FASTA, Export FASTA, or Create Bundle to materialize the selected contigs."
    }

    func showUnavailableSelectionSummary(selectedContigCount: Int) {
        titleLabel.stringValue = "\(selectedContigCount) contigs selected"
        lengthLabel.stringValue = ""
        gcLabel.stringValue = ""
        rankLabel.stringValue = ""
        shareLabel.stringValue = ""
        sequenceView.string = ""
        contextLabel.stringValue = "Selection summary is temporarily unavailable."
        artifactsLabel.stringValue = "Use Copy FASTA, Export FASTA, or Create Bundle to materialize the selected contigs."
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
    var currentContextText: String { contextLabel.stringValue }
    var currentArtifactsText: String { artifactsLabel.stringValue }
#endif
}
