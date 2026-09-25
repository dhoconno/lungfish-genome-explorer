// BatchTableView.swift - Generic base class for batch aggregated classifier table views
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishCore
import os.log

// MARK: - BatchColumnSpec

/// Fixed `NSView.tag` used to locate the optional dimmed secondary text
/// field on a reused cell view, since `NSTableCellView` only exposes a
/// `textField` slot for the primary line.
private let batchSecondaryTextFieldTag = 9081

/// Column specification for a batch table.
///
/// Each entry describes one fixed column in a ``BatchTableView`` subclass.
public struct BatchColumnSpec {
    /// The column's unique identifier (used as the sort-descriptor key too).
    public let identifier: NSUserInterfaceItemIdentifier
    /// The header title string.
    public let title: String
    /// Default column width.
    public let width: CGFloat
    /// Minimum column width enforced by the table.
    public let minWidth: CGFloat
    /// Whether the column sorts ascending by default (`true`) or descending (`false`).
    public let defaultAscending: Bool
    /// Optional header tooltip describing units and interpretation.
    public let toolTip: String?

    public init(
        identifier: NSUserInterfaceItemIdentifier,
        title: String,
        width: CGFloat,
        minWidth: CGFloat,
        defaultAscending: Bool,
        toolTip: String? = nil
    ) {
        self.identifier = identifier
        self.title = title
        self.width = width
        self.minWidth = minWidth
        self.defaultAscending = defaultAscending
        self.toolTip = toolTip
    }
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
open class BatchTableView<Row>: NSView, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation, ColumnFilterMenuHost {

    /// Shared column-header sort/filter menu, lazily created once the view
    /// (and thus `tableView`/`window`) exists.
    private lazy var columnHeaderFilterMenuController = ColumnHeaderFilterMenu(host: self)

    // MARK: - Subclass Hooks

    /// Fixed column specifications. Subclasses must override this.
    open var columnSpecs: [BatchColumnSpec] { [] }

    /// Placeholder string for the search field. Defaults to `"Filter…"`.
    open var searchPlaceholder: String { "Filter\u{2026}" }

    /// Optional accessibility identifier for the search field.
    open var searchAccessibilityIdentifier: String? { nil }

    /// Optional accessibility label for the search field.
    open var searchAccessibilityLabel: String? { nil }

    /// Optional accessibility identifier for the table view.
    open var tableAccessibilityIdentifier: String? { nil }

    /// Optional accessibility label for the table view.
    open var tableAccessibilityLabel: String? { nil }

    /// Optional pasteboard used for command-click scalar copy in visible cells.
    open var cellCopyPasteboard: PasteboardWriting? { nil }

    /// The list of standard (non-metadata) column titles registered with
    /// ``metadataColumns``. Defaults to the ``columnSpecs`` titles.
    open var standardColumnNames: [String] { columnSpecs.map(\.title) }

    /// Returns the text, alignment, and optional font override for a cell.
    ///
    /// Subclasses override this to provide tool-specific rendering.
    /// When `font` is `nil`, the cell keeps the default font set by ``makeCellView(identifier:)``.
    /// The default implementation returns an empty string with left alignment and no font override.
    open func cellContent(
        for column: NSUserInterfaceItemIdentifier,
        row: Row
    ) -> (text: String, alignment: NSTextAlignment, font: NSFont?) {
        ("", .left, nil)
    }

    /// Returns optional dimmed secondary text drawn on the same line after
    /// the primary ``cellContent(for:row:)`` text for a given column/row.
    ///
    /// Additive to ``cellContent(for:row:)`` — does NOT change its
    /// `(text, alignment, font)` tuple, so existing renderers are unaffected,
    /// and it never changes the row height: every list keeps the shared
    /// single-line height whether or not rows carry secondary text. Return
    /// `nil` (the default) to show the primary text alone. Subclasses use
    /// this to show a bundle's user-facing display name as the primary text
    /// while keeping the functional identifier (e.g. a FASTA contig id)
    /// visible beside it.
    open func secondaryCellText(
        for column: NSUserInterfaceItemIdentifier,
        row: Row
    ) -> String? {
        nil
    }

    /// Returns an optional tooltip for a cell. Reset on every render, so a
    /// reused cell never keeps a tooltip from another row. Default: none.
    open func cellToolTip(
        for column: NSUserInterfaceItemIdentifier,
        row: Row
    ) -> String? {
        nil
    }

    /// Returns an optional primary text colour for a cell, for example to
    /// flag a warning. `nil` (the default) uses the standard label colour.
    open func cellTextColor(
        for column: NSUserInterfaceItemIdentifier,
        row: Row
    ) -> NSColor? {
        nil
    }

    /// Returns whether the given row matches `filterText`.
    ///
    /// The default implementation always returns `true` (no filtering).
    open func rowMatchesFilter(_ row: Row, filterText: String) -> Bool { true }

    /// Returns `true` if `lhs` should be ordered before `rhs` when sorting by `key`.
    ///
    /// Pass `ascending` directly to control the result direction. Returning `false` for
    /// both `(lhs, rhs)` and `(rhs, lhs)` is treated as equal by the sort. The default
    /// returns `false` for all keys.
    open func compareRows(_ lhs: Row, _ rhs: Row, by key: String, ascending: Bool) -> Bool { false }

    /// Returns the sample identifier for `row`, used for metadata column lookups.
    ///
    /// Return `nil` if the row has no associated sample. The default returns `nil`.
    open func sampleId(for row: Row) -> String? { nil }

    /// Result/run identity to include in stable row IDs for duplicated biological names.
    public var resultIdentity: String? {
        didSet {
            metadataColumns.persistenceKey = resultIdentity.map {
                "\(String(reflecting: type(of: self))):\($0)"
            }
        }
    }

