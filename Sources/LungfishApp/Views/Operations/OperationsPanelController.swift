// OperationsPanelController.swift - Floating panel for operation progress
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import Combine

/// A floating utility panel that displays all running, completed, and failed
/// operations tracked by ``OperationCenter``.
///
/// Accessed via the Operations menu (Shift-Option-Cmd-O) or programmatically.
@MainActor
final class OperationsPanelController: NSWindowController {

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.title = "Operations"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.minSize = NSSize(width: 460, height: 250)
        panel.center()

        super.init(window: panel)

        let viewController = OperationsPanelViewController()
        panel.contentViewController = viewController
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

// MARK: - Expansion Section Identifiers

/// Accessibility identifiers used to tag expansion sections in the title cell.
/// NSView.tag is read-only on macOS 26, so we use accessibilityIdentifier instead.
private enum ExpansionSectionID {
    static let cliCommand = "ops-expansion-cli"
    static let logEntries = "ops-expansion-log"
    static let errorBox = "ops-expansion-error"
}

// MARK: - OperationsPanelViewController

@MainActor
private final class OperationsPanelViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private let scrollView = NSScrollView()
    private let tableView = NSTableView()
    private let footerView = NSView()
    private var cancellables = Set<AnyCancellable>()
    private nonisolated(unsafe) var elapsedRefreshTimer: Timer?

    private var items: [OperationCenter.Item] = []

    /// Set of item IDs whose detail text is currently expanded.
    private var expandedItemIDs: Set<UUID> = []

