// BatchTableView.swift - Generic base class for batch aggregated classifier table views
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import os.log

// MARK: - BatchColumnSpec

@MainActor
private final class BatchQuickCopyTextField: NSTextField {
    var pasteboard: PasteboardWriting?
    var copiedValue: (() -> String)?

    override func mouseDown(with event: NSEvent) {
        guard event.modifierFlags.contains(.command),
              let value = copiedValue?(),
              !value.isEmpty,
              let pasteboard else {
            super.mouseDown(with: event)
            return
        }

        pasteboard.setString(value)
    }
}

/// Column specification for a batch table.
///
/// Each entry describes one fixed column in a ``BatchTableView`` subclass.
struct BatchColumnSpec {
    /// The column's unique identifier (used as the sort-descriptor key too).
    let identifier: NSUserInterfaceItemIdentifier
    /// The header title string.
    let title: String
    /// Default column width.
    let width: CGFloat
    /// Minimum column width enforced by the table.
    let minWidth: CGFloat
    /// Whether the column sorts ascending by default (`true`) or descending (`false`).
    let defaultAscending: Bool
}

// MARK: - BatchTableView

/// Generic base class for batch aggregated table views (Kraken2, EsViritu, TaxTriage).
///
/// Subclasses provide:
/// - ``columnSpecs`` — fixed column definitions
/// - ``searchPlaceholder`` — placeholder text for the search field
/// - ``cellContent(for:row:)`` — cell text, alignment, and optional font for a given column
/// - ``rowMatchesFilter(_:filterText:)`` — whether a row matches the current filter
/// - ``compareRows(_:_:by:ascending:)`` — comparator for sorting by column key
/// - ``sampleId(for:)`` — sample identifier for metadata column lookups
///
/// All shared boilerplate (layout, scroll view, NSTableView configuration, sort/filter
/// pipeline, selection callbacks, metadata column controller) lives here.
///
/// ## Thread Safety
///
/// `@MainActor` isolated. All data must be provided via ``configure(rows:)``.
///
/// ## Swift Generics Constraint
///
/// `NSTableViewDataSource` and `NSTableViewDelegate` conformances are declared on the
/// class header (not in extensions) because Swift does not allow `@objc` protocol
/// conformances in extensions of generic classes.
@MainActor
class BatchTableView<Row>: NSView, NSTableViewDataSource, NSTableViewDelegate {

    // MARK: - Subclass Hooks

    /// Fixed column specifications. Subclasses must override this.
    var columnSpecs: [BatchColumnSpec] { [] }

    /// Placeholder string for the search field. Defaults to `"Filter…"`.
    var searchPlaceholder: String { "Filter\u{2026}" }

    /// Optional accessibility identifier for the search field.
    var searchAccessibilityIdentifier: String? { nil }

    /// Optional accessibility label for the search field.
    var searchAccessibilityLabel: String? { nil }

    /// Optional accessibility identifier for the table view.
    var tableAccessibilityIdentifier: String? { nil }

    /// Optional accessibility label for the table view.
    var tableAccessibilityLabel: String? { nil }

    /// Optional pasteboard used for command-click scalar copy in visible cells.
    var cellCopyPasteboard: PasteboardWriting? { nil }

    /// The list of standard (non-metadata) column titles registered with
    /// ``metadataColumns``. Defaults to the ``columnSpecs`` titles.
    var standardColumnNames: [String] { columnSpecs.map(\.title) }