    /// Returns a stable biological identity for `row`.
    ///
    /// Subclasses that can display duplicate names after sort/filter/reload should
    /// include result/run context, sample, and the tool-specific biological key.
    open func rowIdentity(for row: Row) -> String? { nil }

    /// Returns a string value for a column, used by per-column filtering.
    ///
    /// Subclasses should override to return the appropriate value for each column.
    /// The default returns the cell content text from ``cellContent(for:row:)``.
    open func columnValue(for columnId: String, row: Row) -> String {
        cellContent(for: NSUserInterfaceItemIdentifier(columnId), row: row).text
    }

    /// Returns a raw numeric value for a column, used by per-column filtering.
    ///
    /// Override this when the displayed cell text is rounded or formatted
    /// (for example `1.5K`) so numeric filters can match the underlying value.
    open func columnNumericValue(for columnId: String, row: Row) -> Double? { nil }

    /// Column type hints — true = numeric, false = text.
    /// Subclasses should override to declare which columns are numeric.
    open var columnTypeHints: [String: Bool] { [:] }

    /// Delay before applying user-typed free-text filters.
    open var filterDebounceDelay: Duration { .milliseconds(180) }

    // MARK: - State

    /// The rows currently displayed (after any filter and sort).
    public private(set) var displayedRows: [Row] = []

    /// Pre-filter baseline preserved so re-sort can restart without re-filtering.
    private var unsortedRows: [Row] = []

    /// The full unfiltered set of rows as last provided by ``configure(rows:)``.
    public var unfilteredRows: [Row] = []

    /// Per-column filters applied via column header click menus.
    public var columnFilterSet = ColumnFilterSet()

    /// Compatibility view of active filters keyed by column identifier.
    public var columnFilters: [String: ColumnFilter] {
        columnFilterSet.activeFiltersByColumn()
    }

    /// Original column titles before filter indicators were appended.
    private var originalColumnTitles: [String: String] = [:]

    /// Current filter text applied to rows.
    private var filterText: String = ""

    /// Nil searches the existing built-in fields plus all displayed metadata.
    private var selectedMetadataSearchColumnID: String?

    /// Pending user-typed free-text filter application.
    private var pendingFilterTask: Task<Void, Never>?

    /// Live content-size preference observation.
    private var contentTypographyObservation: ContentTypographyNotificationObservation?

    /// Stable selection IDs for the current table.
    private var selectionIdentities = SelectionIdentityStore<String>()

    /// Suppresses delegate callbacks while programmatically restoring selection.
    private var isRestoringSelection = false

    // MARK: - Callbacks

    /// Called when the user selects a single row.
    public var onRowSelected: ((Row) -> Void)?

    /// Called when the user selects multiple rows. Provides the full array of selected rows.
    public var onMultipleRowsSelected: (([Row]) -> Void)?

    /// Called when the selection is cleared.
    public var onSelectionCleared: (() -> Void)?

    // MARK: - Metadata Columns

    /// Controller for dynamic sample-metadata columns (from imported CSV/TSV).
    public let metadataColumns = MetadataColumnController(
        contentTypographyOwnership: .embedded
    )

    /// Optional contextual menu assigned to the table.
    public var tableContextMenu: NSMenu? {
        didSet {
            tableView?.menu = tableContextMenu
        }
    }

    // MARK: - Child Views

    /// The table view. Accessible to subclasses for targeted column reloads.
    public private(set) var tableView: NSTableView!
    private var scrollView: NSScrollView!
    private var noMatchesStatusView: ViewportStatusView!
    private var searchField: NSSearchField!
    private var searchHeightConstraint: NSLayoutConstraint!
    private var preferredFontProvider: any ContentPreferredFontProviding =
        AppKitContentPreferredFontProvider()
    private var overridePreferredFontCanonicalPointSize: CGFloat = 0

    // MARK: - Init

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupTableView()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupTableView()
    }

    deinit {
        pendingFilterTask?.cancel()
    }

    // MARK: - Setup

