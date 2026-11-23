// TwelveSSurface+ViewMemory.swift - The 12S result viewer keeps its view for each result, the template of view memory
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The template a viewport copies to remember its view (`docs/contracts/analysis-surface-checklist.md`, section "View
// memory" in `Sources/LungfishKit/AGENTS.md`). One struct holds the view fields, the surface conforms to
// `ViewMemoryAdopting`, and the restore applies each field by its rule. Nothing here writes into the bundle or the
// project, and nothing here starts a tool, a write or a search (VS S4).

import AppKit
import LungfishIO
import LungfishKit

/// The view the 12S result viewer keeps for one result.
///
/// Each field and its class (VS B2 to B9):
/// - `filterText`, the viewport's filter field, is a search text (VS B6). It comes back only on an equal data key.
/// - `samples`, the samples the viewport's sample button chose, by id (VS B5). They are intersected with the result's
///   samples, and none left means every sample. The button shows a subset as "2 of 3 Samples", so the subset is
///   visible in the viewport and needs no filter line.
/// - `targetTable` holds the sort, which always comes back, the column filters, which come back only on an equal data
///   key (VS B6), the selection by `rowIdentity` (VS B4), never by index, and the top row by identity. Its own filter
///   text stays empty, since `filterText` holds it.
/// - `columnWidths`, the width of each target table column by id, is presentation and comes back for each column the
///   table still has.
///
/// The display filters that only the Inspector shows (minimum reads, taxon groups, human, alternates, unmatched
/// minimum and chimera status) are not kept, as VS B6 allows: the viewer cannot clear a filter line when the Inspector
/// changes them, and the Inspector would not show the restored values.
///
/// The type is public because `TwelveSSurface` and `ViewMemoryAdopting` are, and its fields stay internal.
public struct TwelveSViewState: ViewMemoryState {
    public static var kind: String { SurfaceKind.bundle(.twelveSResult).description }
    public static var schemaVersion: Int { 1 }

    var filterText: String
    var samples: SamplePickerMemory?
    var targetTable: BatchTableMemory
    var columnWidths: [String: Double]
    /// The metadata column layouts of the two tables, presentation that always comes back, held here and never in the
    /// account's defaults (VS A10). An older record without them decodes them as nil.
    var targetColumns: MetadataColumnLayoutMemory?
    var unresolvedColumns: MetadataColumnLayoutMemory?

    /// A selection the table part already found past its cap counts as past the store's cap, so the store drops it
    /// whole and the viewer says so (VS A9, word 4).
    public var selectionCount: Int {
        targetTable.selectionTooLarge ? Int.max : targetTable.selectedIdentities.count
    }

    public func withoutSelection() -> TwelveSViewState {
        var view = self
        view.targetTable.selectedIdentities = []
        view.targetTable.selectionTooLarge = false
        return view
    }
}

extension TwelveSSurface: ViewMemoryAdopting {
    /// Reads where the result lives and its data key once, in `load`, and stores both in `viewMemoryItem` and
    /// `viewMemoryDataKey`, so a capture and a restore read only memory. A surface whose load runs off the main actor
    /// reads `ViewMemoryItem.read(at:)` there, which is what a family lane copies. The 12S route reads the whole result
    /// on the main actor before the show (`MainSplitViewController+ContentDisplay.swift`) and this load cannot suspend,
    /// so 12S reads the item's few file attributes on the main actor, once a show (SWIFT ruling R2).
    ///
    /// The data key of VS B1 is the manifest's output name and date with the size and modification time of each
    /// result table, which the viewer read when the result opened (`heldResultStamp`). A rerun or an edit of a table
    /// changes it, a metadata import does not, and a table that could not be read leaves the key unread.
    func readViewMemoryIdentity(of result: TwelveSAmpliconResultBundleData) {
        viewMemoryItem = ViewMemoryItem.read(at: result.bundleURL)
        viewMemoryDataKey = Self.viewMemoryDataKey(of: result, stamp: controller.heldResultStamp)
    }

    static func viewMemoryDataKey(of result: TwelveSAmpliconResultBundleData, stamp: [String]) -> String? {
        let unread = stamp.contains { $0.hasSuffix(" missing") || $0.contains(" missing ") }
        guard !stamp.isEmpty, !unread else { return nil }
        let manifest = result.manifest
        return (["12S v1", manifest.outputName, manifest.createdAt ?? "no date"] + stamp).joined(separator: "\n")
    }

    /// The view as the viewer's controls hold it now. It reads no file and no store.
    public func captureViewMemory() -> TwelveSViewState {
        var table = controller.targetTable.captureViewMemory()
        table.filterText = ""
        let columns = controller.targetTable.tableView.tableColumns
        return TwelveSViewState(
            filterText: controller.displayState.filterText,
            samples: controller.samplePickerState?.captureViewMemory(allSampleIDs: controller.allSampleIDs),
            targetTable: table,
            columnWidths: Dictionary(columns.map { ($0.identifier.rawValue, Double($0.width)) }) { first, _ in first },
            targetColumns: controller.targetTable.metadataColumns.captureViewMemory(),
            unresolvedColumns: controller.unresolvedTable.metadataColumns.captureViewMemory()
        )
    }

    /// Applies a kept view, each field by its rule, through the same paths a person's change takes, and starts
    /// nothing. The route wires the Inspector after this runs, so `announceViewMemory()` tells it the view.
    public func restoreViewMemory(_ state: TwelveSViewState, dataChanged: Bool) -> ViewMemoryLoss {
        var lost: ViewMemoryLoss = []
        if let samples = state.samples, let picker = controller.samplePickerState {
            let restore = picker.applyViewMemory(samples, currentSampleIDs: controller.allSampleIDs)
            controller.selectedSamples = restore.selected
            controller.updateSampleFilterButtonTitle()
            if restore.droppedCount > 0 || (restore.fellBackToAll && !samples.wasAllSamples) {
                lost.insert(.sampleChoice)
            }
        }

        let table = controller.targetTable
        if !dataChanged, state.targetTable.columnFilters.activeFilters.isEmpty {
            // Reset View hands back the starting view, whose empty filters the table part leaves alone. They clear
            // before `applyDisplayState` runs its one pass, which redraws the rows, the column marks and the count.
            table.columnFilterSet = state.targetTable.columnFilters
        }
        var display = controller.displayState
        display.filterText = dataChanged ? "" : state.filterText
        if dataChanged, !state.filterText.isEmpty { lost.insert(.filters) }
        controller.applyDisplayState(display)
        controller.rebuildSampleColumns()
        // The layouts before the widths, which then size each column the table holds.
        table.metadataColumns.applyKeptLayout(state.targetColumns)
        controller.unresolvedTable.metadataColumns.applyKeptLayout(state.unresolvedColumns)

        for column in table.tableView.tableColumns {
            if let width = state.columnWidths[column.identifier.rawValue] { column.width = CGFloat(width) }
        }
        var tableView = state.targetTable
        tableView.filterText = display.filterText
        if tableView.selectedIdentities.isEmpty, !table.tableView.selectedRowIndexes.isEmpty {
            table.tableView.deselectAll(nil)
        }
        let report = table.applyViewMemory(tableView, dataChanged: dataChanged)
        if report.filtersDropped { lost.insert(.filters) }
        if report.selection?.lostAny == true { lost.insert(.selection) }
        return lost
    }

    /// Sends the Inspector the filters, the row count and the selected row's Detail through the viewer's own
    /// callbacks. The host calls it after the route wired them (SWIFT SF-1). A selected row reads its species'
    /// reference sequences off the main actor and moves the Inspector to its Detail tab, as a click does (SWIFT R8).
    public func announceViewMemory() {
        controller.onDisplayStateChanged?(controller.displayState)
        controller.notifyDisplaySummaryChanged()
        let selected = controller.targetTable.selectedRowsByIdentity()
        if !selected.isEmpty { controller.handleTargetSelection(selected) }
    }
}
