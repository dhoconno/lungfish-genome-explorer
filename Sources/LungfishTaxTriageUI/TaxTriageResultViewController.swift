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

/// What `BAMReferenceSnapshotService` reads from a BAM, under the view's name.
private typealias TaxTriageBAMReferenceSnapshot = BAMReferenceSnapshot

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

    /// Persistence for this controller's layout reads and its tables' column layouts; set before loading its view.
    var layoutDefaults: UserDefaults = .standard {
        didSet {
            organismTableView.metadataColumns.userDefaults = layoutDefaults
            batchFlatTableView.metadataColumns.userDefaults = layoutDefaults
        }
    }

    /// Export-failure presentation seam. Tests inject a spy to assert
    /// a failure was surfaced without driving real `NSAlert` UI.
    var exportFailurePresenter: ExportFailurePresenting = DefaultExportFailurePresenter()

    // MARK: - Data

    /// The SQLite database backing this view (when opened from a pre-built DB).
    private var taxTriageDatabase: TaxTriageDatabase?

    /// The TaxTriage result driving this view.
    private(set) var taxTriageResult: TaxTriageResult?

    /// The TaxTriage config used for this run (for re-run and provenance).
    private(set) var taxTriageConfig: TaxTriageConfig?

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

    /// The sample, accessions and BAM of the last BLAST request this view forwarded to its host. The drawer's re-run
    /// sends them again, so it repeats the request and not the BAM the view holds by then (2.12 lane 12.09b).
    private var lastBlastRequest: (sample: String?, accessions: [String]?, bamURL: URL?, bamIndexURL: URL?)?

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

    /// The sample of the selected flat-table row (batch group mode).
    private var selectedBatchSampleId: String?

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

    /// All flat metrics loaded for the batch group, before sample filtering.
    private(set) var allBatchGroupRows: [TaxTriageMetric] = []

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
    /// counts (the segmented control does not scale — its own
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
    /// Parameters: organism, readCount, accessions (from BAM mapping), bamURL, bamIndexURL. The organism's
    /// `sample` names the sample whose BAM it is, and is nil when the view cannot tell (2.12 lane 12.09b).
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
            self, selector: #selector(handleInspectorSampleSelectionChanged), name: .metagenomicsSampleSelectionChanged, object: nil
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

    /// The panel layout this viewport uses. `MetagenomicsPanelLayout.current`
    /// is the one source of truth shared with the Inspector's Panel Layout
    /// picker, so a fresh install opens in the layout the picker shows as
    /// selected (Detail | List) rather than a viewport-private default.
    private func currentPanelLayout() -> MetagenomicsPanelLayout {
        MetagenomicsPanelLayout.current(defaults: layoutDefaults)
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

    // MARK: - Keyboard Shortcuts

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
                } else {
                    self.applyCurrentSampleFilter()
                }
            }
        }
        organismFilterWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: workItem)
    }

    @objc private func handleInspectorSampleSelectionChanged(_ notification: Notification) {
        guard ScopedEventFilter.accept(notification, for: ScopedEventFilter.hostingWindowScope(of: viewIfLoaded)) else { return }
        guard samplePickerState != nil else { return }
        if isBatchGroupMode {
            databaseSampleSelectionDidChange()
        } else {
            applyCurrentSampleFilter()
        }
    }

    /// Rebuilds the sample filter control from the discovered sample IDs.
    ///
    /// Uses the segmented control for small sample counts, and a popup menu
    /// once the count passes `sampleFilterPopUpThreshold` (the
    /// segmented control does not scale to large sample counts — a run with
    /// dozens of samples produced dozens of tiny, unreadable segments).
    private func rebuildSampleFilterSegments() {
        let ids = sampleIds
        if ids.count <= 1 {
            // The organism search field used to be coupled to the
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
        // A row of a sample reads that sample's maps and no other's (13.66). The maps merged over every loaded
        // sample hold the other samples' accessions, which this sample's BAM and stored lengths do not describe.
        if let sampleId = metric.sample {
            if let taxID = metric.taxId, let own = taxIDToAccessionsBySample[sampleId]?[taxID], !own.isEmpty {
                return rankAccessionsByReadSupport(own)
            }
            let sampleMap = organismToAccessionsBySample[sampleId] ?? [:]
            return lookupAccessions(for: normalizedOrganismName(metric.organism), in: sampleMap)
        }
        if let taxID = metric.taxId, let byTaxID = taxIDToAccessions[taxID], !byTaxID.isEmpty {
            return rankAccessionsByReadSupport(byTaxID)
        }
        return accessions(for: metric.organism)
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

    private nonisolated static func parseBamReferenceLengthsSnapshot(
        bamPath: String,
        indexPath: String?,
        samtoolsPath: String
    ) -> TaxTriageBAMReferenceSnapshot {
        BAMReferenceSnapshotService.snapshot(bamPath: bamPath, indexPath: indexPath, samtoolsPath: samtoolsPath)
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
            // The request this repeats, with its own sample, accessions, BAM and index (2.12 lane 12.09b).
            let heldSample = Self.sample(owning: self.bamURL, in: self.bamFilesBySample)
            let last = self.lastBlastRequest ?? (
                sample: heldSample, accessions: self.accessions(for: result.taxonName, sampleId: heldSample),
                bamURL: self.bamURL, bamIndexURL: self.bamIndexURL
            )
            let organism = TaxTriageOrganism(
                name: result.taxonName, score: 0, reads: result.totalReads,
                coverage: nil, taxId: result.taxId, rank: nil, sample: last.sample
            )
            self.forwardBlastVerification(organism, result.totalReads, last.accessions, last.bamURL, last.bamIndexURL)
        }
    }

    // MARK: - BLAST Drawer Public API

    /// Shows BLAST verification results in the bottom drawer, opening it if needed.
    public func showBlastResults(_ result: BlastVerificationResult, recordURL: URL?) {
        lastBlastResult = result
        blastDrawer.showResults(result, recordURL: recordURL)
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

        // `sampleFilterControl` is created with a single
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

            // Sample filter popup (scalable alternative to the segmented
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
        reserveTheSpaceOfTheDeletedRecomputeButton()
    }

    /// The hidden "Recompute Unique Reads" button this bar held (170 pt plus a 6 pt gap, after Open Report) set
    /// where the info text starts and how narrow this view can get. Deleting it (13.53) moved both, so this
    /// keeps the 176 pt. The bar chains the info text to its last button with one leading constraint, found
    /// here by its two items. If the bar stops using one, nothing moves.
    private func reserveTheSpaceOfTheDeletedRecomputeButton() {
        let infoTextLeading = actionBar.constraints.first {
            $0.firstItem === actionBar.infoLabel && $0.firstAttribute == .leading
                && $0.secondItem === openReportButton && $0.secondAttribute == .trailing
        }
        infoTextLeading?.constant += 176
    }

    private func requestBlastVerification(for row: TaxTriageTableRow, readCount: Int) {
        let organism = TaxTriageOrganism(
            name: row.organism,
            score: row.tassScore,
            reads: row.reads,
            coverage: row.coverage,
            taxId: row.taxId,
            rank: row.rank,
            sample: Self.sample(owning: bamURL, in: bamFilesBySample)
        )
        let rowAccessions = accessions(for: row)
        forwardBlastVerification(organism, readCount, rowAccessions, bamURL, bamIndexURL)
    }

    /// Hands a BLAST request to the host and keeps its sample, accessions and BAM for the drawer's re-run.
    private func forwardBlastVerification(
        _ organism: TaxTriageOrganism, _ readCount: Int, _ accessions: [String]?, _ bamURL: URL?, _ bamIndexURL: URL?
    ) {
        lastBlastRequest = (organism.sample, accessions, bamURL, bamIndexURL)
        onBlastVerification?(organism, readCount, accessions, bamURL, bamIndexURL)
    }

    /// The sample whose BAM `bamURL` is, nil when no sample owns it or several do. A BLAST request names the
    /// sample whose reads it searches, so a BAM that belongs to no one sample names none (2.12 lane 12.09b).
    static func sample(owning bamURL: URL?, in bamFilesBySample: [String: URL]) -> String? {
        guard let bamURL else { return nil }
        let owners = bamFilesBySample.filter { $0.value == bamURL }.keys
        return owners.count == 1 ? owners.first : nil
    }

    private func requestBlastVerification(for metric: TaxTriageMetric, readCount: Int) {
        let rowAccessions = accessions(for: metric)
        let ownBamURL = metric.sample.flatMap { bamFilesBySample[$0] }
        let metricBamURL = ownBamURL ?? bamURL
        // The request names the sample whose BAM goes with it: the metric's own, else the owner of the BAM held now.
        let organism = TaxTriageOrganism(
            name: metric.organism,
            score: metric.tassScore,
            reads: metric.reads,
            coverage: metric.coverageBreadth,
            taxId: metric.taxId,
            rank: metric.rank,
            sample: ownBamURL == nil ? Self.sample(owning: metricBamURL, in: bamFilesBySample) : metric.sample
        )
        let metricBamIndexURL: URL?
        if let metricBamURL {
            metricBamIndexURL = resolveBamIndex(
                for: metricBamURL,
                allOutputFiles: taxTriageResult?.allOutputFiles ?? []
            )
        } else {
            metricBamIndexURL = bamIndexURL
        }
        forwardBlastVerification(organism, readCount, rowAccessions, metricBamURL, metricBamIndexURL)
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
                database: BlastDatabaseID.coreNT.rawValue,
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

    // MARK: - Classifier extraction wiring

    /// Builds per-sample selectors from the current table selection.
    ///
    /// When the batch flat table is visible (batch group mode or multi-sample
    /// single-result mode), reads selected rows from `batchFlatTableView` and
    /// groups accessions per sample. Otherwise falls back to the organism table
    /// which represents one sample at a time.
    private func buildTaxTriageSelectors() -> ExtractReadsPlan {
        // Batch flat table is the primary table in batch/multi-sample modes.
        if !batchFlatTableView.isHidden {
            let selectedMetrics = batchFlatTableView.selectedMetrics()
            guard !selectedMetrics.isEmpty else { return ExtractReadsPlan() }

            // Group accessions by sample id since the flat table may have
            // rows from multiple samples selected simultaneously.
            var bySample: [String: [String]] = [:]
            var rowsLeftOut: [(organism: String, sample: String?)] = []
            for metric in selectedMetrics {
                let sampleId = metric.sample ?? sampleIds.first ?? "unknown"
                let metricAccessions = self.accessions(for: metric) ?? []
                if metricAccessions.isEmpty { rowsLeftOut.append((metric.organism, metric.sample)) }
                bySample[sampleId, default: []].append(contentsOf: metricAccessions)
            }
            let selectors: [ClassifierRowSelector] = bySample.compactMap { (sampleId, accessions) in
                guard !accessions.isEmpty else { return nil }
                return ClassifierRowSelector(
                    sampleId: sampleId,
                    accessions: accessions,
                    taxIds: []
                )
            }
            return ExtractReadsPlan(
                selectors: selectors, selectedRowCount: selectedMetrics.count, rowsLeftOut: rowsLeftOut
            )
        }

        // Single-sample organism table fallback.
        let selectedRows = organismTableView.selectedTableRows()
        var rowsLeftOut: [(organism: String, sample: String?)] = []
        var accessions: [String] = []
        for row in selectedRows {
            let rowAccessions = self.accessions(for: row) ?? []
            if rowAccessions.isEmpty { rowsLeftOut.append((row.organism, nil)) }
            accessions.append(contentsOf: rowAccessions)
        }
        guard !accessions.isEmpty else {
            return ExtractReadsPlan(selectedRowCount: selectedRows.count, rowsLeftOut: rowsLeftOut)
        }
        return ExtractReadsPlan(
            selectors: [ClassifierRowSelector(
                sampleId: selectedBatchSampleId ?? sampleIds.first,
                accessions: accessions,
                taxIds: []
            )],
            selectedRowCount: selectedRows.count,
            rowsLeftOut: rowsLeftOut
        )
    }

    /// What the current table selection stands for in an Extract Reads request.
    private struct ExtractReadsPlan {
        /// One selector for each sample that holds a reference accession for a selected row.
        var selectors: [ClassifierRowSelector] = []
        /// Selected table rows, with or without an accession of their own.
        var selectedRowCount = 0
        /// Selected rows whose own sample holds no reference accession, which Extract Reads leaves out.
        var rowsLeftOut: [(organism: String, sample: String?)] = []
    }

    /// What the Extract Reads dialog shows about the current selection besides its selectors.
    public struct ExtractReadsSelectionSummary: Sendable, Equatable {
        /// Every selected row, the rows left out included, so the dialog's label counts rows and not selectors.
        public let rowCount: Int
        /// A line that names the rows left out, or nil when no selected row is left out.
        public let leftOutNotice: String?

        public init(rowCount: Int, leftOutNotice: String?) {
            self.rowCount = rowCount
            self.leftOutNotice = leftOutNotice
        }
    }

    /// The row count and the left-out line of the current selection. The app reads it when it opens the dialog, in the
    /// same main-actor turn as the selectors, so both come from one selection.
    public var extractReadsSelectionSummary: ExtractReadsSelectionSummary {
        let plan = buildTaxTriageSelectors()
        return ExtractReadsSelectionSummary(
            rowCount: plan.selectedRowCount, leftOutNotice: Self.leftOutNotice(for: plan.rowsLeftOut)
        )
    }

    /// The line under the dialog's selection label, or nil when no row is left out. It names up to four rows, and
    /// from five rows it names three and counts the rest.
    nonisolated static func leftOutNotice(for rows: [(organism: String, sample: String?)]) -> String? {
        guard !rows.isEmpty else { return nil }
        let names = rows.map { row in row.sample.map { "\(row.organism) in \($0)" } ?? row.organism }
        let listed: String
        switch names.count {
        case 1: listed = names[0]
        case 2, 3, 4: listed = names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        default: listed = names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more"
        }
        return rows.count == 1
            ? "1 selected row is left out because \(listed) has no reference accession of its own."
            : "\(rows.count) selected rows are left out because \(listed) have no reference accession of their own."
    }

    /// Tells the user why Extract Reads sent nothing. Tests replace it to read the words without driving real
    /// `NSAlert` UI, as `exportFailurePresenter` does for export failures.
    var extractNoticePresenter: (@MainActor (_ title: String, _ message: String, _ window: NSWindow?) -> Void)?

    /// Presents the unified classifier extraction dialog for the current selection.
    private func presentUnifiedExtractionDialog() {
        guard let resultPath = taxTriageDatabase?.databaseURL ?? taxTriageConfig?.outputDirectory else { return }
        let plan = buildTaxTriageSelectors()
        let selectors = plan.selectors
        guard !selectors.isEmpty else {
            if plan.selectedRowCount > 0 { presentNothingToExtractNotice() }
            return
        }
        let firstAccession = selectors.first?.accessions.first ?? "extract"
        let sid = selectors.first?.sampleId ?? "sample"
        onExtractReadsRequested?(.taxtriage, resultPath, selectors, "taxtriage_\(sid)_\(firstAccession)")
    }

    /// Rows are selected and every one lacks a reference accession in its own sample, so nothing can be extracted.
    private func presentNothingToExtractNotice() {
        let title = "Nothing to extract"
        let message = "None of the selected rows has a reference accession in its own sample, so Lungfish cannot tell which reads belong to them."
        if let extractNoticePresenter {
            extractNoticePresenter(title, message, view.window)
            return
        }
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }

    // MARK: - Negative Control Helpers

    /// Returns sample IDs marked as negative controls in the config.
    private func negativeControlSampleIds() -> Set<String> {
        guard let config = taxTriageConfig else { return [] }
        return Set(config.samples.filter(\.isNegativeControl).map(\.sampleId))
    }

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
        selectedBatchSampleId = nil
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
        exportDelimited(fileExtension: "csv", fileTypeName: "CSV")
    }

    @objc private func exportTSVAction(_ sender: Any) {
        exportDelimited(fileExtension: "tsv", fileTypeName: "TSV")
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

    /// Exports the organism matrix by running `taxtriage export organism-matrix` behind an Operations row
    /// (`beginTaxTriageOrganismMatrixExportOperation`). The leaf reads no `--sample` as every sample, so an empty
    /// Sample Filter returns before the save panel.
    @objc private func exportBatchMatrixAction(_ sender: Any) {
        guard let window = view.window, !exportSelectedSampleIds().isEmpty else { return }

        let panel = MetagenomicsFilePanelFactory.delimitedExportPanel(
            title: "Export Organism Matrix",
            suggestedName: "organism_matrix.csv",
            contentTypes: [.commaSeparatedText]
        )

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let invocation = self.organismMatrixExportInvocation(outputURL: url) else {
                logger.warning("Cannot export the organism matrix: the result has no folder")
                return
            }
            Self.beginTaxTriageOrganismMatrixExportOperation(invocation: invocation) { [weak self] failure in
                logger.error("Failed to export TaxTriage organism matrix: \(failure.message, privacy: .public)")
                ResultExportCoordinator.reportFailure(
                    fileName: url.lastPathComponent,
                    error: failure,
                    window: window,
                    presenter: self?.exportFailurePresenter ?? DefaultExportFailurePresenter()
                )
            }
        }
    }

    /// The `taxtriage export organism-matrix` invocation for the view's state, the ticked samples as the result
    /// records them and the organism search, or nil when the view holds no result folder, which the database route
    /// always sets.
    func organismMatrixExportInvocation(outputURL: URL) -> ViewerExportInvocation? {
        guard let batchGroupURL else { return nil }
        return TaxTriageOrganismMatrixExport.invocation(
            resultURL: batchGroupURL,
            samples: exportSelectedSampleIds(),
            searchText: exportSearchText,
            outputURL: outputURL,
            force: FileManager.default.fileExists(atPath: outputURL.path)
        )
    }

    /// The organism search the exports follow, nil when the field holds only white space.
    private var exportSearchText: String? {
        let trimmed = organismSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Exports the batch report by running `taxtriage export batch-report` behind an Operations row
    /// (`beginTaxTriageBatchReportExportOperation`). The report needs the run's sidecar, as the menu item does, and
    /// an empty Sample Filter returns before the save panel.
    @objc private func exportBatchReportAction(_ sender: Any) {
        guard let window = view.window,
              taxTriageResult != nil,
              taxTriageConfig != nil,
              !exportSelectedSampleIds().isEmpty else { return }

        let panel = MetagenomicsFilePanelFactory.delimitedExportPanel(
            title: "Export Batch Report",
            suggestedName: "batch_report.txt"
        )

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let invocation = self.batchReportExportInvocation(outputURL: url) else {
                logger.warning("Cannot export the batch report: the result has no folder")
                return
            }
            Self.beginTaxTriageBatchReportExportOperation(invocation: invocation) { [weak self] failure in
                logger.error("Failed to export TaxTriage batch report: \(failure.message, privacy: .public)")
                ResultExportCoordinator.reportFailure(
                    fileName: url.lastPathComponent,
                    error: failure,
                    window: window,
                    presenter: self?.exportFailurePresenter ?? DefaultExportFailurePresenter()
                )
            }
        }
    }

    /// The `taxtriage export batch-report` invocation for the view's state, or nil when the view holds no result
    /// folder.
    func batchReportExportInvocation(outputURL: URL) -> ViewerExportInvocation? {
        guard let batchGroupURL else { return nil }
        return TaxTriageBatchReportExport.invocation(
            resultURL: batchGroupURL,
            samples: exportSelectedSampleIds(),
            searchText: exportSearchText,
            outputURL: outputURL,
            force: FileManager.default.fileExists(atPath: outputURL.path)
        )
    }

    // MARK: - Delimited Export

    /// Exports the flat table as CSV or TSV by running `taxtriage export results` behind an Operations row
    /// (`beginTaxTriageResultsExportOperation`). The leaf reads no `--sample` as every sample, so an empty Sample
    /// Filter returns before the save panel.
    private func exportDelimited(fileExtension: String, fileTypeName: String) {
        guard let window = view.window else {
            logger.warning("Cannot export: no window")
            return
        }
        guard !exportSelectedSampleIds().isEmpty,
              let format = ViewerExportDelimitedFormat(rawValue: fileExtension),
              exportDatabaseIsPresent(in: window) else { return }

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
            guard let invocation = self.resultsExportInvocation(format: format, outputURL: url) else {
                logger.warning("Cannot export the results table: the result has no folder")
                return
            }
            Self.beginTaxTriageResultsExportOperation(invocation: invocation) { [weak self] failure in
                logger.error("Failed to export TaxTriage results: \(failure.message, privacy: .public)")
                ResultExportCoordinator.reportFailure(
                    fileName: url.lastPathComponent,
                    error: failure,
                    window: window,
                    presenter: self?.exportFailurePresenter ?? DefaultExportFailurePresenter()
                )
            }
        }
    }

    /// The `taxtriage export results` invocation for the view's state: the ticked samples as the result records
    /// them, the organism search, the flat table's first sort descriptor only, as the table orders by it, its column
    /// filters, and the metadata columns it shows, or nil when the view holds no result folder, which the database
    /// route always sets.
    func resultsExportInvocation(format: ViewerExportDelimitedFormat, outputURL: URL) -> ViewerExportInvocation? {
        guard let batchGroupURL else { return nil }
        let table = batchFlatTableView
        return TaxTriageResultsExport.invocation(
            resultURL: batchGroupURL,
            samples: exportSelectedSampleIds(),
            searchText: exportSearchText,
            sortKeys: table.tableView.sortDescriptors.prefix(1).compactMap { descriptor in
                descriptor.key.map { ViewerExportSortKey(column: $0, ascending: descriptor.ascending) }
            },
            filters: table.columnFilterSet,
            metadataColumns: table.metadataColumns.exportHeaders,
            format: format,
            outputURL: outputURL,
            force: FileManager.default.fileExists(atPath: outputURL.path)
        )
    }

    private func exportSelectedSampleIds() -> [String] {
        if isBatchGroupMode, let samplePickerState {
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

    private var exportMetrics: [TaxTriageMetric] {
        metrics.isEmpty ? allBatchGroupRows : metrics
    }

    /// Whether CSV/TSV export reads the database flat table (every
    /// production TaxTriage result) rather than the legacy organism table.
    private var exportsDatabaseFlatTable: Bool {
        isBatchGroupMode && taxTriageDatabase != nil
    }

    private var delimitedExportRowCount: Int {
        exportsDatabaseFlatTable ? batchFlatTableView.displayedRows.count : organismTableView.exportRows.count
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

    /// Returns the scalable sample filter popup for testing.
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


// MARK: - Find

extension TaxTriageResultViewController {
    /// Edit > Find focuses the filter row's Filter organisms field, the one
    /// organism filter the view shows in every mode.
    @objc func performFindPanelAction(_ sender: Any?) {
        guard !organismSearchField.isHidden else { return }
        view.window?.makeFirstResponder(organismSearchField)
    }
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
            return taxTriageResult != nil && taxTriageConfig != nil && !exportSelectedSampleIds().isEmpty
        case #selector(exportBatchMatrixAction(_:)):
            return !exportMetrics.isEmpty
        default:
            return true
        }
    }
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
final class TaxTriageOrganismTableView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation, ResultRowMenuActions {
    /// The pasteboard the copy commands write. Tests substitute a private one.
    var pasteboard: NSPasteboard = .general

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
        scoreCol.headerToolTip = TaxTriageConfidenceBand.headerToolTip
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
        tableView.menu = TaxTriageRowCommands.makeContextMenu(target: self)
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

    // MARK: - Row Commands

    private func subject(for row: TaxTriageTableRow) -> TaxTriageRowSubject {
        TaxTriageRowSubject(
            organism: row.organism,
            taxId: row.taxId,
            tsvFields: [
                row.organism,
                String(format: "%.4f", row.tassScore),
                "\(row.reads)",
                row.uniqueReads.map(String.init) ?? "",
                row.coverage.map { String(format: "%.2f", $0) } ?? "",
                row.confidence ?? "",
                row.taxId.map(String.init) ?? "",
                row.rank ?? "",
            ]
        )
    }

    /// The table row indexes a menu command acts on. A context-menu command
    /// acts on the clicked row, or on the whole selection when the clicked
    /// row is part of it. A menu-bar command or accessibility action acts on
    /// the selection, because `clickedRow` outlives the click that set it.
    private func commandTargetRows(sender: Any?) -> [Int] {
        let selected = tableView.selectedRowIndexes
        let rows: [Int]
        if let menuItem = sender as? NSMenuItem,
           ResultRowMenuValidation.isContextMenuItem(menuItem, in: [tableView.menu]),
           tableView.clickedRow >= 0, !selected.contains(tableView.clickedRow) {
            rows = [tableView.clickedRow]
        } else {
            rows = Array(selected)
        }
        return rows.filter { sortedRows.indices.contains($0) }
    }

    private func availableRowCommands(forRows rows: [Int]) -> [ResultRowCommand] {
        TaxTriageRowCommands.available(for: rows.map { subject(for: sortedRows[$0]) })
    }

    /// Makes the clicked row the selection when a context-menu command was
    /// aimed at it, so the selection-based handlers act on the right rows.
    private func adoptContextTargets(sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              ResultRowMenuValidation.isContextMenuItem(menuItem, in: [tableView.menu]) else { return }
        let clicked = tableView.clickedRow
        guard clicked >= 0, !tableView.selectedRowIndexes.contains(clicked) else { return }
        tableView.selectRowIndexes(IndexSet(integer: clicked), byExtendingSelection: false)
    }

    private func perform(_ command: ResultRowCommand, sender: Any?) {
        let rows = commandTargetRows(sender: sender)
        guard rows.count == 1, let index = rows.first else { return }
        TaxTriageRowCommands.perform(command, on: subject(for: sortedRows[index]), pasteboard: pasteboard)
    }

    /// The context menu follows the selection (or the clicked row). The
    /// menu-bar items under Selection > Table Row are enabled only while the
    /// table has keyboard focus.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = ResultRowCommand.command(for: menuItem.action) else { return true }
        guard TaxTriageRowCommands.supported.contains(command) else { return false }
        guard ResultRowMenuValidation.isReachable(menuItem, table: tableView) else { return false }
        return availableRowCommands(forRows: commandTargetRows(sender: menuItem)).contains(command)
    }

    /// The accessibility custom actions of the row at `row`: every
    /// single-row command its context menu offers, named the same. The
    /// handlers resolve the row from `cellView` when they run and select it
    /// first, so the shared handlers act on it through the selection.
    private func accessibilityActions(forRow row: Int, cellView: NSView) -> [NSAccessibilityCustomAction] {
        guard sortedRows.indices.contains(row) else { return [] }
        return ResultRowMenuValidation.cellActions(availableRowCommands(forRows: [row]), on: cellView) {
            [weak self] command, currentRow in
            guard let self else { return }
            self.tableView.selectRowIndexes(IndexSet(integer: currentRow), byExtendingSelection: false)
            _ = NSApp.sendAction(command.menuSelector, to: self, from: nil)
        }
    }

    // MARK: Menu handlers

    @objc func blastVerifySelectedRow(_ sender: Any?) {
        let rows = commandTargetRows(sender: sender)
        guard rows.count == 1, let index = rows.first else { return }
        let tableRow = sortedRows[index]
        // A menu-bar or accessibility invocation can target an off-screen row.
        tableView.scrollRowToVisible(index)
        TaxTriageRowCommands.presentBlastPopover(
            taxonName: tableRow.organism,
            readsClade: tableRow.uniqueReads ?? tableRow.reads,
            anchorRect: tableView.rect(ofRow: index),
            in: tableView
        ) { [weak self] readCount in
            self?.onBlastRequested?(tableRow, readCount)
        }
    }

    @objc func copySelectedRowName(_ sender: Any?) { perform(.copyName, sender: sender) }
    @objc func copySelectedRowTaxonID(_ sender: Any?) { perform(.copyTaxonID, sender: sender) }
    @objc func copySelectedRowAsTSV(_ sender: Any?) { perform(.copyAsTSV, sender: sender) }
    @objc func openSelectedRowTaxonomyOnNCBI(_ sender: Any?) { perform(.openTaxonomyOnNCBI, sender: sender) }

    @objc func extractReadsForSelectedRows(_ sender: Any?) {
        adoptContextTargets(sender: sender)
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
        guard let cell = makeCell(for: tableColumn, row: row) else { return nil }
        AccessibilityCellActions.install(accessibilityActions(forRow: row, cellView: cell), on: cell)
        return cell
    }

    private func makeCell(for tableColumn: NSTableColumn?, row: Int) -> NSView? {
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
