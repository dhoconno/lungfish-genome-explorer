// NvdResultViewController+ViewMemory.swift - The NVD viewer keeps its view for each result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The route shows the viewer empty and gives it the result's database after the show, so the restore is late (VS A2):
// the viewer tells its surface when the database is in (`finishDatabaseConfigure()`), and the host applies the kept view
// then, only while the view still equals the one the database opened with. Nothing in this file writes into the result
// or the project, and nothing starts a tool, a write, a search or an alignment evidence load (VS S4).

import AppKit
import CryptoKit
import LungfishIO
import LungfishKit

/// The view the NVD viewer keeps for one result. Each field and its class (VS B2 to B9):
/// - `byTaxon`, By Sample or By Taxon, is presentation and always comes back.
/// - `samples`, the sample filter by sample id (VS B5), intersected with the result's samples and never an empty set.
///   The viewer's own Sample Filter button names a subset ("2 of 3 Samples"), so a subset shows in the viewport and
///   comes back after a relaunch too. An empty intersection falls back to every sample and counts as a lost choice.
/// - `searchText`, the "Search contigs..." field, is a search text (VS B6). It comes back only on an equal data key, and
///   the field shows it, so no filter line is needed.
/// - `expandedIdentities`, the open taxon groups and contigs by identity without the result's path, are presentation.
///   A list past the selection cap of VS A9 is not kept, and the rows come back at the outline's starting levels.
/// - `selectedIdentities`, the selected rows by identity with the sample, the contig and the hit rank (VS B4), without
///   the result's path. A kept row is revealed before it is selected (lesson 11), a row that no longer exists is
///   dropped, never replaced by row 0, and a loss is reported only on a changed data key.
/// - `columns`, the metadata column layout, is presentation and lives here, never in the account's defaults (VS A10).
/// - `split`, the divider as the person left it, as a share of the split, is presentation. None means where the viewer
///   puts it.
struct NvdViewMemory: Codable, Sendable, Equatable {
    var byTaxon = false
    var samples: SamplePickerMemory?
    var searchText = ""
    var expandedIdentities: [String] = []
    var selectedIdentities: [String] = []
    var columns: MetadataColumnLayoutMemory?
    var split: SplitPositionMemory?
}

/// What one viewer holds for its visit: the folder the route named, the data key once the database is in, the late
/// restore the surface waits on, the divider the restore gave and the row whose detail the open showed.
@MainActor
final class NvdVisitMemo {
    var folder: URL?
    var dataKey: String?
    var onDatabaseConfigured: ((NvdViewMemory) -> Void)?
    var restoredSplit: SplitPositionMemory?
    var openedDetailIdentity: String?

    private static let registry = NSMapTable<NvdResultViewController, NvdVisitMemo>.weakToStrongObjects()

    static func memo(for controller: NvdResultViewController) -> NvdVisitMemo {
        if let memo = registry.object(forKey: controller) { return memo }
        let memo = NvdVisitMemo()
        registry.setObject(memo, forKey: controller)
        return memo
    }
}

/// A row identity without the result's path, so a moved project keeps its rows (VS A3, B4). The viewer's identity is
/// the tool, the result's path, then the sample, the contig and the hit rank, or "taxon-group" and the taxon's name.
enum NvdRowIdentity {
    static let separator = "\u{1F}"

    static func portable(_ identity: String) -> String {
        var parts = identity.components(separatedBy: separator)
        if parts.count > 1 { parts[1] = "result" }
        return parts.joined(separator: separator)
    }
}

extension NvdResultViewController {
    /// A viewer whose view is kept for the result in `folder`, which the route makes before the show, since the viewer
    /// learns its folder only when its database comes.
    public static func keepingViewMemory(of folder: URL) -> NvdResultViewController {
        let controller = NvdResultViewController()
        NvdVisitMemo.memo(for: controller).folder = folder
        return controller
    }

    /// The data key of VS B1, from the manifest and the samples the database holds, which are in memory once the
    /// database is in. A new import writes a new manifest with its own date and run. The samples are one digest, so the
    /// key stays short for a result of many samples (lesson 5). Nil before the database is in.
    func viewMemoryDataKey() -> String? {
        guard let manifest, database != nil else { return nil }
        let samples = allSamples.map { "\($0.sampleId)=\($0.contigCount)/\($0.hitCount)" }.joined(separator: "\n")
        let digest = SHA256.hash(data: Data(samples.utf8)).map { String(format: "%02x", $0) }.joined()
        return [
            "nvd v1", "imported \(manifest.importDate.timeIntervalSince1970)", "run \(manifest.snakemakeRunId ?? "none")",
            "experiment \(manifest.experiment)", "contigs \(manifest.contigCount)", "hits \(manifest.hitCount)",
            "samples \(digest)",
        ].joined(separator: "\n")
    }

