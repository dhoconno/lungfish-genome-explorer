// OperationsPanelController.swift - Operations window for operation progress
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Combine
import LungfishCore
import LungfishKit

/// A normal app window that displays all running, completed, and failed
/// operations tracked by ``OperationCenter``.
///
/// Accessed via the Operations menu (Shift-Option-Cmd-O) or programmatically.
@MainActor
final class OperationsPanelController: NSWindowController {

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = "Operations"
        window.level = .normal
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.minSize = NSSize(width: 700, height: 530)
        window.center()

        super.init(window: window)

        let viewController = OperationsPanelViewController()
        window.contentViewController = viewController
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class OperationsPanelBackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

// MARK: - OperationsPanelViewController

@MainActor
final class OperationsPanelViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSplitViewDelegate {

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let footerView = NSView()
    private let splitView = NSSplitView()
    private let inspector = OperationsLogInspector(frame: .zero)
    private var cancellables = Set<AnyCancellable>()
    private nonisolated(unsafe) var elapsedRefreshTimer: Timer?

    private var items: [OperationCenter.Item] = []
    private var drawerIsOpen = false
    private var drawerHeight: CGFloat = 349
    private var pendingRowReloadIDs: Set<UUID> = []
    private var pendingRowReloadTask: Task<Void, Never>?

    private static let coalescedRowReloadDelay: Duration = .milliseconds(150)

    /// DateFormatter for log entry timestamps (HH:mm:ss).
    private static let logTimestampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    deinit {
        elapsedRefreshTimer?.invalidate()
        elapsedRefreshTimer = nil
        pendingRowReloadTask?.cancel()
        pendingRowReloadTask = nil
    }

    override func loadView() {
        let container = OperationsPanelBackgroundView(frame: NSRect(x: 0, y: 0, width: 900, height: 650))
        view = container

        // Table setup
        setupTableView()

        // Footer with "Clear Completed" button
        setupFooter()

        // Layout
        // Supply valid initial geometry before attaching Auto Layout children.
        // NSSplitView's delegate also enforces these minima during window resize,
        // not only while the user drags the divider.
        splitView.frame = NSRect(x: 0, y: 40, width: 900, height: 610)
        scrollView.frame = NSRect(x: 0, y: 0, width: 900, height: 260)
        inspector.frame = NSRect(x: 0, y: 261, width: 900, height: 349)
        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = false
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.addArrangedSubview(scrollView)
        splitView.addArrangedSubview(inspector)
        inspector.isHidden = true
        inspector.onClose = { [weak self] in self?.setDrawerOpen(false) }
        footerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(splitView)
        container.addSubview(footerView)

        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: container.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: footerView.topAnchor),

            footerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footerView.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        items = OperationCenter.shared.items
        tableView.reloadData()
        if !items.isEmpty { tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        refreshInspector()
        updateElapsedRefreshTimer()

        OperationCenter.shared.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.applyOperationCenterChange(change)
                }
            }
            .store(in: &cancellables)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        guard let titleColumn = tableView.tableColumn(withIdentifier: .init("title")) else { return }
        let otherWidths = tableView.tableColumns.filter { $0 !== titleColumn }.reduce(CGFloat.zero) { $0 + $1.width }
        let spacing = CGFloat(tableView.tableColumns.count) * tableView.intercellSpacing.width
        let width = max(titleColumn.minWidth, scrollView.contentSize.width - otherWidths - spacing)
        guard abs(titleColumn.width - width) > 0.5 else { return }
        titleColumn.width = width
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard drawerIsOpen else {
            scrollView.frame = splitView.bounds
            return
        }
        let available = max(0, splitView.bounds.height - splitView.dividerThickness)
        let height = min(max(330, drawerHeight), max(0, available - 100))
        let listHeight = available - height
        scrollView.frame = NSRect(x: 0, y: 0, width: splitView.bounds.width, height: listHeight)
        inspector.frame = NSRect(x: 0, y: listHeight + splitView.dividerThickness,
                                 width: splitView.bounds.width, height: height)
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        100
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        max(100, splitView.bounds.height - 330)
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        if drawerIsOpen { drawerHeight = inspector.frame.height }
    }

    private func setDrawerOpen(_ open: Bool) {
        drawerIsOpen = open
        inspector.isHidden = !open
        splitView.adjustSubviews()
        if open, tableView.selectedRow >= 0 { tableView.scrollRowToVisible(tableView.selectedRow) }
        refreshInspector()
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<items.count), columnIndexes: IndexSet(integer: 0))
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshInspector()
        tableView.reloadData(forRowIndexes: IndexSet(integersIn: 0..<items.count), columnIndexes: IndexSet(integer: 0))
    }

    private func refreshInspector() {
        inspector.retainOperations(Set(items.map(\.id)))
        guard tableView.selectedRow >= 0, tableView.selectedRow < items.count else {
            inspector.display(nil)
            return
        }
        let item = items[tableView.selectedRow]
        let menu = NSMenu()
        menu.addItem(withTitle: "Actions", action: nil, keyEquivalent: "")
        populateActions(menu, for: item)
        inspector.display(item, actions: menu)
    }

    static func commandTextHeight(_ command: String, columnWidth: CGFloat) -> CGFloat {
        // Cell insets, Copy button, gap, and command box padding.
        let width = max(1, columnWidth - 64)
        let bounds = (command as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont(name: "Menlo", size: 10) ?? .monospacedSystemFont(ofSize: 10, weight: .regular)],
            context: nil
        )
        return max(14, ceil(bounds.height))
    }

    private func applyOperationCenterChange(_ change: OperationCenter.Change) {
        let previousItems = items
        let latestItems = OperationCenter.shared.items
        let selectedIDs = selectedOperationIDs()

        switch change {
        case .inserted(let id, let index):
            let pendingIDs = takePendingRowReloadIDs()
            items = latestItems
            if latestItems.count == previousItems.count + 1,
               index >= 0,
               index < latestItems.count,
               latestItems[index].id == id {
                tableView.insertRows(at: IndexSet(integer: index), withAnimation: [])
                reloadRows(for: pendingIDs)
            } else {
                reloadDataPreservingSelection(selectedIDs)
            }

        case .updated(let id, let index):
            items = latestItems
            guard let item = latestItems.first(where: { $0.id == id }) else {
                reloadDataPreservingSelection(selectedIDs)
                break
            }
            if item.state.isActive {
                scheduleCoalescedRowReload(for: id)
            } else {
                pendingRowReloadIDs.remove(id)
                reloadRow(for: id, preferredIndex: index)
            }

        case .removed(let ids):
            let removedSet = Set(ids)
            let pendingIDs = takePendingRowReloadIDs().subtracting(removedSet)
            let removedRows = previousItems.enumerated()
                .filter { removedSet.contains($0.element.id) }
                .map(\.offset)
            items = latestItems
            if latestItems.count + removedRows.count == previousItems.count,
               !removedRows.isEmpty {
                tableView.removeRows(at: IndexSet(removedRows), withAnimation: [])
                reloadRows(for: pendingIDs)
            } else {
                reloadDataPreservingSelection(selectedIDs.subtracting(removedSet))
            }

        case .reloaded:
            pendingRowReloadTask?.cancel()
            pendingRowReloadTask = nil
            pendingRowReloadIDs.removeAll()
            items = latestItems
            reloadDataPreservingSelection(selectedIDs)
        }

        if previousItems.isEmpty, !items.isEmpty, tableView.selectedRow < 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        switch change {
        case .updated: break // The bounded refresh above also refreshes the inspector.
        default: refreshInspector()
        }
        updateElapsedRefreshTimer()
    }

    private func scheduleCoalescedRowReload(for id: UUID) {
        pendingRowReloadIDs.insert(id)
        // A stream may never become quiet. Keep the first deadline, accumulating
        // dirty IDs without letting a noisy operation postpone other rows.
        guard pendingRowReloadTask == nil else { return }
        pendingRowReloadTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.coalescedRowReloadDelay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.flushPendingRowReloads()
        }
    }

    private func flushPendingRowReloads() {
        let ids = takePendingRowReloadIDs()
        guard !ids.isEmpty else { return }
        reloadRows(for: ids)
    }

    private func takePendingRowReloadIDs() -> Set<UUID> {
        pendingRowReloadTask?.cancel()
        pendingRowReloadTask = nil
        let ids = pendingRowReloadIDs
        pendingRowReloadIDs.removeAll()
        return ids
    }

    private func reloadRow(for id: UUID, preferredIndex: Int? = nil) {
        let row: Int?
        if let preferredIndex,
           preferredIndex >= 0,
           preferredIndex < items.count,
           items[preferredIndex].id == id {
            row = preferredIndex
        } else {
            row = items.firstIndex { $0.id == id }
        }
        guard items.count == tableView.numberOfRows,
              let row,
              row < tableView.numberOfRows else {
            reloadDataPreservingSelection(selectedOperationIDs())
            return
        }
        tableView.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
        )
        if tableView.selectedRow == row { refreshInspector() }
    }

    private func reloadRows(for ids: Set<UUID>) {
        guard items.count == tableView.numberOfRows else {
            reloadDataPreservingSelection(selectedOperationIDs())
            return
        }
        var rows = IndexSet()
        for (index, item) in items.enumerated() where ids.contains(item.id) {
            guard index < tableView.numberOfRows else {
                reloadDataPreservingSelection(selectedOperationIDs())
                return
            }
            rows.insert(index)
        }
        guard !rows.isEmpty else { return }
        tableView.reloadData(
            forRowIndexes: rows,
            columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns)
        )
        if rows.contains(tableView.selectedRow) { refreshInspector() }
    }

    private func selectedOperationIDs() -> Set<UUID> {
        Set(tableView.selectedRowIndexes.compactMap { row in
            guard row >= 0, row < items.count else { return nil }
            return items[row].id
        })
    }

    private func reloadDataPreservingSelection(_ selectedIDs: Set<UUID>) {
        tableView.reloadData()
        let rows = IndexSet(items.enumerated().compactMap { index, item in
            selectedIDs.contains(item.id) ? index : nil
        })
        if !rows.isEmpty {
            tableView.selectRowIndexes(rows, byExtendingSelection: false)
        }
    }

    // MARK: - Elapsed Refresh Timer

    /// Starts or stops the 1-second elapsed refresh timer based on whether any
    /// items are currently active.
    private func updateElapsedRefreshTimer() {
        let hasActiveItems = items.contains { $0.state.isActive }
        if hasActiveItems && elapsedRefreshTimer == nil {
            elapsedRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.refreshElapsedColumn()
                    }
                }
            }
        } else if !hasActiveItems && elapsedRefreshTimer != nil {
            elapsedRefreshTimer?.invalidate()
            elapsedRefreshTimer = nil
        }
    }

    /// Reloads only the elapsed column cells for active rows.
    private func refreshElapsedColumn() {
        guard let elapsedColumnIndex = tableView.tableColumns.firstIndex(where: {
            $0.identifier.rawValue == "elapsed"
        }) else { return }

        var activeRows = IndexSet()
        for (index, item) in items.enumerated() where item.state.isActive {
            activeRows.insert(index)
        }
        guard !activeRows.isEmpty else { return }
        tableView.reloadData(
            forRowIndexes: activeRows,
            columnIndexes: IndexSet([elapsedColumnIndex, 0])
        )
        inspector.updateLatest(at: Date())
    }

    // MARK: - Table Setup

    private func setupTableView() {
        let titleColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        titleColumn.title = "Operation"
        titleColumn.width = 200
        titleColumn.minWidth = 200
        tableView.addTableColumn(titleColumn)

        let progressColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("progress"))
        progressColumn.title = "Progress"
        progressColumn.width = 170
        progressColumn.minWidth = 135
        tableView.addTableColumn(progressColumn)

        let elapsedColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("elapsed"))
        elapsedColumn.title = "Time"
        elapsedColumn.width = 120
        elapsedColumn.minWidth = 90
        elapsedColumn.maxWidth = 160
        tableView.addTableColumn(elapsedColumn)

        let actionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        actionColumn.title = ""
        actionColumn.width = 82
        actionColumn.minWidth = 82
        actionColumn.maxWidth = 82
        tableView.addTableColumn(actionColumn)

        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 64
        tableView.headerView = NSTableHeaderView()
        tableView.setAccessibilityLabel("Operations table")
        tableView.setAccessibilityIdentifier("operations-table")

        // Context menu
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.setAccessibilityIdentifier("operations-scroll-view")
    }

    // MARK: - Footer

    private func setupFooter() {
        let clearButton = NSButton(title: "Clear Completed", target: self, action: #selector(clearCompleted))
        clearButton.bezelStyle = .rounded
        clearButton.translatesAutoresizingMaskIntoConstraints = false
        clearButton.setAccessibilityIdentifier("operations-clear-completed-button")

        footerView.addSubview(clearButton)

        NSLayoutConstraint.activate([
            clearButton.trailingAnchor.constraint(equalTo: footerView.trailingAnchor, constant: -12),
            clearButton.centerYAnchor.constraint(equalTo: footerView.centerYAnchor),
        ])
    }

    @objc private func clearCompleted() {
        OperationCenter.shared.clearCompleted()
    }

    @objc private func toggleDetailExpansion(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < items.count else { return }
        let close = drawerIsOpen && tableView.selectedRow == row
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        setDrawerOpen(!close)
    }

    @objc private func showResults(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard items.indices.contains(row) else { return }
        let item = items[row]
        Task { @MainActor [weak self] in
            guard !(await OperationResultNavigation.navigate(to: item)) else { return }
            guard let window = self?.view.window else { return }
            let alert = NSAlert()
            alert.messageText = "Unable to show results"
            alert.informativeText = "Open the operation’s project in the main viewer and make sure its result files are still available."
            await alert.beginSheetModal(for: window)
        }
    }

    @objc private func cancelItem(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < items.count else { return }
        guard items[row].isCancellable else { return }
        OperationCenter.shared.cancel(id: items[row].id)
    }

    @objc private func openGitHubIssueFromButton(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < items.count else { return }
        openGitHubIssue(for: items[row])
    }

    // MARK: - Context Menu Actions

    @objc private func contextRunAgain(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? OperationCenter.Item,
              let source = WorkflowOperationsWindowController.replaySourceBundleURL(for: item) else { return }
        WorkflowOperationsWindowController.showPreviousRun(at: source, routeContext: item.routeContext)
    }

    @objc private func contextRevealOutputs(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let item = items.first(where: { $0.id == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting(item.outputURLs + item.bundleURLs)
    }

    @objc private func contextCopyCLICommand(_ sender: NSMenuItem) {
        guard let itemID = sender.representedObject as? UUID,
              let item = items.first(where: { $0.id == itemID }),
              let cmd = item.cliCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }

    @objc private func contextCopyLog(_ sender: NSMenuItem) {
        guard let itemID = sender.representedObject as? UUID,
              let item = items.first(where: { $0.id == itemID }) else { return }
        let logText = formatLogEntries(item.logEntries)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(logText, forType: .string)
    }

    @objc private func contextViewLog(_ sender: NSMenuItem) {
        guard let itemID = sender.representedObject as? UUID,
              let item = items.first(where: { $0.id == itemID }) else { return }
        viewLog(for: item)
    }

    @objc private func contextRevealLog(_ sender: NSMenuItem) {
        guard let itemID = sender.representedObject as? UUID,
              let item = items.first(where: { $0.id == itemID }) else { return }
        revealLog(for: item)
    }

    @objc private func contextCopyFailureReport(_ sender: NSMenuItem) {
        guard let itemID = sender.representedObject as? UUID,
              let item = items.first(where: { $0.id == itemID }) else { return }
        let report = buildFailureReport(for: item)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
    }

    @objc private func contextRevealFailureReport(_ sender: NSMenuItem) {
        guard let itemID = sender.representedObject as? UUID,
              let item = items.first(where: { $0.id == itemID }),
              let reportURL = item.failureReportURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([reportURL])
    }

    @objc private func contextOpenGitHubIssue(_ sender: NSMenuItem) {
        guard let itemID = sender.representedObject as? UUID,
              let item = items.first(where: { $0.id == itemID }) else { return }
        openGitHubIssue(for: item)
    }

    @objc private func contextCancel(_ sender: NSMenuItem) {
        guard let itemID = sender.representedObject as? UUID else { return }
        OperationCenter.shared.cancel(id: itemID)
    }

    @objc private func contextClear(_ sender: NSMenuItem) {
        guard let itemID = sender.representedObject as? UUID else { return }
        OperationCenter.shared.clearItem(id: itemID)
    }

    // MARK: - Helpers

    private func viewLog(for item: OperationCenter.Item) {
        do {
            let logURL = try OperationLogDocument.write(item: item)
            NSWorkspace.shared.open(logURL)
        } catch {
            presentLogWriteFailure(error)
        }
    }

    private func revealLog(for item: OperationCenter.Item) {
        do {
            let logURL = try OperationLogDocument.write(item: item)
            NSWorkspace.shared.activateFileViewerSelecting([logURL])
        } catch {
            presentLogWriteFailure(error)
        }
    }

    private func presentLogWriteFailure(_ error: Error) {
        guard let window = view.window else {
            NSSound.beep()
            return
        }
        let alert = NSAlert(error: error)
        alert.messageText = "Unable to Write Operation Log"
        alert.informativeText = "Lungfish could not create a local log file for this operation."
        alert.beginSheetModal(for: window)
    }

    /// Formats log entries into a plain-text string for clipboard copy.
    private func formatLogEntries(_ entries: [OperationLogEntry]) -> String {
        entries.map { entry in
            let ts = Self.logTimestampFormatter.string(from: entry.timestamp)
            return "[\(ts)] [\(entry.level.rawValue.uppercased())] \(entry.message)"
        }.joined(separator: "\n")
    }

    /// Builds a structured failure report containing CLI command, error message,
    /// error detail, and full log — suitable for pasting into a bug report.
    ///
    /// Composition lives in ``OperationFailureReportStore`` beside the data it
    /// reads, so the report the user copies is byte-identical to the one
    /// already written to disk when the operation failed.
    private func buildFailureReport(for item: OperationCenter.Item) -> String {
        OperationFailureReportStore.buildFailureReport(for: item)
    }

    private func openGitHubIssue(for item: OperationCenter.Item) {
        guard item.state == .failed,
              let url = OperationFailureIssueReporter.newIssueURL(
                for: item,
                failureReport: buildFailureReport(for: item)
              ) else { return }
        GitHubIssueOpener.open(url)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        64
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count, let identifier = tableColumn?.identifier else { return nil }
        let item = items[row]

        switch identifier.rawValue {
        case "title":
            return buildTitleCell(for: item, identifier: identifier, in: tableView)

        case "progress":
            let cell = reuseOrCreate(identifier: identifier, in: tableView)
            let label: NSTextField = cell.viewWithTag(200) as? NSTextField ?? {
                let label = NSTextField(wrappingLabelWithString: "")
                label.tag = 200
                label.font = .systemFont(ofSize: 13)
                label.maximumNumberOfLines = 2
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 23),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    label.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
                ])
                return label
            }()
            label.stringValue = item.displayProgressLabel
            label.setAccessibilityIdentifier("operations-progress-\(item.id)")
            label.setAccessibilityLabel(item.displayProgressLabel)
            if let evidence = item.progressEvidence {
                label.toolTip = "\(item.displayProgressLabel) · \(evidence.phase) · \(evidence.basis)"
            } else { label.toolTip = item.displayProgressLabel }
            label.setAccessibilityHelp(label.toolTip)
            let status = Self.statusAppearance(for: item)
            label.textColor = .labelColor
            let symbol: NSImageView = cell.viewWithTag(201) as? NSImageView ?? {
                let symbol = NSImageView()
                symbol.tag = 201
                symbol.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(symbol)
                NSLayoutConstraint.activate([
                    symbol.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    symbol.topAnchor.constraint(equalTo: cell.topAnchor, constant: 8),
                    symbol.widthAnchor.constraint(equalToConstant: 13),
                    symbol.heightAnchor.constraint(equalToConstant: 13),
                ])
                symbol.setAccessibilityElement(false)
                return symbol
            }()
            symbol.image = NSImage(systemSymbolName: status.symbol, accessibilityDescription: nil)
            symbol.contentTintColor = status.color
            let bar: NSProgressIndicator = cell.subviews.compactMap { $0 as? NSProgressIndicator }.first ?? {
                let bar = NSProgressIndicator()
                bar.style = .bar
                bar.minValue = 0
                bar.maxValue = 1
                bar.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(bar)
                NSLayoutConstraint.activate([
                    bar.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    bar.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
                    bar.heightAnchor.constraint(equalToConstant: 5),
                ])
                return bar
            }()
            // Lifecycle text is always visible. Only evidence-backed work adds a bar.
            bar.isIndeterminate = false
            bar.isHidden = item.displayProgressFraction == nil || item.state != .running
            bar.doubleValue = item.displayProgressFraction ?? 0
            return cell

        case "elapsed":
            let cell = reuseOrCreate(identifier: identifier, in: tableView)
            let label: NSTextField = cell.viewWithTag(400) as? NSTextField ?? {
                let label = NSTextField(wrappingLabelWithString: "")
                label.tag = 400
                label.font = .systemFont(ofSize: 13)
                label.maximumNumberOfLines = 3
                label.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(label)
                NSLayoutConstraint.activate([
                    label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    label.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
                ])
                return label
            }()
            let now = Date()
            let elapsed = (item.finishedAt ?? now).timeIntervalSince(item.startedAt)
            let prefix = item.state.isActive ? "Elapsed" : item.state == .completed ? "Took" : "Ran"
            label.stringValue = "\(prefix) \(formatElapsedTime(elapsed))"
            if let remaining = item.estimatedRemainingTime(at: now) {
                label.stringValue += "\n≈\(formatElapsedTime(remaining)) remaining"
            }
            label.textColor = .secondaryLabelColor
            label.setAccessibilityLabel(label.stringValue)
            return cell

        case "action":
            let cell = reuseOrCreate(identifier: identifier, in: tableView)
            let resultsButton = cell.viewWithTag(302) as? NSButton ?? {
                let button = NSButton(title: "Results", target: self, action: #selector(showResults(_:)))
                button.tag = 302
                button.bezelStyle = .rounded
                button.controlSize = .small
                button.font = .systemFont(ofSize: 11)
                button.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(button)
                NSLayoutConstraint.activate([
                    button.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                    button.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
                ])
                return button
            }()
            resultsButton.isEnabled = OperationResultNavigation.canNavigate(to: item)
            resultsButton.setAccessibilityIdentifier("operations-results-\(item.id)")
            resultsButton.setAccessibilityLabel("Show results for \(item.title)")
            resultsButton.toolTip = resultsButton.isEnabled
                ? "Show this operation’s results in the main viewer"
                : "Results become available when the operation saves a viewable result"
            let cancelButton = cell.viewWithTag(300) as? NSButton ?? {
                let btn = NSButton(title: "Cancel", target: self, action: #selector(cancelItem(_:)))
                btn.tag = 300
                btn.bezelStyle = .rounded
                btn.controlSize = .small
                btn.font = .systemFont(ofSize: 10)
                btn.translatesAutoresizingMaskIntoConstraints = false
                btn.setAccessibilityIdentifier("operations-cancel-button")
                cell.addSubview(btn)
                NSLayoutConstraint.activate([
                    btn.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                    btn.topAnchor.constraint(equalTo: cell.topAnchor, constant: 30),
                ])
                return btn
            }()
            let issueButton = cell.viewWithTag(301) as? NSButton ?? {
                let btn = NSButton(title: "Issue", target: self, action: #selector(openGitHubIssueFromButton(_:)))
                btn.tag = 301
                btn.bezelStyle = .rounded
                btn.controlSize = .small
                btn.font = .systemFont(ofSize: 10)
                btn.translatesAutoresizingMaskIntoConstraints = false
                btn.setAccessibilityIdentifier("operations-open-github-issue-button")
                btn.setAccessibilityLabel("Open GitHub Issue")
                btn.setAccessibilityHelp("Opens a prefilled GitHub issue for this failed operation.")
                cell.addSubview(btn)
                NSLayoutConstraint.activate([
                    btn.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                    btn.topAnchor.constraint(equalTo: cell.topAnchor, constant: 30),
                ])
                return btn
            }()

            switch item.state {
            case .running:
                cancelButton.isHidden = !item.isCancellable
                issueButton.isHidden = true
            case .cancelling:
                cancelButton.isHidden = true
                issueButton.isHidden = true
            case .failed:
                cancelButton.isHidden = true
                issueButton.isHidden = false
            case .completed, .cancelled:
                cancelButton.isHidden = true
                issueButton.isHidden = true
            }

            return cell

        default:
            return nil
        }
    }

    // MARK: - Title Cell Builder

    private func buildTitleCell(
        for item: OperationCenter.Item,
        identifier: NSUserInterfaceItemIdentifier,
        in tableView: NSTableView
    ) -> NSTableCellView {
        let cell = reuseOrCreate(identifier: identifier, in: tableView)
        let title = rowLabel(in: cell, tag: 100, top: 6, size: 13)
        title.stringValue = item.title
        title.toolTip = "\(item.operationType.rawValue): \(item.title)"
        title.setAccessibilityIdentifier("operations-title-\(accessibilitySlug(for: item.title))")
        let detail = rowLabel(in: cell, tag: 101, top: 23, size: 11)
        detail.stringValue = item.state == .failed ? (item.errorMessage ?? item.detail) : item.detail
        detail.textColor = item.state == .failed ? .lungfishDanger : .secondaryLabelColor
        detail.toolTip = detail.stringValue
        detail.setAccessibilityIdentifier("operations-detail-\(accessibilitySlug(for: item.title))")
        let latest = rowLabel(in: cell, tag: 103, top: 42, size: 11)
        latest.stringValue = OperationsLogInspector.latestLine(for: item)
        latest.textColor = .secondaryLabelColor
        latest.toolTip = item.latestLogEntry?.message
        latest.setAccessibilityIdentifier("operations-latest-\(item.id)")
        let button: NSButton = cell.viewWithTag(102) as? NSButton ?? {
            let button = NSButton(title: "Log", target: self, action: #selector(toggleDetailExpansion(_:)))
            button.tag = 102
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11)
            button.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(button)
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -3),
                button.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
                button.widthAnchor.constraint(equalToConstant: 70),
            ])
            return button
        }()
        button.setAccessibilityIdentifier("operations-detail-toggle-\(item.id.uuidString)")
        let isOpen = drawerIsOpen && items.indices.contains(tableView.selectedRow) && items[tableView.selectedRow].id == item.id
        button.title = isOpen ? "Hide Log" : "Log"
        button.setAccessibilityLabel("\(isOpen ? "Hide" : "Show") log for \(item.title)")
        button.toolTip = isOpen ? "Close the log drawer" : "Open the log drawer for this operation"
        return cell
    }

    private func rowLabel(in cell: NSTableCellView, tag: Int, top: CGFloat, size: CGFloat, weight: NSFont.Weight = .regular) -> NSTextField {
        if let label = cell.viewWithTag(tag) as? NSTextField { return label }
        let label = NSTextField(labelWithString: "")
        label.tag = tag
        label.font = .systemFont(ofSize: size, weight: weight)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: tag == 100 ? -78 : -4),
            label.topAnchor.constraint(equalTo: cell.topAnchor, constant: top),
        ])
        return label
    }

    private func accessibilitySlug(for value: String) -> String {
        value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
    }

    static func statusAppearance(for item: OperationCenter.Item) -> (color: NSColor, symbol: String) {
        switch item.state {
        case .completed:
            return item.hasWarnings ? (.systemOrange, "exclamationmark.triangle.fill") : (.systemGreen, "checkmark.circle.fill")
        case .failed: return (.systemRed, "xmark.circle.fill")
        case .running: return (.systemBlue, "arrow.trianglehead.2.clockwise.rotate.90")
        case .cancelling: return (.systemOrange, "stop.circle")
        case .cancelled: return (.secondaryLabelColor, "stop.circle.fill")
        }
    }

    // MARK: - Cell Reuse

    private func reuseOrCreate(identifier: NSUserInterfaceItemIdentifier, in tableView: NSTableView) -> NSTableCellView {
        if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            return existing
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        return cell
    }
}

