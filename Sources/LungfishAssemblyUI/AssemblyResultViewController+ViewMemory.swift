// AssemblyResultViewController+ViewMemory.swift - The assembly result viewer keeps its contig table's view for each result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// One struct holds the view fields, `AssemblyResultSurface` adopts `ViewMemoryAdopting`, and the contig table applies
// them through VS-PARTS's table part. The contigs load in the viewer's own task after `load` returns, so the host hands
// a handle and the kept view applies when that load commits, only while the view is still as the load left it (VS A2).
// Nothing here writes into the result or the project, and nothing starts a tool, a search or a write (VS S4).

import AppKit
import LungfishKit
import LungfishWorkflow

extension AssemblyResultSurface {
    /// The view the assembly result viewer keeps for one result, one type for the five assembler kinds.
    ///
    /// Each field and its class (VS B2 to B9):
    /// - `table` holds the contig table's sort, which comes back whenever its column exists, its filter text and
    ///   column filters, which come back only on an equal data key (VS B6) and show in the table's own filter field and
    ///   column marks, the selected contigs by name (VS B4), never by index, and the top row by name. A restored
    ///   selection reaches the table's callbacks as a pick does, so Extract, Export and BLAST read those contigs.
    /// - `contigColumns`, the metadata column layout, is presentation that always comes back, held here and never in
    ///   the account's defaults (VS A10).
    ///
    /// - `divider`, the divider between the detail pane and the table as the person left it, in the layout they left
    ///   it in, is presentation and always comes back. Nil means where the viewer places it. The pane shows only once a
    ///   selected contig's own read ends, so the divider takes its kept place then, as the viewer's default would.
    ///
    /// The type is public because the surface and `ViewMemoryAdopting` are, and its fields stay internal. It is nested,
    /// so the module's list of public types does not change.
    public struct ViewState: ViewMemoryState {
        public static var kind: String { "analysis.assembly" }
        public static var schemaVersion: Int { 1 }

        var table = BatchTableMemory()
        var contigColumns: MetadataColumnLayoutMemory?
        var divider: Divider?

        /// The divider's share of the split in one panel layout (`AssemblyPanelLayout`), since the same share puts the
        /// divider elsewhere when the detail pane and the table trade places or stack.
        public struct Divider: Codable, Sendable, Equatable {
            var layout: String
            var position: SplitPositionMemory
        }

        /// A selection the table part found past its cap counts as past the store's cap (VS A9, word 4).
        public var selectionCount: Int { table.selectionTooLarge ? Int.max : table.selectedIdentities.count }

        public func withoutSelection() -> ViewState {
            var view = self
            view.table.selectedIdentities = []
            view.table.selectionTooLarge = false
            return view
        }
    }
}

extension AssemblyResultSurface: ViewMemoryAdopting {
    /// The contigs load in the viewer's own task after `load` returns.
    public var viewMemoryLoadIsPending: Bool { true }

    /// Reads where the result lives once, in `load`. The App configures the viewer in the show and this load cannot
    /// suspend, so the folder's few attributes are read on the main actor, once a show, as SWIFT ruling R2 allows.
    func readViewMemoryItem(of result: AssemblyResult) {
        viewMemoryItem = ViewMemoryItem.read(at: result.outputDirectory)
    }

    /// Applies the kept view once the contigs the load read are in the table, under that load's own task: a later
    /// configure replaces the task and a removal cancels it, and a load that failed applies nothing, so the visit
    /// keeps what the store holds. The data key of VS B1 is the tool with the contigs file's size, date and file
    /// number, which the load read (`heldContigsStamp`), so a rerun or an edit of the contigs changes it.
    func applyKeptViewWhenTheContigsLoad(_ viewer: AssemblyResultViewController) {
        // A divider an earlier visit restored is not this visit's, so the view as the load leaves it has none.
        AssemblyKeptDivider.of(viewer).restored = nil
        guard let task = viewer.loadTask else { return }
        Task { @MainActor [weak self, weak viewer] in
            await task.value
            guard let self, let viewer, self.controller === viewer, viewer.loadTask == task, !task.isCancelled,
                  let result = viewer.currentResult else { return }
            let noContigs = result.outcome == .completedWithNoContigs ? ["no contigs"] : nil
            guard let stamp = viewer.heldContigsStamp ?? noContigs else { return }
            self.viewMemoryDataKey = (["Assembly v1", result.tool.rawValue] + stamp).joined(separator: "\n")
            // The view as the load leaves it: no sort, filter or selection, and the column layout it has. A person's
            // sort or pick made while the contigs read differs from it, so it stays and the kept view does not apply.
            let loaded = ViewState(contigColumns: viewer.contigTableView.metadataColumns.captureViewMemory())
            self.viewMemoryHandle?.applyPending(startingView: loaded)
        }
    }

