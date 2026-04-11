// EsVirituResultViewController.swift - Complete EsViritu viral detection result browser
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import SwiftUI
import os.log

private let logger = Logger(subsystem: LogSubsystem.app, category: "EsVirituResultVC")

// MARK: - BatchEsVirituRow

/// A flat row representing a single viral assembly from a single sample, used
/// when aggregating multiple EsViritu results into a batch view.
struct BatchEsVirituRow: Sendable {
    let sample: String
    let virusName: String
    let family: String?
    let assembly: String
    let readCount: Int
    let uniqueReads: Int
    let rpkmf: Double
    let coverageBreadth: Double
    let coverageDepth: Double

    static func fromAssemblies(
        _ assemblies: [ViralAssembly],
        sampleId: String,
        uniqueReadsByAssembly: [String: Int] = [:]
    ) -> [BatchEsVirituRow] {
        assemblies.map { asm in
            // Compute coverage breadth from covered bases / assembly length.
            let coveredBases = asm.contigs.reduce(0) { $0 + $1.coveredBases }
            let coverageBreadth: Double = asm.assemblyLength > 0
                ? Double(coveredBases) / Double(asm.assemblyLength)
                : 0
            return BatchEsVirituRow(
                sample: sampleId, virusName: asm.name, family: asm.family,
                assembly: asm.assembly, readCount: asm.totalReads,
                uniqueReads: uniqueReadsByAssembly[asm.assembly] ?? 0, rpkmf: asm.rpkmf,
                coverageBreadth: coverageBreadth, coverageDepth: asm.meanCoverage
            )
        }
    }
}

// MARK: - EsVirituResultViewController

/// A full-screen viral detection browser combining a detail pane and detection table.
///
/// `EsVirituResultViewController` is the primary UI for displaying EsViritu viral
/// metagenomics results. It replaces the normal sequence viewer content area
/// following the same child-VC pattern as ``TaxonomyViewController``.
///
/// ## Layout
///
/// ```
/// +------------------------------------------+
/// | Summary Bar (48pt)                       |
/// +------------------------------------------+
/// |  Detail Pane  |  Detection Table      |
/// |  (coverage,      |                       |
/// |   BAM viewer)    |                       |
/// |    (resizable NSSplitView)               |
/// | Action Bar (36pt)                        |
/// +------------------------------------------+
/// ```
/// ## Detail Pane
///
/// The left pane shows context-sensitive content:
/// - When a virus is selected: genome coverage plot + alignment summary + mini BAM viewer
/// - When nothing is selected: overview of all detected viruses
///
/// ## Detection Table
///
/// The right pane shows ``ViralDetectionTableView`` -- an expandable
/// `NSOutlineView` with assembly-level parent rows and per-contig child rows.
///
/// ## Actions
///
/// The bottom action bar provides:
/// - Export CSV/TSV of all detections
/// - Re-run EsViritu with different parameters
/// - Show pipeline provenance (tool version, runtime, database)
///
/// ## Thread Safety
///
/// This class is `@MainActor` isolated and uses raw `NSSplitView` (not
/// `NSSplitViewController`) per macOS 26 deprecated API rules.
@MainActor
public final class EsVirituResultViewController: NSViewController, NSSplitViewDelegate {

    // MARK: - Data

    /// The EsViritu result driving this view.
    private(set) var esVirituResult: LungfishIO.EsVirituResult?

    /// The EsViritu config used for this run (for re-run and provenance).
    private(set) var esVirituConfig: EsVirituConfig?

    /// Path to the final BAM file, if available (from --keep True).
    ///
    /// Internal visibility so that ``ViewerViewController+EsViritu`` extraction
    /// callbacks can check BAM availability.
    var bamURL: URL?
    /// Path to the BAM index (.csi/.bai), if available.
    var bamIndexURL: URL?

    /// Background task computing unique reads across all samples in batch mode.
    private var batchUniqueReadComputationTask: Task<Void, Never>?

    /// Sidecar filename for persisted unique read counts.
    private static let uniqueReadsSidecar = "esviritu-unique-reads.json"

    // MARK: - Child Views

    private let summaryBar = EsVirituSummaryBar()
    let splitView = NSSplitView()
    private let detailPane = EsVirituDetailPane()
    private let detectionTableView = ViralDetectionTableView()
    let actionBar = ClassifierActionBar()
    private var splitViewBottomConstraint: NSLayoutConstraint?

    // MARK: - Custom Action Bar Buttons

    /// "Recompute Unique Reads" button — only shown in batch mode.
    private let recomputeUniqueReadsButton: NSButton = {
        let btn = NSButton()
        btn.title = "Recompute Unique Reads"
        btn.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Recompute Unique Reads")
        btn.bezelStyle = .accessoryBarAction
        btn.imagePosition = .imageLeading
        btn.controlSize = .small
        btn.font = .systemFont(ofSize: 11)
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.isHidden = true  // shown only in batch mode
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

    // MARK: - Split View State

    /// Whether the initial divider position has been applied.
    private var didSetInitialSplitPosition = false

    // MARK: - Selection Sync

    /// Prevents infinite feedback loops when syncing selection between views.
    private var suppressSelectionSync = false

    // MARK: - Inspector Sample Picker

    /// EsViritu sample entry for the unified picker.
    public struct EsVirituSampleEntry: ClassifierSampleEntry {
        public let id: String
        public let displayName: String
        public let detectedVirusCount: Int

        public var metricLabel: String { "viruses" }
        public var metricValue: String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return formatter.string(from: NSNumber(value: detectedVirusCount)) ?? "\(detectedVirusCount)"
        }
    }

    /// Observable state shared with the Inspector sample picker.
    public var samplePickerState: ClassifierSamplePickerState!

    /// Sample entries for the unified picker (single entry for EsViritu).
    public var sampleEntries: [EsVirituSampleEntry] = []

    /// Common prefix stripped from sample display names (empty for single-sample).
    public var strippedPrefix: String = ""

    /// Sample metadata for dynamic column display in the detection table.
    var sampleMetadataStore: SampleMetadataStore? {
        didSet {
            let selected = samplePickerState?.selectedSamples.sorted() ?? []
            let sampleId = selected.count == 1 ? selected.first : nil
            detectionTableView.metadataColumns.update(store: sampleMetadataStore, sampleId: sampleId)
            batchTableView.metadataColumns.update(store: sampleMetadataStore, sampleId: nil)
        }
    }

    // MARK: - Callbacks

    /// Called when the user requests BLAST verification for a detection.
    ///
    /// Parameters:
    /// - detection: Representative detection row for the selected virus.
    /// - readCount: Number of unique reads to submit.
    /// - accessions: One or more accessions to extract reads from.
    /// - bamURL: BAM with mapped reads for extraction.
    /// - bamIndexURL: BAM index for random-access extraction.
    public var onBlastVerification: ((ViralDetection, Int, [String], URL?, URL?) -> Void)?

    /// Called when the user wants to re-run EsViritu with the same or different settings.
    public var onReRun: (() -> Void)?

    /// Unified metagenomics drawer (available for views that adopt it).
    /// Provides Samples, Collections, and BLAST Results tabs.
    private(set) lazy var metagenomicsDrawer: MetagenomicsDrawerView = {
        MetagenomicsDrawerView()
    }()