    private func setupTableView() {
        overridePreferredFontCanonicalPointSize = preferredFontProvider
            .canonicalUnscaledPointSize(for: .body)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // Search field above the table.
        let sf = NSSearchField()
        sf.translatesAutoresizingMaskIntoConstraints = false
        sf.placeholderString = searchPlaceholder
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

        // UX-14: overlay shown in place of a blank grid when a filter
        // narrows the table to zero rows, so "no matches" reads as an
        // explicit state rather than looking like a bug.
        let statusView = ViewportStatusView()
        statusView.translatesAutoresizingMaskIntoConstraints = false
        statusView.isHidden = true
        addSubview(statusView)
        self.noMatchesStatusView = statusView

        let searchHeightConstraint = sf.heightAnchor.constraint(equalToConstant: 24)
        self.searchHeightConstraint = searchHeightConstraint
        NSLayoutConstraint.activate([
            sf.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            sf.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            sf.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            searchHeightConstraint,
            sv.topAnchor.constraint(equalTo: sf.bottomAnchor, constant: 4),
            sv.leadingAnchor.constraint(equalTo: leadingAnchor),
            sv.trailingAnchor.constraint(equalTo: trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusView.topAnchor.constraint(equalTo: sv.topAnchor),
            statusView.leadingAnchor.constraint(equalTo: sv.leadingAnchor),
            statusView.trailingAnchor.constraint(equalTo: sv.trailingAnchor),
            statusView.bottomAnchor.constraint(equalTo: sv.bottomAnchor),
        ])

        let tv = NSTableView()
        tv.usesAlternatingRowBackgroundColors = true
        tv.allowsColumnReordering  = true
        tv.allowsColumnResizing    = true
        tv.allowsColumnSelection   = false
        tv.allowsMultipleSelection = true
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
        metadataColumns.onColumnsOrStoreChanged = { [weak self] in
            guard let self else { return }
            self.rebuildSearchScopeMenu()
            self.applyFilter()
        }
        rebuildSearchScopeMenu()
        applyContentTypography()
        let notifications = NotificationCenterContentTypographyNotifications(
            notificationCenter: .default
        )
        contentTypographyObservation = notifications.observe(
            .contentTextSizeDidChange
        ) { [weak self] in
            self?.applyContentTypography()
        }
    }

    /// Applies shared semantic content fonts and adaptive table geometry.
    ///
    /// Subclasses overriding this hook must call `super`.
    open func applyContentTypography() {
        let typography = ContentTypography.current(
            preferredFontProvider: preferredFontProvider
        )
        let selectedRows = tableView.selectedRowIndexes
        isRestoringSelection = true
        defer { isRestoringSelection = false }
        searchField.font = typography.font(for: .body)
        searchHeightConstraint.constant = max(
            24,
            ceil(typography.font(for: .body).boundingRectForFont.height + 8)
        )
        tableView.rowHeight = typography.tableRowHeight()
        if let headerView = tableView.headerView {
            var frame = headerView.frame
            frame.size.height = typography.tableHeaderHeight()
            headerView.frame = frame
        }
        scrollView.tile()
        for column in tableView.tableColumns {
            column.headerCell.font = typography.font(for: .tableHeader)
        }
        tableView.reloadData()
        tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
    }

    /// Replaces the semantic preferred-font source and resets the stable
    /// baseline used for explicit subclass font overrides.
    public func setContentPreferredFontProvider(
        _ provider: any ContentPreferredFontProviding
    ) {
        preferredFontProvider = provider
        overridePreferredFontCanonicalPointSize = provider
            .canonicalUnscaledPointSize(for: .body)
        applyContentTypography()
    }

    /// The resolved semantic typography currently used by this table.
    ///
    /// Exposed for subclasses that adapt non-font geometry, such as column
    /// widths, to the same resolved system metrics.
    public func resolvedContentTypography() -> ContentTypography {
        ContentTypography.current(preferredFontProvider: preferredFontProvider)
    }

    /// Returns the unscaled canonical point size supplied by the active
    /// preferred-font source.
    public func canonicalContentPointSize(for role: ContentTypography.Role) -> CGFloat {
        preferredFontProvider.canonicalUnscaledPointSize(for: role)
    }

    private func addFixedColumns() {
        for spec in columnSpecs {
            let col = NSTableColumn(identifier: spec.identifier)
            col.title    = spec.title
            col.width    = spec.width
            col.minWidth = spec.minWidth
            col.headerToolTip = spec.toolTip ?? Self.defaultHeaderToolTip(for: spec)
            col.sortDescriptorPrototype = NSSortDescriptor(
                key: spec.identifier.rawValue,
                ascending: spec.defaultAscending
            )
            tableView.addTableColumn(col)
        }
    }

    private static func defaultHeaderToolTip(for spec: BatchColumnSpec) -> String? {
        let title = spec.title
        let normalized = title.lowercased()
        if normalized == "sample" {
            return "Sample identifier."
        }
        if normalized == "name" || normalized == "organism" {
            return "Taxon or organism name."
        }
        if normalized == "rank" {
            return "Taxonomic rank."
        }
        if normalized.contains("unique reads") {
            return "Unique or deduplicated reads."
        }
        if normalized.contains("reads") {
            return "Read count in reads."
        }
        if normalized == "%" {
            return "Classified read percentage."
        }
        if normalized.contains("coverage breadth") || normalized == "coverage" {
            return "Percent of reference bases covered."
        }
        if normalized.contains("coverage depth") {
            return "Mean read depth over the reference."
        }
        if normalized.contains("abundance") {
            return "Estimated relative abundance."
        }
        if normalized.contains("tass score") {
            return "TaxTriage confidence score."
        }
        if normalized.contains("confidence") {
            return "Classifier confidence label."
        }
        if normalized.contains("rpkmf") {
            return "Reads per kilobase per million fragments."
        }
        if normalized.contains("assembly") || normalized.contains("family") {
            return title
        }
        return nil
    }

    // MARK: - Public API

    /// Replaces the displayed rows and reloads the table.
    ///
    /// The current filter text is re-applied automatically so that existing
    /// filter state is preserved across sample filter changes.
    ///
    /// - Parameter rows: The new rows to display.
    open func configure(rows: [Row]) {
        self.unfilteredRows = rows
        applyFilter()
        hideEmptyColumns()
    }

    /// Rebuilds columns from the current ``columnSpecs`` and refreshes shared
    /// flexible-sizing and header-chooser integration.
    ///
    /// Hidden state and user widths are preserved for stable identifiers. Dynamic
    /// subclasses should update the state backing ``columnSpecs`` before calling.
    public func rebuildStandardColumns() {
        var previousState: [String: (width: CGFloat, isHidden: Bool)] = [:]
        let existingStandardColumns = tableView.tableColumns.filter {
            !MetadataColumnController.isMetadataColumn($0.identifier)
        }
        for column in existingStandardColumns {
            previousState[column.identifier.rawValue] = (column.width, column.isHidden)
        }

        for column in existingStandardColumns {
            tableView.removeTableColumn(column)
        }
        addFixedColumns()

        for column in tableView.tableColumns {
            guard let state = previousState[column.identifier.rawValue] else { continue }
            column.width = state.width
            column.isHidden = state.isHidden
        }
        metadataColumns.standardColumnNames = standardColumnNames
        metadataColumns.refreshAfterStandardColumnsChanged()
        applyContentTypography()
    }

    // MARK: - Responder Contract (UX-04, UX-17)

    /// Standard Mac responder contract for result tables: `copy:` puts the
    /// selected rows on the pasteboard as TSV (header plus one line per
    /// selected row, visible columns only, in display order), and
    /// `performFindPanelAction:`/`performTextFinderAction:` with
    /// `.showFindInterface` focus this table's own filter field instead of
    /// opening a `NSTextFinder` panel, since the filter field already is
    /// this table's "find" affordance. Implemented once here so every
    /// `BatchTableView` subclass (EsViritu, Assembly and Mapping contig
    /// tables, and any future adopter) gets Edit > Copy and Edit > Find for
    /// free instead of each viewer inventing its own right-click-only copy.
    open override var acceptsFirstResponder: Bool { true }

    /// Visible, non-hidden columns in on-screen display order, used as the
    /// column set for `copy:`'s TSV rendering.
    private var visibleColumnsInDisplayOrder: [NSTableColumn] {
        tableView.tableColumns.filter { !$0.isHidden }
    }

    /// Builds the TSV representation (header row + one row per `rows`) using
    /// the same `columnValue(for:row:)` contract column filters already rely
    /// on, so copied text matches what column-value filtering considers the
    /// cell's value rather than any transient display formatting.
    private func tsvRepresentation(for rows: [Row]) -> String? {
        guard !rows.isEmpty else { return nil }
        let columns = visibleColumnsInDisplayOrder
        guard !columns.isEmpty else { return nil }

        func tsvEscape(_ value: String) -> String {
            value.replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
        }

        var lines: [String] = []
        let header = columns.map { tsvEscape($0.title) }.joined(separator: "\t")
        lines.append(header)
        for row in rows {
            let fields = columns.map { column in
                tsvEscape(columnValue(for: column.identifier.rawValue, row: row))
            }
            lines.append(fields.joined(separator: "\t"))
        }
        return lines.joined(separator: "\n")
    }

    /// `copy:` — puts the current selection (or, with no selection, every
    /// displayed row) on the pasteboard as TSV. Falls back to `.general`
    /// when a subclass has not supplied ``cellCopyPasteboard`` (production
    /// code always has a real `NSPasteboard`; tests inject a fake).
    @objc open func copy(_ sender: Any?) {
        let rows = selectedRowsByIdentity()
        let rowsToCopy = rows.isEmpty ? displayedRows : rows
        guard let tsv = tsvRepresentation(for: rowsToCopy) else { return }
        if let cellCopyPasteboard {
            cellCopyPasteboard.setString(tsv)
        } else {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(tsv, forType: .string)
        }
    }

    /// `selectAll:` — selects every displayed row, matching standard
    /// `NSTableView` behavior for a table that is otherwise a plain `NSView`.
    @objc open override func selectAll(_ sender: Any?) {
        guard !displayedRows.isEmpty else { return }
        tableView.selectAll(sender)
    }

    /// `performFindPanelAction:` — the selector `Edit > Find` sends
    /// (declared on `NSTextView`, not `NSResponder`, but dispatched by
    /// Objective-C selector name, so any responder in the chain may
    /// implement it). Focuses this table's own filter field for
    /// `.showFindInterface`; other tags are forwarded up the responder chain
    /// since this table has no find-next/previous/replace behavior of its own.
    @objc open func performFindPanelAction(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem,
              let tag = NSTextFinder.Action(rawValue: menuItem.tag),
              tag == .showFindInterface else {
            nextResponder?.tryToPerform(#selector(BatchTableView.performFindPanelAction(_:)), with: sender)
            return
        }
        _ = focusSearchField()
    }

    /// `performTextFinderAction:` — declared on `NSResponder`; some callers
    /// send this instead of `performFindPanelAction:`. Forwards to the same
    /// handling.
    @objc open override func performTextFinderAction(_ sender: Any?) {
        performFindPanelAction(sender)
    }

    /// Makes the filter search field the window's first responder. Returns
    /// `true` when the field could be focused (a window is attached).
    @discardableResult
    public func focusSearchField() -> Bool {
        guard let window = self.window else { return false }
        return window.makeFirstResponder(searchField)
    }

    open func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(copy(_:)):
            return !displayedRows.isEmpty
        case #selector(selectAll(_:)):
            return !displayedRows.isEmpty
        case #selector(performFindPanelAction(_:)), #selector(performTextFinderAction(_:)):
            if let tag = NSTextFinder.Action(rawValue: menuItem.tag) {
                return tag == .showFindInterface
            }
            return true
        default:
            return true
        }
    }

