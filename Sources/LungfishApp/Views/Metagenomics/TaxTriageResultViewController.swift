// TaxTriageResultViewController.swift - TaxTriage clinical triage result browser
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.lungfish.app", category: "TaxTriageResultVC")

/// Flipped container so Auto Layout `topAnchor` maps to visual top in AppKit.
private final class FlippedPaneContainerView: NSView {
    override var isFlipped: Bool { true }
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
/// Shows the ``MiniBAMViewController`` when an organism is selected, displaying
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
/// This class is `@MainActor` isolated and uses raw `NSSplitView` (not
/// `NSSplitViewController`) per macOS 26 deprecated API rules.
@MainActor
public final class TaxTriageResultViewController: NSViewController, NSSplitViewDelegate {

    // MARK: - Data

    /// The SQLite database backing this view (when opened from a pre-built DB).
    private var taxTriageDatabase: TaxTriageDatabase?

    /// The TaxTriage result driving this view.
    private(set) var taxTriageResult: TaxTriageResult?

    /// The TaxTriage config used for this run (for re-run and provenance).
    private(set) var taxTriageConfig: TaxTriageConfig?

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

    /// Optional downloaded reference FASTA from TaxTriage output.
    private var referenceFastaURL: URL?

    /// Cached accession → reference sequence map loaded from `referenceFastaURL`.
    private var referenceSequenceCache: [String: String] = [:]

    /// Cached normalized organism name → deduplicated read count.
    private var deduplicatedReadCounts: [String: Int] = [:]

    /// Per-sample deduplicated read counts: normalized organism name → [sampleId → unique reads].
    private var perSampleDeduplicatedReadCounts: [String: [String: Int]] = [:]

    /// Background task computing deduplicated read counts per organism row.
    private var deduplicatedReadCountTask: Task<Void, Never>?

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
    private(set) var selectedSampleIndex: Int = 0

    /// Optional pre-selected sample ID set by sidebar routing before `configure` runs.
    var preselectedSampleId: String?

    // MARK: - Multi-Selection Placeholder

    private lazy var multiSelectionPlaceholder: NSView = {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let primary = NSTextField(labelWithString: "")
        primary.font = .systemFont(ofSize: 13, weight: .semibold)
        primary.alignment = .center
        primary.translatesAutoresizingMaskIntoConstraints = false

        let secondary = NSTextField(labelWithString: "Select a single row to view details")
        secondary.font = .systemFont(ofSize: 11)
        secondary.textColor = .tertiaryLabelColor
        secondary.alignment = .center
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
    var isBatchGroupMode: Bool = false

    /// Whether the last `configureFromDatabase` call loaded data from a pre-built manifest
    /// rather than parsing per-sample files. Used to populate the Inspector manifest status.
    private(set) var didLoadFromManifestCache: Bool = false

    /// True when this VC is displaying a single multi-sample TaxTriage result
    /// using the flat table + Inspector sample picker pattern.
    /// Set automatically by `configure(result:config:)` when `sampleIds.count > 1`.
    private(set) var isMultiSampleSingleResultMode: Bool = false

    /// All flat metrics loaded for the batch group, before sample filtering.
    private(set) var allBatchGroupRows: [TaxTriageMetric] = []

    /// The batch group root directory (parent of sample subdirectories).
    var batchGroupURL: URL?

    /// Flat table showing one row per organism × sample combination.
    /// Hidden in normal mode; shown exclusively when `isBatchGroupMode` is true.
    private(set) var batchFlatTableView = BatchTaxTriageTableView()

    /// Container for the right pane content (organism table, batch overview, or batch flat table).
    /// Stored as an instance property so `setupBatchFlatTableView()` can add to it.
    private var rightPaneContainer = NSView()

    // MARK: - Child Views

    private let summaryBar = TaxTriageSummaryBar()
    private let sampleFilterControl = NSSegmentedControl()
    let splitView = NSSplitView()
    private let leftPaneContainer = FlippedPaneContainerView()
    private var miniBAMController: MiniBAMViewController?
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

    /// Unified metagenomics drawer (Samples + Collections + BLAST tabs).
    /// Created lazily and available for view controllers that adopt the unified drawer.
    private(set) lazy var metagenomicsDrawer: MetagenomicsDrawerView = {
        let drawer = MetagenomicsDrawerView()
        drawer.onSampleFilterChanged = { [weak self] visibleIds in
            self?.applyMetadataFilter(visibleSampleIds: visibleIds)
        }
        return drawer
    }()

    /// Metadata per sample, keyed by sampleId.
    private var sampleMetadata: [String: FASTQSampleMetadata] = [:]

    /// Height constraint for the sample filter bar (0 when hidden, 24 when visible).
    private var sampleFilterHeightConstraint: NSLayoutConstraint?
    /// Top spacing constraint between sample filter and split view.
    private var sampleFilterTopSpacingConstraint: NSLayoutConstraint?
    /// Bottom spacing constraint between sample filter and split view.
    private var sampleFilterBottomSpacingConstraint: NSLayoutConstraint?

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
    var sampleMetadataStore: SampleMetadataStore? {
        didSet {
            updateMetadataColumnsForCurrentSample()
        }
    }

    // MARK: - Organism Search

    /// Current organism search text for filtering.
    private var organismSearchText: String = ""

    /// Debounce work item for organism search field changes.
    private var organismFilterWorkItem: DispatchWorkItem?

    // MARK: - Split View State

    /// Whether the initial divider position has been applied.
    private var didSetInitialSplitPosition = false
    private var pendingInitialSplitValidation = false

    // MARK: - Callbacks

    /// Called when the user requests BLAST verification for a selected organism.
    ///
    /// Parameters: organism, readCount, accessions (from BAM mapping), bamURL, bamIndexURL.
    public var onBlastVerification: ((TaxTriageOrganism, Int, [String]?, URL?, URL?) -> Void)?

    /// Called when the user wants to re-run TaxTriage with the same or different settings.
    public var onReRun: (() -> Void)?

    // MARK: - Lifecycle

    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
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

        applyLayoutPreference()
    }

