// TaxTriageResultViewController.swift - TaxTriage clinical triage result browser
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import SwiftUI
import os.log
import LungfishKit

private let logger = Logger(subsystem: "com.lungfish.app", category: "TaxTriageResultVC")

private struct TaxTriageDatabasePageSnapshot: Sendable {
    let rows: [TaxTriageMetric]
    let uniqueReadsByKey: [String: Int]
    let totalReadsByKey: [String: Int]
    let bamFilesBySample: [String: URL]
    let bamIndexesBySample: [String: URL]
    let retainedReferencesBySample: [String: URL]
    let organismToAccessionsBySample: [String: [String: [String]]]
    let taxIDToAccessionsBySample: [String: [Int: [String]]]
    let accessionLengths: [String: Int]
    let totalMatchingRows: Int
}

private struct TaxTriageBAMReferenceSnapshot: Sendable {
    let accessionLengths: [String: Int]
    let accessionMappedReadCounts: [String: Int]
    let parsedMappedReads: Bool
}

/// Mutable box for a background reader thread's pipe output, joined via
/// `DispatchGroup.wait()` from a `Task.detached` body (never the main actor).
private final class TaxTriagePipeReadBox: @unchecked Sendable {
    var data = Data()
}

/// Per-sample discovery result for the batch unique-read computation,
/// produced off the main actor in `Task.detached` and applied back to
/// `self` as a single `Sendable` value.
private struct TaxTriageBatchSampleDiscovery: Sendable {
    let indexURL: URL?
    let organismToAccessions: [String: [String]]
}

private enum TaxTriageDatabasePageLoadResult: Sendable {
    case success(TaxTriageDatabasePageSnapshot)
    case failure(String)
}

private func makeTaxTriageDatabasePageSnapshot(
    rows dbRows: [TaxTriageTaxonomyRow],
    resultURL: URL?,
    totalMatchingRows: Int
) -> TaxTriageDatabasePageSnapshot {
    var metrics: [TaxTriageMetric] = []
    var uniqueReadsLookup: [String: Int] = [:]
    var totalReadsLookup: [String: Int] = [:]
    var bamsBySample: [String: URL] = [:]
    var indexesBySample: [String: URL] = [:]
    var referencesBySample: [String: URL] = [:]
    var organismAccessionsBySample: [String: [String: [String]]] = [:]
    var taxIDAccessionsBySample: [String: [Int: [String]]] = [:]
    var accessionLengths: [String: Int] = [:]

    metrics.reserveCapacity(dbRows.count)

    for row in dbRows {
        let metric = TaxTriageMetric(
            sample: row.sample,
            taxId: row.taxId,
            organism: row.organism,
            reads: row.readsAligned,
            abundance: row.pctReads,
            coverageBreadth: row.coverageBreadth,
            coverageDepth: row.meanDepth,
            tassScore: row.tassScore,
            confidence: row.confidence
        )
        metrics.append(metric)

        let key = "\(row.sample)\t\(row.organism)"
        if let uniqueReads = row.uniqueReads {
            uniqueReadsLookup[key] = ClassifierUniqueReads.normalizedOrFloor(
                stored: uniqueReads,
                readCount: row.readsAligned
            )
        }
        totalReadsLookup[key] = row.readsAligned

        if let bamPath = row.bamPath, !bamPath.isEmpty {
            if bamPath.hasPrefix("/") {
                bamsBySample[row.sample] = URL(fileURLWithPath: bamPath)
            } else if let resultURL {
                bamsBySample[row.sample] = resultURL.appendingPathComponent(bamPath)
            }
        }
        if let bamIndexPath = row.bamIndexPath, !bamIndexPath.isEmpty {
            if bamIndexPath.hasPrefix("/") {
                indexesBySample[row.sample] = URL(fileURLWithPath: bamIndexPath)
            } else if let resultURL {
                indexesBySample[row.sample] = resultURL.appendingPathComponent(bamIndexPath)
            }
        }
        if let resultURL {
            let retainedReference = resultURL
                .appendingPathComponent("download", isDirectory: true)
                .appendingPathComponent("\(row.sample).dwnld.references.fasta")
            if FileManager.default.fileExists(atPath: retainedReference.path) {
                referencesBySample[row.sample] = retainedReference
            }
        }

        if let accession = row.primaryAccession, !accession.isEmpty {
            let normalized = OrganismNameNormalizer.normalizedKey(row.organism)
            organismAccessionsBySample[row.sample, default: [:]][normalized, default: []].append(accession)
            if let taxID = row.taxId {
                taxIDAccessionsBySample[row.sample, default: [:]][taxID, default: []].append(accession)
            }
            if let length = row.accessionLength, length > 0 {
                accessionLengths[accession] = length
            }
        }
    }

    return TaxTriageDatabasePageSnapshot(
        rows: metrics,
        uniqueReadsByKey: uniqueReadsLookup,
        totalReadsByKey: totalReadsLookup,
        bamFilesBySample: bamsBySample,
        bamIndexesBySample: indexesBySample,
        retainedReferencesBySample: referencesBySample,
        organismToAccessionsBySample: organismAccessionsBySample,
        taxIDToAccessionsBySample: taxIDAccessionsBySample,
        accessionLengths: accessionLengths,
        totalMatchingRows: totalMatchingRows
    )
}

// MARK: - TaxTriageResultViewController

/// A full-screen clinical triage result browser for TaxTriage pipeline output.
///
/// `TaxTriageResultViewController` is the primary UI for displaying TaxTriage
/// metagenomic classification results. It replaces the normal sequence viewer
/// content area following the same child-VC pattern as ``EsVirituResultViewController``
/// and ``TaxonomyViewController``.
///
/// ## Layout
///
/// ```
/// +------------------------------------------+
/// | Summary Bar (48pt)                       |
/// +------------------------------------------+
/// |  BAM Alignments  |  Organism Table       |
/// |  (mini BAM       |  (sortable flat list)  |
/// |   viewer)        |                        |
/// |    (resizable NSSplitView)                |
/// +-------------------------------------------+
/// | Action Bar (36pt)                         |
/// +-------------------------------------------+
/// ```
///
/// ## Left Pane: BAM Alignment Viewer
///
/// Shows detached full alignment evidence when an organism is selected, displaying
/// read alignments for the organism's primary reference accession. When no BAM
/// data is available, the pane is empty.
///
/// ## Right Pane: Organism Table
///
/// A flat-list `NSTableView` (not outline) showing organism identifications with
/// columns for Organism name, TASS Score, Reads, Unique Reads, Coverage, and
/// Confidence (with a color bar indicator). All columns are sortable and user-resizable.
/// In multi-sample mode, the "All Samples" view replaces this with a batch
/// comparison table (``TaxTriageBatchOverviewView``).
///
/// ## Actions
///
/// The bottom action bar provides Export, Re-run, and Open Report Externally buttons.
///
/// ## Thread Safety
///
/// This class is `@MainActor` isolated and manages its `NSSplitView` directly
/// so pane sizing and table/viewer coordination stay local to this controller.
@MainActor
public final class TaxTriageResultViewController: NSViewController, NSSplitViewDelegate, SampleMetadataPresentationConsumer {

    /// Persistence used by this controller for layout reads; set before loading its view.
    var layoutDefaults: UserDefaults = .standard

    /// Export-failure presentation seam (UX-02). Tests inject a spy to assert
    /// a failure was surfaced without driving real `NSAlert` UI.
    var exportFailurePresenter: ExportFailurePresenting = DefaultExportFailurePresenter()

    // MARK: - Data

    /// The SQLite database backing this view (when opened from a pre-built DB).
    private var taxTriageDatabase: TaxTriageDatabase?

    /// The TaxTriage result driving this view.
    private(set) var taxTriageResult: TaxTriageResult?

    /// The TaxTriage config used for this run (for re-run and provenance).
    private(set) var taxTriageConfig: TaxTriageConfig? {
        didSet {
            organismTableView.metadataColumns.persistenceKey = taxTriageConfig.map {
                "taxtriage.organisms:\($0.outputDirectory.standardizedFileURL.path)"
            }
        }
    }

    /// Whether presentUnifiedExtractionDialog() has a result path to extract
    /// from. Extract Reads must stay disabled when neither is set, matching
    /// the guard in presentUnifiedExtractionDialog().
    private var hasExtractableResultPath: Bool {
        taxTriageDatabase != nil || taxTriageConfig != nil
    }

    /// Parsed metrics from the TASS metrics files.
    private(set) var metrics: [TaxTriageMetric] = []

    /// Parsed organisms from the report files.
    private(set) var organisms: [TaxTriageOrganism] = []


    /// Path to the active BAM for the currently selected sample.
    private var bamURL: URL?

    /// Path to the resolved BAM index (.bai or .csi).
    private var bamIndexURL: URL?

    /// All discovered BAM files keyed by sample ID substring.
    private var bamFilesBySample: [String: URL] = [:]
    private var bamIndexesBySample: [String: URL] = [:]
    private var retainedReferencesBySample: [String: URL] = [:]

    /// Maps normalized organism names → BAM reference accessions (from gcfmapping.tsv).
    private var organismToAccessions: [String: [String]] = [:]

    /// Maps Taxonomy ID → BAM reference accessions (from merged.taxid.tsv).
    private var taxIDToAccessions: [Int: [String]] = [:]

    /// Union organism→accession mapping merged from all samples in a multi-sample result.
    private var mergedOrganismToAccessions: [String: [String]] = [:]

    /// Union taxID→accession mapping merged from all samples in a multi-sample result.
    private var mergedTaxIDToAccessions: [Int: [String]] = [:]

    /// Per-sample organism→accession mapping for sample-aware lookup in flat tables.
    private var organismToAccessionsBySample: [String: [String: [String]]] = [:]

    /// Per-sample taxID→accession mapping for sample-aware lookup in flat tables.
    private var taxIDToAccessionsBySample: [String: [Int: [String]]] = [:]

    /// Maps accessions → reference lengths (from BAM header via samtools).
    private var accessionLengths: [String: Int] = [:]

    /// Maps accessions → mapped read count from `samtools idxstats`.
    private var accessionMappedReadCounts: [String: Int] = [:]

    /// Cached normalized organism name → deduplicated read count.
    private var deduplicatedReadCounts: [String: Int] = [:]

    /// Per-sample deduplicated read counts: normalized organism name → [sampleId → unique reads].
    private var perSampleDeduplicatedReadCounts: [String: [String: Int]] = [:]

    /// Background task computing deduplicated read counts per organism row.
    private var deduplicatedReadCountTask: Task<Void, Never>?

    /// Coalesces `batchFlatTableView.reloadUniqueReadsColumn()` calls made from
    /// the batch dedup loop to at most one per 250 ms, so scrolling the table
    /// during a large batch computation is not interrupted once per organism.
    private var pendingUniqueReadsColumnReloadTask: Task<Void, Never>?

    private func scheduleCoalescedUniqueReadsColumnReload() {
        guard pendingUniqueReadsColumnReloadTask == nil else { return }
        pendingUniqueReadsColumnReloadTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled else { return }
            self.pendingUniqueReadsColumnReloadTask = nil
            self.batchFlatTableView.reloadUniqueReadsColumn()
        }
    }

    /// Filename for the batch-level unique-reads cache under `<batchDir>`.
    ///
    /// PERF-04: versioned `v2` because `v1` values were computed from
    /// `AlignmentDataProvider.fetchReads(maxReads: 100_000)`, which capped
    /// any contig with more than 100,000 mapped reads at that ceiling. The
    /// `v2` counter streams the whole contig with no cap via
    /// `countUniqueReads`, so a `v1` cache's values must be recomputed
    /// rather than trusted.
    private static let batchUniqueReadsCacheFilename = "batch-unique-reads.v2.json"

    /// Background task paging SQLite-backed TaxTriage rows into the viewport.
    private var databaseRowLoadTask: Task<Void, Never>?

    /// Background task resolving missing BAM reference lengths for the current selection.
    private var bamReferenceLengthLoadTask: Task<Void, Never>?

    /// Monotonic token used to ignore stale database page loads after filter changes.
    private var databaseRowLoadGeneration = UUID()

    /// Monotonic token used to ignore stale BAM reference loads after selection changes.
    private var bamReferenceLengthLoadGeneration = UUID()

    /// Page size for SQLite-backed TaxTriage viewport loading.
    private let databaseRowsPageSize = 500

    /// Selects the first SQLite-backed row once rows arrive so the detail pane
    /// is populated on initial TaxTriage load.
    private var shouldSelectTopDatabaseRowAfterLoad = false

    /// Currently selected row state for action-bar/detail updates.
    private var selectedOrganismName: String?
    private var selectedReadCount: Int?

    /// Currently selected flat-table row context (batch group / multi-sample flat mode).
    /// Used to route miniBAM-derived read stats back into the selected list row.
    private var selectedBatchSampleId: String?
    private var selectedBatchOrganismName: String?

    /// All table rows before sample filtering (the full merged set).
    private var allTableRows: [TaxTriageTableRow] = []

    /// Distinct sample identifiers discovered from the metrics, in natural order.
    private(set) var sampleIds: [String] = []

    /// Resolved human-readable display names keyed by raw sample ID.
    private var resolvedDisplayNames: [String: String] = [:]

    /// Currently selected sample filter index (0 = "All Samples", 1.. = per-sample).
    public private(set) var selectedSampleIndex: Int = 0

    /// Optional pre-selected sample ID set by sidebar routing before `configure` runs.
    var preselectedSampleId: String?

    /// Database mode: whether View > All Samples (or the "All Samples"
    /// segment) asked for the organism-by-sample overview grid. The grid is
    /// only shown while more than one sample is ticked; see
    /// `isDatabaseOverviewVisible`.
    public private(set) var isShowingDatabaseOverview = false

    /// Database mode: the Sample Filter selection the loaded rows belong to.
    private var loadedDatabaseSampleSelection: Set<String>?

    /// Database mode: a row to select once its sample's rows load (set when
    /// an overview grid value opens a sample).
    private var pendingDatabaseRowSelection: (sample: String, organism: String)?

    /// Loads the organisms seen in negative-control samples.
    private var contaminationRiskLoadTask: Task<Void, Never>?

    /// Opens report files and folders. Tests replace it to observe the URL.
    var reportOpener: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Presents the BLAST read-count popover for the action bar's BLAST
    /// Verify button. `nil` uses the shared `BlastConfigPopoverView` in an
    /// `NSPopover`; tests replace it to drive the chosen read count.
    var blastConfigPopoverPresenter: (@MainActor (_ taxonName: String, _ readsClade: Int, _ anchor: NSView, _ onRun: @escaping (Int) -> Void) -> Void)?

    /// The BLAST read-count popover currently shown from the action bar.
    private(set) var activeBlastConfigPopover: NSPopover?

    // MARK: - Multi-Selection Placeholder

    private let multiSelectionPrimaryLabel = NSTextField(labelWithString: "")
    private let multiSelectionSecondaryLabel = NSTextField(
        labelWithString: "Select a single row to view details"
    )

    private lazy var multiSelectionPlaceholder: NSView = {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let primary = multiSelectionPrimaryLabel
        primary.font = .systemFont(ofSize: 13, weight: .semibold)
        primary.alignment = .center
        primary.lineBreakMode = .byWordWrapping
        primary.maximumNumberOfLines = 0
        primary.cell?.wraps = true
        primary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        primary.translatesAutoresizingMaskIntoConstraints = false

        let secondary = multiSelectionSecondaryLabel
        secondary.font = .systemFont(ofSize: 11)
        secondary.textColor = .tertiaryLabelColor
        secondary.alignment = .center
        secondary.lineBreakMode = .byWordWrapping
        secondary.maximumNumberOfLines = 0
        secondary.cell?.wraps = true
        secondary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),
        ])

        container.isHidden = true
        return container
    }()

    // MARK: - Child Views

    // MARK: - Batch Group Mode

    /// True when this VC is displaying a BATCH GROUP sidebar item (multiple
    /// independent TaxTriage results aggregated into a single flat table).
    /// Distinct from the existing `selectedSampleIndex`-based batch switching
    /// which operates within a single multi-sample TaxTriage result.
    public var isBatchGroupMode: Bool = false

    /// Whether the last `configureFromDatabase` call loaded data from a pre-built manifest
    /// rather than parsing per-sample files. Used to populate the Inspector manifest status.
    public private(set) var didLoadFromManifestCache: Bool = false

    /// True when this VC is displaying a single multi-sample TaxTriage result
    /// using the flat table + Inspector sample picker pattern.
    /// Set automatically by `configure(result:config:)` when `sampleIds.count > 1`.
    private(set) var isMultiSampleSingleResultMode: Bool = false

    /// All flat metrics loaded for the batch group, before sample filtering.
    private(set) var allBatchGroupRows: [TaxTriageMetric] = [] {
        didSet { normalizedOrganismSampleRowIndex = nil }
    }

    /// Keyed lookup from `"\(normalizedOrganism)\t\(sampleId)"` to the matching
    /// `allBatchGroupRows` entry, built lazily and invalidated whenever
    /// `allBatchGroupRows` changes. Avoids the O(rows) linear scan that
    /// `syncUniqueReadsToFlatTable`/`applySingleUniqueReadCount` previously
    /// repeated per (organism, sample) pair during batch dedup computation.
    private var normalizedOrganismSampleRowIndex: [String: TaxTriageMetric]?

    private func organismSampleRowIndex() -> [String: TaxTriageMetric] {
        if let cached = normalizedOrganismSampleRowIndex { return cached }
        var index: [String: TaxTriageMetric] = [:]
        index.reserveCapacity(allBatchGroupRows.count)
        for row in allBatchGroupRows {
            guard let sample = row.sample else { continue }
            let key = "\(normalizedOrganismName(row.organism))\t\(sample)"
            // Keep the first match, mirroring the previous `first(where:)` semantics.
            if index[key] == nil { index[key] = row }
        }
        normalizedOrganismSampleRowIndex = index
        return index
    }

    /// The batch group root directory (parent of sample subdirectories).
    var batchGroupURL: URL?

    /// Flat table showing one row per organism × sample combination.
    /// Hidden in normal mode; shown exclusively when `isBatchGroupMode` is true.
    private(set) var batchFlatTableView = BatchTaxTriageTableView()

    /// Container for the right pane content (organism table, batch overview, or batch flat table).
    /// Stored as an instance property so `setupBatchFlatTableView()` can add to it.
    private let rightPaneContainer = SplitPaneFillContainerView()

    // MARK: - Child Views

    private let summaryBar = TaxTriageSummaryBar()
    private let sampleFilterControl = NSSegmentedControl()
    /// Popup-menu alternative to `sampleFilterControl` for large sample
    /// counts (UX-18: the segmented control does not scale — its own
    /// comment elsewhere concedes this). Shown instead of the segmented
    /// control once the sample count passes `sampleFilterPopUpThreshold`.
    private let sampleFilterPopUp = NSPopUpButton()
    private let sampleFilterPopUpThreshold = 6
    public let splitView = TrackedDividerSplitView()
    private let leftPaneContainer = FlippedSplitPaneFillContainerView()
    /// Supplied by the App composition root; leaf tests use the safe fallback.
    public var classifierAlignmentViewerFactory: @MainActor () -> any ClassifierAlignmentViewerProviding = {
        UnavailableClassifierAlignmentViewer()
    }
    private var alignmentEvidenceViewer: (any ClassifierAlignmentViewerProviding)?
    private let organismTableView = TaxTriageOrganismTableView()
    private let batchOverviewView = TaxTriageBatchOverviewView()
    let actionBar = ClassifierActionBar()

    // MARK: - Custom Action Bar Buttons

    /// "Recompute Unique Reads" button — only shown in batch/multi-sample mode.
    private let recomputeUniqueReadsButton: NSButton = {
        let btn = NSButton()
        btn.title = "Recompute Unique Reads"
        btn.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Recompute Unique Reads")
        btn.bezelStyle = .accessoryBarAction
        btn.imagePosition = .imageLeading
        btn.controlSize = .small
        btn.font = .systemFont(ofSize: 11)
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.isHidden = true  // shown only in batch/multi-sample mode
        return btn
    }()

    private let openReportButton: NSButton = {
        let btn = NSButton()
        btn.title = "Open Report"
        btn.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: "Open Report")
        btn.bezelStyle = .accessoryBarAction
        btn.imagePosition = .imageLeading
        btn.controlSize = .small
        btn.font = .systemFont(ofSize: 11)
        btn.setContentHuggingPriority(.required, for: .horizontal)
        return btn
    }()

    private let relatedAnalysesButton: NSButton = {
        let btn = NSButton()
        btn.title = "Related"
        btn.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Related Analyses")
        btn.bezelStyle = .accessoryBarAction
        btn.imagePosition = .imageLeading
        btn.controlSize = .small
        btn.font = .systemFont(ofSize: 11)
        btn.setContentHuggingPriority(.required, for: .horizontal)
        return btn
    }()

    /// Cached list of related analysis items: (displayLabel, analysisType, bundleURL).
    private var relatedAnalysisItems: [(String, String, URL)]?

    private let blastDrawer = BlastResultsDrawerTab()
    private var blastDrawerHeightConstraint: NSLayoutConstraint?
    private var splitViewBottomConstraint: NSLayoutConstraint?

    /// Height constraint for the sample filter bar (0 when hidden, 24 when visible).
    private var sampleFilterHeightConstraint: NSLayoutConstraint?
    /// Top spacing constraint between sample filter and split view.
    private var sampleFilterTopSpacingConstraint: NSLayoutConstraint?
    /// Bottom spacing constraint between sample filter and split view.
    private var sampleFilterBottomSpacingConstraint: NSLayoutConstraint?
    private var preferredFontProvider: any ContentPreferredFontProviding =
        AppKitContentPreferredFontProvider()
    private nonisolated(unsafe) var contentTypographyObserver: NSObjectProtocol?
#if DEBUG
    private var miniBAMLoadCount = 0
