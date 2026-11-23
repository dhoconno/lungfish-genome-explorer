// EsVirituResultViewController+ViewMemory.swift - The EsViritu viewer keeps its view for each result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// One struct holds the view fields, the controller captures them from its controls, and the restore applies each field by
// its rule. Nothing here writes into the bundle or the project, and nothing starts a tool, a write or a search (VS S4).

import AppKit
import LungfishIO
import LungfishKit

/// One token for this run of the app. A saved sample choice comes back only inside the run that saved it, since the
/// viewer shows the picker only in the Inspector and a subset restored after a relaunch would hide rows with no sign in
/// the view (VS B5).
enum EsVirituViewMemoryRun {
    static let token = UUID().uuidString
}

/// A row identity without the result's path, so a renamed or moved project keeps its selection and expansion (VS A3,
/// B4). The table's identity is the tool, the result's path, the sample, the assembly and then the row's own parts.
enum EsVirituRowIdentity {
    static let separator = "\u{1F}"

    static func portable(_ identity: String) -> String {
        var parts = identity.components(separatedBy: separator)
        if parts.count > 1 { parts[1] = "result" }
        return parts.joined(separator: separator)
    }
}

/// The view an EsViritu viewer keeps for one result. Each field and its class (VS B2 to B9):
/// - `samples` and `samplesRun`, the picker's samples by id (VS B5), intersected with the result's samples, restored
///   only in the run that saved them. An empty intersection falls back to every sample.
/// - `filterText`, the "Filter viruses..." field, is a search text (VS B6). It comes back only on an equal data key, and
///   the field itself shows it, so no filter line is needed.
/// - `sort` is presentation and always comes back.
/// - `selectedIdentities` are row identities with the sample and the assembly (VS B4), without the result's path. An
///   identity that no longer exists is dropped, and none left means no selection, never row 0.
/// - `collapsedIdentities`, the assemblies a person collapsed, by the same identity. The rest stay expanded.
/// - `columns` and `batchColumns`, the metadata column layouts of the detection and batch tables, are presentation and
///   always come back. They live here and never in the account's defaults (VS A10).
/// The split position is not kept yet (see the lane report).
struct EsVirituViewMemory: Codable, Sendable, Equatable {
    var filterText = ""
    var sort: BatchTableMemory.Sort?
    var selectedIdentities: [String] = []
    var collapsedIdentities: [String] = []
    var samples: SamplePickerMemory?
    var samplesRun: String?
    var columns: MetadataColumnLayoutMemory?
    var batchColumns: MetadataColumnLayoutMemory?
}

/// What the sidebar route did to this visit (VS B9). The route's pick wins for the visit and is not kept.
@MainActor
final class EsVirituVisitMemo {
    var routedSample: String?
    var samplesBeforeRoute: SamplePickerMemory?
    /// Whether the viewer's table keeps its collapsed assemblies through its re-filter (`keepCollapsedAssembliesThroughRefilters()`).
    var keepsCollapseThroughRefilters = false

    private static let registry = NSMapTable<EsVirituResultViewController, EsVirituVisitMemo>.weakToStrongObjects()

    static func memo(for controller: EsVirituResultViewController) -> EsVirituVisitMemo {
        if let memo = registry.object(forKey: controller) { return memo }
        let memo = EsVirituVisitMemo()
        registry.setObject(memo, forKey: controller)
        return memo
    }
}

extension EsVirituResultViewController {
    /// The result folder the view's memory belongs to, from facts the viewer already holds. Nil keeps nothing.
    var viewMemoryFolderURL: URL? { batchURL }

