// FASTQDatasetViewController.swift - FASTQ dataset statistics dashboard
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishWorkflow
import UniformTypeIdentifiers

/// Parsed FASTQ read record for the read preview table.
private struct FASTQReadPreviewRecord {
    let index: Int
    let readID: String
    let sequence: String
    let length: Int
    let meanQuality: Double
}

/// Parses raw FASTQ text (4 lines per record) into preview records.
/// Free function to avoid @MainActor isolation from the enclosing class.
private func parseFASTQReadPreviewRecords(from fastqText: String) -> [FASTQReadPreviewRecord] {
    let lines = fastqText.split(separator: "\n", omittingEmptySubsequences: false)
    var records: [FASTQReadPreviewRecord] = []
    records.reserveCapacity(1_000)

    var i = 0
    var recordIndex = 1
    while i + 3 < lines.count {
        let headerLine = lines[i]
        let sequenceLine = lines[i + 1]
        // lines[i + 2] is the "+" separator
        let qualityLine = lines[i + 3]

        // Parse read ID from header (strip leading @, take first whitespace-delimited token)
        let header = headerLine.hasPrefix("@") ? String(headerLine.dropFirst()) : String(headerLine)
        let readID = String(header.split(separator: " ", maxSplits: 1).first ?? Substring(header))

        let sequence = String(sequenceLine)
        let length = sequence.count

        // Compute mean Phred quality from ASCII quality string
        let meanQ: Double
        if qualityLine.isEmpty {
            meanQ = 0
        } else {
            var totalQ = 0
            for char in qualityLine.utf8 {
                totalQ += Int(char) - 33
            }
            meanQ = Double(totalQ) / Double(qualityLine.count)
        }

        records.append(FASTQReadPreviewRecord(
            index: recordIndex,
            readID: readID,
            sequence: sequence,
            length: length,
            meanQuality: meanQ
        ))

        recordIndex += 1
        i += 4
    }

    return records
}

@MainActor
public final class FASTQDatasetViewController: NSViewController {

    // MARK: - Layout Defaults

    private enum LayoutDefaults {
        static let summaryBarHeight: CGFloat = 48
        static let summaryToSparklineSpacing: CGFloat = 2
        static let sparklineHeight: CGFloat = 64
        static let topPaneBottomPadding: CGFloat = 1

        /// Fixed height for the top pane (summary + sparklines). Not user-resizable.
        static let topPaneHeight: CGFloat = summaryBarHeight + summaryToSparklineSpacing + sparklineHeight + topPaneBottomPadding

        static let minSidebarWidth: CGFloat = 200
        static let maxSidebarWidth: CGFloat = 320
        static let preferredSidebarFraction: CGFloat = 0.22
        static let minGeometryForInitialLayout: CGFloat = 300
        static let operationHeaderBandHeight: CGFloat = 36
    }

    // MARK: - Operation Categories

    private struct OperationItem {
        let kind: OperationKind
        let title: String
        let sfSymbol: String
        let category: String
    }

    private enum OperationKind: Int, CaseIterable {
        case qualityReport
        case subsampleProportion
        case subsampleCount
        case lengthFilter
        case searchText
        case searchMotif
        case deduplicate
        case qualityTrim
        case adapterTrim
        case fixedTrim
        case contaminantFilter
        case pairedEndMerge
        case pairedEndRepair
        case primerRemoval
        case sequencePresenceFilter
        case errorCorrection
        case orient
        case demultiplex
        case assembleReads
        case mapReads
        case classifyReads
        case detectViruses
        case comprehensiveTriage
        case naoMgsImport
        case humanReadScrub

        var title: String {
            switch self {
            case .qualityReport: return "Generate Quality Report"
            case .subsampleProportion: return "Subsample by Proportion"
            case .subsampleCount: return "Subsample by Count"
            case .lengthFilter: return "Filter by Read Length"
            case .searchText: return "Extract Reads by ID"
            case .searchMotif: return "Extract Reads by Motif"
            case .deduplicate: return "Remove Duplicate Reads"
            case .qualityTrim: return "Quality Trim"
            case .adapterTrim: return "Adapter Removal"
            case .fixedTrim: return "Trim Fixed Bases"
            case .contaminantFilter: return "Remove Spike-in / Contaminants"
            case .pairedEndMerge: return "Merge Overlapping Pairs"
            case .pairedEndRepair: return "Repair Paired-End Files"
            case .primerRemoval: return "PCR Primer Trimming\u{2026}"
            case .sequencePresenceFilter: return "Select Reads by Sequence"
            case .errorCorrection: return "Correct Sequencing Errors"
            case .orient: return "Orient to Reference Strand"
            case .demultiplex: return "Demultiplex by Barcodes\u{2026}"
            case .assembleReads: return "Assemble Reads (SPAdes)"
            case .mapReads: return "Map Reads (minimap2)"
            case .classifyReads: return "Classify & Profile (Kraken2)"
            case .detectViruses: return "Detect Viruses (EsViritu)"
            case .comprehensiveTriage: return "Clinical Triage (TaxTriage)"
            case .naoMgsImport: return "NAO-MGS Surveillance"
            case .humanReadScrub: return "Remove Human Reads"
            }
        }

        var sfSymbol: String {
            switch self {
            case .qualityReport: return "chart.bar.doc.horizontal"
            case .subsampleProportion: return "percent"
            case .subsampleCount: return "number"
            case .lengthFilter: return "ruler"
            case .searchText: return "magnifyingglass"
            case .searchMotif: return "text.magnifyingglass"
            case .deduplicate: return "square.on.square.dashed"
            case .qualityTrim: return "scissors"
            case .adapterTrim: return "scissors.badge.ellipsis"
            case .fixedTrim: return "crop"
            case .contaminantFilter: return "shield.slash"
            case .pairedEndMerge: return "arrow.triangle.merge"
            case .pairedEndRepair: return "wrench.and.screwdriver"
            case .primerRemoval: return "pin.slash"
            case .sequencePresenceFilter: return "text.badge.checkmark"
            case .errorCorrection: return "wand.and.stars"
            case .orient: return "arrow.uturn.right"
            case .demultiplex: return "barcode"
            case .assembleReads: return "puzzlepiece.extension"
            case .mapReads: return "arrow.left.and.right.text.vertical"
            case .classifyReads: return "k.circle"
            case .detectViruses: return "e.circle"
            case .comprehensiveTriage: return "t.circle"
            case .naoMgsImport: return "globe.americas"
            case .humanReadScrub: return "person.slash"
            }
        }

        var category: String {
            switch self {
            case .qualityReport: return "REPORTS"
            case .demultiplex: return "DEMULTIPLEXING"
            case .qualityTrim, .adapterTrim, .fixedTrim, .primerRemoval, .lengthFilter: return "TRIMMING"
            case .humanReadScrub, .contaminantFilter, .deduplicate: return "DECONTAMINATION"
            case .pairedEndMerge, .pairedEndRepair, .orient, .errorCorrection: return "READ PROCESSING"
            case .subsampleProportion, .subsampleCount, .searchText, .searchMotif, .sequencePresenceFilter: return "SAMPLING & SEARCH"
            case .assembleReads: return "ASSEMBLY"
            case .mapReads: return "ALIGNMENT"
            case .classifyReads, .detectViruses, .comprehensiveTriage, .naoMgsImport: return "CLASSIFICATION"
            }
        }

        /// Tooltip describing when and why a biologist would use this operation.
        var tooltip: String {
            switch self {
            case .qualityReport:
                return "Compute per-base quality, GC content, adapter content, and read length distributions. Use as your first step to decide which preprocessing is needed."
            case .subsampleProportion:
                return "Keep a random fraction of reads. Useful for quick test runs or normalizing read depth across samples."
            case .subsampleCount:
                return "Keep a specific number of randomly selected reads. Useful for downsampling to a target coverage."
            case .lengthFilter:
                return "Keep only reads within a specified length range. Similar to gel-based or bead-based size selection in the lab."
            case .searchText:
                return "Find and extract reads matching a text pattern in the read ID or description header."
            case .searchMotif:
                return "Find and extract reads containing a specific DNA sequence motif (supports IUPAC ambiguity codes)."
            case .deduplicate:
                return "Remove PCR duplicates (identical read pairs from library amplification). Important for WGS and enrichment. Do NOT use for amplicon data — identical reads are expected signal."
            case .qualityTrim:
                return "Trim low-quality bases from read ends using a sliding window. Improves downstream mapping and variant calling accuracy."
            case .adapterTrim:
                return "Remove sequencing adapter sequences from reads. Auto-detect mode works for most Illumina libraries."
            case .fixedTrim:
                return "Remove a fixed number of bases from the 5\u{2032} and/or 3\u{2032} end of every read. Use when you know the first N bases are always a technical artifact."
            case .contaminantFilter:
                return "Remove reads matching a contaminant reference (PhiX spike-in by default). Specify a custom FASTA for other contaminants like cloning vectors."
            case .pairedEndMerge:
                return "Combine overlapping R1 and R2 reads into single longer reads. Useful when insert size is shorter than 2\u{00D7} read length (common in amplicon and viral WGS)."
            case .pairedEndRepair:
                return "Fix paired-end files where R1 and R2 are out of sync (e.g., after filtering removed one mate). Restores proper pairing."
            case .primerRemoval:
                return "Remove known PCR primer sequences from read ends. Required for amplicon sequencing to prevent primer-derived false variants."
            case .sequencePresenceFilter:
                return "Keep or discard reads containing a specific DNA sequence. Useful for selecting reads with a known barcode or removing unwanted adapter chimeras."
            case .errorCorrection:
                return "Correct random sequencing errors using k-mer frequency analysis. Improves de novo assembly quality. Do NOT use before variant calling — it can erase real low-frequency mutations."
            case .orient:
                return "Ensure all reads face 5\u{2032}\u{2192}3\u{2032} relative to a reference. Reverse-complements reads on the minus strand. Essential for amplicon data with known primer orientation."
            case .demultiplex:
                return "Split a pooled FASTQ into individual samples by barcode. Supports Illumina, ONT, and PacBio kits. Not needed if your core already demultiplexed."
            case .assembleReads:
                return "Assemble reads de novo into contigs and scaffolds using SPAdes. Supports bacterial isolate, metagenome, and viral assembly modes."
            case .mapReads:
                return "Map reads to a reference genome using minimap2. Produces a sorted, indexed BAM file. Supports Illumina, ONT, and PacBio platforms."
            case .classifyReads:
                return "Assign each read to a taxonomic group using Kraken2. Produces abundance profiles at species level and optional Bracken-refined estimates."
            case .detectViruses:
                return "Run EsViritu viral metagenomics detection with de novo assembly and genome coverage analysis."
            case .comprehensiveTriage:
                return "Run TaxTriage (Nextflow) for end-to-end clinical metagenomics with TASS confidence scoring and organism reporting."
            case .naoMgsImport:
                return "Import results from the NAO metagenomic surveillance pipeline (securebio/nao-mgs-workflow). Parses virus hit tables and displays alignment data."
            case .humanReadScrub:
                return "Remove human-derived reads using NCBI's sra-human-scrubber. Required before SRA submission and recommended for clinical/surveillance samples."
            }
        }

        var previewKind: OperationPreviewView.OperationKind {
            switch self {
            case .qualityReport: return .qualityReport
            case .subsampleProportion: return .subsampleProportion
            case .subsampleCount: return .subsampleCount
            case .lengthFilter: return .lengthFilter
            case .searchText: return .searchText
            case .searchMotif: return .searchMotif
            case .deduplicate: return .deduplicate
            case .qualityTrim: return .qualityTrim
            case .adapterTrim: return .adapterTrim
            case .fixedTrim: return .fixedTrim
            case .contaminantFilter: return .contaminantFilter
            case .pairedEndMerge: return .pairedEndMerge
            case .pairedEndRepair: return .pairedEndRepair
            case .primerRemoval: return .primerRemoval
            case .sequencePresenceFilter: return .sequencePresenceFilter
            case .errorCorrection: return .errorCorrection
            case .orient: return .orient
            case .demultiplex: return .demultiplex
            case .assembleReads: return .assembleReads
            case .mapReads: return .mapReads
            case .classifyReads: return .classifyReads
            case .detectViruses: return .detectViruses
            case .comprehensiveTriage: return .comprehensiveTriage
            case .naoMgsImport: return .naoMgsImport
            case .humanReadScrub: return .humanReadScrub
            }
        }
    }

    // MARK: - Sidebar Data

    /// Category headers + operation items for the source list sidebar.
    /// Ordered to match a typical FASTQ preprocessing workflow.
    private static let categories: [(header: String, items: [OperationKind])] = [
        ("REPORTS", [.qualityReport]),
        ("DEMULTIPLEXING", [.demultiplex]),
        ("TRIMMING", [.qualityTrim, .adapterTrim, .primerRemoval, .fixedTrim, .lengthFilter]),
        ("DECONTAMINATION", [.humanReadScrub, .contaminantFilter, .deduplicate]),
        ("READ PROCESSING", [.pairedEndMerge, .pairedEndRepair, .orient, .errorCorrection]),
        ("SAMPLING & SEARCH", [.subsampleProportion, .subsampleCount, .searchText, .searchMotif, .sequencePresenceFilter]),
        ("ALIGNMENT", [.mapReads]),
        ("ASSEMBLY", [.assembleReads]),
        ("CLASSIFICATION", [.classifyReads, .detectViruses, .comprehensiveTriage, .naoMgsImport]),
    ]


