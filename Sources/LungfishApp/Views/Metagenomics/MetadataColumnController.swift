// MetadataColumnController.swift - Shared helper for dynamic metadata columns in classifier tables
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

/// Prefix used for all metadata column identifiers to distinguish them from standard columns.
private let metadataColumnPrefix = "metadata_"

// MARK: - MetadataColumnController

/// Manages dynamic metadata columns in classifier taxonomy tables.
///
/// `MetadataColumnController` encapsulates the logic for adding, removing, and
/// rendering metadata columns sourced from a ``SampleMetadataStore``. It handles:
///
/// - Column visibility toggling via a header context menu
/// - Dynamic column insertion/removal on NSTableView or NSOutlineView
/// - Cell rendering for metadata values
/// - Export header/value generation for visible metadata columns
///
/// ## Usage
///
/// Each classifier VC creates an instance and connects it to its table:
///
/// ```swift
/// let metadataColumns = MetadataColumnController()
/// metadataColumns.install(on: tableView)
/// metadataColumns.update(store: metadataStore, sampleId: currentSampleId)
/// ```
///
/// In the table delegate's `viewFor` method, check for metadata columns:
///
/// ```swift
/// if let cell = metadataColumns.cellForColumn(column) {
///     return cell
/// }
/// ```
///
/// ## Thread Safety
///
/// This class is `@MainActor` isolated.
@MainActor
final class MetadataColumnController {

    // MARK: - Properties

    private static let zeroWidthDisableThreshold: CGFloat = 0.5

    /// The metadata store providing column names and values.
    private(set) var store: SampleMetadataStore?

    /// The current sample ID for value lookups.
    private(set) var currentSampleId: String?

    /// Set of metadata column names currently toggled visible by the user.
    var visibleColumns: Set<String> = []

    /// Whether multiple samples are currently being viewed.
    ///
    /// Metadata columns are always available regardless of this flag.
    /// In multi-sample mode each row shows the metadata value for its
    /// respective sample (via ``cellForColumn(_:sampleId:)``).
    var isMultiSampleMode: Bool = false {
        didSet {
            if isMultiSampleMode != oldValue {
                rebuildHeaderMenu()
            }
        }
    }

    /// The table view (NSTableView or NSOutlineView) this controller manages columns on.
    private weak var tableView: NSTableView?

    /// Default widths captured at installation or column creation for restoring disabled columns.
    private var defaultColumnWidths: [String: CGFloat] = [:]

    /// Observer token for zero-width column resize detection.
    private nonisolated(unsafe) var columnResizeObserver: NSObjectProtocol?

    /// Avoids recursive resize/visibility handling while applying manager changes.
    private var isApplyingColumnVisibility = false

    /// Standard column names for the header menu (shown as non-toggleable).
    var standardColumnNames: [String] = []

    deinit {
        if let columnResizeObserver {
            NotificationCenter.default.removeObserver(columnResizeObserver)
        }
    }

    // MARK: - Installation

    /// Installs the metadata column controller on a table view.
    ///
    /// Sets up the header context menu for column visibility toggling.
    ///
    /// - Parameter table: The NSTableView or NSOutlineView to manage.
    func install(on table: NSTableView) {
        self.tableView = table
        configureFlexibleTable(table)
        captureAndRelaxExistingColumns(on: table)
        installResizeObserver(on: table)
        rebuildHeaderMenu()
    }

    // MARK: - Update

    /// Updates the metadata store and current sample ID.
    ///
    /// Call this when the metadata store is first available (after loading from
    /// the bundle) and whenever the selected sample changes.
    ///
    /// - Parameters:
    ///   - store: The metadata store, or nil if no metadata has been imported.
    ///   - sampleId: The current sample ID for value lookups.
    func update(store: SampleMetadataStore?, sampleId: String?) {
        self.store = store
        self.currentSampleId = sampleId
        rebuildHeaderMenu()
        refreshColumns()
    }

    /// Updates just the current sample ID without changing the store.
    ///
    /// Call this when the user switches samples in a multi-sample classifier.
    ///
    /// - Parameter sampleId: The new sample ID.
    func updateSampleId(_ sampleId: String?) {
        self.currentSampleId = sampleId
        tableView?.reloadData()
    }

    // MARK: - Column Management