    /// The view as the contig table's controls hold it now. It reads no file and no store.
    public func captureViewMemory() -> ViewState {
        guard let controller else { return ViewState() }
        let table = controller.contigTableView
        return ViewState(
            table: table.captureViewMemory(), contigColumns: table.metadataColumns.captureViewMemory(),
            divider: controller.dividerToKeep())
    }

    /// Applies a kept view, each field by its rule, and returns what it could not bring back.
    public func restoreViewMemory(_ state: ViewState, dataChanged: Bool) -> ViewMemoryLoss {
        guard let controller else { return [] }
        let table = controller.contigTableView
        table.metadataColumns.applyKeptLayout(state.contigColumns)
        // Before the selection, whose read shows the detail pane, so the pane takes the kept divider as it opens.
        controller.restoreDivider(state.divider)
        // Reset View hands back the starting view, whose empty sort and filters the table part leaves alone.
        if state.table.sort == nil, !table.tableView.sortDescriptors.isEmpty { table.tableView.sortDescriptors = [] }
        if state.table.columnFilters.activeFilters.isEmpty, state.table.filterText.isEmpty {
            if table.columnFilterSet.isActive { table.columnFilterSet = ColumnFilterSet() }
            if !table.currentFilterText.isEmpty { table.setFilterText("") }
        }
        if state.table.selectedIdentities.isEmpty, !table.tableView.selectedRowIndexes.isEmpty {
            table.tableView.deselectAll(nil)
        }
        let report = table.applyViewMemory(state.table, dataChanged: dataChanged)
        var lost: ViewMemoryLoss = []
        if report.filtersDropped { lost.insert(.filters) }
        // A kept contig that is gone is dropped. Only a changed key says so, since the table is flat and an equal key
        // holds every contig (adopters' lesson 11).
        if dataChanged, report.selection?.lostAny == true { lost.insert(.selection) }
        return lost
    }
}

// MARK: - The divider beside the detail pane

/// The divider this visit's restore gave, which the detail pane takes in place of the viewer's default each time it
/// opens, until the next load. It is held beside the viewer, one a viewer, and leaves with it.
@MainActor
final class AssemblyKeptDivider {
    var restored: AssemblyResultSurface.ViewState.Divider?

    private static let registry = NSMapTable<AssemblyResultViewController, AssemblyKeptDivider>.weakToStrongObjects()

    static func of(_ viewer: AssemblyResultViewController) -> AssemblyKeptDivider {
        if let kept = registry.object(forKey: viewer) { return kept }
        let kept = AssemblyKeptDivider()
        registry.setObject(kept, forKey: viewer)
        return kept
    }
}

extension AssemblyResultViewController {
    /// Where the detail pane's divider goes when the pane opens: the kept share when it was kept in this layout and
    /// orientation, else the viewer's default. `applyLayoutPreference` and the first layout's check read it.
    func placedLeadingFraction(for layout: AssemblyPanelLayout) -> CGFloat {
        guard let kept = AssemblyKeptDivider.of(self).restored, kept.layout == layout.rawValue,
              kept.position.isVertical == (layout != .stacked), kept.position.fractions.count == 1,
              let share = kept.position.fractions.first, share.isFinite, share > 0, share < 1 else {
            return defaultLeadingFraction(for: layout)
        }
        return CGFloat(share)
    }

    /// The divider as the person left it, or what the restore gave while the pane is closed or the divider stands
    /// where the viewer placed it, within 2 points, so a visit that moved nothing keeps its starting view (VS S3).
    func dividerToKeep() -> AssemblyResultSurface.ViewState.Divider? {
        let restored = AssemblyKeptDivider.of(self).restored
        let layout = AssemblyPanelLayout.current()
        guard !detailContainer.isHidden, splitCoordinator.didSetInitialSplitPosition,
              let current = splitView.captureViewMemory(), current.fractions.count == 1 else { return restored }
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let minimums = minimumExtents(for: layout)
        let placed = SplitPaneSizing.clampedDividerPosition(
            proposed: (extent * placedLeadingFraction(for: layout)).rounded(),
            containerExtent: max(0, extent - splitView.dividerThickness),
            minimumLeadingExtent: minimums.leading, minimumTrailingExtent: minimums.trailing)
        guard abs(CGFloat(current.fractions[0]) * extent - placed) > 2 else { return restored }
        return AssemblyResultSurface.ViewState.Divider(layout: layout.rawValue, position: current)
    }

    /// Takes a kept divider, or none for the viewer's default. A closed pane takes it when it opens, and an open one,
    /// as at Reset View, is placed again now through the viewer's own layout path.
    func restoreDivider(_ kept: AssemblyResultSurface.ViewState.Divider?) {
        AssemblyKeptDivider.of(self).restored = kept
        guard !detailContainer.isHidden, splitView.arrangedSubviews.count == 2 else { return }
        splitCoordinator.invalidateInitialSplitPosition()
        applyLayoutPreference()
    }
}