    /// The samples as kept: the viewer's applied choice, all of them flagged as such.
    private func keptSamples() -> SamplePickerMemory? {
        let all = Set(allSamples.map(\.sampleId))
        guard !all.isEmpty else { return nil }
        return SamplePickerMemory(selectedSampleIDs: selectedSamples.sorted(), wasAllSamples: selectedSamples == all)
    }

    /// The portable identities of the open rows, in row order.
    private func expandedItemIdentities() -> [String] {
        (0..<outlineView.numberOfRows).compactMap { row in
            guard let item = outlineView.item(atRow: row) as? NvdOutlineItem, outlineView.isItemExpanded(item),
                  let identity = selectionIdentity(for: item) else { return nil }
            return NvdRowIdentity.portable(identity)
        }
    }

    /// The view as the viewer's controls hold it now. It reads no file and no store.
    func captureNvdViewMemory() -> NvdViewMemory {
        var memory = NvdViewMemory()
        memory.byTaxon = groupingMode == .byTaxon
        memory.samples = keptSamples()
        memory.searchText = searchQuery
        if case .kept(let open) = ViewMemoryRules.capSelection(expandedItemIdentities()) {
            memory.expandedIdentities = open
        }
        memory.selectedIdentities = outlineView.selectedRowIndexes.compactMap { row -> String? in
            guard let item = outlineView.item(atRow: row) as? NvdOutlineItem else { return nil }
            return selectionIdentity(for: item).map(NvdRowIdentity.portable)
        }.sorted()
        memory.columns = metadataColumnController.captureViewMemory()
        memory.split = splitToKeep()
        return memory
    }

    /// The view the database opens with: By Sample, every sample, no search, no open row, the first contig selected, the
    /// columns as the key set them and the divider where the viewer puts it. A person's change before the late restore
    /// differs from it, so the restore does not run over it (VS A2).
    func databaseStartingViewMemory() -> NvdViewMemory {
        var start = NvdViewMemory()
        let all = allSamples.map(\.sampleId).sorted()
        if !all.isEmpty { start.samples = SamplePickerMemory(selectedSampleIDs: all, wasAllSamples: true) }
        if let first = displayedContigs.first,
           let identity = selectionIdentity(for: .contig(sampleId: first.sampleId, qseqid: first.qseqid)) {
            start.selectedIdentities = [NvdRowIdentity.portable(identity)]
        }
        start.columns = metadataColumnController.captureViewMemory()
        start.split = splitToKeep()
        return start
    }

    /// The last step of `configure(database:manifest:bundleURL:)`: the loading cover goes, the data key is read from
    /// memory, and the surface's late restore runs.
    func finishDatabaseConfigure() {
        hideLoadingOverlay()
        let memo = NvdVisitMemo.memo(for: self)
        memo.dataKey = viewMemoryDataKey()
        memo.openedDetailIdentity = outlineView.selectedRowIndexes.count == 1
            ? (outlineView.item(atRow: outlineView.selectedRow) as? NvdOutlineItem).flatMap(selectionIdentity(for:))
            : nil
        memo.onDatabaseConfigured?(databaseStartingViewMemory())
    }

    /// Applies a kept view, each field by its rule, through the paths a person's change takes, and returns what it could
    /// not bring back. The rows reload once, the kept rows open and the selected ones are revealed and selected. The
    /// open's first contig is let go before the reload, so the reload shows no detail, and a restored row other than the
    /// one whose detail shows leaves the overview with the action bar set as a pick sets it: no alignment evidence
    /// load starts (VS S4, lesson 8). Its detail shows on a click.
    func applyNvdViewMemory(_ memory: NvdViewMemory, dataChanged: Bool) -> ViewMemoryLoss {
        var lost: ViewMemoryLoss = []
        groupingMode = memory.byTaxon ? .byTaxon : .bySample
        groupingSegment.selectedSegment = groupingMode.rawValue

        var samplesChanged = false
        let all = Set(allSamples.map(\.sampleId))
        if !all.isEmpty {
            let saved = memory.samples ?? SamplePickerMemory(selectedSampleIDs: all.sorted(), wasAllSamples: true)
            let restore = ViewMemoryRules.restoreSamples(
                saved: saved.selectedSampleIDs, savedWasAllSamples: saved.wasAllSamples, current: all
            )
            if restore.droppedCount > 0 || restore.fellBackToAll { lost.insert(.sampleChoice) }
            if restore.selected != selectedSamples {
                selectedSamples = restore.selected
                samplesChanged = true
                updateSampleFilterButtonTitle()
                updateMetadataColumnsForCurrentSamples()
            }
            samplePickerState?.selectedSamples = restore.selected
        }
        metadataColumnController.applyKeptLayout(memory.columns)
        restoreSplit(memory.split)

        let search = dataChanged ? "" : memory.searchText
        if dataChanged, !memory.searchText.isEmpty { lost.insert(.filters) }
        searchField.stringValue = search
        searchQuery = search
        selectionIdentities.clear()
        reloadOutlineData()
        if samplesChanged {
            summaryBar.update(
                experiment: manifest?.experiment ?? "", sampleCount: allSamples.count,
                contigCount: displayedContigs.count,
                hitCount: (try? database?.totalHitCount(samples: Array(selectedSamples))) ?? 0
            )
        }

        openRows(withPortableIdentities: Set(memory.expandedIdentities))
        revealRows(withPortableIdentities: memory.selectedIdentities)
        let visible = visibleSelectionItemsAndIdentities() ?? []
        let byPortable = Dictionary(visible.map { (NvdRowIdentity.portable($0.identity), $0) }) { first, _ in first }
        let kept = ViewMemoryRules.keepIdentities(memory.selectedIdentities, existing: Set(byPortable.keys))
        let picks = kept.kept.compactMap { byPortable[$0] }
        if picks.isEmpty { selectionIdentities.clear() } else { selectionIdentities.select(picks.map(\.identity)) }
        let indexes = IndexSet(picks.map { outlineView.row(forItem: $0.item) }.filter { $0 >= 0 })
        restoreOutlineSelection(indexes)
        if let first = indexes.first { outlineView.scrollRowToVisible(first) }
        showRestoredSelection(picks.map(\.identity))
        // On an equal key every kept row is revealed above, so a row drops only when the data changed (lesson 11).
        if dataChanged, kept.droppedCount > 0 { lost.insert(.selection) }
        return lost
    }