    @objc private func handleLayoutSwapRequested(_ notification: Notification) {
        applyLayoutPreference()
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

        let layout = MetagenomicsPanelLayout.current()
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

        if leftPaneContainer.isHidden {
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

    private func collapsedSplitPositionForHiddenDetail(containerExtent: CGFloat? = nil) -> CGFloat {
        let totalExtent = containerExtent ?? splitContainerExtent()
        guard totalExtent > 0 else { return 0 }
        return splitView.arrangedSubviews.first === leftPaneContainer ? 0 : totalExtent
    }

    private func restoreDefaultSplitPosition(for layout: MetagenomicsPanelLayout? = nil) {
        guard splitView.arrangedSubviews.count > 1 else { return }

        let layout = layout ?? MetagenomicsPanelLayout.current()
        let totalExtent = splitContainerExtent()
        guard totalExtent > 0 else {
            didSetInitialSplitPosition = false
            return
        }

        let minimumExtents = minimumExtents(for: layout)
        let minimumRequiredExtent = minimumExtents.leading + minimumExtents.trailing + splitView.dividerThickness
        guard totalExtent >= minimumRequiredExtent else {
            didSetInitialSplitPosition = false
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
    }

    private func collapseHiddenDetailPaneIfNeeded() {
        guard splitView.arrangedSubviews.count > 1 else { return }

        let totalExtent = splitContainerExtent()
        guard totalExtent > 0 else { return }

        splitView.setPosition(collapsedSplitPositionForHiddenDetail(containerExtent: totalExtent), ofDividerAt: 0)
        splitView.adjustSubviews()
        didSetInitialSplitPosition = true
    }

    private func applyInitialSplitPositionIfNeeded() {
        guard !didSetInitialSplitPosition, splitView.arrangedSubviews.count == 2 else { return }

        if leftPaneContainer.isHidden {
            collapseHiddenDetailPaneIfNeeded()
            return
        }

        let totalExtent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard totalExtent > 0 else { return }

        let layout = MetagenomicsPanelLayout.current()
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
    }

    private func scheduleInitialSplitValidationIfNeeded() {
        guard !pendingInitialSplitValidation else { return }
        pendingInitialSplitValidation = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingInitialSplitValidation = false
            self.resetInitialSplitPositionIfNeeded()
            self.applyInitialSplitPositionIfNeeded()
        }
    }

    /// Swaps the split view pane order based on the persisted layout preference.
    private func applyLayoutPreference() {
        let layout = MetagenomicsPanelLayout.current()
        guard splitView.arrangedSubviews.count == 2 else { return }

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
        } else {
            splitView.isVertical = desiredIsVertical
        }

        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        let totalExtent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        guard totalExtent > 0 else {
            didSetInitialSplitPosition = false
            return
        }

        guard view.window != nil else {
            didSetInitialSplitPosition = false
            return
        }

        if leftPaneContainer.isHidden {
            splitView.setPosition(collapsedSplitPositionForHiddenDetail(containerExtent: totalExtent), ofDividerAt: 0)
            splitView.adjustSubviews()
            didSetInitialSplitPosition = true
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
    }

    // MARK: - Keyboard Shortcuts

    /// Handles Cmd+]/Cmd+[ for sample switching and Cmd+0 for "All Samples".
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.shift),
              !event.modifierFlags.contains(.option),
              sampleIds.count > 1 else {
            return super.performKeyEquivalent(with: event)
        }

        switch event.charactersIgnoringModifiers {
        case "]":
            // Cmd+] — next sample
            let maxIndex = sampleIds.count  // segment 0 is "All", 1..count are samples
            if selectedSampleIndex < maxIndex {
                selectedSampleIndex += 1
                sampleFilterControl.selectedSegment = selectedSampleIndex
                applyCurrentSampleFilter()
            }
            return true

        case "[":
            // Cmd+[ — previous sample
            if selectedSampleIndex > 0 {
                selectedSampleIndex -= 1
                sampleFilterControl.selectedSegment = selectedSampleIndex
                applyCurrentSampleFilter()
            }
            return true

        case "0":
            // Cmd+0 — "All Samples" overview
            selectedSampleIndex = 0
            sampleFilterControl.selectedSegment = 0
            applyCurrentSampleFilter()
            return true

        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    private func setupMiniBAMViewer() {
        let bamVC = MiniBAMViewController()
        bamVC.subjectNoun = "organism"
        bamVC.onReadStatsUpdated = { [weak self] totalReads, uniqueReads in
            guard let self else { return }

            // Ignore the clear() callback (0, 0) — this fires when switching
            // organisms and should not zero out the cached value.
            guard totalReads > 0 else { return }

            if (self.isBatchGroupMode || self.isMultiSampleSingleResultMode),
               let sampleId = self.selectedBatchSampleId,
               let organism = self.selectedBatchOrganismName {
                // For segmented organisms, the miniBAM shows one segment.
                // Keep table totals stable for multi-accession organisms.
                if (self.accessions(for: organism, sampleId: sampleId)?.count ?? 0) > 1 {
                    return
                }
                self.applyBatchFlatTableReadStats(
                    sampleId: sampleId,
                    organism: organism,
                    totalReads: totalReads,
                    uniqueReads: uniqueReads
                )
                return
            }

            guard let selectedOrganismName = self.selectedOrganismName else { return }

            // For segmented organisms, the BAM viewer shows only one segment.
            // Don't overwrite the assembly total with a single segment's count.
            if (self.accessions(for: selectedOrganismName)?.count ?? 1) > 1 {
                return
            }

            // Don't overwrite DB-cached unique reads with miniBAM-computed values.
            let normalized = self.normalizedOrganismName(selectedOrganismName)
            if self.deduplicatedReadCounts[normalized] != nil {
                return
            }

            self.applyReadStats(totalReads: totalReads, uniqueReads: uniqueReads, for: selectedOrganismName)
        }
        addChild(bamVC)
        miniBAMController = bamVC

        let bamView = bamVC.view
        bamView.translatesAutoresizingMaskIntoConstraints = false
        bamView.isHidden = false
        leftPaneContainer.addSubview(bamView)

        NSLayoutConstraint.activate([
            bamView.topAnchor.constraint(equalTo: leftPaneContainer.topAnchor),
            bamView.leadingAnchor.constraint(equalTo: leftPaneContainer.leadingAnchor),
            bamView.trailingAnchor.constraint(equalTo: leftPaneContainer.trailingAnchor),
            bamView.bottomAnchor.constraint(equalTo: leftPaneContainer.bottomAnchor),
        ])
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        resetInitialSplitPositionIfNeeded()
        applyInitialSplitPositionIfNeeded()
        scheduleInitialSplitValidationIfNeeded()
    }


    // MARK: - Sample Extraction

    /// Extracts distinct sample identifiers from metrics, preserving discovery order.
    private func extractSampleIds(from metrics: [TaxTriageMetric]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for metric in metrics {
            if let sample = metric.sample, !sample.isEmpty, seen.insert(sample).inserted {
                ordered.append(sample)
            }
        }
        return ordered
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
        sampleFilterControl.segmentStyle = .texturedRounded
        sampleFilterControl.segmentCount = 1
        sampleFilterControl.setLabel("All Samples", forSegment: 0)
        sampleFilterControl.selectedSegment = 0
        sampleFilterControl.target = self
        sampleFilterControl.action = #selector(sampleFilterChanged(_:))
        sampleFilterControl.translatesAutoresizingMaskIntoConstraints = false
        sampleFilterControl.isHidden = true
        view.addSubview(sampleFilterControl)
    }

    @objc private func sampleFilterChanged(_ sender: NSSegmentedControl) {
        selectedSampleIndex = sender.selectedSegment
        applyCurrentSampleFilter()
    }

    // MARK: - Setup: Organism Search Field

    private lazy var organismSearchField: NSSearchField = {
        let field = NSSearchField()
        field.placeholderString = "Filter organisms\u{2026}"
        field.controlSize = .small
        field.font = .systemFont(ofSize: 11)
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
            applyBatchGroupFilter()
        } else if isMultiSampleSingleResultMode {
            applyMultiSampleFilter()
        } else {
            applyCurrentSampleFilter()
        }
    }

    /// Rebuilds the sample filter segments from the discovered sample IDs.
    private func rebuildSampleFilterSegments() {
        let ids = sampleIds
        if ids.count <= 1 {
            sampleFilterControl.isHidden = true
            organismSearchField.isHidden = true
            sampleFilterHeightConstraint?.constant = 0
            sampleFilterTopSpacingConstraint?.constant = 0
            sampleFilterBottomSpacingConstraint?.constant = 0
            selectedSampleIndex = 0
            return
        }

        sampleFilterControl.segmentCount = ids.count + 1
        sampleFilterControl.setLabel("All Samples", forSegment: 0)
        for (i, sampleId) in ids.enumerated() {
            let display = resolvedDisplayNames[sampleId] ?? sampleId
            sampleFilterControl.setLabel(display, forSegment: i + 1)
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
        sampleFilterControl.isHidden = false
        organismSearchField.isHidden = false
        sampleFilterHeightConstraint?.constant = 24
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
            leftPaneContainer.isHidden = true
            collapseHiddenDetailPaneIfNeeded()
        } else {
            // Restore the left pane (taxonomy/alignments)
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
                bamIndexURL = resolveBamIndex(for: sampleBam, allOutputFiles: taxTriageResult?.allOutputFiles ?? [])
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
        guard let sampleId else {
            selectedSampleIndex = 0
            sampleFilterControl.selectedSegment = 0
            applyCurrentSampleFilter()
            return
        }
        if let idx = sampleIds.firstIndex(of: sampleId) {
            selectedSampleIndex = idx + 1
            sampleFilterControl.selectedSegment = idx + 1
            applyCurrentSampleFilter()
        }
    }

    // MARK: - Setup: Split View

    /// Configures the NSSplitView with BAM alignment viewer (left) and organism table (right).
    ///
    /// Uses raw NSSplitView (not NSSplitViewController) per macOS 26 rules.
    private func setupSplitView() {
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = MetagenomicsPanelLayout.current() != .stacked
        splitView.dividerStyle = .thin
        splitView.delegate = self

        // Left pane: mini BAM alignment viewer (populated on organism selection)
        // The BAM viewer is added in setupMiniBAMViewer() with constraints.


        // Right pane: organism table + batch overview + batch flat table (mutually exclusive).
        // rightPaneContainer is an instance property so setupBatchFlatTableView() can add to it.
        organismTableView.autoresizingMask = [.width, .height]
        rightPaneContainer.addSubview(organismTableView)

        batchOverviewView.autoresizingMask = [.width, .height]
        batchOverviewView.isHidden = true
        rightPaneContainer.addSubview(batchOverviewView)

        // Wire batch overview cell clicks to navigate to organism in sample
        batchOverviewView.onCellSelected = { [weak self] organism, sampleId in
            guard let self else { return }
            self.selectSample(sampleId)
            // Try to select the organism row in the table
            self.organismTableView.selectRow(byOrganism: organism)
        }

        if MetagenomicsPanelLayout.current() == .detailLeading {
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


    /// Sets up the NSTabView with Report and Krona tabs.
    // MARK: - Top Report Parser

    /// Parses preferred confidence/organism reports in deterministic order.
    private func parsePreferredConfidenceMetrics(from result: TaxTriageResult) -> [TaxTriageMetric] {
        let files = result.allOutputFiles
            .filter { !$0.path.contains("/work/") }
            .sorted { $0.path < $1.path }

        let preferred = files.filter {
            $0.lastPathComponent == "multiqc_confidences.txt"
                || $0.lastPathComponent.hasSuffix(".organisms.report.txt")
        }

        var parsed: [TaxTriageMetric] = []
        for url in preferred {
            if let metrics = try? TaxTriageMetricsParser.parse(url: url), !metrics.isEmpty {
                logger.info("Parsed \(metrics.count) TaxTriage metrics from \(url.lastPathComponent, privacy: .public)")
                parsed.append(contentsOf: metrics)
            } else {
                logger.warning("Failed to parse TaxTriage metrics from \(url.lastPathComponent, privacy: .public)")
            }
        }
        if parsed.isEmpty {
            logger.info("No preferred TaxTriage confidence metrics found in output files")
        }
        return parsed
    }

    /// Deduplicates metrics per (organism, sample) pair, keeping the highest TASS.
    ///
    /// Multi-sample runs produce overlapping files (multiqc_confidences.txt +
    /// per-sample .organisms.report.txt) that contain the same data. This removes
    /// true duplicates while preserving distinct per-sample entries.
    private func deduplicatePerOrganismSample(_ metrics: [TaxTriageMetric]) -> [TaxTriageMetric] {
        var seen = Set<String>()
        var deduped: [TaxTriageMetric] = []
        for metric in metrics.sorted(by: { $0.tassScore > $1.tassScore }) {
            let orgKey = normalizedOrganismName(metric.organism)
            let sampleKey = metric.sample ?? ""
            let compositeKey = "\(orgKey)\t\(sampleKey)"
            guard !seen.contains(compositeKey) else { continue }
            seen.insert(compositeKey)
            deduped.append(metric)
        }
        return deduped
    }

    /// Deduplicates metrics per organism (ignoring sample), keeping the highest TASS.
    ///
    /// Used for the merged "All Samples" organism list where each organism
    /// appears once with its best score across all samples.
    private func deduplicatedMetrics(_ metrics: [TaxTriageMetric]) -> [TaxTriageMetric] {
        var seen = Set<String>()
        var deduped: [TaxTriageMetric] = []
        for metric in metrics.sorted(by: { $0.tassScore > $1.tassScore }) {
            let key = normalizedOrganismName(metric.organism)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            deduped.append(metric)
        }
        return deduped
    }

    /// Parses the TaxTriage top_report.tsv into TaxTriageOrganism objects.
    ///
    /// The top_report.tsv has columns:
    /// `abundance, clade_fragments_covered, number_fragments_assigned, rank, taxid, name`
    private func parseTopReport(url: URL) -> [TaxTriageOrganism] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }

        let lines = content.components(separatedBy: .newlines)
        guard lines.count > 1 else { return [] }

        var organisms: [TaxTriageOrganism] = []

        for line in lines.dropFirst() {  // Skip header
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }

            let cols = trimmed.components(separatedBy: "\t")
            guard cols.count >= 6 else { continue }

            let abundance = Double(cols[0]) ?? 0
            let cladeReads = Int(Double(cols[1]) ?? 0)
            let rank = cols[3]
            let taxId = Int(cols[4])
            let name = cols[5].trimmingCharacters(in: .whitespacesAndNewlines)

            let organism = TaxTriageOrganism(
                name: name,
                score: abundance,
                reads: cladeReads,
                coverage: nil,
                taxId: taxId,
                rank: rank
            )
            organisms.append(organism)
        }

        // Sort by clade reads descending
        organisms.sort { $0.reads > $1.reads }

        logger.info("Parsed \(organisms.count) organisms from \(url.lastPathComponent)")
        return organisms
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
        let filtered = allOutputFiles.filter { !$0.path.contains("/work/") }
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
    private func collectFilesRecursively(in directory: URL, matching predicate: (URL) -> Bool) -> [URL] {
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
    private func parseGCFMappingData(url: URL) -> OrganismAccessionMap {
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
    private func mergeOrganismMappings(_ incoming: OrganismAccessionMap, into destination: inout OrganismAccessionMap) {
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

    private func uniqueAccessionsPreservingOrder(_ accessions: [String]) -> [String] {
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

    private func normalizedOrganismName(_ value: String) -> String {
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

    private func referenceSequence(for accession: String) -> String? {
        if referenceSequenceCache.isEmpty {
            loadReferenceSequenceCache()
        }
        return referenceSequenceCache[accession]
    }

    private func loadReferenceSequenceCache() {
        guard referenceSequenceCache.isEmpty else { return }
        guard let fastaURL = referenceFastaURL else { return }
        guard let content = try? String(contentsOf: fastaURL, encoding: .utf8) else {
            logger.warning("Failed to load reference FASTA: \(fastaURL.lastPathComponent, privacy: .public)")
            return
        }

        var cache: [String: String] = [:]
        var currentAccession: String?
        var sequenceBuffer = ""

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix(">") {
                if let accession = currentAccession, !sequenceBuffer.isEmpty {
                    cache[accession] = sequenceBuffer
                }
                sequenceBuffer = ""
                let header = String(line.dropFirst())
                let accession = header
                    .split(whereSeparator: { $0.isWhitespace })
                    .first
                    .map(String.init)
                currentAccession = accession
            } else {
                sequenceBuffer.append(line.uppercased())
            }
        }

        if let accession = currentAccession, !sequenceBuffer.isEmpty {
            cache[accession] = sequenceBuffer
        }

        referenceSequenceCache = cache
        logger.info("Loaded \(cache.count) reference sequences from \(fastaURL.lastPathComponent, privacy: .public)")
    }

    private static func deduplicatedReadCount(from reads: [AlignedRead]) -> Int {
        AlignedRead.deduplicatedReadCount(from: reads)
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

            if self.accessionLengths.isEmpty {
                self.parseBamReferenceLengths(bamURL: bamURL, indexURL: bamIndexURL)
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
                    if self.accessionLengths[accession] == nil {
                        self.parseBamReferenceLengths(bamURL: bamURL, indexURL: bamIndexURL)
                    }
                    guard let contigLength = self.accessionLengths[accession] else { continue }

                    do {
                        let fetchedReads = try await provider.fetchReads(
                            chromosome: accession,
                            start: 0,
                            end: contigLength
                        )
                        if fetchedReads.isEmpty { continue }
                        fetchedAny = true
                        totalUnique += Self.deduplicatedReadCount(from: fetchedReads)
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
            for subdir in subdirs {
                if Task.isCancelled { return }
                let sampleId = subdir.lastPathComponent
                guard let bamURL = bamsBySample[sampleId] else { continue }

                // Resolve BAM index (adjacent or external under this sample subtree).
                let indexCandidates = self.collectFilesRecursively(in: subdir) { fileURL in
                    let ext = fileURL.pathExtension.lowercased()
                    return ext == "bai" || ext == "csi"
                }
                guard let indexURL = self.resolveBamIndex(for: bamURL, allOutputFiles: indexCandidates) else {
                    logger.debug("Batch dedup: no BAM index for sample \(sampleId, privacy: .public)")
                    continue
                }

                // Prefer pre-built sample-scoped mappings from configureFromDatabase().
                var localOrgToAccessions: [String: [String]] = self.organismToAccessionsBySample[sampleId] ?? [:]

                // Fallback: parse any recursive GCF mapping files for this sample.
                if localOrgToAccessions.isEmpty {
                    let gcfFiles = self.collectFilesRecursively(in: subdir) { fileURL in
                        fileURL.lastPathComponent.contains("gcfmapping.tsv")
                    }
                    for gcfURL in gcfFiles {
                        let parsed = self.parseGCFMappingData(url: gcfURL)
                        self.mergeOrganismMappings(parsed, into: &localOrgToAccessions)
                    }
                }

                if localOrgToAccessions.isEmpty {
                    logger.debug("Batch dedup: no GCF mapping for sample \(sampleId, privacy: .public)")
                    continue
                }

                // Parse accession lengths from BAM header for this sample's references.
                var localLengths: [String: Int] = [:]
                if let samtoolsPath = BundleBuildHelpers.managedToolExecutablePath(.samtools) {
                    let samtools = URL(fileURLWithPath: samtoolsPath)
                    let proc = Process()
                    proc.executableURL = samtools
                    proc.arguments = ["view", "-H", bamURL.path]
                    let pipe = Pipe()
                    proc.standardOutput = pipe
                    proc.standardError = Pipe()
                    if let _ = try? proc.run() {
                        let data = pipe.fileHandleForReading.readDataToEndOfFile()
                        proc.waitUntilExit()
                        if let output = String(data: data, encoding: .utf8) {
                            for line in output.components(separatedBy: .newlines) where line.hasPrefix("@SQ") {
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
                                    localLengths[name] = length
                                }
                            }
                        }
                    }
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
                            let fetchedReads = try await provider.fetchReads(
                                chromosome: accession,
                                start: 0,
                                end: contigLength
                            )
                            if fetchedReads.isEmpty { continue }
                            fetchedAny = true
                            totalUnique += Self.deduplicatedReadCount(from: fetchedReads)
                        } catch {
                            logger.debug("Batch dedup: failed for \(normalizedOrganism, privacy: .public) (\(accession, privacy: .public)) in \(sampleId, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        }
                    }

                    if fetchedAny {
                        // Use the BAM-derived unique count — no capping against TSV read count.
                        let trueUnique = max(1, totalUnique)
                        self.perSampleDeduplicatedReadCounts[normalizedOrganism, default: [:]][sampleId] = trueUnique
                        self.syncUniqueReadsToFlatTable()
                    }
                }
            }

            // Persist computed per-sample counts.
            if !Task.isCancelled, !self.perSampleDeduplicatedReadCounts.isEmpty {
                self.persistDeduplicatedReadCounts()

                // Also write the batch-level cache so the flat table loads instantly next time.
                if let batchURL = self.batchGroupURL {
                    let cacheURL = batchURL.appendingPathComponent("batch-unique-reads.json")
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
            perSample[sample] = estimated
        }

        if !perSample.isEmpty {
            perSampleDeduplicatedReadCounts[normalized] = perSample
            syncUniqueReadsToFlatTable()
        }
    }

    /// Saves current deduplicated read counts into the TaxTriage result sidecar.
    private func persistDeduplicatedReadCounts() {
        guard var result = taxTriageResult else { return }
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
        let cache = BatchUniqueReadsCache(sampleOrganism: batchFlatTableView.uniqueReadsByKey)
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
        deduplicatedReadCounts[key] = uniqueReads

        var changed = false
        let updated = organismTableView.rows.map { row -> TaxTriageTableRow in
            guard normalizedOrganismName(row.organism) == key else { return row }
            let resolvedReads = totalReads ?? row.reads
            // Enforce invariant: if the organism has reads, unique reads >= 1
            let safeUnique = (uniqueReads == 0 && resolvedReads > 0) ? resolvedReads : uniqueReads
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
                uniqueReadCount: uniqueReads
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
        // Only apply BAM-computed values for rows that don't already have
        // DB-cached counts. The SQLite database is the source of truth for
        // read counts — the miniBAM viewer should not overwrite them.
        let hadTotal = batchFlatTableView.totalReadsByKey[key] != nil
        let hadUnique = batchFlatTableView.uniqueReadsByKey[key] != nil
        if !hadTotal {
            batchFlatTableView.totalReadsByKey[key] = totalReads
        }
        if !hadUnique {
            batchFlatTableView.uniqueReadsByKey[key] = uniqueReads
        }
        if !hadTotal || !hadUnique {
            batchFlatTableView.reloadReadStatsColumns()
        }

        let normalized = normalizedOrganismName(organism)
        if !hadUnique {
            perSampleDeduplicatedReadCounts[normalized, default: [:]][sampleId] = uniqueReads
        }

        if selectedBatchSampleId == sampleId, selectedBatchOrganismName == organism {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = ","
            let totalReadsText = formatter.string(from: NSNumber(value: totalReads)) ?? "\(totalReads)"
            let uniqueReadsText = formatter.string(from: NSNumber(value: uniqueReads)) ?? "\(uniqueReads)"
            actionBar.updateInfoText("\(organism) — \(totalReadsText) reads (\(uniqueReadsText) unique)")
        }
    }

    /// Merges `perSampleDeduplicatedReadCounts` into `batchFlatTableView.uniqueReadsByKey`
    /// and reloads the table so the Unique Reads column reflects the latest computed values.
    ///
    /// Called after each background deduplication update so the batch flat table stays current.
    /// Uses merge semantics so that DB-cached values are preserved for rows not yet
    /// recomputed from BAM.
    private func syncUniqueReadsToFlatTable() {
        guard isBatchGroupMode || isMultiSampleSingleResultMode else { return }
        for (normalizedOrganism, perSample) in perSampleDeduplicatedReadCounts {
            for (sampleId, count) in perSample {
                // Find the display organism name by matching normalisation.
                // Prefer the raw organism name from allBatchGroupRows for accurate key construction.
                let displayOrganism: String
                if let match = allBatchGroupRows.first(where: {
                    normalizedOrganismName($0.organism) == normalizedOrganism && $0.sample == sampleId
                }) {
                    displayOrganism = match.organism
                } else {
                    // Fall back to the normalized name if no exact match found.
                    displayOrganism = normalizedOrganism
                }
                batchFlatTableView.uniqueReadsByKey["\(sampleId)\t\(displayOrganism)"] = count
            }
        }
        // Reload visible rows without resetting scroll position.
        batchFlatTableView.reloadUniqueReadsColumn()
    }

    private func resolveBamIndex(for bamURL: URL, allOutputFiles: [URL]) -> URL? {
        let fm = FileManager.default
        let adjacentBAI = URL(fileURLWithPath: bamURL.path + ".bai")
        if fm.fileExists(atPath: adjacentBAI.path) { return adjacentBAI }

        let adjacentCSI = URL(fileURLWithPath: bamURL.path + ".csi")
        if fm.fileExists(atPath: adjacentCSI.path) { return adjacentCSI }

        if let externalIndex = allOutputFiles.first(where: {
            $0.lastPathComponent == "\(bamURL.lastPathComponent).bai"
                || $0.lastPathComponent == "\(bamURL.lastPathComponent).csi"
        }) {
            let desired = URL(fileURLWithPath: bamURL.path + ".\(externalIndex.pathExtension)")
            if !fm.fileExists(atPath: desired.path) {
                do {
                    try fm.createSymbolicLink(at: desired, withDestinationURL: externalIndex)
                    logger.info("Linked BAM index \(externalIndex.lastPathComponent, privacy: .public) -> \(desired.lastPathComponent, privacy: .public)")
                } catch {
                    logger.warning("Failed to link BAM index: \(error.localizedDescription, privacy: .public)")
                }
            }
            if fm.fileExists(atPath: desired.path) {
                return desired
            }
            return externalIndex
        }

        guard let samtoolsPath = BundleBuildHelpers.managedToolExecutablePath(.samtools) else {
            logger.warning("Cannot generate BAM index: samtools not found")
            return nil
        }
        let samtools = URL(fileURLWithPath: samtoolsPath)

        let proc = Process()
        proc.executableURL = samtools
        proc.arguments = ["index", bamURL.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            logger.warning("samtools index failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }

        if fm.fileExists(atPath: adjacentBAI.path) { return adjacentBAI }
        if fm.fileExists(atPath: adjacentCSI.path) { return adjacentCSI }
        return nil
    }

    /// Parses BAM reference lengths from samtools output.
    ///
    /// Uses `samtools view -H` for index-independent sequence lengths and
    /// `samtools idxstats` for mapped-read counts when possible.
    private func parseBamReferenceLengths(bamURL: URL, indexURL: URL? = nil) {
        guard let samtoolsPath = BundleBuildHelpers.managedToolExecutablePath(.samtools) else {
            logger.warning("Cannot parse BAM references: samtools not found")
            return
        }
        let samtoolsURL = URL(fileURLWithPath: samtoolsPath)

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
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                return (
                    proc.terminationStatus,
                    String(data: outData, encoding: .utf8) ?? "",
                    String(data: errData, encoding: .utf8) ?? ""
                )
            } catch {
                logger.warning("Failed to run samtools \(arguments.joined(separator: " "), privacy: .public): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }

        // 1) Sequence lengths from header (does not require an index).
        if let header = runSamtools(["view", "-H", bamURL.path]), header.status == 0 {
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
        if let indexURL, fm.fileExists(atPath: indexURL.path) {
            idxstatsAttempts.append(["idxstats", "-X", bamURL.path, indexURL.path])
        }
        idxstatsAttempts.append(["idxstats", bamURL.path])

        var parsedMappedReads = false
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

        let refCount = accessionLengths.count
        if parsedMappedReads {
            logger.info("Parsed BAM references: \(refCount) contigs, mapped-read stats for \(self.accessionMappedReadCounts.count) contigs")
        } else {
            logger.info("Parsed BAM references: \(refCount) contigs (mapped-read stats unavailable)")
        }
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

    // MARK: - Sample Metadata Integration

    /// Configures the metagenomics drawer's Samples tab with metadata.
    ///
    /// Call this after `configure(metrics:...)` once sample metadata has been
    /// loaded from FASTQ bundles.
    public func configureSampleMetadata(_ metadata: [String: FASTQSampleMetadata]) {
        self.sampleMetadata = metadata
        metagenomicsDrawer.configureSamples(sampleIds: sampleIds, metadata: metadata)
    }

    /// Called by the metagenomics drawer when sample visibility changes.
    private func applyMetadataFilter(visibleSampleIds: Set<String>) {
        // Re-filter using the visible set
        let filtered = sampleIds.filter { visibleSampleIds.contains($0) }
        guard !filtered.isEmpty else { return }

        // Reconfigure batch overview with filtered sample IDs
        let negControlIds = negativeControlSampleIds()
        let labels = buildSampleLabelsFromCSVMetadata()
        batchOverviewView.configure(
            metrics: metrics,
            sampleIds: filtered,
            negativeControlSampleIds: negControlIds,
            sampleLabels: labels,
            perSampleDeduplicatedReadCounts: perSampleDeduplicatedReadCounts
        )
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
                manifest.cachedRows[i] = TaxTriageBatchManifest.CachedRow(
                    sample: row.sample,
                    organism: row.organism,
                    tassScore: row.tassScore,
                    reads: row.reads,
                    uniqueReads: uniqueReads,
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

        // Load ALL rows from the DB (filtering by selection happens in applyBatchGroupFilter).
        reloadFromDatabase()

        // Wire batch flat table callbacks (same pattern as configureFromDatabase).
        batchFlatTableView.metadataColumns.isMultiSampleMode = true
        batchFlatTableView.onRowSelected = { [weak self] row in
            guard let self else { return }
            self.actionBar.updateInfoText("1 row selected")
            self.actionBar.setExtractEnabled(true)
            self.hideMultiSelectionPlaceholder()
            self.selectedBatchSampleId = row.sample
            self.selectedBatchOrganismName = row.organism

            // Show the left pane (miniBAM viewer) when a single row is
            // selected — we know exactly which sample + organism to display.
            if self.leftPaneContainer.isHidden {
                self.leftPaneContainer.isHidden = false
                self.restoreDefaultSplitPosition()
            }

            guard let sampleId = row.sample,
                  let bamURL = self.bamFilesBySample[sampleId] else {
                self.miniBAMController?.clear()
                return
            }
            let bamIndexURL = resolveBamIndex(for: bamURL, allOutputFiles: [])
            if let accessions = self.accessions(for: row), !accessions.isEmpty {
                if accessions.contains(where: { self.accessionLengths[$0] == nil }) {
                    self.parseBamReferenceLengths(bamURL: bamURL, indexURL: bamIndexURL)
                }
                if let resolvedAccession = accessions.first(where: { self.accessionLengths[$0] != nil }),
                   let contigLength = self.accessionLengths[resolvedAccession] {
                    self.miniBAMController?.displayContig(
                        bamURL: bamURL,
                        contig: resolvedAccession,
                        contigLength: contigLength,
                        indexURL: bamIndexURL
                    )
                    self.miniBAMController?.view.isHidden = false
                } else {
                    self.miniBAMController?.clear()
                }
            } else {
                self.miniBAMController?.clear()
            }
        }
        batchFlatTableView.onMultipleRowsSelected = { [weak self] rows in
            guard let self else { return }
            self.actionBar.updateInfoText("\(rows.count) rows selected")
            self.actionBar.setExtractEnabled(true)
            self.showMultiSelectionPlaceholder(count: rows.count)
            self.selectedBatchSampleId = nil
            self.selectedBatchOrganismName = nil
            // Hide the left pane when multiple rows are selected — the
            // miniBAM viewer can only show one organism at a time.
            if !self.leftPaneContainer.isHidden {
                self.leftPaneContainer.isHidden = true
                self.collapseHiddenDetailPaneIfNeeded()
            }
        }
        batchFlatTableView.onSelectionCleared = { [weak self] in
            guard let self else { return }
            self.actionBar.updateInfoText("Select an organism to view details")
            self.hideMultiSelectionPlaceholder()
            self.selectedBatchSampleId = nil
            self.selectedBatchOrganismName = nil
            self.miniBAMController?.clear()
        }

        // Show flat table, hide single-result UI.
        sampleFilterControl.isHidden = true
        blastDrawer.isHidden = true
        organismTableView.isHidden = true
        batchOverviewView.isHidden = true
        batchFlatTableView.isHidden = false

        // Show the organism search field.
        organismSearchField.isHidden = false
        sampleFilterHeightConstraint?.constant = 24
        sampleFilterTopSpacingConstraint?.constant = 4
        sampleFilterBottomSpacingConstraint?.constant = 4

        summaryBar.updateBatch(sampleCount: sampleEntries.count, totalOrganisms: allBatchGroupRows.count)

        applyBatchGroupFilter()

        logger.info("configureFromDatabase: loaded \(self.allBatchGroupRows.count) rows across \(self.sampleIds.count) samples from SQLite")
    }

    /// Loads all rows from the SQLite database into `allBatchGroupRows`.
    ///
    /// Fetches every sample's rows (selection filtering is done by `applyBatchGroupFilter`).
    /// Also populates `uniqueReadsByKey` and `bamFilesBySample` from DB columns.
    private func reloadFromDatabase() {
        guard let db = taxTriageDatabase else { return }

        let dbRows = (try? db.fetchRows(samples: sampleIds)) ?? []

        var metrics: [TaxTriageMetric] = []
        var uniqueReadsLookup: [String: Int] = [:]
        var totalReadsLookup: [String: Int] = [:]

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

            // Pre-populate BAM-derived read counts from the database (no background
            // BAM computation needed). reads_aligned and unique_reads are both
            // computed from the BAM at import time by updateUniqueReadsInDB.
            let key = "\(row.sample)\t\(row.organism)"
            if let uniqueReads = row.uniqueReads {
                uniqueReadsLookup[key] = uniqueReads
            }
            totalReadsLookup[key] = row.readsAligned

            // Resolve BAM paths from DB columns (relative to result directory).
            if let bamPath = row.bamPath, !bamPath.isEmpty {
                if bamPath.hasPrefix("/") {
                    bamFilesBySample[row.sample] = URL(fileURLWithPath: bamPath)
                } else if let base = self.batchGroupURL {
                    bamFilesBySample[row.sample] = base.appendingPathComponent(bamPath)
                }
            }

            // Seed accession lookups from DB data so accessions(for:) works.
            if let acc = row.primaryAccession, !acc.isEmpty {
                let normalized = normalizedOrganismName(row.organism)

                var perSample = organismToAccessionsBySample[row.sample] ?? [:]
                perSample[normalized, default: []].append(acc)
                organismToAccessionsBySample[row.sample] = perSample

                if let taxId = row.taxId {
                    var taxMap = taxIDToAccessionsBySample[row.sample] ?? [:]
                    taxMap[taxId, default: []].append(acc)
                    taxIDToAccessionsBySample[row.sample] = taxMap
                }
            }

            // Seed accession lengths from DB (if available).
            if let acc = row.primaryAccession, let len = row.accessionLength, len > 0 {
                accessionLengths[acc] = len
            }
        }

        batchFlatTableView.uniqueReadsByKey = uniqueReadsLookup
        batchFlatTableView.totalReadsByKey = totalReadsLookup
        allBatchGroupRows = metrics
    }

    /// Filters `allBatchGroupRows` by the samples selected in `samplePickerState`
    /// and by the organism search text, then reloads `batchFlatTableView`.
    public func applyBatchGroupFilter() {
        guard isBatchGroupMode, let state = samplePickerState else { return }
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
        sampleFilterHeightConstraint?.constant = 24
        sampleFilterTopSpacingConstraint?.constant = 4
        sampleFilterBottomSpacingConstraint?.constant = 4

        // Switch right pane: hide organism table, show flat table.
        organismTableView.isHidden = true
        batchFlatTableView.isHidden = false
        batchFlatTableView.metadataColumns.isMultiSampleMode = true

        // Use the already-populated `metrics` array as the flat table rows.
        allBatchGroupRows = metrics

        // Wire batch flat table callbacks (same pattern as configureFromDatabase).
        batchFlatTableView.onRowSelected = { [weak self] row in
            guard let self else { return }
            self.actionBar.updateInfoText("1 row selected")
            self.actionBar.setExtractEnabled(true)
            self.hideMultiSelectionPlaceholder()
            self.selectedBatchSampleId = row.sample
            self.selectedBatchOrganismName = row.organism

            // Show the left pane (miniBAM viewer) for the selected sample + organism.
            if self.leftPaneContainer.isHidden {
                self.leftPaneContainer.isHidden = false
                self.restoreDefaultSplitPosition()
            }

            guard let sampleId = row.sample,
                  let bamURL = self.bamFilesBySample[sampleId] else {
                self.miniBAMController?.clear()
                return
            }

            let bamIndexURL = resolveBamIndex(for: bamURL, allOutputFiles: self.taxTriageResult?.allOutputFiles ?? [])

            if let accessions = self.accessions(for: row), !accessions.isEmpty {
                if accessions.contains(where: { self.accessionLengths[$0] == nil }) {
                    self.parseBamReferenceLengths(bamURL: bamURL, indexURL: bamIndexURL)
                }
                if let resolvedAccession = accessions.first(where: { self.accessionLengths[$0] != nil }),
                   let contigLength = self.accessionLengths[resolvedAccession] {
                    self.miniBAMController?.displayContig(
                        bamURL: bamURL,
                        contig: resolvedAccession,
                        contigLength: contigLength,
                        indexURL: bamIndexURL
                    )
                    self.miniBAMController?.view.isHidden = false
                } else {
                    self.miniBAMController?.clear()
                }
            } else {
                self.miniBAMController?.clear()
            }
        }
        batchFlatTableView.onMultipleRowsSelected = { [weak self] rows in
            guard let self else { return }
            self.actionBar.updateInfoText("\(rows.count) rows selected")
            self.actionBar.setExtractEnabled(true)
            self.showMultiSelectionPlaceholder(count: rows.count)
            self.selectedBatchSampleId = nil
            self.selectedBatchOrganismName = nil
            // Hide the left pane when multiple rows are selected.
            if !self.leftPaneContainer.isHidden {
                self.leftPaneContainer.isHidden = true
                self.collapseHiddenDetailPaneIfNeeded()
            }
        }
        batchFlatTableView.onSelectionCleared = { [weak self] in
            guard let self else { return }
            self.actionBar.updateInfoText("Select an organism to view details")
            self.hideMultiSelectionPlaceholder()
            self.selectedBatchSampleId = nil
            self.selectedBatchOrganismName = nil
            self.miniBAMController?.clear()
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

        NSLayoutConstraint.activate([
            // Summary bar (top, below safe area)
            summaryBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            summaryBar.heightAnchor.constraint(equalToConstant: 48),

            // Sample filter control (between summary bar and split view)
            filterTop,
            sampleFilterControl.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            filterHeight,

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
            self.actionBar.setExtractEnabled(true)
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
                    if accessions.contains(where: { self.accessionLengths[$0] == nil }) {
                        self.parseBamReferenceLengths(bamURL: bamURL, indexURL: self.bamIndexURL)
                    }
                    if let resolvedAccession = accessions.first(where: { self.accessionLengths[$0] != nil }),
                       let contigLength = self.accessionLengths[resolvedAccession] {
                        let referenceSequence = self.referenceSequence(for: resolvedAccession)
                        self.miniBAMController?.displayContig(
                            bamURL: bamURL,
                            contig: resolvedAccession,
                            contigLength: contigLength,
                            indexURL: self.bamIndexURL,
                            referenceSequence: referenceSequence
                        )
                        // Show the BAM viewer in the left pane
                        self.miniBAMController?.view.isHidden = false
                    } else {
                        self.miniBAMController?.clear()
                        logger.debug("No reference length found for any mapped accession in \(organismName, privacy: .public)")
                    }
                } else {
                    self.miniBAMController?.clear()
                    logger.debug("No accession mapping for organism: \(organismName, privacy: .public)")
                }
            } else {
                self.miniBAMController?.clear()
            }
        }

        // Table BLAST request -> forward to host with BAM context
        organismTableView.onBlastRequested = { [weak self] row, readCount in
            guard let self else { return }
            let organism = TaxTriageOrganism(
                name: row.organism,
                score: row.tassScore,
                reads: row.reads,
                coverage: row.coverage,
                taxId: row.taxId,
                rank: row.rank
            )
            let rowAccessions = self.accessions(for: row)
            self.onBlastVerification?(organism, readCount, rowAccessions, self.bamURL, self.bamIndexURL)
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
            guard let self else { return }
            let organism = TaxTriageOrganism(
                name: metric.organism,
                score: metric.tassScore,
                reads: metric.reads,
                coverage: metric.coverageBreadth,
                taxId: metric.taxId,
                rank: metric.rank
            )
            let rowAccessions = self.accessions(for: metric)
            let sampleId = metric.sample
            let bamURL = sampleId.flatMap { self.bamFilesBySample[$0] } ?? self.bamURL
            let bamIndexURL: URL?
            if let bamURL {
                bamIndexURL = resolveBamIndex(for: bamURL, allOutputFiles: self.taxTriageResult?.allOutputFiles ?? [])
            } else {
                bamIndexURL = self.bamIndexURL
            }
            self.onBlastVerification?(organism, readCount, rowAccessions, bamURL, bamIndexURL)
        }

        // Action bar BLAST verify (TaxTriage triggers BLAST via table context menu)
        actionBar.onBlastVerify = { [weak self] in
            // TaxTriage BLAST is triggered via the table context menu per-organism;
            // the action bar button is intentionally a no-op placeholder
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
            let cacheURL = batchURL.appendingPathComponent("batch-unique-reads.json")
            try? FileManager.default.removeItem(at: cacheURL)
            // Delete the materialized batch manifest so next open re-parses fresh.
            let manifestURL = batchURL.appendingPathComponent(TaxTriageBatchManifest.filename)
            try? FileManager.default.removeItem(at: manifestURL)
        }
        // Also clear from the per-result sidecar for single-result multi-sample mode.
        if var result = taxTriageResult {
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
        let firstAccession = selectors.first?.accessions.first ?? "extract"
        let sid = selectors.first?.sampleId ?? "sample"
        presentClassifierExtractionDialog(
            tool: .taxtriage,
            resultPath: resultPath,
            selectors: selectors,
            suggestedName: "taxtriage_\(sid)_\(firstAccession)"
        )
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

    // MARK: - Multi-Selection Helpers

    private func showMultiSelectionPlaceholder(count: Int) {
        if let stack = multiSelectionPlaceholder.subviews.first as? NSStackView,
           let primary = stack.arrangedSubviews.first as? NSTextField {
            primary.stringValue = "\(count) items selected"
        }
        miniBAMController?.view.isHidden = true
        multiSelectionPlaceholder.isHidden = false
    }

    private func hideMultiSelectionPlaceholder() {
        multiSelectionPlaceholder.isHidden = true
        // miniBAMController visibility is managed by the row selection handler
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
            actionBar.setExtractEnabled(true)
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
        guard let result = taxTriageResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.summary, forType: .string)
    }

    @objc private func exportBatchMatrixAction(_ sender: Any) {
        guard let window = view.window else { return }
        let csv = TaxTriageBatchExporter.generateOrganismMatrixCSV(
            metrics: metrics,
            sampleIds: sampleIds,
            negativeControlSampleIds: negativeControlSampleIds()
        )

        let panel = NSSavePanel()
        panel.title = "Export Organism Matrix"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "organism_matrix.csv"

        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? csv.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    @objc private func exportBatchReportAction(_ sender: Any) {
        guard let window = view.window,
              let result = taxTriageResult,
              let config = taxTriageConfig else { return }

        let report = TaxTriageBatchExporter.generateSummaryReport(
            result: result,
            config: config,
            metrics: metrics,
            sampleIds: sampleIds
        )

        let panel = NSSavePanel()
        panel.title = "Export Batch Report"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "batch_report.txt"

        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            try? report.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - Delimited Export

    /// Exports the organism table as a delimited file via NSSavePanel.
    ///
    /// Uses `beginSheetModal` (not `runModal`) per macOS 26 rules.
    private func exportDelimited(separator: String, fileExtension: String, fileTypeName: String) {
        guard let window = view.window else {
            logger.warning("Cannot export: no window")
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export TaxTriage Results as \(fileTypeName)"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        let baseName = taxTriageConfig?.samples.first?.sampleId ?? "taxtriage"
        panel.nameFieldStringValue = "\(baseName)_results.\(fileExtension)"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }

            let content = self.buildDelimitedExport(separator: separator)
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                logger.info("Exported \(fileTypeName, privacy: .public) to \(url.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("Export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Builds delimited export content from all table rows.
    func buildDelimitedExport(separator: String) -> String {
        var lines: [String] = []

        var headers = [
            "Organism", "TASS Score", "Reads", "Unique Reads", "Coverage", "Confidence",
            "Tax ID", "Rank", "Abundance",
        ]
        // Append visible metadata column headers
        let metaHeaders = organismTableView.metadataColumns.exportHeaders
        headers.append(contentsOf: metaHeaders)
        lines.append(headers.joined(separator: separator))

        for row in organismTableView.rows {
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

    /// Opens the first available PDF report in the system's default PDF viewer.
    private func openReportExternally() {
        guard let result = taxTriageResult else { return }

        let pdfFiles = result.allOutputFiles.filter { $0.pathExtension.lowercased() == "pdf" }
        let reportPDFs = result.reportFiles.filter { $0.pathExtension.lowercased() == "pdf" }
        let allPDFs = pdfFiles + reportPDFs

        if let firstPDF = allPDFs.first {
            NSWorkspace.shared.open(firstPDF)
        } else if let firstReport = result.reportFiles.first {
            NSWorkspace.shared.open(firstReport)
        } else {
            // Open the output directory
            NSWorkspace.shared.open(result.outputDirectory)
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
    var testSummaryBar: TaxTriageSummaryBar { summaryBar }

    /// Returns the organism table view for testing.
    var testOrganismTableView: TaxTriageOrganismTableView { organismTableView }

    /// Returns the action bar for testing.
    var testActionBar: ClassifierActionBar { actionBar }

    /// Returns the split view for testing.
    var testSplitView: NSSplitView { splitView }

    /// Returns the left pane container for testing.
    var testLeftPaneContainer: NSView { leftPaneContainer }

    /// Returns the right pane container for testing.
    var testRightPaneContainer: NSView { rightPaneContainer }

    /// Returns the current result for testing.
    var testResult: TaxTriageResult? { taxTriageResult }

    /// Returns the batch flat table view for testing.
    var testBatchFlatTableView: BatchTaxTriageTableView { batchFlatTableView }

    /// Returns the batch overview view for testing.
    var testBatchOverviewView: TaxTriageBatchOverviewView { batchOverviewView }

    /// Returns the sample filter segmented control for testing.
    var testSampleFilterControl: NSSegmentedControl { sampleFilterControl }

    /// Returns per-sample deduplicated read counts for testing.
    var testPerSampleDeduplicatedReadCounts: [String: [String: Int]] { perSampleDeduplicatedReadCounts }

    /// Returns deduplicated read counts for testing.
    var testDeduplicatedReadCounts: [String: Int] { deduplicatedReadCounts }

    /// Returns parsed BAM accession lengths for testing.
    var testAccessionLengths: [String: Int] { accessionLengths }

    /// Test hook for applying flat-table read stats updates.
    func testApplyBatchFlatTableReadStats(sampleId: String, organism: String, totalReads: Int, uniqueReads: Int) {
        applyBatchFlatTableReadStats(
            sampleId: sampleId,
            organism: organism,
            totalReads: totalReads,
            uniqueReads: uniqueReads
        )
    }

    /// Test hook for parsing BAM reference lengths with optional external index.
    func testParseBamReferenceLengths(bamURL: URL, indexURL: URL?) {
        parseBamReferenceLengths(bamURL: bamURL, indexURL: indexURL)
    }

    /// Test hook for organism/sample accession lookup resolution.
    func testAccessions(forOrganism organism: String, sampleId: String? = nil) -> [String]? {
        accessions(for: organism, sampleId: sampleId)
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
struct TaxTriageTableRow: Equatable {

    /// Scientific name of the organism.
    let organism: String

    /// TASS confidence score (0.0 to 1.0).
    let tassScore: Double

    /// Number of reads assigned to this organism.
    let reads: Int

    /// Number of reads remaining after PCR-duplicate masking/removal.
    let uniqueReads: Int?

    /// Coverage breadth percentage (0.0 to 100.0), if available.
    let coverage: Double?

    /// Qualitative confidence label (e.g., "high", "medium", "low").
    let confidence: String?

    /// NCBI taxonomy ID, if available.
    let taxId: Int?

    /// Taxonomic rank code, if available.
    let rank: String?

    /// Relative abundance (0.0 to 1.0), if available.
    let abundance: Double?

    /// Whether this organism was detected in a negative control sample (contamination risk).
    let isContaminationRisk: Bool

    init(
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
        self.uniqueReads = uniqueReads
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
    let metadataColumns = MetadataColumnController()

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
    private let tableView = NSTableView()

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
        setupTableView()
        setupContextMenu()
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
        scoreCol.headerToolTip = "Taxonomic Assignment Specificity Score: >=0.95 high confidence, 0.80-0.95 moderate, <0.80 low confidence"
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
        tableView.rowHeight = 24

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autoresizingMask = [.width, .height]

        addSubview(scrollView)

        setAccessibilityRole(.table)
        setAccessibilityLabel("TaxTriage organism identifications")

        // Install metadata column controller for dynamic sample metadata columns.
        metadataColumns.standardColumnNames = [
            "Organism", "TASS Score", "Reads", "Unique Reads", "Coverage", "Confidence",
        ]
        metadataColumns.install(on: tableView)
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
            title: "Copy TaxID",
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
            if item.tassScore >= 0.95 {
                tassCell.toolTip = "High confidence (>=0.95): strong taxonomic signal"
            } else if item.tassScore >= 0.80 {
                tassCell.toolTip = "Moderate confidence (0.80-0.95): likely true positive, verify with BLAST"
            } else {
                tassCell.toolTip = "Low confidence (<0.80): weak signal, may be noise or contamination"
            }
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
            cell.toolTip = item.confidence ?? confidenceTip(for: item.tassScore)
            return cell

        default:
            // Check for dynamic metadata columns
            if let cell = metadataColumns.cellForColumn(column) {
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
            field.font = .systemFont(ofSize: 12, weight: .medium)
        } else if monospaced {
            field.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        } else {
            field.font = .systemFont(ofSize: 11, weight: .regular)
        }

        if dimmed {
            field.textColor = .tertiaryLabelColor
        }

        return field
    }

    private func confidenceTip(for score: Double) -> String {
        if score >= 0.8 { return "High confidence" }
        if score >= 0.4 { return "Medium confidence" }
        return "Low confidence"
    }
}


// MARK: - TaxTriageSummaryBar

/// Summary card bar for TaxTriage clinical triage results.
///
/// Shows four cards: Organisms Detected, Pipeline Runtime, High Confidence, and Samples.
@MainActor
final class TaxTriageSummaryBar: GenomicSummaryCardBar {

    private var organismCount: Int = 0
    private var runtime: TimeInterval = 0
    private var highConfidenceCount: Int = 0
    private var sampleCount: Int = 0

    // MARK: - Batch State

    private var isBatchMode: Bool = false
    private var batchSampleCount: Int = 0
    private var batchTotalOrganisms: Int = 0

    /// Updates the summary bar with result data.
    func update(
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
        needsDisplay = true
    }

    /// Updates the summary bar to show batch aggregation statistics.
    ///
    /// Displays: "Batch: N samples · M organisms"
    ///
    /// - Parameters:
    ///   - sampleCount: Number of samples in the batch.
    ///   - totalOrganisms: Total number of organism rows across all samples.
    func updateBatch(sampleCount: Int, totalOrganisms: Int) {
        isBatchMode = true
        batchSampleCount = sampleCount
        batchTotalOrganisms = totalOrganisms
        needsDisplay = true
    }

    override var cards: [Card] {
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

    override func abbreviatedLabel(for label: String) -> String {
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