    /// DateFormatter for log entry timestamps (HH:mm:ss).
    private static let logTimestampFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        return df
    }()

    deinit {
        elapsedRefreshTimer?.invalidate()
        elapsedRefreshTimer = nil
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 400))
        view = container

        // Table setup
        setupTableView()

        // Footer with "Clear Completed" button
        setupFooter()

        // Layout
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        footerView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        container.addSubview(footerView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerView.topAnchor),

            footerView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footerView.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        OperationCenter.shared.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newItems in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.items = newItems
                    self.tableView.reloadData()
                    self.updateElapsedRefreshTimer()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Elapsed Refresh Timer

    /// Starts or stops the 1-second elapsed refresh timer based on whether any
    /// items are currently running.
    private func updateElapsedRefreshTimer() {
        let hasRunning = items.contains { $0.state == .running }
        if hasRunning && elapsedRefreshTimer == nil {
            elapsedRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.refreshElapsedColumn()
                    }
                }
            }
        } else if !hasRunning && elapsedRefreshTimer != nil {
            elapsedRefreshTimer?.invalidate()
            elapsedRefreshTimer = nil
        }
    }

    /// Reloads only the elapsed column cells for running rows.
    private func refreshElapsedColumn() {
        guard let elapsedColumnIndex = tableView.tableColumns.firstIndex(where: {
            $0.identifier.rawValue == "elapsed"
        }) else { return }
        guard let etaColumnIndex = tableView.tableColumns.firstIndex(where: {
            $0.identifier.rawValue == "eta"
        }) else { return }

        var runningRows = IndexSet()
        for (index, item) in items.enumerated() where item.state == .running {
            runningRows.insert(index)
        }
        guard !runningRows.isEmpty else { return }
        tableView.reloadData(
            forRowIndexes: runningRows,
            columnIndexes: IndexSet([elapsedColumnIndex, etaColumnIndex])
        )
    }

    // MARK: - Table Setup

    private func setupTableView() {
        let typeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("type"))
        typeColumn.title = "Type"
        typeColumn.width = 80
        typeColumn.minWidth = 60
        tableView.addTableColumn(typeColumn)

        let titleColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        titleColumn.title = "Operation"
        titleColumn.width = 200
        titleColumn.minWidth = 100
        tableView.addTableColumn(titleColumn)

        let progressColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("progress"))
        progressColumn.title = "Progress"
        progressColumn.width = 120
        progressColumn.minWidth = 80
        tableView.addTableColumn(progressColumn)

        let elapsedColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("elapsed"))
        elapsedColumn.title = "Elapsed"
        elapsedColumn.width = 70
        elapsedColumn.minWidth = 50
        elapsedColumn.maxWidth = 90
        tableView.addTableColumn(elapsedColumn)

        let etaColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("eta"))
        etaColumn.title = "ETA"
        etaColumn.width = 70
        etaColumn.minWidth = 50
        etaColumn.maxWidth = 90
        tableView.addTableColumn(etaColumn)

        let actionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        actionColumn.title = ""
        actionColumn.width = 60
        actionColumn.minWidth = 60
        actionColumn.maxWidth = 60
        tableView.addTableColumn(actionColumn)

        tableView.dataSource = self
        tableView.delegate = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 36
        tableView.headerView = NSTableHeaderView()
        tableView.setAccessibilityLabel("Operations table")
        tableView.setAccessibilityIdentifier("operations-table")

        // Context menu
        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
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
        let itemID = items[row].id
        if expandedItemIDs.contains(itemID) {
            expandedItemIDs.remove(itemID)
        } else {
            expandedItemIDs.insert(itemID)
        }
        // Animate the row height change by telling the table to re-query heights.
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
        tableView.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
    }

    @objc private func cancelItem(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < items.count else { return }
        OperationCenter.shared.cancel(id: items[row].id)
    }

    // MARK: - Context Menu Actions

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

    @objc private func contextCopyFailureReport(_ sender: NSMenuItem) {
        guard let itemID = sender.representedObject as? UUID,
              let item = items.first(where: { $0.id == itemID }) else { return }
        let report = buildFailureReport(for: item)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
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
    /// Falls back gracefully: if structured `errorMessage`/`errorDetail` fields
    /// are not set (e.g. download failures that only populate `detail`), the
    /// `detail` subtitle text is used as the failure reason.
    private func buildFailureReport(for item: OperationCenter.Item) -> String {
        var lines: [String] = []
        lines.append("=== Lungfish Operation Failure Report ===")
        lines.append("Operation: \(item.title)")
        if let cmd = item.cliCommand {
            lines.append("")
            lines.append("CLI Command:")
            lines.append("  \(cmd)")
        }
        // Prefer structured errorMessage; fall back to the detail subtitle which
        // download/ingestion paths always populate with the failure reason.
        let errorText = item.errorMessage ?? item.detail
        if !errorText.isEmpty {
            lines.append("")
            lines.append("Error: \(errorText)")
        }
        if let detail = item.errorDetail {
            lines.append("")
            lines.append("Details:")
            detail.components(separatedBy: "\n").forEach { lines.append("  \($0)") }
        }
        if !item.logEntries.isEmpty {
            lines.append("")
            lines.append("Log:")
            lines.append(formatLogEntries(item.logEntries).components(separatedBy: "\n")
                .map { "  \($0)" }.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n")
    }

    /// Removes expansion-specific subviews (CLI command, log, error sections)
    /// from a cell view being reused in collapsed state.
    private func removeExpansionSubviews(from cell: NSTableCellView) {
        let expansionIDs: Set<String> = [
            ExpansionSectionID.cliCommand,
            ExpansionSectionID.logEntries,
            ExpansionSectionID.errorBox,
        ]
        cell.subviews
            .filter { expansionIDs.contains($0.accessibilityIdentifier() ?? "") }
            .forEach { $0.removeFromSuperview() }
    }

    // MARK: - Expanded Row Height Calculation

    /// Calculates the height for an expanded row based on its content.
    private func expandedRowHeight(for item: OperationCenter.Item, columnWidth: CGFloat) -> CGFloat {
        let textWidth = max(120, columnWidth - 28)
        let detailBounds = (item.detail as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 10)],
            context: nil
        )
        let detailHeight = ceil(detailBounds.height)

        var extraHeight: CGFloat = 0

        // CLI command section
        if item.cliCommand != nil {
            // Label (14pt) + spacing (4pt) + command box (~28pt) + spacing (6pt)
            extraHeight += 52
        }

        // Log entries section
        if !item.logEntries.isEmpty {
            // Label (14pt) + spacing (4pt) + scroll area (min 40, max 150) + spacing (6pt)
            let entryHeight = CGFloat(item.logEntries.count) * 16
            let logAreaHeight = min(150, max(40, entryHeight))
            extraHeight += 14 + 4 + logAreaHeight + 6
        }

        // Error section
        if item.state == .failed, item.errorMessage != nil {
            extraHeight += 40
            if item.errorDetail != nil {
                extraHeight += 36
            }
        }

        let total = 8 + 16 + 2 + detailHeight + extraHeight + 4
        return max(44, total)
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < items.count else { return 36 }
        let item = items[row]
        guard expandedItemIDs.contains(item.id) else { return 36 }

        let titleColumnWidth = tableView.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("title"))?.width ?? 220
        return expandedRowHeight(for: item, columnWidth: titleColumnWidth)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < items.count, let identifier = tableColumn?.identifier else { return nil }
        let item = items[row]

        switch identifier.rawValue {
        case "type":
            let cell = reuseOrCreate(identifier: identifier, in: tableView)
            let textField = cell.subviews.first as? NSTextField ?? {
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(tf)
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return tf
            }()
            textField.stringValue = item.operationType.rawValue
            textField.font = .systemFont(ofSize: 11)
            textField.textColor = .secondaryLabelColor
            return cell

        case "title":
            return buildTitleCell(for: item, identifier: identifier, in: tableView)

        case "progress":
            let cell = reuseOrCreate(identifier: identifier, in: tableView)
            let progressBar: NSProgressIndicator = cell.subviews.first(where: { $0 is NSProgressIndicator }) as? NSProgressIndicator ?? {
                let pb = NSProgressIndicator()
                pb.style = .bar
                pb.isIndeterminate = false
                pb.minValue = 0
                pb.maxValue = 1
                pb.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(pb)
                NSLayoutConstraint.activate([
                    pb.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    pb.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    pb.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return pb
            }()
            let statusLabel: NSTextField = cell.subviews.compactMap({ $0 as? NSTextField }).first ?? {
                let tf = NSTextField(labelWithString: "")
                tf.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(tf)
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return tf
            }()

            switch item.state {
            case .running:
                progressBar.doubleValue = item.progress
                progressBar.isHidden = false
                statusLabel.isHidden = true
            case .completed, .failed:
                progressBar.isHidden = true
                statusLabel.isHidden = false
                statusLabel.stringValue = item.displayStateLabel
                if item.state == .failed {
                    statusLabel.textColor = .systemRed
                } else if item.hasWarnings {
                    statusLabel.textColor = .systemOrange
                } else {
                    statusLabel.textColor = .systemGreen
                }
                statusLabel.font = .systemFont(ofSize: 11)
            }
            return cell

        case "elapsed":
            let cell = reuseOrCreate(identifier: identifier, in: tableView)
            let textField = cell.viewWithTag(400) as? NSTextField ?? {
                let tf = NSTextField(labelWithString: "")
                tf.tag = 400
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.alignment = .right
                cell.addSubview(tf)
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return tf
            }()
            textField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

            switch item.state {
            case .running:
                let elapsed = Date().timeIntervalSince(item.startedAt)
                textField.stringValue = formatElapsedTime(elapsed)
                textField.textColor = .secondaryLabelColor
            case .completed, .failed:
                let elapsed = (item.finishedAt ?? Date()).timeIntervalSince(item.startedAt)
                textField.stringValue = formatElapsedTime(elapsed)
                textField.textColor = .tertiaryLabelColor
            }
            return cell

        case "eta":
            let cell = reuseOrCreate(identifier: identifier, in: tableView)
            let textField = cell.viewWithTag(410) as? NSTextField ?? {
                let tf = NSTextField(labelWithString: "")
                tf.tag = 410
                tf.translatesAutoresizingMaskIntoConstraints = false
                tf.alignment = .right
                cell.addSubview(tf)
                NSLayoutConstraint.activate([
                    tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                return tf
            }()
            textField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)

            switch item.state {
            case .running:
                if item.progress > 0, item.progress < 1 {
                    let elapsed = Date().timeIntervalSince(item.startedAt)
                    let remaining = max(0, elapsed * (1 - item.progress) / item.progress)
                    textField.stringValue = formatElapsedTime(remaining)
                } else {
                    textField.stringValue = "—"
                }
                textField.textColor = .secondaryLabelColor
            case .completed, .failed:
                textField.stringValue = "—"
                textField.textColor = .tertiaryLabelColor
            }
            return cell

        case "action":
            let cell = reuseOrCreate(identifier: identifier, in: tableView)
            if item.state == .running {
                let button = cell.viewWithTag(300) as? NSButton ?? {
                    let btn = NSButton(title: "Cancel", target: self, action: #selector(cancelItem(_:)))
                    btn.tag = 300
                    btn.bezelStyle = .rounded
                    btn.controlSize = .small
                    btn.font = .systemFont(ofSize: 10)
                    btn.translatesAutoresizingMaskIntoConstraints = false
                    cell.addSubview(btn)
                    NSLayoutConstraint.activate([
                        btn.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                        btn.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    ])
                    return btn
                }()
                button.isHidden = false
            } else {
                (cell.viewWithTag(300) as? NSButton)?.isHidden = true
            }
            return cell

        default:
            return nil
        }
    }

    // MARK: - Title Cell Builder

    /// Builds the title column cell, including expanded sections for CLI command,
    /// log entries, and error display.
    private func buildTitleCell(
        for item: OperationCenter.Item,
        identifier: NSUserInterfaceItemIdentifier,
        in tableView: NSTableView
    ) -> NSTableCellView {
        // Always create a fresh cell for expanded rows to avoid stale subviews.
        // For collapsed rows, reuse is safe.
        let isExpanded = expandedItemIDs.contains(item.id)
        let cell: NSTableCellView
        if isExpanded {
            cell = NSTableCellView()
            cell.identifier = identifier
        } else {
            cell = reuseOrCreate(identifier: identifier, in: tableView)
            // Remove any expansion subviews left from a previously expanded state
            removeExpansionSubviews(from: cell)
        }

        // Title field (tag 100)
        let titleField = cell.viewWithTag(100) as? NSTextField ?? {
            let tf = NSTextField(labelWithString: "")
            tf.tag = 100
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            tf.maximumNumberOfLines = 1
            cell.addSubview(tf)
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -22),
                tf.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            ])
            return tf
        }()
        titleField.stringValue = item.title
        titleField.font = .systemFont(ofSize: 12, weight: .medium)

        // Detail field (tag 101)
        let detailField = cell.viewWithTag(101) as? NSTextField ?? {
            let tf = NSTextField(labelWithString: "")
            tf.tag = 101
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            cell.addSubview(tf)
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -22),
                tf.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1),
            ])
            return tf
        }()

        // Disclosure toggle (tag 102)
        let moreButton = cell.viewWithTag(102) as? NSButton ?? {
            let btn = NSButton(title: "", target: self, action: #selector(toggleDetailExpansion(_:)))
            btn.tag = 102
            btn.setButtonType(.onOff)
            btn.bezelStyle = .disclosure
            btn.controlSize = .mini
            btn.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(btn)
            NSLayoutConstraint.activate([
                btn.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                btn.topAnchor.constraint(equalTo: cell.topAnchor, constant: 2),
            ])
            return btn
        }()
        moreButton.setAccessibilityLabel(isExpanded ? "Collapse operation details" : "Expand operation details")
        moreButton.setAccessibilityIdentifier("operations-detail-toggle-\(item.id.uuidString)")
        moreButton.setAccessibilityHelp("Shows or hides the CLI command, logs, and error details for this operation.")

        let isMultiLine = item.detail.contains("\n") || item.detail.count > 60
        let hasExpandableContent = isMultiLine || item.cliCommand != nil || !item.logEntries.isEmpty
            || (item.state == .failed && item.errorMessage != nil)

        if isExpanded {
            detailField.stringValue = item.detail
            detailField.lineBreakMode = .byWordWrapping
            detailField.maximumNumberOfLines = 0
            moreButton.state = .on
            moreButton.isHidden = false

            // Build expanded sections below the detail field
            var lastAnchor = detailField.bottomAnchor

            // CLI Command section
            if let cmd = item.cliCommand {
                let section = buildCLICommandSection(command: cmd)
                section.setAccessibilityIdentifier(ExpansionSectionID.cliCommand)
                section.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(section)
                NSLayoutConstraint.activate([
                    section.topAnchor.constraint(equalTo: lastAnchor, constant: 6),
                    section.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    section.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                ])
                lastAnchor = section.bottomAnchor
            }

            // Log entries section
            if !item.logEntries.isEmpty {
                let section = buildLogEntriesSection(entries: item.logEntries)
                section.setAccessibilityIdentifier(ExpansionSectionID.logEntries)
                section.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(section)
                let entryHeight = CGFloat(item.logEntries.count) * 16
                let logAreaHeight = min(150, max(40, entryHeight))
                NSLayoutConstraint.activate([
                    section.topAnchor.constraint(equalTo: lastAnchor, constant: 6),
                    section.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    section.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                    section.heightAnchor.constraint(equalToConstant: logAreaHeight + 18),
                ])
                lastAnchor = section.bottomAnchor
            }

            // Error section (for failed operations)
            if item.state == .failed, let errorMsg = item.errorMessage {
                let section = buildErrorSection(message: errorMsg, detail: item.errorDetail)
                section.setAccessibilityIdentifier(ExpansionSectionID.errorBox)
                section.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(section)
                NSLayoutConstraint.activate([
                    section.topAnchor.constraint(equalTo: lastAnchor, constant: 6),
                    section.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                    section.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                ])
                lastAnchor = section.bottomAnchor
            }
        } else {
            let collapsed = item.detail.replacingOccurrences(of: "\n", with: ", ")
            detailField.stringValue = collapsed
            detailField.lineBreakMode = .byTruncatingTail
            detailField.maximumNumberOfLines = 1
            moreButton.state = .off
            moreButton.isHidden = !hasExpandableContent
        }

        detailField.toolTip = isMultiLine ? item.detail : nil
        detailField.font = .systemFont(ofSize: 10)
        detailField.textColor = .secondaryLabelColor

        return cell
    }

    // MARK: - Expanded Section Builders

    /// Builds the CLI command display section with a grey background box and Copy button.
    private func buildCLICommandSection(command: String) -> NSView {
        let container = NSView()

        let label = NSTextField(labelWithString: "CLI Command")
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        // Grey background box for the command text
        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        box.layer?.cornerRadius = 4
        container.addSubview(box)

        let commandField = NSTextField(labelWithString: command)
        commandField.font = NSFont(name: "Menlo", size: 10) ?? .monospacedSystemFont(ofSize: 10, weight: .regular)
        commandField.textColor = .labelColor
        commandField.lineBreakMode = .byTruncatingTail
        commandField.maximumNumberOfLines = 2
        commandField.isSelectable = true
        commandField.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(commandField)

        let copyButton = NSButton(title: "Copy", target: self, action: #selector(copyCLIFromButton(_:)))
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .mini
        copyButton.font = .systemFont(ofSize: 9)
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(copyButton)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),

            box.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
            box.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -4),
            box.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            commandField.topAnchor.constraint(equalTo: box.topAnchor, constant: 3),
            commandField.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            commandField.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
            commandField.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -3),

            copyButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            copyButton.centerYAnchor.constraint(equalTo: box.centerYAnchor),
            copyButton.widthAnchor.constraint(equalToConstant: 40),
        ])

        return container
    }

    /// Copies the CLI command for the row containing the sender button.
    @objc private func copyCLIFromButton(_ sender: NSButton) {
        let row = tableView.row(for: sender)
        guard row >= 0, row < items.count, let cmd = items[row].cliCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(cmd, forType: .string)
    }

    /// Builds the log entries section with a scrollable list of timestamped entries.
    private func buildLogEntriesSection(entries: [OperationLogEntry]) -> NSView {
        let container = NSView()

        let label = NSTextField(labelWithString: "Log")
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        let logScrollView = NSScrollView()
        logScrollView.translatesAutoresizingMaskIntoConstraints = false
        logScrollView.hasVerticalScroller = true
        logScrollView.autohidesScrollers = true
        logScrollView.borderType = .bezelBorder
        logScrollView.drawsBackground = true
        logScrollView.backgroundColor = .textBackgroundColor
        container.addSubview(logScrollView)

        // Build attributed string with all log entries
        let logText = NSMutableAttributedString()
        let monoFont = NSFont(name: "Menlo", size: 9.5) ?? .monospacedSystemFont(ofSize: 9.5, weight: .regular)

        for (index, entry) in entries.enumerated() {
            let ts = Self.logTimestampFormatter.string(from: entry.timestamp)
            let levelIndicator: String
            let levelColor: NSColor
            switch entry.level {
            case .debug:
                levelIndicator = "DBG"
                levelColor = .systemGray
            case .info:
                levelIndicator = "INF"
                levelColor = .secondaryLabelColor
            case .warning:
                levelIndicator = "WRN"
                levelColor = .systemOrange
            case .error:
                levelIndicator = "ERR"
                levelColor = .systemRed
            }

            let line = "\(ts) [\(levelIndicator)] \(entry.message)"
            let attrs: [NSAttributedString.Key: Any] = [
                .font: monoFont,
                .foregroundColor: entry.level == .error ? NSColor.systemRed : levelColor,
            ]
            if index > 0 {
                logText.append(NSAttributedString(string: "\n"))
            }
            logText.append(NSAttributedString(string: line, attributes: attrs))
        }

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.textStorage?.setAttributedString(logText)
        textView.backgroundColor = .textBackgroundColor
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        logScrollView.documentView = textView

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),

            logScrollView.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
            logScrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            logScrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            logScrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        return container
    }

    /// Builds the error display section with red background highlighting.
    private func buildErrorSection(message: String, detail: String?) -> NSView {
        let container = NSView()

        let box = NSView()
        box.translatesAutoresizingMaskIntoConstraints = false
        box.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.1).cgColor
        box.layer?.cornerRadius = 4
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.systemRed.withAlphaComponent(0.3).cgColor
        container.addSubview(box)

        let errorLabel = NSTextField(labelWithString: message)
        errorLabel.font = .systemFont(ofSize: 11, weight: .medium)
        errorLabel.textColor = .systemRed
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.maximumNumberOfLines = 3
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(errorLabel)

        var constraints = [
            box.topAnchor.constraint(equalTo: container.topAnchor),
            box.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            box.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            errorLabel.topAnchor.constraint(equalTo: box.topAnchor, constant: 4),
            errorLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
            errorLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
        ]

        if let detail {
            let detailLabel = NSTextField(labelWithString: detail)
            detailLabel.font = NSFont(name: "Menlo", size: 9) ?? .monospacedSystemFont(ofSize: 9, weight: .regular)
            detailLabel.textColor = .systemRed.withAlphaComponent(0.8)
            detailLabel.lineBreakMode = .byWordWrapping
            detailLabel.maximumNumberOfLines = 4
            detailLabel.isSelectable = true
            detailLabel.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(detailLabel)
            constraints.append(contentsOf: [
                detailLabel.topAnchor.constraint(equalTo: errorLabel.bottomAnchor, constant: 2),
                detailLabel.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 6),
                detailLabel.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -6),
                detailLabel.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -4),
            ])
        } else {
            constraints.append(
                errorLabel.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -4)
            )
        }

        NSLayoutConstraint.activate(constraints)
        return container
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