    /// The BLAST results drawer embedded at the bottom of the view.
    private var blastDrawerView: BlastResultsDrawerTab?
    private var blastDrawerBottomConstraint: NSLayoutConstraint?
    private var isBlastDrawerOpen = false

    /// Called when the user clicks "View Alignments" to open the BAM viewer
    /// for a specific viral reference. Parameters: BAM URL, reference accession.
    public var onViewBAM: ((URL, String) -> Void)?

    // MARK: - Batch Mode

    /// Whether this view controller is displaying an aggregated batch result.
    var isBatchMode: Bool = false

    /// Whether the last `configureFromDatabase` call loaded data from a pre-built aggregated manifest
    /// rather than parsing per-sample files. Used to populate the Inspector manifest status.
    private(set) var didLoadFromManifestCache: Bool = false

    /// All flat rows loaded from each sample's EsViritu detection file in batch mode.
    var allBatchRows: [BatchEsVirituRow] = []

    /// Flat table used in batch mode (placed inside the right pane of `splitView`).
    private(set) var batchTableView = BatchEsVirituTableView()

    /// The URL of the batch result directory (set during `configureFromDatabase`).
    var batchURL: URL?

    /// Container for the right pane content (detection table or batch table).
    /// Saved as an instance property so `setupBatchTableView` can add to it.
    private var rightPaneContainer = NSView()

    /// Lookup dictionary mapping (sampleId, assemblyAccession) -> ViralAssembly,
    /// built during `configureFromDatabase` for detail pane wiring.
    private var batchAssemblyLookup: [String: ViralAssembly] = [:]

    /// Lookup dictionary mapping assemblyAccession -> BAM URL, built during
    /// `configureFromDatabase` for miniBAM wiring in batch mode.
    private var batchBAMLookup: [String: URL] = [:]

    /// Lookup dictionary mapping assemblyAccession -> BAM index URL.
    private var batchBAMIndexLookup: [String: URL] = [:]

    // MARK: - Lifecycle

    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view = container

        setupSummaryBar()
        setupSplitView()
        setupBatchTableView()
        setupMiniBAMViewer()
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

    // MARK: - Mini BAM Viewer

    private var miniBAMController: MiniBAMViewController?

    /// The assembly accession currently displayed in the mini BAM viewer.
    private var currentBAMAssemblyAccession: String?
    /// The contig accession currently displayed in the mini BAM viewer.
    private var currentBAMContigAccession: String?

    private func setupMiniBAMViewer() {
        let bamVC = MiniBAMViewController()
        bamVC.onReadStatsUpdated = { [weak self] _, uniqueReads in
            guard let self,
                  let assemblyAcc = self.currentBAMAssemblyAccession,
                  let contigAcc = self.currentBAMContigAccession else { return }
            self.detectionTableView.setUniqueReadCount(
                uniqueReads,
                forContig: contigAcc,
                inAssembly: assemblyAcc
            )
        }
        addChild(bamVC)
        miniBAMController = bamVC
        detailPane.miniBAMViewController = bamVC
    }

    public override func viewDidLayout() {
        super.viewDidLayout()

        // Apply the initial 40/60 split once the split view has real bounds.
        if !didSetInitialSplitPosition, splitView.bounds.width > 0 {
            didSetInitialSplitPosition = true
            let position = round(splitView.bounds.width * 0.4)
            splitView.setPosition(position, ofDividerAt: 0)
        }
    }

    // MARK: - SQLite Database Mode

    /// The SQLite database backing this VC when loaded via `configureFromDatabase`.
    private var esVirituDatabase: EsVirituDatabase?

    /// Configures this VC from a pre-built SQLite database instead of parsing
    /// per-sample files or manifest caches.
    ///
    /// Sets `isBatchMode = true` so the existing sample selection and filter
    /// paths operate correctly. Populates `allBatchRows`, sample entries,
    /// and BAM lookups from the database, then shows the batch table.
    public func configureFromDatabase(_ db: EsVirituDatabase, resultURL: URL) {
        self.esVirituDatabase = db
        self.batchURL = resultURL
        self.isBatchMode = true
        self.didLoadFromManifestCache = true

        // Fetch all samples from the DB.
        let sampleList = (try? db.fetchSamples()) ?? []
        let sampleIds = sampleList.map(\.sample).sorted()

        // Build sample entries for the Inspector picker.
        sampleEntries = sampleIds.map { sid in
            let count = sampleList.first(where: { $0.sample == sid })?.detectionCount ?? 0
            return EsVirituSampleEntry(
                id: sid,
                displayName: FASTQDisplayNameResolver.resolveDisplayName(sampleId: sid, projectURL: nil),
                detectedVirusCount: count
            )
        }
        samplePickerState = ClassifierSamplePickerState(allSamples: Set(sampleIds))
        samplePickerState.selectedSamples = Set(sampleIds)

        // Load ALL rows from the DB (filtering by selection happens in applyBatchSampleFilter).
        reloadFromDatabase()

        // Wire batch table callbacks (same pattern as configureFromDatabase).
        batchTableView.metadataColumns.isMultiSampleMode = true
        batchTableView.onRowSelected = { [weak self] row in
            guard let self else { return }
            self.actionBar.updateInfoText("1 row selected")
            // Show the detail pane for the selected virus+sample combination.
            let key = "\(row.sample)\t\(row.assembly)"
            if let assembly = self.batchAssemblyLookup[key] {
                let batchBAMURL = self.batchBAMLookup[row.sample]
                let batchBAMIndexURL = self.batchBAMIndexLookup[row.sample]
                let savedBAMURL = self.bamURL
                let savedBAMIndexURL = self.bamIndexURL
                self.bamURL = batchBAMURL
                self.bamIndexURL = batchBAMIndexURL
                self.showAssemblyDetail(assembly)
                self.bamURL = savedBAMURL
                self.bamIndexURL = savedBAMIndexURL
            }
        }
        batchTableView.onMultipleRowsSelected = { [weak self] rows in
            guard let self else { return }
            self.actionBar.updateInfoText("\(rows.count) rows selected")
            self.showMultiSelectionPlaceholder(count: rows.count)
        }
        batchTableView.onSelectionCleared = { [weak self] in
            guard let self else { return }
            self.actionBar.updateInfoText("Select a virus to view details")
            self.hideMultiSelectionPlaceholder()
        }

        // Batch mode prefers single-sample hierarchical display when possible.
        detectionTableView.isHidden = false
        batchTableView.isHidden = true

        summaryBar.updateBatch(sampleCount: sampleEntries.count, totalDetections: allBatchRows.count)

        applyBatchSampleFilter()

        logger.info("configureFromDatabase: loaded \(self.allBatchRows.count) rows across \(sampleIds.count) samples from SQLite")
    }