    // MARK: - Sidebar Expansion State

    private static let expansionDefaultsKey = "FASTQOperationSidebarExpansion"

    /// Set of category header names that are currently expanded.
    /// Categories not in this set are collapsed (all collapsed by default).
    private var expandedCategories: Set<String> = {
        guard let dict = UserDefaults.standard.dictionary(forKey: FASTQDatasetViewController.expansionDefaultsKey) as? [String: Bool] else {
            return []
        }
        return Set(dict.filter { $0.value }.map { $0.key })
    }()

    /// Persists the current expansion state to UserDefaults.
    private func saveExpansionState() {
        var dict: [String: Bool] = [:]
        for (header, _) in Self.categories {
            dict[header] = expandedCategories.contains(header)
        }
        UserDefaults.standard.set(dict, forKey: Self.expansionDefaultsKey)
    }

    // MARK: - Properties

    private var statistics: FASTQDatasetStatistics?
    private var fastqURL: URL?
    private var sourceURL: URL?
    private var derivativeManifest: FASTQDerivedBundleManifest?
    private var selectedOperation: OperationKind?
    private nonisolated(unsafe) var qualityReportTask: Task<Void, Never>?
    private nonisolated(unsafe) var operationTask: Task<Void, Never>?
    private nonisolated(unsafe) var fastaPreviewTask: Task<Void, Never>?

    public var onStatisticsUpdated: ((FASTQDatasetStatistics) -> Void)?
    public var onRunOperation: ((FASTQDerivativeRequest) async throws -> Void)?

    /// Callback to open/focus the Demux tab in the metadata drawer.
    public var onOpenDemuxDrawer: (() -> Void)?
    public var onOpenPrimerTrimDrawer: (() -> Void)?
    public var onOpenDedupDrawer: (() -> Void)?

    /// Current demux configuration from the metadata drawer. Set by the drawer view.
    /// When present, the demultiplex operation uses this configuration.
    public var currentDemuxConfig: DemultiplexStep? {
        didSet {
            if selectedOperation == .demultiplex {
                updateParameterBar()
            }
        }
    }

    public var currentPrimerTrimConfiguration: FASTQPrimerTrimConfiguration? {
        didSet {
            if selectedOperation == .primerRemoval {
                updateParameterBar()
            }
        }
    }

    // MARK: - Read Preview Data

    private var readPreviewRecords: [FASTQReadPreviewRecord] = []
    private nonisolated(unsafe) var readPreviewTask: Task<Void, Never>?
    private var readPreviewLoaded = false

    // MARK: - UI Components — Two-Pane Split

    private let mainSplitView = NSSplitView()
    private let topPane = NSView()
    private let middlePane = NSView()

    // Top Pane: Summary + Sparklines
    private let summaryBar = FASTQSummaryBar()
    private let sparklineStrip = FASTQSparklineStrip()

    // Middle Pane: Sidebar + Preview (inner split for resizable sidebar)
    private let middleSplitView = NSSplitView()
    private let sidebarPane = NSView()
    private let previewPane = NSView()
    private let operationSidebar = NSTableView()
    private let operationScrollView = NSScrollView()
    private let operationSidebarHeader = NSTextField(labelWithString: "FASTQ Operations")
    private let operationSidebarHeaderSeparator = NSBox()
    private let parameterBar = NSStackView()
    private let parameterBarSeparator = NSBox()
    private let previewCanvas = OperationPreviewView()
    private let runBar = NSView()
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let outputEstimateLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()

    // Middle Pane: Tab Selector
    private let middleTabControl = NSSegmentedControl()
    private let middleTabSeparator = NSBox()
    private let middleContentContainer = NSView()

    // Read Preview view
    private let readPreviewScrollView = NSScrollView()
    private let readPreviewTable = NSTableView()
    private let readPreviewSpinner = NSProgressIndicator()
    private let readPreviewPlaceholder = NSTextField(labelWithString: "Select the Reads tab to preview the first 1,000 records.")

    // Parameter controls (reused across operations)
    private let fieldOneLabel = NSTextField(labelWithString: "")
    private let fieldTwoLabel = NSTextField(labelWithString: "")
    private let fieldOneInput = NSTextField(string: "")
    private let fieldTwoInput = NSTextField(string: "")
    private let searchFieldPopup = NSPopUpButton()
    private let dedupDrawerButton = NSButton(title: "Configure Dedup…", target: nil, action: nil)
    private let regexCheckbox = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let revCompCheckbox = NSButton(checkboxWithTitle: "Rev. Comp.", target: nil, action: nil)
    private var dedupPreset: FASTQDeduplicatePreset = .exactPCR
    private var dedupSubstitutions: Int = 0
    private var dedupOptical: Bool = false
    private var dedupOpticalDistance: Int = 40
    private let qualityTrimModePopup = NSPopUpButton()
    private let adapterModePopup = NSPopUpButton()
    private let contaminantModePopup = NSPopUpButton()
    private let mergeStrictnessPopup = NSPopUpButton()
    private let primerSourcePopup = NSPopUpButton()
    private let interleaveDirectionPopup = NSPopUpButton()
    private let primerTrimDrawerButton = NSButton(title: "Configure Primer Trim…", target: nil, action: nil)

    // Orient-specific controls
    private let orientReferencePopup = NSPopUpButton()
    private let orientBrowseButton = NSButton(title: "Browse\u{2026}", target: nil, action: nil)
    private let orientMaskPopup = NSPopUpButton()
    private let orientSaveUnorientedCheckbox = NSButton(checkboxWithTitle: "Save unoriented reads", target: nil, action: nil)
    private var orientReferenceURL: URL?
    private var orientProjectReferences: [(url: URL, manifest: ReferenceSequenceManifest)] = []

