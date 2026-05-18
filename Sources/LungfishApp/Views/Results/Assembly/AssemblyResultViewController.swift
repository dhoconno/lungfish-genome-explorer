// AssemblyResultViewController.swift - Classifier-style assembly contig viewport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishCore
import LungfishWorkflow

protocol AssemblyContigCatalogProviding: Sendable {
    func records() async throws -> [AssemblyContigRecord]
    func sequenceFASTA(for name: String, lineWidth: Int) async throws -> String
    func selectionSummary(for names: [String]) async throws -> AssemblyContigSelectionSummary
}

extension AssemblyContigCatalog: AssemblyContigCatalogProviding {}

@MainActor
public final class AssemblyResultViewController: NSViewController {
    private enum BlastSelectionLimit {
        static let maxContigs = 50
    }

    private enum EmptyStateCopy {
        static let noContigs = "Assembly completed, but no contigs were generated."
    }

    private(set) var currentResult: AssemblyResult?
    public var onBlastVerification: ((BlastRequest) -> Void)?
    public var onExtractSequenceRequested: (([String], String) -> Void)? {
        didSet { refreshContextMenu() }
    }
    public var onExportFASTARequested: (([String], String) -> Void)? {
        didSet { refreshContextMenu() }
    }
    public var onCreateBundleRequested: (([String], String) -> Void)? {
        didSet { refreshContextMenu() }
    }
    public var onRunOperationRequested: (([String]) -> Void)? {
        didSet {
            refreshContextMenu()
        }
    }
    var warningPresenter: ((String, String) -> Void)?

    private let summaryStrip = AssemblySummaryStrip()
    private let splitView = TrackedDividerSplitView()
    private let tableContainer = NSView()
    private let detailContainer = NSView()
    private let contigTableView = AssemblyContigTableView()
    private let emptyStateView = NSView()
    private let emptyStateLabel = NSTextField(wrappingLabelWithString: EmptyStateCopy.noContigs)
    private let detailPane = AssemblyContigDetailPane()
    private let actionBar = AssemblyActionBar()
    private let splitCoordinator = TwoPaneTrackedSplitCoordinator()
    private let materializationAction = AssemblyContigMaterializationAction()

    private var savePanelPresenter: SavePanelPresenting = DefaultSavePanelPresenter()
    private var scalarPasteboard: PasteboardWriting = DefaultPasteboard()

    var catalogLoader: @Sendable (AssemblyResult) async throws -> any AssemblyContigCatalogProviding = { result in
        try await AssemblyContigCatalog(result: result)
    }

    private var catalog: (any AssemblyContigCatalogProviding)?
    private var allRecords: [AssemblyContigRecord] = []
    private var selectedContigNames: [String] = []
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0
    private var selectionGeneration = 0

    private var contextMenu = NSMenu()
    private var splitViewBottomConstraint: NSLayoutConstraint?
    private var blastDrawerContainer: BlastResultsDrawerContainerView?
    private var blastDrawerHeightConstraint: NSLayoutConstraint?
    private var isBlastDrawerOpen = false

    public override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("Assembly result viewport")
        root.setAccessibilityIdentifier("assembly-result-view")
        view = root

