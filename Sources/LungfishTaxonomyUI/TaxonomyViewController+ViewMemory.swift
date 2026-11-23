// TaxonomyViewController+ViewMemory.swift - The Kraken2 and CZ ID viewers keep their view for each result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Both surfaces show a `TaxonomyViewController`, so the view they keep is one struct and one capture and restore, here.
// Nothing in this file writes into the bundle or the project, and nothing starts a tool, a write or a search (VS S4).

import AppKit
import LungfishIO
import LungfishKit

/// One token for this run of the app. A saved sample choice comes back only inside the run that saved it, since the
/// viewer shows the picker only in the Inspector and a subset restored after a relaunch would hide rows with no sign in
/// the view (VS B5).
enum TaxonomyViewMemoryRun {
    static let token = UUID().uuidString
}

/// A row identity without the result's path, so a renamed or moved project keeps its selection and zoom (VS A3, B4).
/// The table's identity is the tool, the result's path, the sample, the taxon id, the rank and the name.
enum TaxonomyRowIdentity {
    static let separator = "\u{1F}"

    static func portable(_ identity: String) -> String {
        var parts = identity.components(separatedBy: separator)
        if parts.count > 1 { parts[1] = "result" }
        return parts.joined(separator: separator)
    }
}

/// The view a taxonomy viewer keeps for one result. Each field and its class (VS B2 to B9):
/// - `samples` and `samplesRun`, the picker's samples by id (VS B5), intersected with the result's samples, restored
///   only in the run that saved them. An empty intersection falls back to every sample.
/// - `filterText`, the "Filter taxa..." field, is a search text (VS B6). It comes back only on an equal data key, and
///   the field itself shows it, so no filter line is needed.
/// - `sort` is presentation and always comes back.
/// - `selectedIdentities` are table row identities with the sample (VS B4), without the result's path. An identity
///   that no longer exists is dropped, and none left means no selection, never row 0.
/// - `zoomIdentity`, the sunburst's zoom centre by the same identity. A node that no longer exists drops the zoom.
/// - `drawerOpen`, the Collections drawer, is presentation.
/// - `columns` and `batchColumns`, the metadata column layouts of the outline and the batch table, are presentation and
///   always come back. They live here and never in the account's defaults (VS A10).
/// - `split`, the divider as the person left it, as a share of the split, is presentation and always comes back. None
///   means where the viewer puts it.
struct TaxonomyViewMemory: Codable, Sendable, Equatable {
    var filterText = ""
    var sort: BatchTableMemory.Sort?
    var selectedIdentities: [String] = []
    var zoomIdentity: String?
    var drawerOpen = false
    var samples: SamplePickerMemory?
    var samplesRun: String?
    var columns: MetadataColumnLayoutMemory?
    var batchColumns: MetadataColumnLayoutMemory?
    var split: SplitPositionMemory?
}

/// What the sidebar route did to this visit (VS B9). The route's pick wins for the visit and is not kept.
@MainActor
final class TaxonomyVisitMemo {
    var routedSample: String?
    var samplesBeforeRoute: SamplePickerMemory?
    /// The divider this visit restored, which the first position takes once the split has a size.
    var restoredSplit: SplitPositionMemory?

    private static let registry = NSMapTable<TaxonomyViewController, TaxonomyVisitMemo>.weakToStrongObjects()

    static func memo(for controller: TaxonomyViewController) -> TaxonomyVisitMemo {
        if let memo = registry.object(forKey: controller) { return memo }
        let memo = TaxonomyVisitMemo()
        registry.setObject(memo, forKey: controller)
        return memo
    }
}

extension TaxonomyViewController {
    /// The result folder the view's memory belongs to, from facts the viewer already holds. Nil keeps nothing.
    var viewMemoryFolderURL: URL? {
        isBatchMode ? batchURL : classificationResult?.config.outputDirectory
    }

    /// The data key of VS B1, which a rerun must change even when every count comes out the same. A batch result keys
    /// on the run record its database holds, the `created_at` that `build-db` writes, and not on the file's date,
    /// which the sample metadata cache moves on a visit. A one-sample result keys on its provenance run id. A
    /// database or result with neither keys as "no run", which a rerun's record never equals. The counts the viewer
    /// loaded follow. The metadata table is read once, in the surface's load, on the main actor where the route has
    /// just read the whole database (SWIFT ruling R2). A key part not read gives nil, which never compares equal.
    func viewMemoryDataKey() -> String? {
        if isBatchMode {
            guard !sampleEntries.isEmpty, let database = kraken2Database,
                  let metadata = try? database.fetchMetadata() else { return nil }
            let samples = sampleEntries.map { "\($0.id)=\($0.classifiedReads)" }
            let run = "built \(metadata["created_at"] ?? "no run")"
            return (["kraken2 batch v2", run, "rows \(allBatchRows.count)"] + samples).joined(separator: "\n")
        }
        guard let result = classificationResult else { return nil }
        let tree = result.tree
        return [
            "kraken2 v2", "run \(result.provenanceId?.uuidString ?? "no run")", "reads \(tree.totalReads)",
            "classified \(tree.classifiedReads)", "species \(tree.speciesCount)",
        ].joined(separator: "\n")
    }

