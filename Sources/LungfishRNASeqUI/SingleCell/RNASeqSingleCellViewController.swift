// RNASeqSingleCellViewController.swift - The view of a single-cell RNA-seq result (Phase 5.4 lane RS-SC-VIEW)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The view shows the cell summary that the CLI wrote, paged from `cells.sqlite` opened read only. The top pane holds
// each `samples` row, the tool and version of the manifest's `origin`, the quality table as written, the barcode rank
// plot and the histograms. The bottom pane is the cells table with each cell's not-host columns. The view computes no
// number of its own (`docs/plans/2026-10-02-architecture-program.md:262`).

import AppKit
import LungfishIO

/// The view of a single-cell result. The container `RNASeqResultViewController` hosts it by the manifest's modality.
@MainActor
public final class RNASeqSingleCellViewController: NSViewController {
    public static let accessibilityID = "rnaseq-single-cell-view"

    public private(set) var result: RNASeqResult?
    public private(set) var bundleURL: URL?
    /// The summary shown, nil until the read ends or when it failed.
    public private(set) var summary: RNASeqSingleCellSummary?
    /// The reader's words when the cell summary could not be shown, and nil otherwise.
    public private(set) var failureWords: String?
    public private(set) var tableSource: RNASeqSingleCellTableSource?
    /// The read that `configure` started, which a test can wait on.
    public private(set) var loading: Task<Void, Never>?

    private let summaryStack = NSStackView()
    public let cellsTable = NSTableView()

    public override func loadView() {
        let root = NSView()
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityIdentifier(Self.accessibilityID)

        summaryStack.orientation = .vertical
        summaryStack.alignment = .leading
        summaryStack.spacing = 10
        summaryStack.edgeInsets = NSEdgeInsets(top: 4, left: 20, bottom: 12, right: 20)
        summaryStack.translatesAutoresizingMaskIntoConstraints = false
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(summaryStack)
        let top = NSScrollView()
        top.hasVerticalScroller = true
        top.drawsBackground = false
        top.documentView = document
        NSLayoutConstraint.activate([
            summaryStack.topAnchor.constraint(equalTo: document.topAnchor),
            summaryStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            summaryStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            summaryStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: top.contentView.widthAnchor),
        ])

        cellsTable.setAccessibilityIdentifier("rnaseq-sc-cells")
        cellsTable.usesAlternatingRowBackgroundColors = true
        cellsTable.allowsColumnReordering = false
        cellsTable.columnAutoresizingStyle = .noColumnAutoresizing
        let bottom = NSScrollView()
        bottom.hasVerticalScroller = true
        bottom.hasHorizontalScroller = true
        bottom.documentView = cellsTable

