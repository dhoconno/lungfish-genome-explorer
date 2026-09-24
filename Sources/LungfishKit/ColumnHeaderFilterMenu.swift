// ColumnHeaderFilterMenu.swift - Shared column-header sort/filter menu builder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit

/// A host that owns a table/outline view's column filter state and can be
/// driven by ``ColumnHeaderFilterMenu`` to show the "Sort / Filter / Combine /
/// Clear" column-header menu and its "Column Filter" value prompt.
///
/// This is the single source of truth for the menu that previously existed
/// as four near-identical, independently-drifting copies (`BatchTableView`,
/// `TaxonomyTableView`, `ViralDetectionTableView`, `NaoMgsResultViewController`).
/// A host only needs to supply its column list, type hints, filter set and a
/// callback to run after a filter/sort change; the menu itself and the value
/// prompt are shared code.
@MainActor
public protocol ColumnFilterMenuHost: AnyObject {
    /// The columns currently shown, in display order.
    var columnHeaderFilterMenuColumns: [NSTableColumn] { get }

    /// `true` when the named column should offer numeric operators
    /// (≥ / ≤ / = / between) instead of text operators (contains / equals /
    /// starts with).
    func columnHeaderFilterMenu(isNumericColumn columnId: String) -> Bool

    /// A snapshot of the filter set backing this host's table. `ColumnFilterSet`
    /// is a value type, so `ColumnHeaderFilterMenu` never mutates it in place —
    /// it reads a snapshot here and applies changes through the mutating
    /// methods below.
    var columnHeaderFilterMenuFilterSet: ColumnFilterSet { get }

    /// Replaces the filter(s) on `columnId` with `filter`.
    func columnHeaderFilterMenu(replaceFilterFor columnId: String, with filter: ColumnFilter)

    /// Removes the filter(s) on `columnId`.
    func columnHeaderFilterMenu(removeFilterFor columnId: String)

    /// Removes every column filter.
    func columnHeaderFilterMenuRemoveAllFilters()

    /// Sets the AND/OR composition mode across active column filters.
    func columnHeaderFilterMenu(setComposition composition: ColumnFilterComposition)

    /// Applies the given ascending/descending sort by column key. Hosts that
    /// use `NSTableView`/`NSOutlineView` native sort descriptors can just set
    /// `sortDescriptors`; hosts with a hand-rolled sort (the outline tables)
    /// update their own sort-key state.
    func columnHeaderFilterMenu(sortByKey key: String, ascending: Bool)

    /// Called after any filter or composition change so the host can
    /// re-derive its displayed rows and reload.
    func columnHeaderFilterMenuFiltersDidChange()

    /// The window to anchor the "Column Filter" value-entry sheet to.
    var columnHeaderFilterMenuWindow: NSWindow? { get }
}

/// Builds and presents the shared column-header context menu (sort, filter,
/// combine, clear) and its value-entry sheet, and applies the resulting
/// filter to a ``ColumnFilterMenuHost``.
///
/// Usage: a host owns one instance, forwards `didClick tableColumn:` to
/// ``show(for:in:)``, and implements ``ColumnFilterMenuHost``.
@MainActor
public final class ColumnHeaderFilterMenu: NSObject {
    private unowned let host: ColumnFilterMenuHost

    public init(host: ColumnFilterMenuHost) {
        self.host = host
    }

