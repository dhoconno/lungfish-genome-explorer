// NvdResultViewController.swift - NVD (Novel Virus Diagnostics) taxonomy browser
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import SwiftUI
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "NvdResultVC")

/// Formats a count with K/M suffixes for the outline view columns.
private func nvdFormatCount(_ count: Int) -> String {
    if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
    if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
    return "\(count)"
}

// MARK: - NvdOutlineItem

/// Items displayed in the NSOutlineView.
///
/// Lightweight enum for Hashable identity; actual data is stored in lookup dictionaries.
enum NvdOutlineItem: Hashable {
    /// Best-hit contig row (expandable if secondary hits exist).
    case contig(sampleId: String, qseqid: String)

    /// A secondary BLAST hit under a contig.
    case childHit(sampleId: String, qseqid: String, hitRank: Int)

    /// Taxon grouping header (byTaxon mode).
    case taxonGroup(name: String)
}

// MARK: - FlippedNvdContentView

/// Flipped container so Auto Layout `topAnchor` maps to visual top.
private final class FlippedNvdContentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - NvdDetailContainer

/// A self-contained detail pane container that manages a scroll view filling its bounds.
///
/// Added directly as an NSSplitView arranged subview. NSSplitView manages its
/// frame via frame-based layout; the container fills itself with the scroll view
/// using autoresizing masks.
private final class NvdDetailContainer: NSView {

    let scrollView: NSScrollView
    let contentView: FlippedNvdContentView

    init(scrollView: NSScrollView, contentView: FlippedNvdContentView) {
        self.scrollView = scrollView
        self.contentView = contentView
        super.init(frame: .zero)

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.documentView = contentView
        scrollView.autoresizingMask = [.width, .height]

        // Ensure the content view fills at least the visible area so
        // subviews pinned to its bottom edge use the full height.
        contentView.translatesAutoresizingMaskIntoConstraints = false
        let minHeight = contentView.heightAnchor.constraint(
            greaterThanOrEqualTo: scrollView.contentView.heightAnchor
        )
        minHeight.priority = .defaultHigh
        minHeight.isActive = true

        // Width tracks the clip view
        contentView.widthAnchor.constraint(
            equalTo: scrollView.contentView.widthAnchor
        ).isActive = true

        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        scrollView.frame = bounds
    }
}

// MARK: - NvdResultViewController