    // MARK: - Empty Column Hiding

    /// Returns `true` if the given column has at least one non-nil / non-empty data value
    /// across all rows in ``unfilteredRows``.
    ///
    /// The default implementation always returns `true` (no columns hidden).
    /// Subclasses override this to hide columns that are never populated for a given tool.
    open func columnHasData(_ columnId: NSUserInterfaceItemIdentifier) -> Bool {
        return true
    }

    /// Hook for subclasses that need to react after filtering/sorting replaces ``displayedRows``.
    open func didApplyDisplayedRows() {}

    /// Hides fixed (non-metadata) columns that have no data across all rows.
    ///
    /// Called automatically at the end of ``configure(rows:)``. Each non-metadata column
    /// is shown or hidden based on the result of ``columnHasData(_:)``.
    open func hideEmptyColumns() {
        for col in tableView.tableColumns {
            guard !MetadataColumnController.isMetadataColumn(col.identifier) else { continue }
            col.isHidden = !columnHasData(col.identifier)
        }
    }

    // MARK: - Filter

    @objc private func filterChanged(_ sender: NSSearchField) {
        filterText = sender.stringValue
        if filterText.isEmpty {
            pendingFilterTask?.cancel()
            pendingFilterTask = nil
            applyFilter()
            return
        }
        scheduleFilterApply()
    }

