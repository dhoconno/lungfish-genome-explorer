// RNASeqCellMapViewController+ViewMemory.swift - The cell map keeps its embedding, colouring, size, zoom and selection
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The cell map's part of the RNA-seq result's view memory (`RNASeqResultSurface+ViewMemory.swift`). The embedding and the
// colouring are kept by the names a person reads, never by a number of the file, and the selection only as its one
// `cell-map select` form, never as its cells (VS B7). A restore reads another embedding or colouring through the same
// reread a person's choice starts, and the zoom and the selection wait for that read. The selection then runs the same
// select rule a person's lasso or legend click runs, off the main actor under `selectionGeneration`, never inline.

import AppKit
import LungfishIO
import LungfishKit
import LungfishWorkflow

/// What the cell map keeps for one result. Each field and its class (VS B2 to B9):
/// - `embedding`, by name, is presentation. A name the map no longer holds opens the first embedding, which is "your
///   place" in the reset line.
/// - `colouring`, by name, is presentation. A label set or an extra by its name, a gene by its id with the saved feature
///   only on an equal data key. One that is gone opens the default colouring, which is "your place".
/// - `pointSize` is presentation and always comes back, clamped to 1 to 8.
/// - `window`, the zoom and pan in the plane's units, is a place in coordinates, so it comes back only on an equal data
///   key and on the kept embedding (VS B2, B3), and is "your place" when dropped.
/// - `selection` is the one `cell-map select` form, a polygon in the plane or labels of one set. Both name other cells
///   after a rerun, so it comes back only on an equal data key (VS B3, B7, BIO OBJECT 2), and is "your selection" when
///   dropped. The mask and the legend rows are never kept, and a selection no one form names keeps nothing.
struct RNASeqCellMapViewMemory: Codable, Sendable, Equatable {
    /// A colouring by the name a person reads.
    enum Colouring: Codable, Sendable, Equatable {
        case labelSet(String)
        case sample
        case cellUMIs
        case cellGenes
        case notHostUMIs(extra: String)
        case flag(extra: String)
        case gene(id: String, name: String, feature: Int, umis: Bool, sharesName: Bool)
    }

    /// The one form of `lungfish-cli rnaseq cell-map select` that names the selection.
    enum Selection: Codable, Sendable, Equatable {
        /// The vertices as `RNASeqCellMapSelect.polygonText` writes them, which parse back to the same Float32 values.
        case polygon(String)
        case labels(set: String, labels: [String])
    }

    /// The part of the plane shown, in the embedding's units.
    struct Window: Codable, Sendable, Equatable {
        var minX: Float
        var minY: Float
        var maxX: Float
        var maxY: Float
    }

    var embedding: String?
    var colouring: Colouring?
    var pointSize: Double
    var window: Window?
    var selection: Selection?
}

/// The zoom and the selection a restore applies once the embedding and colouring it asked for are read (VS A2). It
/// applies only while no choice, zoom or selection was made since the restore, which the two counters tell.
@MainActor
final class RNASeqCellMapPendingRestore {
    let window: RNASeqCellMapViewMemory.Window?
    let selection: RNASeqCellMapViewMemory.Selection?
    var generation: Int
    var selectionGeneration: Int
    /// A later restore, a reset or a person's change ended it.
    var cancelled = false

    init(window: RNASeqCellMapViewMemory.Window?, selection: RNASeqCellMapViewMemory.Selection?,
         generation: Int, selectionGeneration: Int) {
        self.window = window
        self.selection = selection
        self.generation = generation
        self.selectionGeneration = selectionGeneration
    }

    /// Whether the view is still the one the restore left, so the rest of the kept view may still come.
    func applies(to map: RNASeqCellMapViewController) -> Bool {
        !cancelled && generation == map.generation && selectionGeneration == map.selectionGeneration
    }
}

