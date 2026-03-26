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

/// A full-screen viral detection browser combining a sunburst chart and detection table.
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
/// |  Sunburst Chart  |  Detection Table      |
/// |                  |                       |
/// |    (resizable NSSplitView)               |
/// +------------------------------------------+
/// | Action Bar (36pt)                        |
/// +------------------------------------------+
/// ```
///
/// ## Sunburst
///
/// Reuses ``TaxonomySunburstView`` by constructing a ``TaxonTree`` from the
/// EsViritu taxonomic profile. The hierarchy is:
/// Family -> Genus -> Species, with arc size proportional to RPKMF or read count.
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

    /// Background task computing unique reads for all assemblies.
    private var uniqueReadComputationTask: Task<Void, Never>?

    /// Sidecar filename for persisted unique read counts.
    private static let uniqueReadsSidecar = "esviritu-unique-reads.json"

    // MARK: - Child Views

    private let summaryBar = EsVirituSummaryBar()
    let splitView = NSSplitView()
    private let detailPane = EsVirituDetailPane()
    private let detectionTableView = ViralDetectionTableView()
    let actionBar = EsVirituActionBar()

    // MARK: - Split View State

    /// Whether the initial divider position has been applied.
    private var didSetInitialSplitPosition = false

    // MARK: - Selection Sync

    /// Prevents infinite feedback loops when syncing selection between views.
    private var suppressSelectionSync = false

    // MARK: - Callbacks

    /// Called when the user requests BLAST verification for a detection.
    ///
    /// - Parameter detection: The viral detection to verify.
    public var onBlastVerification: ((ViralDetection) -> Void)?

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
    /// Populates the summary bar, sunburst chart, detection table, and action bar.
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

        // Locate the final BAM file (from --keep True)
        if let outputDir = config?.outputDirectory {
            let tempDir = outputDir.appendingPathComponent("\(config?.sampleName ?? "sample")_temp")
            let bamName = "\(config?.sampleName ?? "sample").third.filt.sorted.bam"
            let candidateBAM = tempDir.appendingPathComponent(bamName)
            if FileManager.default.fileExists(atPath: candidateBAM.path) {
                bamURL = candidateBAM
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

        // Update action bar
        actionBar.configure(
            totalReads: result.totalFilteredReads,
            detectionCount: result.assemblies.count
        )

        let hasBam = self.bamURL != nil
        logger.info("Configured with \(result.detections.count) detections, \(result.assemblies.count) assemblies, \(result.detectedFamilyCount) families, BAM=\(hasBam)")

        // Compute unique reads for all assemblies in the background
        if let bamURL {
            scheduleUniqueReadComputation(assemblies: result.assemblies, bamURL: bamURL)
        }
    }

    // MARK: - Background Unique Read Computation

    /// Computes deduplicated read counts for all assemblies in the background.
    ///
    /// Iterates assemblies by descending read count (most important first),
    /// fetches reads from the BAM for each primary contig, deduplicates by
    /// position/strand, and updates the table incrementally.
    private func scheduleUniqueReadComputation(assemblies: [ViralAssembly], bamURL: URL) {
        uniqueReadComputationTask?.cancel()

        // Find BAM index (CSI or BAI)
        let fm = FileManager.default
        let csiPath = bamURL.path + ".csi"
        let baiPath = bamURL.path + ".bai"
        let indexPath: String
        if fm.fileExists(atPath: csiPath) {
            indexPath = csiPath
        } else if fm.fileExists(atPath: baiPath) {
            indexPath = baiPath
        } else {
            logger.info("No BAM index found for unique read computation; skipping")
            return
        }

        let sorted = assemblies.sorted { $0.totalReads > $1.totalReads }

        uniqueReadComputationTask = Task { [weak self] in
            let provider = AlignmentDataProvider(
                alignmentPath: bamURL.path,
                indexPath: indexPath
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
            splitView.bottomAnchor.constraint(equalTo: actionBar.topAnchor),
        ])
    }

    // MARK: - Callback Wiring

    private func wireCallbacks() {
        // Table selection -> detail pane + action bar update
        detectionTableView.onAssemblySelected = { [weak self] assembly in
            guard let self else { return }
            if let assembly {
                // Track which assembly/contig is in the BAM viewer for unique read updates
                self.currentBAMAssemblyAccession = assembly.assembly
                self.currentBAMContigAccession = assembly.contigs.first?.accession

                // Update action bar with selection info
                self.actionBar.updateSelection(
                    assemblyName: assembly.name,
                    readCount: assembly.totalReads
                )

                // Show coverage detail for the selected virus
                var windows: [String: [ViralCoverageWindow]] = [:]
                for contig in assembly.contigs {
                    if let w = self.detectionTableView.coverageWindowsByAccession[contig.accession] {
                        windows[contig.accession] = w
                    }
                }
                self.detailPane.showVirusDetail(
                    assembly: assembly,
                    coverageWindows: windows,
                    bamURL: self.bamURL
                )
            } else {
                // Nothing selected — show overview
                if let result = self.esVirituResult {
                    self.detailPane.configureOverview(
                        result: result,
                        coverageWindows: self.detectionTableView.coverageWindowsByAccession,
                        bamURL: self.bamURL
                    )
                }
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
            self.actionBar.updateSelection(
                assemblyName: detection.name,
                readCount: detection.readCount
            )
        }

        // Table BLAST request -> forward to host
        detectionTableView.onBlastRequested = { [weak self] detection in
            self?.onBlastVerification?(detection)
        }

        // Table extract request -> forward to host
        detectionTableView.onExtractReadsRequested = { [weak self] detection in
            self?.onExtractReads?(detection)
        }

        detectionTableView.onExtractAssemblyReadsRequested = { [weak self] assembly in
            self?.onExtractAssemblyReads?(assembly)
        }

        // Action bar export
        actionBar.onExport = { [weak self] in
            self?.showExportMenu()
        }

        // Action bar re-run
        actionBar.onReRun = { [weak self] in
            self?.onReRun?()
        }

        // Action bar provenance
        actionBar.onProvenance = { [weak self] sender in
            self?.showProvenancePopover(relativeTo: sender)
        }
    }

    // MARK: - BLAST Results

    /// Shows BLAST verification results in a bottom drawer.
    ///
    /// Creates a ``BlastResultsDrawerTab`` if needed, populates it with the
    /// results, and slides the drawer open with animation.
    public func showBlastResults(_ result: BlastVerificationResult) {
        if blastDrawerView == nil {
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

            blastDrawerView = drawer
            blastDrawerBottomConstraint = bottomConstraint
            view.layoutSubtreeIfNeeded()
        }

        blastDrawerView?.showResults(result)

        // Animate drawer open
        if !isBlastDrawerOpen {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                self.blastDrawerBottomConstraint?.animator().constant = 0
                self.view.layoutSubtreeIfNeeded()
            }
            isBlastDrawerOpen = true
        }

        logger.info("Showing BLAST results: \(result.verifiedCount)/\(result.readResults.count) verified for \(result.taxonName)")
    }

    // MARK: - NSSplitViewDelegate

    /// Enforces minimum widths for sunburst (250px) and table (300px).
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
            "Virus Name", "Accession", "Assembly", "Family", "Genus", "Species",
            "Read Count", "RPKMF", "Coverage", "Identity", "Segment", "Length",
        ]
        lines.append(headers.joined(separator: separator))

        for detection in result.detections {
            let row = [
                escapeField(detection.name, separator: separator),
                detection.accession,
                detection.assembly,
                escapeField(detection.family ?? "", separator: separator),
                escapeField(detection.genus ?? "", separator: separator),
                escapeField(detection.species ?? "", separator: separator),
                "\(detection.readCount)",
                String(format: "%.2f", detection.rpkmf),
                String(format: "%.2f", detection.meanCoverage),
                String(format: "%.2f", detection.avgReadIdentity),
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

    // MARK: - TaxonTree Construction

    /// Builds a ``TaxonTree`` from the EsViritu taxonomic profile for sunburst display.
    ///
    /// Creates a hierarchy: Root -> Family -> Genus -> Species.
    /// Arc sizes are proportional to read count.
    private func buildTaxonTree(from result: LungfishIO.EsVirituResult) -> TaxonTree {
        let root = TaxonNode(
            taxId: 1,
            name: "Viruses",
            rank: .root,
            depth: 0,
            readsDirect: 0,
            readsClade: result.totalFilteredReads,
            fractionClade: 1.0,
            fractionDirect: 0.0,
            parentTaxId: nil
        )

        // Group detections by family -> genus -> species
        var familyMap: [String: (reads: Int, genera: [String: (reads: Int, species: [String: Int])])] = [:]

        for detection in result.detections {
            let family = detection.family ?? "Unknown"
            let genus = detection.genus ?? "Unknown"
            let species = detection.species ?? detection.name

            familyMap[family, default: (reads: 0, genera: [:])].reads += detection.readCount
            familyMap[family, default: (reads: 0, genera: [:])].genera[genus, default: (reads: 0, species: [:])].reads += detection.readCount
            familyMap[family, default: (reads: 0, genera: [:])].genera[genus, default: (reads: 0, species: [:])].species[species, default: 0] += detection.readCount
        }

        let totalReads = max(result.totalFilteredReads, 1)
        var taxIdCounter = 100

        for (familyName, familyData) in familyMap.sorted(by: { $0.value.reads > $1.value.reads }) {
            taxIdCounter += 1
            let familyNode = TaxonNode(
                taxId: taxIdCounter,
                name: familyName,
                rank: .family,
                depth: 1,
                readsDirect: 0,
                readsClade: familyData.reads,
                fractionClade: Double(familyData.reads) / Double(totalReads),
                fractionDirect: 0.0,
                parentTaxId: 1
            )

            root.addChild(familyNode)

            for (genusName, genusData) in familyData.genera.sorted(by: { $0.value.reads > $1.value.reads }) {
                taxIdCounter += 1
                let genusNode = TaxonNode(
                    taxId: taxIdCounter,
                    name: genusName,
                    rank: .genus,
                    depth: 2,
                    readsDirect: 0,
                    readsClade: genusData.reads,
                    fractionClade: Double(genusData.reads) / Double(totalReads),
                    fractionDirect: 0.0,
                    parentTaxId: familyNode.taxId
                )

                familyNode.addChild(genusNode)

                for (speciesName, speciesReads) in genusData.species.sorted(by: { $0.value > $1.value }) {
                    taxIdCounter += 1
                    let speciesNode = TaxonNode(
                        taxId: taxIdCounter,
                        name: speciesName,
                        rank: .species,
                        depth: 3,
                        readsDirect: speciesReads,
                        readsClade: speciesReads,
                        fractionClade: Double(speciesReads) / Double(totalReads),
                        fractionDirect: Double(speciesReads) / Double(totalReads),
                        parentTaxId: genusNode.taxId
                    )

                    genusNode.addChild(speciesNode)
                }
            }
        }

        return TaxonTree(root: root, unclassifiedNode: nil, totalReads: totalReads)
    }

    // MARK: - Testing Accessors

    /// Returns the summary bar for testing.
    var testSummaryBar: EsVirituSummaryBar { summaryBar }

    /// Returns the detail pane for testing.
    var testDetailPane: EsVirituDetailPane { detailPane }

    /// Returns the detection table view for testing.
    var testDetectionTableView: ViralDetectionTableView { detectionTableView }

    /// Returns the action bar for testing.
    var testActionBar: EsVirituActionBar { actionBar }

    /// Returns the split view for testing.
    var testSplitView: NSSplitView { splitView }

    /// Returns the current EsViritu result for testing.
    var testResult: LungfishIO.EsVirituResult? { esVirituResult }
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

// MARK: - EsVirituActionBar

/// A 36pt bottom bar for the EsViritu result view with export, re-run, and provenance controls.
///
/// ## Layout
///
/// ```
/// [Export v] [Re-run]  |  Rift Valley fever virus -- 1,234 reads  | [Provenance]
/// ```
@MainActor
final class EsVirituActionBar: NSView {

    // MARK: - Callbacks

    /// Called when the user clicks the export button.
    var onExport: (() -> Void)?

    /// Called when the user clicks the re-run button.
    var onReRun: (() -> Void)?

    /// Called when the user clicks the provenance button.
    var onProvenance: ((Any) -> Void)?

    // MARK: - State

    private var totalReads: Int = 0
    private var detectionCount: Int = 0

    // MARK: - Subviews

    private let exportButton = NSButton(
        title: "Export",
        target: nil,
        action: nil
    )
    private let reRunButton = NSButton(
        title: "Re-run",
        target: nil,
        action: nil
    )
    private let infoLabel = NSTextField(labelWithString: "")
    private let provenanceButton = NSButton(
        title: "",
        target: nil,
        action: nil
    )
    private let separator = NSBox()

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
        // Separator at top
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        // Export button (left)
        exportButton.translatesAutoresizingMaskIntoConstraints = false
        exportButton.bezelStyle = .accessoryBarAction
        exportButton.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export")
        exportButton.imagePosition = .imageLeading
        exportButton.target = self
        exportButton.action = #selector(exportTapped(_:))
        exportButton.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(exportButton)

        // Re-run button
        reRunButton.translatesAutoresizingMaskIntoConstraints = false
        reRunButton.bezelStyle = .accessoryBarAction
        reRunButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Re-run")
        reRunButton.imagePosition = .imageLeading
        reRunButton.target = self
        reRunButton.action = #selector(reRunTapped(_:))
        reRunButton.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(reRunButton)

        // Info label (center)
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.font = .systemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingTail
        infoLabel.stringValue = "Select a virus to view details"
        addSubview(infoLabel)

        // Provenance button (right)
        provenanceButton.translatesAutoresizingMaskIntoConstraints = false
        provenanceButton.bezelStyle = .accessoryBarAction
        provenanceButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Provenance")
        provenanceButton.imagePosition = .imageOnly
        provenanceButton.target = self
        provenanceButton.action = #selector(provenanceTapped(_:))
        provenanceButton.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(provenanceButton)

        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),

            exportButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            exportButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            reRunButton.leadingAnchor.constraint(equalTo: exportButton.trailingAnchor, constant: 6),
            reRunButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            infoLabel.leadingAnchor.constraint(equalTo: reRunButton.trailingAnchor, constant: 12),
            infoLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            infoLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: provenanceButton.leadingAnchor, constant: -12
            ),

            provenanceButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            provenanceButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("EsViritu Action Bar")
    }

    // MARK: - Public API

    /// Configures the action bar.
    func configure(totalReads: Int, detectionCount: Int) {
        self.totalReads = totalReads
        self.detectionCount = detectionCount
    }

    /// Updates the info label with the selected virus details.
    func updateSelection(assemblyName: String?, readCount: Int?) {
        if let name = assemblyName, let count = readCount {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = ","
            let readStr = formatter.string(from: NSNumber(value: count)) ?? "\(count)"
            infoLabel.stringValue = "\(name) \u{2014} \(readStr) reads"
            infoLabel.textColor = .labelColor
        } else {
            infoLabel.stringValue = "Select a virus to view details"
            infoLabel.textColor = .secondaryLabelColor
        }
    }

    /// Returns the info label text for testing.
    var infoText: String { infoLabel.stringValue }

    // MARK: - Actions

    @objc private func exportTapped(_ sender: NSButton) {
        onExport?()
    }

    @objc private func reRunTapped(_ sender: NSButton) {
        onReRun?()
    }

    @objc private func provenanceTapped(_ sender: NSButton) {
        onProvenance?(sender)
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