    private func scheduleFilterApply() {
        pendingFilterTask?.cancel()
        let delay = filterDebounceDelay
        pendingFilterTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingFilterTask = nil
            self.applyFilter()
        }
    }

    private func applyFilter() {
        var filtered: [Row]
        if filterText.isEmpty {
            filtered = unfilteredRows
        } else {
            filtered = unfilteredRows.filter { rowMatchesSearch($0, filterText: filterText) }
        }

        let columnFilterSnapshot = ColumnFilterSnapshot(columnFilterSet, typeHints: columnTypeHints)
        if columnFilterSnapshot.isActive {
            filtered = filtered.filter { row in
                columnFilterSnapshot.matches { filter in
                    columnFilterValue(for: filter, row: row)
                }
            }
        }

        // Re-apply current sort order on top of the filtered set.
        if let descriptor = tableView.sortDescriptors.first, let key = descriptor.key {
            let ascending = descriptor.ascending
            self.unsortedRows  = filtered
            self.displayedRows = filtered.sorted { compareDisplayedRows($0, $1, by: key, ascending: ascending) }
        } else {
            self.unsortedRows  = filtered
            self.displayedRows = filtered
        }
        tableView.reloadData()
        ColumnFilter.updateColumnTitleIndicators(
            on: tableView,
            filters: columnFilterSet.activeFiltersByColumn(),
            originalTitles: &originalColumnTitles
        )
        restoreSelectionByIdentityAfterDisplayedRowsChanged()
        updateNoMatchesStatus()
        didApplyDisplayedRows()
    }

    /// Shows the "no matches" overlay (UX-14) when a free-text or column
    /// filter has narrowed a non-empty table to zero rows. Stays hidden
    /// when the table is legitimately empty (no rows were ever loaded), so
    /// this overlay never substitutes for a tool-specific empty-result
    /// message a subclass may show elsewhere.
    private func updateNoMatchesStatus() {
        let hasActiveFilter = !filterText.isEmpty || columnFilterSet.isActive
        let shouldShow = displayedRows.isEmpty && !unfilteredRows.isEmpty && hasActiveFilter
        noMatchesStatusView.isHidden = !shouldShow
        guard shouldShow else { return }
        noMatchesStatusView.configure(.noMatches()) { [weak self] in
            guard let self else { return }
            self.setFilterText("")
            self.clearAllColumnFilters()
        }
    }

    private func rowMatchesSearch(_ row: Row, filterText: String) -> Bool {
        if let selectedMetadataSearchColumnID {
            return metadataColumns.value(
                columnID: selectedMetadataSearchColumnID,
                sampleID: sampleId(for: row)
            )?.localizedCaseInsensitiveContains(filterText) == true
        }
        if rowMatchesFilter(row, filterText: filterText) {
            return true
        }
        return metadataColumns.displayedMetadataColumns.contains { column in
            metadataColumns.value(columnID: column.id, sampleID: sampleId(for: row))?
                .localizedCaseInsensitiveContains(filterText) == true
        }
    }

    private func compareDisplayedRows(
        _ lhs: Row,
        _ rhs: Row,
        by key: String,
        ascending: Bool
    ) -> Bool {
        if let result = metadataColumns.comparison(
            columnID: key,
            lhsSampleID: sampleId(for: lhs),
            rhsSampleID: sampleId(for: rhs)
        ) {
            return ascending ? result == .orderedAscending : result == .orderedDescending
        }
        return compareRows(lhs, rhs, by: key, ascending: ascending)
    }

    private func rebuildSearchScopeMenu() {
        let displayedColumns = metadataColumns.displayedMetadataColumns
        if let selectedMetadataSearchColumnID,
           !displayedColumns.contains(where: { $0.id == selectedMetadataSearchColumnID }) {
            self.selectedMetadataSearchColumnID = nil
        }

        let menu = NSMenu(title: "Search Fields")
        let allFields = NSMenuItem(
            title: "All Fields",
            action: #selector(selectSearchScope(_:)),
            keyEquivalent: ""
        )
        allFields.target = self
        allFields.state = selectedMetadataSearchColumnID == nil ? .on : .off
        menu.addItem(allFields)
        if !displayedColumns.isEmpty {
            menu.addItem(.separator())
        }
        for column in displayedColumns {
            let item = NSMenuItem(
                title: column.title,
                action: #selector(selectSearchScope(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = column.id
            item.state = selectedMetadataSearchColumnID == column.id ? .on : .off
            menu.addItem(item)
        }
        searchField.searchMenuTemplate = menu
    }

    @objc private func selectSearchScope(_ sender: NSMenuItem) {
        selectedMetadataSearchColumnID = sender.representedObject as? String
        rebuildSearchScopeMenu()
        applyFilter()
    }

    private func columnFilterValue(for filter: PreparedColumnFilter, row: Row) -> ColumnFilterValue? {
        let columnId = filter.columnId

        if let metadataColumnName = filter.metadataColumnName,
           let sid = sampleId(for: row),
           let store = metadataColumns.store,
           let metaValue = store.records[sid]?[metadataColumnName] {
            if filter.prefersNumeric,
               let numericValue = ColumnFilter.parseNumericValue(metaValue) {
                return .numeric(numericValue)
            }
            return .string(metaValue)
        }

        if let numericValue = columnNumericValue(for: columnId, row: row) {
            return .numeric(numericValue)
        }
        let value = columnValue(for: columnId, row: row)
        if filter.prefersNumeric,
           let numericValue = ColumnFilter.parseNumericValue(value) {
            return .numeric(numericValue)
        }
        return .string(value)
    }

    /// Returns the current free-text filter query.
    public var currentFilterText: String { searchField.stringValue }

    /// Applies a new free-text filter query and refreshes the table.
    public func setFilterText(_ text: String) {
        pendingFilterTask?.cancel()
        pendingFilterTask = nil
        searchField.stringValue = text
        filterText = text
        applyFilter()
    }

    /// Returns the scroll origin of the table view content.
    public var currentScrollOriginY: CGFloat { scrollView.contentView.bounds.origin.y }

    /// Restores the table view scroll origin.
    public func restoreScrollOriginY(_ originY: CGFloat) {
        layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: originY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Positions a displayed row at the top of the visible table area.
    public func scrollRowToTop(_ rowIndex: Int) {
        guard rowIndex >= 0, rowIndex < tableView.numberOfRows else { return }
        layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        tableView.layoutSubtreeIfNeeded()

        let rowRect = tableView.rect(ofRow: rowIndex)
        let maxY = max(0, tableView.bounds.height - scrollView.contentView.bounds.height)
        let targetY = min(max(0, rowRect.minY), maxY)
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Replaces or inserts a column filter and refreshes the table.
    public func setColumnFilter(_ filter: ColumnFilter, for columnId: String) {
        columnFilterSet.replaceFilters(for: columnId, with: filter)
        applyFilter()
    }

    /// Appends a column filter without replacing other filters on the same column.
    public func addColumnFilter(_ filter: ColumnFilter) {
        columnFilterSet.append(filter)
        applyFilter()
    }

    /// Sets whether active filters compose as AND or OR.
    public func setColumnFilterComposition(_ composition: ColumnFilterComposition) {
        columnFilterSet.composition = composition
        applyFilter()
    }

    /// Removes one column filter and refreshes the table.
    public func clearColumnFilter(for columnId: String) {
        columnFilterSet.removeFilters(for: columnId)
        applyFilter()
    }

    /// Removes every column filter and refreshes the table.
    public func clearAllColumnFilters() {
        columnFilterSet.removeAll()
        applyFilter()
    }

    // MARK: - Cell Factory

    open func makeCellView(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = BatchTableCellView()
        cell.identifier = identifier
        let tf = NSTextField(labelWithString: "")
        let typography = ContentTypography.current(
            preferredFontProvider: preferredFontProvider
        )
        tf.font = typography.font(for: .monospaced)
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf

        // Optional dimmed secondary text (populated via `secondaryCellText`).
        // It sits on the same line as the primary text, after it, so a row
        // that carries it is exactly as tall as one that does not: every
        // list in the app shares the single-line row height. Hidden and
        // empty by default so cells without it are unaffected; additive to
        // the primary `textField` slot, not a replacement for it.
        let secondaryField = NSTextField(labelWithString: "")
        secondaryField.tag = batchSecondaryTextFieldTag
        secondaryField.font = typography.font(for: .monospaced)
        secondaryField.textColor = .secondaryLabelColor
        secondaryField.lineBreakMode = .byTruncatingTail
        secondaryField.translatesAutoresizingMaskIntoConstraints = false
        secondaryField.isHidden = true
        cell.addSubview(secondaryField)

        // The primary text keeps its width when the two compete for room;
        // the secondary text truncates first. A primary wider than the cell
        // still truncates against the required trailing limit below.
        tf.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        secondaryField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        secondaryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // With no secondary text the primary field spans the cell exactly as
        // it always has (`batchCellPrimaryTrailing`). When secondary text is
        // shown that constraint is released and the secondary field takes
        // over the trailing edge (`batchCellSecondaryTrailing`).
        let primaryTrailing = tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4)
        primaryTrailing.identifier = "batchCellPrimaryTrailing"
        let secondaryLeading = secondaryField.leadingAnchor.constraint(equalTo: tf.trailingAnchor, constant: 8)
        secondaryLeading.identifier = "batchCellSecondaryLeading"
        let secondaryTrailing = secondaryField.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4)
        secondaryTrailing.identifier = "batchCellSecondaryTrailing"
        cell.primaryTrailing = primaryTrailing
        cell.secondaryLeading = secondaryLeading
        cell.secondaryTrailing = secondaryTrailing
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            primaryTrailing,
            secondaryField.firstBaselineAnchor.constraint(equalTo: tf.firstBaselineAnchor),
        ])
        return cell
    }

    // MARK: - NSTableViewDataSource

    public func numberOfRows(in tableView: NSTableView) -> Int {
        displayedRows.count
    }

    public func tableView(
        _ tableView: NSTableView,
        sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key else {
            displayedRows = unsortedRows
            tableView.reloadData()
            restoreSelectionByIdentityAfterDisplayedRowsChanged()
            return
        }
        let ascending = descriptor.ascending
        displayedRows = unsortedRows.sorted { compareDisplayedRows($0, $1, by: key, ascending: ascending) }
        tableView.reloadData()
        restoreSelectionByIdentityAfterDisplayedRowsChanged()
    }

    public func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let headerView = tableView.headerView else { return }
        columnHeaderFilterMenuController.show(for: tableColumn, in: headerView)
    }

    // MARK: - ColumnFilterMenuHost

    public var columnHeaderFilterMenuColumns: [NSTableColumn] { tableView.tableColumns }

    public func columnHeaderFilterMenu(isNumericColumn columnId: String) -> Bool {
        columnTypeHints[columnId] ?? false
    }

    public var columnHeaderFilterMenuFilterSet: ColumnFilterSet { columnFilterSet }

    public func columnHeaderFilterMenu(replaceFilterFor columnId: String, with filter: ColumnFilter) {
        columnFilterSet.replaceFilters(for: columnId, with: filter)
    }

    public func columnHeaderFilterMenu(removeFilterFor columnId: String) {
        columnFilterSet.removeFilters(for: columnId)
    }

    public func columnHeaderFilterMenuRemoveAllFilters() {
        columnFilterSet.removeAll()
    }

    public func columnHeaderFilterMenu(setComposition composition: ColumnFilterComposition) {
        columnFilterSet.composition = composition
    }

    public func columnHeaderFilterMenu(sortByKey key: String, ascending: Bool) {
        guard let proto = tableView.tableColumns
            .first(where: { $0.sortDescriptorPrototype?.key == key })?.sortDescriptorPrototype
        else { return }
        tableView.sortDescriptors = [NSSortDescriptor(key: proto.key, ascending: ascending, selector: proto.selector)]
    }

    public func columnHeaderFilterMenuFiltersDidChange() {
        applyFilter()
    }

    public var columnHeaderFilterMenuWindow: NSWindow? { window }

    // MARK: - NSTableViewDelegate

    public func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let column = tableColumn, row < displayedRows.count else { return nil }

        // Metadata columns handled by the controller.
        if MetadataColumnController.isMetadataColumn(column.identifier) {
            let rowData = displayedRows[row]
            return metadataColumns.cellForColumn(column, in: tableView, sampleId: sampleId(for: rowData) ?? "")
        }

        let rowData = displayedRows[row]
        let id = column.identifier

        let cellView = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView
            ?? makeCellView(identifier: id)

        populateCellView(cellView, id: id, rowData: rowData)

        return cellView
    }

    /// Populates (or resets) `cellView` for `id`/`rowData`, exactly as
    /// ``tableView(_:viewFor:row:)`` does for a view AppKit handed back from
    /// its reuse pool or built fresh — factored out so it can also be driven
    /// directly on a specific, already-existing `NSTableCellView` instance
    /// (see `testPopulateReusedCellView` below) to deterministically exercise
    /// the reuse-reset seam without depending on AppKit's private reuse-queue
    /// timing, which is not driven synchronously by any documented public API
    /// in a headless/offscreen test host.
    private func populateCellView(
        _ cellView: NSTableCellView,
        id: NSUserInterfaceItemIdentifier,
        rowData: Row
    ) {
        let (text, alignment, font) = cellContent(for: id, row: rowData)
        cellView.textField?.stringValue = text
        cellView.textField?.alignment   = alignment
        if let font {
            cellView.textField?.font = scaledContentFont(from: font)
        } else {
            cellView.textField?.font = ContentTypography.current(
                preferredFontProvider: preferredFontProvider
            ).font(for: .monospaced)
        }

        cellView.textField?.textColor = cellTextColor(for: id, row: rowData) ?? .labelColor
        let toolTip = cellToolTip(for: id, row: rowData)
        cellView.textField?.toolTip = toolTip
        cellView.toolTip = toolTip

        let secondaryText = secondaryCellText(for: id, row: rowData)
        applySecondaryCellText(secondaryText, to: cellView, alignment: alignment)
    }

    /// Populates (or hides) the dimmed secondary text added by
    /// ``makeCellView(identifier:)`` and hands the cell's trailing edge to
    /// whichever field is last on the line. Cells are reused across
    /// rows/columns, so this runs on every render to reset state left over
    /// from a prior row.
    private func applySecondaryCellText(
        _ secondaryText: String?,
        to cellView: NSTableCellView,
        alignment: NSTextAlignment
    ) {
        guard let secondaryField = cellView.viewWithTag(batchSecondaryTextFieldTag) as? NSTextField else {
            return
        }
        let cell = cellView as? BatchTableCellView

        if let secondaryText, !secondaryText.isEmpty {
            secondaryField.stringValue = secondaryText
            secondaryField.alignment = alignment
            secondaryField.isHidden = false
            cell?.primaryTrailing?.isActive = false
            cell?.secondaryLeading?.isActive = true
            cell?.secondaryTrailing?.isActive = true
        } else {
            secondaryField.stringValue = ""
            secondaryField.isHidden = true
            cell?.secondaryLeading?.isActive = false
            cell?.secondaryTrailing?.isActive = false
            cell?.primaryTrailing?.isActive = true
        }
    }

    private func scaledContentFont(from baseline: NSFont) -> NSFont {
        let preferenceScale = CGFloat(
            AppSettings.shared.contentTextSizePreference.normalized.scaleFactor
        )
        let currentPreferredPointSize = preferredFontProvider
            .preferredFont(for: .body)
            .pointSize
        let systemMetricScale = currentPreferredPointSize
            / max(overridePreferredFontCanonicalPointSize, 1)
        let scale = preferenceScale * systemMetricScale
        let pointSize = max(ContentTypography.minimumPointSize, baseline.pointSize * scale)
        return NSFont(descriptor: baseline.fontDescriptor, size: pointSize) ?? baseline
    }

    open func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRestoringSelection else { return }

        let selectedIndexes = tableView.selectedRowIndexes
        if selectedIndexes.isEmpty {
            selectionIdentities.clear()
            onSelectionCleared?()
            return
        }

        let selected = selectedIndexes.compactMap { idx -> Row? in
            guard idx < displayedRows.count else { return nil }
            return displayedRows[idx]
        }

        let ids = selected.compactMap { rowIdentity(for: $0) }
        if ids.count == selected.count, !ids.isEmpty {
            selectionIdentities.select(ids)
        } else {
            selectionIdentities.clear()
        }

        emitSelectionCallbacks(for: selected)
    }

    /// Returns selected visible rows using stable identity when available.
    public func selectedRowsByIdentity() -> [Row] {
        guard let visibleIDs = displayedRowIdentities(),
              !selectionIdentities.selectedIDs.isEmpty else {
            return selectedRowsByCurrentIndexes()
        }

        let selectedIDs = selectionIdentities.selectedIDs
        return displayedRows.enumerated().compactMap { index, row in
            selectedIDs.contains(visibleIDs[index]) ? row : nil
        }
    }

    /// Returns true when the current stable selection still maps to a visible row.
    public func hasVisibleIdentitySelection() -> Bool {
        !selectedRowsByIdentity().isEmpty
    }

    /// Selects a clicked context-menu row through the same identity store as visible selection.
    public func selectDisplayedRowForContextMenuIfNeeded(_ rowIndex: Int) {
        guard rowIndex >= 0, rowIndex < displayedRows.count else { return }
        let row = displayedRows[rowIndex]

        if let id = rowIdentity(for: row), !id.isEmpty {
            selectionIdentities.select([id])
            restoreTableSelection(IndexSet(integer: rowIndex))
            emitSelectionCallbacks(for: [row])
        } else {
            tableView.selectRowIndexes(IndexSet(integer: rowIndex), byExtendingSelection: false)
            tableViewSelectionDidChange(
                Notification(name: NSTableView.selectionDidChangeNotification, object: tableView)
            )
        }
    }

    private func restoreSelectionByIdentityAfterDisplayedRowsChanged() {
        guard let visibleIDs = displayedRowIdentities() else { return }

        let previousIDs = selectionIdentities.selectedIDs
        guard !previousIDs.isEmpty else {
            restoreTableSelection([])
            return
        }

        selectionIdentities.removeSelectionsNotVisible(in: visibleIDs)
        let selectedIndexes = selectionIdentities.visibleIndexes(in: visibleIDs)
        restoreTableSelection(selectedIndexes)

        if selectionIdentities.selectedIDs.isEmpty {
            onSelectionCleared?()
        } else {
            emitSelectionCallbacks(for: selectedRowsByIdentity())
        }
    }

    private func displayedRowIdentities() -> [String]? {
        var ids: [String] = []
        ids.reserveCapacity(displayedRows.count)
        for row in displayedRows {
            guard let id = rowIdentity(for: row), !id.isEmpty else { return nil }
            ids.append(id)
        }
        return ids
    }

    private func selectedRowsByCurrentIndexes() -> [Row] {
        tableView.selectedRowIndexes.compactMap { index in
            guard index >= 0, index < displayedRows.count else { return nil }
            return displayedRows[index]
        }
    }

    private func restoreTableSelection(_ indexes: IndexSet) {
        isRestoringSelection = true
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        isRestoringSelection = false
    }

    private func emitSelectionCallbacks(for selected: [Row]) {
        if selected.isEmpty {
            onSelectionCleared?()
        } else if selected.count == 1, let row = selected.first {
            onRowSelected?(row)
        } else {
            onMultipleRowsSelected?(selected)
        }
    }
}

