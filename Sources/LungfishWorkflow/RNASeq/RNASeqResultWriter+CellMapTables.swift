// RNASeqResultWriter+CellMapTables.swift - The parent of a cell map and the rows of its cellmap.sqlite (Phase 5.5 lane CM-KIND)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The writer reads the single-cell parent once, after its sha256 values match, and writes every row of `cellmap.sqlite`
// (`docs/formats/rnaseq-cell-map.md`, cellmap.sqlite): the cells, each embedding and its cells left out for each sample,
// each label set with its counts in total and for each sample, `gene_values` through `RNASeqCellMapGenes`, the not-host
// values and every bound. Each count is the writer's, so the view counts nothing.

import Foundation
import LungfishCore
import LungfishIO

/// The single-cell parent of a cell map, checked and read. Cells are held a column at a time, in cell order.
struct CellMapParent {
    struct Cells {
        var sample: [Int32] = []
        var barcode: [String] = []
        var umis: [UInt64] = []
        var genes: [UInt32] = []
        var count: Int { barcode.count }
    }

    let url: URL
    let manifest: RNASeqResultManifest
    let manifestSHA256: String
    let database: RNASeqCellsDatabase
    let samples: [RNASeqCellsDatabase.Sample]
    let sampleNames: [Int: String]
    let features: [RNASeqCellsDatabase.Feature]
    let cells: Cells
    let firstCell: [Int: Int]

    /// Refuses a parent that is not a single-cell result, or whose files differ from its manifest, before any read of
    /// its matrices.
    init(_ url: URL) throws {
        self.url = url
        manifest = try RNASeqResultBundle.loadManifest(from: url)
        guard manifest.modality == .singleCell else {
            throw RNASeqCellMapError.parentNotSingleCell(name: manifest.name, isCellMap: manifest.modality == .cellMap)
        }
        guard let matrices = manifest.matrices, !matrices.isEmpty, let summary = manifest.cellsSummary else {
            throw RNASeqPseudobulkRefusal.noCells(name: manifest.name)
        }
        var changed: [String] = []
        for mismatch in try RNASeqResultBundle.verifyChecksums(of: url) where !changed.contains(mismatch.path) { changed.append(mismatch.path) }
        guard changed.isEmpty else { throw RNASeqPseudobulkRefusal.checksumsDiffer(name: manifest.name, paths: changed) }
        manifestSHA256 = try RNASeqResultBundle.sha256Hex(fileAt: RNASeqResultBundle.manifestURL(in: url))
        database = try RNASeqCellsDatabase(url: try RNASeqResultBundle.resolve(summary.path, in: url))
        samples = try database.samples()
        sampleNames = Dictionary(samples.map { ($0.sample, $0.name) }, uniquingKeysWith: { first, _ in first })
        features = try database.features()
        var cells = Cells()
        var firstCell: [Int: Int] = [:]
        let total = try database.cellCount()
        let page = 1 << 16
        for offset in stride(from: 0, to: total, by: page) {
            try Task.checkCancellation()
            for cell in try database.cells(offset: offset, limit: page) {
                // Cells run from 1 over every sample, and a sample's columns from 1 with no gap.
                let first = cell.cell - cell.column + 1
                guard cell.cell == cells.count + 1, firstCell[cell.sample, default: first] == first else {
                    throw RNASeqResultError.invalidTable(path: summary.path, reason: "its cells are not numbered 1 to \(total) in sample and column order")
                }
                firstCell[cell.sample] = first
                cells.sample.append(Int32(cell.sample))
                cells.barcode.append(cell.barcode)
                cells.umis.append(UInt64(max(0, cell.umis)))
                cells.genes.append(UInt32(max(0, cell.genes)))
            }
        }
        self.cells = cells
        self.firstCell = firstCell
    }
}

