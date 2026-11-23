// BatchTableView+ViewMemory.swift - What a result table remembers of its view
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import AppKit
import LungfishWorkflow

/// The view fields of one ``BatchTableView`` that a person set.
///
/// A view's own state struct embeds one of these for each table it shows, so one part serves
/// every table class. The selection is held by stable row identity and never by index, and a
/// class that does not override ``BatchTableView/rowIdentity(for:)`` keeps no selection.
public struct BatchTableMemory: Codable, Sendable, Equatable {
    /// The first sort descriptor, by the column's sort key.
    public struct Sort: Codable, Sendable, Equatable {
        public var key: String
        public var ascending: Bool

        public init(key: String, ascending: Bool) {
            self.key = key
            self.ascending = ascending
        }
    }

    public var sort: Sort?
    public var columnFilters: ColumnFilterSet
    public var filterText: String
    /// The identities of the selected rows, in display order. Empty when nothing was selected,
    /// when the table has no row identity, or when the selection passed a cap of VS A9.
    public var selectedIdentities: [String]
    /// True when a selection existed and was dropped whole for its size (word 4).
    public var selectionTooLarge: Bool
    /// The identity of the row at the top of the scrolled table, nil while the table is not scrolled.
    public var topRowIdentity: String?

    public init(
        sort: Sort? = nil,
        columnFilters: ColumnFilterSet = ColumnFilterSet(),
        filterText: String = "",
        selectedIdentities: [String] = [],
        selectionTooLarge: Bool = false,
        topRowIdentity: String? = nil
    ) {
        self.sort = sort
        self.columnFilters = columnFilters
        self.filterText = filterText
        self.selectedIdentities = selectedIdentities
        self.selectionTooLarge = selectionTooLarge
        self.topRowIdentity = topRowIdentity
    }

    private enum CodingKeys: String, CodingKey {
        case sort, columnFilters, filterText, selectedIdentities, selectionTooLarge, topRowIdentity
    }

    /// Every field has a default, so a record written by an older build still reads.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sort = try container.decodeIfPresent(Sort.self, forKey: .sort)
        columnFilters = try container.decodeIfPresent(ColumnFilterSet.self, forKey: .columnFilters) ?? ColumnFilterSet()
        filterText = try container.decodeIfPresent(String.self, forKey: .filterText) ?? ""
        selectedIdentities = try container.decodeIfPresent([String].self, forKey: .selectedIdentities) ?? []
        selectionTooLarge = try container.decodeIfPresent(Bool.self, forKey: .selectionTooLarge) ?? false
        topRowIdentity = try container.decodeIfPresent(String.self, forKey: .topRowIdentity)
    }
}

/// What ``BatchTableView/applyViewMemory(_:dataChanged:)`` did, so the adopter can say which
/// parts were not kept (VS U2) and show the in-view line for a restored filter (word 5).
public struct BatchTableRestoreReport: Sendable, Equatable {
    public var sortRestored = false
    /// True when a column filter or the filter text was applied.
    public var filtersRestored = false
    /// True when a saved filter was not applied, because the data changed or its column is gone.
    public var filtersDropped = false
    /// What became of the saved selection, nil when none was saved.
    public var selection: ViewMemoryIdentityRestore?
    public var selectionTooLarge = false
    public var topRowRestored = false

    public init() {}

    /// True when a saved selection was lost in part or in whole, so "your selection" applies.
    public var selectionLost: Bool {
        selectionTooLarge || (selection?.lostAny ?? false)
    }
}

