// RNASeqPseudobulk+Pass.swift - The one pass over each matrix and the writer's request (Phase 5.2 lane RS-PSEUDOBULK)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The pass reads each matrix under `source/` once, after `RNASeqResultBundle.verifyChecksums`, and adds every entry of a
// `Gene Expression` feature to its cell's group in whole numbers. Memory is one batch of entries, the barcodes of the
// result and one sum a gene for each group kept.

import Foundation
import LungfishCore
import LungfishIO

extension RNASeqPseudobulk {
    /// Reads, checks and sums `result` by `labels`. Writes nothing, and every refusal comes before the first matrix.
    public static func sum(result: URL, labels: URL, name: String, createdAt: Date = Date()) throws -> Outcome {
        let manifest = try RNASeqResultBundle.loadManifest(from: result)
        if manifest.modality == .cellMap {
            throw RNASeqCellMapError.cellMapGiven(name: manifest.name, parent: manifest.parent?.path ?? RNASeqResultBundle.notRecordedText, use: .pseudobulk)
        }
        guard manifest.modality == .singleCell else { throw RNASeqPseudobulkRefusal.bulkResult(name: manifest.name) }
        guard let matrices = manifest.matrices, !matrices.isEmpty, let summary = manifest.cellsSummary else {
            throw RNASeqPseudobulkRefusal.noCells(name: manifest.name)
        }
        var changed: [String] = []
        for mismatch in try RNASeqResultBundle.verifyChecksums(of: result) where !changed.contains(mismatch.path) { changed.append(mismatch.path) }
        guard changed.isEmpty else { throw RNASeqPseudobulkRefusal.checksumsDiffer(name: manifest.name, paths: changed) }
        let loaded = try RNASeqResultBundle.load(from: result)
        let database = try RNASeqCellsDatabase(url: try RNASeqResultBundle.resolve(summary.path, in: result))
        let samples = try database.samples()
        let features = try database.features()
        var sampleCells = samples.map { SampleCells(name: $0.name, count: $0.cells, columnOfBarcode: [:]) }
        let indexOfNumber = Dictionary(samples.enumerated().map { ($1.sample, $0) }, uniquingKeysWith: { first, _ in first })
        for cell in try database.cells(offset: 0, limit: try database.cellCount()) {
            if let index = indexOfNumber[cell.sample] { sampleCells[index].columnOfBarcode[cell.barcode] = cell.column }
        }
        try Task.checkCancellation()
        let assignment = try assign(labels: labels, samples: sampleCells)
        var groups = assignment.groups
        let keptPositions = groups.indices.filter { groups[$0].cells >= minimumCells }
        guard !keptPositions.isEmpty else { throw RNASeqPseudobulkRefusal.noGroupLeft(file: labels.lastPathComponent) }

        var geneOfRow = [Int](repeating: -1, count: features.count)
        var geneIDs: [String] = []
        var otherTypes: [String: Int] = [:]
        for feature in features where feature.feature >= 1 && feature.feature <= features.count {
            if feature.type == geneExpression {
                geneOfRow[feature.feature - 1] = geneIDs.count
                geneIDs.append(feature.id)
            } else {
                otherTypes[feature.type, default: 0] += 1
            }
        }
        var slot = [Int](repeating: -1, count: groups.count)
        for (position, index) in keptPositions.enumerated() { slot[index] = position }
        let geneCount = geneIDs.count
        var sums = [UInt64](repeating: 0, count: keptPositions.count * geneCount)
        var groupUMIs = [UInt64](repeating: 0, count: groups.count)
        var unlabelledUMIs = [UInt64](repeating: 0, count: samples.count)
        for entry in matrices {
            guard let sample = samples.firstIndex(where: { $0.name == entry.sample }) else {
                throw RNASeqResultError.invalidTable(path: summary.path, reason: "it lists no sample \(entry.sample)")
            }
            let groupOfColumn = assignment.groupOfCell[sample]
            let reader = try MatrixMarketReader(url: try RNASeqResultBundle.resolve(entry.matrix.path, in: result))
            defer { reader.close() }
            guard reader.size.rows == features.count, reader.size.columns == groupOfColumn.count else {
                throw RNASeqResultError.invalidTable(path: entry.matrix.path, reason: "its size line differs from the counts of cells.sqlite")
            }
            var batch = MatrixMarketBatch(capacity: 1 << 16)
            while try reader.next(&batch) {
                try Task.checkCancellation()
                let rows = batch.rows
                let columns = batch.columns
                let values = batch.values
                for index in 0..<values.count {
                    let gene = geneOfRow[rows[index] - 1]
                    guard gene >= 0 else { continue }
                    let group = groupOfColumn[columns[index] - 1]
                    guard group >= 0 else {
                        unlabelledUMIs[sample] &+= values[index]
                        continue
                    }
                    groupUMIs[group] &+= values[index]
                    if slot[group] >= 0 { sums[slot[group] * geneCount + gene] &+= values[index] }
                }
            }
        }
        for index in groups.indices { groups[index].umis = groupUMIs[index] }
        let kept = keptPositions.map { groups[$0] }
        let dropped = groups.filter { $0.cells < minimumCells }
        let unlabelled = samples.indices.compactMap { index -> Unlabelled? in
            let cells = assignment.groupOfCell[index].filter { $0 < 0 }.count
            return cells > 0 ? Unlabelled(sample: samples[index].name, cells: cells, umis: unlabelledUMIs[index]) : nil
        }
        let table = RNASeqCountTable(sampleIDs: kept.map(\.column), rows: geneIDs.enumerated().map { gene, id in
            .init(id: id, counts: kept.indices.map { Double(sums[$0 * geneCount + gene]) })
        })
        return try outcome(
            Summed(kept: kept, dropped: dropped, unlabelled: unlabelled, geneIDs: geneIDs, otherTypes: otherTypes, table: table),
            manifest: manifest, loaded: loaded, result: result, labels: labels, name: name, createdAt: createdAt)
    }
}