// MARK: - Context Menu Delegate

extension OperationsPanelViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let clickedRow = tableView.clickedRow
        guard clickedRow >= 0, clickedRow < items.count else { return }
        let item = items[clickedRow]

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
        }

        // For failed operations, offer a single "Copy Failure Report" that bundles
        // the CLI command + error/detail text + log into one clipboard copy.
        // Show this regardless of whether errorMessage/logEntries are populated —
        // the detail field always contains the failure reason.
        if item.state == .failed {
            let copyReport = NSMenuItem(title: "Copy Failure Report", action: #selector(contextCopyFailureReport(_:)), keyEquivalent: "")
            copyReport.representedObject = item.id
            copyReport.target = self
            menu.addItem(copyReport)
        }

        if item.cliCommand != nil || !item.logEntries.isEmpty || item.state == .failed {
            menu.addItem(.separator())
        }

        if item.state == .running {
            let cancelItem = NSMenuItem(title: "Cancel", action: #selector(contextCancel(_:)), keyEquivalent: "")
            cancelItem.representedObject = item.id
            cancelItem.target = self
            menu.addItem(cancelItem)
        } else {
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
func formatElapsedTime(_ interval: TimeInterval) -> String {
    let elapsed = max(0, interval)
    if elapsed < 1 { return "<1s" }
    let totalSeconds = Int(elapsed)
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 { return "\(hours)h \(minutes)m" }
    if minutes > 0 { return "\(minutes)m \(seconds)s" }
    return "\(seconds)s"
}
