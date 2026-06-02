import AppKit
import LungfishIO
import SwiftUI
import UniformTypeIdentifiers
import LungfishKit

@MainActor
public final class TwelveSAmpliconResultViewController: NSViewController {
    enum Mode: Int {
        case targets
        case unresolved
    }

    private let titleLabel = NSTextField(labelWithString: "12S Amplicon Matches")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let modeControl = NSSegmentedControl(
        labels: ["Targets", "Unresolved"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let searchField = NSSearchField()
    private let sampleFilterButton = NSButton(title: "All Samples", target: nil, action: nil)
    private let tableContainer = NSView()
    private let targetTable = TwelveSTargetTableView()
    private let unresolvedTable = TwelveSUnresolvedTableView()
    private let actionBar = ClassifierActionBar()

    private var splitViewBottomConstraint: NSLayoutConstraint?
    private var blastDrawerContainer: BlastResultsDrawerContainerView?
    private var blastDrawerHeightConstraint: NSLayoutConstraint?
    private var isBlastDrawerOpen = false

    private var result: TwelveSAmpliconResultBundleData?
    private var mode: Mode = .targets
    private var displayState = TwelveSResultDisplayState()
    private var allTargetRows: [TwelveSScientificNameCountRow] = []
    private var targetRows: [TwelveSScientificNameCountRow] = []
    private var allUnresolvedRows: [TwelveSUnresolvedSequence] = []
    private var unresolvedRows: [TwelveSUnresolvedSequence] = []
    /// Pasteboard seam for the copy context menu (overridable in tests).
    private var pasteboard: PasteboardWriting = DefaultPasteboard()
    private let copyContextMenu = NSMenu()

    // MARK: - Multi-sample comparison

    /// Shared picker state observed for sample-selection changes. `nil` until
    /// the host wires samples via ``configureSamples(_:state:)``.
    private var samplePickerState: ClassifierSamplePickerState?
    private var sampleEntries: [TwelveSSampleEntry] = []
    private var allSampleIDs: Set<String> = []
    private var selectedSamples: Set<String> = []
    private var samplePopover: NSPopover?
    private var sampleNameStrippedPrefix = ""

    /// Imported per-sample metadata (CSV/TSV), shown as matrix columns.
    private var metadataStore: SampleMetadataStore?
    /// Which imported metadata fields are currently shown as columns.
    private var visibleMetadataFields: [String] = []
    /// User override for showing per-sample reads columns. `nil` = follow the
    /// ≤8-selected-samples auto rule.
    private var showReadsColumnsOverride: Bool?
    /// Threshold above which per-sample reads columns are auto-suppressed.
    private let autoReadsColumnSampleLimit = 8
    private let sampleColumnsButton = NSButton(title: "Sample Columns", target: nil, action: nil)

    public var onDisplaySummaryChanged: ((TwelveSResultDisplaySummary) -> Void)?
    public var onDisplayStateChanged: ((TwelveSResultDisplayState) -> Void)?
    public var onUnresolvedBlastRequested: ((TwelveSUnresolvedBlastRequest) -> Void)?
    public var onUnresolvedBlastCancelRequested: (() -> Void)?

    /// Emitted when the active-table selection changes. A single-row selection
    /// produces a populated payload; a multi/empty selection produces `nil`.
    /// The App wires this to the Inspector's 12S Detail tab.
    public var onSelectedRowDetailChanged: ((TwelveSDetailPayload?) -> Void)?

    /// Fired when the user chooses "Import Metadata…". The App presents the
    /// shared CSV/TSV import panel and calls ``applyMetadataStore(_:)``.
    public var onMetadataImportRequested: (() -> Void)?

    /// The most recent detail payload, retained so the legacy `testing*`
    /// accessors keep reporting the selected row's evidence after the split
    /// detail pane was removed.
    private var lastDetailPayload: TwelveSDetailPayload?

    /// Resolves per-target reference sequences from the bundle's reference
    /// FASTA, populated lazily into the detail payload after selection.
    private var referenceProvider: TwelveSReferenceSequenceProvider?

    /// The currently visible table, switched by ``mode``.
    private var activeTableView: NSTableView {
        mode == .targets ? targetTable.tableView : unresolvedTable.tableView
    }

    var visibleTargetRowCount: Int {
        targetTable.displayedRows.count
    }

    var visibleUnresolvedRowCount: Int {
        unresolvedTable.displayedRows.count
    }

    var tableColumnIdentifiers: [String] {
        let table = mode == .targets ? targetTable : unresolvedTable as NSView
        guard let tableView = (table as? TwelveSTargetTableView)?.tableView
            ?? (table as? TwelveSUnresolvedTableView)?.tableView else { return [] }
        return tableView.tableColumns
            .filter { !MetadataColumnController.isMetadataColumn($0.identifier) }
            .map { $0.identifier.rawValue }
    }

    var summaryTextForTesting: String {
        summaryLabel.stringValue
    }

    var testingDetailSampleRows: [TwelveSDetailSampleEvidenceRow] {
        switch lastDetailPayload?.kind {
        case let .target(detail): return detail.sampleEvidence
        case let .unresolved(detail): return detail.sampleEvidence
        case nil: return []
        }
    }

    var testingAlternateMatchTexts: [String] {
        if case let .target(detail) = lastDetailPayload?.kind {
            return detail.alternateTexts
        }
        return []
    }

    var testingExportMenuTitles: [String] {
        buildExportMenu().items.filter { !$0.isSeparatorItem }.map(\.title)
    }

    var testingHasProvenanceAction: Bool {
        actionBar.onProvenance != nil
    }

    /// Test-only view of the active mode.
    var testingActiveMode: Mode { mode }

    /// Test-only count of rows displayed in the active table.
    var testingActiveTableRowCount: Int {
        mode == .targets ? targetTable.displayedRows.count : unresolvedTable.displayedRows.count
    }

    /// Test-only visibility of the sample filter button.
    var testingSampleFilterButtonHidden: Bool { sampleFilterButton.isHidden }

    /// Test-only: the active target-table primary sort descriptor.
    var testingTargetSortDescriptor: NSSortDescriptor? { targetTable.tableView.sortDescriptors.first }

    /// Test-only: set the target-table sort.
    func testingSetTargetSort(key: String, ascending: Bool) {
        targetTable.tableView.sortDescriptors = [NSSortDescriptor(key: key, ascending: ascending)]
    }

    /// Test-only: all column identifiers on the target table (incl. matrix).
    var testingTargetColumnIDs: [String] {
        targetTable.tableView.tableColumns.map { $0.identifier.rawValue }
    }

    /// Test-only: force reads-column visibility and rebuild.
    func testingSetSampleColumnsForced(showReads: Bool) {
        showReadsColumnsOverride = showReads
        rebuildSampleColumns()
    }

    /// Test-only: fire the metadata-import callback.
    func testingTriggerMetadataImport() {
        onMetadataImportRequested?()
    }

    public override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("12S amplicon result viewport")
        root.setAccessibilityIdentifier("twelve-s-amplicon-result-view")
        view = root

        configureHeader()
        configureTables()
        configureActionBar()
        layout()
    }

    public func configure(result: TwelveSAmpliconResultBundleData) {
        self.result = result
        allTargetRows = result.scientificNameRows
        allUnresolvedRows = result.unresolvedSequences.sorted { lhs, rhs in
            if lhs.readCount != rhs.readCount { return lhs.readCount > rhs.readCount }
            return lhs.sequenceID < rhs.sequenceID
        }
        targetTable.resultIdentity = result.manifest.outputName
        unresolvedTable.resultIdentity = result.manifest.outputName
        referenceProvider = TwelveSReferenceSequenceProvider(referenceURL: result.artifacts.referenceURL)
        titleLabel.stringValue = "\(result.manifest.outputName) 12S Matches"
        summaryLabel.stringValue = Self.summaryText(for: result)
        applyFilters(notify: false)
        applyDefaultSort()
        showTargets()
    }

    public func applyDisplayState(_ state: TwelveSResultDisplayState) {
        displayState = state
        searchField.stringValue = state.filterText
        applyFilters(notify: true)
    }

    /// Wires the multi-sample picker. Pass the sample entries (built from the
    /// bundle's samples) and a shared ``ClassifierSamplePickerState``; the
    /// viewport observes the state and re-aggregates rows over the selection.
    public func configureSamples(_ entries: [TwelveSSampleEntry], state: ClassifierSamplePickerState) {
        sampleEntries = entries
        allSampleIDs = Set(entries.map(\.id))
        samplePickerState = state
        selectedSamples = state.selectedSamples
        sampleNameStrippedPrefix = ClassifierSamplePickerView.commonPrefix(of: entries.map(\.displayName))
        sampleFilterButton.isHidden = entries.count <= 1
        sampleColumnsButton.isHidden = entries.count <= 1
        updateSampleFilterButtonTitle()
        startObservingSampleSelection()
        applyFilters(notify: false)
        rebuildSampleColumns()
    }

    /// Applies imported per-sample metadata as matrix columns. New fields are
    /// shown by default; pass `nil` to clear.
    public func applyMetadataStore(_ store: SampleMetadataStore?) {
        metadataStore = store
        visibleMetadataFields = store?.columnNames ?? []
        rebuildSampleColumns()
    }

    /// The currently-selected sample IDs in display (picker/sample-table) order.
    private var orderedSelectedSampleIDs: [String] {
        sampleEntries.map(\.id).filter { selectedSamples.contains($0) }
    }

    /// Whether per-sample reads columns should be shown: the user override if
    /// set, else the ≤8-selected-samples auto rule.
    private var shouldShowReadsColumns: Bool {
        showReadsColumnsOverride ?? (orderedSelectedSampleIDs.count <= autoReadsColumnSampleLimit)
    }

    /// Rebuilds the per-sample matrix columns on the target table and updates
    /// the suppressed-columns note.
    private func rebuildSampleColumns() {
        let ids = orderedSelectedSampleIDs
        let names = Dictionary(uniqueKeysWithValues: sampleEntries.map { ($0.id, $0.displayName) })
        targetTable.setSampleColumns(
            sampleIDs: ids,
            displayNames: names,
            showReads: shouldShowReadsColumns,
            store: metadataStore,
            metadataFields: visibleMetadataFields
        )
        updateActionBar()
    }

    private func updateSampleFilterButtonTitle() {
        let total = allSampleIDs.count
        let selected = selectedSamples.count
        sampleFilterButton.title = (selected == total || total == 0)
            ? "All Samples"
            : "\(selected) of \(total) Samples"
    }

    /// Reactively observes `samplePickerState.selectedSamples` using
    /// `withObservationTracking`, re-registering after each change. The
    /// main-actor hop follows the project's binding runtime pattern rather than
    /// `Task { @MainActor }` from a background callback.
    private func startObservingSampleSelection() {
        guard let pickerState = samplePickerState else { return }
        withObservationTracking {
            _ = pickerState.selectedSamples
        } onChange: { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                MainActor.assumeIsolated {
                    let newSelection = self.samplePickerState?.selectedSamples ?? []
                    guard newSelection != self.selectedSamples else {
                        self.startObservingSampleSelection()
                        return
                    }
                    self.selectedSamples = newSelection
                    self.updateSampleFilterButtonTitle()
                    self.applyFilters(notify: false)
                    self.rebuildSampleColumns()
                    self.startObservingSampleSelection()
                }
            }
        }
    }

