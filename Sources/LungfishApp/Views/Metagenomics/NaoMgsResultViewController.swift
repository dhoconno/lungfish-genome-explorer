// NaoMgsResultViewController.swift - NAO-MGS metagenomic surveillance result viewer
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import SwiftUI
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "NaoMgsResultVC")

// MARK: - NaoMgsResultViewController

/// A full-screen NAO-MGS metagenomic surveillance result browser.
///
/// `NaoMgsResultViewController` is the primary UI for displaying imported
/// NAO-MGS workflow results (`virus_hits_final.tsv`). It replaces the normal
/// sequence viewer content area following the same child-VC pattern as
/// ``TaxonomyViewController`` and ``EsVirituResultViewController``.
///
/// ## Layout
///
/// ```
/// +--------------------------------------------------+
/// | Summary Bar (48pt)                                |
/// +--------------------------------------------------+
/// |  Detail Pane       |  Taxonomy Table              |
/// |  (miniBAM viewer,  |                              |
/// |   accession info,  |  - Taxid 130309              |
/// |   metrics)         |    125,727 hits              |
/// |                    |  - Taxid 28284               |
/// |                    |    36,577 hits               |
/// |                    |  ...                         |
/// +--------------------------------------------------+
/// | Action Bar (36pt)                                 |
/// +--------------------------------------------------+
/// ```
///
/// ## MiniBAM Alignment Viewer
///
/// When a taxon is selected and BAM data is available, the detail pane shows
/// a MiniBAMViewController rendering the read pileup for the top accession.
/// Selecting accessions in the accession list switches the BAM display.
///
/// ## Thread Safety
///
/// This class is `@MainActor` isolated and uses raw `NSSplitView` (not
/// `NSSplitViewController`) per macOS 26 deprecated API rules.
@MainActor
public final class NaoMgsResultViewController: NSViewController, NSSplitViewDelegate {

    // MARK: - Data

    /// The NAO-MGS result driving this view.
    private(set) var naoMgsResult: NaoMgsResult?

    /// Hits grouped by taxonomy ID for efficient lookup.
    private var hitsByTaxon: [Int: [NaoMgsVirusHit]] = [:]

    /// Currently selected taxon summary.
    private var selectedTaxonSummary: NaoMgsTaxonSummary?

    /// Currently selected accession within the detail pane.
    private var selectedAccession: String?

    /// URL of the NAO-MGS bundle directory.
    private var bundleURL: URL?

    /// URL to the sorted BAM file for alignment display.
    private var bamURL: URL?

    /// URL to the BAM index (.bai) file.
    private var bamIndexURL: URL?

    // MARK: - Child Views

    private let summaryBar = NaoMgsSummaryBar()
    let splitView = NSSplitView()
    private let taxonomyTableScrollView = NSScrollView()
    private let taxonomyTableView = NSTableView()
    private let detailScrollView = NSScrollView()
    private let detailContentView = FlippedNaoMgsContentView()
    let actionBar = NaoMgsActionBar()

    // MARK: - MiniBAM

    /// The mini BAM view controller for alignment pileup display.
    private var miniBAMController: MiniBAMViewController?

    /// Preferred height for the mini BAM view (resizable).
    private var miniBAMPreferredHeight: CGFloat = 320
    private var miniBAMHeightConstraint: NSLayoutConstraint?
    private let miniBAMMinHeight: CGFloat = 220
    private let miniBAMMaxHeight: CGFloat = 900

    // MARK: - Split View State

    /// Whether the initial divider position has been applied.
    private var didSetInitialSplitPosition = false

    // MARK: - Selection Sync

    /// Prevents infinite feedback loops when syncing selection between views.
    private var suppressSelectionSync = false

    // MARK: - Callbacks

    /// Called when the user confirms BLAST verification for a taxon.
    public var onBlastVerification: ((NaoMgsTaxonSummary, Int, [NaoMgsVirusHit]) -> Void)?

    /// Called when the user wants to export results.
    public var onExport: (() -> Void)?

    /// Called when the user selects a taxon and wants to view it on NCBI.
    public var onViewOnNCBI: ((NaoMgsTaxonSummary) -> Void)?

    // MARK: - Lifecycle

    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view = container

        setupSummaryBar()
        setupSplitView()
        setupActionBar()
        layoutSubviews()
        wireCallbacks()

        showOverview()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()