    /// Loads all rows from the SQLite database into `allBatchRows`.
    ///
    /// Fetches every sample's rows (selection filtering is done by `applyBatchSampleFilter`).
    /// Groups per-contig `EsVirituDetectionRow`s by (sample, assembly) to produce
    /// `BatchEsVirituRow`s, populates `batchAssemblyLookup` with fully-built
    /// ``ViralAssembly`` values for the detail-pane wiring, and resolves
    /// BAM paths into `batchBAMLookup` and `batchBAMIndexLookup` from DB columns.
    private func reloadFromDatabase() {
        guard let db = esVirituDatabase else { return }

        // Clear stale lookups so reloads never accumulate data from prior loads.
        batchAssemblyLookup.removeAll()
        batchBAMLookup.removeAll()
        batchBAMIndexLookup.removeAll()

        let allSampleIds = sampleEntries.map(\.id)
        let dbRows = (try? db.fetchRows(samples: allSampleIds)) ?? []

        // Group by (sample, assembly) to aggregate per-contig rows.
        var grouped: [String: [EsVirituDetectionRow]] = [:]
        for row in dbRows {
            let key = "\(row.sample)\t\(row.assembly)"
            grouped[key, default: []].append(row)
        }

        var batchRows: [BatchEsVirituRow] = []
        for (key, group) in grouped {
            guard let first = group.first else { continue }
            let totalReads = group.reduce(0) { $0 + $1.readCount }
            let totalUniqueReads = group.reduce(0) { $0 + ($1.uniqueReads ?? 0) }
            let totalCoveredBases = group.reduce(0) { $0 + ($1.coveredBases ?? 0) }
            let assemblyLen = first.assemblyLength ?? 1
            let breadth = assemblyLen > 0 ? Double(totalCoveredBases) / Double(assemblyLen) : 0
            let coverageValues = group.compactMap(\.meanCoverage)
            let avgDepth = coverageValues.isEmpty ? 0.0 :
                coverageValues.reduce(0, +) / Double(coverageValues.count)

            batchRows.append(BatchEsVirituRow(
                sample: first.sample,
                virusName: first.virusName,
                family: first.family ?? "",
                assembly: first.assembly,
                readCount: totalReads,
                uniqueReads: totalUniqueReads,
                rpkmf: first.rpkmf ?? 0,
                coverageBreadth: breadth,
                coverageDepth: avgDepth
            ))

            // Build a ViralAssembly for the detail pane by converting each
            // DB row into a ``ViralDetection`` contig, then aggregating them
            // the same way ``EsVirituDetectionParser/groupByAssembly`` does
            // for single-sample mode. Without this the detail pane stays
            // blank when a row is clicked (``batchAssemblyLookup`` lookup
            // misses and ``showAssemblyDetail`` is never called).
            let contigs: [ViralDetection] = group.map { row in
                ViralDetection(
                    sampleId: row.sample,
                    name: row.virusName,
                    description: row.description ?? "",
                    length: row.contigLength ?? 0,
                    segment: row.segment,
                    accession: row.accession,
                    assembly: row.assembly,
                    assemblyLength: row.assemblyLength ?? 0,
                    kingdom: row.kingdom,
                    phylum: row.phylum,
                    tclass: row.tclass,
                    order: row.torder,
                    family: row.family,
                    genus: row.genus,
                    species: row.species,
                    subspecies: row.subspecies,
                    rpkmf: row.rpkmf ?? 0,
                    readCount: row.readCount,
                    coveredBases: row.coveredBases ?? 0,
                    meanCoverage: row.meanCoverage ?? 0,
                    avgReadIdentity: row.avgReadIdentity ?? 0,
                    pi: row.pi ?? 0,
                    filteredReadsInSample: row.filteredReadsInSample ?? 0
                )
            }

            // Assembly-level weighted averages (matches EsVirituDetectionParser.groupByAssembly).
            let weightedCoverage: Double
            let weightedIdentity: Double
            if totalReads > 0 {
                weightedCoverage = contigs.reduce(0.0) {
                    $0 + $1.meanCoverage * Double($1.readCount)
                } / Double(totalReads)
                weightedIdentity = contigs.reduce(0.0) {
                    $0 + $1.avgReadIdentity * Double($1.readCount)
                } / Double(totalReads)
            } else {
                weightedCoverage = 0
                weightedIdentity = 0
            }

            let assembly = ViralAssembly(
                assembly: first.assembly,
                assemblyLength: first.assemblyLength ?? 0,
                name: first.virusName,
                family: first.family,
                genus: first.genus,
                species: first.species,
                totalReads: totalReads,
                rpkmf: first.rpkmf ?? 0,
                meanCoverage: weightedCoverage,
                avgReadIdentity: weightedIdentity,
                contigs: contigs
            )
            batchAssemblyLookup[key] = assembly
        }

        // Resolve BAM paths from DB columns.
        // Paths stored in the DB are relative to the result directory; resolve
        // them against `batchURL` when available, otherwise fall back to treating
        // them as absolute paths (backward-compatible with older databases).
        let baseURL = batchURL
        for row in dbRows {
            if let bamPath = row.bamPath, !bamPath.isEmpty {
                let resolved: URL
                if let base = baseURL, !bamPath.hasPrefix("/") {
                    resolved = base.appendingPathComponent(bamPath)
                } else {
                    resolved = URL(fileURLWithPath: bamPath)
                }
                batchBAMLookup[row.sample] = resolved
            }
            if let bamIndexPath = row.bamIndexPath, !bamIndexPath.isEmpty {
                let resolved: URL
                if let base = baseURL, !bamIndexPath.hasPrefix("/") {
                    resolved = base.appendingPathComponent(bamIndexPath)
                } else {
                    resolved = URL(fileURLWithPath: bamIndexPath)
                }
                batchBAMIndexLookup[row.sample] = resolved
            }
        }

        allBatchRows = batchRows
    }

