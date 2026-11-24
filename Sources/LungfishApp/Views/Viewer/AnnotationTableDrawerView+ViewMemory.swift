// AnnotationTableDrawerView+ViewMemory.swift - The reference viewer's drawer keeps its tab and its row (VS-MAP-2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane VS-MAP-2 item 1 (VS B4, VS-MAP BIO R1). The drawer's tab is presentation and restores on any data key. Its one
// selected row restores by `trackId`, row id, name, chromosome, start and end, never by index, and only after the
// drawer's rows load; a row that no longer matches is dropped. Both ride in the viewer's record
// (`ReferenceViewerMemory.drawer`), so the item keeps one record with one writer (VS-REF Finding 5).

import AppKit
import LungfishWorkflow

/// A drawer row by its identity (VS B4, `AnnotationSearchResult.swift:9-45`).
struct ReferenceDrawerRow: Codable, Sendable, Equatable {
    var trackId: String
    var rowId: Int64?
    var name: String
    var chromosome: String
    var start: Int
    var end: Int

    init(_ result: AnnotationSearchResult) {
        trackId = result.trackId
        rowId = result.annotationRowId ?? result.variantRowId
        name = result.name
        chromosome = result.chromosome
        start = result.start
        end = result.end
    }
}

/// The drawer's kept view: its tab and its one selected row.
struct ReferenceDrawerMemory: Codable, Sendable, Equatable {
    var tab: Int
    var row: ReferenceDrawerRow?
}

extension AnnotationTableDrawerView {
    /// The tab and the one selected row as they stand, nil at the default (the annotations tab with no row), so a visit
    /// that only opened the drawer keeps nothing (VS S3). A multiple selection keeps no row.
    var keptViewMemory: ReferenceDrawerMemory? {
        let selected = tableView.selectedRowIndexes
        let showsRows = activeTab != .samples && !(activeTab == .variants && activeVariantSubtab == .genotypes)
        let row = selected.count == 1 && showsRows ? selected.first.flatMap { index in
            index < displayedAnnotations.count ? ReferenceDrawerRow(displayedAnnotations[index]) : nil
        } : nil
        guard activeTab != .annotations || row != nil else { return nil }
        return ReferenceDrawerMemory(tab: activeTab.rawValue, row: row)
    }

    /// The drawer's rows loaded or changed (`updateCountLabel`), so the viewer may restore a kept row now.
    func viewMemoryRowsDidLoad() {
        (delegate as? ViewerViewController)?.restorePendingDrawerMemory(in: self)
    }

    /// Selects the row whose identity is `row` among the rows on show, as a restore: no delegate call, so it starts
    /// nothing (VS S4). Returns false when no row matches.
    func selectViewMemoryRow(_ row: ReferenceDrawerRow) -> Bool {
        guard let index = displayedAnnotations.firstIndex(where: { ReferenceDrawerRow($0) == row }) else { return false }
        isSuppressingDelegateCallbacks = true
        defer { isSuppressingDelegateCallbacks = false }
        tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        tableView.scrollRowToVisible(index)
        return true
    }
}

extension ViewerViewController {
    /// Restores the kept drawer view once the drawer's rows have loaded (VS-MAP BIO R1): the tab first, then the row
    /// by identity. A person's pick in the drawer first stays. A row that no longer matches is dropped, and only a
    /// changed data key says so (word 2, LESSONS 11).
    func restorePendingDrawerMemory(in drawer: AnnotationTableDrawerView) {
        guard let session = viewMemory, let kept = session.pendingDrawer, drawer === annotationDrawerView,
              !session.restoringDrawer, !drawer.isLoading else { return }
        session.restoringDrawer = true
        defer { session.restoringDrawer = false }
        if drawer.activeTab.rawValue != kept.tab, let tab = AnnotationTableDrawerView.DrawerTab(rawValue: kept.tab) {
            drawer.switchToTab(tab)
        }
        guard let row = kept.row, drawer.tableView.selectedRowIndexes.isEmpty else {
            session.pendingDrawer = nil
            return
        }
        guard !drawer.displayedAnnotations.isEmpty else { return } // its rows have not loaded yet
        session.pendingDrawer = nil
        if !drawer.selectViewMemoryRow(row), session.drawerKeyChanged,
           let words = ViewMemoryWords.dataChanged(session.restoredLoss.union(.selection)) {
            showViewMemoryLine(words, in: session)
        }
    }
}