#endif

    /// Whether the BLAST results drawer is currently visible.
    public private(set) var isBlastDrawerOpen = false

    /// The most recent BLAST verification result, if any.
    public private(set) var lastBlastResult: BlastVerificationResult?

    // MARK: - Inspector Sample Picker

    /// TaxTriage sample entry for the unified picker.
    public struct TaxTriageSampleEntry: ClassifierSampleEntry {
        public let id: String
        public let displayName: String
        public let organismCount: Int

        public var metricLabel: String { "organisms" }
        public var metricValue: String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return formatter.string(from: NSNumber(value: organismCount)) ?? "\(organismCount)"
        }
    }

    /// Observable state shared with the Inspector sample picker.
    public var samplePickerState: ClassifierSamplePickerState!

    /// Sample entries for the unified picker.
    public var sampleEntries: [TaxTriageSampleEntry] = []

    /// Common prefix stripped from sample display names.
    public var strippedPrefix: String = ""

    /// Sample metadata for dynamic column display in the organism table.
    public var sampleMetadataStore: SampleMetadataStore? {
        didSet {
            updateMetadataColumnsForCurrentSample()
        }
    }

    public func applySampleMetadata(_ store: SampleMetadataStore?) {
        sampleMetadataStore = store
    }

    // MARK: - Organism Search

    /// Current organism search text for filtering.
    private var organismSearchText: String = ""

    /// Debounce work item for organism search field changes.
    private var organismFilterWorkItem: DispatchWorkItem?

    // MARK: - Split View State

    /// Whether the initial divider position has been applied.
    private var didSetInitialSplitPosition = false
    private var needsInitialSplitValidation = true
    private var pendingInitialSplitValidation = false
    private var pendingInitialValidationLeadingExtent: CGFloat?
    private var isSynchronizingTrackedSplitPosition = false
    private var isMiniBAMDetailPaneCollapsed = false

    // MARK: - Callbacks

    /// Called when the user requests BLAST verification for a selected organism.
    ///
    /// Parameters: organism, readCount, accessions (from BAM mapping), bamURL, bamIndexURL.
    public var onBlastVerification: ((TaxTriageOrganism, Int, [String]?, URL?, URL?) -> Void)?

    /// Called when the user wants to re-run TaxTriage with the same or different settings.
    public var onReRun: (() -> Void)?

    /// Invoked when the user requests read extraction. The App host wires this to
    /// presentClassifierExtractionDialog; kept as a callback so this VC has no
    /// dependency on the App-internal extraction/operation pipeline.
    public var onExtractReadsRequested: (@MainActor (ClassifierTool, URL, [ClassifierRowSelector], String) -> Void)?

    // MARK: - Lifecycle

    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        container.setAccessibilityIdentifier("taxtriage-result-view")
        container.setAccessibilityLabel("TaxTriage Result View")
        view = container

        setupSummaryBar()
        setupSampleFilterControl()
        setupOrganismSearchField()
        setupSplitView()
        setupMiniBAMViewer()
        setupBlastDrawer()
        setupBatchFlatTableView()
        setupActionBar()
        layoutSubviews()
        wireCallbacks()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInspectorSampleSelectionChanged),
            name: .metagenomicsSampleSelectionChanged,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLayoutSwapRequested),
            name: .metagenomicsLayoutSwapRequested,
            object: nil
        )

        installContentTypographyObservation()
        applyLayoutPreference()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        validateInitialSplitLayoutAfterWindowAttachment()
    }

    isolated deinit {
        clearClassifierAlignmentEvidence()
        databaseRowLoadTask?.cancel()
        deduplicatedReadCountTask?.cancel()
        contaminationRiskLoadTask?.cancel()
        if let contentTypographyObserver {
            NotificationCenter.default.removeObserver(contentTypographyObserver)
        }
        NotificationCenter.default.removeObserver(self)
    }

    /// Clears detached evidence before this leaf is detached from its host.
    public func clearClassifierAlignmentEvidence() {
        alignmentEvidenceViewer?.clear()
    }

    private func validateInitialSplitLayoutAfterWindowAttachment() {
        guard view.window != nil else { return }

        view.layoutSubtreeIfNeeded()
        resetInitialSplitPositionIfNeeded()

        if leftPaneContainer.isHidden {
            collapseHiddenDetailPaneIfNeeded()
        } else if !hasValidInitialSplitPosition() {
            restoreDefaultSplitPosition()
        } else {
            applyInitialSplitPositionIfNeeded()
        }

        splitView.layoutSubtreeIfNeeded()
        rightPaneContainer.layoutSubtreeIfNeeded()
        batchFlatTableView.layoutSubtreeIfNeeded()

        needsInitialSplitValidation = !hasValidInitialSplitPosition()
        scheduleInitialSplitValidationIfNeeded()
    }

    @objc private func handleLayoutSwapRequested(_ notification: Notification) {
        applyLayoutPreference()
    }

    private static func currentTaxTriagePanelLayout(
        defaults: UserDefaults = .standard
    ) -> MetagenomicsPanelLayout {
        let hasExplicitLayout = defaults.object(forKey: MetagenomicsPanelLayout.defaultsKey) != nil
        let hasLegacyLayout = defaults.object(forKey: MetagenomicsPanelLayout.legacyTableOnLeftKey) != nil
        guard hasExplicitLayout || hasLegacyLayout else { return .stacked }
        return MetagenomicsPanelLayout.current(defaults: defaults)
    }

    private func currentPanelLayout() -> MetagenomicsPanelLayout {
        Self.currentTaxTriagePanelLayout(defaults: layoutDefaults)
    }

    private func defaultLeadingFraction(for layout: MetagenomicsPanelLayout) -> CGFloat {
        switch layout {
        case .detailLeading:
            return 0.6
        case .listLeading:
            return 0.4
        case .stacked:
            return 0.4
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

    private func resetInitialSplitPositionIfNeeded() {
        guard didSetInitialSplitPosition, !leftPaneContainer.isHidden, splitView.arrangedSubviews.count == 2 else { return }

        let layout = currentPanelLayout()
        let minimumExtents = minimumExtents(for: layout)
        let totalExtent = splitContainerExtent()
        let minimumRequiredExtent = minimumExtents.leading + minimumExtents.trailing + splitView.dividerThickness
        guard totalExtent >= minimumRequiredExtent else { return }

        let leadingExtent = splitView.isVertical
            ? splitView.arrangedSubviews[0].frame.width
            : splitView.arrangedSubviews[0].frame.height
        let trailingExtent = splitView.isVertical
            ? splitView.arrangedSubviews[1].frame.width
            : splitView.arrangedSubviews[1].frame.height

        if leadingExtent < minimumExtents.leading || trailingExtent < minimumExtents.trailing {
            didSetInitialSplitPosition = false
        }
    }

    private func currentMinimumExtents() -> (leading: CGFloat, trailing: CGFloat) {
        let detailIsLeading = splitView.arrangedSubviews.first === leftPaneContainer
        var minimumExtents: (leading: CGFloat, trailing: CGFloat) = detailIsLeading ? (250, 300) : (300, 250)

        if leftPaneContainer.isHidden || isMiniBAMDetailPaneCollapsed {
            if detailIsLeading {
                minimumExtents.leading = 0
            } else {
                minimumExtents.trailing = 0
            }
        }

        return minimumExtents
    }

    private func splitContainerExtent() -> CGFloat {
        splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
    }

    private func currentDividerPosition() -> CGFloat? {
        guard splitView.arrangedSubviews.count == 2 else { return nil }
        return splitView.isVertical
            ? splitView.arrangedSubviews[0].frame.width
            : splitView.arrangedSubviews[0].frame.height
    }

    private func clampedCurrentDividerPosition(for proposedPosition: CGFloat) -> CGFloat {
        let minimumExtents = currentMinimumExtents()
        return MetagenomicsPaneSizing.clampedDividerPosition(
            proposed: proposedPosition,
            containerExtent: splitContainerExtent(),
            minimumLeadingExtent: minimumExtents.leading,
            minimumTrailingExtent: minimumExtents.trailing
        )
    }

    private func synchronizeTrackedSplitPositionIfNeeded() {
        guard !isSynchronizingTrackedSplitPosition,
              let requestedPosition = splitView.requestedDividerPosition(at: 0),
              let currentPosition = currentDividerPosition()
        else { return }

        let clampedPosition = clampedCurrentDividerPosition(for: requestedPosition)
        guard abs(currentPosition - clampedPosition) > 1 else { return }

        isSynchronizingTrackedSplitPosition = true
        splitView.setPosition(clampedPosition, ofDividerAt: 0)
        isSynchronizingTrackedSplitPosition = false
    }

    private func collapsedSplitPositionForHiddenDetail(containerExtent: CGFloat? = nil) -> CGFloat {
        let totalExtent = containerExtent ?? splitContainerExtent()
        guard totalExtent > 0 else { return 0 }
        return splitView.arrangedSubviews.first === leftPaneContainer ? 0 : totalExtent
    }

    private func restoreDefaultSplitPosition(for layout: MetagenomicsPanelLayout? = nil) {
        guard splitView.arrangedSubviews.count > 1 else { return }

        let layout = layout ?? currentPanelLayout()
        let totalExtent = splitContainerExtent()
        guard totalExtent > 0 else {
            didSetInitialSplitPosition = false
            needsInitialSplitValidation = true
            return
        }

        let minimumExtents = minimumExtents(for: layout)
        let minimumRequiredExtent = minimumExtents.leading + minimumExtents.trailing + splitView.dividerThickness
        guard totalExtent >= minimumRequiredExtent else {
            didSetInitialSplitPosition = false
            needsInitialSplitValidation = true
            return
        }

        let position = MetagenomicsPaneSizing.clampedDividerPosition(
            proposed: round(totalExtent * defaultLeadingFraction(for: layout)),
            containerExtent: totalExtent,
            minimumLeadingExtent: minimumExtents.leading,
            minimumTrailingExtent: minimumExtents.trailing
        )
        splitView.setPosition(position, ofDividerAt: 0)
        didSetInitialSplitPosition = true
        needsInitialSplitValidation = false
    }

    private func collapseHiddenDetailPaneIfNeeded() {
        guard splitView.arrangedSubviews.count > 1 else { return }

        let totalExtent = splitContainerExtent()
        guard totalExtent > 0 else {
            needsInitialSplitValidation = true
            return
        }

        splitView.setPosition(collapsedSplitPositionForHiddenDetail(containerExtent: totalExtent), ofDividerAt: 0)
        didSetInitialSplitPosition = true
        needsInitialSplitValidation = false
    }

    private func collapseMiniBAMDetailPane() {
        isMiniBAMDetailPaneCollapsed = true
        leftPaneContainer.isHidden = true
        collapseHiddenDetailPaneIfNeeded()
    }

    private func miniBAMDetailPaneExtent() -> CGFloat {
        splitView.isVertical ? leftPaneContainer.frame.width : leftPaneContainer.frame.height
    }

    /// The smallest extent the detail pane may have and still count as shown.
    ///
    /// Uses the layout's detail minimum, reduced to what the container can
    /// actually hold beside the list's own minimum.
    private func minimumRevealedDetailPaneExtent() -> CGFloat {
        let layout = currentPanelLayout()
        let minimums = minimumExtents(for: layout)
        let detailMinimum = layout == .detailLeading ? minimums.leading : minimums.trailing
        let listMinimum = layout == .detailLeading ? minimums.trailing : minimums.leading
        let available = splitContainerExtent() - listMinimum - splitView.dividerThickness
        return max(1, min(detailMinimum, available))
    }

    private func revealMiniBAMDetailPaneIfNeeded() {
        let wasCollapsed = isMiniBAMDetailPaneCollapsed
        isMiniBAMDetailPaneCollapsed = false
        // Collapsing sets the divider to the container edge, and NSSplitView
        // un-hides a pane whose divider it moves, so `isHidden` alone does not
        // say whether the pane is collapsed. A pane left a few points tall
        // (the evidence viewer's own minimum) must also be re-expanded:
        // treating any extent above 1 pt as "shown" left the alignment pane
        // stuck at about 31 pt after the Inspector sample filter reloaded the
        // rows, so no later row selection could draw into it.
        guard leftPaneContainer.isHidden
                || wasCollapsed
                || miniBAMDetailPaneExtent() < minimumRevealedDetailPaneExtent()
        else { return }
        leftPaneContainer.isHidden = false
        applyRevealedDetailPaneFrames()
        if miniBAMDetailPaneExtent() < minimumRevealedDetailPaneExtent() {
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.isMiniBAMDetailPaneCollapsed else { return }
                self.leftPaneContainer.isHidden = false
                self.applyRevealedDetailPaneFrames()
            }
        }
    }

    /// Restores the default divider position and sets both pane frames from it.
    ///
    /// `NSSplitView.adjustSubviews()` distributes space in proportion to the
    /// panes' current frames, so after a collapse it kept the detail pane at
    /// its collapsed proportion. Setting the frames from the computed divider
    /// position makes the reveal independent of the collapsed frames.
    private func applyRevealedDetailPaneFrames() {
        restoreDefaultSplitPosition()
        guard didSetInitialSplitPosition,
              let position = splitView.requestedDividerPosition(at: 0) else { return }
        applySplitFrames(for: position)
    }

    private func applyInitialSplitPositionIfNeeded() {
        guard !didSetInitialSplitPosition, splitView.arrangedSubviews.count == 2 else { return }

        if leftPaneContainer.isHidden {
            collapseHiddenDetailPaneIfNeeded()
            return
        }

        let totalExtent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard totalExtent > 0 else { return }

        let layout = currentPanelLayout()
        let minimumExtents = minimumExtents(for: layout)
        let minimumRequiredExtent = minimumExtents.leading + minimumExtents.trailing + splitView.dividerThickness
        guard totalExtent >= minimumRequiredExtent else { return }

        let clampedPosition = MetagenomicsPaneSizing.clampedDividerPosition(
            proposed: round(totalExtent * defaultLeadingFraction(for: layout)),
            containerExtent: totalExtent,
            minimumLeadingExtent: minimumExtents.leading,
            minimumTrailingExtent: minimumExtents.trailing
        )
        splitView.setPosition(clampedPosition, ofDividerAt: 0)
        didSetInitialSplitPosition = true
        needsInitialSplitValidation = false
    }

    private func hasValidInitialSplitPosition() -> Bool {
        guard splitView.arrangedSubviews.count == 2 else { return false }

        let totalExtent = splitContainerExtent()
        guard totalExtent > 0 else { return false }

        let minimumExtents = currentMinimumExtents()
        let minimumRequiredExtent = minimumExtents.leading + minimumExtents.trailing + splitView.dividerThickness
        guard totalExtent >= minimumRequiredExtent else { return false }

        let leadingExtent = splitView.isVertical
            ? splitView.arrangedSubviews[0].frame.width
            : splitView.arrangedSubviews[0].frame.height
        let trailingExtent = splitView.isVertical
            ? splitView.arrangedSubviews[1].frame.width
            : splitView.arrangedSubviews[1].frame.height

        return leadingExtent >= minimumExtents.leading && trailingExtent >= minimumExtents.trailing
    }

    private func scheduleInitialSplitValidationIfNeeded() {
        guard needsInitialSplitValidation, view.window != nil, !pendingInitialSplitValidation else { return }
        pendingInitialSplitValidation = true
        pendingInitialValidationLeadingExtent = splitView.arrangedSubviews.count == 2
            ? (splitView.isVertical ? splitView.arrangedSubviews[0].frame.width : splitView.arrangedSubviews[0].frame.height)
            : nil

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingInitialSplitValidation = false
            let scheduledLeadingExtent = self.pendingInitialValidationLeadingExtent
            self.pendingInitialValidationLeadingExtent = nil
            let requestedDividerPosition = self.splitView.requestedDividerPosition(at: 0)
            guard self.view.window != nil else { return }
            guard self.needsInitialSplitValidation else { return }
            if let requestedDividerPosition,
               let scheduledLeadingExtent,
               abs(requestedDividerPosition - scheduledLeadingExtent) > 2,
               self.splitView.arrangedSubviews.count == 2 {
                let currentLeadingExtent = self.splitView.isVertical
                    ? self.splitView.arrangedSubviews[0].frame.width
                    : self.splitView.arrangedSubviews[0].frame.height
                if abs(currentLeadingExtent - scheduledLeadingExtent) > 2 {
                    self.didSetInitialSplitPosition = true
                    self.needsInitialSplitValidation = false
                    return
                }
            }
            self.resetInitialSplitPositionIfNeeded()
            if self.leftPaneContainer.isHidden {
                self.collapseHiddenDetailPaneIfNeeded()
            } else if !self.hasValidInitialSplitPosition() {
                self.restoreDefaultSplitPosition()
            } else {
                self.applyInitialSplitPositionIfNeeded()
            }
            self.needsInitialSplitValidation = !self.hasValidInitialSplitPosition()
        }
    }

    private func applySplitFrames(for leadingExtent: CGFloat) {
        guard splitView.arrangedSubviews.count == 2 else { return }

        let dividerThickness = splitView.dividerThickness
        let firstView = splitView.arrangedSubviews[0]
        let secondView = splitView.arrangedSubviews[1]

        if splitView.isVertical {
            let totalWidth = splitView.bounds.width
            let trailingWidth = max(0, totalWidth - leadingExtent - dividerThickness)
            firstView.frame = NSRect(x: 0, y: 0, width: leadingExtent, height: splitView.bounds.height)
            secondView.frame = NSRect(
                x: leadingExtent + dividerThickness,
                y: 0,
                width: trailingWidth,
                height: splitView.bounds.height
            )
        } else {
            // Keep frame order consistent with the arrangedSubviews array:
            // firstView occupies the leading (y == 0) slice, secondView the
            // trailing slice. Inverting these makes AppKit log "arranged view
            // frames are not in the same order as the arranged views array" and
            // fall back to its own layout.
            let totalHeight = splitView.bounds.height
            let trailingHeight = max(0, totalHeight - leadingExtent - dividerThickness)
            firstView.frame = NSRect(
                x: 0,
                y: 0,
                width: splitView.bounds.width,
                height: leadingExtent
            )
            secondView.frame = NSRect(
                x: 0,
                y: leadingExtent + dividerThickness,
                width: splitView.bounds.width,
                height: trailingHeight
            )
        }
    }

    /// Swaps the split view pane order based on the persisted layout preference.
    private func applyLayoutPreference() {
        let layout = currentPanelLayout()
        guard splitView.arrangedSubviews.count == 2 else { return }

        let detailPaneWasHidden = leftPaneContainer.isHidden || isMiniBAMDetailPaneCollapsed
        let desiredIsVertical = layout != .stacked
        let desiredFirstPane: NSView = layout == .detailLeading ? leftPaneContainer : rightPaneContainer
        let desiredSecondPane: NSView = layout == .detailLeading ? rightPaneContainer : leftPaneContainer

        let currentFirstPane = splitView.arrangedSubviews[0]
        let currentSecondPane = splitView.arrangedSubviews[1]
        let currentExtent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let orientationChanged = splitView.isVertical != desiredIsVertical
        let currentFirstExtent = splitView.isVertical ? currentFirstPane.frame.width : currentFirstPane.frame.height
        let currentSecondExtent = max(0, currentExtent - currentFirstExtent)
        let needsRebuild = orientationChanged
            || splitView.arrangedSubviews[0] !== desiredFirstPane
            || splitView.arrangedSubviews[1] !== desiredSecondPane

        if needsRebuild {
            splitView.removeArrangedSubview(currentFirstPane)
            splitView.removeArrangedSubview(currentSecondPane)
            currentFirstPane.removeFromSuperview()
            currentSecondPane.removeFromSuperview()

            splitView.isVertical = desiredIsVertical
            splitView.addArrangedSubview(desiredFirstPane)
            splitView.addArrangedSubview(desiredSecondPane)
            leftPaneContainer.isHidden = detailPaneWasHidden
        } else {
            splitView.isVertical = desiredIsVertical
            leftPaneContainer.isHidden = detailPaneWasHidden
        }

        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        let totalExtent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard totalExtent > 0 else {
            didSetInitialSplitPosition = false
            needsInitialSplitValidation = true
            return
        }

        guard view.window != nil else {
            didSetInitialSplitPosition = false
            needsInitialSplitValidation = true
            return
        }

        if detailPaneWasHidden {
            let collapsedPosition = collapsedSplitPositionForHiddenDetail(containerExtent: totalExtent)
            splitView.setPosition(collapsedPosition, ofDividerAt: 0)
            applySplitFrames(for: collapsedPosition)
            didSetInitialSplitPosition = true
            needsInitialSplitValidation = false
            return
        }

        let minimumExtents = minimumExtents(for: layout)
        let defaultLeadingExtent = round(totalExtent * defaultLeadingFraction(for: layout))
        let leadingExtent = !orientationChanged && currentFirstExtent > 0 && currentSecondExtent > 0
            ? (desiredFirstPane === currentFirstPane ? currentFirstExtent : currentSecondExtent)
            : defaultLeadingExtent

        let clampedPosition = MetagenomicsPaneSizing.clampedDividerPosition(
            proposed: leadingExtent,
            containerExtent: totalExtent,
            minimumLeadingExtent: minimumExtents.leading,
            minimumTrailingExtent: minimumExtents.trailing
        )
        splitView.setPosition(clampedPosition, ofDividerAt: 0)
        didSetInitialSplitPosition = true
        needsInitialSplitValidation = false
    }

    // MARK: - Keyboard Shortcuts (UX-03)

    /// Selects the next sample (⌘]), dispatched through the responder chain
    /// from a real `View` menu item ([MainMenu.swift](../LungfishApp/App/MainMenu.swift)).
    ///
    /// These were previously implemented only as `NSViewController.performKeyEquivalent`
    /// overrides. AppKit dispatches key equivalents down the *view* hierarchy
    /// starting at the window's `contentView`, never to view controllers, so
    /// that override was never reached by a real ⌘] keypress — only by a test
    /// calling `performKeyEquivalent(with:)` directly. Real menu items with a
    /// nil target reach this method via the responder chain instead, the same
    /// pattern `TaxonomyViewController.expandAllTaxonomyItems` already uses.
    @objc public func selectNextSample(_ sender: Any?) {
        if isBatchGroupMode {
            stepDatabaseSample(by: 1)
            return
        }
        guard sampleIds.count > 1, !metrics.isEmpty else { return }
        let maxIndex = sampleIds.count  // segment 0 is "All", 1..count are samples
        guard selectedSampleIndex < maxIndex else { return }
        selectedSampleIndex += 1
        sampleFilterControl.selectedSegment = selectedSampleIndex
        sampleFilterPopUp.selectItem(at: selectedSampleIndex)
        applyCurrentSampleFilter()
    }

    /// Selects the previous sample (⌘[). See ``selectNextSample(_:)``.
    @objc public func selectPreviousSample(_ sender: Any?) {
        if isBatchGroupMode {
            stepDatabaseSample(by: -1)
            return
        }
        guard sampleIds.count > 1, !metrics.isEmpty, selectedSampleIndex > 0 else { return }
        selectedSampleIndex -= 1
        sampleFilterControl.selectedSegment = selectedSampleIndex
        sampleFilterPopUp.selectItem(at: selectedSampleIndex)
        applyCurrentSampleFilter()
    }

    /// Selects the "All Samples" overview (⌥⌘0 — plain ⌘0 is already View >
    /// Zoom to Fit). See ``selectNextSample(_:)``.
    @objc public func selectAllSamplesOverview(_ sender: Any?) {
        if isBatchGroupMode {
            toggleDatabaseOverview()
            return
        }
        guard sampleIds.count > 1, !metrics.isEmpty else { return }
        selectedSampleIndex = 0
        sampleFilterControl.selectedSegment = 0
        sampleFilterPopUp.selectItem(at: 0)
        applyCurrentSampleFilter()
    }

    private func setupMiniBAMViewer() {
        let viewer = classifierAlignmentViewerFactory()
        addChild(viewer.viewController)
        alignmentEvidenceViewer = viewer
        let evidenceView = viewer.viewController.view
        evidenceView.translatesAutoresizingMaskIntoConstraints = false
        evidenceView.isHidden = false
        evidenceView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        evidenceView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        leftPaneContainer.addSubview(evidenceView)
        leftPaneContainer.fillSubview = evidenceView
        NSLayoutConstraint.activate([
            evidenceView.topAnchor.constraint(equalTo: leftPaneContainer.topAnchor),
            evidenceView.bottomAnchor.constraint(equalTo: leftPaneContainer.bottomAnchor),
            evidenceView.leadingAnchor.constraint(equalTo: leftPaneContainer.leadingAnchor),
            evidenceView.trailingAnchor.constraint(equalTo: leftPaneContainer.trailingAnchor),
        ])
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        guard needsInitialSplitValidation else { return }
        resetInitialSplitPositionIfNeeded()
        scheduleInitialSplitValidationIfNeeded()
    }


    // MARK: - CSV Metadata Labels

    /// Builds sample display labels from CSV metadata in each source bundle.
    ///
    /// For each sample in the config, resolves the source FASTQ bundle and
    /// loads any `metadata.csv` to extract a display label.
    private func buildSampleLabelsFromCSVMetadata() -> [String: String] {
        guard let config = taxTriageConfig else { return [:] }
        var labels: [String: String] = [:]
        for sample in config.samples {
            // Resolve the bundle containing the FASTQ file
            let bundleURL = sample.fastq1.deletingLastPathComponent()
            if FASTQBundle.isBundleURL(bundleURL),
               let csvMeta = FASTQBundleCSVMetadata.load(from: bundleURL),
               let label = csvMeta.displayLabel {
                labels[sample.sampleId] = label
            }
        }
        return labels
    }

    // MARK: - Row Building

    /// Merges organism report data with TASS metrics into unified table rows.
    ///
    /// When a metric matches an organism by name, the metric's richer data
    /// (TASS score, coverage breadth/depth, abundance) is used. Organisms
    /// without matching metrics fall back to report-level data.
    private func buildTableRows(
        organisms: [TaxTriageOrganism],
        metrics: [TaxTriageMetric],
        sampleId: String? = nil
    ) -> [TaxTriageTableRow] {
        // Build lookup from organism name to metric
        let metricsByName = Dictionary(
            metrics.map { (normalizedOrganismName($0.organism), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        // Compute contamination risk: organisms detected in negative control samples
        let negControlIds = negativeControlSampleIds()
        let contaminationOrganisms: Set<String>
        if !negControlIds.isEmpty {
            contaminationOrganisms = Set(
                self.metrics.filter { m in
                    if let sample = m.sample { return negControlIds.contains(sample) }
                    return false
                }.map { normalizedOrganismName($0.organism) }
            )
        } else {
            contaminationOrganisms = []
        }

        // Resolve unique reads: use per-sample counts when filtering by sample,
        // otherwise fall back to aggregate counts.
        let resolveUniqueReads: (String) -> Int? = { normalizedName in
            if let sampleId,
               let perSample = self.perSampleDeduplicatedReadCounts[normalizedName],
               let count = perSample[sampleId] {
                return count
            }
            return self.deduplicatedReadCounts[normalizedName]
        }

        var rows: [TaxTriageTableRow] = []

        // Start from organisms (report data)
        for organism in organisms {
            let normalizedName = normalizedOrganismName(organism.name)
            let matchingMetric = metricsByName[normalizedName]
            rows.append(TaxTriageTableRow(
                organism: organism.name,
                tassScore: matchingMetric?.tassScore ?? organism.score,
                reads: matchingMetric?.reads ?? organism.reads,
                uniqueReads: resolveUniqueReads(normalizedName),
                coverage: matchingMetric?.coverageBreadth ?? organism.coverage,
                confidence: normalizedConfidenceLabel(matchingMetric?.confidence)
                    ?? confidenceLabel(for: matchingMetric?.tassScore ?? organism.score),
                taxId: matchingMetric?.taxId ?? organism.taxId,
                rank: matchingMetric?.rank ?? organism.rank,
                abundance: matchingMetric?.abundance,
                isContaminationRisk: contaminationOrganisms.contains(normalizedName)
            ))
        }

        // Add metrics not in organisms list
        let existingNames = Set(organisms.map { normalizedOrganismName($0.name) })
        for metric in metrics where !existingNames.contains(normalizedOrganismName(metric.organism)) {
            let normalizedName = normalizedOrganismName(metric.organism)
            rows.append(TaxTriageTableRow(
                organism: metric.organism,
                tassScore: metric.tassScore,
                reads: metric.reads,
                uniqueReads: resolveUniqueReads(normalizedName),
                coverage: metric.coverageBreadth,
                confidence: normalizedConfidenceLabel(metric.confidence)
                    ?? confidenceLabel(for: metric.tassScore),
                taxId: metric.taxId,
                rank: metric.rank,
                abundance: metric.abundance,
                isContaminationRisk: contaminationOrganisms.contains(normalizedName)
            ))
        }

        return rows.sorted { $0.tassScore > $1.tassScore }
    }

    /// Converts a numeric score to a qualitative confidence label.
    private func confidenceLabel(for score: Double) -> String {
        if score >= 0.8 { return "High" }
        if score >= 0.4 { return "Medium" }
        return "Low"
    }

    /// Normalizes confidence strings from parser output to a single vocabulary.
    private func normalizedConfidenceLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }

        switch normalized {
        case "high", "high confidence":
            return "High"
        case "medium", "moderate", "medium confidence", "moderate confidence":
            return "Medium"
        case "low", "low confidence":
            return "Low"
        default:
            return raw.capitalized
        }
    }

    // MARK: - Setup: Summary Bar

    private func setupSummaryBar() {
        summaryBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(summaryBar)
    }

    // MARK: - Setup: Sample Filter Control

    /// Configures the per-sample segmented control.
    ///
    /// Initially hidden; shown only when the result contains multiple samples.
    /// Segment 0 is "All Samples"; subsequent segments are per-sample IDs.
    private func setupSampleFilterControl() {
        sampleFilterControl.segmentStyle = .rounded
        sampleFilterControl.segmentCount = 1
        sampleFilterControl.setLabel("All Samples", forSegment: 0)
        sampleFilterControl.selectedSegment = 0
        sampleFilterControl.setAccessibilityIdentifier("taxtriage-sample-filter-control")
        sampleFilterControl.setAccessibilityLabel("TaxTriage Sample Filter")
        sampleFilterControl.target = self
        sampleFilterControl.action = #selector(sampleFilterChanged(_:))
        sampleFilterControl.translatesAutoresizingMaskIntoConstraints = false
        sampleFilterControl.isHidden = true
        view.addSubview(sampleFilterControl)

        sampleFilterPopUp.setAccessibilityIdentifier("taxtriage-sample-filter-popup")
        sampleFilterPopUp.setAccessibilityLabel("TaxTriage Sample Filter")
        sampleFilterPopUp.target = self
        sampleFilterPopUp.action = #selector(sampleFilterPopUpChanged(_:))
        sampleFilterPopUp.translatesAutoresizingMaskIntoConstraints = false
        sampleFilterPopUp.isHidden = true
        view.addSubview(sampleFilterPopUp)
    }

    @objc private func sampleFilterChanged(_ sender: NSSegmentedControl) {
        if isBatchGroupMode {
            selectDatabaseSampleFilterIndex(sender.selectedSegment)
            return
        }
        selectedSampleIndex = sender.selectedSegment
        applyCurrentSampleFilter()
    }

    @objc private func sampleFilterPopUpChanged(_ sender: NSPopUpButton) {
        if isBatchGroupMode {
            selectDatabaseSampleFilterIndex(sender.indexOfSelectedItem)
            return
        }
        selectedSampleIndex = sender.indexOfSelectedItem
        applyCurrentSampleFilter()
    }

    // MARK: - Setup: Organism Search Field

    private lazy var organismSearchField: NSSearchField = {
        let field = NSSearchField()
        field.placeholderString = "Filter organisms\u{2026}"
        field.controlSize = .small
        field.font = .systemFont(ofSize: 11)
        field.setAccessibilityIdentifier("taxtriage-organism-search-field")
        field.setAccessibilityLabel("TaxTriage Organism Search")
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        field.target = self
        field.action = #selector(organismSearchAction)
        return field
    }()

    private func setupOrganismSearchField() {
        organismSearchField.isHidden = true
        view.addSubview(organismSearchField)
    }

    private func installContentTypographyObservation() {
        contentTypographyObserver = NotificationCenter.default.addObserver(
            forName: .contentTextSizeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyResultContentTypography()
            }
        }
        applyResultContentTypography()
    }

    private func applyResultContentTypography() {
        organismSearchField.font = taxTriageContentFont(
            canonicalPointSize: 11,
            preferredFontProvider: preferredFontProvider
        )
        multiSelectionPrimaryLabel.font = taxTriageContentFont(
            canonicalPointSize: 13,
            weight: .semibold,
            preferredFontProvider: preferredFontProvider
        )
        multiSelectionSecondaryLabel.font = taxTriageContentFont(
            canonicalPointSize: 11,
            preferredFontProvider: preferredFontProvider
        )
        for field in [multiSelectionPrimaryLabel, multiSelectionSecondaryLabel] {
            if !field.stringValue.isEmpty {
                field.toolTip = field.stringValue
                field.setAccessibilityValue(field.stringValue)
            }
        }
        updateFilterRowHeightForContentTypography()
        multiSelectionPlaceholder.needsLayout = true
        view.needsLayout = true
    }

    private func updateFilterRowHeightForContentTypography() {
        let isVisible = !sampleFilterControl.isHidden || !sampleFilterPopUp.isHidden || !organismSearchField.isHidden
        guard isVisible else {
            sampleFilterHeightConstraint?.constant = 0
            return
        }
        let fontHeight = organismSearchField.font?.boundingRectForFont.height ?? 0
        sampleFilterHeightConstraint?.constant = max(24, ceil(fontHeight + 8))
    }

    private func setContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        preferredFontProvider = provider
        organismTableView.setContentPreferredFontProvider(provider)
        batchOverviewView.setContentPreferredFontProvider(provider)
        batchFlatTableView.setContentPreferredFontProvider(provider)
        applyResultContentTypography()
    }

    @objc private func organismSearchAction(_ sender: NSSearchField) {
        organismFilterWorkItem?.cancel()
        let query = sender.stringValue
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.organismSearchText = query
                if self.isBatchGroupMode {
                    self.applyBatchGroupFilter()
                } else if self.isMultiSampleSingleResultMode {
                    self.applyMultiSampleFilter()
                } else {
                    self.applyCurrentSampleFilter()
                }
            }
        }
        organismFilterWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    @objc private func handleInspectorSampleSelectionChanged() {
        guard samplePickerState != nil else { return }
        if isBatchGroupMode {
            databaseSampleSelectionDidChange()
        } else if isMultiSampleSingleResultMode {
            applyMultiSampleFilter()
        } else {
            applyCurrentSampleFilter()
        }
    }

    /// Rebuilds the sample filter control from the discovered sample IDs.
    ///
    /// Uses the segmented control for small sample counts, and a popup menu
    /// once the count passes `sampleFilterPopUpThreshold` (UX-18: the
    /// segmented control does not scale to large sample counts — a run with
    /// dozens of samples produced dozens of tiny, unreadable segments).
    private func rebuildSampleFilterSegments() {
        let ids = sampleIds
        if ids.count <= 1 {
            // UX-05: the organism search field used to be coupled to the
            // sample-scope control and hid itself for single-sample results,
            // the most common case, leaving no way to find an organism.
            // Only the (now-redundant) sample control hides here; the search
            // field stays reachable.
            sampleFilterControl.isHidden = true
            sampleFilterPopUp.isHidden = true
            organismSearchField.isHidden = false
            updateFilterRowHeightForContentTypography()
            sampleFilterTopSpacingConstraint?.constant = 4
            sampleFilterBottomSpacingConstraint?.constant = 4
            selectedSampleIndex = 0
            return
        }

        let useScalablePopUp = ids.count > sampleFilterPopUpThreshold

        sampleFilterControl.segmentCount = ids.count + 1
        sampleFilterControl.setLabel("All Samples", forSegment: 0)
        sampleFilterPopUp.removeAllItems()
        sampleFilterPopUp.addItem(withTitle: "All Samples")
        for (i, sampleId) in ids.enumerated() {
            let display = resolvedDisplayNames[sampleId] ?? sampleId
            sampleFilterControl.setLabel(display, forSegment: i + 1)
            sampleFilterPopUp.addItem(withTitle: display)
        }

        // Apply pre-selected sample if set by sidebar routing
        if let preselected = preselectedSampleId,
           let matchIndex = ids.firstIndex(of: preselected) {
            selectedSampleIndex = matchIndex + 1
            preselectedSampleId = nil
        } else {
            selectedSampleIndex = 0
        }
        sampleFilterControl.selectedSegment = selectedSampleIndex
        sampleFilterPopUp.selectItem(at: selectedSampleIndex)
        sampleFilterControl.isHidden = useScalablePopUp
        sampleFilterPopUp.isHidden = !useScalablePopUp
        organismSearchField.isHidden = false
        updateFilterRowHeightForContentTypography()
        sampleFilterTopSpacingConstraint?.constant = 4
        sampleFilterBottomSpacingConstraint?.constant = 4
    }

    /// Filters table rows to the currently selected sample and refreshes the table.
    private func applyCurrentSampleFilter() {
        let showBatchOverview = selectedSampleIndex == 0 && sampleIds.count > 1

        // Update metadata columns for the new sample selection
        updateMetadataColumnsForCurrentSample()

        // Toggle between batch overview and per-sample organism table
        batchOverviewView.isHidden = !showBatchOverview
        organismTableView.isHidden = showBatchOverview

        // Collapse/restore left pane for full-width batch overview
        if showBatchOverview {
            // Hide left pane — give all space to the batch comparison table
            isMiniBAMDetailPaneCollapsed = true
            leftPaneContainer.isHidden = true
            collapseHiddenDetailPaneIfNeeded()
        } else {
            // Restore the left pane (taxonomy/alignments)
            isMiniBAMDetailPaneCollapsed = false
            if leftPaneContainer.isHidden {
                leftPaneContainer.isHidden = false
                restoreDefaultSplitPosition()
            }
        }

        // Switch to the correct per-sample BAM and mappings when viewing a specific sample.
        // TaxTriage multi-sample runs produce per-sample BAMs, gcfmappings, and taxid mappings.
        if selectedSampleIndex > 0, selectedSampleIndex <= sampleIds.count {
            let targetSampleId = sampleIds[selectedSampleIndex - 1]

            if let sampleBam = bamFilesBySample[targetSampleId] {
                bamURL = sampleBam
                bamIndexURL = bamIndexesBySample[targetSampleId]
                    ?? resolveBamIndex(for: sampleBam, allOutputFiles: taxTriageResult?.allOutputFiles ?? [])
                accessionLengths = [:]
                accessionMappedReadCounts = [:]
            }
            setActiveAccessionLookup(forSampleId: targetSampleId)
        } else {
            setActiveAccessionLookup(forSampleId: nil)
        }

        let filteredRows: [TaxTriageTableRow]
        if selectedSampleIndex == 0 || sampleIds.isEmpty {
            // "All Samples" — show merged view / batch overview
            filteredRows = allTableRows
            if showBatchOverview {
                let negControlIds = negativeControlSampleIds()
                let labels = buildSampleLabelsFromCSVMetadata()
                batchOverviewView.configure(metrics: metrics, sampleIds: sampleIds, negativeControlSampleIds: negControlIds, sampleLabels: labels, perSampleDeduplicatedReadCounts: perSampleDeduplicatedReadCounts)
            }
        } else {
            let targetSample = sampleIds[selectedSampleIndex - 1]
            // Rebuild rows from metrics filtered to this sample
            let filteredMetrics = metrics.filter { $0.sample == targetSample }
            let filteredOrganisms = filteredMetrics.map {
                TaxTriageOrganism(
                    name: $0.organism,
                    score: $0.tassScore,
                    reads: $0.reads,
                    coverage: $0.coverageBreadth,
                    taxId: $0.taxId,
                    rank: $0.rank
                )
            }
            // Use per-sample dedup counts for the filtered view
            filteredRows = buildTableRows(
                organisms: filteredOrganisms,
                metrics: filteredMetrics,
                sampleId: targetSample
            )
        }

        // Apply organism name text filter if active
        var displayRows = filteredRows
        if !organismSearchText.isEmpty {
            displayRows = displayRows.filter {
                $0.organism.localizedCaseInsensitiveContains(organismSearchText)
            }
        }

        organismTableView.rows = displayRows
        summaryBar.update(
            organismCount: displayRows.count,
            runtime: taxTriageResult?.runtime ?? 0,
            highConfidenceCount: displayRows.filter { $0.tassScore >= 0.8 }.count,
            sampleCount: selectedSampleIndex == 0
                ? (taxTriageResult?.config.samples.count ?? 1)
                : 1
        )
    }

    /// Selects a sample by its identifier, scrolling the segmented control.
    ///
    /// - Parameter sampleId: The sample ID to select, or nil for "All Samples".
    public func selectSample(_ sampleId: String?) {
        if isBatchGroupMode {
            if let sampleId {
                guard sampleIds.contains(sampleId) else { return }
                setDatabaseSampleSelection([sampleId], showOverview: false)
            } else {
                setDatabaseSampleSelection(sampleIds, showOverview: sampleIds.count > 1)
            }
            return
        }
        guard let sampleId else {
            selectedSampleIndex = 0
            sampleFilterControl.selectedSegment = 0
            sampleFilterPopUp.selectItem(at: 0)
            applyCurrentSampleFilter()
            return
        }
        if let idx = sampleIds.firstIndex(of: sampleId) {
            selectedSampleIndex = idx + 1
            sampleFilterControl.selectedSegment = idx + 1
            sampleFilterPopUp.selectItem(at: idx + 1)
            applyCurrentSampleFilter()
        }
    }

    // MARK: - Setup: Split View

    /// Configures the NSSplitView with BAM alignment viewer (left) and organism table (right).
    private func setupSplitView() {
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.setAccessibilityIdentifier("taxtriage-result-split-view")
        splitView.setAccessibilityLabel("TaxTriage Result Split View")
        splitView.isVertical = currentPanelLayout() != .stacked
        splitView.dividerStyle = .thin
        splitView.delegate = self
        leftPaneContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        leftPaneContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rightPaneContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rightPaneContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        leftPaneContainer.setAccessibilityElement(true)
        leftPaneContainer.setAccessibilityIdentifier("taxtriage-left-shell")
        leftPaneContainer.setAccessibilityLabel("TaxTriage Left Shell")
        rightPaneContainer.setAccessibilityElement(true)
        rightPaneContainer.setAccessibilityIdentifier("taxtriage-right-shell")
        rightPaneContainer.setAccessibilityLabel("TaxTriage Right Shell")

        // Left pane: mini BAM alignment viewer (populated on organism selection)
        // The BAM viewer is added in setupMiniBAMViewer() with constraints.


        // Right pane: organism table + batch overview + batch flat table (mutually exclusive).
        // rightPaneContainer is an instance property so setupBatchFlatTableView() can add to it.
        organismTableView.autoresizingMask = [.width, .height]
        rightPaneContainer.addSubview(organismTableView)

        // Pinned with constraints (not an autoresizing mask from a zero
        // frame) so the grid fills the pane whenever it is shown.
        batchOverviewView.translatesAutoresizingMaskIntoConstraints = false
        batchOverviewView.isHidden = true
        rightPaneContainer.addSubview(batchOverviewView)
        NSLayoutConstraint.activate([
            batchOverviewView.topAnchor.constraint(equalTo: rightPaneContainer.topAnchor),
            batchOverviewView.bottomAnchor.constraint(equalTo: rightPaneContainer.bottomAnchor),
            batchOverviewView.leadingAnchor.constraint(equalTo: rightPaneContainer.leadingAnchor),
            batchOverviewView.trailingAnchor.constraint(equalTo: rightPaneContainer.trailingAnchor),
        ])

        // Wire batch overview cell clicks to navigate to organism in sample
        batchOverviewView.onCellSelected = { [weak self] organism, sampleId in
            guard let self else { return }
            if self.isBatchGroupMode {
                self.openDatabaseSample(sampleId, selectingOrganism: organism)
                return
            }
            self.selectSample(sampleId)
            // Try to select the organism row in the table
            self.organismTableView.selectRow(byOrganism: organism)
        }

        if currentPanelLayout() == .detailLeading {
            splitView.addArrangedSubview(leftPaneContainer)
            splitView.addArrangedSubview(rightPaneContainer)
        } else {
            splitView.addArrangedSubview(rightPaneContainer)
            splitView.addArrangedSubview(leftPaneContainer)
        }

        // Multi-selection placeholder overlay on the left pane container
        leftPaneContainer.addSubview(multiSelectionPlaceholder)
        NSLayoutConstraint.activate([
            multiSelectionPlaceholder.topAnchor.constraint(equalTo: leftPaneContainer.topAnchor),
            multiSelectionPlaceholder.bottomAnchor.constraint(equalTo: leftPaneContainer.bottomAnchor),
            multiSelectionPlaceholder.leadingAnchor.constraint(equalTo: leftPaneContainer.leadingAnchor),
            multiSelectionPlaceholder.trailingAnchor.constraint(equalTo: leftPaneContainer.trailingAnchor),
        ])

        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        view.addSubview(splitView)
    }


    typealias OrganismAccessionMap = [String: [String]]
    typealias TaxIDAccessionMap = [Int: [String]]

    /// Sets the active accession lookup dictionaries for the currently selected sample.
    ///
    /// - Parameter sampleId: Target sample ID, or `nil` to activate the merged lookup.
    private func setActiveAccessionLookup(forSampleId sampleId: String?) {
        if let sampleId {
            organismToAccessions = organismToAccessionsBySample[sampleId] ?? mergedOrganismToAccessions
            taxIDToAccessions = taxIDToAccessionsBySample[sampleId] ?? mergedTaxIDToAccessions
        } else {
            organismToAccessions = mergedOrganismToAccessions
            taxIDToAccessions = mergedTaxIDToAccessions
        }
    }

    /// Rebuilds merged + sample-scoped accession lookup maps from TaxTriage output files.
    private func rebuildAccessionLookups(from allOutputFiles: [URL], sampleIds: [String]) {
        let filtered = TaxTriageOutputArtifactPolicy.filterRetainedOutputFiles(
            allOutputFiles,
            outputDirectory: taxTriageConfig?.outputDirectory
        )
        let gcfFiles = filtered.filter { $0.lastPathComponent.contains("gcfmapping.tsv") }
        let taxIDFiles = filtered.filter { $0.lastPathComponent.contains("merged.taxid.tsv") }
        rebuildAccessionLookups(gcfFiles: gcfFiles, taxIDFiles: taxIDFiles, sampleIds: sampleIds)
    }

    /// Rebuilds merged + sample-scoped accession lookup maps from explicit mapping file sets.
    private func rebuildAccessionLookups(gcfFiles: [URL], taxIDFiles: [URL], sampleIds: [String]) {
        mergedOrganismToAccessions = [:]
        mergedTaxIDToAccessions = [:]
        organismToAccessionsBySample = [:]
        taxIDToAccessionsBySample = [:]

        for gcfFile in gcfFiles {
            let parsed = parseGCFMappingData(url: gcfFile)
            guard !parsed.isEmpty else { continue }
            mergeOrganismMappings(parsed, into: &mergedOrganismToAccessions)
            if let sampleId = sampleIdForMappingFile(gcfFile, sampleIds: sampleIds) {
                var perSample = organismToAccessionsBySample[sampleId] ?? [:]
                mergeOrganismMappings(parsed, into: &perSample)
                organismToAccessionsBySample[sampleId] = perSample
            }
        }

        for taxIDFile in taxIDFiles {
            let (taxMap, organismMap) = parseTaxIDMappingData(url: taxIDFile)
            if !taxMap.isEmpty {
                mergeTaxIDMappings(taxMap, into: &mergedTaxIDToAccessions)
            }
            if !organismMap.isEmpty {
                mergeOrganismMappings(organismMap, into: &mergedOrganismToAccessions)
            }

            if let sampleId = sampleIdForMappingFile(taxIDFile, sampleIds: sampleIds) {
                if !taxMap.isEmpty {
                    var perSampleTax = taxIDToAccessionsBySample[sampleId] ?? [:]
                    mergeTaxIDMappings(taxMap, into: &perSampleTax)
                    taxIDToAccessionsBySample[sampleId] = perSampleTax
                }
                if !organismMap.isEmpty {
                    var perSampleOrg = organismToAccessionsBySample[sampleId] ?? [:]
                    mergeOrganismMappings(organismMap, into: &perSampleOrg)
                    organismToAccessionsBySample[sampleId] = perSampleOrg
                }
            }
        }

        organismToAccessions = mergedOrganismToAccessions
        taxIDToAccessions = mergedTaxIDToAccessions
        logger.info("Built TaxTriage accession lookups: merged organisms=\(self.mergedOrganismToAccessions.count), merged taxids=\(self.mergedTaxIDToAccessions.count), per-sample organism maps=\(self.organismToAccessionsBySample.count), per-sample taxid maps=\(self.taxIDToAccessionsBySample.count)")
    }

    /// Attempts to infer the sample ID encoded in a mapping filename.
    private func sampleIdForMappingFile(_ fileURL: URL, sampleIds: [String]) -> String? {
        let name = fileURL.lastPathComponent.lowercased()
        if let containsMatch = sampleIds.first(where: { name.contains($0.lowercased()) }) {
            return containsMatch
        }

        let pathComponents = Set(fileURL.pathComponents.map { $0.lowercased() })
        if let componentMatch = sampleIds.first(where: { pathComponents.contains($0.lowercased()) }) {
            return componentMatch
        }

        let stem = fileURL.deletingPathExtension().lastPathComponent
        let candidatePrefix = stem.components(separatedBy: ".").first ?? stem
        return sampleIds.first(where: { $0.caseInsensitiveCompare(candidatePrefix) == .orderedSame })
    }

    /// Collects regular files recursively under a directory that match a predicate.
    private nonisolated func collectFilesRecursively(in directory: URL, matching predicate: (URL) -> Bool) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var matches: [URL] = []
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            if predicate(fileURL) {
                matches.append(fileURL)
            }
        }
        return matches
    }

    /// Parses a gcfmapping file into a normalized organism→accessions map.
    ///
    /// Format: accession\tGCF_ID\torganism_name\tdescription
    private nonisolated func parseGCFMappingData(url: URL) -> OrganismAccessionMap {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var mapping: OrganismAccessionMap = [:]
        for line in content.components(separatedBy: .newlines) {
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 3 else { continue }
            let accession = cols[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let organismName = cols[2].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !accession.isEmpty else { continue }
            let key = normalizedOrganismName(organismName)
            guard !key.isEmpty else { continue }
            mapping[key, default: []].append(accession)
        }
        return mapping.mapValues(uniqueAccessionsPreservingOrder)
    }

    /// Parses merged taxid mapping rows into taxID and organism lookup maps.
    ///
    /// Expected columns:
    /// `Acc\tAssembly\tOrganism_Name\tDescription\tMapped_Value`
    private func parseTaxIDMappingData(url: URL) -> (taxID: TaxIDAccessionMap, organism: OrganismAccessionMap) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return ([:], [:]) }

        var byTaxID: TaxIDAccessionMap = [:]
        var byOrganism: OrganismAccessionMap = [:]

        for line in content.components(separatedBy: .newlines) {
            let cols = line.components(separatedBy: "\t")
            guard cols.count >= 5 else { continue }

            let accession = cols[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let organismName = cols[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let taxIDRaw = cols[4].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !accession.isEmpty, accession.lowercased() != "acc" else { continue }

            if let taxID = Int(taxIDRaw), taxID > 0 {
                byTaxID[taxID, default: []].append(accession)
            }

            let key = normalizedOrganismName(organismName)
            if !key.isEmpty {
                byOrganism[key, default: []].append(accession)
            }
        }

        return (
            byTaxID.mapValues(uniqueAccessionsPreservingOrder),
            byOrganism.mapValues(uniqueAccessionsPreservingOrder)
        )
    }

    /// Merges a parsed organism→accessions mapping into an existing destination map.
    private nonisolated func mergeOrganismMappings(_ incoming: OrganismAccessionMap, into destination: inout OrganismAccessionMap) {
        for (organism, accessions) in incoming {
            destination[organism, default: []].append(contentsOf: accessions)
            destination[organism] = uniqueAccessionsPreservingOrder(destination[organism] ?? [])
        }
    }

    /// Merges a parsed taxID→accessions mapping into an existing destination map.
    private func mergeTaxIDMappings(_ incoming: TaxIDAccessionMap, into destination: inout TaxIDAccessionMap) {
        for (taxID, accessions) in incoming {
            destination[taxID, default: []].append(contentsOf: accessions)
            destination[taxID] = uniqueAccessionsPreservingOrder(destination[taxID] ?? [])
        }
    }

    private nonisolated func uniqueAccessionsPreservingOrder(_ accessions: [String]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        ordered.reserveCapacity(accessions.count)
        for accession in accessions where !accession.isEmpty {
            if seen.insert(accession).inserted {
                ordered.append(accession)
            }
        }
        return ordered
    }

    private nonisolated func normalizedOrganismName(_ value: String) -> String {
        OrganismNameNormalizer.normalizedKey(value)
    }

    private func rankAccessionsByReadSupport(_ accessions: [String]) -> [String] {
        let unique = uniqueAccessionsPreservingOrder(accessions)
        return unique.sorted { lhs, rhs in
            let lhsReads = accessionMappedReadCounts[lhs] ?? 0
            let rhsReads = accessionMappedReadCounts[rhs] ?? 0
            if lhsReads != rhsReads {
                return lhsReads > rhsReads
            }
            return lhs < rhs
        }
    }

    private func lookupAccessions(for normalizedOrganismName: String, in mapping: OrganismAccessionMap) -> [String]? {
        guard !normalizedOrganismName.isEmpty else { return nil }

        if let exact = mapping[normalizedOrganismName], !exact.isEmpty {
            return rankAccessionsByReadSupport(exact)
        }
        if let fuzzy = mapping.first(where: { key, _ in
            key.contains(normalizedOrganismName) || normalizedOrganismName.contains(key)
        }) {
            return rankAccessionsByReadSupport(fuzzy.value)
        }

        // Token-overlap fallback handles minor source typos/variant formatting
        // (e.g. missing first character, shortened years like /40 vs /1940).
        let best = mapping.max { lhs, rhs in
            tokenSimilarity(lhs.key, normalizedOrganismName) < tokenSimilarity(rhs.key, normalizedOrganismName)
        }
        if let best, tokenSimilarity(best.key, normalizedOrganismName) >= 0.75 {
            return rankAccessionsByReadSupport(best.value)
        }
        return nil
    }

    private func accessions(for row: TaxTriageTableRow, sampleId: String? = nil) -> [String]? {
        if let taxID = row.taxId,
           let sampleId,
           let sampleTaxMap = taxIDToAccessionsBySample[sampleId],
           let bySampleTaxID = sampleTaxMap[taxID],
           !bySampleTaxID.isEmpty {
            return rankAccessionsByReadSupport(bySampleTaxID)
        }

        if let taxID = row.taxId, let byTaxID = taxIDToAccessions[taxID], !byTaxID.isEmpty {
            return rankAccessionsByReadSupport(byTaxID)
        }
        return accessions(for: row.organism, sampleId: sampleId)
    }

    private func accessions(for metric: TaxTriageMetric) -> [String]? {
        if let taxID = metric.taxId,
           let sampleId = metric.sample,
           let sampleTaxMap = taxIDToAccessionsBySample[sampleId],
           let bySampleTaxID = sampleTaxMap[taxID],
           !bySampleTaxID.isEmpty {
            return rankAccessionsByReadSupport(bySampleTaxID)
        }

        if let taxID = metric.taxId, let byTaxID = taxIDToAccessions[taxID], !byTaxID.isEmpty {
            return rankAccessionsByReadSupport(byTaxID)
        }

        return accessions(for: metric.organism, sampleId: metric.sample)
    }

    private func accessions(for organismName: String, sampleId: String? = nil) -> [String]? {
        let normalized = normalizedOrganismName(organismName)
        if let sampleId,
           let sampleMapping = organismToAccessionsBySample[sampleId],
           let sampleResolved = lookupAccessions(for: normalized, in: sampleMapping) {
            return sampleResolved
        }
        return lookupAccessions(for: normalized, in: organismToAccessions)
    }

    private func tokenSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = Set(lhs.split(separator: " ").map(String.init))
        let rhsTokens = Set(rhs.split(separator: " ").map(String.init))
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }
        let intersection = lhsTokens.intersection(rhsTokens).count
        let denominator = max(lhsTokens.count, rhsTokens.count)
        guard denominator > 0 else { return 0 }
        return Double(intersection) / Double(denominator)
    }

    private func scheduleDeduplicatedReadCountComputation(for rows: [TaxTriageTableRow]) {
        deduplicatedReadCountTask?.cancel()
        guard let bamURL, let bamIndexURL else { return }
        guard !rows.isEmpty else { return }

        let rowsByReadCount = rows.sorted { $0.reads > $1.reads }
        let provider = AlignmentDataProvider(
            alignmentPath: bamURL.path,
            indexPath: bamIndexURL.path
        )

        deduplicatedReadCountTask = Task { [weak self] in
            guard let self else { return }

            // Resolve reference lengths off the main actor, and only once: a
            // length missing from the header/idxstats parse will never appear
            // by re-running samtools again for the same BAM, so the old
            // per-accession re-parse inside the loop below only added
            // redundant `Process` spawns on the main actor without ever
            // finding anything new.
            if self.accessionLengths.isEmpty {
                await self.parseBamReferenceLengthsOffMain(bamURL: bamURL, indexURL: bamIndexURL)
            }

            for row in rowsByReadCount {
                if Task.isCancelled { return }
                let normalized = self.normalizedOrganismName(row.organism)
                if self.deduplicatedReadCounts[normalized] != nil { continue }

                guard let rowAccessions = self.accessions(for: row), !rowAccessions.isEmpty else {
                    // No accession mapping — can't compute unique reads from BAM.
                    // Leave unique reads as unknown ("—") rather than showing an incorrect
                    // value equal to total reads. The column will remain empty for this organism.
                    continue
                }
                var totalUnique = 0
                var fetchedAny = false

                for accession in rowAccessions {
                    if Task.isCancelled { return }
                    // Missing means skip: the length was already resolved once
                    // above from the full BAM header/idxstats parse.
                    guard let contigLength = self.accessionLengths[accession] else { continue }

                    do {
                        // PERF-04: stream the whole contig through the
                        // uncapped counter rather than fetchReads(maxReads:)
                        // + deduplicatedReadCount(from:), which silently
                        // undercounted any contig with more than 100,000
                        // mapped reads and buffered up to 500 MB of SAM text
                        // per contig to do it.
                        let uniqueCount = try await provider.countUniqueReads(
                            chromosome: accession,
                            start: 0,
                            end: contigLength
                        )
                        guard uniqueCount > 0 else { continue }
                        fetchedAny = true
                        totalUnique += uniqueCount
                    } catch {
                        logger.debug("Failed dedup count for \(row.organism, privacy: .public) (\(accession, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                    }
                }

                if fetchedAny {
                    // Use the actual unique read count from the BAM without capping to
                    // row.reads. The TSV read count may be a filtered/classified subset
                    // while the BAM contains all aligned reads, so capping would produce
                    // an artificially low (wrong) value.
                    let trueUnique = max(1, totalUnique)
                    self.applyUniqueReadCount(trueUnique, for: row.organism)

                    // Compute per-sample estimates by distributing the dedup ratio
                    // across each sample's per-organism read count.
                    self.computePerSampleUniqueReads(
                        normalized: normalized,
                        totalReads: row.reads,
                        uniqueReads: trueUnique
                    )
                } else {
                    // No reads fetched from BAM (accession exists but mapped region is empty).
                    // Leave unique reads as unknown ("—") rather than showing total reads.
                    // This avoids the misleading "unique reads = total reads" display.
                }
            }

            // Persist computed counts to the sidecar so they load instantly next time.
            if !Task.isCancelled, !self.deduplicatedReadCounts.isEmpty {
                self.persistDeduplicatedReadCounts()
            }
        }
    }

    /// Computes per-sample unique reads for each organism by reading each sample's BAM
    /// directly in batch group mode, where every sample has its own BAM file.
    ///
    /// This avoids the estimation error introduced by proportional distribution.
    /// Called from `configureFromDatabase` after `bamFilesBySample` is populated.
    ///
    /// - Parameters:
    ///   - subdirs: The list of per-sample subdirectories scanned during `configureFromDatabase`.
    private func scheduleBatchPerSampleUniqueReadComputation(subdirs: [URL]) {
        deduplicatedReadCountTask?.cancel()
        guard !bamFilesBySample.isEmpty else { return }

        // Snapshot the per-sample BAM map so the task doesn't capture mutable state.
        let bamsBySample = bamFilesBySample

        deduplicatedReadCountTask = Task { [weak self] in
            guard let self else { return }

            // Build per-sample organism→accession mappings and accession lengths
            // without touching the shared `accessionLengths`/`organismToAccessions` dicts.
            // Prefer pre-built sample-scoped mappings from configureFromDatabase(),
            // snapshotted here (Sendable) so the fallback discovery below can run
            // entirely off the main actor.
            let prebuiltOrgToAccessionsBySample = self.organismToAccessionsBySample

            for subdir in subdirs {
                if Task.isCancelled { return }
                let sampleId = subdir.lastPathComponent
                guard let bamURL = bamsBySample[sampleId] else { continue }
                let prebuiltMapping = prebuiltOrgToAccessionsBySample[sampleId] ?? [:]

                // Directory walks (BAM index resolution, GCF mapping discovery) and
                // GCF file parsing are pure given their inputs, so they run in a
                // detached task rather than on the main actor. Only the small,
                // Sendable discovery result below is applied back to `self`.
                let discovery = await Task.detached(priority: .userInitiated) { [weak self] () -> TaxTriageBatchSampleDiscovery in
                    // `self` is only used to reach `nonisolated` helper methods
                    // (pure functions of their arguments); nothing here reads or
                    // writes main-actor-isolated state.
                    guard let self else { return TaxTriageBatchSampleDiscovery(indexURL: nil, organismToAccessions: [:]) }
                    let indexCandidates = self.collectFilesRecursively(in: subdir) { fileURL in
                        let ext = fileURL.pathExtension.lowercased()
                        return ext == "bai" || ext == "csi"
                    }
                    guard let indexURL = self.resolveBamIndex(for: bamURL, allOutputFiles: indexCandidates) else {
                        return TaxTriageBatchSampleDiscovery(indexURL: nil, organismToAccessions: [:])
                    }

                    var localOrgToAccessions = prebuiltMapping
                    if localOrgToAccessions.isEmpty {
                        let gcfFiles = self.collectFilesRecursively(in: subdir) { fileURL in
                            fileURL.lastPathComponent.contains("gcfmapping.tsv")
                        }
                        for gcfURL in gcfFiles {
                            let parsed = self.parseGCFMappingData(url: gcfURL)
                            self.mergeOrganismMappings(parsed, into: &localOrgToAccessions)
                        }
                    }
                    return TaxTriageBatchSampleDiscovery(indexURL: indexURL, organismToAccessions: localOrgToAccessions)
                }.value

                guard let indexURL = discovery.indexURL else {
                    logger.debug("Batch dedup: no BAM index for sample \(sampleId, privacy: .public)")
                    continue
                }
                let localOrgToAccessions = discovery.organismToAccessions
                guard !localOrgToAccessions.isEmpty else {
                    logger.debug("Batch dedup: no GCF mapping for sample \(sampleId, privacy: .public)")
                    continue
                }

                // Parse accession lengths from BAM header for this sample's references,
                // off the main actor: the samtools spawn and pipe drains run in a
                // detached task, draining stdout and stderr concurrently so a noisy
                // samtools cannot deadlock the caller. This is the batch-mode twin of
                // the single-sample `parseBamReferenceLengthsOffMain` path above.
                var localLengths: [String: Int] = [:]
                if let samtoolsPath = ManagedToolLocator.managedToolExecutablePath(.samtools) {
                    let headerBamPath = bamURL.path
                    let snapshot = await Task.detached(priority: .userInitiated) {
                        Self.parseBamReferenceLengthsSnapshot(
                            bamPath: headerBamPath,
                            indexPath: nil,
                            samtoolsPath: samtoolsPath
                        )
                    }.value
                    localLengths = snapshot.accessionLengths
                }

                let provider = AlignmentDataProvider(
                    alignmentPath: bamURL.path,
                    indexPath: indexURL.path
                )

                // Compute per-organism unique reads for this sample.
                for (normalizedOrganism, accessions) in localOrgToAccessions {
                    if Task.isCancelled { return }
                    var totalUnique = 0
                    var fetchedAny = false

                    for accession in accessions {
                        if Task.isCancelled { return }
                        guard let contigLength = localLengths[accession] else { continue }

                        do {
                            // PERF-04: uncapped streaming count (see the
                            // single-sample path above for the full
                            // rationale).
                            let uniqueCount = try await provider.countUniqueReads(
                                chromosome: accession,
                                start: 0,
                                end: contigLength
                            )
                            guard uniqueCount > 0 else { continue }
                            fetchedAny = true
                            totalUnique += uniqueCount
                        } catch {
                            logger.debug("Batch dedup: failed for \(normalizedOrganism, privacy: .public) (\(accession, privacy: .public)) in \(sampleId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        }
                    }

                    if fetchedAny {
                        // Use the BAM-derived unique count — no capping against TSV read count.
                        let trueUnique = max(1, totalUnique)
                        self.perSampleDeduplicatedReadCounts[normalizedOrganism, default: [:]][sampleId] = trueUnique
                        // Update only this (organism, sample) key through the cached
                        // index, and coalesce the table reload, rather than rescanning
                        // every computed pair (syncUniqueReadsToFlatTable) once per
                        // organism — this was the O(organisms x samples x rows) pass
                        // that repainted the table once per organism during a batch run.
                        self.updateFlatTableKey(normalizedOrganism: normalizedOrganism, sampleId: sampleId, uniqueReadCount: trueUnique)
                        self.scheduleCoalescedUniqueReadsColumnReload()
                    }
                }
            }

            // Persist computed per-sample counts.
            if !Task.isCancelled, !self.perSampleDeduplicatedReadCounts.isEmpty {
                self.persistDeduplicatedReadCounts()

                // Also write the batch-level cache so the flat table loads instantly next time.
                if let batchURL = self.batchGroupURL {
                    let cacheURL = batchURL.appendingPathComponent(Self.batchUniqueReadsCacheFilename)
                    self.persistBatchUniqueReadsCache(to: cacheURL)
                }

                // Update the materialized batch manifest with the new unique reads values
                // so future opens get fully-populated rows from the manifest cache.
                self.updateBatchManifestUniqueReads()
            }
        }
    }

    /// Computes per-sample unique reads for an organism by applying the dedup ratio
    /// to each sample's total read count from the metrics.
    private func computePerSampleUniqueReads(normalized: String, totalReads: Int, uniqueReads: Int) {
        guard totalReads > 0, sampleIds.count > 1 else { return }
        let dedupRatio = Double(uniqueReads) / Double(totalReads)

        var perSample: [String: Int] = [:]
        for metric in metrics {
            guard let sample = metric.sample else { continue }
            let metricNormalized = normalizedOrganismName(metric.organism)
            guard metricNormalized == normalized else { continue }
            let estimated = Int(round(Double(metric.reads) * dedupRatio))
            perSample[sample] = ClassifierUniqueReads.normalizedOrFloor(
                stored: estimated,
                readCount: metric.reads
            )
        }

        if !perSample.isEmpty {
            perSampleDeduplicatedReadCounts[normalized] = perSample
            syncUniqueReadsToFlatTable()
        }
    }

    /// Saves current deduplicated read counts into the TaxTriage result sidecar.
    private func persistDeduplicatedReadCounts() {
        // Database mode reads the sidecar with relocated paths; it keeps its
        // unique-read counts in the batch cache and never rewrites the sidecar.
        guard !isBatchGroupMode, var result = taxTriageResult else { return }
        result.deduplicatedReadCounts = deduplicatedReadCounts
        result.perSampleDeduplicatedReadCounts = perSampleDeduplicatedReadCounts.isEmpty ? nil : perSampleDeduplicatedReadCounts
        do {
            try result.save()
            logger.info("Persisted \(self.deduplicatedReadCounts.count) deduplicated read counts to sidecar")
        } catch {
            logger.warning("Failed to persist deduplicated read counts: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Batch Unique Reads Cache (batch-unique-reads.json)

    /// Loads the batch-level unique reads cache from `<batchDir>/batch-unique-reads.json`.
    ///
    /// The cache maps `"sampleId\torganism"` keys to unique read counts so the flat table
    /// can be populated immediately on second open without re-scanning BAM files.
    ///
    /// - Returns: The decoded cache dictionary, or `nil` if the file is absent or malformed.
    private func loadBatchUniqueReadsCache(from url: URL) -> [String: Int]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        guard let wrapper = try? decoder.decode(BatchUniqueReadsCache.self, from: data) else { return nil }
        return wrapper.sampleOrganism
    }

    /// Persists `batchFlatTableView.uniqueReadsByKey` to `<batchDir>/batch-unique-reads.json`
    /// so the flat table can be restored instantly on the next open.
    private func persistBatchUniqueReadsCache(to url: URL) {
        var normalizedCounts = batchFlatTableView.uniqueReadsByKey
        for row in allBatchGroupRows {
            let key = "\(row.sample ?? "")\t\(row.organism)"
            guard normalizedCounts[key] != nil else { continue }
            let readCount = batchFlatTableView.totalReadsByKey[key] ?? row.reads
            normalizedCounts[key] = ClassifierUniqueReads.normalized(
                stored: normalizedCounts[key],
                readCount: readCount
            )
        }
        let cache = BatchUniqueReadsCache(sampleOrganism: normalizedCounts)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(cache)
            try data.write(to: url)
            logger.info("Persisted batch-unique-reads.json with \(cache.sampleOrganism.count) entries")
        } catch {
            logger.warning("Failed to persist batch-unique-reads.json: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func applyReadStats(totalReads: Int? = nil, uniqueReads: Int, for organismName: String) {
        let key = normalizedOrganismName(organismName)
        let cacheReadCount = totalReads
            ?? organismTableView.rows.first { normalizedOrganismName($0.organism) == key }?.reads
            ?? 0
        let cacheUnique = ClassifierUniqueReads.normalizedOrFloor(
            stored: uniqueReads,
            readCount: cacheReadCount
        )
        deduplicatedReadCounts[key] = cacheUnique

        var changed = false
        let updated = organismTableView.rows.map { row -> TaxTriageTableRow in
            guard normalizedOrganismName(row.organism) == key else { return row }
            let resolvedReads = totalReads ?? row.reads
            let safeUnique = ClassifierUniqueReads.normalizedOrFloor(
                stored: uniqueReads,
                readCount: resolvedReads
            )
            if row.uniqueReads == safeUnique, row.reads == resolvedReads { return row }
            changed = true
            return row.with(reads: resolvedReads, uniqueReads: safeUnique)
        }

        if changed {
            organismTableView.rows = updated
        }

        // Refresh batch overview if it's visible so unique reads facet updates live
        if !batchOverviewView.isHidden, batchOverviewView.currentFacet == .uniqueReads {
            let negControlIds = negativeControlSampleIds()
            let labels = buildSampleLabelsFromCSVMetadata()
            batchOverviewView.configure(metrics: metrics, sampleIds: sampleIds, negativeControlSampleIds: negControlIds, sampleLabels: labels, perSampleDeduplicatedReadCounts: perSampleDeduplicatedReadCounts)
        }

        if normalizedOrganismName(selectedOrganismName ?? "") == key {
            if let totalReads {
                selectedReadCount = totalReads
            }
            updateActionBarForOrganism(
                name: selectedOrganismName,
                readCount: selectedReadCount,
                uniqueReadCount: cacheUnique
            )
        }
    }

    private func applyUniqueReadCount(_ uniqueReads: Int, for organismName: String) {
        applyReadStats(uniqueReads: uniqueReads, for: organismName)
    }

    private func applyBatchFlatTableReadStats(
        sampleId: String,
        organism: String,
        totalReads: Int,
        uniqueReads: Int
    ) {
        let key = "\(sampleId)\t\(organism)"
        let safeUnique = ClassifierUniqueReads.normalizedOrFloor(
            stored: uniqueReads,
            readCount: totalReads
        )
        // Only apply BAM-computed values for rows that don't already have
        // DB-cached counts. The SQLite database is the source of truth for
        // read counts — the miniBAM viewer should not overwrite them.
        let hadTotal = batchFlatTableView.totalReadsByKey[key] != nil
        let hadUnique = batchFlatTableView.uniqueReadsByKey[key] != nil
        if !hadTotal {
            batchFlatTableView.totalReadsByKey[key] = totalReads
        }
        if !hadUnique {
            batchFlatTableView.uniqueReadsByKey[key] = safeUnique
        }
        if !hadTotal || !hadUnique {
            batchFlatTableView.reloadReadStatsColumns()
        }

        let normalized = normalizedOrganismName(organism)
        if !hadUnique {
            perSampleDeduplicatedReadCounts[normalized, default: [:]][sampleId] = safeUnique
        }

        if selectedBatchSampleId == sampleId, selectedBatchOrganismName == organism {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = ","
            let totalReadsText = formatter.string(from: NSNumber(value: totalReads)) ?? "\(totalReads)"
            let uniqueReadsText = formatter.string(from: NSNumber(value: safeUnique)) ?? "\(safeUnique)"
            actionBar.updateInfoText("\(organism) — \(totalReadsText) reads (\(uniqueReadsText) unique)")
        }
    }

    /// Merges `perSampleDeduplicatedReadCounts` into `batchFlatTableView.uniqueReadsByKey`
    /// and reloads the table so the Unique Reads column reflects the latest computed values.
    ///
    /// Called after a full recompute (e.g. loading a persisted cache) so the batch
    /// flat table stays current. Uses merge semantics so that DB-cached values are
    /// preserved for rows not yet recomputed from BAM.
    ///
    /// The per-(organism, sample) incremental path during batch dedup computation
    /// uses `applyOneUniqueReadCountToFlatTable` instead, which updates a single
    /// key through the cached index rather than rescanning every computed pair
    /// and re-linear-scanning `allBatchGroupRows` for each one (previously
    /// O(organisms x samples x rows) over the course of a batch computation).
    private func syncUniqueReadsToFlatTable() {
        guard isBatchGroupMode || isMultiSampleSingleResultMode else { return }
        for (normalizedOrganism, perSample) in perSampleDeduplicatedReadCounts {
            for (sampleId, count) in perSample {
                updateFlatTableKey(normalizedOrganism: normalizedOrganism, sampleId: sampleId, uniqueReadCount: count)
            }
        }
        // Reload visible rows without resetting scroll position.
        batchFlatTableView.reloadUniqueReadsColumn()
    }

    /// Updates a single (organism, sample) entry in `batchFlatTableView.uniqueReadsByKey`
    /// using the cached row index, without touching any other key or reloading the table.
    /// Callers that update many keys in a loop (batch dedup computation) should call this
    /// per key and reload the table once at the end, rather than calling
    /// `syncUniqueReadsToFlatTable()` per key.
    private func updateFlatTableKey(normalizedOrganism: String, sampleId: String, uniqueReadCount: Int) {
        // Find the display organism name by matching normalisation.
        // Prefer the raw organism name from allBatchGroupRows for accurate key construction.
        let rowIndex = organismSampleRowIndex()
        let indexKey = "\(normalizedOrganism)\t\(sampleId)"
        let matchedRow = rowIndex[indexKey]
        let displayOrganism = matchedRow?.organism ?? normalizedOrganism
        let key = "\(sampleId)\t\(displayOrganism)"
        let readCount = batchFlatTableView.totalReadsByKey[key] ?? matchedRow?.reads ?? 0
        batchFlatTableView.uniqueReadsByKey[key] = ClassifierUniqueReads.normalizedOrFloor(
            stored: uniqueReadCount,
            readCount: readCount
        )
    }

    private nonisolated func resolveBamIndex(for bamURL: URL, allOutputFiles: [URL]) -> URL? {
        let fm = FileManager.default
        let adjacentBAI = URL(fileURLWithPath: bamURL.path + ".bai")
        if fm.fileExists(atPath: adjacentBAI.path) { return adjacentBAI }

        let adjacentCSI = URL(fileURLWithPath: bamURL.path + ".csi")
        if fm.fileExists(atPath: adjacentCSI.path) { return adjacentCSI }

        if let externalIndex = allOutputFiles.first(where: {
            $0.lastPathComponent == "\(bamURL.lastPathComponent).bai"
                || $0.lastPathComponent == "\(bamURL.lastPathComponent).csi"
        }) {
            return externalIndex
        }
        // Display never materializes an index.  Only a final retained BAI/CSI
        // can be passed to the detached evidence validator.
        return nil
    }

    /// Parses BAM reference lengths from samtools output.
    ///
    /// Uses `samtools view -H` for index-independent sequence lengths and
    /// `samtools idxstats` for mapped-read counts when possible.
    private func parseBamReferenceLengths(bamURL: URL, indexURL: URL? = nil) {
        guard let samtoolsPath = ManagedToolLocator.managedToolExecutablePath(.samtools) else {
            logger.warning("Cannot parse BAM references: samtools not found")
            return
        }
        let snapshot = Self.parseBamReferenceLengthsSnapshot(
            bamPath: bamURL.path,
            indexPath: indexURL?.path,
            samtoolsPath: samtoolsPath
        )
        mergeBAMReferenceSnapshot(snapshot)
    }

    /// Off-main variant of `parseBamReferenceLengths`. The samtools spawns and
    /// blocking pipe reads happen in a detached task; only the final,
    /// `Sendable` snapshot merge touches `self` on the main actor.
    private func parseBamReferenceLengthsOffMain(bamURL: URL, indexURL: URL? = nil) async {
        guard let samtoolsPath = ManagedToolLocator.managedToolExecutablePath(.samtools) else {
            logger.warning("Cannot parse BAM references: samtools not found")
            return
        }
        let bamPath = bamURL.path
        let indexPath = indexURL?.path
        let snapshot = await Task.detached(priority: .userInitiated) {
            Self.parseBamReferenceLengthsSnapshot(
                bamPath: bamPath,
                indexPath: indexPath,
                samtoolsPath: samtoolsPath
            )
        }.value
        mergeBAMReferenceSnapshot(snapshot)
    }

    private nonisolated static func parseBamReferenceLengthsSnapshot(
        bamPath: String,
        indexPath: String?,
        samtoolsPath: String
    ) -> TaxTriageBAMReferenceSnapshot {
        let samtoolsURL = URL(fileURLWithPath: samtoolsPath)
        var accessionLengths: [String: Int] = [:]
        var accessionMappedReadCounts: [String: Int] = [:]
        var parsedMappedReads = false

        func runSamtools(_ arguments: [String]) -> (status: Int32, stdout: String, stderr: String)? {
            let proc = Process()
            proc.executableURL = samtoolsURL
            proc.arguments = arguments
            let outPipe = Pipe()
            let errPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = errPipe
            do {
                try proc.run()
                // Read stdout and stderr CONCURRENTLY to prevent pipe deadlock:
                // reading stdout to EOF before touching stderr blocks forever if
                // samtools writes more than one pipe buffer (64 KB) of warnings.
                let outBox = TaxTriagePipeReadBox()
                let errBox = TaxTriagePipeReadBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                group.wait()
                proc.waitUntilExit()
                return (
                    proc.terminationStatus,
                    String(data: outBox.data, encoding: .utf8) ?? "",
                    String(data: errBox.data, encoding: .utf8) ?? ""
                )
            } catch {
                logger.warning("Failed to run samtools \(arguments.joined(separator: " "), privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        // 1) Sequence lengths from header (does not require an index).
        if let header = runSamtools(["view", "-H", bamPath]), header.status == 0 {
            for line in header.stdout.components(separatedBy: .newlines) where line.hasPrefix("@SQ") {
                let fields = line.components(separatedBy: "\t")
                var name: String?
                var length: Int?
                for field in fields {
                    if field.hasPrefix("SN:") {
                        name = String(field.dropFirst(3))
                    } else if field.hasPrefix("LN:") {
                        length = Int(field.dropFirst(3))
                    }
                }
                if let name, let length, length > 0 {
                    accessionLengths[name] = length
                }
            }
        }

        // 2) idxstats for mapped read counts (prefer explicit index path when available).
        let fm = FileManager.default
        var idxstatsAttempts: [[String]] = []
        if let indexPath, fm.fileExists(atPath: indexPath) {
            idxstatsAttempts.append(["idxstats", "-X", bamPath, indexPath])
        }
        idxstatsAttempts.append(["idxstats", bamPath])

        for args in idxstatsAttempts {
            guard let result = runSamtools(args) else { continue }
            guard result.status == 0 else {
                if !result.stderr.isEmpty {
                    logger.warning("samtools \(args.joined(separator: " "), privacy: .public) failed: \(result.stderr, privacy: .public)")
                }
                continue
            }

            for line in result.stdout.components(separatedBy: .newlines) {
                let cols = line.components(separatedBy: "\t")
                guard cols.count >= 4 else { continue }
                let ref = cols[0].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !ref.isEmpty, ref != "*" else { continue }
                if let length = Int(cols[1]), length > 0 {
                    accessionLengths[ref] = length
                }
                if let mappedReads = Int(cols[2]) {
                    accessionMappedReadCounts[ref] = mappedReads
                    parsedMappedReads = true
                }
            }
            break
        }

        return TaxTriageBAMReferenceSnapshot(
            accessionLengths: accessionLengths,
            accessionMappedReadCounts: accessionMappedReadCounts,
            parsedMappedReads: parsedMappedReads
        )
    }

    private func mergeBAMReferenceSnapshot(_ snapshot: TaxTriageBAMReferenceSnapshot) {
        accessionLengths.merge(snapshot.accessionLengths) { _, new in new }
        accessionMappedReadCounts.merge(snapshot.accessionMappedReadCounts) { _, new in new }

        let refCount = accessionLengths.count
        if snapshot.parsedMappedReads {
            logger.info("Parsed BAM references: \(refCount) contigs, mapped-read stats for \(self.accessionMappedReadCounts.count) contigs")
        } else {
            logger.info("Parsed BAM references: \(refCount) contigs (mapped-read stats unavailable)")
        }
    }

    private func displayTaxTriageMiniBAM(
        bamURL: URL,
        indexURL: URL?,
        accessions: [String]
    ) {
#if DEBUG
        miniBAMLoadCount += 1
#endif
        bamReferenceLengthLoadTask?.cancel()
        bamReferenceLengthLoadGeneration = UUID()
        let generation = bamReferenceLengthLoadGeneration

        guard !accessions.isEmpty else {
            alignmentEvidenceViewer?.clear()
            return
        }

        if displayTaxTriageMiniBAMIfLengthKnown(
            bamURL: bamURL,
            indexURL: indexURL,
            accessions: accessions
        ) {
            return
        }

        guard let samtoolsPath = ManagedToolLocator.managedToolExecutablePath(.samtools) else {
            alignmentEvidenceViewer?.clear()
            logger.warning("Cannot resolve BAM reference lengths for selected TaxTriage row: samtools not found")
            return
        }

        let bamPath = bamURL.path
        let indexPath = indexURL?.path
        bamReferenceLengthLoadTask = Task.detached(priority: .userInitiated) { [weak self, accessions] in
            let snapshot = Self.parseBamReferenceLengthsSnapshot(
                bamPath: bamPath,
                indexPath: indexPath,
                samtoolsPath: samtoolsPath
            )
            guard !Task.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    guard self.bamReferenceLengthLoadGeneration == generation else { return }
                    self.mergeBAMReferenceSnapshot(snapshot)
                    if !self.displayTaxTriageMiniBAMIfLengthKnown(
                        bamURL: bamURL,
                        indexURL: indexURL,
                        accessions: accessions
                    ) {
                        self.alignmentEvidenceViewer?.clear()
                    }
                }
            }
        }
    }

    @discardableResult
    private func displayTaxTriageMiniBAMIfLengthKnown(
        bamURL: URL,
        indexURL: URL?,
        accessions: [String]
    ) -> Bool {
        guard let resolvedAccession = accessions.first(where: { accessionLengths[$0] != nil }),
              let contigLength = accessionLengths[resolvedAccession] else {
            return false
        }

        guard let indexURL, let viewer = alignmentEvidenceViewer else {
            alignmentEvidenceViewer?.clear()
            return false
        }
        let sampleID = selectedBatchSampleId
            ?? (selectedSampleIndex > 0 && selectedSampleIndex <= sampleIds.count
                ? sampleIds[selectedSampleIndex - 1]
                : "selected-sample")
        let kind: ClassifierAlignmentIndex.Kind = switch indexURL.pathExtension.lowercased() {
        case "csi": .csi
        case "crai": .crai
        default: .bai
        }
        do {
            let resultURL = batchGroupURL ?? bamURL.deletingLastPathComponent()
            let reference = downloadedReferenceCandidate(
                sampleID: sampleID,
                accession: resolvedAccession,
                expectedLength: contigLength,
                resultURL: resultURL
            )
            let request = try ClassifierAlignmentEvidenceRequest(
                workflow: .taxTriage,
                resultIdentity: .init(stableID: resultURL.standardizedFileURL.path, finalResultURL: resultURL, provenanceID: "taxtriage:\(resultURL.lastPathComponent)"),
                bamURL: bamURL, index: .init(url: indexURL, kind: kind),
                sample: .init(canonicalID: sampleID),
                contig: .init(name: resolvedAccession, expectedLength: contigLength),
                referenceCandidate: reference,
                presentation: .init(workflowLabel: "TaxTriage", resultLabel: resultURL.lastPathComponent, sampleLabel: sampleID, contigLabel: resolvedAccession)
            )
            viewer.display(request)
        } catch { viewer.clear(); return false }
        return true
    }

    private func downloadedReferenceCandidate(
        sampleID: String,
        accession: String,
        expectedLength: Int,
        resultURL: URL
    ) -> ClassifierAlignmentReferenceCandidate? {
        let name = "\(sampleID).dwnld.references.fasta"
        if let storedMember = retainedReferencesBySample[sampleID],
           storedMember.lastPathComponent == name,
           FileManager.default.fileExists(atPath: storedMember.path) {
            return .init(fastaURL: storedMember, recordName: accession, expectedLength: expectedLength)
        }
        guard let storedMember = taxTriageResult?.allOutputFiles.first(where: {
            $0.lastPathComponent == name && $0.standardizedFileURL.path.hasPrefix(resultURL.standardizedFileURL.path)
        }), FileManager.default.fileExists(atPath: storedMember.path) else {
            return nil
        }
        return .init(fastaURL: storedMember, recordName: accession, expectedLength: expectedLength)
    }

    // MARK: - Setup: BLAST Drawer

    private func setupBlastDrawer() {
        blastDrawer.translatesAutoresizingMaskIntoConstraints = false
        blastDrawer.isHidden = true
        view.addSubview(blastDrawer)

        blastDrawer.onRerunBlast = { [weak self] in
            guard let self, let result = self.lastBlastResult else { return }
            let organism = TaxTriageOrganism(
                name: result.taxonName, score: 0, reads: result.totalReads,
                coverage: nil, taxId: result.taxId, rank: nil
            )
            let orgAccessions = self.accessions(for: result.taxonName)
            self.onBlastVerification?(organism, result.totalReads, orgAccessions, self.bamURL, self.bamIndexURL)
        }
    }

    // MARK: - BLAST Drawer Public API

    /// Shows BLAST verification results in the bottom drawer, opening it if needed.
    public func showBlastResults(_ result: BlastVerificationResult) {
        lastBlastResult = result
        blastDrawer.showResults(result)
        if !isBlastDrawerOpen {
            toggleBlastDrawer()
        }
    }

    /// Shows BLAST loading state in the bottom drawer.
    public func showBlastLoading(phase: BlastJobPhase, requestId: String?) {
        blastDrawer.showLoading(phase: phase, requestId: requestId)
        if !isBlastDrawerOpen {
            toggleBlastDrawer()
        }
    }

    /// Shows BLAST failure state in the bottom drawer.
    public func showBlastFailure(_ message: String) {
        blastDrawer.showFailure(message: message)
        if !isBlastDrawerOpen {
            toggleBlastDrawer()
        }
    }

    /// Toggles the BLAST results drawer open or closed with animation.
    public func toggleBlastDrawer() {
        let drawerHeight: CGFloat = 250
        let targetHeight: CGFloat = isBlastDrawerOpen ? 0 : drawerHeight

        blastDrawer.isHidden = false
        blastDrawerHeightConstraint?.constant = targetHeight

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            self.view.layoutSubtreeIfNeeded()
        }

        isBlastDrawerOpen = !isBlastDrawerOpen
        if !isBlastDrawerOpen {
            blastDrawer.isHidden = true
        }
    }

    // MARK: - Setup: Batch Flat Table View

    /// Adds the batch flat table view as a sibling of `splitView` with identical
    /// Adds the batch flat table view inside the right pane container so that the
    /// split view (and thus the left/miniBAM pane) remains visible in batch group mode.
    /// Hidden by default; shown when `configureFromDatabase` is called.
    private func setupBatchFlatTableView() {
        batchFlatTableView.translatesAutoresizingMaskIntoConstraints = false
        batchFlatTableView.isHidden = true
        rightPaneContainer.addSubview(batchFlatTableView)
        NSLayoutConstraint.activate([
            batchFlatTableView.topAnchor.constraint(equalTo: rightPaneContainer.topAnchor),
            batchFlatTableView.bottomAnchor.constraint(equalTo: rightPaneContainer.bottomAnchor),
            batchFlatTableView.leadingAnchor.constraint(equalTo: rightPaneContainer.leadingAnchor),
            batchFlatTableView.trailingAnchor.constraint(equalTo: rightPaneContainer.trailingAnchor),
        ])
    }

    /// Updates the persisted `TaxTriageBatchManifest` with newly computed unique reads values.
    ///
    /// Called from background unique-reads computation completion so that future opens
    /// get the fully-populated manifest including exact BAM-derived counts.
    private func updateBatchManifestUniqueReads() {
        guard let batchURL = batchGroupURL,
              var manifest = MetagenomicsBatchResultStore.loadTaxTriageBatchManifest(from: batchURL)
        else { return }

        for i in manifest.cachedRows.indices {
            let row = manifest.cachedRows[i]
            let key = "\(row.sample)\t\(row.organism)"
            if let uniqueReads = batchFlatTableView.uniqueReadsByKey[key] {
                let safeUnique = ClassifierUniqueReads.normalizedOrFloor(
                    stored: uniqueReads,
                    readCount: row.reads
                )
                manifest.cachedRows[i] = TaxTriageBatchManifest.CachedRow(
                    sample: row.sample,
                    organism: row.organism,
                    tassScore: row.tassScore,
                    reads: row.reads,
                    uniqueReads: safeUnique,
                    confidence: row.confidence,
                    coverageBreadth: row.coverageBreadth,
                    coverageDepth: row.coverageDepth,
                    abundance: row.abundance
                )
            }
        }

        do {
            try MetagenomicsBatchResultStore.saveTaxTriageBatchManifest(manifest, to: batchURL)
            logger.info("Updated TaxTriage batch manifest with unique reads")
        } catch {
            logger.warning("Failed to update TaxTriage batch manifest: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - SQLite Database Mode

    /// Configures this VC from a pre-built SQLite database instead of parsing
    /// per-sample files or manifest caches.
    ///
    /// Sets `isBatchGroupMode = true` so the existing sample selection and filter
    /// paths operate correctly. Populates `allBatchGroupRows`, sample entries,
    /// and BAM lookups from the database, then shows the flat table.
    public func configureFromDatabase(_ db: TaxTriageDatabase, resultURL: URL) {
        self.taxTriageDatabase = db
        self.batchGroupURL = resultURL
        self.isBatchGroupMode = true
        self.didLoadFromManifestCache = true
        self.isShowingDatabaseOverview = false
        self.pendingDatabaseRowSelection = nil
        self.loadedDatabaseSampleSelection = nil
        batchFlatTableView.resultIdentity = resultURL.standardizedFileURL.path

        // The run's sidecar (taxtriage-result.json) and its config drive Open
        // Report, Copy Summary, the Provenance popover, Export Batch Report,
        // CSV sample labels and negative-control flags. It is optional: a
        // result folder without it still shows every database row.
        loadResultSidecar(from: resultURL)
        organismTableView.metadataColumns.persistenceKey = "taxtriage.organisms:\(resultURL.standardizedFileURL.path)"

        // Fetch all samples from the DB.
        let sampleList = (try? db.fetchSamples()) ?? []
        sampleIds = sampleList.map(\.sample).sorted()

        // Build sample entries for the Inspector picker.
        sampleEntries = sampleIds.map { sid in
            let count = sampleList.first(where: { $0.sample == sid })?.organismCount ?? 0
            return TaxTriageSampleEntry(
                id: sid,
                displayName: FASTQDisplayNameResolver.resolveDisplayName(sampleId: sid, projectURL: nil),
                organismCount: count
            )
        }
        samplePickerState = ClassifierSamplePickerState(allSamples: Set(sampleIds))
        samplePickerState.selectedSamples = Set(sampleIds)
        resolvedDisplayNames = Dictionary(
            uniqueKeysWithValues: sampleEntries.map { ($0.id, $0.displayName) }
        ).merging(buildSampleLabelsFromCSVMetadata()) { _, csvLabel in csvLabel }

        // UX-03 (reproduced): `sampleFilterControl` is created with a single
        // "All Samples" segment and was never rebuilt to match the loaded
        // sample count. The ⌘]/⌘[/⌘0 handlers in `performKeyEquivalent`
        // index into this control by `sampleIds.count`, so on any real
        // multi-sample batch this crashed with an out-of-bounds segment
        // index the moment the shortcut fired (reachable or not). Rebuild
        // the segments here so the control's segment count always matches
        // `sampleIds`.
        rebuildSampleFilterSegments()

        resetDatabaseLoadedRows()

        // Wire batch flat table callbacks (same pattern as configureFromDatabase).
        batchFlatTableView.metadataColumns.isMultiSampleMode = true
        batchFlatTableView.onRowSelected = { [weak self] row in
            guard let self else { return }
            self.actionBar.updateInfoText("1 row selected")
            self.actionBar.setBlastEnabled(true)
            self.actionBar.setExtractEnabled(self.hasExtractableResultPath)
            self.hideMultiSelectionPlaceholder()
            self.selectedBatchSampleId = row.sample
            self.selectedBatchOrganismName = row.organism

            // Reveal the miniBAM detail pane ONLY when the selected organism has
            // BAM alignment data to display. Showing it unconditionally left a
            // large empty pane for organisms without alignments — including the
            // top row auto-selected on initial load — which read as a blank
            // viewport until the user changed the layout.
            let bamURL = row.sample.flatMap { self.bamFilesBySample[$0] }
            let accessions = self.accessions(for: row) ?? []
            if let bamURL, !accessions.isEmpty {
                self.revealMiniBAMDetailPaneIfNeeded()
                self.displayTaxTriageMiniBAM(
                    bamURL: bamURL,
                    indexURL: row.sample.flatMap { self.bamIndexesBySample[$0] }
                        ?? resolveBamIndex(for: bamURL, allOutputFiles: []),
                    accessions: accessions
                )
            } else {
                self.alignmentEvidenceViewer?.clear()
                self.collapseMiniBAMDetailPane()
            }
        }
        batchFlatTableView.onMultipleRowsSelected = { [weak self] rows in
            guard let self else { return }
            self.actionBar.updateInfoText("\(rows.count) rows selected")
            self.actionBar.setBlastEnabled(false, reason: "Select a single row to use BLAST Verify")
            self.actionBar.setExtractEnabled(self.hasExtractableResultPath)
            self.showMultiSelectionPlaceholder(count: rows.count)
            // Hide the left pane when multiple rows are selected — the
            // miniBAM viewer can only show one organism at a time.
            self.collapseMiniBAMDetailPane()
        }
        batchFlatTableView.onSelectionCleared = { [weak self] in
            guard let self else { return }
            self.actionBar.updateInfoText("Select an organism to view details")
            self.actionBar.setBlastEnabled(false, reason: "Select a row to use BLAST Verify")
            self.hideMultiSelectionPlaceholder()
            self.selectedBatchSampleId = nil
            self.selectedBatchOrganismName = nil
            self.alignmentEvidenceViewer?.clear()
            // Nothing selected -> collapse the empty detail pane so the organism
            // table keeps the full viewport.
            self.collapseMiniBAMDetailPane()
        }

        // Show the flat table. The Inspector's Sample Filter checklist
        // (samplePickerState) is the source of truth for which samples are
        // loaded. The segmented control above the table is a shortcut into
        // it for multi-sample results: "All Samples" ticks every sample and
        // shows the organism-by-sample overview grid, and a sample segment
        // ticks only that sample. rebuildSampleFilterSegments() above hides
        // both controls when there is only one sample.
        blastDrawer.isHidden = true
        organismTableView.isHidden = true
        batchOverviewView.isHidden = true
        batchFlatTableView.isHidden = false
        collapseMiniBAMDetailPane()
        syncSampleFilterControlToPickerState()
        loadContaminationRiskOrganisms(from: db)

        // Show the organism search field.
        organismSearchField.isHidden = false
        updateFilterRowHeightForContentTypography()
        sampleFilterTopSpacingConstraint?.constant = 4
        sampleFilterBottomSpacingConstraint?.constant = 4

        summaryBar.updateBatch(
            sampleCount: sampleEntries.count,
            totalOrganisms: sampleList.reduce(0) { $0 + $1.organismCount }
        )

        applyBatchGroupFilter()

        logger.info("configureFromDatabase: scheduled paged loading across \(self.sampleIds.count) samples from SQLite")
    }

    private func resetDatabaseLoadedRows() {
        databaseRowLoadTask?.cancel()
        databaseRowLoadGeneration = UUID()
        shouldSelectTopDatabaseRowAfterLoad = true
        allBatchGroupRows = []
        batchFlatTableView.uniqueReadsByKey = [:]
        batchFlatTableView.totalReadsByKey = [:]
        batchFlatTableView.configure(rows: [])
        bamFilesBySample = [:]
        bamIndexesBySample = [:]
        retainedReferencesBySample = [:]
        organismToAccessionsBySample = [:]
        taxIDToAccessionsBySample = [:]
        mergedOrganismToAccessions = [:]
        mergedTaxIDToAccessions = [:]
        organismToAccessions = [:]
        taxIDToAccessions = [:]
        accessionLengths = [:]
    }

    private func reloadDatabaseRowsForCurrentFilter() {
        guard let db = taxTriageDatabase, let state = samplePickerState else { return }

        databaseRowLoadTask?.cancel()
        let generation = UUID()
        databaseRowLoadGeneration = generation

        let selectedSamples = sampleIds.filter { state.selectedSamples.contains($0) }
        loadedDatabaseSampleSelection = state.selectedSamples
        let searchText = organismSearchText
        let resultURL = batchGroupURL
        let pageSize = databaseRowsPageSize
        shouldSelectTopDatabaseRowAfterLoad = true

        allBatchGroupRows = []
        batchFlatTableView.uniqueReadsByKey = [:]
        batchFlatTableView.totalReadsByKey = [:]
        batchFlatTableView.configure(rows: [])
        bamFilesBySample = [:]
        bamIndexesBySample = [:]
        retainedReferencesBySample = [:]
        organismToAccessionsBySample = [:]
        taxIDToAccessionsBySample = [:]
        mergedOrganismToAccessions = [:]
        mergedTaxIDToAccessions = [:]
        organismToAccessions = [:]
        taxIDToAccessions = [:]
        accessionLengths = [:]
        summaryBar.updateBatch(sampleCount: sampleEntries.count, totalOrganisms: 0)

        guard !selectedSamples.isEmpty else { return }

        databaseRowLoadTask = Task { [weak self, db, selectedSamples, searchText, resultURL, pageSize, generation] in
            var offset = 0
            while !Task.isCancelled {
                let pageOffset = offset
                let loadResult = await Task.detached(priority: .userInitiated) {
                    () -> TaxTriageDatabasePageLoadResult in
                    do {
                        let page = try db.fetchRowsPage(
                            samples: selectedSamples,
                            limit: pageSize,
                            offset: pageOffset,
                            organismSearchText: searchText
                        )
                        let snapshot = makeTaxTriageDatabasePageSnapshot(
                            rows: page.rows,
                            resultURL: resultURL,
                            totalMatchingRows: page.totalMatchingRows
                        )
                        return .success(snapshot)
                    } catch {
                        return .failure(error.localizedDescription)
                    }
                }.value

                guard let self, !Task.isCancelled, self.databaseRowLoadGeneration == generation else { return }

                switch loadResult {
                case .success(let snapshot):
                    self.mergeDatabasePageSnapshot(snapshot)
                    self.batchFlatTableView.configure(rows: self.allBatchGroupRows)
                    self.selectTopDatabaseRowAfterInitialPageIfNeeded()
                    if self.isDatabaseOverviewVisible {
                        self.reconfigureDatabaseOverviewGrid()
                    }
                    self.summaryBar.updateBatch(
                        sampleCount: self.sampleEntries.count,
                        totalOrganisms: snapshot.totalMatchingRows
                    )

                    guard !snapshot.rows.isEmpty else { return }
                    offset += snapshot.rows.count
                    if self.allBatchGroupRows.count >= snapshot.totalMatchingRows {
                        logger.info("Loaded \(self.allBatchGroupRows.count) TaxTriage rows from SQLite pages")
                        return
                    }

                case .failure(let message):
                    logger.error("Failed to load TaxTriage rows from SQLite: \(message, privacy: .public)")
                    return
                }
            }
        }
    }

    private func mergeDatabasePageSnapshot(_ snapshot: TaxTriageDatabasePageSnapshot) {
        allBatchGroupRows.append(contentsOf: snapshot.rows)
        batchFlatTableView.uniqueReadsByKey.merge(snapshot.uniqueReadsByKey) { _, new in new }
        batchFlatTableView.totalReadsByKey.merge(snapshot.totalReadsByKey) { _, new in new }
        bamFilesBySample.merge(snapshot.bamFilesBySample) { _, new in new }
        bamIndexesBySample.merge(snapshot.bamIndexesBySample) { _, new in new }
        retainedReferencesBySample.merge(snapshot.retainedReferencesBySample) { _, new in new }
        accessionLengths.merge(snapshot.accessionLengths) { _, new in new }

        mergeOrganismAccessions(snapshot.organismToAccessionsBySample)
        mergeTaxIDAccessions(snapshot.taxIDToAccessionsBySample)
        organismToAccessions = mergedOrganismToAccessions
        taxIDToAccessions = mergedTaxIDToAccessions
    }

    private func selectTopDatabaseRowAfterInitialPageIfNeeded() {
        guard shouldSelectTopDatabaseRowAfterLoad else { return }
        // The overview grid replaces the list; selecting a hidden list row
        // would reveal the alignment pane behind it. The flag stays set so
        // the top row is selected when the list comes back.
        guard !isDatabaseOverviewVisible else { return }
        let rows = batchFlatTableView.displayedRows
        guard !rows.isEmpty else { return }
        shouldSelectTopDatabaseRowAfterLoad = false
        var index = 0
        if let pending = pendingDatabaseRowSelection {
            pendingDatabaseRowSelection = nil
            let pendingKey = normalizedOrganismName(pending.organism)
            if let match = rows.firstIndex(where: {
                $0.sample == pending.sample && normalizedOrganismName($0.organism) == pendingKey
            }) {
                index = match
            }
        }
        batchFlatTableView.selectDisplayedRowForContextMenuIfNeeded(index)
        if index > 0 {
            batchFlatTableView.tableView.scrollRowToVisible(index)
        }
    }

    private func mergeOrganismAccessions(_ incoming: [String: [String: [String]]]) {
        for (sample, organismMap) in incoming {
            var sampleMap = organismToAccessionsBySample[sample] ?? [:]
            for (organism, accessions) in organismMap {
                sampleMap[organism, default: []].append(contentsOf: accessions)
                sampleMap[organism] = uniqueAccessionsPreservingOrder(sampleMap[organism] ?? [])
                mergedOrganismToAccessions[organism, default: []].append(contentsOf: accessions)
                mergedOrganismToAccessions[organism] = uniqueAccessionsPreservingOrder(
                    mergedOrganismToAccessions[organism] ?? []
                )
            }
            organismToAccessionsBySample[sample] = sampleMap
        }
    }

    private func mergeTaxIDAccessions(_ incoming: [String: [Int: [String]]]) {
        for (sample, taxMap) in incoming {
            var sampleMap = taxIDToAccessionsBySample[sample] ?? [:]
            for (taxID, accessions) in taxMap {
                sampleMap[taxID, default: []].append(contentsOf: accessions)
                sampleMap[taxID] = uniqueAccessionsPreservingOrder(sampleMap[taxID] ?? [])
                mergedTaxIDToAccessions[taxID, default: []].append(contentsOf: accessions)
                mergedTaxIDToAccessions[taxID] = uniqueAccessionsPreservingOrder(
                    mergedTaxIDToAccessions[taxID] ?? []
                )
            }
            taxIDToAccessionsBySample[sample] = sampleMap
        }
    }

    /// Filters `allBatchGroupRows` by the samples selected in `samplePickerState`
    /// and by the organism search text, then reloads `batchFlatTableView`.
    public func applyBatchGroupFilter() {
        guard isBatchGroupMode, let state = samplePickerState else { return }
        if taxTriageDatabase != nil {
            reloadDatabaseRowsForCurrentFilter()
            return
        }
        let selected = state.selectedSamples
        var filtered: [TaxTriageMetric]
        if selected.isEmpty {
            filtered = []
        } else {
            filtered = allBatchGroupRows.filter { m in
                guard let s = m.sample else { return false }
                return selected.contains(s)
            }
        }
        // Apply organism search text filter if active.
        if !organismSearchText.isEmpty {
            filtered = filtered.filter {
                $0.organism.localizedCaseInsensitiveContains(organismSearchText)
            }
        }
        batchFlatTableView.configure(rows: filtered)
    }

    // MARK: - Database Mode: Result Sidecar

    /// Loads `taxtriage-result.json` and its config from the result folder.
    ///
    /// The sidecar stores absolute paths from the machine and folder the run
    /// wrote. Paths under the stored output folder are rebased onto
    /// `resultURL`, so a result that was copied or moved still finds its own
    /// reports.
    private func loadResultSidecar(from resultURL: URL) {
        guard let stored = try? TaxTriageResult.load(from: resultURL) else {
            taxTriageResult = nil
            taxTriageConfig = nil
            return
        }
        let relocated = Self.relocatedResult(stored, to: resultURL)
        taxTriageResult = relocated
        taxTriageConfig = relocated.config
    }

    static func relocatedResult(_ result: TaxTriageResult, to resultURL: URL) -> TaxTriageResult {
        let oldRoot = result.outputDirectory.standardizedFileURL.path
        let newRoot = resultURL.standardizedFileURL.path
        guard oldRoot != newRoot else { return result }
        func rebase(_ url: URL) -> URL {
            let path = url.standardizedFileURL.path
            guard path == oldRoot || path.hasPrefix(oldRoot + "/") else { return url }
            return URL(fileURLWithPath: newRoot + String(path.dropFirst(oldRoot.count)))
        }
        return TaxTriageResult(
            config: result.config,
            runtime: result.runtime,
            exitCode: result.exitCode,
            outputDirectory: resultURL,
            reportFiles: result.reportFiles.map(rebase),
            metricsFiles: result.metricsFiles.map(rebase),
            kronaFiles: result.kronaFiles.map(rebase),
            logFile: result.logFile.map(rebase),
            traceFile: result.traceFile.map(rebase),
            allOutputFiles: result.allOutputFiles.map(rebase),
            deduplicatedReadCounts: result.deduplicatedReadCounts,
            perSampleDeduplicatedReadCounts: result.perSampleDeduplicatedReadCounts,
            sourceBundleURLs: result.sourceBundleURLs,
            ignoredFailures: result.ignoredFailures,
            sampleFailures: result.sampleFailures
        )
    }

    /// Flags every organism that TaxTriage detected in a negative-control
    /// sample, across all samples and independent of the Sample Filter.
    private func loadContaminationRiskOrganisms(from db: TaxTriageDatabase) {
        batchFlatTableView.contaminationRiskOrganismKeys = []
        let controls = negativeControlSampleIds().filter { sampleIds.contains($0) }
        guard !controls.isEmpty else { return }
        let samples = controls.sorted()
        contaminationRiskLoadTask?.cancel()
        contaminationRiskLoadTask = Task { [weak self, db, samples] in
            let keys = await Task.detached(priority: .userInitiated) { () -> Set<String> in
                let rows = (try? db.fetchRows(samples: samples)) ?? []
                return Set(rows.map { OrganismNameNormalizer.normalizedKey($0.organism) })
            }.value
            guard let self, !Task.isCancelled, self.taxTriageDatabase === db else { return }
            self.batchFlatTableView.contaminationRiskOrganismKeys = keys
            if self.isDatabaseOverviewVisible {
                self.reconfigureDatabaseOverviewGrid()
            }
        }
    }

    // MARK: - Database Mode: Sample Selection

    /// Sample IDs ticked in the Inspector's Sample Filter, in `sampleIds` order.
    var selectedDatabaseSampleIds: [String] {
        guard let state = samplePickerState else { return [] }
        return sampleIds.filter { state.selectedSamples.contains($0) }
    }

    /// Whether the organism-by-sample overview grid is on screen.
    var isDatabaseOverviewVisible: Bool {
        isBatchGroupMode && isShowingDatabaseOverview && selectedDatabaseSampleIds.count > 1
    }

    /// Index into `sampleIds` of the one sample the list shows, when exactly
    /// one sample is ticked and the overview grid is not showing.
    private func currentSingleDatabaseSampleIndex() -> Int? {
        let selected = selectedDatabaseSampleIds
        guard !isDatabaseOverviewVisible, selected.count == 1 else { return nil }
        return sampleIds.firstIndex(of: selected[0])
    }

    private var canSelectNextDatabaseSample: Bool {
        guard isBatchGroupMode, sampleIds.count > 1 else { return false }
        guard let current = currentSingleDatabaseSampleIndex() else { return true }
        return current < sampleIds.count - 1
    }

    private var canSelectPreviousDatabaseSample: Bool {
        guard isBatchGroupMode, sampleIds.count > 1 else { return false }
        guard let current = currentSingleDatabaseSampleIndex() else { return true }
        return current > 0
    }

    /// Next/Previous Sample. From one ticked sample this moves to its
    /// neighbour. From several ticked samples, or from the overview grid,
    /// Next starts at the first sample and Previous at the last.
    private func stepDatabaseSample(by delta: Int) {
        guard sampleIds.count > 1 else { return }
        let target: Int
        if let current = currentSingleDatabaseSampleIndex() {
            target = current + delta
            guard sampleIds.indices.contains(target) else { return }
        } else {
            target = delta > 0 ? 0 : sampleIds.count - 1
        }
        setDatabaseSampleSelection([sampleIds[target]], showOverview: false)
    }

    /// View > All Samples. Ticks every sample and shows the overview grid;
    /// choosing it again while the grid shows returns to the organism list.
    private func toggleDatabaseOverview() {
        guard sampleIds.count > 1 else { return }
        if isDatabaseOverviewVisible {
            isShowingDatabaseOverview = false
            syncSampleFilterControlToPickerState()
            applyDatabaseOverviewPresentation()
        } else {
            setDatabaseSampleSelection(sampleIds, showOverview: true)
        }
    }

    /// Segment/popup index: 0 is "All Samples", 1... are the samples.
    private func selectDatabaseSampleFilterIndex(_ index: Int) {
        if index <= 0 {
            if isDatabaseOverviewVisible, selectedDatabaseSampleIds.count == sampleIds.count {
                toggleDatabaseOverview()
            } else {
                setDatabaseSampleSelection(sampleIds, showOverview: true)
            }
            return
        }
        guard index - 1 < sampleIds.count else { return }
        setDatabaseSampleSelection([sampleIds[index - 1]], showOverview: false)
    }

    /// Opens one sample's organism list from an overview grid value and
    /// selects the organism's row once the sample's rows load.
    private func openDatabaseSample(_ sampleId: String, selectingOrganism organism: String) {
        guard sampleIds.contains(sampleId) else { return }
        pendingDatabaseRowSelection = (sampleId, organism)
        setDatabaseSampleSelection([sampleId], showOverview: false)
    }

    /// Writes a sample selection into the Inspector's Sample Filter state and
    /// applies it. The Inspector posts its own change notification for the
    /// same edit; `databaseSampleSelectionDidChange()` recognises that the
    /// rows are already loaded for it and does not reload them twice.
    private func setDatabaseSampleSelection(_ ids: [String], showOverview: Bool) {
        guard let state = samplePickerState else { return }
        isShowingDatabaseOverview = showOverview && ids.count > 1
        state.selectedSamples = Set(ids)
        databaseSampleSelectionDidChange()
    }

    /// Applies the current Sample Filter state: reloads rows when the ticked
    /// set changed, then updates the segmented control and the overview grid.
    private func databaseSampleSelectionDidChange() {
        guard let state = samplePickerState else { return }
        if state.selectedSamples.count <= 1 {
            isShowingDatabaseOverview = false
        }
        let needsReload = taxTriageDatabase == nil
            || loadedDatabaseSampleSelection != state.selectedSamples
        if needsReload {
            applyBatchGroupFilter()
        }
        syncSampleFilterControlToPickerState()
        applyDatabaseOverviewPresentation()
    }

    /// Mirrors the Sample Filter state into the segmented control or popup:
    /// the overview grid selects "All Samples", one ticked sample selects its
    /// segment, and any other combination selects nothing.
    private func syncSampleFilterControlToPickerState() {
        guard isBatchGroupMode else { return }
        let index: Int
        if isDatabaseOverviewVisible {
            index = 0
        } else if let single = currentSingleDatabaseSampleIndex() {
            index = single + 1
        } else {
            index = -1
        }
        selectedSampleIndex = max(0, index)
        if sampleFilterControl.segmentCount == sampleIds.count + 1 {
            sampleFilterControl.selectedSegment = index
        }
        if sampleFilterPopUp.numberOfItems == sampleIds.count + 1 {
            sampleFilterPopUp.selectItem(at: index)
        }
    }

    /// Swaps between the flat organism list and the overview grid.
    private func applyDatabaseOverviewPresentation() {
        guard isBatchGroupMode else { return }
        let showOverview = isDatabaseOverviewVisible
        let wasShowingOverview = !batchOverviewView.isHidden
        batchOverviewView.isHidden = !showOverview
        batchFlatTableView.isHidden = showOverview

        if showOverview {
            alignmentEvidenceViewer?.clear()
            multiSelectionPlaceholder.isHidden = true
            collapseMiniBAMDetailPane()
            reconfigureDatabaseOverviewGrid()
            actionBar.updateInfoText(
                "Organism overview of \(selectedDatabaseSampleIds.count) samples. Double-click a sample value to open that sample."
            )
            actionBar.setBlastEnabled(false, reason: "Choose one sample to use BLAST Verify")
            actionBar.setExtractEnabled(false)
            return
        }

        guard wasShowingOverview else { return }
        // Back to the list: re-drive the list's selection so the action bar
        // and alignment pane match what the list shows.
        let selection = batchFlatTableView.selectedMetrics()
        if selection.isEmpty {
            shouldSelectTopDatabaseRowAfterLoad = true
            selectTopDatabaseRowAfterInitialPageIfNeeded()
        } else if selection.count == 1, let selected = selection.first,
                  let index = batchFlatTableView.displayedRows.firstIndex(where: {
                      $0.sample == selected.sample && $0.organism == selected.organism
                  }) {
            batchFlatTableView.selectDisplayedRowForContextMenuIfNeeded(index)
        } else {
            actionBar.updateInfoText("\(selection.count) rows selected")
            actionBar.setExtractEnabled(hasExtractableResultPath)
        }
    }

    /// Rebuilds the overview grid from the loaded database rows.
    private func reconfigureDatabaseOverviewGrid() {
        var perSampleUnique: [String: [String: Int]] = [:]
        for row in allBatchGroupRows {
            guard let sample = row.sample else { continue }
            let key = "\(sample)\t\(row.organism)"
            let readCount = batchFlatTableView.totalReadsByKey[key] ?? row.reads
            guard let unique = ClassifierUniqueReads.normalized(
                stored: batchFlatTableView.uniqueReadsByKey[key],
                readCount: readCount
            ) else { continue }
            perSampleUnique[normalizedOrganismName(row.organism), default: [:]][sample] = unique
        }
        batchOverviewView.configure(
            metrics: allBatchGroupRows,
            sampleIds: selectedDatabaseSampleIds,
            negativeControlSampleIds: negativeControlSampleIds(),
            sampleLabels: resolvedDisplayNames,
            perSampleDeduplicatedReadCounts: perSampleUnique
        )
    }

    // MARK: - Multi-Sample Single Result Mode

    /// Switches a single multi-sample TaxTriage result to the flat-table + Inspector
    /// sample picker pattern used by batch group mode.
    ///
    /// Called automatically from `configure(result:config:)` when `sampleIds.count > 1`.
    /// Reuses the existing `batchFlatTableView` and `bamFilesBySample` data already
    /// populated by `configure`. Does NOT affect `isBatchGroupMode`.
    private func enableMultiSampleFlatTableMode() {
        isMultiSampleSingleResultMode = true

        // Hide the segmented control — it doesn't scale to large sample counts.
        // Keep the filter row height so the organism search field remains visible.
        sampleFilterControl.isHidden = true

        // Hide the batch overview (pivot table feature, designed separately).
        batchOverviewView.isHidden = true

        // Show organism search field in the filter row.
        // rebuildSampleFilterSegments already set height to 24/4/4 above; keep that.
        organismSearchField.isHidden = false
        updateFilterRowHeightForContentTypography()
        sampleFilterTopSpacingConstraint?.constant = 4
        sampleFilterBottomSpacingConstraint?.constant = 4

        // Switch right pane: hide organism table, show flat table.
        organismTableView.isHidden = true
        batchFlatTableView.isHidden = false
        collapseMiniBAMDetailPane()
        batchFlatTableView.metadataColumns.isMultiSampleMode = true
        batchFlatTableView.resultIdentity = taxTriageConfig?.outputDirectory.standardizedFileURL.path

        // Use the already-populated `metrics` array as the flat table rows.
        allBatchGroupRows = metrics

        // Wire batch flat table callbacks (same pattern as configureFromDatabase).
        batchFlatTableView.onRowSelected = { [weak self] row in
            guard let self else { return }
            self.actionBar.updateInfoText("1 row selected")
            self.actionBar.setBlastEnabled(true)
            self.actionBar.setExtractEnabled(self.hasExtractableResultPath)
            self.hideMultiSelectionPlaceholder()
            self.selectedBatchSampleId = row.sample
            self.selectedBatchOrganismName = row.organism

            // Reveal the miniBAM detail pane ONLY when the selected organism has
            // BAM alignment data. Showing it for organisms without alignments
            // left a large empty pane that read as a blank viewport.
            let bamURL = row.sample.flatMap { self.bamFilesBySample[$0] }
            let accessions = self.accessions(for: row) ?? []
            if let bamURL, !accessions.isEmpty {
                self.revealMiniBAMDetailPaneIfNeeded()
                self.displayTaxTriageMiniBAM(
                    bamURL: bamURL,
                    indexURL: resolveBamIndex(for: bamURL, allOutputFiles: self.taxTriageResult?.allOutputFiles ?? []),
                    accessions: accessions
                )
            } else {
                self.alignmentEvidenceViewer?.clear()
                self.collapseMiniBAMDetailPane()
            }
        }
        batchFlatTableView.onMultipleRowsSelected = { [weak self] rows in
            guard let self else { return }
            self.actionBar.updateInfoText("\(rows.count) rows selected")
            self.actionBar.setBlastEnabled(false, reason: "Select a single row to use BLAST Verify")
            self.actionBar.setExtractEnabled(self.hasExtractableResultPath)
            self.showMultiSelectionPlaceholder(count: rows.count)
            // Hide the left pane when multiple rows are selected.
            self.collapseMiniBAMDetailPane()
        }
        batchFlatTableView.onSelectionCleared = { [weak self] in
            guard let self else { return }
            self.actionBar.updateInfoText("Select an organism to view details")
            self.actionBar.setBlastEnabled(false, reason: "Select a row to use BLAST Verify")
            self.hideMultiSelectionPlaceholder()
            self.selectedBatchSampleId = nil
            self.selectedBatchOrganismName = nil
            self.alignmentEvidenceViewer?.clear()
            // Nothing selected -> collapse the empty detail pane.
            self.collapseMiniBAMDetailPane()
        }

        summaryBar.updateBatch(sampleCount: sampleIds.count, totalOrganisms: metrics.count)

        applyMultiSampleFilter()

        // Populate unique reads column from any already-persisted per-sample dedup counts.
        syncUniqueReadsToFlatTable()

        // Show the Recompute Unique Reads button in multi-sample single-result mode.
        recomputeUniqueReadsButton.isHidden = false
    }

    /// Filters `allBatchGroupRows` (sourced from `metrics`) by the samples selected
    /// in `samplePickerState` and by the organism search text, then reloads `batchFlatTableView`.
    ///
    /// Called from `handleInspectorSampleSelectionChanged` and `organismSearchAction`
    /// when `isMultiSampleSingleResultMode` is true.
    public func applyMultiSampleFilter() {
        guard isMultiSampleSingleResultMode, let state = samplePickerState else { return }
        let selected = state.selectedSamples
        var filtered: [TaxTriageMetric]
        if selected.isEmpty {
            filtered = []
        } else {
            filtered = allBatchGroupRows.filter { m in
                guard let s = m.sample else { return false }
                return selected.contains(s)
            }
        }
        if !organismSearchText.isEmpty {
            filtered = filtered.filter {
                $0.organism.localizedCaseInsensitiveContains(organismSearchText)
            }
        }
        batchFlatTableView.configure(rows: filtered)
    }

    // MARK: - Setup: Action Bar

    private func setupActionBar() {
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actionBar)
    }

    // MARK: - Layout

    private func layoutSubviews() {
        let drawerHeight = blastDrawer.heightAnchor.constraint(equalToConstant: 0)
        blastDrawerHeightConstraint = drawerHeight

        let splitBottom = splitView.bottomAnchor.constraint(equalTo: blastDrawer.topAnchor)
        splitViewBottomConstraint = splitBottom

        // Sample filter bar collapses to zero height when hidden (single-sample runs).
        let filterHeight = sampleFilterControl.heightAnchor.constraint(equalToConstant: 0)
        sampleFilterHeightConstraint = filterHeight
        let filterTop = sampleFilterControl.topAnchor.constraint(equalTo: summaryBar.bottomAnchor, constant: 0)
        sampleFilterTopSpacingConstraint = filterTop
        let filterBottom = splitView.topAnchor.constraint(equalTo: sampleFilterControl.bottomAnchor, constant: 0)
        sampleFilterBottomSpacingConstraint = filterBottom
        let summaryHeight = summaryBar.heightAnchor.constraint(
            equalToConstant: summaryBar.preferredContentHeight
        )
        summaryBar.onPreferredContentHeightChanged = { [weak summaryHeight] height in
            summaryHeight?.constant = height
        }

        NSLayoutConstraint.activate([
            // Summary bar (top, below safe area)
            summaryBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            summaryHeight,

            // Sample filter control (between summary bar and split view)
            filterTop,
            sampleFilterControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            filterHeight,

            // Sample filter popup (UX-18: scalable alternative to the segmented
            // control for large sample counts, occupying the same row)
            sampleFilterPopUp.centerYAnchor.constraint(equalTo: sampleFilterControl.centerYAnchor),
            sampleFilterPopUp.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            sampleFilterPopUp.widthAnchor.constraint(lessThanOrEqualToConstant: 220),

            // Organism search field (right-aligned on the same row as sample filter)
            organismSearchField.centerYAnchor.constraint(equalTo: sampleFilterControl.centerYAnchor),
            organismSearchField.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            organismSearchField.widthAnchor.constraint(lessThanOrEqualToConstant: 200),

            // Action bar (bottom, fixed height)
            actionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: 36),

            // BLAST drawer (between split view and action bar)
            blastDrawer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            blastDrawer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            blastDrawer.bottomAnchor.constraint(equalTo: actionBar.topAnchor),
            drawerHeight,

            // Split view (fills remaining space)
            filterBottom,
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitBottom,

            // batchFlatTableView is inside rightPaneContainer; no top-level constraints needed.
        ])
    }

    // MARK: - Callback Wiring

    private func wireCallbacks() {
        // Table multi-selection -> placeholder + action bar update
        organismTableView.onMultipleRowsSelected = { [weak self] count in
            guard let self else { return }
            self.showMultiSelectionPlaceholder(count: count)
            self.actionBar.updateInfoText("\(count) items selected")
            self.actionBar.setBlastEnabled(false, reason: "Select a single row to use BLAST Verify")
            self.actionBar.setExtractEnabled(self.hasExtractableResultPath)
        }

        // Table selection -> action bar update + BAM viewer update
        organismTableView.onRowSelected = { [weak self] row in
            guard let self else { return }
            self.hideMultiSelectionPlaceholder()
            self.selectedOrganismName = row?.organism
            self.selectedReadCount = row?.reads
            self.updateActionBarForOrganism(
                name: row?.organism,
                readCount: row?.reads,
                uniqueReadCount: row?.uniqueReads
            )

            // Load BAM alignments for the selected organism.
            // The BAM uses accession numbers (NC_009539.1) as reference names,
            // not organism names. Use the gcfmapping to translate.
            if let row, let bamURL = self.bamURL {
                let organismName = row.organism
                if let accessions = self.accessions(for: row),
                   !accessions.isEmpty {
                    self.displayTaxTriageMiniBAM(
                        bamURL: bamURL,
                        indexURL: self.bamIndexURL,
                        accessions: accessions
                    )
                } else {
                    self.alignmentEvidenceViewer?.clear()
                    logger.debug("No accession mapping for organism: \(organismName, privacy: .public)")
                }
            } else {
                self.alignmentEvidenceViewer?.clear()
            }
        }

        // Table BLAST request -> forward to host with BAM context
        organismTableView.onBlastRequested = { [weak self] row, readCount in
            self?.requestBlastVerification(for: row, readCount: readCount)
        }

        // Action bar Extract FASTQ -> route to the unified extraction dialog.
        actionBar.onExtractFASTQ = { [weak self] in
            self?.presentUnifiedExtractionDialog()
        }

        // Context menu Extract FASTQ -> route to the same unified dialog.
        organismTableView.onExtractFASTQ = { [weak self] in
            self?.presentUnifiedExtractionDialog()
        }

        // Batch flat table context menu -> same unified dialog.
        batchFlatTableView.onExtractReadsRequested = { [weak self] in
            self?.presentUnifiedExtractionDialog()
        }

        // Batch flat table BLAST verify -> forward to host with BAM context.
        batchFlatTableView.onBlastVerifyRequested = { [weak self] metric, readCount in
            self?.requestBlastVerification(for: metric, readCount: readCount)
        }

        // Action bar BLAST verify -> read-count popover for the selected row.
        actionBar.onBlastVerify = { [weak self] in
            self?.requestBlastVerificationForCurrentSelection()
        }

        // Action bar export
        actionBar.onExport = { [weak self] in
            self?.showExportMenu()
        }

        // Action bar provenance
        actionBar.onProvenance = { [weak self] sender in
            self?.showProvenancePopover(relativeTo: sender)
        }

        // Custom button: Open Report
        openReportButton.target = self
        openReportButton.action = #selector(openExternalTapped)
        openReportButton.toolTip = "Open the TaxTriage report (PDF, or HTML when there is no PDF) for the selected row's sample"
        actionBar.addCustomButton(openReportButton)

        // Custom button: Related analyses (hidden until discoveries are made)
        relatedAnalysesButton.target = self
        relatedAnalysesButton.action = #selector(relatedAnalysesTapped(_:))
        relatedAnalysesButton.isHidden = true
        actionBar.addCustomButton(relatedAnalysesButton)

        // Custom button: Recompute Unique Reads (hidden until batch/multi-sample mode)
        recomputeUniqueReadsButton.target = self
        recomputeUniqueReadsButton.action = #selector(recomputeUniqueReadsTapped)
        actionBar.addCustomButton(recomputeUniqueReadsButton)
    }

    private func requestBlastVerification(for row: TaxTriageTableRow, readCount: Int) {
        let organism = TaxTriageOrganism(
            name: row.organism,
            score: row.tassScore,
            reads: row.reads,
            coverage: row.coverage,
            taxId: row.taxId,
            rank: row.rank
        )
        let rowAccessions = accessions(for: row)
        onBlastVerification?(organism, readCount, rowAccessions, bamURL, bamIndexURL)
    }

    private func requestBlastVerification(for metric: TaxTriageMetric, readCount: Int) {
        let organism = TaxTriageOrganism(
            name: metric.organism,
            score: metric.tassScore,
            reads: metric.reads,
            coverage: metric.coverageBreadth,
            taxId: metric.taxId,
            rank: metric.rank
        )
        let rowAccessions = accessions(for: metric)
        let sampleId = metric.sample
        let metricBamURL = sampleId.flatMap { bamFilesBySample[$0] } ?? bamURL
        let metricBamIndexURL: URL?
        if let metricBamURL {
            metricBamIndexURL = resolveBamIndex(
                for: metricBamURL,
                allOutputFiles: taxTriageResult?.allOutputFiles ?? []
            )
        } else {
            metricBamIndexURL = bamIndexURL
        }
        onBlastVerification?(organism, readCount, rowAccessions, metricBamURL, metricBamIndexURL)
    }

    /// Action bar BLAST Verify. Opens the same read-count popover as the
    /// row's "Verify with BLAST…" context menu item (slider from 1 to at most
    /// 50 reads, 20 by default) instead of submitting straight away, so one
    /// click never spends the whole NCBI allowance.
    private func requestBlastVerificationForCurrentSelection() {
        let flatSelection = batchFlatTableView.selectedMetrics()
        if batchFlatTableView.isHidden == false, flatSelection.count == 1, let metric = flatSelection.first {
            presentBlastConfigPopover(
                taxonName: metric.organism,
                readsClade: defaultBlastReadCount(for: metric)
            ) { [weak self] readCount in
                self?.requestBlastVerification(for: metric, readCount: readCount)
            }
            return
        }

        let organismRows = organismTableView.selectedTableRows()
        if organismTableView.isHidden == false, organismRows.count == 1, let row = organismRows.first {
            presentBlastConfigPopover(
                taxonName: row.organism,
                readsClade: row.uniqueReads ?? row.reads
            ) { [weak self] readCount in
                self?.requestBlastVerification(for: row, readCount: readCount)
            }
            return
        }

        actionBar.setBlastEnabled(false, reason: "Select a single row to use BLAST Verify")
    }

    private func presentBlastConfigPopover(
        taxonName: String,
        readsClade: Int,
        onRun: @escaping (Int) -> Void
    ) {
        let anchor = actionBar.blastButton
        if let presenter = blastConfigPopoverPresenter {
            presenter(taxonName, readsClade, anchor, onRun)
            return
        }
        activeBlastConfigPopover?.close()
        // NSPopover raises when its anchor is not in a window.
        guard anchor.window != nil else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 280, height: 160)
        popover.contentViewController = NSHostingController(
            rootView: BlastConfigPopoverView(
                taxonName: taxonName,
                readsClade: readsClade,
                database: "core_nt",
                onRun: { [weak self, weak popover] readCount in
                    popover?.close()
                    self?.activeBlastConfigPopover = nil
                    onRun(readCount)
                }
            )
        )
        activeBlastConfigPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    private func defaultBlastReadCount(for metric: TaxTriageMetric) -> Int {
        let sampleKey = metric.sample ?? ""
        return batchFlatTableView.totalReadsByKey["\(sampleKey)\t\(metric.organism)"] ?? metric.reads
    }

    // MARK: - Recompute Unique Reads

    @objc private func recomputeUniqueReadsTapped() {
        recomputeAllUniqueReads()
    }

    /// Clears all cached unique read data and restarts computation from BAM files for
    /// all organisms across all samples. Works for both batch group mode and multi-sample
    /// single-result mode.
    func recomputeAllUniqueReads() {
        // 1. Clear in-memory caches.
        perSampleDeduplicatedReadCounts.removeAll()
        deduplicatedReadCounts.removeAll()

        // 2. Clear the flat table's unique reads display.
        batchFlatTableView.uniqueReadsByKey.removeAll()
        batchFlatTableView.tableView.reloadData()

        // 3. Delete on-disk caches.
        if let batchURL = batchGroupURL {
            // Delete batch-level cache.
            let cacheURL = batchURL.appendingPathComponent(Self.batchUniqueReadsCacheFilename)
            try? FileManager.default.removeItem(at: cacheURL)
            // Delete the materialized batch manifest so next open re-parses fresh.
            let manifestURL = batchURL.appendingPathComponent(TaxTriageBatchManifest.filename)
            try? FileManager.default.removeItem(at: manifestURL)
        }
        // Also clear from the per-result sidecar for single-result multi-sample mode.
        // Database mode loads the sidecar read-only (with relocated paths) and
        // must never rewrite it.
        if !isBatchGroupMode, var result = taxTriageResult {
            result.perSampleDeduplicatedReadCounts = nil
            result.deduplicatedReadCounts = nil
            try? result.save()
        }

        // 4. Cancel any existing computation.
        deduplicatedReadCountTask?.cancel()

        // 5. Restart computation for all organisms.
        if isBatchGroupMode, let batchURL = batchGroupURL {
            // Re-enumerate sample subdirectories (same logic as configureFromDatabase).
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: batchURL.path)) ?? []
            let subdirs = contents
                .sorted()
                .map { batchURL.appendingPathComponent($0) }
                .filter { url in
                    var isDir: ObjCBool = false
                    return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
                }
            if !subdirs.isEmpty {
                scheduleBatchPerSampleUniqueReadComputation(subdirs: subdirs)
            }
        } else if isMultiSampleSingleResultMode {
            // Multi-sample single-result: use allBatchGroupRows as the row source.
            // Convert allBatchGroupRows to TaxTriageTableRow for the scheduler.
            let rows = allBatchGroupRows.map { metric in
                TaxTriageTableRow(
                    organism: metric.organism,
                    tassScore: metric.tassScore,
                    reads: metric.reads,
                    uniqueReads: nil,
                    coverage: metric.coverageBreadth,
                    confidence: metric.confidence,
                    taxId: metric.taxId,
                    rank: metric.rank,
                    abundance: metric.abundance
                )
            }
            scheduleDeduplicatedReadCountComputation(for: rows)
        }

        // 6. Update info text to indicate recompute is in progress.
        actionBar.updateInfoText("Recomputing unique reads for all organisms\u{2026}")
    }

    // MARK: - Classifier extraction wiring

    /// Builds per-sample selectors from the current table selection.
    ///
    /// When the batch flat table is visible (batch group mode or multi-sample
    /// single-result mode), reads selected rows from `batchFlatTableView` and
    /// groups accessions per sample. Otherwise falls back to the organism table
    /// which represents one sample at a time.
    private func buildTaxTriageSelectors() -> [ClassifierRowSelector] {
        // Batch flat table is the primary table in batch/multi-sample modes.
        if !batchFlatTableView.isHidden {
            let selectedMetrics = batchFlatTableView.selectedMetrics()
            guard !selectedMetrics.isEmpty else { return [] }

            // Group accessions by sample id since the flat table may have
            // rows from multiple samples selected simultaneously.
            var bySample: [String: [String]] = [:]
            for metric in selectedMetrics {
                let sampleId = metric.sample ?? sampleIds.first ?? "unknown"
                let metricAccessions = self.accessions(for: metric) ?? []
                bySample[sampleId, default: []].append(contentsOf: metricAccessions)
            }
            return bySample.compactMap { (sampleId, accessions) in
                guard !accessions.isEmpty else { return nil }
                return ClassifierRowSelector(
                    sampleId: sampleId,
                    accessions: accessions,
                    taxIds: []
                )
            }
        }

        // Single-sample organism table fallback.
        let accessions = organismTableView.selectedTableRows().flatMap { self.accessions(for: $0) ?? [] }
        guard !accessions.isEmpty else { return [] }
        return [ClassifierRowSelector(
            sampleId: selectedBatchSampleId ?? sampleIds.first,
            accessions: accessions,
            taxIds: []
        )]
    }

    /// Presents the unified classifier extraction dialog for the current selection.
    private func presentUnifiedExtractionDialog() {
        guard let resultPath = taxTriageDatabase?.databaseURL ?? taxTriageConfig?.outputDirectory else { return }
        let selectors = buildTaxTriageSelectors()
        guard !selectors.isEmpty else { return }
        let firstAccession = selectors.first?.accessions.first ?? "extract"
        let sid = selectors.first?.sampleId ?? "sample"
        onExtractReadsRequested?(.taxtriage, resultPath, selectors, "taxtriage_\(sid)_\(firstAccession)")
    }

    // MARK: - Negative Control Helpers

    /// Returns sample IDs marked as negative controls in the config.
    private func negativeControlSampleIds() -> Set<String> {
        guard let config = taxTriageConfig else { return [] }
        return Set(config.samples.filter(\.isNegativeControl).map(\.sampleId))
    }

    // MARK: - Related Analyses Discovery

    /// Scans source bundles for Kraken2 and EsViritu results to enable cross-navigation.
    ///
    /// After configuring, call this to populate the "Related" button in the action bar.
    /// Source bundles are discovered from the TaxTriage config's `sourceBundleURLs`
    /// or inferred from the input FASTQ paths.
    func discoverRelatedAnalyses() {
        guard let config = taxTriageConfig else { return }
        let fm = FileManager.default

        // Determine source bundle directories
        var bundleURLs: [URL] = taxTriageResult?.sourceBundleURLs ?? []
        if bundleURLs.isEmpty {
            // Infer from input FASTQ parent directories
            bundleURLs = config.samples.compactMap { sample in
                let parent = sample.fastq1.deletingLastPathComponent()
                // Check if this looks like a bundle (has FASTQ files)
                let hasFastq = (try? fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?.contains { url in
                    let ext = url.pathExtension.lowercased()
                    return ext == "fastq" || ext == "fq" || url.lastPathComponent.hasSuffix(".fastq.gz") || url.lastPathComponent.hasSuffix(".fq.gz")
                } ?? false
                return hasFastq ? parent : nil
            }
        }

        var items: [(String, String, URL)] = []

        for bundleURL in bundleURLs {
            guard let contents = try? fm.contentsOfDirectory(
                at: bundleURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            let bundleName = bundleURL.lastPathComponent

            for childURL in contents {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: childURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let dirName = childURL.lastPathComponent.lowercased()

                // Kraken2/Classification results
                if dirName.hasPrefix("classification-") || dirName.hasPrefix("kraken") {
                    let hasReport = fm.fileExists(atPath: childURL.appendingPathComponent("classification.kraken2.report.txt").path)
                        || fm.fileExists(atPath: childURL.appendingPathComponent("classification.report.txt").path)
                    if hasReport {
                        items.append(("View Kraken2 (\(bundleName))", "kraken2", childURL))
                    }
                }

                // EsViritu results
                if dirName.hasPrefix("esviritu-") {
                    let hasSidecar = fm.fileExists(atPath: childURL.appendingPathComponent("esviritu-result.json").path)
                    if hasSidecar {
                        items.append(("View EsViritu (\(bundleName))", "esviritu", childURL))
                    }
                }
            }
        }

        relatedAnalysisItems = items
        relatedAnalysesButton.isHidden = items.isEmpty
        if !items.isEmpty {
            logger.info("Discovered \(items.count) related analyses in source bundles")
        }
    }

    /// Callback for navigating to a related analysis result.
    /// Set by the host (ViewerViewController+TaxTriage) to handle cross-navigation.
    public var onRelatedAnalysis: ((String, URL) -> Void)?

    // MARK: - NSSplitViewDelegate

    public func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let minimumExtents = currentMinimumExtents()
        return MetagenomicsPaneSizing.clampedDividerPosition(
            proposed: proposedPosition,
            containerExtent: extent,
            minimumLeadingExtent: minimumExtents.leading,
            minimumTrailingExtent: minimumExtents.trailing
        )
    }

    public func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard splitView === self.splitView, splitView.arrangedSubviews.count == 2 else { return }

        // Both orientations flow through the same computed-target + applySplitFrames
        // path. Delegating the stacked (horizontal) case to adjustSubviews() left
        // the arranged subviews at zero height on first display, so the organism
        // table rendered blank until the user changed layout.

        let totalExtent = splitContainerExtent()
        guard totalExtent > 0 else { return }

        let targetLeadingExtent: CGFloat
        if leftPaneContainer.isHidden || isMiniBAMDetailPaneCollapsed {
            targetLeadingExtent = collapsedSplitPositionForHiddenDetail(containerExtent: totalExtent)
        } else if didSetInitialSplitPosition, !needsInitialSplitValidation {
            let proposedLeadingExtent = self.splitView.requestedDividerPosition(at: 0) ?? currentDividerPosition()
            targetLeadingExtent = clampedCurrentDividerPosition(for: proposedLeadingExtent ?? 0)
        } else {
            let layout = currentPanelLayout()
            let minimumExtents = minimumExtents(for: layout)
            targetLeadingExtent = MetagenomicsPaneSizing.clampedDividerPosition(
                proposed: round(totalExtent * defaultLeadingFraction(for: layout)),
                containerExtent: totalExtent,
                minimumLeadingExtent: minimumExtents.leading,
                minimumTrailingExtent: minimumExtents.trailing
            )
        }

        applySplitFrames(for: targetLeadingExtent)
    }

    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.object as? NSSplitView === splitView else { return }
        if !isSynchronizingTrackedSplitPosition,
           didSetInitialSplitPosition,
           !needsInitialSplitValidation,
           let currentPosition = currentDividerPosition() {
            splitView.recordObservedDividerPosition(currentPosition)
        }
        if hasValidInitialSplitPosition() {
            didSetInitialSplitPosition = true
            needsInitialSplitValidation = false
            return
        }

        guard didSetInitialSplitPosition, !pendingInitialSplitValidation else { return }
        needsInitialSplitValidation = true
        scheduleInitialSplitValidationIfNeeded()
    }

    // MARK: - Multi-Selection Helpers

    private func showMultiSelectionPlaceholder(count: Int) {
        selectedOrganismName = nil
        selectedReadCount = nil
        selectedBatchSampleId = nil
        selectedBatchOrganismName = nil
        alignmentEvidenceViewer?.clear()
        multiSelectionPrimaryLabel.stringValue = "\(count) items selected"
        multiSelectionPrimaryLabel.toolTip = multiSelectionPrimaryLabel.stringValue
        multiSelectionPrimaryLabel.setAccessibilityValue(
            multiSelectionPrimaryLabel.stringValue
        )
        alignmentEvidenceViewer?.viewController.view.isHidden = true
        multiSelectionPlaceholder.isHidden = false
    }

    private func hideMultiSelectionPlaceholder() {
        multiSelectionPlaceholder.isHidden = true
        // The placeholder hides the evidence view; give it back so a later
        // single-row selection has somewhere to draw. Pane collapse and
        // reveal are still managed by the row selection handlers.
        alignmentEvidenceViewer?.viewController.view.isHidden = false
    }

    // MARK: - Action Bar Selection Helper

    /// Updates the unified action bar info text from organism selection.
    private func updateActionBarForOrganism(name: String?, readCount: Int?, uniqueReadCount: Int?) {
        if let name, let count = readCount {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = ","
            let readStr = formatter.string(from: NSNumber(value: count)) ?? "\(count)"
            if let uniqueReadCount {
                let uniqueStr = formatter.string(from: NSNumber(value: uniqueReadCount)) ?? "\(uniqueReadCount)"
                actionBar.updateInfoText("\(name) \u{2014} \(readStr) reads (\(uniqueStr) unique)")
            } else {
                actionBar.updateInfoText("\(name) \u{2014} \(readStr) reads")
            }
            actionBar.setBlastEnabled(true)
            actionBar.setExtractEnabled(hasExtractableResultPath)
        } else {
            actionBar.updateInfoText("Select an organism to view details")
            actionBar.setBlastEnabled(false, reason: "Select a row to use BLAST Verify")
            actionBar.setExtractEnabled(false)
        }
    }

    // MARK: - Custom Button Actions

    @objc private func openExternalTapped() {
        openReportExternally()
    }

    @objc private func relatedAnalysesTapped(_ sender: NSButton) {
        guard let items = relatedAnalysisItems, !items.isEmpty else { return }

        let menu = NSMenu()
        for (label, analysisType, bundleURL) in items {
            let menuItem = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            menuItem.representedObject = (analysisType, bundleURL)
            menuItem.target = self
            menuItem.action = #selector(relatedMenuItemSelected(_:))
            menu.addItem(menuItem)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.maxY), in: sender)
    }

    @objc private func relatedMenuItemSelected(_ sender: NSMenuItem) {
        guard let tuple = sender.representedObject as? (String, URL) else { return }
        onRelatedAnalysis?(tuple.0, tuple.1)
    }

    // MARK: - Export

    private func showExportMenu() {
        let menu = buildExportMenu()
        let anchorView = actionBar
        let point = NSPoint(x: anchorView.bounds.maxX - 100, y: anchorView.bounds.maxY)
        menu.popUp(positioning: nil, at: point, in: anchorView)
    }

    /// Builds the export context menu.
    func buildExportMenu() -> NSMenu {
        let menu = NSMenu()

        let csvItem = NSMenuItem(
            title: "Export as CSV\u{2026}",
            action: #selector(exportCSVAction(_:)),
            keyEquivalent: ""
        )
        csvItem.target = self
        menu.addItem(csvItem)

        let tsvItem = NSMenuItem(
            title: "Export as TSV\u{2026}",
            action: #selector(exportTSVAction(_:)),
            keyEquivalent: ""
        )
        tsvItem.target = self
        menu.addItem(tsvItem)

        menu.addItem(.separator())

        let copyItem = NSMenuItem(
            title: "Copy Summary",
            action: #selector(copySummaryAction(_:)),
            keyEquivalent: ""
        )
        copyItem.target = self
        menu.addItem(copyItem)

        // Batch export options (only when multiple samples)
        if sampleIds.count > 1 {
            menu.addItem(.separator())

            let matrixItem = NSMenuItem(
                title: "Export Organism Matrix (CSV)\u{2026}",
                action: #selector(exportBatchMatrixAction(_:)),
                keyEquivalent: ""
            )
            matrixItem.target = self
            menu.addItem(matrixItem)

            let reportItem = NSMenuItem(
                title: "Export Batch Report\u{2026}",
                action: #selector(exportBatchReportAction(_:)),
                keyEquivalent: ""
            )
            reportItem.target = self
            menu.addItem(reportItem)
        }

        return menu
    }

    @objc private func exportCSVAction(_ sender: Any) {
        exportDelimited(separator: ",", fileExtension: "csv", fileTypeName: "CSV")
    }

    @objc private func exportTSVAction(_ sender: Any) {
        exportDelimited(separator: "\t", fileExtension: "tsv", fileTypeName: "TSV")
    }

    @objc private func copySummaryAction(_ sender: Any) {
        guard let summary = summaryTextForCopy() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }

    /// Text for Export > Copy Summary: the run summary from the sidecar
    /// followed, in database mode, by what the view currently shows.
    func summaryTextForCopy() -> String? {
        var lines: [String] = []
        if let result = taxTriageResult {
            lines.append(result.summary)
        }
        if isBatchGroupMode {
            if lines.isEmpty {
                lines.append("TaxTriage results: \(batchGroupURL?.lastPathComponent ?? "database")")
            }
            let selected = selectedDatabaseSampleIds
            lines.append("Samples shown: \(selected.count) of \(sampleIds.count) (\(selected.joined(separator: ", ")))")
            lines.append("Organism rows shown: \(batchFlatTableView.displayedRows.count)")
            let high = batchFlatTableView.displayedRows.filter {
                TaxTriageConfidenceBand(label: $0.confidence, tassScore: $0.tassScore) == .high
            }.count
            lines.append("High confidence rows: \(high)")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    @objc private func exportBatchMatrixAction(_ sender: Any) {
        guard let window = view.window else { return }

        let panel = MetagenomicsFilePanelFactory.delimitedExportPanel(
            title: "Export Organism Matrix",
            suggestedName: "organism_matrix.csv",
            contentTypes: [.commaSeparatedText]
        )

        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try self.writeBatchMatrixCSV(to: url)
            } catch {
                logger.error("Failed to export TaxTriage organism matrix: \(error.localizedDescription, privacy: .public)")
                ResultExportCoordinator.reportFailure(
                    fileName: url.lastPathComponent,
                    error: error,
                    window: window,
                    presenter: self.exportFailurePresenter
                )
            }
        }
    }

    func writeBatchMatrixCSV(to url: URL) throws {
        let startedAt = Date()
        let negativeControlIds = negativeControlSampleIds()
        let matrixMetrics = exportMetrics
        let csv = TaxTriageBatchExporter.generateOrganismMatrixCSV(
            metrics: matrixMetrics,
            sampleIds: sampleIds,
            negativeControlSampleIds: negativeControlIds
        )
        let exportedOrganismCount = taxTriageCrossSampleOrganismCount(in: matrixMetrics)
        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app taxtriage organism matrix export",
            sourceURLs: exportProvenanceSourceURLs(),
            outputURL: url,
            outputFormat: .text,
            argv: ["Lungfish.app", "export-taxtriage-organism-matrix", "--output", url.path],
            explicitOptions: [
                "outputPath": .file(url),
                "format": .string("csv"),
            ],
            defaults: [
                "format": .string("csv"),
            ],
            resolved: [
                "rowCount": .integer(exportedOrganismCount),
                "exportedOrganismCount": .integer(exportedOrganismCount),
                "metricCount": .integer(matrixMetrics.count),
                "sampleCount": .integer(sampleIds.count),
                "sampleIds": .array(sampleIds.map { .string($0) }),
                "negativeControlSampleIds": .array(negativeControlIds.sorted().map { .string($0) }),
                "tableMode": .string(exportTableModeName),
            ],
            startedAt: startedAt
        )) { outputURL in
            try csv.write(to: outputURL, atomically: true, encoding: .utf8)
        }
    }

    @objc private func exportBatchReportAction(_ sender: Any) {
        guard let window = view.window,
              let result = taxTriageResult,
              let config = taxTriageConfig else { return }

        let panel = MetagenomicsFilePanelFactory.delimitedExportPanel(
            title: "Export Batch Report",
            suggestedName: "batch_report.txt"
        )

        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try self.writeBatchReport(to: url, result: result, config: config)
            } catch {
                logger.error("Failed to export TaxTriage batch report: \(error.localizedDescription, privacy: .public)")
                ResultExportCoordinator.reportFailure(
                    fileName: url.lastPathComponent,
                    error: error,
                    window: window,
                    presenter: self.exportFailurePresenter
                )
            }
        }
    }

    func writeBatchReport(to url: URL, result: TaxTriageResult, config: TaxTriageConfig) throws {
        let startedAt = Date()
        let negativeControlIds = negativeControlSampleIds()
        let reportMetrics = exportMetrics
        let report = TaxTriageBatchExporter.generateSummaryReport(
            result: result,
            config: config,
            metrics: reportMetrics,
            sampleIds: sampleIds
        )
        let reportLineCount = report.split(separator: "\n", omittingEmptySubsequences: false).count
        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app taxtriage batch report export",
            sourceURLs: exportProvenanceSourceURLs(),
            outputURL: url,
            outputFormat: .text,
            argv: ["Lungfish.app", "export-taxtriage-batch-report", "--output", url.path],
            explicitOptions: [
                "outputPath": .file(url),
                "format": .string("txt"),
            ],
            defaults: [
                "format": .string("txt"),
            ],
            resolved: [
                "reportLineCount": .integer(reportLineCount),
                "metricCount": .integer(reportMetrics.count),
                "sampleCount": .integer(sampleIds.count),
                "exportedOrganismCount": .integer(taxTriageCrossSampleOrganismCount(in: reportMetrics)),
                "sampleIds": .array(sampleIds.map { .string($0) }),
                "negativeControlSampleIds": .array(negativeControlIds.sorted().map { .string($0) }),
                "classifierCount": .integer(config.classifiers.count),
                "tableMode": .string(exportTableModeName),
            ],
            startedAt: startedAt
        )) { outputURL in
            try report.write(to: outputURL, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Delimited Export

    /// Exports the organism table as a delimited file via an `NSSavePanel` sheet.
    private func exportDelimited(separator: String, fileExtension: String, fileTypeName: String) {
        guard let window = view.window else {
            logger.warning("Cannot export: no window")
            return
        }

        let baseName: String
        if isBatchGroupMode {
            let selected = selectedDatabaseSampleIds
            baseName = selected.count == 1 ? selected[0] : (batchGroupURL?.lastPathComponent ?? "taxtriage")
        } else {
            baseName = taxTriageConfig?.samples.first?.sampleId ?? "taxtriage"
        }
        let panel = MetagenomicsFilePanelFactory.delimitedExportPanel(
            title: "Export TaxTriage Results as \(fileTypeName)",
            suggestedName: "\(baseName)_results.\(fileExtension)"
        )

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }

            let content = self.buildDelimitedExport(separator: separator)
            do {
                try self.writeDelimitedResults(separator: separator, fileExtension: fileExtension, to: url, content: content)
                logger.info("Exported \(fileTypeName, privacy: .public) to \(url.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("Export failed: \(error.localizedDescription, privacy: .public)")
                ResultExportCoordinator.reportFailure(
                    fileName: url.lastPathComponent,
                    error: error,
                    window: window,
                    presenter: self.exportFailurePresenter
                )
            }
        }
    }

    func writeDelimitedResults(
        separator: String,
        fileExtension: String,
        to url: URL,
        content: String? = nil
    ) throws {
        let startedAt = Date()
        let exportContent = content ?? buildDelimitedExport(separator: separator)
        try ScientificFileExportProvenance.writeAtomically(.init(
            workflowName: "lungfish app taxtriage results export",
            sourceURLs: exportProvenanceSourceURLs(),
            outputURL: url,
            outputFormat: .text,
            argv: ["Lungfish.app", "export-taxtriage-results", "--format", fileExtension, "--output", url.path],
            explicitOptions: [
                "outputPath": .file(url),
                "format": .string(fileExtension),
            ],
            defaults: [
                "format": .string("tsv"),
            ],
            resolved: [
                "rowCount": .integer(delimitedExportRowCount),
                "sampleIds": .array(sampleIds.map { .string($0) }),
                "selectedSamples": .array(exportSelectedSampleIds().map(ParameterValue.string)),
                "selectedSampleIndex": .integer(selectedSampleIndex),
                "selectedSampleId": exportSelectedSampleId().map(ParameterValue.string) ?? .null,
                "organismSearchText": .string(organismSearchText),
                "tableMode": .string(exportTableModeName),
                "sortDescriptors": .array(exportSortDescriptorParameters(delimitedExportSortDescriptors)),
                "metadataColumns": .array(delimitedExportMetadataHeaders.map { .string($0) }),
            ],
            startedAt: startedAt
        )) { outputURL in
            try exportContent.write(to: outputURL, atomically: true, encoding: .utf8)
        }
    }

    private func exportProvenanceSourceURLs() -> [URL] {
        var urls: [URL] = []
        if let databaseURL = taxTriageDatabase?.databaseURL {
            urls.append(databaseURL)
        }
        if let batchGroupURL {
            urls.append(batchGroupURL.appendingPathComponent(TaxTriageBatchManifest.filename))
        }
        // In database mode the config's output folder is where the run was
        // written, which is stale once the result is copied or moved. The
        // relocated result folder below is the one this view reads.
        if !isBatchGroupMode, let outputDirectory = taxTriageConfig?.outputDirectory {
            urls.append(outputDirectory)
        }
        if let resultDirectory = taxTriageResult?.outputDirectory {
            urls.append(resultDirectory)
        }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var exportTableModeName: String {
        if isBatchGroupMode { return "batchGroup" }
        if isMultiSampleSingleResultMode { return "multiSampleFlat" }
        if selectedSampleIndex == 0, sampleIds.count > 1 { return "batchOverview" }
        return "organismTable"
    }

    private func exportSelectedSampleIds() -> [String] {
        if (isBatchGroupMode || isMultiSampleSingleResultMode), let samplePickerState {
            return sampleIds.filter { samplePickerState.selectedSamples.contains($0) }
        }
        if let selected = exportSelectedSampleId() {
            return [selected]
        }
        return sampleIds
    }

    private func exportSelectedSampleId() -> String? {
        guard selectedSampleIndex > 0, selectedSampleIndex <= sampleIds.count else {
            return sampleIds.count == 1 ? sampleIds.first : nil
        }
        return sampleIds[selectedSampleIndex - 1]
    }

    private func exportSortDescriptorParameters(_ descriptors: [NSSortDescriptor]) -> [ParameterValue] {
        descriptors.map { descriptor in
            .dictionary([
                "key": descriptor.key.map(ParameterValue.string) ?? .null,
                "ascending": .boolean(descriptor.ascending),
                "selector": descriptor.selector.map { .string(NSStringFromSelector($0)) } ?? .null,
            ])
        }
    }

    private var exportMetrics: [TaxTriageMetric] {
        metrics.isEmpty ? allBatchGroupRows : metrics
    }

    private func taxTriageCrossSampleOrganismCount(in metrics: [TaxTriageMetric]) -> Int {
        Set(metrics.map {
            $0.organism.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        }).count
    }

    /// Whether CSV/TSV export reads the database flat table (every
    /// production TaxTriage result) rather than the legacy organism table.
    private var exportsDatabaseFlatTable: Bool {
        isBatchGroupMode && taxTriageDatabase != nil
    }

    private var delimitedExportRowCount: Int {
        exportsDatabaseFlatTable ? batchFlatTableView.displayedRows.count : organismTableView.exportRows.count
    }

    private var delimitedExportSortDescriptors: [NSSortDescriptor] {
        exportsDatabaseFlatTable ? batchFlatTableView.tableView.sortDescriptors : organismTableView.exportSortDescriptors
    }

    private var delimitedExportMetadataHeaders: [String] {
        exportsDatabaseFlatTable
            ? batchFlatTableView.metadataColumns.exportHeaders
            : organismTableView.metadataColumns.exportHeaders
    }

    /// Delimited export of the database flat table: the rows it currently
    /// shows (Sample Filter, organism search and column filters applied), in
    /// its current sort order.
    private func buildDatabaseDelimitedExport(separator: String) -> String {
        var headers = [
            "Sample", "Organism", "TASS Score", "Reads", "Unique Reads", "Coverage", "Confidence",
            "Tax ID", "Rank", "Abundance", "Contamination Risk",
        ]
        let metadataColumns = batchFlatTableView.metadataColumns
        headers.append(contentsOf: metadataColumns.exportHeaders)
        var lines = [headers.map { escapeField($0, separator: separator) }.joined(separator: separator)]

        for row in batchFlatTableView.displayedRows {
            let sample = row.sample ?? ""
            let key = "\(sample)\t\(row.organism)"
            let reads = batchFlatTableView.totalReadsByKey[key] ?? row.reads
            let unique = ClassifierUniqueReads.normalized(
                stored: batchFlatTableView.uniqueReadsByKey[key],
                readCount: reads
            )
            var fields: [String] = [
                escapeField(sample, separator: separator),
                escapeField(row.organism, separator: separator),
                String(format: "%.4f", row.tassScore),
                "\(reads)",
                unique.map(String.init) ?? "",
                row.coverageBreadth.map { String(format: "%.2f", $0) } ?? "",
                escapeField(row.confidence ?? "", separator: separator),
                row.taxId.map { "\($0)" } ?? "",
                escapeField(row.rank ?? "", separator: separator),
                row.abundance.map { String(format: "%.6f", $0) } ?? "",
                batchFlatTableView.isContaminationRisk(row) ? "yes" : "",
            ]
            for value in metadataColumns.exportValues(for: sample) {
                fields.append(escapeField(value, separator: separator))
            }
            lines.append(fields.joined(separator: separator))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Builds delimited export content from all table rows.
    func buildDelimitedExport(separator: String) -> String {
        if exportsDatabaseFlatTable {
            return buildDatabaseDelimitedExport(separator: separator)
        }
        var lines: [String] = []

        var headers = [
            "Organism", "TASS Score", "Reads", "Unique Reads", "Coverage", "Confidence",
            "Tax ID", "Rank", "Abundance",
        ]
        // Append visible metadata column headers
        let metaHeaders = organismTableView.metadataColumns.exportHeaders
        headers.append(contentsOf: metaHeaders)
        lines.append(headers.joined(separator: separator))

        for row in organismTableView.exportRows {
            var fields: [String] = []
            fields.append(escapeField(row.organism, separator: separator))
            fields.append(String(format: "%.4f", row.tassScore))
            fields.append("\(row.reads)")
            fields.append(row.uniqueReads.map(String.init) ?? "")
            fields.append(row.coverage.map { String(format: "%.2f", $0) } ?? "")
            fields.append(row.confidence ?? "")
            fields.append(row.taxId.map { "\($0)" } ?? "")
            fields.append(row.rank ?? "")
            fields.append(row.abundance.map { String(format: "%.6f", $0) } ?? "")

            // Append visible metadata column values
            let metaValues = organismTableView.metadataColumns.exportValues
            for value in metaValues {
                fields.append(escapeField(value, separator: separator))
            }
            lines.append(fields.joined(separator: separator))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Escapes a field for CSV output.
    private func escapeField(_ value: String, separator: String) -> String {
        guard separator == "," else { return value }
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }

    // MARK: - Metadata Column Updates

    /// Updates the organism table's metadata columns for the currently selected sample.
    private func updateMetadataColumnsForCurrentSample() {
        let isMultiSample = selectedSampleIndex == 0 && sampleIds.count > 1
        let currentId: String?
        if selectedSampleIndex > 0, selectedSampleIndex <= sampleIds.count {
            currentId = sampleIds[selectedSampleIndex - 1]
        } else if sampleIds.count == 1 {
            currentId = sampleIds.first
        } else {
            currentId = nil
        }
        organismTableView.metadataColumns.isMultiSampleMode = isMultiSample
        organismTableView.metadataColumns.update(store: sampleMetadataStore, sampleId: currentId)
        batchFlatTableView.metadataColumns.update(store: sampleMetadataStore, sampleId: nil)
    }

    // MARK: - Open Externally

    /// The report Open Report shows in database mode: the selected row's
    /// sample first, then the ticked samples, then any sample. Per sample it
    /// tries `<sample>/report/<sample>.odr.pdf`, then `<sample>.odr.html`
    /// (also under a top-level `report/` folder), and only then the run-level
    /// `all.odr.pdf` / `all.odr.html` in a sample's report folder.
    func databaseReportURL() -> URL? {
        guard let root = batchGroupURL else { return nil }
        var orderedSamples: [String] = []
        for sample in [selectedBatchSampleId].compactMap({ $0 }) + selectedDatabaseSampleIds + sampleIds
        where !orderedSamples.contains(sample) {
            orderedSamples.append(sample)
        }
        let fm = FileManager.default
        func sampleReportFolder(_ sample: String) -> URL {
            root.appendingPathComponent(sample, isDirectory: true)
                .appendingPathComponent("report", isDirectory: true)
        }
        for sample in orderedSamples {
            let folders = [sampleReportFolder(sample), root.appendingPathComponent("report", isDirectory: true)]
            for folder in folders {
                let candidates = [
                    folder.appendingPathComponent("\(sample).odr.pdf"),
                    folder.appendingPathComponent("\(sample).odr.html"),
                ]
                if let found = candidates.first(where: { fm.fileExists(atPath: $0.path) }) {
                    return found
                }
            }
        }
        for sample in orderedSamples {
            let folder = sampleReportFolder(sample)
            let candidates = [
                folder.appendingPathComponent("all.odr.pdf"),
                folder.appendingPathComponent("all.odr.html"),
            ]
            if let found = candidates.first(where: { fm.fileExists(atPath: $0.path) }) {
                return found
            }
        }
        return nil
    }

    /// Opens the TaxTriage report in the system's default viewer.
    private func openReportExternally() {
        if isBatchGroupMode {
            if let report = databaseReportURL() {
                reportOpener(report)
                return
            }
            if taxTriageResult == nil {
                if let root = batchGroupURL { reportOpener(root) }
                return
            }
        }
        guard let result = taxTriageResult else { return }

        let pdfFiles = result.allOutputFiles.filter { $0.pathExtension.lowercased() == "pdf" }
        let reportPDFs = result.reportFiles.filter { $0.pathExtension.lowercased() == "pdf" }
        let allPDFs = pdfFiles + reportPDFs

        let fm = FileManager.default
        if let firstPDF = allPDFs.first(where: { fm.fileExists(atPath: $0.path) }) {
            reportOpener(firstPDF)
        } else if let firstReport = result.reportFiles.first(where: { fm.fileExists(atPath: $0.path) }) {
            reportOpener(firstReport)
        } else {
            // Open the output directory
            reportOpener(result.outputDirectory)
        }
    }

    // MARK: - Provenance Popover

    private func showProvenancePopover(relativeTo sender: Any) {
        guard let result = taxTriageResult else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 260)

        let provenanceView = TaxTriageProvenanceView(
            result: result,
            config: taxTriageConfig ?? result.config
        )
        popover.contentViewController = NSHostingController(rootView: provenanceView)

        let anchorView: NSView
        let anchorRect: NSRect
        if let button = sender as? NSView {
            anchorView = button
            anchorRect = button.bounds
        } else {
            anchorView = actionBar
            anchorRect = actionBar.bounds
        }

        popover.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .maxY)
    }

    // MARK: - Testing Accessors

    /// Returns the summary bar for testing.
    public var testSummaryBar: TaxTriageSummaryBar { summaryBar }

    /// Returns the organism table view for testing.
    var testOrganismTableView: TaxTriageOrganismTableView { organismTableView }

    /// Returns the action bar for testing.
    public var testActionBar: ClassifierActionBar { actionBar }

    /// Returns the split view for testing.
    public var testSplitView: NSSplitView { splitView }

    /// Returns the left pane container for testing.
    public var testLeftPaneContainer: NSView { leftPaneContainer }

    /// Returns the right pane container for testing.
    public var testRightPaneContainer: NSView { rightPaneContainer }

    /// Returns the current result for testing.
    public var testResult: TaxTriageResult? { taxTriageResult }

    /// Returns the batch flat table view for testing.
    public var testBatchFlatTableView: BatchTaxTriageTableView { batchFlatTableView }

    /// Returns the batch overview view for testing.
    var testBatchOverviewView: TaxTriageBatchOverviewView { batchOverviewView }

    /// Returns the sample filter segmented control for testing.
    public var testSampleFilterControl: NSSegmentedControl { sampleFilterControl }

    /// Returns the scalable sample filter popup for testing (UX-18).
    public var testSampleFilterPopUp: NSPopUpButton { sampleFilterPopUp }

    /// Test hook: rebuilds the (currently unreachable in production —
    /// see `TaxTriageSampleScopeTests`) single-selection sample filter
    /// control/popup directly, bypassing `configureFromDatabase`'s
    /// batch-group re-hide.
    public func testRebuildSampleFilterSegments() {
        rebuildSampleFilterSegments()
    }

    /// Returns the last requested divider position for testing.
    public var testRequestedDividerPosition: CGFloat? { splitView.requestedDividerPosition(at: 0) }

    /// Returns whether initial split validation is still pending for testing.
    public var testNeedsInitialSplitValidation: Bool { needsInitialSplitValidation }

    /// Returns per-sample deduplicated read counts for testing.
    public var testPerSampleDeduplicatedReadCounts: [String: [String: Int]] { perSampleDeduplicatedReadCounts }

    /// Returns deduplicated read counts for testing.
    public var testDeduplicatedReadCounts: [String: Int] { deduplicatedReadCounts }

    /// Returns parsed BAM accession lengths for testing.
    public var testAccessionLengths: [String: Int] { accessionLengths }

    /// Test hook for applying flat-table read stats updates.
    public func testApplyBatchFlatTableReadStats(sampleId: String, organism: String, totalReads: Int, uniqueReads: Int) {
        applyBatchFlatTableReadStats(
            sampleId: sampleId,
            organism: organism,
            totalReads: totalReads,
            uniqueReads: uniqueReads
        )
    }

    /// Test hook for parsing BAM reference lengths with optional external index.
    public func testParseBamReferenceLengths(bamURL: URL, indexURL: URL?) {
        parseBamReferenceLengths(bamURL: bamURL, indexURL: indexURL)
    }

    /// Test hook for organism/sample accession lookup resolution.
    public func testAccessions(forOrganism organism: String, sampleId: String? = nil) -> [String]? {
        accessions(for: organism, sampleId: sampleId)
    }

#if DEBUG
    var testingOrganismSearchField: NSSearchField { organismSearchField }
    var testingFilterRowHeight: CGFloat {
        sampleFilterHeightConstraint?.constant ?? 0
    }
    var testingPlaceholderFields: [NSTextField] {
        [multiSelectionPrimaryLabel, multiSelectionSecondaryLabel]
    }
    var testingPlaceholderFieldsAreContainedAndSeparated: Bool {
        let containerBounds = multiSelectionPlaceholder.bounds.insetBy(dx: -0.5, dy: -0.5)
        let frames = testingPlaceholderFields.map {
            $0.convert($0.bounds, to: multiSelectionPlaceholder)
        }
        return frames.allSatisfy(containerBounds.contains)
            && !frames[0].intersects(frames[1])
    }
    var testingMiniBAMControllerIdentity: ObjectIdentifier? {
        alignmentEvidenceViewer.map { ObjectIdentifier($0) }
    }
    var testingMiniBAMLoadCount: Int { miniBAMLoadCount }
    var testingOpenReportButton: NSButton { openReportButton }
    var testingEvidenceView: NSView? { alignmentEvidenceViewer?.viewController.view }
    var testingDetailPaneExtent: CGFloat { miniBAMDetailPaneExtent() }
    var testingIsDetailPaneCollapsed: Bool { isMiniBAMDetailPaneCollapsed }

    func testingSetContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        setContentPreferredFontProvider(provider)
    }

    func testingShowFilterRow() {
        organismSearchField.isHidden = false
        sampleFilterTopSpacingConstraint?.constant = 4
        sampleFilterBottomSpacingConstraint?.constant = 4
        updateFilterRowHeightForContentTypography()
    }

    func testingShowMultiSelectionPlaceholder(count: Int) {
        showMultiSelectionPlaceholder(count: count)
    }

    func testingLayoutMultiSelectionPlaceholder(width: CGFloat, height: CGFloat) {
        multiSelectionPlaceholder.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: height
        )
        multiSelectionPlaceholder.layoutSubtreeIfNeeded()
    }
#endif
}


// MARK: - Menu Validation

extension TaxTriageResultViewController: NSMenuItemValidation {
    /// Validates View > Next Sample / Previous Sample / All Samples (nil
    /// target, reached through the responder chain) and the Export menu.
    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(selectNextSample(_:)):
            if isBatchGroupMode { return canSelectNextDatabaseSample }
            return sampleIds.count > 1 && !metrics.isEmpty && selectedSampleIndex < sampleIds.count
        case #selector(selectPreviousSample(_:)):
            if isBatchGroupMode { return canSelectPreviousDatabaseSample }
            return sampleIds.count > 1 && !metrics.isEmpty && selectedSampleIndex > 0
        case #selector(selectAllSamplesOverview(_:)):
            if isBatchGroupMode {
                menuItem.state = isDatabaseOverviewVisible ? .on : .off
                return sampleIds.count > 1
            }
            menuItem.state = .off
            return sampleIds.count > 1 && !metrics.isEmpty
        case #selector(exportCSVAction(_:)), #selector(exportTSVAction(_:)):
            return delimitedExportRowCount > 0
        case #selector(copySummaryAction(_:)):
            return summaryTextForCopy() != nil
        case #selector(exportBatchReportAction(_:)):
            return taxTriageResult != nil && taxTriageConfig != nil
        case #selector(exportBatchMatrixAction(_:)):
            return !exportMetrics.isEmpty
        default:
            return true
        }
    }
}

