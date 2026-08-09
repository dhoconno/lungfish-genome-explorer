// ReferenceBundleViewportController.swift - Shared viewport for reference bundles and mapping results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

@MainActor
public class ReferenceBundleViewportController: NSViewController {
    enum PresentationMode: Equatable {
        case listDetail
        case focusedDetail
    }

    private(set) var currentInput: ReferenceBundleViewportInput?
    private(set) var presentationMode: PresentationMode = .listDetail
    private(set) var currentResult: MappingResult?
    private var currentResultDirectoryURL: URL?
    private var loadedViewerBundleURL: URL?
    private var sequenceRows: [ReferenceBundleRecordRow] = []
    private var usesRecordStoreTable = false
    private var recordStoreWarning: String?
    private typealias AlignmentTrackSummaryBuilder = (URL, Int) async throws -> [MappingContigSummary]
    private lazy var alignmentTrackSummaryBuilder: AlignmentTrackSummaryBuilder = { [weak self] bamURL, totalReads in
        try await MappingSummaryBuilder.build(
            sortedBAMURL: bamURL,
            totalReads: totalReads,
            reportWarning: { warning in
                // MappingSummaryBuilder's own memory guard warning (see its
                // sortedBAMMemoryGuardBytes doc comment) previously had no
                // sink in this viewport: the pre-fix default builder passed
                // no reportWarning at all, so it was constructed and
                // discarded. This controller has no OperationCenter/Logger
                // presence of its own (refreshMappingRowsForVisibleAlignmentTrack
                // isn't tied to a running OperationCenter operation id), so
                // route it through the same summary-bar surface this
                // controller already uses for non-fatal conditions
                // (recordStoreWarning's directBundle sibling).
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    self?.alignmentTrackSummaryWarning = warning
                    self?.updateSummaryBar()
                }}
            }
        )
    }
    private var alignmentTrackSummaryWarning: String?
    private var alignmentTrackSummaryRefreshID = UUID()
    private var visibleAlignmentSummaryOverride: VisibleAlignmentSummary?

    var onEmbeddedReferenceBundleLoaded: ((ReferenceBundle) -> Void)?
    var onSequenceSelectionStateChanged: ((SequenceRegionSelectionState?) -> Void)?

    private let embeddedViewerController = ViewerViewController()
    private let splitCoordinator = TwoPaneTrackedSplitCoordinator()

    private let summaryBar: NSView = {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }()

    private let summaryLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Reference Bundle")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier("reference-bundle-summary-label")
        return label
    }()

    private let focusButton: NSButton = {
        let button = NSButton(title: "Focus", target: nil, action: nil)
        button.bezelStyle = .rounded
        LungfishKitControlStyle.applyInspectorMetrics(to: button)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityIdentifier("reference-viewport-focus-button")
        button.setAccessibilityLabel("Focus reference detail")
        return button
    }()

    private let focusContainer: NSView = {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isHidden = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        return container
    }()

    private let focusedBackButton: NSButton = {
        let button = NSButton(title: "Back", target: nil, action: nil)
        button.bezelStyle = .rounded
        LungfishKitControlStyle.applyInspectorMetrics(to: button)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityIdentifier("reference-viewport-back-button")
        button.setAccessibilityLabel("Back to reference list and detail")
        return button
    }()

    private let focusedDetailContainer = NSView()
    private let splitView = TrackedDividerSplitView()
    private let listContainer = NSView()
    private let detailContainer = NSView()
    private let detailContentContainer = NSView()
    private var detailContentContainerConstraints: [NSLayoutConstraint] = []
    private let contigTableView = MappingContigTableView()
    private let sequenceTableView = ReferenceBundleRecordTable()

    private let detailPlaceholderLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Select a sequence to inspect.")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        label.setAccessibilityIdentifier("reference-bundle-detail-placeholder")
        return label
    }()

    var rootAccessibilityIdentifier: String { "reference-bundle-view" }
    var rootAccessibilityLabel: String { "Reference bundle viewport" }

    public override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel(rootAccessibilityLabel)
        root.setAccessibilityIdentifier(rootAccessibilityIdentifier)
        view = root

        setupSummaryBar()
        setupContainers()
        setupSplitView()
        setupFocusContainer()
        layoutSubviews()
        wireCallbacks()
        applyPresentationMode()
        applyLayoutPreference()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        guard splitView.arrangedSubviews.count > 1 else { return }
        guard splitCoordinator.needsInitialSplitValidation else { return }
        scheduleInitialSplitValidationIfNeeded()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupSummaryBar() {
        summaryBar.addSubview(summaryLabel)
        summaryBar.addSubview(focusButton)
        NSLayoutConstraint.activate([
            summaryLabel.leadingAnchor.constraint(equalTo: summaryBar.leadingAnchor, constant: 12),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: focusButton.leadingAnchor, constant: -12),
            summaryLabel.centerYAnchor.constraint(equalTo: summaryBar.centerYAnchor),

            focusButton.trailingAnchor.constraint(equalTo: summaryBar.trailingAnchor, constant: -12),
            focusButton.centerYAnchor.constraint(equalTo: summaryBar.centerYAnchor),
            summaryBar.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func setupContainers() {
        [
            summaryBar,
            splitView,
            listContainer,
            detailContainer,
            detailContentContainer,
            focusedDetailContainer,
            contigTableView,
            sequenceTableView,
        ].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        embeddedViewerController.publishesGlobalViewportNotifications = false

        listContainer.addSubview(contigTableView)
        listContainer.addSubview(sequenceTableView)
        detailContentContainer.addSubview(detailPlaceholderLabel)

        addChild(embeddedViewerController)
        let detailView = embeddedViewerController.view
        detailView.translatesAutoresizingMaskIntoConstraints = false
        detailContentContainer.addSubview(detailView, positioned: .below, relativeTo: detailPlaceholderLabel)
        attachDetailContent(to: detailContainer)

        NSLayoutConstraint.activate([
            contigTableView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            contigTableView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            contigTableView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            contigTableView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),

            sequenceTableView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            sequenceTableView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            sequenceTableView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            sequenceTableView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),

            detailView.topAnchor.constraint(equalTo: detailContentContainer.topAnchor),
            detailView.leadingAnchor.constraint(equalTo: detailContentContainer.leadingAnchor),
            detailView.trailingAnchor.constraint(equalTo: detailContentContainer.trailingAnchor),
            detailView.bottomAnchor.constraint(equalTo: detailContentContainer.bottomAnchor),

            detailPlaceholderLabel.centerXAnchor.constraint(equalTo: detailContentContainer.centerXAnchor),
            detailPlaceholderLabel.centerYAnchor.constraint(equalTo: detailContentContainer.centerYAnchor),
            detailPlaceholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: detailContentContainer.leadingAnchor, constant: 24),
            detailPlaceholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: detailContentContainer.trailingAnchor, constant: -24),
        ])
    }

    private func setupFocusContainer() {
        focusContainer.addSubview(focusedBackButton)
        focusContainer.addSubview(focusedDetailContainer)

        NSLayoutConstraint.activate([
            focusedBackButton.topAnchor.constraint(equalTo: focusContainer.topAnchor, constant: 10),
            focusedBackButton.leadingAnchor.constraint(equalTo: focusContainer.leadingAnchor, constant: 12),

            focusedDetailContainer.topAnchor.constraint(equalTo: focusedBackButton.bottomAnchor, constant: 10),
            focusedDetailContainer.leadingAnchor.constraint(equalTo: focusContainer.leadingAnchor),
            focusedDetailContainer.trailingAnchor.constraint(equalTo: focusContainer.trailingAnchor),
            focusedDetailContainer.bottomAnchor.constraint(equalTo: focusContainer.bottomAnchor),
        ])
    }

    private func setupSplitView() {
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.isVertical = true
        splitView.addArrangedSubview(listContainer)
        splitView.addArrangedSubview(detailContainer)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)
    }

    private func layoutSubviews() {
        view.addSubview(summaryBar)
        view.addSubview(splitView)
        view.addSubview(focusContainer)

        NSLayoutConstraint.activate([
            summaryBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            splitView.topAnchor.constraint(equalTo: summaryBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            focusContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            focusContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            focusContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            focusContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func wireCallbacks() {
        focusButton.target = self
        focusButton.action = #selector(enterFocusedDetailModeFromControl)
        focusedBackButton.target = self
        focusedBackButton.action = #selector(returnToListDetailModeFromControl)

        contigTableView.onRowSelected = { [weak self] row in
            self?.displaySelectedContig(row)
        }
        contigTableView.onSelectionCleared = { [weak self] in
            self?.showDetailPlaceholder("Select a mapped contig to inspect mapped reads.")
        }

        sequenceTableView.onRowSelected = { [weak self] row in
            self?.displaySelectedSequence(row.summary)
        }
        sequenceTableView.onSelectionCleared = { [weak self] in
            self?.showDetailPlaceholder("Select a sequence to inspect.")
        }
        sequenceTableView.onDisplayedRowsChanged = { [weak self] in
            self?.publishAnnotationScopeAndReconcileSequenceSelection()
        }
        embeddedViewerController.onSequenceRegionSelectionChanged = { [weak self] state in
            self?.onSequenceSelectionStateChanged?(state)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLayoutPreferenceChanged),
            name: .mappingLayoutSwapRequested,
            object: nil
        )
    }

    private func attachDetailContent(to container: NSView) {
        NSLayoutConstraint.deactivate(detailContentContainerConstraints)
        if detailContentContainer.superview !== container {
            detailContentContainer.removeFromSuperview()
            container.addSubview(detailContentContainer)
        }
        detailContentContainerConstraints = [
            detailContentContainer.topAnchor.constraint(equalTo: container.topAnchor),
            detailContentContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            detailContentContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            detailContentContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ]
        NSLayoutConstraint.activate(detailContentContainerConstraints)
    }

    @objc private func enterFocusedDetailModeFromControl() {
        enterFocusedDetailMode()
    }

    @objc private func returnToListDetailModeFromControl() {
        returnToListDetailMode()
    }

    private func enterFocusedDetailMode() {
        guard presentationMode != .focusedDetail else { return }
        presentationMode = .focusedDetail
        applyPresentationMode()
        publishAnnotationScopeAndReconcileSequenceSelection()
    }

    private func returnToListDetailMode() {
        guard presentationMode != .listDetail else { return }
        presentationMode = .listDetail
        applyPresentationMode()
        applyLayoutPreference()
        publishAnnotationScopeAndReconcileSequenceSelection()
    }

    private func applyPresentationMode() {
        switch presentationMode {
        case .listDetail:
            focusContainer.isHidden = true
            summaryBar.isHidden = false
            splitView.isHidden = false
            focusedBackButton.isHidden = true
            attachDetailContent(to: detailContainer)
        case .focusedDetail:
            attachDetailContent(to: focusedDetailContainer)
            summaryBar.isHidden = true
            splitView.isHidden = true
            focusedBackButton.isHidden = false
            focusContainer.isHidden = false
        }
    }

    @objc private func handleLayoutPreferenceChanged() {
        applyLayoutPreference()
    }

    private func defaultLeadingFraction(for layout: MappingPanelLayout) -> CGFloat {
        switch layout {
        case .detailLeading:
            return 0.6
        case .listLeading, .stacked:
            return 0.4
        }
    }

    private func minimumExtents(for layout: MappingPanelLayout) -> (leading: CGFloat, trailing: CGFloat) {
        switch layout {
        case .detailLeading:
            return (320, 320)
        case .listLeading, .stacked:
            return (320, 320)
        }
    }

    private func applyLayoutPreference() {
        guard splitView.arrangedSubviews.count > 1 else { return }
        let layout = MappingPanelLayout.current()
        let detailLeading = layout == .detailLeading
        splitCoordinator.applyLayoutPreference(
            to: splitView,
            desiredIsVertical: layout != .stacked,
            desiredFirstPane: detailLeading ? detailContainer : listContainer,
            desiredSecondPane: detailLeading ? listContainer : detailContainer,
            defaultLeadingFraction: defaultLeadingFraction(for: layout),
            minimumExtents: minimumExtents(for: layout),
            isViewInWindow: view.window != nil
        )
    }

    private func scheduleInitialSplitValidationIfNeeded() {
        splitCoordinator.scheduleInitialSplitValidationIfNeeded(
            ownerView: view,
            splitView: splitView,
            minimumExtents: { [weak self] in
                self?.minimumExtents(for: MappingPanelLayout.current()) ?? (320, 320)
            },
            defaultLeadingFraction: { [weak self] in
                self?.defaultLeadingFraction(for: MappingPanelLayout.current()) ?? 0.4
            }
        )
    }

    private func updateSummaryBar() {
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.toolTip = nil
        if let visibleAlignmentSummaryOverride {
            let pct = visibleAlignmentSummaryOverride.totalReads > 0
                ? String(
                    format: "%.1f%%",
                    Double(visibleAlignmentSummaryOverride.mappedReads)
                        / Double(visibleAlignmentSummaryOverride.totalReads) * 100
                )
                : "—"
            var text = "\(visibleAlignmentSummaryOverride.trackName) — \(visibleAlignmentSummaryOverride.mappedReads.formatted()) / \(visibleAlignmentSummaryOverride.totalReads.formatted()) reads mapped (\(pct))"
            if let alignmentTrackSummaryWarning {
                text += " — Warning: \(alignmentTrackSummaryWarning)"
                summaryLabel.textColor = .systemOrange
                summaryLabel.toolTip = alignmentTrackSummaryWarning
            }
            summaryLabel.stringValue = text
            return
        }

        guard let result = currentResult else {
            let title = currentInput?.documentTitle ?? "Reference Bundle"
            if let recordStoreWarning {
                summaryLabel.stringValue = "\(title) — Warning: \(recordStoreWarning)"
                summaryLabel.textColor = .systemOrange
                summaryLabel.toolTip = recordStoreWarning
            } else {
                summaryLabel.stringValue = title
            }
            return
        }
        let pct = result.totalReads > 0
            ? String(format: "%.1f%%", Double(result.mappedReads) / Double(result.totalReads) * 100)
            : "—"
        summaryLabel.stringValue = "\(result.mapper.displayName) Mapping — \(result.mappedReads.formatted()) / \(result.totalReads.formatted()) reads mapped (\(pct))"
    }

    func configure(input: ReferenceBundleViewportInput) throws {
        try configure(input: input, preferredSelectionName: nil)
    }

    private func configure(input: ReferenceBundleViewportInput, preferredSelectionName: String?) throws {
        currentInput = input
        currentResult = input.mappingResult
        currentResultDirectoryURL = input.mappingResultDirectoryURL
        loadedViewerBundleURL = nil
        visibleAlignmentSummaryOverride = nil
        recordStoreWarning = nil
        alignmentTrackSummaryWarning = nil
        alignmentTrackSummaryRefreshID = UUID()
        presentationMode = .listDetail
        applyPresentationMode()
        updateSummaryBar()

        switch input.kind {
        case .mappingResult:
            configureMappingRows(input.mappingResult, preferredSelectionName: preferredSelectionName)
        case .directBundle:
            try configureDirectBundleRows(input: input, preferredSelectionName: preferredSelectionName)
        }

        applyLayoutPreference()
    }

    private func configureMappingRows(_ result: MappingResult?, preferredSelectionName: String?) {
        usesRecordStoreTable = false
        sequenceRows = []
        sequenceTableView.configure(dynamicFields: [], rows: [])
        sequenceTableView.isHidden = true
        contigTableView.isHidden = false

        applyOriginalMappingRows(preferredSelectionName: preferredSelectionName)
        if let visibleTrackID = embeddedViewerController.viewerView.visibleAlignmentTrackIDSetting,
           !visibleTrackID.isEmpty {
            refreshMappingRowsForVisibleAlignmentTrack(
                visibleTrackID,
                preferredSelectionName: preferredSelectionName
            )
        }
    }

    private func configureDirectBundleRows(input: ReferenceBundleViewportInput, preferredSelectionName: String?) throws {
        usesRecordStoreTable = false
        contigTableView.configure(rows: [])
        contigTableView.isHidden = true
        sequenceTableView.isHidden = false

        guard let bundleURL = input.renderedBundleURL else {
            sequenceRows = []
            sequenceTableView.configure(dynamicFields: [], rows: [])
            showDetailPlaceholder("Reference bundle viewer unavailable for this mapping result.")
            return
        }

        let manifest: BundleManifest
        if let inputManifest = input.manifest {
            manifest = inputManifest
        } else {
            manifest = try BundleManifest.load(from: bundleURL)
        }
        let loadResult = try BundleBrowserLoader().load(bundleURL: bundleURL, manifest: manifest)
        let tableContent = loadRecordTableContent(
            bundleURL: bundleURL,
            manifest: manifest,
            summaries: loadResult.summary.sequences
        )
        sequenceRows = tableContent.rows
        usesRecordStoreTable = manifest.recordStore != nil
        recordStoreWarning = tableContent.warning
        updateSummaryBar()
        sequenceTableView.configure(dynamicFields: tableContent.fields, rows: sequenceRows)
        refreshSequenceSelection(preferredSelectionName: preferredSelectionName)
    }

    private func loadRecordTableContent(
        bundleURL: URL,
        manifest: BundleManifest,
        summaries: [BundleBrowserSequenceSummary]
    ) -> (
        fields: [GenBankRecordDatabase.FieldDefinition],
        rows: [ReferenceBundleRecordRow],
        warning: String?
    ) {
        let fallbackRows = summaries.map { ReferenceBundleRecordRow(summary: $0, values: [:]) }
        guard manifest.recordStore != nil else {
            return ([], fallbackRows, nil)
        }

        do {
            let bundle = ReferenceBundle(url: bundleURL, manifest: manifest)
            guard let database = try bundle.recordStoreDatabase() else {
                return ([], fallbackRows, nil)
            }
            let fields = try database.fieldDefinitions()
            let records = try database.records()

            var summariesByName: [String: BundleBrowserSequenceSummary] = [:]
            var duplicateSummaryNames: [String] = []
            for summary in summaries {
                if summariesByName.updateValue(summary, forKey: summary.name) != nil {
                    duplicateSummaryNames.append(summary.name)
                }
            }
            guard duplicateSummaryNames.isEmpty else {
                return ([], fallbackRows, "GenBank metadata contains ambiguous sequence identities; showing manifest records.")
            }

            var seenRecordNames = Set<String>()
            var mergedRows: [ReferenceBundleRecordRow] = []
            mergedRows.reserveCapacity(records.count)
            for record in records {
                guard seenRecordNames.insert(record.sequenceName).inserted else {
                    return ([], fallbackRows, "GenBank metadata contains ambiguous record identities; showing manifest records.")
                }
                guard let summary = summariesByName[record.sequenceName] else {
                    return ([], fallbackRows, "GenBank metadata does not match the bundled sequences; showing manifest records.")
                }
                guard summary.length == Int64(record.sequenceLength) else {
                    return ([], fallbackRows, "GenBank metadata does not match bundled sequence lengths; showing manifest records.")
                }
                mergedRows.append(ReferenceBundleRecordRow(summary: summary, values: record.values))
            }

            guard mergedRows.count == summaries.count else {
                return ([], fallbackRows, "GenBank metadata does not cover every bundled sequence; showing manifest records.")
            }
            return (fields, mergedRows, nil)
        } catch {
            return (
                [],
                fallbackRows,
                "Unable to read the declared GenBank metadata store; showing manifest records. \(error.localizedDescription)"
            )
        }
    }

    private func refreshSelection(preferredSelectionName: String? = nil) {
        guard !contigTableView.displayedRows.isEmpty else {
            if let viewerBundleURL = currentInput?.renderedBundleURL {
                do {
                    try loadViewerBundleIfNeeded(from: viewerBundleURL, sequenceName: "")
                    showDetailViewer()
                } catch {
                    showDetailPlaceholder("Unable to load the reference mapping viewer.")
                }
            } else {
                showDetailPlaceholder("Reference bundle viewer unavailable for this mapping result.")
            }
            return
        }

        if let preferredSelectionName,
           selectContig(named: preferredSelectionName) {
            return
        }

        selectContig(at: 0)
    }

    private func refreshSequenceSelection(preferredSelectionName: String? = nil) {
        guard !sequenceTableView.displayedRows.isEmpty else {
            showDetailPlaceholder("No sequences are available for this reference bundle.")
            return
        }

        if let preferredSelectionName,
           selectSequence(named: preferredSelectionName) {
            return
        }

        selectSequence(at: 0)
    }

    private func publishAnnotationScopeAndReconcileSequenceSelection() {
        guard currentInput?.kind == .directBundle, !sequenceTableView.isHidden else { return }

        guard !sequenceTableView.displayedRows.isEmpty else {
            embeddedViewerController.setAnnotationRecordScope([])
            sequenceTableView.tableView.deselectAll(nil)
            showDetailPlaceholder("No sequences are available for this reference bundle.")
            return
        }

        if currentSelectedSequence() == nil {
            selectSequence(at: 0)
        }

        let scope: Set<String>?
        if presentationMode == .focusedDetail {
            scope = currentSelectedSequence().map { [$0.summary.name] } ?? []
        } else {
            let hasActiveFilter = !sequenceTableView.currentFilterText
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !sequenceTableView.columnFilters.isEmpty
            scope = usesRecordStoreTable || hasActiveFilter
                ? Set(sequenceTableView.displayedRows.map(\.summary.name))
                : nil
        }
        embeddedViewerController.setAnnotationRecordScope(scope)
    }

    private func loadViewerBundleIfNeeded(from bundleURL: URL, sequenceName: String) throws {
        let standardized = bundleURL.standardizedFileURL
        if loadedViewerBundleURL == standardized {
            return
        }

        embeddedViewerController.clearViewport(statusMessage: "Loading reference viewer...")
        embeddedViewerController.annotationSearchIndex = nil
        try embeddedViewerController.displayBundle(
            at: standardized,
            mode: .sequence(name: sequenceName, restoreViewState: false)
        )
        rebuildEmbeddedAnnotationSearchIndex()
        loadedViewerBundleURL = standardized
    }

    @objc(reloadViewerBundleForInspectorChangesAndReturnError:)
    func reloadViewerBundleForInspectorChanges() throws {
        guard let input = currentInput else { return }
        let preferredSelectionName: String?
        switch input.kind {
        case .directBundle:
            preferredSelectionName = currentSelectedSequence()?.summary.name
        case .mappingResult:
            preferredSelectionName = currentSelectedContig()?.contigName
        }
        loadedViewerBundleURL = nil
        try configure(input: input, preferredSelectionName: preferredSelectionName)
    }

    var filteredAlignmentServiceTarget: AlignmentFilterTarget? {
        if let resultDirectoryURL = currentInput?.mappingResultDirectoryURL?.standardizedFileURL {
            return .mappingResult(resultDirectoryURL)
        }

        if let result = currentResult {
            return .mappingResult(result.bamURL.deletingLastPathComponent().standardizedFileURL)
        }
        return nil
    }

    func applyEmbeddedReadDisplaySettings(_ userInfo: [AnyHashable: Any]) {
        embeddedViewerController.applyReadDisplaySettings(userInfo)

        if userInfo.keys.contains(NotificationUserInfoKey.visibleAlignmentTrackID as AnyHashable) {
            refreshMappingRowsForVisibleAlignmentTrack(
                embeddedViewerController.viewerView.visibleAlignmentTrackIDSetting,
                preferredSelectionName: currentSelectedContig()?.contigName
            )
        }
    }

    func notifyEmbeddedReferenceBundleLoadedIfAvailable() {
        if let bundle = embeddedViewerController.viewerView.currentReferenceBundle {
            onEmbeddedReferenceBundleLoaded?(bundle)
        }
    }

    func currentSequenceAnnotationDraftContext() -> SequenceAnnotationDraftContext? {
        embeddedViewerController.localSequenceAnnotationDraftContext
    }

    func currentSequenceAnnotationOperationContext() -> SequenceAnnotationDraftContext? {
        embeddedViewerController.currentSequenceAnnotationOperationContext()
    }

    var activeSequenceViewerController: ViewerViewController {
        embeddedViewerController
    }

    func notifySequenceSelectionStateIfAvailable() {
        onSequenceSelectionStateChanged?(embeddedViewerController.currentSequenceRegionSelectionState())
    }

    func buildConsensusExportPayload() async throws -> (records: [String], suggestedName: String) {
        let request = try buildInspectorConsensusExportRequest()
        let consensus = try await embeddedViewerController.fetchMappingConsensusSequence(request)
        let record = ">\(request.recordName)\n\(consensus)\n"
        return ([record], request.suggestedName)
    }

    func buildConsensusExportRequest() throws -> MappingConsensusExportRequest {
        try buildConsensusExportRequest(explicitRegion: nil)
    }

    func buildVisibleViewportConsensusExportRequest() throws -> MappingConsensusExportRequest {
        try buildConsensusExportRequest(explicitRegion: visibleViewportConsensusRegion())
    }

    func buildSelectedRegionConsensusExportRequest() throws -> MappingConsensusExportRequest {
        guard let region = selectedConsensusRegion() else {
            throw NSError(
                domain: "Lungfish",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No selected region is available"]
            )
        }
        return try buildConsensusExportRequest(explicitRegion: region)
    }

    func buildSelectedAnnotationConsensusExportRequest() throws -> MappingConsensusExportRequest {
        guard let region = selectedAnnotationConsensusRegion() else {
            throw NSError(
                domain: "Lungfish",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No selected annotation is available"]
            )
        }
        return try buildConsensusExportRequest(explicitRegion: region)
    }

    func buildInspectorConsensusExportRequest() throws -> MappingConsensusExportRequest {
        guard let viewer = embeddedViewerController.viewerView else {
            return try buildVisibleViewportConsensusExportRequest()
        }
        if viewer.isUserColumnSelection,
           viewer.selectionRange?.isEmpty == false {
            return try buildSelectedRegionConsensusExportRequest()
        }
        return try buildVisibleViewportConsensusExportRequest()
    }

    private func buildConsensusExportRequest(
        explicitRegion: MappingConsensusExportRequestBuilder.ExplicitRegion?
    ) throws -> MappingConsensusExportRequest {
        guard let result = currentResult else {
            throw NSError(
                domain: "Lungfish",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No mapping result loaded"]
            )
        }

        let fallbackChromosome = embeddedViewerController.currentBundleDataProvider?
            .chromosomeInfo(named: embeddedViewerController.referenceFrame?.chromosome ?? "")

        return try MappingConsensusExportRequestBuilder.build(
            sampleName: result.bamURL.deletingPathExtension().deletingPathExtension().lastPathComponent,
            selectedContig: currentSelectedContig(),
            fallbackChromosome: fallbackChromosome,
            explicitRegion: explicitRegion,
            consensusMode: embeddedViewerController.viewerView.consensusModeSetting,
            consensusMinDepth: embeddedViewerController.viewerView.consensusMinDepthSetting,
            consensusMinMapQ: max(
                embeddedViewerController.viewerView.minMapQSetting,
                embeddedViewerController.viewerView.consensusMinMapQSetting
            ),
            consensusMinBaseQ: embeddedViewerController.viewerView.consensusMinBaseQSetting,
            excludeFlags: embeddedViewerController.viewerView.excludeFlagsSetting,
            useAmbiguity: embeddedViewerController.viewerView.consensusUseAmbiguitySetting
        )
    }

    private func visibleViewportConsensusRegion() -> MappingConsensusExportRequestBuilder.ExplicitRegion? {
        guard let frame = embeddedViewerController.referenceFrame else { return nil }
        return .init(
            chromosome: frame.chromosome,
            start: Int(floor(frame.start)),
            end: Int(ceil(frame.end)),
            label: "visible"
        )
    }

    private func selectedConsensusRegion() -> MappingConsensusExportRequestBuilder.ExplicitRegion? {
        guard let range = embeddedViewerController.viewerView.selectionRange else { return nil }
        let chromosome = embeddedViewerController.referenceFrame?.chromosome
            ?? embeddedViewerController.currentBundleDataProvider?.chromosomes.first?.name
            ?? ""
        guard !chromosome.isEmpty else { return nil }
        return .init(
            chromosome: chromosome,
            start: range.lowerBound,
            end: range.upperBound,
            label: "selection"
        )
    }

    private func selectedAnnotationConsensusRegion() -> MappingConsensusExportRequestBuilder.ExplicitRegion? {
        guard let annotation = embeddedViewerController.viewerView.selectedAnnotation else { return nil }
        let chromosome = annotation.chromosome
            ?? embeddedViewerController.referenceFrame?.chromosome
            ?? embeddedViewerController.currentBundleDataProvider?.chromosomes.first?.name
            ?? ""
        guard !chromosome.isEmpty else { return nil }
        return .init(
            chromosome: chromosome,
            start: annotation.start,
            end: annotation.end,
            label: "annotation \(annotation.name)"
        )
    }

    private func rebuildEmbeddedAnnotationSearchIndex() {
        guard let bundle = embeddedViewerController.viewerView.currentReferenceBundle else {
            embeddedViewerController.annotationSearchIndex = nil
            return
        }

        let index = AnnotationSearchIndex()
        let chromosomes = embeddedViewerController.currentBundleDataProvider?.chromosomes ?? []
        index.buildIndex(bundle: bundle, chromosomes: chromosomes)
        embeddedViewerController.annotationSearchIndex = index
        onEmbeddedReferenceBundleLoaded?(bundle)
    }

    private func displaySelectedContig(_ selectedContig: MappingContigSummary) {
        guard currentResult != nil else {
            showDetailPlaceholder("No mapping result loaded.")
            return
        }

        guard let viewerBundleURL = currentInput?.renderedBundleURL else {
            showDetailPlaceholder("Reference bundle viewer unavailable for this mapping result.")
            return
        }

        do {
            try loadViewerBundleIfNeeded(
                from: viewerBundleURL,
                sequenceName: selectedContig.contigName
            )
            guard let chromosome = embeddedViewerController.currentBundleDataProvider?.chromosomeInfo(named: selectedContig.contigName) else {
                showDetailPlaceholder("Selected contig is not present in the reference bundle.")
                return
            }

            showDetailViewer()
            embeddedViewerController.navigateToChromosomeAndPosition(
                chromosome: chromosome.name,
                chromosomeLength: Int(chromosome.length),
                start: 0,
                end: max(1, Int(chromosome.length))
            )
        } catch {
            showDetailPlaceholder("Unable to load the reference mapping viewer.")
        }
    }

    private func displaySelectedSequence(_ selectedSequence: BundleBrowserSequenceSummary) {
        guard let bundleURL = currentInput?.renderedBundleURL else {
            showDetailPlaceholder("Reference bundle viewer unavailable for this mapping result.")
            return
        }

        do {
            try loadViewerBundleIfNeeded(from: bundleURL, sequenceName: selectedSequence.name)
            guard let chromosome = embeddedViewerController.currentBundleDataProvider?.chromosomeInfo(named: selectedSequence.name) else {
                showDetailPlaceholder("Selected sequence is not present in the reference bundle.")
                return
            }

            showDetailViewer()
            embeddedViewerController.navigateToChromosomeAndPosition(
                chromosome: chromosome.name,
                chromosomeLength: Int(chromosome.length),
                start: 0,
                end: max(1, Int(chromosome.length))
            )
        } catch {
            showDetailPlaceholder("Unable to load sequence detail for \(selectedSequence.name).")
        }
    }

    private func showDetailViewer() {
        embeddedViewerController.view.isHidden = false
        detailPlaceholderLabel.isHidden = true
    }

    private func showDetailPlaceholder(_ message: String) {
        detailPlaceholderLabel.stringValue = message
        detailPlaceholderLabel.isHidden = false
        embeddedViewerController.view.isHidden = true
    }

    private func currentSelectedContig() -> MappingContigSummary? {
        let selectedRow = contigTableView.tableView.selectedRow
        guard selectedRow >= 0, selectedRow < contigTableView.displayedRows.count else { return nil }
        return contigTableView.displayedRows[selectedRow]
    }

    private func currentSelectedSequence() -> ReferenceBundleRecordRow? {
        let selectedRow = sequenceTableView.tableView.selectedRow
        guard selectedRow >= 0, selectedRow < sequenceTableView.displayedRows.count else { return nil }
        return sequenceTableView.displayedRows[selectedRow]
    }

    private func selectContig(named name: String) -> Bool {
        guard let row = contigTableView.displayedRows.firstIndex(where: { $0.contigName == name }) else { return false }
        selectContig(at: row)
        return true
    }

    private func selectContig(at row: Int) {
        guard row >= 0, row < contigTableView.displayedRows.count else { return }
        contigTableView.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        displaySelectedContig(contigTableView.displayedRows[row])
    }

    private func selectSequence(named name: String) -> Bool {
        guard let row = sequenceTableView.displayedRows.firstIndex(where: { $0.summary.name == name }) else { return false }
        selectSequence(at: row)
        return true
    }

    private func selectSequence(at row: Int) {
        guard row >= 0, row < sequenceTableView.displayedRows.count else { return }
        sequenceTableView.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        displaySelectedSequence(sequenceTableView.displayedRows[row].summary)
    }

    private func applyOriginalMappingRows(preferredSelectionName: String?) {
        visibleAlignmentSummaryOverride = nil
        alignmentTrackSummaryWarning = nil
        updateSummaryBar()
        contigTableView.configure(rows: currentResult?.contigs ?? [])
        refreshSelection(preferredSelectionName: preferredSelectionName)
    }

    private func refreshMappingRowsForVisibleAlignmentTrack(
        _ trackID: String?,
        preferredSelectionName: String?
    ) {
        guard currentInput?.kind == .mappingResult else { return }

        alignmentTrackSummaryWarning = nil
        alignmentTrackSummaryRefreshID = UUID()
        let refreshID = alignmentTrackSummaryRefreshID

        guard let trackID,
              !trackID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            applyOriginalMappingRows(preferredSelectionName: preferredSelectionName)
            return
        }

        guard let bundleURL = currentInput?.renderedBundleURL,
              let manifest = try? BundleManifest.load(from: bundleURL),
              let track = manifest.alignments.first(where: { $0.id == trackID })
        else {
            return
        }

        let bamURL = resolvedTrackURL(track.sourcePath, bundleURL: bundleURL)
        let mappedReads = Int(clamping: track.mappedReadCount ?? 0)
        let totalReads = mappedReads + Int(clamping: track.unmappedReadCount ?? 0)
        let summaryBuilder = alignmentTrackSummaryBuilder

        Task { @MainActor [weak self] in
            do {
                let summaries = try await summaryBuilder(bamURL, totalReads)
                guard let self,
                      self.alignmentTrackSummaryRefreshID == refreshID
                else {
                    return
                }
                self.applyVisibleAlignmentRows(
                    summaries,
                    track: track,
                    mappedReads: mappedReads,
                    totalReads: totalReads,
                    preferredSelectionName: preferredSelectionName
                )
            } catch {
                guard let self,
                      self.alignmentTrackSummaryRefreshID == refreshID
                else {
                    return
                }

                if let fallbackRows = self.metadataFallbackRows(
                    for: track,
                    bundleURL: bundleURL,
                    totalReads: totalReads
                ) {
                    self.applyVisibleAlignmentRows(
                        fallbackRows,
                        track: track,
                        mappedReads: mappedReads,
                        totalReads: totalReads,
                        preferredSelectionName: preferredSelectionName
                    )
                } else {
                    self.showDetailPlaceholder("Unable to compute alignment statistics for \(track.name).")
                }
            }
        }
    }

    private func applyVisibleAlignmentRows(
        _ summaries: [MappingContigSummary],
        track: AlignmentTrackInfo,
        mappedReads: Int,
        totalReads: Int,
        preferredSelectionName: String?
    ) {
        let filteredSummaries = summaries.filter { $0.mappedReads > 0 }
        let computedMappedReads = filteredSummaries.reduce(0) { $0 + $1.mappedReads }
        let displayMappedReads = mappedReads > 0 ? mappedReads : computedMappedReads
        let displayTotalReads = totalReads > 0 ? totalReads : displayMappedReads
        visibleAlignmentSummaryOverride = VisibleAlignmentSummary(
            trackName: track.name,
            mappedReads: displayMappedReads,
            totalReads: displayTotalReads
        )
        updateSummaryBar()
        contigTableView.configure(rows: filteredSummaries)
        refreshSelection(preferredSelectionName: preferredSelectionName)
    }

    private func metadataFallbackRows(
        for track: AlignmentTrackInfo,
        bundleURL: URL,
        totalReads: Int
    ) -> [MappingContigSummary]? {
        guard let metadataDBPath = track.metadataDBPath else { return nil }
        let metadataDBURL = resolvedTrackURL(metadataDBPath, bundleURL: bundleURL)
        guard let database = try? AlignmentMetadataDatabase(url: metadataDBURL) else { return nil }

        let rows = database.chromosomeStats()
            .filter { $0.mappedReads > 0 }
            .map { stat in
                MappingContigSummary(
                    contigName: stat.chromosome,
                    contigLength: Int(clamping: stat.length),
                    mappedReads: Int(clamping: stat.mappedReads),
                    mappedReadPercent: totalReads > 0
                        ? Double(stat.mappedReads) / Double(totalReads) * 100
                        : 0,
                    meanDepth: 0,
                    coverageBreadth: 0,
                    medianMAPQ: 0,
                    meanIdentity: 0
                )
            }

        return rows.isEmpty ? nil : rows
    }

    private func resolvedTrackURL(_ path: String, bundleURL: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        if path.hasPrefix("@/") {
            return bundleURL.appendingPathComponent(String(path.dropFirst(2)))
        }
        return bundleURL.appendingPathComponent(path)
    }
}

private struct VisibleAlignmentSummary: Equatable {
    let trackName: String
    let mappedReads: Int
    let totalReads: Int
}

private enum MappingResultExportError: LocalizedError {
    case noData
    case unsupportedFormat(ResultExportFormat)

    var errorDescription: String? {
        switch self {
        case .noData:
            return "No mapping result data is loaded; cannot export."
        case .unsupportedFormat(let format):
            return "Export format '\(format.rawValue)' is not supported for mapping results."
        }
    }
}

private enum MappingResultExportBuilder {
    private static let numericLocale = Locale(identifier: "en_US_POSIX")

    static func delimitedContent(for result: MappingResult, separator: String) -> String {
        let headers = [
            "Contig",
            "Length",
            "Mapped Reads",
            "% Mapped",
            "Mean Depth",
            "Coverage Breadth",
            "Median MAPQ",
            "Mean Identity",
        ]
        let rows = result.contigs.map { contig in
            [
                escaped(contig.contigName, separator: separator),
                "\(contig.contigLength)",
                "\(contig.mappedReads)",
                String(format: "%.4f", locale: numericLocale, contig.mappedReadPercent),
                String(format: "%.4f", locale: numericLocale, contig.meanDepth),
                String(format: "%.4f", locale: numericLocale, contig.coverageBreadth),
                String(format: "%.4f", locale: numericLocale, contig.medianMAPQ),
                String(format: "%.4f", locale: numericLocale, contig.meanIdentity),
            ].joined(separator: separator)
        }
        return ([headers.joined(separator: separator)] + rows).joined(separator: "\n") + "\n"
    }

    private static func escaped(_ value: String, separator: String) -> String {
        guard value.contains(separator) || value.contains("\"") || value.contains("\n") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

extension ReferenceBundleViewportController: ResultViewportController {
    public typealias ResultType = MappingResult

    public static var resultTypeName: String { "Mapping Results" }

    public func configure(result: MappingResult) {
        configure(result: result, resultDirectoryURL: nil)
    }

    public func configure(result: MappingResult, resultDirectoryURL: URL?) {
        let input = ReferenceBundleViewportInput.mappingResult(
            result: result,
            resultDirectoryURL: resultDirectoryURL,
            provenance: nil as MappingProvenance?
        )
        do {
            try configure(input: input)
        } catch {
            currentInput = input
            currentResult = result
            currentResultDirectoryURL = resultDirectoryURL?.standardizedFileURL
            showDetailPlaceholder("Unable to load the reference mapping viewer.")
        }
    }

    public var summaryBarView: NSView { summaryBar }

    public func exportResults(to url: URL, format: ResultExportFormat) throws {
        guard let result = currentResult else {
            throw MappingResultExportError.noData
        }

        switch format {
        case .csv:
            let startedAt = Date()
            let content = MappingResultExportBuilder.delimitedContent(for: result, separator: ",")
            try content.write(to: url, atomically: true, encoding: .utf8)
            try writeMappingResultExportProvenance(result: result, outputURL: url, format: format, startedAt: startedAt)
        case .tsv:
            let startedAt = Date()
            let content = MappingResultExportBuilder.delimitedContent(for: result, separator: "\t")
            try content.write(to: url, atomically: true, encoding: .utf8)
            try writeMappingResultExportProvenance(result: result, outputURL: url, format: format, startedAt: startedAt)
        case .json, .fasta:
            throw MappingResultExportError.unsupportedFormat(format)
        }
    }

    private func writeMappingResultExportProvenance(
        result: MappingResult,
        outputURL: URL,
        format: ResultExportFormat,
        startedAt: Date
    ) throws {
        let sourceURLs = mappingResultExportSourceURLs(for: result)
        try ScientificFileExportProvenance.write(.init(
            workflowName: "lungfish app mapping result export",
            sourceURLs: sourceURLs,
            outputURL: outputURL,
            outputFormat: .text,
            argv: [
                "Lungfish.app",
                "export-mapping-results",
                "--format",
                format.rawValue,
                "--output",
                outputURL.path,
            ],
            explicitOptions: [
                "format": .string(format.rawValue),
                "outputPath": .file(outputURL),
            ],
            resolved: [
                "contigCount": .integer(result.contigs.count),
                "mappedReads": .integer(result.mappedReads),
                "sourceCount": .integer(sourceURLs.count),
                "totalReads": .integer(result.totalReads),
            ],
            startedAt: startedAt
        ))
    }

    private func mappingResultExportSourceURLs(for result: MappingResult) -> [URL] {
        let primarySources = [
            currentResultDirectoryURL,
            currentInput?.renderedBundleURL,
        ]
        let fallbackSources = [
            result.bamURL,
            result.baiURL,
            result.sourceReferenceBundleURL,
            result.viewerBundleURL,
        ]
        return uniqueExistingURLs(primarySources.compactMap { $0 } + fallbackSources.compactMap { $0 })
    }

    private func uniqueExistingURLs(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.compactMap { url in
            let standardized = url.standardizedFileURL
            guard FileManager.default.fileExists(atPath: standardized.path),
                  seen.insert(standardized.path).inserted
            else {
                return nil
            }
            return standardized
        }
    }
}

extension ReferenceBundleViewportController: NSSplitViewDelegate {
    public func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard splitView === self.splitView else { return proposedPosition }
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let extents = minimumExtents(for: MappingPanelLayout.current())
        return SplitPaneSizing.clampedDividerPosition(
            proposed: proposedPosition,
            containerExtent: extent,
            minimumLeadingExtent: extents.leading,
            minimumTrailingExtent: extents.trailing
        )
    }

    public func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard let trackedSplitView = splitView as? TrackedDividerSplitView,
              trackedSplitView === self.splitView else { return }
        splitCoordinator.resizeSubviewsWithOldSize(
            trackedSplitView,
            oldSize: oldSize,
            defaultLeadingFraction: defaultLeadingFraction(for: MappingPanelLayout.current()),
            minimumExtents: minimumExtents(for: MappingPanelLayout.current())
        )
    }

    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard splitView.arrangedSubviews.count > 1 else { return }
        if splitCoordinator.needsInitialSplitValidation {
            scheduleInitialSplitValidationIfNeeded()
        }
        splitCoordinator.splitViewDidResizeSubviews(
            splitView,
            minimumExtents: minimumExtents(for: MappingPanelLayout.current())
        )
    }
}