        if !didSetInitialSplitPosition, splitView.bounds.width > 0 {
            didSetInitialSplitPosition = true
            // Detail pane on left gets 55%, taxonomy table on right gets 45%
            let position = round(splitView.bounds.width * 0.55)
            splitView.setPosition(position, ofDividerAt: 0)

            // Now that the split view has real bounds, size the detail content.
            resizeDetailContentToFit()
        }
    }

    // MARK: - Public API

    /// Configures the view with a parsed NAO-MGS result.
    public func configure(result: NaoMgsResult, bundleURL: URL? = nil) {
        naoMgsResult = result
        hitsByTaxon = NaoMgsDataConverter.groupByTaxon(result.virusHits)
        self.bundleURL = bundleURL

        // Discover BAM file in bundle
        if let bundleURL {
            discoverBAMFile(in: bundleURL, sampleName: result.sampleName)
        }

        // Set up mini BAM controller if BAM available
        setupMiniBAMViewer()

        // Update summary bar
        summaryBar.update(result: result)

        // Reload taxonomy table
        taxonomyTableView.reloadData()

        // Update action bar
        actionBar.configure(
            totalHits: result.totalHitReads,
            taxonCount: result.taxonSummaries.count
        )

        // Show overview in detail pane
        showOverview()

        logger.info("Configured NAO-MGS viewer with \(result.totalHitReads) hits, \(result.taxonSummaries.count) taxa, sample=\(result.sampleName, privacy: .public), bam=\(self.bamURL != nil)")
    }

    // MARK: - BAM Discovery

    /// Searches for the sorted BAM file and its index in the bundle directory.
    private func discoverBAMFile(in bundleURL: URL, sampleName: String) {
        let fm = FileManager.default

        // Try standard naming convention: {sample}.sorted.bam
        let standardBAM = bundleURL.appendingPathComponent("\(sampleName).sorted.bam")
        if fm.fileExists(atPath: standardBAM.path) {
            bamURL = standardBAM
            // Look for index
            let bai = bundleURL.appendingPathComponent("\(sampleName).sorted.bam.bai")
            let csi = bundleURL.appendingPathComponent("\(sampleName).sorted.bam.csi")
            if fm.fileExists(atPath: bai.path) {
                bamIndexURL = bai
            } else if fm.fileExists(atPath: csi.path) {
                bamIndexURL = csi
            }
            return
        }

        // Fallback: scan for any .sorted.bam file
        if let contents = try? fm.contentsOfDirectory(at: bundleURL, includingPropertiesForKeys: nil) {
            for file in contents where file.pathExtension == "bam" && file.lastPathComponent.contains("sorted") {
                bamURL = file
                let bai = file.appendingPathExtension("bai")
                let csi = file.deletingPathExtension().appendingPathExtension("csi")
                if fm.fileExists(atPath: bai.path) {
                    bamIndexURL = bai
                } else if fm.fileExists(atPath: csi.path) {
                    bamIndexURL = csi
                }
                break
            }
        }
    }

    // MARK: - MiniBAM Setup

    private func setupMiniBAMViewer() {
        guard bamURL != nil else { return }
        guard miniBAMController == nil else { return }

        let miniBAM = MiniBAMViewController()
        addChild(miniBAM)
        miniBAMController = miniBAM

        // Wire read stats callback for unique read display
        miniBAM.onReadStatsUpdated = { [weak self] totalReads, uniqueReads in
            guard let self, let summary = self.selectedTaxonSummary else { return }
            self.updateDetailMetrics(summary: summary, uniqueReads: uniqueReads, totalReads: totalReads)
        }
    }

    // MARK: - Detail Pane Content

    /// Shows the overview when no taxon is selected.
    private func showOverview() {
        selectedTaxonSummary = nil
        selectedAccession = nil
        miniBAMController?.clear()

        rebuildDetailContent()
        actionBar.updateSelection(nil)
    }

    /// Shows the detail pane for the selected taxon.
    private func showTaxonDetail(_ summary: NaoMgsTaxonSummary) {
        selectedTaxonSummary = summary
        let hits = hitsByTaxon[summary.taxId] ?? []

        let accessionSummaries = NaoMgsDataConverter.buildAccessionSummaries(hits: hits)
        let topAccession = accessionSummaries.first?.accession
        selectedAccession = topAccession

        rebuildDetailContent()
        actionBar.updateSelection(summary)

        // Load BAM for top accession
        if let bamURL, let topAccession {
            let refLength = accessionSummaries.first?.estimatedRefLength ?? 0
            miniBAMController?.displayContig(
                bamURL: bamURL,
                contig: topAccession,
                contigLength: refLength,
                indexURL: bamIndexURL
            )
        } else {
            miniBAMController?.clear()
        }
    }

    /// Switches the miniBAM display to a different accession.
    private func switchToAccession(_ accession: String) {
        selectedAccession = accession

        guard let bamURL, let summary = selectedTaxonSummary else { return }
        let hits = hitsByTaxon[summary.taxId] ?? []
        let accessionSummaries = NaoMgsDataConverter.buildAccessionSummaries(hits: hits)
        let refLength = accessionSummaries.first(where: { $0.accession == accession })?.estimatedRefLength ?? 0

        miniBAMController?.displayContig(
            bamURL: bamURL,
            contig: accession,
            contigLength: refLength,
            indexURL: bamIndexURL
        )
    }

    /// Updates the metrics labels in the detail pane after BAM stats change.
    private func updateDetailMetrics(summary: NaoMgsTaxonSummary, uniqueReads: Int, totalReads: Int) {
        // Update the action bar with unique read info
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        let uniqueStr = formatter.string(from: NSNumber(value: uniqueReads)) ?? "\(uniqueReads)"
        let totalStr = formatter.string(from: NSNumber(value: totalReads)) ?? "\(totalReads)"

        let totalHits = naoMgsResult?.totalHitReads ?? 0
        let pct = totalHits > 0 ? Double(summary.hitCount) / Double(totalHits) * 100 : 0
        let pctStr = String(format: "%.1f%%", pct)

        actionBar.infoLabel.stringValue = "\(summary.name) \u{2014} \(uniqueStr) unique / \(totalStr) total reads (\(pctStr))"
        actionBar.infoLabel.textColor = .labelColor
    }

    // MARK: - Detail Content Rebuild

    private func rebuildDetailContent() {
        for subview in detailContentView.subviews {
            subview.removeFromSuperview()
        }
        // Reset any active constraints on the content view
        detailContentView.removeConstraints(detailContentView.constraints)
        miniBAMHeightConstraint = nil

        if let summary = selectedTaxonSummary {
            buildTaxonDetailContent(summary)
        } else {
            buildOverviewContent()
        }

        // Use a deferred layout pass so the scroll view has real bounds.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resizeDetailContentToFit()
        }
    }

    /// Sizes the detail content view to match the scroll view width and fit content height.
    private func resizeDetailContentToFit() {
        let clipWidth = detailScrollView.contentView.bounds.width
        guard clipWidth > 0 else { return }

        // Set width to match clip view, then let Auto Layout compute height.
        detailContentView.frame.size.width = clipWidth
        detailContentView.layoutSubtreeIfNeeded()

        let fittingSize = detailContentView.fittingSize
        detailContentView.frame = NSRect(
            x: 0, y: 0,
            width: clipWidth,
            height: max(fittingSize.height, 400)
        )

        detailScrollView.contentView.scroll(to: .zero)
        detailScrollView.reflectScrolledClipView(detailScrollView.contentView)
    }

    // MARK: - Overview Content

    private func buildOverviewContent() {
        guard let result = naoMgsResult else { return }

        let titleLabel = NSTextField(labelWithString: "NAO-MGS Results Overview")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailContentView.addSubview(titleLabel)

        let subtitleLabel = NSTextField(labelWithString: "Select a taxon in the table to view alignments and statistics.")
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailContentView.addSubview(subtitleLabel)

        // Quick stats using hosting view
        let statsView = NaoMgsOverviewView(
            taxonSummaries: result.taxonSummaries,
            totalHitReads: result.totalHitReads,
            sampleName: result.sampleName,
            onTaxonSelected: { [weak self] taxId in
                self?.selectTaxonById(taxId)
            }
        )
        let hostingView = NSHostingView(rootView: statsView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        detailContentView.addSubview(hostingView)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: detailContentView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor, constant: -16),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor, constant: -16),

            hostingView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            hostingView.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor),
            hostingView.bottomAnchor.constraint(lessThanOrEqualTo: detailContentView.bottomAnchor, constant: -16),
        ])
    }

    // MARK: - Taxon Detail Content

    private func buildTaxonDetailContent(_ summary: NaoMgsTaxonSummary) {
        let hits = hitsByTaxon[summary.taxId] ?? []
        let accessionSummaries = NaoMgsDataConverter.buildAccessionSummaries(hits: hits)

        var lastView: NSView = detailContentView
        var lastBottomConstant: CGFloat = 16

        // 1. MiniBAM pileup at top (when BAM is available)
        if bamURL != nil, let miniBAM = miniBAMController {
            let bamView = miniBAM.view
            bamView.translatesAutoresizingMaskIntoConstraints = false
            detailContentView.addSubview(bamView)

            miniBAM.onResizeBy = { [weak self] deltaY in
                self?.adjustMiniBAMHeight(by: deltaY)
            }

            let bamHeight = bamView.heightAnchor.constraint(equalToConstant: miniBAMPreferredHeight)
            miniBAMHeightConstraint = bamHeight

            NSLayoutConstraint.activate([
                bamView.topAnchor.constraint(equalTo: detailContentView.topAnchor, constant: 8),
                bamView.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor, constant: 4),
                bamView.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor, constant: -4),
                bamHeight,
            ])
            lastView = bamView
            lastBottomConstant = 12
        }

        // 2. Taxon name header
        let nameLabel = NSTextField(labelWithString: summary.name.isEmpty ? "Taxid \(summary.taxId)" : summary.name)
        nameLabel.font = .systemFont(ofSize: 14, weight: .bold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        detailContentView.addSubview(nameLabel)

        let subtitleLabel = NSTextField(labelWithString: "Taxid: \(summary.taxId)  \u{2022}  \(summary.hitCount) reads  \u{2022}  \(summary.accessions.count) accessions")
        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailContentView.addSubview(subtitleLabel)

        // 3. Metrics row
        let metricsView = buildMetricsView(for: summary)
        detailContentView.addSubview(metricsView)

        // 4. Accession list (scrollable)
        let accessionListView = buildAccessionList(accessionSummaries: accessionSummaries)
        detailContentView.addSubview(accessionListView)

        // Constraints
        let topAnchor = (lastView === detailContentView)
            ? detailContentView.topAnchor
            : lastView.bottomAnchor

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: lastBottomConstant),
            nameLabel.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor, constant: -16),

            subtitleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor, constant: -16),

            metricsView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            metricsView.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor, constant: 16),
            metricsView.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor, constant: -16),

            accessionListView.topAnchor.constraint(equalTo: metricsView.bottomAnchor, constant: 12),
            accessionListView.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor, constant: 16),
            accessionListView.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor, constant: -16),
            accessionListView.bottomAnchor.constraint(lessThanOrEqualTo: detailContentView.bottomAnchor, constant: -8),
        ])
    }

    private func adjustMiniBAMHeight(by deltaY: CGFloat) {
        guard let constraint = miniBAMHeightConstraint else { return }
        let availableHeight = max(detailContentView.bounds.height, view.bounds.height) - 120
        let maxHeight = max(miniBAMMinHeight, min(miniBAMMaxHeight, availableHeight))
        miniBAMPreferredHeight = min(max(miniBAMMinHeight, miniBAMPreferredHeight + deltaY), maxHeight)
        constraint.constant = miniBAMPreferredHeight
        detailContentView.layoutSubtreeIfNeeded()
    }

    private func buildMetricsView(for summary: NaoMgsTaxonSummary) -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .top
        container.distribution = .fillEqually
        container.spacing = 8
        container.translatesAutoresizingMaskIntoConstraints = false

        let metrics: [(String, String)] = [
            ("Avg Identity", String(format: "%.1f%%", summary.avgIdentity)),
            ("Avg Bit Score", String(format: "%.0f", summary.avgBitScore)),
            ("Avg Edit Dist", String(format: "%.1f", summary.avgEditDistance)),
            ("Accessions", "\(summary.accessions.count)"),
        ]

        for (label, value) in metrics {
            let pill = makeMetricPill(label: label, value: value)
            container.addArrangedSubview(pill)
        }

        return container
    }

    private func makeMetricPill(label: String, value: String) -> NSView {
        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false

        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 9, weight: .medium)
        labelField.textColor = .tertiaryLabelColor
        labelField.alignment = .center
        labelField.translatesAutoresizingMaskIntoConstraints = false

        let valueField = NSTextField(labelWithString: value)
        valueField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        valueField.textColor = .labelColor
        valueField.alignment = .center
        valueField.translatesAutoresizingMaskIntoConstraints = false

        pill.addSubview(labelField)
        pill.addSubview(valueField)

        NSLayoutConstraint.activate([
            labelField.topAnchor.constraint(equalTo: pill.topAnchor),
            labelField.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            labelField.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            valueField.topAnchor.constraint(equalTo: labelField.bottomAnchor, constant: 2),
            valueField.leadingAnchor.constraint(equalTo: pill.leadingAnchor),
            valueField.trailingAnchor.constraint(equalTo: pill.trailingAnchor),
            valueField.bottomAnchor.constraint(equalTo: pill.bottomAnchor),
        ])

        return pill
    }

    private func buildAccessionList(accessionSummaries: [NaoMgsAccessionSummary]) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let headerLabel = NSTextField(labelWithString: "Reference Accessions (\(accessionSummaries.count))")
        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerLabel)

        // Create accession table
        let tableScrollView = NSScrollView()
        tableScrollView.translatesAutoresizingMaskIntoConstraints = false
        tableScrollView.hasVerticalScroller = true
        tableScrollView.autohidesScrollers = true

        let accessionTable = NSTableView()
        accessionTable.headerView = nil
        accessionTable.rowHeight = 20
        accessionTable.style = .plain
        accessionTable.usesAlternatingRowBackgroundColors = false

        let accColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("accession"))
        accColumn.title = "Accession"
        accessionTable.addTableColumn(accColumn)

        // Use tags to identify this table vs the taxonomy table
        accessionTable.tag = 999

        // Store summaries for the data source
        let wrapper = AccessionDataWrapper(summaries: accessionSummaries, selected: selectedAccession)
        accessionTable.dataSource = wrapper
        accessionTable.delegate = wrapper
        objc_setAssociatedObject(container, &accessionDataKey, wrapper, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        wrapper.onSelect = { [weak self] accession in
            self?.selectedAccession = accession
            self?.switchToAccession(accession)
        }

        // Right-click context menu for copying accession
        let menu = NSMenu(title: "Accession Actions")
        wrapper.contextMenu = menu
        wrapper.populateMenu = { [weak self] menu, accession in
            menu.removeAllItems()
            let copyItem = NSMenuItem(title: "Copy Accession", action: #selector(self?.contextCopyAccession(_:)), keyEquivalent: "")
            copyItem.target = self
            copyItem.representedObject = accession
            menu.addItem(copyItem)

            let viewNCBI = NSMenuItem(title: "View on NCBI", action: #selector(self?.contextViewAccessionOnNCBI(_:)), keyEquivalent: "")
            viewNCBI.target = self
            viewNCBI.representedObject = accession
            menu.addItem(viewNCBI)
        }
        accessionTable.menu = menu

        tableScrollView.documentView = accessionTable

        container.addSubview(tableScrollView)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            tableScrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 4),
            tableScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),
            tableScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    // MARK: - Taxon Selection

    /// Selects a taxon by its taxonomy ID, updating both the table and detail pane.
    private func selectTaxonById(_ taxId: Int) {
        guard let result = naoMgsResult else { return }
        let summaries = sortedSummaries
        guard let index = summaries.firstIndex(where: { $0.taxId == taxId }) else { return }

        suppressSelectionSync = true
        taxonomyTableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        taxonomyTableView.scrollRowToVisible(index)
        suppressSelectionSync = false

        showTaxonDetail(summaries[index])
    }

    // MARK: - Setup: Summary Bar

    private func setupSummaryBar() {
        summaryBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(summaryBar)
    }

    // MARK: - Setup: Split View

    /// Configures the NSSplitView with detail pane (left) and taxonomy table (right).
    ///
    /// Uses raw NSSplitView (not NSSplitViewController) per macOS 26 rules.
    private func setupSplitView() {
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self

        // Left pane: detail (miniBAM + metrics + accessions).
        // The detail pane is a self-contained NSView that uses an internal scroll view.
        // NSSplitView arranged subviews use frame-based layout (default).
        let detailContainer = NaoMgsDetailContainer(scrollView: detailScrollView, contentView: detailContentView)
        detailContainer.wantsLayer = false // macOS 26: layer-backed by default

        // Right pane: taxonomy table
        let tableContainer = NSView()
        setupTaxonomyTable()
        taxonomyTableScrollView.autoresizingMask = [.width, .height]
        tableContainer.addSubview(taxonomyTableScrollView)

        splitView.addArrangedSubview(detailContainer)
        splitView.addArrangedSubview(tableContainer)

        // Detail pane holds width more firmly (table is preferred for resize)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        view.addSubview(splitView)
    }

    /// Configures the taxonomy table with columns for taxon data.
    private func setupTaxonomyTable() {
        taxonomyTableView.headerView = NSTableHeaderView()
        taxonomyTableView.usesAlternatingRowBackgroundColors = true
        taxonomyTableView.allowsMultipleSelection = false
        taxonomyTableView.allowsColumnReordering = true
        taxonomyTableView.allowsColumnResizing = true
        taxonomyTableView.style = .inset
        taxonomyTableView.intercellSpacing = NSSize(width: 8, height: 2)
        taxonomyTableView.rowHeight = 22

        // Columns
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Taxon"
        nameColumn.width = 160
        nameColumn.minWidth = 80
        nameColumn.sortDescriptorPrototype = NSSortDescriptor(key: "name", ascending: true, selector: #selector(NSString.localizedCaseInsensitiveCompare(_:)))
        taxonomyTableView.addTableColumn(nameColumn)

        let hitsColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("hits"))
        hitsColumn.title = "Hits"
        hitsColumn.width = 64
        hitsColumn.minWidth = 48
        hitsColumn.sortDescriptorPrototype = NSSortDescriptor(key: "hits", ascending: false)
        taxonomyTableView.addTableColumn(hitsColumn)

        let identityColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("identity"))
        identityColumn.title = "Avg Identity"
        identityColumn.width = 72
        identityColumn.minWidth = 56
        identityColumn.sortDescriptorPrototype = NSSortDescriptor(key: "identity", ascending: false)
        taxonomyTableView.addTableColumn(identityColumn)

        let accessionsColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("accessions"))
        accessionsColumn.title = "Refs"
        accessionsColumn.width = 40
        accessionsColumn.minWidth = 32
        accessionsColumn.sortDescriptorPrototype = NSSortDescriptor(key: "accessions", ascending: false)
        taxonomyTableView.addTableColumn(accessionsColumn)

        taxonomyTableView.dataSource = self
        taxonomyTableView.delegate = self
        taxonomyTableView.menu = buildContextMenu()

        // Sort by hits descending initially
        taxonomyTableView.sortDescriptors = [
            NSSortDescriptor(key: "hits", ascending: false)
        ]

        // Scroll view setup
        taxonomyTableScrollView.documentView = taxonomyTableView
        taxonomyTableScrollView.hasVerticalScroller = true
        taxonomyTableScrollView.hasHorizontalScroller = false
        taxonomyTableScrollView.autohidesScrollers = true
        taxonomyTableScrollView.drawsBackground = true

        taxonomyTableView.setAccessibilityLabel("NAO-MGS Taxonomy Table")
    }

    // MARK: - Setup: Action Bar

    private func setupActionBar() {
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actionBar)
    }

    // MARK: - Layout

    private func layoutSubviews() {
        NSLayoutConstraint.activate([
            // Summary bar (top)
            summaryBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            summaryBar.heightAnchor.constraint(equalToConstant: 48),

            // Action bar (bottom, fixed height)
            actionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: 36),

            // Split view (fills remaining space)
            splitView.topAnchor.constraint(equalTo: summaryBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: actionBar.topAnchor),
        ])
    }

    // MARK: - Callback Wiring

    private func wireCallbacks() {
        actionBar.onExport = { [weak self] in
            self?.exportResults()
        }
    }

    // MARK: - Context Menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Taxon Actions")
        menu.delegate = self
        return menu
    }

    private func populateContextMenu(_ menu: NSMenu, for summary: NaoMgsTaxonSummary) {
        menu.removeAllItems()

        let hitCount = summary.hitCount

        // BLAST verification options
        let defaultCount = min(20, hitCount)
        let blast20 = NSMenuItem(
            title: "BLAST Verify (\(defaultCount) reads)",
            action: #selector(contextBlastVerify(_:)),
            keyEquivalent: ""
        )
        blast20.target = self
        blast20.representedObject = (summary, defaultCount)
        menu.addItem(blast20)

        if hitCount > 20 {
            let blast50 = NSMenuItem(
                title: "BLAST Verify (\(min(50, hitCount)) reads)",
                action: #selector(contextBlastVerify(_:)),
                keyEquivalent: ""
            )
            blast50.target = self
            blast50.representedObject = (summary, min(50, hitCount))
            menu.addItem(blast50)
        }

        menu.addItem(NSMenuItem.separator())

        // Copy Taxon ID
        let copyTaxId = NSMenuItem(title: "Copy Taxon ID", action: #selector(contextCopyTaxonId(_:)), keyEquivalent: "")
        copyTaxId.target = self
        copyTaxId.representedObject = summary
        menu.addItem(copyTaxId)

        // Copy accessions
        if !summary.accessions.isEmpty {
            let copyAccessions = NSMenuItem(title: "Copy Accessions", action: #selector(contextCopyAccessions(_:)), keyEquivalent: "")
            copyAccessions.target = self
            copyAccessions.representedObject = summary
            menu.addItem(copyAccessions)
        }

        menu.addItem(NSMenuItem.separator())

        // View on NCBI
        let viewNCBI = NSMenuItem(title: "View on NCBI", action: #selector(contextViewOnNCBI(_:)), keyEquivalent: "")
        viewNCBI.target = self
        viewNCBI.representedObject = summary
        menu.addItem(viewNCBI)

        let viewTaxonomy = NSMenuItem(title: "View Taxonomy on NCBI", action: #selector(contextViewTaxonomyOnNCBI(_:)), keyEquivalent: "")
        viewTaxonomy.target = self
        viewTaxonomy.representedObject = summary
        menu.addItem(viewTaxonomy)

        let searchPubMed = NSMenuItem(title: "Search PubMed", action: #selector(contextSearchPubMed(_:)), keyEquivalent: "")
        searchPubMed.target = self
        searchPubMed.representedObject = summary
        menu.addItem(searchPubMed)
    }

    // MARK: - Context Menu Actions

    @objc private func contextBlastVerify(_ sender: NSMenuItem) {
        guard let (summary, count) = sender.representedObject as? (NaoMgsTaxonSummary, Int) else { return }
        let hits = hitsByTaxon[summary.taxId] ?? []
        let selectedReads = NaoMgsDataConverter.selectBlastReads(hits: hits, count: count)
        logger.info("BLAST verify taxon \(summary.taxId): \(selectedReads.count) reads selected from \(hits.count) total")
        onBlastVerification?(summary, selectedReads.count, selectedReads)
    }

    @objc private func contextCopyTaxonId(_ sender: NSMenuItem) {
        guard let summary = sender.representedObject as? NaoMgsTaxonSummary else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(summary.taxId)", forType: .string)
    }

    @objc private func contextCopyAccessions(_ sender: NSMenuItem) {
        guard let summary = sender.representedObject as? NaoMgsTaxonSummary else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary.accessions.joined(separator: "\n"), forType: .string)
    }

    @objc func contextCopyAccession(_ sender: NSMenuItem) {
        guard let accession = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(accession, forType: .string)
    }

    @objc func contextViewAccessionOnNCBI(_ sender: NSMenuItem) {
        guard let accession = sender.representedObject as? String else { return }
        let url = URL(string: "https://www.ncbi.nlm.nih.gov/nuccore/\(accession)")!
        NSWorkspace.shared.open(url)
    }

    @objc private func contextViewOnNCBI(_ sender: NSMenuItem) {
        guard let summary = sender.representedObject as? NaoMgsTaxonSummary else { return }
        let url = URL(string: "https://www.ncbi.nlm.nih.gov/nuccore/?term=txid\(summary.taxId)[Organism:exp]")!
        NSWorkspace.shared.open(url)
    }

    @objc private func contextViewTaxonomyOnNCBI(_ sender: NSMenuItem) {
        guard let summary = sender.representedObject as? NaoMgsTaxonSummary else { return }
        let url = URL(string: "https://www.ncbi.nlm.nih.gov/datasets/taxonomy/\(summary.taxId)/")!
        NSWorkspace.shared.open(url)
    }

    @objc private func contextSearchPubMed(_ sender: NSMenuItem) {
        guard let summary = sender.representedObject as? NaoMgsTaxonSummary else { return }
        let encodedName = summary.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? summary.name
        let url = URL(string: "https://pubmed.ncbi.nlm.nih.gov/?term=\(encodedName)")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - NSSplitViewDelegate

    public func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofDividerAt dividerIndex: Int) -> CGFloat {
        return max(proposedMinimumPosition, 300)
    }

    public func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofDividerAt dividerIndex: Int) -> CGFloat {
        return min(proposedMaximumPosition, splitView.bounds.width - 200)
    }

    // MARK: - Export

    public func exportResults() {
        guard let result = naoMgsResult, let window = view.window else { return }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.tabSeparatedText]
        savePanel.nameFieldStringValue = "\(result.sampleName)_naomgs_summary.tsv"
        savePanel.title = "Export NAO-MGS Summary"

        savePanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = savePanel.url,
                  let self, let result = self.naoMgsResult else { return }

            var lines: [String] = []
            lines.append("taxon_id\tname\thit_count\tavg_identity\tavg_bit_score\tavg_edit_distance\taccessions")

            for summary in result.taxonSummaries {
                let accStr = summary.accessions.joined(separator: ",")
                lines.append("\(summary.taxId)\t\(summary.name)\t\(summary.hitCount)\t\(String(format: "%.2f", summary.avgIdentity))\t\(String(format: "%.1f", summary.avgBitScore))\t\(String(format: "%.1f", summary.avgEditDistance))\t\(accStr)")
            }

            let content = lines.joined(separator: "\n") + "\n"
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                logger.info("Exported NAO-MGS summary to \(url.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("Failed to export NAO-MGS summary: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Sorted Data

    private var sortedSummaries: [NaoMgsTaxonSummary] {
        guard let result = naoMgsResult else { return [] }
        var summaries = result.taxonSummaries

        if let sortDescriptor = taxonomyTableView.sortDescriptors.first {
            switch sortDescriptor.key {
            case "name":
                summaries.sort {
                    let result = $0.name.localizedCaseInsensitiveCompare($1.name)
                    return sortDescriptor.ascending ? result == .orderedAscending : result == .orderedDescending
                }
            case "hits":
                summaries.sort {
                    sortDescriptor.ascending ? $0.hitCount < $1.hitCount : $0.hitCount > $1.hitCount
                }
            case "identity":
                summaries.sort {
                    sortDescriptor.ascending ? $0.avgIdentity < $1.avgIdentity : $0.avgIdentity > $1.avgIdentity
                }
            case "accessions":
                summaries.sort {
                    sortDescriptor.ascending
                        ? $0.accessions.count < $1.accessions.count
                        : $0.accessions.count > $1.accessions.count
                }
            default:
                break
            }
        }

        return summaries
    }
}

// MARK: - FlippedNaoMgsContentView

/// Flipped container so Auto Layout `topAnchor` maps to visual top.
private final class FlippedNaoMgsContentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - NaoMgsDetailContainer

/// A self-contained detail pane container that manages a scroll view filling its bounds.
///
/// This is added directly as an NSSplitView arranged subview. NSSplitView
/// manages its frame via frame-based layout. The container fills itself
/// with the scroll view using autoresizing masks.
private final class NaoMgsDetailContainer: NSView {

    init(scrollView: NSScrollView, contentView: FlippedNaoMgsContentView) {
        super.init(frame: .zero)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = contentView
        scrollView.autoresizingMask = [.width, .height]
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var isFlipped: Bool { true }
}

// MARK: - NSTableViewDataSource

extension NaoMgsResultViewController: NSTableViewDataSource {

    public func numberOfRows(in tableView: NSTableView) -> Int {
        sortedSummaries.count
    }

    public func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        tableView.reloadData()
    }
}

// MARK: - NSTableViewDelegate

extension NaoMgsResultViewController: NSTableViewDelegate {

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let summaries = sortedSummaries
        guard row < summaries.count else { return nil }

        let summary = summaries[row]
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("default")

        let cellView = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeCellView(identifier: identifier)

        switch identifier.rawValue {
        case "name":
            cellView.textField?.stringValue = summary.name.isEmpty ? "Taxid \(summary.taxId)" : summary.name
            cellView.textField?.font = .systemFont(ofSize: 11)
            cellView.textField?.lineBreakMode = .byTruncatingTail
        case "hits":
            cellView.textField?.stringValue = naoMgsFormatCount(summary.hitCount)
            cellView.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            cellView.textField?.alignment = .right
        case "identity":
            cellView.textField?.stringValue = String(format: "%.1f%%", summary.avgIdentity)
            cellView.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cellView.textField?.alignment = .right
        case "accessions":
            cellView.textField?.stringValue = "\(summary.accessions.count)"
            cellView.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cellView.textField?.alignment = .right
        default:
            cellView.textField?.stringValue = ""
        }

        return cellView
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionSync else { return }

        let row = taxonomyTableView.selectedRow
        let summaries = sortedSummaries

        if row >= 0, row < summaries.count {
            showTaxonDetail(summaries[row])
        } else {
            showOverview()
        }
    }

    private func makeCellView(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.truncatesLastVisibleLine = true
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }
}

/// Formats a count with K/M suffixes for the taxonomy table.
private func naoMgsFormatCount(_ count: Int) -> String {
    if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
    if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
    return "\(count)"
}

// MARK: - NSMenuDelegate

extension NaoMgsResultViewController: NSMenuDelegate {

    public func menuNeedsUpdate(_ menu: NSMenu) {
        let clickedRow = taxonomyTableView.clickedRow
        let summaries = sortedSummaries

        guard clickedRow >= 0, clickedRow < summaries.count else {
            menu.removeAllItems()
            return
        }

        populateContextMenu(menu, for: summaries[clickedRow])
    }
}

// MARK: - NaoMgsSummaryBar

@MainActor
final class NaoMgsSummaryBar: GenomicSummaryCardBar {

    private var totalHits: Int = 0
    private var taxonCount: Int = 0
    private var topTaxonName: String = ""
    private var sampleName: String = ""

    func update(result: NaoMgsResult) {
        totalHits = result.totalHitReads
        taxonCount = result.taxonSummaries.count
        let firstName = result.taxonSummaries.first?.name ?? ""
        topTaxonName = firstName.isEmpty
            ? (result.taxonSummaries.first.map { "Taxid \($0.taxId)" } ?? "\u{2014}")
            : firstName
        sampleName = result.sampleName
        needsDisplay = true
    }

    override var cards: [Card] {
        [
            Card(label: "Virus Hits", value: GenomicSummaryCardBar.formatCount(totalHits)),
            Card(label: "Unique Taxa", value: "\(taxonCount)"),
            Card(label: "Top Taxon", value: topTaxonName),
            Card(label: "Sample", value: sampleName),
        ]
    }

    override func abbreviatedLabel(for label: String) -> String {
        switch label {
        case "Virus Hits": return "Hits"
        case "Unique Taxa": return "Taxa"
        case "Top Taxon": return "Top"
        default: return super.abbreviatedLabel(for: label)
        }
    }
}

// MARK: - NaoMgsActionBar

@MainActor
final class NaoMgsActionBar: NSView {

    var onExport: (() -> Void)?

    private var totalHits: Int = 0

    private let exportButton = NSButton(title: "Export", target: nil, action: nil)
    let infoLabel = NSTextField(labelWithString: "")
    private let separator = NSBox()

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        exportButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.bezelStyle = .accessoryBarAction
        exportButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
        exportButton.imagePosition = .imageLeading
        exportButton.target = self
        exportButton.action = #selector(exportTapped(_:))
        exportButton.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(exportButton)

        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.font = .systemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingTail
        infoLabel.stringValue = "Select a taxon to view details"
        addSubview(infoLabel)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            exportButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            exportButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            infoLabel.leadingAnchor.constraint(equalTo: exportButton.trailingAnchor, constant: 12),
            infoLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            infoLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
        ])

        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("NAO-MGS Action Bar")
    }

    func configure(totalHits: Int, taxonCount: Int) {
        self.totalHits = totalHits
    }

    func updateSelection(_ summary: NaoMgsTaxonSummary?) {
        if let summary {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = ","
            let readStr = formatter.string(from: NSNumber(value: summary.hitCount)) ?? "\(summary.hitCount)"

            let pct = totalHits > 0
                ? Double(summary.hitCount) / Double(totalHits) * 100
                : 0
            let pctStr = String(format: "%.1f%%", pct)

            infoLabel.stringValue = "\(summary.name) \u{2014} \(readStr) hits (\(pctStr))"
            infoLabel.textColor = .labelColor
        } else {
            infoLabel.stringValue = "Select a taxon to view details"
            infoLabel.textColor = .secondaryLabelColor
        }
    }

    var infoText: String {
        infoLabel.stringValue
    }

    @objc private func exportTapped(_ sender: NSButton) {
        onExport?()
    }
}

