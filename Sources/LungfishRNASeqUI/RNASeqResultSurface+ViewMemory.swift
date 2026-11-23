// RNASeqResultSurface+ViewMemory.swift - The RNA-seq result viewer keeps its view for each result
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Copied from the template, `Sources/LungfishTwelveSUI/TwelveSSurface+ViewMemory.swift`. One struct holds the view of
// the child on show, the surface conforms to `ViewMemoryAdopting`, and each child applies its fields by their rules
// (`Bulk/RNASeqBulkViewController+ViewMemory.swift`, `CellMap/RNASeqCellMapViewController+ViewMemory.swift`). Nothing
// here writes into the result or the project, and nothing starts a tool or a write (VS S4).

import AppKit
import LungfishIO
import LungfishKit

extension RNASeqResultSurface {
    /// The view the RNA-seq result viewer keeps for one result.
    ///
    /// - `child`, the child on show, is the manifest's modality, which the data decides and a person does not pick. A
    ///   kept view of another child restores nothing.
    /// - `bulk` holds the gene search, the tab and the selected genes (`RNASeqBulkViewMemory`).
    /// - `cellMap` holds the embedding and colouring by name, the point size, the zoom and the selection's form
    ///   (`RNASeqCellMapViewMemory`).
    /// - The single-cell child keeps nothing yet.
    ///
    /// The type is public because the surface and `ViewMemoryAdopting` are, and its fields stay internal. It is nested,
    /// so the module's list of public types does not change.
    public struct ViewState: ViewMemoryState {
        public static var kind: String { SurfaceKind.bundle(.rnaseqResult).description }
        public static var schemaVersion: Int { 1 }

        var child: String
        var bulk: RNASeqBulkViewMemory?
        var cellMap: RNASeqCellMapViewMemory?

        /// A selection past its cap counts as past the store's cap, so the store drops it whole and the viewer says so
        /// (VS A9, word 4). A cell map's form is one form, never a list of cells.
        public var selectionCount: Int { bulk?.selectionCount ?? 0 }

        public func withoutSelection() -> ViewState {
            var view = self
            view.bulk?.selected = [:]
            view.bulk?.selectionTooLarge = false
            view.cellMap?.selection = nil
            return view
        }
    }

    /// The data key of VS B1: the manifest's modality, name and date with one digest of the path and sha256 of every
    /// file it lists, as `RNASeqResultBundle.verifyChecksums` lists them, read from the manifest and never by hashing
    /// a file. A rerun writes new checksums, so a cell map with new coordinates under the same names has another key.
    /// A result that did not read has no key, which never compares equal.
    nonisolated static func viewMemoryDataKey(of outcome: RNASeqResultLoadOutcome) -> String? {
        guard case .loaded(let result) = outcome else { return nil }
        let manifest = result.manifest
        var listed = [manifest.samples, manifest.genes].map { ($0.path, $0.sha256) }
        listed += manifest.counts.map { ($0.path, $0.sha256) }
        listed += manifest.sourceFiles.map { ($0.path, $0.sha256) }
        for matrix in manifest.matrices ?? [] {
            listed += [matrix.matrix, matrix.features, matrix.barcodes].map { ($0.path, $0.sha256) }
        }
        if let cells = manifest.cellsSummary { listed.append((cells.path, cells.sha256)) }
        if let quality = manifest.quality { listed.append((quality.path, quality.sha256)) }
        if let cellMap = manifest.cellMap { listed.append((cellMap.path, cellMap.sha256)) }
        listed += (manifest.labelTables ?? []).map { ($0.path, $0.sha256) }
        // One digest of the listed paths and sha256 values keeps the key short for a result of hundreds of samples. The raw
        // lines pass the store's 64 KB record cap at about 600 files, and the store then drops the whole record.
        let files = RNASeqResultBundle.sha256Hex(Data(listed.map { "\($0.0) \($0.1)" }.joined(separator: "\n").utf8))
        return ["RNA-seq v1", manifest.modality.rawValue, manifest.name, manifest.createdAt, files].joined(separator: "\n")
    }

    /// The child on show, as the manifest names its modality, or "none" when the folder did not read.
    var shownChild: String { controller.facts?.modality ?? "none" }
}

extension RNASeqResultSurface: ViewMemoryAdopting {
    /// The view as the child's controls hold it now. It reads no file and no store.
    public func captureViewMemory() -> ViewState {
        ViewState(child: shownChild, bulk: controller.bulk?.captureViewMemory(),
                  cellMap: controller.cellMap?.captureViewMemory(pending: cellMapRestore))
    }

    /// Applies a kept view through the paths a person's change takes and returns what it lost. A cell map's zoom and
    /// selection wait for the embedding and colouring it reads (`RNASeqCellMapViewController.finishRestore`). An
    /// earlier restore still waiting ends here, so Reset View is never undone by it.
    public func restoreViewMemory(_ state: ViewState, dataChanged: Bool) -> ViewMemoryLoss {
        cellMapRestore?.cancelled = true
        cellMapRestore = nil
        bulkReselect?.cancel()
        bulkReselect = nil
        guard state.child == shownChild else {
            var lost: ViewMemoryLoss = [.place]
            if let bulk = state.bulk, !bulk.search.isEmpty { lost.insert(.filters) }
            if state.selectionCount > 0 || state.cellMap?.selection != nil { lost.insert(.selection) }
            return lost
        }
        var lost: ViewMemoryLoss = []
        if let bulk = state.bulk, let view = controller.bulk {
            lost.formUnion(view.restoreViewMemory(bulk, dataChanged: dataChanged))
            bulkRestore = bulk
        }
        if let map = state.cellMap, let view = controller.cellMap {
            let restored = view.restoreViewMemory(map, dataChanged: dataChanged)
            lost.formUnion(restored.lost)
            cellMapRestore = restored.pending
        }
        return lost
    }

    /// The host calls this once the route has installed the surface. The bulk view selects its kept genes again where a
    /// table dropped them at the model's reload after the restore, and once more after the quality read's reload. It
    /// starts nothing.
    public func announceViewMemory() {
        guard let kept = bulkRestore, let bulk = controller.bulk else {
            bulkRestore = nil
            return
        }
        bulkRestore = nil
        bulk.reselectKeptRows(kept)
        // The quality read ends later and the reload it causes can drop the rows of a table no window shows. The read is
        // already running, so waiting for it starts nothing (VS S4). `reselectKeptRows` leaves a table that has rows.
        bulkReselect?.cancel()
        bulkReselect = Task { [weak bulk] in
            await bulk?.model.qualityRead()
            guard !Task.isCancelled else { return }
            bulk?.reselectKeptRows(kept)
        }
    }
}