    /// The data key of VS B1, which a rerun must change even when every count comes out the same. A batch result keys
    /// on the run record its database holds, the `created_at` that `build-db` writes, and a database without one keys
    /// as "no run", which a rerun's record never equals. The counts the viewer loaded follow. The metadata table is
    /// read once, in the surface's load, on the main actor where the route has just read the whole database (SWIFT
    /// ruling R2). A key part not read gives nil, which never compares equal.
    func viewMemoryDataKey() -> String? {
        if isBatchMode {
            guard !sampleEntries.isEmpty, let database = esVirituDatabase,
                  let metadata = try? database.fetchMetadata() else { return nil }
            let samples = sampleEntries.map { "\($0.id)=\($0.detectedVirusCount)" }
            let run = "built \(metadata["created_at"] ?? "no run")"
            return (["esviritu batch v2", run, "rows \(allBatchRows.count)"] + samples).joined(separator: "\n")
        }
        guard let result = esVirituResult else { return nil }
        return ["esviritu v1", result.sampleId, "detections \(result.detections.count)"].joined(separator: "\n")
    }

    /// The view as the viewer's controls hold it now. It reads no file and no store.
    func captureEsVirituViewMemory() -> EsVirituViewMemory {
        var memory = EsVirituViewMemory()
        let table = detectionTableView
        memory.filterText = table.filterText
        // The header menu sets the table's own key and leaves the outline's descriptors, so the table's key is read.
        memory.sort = BatchTableMemory.Sort(key: table.exportSortKey, ascending: table.exportSortAscending)
        memory.selectedIdentities = table.selectionIdentities.selectedIDs.map(EsVirituRowIdentity.portable).sorted()
        memory.collapsedIdentities = collapsedAssemblyIdentities()
        memory.columns = table.metadataColumns.captureViewMemory()
        memory.batchColumns = batchTableView.metadataColumns.captureViewMemory()
        if isBatchMode, let picker = samplePickerState {
            var picked = picker.captureViewMemory(allSampleIDs: Set(sampleEntries.map(\.id)))
            // The route's pick is the app's, not a choice, unless the person changed it afterwards (VS B9, S3).
            let memo = EsVirituVisitMemo.memo(for: self)
            if let routed = memo.routedSample, picked.selectedSampleIDs == [routed], let before = memo.samplesBeforeRoute {
                picked = before
            }
            memory.samples = picked
            memory.samplesRun = EsVirituViewMemoryRun.token
        }
        return memory
    }

    /// Applies a kept view, each field by its rule, through the paths a person's change takes. It returns what it could
    /// not bring back. A restored selection reaches the viewer's own selection callbacks, as a click does, and nothing
    /// else starts.
    func applyEsVirituViewMemory(_ memory: EsVirituViewMemory, dataChanged: Bool) -> ViewMemoryLoss {
        var lost: ViewMemoryLoss = []
        let table = detectionTableView
        let outline = table.outlineView

        // Samples first, since a new sample set rebuilds the rows and resets the selection.
        if isBatchMode, let picker = samplePickerState, let saved = memory.samples,
           memory.samplesRun == EsVirituViewMemoryRun.token {
            let before = picker.selectedSamples
            let restore = picker.applyViewMemory(saved, currentSampleIDs: Set(sampleEntries.map(\.id)))
            if restore.selected != before { applyBatchSampleFilter() }
            if restore.droppedCount > 0 || restore.fellBackToAll { lost.insert(.sampleChoice) }
        }

        // The column layouts before the rows, since a layout change refreshes the columns and re-filters the table.
        table.metadataColumns.applyKeptLayout(memory.columns)
        batchTableView.metadataColumns.applyKeptLayout(memory.batchColumns)

        let filter = dataChanged ? "" : memory.filterText
        if dataChanged, !memory.filterText.isEmpty { lost.insert(.filters) }
        if table.filterText != filter {
            table.searchField.stringValue = filter
            table.filterText = filter
            table.applyFilterImmediately()
        }

        let sort = memory.sort ?? BatchTableMemory.Sort(key: "reads", ascending: false)
        if table.exportSortKey != sort.key || table.exportSortAscending != sort.ascending {
            outline.sortDescriptors = [NSSortDescriptor(key: sort.key, ascending: sort.ascending)]
            // The delegate sets the key from the descriptor. When it did not run, the menu's path sets it.
            if table.exportSortKey != sort.key || table.exportSortAscending != sort.ascending {
                table.columnHeaderFilterMenu(sortByKey: sort.key, ascending: sort.ascending)
            }
        }

        let visible = table.visibleSelectionIdentities() ?? []
        let byPortable = Dictionary(visible.map { (EsVirituRowIdentity.portable($0), $0) }) { first, _ in first }
        let kept = ViewMemoryRules.keepIdentities(memory.selectedIdentities, existing: Set(byPortable.keys))
        if kept.kept.isEmpty {
            table.selectionIdentities.clear()
        } else {
            table.selectionIdentities.select(kept.kept.compactMap { byPortable[$0] })
        }
        table.restoreSelectionAfterDisplayedItemsChanged()
        if kept.droppedCount > 0 { lost.insert(.selection) }

        // Expansion last: a collapse hides rows, and the selection above is already in place. The collapse is kept by
        // the assembly's identity with its sample (VS B4), also on a changed data key: it hides no count, since the
        // assembly row sums its detections, so it is presentation and not a filter (VS B6).
        applyCollapsedAssemblies(Set(memory.collapsedIdentities))
        return lost
    }

