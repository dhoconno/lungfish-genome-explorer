// MappingResultViewController.swift - Viewport for read mapping results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow

@MainActor
public final class MappingResultViewController: NSViewController {
    private(set) var currentResult: MappingResult?
    private var loadedViewerBundleURL: URL?
    private var didSetInitialSplitPosition = false

    private let embeddedViewerController = ViewerViewController()

    private let summaryBar: NSView = {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Mapping Results")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 32),
        ])

        return bar
    }()

    private let splitView: NSSplitView = {
        let split = NSSplitView()
        split.translatesAutoresizingMaskIntoConstraints = false
        split.isVertical = true
        split.dividerStyle = .thin
        return split
    }()

    private let listContainer = NSView()
    private let detailContainer = NSView()

    private let scrollView: NSScrollView = {
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        return scroll
    }()

    private let tableView: NSTableView = {
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let contig = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("contig"))
        contig.title = "Contig"
        contig.width = 220
        contig.minWidth = 140

        let length = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("length"))
        length.title = "Length"
        length.width = 90
        length.minWidth = 70

        let reads = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("reads"))
        reads.title = "Reads"
        reads.width = 90
        reads.minWidth = 70

        let mappedPct = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mappedPercent"))
        mappedPct.title = "% Mapped"
        mappedPct.width = 84
        mappedPct.minWidth = 74

        let depth = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("depth"))
        depth.title = "Depth"
        depth.width = 80
        depth.minWidth = 66

        let breadth = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("breadth"))
        breadth.title = "Breadth"
        breadth.width = 84
        breadth.minWidth = 70

        let mapq = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mapq"))
        mapq.title = "MAPQ"
        mapq.width = 72
        mapq.minWidth = 60

        let identity = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("identity"))
        identity.title = "Identity"
        identity.width = 84
        identity.minWidth = 70

        table.addTableColumn(contig)
        table.addTableColumn(length)
        table.addTableColumn(reads)
        table.addTableColumn(mappedPct)
        table.addTableColumn(depth)
        table.addTableColumn(breadth)
        table.addTableColumn(mapq)
        table.addTableColumn(identity)
        return table
    }()

    private let detailPlaceholderLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Select a mapped contig to inspect mapped reads.")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        return label
    }()

    private var contigRows: [MappingContigSummary] = []

    public override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        tableView.dataSource = self
        tableView.delegate = self
        scrollView.documentView = tableView

        listContainer.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.translatesAutoresizingMaskIntoConstraints = false
        splitView.addArrangedSubview(listContainer)
        splitView.addArrangedSubview(detailContainer)

        listContainer.addSubview(scrollView)
        detailContainer.addSubview(detailPlaceholderLabel)

        addChild(embeddedViewerController)
        let detailView = embeddedViewerController.view
        detailView.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(detailView, positioned: .below, relativeTo: detailPlaceholderLabel)

        view.addSubview(summaryBar)
        view.addSubview(splitView)

        NSLayoutConstraint.activate([
            summaryBar.topAnchor.constraint(equalTo: view.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            splitView.topAnchor.constraint(equalTo: summaryBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),

            detailView.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            detailView.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            detailView.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            detailView.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),

            detailPlaceholderLabel.centerXAnchor.constraint(equalTo: detailContainer.centerXAnchor),
            detailPlaceholderLabel.centerYAnchor.constraint(equalTo: detailContainer.centerYAnchor),
            detailPlaceholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: detailContainer.leadingAnchor, constant: 24),
            detailPlaceholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: detailContainer.trailingAnchor, constant: -24),

            listContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            detailContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
        ])

        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        guard !didSetInitialSplitPosition else { return }
        didSetInitialSplitPosition = true
        splitView.setPosition(420, ofDividerAt: 0)
    }

    private func updateSummaryBar() {
        guard let result = currentResult,
              let label = summaryBar.subviews.compactMap({ $0 as? NSTextField }).first else { return }
        let pct = result.totalReads > 0
            ? String(format: "%.1f%%", Double(result.mappedReads) / Double(result.totalReads) * 100)
            : "—"
        label.stringValue = "\(result.mapper.displayName) Mapping — \(result.mappedReads.formatted()) / \(result.totalReads.formatted()) reads mapped (\(pct))"
    }

    private func refreshSelection() {
        tableView.reloadData()
        if !contigRows.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            displaySelectedContig()
            return
        }

        if let viewerBundleURL = currentResult?.viewerBundleURL {
            do {
                try loadViewerBundleIfNeeded(from: viewerBundleURL)
                showDetailViewer()
            } catch {
                showDetailPlaceholder("Unable to load the reference mapping viewer.")
            }
        } else {
            showDetailPlaceholder("Reference bundle viewer unavailable for this mapping result.")
        }
    }

    private func loadViewerBundleIfNeeded(from bundleURL: URL) throws {
        let standardized = bundleURL.standardizedFileURL
        if loadedViewerBundleURL == standardized {
            return
        }

        embeddedViewerController.clearViewport(statusMessage: "Loading mapping viewer...")
        try embeddedViewerController.displayBundle(at: standardized)
        loadedViewerBundleURL = standardized
    }

    private func displaySelectedContig() {
        guard let result = currentResult else {
            showDetailPlaceholder("No mapping result loaded.")
            return
        }

        guard tableView.selectedRow >= 0, tableView.selectedRow < contigRows.count else {
            showDetailPlaceholder("Select a mapped contig to inspect mapped reads.")
            return
        }

        guard let viewerBundleURL = result.viewerBundleURL else {
            showDetailPlaceholder("Reference bundle viewer unavailable for this mapping result.")
            return
        }

        do {
            try loadViewerBundleIfNeeded(from: viewerBundleURL)
            let selectedContig = contigRows[tableView.selectedRow]
            guard let chromosome = embeddedViewerController.currentBundleDataProvider?.chromosomeInfo(named: selectedContig.contigName) else {
                showDetailPlaceholder("Selected contig is not present in the reference bundle.")
                return
            }

            showDetailViewer()
            embeddedViewerController.navigateToChromosomeAndPosition(
                chromosome: chromosome.name,
                chromosomeLength: Int(chromosome.length),
                start: 0,
                end: max(1, Int(chromosome.length))
            )
        } catch {
            showDetailPlaceholder("Unable to load the reference mapping viewer.")
        }
    }

    private func showDetailViewer() {
        embeddedViewerController.view.isHidden = false
        detailPlaceholderLabel.isHidden = true
    }

    private func showDetailPlaceholder(_ message: String) {
        detailPlaceholderLabel.stringValue = message
        detailPlaceholderLabel.isHidden = false
        embeddedViewerController.view.isHidden = true
    }
}