// MARK: - AccessionDataWrapper

/// Lightweight data source for the accession table in the detail pane.
///
/// Stored as an associated object on the container view to keep it alive.
nonisolated(unsafe) private var accessionDataKey: UInt8 = 0

@MainActor
private final class AccessionDataWrapper: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    let summaries: [NaoMgsAccessionSummary]
    var selectedAccession: String?
    var onSelect: ((String) -> Void)?
    var contextMenu: NSMenu?
    var populateMenu: ((NSMenu, String) -> Void)?

    init(summaries: [NaoMgsAccessionSummary], selected: String?) {
        self.summaries = summaries
        self.selectedAccession = selected
        super.init()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        summaries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < summaries.count else { return nil }
        let summary = summaries[row]

        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("accRow"), owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = NSUserInterfaceItemIdentifier("accRow")
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            c.addSubview(tf)
            c.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 2),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -2),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()

        let coveragePct = String(format: "%.0f%%", summary.coverageFraction * 100)
        cell.textField?.stringValue = "\(summary.accession)  \(naoMgsFormatCount(summary.readCount)) reads  \(coveragePct)"
        cell.textField?.font = .monospacedSystemFont(ofSize: 10, weight: .regular)

        if summary.accession == selectedAccession {
            cell.textField?.textColor = .controlAccentColor
        } else {
            cell.textField?.textColor = .labelColor
        }

        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < summaries.count else { return }
        let accession = summaries[row].accession
        selectedAccession = accession
        onSelect?(accession)
    }

    func tableView(_ tableView: NSTableView, rowActionsForRow row: Int, edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
        []
    }
}
