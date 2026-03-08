// FASTQDatasetViewController.swift - FASTQ dataset statistics dashboard
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO

@MainActor
public final class FASTQDatasetViewController: NSViewController {

    // MARK: - Chart Tabs

    private enum ChartTab: Int, CaseIterable {
        case lengthDistribution = 0
        case qualityPerPosition = 1
        case qualityScoreDistribution = 2

        var title: String {
            switch self {
            case .lengthDistribution: return "Length Distribution"
            case .qualityPerPosition: return "Quality / Position"
            case .qualityScoreDistribution: return "Q Score Distribution"
            }
        }
    }

    private enum OperationKind: Int, CaseIterable {
        case subsampleProportion
        case subsampleCount
        case lengthFilter
        case searchText
        case searchMotif
        case deduplicate

        var title: String {
            switch self {
            case .subsampleProportion: return "Subsample by Proportion"
            case .subsampleCount: return "Subsample by Count"
            case .lengthFilter: return "Filter by Read Length"
            case .searchText: return "Find by ID/Description"
            case .searchMotif: return "Find by Sequence Motif"
            case .deduplicate: return "Remove Duplicates"
            }
        }
    }

    // MARK: - Properties

    private var statistics: FASTQDatasetStatistics?
    private var fastqURL: URL?
    private var sourceURL: URL?
    private var derivativeManifest: FASTQDerivedBundleManifest?
    private var activeChartTab: ChartTab = .lengthDistribution
    private var qualityReportTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?

    public var onStatisticsUpdated: ((FASTQDatasetStatistics) -> Void)?
    public var onRunOperation: ((FASTQDerivativeRequest) async throws -> Void)?

    // MARK: - UI Components

    private let splitView = NSSplitView()
    private let topPane = NSView()
    private let bottomPane = NSView()

    private let summaryBar = FASTQSummaryBar()
    private let chartControlsRow = NSView()
    private let tabBar = NSSegmentedControl()

    private let chartContainer = NSView()
    private let lengthHistogramView = FASTQHistogramChartView()
    private let qualityBoxplotView = FASTQQualityBoxplotView()
    private let qualityScoreHistogramView = FASTQHistogramChartView()

    private let consoleTitleLabel = NSTextField(labelWithString: "FASTQ Operations")
    private let consoleScrollView = NSScrollView()
    private let consoleTextView = NSTextView()

    private let operationPopup = NSPopUpButton()
    private let fieldOneLabel = NSTextField(labelWithString: "")
    private let fieldTwoLabel = NSTextField(labelWithString: "")
    private let fieldOneInput = NSTextField(string: "")
    private let fieldTwoInput = NSTextField(string: "")
    private let searchFieldPopup = NSPopUpButton()
    private let dedupModePopup = NSPopUpButton()
    private let regexCheckbox = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let pairedAwareCheckbox = NSButton(checkboxWithTitle: "Paired-aware deduplication", target: nil, action: nil)

    private let runOperationButton = NSButton(title: "Run Operation", target: nil, action: nil)
    private let computeQualityButton = NSButton(title: "Compute Quality Report", target: nil, action: nil)
    private let qualityStatusBadge = NSTextField(labelWithString: "")

    private let progressIndicator = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")

    // MARK: - Lifecycle

    deinit {
        qualityReportTask?.cancel()
        operationTask?.cancel()
    }

    public override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        view.wantsLayer = true

        configureSplitView()
        configureTopPane()
        configureBottomPane()
        layoutSplitView()
        updateOperationInputs()
        updateQualityControls()
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
        self.activeChartTab = .lengthDistribution