#if DEBUG
extension ReferenceBundleViewportController {
    func configureForTesting(input: ReferenceBundleViewportInput) throws {
        try configure(input: input)
    }

    func configureForTesting(result: MappingResult, resultDirectoryURL: URL? = nil) {
        configure(result: result, resultDirectoryURL: resultDirectoryURL)
    }

    func reapplyMappingLayoutPreferenceForTesting() {
        splitCoordinator.invalidateInitialSplitPosition()
        applyLayoutPreference()
    }

    var testDisplayedSequenceNames: [String] { sequenceTableView.displayedRows.map(\.summary.name) }
    var testSelectedSequenceName: String? { currentSelectedSequence()?.summary.name }
    var testSelectedContigName: String? { currentSelectedContig()?.contigName }
    var testPresentationMode: PresentationMode { presentationMode }
    var testIsFocusedDetailMode: Bool { presentationMode == .focusedDetail }
    var testFocusedBackButtonAccessibilityIdentifier: String? { focusedBackButton.accessibilityIdentifier() }
    var testBackButtonAccessibilityIdentifier: String? { focusedBackButton.accessibilityIdentifier() }
    var testBackButtonIsHidden: Bool { focusContainer.isHidden || focusedBackButton.isHidden }
    var testSplitView: TrackedDividerSplitView { splitView }
    var testListContainer: NSView { listContainer }
    var testDetailContainer: NSView { detailContainer }
    var testSummaryText: String { summaryLabel.stringValue }
    var testRecordTableColumnIdentifiers: [String] {
        sequenceTableView.tableView.tableColumns.map(\.identifier.rawValue)
    }
    var testContigTableView: MappingContigTableView { contigTableView }
    var testDetailPlaceholderMessage: String { detailPlaceholderLabel.stringValue }
    var testEmbeddedViewerPublishesGlobalViewportNotifications: Bool {
        embeddedViewerController.publishesGlobalViewportNotifications
    }
    var testEmbeddedViewerShowsReferenceViewport: Bool {
        embeddedViewerController.referenceBundleViewportController != nil
    }
    var testEmbeddedViewerShowsChromosomeNavigator: Bool {
        embeddedViewerController.chromosomeNavigatorView != nil
    }
    var testFilteredAlignmentServiceTarget: AlignmentFilterTarget? {
        filteredAlignmentServiceTarget
    }
    var testCurrentSequenceAnnotationOperationContext: SequenceAnnotationDraftContext? {
        currentSequenceAnnotationOperationContext()
    }
    var testAnnotationRecordScope: Set<String>? { embeddedViewerController.annotationRecordScope }

