// MetadataColumnController.swift - Shared helper for dynamic metadata columns in classifier tables
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore

/// Prefix used for all metadata column identifiers to distinguish them from standard columns.
private let metadataColumnPrefix = "metadata_"

@MainActor
private final class MetadataContentTextField:
    NSTextField,
    ContentTypographySemanticFontProviding
{
    let contentTypographyRole = ContentTypography.Role.body
}

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
public final class MetadataColumnController {
    public enum ContentTypographyOwnership {
        case standalone
        case embedded
    }

    // MARK: - Properties

    public init(
        contentTypographyOwnership: ContentTypographyOwnership = .standalone,
        userDefaults: UserDefaults = .standard
    ) {
        self.contentTypographyOwnership = contentTypographyOwnership
        self.userDefaults = userDefaults
        if contentTypographyOwnership == .standalone {
            let notifications = NotificationCenterContentTypographyNotifications(
                notificationCenter: .default
            )
            contentTypographyObservation = notifications.observe(
                .contentTextSizeDidChange
            ) { [weak self] in
                self?.applyContentTypography()
            }
        }
    }

    private static let zeroWidthDisableThreshold: CGFloat = 0.5
    private static let metadataCellTextFieldTag = 51_001
    private static let persistencePrefix = "org.lungfish.metadata-column-layout."

    private struct PersistedLayout: Codable {
        let version: Int
        let visibleMetadata: [String]
        let columnOrder: [String]
        let metadataWidths: [String: CGFloat]
    }

    /// The metadata store providing column names and values.
    public private(set) var store: SampleMetadataStore?

    /// The current sample ID for value lookups.
    public private(set) var currentSampleId: String?

    /// Set of metadata column names currently toggled visible by the user.
    public var visibleColumns: Set<String> = []

    /// Called after the installed metadata columns or backing store change.
    /// Owners use this to refresh search scopes and their existing row pipeline.
    public var onColumnsOrStoreChanged: (() -> Void)?

    /// Metadata columns actually displayed by the installed table, in display order.
    public var displayedMetadataColumns: [(id: String, title: String)] {
        guard let tableView else { return [] }
        return tableView.tableColumns.compactMap { column in
            guard Self.isMetadataColumn(column.identifier), !column.isHidden else { return nil }
            return (column.identifier.rawValue, column.title)
        }
    }

    /// An optional stable result-and-table-role key used to remember the user's
    /// metadata selection and table column order. A nil key retains the
    /// controller's previous in-memory-only behavior.
    public var persistenceKey: String? {
        didSet {
            guard persistenceKey != oldValue else { return }
            if oldValue != nil {
                persistLayout(for: oldValue)
            }
            restoreLayoutForCurrentKey()
        }
    }

    /// Whether multiple samples are currently being viewed.
    ///
    /// Metadata columns are always available regardless of this flag.
    /// In multi-sample mode each row shows the metadata value for its
    /// respective sample (via ``cellForColumn(_:sampleId:)``).
    public var isMultiSampleMode: Bool = false {
        didSet {
            if isMultiSampleMode != oldValue {
                rebuildHeaderMenu()
            }
        }
    }

    /// The table view (NSTableView or NSOutlineView) this controller manages columns on.
    private weak var tableView: NSTableView?
    private let userDefaults: UserDefaults
    private var persistedLayout: PersistedLayout?
    private var defaultStandardColumnOrder: [String] = []

    /// Default widths captured at installation or column creation for restoring disabled columns.
    private var defaultColumnWidths: [String: CGFloat] = [:]

    /// Observer token for zero-width column resize detection.
    private nonisolated(unsafe) var columnResizeObserver: NSObjectProtocol?
    private nonisolated(unsafe) var columnMoveObserver: NSObjectProtocol?
    private nonisolated(unsafe) var outlineColumnResizeObserver: NSObjectProtocol?
    private nonisolated(unsafe) var outlineColumnMoveObserver: NSObjectProtocol?

    /// Live content-size preference observation.
    private var contentTypographyObservation: ContentTypographyNotificationObservation?
    private let contentTypographyOwnership: ContentTypographyOwnership

    /// Avoids recursive resize/visibility handling while applying manager changes.
    private var isApplyingColumnVisibility = false
    private var isEmittingColumnsOrStoreChanged = false

    /// Standard column names for the header menu (shown as non-toggleable).
    public var standardColumnNames: [String] = []

