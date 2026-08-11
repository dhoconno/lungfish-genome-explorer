// NvdResultViewController.swift - NVD (Novel Virus Diagnostics) taxonomy browser
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import SwiftUI
import os.log
import LungfishKit

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

    /// Returns `(sampleId, qseqid)` for rows that point at a contig (either
    /// directly via `.contig` or indirectly via `.childHit`). Returns nil for
    /// grouping rows that don't have a BAM reference. Used by
    /// `buildNvdSelectors` to flatten mixed taxon-group + contig selections.
    var sampleContig: (sampleId: String, qseqid: String)? {
        switch self {
        case .contig(let sampleId, let qseqid),
             .childHit(let sampleId, let qseqid, _):
            return (sampleId, qseqid)
        case .taxonGroup:
            return nil
        }
    }
}

// MARK: - FlippedNvdContentView

/// Flipped container so Auto Layout `topAnchor` maps to visual top.
private final class FlippedNvdContentView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private func nvdDescendants<T: NSView>(of type: T.Type, in root: NSView) -> [T] {
    var result: [T] = []
    if let typed = root as? T {
        result.append(typed)
    }
    for subview in root.subviews {
        result.append(contentsOf: nvdDescendants(of: type, in: subview))
    }
    return result
}

@MainActor
private func nvdHasAncestor<T: NSView>(of type: T.Type, from view: NSView) -> Bool {
    var ancestor = view.superview
    while let current = ancestor {
        if current is T {
            return true
        }
        ancestor = current.superview
    }
    return false
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
/// |  [Alignment evidence]|  > NODE_1183 (227bp) ...           |
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
    NSOutlineViewDataSource, NSOutlineViewDelegate, NSPopoverDelegate,
    SampleMetadataPresentationConsumer
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
    private var manifestSamplesByID: [String: NvdSampleSummary] = [:]

    /// Currently selected sample IDs for filtering.
    private var selectedSamples: Set<String> = []

    // MARK: - Displayed Data

    /// Best hits (hit_rank=1) for currently selected samples.
    private var displayedContigs: [NvdBlastHit] = [] {
        didSet {
            displayedContigLookup = Dictionary(
                displayedContigs.map {
                    (Self.contigLookupKey(sampleId: $0.sampleId, qseqid: $0.qseqid), $0)
                },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }

    /// Updated only when the result projection changes. Typography refreshes
    /// resolve a realized row in O(1) instead of rescanning every contig for
    /// every visible column.
    private var displayedContigLookup: [String: NvdBlastHit] = [:]

    /// Cache of child hits per contig. Key: "sampleId\tqseqid".
    private var childHitsCache: [String: [NvdBlastHit]] = [:]

    /// Taxon groups for byTaxon grouping mode.
    private var taxonGroups: [NvdTaxonGroup] = [] {
        didSet {
            taxonGroupLookup = Dictionary(
                taxonGroups.map { ($0.adjustedTaxidName, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }

    /// Updated only when the by-taxon projection changes so each realized
    /// typography cell resolves its group in O(1).
    private var taxonGroupLookup: [String: NvdTaxonGroup] = [:]

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

    /// Sample metadata for dynamic column display in the outline view.
    public var sampleMetadataStore: SampleMetadataStore? {
        didSet {
            updateMetadataColumnsForCurrentSamples()
        }
    }

    public func applySampleMetadata(_ store: SampleMetadataStore?) {
        sampleMetadataStore = store
    }

    /// Controller for dynamic sample metadata columns (from imported CSV/TSV).
    /// This viewport owns the typography observation for standard and metadata
    /// cells, so the embedded metadata controller must not observe separately.
    private let metadataColumnController = MetadataColumnController(
        contentTypographyOwnership: .embedded
    )

    // MARK: - Content Typography

    private var contentPreferredFontProvider: any ContentPreferredFontProviding =
        AppKitContentPreferredFontProvider()
    private lazy var contentTypographyApplicator = ContentTypographyViewApplicator(
        preferredFontProvider: contentPreferredFontProvider,
        excludedSubtree: { [weak self] candidate in
            guard let self else { return true }
            return candidate === self.summaryBar
                || candidate === self.actionBar
                || candidate === self.outlineView
                || candidate === self.blastDrawerContainer
                || candidate === self.alignmentEvidenceViewer?.viewController.view
                || candidate is NSButton
                || candidate is NSSegmentedControl
                || candidate is NSPopUpButton
                || candidate is NSSlider
        }
    )
    private lazy var outlineTypographyApplicator = ContentTypographyViewApplicator(
        preferredFontProvider: contentPreferredFontProvider,
        excludedSubtree: { candidate in candidate is NSTableCellView }
    )
    private var contentTypographyObservation: ContentTypographyViewObservation?
    private var typographyDetailScrollOrigin: NSPoint?
    private var typographyDividerPosition: CGFloat?
    private weak var detailMetricsStack: NSStackView?
    private var isApplyingOutlineTypography = false

#if DEBUG
    private var outlineReloadCount = 0
    private var childHitLoadCount = 0
    private var detailRebuildCount = 0
    private var alignmentEvidenceLoadCount = 0
    private var typographyDisplayedContigScanCount = 0
    private var typographyTaxonGroupScanCount = 0
    private var typographyRealizedCellResolutionCount = 0
    var testDisableMiniBAMLoading = false
#endif

    // MARK: - Callbacks

    /// Called when the user confirms BLAST verification for a contig.
    /// Parameters: (selected hit, contig FASTA sequence).
    public var onBlastVerification: ((NvdBlastHit, String) -> Void)?
    public var onExtractSequenceRequested: (([String], String) -> Void)?
    public var onExportFASTARequested: (([String]) -> Void)?
    public var onCreateBundleRequested: (([String]) -> Void)?
    public var onRunOperationRequested: (([String]) -> Void)?

    /// Called when the user wants to export results.
    public var onExport: (() -> Void)?

    /// Invoked when the user requests read extraction. The App host wires this to
    /// presentClassifierExtractionDialog; kept as a callback so this VC has no
    /// dependency on the App-internal extraction/operation pipeline.
    public var onExtractReadsRequested: (@MainActor (ClassifierTool, URL, [ClassifierRowSelector], String) -> Void)?

    // MARK: - UI Components

    private let summaryBar = NvdSummaryBar()
    let splitView = TrackedDividerSplitView()
    private let outlineScrollView = NSScrollView()
    private let outlineView = NSOutlineView()
    private let searchField = NSSearchField()
    private let detailScrollView = NSScrollView()
    private let detailContentView = FlippedNvdContentView()
    let actionBar = ClassifierActionBar()
    private let groupingSegment = NSSegmentedControl(labels: ["By Sample", "By Taxon"], trackingMode: .selectOne, target: nil, action: nil)

    // MARK: - Multi-Selection Placeholder

    private lazy var multiSelectionPlaceholder: NSView = {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let primary = NSTextField(labelWithString: "")
        primary.font = .systemFont(ofSize: 13, weight: .semibold)
        primary.alignment = .center
        primary.maximumNumberOfLines = 0
        primary.lineBreakMode = .byWordWrapping
        primary.translatesAutoresizingMaskIntoConstraints = false

        let secondary = NSTextField(labelWithString: "Select a single row to view details")
        secondary.font = .systemFont(ofSize: 11)
        secondary.textColor = .tertiaryLabelColor
        secondary.alignment = .center
        secondary.maximumNumberOfLines = 0
        secondary.lineBreakMode = .byWordWrapping
        secondary.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [primary, secondary])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -12),
            primary.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -24),
            secondary.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -24),
        ])

        container.isHidden = true
        return container
    }()

    // MARK: - Detached alignment evidence

    /// The App composition root replaces this leaf-safe default with the full
    /// ViewerViewController-backed provider for the current window.
    public var classifierAlignmentViewerFactory: @MainActor () -> any ClassifierAlignmentViewerProviding = {
        UnavailableClassifierAlignmentViewer()
    }
    private var alignmentEvidenceViewer: (any ClassifierAlignmentViewerProviding)?
    private var alignmentEvidenceHeightConstraint: NSLayoutConstraint?

    // MARK: - Loading State

    private let loadingOverlay = NSView()
    private let loadingSpinner = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "Loading\u{2026}")

    // MARK: - Search

    private var searchQuery: String = ""
    private var filterWorkItem: DispatchWorkItem?

    // MARK: - Split View State

    private var detailContainer: ScrollViewSplitPaneContainerView?
    private var outlineContainer: NSView?
    private let splitCoordinator = TwoPaneTrackedSplitCoordinator()
    private var splitViewBottomConstraint: NSLayoutConstraint?

    // MARK: - Selection Sync

    private var suppressSelectionSync = false
    private var selectionIdentities = SelectionIdentityStore<String>()

    // MARK: - Sample Popover

    private let sampleFilterButton = NSButton(title: "All Samples", target: nil, action: nil)
    private var samplePopover: NSPopover?

    // MARK: - BLAST Drawer

    private var blastDrawerContainer: BlastResultsDrawerContainerView?
    private var blastDrawerHeightConstraint: NSLayoutConstraint?
    private var isBlastDrawerOpen = false

    // MARK: - Lifecycle

    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        container.setAccessibilityIdentifier("nvd-result-view")
        container.setAccessibilityLabel("NVD Result View")
        view = container

        setupSummaryBar()
        setupSplitView()
        setupActionBar()
        setupLoadingOverlay()
        layoutSubviews()
        wireCallbacks()
        contentTypographyObservation = ContentTypographyViewObservation(
            applicator: contentTypographyApplicator,
            rootProvider: { [weak self] in self?.view },
            beforeApply: { [weak self] in
                guard let self else { return }
                self.typographyDetailScrollOrigin =
                    self.detailScrollView.contentView.bounds.origin
                if let first = self.splitView.arrangedSubviews.first {
                    self.typographyDividerPosition = self.splitView.isVertical
                        ? first.frame.maxX
                        : first.frame.maxY
                }
                if self.alignmentEvidenceHeightConstraint == nil,
                   let evidenceView = self.alignmentEvidenceViewer?.viewController.view,
                   evidenceView.bounds.height > 0 {
                    let fixedHeight = evidenceView.heightAnchor.constraint(
                        equalToConstant: evidenceView.bounds.height
                    )
                    fixedHeight.priority = .required - 2
                    fixedHeight.isActive = true
                    self.alignmentEvidenceHeightConstraint = fixedHeight
                }
                self.updateDetailTypographyLayout()
            },
            afterApply: { [weak self] in
                guard let self else { return }
                let divider = self.typographyDividerPosition
                if let divider,
                   self.splitView.arrangedSubviews.count == 2 {
                    self.splitView.setPosition(divider, ofDividerAt: 0)
                }
                self.applyOutlineTypography()
                self.updateDetailTypographyLayout()
                let origin = self.typographyDetailScrollOrigin
                self.resizeDetailContentToFit(restoringScrollOrigin: origin)
                self.isApplyingOutlineTypography = false
                self.typographyDetailScrollOrigin = nil
                self.typographyDividerPosition = nil
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isApplyingOutlineTypography = true
                    defer { self.isApplyingOutlineTypography = false }
                    if let divider, self.splitView.arrangedSubviews.count == 2 {
                        self.splitView.setPosition(divider, ofDividerAt: 0)
                        self.splitView.layoutSubtreeIfNeeded()
                    }
                    self.resizeDetailContentToFit(restoringScrollOrigin: origin)
                }
            }
        )
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        guard splitCoordinator.needsInitialSplitValidation else { return }
        scheduleInitialSplitValidationIfNeeded()
    }

    // MARK: - Public API: Two-Phase Loading

    /// Phase 1: Configure with cached rows from manifest (instant display).
    ///
    /// Shows the contig list immediately from cached data in manifest.json.
    /// The database is not yet available — detail pane and search are disabled
    /// until `configure(database:manifest:bundleURL:)` is called.
    public func configureWithCachedRows(_ rows: [NvdContigRow], manifest: NvdManifest, bundleURL: URL) {
        self.manifest = manifest
        self.manifestSamplesByID = Dictionary(uniqueKeysWithValues: manifest.samples.map { ($0.sampleId, $0) })
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
        restoreSelectionAfterOutlineReload()

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
        self.manifestSamplesByID = Dictionary(uniqueKeysWithValues: manifest.samples.map { ($0.sampleId, $0) })
        self.bundleURL = bundleURL

        // Fetch samples from database
        do {
            allSamples = try database.allSamples()
        } catch {
            logger.error("Failed to fetch samples: \(error.localizedDescription, privacy: .public)")
            allSamples = []
        }

        // Resolve human-readable display names via manifest lookup.
        // bundleURL is the .lungfishfastq bundle; project is its parent.
        let sampleNames = allSamples.map(\.sampleId)
        let projectURL = bundleURL.deletingLastPathComponent()
        strippedPrefix = ""

        // Create sample entries with resolved display names
        sampleEntries = allSamples.map { sample in
            let displayName = FASTQDisplayNameResolver.resolveDisplayName(
                sampleId: sample.sampleId, projectURL: projectURL)
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
#if DEBUG
        outlineReloadCount += 1
#endif
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
        restoreSelectionAfterOutlineReload()
    }

    // MARK: - Selection

    private func selectContigByIndex(_ index: Int) {
        guard index < displayedContigs.count else { return }

        let contig = displayedContigs[index]
        let item = NvdOutlineItem.contig(sampleId: contig.sampleId, qseqid: contig.qseqid)
        let row = outlineView.row(forItem: item)
        guard row >= 0 else { return }

        if let identity = selectionIdentity(for: item) {
            selectionIdentities.select([identity])
        }
        suppressSelectionSync = true
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineView.scrollRowToVisible(row)
        suppressSelectionSync = false

        showContigDetail(contig)
    }

    // MARK: - Detail Pane Content

    private func showOverview() {
#if DEBUG
        detailRebuildCount += 1
#endif
        teardownAlignmentEvidence()
        hideMultiSelectionPlaceholder()

        for subview in detailContentView.subviews {
            subview.removeFromSuperview()
        }
        detailContentView.removeConstraints(detailContentView.constraints)

        let titleLabel = NSTextField(labelWithString: "NVD Results Overview")
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.maximumNumberOfLines = 0
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailContentView.addSubview(titleLabel)

        let experiment = manifest?.experiment ?? "Unknown"
        let subtitleLabel = NSTextField(labelWithString: "Experiment \(experiment). Select a contig in the outline to view alignments.")
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.lineBreakMode = .byWordWrapping
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
        contentTypographyObservation?.refresh()
        resizeDetailContentToFit()
    }

    private func showContigDetail(_ hit: NvdBlastHit) {
#if DEBUG
        detailRebuildCount += 1
#endif
        teardownAlignmentEvidence()
        hideMultiSelectionPlaceholder()

        for subview in detailContentView.subviews {
            subview.removeFromSuperview()
        }
        detailContentView.removeConstraints(detailContentView.constraints)

        buildContigDetailContent(hit)
        updateActionBarForHit(hit)
        contentTypographyObservation?.refresh()

        DispatchQueue.main.async { [weak self] in
            self?.resizeDetailContentToFit()
        }
    }

    private func buildContigDetailContent(_ hit: NvdBlastHit) {
        // Contig name header
        let displayName = NvdDataConverter.displayName(for: hit.qseqid, qlen: hit.qlen)
        let nameLabel = NSTextField(labelWithString: displayName)
        nameLabel.font = .systemFont(ofSize: 14, weight: .bold)
        nameLabel.maximumNumberOfLines = 0
        nameLabel.lineBreakMode = .byWordWrapping
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
        subtitleLabel.maximumNumberOfLines = 0
        subtitleLabel.lineBreakMode = .byWordWrapping
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        detailContentView.addSubview(subtitleLabel)

        // Metrics row
        let metricsView = buildMetricsView(for: hit)
        detailContentView.addSubview(metricsView)

        let alignmentContainer = buildAlignmentEvidencePanel(for: hit)
        detailContentView.addSubview(alignmentContainer)

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

            alignmentContainer.topAnchor.constraint(equalTo: metricsView.bottomAnchor, constant: 12),
            alignmentContainer.leadingAnchor.constraint(equalTo: detailContentView.leadingAnchor, constant: 8),
            alignmentContainer.trailingAnchor.constraint(equalTo: detailContentView.trailingAnchor, constant: -8),
        ])

        // Pin the evidence container to the bottom of the detail pane.
        let bottomConstraint = alignmentContainer.bottomAnchor.constraint(
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
        detailMetricsStack = container

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
        labelField.maximumNumberOfLines = 0
        labelField.lineBreakMode = .byWordWrapping
        labelField.translatesAutoresizingMaskIntoConstraints = false

        let valueField = NSTextField(labelWithString: value)
        valueField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        valueField.textColor = .labelColor
        valueField.alignment = .center
        valueField.maximumNumberOfLines = 0
        valueField.lineBreakMode = .byWordWrapping
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

    // MARK: - Detached alignment evidence panel

    private func buildAlignmentEvidencePanel(for hit: NvdBlastHit) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        guard let database, let bundleURL else {
            let label = NSTextField(labelWithString: "No BAM data available.")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: container.topAnchor),
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -8),
                label.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
            return container
        }

        // Header
        let headerLabel = NSTextField(labelWithString: "Contig Alignment")
        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.maximumNumberOfLines = 0
        headerLabel.lineBreakMode = .byWordWrapping
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerLabel)

        // Accession info
        let accessionLabel = NSTextField(
            labelWithString: "Best hit: \(hit.sseqid) \u{2014} \(hit.stitle)"
        )
        accessionLabel.font = .systemFont(ofSize: 10)
        accessionLabel.textColor = .secondaryLabelColor
        accessionLabel.maximumNumberOfLines = 0
        accessionLabel.lineBreakMode = .byWordWrapping
        accessionLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(accessionLabel)

        let evidenceViewer = alignmentEvidenceViewer ?? classifierAlignmentViewerFactory()
        if alignmentEvidenceViewer == nil {
            alignmentEvidenceViewer = evidenceViewer
            addChild(evidenceViewer.viewController)
        }
        let evidenceView = evidenceViewer.viewController.view
        evidenceView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(evidenceView)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            headerLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            accessionLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 2),
            accessionLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            accessionLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            evidenceView.topAnchor.constraint(equalTo: accessionLabel.bottomAnchor, constant: 6),
            evidenceView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            evidenceView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            evidenceView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4),
            evidenceView.heightAnchor.constraint(greaterThanOrEqualToConstant: 140),
        ])

        displayNvdAlignmentEvidence(for: hit, database: database, bundleURL: bundleURL)

        return container
    }

    private func displayNvdAlignmentEvidence(for hit: NvdBlastHit, database: NvdDatabase, bundleURL: URL) {
#if DEBUG
        alignmentEvidenceLoadCount += 1
#endif
        guard let viewer = alignmentEvidenceViewer else { return }
        do {
            guard let bamRelPath = try database.bamPath(forSample: hit.sampleId) else {
                viewer.clear()
                return
            }
            let bamURL = bundleURL.appendingPathComponent(bamRelPath)
            let indexRelative = try database.bamIndexPath(forSample: hit.sampleId)
                ?? manifestSamplesByID[hit.sampleId]?.bamIndexRelativePath
            let indexURL = resolveNvdIndex(bamURL: bamURL, storedIndexPath: indexRelative, bundleURL: bundleURL)
            guard let indexURL else {
                viewer.clear()
                return
            }
            let indexKind: ClassifierAlignmentIndex.Kind = indexURL.pathExtension.lowercased() == "csi" ? .csi : .bai
            let sample = allSamples.first(where: { $0.sampleId == hit.sampleId })
            let reference = sample.map { metadata in
                ClassifierAlignmentReferenceCandidate(
                    fastaURL: bundleURL.appendingPathComponent(metadata.fastaPath),
                    recordName: hit.qseqid,
                    expectedLength: max(hit.qlen, 1)
                )
            }
            let request = try ClassifierAlignmentEvidenceRequest(
                workflow: .nvd,
                resultIdentity: .init(
                    stableID: bundleURL.standardizedFileURL.path,
                    finalResultURL: bundleURL,
                    provenanceID: "nvd:\(manifest?.experiment ?? bundleURL.lastPathComponent)"
                ),
                bamURL: bamURL,
                index: .init(url: indexURL, kind: indexKind),
                sample: .init(canonicalID: hit.sampleId),
                contig: .init(name: hit.qseqid, expectedLength: max(hit.qlen, 1)),
                referenceCandidate: reference,
                presentation: .init(workflowLabel: "NVD", resultLabel: manifest?.experiment ?? bundleURL.lastPathComponent, sampleLabel: hit.sampleId, contigLabel: hit.qseqid)
            )
            viewer.display(request)
        } catch {
            viewer.clear()
        }
    }

    private func resolveNvdIndex(bamURL: URL, storedIndexPath: String?, bundleURL: URL) -> URL? {
        if let storedIndexPath, !storedIndexPath.isEmpty {
            return storedIndexPath.hasPrefix("/")
                ? URL(fileURLWithPath: storedIndexPath)
                : bundleURL.appendingPathComponent(storedIndexPath)
        }
        // Legacy manifests/databases may omit the stored field.  Resolve only
        // an index stored beside the final BAM; never create one in the viewer.
        for suffix in [".bai", ".csi"] {
            let candidate = URL(fileURLWithPath: bamURL.path + suffix)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private func teardownAlignmentEvidence() {
        alignmentEvidenceViewer?.clear()
        alignmentEvidenceViewer?.viewController.view.removeFromSuperview()
        alignmentEvidenceHeightConstraint?.isActive = false
        alignmentEvidenceHeightConstraint = nil
    }

    /// Clears detached evidence before this leaf is detached from its host.
    public func clearClassifierAlignmentEvidence() {
        teardownAlignmentEvidence()
    }

    isolated deinit {
        teardownAlignmentEvidence()
    }

    // MARK: - Detail Content Sizing

    private func resizeDetailContentToFit(restoringScrollOrigin: NSPoint? = nil) {
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

        let requestedOrigin = restoringScrollOrigin ?? .zero
        let maxX = max(0, detailContentView.frame.width - detailScrollView.contentView.bounds.width)
        let maxY = max(0, detailContentView.frame.height - detailScrollView.contentView.bounds.height)
        detailScrollView.contentView.scroll(to: NSPoint(
            x: min(max(0, requestedOrigin.x), maxX),
            y: min(max(0, requestedOrigin.y), maxY)
        ))
        detailScrollView.reflectScrolledClipView(detailScrollView.contentView)
    }

    private func updateDetailTypographyLayout() {
        let typography = ContentTypography(
            preference: AppSettings.shared.contentTextSizePreference,
            preferredFontProvider: contentPreferredFontProvider
        )
        let scale = typography.font(for: .body).pointSize / max(
            contentPreferredFontProvider.canonicalUnscaledPointSize(for: .body),
            1
        )
        let shouldStack = scale >= 1.5
            || detailScrollView.contentView.bounds.width < 320
        detailMetricsStack?.orientation = shouldStack ? .vertical : .horizontal
        detailMetricsStack?.distribution = shouldStack ? .fill : .fillEqually
        detailMetricsStack?.alignment = shouldStack ? .width : .top
        detailContentView.needsLayout = true
        detailContentView.layoutSubtreeIfNeeded()
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
        splitView.setAccessibilityIdentifier("nvd-result-split-view")
        splitView.setAccessibilityLabel("NVD Result Split View")
        splitView.isVertical = MetagenomicsPanelLayout.current() != .stacked
        splitView.dividerStyle = .thin
        splitView.delegate = self

        // Detail pane in detail-leading mode.
        let detail = ScrollViewSplitPaneContainerView(
            scrollView: detailScrollView,
            documentView: detailContentView
        )
        detail.setAccessibilityElement(true)
        detail.setAccessibilityIdentifier("nvd-detail-shell")
        detail.setAccessibilityLabel("NVD Detail Shell")
        detailContainer = detail

        // Outline pane in list-leading / stacked mode.
        setupOutlineView()
        let filterBar = makeFilterBar()
        let outlineCont = SplitPaneHeaderContainerView(
            headerView: filterBar,
            contentView: outlineScrollView
        )
        outlineCont.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        outlineCont.setContentHuggingPriority(.defaultLow, for: .horizontal)
        outlineCont.setAccessibilityElement(true)
        outlineCont.setAccessibilityIdentifier("nvd-outline-shell")
        outlineCont.setAccessibilityLabel("NVD Outline Shell")
        self.outlineContainer = outlineCont

        if MetagenomicsPanelLayout.current() == .detailLeading {
            splitView.addArrangedSubview(detail)
            splitView.addArrangedSubview(outlineCont)
        } else {
            splitView.addArrangedSubview(outlineCont)
            splitView.addArrangedSubview(detail)
        }

        // Multi-selection placeholder overlay on the detail container
        detail.addSubview(multiSelectionPlaceholder)
        NSLayoutConstraint.activate([
            multiSelectionPlaceholder.topAnchor.constraint(equalTo: detail.topAnchor),
            multiSelectionPlaceholder.bottomAnchor.constraint(equalTo: detail.bottomAnchor),
            multiSelectionPlaceholder.leadingAnchor.constraint(equalTo: detail.leadingAnchor),
            multiSelectionPlaceholder.trailingAnchor.constraint(equalTo: detail.trailingAnchor),
        ])

        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        splitView.adjustSubviews()
        view.addSubview(splitView)
    }

    private func setupOutlineView() {
        outlineScrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        outlineScrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)

        outlineView.headerView = NSTableHeaderView()
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.allowsMultipleSelection = true
        outlineView.allowsColumnReordering = true
        outlineView.allowsColumnResizing = true
        outlineView.style = .inset
        outlineView.intercellSpacing = NSSize(width: 8, height: 2)
        outlineView.rowHeight = 22
        outlineView.autoresizesOutlineColumn = false
        outlineView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        outlineView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        outlineView.setAccessibilityIdentifier("nvd-outline-view")

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

        let uniqueCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("uniqueReads"))
        uniqueCol.title = "Unique Reads"
        uniqueCol.width = 90
        uniqueCol.minWidth = 60
        outlineView.addTableColumn(uniqueCol)

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
        outlineScrollView.setAccessibilityIdentifier("nvd-outline-shell-scroll")
        outlineScrollView.setAccessibilityLabel("NVD Outline Shell Scroll View")
        outlineScrollView.documentView = outlineView
        outlineScrollView.hasVerticalScroller = true
        outlineScrollView.hasHorizontalScroller = true
        outlineScrollView.autohidesScrollers = true
        outlineScrollView.drawsBackground = true

        outlineView.setAccessibilityLabel("NVD Contig Outline")

        // Install metadata column controller for dynamic sample metadata columns.
        metadataColumnController.standardColumnNames = [
            "Sample", "Contig", "Length", "Classification", "Rank",
            "Accession", "Subject", "% Identity", "E-value", "Bitscore",
            "Mapped Reads", "Unique Reads", "Reads/Billion", "Aln Length",
        ]
        metadataColumnController.install(on: outlineView)
    }

    /// Updates only realized outline content and geometry. It deliberately
    /// avoids `reloadData`, which would collapse items and clear lazy children.
    private func applyOutlineTypography() {
        let exactScrollOrigin = outlineView.enclosingScrollView?.contentView.bounds.origin
        isApplyingOutlineTypography = true
        defer {
            if let exactScrollOrigin,
               let scrollView = outlineView.enclosingScrollView {
                scrollView.contentView.scroll(to: exactScrollOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
        outlineTypographyApplicator.apply(to: outlineView)
        let visibleRows = outlineView.rows(in: outlineView.visibleRect)
        guard visibleRows.location != NSNotFound else { return }
        for row in visibleRows.location..<min(
            NSMaxRange(visibleRows),
            outlineView.numberOfRows
        ) {
            guard let item = outlineView.item(atRow: row) as? NvdOutlineItem else {
                continue
            }
            for (columnIndex, column) in outlineView.tableColumns.enumerated()
            where !column.isHidden {
                guard let cell = outlineView.view(
                    atColumn: columnIndex,
                    row: row,
                    makeIfNecessary: false
                ) as? NSTableCellView else {
                    continue
                }
                if column.identifier.rawValue.hasPrefix("metadata_") {
                    contentTypographyApplicator.apply(to: cell)
                } else {
                    configureExistingCell(cell, column: column.identifier, item: item)
                }
            }
        }
    }

    private func configureExistingCell(
        _ cell: NSTableCellView,
        column: NSUserInterfaceItemIdentifier,
        item: NvdOutlineItem
    ) {
#if DEBUG
        typographyRealizedCellResolutionCount += 1
#endif
        switch item {
        case .contig(let sampleId, let qseqid):
            guard let hit = displayedContigLookup[
                Self.contigLookupKey(sampleId: sampleId, qseqid: qseqid)
            ] else { return }
            configureCell(cell, column: column.rawValue, hit: hit, isChild: false)
        case .childHit(let sampleId, let qseqid, let hitRank):
            let key = "\(sampleId)\t\(qseqid)"
            guard let hit = childHitsCache[key]?.first(where: {
                $0.hitRank == hitRank
            }) else { return }
            configureCell(cell, column: column.rawValue, hit: hit, isChild: true)
        case .taxonGroup(let name):
            configureTaxonCell(cell, column: column.rawValue, name: name)
        }
    }

    private func resolvedContentFont(
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        monospaced: Bool = false,
        digitsOnly: Bool = false
    ) -> NSFont {
        let typography = ContentTypography(
            preference: AppSettings.shared.contentTextSizePreference,
            preferredFontProvider: contentPreferredFontProvider
        )
        let scale = typography.font(for: .body).pointSize / max(
            contentPreferredFontProvider.canonicalUnscaledPointSize(for: .body),
            1
        )
        let resolvedSize = max(ContentTypography.minimumPointSize, size * scale)
        if digitsOnly {
            return .monospacedDigitSystemFont(ofSize: resolvedSize, weight: weight)
        }
        if monospaced {
            return .monospacedSystemFont(ofSize: resolvedSize, weight: weight)
        }
        return .systemFont(ofSize: resolvedSize, weight: weight)
    }

    private static func contigLookupKey(sampleId: String, qseqid: String) -> String {
        "\(sampleId)\u{1F}\(qseqid)"
    }

    private func finishPrimaryCell(_ cell: NSTableCellView, childAlpha: CGFloat = 1) {
        guard let field = cell.textField else { return }
        field.alphaValue = childAlpha
        field.toolTip = field.stringValue
        field.setAccessibilityLabel(field.stringValue)
        field.setAccessibilityValue(field.stringValue)
    }

    private func configureTaxonCell(
        _ cell: NSTableCellView,
        column: String,
        name: String
    ) {
        guard let field = cell.textField else { return }
        switch column {
        case "contig":
            field.stringValue = name.isEmpty ? "Unclassified" : name
            field.font = resolvedContentFont(size: 11, weight: .semibold)
            field.alignment = .left
        case "mappedReads":
            if let group = taxonGroupLookup[name] {
                field.stringValue = nvdFormatCount(group.totalMappedReads)
                field.font = resolvedContentFont(
                    size: 11, weight: .medium, digitsOnly: true
                )
                field.alignment = .right
            } else {
                field.stringValue = ""
            }
        case "rank":
            if let group = taxonGroupLookup[name] {
                field.stringValue = group.adjustedTaxidRank
                field.font = resolvedContentFont(size: 11)
                field.alignment = .left
            } else {
                field.stringValue = ""
            }
        default:
            field.stringValue = ""
        }
        finishPrimaryCell(cell)
    }

    private func makeFilterBar() -> NSView {
        let filterBar = NSStackView()
        filterBar.orientation = .horizontal
        filterBar.alignment = .centerY
        filterBar.spacing = 6
        filterBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        filterBar.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Sample filter button
        sampleFilterButton.bezelStyle = .push
        sampleFilterButton.controlSize = .small
        sampleFilterButton.font = .systemFont(ofSize: 11)
        sampleFilterButton.setAccessibilityIdentifier("nvd-sample-filter-button")
        sampleFilterButton.setAccessibilityLabel("NVD Sample Filter")
        sampleFilterButton.target = self
        sampleFilterButton.action = #selector(sampleFilterButtonClicked(_:))
        sampleFilterButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        filterBar.addArrangedSubview(sampleFilterButton)

        // Grouping mode selector
        groupingSegment.controlSize = .small
        groupingSegment.font = .systemFont(ofSize: 11)
        groupingSegment.selectedSegment = 0
        groupingSegment.setAccessibilityIdentifier("nvd-grouping-control")
        groupingSegment.setAccessibilityLabel("NVD Grouping Mode")
        groupingSegment.target = self
        groupingSegment.action = #selector(groupingModeChanged(_:))
        filterBar.addArrangedSubview(groupingSegment)

        // Search field
        searchField.placeholderString = "Search contigs\u{2026}"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.setAccessibilityIdentifier("nvd-search-field")
        searchField.setAccessibilityLabel("NVD Search Contigs")
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchFieldAction(_:))
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        filterBar.addArrangedSubview(searchField)
        return filterBar
    }

    // MARK: - Setup: Action Bar

    private func setupActionBar() {
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actionBar)
    }

    // MARK: - Layout

    private func layoutSubviews() {
        let summaryHeight = summaryBar.heightAnchor.constraint(
            equalToConstant: summaryBar.preferredContentHeight
        )
        summaryBar.onPreferredContentHeightChanged = { [weak summaryHeight] height in
            summaryHeight?.constant = height
        }
        NSLayoutConstraint.activate([
            // Summary bar (top)
            summaryBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            summaryHeight,

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
        if force {
            splitCoordinator.invalidateInitialSplitPosition()
        }
        applyLayoutPreference()
    }

    // MARK: - Callback Wiring

    private func wireCallbacks() {
        // Action bar Extract FASTQ -> route to the unified extraction dialog.
        actionBar.onExtractFASTQ = { [weak self] in
            self?.presentUnifiedExtractionDialog()
        }

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

    // MARK: - Classifier extraction wiring

    /// Builds per-sample selectors from the current outline-view selection.
    /// `.contig` and `.childHit` both carry sampleId + qseqid (the BAM @SQ
    /// reference); `.taxonGroup` is a grouping row and is skipped. Results
    /// are grouped by sample so multi-sample selections produce one selector
    /// per sample.
    private func buildNvdSelectors() -> [ClassifierRowSelector] {
        var bySample: [String: [String]] = [:]
        for item in selectedOutlineItemsByIdentity() {
            guard let (sampleId, qseqid) = item.sampleContig else { continue }
            bySample[sampleId, default: []].append(qseqid)
        }
        return bySample
            .map { ClassifierRowSelector(sampleId: $0.key, accessions: $0.value, taxIds: []) }
            .sorted { ($0.sampleId ?? "") < ($1.sampleId ?? "") }
    }

    /// Presents the unified classifier extraction dialog for the current selection.
    private func presentUnifiedExtractionDialog() {
        presentUnifiedExtractionDialog(selectors: buildNvdSelectors())
    }

    private func presentUnifiedExtractionDialog(for hit: NvdBlastHit) {
        presentUnifiedExtractionDialog(selectors: [
            ClassifierRowSelector(sampleId: hit.sampleId, accessions: [hit.qseqid], taxIds: [])
        ])
    }

    private func presentUnifiedExtractionDialog(selectors: [ClassifierRowSelector]) {
        guard let resultPath = database?.databaseURL else { return }
        guard !selectors.isEmpty else { return }
        let firstContig = selectors.first?.accessions.first ?? "extract"
        onExtractReadsRequested?(.nvd, resultPath, selectors, "nvd_\(firstContig)")
    }

    @objc private func contextExtractReadsUnified(_ sender: Any?) {
        if let hit = (sender as? NSMenuItem)?.representedObject as? NvdBlastHit {
            presentUnifiedExtractionDialog(for: hit)
            return
        }

        if outlineView.selectedRowIndexes.isEmpty,
           outlineView.clickedRow >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: outlineView.clickedRow), byExtendingSelection: false)
            updateSelectionIdentitiesFromOutlineSelection()
        }
        presentUnifiedExtractionDialog()
    }

    @objc private func handleLayoutSwapRequested(_ notification: Notification) {
        applyLayoutPreference()
    }

    private func defaultLeadingFraction(for layout: MetagenomicsPanelLayout) -> CGFloat {
        switch layout {
        case .detailLeading, .stacked:
            return 0.4
        case .listLeading:
            return 0.6
        }
    }

    private func minimumExtents(for layout: MetagenomicsPanelLayout) -> (leading: CGFloat, trailing: CGFloat) {
        switch layout {
        case .detailLeading:
            return (250, 300)
        case .listLeading, .stacked:
            return (300, 250)
        }
    }

    private func scheduleInitialSplitValidationIfNeeded() {
        splitCoordinator.scheduleInitialSplitValidationIfNeeded(
            ownerView: view,
            splitView: splitView,
            minimumExtents: { [weak self] in
                self?.minimumExtents(for: MetagenomicsPanelLayout.current()) ?? (250, 300)
            },
            defaultLeadingFraction: { [weak self] in
                self?.defaultLeadingFraction(for: MetagenomicsPanelLayout.current()) ?? 0.4
            },
            afterApply: { [weak self] in
                self?.resizeDetailContentToFit()
            }
        )
    }

    @objc private func handleInspectorSampleSelectionChanged(_ notification: Notification) {
        let newSelection = samplePickerState.selectedSamples
        guard newSelection != selectedSamples else { return }
        selectedSamples = newSelection
        updateSampleFilterButtonTitle()
        updateMetadataColumnsForCurrentSamples()
        reloadOutlineData()
        summaryBar.update(
            experiment: manifest?.experiment ?? "",
            sampleCount: allSamples.count,
            contigCount: displayedContigs.count,
            hitCount: (try? database?.totalHitCount(samples: Array(newSelection))) ?? 0
        )
    }

    private func applyLayoutPreference() {
        let layout = MetagenomicsPanelLayout.current()
        guard splitView.arrangedSubviews.count == 2 else { return }

        let desiredIsVertical = layout != .stacked
        let desiredFirstPane: NSView = layout == .detailLeading ? detailContainer! : outlineContainer!
        let desiredSecondPane: NSView = layout == .detailLeading ? outlineContainer! : detailContainer!
        splitCoordinator.applyLayoutPreference(
            to: splitView,
            desiredIsVertical: desiredIsVertical,
            desiredFirstPane: desiredFirstPane,
            desiredSecondPane: desiredSecondPane,
            defaultLeadingFraction: defaultLeadingFraction(for: layout),
            minimumExtents: minimumExtents(for: layout),
            isViewInWindow: view.window != nil,
            afterApply: { [weak self] in
                self?.resizeDetailContentToFit()
            }
        )
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
        updateMetadataColumnsForCurrentSamples()
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
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let minimumExtents: (leading: CGFloat, trailing: CGFloat) = splitView.arrangedSubviews.first === detailContainer
            ? (250, 300)
            : (300, 250)
        return MetagenomicsPaneSizing.clampedDividerPosition(
            proposed: proposedPosition,
            containerExtent: extent,
            minimumLeadingExtent: minimumExtents.leading,
            minimumTrailingExtent: minimumExtents.trailing
        )
    }

    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.object as? NSSplitView === splitView else { return }
        splitCoordinator.splitViewDidResizeSubviews(
            splitView,
            minimumExtents: minimumExtents(for: MetagenomicsPanelLayout.current()),
            afterResize: { [weak self] in
                self?.resizeDetailContentToFit()
            }
        )
    }

    // MARK: - BLAST Verification

    private func blastVerifySelectedContig() {
        guard let hit = singleIdentityBackedSelectedHit() else { return }
        guard let bundleURL, let database else { return }

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
        if let blastDrawerContainer { return blastDrawerContainer.blastResultsTab }

        let container = BlastResultsDrawerContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        let heightConstraint = container.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: actionBar.topAnchor),
            heightConstraint,
        ])

        splitViewBottomConstraint?.isActive = false
        let newSplitBottom = splitView.bottomAnchor.constraint(equalTo: container.topAnchor)
        newSplitBottom.isActive = true
        splitViewBottomConstraint = newSplitBottom

        blastDrawerContainer = container
        blastDrawerHeightConstraint = heightConstraint
        container.onDrag = { [weak self] delta in
            guard let self, let heightConstraint = self.blastDrawerHeightConstraint else { return }
            let availableExtent = max(0, self.view.bounds.height - self.actionBar.frame.height)
            let proposed = heightConstraint.constant + delta
            heightConstraint.constant = MetagenomicsPaneSizing.clampedDrawerExtent(
                proposed: proposed,
                containerExtent: availableExtent,
                minimumDrawerExtent: 160,
                minimumSiblingExtent: 120
            )
            self.view.layoutSubtreeIfNeeded()
        }
        container.onDragEnd = { [weak self] in
            self?.view.layoutSubtreeIfNeeded()
        }
        container.blastResultsTab.onRerunBlast = { [weak self] in
            self?.blastVerifySelectedContig()
        }
        view.layoutSubtreeIfNeeded()

        return container.blastResultsTab
    }

    private func openBlastDrawerIfNeeded() {
        guard !isBlastDrawerOpen else { return }
        guard let blastDrawerHeightConstraint else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            blastDrawerHeightConstraint.animator().constant = 220
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
        let extractReadsItem = NSMenuItem(
            title: "Extract Reads\u{2026}",
            action: #selector(contextExtractReadsUnified(_:)),
            keyEquivalent: ""
        )
        extractReadsItem.target = self
        extractReadsItem.representedObject = hit
        extractReadsItem.isEnabled = database != nil
        menu.addItem(extractReadsItem)
        menu.addItem(NSMenuItem.separator())

        let selectedHit = singleIdentityBackedSelectedHit(matching: hit)
        let contextFASTARecord = contigFASTARecord(for: hit)
        let sharedItems = FASTASequenceActionMenuBuilder.buildItems(
            selectionCount: contextFASTARecord == nil ? 0 : 1,
            handlers: FASTASequenceActionHandlers(
                onExtractSequence: { [weak self] in self?.extractSequence(for: hit) },
                onBlast: (onBlastVerification != nil && database != nil && selectedHit != nil)
                    ? { [weak self] in
                        self?.performBlastVerification(for: hit)
                    }
                    : nil,
                onCopy: contextFASTARecord == nil ? nil : { [weak self] in self?.copyContigSequence(hit) },
                onExport: (onExportFASTARequested == nil || contextFASTARecord == nil) ? nil : { [weak self] in
                    self?.exportContigSequence(hit)
                },
                onCreateBundle: (onCreateBundleRequested == nil || contextFASTARecord == nil) ? nil : { [weak self] in
                    self?.createBundle(for: hit)
                },
                onRunOperation: (onRunOperationRequested == nil || contextFASTARecord == nil) ? nil : { [weak self] in
                    self?.runOperation(for: hit)
                }
            )
        )
        if !sharedItems.isEmpty {
            sharedItems.forEach(menu.addItem(_:))
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

    private func selectedContigFASTARecords() -> [String] {
        selectedOutlineItemsByIdentity().compactMap { item in
            switch item {
            case .contig(let sampleId, let qseqid):
                guard let hit = displayedContigs.first(where: { $0.sampleId == sampleId && $0.qseqid == qseqid }) else {
                    return nil
                }
                return contigFASTARecord(for: hit)
            case .childHit:
                return nil
            case .taxonGroup:
                return nil
            }
        }
    }

    private func extractSequence(for hit: NvdBlastHit) {
        guard let record = contigFASTARecord(for: hit) else { return }
        let records = [record]
        if let onExtractSequenceRequested {
            onExtractSequenceRequested(records, suggestedSequenceName(for: records, fallback: "nvd-contig"))
        } else {
            presentUnifiedExtractionDialog(for: hit)
        }
    }

    private func suggestedSequenceName(for fastaRecords: [String], fallback: String) -> String {
        guard let header = fastaRecords.first?
            .split(whereSeparator: \.isNewline)
            .first?
            .dropFirst()
            .split(separator: " ")
            .first,
              !header.isEmpty else {
            return fallback
        }
        return String(header)
    }

    // MARK: - Context Menu Actions

    private func performBlastVerification(for hit: NvdBlastHit) {
        guard let sequence = contigSequence(for: hit) else { return }
        onBlastVerification?(hit, sequence)
    }

    private func copyContigSequence(_ hit: NvdBlastHit) {
        guard let fastaText = contigFASTARecord(for: hit) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fastaText, forType: .string)
    }

    private func runOperation(for hit: NvdBlastHit) {
        guard let fastaText = contigFASTARecord(for: hit) else { return }
        onRunOperationRequested?([fastaText])
    }

    private func exportContigSequence(_ hit: NvdBlastHit) {
        guard let fastaText = contigFASTARecord(for: hit) else { return }
        onExportFASTARequested?([fastaText])
    }

    private func createBundle(for hit: NvdBlastHit) {
        guard let fastaText = contigFASTARecord(for: hit) else { return }
        onCreateBundleRequested?([fastaText])
    }

    private func contigSequence(for hit: NvdBlastHit) -> String? {
        guard let bundleURL, let database else { return nil }
        guard let fastaRelPath = try? database.fastaPath(forSample: hit.sampleId) else {
            return nil
        }
        let fastaURL = bundleURL.appendingPathComponent(fastaRelPath)
        return NvdDataConverter.extractContigSequence(from: fastaURL, contigName: hit.qseqid)
    }

    private func contigFASTARecord(for hit: NvdBlastHit) -> String? {
        guard let sequence = contigSequence(for: hit) else { return nil }
        return ">\(hit.qseqid)\n\(sequence)\n"
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

    // MARK: - Multi-Selection Helpers

    private func showMultiSelectionPlaceholder(count: Int) {
        teardownAlignmentEvidence()

        if let stack = multiSelectionPlaceholder.subviews.first as? NSStackView,
           let primary = stack.arrangedSubviews.first as? NSTextField {
            primary.stringValue = "\(count) items selected"
        }
        detailScrollView.isHidden = true
        multiSelectionPlaceholder.isHidden = false
        actionBar.updateInfoText("\(count) items selected")
        actionBar.setBlastEnabled(false, reason: "Select a single row to use BLAST Verify")
        actionBar.setExtractEnabled(database != nil)
    }

    private func hideMultiSelectionPlaceholder() {
        multiSelectionPlaceholder.isHidden = true
        detailScrollView.isHidden = false
    }

    // MARK: - Action Bar Selection Helper

    /// Updates the unified action bar info text from a BLAST hit.
    private func updateActionBarForHit(_ hit: NvdBlastHit?) {
        if let hit {
            let displayName = NvdDataConverter.displayName(for: hit.qseqid, qlen: hit.qlen)
            let classification = hit.adjustedTaxidName.isEmpty ? "Unclassified" : hit.adjustedTaxidName
            actionBar.updateInfoText("\(displayName) \u{2014} \(classification)")
            actionBar.setBlastEnabled(true)
            actionBar.setExtractEnabled(database != nil)
        } else {
            actionBar.updateInfoText("Select a contig to view details")
            actionBar.setBlastEnabled(false, reason: "Select a row to use BLAST Verify")
            actionBar.setExtractEnabled(false)
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

    // MARK: - Metadata Column Updates

    /// Updates metadata columns for the current sample selection.
    private func updateMetadataColumnsForCurrentSamples() {
        let isMulti = selectedSamples.count > 1
        let sampleId: String?
        if selectedSamples.count == 1 {
            sampleId = selectedSamples.first
        } else {
            sampleId = nil
        }
        metadataColumnController.isMultiSampleMode = isMulti
        metadataColumnController.update(store: sampleMetadataStore, sampleId: sampleId)
    }

    // MARK: - Export

    public func exportResults() {
        guard let window = view.window else { return }
        let experiment = manifest?.experiment ?? "nvd"

        let savePanel = MetagenomicsFilePanelFactory.tsvSummaryExportPanel(
            title: "Export NVD Contigs",
            suggestedName: "\(experiment)_nvd_contigs.tsv"
        )

        savePanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = savePanel.url, let self else { return }

            do {
                try self.writeContigsTSV(to: url)
                logger.info("Exported NVD contigs to \(url.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("Failed to export NVD contigs: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    func writeContigsTSV(to url: URL) throws {
        let startedAt = Date()
        let content = contigsTSVContent()
        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app nvd contigs export",
            sourceURLs: exportProvenanceSourceURLs(),
            outputURL: url,
            outputFormat: .text,
            argv: ["Lungfish.app", "export-nvd-contigs", "--output", url.path],
            explicitOptions: [
                "outputPath": .file(url),
                "format": .string("tsv"),
            ],
            defaults: [
                "format": .string("tsv"),
            ],
            resolved: [
                "rowCount": .integer(displayedContigs.count),
                "experiment": .string(manifest?.experiment ?? "nvd"),
                "sourceSampleCount": .integer(sampleEntries.count),
                "selectedSamples": .array(selectedSamples.sorted().map { .string($0) }),
                "searchQuery": .string(searchQuery),
                "groupingMode": .string(exportGroupingModeName),
                "taxonGroupCount": .integer(taxonGroups.count),
                "metadataColumns": .array(metadataColumnController.exportHeaders.map { .string($0) }),
            ],
            startedAt: startedAt
        )) { outputURL in
            try content.write(to: outputURL, atomically: true, encoding: .utf8)
        }
    }

    private var exportGroupingModeName: String {
        switch groupingMode {
        case .bySample: return "bySample"
        case .byTaxon: return "byTaxon"
        }
    }

    private func contigsTSVContent() -> String {
        var lines: [String] = []
        var header = "sample_id\tcontig\tlength\tclassification\trank\taccession\tsubject\tpident\tevalue\tbitscore\tmapped_reads\treads_per_billion"
        let metaHeaders = metadataColumnController.exportHeaders
        if !metaHeaders.isEmpty {
            header += "\t" + metaHeaders.joined(separator: "\t")
        }
        lines.append(header)

        for hit in displayedContigs {
            var line = "\(hit.sampleId)\t\(hit.qseqid)\t\(hit.qlen)\t\(hit.adjustedTaxidName)\t\(hit.adjustedTaxidRank)\t\(hit.sseqid)\t\(hit.stitle)\t\(String(format: "%.2f", hit.pident))\t\(hit.evalue)\t\(String(format: "%.1f", hit.bitscore))\t\(hit.mappedReads)\t\(String(format: "%.0f", hit.readsPerBillion))"
            let metaValues = metadataColumnController.exportValues(for: hit.sampleId)
            if !metaValues.isEmpty {
                line += "\t" + metaValues.joined(separator: "\t")
            }
            lines.append(line)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private func exportProvenanceSourceURLs() -> [URL] {
        var urls: [URL] = []
        if let database {
            urls.append(database.databaseURL)
        }
        if let bundleURL {
            urls.append(bundleURL.appendingPathComponent("manifest.json"))
        }
        if let sourceDirectoryPath = manifest?.sourceDirectoryPath, !sourceDirectoryPath.isEmpty {
            urls.append(URL(fileURLWithPath: sourceDirectoryPath, isDirectory: true))
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Child Hits (Lazy Loading)

    /// Returns child hits for a contig, loading from database on first access.
    private func childHitsForContig(sampleId: String, qseqid: String) -> [NvdBlastHit] {
        let key = "\(sampleId)\t\(qseqid)"
        if let cached = childHitsCache[key] {
            return cached
        }

        // Row-height/header relayout can ask the outline whether newly realized
        // rows are expandable. A typography-only transaction must never turn
        // those layout queries into database reads or cache mutations.
        guard !isApplyingOutlineTypography else { return [] }
        guard let database else { return [] }

        do {
#if DEBUG
            childHitLoadCount += 1
#endif
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

        // Check for dynamic metadata columns first — pass per-row sample ID for join
        if let tableColumn {
            let rowSampleId: String?
            switch outlineItem {
            case .contig(let sampleId, _):
                rowSampleId = sampleId
            case .childHit(let sampleId, _, _):
                rowSampleId = sampleId
            case .taxonGroup:
                rowSampleId = nil
            }
            if let cell = metadataColumnController.cellForColumn(tableColumn, in: outlineView, sampleId: rowSampleId) {
                contentTypographyApplicator.apply(to: cell)
                return cell
            }
        }

        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("default")

        let cellView = outlineView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeOutlineCellView(identifier: identifier)

        switch outlineItem {
        case .contig(let sampleId, let qseqid):
            guard let hit = displayedContigLookup[
                Self.contigLookupKey(sampleId: sampleId, qseqid: qseqid)
            ] else {
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
            configureTaxonCell(cellView, column: identifier.rawValue, name: name)
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
                ? resolvedContentFont(size: 10)
                : resolvedContentFont(size: 11, weight: .medium)
            textField?.alignment = .left
        case "sampleId":
            textField?.stringValue = hit.sampleId
            textField?.font = resolvedContentFont(size: 10)
            textField?.alignment = .left
        case "length":
            textField?.stringValue = nvdFormatCount(hit.qlen)
            textField?.font = resolvedContentFont(size: 11, digitsOnly: true)
            textField?.alignment = .right
        case "classification":
            textField?.stringValue = hit.adjustedTaxidName.isEmpty ? "Unclassified" : hit.adjustedTaxidName
            textField?.font = resolvedContentFont(size: 11)
            textField?.alignment = .left
        case "rank":
            textField?.stringValue = hit.adjustedTaxidRank
            textField?.font = resolvedContentFont(size: 11)
            textField?.alignment = .left
        case "accession":
            textField?.stringValue = hit.sseqid
            textField?.font = resolvedContentFont(size: 10, monospaced: true)
            textField?.alignment = .left
        case "subject":
            textField?.stringValue = hit.stitle
            textField?.font = resolvedContentFont(size: 10)
            textField?.lineBreakMode = .byTruncatingTail
            textField?.alignment = .left
        case "pident":
            textField?.stringValue = String(format: "%.1f", hit.pident)
            textField?.font = resolvedContentFont(size: 11, digitsOnly: true)
            textField?.alignment = .right
        case "evalue":
            textField?.stringValue = formatEvalue(hit.evalue)
            textField?.font = resolvedContentFont(size: 10, digitsOnly: true)
            textField?.alignment = .right
        case "bitscore":
            textField?.stringValue = String(format: "%.0f", hit.bitscore)
            textField?.font = resolvedContentFont(size: 11, digitsOnly: true)
            textField?.alignment = .right
        case "mappedReads":
            textField?.stringValue = nvdFormatCount(hit.mappedReads)
            textField?.font = resolvedContentFont(
                size: 11, weight: .medium, digitsOnly: true
            )
            textField?.alignment = .right
        case "uniqueReads":
            let unique = ClassifierUniqueReads.normalizedOrFloor(
                stored: hit.uniqueReads,
                readCount: hit.mappedReads
            )
            textField?.stringValue = nvdFormatCount(unique)
            textField?.font = resolvedContentFont(size: 11, digitsOnly: true)
            textField?.alignment = .right
        case "readsPerBillion":
            textField?.stringValue = String(format: "%.0f", hit.readsPerBillion)
            textField?.font = resolvedContentFont(size: 11, digitsOnly: true)
            textField?.alignment = .right
        case "coverage":
            textField?.stringValue = nvdFormatCount(hit.length)
            textField?.font = resolvedContentFont(size: 11, digitsOnly: true)
            textField?.alignment = .right
        default:
            textField?.stringValue = ""
        }
        finishPrimaryCell(cellView, childAlpha: childAlpha)
    }

    public func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionSync else { return }
        updateSelectionIdentitiesFromOutlineSelection()
        displaySelectionDetail(for: selectedOutlineItemsByIdentity())
    }

    private func updateSelectionIdentitiesFromOutlineSelection() {
        let selected = selectedOutlineItemsFromCurrentIndexes()
        let ids = selected.compactMap(selectionIdentity(for:))
        if ids.count == selected.count, !ids.isEmpty {
            selectionIdentities.select(ids)
        } else {
            selectionIdentities.clear()
        }
    }

    private func restoreSelectionAfterOutlineReload() {
        guard let visibleIDs = visibleSelectionIdentities() else { return }
        let previousIDs = selectionIdentities.selectedIDs
        guard !previousIDs.isEmpty else {
            restoreOutlineSelection([])
            return
        }

        selectionIdentities.removeSelectionsNotVisible(in: visibleIDs)
        let selectedIndexes = selectionIdentities.visibleIndexes(in: visibleIDs)
        restoreOutlineSelection(selectedIndexes)
        displaySelectionDetail(for: selectedOutlineItemsByIdentity())
    }

    private func restoreOutlineSelection(_ indexes: IndexSet) {
        suppressSelectionSync = true
        outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
        suppressSelectionSync = false
    }

    private func selectedOutlineItemsByIdentity() -> [NvdOutlineItem] {
        guard let visible = visibleSelectionItemsAndIdentities(),
              !selectionIdentities.selectedIDs.isEmpty else {
            return selectedOutlineItemsFromCurrentIndexes()
        }

        let selectedIDs = selectionIdentities.selectedIDs
        return visible.compactMap { item, identity in
            selectedIDs.contains(identity) ? item : nil
        }
    }

    private func visibleIdentitySelectionCount() -> Int {
        selectedOutlineItemsByIdentity().count
    }

    private func singleIdentityBackedSelectedHit() -> NvdBlastHit? {
        let selected = selectedOutlineItemsByIdentity()
        guard selected.count == 1, let item = selected.first else { return nil }
        switch item {
        case .contig(let sampleId, let qseqid):
            return displayedContigs.first { $0.sampleId == sampleId && $0.qseqid == qseqid }
        case .childHit(let sampleId, let qseqid, let hitRank):
            let key = "\(sampleId)\t\(qseqid)"
            return childHitsCache[key]?.first { $0.hitRank == hitRank }
        case .taxonGroup:
            return nil
        }
    }

    private func singleIdentityBackedSelectedHit(matching contextHit: NvdBlastHit) -> NvdBlastHit? {
        guard let selected = singleIdentityBackedSelectedHit(),
              selected.sampleId == contextHit.sampleId,
              selected.qseqid == contextHit.qseqid,
              selected.hitRank == contextHit.hitRank else {
            return nil
        }
        return selected
    }

    private func selectedOutlineItemsFromCurrentIndexes() -> [NvdOutlineItem] {
        outlineView.selectedRowIndexes.compactMap { row in
            guard row >= 0 else { return nil }
            return outlineView.item(atRow: row) as? NvdOutlineItem
        }
    }

    private func visibleSelectionIdentities() -> [String]? {
        visibleSelectionItemsAndIdentities()?.map(\.identity)
    }

    private func visibleSelectionItemsAndIdentities() -> [(item: NvdOutlineItem, identity: String)]? {
        var visible: [(item: NvdOutlineItem, identity: String)] = []
        visible.reserveCapacity(outlineView.numberOfRows)
        for row in 0..<outlineView.numberOfRows {
            guard let item = outlineView.item(atRow: row) as? NvdOutlineItem,
                  let identity = selectionIdentity(for: item) else {
                return nil
            }
            visible.append((item, identity))
        }
        return visible
    }

    private func selectionIdentity(for item: NvdOutlineItem) -> String? {
        let resultPath = database?.databaseURL.standardizedFileURL.path
            ?? bundleURL?.standardizedFileURL.path
            ?? manifest?.sourceDirectoryPath
            ?? "unknown-result"
        switch item {
        case .contig(let sampleId, let qseqid):
            return ["nvd", resultPath, sampleId, qseqid].joined(separator: "\u{1F}")
        case .childHit(let sampleId, let qseqid, let hitRank):
            return ["nvd", resultPath, sampleId, qseqid, String(hitRank)].joined(separator: "\u{1F}")
        case .taxonGroup(let name):
            return ["nvd", resultPath, "taxon-group", name].joined(separator: "\u{1F}")
        }
    }

    private func displaySelectionDetail(for selected: [NvdOutlineItem]) {
        if selected.count > 1 {
            showMultiSelectionPlaceholder(count: selected.count)
            return
        }

        guard let item = selected.first else {
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

    // MARK: - Testing Accessors

    var testDetailContainer: NSView? { detailContainer }
    var testOutlineContainer: NSView? { outlineContainer }
    var testSplitView: NSSplitView { splitView }
    var testBlastDrawerContainer: BlastResultsDrawerContainerView? { blastDrawerContainer }
    var testActionBar: ClassifierActionBar { actionBar }
    var testOutlineView: NSOutlineView { outlineView }
    var testSearchField: NSSearchField { searchField }
    var testDetailContentView: NSView { detailContentView }
    var testDetailScrollView: NSScrollView { detailScrollView }

#if DEBUG
    var testOutlineReloadCount: Int { outlineReloadCount }
    var testChildHitLoadCount: Int { childHitLoadCount }
    var testDetailRebuildCount: Int { detailRebuildCount }
    var testMiniBAMLoadCount: Int { alignmentEvidenceLoadCount }
    var testTypographyDisplayedContigScanCount: Int {
        typographyDisplayedContigScanCount
    }
    var testTypographyTaxonGroupScanCount: Int {
        typographyTaxonGroupScanCount
    }
    var testTypographyRealizedCellResolutionCount: Int {
        typographyRealizedCellResolutionCount
    }
    var testMiniBAMControllerIdentity: ObjectIdentifier? {
        alignmentEvidenceViewer.map { ObjectIdentifier($0) }
    }
    var testMiniBAMViewHeight: CGFloat? { alignmentEvidenceViewer?.viewController.view.bounds.height }
    var testMetricStackOrientation: NSUserInterfaceLayoutOrientation? {
        detailMetricsStack?.orientation
    }
    var testExpandedOutlineItemIdentities: [String] {
        (0..<outlineView.numberOfRows).compactMap { row in
            guard let item = outlineView.item(atRow: row) as? NvdOutlineItem,
                  outlineView.isItemExpanded(item) else {
                return nil
            }
            return selectionIdentity(for: item)
        }
    }
    var testDetailPrimaryPointSizes: [CGFloat] {
        let miniRoot = alignmentEvidenceViewer?.viewController.view
        return nvdDescendants(of: NSTextField.self, in: detailContentView)
            .filter { field in
                !(miniRoot.map { field.isDescendant(of: $0) } ?? false)
                    && !nvdHasAncestor(of: NSButton.self, from: field)
            }
            .compactMap { $0.font?.pointSize }
    }
    var testDetailPrimaryFieldsAreContained: Bool {
        let miniRoot = alignmentEvidenceViewer?.viewController.view
        return nvdDescendants(of: NSTextField.self, in: detailContentView)
            .filter { field in
                !(miniRoot.map { field.isDescendant(of: $0) } ?? false)
                    && !nvdHasAncestor(of: NSButton.self, from: field)
            }
            .allSatisfy { field in
                let frame = field.convert(field.bounds, to: detailContentView)
                return frame.minX >= -0.5
                    && frame.maxX <= detailContentView.bounds.width + 0.5
            }
    }
    var testDetailFullTextAccessibility: Bool {
        let miniRoot = alignmentEvidenceViewer?.viewController.view
        return nvdDescendants(of: NSTextField.self, in: detailContentView)
            .filter { field in
                !field.stringValue.isEmpty
                    && !(miniRoot.map { field.isDescendant(of: $0) } ?? false)
                    && !nvdHasAncestor(of: NSButton.self, from: field)
            }
            .allSatisfy {
                $0.toolTip == $0.stringValue
                    && $0.accessibilityValue() == $0.stringValue
            }
    }
    var testPlaceholderFieldsAreContained: Bool {
        nvdDescendants(of: NSTextField.self, in: multiSelectionPlaceholder)
            .allSatisfy { field in
                let frame = field.convert(field.bounds, to: multiSelectionPlaceholder)
                return frame.minX >= -0.5
                    && frame.maxX <= multiSelectionPlaceholder.bounds.width + 0.5
            }
    }
    var testPlaceholderPointSizes: [CGFloat] {
        nvdDescendants(of: NSTextField.self, in: multiSelectionPlaceholder)
            .compactMap { $0.font?.pointSize }
    }
    var testLoadingPointSize: CGFloat? { loadingLabel.font?.pointSize }
    func testDetailPrimaryPointSize(containing text: String) -> CGFloat? {
        let miniRoot = alignmentEvidenceViewer?.viewController.view
        return nvdDescendants(of: NSTextField.self, in: detailContentView)
            .first { field in
                field.stringValue.contains(text)
                    && !(miniRoot.map { field.isDescendant(of: $0) } ?? false)
            }?
            .font?
            .pointSize
    }

    func testingSetContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        precondition(
            !isViewLoaded,
            "The preferred-font provider must be injected before loading the view."
        )
        contentPreferredFontProvider = provider
    }

    func testExpandFirstContig() {
        guard outlineView.numberOfRows > 0,
              let item = outlineView.item(atRow: 0) else { return }
        outlineView.expandItem(item)
    }

    func testResetTypographyDisplayedContigScanCount() {
        typographyDisplayedContigScanCount = 0
        typographyTaxonGroupScanCount = 0
        typographyRealizedCellResolutionCount = 0
    }

    func testSetGroupingMode(_ mode: GroupingMode) {
        groupingMode = mode
        reloadOutlineData()
    }

    func testExpandFirstTaxon() {
        guard outlineView.numberOfRows > 0,
              let item = outlineView.item(atRow: 0) else { return }
        outlineView.expandItem(item)
    }

    func testShowMetadataColumn(_ name: String, store: SampleMetadataStore) {
        metadataColumnController.visibleColumns.insert(name)
        sampleMetadataStore = store
    }

    func testSetDetailPaneWidth(_ width: CGFloat) {
        detailScrollView.frame.size.width = width
        detailScrollView.contentView.frame.size.width = width
        detailContentView.frame.size.width = width
        resizeDetailContentToFit()
    }

    func testingShowMultiSelectionPlaceholder(count: Int) {
        showMultiSelectionPlaceholder(count: count)
        contentTypographyObservation?.refresh()
    }
#endif

    func testSelectOutlineRow(_ row: Int) {
        outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification, object: outlineView))
    }

    func testSelectedOutlineContigSamples() -> [String] {
        selectedOutlineItemsByIdentity().compactMap { item in
            item.sampleContig?.sampleId
        }
    }

    func testOutlineSelectedRowIndexes() -> IndexSet {
        outlineView.selectedRowIndexes
    }

    func testSelectOutlineRowsWithoutIdentitySync(_ indexes: IndexSet) {
        suppressSelectionSync = true
        outlineView.selectRowIndexes(indexes, byExtendingSelection: false)
        suppressSelectionSync = false
    }

    struct TestContextMenuActionState {
        let identitySelectionCount: Int
        let menuSelectionCount: Int
        let blastEnabled: Bool
    }

    func testContextMenuActionStateForContig(at index: Int) -> TestContextMenuActionState {
        guard displayedContigs.indices.contains(index) else {
            return TestContextMenuActionState(identitySelectionCount: 0, menuSelectionCount: 0, blastEnabled: false)
        }
        let menu = NSMenu(title: "Test Menu")
        populateContextMenu(menu, for: displayedContigs[index])
        let blastItem = menu.items.first { $0.title == "Verify with BLAST\u{2026}" }
        let count = visibleIdentitySelectionCount()
        return TestContextMenuActionState(
            identitySelectionCount: count,
            menuSelectionCount: count,
            blastEnabled: blastItem?.isEnabled == true
        )
    }

    func testContextMenuActionStateForFirstContig() -> TestContextMenuActionState {
        testContextMenuActionStateForContig(at: 0)
    }

    func testContextMenuTitlesForFirstContig() -> [String] {
        guard !displayedContigs.isEmpty else { return [] }
        outlineView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let menu = NSMenu(title: "Test Menu")
        populateContextMenu(menu, for: displayedContigs[0])
        return menu.items.map(\.title)
    }

    func testInvokeContextMenuItem(title: String, forContigAt index: Int) -> Bool {
        guard displayedContigs.indices.contains(index) else { return false }
        let menu = NSMenu(title: "Test Menu")
        populateContextMenu(menu, for: displayedContigs[index])
        guard let item = menu.items.first(where: { $0.title == title }),
              item.isEnabled,
              let action = item.action,
              let target = item.target else {
            return false
        }
        NSApp.sendAction(action, to: target, from: item)
        return true
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

        cardsDidChange()
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
