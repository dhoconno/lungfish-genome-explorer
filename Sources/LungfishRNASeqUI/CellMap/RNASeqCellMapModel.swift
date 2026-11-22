// RNASeqCellMapModel.swift - What the embedding view reads from a cell map, and the colour of each cell (Phase 5.5 lane CM-VIEW)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Everything here is read from `cellmap.sqlite` through CM-KIND's reader, `RNASeqCellMapDatabase`, off the main actor,
// and each read checks for cancellation in its step loop. The coordinates load in one columnar read into Float32
// arrays in cell order, and no struct is made for each cell (5.5 V4). A cell's colour is the palette index of the
// value the file holds for it, and the draw order follows 5.5 V3. Nothing here is a number on screen. The legend's
// counts and bounds are the file's (`RNASeqEmbeddingLegend`).

import Foundation
import LungfishIO

/// What the plot can be coloured by. Each case reads one table of the cell map.
public enum RNASeqCellMapColouring: Hashable, Sendable {
    /// A label set by its `label_sets.label_set` number, read from `cell_labels`.
    case labelSet(Int)
    /// The sample of each cell, from `samples`.
    case sample
    /// The UMIs of each cell, read from `cells.umis`, with the `umis` row of `value_bounds`.
    case cellUMIs
    /// The genes of each cell, read from `cells.genes`, with the `genes` row of `value_bounds`.
    case cellGenes
    /// The not-host UMIs of an extra, read from `cell_not_host`, with the bounds of `value_bounds`.
    case notHostUMIs(extra: Int)
    /// The flag words of a virus or bacterium extra, read from `cell_not_host` and counted in `flag_counts`.
    case flag(extra: Int)
    /// One gene's values in one unit, read from `gene_values` with that unit's own bounds (5.5 G1).
    case gene(RNASeqGeneChoice)
}

/// The facts of a cell map that every colouring and embedding shares. All are values as stored.
public struct RNASeqCellMapFacts: Equatable, Sendable {
    public var embeddings: [RNASeqCellMapDatabase.Embedding]
    public var embeddingCells: [RNASeqCellMapDatabase.EmbeddingCells]
    public var samples: [RNASeqCellMapDatabase.Sample]
    public var labelSets: [RNASeqCellMapDatabase.LabelSet]
    public var valueBounds: [RNASeqCellMapDatabase.ValueBound]
    public var extras: [RNASeqCellMapDatabase.NotHostExtra]
    public var flagCounts: [RNASeqCellMapDatabase.FlagCount]
    /// `SELECT count(*) FROM cells`, every cell of the parent.
    public var cellCount: Int

    /// The embedding the view opens on, the first in file order (5.5 V6).
    public var defaultEmbedding: RNASeqCellMapDatabase.Embedding? { embeddings.first }

    /// The colouring the view opens on, the first label set, or the sample when the map holds none. Nothing is kept
    /// between opens (5.5 V6).
    public var defaultColouring: RNASeqCellMapColouring { labelSets.first.map { .labelSet($0.labelSet) } ?? .sample }

    /// Every colouring the cell map can give, in the order of the Colour by pop-up.
    public var colourings: [RNASeqCellMapColouring] {
        var found = labelSets.map { RNASeqCellMapColouring.labelSet($0.labelSet) } + [.sample, .cellUMIs, .cellGenes]
        for extra in extras {
            found.append(.notHostUMIs(extra: extra.extra))
            if flagCounts.contains(where: { $0.extra == extra.extra }) { found.append(.flag(extra: extra.extra)) }
        }
        return found
    }

    public func title(of colouring: RNASeqCellMapColouring) -> String {
        switch colouring {
        case .labelSet(let id): return labelSets.first { $0.labelSet == id }?.name ?? "Labels"
        case .sample: return "Sample"
        case .cellUMIs: return "UMIs per cell"
        case .cellGenes: return "Genes per cell"
        case .notHostUMIs(let extra): return "\(extraName(extra)) not-host UMIs"
        case .flag(let extra): return "\(extraName(extra)) flag"
        case .gene(let choice): return "\(choice.label) \(RNASeqEmbeddingWords.geneUnit(choice.unit))"
        }
    }

