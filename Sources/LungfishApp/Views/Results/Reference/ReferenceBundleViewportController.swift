// ReferenceBundleViewportController.swift - Shared viewport for reference bundles and mapping results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow
import LungfishKit

@MainActor
public class ReferenceBundleViewportController: NSViewController, SampleMetadataPresentationConsumer {
    private struct AlignmentReadCounts {
        let mapped: Int
        let total: Int
    }

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
    private typealias AlignmentTrackSummaryBuilder = (URL, Int, Set<String>) async throws -> [MappingContigSummary]
    private lazy var alignmentTrackSummaryBuilder: AlignmentTrackSummaryBuilder = { [weak self] bamURL, totalReads, readGroupIDs in
        let refreshID = await self?.alignmentTrackSummaryRefreshID
        return try await MappingSummaryBuilder.build(
            sortedBAMURL: bamURL,
            totalReads: totalReads,
            readGroupIDs: readGroupIDs,
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
                // (recordStoreWarning's directBundle sibling). Guarded by the
                // same alignmentTrackSummaryRefreshID staleness check every
                // sibling completion/error path in
                // refreshMappingRowsForVisibleAlignmentTrack uses, so a
                // superseded refresh can't clobber a newer one's summary bar.
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard let self, self.alignmentTrackSummaryRefreshID == refreshID else { return }
                    self.alignmentTrackSummaryWarning = warning
                    self.updateSummaryBar()
                }}
            }
        )
    }
    private var alignmentTrackSummaryWarning: String?
    private var alignmentTrackSummaryRefreshID = UUID()
    private var visibleAlignmentSummaryOverride: VisibleAlignmentSummary?
    /// Row identity restoration emits the normal table selection callback.
    /// Suppress it while asynchronous mapping rows are being replaced so the
    /// previously-focused row cannot reapply a stale track/RG predicate.
    private var isReplacingMappingRows = false
    private var metadataPresentationContext: SampleMetadataPresentationContext?
    private var metadataPresentationObserverToken: SampleMetadataPresentationContext.ObserverToken?

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

    /// Connects this BAM list to its owning result's shared metadata store.
    /// Replacing a context unregisters the old result before the new store is
    /// delivered, so navigation cannot leave stale metadata columns behind.
    public func installSampleMetadataPresentation(
        _ context: SampleMetadataPresentationContext?
    ) {
        if metadataPresentationContext === context { return }
        if let metadataPresentationContext, let metadataPresentationObserverToken {
            metadataPresentationContext.removeObserver(metadataPresentationObserverToken)
        }
        metadataPresentationContext = context
        metadataPresentationObserverToken = context?.observe(self)
        if context == nil {
            applySampleMetadata(nil)
        }
    }

    public func applySampleMetadata(_ store: SampleMetadataStore?) {
        contigTableView.metadataColumns.update(store: store, sampleId: nil)
        sequenceTableView.metadataColumns.update(store: store, sampleId: nil)
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
            guard let self, !self.isReplacingMappingRows else { return }
            self.displaySelectedContig(row)
        }
        contigTableView.onSelectionCleared = { [weak self] in
            guard let self, !self.isReplacingMappingRows else { return }
            self.showDetailPlaceholder("Select a mapped contig to inspect mapped reads.")
        }

        sequenceTableView.onRowSelected = { [weak self] row in
            self?.displaySelectedSequence(row)
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

        applyMappingBundleDisplayLabels()
        applyOriginalMappingRows(preferredSelectionName: preferredSelectionName)
        let configuredTrackID = embeddedViewerController.viewerView.visibleAlignmentTrackIDSetting
        let alignmentTracks = currentInput?.viewerBundleManifest?.alignments ?? []
        let defaultTrackID = alignmentTracks
            .first(where: { $0.metadataDBPath != nil })?.id
            ?? alignmentTracks.first?.id
        let visibleTrackID = alignmentTracks.contains { $0.id == configuredTrackID }
            ? configuredTrackID
            : defaultTrackID
        if let visibleTrackID, !visibleTrackID.isEmpty {
            if let track = alignmentTracks.first(where: { $0.id == visibleTrackID }),
               let bundleURL = currentInput?.renderedBundleURL,
               let resolution = sampleIdentityResolution(for: track, bundleURL: bundleURL),
               resolution.identityIndex.canonicalSampleIDs.count == 1,
               resolution.unmatchedReadGroupIDs.isEmpty,
               let sampleID = resolution.identityIndex.canonicalSampleIDs.first {
                let readCounts = alignmentReadCounts(for: track, bundleURL: bundleURL)
                if let cachedRows = metadataFallbackRows(
                    for: track,
                    bundleURL: bundleURL,
                    totalReads: readCounts.total
                ) {
                    applyVisibleAlignmentRows(
                        [(
                            sampleID: sampleID,
                            readGroupIDs: resolution.identityIndex.readGroupIDs(forCanonicalSampleID: sampleID),
                            summaries: cachedRows
                        )],
                        track: track,
                        mappedReads: readCounts.mapped,
                        totalReads: readCounts.total,
                        preferredSelectionName: preferredSelectionName
                    )
                }
            }
            embeddedViewerController.viewerView.visibleAlignmentTrackIDSetting = visibleTrackID
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
        sequenceRows = directRows(
            from: tableContent.rows,
            manifest: manifest,
            bundleURL: bundleURL
        )
        usesRecordStoreTable = manifest.recordStore != nil
        recordStoreWarning = tableContent.warning
        updateSummaryBar()
        sequenceTableView.bundleDisplayName = manifest.name
        sequenceTableView.configure(dynamicFields: tableContent.fields, rows: sequenceRows)
        refreshSequenceSelection(preferredSelectionName: preferredSelectionName)
    }

    /// Sets the `contigTableView`'s bundle-name display decoration for
    /// `.mappingResult` inputs from `currentInput.viewerBundleManifest`
    /// (plumbed in by the caller — see `ReferenceBundleViewportController
    /// +MappingResult.swift`/`configure(result:resultDirectoryURL:)` —
    /// avoiding a second manifest disk read here). Absent manifest ⇒ nil
    /// display name ⇒ tables fall back to the bare contig id, unchanged
    /// from pre-Item-2 behavior.
    private func applyMappingBundleDisplayLabels() {
        guard let manifest = currentInput?.viewerBundleManifest else {
            contigTableView.bundleDisplayName = nil
            contigTableView.fastaDescriptionsByContig = [:]
            return
        }
        contigTableView.bundleDisplayName = manifest.name
        var descriptions: [String: String] = [:]
        for chromosome in manifest.genome?.chromosomes ?? [] {
            if let fastaDescription = chromosome.fastaDescription, !fastaDescription.isEmpty {
                descriptions[chromosome.name] = fastaDescription
            }
        }
        contigTableView.fastaDescriptionsByContig = descriptions
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
           selectContig(named: preferredSelectionName, appliesAlignmentIdentity: false) {
            return
        }

        // A refresh chooses a row to navigate, but it must not turn the first
        // All Alignments row into a new track/RG filter. Explicit table
        // selection still applies the identity carried by that row.
        selectContig(at: 0, appliesAlignmentIdentity: false)
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
            let tracks = currentInput?.viewerBundleManifest?.alignments ?? []
            let requestedTrackID = embeddedViewerController.viewerView.visibleAlignmentTrackIDSetting
            guard requestedTrackID != nil else {
                // "All Alignments" is an explicit no-track/no-RG predicate.
                // Unless a caller supplied an alternative RG value in the
                // same atomic update, clear the prior focused row's filter.
                if !userInfo.keys.contains(NotificationUserInfoKey.selectedReadGroups as AnyHashable) {
                    embeddedViewerController.applyReadDisplaySettings([
                        NotificationUserInfoKey.selectedReadGroups: Set<String>()
                    ])
                }
                refreshAllMetadataTracks(tracks, preferredSelectionName: currentSelectedContig()?.contigName)
                return
            }
            let effectiveTrackID = tracks.contains { $0.id == requestedTrackID } ? requestedTrackID : nil
            refreshMappingRowsForVisibleAlignmentTrack(
                effectiveTrackID,
                preferredSelectionName: currentSelectedContig()?.contigName
            )
        }
    }

    /// Rebuilds All Alignments from scratch. Clearing first is intentional:
    /// an all-track request must never continue showing a stale focused-track
    /// result while asynchronous RG-filtered summaries are running.
    private func refreshAllMetadataTracks(
        _ tracks: [AlignmentTrackInfo],
        preferredSelectionName: String?
    ) {
        guard currentInput?.kind == .mappingResult,
              let bundleURL = currentInput?.renderedBundleURL
        else { return }
        alignmentTrackSummaryRefreshID = UUID()
        let refreshID = alignmentTrackSummaryRefreshID
        visibleAlignmentSummaryOverride = nil
        alignmentTrackSummaryWarning = nil
        updateSummaryBar()
        contigTableView.configure(rows: [])
        let builder = alignmentTrackSummaryBuilder
        Task { @MainActor [weak self] in
            var rows: [MappingContigSummary] = []
            for track in tracks {
                let total = self?.alignmentReadCounts(for: track, bundleURL: bundleURL).total
                    ?? Int(clamping: (track.mappedReadCount ?? 0) + (track.unmappedReadCount ?? 0))
                let bamURL = self?.resolvedTrackURL(track.sourcePath, bundleURL: bundleURL) ?? bundleURL
                let resolution = self?.sampleIdentityResolution(for: track, bundleURL: bundleURL)
                let canonicalSampleIDs = resolution?.identityIndex.canonicalSampleIDs.sorted() ?? []
                let samples: [(sampleID: String?, readGroupIDs: Set<String>)]
                if canonicalSampleIDs.isEmpty {
                    // Metadata can exist while every RG has no usable SM tag.
                    // Keep this track visible as an unmatched, no-RG row
                    // rather than silently omitting it from All Alignments.
                    samples = [(sampleID: nil, readGroupIDs: [])]
                } else if let resolution {
                    samples = canonicalSampleIDs.map { sampleID in
                        (
                            sampleID: sampleID,
                            readGroupIDs: resolution.identityIndex.readGroupIDs(forCanonicalSampleID: sampleID)
                        )
                    }
                } else {
                    samples = [(sampleID: nil, readGroupIDs: [])]
                }
                let canUseAggregateFallback = samples.count == 1
                    && samples[0].sampleID != nil
                    && resolution?.unmatchedReadGroupIDs.isEmpty == true
                for (sampleID, readGroups) in samples {
                    let summaries: [MappingContigSummary]
                    if canUseAggregateFallback,
                       let cached = self?.metadataFallbackRows(for: track, bundleURL: bundleURL, totalReads: total) {
                        summaries = cached
                    } else {
                        summaries = (try? await builder(bamURL, total, readGroups)) ?? []
                    }
                    rows += summaries.filter { $0.mappedReads > 0 }.map {
                        MappingContigSummary(sampleID: sampleID, alignmentTrackID: track.id, readGroupIDs: readGroups, contigName: $0.contigName, contigLength: $0.contigLength, mappedReads: $0.mappedReads, mappedReadPercent: $0.mappedReadPercent, meanDepth: $0.meanDepth, coverageBreadth: $0.coverageBreadth, medianMAPQ: $0.medianMAPQ, meanIdentity: $0.meanIdentity)
                    }
                }
            }
            guard let self, self.alignmentTrackSummaryRefreshID == refreshID else { return }
            self.configureMappingContigRows(rows)
            // All-mode rows represent different BAM/RG predicates. Do not
            // auto-select one while the viewer is explicitly filtered to
            // "all"; detail is meaningful only after an explicit row choice.
            self.clearMappingSelectionAfterAllRebuild()
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

    private func displaySelectedContig(
        _ selectedContig: MappingContigSummary,
        appliesAlignmentIdentity: Bool = true
    ) {
        guard currentResult != nil else {
            showDetailPlaceholder("No mapping result loaded.")
            return
        }

        guard let viewerBundleURL = currentInput?.renderedBundleURL else {
            showDetailPlaceholder("Reference bundle viewer unavailable for this mapping result.")
            return
        }

        do {
            if appliesAlignmentIdentity {
                embeddedViewerController.applyReadDisplaySettings([
                    NotificationUserInfoKey.visibleAlignmentTrackID: selectedContig.alignmentTrackID ?? "",
                    NotificationUserInfoKey.selectedReadGroups: selectedContig.readGroupIDs,
                ])
            }
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

    private func displaySelectedSequence(_ row: ReferenceBundleRecordRow) {
        if let alignmentTrackID = row.alignmentTrackID {
            let settings: [AnyHashable: Any] = [
                NotificationUserInfoKey.visibleAlignmentTrackID: alignmentTrackID,
                // An explicit no-RG sample fallback is still a selection. It
                // must clear a previously-selected track's RG filter rather
                // than inheriting it and silently showing the wrong subset.
                NotificationUserInfoKey.selectedReadGroups: row.readGroupIDs,
            ]
            embeddedViewerController.applyReadDisplaySettings(settings)
        }
        displaySelectedSequence(row.summary)
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

    private func selectContig(named name: String, appliesAlignmentIdentity: Bool = true) -> Bool {
        guard let row = contigTableView.displayedRows.firstIndex(where: { $0.contigName == name }) else { return false }
        selectContig(at: row, appliesAlignmentIdentity: appliesAlignmentIdentity)
        return true
    }

    private func selectContig(at row: Int, appliesAlignmentIdentity: Bool = true) {
        guard row >= 0, row < contigTableView.displayedRows.count else { return }
        contigTableView.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        displaySelectedContig(
            contigTableView.displayedRows[row],
            appliesAlignmentIdentity: appliesAlignmentIdentity
        )
    }

    private func selectSequence(named name: String) -> Bool {
        guard let row = sequenceTableView.displayedRows.firstIndex(where: { $0.summary.name == name }) else { return false }
        selectSequence(at: row)
        return true
    }

    private func selectSequence(at row: Int) {
        guard row >= 0, row < sequenceTableView.displayedRows.count else { return }
        sequenceTableView.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        displaySelectedSequence(sequenceTableView.displayedRows[row])
    }

    /// Direct reference bundles normally show one row per sequence. If a
    /// persisted alignment metadata database resolves samples, expand that
    /// list to explicit sample × sequence × track rows. The resolver is the
    /// sole source of sample identity; tracks with no resolved sample remain
    /// as unbound reference rows rather than inheriting a filename-derived
    /// identity.
    private func directRows(
        from baseRows: [ReferenceBundleRecordRow],
        manifest: BundleManifest,
        bundleURL: URL
    ) -> [ReferenceBundleRecordRow] {
        let bindings = manifest.alignments.flatMap { track -> [(String?, String, Set<String>)] in
            guard let resolution = sampleIdentityResolution(for: track, bundleURL: bundleURL),
                  !resolution.identityIndex.canonicalSampleIDs.isEmpty
            else {
                // Keep a selectable, explicitly unmatched row for tracks that
                // have no usable persisted SM identity. It must not disappear
                // merely because another track resolves to a named sample.
                return [(nil, track.id, [])]
            }
            return resolution.identityIndex.canonicalSampleIDs.sorted().map { sampleID in
                (sampleID, track.id, resolution.identityIndex.readGroupIDs(forCanonicalSampleID: sampleID))
            }
        }
        guard !bindings.isEmpty else { return baseRows }
        return bindings.flatMap { sampleID, trackID, readGroupIDs in
            baseRows.map { row in
                ReferenceBundleRecordRow(
                    summary: row.summary,
                    values: row.values,
                    sampleID: sampleID,
                    alignmentTrackID: trackID,
                    readGroupIDs: readGroupIDs
                )
            }
        }
    }

    private func applyOriginalMappingRows(preferredSelectionName: String?) {
        visibleAlignmentSummaryOverride = nil
        alignmentTrackSummaryWarning = nil
        updateSummaryBar()
        configureMappingContigRows(currentResult?.contigs ?? [])
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
        let readCounts = alignmentReadCounts(for: track, bundleURL: bundleURL)
        let mappedReads = readCounts.mapped
        let totalReads = readCounts.total
        let summaryBuilder = alignmentTrackSummaryBuilder
        let resolution = sampleIdentityResolution(for: track, bundleURL: bundleURL)
        let sampleReadGroups: [(sampleID: String?, readGroupIDs: Set<String>)]
        if let resolution, !resolution.identityIndex.canonicalSampleIDs.isEmpty {
            sampleReadGroups = resolution.identityIndex.canonicalSampleIDs.sorted().map { sampleID in
                (sampleID, resolution.identityIndex.readGroupIDs(forCanonicalSampleID: sampleID))
            }
        } else {
            sampleReadGroups = [(nil, [])]
        }
        let canUseAggregateFallback = sampleReadGroups.count == 1
            && sampleReadGroups[0].sampleID != nil
            && resolution?.unmatchedReadGroupIDs.isEmpty == true

        // Cached metadata is immediately usable for a single resolved sample
        // and avoids an empty initial list while the expensive exact summary
        // process is starting. The async result below replaces these rows when
        // it completes. Multiple samples are intentionally not expanded from
        // aggregate track stats because that would fabricate per-sample reads.
        if canUseAggregateFallback,
           let fallbackRows = metadataFallbackRows(
            for: track,
            bundleURL: bundleURL,
            totalReads: totalReads
           ) {
            applyVisibleAlignmentRows(
                [(
                    sampleID: sampleReadGroups[0].sampleID,
                    readGroupIDs: sampleReadGroups[0].readGroupIDs,
                    summaries: fallbackRows
                )],
                track: track,
                mappedReads: mappedReads,
                totalReads: totalReads,
                preferredSelectionName: preferredSelectionName
            )
        }

        Task { @MainActor [weak self] in
            do {
                var sampleSummaries: [(sampleID: String?, readGroupIDs: Set<String>, summaries: [MappingContigSummary])] = []
                for sample in sampleReadGroups {
                    // A no-RG sample is valid only when persisted identity proved
                    // this is the explicit single-sample fallback; aggregate
                    // metrics are then truthful for that one sample.
                    let summaries = try await summaryBuilder(bamURL, totalReads, sample.readGroupIDs)
                    sampleSummaries.append((sample.sampleID, sample.readGroupIDs, summaries))
                }
                // Some managed samtools wrappers surface a failed streamed
                // subcommand as an empty, otherwise-successful parse. For a
                // single persisted sample, the bundle's indexed stats remain
                // a truthful initial sample × contig fallback; do not leave
                // the default metadata-bearing track blank until a manual
                // track toggle.
                if sampleSummaries.allSatisfy({ sample in
                    sample.summaries.isEmpty || sample.summaries.allSatisfy { $0.mappedReads == 0 }
                }),
                   canUseAggregateFallback,
                   let fallbackRows = self?.metadataFallbackRows(
                    for: track,
                    bundleURL: bundleURL,
                    totalReads: totalReads
                   ) {
                    sampleSummaries = [(
                        sampleID: sampleReadGroups[0].sampleID,
                        readGroupIDs: sampleReadGroups[0].readGroupIDs,
                        summaries: fallbackRows
                    )]
                }
                guard let self,
                      self.alignmentTrackSummaryRefreshID == refreshID
                else {
                    return
                }
                self.applyVisibleAlignmentRows(
                    sampleSummaries,
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
                ), canUseAggregateFallback {
                    self.applyVisibleAlignmentRows(
                        [(
                            sampleID: sampleReadGroups[0].sampleID,
                            readGroupIDs: sampleReadGroups[0].readGroupIDs,
                            summaries: fallbackRows
                        )],
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
        _ sampleSummaries: [(sampleID: String?, readGroupIDs: Set<String>, summaries: [MappingContigSummary])],
        track: AlignmentTrackInfo,
        mappedReads: Int,
        totalReads: Int,
        preferredSelectionName: String?
    ) {
        let filteredSummaries = sampleSummaries.flatMap { sample in
            sample.summaries.filter { $0.mappedReads > 0 }.map { summary in
                MappingContigSummary(
                    sampleID: sample.sampleID,
                    alignmentTrackID: track.id,
                    readGroupIDs: sample.readGroupIDs,
                    contigName: summary.contigName,
                    contigLength: summary.contigLength,
                    mappedReads: summary.mappedReads,
                    mappedReadPercent: summary.mappedReadPercent,
                    meanDepth: summary.meanDepth,
                    coverageBreadth: summary.coverageBreadth,
                    medianMAPQ: summary.medianMAPQ,
                    meanIdentity: summary.meanIdentity
                )
            }
        }
        let computedMappedReads = filteredSummaries.reduce(0) { $0 + $1.mappedReads }
        let displayMappedReads = mappedReads > 0 ? mappedReads : computedMappedReads
        let displayTotalReads = totalReads > 0 ? totalReads : displayMappedReads
        visibleAlignmentSummaryOverride = VisibleAlignmentSummary(
            trackName: track.name,
            mappedReads: displayMappedReads,
            totalReads: displayTotalReads
        )
        updateSummaryBar()
        configureMappingContigRows(filteredSummaries)
        refreshSelection(preferredSelectionName: preferredSelectionName)
    }

    private func configureMappingContigRows(_ rows: [MappingContigSummary]) {
        isReplacingMappingRows = true
        defer { isReplacingMappingRows = false }
        contigTableView.configure(rows: rows)
    }

    private func clearMappingSelectionAfterAllRebuild() {
        contigTableView.tableView.deselectAll(nil)
        showDetailPlaceholder("Select a mapped contig to inspect mapped reads.")
    }

    private func sampleIdentityResolution(
        for track: AlignmentTrackInfo,
        bundleURL: URL?
    ) -> BAMSampleIdentityResolver.Resolution? {
        guard let bundleURL,
              let metadataDBPath = track.metadataDBPath,
              let database = try? AlignmentMetadataDatabase(
                url: resolvedTrackURL(metadataDBPath, bundleURL: bundleURL)
              )
        else {
            return nil
        }
        let explicitSampleID = track.sampleNames.count == 1 ? track.sampleNames[0] : nil
        let trackSampleIDs = explicitSampleID.map { [track.id: $0] } ?? [:]
        return try? BAMSampleIdentityResolver.resolve(
            readGroups: database.readGroups(),
            trackIDs: [track.id],
            explicitResultSampleID: explicitSampleID,
            trackSampleIDs: trackSampleIDs
        )
    }

    private func alignmentReadCounts(
        for track: AlignmentTrackInfo,
        bundleURL: URL
    ) -> AlignmentReadCounts {
        let manifestMapped = Int(clamping: track.mappedReadCount ?? 0)
        let manifestTotal = manifestMapped + Int(clamping: track.unmappedReadCount ?? 0)
        let fallback = AlignmentReadCounts(mapped: manifestMapped, total: manifestTotal)
        guard let metadataDBPath = track.metadataDBPath,
              let database = try? AlignmentMetadataDatabase(
                url: resolvedTrackURL(metadataDBPath, bundleURL: bundleURL)
              )
        else {
            return fallback
        }

        let flagStats = database.flagStats()
        if let totalRecord = flagStats.first(where: { $0.category == "total" }),
           let mappedRecord = flagStats.first(where: { $0.category == "mapped" }) {
            let total = totalRecord.qcPass.addingReportingOverflow(totalRecord.qcFail)
            let mapped = mappedRecord.qcPass.addingReportingOverflow(mappedRecord.qcFail)
            if !total.overflow,
               !mapped.overflow,
               total.partialValue >= 0,
               mapped.partialValue >= 0,
               total.partialValue >= mapped.partialValue {
                return AlignmentReadCounts(
                    mapped: Int(clamping: mapped.partialValue),
                    total: Int(clamping: total.partialValue)
                )
            }
        }

        let databaseMapped = database.totalMappedReads()
        let databaseUnmapped = database.totalUnmappedReads()
        let databaseTotal = databaseMapped.addingReportingOverflow(databaseUnmapped)
        guard databaseMapped >= 0,
              databaseUnmapped >= 0,
              !databaseTotal.overflow,
              databaseTotal.partialValue > 0 else {
            return fallback
        }
        return AlignmentReadCounts(
            mapped: Int(clamping: databaseMapped),
            total: Int(clamping: databaseTotal.partialValue)
        )
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
        // Loaded only for display decoration (selector-cell bundle name,
        // track header label) — deliberately NOT the input's `manifest`
        // field, which drives `documentTitle` and must stay `nil` here.
        // Missing/unreadable viewer bundle degrades to `nil` silently; the
        // tables and track header then fall back to the bare contig id.
        let viewerBundleManifest = result.viewerBundleURL.flatMap {
            try? BundleManifest.load(from: $0)
        }
        let input = ReferenceBundleViewportInput.mappingResult(
            result: result,
            resultDirectoryURL: resultDirectoryURL,
            provenance: nil as MappingProvenance?,
            viewerBundleManifest: viewerBundleManifest
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
    var testSequenceTableView: ReferenceBundleRecordTable { sequenceTableView }
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

    func testSelectContig(sampleID: String?, alignmentTrackID: String?, named name: String) {
        guard let row = contigTableView.displayedRows.firstIndex(where: {
            $0.sampleID == sampleID
                && $0.alignmentTrackID == alignmentTrackID
                && $0.contigName == name
        }) else { return }
        selectContig(at: row)
    }

    func testSelectSequence(named name: String) {
        _ = selectSequence(named: name)
    }

    func testSelectSequence(sampleID: String, named name: String) {
        guard let row = sequenceTableView.displayedRows.firstIndex(where: {
            $0.sampleID == sampleID && $0.summary.name == name
        }) else { return }
        selectSequence(at: row)
    }

    func testSelectSequence(sampleID: String?, alignmentTrackID: String?, named name: String) {
        guard let row = sequenceTableView.displayedRows.firstIndex(where: {
            $0.sampleID == sampleID
                && $0.alignmentTrackID == alignmentTrackID
                && $0.summary.name == name
        }) else { return }
        selectSequence(at: row)
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
        alignmentTrackSummaryBuilder = { bamURL, totalReads, _ in
            try await builder(bamURL, totalReads)
        }
    }

    func setAlignmentTrackSummaryBuilderForTesting(
        _ builder: @escaping (URL, Int, Set<String>) async throws -> [MappingContigSummary]
    ) {
        alignmentTrackSummaryBuilder = builder
    }

    var testSelectedReadGroups: Set<String> { embeddedViewerController.viewerView.selectedReadGroupsSetting }
    var testVisibleAlignmentTrackID: String? { embeddedViewerController.viewerView.visibleAlignmentTrackIDSetting }
    var testDisplayedSequenceSampleIDs: [String?] { sequenceTableView.displayedRows.map(\.sampleID) }
}
#endif