// MARK: - BatchUniqueReadsCache

/// Codable wrapper for the batch-level unique reads cache (`batch-unique-reads.json`).
///
/// Persisted under `<batchDir>/batch-unique-reads.json`. Keys are `"sampleId\torganism"`,
/// values are unique read counts. Allows instant restoration of the Unique Reads column
/// in batch group mode without re-scanning any BAM files.
private struct BatchUniqueReadsCache: Codable {
    /// Map of `"sampleId\torganism"` → unique read count.
    var sampleOrganism: [String: Int]
}

// MARK: - TaxTriageTableRow

/// A unified table row combining organism report data with TASS metrics.
///
/// Used as the data model for ``TaxTriageOrganismTableView``.
public struct TaxTriageTableRow: Equatable {

    /// Scientific name of the organism.
    public let organism: String

    /// TASS confidence score (0.0 to 1.0).
    public let tassScore: Double

    /// Number of reads assigned to this organism.
    public let reads: Int

    /// Number of reads remaining after PCR-duplicate masking/removal.
    public let uniqueReads: Int?

    /// Coverage breadth percentage (0.0 to 100.0), if available.
    public let coverage: Double?

    /// Qualitative confidence label (e.g., "high", "medium", "low").
    public let confidence: String?

    /// NCBI taxonomy ID, if available.
    public let taxId: Int?