    func extraName(_ extra: Int) -> String { extras.first { $0.extra == extra }?.name ?? "extra \(extra)" }

    func sampleName(_ sample: Int) -> String { samples.first { $0.sample == sample }?.name ?? String(sample) }

    /// The sample of a cell from 0. Cells are numbered from 1 over all samples in sample order, so each sample's
    /// cells follow the cells of the samples before it (`docs/formats/rnaseq-cell-map.md`, cellmap.sqlite).
    func sampleIndex(ofCell cell: Int) -> Int {
        var end = 0
        for (index, sample) in samples.enumerated() {
            end += sample.cells
            if cell < end { return index }
        }
        return max(samples.count - 1, 0)
    }
}

/// Dimensions 1 and 2 of one embedding in cell order, NaN for a cell left out.
public struct RNASeqCellMapPoints: Sendable {
    public var embedding: Int
    public var x: ContiguousArray<Float32>
    public var y: ContiguousArray<Float32>

    public func isDrawn(_ cell: Int) -> Bool { x[cell].isFinite && y[cell].isFinite }
}

/// The values a colouring reads, as the file holds them.
public enum RNASeqCellMapValues: Sendable {
    /// The label number of each cell in cell order, 0 for no label.
    case labels(ContiguousArray<UInt32>)
    case samples
    /// The UMIs or the genes of each cell in cell order, from `cells`.
    case totals(ContiguousArray<UInt32>)
    /// The cells, from 1, with a count above 0, and their counts.
    case counts(cells: [Int], values: [Double])
    /// The cells, from 1, that carry flag words, and their words.
    case flags(cells: [Int], words: [String])
    /// One gene's cells with a count and their values in the unit asked, with the formula of its normalised value.
    case gene(RNASeqCellMapGeneRead)
}

/// A gene's row of `gene_values` for one unit, and the formula that `meta` records for the normalised value (nil for UMIs).
public struct RNASeqCellMapGeneRead: Sendable {
    public var values: RNASeqCellMapDatabase.GeneValues
    public var formula: String?
}

/// The colour and draw order of every cell for one colouring and one embedding, with the legend.
public struct RNASeqCellMapColours: Sendable {
    /// The palette index of each cell in cell order.
    public var index: ContiguousArray<UInt16>
    /// The drawn cells, from 0, first drawn first (5.5 V3).
    public var order: ContiguousArray<UInt32>
    public var legend: RNASeqEmbeddingLegend

