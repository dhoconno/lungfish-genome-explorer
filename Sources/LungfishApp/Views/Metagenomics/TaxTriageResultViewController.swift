// TaxTriageResultViewController.swift - TaxTriage clinical triage result browser
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import PDFKit
import SwiftUI
import WebKit
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
/// |  Organism Table   |  Report/Krona Tabs   |
/// |  (sortable,       |  (PDFView or         |
/// |   flat list)      |   WKWebView)         |
/// |    (resizable NSSplitView)               |
/// +------------------------------------------+
/// | Action Bar (36pt)                        |
/// +------------------------------------------+
/// ```
///
/// ## Left Pane: Organism Table
///
/// A flat-list `NSTableView` (not outline) showing organism identifications with
/// columns for Organism name, TASS Score, Reads, Coverage, and Confidence
/// (with a color bar indicator). All columns are sortable and user-resizable.
///
/// ## Right Pane: Tab View
///
/// An `NSTabView` with two tabs:
/// - **Report**: `PDFView` (from PDFKit) showing the PDF report if available
/// - **Krona**: `WKWebView` embedding the Krona interactive HTML if available
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

    /// The TaxTriage result driving this view.
    private(set) var taxTriageResult: TaxTriageResult?

    /// The TaxTriage config used for this run (for re-run and provenance).
    private(set) var taxTriageConfig: TaxTriageConfig?

    /// Parsed metrics from the TASS metrics files.
    private(set) var metrics: [TaxTriageMetric] = []

    /// Parsed organisms from the report files.
    private(set) var organisms: [TaxTriageOrganism] = []

    /// Taxonomy tree parsed from the Kraken2 kreport (for sunburst).
    private var taxonomyTree: TaxonTree?

    /// Path to the merged BAM from TaxTriage alignment output.
    private var bamURL: URL?

    /// Path to the resolved BAM index (.bai or .csi).
    private var bamIndexURL: URL?

    /// Maps normalized organism names → BAM reference accessions (from gcfmapping.tsv).
    private var organismToAccessions: [String: [String]] = [:]

    /// Maps Taxonomy ID → BAM reference accessions (from merged.taxid.tsv).
    private var taxIDToAccessions: [Int: [String]] = [:]

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

    /// All table rows before sample filtering (the full merged set).
    private var allTableRows: [TaxTriageTableRow] = []

    /// Distinct sample identifiers discovered from the metrics, in natural order.
    private(set) var sampleIds: [String] = []

    /// Currently selected sample filter index (0 = "All Samples", 1.. = per-sample).
    private(set) var selectedSampleIndex: Int = 0

    /// Optional pre-selected sample ID set by sidebar routing before `configure` runs.
    var preselectedSampleId: String?

    // MARK: - Child Views

    private let summaryBar = TaxTriageSummaryBar()
    private let sampleFilterControl = NSSegmentedControl()
    let splitView = NSSplitView()
    private let leftTabView = NSSegmentedControl()
    private let leftPaneContainer = FlippedPaneContainerView()
    private let sunburstView = TaxonomySunburstView()
    private var miniBAMController: MiniBAMViewController?
    private let organismTableView = TaxTriageOrganismTableView()
    private let batchOverviewView = TaxTriageBatchOverviewView()
    let actionBar = TaxTriageActionBar()
    private let blastDrawer = BlastResultsDrawerTab()
    private var blastDrawerHeightConstraint: NSLayoutConstraint?
    private var splitViewBottomConstraint: NSLayoutConstraint?

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

    // MARK: - Split View State

    /// Whether the initial divider position has been applied.
    private var didSetInitialSplitPosition = false

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
        setupSplitView()
        setupMiniBAMViewer()
        setupBlastDrawer()
        setupActionBar()
        layoutSubviews()
        wireCallbacks()
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
        bamVC.onReadStatsUpdated = { [weak self] _, uniqueReads in
            guard let self, let selectedOrganismName = self.selectedOrganismName else { return }
            // For segmented organisms, table unique reads are aggregated across
            // accessions in background; don't overwrite with one segment's value.
            if (self.accessions(for: selectedOrganismName)?.count ?? 0) > 1 {
                return
            }
            self.applyUniqueReadCount(uniqueReads, for: selectedOrganismName)
        }
        addChild(bamVC)
        miniBAMController = bamVC

        let bamView = bamVC.view
        bamView.translatesAutoresizingMaskIntoConstraints = false
        bamView.isHidden = true
        leftPaneContainer.addSubview(bamView)

        NSLayoutConstraint.activate([
            bamView.topAnchor.constraint(equalTo: leftTabView.bottomAnchor, constant: 4),
            bamView.leadingAnchor.constraint(equalTo: leftPaneContainer.leadingAnchor),
            bamView.trailingAnchor.constraint(equalTo: leftPaneContainer.trailingAnchor),
            bamView.bottomAnchor.constraint(equalTo: leftPaneContainer.bottomAnchor),
        ])
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

    /// Configures the view with a TaxTriage result and optional config.
    ///
    /// Prefers parsing TaxTriage confidence reports (`multiqc_confidences.txt`
    /// and `*.organisms.report.txt`) so displayed TASS/read values match the
    /// PDF report content.
    ///
    /// - Parameters:
    ///   - result: The TaxTriage pipeline result.
    ///   - config: The config used for this run (for provenance and re-run).
    public func configure(result: TaxTriageResult, config: TaxTriageConfig? = nil) {
        taxTriageResult = result
        taxTriageConfig = config ?? result.config
        taxonomyTree = nil
        bamURL = nil
        bamIndexURL = nil
        organismToAccessions = [:]
        taxIDToAccessions = [:]
        accessionLengths = [:]
        accessionMappedReadCounts = [:]
        referenceFastaURL = nil
        referenceSequenceCache = [:]
        // Load cached unique reads but discard zeros — they are stale from a bug
        // where organisms without accession mappings were recorded as 0.
        // The background task will recompute them correctly.
        deduplicatedReadCounts = (result.deduplicatedReadCounts ?? [:]).filter { $0.value > 0 }
        perSampleDeduplicatedReadCounts = result.perSampleDeduplicatedReadCounts ?? [:]
        deduplicatedReadCountTask?.cancel()
        deduplicatedReadCountTask = nil
        selectedOrganismName = nil
        selectedReadCount = nil

        // 1. Parse confidence/organism metrics (preferred over top_report.tsv).
        let preferredMetrics = parsePreferredConfidenceMetrics(from: result)
        var allMetrics = preferredMetrics
        if allMetrics.isEmpty {
            for metricsURL in result.metricsFiles where !metricsURL.path.contains("/work/") {
                if let parsed = try? TaxTriageMetricsParser.parse(url: metricsURL), !parsed.isEmpty {
                    allMetrics.append(contentsOf: parsed)
                }
            }
        }
        // Keep all per-sample metrics for filtering; deduplicate only
        // per (organism, sample) to remove true duplicates from overlapping files.
        metrics = deduplicatePerOrganismSample(allMetrics)

        // For the merged organism list, collapse to one row per organism
        // using the highest TASS score across samples.
        let mergedMetrics = deduplicatedMetrics(metrics)

        var allOrganisms = mergedMetrics.map {
            TaxTriageOrganism(
                name: $0.organism,
                score: $0.tassScore,
                reads: $0.reads,
                coverage: $0.coverageBreadth,
                taxId: $0.taxId,
                rank: $0.rank
            )
        }

        // Fallback: top_report.tsv for older/incomplete runs.
        if allOrganisms.isEmpty {
            let topReportFiles = result.allOutputFiles.filter {
                $0.lastPathComponent.contains("top_report.tsv")
                    && !$0.path.contains("/work/")
            }
            for topReportURL in topReportFiles {
                let parsed = parseTopReport(url: topReportURL)
                allOrganisms.append(contentsOf: parsed)
            }
        }

        // Last fallback: legacy key/value report parser.
        if allOrganisms.isEmpty {
            for reportURL in result.reportFiles {
                if let parsed = try? TaxTriageReportParser.parse(url: reportURL) {
                    allOrganisms.append(contentsOf: parsed)
                }
            }
        }
        organisms = allOrganisms

        // 2. Parse taxonomy tree from kreport for sunburst
        let kreportFiles = result.allOutputFiles.filter {
            $0.lastPathComponent.hasSuffix(".kraken2.report.txt")
                && !$0.path.contains("/work/")
        }
        logger.info("Found \(kreportFiles.count) kreport file(s)")
        if let kreportURL = kreportFiles.first {
            do {
                let tree = try KreportParser.parse(url: kreportURL)
                taxonomyTree = tree
                logger.info("Parsed kreport with \(tree.totalReads) total reads, \(tree.speciesCount) species")
            } catch {
                logger.warning("Failed to parse kreport: \(error.localizedDescription)")
            }
        }

        // Build table rows from organisms (enriched with merged metrics)
        let mergedRows = buildTableRows(organisms: allOrganisms, metrics: mergedMetrics)
        allTableRows = mergedRows

        // Extract distinct sample IDs from metrics for the sample filter control.
        let discoveredSamples = extractSampleIds(from: metrics)
        sampleIds = discoveredSamples
        rebuildSampleFilterSegments()

        // Update summary bar
        summaryBar.update(
            organismCount: mergedRows.count,
            runtime: result.runtime,
            highConfidenceCount: mergedRows.filter { $0.tassScore >= 0.8 }.count,
            sampleCount: result.config.samples.count
        )

        // Configure table (apply filter if a sample was pre-selected)
        if selectedSampleIndex > 0 {
            applyCurrentSampleFilter()
        } else {
            organismTableView.rows = mergedRows
        }

        // Configure tabs
        // Configure sunburst from kreport taxonomy tree
        configureSunburst()

        // Find the BAM file from TaxTriage output (check minimap2/ and alignment/)
        let bamFiles = result.allOutputFiles.filter {
            $0.pathExtension == "bam" && !$0.path.contains("/work/")
        }
        if let bam = bamFiles.first {
            bamURL = bam
            bamIndexURL = resolveBamIndex(for: bam, allOutputFiles: result.allOutputFiles)
            let indexName = bamIndexURL?.lastPathComponent ?? "none"
            logger.info("Found TaxTriage BAM: \(bam.lastPathComponent, privacy: .public), index: \(indexName, privacy: .public)")
        }

        // Parse gcfmapping.tsv to build organism→accession lookup
        let gcfFiles = result.allOutputFiles.filter {
            $0.lastPathComponent.contains("gcfmapping.tsv") && !$0.path.contains("/work/")
        }
        if let gcfFile = gcfFiles.first {
            parseGCFMapping(url: gcfFile)
        }

        // Parse merged.taxid.tsv to build taxid→accession lookup and enrich organism mapping.
        let taxIDMapFiles = result.allOutputFiles.filter {
            $0.lastPathComponent.contains("merged.taxid.tsv") && !$0.path.contains("/work/")
        }
        if let taxIDMapFile = taxIDMapFiles.first {
            parseTaxIDMapping(url: taxIDMapFile)
        }

        referenceFastaURL = result.allOutputFiles.first(where: { url in
            guard !url.path.contains("/work/") else { return false }
            let ext = url.pathExtension.lowercased()
            guard ext == "fasta" || ext == "fa" || ext == "fna" else { return false }
            return url.lastPathComponent.lowercased().contains("references")
        })

        // Parse BAM header for reference lengths (needed for MiniBAMViewController)
        if let bam = bamURL {
            parseBamReferenceLengths(bamURL: bam)
        }

        refreshLeftPaneMode(preferTaxonomy: true)

        // Update action bar
        actionBar.configure(
            organismCount: mergedRows.count,
            sampleCount: result.config.samples.count
        )

        scheduleDeduplicatedReadCountComputation(for: mergedRows)

        // Discover related Kraken2/EsViritu analyses in source bundles
        discoverRelatedAnalyses()

        logger.info("Configured with \(mergedRows.count) organisms, \(result.metricsFiles.count) metrics files, \(result.kronaFiles.count) Krona files")
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
        metrics: [TaxTriageMetric]
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

        var rows: [TaxTriageTableRow] = []

        // Start from organisms (report data)
        for organism in organisms {
            let normalizedName = normalizedOrganismName(organism.name)
            let matchingMetric = metricsByName[normalizedName]
            rows.append(TaxTriageTableRow(
                organism: organism.name,
                tassScore: matchingMetric?.tassScore ?? organism.score,
                reads: matchingMetric?.reads ?? organism.reads,
                uniqueReads: deduplicatedReadCounts[normalizedName],
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
                uniqueReads: deduplicatedReadCounts[normalizedName],
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

    /// Rebuilds the sample filter segments from the discovered sample IDs.
    private func rebuildSampleFilterSegments() {
        let ids = sampleIds
        if ids.count <= 1 {
            sampleFilterControl.isHidden = true
            sampleFilterHeightConstraint?.constant = 0
            sampleFilterTopSpacingConstraint?.constant = 0
            sampleFilterBottomSpacingConstraint?.constant = 0
            selectedSampleIndex = 0
            return
        }

        sampleFilterControl.segmentCount = ids.count + 1
        sampleFilterControl.setLabel("All Samples", forSegment: 0)
        for (i, sampleId) in ids.enumerated() {
            sampleFilterControl.setLabel(sampleId, forSegment: i + 1)
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
        sampleFilterHeightConstraint?.constant = 24
        sampleFilterTopSpacingConstraint?.constant = 4
        sampleFilterBottomSpacingConstraint?.constant = 4
    }

    /// Filters table rows to the currently selected sample and refreshes the table.
    private func applyCurrentSampleFilter() {
        let showBatchOverview = selectedSampleIndex == 0 && sampleIds.count > 1

        // Toggle between batch overview and per-sample organism table
        batchOverviewView.isHidden = !showBatchOverview
        organismTableView.isHidden = showBatchOverview

        // Collapse/restore left pane for full-width batch overview
        if showBatchOverview {
            // Hide left pane — give all space to the batch comparison table
            leftPaneContainer.isHidden = true
            if splitView.arrangedSubviews.count > 1 {
                splitView.setPosition(0, ofDividerAt: 0)
            }
        } else {
            // Restore the left pane (taxonomy/alignments)
            if leftPaneContainer.isHidden {
                leftPaneContainer.isHidden = false
                let position = round(splitView.bounds.width * 0.4)
                splitView.setPosition(position, ofDividerAt: 0)
            }
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
            filteredRows = buildTableRows(organisms: filteredOrganisms, metrics: filteredMetrics)
        }

        organismTableView.rows = filteredRows
        summaryBar.update(
            organismCount: filteredRows.count,
            runtime: taxTriageResult?.runtime ?? 0,
            highConfidenceCount: filteredRows.filter { $0.tassScore >= 0.8 }.count,
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

    /// Configures the NSSplitView with organism table (left) and tab view (right).
    ///
    /// Uses raw NSSplitView (not NSSplitViewController) per macOS 26 rules.
    private func setupSplitView() {
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self

        // Left pane: tabbed container with Alignments + Taxonomy

        // Segmented control for switching between BAM and Sunburst
        leftTabView.segmentCount = 2
        leftTabView.setLabel("Alignments", forSegment: 0)
        leftTabView.setLabel("Taxonomy", forSegment: 1)
        leftTabView.segmentStyle = .texturedRounded
        leftTabView.selectedSegment = 1  // Taxonomy is default until BAM-backed selection
        leftTabView.target = self
        leftTabView.action = #selector(leftTabChanged(_:))
        leftTabView.translatesAutoresizingMaskIntoConstraints = false
        leftPaneContainer.addSubview(leftTabView)

        // Sunburst (visible by default)
        sunburstView.translatesAutoresizingMaskIntoConstraints = false
        sunburstView.isHidden = false
        leftPaneContainer.addSubview(sunburstView)

        NSLayoutConstraint.activate([
            leftTabView.topAnchor.constraint(equalTo: leftPaneContainer.topAnchor, constant: 4),
            leftTabView.centerXAnchor.constraint(equalTo: leftPaneContainer.centerXAnchor),

            sunburstView.topAnchor.constraint(equalTo: leftTabView.bottomAnchor, constant: 4),
            sunburstView.leadingAnchor.constraint(equalTo: leftPaneContainer.leadingAnchor),
            sunburstView.trailingAnchor.constraint(equalTo: leftPaneContainer.trailingAnchor),
            sunburstView.bottomAnchor.constraint(equalTo: leftPaneContainer.bottomAnchor),
        ])

        // Right pane: organism table + batch overview (mutually exclusive)
        let tableContainer = NSView()
        organismTableView.autoresizingMask = [.width, .height]
        tableContainer.addSubview(organismTableView)

        batchOverviewView.autoresizingMask = [.width, .height]
        batchOverviewView.isHidden = true
        tableContainer.addSubview(batchOverviewView)

        // Wire batch overview cell clicks to navigate to organism in sample
        batchOverviewView.onCellSelected = { [weak self] organism, sampleId in
            guard let self else { return }
            self.selectSample(sampleId)
            // Try to select the organism row in the table
            self.organismTableView.selectRow(byOrganism: organism)
        }

        splitView.addArrangedSubview(leftPaneContainer)
        splitView.addArrangedSubview(tableContainer)

        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        view.addSubview(splitView)
    }

    @objc private func leftTabChanged(_ sender: NSSegmentedControl) {
        let showBAM = sender.selectedSegment == 0
        miniBAMController?.view.isHidden = !showBAM
        sunburstView.isHidden = showBAM
    }

    /// Updates segment availability and default selection based on loaded data.
    private func refreshLeftPaneMode(preferTaxonomy: Bool) {
        let hasBAM = (bamURL != nil && bamIndexURL != nil)
        let hasTaxonomy = taxonomyTree != nil

        leftTabView.setEnabled(hasBAM, forSegment: 0)
        leftTabView.setEnabled(hasTaxonomy, forSegment: 1)

        let targetSegment: Int
        if preferTaxonomy, hasTaxonomy {
            targetSegment = 1
        } else if hasBAM {
            targetSegment = 0
        } else if hasTaxonomy {
            targetSegment = 1
        } else {
            targetSegment = 0
        }

        leftTabView.selectedSegment = targetSegment
        leftTabChanged(leftTabView)

        if !hasBAM {
            miniBAMController?.clear()
        }
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

    /// Parses the gcfmapping.tsv to build organism name → accession lookup.
    ///
    /// Format: accession\tGCF_ID\torganism_name\tdescription
    private func parseGCFMapping(url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }

        var mapping: [String: [String]] = [:]
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
        organismToAccessions = mapping.mapValues(uniqueAccessionsPreservingOrder)
        logger.info("Parsed gcfmapping: \(mapping.count) organisms → \(mapping.values.flatMap { $0 }.count) accessions")
    }

    /// Parses merged taxid mapping: accession + organism + taxid.
    ///
    /// Expected columns:
    /// `Acc\tAssembly\tOrganism_Name\tDescription\tMapped_Value`
    private func parseTaxIDMapping(url: URL) {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return }

        var byTaxID: [Int: [String]] = [:]
        var byOrganism: [String: [String]] = organismToAccessions

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

        taxIDToAccessions = byTaxID.mapValues(uniqueAccessionsPreservingOrder)
        organismToAccessions = byOrganism.mapValues(uniqueAccessionsPreservingOrder)
        logger.info("Parsed merged taxid mapping: \(self.taxIDToAccessions.count) taxids, \(self.organismToAccessions.count) organisms")
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
        value
            .replacingOccurrences(of: "★", with: "")
            .replacingOccurrences(of: "°", with: "")
            .replacingOccurrences(of: "\u{25CF}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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

    private func accessions(for row: TaxTriageTableRow) -> [String]? {
        if let taxID = row.taxId, let byTaxID = taxIDToAccessions[taxID], !byTaxID.isEmpty {
            return rankAccessionsByReadSupport(byTaxID)
        }
        return accessions(for: row.organism)
    }

    private func accessions(for organismName: String) -> [String]? {
        let normalized = normalizedOrganismName(organismName)
        guard !normalized.isEmpty else { return nil }
        if let exact = organismToAccessions[normalized] {
            return rankAccessionsByReadSupport(exact)
        }
        if let fuzzy = organismToAccessions.first(where: { key, _ in
            key.contains(normalized) || normalized.contains(key)
        }) {
            return rankAccessionsByReadSupport(fuzzy.value)
        }

        // Token-overlap fallback handles minor source typos/variant formatting
        // (e.g. missing first character, shortened years like /40 vs /1940).
        let best = organismToAccessions.max { lhs, rhs in
            tokenSimilarity(lhs.key, normalized) < tokenSimilarity(rhs.key, normalized)
        }
        if let best, tokenSimilarity(best.key, normalized) >= 0.75 {
            return rankAccessionsByReadSupport(best.value)
        }
        return nil
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
        guard !reads.isEmpty else { return 0 }
        var positionGroups: [String: Int] = [:]
        for read in reads {
            let strand = read.isReverse ? "R" : "F"
            let key = "\(read.position)-\(read.alignmentEnd)-\(strand)"
            positionGroups[key, default: 0] += 1
        }
        let duplicateCount = positionGroups.values.reduce(into: 0) { total, count in
            if count > 1 { total += count - 1 }
        }
        return max(0, reads.count - duplicateCount)
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
                self.parseBamReferenceLengths(bamURL: bamURL)
            }

            for row in rowsByReadCount {
                if Task.isCancelled { return }
                let normalized = self.normalizedOrganismName(row.organism)
                if self.deduplicatedReadCounts[normalized] != nil { continue }

                guard let rowAccessions = self.accessions(for: row), !rowAccessions.isEmpty else {
                    // No accession mapping — can't compute from BAM.
                    // Use total reads as the unique count (conservative: assume all unique).
                    if row.reads > 0 {
                        self.applyUniqueReadCount(row.reads, for: row.organism)
                        self.computePerSampleUniqueReads(
                            normalized: normalized,
                            totalReads: row.reads,
                            uniqueReads: row.reads
                        )
                    } else {
                        self.applyUniqueReadCount(0, for: row.organism)
                    }
                    continue
                }
                var totalUnique = 0
                var fetchedAny = false

                for accession in rowAccessions {
                    if Task.isCancelled { return }
                    if self.accessionLengths[accession] == nil {
                        self.parseBamReferenceLengths(bamURL: bamURL)
                    }
                    guard let contigLength = self.accessionLengths[accession] else { continue }

                    do {
                        let fetchedReads = try await provider.fetchReads(
                            chromosome: accession,
                            start: 0,
                            end: contigLength,
                            maxReads: 5000
                        )
                        if fetchedReads.isEmpty { continue }
                        fetchedAny = true
                        totalUnique += Self.deduplicatedReadCount(from: fetchedReads)
                    } catch {
                        logger.debug("Failed dedup count for \(row.organism, privacy: .public) (\(accession, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                    }
                }

                if fetchedAny {
                    let boundedUnique = max(1, min(row.reads, totalUnique))
                    self.applyUniqueReadCount(boundedUnique, for: row.organism)

                    // Compute per-sample estimates by distributing the dedup ratio
                    // across each sample's per-organism read count.
                    self.computePerSampleUniqueReads(
                        normalized: normalized,
                        totalReads: row.reads,
                        uniqueReads: boundedUnique
                    )
                } else {
                    // No reads fetched from BAM (accession exists but empty).
                    // Use total reads as conservative estimate.
                    let fallback = row.reads > 0 ? row.reads : 0
                    self.applyUniqueReadCount(fallback, for: row.organism)
                    if row.reads > 0 {
                        self.computePerSampleUniqueReads(
                            normalized: normalized,
                            totalReads: row.reads,
                            uniqueReads: fallback
                        )
                    }
                }
            }

            // Persist computed counts to the sidecar so they load instantly next time.
            if !Task.isCancelled, !self.deduplicatedReadCounts.isEmpty {
                self.persistDeduplicatedReadCounts()
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

    private func applyUniqueReadCount(_ uniqueReads: Int, for organismName: String) {
        let key = normalizedOrganismName(organismName)
        deduplicatedReadCounts[key] = uniqueReads

        var changed = false
        let updated = organismTableView.rows.map { row -> TaxTriageTableRow in
            guard normalizedOrganismName(row.organism) == key else { return row }
            if row.uniqueReads == uniqueReads { return row }
            changed = true
            return row.with(uniqueReads: uniqueReads)
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
            actionBar.updateSelection(
                organismName: selectedOrganismName,
                readCount: selectedReadCount,
                uniqueReadCount: uniqueReads
            )
        }
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

        guard let samtools = ProcessManager.shared.findExecutable(named: "samtools") else {
            logger.warning("Cannot generate BAM index: samtools not found")
            return nil
        }

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

    /// Parses BAM reference lengths from samtools idxstats output.
    private func parseBamReferenceLengths(bamURL: URL) {
        guard ProcessManager.shared.findExecutable(named: "samtools") != nil else {
            logger.warning("Cannot parse BAM references: samtools not found")
            return
        }
        let proc = Process()
        proc.executableURL = ProcessManager.shared.findExecutable(named: "samtools")
        proc.arguments = ["idxstats", bamURL.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        let errorPipe = Pipe()
        proc.standardError = errorPipe

        do {
            try proc.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else {
                let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                logger.warning("samtools idxstats failed: \(stderr, privacy: .public)")
                return
            }

            if let output = String(data: data, encoding: .utf8) {
                for line in output.components(separatedBy: .newlines) {
                    let cols = line.components(separatedBy: "\t")
                    guard cols.count >= 4 else { continue }
                    let ref = cols[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !ref.isEmpty, ref != "*" else { continue }
                    if let length = Int(cols[1]), length > 0 {
                        accessionLengths[ref] = length
                    }
                    if let mappedReads = Int(cols[2]) {
                        accessionMappedReadCounts[ref] = mappedReads
                    }
                }
            }
            let refCount = self.accessionLengths.count
            logger.info("Parsed BAM references: \(refCount) contigs, mapped-read stats for \(self.accessionMappedReadCounts.count) contigs")
        } catch {
            logger.warning("Failed to parse BAM references: \(error.localizedDescription)")
        }
    }

    /// Configures the sunburst with the taxonomy tree from the kreport.
    private func configureSunburst() {
        if let tree = taxonomyTree {
            sunburstView.tree = tree
            sunburstView.centerNode = nil
            sunburstView.selectedNode = nil
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
        ])
    }

    // MARK: - Callback Wiring

    private func wireCallbacks() {
        // Table selection -> action bar update + BAM viewer update
        organismTableView.onRowSelected = { [weak self] row in
            guard let self else { return }
            self.selectedOrganismName = row?.organism
            self.selectedReadCount = row?.reads
            self.actionBar.updateSelection(
                organismName: row?.organism,
                readCount: row?.reads,
                uniqueReadCount: row?.uniqueReads
            )

            // Load BAM alignments for the selected organism.
            // The BAM uses accession numbers (NC_009539.1) as reference names,
            // not organism names. Use the gcfmapping to translate.
            if let row, let bamURL = self.bamURL {
                let organismName = row.organism
                if let accessions = self.accessions(for: row),
                   let primaryAccession = accessions.first {
                    if self.accessionLengths[primaryAccession] == nil {
                        self.parseBamReferenceLengths(bamURL: bamURL)
                    }
                    if let contigLength = self.accessionLengths[primaryAccession] {
                        let referenceSequence = self.referenceSequence(for: primaryAccession)
                        self.miniBAMController?.displayContig(
                            bamURL: bamURL,
                            contig: primaryAccession,
                            contigLength: contigLength,
                            indexURL: self.bamIndexURL,
                            referenceSequence: referenceSequence
                        )
                        // Switch to Alignments tab automatically
                        self.leftTabView.selectedSegment = 0
                        self.leftTabChanged(self.leftTabView)
                    } else {
                        self.miniBAMController?.clear()
                        logger.debug("No reference length for accession: \(primaryAccession, privacy: .public)")
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

        // Action bar open report externally
        actionBar.onOpenExternally = { [weak self] in
            self?.openReportExternally()
        }

        // Action bar related analyses navigation
        actionBar.onRelatedAnalysis = { [weak self] analysisType, url in
            self?.onRelatedAnalysis?(analysisType, url)
        }
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

        actionBar.configureRelatedAnalyses(items: items)
        if !items.isEmpty {
            logger.info("Discovered \(items.count) related analyses in source bundles")
        }
    }

    /// Callback for navigating to a related analysis result.
    /// Set by the host (ViewerViewController+TaxTriage) to handle cross-navigation.
    public var onRelatedAnalysis: ((String, URL) -> Void)?

    // MARK: - NSSplitViewDelegate

    /// Enforces minimum widths for organism table (300px) and tab view (300px).
    /// When batch overview is active (All Samples), allows the left pane to collapse
    /// fully so the batch table gets the full viewport width.
    public func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        let isBatchOverview = selectedSampleIndex == 0 && sampleIds.count > 1
        if isBatchOverview { return 0 }
        return max(proposedMinimumPosition, 300)
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

        let headers = [
            "Organism", "TASS Score", "Reads", "Unique Reads", "Coverage", "Confidence",
            "Tax ID", "Rank", "Abundance",
        ]
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
    var testActionBar: TaxTriageActionBar { actionBar }

    /// Returns the split view for testing.
    var testSplitView: NSSplitView { splitView }

    /// Returns the sunburst view for testing.
    var testSunburstView: TaxonomySunburstView { sunburstView }

    /// Returns the current result for testing.
    var testResult: TaxTriageResult? { taxTriageResult }
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

    func with(uniqueReads: Int?) -> TaxTriageTableRow {
        TaxTriageTableRow(
            organism: organism,
            tassScore: tassScore,
            reads: reads,
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
final class TaxTriageOrganismTableView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - Column Identifiers

    private enum ColumnID {
        static let organism = NSUserInterfaceItemIdentifier("organism")
        static let tassScore = NSUserInterfaceItemIdentifier("tassScore")
        static let reads = NSUserInterfaceItemIdentifier("reads")
        static let uniqueReads = NSUserInterfaceItemIdentifier("uniqueReads")
        static let coverage = NSUserInterfaceItemIdentifier("coverage")
        static let confidence = NSUserInterfaceItemIdentifier("confidence")
    }

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

    /// Called when the user requests BLAST verification for a row with a chosen read count.
    var onBlastRequested: ((TaxTriageTableRow, Int) -> Void)?

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
        confidenceCol.minWidth = 60
        confidenceCol.maxWidth = 140
        confidenceCol.sortDescriptorPrototype = NSSortDescriptor(key: "confidence", ascending: false)
        tableView.addTableColumn(confidenceCol)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
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

        let copyItem = NSMenuItem(
            title: "Copy Organism Name",
            action: #selector(contextCopyAction(_:)),
            keyEquivalent: ""
        )
        copyItem.target = self
        menu.addItem(copyItem)

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
                cell.toolTip = "Contamination risk: detected in negative control sample"
                cell.textColor = .systemOrange
            }
            return cell

        case ColumnID.tassScore:
            return makeLabelCell(text: String(format: "%.3f", item.tassScore), monospaced: true)

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
            return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selectedRow = tableView.selectedRow
        if selectedRow >= 0, selectedRow < sortedRows.count {
            onRowSelected?(sortedRows[selectedRow])
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

    /// Updates the summary bar with result data.
    func update(
        organismCount: Int,
        runtime: TimeInterval,
        highConfidenceCount: Int,
        sampleCount: Int
    ) {
        self.organismCount = organismCount
        self.runtime = runtime
        self.highConfidenceCount = highConfidenceCount
        self.sampleCount = sampleCount
        needsDisplay = true
    }

    override var cards: [Card] {
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


// MARK: - TaxTriageActionBar

/// A 36pt bottom bar for the TaxTriage result view with export, re-run, open externally, and provenance controls.
///
/// ## Layout
///
/// ```
/// [Export v] [Re-run] [Open Report]  |  E. coli -- 12,345 reads  | [Provenance]
/// ```
@MainActor
final class TaxTriageActionBar: NSView {

    // MARK: - Callbacks

    /// Called when the user clicks the export button.
    var onExport: (() -> Void)?

    /// Called when the user clicks the re-run button.
    var onReRun: (() -> Void)?

    /// Called when the user clicks the provenance button.
    var onProvenance: ((Any) -> Void)?

    /// Called when the user clicks the open externally button.
    var onOpenExternally: (() -> Void)?

    /// Called when the user selects a related analysis to navigate to.
    /// Parameter: (analysisType, bundleURL) where analysisType is "kraken2" or "esviritu".
    var onRelatedAnalysis: ((String, URL) -> Void)?

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
    private let openExternalButton = NSButton(
        title: "Open Report",
        target: nil,
        action: nil
    )
    private let relatedButton = NSButton(
        title: "Related",
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

        // Open report externally button
        openExternalButton.translatesAutoresizingMaskIntoConstraints = false
        openExternalButton.bezelStyle = .accessoryBarAction
        openExternalButton.image = NSImage(systemSymbolName: "arrow.up.forward.square", accessibilityDescription: "Open Report")
        openExternalButton.imagePosition = .imageLeading
        openExternalButton.target = self
        openExternalButton.action = #selector(openExternalTapped(_:))
        openExternalButton.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(openExternalButton)

        // Related analyses button (hidden by default, shown when related results exist)
        relatedButton.translatesAutoresizingMaskIntoConstraints = false
        relatedButton.bezelStyle = .accessoryBarAction
        relatedButton.image = NSImage(systemSymbolName: "link", accessibilityDescription: "Related Analyses")
        relatedButton.imagePosition = .imageLeading
        relatedButton.target = self
        relatedButton.action = #selector(relatedTapped(_:))
        relatedButton.setContentHuggingPriority(.required, for: .horizontal)
        relatedButton.isHidden = true
        addSubview(relatedButton)

        // Info label (center)
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.font = .systemFont(ofSize: 11, weight: .regular)
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.lineBreakMode = .byTruncatingTail
        infoLabel.stringValue = "Select an organism to view details"
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

            openExternalButton.leadingAnchor.constraint(equalTo: reRunButton.trailingAnchor, constant: 6),
            openExternalButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            relatedButton.leadingAnchor.constraint(equalTo: openExternalButton.trailingAnchor, constant: 6),
            relatedButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            infoLabel.leadingAnchor.constraint(equalTo: relatedButton.trailingAnchor, constant: 12),
            infoLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            infoLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: provenanceButton.leadingAnchor, constant: -12
            ),

            provenanceButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            provenanceButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("TaxTriage Action Bar")
    }

    // MARK: - Public API

    /// Configures the action bar with overall result metadata.
    func configure(organismCount: Int, sampleCount: Int) {
        // Reserved for future use
    }

    /// Updates the info label with the selected organism details.
    func updateSelection(organismName: String?, readCount: Int?, uniqueReadCount: Int?) {
        if let name = organismName, let count = readCount {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.groupingSeparator = ","
            let readStr = formatter.string(from: NSNumber(value: count)) ?? "\(count)"
            if let uniqueReadCount {
                let uniqueStr = formatter.string(from: NSNumber(value: uniqueReadCount)) ?? "\(uniqueReadCount)"
                infoLabel.stringValue = "\(name) \u{2014} \(readStr) reads (\(uniqueStr) unique)"
            } else {
                infoLabel.stringValue = "\(name) \u{2014} \(readStr) reads"
            }
            infoLabel.textColor = .labelColor
        } else {
            infoLabel.stringValue = "Select an organism to view details"
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

    @objc private func openExternalTapped(_ sender: NSButton) {
        onOpenExternally?()
    }

    @objc private func provenanceTapped(_ sender: NSButton) {
        onProvenance?(sender)
    }

    @objc private func relatedTapped(_ sender: NSButton) {
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

    /// Cached list of related analysis items: (displayLabel, analysisType, bundleURL).
    private var relatedAnalysisItems: [(String, String, URL)]?

    /// Configures the related analyses button based on discovered results in source bundles.
    func configureRelatedAnalyses(items: [(String, String, URL)]) {
        relatedAnalysisItems = items
        relatedButton.isHidden = items.isEmpty
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