extension RNASeqResultWriter {
    /// Writes every row of `cellmap.sqlite` but the commit, and returns the summary without its outputs.
    func writeTables(
        _ request: CellMapRequest, parent: CellMapParent, writer: RNASeqCellMapDatabaseWriter, spill: URL,
        observe: ((RNASeqCellMapGenes.Step) throws -> Void)?
    ) throws -> CellMapSummary {
        let cellsSHA256 = parent.manifest.cellsSummary?.sha256 ?? ""
        try writer.setMeta("parent_manifest_sha256", parent.manifestSHA256)
        try writer.setMeta("parent_cells_sha256", cellsSHA256)
        let samples = parent.samples.map { CellMapSummary.Sample(sample: $0.sample, name: $0.name, cells: $0.cells) }
        try writer.addSamples(samples.map { ($0.sample, $0.name, $0.cells) })
        try writer.addCells(firstCell: 1, samples: parent.cells.sample, barcodes: parent.cells.barcode, umis: parent.cells.umis, genes: parent.cells.genes)
        try writer.addFeatures(parent.features.map { ($0.feature, $0.id, $0.name, $0.type, $0.total, $0.cells) })
        let position = Dictionary(samples.enumerated().map { ($1.sample, $0) }, uniquingKeysWith: { first, _ in first })
        func perSample(_ cells: [Int32]) -> [Int] {
            var counts = [Int](repeating: 0, count: samples.count)
            for cell in cells { if let index = position[Int(parent.cells.sample[Int(cell) - 1])] { counts[index] += 1 } }
            return counts
        }

        var embeddingCounts: [CellMapSummary.EmbeddingCount] = []
        for (index, embedding) in request.embeddings.enumerated() {
            try Task.checkCancellation()
            let number = index + 1
            try writer.addEmbedding(number, name: embedding.name, dimensions: embedding.dimensions, method: embedding.method,
                                    source: embedding.source.rawValue, sourceFile: embedding.sourceFile, otherCounts: embedding.otherCounts,
                                    cells: embedding.cells.count)
            let drawn = perSample(embedding.cells)
            let leftOut = samples.indices.map { samples[$0].cells - drawn[$0] }
            for (place, sample) in samples.enumerated() {
                try writer.addEmbeddingCells(number, sample: sample.sample, drawn: drawn[place], leftOut: leftOut[place])
            }
            for dimension in 0..<embedding.dimensions {
                try writer.addCoordinates(number, dimension: dimension + 1, cells: embedding.cells) { embedding.values[$0 * embedding.dimensions + dimension] }
            }
            embeddingCounts.append(.init(name: embedding.name, drawn: drawn, leftOut: leftOut))
        }

        var labelCounts: [CellMapSummary.LabelSetCount] = []
        for (index, set) in request.labelSets.enumerated() {
            try Task.checkCancellation()
            let number = index + 1
            let order = RNASeqCellMap.labelOrder(set.labels)
            let idOf = Dictionary(order.enumerated().map { ($1, Int32($0 + 1)) }, uniquingKeysWith: { first, _ in first })
            let ids = set.labels.map { idOf[$0] ?? 0 }
            var cellsOfLabel = [Int](repeating: 0, count: order.count)
            var bySample = [[Int]](repeating: [Int](repeating: 0, count: samples.count), count: order.count)
            for (cell, id) in zip(set.cells, ids) {
                cellsOfLabel[Int(id) - 1] += 1
                if let place = position[Int(parent.cells.sample[Int(cell) - 1])] { bySample[Int(id) - 1][place] += 1 }
            }
            let table = "labels/\(RNASeqCellMap.labelTableFileName(set.name))"
            try writer.addLabelSet(number, name: set.name, source: set.source.rawValue, sourceFile: set.sourceFile,
                                   labels: zip(order, cellsOfLabel).map { ($0, $1) }, table: table)
            for label in order.indices {
                for (place, sample) in samples.enumerated() where bySample[label][place] > 0 {
                    try writer.addLabelCount(number, label: label + 1, sample: sample.sample, cells: bySample[label][place])
                }
            }
            let labelled = perSample(set.cells)
            let unlabelled = samples.indices.map { samples[$0].cells - labelled[$0] }
            for (place, sample) in samples.enumerated() {
                try writer.addLabelSetSample(number, sample: sample.sample, labelled: labelled[place], unlabelled: unlabelled[place])
            }
            try writer.addCellLabels(number, cells: set.cells, labels: ids)
            labelCounts.append(.init(name: set.name, table: table, labels: order, cells: cellsOfLabel, labelled: labelled, unlabelled: unlabelled))
        }

        var matrices: [RNASeqCellMapGenes.Matrix] = []
        var inputs: [Manifest.FileEntry] = []
        for entry in parent.manifest.matrices ?? [] {
            guard let sample = parent.samples.first(where: { $0.name == entry.sample }), let first = parent.firstCell[sample.sample] ?? (sample.cells == 0 ? 1 : nil) else {
                throw RNASeqResultError.invalidTable(path: RNASeqCellsDatabase.filename, reason: "it lists no sample \(entry.sample)")
            }
            matrices.append(.init(url: try RNASeqResultBundle.resolve(entry.matrix.path, in: parent.url), path: entry.matrix.path,
                                  firstCell: first, columns: sample.cells))
            inputs += [entry.matrix, entry.features, entry.barcodes]
        }
        let genes = try RNASeqCellMapGenes.run(
            matrices: matrices, features: parent.features, cellUMIs: parent.cells.umis, notHost: Set(parent.manifest.notHost),
            spill: spill, writer: writer, observe: { step in
                try observe?(step)
                try Task.checkCancellation()
            })

        try writeNotHost(parent: parent, writer: writer)
        let umis = RNASeqCellMap.bounds(nonZero: parent.cells.umis.filter { $0 > 0 }, cells: parent.cells.count)
        try writer.addValueBounds("umis", extra: 0, minimum: Double(umis.minimum), maximum: Double(umis.maximum), p99: Double(umis.p99))
        let geneCounts = RNASeqCellMap.bounds(nonZero: parent.cells.genes.filter { $0 > 0 }, cells: parent.cells.count)
        try writer.addValueBounds("genes", extra: 0, minimum: Double(geneCounts.minimum), maximum: Double(geneCounts.maximum), p99: Double(geneCounts.p99))
        return CellMapSummary(
            parentManifestSHA256: parent.manifestSHA256, parentCellsSHA256: cellsSHA256, parentInputs: inputs, samples: samples,
            embeddings: embeddingCounts, labelSets: labelCounts, genes: genes, cellMapBytes: 0, outputs: [])
    }

