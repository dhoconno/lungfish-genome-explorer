// EsVirituResultViewController.swift - Complete EsViritu viral detection result browser
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import SwiftUI
import os.log
import LungfishKit

private let logger = Logger(subsystem: LogSubsystem.app, category: "EsVirituResultVC")

/// Serializes async load-modify-save work per batch manifest path so
/// concurrent per-sample completions never interleave a manifest
/// read-modify-write. Mirrors `BundleManifestMutationSerializer`
/// (Sources/LungfishWorkflow/Bundles/ReferenceBundleAnnotationImportService.swift)
/// -- that type is `internal` to `LungfishWorkflow`, not `public`, so it
/// isn't importable from this leaf module; this is a local copy of the same
/// per-key task-chaining design rather than a shared import (round-3 review
/// fix, R3ML EsViritu batch manifest write race).
///
/// The per-sample unique-read computation (deleted in 13.53) processed batch samples one
/// at a time in a single `Task`, but each sample's completion previously
/// kicked off its OWN unserialized `Task.detached` to update the shared
/// `EsVirituBatchAggregatedManifest` on disk (R3-R3ML-5). Those detached
/// tasks could run concurrently -- each independently loading the manifest,
/// applying its own sample's unique-read counts, and saving -- so a later
/// writer's save could silently discard an earlier writer's still-in-flight
/// update (last-write-wins lost update). Routing every write for the same
/// `batchURL` through this serializer restores strict ordering without
/// blocking writes to a different batch's manifest.
private actor EsVirituBatchManifestMutationSerializer {
    static let shared = EsVirituBatchManifestMutationSerializer()

    private var tails: [String: (generation: Int, task: Task<Void, Never>)] = [:]

    init() {}

    /// Runs `work` after any already-queued work for `batchURL` has
    /// finished, and queues any later callers for the same `batchURL`
    /// behind this one. Callers for different batch URLs never block each
    /// other.
    ///
    /// Not reentrant for the same `batchURL` -- see the identical caveat on
    /// `BundleManifestMutationSerializer.run`.
    func run(
        batchURL: URL,
        _ work: @Sendable @escaping () async -> Void
    ) async {
        let key = batchURL.resolvingSymlinksInPath().standardizedFileURL.path
        let previousEntry = tails[key]
        let generation = (previousEntry?.generation ?? 0) + 1

        let resultTask = Task<Void, Never> {
            await previousEntry?.task.value
            await work()
        }
        tails[key] = (generation, resultTask)

        defer {
            if tails[key]?.generation == generation {
                tails.removeValue(forKey: key)
            }
        }

        await resultTask.value
    }
}

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

    init(
        sample: String,
        virusName: String,
        family: String?,
        assembly: String,
        readCount: Int,
        uniqueReads: Int,
        rpkmf: Double,
        coverageBreadth: Double,
        coverageDepth: Double
    ) {
        self.sample = sample
        self.virusName = virusName
        self.family = family
        self.assembly = assembly
        self.readCount = readCount
        self.uniqueReads = Self.normalizedUniqueReads(stored: uniqueReads, readCount: readCount)
        self.rpkmf = rpkmf
        self.coverageBreadth = coverageBreadth
        self.coverageDepth = coverageDepth
    }

    static func normalizedUniqueReads(stored: Int?, readCount: Int) -> Int {
        ClassifierUniqueReads.normalizedOrFloor(stored: stored, readCount: readCount)
    }

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
/// - When a virus with BAM data is selected: the mini BAM viewer fills the pane
/// - When a virus without BAM data is selected: genome coverage summary
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
public final class EsVirituResultViewController: NSViewController, NSSplitViewDelegate, SampleMetadataPresentationConsumer {

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

    /// Export-failure presentation seam. Tests inject a spy to assert
    /// a failure was surfaced without driving real `NSAlert` UI.
    var exportFailurePresenter: ExportFailurePresenting = DefaultExportFailurePresenter()

    // MARK: - Child Views

    private let summaryBar = EsVirituSummaryBar()
    let splitView = TrackedDividerSplitView()
    private let detailContainer = SplitPaneFillContainerView()
    private let rightPaneContainer = SplitPaneFillContainerView()
    private let detailPane = EsVirituDetailPane()
    private let detectionTableView = ViralDetectionTableView()
    let actionBar = ClassifierActionBar()
    private var splitViewBottomConstraint: NSLayoutConstraint?
    private let contentTypographyApplicator = ContentTypographyViewApplicator()
    private var contentTypographyObservation: ContentTypographyViewObservation?