    @objc private func sampleFilterButtonClicked(_ sender: NSButton) {
        if let existing = samplePopover, existing.isShown {
            existing.close()
            samplePopover = nil
            return
        }
        guard let samplePickerState else { return }
        samplePickerState.selectedSamples = selectedSamples

        let pickerView = ClassifierSamplePickerView(
            samples: sampleEntries,
            pickerState: samplePickerState,
            strippedPrefix: sampleNameStrippedPrefix,
            isInline: false
        )
        let popover = NSPopover()
        popover.contentViewController = NSHostingController(rootView: pickerView)
        popover.behavior = .transient
        popover.delegate = self
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        samplePopover = popover
    }

    @objc private func sampleColumnsButtonClicked(_ sender: NSButton) {
        let menu = NSMenu()

        let readsItem = NSMenuItem(title: "Show Per-Sample Reads", action: #selector(toggleReadsColumns(_:)), keyEquivalent: "")
        readsItem.target = self
        readsItem.state = shouldShowReadsColumns ? .on : .off
        menu.addItem(readsItem)

        if let store = metadataStore, !store.columnNames.isEmpty {
            menu.addItem(NSMenuItem.separator())
            let header = NSMenuItem(title: "Metadata Columns", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for field in store.columnNames {
                let item = NSMenuItem(title: field, action: #selector(toggleMetadataField(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = field
                item.state = visibleMetadataFields.contains(field) ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        let importItem = NSMenuItem(title: "Import Metadata\u{2026}", action: #selector(importMetadataMenuItem(_:)), keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)

        let point = NSPoint(x: sender.bounds.minX, y: sender.bounds.maxY)
        menu.popUp(positioning: nil, at: point, in: sender)
    }

    @objc private func toggleReadsColumns(_ sender: NSMenuItem) {
        showReadsColumnsOverride = !(shouldShowReadsColumns)
        rebuildSampleColumns()
    }

    @objc private func toggleMetadataField(_ sender: NSMenuItem) {
        guard let field = sender.representedObject as? String else { return }
        if let idx = visibleMetadataFields.firstIndex(of: field) {
            visibleMetadataFields.remove(at: idx)
        } else {
            visibleMetadataFields.append(field)
        }
        rebuildSampleColumns()
    }

    @objc private func importMetadataMenuItem(_ sender: NSMenuItem) {
        onMetadataImportRequested?()
    }

    /// Whether the current selection is a strict subset of all samples
    /// (multi-sample comparison restricting the visible rows).
    private var isSampleSubset: Bool {
        !allSampleIDs.isEmpty && selectedSamples.count < allSampleIDs.count
    }

    /// Test seam: drive the sample selection without the popover.
    func testingSetSelectedSamples(_ ids: Set<String>) {
        if let samplePickerState {
            samplePickerState.selectedSamples = ids
        }
        selectedSamples = ids
        updateSampleFilterButtonTitle()
        applyFilters(notify: false)
    }

    func setSearchTextForTesting(_ text: String) {
        searchField.stringValue = text
        applyFilterText(text)
    }

    func showUnresolvedForTesting() {
        modeControl.selectedSegment = Mode.unresolved.rawValue
        applyMode(.unresolved)
    }

    func selectTargetForTesting(row: Int) {
        showTargets()
        guard targetRows.indices.contains(row) else { return }
        targetTable.tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        targetTable.tableViewSelectionDidChange(
            Notification(name: NSTableView.selectionDidChangeNotification, object: targetTable.tableView)
        )
    }

    func triggerUnresolvedBlastForTesting() {
        performUnresolvedBlast()
    }

    func testingTargetText(row: Int, column: String) -> String {
        guard targetRows.indices.contains(row) else { return "" }
        return targetTable.cellContent(for: NSUserInterfaceItemIdentifier(column), row: targetTable.displayedRows[row]).text
    }

    func exportSnapshot() -> TwelveSAmpliconResultExportSnapshot? {
        guard let result else { return nil }
        return TwelveSAmpliconResultExportSnapshot(
            bundleURL: result.bundleURL,
            analysisName: result.manifest.analysisName,
            sampleNames: result.sampleNames,
            filters: displayState,
            rows: targetRows,
            unresolvedRows: unresolvedRows
        )
    }

    public func presentExport(format: TwelveSAmpliconResultExportFormat) {
        guard let snapshot = exportSnapshot() else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(snapshot.analysisName)-12s.\(format.fileExtension)"
        panel.allowedContentTypes = [format.contentType]
        panel.title = "Export 12S Results"

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            // `snapshot` and `format` are Sendable value inputs and `url` is a Sendable
            // URL, so the export (which shells out to the CLI and blocks on
            // process.waitUntilExit) runs off the main thread. The completion closure
            // returns immediately; only error reporting hops back to the main actor.
            let outputURL = url
            Task { [weak self] in
                do {
                    _ = try await Task.detached {
                        try TwelveSAmpliconResultExportService().export(
                            snapshot: snapshot,
                            format: format,
                            to: outputURL
                        )
                    }.value
                } catch {
                    await MainActor.run {
                        self?.presentExportError(error)
                    }
                }
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
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

    private func configureHeader() {
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        summaryLabel.font = .systemFont(ofSize: 12, weight: .regular)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setAccessibilityIdentifier("twelve-s-summary")

        modeControl.selectedSegment = Mode.targets.rawValue
        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.setAccessibilityIdentifier("twelve-s-mode-control")

        searchField.placeholderString = "Filter species or matches"
        searchField.controlSize = .small
        searchField.font = .systemFont(ofSize: 11)
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.setAccessibilityIdentifier("twelve-s-search-field")
        searchField.setAccessibilityLabel("12S Filter Species Or Matches")

        sampleFilterButton.bezelStyle = .push
        sampleFilterButton.controlSize = .small
        sampleFilterButton.font = .systemFont(ofSize: 11)
        sampleFilterButton.target = self
        sampleFilterButton.action = #selector(sampleFilterButtonClicked(_:))
        sampleFilterButton.setAccessibilityIdentifier("twelve-s-sample-filter-button")
        sampleFilterButton.setAccessibilityLabel("12S Sample Filter")
        sampleFilterButton.isHidden = true // shown once samples are wired

        sampleColumnsButton.bezelStyle = .push
        sampleColumnsButton.controlSize = .small
        sampleColumnsButton.font = .systemFont(ofSize: 11)
        sampleColumnsButton.target = self
        sampleColumnsButton.action = #selector(sampleColumnsButtonClicked(_:))
        sampleColumnsButton.setAccessibilityIdentifier("twelve-s-sample-columns-button")
        sampleColumnsButton.setAccessibilityLabel("12S Sample Columns")
        sampleColumnsButton.isHidden = true // shown once samples are wired
    }

    private func configureTables() {
        for table in [targetTable, unresolvedTable] as [NSView] {
            table.translatesAutoresizingMaskIntoConstraints = false
            tableContainer.addSubview(table)
            NSLayoutConstraint.activate([
                table.topAnchor.constraint(equalTo: tableContainer.topAnchor),
                table.leadingAnchor.constraint(equalTo: tableContainer.leadingAnchor),
                table.trailingAnchor.constraint(equalTo: tableContainer.trailingAnchor),
                table.bottomAnchor.constraint(equalTo: tableContainer.bottomAnchor),
            ])
        }
        unresolvedTable.isHidden = true

        targetTable.onRowSelected = { [weak self] row in
            self?.handleTargetSelection([row])
        }
        targetTable.onMultipleRowsSelected = { [weak self] rows in
            self?.handleTargetSelection(rows)
        }
        targetTable.onSelectionCleared = { [weak self] in
            self?.handleTargetSelection([])
        }
        unresolvedTable.onRowSelected = { [weak self] row in
            self?.handleUnresolvedSelection([row])
        }
        unresolvedTable.onMultipleRowsSelected = { [weak self] rows in
            self?.handleUnresolvedSelection(rows)
        }
        unresolvedTable.onSelectionCleared = { [weak self] in
            self?.handleUnresolvedSelection([])
        }

        copyContextMenu.delegate = self
        targetTable.tableContextMenu = copyContextMenu
        unresolvedTable.tableContextMenu = copyContextMenu
    }

    /// Repopulates the copy context menu for the active table's current
    /// selection. If the user right-clicked a row outside the current
    /// selection, that row is selected first (matching NVD's behavior).
    private func populateCopyContextMenu() {
        switch mode {
        case .targets:
            let clicked = targetTable.tableView.clickedRow
            if clicked >= 0, !targetTable.tableView.selectedRowIndexes.contains(clicked) {
                targetTable.selectDisplayedRowForContextMenuIfNeeded(clicked)
            }
            let rows = resolvedTargetSelection()
            TwelveSCopyMenuProvider.populateTargetMenu(copyContextMenu, rows: rows, pasteboard: pasteboard)
        case .unresolved:
            let clicked = unresolvedTable.tableView.clickedRow
            if clicked >= 0, !unresolvedTable.tableView.selectedRowIndexes.contains(clicked) {
                unresolvedTable.selectDisplayedRowForContextMenuIfNeeded(clicked)
            }
            let rows = resolvedUnresolvedSelection()
            TwelveSCopyMenuProvider.populateUnresolvedMenu(copyContextMenu, rows: rows, pasteboard: pasteboard)
        }
    }

    private func resolvedTargetSelection() -> [TwelveSScientificNameCountRow] {
        let selected = targetTable.selectedRowsByIdentity()
        return selected.isEmpty ? Array(targetTable.displayedRows.prefix(1)) : selected
    }

    private func resolvedUnresolvedSelection() -> [TwelveSUnresolvedSequence] {
        let selected = unresolvedTable.selectedRowsByIdentity()
        return selected.isEmpty ? Array(unresolvedTable.displayedRows.prefix(1)) : selected
    }

    /// Test seam: override the pasteboard used by the copy menu.
    func testingSetPasteboard(_ pasteboard: PasteboardWriting) {
        self.pasteboard = pasteboard
    }

    /// Test seam: select a row and exercise the "Copy Name" path directly.
    func testingCopyNameForSelectedRow(_ row: Int) {
        switch mode {
        case .targets:
            guard targetTable.displayedRows.indices.contains(row) else { return }
            pasteboard.setString(TwelveSCopyFormatting.names([targetTable.displayedRows[row]]))
        case .unresolved:
            guard unresolvedTable.displayedRows.indices.contains(row) else { return }
            pasteboard.setString(TwelveSCopyFormatting.unresolvedNames([unresolvedTable.displayedRows[row]]))
        }
    }

    private func configureActionBar() {
        actionBar.extractButton.isHidden = true
        actionBar.updateInfoText("Select unresolved clusters to BLAST")
        actionBar.setBlastEnabled(false, reason: "Switch to Unresolved to BLAST unmatched sequences")
        actionBar.onBlastVerify = { [weak self] in
            self?.performUnresolvedBlast()
        }
        actionBar.onExport = { [weak self] in
            self?.showExportMenu()
        }
        actionBar.onProvenance = { [weak self] sender in
            self?.showProvenancePopover(relativeTo: sender)
        }
    }

    private func layout() {
        let headerRow = NSStackView(views: [titleLabel, modeControl, sampleFilterButton, sampleColumnsButton, searchField])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        tableContainer.translatesAutoresizingMaskIntoConstraints = false

        [headerRow, summaryLabel, tableContainer, actionBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        // The detail pane moved to the Inspector, so the table host spans the
        // full width. `splitViewBottomConstraint` now anchors the table
        // container's bottom; the BLAST drawer re-points it when it opens.
        let tableBottom = tableContainer.bottomAnchor.constraint(equalTo: actionBar.topAnchor)
        splitViewBottomConstraint = tableBottom
        NSLayoutConstraint.activate([
            headerRow.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            headerRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            headerRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            modeControl.widthAnchor.constraint(equalToConstant: 190),
            searchField.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),

            summaryLabel.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 6),
            summaryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            summaryLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            tableContainer.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 10),
            tableContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            tableContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            tableBottom,
            tableContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),

            actionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            actionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            actionBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func showTargets() {
        modeControl.selectedSegment = Mode.targets.rawValue
        applyMode(.targets)
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        applyMode(Mode(rawValue: sender.selectedSegment) ?? .targets)
    }

    @objc private func searchFieldChanged(_ sender: NSSearchField) {
        applyFilterText(sender.stringValue)
    }

    private func applyFilterText(_ text: String) {
        guard displayState.filterText != text else { return }
        displayState.filterText = text
        applyFilters(notify: true)
    }

    private func applyMode(_ mode: Mode) {
        self.mode = mode
        targetTable.isHidden = mode != .targets
        unresolvedTable.isHidden = mode != .unresolved
        emitDetail(nil)
        updateActionBar()
        notifyDisplaySummaryChanged()
    }

    private func applyFilters(notify: Bool) {
        targetRows = allTargetRows.filter(targetMatchesDisplayState)
        unresolvedRows = allUnresolvedRows.filter(unresolvedMatchesDisplayState)
        // When comparing a strict subset of samples, drop rows that have no
        // reads in the selected samples (NAO-MGS / NVD idiom). A single-sample
        // bundle or "All Samples" leaves the row set unchanged.
        if isSampleSubset {
            targetRows = targetRows.filter { TwelveSRowAggregator.includesTarget($0, selected: selectedSamples) }
            unresolvedRows = unresolvedRows.filter { TwelveSRowAggregator.includesUnresolved($0, selected: selectedSamples) }
        }
        // Hide species rows with zero reads across the currently-shown samples
        // (unconditional). Shown = the selected subset if active, else all.
        let shownSamples = isSampleSubset ? selectedSamples : allSampleIDs
        targetRows = targetRows.filter { row in
            shownSamples.isEmpty
                ? row.totalExactReads > 0
                : TwelveSRowAggregator.totalExactReads(row, selected: shownSamples) > 0
        }
        // Display-state filters narrow the row set; the kernel free-text filter
        // (driven by the header search field) narrows within. Apply the current
        // search text to both tables so the two filter layers compose.
        targetTable.configure(rows: targetRows)
        unresolvedTable.configure(rows: unresolvedRows)
        applyDefaultSortIfNeeded()
        targetTable.setFilterText(displayState.filterText)
        unresolvedTable.setFilterText(displayState.filterText)
        updateActionBar()
        notifyDisplaySummaryChanged()
        if notify {
            onDisplayStateChanged?(displayState)
        }
    }

    /// Preserves an existing sort across filter changes, applying the default
    /// order only when no sort is set yet (so a user's chosen sort survives
    /// filtering/sample changes).
    private func applyDefaultSortIfNeeded() {
        if targetTable.tableView.sortDescriptors.isEmpty {
            targetTable.tableView.sortDescriptors = [NSSortDescriptor(key: "totalExactReads", ascending: false)]
        }
        if unresolvedTable.tableView.sortDescriptors.isEmpty {
            unresolvedTable.tableView.sortDescriptors = [NSSortDescriptor(key: "readCount", ascending: false)]
        }
    }

    /// Unconditionally resets both tables to the default order (reads
    /// descending). Called when a new result is configured so every bundle
    /// starts sorted by abundance, regardless of any prior sort state.
    private func applyDefaultSort() {
        targetTable.tableView.sortDescriptors = [NSSortDescriptor(key: "totalExactReads", ascending: false)]
        unresolvedTable.tableView.sortDescriptors = [NSSortDescriptor(key: "readCount", ascending: false)]
    }

    private func notifyDisplaySummaryChanged() {
        switch mode {
        case .targets:
            onDisplaySummaryChanged?(
                TwelveSResultDisplaySummary(
                    rowLabel: "Species Rows",
                    visibleRows: targetRows.count,
                    totalRows: allTargetRows.count
                )
            )
        case .unresolved:
            onDisplaySummaryChanged?(
                TwelveSResultDisplaySummary(
                    rowLabel: "Unmatched Sequences",
                    visibleRows: unresolvedRows.count,
                    totalRows: allUnresolvedRows.count
                )
            )
        }
    }

    private func targetMatchesDisplayState(_ row: TwelveSScientificNameCountRow) -> Bool {
        guard row.totalExactReads >= displayState.minimumExactReads else { return false }
        if displayState.excludeHuman, isHuman(row) { return false }
        if displayState.requireAlternateMatches, alternateTexts(for: row).isEmpty { return false }

        let displayTaxonGroups = row.displayTaxonGroups
        let groups = Set(displayTaxonGroups.map { $0.lowercased() })
        let includedGroups = displayState.normalizedIncludedTaxonGroups
        if !includedGroups.isEmpty, groups.isDisjoint(with: includedGroups) { return false }
        let excludedGroups = displayState.normalizedExcludedTaxonGroups
        if !excludedGroups.isEmpty, !groups.isDisjoint(with: excludedGroups) { return false }

        let filter = displayState.normalizedFilterText
        guard !filter.isEmpty else { return true }
        let haystack = [
            row.scientificName,
            row.commonNamesText,
            row.potentialMatchesText,
            displayTaxonGroups.joined(separator: " "),
            row.taxids.joined(separator: " "),
            row.targetIDs.joined(separator: " "),
        ].joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(filter)
    }

    private func unresolvedMatchesDisplayState(_ row: TwelveSUnresolvedSequence) -> Bool {
        guard row.readCount >= displayState.minimumUnresolvedReads else { return false }
        guard displayState.chimeraFilter.includes(row.chimeraStatus) else { return false }
        let filter = displayState.normalizedFilterText
        guard !filter.isEmpty else { return true }
        let haystack = [
            row.sequenceID,
            row.sequence,
            row.chimeraStatus.displayName,
            row.note ?? "",
        ].joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(filter)
    }

    private func isHuman(_ row: TwelveSScientificNameCountRow) -> Bool {
        row.scientificName.caseInsensitiveCompare("Homo sapiens") == .orderedSame
            || row.taxids.contains("9606")
    }

    // MARK: - Detail (emitted to the Inspector .twelveSDetail tab)

    private var sampleDisplayNames: [String: String] {
        Dictionary(uniqueKeysWithValues: result?.samples.map { ($0.sampleID, $0.displayName) } ?? [])
    }

    private func handleTargetSelection(_ rows: [TwelveSScientificNameCountRow]) {
        guard mode == .targets else { return }
        updateActionBar()
        if rows.count == 1, let row = rows.first {
            // Emit the base detail immediately; reference sequences (read from
            // the bundle FASTA) fill in asynchronously so a high-target species
            // like Homo sapiens doesn't block the selection.
            emitDetail(TwelveSDetailPayload(targetRow: row, sampleDisplayNames: sampleDisplayNames))
            loadReferenceSequences(for: row)
        } else {
            emitDetail(nil)
        }
    }

    /// Reads the species' reference sequences off the main actor, then re-emits
    /// the detail payload with them attached — but only if the selection is
    /// still on the same species.
    private func loadReferenceSequences(for row: TwelveSScientificNameCountRow) {
        guard let provider = referenceProvider else { return }
        let targetIDs = row.targetIDs
        let species = row.scientificName
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sequences = provider.sequences(forTargetIDs: targetIDs)
            guard !sequences.isEmpty else { return }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self,
                          case let .target(detail)? = self.lastDetailPayload?.kind,
                          detail.scientificName == species
                    else { return }
                    self.emitDetail(TwelveSDetailPayload(kind: .target(detail.withReferenceSequences(sequences))))
                }
            }
        }
    }

    private func handleUnresolvedSelection(_ rows: [TwelveSUnresolvedSequence]) {
        guard mode == .unresolved else { return }
        updateActionBar()
        if rows.count == 1, let row = rows.first {
            emitDetail(TwelveSDetailPayload(unresolvedRow: row, sampleDisplayNames: sampleDisplayNames))
        } else {
            emitDetail(nil)
        }
    }

    private func emitDetail(_ payload: TwelveSDetailPayload?) {
        lastDetailPayload = payload
        onSelectedRowDetailChanged?(payload)
    }

    private func alternateTexts(for row: TwelveSScientificNameCountRow) -> [String] {
        TwelveSTargetTableView.alternateTexts(for: row)
    }

    private func updateActionBar() {
        switch mode {
        case .targets:
            var info = "\(targetRows.count) of \(allTargetRows.count) target rows"
            // Note when per-sample reads columns are auto-suppressed for a large cohort.
            if showReadsColumnsOverride == nil,
               orderedSelectedSampleIDs.count > autoReadsColumnSampleLimit {
                info += " · per-sample columns hidden for \(orderedSelectedSampleIDs.count) samples (use Sample Columns)"
            }
            actionBar.updateInfoText(info)
            actionBar.setBlastEnabled(false, reason: "Switch to Unresolved to BLAST unmatched sequences")
        case .unresolved:
            let count = selectedUnresolvedRows().count
            actionBar.updateInfoText("\(unresolvedRows.count) unresolved clusters visible")
            actionBar.setBlastEnabled(count > 0, reason: "No unresolved sequence clusters match the current filters")
        }
    }

    private func selectedUnresolvedRows() -> [TwelveSUnresolvedSequence] {
        guard mode == .unresolved else { return [] }
        let selected = unresolvedTable.selectedRowsByIdentity()
        return selected.isEmpty ? unresolvedTable.displayedRows : selected
    }

    private func performUnresolvedBlast() {
        guard let result else { return }
        let rows = selectedUnresolvedRows()
        guard !rows.isEmpty else { return }
        onUnresolvedBlastRequested?(
            TwelveSUnresolvedBlastRequest(
                bundleURL: result.bundleURL,
                minimumReads: displayState.minimumUnresolvedReads,
                sequences: rows
            )
        )
    }

    private func ensureBlastDrawer() -> BlastResultsDrawerTab {
        if let blastDrawerContainer {
            blastDrawerContainer.blastResultsTab.presentationStyle = .sequenceBlast
            return blastDrawerContainer.blastResultsTab
        }

        let container = BlastResultsDrawerContainerView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)
        let heightConstraint = container.heightAnchor.constraint(equalToConstant: 0)
        splitViewBottomConstraint?.isActive = false
        let newSplitBottom = tableContainer.bottomAnchor.constraint(equalTo: container.topAnchor)
        splitViewBottomConstraint = newSplitBottom
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: actionBar.topAnchor),
            heightConstraint,
            newSplitBottom,
        ])
        blastDrawerHeightConstraint = heightConstraint
        blastDrawerContainer = container
        container.onDrag = { [weak self] delta in
            guard let self, let heightConstraint = self.blastDrawerHeightConstraint else { return }
            let availableExtent = max(0, self.view.bounds.height - self.actionBar.frame.height)
            let proposed = heightConstraint.constant + delta
            heightConstraint.constant = SplitPaneSizing.clampedDrawerExtent(
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
        container.blastResultsTab.presentationStyle = .sequenceBlast
        container.blastResultsTab.onRerunBlast = { [weak self] in
            self?.performUnresolvedBlast()
        }
        container.blastResultsTab.onCancelBlast = { [weak self] in
            self?.onUnresolvedBlastCancelRequested?()
        }
        return container.blastResultsTab
    }

    private func openBlastDrawerIfNeeded() {
        guard !isBlastDrawerOpen, let blastDrawerHeightConstraint else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            blastDrawerHeightConstraint.animator().constant = 220
            view.layoutSubtreeIfNeeded()
        }
        isBlastDrawerOpen = true
    }

    private static func summaryText(for result: TwelveSAmpliconResultBundleData) -> String {
        let chimeraText = result.chimeraCandidateCount == 1
            ? "1 chimera candidate"
            : "\(result.chimeraCandidateCount) chimera candidates"
        return [
            "\(result.samples.count) samples",
            "\(result.readFate.exactMatchReads) exact reads",
            "\(formatPercent(result.readFate.unresolvedPercent)) unresolved",
            chimeraText,
        ].joined(separator: " | ")
    }

    private static func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    private func showExportMenu() {
        let menu = buildExportMenu()
        let point = NSPoint(x: actionBar.exportButton.bounds.minX, y: actionBar.exportButton.bounds.maxY)
        menu.popUp(positioning: nil, at: point, in: actionBar.exportButton)
    }

    private func buildExportMenu() -> NSMenu {
        let menu = NSMenu()
        for format in TwelveSAmpliconResultExportFormat.allCases {
            let item = NSMenuItem(
                title: "Export as \(format.displayName)...",
                action: #selector(exportFormatMenuItemTapped(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = format
            menu.addItem(item)
        }
        return menu
    }

    @objc private func exportFormatMenuItemTapped(_ sender: NSMenuItem) {
        guard let format = sender.representedObject as? TwelveSAmpliconResultExportFormat else { return }
        presentExport(format: format)
    }

    private func showProvenancePopover(relativeTo sender: NSView) {
        guard let result else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 220)
        popover.contentViewController = NSHostingController(
            rootView: TwelveSProvenanceSummaryView(result: result)
        )
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
    }

    private func presentExportError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "12S Export Failed"
        alert.informativeText = error.localizedDescription
        if let window = view.window ?? NSApp.keyWindow {
            alert.beginSheetModal(for: window)
        } else {
            NSApp.presentError(error)
        }
    }
}

extension TwelveSAmpliconResultViewController: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === copyContextMenu else { return }
        populateCopyContextMenu()
    }
}

extension TwelveSAmpliconResultViewController: NSPopoverDelegate {
    public func popoverDidClose(_ notification: Notification) {
        let newSelection = samplePickerState?.selectedSamples ?? selectedSamples
        samplePopover = nil
        guard newSelection != selectedSamples else { return }
        selectedSamples = newSelection
        updateSampleFilterButtonTitle()
        applyFilters(notify: false)
        rebuildSampleColumns()
    }
}

private struct TwelveSProvenanceSummaryView: View {
    let result: TwelveSAmpliconResultBundleData

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("12S Result Provenance", systemImage: "info.circle")
                .font(.headline)
            Divider()
            LabeledContent("Analysis", value: result.manifest.analysisName)
            LabeledContent("Samples", value: "\(result.samples.count)")
            LabeledContent("Exact Reads", value: "\(result.readFate.exactMatchReads)")
            LabeledContent("Unmatched", value: Self.percentText(result.readFate.unresolvedPercent))
            LabeledContent("Created", value: result.manifest.createdAt ?? "Unknown")
            Divider()
            Text(result.artifacts.provenanceURL.path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
        }
        .padding(14)
        .frame(minWidth: 320, alignment: .leading)
    }

    private static func percentText(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }
}