    /// Taxonomic rank code, if available.
    public let rank: String?

    /// Relative abundance (0.0 to 1.0), if available.
    public let abundance: Double?

    /// Whether this organism was detected in a negative control sample (contamination risk).
    public let isContaminationRisk: Bool

    public init(
        organism: String,
        tassScore: Double,
        reads: Int,
        uniqueReads: Int? = nil,
        coverage: Double? = nil,
        confidence: String? = nil,
        taxId: Int? = nil,
        rank: String? = nil,
        abundance: Double? = nil,
        isContaminationRisk: Bool = false
    ) {
        self.organism = organism
        self.tassScore = tassScore
        self.reads = reads
        self.uniqueReads = ClassifierUniqueReads.normalized(stored: uniqueReads, readCount: reads)
        self.coverage = coverage
        self.confidence = confidence
        self.taxId = taxId
        self.rank = rank
        self.abundance = abundance
        self.isContaminationRisk = isContaminationRisk
    }

    func with(reads: Int? = nil, uniqueReads: Int?) -> TaxTriageTableRow {
        TaxTriageTableRow(
            organism: organism,
            tassScore: tassScore,
            reads: reads ?? self.reads,
            uniqueReads: uniqueReads,
            coverage: coverage,
            confidence: confidence,
            taxId: taxId,
            rank: rank,
            abundance: abundance,
            isContaminationRisk: isContaminationRisk
        )
    }
}