    /// Updates the persisted `EsVirituBatchAggregatedManifest` with newly computed unique reads.
    ///
    /// Called after background unique-reads computation so that future opens get
    /// fully-populated rows from the manifest cache.
    private func updateEsVirituBatchAggregatedManifestUniqueReads() {
        guard let batchURL,
              var aggregated = MetagenomicsBatchResultStore.loadEsVirituBatchAggregatedManifest(from: batchURL)
        else { return }

        let updatedRows = allBatchRows
        let byAssemblyAndSample = Dictionary(
            uniqueKeysWithValues: updatedRows.map { ("\($0.sample)\t\($0.assembly)", $0.uniqueReads) }
        )

        for i in aggregated.cachedRows.indices {
            let row = aggregated.cachedRows[i]
            let key = "\(row.sample)\t\(row.assembly)"
            if let uniqueReads = byAssemblyAndSample[key] {
                aggregated.cachedRows[i] = EsVirituBatchAggregatedManifest.CachedRow(
                    sample: row.sample,
                    virusName: row.virusName,
                    family: row.family,
                    assembly: row.assembly,
                    readCount: row.readCount,
                    uniqueReads: uniqueReads,
                    rpkmf: row.rpkmf,
                    coverageBreadth: row.coverageBreadth,
                    coverageDepth: row.coverageDepth
                )
            }
        }

        do {
            try MetagenomicsBatchResultStore.saveEsVirituBatchAggregatedManifest(aggregated, to: batchURL)
            logger.info("Updated EsViritu batch aggregated manifest with unique reads")
        } catch {
            logger.warning("Failed to update EsViritu batch aggregated manifest: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Filters `allBatchRows` by the samples selected in `samplePickerState`
    /// and renders the native table/detail panes for all selected samples.
    func applyBatchSampleFilter() {
        guard let state = samplePickerState else { return }
        let selected = state.selectedSamples.sorted()

        guard !selected.isEmpty else {
            esVirituResult = nil
            detectionTableView.result = nil
            detectionTableView.uniqueReadCountsByAssembly = [:]
            detectionTableView.uniqueReadCountsByContig = [:]
            detectionTableView.uniqueReadCountsBySampleAssembly = [:]
            detectionTableView.uniqueReadCountsBySampleContig = [:]
            detectionTableView.metadataColumns.isMultiSampleMode = false
            detectionTableView.metadataColumns.update(store: sampleMetadataStore, sampleId: nil)
            detectionTableView.isHidden = false
            batchTableView.isHidden = true
            showOverview()
            actionBar.updateInfoText("Select a virus to view details")
            actionBar.setBlastEnabled(false, reason: "Select a row to use BLAST Verify")
            actionBar.setExtractEnabled(false)
            return
        }

        showBatchSamplesView(sampleIds: selected)
    }

    /// Shows the native hierarchical EsViritu table/detail panes for one or more selected
    /// samples while still sourcing data from the batch SQLite database.
    private func showBatchSamplesView(sampleIds: [String]) {
        let selectedSet = Set(sampleIds)
        let assemblies: [ViralAssembly] = batchAssemblyLookup
            .compactMap { key, value in
                guard let sampleId = key.split(separator: "\t", maxSplits: 1).first.map(String.init),
                      selectedSet.contains(sampleId) else { return nil }
                return value
            }
            .sorted { $0.totalReads > $1.totalReads }

        let detections = assemblies.flatMap(\.contigs)
        let familyCount = Set(detections.compactMap(\.family)).count
        let speciesCount = Set(detections.compactMap(\.species)).count
        let totalFilteredReads = detections.map(\.filteredReadsInSample).max() ?? 0

        var coverageWindowsByAccession: [String: [ViralCoverageWindow]] = [:]
        if let db = esVirituDatabase {
            for contig in detections {
                if let windows = try? db.fetchCoverageWindows(sample: contig.sampleId, accession: contig.accession), !windows.isEmpty {
                    coverageWindowsByAccession[contig.accession] = windows.map {
                        ViralCoverageWindow(
                            accession: $0.accession,
                            windowIndex: $0.windowIndex,
                            windowStart: $0.windowStart,
                            windowEnd: $0.windowEnd,
                            averageCoverage: $0.averageCoverage
                        )
                    }
                }
            }
        }

        let result = EsVirituResult(
            sampleId: sampleIds.count == 1 ? (sampleIds.first ?? "batch") : "batch",
            detections: detections,
            assemblies: assemblies,
            taxProfile: [],
            coverageWindows: coverageWindowsByAccession.values.flatMap { $0 },
            totalFilteredReads: totalFilteredReads,
            detectedFamilyCount: familyCount,
            detectedSpeciesCount: speciesCount,
            runtime: nil,
            toolVersion: nil
        )

        var uniqueByAssembly: [String: Int] = [:]
        var uniqueBySampleAssembly: [String: Int] = [:]
        var uniqueBySampleContig: [String: Int] = [:]
        for row in allBatchRows where selectedSet.contains(row.sample) {
            uniqueByAssembly[row.assembly] = row.uniqueReads
            uniqueBySampleAssembly["\(row.sample)\t\(row.assembly)"] = row.uniqueReads
        }
        for detection in detections {
            let key = "\(detection.sampleId)\t\(detection.assembly)"
            if let unique = uniqueBySampleAssembly[key] {
                uniqueBySampleContig["\(detection.sampleId)\t\(detection.accession)"] = unique
            }
        }

        esVirituResult = result
        detectionTableView.result = result
        detectionTableView.coverageWindowsByAccession = coverageWindowsByAccession
        detectionTableView.uniqueReadCountsByAssembly = uniqueByAssembly
        detectionTableView.uniqueReadCountsBySampleAssembly = uniqueBySampleAssembly
        detectionTableView.uniqueReadCountsBySampleContig = uniqueBySampleContig
        detectionTableView.metadataColumns.isMultiSampleMode = sampleIds.count > 1
        detectionTableView.metadataColumns.update(
            store: sampleMetadataStore,
            sampleId: sampleIds.count == 1 ? sampleIds.first : nil
        )

        if let firstSample = sampleIds.first {
            setBatchBAMContext(forSample: firstSample)
        } else {
            bamURL = nil
            bamIndexURL = nil
        }

        detectionTableView.isHidden = false
        batchTableView.isHidden = true
        showOverview()
        actionBar.updateInfoText("Select a virus to view details")
        actionBar.setBlastEnabled(false, reason: "Select a row to use BLAST Verify")
        actionBar.setExtractEnabled(false)
    }

    @objc private func handleBatchSampleSelectionChanged() {
        guard isBatchMode else { return }
        applyBatchSampleFilter()
    }

    // MARK: - Batch Unique Read Computation

    /// Schedules background unique-read computation for all batch samples that have BAM
    /// files available but whose rows still show 0 unique reads.
    ///
    /// Iterates each sample in `batchBAMLookup`, skips samples where ALL assemblies already
    /// have non-zero unique reads, and launches a single `Task.detached` that processes
    /// samples sequentially. As each sample completes, `allBatchRows` is updated and
    /// `applyBatchSampleFilter()` is called to refresh the table.
    private func scheduleBatchUniqueReadComputation() {
        batchUniqueReadComputationTask?.cancel()

        // Collect samples that need computation: have a BAM but lack unique-read data.
        struct SampleWork {
            let sampleId: String
            let assemblies: [ViralAssembly]
            let bamURL: URL
            let bamIndexURL: URL
            let resultDir: URL
        }

        var workItems: [SampleWork] = []

        for (sampleId, bamURL) in batchBAMLookup {
            guard let bamIndexURL = batchBAMIndexLookup[sampleId] else { continue }

            // Collect this sample's assemblies from batchAssemblyLookup.
            let assemblies = batchAssemblyLookup
                .compactMap { key, value -> ViralAssembly? in
                    guard key.hasPrefix("\(sampleId)\t") else { return nil }
                    return value
                }
            guard !assemblies.isEmpty else { continue }

            // Check whether all assemblies already have unique reads in allBatchRows.
            let existingRows = allBatchRows.filter { $0.sample == sampleId }
            let allHaveUniqueReads = existingRows.allSatisfy { $0.uniqueReads > 0 }
            if allHaveUniqueReads { continue }

            // Derive result dir from bamURL: <resultDir>/<sampleId>_temp/<bamName>
            // so resultDir = bamURL.deletingLastPathComponent().deletingLastPathComponent()
            let resultDir = bamURL
                .deletingLastPathComponent()  // <sampleId>_temp/
                .deletingLastPathComponent()  // <resultDir>/

            workItems.append(SampleWork(
                sampleId: sampleId,
                assemblies: assemblies.sorted { $0.totalReads > $1.totalReads },
                bamURL: bamURL,
                bamIndexURL: bamIndexURL,
                resultDir: resultDir
            ))
        }

        guard !workItems.isEmpty else {
            logger.debug("scheduleBatchUniqueReadComputation: All samples already have unique reads")
            return
        }

        logger.info("scheduleBatchUniqueReadComputation: Starting computation for \(workItems.count) sample(s)")

        batchUniqueReadComputationTask = Task { [weak self] in
            for work in workItems {
                if Task.isCancelled { return }

                let provider = AlignmentDataProvider(
                    alignmentPath: work.bamURL.path,
                    indexPath: work.bamIndexURL.path
                )

                // Compute unique reads per assembly for this sample.
                var uniqueByAssembly: [String: Int] = [:]

                for assembly in work.assemblies {
                    if Task.isCancelled { return }

                    var assemblyUniqueTotal = 0
                    var fetchedAny = false

                    for contig in assembly.contigs {
                        if Task.isCancelled { return }
                        guard contig.length > 0 else { continue }

                        let reads = (try? await provider.fetchReads(
                            chromosome: contig.accession,
                            start: 0,
                            end: contig.length,
                            excludeFlags: 0x904
                        )) ?? []

                        if reads.isEmpty { continue }
                        fetchedAny = true
                        assemblyUniqueTotal += min(contig.readCount, Self.deduplicatedReadCount(from: reads))
                    }

                    if fetchedAny || assembly.contigs.count == 1 {
                        uniqueByAssembly[assembly.assembly] = assemblyUniqueTotal
                    }
                }

                if Task.isCancelled { return }
                if uniqueByAssembly.isEmpty { continue }

                let sampleId = work.sampleId
                let resultDir = work.resultDir
                let assemblyCount = uniqueByAssembly.count

                logger.info("scheduleBatchUniqueReadComputation: Computed unique reads for \(sampleId, privacy: .public) — \(assemblyCount) assemblies")

                // Capture a snapshot for the main-actor closure.
                let snapshotByAssembly = uniqueByAssembly
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }

                        // Update allBatchRows for this sample's assemblies.
                        self.allBatchRows = self.allBatchRows.map { row in
                            guard row.sample == sampleId,
                                  let newCount = snapshotByAssembly[row.assembly] else {
                                return row
                            }
                            return BatchEsVirituRow(
                                sample: row.sample,
                                virusName: row.virusName,
                                family: row.family,
                                assembly: row.assembly,
                                readCount: row.readCount,
                                uniqueReads: newCount,
                                rpkmf: row.rpkmf,
                                coverageBreadth: row.coverageBreadth,
                                coverageDepth: row.coverageDepth
                            )
                        }
                        self.applyBatchSampleFilter()

                        // Persist the unique reads sidecar for this sample.
                        self.persistBatchUniqueReads(
                            uniqueByAssembly: snapshotByAssembly,
                            toResultDir: resultDir
                        )

                        // Update the materialized batch aggregated manifest with new unique
                        // reads so future opens get fully-populated rows from cache.
                        self.updateEsVirituBatchAggregatedManifestUniqueReads()
                    }
                }
            }
        }
    }

