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

        static let minSidebarWidth: CGFloat = 140
        static let maxSidebarWidth: CGFloat = 260
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
        case errorCorrection
        case orient
        case demultiplex

        var title: String {
            switch self {
            case .qualityReport: return "Compute Quality Report"
            case .subsampleProportion: return "Subsample by Proportion"
            case .subsampleCount: return "Subsample by Count"
            case .lengthFilter: return "Filter by Read Length"
            case .searchText: return "Find by ID/Description"
            case .searchMotif: return "Find by Sequence Motif"
            case .deduplicate: return "Remove Duplicates"
            case .qualityTrim: return "Quality Trim"
            case .adapterTrim: return "Adapter Removal"
            case .fixedTrim: return "Fixed Trim (5'/3')"
            case .contaminantFilter: return "Contaminant Filter"
            case .pairedEndMerge: return "Merge Overlapping Pairs"
            case .pairedEndRepair: return "Repair Paired Reads"
            case .primerRemoval: return "Custom Primer Removal"
            case .errorCorrection: return "Error Correction"
            case .orient: return "Orient Reads"
            case .demultiplex: return "Demultiplex (Barcodes)"
            }
        }

        var sfSymbol: String {
            switch self {
            case .qualityReport: return "chart.bar.doc.horizontal"
            case .subsampleProportion: return "chart.pie"
            case .subsampleCount: return "number"
            case .lengthFilter: return "arrow.left.and.right"
            case .searchText: return "magnifyingglass"
            case .searchMotif: return "text.magnifyingglass"
            case .deduplicate: return "square.on.square.dashed"
            case .qualityTrim: return "scissors"
            case .adapterTrim: return "minus.circle"
            case .fixedTrim: return "ruler"
            case .contaminantFilter: return "shield.slash"
            case .pairedEndMerge: return "arrow.triangle.merge"
            case .pairedEndRepair: return "wrench.and.screwdriver"
            case .primerRemoval: return "xmark.seal"
            case .errorCorrection: return "wand.and.stars"
            case .orient: return "arrow.left.arrow.right"
            case .demultiplex: return "barcode"
            }
        }

        var category: String {
            switch self {
            case .qualityReport: return "REPORTS"
            case .subsampleProportion, .subsampleCount: return "SAMPLING"
            case .qualityTrim, .adapterTrim, .fixedTrim, .primerRemoval: return "TRIMMING"
            case .lengthFilter, .contaminantFilter, .deduplicate: return "FILTERING"
            case .errorCorrection: return "CORRECTION"
            case .pairedEndMerge, .pairedEndRepair: return "REFORMATTING"
            case .searchText, .searchMotif: return "SEARCH"
            case .orient: return "PREPROCESSING"
            case .demultiplex: return "DEMULTIPLEXING"
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
            case .errorCorrection: return .errorCorrection
            case .orient: return .orient
            case .demultiplex: return .demultiplex
            }
        }
    }

    // MARK: - Sidebar Data

    /// Category headers + operation items for the source list sidebar.
    private static let categories: [(header: String, items: [OperationKind])] = [
        ("REPORTS", [.qualityReport]),
        ("SAMPLING", [.subsampleProportion, .subsampleCount]),
        ("TRIMMING", [.qualityTrim, .adapterTrim, .fixedTrim, .primerRemoval]),
        ("FILTERING", [.lengthFilter, .contaminantFilter, .deduplicate]),
        ("CORRECTION", [.errorCorrection]),
        ("PREPROCESSING", [.orient]),
        ("DEMULTIPLEXING", [.demultiplex]),
        ("REFORMATTING", [.pairedEndMerge, .pairedEndRepair]),
        ("SEARCH", [.searchText, .searchMotif]),
    ]

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

    /// Callback to open/focus the Demux Setup tab in the metadata drawer.
    public var onOpenDemuxDrawer: (() -> Void)?

    /// Current demux configuration from the metadata drawer. Set by the drawer view.
    /// When present, the demultiplex operation uses this configuration.
    public var currentDemuxConfig: DemultiplexStep? {
        didSet {
            if selectedOperation == .demultiplex {
                updateParameterBar()
            }
        }
    }

    /// Full demultiplex plan from the metadata drawer.
    /// Multi-step plans run sequentially when more than one step is configured.
    public var currentDemuxPlan: DemultiplexPlan? {
        didSet {
            if selectedOperation == .demultiplex {
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
    private let dedupModePopup = NSPopUpButton()
    private let regexCheckbox = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let revCompCheckbox = NSButton(checkboxWithTitle: "Rev. Comp.", target: nil, action: nil)
    private let pairedAwareCheckbox = NSButton(checkboxWithTitle: "Paired-aware", target: nil, action: nil)
    private let qualityTrimModePopup = NSPopUpButton()
    private let adapterModePopup = NSPopUpButton()
    private let contaminantModePopup = NSPopUpButton()
    private let mergeStrictnessPopup = NSPopUpButton()
    private let primerSourcePopup = NSPopUpButton()
    private let interleaveDirectionPopup = NSPopUpButton()

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
        dedupModePopup.addItems(withTitles: ["Identifier", "Description", "Sequence"])
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

        for popup in [searchFieldPopup, dedupModePopup, qualityTrimModePopup, adapterModePopup,
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
        pairedAwareCheckbox.translatesAutoresizingMaskIntoConstraints = false
        pairedAwareCheckbox.target = self
        pairedAwareCheckbox.action = #selector(parameterCheckboxChanged(_:))
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
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        runBar.addSubview(statusLabel)

        outputEstimateLabel.font = .systemFont(ofSize: 11)
        outputEstimateLabel.textColor = .secondaryLabelColor
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
        statusToEstimate.priority = .defaultLow

        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: runBar.topAnchor),
            border.leadingAnchor.constraint(equalTo: runBar.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: runBar.trailingAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),

            statusLabel.leadingAnchor.constraint(equalTo: runBar.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: runBar.centerYAnchor),
            statusToEstimate,

            outputEstimateLabel.centerXAnchor.constraint(equalTo: runBar.centerXAnchor),
            outputEstimateLabel.centerYAnchor.constraint(equalTo: runBar.centerYAnchor),

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
            parameterBar.addArrangedSubview(fieldOneLabel)
            parameterBar.addArrangedSubview(fieldOneInput)

        case .subsampleCount:
            fieldOneLabel.stringValue = "Count:"
            fieldOneInput.placeholderString = "10000"
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
            parameterBar.addArrangedSubview(dedupModePopup)
            parameterBar.addArrangedSubview(pairedAwareCheckbox)

        case .qualityTrim:
            fieldOneLabel.stringValue = "Q Threshold:"
            fieldOneInput.placeholderString = "20"
            fieldTwoLabel.stringValue = "Window:"
            fieldTwoInput.placeholderString = "4"
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
            fieldTwoLabel.stringValue = "Mismatch:"
            fieldTwoInput.placeholderString = "1"
            parameterBar.addArrangedSubview(contaminantModePopup)
            parameterBar.addArrangedSubview(fieldOneLabel)
            parameterBar.addArrangedSubview(fieldOneInput)
            parameterBar.addArrangedSubview(fieldTwoLabel)
            parameterBar.addArrangedSubview(fieldTwoInput)

        case .pairedEndMerge:
            fieldOneLabel.stringValue = "Min Overlap:"
            fieldOneInput.placeholderString = "12"
            parameterBar.addArrangedSubview(mergeStrictnessPopup)
            parameterBar.addArrangedSubview(fieldOneLabel)
            parameterBar.addArrangedSubview(fieldOneInput)

        case .pairedEndRepair:
            let label = NSTextField(labelWithString: "No parameters required")
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            parameterBar.addArrangedSubview(label)

        case .primerRemoval:
            fieldOneLabel.stringValue = "Sequence/Path:"
            fieldOneInput.placeholderString = "AGATCGGAAGAGC"
            fieldTwoLabel.stringValue = "K-mer:"
            fieldTwoInput.placeholderString = "23"
            parameterBar.addArrangedSubview(primerSourcePopup)
            parameterBar.addArrangedSubview(fieldOneLabel)
            parameterBar.addArrangedSubview(fieldOneInput)
            parameterBar.addArrangedSubview(fieldTwoLabel)
            parameterBar.addArrangedSubview(fieldTwoInput)

        case .errorCorrection:
            fieldOneLabel.stringValue = "K-mer Size:"
            fieldOneInput.placeholderString = "50"
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
                let placeholder = NSTextField(labelWithString: "Select a kit in the Demux Setup panel below")
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
        params.dedupMode = dedupModePopup.titleOfSelectedItem ?? "Sequence"
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
        // Find the row index for .qualityReport in the sidebar
        var targetRow = -1
        var currentRow = 0
        for (_, items) in Self.categories {
            currentRow += 1 // header
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

        let opID = OperationCenter.shared.start(
            title: "Quality Report",
            detail: url.lastPathComponent,
            operationType: .qualityReport
        )

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
                        self.setStatus("Quality report complete")
                        self.onStatisticsUpdated?(fullStats)
                    }
                }
            } catch {
                let errorMessage = "\(error)"
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        OperationCenter.shared.fail(id: opID, detail: errorMessage)
                        self.qualityReportTask = nil
                        self.updateRunButtonState()
                        self.cancelButton.isHidden = true
                        self.progressIndicator.stopAnimation(nil)
                        self.setStatus("Quality report failed")

                        let alert = NSAlert()
                        alert.messageText = "Quality Report Failed"
                        alert.informativeText = errorMessage
                        alert.alertStyle = .warning
                        alert.addButton(withTitle: "OK")
                        alert.applyLungfishBranding()
                        alert.runModal()
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
        // Demux requires a configuration from the drawer
        if selectedOperation == .demultiplex
            && (currentDemuxPlan?.steps.isEmpty ?? true)
            && currentDemuxConfig == nil {
            setStatus("Configure demultiplexing in the Demux Setup panel below")
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

        operationTask = Task { [weak self, onRunOperation] in
            do {
                try await onRunOperation(request)
                guard let self else { return }
                self.operationTask = nil
                self.updateRunButtonState()
                self.cancelButton.isHidden = true
                self.progressIndicator.stopAnimation(nil)
                self.setStatus("Done: \(self.description(for: request))")
            } catch is CancellationError {
                guard let self else { return }
                self.operationTask = nil
                self.updateRunButtonState()
                self.cancelButton.isHidden = true
                self.progressIndicator.stopAnimation(nil)
                self.setStatus("Cancelled")
            } catch {
                guard let self else { return }
                self.operationTask = nil
                self.updateRunButtonState()
                self.cancelButton.isHidden = true
                self.progressIndicator.stopAnimation(nil)
                self.setStatus("Failed: \(error.localizedDescription)", isError: true)
                self.showErrorBanner("Operation failed: \(error.localizedDescription)")
            }
        }
    }


    @objc private func openDemuxDrawerClicked(_ sender: Any) {
        onOpenDemuxDrawer?()
    }

    // MARK: - Orient Reference Management

    private func rebuildOrientReferencePopup() {
        orientReferencePopup.removeAllItems()
        orientProjectReferences = []

        if let projectURL = fastqURL?.deletingLastPathComponent() {
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
           !ReferenceSequenceFolder.isProjectReference(orientReferenceURL, in: fastqURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/")) {
            orientReferencePopup.addItem(withTitle: orientReferenceURL.lastPathComponent)
            orientReferencePopup.selectItem(at: orientReferencePopup.numberOfItems - 1)
            orientReferencePopup.isEnabled = true
        }
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
        panel.allowedContentTypes = [UTType(filenameExtension: "fasta"), UTType(filenameExtension: "fa"), UTType(filenameExtension: "fna")].compactMap { $0 }
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

    /// Maps a flat table row index to an OperationKind, accounting for category headers.
    private func operationKindForRow(_ row: Int) -> OperationKind? {
        var currentRow = 0
        for (_, items) in Self.categories {
            if currentRow == row { return nil } // header row
            currentRow += 1 // header
            for item in items {
                if currentRow == row { return item }
                currentRow += 1
            }
        }
        return nil
    }

    /// Total number of rows in the sidebar (headers + items).
    private var sidebarRowCount: Int {
        Self.categories.reduce(0) { $0 + 1 + $1.items.count }
    }

    /// Returns whether a row is a group header.
    private func isGroupRow(_ row: Int) -> Bool {
        var currentRow = 0
        for (_, items) in Self.categories {
            if currentRow == row { return true }
            currentRow += 1 + items.count
        }
        return false
    }

    /// Returns the category header or operation title for a row.
    private func titleForRow(_ row: Int) -> String {
        var currentRow = 0
        for (header, items) in Self.categories {
            if currentRow == row { return header }
            currentRow += 1
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
            let mode: FASTQDeduplicateMode
            switch dedupModePopup.indexOfSelectedItem {
            case 1: mode = .description
            case 2: mode = .sequence
            default: mode = .identifier
            }
            return .deduplicate(mode: mode, pairedAware: pairedAwareCheckbox.state == .on)

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
            let source: FASTQPrimerSource = primerSourcePopup.indexOfSelectedItem == 1 ? .reference : .literal
            let kmerSize = Int(fieldTwoInput.stringValue) ?? 23
            guard kmerSize > 0, kmerSize <= 63 else {
                setStatus("K-mer size must be between 1 and 63.", isError: true)
                return nil
            }
            let input = fieldOneInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty else {
                setStatus("Provide a primer sequence (literal) or reference FASTA path.", isError: true)
                return nil
            }
            switch source {
            case .literal:
                let validChars = CharacterSet(charactersIn: "ACGTUacgtuNnRYSWKMBDHVryswkmbdhv")
                guard input.unicodeScalars.allSatisfy({ validChars.contains($0) }) else {
                    setStatus("Primer sequence contains invalid characters. Use IUPAC nucleotide codes.", isError: true)
                    return nil
                }
                return .primerRemoval(source: .literal, literalSequence: input, referenceFasta: nil, kmerSize: kmerSize, minKmer: 11, hammingDistance: 1)
            case .reference:
                return .primerRemoval(source: .reference, literalSequence: nil, referenceFasta: input, kmerSize: kmerSize, minKmer: 11, hammingDistance: 1)
            }

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

        case .demultiplex:
            let effectivePlan: DemultiplexPlan
            if let plan = currentDemuxPlan, !plan.steps.isEmpty {
                effectivePlan = plan
            } else if let step = currentDemuxConfig {
                effectivePlan = DemultiplexPlan(steps: [step], compositeSampleNames: [:])
            } else {
                setStatus("Configure demultiplexing in the Demux Setup drawer first.", isError: true)
                return nil
            }
            let sourcePlatform = fastqURL.map { SequencingPlatform.detect(fromFASTQ: $0) } ?? nil
            return .multiStepDemultiplex(plan: effectivePlan, sourcePlatform: sourcePlatform)
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
        case .deduplicate(let mode, let pairedAware):
            return "Deduplicate \(mode.rawValue)\(pairedAware ? " (paired-aware)" : "")"
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
        case .primerRemoval(let source, let literalSeq, let refFasta, let kmerSize, _, _):
            let srcDesc = source == .literal ? (literalSeq ?? "literal") : (refFasta ?? "reference")
            return "Primer removal (\(source.rawValue): \(srcDesc), k=\(kmerSize))"
        case .errorCorrection(let kmerSize):
            return "Error correction (k=\(kmerSize))"
        case .interleaveReformat(let direction):
            return direction == .interleave ? "Interleave R1/R2" : "Deinterleave to R1/R2"
        case .demultiplex(
            let kitID,
            _,
            let location,
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
        case .multiStepDemultiplex(let plan, _):
            return "Multi-step demultiplex (\(plan.steps.count) steps)"
        case .orient(let referenceURL, let wordLength, let dbMask, _):
            return "Orient against \(referenceURL.lastPathComponent) (w=\(wordLength), mask=\(dbMask))"
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
            runButton.title = "Compute"
        case .orient:
            runButton.isEnabled = orientReferenceURL != nil
            runButton.title = "Run"
        case .demultiplex:
            let hasPlan = !(currentDemuxPlan?.steps.isEmpty ?? true)
            runButton.isEnabled = hasPlan || currentDemuxConfig != nil
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
            if columnID == "icon" { return nil }
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
        return cell
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if tableView === readPreviewTable { return 20 }
        return isGroupRow(row) ? 28 : 24
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if tableView === readPreviewTable { return true }
        return !isGroupRow(row)
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView,
              tableView === operationSidebar else { return }
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        selectedOperation = operationKindForRow(row)
        updateParameterBar()
        if selectedOperation == .demultiplex { onOpenDemuxDrawer?() }
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