    /// The view as the viewer's controls hold it now. It reads no file and no store.
    func captureTaxonomyViewMemory() -> TaxonomyViewMemory {
        var memory = TaxonomyViewMemory()
        memory.filterText = taxonomyTableView.filterText
        // The header menu sets the table's own key and leaves the outline's descriptors, so the table's key is read.
        memory.sort = BatchTableMemory.Sort(
            key: taxonomyTableView.currentSortKey, ascending: taxonomyTableView.currentSortAscending
        )
        memory.selectedIdentities = taxonomyTableView.selectionIdentities.selectedIDs
            .map(TaxonomyRowIdentity.portable).sorted()
        if let centre = sunburstView.centerNode, let identity = taxonomyTableView.selectionIdentity(for: centre) {
            memory.zoomIdentity = TaxonomyRowIdentity.portable(identity)
        }
        memory.drawerOpen = isTaxaCollectionsDrawerOpen
        memory.columns = taxonomyTableView.metadataColumns.captureViewMemory()
        memory.batchColumns = batchTableView.metadataColumns.captureViewMemory()
        memory.split = splitToKeep()
        if isBatchMode, let picker = samplePickerState {
            var picked = picker.captureViewMemory(allSampleIDs: Set(sampleEntries.map(\.id)))
            // The route's pick is the app's, not a choice, unless the person changed it afterwards (VS B9, S3).
            let memo = TaxonomyVisitMemo.memo(for: self)
            if let routed = memo.routedSample, picked.selectedSampleIDs == [routed], let before = memo.samplesBeforeRoute {
                picked = before
            }
            memory.samples = picked
            memory.samplesRun = TaxonomyViewMemoryRun.token
        }
        return memory
    }

    /// Applies a kept view, each field by its rule, through the paths a person's change takes. It returns what it could
    /// not bring back. A restored selection reaches the viewer's own selection callbacks, as a click does, and nothing
    /// else starts.
    func applyTaxonomyViewMemory(_ memory: TaxonomyViewMemory, dataChanged: Bool) -> ViewMemoryLoss {
        var lost: ViewMemoryLoss = []
        let table = taxonomyTableView

        // Samples first, since a new sample set rebuilds the tree and resets the zoom and the selection.
        if isBatchMode, let picker = samplePickerState, let saved = memory.samples,
           memory.samplesRun == TaxonomyViewMemoryRun.token {
            let before = picker.selectedSamples
            let restore = picker.applyViewMemory(saved, currentSampleIDs: Set(sampleEntries.map(\.id)))
            if restore.selected != before { applyBatchSampleFilter() }
            if restore.droppedCount > 0 || restore.fellBackToAll { lost.insert(.sampleChoice) }
        }

        // The column layouts before the rows, since a layout change refreshes the table's columns.
        table.metadataColumns.applyKeptLayout(memory.columns)
        batchTableView.metadataColumns.applyKeptLayout(memory.batchColumns)
        restoreSplit(memory.split)

        let filter = dataChanged ? "" : memory.filterText
        if dataChanged, !memory.filterText.isEmpty { lost.insert(.filters) }
        if table.filterText != filter {
            table.searchField.stringValue = filter
            table.filterText = filter
        }

        let sort = memory.sort ?? BatchTableMemory.Sort(key: "reads", ascending: false)
        if table.currentSortKey != sort.key || table.currentSortAscending != sort.ascending {
            table.outlineView.sortDescriptors = [NSSortDescriptor(key: sort.key, ascending: sort.ascending)]
            // The delegate sets the key from the descriptor. When it did not run, the menu's path sets it.
            if table.currentSortKey != sort.key || table.currentSortAscending != sort.ascending {
                table.columnHeaderFilterMenu(sortByKey: sort.key, ascending: sort.ascending)
            }
        }

        let visible = table.visibleSelectionIdentities() ?? []
        let byPortable = Dictionary(visible.map { (TaxonomyRowIdentity.portable($0), $0) }) { first, _ in first }
        let kept = ViewMemoryRules.keepIdentities(memory.selectedIdentities, existing: Set(byPortable.keys))
        if kept.kept.isEmpty {
            table.selectionIdentities.clear()
        } else {
            table.selectionIdentities.select(kept.kept.compactMap { byPortable[$0] })
        }
        table.restoreSelectionAfterDisplayedNodesChanged()
        if kept.droppedCount > 0 { lost.insert(.selection) }

        if let identity = memory.zoomIdentity {
            if let node = taxonNode(withPortableIdentity: identity) {
                sunburstView.centerNode = node
                breadcrumbBar.update(zoomNode: node)
            } else {
                lost.insert(.place)
            }
        } else if sunburstView.centerNode != nil {
            sunburstView.centerNode = nil
            breadcrumbBar.update(zoomNode: nil)
        }

        if memory.drawerOpen != isTaxaCollectionsDrawerOpen { toggleTaxaCollectionsDrawer() }
        return lost
    }

