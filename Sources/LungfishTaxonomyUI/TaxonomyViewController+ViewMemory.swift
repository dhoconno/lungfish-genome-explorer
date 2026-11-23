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
/// The split position is not kept yet (see the lane report).
struct TaxonomyViewMemory: Codable, Sendable, Equatable {
    var filterText = ""
    var sort: BatchTableMemory.Sort?
    var selectedIdentities: [String] = []
    var zoomIdentity: String?
    var drawerOpen = false
    var samples: SamplePickerMemory?
    var samplesRun: String?
}

/// What the sidebar route did to this visit (VS B9). The route's pick wins for the visit and is not kept.
@MainActor
final class TaxonomyVisitMemo {
    var routedSample: String?
    var samplesBeforeRoute: SamplePickerMemory?

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

    /// The data key of VS B1, from what the viewer loaded when the result opened, so it reads no file. A key part not
    /// read gives nil, which never compares equal. A rerun that changes a count changes the key.
    func viewMemoryDataKey() -> String? {
        if isBatchMode {
            guard !sampleEntries.isEmpty else { return nil }
            let samples = sampleEntries.map { "\($0.id)=\($0.classifiedReads)" }
            return (["kraken2 batch v1", "rows \(allBatchRows.count)"] + samples).joined(separator: "\n")
        }
        guard let tree = classificationResult?.tree else { return nil }
        return [
            "kraken2 v1", "reads \(tree.totalReads)", "classified \(tree.classifiedReads)",
            "species \(tree.speciesCount)",
        ].joined(separator: "\n")
    }

    /// The view as the viewer's controls hold it now. It reads no file and no store.
    func captureTaxonomyViewMemory() -> TaxonomyViewMemory {
        var memory = TaxonomyViewMemory()
        memory.filterText = taxonomyTableView.filterText
        if let descriptor = taxonomyTableView.outlineView.sortDescriptors.first, let key = descriptor.key {
            memory.sort = BatchTableMemory.Sort(key: key, ascending: descriptor.ascending)
        }
        memory.selectedIdentities = taxonomyTableView.selectionIdentities.selectedIDs
            .map(TaxonomyRowIdentity.portable).sorted()
        if let centre = sunburstView.centerNode, let identity = taxonomyTableView.selectionIdentity(for: centre) {
            memory.zoomIdentity = TaxonomyRowIdentity.portable(identity)
        }
        memory.drawerOpen = isTaxaCollectionsDrawerOpen
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

        let filter = dataChanged ? "" : memory.filterText
        if dataChanged, !memory.filterText.isEmpty { lost.insert(.filters) }
        if table.filterText != filter {
            table.searchField.stringValue = filter
            table.filterText = filter
        }

        let sort = memory.sort ?? BatchTableMemory.Sort(key: "reads", ascending: false)
        let current = table.outlineView.sortDescriptors.first
        if current?.key != sort.key || current?.ascending != sort.ascending {
            table.outlineView.sortDescriptors = [NSSortDescriptor(key: sort.key, ascending: sort.ascending)]
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