    /// The not-host extras, each cell's UMIs of an extra's own figure (record 0) and flag, the flag counts of each virus
    /// or bacterium extra over every cell of each sample, and the bound of each extra's UMIs.
    private func writeNotHost(parent: CellMapParent, writer: RNASeqCellMapDatabaseWriter) throws {
        let extras = try parent.database.notHostExtras()
        guard !extras.isEmpty else { return }
        var cellOf: [Int: [String: Int]] = [:]
        for index in 0..<parent.cells.count { cellOf[Int(parent.cells.sample[index]), default: [:]][parent.cells.barcode[index]] = index + 1 }
        var umisOf: [Int: [Int: Int]] = [:]
        for count in try parent.database.notHostCounts() where count.record == 0 && count.umis > 0 {
            if let cell = cellOf[count.sample]?[count.barcode] { umisOf[count.extra, default: [:]][cell] = count.umis }
        }
        var flagOf: [Int: [Int: String]] = [:]
        for call in try parent.database.notHostCalls() where !call.flag.isEmpty { flagOf[call.extra, default: [:]][call.cell] = call.flag }
        for extra in extras {
            try writer.addNotHostExtra(extra.extra, name: extra.name, kind: extra.kind)
            let umis = umisOf[extra.extra] ?? [:]
            let flags = flagOf[extra.extra] ?? [:]
            for cell in Set(umis.keys).union(flags.keys).sorted() {
                try writer.addCellNotHost(cell: cell, extra: extra.extra, umis: umis[cell] ?? 0, flag: flags[cell] ?? "")
            }
            if extra.kind == ReferenceSetExtraKind.virus.rawValue || extra.kind == ReferenceSetExtraKind.bacterium.rawValue {
                for sample in parent.samples {
                    var counts: [String: Int] = [:]
                    for index in 0..<parent.cells.count where Int(parent.cells.sample[index]) == sample.sample {
                        counts[flags[index + 1] ?? "", default: 0] += 1
                    }
                    for flag in counts.keys.sorted(by: RNASeqCellMap.codePointOrder) {
                        try writer.addFlagCount(extra: extra.extra, sample: sample.sample, flag: flag, cells: counts[flag] ?? 0)
                    }
                }
            }
            let bounds = RNASeqCellMap.bounds(nonZero: Array(umis.values), cells: parent.cells.count)
            try writer.addValueBounds("not_host_umis", extra: extra.extra, minimum: Double(bounds.minimum), maximum: Double(bounds.maximum), p99: Double(bounds.p99))
        }
    }
}
