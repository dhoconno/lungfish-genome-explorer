// AssemblyResultViewController.swift - Classifier-style assembly contig viewport
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import LungfishWorkflow

protocol AssemblyContigCatalogProviding: Sendable {
    func records() async throws -> [AssemblyContigRecord]
    func sequenceFASTA(for name: String, lineWidth: Int) async throws -> String
    func selectionSummary(for names: [String]) async throws -> AssemblyContigSelectionSummary
}

extension AssemblyContigCatalog: AssemblyContigCatalogProviding {}

@MainActor
public final class AssemblyResultViewController: NSViewController {
    private(set) var currentResult: AssemblyResult?
    public var onBlastVerification: ((BlastRequest) -> Void)?

    private let summaryStrip = AssemblySummaryStrip()
    private let splitView = TrackedDividerSplitView()
    private let tableContainer = NSView()
    private let detailContainer = NSView()
    private let contigTableView = AssemblyContigTableView()
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

    private lazy var contextMenu: NSMenu = buildContextMenu()

    public override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
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

        contigTableView.translatesAutoresizingMaskIntoConstraints = false
        contigTableView.tableContextMenu = contextMenu
        tableContainer.addSubview(contigTableView)

        detailPane.translatesAutoresizingMaskIntoConstraints = false
        detailContainer.addSubview(detailPane)

        NSLayoutConstraint.activate([
            contigTableView.topAnchor.constraint(equalTo: tableContainer.topAnchor),
            contigTableView.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor),
            contigTableView.trailingAnchor.constraint(equalTo: tableContainer.trailingAnchor),
            contigTableView.bottomAnchor.constraint(equalTo: tableContainer.bottomAnchor),

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
        splitView.isVertical = MetagenomicsPanelLayout.current() != .stacked

        let layout = MetagenomicsPanelLayout.current()
        if layout == .detailLeading {
            splitView.addArrangedSubview(detailContainer)
            splitView.addArrangedSubview(tableContainer)
        } else {
            splitView.addArrangedSubview(tableContainer)
            splitView.addArrangedSubview(detailContainer)
        }
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleLayoutSwapRequested),
            name: .metagenomicsLayoutSwapRequested,
            object: nil
        )
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

            actionBar.topAnchor.constraint(equalTo: splitView.bottomAnchor),
            actionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
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
        detailPane.configureQuickCopy(pasteboard: scalarPasteboard)
        contigTableView.scalarPasteboard = scalarPasteboard
    }

    @objc private func handleLayoutSwapRequested(_ notification: Notification) {
        applyLayoutPreference()
    }

    private func defaultLeadingFraction(for layout: MetagenomicsPanelLayout) -> CGFloat {
        switch layout {
        case .detailLeading:
            return 0.6
        case .listLeading, .stacked:
            return 0.4
        }
    }

    private func minimumExtents(for layout: MetagenomicsPanelLayout) -> (leading: CGFloat, trailing: CGFloat) {
        switch layout {
        case .detailLeading:
            return (260, 320)
        case .listLeading, .stacked:
            return (320, 260)
        }
    }

    private func applyLayoutPreference() {
        let layout = MetagenomicsPanelLayout.current()
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
        splitCoordinator.scheduleInitialSplitValidationIfNeeded(
            ownerView: view,
            splitView: splitView,
            minimumExtents: { [weak self] in
                self?.minimumExtents(for: MetagenomicsPanelLayout.current()) ?? (260, 320)
            },
            defaultLeadingFraction: { [weak self] in
                self?.defaultLeadingFraction(for: MetagenomicsPanelLayout.current()) ?? 0.4
            }
        )
    }

    private func buildContextMenu() -> NSMenu {
        let menu = NSMenu()
        let items: [(String, Selector)] = [
            ("BLAST Selected", #selector(blastSelected)),
            ("Copy FASTA", #selector(copySelectedFASTA)),
            ("Export FASTA…", #selector(exportSelectedFASTA)),
            ("Create Bundle…", #selector(createBundleFromSelection)),
        ]

        for (title, action) in items {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func blastSelected() { performBlastSelected() }
    @objc private func copySelectedFASTA() { performCopySelectedFASTA() }
    @objc private func exportSelectedFASTA() { performExportSelectedFASTA() }
    @objc private func createBundleFromSelection() { performCreateBundle() }

    private func performBlastSelected() {
        guard let result = currentResult, !selectedContigNames.isEmpty else { return }
        let selectedContigs = selectedContigNames
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
        guard let result = currentResult,
              !selectedContigNames.isEmpty,
              let window = view.window
        else { return }

        let selectedContigs = selectedContigNames
        let suggestedName = selectedContigs.count == 1
            ? "\(selectedContigs[0]).fa"
            : "\(result.outputDirectory.lastPathComponent)-selected-contigs.fa"

        Task {
            guard let destination = await savePanelPresenter.present(suggestedName: suggestedName, on: window) else {
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
        let selectedContigs = selectedContigNames
        let suggestedName = selectedContigs.count == 1
            ? selectedContigs[0]
            : "\(result.outputDirectory.lastPathComponent)-selected-contigs"
        Task {
            _ = try? await materializationAction.createBundle(
                result: result,
                selectedContigs: selectedContigs,
                suggestedName: suggestedName
            )
        }
    }

    private func load(result: AssemblyResult, generation: Int) async throws {
        let catalog = try await catalogLoader(result)
        let records = try await catalog.records()
        guard !Task.isCancelled, generation == loadGeneration else {
            return
        }

        currentResult = result
        self.catalog = catalog
        self.allRecords = records
        self.selectedContigNames = []

        summaryStrip.configure(result: result, pasteboard: scalarPasteboard)
        detailPane.configureQuickCopy(pasteboard: scalarPasteboard)
        contigTableView.scalarPasteboard = scalarPasteboard
        contigTableView.configure(rows: records)
        showEmptySelectionState()
        applyLayoutPreference()
    }

    private func showSelection(rows: [AssemblyContigRecord]) async {
        selectionGeneration += 1
        let generation = selectionGeneration
        let selectedNames = rows.map(\.name)
        selectedContigNames = selectedNames
        actionBar.setSelectionCount(rows.count)

        guard let result = currentResult, let catalog else {
            showEmptySelectionState(advanceSelectionGeneration: false)
            return
        }

        if rows.count == 1, let record = rows.first {
            let fasta = (try? await catalog.sequenceFASTA(for: record.name, lineWidth: 70)) ?? ""
            guard generation == selectionGeneration else { return }
            detailPane.showSingleSelection(record: record, fasta: fasta, result: result)
            return
        }

        if rows.count > 1 {
            if let summary = try? await catalog.selectionSummary(for: selectedNames) {
                guard generation == selectionGeneration else { return }
                detailPane.showMultiSelection(summary: summary)
            } else if generation == selectionGeneration {
                detailPane.showUnavailableSelectionSummary(selectedContigCount: rows.count)
            }
            return
        }

        showEmptySelectionState(advanceSelectionGeneration: false)
    }

    private func showEmptySelectionState(advanceSelectionGeneration: Bool = true) {
        if advanceSelectionGeneration {
            selectionGeneration += 1
        }
        selectedContigNames = []
        actionBar.setSelectionCount(0)
        detailPane.showEmptyState(contigCount: allRecords.count)
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
        splitCoordinator.splitViewDidResizeSubviews(
            splitView,
            minimumExtents: minimumExtents(for: MetagenomicsPanelLayout.current())
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