    /// Shows the column-header menu for `tableColumn`, anchored under its
    /// header cell in `headerView`.
    public func show(for tableColumn: NSTableColumn, in headerView: NSTableHeaderView) {
        guard let colIndex = headerView.tableView?.tableColumns.firstIndex(of: tableColumn) else { return }

        let columnId = tableColumn.identifier.rawValue
        let displayName = tableColumn.title.isEmpty ? "Column" : tableColumn.title
        let isNumeric = host.columnHeaderFilterMenu(isNumericColumn: columnId)
        let filterSet = host.columnHeaderFilterMenuFilterSet
        let activeByColumn = filterSet.activeFiltersByColumn()

        let menu = NSMenu()

        menu.addItem(makeItem("Sort Ascending") { [weak self] in
            self?.sort(tableColumn, ascending: true)
        })
        menu.addItem(makeItem("Sort Descending") { [weak self] in
            self?.sort(tableColumn, ascending: false)
        })

        menu.addItem(.separator())

        let operators: [(String, FilterOperator)] = isNumeric
            ? [
                ("Filter \(displayName) \u{2265}\u{2026}", .greaterOrEqual),
                ("Filter \(displayName) \u{2264}\u{2026}", .lessOrEqual),
                ("Filter \(displayName) =\u{2026}", .equal),
                ("Filter \(displayName) Between\u{2026}", .between),
            ]
            : [
                ("Filter \(displayName) Contains\u{2026}", .contains),
                ("Filter \(displayName) Equals\u{2026}", .equal),
                ("Filter \(displayName) Starts With\u{2026}", .startsWith),
            ]

        for (label, op) in operators {
            menu.addItem(makeItem(label) { [weak self] in
                self?.promptColumnFilter(columnId: columnId, displayName: displayName, op: op)
            })
        }

        if activeByColumn[columnId]?.isActive == true {
            menu.addItem(.separator())
            menu.addItem(makeItem("Clear \(displayName) Filter") { [weak self] in
                self?.clearFilter(columnId: columnId)
            })
        }

        if !activeByColumn.filter({ $0.value.isActive }).isEmpty {
            menu.addItem(.separator())

            let compositionItem = NSMenuItem(title: "Combine Filters", action: nil, keyEquivalent: "")
            let compositionMenu = NSMenu(title: "Combine Filters")
            for (title, composition) in [
                ("All Filters (AND)", ColumnFilterComposition.all),
                ("Any Filter (OR)", ColumnFilterComposition.any),
            ] {
                let item = makeItem(title) { [weak self] in
                    self?.setComposition(composition)
                }
                item.state = filterSet.composition == composition ? .on : .off
                compositionMenu.addItem(item)
            }
            compositionItem.submenu = compositionMenu
            menu.addItem(compositionItem)

            menu.addItem(makeItem("Clear All Filters") { [weak self] in
                self?.clearAll()
            })
        }

        let rect = headerView.headerRect(ofColumn: colIndex)
        let anchorPoint = NSPoint(x: rect.minX + 8, y: rect.minY - 2)
        menu.popUp(positioning: nil, at: anchorPoint, in: headerView)
    }

    // MARK: - Actions

    private func sort(_ column: NSTableColumn, ascending: Bool) {
        guard let proto = column.sortDescriptorPrototype, let key = proto.key else { return }
        host.columnHeaderFilterMenu(sortByKey: key, ascending: ascending)
    }

    private func clearFilter(columnId: String) {
        host.columnHeaderFilterMenu(removeFilterFor: columnId)
        host.columnHeaderFilterMenuFiltersDidChange()
    }

    private func clearAll() {
        host.columnHeaderFilterMenuRemoveAllFilters()
        host.columnHeaderFilterMenuFiltersDidChange()
    }

    private func setComposition(_ composition: ColumnFilterComposition) {
        host.columnHeaderFilterMenu(setComposition: composition)
        host.columnHeaderFilterMenuFiltersDidChange()
    }

    /// Presents the "Column Filter" value-entry sheet for `columnId`/`op`,
    /// applying the resulting filter to the host on Apply.
    public func promptColumnFilter(columnId: String, displayName: String, op: FilterOperator) {
        guard let window = host.columnHeaderFilterMenuWindow else { return }

        let alert = NSAlert()
        alert.messageText = "Column Filter"
        alert.informativeText = "Enter a value for \(displayName) (\(op.rawValue))."
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = op == .between ? "min value" : "filter value"
        let excludeCheckbox = NSButton(checkboxWithTitle: "Exclude matching rows", target: nil, action: nil)
        excludeCheckbox.controlSize = .small

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 260, height: op == .between ? 78 : 50))
        stack.orientation = .vertical
        stack.spacing = 5
        stack.addArrangedSubview(field)
        var field2: NSTextField?
        if op == .between {
            let f2 = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            f2.placeholderString = "max value"
            stack.addArrangedSubview(f2)
            field2 = f2
        }
        stack.addArrangedSubview(excludeCheckbox)
        alert.accessoryView = stack

        let filterSet = host.columnHeaderFilterMenuFilterSet
        if let existing = filterSet.activeFilters.first(where: { $0.columnId == columnId && $0.op == op }) {
            field.stringValue = existing.value
            excludeCheckbox.state = existing.isInverted ? .on : .off
        }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return }

            let value2 = field2?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

            self.host.columnHeaderFilterMenu(
                replaceFilterFor: columnId,
                with: ColumnFilter(
                    columnId: columnId,
                    op: op,
                    value: value,
                    value2: value2,
                    isInverted: excludeCheckbox.state == .on
                )
            )
            self.host.columnHeaderFilterMenuFiltersDidChange()
        }
    }

    private func makeItem(_ title: String, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        return item
    }
}

/// An `NSMenuItem` that runs a closure instead of a target/action selector,
/// used internally by ``ColumnHeaderFilterMenu`` so no `@objc` shim methods
/// are needed on the host.
@MainActor
private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
    }

    convenience init(title: String, action: @escaping () -> Void) {
        self.init(title: title, handler: action)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler()
    }
}