    /// The detail pane and the action bar after a restore. The open's detail stays when the restore selects that same
    /// row. Any other selection shows the overview, and the action bar acts on the selected rows as after a pick.
    private func showRestoredSelection(_ identities: [String]) {
        if identities.count == 1, identities.first == NvdVisitMemo.memo(for: self).openedDetailIdentity { return }
        showOverview()
        if identities.count == 1, let hit = singleIdentityBackedSelectedHit() {
            updateActionBarForHit(hit)
        } else if identities.count > 1 {
            resultActions.showSelection(count: identities.count, extractable: database != nil)
        }
    }

    /// Opens each row whose portable identity is in `open`, taxon groups before the contigs inside them, as a person's
    /// clicks do. A row not shown is skipped, and nothing asks a row whether it can open, so no row's hits are read.
    private func openRows(withPortableIdentities open: Set<String>) {
        guard !open.isEmpty else { return }
        for _ in 0..<2 {
            var opened = false
            var row = 0
            while row < outlineView.numberOfRows {
                if let item = outlineView.item(atRow: row) as? NvdOutlineItem, !outlineView.isItemExpanded(item),
                   let identity = selectionIdentity(for: item), open.contains(NvdRowIdentity.portable(identity)) {
                    outlineView.expandItem(item)
                    opened = true
                }
                row += 1
            }
            if !opened { break }
        }
    }

    /// Opens the way to each kept row (lesson 11): its taxon group By Taxon, and its contig for a hit row.
    private func revealRows(withPortableIdentities identities: [String]) {
        for identity in identities {
            let parts = identity.components(separatedBy: NvdRowIdentity.separator)
            guard parts.count >= 4, parts[2] != "taxon-group" else { continue }
            let sample = parts[2], qseqid = parts[3]
            if groupingMode == .byTaxon,
               let contig = displayedContigs.first(where: { $0.sampleId == sample && $0.qseqid == qseqid }) {
                outlineView.expandItem(NvdOutlineItem.taxonGroup(name: contig.adjustedTaxidName))
            }
            if parts.count >= 5 {
                outlineView.expandItem(NvdOutlineItem.contig(sampleId: sample, qseqid: qseqid))
            }
        }
    }
}

// MARK: - The divider

extension NvdResultViewController {
    /// The kept share the first position takes in place of the default, until the split has a position.
    var keptSplitFraction: CGFloat? {
        guard !splitCoordinator.didSetInitialSplitPosition, let kept = NvdVisitMemo.memo(for: self).restoredSplit,
              kept.isVertical == splitView.isVertical, let first = kept.fractions.first else { return nil }
        return CGFloat(first)
    }

    /// The divider as the person left it, or nil while it stands where the viewer put it, so a visit that moved nothing
    /// keeps its starting view. Before the split has a position it is what the restore gave it.
    func splitToKeep() -> SplitPositionMemory? {
        let restored = NvdVisitMemo.memo(for: self).restoredSplit
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
        NvdVisitMemo.memo(for: self).restoredSplit = usable
        guard splitCoordinator.didSetInitialSplitPosition, splitView.arrangedSubviews.count == 2 else { return }
        let share = usable?.fractions.first ?? Double(defaultLeadingFraction(for: .current()))
        splitView.applyViewMemory(SplitPositionMemory(isVertical: splitView.isVertical, fractions: [share]))
    }
}
