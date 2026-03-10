// FASTQDatasetViewController.swift - FASTQ dataset statistics dashboard
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishWorkflow

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
            case .demultiplex: return "barcode"
            }
        }

        var category: String {
            switch self {
            case .qualityReport: return "QUALITY"
            case .subsampleProportion, .subsampleCount: return "SAMPLING"
            case .qualityTrim, .adapterTrim, .fixedTrim, .primerRemoval: return "TRIMMING"
            case .lengthFilter, .contaminantFilter, .deduplicate: return "FILTERING"
            case .errorCorrection: return "CORRECTION"
            case .pairedEndMerge, .pairedEndRepair: return "REFORMATTING"
            case .searchText, .searchMotif: return "SEARCH"
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
            case .demultiplex: return .demultiplex
            }
        }
    }

    // MARK: - Sidebar Data

    /// Category headers + operation items for the source list sidebar.
    private static let categories: [(header: String, items: [OperationKind])] = [
        ("QUALITY", [.qualityReport]),
        ("SAMPLING", [.subsampleProportion, .subsampleCount]),
        ("TRIMMING", [.qualityTrim, .adapterTrim, .fixedTrim, .primerRemoval]),
        ("FILTERING", [.lengthFilter, .contaminantFilter, .deduplicate]),
        ("CORRECTION", [.errorCorrection]),
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
    private var qualityReportTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var fastaPreviewTask: Task<Void, Never>?
    private var demuxKitOptions: [IlluminaBarcodeDefinition] = []
    private var demuxSampleAssignments: [FASTQSampleBarcodeAssignment] = []

    public var onStatisticsUpdated: ((FASTQDatasetStatistics) -> Void)?
    public var onRunOperation: ((FASTQDerivativeRequest) async throws -> Void)?

    // MARK: - Read Preview Data

    private var readPreviewRecords: [FASTQReadPreviewRecord] = []
    private var readPreviewTask: Task<Void, Never>?
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
    private let parameterBar = NSStackView()
    private let previewCanvas = OperationPreviewView()
    private let runBar = NSView()
    private let runButton = NSButton(title: "Run", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let outputEstimateLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()

    // Middle Pane: Tab Selector
    private let middleTabControl = NSSegmentedControl()
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
    private let demuxKitPopup = NSPopUpButton()
    private let demuxLocationPopup = NSPopUpButton()
    private let demuxWindow5Label = NSTextField(labelWithString: "5' Window:")
    private let demuxWindow5Input = NSTextField(string: "0")
    private let demuxWindow3Label = NSTextField(labelWithString: "3' Window:")
    private let demuxWindow3Input = NSTextField(string: "0")
    private let demuxTrimCheckbox = NSButton(checkboxWithTitle: "Remove barcodes + flanking sequences", target: nil, action: nil)
    private let demuxScoutButton = NSButton(title: "Scout Barcodes", target: nil, action: nil)
    private var scoutTask: Task<Void, Never>?

    // MARK: - Lifecycle

    deinit {
        qualityReportTask?.cancel()
        operationTask?.cancel()
        fastaPreviewTask?.cancel()
        readPreviewTask?.cancel()
    }

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view.wantsLayer = true

        configureMainSplitView()
        configureTopPane()
        configureMiddlePane()
    }

    private var didSetInitialSplitPositions = false

    public override func viewDidLayout() {
        super.viewDidLayout()
        if !didSetInitialSplitPositions, view.bounds.height > 200 {
            didSetInitialSplitPositions = true
            updateSplitPositions()
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

        loadDemultiplexMetadata(for: fastqURL)

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

    private func loadDemultiplexMetadata(for fastqURL: URL?) {
        var kits = IlluminaBarcodeKitRegistry.builtinKits()
        var preferredKitID: String?
        demuxSampleAssignments = []

        if let fastqURL,
           let metadata = FASTQMetadataStore.load(for: fastqURL),
           let demuxMetadata = metadata.demultiplexMetadata {
            demuxSampleAssignments = demuxMetadata.sampleAssignments
            preferredKitID = demuxMetadata.preferredBarcodeSetID
            for customKit in demuxMetadata.customBarcodeSets {
                if kits.contains(where: { $0.id == customKit.id }) { continue }
                kits.append(customKit)
            }
        }

        demuxKitOptions = kits
        demuxKitPopup.removeAllItems()
        demuxKitPopup.addItems(withTitles: demuxKitOptions.map(\.displayName))

        if let preferredKitID,
           let preferredIndex = demuxKitOptions.firstIndex(where: { $0.id == preferredKitID }) {
            demuxKitPopup.selectItem(at: preferredIndex)
        } else if let defaultIndex = demuxKitOptions.firstIndex(where: { $0.id == "nextera-xt-v2" }) {
            demuxKitPopup.selectItem(at: defaultIndex)
        } else if !demuxKitOptions.isEmpty {
            demuxKitPopup.selectItem(at: 0)
        }
    }

    public func updateOperationStatus(_ line: String) {
        setStatus(line)
    }

    public func refreshDemultiplexMetadata() {
        loadDemultiplexMetadata(for: fastqURL)
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
            summaryBar.heightAnchor.constraint(equalToConstant: 48),

            sparklineStrip.topAnchor.constraint(equalTo: summaryBar.bottomAnchor, constant: 2),
            sparklineStrip.leadingAnchor.constraint(equalTo: topPane.leadingAnchor),
            sparklineStrip.trailingAnchor.constraint(equalTo: topPane.trailingAnchor),
            sparklineStrip.heightAnchor.constraint(equalToConstant: 52),
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

        // Content container holds either the operations split or read preview
        middleContentContainer.translatesAutoresizingMaskIntoConstraints = false
        middlePane.addSubview(middleContentContainer)

        // Use high (but not required) priority so constraints yield gracefully
        // when the split view parent starts at zero size during initial layout.
        let tabTop = middleTabControl.topAnchor.constraint(equalTo: middlePane.topAnchor, constant: 4)
        tabTop.priority = .defaultHigh
        let tabHeight = middleTabControl.heightAnchor.constraint(equalToConstant: 24)
        tabHeight.priority = .defaultHigh
        let contentTop = middleContentContainer.topAnchor.constraint(equalTo: middleTabControl.bottomAnchor, constant: 4)
        contentTop.priority = .defaultHigh
        let contentBottom = middleContentContainer.bottomAnchor.constraint(equalTo: middlePane.bottomAnchor)
        contentBottom.priority = .defaultHigh

        NSLayoutConstraint.activate([
            tabTop,
            middleTabControl.centerXAnchor.constraint(equalTo: middlePane.centerXAnchor),
            tabHeight,

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

        // Operation sidebar (source list style)
        operationSidebar.style = .sourceList
        operationSidebar.headerView = nil
        operationSidebar.usesAlternatingRowBackgroundColors = false
        operationSidebar.rowHeight = 24
        operationSidebar.target = self
        operationSidebar.action = #selector(operationSidebarClicked(_:))

        let iconColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("icon"))
        iconColumn.width = 20
        iconColumn.maxWidth = 20
        operationSidebar.addTableColumn(iconColumn)

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.width = 200
        nameColumn.resizingMask = .autoresizingMask
        operationSidebar.addTableColumn(nameColumn)

        operationSidebar.dataSource = self
        operationSidebar.delegate = self

        operationScrollView.documentView = operationSidebar
        operationScrollView.hasVerticalScroller = true
        operationScrollView.autohidesScrollers = true
        operationScrollView.drawsBackground = false
        operationScrollView.translatesAutoresizingMaskIntoConstraints = false
        sidebarPane.addSubview(operationScrollView)

        NSLayoutConstraint.activate([
            operationScrollView.topAnchor.constraint(equalTo: sidebarPane.topAnchor),
            operationScrollView.leadingAnchor.constraint(equalTo: sidebarPane.leadingAnchor),
            operationScrollView.trailingAnchor.constraint(equalTo: sidebarPane.trailingAnchor),
            operationScrollView.bottomAnchor.constraint(equalTo: sidebarPane.bottomAnchor),
        ])

        // Preview area
        configureParameterBar()
        previewPane.addSubview(parameterBar)

        previewCanvas.translatesAutoresizingMaskIntoConstraints = false
        previewCanvas.wantsLayer = true
        previewPane.addSubview(previewCanvas)

        configureRunBar()
        previewPane.addSubview(runBar)

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

        let previewTop = previewCanvas.topAnchor.constraint(equalTo: parameterBar.bottomAnchor, constant: 1)
        previewTop.priority = .defaultHigh
        let previewLeading = previewCanvas.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor)
        previewLeading.priority = .defaultHigh
        let previewTrailing = previewCanvas.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor)
        previewTrailing.priority = .defaultHigh
        let previewBottom = previewCanvas.bottomAnchor.constraint(equalTo: runBar.topAnchor, constant: -1)
        previewBottom.priority = .defaultHigh

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

            previewTop,
            previewLeading,
            previewTrailing,
            previewBottom,

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

        // Initialize popups
        searchFieldPopup.addItems(withTitles: ["ID", "Description"])
        dedupModePopup.addItems(withTitles: ["Identifier", "Description", "Sequence"])
        qualityTrimModePopup.addItems(withTitles: ["Cut Right (3')", "Cut Front (5')", "Cut Tail", "Cut Both"])
        adapterModePopup.addItems(withTitles: ["Auto-Detect", "Specify Sequence"])
        contaminantModePopup.addItems(withTitles: ["PhiX Spike-in", "Custom Reference"])
        mergeStrictnessPopup.addItems(withTitles: ["Normal", "Strict"])
        primerSourcePopup.addItems(withTitles: ["Literal Sequence", "Reference FASTA"])
        interleaveDirectionPopup.addItems(withTitles: ["Interleave (R1+R2 → one)", "Deinterleave (one → R1+R2)"])

        for control in [fieldOneLabel, fieldTwoLabel, demuxWindow5Label, demuxWindow3Label] {
            control.font = .systemFont(ofSize: 10, weight: .medium)
            control.textColor = .secondaryLabelColor
            control.translatesAutoresizingMaskIntoConstraints = false
        }

        for field in [fieldOneInput, fieldTwoInput, demuxWindow5Input, demuxWindow3Input] {
            field.font = .systemFont(ofSize: 12)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 80).isActive = true
            field.delegate = self
        }

        for popup in [searchFieldPopup, dedupModePopup, qualityTrimModePopup, adapterModePopup,
                       contaminantModePopup, mergeStrictnessPopup, primerSourcePopup,
                       interleaveDirectionPopup, demuxLocationPopup] {
            popup.font = .systemFont(ofSize: 12)
            popup.translatesAutoresizingMaskIntoConstraints = false
            popup.target = self
            popup.action = #selector(parameterPopupChanged(_:))
        }

        demuxKitPopup.font = .systemFont(ofSize: 12)
        demuxKitPopup.translatesAutoresizingMaskIntoConstraints = false
        demuxKitPopup.target = self
        demuxKitPopup.action = #selector(demuxKitSelectionChanged(_:))

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

    private func updateSplitPositions() {
        let viewHeight = view.bounds.height
        guard viewHeight > 200 else { return }

        // Top pane: summary + sparklines (~108pt)
        let topHeight = min(viewHeight * 0.18, 130)
        mainSplitView.setPosition(topHeight, ofDividerAt: 0)

        // Sidebar default width — wide enough to show full operation names
        middleSplitView.setPosition(240, ofDividerAt: 0)
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
            runButton.isEnabled = false
            return
        }

        // Clear field values when switching operations to prevent bleed-through
        fieldOneInput.stringValue = ""
        fieldTwoInput.stringValue = ""
        runButton.isEnabled = true
        runButton.title = "Run"

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

        case .demultiplex:
            if demuxLocationPopup.numberOfItems == 0 {
                demuxLocationPopup.addItems(withTitles: ["5' End", "3' End", "Both Ends (5'+3')"])
                demuxLocationPopup.selectItem(at: 2)
            }
            demuxTrimCheckbox.state = .on
            fieldOneLabel.stringValue = "Error Rate:"
            fieldOneInput.placeholderString = "0.15"
            if demuxWindow5Input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                demuxWindow5Input.stringValue = "0"
            }
            if demuxWindow3Input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                demuxWindow3Input.stringValue = "0"
            }
            parameterBar.addArrangedSubview(demuxKitPopup)
            parameterBar.addArrangedSubview(demuxLocationPopup)
            parameterBar.addArrangedSubview(fieldOneLabel)
            parameterBar.addArrangedSubview(fieldOneInput)
            parameterBar.addArrangedSubview(demuxWindow5Label)
            parameterBar.addArrangedSubview(demuxWindow5Input)
            parameterBar.addArrangedSubview(demuxWindow3Label)
            parameterBar.addArrangedSubview(demuxWindow3Input)
            parameterBar.addArrangedSubview(demuxTrimCheckbox)
            demuxScoutButton.bezelStyle = .rounded
            demuxScoutButton.font = .systemFont(ofSize: 11)
            demuxScoutButton.target = self
            demuxScoutButton.action = #selector(scoutBarcodesClicked(_:))
            parameterBar.addArrangedSubview(demuxScoutButton)

        case .qualityReport:
            if hasQualityData {
                let label = NSTextField(labelWithString: "Quality data already computed. Sparkline charts are populated above.")
                label.font = .systemFont(ofSize: 11)
                label.textColor = .secondaryLabelColor
                parameterBar.addArrangedSubview(label)
                runButton.isEnabled = false
            } else if qualityReportTask != nil {
                let label = NSTextField(labelWithString: "Computing quality report...")
                label.font = .systemFont(ofSize: 11)
                label.textColor = .secondaryLabelColor
                parameterBar.addArrangedSubview(label)
                runButton.isEnabled = false
            } else {
                let label = NSTextField(labelWithString: "Scan all reads to compute per-position quality, length distribution, and quality score histograms.")
                label.font = .systemFont(ofSize: 11)
                label.textColor = .secondaryLabelColor
                parameterBar.addArrangedSubview(label)
                runButton.title = "Compute"
            }
        }

        // Add spacer to push controls left
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        parameterBar.addArrangedSubview(spacer)

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
            outputEstimateLabel.stringValue = "Output depends on data content"
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
        case .qualityReport:
            outputEstimateLabel.stringValue = ""
        case .demultiplex:
            outputEstimateLabel.stringValue = "Output depends on data content"
        default:
            outputEstimateLabel.stringValue = "Output depends on data content"
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
                        self.runButton.isEnabled = true
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
                        self.runButton.isEnabled = true
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
            runButton.isEnabled = true
            cancelButton.isHidden = true
            progressIndicator.stopAnimation(nil)
            setStatus("Quality report cancelled")
            return
        }
        if let task = operationTask {
            task.cancel()
            operationTask = nil
            runButton.isEnabled = true
            cancelButton.isHidden = true
            progressIndicator.stopAnimation(nil)
            setStatus("Operation cancelled")
        }
    }

    @objc private func operationSidebarClicked(_ sender: NSTableView) {
        let row = sender.selectedRow
        guard row >= 0 else { return }

        // Map flat row to operation kind
        selectedOperation = operationKindForRow(row)
        updateParameterBar()
    }

    @objc private func parameterPopupChanged(_ sender: NSPopUpButton) {
        updatePreview()
    }

    @objc private func demuxKitSelectionChanged(_ sender: NSPopUpButton) {
        updatePreview()
    }

    @objc private func parameterCheckboxChanged(_ sender: NSButton) {
        updatePreview()
    }

    @objc private func runOperationClicked(_ sender: Any) {
        // Quality report has its own execution path
        if selectedOperation == .qualityReport {
            computeQualityReport()
            return
        }
        guard operationTask == nil else { return }
        guard let request = buildOperationRequest() else { return }
        guard let onRunOperation else {
            setStatus("No FASTQ source selected")
            return
        }

        runButton.isEnabled = false
        cancelButton.isHidden = false
        progressIndicator.startAnimation(nil)
        setStatus("Running: \(description(for: request))")

        operationTask = Task { [weak self] in
            do {
                try await onRunOperation(request)
                guard let self else { return }
                self.operationTask = nil
                self.runButton.isEnabled = true
                self.cancelButton.isHidden = true
                self.progressIndicator.stopAnimation(nil)
                self.setStatus("Done: \(self.description(for: request))")
            } catch is CancellationError {
                guard let self else { return }
                self.operationTask = nil
                self.runButton.isEnabled = true
                self.cancelButton.isHidden = true
                self.progressIndicator.stopAnimation(nil)
                self.setStatus("Cancelled")
            } catch {
                guard let self else { return }
                self.operationTask = nil
                self.runButton.isEnabled = true
                self.cancelButton.isHidden = true
                self.progressIndicator.stopAnimation(nil)
                self.setStatus("Failed: \(error.localizedDescription)")

                let alert = NSAlert()
                alert.messageText = "FASTQ Operation Failed"
                alert.informativeText = error.localizedDescription
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.applyLungfishBranding()
                alert.runModal()
            }
        }
    }

    // MARK: - Barcode Scouting

    @objc private func scoutBarcodesClicked(_ sender: Any) {
        guard scoutTask == nil else { return }
        guard let fastqURL else {
            setStatus("No FASTQ source selected.")
            return
        }
        guard demuxKitPopup.indexOfSelectedItem >= 0,
              demuxKitPopup.indexOfSelectedItem < demuxKitOptions.count else {
            setStatus("Select a barcode kit before scouting.")
            return
        }

        let selectedKit = demuxKitOptions[demuxKitPopup.indexOfSelectedItem]
        demuxScoutButton.isEnabled = false
        progressIndicator.startAnimation(nil)
        setStatus("Scouting barcodes...")

        scoutTask = Task { [weak self] in
            guard let self else { return }
            do {
                let pipeline = DemultiplexingPipeline()
                let result = try await pipeline.scout(
                    inputURL: fastqURL,
                    kit: selectedKit,
                    readLimit: 10_000,
                    progress: { [weak self] _, message in
                        DispatchQueue.main.async { [weak self] in
                            MainActor.assumeIsolated {
                                self?.setStatus(message)
                            }
                        }
                    }
                )

                self.scoutTask = nil
                self.demuxScoutButton.isEnabled = true
                self.progressIndicator.stopAnimation(nil)

                // Save scout result to bundle
                self.saveScoutResult(result, for: fastqURL)

                // Present scout sheet
                guard let window = self.view.window else { return }
                BarcodeScoutSheet.present(
                    on: window,
                    scoutResult: result,
                    kitDisplayName: selectedKit.displayName,
                    onProceed: { [weak self] acceptedDetections, finalResult in
                        self?.handleScoutProceed(
                            acceptedDetections: acceptedDetections,
                            scoutResult: finalResult,
                            kit: selectedKit
                        )
                    }
                )
            } catch is CancellationError {
                self.scoutTask = nil
                self.demuxScoutButton.isEnabled = true
                self.progressIndicator.stopAnimation(nil)
                self.setStatus("Scout cancelled.")
            } catch {
                self.scoutTask = nil
                self.demuxScoutButton.isEnabled = true
                self.progressIndicator.stopAnimation(nil)
                self.setStatus("Scout failed: \(error.localizedDescription)")
            }
        }
    }

    private func handleScoutProceed(
        acceptedDetections: [BarcodeDetection],
        scoutResult: BarcodeScoutResult,
        kit: BarcodeKitDefinition
    ) {
        // Save final (user-edited) scout result
        if let fastqURL {
            saveScoutResult(scoutResult, for: fastqURL)
        }

        // Build pruned kit with only accepted barcodes
        let acceptedIDs = Set(acceptedDetections.map(\.barcodeID))
        let prunedBarcodes = kit.barcodes.filter { acceptedIDs.contains($0.id) }

        // Update sample names from scout detections
        var updatedBarcodes = prunedBarcodes
        for i in updatedBarcodes.indices {
            if let detection = acceptedDetections.first(where: { $0.barcodeID == updatedBarcodes[i].id }),
               let sampleName = detection.sampleName {
                updatedBarcodes[i] = BarcodeEntry(
                    id: updatedBarcodes[i].id,
                    i7Sequence: updatedBarcodes[i].i7Sequence,
                    i5Sequence: updatedBarcodes[i].i5Sequence,
                    sampleName: sampleName
                )
            }
        }

        let acceptedCount = acceptedDetections.count
        setStatus("Scout complete: \(acceptedCount) barcode(s) accepted. Ready to demultiplex.")
    }

    private func saveScoutResult(_ result: BarcodeScoutResult, for fastqURL: URL) {
        do {
            // Save inside .lungfishfastq bundle if it is one, otherwise next to the FASTQ
            let targetDir: URL
            if FASTQBundle.isBundleURL(fastqURL) {
                targetDir = fastqURL
            } else {
                targetDir = fastqURL.deletingLastPathComponent()
            }
            let scoutURL = targetDir.appendingPathComponent(BarcodeScoutResult.filename)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(result)
            try data.write(to: scoutURL, options: .atomic)
        } catch {
            setStatus("Warning: Could not save scout result: \(error.localizedDescription)")
        }
    }

    private func loadScoutResult(for fastqURL: URL) -> BarcodeScoutResult? {
        let targetDir: URL
        if FASTQBundle.isBundleURL(fastqURL) {
            targetDir = fastqURL
        } else {
            targetDir = fastqURL.deletingLastPathComponent()
        }
        let scoutURL = targetDir.appendingPathComponent(BarcodeScoutResult.filename)
        guard FileManager.default.fileExists(atPath: scoutURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: scoutURL)
            return try JSONDecoder().decode(BarcodeScoutResult.self, from: data)
        } catch {
            return nil
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
            setStatus("No operation selected.")
            return nil
        }

        switch kind {
        case .qualityReport:
            // Quality report is not a derivative operation; handled via computeQualityReport()
            return nil

        case .subsampleProportion:
            guard let value = Double(fieldOneInput.stringValue), value > 0, value <= 1 else {
                setStatus("Invalid proportion. Enter a value in (0, 1].")
                return nil
            }
            return .subsampleProportion(value)

        case .subsampleCount:
            guard let value = Int(fieldOneInput.stringValue), value > 0 else {
                setStatus("Invalid read count. Enter an integer > 0.")
                return nil
            }
            return .subsampleCount(value)

        case .lengthFilter:
            let minValue = Int(fieldOneInput.stringValue.trimmingCharacters(in: .whitespaces))
            let maxValue = Int(fieldTwoInput.stringValue.trimmingCharacters(in: .whitespaces))
            if minValue == nil, maxValue == nil {
                setStatus("Provide min, max, or both for length filter.")
                return nil
            }
            if let minValue, let maxValue, minValue > maxValue {
                setStatus("Min length cannot be greater than max length.")
                return nil
            }
            return .lengthFilter(min: minValue, max: maxValue)

        case .searchText:
            let query = fieldOneInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                setStatus("Search pattern cannot be empty.")
                return nil
            }
            let field: FASTQSearchField = searchFieldPopup.indexOfSelectedItem == 1 ? .description : .id
            return .searchText(query: query, field: field, regex: regexCheckbox.state == .on)

        case .searchMotif:
            let pattern = fieldOneInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else {
                setStatus("Motif pattern cannot be empty.")
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
                setStatus("Quality threshold and window size must be > 0.")
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
                    setStatus("Specify an adapter sequence or use Auto-Detect.")
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
                setStatus("Trim values must be >= 0.")
                return nil
            }
            guard from5 > 0 || from3 > 0 else {
                setStatus("At least one trim value must be > 0.")
                return nil
            }
            return .fixedTrim(from5Prime: from5, from3Prime: from3)

        case .contaminantFilter:
            let kmerSize = Int(fieldOneInput.stringValue) ?? 31
            let hammingDist = Int(fieldTwoInput.stringValue) ?? 1
            guard kmerSize > 0, kmerSize <= 63 else {
                setStatus("Kmer size must be between 1 and 63.")
                return nil
            }
            guard hammingDist >= 0, hammingDist <= 3 else {
                setStatus("Mismatch tolerance must be 0-3.")
                return nil
            }
            if contaminantModePopup.indexOfSelectedItem == 1 {
                setStatus("Custom reference mode requires a file picker (not yet implemented). Use PhiX mode.")
                return nil
            }
            return .contaminantFilter(mode: .phix, referenceFasta: nil, kmerSize: kmerSize, hammingDistance: hammingDist)

        case .pairedEndMerge:
            let minOverlap = Int(fieldOneInput.stringValue) ?? 12
            guard minOverlap > 0 else {
                setStatus("Minimum overlap must be > 0.")
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
                setStatus("K-mer size must be between 1 and 63.")
                return nil
            }
            let input = fieldOneInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty else {
                setStatus("Provide a primer sequence (literal) or reference FASTA path.")
                return nil
            }
            switch source {
            case .literal:
                let validChars = CharacterSet(charactersIn: "ACGTUacgtuNnRYSWKMBDHVryswkmbdhv")
                guard input.unicodeScalars.allSatisfy({ validChars.contains($0) }) else {
                    setStatus("Primer sequence contains invalid characters. Use IUPAC nucleotide codes.")
                    return nil
                }
                return .primerRemoval(source: .literal, literalSequence: input, referenceFasta: nil, kmerSize: kmerSize, minKmer: 11, hammingDistance: 1)
            case .reference:
                return .primerRemoval(source: .reference, literalSequence: nil, referenceFasta: input, kmerSize: kmerSize, minKmer: 11, hammingDistance: 1)
            }

        case .errorCorrection:
            let kmerSize = Int(fieldOneInput.stringValue) ?? 50
            guard kmerSize > 0, kmerSize <= 62 else {
                setStatus("K-mer size must be between 1 and 62 (tadpole limit).")
                return nil
            }
            return .errorCorrection(kmerSize: kmerSize)

        case .demultiplex:
            guard demuxKitPopup.indexOfSelectedItem >= 0,
                  demuxKitPopup.indexOfSelectedItem < demuxKitOptions.count else {
                setStatus("Select a barcode kit.")
                return nil
            }
            let selectedKit = demuxKitOptions[demuxKitPopup.indexOfSelectedItem]
            let kitID = selectedKit.id
            let location: String
            switch demuxLocationPopup.indexOfSelectedItem {
            case 0: location = "fivePrime"
            case 1: location = "threePrime"
            default: location = "bothEnds"
            }
            let errorRate = Double(fieldOneInput.stringValue) ?? 0.15
            guard errorRate >= 0, errorRate <= 1 else {
                setStatus("Error rate must be between 0 and 1.")
                return nil
            }
            let maxDistanceFrom5Prime = Int(demuxWindow5Input.stringValue) ?? 0
            let maxDistanceFrom3Prime = Int(demuxWindow3Input.stringValue) ?? 0
            guard maxDistanceFrom5Prime >= 0, maxDistanceFrom3Prime >= 0 else {
                setStatus("Demultiplex windows must be >= 0.")
                return nil
            }

            let resolvedAssignments = resolveDemultiplexAssignments(using: selectedKit)
            if selectedKit.pairingMode == .combinatorialDual && resolvedAssignments.isEmpty {
                setStatus("Combinatorial kits require FASTQ sample metadata with explicit 5'/3' barcode pairs.")
                return nil
            }

            let trim = demuxTrimCheckbox.state == .on
            return .demultiplex(
                kitID: kitID,
                customCSVPath: nil,
                location: location,
                maxDistanceFrom5Prime: maxDistanceFrom5Prime,
                maxDistanceFrom3Prime: maxDistanceFrom3Prime,
                errorRate: errorRate,
                trimBarcodes: trim,
                sampleAssignments: resolvedAssignments.isEmpty ? nil : resolvedAssignments
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
            let sampleAssignments
        ):
            let sampleCount = sampleAssignments?.count ?? 0
            let source = sampleCount > 0 ? ", \(sampleCount) sample-pairs" : ""
            return "Demultiplex (\(kitID), \(location), w5=\(maxDistanceFrom5Prime), w3=\(maxDistanceFrom3Prime), e=\(String(format: "%.2f", errorRate))\(source))"
        }
    }

    // MARK: - Helpers

    private func resolveDemultiplexAssignments(using kit: IlluminaBarcodeDefinition) -> [FASTQSampleBarcodeAssignment] {
        guard !demuxSampleAssignments.isEmpty else { return [] }

        var resolved: [FASTQSampleBarcodeAssignment] = []
        resolved.reserveCapacity(demuxSampleAssignments.count)

        for assignment in demuxSampleAssignments {
            let forward = assignment.forwardSequence ?? sequenceForBarcode(id: assignment.forwardBarcodeID, in: kit)
            let reverse = assignment.reverseSequence ?? sequenceForBarcode(id: assignment.reverseBarcodeID, in: kit)

            guard let forward, let reverse else { continue }
            resolved.append(
                FASTQSampleBarcodeAssignment(
                    sampleID: assignment.sampleID,
                    sampleName: assignment.sampleName,
                    forwardBarcodeID: assignment.forwardBarcodeID,
                    forwardSequence: forward,
                    reverseBarcodeID: assignment.reverseBarcodeID,
                    reverseSequence: reverse,
                    metadata: assignment.metadata
                )
            )
        }

        return resolved
    }

    private func sequenceForBarcode(id: String?, in kit: IlluminaBarcodeDefinition) -> String? {
        guard let id = id?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty else { return nil }
        return kit.barcodes.first(where: { $0.id.caseInsensitiveCompare(id) == .orderedSame })?.i7Sequence.uppercased()
    }

    private var hasQualityData: Bool {
        guard let stats = statistics else { return false }
        return !stats.perPositionQuality.isEmpty && !stats.qualityScoreHistogram.isEmpty
    }

    private func setStatus(_ line: String) {
        statusLabel.stringValue = line
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

// MARK: - NSSplitViewDelegate (sidebar constraints)

extension FASTQDatasetViewController: NSSplitViewDelegate {
    public func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === mainSplitView {
            return 104 // minimum top pane height (48 + 2 + 52 + 2)
        }
        if splitView === middleSplitView {
            return 200 // minimum sidebar width
        }
        return proposedMinimumPosition
    }

    public func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === mainSplitView {
            return 160 // maximum top pane height
        }
        if splitView === middleSplitView {
            return 320 // maximum sidebar width
        }
        return proposedMaximumPosition
    }

    public func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }
}