// MARK: - TaxTriageOrganismTableView

/// A flat-list NSTableView showing TaxTriage organism identifications.
///
/// Columns: Organism, TASS Score, Reads, Coverage, Confidence (color bar).
/// All columns are sortable and user-resizable.
@MainActor
final class TaxTriageOrganismTableView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {

    // MARK: - Column Identifiers

    private enum ColumnID {
        static let organism = NSUserInterfaceItemIdentifier("organism")
        static let tassScore = NSUserInterfaceItemIdentifier("tassScore")
        static let reads = NSUserInterfaceItemIdentifier("reads")
        static let uniqueReads = NSUserInterfaceItemIdentifier("uniqueReads")
        static let coverage = NSUserInterfaceItemIdentifier("coverage")
        static let confidence = NSUserInterfaceItemIdentifier("confidence")
    }

    // MARK: - Metadata Columns

    /// Controller for dynamic sample metadata columns (from imported CSV/TSV).
    let metadataColumns = MetadataColumnController(
        contentTypographyOwnership: .embedded
    )

    // MARK: - Data

    /// The rows to display, sorted by the active sort descriptor.
    var rows: [TaxTriageTableRow] = [] {
        didSet {
            let previousSelectionKeys = selectedRowKeys()
            let shouldRestoreFocus = tableHasKeyboardFocus
            sortedRows = sortRows(rows)
            tableView.reloadData()
            restoreSelection(using: previousSelectionKeys)
            if shouldRestoreFocus {
                tableView.window?.makeFirstResponder(tableView)
            }
        }
    }

