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
    private var bamURL: URL?
    /// Path to the BAM index (.csi/.bai), if available.
    private var bamIndexURL: URL?

    /// Background task computing unique reads for all assemblies.
    private var uniqueReadComputationTask: Task<Void, Never>?

    /// Sidecar filename for persisted unique read counts.
    private static let uniqueReadsSidecar = "esviritu-unique-reads.json"

    // MARK: - Child Views

    private let summaryBar = EsVirituSummaryBar()
    let splitView = NSSplitView()
    private let detailPane = EsVirituDetailPane()
    private let detectionTableView = ViralDetectionTableView()
    let actionBar = ClassifierActionBar()
    private var splitViewBottomConstraint: NSLayoutConstraint?

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

    /// Called when the user requests read extraction for a detection.
    ///
    /// - Parameter detection: The viral detection whose reads to extract.
    public var onExtractReads: ((ViralDetection) -> Void)?

    /// Called when the user requests read extraction for an assembly.
    ///
    /// - Parameter assembly: The viral assembly whose reads to extract.
    public var onExtractAssemblyReads: ((ViralAssembly) -> Void)?

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

    // MARK: - Lifecycle

    public override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        view = container

        setupSummaryBar()
        setupSplitView()
        setupMiniBAMViewer()
        setupActionBar()
        layoutSubviews()
        wireCallbacks()
        applyLayoutPreference()
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

    // MARK: - Public API

    /// Configures the view with an EsViritu result and optional config.
    ///
    /// Populates the summary bar, detail pane, detection table, and action bar.
    ///
    /// - Parameters:
    ///   - result: The parsed EsViritu result.
    ///   - config: The config used for this run (for provenance and re-run).
    public func configure(result: LungfishIO.EsVirituResult, config: EsVirituConfig? = nil) {
        esVirituResult = result
        esVirituConfig = config

        // Build coverage lookup
        var coverageLookup: [String: [ViralCoverageWindow]] = [:]
        for window in result.coverageWindows {
            coverageLookup[window.accession, default: []].append(window)
        }

        // Reset BAM-derived state for reconfiguration.
        bamURL = nil
        bamIndexURL = nil

        // Locate the final BAM file (from --keep True)
        if let outputDir = config?.outputDirectory {
            let tempDir = outputDir.appendingPathComponent("\(config?.sampleName ?? "sample")_temp")
            let bamName = "\(config?.sampleName ?? "sample").third.filt.sorted.bam"
            let candidateBAM = tempDir.appendingPathComponent(bamName)
            if FileManager.default.fileExists(atPath: candidateBAM.path) {
                bamURL = candidateBAM
                bamIndexURL = resolveBamIndex(for: candidateBAM)
                logger.info("Found EsViritu BAM at \(candidateBAM.lastPathComponent)")
            }
        }

        // Update summary bar
        summaryBar.update(result: result)

        // Configure detail pane with overview
        detailPane.configureOverview(
            result: result,
            coverageWindows: coverageLookup,
            bamURL: bamURL
        )

        // Clear cached unique reads from previous sample and load persisted values
        uniqueReadComputationTask?.cancel()
        detectionTableView.uniqueReadCountsByAssembly = [:]
        detectionTableView.uniqueReadCountsByContig = [:]
        if let outputDir = config?.outputDirectory {
            loadPersistedUniqueReads(from: outputDir)
        }

        // Configure table
        detectionTableView.coverageWindowsByAccession = coverageLookup
        detectionTableView.result = result

        // Update action bar info text
        actionBar.updateInfoText("Select a virus to view details")

        let hasBam = self.bamURL != nil
        let hasBamIndex = self.bamIndexURL != nil
        logger.info("Configured with \(result.detections.count) detections, \(result.assemblies.count) assemblies, \(result.detectedFamilyCount) families, BAM=\(hasBam), index=\(hasBamIndex)")

        // Compute unique reads for all assemblies in the background
        if let bamURL, let bamIndexURL {
            scheduleUniqueReadComputation(assemblies: result.assemblies, bamURL: bamURL, bamIndexURL: bamIndexURL)
        }

        // Build single-sample picker entry from EsViritu result
        let sampleName = result.sampleId
        sampleEntries = [EsVirituSampleEntry(
            id: sampleName,
            displayName: sampleName,
            detectedVirusCount: result.assemblies.count
        )]
        strippedPrefix = ""
        samplePickerState = ClassifierSamplePickerState(allSamples: Set([sampleName]))
    }

    // MARK: - Background Unique Read Computation

    /// Computes deduplicated read counts for all assemblies in the background.
    ///
    /// Iterates assemblies by descending read count (most important first),
    /// fetches reads from the BAM for each primary contig, deduplicates by
    /// position/strand, and updates the table incrementally.
    private func scheduleUniqueReadComputation(assemblies: [ViralAssembly], bamURL: URL, bamIndexURL: URL) {
        uniqueReadComputationTask?.cancel()

        let sorted = assemblies.sorted { $0.totalReads > $1.totalReads }

        uniqueReadComputationTask = Task { [weak self] in
            let provider = AlignmentDataProvider(
                alignmentPath: bamURL.path,
                indexPath: bamIndexURL.path
            )

            for assembly in sorted {
                if Task.isCancelled { return }
                // Skip if already computed (e.g., from a previous user click)
                if self?.detectionTableView.uniqueReadCountsByAssembly[assembly.assembly] != nil {
                    continue
                }

                let isMultiSegment = assembly.contigs.count > 1
                var fetchedAny = false

                for contig in assembly.contigs {
                    if Task.isCancelled { return }
                    guard contig.length > 0 else { continue }

                    let reads = (try? await provider.fetchReads(
                        chromosome: contig.accession,
                        start: 0,
                        end: contig.length,
                        excludeFlags: 0x904,
                        maxReads: 5000
                    )) ?? []

                    if reads.isEmpty { continue }
                    fetchedAny = true
                    let contigUnique = min(contig.readCount, Self.deduplicatedReadCount(from: reads))
                    let assemblyAccession = assembly.assembly

                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.detectionTableView.setUniqueReadCount(
                                contigUnique,
                                forContig: contig.accession,
                                inAssembly: assemblyAccession
                            )
                        }
                    }
                }

                // For single-contig assemblies that had no reads, ensure assembly shows 0
                if !fetchedAny && !isMultiSegment {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.detectionTableView.setUniqueReadCount(0, forAssembly: assembly.assembly)
                        }
                    }
                }
            }

            // Persist computed unique reads so they load instantly on re-open
            if !Task.isCancelled {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.persistUniqueReads()
                    }
                }
            }
        }
    }

    /// Counts unique reads by deduplicating on position-strand fingerprint.
    private static func deduplicatedReadCount(from reads: [AlignedRead]) -> Int {
        AlignedRead.deduplicatedReadCount(from: reads)
    }

    /// Resolves the BAM index adjacent to the BAM file.
    private func resolveBamIndex(for bamURL: URL) -> URL? {
        let fm = FileManager.default
        let csiURL = URL(fileURLWithPath: bamURL.path + ".csi")
        if fm.fileExists(atPath: csiURL.path) { return csiURL }

        let baiURL = URL(fileURLWithPath: bamURL.path + ".bai")
        if fm.fileExists(atPath: baiURL.path) { return baiURL }

        logger.warning("No BAM index found for \(bamURL.lastPathComponent, privacy: .public)")
        return nil
    }

    // MARK: - Unique Read Persistence

    /// Sidecar data structure for persisted unique read counts.
    private struct UniqueReadCache: Codable {
        var byAssembly: [String: Int]
        var byContig: [String: Int]
    }

    /// Loads persisted unique read counts from the output directory sidecar.
    private func loadPersistedUniqueReads(from outputDir: URL) {
        let sidecarURL = outputDir.appendingPathComponent(Self.uniqueReadsSidecar)
        guard let data = try? Data(contentsOf: sidecarURL),
              let cache = try? JSONDecoder().decode(UniqueReadCache.self, from: data) else {
            return
        }
        detectionTableView.uniqueReadCountsByAssembly = cache.byAssembly
        detectionTableView.uniqueReadCountsByContig = cache.byContig
        logger.info("Loaded persisted unique reads: \(cache.byAssembly.count) assemblies, \(cache.byContig.count) contigs")
    }

    /// Persists current unique read counts to the output directory sidecar.
    private func persistUniqueReads() {
        guard let outputDir = esVirituConfig?.outputDirectory else { return }
        let cache = UniqueReadCache(
            byAssembly: detectionTableView.uniqueReadCountsByAssembly,
            byContig: detectionTableView.uniqueReadCountsByContig
        )
        let sidecarURL = outputDir.appendingPathComponent(Self.uniqueReadsSidecar)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(cache)
            try data.write(to: sidecarURL)
            logger.info("Persisted unique reads for \(cache.byAssembly.count) assemblies")
        } catch {
            logger.warning("Failed to persist unique reads: \(error.localizedDescription, privacy: .public)")
        }
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

        // Table container (right pane)
        let tableContainer = NSView()
        detectionTableView.autoresizingMask = [.width, .height]
        tableContainer.addSubview(detectionTableView)

        splitView.addArrangedSubview(detailContainer)
        splitView.addArrangedSubview(tableContainer)

        // Table pane is preferred to resize (detail pane holds width more firmly)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        view.addSubview(splitView)
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

            // Split view (fills remaining space)
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
            if let assembly {
                // Update action bar with selection info
                self.updateActionBarForAssembly(name: assembly.name, readCount: assembly.totalReads)

                self.showAssemblyDetail(assembly)
            } else {
                self.showOverview()
            }
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
            self.updateActionBarForAssembly(name: detection.name, readCount: detection.readCount)

            guard let assembly = self.resolveAssembly(for: detection) else {
                logger.warning("Unable to resolve parent assembly for detection \(detection.accession, privacy: .public)")
                return
            }
            self.showAssemblyDetail(assembly, focusedContigAccession: detection.accession)
        }

        // Table BLAST request -> forward to host with BAM context
        detectionTableView.onBlastRequested = { [weak self] detection, readCount, accessions in
            guard let self else { return }
            self.onBlastVerification?(detection, readCount, accessions, self.bamURL, self.bamIndexURL)
        }

        // Table extract request -> forward to host
        detectionTableView.onExtractReadsRequested = { [weak self] detection in
            self?.onExtractReads?(detection)
        }

        detectionTableView.onExtractAssemblyReadsRequested = { [weak self] assembly in
            self?.onExtractAssemblyReads?(assembly)
        }

        // Action bar BLAST verify (EsViritu triggers BLAST via table context menu,
        // but the action bar button gives quick access to the table's BLAST flow)
        actionBar.onBlastVerify = { [weak self] in
            // EsViritu BLAST is triggered via the table context menu per-detection;
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

        let headers = [
            "Sample ID", "Virus Name", "Accession", "Assembly", "Kingdom", "Phylum",
            "Class", "Order", "Family", "Genus", "Species", "Subspecies",
            "Read Count", "RPKMF", "Coverage", "Identity", "Covered Bases",
            "Nucleotide Diversity", "Assembly Length", "Filtered Reads",
            "Segment", "Length",
        ]
        lines.append(headers.joined(separator: separator))

        for detection in result.detections {
            let row = [
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

    /// Updates the summary bar with data from the result.
    func update(result: LungfishIO.EsVirituResult) {
        totalReads = result.totalFilteredReads
        familyCount = result.detectedFamilyCount
        speciesCount = result.detectedSpeciesCount
        topVirus = result.assemblies
            .max(by: { $0.totalReads < $1.totalReads })?
            .name ?? "\u{2014}"
        needsDisplay = true
    }

    override var cards: [Card] {
        [
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
