// NaoMgsResultViewController+ViewMemory.swift - The NAO-MGS viewer keeps its view for each result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The route shows the viewer empty and gives it the result's database after the show, so the restore is late (VS A2):
// the viewer tells its surface when the database is in (`finishDatabaseConfigure()`), and the host applies the kept view
// then, only while the view still equals the one the database opened with. Nothing in this file writes into the result
// or the project, and nothing starts a tool, a write, a search or a long load (VS S4).

import AppKit
import CryptoKit
import LungfishIO
import LungfishKit

/// The view the NAO-MGS viewer keeps for one result. Each field and its class (VS B2 to B9):
/// - `samples`, the sample filter by sample id (VS B5), intersected with the result's samples. The viewer's own Sample
///   Filter button names a subset ("1 of 3 Samples"), so a subset shows in the viewport and comes back after a relaunch
///   too. An empty intersection falls back to every sample and counts as a lost sample choice.
/// - `filterText`, the "Filter taxa..." field, is a search text (VS B6). It comes back only on an equal data key, and
///   the field shows it, so no filter line is needed.
/// - `sort`, the table's sort, is presentation and always comes back.
/// - `selectedIdentities`, the selected rows by sample and taxon id (VS B4). A row that no longer exists is dropped,
///   never replaced by row 0. A restored row is selected as the table's selection, with no detail load, so Extract and
///   BLAST act on it as on a person's pick, and its detail shows on a click (lesson 8).
/// - `columns`, the metadata column layout, is presentation and always comes back. It lives here and never in the
///   account's defaults (VS A10).
/// - `split`, the divider as the person left it, as a share of the split, is presentation. None means where the viewer
///   puts it.
struct NaoMgsViewMemory: Codable, Sendable, Equatable {
    var samples: SamplePickerMemory?
    var filterText = ""
    var sort: BatchTableMemory.Sort?
    var selectedIdentities: [String] = []
    var columns: MetadataColumnLayoutMemory?
    var split: SplitPositionMemory?
}

/// What one viewer holds for its visit: the folder the route named, the data key once the database is in, the late
/// restore the surface waits on, and the divider the restore gave.
@MainActor
final class NaoMgsVisitMemo {
    var folder: URL?
    var dataKey: String?
    var onDatabaseConfigured: ((NaoMgsViewMemory) -> Void)?
    var restoredSplit: SplitPositionMemory?

    private static let registry = NSMapTable<NaoMgsResultViewController, NaoMgsVisitMemo>.weakToStrongObjects()

    static func memo(for controller: NaoMgsResultViewController) -> NaoMgsVisitMemo {
        if let memo = registry.object(forKey: controller) { return memo }
        let memo = NaoMgsVisitMemo()
        registry.setObject(memo, forKey: controller)
        return memo
    }
}

extension NaoMgsResultViewController {
    /// A viewer whose view is kept for the result in `folder`, which the route makes before the show, since the viewer
    /// learns its folder only from the database it gets after the show.
    public static func keepingViewMemory(of folder: URL) -> NaoMgsResultViewController {
        let controller = NaoMgsResultViewController()
        NaoMgsVisitMemo.memo(for: controller).folder = folder
        return controller
    }

    /// The identity of a row: its sample and its taxon id, so the same taxon of two samples are two rows (VS B4).
    static func viewMemoryIdentity(of row: NaoMgsTaxonSummaryRow) -> String {
        "\(row.sample)\u{1F}\(row.taxId)"
    }