    /// The currently sorted rows.
    private var sortedRows: [TaxTriageTableRow] = []

    var exportRows: [TaxTriageTableRow] {
        sortedRows
    }

    var exportSortDescriptors: [NSSortDescriptor] {
        tableView.sortDescriptors
    }

    /// Shared formatter for integer read counts.
    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter
    }()

    // MARK: - Callbacks

    /// Called when a row is selected. Passes nil for deselection.
    var onRowSelected: ((TaxTriageTableRow?) -> Void)?

    /// Called when multiple rows are selected. Parameter is the count.
    var onMultipleRowsSelected: ((Int) -> Void)?

    /// Called when the user requests BLAST verification for a row with a chosen read count.
    var onBlastRequested: ((TaxTriageTableRow, Int) -> Void)?

    /// Called when the user requests FASTQ extraction from the context menu.
    var onExtractFASTQ: (() -> Void)?

    /// Returns the currently selected table rows.
    func selectedTableRows() -> [TaxTriageTableRow] {
        tableView.selectedRowIndexes.compactMap { index in
            guard index < sortedRows.count else { return nil }
            return sortedRows[index]
        }
    }

    // MARK: - Subviews

    private let scrollView = NSScrollView()
    private let tableView = TaxTriageTableView()
    private var preferredFontProvider: any ContentPreferredFontProviding =
        AppKitContentPreferredFontProvider()
    private nonisolated(unsafe) var contentTypographyObserver: NSObjectProtocol?