    /// Persists unique read counts for a single batch sample to its result directory sidecar.
    private func persistBatchUniqueReads(uniqueByAssembly: [String: Int], toResultDir resultDir: URL) {
        let cache = UniqueReadCache(byAssembly: uniqueByAssembly, byContig: [:])
        let sidecarURL = resultDir.appendingPathComponent(Self.uniqueReadsSidecar)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(cache)
            try data.write(to: sidecarURL)
            logger.info("Persisted batch unique reads for \(uniqueByAssembly.count) assemblies at \(resultDir.lastPathComponent, privacy: .public)")
        } catch {
            logger.warning("Failed to persist batch unique reads: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Unique Read Helpers

    /// Counts unique reads by deduplicating on position-strand fingerprint.
    private static func deduplicatedReadCount(from reads: [AlignedRead]) -> Int {
        AlignedRead.deduplicatedReadCount(from: reads)
    }

    /// Sidecar data structure for persisted unique read counts.
    private struct UniqueReadCache: Codable {
        var byAssembly: [String: Int]
        var byContig: [String: Int]
    }

    // MARK: - Setup: Summary Bar

    private func setupSummaryBar() {
        summaryBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(summaryBar)
    }

    // MARK: - Setup: Split View

    /// Configures the NSSplitView with detail pane (left) and detection table (right).
    ///
    /// The left pane shows context-sensitive content:
    /// - When a virus is selected: genome coverage plot + alignment summary
    /// - When nothing is selected: overview of all detected viruses
    ///
    /// Uses raw NSSplitView (not NSSplitViewController) per macOS 26 rules.
    private func setupSplitView() {
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self

        // Detail pane (left) — coverage plots, BAM info, overview
        let detailContainer = NSView()
        detailPane.autoresizingMask = [.width, .height]
        detailContainer.addSubview(detailPane)

        // Multi-selection placeholder overlay on the detail container
        detailContainer.addSubview(multiSelectionPlaceholder)
        NSLayoutConstraint.activate([
            multiSelectionPlaceholder.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            multiSelectionPlaceholder.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
            multiSelectionPlaceholder.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            multiSelectionPlaceholder.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
        ])

        // Table container (right pane) — stored as instance property so
        // setupBatchTableView() can add batchTableView inside it later.
        detectionTableView.autoresizingMask = [.width, .height]
        rightPaneContainer.addSubview(detectionTableView)

        splitView.addArrangedSubview(detailContainer)
        splitView.addArrangedSubview(rightPaneContainer)

        // Table pane is preferred to resize (detail pane holds width more firmly)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        view.addSubview(splitView)
    }

    // MARK: - Setup: Batch Table View

    /// Adds the batch table view inside the right pane container so that the
    /// split view (and thus the detail pane) remains visible in batch mode.
    /// Hidden by default; shown when `configureFromDatabase` is called.
    private func setupBatchTableView() {
        batchTableView.translatesAutoresizingMaskIntoConstraints = false
        batchTableView.isHidden = true
        rightPaneContainer.addSubview(batchTableView)
        NSLayoutConstraint.activate([
            batchTableView.topAnchor.constraint(equalTo: rightPaneContainer.topAnchor),
            batchTableView.bottomAnchor.constraint(equalTo: rightPaneContainer.bottomAnchor),
            batchTableView.leadingAnchor.constraint(equalTo: rightPaneContainer.leadingAnchor),
            batchTableView.trailingAnchor.constraint(equalTo: rightPaneContainer.trailingAnchor),
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
            // Summary bar (top, below safe area)
            summaryBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            summaryBar.heightAnchor.constraint(equalToConstant: 48),

            // Action bar (bottom, fixed height)
            actionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            actionBar.heightAnchor.constraint(equalToConstant: 36),

            // Split view (fills remaining space; batchTableView is inside rightPaneContainer)
            splitView.topAnchor.constraint(equalTo: summaryBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])

        let bottomConstraint = splitView.bottomAnchor.constraint(equalTo: actionBar.topAnchor)
        bottomConstraint.isActive = true
        splitViewBottomConstraint = bottomConstraint
    }

    // MARK: - Callback Wiring

    private func wireCallbacks() {
        // Table selection -> detail pane + action bar update
        detectionTableView.onAssemblySelected = { [weak self] assembly in
            guard let self else { return }
            self.hideMultiSelectionPlaceholder()
            if let assembly {
                self.setBatchBAMContext(forSample: assembly.contigs.first?.sampleId)
                // Update action bar with selection info
                self.updateActionBarForAssembly(name: assembly.name, readCount: assembly.totalReads)
                self.actionBar.setBlastEnabled(true)
                self.actionBar.setExtractEnabled(true)
                self.showAssemblyDetail(assembly)
            } else {
                self.showOverview()
                self.actionBar.setBlastEnabled(false, reason: "Select a row to use BLAST Verify")
                self.actionBar.setExtractEnabled(false)
            }
        }

        // Table multi-selection -> placeholder + action bar update
        detectionTableView.onMultipleSelected = { [weak self] count in
            guard let self else { return }
            self.showMultiSelectionPlaceholder(count: count)
            self.actionBar.updateInfoText("\(count) items selected")
            self.actionBar.setBlastEnabled(false, reason: "Select a single row to use BLAST Verify")
            self.actionBar.setExtractEnabled(true)
        }

        // Detail pane "View Alignments" button -> forward to host VC
        detailPane.onViewBAM = { [weak self] accession in
            guard let self, let bamURL = self.bamURL else { return }
            self.onViewBAM?(bamURL, accession)
        }

        // Previous action bar / detail pane wiring handled above.
        // first handler above.

        // Table detection selection -> action bar update
        detectionTableView.onDetectionSelected = { [weak self] detection in
            guard let self else { return }
            self.hideMultiSelectionPlaceholder()
            self.setBatchBAMContext(forSample: detection.sampleId)
            self.updateActionBarForAssembly(name: detection.name, readCount: detection.readCount)
            self.actionBar.setBlastEnabled(true)
            self.actionBar.setExtractEnabled(true)

            guard let assembly = self.resolveAssembly(for: detection) else {
                logger.warning("Unable to resolve parent assembly for detection \(detection.accession, privacy: .public)")
                return
            }
            self.showAssemblyDetail(assembly, focusedContigAccession: detection.accession)
        }

        // Table BLAST request -> forward to host with BAM context
        detectionTableView.onBlastRequested = { [weak self] detection, readCount, accessions in
            guard let self else { return }
            let sampleBAMURL = self.batchBAMLookup[detection.sampleId] ?? self.bamURL
            let sampleBAMIndexURL = self.batchBAMIndexLookup[detection.sampleId] ?? self.bamIndexURL
            self.onBlastVerification?(detection, readCount, accessions, sampleBAMURL, sampleBAMIndexURL)
        }

        // Table extract request -> route to the unified extraction dialog.
        detectionTableView.onExtractReadsRequested = { [weak self] in
            self?.presentUnifiedExtractionDialog()
        }

        // Action bar Extract FASTQ -> route to the unified extraction dialog.
        actionBar.onExtractFASTQ = { [weak self] in
            self?.presentUnifiedExtractionDialog()
        }

        // Action bar BLAST verify -> show BLAST config popover for the current selection
        actionBar.onBlastVerify = { [weak self] in
            guard let self else { return }
            self.detectionTableView.showBlastPopoverForSelectedRow()
        }

        // Action bar export
        actionBar.onExport = { [weak self] in
            self?.showExportMenu()
        }

        // Action bar provenance
        actionBar.onProvenance = { [weak self] sender in
            self?.showProvenancePopover(relativeTo: sender)
        }

        // Custom button: Recompute Unique Reads (hidden until batch mode is active)
        recomputeUniqueReadsButton.target = self
        recomputeUniqueReadsButton.action = #selector(recomputeUniqueReadsTapped)
        actionBar.addCustomButton(recomputeUniqueReadsButton)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLayoutSwapRequested),
            name: .metagenomicsLayoutSwapRequested,
            object: nil
        )
    }

    private func setBatchBAMContext(forSample sampleId: String?) {
        guard isBatchMode else { return }
        guard let sampleId else {
            bamURL = nil
            bamIndexURL = nil
            return
        }
        bamURL = batchBAMLookup[sampleId]
        bamIndexURL = batchBAMIndexLookup[sampleId]
    }

    private func currentSelectedSampleIDForActions() -> String? {
        detectionTableView.selectedSampleIDs().first
    }

    // MARK: - Recompute Unique Reads

    @objc private func recomputeUniqueReadsTapped() {
        recomputeAllUniqueReads()
    }

    /// Clears all cached unique read data and restarts computation from BAM files for
    /// all assemblies across all samples in batch mode.
    func recomputeAllUniqueReads() {
        // 1. Zero out unique reads in allBatchRows so the table immediately shows 0
        //    and the computation guard (allHaveUniqueReads) doesn't skip any sample.
        allBatchRows = allBatchRows.map { row in
            BatchEsVirituRow(
                sample: row.sample,
                virusName: row.virusName,
                family: row.family,
                assembly: row.assembly,
                readCount: row.readCount,
                uniqueReads: 0,
                rpkmf: row.rpkmf,
                coverageBreadth: row.coverageBreadth,
                coverageDepth: row.coverageDepth
            )
        }
        applyBatchSampleFilter()

        // 2. Delete on-disk caches.
        if let batchURL {
            // Delete the materialized aggregated manifest so next open re-parses fresh.
            let manifestURL = batchURL.appendingPathComponent(EsVirituBatchAggregatedManifest.filename)
            try? FileManager.default.removeItem(at: manifestURL)

            // Delete per-sample unique reads sidecars.
            for sample in sampleEntries {
                // Derive the result directory from batchBAMLookup if available,
                // otherwise fall back to a <batchURL>/<sampleId> subdir convention.
                let resultDir: URL
                if let bamURL = batchBAMLookup[sample.id] {
                    resultDir = bamURL
                        .deletingLastPathComponent()  // <sampleId>_temp/
                        .deletingLastPathComponent()  // <resultDir>/
                } else {
                    resultDir = batchURL.appendingPathComponent(sample.id)
                }
                let cacheURL = resultDir.appendingPathComponent(Self.uniqueReadsSidecar)
                try? FileManager.default.removeItem(at: cacheURL)
            }
        }

        // 3. Cancel any existing computation.
        batchUniqueReadComputationTask?.cancel()

        // 4. Restart computation for all assemblies.
        scheduleBatchUniqueReadComputation()

        // 5. Update info text to indicate recompute is in progress.
        actionBar.updateInfoText("Recomputing unique reads for all assemblies\u{2026}")
    }

    // MARK: - Classifier extraction wiring

    /// Builds per-sample selectors from the current detection-table selection.
    private func buildEsVirituSelectors() -> [ClassifierRowSelector] {
        let accessions = detectionTableView.selectedAssemblyAccessions()
        guard !accessions.isEmpty else { return [] }
        let sampleId = isBatchMode ? detectionTableView.selectedSampleIDs().first : nil
        return [ClassifierRowSelector(sampleId: sampleId, accessions: accessions, taxIds: [])]
    }

    /// Presents the unified classifier extraction dialog for the current selection.
    private func presentUnifiedExtractionDialog() {
        guard let resultPath = esVirituDatabase?.databaseURL ?? esVirituConfig?.outputDirectory else { return }
        let firstAccession = detectionTableView.selectedAssemblyAccessions().first ?? "extract"
        presentClassifierExtractionDialog(
            tool: .esviritu,
            resultPath: resultPath,
            selectors: buildEsVirituSelectors(),
            suggestedName: "esviritu_\(firstAccession)"
        )
    }

    @objc private func handleLayoutSwapRequested(_ notification: Notification) {
        applyLayoutPreference()
    }

    /// Swaps the split view pane order based on the persisted layout preference.
    private func applyLayoutPreference() {
        let tableOnLeft = UserDefaults.standard.bool(forKey: "metagenomicsTableOnLeft")
        guard splitView.arrangedSubviews.count == 2,
              let detail = detailPane.superview,
              let table = detectionTableView.superview else { return }

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

    private func resolveAssembly(for detection: ViralDetection) -> ViralAssembly? {
        guard let result = esVirituResult else { return nil }
        if let byAssemblyID = result.assemblies.first(where: { $0.assembly == detection.assembly }) {
            return byAssemblyID
        }
        return result.assemblies.first(where: { assembly in
            assembly.contigs.contains(where: { $0.accession == detection.accession })
        })
    }

    private func coverageWindows(for assembly: ViralAssembly) -> [String: [ViralCoverageWindow]] {
        var windows: [String: [ViralCoverageWindow]] = [:]
        for contig in assembly.contigs {
            if let contigWindows = detectionTableView.coverageWindowsByAccession[contig.accession] {
                windows[contig.accession] = contigWindows
            }
        }
        return windows
    }

    private func showAssemblyDetail(_ assembly: ViralAssembly, focusedContigAccession: String? = nil) {
        currentBAMAssemblyAccession = assembly.assembly

        let selectedContig = assembly.contigs.first { $0.accession == focusedContigAccession } ?? assembly.contigs.first
        currentBAMContigAccession = selectedContig?.accession

        detailPane.showVirusDetail(
            assembly: assembly,
            coverageWindows: coverageWindows(for: assembly),
            bamURL: bamURL,
            focusedContigAccession: selectedContig?.accession
        )
    }

    private func showOverview() {
        currentBAMAssemblyAccession = nil
        currentBAMContigAccession = nil
        guard let result = esVirituResult else { return }
        detailPane.configureOverview(
            result: result,
            coverageWindows: detectionTableView.coverageWindowsByAccession,
            bamURL: bamURL
        )
    }

    // MARK: - BLAST Results

    /// Shows BLAST loading state in a bottom drawer.
    public func showBlastLoading(phase: BlastJobPhase, requestId: String?) {
        let drawer = ensureBlastDrawer()
        drawer.showLoading(phase: phase, requestId: requestId)
        openBlastDrawerIfNeeded()
    }

    /// Shows BLAST verification results in a bottom drawer.
    ///
    /// Creates a ``BlastResultsDrawerTab`` if needed, populates it with the
    /// results, and slides the drawer open with animation.
    public func showBlastResults(_ result: BlastVerificationResult) {
        let drawer = ensureBlastDrawer()
        drawer.showResults(result)
        openBlastDrawerIfNeeded()

        logger.info("Showing BLAST results: \(result.verifiedCount)/\(result.readResults.count) verified for \(result.taxonName)")
    }

    /// Shows BLAST failure state in a bottom drawer.
    public func showBlastFailure(_ message: String) {
        let drawer = ensureBlastDrawer()
        drawer.showFailure(message: message)
        openBlastDrawerIfNeeded()
    }

    private func ensureBlastDrawer() -> BlastResultsDrawerTab {
        if let blastDrawerView {
            return blastDrawerView
        }

        let drawer = BlastResultsDrawerTab()
        drawer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(drawer)

        let bottomConstraint = drawer.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: 220)
        let heightConstraint = drawer.heightAnchor.constraint(equalToConstant: 220)

        NSLayoutConstraint.activate([
            drawer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            drawer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            heightConstraint,
            bottomConstraint,
        ])

        // Re-pin main content above the drawer so opening it resizes the
        // top panels instead of drawing over them.
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
            self.blastDrawerBottomConstraint?.animator().constant = 0
            self.view.layoutSubtreeIfNeeded()
        }
        isBlastDrawerOpen = true
    }

