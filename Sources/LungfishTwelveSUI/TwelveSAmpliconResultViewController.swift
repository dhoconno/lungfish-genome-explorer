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
    private let splitView = NSSplitView()
    private let tableContainer = NSView()
    private let targetTable = TwelveSTargetTableView()
    private let unresolvedTable = TwelveSUnresolvedTableView()
    private let detailScrollView = NSScrollView()
    private let detailStack = NSStackView()
    private let detailTitleLabel = NSTextField(labelWithString: "Selection")
    private let detailBodyLabel = NSTextField(labelWithString: "Select a row to review sample evidence.")
    private let detailSampleDisclosureButton = NSButton(title: "Sample Evidence", target: nil, action: nil)
    private let detailSampleLabel = NSTextField(labelWithString: "")
    private let detailAlternatesDisclosureButton = NSButton(title: "Alternate Exact Matches", target: nil, action: nil)
    private let detailAlternatesLabel = NSTextField(labelWithString: "")
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
    private var detailSampleRows: [TwelveSDetailSampleEvidenceRow] = []
    private var detailAlternateTexts: [String] = []
    private var isSampleEvidenceExpanded = true
    private var areAlternateMatchesExpanded = true

    /// Pasteboard seam for the copy context menu (overridable in tests).
    private var pasteboard: PasteboardWriting = DefaultPasteboard()
    private let copyContextMenu = NSMenu()

    public var onDisplaySummaryChanged: ((TwelveSResultDisplaySummary) -> Void)?
    public var onDisplayStateChanged: ((TwelveSResultDisplayState) -> Void)?
    public var onUnresolvedBlastRequested: ((TwelveSUnresolvedBlastRequest) -> Void)?
    public var onUnresolvedBlastCancelRequested: (() -> Void)?

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
        detailSampleRows
    }

    var testingAlternateMatchTexts: [String] {
        detailAlternateTexts
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
        configureDetailPane()
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
        titleLabel.stringValue = "\(result.manifest.outputName) 12S Matches"
        summaryLabel.stringValue = Self.summaryText(for: result)
        applyFilters(notify: false)
        showTargets()
    }

    public func applyDisplayState(_ state: TwelveSResultDisplayState) {
        displayState = state
        searchField.stringValue = state.filterText
        applyFilters(notify: true)
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

    private func configureDetailPane() {
        detailTitleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        detailTitleLabel.lineBreakMode = .byTruncatingTail

        [detailBodyLabel, detailSampleLabel, detailAlternatesLabel].forEach { label in
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 0
            label.lineBreakMode = .byWordWrapping
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        configureDetailDisclosureButton(
            detailSampleDisclosureButton,
            action: #selector(toggleSampleEvidenceDisclosure(_:))
        )
        configureDetailDisclosureButton(
            detailAlternatesDisclosureButton,
            action: #selector(toggleAlternateMatchesDisclosure(_:))
        )

        detailStack.orientation = .vertical
        detailStack.alignment = .leading
        detailStack.spacing = 8
        detailStack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        detailStack.translatesAutoresizingMaskIntoConstraints = false
        detailStack.addArrangedSubview(detailTitleLabel)
        detailStack.addArrangedSubview(detailBodyLabel)
        detailStack.addArrangedSubview(detailSampleDisclosureButton)
        detailStack.addArrangedSubview(detailSampleLabel)
        detailStack.addArrangedSubview(detailAlternatesDisclosureButton)
        detailStack.addArrangedSubview(detailAlternatesLabel)
        setTargetDetailSectionsHidden(true)

        detailScrollView.documentView = detailStack
        detailScrollView.hasVerticalScroller = true
        detailScrollView.borderType = .noBorder
    }

    private func configureDetailDisclosureButton(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .disclosure
        button.state = .on
        button.font = .systemFont(ofSize: 12, weight: .semibold)
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
        let headerRow = NSStackView(views: [titleLabel, modeControl, searchField])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(tableContainer)
        splitView.addArrangedSubview(detailScrollView)

        [headerRow, summaryLabel, splitView, actionBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }

        let splitBottom = splitView.bottomAnchor.constraint(equalTo: actionBar.topAnchor)
        splitViewBottomConstraint = splitBottom
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

            splitView.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 10),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            splitBottom,
            splitView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),

            tableContainer.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
            detailScrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),

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

    @objc private func toggleSampleEvidenceDisclosure(_ sender: NSButton) {
        isSampleEvidenceExpanded = sender.state == .on
        detailSampleLabel.isHidden = !isSampleEvidenceExpanded
    }

    @objc private func toggleAlternateMatchesDisclosure(_ sender: NSButton) {
        areAlternateMatchesExpanded = sender.state == .on
        detailAlternatesLabel.isHidden = !areAlternateMatchesExpanded
    }

    private func applyMode(_ mode: Mode) {
        self.mode = mode
        targetTable.isHidden = mode != .targets
        unresolvedTable.isHidden = mode != .unresolved
        clearDetail()
        updateActionBar()
        notifyDisplaySummaryChanged()
    }

    private func applyFilters(notify: Bool) {
        targetRows = allTargetRows.filter(targetMatchesDisplayState)
        unresolvedRows = allUnresolvedRows.filter(unresolvedMatchesDisplayState)
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

    /// Establishes the legacy default order (exact reads / read count descending)
    /// the first time rows are shown, matching the pre-migration behavior.
    private func applyDefaultSortIfNeeded() {
        if targetTable.tableView.sortDescriptors.isEmpty {
            targetTable.tableView.sortDescriptors = [NSSortDescriptor(key: "totalExactReads", ascending: false)]
        }
        if unresolvedTable.tableView.sortDescriptors.isEmpty {
            unresolvedTable.tableView.sortDescriptors = [NSSortDescriptor(key: "readCount", ascending: false)]
        }
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

    // MARK: - Detail (legacy split pane — removed in Phase 3)

    private func handleTargetSelection(_ rows: [TwelveSScientificNameCountRow]) {
        guard mode == .targets else { return }
        updateActionBar()
        if rows.count == 1, let row = rows.first {
            updateTargetDetail(row: row)
        } else {
            clearDetail()
        }
    }

    private func handleUnresolvedSelection(_ rows: [TwelveSUnresolvedSequence]) {
        guard mode == .unresolved else { return }
        updateActionBar()
        if rows.count == 1, let row = rows.first {
            updateUnresolvedDetail(row: row)
        } else {
            clearDetail()
        }
    }

    private func clearDetail() {
        detailSampleRows = []
        detailAlternateTexts = []
        switch mode {
        case .targets:
            detailTitleLabel.stringValue = "Target Evidence"
            detailBodyLabel.stringValue = "Select a target to review sample evidence and alternate exact matches."
        case .unresolved:
            detailTitleLabel.stringValue = "Unresolved Sequence"
            detailBodyLabel.stringValue = "Select an unresolved cluster to review sequence and sample counts."
        }
        setTargetDetailSectionsHidden(true)
    }

    private func updateTargetDetail(row: TwelveSScientificNameCountRow) {
        let sampleDisplayNames = Dictionary(uniqueKeysWithValues: result?.samples.map { ($0.sampleID, $0.displayName) } ?? [])
        detailSampleRows = row.sampleCounts
            .filter { $0.value > 0 }
            .map { sampleID, count in
                let denominator = row.sampleExactReadTotals[sampleID, default: 0]
                let percent = denominator > 0 ? Double(count) / Double(denominator) * 100 : 0
                return TwelveSDetailSampleEvidenceRow(
                    sampleID: sampleID,
                    displayName: sampleDisplayNames[sampleID] ?? sampleID,
                    exactReads: count,
                    percentOfSampleExactReads: percent
                )
            }
            .sorted {
                if $0.exactReads != $1.exactReads { return $0.exactReads > $1.exactReads }
                return $0.sampleID < $1.sampleID
            }
        detailAlternateTexts = alternateTexts(for: row)

        let sampleLines = detailSampleRows.map {
            "\($0.displayName): \($0.exactReads) reads (\(Self.formatPercent($0.percentOfSampleExactReads)))"
        }
        let alternateLines = detailAlternateTexts.isEmpty
            ? ["No alternate exact species labels recorded."]
            : detailAlternateTexts.map { "Alternate: \($0)" }
        detailTitleLabel.stringValue = row.scientificName
        detailBodyLabel.stringValue = [
            "\(row.totalExactReads) exact reads",
            "\(row.referenceTargetCount) reference target\(row.referenceTargetCount == 1 ? "" : "s")",
        ].joined(separator: " | ")
        detailSampleDisclosureButton.title = "Sample Evidence (\(detailSampleRows.count))"
        detailAlternatesDisclosureButton.title = "Alternate Exact Matches (\(detailAlternateTexts.count))"
        detailSampleLabel.stringValue = sampleLines.isEmpty ? "No sample-level evidence recorded." : sampleLines.joined(separator: "\n")
        detailAlternatesLabel.stringValue = alternateLines.joined(separator: "\n")
        setTargetDetailSectionsHidden(false)
    }

    private func updateUnresolvedDetail(row: TwelveSUnresolvedSequence) {
        detailSampleRows = []
        detailAlternateTexts = []
        let sampleLines = row.sampleCounts
            .filter { $0.value > 0 }
            .sorted {
                if $0.value != $1.value { return $0.value > $1.value }
                return $0.key < $1.key
            }
            .prefix(10)
            .map { "\($0.key): \($0.value) reads" }
        detailTitleLabel.stringValue = "\(row.sequenceID) | \(row.readCount) reads"
        detailBodyLabel.stringValue = ([
            "Chimera: \(row.chimeraStatus.displayName)",
            row.sequence,
        ] + sampleLines).joined(separator: "\n")
        setTargetDetailSectionsHidden(true)
    }

    private func setTargetDetailSectionsHidden(_ hidden: Bool) {
        detailSampleDisclosureButton.isHidden = hidden
        detailAlternatesDisclosureButton.isHidden = hidden
        detailSampleDisclosureButton.state = isSampleEvidenceExpanded ? .on : .off
        detailAlternatesDisclosureButton.state = areAlternateMatchesExpanded ? .on : .off
        detailSampleLabel.isHidden = hidden || !isSampleEvidenceExpanded
        detailAlternatesLabel.isHidden = hidden || !areAlternateMatchesExpanded
    }

    private func alternateTexts(for row: TwelveSScientificNameCountRow) -> [String] {
        TwelveSTargetTableView.alternateTexts(for: row)
    }

    private func updateActionBar() {
        switch mode {
        case .targets:
            actionBar.updateInfoText("\(targetRows.count) of \(allTargetRows.count) target rows")
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
        let newSplitBottom = splitView.bottomAnchor.constraint(equalTo: container.topAnchor)
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