    // Error banner (replaces modal NSAlert for operation failures)
    private lazy var errorBannerView: NSView = {
        let banner = NSView()
        banner.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.1).cgColor
        banner.layer?.cornerRadius = 6
        banner.isHidden = true
        return banner
    }()
    private lazy var errorBannerLabel: NSTextField = {
        let label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 11)
        label.textColor = .systemRed
        label.maximumNumberOfLines = 3
        return label
    }()
    private lazy var errorBannerDismissButton: NSButton = {
        let btn = NSButton(image: NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Dismiss")!, target: self, action: #selector(dismissErrorBanner))
        btn.bezelStyle = .inline
        btn.isBordered = false
        return btn
    }()

    // MARK: - Lifecycle

    deinit {
        qualityReportTask?.cancel()
        operationTask?.cancel()
        fastaPreviewTask?.cancel()
        readPreviewTask?.cancel()
    }

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))

        configureMainSplitView()
        configureTopPane()
        configureMiddlePane()

        // Orient is dispatched directly through the operations sidebar (no notification needed)
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        applyInitialSplitPositionsIfNeeded()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.applyInitialSplitPositionsIfNeeded()
            }
        }
    }


    // MARK: - Public API

    public func configure(
        statistics: FASTQDatasetStatistics,
        records: [FASTQRecord],
        fastqURL: URL? = nil,
        sourceURL: URL? = nil,
        derivativeManifest: FASTQDerivedBundleManifest? = nil
    ) {
        self.statistics = statistics
        self.fastqURL = fastqURL
        self.sourceURL = sourceURL
        self.derivativeManifest = derivativeManifest

        // Reset read preview cache when the source changes
        readPreviewLoaded = false
        readPreviewRecords = []
        readPreviewTask?.cancel()
        readPreviewTask = nil


        summaryBar.update(with: statistics)
        sparklineStrip.update(with: statistics)
        previewCanvas.update(operation: selectedOperation?.previewKind ?? .none, statistics: statistics)
        loadFASTAPreview(fastqURL: fastqURL, fallbackRecords: records)
        updateQualityReportButton()
        setStatus("Loaded: \(statistics.readCount) reads")
        if let derivativeManifest {
            setStatus("Derived: \(derivativeManifest.operation.displaySummary)")
        }
    }


    public func updateOperationStatus(_ line: String) {
        setStatus(line)
    }

    // MARK: - Main Split View

    private func configureMainSplitView() {
        mainSplitView.translatesAutoresizingMaskIntoConstraints = false
        mainSplitView.isVertical = false
        mainSplitView.dividerStyle = .thin
        mainSplitView.delegate = self
        view.addSubview(mainSplitView)

        // NSSplitView manages pane frames via autoresizing masks — do NOT set
        // translatesAutoresizingMaskIntoConstraints = false on direct pane views.
        // Min sizes are enforced via the NSSplitViewDelegate instead.
        for pane in [topPane, middlePane] {
            mainSplitView.addSubview(pane)
        }

        // Top pane holds its size; bottom pane flexes on window resize.
        mainSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        mainSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        NSLayoutConstraint.activate([
            mainSplitView.topAnchor.constraint(equalTo: view.topAnchor),
            mainSplitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainSplitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mainSplitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: - Top Pane: Summary + Sparklines

    private func configureTopPane() {
        summaryBar.translatesAutoresizingMaskIntoConstraints = false
        topPane.addSubview(summaryBar)

        sparklineStrip.translatesAutoresizingMaskIntoConstraints = false
        sparklineStrip.onComputeQualityReport = { [weak self] in
            self?.selectAndRunQualityReport()
        }
        topPane.addSubview(sparklineStrip)

        NSLayoutConstraint.activate([
            summaryBar.topAnchor.constraint(equalTo: topPane.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: topPane.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: topPane.trailingAnchor),
            summaryBar.heightAnchor.constraint(equalToConstant: LayoutDefaults.summaryBarHeight),

            sparklineStrip.topAnchor.constraint(equalTo: summaryBar.bottomAnchor, constant: LayoutDefaults.summaryToSparklineSpacing),
            sparklineStrip.leadingAnchor.constraint(equalTo: topPane.leadingAnchor),
            sparklineStrip.trailingAnchor.constraint(equalTo: topPane.trailingAnchor),
            sparklineStrip.heightAnchor.constraint(equalToConstant: LayoutDefaults.sparklineHeight),
        ])
    }

    // MARK: - Middle Pane: Operation Sidebar + Preview (resizable split)

    private func configureMiddlePane() {
        // Tab control: Operations | Reads
        middleTabControl.segmentCount = 2
        middleTabControl.setLabel("Operations", forSegment: 0)
        middleTabControl.setLabel("Reads", forSegment: 1)
        middleTabControl.segmentStyle = .texturedRounded
        middleTabControl.selectedSegment = 0
        middleTabControl.target = self
        middleTabControl.action = #selector(middleTabChanged(_:))
        middleTabControl.translatesAutoresizingMaskIntoConstraints = false
        middlePane.addSubview(middleTabControl)
        middleTabSeparator.boxType = .separator
        middleTabSeparator.translatesAutoresizingMaskIntoConstraints = false
        middlePane.addSubview(middleTabSeparator)

        // Content container holds either the operations split or read preview
        middleContentContainer.translatesAutoresizingMaskIntoConstraints = false
        middlePane.addSubview(middleContentContainer)

        // Use high (but not required) priority so constraints yield gracefully
        // when the split view parent starts at zero size during initial layout.
        let tabTop = middleTabControl.topAnchor.constraint(equalTo: middlePane.topAnchor)
        tabTop.priority = .defaultHigh
        let tabHeight = middleTabControl.heightAnchor.constraint(equalToConstant: 24)
        tabHeight.priority = .defaultHigh
        let tabSeparatorTop = middleTabSeparator.topAnchor.constraint(equalTo: middleTabControl.bottomAnchor)
        tabSeparatorTop.priority = .defaultHigh
        let contentTop = middleContentContainer.topAnchor.constraint(equalTo: middleTabSeparator.bottomAnchor)
        contentTop.priority = .defaultHigh
        let contentBottom = middleContentContainer.bottomAnchor.constraint(equalTo: middlePane.bottomAnchor)
        contentBottom.priority = .defaultHigh

        NSLayoutConstraint.activate([
            tabTop,
            middleTabControl.centerXAnchor.constraint(equalTo: middlePane.centerXAnchor),
            tabHeight,

            tabSeparatorTop,
            middleTabSeparator.leadingAnchor.constraint(equalTo: middlePane.leadingAnchor),
            middleTabSeparator.trailingAnchor.constraint(equalTo: middlePane.trailingAnchor),

            contentTop,
            middleContentContainer.leadingAnchor.constraint(equalTo: middlePane.leadingAnchor),
            middleContentContainer.trailingAnchor.constraint(equalTo: middlePane.trailingAnchor),
            contentBottom,
        ])

        // Inner horizontal split: sidebar | preview
        middleSplitView.translatesAutoresizingMaskIntoConstraints = false
        middleSplitView.isVertical = true
        middleSplitView.dividerStyle = .thin
        middleSplitView.delegate = self
        middleContentContainer.addSubview(middleSplitView)

        // NSSplitView manages pane frames — do NOT set
        // translatesAutoresizingMaskIntoConstraints = false on these.
        middleSplitView.addSubview(sidebarPane)
        middleSplitView.addSubview(previewPane)

        middleSplitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0) // sidebar holds
        middleSplitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)  // preview flexes

        NSLayoutConstraint.activate([
            middleSplitView.topAnchor.constraint(equalTo: middleContentContainer.topAnchor),
            middleSplitView.leadingAnchor.constraint(equalTo: middleContentContainer.leadingAnchor),
            middleSplitView.trailingAnchor.constraint(equalTo: middleContentContainer.trailingAnchor),
            middleSplitView.bottomAnchor.constraint(equalTo: middleContentContainer.bottomAnchor),
        ])

        // Read preview table (hidden initially)
        configureReadPreviewTable()

        // Operation sidebar (plain style — no grey source-list background)
        operationSidebar.style = .plain
        operationSidebar.headerView = nil
        operationSidebar.usesAlternatingRowBackgroundColors = false
        operationSidebar.rowHeight = 24
        operationSidebar.floatsGroupRows = false

        let iconColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("icon"))
        iconColumn.width = 20
        iconColumn.maxWidth = 20
        operationSidebar.addTableColumn(iconColumn)

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.width = 140
        nameColumn.resizingMask = .autoresizingMask
        operationSidebar.addTableColumn(nameColumn)

        operationSidebar.dataSource = self
        operationSidebar.delegate = self

        operationScrollView.documentView = operationSidebar
        operationScrollView.hasVerticalScroller = true
        operationScrollView.autohidesScrollers = true
        operationScrollView.drawsBackground = false
        operationScrollView.translatesAutoresizingMaskIntoConstraints = false
        operationSidebarHeader.font = .systemFont(ofSize: 11, weight: .semibold)
        operationSidebarHeader.textColor = .secondaryLabelColor
        operationSidebarHeader.translatesAutoresizingMaskIntoConstraints = false
        sidebarPane.addSubview(operationSidebarHeader)
        operationSidebarHeaderSeparator.boxType = .separator
        operationSidebarHeaderSeparator.translatesAutoresizingMaskIntoConstraints = false
        sidebarPane.addSubview(operationSidebarHeaderSeparator)
        sidebarPane.addSubview(operationScrollView)

        NSLayoutConstraint.activate([
            operationSidebarHeader.centerYAnchor.constraint(
                equalTo: sidebarPane.topAnchor,
                constant: LayoutDefaults.operationHeaderBandHeight / 2
            ),
            operationSidebarHeader.leadingAnchor.constraint(equalTo: sidebarPane.leadingAnchor, constant: 8),
            operationSidebarHeader.trailingAnchor.constraint(lessThanOrEqualTo: sidebarPane.trailingAnchor, constant: -8),

            operationSidebarHeaderSeparator.topAnchor.constraint(
                equalTo: sidebarPane.topAnchor,
                constant: LayoutDefaults.operationHeaderBandHeight
            ),
            operationSidebarHeaderSeparator.leadingAnchor.constraint(equalTo: sidebarPane.leadingAnchor),
            operationSidebarHeaderSeparator.trailingAnchor.constraint(equalTo: sidebarPane.trailingAnchor),

            operationScrollView.topAnchor.constraint(equalTo: operationSidebarHeaderSeparator.bottomAnchor),
            operationScrollView.leadingAnchor.constraint(equalTo: sidebarPane.leadingAnchor),
            operationScrollView.trailingAnchor.constraint(equalTo: sidebarPane.trailingAnchor),
            operationScrollView.bottomAnchor.constraint(equalTo: sidebarPane.bottomAnchor),
        ])

        // Preview area
        configureParameterBar()
        previewPane.addSubview(parameterBar)

        // Thin separator below parameter bar (Liquid Glass style)
        parameterBarSeparator.boxType = .separator
        parameterBarSeparator.translatesAutoresizingMaskIntoConstraints = false
        previewPane.addSubview(parameterBarSeparator)

        previewCanvas.translatesAutoresizingMaskIntoConstraints = false
        previewPane.addSubview(previewCanvas)

        configureRunBar()
        previewPane.addSubview(runBar)

        // Error banner (inline replacement for modal alerts)
        configureErrorBanner()
        previewPane.addSubview(errorBannerView)

        let parameterBarHeight = parameterBar.heightAnchor.constraint(equalToConstant: 36)
        parameterBarHeight.priority = .defaultHigh
        let runBarHeight = runBar.heightAnchor.constraint(equalToConstant: 36)
        runBarHeight.priority = .defaultHigh

        // During initial split-view negotiation, previewPane can transiently be 0x0.
        // Keep these edge constraints non-required to avoid noisy unsatisfiable logs
        // while AppKit settles pane geometry.
        let parameterTop = parameterBar.topAnchor.constraint(equalTo: previewPane.topAnchor)
        parameterTop.priority = .defaultHigh
        let parameterLeading = parameterBar.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor)
        parameterLeading.priority = .defaultHigh
        let parameterTrailing = parameterBar.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor)
        parameterTrailing.priority = .defaultHigh

        let separatorTop = parameterBarSeparator.topAnchor.constraint(equalTo: parameterBar.bottomAnchor)
        separatorTop.priority = .defaultHigh
        let separatorLeading = parameterBarSeparator.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor)
        separatorLeading.priority = .defaultHigh
        let separatorTrailing = parameterBarSeparator.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor)
        separatorTrailing.priority = .defaultHigh

        let previewTop = previewCanvas.topAnchor.constraint(equalTo: parameterBarSeparator.bottomAnchor)
        previewTop.priority = .defaultHigh
        let previewLeading = previewCanvas.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor)
        previewLeading.priority = .defaultHigh
        let previewTrailing = previewCanvas.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor)
        previewTrailing.priority = .defaultHigh
        let previewBottom = previewCanvas.bottomAnchor.constraint(equalTo: errorBannerView.topAnchor, constant: -1)
        previewBottom.priority = .defaultHigh

        let bannerLeading = errorBannerView.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor, constant: 8)
        bannerLeading.priority = .defaultHigh
        let bannerTrailing = errorBannerView.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor, constant: -8)
        bannerTrailing.priority = .defaultHigh
        let bannerBottom = errorBannerView.bottomAnchor.constraint(equalTo: runBar.topAnchor, constant: -4)
        bannerBottom.priority = .defaultHigh
        let bannerHeight = errorBannerView.heightAnchor.constraint(equalToConstant: 0)
        bannerHeight.priority = .defaultLow

        let runLeading = runBar.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor)
        runLeading.priority = .defaultHigh
        let runTrailing = runBar.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor)
        runTrailing.priority = .defaultHigh
        let runBottom = runBar.bottomAnchor.constraint(equalTo: previewPane.bottomAnchor)
        runBottom.priority = .defaultHigh

        NSLayoutConstraint.activate([
            parameterTop,
            parameterLeading,
            parameterTrailing,
            parameterBarHeight,

            separatorTop,
            separatorLeading,
            separatorTrailing,

            previewTop,
            previewLeading,
            previewTrailing,
            previewBottom,

            bannerLeading,
            bannerTrailing,
            bannerBottom,
            bannerHeight,

            runLeading,
            runTrailing,
            runBottom,
            runBarHeight,
        ])
    }

    private func configureParameterBar() {
        parameterBar.translatesAutoresizingMaskIntoConstraints = false
        parameterBar.orientation = .horizontal
        parameterBar.distribution = .fill
        parameterBar.spacing = 12
        parameterBar.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        parameterBar.detachesHiddenViews = true

        // Initialize popups
        searchFieldPopup.addItems(withTitles: ["ID", "Description"])
        dedupDrawerButton.translatesAutoresizingMaskIntoConstraints = false
        dedupDrawerButton.bezelStyle = .rounded
        dedupDrawerButton.controlSize = .small
        dedupDrawerButton.target = self
        dedupDrawerButton.action = #selector(openDedupDrawer(_:))
        qualityTrimModePopup.addItems(withTitles: ["Cut Right (3')", "Cut Front (5')", "Cut Tail", "Cut Both"])
        adapterModePopup.addItems(withTitles: ["Auto-Detect", "Specify Sequence"])
        contaminantModePopup.addItems(withTitles: ["PhiX Spike-in", "Custom Reference"])
        mergeStrictnessPopup.addItems(withTitles: ["Normal", "Strict"])
        primerSourcePopup.addItems(withTitles: ["Literal Sequence", "Reference FASTA"])
        interleaveDirectionPopup.addItems(withTitles: ["Interleave (R1+R2 → one)", "Deinterleave (one → R1+R2)"])

        for control in [fieldOneLabel, fieldTwoLabel] {
            control.font = .systemFont(ofSize: 10, weight: .medium)
            control.textColor = .secondaryLabelColor
            control.translatesAutoresizingMaskIntoConstraints = false
        }

        for field in [fieldOneInput, fieldTwoInput] {
            field.font = .systemFont(ofSize: 12)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
            field.delegate = self
        }

        for popup in [searchFieldPopup, qualityTrimModePopup, adapterModePopup,
                       contaminantModePopup, mergeStrictnessPopup, primerSourcePopup,
                       interleaveDirectionPopup] {
            popup.font = .systemFont(ofSize: 12)
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.target = self
            popup.action = #selector(parameterPopupChanged(_:))
        }


        regexCheckbox.translatesAutoresizingMaskIntoConstraints = false
        regexCheckbox.target = self
        regexCheckbox.action = #selector(parameterCheckboxChanged(_:))
        revCompCheckbox.translatesAutoresizingMaskIntoConstraints = false
        revCompCheckbox.target = self
        revCompCheckbox.action = #selector(parameterCheckboxChanged(_:))
        primerTrimDrawerButton.translatesAutoresizingMaskIntoConstraints = false
        primerTrimDrawerButton.bezelStyle = .rounded
        primerTrimDrawerButton.controlSize = .small
        primerTrimDrawerButton.target = self
        primerTrimDrawerButton.action = #selector(openPrimerTrimDrawer(_:))
    }

    private func configureErrorBanner() {
        errorBannerView.translatesAutoresizingMaskIntoConstraints = false
        errorBannerLabel.translatesAutoresizingMaskIntoConstraints = false
        errorBannerDismissButton.translatesAutoresizingMaskIntoConstraints = false

        errorBannerView.addSubview(errorBannerLabel)
        errorBannerView.addSubview(errorBannerDismissButton)

        NSLayoutConstraint.activate([
            errorBannerLabel.leadingAnchor.constraint(equalTo: errorBannerView.leadingAnchor, constant: 8),
            errorBannerLabel.centerYAnchor.constraint(equalTo: errorBannerView.centerYAnchor),
            errorBannerLabel.trailingAnchor.constraint(lessThanOrEqualTo: errorBannerDismissButton.leadingAnchor, constant: -4),

            errorBannerDismissButton.trailingAnchor.constraint(equalTo: errorBannerView.trailingAnchor, constant: -4),
            errorBannerDismissButton.centerYAnchor.constraint(equalTo: errorBannerView.centerYAnchor),
            errorBannerDismissButton.widthAnchor.constraint(equalToConstant: 16),
            errorBannerDismissButton.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    private func showErrorBanner(_ message: String) {
        errorBannerLabel.stringValue = message
        errorBannerView.isHidden = false
        // Auto-dismiss after 10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            MainActor.assumeIsolated {
                self?.dismissErrorBanner()
            }
        }
    }

    @objc private func dismissErrorBanner() {
        errorBannerView.isHidden = true
    }

    private func configureRunBar() {
        runBar.translatesAutoresizingMaskIntoConstraints = false

        // Top border
        let border = NSBox()
        border.boxType = .separator
        border.translatesAutoresizingMaskIntoConstraints = false
        runBar.addSubview(border)

        // Status label (replaces bottom activity panel)
        statusLabel.font = .systemFont(ofSize: 10)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        runBar.addSubview(statusLabel)

        outputEstimateLabel.font = .systemFont(ofSize: 11)
        outputEstimateLabel.textColor = .secondaryLabelColor
        outputEstimateLabel.lineBreakMode = .byTruncatingTail
        outputEstimateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        outputEstimateLabel.translatesAutoresizingMaskIntoConstraints = false
        runBar.addSubview(outputEstimateLabel)

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        runBar.addSubview(progressIndicator)

        runButton.bezelStyle = .rounded
        runButton.keyEquivalent = "\r"
        runButton.keyEquivalentModifierMask = .command
        runButton.target = self
        runButton.action = #selector(runOperationClicked(_:))
        runButton.translatesAutoresizingMaskIntoConstraints = false
        runButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64).isActive = true
        runBar.addSubview(runButton)

        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancelOperationClicked(_:))
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.isHidden = true
        runBar.addSubview(cancelButton)


        let statusToEstimate = statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: outputEstimateLabel.leadingAnchor, constant: -8)
        statusToEstimate.priority = .defaultHigh

        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: runBar.topAnchor),
            border.leadingAnchor.constraint(equalTo: runBar.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: runBar.trailingAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),

            statusLabel.leadingAnchor.constraint(equalTo: runBar.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: runBar.centerYAnchor),
            statusToEstimate,
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: progressIndicator.leadingAnchor, constant: -8),

            outputEstimateLabel.centerXAnchor.constraint(equalTo: runBar.centerXAnchor),
            outputEstimateLabel.centerYAnchor.constraint(equalTo: runBar.centerYAnchor),
            outputEstimateLabel.trailingAnchor.constraint(lessThanOrEqualTo: progressIndicator.leadingAnchor, constant: -8),

            progressIndicator.trailingAnchor.constraint(equalTo: cancelButton.leadingAnchor, constant: -8),
            progressIndicator.centerYAnchor.constraint(equalTo: runBar.centerYAnchor),

            cancelButton.trailingAnchor.constraint(equalTo: runButton.leadingAnchor, constant: -4),
            cancelButton.centerYAnchor.constraint(equalTo: runBar.centerYAnchor),

            runButton.trailingAnchor.constraint(equalTo: runBar.trailingAnchor, constant: -12),
            runButton.centerYAnchor.constraint(equalTo: runBar.centerYAnchor),
        ])

        runButton.isEnabled = false
    }

    // MARK: - Split View Layout

    private var didApplyInitialSplitPositions = false

    private func applyInitialSplitPositionsIfNeeded() {
        guard !didApplyInitialSplitPositions else { return }

        let viewHeight = view.bounds.height
        let middleWidth = middleSplitView.bounds.width
        guard viewHeight > LayoutDefaults.minGeometryForInitialLayout,
              middleWidth > LayoutDefaults.minGeometryForInitialLayout else { return }

        // Pin the top pane to its fixed height.
        mainSplitView.setPosition(LayoutDefaults.topPaneHeight, ofDividerAt: 0)

        // Keep operation list compact by default to prioritize preview/read content width.
        let sidebarWidth = max(
            LayoutDefaults.minSidebarWidth,
            min(middleWidth * LayoutDefaults.preferredSidebarFraction, LayoutDefaults.maxSidebarWidth)
        )
        middleSplitView.setPosition(sidebarWidth, ofDividerAt: 0)

        didApplyInitialSplitPositions = true
    }


    // MARK: - Parameter Bar Updates

    private func updateParameterBar() {
        // Remove all existing arranged subviews
        for view in parameterBar.arrangedSubviews {
            parameterBar.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        guard let kind = selectedOperation else {
            let label = NSTextField(labelWithString: "Select an operation from the list")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .tertiaryLabelColor
            parameterBar.addArrangedSubview(label)
            updateRunButtonState()
            return
        }

        // Clear field values when switching operations to prevent bleed-through
        fieldOneInput.stringValue = ""
        fieldTwoInput.stringValue = ""

        switch kind {
        case .subsampleProportion:
            fieldOneLabel.stringValue = "Proportion:"
            fieldOneInput.placeholderString = "0.10"
            fieldOneInput.stringValue = "0.10"
            parameterBar.addArrangedSubview(fieldOneLabel)
            parameterBar.addArrangedSubview(fieldOneInput)

        case .subsampleCount:
            fieldOneLabel.stringValue = "Count:"
            fieldOneInput.placeholderString = "10000"
            fieldOneInput.stringValue = "10000"
            parameterBar.addArrangedSubview(fieldOneLabel)
            parameterBar.addArrangedSubview(fieldOneInput)

        case .lengthFilter:
            fieldOneLabel.stringValue = "Min:"
            fieldTwoLabel.stringValue = "Max:"
            fieldOneInput.placeholderString = ""
            fieldTwoInput.placeholderString = ""
            parameterBar.addArrangedSubview(fieldOneLabel)
            parameterBar.addArrangedSubview(fieldOneInput)
            parameterBar.addArrangedSubview(fieldTwoLabel)
            parameterBar.addArrangedSubview(fieldTwoInput)

        case .searchText:
            fieldOneLabel.stringValue = "Pattern:"
            fieldOneInput.placeholderString = "SRR1770413"
            parameterBar.addArrangedSubview(fieldOneLabel)
            parameterBar.addArrangedSubview(fieldOneInput)
            parameterBar.addArrangedSubview(searchFieldPopup)
            parameterBar.addArrangedSubview(regexCheckbox)

        case .searchMotif:
            fieldOneLabel.stringValue = "Motif:"
            fieldOneInput.placeholderString = "ATGNNNT"
            parameterBar.addArrangedSubview(fieldOneLabel)
            parameterBar.addArrangedSubview(fieldOneInput)
            parameterBar.addArrangedSubview(regexCheckbox)
            parameterBar.addArrangedSubview(revCompCheckbox)

        case .deduplicate:
            parameterBar.addArrangedSubview(dedupDrawerButton)

        case .qualityTrim:
            fieldOneLabel.stringValue = "Q Threshold:"
            fieldOneInput.placeholderString = "20"
            fieldOneInput.stringValue = "20"
            fieldTwoLabel.stringValue = "Window:"
            fieldTwoInput.placeholderString = "4"
            fieldTwoInput.stringValue = "4"
            parameterBar.addArrangedSubview(fieldOneLabel)
            parameterBar.addArrangedSubview(fieldOneInput)
            parameterBar.addArrangedSubview(fieldTwoLabel)
            parameterBar.addArrangedSubview(fieldTwoInput)
            parameterBar.addArrangedSubview(qualityTrimModePopup)

        case .adapterTrim:
            fieldOneLabel.stringValue = "Adapter:"
            fieldOneInput.placeholderString = "(auto-detect)"
            parameterBar.addArrangedSubview(adapterModePopup)
            parameterBar.addArrangedSubview(fieldOneLabel)
            parameterBar.addArrangedSubview(fieldOneInput)

        case .fixedTrim:
            fieldOneLabel.stringValue = "5' Trim:"
            fieldOneInput.placeholderString = "0"
            fieldTwoLabel.stringValue = "3' Trim:"
            fieldTwoInput.placeholderString = "0"
            parameterBar.addArrangedSubview(fieldOneLabel)
            parameterBar.addArrangedSubview(fieldOneInput)
            parameterBar.addArrangedSubview(fieldTwoLabel)
            parameterBar.addArrangedSubview(fieldTwoInput)

        case .contaminantFilter:
            fieldOneLabel.stringValue = "K-mer:"
            fieldOneInput.placeholderString = "31"
            fieldOneInput.stringValue = "31"
            fieldTwoLabel.stringValue = "Mismatch:"
            fieldTwoInput.placeholderString = "1"
            fieldTwoInput.stringValue = "1"
            parameterBar.addArrangedSubview(contaminantModePopup)
            parameterBar.addArrangedSubview(fieldOneLabel)
            parameterBar.addArrangedSubview(fieldOneInput)
            parameterBar.addArrangedSubview(fieldTwoLabel)
            parameterBar.addArrangedSubview(fieldTwoInput)

        case .pairedEndMerge:
            fieldOneLabel.stringValue = "Min Overlap:"
            fieldOneInput.placeholderString = "12"
            fieldOneInput.stringValue = "12"
            parameterBar.addArrangedSubview(mergeStrictnessPopup)
            parameterBar.addArrangedSubview(fieldOneLabel)
            parameterBar.addArrangedSubview(fieldOneInput)

        case .pairedEndRepair:
            let label = NSTextField(labelWithString: "No parameters required")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            parameterBar.addArrangedSubview(label)

        case .primerRemoval:
            let status = NSTextField(labelWithString: currentPrimerTrimConfiguration == nil
                ? "Configure PCR primer trimming in the bottom drawer."
                : "Primer trim drawer configured.")
            status.font = .systemFont(ofSize: 11)
            status.textColor = .secondaryLabelColor
            parameterBar.addArrangedSubview(status)
            parameterBar.addArrangedSubview(primerTrimDrawerButton)

        case .sequencePresenceFilter:
            fieldOneLabel.stringValue = "Sequence:"
            fieldOneInput.placeholderString = "AGATCGGAAGAGC or path to FASTA"
            fieldOneInput.frame.size.width = 200
            fieldTwoLabel.stringValue = "Min Overlap:"
            fieldTwoInput.placeholderString = "16"
            fieldTwoInput.stringValue = "16"
            let searchEndPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            searchEndPopup.controlSize = .small
            searchEndPopup.translatesAutoresizingMaskIntoConstraints = false
            searchEndPopup.addItems(withTitles: ["5' end", "3' end"])
            let keepDiscardPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            keepDiscardPopup.controlSize = .small
            keepDiscardPopup.translatesAutoresizingMaskIntoConstraints = false
            keepDiscardPopup.addItems(withTitles: ["Keep matched", "Discard matched"])
            keepDiscardPopup.tag = 901
            searchEndPopup.tag = 902
            let rcCheckbox = NSButton(checkboxWithTitle: "Also search reverse complement", target: nil, action: nil)
            rcCheckbox.controlSize = .small
            rcCheckbox.tag = 903
            let noteLabel = NSTextField(labelWithString: "Reads are not trimmed")
            noteLabel.font = .systemFont(ofSize: 10)
            noteLabel.textColor = .tertiaryLabelColor
            parameterBar.addArrangedSubview(fieldOneLabel)
            parameterBar.addArrangedSubview(fieldOneInput)
            parameterBar.addArrangedSubview(searchEndPopup)
            parameterBar.addArrangedSubview(keepDiscardPopup)
            parameterBar.addArrangedSubview(fieldTwoLabel)
            parameterBar.addArrangedSubview(fieldTwoInput)
            parameterBar.addArrangedSubview(rcCheckbox)
            parameterBar.addArrangedSubview(noteLabel)

        case .errorCorrection:
            fieldOneLabel.stringValue = "K-mer Size:"
            fieldOneInput.placeholderString = "50"
            fieldOneInput.stringValue = "50"
            parameterBar.addArrangedSubview(fieldOneLabel)
            parameterBar.addArrangedSubview(fieldOneInput)

        case .orient:
            rebuildOrientReferencePopup()
            let refLabel = NSTextField(labelWithString: "Reference:")
            refLabel.font = .systemFont(ofSize: 11)
            refLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            orientReferencePopup.controlSize = .small
            orientReferencePopup.translatesAutoresizingMaskIntoConstraints = false
            orientReferencePopup.target = self
            orientReferencePopup.action = #selector(orientReferenceChanged(_:))
            orientBrowseButton.bezelStyle = .rounded
            orientBrowseButton.controlSize = .small
            orientBrowseButton.translatesAutoresizingMaskIntoConstraints = false
            orientBrowseButton.target = self
            orientBrowseButton.action = #selector(orientBrowseClicked(_:))
            fieldOneLabel.stringValue = "Word Length:"
            fieldOneInput.placeholderString = "12"
            fieldOneInput.stringValue = "12"
            let maskLabel = NSTextField(labelWithString: "Mask:")
            maskLabel.font = .systemFont(ofSize: 11)
            maskLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            orientMaskPopup.removeAllItems()
            orientMaskPopup.addItems(withTitles: ["dust", "none"])
            orientMaskPopup.controlSize = .small
            orientMaskPopup.translatesAutoresizingMaskIntoConstraints = false
            orientSaveUnorientedCheckbox.controlSize = .small
            orientSaveUnorientedCheckbox.state = .on
            parameterBar.addArrangedSubview(refLabel)
            parameterBar.addArrangedSubview(orientReferencePopup)
            parameterBar.addArrangedSubview(orientBrowseButton)
            parameterBar.addArrangedSubview(fieldOneLabel)
            parameterBar.addArrangedSubview(fieldOneInput)
            parameterBar.addArrangedSubview(maskLabel)
            parameterBar.addArrangedSubview(orientMaskPopup)
            parameterBar.addArrangedSubview(orientSaveUnorientedCheckbox)

        case .demultiplex:
            if let drawerConfig = currentDemuxConfig {
                // Show read-only summary of the drawer configuration
                let kitName = BarcodeKitRegistry.kit(byID: drawerConfig.barcodeKitID)?.displayName ?? drawerConfig.barcodeKitID
                let locationDesc: String
                switch drawerConfig.barcodeLocation {
                case .fivePrime: locationDesc = "5'"
                case .threePrime: locationDesc = "3'"
                case .bothEnds: locationDesc = "Both"
                }
                let summaryText = "\(kitName) | \(locationDesc) | e=\(String(format: "%.2f", drawerConfig.errorRate)) | \(drawerConfig.trimBarcodes ? "Trim" : "Keep")"
                let summaryLabel = NSTextField(labelWithString: summaryText)
                summaryLabel.font = .systemFont(ofSize: 11)
                summaryLabel.textColor = .secondaryLabelColor
                summaryLabel.lineBreakMode = .byTruncatingTail
                parameterBar.addArrangedSubview(summaryLabel)
            } else {
                let placeholder = NSTextField(labelWithString: "Configure demultiplexing in the Demux drawer")
                placeholder.font = .systemFont(ofSize: 11)
                placeholder.textColor = .secondaryLabelColor
                parameterBar.addArrangedSubview(placeholder)
            }

            // Always show a button to open/focus the drawer for either state
            let configureButton = NSButton(title: "Configure in Drawer\u{2026}", target: self, action: #selector(openDemuxDrawerClicked(_:)))
            configureButton.bezelStyle = .rounded
            configureButton.font = .systemFont(ofSize: 11)
            configureButton.translatesAutoresizingMaskIntoConstraints = false
            parameterBar.addArrangedSubview(configureButton)

        case .qualityReport:
            if hasQualityData {
                let label = NSTextField(labelWithString: "Quality data already computed. Sparkline charts are populated above.")
                label.font = .systemFont(ofSize: 11)
                label.textColor = .secondaryLabelColor
                parameterBar.addArrangedSubview(label)
            } else if qualityReportTask != nil {
                let label = NSTextField(labelWithString: "Computing quality report...")
                label.font = .systemFont(ofSize: 11)
                label.textColor = .secondaryLabelColor
                parameterBar.addArrangedSubview(label)
            } else {
                let label = NSTextField(labelWithString: "Scan all reads to compute per-position quality, length distribution, and quality score histograms.")
                label.font = .systemFont(ofSize: 11)
                label.textColor = .secondaryLabelColor
                parameterBar.addArrangedSubview(label)
            }

        case .assembleReads:
            let label = NSTextField(labelWithString: "Assemble reads de novo into contigs and scaffolds using SPAdes.")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            parameterBar.addArrangedSubview(label)

        case .mapReads:
            let label = NSTextField(labelWithString: "Map reads to a reference genome using minimap2. Produces a sorted, indexed BAM file.")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            parameterBar.addArrangedSubview(label)

        case .classifyReads:
            let label = NSTextField(labelWithString: "Run Kraken2/Bracken taxonomic classification and abundance profiling on this dataset.")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            parameterBar.addArrangedSubview(label)

        case .detectViruses:
            let label = NSTextField(labelWithString: "Run EsViritu viral detection with genome coverage analysis on this dataset.")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            parameterBar.addArrangedSubview(label)

        case .comprehensiveTriage:
            let label = NSTextField(labelWithString: "Run TaxTriage end-to-end clinical metagenomics triage with confidence scoring.")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            parameterBar.addArrangedSubview(label)

        case .naoMgsImport:
            let label = NSTextField(labelWithString: "Import results from NAO metagenomic surveillance pipeline (securebio/nao-mgs-workflow).")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            parameterBar.addArrangedSubview(label)

        case .humanReadScrub:
            let label = NSTextField(labelWithString: "Remove human-derived reads using NCBI sra-human-scrubber. Required before SRA submission.")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            parameterBar.addArrangedSubview(label)
        }

        // Add spacer to push controls left
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        parameterBar.addArrangedSubview(spacer)

        // Centralize run button state after all parameter UI is configured
        updateRunButtonState()
        // Update preview
        updatePreview()
    }

    private func updatePreview() {
        guard let kind = selectedOperation else {
            previewCanvas.update(operation: .none, statistics: statistics)
            return
        }

        var params = OperationPreviewView.Parameters()
        params.proportion = Double(fieldOneInput.stringValue) ?? 0.1
        params.count = Int(fieldOneInput.stringValue) ?? 1000
        params.minLength = Int(fieldOneInput.stringValue)
        params.maxLength = Int(fieldTwoInput.stringValue)
        params.qualityThreshold = Int(fieldOneInput.stringValue) ?? 20
        params.windowSize = Int(fieldTwoInput.stringValue) ?? 4
        params.trimMode = qualityTrimModePopup.titleOfSelectedItem ?? "Cut Right (3')"
        params.trim5Prime = Int(fieldOneInput.stringValue) ?? 0
        params.trim3Prime = Int(fieldTwoInput.stringValue) ?? 0
        params.dedupMode = dedupPreset.rawValue
        params.kmerSize = Int(fieldOneInput.stringValue) ?? 50
        params.searchPattern = fieldOneInput.stringValue
        params.searchField = searchFieldPopup.titleOfSelectedItem ?? "ID"
        params.searchRegex = regexCheckbox.state == .on
        params.reverseComplement = revCompCheckbox.state == .on

        previewCanvas.parameters = params
        previewCanvas.update(operation: kind.previewKind, statistics: statistics)

        // Update output estimate
        updateOutputEstimate(for: kind)
    }

    private func updateOutputEstimate(for kind: OperationKind) {
        guard let stats = statistics else {
            outputEstimateLabel.stringValue = ""
            return
        }

        switch kind {
        case .subsampleProportion:
            let p = Double(fieldOneInput.stringValue) ?? 0.1
            let estimated = Int(Double(stats.readCount) * p)
            outputEstimateLabel.stringValue = "Estimated output: ~\(formatCount(estimated)) reads (\(String(format: "%.1f", p * 100))%)"
        case .subsampleCount:
            let n = Int(fieldOneInput.stringValue) ?? 1000
            outputEstimateLabel.stringValue = "Estimated output: \(formatCount(min(n, stats.readCount))) reads"
        case .lengthFilter:
            let minLen = Int(fieldOneInput.stringValue.trimmingCharacters(in: .whitespaces))
            let maxLen = Int(fieldTwoInput.stringValue.trimmingCharacters(in: .whitespaces))
            if minLen != nil || maxLen != nil {
                let passingReads = stats.readLengthHistogram.reduce(0) { total, entry in
                    let length = entry.key
                    let count = entry.value
                    let passMin = minLen.map { length >= $0 } ?? true
                    let passMax = maxLen.map { length <= $0 } ?? true
                    return total + (passMin && passMax ? count : 0)
                }
                let pct = stats.readCount > 0 ? Double(passingReads) / Double(stats.readCount) * 100 : 0
                outputEstimateLabel.stringValue = "Estimated output: ~\(formatCount(passingReads)) reads (\(String(format: "%.1f", pct))%)"
            } else {
                outputEstimateLabel.stringValue = ""
            }
        case .fixedTrim:
            let from5 = Int(fieldOneInput.stringValue) ?? 0
            let from3 = Int(fieldTwoInput.stringValue) ?? 0
            let totalTrim = from5 + from3
            if totalTrim > 0, stats.meanReadLength > 0 {
                let avgOutput = max(0, Int(stats.meanReadLength) - totalTrim)
                outputEstimateLabel.stringValue = "Output reads: ~\(avgOutput) bp avg (from \(Int(stats.meanReadLength)) bp)"
            } else {
                outputEstimateLabel.stringValue = ""
            }
        default:
            outputEstimateLabel.stringValue = ""
        }
    }

    private func loadFASTAPreview(fastqURL: URL?, fallbackRecords: [FASTQRecord]) {
        fastaPreviewTask?.cancel()
        fastaPreviewTask = nil

        if let fastqURL {
            previewCanvas.setFASTAContent("Loading first 1,000 FASTQ reads as FASTA...")
            let sourceURL = fastqURL.standardizedFileURL
            fastaPreviewTask = Task.detached(priority: .utility) { [weak self] in
                do {
                    let fasta = try await Self.buildFASTAPreview(from: sourceURL, readLimit: 1_000)
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            guard self.fastqURL?.standardizedFileURL == sourceURL else { return }
                            self.previewCanvas.setFASTAContent(fasta)
                            self.fastaPreviewTask = nil
                        }
                    }
                } catch is CancellationError {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.fastaPreviewTask = nil
                        }
                    }
                } catch {
                    let errorMessage = "\(error)"
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            guard self.fastqURL?.standardizedFileURL == sourceURL else { return }
                            self.previewCanvas.setFASTAContent("Failed to load FASTA preview: \(errorMessage)")
                            self.fastaPreviewTask = nil
                        }
                    }
                }
            }
            return
        }

        if !fallbackRecords.isEmpty {
            let subset = Array(fallbackRecords.prefix(1_000))
            previewCanvas.setFASTAContent(Self.formatFASTA(records: subset))
        } else {
            previewCanvas.setFASTAContent("No FASTQ reads available for preview.")
        }
    }

    private static func buildFASTAPreview(from url: URL, readLimit: Int) async throws -> String {
        if let streamedFASTA = await buildFASTAPreviewWithSeqkit(from: url, readLimit: readLimit) {
            return streamedFASTA
        }

        let reader = FASTQReader(validateSequence: false)
        var records: [FASTQRecord] = []
        records.reserveCapacity(readLimit)
        for try await record in reader.records(from: url) {
            records.append(record)
            if records.count >= readLimit { break }
        }
        return formatFASTA(records: records)
    }

    private static func buildFASTAPreviewWithSeqkit(from url: URL, readLimit: Int) async -> String? {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("lungfish-fasta-preview-\(UUID().uuidString)", isDirectory: true)
        let sampledFASTQ = tempDir.appendingPathComponent("sample.fastq")
        let outputFASTA = tempDir.appendingPathComponent("sample.fasta")

        do {
            try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        defer { try? fm.removeItem(at: tempDir) }

        do {
            let runner = NativeToolRunner.shared
            let headResult = try await runner.run(
                .seqkit,
                arguments: ["head", "-n", String(max(1, readLimit)), url.path],
                timeout: 120
            )
            guard headResult.isSuccess, !headResult.stdout.isEmpty else {
                return nil
            }

            try headResult.stdout.write(to: sampledFASTQ, atomically: true, encoding: .utf8)

            let fastaResult = try await runner.run(
                .seqkit,
                arguments: ["fq2fa", "-w", "0", sampledFASTQ.path, "-o", outputFASTA.path],
                timeout: 120
            )
            guard fastaResult.isSuccess else {
                return nil
            }

            let fasta = try String(contentsOf: outputFASTA, encoding: .utf8)
            guard !fasta.isEmpty else { return "No FASTQ reads available for preview." }
            return fasta.hasSuffix("\n") ? fasta : fasta + "\n"
        } catch {
            return nil
        }
    }

    private static func formatFASTA(records: [FASTQRecord]) -> String {
        guard !records.isEmpty else { return "No FASTQ reads available for preview." }
        var lines: [String] = []
        lines.reserveCapacity(records.count * 2)
        for record in records {
            if let description = record.description, !description.isEmpty {
                lines.append(">\(record.identifier) \(description)")
            } else {
                lines.append(">\(record.identifier)")
            }
            lines.append(record.sequence)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Read Preview Table

    private func configureReadPreviewTable() {
        readPreviewTable.style = .plain
        readPreviewTable.usesAlternatingRowBackgroundColors = true
        readPreviewTable.rowHeight = 20
        readPreviewTable.headerView = NSTableHeaderView()
        readPreviewTable.allowsColumnReordering = false

        let colIndex = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rp_index"))
        colIndex.title = "#"
        colIndex.width = 50
        colIndex.maxWidth = 70
        readPreviewTable.addTableColumn(colIndex)

        let colID = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rp_readID"))
        colID.title = "Read ID"
        colID.width = 200
        colID.minWidth = 100
        colID.resizingMask = .autoresizingMask
        readPreviewTable.addTableColumn(colID)

        let colLen = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rp_length"))
        colLen.title = "Length"
        colLen.width = 60
        colLen.maxWidth = 80
        readPreviewTable.addTableColumn(colLen)

        let colQ = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rp_meanQ"))
        colQ.title = "Mean Q"
        colQ.width = 60
        colQ.maxWidth = 80
        readPreviewTable.addTableColumn(colQ)

        let colSeq = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("rp_sequence"))
        colSeq.title = "Sequence"
        colSeq.width = 400
        colSeq.minWidth = 100
        colSeq.resizingMask = .autoresizingMask
        readPreviewTable.addTableColumn(colSeq)

        readPreviewTable.dataSource = self
        readPreviewTable.delegate = self

        readPreviewScrollView.documentView = readPreviewTable
        readPreviewScrollView.hasVerticalScroller = true
        readPreviewScrollView.hasHorizontalScroller = true
        readPreviewScrollView.autohidesScrollers = true
        readPreviewScrollView.translatesAutoresizingMaskIntoConstraints = false
        readPreviewScrollView.isHidden = true
        middleContentContainer.addSubview(readPreviewScrollView)

        readPreviewSpinner.style = .spinning
        readPreviewSpinner.controlSize = .regular
        readPreviewSpinner.isDisplayedWhenStopped = false
        readPreviewSpinner.translatesAutoresizingMaskIntoConstraints = false
        readPreviewSpinner.isHidden = true
        middleContentContainer.addSubview(readPreviewSpinner)

        readPreviewPlaceholder.font = .systemFont(ofSize: 13)
        readPreviewPlaceholder.textColor = .tertiaryLabelColor
        readPreviewPlaceholder.alignment = .center
        readPreviewPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        readPreviewPlaceholder.isHidden = true
        middleContentContainer.addSubview(readPreviewPlaceholder)

        NSLayoutConstraint.activate([
            readPreviewScrollView.topAnchor.constraint(equalTo: middleContentContainer.topAnchor),
            readPreviewScrollView.leadingAnchor.constraint(equalTo: middleContentContainer.leadingAnchor),
            readPreviewScrollView.trailingAnchor.constraint(equalTo: middleContentContainer.trailingAnchor),
            readPreviewScrollView.bottomAnchor.constraint(equalTo: middleContentContainer.bottomAnchor),

            readPreviewSpinner.centerXAnchor.constraint(equalTo: middleContentContainer.centerXAnchor),
            readPreviewSpinner.centerYAnchor.constraint(equalTo: middleContentContainer.centerYAnchor),

            readPreviewPlaceholder.centerXAnchor.constraint(equalTo: middleContentContainer.centerXAnchor),
            readPreviewPlaceholder.centerYAnchor.constraint(equalTo: middleContentContainer.centerYAnchor),
            {
                let c = readPreviewPlaceholder.widthAnchor.constraint(lessThanOrEqualTo: middleContentContainer.widthAnchor, constant: -40)
                c.priority = .defaultHigh
                return c
            }(),
        ])
    }

    @objc private func middleTabChanged(_ sender: NSSegmentedControl) {
        let showReads = sender.selectedSegment == 1
        middleSplitView.isHidden = showReads
        readPreviewScrollView.isHidden = !showReads
        readPreviewPlaceholder.isHidden = true

        if showReads && !readPreviewLoaded {
            loadReadPreview()
        }
    }

    private func loadReadPreview() {
        guard let url = fastqURL else {
            readPreviewPlaceholder.stringValue = "No FASTQ file available for preview."
            readPreviewPlaceholder.isHidden = false
            readPreviewScrollView.isHidden = true
            return
        }

        readPreviewTask?.cancel()
        readPreviewSpinner.isHidden = false
        readPreviewSpinner.startAnimation(nil)
        readPreviewPlaceholder.isHidden = true
        setStatus("Loading read preview...")

        let sourceURL = url.standardizedFileURL
        readPreviewTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let runner = NativeToolRunner.shared
                let result = try await runner.run(
                    .seqkit,
                    arguments: ["head", "-n", "1000", sourceURL.path],
                    timeout: 120
                )

                guard result.isSuccess, !result.stdout.isEmpty else {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            self.readPreviewSpinner.stopAnimation(nil)
                            self.readPreviewSpinner.isHidden = true
                            self.readPreviewPlaceholder.stringValue = "Failed to extract reads from FASTQ file."
                            self.readPreviewPlaceholder.isHidden = false
                            self.readPreviewScrollView.isHidden = true
                            self.setStatus("Read preview failed")
                        }
                    }
                    return
                }

                let records = parseFASTQReadPreviewRecords(from: result.stdout)

                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        guard self.fastqURL?.standardizedFileURL == sourceURL else { return }
                        self.readPreviewRecords = records
                        self.readPreviewLoaded = true
                        self.readPreviewTable.reloadData()
                        self.readPreviewSpinner.stopAnimation(nil)
                        self.readPreviewSpinner.isHidden = true
                        self.readPreviewTask = nil
                        self.setStatus("Read preview: \(records.count) reads loaded")
                    }
                }
            } catch is CancellationError {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.readPreviewSpinner.stopAnimation(nil)
                        self.readPreviewSpinner.isHidden = true
                        self.readPreviewTask = nil
                    }
                }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.readPreviewSpinner.stopAnimation(nil)
                        self.readPreviewSpinner.isHidden = true
                        self.readPreviewPlaceholder.stringValue = "Failed to load read preview: \(error.localizedDescription)"
                        self.readPreviewPlaceholder.isHidden = false
                        self.readPreviewScrollView.isHidden = true
                        self.readPreviewTask = nil
                        self.setStatus("Read preview failed")
                    }
                }
            }
        }
    }

    // MARK: - Quality Report

    private func updateQualityReportButton() {
        // Quality report availability is now reflected via the sidebar operation state.
        // If quality data already exists, the parameter bar shows "already computed".
        if selectedOperation == .qualityReport {
            updateParameterBar()
        }
    }

    /// Selects the Quality Report operation in the sidebar and immediately runs it.
    private func selectAndRunQualityReport() {
        // Ensure the REPORTS category is expanded so the row is visible
        if !expandedCategories.contains("REPORTS") {
            expandedCategories.insert("REPORTS")
            saveExpansionState()
            operationSidebar.reloadData()
        }

        // Find the row index for .qualityReport in the sidebar (collapse-aware)
        var targetRow = -1
        var currentRow = 0
        for (header, items) in Self.categories {
            currentRow += 1 // header
            guard expandedCategories.contains(header) else { continue }
            for item in items {
                if item == .qualityReport {
                    targetRow = currentRow
                    break
                }
                currentRow += 1
            }
            if targetRow >= 0 { break }
        }

        guard targetRow >= 0 else { return }
        operationSidebar.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
        selectedOperation = .qualityReport
        updateParameterBar()

        // Run immediately
        computeQualityReport()
    }

    /// Runs the quality report computation (reused by sidebar Run button and sparkline callback).
    private func computeQualityReport() {
        guard let url = fastqURL else { return }
        guard qualityReportTask == nil else { return }

        runButton.isEnabled = false
        cancelButton.isHidden = false
        progressIndicator.startAnimation(nil)
        setStatus("Computing quality report...")

        let qrCliCmd = "# lungfish fastq quality-report \(url.path) (CLI command not yet available \u{2014} use GUI)"
        let opID = OperationCenter.shared.start(
            title: "Quality Report",
            detail: url.lastPathComponent,
            operationType: .qualityReport,
            cliCommand: qrCliCmd
        )

        let startTime = Date()

        qualityReportTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let reader = FASTQReader(validateSequence: false)
                let (fullStats, _) = try await reader.computeStatistics(
                    from: url,
                    sampleLimit: 0
                )

                var metadata = FASTQMetadataStore.load(for: url) ?? PersistedFASTQMetadata()
                metadata.computedStatistics = fullStats
                FASTQMetadataStore.save(metadata, for: url)

                let elapsed = Int(Date().timeIntervalSince(startTime))
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        OperationCenter.shared.complete(id: opID, detail: "Complete — \(fullStats.readCount) reads")
                        self.qualityReportTask = nil
                        self.statistics = fullStats
                        self.summaryBar.update(with: fullStats)
                        self.sparklineStrip.update(with: fullStats)
                        self.previewCanvas.update(operation: self.selectedOperation?.previewKind ?? .none, statistics: fullStats)
                        self.updateRunButtonState()
                        self.cancelButton.isHidden = true
                        self.progressIndicator.stopAnimation(nil)
                        self.updateQualityReportButton()
                        self.setStatus("Quality report complete (\(elapsed)s)")
                        self.onStatisticsUpdated?(fullStats)
                    }
                }
            } catch is CancellationError {
                // User cancelled — return silently, don't show error
                let elapsed = Int(Date().timeIntervalSince(startTime))
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        OperationCenter.shared.complete(id: opID, detail: "Cancelled")
                        self.qualityReportTask = nil
                        self.updateRunButtonState()
                        self.cancelButton.isHidden = true
                        self.progressIndicator.stopAnimation(nil)
                        self.setStatus("Quality report cancelled (\(elapsed)s)")
                    }
                }
            } catch {
                let errorMessage = "\(error)"
                let elapsed = Int(Date().timeIntervalSince(startTime))
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        OperationCenter.shared.fail(id: opID, detail: errorMessage)
                        self.qualityReportTask = nil
                        self.updateRunButtonState()
                        self.cancelButton.isHidden = true
                        self.progressIndicator.stopAnimation(nil)
                        self.setStatus("Quality report failed (\(elapsed)s)")
                        // Error details are in the Operations Panel — auto-open it
                        (NSApp.delegate as? AppDelegate)?.showOperationsPanel(nil)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func cancelOperationClicked(_ sender: Any) {
        if let task = qualityReportTask {
            task.cancel()
            qualityReportTask = nil
            updateRunButtonState()
            cancelButton.isHidden = true
            progressIndicator.stopAnimation(nil)
            setStatus("Quality report cancelled")
            return
        }
        if let task = operationTask {
            task.cancel()
            operationTask = nil
            updateRunButtonState()
            cancelButton.isHidden = true
            progressIndicator.stopAnimation(nil)
            setStatus("Operation cancelled")
        }
    }



    @objc private func parameterPopupChanged(_ sender: NSPopUpButton) {
        updatePreview()
    }


    @objc private func parameterCheckboxChanged(_ sender: NSButton) {
        updatePreview()
    }

    /// Programmatically triggers the current operation run. Called after scout "Proceed".
    public func triggerCurrentOperationRun() {
        runOperationClicked(self)
    }

    @objc private func runOperationClicked(_ sender: Any) {
        // Quality report has its own execution path
        if selectedOperation == .qualityReport {
            computeQualityReport()
            return
        }
        // Classification operations dispatch to tool-specific launch methods
        if selectedOperation == .classifyReads {
            NSApp.sendAction(#selector(AppDelegate.launchKraken2Classification(_:)), to: nil, from: nil)
            return
        }
        if selectedOperation == .detectViruses {
            NSApp.sendAction(#selector(AppDelegate.launchEsVirituDetection(_:)), to: nil, from: nil)
            return
        }
        if selectedOperation == .comprehensiveTriage {
            NSApp.sendAction(#selector(AppDelegate.launchTaxTriage(_:)), to: nil, from: nil)
            return
        }
        if selectedOperation == .assembleReads {
            NSApp.sendAction(#selector(AppDelegate.runSPAdes(_:)), to: nil, from: nil)
            return
        }
        if selectedOperation == .mapReads {
            NSApp.sendAction(#selector(AppDelegate.launchMinimap2Mapping(_:)), to: nil, from: nil)
            return
        }
        if selectedOperation == .naoMgsImport {
            NSApp.sendAction(#selector(AppDelegate.launchNaoMgsImport(_:)), to: nil, from: nil)
            return
        }
        // Demux requires a configuration from the drawer
        if selectedOperation == .demultiplex
            && currentDemuxConfig == nil {
            setStatus("Configure demultiplexing in the Demux panel below")
            shakeButton(runButton)
            return
        }
        guard operationTask == nil else { return }
        guard let request = buildOperationRequest() else {
            shakeButton(runButton)
            return
        }
        guard let onRunOperation else {
            setStatus("No FASTQ source selected")
            return
        }

        runButton.isEnabled = false
        cancelButton.isHidden = false
        progressIndicator.startAnimation(nil)
        setStatus("Running: \(description(for: request))")

        let startTime = Date()

        operationTask = Task { [weak self, onRunOperation] in
            do {
                try await onRunOperation(request)
                guard let self else { return }
                let elapsed = Int(Date().timeIntervalSince(startTime))
                self.operationTask = nil
                self.updateRunButtonState()
                self.cancelButton.isHidden = true
                self.progressIndicator.stopAnimation(nil)
                self.setStatus("Done: \(self.description(for: request)) (\(elapsed)s)")
            } catch is CancellationError {
                guard let self else { return }
                let elapsed = Int(Date().timeIntervalSince(startTime))
                self.operationTask = nil
                self.updateRunButtonState()
                self.cancelButton.isHidden = true
                self.progressIndicator.stopAnimation(nil)
                self.setStatus("Cancelled (\(elapsed)s)")
            } catch {
                guard let self else { return }
                let elapsed = Int(Date().timeIntervalSince(startTime))
                self.operationTask = nil
                self.updateRunButtonState()
                self.cancelButton.isHidden = true
                self.progressIndicator.stopAnimation(nil)
                self.setStatus("Failed (\(elapsed)s) — see Operations Panel")
                // Error details are in the Operations Panel — auto-open it
                (NSApp.delegate as? AppDelegate)?.showOperationsPanel(nil)
            }
        }
    }


    @objc private func openDemuxDrawerClicked(_ sender: Any) {
        onOpenDemuxDrawer?()
    }

    @objc private func openPrimerTrimDrawer(_ sender: Any) {
        onOpenPrimerTrimDrawer?()
    }

    @objc private func openDedupDrawer(_ sender: Any) {
        onOpenDedupDrawer?()
    }

    /// Update deduplication parameters from the drawer preset selector.
    public func updateDedupConfig(preset: FASTQDeduplicatePreset, substitutions: Int, optical: Bool, opticalDistance: Int) {
        dedupPreset = preset
        dedupSubstitutions = substitutions
        dedupOptical = optical
        dedupOpticalDistance = opticalDistance
        updatePreview()
    }

    // MARK: - Orient Reference Management

    private func rebuildOrientReferencePopup() {
        orientReferencePopup.removeAllItems()
        orientProjectReferences = []

        let projectURL = orientProjectURL()

        if let projectURL {
            orientProjectReferences = ReferenceSequenceFolder.listReferences(in: projectURL)
            for ref in orientProjectReferences {
                orientReferencePopup.addItem(withTitle: ref.manifest.name)
            }
        }

        if orientProjectReferences.isEmpty {
            orientReferencePopup.addItem(withTitle: "No project references")
            orientReferencePopup.isEnabled = false
        } else {
            orientReferencePopup.isEnabled = true
        }

        // If an external reference was previously selected, add it as an extra item
        if let orientReferenceURL,
           let projectURL,
           !ReferenceSequenceFolder.isProjectReference(orientReferenceURL, in: projectURL) {
            orientReferencePopup.addItem(withTitle: orientReferenceURL.lastPathComponent)
            orientReferencePopup.selectItem(at: orientReferencePopup.numberOfItems - 1)
            orientReferencePopup.isEnabled = true
        } else if let orientReferenceURL, projectURL == nil {
            orientReferencePopup.addItem(withTitle: orientReferenceURL.lastPathComponent)
            orientReferencePopup.selectItem(at: orientReferencePopup.numberOfItems - 1)
            orientReferencePopup.isEnabled = true
        }
    }

    private func orientProjectURL() -> URL? {
        let candidateURL = sourceURL?.standardizedFileURL ?? fastqURL?.standardizedFileURL
        guard let candidateURL else { return nil }

        if FASTQBundle.isBundleURL(candidateURL) {
            return candidateURL.deletingLastPathComponent()
        }

        let parentDirectory = candidateURL.deletingLastPathComponent()
        if parentDirectory.pathExtension.lowercased() == FASTQBundle.directoryExtension {
            return parentDirectory.deletingLastPathComponent()
        }

        return parentDirectory
    }

    @objc private func orientReferenceChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        if index >= 0, index < orientProjectReferences.count {
            let ref = orientProjectReferences[index]
            orientReferenceURL = ReferenceSequenceFolder.fastaURL(in: ref.url)
        }
        updateRunButtonState()
    }

    @objc private func orientBrowseClicked(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = FASTAFileTypes.readableContentTypes
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a reference FASTA for read orientation"
        panel.beginSheetModal(for: self.view.window ?? NSApp.mainWindow!) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.orientReferenceURL = url
            self.rebuildOrientReferencePopup()
            if !self.orientProjectReferences.isEmpty || self.orientReferencePopup.numberOfItems > 0 {
                self.orientReferencePopup.selectItem(at: self.orientReferencePopup.numberOfItems - 1)
            }
            self.orientReferencePopup.isEnabled = true
            self.updateRunButtonState()
        }
    }


    // MARK: - Sidebar Row Mapping

    /// Maps a flat table row index to an OperationKind, accounting for category
    /// headers and collapsed categories.
    private func operationKindForRow(_ row: Int) -> OperationKind? {
        var currentRow = 0
        for (header, items) in Self.categories {
            if currentRow == row { return nil } // header row
            currentRow += 1 // header
            guard expandedCategories.contains(header) else { continue }
            for item in items {
                if currentRow == row { return item }
                currentRow += 1
            }
        }
        return nil
    }

    /// Total number of rows in the sidebar (headers + visible items).
    private var sidebarRowCount: Int {
        Self.categories.reduce(0) { total, cat in
            let itemCount = expandedCategories.contains(cat.header) ? cat.items.count : 0
            return total + 1 + itemCount
        }
    }

    /// Returns whether a row is a group header.
    private func isGroupRow(_ row: Int) -> Bool {
        var currentRow = 0
        for (header, items) in Self.categories {
            if currentRow == row { return true }
            currentRow += 1
            if expandedCategories.contains(header) {
                currentRow += items.count
            }
        }
        return false
    }

    /// Returns the category header name for a group row, or nil if not a group row.
    private func categoryHeaderForRow(_ row: Int) -> String? {
        var currentRow = 0
        for (header, items) in Self.categories {
            if currentRow == row { return header }
            currentRow += 1
            if expandedCategories.contains(header) {
                currentRow += items.count
            }
        }
        return nil
    }

    /// Returns the category header or operation title for a row.
    private func titleForRow(_ row: Int) -> String {
        var currentRow = 0
        for (header, items) in Self.categories {
            if currentRow == row { return header }
            currentRow += 1
            guard expandedCategories.contains(header) else { continue }
            for item in items {
                if currentRow == row { return item.title }
                currentRow += 1
            }
        }
        return ""
    }

    /// Returns the SF Symbol name for an operation row.
    private func sfSymbolForRow(_ row: Int) -> String? {
        operationKindForRow(row)?.sfSymbol
    }

    /// Toggles expansion of a category, animating row insertion or removal.
    private func toggleCategory(_ header: String) {
        guard let catIndex = Self.categories.firstIndex(where: { $0.header == header }) else { return }
        let items = Self.categories[catIndex].items
        guard !items.isEmpty else { return }

        // Calculate the row index of this header
        var headerRow = 0
        for i in 0..<catIndex {
            headerRow += 1
            if expandedCategories.contains(Self.categories[i].header) {
                headerRow += Self.categories[i].items.count
            }
        }

        let wasExpanded = expandedCategories.contains(header)

        if wasExpanded {
            // Collapse: remove item rows
            let firstItemRow = headerRow + 1
            let rowRange = IndexSet(integersIn: firstItemRow..<(firstItemRow + items.count))

            // Deselect any selected row that will be removed
            let selectedRow = operationSidebar.selectedRow
            if selectedRow >= firstItemRow && selectedRow < firstItemRow + items.count {
                selectedOperation = nil
                updateParameterBar()
            }

            expandedCategories.remove(header)
            operationSidebar.beginUpdates()
            operationSidebar.removeRows(at: rowRange, withAnimation: .slideUp)
            operationSidebar.endUpdates()

            // Reload the header row to update disclosure triangle rotation
            operationSidebar.reloadData(forRowIndexes: IndexSet(integer: headerRow),
                                         columnIndexes: IndexSet(integersIn: 0..<operationSidebar.numberOfColumns))
        } else {
            // Expand: insert item rows
            expandedCategories.insert(header)
            let firstItemRow = headerRow + 1
            let rowRange = IndexSet(integersIn: firstItemRow..<(firstItemRow + items.count))

            operationSidebar.beginUpdates()
            operationSidebar.insertRows(at: rowRange, withAnimation: .slideDown)
            operationSidebar.endUpdates()

            // Reload the header row to update disclosure triangle rotation
            operationSidebar.reloadData(forRowIndexes: IndexSet(integer: headerRow),
                                         columnIndexes: IndexSet(integersIn: 0..<operationSidebar.numberOfColumns))
        }

        saveExpansionState()
    }

    // MARK: - Request Building

    private func buildOperationRequest() -> FASTQDerivativeRequest? {
        guard let kind = selectedOperation else {
            setStatus("No operation selected.", isError: true)
            return nil
        }

        switch kind {
        case .qualityReport:
            // Quality report is not a derivative operation; handled via computeQualityReport()
            return nil

        case .classifyReads:
            // Classify & Profile Reads is dispatched via ToolsMenuActions; not a derivative operation
            return nil

        case .detectViruses:
            // EsViritu is dispatched via the unified metagenomics wizard; not a derivative operation
            return nil

        case .comprehensiveTriage:
            // TaxTriage is dispatched via the unified metagenomics wizard; not a derivative operation
            return nil

        case .humanReadScrub:
            return .humanReadScrub(databaseID: "sra-human-scrubber", removeReads: true)

        case .subsampleProportion:
            guard let value = Double(fieldOneInput.stringValue), value > 0, value <= 1 else {
                setStatus("Invalid proportion. Enter a value in (0, 1].", isError: true)
                return nil
            }
            return .subsampleProportion(value)

        case .subsampleCount:
            guard let value = Int(fieldOneInput.stringValue), value > 0 else {
                setStatus("Invalid read count. Enter an integer > 0.", isError: true)
                return nil
            }
            return .subsampleCount(value)

        case .lengthFilter:
            let minValue = Int(fieldOneInput.stringValue.trimmingCharacters(in: .whitespaces))
            let maxValue = Int(fieldTwoInput.stringValue.trimmingCharacters(in: .whitespaces))
            if minValue == nil, maxValue == nil {
                setStatus("Provide min, max, or both for length filter.", isError: true)
                return nil
            }
            if let minValue, let maxValue, minValue > maxValue {
                setStatus("Min length cannot be greater than max length.", isError: true)
                return nil
            }
            return .lengthFilter(min: minValue, max: maxValue)

        case .searchText:
            let query = fieldOneInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                setStatus("Search pattern cannot be empty.", isError: true)
                return nil
            }
            let field: FASTQSearchField = searchFieldPopup.indexOfSelectedItem == 1 ? .description : .id
            return .searchText(query: query, field: field, regex: regexCheckbox.state == .on)

        case .searchMotif:
            let pattern = fieldOneInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else {
                setStatus("Motif pattern cannot be empty.", isError: true)
                return nil
            }
            return .searchMotif(pattern: pattern, regex: regexCheckbox.state == .on)

        case .deduplicate:
            return .deduplicate(
                preset: dedupPreset,
                substitutions: dedupSubstitutions,
                optical: dedupOptical,
                opticalDistance: dedupOpticalDistance
            )

        case .qualityTrim:
            let threshold = Int(fieldOneInput.stringValue) ?? 20
            let windowSize = Int(fieldTwoInput.stringValue) ?? 4
            guard threshold > 0, windowSize > 0 else {
                setStatus("Quality threshold and window size must be > 0.", isError: true)
                return nil
            }
            let trimMode: FASTQQualityTrimMode
            switch qualityTrimModePopup.indexOfSelectedItem {
            case 1: trimMode = .cutFront
            case 2: trimMode = .cutTail
            case 3: trimMode = .cutBoth
            default: trimMode = .cutRight
            }
            return .qualityTrim(threshold: threshold, windowSize: windowSize, mode: trimMode)

        case .adapterTrim:
            let adapterMode: FASTQAdapterMode
            let sequence: String?
            if adapterModePopup.indexOfSelectedItem == 1 {
                adapterMode = .specified
                let seq = fieldOneInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !seq.isEmpty else {
                    setStatus("Specify an adapter sequence or use Auto-Detect.", isError: true)
                    return nil
                }
                sequence = seq
            } else {
                adapterMode = .autoDetect
                sequence = nil
            }
            return .adapterTrim(mode: adapterMode, sequence: sequence, sequenceR2: nil, fastaFilename: nil)

        case .fixedTrim:
            let from5 = Int(fieldOneInput.stringValue) ?? 0
            let from3 = Int(fieldTwoInput.stringValue) ?? 0
            guard from5 >= 0, from3 >= 0 else {
                setStatus("Trim values must be >= 0.", isError: true)
                return nil
            }
            guard from5 > 0 || from3 > 0 else {
                setStatus("At least one trim value must be > 0.", isError: true)
                return nil
            }
            return .fixedTrim(from5Prime: from5, from3Prime: from3)

        case .contaminantFilter:
            let kmerSize = Int(fieldOneInput.stringValue) ?? 31
            let hammingDist = Int(fieldTwoInput.stringValue) ?? 1
            guard kmerSize > 0, kmerSize <= 63 else {
                setStatus("Kmer size must be between 1 and 63.", isError: true)
                return nil
            }
            guard hammingDist >= 0, hammingDist <= 3 else {
                setStatus("Mismatch tolerance must be 0-3.", isError: true)
                return nil
            }
            if contaminantModePopup.indexOfSelectedItem == 1 {
                setStatus("Custom reference mode requires a file picker (not yet implemented). Use PhiX mode.", isError: true)
                return nil
            }
            return .contaminantFilter(mode: .phix, referenceFasta: nil, kmerSize: kmerSize, hammingDistance: hammingDist)

        case .pairedEndMerge:
            let minOverlap = Int(fieldOneInput.stringValue) ?? 12
            guard minOverlap > 0 else {
                setStatus("Minimum overlap must be > 0.", isError: true)
                return nil
            }
            let strictness: FASTQMergeStrictness = mergeStrictnessPopup.indexOfSelectedItem == 1 ? .strict : .normal
            return .pairedEndMerge(strictness: strictness, minOverlap: minOverlap)

        case .pairedEndRepair:
            return .pairedEndRepair

        case .primerRemoval:
            guard let configuration = currentPrimerTrimConfiguration else {
                setStatus("Configure PCR primer trimming in the Primer Trim drawer first.", isError: true)
                return nil
            }
            return .primerRemoval(configuration: configuration)

        case .sequencePresenceFilter:
            let seqInput = fieldOneInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seqInput.isEmpty else {
                setStatus("Enter a sequence or path to a FASTA file.", isError: true)
                return nil
            }
            let minOverlap = Int(fieldTwoInput.stringValue) ?? 16
            guard minOverlap > 0 else {
                setStatus("Minimum overlap must be > 0.", isError: true)
                return nil
            }
            // Determine if input is a file path or literal sequence
            let isFilePath = seqInput.contains("/") || seqInput.hasSuffix(".fasta") || seqInput.hasSuffix(".fa")
            let searchEndPopup = parameterBar.subviews.first(where: { ($0 as? NSPopUpButton)?.tag == 902 }) as? NSPopUpButton
            let keepDiscardPopup = parameterBar.subviews.first(where: { ($0 as? NSPopUpButton)?.tag == 901 }) as? NSPopUpButton
            let rcCheckbox = parameterBar.subviews.first(where: { ($0 as? NSButton)?.tag == 903 }) as? NSButton
            let searchEnd: FASTQAdapterSearchEnd = searchEndPopup?.indexOfSelectedItem == 1 ? .threePrime : .fivePrime
            let keepMatched = keepDiscardPopup?.indexOfSelectedItem == 0
            let searchRC = rcCheckbox?.state == .on
            return .sequencePresenceFilter(
                sequence: isFilePath ? nil : seqInput,
                fastaPath: isFilePath ? seqInput : nil,
                searchEnd: searchEnd,
                minOverlap: minOverlap,
                errorRate: 0.15,
                keepMatched: keepMatched,
                searchReverseComplement: searchRC
            )

        case .errorCorrection:
            let kmerSize = Int(fieldOneInput.stringValue) ?? 50
            guard kmerSize > 0, kmerSize <= 62 else {
                setStatus("K-mer size must be between 1 and 62 (tadpole limit).", isError: true)
                return nil
            }
            return .errorCorrection(kmerSize: kmerSize)

        case .orient:
            guard let refURL = orientReferenceURL else {
                setStatus("Select a reference FASTA before running orient.", isError: true)
                return nil
            }
            let wordLength = Int(fieldOneInput.stringValue) ?? 12
            let dbMask = orientMaskPopup.titleOfSelectedItem ?? "dust"
            let saveUnoriented = orientSaveUnorientedCheckbox.state == .on
            return .orient(referenceURL: refURL, wordLength: wordLength, dbMask: dbMask, saveUnoriented: saveUnoriented)

        case .assembleReads:
            // Assembly is dispatched via AssemblySheetPresenter; not a derivative operation
            return nil

        case .mapReads:
            // Map Reads is dispatched via the MapReadsWizardSheet; not a derivative operation
            return nil

        case .naoMgsImport:
            // NAO-MGS import is dispatched via the NaoMgsImportSheet; not a derivative operation
            return nil

        case .demultiplex:
            guard let step = currentDemuxConfig else {
                setStatus("Configure demultiplexing in the Demux drawer first.", isError: true)
                return nil
            }
            let location: String
            switch step.barcodeLocation {
            case .fivePrime: location = "fivePrime"
            case .threePrime: location = "threePrime"
            case .bothEnds: location = "bothEnds"
            }
            return .demultiplex(
                kitID: step.barcodeKitID,
                customCSVPath: nil,
                location: location,
                symmetryMode: step.symmetryMode,
                maxDistanceFrom5Prime: step.maxSearchDistance5Prime,
                maxDistanceFrom3Prime: step.maxSearchDistance3Prime,
                errorRate: step.errorRate,
                trimBarcodes: step.trimBarcodes,
                sampleAssignments: step.sampleAssignments,
                kitOverride: nil
            )
        }
    }

    private func description(for request: FASTQDerivativeRequest) -> String {
        switch request {
        case .subsampleProportion(let p):
            return "Subsample by proportion (\(String(format: "%.4f", p)))"
        case .subsampleCount(let n):
            return "Subsample by count (\(n))"
        case .lengthFilter(let min, let max):
            return "Length filter (min: \(min.map(String.init) ?? "-"), max: \(max.map(String.init) ?? "-"))"
        case .searchText(let query, let field, let regex):
            return "Search \(field.rawValue) = \(query)\(regex ? " (regex)" : "")"
        case .searchMotif(let pattern, let regex):
            return "Motif \(pattern)\(regex ? " (regex)" : "")"
        case .deduplicate(let preset, let substitutions, let optical, let opticalDistance):
            if optical {
                return "Deduplicate optical (dist: \(opticalDistance), subs: \(substitutions))"
            }
            return "Deduplicate \(preset.rawValue) (subs: \(substitutions))"
        case .qualityTrim(let threshold, let windowSize, let mode):
            return "Quality trim Q\(threshold) w\(windowSize) (\(mode.rawValue))"
        case .adapterTrim(let mode, _, _, _):
            return "Adapter trim (\(mode.rawValue))"
        case .fixedTrim(let from5Prime, let from3Prime):
            return "Fixed trim (5': \(from5Prime), 3': \(from3Prime))"
        case .contaminantFilter(let mode, _, let kmerSize, let hammingDistance):
            return "Contaminant filter (\(mode.rawValue), k=\(kmerSize), hdist=\(hammingDistance))"
        case .pairedEndMerge(let strictness, let minOverlap):
            return "PE merge (\(strictness.rawValue), min overlap: \(minOverlap))"
        case .pairedEndRepair:
            return "PE read repair"
        case .primerRemoval(let configuration):
            let source = configuration.source == .literal
                ? (configuration.forwardSequence ?? "literal")
                : (configuration.referenceFasta ?? "reference")
            return "PCR primer trim (\(configuration.mode.rawValue), \(configuration.readMode.rawValue), \(source))"
        case .errorCorrection(let kmerSize):
            return "Error correction (k=\(kmerSize))"
        case .interleaveReformat(let direction):
            return direction == .interleave ? "Interleave R1/R2" : "Deinterleave to R1/R2"
        case .demultiplex(
            let kitID,
            _,
            let location,
            _,
            let maxDistanceFrom5Prime,
            let maxDistanceFrom3Prime,
            let errorRate,
            _,
            let sampleAssignments,
            _
        ):
            let sampleCount = sampleAssignments?.count ?? 0
            let source = sampleCount > 0 ? ", \(sampleCount) sample-pairs" : ""
            return "Demultiplex (\(kitID), \(location), w5=\(maxDistanceFrom5Prime), w3=\(maxDistanceFrom3Prime), e=\(String(format: "%.2f", errorRate))\(source))"
        case .sequencePresenceFilter(let sequence, _, let searchEnd, let minOverlap, let errorRate, let keepMatched, let searchRC):
            let endLabel = searchEnd == .fivePrime ? "5'" : "3'"
            let action = keepMatched ? "keep" : "discard"
            let seq = sequence.map { String($0.prefix(20)) } ?? "FASTA"
            let rcLabel = searchRC ? " +RC" : ""
            return "Sequence filter (\(endLabel), \(action) matched, \(seq)\(rcLabel), ov=\(minOverlap), e=\(String(format: "%.2f", errorRate)))"
        case .orient(let referenceURL, let wordLength, let dbMask, _):
            return "Orient against \(referenceURL.lastPathComponent) (w=\(wordLength), mask=\(dbMask))"
        case .humanReadScrub(let databaseID, let removeReads):
            return "Human read scrub (db: \(databaseID), \(removeReads ? "remove" : "mask with N"))"
        }
    }

    // MARK: - Run Button State

    /// Centralizes Run button enable/disable logic based on the selected operation
    /// and current configuration state. Called at the end of updateParameterBar()
    /// and whenever currentDemuxConfig changes.
    private func updateRunButtonState() {
        // Do not override state while an operation is in progress
        guard operationTask == nil, qualityReportTask == nil else { return }

        guard let kind = selectedOperation else {
            runButton.isEnabled = false
            return
        }

        switch kind {
        case .qualityReport:
            // Disabled when data already exists or report is running
            runButton.isEnabled = !hasQualityData && qualityReportTask == nil
            runButton.title = "Run"
        case .classifyReads:
            runButton.isEnabled = true
            runButton.title = "Run"
        case .detectViruses:
            runButton.isEnabled = true
            runButton.title = "Run"
        case .comprehensiveTriage:
            runButton.isEnabled = true
            runButton.title = "Run"
        case .humanReadScrub:
            runButton.isEnabled = true
            runButton.title = "Run"
        case .orient:
            runButton.isEnabled = orientReferenceURL != nil
            runButton.title = "Run"
        case .demultiplex:
            runButton.isEnabled = currentDemuxConfig != nil
            runButton.title = "Run"
        case .primerRemoval:
            runButton.isEnabled = currentPrimerTrimConfiguration != nil
            runButton.title = "Run"
        default:
            runButton.isEnabled = true
            runButton.title = "Run"
        }
    }

    // MARK: - Helpers


    private var hasQualityData: Bool {
        guard let stats = statistics else { return false }
        return !stats.perPositionQuality.isEmpty && !stats.qualityScoreHistogram.isEmpty
    }

    private func setStatus(_ line: String, isError: Bool = false) {
        statusLabel.stringValue = line
        statusLabel.textColor = isError ? .systemRed : .tertiaryLabelColor
        if isError {
            // Brief font size emphasis for errors
            statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        } else {
            statusLabel.font = .systemFont(ofSize: 10)
        }
    }

    private func shakeButton(_ button: NSButton) {
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.duration = 0.4
        animation.values = [-6, 6, -4, 4, -2, 2, 0]
        button.layer?.add(animation, forKey: "shake")
    }

    private func formatCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fK", Double(count) / 1_000) }
        return "\(count)"
    }
}

// MARK: - NSTableViewDataSource & Delegate (Operation Sidebar + Read Preview)

extension FASTQDatasetViewController: NSTableViewDataSource, NSTableViewDelegate {

    public func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === readPreviewTable {
            return readPreviewRecords.count
        }
        return sidebarRowCount
    }

    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if tableView === readPreviewTable { return false }
        return isGroupRow(row)
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === readPreviewTable {
            return readPreviewCellView(for: tableColumn, row: row)
        }

        let isGroup = isGroupRow(row)
        let title = titleForRow(row)
        let columnID = tableColumn?.identifier.rawValue ?? ""

        if isGroup {
            if columnID == "icon" {
                // Disclosure triangle in the icon column
                let isExpanded = expandedCategories.contains(title)
                let triangleName = isExpanded ? "chevron.down" : "chevron.right"
                let imageView = NSImageView()
                imageView.image = NSImage(systemSymbolName: triangleName, accessibilityDescription: isExpanded ? "Collapse" : "Expand")?
                    .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
                imageView.contentTintColor = .tertiaryLabelColor
                imageView.imageScaling = .scaleProportionallyDown
                return imageView
            }
            let cell = NSTextField(labelWithString: title)
            cell.font = .systemFont(ofSize: 11, weight: .semibold)
            cell.textColor = .secondaryLabelColor
            return cell
        }

        if columnID == "icon" {
            if let symbolName = sfSymbolForRow(row) {
                let imageView = NSImageView()
                imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
                imageView.contentTintColor = .secondaryLabelColor
                imageView.imageScaling = .scaleProportionallyDown
                return imageView
            }
            return nil
        }

        let cell = NSTextField(labelWithString: title)
        cell.font = .systemFont(ofSize: 12)
        cell.textColor = .labelColor
        cell.lineBreakMode = .byTruncatingTail
        if let kind = operationKindForRow(row) {
            cell.toolTip = kind.tooltip
        }
        return cell
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView === readPreviewTable { return 20 }
        return isGroupRow(row) ? 28 : 24
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if tableView === readPreviewTable { return true }
        if isGroupRow(row) {
            // Toggle expansion when the user clicks on a group header row
            if let header = categoryHeaderForRow(row) {
                toggleCategory(header)
            }
            return false
        }
        return true
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView,
              tableView === operationSidebar else { return }
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        selectedOperation = operationKindForRow(row)
        updateParameterBar()
        // Clear stale error status/banner from previous operation
        dismissErrorBanner()
        if let stats = statistics {
            setStatus("Loaded: \(stats.readCount) reads")
        } else {
            setStatus("")
        }
        if selectedOperation == .demultiplex { onOpenDemuxDrawer?() }
        if selectedOperation == .primerRemoval { onOpenPrimerTrimDrawer?() }
        if selectedOperation == .deduplicate { onOpenDedupDrawer?() }
    }

    // MARK: - Read Preview Cell Views

    private func readPreviewCellView(for tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < readPreviewRecords.count else { return nil }
        let record = readPreviewRecords[row]
        let columnID = tableColumn?.identifier.rawValue ?? ""

        switch columnID {
        case "rp_index":
            let cell = NSTextField(labelWithString: "\(record.index)")
            cell.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cell.textColor = .secondaryLabelColor
            cell.alignment = .right
            return cell

        case "rp_readID":
            let cell = NSTextField(labelWithString: record.readID)
            cell.font = .systemFont(ofSize: 11)
            cell.textColor = .labelColor
            cell.lineBreakMode = .byTruncatingTail
            return cell

        case "rp_length":
            let cell = NSTextField(labelWithString: "\(record.length)")
            cell.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cell.textColor = .labelColor
            cell.alignment = .right
            return cell

        case "rp_meanQ":
            let cell = NSTextField(labelWithString: String(format: "%.1f", record.meanQuality))
            cell.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            cell.alignment = .right
            // Color-code quality
            if record.meanQuality >= 30 {
                cell.textColor = .systemGreen
            } else if record.meanQuality >= 20 {
                cell.textColor = .systemYellow
            } else {
                cell.textColor = .systemRed
            }
            return cell

        case "rp_sequence":
            let truncated = record.sequence.count > 80 ? String(record.sequence.prefix(80)) + "..." : record.sequence
            let cell = NSTextField(labelWithString: truncated)
            cell.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            cell.textColor = .labelColor
            cell.lineBreakMode = .byTruncatingTail
            return cell

        default:
            return nil
        }
    }
}