#if DEBUG
    private var typographyRealizedCellResolutionCount = 0
#endif

    private var tableHasKeyboardFocus: Bool {
        guard let firstResponder = window?.firstResponder else { return false }
        if firstResponder === tableView { return true }
        if let view = firstResponder as? NSView {
            return view.isDescendant(of: tableView)
        }
        return false
    }

    // MARK: - Initialization

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setupTableView()
        setupLayout()
        setupContextMenu()
        installContentTypographyObservation()
    }

    deinit {
        if let contentTypographyObserver {
            NotificationCenter.default.removeObserver(contentTypographyObserver)
        }
    }

    // MARK: - Setup

    private func setupTableView() {
        // Organism column
        let organismCol = NSTableColumn(identifier: ColumnID.organism)
        organismCol.title = "Organism"
        organismCol.width = 180
        organismCol.minWidth = 100
        organismCol.maxWidth = 400
        organismCol.sortDescriptorPrototype = NSSortDescriptor(key: "organism", ascending: true)
        tableView.addTableColumn(organismCol)

        // TASS Score column
        let scoreCol = NSTableColumn(identifier: ColumnID.tassScore)
        scoreCol.title = "TASS Score"
        scoreCol.width = 80
        scoreCol.minWidth = 60
        scoreCol.maxWidth = 120
        scoreCol.sortDescriptorPrototype = NSSortDescriptor(key: "tassScore", ascending: false)
        scoreCol.headerToolTip = "Taxonomic Assignment Specificity Score: >=0.80 high confidence, 0.40-0.80 medium confidence, <0.40 low confidence"
        tableView.addTableColumn(scoreCol)

        // Reads column
        let readsCol = NSTableColumn(identifier: ColumnID.reads)
        readsCol.title = "Reads"
        readsCol.width = 70
        readsCol.minWidth = 50
        readsCol.maxWidth = 120
        readsCol.sortDescriptorPrototype = NSSortDescriptor(key: "reads", ascending: false)
        tableView.addTableColumn(readsCol)

        // Deduplicated reads column
        let uniqueReadsCol = NSTableColumn(identifier: ColumnID.uniqueReads)
        uniqueReadsCol.title = "Unique Reads"
        uniqueReadsCol.width = 90
        uniqueReadsCol.minWidth = 70
        uniqueReadsCol.maxWidth = 140
        uniqueReadsCol.sortDescriptorPrototype = NSSortDescriptor(key: "uniqueReads", ascending: false)
        tableView.addTableColumn(uniqueReadsCol)

        // Coverage column
        let coverageCol = NSTableColumn(identifier: ColumnID.coverage)
        coverageCol.title = "Coverage"
        coverageCol.width = 70
        coverageCol.minWidth = 50
        coverageCol.maxWidth = 120
        coverageCol.sortDescriptorPrototype = NSSortDescriptor(key: "coverage", ascending: false)
        tableView.addTableColumn(coverageCol)

        // Confidence column (color bar)
        let confidenceCol = NSTableColumn(identifier: ColumnID.confidence)
        confidenceCol.title = "Confidence"
        confidenceCol.width = 80
        confidenceCol.minWidth = 80
        confidenceCol.maxWidth = 140
        confidenceCol.sortDescriptorPrototype = NSSortDescriptor(key: "confidence", ascending: false)
        tableView.addTableColumn(confidenceCol)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.allowsColumnSelection = false
        tableView.headerView = NSTableHeaderView()
        tableView.style = .inset
        tableView.rowHeight = 22
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tableView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(scrollView)

        setAccessibilityRole(.table)
        setAccessibilityLabel("TaxTriage organism identifications")

        // Install metadata column controller for dynamic sample metadata columns.
        metadataColumns.standardColumnNames = [
            "Organism", "TASS Score", "Reads", "Unique Reads", "Coverage", "Confidence",
        ]
        metadataColumns.install(on: tableView)
    }

    private func installContentTypographyObservation() {
        contentTypographyObserver = NotificationCenter.default.addObserver(
            forName: .contentTextSizeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyContentTypography()
            }
        }
        applyContentTypography()
    }

    private func applyContentTypography() {
        taxTriageApplyTableGeometry(
            to: tableView,
            minimumRowHeight: 22,
            preferredFontProvider: preferredFontProvider
        )
        metadataColumns.applyContentTypography()
        let realizedCount = taxTriageForEachRealizedCell(in: tableView) {
            [weak self] column, _, view in
            guard let self else { return }
            if view is TaxTriageConfidenceCellView {
                return
            }
            guard let field = (view as? NSTextField)
                ?? (view as? NSTableCellView)?.textField else {
                return
            }
            self.applyContentTypography(to: field, column: column.identifier)
        }
#if DEBUG
        typographyRealizedCellResolutionCount = realizedCount
#endif
    }

    private func applyContentTypography(
        to field: NSTextField,
        column: NSUserInterfaceItemIdentifier
    ) {
        if MetadataColumnController.isMetadataColumn(column) {
            field.font = ContentTypography.current(
                preferredFontProvider: preferredFontProvider
            ).font(for: .body)
        } else if column == ColumnID.organism {
            field.font = taxTriageContentFont(
                canonicalPointSize: 12,
                weight: .medium,
                preferredFontProvider: preferredFontProvider
            )
        } else {
            field.font = taxTriageContentFont(
                canonicalPointSize: 11,
                digitsOnly: true,
                preferredFontProvider: preferredFontProvider
            )
        }
        if !field.stringValue.isEmpty {
            field.toolTip = field.toolTip ?? field.stringValue
            field.setAccessibilityValue(field.stringValue)
        }
    }

    func setContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        preferredFontProvider = provider
        applyContentTypography()
    }

    private func setupLayout() {
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func setupContextMenu() {
        let menu = NSMenu()

        let blastItem = NSMenuItem(
            title: "Verify with BLAST\u{2026}",
            action: #selector(contextBlastAction(_:)),
            keyEquivalent: ""
        )
        blastItem.target = self
        menu.addItem(blastItem)

        menu.addItem(NSMenuItem.separator())

        let copyItem = NSMenuItem(
            title: "Copy Organism Name",
            action: #selector(contextCopyAction(_:)),
            keyEquivalent: ""
        )
        copyItem.target = self
        menu.addItem(copyItem)

        let copyAccessionItem = NSMenuItem(
            title: "Copy Accession Number",
            action: #selector(contextCopyAccessionAction(_:)),
            keyEquivalent: ""
        )
        copyAccessionItem.target = self
        menu.addItem(copyAccessionItem)

        let copyTaxIdItem = NSMenuItem(
            title: LungfishUIStrings.Classifier.copyTaxonID,
            action: #selector(contextCopyTaxIdAction(_:)),
            keyEquivalent: ""
        )
        copyTaxIdItem.target = self
        menu.addItem(copyTaxIdItem)

        let copyTSVItem = NSMenuItem(
            title: "Copy Row as TSV",
            action: #selector(contextCopyRowTSVAction(_:)),
            keyEquivalent: ""
        )
        copyTSVItem.target = self
        menu.addItem(copyTSVItem)

        menu.addItem(NSMenuItem.separator())

        let lookupItem = NSMenuItem(
            title: "Look Up in NCBI Taxonomy",
            action: #selector(contextLookUpNCBIAction(_:)),
            keyEquivalent: ""
        )
        lookupItem.target = self
        menu.addItem(lookupItem)

        menu.addItem(NSMenuItem.separator())

        let extractItem = NSMenuItem(
            title: "Extract Reads\u{2026}",
            action: #selector(contextExtractFASTQ(_:)),
            keyEquivalent: ""
        )
        extractItem.target = self
        menu.addItem(extractItem)

        tableView.menu = menu
    }

    private func selectedRowKeys() -> [String] {
        let indexes = tableView.selectedRowIndexes
        guard !indexes.isEmpty else { return [] }
        return indexes.compactMap { index in
            guard index >= 0, index < sortedRows.count else { return nil }
            return rowSelectionKey(for: sortedRows[index])
        }
    }

    private func restoreSelection(using keys: [String]) {
        guard !keys.isEmpty else { return }
        let firstKey = keys[0]
        guard let newIndex = sortedRows.firstIndex(where: { rowSelectionKey(for: $0) == firstKey }) else {
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: newIndex), byExtendingSelection: false)
        tableView.scrollRowToVisible(newIndex)
    }

    private func rowSelectionKey(for row: TaxTriageTableRow) -> String {
        let tax = row.taxId.map(String.init) ?? "-"
        return "\(tax)|\(row.organism.lowercased())"
    }

    // MARK: - Menu Item Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(contextBlastAction(_:)) {
            // BLAST requires exactly one selected row
            return tableView.clickedRow >= 0 && tableView.selectedRowIndexes.count <= 1
        }
        if menuItem.action == #selector(contextExtractFASTQ(_:)) {
            // Extract FASTQ requires at least one selected row
            return !tableView.selectedRowIndexes.isEmpty || tableView.clickedRow >= 0
        }
        return true
    }

    @objc private func contextBlastAction(_ sender: Any) {
        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0, clickedRow < sortedRows.count else { return }
        let tableRow = sortedRows[clickedRow]

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 280, height: 160)
        popover.contentViewController = NSHostingController(
            rootView: BlastConfigPopoverView(
                taxonName: tableRow.organism,
                readsClade: tableRow.uniqueReads ?? tableRow.reads,
                database: "core_nt",
                onRun: { [weak self, weak popover] readCount in
                    popover?.close()
                    self?.onBlastRequested?(tableRow, readCount)
                }
            )
        )

        let rowRect = tableView.rect(ofRow: clickedRow)
        popover.show(relativeTo: rowRect, of: tableView, preferredEdge: .maxY)
    }

    @objc private func contextCopyAction(_ sender: Any) {
        let row = tableView.clickedRow
        guard row >= 0, row < sortedRows.count else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sortedRows[row].organism, forType: .string)
    }

    @objc private func contextCopyAccessionAction(_ sender: Any) {
        let row = tableView.clickedRow
        guard row >= 0, row < sortedRows.count else { return }
        let item = sortedRows[row]
        let accession = item.taxId.map { "taxid:\($0)" } ?? item.organism
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(accession, forType: .string)
    }

    @objc private func contextCopyTaxIdAction(_ sender: Any) {
        let row = tableView.clickedRow
        guard row >= 0, row < sortedRows.count else { return }
        let item = sortedRows[row]
        let taxIdString = item.taxId.map(String.init) ?? ""
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(taxIdString, forType: .string)
    }

    @objc private func contextCopyRowTSVAction(_ sender: Any) {
        let row = tableView.clickedRow
        guard row >= 0, row < sortedRows.count else { return }
        let item = sortedRows[row]
        let fields: [String] = [
            item.organism,
            String(format: "%.4f", item.tassScore),
            "\(item.reads)",
            item.uniqueReads.map(String.init) ?? "",
            item.coverage.map { String(format: "%.2f", $0) } ?? "",
            item.confidence ?? "",
            item.taxId.map(String.init) ?? "",
            item.rank ?? "",
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(fields.joined(separator: "\t"), forType: .string)
    }

    @objc private func contextLookUpNCBIAction(_ sender: Any) {
        let row = tableView.clickedRow
        guard row >= 0, row < sortedRows.count else { return }
        let item = sortedRows[row]
        let urlString: String
        if let taxId = item.taxId {
            urlString = "https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=\(taxId)"
        } else {
            let encoded = item.organism.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item.organism
            urlString = "https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?name=\(encoded)"
        }
        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func contextExtractFASTQ(_ sender: Any?) {
        onExtractFASTQ?()
    }

    /// Selects the first row matching the given organism name (case-insensitive).
    func selectRow(byOrganism name: String) {
        let lowered = name.lowercased()
        guard let idx = sortedRows.firstIndex(where: { $0.organism.lowercased() == lowered }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        tableView.scrollRowToVisible(idx)
    }

    // MARK: - Sorting

    private func sortRows(_ rows: [TaxTriageTableRow]) -> [TaxTriageTableRow] {
        guard let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else {
            return rows.sorted { $0.tassScore > $1.tassScore }
        }

        return rows.sorted { a, b in
            let result: Bool
            switch key {
            case "organism":
                result = a.organism.localizedCompare(b.organism) == .orderedAscending
            case "tassScore":
                result = a.tassScore < b.tassScore
            case "reads":
                result = a.reads < b.reads
            case "uniqueReads":
                result = (a.uniqueReads ?? -1) < (b.uniqueReads ?? -1)
            case "coverage":
                result = (a.coverage ?? 0) < (b.coverage ?? 0)
            case "confidence":
                result = a.tassScore < b.tassScore
            default:
                result = false
            }
            return descriptor.ascending ? result : !result
        }
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        sortedRows.count
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        sortedRows = sortRows(rows)
        tableView.reloadData()
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < sortedRows.count else { return nil }
        let item = sortedRows[row]

        switch column.identifier {
        case ColumnID.organism:
            let displayText = item.isContaminationRisk ? "\u{26A0} \(item.organism)" : item.organism
            let cell = makeLabelCell(text: displayText, bold: true)
            if item.isContaminationRisk {
                cell.toolTip = "Contamination risk: detected in negative control sample\n\(item.organism)"
                cell.textColor = .systemOrange
            } else {
                cell.toolTip = item.organism
            }
            return cell

        case ColumnID.tassScore:
            let tassCell = makeLabelCell(text: String(format: "%.3f", item.tassScore), monospaced: true)
            tassCell.toolTip = TaxTriageConfidenceBand.toolTip(label: item.confidence, tassScore: item.tassScore)
            return tassCell

        case ColumnID.reads:
            let text = Self.countFormatter.string(from: NSNumber(value: item.reads)) ?? "\(item.reads)"
            return makeLabelCell(text: text, monospaced: true)

        case ColumnID.uniqueReads:
            if let uniqueReads = item.uniqueReads {
                let text = Self.countFormatter.string(from: NSNumber(value: uniqueReads)) ?? "\(uniqueReads)"
                return makeLabelCell(text: text, monospaced: true)
            }
            return makeLabelCell(text: "\u{2014}", dimmed: true)

        case ColumnID.coverage:
            if let coverage = item.coverage {
                return makeLabelCell(text: String(format: "%.1f%%", coverage), monospaced: true)
            }
            return makeLabelCell(text: "\u{2014}", dimmed: true)

        case ColumnID.confidence:
            let cell = TaxTriageConfidenceCellView()
            cell.score = item.tassScore
            cell.band = TaxTriageConfidenceBand(label: item.confidence, tassScore: item.tassScore)
            cell.toolTip = TaxTriageConfidenceBand.toolTip(label: item.confidence, tassScore: item.tassScore)
            return cell

        default:
            // Check for dynamic metadata columns
            if let cell = metadataColumns.cellForColumn(column, in: tableView, sampleId: metadataColumns.currentSampleId) {
                return cell
            }
            return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selectedIndexes = tableView.selectedRowIndexes
        if selectedIndexes.count > 1 {
            onMultipleRowsSelected?(selectedIndexes.count)
        } else if selectedIndexes.count == 1, let idx = selectedIndexes.first, idx < sortedRows.count {
            onRowSelected?(sortedRows[idx])
        } else {
            onRowSelected?(nil)
        }
    }

    // MARK: - Cell Helpers

    private func makeLabelCell(
        text: String,
        bold: Bool = false,
        monospaced: Bool = false,
        dimmed: Bool = false
    ) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.lineBreakMode = .byTruncatingTail

        if bold {
            field.font = taxTriageContentFont(
                canonicalPointSize: 12,
                weight: .medium,
                preferredFontProvider: preferredFontProvider
            )
        } else if monospaced {
            field.font = taxTriageContentFont(
                canonicalPointSize: 11,
                digitsOnly: true,
                preferredFontProvider: preferredFontProvider
            )
        } else {
            field.font = taxTriageContentFont(
                canonicalPointSize: 11,
                preferredFontProvider: preferredFontProvider
            )
        }

        if dimmed {
            field.textColor = .tertiaryLabelColor
        }
        field.toolTip = text
        field.setAccessibilityValue(text)

        return field
    }

#if DEBUG
    var testingTableView: NSTableView { tableView }
    var testingTableReloadCount: Int { tableView.testingReloadDataCallCount }
    var testingTypographyRealizedCellResolutionCount: Int {
        typographyRealizedCellResolutionCount
    }
    var testingPresentationState: TaxTriageTablePresentationState {
        TaxTriageTablePresentationState(tableView: tableView)
    }

    func testingSetContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        setContentPreferredFontProvider(provider)
    }

    func testingCellView(column identifier: String, row: Int) -> NSView? {
        guard let columnIndex = tableView.tableColumns.firstIndex(where: {
            $0.identifier.rawValue == identifier
        }) else {
            return nil
        }
        return tableView.view(
            atColumn: columnIndex,
            row: row,
            makeIfNecessary: true
        )
    }

    func testingCell(column identifier: String, row: Int) -> NSTextField? {
        let view = testingCellView(column: identifier, row: row)
        return (view as? NSTextField) ?? (view as? NSTableCellView)?.textField
    }

    func testingScroll(to origin: NSPoint) {
        scrollView.contentView.scroll(to: origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
#endif
}


// MARK: - TaxTriageSummaryBar

/// Summary card bar for TaxTriage clinical triage results.
///
/// Shows four cards: Organisms Detected, Pipeline Runtime, High Confidence, and Samples.
@MainActor
public final class TaxTriageSummaryBar: GenomicSummaryCardBar {

    private var organismCount: Int = 0
    private var runtime: TimeInterval = 0
    private var highConfidenceCount: Int = 0
    private var sampleCount: Int = 0

    // MARK: - Batch State

    private var isBatchMode: Bool = false
    private var batchSampleCount: Int = 0
    private var batchTotalOrganisms: Int = 0

    /// Updates the summary bar with result data.
    public func update(
        organismCount: Int,
        runtime: TimeInterval,
        highConfidenceCount: Int,
        sampleCount: Int
    ) {
        isBatchMode = false
        self.organismCount = organismCount
        self.runtime = runtime
        self.highConfidenceCount = highConfidenceCount
        self.sampleCount = sampleCount
        cardsDidChange()
    }

    /// Updates the summary bar to show batch aggregation statistics.
    ///
    /// Displays: "Batch: N samples · M organisms"
    ///
    /// - Parameters:
    ///   - sampleCount: Number of samples in the batch.
    ///   - totalOrganisms: Total number of organism rows across all samples.
    public func updateBatch(sampleCount: Int, totalOrganisms: Int) {
        isBatchMode = true
        batchSampleCount = sampleCount
        batchTotalOrganisms = totalOrganisms
        cardsDidChange()
    }

    public override var cards: [Card] {
        if isBatchMode {
            return [
                Card(label: "Batch", value: "TaxTriage"),
                Card(label: "Samples", value: "\(batchSampleCount)"),
                Card(label: "Organisms", value: GenomicSummaryCardBar.formatCount(batchTotalOrganisms)),
            ]
        }

        let runtimeStr: String
        if runtime >= 60 {
            runtimeStr = String(format: "%.1fm", runtime / 60)
        } else {
            runtimeStr = String(format: "%.1fs", runtime)
        }

        return [
            Card(label: "Organisms", value: "\(organismCount)"),
            Card(label: "Runtime", value: runtimeStr),
            Card(label: "High Confidence", value: "\(highConfidenceCount)"),
            Card(label: "Samples", value: "\(sampleCount)"),
        ]
    }

    public override func abbreviatedLabel(for label: String) -> String {
        switch label {
        case "Organisms": return "Org."
        case "High Confidence": return "Hi-Conf"
        case "Samples": return "Samp."
        default: return super.abbreviatedLabel(for: label)
        }
    }
}


// MARK: - TaxTriageProvenanceView

/// SwiftUI popover showing TaxTriage pipeline provenance metadata.
struct TaxTriageProvenanceView: View {
    let result: TaxTriageResult
    let config: TaxTriageConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("TaxTriage Pipeline Provenance")
                .font(.headline)

            Divider()

            provenanceRow("Samples", value: "\(config.samples.count)")
            provenanceRow("Platform", value: config.platform.displayName)
            provenanceRow("Runtime", value: String(format: "%.1f seconds", result.runtime))
            provenanceRow("Exit Code", value: "\(result.exitCode)")
            provenanceRow("Reports", value: "\(result.reportFiles.count)")
            provenanceRow("Metrics Files", value: "\(result.metricsFiles.count)")

            Divider()

            provenanceRow("Classifiers", value: config.classifiers.joined(separator: ", "))
            provenanceRow("K2 Confidence", value: String(format: "%.2f", config.k2Confidence))
            provenanceRow("Top Hits", value: "\(config.topHitsCount)")
            provenanceRow("Skip Assembly", value: config.skipAssembly ? "Yes" : "No")
            provenanceRow("Max CPUs", value: "\(config.maxCpus)")
            provenanceRow("Max Memory", value: config.maxMemory)

            if let dbPath = config.kraken2DatabasePath {
                provenanceRow("Database", value: dbPath.lastPathComponent)
            }
        }
        .padding(12)
        .frame(width: 340, alignment: .leading)
    }

    private func provenanceRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(value)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}
