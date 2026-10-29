// ReferenceBundleViewportController.swift - Shared viewport for reference bundles and mapping results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishOperations
import LungfishWorkflow
import LungfishKit

@MainActor
public class ReferenceBundleViewportController: NSViewController, SampleMetadataPresentationConsumer {
    enum PresentationMode: Equatable {
        case listDetail
        case focusedDetail
    }

    private(set) var currentInput: ReferenceBundleViewportInput?
    private(set) var presentationMode: PresentationMode = .listDetail
    private(set) var currentResult: MappingResult?
    private var currentResultDirectoryURL: URL?
    var loadedViewerBundleURL: URL?
    /// What each pane shows while a large reference opens (UX ruling Q-S1).
    let openProgress = ReferenceViewportOpenProgress()
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
            // The table shows rows with reads only, so rows for references without alignments are never built.
            includeUnmappedReferenceRows: false,
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
        ).rows
    }
    var alignmentTrackSummaryWarning: String? { didSet { alignmentTrackSummaryProgress = nil } }
    var alignmentTrackSummaryProgress: String?
    private var alignmentTrackSummaryRefreshID = UUID()
    private var visibleAlignmentSummaryOverride: VisibleAlignmentSummary?
    /// Row identity restoration emits the normal table selection callback.
    /// Suppress it while asynchronous mapping rows are being replaced so the
    /// previously-focused row cannot reapply a stale track/RG predicate.
    private var isReplacingMappingRows = false
    private var metadataPresentationContext: SampleMetadataPresentationContext?
    private var metadataPresentationObserverToken: SampleMetadataPresentationContext.ObserverToken?
    private var alignmentActionContextGeneration = 0
    private var alignmentActionContextTask: Task<Void, Never>?
    /// The running mapping row refresh, `nil` once it finishes. A newer refresh cancels it,
    /// which stops its samtools children, and the ready announcement waits for it.
    var mappingRowsRefreshTask: Task<Void, Never>?

    private struct AlignmentActionContextSeed: Sendable {
        let identity: AlignmentEvidenceIdentity
        let alignmentURL: URL
        let indexURL: URL
        let decodingReferenceURL: URL?
        let contig: String
        let contigLength: Int
        let filters: AlignmentConsensusFilters
        let outputCapability: AlignmentOutputCapability
        let sourceReads: AlignmentSourceReadResolution
        let presentationLabel: String
    }

    var onEmbeddedReferenceBundleLoaded: ((ReferenceBundle) -> Void)?
    var onSequenceSelectionStateChanged: ((SequenceRegionSelectionState?) -> Void)?
    var onConsensusActionStateChanged: (() -> Void)?

    private let embeddedViewerController = ViewerViewController()
    private let splitCoordinator = TwoPaneTrackedSplitCoordinator()

    let summaryBar: NSView = {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }()

    let summaryLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Reference Bundle")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier("reference-bundle-summary-label")
        return label
    }()
    /// How many reference sequences have alignments, when a result left some out (UX ruling Q-B2).
    let referenceCountLabel = MappingReferenceCountText.makeLabel()

    let focusButton: NSButton = {
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
    let listContainer = NSView()
    private let detailContainer = NSView()
    private let detailContentContainer = NSView()
    private var detailContentContainerConstraints: [NSLayoutConstraint] = []
    let contigTableView = MappingContigTableView()
    let sequenceTableView = ReferenceBundleRecordTable()

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
        mappingRowsRefreshTask?.cancel()
        if let metadataPresentationContext, let metadataPresentationObserverToken {
            Task { @MainActor in
                metadataPresentationContext.removeObserver(metadataPresentationObserverToken)
            }
        }
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
        summaryBar.addSubview(referenceCountLabel)
        summaryBar.addSubview(focusButton)
        NSLayoutConstraint.activate([
            summaryLabel.leadingAnchor.constraint(equalTo: summaryBar.leadingAnchor, constant: 12),
            referenceCountLabel.leadingAnchor.constraint(equalTo: summaryLabel.trailingAnchor, constant: 12),
            referenceCountLabel.trailingAnchor.constraint(lessThanOrEqualTo: focusButton.leadingAnchor, constant: -12),
            referenceCountLabel.centerYAnchor.constraint(equalTo: summaryBar.centerYAnchor),
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

        sequenceTableView.onCopySequences = { [weak self] rows, asFASTA in
            self?.copyReferenceSequences(rows, asFASTA: asFASTA)
        }
        sequenceTableView.onExtractSequences = { [weak self] rows in
            guard let self, let manifest = self.currentInput?.manifest else { return }
            let selectedNames = Set(rows.map(\.summary.name))
            let chromosomes = (manifest.genome?.chromosomes ?? []).filter { selectedNames.contains($0.name) }
            let name = rows.count == 1
                ? String(ReferenceBundleRecordTable.alleleName(for: rows[0]).prefix(100))
                : "selected-sequences"
            self.embeddedViewerController.extractSelectedChromosomesToNewBundle(chromosomes, suggestedBundleName: name)
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
        embeddedViewerController.onAlignmentConsensusActionStateChanged = { [weak self] in
            self?.onConsensusActionStateChanged?()
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
        case .stacked:
            return (64, 96)
        case .detailLeading, .listLeading:
            return (96, 96)
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
                self?.minimumExtents(for: MappingPanelLayout.current()) ?? (64, 96)
            },
            defaultLeadingFraction: { [weak self] in
                self?.defaultLeadingFraction(for: MappingPanelLayout.current()) ?? 0.4
            }
        )
    }

    private func updateSummaryBar() {
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.toolTip = nil
        MappingReferenceCountText.apply(to: referenceCountLabel, result: currentInput?.kind == .mappingResult ? currentResult : nil)
        if let summary = visibleAlignmentSummaryOverride {
            summaryLabel.stringValue = withSummaryWarning(Self.alignmentSummaryText(
                track: summary.trackName, mapped: summary.mappedReads, total: summary.totalReads, areReads: summary.countsAreReads
            ), tip: Self.alignmentSummaryTip(total: summary.totalReads, areReads: summary.countsAreReads))
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
        summaryLabel.stringValue = withSummaryWarning("\(result.mapper.displayName) Mapping — \(result.mappedReads.formatted()) / \(result.totalReads.formatted()) reads mapped (\(pct))")
    }

    func configure(input: ReferenceBundleViewportInput) throws {
        // Reconfiguring with the document already shown keeps the row the
        // user chose; a new document starts from its default selection.
        let preferredSelectionName = currentInput == input ? currentSelectionName() : nil
        try configure(input: input, preferredSelectionName: preferredSelectionName)
    }

    /// The name of the selected contig or sequence, whichever list this input shows.
    private func currentSelectionName() -> String? {
        switch currentInput?.kind {
        case .directBundle:
            return currentSelectedSequence()?.summary.name
        case .mappingResult:
            return currentSelectedContig()?.contigName
        case nil:
            return nil
        }
    }

    private func configure(input: ReferenceBundleViewportInput, preferredSelectionName: String?) throws {
        // SwiftUI's NSViewControllerRepresentable can configure this controller
        // before AppKit first requests its view. Selection immediately loads the
        // embedded viewer, whose progress overlay is created by loadView().
        _ = view
        // Focus mode is the user's choice of how to look at this document.
        // Reloading the same document (an Inspector-driven refresh, a repeated
        // display request) keeps it; only a different document starts in
        // list-detail mode.
        let keepsPresentationMode = currentInput == input
        clearAlignmentActionContext()
        currentInput = input
        currentResult = input.mappingResult
        currentResultDirectoryURL = input.mappingResultDirectoryURL
        loadedViewerBundleURL = nil
        visibleAlignmentSummaryOverride = nil
        recordStoreWarning = nil
        alignmentTrackSummaryWarning = nil
        alignmentTrackSummaryRefreshID = UUID()
        if !keepsPresentationMode {
            presentationMode = .listDetail
        }
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
            // The refresh reads the track's stats once, off the main actor, and
            // shows the rows with reads before the exact summaries finish.
            embeddedViewerController.viewerView.visibleAlignmentTrackIDSetting = visibleTrackID
            refreshMappingRowsForVisibleAlignmentTrack(
                visibleTrackID,
                preferredSelectionName: preferredSelectionName
            )
        }
    }

    private func copyReferenceSequences(_ rows: [ReferenceBundleRecordRow], asFASTA: Bool) {
        guard let input = currentInput, let bundleURL = input.renderedBundleURL,
              let manifest = input.manifest else { return }
        let provider = BundleDataProvider(bundleURL: bundleURL, manifest: manifest, referenceBundle: input.preparedBundle)
        Task { [weak self] in
            do {
                var sequences: [String] = []
                for row in rows {
                    guard let length = Int(exactly: row.summary.length) else { continue }
                    let bases = try await provider.fetchSequence(chromosome: row.summary.name, start: 0, end: length)
                    sequences.append(asFASTA ? ">\(ReferenceBundleRecordTable.fullReferenceName(for: row))\n\(bases)" : bases)
                }
                guard !sequences.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(sequences.joined(separator: "\n"), forType: .string)
            } catch {
                guard let self, let window = self.view.window else { return }
                FailurePresenter.present(ReferenceBundleFailureReports.copySequences(error), in: window)
            }
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
        sequenceTableView.displaysAlleles = bundleURL.pathComponents.contains {
            $0.lowercased().hasSuffix(".lungfishmhcref")
        }
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
    /// FASTA descriptions are looked up only for the rows the table shows
    /// (`configureMappingContigRows`), never for every reference sequence.
    private func applyMappingBundleDisplayLabels() {
        contigTableView.bundleDisplayName = currentInput?.viewerBundleManifest?.name
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

        embeddedViewerController.clearViewport(statusMessage: ReferenceViewportOpenProgress.loadingViewer)
        embeddedViewerController.annotationSearchIndex = nil
        // The manifest and bundle the open built once, never a second decode or index build here.
        let held = standardized == currentInput?.renderedBundleURL ? currentInput : nil
        try embeddedViewerController.displayBundle(
            at: standardized,
            mode: .sequence(name: sequenceName, restoreViewState: false),
            manifest: held?.manifest ?? held?.viewerBundleManifest,
            bundle: held?.preparedBundle
        )
        rebuildEmbeddedAnnotationSearchIndex()
        loadedViewerBundleURL = standardized
    }

    @objc(reloadViewerBundleForInspectorChangesAndReturnError:)
    func reloadViewerBundleForInspectorChanges() throws {
        guard let input = currentInput else { return }
        let preferredSelectionName = currentSelectionName()
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
        // The context is an immutable scientific snapshot. Never leave it
        // installed while any display/scientific filter is being replaced.
        clearAlignmentActionContext()
        embeddedViewerController.applyReadDisplaySettings(userInfo)

        guard currentInput?.kind == .mappingResult else {
            if let row = currentSelectedSequence(),
               row.alignmentTrackID == embeddedViewerController.viewerView.visibleAlignmentTrackIDSetting {
                installAlignmentActionContext(for: row)
            }
            return
        }

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
        } else if let row = currentSelectedContig(),
                  let bundleURL = currentInput?.renderedBundleURL {
            installAlignmentActionContext(for: row, bundleURL: bundleURL)
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
        mappingRowsRefreshTask?.cancel()
        visibleAlignmentSummaryOverride = nil
        alignmentTrackSummaryWarning = nil
        alignmentTrackSummaryProgress = tracks.map(\.name).joined(separator: ", ")
        updateSummaryBar()
        contigTableView.configure(rows: [])
        let builder = alignmentTrackSummaryBuilder
        // The record holds the rows of the mapping's own BAM, measured when the mapping ran.
        let (recordRows, resultBAMURL) = (currentResult?.contigs ?? [], currentResult?.bamURL)
        let trackFiles = tracks.map { track in
            (track: track,
             bamURL: resolvedTrackURL(track.sourcePath, bundleURL: bundleURL),
             databaseURL: track.metadataDBPath.map { resolvedTrackURL($0, bundleURL: bundleURL) })
        }
        mappingRowsRefreshTask = Task { @MainActor [weak self] in
            var rows: [MappingContigSummary] = []
            var failures: [(track: String, reason: String)] = []
            for (track, bamURL, databaseURL) in trackFiles {
                // One open of the track's stats database, off the main actor.
                // A track whose read groups carry no usable SM tag stays
                // visible as an unmatched, no-RG row in All Alignments.
                let stats = await AlignmentTrackStatsSnapshot.read(track: track, databaseURL: databaseURL)
                let usesRecordRows = stats.sampleCoversWholeBAM && stats.isImported(from: resultBAMURL)
                let rowsBeforeTrack = rows.count
                for (sampleID, readGroups) in stats.sampleReadGroups {
                    // A cancelled build reads as no rows, so a superseded refresh stops here.
                    guard !Task.isCancelled else { return }
                    var summaries = recordRows
                    if !usesRecordRows {
                        do {
                            summaries = try await builder(bamURL, stats.totalReads, readGroups)
                        } catch {
                            summaries = []
                            failures.append((track.name, error.localizedDescription))
                        }
                    }
                    guard !Task.isCancelled else { return }
                    rows += summaries.filter { $0.mappedReads > 0 }.map {
                        MappingContigSummary(sampleID: sampleID, alignmentTrackID: track.id, readGroupIDs: readGroups, contigName: $0.contigName, contigLength: $0.contigLength, mappedReads: $0.mappedReads, mappedReadPercent: $0.mappedReadPercent, meanDepth: $0.meanDepth, coverageBreadth: $0.coverageBreadth, medianMAPQ: $0.medianMAPQ, meanIdentity: $0.meanIdentity)
                    }
                }
                if stats.mappedReads > 0, rows.count == rowsBeforeTrack, !failures.contains(where: { $0.track == track.name }) {
                    failures.append((track.name, MappingSummaryReturnedNoRows().localizedDescription))
                }
            }
            guard let self, self.alignmentTrackSummaryRefreshID == refreshID else { return }
            self.alignmentTrackSummaryWarning = Self.measurementFailureWords(failures)
            self.updateSummaryBar()
            self.configureMappingContigRows(rows)
            // All-mode rows represent different BAM/RG predicates. Do not
            // auto-select one while the viewer is explicitly filtered to
            // "all"; detail is meaningful only after an explicit row choice.
            self.clearMappingSelectionAfterAllRebuild()
            self.finishMappingRowsRefresh()
        }
    }

    /// The variant tracks the embedded viewer currently hides.
    var embeddedHiddenVariantTrackIDs: Set<String> {
        embeddedViewerController.viewerView.hiddenVariantTrackIDs
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
        try buildConsensusExportRequest(scope: .wholeContig)
    }

    func buildVisibleViewportConsensusExportRequest() throws -> MappingConsensusExportRequest {
        // Compatibility adapter for callers that historically named this
        // method after viewport state. Scientific scope is now explicit.
        try buildConsensusExportRequest(scope: .wholeContig)
    }

    func buildSelectedRegionConsensusExportRequest() throws -> MappingConsensusExportRequest {
        try buildConsensusExportRequest(scope: .selectedRegion)
    }

    func buildSelectedAnnotationConsensusExportRequest() throws -> MappingConsensusExportRequest {
        // Annotation selection is a display convenience, not a scientific
        // consensus scope. It may only act through an explicit column range.
        try buildConsensusExportRequest(scope: .selectedRegion)
    }

    func buildInspectorConsensusExportRequest() throws -> MappingConsensusExportRequest {
        try buildConsensusExportRequest(scope: embeddedViewerController.alignmentConsensusScope)
    }

    func consensusScopeState() -> (scope: AlignmentConsensusScope, unavailableMessage: String?) {
        let scope = embeddedViewerController.alignmentConsensusScope
        guard let context = embeddedViewerController.alignmentActionContext else {
            return (scope, AlignmentScientificActionError.contextUnavailable.localizedDescription)
        }
        do {
            _ = try scope.resolve(in: context, selection: embeddedViewerController.explicitAlignmentSelection)
            return (scope, nil)
        } catch {
            return (scope, error.localizedDescription)
        }
    }

    func setConsensusScope(_ scope: AlignmentConsensusScope) {
        embeddedViewerController.alignmentConsensusScope = scope
    }

    func refreshAlignmentActionContextFilters() {
        guard let context = embeddedViewerController.alignmentActionContext,
              let filters = currentAlignmentFilters() else { return }
        embeddedViewerController.alignmentActionContext = try? context.replacingFilters(filters)
    }

    private func buildConsensusExportRequest(scope: AlignmentConsensusScope) throws -> MappingConsensusExportRequest {
        guard let context = embeddedViewerController.alignmentActionContext else {
            throw AlignmentScientificActionError.contextUnavailable
        }
        let region = try scope.resolve(
            in: context,
            selection: embeddedViewerController.explicitAlignmentSelection
        )
        return try MappingConsensusExportRequestBuilder.build(
            sampleName: context.identity.sampleID,
            context: context,
            region: region,
            consensusMode: embeddedViewerController.viewerView.consensusModeSetting,
            useAmbiguity: embeddedViewerController.viewerView.consensusUseAmbiguitySetting
        )
    }

    private func rebuildEmbeddedAnnotationSearchIndex() {
        guard let bundle = embeddedViewerController.viewerView.currentReferenceBundle else {
            embeddedViewerController.annotationSearchIndex = nil
            return
        }

        let index = AnnotationSearchIndex()
        index.onVariantFormatOverlayComplete = { [weak self, weak index, weak bundle] in
            guard let self, let index, let bundle,
                  self.embeddedViewerController.viewerView.currentReferenceBundle?.url.standardizedFileURL
                    == bundle.url.standardizedFileURL else { return }
            self.embeddedViewerController.annotationDrawerView?.refreshVariantFormatOverlay(from: index)
            self.embeddedViewerController.viewerView.invalidateVariantFormatHoverCache()
        }
        let chromosomes = embeddedViewerController.currentBundleDataProvider?.chromosomes ?? []
        index.buildIndex(bundle: bundle, chromosomes: chromosomes)
        embeddedViewerController.annotationSearchIndex = index
        onEmbeddedReferenceBundleLoaded?(bundle)
    }

    private func displaySelectedContig(
        _ selectedContig: MappingContigSummary,
        appliesAlignmentIdentity: Bool = true
    ) {
        if deferFirstViewerOpen({ [weak self] in
            self?.displaySelectedContig(selectedContig, appliesAlignmentIdentity: appliesAlignmentIdentity)
        }) { return }
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
            installAlignmentActionContext(
                for: selectedContig,
                bundleURL: viewerBundleURL
            )
        } catch {
            showDetailPlaceholder("Unable to load the reference mapping viewer.")
        }
    }

    private func displaySelectedSequence(_ row: ReferenceBundleRecordRow) {
        if deferFirstViewerOpen({ [weak self] in self?.displaySelectedSequence(row) }) { return }
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
        guard displaySelectedSequence(row.summary) else { return }
        installAlignmentActionContext(for: row)
    }

    @discardableResult
    private func displaySelectedSequence(_ selectedSequence: BundleBrowserSequenceSummary) -> Bool {
        guard let bundleURL = currentInput?.renderedBundleURL else {
            showDetailPlaceholder("Reference bundle viewer unavailable for this mapping result.")
            return false
        }

        do {
            try loadViewerBundleIfNeeded(from: bundleURL, sequenceName: selectedSequence.name)
            guard let chromosome = embeddedViewerController.currentBundleDataProvider?.chromosomeInfo(named: selectedSequence.name) else {
                showDetailPlaceholder("Selected sequence is not present in the reference bundle.")
                return false
            }

            showDetailViewer()
            embeddedViewerController.navigateToChromosomeAndPosition(
                chromosome: chromosome.name,
                chromosomeLength: Int(chromosome.length),
                start: 0,
                end: max(1, Int(chromosome.length))
            )
            return true
        } catch {
            showDetailPlaceholder("Unable to load sequence detail for \(selectedSequence.name).")
            return false
        }
    }

    private func showDetailViewer() {
        embeddedViewerController.view.isHidden = false
        detailPlaceholderLabel.isHidden = true
    }

    func showDetailPlaceholder(_ message: String) {
        clearAlignmentActionContext()
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
        let selectedContig = contigTableView.displayedRows[row]
        contigTableView.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        displaySelectedContig(
            selectedContig,
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
            var resolvedBindings: [(String?, String, Set<String>)] = resolution.identityIndex.canonicalSampleIDs.sorted().map { sampleID in
                (sampleID, track.id, resolution.identityIndex.readGroupIDs(forCanonicalSampleID: sampleID))
            }
            if !resolution.unmatchedReadGroupIDs.isEmpty {
                resolvedBindings.append((nil, track.id, resolution.unmatchedReadGroupIDs))
            }
            return resolvedBindings
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
        // A superseded refresh stops its samtools children, not only its output.
        mappingRowsRefreshTask?.cancel()
        mappingRowsRefreshTask = nil

        guard let trackID,
              !trackID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            applyOriginalMappingRows(preferredSelectionName: preferredSelectionName)
            return
        }

        // The viewer manifest the open decoded once, never a second decode here.
        guard let bundleURL = currentInput?.renderedBundleURL,
              let track = currentInput?.viewerBundleManifest?.alignments.first(where: { $0.id == trackID })
        else {
            return
        }

        let bamURL = resolvedTrackURL(track.sourcePath, bundleURL: bundleURL)
        let databaseURL = track.metadataDBPath.map { resolvedTrackURL($0, bundleURL: bundleURL) }
        let summaryBuilder = alignmentTrackSummaryBuilder
        let resultBAMURL = currentResult?.bamURL
        mappingRowsRefreshTask = Task { @MainActor [weak self] in
            // One open of the track's stats database for the whole refresh, off the main actor.
            let stats = await AlignmentTrackStatsSnapshot.read(track: track, databaseURL: databaseURL)
            // The mapping's own BAM shows the record's rows while its summaries are measured, and when they cannot be.
            // A track with a stats database that is not that BAM shows none until measured (a filtered track names no source). A track with no stats database keeps the rows shown.
            if let self, self.alignmentTrackSummaryRefreshID == refreshID {
                let preferred = self.currentSelectedContig()?.contigName ?? preferredSelectionName
                if stats.isImported(from: resultBAMURL) {
                    self.applyOriginalMappingRows(preferredSelectionName: preferred)
                } else if track.metadataDBPath != nil {
                    self.alignmentTrackSummaryProgress = track.name
                    self.applyVisibleAlignmentRows([], track: track, mappedReads: stats.mappedReads, totalReads: stats.totalReads, countsAreReads: stats.countsAreReads, preferredSelectionName: preferred)
                }
            }
            do {
                var sampleSummaries: [(sampleID: String?, readGroupIDs: Set<String>, summaries: [MappingContigSummary])] = []
                for sample in stats.sampleReadGroups {
                    // A no-RG sample is valid only when persisted identity proved
                    // this is the explicit single-sample fallback; aggregate
                    // metrics are then truthful for that one sample.
                    let summaries = try await summaryBuilder(bamURL, stats.totalReads, sample.readGroupIDs)
                    sampleSummaries.append((sample.sampleID, sample.readGroupIDs, summaries))
                }
                // Some managed samtools wrappers surface a failed streamed
                // subcommand as an empty, otherwise-successful parse. A track
                // that holds mapped reads and measures none failed to measure.
                if stats.mappedReads > 0, sampleSummaries.allSatisfy({ sample in
                    sample.summaries.allSatisfy { $0.mappedReads == 0 }
                }) {
                    throw MappingSummaryReturnedNoRows()
                }
                guard let self, self.alignmentTrackSummaryRefreshID == refreshID else { return }
                self.alignmentTrackSummaryProgress = nil
                self.applyVisibleAlignmentRows(
                    sampleSummaries, track: track, mappedReads: stats.mappedReads,
                    totalReads: stats.totalReads, countsAreReads: stats.countsAreReads, preferredSelectionName: preferredSelectionName
                )
                self.finishMappingRowsRefresh()
            } catch {
                guard !Task.isCancelled, let self, self.alignmentTrackSummaryRefreshID == refreshID else { return }
                self.alignmentTrackSummaryWarning = Self.measurementFailureWords([(track.name, error.localizedDescription)])
                self.updateSummaryBar()
                self.finishMappingRowsRefresh()
            }
        }
    }

    private func applyVisibleAlignmentRows(
        _ sampleSummaries: [(sampleID: String?, readGroupIDs: Set<String>, summaries: [MappingContigSummary])],
        track: AlignmentTrackInfo,
        mappedReads: Int,
        totalReads: Int,
        countsAreReads: Bool,
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
        // A total of 0 is none measured and stays 0, since showing the mapped count as the total printed 100%.
        visibleAlignmentSummaryOverride = VisibleAlignmentSummary(
            trackName: track.name,
            mappedReads: mappedReads > 0 ? mappedReads : computedMappedReads,
            totalReads: totalReads,
            countsAreReads: countsAreReads || totalReads <= 0
        )
        updateSummaryBar()
        configureMappingContigRows(filteredSummaries)
        refreshSelection(preferredSelectionName: preferredSelectionName)
    }

    private func configureMappingContigRows(_ rows: [MappingContigSummary]) {
        isReplacingMappingRows = true
        defer { isReplacingMappingRows = false }
        contigTableView.trackDisplayNamesByID = Dictionary(
            (currentInput?.viewerBundleManifest?.alignments ?? []).map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        contigTableView.fastaDescriptionsByContig = Self.fastaDescriptions(for: rows, in: currentInput?.viewerBundleManifest)
        contigTableView.configure(rows: rows)
        announceReadyIfUsable()
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

    private func resolvedTrackURL(_ path: String, bundleURL: URL) -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        if path.hasPrefix("@/") {
            return bundleURL.appendingPathComponent(String(path.dropFirst(2)))
        }
        return bundleURL.appendingPathComponent(path)
    }

    private func installAlignmentActionContext(
        for row: MappingContigSummary,
        bundleURL: URL
    ) {
        guard let result = currentResult else {
            clearAlignmentActionContext()
            return
        }
        guard let filters = currentAlignmentFilters() else {
            clearAlignmentActionContext()
            return
        }
        let track = row.alignmentTrackID.flatMap { trackID in
            currentInput?.viewerBundleManifest?.alignments.first { $0.id == trackID }
        }
        guard track?.format != .sam else {
            clearAlignmentActionContext()
            return
        }
        let alignmentURL = track.map { resolvedTrackURL($0.sourcePath, bundleURL: bundleURL) }
            ?? result.bamURL
        let indexURL = track.map { resolvedTrackURL($0.indexPath, bundleURL: bundleURL) }
            ?? result.baiURL
        let outputCapability: AlignmentOutputCapability = if let root = currentResultDirectoryURL
            ?? ProjectTempDirectory.findProjectRoot(alignmentURL) {
            .projectDerivedRoot(root)
        } else {
            .userSelectedDestination
        }
        let resultID = currentResultDirectoryURL?.lastPathComponent
            ?? result.bamURL.deletingLastPathComponent().lastPathComponent
        let evidenceID = "\(track?.id ?? alignmentURL.lastPathComponent):\(row.contigName)"
        scheduleAlignmentActionContext(.init(
            identity: .init(
                workflow: "mapping",
                resultID: resultID,
                sampleID: row.sampleID ?? "all-alignments",
                evidenceID: evidenceID
            ),
            alignmentURL: alignmentURL,
            indexURL: indexURL,
            decodingReferenceURL: decodingReferenceURL(for: track, manifest: currentInput?.viewerBundleManifest, bundleURL: bundleURL),
            contig: row.contigName,
            contigLength: row.contigLength,
            filters: filters,
            outputCapability: outputCapability,
            sourceReads: mappingSourceReads(),
            presentationLabel: "\(row.sampleID ?? "All alignments") — \(row.contigName)"
        ))
    }

    private func installAlignmentActionContext(for row: ReferenceBundleRecordRow) {
        guard let input = currentInput,
              input.kind == .directBundle,
              let bundleURL = input.renderedBundleURL,
              let manifest = input.manifest,
              let trackID = row.alignmentTrackID,
              let track = manifest.alignments.first(where: { $0.id == trackID }),
              track.format != .sam,
              let filters = currentAlignmentFilters()
        else {
            clearAlignmentActionContext()
            return
        }
        let outputCapability = ProjectTempDirectory.findProjectRoot(bundleURL)
            .map(AlignmentOutputCapability.projectDerivedRoot)
            ?? .userSelectedDestination
        scheduleAlignmentActionContext(.init(
            identity: .init(
                workflow: "reference-bundle",
                resultID: manifest.identifier,
                sampleID: row.sampleID ?? "all-alignments",
                evidenceID: "\(track.id):\(row.summary.name)"
            ),
            alignmentURL: resolvedTrackURL(track.sourcePath, bundleURL: bundleURL),
            indexURL: resolvedTrackURL(track.indexPath, bundleURL: bundleURL),
            decodingReferenceURL: decodingReferenceURL(for: track, manifest: manifest, bundleURL: bundleURL),
            contig: row.summary.name,
            contigLength: Int(row.summary.length),
            filters: filters,
            outputCapability: outputCapability,
            sourceReads: .bamFallback,
            presentationLabel: "\(row.sampleID ?? track.name) — \(row.summary.name)"
        ))
    }

    private func mappingSourceReads() -> AlignmentSourceReadResolution {
        let urls = currentInput?.mappingProvenance?.inputFASTQPaths
            .map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            ?? []
        return urls.isEmpty ? .bamFallback : .sourceFASTQs(urls)
    }

    private func decodingReferenceURL(
        for track: AlignmentTrackInfo?,
        manifest: BundleManifest?,
        bundleURL: URL
    ) -> URL? {
        guard track?.format == .cram, let path = manifest?.genome?.path else { return nil }
        return resolvedTrackURL(path, bundleURL: bundleURL)
    }

    private func currentAlignmentFilters() -> AlignmentConsensusFilters? {
        guard let settings = embeddedViewerController.viewerView else { return nil }
        return .init(
            minimumDepth: settings.consensusMinDepthSetting,
            minimumMapQ: max(settings.minMapQSetting, settings.consensusMinMapQSetting),
            minimumBaseQuality: settings.consensusMinBaseQSetting,
            excludedFlags: settings.excludeFlagsSetting,
            readGroups: settings.selectedReadGroupsSetting
        )
    }

    private func scheduleAlignmentActionContext(_ seed: AlignmentActionContextSeed) {
        clearAlignmentActionContext()
        let generation = alignmentActionContextGeneration
        alignmentActionContextTask = Task { @MainActor [weak self] in
            do {
                let context = try await Task.detached(priority: .userInitiated) {
                    func snapshot(_ url: URL) throws -> AlignmentEvidenceFileSnapshot {
                        AlignmentEvidenceFileSnapshot(
                            url: url,
                            byteCount: try ProvenanceFileHasher.fileSize(of: url),
                            sha256: try ProvenanceFileHasher.sha256(of: url)
                        )
                    }
                    let referenceSnapshot = try seed.decodingReferenceURL.map(snapshot)
                    return try AlignmentActionContext(
                        identity: seed.identity,
                        alignmentURL: seed.alignmentURL,
                        indexURL: seed.indexURL,
                        decodingReferenceURL: seed.decodingReferenceURL,
                        contig: seed.contig,
                        contigLength: seed.contigLength,
                        alignmentSnapshot: try snapshot(seed.alignmentURL),
                        indexSnapshot: try snapshot(seed.indexURL),
                        decodingReferenceSnapshot: referenceSnapshot,
                        filters: seed.filters,
                        outputCapability: seed.outputCapability,
                        sourceReads: seed.sourceReads,
                        presentationLabel: seed.presentationLabel
                    )
                }.value
                guard let self,
                      !Task.isCancelled,
                      self.alignmentActionContextGeneration == generation
                else { return }
                self.embeddedViewerController.alignmentActionContext = context
            } catch {
                guard let self, self.alignmentActionContextGeneration == generation else { return }
                self.embeddedViewerController.alignmentActionContext = nil
            }
        }
    }


    private func clearAlignmentActionContext() {
        alignmentActionContextGeneration += 1
        alignmentActionContextTask?.cancel()
        alignmentActionContextTask = nil
        embeddedViewerController.alignmentActionContext = nil
    }
}

private struct VisibleAlignmentSummary: Equatable {
    let trackName: String
    let mappedReads: Int
    let totalReads: Int
    let countsAreReads: Bool
}

extension ReferenceBundleViewportController {
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
}

extension ReferenceBundleViewportController: NSSplitViewDelegate {
    public func splitView(
        _ splitView: NSSplitView,
        effectiveRect proposedEffectiveRect: NSRect,
        forDrawnRect drawnRect: NSRect,
        ofDividerAt dividerIndex: Int
    ) -> NSRect {
        // Keep the thin divider visually quiet, but give it an easy-to-grab target.
        splitView.isVertical
            ? proposedEffectiveRect.insetBy(dx: -4, dy: 0)
            : proposedEffectiveRect.insetBy(dx: 0, dy: -4)
    }

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
            containerExtent: max(0, extent - splitView.dividerThickness),
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
    var testReferenceCountLabel: NSTextField { referenceCountLabel }
    var testRecordTableColumnIdentifiers: [String] {
        sequenceTableView.tableView.tableColumns.map(\.identifier.rawValue)
    }
    var testSequenceTableView: ReferenceBundleRecordTable { sequenceTableView }
    var testContigTableView: MappingContigTableView { contigTableView }
    var testDetailPlaceholderMessage: String { detailPlaceholderLabel.stringValue }
    var testEmbeddedViewerController: ViewerViewController { embeddedViewerController }
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
    var testAlignmentActionContext: AlignmentActionContext? {
        embeddedViewerController.alignmentActionContext
    }

    func testAwaitAlignmentActionContext() async {
        await alignmentActionContextTask?.value
    }


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
        if isUserColumnSelection, let contig = embeddedViewerController.alignmentActionContext?.contig {
            embeddedViewerController.setExplicitAlignmentSelection(
                contig: contig,
                start: range.lowerBound,
                end: range.upperBound
            )
        } else {
            embeddedViewerController.explicitAlignmentSelection = nil
        }
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