    /// Colours `points` by `values`. Cells left out of the embedding are not in `order`.
    public static func make(facts: RNASeqCellMapFacts, colouring: RNASeqCellMapColouring, values: RNASeqCellMapValues,
                            points: RNASeqCellMapPoints) throws -> RNASeqCellMapColours {
        let count = points.x.count
        var index = ContiguousArray<UInt16>(repeating: RNASeqEmbeddingPalette.greyIndex, count: count)
        var under = ContiguousArray<UInt32>()
        var over = ContiguousArray<UInt32>()
        var legend = RNASeqEmbeddingLegend(title: facts.title(of: colouring), rows: [])
        switch (colouring, values) {
        case (.labelSet(let id), .labels(let labels)):
            let set = facts.labelSets.first { $0.labelSet == id }
            for cell in 0..<count {
                let label = cell < labels.count ? Int(labels[cell]) : 0
                if label > 0 { index[cell] = RNASeqEmbeddingPalette.labelIndex(label - 1) }
                guard points.isDrawn(cell) else { continue }
                if label > 0 { over.append(UInt32(cell)) } else { under.append(UInt32(cell)) }
                if cell & 0xFFFF == 0 { try Task.checkCancellation() }
            }
            let labelRows = set?.labels ?? []
            legend.rows = labelRows.map { .init(name: $0.name, count: String($0.cells), colour: RNASeqEmbeddingPalette.labelIndex($0.label - 1)) }
            if labelRows.count > RNASeqEmbeddingPalette.labelSlots { legend.words.append(RNASeqEmbeddingWords.coloursRepeat) }
            for sample in set?.samples ?? [] where sample.unlabelled > 0 {
                legend.words.append(RNASeqEmbeddingWords.unlabelled(sample.unlabelled, sample: facts.sampleName(sample.sample), set: set?.name ?? ""))
            }
        case (.sample, _):
            for cell in 0..<count {
                index[cell] = RNASeqEmbeddingPalette.labelIndex(facts.sampleIndex(ofCell: cell))
                if points.isDrawn(cell) { over.append(UInt32(cell)) }
            }
            legend.rows = facts.samples.enumerated().map { .init(name: $1.name, count: String($1.cells), colour: RNASeqEmbeddingPalette.labelIndex($0)) }
            if facts.samples.count > RNASeqEmbeddingPalette.labelSlots { legend.words.append(RNASeqEmbeddingWords.coloursRepeat) }
        case (.flag(let extra), .flags(let cells, let words)):
            let counts = facts.flagCounts.filter { $0.extra == extra }
            var named: [String] = []
            for row in counts where !row.flag.isEmpty && !named.contains(row.flag) { named.append(row.flag) }
            for (cell, word) in zip(cells, words) where cell >= 1 && cell <= count {
                if let slot = named.firstIndex(of: word) { index[cell - 1] = RNASeqEmbeddingPalette.labelIndex(slot) }
            }
            for cell in 0..<count where points.isDrawn(cell) {
                if index[cell] == RNASeqEmbeddingPalette.greyIndex { under.append(UInt32(cell)) } else { over.append(UInt32(cell)) }
            }
            func countText(_ flag: String) -> String {
                let rows = counts.filter { $0.flag == flag }
                if rows.count == 1 { return String(rows[0].cells) }
                return rows.map { "\($0.cells) in \(facts.sampleName($0.sample))" }.joined(separator: ", ")
            }
            legend.rows = named.enumerated().map { .init(name: $1, count: countText($1), colour: RNASeqEmbeddingPalette.labelIndex($0)) }
            if counts.contains(where: { $0.flag.isEmpty }) {
                legend.rows.append(.init(name: RNASeqEmbeddingWords.notFlagged, count: countText(""), colour: RNASeqEmbeddingPalette.greyIndex))
            }
        case (.notHostUMIs(let extra), .counts(let cells, let values)):
            var value = ContiguousArray<Double>(repeating: 0, count: count)
            for (cell, amount) in zip(cells, values) where cell >= 1 && cell <= count { value[cell - 1] = amount }
            return try scaled(facts: facts, points: points, legend: legend,
                              bound: facts.valueBounds.first { $0.value == "not_host_umis" && $0.extra == extra }) { value[$0] }
        case (.cellUMIs, .totals(let totals)), (.cellGenes, .totals(let totals)):
            let name = colouring == .cellUMIs ? "umis" : "genes"
            return try scaled(facts: facts, points: points, legend: legend,
                              bound: facts.valueBounds.first { $0.value == name && $0.extra == 0 }) { $0 < totals.count ? Double(totals[$0]) : 0 }
        case (.gene(let choice), .gene(let read)):
            // The gene goes through the helper of the count colourings with the stored bounds of the unit shown, so the p99
            // or maximum rule and the scale words stay in one place. W5 names the grey cells in place of the count's sentence.
            var value = ContiguousArray<Float32>(repeating: 0, count: count)
            for (cell, amount) in zip(read.values.cells, read.values.floats) where cell >= 1 && Int(cell) <= count { value[Int(cell) - 1] = amount }
            let stored = RNASeqEmbeddingLegend.Scale(minimum: read.values.minimum, maximum: read.values.maximum, p99: read.values.p99)
            var made = try scaled(facts: facts, points: points, legend: legend, scale: stored, grey: nil) { Double(value[$0]) }
            made.legend.words.insert(RNASeqEmbeddingWords.geneColour(unit: choice.unit, gene: choice.label), at: 0)
            made.legend.formula = choice.unit == .normalised ? read.formula ?? RNASeqResultBundle.notRecordedText : nil
            return made
        default:
            throw RNASeqResultError.invalidTable(path: RNASeqCellMap.filename, reason: "the values read do not belong to \(facts.title(of: colouring))")
        }
        return RNASeqCellMapColours(index: index, order: under + over, legend: legend)
    }

