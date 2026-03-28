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
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: true
        )
        panel.title = "Operations"
        panel.isFloatingPanel = true
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

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
    }

    // MARK: - Footer

    private func setupFooter() {
        let clearButton = NSButton(title: "Clear Completed", target: self, action: #selector(clearCompleted))
        clearButton.bezelStyle = .rounded
        clearButton.translatesAutoresizingMaskIntoConstraints = false

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
        let textWidth = max(120, titleColumnWidth - 28) // account for disclosure button + paddings
        let detailBounds = (item.detail as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 10)],
            context: nil
        )
        let detailHeight = ceil(detailBounds.height)
        let total = 8 + 16 + 2 + detailHeight + 4
        return max(44, total)
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
            let cell = reuseOrCreate(identifier: identifier, in: tableView)
            // Title + detail as two-line layout
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
                    tf.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -2),
                ])
                return tf
            }()

            // Find or create the disclosure toggle button (tag 102)
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

            let isExpanded = expandedItemIDs.contains(item.id)
            let isMultiLine = item.detail.contains("\n") || item.detail.count > 60

            if isExpanded {
                // Show full text, wrapping
                detailField.stringValue = item.detail
                detailField.lineBreakMode = .byWordWrapping
                detailField.maximumNumberOfLines = 0
                moreButton.state = .on
                moreButton.isHidden = false
            } else {
                // Collapse to single line: join newlines with ", "
                let collapsed = item.detail.replacingOccurrences(of: "\n", with: ", ")
                detailField.stringValue = collapsed
                detailField.lineBreakMode = .byTruncatingTail
                detailField.maximumNumberOfLines = 1
                moreButton.state = .off
                moreButton.isHidden = !isMultiLine
            }
            detailField.toolTip = isMultiLine ? item.detail : nil
            detailField.font = .systemFont(ofSize: 10)
            detailField.textColor = .secondaryLabelColor
            return cell

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
            // Find or create the status label (tag 201)
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
                statusLabel.stringValue = item.state == .completed ? "Completed" : "Failed"
                statusLabel.textColor = item.state == .completed ? .systemGreen : .systemRed
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

    private func reuseOrCreate(identifier: NSUserInterfaceItemIdentifier, in tableView: NSTableView) -> NSTableCellView {
        if let existing = tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            return existing
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        return cell
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
