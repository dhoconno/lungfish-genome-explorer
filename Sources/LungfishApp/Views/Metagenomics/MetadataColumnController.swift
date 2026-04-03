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

    /// The metadata store providing column names and values.
    private(set) var store: SampleMetadataStore?

    /// The current sample ID for value lookups.
    private(set) var currentSampleId: String?

    /// Set of metadata column names currently toggled visible by the user.
    private(set) var visibleColumns: Set<String> = []

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

    /// Standard column names for the header menu (shown as non-toggleable).
    var standardColumnNames: [String] = []

    // MARK: - Installation

    /// Installs the metadata column controller on a table view.
    ///
    /// Sets up the header context menu for column visibility toggling.
    ///
    /// - Parameter table: The NSTableView or NSOutlineView to manage.
    func install(on table: NSTableView) {
        self.tableView = table
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
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(metadataColumnPrefix)\(colName)"))
            col.title = colName
            col.width = 100
            col.minWidth = 50
            col.maxWidth = 300
            col.sortDescriptorPrototype = NSSortDescriptor(
                key: "\(metadataColumnPrefix)\(colName)",
                ascending: true
            )
            tableView.addTableColumn(col)
        }

        tableView.reloadData()
    }

    // MARK: - Header Context Menu

    /// Rebuilds the header context menu with standard and metadata column entries.
    private func rebuildHeaderMenu() {
        guard let tableView else { return }

        let menu = NSMenu(title: "Columns")

        // Standard columns (always shown, not toggleable)
        for name in standardColumnNames {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.state = .on
            item.isEnabled = false
            menu.addItem(item)
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

        let field = NSTextField(labelWithString: value)
        field.font = .systemFont(ofSize: 11)
        field.lineBreakMode = .byTruncatingTail
        if value == "\u{2014}" {
            field.textColor = .tertiaryLabelColor
        }
        return field
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
}