    // MARK: - NSSplitViewDelegate

    /// Enforces minimum widths for detail pane (250px) and table (300px).
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

    // MARK: - Multi-Selection Helpers

    private func showMultiSelectionPlaceholder(count: Int) {
        if let stack = multiSelectionPlaceholder.subviews.first as? NSStackView,
           let primary = stack.arrangedSubviews.first as? NSTextField {
            primary.stringValue = "\(count) items selected"
        }
        detailPane.isHidden = true
        multiSelectionPlaceholder.isHidden = false
    }

    private func hideMultiSelectionPlaceholder() {
        multiSelectionPlaceholder.isHidden = true
        detailPane.isHidden = false
    }

    // MARK: - Action Bar Selection Helper

    /// Updates the unified action bar info text from assembly/detection selection.
    private func updateActionBarForAssembly(name: String?, readCount: Int?) {
        if let name, let count = readCount {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = ","
            let readStr = formatter.string(from: NSNumber(value: count)) ?? "\(count)"
            actionBar.updateInfoText("\(name) \u{2014} \(readStr) reads")
        } else {
            actionBar.updateInfoText("Select a virus to view details")
        }
    }

    // MARK: - Export

    private func showExportMenu() {
        let menu = buildExportMenu()
        let anchorView = actionBar
        let point = NSPoint(x: anchorView.bounds.maxX - 100, y: anchorView.bounds.maxY)
        menu.popUp(positioning: nil, at: point, in: anchorView)
    }

