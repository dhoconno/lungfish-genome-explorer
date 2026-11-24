// TaxTriageResultViewController+ViewMemory.swift - The TaxTriage viewer keeps its view for each result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The route configures the viewer from its database before the show, and the rows come in pages after it, so the
// restore is late (VS A2): when the open's first page is in, and before the open selects its top row, the viewer runs
// the surface's late restore, which applies the kept view only while the view still equals the one the database opened
// with. Nothing in this file writes into the result or the project, and nothing starts a tool, a write or a search (VS S4).

import AppKit
import CryptoKit
import LungfishIO
import LungfishKit

/// One token for this run of the app. A subset of several samples, which neither the segmented control nor the pop-up
/// can show, comes back only inside the run that kept it, since its picker shows only in the Inspector (VS B5).
enum TaxTriageViewMemoryRun {
    static let token = UUID().uuidString
}

/// A row identity without the result's path, so a moved project keeps its rows (VS A3, B4). The batch table's identity
/// is the tool, the result's path, then the sample, the tax id, the rank and the organism.
enum TaxTriageRowIdentity {
    static let separator = "\u{1F}"

    static func portable(_ identity: String) -> String {
        var parts = identity.components(separatedBy: separator)
        if parts.count > 1 { parts[1] = "result" }
        return parts.joined(separator: separator)
    }
}

/// The view the TaxTriage viewer keeps for one result. Each field and its class (VS B2 to B9):
/// - `samples`, the sample filter by sample id (VS B5), never `selectedSampleIndex`, intersected with the result's
///   samples. Every sample or one sample shows in the viewport's segmented control or pop-up, so it comes back after a
///   relaunch too. A subset of several shows only in the Inspector, so it comes back only in the run that kept it
///   (`samplesRun`).
/// - `overview`, the "All Samples" grid in place of the list (the batch facet), is presentation.
/// - `searchText`, the "Filter organisms..." field, is a search text (VS B6). It comes back only on an equal data key, and
///   the field shows it, so no filter line is needed.
/// - `table`, the batch table's sort (presentation) and its column filters (VS B6, dropped on a changed key, marked on
///   the column titles). Its selection is not used: the selection is the next field.
/// - `selectedIdentities`, the selected rows by the batch table's identity, which carries the sample (VS B4), without the
///   result's path. A row that no longer exists is dropped, never replaced by the top row, and a loss is reported only
///   on a changed data key (lesson 11). A view kept with no row selected leaves the open's top-row pick.
/// - `columns`, the batch table's metadata column layout, is presentation and lives here, never in the account's
///   defaults (VS A10).
/// The divider is not kept: the alignment pane opens and shuts with the selected row's alignment file.
struct TaxTriageViewMemory: Codable, Sendable, Equatable {
    var samples: SamplePickerMemory?
    var samplesRun: String?
    var overview = false
    var searchText = ""
    var table: BatchTableMemory?
    var selectedIdentities: [String] = []
    var columns: MetadataColumnLayoutMemory?
}

/// What one viewer holds for its visit: the open's table, the late restore the surface waits on, the rows the restore
/// selects once they show and the sidebar route's sample (VS B9).
@MainActor
final class TaxTriageVisitMemo {
    var keepsView = false
    var dataKey: String?
    var openingTable: BatchTableMemory?
    var onFirstPage: ((TaxTriageViewMemory) -> Void)?
    var waitingStart: TaxTriageViewMemory?
    var firstPageLanded = false
    var loadComplete = false
    var reloadedByRestore = false
    /// The portable identities the restore selects once their rows show, empty when every kept row is gone (no row, never
    /// the top row), nil when no restore waits and the open's top-row pick stands.
    var pendingSelection: [String]?
    var routedSample: String?
    var samplesBeforeRoute: SamplePickerMemory?
    /// The rows kept for the picker the route replaced. A capture keeps them while the route's pick stands (VS B9).
    var selectionBeforeRoute: [String] = []
    /// Reset View ran before the open's first page, so the late restore brings nothing back (VS A2, the reset side).
    var resetBeforeFirstPage = false

    private static let registry = NSMapTable<TaxTriageResultViewController, TaxTriageVisitMemo>.weakToStrongObjects()

