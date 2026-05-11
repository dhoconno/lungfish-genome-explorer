// WorkflowLibraryView.swift - Project workflow library sidebar
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow

@MainActor
public final class WorkflowLibraryView: NSView {
    public var onSelectWorkflow: ((WorkflowLibraryEntry) -> Void)?
    public var onCreateWorkflow: (() -> Void)?
    public var onDuplicateWorkflow: (() -> Void)?
    public var onDeleteWorkflow: (() -> Void)?
    public var onRenameWorkflow: ((WorkflowLibraryEntry, String) -> Void)?

    private var entries: [WorkflowLibraryEntry] = []
    private var isApplyingSelection = false
    private let tableView = WorkflowLibraryTableView()
    private let scrollView = NSScrollView()
    private let createButton = NSButton()
    private let duplicateButton = NSButton()
    private let deleteButton = NSButton()

    public var workflowNamesForTesting: [String] {
        entries.map(\.name)
    }

    public var contextMenuTitlesForTesting: [String] {
        tableView.menu?.items.map(\.title) ?? []
    }

    public var isNameColumnEditableForTesting: Bool {
        tableView.tableColumns.first?.isEditable == true
    }

    public var contextMenuActionsTargetLibraryForTesting: Bool {
        tableView.menu?.items
            .filter { $0.action != nil }
            .allSatisfy { $0.target as? WorkflowLibraryView === self } ?? false
    }

    public var selectedEntryForTesting: WorkflowLibraryEntry? {
        selectedEntry
    }

    public var selectedEntry: WorkflowLibraryEntry? {
        let row = tableView.selectedRow
        guard entries.indices.contains(row) else { return nil }
        return entries[row]
    }

    public init() {
        super.init(frame: .zero)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    public func setEntries(_ entries: [WorkflowLibraryEntry], selectedBundleURL: URL?) {
        self.entries = entries
        tableView.reloadData()
        let selectedPath = selectedBundleURL?.standardizedFileURL.path
        let selectedIndex = entries.firstIndex { $0.bundleURL.path == selectedPath }

        isApplyingSelection = true
        if let selectedIndex {
            tableView.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
        isApplyingSelection = false
        updateButtonState()
    }

    public func testingSelectWorkflow(named name: String) {
        guard let index = entries.firstIndex(where: { $0.name == name }) else { return }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
    }

    public func testingSelectContextMenuRow(at row: Int) {
        let rowRect = tableView.rect(ofRow: row)
        tableView.selectContextMenuRow(at: NSPoint(x: rowRect.midX, y: rowRect.midY))
    }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        let title = NSTextField(labelWithString: "Workflows")
        title.font = .preferredFont(forTextStyle: .subheadline)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(title)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        header.addArrangedSubview(spacer)

        configureButton(createButton, symbolName: "plus", tooltip: "New workflow", action: #selector(createWorkflow(_:)))
        configureButton(duplicateButton, symbolName: "doc.on.doc", tooltip: "Duplicate workflow", action: #selector(duplicateWorkflow(_:)))
        configureButton(deleteButton, symbolName: "trash", tooltip: "Delete workflow", action: #selector(deleteWorkflow(_:)))
        header.addArrangedSubview(createButton)
        header.addArrangedSubview(duplicateButton)
        header.addArrangedSubview(deleteButton)

        tableView.headerView = nil
        tableView.rowHeight = 30
        tableView.style = .sourceList
        tableView.allowsMultipleSelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(beginInlineRename(_:))
        tableView.setAccessibilityIdentifier("workflow-library-table")
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("WorkflowColumn"))
        column.isEditable = true
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.menu = makeContextMenu()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Workflow library")
        setAccessibilityIdentifier("workflow-library")
        updateButtonState()
    }

    private func configureButton(_ button: NSButton, symbolName: String, tooltip: String, action: Selector) {
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: tooltip)
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 22).isActive = true
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
    }

    private func updateButtonState() {
        let hasSelection = selectedEntry != nil
        duplicateButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
    }

    @objc private func createWorkflow(_ sender: Any?) {
        onCreateWorkflow?()
    }

    @objc private func duplicateWorkflow(_ sender: Any?) {
        onDuplicateWorkflow?()
    }

    @objc private func deleteWorkflow(_ sender: Any?) {
        onDeleteWorkflow?()
    }

    private func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        addContextMenuItem(to: menu, title: "Rename", action: #selector(beginInlineRename(_:)))
        addContextMenuItem(to: menu, title: "Duplicate", action: #selector(duplicateWorkflow(_:)))
        menu.addItem(NSMenuItem.separator())
        addContextMenuItem(to: menu, title: "Delete", action: #selector(deleteWorkflow(_:)))
        return menu
    }

    private func addContextMenuItem(to menu: NSMenu, title: String, action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func beginInlineRename(_ sender: Any?) {
        guard selectedEntry != nil else { return }
        tableView.editColumn(0, row: tableView.selectedRow, with: nil, select: true)
    }
}

private final class WorkflowLibraryTableView: NSTableView {
    override func rightMouseDown(with event: NSEvent) {
        selectContextMenuRow(at: convert(event.locationInWindow, from: nil))
        super.rightMouseDown(with: event)
    }

    func selectContextMenuRow(at point: NSPoint) {
        let clickedRow = row(at: point)
        guard clickedRow >= 0 else { return }
        selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
    }
}

extension WorkflowLibraryView: NSTableViewDataSource {
    public func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    public func tableView(
        _ tableView: NSTableView,
        setObjectValue object: Any?,
        for tableColumn: NSTableColumn?,
        row: Int
    ) {
        guard entries.indices.contains(row),
              let proposedName = object as? String else { return }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != entries[row].name else { return }
        onRenameWorkflow?(entries[row], name)
    }
}

extension WorkflowLibraryView: NSTableViewDelegate {
    public func tableView(
        _ tableView: NSTableView,
        shouldEdit tableColumn: NSTableColumn?,
        row: Int
    ) -> Bool {
        entries.indices.contains(row)
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("WorkflowLibraryCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView) ?? makeCell(identifier: identifier)
        let entry = entries[row]
        cell.textField?.stringValue = entry.name
        cell.textField?.toolTip = entry.bundleURL.path
        cell.imageView?.image = NSImage(systemSymbolName: "point.topleft.down.curvedto.point.bottomright.up", accessibilityDescription: "Workflow")
        cell.imageView?.contentTintColor = .systemBlue
        return cell
    }

    public func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonState()
        guard !isApplyingSelection, let selectedEntry else { return }
        onSelectWorkflow?(selectedEntry)
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        cell.addSubview(imageView)
        cell.imageView = imageView

        let textField = NSTextField(labelWithString: "")
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        textField.isEditable = true
        textField.isSelectable = true
        textField.isBordered = false
        textField.drawsBackground = false
        cell.addSubview(textField)
        cell.textField = textField

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),

            textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])

        return cell
    }
}

extension WorkflowLibraryView: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items where item.action != nil {
            item.isEnabled = selectedEntry != nil
        }
    }
}