    /// Refreshes the dynamic columns on the table view based on current visibility state.
    private func refreshColumns() {
        guard let tableView else { return }

        // Remove all existing metadata columns
        let existingMetaCols = tableView.tableColumns.filter {
            $0.identifier.rawValue.hasPrefix(metadataColumnPrefix)
        }
        for col in existingMetaCols {
            tableView.removeTableColumn(col)
        }

        // Only need a store to add metadata columns
        guard let store else { return }

        // Add visible metadata columns in the order they appear in the store
        for colName in store.columnNames where visibleColumns.contains(colName) {
            let identifier = "\(metadataColumnPrefix)\(colName)"
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            col.title = colName
            col.width = defaultColumnWidths[identifier] ?? 100
            configureFlexibleColumn(col)
            col.sortDescriptorPrototype = NSSortDescriptor(
                key: identifier,
                ascending: true
            )
            tableView.addTableColumn(col)
        }

        tableView.reloadData()
        rebuildHeaderMenu()
    }

    // MARK: - Flexible Resizing

    private func configureFlexibleTable(_ table: NSTableView) {
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.enclosingScrollView?.hasHorizontalScroller = true
        if table.headerView == nil {
            table.headerView = NSTableHeaderView()
        }
    }

    private func captureAndRelaxExistingColumns(on table: NSTableView) {
        for column in table.tableColumns {
            rememberDefaultWidth(for: column)
            configureFlexibleColumn(column)
        }
    }

    private func configureFlexibleColumn(_ column: NSTableColumn) {
        rememberDefaultWidth(for: column)
        column.minWidth = 0
        column.maxWidth = CGFloat.greatestFiniteMagnitude
    }

    private func rememberDefaultWidth(for column: NSTableColumn) {
        let id = column.identifier.rawValue
        guard defaultColumnWidths[id] == nil else { return }
        let fallback = MetadataColumnController.isMetadataColumn(column.identifier) ? 100.0 : 80.0
        let width = column.width > Self.zeroWidthDisableThreshold ? column.width : fallback
        defaultColumnWidths[id] = width
    }

