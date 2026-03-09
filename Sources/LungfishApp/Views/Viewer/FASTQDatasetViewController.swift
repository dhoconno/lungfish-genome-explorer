// FASTQDatasetViewController.swift - FASTQ dataset statistics dashboard
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

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
            case .demultiplex: return "Demultiplex (Illumina Barcodes)"
            }
        }

        var sfSymbol: String {
            switch self {
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

    public var onStatisticsUpdated: ((FASTQDatasetStatistics) -> Void)?
    public var onRunOperation: ((FASTQDerivativeRequest) async throws -> Void)?

    // MARK: - UI Components — Two-Pane Split

    private let mainSplitView = NSSplitView()
    private let topPane = NSView()
    private let middlePane = NSView()

    // Top Pane: Summary + Sparklines
    private let summaryBar = FASTQSummaryBar()
    private let sparklineStrip = FASTQSparklineStrip()
    private let qualityReportButton = NSButton(title: "Compute Quality Report", target: nil, action: nil)

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
    private let outputEstimateLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()

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
    private let demuxTrimCheckbox = NSButton(checkboxWithTitle: "Trim barcodes", target: nil, action: nil)

    // MARK: - Lifecycle

    deinit {
        qualityReportTask?.cancel()
        operationTask?.cancel()
    }

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view.wantsLayer = true

        configureMainSplitView()
        configureTopPane()
        configureMiddlePane()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        updateSplitPositions()
    }

    // MARK: - Public API

    public func configure(
        statistics: FASTQDatasetStatistics,
        records: [FASTQRecord],
        fastqURL: URL? = nil,
        sourceURL: URL? = nil,
        derivativeManifest: FASTQDerivedBundleManifest? = nil
    ) {
        _ = records
        self.statistics = statistics
        self.fastqURL = fastqURL
        self.sourceURL = sourceURL
        self.derivativeManifest = derivativeManifest

        summaryBar.update(with: statistics)
        sparklineStrip.update(with: statistics)
        previewCanvas.update(operation: selectedOperation?.previewKind ?? .none, statistics: statistics)
        updateQualityReportButton()
        setStatus("Loaded: \(statistics.readCount) reads")
        if let derivativeManifest {
            setStatus("Derived: \(derivativeManifest.operation.displaySummary)")
        }
    }

    // MARK: - Main Split View

    private func configureMainSplitView() {
        mainSplitView.translatesAutoresizingMaskIntoConstraints = false
        mainSplitView.isVertical = false
        mainSplitView.dividerStyle = .thin
        mainSplitView.delegate = self
        view.addSubview(mainSplitView)

        for pane in [topPane, middlePane] {
            pane.translatesAutoresizingMaskIntoConstraints = false
            mainSplitView.addSubview(pane)
        }

        NSLayoutConstraint.activate([
            mainSplitView.topAnchor.constraint(equalTo: view.topAnchor),
            mainSplitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            mainSplitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            mainSplitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        topPane.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        middlePane.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
    }

    // MARK: - Top Pane: Summary + Sparklines

    private func configureTopPane() {
        summaryBar.translatesAutoresizingMaskIntoConstraints = false
        topPane.addSubview(summaryBar)

        sparklineStrip.translatesAutoresizingMaskIntoConstraints = false
        sparklineStrip.onComputeQualityReport = { [weak self] in
            self?.computeQualityReportClicked()
        }
        topPane.addSubview(sparklineStrip)

        qualityReportButton.translatesAutoresizingMaskIntoConstraints = false
        qualityReportButton.bezelStyle = .accessoryBarAction
        qualityReportButton.font = .systemFont(ofSize: 11, weight: .medium)
        qualityReportButton.target = self
        qualityReportButton.action = #selector(qualityReportButtonClicked(_:))
        topPane.addSubview(qualityReportButton)

        NSLayoutConstraint.activate([
            summaryBar.topAnchor.constraint(equalTo: topPane.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: topPane.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: topPane.trailingAnchor),
            summaryBar.heightAnchor.constraint(equalToConstant: 48),

            sparklineStrip.topAnchor.constraint(equalTo: summaryBar.bottomAnchor, constant: 2),
            sparklineStrip.leadingAnchor.constraint(equalTo: topPane.leadingAnchor),
            sparklineStrip.trailingAnchor.constraint(equalTo: topPane.trailingAnchor),
            sparklineStrip.heightAnchor.constraint(equalToConstant: 52),
            sparklineStrip.bottomAnchor.constraint(lessThanOrEqualTo: topPane.bottomAnchor),

            qualityReportButton.trailingAnchor.constraint(equalTo: topPane.trailingAnchor, constant: -8),
            qualityReportButton.centerYAnchor.constraint(equalTo: sparklineStrip.centerYAnchor),
        ])
    }

    // MARK: - Middle Pane: Operation Sidebar + Preview (resizable split)

    private func configureMiddlePane() {
        // Inner horizontal split: sidebar | preview
        middleSplitView.translatesAutoresizingMaskIntoConstraints = false
        middleSplitView.isVertical = true
        middleSplitView.dividerStyle = .thin
        middleSplitView.delegate = self
        middlePane.addSubview(middleSplitView)

        sidebarPane.translatesAutoresizingMaskIntoConstraints = false
        previewPane.translatesAutoresizingMaskIntoConstraints = false
        middleSplitView.addSubview(sidebarPane)
        middleSplitView.addSubview(previewPane)

        NSLayoutConstraint.activate([
            middleSplitView.topAnchor.constraint(equalTo: middlePane.topAnchor),
            middleSplitView.leadingAnchor.constraint(equalTo: middlePane.leadingAnchor),
            middleSplitView.trailingAnchor.constraint(equalTo: middlePane.trailingAnchor),
            middleSplitView.bottomAnchor.constraint(equalTo: middlePane.bottomAnchor),
        ])

        // Operation sidebar (source list style)
        operationSidebar.style = .sourceList
        operationSidebar.headerView = nil
        operationSidebar.usesAlternatingRowBackgroundColors = false
        operationSidebar.selectionHighlightStyle = .sourceList
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

        NSLayoutConstraint.activate([
            parameterBar.topAnchor.constraint(equalTo: previewPane.topAnchor),
            parameterBar.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor),
            parameterBar.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor),
            parameterBar.heightAnchor.constraint(equalToConstant: 36),

            previewCanvas.topAnchor.constraint(equalTo: parameterBar.bottomAnchor, constant: 1),
            previewCanvas.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor),
            previewCanvas.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor),
            previewCanvas.bottomAnchor.constraint(equalTo: runBar.topAnchor, constant: -1),

            runBar.leadingAnchor.constraint(equalTo: previewPane.leadingAnchor),
            runBar.trailingAnchor.constraint(equalTo: previewPane.trailingAnchor),
            runBar.bottomAnchor.constraint(equalTo: previewPane.bottomAnchor),
            runBar.heightAnchor.constraint(equalToConstant: 36),
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

        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: runBar.topAnchor),
            border.leadingAnchor.constraint(equalTo: runBar.leadingAnchor),
            border.trailingAnchor.constraint(equalTo: runBar.trailingAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),

            statusLabel.leadingAnchor.constraint(equalTo: runBar.leadingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: runBar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: outputEstimateLabel.leadingAnchor, constant: -8),

            outputEstimateLabel.centerXAnchor.constraint(equalTo: runBar.centerXAnchor),
            outputEstimateLabel.centerYAnchor.constraint(equalTo: runBar.centerYAnchor),

            progressIndicator.trailingAnchor.constraint(equalTo: runButton.leadingAnchor, constant: -8),
            progressIndicator.centerYAnchor.constraint(equalTo: runBar.centerYAnchor),

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
            if demuxKitPopup.numberOfItems == 0 {
                demuxKitPopup.addItems(withTitles: [
                    "TruSeq Single A (D701-D712)",
                    "TruSeq Single B (D501-D508)",
                    "TruSeq HT Dual (96)",
                    "Nextera XT v2 (84)",
                    "IDT UD Indexes (24)",
                ])
            }
            if demuxLocationPopup.numberOfItems == 0 {
                demuxLocationPopup.addItems(withTitles: ["Anywhere", "5' End", "3' End"])
            }
            demuxTrimCheckbox.state = .on
            fieldOneLabel.stringValue = "Error Rate:"
            fieldOneInput.placeholderString = "0.15"
            parameterBar.addArrangedSubview(demuxKitPopup)
            parameterBar.addArrangedSubview(demuxLocationPopup)
            parameterBar.addArrangedSubview(fieldOneLabel)
            parameterBar.addArrangedSubview(fieldOneInput)
            parameterBar.addArrangedSubview(demuxTrimCheckbox)
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
        default:
            outputEstimateLabel.stringValue = "Output depends on data content"
        }
    }

    // MARK: - Quality Report

    private func updateQualityReportButton() {
        let canCompute = fastqURL != nil && !hasQualityData && qualityReportTask == nil
        qualityReportButton.isHidden = !canCompute
    }

    @objc private func qualityReportButtonClicked(_ sender: Any) {
        computeQualityReportClicked()
    }

    private func computeQualityReportClicked() {
        guard let url = fastqURL else { return }
        guard qualityReportTask == nil else { return }

        qualityReportButton.isEnabled = false
        setStatus("Computing quality report...")

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

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.qualityReportTask = nil
                    self.statistics = fullStats
                    self.summaryBar.update(with: fullStats)
                    self.sparklineStrip.update(with: fullStats)
                    self.previewCanvas.update(operation: self.selectedOperation?.previewKind ?? .none, statistics: fullStats)
                    self.qualityReportButton.isEnabled = true
                    self.updateQualityReportButton()
                    self.setStatus("Quality report complete")
                    self.onStatisticsUpdated?(fullStats)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.qualityReportTask = nil
                    self.qualityReportButton.isEnabled = true
                    self.setStatus("Quality report failed")

                    let alert = NSAlert()
                    alert.messageText = "Quality Report Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
        }
    }

    // MARK: - Actions

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

    @objc private func parameterCheckboxChanged(_ sender: NSButton) {
        updatePreview()
    }

    @objc private func runOperationClicked(_ sender: Any) {
        guard operationTask == nil else { return }
        guard let request = buildOperationRequest() else { return }
        guard let onRunOperation else {
            setStatus("No FASTQ source selected")
            return
        }

        runButton.isEnabled = false
        progressIndicator.startAnimation(nil)
        setStatus("Running: \(description(for: request))")

        operationTask = Task { [weak self] in
            do {
                try await onRunOperation(request)
                await MainActor.run {
                    guard let self else { return }
                    self.operationTask = nil
                    self.runButton.isEnabled = true
                    self.progressIndicator.stopAnimation(nil)
                    self.setStatus("Done: \(self.description(for: request))")
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.operationTask = nil
                    self.runButton.isEnabled = true
                    self.progressIndicator.stopAnimation(nil)
                    self.setStatus("Failed: \(error.localizedDescription)")

                    let alert = NSAlert()
                    alert.messageText = "FASTQ Operation Failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
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
            let kitIDs = ["truseq-single-a", "truseq-single-b", "truseq-ht-dual", "nextera-xt-v2", "idt-ud-indexes"]
            let kitID = kitIDs[demuxKitPopup.indexOfSelectedItem]
            let location: String
            switch demuxLocationPopup.indexOfSelectedItem {
            case 1: location = "fivePrime"
            case 2: location = "threePrime"
            default: location = "anywhere"
            }
            let errorRate = Double(fieldOneInput.stringValue) ?? 0.15
            guard errorRate >= 0, errorRate <= 1 else {
                setStatus("Error rate must be between 0 and 1.")
                return nil
            }
            let trim = demuxTrimCheckbox.state == .on
            return .demultiplex(kitID: kitID, customCSVPath: nil, location: location, errorRate: errorRate, trimBarcodes: trim)
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
        case .demultiplex(let kitID, _, let location, let errorRate, _):
            return "Demultiplex (\(kitID), \(location), e=\(String(format: "%.2f", errorRate)))"
        }
    }

    // MARK: - Helpers

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

// MARK: - NSTableViewDataSource & Delegate (Operation Sidebar)

extension FASTQDatasetViewController: NSTableViewDataSource, NSTableViewDelegate {

    public func numberOfRows(in tableView: NSTableView) -> Int {
        sidebarRowCount
    }

    public func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        isGroupRow(row)
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
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
        isGroupRow(row) ? 28 : 24
    }

    public func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !isGroupRow(row)
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        guard let tableView = notification.object as? NSTableView,
              tableView === operationSidebar else { return }
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        selectedOperation = operationKindForRow(row)
        updateParameterBar()
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
        if splitView === middleSplitView {
            return 200 // minimum sidebar width
        }
        return proposedMinimumPosition
    }

    public func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        if splitView === middleSplitView {
            return 320 // maximum sidebar width
        }
        return proposedMaximumPosition
    }

    public func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        false
    }
}
