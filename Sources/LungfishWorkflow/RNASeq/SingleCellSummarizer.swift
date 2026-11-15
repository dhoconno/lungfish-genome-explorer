// SingleCellSummarizer.swift - One streaming pass over each kept matrix into cells.sqlite (Phase 5.2 lane RS-SC-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The writer calls this in its stage, after it has copied and hashed the tool's files, so the pass reads the copy whose
// sha256 the manifest and `meta` hold, and reads it once (`docs/formats/rnaseq-bundle.md`, Single cell). Each cell's
// UMIs and genes count only `Gene Expression` features, as compare.py keeps them, and every feature's total and cells
// count its own entries. Memory is one batch of entries plus arrays of the cells and features of one sample.

import Foundation
import LungfishIO

final class SingleCellSummarizer {
    private let database: RNASeqCellsDatabaseWriter
    private let genomes: [String]
    private var nextCell = 1
    private var sampleNumber = 0
    private var featureIDs: [String]?
    private var featureNames: [String] = []
    private var featureTypes: [String] = []
    /// -1 for a feature outside a cell's totals, 0 for a gene of no named genome, else the genome's number.
    private var rowClass: [Int] = []
    private var totals: [UInt64] = []
    private var cellsOfRow: [UInt32] = []

    init(url: URL, genomes: [String]) throws {
        database = try RNASeqCellsDatabaseWriter(url: url)
        self.genomes = genomes
        do { try database.addGenomes(genomes) } catch {
            database.abandon()
            throw error
        }
    }

    /// Reads one sample's matrix, features and barcodes, each a kept file of the stage, and returns its size line.
    func add(
        sample: String, matrix: RNASeqResultManifest.SourceFileEntry, features: RNASeqResultManifest.SourceFileEntry,
        barcodes: RNASeqResultManifest.SourceFileEntry, in stage: URL
    ) throws -> (size: MatrixMarketSize, isGzip: Bool) {
        let rows = try MatrixMarketReader.textLines(of: stage.appendingPathComponent(features.path)).map {
            $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        }
        let barcodeList = try MatrixMarketReader.textLines(of: stage.appendingPathComponent(barcodes.path))
        let ids = rows.map { $0.first ?? "" }
        if let known = featureIDs {
            guard known == ids else { throw SingleCellImportError.featuresDiffer(first: "the first sample", other: sample) }
        } else {
            featureIDs = ids
            featureNames = rows.map { $0.count > 1 ? $0[1] : "" }
            featureTypes = rows.map { $0.count > 2 ? $0[2] : SingleCellFolderReader.geneExpression }
            rowClass = zip(ids, featureTypes).map { id, type in
                guard type == SingleCellFolderReader.geneExpression else { return -1 }
                return genomes.firstIndex { id.hasPrefix($0 + "_") }.map { $0 + 1 } ?? 0
            }
            totals = [UInt64](repeating: 0, count: ids.count)
            cellsOfRow = [UInt32](repeating: 0, count: ids.count)
        }
        let reader = try MatrixMarketReader(url: stage.appendingPathComponent(matrix.path))
        defer { reader.close() }
        let size = reader.size
        guard size.rows == ids.count else {
            throw SingleCellImportError.sizeDiffers(sample: sample, what: "features", stated: size.rows, file: (features.path as NSString).lastPathComponent, listed: ids.count)
        }
        guard size.columns == barcodeList.count else {
            throw SingleCellImportError.sizeDiffers(
                sample: sample, what: "barcodes", stated: size.columns, file: (barcodes.path as NSString).lastPathComponent, listed: barcodeList.count)
        }
        var umis = [UInt64](repeating: 0, count: size.columns)
        var genes = [UInt32](repeating: 0, count: size.columns)
        var genomeUMIs = [[UInt64]](repeating: [UInt64](repeating: 0, count: size.columns), count: genomes.count)
        var genomeGenes = [[UInt32]](repeating: [UInt32](repeating: 0, count: size.columns), count: genomes.count)
        var batch = MatrixMarketBatch(capacity: 1 << 16)
        while try reader.next(&batch) {
            try Task.checkCancellation()
            let batchRows = batch.rows
            let batchColumns = batch.columns
            let batchValues = batch.values
            for index in 0..<batchValues.count {
                let value = batchValues[index]
                guard value > 0 else { continue }
                let row = batchRows[index] - 1
                let column = batchColumns[index] - 1
                totals[row] &+= value
                cellsOfRow[row] &+= 1
                let kind = rowClass[row]
                guard kind >= 0 else { continue }
                umis[column] &+= value
                genes[column] &+= 1
                if kind > 0 {
                    genomeUMIs[kind - 1][column] &+= value
                    genomeGenes[kind - 1][column] &+= 1
                }
            }
        }
        sampleNumber += 1
        try database.addSample(sampleNumber, name: sample, matrix: matrix.path, size: size)
        try database.addCells(sample: sampleNumber, firstCell: nextCell, barcodes: barcodeList, umis: umis, genes: genes)
        for genome in genomes.indices {
            try database.addCellGenomes(firstCell: nextCell, genome: genome + 1, umis: genomeUMIs[genome], genes: genomeGenes[genome])
        }
        for file in [matrix, features, barcodes] { try database.setMeta("sha256:\(file.path)", file.sha256) }
        nextCell += size.columns
        return (size, reader.isGzip)
    }

    /// Writes the features with their totals, builds the barcode index and commits.
    func finish() throws {
        try database.addFeatures(
            ids: featureIDs ?? [], names: featureNames, types: featureTypes,
            genomes: rowClass.map { $0 > 0 ? $0 : nil }, totals: totals, cells: cellsOfRow)
        try database.finish()
    }

    func abandon() { database.abandon() }
}

extension RNASeqResultWriter {
    /// The matrices of a single-cell request, read once each from their copies under `source/` into `cells.sqlite`.
    func writeCells(_ request: Request, copied: CopiedSources, into stage: URL) throws -> ([Manifest.MatrixEntry]?, Manifest.CellsSummary?) {
        guard let inputs = request.matrices else { return (nil, nil) }
        let url = stage.appendingPathComponent(RNASeqCellsDatabase.filename)
        let pass = try SingleCellSummarizer(url: url, genomes: request.genomes)
        var entries: [Manifest.MatrixEntry] = []
        do {
            for input in inputs {
                func kept(_ relative: String) throws -> Manifest.SourceFileEntry {
                    let path = "source/\(copied.folders[input.sample] ?? input.sample)/\(relative)"
                    guard let found = copied.entries.first(where: { $0.path == path }) else { throw RNASeqResultWriterError.matrixFileNotKept(path) }
                    return found
                }
                let matrix = try kept(input.matrix)
                let features = try kept(input.features)
                let barcodes = try kept(input.barcodes)
                let read = try pass.add(sample: input.sample, matrix: matrix, features: features, barcodes: barcodes, in: stage)
                entries.append(.init(
                    sample: input.sample, matrix: .init(path: matrix.path, sha256: matrix.sha256),
                    features: .init(path: features.path, sha256: features.sha256), barcodes: .init(path: barcodes.path, sha256: barcodes.sha256),
                    isGzip: read.isGzip, cellCount: read.size.columns, featureCount: read.size.rows, entryCount: read.size.entries))
            }
            try pass.finish()
        } catch {
            pass.abandon()
            throw error
        }
        let summary = Manifest.CellsSummary(
            path: RNASeqCellsDatabase.filename, sha256: try RNASeqResultBundle.sha256Hex(fileAt: url),
            schemaVersion: RNASeqCellsDatabase.currentSchemaVersion)
        return (entries, summary)
    }
}