// MARK: - Local Operation Log Documents

enum OperationLogDocument {
    static func write(item: OperationCenter.Item) throws -> URL {
        let url = fileURL(for: item)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try render(item: item).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func fileURL(for item: OperationCenter.Item) -> URL {
        let logsDirectory = defaultLogsDirectory()

        let datePrefix = fileTimestamp(item.startedAt)
        let titleSlug = slug(item.title)
        let idPrefix = String(item.id.uuidString.prefix(8)).lowercased()
        return logsDirectory.appendingPathComponent("\(datePrefix)-\(titleSlug)-\(idPrefix).log")
    }

    static func defaultLogsDirectory(
        appIdentity: LungfishAppIdentity = .current,
        libraryDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let library = libraryDirectory
            ?? fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library",
                isDirectory: true
            )
        return library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent(appIdentity.logDirectoryName, isDirectory: true)
            .appendingPathComponent("Operations", isDirectory: true)
    }

    private static func render(item: OperationCenter.Item) -> String {
        var lines: [String] = []
        lines.append("Lungfish Operation Log")
        lines.append("Operation: \(item.title)")
        lines.append("Operation ID: \(item.id.uuidString)")
        lines.append("Type: \(item.operationType.rawValue)")
        lines.append("State: \(item.displayStateLabel)")
        lines.append("Started: \(displayTimestamp(item.startedAt))")
        if let finishedAt = item.finishedAt {
            lines.append("Finished: \(displayTimestamp(finishedAt))")
        }
        lines.append("Progress: \(item.displayProgressLabel)")
        lines.append("Log scope: bounded captured preview; exported snapshot includes retained entries only.")

        if !item.detail.isEmpty {
            lines.append("")
            lines.append("Detail:")
            lines.append(item.detail)
        }

        if let cliCommand = item.cliCommand {
            lines.append("")
            lines.append("CLI Command:")
            lines.append(cliCommand)
        }

        if !item.outputURLs.isEmpty {
            lines.append("")
            lines.append("Output Files:")
            item.outputURLs.forEach { lines.append($0.path) }
        }

        if let errorMessage = item.errorMessage {
            lines.append("")
            lines.append("Error:")
            lines.append(errorMessage)
        }

        if let errorDetail = item.errorDetail {
            lines.append("")
            lines.append("Error Detail:")
            lines.append(errorDetail)
        }

        if !item.logEntries.isEmpty {
            lines.append("")
            lines.append("Log Entries:")
            item.logEntries.forEach { entry in
                lines.append("[\(displayTimestamp(entry.timestamp))] [\(entry.level.rawValue.uppercased())] \(entry.message)")
            }
        }

        if !item.retryEvents.isEmpty {
            lines.append("")
            lines.append("Retry Metadata:")
            item.retryEvents.forEach { retry in
                lines.append(
                    "[\(displayTimestamp(retry.timestamp))] HTTP \(retry.statusCode) attempt \(retry.attempt)/\(retry.maxRetries); next retry in \(retry.delaySeconds)s"
                )
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    private static func slug(_ value: String) -> String {
        let slug = value
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return String((slug.isEmpty ? "operation" : slug).prefix(48))
    }

    private static func displayTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZZ"
        return formatter.string(from: date)
    }

    private static func fileTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

// MARK: - Context Menu Delegate

extension OperationsPanelViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0, clickedRow < items.count else { return }
        let item = items[clickedRow]

        populateActions(menu, for: item)
    }

    private func populateActions(_ menu: NSMenu, for item: OperationCenter.Item) {
        if !item.outputURLs.isEmpty || !item.bundleURLs.isEmpty {
            let reveal = NSMenuItem(title: "Reveal Output Files", action: #selector(contextRevealOutputs(_:)), keyEquivalent: "")
            reveal.target = self
            reveal.representedObject = item.id
            menu.addItem(reveal)
        }
        if WorkflowOperationsWindowController.replaySourceBundleURL(for: item) != nil {
            let runAgain = NSMenuItem(title: "Run Again…", action: #selector(contextRunAgain(_:)), keyEquivalent: "")
            runAgain.target = self
            runAgain.representedObject = item
            menu.addItem(runAgain)
        }

        if item.cliCommand != nil {
            let copyCmd = NSMenuItem(title: "Copy CLI Command", action: #selector(contextCopyCLICommand(_:)), keyEquivalent: "")
            copyCmd.representedObject = item.id
            copyCmd.target = self
            menu.addItem(copyCmd)
        }

        if !item.logEntries.isEmpty {
            let copyLog = NSMenuItem(title: "Copy Log", action: #selector(contextCopyLog(_:)), keyEquivalent: "")
            copyLog.representedObject = item.id
            copyLog.target = self
            menu.addItem(copyLog)

            let viewLog = NSMenuItem(title: "View Log", action: #selector(contextViewLog(_:)), keyEquivalent: "")
            viewLog.representedObject = item.id
            viewLog.target = self
            menu.addItem(viewLog)

            let revealLog = NSMenuItem(title: "Reveal Log in Finder", action: #selector(contextRevealLog(_:)), keyEquivalent: "")
            revealLog.representedObject = item.id
            revealLog.target = self
            menu.addItem(revealLog)
        }

        // Failed operations can be copied as a report or opened as a prefilled
        // GitHub issue; the user reviews and submits in the browser.
        if item.state == .failed {
            let copyReport = NSMenuItem(title: "Copy Failure Report", action: #selector(contextCopyFailureReport(_:)), keyEquivalent: "")
            copyReport.representedObject = item.id
            copyReport.target = self
            menu.addItem(copyReport)

            let openIssue = NSMenuItem(title: "Open GitHub Issue", action: #selector(contextOpenGitHubIssue(_:)), keyEquivalent: "")
            openIssue.representedObject = item.id
            openIssue.target = self
            menu.addItem(openIssue)

            // The report was written automatically when the operation failed,
            // so this only has to point at it.
            if item.failureReportURL != nil {
                let revealReport = NSMenuItem(
                    title: "Reveal Failure Report in Finder",
                    action: #selector(contextRevealFailureReport(_:)),
                    keyEquivalent: ""
                )
                revealReport.representedObject = item.id
                revealReport.target = self
                menu.addItem(revealReport)
            }
        }

        if item.cliCommand != nil || !item.logEntries.isEmpty || item.state == .failed {
            menu.addItem(.separator())
        }

        if item.isCancellable {
            let cancelItem = NSMenuItem(title: "Cancel", action: #selector(contextCancel(_:)), keyEquivalent: "")
            cancelItem.representedObject = item.id
            cancelItem.target = self
            menu.addItem(cancelItem)
        } else if !item.state.isActive {
            let clearItem = NSMenuItem(title: "Clear", action: #selector(contextClear(_:)), keyEquivalent: "")
            clearItem.representedObject = item.id
            clearItem.target = self
            menu.addItem(clearItem)
        }
    }
}

// MARK: - Elapsed Time Formatting

/// Formats a time interval into a compact human-readable elapsed time string.
///
/// Formatting tiers:
/// - Less than 1 second: `"<1s"`
/// - 1--59 seconds: `"42s"`
/// - 1--59 minutes: `"3m 12s"`
/// - 1 hour or more: `"1h 23m"`
///
/// Negative intervals are clamped to zero and displayed as `"<1s"`.
///
/// Delegates to ``LungfishFormatters/formatDuration(_:)-`` (F46), the
/// canonical duration formatter shared across the app.
func formatElapsedTime(_ interval: TimeInterval) -> String {
    LungfishFormatters.formatDuration(interval)
}
