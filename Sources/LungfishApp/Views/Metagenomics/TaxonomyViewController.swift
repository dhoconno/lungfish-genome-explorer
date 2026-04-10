// TaxonomyViewController.swift - Complete taxonomy browser combining sunburst and table
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import SwiftUI
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "TaxonomyViewController")

// MARK: - BatchClassificationRow

/// A flat row representing a single taxon from a single sample, used when
/// aggregating multiple Kraken2 results into a batch view.
struct BatchClassificationRow: Sendable {
    let sample: String
    let taxonName: String
    let taxId: Int
    let rank: String
    let rankDisplayName: String
    let readsDirect: Int
    let readsClade: Int
    let percentage: Double

    static func fromTree(_ tree: TaxonTree, sampleId: String) -> [BatchClassificationRow] {
        tree.allNodes().compactMap { node in
            guard node.taxId != 1, node.rank != .unclassified else { return nil }
            return BatchClassificationRow(
                sample: sampleId, taxonName: node.name, taxId: node.taxId,
                rank: node.rank.code, rankDisplayName: node.rank.displayName,
                readsDirect: node.readsDirect, readsClade: node.readsClade,
                percentage: node.fractionClade * 100.0
            )
        }
    }
}

// MARK: - TaxonomyViewController

/// A full-screen taxonomy browser combining a sunburst chart and hierarchical table.
///
/// `TaxonomyViewController` is the primary UI for displaying Kraken2 classification
/// results. It replaces the normal sequence viewer content area following the same
/// child-VC pattern used by ``FASTACollectionViewController``.
///
/// ## Layout
///
/// ```
/// +------------------------------------------+
/// | Summary Bar (48pt)                       |
/// +------------------------------------------+
/// | Breadcrumb Bar (28pt)                    |
/// +------------------------------------------+
/// |  Sunburst Chart  |  Taxonomy Table       |
/// |                  |                       |
/// |    (resizable NSSplitView)               |
/// +------------------------------------------+
/// | Action Bar (36pt)                        |
/// +------------------------------------------+
/// ```
///
/// ## Selection Synchronization
///
/// Clicking a segment in the sunburst selects the corresponding row in the table,
/// and clicking a table row highlights the corresponding sunburst segment. A
/// suppression flag prevents infinite feedback loops (per project conventions).
///
/// ## Export
///
/// The action bar provides export capabilities:
/// - **Export as CSV/TSV**: Writes the full taxonomy table in depth-first order
///   via ``NSSavePanel`` (using `beginSheetModal`, not `runModal`, per macOS 26 rules).
/// - **Copy Summary**: Copies the classification summary text to the pasteboard.
///
/// ## Provenance
///
/// A collapsible provenance popover shows pipeline metadata (tool version, database,
/// preset, confidence, runtime, input file) when a classification result is loaded.
///
/// ## Extraction
///
/// When the user clicks "Extract Sequences" in the action bar or context menu,
/// the hosting controller routes the selection to ``TaxonomyExtractionPipeline``.
///
/// ## Thread Safety
///
/// This class is `@MainActor` isolated and uses raw `NSSplitView` (not
/// `NSSplitViewController`) per macOS 26 deprecated API rules.
@MainActor
public final class TaxonomyViewController: NSViewController, NSSplitViewDelegate {

    // MARK: - Data

    /// The classification result driving this view.
    var classificationResult: ClassificationResult?

    /// The taxonomy tree extracted from the result.
    var tree: TaxonTree?

    // MARK: - Inspector Sample Picker

    /// Kraken2 sample entry for the unified picker.
    public struct Kraken2SampleEntry: ClassifierSampleEntry {
        public let id: String
        public let displayName: String
        public let classifiedReads: Int