extension MappingResultViewController: ResultViewportController {
    public typealias ResultType = MappingResult

    public static var resultTypeName: String { "Mapping Results" }

    public func configure(result: MappingResult) {
        currentResult = result
        contigRows = result.contigs
        updateSummaryBar()
        loadedViewerBundleURL = nil
        refreshSelection()
    }

    public var summaryBarView: NSView { summaryBar }

    public func exportResults(to url: URL, format: ResultExportFormat) throws {
        throw NSError(
            domain: "Lungfish",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Mapping export not yet implemented"]
        )
    }
}

extension MappingResultViewController: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        contigRows.count
    }
}

extension MappingResultViewController: NSTableViewDelegate {
    public func tableViewSelectionDidChange(_ notification: Notification) {
        displaySelectedContig()
    }

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard row < contigRows.count else { return nil }

        let summary = contigRows[row]
        let cellIdentifier = NSUserInterfaceItemIdentifier("mapping-cell-\(tableColumn?.identifier.rawValue ?? "default")")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: cellIdentifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = cellIdentifier
            let textField = NSTextField(labelWithString: "")
            textField.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(textField)
            cell.textField = textField
            NSLayoutConstraint.activate([
                textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
                textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }

        switch tableColumn?.identifier.rawValue {
        case "contig":
            cell.textField?.stringValue = summary.contigName
            cell.textField?.alignment = .left
        case "length":
            cell.textField?.stringValue = summary.contigLength.formatted()
            cell.textField?.alignment = .right
        case "reads":
            cell.textField?.stringValue = summary.mappedReads.formatted()
            cell.textField?.alignment = .right
        case "mappedPercent":
            cell.textField?.stringValue = String(format: "%.1f%%", summary.mappedReadPercent * 100)
            cell.textField?.alignment = .right
        case "depth":
            cell.textField?.stringValue = String(format: "%.1f", summary.meanDepth)
            cell.textField?.alignment = .right
        case "breadth":
            cell.textField?.stringValue = String(format: "%.1f%%", summary.coverageBreadth * 100)
            cell.textField?.alignment = .right
        case "mapq":
            cell.textField?.stringValue = String(format: "%.1f", summary.medianMAPQ)
            cell.textField?.alignment = .right
        case "identity":
            cell.textField?.stringValue = String(format: "%.1f%%", summary.meanIdentity * 100)
            cell.textField?.alignment = .right
        default:
            cell.textField?.stringValue = ""
            cell.textField?.alignment = .left
        }

        return cell
    }
}