    /// The sidebar route's sample (VS B9). It sets the picker as the route always did, and notes the picker the visit
    /// had before, so a capture that still finds the route's pick keeps that picker and not the route's.
    public func selectSampleFromRoute(_ sampleId: String) {
        let memo = TaxonomyVisitMemo.memo(for: self)
        if memo.routedSample == nil, let picker = samplePickerState {
            memo.samplesBeforeRoute = picker.captureViewMemory(allSampleIDs: Set(sampleEntries.map(\.id)))
        }
        memo.routedSample = sampleId
        samplePickerState?.selectedSamples = [sampleId]
    }

    /// The node a row identity names, found by its taxon id first so the identity is built for few nodes.
    private func taxonNode(withPortableIdentity identity: String) -> TaxonNode? {
        guard let root = tree?.root else { return nil }
        let parts = identity.components(separatedBy: TaxonomyRowIdentity.separator)
        let taxId: String? = parts.count > 3 ? parts[3] : nil
        var pending = [root]
        while let node = pending.popLast() {
            if taxId == nil || String(node.taxId) == taxId,
               let nodeIdentity = taxonomyTableView.selectionIdentity(for: node),
               TaxonomyRowIdentity.portable(nodeIdentity) == identity {
                return node
            }
            pending.append(contentsOf: node.children)
        }
        return nil
    }
}

// MARK: - The divider

extension TaxonomyViewController {
    /// The kept share the first position takes in place of the default, until the split has a position. The first
    /// layout gives it one once the split has a size (`applyInitialSplitPositionIfNeeded()`), so no timer waits.
    var keptSplitFraction: CGFloat? {
        guard !didSetInitialSplitPosition, let kept = TaxonomyVisitMemo.memo(for: self).restoredSplit,
              kept.isVertical == splitView.isVertical, let first = kept.fractions.first else { return nil }
        return CGFloat(first)
    }

    /// The divider as the person left it, or nil while it stands where the viewer put it on a first visit, so a visit
    /// that moved nothing keeps its starting view. Before the split has a position it is what the restore gave it.
    func splitToKeep() -> SplitPositionMemory? {
        let restored = TaxonomyVisitMemo.memo(for: self).restoredSplit
        guard didSetInitialSplitPosition, let current = Self.splitMemory(of: splitView) else { return restored }
        let placed = restored?.fractions.first ?? Double(defaultLeadingFraction(for: .current()))
        let extent = Double(splitView.isVertical ? splitView.bounds.width : splitView.bounds.height)
        return abs(current.fractions[0] - placed) * extent <= 2 ? restored : current
    }

    /// Puts the divider where the view keeps it, or where the viewer puts it when the view keeps none. Before the split
    /// has a position the first position takes it, and after it the divider moves now.
    func restoreSplit(_ kept: SplitPositionMemory?) {
        let usable = kept.flatMap { $0.isVertical == splitView.isVertical && $0.fractions.count == 1 ? $0 : nil }
        TaxonomyVisitMemo.memo(for: self).restoredSplit = usable
        guard didSetInitialSplitPosition, splitView.arrangedSubviews.count == 2 else { return }
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let share = usable?.fractions.first.map { CGFloat($0) } ?? defaultLeadingFraction(for: .current())
        splitView.setPosition(round(extent * share), ofDividerAt: 0)
    }

    /// The divider of a two-pane split as the leading pane's share, or nil while the split has no size.
    static func splitMemory(of split: NSSplitView) -> SplitPositionMemory? {
        let extent = split.isVertical ? split.bounds.width : split.bounds.height
        guard split.arrangedSubviews.count == 2, extent > 0 else { return nil }
        let pane = split.arrangedSubviews[0].frame
        let edge = split.isVertical ? pane.maxX : pane.maxY
        return SplitPositionMemory(isVertical: split.isVertical, fractions: [Double(edge / extent)])
    }
}