    private func installResizeObserver(on table: NSTableView) {
        if let columnResizeObserver {
            NotificationCenter.default.removeObserver(columnResizeObserver)
        }
        columnResizeObserver = NotificationCenter.default.addObserver(
            forName: NSTableView.columnDidResizeNotification,
            object: table,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncDisabledColumnsFromWidths()
            }
        }
    }

    private func syncDisabledColumnsFromWidths() {
        guard let tableView, !isApplyingColumnVisibility else { return }

        var metadataChanged = false
        for column in tableView.tableColumns where column.width <= Self.zeroWidthDisableThreshold && !column.isHidden {
            rememberDefaultWidth(for: column)
            if Self.isMetadataColumn(column.identifier) {
                let colName = String(column.identifier.rawValue.dropFirst(metadataColumnPrefix.count))
                if visibleColumns.remove(colName) != nil {
                    metadataChanged = true
                }
            } else {
                column.isHidden = true
            }
        }

        if metadataChanged {
            refreshColumns()
        } else {
            rebuildHeaderMenu()
        }
    }

    private func setStandardColumnVisible(id: String, visible: Bool) {
        guard let tableView,
              let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == id }) else { return }

        isApplyingColumnVisibility = true
        rememberDefaultWidth(for: column)
        configureFlexibleColumn(column)
        if visible {
            column.isHidden = false
            if column.width <= Self.zeroWidthDisableThreshold {
                column.width = defaultColumnWidths[id] ?? 80
            }
        } else {
            column.isHidden = true
        }
        isApplyingColumnVisibility = false
        rebuildHeaderMenu()
        tableView.reloadData()
    }

    // MARK: - Header Context Menu

    /// Rebuilds the header context menu with standard and metadata column entries.
    private func rebuildHeaderMenu() {
        guard let tableView else { return }

        let menu = NSMenu(title: "Columns")

        // Standard columns
        let standardColumns = tableView.tableColumns.filter { !Self.isMetadataColumn($0.identifier) }
        if !standardColumns.isEmpty {
            let header = NSMenuItem(title: "Standard Columns", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
        }

        for column in standardColumns {
            let title = column.title.isEmpty ? column.identifier.rawValue : column.title
            let item = NSMenuItem(
                title: title,
                action: #selector(toggleStandardColumn(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = column.identifier.rawValue
            item.state = column.isHidden ? .off : .on
            menu.addItem(item)
        }

        if !standardColumns.isEmpty {
            menu.addItem(.separator())
            let resetItem = NSMenuItem(
                title: "Reset Column Widths",
                action: #selector(resetStandardColumnWidths(_:)),
                keyEquivalent: ""
            )
            resetItem.target = self
            menu.addItem(resetItem)
        }

        // Metadata columns section
        if let store, !store.columnNames.isEmpty {
            menu.addItem(.separator())

            let header = NSMenuItem(title: "Sample Metadata", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)

            for colName in store.columnNames {
                let item = NSMenuItem(
                    title: colName,
                    action: #selector(toggleMetadataColumn(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = colName
                item.state = visibleColumns.contains(colName) ? .on : .off
                menu.addItem(item)
            }
        }

        tableView.headerView?.menu = menu
    }

    @objc private func toggleStandardColumn(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        let isVisible = sender.state == .on
        setStandardColumnVisible(id: id, visible: !isVisible)
    }

    @objc private func resetStandardColumnWidths(_ sender: Any?) {
        guard let tableView else { return }
        isApplyingColumnVisibility = true
        for column in tableView.tableColumns where !Self.isMetadataColumn(column.identifier) {
            let id = column.identifier.rawValue
            column.isHidden = false
            column.width = defaultColumnWidths[id] ?? max(80, column.width)
            configureFlexibleColumn(column)
        }
        isApplyingColumnVisibility = false
        rebuildHeaderMenu()
        tableView.reloadData()
    }

    @objc private func toggleMetadataColumn(_ sender: NSMenuItem) {
        guard let colName = sender.representedObject as? String else { return }
        if visibleColumns.contains(colName) {
            visibleColumns.remove(colName)
        } else {
            visibleColumns.insert(colName)
        }
        rebuildHeaderMenu()
        refreshColumns()
    }

    // MARK: - Cell Rendering

    /// Returns true if the given column identifier is a metadata column.
    static func isMetadataColumn(_ identifier: NSUserInterfaceItemIdentifier) -> Bool {
        identifier.rawValue.hasPrefix(metadataColumnPrefix)
    }

    /// Returns a cell view for a metadata column, or nil if the column is not a metadata column.
    ///
    /// Call this from `tableView(_:viewFor:row:)` or `outlineView(_:viewFor:item:)`.
    ///
    /// - Parameter column: The table column to check.
    /// - Returns: A configured NSTextField cell, or nil if not a metadata column.
    func cellForColumn(_ column: NSTableColumn) -> NSView? {
        return cellForColumn(column, sampleId: currentSampleId)
    }

    /// Returns a cell view for a metadata column using a specific sample ID.
    ///
    /// In multi-sample mode, callers should pass the row's sample ID so each
    /// row displays the correct metadata value for its respective sample.
    ///
    /// - Parameters:
    ///   - column: The table column to check.
    ///   - sampleId: The sample ID to look up metadata for.
    /// - Returns: A configured NSTextField cell, or nil if not a metadata column.
    func cellForColumn(_ column: NSTableColumn, sampleId: String?) -> NSView? {
        let rawID = column.identifier.rawValue
        guard rawID.hasPrefix(metadataColumnPrefix) else { return nil }

        let metaColName = String(rawID.dropFirst(metadataColumnPrefix.count))
        let value: String
        if let sampleId,
           let record = store?.records[sampleId],
           let val = record[metaColName] {
            value = val
        } else {
            value = "\u{2014}" // em dash for missing
        }

        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: 11)
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        if value == "\u{2014}" {
            field.textColor = .tertiaryLabelColor
        }
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    // MARK: - Export Support

    /// Returns the header names for visible metadata columns (in store order).
    var exportHeaders: [String] {
        guard let store else { return [] }
        return store.columnNames.filter { visibleColumns.contains($0) }
    }

    /// Returns the values for visible metadata columns for the current sample.
    var exportValues: [String] {
        guard let store, let sampleId = currentSampleId else { return [] }
        return store.columnNames.compactMap { colName in
            guard visibleColumns.contains(colName) else { return nil }
            return store.records[sampleId]?[colName] ?? ""
        }
    }

    /// Returns the values for visible metadata columns for a specific sample ID.
    ///
    /// Use this when exporting rows that may reference different samples.
    ///
    /// - Parameter sampleId: The sample ID to look up values for.
    /// - Returns: Array of metadata values in the same order as ``exportHeaders``.
    func exportValues(for sampleId: String) -> [String] {
        guard let store else { return [] }
        return store.columnNames.compactMap { colName in
            guard visibleColumns.contains(colName) else { return nil }
            return store.records[sampleId]?[colName] ?? ""
        }
    }

    /// Returns whether any metadata columns are currently visible.
    var hasVisibleColumns: Bool {
        !visibleColumns.isEmpty && store != nil
    }

    // MARK: - Testing Hooks

    func testingSyncDisabledColumnsFromWidths() {
        syncDisabledColumnsFromWidths()
    }

    func testingSetStandardColumnVisible(id: String, visible: Bool) {
        setStandardColumnVisible(id: id, visible: visible)
    }
}