    static func memo(for controller: TaxTriageResultViewController) -> TaxTriageVisitMemo {
        if let memo = registry.object(forKey: controller) { return memo }
        let memo = TaxTriageVisitMemo()
        registry.setObject(memo, forKey: controller)
        return memo
    }
}

extension TaxTriageResultViewController {
    /// A viewer whose view is kept for its result. Its tables declare view memory before any key is set, so they write
    /// no column layout to the account's defaults (VS A10).
    public static func keepingViewMemory() -> TaxTriageResultViewController {
        let controller = TaxTriageResultViewController()
        controller.batchFlatTableView.metadataColumns.adoptViewMemory()
        controller.organismTableView.metadataColumns.adoptViewMemory()
        TaxTriageVisitMemo.memo(for: controller).keepsView = true
        return controller
    }

    /// The result folder the view's memory belongs to. Nil keeps nothing.
    var viewMemoryFolderURL: URL? { batchGroupURL }

    /// Whether the open's first page is in and no restored row waits for its page.
    var viewMemoryIsSettled: Bool {
        let memo = TaxTriageVisitMemo.memo(for: self)
        return memo.firstPageLanded && memo.pendingSelection == nil
    }

    /// The data key of VS B1: the run record the database holds, the `created_at` that `build-db` writes, and one digest
    /// of the samples with their organism counts (lesson 5). A database without a record keys as "no run". The metadata
    /// table is read once, in the surface's load, on the main actor where the route has just read the samples (SWIFT
    /// ruling R2). A part not read gives nil, which never compares equal.
    func viewMemoryDataKey() -> String? {
        guard let database = taxTriageDatabase, !sampleEntries.isEmpty,
              let metadata = try? database.fetchMetadata() else { return nil }
        let samples = sampleEntries.map { "\($0.id)=\($0.organismCount)" }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(samples.utf8)).map { String(format: "%02x", $0) }.joined()
        return ["taxtriage v1", "built \(metadata["created_at"] ?? "no run")", "samples \(digest)"].joined(separator: "\n")
    }

    /// The table's sort and filters as the open set them, read in the surface's load before any person's change.
    func noteOpeningView() {
        TaxTriageVisitMemo.memo(for: self).openingTable = tableMemoryWithoutSelection()
    }

    private func tableMemoryWithoutSelection() -> BatchTableMemory {
        var table = batchFlatTableView.captureViewMemory()
        table.selectedIdentities = []
        table.selectionTooLarge = false
        table.topRowIdentity = nil
        return table
    }

    /// The portable identities of the selected rows, in row order.
    private func selectedPortableIdentities() -> [String] {
        let table = batchFlatTableView
        let rows = table.displayedRows
        return table.tableView.selectedRowIndexes.compactMap { index -> String? in
            guard index < rows.count, let identity = table.rowIdentity(for: rows[index]) else { return nil }
            return TaxTriageRowIdentity.portable(identity)
        }
    }

    /// The selection a capture keeps now. The rows a restore still waits to select stand in for the table's own only
    /// while the shown list holds no selection or the grid hides the list, so a marker that no page or list return
    /// will clear never hides a row the shown list holds.
    private func keptSelection() -> [String] {
        let live = selectedPortableIdentities()
        guard let pending = TaxTriageVisitMemo.memo(for: self).pendingSelection else { return live }
        return live.isEmpty || batchFlatTableView.isHidden ? pending : live
    }

    /// The view as the viewer's controls hold it now. It reads no file and no store.
    func captureTaxTriageViewMemory() -> TaxTriageViewMemory {
        let memo = TaxTriageVisitMemo.memo(for: self)
        var memory = TaxTriageViewMemory()
        var routePickStands = false
        if let picker = samplePickerState, !sampleIds.isEmpty {
            var picked = picker.captureViewMemory(allSampleIDs: Set(sampleIds))
            // The route's pick is the app's, not a choice, unless the person changed it afterwards (VS B9).
            if let routed = memo.routedSample, picked.selectedSampleIDs == [routed], let before = memo.samplesBeforeRoute {
                picked = before
                routePickStands = true
            }
            memory.samples = picked
            memory.samplesRun = TaxTriageViewMemoryRun.token
        }
        memory.overview = isShowingDatabaseOverview
        // The field's text, which a person may have typed before its short wait applies it.
        memory.searchText = organismSearchField.stringValue
        memory.table = tableMemoryWithoutSelection()
        // While the route's pick stands, the rows kept are those of the picker it replaced (VS B9).
        memory.selectedIdentities = routePickStands ? memo.selectionBeforeRoute : keptSelection()
        memory.columns = batchFlatTableView.metadataColumns.captureViewMemory()
        return memory
    }

    /// The view the database opens with: every sample, the list, no search, the table as the open set it, no row selected
    /// yet and the columns as they stand. A person's change before the late restore differs from it, so the restore does
    /// not run over it (VS A2).
    func databaseStartingViewMemory() -> TaxTriageViewMemory {
        var start = TaxTriageViewMemory()
        if samplePickerState != nil, !sampleIds.isEmpty {
            start.samples = SamplePickerMemory(selectedSampleIDs: sampleIds.sorted(), wasAllSamples: true)
            start.samplesRun = TaxTriageViewMemoryRun.token
        }
        start.table = TaxTriageVisitMemo.memo(for: self).openingTable
        start.columns = batchFlatTableView.metadataColumns.captureViewMemory()
        return start
    }

    /// Each page of the rows ends here. The open's first page runs the surface's late restore once, before the open's
    /// top row is selected, and then the restored rows are selected once they show, in place of the top row.
    func finishDatabasePage(complete: Bool) {
        let memo = TaxTriageVisitMemo.memo(for: self)
        memo.loadComplete = complete
        if memo.keepsView, !memo.firstPageLanded {
            memo.firstPageLanded = true
            let start = databaseStartingViewMemory()
            if let apply = memo.onFirstPage {
                apply(start)
                // A reset before this page stood over the late restore, whether or not the restore ran.
                memo.resetBeforeFirstPage = false
            } else {
                memo.waitingStart = start
            }
            if memo.reloadedByRestore {
                // The restore asked for the kept samples or search, so this page is of the open's rows, not the view's.
                memo.reloadedByRestore = false
                return
            }
        }
        guard memo.pendingSelection != nil else {
            selectTopDatabaseRowAfterInitialPageIfNeeded()
            return
        }
        selectRestoredRowsIfShown()
    }

    /// Selects the rows a restore kept once every one of them shows, or once the last page is in, in place of the open's
    /// top row. A restore that lands after the first page selects them now.
    func selectRestoredRowsIfShown(afterLateRestore: Bool = false) {
        let memo = TaxTriageVisitMemo.memo(for: self)
        if afterLateRestore {
            guard !memo.reloadedByRestore else { memo.reloadedByRestore = false; return }
            // No row waits, so the top row the first page selected stands, and no later page selects it again.
            guard memo.pendingSelection != nil else { return }
            shouldSelectTopDatabaseRowAfterLoad = true
        }
        guard let pending = memo.pendingSelection else { return }
        let complete = memo.loadComplete
        guard shouldSelectTopDatabaseRowAfterLoad, !isDatabaseOverviewVisible else { return }
        let table = batchFlatTableView
        var indexByIdentity: [String: Int] = [:]
        for (index, row) in table.displayedRows.enumerated() {
            guard let identity = table.rowIdentity(for: row) else { continue }
            let portable = TaxTriageRowIdentity.portable(identity)
            if indexByIdentity[portable] == nil { indexByIdentity[portable] = index }
        }
        let found = pending.compactMap { indexByIdentity[$0] }
        // A kept row on a later page waits for it.
        guard found.count == pending.count || complete else { return }
        memo.pendingSelection = nil
        shouldSelectTopDatabaseRowAfterLoad = false
        guard let first = found.min() else { return }
        // The same path as a pick, so Extract, Export and BLAST act on the rows shown selected (lesson 8).
        table.tableView.selectRowIndexes(IndexSet(found), byExtendingSelection: false)
        table.tableView.scrollRowToVisible(first)
    }

    /// Applies a kept view, each field by its rule, through the paths a person's change takes, and returns what it could
    /// not bring back. The samples and the search reload the rows once, and the kept rows are selected as their page
    /// comes in, in place of the open's top row, so the restore starts no load the open would not (VS S4).
    func applyTaxTriageViewMemory(_ memory: TaxTriageViewMemory, dataChanged: Bool) -> ViewMemoryLoss {
        var lost: ViewMemoryLoss = []
        let memo = TaxTriageVisitMemo.memo(for: self)
        guard let picker = samplePickerState else { return lost }
        let all = Set(sampleIds)
        var reload = false
        if let saved = memory.samples, !all.isEmpty,
           saved.wasAllSamples || saved.selectedSampleIDs.count == 1 || memory.samplesRun == TaxTriageViewMemoryRun.token {
            let restore = ViewMemoryRules.restoreSamples(
                saved: saved.selectedSampleIDs, savedWasAllSamples: saved.wasAllSamples, current: all
            )
            if restore.droppedCount > 0 || restore.fellBackToAll { lost.insert(.sampleChoice) }
            if memo.routedSample != nil {
                // The route's sample wins for this visit, and the kept choice is what the next visit keeps (VS B9).
                memo.samplesBeforeRoute = SamplePickerMemory(
                    selectedSampleIDs: restore.selected.sorted(), wasAllSamples: restore.selected == all
                )
            } else if restore.selected != picker.selectedSamples {
                picker.selectedSamples = restore.selected
                reload = true
            }
        }
        if memo.routedSample == nil {
            isShowingDatabaseOverview = memory.overview && picker.selectedSamples.count > 1
        }
        batchFlatTableView.metadataColumns.applyKeptLayout(memory.columns)
        if let table = memory.table, batchFlatTableView.applyViewMemory(table, dataChanged: dataChanged).filtersDropped {
            lost.insert(.filters)
        }

        let search = dataChanged ? "" : memory.searchText
        if dataChanged, !memory.searchText.isEmpty { lost.insert(.filters) }
        if search != organismSearchText { reload = true }
        organismSearchField.stringValue = search
        organismSearchText = search

        var kept = memory.selectedIdentities
        if dataChanged, memo.loadComplete, !kept.isEmpty {
            // The open's rows are all in, so a kept row that is not among them is gone from the changed data.
            let existing = Set(allBatchGroupRows.compactMap {
                batchFlatTableView.rowIdentity(for: $0).map(TaxTriageRowIdentity.portable)
            })
            let restore = ViewMemoryRules.keepIdentities(kept, existing: existing)
            if restore.droppedCount > 0 { lost.insert(.selection) }
            kept = restore.kept
        }
        if memo.routedSample != nil {
            // The route's sample wins for this visit (VS B9): the kept rows belong to the picker the route replaced, so
            // they wait for the visit that brings it back, and the open's own pick stands.
            memo.selectionBeforeRoute = kept
            memo.pendingSelection = nil
        } else {
            // A kept view with no row leaves the open's top-row pick standing, as a batch table's restore does. Only kept
            // rows that are all gone select nothing in its place (VS B4). So a restore that reloads no page, such as
            // Reset View, leaves no empty marker for a later page to take.
            memo.pendingSelection = memory.selectedIdentities.isEmpty ? nil : kept
        }
        if reload {
            memo.reloadedByRestore = true
            applyBatchGroupFilter()
        }
        syncSampleFilterControlToPickerState()
        applyDatabaseOverviewPresentation()
        return lost
    }

    /// The sidebar route's sample (VS B9). It sets the picker as the route always did, and notes the picker the visit
    /// had before, so a capture that still finds the route's pick keeps that picker and not the route's.
    public func selectSampleFromRoute(_ sampleId: String) {
        let memo = TaxTriageVisitMemo.memo(for: self)
        if memo.routedSample == nil, let picker = samplePickerState {
            memo.samplesBeforeRoute = picker.captureViewMemory(allSampleIDs: Set(sampleIds))
            memo.selectionBeforeRoute = keptSelection()
            memo.pendingSelection = nil
        }
        memo.routedSample = sampleId
        samplePickerState?.selectedSamples = [sampleId]
    }
}