        setupContainers()
        setupSplitView()
        setupActionBar()
        layoutSubviews()
        wireCallbacks()
        applyLayoutPreference()
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        guard splitCoordinator.needsInitialSplitValidation else { return }
        scheduleInitialSplitValidationIfNeeded()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func setupContainers() {
        [tableContainer, detailContainer, summaryStrip, actionBar, splitView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        refreshContextMenu()
        contigTableView.translatesAutoresizingMaskIntoConstraints = false
        contigTableView.tableContextMenu = contextMenu
        tableContainer.addSubview(contigTableView)

        emptyStateView.translatesAutoresizingMaskIntoConstraints = false
        emptyStateView.isHidden = true
        emptyStateView.setAccessibilityElement(true)
        emptyStateView.setAccessibilityRole(.group)
        emptyStateView.setAccessibilityLabel("Assembly empty state")
        emptyStateView.setAccessibilityIdentifier("assembly-result-empty-state")
        tableContainer.addSubview(emptyStateView)

        emptyStateLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyStateLabel.alignment = .center
        emptyStateLabel.lineBreakMode = .byWordWrapping
        emptyStateLabel.maximumNumberOfLines = 0
        emptyStateLabel.font = .systemFont(ofSize: 14, weight: .medium)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.setAccessibilityIdentifier("assembly-result-empty-state-message")
        emptyStateView.addSubview(emptyStateLabel)

        detailPane.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(detailPane)
        detailContainer.isHidden = true

        NSLayoutConstraint.activate([
            contigTableView.topAnchor.constraint(equalTo: tableContainer.topAnchor),
            contigTableView.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor),
            contigTableView.trailingAnchor.constraint(equalTo: tableContainer.trailingAnchor),
            contigTableView.bottomAnchor.constraint(equalTo: tableContainer.bottomAnchor),

            emptyStateView.topAnchor.constraint(equalTo: tableContainer.topAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: tableContainer.trailingAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: tableContainer.bottomAnchor),

            emptyStateLabel.centerXAnchor.constraint(equalTo: emptyStateView.centerXAnchor),
            emptyStateLabel.centerYAnchor.constraint(equalTo: emptyStateView.centerYAnchor),
            emptyStateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: emptyStateView.leadingAnchor, constant: 24),
            emptyStateLabel.trailingAnchor.constraint(lessThanOrEqualTo: emptyStateView.trailingAnchor, constant: -24),
            emptyStateLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),

            detailPane.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            detailPane.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            detailPane.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
            detailPane.bottomAnchor.constraint(equalTo: detailContainer.bottomAnchor),
        ])
    }

    private func setupSplitView() {
        splitView.dividerStyle = .thin
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.delegate = self
        splitView.isVertical = true
        splitView.addArrangedSubview(tableContainer)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
    }

    private func setupActionBar() {
        actionBar.onBlast = { [weak self] in self?.performBlastSelected() }
        actionBar.onCopy = { [weak self] in self?.performCopySelectedFASTA() }
        actionBar.onExport = { [weak self] in self?.performExportSelectedFASTA() }
        actionBar.onBundle = { [weak self] in self?.performCreateBundle() }
        actionBar.setSelectionCount(0)
    }

    private func layoutSubviews() {
        view.addSubview(summaryStrip)
        view.addSubview(splitView)
        view.addSubview(actionBar)

        NSLayoutConstraint.activate([
            summaryStrip.topAnchor.constraint(equalTo: view.topAnchor),
            summaryStrip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            summaryStrip.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            splitView.topAnchor.constraint(equalTo: summaryStrip.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let bottomConstraint = splitView.bottomAnchor.constraint(equalTo: actionBar.topAnchor)
        bottomConstraint.isActive = true
        splitViewBottomConstraint = bottomConstraint
    }

    private func wireCallbacks() {
        contigTableView.onSelectionCleared = { [weak self] in
            Task { self?.showEmptySelectionState() }
        }
        contigTableView.onRowSelected = { [weak self] row in
            Task { await self?.showSelection(rows: [row]) }
        }
        contigTableView.onMultipleRowsSelected = { [weak self] rows in
            Task { await self?.showSelection(rows: rows) }
        }
        contigTableView.scalarPasteboard = scalarPasteboard
    }

    private func defaultLeadingFraction(for layout: AssemblyPanelLayout) -> CGFloat {
        switch layout {
        case .detailLeading:
            return 0.6
        case .listLeading, .stacked:
            return 0.4
        }
    }

    private func minimumExtents(for layout: AssemblyPanelLayout) -> (leading: CGFloat, trailing: CGFloat) {
        switch layout {
        case .detailLeading:
            return (260, 320)
        case .listLeading, .stacked:
            return (320, 260)
        }
    }

    private func applyLayoutPreference() {
        guard splitView.arrangedSubviews.count > 1 else { return }
        let layout = AssemblyPanelLayout.current()
        let detailLeading = layout == .detailLeading
        splitCoordinator.applyLayoutPreference(
            to: splitView,
            desiredIsVertical: layout != .stacked,
            desiredFirstPane: detailLeading ? detailContainer : tableContainer,
            desiredSecondPane: detailLeading ? tableContainer : detailContainer,
            defaultLeadingFraction: defaultLeadingFraction(for: layout),
            minimumExtents: minimumExtents(for: layout),
            isViewInWindow: view.window != nil
        )
    }

    private func scheduleInitialSplitValidationIfNeeded() {
        guard splitView.arrangedSubviews.count > 1 else { return }
        splitCoordinator.scheduleInitialSplitValidationIfNeeded(
            ownerView: view,
            splitView: splitView,
            minimumExtents: { [weak self] in
                self?.minimumExtents(for: AssemblyPanelLayout.current()) ?? (260, 320)
            },
            defaultLeadingFraction: { [weak self] in
                self?.defaultLeadingFraction(for: AssemblyPanelLayout.current()) ?? 0.4
            }
        )
    }

    private func refreshContextMenu() {
        contextMenu = FASTASequenceActionMenuBuilder.buildMenu(
            selectionCount: selectedContigNames.count,
            handlers: FASTASequenceActionHandlers(
                onExtractSequence: { [weak self] in self?.performExtractSelectedSequence() },
                blastMenuTitle: "BLAST Contig…",
                onBlast: { [weak self] in self?.performBlastSelected() },
                onCopy: { [weak self] in self?.performCopySelectedFASTA() },
                onExport: { [weak self] in self?.performExportSelectedFASTA() },
                onCreateBundle: { [weak self] in self?.performCreateBundle() },
                onRunOperation: onRunOperationRequested == nil ? nil : { [weak self] in
                    self?.performRunOperation()
                }
            )
        )
        contigTableView.tableContextMenu = contextMenu
    }

    private func defaultSuggestedName(for selectedContigs: [String]) -> String {
        guard let result = currentResult else {
            return selectedContigs.first ?? "selected-contigs"
        }
        return selectedContigs.count == 1
            ? selectedContigs[0]
            : "\(result.outputDirectory.lastPathComponent)-selected-contigs"
    }

    private func selectedFASTARecords(lineWidth: Int = 70) async -> [String] {
        guard let catalog else { return [] }
        var fastaRecords: [String] = []
        fastaRecords.reserveCapacity(selectedContigNames.count)
        for contigName in selectedContigNames {
            if let fasta = try? await catalog.sequenceFASTA(for: contigName, lineWidth: lineWidth) {
                fastaRecords.append(fasta)
            }
        }
        return fastaRecords
    }

    private func performExtractSelectedSequence() {
        guard !selectedContigNames.isEmpty else { return }
        let suggestedName = defaultSuggestedName(for: selectedContigNames)
        Task { [weak self] in
            guard let self else { return }
            let fastaRecords = await selectedFASTARecords()
            guard !fastaRecords.isEmpty else { return }
            onExtractSequenceRequested?(fastaRecords, suggestedName)
        }
    }

    private func performBlastSelected() {
        guard let result = currentResult, !selectedContigNames.isEmpty else { return }
        let selectedContigs = selectedContigNames
        guard selectedContigs.count <= BlastSelectionLimit.maxContigs else {
            presentWarning(
                title: "Too Many Contigs for BLAST",
                message: "Select 50 contigs or fewer for a single BLAST submission."
            )
            return
        }
        Task {
            if let request = try? await materializationAction.buildBlastRequest(result: result, selectedContigs: selectedContigs) {
                onBlastVerification?(request)
            }
        }
    }

    private func performCopySelectedFASTA() {
        guard let result = currentResult, !selectedContigNames.isEmpty else { return }
        let selectedContigs = selectedContigNames
        Task {
            try? await materializationAction.copyFASTA(result: result, selectedContigs: selectedContigs)
        }
    }

    private func performExportSelectedFASTA() {
        guard let result = currentResult, !selectedContigNames.isEmpty else { return }
        let suggestedName = defaultSuggestedName(for: selectedContigNames)

        if let onExportFASTARequested {
            Task { [weak self] in
                guard let self else { return }
                let fastaRecords = await selectedFASTARecords()
                guard !fastaRecords.isEmpty else { return }
                onExportFASTARequested(fastaRecords, "\(suggestedName).fa")
            }
            return
        }

        guard let window = view.window else { return }

        let selectedContigs = selectedContigNames
        let exportName = selectedContigs.count == 1
            ? "\(selectedContigs[0]).fa"
            : "\(result.outputDirectory.lastPathComponent)-selected-contigs.fa"

        Task {
            guard let destination = await savePanelPresenter.present(suggestedName: exportName, on: window) else {
                return
            }
            try? await materializationAction.exportFASTA(
                result: result,
                selectedContigs: selectedContigs,
                outputURL: destination
            )
        }
    }

    private func performCreateBundle() {
        guard let result = currentResult, !selectedContigNames.isEmpty else { return }
        let suggestedName = defaultSuggestedName(for: selectedContigNames)

        if let onCreateBundleRequested {
            Task { [weak self] in
                guard let self else { return }
                let fastaRecords = await selectedFASTARecords()
                guard !fastaRecords.isEmpty else { return }
                onCreateBundleRequested(fastaRecords, suggestedName)
            }
            return
        }

        let selectedContigs = selectedContigNames
        Task {
            _ = try? await materializationAction.createBundle(
                result: result,
                selectedContigs: selectedContigs,
                suggestedName: suggestedName
            )
        }
    }

    private func performRunOperation() {
        guard !selectedContigNames.isEmpty, let catalog else { return }
        let selectedContigs = selectedContigNames
        Task {
            var fastaRecords: [String] = []
            for contigName in selectedContigs {
                if let fasta = try? await catalog.sequenceFASTA(for: contigName, lineWidth: 70) {
                    fastaRecords.append(fasta)
                }
            }
            guard !fastaRecords.isEmpty else { return }
            onRunOperationRequested?(fastaRecords)
        }
    }

    private func load(result: AssemblyResult, generation: Int) async throws {
        guard generation == loadGeneration else { return }
        currentResult = result
        summaryStrip.configure(result: result, pasteboard: scalarPasteboard)
        contigTableView.scalarPasteboard = scalarPasteboard

        if result.outcome == .completedWithNoContigs {
            catalog = nil
            allRecords = []
            selectedContigNames = []
            contigTableView.configure(rows: [])
            showEmptyContigState()
            applyLayoutPreference()
            return
        }

        let catalog = try await catalogLoader(result)
        let records = try await catalog.records()
        guard !Task.isCancelled, generation == loadGeneration else {
            return
        }

        self.catalog = catalog
        self.allRecords = records
        self.selectedContigNames = []
        refreshContextMenu()
        contigTableView.configure(rows: records)
        contigTableView.isHidden = false
        emptyStateView.isHidden = true
        actionBar.setSelectionCount(0)
        showEmptySelectionState()
        applyLayoutPreference()
    }

    private func showSelection(rows: [AssemblyContigRecord]) async {
        selectionGeneration += 1
        selectedContigNames = rows.map(\.name)
        actionBar.setSelectionCount(rows.count)
        refreshContextMenu()
    }

    private func showEmptySelectionState(advanceSelectionGeneration: Bool = true) {
        if advanceSelectionGeneration {
            selectionGeneration += 1
        }
        selectedContigNames = []
        actionBar.setSelectionCount(0)
        refreshContextMenu()
    }

    private func showEmptyContigState() {
        contigTableView.isHidden = true
        emptyStateView.isHidden = false
        detailContainer.isHidden = true
        selectedContigNames = []
        actionBar.setSelectionCount(0)
        refreshContextMenu()
    }

    public func showBlastLoading(phase: BlastJobPhase, requestId: String?) {
        let drawer = ensureBlastDrawer()
        drawer.showLoading(phase: phase, requestId: requestId)
        openBlastDrawerIfNeeded()
    }

    public func showBlastResults(_ result: BlastVerificationResult) {
        let drawer = ensureBlastDrawer()
        drawer.showResults(result)
        openBlastDrawerIfNeeded()
    }

    public func showBlastFailure(_ message: String) {
        let drawer = ensureBlastDrawer()
        drawer.showFailure(message: message)
        openBlastDrawerIfNeeded()
    }

    private func ensureBlastDrawer() -> BlastResultsDrawerTab {
        if let blastDrawerContainer {
            blastDrawerContainer.blastResultsTab.presentationStyle = .contigBlast
            return blastDrawerContainer.blastResultsTab
        }

        let container = BlastResultsDrawerContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        let heightConstraint = container.heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: actionBar.topAnchor),
            heightConstraint,
        ])

        splitViewBottomConstraint?.isActive = false
        let newSplitBottom = splitView.bottomAnchor.constraint(equalTo: container.topAnchor)
        newSplitBottom.isActive = true
        splitViewBottomConstraint = newSplitBottom

        blastDrawerContainer = container
        blastDrawerHeightConstraint = heightConstraint
        container.onDrag = { [weak self] delta in
            guard let self, let heightConstraint = self.blastDrawerHeightConstraint else { return }
            let availableExtent = max(0, self.view.bounds.height - self.actionBar.frame.height)
            let proposed = heightConstraint.constant + delta
            heightConstraint.constant = MetagenomicsPaneSizing.clampedDrawerExtent(
                proposed: proposed,
                containerExtent: availableExtent,
                minimumDrawerExtent: 160,
                minimumSiblingExtent: 120
            )
            self.view.layoutSubtreeIfNeeded()
        }
        container.onDragEnd = { [weak self] in
            self?.view.layoutSubtreeIfNeeded()
        }
        view.layoutSubtreeIfNeeded()
        container.blastResultsTab.presentationStyle = .contigBlast
        return container.blastResultsTab
    }

    private func openBlastDrawerIfNeeded() {
        guard !isBlastDrawerOpen else { return }
        guard let blastDrawerHeightConstraint else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            blastDrawerHeightConstraint.animator().constant = 220
            view.layoutSubtreeIfNeeded()
        }
        isBlastDrawerOpen = true
    }

    private func presentWarning(title: String, message: String) {
        if let warningPresenter {
            warningPresenter(title, message)
            return
        }

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.applyLungfishBranding()

        if let window = view.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.presentError(AssemblyResultWarning(title: title, message: message))
        }
    }

    private struct AssemblyResultWarning: LocalizedError {
        let title: String
        let message: String

        var errorDescription: String? { title }
        var recoverySuggestion: String? { message }
    }
}