    // MARK: - Multi-Selection Placeholder

    private lazy var multiSelectionPlaceholder: NSView = {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let primary = NSTextField(labelWithString: "")
        primary.font = .systemFont(ofSize: 13, weight: .semibold)
        primary.alignment = .center
        primary.lineBreakMode = .byWordWrapping
        primary.maximumNumberOfLines = 0
        primary.translatesAutoresizingMaskIntoConstraints = false

        let secondary = NSTextField(labelWithString: "Select a single row to view details")
        secondary.font = .systemFont(ofSize: 11)
        secondary.textColor = .tertiaryLabelColor
        secondary.alignment = .center
        secondary.lineBreakMode = .byWordWrapping
        secondary.maximumNumberOfLines = 0
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
            stack.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -32),
        ])

        container.isHidden = true
        return container
    }()

    // MARK: - Split View State

    /// Shared raw split-view coordinator for pane ordering and divider state.
    private let splitCoordinator = TwoPaneTrackedSplitCoordinator()

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
    public var sampleMetadataStore: SampleMetadataStore? {
        didSet {
            let selected = samplePickerState?.selectedSamples.sorted() ?? []
            let sampleId = selected.count == 1 ? selected.first : nil
            detectionTableView.metadataColumns.update(store: sampleMetadataStore, sampleId: sampleId)
            batchTableView.metadataColumns.update(store: sampleMetadataStore, sampleId: nil)
        }
    }

    public func applySampleMetadata(_ store: SampleMetadataStore?) {
        sampleMetadataStore = store
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

    /// Invoked when the user requests read extraction. The App host wires this to
    /// presentClassifierExtractionDialog; kept as a callback so this VC has no
    /// dependency on the App-internal extraction/operation pipeline.
    public var onExtractReadsRequested: (@MainActor (ClassifierTool, URL, [ClassifierRowSelector], String) -> Void)?

    /// The BLAST results drawer embedded at the bottom of the view.
    private var blastDrawerContainer: BlastResultsDrawerContainerView?
    private var blastDrawerHeightConstraint: NSLayoutConstraint?
    private var isBlastDrawerOpen = false

    // MARK: - Batch Mode

    /// Whether this view controller is displaying an aggregated batch result.
    var isBatchMode: Bool = false

    /// Whether the last `configureFromDatabase` call loaded data from a pre-built aggregated manifest
    /// rather than parsing per-sample files. Used to populate the Inspector manifest status.
    public private(set) var didLoadFromManifestCache: Bool = false

    /// All flat rows loaded from each sample's EsViritu detection file in batch mode.
    var allBatchRows: [BatchEsVirituRow] = []

    /// Flat table used in batch mode (placed inside the right pane of `splitView`).
    private(set) var batchTableView = BatchEsVirituTableView()

    /// The URL of the batch result directory (set during `configureFromDatabase`).
    var batchURL: URL?

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
        container.setAccessibilityElement(true)
        container.setAccessibilityIdentifier("esviritu-result-view")
        container.setAccessibilityLabel("EsViritu Result View")
        view = container

        setupSummaryBar()
        setupSplitView()
        setupBatchTableView()
        setupAlignmentEvidenceViewer()
        setupActionBar()
        layoutSubviews()
        wireCallbacks()
        applyLayoutPreference()
        contentTypographyObservation = ContentTypographyViewObservation(
            applicator: contentTypographyApplicator,
            rootProvider: { [weak self] in self?.multiSelectionPlaceholder }
        )

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleBatchSampleSelectionChanged), name: .metagenomicsSampleSelectionChanged, object: nil
        )
    }

    // MARK: - Detached alignment evidence

    /// Supplied by LungfishApp at composition time; the default is leaf-safe.
    public var classifierAlignmentViewerFactory: @MainActor () -> any ClassifierAlignmentViewerProviding = {
        UnavailableClassifierAlignmentViewer()
    }

    /// Resolves the reference FASTA record backing an EsViritu detection.
    ///
    /// EsViritu aligns against the pangenome FASTA of a managed EsViritu database,
    /// which lives outside the result directory and whose location only
    /// `LungfishApp` knows how to resolve. The leaf therefore asks through this
    /// callback, supplied at composition time, rather than reaching for the
    /// database itself. A `nil` callback, or a `nil` return, leaves the evidence
    /// request without a reference so the viewport honestly reports one is absent.
    public var onResolveReferenceCandidate: ((_ sampleID: String, _ contig: String, _ length: Int) -> ClassifierAlignmentReferenceCandidate?)?

    private var alignmentEvidenceViewer: (any ClassifierAlignmentViewerProviding)?

    /// The assembly accession currently displayed in the mini BAM viewer.
    private var currentBAMAssemblyAccession: String?
    /// The contig accession currently displayed in the mini BAM viewer.
    private var currentBAMContigAccession: String?
    private var currentBAMSampleID: String?

    private func setupAlignmentEvidenceViewer() {
        let viewer = classifierAlignmentViewerFactory()
        addChild(viewer.viewController)
        alignmentEvidenceViewer = viewer
        detailPane.alignmentEvidenceView = viewer.viewController.view
        detailPane.onDisplayAlignmentEvidence = { [weak self] contig, length in
            self?.displayEsVirituAlignmentEvidence(contig: contig, length: length)
        }
    }

    private func displayEsVirituAlignmentEvidence(contig: String, length: Int) {
        guard let viewer = alignmentEvidenceViewer,
              !contig.isEmpty, length > 0,
              let bamURL, let indexURL = bamIndexURL,
              let sampleID = currentBAMSampleID else {
            alignmentEvidenceViewer?.clear()
            return
        }
        let kind: ClassifierAlignmentIndex.Kind = switch indexURL.pathExtension.lowercased() {
        case "csi": .csi
        case "crai": .crai
        default: .bai
        }
        do {
            let resultURL = batchURL ?? bamURL.deletingLastPathComponent()
            let request = try ClassifierAlignmentEvidenceRequest(
                workflow: .esViritu,
                resultIdentity: .init(stableID: resultURL.standardizedFileURL.path, finalResultURL: resultURL, provenanceID: "esviritu:\(resultURL.lastPathComponent)"),
                bamURL: bamURL,
                index: .init(url: indexURL, kind: kind),
                sample: .init(canonicalID: sampleID),
                contig: .init(name: contig, expectedLength: length),
                referenceCandidate: onResolveReferenceCandidate?(sampleID, contig, length),
                presentation: .init(workflowLabel: "EsViritu", resultLabel: resultURL.lastPathComponent, sampleLabel: sampleID, contigLabel: contig)
            )
            viewer.display(request)
        } catch {
            viewer.clear()
        }
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        guard splitCoordinator.needsInitialSplitValidation else { return }
        scheduleInitialSplitValidationIfNeeded()
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
        batchTableView.resultIdentity = resultURL.standardizedFileURL.path
        detectionTableView.resultIdentity = resultURL.standardizedFileURL.path

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
        batchTableView.configure(rows: allBatchRows)

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
            self.clearCurrentAlignmentEvidence()
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
            let totalUniqueReads = group.reduce(0) {
                $0 + BatchEsVirituRow.normalizedUniqueReads(stored: $1.uniqueReads, readCount: $1.readCount)
            }
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

            // Build a ViralAssembly for the detail pane from the DB rows, as the
            // export does. Without this the detail pane stays blank when a row
            // is clicked (``batchAssemblyLookup`` lookup misses and
            // ``showAssemblyDetail`` is never called).
            batchAssemblyLookup[key] = EsVirituDetectionExport.assembly(from: group)
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
    /// fully-populated rows from the manifest cache. Dispatches the manifest
    /// read/mutate/write to a background task (R3-R3ML-5): for a batch of N samples
    /// needing computation, this decode+encode+write of the *entire* aggregated manifest
    /// (all samples x all assemblies) previously happened synchronously on the main actor
    /// once per completed sample, each call blocking the UI for the full manifest I/O
    /// duration. The main actor is only touched to read the current `batchURL`/
    /// `allBatchRows` snapshot up front; the actual file I/O runs off-main.
    @discardableResult
    private func updateEsVirituBatchAggregatedManifestUniqueReads() -> Task<Void, Never>? {
        guard let batchURL else { return nil }

        let byAssemblyAndSample = Dictionary(
            uniqueKeysWithValues: allBatchRows.map { ("\($0.sample)\t\($0.assembly)", $0.uniqueReads) }
        )

        // R3-R3ML-5 fixup (round-3 review): route every write for this
        // batchURL through EsVirituBatchManifestMutationSerializer instead
        // of a bare Task.detached, so per-sample completions serialize their
        // load-modify-save of the shared manifest instead of racing.
        return Task.detached(priority: .utility) {
            await EsVirituBatchManifestMutationSerializer.shared.run(batchURL: batchURL) {
                Self.writeUpdatedBatchAggregatedManifestUniqueReads(
                    batchURL: batchURL,
                    byAssemblyAndSample: byAssemblyAndSample
                )
            }
        }
    }

    /// Pure merge step: applies newly computed unique-read counts onto a loaded
    /// `EsVirituBatchAggregatedManifest`'s cached rows, keyed by "sample\tassembly".
    /// Rows with no matching entry in `byAssemblyAndSample` are left unchanged.
    nonisolated static func applyingUniqueReads(
        byAssemblyAndSample: [String: Int],
        to manifest: EsVirituBatchAggregatedManifest
    ) -> EsVirituBatchAggregatedManifest {
        var updated = manifest
        for i in updated.cachedRows.indices {
            let row = updated.cachedRows[i]
            let key = "\(row.sample)\t\(row.assembly)"
            if let uniqueReads = byAssemblyAndSample[key] {
                updated.cachedRows[i] = EsVirituBatchAggregatedManifest.CachedRow(
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
        return updated
    }

    /// Off-main-actor load/merge/save of the batch aggregated manifest. Safe to call from a
    /// detached background task: touches only the filesystem and `Sendable` values, no
    /// `self`/UI state.
    nonisolated private static func writeUpdatedBatchAggregatedManifestUniqueReads(
        batchURL: URL,
        byAssemblyAndSample: [String: Int]
    ) {
        guard let aggregated = MetagenomicsBatchResultStore.loadEsVirituBatchAggregatedManifest(from: batchURL) else {
            return
        }
        let updated = applyingUniqueReads(byAssemblyAndSample: byAssemblyAndSample, to: aggregated)
        do {
            try MetagenomicsBatchResultStore.saveEsVirituBatchAggregatedManifest(updated, to: batchURL)
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
        let assemblies = EsVirituDetectionExport.assemblies(in: batchAssemblyLookup, selectedSamples: selectedSet)

        let detections = assemblies.flatMap(\.contigs)
        let familyCount = Set(detections.compactMap(\.family)).count
        let speciesCount = Set(detections.compactMap(\.species)).count
        let totalFilteredReads = detections.map(\.filteredReadsInSample).max() ?? 0

        detectionTableView.resetCoverageWindows()
        var allCoverageWindows: [ViralCoverageWindow] = []
        if let db = esVirituDatabase {
            for contig in detections {
                if let windows = try? db.fetchCoverageWindows(sample: contig.sampleId, accession: contig.accession), !windows.isEmpty {
                    let mappedWindows = windows.map {
                        ViralCoverageWindow(
                            accession: $0.accession,
                            windowIndex: $0.windowIndex,
                            windowStart: $0.windowStart,
                            windowEnd: $0.windowEnd,
                            averageCoverage: $0.averageCoverage
                        )
                    }
                    detectionTableView.setCoverageWindows(
                        mappedWindows,
                        sampleId: contig.sampleId,
                        accession: contig.accession
                    )
                    allCoverageWindows.append(contentsOf: mappedWindows)
                }
            }
        }

        let result = EsVirituResult(
            sampleId: EsVirituDetectionExport.resultSampleId(selectedSamples: sampleIds),
            detections: detections,
            assemblies: assemblies,
            taxProfile: [],
            coverageWindows: allCoverageWindows,
            totalFilteredReads: totalFilteredReads,
            detectedFamilyCount: familyCount,
            detectedSpeciesCount: speciesCount,
            runtime: nil,
            toolVersion: nil
        )

        let uniqueReadMaps = Self.buildBatchUniqueReadMaps(
            rows: allBatchRows,
            selectedSamples: selectedSet
        )

        esVirituResult = result
        detectionTableView.resultIdentity = batchURL?.standardizedFileURL.path
        detectionTableView.result = result
        detectionTableView.uniqueReadCountsByAssembly = uniqueReadMaps.byAssembly
        detectionTableView.uniqueReadCountsBySampleAssembly = uniqueReadMaps.bySampleAssembly
        detectionTableView.uniqueReadCountsBySampleContig = uniqueReadMaps.bySampleContig
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

    struct BatchUniqueReadMaps {
        let byAssembly: [String: Int]
        let bySampleAssembly: [String: Int]
        let bySampleContig: [String: Int]
    }

    static func buildBatchUniqueReadMaps(
        rows: [BatchEsVirituRow],
        selectedSamples: Set<String>
    ) -> BatchUniqueReadMaps {
        var byAssembly: [String: Int] = [:]
        var bySampleAssembly: [String: Int] = [:]

        for row in rows where selectedSamples.contains(row.sample) {
            let uniqueReads = BatchEsVirituRow.normalizedUniqueReads(
                stored: row.uniqueReads,
                readCount: row.readCount
            )
            byAssembly[row.assembly] = uniqueReads
            bySampleAssembly["\(row.sample)\t\(row.assembly)"] = uniqueReads
        }

        return BatchUniqueReadMaps(
            byAssembly: byAssembly,
            bySampleAssembly: bySampleAssembly,
            bySampleContig: [:]
        )
    }

    @objc private func handleBatchSampleSelectionChanged(_ notification: Notification) {
        guard ScopedEventFilter.accept(notification, for: ScopedEventFilter.hostingWindowScope(of: viewIfLoaded)) else { return }
        guard isBatchMode else { return }
        applyBatchSampleFilter()
    }

    // MARK: - Batch Unique Read Computation

    // MARK: - Unique Read Helpers

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
        splitView.setAccessibilityIdentifier("esviritu-result-split-view")
        splitView.setAccessibilityLabel("EsViritu Result Split View")
        splitView.isVertical = MetagenomicsPanelLayout.current() != .stacked
        splitView.dividerStyle = .thin
        splitView.delegate = self
        detailContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rightPaneContainer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        rightPaneContainer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailContainer.setAccessibilityElement(true)
        detailContainer.setAccessibilityIdentifier("esviritu-detail-shell")
        detailContainer.setAccessibilityLabel("EsViritu Detail Shell")
        rightPaneContainer.setAccessibilityElement(true)
        rightPaneContainer.setAccessibilityIdentifier("esviritu-detection-shell")
        rightPaneContainer.setAccessibilityLabel("EsViritu Detection Shell")

        // Detail pane (detail-leading mode) — coverage plots, BAM info, overview
        detailPane.autoresizingMask = [.width, .height]
        detailPane.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detailPane.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailContainer.addSubview(detailPane)
        detailContainer.fillSubview = detailPane

        // Multi-selection placeholder overlay on the detail container
        detailContainer.addSubview(multiSelectionPlaceholder)
        NSLayoutConstraint.activate([
            multiSelectionPlaceholder.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            multiSelectionPlaceholder.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
            multiSelectionPlaceholder.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            multiSelectionPlaceholder.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
        ])

        // Table container (list-leading / stacked mode) — stored as instance
        // property so setupBatchTableView() can add batchTableView inside it later.
        detectionTableView.autoresizingMask = [.width, .height]
        detectionTableView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        detectionTableView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        rightPaneContainer.addSubview(detectionTableView)
        rightPaneContainer.fillSubview = detectionTableView

        if MetagenomicsPanelLayout.current() == .detailLeading {
            splitView.addArrangedSubview(detailContainer)
            splitView.addArrangedSubview(rightPaneContainer)
        } else {
            splitView.addArrangedSubview(rightPaneContainer)
            splitView.addArrangedSubview(detailContainer)
        }

        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
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
                self.clearCurrentAlignmentEvidence()
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

        reserveTheSpaceOfTheDeletedRecomputeButton()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLayoutSwapRequested),
            name: .metagenomicsLayoutSwapRequested,
            object: nil
        )
    }

    /// The hidden "Recompute Unique Reads" button this bar held (170 pt plus a 6 pt gap, after Extract FASTQ) set
    /// where the info text starts and how narrow this view can get. Deleting it (13.53) moved both, so this
    /// keeps the 176 pt. The bar chains the info text to its last button with one leading constraint, found
    /// here by its first item. If the bar stops using one, nothing moves.
    private func reserveTheSpaceOfTheDeletedRecomputeButton() {
        let infoTextLeading = actionBar.constraints.first {
            $0.firstItem === actionBar.infoLabel && $0.firstAttribute == .leading
        }
        infoTextLeading?.constant += 176
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

    // MARK: - Classifier extraction wiring

    /// Builds per-sample selectors from the current detection-table selection.
    private func buildEsVirituSelectors() -> [ClassifierRowSelector] {
        let pairs = detectionTableView.selectedSampleAccessions()
        guard !pairs.isEmpty else { return [] }

        guard isBatchMode else {
            return [ClassifierRowSelector(sampleId: nil, accessions: pairs.map(\.accession), taxIds: [])]
        }

        var bySample: [String: [String]] = [:]
        for pair in pairs {
            bySample[pair.sampleId, default: []].append(pair.accession)
        }
        return bySample
            .map { ClassifierRowSelector(sampleId: $0.key, accessions: $0.value, taxIds: []) }
            .sorted { ($0.sampleId ?? "") < ($1.sampleId ?? "") }
    }

    /// Presents the unified classifier extraction dialog for the current selection.
    private func presentUnifiedExtractionDialog() {
        guard let resultPath = esVirituDatabase?.databaseURL ?? esVirituConfig?.outputDirectory else { return }
        let firstAccession = detectionTableView.selectedAssemblyAccessions().first ?? "extract"
        onExtractReadsRequested?(.esviritu, resultPath, buildEsVirituSelectors(), "esviritu_\(firstAccession)")
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
        case .detailLeading, .listLeading, .stacked:
            return (250, 250)
        }
    }

    private func applyInitialSplitPositionIfNeeded() {
        splitCoordinator.applyInitialSplitPositionIfNeeded(
            to: splitView,
            defaultLeadingFraction: defaultLeadingFraction(for: MetagenomicsPanelLayout.current()),
            minimumExtents: minimumExtents(for: MetagenomicsPanelLayout.current())
        )
    }

    private func resetInitialSplitPositionIfNeeded() {
        splitCoordinator.resetInitialSplitPositionIfNeeded(
            in: splitView,
            minimumExtents: minimumExtents(for: MetagenomicsPanelLayout.current())
        )
    }

    private func hasValidInitialSplitPosition() -> Bool {
        splitCoordinator.hasValidInitialSplitPosition(
            in: splitView,
            minimumExtents: minimumExtents(for: MetagenomicsPanelLayout.current())
        )
    }

    private func scheduleInitialSplitValidationIfNeeded() {
        splitCoordinator.scheduleInitialSplitValidationIfNeeded(
            ownerView: view,
            splitView: splitView,
            minimumExtents: { [weak self] in
                self?.minimumExtents(for: MetagenomicsPanelLayout.current()) ?? (250, 250)
            },
            defaultLeadingFraction: { [weak self] in
                self?.defaultLeadingFraction(for: MetagenomicsPanelLayout.current()) ?? 0.4
            }
        )
    }

    /// Swaps the split view pane order based on the persisted layout preference.
    private func applyLayoutPreference() {
        let layout = MetagenomicsPanelLayout.current()
        guard splitView.arrangedSubviews.count == 2 else { return }

        let desiredIsVertical = layout != .stacked
        let desiredFirstPane: NSView = layout == .detailLeading ? detailContainer : rightPaneContainer
        let desiredSecondPane: NSView = layout == .detailLeading ? rightPaneContainer : detailContainer
        splitCoordinator.applyLayoutPreference(
            to: splitView,
            desiredIsVertical: desiredIsVertical,
            desiredFirstPane: desiredFirstPane,
            desiredSecondPane: desiredSecondPane,
            defaultLeadingFraction: defaultLeadingFraction(for: layout),
            minimumExtents: minimumExtents(for: layout),
            isViewInWindow: view.window != nil
        )
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
            if let contigWindows = detectionTableView.coverageWindows(
                sampleId: contig.sampleId,
                accession: contig.accession
            ) {
                windows[contig.accession] = contigWindows
            }
        }
        return windows
    }

    private func showAssemblyDetail(_ assembly: ViralAssembly, focusedContigAccession: String? = nil) {
        currentBAMAssemblyAccession = assembly.assembly

        let selectedContig = assembly.contigs.first { $0.accession == focusedContigAccession } ?? assembly.contigs.first
        currentBAMContigAccession = selectedContig?.accession
        currentBAMSampleID = selectedContig?.sampleId

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
        currentBAMSampleID = nil
        alignmentEvidenceViewer?.clear()
        guard let result = esVirituResult else { return }
        detailPane.configureOverview(
            result: result,
            coverageWindows: detectionTableView.coverageWindowsForDisplay(),
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
    public func showBlastResults(_ result: BlastVerificationResult, recordURL: URL?) {
        let drawer = ensureBlastDrawer()
        drawer.showResults(result, recordURL: recordURL)
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
        if let blastDrawerContainer {
            return blastDrawerContainer.blastResultsTab
        }

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

        // Re-pin main content above the drawer so opening it resizes the
        // top panels instead of drawing over them.
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
            self.view.layoutSubtreeIfNeeded()
        }
        isBlastDrawerOpen = true
    }

    // MARK: - NSSplitViewDelegate

    public func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        return MetagenomicsPaneSizing.clampedDividerPosition(
            proposed: proposedPosition,
            containerExtent: extent,
            minimumLeadingExtent: 250,
            minimumTrailingExtent: 250
        )
    }

    public func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard let trackedSplitView = splitView as? TrackedDividerSplitView,
              trackedSplitView === self.splitView else { return }
        splitCoordinator.resizeSubviewsWithOldSize(
            trackedSplitView,
            oldSize: oldSize,
            defaultLeadingFraction: defaultLeadingFraction(for: MetagenomicsPanelLayout.current()),
            minimumExtents: minimumExtents(for: MetagenomicsPanelLayout.current())
        )
    }

    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.object as? NSSplitView === splitView else { return }
        splitCoordinator.splitViewDidResizeSubviews(
            splitView,
            minimumExtents: minimumExtents(for: MetagenomicsPanelLayout.current())
        )
    }

    // MARK: - Multi-Selection Helpers

    private func showMultiSelectionPlaceholder(count: Int) {
        clearCurrentAlignmentEvidence()
        if let stack = multiSelectionPlaceholder.subviews.first as? NSStackView,
           let primary = stack.arrangedSubviews.first as? NSTextField {
            primary.stringValue = "\(count) items selected"
        }
        detailPane.isHidden = true
        multiSelectionPlaceholder.isHidden = false
        contentTypographyObservation?.refresh()
    }

    private func clearCurrentAlignmentEvidence() {
        currentBAMAssemblyAccession = nil
        currentBAMContigAccession = nil
        currentBAMSampleID = nil
        alignmentEvidenceViewer?.clear()
    }

    /// Clears detached evidence before this leaf is detached from its host.
    public func clearClassifierAlignmentEvidence() {
        clearCurrentAlignmentEvidence()
    }

    isolated deinit {
        clearCurrentAlignmentEvidence()
        NotificationCenter.default.removeObserver(self)
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
        exportDelimited(format: .csv, fileTypeName: "CSV")
    }

    @objc private func exportTSVAction(_ sender: Any) {
        exportDelimited(format: .tsv, fileTypeName: "TSV")
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

    /// Exports the detection table as a delimited file via NSSavePanel, by running `esviritu export detections`
    /// behind an Operations row (`beginEsVirituDetectionsExportOperation`).
    ///
    /// Uses `beginSheetModal` (not `runModal`) per macOS 26 rules.
    private func exportDelimited(format: ViewerExportDelimitedFormat, fileTypeName: String) {
        guard let result = esVirituResult, let window = view.window else {
            logger.warning("Cannot export: no result or window")
            return
        }

        let baseName = result.sampleId
        let panel = MetagenomicsFilePanelFactory.delimitedExportPanel(
            title: "Export Detections as \(fileTypeName)",
            suggestedName: "\(baseName)_detections.\(format.rawValue)"
        )

        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            guard let invocation = self.detectionsExportInvocation(result: result, format: format, outputURL: url) else {
                logger.warning("Cannot export: the result has no folder")
                return
            }
            Self.beginEsVirituDetectionsExportOperation(invocation: invocation) { [weak self] failure in
                logger.error("Export failed: \(failure.message, privacy: .public)")
                ResultExportCoordinator.reportFailure(
                    fileName: url.lastPathComponent,
                    error: failure,
                    window: window,
                    presenter: self?.exportFailurePresenter ?? DefaultExportFailurePresenter()
                )
            }
        }
    }

    /// The `esviritu export detections` invocation for the view's state, or nil when the result has no folder,
    /// which the app's database route always sets (BIO ruling on 12.31 G3, G3-2). In batch mode it names the
    /// picker's samples as the database records them (BIO ruling on 12.31 G1, G1-2).
    func detectionsExportInvocation(
        result: LungfishIO.EsVirituResult,
        format: ViewerExportDelimitedFormat,
        outputURL: URL
    ) -> ViewerExportInvocation? {
        guard let batchURL else { return nil }
        return EsVirituDetectionExport.invocation(
            resultURL: batchURL,
            samples: exportSelectedSampleIds(for: result),
            metadataColumns: detectionTableView.metadataColumns.exportHeaders,
            format: format,
            outputURL: outputURL,
            force: FileManager.default.fileExists(atPath: outputURL.path)
        )
    }

    private func exportSelectedSampleIds(for result: LungfishIO.EsVirituResult) -> [String] {
        if isBatchMode, let samplePickerState {
            return samplePickerState.selectedSamples.sorted()
        }
        let detectionSamples = Set(result.detections.map(\.sampleId))
        if !detectionSamples.isEmpty {
            return detectionSamples.sorted()
        }
        return result.sampleId == "batch" ? [] : [result.sampleId]
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

    /// Returns the detail pane container for testing.
    var testDetailContainer: NSView { detailContainer }

    /// Returns the detection table view for testing.
    var testDetectionTableView: ViralDetectionTableView { detectionTableView }

    /// Builds the current extraction selectors for testing.
    func testBuildEsVirituSelectors() -> [ClassifierRowSelector] {
        buildEsVirituSelectors()
    }

    /// Returns the right pane container for testing.
    var testRightPaneContainer: NSView { rightPaneContainer }

    /// Returns the action bar for testing.
    var testActionBar: ClassifierActionBar { actionBar }

    /// Returns the split view for testing.
    var testSplitView: NSSplitView { splitView }

    /// Returns the last requested divider position for testing.
    var testRequestedDividerPosition: CGFloat? { splitView.requestedDividerPosition(at: 0) }

    /// Returns whether initial split validation is still pending for testing.
    var testNeedsInitialSplitValidation: Bool { splitCoordinator.needsInitialSplitValidation }

    /// Returns the shared BLAST drawer container for testing.
    var testBlastDrawerContainer: BlastResultsDrawerContainerView? { blastDrawerContainer }

    /// Returns the current EsViritu result for testing.
    var testResult: LungfishIO.EsVirituResult? { esVirituResult }

    /// Triggers the same batch-aggregated-manifest write path a real
    /// per-sample completion uses (`allBatchRows` snapshot -> serialized
    /// load-modify-save), returning the underlying `Task` so a test can await
    /// completion before asserting the resulting file on disk. Exists so
    /// concurrent-writer races (R3-R3ML-5 / round-3 review fix) can be
    /// reproduced deterministically without standing up the full batch
    /// unique-read computation pipeline.
    @discardableResult
    func testTriggerBatchAggregatedManifestWrite() -> Task<Void, Never>? {
        updateEsVirituBatchAggregatedManifestUniqueReads()
    }

    /// Returns the batch table view for testing.
    var testBatchTableView: BatchEsVirituTableView { batchTableView }

    /// Returns the assembly currently targeted by mini-BAM updates.
    var testCurrentBAMAssemblyAccession: String? { currentBAMAssemblyAccession }

    /// Returns the contig currently targeted by mini-BAM updates.
    var testCurrentBAMContigAccession: String? { currentBAMContigAccession }

    /// Returns the sample currently targeted by detached-alignment updates.
    var testCurrentBAMSampleID: String? { currentBAMSampleID }

    #if DEBUG
    struct TestingPlaceholderTypographyMetrics: Equatable {
        let primaryPointSize: CGFloat
        let secondaryPointSize: CGFloat
        let fieldsAreContained: Bool
    }

    func testingShowMultiSelectionPlaceholder(count: Int) {
        showMultiSelectionPlaceholder(count: count)
        view.layoutSubtreeIfNeeded()
        multiSelectionPlaceholder.layoutSubtreeIfNeeded()
    }

    var testingPlaceholderTypographyMetrics: TestingPlaceholderTypographyMetrics {
        let stack = multiSelectionPlaceholder.subviews.first as? NSStackView
        let fields = stack?.arrangedSubviews.compactMap { $0 as? NSTextField } ?? []
        return TestingPlaceholderTypographyMetrics(
            primaryPointSize: fields.first?.font?.pointSize ?? 0,
            secondaryPointSize: fields.dropFirst().first?.font?.pointSize ?? 0,
            fieldsAreContained: fields.allSatisfy { field in
                guard let parent = field.superview else { return false }
                return field.frame.width > 0
                    && field.frame.height > 0
                    && parent.bounds.insetBy(dx: -2, dy: -2).contains(field.frame)
            }
        )
    }

    var testingPlaceholderFrameDescription: String {
        let stack = multiSelectionPlaceholder.subviews.first as? NSStackView
        return (stack?.arrangedSubviews.compactMap { $0 as? NSTextField } ?? []).map {
            "\($0.stringValue): frame=\(NSStringFromRect($0.frame)) parent=\(NSStringFromRect($0.superview?.bounds ?? .zero))"
        }.joined(separator: " | ")
    }
    #endif
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
        cardsDidChange()
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
        cardsDidChange()
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
                provenanceRow("Paired-End", value: config.readFormat.pairedEndLabel)
                provenanceRow("Quality Filter", value: config.qualityFilter ? "Enabled" : "Disabled")
                // "Min Read Length" intentionally removed --
                // EsViritu has no such option, so this value was never
                // applied and echoing it here contradicted the actual
                // computation.
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