#if DEBUG
extension BatchTableView {
    public var testSearchField: NSSearchField { searchField }
    public var testTableView: NSTableView { tableView }

    /// Whether the UX-14 "no matches" overlay is currently visible.
    public var testNoMatchesStatusVisible: Bool { !noMatchesStatusView.isHidden }

    /// Renders the cell view for `row`/`columnID` through the real
    /// `NSTableViewDelegate` path and returns its primary and (if visible)
    /// secondary line text, for asserting on the additive secondary-line seam.
    public func testCellText(row: Int, columnID: String) -> (primary: String, secondary: String?) {
        guard let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == columnID }),
              let cellView = tableView(tableView, viewFor: column, row: row) as? NSTableCellView
        else {
            return ("", nil)
        }
        let primary = cellView.textField?.stringValue ?? ""
        guard let secondaryField = cellView.viewWithTag(batchSecondaryTextFieldTag) as? NSTextField,
              !secondaryField.isHidden else {
            return (primary, nil)
        }
        return (primary, secondaryField.stringValue)
    }

    /// Re-populates a specific, already-existing `NSTableCellView` for
    /// `row`/`columnID` through the exact same production code
    /// (`populateCellView`) that ``tableView(_:viewFor:row:)`` runs on a view
    /// AppKit hands back from its reuse pool.
    ///
    /// AppKit's real reuse-pool hand-off is driven by private, display-cycle
    /// bookkeeping with no synchronous, documented public trigger — verified
    /// empirically to be flaky (order of ~10-20% failures) even after a real
    /// scroll + `layoutSubtreeIfNeeded()` + `display()` pass in a headless
    /// test host. This hook drives the actual reuse-reset logic
    /// deterministically instead, by handing `populateCellView` a specific,
    /// caller-chosen `NSTableCellView` — usually one already returned by an
    /// earlier ``tableView(_:viewFor:row:)`` call for a different row — so
    /// tests can assert on leftover-state cleanup without racing AppKit's
    /// pool timing.
    public func testPopulateReusedCellView(
        _ cellView: NSTableCellView,
        row: Int,
        columnID: String
    ) {
        guard let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == columnID }),
              row >= 0, row < displayedRows.count else { return }
        populateCellView(cellView, id: column.identifier, rowData: displayedRows[row])
    }
}
#endif

// MARK: - Shared Helpers

/// Formats an integer read count as a compact human-readable string.
///
/// - `>= 1 000 000` → `"12.3M"`
/// - `>= 1 000`     → `"4.5K"`
/// - otherwise      → `"123"`
public func formatReadCount(_ count: Int) -> String {
    if count >= 1_000_000 {
        return String(format: "%.1fM", Double(count) / 1_000_000)
    } else if count >= 1_000 {
        return String(format: "%.1fK", Double(count) / 1_000)
    }
    return "\(count)"
}

// MARK: - Cell view

/// The cell ``BatchTableView/makeCellView(identifier:)`` builds.
///
/// Holds the constraints that hand the trailing edge to either the primary
/// text field or the inline secondary text, so re-populating a reused cell
/// can flip between the two without searching the constraint list (inactive
/// constraints are not in `constraints`).
public final class BatchTableCellView: NSTableCellView {
    fileprivate var primaryTrailing: NSLayoutConstraint?
    fileprivate var secondaryLeading: NSLayoutConstraint?
    fileprivate var secondaryTrailing: NSLayoutConstraint?
}