extension AssemblyResultViewController: ResultViewportController {
    public typealias ResultType = AssemblyResult

    public static var resultTypeName: String { "Assembly Results" }

    public func configure(result: AssemblyResult) {
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        loadTask = Task { [weak self] in
            try? await self?.load(result: result, generation: generation)
        }
    }

    public var summaryBarView: NSView { summaryStrip }

    public func exportResults(to url: URL, format: ResultExportFormat) throws {
        throw NSError(
            domain: "Lungfish",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Assembly export is handled from the viewport action bar."]
        )
    }
}

extension AssemblyResultViewController: BlastVerifiable {}

extension AssemblyResultViewController: NSSplitViewDelegate {
    public func splitViewDidResizeSubviews(_ notification: Notification) {
        guard splitView.arrangedSubviews.count > 1 else { return }
        splitCoordinator.splitViewDidResizeSubviews(
            splitView,
            minimumExtents: minimumExtents(for: AssemblyPanelLayout.current())
        )
    }
}

#if DEBUG
extension AssemblyResultViewController {
    func configureForTesting(
        result: AssemblyResult,
        scalarPasteboard: PasteboardWriting = DefaultPasteboard()
    ) async throws {
        self.scalarPasteboard = scalarPasteboard
        loadGeneration += 1
        let generation = loadGeneration
        try await load(result: result, generation: generation)
    }