extension BatchTableView {
    /// Copies the view fields of this table. Cheap, main actor, and it reads no store or file.
    public func captureViewMemory() -> BatchTableMemory {
        var memory = BatchTableMemory()
        if let descriptor = tableView.sortDescriptors.first, let key = descriptor.key {
            memory.sort = BatchTableMemory.Sort(key: key, ascending: descriptor.ascending)
        }
        memory.columnFilters = columnFilterSet
        memory.filterText = currentFilterText

        let selectedIndexes = tableView.selectedRowIndexes
        if !selectedIndexes.isEmpty {
            var identities: [String] = []
            var everyRowHasAnIdentity = true
            for index in selectedIndexes {
                guard index >= 0, index < displayedRows.count,
                      let identity = rowIdentity(for: displayedRows[index]),
                      !identity.isEmpty
                else {
                    everyRowHasAnIdentity = false
                    break
                }
                identities.append(identity)
            }
            if everyRowHasAnIdentity {
                switch ViewMemoryRules.capSelection(identities) {
                case .kept(let kept):
                    memory.selectedIdentities = kept
                case .tooLarge:
                    memory.selectionTooLarge = true
                case .empty:
                    break
                }
            }
        }

        let originY = currentScrollOriginY
        if originY > 0 {
            let topIndex = tableView.row(at: NSPoint(x: 1, y: originY + 1))
            if topIndex > 0, topIndex < displayedRows.count,
               let identity = rowIdentity(for: displayedRows[topIndex]),
               !identity.isEmpty {
                memory.topRowIdentity = identity
            }
        }
        return memory
    }

    /// Applies remembered view fields to this table.
    ///
    /// Call it after ``configure(rows:)``, since the selection and the top row are matched
    /// against the rows on show. Called earlier it still restores the sort and the filters, and
    /// it selects nothing. The sort restores whenever its column exists. The column filters and
    /// the filter text restore only while `dataChanged` is false, as VS B6 requires, and a
    /// filter on a column the table no longer has is dropped. The selection restores by
    /// identity and keeps only the rows that still exist, and a table with no row identity
    /// restores no selection. A restored selection reaches the same callbacks as a pick does.
    /// Nothing here starts a tool, a write or a long load.
    @discardableResult
    public func applyViewMemory(_ memory: BatchTableMemory, dataChanged: Bool) -> BatchTableRestoreReport {
        var report = BatchTableRestoreReport()

        if let sort = memory.sort,
           tableView.tableColumns.contains(where: { $0.sortDescriptorPrototype?.key == sort.key }) {
            columnHeaderFilterMenu(sortByKey: sort.key, ascending: sort.ascending)
            report.sortRestored = true
        }

        if !memory.columnFilters.activeFilters.isEmpty || !memory.filterText.isEmpty {
            if dataChanged {
                report.filtersDropped = true
            } else {
                let knownColumns = Set(tableView.tableColumns.map { $0.identifier.rawValue })
                var usable = memory.columnFilters
                usable.filters.removeAll { filter in
                    let identifier = NSUserInterfaceItemIdentifier(filter.columnId)
                    return !knownColumns.contains(filter.columnId)
                        && !MetadataColumnController.isMetadataColumn(identifier)
                }
                if usable.filters.count < memory.columnFilters.filters.count {
                    report.filtersDropped = true
                }
                columnFilterSet = usable
                setFilterText(memory.filterText)
                report.filtersRestored = true
            }
        }

        report.selectionTooLarge = memory.selectionTooLarge
        let wantsSelection = !memory.selectedIdentities.isEmpty
        if wantsSelection || memory.topRowIdentity != nil {
            var indexByIdentity: [String: Int] = [:]
            for (index, row) in displayedRows.enumerated() {
                if let identity = rowIdentity(for: row), !identity.isEmpty, indexByIdentity[identity] == nil {
                    indexByIdentity[identity] = index
                }
            }
            if wantsSelection {
                let restore = ViewMemoryRules.keepIdentities(
                    memory.selectedIdentities,
                    existing: Set(indexByIdentity.keys)
                )
                report.selection = restore
                if !restore.isEmpty {
                    let indexes = IndexSet(restore.kept.compactMap { indexByIdentity[$0] })
                    tableView.selectRowIndexes(indexes, byExtendingSelection: false)
                }
            }
            if let top = memory.topRowIdentity, let index = indexByIdentity[top] {
                scrollRowToTop(index)
                report.topRowRestored = true
            }
        }
        return report
    }
}