        let split = NSSplitView()
        split.isVertical = false
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(top)
        split.addArrangedSubview(bottom)
        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            top.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            bottom.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        view = root
    }

    /// Keeps the result and reads its cell summary off the main actor. A later call replaces an earlier read.
    public func configure(result: RNASeqResult, bundleURL: URL) {
        self.result = result
        self.bundleURL = bundleURL
        loading?.cancel()
        loading = Task { [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) {
                RNASeqSingleCellSummary.read(result, bundleURL: bundleURL)
            }.value
            guard !Task.isCancelled, let self, self.bundleURL == bundleURL else { return }
            self.show(outcome)
        }
    }

    /// Shows the summary and opens the cells table, or shows the words of the failure.
    public func show(_ outcome: RNASeqSingleCellLoadOutcome) {
        _ = view
        close()
        for line in summaryStack.arrangedSubviews {
            summaryStack.removeArrangedSubview(line)
            line.removeFromSuperview()
        }
        switch outcome {
        case .failed(let words):
            fail(words)
        case .loaded(let shown, let cellsURL):
            do {
                let source = RNASeqSingleCellTableSource(pages: try RNASeqSingleCellPages(cellsURL: cellsURL), summary: shown)
                summary = shown
                failureWords = nil
                tableSource = source
                source.install(in: cellsTable)
                lay(shown)
            } catch {
                fail(error.localizedDescription)
            }
        }
    }

    /// Lets go of the cells table, which closes its read-only handle on `cells.sqlite`.
    public func close() {
        tableSource?.pages.close()
        tableSource = nil
        cellsTable.dataSource = nil
        cellsTable.delegate = nil
        cellsTable.reloadData()
    }

    private func fail(_ words: String) {
        summary = nil
        failureWords = words
        summaryStack.addArrangedSubview(Self.text(words, id: "rnaseq-sc-failure", wraps: true))
    }

    private func lay(_ summary: RNASeqSingleCellSummary) {
        summaryStack.addArrangedSubview(Self.heading("Cell summary"))
        summaryStack.addArrangedSubview(Self.grid(
            header: ["Sample", "Cells", "Features", "Entries"],
            rows: summary.samples.map { [$0.name, String($0.cells), String($0.features), String($0.entries)] },
            id: "rnaseq-sc-samples"))
        summaryStack.addArrangedSubview(Self.fact("Tool", summary.tool, id: "rnaseq-sc-tool"))
        summaryStack.addArrangedSubview(Self.fact("Version", summary.toolVersion, id: "rnaseq-sc-tool-version"))
        summaryStack.addArrangedSubview(Self.fact("Cells", String(summary.cellCount), id: "rnaseq-sc-cell-count"))

        summaryStack.addArrangedSubview(Self.heading("Quality"))
        if let quality = summary.quality {
            // One row for each metric and one column for each sample. Side by side, the 20 metrics of a Cell Ranger run
            // are 3,834 pt wide and this pane does not scroll sideways. A value the file leaves null reads Not recorded.
            let metrics: [[String]] = quality.columns.enumerated().map { index, name in
                [name] + quality.rows.map { row in (index < row.values.count ? row.values[index] : nil) ?? RNASeqResultBundle.notRecordedText }
            }
            summaryStack.addArrangedSubview(Self.grid(header: ["Metric"] + quality.rows.map(\.sample), rows: metrics, id: "rnaseq-sc-quality"))
        } else {
            summaryStack.addArrangedSubview(Self.text(RNASeqSingleCellWords.noQuality, id: "rnaseq-sc-quality-none", wraps: true))
        }

        summaryStack.addArrangedSubview(Self.heading("Barcode rank"))
        summaryStack.addArrangedSubview(Self.text(RNASeqSingleCellWords.rankPlot, id: "rnaseq-sc-rank-words", wraps: true))
        if summary.cellCount == 0 {
            summaryStack.addArrangedSubview(Self.text(RNASeqSingleCellWords.noCells, id: "rnaseq-sc-no-cells", wraps: true))
        } else {
            summaryStack.addArrangedSubview(RNASeqRankPlotView(steps: summary.rankSteps))
        }

        for histogram in [summary.umis, summary.genes] {
            summaryStack.addArrangedSubview(Self.heading(histogram.title))
            summaryStack.addArrangedSubview(RNASeqHistogramView(histogram: histogram))
        }
        if summary.notHost.isEmpty {
            summaryStack.addArrangedSubview(Self.heading("Not-host UMIs per cell"))
            summaryStack.addArrangedSubview(Self.text(RNASeqSingleCellWords.noNotHost, id: "rnaseq-sc-no-not-host", wraps: true))
        }
        for histogram in summary.notHost {
            summaryStack.addArrangedSubview(Self.heading(histogram.title))
            summaryStack.addArrangedSubview(RNASeqHistogramView(histogram: histogram))
        }
        for extra in summary.extras {
            summaryStack.addArrangedSubview(Self.fact("\(extra.name) masked column", extra.maskWords, id: "rnaseq-sc-mask-words-\(extra.extra)"))
        }
    }

    /// A line of read-only text that a person can select and copy.
    static func text(_ string: String, id: String, wraps: Bool = false) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: string) : NSTextField(labelWithString: string)
        field.isEditable = false
        field.isSelectable = true
        field.setAccessibilityIdentifier(id)
        if wraps { field.preferredMaxLayoutWidth = 640 }
        return field
    }

    private static func heading(_ string: String) -> NSTextField {
        let field = NSTextField(labelWithString: string)
        field.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        return field
    }

    private static func fact(_ label: String, _ value: String, id: String) -> NSView {
        let name = NSTextField(labelWithString: label)
        name.textColor = .secondaryLabelColor
        name.setContentHuggingPriority(.required, for: .horizontal)
        let row = NSStackView(views: [name, text(value, id: id)])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 12
        return row
    }

    /// A grid of read-only text. Each value field carries `<id>-<row>-<column>`, from 0, under the header row.
    private static func grid(header: [String], rows: [[String]], id: String) -> NSView {
        let heads = header.map { title -> NSView in
            let field = NSTextField(labelWithString: title)
            field.textColor = .secondaryLabelColor
            return field
        }
        let body = rows.enumerated().map { index, values in
            values.enumerated().map { column, value -> NSView in text(value, id: "\(id)-\(index)-\(column)") }
        }
        let grid = NSGridView(views: [heads] + body)
        grid.columnSpacing = 16
        grid.rowSpacing = 4
        grid.setAccessibilityIdentifier(id)
        return grid
    }
}

/// A document view that lays out from the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
