import AppKit
import LungfishIO
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class TwelveSAmpliconResultViewController: NSViewController {
    private enum Mode: Int {
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
    private let splitView = NSSplitView()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
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

    var onDisplaySummaryChanged: ((TwelveSResultDisplaySummary) -> Void)?
    var onDisplayStateChanged: ((TwelveSResultDisplayState) -> Void)?
    var onUnresolvedBlastRequested: ((TwelveSUnresolvedBlastRequest) -> Void)?
    var onUnresolvedBlastCancelRequested: (() -> Void)?

    var visibleTargetRowCount: Int {
        mode == .targets ? tableView.numberOfRows : targetRows.count
    }

    var visibleUnresolvedRowCount: Int {
        mode == .unresolved ? tableView.numberOfRows : unresolvedRows.count
    }

    var tableColumnIdentifiers: [String] {
        tableView.tableColumns.map { $0.identifier.rawValue }
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

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("12S amplicon result viewport")
        root.setAccessibilityIdentifier("twelve-s-amplicon-result-view")
        view = root

        configureHeader()
        configureTable()
        configureDetailPane()
        configureActionBar()
        layout()
    }

    func configure(result: TwelveSAmpliconResultBundleData) {
        self.result = result
        allTargetRows = result.scientificNameRows
        allUnresolvedRows = result.unresolvedSequences.sorted { lhs, rhs in
            if lhs.readCount != rhs.readCount { return lhs.readCount > rhs.readCount }
            return lhs.sequenceID < rhs.sequenceID
        }
        titleLabel.stringValue = "\(result.manifest.outputName) 12S Matches"
        summaryLabel.stringValue = Self.summaryText(for: result)
        applyFilters(notify: false)
        showTargets()
    }

    func applyDisplayState(_ state: TwelveSResultDisplayState) {
        displayState = state
        applyFilters(notify: true)
    }

    func showUnresolvedForTesting() {
        modeControl.selectedSegment = Mode.unresolved.rawValue
        applyMode(.unresolved)
    }

    func selectTargetForTesting(row: Int) {
        showTargets()
        guard targetRows.indices.contains(row) else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        updateDetailForCurrentSelection()
    }

    func triggerUnresolvedBlastForTesting() {
        performUnresolvedBlast()
    }

    func testingTargetText(row: Int, column: String) -> String {
        guard targetRows.indices.contains(row) else { return "" }
        return targetText(for: targetRows[row], column: column)
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

    func presentExport(format: TwelveSAmpliconResultExportFormat) {
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

    func showBlastLoading(phase: BlastJobPhase, requestId: String?) {
        let drawer = ensureBlastDrawer()
        drawer.showLoading(phase: phase, requestId: requestId)
        openBlastDrawerIfNeeded()
    }

    func showBlastResults(_ result: BlastVerificationResult) {
        let drawer = ensureBlastDrawer()
        drawer.showResults(result)
        openBlastDrawerIfNeeded()
    }

    func showBlastFailure(_ message: String) {
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
    }

    private func configureTable() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsColumnResizing = true
        tableView.allowsMultipleSelection = true
        tableView.rowHeight = 26
        tableView.headerView = NSTableHeaderView()
        tableView.setAccessibilityIdentifier("twelve-s-result-table")

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        scrollView.borderType = .noBorder
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
        let headerRow = NSStackView(views: [titleLabel, modeControl])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 12
        headerRow.translatesAutoresizingMaskIntoConstraints = false

        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.addArrangedSubview(scrollView)
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

            summaryLabel.topAnchor.constraint(equalTo: headerRow.bottomAnchor, constant: 6),
            summaryLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            summaryLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),

            splitView.topAnchor.constraint(equalTo: summaryLabel.bottomAnchor, constant: 10),
            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            splitBottom,
            splitView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),

            scrollView.widthAnchor.constraint(greaterThanOrEqualToConstant: 420),
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
        rebuildColumns()
        tableView.reloadData()
        tableView.deselectAll(nil)
        updateDetailForCurrentSelection()
        updateActionBar()
        notifyDisplaySummaryChanged()
    }

    private func applyFilters(notify: Bool) {
        targetRows = allTargetRows.filter(targetMatchesDisplayState)
        unresolvedRows = allUnresolvedRows.filter(unresolvedMatchesDisplayState)
        if mode == .targets || mode == .unresolved {
            tableView.reloadData()
            updateDetailForCurrentSelection()
            updateActionBar()
        }
        notifyDisplaySummaryChanged()
        if notify {
            onDisplayStateChanged?(displayState)
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

    private func rebuildColumns() {
        for column in tableView.tableColumns {
            tableView.removeTableColumn(column)
        }
        switch mode {
        case .targets:
            addColumn("scientificName", title: "Scientific Name", width: 220)
            addColumn("commonNames", title: "Common Names", width: 150)
            addColumn("taxonGroups", title: "Group", width: 95)
            addColumn("taxids", title: "Tax ID", width: 90)
            addColumn("totalExactReads", title: "Exact Reads", width: 90)
            addColumn("referenceTargets", title: "Refs", width: 60)
            addColumn("maxSamplePercent", title: "Max %", width: 80)
            addColumn("alternateMatchCount", title: "Alternates", width: 85)
        case .unresolved:
            addColumn("sequenceID", title: "Sequence", width: 130)
            addColumn("readCount", title: "Reads", width: 70)
            addColumn("sampleCount", title: "Samples", width: 75)
            addColumn("chimeraStatus", title: "Chimera", width: 110)
            addColumn("sequence", title: "Bases", width: 360)
        }
    }

    private func addColumn(_ identifier: String, title: String, width: CGFloat) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        column.minWidth = min(width, 60)
        tableView.addTableColumn(column)
    }

    private func updateDetailForCurrentSelection() {
        switch mode {
        case .targets:
            guard targetRows.indices.contains(tableView.selectedRow) else {
                detailSampleRows = []
                detailAlternateTexts = []
                detailTitleLabel.stringValue = "Target Evidence"
                detailBodyLabel.stringValue = "Select a target to review sample evidence and alternate exact matches."
                setTargetDetailSectionsHidden(true)
                return
            }
            updateTargetDetail(row: targetRows[tableView.selectedRow])
        case .unresolved:
            guard unresolvedRows.indices.contains(tableView.selectedRow) else {
                detailSampleRows = []
                detailAlternateTexts = []
                detailTitleLabel.stringValue = "Unresolved Sequence"
                detailBodyLabel.stringValue = "Select an unresolved cluster to review sequence and sample counts."
                setTargetDetailSectionsHidden(true)
                return
            }
            updateUnresolvedDetail(row: unresolvedRows[tableView.selectedRow])
        }
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
        if !row.alternateMatches.isEmpty {
            return row.alternateMatches.map(\.displayName)
        }
        return row.potentialMatches
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
        let selected = tableView.selectedRowIndexes.compactMap { index in
            unresolvedRows.indices.contains(index) ? unresolvedRows[index] : nil
        }
        return selected.isEmpty ? unresolvedRows : selected
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

extension TwelveSAmpliconResultViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        switch mode {
        case .targets:
            return targetRows.count
        case .unresolved:
            return unresolvedRows.count
        }
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let identifier = tableColumn?.identifier.rawValue else { return nil }
        let text: String
        switch mode {
        case .targets:
            guard targetRows.indices.contains(row) else { return nil }
            text = targetText(for: targetRows[row], column: identifier)
        case .unresolved:
            guard unresolvedRows.indices.contains(row) else { return nil }
            text = unresolvedText(for: unresolvedRows[row], column: identifier)
        }
        return makeCell(text)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateDetailForCurrentSelection()
        updateActionBar()
    }

    private func targetText(for row: TwelveSScientificNameCountRow, column: String) -> String {
        switch column {
        case "scientificName":
            return row.scientificName
        case "commonNames":
            return row.commonNamesText
        case "taxonGroups":
            return row.displayTaxonGroups.joined(separator: "; ")
        case "taxids":
            return row.taxids.joined(separator: "; ")
        case "totalExactReads":
            return String(row.totalExactReads)
        case "referenceTargets":
            return String(row.referenceTargetCount)
        case "maxSamplePercent":
            return Self.formatPercent(row.maxSamplePercent)
        case "alternateMatchCount":
            return String(alternateTexts(for: row).count)
        default:
            return ""
        }
    }

    private func unresolvedText(for row: TwelveSUnresolvedSequence, column: String) -> String {
        switch column {
        case "sequenceID":
            return row.sequenceID
        case "readCount":
            return String(row.readCount)
        case "sampleCount":
            return String(row.sampleCounts.filter { $0.value > 0 }.count)
        case "chimeraStatus":
            return row.chimeraStatus.displayName
        case "sequence":
            return row.sequence
        default:
            return ""
        }
    }

    private func makeCell(_ text: String) -> NSTableCellView {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
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