    /// Builds the export menu.
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
            action: #selector(showProvenanceMenuAction(_:)),
            keyEquivalent: ""
        )
        provenanceItem.target = self
        menu.addItem(provenanceItem)

        return menu
    }

    @objc private func exportCSVAction(_ sender: Any) {
        exportDelimited(separator: ",", fileExtension: "csv", fileTypeName: "CSV")
    }

    @objc private func exportTSVAction(_ sender: Any) {
        exportDelimited(separator: "\t", fileExtension: "tsv", fileTypeName: "TSV")
    }

    @objc private func copySummaryAction(_ sender: Any) {
        guard let result = esVirituResult else { return }
        let summary = buildSummaryText(result: result)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary, forType: .string)
    }

    @objc private func showProvenanceMenuAction(_ sender: Any) {
        showProvenancePopover(relativeTo: sender)
    }

    // MARK: - Delimited Export

    /// Exports the detection table as a delimited file via NSSavePanel.
    ///
    /// Uses `beginSheetModal` (not `runModal`) per macOS 26 rules.
    private func exportDelimited(separator: String, fileExtension: String, fileTypeName: String) {
        guard let result = esVirituResult, let window = view.window else {
            logger.warning("Cannot export: no result or window")
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Detections as \(fileTypeName)"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        let baseName = result.sampleId
        panel.nameFieldStringValue = "\(baseName)_detections.\(fileExtension)"

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }

            let content = self.buildDelimitedExport(result: result, separator: separator)
            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                logger.info("Exported \(fileTypeName, privacy: .public) to \(url.lastPathComponent, privacy: .public)")
            } catch {
                logger.error("Export failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Builds delimited export content from all detections.
    func buildDelimitedExport(result: LungfishIO.EsVirituResult, separator: String) -> String {
        var lines: [String] = []

        var headers = [
            "Sample ID", "Virus Name", "Accession", "Assembly", "Kingdom", "Phylum",
            "Class", "Order", "Family", "Genus", "Species", "Subspecies",
            "Read Count", "RPKMF", "Coverage", "Identity", "Covered Bases",
            "Nucleotide Diversity", "Assembly Length", "Filtered Reads",
            "Segment", "Length",
        ]
        // Append visible metadata column headers
        let metaHeaders = detectionTableView.metadataColumns.exportHeaders
        headers.append(contentsOf: metaHeaders)
        lines.append(headers.joined(separator: separator))

        // Metadata values (constant per sample for all rows in single-sample EsViritu)
        let metaValues = detectionTableView.metadataColumns.exportValues

        for detection in result.detections {
            var row = [
                escapeField(detection.sampleId, separator: separator),
                escapeField(detection.name, separator: separator),
                detection.accession,
                detection.assembly,
                escapeField(detection.kingdom ?? "", separator: separator),
                escapeField(detection.phylum ?? "", separator: separator),
                escapeField(detection.tclass ?? "", separator: separator),
                escapeField(detection.order ?? "", separator: separator),
                escapeField(detection.family ?? "", separator: separator),
                escapeField(detection.genus ?? "", separator: separator),
                escapeField(detection.species ?? "", separator: separator),
                escapeField(detection.subspecies ?? "", separator: separator),
                "\(detection.readCount)",
                String(format: "%.2f", detection.rpkmf),
                String(format: "%.2f", detection.meanCoverage),
                String(format: "%.2f", detection.avgReadIdentity),
                "\(detection.coveredBases)",
                String(format: "%.6f", detection.pi),
                "\(detection.assemblyLength)",
                "\(detection.filteredReadsInSample)",
                detection.segment ?? "",
                "\(detection.length)",
            ]
            for value in metaValues {
                row.append(escapeField(value, separator: separator))
            }
            lines.append(row.joined(separator: separator))
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

    // MARK: - Summary Text

    private func buildSummaryText(result: LungfishIO.EsVirituResult) -> String {
        var lines: [String] = []
        lines.append("EsViritu Results: \(result.sampleId)")
        lines.append("Total Filtered Reads: \(result.totalFilteredReads)")
        lines.append("Detected Families: \(result.detectedFamilyCount)")
        lines.append("Detected Species: \(result.detectedSpeciesCount)")
        lines.append("Assemblies: \(result.assemblies.count)")
        lines.append("Contigs: \(result.detections.count)")
        if let runtime = result.runtime {
            lines.append("Runtime: \(String(format: "%.1f", runtime))s")
        }
        if let version = result.toolVersion {
            lines.append("Tool Version: \(version)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Provenance Popover

    private func showProvenancePopover(relativeTo sender: Any) {
        guard let result = esVirituResult else { return }

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 220)

        let provenanceView = EsVirituProvenanceView(
            result: result,
            config: esVirituConfig
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
    var testSummaryBar: EsVirituSummaryBar { summaryBar }

    /// Returns the detail pane for testing.
    var testDetailPane: EsVirituDetailPane { detailPane }

    /// Returns the detection table view for testing.
    var testDetectionTableView: ViralDetectionTableView { detectionTableView }

    /// Returns the action bar for testing.
    var testActionBar: ClassifierActionBar { actionBar }

    /// Returns the split view for testing.
    var testSplitView: NSSplitView { splitView }

    /// Returns the current EsViritu result for testing.
    var testResult: LungfishIO.EsVirituResult? { esVirituResult }

    /// Returns the batch table view for testing.
    var testBatchTableView: BatchEsVirituTableView { batchTableView }

    /// Returns the assembly currently targeted by mini-BAM updates.
    var testCurrentBAMAssemblyAccession: String? { currentBAMAssemblyAccession }

    /// Returns the contig currently targeted by mini-BAM updates.
    var testCurrentBAMContigAccession: String? { currentBAMContigAccession }
}

// MARK: - EsVirituSummaryBar

/// Summary card bar for EsViritu viral detection results.
///
/// Shows four cards: Total Reads, Families Detected, Species Detected, and Top Virus.
@MainActor
final class EsVirituSummaryBar: GenomicSummaryCardBar {

    private var totalReads: Int = 0
    private var familyCount: Int = 0
    private var speciesCount: Int = 0
    private var topVirus: String = ""

    // MARK: - Batch State

    private var isBatchMode: Bool = false
    private var batchSampleCount: Int = 0
    private var batchTotalDetections: Int = 0

    /// Updates the summary bar with data from the result.
    func update(result: LungfishIO.EsVirituResult) {
        isBatchMode = false
        totalReads = result.totalFilteredReads
        familyCount = result.detectedFamilyCount
        speciesCount = result.detectedSpeciesCount
        topVirus = result.assemblies
            .max(by: { $0.totalReads < $1.totalReads })?
            .name ?? "\u{2014}"
        needsDisplay = true
    }

    /// Updates the summary bar to show batch aggregation statistics.
    ///
    /// Displays: "Batch: N samples · M viral detections"
    ///
    /// - Parameters:
    ///   - sampleCount: Number of samples in the batch.
    ///   - totalDetections: Total number of viral detection rows across all samples.
    func updateBatch(sampleCount: Int, totalDetections: Int) {
        isBatchMode = true
        batchSampleCount = sampleCount
        batchTotalDetections = totalDetections
        needsDisplay = true
    }

    override var cards: [Card] {
        if isBatchMode {
            return [
                Card(label: "Batch", value: "EsViritu"),
                Card(label: "Samples", value: "\(batchSampleCount)"),
                Card(label: "Detections", value: GenomicSummaryCardBar.formatCount(batchTotalDetections)),
            ]
        }
        return [
            Card(label: "Filtered Reads", value: GenomicSummaryCardBar.formatCount(totalReads)),
            Card(label: "Families", value: "\(familyCount)"),
            Card(label: "Species", value: "\(speciesCount)"),
            Card(label: "Top Virus", value: topVirus),
        ]
    }

    override func abbreviatedLabel(for label: String) -> String {
        switch label {
        case "Filtered Reads": return "Reads"
        case "Families": return "Fam."
        case "Top Virus": return "Top"
        default: return super.abbreviatedLabel(for: label)
        }
    }
}

// MARK: - EsVirituProvenanceView

/// SwiftUI popover showing pipeline provenance metadata.
struct EsVirituProvenanceView: View {
    let result: LungfishIO.EsVirituResult
    let config: EsVirituConfig?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("EsViritu Pipeline Provenance")
                .font(.headline)

            Divider()

            provenanceRow("Sample", value: result.sampleId)

            if let version = result.toolVersion {
                provenanceRow("Tool Version", value: version)
            }

            if let runtime = result.runtime {
                provenanceRow("Runtime", value: String(format: "%.1f seconds", runtime))
            }

            provenanceRow("Filtered Reads", value: "\(result.totalFilteredReads)")
            provenanceRow("Detected Families", value: "\(result.detectedFamilyCount)")
            provenanceRow("Detected Species", value: "\(result.detectedSpeciesCount)")

            if let config {
                Divider()
                provenanceRow("Paired-End", value: config.isPairedEnd ? "Yes" : "No")
                provenanceRow("Quality Filter", value: config.qualityFilter ? "Enabled" : "Disabled")
                provenanceRow("Min Read Length", value: "\(config.minReadLength) bp")
                provenanceRow("Threads", value: "\(config.threads)")
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
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
