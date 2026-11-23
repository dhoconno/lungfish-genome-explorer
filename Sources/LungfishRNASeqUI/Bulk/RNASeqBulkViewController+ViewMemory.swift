// RNASeqBulkViewController+ViewMemory.swift - The bulk view keeps its gene search, its tab and its selected genes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The bulk child's part of the RNA-seq result's view memory (`RNASeqResultSurface+ViewMemory.swift`). It reads only the
// controls and the injected model, and its restore goes through the paths a person's typing, tab click and row click
// take. Nothing here writes, reads a file or starts a read (VS S4).

import AppKit
import LungfishKit

/// What the bulk view keeps for one result. Each field and its class (VS B2 to B9):
/// - `search`, the "Search genes by id or name" field, is a search text that hides gene rows (VS B6). It comes back only
///   on an equal data key, and it shows in the viewport, in its field and in the "<n> of <m> genes match" line beside
///   it, so it needs no filter line (word 5). A changed key drops it, which is "your filters".
/// - `tab`, the tab on show, is presentation. A count table's tab is kept by the table's path in the result and the
///   other two by their names, never by a tab's place, and a tab that is gone opens the first.
/// - `selected` holds each count table's selected rows by feature id, never by index (VS B4), and comes back for each
///   id the table still shows. The count tables have no sort, so no sort is kept.
struct RNASeqBulkViewMemory: Codable, Sendable, Equatable {
    var search: String
    var tab: String?
    var selected: [String: [String]]
    /// True when the selection passed the cap of VS A9 and was dropped whole (word 4).
    var selectionTooLarge: Bool

    var selectionCount: Int {
        selectionTooLarge ? Int.max : selected.values.reduce(0) { $0 + $1.count }
    }
}

extension RNASeqBulkViewController {
    static let countTabPrefix = "rnaseq-bulk-tab-"

    /// The view as the controls hold it. It reads no file and no store.
    func captureViewMemory() -> RNASeqBulkViewMemory {
        var selected: [String: [String]] = [:]
        for (index, table) in countTables.enumerated() where index < model.tables.count {
            let shown = model.tables[index]
            let ids = table.selectedRowIndexes.compactMap { row in
                row < shown.visibleRows.count ? shown.table.rows[shown.visibleRows[row]].id : nil
            }
            if !ids.isEmpty { selected[shown.path] = ids }
        }
        var tooLarge = false
        if case .tooLarge = ViewMemoryRules.capSelection(selected.keys.sorted().flatMap { selected[$0] ?? [] }) {
            selected = [:]
            tooLarge = true
        }
        return RNASeqBulkViewMemory(search: model.searchText, tab: tabName(of: tabView.selectedTabViewItem),
                                    selected: selected, selectionTooLarge: tooLarge)
    }

    /// Applies a kept view: the search on an equal key, then the tab, then each table's rows by feature id. It returns
    /// what it lost. A view the kept one does not hold, such as the start that Reset View hands back, clears the search
    /// and the selection.
    func restoreViewMemory(_ memory: RNASeqBulkViewMemory, dataChanged: Bool) -> ViewMemoryLoss {
        _ = view
        var lost: ViewMemoryLoss = []
        let search = dataChanged ? "" : memory.search
        if dataChanged, !memory.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { lost.insert(.filters) }
        if model.searchText != search {
            model.search(search)
            reloadFromModel()
        }
        // Rows are picked while their tab still shows, as a person picks them, and the tab comes after.
        for (index, table) in countTables.enumerated() where index < model.tables.count {
            let shown = model.tables[index]
            var rowOfID: [String: Int] = [:]
            for (row, line) in shown.visibleRows.enumerated() where rowOfID[shown.table.rows[line].id] == nil {
                rowOfID[shown.table.rows[line].id] = row
            }
            let restore = ViewMemoryRules.keepIdentities(memory.selected[shown.path] ?? [], existing: Set(rowOfID.keys))
            if restore.lostAny { lost.insert(.selection) }
            table.selectRowIndexes(IndexSet(restore.kept.compactMap { rowOfID[$0] }), byExtendingSelection: false)
        }
        if let item = tabView.tabViewItems.first(where: { tabName(of: $0) == memory.tab }) ?? tabView.tabViewItems.first {
            tabView.selectTabViewItem(item)
        }
        let paths = Set(model.tables.map(\.path))
        if memory.selected.keys.contains(where: { !paths.contains($0) }) { lost.insert(.selection) }
        return lost
    }

    /// Selects the kept genes again in each table that shows none. A table the restore filled before it ever showed in
    /// a window can drop its selection at the model's next reload, so the surface calls this once the route has
    /// installed it (`announceViewMemory`). A table with a selection of its own is left as it is.
    func reselectKeptRows(_ memory: RNASeqBulkViewMemory) {
        for (index, table) in countTables.enumerated() where index < model.tables.count && table.selectedRowIndexes.isEmpty {
            let shown = model.tables[index]
            let wanted = Set(memory.selected[shown.path] ?? [])
            guard !wanted.isEmpty else { continue }
            let rows = shown.visibleRows.enumerated().filter { wanted.contains(shown.table.rows[$0.element].id) }.map(\.offset)
            table.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
        }
    }

    /// A tab's name that survives a rebuild: a count table's path, or the id of the quality or correlation tab.
    func tabName(of item: NSTabViewItem?) -> String? {
        guard let id = item?.identifier as? String else { return nil }
        if id.hasPrefix(Self.countTabPrefix), let index = Int(id.dropFirst(Self.countTabPrefix.count)),
           model.tables.indices.contains(index) {
            return "counts " + model.tables[index].path
        }
        return id
    }
}