    /// The assemblies shown collapsed, by identity without the result's path.
    func collapsedAssemblyIdentities() -> [String] {
        let table = detectionTableView
        let outline = table.outlineView
        return (0..<outline.numberOfRows).compactMap { row in
            guard let item = outline.item(atRow: row), outline.isExpandable(item), !outline.isItemExpanded(item),
                  let identity = table.selectionIdentity(for: item) else { return nil }
            return EsVirituRowIdentity.portable(identity)
        }
    }

    /// The table filters again on every column or metadata change, and while a filter shows that opens every
    /// assembly. The route's metadata hand-off and the window's first layout are such changes, so a restored
    /// collapse, or a person's, would open again at once. This keeps the collapsed assemblies through that re-filter.
    /// It is installed once a viewer, in the surface's load, and starts nothing (VS S4).
    func keepCollapsedAssembliesThroughRefilters() {
        let memo = EsVirituVisitMemo.memo(for: self)
        guard !memo.keepsCollapseThroughRefilters else { return }
        memo.keepsCollapseThroughRefilters = true
        let columns = detectionTableView.metadataColumns
        let refilter = columns.onColumnsOrStoreChanged
        columns.onColumnsOrStoreChanged = { [weak self] in
            let collapsed = self?.collapsedAssemblyIdentities() ?? []
            refilter?()
            if let self, !collapsed.isEmpty { self.applyCollapsedAssemblies(Set(collapsed)) }
        }
    }

    /// Collapses each assembly whose identity is in `collapsed` and opens every other one, as a person's clicks do.
    private func applyCollapsedAssemblies(_ collapsed: Set<String>) {
        let table = detectionTableView
        let outline = table.outlineView
        for _ in 0..<3 {
            var changed = false
            var row = 0
            while row < outline.numberOfRows {
                if let item = outline.item(atRow: row), outline.isExpandable(item),
                   let identity = table.selectionIdentity(for: item) {
                    let wantsCollapsed = collapsed.contains(EsVirituRowIdentity.portable(identity))
                    if wantsCollapsed == outline.isItemExpanded(item) {
                        if wantsCollapsed { outline.collapseItem(item) } else { outline.expandItem(item) }
                        changed = true
                    }
                }
                row += 1
            }
            if !changed { break }
        }
    }

    /// The sidebar route's sample (VS B9). It sets the picker as the route always did, and notes the picker the visit
    /// had before, so a capture that still finds the route's pick keeps that picker and not the route's.
    public func selectSampleFromRoute(_ sampleId: String) {
        let memo = EsVirituVisitMemo.memo(for: self)
        if memo.routedSample == nil, let picker = samplePickerState {
            memo.samplesBeforeRoute = picker.captureViewMemory(allSampleIDs: Set(sampleEntries.map(\.id)))
        }
        memo.routedSample = sampleId
        samplePickerState?.selectedSamples = [sampleId]
    }
}
