// ReferenceBundleViewportController.swift - Shared viewport for reference bundles and mapping results
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import LungfishIO
import LungfishWorkflow

@MainActor
final class ReferenceSequenceTableView: BatchTableView<BundleBrowserSequenceSummary> {
    var onDisplayedRowsChanged: (() -> Void)?

    override var columnSpecs: [BatchColumnSpec] {
        [
            .init(identifier: .init("sequence"), title: "Sequence", width: 220, minWidth: 140, defaultAscending: true),
            .init(identifier: .init("length"), title: "Length", width: 100, minWidth: 80, defaultAscending: false),
            .init(identifier: .init("role"), title: "Role", width: 100, minWidth: 80, defaultAscending: true),
        ]
    }

    override var searchPlaceholder: String { "Filter sequences\u{2026}" }
    override var searchAccessibilityIdentifier: String? { "reference-bundle-sequence-search" }
    override var searchAccessibilityLabel: String? { "Filter reference sequences" }
    override var tableAccessibilityIdentifier: String? { "reference-bundle-sequence-table" }
    override var tableAccessibilityLabel: String? { "Reference sequence table" }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        finishSetup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        finishSetup()
    }

    private func finishSetup() {
        tableView.allowsMultipleSelection = false
        tableView.sortDescriptors = [
            NSSortDescriptor(key: "sequence", ascending: true),
        ]
    }

    override func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: BundleBrowserSequenceSummary
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        switch column.rawValue {
        case "sequence":
            return (row.name, .left, .systemFont(ofSize: 12))
        case "length":
            return (row.length.formatted(), .right, numericFont)
        case "role":
            return (roleDescription(for: row), .left, .systemFont(ofSize: 12))
        default:
            return ("", .left, nil)
        }
    }

    override func columnValue(for columnId: String, row: BundleBrowserSequenceSummary) -> String {
        switch columnId {
        case "sequence":
            return row.name
        case "length":
            return "\(row.length)"
        case "role":
            return roleDescription(for: row)
        default:
            return super.columnValue(for: columnId, row: row)
        }
    }

    override func rowMatchesFilter(_ row: BundleBrowserSequenceSummary, filterText: String) -> Bool {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        let haystack = [
            row.name,
            row.displayDescription ?? "",
            row.length.formatted(),
            row.aliases.joined(separator: " "),
            roleDescription(for: row),
        ]

        return haystack.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    override func compareRows(
        _ lhs: BundleBrowserSequenceSummary,
        _ rhs: BundleBrowserSequenceSummary,
        by key: String,
        ascending: Bool
    ) -> Bool {
        let comparison: ComparisonResult
        switch key {
        case "sequence":
            comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        case "length":
            comparison = compare(lhs.length, rhs.length)
        case "role":
            comparison = roleDescription(for: lhs).localizedCaseInsensitiveCompare(roleDescription(for: rhs))
        default:
            comparison = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        }

        if comparison == .orderedSame {
            let fallback = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if fallback == .orderedSame {
                return false
            }
            return ascending ? fallback == .orderedAscending : fallback == .orderedDescending
        }

        return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
    }

    override func didApplyDisplayedRows() {
        onDisplayedRowsChanged?()
    }

    private var numericFont: NSFont {
        .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    }

    private func roleDescription(for row: BundleBrowserSequenceSummary) -> String {
        if row.isMitochondrial {
            return "Mitochondrial"
        }
        return row.isPrimary ? "Primary" : "Alternate"
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs {
            return .orderedAscending
        }
        if lhs > rhs {
            return .orderedDescending
        }
        return .orderedSame
    }
}

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
    private var sequenceRows: [BundleBrowserSequenceSummary] = []

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
        LungfishAppKitControlStyle.applyInspectorMetrics(to: button)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setAccessibilityIdentifier("reference-viewport-focus-button")
        button.setAccessibilityLabel("Focus reference detail")
        return button
    }()

    private let focusContainer: NSView = {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isHidden = true
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        return container
    }()

    private let focusedBackButton: NSButton = {
        let button = NSButton(title: "Back", target: nil, action: nil)
        button.bezelStyle = .rounded
        LungfishAppKitControlStyle.applyInspectorMetrics(to: button)
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
    private let sequenceTableView = ReferenceSequenceTableView()

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
            summaryBar.topAnchor.constraint(equalTo: view.topAnchor),
            summaryBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            splitView.topAnchor.constraint(equalTo: summaryBar.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            focusContainer.topAnchor.constraint(equalTo: view.topAnchor),
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
            self?.displaySelectedSequence(row)
        }
        sequenceTableView.onSelectionCleared = { [weak self] in
            self?.showDetailPlaceholder("Select a sequence to inspect.")
        }
        sequenceTableView.onDisplayedRowsChanged = { [weak self] in
            self?.reconcileSequenceSelectionAfterDisplayedRowsChanged()
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
    }

    private func returnToListDetailMode() {
        guard presentationMode != .listDetail else { return }
        presentationMode = .listDetail
        applyPresentationMode()
        applyLayoutPreference()
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
        guard let result = currentResult else {
            summaryLabel.stringValue = currentInput?.documentTitle ?? "Reference Bundle"
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
        sequenceRows = []
        sequenceTableView.configure(rows: [])
        sequenceTableView.isHidden = true
        contigTableView.isHidden = false
        contigTableView.configure(rows: result?.contigs ?? [])
        refreshSelection(preferredSelectionName: preferredSelectionName)
    }

    private func configureDirectBundleRows(input: ReferenceBundleViewportInput, preferredSelectionName: String?) throws {
        contigTableView.configure(rows: [])
        contigTableView.isHidden = true
        sequenceTableView.isHidden = false

        guard let bundleURL = input.renderedBundleURL else {
            sequenceRows = []
            sequenceTableView.configure(rows: [])
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
        sequenceRows = loadResult.summary.sequences
        sequenceTableView.configure(rows: sequenceRows)
        refreshSequenceSelection(preferredSelectionName: preferredSelectionName)
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

    private func reconcileSequenceSelectionAfterDisplayedRowsChanged() {
        guard currentInput?.kind == .directBundle, !sequenceTableView.isHidden else { return }

        guard !sequenceTableView.displayedRows.isEmpty else {
            sequenceTableView.tableView.deselectAll(nil)
            showDetailPlaceholder("No sequences are available for this reference bundle.")
            return
        }

        if let selected = currentSelectedSequence() {
            displaySelectedSequence(selected)
            return
        }

        selectSequence(at: 0)
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
            preferredSelectionName = currentSelectedSequence()?.name
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
    }

    func notifyEmbeddedReferenceBundleLoadedIfAvailable() {
        if let bundle = embeddedViewerController.viewerView.currentReferenceBundle {
            onEmbeddedReferenceBundleLoaded?(bundle)
        }
    }

    func currentSequenceAnnotationDraftContext() -> SequenceAnnotationDraftContext? {
        embeddedViewerController.localSequenceAnnotationDraftContext
    }

    func notifySequenceSelectionStateIfAvailable() {
        onSequenceSelectionStateChanged?(embeddedViewerController.currentSequenceRegionSelectionState())
    }

    func buildConsensusExportPayload() async throws -> (records: [String], suggestedName: String) {
        let request = try buildConsensusExportRequest()
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

    private func currentSelectedSequence() -> BundleBrowserSequenceSummary? {
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
        guard let row = sequenceTableView.displayedRows.firstIndex(where: { $0.name == name }) else { return false }
        selectSequence(at: row)
        return true
    }

    private func selectSequence(at row: Int) {
        guard row >= 0, row < sequenceTableView.displayedRows.count else { return }
        sequenceTableView.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        displaySelectedSequence(sequenceTableView.displayedRows[row])
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
        throw NSError(
            domain: "Lungfish",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Mapping export not yet implemented"]
        )
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

    var testDisplayedSequenceNames: [String] { sequenceTableView.displayedRows.map(\.name) }
    var testSelectedSequenceName: String? { currentSelectedSequence()?.name }
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

    func testSetEmbeddedReadDisplaySettings(minMapQ: Int, consensusMinMapQ: Int) {
        embeddedViewerController.viewerView.minMapQSetting = minMapQ
        embeddedViewerController.viewerView.consensusMinMapQSetting = consensusMinMapQ
    }
}
#endif