    /// The data key of VS B1, from the manifest and the samples the database holds, which are in memory once the
    /// database is in. A new import writes a new manifest, with its own date and source. The samples are one digest, so
    /// the key stays short for a result of many samples (lesson 5). Nil before the database is in.
    func viewMemoryDataKey() -> String? {
        guard let manifest else { return nil }
        let samples = allSamples.map { "\($0.sample)=\($0.hitCount)" }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(samples.utf8)).map { String(format: "%02x", $0) }.joined()
        return [
            "naomgs v1", "imported \(manifest.importDate.timeIntervalSince1970)", "source \(manifest.sourceFilePath)",
            "hits \(manifest.hitCount)", "taxa \(manifest.taxonCount)", "samples \(digest)",
        ].joined(separator: "\n")
    }

    /// The view as the viewer's controls hold it now. It reads no file and no store.
    func captureNaoMgsViewMemory() -> NaoMgsViewMemory {
        var memory = NaoMgsViewMemory()
        if let picker = samplePickerState, !allSamples.isEmpty {
            memory.samples = picker.captureViewMemory(allSampleIDs: Set(allSamples.map(\.sample)))
        }
        memory.filterText = searchText
        if let descriptor = taxonomyTableView.sortDescriptors.first, let key = descriptor.key {
            memory.sort = BatchTableMemory.Sort(key: key, ascending: descriptor.ascending)
        }
        memory.selectedIdentities = taxonomyTableView.selectedRowIndexes
            .compactMap { $0 < displayedRows.count ? Self.viewMemoryIdentity(of: displayedRows[$0]) : nil }.sorted()
        memory.columns = metadataColumnController.captureViewMemory()
        memory.split = splitToKeep()
        return memory
    }

    /// The view the database opens with: every sample, no filter, the sort by hits, no row, the columns as the key set
    /// them and the divider where the viewer puts it. A person's change before the late restore differs from it, so the
    /// restore does not run over it (VS A2).
    func databaseStartingViewMemory() -> NaoMgsViewMemory {
        var start = NaoMgsViewMemory()
        if let picker = samplePickerState, !allSamples.isEmpty {
            start.samples = picker.captureViewMemory(allSampleIDs: Set(allSamples.map(\.sample)))
        }
        start.sort = BatchTableMemory.Sort(key: "hits", ascending: false)
        start.columns = metadataColumnController.captureViewMemory()
        start.split = splitToKeep()
        return start
    }

    /// The last step of `configure(database:manifest:bundleURL:)`: the loading cover goes, the data key is read from
    /// memory, and the surface's late restore runs.
    func finishDatabaseConfigure() {
        hideLoadingOverlay()
        let memo = NaoMgsVisitMemo.memo(for: self)
        memo.dataKey = viewMemoryDataKey()
        memo.onDatabaseConfigured?(databaseStartingViewMemory())
    }

    /// Applies a kept view, each field by its rule, through the paths a person's change takes, and returns what it could
    /// not bring back. The rows reload once, and the kept rows are selected after it.
    func applyNaoMgsViewMemory(_ memory: NaoMgsViewMemory, dataChanged: Bool) -> ViewMemoryLoss {
        var lost: ViewMemoryLoss = []
        if let picker = samplePickerState, !allSamples.isEmpty {
            let all = SamplePickerMemory(selectedSampleIDs: allSamples.map(\.sample).sorted(), wasAllSamples: true)
            let restore = picker.applyViewMemory(memory.samples ?? all, currentSampleIDs: Set(allSamples.map(\.sample)))
            if restore.droppedCount > 0 || restore.fellBackToAll { lost.insert(.sampleChoice) }
            if restore.selected != selectedSamples {
                selectedSamples = restore.selected
                updateSampleFilterButtonTitle()
                updateMetadataColumnsForCurrentSamples()
                if let database, let manifest {
                    summaryBar.update(database: database, manifest: manifest, selectedSamples: Array(selectedSamples))
                }
            }
        }
        metadataColumnController.applyKeptLayout(memory.columns)
        restoreSplit(memory.split)

        let filter = dataChanged ? "" : memory.filterText
        if dataChanged, !memory.filterText.isEmpty { lost.insert(.filters) }
        taxonomySearchField.stringValue = filter
        searchText = filter
        let sort = memory.sort ?? BatchTableMemory.Sort(key: "hits", ascending: false)
        let current = taxonomyTableView.sortDescriptors.first
        if current?.key != sort.key || current?.ascending != sort.ascending {
            taxonomyTableView.sortDescriptors = [NSSortDescriptor(key: sort.key, ascending: sort.ascending)]
        }
        reloadTaxonomyTable()

        let rows = displayedRows
        let indexByIdentity = Dictionary(rows.enumerated().map { (Self.viewMemoryIdentity(of: $1), $0) }) { first, _ in first }
        let kept = ViewMemoryRules.keepIdentities(memory.selectedIdentities, existing: Set(indexByIdentity.keys))
        let indexes = IndexSet(kept.kept.compactMap { indexByIdentity[$0] })
        suppressSelectionSync = true
        taxonomyTableView.selectRowIndexes(indexes, byExtendingSelection: false)
        suppressSelectionSync = false
        selectedRow = indexes.count == 1 ? indexes.first.map { rows[$0] } : nil
        if let first = indexes.first { taxonomyTableView.scrollRowToVisible(first) }
        // The bar acts on the rows shown selected, as after a pick (lesson 8). It reads one count and starts no detail
        // and no BAM load.
        if let row = selectedRow {
            updateActionBarForRow(row, totalHits: (try? database?.totalHitCount(samples: Array(selectedSamples))) ?? 0)
        } else if indexes.count > 1 {
            resultActions.showSelection(count: indexes.count, extractable: database != nil)
        }
        // A kept row drops only when the data changed: on an equal key every kept row is a row the restored samples
        // and filter show, so no line says the data changed (lesson 11).
        if dataChanged, kept.droppedCount > 0 { lost.insert(.selection) }
        return lost
    }
}

// MARK: - The divider

extension NaoMgsResultViewController {
    /// The kept share the first position takes in place of the default, until the split has a position.
    var keptSplitFraction: CGFloat? {
        guard !splitCoordinator.didSetInitialSplitPosition, let kept = NaoMgsVisitMemo.memo(for: self).restoredSplit,
              kept.isVertical == splitView.isVertical, let first = kept.fractions.first else { return nil }
        return CGFloat(first)
    }

    /// The divider as the person left it, or nil while it stands where the viewer put it, so a visit that moved nothing
    /// keeps its starting view. Before the split has a position it is what the restore gave it.
    func splitToKeep() -> SplitPositionMemory? {
        let restored = NaoMgsVisitMemo.memo(for: self).restoredSplit
        guard splitCoordinator.didSetInitialSplitPosition, let current = splitView.captureViewMemory(),
              current.fractions.count == 1 else { return restored }
        let placed = restored?.fractions.first ?? Double(defaultLeadingFraction(for: .current()))
        let extent = Double(splitView.isVertical ? splitView.bounds.width : splitView.bounds.height)
        return abs(current.fractions[0] - placed) * extent <= 2 ? restored : current
    }

    /// Puts the divider where the view keeps it, or where the viewer puts it when the view keeps none. Before the split
    /// has a position the first position takes it, and after it the divider moves now.
    func restoreSplit(_ kept: SplitPositionMemory?) {
        let usable = kept.flatMap { $0.isVertical == splitView.isVertical && $0.fractions.count == 1 ? $0 : nil }
        NaoMgsVisitMemo.memo(for: self).restoredSplit = usable
        guard splitCoordinator.didSetInitialSplitPosition, splitView.arrangedSubviews.count == 2 else { return }
        let share = usable?.fractions.first ?? Double(defaultLeadingFraction(for: .current()))
        splitView.applyViewMemory(SplitPositionMemory(isVertical: splitView.isVertical, fractions: [share]))
    }
}