extension RNASeqCellMapViewController {
    /// The view as the controls hold it, with the embedding and colouring a read in flight fetches, and the zoom and the
    /// selection a restore still waits to apply. Nil before a map is read. It reads no file and no store.
    func captureViewMemory(pending: RNASeqCellMapPendingRestore?) -> RNASeqCellMapViewMemory? {
        guard let shown = snapshot else { return nil }
        let facts = shown.facts
        let embedding = wantedEmbedding ?? shown.points.embedding
        var memory = RNASeqCellMapViewMemory(
            embedding: facts.embeddings.first { $0.embedding == embedding }?.name,
            colouring: Self.memory(of: wantedColouring ?? shown.colouring, in: facts),
            pointSize: pointSize,
            window: plotWindow.flatMap(Self.memory(of:)),
            selection: selection.flatMap { $0.embedding == embedding ? $0.form.flatMap(Self.memory(of:)) : nil })
        if let pending, pending.applies(to: self) {
            if memory.window == nil { memory.window = pending.window }
            if selection == nil { memory.selection = pending.selection }
        }
        return memory
    }

    /// Applies a kept view and returns what it lost with the part that waits for a read. The point size applies now, the
    /// embedding and the colouring through the reread a person's choice starts, and the zoom and the selection when that
    /// read ends, through `finishRestore`. It starts no write and no tool (VS S4). A view the kept one does not hold, such
    /// as the start that Reset View hands back, clears the zoom and the selection.
    func restoreViewMemory(_ memory: RNASeqCellMapViewMemory,
                           dataChanged: Bool) -> (lost: ViewMemoryLoss, pending: RNASeqCellMapPendingRestore?) {
        guard let shown = snapshot else { return ([], nil) }
        let facts = shown.facts
        var lost: ViewMemoryLoss = []
        choosePointSize(memory.pointSize)

        let found = memory.embedding.flatMap { name in facts.embeddings.first { $0.name == name } }
        if memory.embedding != nil, found == nil { lost.insert(.place) }
        let embedding = (found ?? facts.defaultEmbedding)?.embedding ?? shown.points.embedding
        let resolved = memory.colouring.flatMap { Self.colouring($0, in: facts, dataChanged: dataChanged) }
        if memory.colouring != nil, resolved == nil { lost.insert(.place) }
        let colouring = resolved ?? facts.defaultColouring

        // A zoom and a selection are coordinates of the plane, so a changed key or another embedding drops them (VS B3).
        let sameEmbedding = found != nil && !dataChanged
        if memory.window != nil, !sameEmbedding { lost.insert(.place) }
        if memory.selection != nil, !sameEmbedding { lost.insert(.selection) }
        let window = sameEmbedding ? memory.window : nil
        let kept = sameEmbedding ? memory.selection : nil

        if window == nil, plotWindow != nil {
            plotWindow = nil
            requestRaster()
        }
        if kept == nil, selection != nil { clearSelection() }
        if case .gene(let choice) = colouring { geneUnit = choice.unit }
        let rereads = wantedEmbedding != nil || wantedColouring != nil
            || embedding != shown.points.embedding || colouring != shown.colouring
        if rereads {
            wantedEmbedding = embedding
            wantedColouring = colouring
            rereadWanted()
        }
        guard window != nil || kept != nil else { return (lost, nil) }
        let pending = RNASeqCellMapPendingRestore(
            window: window, selection: kept, generation: generation, selectionGeneration: selectionGeneration)
        // The rest runs in the view's `work` task after the read it waits for, never inline at the restore.
        let reading = rereads ? readWork : nil
        work = Task { [weak self] in
            await reading?.value
            self?.finishRestore(pending)
        }
        return (lost, pending)
    }

    /// Applies the zoom, then runs the kept selection's form through the select rule a person's lasso or legend click
    /// runs, off the main actor under `selectionGeneration`. Nothing applies when a choice, a zoom or a selection was made
    /// since the restore, or when the read failed (VS A2).
    func finishRestore(_ pending: RNASeqCellMapPendingRestore) {
        guard pending.applies(to: self), plotWindow == nil, let shown = snapshot else {
            pending.cancelled = true
            return
        }
        if let window = pending.window {
            plotWindow = RNASeqEmbeddingWindow(minX: window.minX, minY: window.minY, maxX: window.maxX, maxY: window.maxY)
            requestRaster()
        }
        guard let kept = pending.selection else { return }
        runKeptSelection(kept, in: shown)
        // The run bumped the counter, and the pending selection stands for the view until the run shows it.
        pending.selectionGeneration = selectionGeneration
    }