        public var metricLabel: String { "reads" }
        public var metricValue: String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return formatter.string(from: NSNumber(value: classifiedReads)) ?? "\(classifiedReads)"
        }
    }

    /// Observable state shared with the Inspector sample picker.
    public var samplePickerState: ClassifierSamplePickerState!

    /// Sample entries for the unified picker (single entry for Kraken2).
    public var sampleEntries: [Kraken2SampleEntry] = []

    /// Common prefix stripped from sample display names (empty for single-sample).
    public var strippedPrefix: String = ""

    /// Sample metadata for dynamic column display in the taxonomy table.
    var sampleMetadataStore: SampleMetadataStore? {
        didSet {
            // Kraken2 is single-sample: use the first (only) sample entry's ID.
            let sampleId = sampleEntries.first?.id
            taxonomyTableView.metadataColumns.update(store: sampleMetadataStore, sampleId: sampleId)
        }
    }

    // MARK: - Child Views

    private let summaryBar = TaxonomySummaryBar()
    private let breadcrumbBar = TaxonomyBreadcrumbBar()
    let splitView = NSSplitView()
    private let sunburstView = TaxonomySunburstView()
    private let taxonomyTableView = TaxonomyTableView()
    let actionBar = ClassifierActionBar()

    // MARK: - Collections / BLAST Toggle Buttons (custom, managed by this VC)

    let collectionsToggleButton: NSButton = {
        let btn = NSButton(title: "Collections", target: nil, action: nil)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.bezelStyle = .accessoryBarAction
        btn.setButtonType(.pushOnPushOff)
        btn.image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "Collections")
        btn.imagePosition = .imageLeading
        btn.controlSize = .small
        btn.font = .systemFont(ofSize: 11)
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.setAccessibilityLabel("Toggle Taxa Collections Drawer")
        return btn
    }()

    let blastResultsToggleButton: NSButton = {
        let btn = NSButton(title: "BLAST Results", target: nil, action: nil)
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.bezelStyle = .accessoryBarAction
        btn.setButtonType(.pushOnPushOff)
        btn.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "BLAST Results")
        btn.imagePosition = .imageLeading
        btn.controlSize = .small
        btn.font = .systemFont(ofSize: 11)
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.setAccessibilityLabel("Toggle BLAST Results Drawer")
        return btn
    }()

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

    // MARK: - Action Bar State

    /// The currently selected taxon node (for info text updates).
    private var selectedTaxonNode: TaxonNode?

    /// Total reads for percentage display in the action bar.
    private var totalReadsForActionBar: Int = 0

    // MARK: - Split View State

    /// Whether the initial divider position has been applied.
    /// `setPosition` only works after the split view has real bounds, so
    /// it is deferred to `viewDidLayout`.
    private var didSetInitialSplitPosition = false

    // MARK: - Selection Sync

    /// When true, programmatic selection changes don't trigger cross-view sync.
    /// Prevents infinite loops when syncing between sunburst and table.
    private var suppressSelectionSync = false

    private func isActionableTaxonNode(_ node: TaxonNode?) -> Bool {
        guard let node else { return false }
        return node.taxId > 1
    }

    // MARK: - Callbacks

    /// Called when the user requests sequence extraction from a taxon.
    ///
    /// - Parameters:
    ///   - node: The taxon to extract reads for.
    ///   - includeChildren: Whether to include child taxa in the extraction.
    public var onExtractSequences: ((TaxonNode, Bool) -> Void)?

    /// Called when the user requests batch extraction from a taxa collection.
    ///
    /// - Parameters:
    ///   - collection: The taxa collection to extract.
    ///   - result: The current classification result.
    public var onBatchExtract: ((TaxaCollection, ClassificationResult) -> Void)?

    /// Called when the user confirms BLAST verification for a taxon via the popover.
    ///
    /// - Parameters:
    ///   - node: The taxon to verify.
    ///   - readCount: The number of reads to submit to BLAST.
    public var onBlastVerification: ((TaxonNode, Int) -> Void)?

    // MARK: - BLAST State

    /// The last-received BLAST verification result, for re-run support.
    var lastBlastResult: BlastVerificationResult?

    /// The taxon node that was last sent to BLAST, for re-run support.
    var lastBlastNode: TaxonNode?

    // MARK: - Batch Mode

    /// Whether this view controller is displaying an aggregated batch result.
    var isBatchMode: Bool = false

    /// All flat rows loaded from each sample's kreport in batch mode.
    var allBatchRows: [BatchClassificationRow] = []

    /// Flat table used in batch mode (sibling of `splitView`).
    private(set) var batchTableView = BatchClassificationTableView()

    /// The URL of the batch result directory (set during `configureFromDatabase`).
    var batchURL: URL?

    /// Sample currently rendered in the hierarchical taxonomy/sunburst views in batch mode.
    private(set) var currentBatchSampleId: String?

    // MARK: - Taxa Collections Drawer

    /// The taxa collections drawer view, created lazily on first toggle.
    var taxaCollectionsDrawerView: TaxaCollectionsDrawerView?

    /// Constraint controlling the drawer's vertical offset from the action bar.
    var taxaCollectionsDrawerBottomConstraint: NSLayoutConstraint?

    /// Constraint controlling the drawer's height.
    var taxaCollectionsDrawerHeightConstraint: NSLayoutConstraint?

    /// Whether the taxa collections drawer is currently visible.
    var isTaxaCollectionsDrawerOpen: Bool = false

    /// Debounce work item for persisting drawer height changes.
    var _taxaDrawerHeightSaveWorkItem: DispatchWorkItem?

    // MARK: - Lifecycle

    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view = container

        setupSummaryBar()
        setupBreadcrumbBar()
        setupSplitView()
        setupBatchTableView()
        setupActionBar()
        layoutSubviews()
        wireCallbacks()
        applyLayoutPreference()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleBatchSampleSelectionChanged),
            name: .metagenomicsSampleSelectionChanged,
            object: nil
        )
    }

    public override func viewDidLayout() {
        super.viewDidLayout()

        // Apply the initial 60/40 split once the split view has real bounds.
        // NSSplitView.setPosition is a no-op when bounds are zero, so we
        // must wait until after the first layout pass.
        if !didSetInitialSplitPosition, splitView.bounds.width > 0 {
            didSetInitialSplitPosition = true
            let position = round(splitView.bounds.width * 0.6)
            splitView.setPosition(position, ofDividerAt: 0)
        }
    }

    // MARK: - Public API

    /// Configures the taxonomy view with a classification result.
    ///
    /// Populates the summary bar, sunburst chart, taxonomy table, and action bar
    /// with data from the classification result.
    ///
    /// - Parameter result: The classification result to display.
    public func configure(result: ClassificationResult) {
        classificationResult = result
        tree = result.tree

        summaryBar.update(tree: result.tree)
        sunburstView.tree = result.tree
        sunburstView.centerNode = nil
        sunburstView.selectedNode = nil
        taxonomyTableView.tree = result.tree

        // Wire table right-click extraction -> unified extraction dialog
        taxonomyTableView.onExtractReadsRequested = { [weak self] in
            self?.presentUnifiedExtractionDialog()
        }

        // Wire table right-click NCBI links
        taxonomyTableView.onNCBITaxonomyRequested = { node in
            let url = URL(string: "https://www.ncbi.nlm.nih.gov/datasets/taxonomy/\(node.taxId)/")!
            NSWorkspace.shared.open(url)
        }
        taxonomyTableView.onNCBIGenBankRequested = { node in
            let url = URL(string: "https://www.ncbi.nlm.nih.gov/nuccore/?term=txid\(node.taxId)[Organism:exp]")!
            NSWorkspace.shared.open(url)
        }
        taxonomyTableView.onNCBIPubMedRequested = { node in
            let encodedName = node.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? node.name
            let url = URL(string: "https://pubmed.ncbi.nlm.nih.gov/?term=\(encodedName)")!
            NSWorkspace.shared.open(url)
        }

        // Wire table right-click BLAST
        taxonomyTableView.onBlastRequested = { [weak self] node in
            guard let self else { return }
            self.showBlastConfigPopover(for: node, relativeTo: self.sunburstView)
        }

        totalReadsForActionBar = result.tree.totalReads
        updateActionBarSelection(nil)
        breadcrumbBar.update(zoomNode: nil)

        logger.info("Configured with \(result.tree.totalReads) reads, \(result.tree.speciesCount) species")

        // Build single-sample picker entry from classification result.
        // Resolve human-readable display name via manifest lookup.
        let rawSampleName = result.config.sampleDisplayName
            ?? result.config.inputFiles.first?
                .deletingPathExtension().lastPathComponent
            ?? "sample"
        let projectURL = result.config.outputDirectory
            .deletingLastPathComponent()  // derivatives/
            .deletingLastPathComponent()  // bundle.lungfishfastq/
            .deletingLastPathComponent()  // project/
        let sampleName = FASTQDisplayNameResolver.resolveDisplayName(
            sampleId: rawSampleName, projectURL: projectURL)
        sampleEntries = [Kraken2SampleEntry(
            id: rawSampleName,
            displayName: sampleName,
            classifiedReads: result.tree.classifiedReads
        )]
        strippedPrefix = ""
        samplePickerState = ClassifierSamplePickerState(allSamples: Set([sampleName]))
        taxonomyTableView.currentSampleID = rawSampleName
    }

    // MARK: - Database-backed Batch Mode

    /// The SQLite database backing this VC when loaded via `configureFromDatabase`.
    private var kraken2Database: Kraken2Database?

    /// Configures this VC from a pre-built SQLite database instead of parsing
    /// per-sample kreport files or manifest caches.
    ///
    /// Sets `isBatchMode = true` so the existing sample selection and filter
    /// paths operate correctly. Populates `allBatchRows`, sample entries,
    /// and picker state from the database, then shows the batch table.
    public func configureFromDatabase(_ db: Kraken2Database) {
        self.kraken2Database = db
        self.isBatchMode = true

        // Fetch all samples from the DB.
        let sampleList = (try? db.fetchSamples()) ?? []
        let sampleIds = sampleList.map(\.sample).sorted()

        // Build sample entries for the Inspector picker.
        sampleEntries = sampleIds.map { sid in
            let count = sampleList.first(where: { $0.sample == sid })?.taxonCount ?? 0
            return Kraken2SampleEntry(
                id: sid,
                displayName: FASTQDisplayNameResolver.resolveDisplayName(sampleId: sid, projectURL: nil),
                classifiedReads: count
            )
        }
        samplePickerState = ClassifierSamplePickerState(allSamples: Set(sampleIds))
        samplePickerState.selectedSamples = Set(sampleIds)

        // Reuse the same taxonomy context actions (extract, BLAST, NCBI links)
        // as single-sample mode so DB-backed batch display preserves workflows.
        taxonomyTableView.onExtractReadsRequested = { [weak self] in
            self?.presentUnifiedExtractionDialog()
        }
        taxonomyTableView.onNCBITaxonomyRequested = { node in
            let url = URL(string: "https://www.ncbi.nlm.nih.gov/datasets/taxonomy/\(node.taxId)/")!
            NSWorkspace.shared.open(url)
        }
        taxonomyTableView.onNCBIGenBankRequested = { node in
            let url = URL(string: "https://www.ncbi.nlm.nih.gov/nuccore/?term=txid\(node.taxId)[Organism:exp]")!
            NSWorkspace.shared.open(url)
        }
        taxonomyTableView.onNCBIPubMedRequested = { node in
            let encodedName = node.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? node.name
            let url = URL(string: "https://pubmed.ncbi.nlm.nih.gov/?term=\(encodedName)")!
            NSWorkspace.shared.open(url)
        }
        taxonomyTableView.onBlastRequested = { [weak self] node in
            guard let self else { return }
            self.showBlastConfigPopover(for: node, relativeTo: self.sunburstView)
        }

        // Load ALL rows from the DB (filtering by selection happens in applyBatchSampleFilter).
        reloadFromDatabase()

        // Wire batch table callbacks (same pattern as configureFromDatabase).
        batchTableView.metadataColumns.isMultiSampleMode = true
        batchTableView.onRowSelected = { [weak self] _ in
            self?.actionBar.updateInfoText("1 row selected")
        }
        batchTableView.onMultipleRowsSelected = { [weak self] rows in
            self?.actionBar.updateInfoText("\(rows.count) rows selected")
        }
        batchTableView.onSelectionCleared = { [weak self] in
            self?.actionBar.updateInfoText("Select a taxon to view details")
        }

        // Prefer the native hierarchical taxonomy + sunburst display in batch mode.
        splitView.isHidden = false
        batchTableView.isHidden = true

        summaryBar.updateBatch(
            sampleCount: sampleEntries.count,
            totalRows: allBatchRows.count,
            databaseName: "kraken2.sqlite"
        )

        applyBatchSampleFilter()

        logger.info("configureFromDatabase: loaded \(self.allBatchRows.count) rows across \(sampleIds.count) samples from SQLite")
    }

    /// Loads all rows from the SQLite database into `allBatchRows`.
    ///
    /// Fetches every sample's rows (selection filtering is done by `applyBatchSampleFilter`).
    private func reloadFromDatabase() {
        guard let db = kraken2Database else { return }

        let allSampleIds = sampleEntries.map(\.id)
        let dbRows = (try? db.fetchRows(samples: allSampleIds)) ?? []

        allBatchRows = dbRows.map { row in
            BatchClassificationRow(
                sample: row.sample,
                taxonName: row.taxonName,
                taxId: row.taxId,
                rank: row.rank ?? "",
                rankDisplayName: row.rankDisplayName ?? "",
                readsDirect: row.readsDirect,
                readsClade: row.readsClade,
                percentage: row.percentage
            )
        }
    }

    /// Filters `allBatchRows` by the samples selected in `samplePickerState`
    /// and renders one combined taxonomy tree across all selected samples.
    private func applyBatchSampleFilter() {
        guard let state = samplePickerState else { return }
        let selected = state.selectedSamples.sorted()

        guard let db = kraken2Database else {
            taxonomyTableView.tree = nil
            sunburstView.tree = nil
            return
        }

        // Render all selected samples together: single sample => native tree,
        // multi-sample => synthetic root with one top-level node per sample.
        guard let sample = selected.first else {
            currentBatchSampleId = nil
            tree = nil
            taxonomyTableView.tree = nil
            taxonomyTableView.currentSampleID = nil
            sunburstView.tree = nil
            updateActionBarSelection(nil)
            return
        }

        do {
            let sampleTrees: [(sampleId: String, tree: TaxonTree)] = try selected.map { sid in
                (sampleId: sid, tree: try db.fetchTree(sample: sid))
            }

            let displayTree: TaxonTree
            if sampleTrees.count == 1, let only = sampleTrees.first {
                currentBatchSampleId = only.sampleId
                taxonomyTableView.currentSampleID = only.sampleId
                displayTree = only.tree
            } else {
                currentBatchSampleId = sample
                taxonomyTableView.currentSampleID = nil
                displayTree = mergedTree(for: sampleTrees)
            }

            tree = displayTree
            taxonomyTableView.tree = displayTree
            sunburstView.tree = displayTree
            sunburstView.centerNode = nil
            sunburstView.selectedNode = nil
            hideMultiSelectionPlaceholder()
            splitView.isHidden = false
            batchTableView.isHidden = true
            breadcrumbBar.update(zoomNode: nil)
            totalReadsForActionBar = displayTree.totalReads
            updateActionBarSelection(nil)
            actionBar.setExtractEnabled(true)
        } catch {
            logger.error("Failed to fetch Kraken2 tree for sample \(sample, privacy: .public): \(error.localizedDescription, privacy: .public)")
            currentBatchSampleId = nil
            tree = nil
            taxonomyTableView.tree = nil
            taxonomyTableView.currentSampleID = nil
            sunburstView.tree = nil
            updateActionBarSelection(nil)
        }
    }

    /// Builds a synthetic multi-sample taxonomy tree where each selected sample appears
    /// as its own top-level node containing that sample's taxonomy hierarchy.
    private func mergedTree(for sampleTrees: [(sampleId: String, tree: TaxonTree)]) -> TaxonTree {
        let totalReads = sampleTrees.reduce(0) { $0 + $1.tree.totalReads }
        let root = TaxonNode(
            taxId: 1,
            name: "Root",
            rank: .root,
            depth: 0,
            readsDirect: 0,
            readsClade: totalReads,
            fractionClade: 1.0,
            fractionDirect: 0.0,
            parentTaxId: nil
        )

        var syntheticSampleTaxId = -1
        for (sampleId, sampleTree) in sampleTrees {
            let sampleReads = sampleTree.root.readsClade
            let sampleFraction = totalReads > 0 ? Double(sampleReads) / Double(totalReads) : 0.0
            let sampleNode = TaxonNode(
                taxId: syntheticSampleTaxId,
                name: sampleId,
                rank: TaxonomicRank(code: "no rank"),
                depth: 1,
                readsDirect: 0,
                readsClade: sampleReads,
                fractionClade: sampleFraction,
                fractionDirect: 0.0,
                parentTaxId: 1
            )
            syntheticSampleTaxId -= 1

            for child in sampleTree.root.children {
                sampleNode.addChild(cloneTaxonSubtree(child))
            }
            root.addChild(sampleNode)
        }

        return TaxonTree(root: root, unclassifiedNode: nil, totalReads: totalReads)
    }

    private func cloneTaxonSubtree(_ node: TaxonNode) -> TaxonNode {
        let copy = TaxonNode(
            taxId: node.taxId,
            name: node.name,
            rank: node.rank,
            depth: node.depth,
            readsDirect: node.readsDirect,
            readsClade: node.readsClade,
            fractionClade: node.fractionClade,
            fractionDirect: node.fractionDirect,
            parentTaxId: node.parentTaxId
        )
        for child in node.children {
            copy.addChild(cloneTaxonSubtree(child))
        }
        return copy
    }

    @objc private func handleBatchSampleSelectionChanged() {
        guard isBatchMode else { return }
        applyBatchSampleFilter()
    }

    // MARK: - Classifier extraction wiring

    /// Builds Kraken2 selectors from `explicit` nodes, or the current table
    /// selection if `explicit` is nil. Passing explicit nodes bypasses the
    /// table-view selection state so chart-menu handlers work for nodes
    /// hidden by an active filter.
    private func buildKraken2Selectors(explicit: [TaxonNode]? = nil) -> [ClassifierRowSelector] {
        let nodes: [TaxonNode] = explicit ?? taxonomyTableView.outlineView.selectedRowIndexes.compactMap {
            taxonomyTableView.outlineView.item(atRow: $0) as? TaxonNode
        }
        let actionable = nodes.filter { isActionableTaxonNode($0) }
        guard !actionable.isEmpty else { return [] }
        let taxIds = actionable.map(\.taxId)

        // In batch mode with multiple samples selected, build one selector per
        // sample so the resolver runs the extraction pipeline against each
        // sample's classification.kraken file independently. The merged taxonomy
        // tree shows aggregate counts; the same tax IDs apply to every sample.
        if isBatchMode {
            let selectedSamples = samplePickerState.selectedSamples.sorted()
            if selectedSamples.count > 1 {
                return selectedSamples.map { sid in
                    ClassifierRowSelector(sampleId: sid, accessions: [], taxIds: taxIds)
                }
            }
        }

        return [ClassifierRowSelector(sampleId: nil, accessions: [], taxIds: taxIds)]
    }

    /// Resolves the Kraken2 result path.
    ///
    /// - Single-result mode: returns `classificationResult.config.outputDirectory`.
    /// - Batch mode: returns the **batch root** directory so the resolver can
    ///   locate per-sample subdirectories via the selector's `sampleId`.
    private func resolveKraken2ResultPath() -> URL? {
        if let cr = classificationResult { return cr.config.outputDirectory }
        if isBatchMode, let batchURL { return batchURL }
        return nil
    }

    private func presentUnifiedExtractionDialog(explicitNodes: [TaxonNode]? = nil) {
        guard let resultPath = resolveKraken2ResultPath() else { return }
        let name = (explicitNodes?.first ?? taxonomyTableView.selectedNode)?.name ?? "extract"
        presentClassifierExtractionDialog(
            tool: .kraken2,
            resultPath: resultPath,
            selectors: buildKraken2Selectors(explicit: explicitNodes),
            suggestedName: "kraken2_\(name.replacingOccurrences(of: " ", with: "_"))"
        )
    }

    // MARK: - Setup: Summary Bar

    private func setupSummaryBar() {
        summaryBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(summaryBar)
    }

    // MARK: - Setup: Breadcrumb Bar

    private func setupBreadcrumbBar() {
        breadcrumbBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(breadcrumbBar)
    }

    // MARK: - Setup: Split View

    /// Configures the NSSplitView with sunburst (left) and table (right).
    ///
    /// Uses raw NSSplitView (not NSSplitViewController) per macOS 26 rules.
    /// Delegate methods are safe on raw NSSplitView instances.
    ///
    /// **Important**: NSSplitView manages its arranged subview frames directly
    /// using frame-based layout. The container views must keep
    /// `translatesAutoresizingMaskIntoConstraints = true` (the default) so that
    /// NSSplitView's frame assignments are not overridden by Auto Layout.
    /// The child views inside each container use `autoresizingMask` to fill
    /// the container as its frame changes.
    private func setupSplitView() {
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self

        // Sunburst container (left pane)
        // NSSplitView sets this view's frame directly -- do NOT disable
        // translatesAutoresizingMaskIntoConstraints on the container.
        let sunburstContainer = NSView()
        sunburstView.autoresizingMask = [.width, .height]
        sunburstContainer.addSubview(sunburstView)

        // Multi-selection placeholder overlay on the sunburst container
        sunburstContainer.addSubview(multiSelectionPlaceholder)
        NSLayoutConstraint.activate([
            multiSelectionPlaceholder.topAnchor.constraint(equalTo: sunburstContainer.topAnchor),
            multiSelectionPlaceholder.bottomAnchor.constraint(equalTo: sunburstContainer.bottomAnchor),
            multiSelectionPlaceholder.leadingAnchor.constraint(equalTo: sunburstContainer.leadingAnchor),
            multiSelectionPlaceholder.trailingAnchor.constraint(equalTo: sunburstContainer.trailingAnchor),
        ])

        // Table container (right pane)
        let tableContainer = NSView()
        taxonomyTableView.autoresizingMask = [.width, .height]
        tableContainer.addSubview(taxonomyTableView)

        splitView.addArrangedSubview(sunburstContainer)
        splitView.addArrangedSubview(tableContainer)

        // Set holding priorities so the table pane is preferred to resize
        // when the split view itself resizes (e.g., window resize). The left
        // pane (sunburst) holds its width more firmly.
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        view.addSubview(splitView)
    }

    // MARK: - Setup: Batch Table View

    /// Adds the batch table view as a sibling of `splitView` with identical
    /// constraints. Hidden by default; shown when `configureFromDatabase` is called.
    private func setupBatchTableView() {
        batchTableView.translatesAutoresizingMaskIntoConstraints = false
        batchTableView.isHidden = true
        view.addSubview(batchTableView)
    }

    // MARK: - Setup: Action Bar

    private func setupActionBar() {
        actionBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(actionBar)
    }

    // MARK: - Layout

    private func layoutSubviews() {
        NSLayoutConstraint.activate([
            // Summary bar (top, below safe area to avoid title bar overlap)
            summaryBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            summaryBar.heightAnchor.constraint(equalToConstant: 48),

            // Breadcrumb bar (below summary)
            breadcrumbBar.topAnchor.constraint(equalTo: summaryBar.bottomAnchor),
            breadcrumbBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            breadcrumbBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            breadcrumbBar.heightAnchor.constraint(equalToConstant: 28),

            // Action bar (bottom, fixed height)
            actionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: 36),

            // Batch table view (same region as splitView, hidden by default)
            batchTableView.topAnchor.constraint(equalTo: breadcrumbBar.bottomAnchor),
            batchTableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            batchTableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            batchTableView.bottomAnchor.constraint(equalTo: actionBar.topAnchor),

            // Split view (fills remaining space between breadcrumb and action bar)
            splitView.topAnchor.constraint(equalTo: breadcrumbBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: actionBar.topAnchor),
        ])
    }

    // MARK: - Callback Wiring

    private func wireCallbacks() {
        // Sunburst selection -> table sync
        sunburstView.onNodeSelected = { [weak self] node in
            guard let self, !self.suppressSelectionSync else { return }
            self.suppressSelectionSync = true
            self.taxonomyTableView.selectAndScrollTo(node: node)
            self.hideMultiSelectionPlaceholder()
            self.updateActionBarSelection(node)
            self.suppressSelectionSync = false
        }

        // Sunburst double-click -> zoom
        sunburstView.onNodeDoubleClicked = { [weak self] node in
            guard let self else { return }
            self.breadcrumbBar.update(zoomNode: self.sunburstView.centerNode)
        }

        // Sunburst zoom changed (keyboard or mouse) -> update breadcrumb
        sunburstView.onZoomChanged = { [weak self] newCenter in
            guard let self else { return }
            self.breadcrumbBar.update(zoomNode: newCenter)
        }

        // Sunburst right-click on segment -> taxon context menu
        sunburstView.onNodeRightClicked = { [weak self] node, windowPoint in
            guard let self else { return }
            self.showContextMenu(for: node, at: windowPoint)
        }

        // Sunburst right-click on empty space -> chart context menu
        sunburstView.onEmptySpaceRightClicked = { [weak self] windowPoint in
            guard let self else { return }
            self.showChartContextMenu(at: windowPoint)
        }

        // Table selection -> sunburst sync
        taxonomyTableView.onNodeSelected = { [weak self] node in
            guard let self, !self.suppressSelectionSync else { return }
            // Guard against intermediate selection notifications during Cmd+Click:
            // if the table already has multiple rows selected, defer to the
            // multi-selection callback instead.
            if self.taxonomyTableView.outlineView.selectedRowIndexes.count > 1 { return }
            self.suppressSelectionSync = true
            self.sunburstView.selectedNode = node
            self.hideMultiSelectionPlaceholder()
            self.updateActionBarSelection(node)
            self.suppressSelectionSync = false
        }

        // Table multi-selection -> placeholder + action bar update
        taxonomyTableView.onMultipleNodesSelected = { [weak self] count in
            guard let self, !self.suppressSelectionSync else { return }
            self.suppressSelectionSync = true
            self.sunburstView.selectedNode = nil
            self.hideMultiSelectionPlaceholder()
            self.actionBar.updateInfoText("\(count) items selected")
            self.actionBar.setBlastEnabled(false, reason: "Select a single row to use BLAST Verify")
            self.actionBar.setExtractEnabled(true)
            self.suppressSelectionSync = false
        }

        // Table filter -> sunburst dimming
        taxonomyTableView.onFilterChanged = { [weak self] filteredIds in
            self?.sunburstView.filteredNodeIds = filteredIds
        }

        // Breadcrumb navigation -> zoom sunburst
        breadcrumbBar.onNavigateToNode = { [weak self] node in
            guard let self else { return }
            self.sunburstView.centerNode = node
            self.breadcrumbBar.update(zoomNode: node)
        }

        // Action bar Extract FASTQ -> route to the unified extraction dialog
        actionBar.onExtractFASTQ = { [weak self] in
            self?.presentUnifiedExtractionDialog()
        }

        // Action bar BLAST verify -> show BLAST config for current selection
        actionBar.onBlastVerify = { [weak self] in
            guard let self, let node = self.selectedTaxonNode else { return }
            self.showBlastConfigPopover(for: node, relativeTo: self.actionBar.blastButton)
        }

        // Action bar export -> show export menu
        actionBar.onExport = { [weak self] in
            guard let self else { return }
            let menu = self.buildExportMenu()
            let point = NSPoint(x: self.actionBar.exportButton.bounds.minX, y: self.actionBar.exportButton.bounds.maxY)
            menu.popUp(positioning: nil, at: point, in: self.actionBar.exportButton)
        }

        // Action bar provenance -> show provenance popover
        actionBar.onProvenance = { [weak self] sender in
            self?.showProvenancePopover(relativeTo: sender)
        }

        // Wire custom buttons
        collectionsToggleButton.target = self
        collectionsToggleButton.action = #selector(collectionsToggleTapped(_:))
        actionBar.addCustomButton(collectionsToggleButton)

        blastResultsToggleButton.target = self
        blastResultsToggleButton.action = #selector(blastResultsToggleTapped(_:))
        actionBar.addCustomButton(blastResultsToggleButton)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLayoutSwapRequested),
            name: .metagenomicsLayoutSwapRequested,
            object: nil
        )
    }

    @objc private func handleLayoutSwapRequested(_ notification: Notification) {
        applyLayoutPreference()
    }

    /// Swaps the split view pane order based on the persisted layout preference.
    private func applyLayoutPreference() {
        let tableOnLeft = UserDefaults.standard.bool(forKey: "metagenomicsTableOnLeft")
        guard splitView.arrangedSubviews.count == 2,
              let detail = sunburstView.superview,
              let table = taxonomyTableView.superview else { return }

        let currentTableIsFirst = (splitView.arrangedSubviews[0] === table)
        guard tableOnLeft != currentTableIsFirst else { return }

        let totalWidth = max(splitView.bounds.width, 1)
        let leftRatio = splitView.arrangedSubviews[0].frame.width / totalWidth

        splitView.removeArrangedSubview(detail)
        splitView.removeArrangedSubview(table)
        detail.removeFromSuperview()
        table.removeFromSuperview()

        if tableOnLeft {
            splitView.addArrangedSubview(table)
            splitView.addArrangedSubview(detail)
        } else {
            splitView.addArrangedSubview(detail)
            splitView.addArrangedSubview(table)
        }

        let tableIndex = tableOnLeft ? 0 : 1
        let detailIndex = tableOnLeft ? 1 : 0
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: tableIndex)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: detailIndex)

        let newPosition = round(totalWidth * (1.0 - leftRatio))
        splitView.setPosition(newPosition, ofDividerAt: 0)
        splitView.adjustSubviews()
    }

    /// Toggles the BLAST results tab in the taxa collections drawer.
    ///
    /// If the drawer is closed, opens it and switches to the BLAST tab.
    /// If the drawer is open on the BLAST tab, closes it.
    /// If the drawer is open on another tab, switches to the BLAST tab.
    private func toggleBlastResultsTab() {
        if taxaCollectionsDrawerView == nil {
            // First open: create drawer, open it, switch to BLAST tab
            toggleTaxaCollectionsDrawer()
            taxaCollectionsDrawerView?.switchToTab(.blastResults)
            blastResultsToggleButton.state = .on
            collectionsToggleButton.state = .off
        } else if !isTaxaCollectionsDrawerOpen {
            // Drawer exists but is closed: open and switch to BLAST tab
            toggleTaxaCollectionsDrawer()
            taxaCollectionsDrawerView?.switchToTab(.blastResults)
            blastResultsToggleButton.state = .on
            collectionsToggleButton.state = .off
        } else if taxaCollectionsDrawerView?.selectedTab == .blastResults {
            // Already open on BLAST tab: close the drawer
            toggleTaxaCollectionsDrawer()
            blastResultsToggleButton.state = .off
        } else {
            // Drawer open on Collections tab: switch to BLAST tab
            taxaCollectionsDrawerView?.switchToTab(.blastResults)
            blastResultsToggleButton.state = .on
            collectionsToggleButton.state = .off
        }
    }

    // MARK: - Custom Toggle Button Actions

    @objc private func collectionsToggleTapped(_ sender: NSButton) {
        toggleTaxaCollectionsDrawer()
    }

    @objc private func blastResultsToggleTapped(_ sender: NSButton) {
        toggleBlastResultsTab()
    }

    // MARK: - Multi-Selection Helpers

    private func showMultiSelectionPlaceholder(count: Int) {
        if let stack = multiSelectionPlaceholder.subviews.first as? NSStackView,
           let primary = stack.arrangedSubviews.first as? NSTextField {
            primary.stringValue = "\(count) items selected"
        }
        sunburstView.isHidden = true
        multiSelectionPlaceholder.isHidden = false
    }

    private func hideMultiSelectionPlaceholder() {
        multiSelectionPlaceholder.isHidden = true
        sunburstView.isHidden = false
    }

    // MARK: - Action Bar Selection Helper

    /// Updates the unified action bar info text and BLAST button state from a taxon node.
    private func updateActionBarSelection(_ node: TaxonNode?) {
        selectedTaxonNode = isActionableTaxonNode(node) ? node : nil

        if let node = selectedTaxonNode {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = ","
            let readStr = formatter.string(from: NSNumber(value: node.readsClade)) ?? "\(node.readsClade)"

            let pct = totalReadsForActionBar > 0
                ? Double(node.readsClade) / Double(totalReadsForActionBar) * 100
                : 0
            let pctStr = String(format: "%.1f%%", pct)

            actionBar.updateInfoText("\(node.name) \u{2014} \(readStr) reads (\(pctStr))")
            actionBar.setBlastEnabled(true)
            actionBar.setExtractEnabled(true)
        } else {
            actionBar.updateInfoText("Select a taxon to view details")
            actionBar.setBlastEnabled(false, reason: "Select a row to use BLAST Verify")
            actionBar.setExtractEnabled(false)
        }
    }

    // MARK: - NSSplitViewDelegate

    /// Enforces minimum widths for sunburst (300px) and table (260px).
    public func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        // Minimum left pane (sunburst) width
        max(proposedMinimumPosition, 300)
    }

    public func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        // Ensure right pane (table) has at least 260px
        min(proposedMaximumPosition, splitView.bounds.width - 260)
    }

    // MARK: - Context Menu (Taxon)

    /// Builds and shows a context menu for a taxon node at the given window point.
    ///
    /// Menu items:
    /// - Extract Reads...
    /// - Copy Taxon Name
    /// - Copy Taxonomy Path
    /// - (separator)
    /// - Zoom to [name]
    /// - Zoom Out to Root
    private func showContextMenu(for node: TaxonNode, at windowPoint: NSPoint) {
        let menu = NSMenu()

        // Extract reads for this taxon. The unified dialog's resolver handles
        // descendant taxon expansion internally, so the old "and Children"
        // variant is no longer needed.
        let extractItem = NSMenuItem(
            title: "Extract Reads\u{2026}",
            action: #selector(contextExtractReads(_:)),
            keyEquivalent: ""
        )
        extractItem.target = self
        extractItem.representedObject = node
        menu.addItem(extractItem)

        menu.addItem(.separator())

        // Copy taxon name
        let copyNameItem = NSMenuItem(
            title: "Copy Taxon Name",
            action: #selector(contextCopyName(_:)),
            keyEquivalent: ""
        )
        copyNameItem.target = self
        copyNameItem.representedObject = node
        menu.addItem(copyNameItem)

        // Copy taxonomy path
        let copyPathItem = NSMenuItem(
            title: "Copy Taxonomy Path",
            action: #selector(contextCopyPath(_:)),
            keyEquivalent: ""
        )
        copyPathItem.target = self
        copyPathItem.representedObject = node
        menu.addItem(copyPathItem)

        menu.addItem(.separator())

        // Zoom to node (disabled if already the zoom root)
        let zoomItem = NSMenuItem(
            title: "Zoom to \(node.name)",
            action: #selector(contextZoomToNode(_:)),
            keyEquivalent: ""
        )
        zoomItem.target = self
        zoomItem.representedObject = node
        if sunburstView.centerNode === node {
            zoomItem.isEnabled = false
        }
        menu.addItem(zoomItem)

        // Zoom out to root
        let zoomOutItem = NSMenuItem(
            title: "Zoom Out to Root",
            action: #selector(contextZoomToRoot(_:)),
            keyEquivalent: ""
        )
        zoomOutItem.target = self
        zoomOutItem.isEnabled = sunburstView.centerNode != nil
        menu.addItem(zoomOutItem)

        menu.addItem(.separator())

        // NCBI links submenu
        let ncbiSubmenu = NSMenu()

        let taxonomyItem = NSMenuItem(
            title: "NCBI Taxonomy",
            action: #selector(contextOpenNCBITaxonomy(_:)),
            keyEquivalent: ""
        )
        taxonomyItem.target = self
        taxonomyItem.representedObject = node
        taxonomyItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "Web")
        ncbiSubmenu.addItem(taxonomyItem)

        let genBankItem = NSMenuItem(
            title: "GenBank Sequences",
            action: #selector(contextOpenNCBIGenBank(_:)),
            keyEquivalent: ""
        )
        genBankItem.target = self
        genBankItem.representedObject = node
        ncbiSubmenu.addItem(genBankItem)

        let pubmedItem = NSMenuItem(
            title: "PubMed Literature",
            action: #selector(contextOpenNCBIPubMed(_:)),
            keyEquivalent: ""
        )
        pubmedItem.target = self
        pubmedItem.representedObject = node
        ncbiSubmenu.addItem(pubmedItem)

        let genomeItem = NSMenuItem(
            title: "Genome Assemblies",
            action: #selector(contextOpenNCBIGenome(_:)),
            keyEquivalent: ""
        )
        genomeItem.target = self
        genomeItem.representedObject = node
        ncbiSubmenu.addItem(genomeItem)

        let ncbiItem = NSMenuItem(title: "Look Up on NCBI", action: nil, keyEquivalent: "")
        ncbiItem.submenu = ncbiSubmenu
        ncbiItem.image = NSImage(systemSymbolName: "globe", accessibilityDescription: "NCBI")
        menu.addItem(ncbiItem)

        menu.addItem(.separator())

        let blastItem = NSMenuItem(
            title: "BLAST Matching Reads\u{2026}",
            action: #selector(contextBlastReads(_:)),
            keyEquivalent: ""
        )
        blastItem.target = self
        blastItem.representedObject = node
        blastItem.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "BLAST")
        menu.addItem(blastItem)

        // Convert window point to view coordinates and show
        let viewPoint = view.convert(windowPoint, from: nil)
        menu.popUp(positioning: nil, at: viewPoint, in: view)
    }

    // MARK: - Context Menu (Chart / Empty Space)

    /// Builds and shows a chart-level context menu at the given window point.
    ///
    /// This menu appears when the user right-clicks empty space in the sunburst
    /// chart (not on a segment). It provides chart-level actions like copying the
    /// chart as a PNG image.
    ///
    /// - Parameter windowPoint: The click location in window coordinates.
    private func showChartContextMenu(at windowPoint: NSPoint) {
        guard tree != nil else { return }

        let menu = NSMenu()

        let copyItem = NSMenuItem(
            title: "Copy Chart as PNG",
            action: #selector(sunburstView.copyChartToPasteboard(_:)),
            keyEquivalent: ""
        )
        copyItem.target = sunburstView
        menu.addItem(copyItem)

        let viewPoint = view.convert(windowPoint, from: nil)
        menu.popUp(positioning: nil, at: viewPoint, in: view)
    }

    /// Builds context menu items for the given node (for testing).
    func contextMenuItems(for node: TaxonNode) -> [NSMenuItem] {
        let menu = NSMenu()
        showContextMenuItems(for: node, into: menu)
        return menu.items
    }

    /// Adds context menu items to the given menu without showing it.
    private func showContextMenuItems(for node: TaxonNode, into menu: NSMenu) {
        let extractItem = NSMenuItem(
            title: "Extract Reads\u{2026}",
            action: #selector(contextExtractReads(_:)),
            keyEquivalent: ""
        )
        extractItem.target = self
        extractItem.representedObject = node
        menu.addItem(extractItem)

        menu.addItem(.separator())

        let copyNameItem = NSMenuItem(
            title: "Copy Taxon Name",
            action: #selector(contextCopyName(_:)),
            keyEquivalent: ""
        )
        copyNameItem.target = self
        copyNameItem.representedObject = node
        menu.addItem(copyNameItem)

        let copyPathItem = NSMenuItem(
            title: "Copy Taxonomy Path",
            action: #selector(contextCopyPath(_:)),
            keyEquivalent: ""
        )
        copyPathItem.target = self
        copyPathItem.representedObject = node
        menu.addItem(copyPathItem)

        menu.addItem(.separator())

        let zoomItem = NSMenuItem(
            title: "Zoom to \(node.name)",
            action: #selector(contextZoomToNode(_:)),
            keyEquivalent: ""
        )
        zoomItem.target = self
        zoomItem.representedObject = node
        if sunburstView.centerNode === node {
            zoomItem.isEnabled = false
        }
        menu.addItem(zoomItem)

        let zoomOutItem = NSMenuItem(
            title: "Zoom Out to Root",
            action: #selector(contextZoomToRoot(_:)),
            keyEquivalent: ""
        )
        zoomOutItem.target = self
        zoomOutItem.isEnabled = sunburstView.centerNode != nil
        menu.addItem(zoomOutItem)

        menu.addItem(.separator())

        let blastItem = NSMenuItem(
            title: "BLAST Matching Reads\u{2026}",
            action: #selector(contextBlastReads(_:)),
            keyEquivalent: ""
        )
        blastItem.target = self
        blastItem.representedObject = node
        blastItem.image = NSImage(systemSymbolName: "bolt.circle", accessibilityDescription: "BLAST")
        menu.addItem(blastItem)
    }

    // MARK: - Context Menu Actions

    @objc private func contextExtractReads(_ sender: NSMenuItem) {
        // Explicit nodes so the dialog works for filter-hidden rows.
        guard let node = sender.representedObject as? TaxonNode else { return }
        presentUnifiedExtractionDialog(explicitNodes: [node])
    }

    @objc private func contextCopyName(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? TaxonNode else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(node.name, forType: .string)
    }

    @objc private func contextCopyPath(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? TaxonNode else { return }
        let path = node.pathFromRoot()
            .filter { $0.rank != .root }
            .map(\.name)
            .joined(separator: " > ")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    @objc private func contextZoomToNode(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? TaxonNode else { return }
        sunburstView.centerNode = node
        breadcrumbBar.update(zoomNode: node)
    }

    @objc private func contextZoomToRoot(_ sender: NSMenuItem) {
        sunburstView.centerNode = nil
        breadcrumbBar.update(zoomNode: nil)
    }

    @objc private func contextBlastReads(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? TaxonNode else { return }
        showBlastConfigPopover(for: node, relativeTo: sender)
    }

    /// Shows a popover with BLAST configuration (read count slider and Run button).
    ///
    /// - Parameters:
    ///   - node: The taxon to verify.
    ///   - sender: The menu item or view to anchor the popover to.
    private func showBlastConfigPopover(for node: TaxonNode, relativeTo sender: Any) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 280, height: 160)

        let configView = BlastConfigPopoverView(
            taxonName: node.name,
            readsClade: node.readsClade
        ) { [weak self, weak popover] readCount in
            popover?.performClose(nil)
            self?.lastBlastNode = node
            self?.onBlastVerification?(node, readCount)
        }

        popover.contentViewController = NSHostingController(rootView: configView)

        // Anchor to the sunburst view center (the context menu has no rect).
        let anchorView = sunburstView
        let anchorRect = NSRect(
            x: anchorView.bounds.midX - 1,
            y: anchorView.bounds.midY - 1,
            width: 2,
            height: 2
        )
        popover.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .maxY)
    }

    // MARK: - NCBI Links

    @objc private func contextOpenNCBITaxonomy(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? TaxonNode else { return }
        let url = URL(string: "https://www.ncbi.nlm.nih.gov/datasets/taxonomy/\(node.taxId)/")!
        NSWorkspace.shared.open(url)
    }

    @objc private func contextOpenNCBIGenBank(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? TaxonNode else { return }
        let url = URL(string: "https://www.ncbi.nlm.nih.gov/nuccore/?term=txid\(node.taxId)[Organism:exp]")!
        NSWorkspace.shared.open(url)
    }

    @objc private func contextOpenNCBIPubMed(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? TaxonNode else { return }
        let encodedName = node.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? node.name
        let url = URL(string: "https://pubmed.ncbi.nlm.nih.gov/?term=\(encodedName)")!
        NSWorkspace.shared.open(url)
    }

    @objc private func contextOpenNCBIGenome(_ sender: NSMenuItem) {
        guard let node = sender.representedObject as? TaxonNode else { return }
        let url = URL(string: "https://www.ncbi.nlm.nih.gov/datasets/genome/?taxon=\(node.taxId)")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Export

    /// Exports the taxonomy table as CSV via an NSSavePanel.
    ///
    /// The export writes all nodes from the tree in depth-first order with columns:
    /// Name, Rank, Reads (Clade), Reads (Direct), Clade %, Direct %.
    ///
    /// Uses `beginSheetModal` (not `runModal`) per macOS 26 deprecated API rules.
    private func exportCSV() {
        exportDelimited(separator: ",", fileExtension: "csv", fileTypeName: "CSV")
    }

    /// Exports the taxonomy table as TSV via an NSSavePanel.
    ///
    /// Same columns as CSV but tab-separated.
    private func exportTSV() {
        exportDelimited(separator: "\t", fileExtension: "tsv", fileTypeName: "TSV")
    }

    /// Shared implementation for CSV/TSV export.
    ///
    /// - Parameters:
    ///   - separator: Column separator character.
    ///   - fileExtension: File extension without dot (e.g., "csv").
    ///   - fileTypeName: Human-readable format name for the panel.
    private func exportDelimited(separator: String, fileExtension: String, fileTypeName: String) {
        guard let tree, let window = view.window else {
            logger.warning("Cannot export: no tree or window")
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Taxonomy as \(fileTypeName)"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        // Default filename from input file
        let baseName = classificationResult?.config.inputFiles.first?
            .deletingPathExtension().lastPathComponent ?? "classification"
        panel.nameFieldStringValue = "\(baseName)_classification.\(fileExtension)"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }

            let content = self.buildDelimitedExport(tree: tree, separator: separator)
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                logger.info("Exported taxonomy \(fileTypeName, privacy: .public) to \(url.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("Export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Builds the delimited text content for export.
    ///
    /// Writes a header row followed by all nodes in depth-first order.
    ///
    /// - Parameters:
    ///   - tree: The taxonomy tree to export.
    ///   - separator: Column separator character.
    /// - Returns: The complete file content as a string.
    func buildDelimitedExport(tree: TaxonTree, separator: String) -> String {
        var lines: [String] = []

        // Header
        var headers = ["Name", "Rank", "Reads (Clade)", "Reads (Direct)", "Clade %", "Direct %"]
        // Append visible metadata column headers
        let metaHeaders = taxonomyTableView.metadataColumns.exportHeaders
        headers.append(contentsOf: metaHeaders)
        lines.append(headers.joined(separator: separator))

        // Metadata values (constant per sample for all rows)
        let metaValues = taxonomyTableView.metadataColumns.exportValues

        // Depth-first traversal
        let allNodes = tree.allNodes()
        for node in allNodes {
            let cladePercent = tree.totalReads > 0
                ? String(format: "%.4f", Double(node.readsClade) / Double(tree.totalReads) * 100)
                : "0.0000"
            let directPercent = tree.totalReads > 0
                ? String(format: "%.4f", Double(node.readsDirect) / Double(tree.totalReads) * 100)
                : "0.0000"

            // Escape fields that may contain the separator (mainly for CSV)
            let name = escapeField(node.name, separator: separator)
            let rank = escapeField(node.rank.displayName, separator: separator)

            var row = [
                name,
                rank,
                "\(node.readsClade)",
                "\(node.readsDirect)",
                cladePercent,
                directPercent,
            ]
            for value in metaValues {
                row.append(escapeField(value, separator: separator))
            }
            lines.append(row.joined(separator: separator))
        }

        // Include unclassified node if present
        if let unclassified = tree.unclassifiedNode {
            let cladePercent = tree.totalReads > 0
                ? String(format: "%.4f", Double(unclassified.readsClade) / Double(tree.totalReads) * 100)
                : "0.0000"
            var row = [
                escapeField(unclassified.name, separator: separator),
                escapeField(unclassified.rank.displayName, separator: separator),
                "\(unclassified.readsClade)",
                "\(unclassified.readsDirect)",
                cladePercent,
                cladePercent,
            ]
            for value in metaValues {
                row.append(escapeField(value, separator: separator))
            }
            lines.append(row.joined(separator: separator))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Escapes a field value for delimited output.
    ///
    /// For CSV, fields containing commas, quotes, or newlines are quoted.
    /// For TSV, fields are returned unmodified (tabs in taxon names are rare).
    ///
    /// - Parameters:
    ///   - value: The field value.
    ///   - separator: The column separator.
    /// - Returns: The escaped field value.
    private func escapeField(_ value: String, separator: String) -> String {
        guard separator == "," else { return value }
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }

    /// Copies the classification summary text to the system pasteboard.
    private func copySummaryToClipboard() {
        guard let result = classificationResult else {
            logger.warning("Cannot copy summary: no classification result")
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(result.summary, forType: .string)

        logger.info("Copied classification summary to clipboard")
    }

    // MARK: - Export Actions (for NSMenuItem targets)

    @objc private func exportCSVAction(_ sender: Any) {
        exportCSV()
    }

    @objc private func exportTSVAction(_ sender: Any) {
        exportTSV()
    }

    @objc private func copySummaryAction(_ sender: Any) {
        copySummaryToClipboard()
    }

    @objc private func showProvenanceAction(_ sender: Any) {
        showProvenancePopover(relativeTo: sender)
    }

    // MARK: - Provenance Popover

    /// Shows a provenance popover with classification pipeline metadata.
    ///
    /// Displays tool version, database, preset, confidence, runtime, and input
    /// file information from the ``ClassificationResult``.
    ///
    /// - Parameter sender: The view or button to anchor the popover to.
    private func showProvenancePopover(relativeTo sender: Any) {
        guard let result = classificationResult else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 220)

        let provenanceView = TaxonomyProvenanceView(result: result)
        popover.contentViewController = NSHostingController(rootView: provenanceView)

        // Anchor to the action bar or the sender button
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

    /// Returns the export menu for the action bar or toolbar.
    ///
    /// This builds an NSMenu with export and provenance items that can be
    /// attached to a button or presented programmatically.
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

        menu.addItem(.separator())

        let provenanceItem = NSMenuItem(
            title: "Show Provenance\u{2026}",
            action: #selector(showProvenanceAction(_:)),
            keyEquivalent: ""
        )
        provenanceItem.target = self
        menu.addItem(provenanceItem)

        return menu
    }

    // MARK: - Expand / Collapse All (View Menu Actions)

    /// Expands all items in the taxonomy table.
    ///
    /// Triggered by the View > Expand All menu item (Cmd+Shift+Right).
    @objc func expandAllTaxonomyItems(_ sender: Any?) {
        taxonomyTableView.expandAll()
    }

    /// Collapses all items in the taxonomy table.
    ///
    /// Triggered by the View > Collapse All menu item (Cmd+Shift+Left).
    @objc func collapseAllTaxonomyItems(_ sender: Any?) {
        taxonomyTableView.collapseAll()
    }

    // MARK: - Testing Accessors

    /// Returns the summary bar for testing.
    var testSummaryBar: TaxonomySummaryBar { summaryBar }

    /// Returns the breadcrumb bar for testing.
    var testBreadcrumbBar: TaxonomyBreadcrumbBar { breadcrumbBar }

    /// Returns the sunburst view for testing.
    var testSunburstView: TaxonomySunburstView { sunburstView }

    /// Returns the taxonomy table view for testing.
    var testTableView: TaxonomyTableView { taxonomyTableView }

    /// Returns the action bar for testing.
    var testActionBar: ClassifierActionBar { actionBar }

    /// Returns the split view for testing.
    var testSplitView: NSSplitView { splitView }

    /// Returns the current classification result for testing.
    var testClassificationResult: ClassificationResult? { classificationResult }

    /// Returns the taxa collections drawer for testing.
    var testCollectionsDrawer: TaxaCollectionsDrawerView? { taxaCollectionsDrawerView }

    /// Returns whether the taxa collections drawer is open for testing.
    var testIsCollectionsDrawerOpen: Bool { isTaxaCollectionsDrawerOpen }

    /// Returns the batch table view for testing.
    var testBatchTableView: BatchClassificationTableView { batchTableView }
}