    /// Colours a count by the file's bounds, the one place of the rule for every count colouring. The scale runs from 0
    /// to its top, the p99 or the maximum when the p99 is 0, a value above the top takes the top colour, zeros draw first
    /// in grey and the rest in rising order (5.5 V3, `docs/formats/rnaseq-cell-map.md`, Bounds). `value` is the count of
    /// a cell from 0.
    private static func scaled(facts: RNASeqCellMapFacts, points: RNASeqCellMapPoints, legend: RNASeqEmbeddingLegend,
                               bound: RNASeqCellMapDatabase.ValueBound?, value: (Int) -> Double) throws -> RNASeqCellMapColours {
        let scale = RNASeqEmbeddingLegend.Scale(minimum: bound?.minimum ?? 0, maximum: bound?.maximum ?? 0, p99: bound?.p99 ?? 0)
        return try scaled(facts: facts, points: points, legend: legend, scale: scale, grey: RNASeqEmbeddingWords.greyHaveZero, value: value)
    }

    /// The same rule for a scale in hand, such as a gene's stored bounds. `grey` is the sentence that ends the scale words,
    /// or nil when other words name the grey cells.
    private static func scaled(facts: RNASeqCellMapFacts, points: RNASeqCellMapPoints, legend: RNASeqEmbeddingLegend,
                               scale: RNASeqEmbeddingLegend.Scale, grey: String?, value: (Int) -> Double) throws -> RNASeqCellMapColours {
        let count = points.x.count
        let top = RNASeqEmbeddingPalette.gradientSteps - 1
        var index = ContiguousArray<UInt16>(repeating: RNASeqEmbeddingPalette.greyIndex, count: count)
        var under = ContiguousArray<UInt32>()
        var risen: [(value: Double, cell: UInt32)] = []
        for cell in 0..<count {
            if cell & 0xFFFF == 0 { try Task.checkCancellation() }
            let amount = value(cell)
            if amount > 0, scale.top > 0 {
                index[cell] = RNASeqEmbeddingPalette.gradientBase + UInt16(min(Int(amount / scale.top * Double(top)), top))
            }
            guard points.isDrawn(cell) else { continue }
            if amount > 0 { risen.append((amount, UInt32(cell))) } else { under.append(UInt32(cell)) }
        }
        // Zeros first in grey, then the rest in rising order (5.5 V3). A sort is not a number on screen.
        risen.sort { $0.value != $1.value ? $0.value < $1.value : $0.cell < $1.cell }
        var legend = legend
        legend.scale = scale
        if scale.maximum <= 0 {
            legend.words.append(RNASeqEmbeddingWords.scaleAllZero(cells: facts.cellCount))
        } else if scale.p99 > 0 {
            legend.words.append(RNASeqEmbeddingWords.scale(p99: RNASeqEmbeddingWords.number(scale.p99),
                                                            maximum: RNASeqEmbeddingWords.number(scale.maximum), grey: grey))
        } else {
            legend.words.append(RNASeqEmbeddingWords.scaleToMaximum(maximum: RNASeqEmbeddingWords.number(scale.maximum), cells: facts.cellCount,
                                                                     grey: grey))
        }
        return RNASeqCellMapColours(index: index, order: under + ContiguousArray(risen.map(\.cell)), legend: legend)
    }
}

/// What the view opens with: the facts, the first embedding's points and the default colouring.
public struct RNASeqCellMapSnapshot: Sendable {
    public var database: RNASeqCellMapDatabase
    public var facts: RNASeqCellMapFacts
    public var points: RNASeqCellMapPoints
    public var colouring: RNASeqCellMapColouring
    public var values: RNASeqCellMapValues
    public var colours: RNASeqCellMapColours
}

/// What reading a cell map gave. It holds no state of the main actor, so a detached task can return it.
public enum RNASeqCellMapLoadOutcome: Sendable {
    case loaded(RNASeqCellMapSnapshot)
    case failed(String)
}

/// The reads of the embedding view, each synchronous so it runs inside a task off the main actor, and each through
/// CM-KIND's reader, which opens its own read-only handle and checks for cancellation in its step loop.
public enum RNASeqCellMapLoader {
    /// The `cellmap.sqlite` the manifest names, inside the result.
    public static func databaseURL(result: RNASeqResult, bundleURL: URL) throws -> URL {
        guard let entry = result.manifest.cellMap else {
            throw RNASeqResultError.unreadableFile(path: RNASeqCellMap.filename, reason: "the manifest names no cell map")
        }
        return try RNASeqResultBundle.resolve(entry.path, in: bundleURL)
    }