        summaryBar.update(with: statistics)
        updateCharts()
        updateQualityControls()
        appendConsole("Loaded dataset: \(statistics.readCount) reads")
        if let derivativeManifest {
            appendConsole("Derived dataset: \(derivativeManifest.operation.displaySummary)")
        }
    }

    // MARK: - Setup

    private func configureSplitView() {
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.adjustSubviews()
        view.addSubview(splitView)

        topPane.translatesAutoresizingMaskIntoConstraints = false
        bottomPane.translatesAutoresizingMaskIntoConstraints = false
        splitView.addSubview(topPane)
        splitView.addSubview(bottomPane)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: view.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        topPane.heightAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        bottomPane.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
    }

    private func configureTopPane() {
        summaryBar.translatesAutoresizingMaskIntoConstraints = false
        topPane.addSubview(summaryBar)

        chartControlsRow.translatesAutoresizingMaskIntoConstraints = false
        topPane.addSubview(chartControlsRow)

        tabBar.segmentCount = ChartTab.allCases.count
        for tab in ChartTab.allCases {
            tabBar.setLabel(tab.title, forSegment: tab.rawValue)
            tabBar.setWidth(0, forSegment: tab.rawValue)
        }
        tabBar.selectedSegment = ChartTab.lengthDistribution.rawValue
        tabBar.segmentStyle = .texturedRounded
        tabBar.target = self
        tabBar.action = #selector(chartTabChanged(_:))
        tabBar.translatesAutoresizingMaskIntoConstraints = false
        chartControlsRow.addSubview(tabBar)

        chartContainer.translatesAutoresizingMaskIntoConstraints = false
        chartContainer.wantsLayer = true
        topPane.addSubview(chartContainer)

        for chart in [lengthHistogramView, qualityBoxplotView, qualityScoreHistogramView] as [NSView] {
            chart.translatesAutoresizingMaskIntoConstraints = false
            chartContainer.addSubview(chart)
            NSLayoutConstraint.activate([
                chart.topAnchor.constraint(equalTo: chartContainer.topAnchor),
                chart.leadingAnchor.constraint(equalTo: chartContainer.leadingAnchor),
                chart.trailingAnchor.constraint(equalTo: chartContainer.trailingAnchor),
                chart.bottomAnchor.constraint(equalTo: chartContainer.bottomAnchor),
            ])
        }

        qualityBoxplotView.isHidden = true
        qualityScoreHistogramView.isHidden = true

        NSLayoutConstraint.activate([
            summaryBar.topAnchor.constraint(equalTo: topPane.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: topPane.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: topPane.trailingAnchor),
            summaryBar.heightAnchor.constraint(equalToConstant: 48),

            chartControlsRow.topAnchor.constraint(equalTo: summaryBar.bottomAnchor, constant: 4),
            chartControlsRow.leadingAnchor.constraint(equalTo: topPane.leadingAnchor),
            chartControlsRow.trailingAnchor.constraint(equalTo: topPane.trailingAnchor),
            chartControlsRow.heightAnchor.constraint(equalToConstant: 30),

            tabBar.leadingAnchor.constraint(equalTo: chartControlsRow.leadingAnchor, constant: 8),
            tabBar.centerYAnchor.constraint(equalTo: chartControlsRow.centerYAnchor),

            chartContainer.topAnchor.constraint(equalTo: chartControlsRow.bottomAnchor, constant: 4),
            chartContainer.leadingAnchor.constraint(equalTo: topPane.leadingAnchor),
            chartContainer.trailingAnchor.constraint(equalTo: topPane.trailingAnchor),
            chartContainer.bottomAnchor.constraint(equalTo: topPane.bottomAnchor),
        ])
    }

    private func configureBottomPane() {
        consoleTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        consoleTitleLabel.translatesAutoresizingMaskIntoConstraints = false
        bottomPane.addSubview(consoleTitleLabel)

        operationPopup.addItems(withTitles: OperationKind.allCases.map(\.title))
        operationPopup.target = self
        operationPopup.action = #selector(operationSelectionChanged(_:))
        operationPopup.translatesAutoresizingMaskIntoConstraints = false
        bottomPane.addSubview(operationPopup)

        fieldOneLabel.font = .systemFont(ofSize: 12)
        fieldTwoLabel.font = .systemFont(ofSize: 12)
        fieldOneLabel.translatesAutoresizingMaskIntoConstraints = false
        fieldTwoLabel.translatesAutoresizingMaskIntoConstraints = false
        fieldOneInput.translatesAutoresizingMaskIntoConstraints = false
        fieldTwoInput.translatesAutoresizingMaskIntoConstraints = false

        searchFieldPopup.addItems(withTitles: ["ID", "Description"])
        searchFieldPopup.translatesAutoresizingMaskIntoConstraints = false

        dedupModePopup.addItems(withTitles: ["Identifier", "Description", "Sequence"])
        dedupModePopup.translatesAutoresizingMaskIntoConstraints = false

        regexCheckbox.translatesAutoresizingMaskIntoConstraints = false
        pairedAwareCheckbox.translatesAutoresizingMaskIntoConstraints = false

        runOperationButton.bezelStyle = .rounded
        runOperationButton.target = self
        runOperationButton.action = #selector(runOperationClicked(_:))
        runOperationButton.translatesAutoresizingMaskIntoConstraints = false

        computeQualityButton.bezelStyle = .rounded
        computeQualityButton.target = self
        computeQualityButton.action = #selector(computeQualityReportClicked(_:))
        computeQualityButton.translatesAutoresizingMaskIntoConstraints = false

        qualityStatusBadge.font = .systemFont(ofSize: 11, weight: .semibold)
        qualityStatusBadge.alignment = .center
        qualityStatusBadge.wantsLayer = true
        qualityStatusBadge.layer?.cornerRadius = 6
        qualityStatusBadge.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        progressLabel.font = .systemFont(ofSize: 11)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.isHidden = true
        progressLabel.translatesAutoresizingMaskIntoConstraints = false

        for subview in [
            fieldOneLabel, fieldOneInput,
            fieldTwoLabel, fieldTwoInput,
            searchFieldPopup, dedupModePopup,
            regexCheckbox, pairedAwareCheckbox,
            runOperationButton, computeQualityButton,
            qualityStatusBadge, progressIndicator, progressLabel,
        ] {
            bottomPane.addSubview(subview)
        }

        consoleScrollView.translatesAutoresizingMaskIntoConstraints = false
        consoleScrollView.borderType = .bezelBorder
        consoleScrollView.hasVerticalScroller = true
        consoleScrollView.drawsBackground = true
        consoleScrollView.backgroundColor = .textBackgroundColor

        consoleTextView.isEditable = false
        consoleTextView.isSelectable = true
        consoleTextView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        consoleTextView.string = ""
        consoleScrollView.documentView = consoleTextView
        bottomPane.addSubview(consoleScrollView)

        NSLayoutConstraint.activate([
            consoleTitleLabel.topAnchor.constraint(equalTo: bottomPane.topAnchor, constant: 8),
            consoleTitleLabel.leadingAnchor.constraint(equalTo: bottomPane.leadingAnchor, constant: 8),

            operationPopup.topAnchor.constraint(equalTo: consoleTitleLabel.bottomAnchor, constant: 8),
            operationPopup.leadingAnchor.constraint(equalTo: bottomPane.leadingAnchor, constant: 8),
            operationPopup.widthAnchor.constraint(equalToConstant: 240),

            fieldOneLabel.topAnchor.constraint(equalTo: operationPopup.topAnchor),
            fieldOneLabel.leadingAnchor.constraint(equalTo: operationPopup.trailingAnchor, constant: 12),
            fieldOneLabel.widthAnchor.constraint(equalToConstant: 120),

            fieldOneInput.topAnchor.constraint(equalTo: fieldOneLabel.bottomAnchor, constant: 4),
            fieldOneInput.leadingAnchor.constraint(equalTo: fieldOneLabel.leadingAnchor),
            fieldOneInput.widthAnchor.constraint(equalToConstant: 150),

            fieldTwoLabel.topAnchor.constraint(equalTo: operationPopup.topAnchor),
            fieldTwoLabel.leadingAnchor.constraint(equalTo: fieldOneInput.trailingAnchor, constant: 12),
            fieldTwoLabel.widthAnchor.constraint(equalToConstant: 120),

            fieldTwoInput.topAnchor.constraint(equalTo: fieldTwoLabel.bottomAnchor, constant: 4),
            fieldTwoInput.leadingAnchor.constraint(equalTo: fieldTwoLabel.leadingAnchor),
            fieldTwoInput.widthAnchor.constraint(equalToConstant: 150),

            searchFieldPopup.topAnchor.constraint(equalTo: operationPopup.topAnchor),
            searchFieldPopup.leadingAnchor.constraint(equalTo: fieldTwoInput.trailingAnchor, constant: 12),
            searchFieldPopup.widthAnchor.constraint(equalToConstant: 120),

            dedupModePopup.topAnchor.constraint(equalTo: operationPopup.topAnchor),
            dedupModePopup.leadingAnchor.constraint(equalTo: fieldTwoInput.trailingAnchor, constant: 12),
            dedupModePopup.widthAnchor.constraint(equalToConstant: 140),

            regexCheckbox.topAnchor.constraint(equalTo: fieldOneInput.bottomAnchor, constant: 6),
            regexCheckbox.leadingAnchor.constraint(equalTo: fieldOneInput.leadingAnchor),

            pairedAwareCheckbox.topAnchor.constraint(equalTo: fieldOneInput.bottomAnchor, constant: 6),
            pairedAwareCheckbox.leadingAnchor.constraint(equalTo: dedupModePopup.leadingAnchor),

            runOperationButton.topAnchor.constraint(equalTo: operationPopup.topAnchor),
            runOperationButton.trailingAnchor.constraint(equalTo: bottomPane.trailingAnchor, constant: -8),

            computeQualityButton.topAnchor.constraint(equalTo: runOperationButton.bottomAnchor, constant: 6),
            computeQualityButton.trailingAnchor.constraint(equalTo: bottomPane.trailingAnchor, constant: -8),

            qualityStatusBadge.centerYAnchor.constraint(equalTo: computeQualityButton.centerYAnchor),
            qualityStatusBadge.trailingAnchor.constraint(equalTo: computeQualityButton.leadingAnchor, constant: -8),
            qualityStatusBadge.heightAnchor.constraint(equalToConstant: 20),
            qualityStatusBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 118),

            progressLabel.centerYAnchor.constraint(equalTo: qualityStatusBadge.centerYAnchor),
            progressLabel.trailingAnchor.constraint(equalTo: qualityStatusBadge.leadingAnchor, constant: -8),

            progressIndicator.centerYAnchor.constraint(equalTo: progressLabel.centerYAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: progressLabel.leadingAnchor, constant: -6),

            consoleScrollView.topAnchor.constraint(equalTo: regexCheckbox.bottomAnchor, constant: 10),
            consoleScrollView.leadingAnchor.constraint(equalTo: bottomPane.leadingAnchor, constant: 8),
            consoleScrollView.trailingAnchor.constraint(equalTo: bottomPane.trailingAnchor, constant: -8),
            consoleScrollView.bottomAnchor.constraint(equalTo: bottomPane.bottomAnchor, constant: -8),
        ])
    }

    private func layoutSplitView() {
        splitView.setPosition(view.bounds.height * 0.56, ofDividerAt: 0)
    }

    // MARK: - Updates

    private func updateCharts() {
        guard let stats = statistics else { return }

        let lengthBins = stats.readLengthHistogram
            .sorted { $0.key < $1.key }
            .map { (key: $0.key, value: $0.value) }

        lengthHistogramView.update(with: .init(
            title: "Read Length Distribution",
            xLabel: "Read Length (bp)",
            yLabel: "Count",
            bins: lengthBins,
            barColor: .systemBlue
        ))

        let qBins = stats.qualityScoreHistogram.sorted { $0.key < $1.key }
            .map { (key: Int($0.key), value: $0.value) }

        qualityScoreHistogramView.update(with: .init(
            title: "Quality Score Distribution",
            xLabel: "Quality Score (Phred)",
            yLabel: "Base Count",
            bins: qBins,
            barColor: .systemGreen
        ))

        qualityBoxplotView.update(with: stats.perPositionQuality)
        applyChartVisibility()
    }

    private func applyChartVisibility() {
        lengthHistogramView.isHidden = activeChartTab != .lengthDistribution
        qualityBoxplotView.isHidden = activeChartTab != .qualityPerPosition
        qualityScoreHistogramView.isHidden = activeChartTab != .qualityScoreDistribution
    }

    private func updateQualityControls() {
        let hasQualityReport = hasQualityData

        tabBar.selectedSegment = activeChartTab.rawValue
        tabBar.setEnabled(true, forSegment: ChartTab.lengthDistribution.rawValue)
        tabBar.setEnabled(hasQualityReport, forSegment: ChartTab.qualityPerPosition.rawValue)
        tabBar.setEnabled(hasQualityReport, forSegment: ChartTab.qualityScoreDistribution.rawValue)

        if hasQualityReport {
            qualityStatusBadge.stringValue = "Quality Report: Cached"
            qualityStatusBadge.textColor = .systemGreen
            qualityStatusBadge.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.12).cgColor
            qualityStatusBadge.layer?.borderColor = NSColor.systemGreen.withAlphaComponent(0.35).cgColor
            qualityStatusBadge.layer?.borderWidth = 1
        } else {
            qualityStatusBadge.stringValue = "Quality Report: Not Computed"
            qualityStatusBadge.textColor = .secondaryLabelColor
            qualityStatusBadge.layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.12).cgColor
            qualityStatusBadge.layer?.borderColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.25).cgColor
            qualityStatusBadge.layer?.borderWidth = 1
        }

        if !hasQualityReport, activeChartTab != .lengthDistribution {
            activeChartTab = .lengthDistribution
            tabBar.selectedSegment = activeChartTab.rawValue
            applyChartVisibility()
        }

        let canCompute = fastqURL != nil && !hasQualityReport && qualityReportTask == nil
        computeQualityButton.isHidden = !canCompute
    }

    private func updateOperationInputs() {
        let kind = OperationKind(rawValue: operationPopup.indexOfSelectedItem) ?? .subsampleProportion

        fieldOneLabel.isHidden = false
        fieldOneInput.isHidden = false
        fieldTwoLabel.isHidden = true
        fieldTwoInput.isHidden = true
        searchFieldPopup.isHidden = true
        regexCheckbox.isHidden = true
        dedupModePopup.isHidden = true
        pairedAwareCheckbox.isHidden = true

        switch kind {
        case .subsampleProportion:
            fieldOneLabel.stringValue = "Proportion (0-1)"
            fieldOneInput.placeholderString = "0.10"

        case .subsampleCount:
            fieldOneLabel.stringValue = "Read Count"
            fieldOneInput.placeholderString = "10000"

        case .lengthFilter:
            fieldOneLabel.stringValue = "Min Length"
            fieldTwoLabel.stringValue = "Max Length"
            fieldOneInput.placeholderString = ""
            fieldTwoInput.placeholderString = ""
            fieldTwoLabel.isHidden = false
            fieldTwoInput.isHidden = false

        case .searchText:
            fieldOneLabel.stringValue = "Pattern"
            fieldOneInput.placeholderString = "read-id"
            searchFieldPopup.isHidden = false
            regexCheckbox.isHidden = false

        case .searchMotif:
            fieldOneLabel.stringValue = "Motif / Pattern"
            fieldOneInput.placeholderString = "ATGNNNT"
            regexCheckbox.isHidden = false

        case .deduplicate:
            fieldOneLabel.isHidden = true
            fieldOneInput.isHidden = true
            dedupModePopup.isHidden = false
            pairedAwareCheckbox.isHidden = false
        }
    }

    private var hasQualityData: Bool {
        guard let stats = statistics else { return false }
        return !stats.perPositionQuality.isEmpty && !stats.qualityScoreHistogram.isEmpty
    }

    // MARK: - Actions

    @objc private func chartTabChanged(_ sender: NSSegmentedControl) {
        guard let tab = ChartTab(rawValue: sender.selectedSegment) else { return }
        if (tab == .qualityPerPosition || tab == .qualityScoreDistribution), !hasQualityData {
            sender.selectedSegment = ChartTab.lengthDistribution.rawValue
            activeChartTab = .lengthDistribution
        } else {
            activeChartTab = tab
        }
        applyChartVisibility()
    }

    @objc private func operationSelectionChanged(_ sender: NSPopUpButton) {
        _ = sender
        updateOperationInputs()
    }

    @objc private func runOperationClicked(_ sender: NSButton) {
        _ = sender
        guard operationTask == nil else { return }
        guard let request = buildOperationRequest() else { return }
        guard let onRunOperation else {
            appendConsole("Operation unavailable: no FASTQ source selected.")
            return
        }

        runOperationButton.isEnabled = false
        progressIndicator.startAnimation(nil)
        progressLabel.isHidden = false
        progressLabel.stringValue = "Running operation..."

        appendConsole("Starting: \(description(for: request))")

        operationTask = Task { [weak self] in
            do {
                try await onRunOperation(request)
                await MainActor.run {
                    guard let self else { return }
                    self.operationTask = nil
                    self.runOperationButton.isEnabled = true
                    self.progressIndicator.stopAnimation(nil)
                    self.progressLabel.isHidden = true
                    self.appendConsole("Completed: \(self.description(for: request))")
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.operationTask = nil
                    self.runOperationButton.isEnabled = true
                    self.progressIndicator.stopAnimation(nil)
                    self.progressLabel.isHidden = true
                    self.appendConsole("Failed: \(error.localizedDescription)")

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

    @objc private func computeQualityReportClicked(_ sender: NSButton) {
        guard let url = fastqURL else { return }
        guard qualityReportTask == nil else { return }

        sender.isEnabled = false
        progressIndicator.startAnimation(nil)
        progressLabel.isHidden = false
        progressLabel.stringValue = "Computing quality report..."
        appendConsole("Computing quality report...")

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
                    self.updateCharts()
                    self.updateQualityControls()
                    self.progressIndicator.stopAnimation(nil)
                    self.progressLabel.isHidden = true
                    self.computeQualityButton.isEnabled = true
                    self.appendConsole("Quality report cached.")
                    self.onStatisticsUpdated?(fullStats)
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.qualityReportTask = nil
                    self.progressIndicator.stopAnimation(nil)
                    self.progressLabel.isHidden = true
                    self.computeQualityButton.isEnabled = true
                    self.appendConsole("Quality report failed: \(error.localizedDescription)")

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

    // MARK: - Request Building

    private func buildOperationRequest() -> FASTQDerivativeRequest? {
        let kind = OperationKind(rawValue: operationPopup.indexOfSelectedItem) ?? .subsampleProportion

        switch kind {
        case .subsampleProportion:
            guard let value = Double(fieldOneInput.stringValue), value > 0, value <= 1 else {
                appendConsole("Invalid proportion. Enter a value in (0, 1].")
                return nil
            }
            return .subsampleProportion(value)

        case .subsampleCount:
            guard let value = Int(fieldOneInput.stringValue), value > 0 else {
                appendConsole("Invalid read count. Enter an integer > 0.")
                return nil
            }
            return .subsampleCount(value)

        case .lengthFilter:
            let minValue = Int(fieldOneInput.stringValue.trimmingCharacters(in: .whitespaces))
            let maxValue = Int(fieldTwoInput.stringValue.trimmingCharacters(in: .whitespaces))
            if minValue == nil, maxValue == nil {
                appendConsole("Provide min, max, or both for length filter.")
                return nil
            }
            if let minValue, let maxValue, minValue > maxValue {
                appendConsole("Min length cannot be greater than max length.")
                return nil
            }
            return .lengthFilter(min: minValue, max: maxValue)

        case .searchText:
            let query = fieldOneInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                appendConsole("Search pattern cannot be empty.")
                return nil
            }
            let field: FASTQSearchField = searchFieldPopup.indexOfSelectedItem == 1 ? .description : .id
            return .searchText(query: query, field: field, regex: regexCheckbox.state == .on)

        case .searchMotif:
            let pattern = fieldOneInput.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else {
                appendConsole("Motif pattern cannot be empty.")
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
        }
    }

    private func appendConsole(_ line: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] \(line)\n"
        consoleTextView.textStorage?.append(NSAttributedString(string: entry))
        consoleTextView.scrollToEndOfDocument(nil)
    }
}