/// A full-screen NVD (Novel Virus Diagnostics) BLAST result browser.
///
/// `NvdResultViewController` is the primary UI for displaying imported NVD
/// pipeline results. It uses a hierarchical NSOutlineView where contigs are
/// expandable to show their secondary BLAST hits.
///
/// ## Layout
///
/// ```
/// +----------------------------------------------------------+
/// | Summary Bar (48pt)                                        |
/// |   Experiment: 32149 | Samples: 27 | Contigs: 28,461      |
/// +----------------------------------------------------------+
/// | Detail Pane (40%)    |  NSOutlineView (60%)               |
/// |  [Summary info]      |  Search: [________________]        |
/// |  [MiniBAM viewer]    |  > NODE_1183 (227bp) ...           |
/// +----------------------------------------------------------+
/// | Action Bar (36pt)  [BLAST Verify] [Export]                |
/// +----------------------------------------------------------+
/// ```
///
/// ## Thread Safety
///
/// This class is `@MainActor` isolated and uses raw `NSSplitView` (not
/// `NSSplitViewController`) per macOS 26 deprecated API rules.
@MainActor
public final class NvdResultViewController: NSViewController, NSSplitViewDelegate,
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSPopoverDelegate
{

    // MARK: - Data

    /// SQLite database for BLAST hits and sample metadata.
    private var database: NvdDatabase?

    /// Bundle manifest metadata.
    private var manifest: NvdManifest?

    /// URL of the NVD bundle directory.
    private var bundleURL: URL?

    /// All samples from the database.
    private var allSamples: [NvdSampleMetadata] = []

    /// Currently selected sample IDs for filtering.
    private var selectedSamples: Set<String> = []

    // MARK: - Displayed Data

    /// Best hits (hit_rank=1) for currently selected samples.
    private var displayedContigs: [NvdBlastHit] = []

    /// Cache of child hits per contig. Key: "sampleId\tqseqid".
    private var childHitsCache: [String: [NvdBlastHit]] = [:]

    /// Taxon groups for byTaxon grouping mode.
    private var taxonGroups: [NvdTaxonGroup] = []

    /// Contigs under each taxon group. Key: taxon name.
    private var taxonContigs: [String: [NvdBlastHit]] = [:]

    /// Cached contig rows from the manifest (used before database is available).
    private var cachedRows: [NvdContigRow] = []

    // MARK: - Grouping Mode

    /// How the outline view organizes its data.
    public enum GroupingMode: Int {
        case bySample = 0  // Flat contig list
        case byTaxon = 1   // Taxon -> Contig -> Hit hierarchy
    }

    /// Current grouping mode.
    public var groupingMode: GroupingMode = .bySample

    // MARK: - Sample Picker

    /// Sample entries for the picker view.
    public var sampleEntries: [NvdSampleEntry] = []

    /// NVD sample entry for the unified picker.
    public struct NvdSampleEntry: ClassifierSampleEntry {
        public let id: String
        public let displayName: String
        public let contigCount: Int
        public let hitCount: Int

        public var metricLabel: String { "Contigs / Hits" }
        public var metricValue: String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            let c = formatter.string(from: NSNumber(value: contigCount)) ?? "\(contigCount)"
            let h = formatter.string(from: NSNumber(value: hitCount)) ?? "\(hitCount)"
            return "\(c) / \(h)"
        }
        public var secondaryMetric: String? { metricValue }

        public init(id: String, displayName: String, contigCount: Int, hitCount: Int) {
            self.id = id
            self.displayName = displayName
            self.contigCount = contigCount
            self.hitCount = hitCount
        }
    }

    /// Common prefix stripped from sample display names.
    public var strippedPrefix: String = ""

    /// Observable state shared with the SwiftUI sample picker popover and Inspector.
    public var samplePickerState: ClassifierSamplePickerState!

    // MARK: - Callbacks

    /// Called when the user confirms BLAST verification for a contig.
    /// Parameters: (selected hit, contig FASTA sequence).
    public var onBlastVerification: ((NvdBlastHit, String) -> Void)?

    /// Called when the user wants to export results.
    public var onExport: (() -> Void)?

    // MARK: - UI Components

    private let summaryBar = NvdSummaryBar()
    let splitView = NSSplitView()
    private let outlineScrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let searchField = NSSearchField()
    private let detailScrollView = NSScrollView()
    private let detailContentView = FlippedNvdContentView()
    let actionBar = ClassifierActionBar()
    private let groupingSegment = NSSegmentedControl(labels: ["By Sample", "By Taxon"], trackingMode: .selectOne, target: nil, action: nil)

    // MARK: - MiniBAM

    private var miniBAMController: MiniBAMViewController?
    private var miniBAMHeightConstraint: NSLayoutConstraint?
    private let miniBAMDefaultHeight: CGFloat = 220
    private let miniBAMMinHeight: CGFloat = 140
    private let miniBAMMaxHeight: CGFloat = 900

    // MARK: - Loading State

    private let loadingOverlay = NSView()
    private let loadingSpinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "Loading\u{2026}")

    // MARK: - Search

    private var searchQuery: String = ""
    private var filterWorkItem: DispatchWorkItem?

    // MARK: - Split View State

    private var detailContainer: NvdDetailContainer?
    private var outlineContainer: NSView?
    private var didSetInitialSplitPosition = false
    private var splitViewBottomConstraint: NSLayoutConstraint?

    // MARK: - Selection Sync

    private var suppressSelectionSync = false

    // MARK: - Sample Popover

    private let sampleFilterButton = NSButton(title: "All Samples", target: nil, action: nil)
    private var samplePopover: NSPopover?

    // MARK: - BLAST Drawer

    private var blastDrawerView: BlastResultsDrawerTab?
    private var blastDrawerBottomConstraint: NSLayoutConstraint?
    private var isBlastDrawerOpen = false

    // MARK: - Lifecycle

    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view = container

        setupSummaryBar()
        setupSplitView()
        setupActionBar()
        setupLoadingOverlay()
        layoutSubviews()
        wireCallbacks()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        applySplitPositionIfNeeded(force: false)
    }

    // MARK: - Public API: Two-Phase Loading

    /// Phase 1: Configure with cached rows from manifest (instant display).
    ///
    /// Shows the contig list immediately from cached data in manifest.json.
    /// The database is not yet available — detail pane and search are disabled
    /// until `configure(database:manifest:bundleURL:)` is called.
    public func configureWithCachedRows(_ rows: [NvdContigRow], manifest: NvdManifest, bundleURL: URL) {
        self.manifest = manifest
        self.bundleURL = bundleURL
        self.cachedRows = rows

        // Convert cached rows to displayedContigs-compatible NvdBlastHit list
        displayedContigs = rows.map { row in
            NvdBlastHit(
                experiment: manifest.experiment,
                blastTask: "",
                sampleId: row.sampleId,
                qseqid: row.qseqid,
                qlen: row.qlen,
                sseqid: row.sseqid,
                stitle: row.stitle,
                taxRank: "",
                length: 0,
                pident: row.pident,
                evalue: row.evalue,
                bitscore: row.bitscore,
                sscinames: row.adjustedTaxidName,
                staxids: "",
                blastDbVersion: "",
                snakemakeRunId: "",
                mappedReads: row.mappedReads,
                totalReads: 0,
                statDbVersion: "",
                adjustedTaxid: "",
                adjustmentMethod: "",
                adjustedTaxidName: row.adjustedTaxidName,
                adjustedTaxidRank: row.adjustedTaxidRank,
                hitRank: 1,
                readsPerBillion: row.readsPerBillion
            )
        }

        outlineView.reloadData()

        // Update summary bar with cached counts
        summaryBar.update(
            experiment: manifest.experiment,
            sampleCount: manifest.sampleCount,
            contigCount: manifest.contigCount,
            hitCount: manifest.hitCount
        )

        showLoadingOverlay("Opening database\u{2026}")
        applySplitPositionIfNeeded(force: true)
        logger.info("Configured with \(rows.count) cached contig rows from manifest")
    }

    /// Phase 2: Full configure with SQLite database.
    public func configure(database: NvdDatabase, manifest: NvdManifest, bundleURL: URL) {
        showLoadingOverlay("Loading contig data\u{2026}")

        self.database = database
        self.manifest = manifest
        self.bundleURL = bundleURL

        // Fetch samples from database
        do {
            allSamples = try database.allSamples()
        } catch {
            logger.error("Failed to fetch samples: \(error.localizedDescription, privacy: .public)")
            allSamples = []
        }

        // Compute common prefix for display names
        let sampleNames = allSamples.map(\.sampleId)
        strippedPrefix = NvdDataConverter.commonPrefix(of: sampleNames)

        // Create sample entries with stripped display names
        sampleEntries = allSamples.map { sample in
            let displayName = strippedPrefix.isEmpty
                ? sample.sampleId
                : String(sample.sampleId.dropFirst(strippedPrefix.count))
            return NvdSampleEntry(
                id: sample.sampleId,
                displayName: displayName,
                contigCount: sample.contigCount,
                hitCount: sample.hitCount
            )
        }

        // Select all samples initially
        selectedSamples = Set(sampleNames)
        samplePickerState = ClassifierSamplePickerState(allSamples: selectedSamples)

        // Update summary bar
        summaryBar.update(
            experiment: manifest.experiment,
            sampleCount: allSamples.count,
            contigCount: manifest.contigCount,
            hitCount: manifest.hitCount
        )

        // Reload the outline view with full database data
        reloadOutlineData()

        // Auto-select first contig
        if !displayedContigs.isEmpty {
            selectContigByIndex(0)
        } else {
            showOverview()
        }

        // Update sample button and split position
        updateSampleFilterButtonTitle()
        applySplitPositionIfNeeded(force: true)

        hideLoadingOverlay()
        logger.info("Configured NVD viewer with database, \(self.allSamples.count) samples")
    }

    // MARK: - Data Reload

    private func reloadOutlineData() {
        guard let database else {
            displayedContigs = []
            taxonGroups = []
            taxonContigs = [:]
            outlineView.reloadData()
            return
        }

        let samples = Array(selectedSamples)

        do {
            if searchQuery.isEmpty {
                displayedContigs = try database.bestHits(forSamples: samples)
            } else {
                displayedContigs = try database.searchBestHits(query: searchQuery, samples: samples)
            }
        } catch {
            logger.error("Failed to fetch contigs: \(error.localizedDescription, privacy: .public)")
            displayedContigs = []
        }

        // Clear child hits cache — will be lazily reloaded
        childHitsCache.removeAll()

        // Load taxon groups if in byTaxon mode
        if groupingMode == .byTaxon {
            do {
                var allGroups = try database.taxonGroups(forSamples: samples)
                // Build taxon -> contigs mapping from filtered contigs
                taxonContigs.removeAll()
                for contig in displayedContigs {
                    taxonContigs[contig.adjustedTaxidName, default: []].append(contig)
                }
                // Filter taxon groups to only include those with matching contigs
                if !searchQuery.isEmpty {
                    allGroups = allGroups.filter { taxonContigs[$0.adjustedTaxidName] != nil }
                }
                taxonGroups = allGroups
            } catch {
                logger.error("Failed to fetch taxon groups: \(error.localizedDescription, privacy: .public)")
                taxonGroups = []
                taxonContigs = [:]
            }
        }

        outlineView.reloadData()
    }

    // MARK: - Selection

    private func selectContigByIndex(_ index: Int) {
        guard index < displayedContigs.count else { return }

        let contig = displayedContigs[index]
        let item = NvdOutlineItem.contig(sampleId: contig.sampleId, qseqid: contig.qseqid)
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }

        suppressSelectionSync = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        suppressSelectionSync = false

        showContigDetail(contig)
    }

    // MARK: - Detail Pane Content

    private func showOverview() {
        teardownMiniBAM()

        for subview in detailContentView.subviews {
            subview.removeFromSuperview()
        }
        detailContentView.removeConstraints(detailContentView.constraints)

        let titleLabel = NSTextField(labelWithString: "NVD Results Overview")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailContentView.addSubview(titleLabel)

        let experiment = manifest?.experiment ?? "Unknown"
        let subtitleLabel = NSTextField(labelWithString: "Experiment \(experiment). Select a contig in the outline to view alignments.")
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailContentView.addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: detailContentView.topAnchor, constant: 16),
            titleLabel.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor, constant: -16),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor, constant: -16),
        ])

        actionBar.updateInfoText("Select a contig to view details")
        actionBar.setBlastEnabled(false)
        resizeDetailContentToFit()
    }

    private func showContigDetail(_ hit: NvdBlastHit) {
        teardownMiniBAM()

        for subview in detailContentView.subviews {
            subview.removeFromSuperview()
        }
        detailContentView.removeConstraints(detailContentView.constraints)

        buildContigDetailContent(hit)
        updateActionBarForHit(hit)

        DispatchQueue.main.async { [weak self] in
            self?.resizeDetailContentToFit()
        }
    }

    private func buildContigDetailContent(_ hit: NvdBlastHit) {
        // Contig name header
        let displayName = NvdDataConverter.displayName(for: hit.qseqid, qlen: hit.qlen)
        let nameLabel = NSTextField(labelWithString: displayName)
        nameLabel.font = .systemFont(ofSize: 14, weight: .bold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        detailContentView.addSubview(nameLabel)

        // Classification subtitle
        let classificationText = hit.adjustedTaxidName.isEmpty
            ? "Unclassified"
            : "\(hit.adjustedTaxidName) (\(hit.adjustedTaxidRank))"
        let subtitleLabel = NSTextField(
            labelWithString: "Sample: \(hit.sampleId)  \u{2022}  \(classificationText)"
        )
        subtitleLabel.font = .systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailContentView.addSubview(subtitleLabel)

        // Metrics row
        let metricsView = buildMetricsView(for: hit)
        detailContentView.addSubview(metricsView)

        // MiniBAM panel (if BAM file available)
        let miniBAMContainer = buildMiniBAMPanel(for: hit)
        detailContentView.addSubview(miniBAMContainer)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: detailContentView.topAnchor, constant: 12),
            nameLabel.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor, constant: 16),
            nameLabel.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor, constant: -16),

            subtitleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            subtitleLabel.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor, constant: 16),
            subtitleLabel.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor, constant: -16),

            metricsView.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
            metricsView.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor, constant: 16),
            metricsView.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor, constant: -16),

            miniBAMContainer.topAnchor.constraint(equalTo: metricsView.bottomAnchor, constant: 12),
            miniBAMContainer.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor, constant: 8),
            miniBAMContainer.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor, constant: -8),
        ])

        // Pin miniBAM container to bottom of detail pane so it fills available vertical space
        let bottomConstraint = miniBAMContainer.bottomAnchor.constraint(
            equalTo: detailContentView.bottomAnchor, constant: -8
        )
        bottomConstraint.priority = .required - 1
        bottomConstraint.isActive = true
    }

    private func buildMetricsView(for hit: NvdBlastHit) -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .top
        container.distribution = .fillEqually
        container.spacing = 8
        container.translatesAutoresizingMaskIntoConstraints = false

        let metrics: [(String, String)] = [
            ("Identity", String(format: "%.1f%%", hit.pident)),
            ("E-value", formatEvalue(hit.evalue)),
            ("Bit Score", String(format: "%.0f", hit.bitscore)),
            ("Mapped Reads", nvdFormatCount(hit.mappedReads)),
            ("RPB", String(format: "%.0f", hit.readsPerBillion)),
            ("Length", nvdFormatCount(hit.qlen)),
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

    private func formatEvalue(_ evalue: Double) -> String {
        if evalue == 0.0 { return "0" }
        if evalue < 1e-100 { return String(format: "%.0e", evalue) }
        if evalue < 0.01 { return String(format: "%.1e", evalue) }
        return String(format: "%.2g", evalue)
    }

    // MARK: - MiniBAM Panel

    private func buildMiniBAMPanel(for hit: NvdBlastHit) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        guard let database, let bundleURL else {
            let label = NSTextField(labelWithString: "No BAM data available.")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: container.topAnchor),
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                label.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            return container
        }

        // Header
        let headerLabel = NSTextField(labelWithString: "Contig Alignment")
        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerLabel)

        // Accession info
        let accessionLabel = NSTextField(
            labelWithString: "Best hit: \(hit.sseqid) \u{2014} \(hit.stitle)"
        )
        accessionLabel.font = .systemFont(ofSize: 10)
        accessionLabel.textColor = .secondaryLabelColor
        accessionLabel.lineBreakMode = .byTruncatingTail
        accessionLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(accessionLabel)

        // Create MiniBAM
        let miniBAM = MiniBAMViewController()
        miniBAM.subjectNoun = "contig"
        miniBAM.showsPCRDuplicates = false
        miniBAM.keyboardShortcutsEnabled = true
        addChild(miniBAM)
        miniBAMController = miniBAM

        let bamView = miniBAM.view
        bamView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(bamView)

        // Use a minimum height but allow the view to grow to fill available space
        let heightConstraint = bamView.heightAnchor.constraint(greaterThanOrEqualToConstant: miniBAMMinHeight)
        miniBAMHeightConstraint = nil  // No fixed height — fills available space

        miniBAM.onResizeBy = { [weak self] deltaY in
            self?.adjustMiniBAMHeight(by: deltaY)
        }

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            headerLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            accessionLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 2),
            accessionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            accessionLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            bamView.topAnchor.constraint(equalTo: accessionLabel.bottomAnchor, constant: 6),
            bamView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            bamView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            bamView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            heightConstraint,
        ])

        // Load BAM asynchronously
        loadMiniBAM(miniBAM: miniBAM, hit: hit, database: database, bundleURL: bundleURL)

        return container
    }

    private func loadMiniBAM(miniBAM: MiniBAMViewController, hit: NvdBlastHit, database: NvdDatabase, bundleURL: URL) {
        // Get BAM path from database
        do {
            guard let bamRelPath = try database.bamPath(forSample: hit.sampleId) else {
                logger.warning("No BAM path found for sample \(hit.sampleId, privacy: .public)")
                return
            }
            let bamURL = bundleURL.appendingPathComponent(bamRelPath)
            guard FileManager.default.fileExists(atPath: bamURL.path) else {
                logger.warning("BAM file not found: \(bamURL.path, privacy: .public)")
                return
            }

            // The contig name IS the reference name in the BAM
            miniBAM.displayContig(
                bamURL: bamURL,
                contig: hit.qseqid,
                contigLength: max(hit.qlen, 1)
            )
        } catch {
            logger.error("Failed to get BAM path: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func adjustMiniBAMHeight(by deltaY: CGFloat) {
        guard let constraint = miniBAMHeightConstraint else { return }
        let next = min(max(miniBAMMinHeight, constraint.constant + deltaY), miniBAMMaxHeight)
        constraint.constant = next
        detailContentView.layoutSubtreeIfNeeded()
    }

    private func teardownMiniBAM() {
        if let controller = miniBAMController {
            controller.view.removeFromSuperview()
            controller.removeFromParent()
            miniBAMController = nil
        }
        miniBAMHeightConstraint = nil
    }

    // MARK: - Detail Content Sizing

    private func resizeDetailContentToFit() {
        let clipWidth = detailScrollView.contentView.bounds.width
        guard clipWidth > 0 else { return }

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

    // MARK: - Loading Overlay

    private func setupLoadingOverlay() {
        loadingOverlay.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.isHidden = true

        let backing = NSVisualEffectView()
        backing.material = .hudWindow
        backing.blendingMode = .withinWindow
        backing.state = .active
        backing.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(backing)

        loadingSpinner.style = .spinning
        loadingSpinner.controlSize = .regular
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(loadingSpinner)

        loadingLabel.font = .systemFont(ofSize: 12, weight: .medium)
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.alignment = .center
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        loadingOverlay.addSubview(loadingLabel)

        view.addSubview(loadingOverlay)

        NSLayoutConstraint.activate([
            backing.topAnchor.constraint(equalTo: loadingOverlay.topAnchor),
            backing.leadingAnchor.constraint(equalTo: loadingOverlay.leadingAnchor),
            backing.trailingAnchor.constraint(equalTo: loadingOverlay.trailingAnchor),
            backing.bottomAnchor.constraint(equalTo: loadingOverlay.bottomAnchor),

            loadingOverlay.topAnchor.constraint(equalTo: splitView.topAnchor),
            loadingOverlay.leadingAnchor.constraint(equalTo: splitView.leadingAnchor),
            loadingOverlay.trailingAnchor.constraint(equalTo: splitView.trailingAnchor),
            loadingOverlay.bottomAnchor.constraint(equalTo: splitView.bottomAnchor),

            loadingSpinner.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            loadingSpinner.centerYAnchor.constraint(equalTo: loadingOverlay.centerYAnchor, constant: -12),

            loadingLabel.topAnchor.constraint(equalTo: loadingSpinner.bottomAnchor, constant: 8),
            loadingLabel.centerXAnchor.constraint(equalTo: loadingOverlay.centerXAnchor),
            loadingLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
        ])
    }

    private func showLoadingOverlay(_ message: String) {
        loadingLabel.stringValue = message
        loadingOverlay.isHidden = false
        loadingSpinner.startAnimation(nil)
    }

    private func hideLoadingOverlay() {
        loadingSpinner.stopAnimation(nil)
        loadingOverlay.isHidden = true
    }

    // MARK: - Setup: Summary Bar

    private func setupSummaryBar() {
        summaryBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(summaryBar)
    }

    // MARK: - Setup: Split View

    /// Configures the NSSplitView with detail pane (left) and outline view (right).
    ///
    /// Uses raw NSSplitView (not NSSplitViewController) per macOS 26 rules.
    private func setupSplitView() {
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self

        // Left pane: detail
        let detail = NvdDetailContainer(scrollView: detailScrollView, contentView: detailContentView)
        detailContainer = detail

        // Right pane: outline view with search bar
        let outlineCont = NSView()
        self.outlineContainer = outlineCont
        setupOutlineView()
        setupFilterBar(in: outlineCont)

        splitView.addArrangedSubview(detail)
        splitView.addArrangedSubview(outlineCont)

        // Outline pane resizes first; detail pane holds width firmly.
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        splitView.adjustSubviews()
        view.addSubview(splitView)

        applyLayoutPreference()
    }

    private func setupOutlineView() {
        outlineView.headerView = NSTableHeaderView()
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = false
        outlineView.allowsColumnReordering = true
        outlineView.allowsColumnResizing = true
        outlineView.style = .inset
        outlineView.intercellSpacing = NSSize(width: 8, height: 2)
        outlineView.rowHeight = 22
        outlineView.autoresizesOutlineColumn = false

        // Columns — Sample first, then Contig (which is the outline column with disclosure triangles)
        let sampleCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sampleId"))
        sampleCol.title = "Sample"
        sampleCol.width = 140
        sampleCol.minWidth = 80
        outlineView.addTableColumn(sampleCol)

        let contigCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("contig"))
        contigCol.title = "Contig"
        contigCol.width = 160
        contigCol.minWidth = 100
        outlineView.addTableColumn(contigCol)
        outlineView.outlineTableColumn = contigCol

        let lengthCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("length"))
        lengthCol.title = "Length"
        lengthCol.width = 64
        lengthCol.minWidth = 48
        outlineView.addTableColumn(lengthCol)

        let classCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("classification"))
        classCol.title = "Classification"
        classCol.width = 160
        classCol.minWidth = 100
        outlineView.addTableColumn(classCol)

        let rankCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rank"))
        rankCol.title = "Rank"
        rankCol.width = 70
        rankCol.minWidth = 50
        outlineView.addTableColumn(rankCol)

        let accessionCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("accession"))
        accessionCol.title = "Accession"
        accessionCol.width = 110
        accessionCol.minWidth = 70
        outlineView.addTableColumn(accessionCol)

        let subjectCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("subject"))
        subjectCol.title = "Subject"
        subjectCol.width = 180
        subjectCol.minWidth = 80
        outlineView.addTableColumn(subjectCol)

        let pidentCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pident"))
        pidentCol.title = "Identity %"
        pidentCol.width = 70
        pidentCol.minWidth = 50
        outlineView.addTableColumn(pidentCol)

        let evalueCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("evalue"))
        evalueCol.title = "E-value"
        evalueCol.width = 70
        evalueCol.minWidth = 50
        outlineView.addTableColumn(evalueCol)

        let bitscoreCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("bitscore"))
        bitscoreCol.title = "Bit Score"
        bitscoreCol.width = 70
        bitscoreCol.minWidth = 50
        outlineView.addTableColumn(bitscoreCol)

        let mappedCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("mappedReads"))
        mappedCol.title = "Mapped Reads"
        mappedCol.width = 90
        mappedCol.minWidth = 60
        outlineView.addTableColumn(mappedCol)

        let rpbCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("readsPerBillion"))
        rpbCol.title = "RPB"
        rpbCol.width = 70
        rpbCol.minWidth = 50
        outlineView.addTableColumn(rpbCol)

        let coverageCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("coverage"))
        coverageCol.title = "Aln Length"
        coverageCol.width = 70
        coverageCol.minWidth = 50
        outlineView.addTableColumn(coverageCol)

        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.menu = buildContextMenu()

        // Scroll view setup
        outlineScrollView.documentView = outlineView
        outlineScrollView.hasVerticalScroller = true
        outlineScrollView.hasHorizontalScroller = true
        outlineScrollView.autohidesScrollers = true
        outlineScrollView.drawsBackground = true

        outlineView.setAccessibilityLabel("NVD Contig Outline")
    }

    private func setupFilterBar(in container: NSView) {
        container.translatesAutoresizingMaskIntoConstraints = false

        let filterBar = NSStackView()
        filterBar.translatesAutoresizingMaskIntoConstraints = false
        filterBar.orientation = .horizontal
        filterBar.alignment = .centerY
        filterBar.spacing = 6
        container.addSubview(filterBar)

        // Sample filter button
        sampleFilterButton.translatesAutoresizingMaskIntoConstraints = false
        sampleFilterButton.bezelStyle = .push
        sampleFilterButton.controlSize = .small
        sampleFilterButton.font = .systemFont(ofSize: 11)
        sampleFilterButton.target = self
        sampleFilterButton.action = #selector(sampleFilterButtonClicked(_:))
        sampleFilterButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        filterBar.addArrangedSubview(sampleFilterButton)

        // Grouping mode selector
        groupingSegment.translatesAutoresizingMaskIntoConstraints = false
        groupingSegment.controlSize = .small
        groupingSegment.font = .systemFont(ofSize: 11)
        groupingSegment.selectedSegment = 0
        groupingSegment.target = self
        groupingSegment.action = #selector(groupingModeChanged(_:))
        filterBar.addArrangedSubview(groupingSegment)

        // Search field
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search contigs\u{2026}"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction(_:))
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        filterBar.addArrangedSubview(searchField)

        outlineScrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(outlineScrollView)

        NSLayoutConstraint.activate([
            filterBar.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            filterBar.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
            filterBar.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -6),

            outlineScrollView.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 6),
            outlineScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            outlineScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            outlineScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
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
        ])

        let bottomConstraint = splitView.bottomAnchor.constraint(equalTo: actionBar.topAnchor)
        bottomConstraint.isActive = true
        splitViewBottomConstraint = bottomConstraint
    }

    private func applySplitPositionIfNeeded(force: Bool) {
        guard splitView.arrangedSubviews.count >= 2 else { return }
        guard splitView.bounds.width > 0 else {
            if force { didSetInitialSplitPosition = false }
            return
        }

        guard force || !didSetInitialSplitPosition else { return }

        // Detail pane on left gets 40%, outline on right gets 60%.
        let position = round(splitView.bounds.width * 0.4)
        splitView.setPosition(position, ofDividerAt: 0)
        didSetInitialSplitPosition = true
        resizeDetailContentToFit()
    }

    // MARK: - Callback Wiring

    private func wireCallbacks() {
        actionBar.onBlastVerify = { [weak self] in
            self?.blastVerifySelectedContig()
        }

        actionBar.onExport = { [weak self] in
            self?.exportResults()
        }

        actionBar.onProvenance = { [weak self] sender in
            self?.showProvenance(from: sender)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLayoutSwapRequested),
            name: .metagenomicsLayoutSwapRequested,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInspectorSampleSelectionChanged),
            name: .metagenomicsSampleSelectionChanged,
            object: nil
        )
    }

    @objc private func handleLayoutSwapRequested(_ notification: Notification) {
        applyLayoutPreference()
    }

    @objc private func handleInspectorSampleSelectionChanged(_ notification: Notification) {
        let newSelection = samplePickerState.selectedSamples
        guard newSelection != selectedSamples else { return }
        selectedSamples = newSelection
        updateSampleFilterButtonTitle()
        reloadOutlineData()
        summaryBar.update(
            experiment: manifest?.experiment ?? "",
            sampleCount: allSamples.count,
            contigCount: displayedContigs.count,
            hitCount: (try? database?.totalHitCount(samples: Array(newSelection))) ?? 0
        )
    }

    private func applyLayoutPreference() {
        let tableOnLeft = UserDefaults.standard.bool(forKey: "metagenomicsTableOnLeft")
        guard splitView.arrangedSubviews.count == 2,
              let detail = detailContainer,
              let outline = outlineContainer else { return }

        let currentOutlineIsFirst = (splitView.arrangedSubviews[0] === outline)
        guard tableOnLeft != currentOutlineIsFirst else { return }

        let totalWidth = max(splitView.bounds.width, 1)
        let leftRatio = splitView.arrangedSubviews[0].frame.width / totalWidth

        splitView.removeArrangedSubview(detail)
        splitView.removeArrangedSubview(outline)
        detail.removeFromSuperview()
        outline.removeFromSuperview()

        if tableOnLeft {
            splitView.addArrangedSubview(outline)
            splitView.addArrangedSubview(detail)
        } else {
            splitView.addArrangedSubview(detail)
            splitView.addArrangedSubview(outline)
        }

        let outlineIndex = tableOnLeft ? 0 : 1
        let detailIndex = tableOnLeft ? 1 : 0
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: outlineIndex)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: detailIndex)

        let newPosition = round(totalWidth * (1.0 - leftRatio))
        splitView.setPosition(newPosition, ofDividerAt: 0)
        splitView.adjustSubviews()
    }

    // MARK: - Sample Filter

    private func updateSampleFilterButtonTitle() {
        let total = allSamples.count
        let selected = selectedSamples.count
        if selected == total {
            sampleFilterButton.title = "All Samples"
        } else {
            sampleFilterButton.title = "\(selected) of \(total) Samples"
        }
    }

    @objc private func sampleFilterButtonClicked(_ sender: NSButton) {
        if let existing = samplePopover, existing.isShown {
            existing.close()
            samplePopover = nil
            return
        }

        samplePickerState.selectedSamples = selectedSamples

        let pickerView = ClassifierSamplePickerView(
            samples: sampleEntries,
            pickerState: samplePickerState,
            strippedPrefix: strippedPrefix,
            isInline: false
        )

        let hostingController = NSHostingController(rootView: pickerView)
        let popover = NSPopover()
        popover.contentViewController = hostingController
        popover.behavior = .transient
        popover.delegate = self
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        samplePopover = popover
    }

    // MARK: - NSPopoverDelegate

    public func popoverDidClose(_ notification: Notification) {
        let newSelection = samplePickerState.selectedSamples
        guard newSelection != selectedSamples else { return }

        selectedSamples = newSelection
        updateSampleFilterButtonTitle()
        reloadOutlineData()
        summaryBar.update(
            experiment: manifest?.experiment ?? "",
            sampleCount: allSamples.count,
            contigCount: displayedContigs.count,
            hitCount: (try? database?.totalHitCount(samples: Array(newSelection))) ?? 0
        )
        samplePopover = nil
    }

    // MARK: - Search

    @objc private func searchFieldAction(_ sender: NSSearchField) {
        let newQuery = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard newQuery != searchQuery else { return }
        searchQuery = newQuery
        reloadOutlineData()
    }

    // MARK: - Grouping Mode

    @objc private func groupingModeChanged(_ sender: NSSegmentedControl) {
        groupingMode = GroupingMode(rawValue: sender.selectedSegment) ?? .bySample
        reloadOutlineData()
    }

    // MARK: - NSSplitViewDelegate

    /// Constrains minimum left pane width. Uses raw NSSplitView delegate
    /// (not NSSplitViewController) — safe per macOS 26 rules.
    public func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        max(proposedMinimumPosition, 250)
    }

    public func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.width - 300)
    }

    // MARK: - BLAST Verification

    private func blastVerifySelectedContig() {
        let selectedRow = outlineView.selectedRow
        guard selectedRow >= 0 else { return }
        guard let item = outlineView.item(atRow: selectedRow) as? NvdOutlineItem else { return }

        let hit: NvdBlastHit?
        switch item {
        case .contig(let sampleId, let qseqid):
            hit = displayedContigs.first { $0.sampleId == sampleId && $0.qseqid == qseqid }
        case .childHit(let sampleId, let qseqid, let hitRank):
            let key = "\(sampleId)\t\(qseqid)"
            hit = childHitsCache[key]?.first { $0.hitRank == hitRank }
        case .taxonGroup:
            hit = nil
        }

        guard let hit, let bundleURL, let database else { return }

        // Extract contig FASTA sequence
        do {
            guard let fastaRelPath = try database.fastaPath(forSample: hit.sampleId) else {
                logger.warning("No FASTA path for sample \(hit.sampleId, privacy: .public)")
                return
            }
            let fastaURL = bundleURL.appendingPathComponent(fastaRelPath)
            guard let sequence = NvdDataConverter.extractContigSequence(from: fastaURL, contigName: hit.qseqid) else {
                logger.warning("Could not extract contig \(hit.qseqid, privacy: .public) from FASTA")
                return
            }
            onBlastVerification?(hit, sequence)
        } catch {
            logger.error("BLAST verify failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - BLAST Drawer

    public func showBlastLoading(phase: BlastJobPhase, requestId: String?) {
        let drawer = ensureBlastDrawer()
        drawer.showLoading(phase: phase, requestId: requestId)
        openBlastDrawerIfNeeded()
    }

    public func showBlastResults(_ result: BlastVerificationResult) {
        let drawer = ensureBlastDrawer()
        drawer.showResults(result)
        openBlastDrawerIfNeeded()
    }

    public func showBlastFailure(_ message: String) {
        let drawer = ensureBlastDrawer()
        drawer.showFailure(message: message)
        openBlastDrawerIfNeeded()
    }

    private func ensureBlastDrawer() -> BlastResultsDrawerTab {
        if let blastDrawerView { return blastDrawerView }

        let drawer = BlastResultsDrawerTab()
        drawer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(drawer)

        let bottomConstraint = drawer.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: 220)

        NSLayoutConstraint.activate([
            drawer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            drawer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            drawer.heightAnchor.constraint(equalToConstant: 220),
            bottomConstraint,
        ])

        splitViewBottomConstraint?.isActive = false
        let newSplitBottom = splitView.bottomAnchor.constraint(equalTo: drawer.topAnchor)
        newSplitBottom.isActive = true
        splitViewBottomConstraint = newSplitBottom

        blastDrawerView = drawer
        blastDrawerBottomConstraint = bottomConstraint
        view.layoutSubtreeIfNeeded()

        return drawer
    }

    private func openBlastDrawerIfNeeded() {
        guard !isBlastDrawerOpen else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            blastDrawerBottomConstraint?.animator().constant = 0
            view.layoutSubtreeIfNeeded()
        }
        isBlastDrawerOpen = true
    }

    // MARK: - Context Menu

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Contig Actions")
        menu.delegate = self
        return menu
    }

    private func populateContextMenu(_ menu: NSMenu, for hit: NvdBlastHit) {
        menu.removeAllItems()

        // BLAST Verify
        if onBlastVerification != nil, database != nil {
            let blastItem = NSMenuItem(
                title: "BLAST Verify Sequence",
                action: #selector(contextBlastVerify(_:)),
                keyEquivalent: ""
            )
            blastItem.target = self
            blastItem.representedObject = hit
            menu.addItem(blastItem)
            menu.addItem(NSMenuItem.separator())
        }

        // Copy Contig Name
        let copyContig = NSMenuItem(title: "Copy Contig Name", action: #selector(contextCopyContigName(_:)), keyEquivalent: "")
        copyContig.target = self
        copyContig.representedObject = hit.qseqid
        menu.addItem(copyContig)

        // Copy Accession
        if !hit.sseqid.isEmpty {
            let copyAcc = NSMenuItem(title: "Copy Accession", action: #selector(contextCopyAccession(_:)), keyEquivalent: "")
            copyAcc.target = self
            copyAcc.representedObject = hit.sseqid
            menu.addItem(copyAcc)
        }

        menu.addItem(NSMenuItem.separator())

        // View on NCBI
        if !hit.sseqid.isEmpty {
            let viewNCBI = NSMenuItem(title: "View Accession on NCBI", action: #selector(contextViewAccessionOnNCBI(_:)), keyEquivalent: "")
            viewNCBI.target = self
            viewNCBI.representedObject = hit.sseqid
            menu.addItem(viewNCBI)
        }

        if !hit.adjustedTaxidName.isEmpty {
            let searchPubMed = NSMenuItem(title: "Search PubMed", action: #selector(contextSearchPubMed(_:)), keyEquivalent: "")
            searchPubMed.target = self
            searchPubMed.representedObject = hit.adjustedTaxidName
            menu.addItem(searchPubMed)
        }
    }

    // MARK: - Context Menu Actions

    @objc private func contextBlastVerify(_ sender: NSMenuItem) {
        guard let hit = sender.representedObject as? NvdBlastHit,
              let bundleURL, let database else { return }

        do {
            guard let fastaRelPath = try database.fastaPath(forSample: hit.sampleId) else { return }
            let fastaURL = bundleURL.appendingPathComponent(fastaRelPath)
            guard let sequence = NvdDataConverter.extractContigSequence(from: fastaURL, contigName: hit.qseqid) else { return }
            onBlastVerification?(hit, sequence)
        } catch {
            logger.error("Context BLAST verify failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func contextCopyContigName(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(name, forType: .string)
    }

    @objc private func contextCopyAccession(_ sender: NSMenuItem) {
        guard let accession = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(accession, forType: .string)
    }

    @objc private func contextViewAccessionOnNCBI(_ sender: NSMenuItem) {
        guard let accession = sender.representedObject as? String else { return }
        if let url = URL(string: "https://www.ncbi.nlm.nih.gov/nuccore/\(accession)") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func contextSearchPubMed(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        let encodedName = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name
        if let url = URL(string: "https://pubmed.ncbi.nlm.nih.gov/?term=\(encodedName)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Action Bar Selection Helper

    /// Updates the unified action bar info text from a BLAST hit.
    private func updateActionBarForHit(_ hit: NvdBlastHit?) {
        if let hit {
            let displayName = NvdDataConverter.displayName(for: hit.qseqid, qlen: hit.qlen)
            let classification = hit.adjustedTaxidName.isEmpty ? "Unclassified" : hit.adjustedTaxidName
            actionBar.updateInfoText("\(displayName) \u{2014} \(classification)")
            actionBar.setBlastEnabled(true)
        } else {
            actionBar.updateInfoText("Select a contig to view details")
            actionBar.setBlastEnabled(false)
        }
    }

    // MARK: - Provenance Popover

    private func showProvenance(from button: NSButton) {
        guard let manifest else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 260)
        popover.contentViewController = NSHostingController(rootView: NvdProvenanceView(manifest: manifest))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    // MARK: - Export

    public func exportResults() {
        guard let window = view.window else { return }
        let experiment = manifest?.experiment ?? "nvd"

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.tabSeparatedText]
        savePanel.nameFieldStringValue = "\(experiment)_nvd_contigs.tsv"
        savePanel.title = "Export NVD Contigs"

        savePanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = savePanel.url, let self else { return }

            var lines: [String] = []
            lines.append("sample_id\tcontig\tlength\tclassification\trank\taccession\tsubject\tpident\tevalue\tbitscore\tmapped_reads\treads_per_billion")

            for hit in self.displayedContigs {
                lines.append("\(hit.sampleId)\t\(hit.qseqid)\t\(hit.qlen)\t\(hit.adjustedTaxidName)\t\(hit.adjustedTaxidRank)\t\(hit.sseqid)\t\(hit.stitle)\t\(String(format: "%.2f", hit.pident))\t\(hit.evalue)\t\(String(format: "%.1f", hit.bitscore))\t\(hit.mappedReads)\t\(String(format: "%.0f", hit.readsPerBillion))")
            }

            let content = lines.joined(separator: "\n") + "\n"
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                logger.info("Exported NVD contigs to \(url.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("Failed to export NVD contigs: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Child Hits (Lazy Loading)

    /// Returns child hits for a contig, loading from database on first access.
    private func childHitsForContig(sampleId: String, qseqid: String) -> [NvdBlastHit] {
        let key = "\(sampleId)\t\(qseqid)"
        if let cached = childHitsCache[key] {
            return cached
        }

        guard let database else { return [] }

        do {
            let children = try database.childHits(sampleId: sampleId, qseqid: qseqid)
            childHitsCache[key] = children
            return children
        } catch {
            logger.error("Failed to fetch child hits: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

// MARK: - NSOutlineViewDataSource

extension NvdResultViewController {

    public func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        switch groupingMode {
        case .bySample:
            if item == nil {
                return displayedContigs.count
            }
            if let outlineItem = item as? NvdOutlineItem,
               case .contig(let sampleId, let qseqid) = outlineItem {
                let children = childHitsForContig(sampleId: sampleId, qseqid: qseqid)
                // Show children only if there are secondary hits (more than 1 total)
                return children.count > 1 ? children.count : 0
            }
            return 0

        case .byTaxon:
            if item == nil {
                return taxonGroups.count
            }
            if let outlineItem = item as? NvdOutlineItem {
                switch outlineItem {
                case .taxonGroup(let name):
                    return taxonContigs[name]?.count ?? 0
                case .contig(let sampleId, let qseqid):
                    let children = childHitsForContig(sampleId: sampleId, qseqid: qseqid)
                    return children.count > 1 ? children.count : 0
                case .childHit:
                    return 0
                }
            }
            return 0
        }
    }

    public func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        switch groupingMode {
        case .bySample:
            if item == nil {
                let hit = displayedContigs[index]
                return NvdOutlineItem.contig(sampleId: hit.sampleId, qseqid: hit.qseqid)
            }
            if let outlineItem = item as? NvdOutlineItem,
               case .contig(let sampleId, let qseqid) = outlineItem {
                let children = childHitsForContig(sampleId: sampleId, qseqid: qseqid)
                let child = children[index]
                return NvdOutlineItem.childHit(sampleId: child.sampleId, qseqid: child.qseqid, hitRank: child.hitRank)
            }
            return NvdOutlineItem.contig(sampleId: "", qseqid: "")

        case .byTaxon:
            if item == nil {
                return NvdOutlineItem.taxonGroup(name: taxonGroups[index].adjustedTaxidName)
            }
            if let outlineItem = item as? NvdOutlineItem {
                switch outlineItem {
                case .taxonGroup(let name):
                    if let contigs = taxonContigs[name], index < contigs.count {
                        let hit = contigs[index]
                        return NvdOutlineItem.contig(sampleId: hit.sampleId, qseqid: hit.qseqid)
                    }
                case .contig(let sampleId, let qseqid):
                    let children = childHitsForContig(sampleId: sampleId, qseqid: qseqid)
                    if index < children.count {
                        let child = children[index]
                        return NvdOutlineItem.childHit(sampleId: child.sampleId, qseqid: child.qseqid, hitRank: child.hitRank)
                    }
                case .childHit:
                    break
                }
            }
            return NvdOutlineItem.contig(sampleId: "", qseqid: "")
        }
    }

    public func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let outlineItem = item as? NvdOutlineItem else { return false }
        switch outlineItem {
        case .contig(let sampleId, let qseqid):
            let children = childHitsForContig(sampleId: sampleId, qseqid: qseqid)
            return children.count > 1
        case .taxonGroup:
            return true
        case .childHit:
            return false
        }
    }
}

// MARK: - NSOutlineViewDelegate

extension NvdResultViewController {

    public func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let outlineItem = item as? NvdOutlineItem else { return nil }
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("default")

        let cellView = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeOutlineCellView(identifier: identifier)

        switch outlineItem {
        case .contig(let sampleId, let qseqid):
            guard let hit = displayedContigs.first(where: { $0.sampleId == sampleId && $0.qseqid == qseqid }) else {
                cellView.textField?.stringValue = ""
                return cellView
            }
            configureCell(cellView, column: identifier.rawValue, hit: hit, isChild: false)

        case .childHit(let sampleId, let qseqid, let hitRank):
            let key = "\(sampleId)\t\(qseqid)"
            if let children = childHitsCache[key],
               let child = children.first(where: { $0.hitRank == hitRank }) {
                configureCell(cellView, column: identifier.rawValue, hit: child, isChild: true)
            } else {
                cellView.textField?.stringValue = ""
            }

        case .taxonGroup(let name):
            if identifier.rawValue == "contig" {
                cellView.textField?.stringValue = name.isEmpty ? "Unclassified" : name
                cellView.textField?.font = .systemFont(ofSize: 11, weight: .semibold)
                cellView.textField?.alignment = .left
            } else if identifier.rawValue == "mappedReads" {
                if let group = taxonGroups.first(where: { $0.adjustedTaxidName == name }) {
                    cellView.textField?.stringValue = nvdFormatCount(group.totalMappedReads)
                    cellView.textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
                    cellView.textField?.alignment = .right
                } else {
                    cellView.textField?.stringValue = ""
                }
            } else if identifier.rawValue == "rank" {
                if let group = taxonGroups.first(where: { $0.adjustedTaxidName == name }) {
                    cellView.textField?.stringValue = group.adjustedTaxidRank
                    cellView.textField?.font = .systemFont(ofSize: 11)
                    cellView.textField?.alignment = .left
                } else {
                    cellView.textField?.stringValue = ""
                }
            } else {
                cellView.textField?.stringValue = ""
            }
        }

        return cellView
    }

    private func configureCell(_ cellView: NSTableCellView, column: String, hit: NvdBlastHit, isChild: Bool) {
        let textField = cellView.textField
        let childAlpha: CGFloat = isChild ? 0.7 : 1.0

        switch column {
        case "contig":
            textField?.stringValue = isChild
                ? "Hit #\(hit.hitRank)"
                : NvdDataConverter.displayName(for: hit.qseqid, qlen: hit.qlen)
            textField?.font = isChild
                ? .systemFont(ofSize: 10, weight: .regular)
                : .systemFont(ofSize: 11, weight: .medium)
            textField?.alphaValue = childAlpha
            textField?.alignment = .left
        case "sampleId":
            textField?.stringValue = hit.sampleId
            textField?.font = .systemFont(ofSize: 10)
            textField?.alphaValue = childAlpha
            textField?.alignment = .left
        case "length":
            textField?.stringValue = nvdFormatCount(hit.qlen)
            textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            textField?.alphaValue = childAlpha
            textField?.alignment = .right
        case "classification":
            textField?.stringValue = hit.adjustedTaxidName.isEmpty ? "Unclassified" : hit.adjustedTaxidName
            textField?.font = .systemFont(ofSize: 11)
            textField?.alphaValue = childAlpha
            textField?.alignment = .left
        case "rank":
            textField?.stringValue = hit.adjustedTaxidRank
            textField?.font = .systemFont(ofSize: 11)
            textField?.alphaValue = childAlpha
            textField?.alignment = .left
        case "accession":
            textField?.stringValue = hit.sseqid
            textField?.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            textField?.alphaValue = childAlpha
            textField?.alignment = .left
        case "subject":
            textField?.stringValue = hit.stitle
            textField?.font = .systemFont(ofSize: 10)
            textField?.lineBreakMode = .byTruncatingTail
            textField?.alphaValue = childAlpha
            textField?.alignment = .left
        case "pident":
            textField?.stringValue = String(format: "%.1f", hit.pident)
            textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            textField?.alphaValue = childAlpha
            textField?.alignment = .right
        case "evalue":
            textField?.stringValue = formatEvalue(hit.evalue)
            textField?.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            textField?.alphaValue = childAlpha
            textField?.alignment = .right
        case "bitscore":
            textField?.stringValue = String(format: "%.0f", hit.bitscore)
            textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            textField?.alphaValue = childAlpha
            textField?.alignment = .right
        case "mappedReads":
            textField?.stringValue = nvdFormatCount(hit.mappedReads)
            textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            textField?.alphaValue = childAlpha
            textField?.alignment = .right
        case "readsPerBillion":
            textField?.stringValue = String(format: "%.0f", hit.readsPerBillion)
            textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            textField?.alphaValue = childAlpha
            textField?.alignment = .right
        case "coverage":
            textField?.stringValue = nvdFormatCount(hit.length)
            textField?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            textField?.alphaValue = childAlpha
            textField?.alignment = .right
        default:
            textField?.stringValue = ""
        }
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionSync else { return }

        let row = outlineView.selectedRow
        guard row >= 0, let item = outlineView.item(atRow: row) as? NvdOutlineItem else {
            showOverview()
            return
        }

        switch item {
        case .contig(let sampleId, let qseqid):
            if let hit = displayedContigs.first(where: { $0.sampleId == sampleId && $0.qseqid == qseqid }) {
                showContigDetail(hit)
            }
        case .childHit(let sampleId, let qseqid, let hitRank):
            let key = "\(sampleId)\t\(qseqid)"
            if let children = childHitsCache[key],
               let child = children.first(where: { $0.hitRank == hitRank }) {
                showContigDetail(child)
            }
        case .taxonGroup:
            showOverview()
        }
    }

    private func makeOutlineCellView(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
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

// MARK: - NSMenuDelegate

extension NvdResultViewController: NSMenuDelegate {

    public func menuNeedsUpdate(_ menu: NSMenu) {
        let clickedRow = outlineView.clickedRow
        guard clickedRow >= 0, let item = outlineView.item(atRow: clickedRow) as? NvdOutlineItem else {
            menu.removeAllItems()
            return
        }

        switch item {
        case .contig(let sampleId, let qseqid):
            if let hit = displayedContigs.first(where: { $0.sampleId == sampleId && $0.qseqid == qseqid }) {
                populateContextMenu(menu, for: hit)
            }
        case .childHit(let sampleId, let qseqid, let hitRank):
            let key = "\(sampleId)\t\(qseqid)"
            if let children = childHitsCache[key],
               let child = children.first(where: { $0.hitRank == hitRank }) {
                populateContextMenu(menu, for: child)
            }
        case .taxonGroup:
            menu.removeAllItems()
        }
    }
}

// MARK: - NSSearchFieldDelegate (Debounced Search)

extension NvdResultViewController: NSSearchFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        filterWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let newQuery = self.searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard newQuery != self.searchQuery else { return }
                    self.searchQuery = newQuery
                    self.reloadOutlineData()
                }
            }
        }
        filterWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }
}

// MARK: - NvdSummaryBar

@MainActor
final class NvdSummaryBar: GenomicSummaryCardBar {

    private var experimentLabel: String = ""
    private var samplesLabel: String = ""
    private var contigsLabel: String = ""
    private var hitsLabel: String = ""

    func update(experiment: String, sampleCount: Int, contigCount: Int, hitCount: Int) {
        experimentLabel = experiment
        samplesLabel = sampleCount == 1 ? "1 sample" : "\(sampleCount) samples"

        let contigFmt = NumberFormatter()
        contigFmt.numberStyle = .decimal
        let contigStr = contigFmt.string(from: NSNumber(value: contigCount)) ?? "\(contigCount)"
        contigsLabel = "\(contigStr) contigs"

        let hitFmt = NumberFormatter()
        hitFmt.numberStyle = .decimal
        let hitStr = hitFmt.string(from: NSNumber(value: hitCount)) ?? "\(hitCount)"
        hitsLabel = "\(hitStr) hits"

        needsDisplay = true
    }

    override var cards: [Card] {
        [
            Card(label: "Experiment", value: experimentLabel),
            Card(label: "Samples", value: samplesLabel),
            Card(label: "Contigs", value: contigsLabel),
            Card(label: "Hits", value: hitsLabel),
        ]
    }
}