    /// Returns the text, alignment, and optional font override for a cell.
    ///
    /// Subclasses override this to provide tool-specific rendering.
    /// When `font` is `nil`, the cell keeps the default font set by ``makeCellView(identifier:)``.
    /// The default implementation returns an empty string with left alignment and no font override.
    func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: Row
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        ("", .left, nil)
    }

    /// Returns whether the given row matches `filterText`.
    ///
    /// The default implementation always returns `true` (no filtering).
    func rowMatchesFilter(_ row: Row, filterText: String) -> Bool { true }

    /// Returns `true` if `lhs` should be ordered before `rhs` when sorting by `key`.
    ///
    /// Pass `ascending` directly to control the result direction. Returning `false` for
    /// both `(lhs, rhs)` and `(rhs, lhs)` is treated as equal by the sort. The default
    /// returns `false` for all keys.
    func compareRows(_ lhs: Row, _ rhs: Row, by key: String, ascending: Bool) -> Bool { false }

    /// Returns the sample identifier for `row`, used for metadata column lookups.
    ///
    /// Return `nil` if the row has no associated sample. The default returns `nil`.
    func sampleId(for row: Row) -> String? { nil }

    /// Returns a string value for a column, used by per-column filtering.
    ///
    /// Subclasses should override to return the appropriate value for each column.
    /// The default returns the cell content text from ``cellContent(for:row:)``.
    func columnValue(for columnId: String, row: Row) -> String {
        cellContent(for: NSUserInterfaceItemIdentifier(columnId), row: row).text
    }

    /// Column type hints — true = numeric, false = text.
    /// Subclasses should override to declare which columns are numeric.
    var columnTypeHints: [String: Bool] { [:] }

    // MARK: - State

    /// The rows currently displayed (after any filter and sort).
    private(set) var displayedRows: [Row] = []

    /// Pre-filter baseline preserved so re-sort can restart without re-filtering.
    private var unsortedRows: [Row] = []

    /// The full unfiltered set of rows as last provided by ``configure(rows:)``.
    var unfilteredRows: [Row] = []

    /// Per-column filters applied via column header click menus.
    internal(set) var columnFilters: [String: ColumnFilter] = [:]

    /// Original column titles before filter indicators were appended.
    private var originalColumnTitles: [String: String] = [:]

    /// Current filter text applied to rows.
    private var filterText: String = ""

    // MARK: - Callbacks

    /// Called when the user selects a single row.
    var onRowSelected: ((Row) -> Void)?

    /// Called when the user selects multiple rows. Provides the full array of selected rows.
    var onMultipleRowsSelected: (([Row]) -> Void)?

    /// Called when the selection is cleared.
    var onSelectionCleared: (() -> Void)?

    // MARK: - Metadata Columns

    /// Controller for dynamic sample-metadata columns (from imported CSV/TSV).
    let metadataColumns = MetadataColumnController()

    /// Optional contextual menu assigned to the table.
    var tableContextMenu: NSMenu? {
        didSet {
            tableView?.menu = tableContextMenu
        }
    }

    // MARK: - Child Views

    /// The table view. Accessible to subclasses for targeted column reloads.
    private(set) var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var searchField: NSSearchField!

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTableView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTableView()
    }

    // MARK: - Setup

    private func setupTableView() {
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Search field above the table.
        let sf = NSSearchField()
        sf.translatesAutoresizingMaskIntoConstraints = false
        sf.placeholderString = searchPlaceholder
        sf.font = .systemFont(ofSize: 11)
        sf.controlSize = .small
        sf.target = self
        sf.action = #selector(filterChanged(_:))
        sf.sendsSearchStringImmediately = true
        if let searchAccessibilityIdentifier {
            sf.setAccessibilityIdentifier(searchAccessibilityIdentifier)
        }
        if let searchAccessibilityLabel {
            sf.setAccessibilityLabel(searchAccessibilityLabel)
        }
        addSubview(sf)
        self.searchField = sf

        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.hasVerticalScroller   = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers    = true
        sv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        sv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(sv)
        self.scrollView = sv

        NSLayoutConstraint.activate([
            sf.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            sf.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            sf.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            sf.heightAnchor.constraint(equalToConstant: 24),
            sv.topAnchor.constraint(equalTo: sf.bottomAnchor, constant: 4),
            sv.leadingAnchor.constraint(equalTo: leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        let tv = NSTableView()
        tv.usesAlternatingRowBackgroundColors = true
        tv.allowsColumnReordering  = true
        tv.allowsColumnResizing    = true
        tv.allowsColumnSelection   = false
        tv.allowsMultipleSelection = true
        tv.rowHeight               = 22
        tv.style                   = .plain
        tv.delegate                = self
        tv.dataSource              = self
        tv.columnAutoresizingStyle = .noColumnAutoresizing
        tv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let tableAccessibilityIdentifier {
            tv.setAccessibilityIdentifier(tableAccessibilityIdentifier)
        }
        if let tableAccessibilityLabel {
            tv.setAccessibilityLabel(tableAccessibilityLabel)
        }
        tv.menu = tableContextMenu
        self.tableView = tv

        addFixedColumns()
        sv.documentView = tv

        metadataColumns.isMultiSampleMode = true
        metadataColumns.standardColumnNames = standardColumnNames
        metadataColumns.install(on: tv)
    }

    private func addFixedColumns() {
        for spec in columnSpecs {
            let col = NSTableColumn(identifier: spec.identifier)
            col.title    = spec.title
            col.width    = spec.width
            col.minWidth = spec.minWidth
            col.sortDescriptorPrototype = NSSortDescriptor(
                key: spec.identifier.rawValue,
                ascending: spec.defaultAscending
            )
            tableView.addTableColumn(col)
        }
    }

    // MARK: - Public API

    /// Replaces the displayed rows and reloads the table.
    ///
    /// The current filter text is re-applied automatically so that existing
    /// filter state is preserved across sample filter changes.
    ///
    /// - Parameter rows: The new rows to display.
    func configure(rows: [Row]) {
        self.unfilteredRows = rows
        applyFilter()
        hideEmptyColumns()
    }

    // MARK: - Empty Column Hiding

    /// Returns `true` if the given column has at least one non-nil / non-empty data value
    /// across all rows in ``unfilteredRows``.
    ///
    /// The default implementation always returns `true` (no columns hidden).
    /// Subclasses override this to hide columns that are never populated for a given tool.
    func columnHasData(_ columnId: NSUserInterfaceItemIdentifier) -> Bool {
        return true
    }

    /// Hook for subclasses that need to react after filtering/sorting replaces ``displayedRows``.
    func didApplyDisplayedRows() {}

    /// Hides fixed (non-metadata) columns that have no data across all rows.
    ///
    /// Called automatically at the end of ``configure(rows:)``. Each non-metadata column
    /// is shown or hidden based on the result of ``columnHasData(_:)``.
    func hideEmptyColumns() {
        for col in tableView.tableColumns {
            guard !MetadataColumnController.isMetadataColumn(col.identifier) else { continue }
            col.isHidden = !columnHasData(col.identifier)
        }
    }

    // MARK: - Filter

    @objc private func filterChanged(_ sender: NSSearchField) {
        filterText = sender.stringValue
        applyFilter()
    }

    private func applyFilter() {
        var filtered: [Row]
        if filterText.isEmpty {
            filtered = unfilteredRows
        } else {
            filtered = unfilteredRows.filter { rowMatchesFilter($0, filterText: filterText) }
        }

        // Apply per-column filters
        for (columnId, filter) in columnFilters where filter.isActive {
            filtered = filtered.filter { row in
                let value = columnValue(for: columnId, row: row)
                // Try numeric match first for numeric columns
                if columnTypeHints[columnId] == true, let num = Double(value) {
                    return filter.matchesNumeric(num)
                }
                // Also try metadata columns
                if columnId.hasPrefix("metadata_"), let sid = sampleId(for: row),
                   let store = metadataColumns.store,
                   let metaValue = store.records[sid]?[String(columnId.dropFirst("metadata_".count))] {
                    if let num = Double(metaValue) {
                        return filter.matchesNumeric(num)
                    }
                    return filter.matchesString(metaValue)
                }
                return filter.matchesString(value)
            }
        }

        // Re-apply current sort order on top of the filtered set.
        if let descriptor = tableView.sortDescriptors.first, let key = descriptor.key {
            let ascending = descriptor.ascending
            self.unsortedRows  = filtered
            self.displayedRows = filtered.sorted { compareRows($0, $1, by: key, ascending: ascending) }
        } else {
            self.unsortedRows  = filtered
            self.displayedRows = filtered
        }
        tableView.reloadData()
        ColumnFilter.updateColumnTitleIndicators(on: tableView, filters: columnFilters, originalTitles: &originalColumnTitles)
        didApplyDisplayedRows()
    }

    /// Returns the current free-text filter query.
    var currentFilterText: String { searchField.stringValue }

    /// Applies a new free-text filter query and refreshes the table.
    func setFilterText(_ text: String) {
        searchField.stringValue = text
        filterText = text
        applyFilter()
    }

    /// Returns the scroll origin of the table view content.
    var currentScrollOriginY: CGFloat { scrollView.contentView.bounds.origin.y }

    /// Restores the table view scroll origin.
    func restoreScrollOriginY(_ originY: CGFloat) {
        layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: originY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Replaces or inserts a column filter and refreshes the table.
    func setColumnFilter(_ filter: ColumnFilter, for columnId: String) {
        columnFilters[columnId] = filter
        applyFilter()
    }

    /// Removes one column filter and refreshes the table.
    func clearColumnFilter(for columnId: String) {
        columnFilters.removeValue(forKey: columnId)
        applyFilter()
    }

    /// Removes every column filter and refreshes the table.
    func clearAllColumnFilters() {
        columnFilters.removeAll()
        applyFilter()
    }

    // MARK: - Cell Factory

    func makeCellView(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let tf = BatchQuickCopyTextField(labelWithString: "")
        tf.pasteboard = cellCopyPasteboard
        tf.copiedValue = { [weak tf] in tf?.stringValue ?? "" }
        tf.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedRows.count
    }

    func tableView(
        _ tableView: NSTableView,
        sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key else {
            displayedRows = unsortedRows
            tableView.reloadData()
            return
        }
        let ascending = descriptor.ascending
        displayedRows = unsortedRows.sorted { compareRows($0, $1, by: key, ascending: ascending) }
        tableView.reloadData()
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        showColumnHeaderFilterMenu(for: tableColumn)
    }

    // MARK: - Column Header Filter Menus

    private func showColumnHeaderFilterMenu(for tableColumn: NSTableColumn) {
        guard let headerView = tableView.headerView,
              let colIndex = tableView.tableColumns.firstIndex(of: tableColumn) else { return }

        let columnId = tableColumn.identifier.rawValue
        let displayName = tableColumn.title.isEmpty ? "Column" : tableColumn.title
        let isNumeric = columnTypeHints[columnId] ?? false

        let menu = NSMenu()

        let sortAscItem = NSMenuItem(title: "Sort Ascending", action: #selector(batchSortColumnAsc(_:)), keyEquivalent: "")
        sortAscItem.target = self
        sortAscItem.representedObject = tableColumn
        menu.addItem(sortAscItem)

        let sortDescItem = NSMenuItem(title: "Sort Descending", action: #selector(batchSortColumnDesc(_:)), keyEquivalent: "")
        sortDescItem.target = self
        sortDescItem.representedObject = tableColumn
        menu.addItem(sortDescItem)

        menu.addItem(NSMenuItem.separator())

        if isNumeric {
            for (label, op) in [
                ("Filter \(displayName) \u{2265}\u{2026}", FilterOperator.greaterOrEqual),
                ("Filter \(displayName) \u{2264}\u{2026}", FilterOperator.lessOrEqual),
                ("Filter \(displayName) =\u{2026}", FilterOperator.equal),
                ("Filter \(displayName) Between\u{2026}", FilterOperator.between),
            ] {
                let item = NSMenuItem(title: label, action: #selector(batchPromptColumnFilter(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["columnId": columnId, "op": op] as [String: Any]
                menu.addItem(item)
            }
        } else {
            for (label, op) in [
                ("Filter \(displayName) Contains\u{2026}", FilterOperator.contains),
                ("Filter \(displayName) Equals\u{2026}", FilterOperator.equal),
                ("Filter \(displayName) Starts With\u{2026}", FilterOperator.startsWith),
            ] {
                let item = NSMenuItem(title: label, action: #selector(batchPromptColumnFilter(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = ["columnId": columnId, "op": op] as [String: Any]
                menu.addItem(item)
            }
        }

        if columnFilters[columnId]?.isActive == true {
            menu.addItem(NSMenuItem.separator())
            let clearItem = NSMenuItem(title: "Clear \(displayName) Filter", action: #selector(batchClearColumnFilter(_:)), keyEquivalent: "")
            clearItem.target = self
            clearItem.representedObject = columnId
            menu.addItem(clearItem)
        }

        if !columnFilters.filter({ $0.value.isActive }).isEmpty {
            let clearAllItem = NSMenuItem(title: "Clear All Filters", action: #selector(batchClearAllColumnFilters(_:)), keyEquivalent: "")
            clearAllItem.target = self
            menu.addItem(clearAllItem)
        }

        let rect = headerView.headerRect(ofColumn: colIndex)
        let anchorPoint = NSPoint(x: rect.minX + 8, y: rect.minY - 2)
        menu.popUp(positioning: nil, at: anchorPoint, in: headerView)
    }

    @objc private func batchPromptColumnFilter(_ sender: NSMenuItem) {
        guard let payload = sender.representedObject as? [String: Any],
              let columnId = payload["columnId"] as? String,
              let op = payload["op"] as? FilterOperator,
              let window = window else { return }

        let alert = NSAlert()
        alert.messageText = "Column Filter"
        let displayName = tableView.tableColumns
            .first { $0.identifier.rawValue == columnId }?.title ?? columnId
        alert.informativeText = "Enter a value for \(displayName) (\(op.rawValue))."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = op == .between ? "min value" : "filter value"

        if op == .between {
            let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 240, height: 52))
            stack.orientation = .vertical
            stack.spacing = 4
            let field2 = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            field2.placeholderString = "max value"
            stack.addArrangedSubview(field)
            stack.addArrangedSubview(field2)
            alert.accessoryView = stack
        } else {
            alert.accessoryView = field
        }

        if let existing = columnFilters[columnId] {
            field.stringValue = existing.value
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }

            var value2: String? = nil
            if op == .between, let stack = alert.accessoryView as? NSStackView,
               let field2 = stack.arrangedSubviews.last as? NSTextField {
                value2 = field2.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            self.setColumnFilter(
                ColumnFilter(columnId: columnId, op: op, value: value, value2: value2),
                for: columnId
            )
        }
    }

    @objc private func batchSortColumnAsc(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? NSTableColumn,
              let proto = column.sortDescriptorPrototype else { return }
        tableView.sortDescriptors = [NSSortDescriptor(key: proto.key, ascending: true, selector: proto.selector)]
    }

    @objc private func batchSortColumnDesc(_ sender: NSMenuItem) {
        guard let column = sender.representedObject as? NSTableColumn,
              let proto = column.sortDescriptorPrototype else { return }
        tableView.sortDescriptors = [NSSortDescriptor(key: proto.key, ascending: false, selector: proto.selector)]
    }

    @objc private func batchClearColumnFilter(_ sender: NSMenuItem) {
        guard let columnId = sender.representedObject as? String else { return }
        clearColumnFilter(for: columnId)
    }

    @objc private func batchClearAllColumnFilters(_ sender: Any?) {
        clearAllColumnFilters()
    }

    // MARK: - NSTableViewDelegate

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let column = tableColumn, row < displayedRows.count else { return nil }

        // Metadata columns handled by the controller.
        if MetadataColumnController.isMetadataColumn(column.identifier) {
            let rowData = displayedRows[row]
            return metadataColumns.cellForColumn(column, sampleId: sampleId(for: rowData) ?? "")
        }

        let rowData = displayedRows[row]
        let id = column.identifier

        let cellView = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? makeCellView(identifier: id)

        let (text, alignment, font) = cellContent(for: id, row: rowData)
        cellView.textField?.stringValue = text
        cellView.textField?.alignment   = alignment
        if let copyField = cellView.textField as? BatchQuickCopyTextField {
            copyField.pasteboard = cellCopyPasteboard
        }
        if let font {
            cellView.textField?.font = font
        }

        return cellView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let selectedIndexes = tableView.selectedRowIndexes
        if selectedIndexes.isEmpty {
            onSelectionCleared?()
            return
        }

        let selected = selectedIndexes.compactMap { idx -> Row? in
            guard idx < displayedRows.count else { return nil }
            return displayedRows[idx]
        }

        if selected.count == 1, let row = selected.first {
            onRowSelected?(row)
        } else if selected.count > 1 {
            onMultipleRowsSelected?(selected)
        }
    }
}

#if DEBUG
extension BatchTableView {
    var testSearchField: NSSearchField { searchField }
    var testTableView: NSTableView { tableView }
}
#endif

// MARK: - Shared Helpers

/// Formats an integer read count as a compact human-readable string.
///
/// - `>= 1 000 000` → `"12.3M"`
/// - `>= 1 000`     → `"4.5K"`
/// - otherwise      → `"123"`
func formatReadCount(_ count: Int) -> String {
    if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
        return String(format: "%.1fK", Double(count) / 1_000)
    }
    return "\(count)"
}