    deinit {
        if let columnResizeObserver {
            NotificationCenter.default.removeObserver(columnResizeObserver)
        }
        if let columnMoveObserver {
            NotificationCenter.default.removeObserver(columnMoveObserver)
        }
        if let outlineColumnResizeObserver {
            NotificationCenter.default.removeObserver(outlineColumnResizeObserver)
        }
        if let outlineColumnMoveObserver {
            NotificationCenter.default.removeObserver(outlineColumnMoveObserver)
        }
    }

    // MARK: - Installation

    /// Installs the metadata column controller on a table view.
    ///
    /// Sets up the header context menu for column visibility toggling.
    ///
    /// - Parameter table: The NSTableView or NSOutlineView to manage.
    public func install(on table: NSTableView) {
        self.tableView = table
        defaultStandardColumnOrder = table.tableColumns.compactMap { column in
            Self.isMetadataColumn(column.identifier) ? nil : column.identifier.rawValue
        }
        configureFlexibleTable(table)
        captureAndRelaxExistingColumns(on: table)
        installColumnObservers(on: table)
        applyPersistedColumnOrder()
        rebuildHeaderMenu()
        applyContentTypography()
    }

    /// Applies semantic metadata-cell and header typography without recreating
    /// the owning controller.
    public func applyContentTypography() {
        guard let tableView else { return }
        let typography = ContentTypography.current()
        if contentTypographyOwnership == .standalone {
            tableView.rowHeight = typography.tableRowHeight()
            if let headerView = tableView.headerView {
                var frame = headerView.frame
                frame.size.height = typography.tableHeaderHeight()
                headerView.frame = frame
            }
            tableView.enclosingScrollView?.tile()
        }
        for column in tableView.tableColumns where Self.isMetadataColumn(column.identifier) {
            column.headerCell.font = typography.font(for: .tableHeader)
        }
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.location != NSNotFound else { return }
        for row in visibleRows.location..<min(
            NSMaxRange(visibleRows),
            tableView.numberOfRows
        ) {
            for (columnIndex, column) in tableView.tableColumns.enumerated()
            where Self.isMetadataColumn(column.identifier) && !column.isHidden {
                let cell = tableView.view(
                    atColumn: columnIndex,
                    row: row,
                    makeIfNecessary: false
                ) as? NSTableCellView
                cell?.textField?.font = typography.font(for: .body)
            }
        }
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
    public func update(store: SampleMetadataStore?, sampleId: String?) {
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
    public func updateSampleId(_ sampleId: String?) {
        self.currentSampleId = sampleId
        reloadVisibleMetadataColumns()
    }

    /// Re-registers standard columns that were replaced after installation.
    ///
    /// Dynamic table subclasses should call this after rebuilding their non-metadata
    /// columns so late columns receive flexible sizing and appear in the header chooser.
    public func refreshAfterStandardColumnsChanged() {
        guard let tableView else { return }
        configureFlexibleTable(tableView)
        captureAndRelaxExistingColumns(on: tableView)
        if store != nil {
            // Reinsert metadata columns after the rebuilt standard columns.
            refreshColumns()
        } else {
            rebuildHeaderMenu()
        }
    }

    // MARK: - Column Management

    /// Refreshes the dynamic columns on the table view based on current visibility state.
    private func refreshColumns() {
        guard let tableView else { return }

        let wasApplyingColumnVisibility = isApplyingColumnVisibility
        isApplyingColumnVisibility = true
        defer {
            isApplyingColumnVisibility = wasApplyingColumnVisibility
            if !wasApplyingColumnVisibility {
                persistLayout()
                emitColumnsOrStoreChanged()
            }
        }

        let availableColumns = Set(store?.columnNames ?? [])
        let unwantedMetadataColumns = tableView.tableColumns.filter { column in
            guard Self.isMetadataColumn(column.identifier) else { return false }
            let name = String(column.identifier.rawValue.dropFirst(metadataColumnPrefix.count))
            return !availableColumns.contains(name) || !visibleColumns.contains(name)
        }
        for col in unwantedMetadataColumns {
            tableView.removeTableColumn(col)
        }

        guard let store else { return }

        for colName in store.columnNames where visibleColumns.contains(colName) {
            let identifier = "\(metadataColumnPrefix)\(colName)"
            guard tableView.tableColumns.allSatisfy({ $0.identifier.rawValue != identifier }) else {
                continue
            }
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            col.title = colName
            col.headerToolTip = Self.metadataHeaderToolTip(for: colName)
            col.width = persistedLayout?.metadataWidths[identifier]
                ?? defaultColumnWidths[identifier]
                ?? 100
            configureFlexibleColumn(col)
            col.sortDescriptorPrototype = NSSortDescriptor(
                key: identifier,
                ascending: true
            )
            tableView.addTableColumn(col)
        }

        applyPersistedColumnOrder()
        tableView.reloadData()
        rebuildHeaderMenu()
        applyContentTypography()
    }

    // MARK: - Layout Persistence

    private func persistenceDefaultsKey(for key: String) -> String {
        Self.persistencePrefix + key
    }

    private func restoreLayoutForCurrentKey() {
        guard let persistenceKey else {
            persistedLayout = nil
            applyPersistedLayout()
            return
        }

        let defaultsKey = persistenceDefaultsKey(for: persistenceKey)
        if let data = userDefaults.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(PersistedLayout.self, from: data),
           decoded.version == 1 {
            persistedLayout = decoded
        } else {
            persistedLayout = nil
        }
        applyPersistedLayout()
    }

    private func applyPersistedLayout() {
        let wasApplyingColumnVisibility = isApplyingColumnVisibility
        isApplyingColumnVisibility = true
        visibleColumns = Set(persistedLayout?.visibleMetadata ?? [])
        refreshColumns()
        if persistedLayout == nil {
            applyDefaultStandardColumnOrder()
        } else {
            applyPersistedColumnOrder()
        }
        isApplyingColumnVisibility = wasApplyingColumnVisibility
        rebuildHeaderMenu()
        if !wasApplyingColumnVisibility {
            emitColumnsOrStoreChanged()
        }
    }

    private func emitColumnsOrStoreChanged() {
        guard !isApplyingColumnVisibility, !isEmittingColumnsOrStoreChanged else { return }
        isEmittingColumnsOrStoreChanged = true
        onColumnsOrStoreChanged?()
        isEmittingColumnsOrStoreChanged = false
    }

    private func applyDefaultStandardColumnOrder() {
        guard let tableView else { return }
        for (destination, identifier) in defaultStandardColumnOrder.enumerated() {
            guard let currentIndex = tableView.tableColumns.firstIndex(where: {
                $0.identifier.rawValue == identifier
            }), currentIndex != destination else { continue }
            tableView.moveColumn(currentIndex, toColumn: destination)
        }
    }

    private func applyPersistedColumnOrder() {
        guard let tableView, let persistedLayout else { return }
        let currentIDs = tableView.tableColumns.map { $0.identifier.rawValue }
        let savedIDs = persistedLayout.columnOrder.filter { currentIDs.contains($0) }
        let desiredIDs = savedIDs + currentIDs.filter { !savedIDs.contains($0) }
        for (destination, identifier) in desiredIDs.enumerated() {
            let currentIndex = tableView.tableColumns.firstIndex {
                $0.identifier.rawValue == identifier
            }
            if let currentIndex, currentIndex != destination {
                tableView.moveColumn(currentIndex, toColumn: destination)
            }
        }
    }

    private func persistLayout(for key: String? = nil) {
        guard !isApplyingColumnVisibility,
              let storageKey = key ?? persistenceKey,
              let tableView else { return }

        let currentOrder = tableView.tableColumns.map { $0.identifier.rawValue }
        let currentWidths: [String: CGFloat] = Dictionary(
            uniqueKeysWithValues: tableView.tableColumns.compactMap { column in
                guard Self.isMetadataColumn(column.identifier) else { return nil }
                return (column.identifier.rawValue, column.width)
            }
        )
        let needsMerge = hasTemporarilyUnavailableSavedMetadata
        let previousLayout = persistedLayout

        let layout = PersistedLayout(
            version: 1,
            visibleMetadata: visibleColumns.sorted(),
            columnOrder: needsMerge
                ? mergedColumnOrder(currentOrder, preservingUnavailableFrom: previousLayout)
                : currentOrder,
            metadataWidths: needsMerge
                ? mergedMetadataWidths(currentWidths, preservingUnavailableFrom: previousLayout)
                : currentWidths
        )
        guard let data = try? JSONEncoder().encode(layout) else { return }
        userDefaults.set(data, forKey: persistenceDefaultsKey(for: storageKey))
        if storageKey == persistenceKey {
            persistedLayout = layout
        }
    }

    private func mergedColumnOrder(
        _ currentOrder: [String],
        preservingUnavailableFrom previousLayout: PersistedLayout?
    ) -> [String] {
        guard let previousLayout else { return currentOrder }
        let oldIDs = Set(previousLayout.columnOrder)
        let currentIDs = Set(currentOrder)
        var currentIDsKnownToPrevious = currentOrder.filter { oldIDs.contains($0) }.makeIterator()
        var merged = previousLayout.columnOrder.map { identifier in
            currentIDs.contains(identifier) ? currentIDsKnownToPrevious.next()! : identifier
        }
        merged.append(contentsOf: currentOrder.filter { !oldIDs.contains($0) })
        return merged
    }

    private func mergedMetadataWidths(
        _ currentWidths: [String: CGFloat],
        preservingUnavailableFrom previousLayout: PersistedLayout?
    ) -> [String: CGFloat] {
        guard let previousLayout else { return currentWidths }
        return previousLayout.metadataWidths.merging(currentWidths) { _, current in current }
    }

    private var hasTemporarilyUnavailableSavedMetadata: Bool {
        guard let store else { return !visibleColumns.isEmpty }
        return !visibleColumns.isSubset(of: Set(store.columnNames))
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

    private static func metadataHeaderToolTip(for columnName: String) -> String {
        "Sample metadata: \(columnName)"
    }

    private func rememberDefaultWidth(for column: NSTableColumn) {
        let id = column.identifier.rawValue
        guard defaultColumnWidths[id] == nil else { return }
        let fallback = MetadataColumnController.isMetadataColumn(column.identifier) ? 100.0 : 80.0
        let width = column.width > Self.zeroWidthDisableThreshold ? column.width : fallback
        defaultColumnWidths[id] = width
    }

    private func installColumnObservers(on table: NSTableView) {
        if let columnResizeObserver {
            NotificationCenter.default.removeObserver(columnResizeObserver)
        }
        if let columnMoveObserver {
            NotificationCenter.default.removeObserver(columnMoveObserver)
        }
        if let outlineColumnResizeObserver {
            NotificationCenter.default.removeObserver(outlineColumnResizeObserver)
        }
        if let outlineColumnMoveObserver {
            NotificationCenter.default.removeObserver(outlineColumnMoveObserver)
        }
        columnResizeObserver = NotificationCenter.default.addObserver(
            forName: NSTableView.columnDidResizeNotification,
            object: table,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.syncDisabledColumnsFromWidths()
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.syncDisabledColumnsFromWidths()
                    }
                }
            }
        }
        columnMoveObserver = NotificationCenter.default.addObserver(
            forName: NSTableView.columnDidMoveNotification,
            object: table,
            queue: nil
        ) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.persistLayout()
                    self?.emitColumnsOrStoreChanged()
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        self?.persistLayout()
                        self?.emitColumnsOrStoreChanged()
                    }
                }
            }
        }
        if let outlineView = table as? NSOutlineView {
            outlineColumnResizeObserver = NotificationCenter.default.addObserver(
                forName: NSOutlineView.columnDidResizeNotification,
                object: outlineView,
                queue: nil
            ) { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self?.syncDisabledColumnsFromWidths()
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.syncDisabledColumnsFromWidths()
                        }
                    }
                }
            }
            outlineColumnMoveObserver = NotificationCenter.default.addObserver(
                forName: NSOutlineView.columnDidMoveNotification,
                object: outlineView,
                queue: nil
            ) { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        self?.persistLayout()
                        self?.emitColumnsOrStoreChanged()
                    }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        MainActor.assumeIsolated {
                            self?.persistLayout()
                            self?.emitColumnsOrStoreChanged()
                        }
                    }
                }
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
            persistLayout()
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
    public static func isMetadataColumn(_ identifier: NSUserInterfaceItemIdentifier) -> Bool {
        identifier.rawValue.hasPrefix(metadataColumnPrefix)
    }

    /// Returns the exact metadata value for a column/sample pair.
    /// A nil sample falls back to the controller's current sample.
    public func value(columnID: String, sampleID: String?) -> String? {
        guard columnID.hasPrefix(metadataColumnPrefix), let store else { return nil }
        let columnName = String(columnID.dropFirst(metadataColumnPrefix.count))
        guard store.columnNames.contains(columnName),
              let resolvedSampleID = sampleID ?? currentSampleId else { return nil }
        return store.records[resolvedSampleID]?[columnName]
    }

    /// Compares two sample values for a metadata column using one natural text ordering.
    /// Returns nil when `columnID` is not an installed metadata-store key.
    public func comparison(
        columnID: String,
        lhsSampleID: String?,
        rhsSampleID: String?
    ) -> ComparisonResult? {
        guard columnID.hasPrefix(metadataColumnPrefix), let store else { return nil }
        let columnName = String(columnID.dropFirst(metadataColumnPrefix.count))
        guard store.columnNames.contains(columnName) else { return nil }
        let lhs = value(columnID: columnID, sampleID: lhsSampleID) ?? ""
        let rhs = value(columnID: columnID, sampleID: rhsSampleID) ?? ""
        return lhs.compare(rhs, options: [.caseInsensitive, .numeric])
    }

    /// Returns a cell view for a metadata column, or nil if the column is not a metadata column.
    ///
    /// Call this from `tableView(_:viewFor:row:)` or `outlineView(_:viewFor:item:)`.
    ///
    /// - Parameter column: The table column to check.
    /// - Returns: A configured NSTextField cell, or nil if not a metadata column.
    public func cellForColumn(_ column: NSTableColumn) -> NSView? {
        cellForColumn(column, sampleId: currentSampleId)
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
    public func cellForColumn(_ column: NSTableColumn, sampleId: String?) -> NSView? {
        guard let value = metadataValue(for: column, sampleId: sampleId) else { return nil }
        let cell = makeMetadataCell(identifier: metadataCellIdentifier(for: column))
        configureMetadataCell(cell, value: value)
        return cell
    }

    /// Returns a reusable cell view for a metadata column using a specific sample ID.
    ///
    /// Hot table/outline delegates should call this overload so AppKit can recycle
    /// metadata cells while scrolling through large result tables.
    public func cellForColumn(_ column: NSTableColumn, in tableView: NSTableView, sampleId: String?) -> NSView? {
        guard let value = metadataValue(for: column, sampleId: sampleId) else { return nil }
        let identifier = metadataCellIdentifier(for: column)
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView
            ?? makeMetadataCell(identifier: identifier)
        configureMetadataCell(cell, value: value)
        return cell
    }

    private func metadataValue(for column: NSTableColumn, sampleId: String?) -> String? {
        let rawID = column.identifier.rawValue
        guard rawID.hasPrefix(metadataColumnPrefix) else { return nil }
        return value(columnID: rawID, sampleID: sampleId) ?? "\u{2014}"
    }

    private func metadataCellIdentifier(for column: NSTableColumn) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("metadata-cell-\(column.identifier.rawValue)")
    }

    private func makeMetadataCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let field = MetadataContentTextField(labelWithString: "")
        field.tag = Self.metadataCellTextFieldTag
        let typography = ContentTypography.current()
        field.font = typography.font(for: .body)
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    private func configureMetadataCell(_ cell: NSTableCellView, value: String) {
        let field = cell.textField ?? cell.viewWithTag(Self.metadataCellTextFieldTag) as? NSTextField
        field?.stringValue = value
        let typography = ContentTypography.current()
        field?.font = typography.font(for: .body)
        field?.lineBreakMode = .byTruncatingTail
        field?.textColor = value == "\u{2014}" ? .tertiaryLabelColor : .labelColor
        field?.toolTip = value == "\u{2014}" ? nil : value
        cell.toolTip = field?.toolTip
    }

    private func reloadVisibleMetadataColumns() {
        guard let tableView else { return }
        let metadataColumnIndexes = tableView.tableColumns.enumerated().compactMap { index, column in
            Self.isMetadataColumn(column.identifier) && !column.isHidden ? index : nil
        }
        guard !metadataColumnIndexes.isEmpty else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(integersIn: 0..<tableView.numberOfRows),
            columnIndexes: IndexSet(metadataColumnIndexes)
        )
    }

    // MARK: - Export Support

    /// Returns the header names for visible metadata columns (in store order).
    public var exportHeaders: [String] {
        guard let store else { return [] }
        return store.columnNames.filter { visibleColumns.contains($0) }
    }

    /// Returns the values for visible metadata columns for the current sample.
    public var exportValues: [String] {
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
    public func exportValues(for sampleId: String) -> [String] {
        guard let store else { return [] }
        return store.columnNames.compactMap { colName in
            guard visibleColumns.contains(colName) else { return nil }
            return store.records[sampleId]?[colName] ?? ""
        }
    }

    /// Returns whether any metadata columns are currently visible.
    public var hasVisibleColumns: Bool {
        !visibleColumns.isEmpty && store != nil
    }

    // MARK: - Testing Hooks

    public func testingSyncDisabledColumnsFromWidths() {
        syncDisabledColumnsFromWidths()
    }

    public func testingSetStandardColumnVisible(id: String, visible: Bool) {
        setStandardColumnVisible(id: id, visible: visible)
    }
}