// MARK: - NSTextFieldDelegate (parameter field changes)

extension FASTQDatasetViewController: NSTextFieldDelegate {
    public func controlTextDidChange(_ obj: Notification) {
        updatePreview()
    }

    public func controlTextDidEndEditing(_ obj: Notification) {
        updatePreview()
    }
}

// MARK: - NSSplitViewDelegate (pane size constraints)
//
// These delegate methods are the CORRECT API for constraining divider positions
// on raw NSSplitView instances (mainSplitView, middleSplitView). They are NOT
// needed — and should NOT be used — on NSSplitViewController, which exposes
// minimumThickness / maximumThickness on its split view items instead.
//
// Holding priorities (set in configureMainSplitView / configureMiddlePane)
// complement these constraints by controlling which pane absorbs resize delta.

extension FASTQDatasetViewController: NSSplitViewDelegate {
    public func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === mainSplitView {
            // Top pane is fixed-height — lock divider in place.
            return LayoutDefaults.topPaneHeight
        }
        if splitView === middleSplitView {
            return LayoutDefaults.minSidebarWidth
        }
        return proposedMinimumPosition
    }

    public func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === mainSplitView {
            // Top pane is fixed-height — lock divider in place.
            return LayoutDefaults.topPaneHeight
        }
        if splitView === middleSplitView {
            return LayoutDefaults.maxSidebarWidth
        }
        return proposedMaximumPosition
    }

    public func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }
}