    /// Runs a kept form as one `cell-map select` of it would: a polygon through the lasso's path, and labels by name
    /// through the legend's rule, reading the set's labels off the main actor when another colouring is on show.
    private func runKeptSelection(_ kept: RNASeqCellMapViewMemory.Selection, in shown: RNASeqCellMapSnapshot) {
        switch kept {
        case .polygon(let text):
            guard let vertices = try? RNASeqCellMapSelect.parsePolygon(text) else { return }
            selectPolygon(vertices, mode: .replace)
        case .labels(let name, let names):
            guard let set = shown.facts.labelSets.first(where: { $0.name == name }), !names.isEmpty else { return }
            var rows = Set<Int>()
            var chosen = Set<UInt32>()
            for label in names {
                guard let row = set.labels.firstIndex(where: { $0.name == label }),
                      (1...set.labels.count).contains(set.labels[row].label) else { return }
                rows.insert(row)
                chosen.insert(UInt32(set.labels[row].label))
            }
            let colouring = RNASeqCellMapColouring.labelSet(set.labelSet)
            var onShow: ContiguousArray<UInt32>?
            if shown.colouring == colouring, case .labels(let labels) = shown.values { onShow = labels }
            let database = shown.database
            let labelSet = set.labelSet
            let (shownLabels, wanted) = (onShow, chosen)
            runSelection(rule: { .labels(shownLabels ?? ((try? database.cellLabels(labelSet: labelSet)) ?? []), chosen: wanted) },
                         mode: .replace, form: .labels(set: name, labels: names), rows: rows, rowsColouring: colouring,
                         polygon: nil)
        }
    }

    // MARK: - Names

    static func memory(of colouring: RNASeqCellMapColouring, in facts: RNASeqCellMapFacts) -> RNASeqCellMapViewMemory.Colouring? {
        switch colouring {
        case .labelSet(let id): return facts.labelSets.first { $0.labelSet == id }.map { .labelSet($0.name) }
        case .sample: return .sample
        case .cellUMIs: return .cellUMIs
        case .cellGenes: return .cellGenes
        case .notHostUMIs(let extra): return facts.extras.first { $0.extra == extra }.map { .notHostUMIs(extra: $0.name) }
        case .flag(let extra): return facts.extras.first { $0.extra == extra }.map { .flag(extra: $0.name) }
        case .gene(let choice):
            return .gene(id: choice.id, name: choice.name, feature: choice.feature, umis: choice.unit == .umis,
                         sharesName: choice.sharesName)
        }
    }

    /// The colouring a kept name stands for in this map, or nil when it is gone. A gene comes back only on an equal key,
    /// where its saved feature still names it.
    static func colouring(_ kept: RNASeqCellMapViewMemory.Colouring, in facts: RNASeqCellMapFacts,
                          dataChanged: Bool) -> RNASeqCellMapColouring? {
        let found: RNASeqCellMapColouring?
        switch kept {
        case .labelSet(let name): found = facts.labelSets.first { $0.name == name }.map { .labelSet($0.labelSet) }
        case .sample: found = .sample
        case .cellUMIs: found = .cellUMIs
        case .cellGenes: found = .cellGenes
        case .notHostUMIs(let name): found = facts.extras.first { $0.name == name }.map { .notHostUMIs(extra: $0.extra) }
        case .flag(let name): found = facts.extras.first { $0.name == name }.map { .flag(extra: $0.extra) }
        case .gene(let id, let name, let feature, let umis, let sharesName):
            return dataChanged ? nil : .gene(RNASeqGeneChoice(feature: feature, id: id, name: name,
                                                              unit: umis ? .umis : .normalised, sharesName: sharesName))
        }
        return found.flatMap { facts.colourings.contains($0) ? $0 : nil }
    }

    static func memory(of window: RNASeqEmbeddingWindow) -> RNASeqCellMapViewMemory.Window? {
        let values = [window.minX, window.minY, window.maxX, window.maxY]
        guard values.allSatisfy(\.isFinite) else { return nil }
        return RNASeqCellMapViewMemory.Window(minX: window.minX, minY: window.minY, maxX: window.maxX, maxY: window.maxY)
    }

    static func memory(of form: RNASeqCellMapSelect.Form) -> RNASeqCellMapViewMemory.Selection? {
        switch form {
        case .polygon(let vertices):
            guard vertices.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            return .polygon(RNASeqCellMapSelect.polygonText(vertices))
        case .labels(let set, let labels):
            return .labels(set: set, labels: labels)
        }
    }
}