    func testSelectContig(named name: String) {
        _ = selectContig(named: name)
    }

    func testSelectSequence(named name: String) {
        _ = selectSequence(named: name)
    }

    func testEnterFocusedDetailMode() {
        enterFocusedDetailMode()
    }

    func testTapBackButton() {
        focusedBackButton.performClick(nil)
    }

    func testReturnToListDetailMode() {
        returnToListDetailMode()
    }

    func testApplySequenceFilter(_ filter: String) {
        sequenceTableView.setFilterText(filter)
    }

    func testClearContigSelection() {
        contigTableView.tableView.deselectAll(nil)
    }

    func testBuildConsensusExportRequest() throws -> MappingConsensusExportRequest {
        try buildConsensusExportRequest()
    }

    func testBuildInspectorConsensusExportRequest() throws -> MappingConsensusExportRequest {
        try buildInspectorConsensusExportRequest()
    }

    func testSetEmbeddedSelectionRange(_ range: Range<Int>, isUserColumnSelection: Bool = true) {
        embeddedViewerController.viewerView.selectionRange = range
        embeddedViewerController.viewerView.isUserColumnSelection = isUserColumnSelection
    }

    func testSetEmbeddedReadDisplaySettings(minMapQ: Int, consensusMinMapQ: Int) {
        embeddedViewerController.viewerView.minMapQSetting = minMapQ
        embeddedViewerController.viewerView.consensusMinMapQSetting = consensusMinMapQ
    }

    func setAlignmentTrackSummaryBuilderForTesting(
        _ builder: @escaping (URL, Int) async throws -> [MappingContigSummary]
    ) {
        alignmentTrackSummaryBuilder = builder
    }
}
#endif