    public static func facts(_ database: RNASeqCellMapDatabase) throws -> RNASeqCellMapFacts {
        RNASeqCellMapFacts(
            embeddings: try database.embeddings(), embeddingCells: try database.embeddingCells(), samples: try database.samples(),
            labelSets: try database.labelSets(), valueBounds: try database.valueBounds(), extras: try database.notHostExtras(),
            flagCounts: try database.flagCounts(), cellCount: try database.cellCount())
    }

    public static func points(_ database: RNASeqCellMapDatabase, embedding: Int) throws -> RNASeqCellMapPoints {
        let read = try database.coordinates(embedding: embedding)
        return RNASeqCellMapPoints(embedding: embedding, x: read.x, y: read.y)
    }

    public static func values(_ database: RNASeqCellMapDatabase, colouring: RNASeqCellMapColouring) throws -> RNASeqCellMapValues {
        switch colouring {
        case .labelSet(let id):
            return .labels(try database.cellLabels(labelSet: id))
        case .sample:
            return .samples
        case .cellUMIs:
            return .totals(try database.cellTotals().umis)
        case .cellGenes:
            return .totals(try database.cellTotals().genes)
        case .notHostUMIs(let extra):
            let rows = try database.cellNotHost(extra: extra).filter { $0.umis > 0 }
            return .counts(cells: rows.map(\.cell), values: rows.map { Double($0.umis) })
        case .flag(let extra):
            let rows = try database.cellNotHost(extra: extra).filter { !$0.flag.isEmpty }
            return .flags(cells: rows.map(\.cell), words: rows.map(\.flag))
        case .gene(let choice):
            guard let found = try database.geneValues(feature: choice.feature, unit: choice.unit) else {
                throw RNASeqResultError.invalidTable(path: RNASeqCellMap.filename, reason: RNASeqEmbeddingWords.noGeneValues(choice.label))
            }
            try Task.checkCancellation()
            let formula = try choice.unit == .normalised ? database.meta()["normalisation"] : nil
            return .gene(RNASeqCellMapGeneRead(values: found, formula: formula))
        }
    }

    /// Reads what the view opens with. It only reads, so a result is never changed by being shown.
    public static func snapshot(result: RNASeqResult, bundleURL: URL) throws -> RNASeqCellMapSnapshot {
        let url = try databaseURL(result: result, bundleURL: bundleURL)
        let database = try RNASeqCellMapDatabase(url: url)
        let facts = try facts(database)
        guard let embedding = facts.defaultEmbedding else {
            throw RNASeqResultError.invalidTable(path: RNASeqCellMap.filename, reason: RNASeqEmbeddingWords.noEmbedding)
        }
        let points = try points(database, embedding: embedding.embedding)
        try Task.checkCancellation()
        let colouring = facts.defaultColouring
        let values = try values(database, colouring: colouring)
        let colours = try RNASeqCellMapColours.make(facts: facts, colouring: colouring, values: values, points: points)
        return RNASeqCellMapSnapshot(database: database, facts: facts, points: points, colouring: colouring, values: values, colours: colours)
    }

    /// Reads the snapshot off the main actor. A cancel of the calling task, such as the memory guard's cancel of the
    /// surface's `loadTask`, reaches the read, which stops at its next check.
    public static func load(result: RNASeqResult, bundleURL: URL) async -> RNASeqCellMapLoadOutcome {
        do {
            return .loaded(try await offMain { try snapshot(result: result, bundleURL: bundleURL) })
        } catch is CancellationError {
            return .failed(RNASeqEmbeddingWords.failed("The read was stopped."))
        } catch {
            return .failed(RNASeqSingleCellSummary.failureWords(error))
        }
    }
}

/// Runs `work` on a detached task and passes a cancel of the caller on to it, which a bare `Task.detached` does not.
func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    let task = Task.detached(priority: .userInitiated) { try work() }
    return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
}