    var testSplitView: TrackedDividerSplitView { splitView }
    var testTableContainer: NSView { tableContainer }
    var testDetailContainer: NSView { detailContainer }
    var testSummaryStrip: AssemblySummaryStrip { summaryStrip }
    var testContigTableView: AssemblyContigTableView { contigTableView }
    var testDetailPane: AssemblyContigDetailPane { detailPane }
    var testActionBar: AssemblyActionBar { actionBar }
    var testContextMenuTitles: [String] { contextMenu.items.map(\.title) }
    var testEmptyStateView: NSView { emptyStateView }
    var testEmptyStateMessage: String { emptyStateLabel.stringValue }

    func testSelectContig(named name: String) async throws {
        if let record = contigTableView.displayedRows.first(where: { $0.name == name }) {
            await showSelection(rows: [record])
        }
    }

    func testSelectContigs(named names: [String]) async throws {
        let wanted = Set(names)
        let rows = contigTableView.displayedRows.filter { wanted.contains($0.name) }
        await showSelection(rows: rows)
    }

    func testCopySummaryValue(identifier: String) {
        summaryStrip.copyValue(for: identifier)
    }

    func testCopyVisibleDetailValue(identifier: String) {
        detailPane.copyValue(identifier: identifier)
    }

    func testCopyVisibleTableValue(row: Int, columnID: String) {
        contigTableView.copyValue(row: row, columnID: columnID, pasteboard: scalarPasteboard)
    }

    func testTriggerBlast() {
        performBlastSelected()
    }
}
#endif
