// MappingResultViewController.swift - Viewport for read mapping results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishIO
import LungfishWorkflow

@MainActor
public final class MappingResultViewController: NSViewController {
    private(set) var currentResult: MappingResult?
    private var loadedViewerBundleURL: URL?

    var onEmbeddedReferenceBundleLoaded: ((ReferenceBundle) -> Void)?

    private let embeddedViewerController = ViewerViewController()
    private let splitCoordinator = TwoPaneTrackedSplitCoordinator()

    private let summaryBar: NSView = {
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        return bar
    }()

    private let summaryLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Mapping Results")
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setAccessibilityIdentifier("mapping-result-summary-label")
        return label
    }()

    private let splitView = TrackedDividerSplitView()
    private let listContainer = NSView()
    private let detailContainer = NSView()
    private let contigTableView = MappingContigTableView()

    private let detailPlaceholderLabel: NSTextField = {
        let label = NSTextField(labelWithString: "Select a mapped contig to inspect mapped reads.")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 0
        label.setAccessibilityIdentifier("mapping-result-detail-placeholder")
        return label
    }()

    public override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("Mapping result viewport")
        root.setAccessibilityIdentifier("mapping-result-view")
        view = root

        setupSummaryBar()
        setupContainers()
        setupSplitView()
        layoutSubviews()
        wireCallbacks()
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
        NSLayoutConstraint.activate([
            summaryLabel.leadingAnchor.constraint(equalTo: summaryBar.leadingAnchor, constant: 12),
            summaryLabel.trailingAnchor.constraint(lessThanOrEqualTo: summaryBar.trailingAnchor, constant: -12),
            summaryLabel.centerYAnchor.constraint(equalTo: summaryBar.centerYAnchor),
            summaryBar.heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    private func setupContainers() {
        [summaryBar, splitView, listContainer, detailContainer, contigTableView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        embeddedViewerController.publishesGlobalViewportNotifications = false

        listContainer.addSubview(contigTableView)
        detailContainer.addSubview(detailPlaceholderLabel)

        addChild(embeddedViewerController)
        let detailView = embeddedViewerController.view
        detailView.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(detailView, positioned: .below, relativeTo: detailPlaceholderLabel)

        NSLayoutConstraint.activate([
            contigTableView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            contigTableView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            contigTableView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            contigTableView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),

            detailView.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            detailView.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            detailView.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            detailView.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),

            detailPlaceholderLabel.centerXAnchor.constraint(equalTo: detailContainer.centerXAnchor),
            detailPlaceholderLabel.centerYAnchor.constraint(equalTo: detailContainer.centerYAnchor),
            detailPlaceholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: detailContainer.leadingAnchor, constant: 24),
            detailPlaceholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: detailContainer.trailingAnchor, constant: -24),
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

        NSLayoutConstraint.activate([
            summaryBar.topAnchor.constraint(equalTo: view.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            splitView.topAnchor.constraint(equalTo: summaryBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func wireCallbacks() {
        contigTableView.onRowSelected = { [weak self] row in
            self?.displaySelectedContig(row)
        }
        contigTableView.onSelectionCleared = { [weak self] in
            self?.showDetailPlaceholder("Select a mapped contig to inspect mapped reads.")
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLayoutPreferenceChanged),
            name: .mappingLayoutSwapRequested,
            object: nil
        )
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
        guard let result = currentResult else { return }
        let pct = result.totalReads > 0
            ? String(format: "%.1f%%", Double(result.mappedReads) / Double(result.totalReads) * 100)
            : "—"
        summaryLabel.stringValue = "\(result.mapper.displayName) Mapping — \(result.mappedReads.formatted()) / \(result.totalReads.formatted()) reads mapped (\(pct))"
    }

    private func refreshSelection() {
        guard !contigTableView.displayedRows.isEmpty else {
            if let viewerBundleURL = currentResult?.viewerBundleURL {
                do {
                    try loadViewerBundleIfNeeded(from: viewerBundleURL)
                    showDetailViewer()
                } catch {
                    showDetailPlaceholder("Unable to load the reference mapping viewer.")
                }
            } else {
                showDetailPlaceholder("Reference bundle viewer unavailable for this mapping result.")
            }
            return
        }

        contigTableView.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        displaySelectedContig(contigTableView.displayedRows[0])
    }

    private func loadViewerBundleIfNeeded(from bundleURL: URL) throws {
        let standardized = bundleURL.standardizedFileURL
        if loadedViewerBundleURL == standardized {
            return
        }

        embeddedViewerController.clearViewport(statusMessage: "Loading mapping viewer...")
        embeddedViewerController.annotationSearchIndex = nil
        try embeddedViewerController.displayBundle(at: standardized)
        rebuildEmbeddedAnnotationSearchIndex()
        loadedViewerBundleURL = standardized
    }

    @objc(reloadViewerBundleForInspectorChangesAndReturnError:)
    func reloadViewerBundleForInspectorChanges() throws {
        guard let viewerBundleURL = currentResult?.viewerBundleURL else { return }
        loadedViewerBundleURL = nil
        try loadViewerBundleIfNeeded(from: viewerBundleURL)
    }

    func applyEmbeddedReadDisplaySettings(_ userInfo: [AnyHashable: Any]) {
        embeddedViewerController.applyReadDisplaySettings(userInfo)
    }

    func notifyEmbeddedReferenceBundleLoadedIfAvailable() {
        if let bundle = embeddedViewerController.viewerView.currentReferenceBundle {
            onEmbeddedReferenceBundleLoaded?(bundle)
        }
    }

    func buildConsensusExportPayload() async throws -> (records: [String], suggestedName: String) {
        let request = try buildConsensusExportRequest()
        let consensus = try await embeddedViewerController.fetchMappingConsensusSequence(request)
        let record = ">\(request.recordName)\n\(consensus)\n"
        return ([record], request.suggestedName)
    }

    // TODO(2026-04-22): Add visible-viewport consensus export.
    // TODO(2026-04-22): Add selected-annotation consensus export.
    // TODO(2026-04-22): Add selected-region consensus export.
    func buildConsensusExportRequest() throws -> MappingConsensusExportRequest {
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
            consensusMode: embeddedViewerController.viewerView.consensusModeSetting,
            consensusMinDepth: embeddedViewerController.viewerView.consensusMinDepthSetting,
            consensusMinMapQ: embeddedViewerController.viewerView.consensusMinMapQSetting,
            consensusMinBaseQ: embeddedViewerController.viewerView.consensusMinBaseQSetting,
            excludeFlags: embeddedViewerController.viewerView.excludeFlagsSetting,
            useAmbiguity: embeddedViewerController.viewerView.consensusUseAmbiguitySetting
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
        guard let result = currentResult else {
            showDetailPlaceholder("No mapping result loaded.")
            return
        }

        guard let viewerBundleURL = result.viewerBundleURL else {
            showDetailPlaceholder("Reference bundle viewer unavailable for this mapping result.")
            return
        }

        do {
            try loadViewerBundleIfNeeded(from: viewerBundleURL)
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
        guard selectedRow >= 0 else { return nil }
        return contigTableView.record(at: selectedRow)
    }
}

extension MappingResultViewController: ResultViewportController {
    public typealias ResultType = MappingResult

    public static var resultTypeName: String { "Mapping Results" }

    public func configure(result: MappingResult) {
        currentResult = result
        loadedViewerBundleURL = nil
        updateSummaryBar()
        contigTableView.configure(rows: result.contigs)
        refreshSelection()
        applyLayoutPreference()
    }

    public var summaryBarView: NSView { summaryBar }

    public func exportResults(to url: URL, format: ResultExportFormat) throws {
        throw NSError(
            domain: "Lungfish",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Mapping export not yet implemented"]
        )
    }
}

extension MappingResultViewController: NSSplitViewDelegate {
    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard splitView.arrangedSubviews.count > 1 else { return }
        splitCoordinator.splitViewDidResizeSubviews(
            splitView,
            minimumExtents: minimumExtents(for: MappingPanelLayout.current())
        )
    }
}

#if DEBUG
extension MappingResultViewController {
    func configureForTesting(result: MappingResult) {
        configure(result: result)
    }

    var testSplitView: TrackedDividerSplitView { splitView }
    var testListContainer: NSView { listContainer }
    var testDetailContainer: NSView { detailContainer }
    var testSummaryText: String { summaryLabel.stringValue }
    var testContigTableView: MappingContigTableView { contigTableView }
    var testDetailPlaceholderMessage: String { detailPlaceholderLabel.stringValue }
    var testEmbeddedViewerPublishesGlobalViewportNotifications: Bool {
        embeddedViewerController.publishesGlobalViewportNotifications
    }

    func testSelectContig(named name: String) {
        guard let row = contigTableView.displayedRows.firstIndex(where: { $0.contigName == name }) else { return }
        contigTableView.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    func testClearContigSelection() {
        contigTableView.tableView.deselectAll(nil)
    }

    func testBuildConsensusExportRequest() throws -> MappingConsensusExportRequest {
        try buildConsensusExportRequest()
    }
}
#endif
