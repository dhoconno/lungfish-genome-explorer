// RNASeqCellMapViewFixtures.swift - Cell maps for the embedding view's tests, written by CM-KIND's writer (Phase 5.5 lane CM-VIEW)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The model tests use a cell map of the STARsolo cut of 200 cells (`Tests/Fixtures/rnaseq/starsolo-pbmc_1k_v3`), with a
// UMAP that leaves 3 cells out, a PCA of every cell and a set of 21 numeric labels, so the palette repeats. The smoke
// fixture is a cell map of 12 cells and its single-cell parent, committed under `Tests/Fixtures/rnaseq/cell-map-smoke`
// and staged for the packaged smoke through `SMOKE_FIXTURES`. `RNASeqCellMapViewFixtureTests` reads it back, and with
// LUNGFISH_CM_VIEW_WRITE_SMOKE_FIXTURE set to a folder it writes it again there.

import Foundation
import LungfishIO
import LungfishTestSupport
@testable import LungfishCore
@testable import LungfishWorkflow

enum RNASeqCellMapViewFixtures {
    static let starsolo = RNASeqFixtures.root.appendingPathComponent("starsolo-pbmc_1k_v3", isDirectory: true)
    static let smoke = RNASeqFixtures.root.appendingPathComponent("cell-map-smoke", isDirectory: true)
    static let writer = RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))

    /// The cells the UMAP leaves out and the cells with no label, from 1.
    static let leftOut: Set<Int32> = [5, 77, 150]
    static let unlabelled: Set<Int32> = [5, 6, 7]

    /// The UMAP's coordinates of a cell, from 1, distinct for every cell.
    static func umap(_ cell: Int32) -> (x: Double, y: Double) { (Double(cell) * 0.5, 0.25 - Double(cell % 17) * 3) }
    /// The label of a labelled cell, 21 numeric labels.
    static func label(_ cell: Int32) -> String { String(cell % 21 + 1) }

    static func parent(_ folder: URL, name: String, in root: URL) throws -> URL {
        let read = try SingleCellFolderReader.read(folder: folder)
        let samples = [RNASeqSampleRecord(id: read.sample, animal: "A1", species: "Homo sapiens", origin: "blood", runs: [read.sample])]
        let request = try SingleCellFolderReader.request([read], name: name, samples: samples, genomes: [])
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test")
        return try writer.write(request, to: root.appendingPathComponent("\(name).lungfishrnaseq", isDirectory: true), envelope: envelope)
    }

    static func write(_ request: RNASeqResultWriter.CellMapRequest, to url: URL) throws {
        _ = try writer.writeCellMap(request, to: url, availableBytes: { _ in Int64.max }, observe: nil) { _ in
            ProvenanceEnvelope(workflowName: "RNA-seq cell map", toolName: "lungfish-cli", toolVersion: "test")
        }
    }

    /// A cell map of the 200-cell cut, and its parent.
    static func cellMap(in root: URL) throws -> (parent: URL, map: URL) {
        let parent = try parent(starsolo, name: "pbmc", in: root)
        let all = Array(1...Int32(200))
        let drawn = all.filter { !leftOut.contains($0) }
        let labelled = all.filter { !unlabelled.contains($0) }
        let request = RNASeqResultWriter.CellMapRequest(
            name: "pbmc-map", parent: parent, origin: .init(kind: .imported, tool: "Cell Ranger"),
            embeddings: [
                .init(name: "UMAP", method: "UMAP", source: .imported, sourceFile: "source/1/projection.csv", otherCounts: true,
                      dimensions: 2, cells: drawn, values: drawn.flatMap { [umap($0).x, umap($0).y] }),
                .init(name: "PCA", method: "PCA", source: .imported, sourceFile: "source/2/projection.csv", otherCounts: false,
                      dimensions: 2, cells: all, values: all.flatMap { [Double($0), Double(-$0)] }),
            ],
            labelSets: [.init(name: "graphclust", source: .imported, sourceFile: "source/3/clusters.csv", cells: labelled,
                              labels: labelled.map(label))],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let map = root.appendingPathComponent("pbmc-map.lungfishrnaseq", isDirectory: true)
        try write(request, to: map)
        return (parent, map)
    }

    // MARK: - The smoke fixture

    static let smokeParentName = "Smoke single-cell"
    static let smokeMapName = "Smoke cell map"
    static let smokeCells: Int32 = 12
    static let smokeLeftOut: Set<Int32> = [4]
    static let smokeUnlabelled: Set<Int32> = [4, 9]
    static func smokePoint(_ cell: Int32) -> (x: Double, y: Double) { (Double(cell % 4) * 1.5, Double(cell / 4) * 1.25) }
    static func smokeLabel(_ cell: Int32) -> String { String(cell % 3 + 1) }

    /// A STARsolo folder of 12 cells and 6 genes, cut from the fixture's first barcodes and features, with its run files.
    static func smokeStarsolo(in root: URL) throws -> URL {
        let folder = root.appendingPathComponent("smoke-starsolo", isDirectory: true)
        let filtered = folder.appendingPathComponent("Solo.out/Gene/filtered", isDirectory: true)
        try FileManager.default.createDirectory(at: filtered, withIntermediateDirectories: true)
        for file in ["Log.final.out", "Solo.out/Barcodes.stats", "Solo.out/Gene/Summary.csv", "Solo.out/Gene/Features.stats"] {
            try FileManager.default.copyItem(at: starsolo.appendingPathComponent(file), to: folder.appendingPathComponent(file))
        }
        let source = starsolo.appendingPathComponent("Solo.out/Gene/filtered", isDirectory: true)
        func lines(_ name: String, _ count: Int) throws -> String {
            try String(contentsOf: source.appendingPathComponent(name), encoding: .utf8).split(separator: "\n").prefix(count).map { $0 + "\n" }.joined()
        }
        try lines("features.tsv", 6).write(to: filtered.appendingPathComponent("features.tsv"), atomically: true, encoding: .utf8)
        try lines("barcodes.tsv", Int(smokeCells)).write(to: filtered.appendingPathComponent("barcodes.tsv"), atomically: true, encoding: .utf8)
        var entries: [String] = []
        for cell in 1...Int(smokeCells) {
            for gene in 1...6 where (cell + gene) % 3 != 0 { entries.append("\(gene) \(cell) \((cell * gene) % 7 + 1)") }
        }
        let matrix = "%%MatrixMarket matrix coordinate integer general\n%\n6 \(smokeCells) \(entries.count)\n" + entries.joined(separator: "\n") + "\n"
        try matrix.write(to: filtered.appendingPathComponent("matrix.mtx"), atomically: true, encoding: .utf8)
        return folder
    }

    /// Writes the smoke parent and its cell map into `folder`, as the committed copy holds them.
    static func writeSmoke(into folder: URL, scratch: URL) throws {
        let cut = try smokeStarsolo(in: scratch)
        let parent = try parent(cut, name: smokeParentName, in: folder)
        let barcodes = try String(contentsOf: cut.appendingPathComponent("Solo.out/Gene/filtered/barcodes.tsv"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let all = Array(1...smokeCells)
        let drawn = all.filter { !smokeLeftOut.contains($0) }
        let labelled = all.filter { !smokeUnlabelled.contains($0) }
        var table = "barcode\tUMAP_1\tUMAP_2\tclusters\n"
        for cell in drawn {
            let point = smokePoint(cell)
            table += "\(barcodes[Int(cell) - 1])\t\(point.x)\t\(point.y)\t\(smokeUnlabelled.contains(cell) ? "" : smokeLabel(cell))\n"
        }
        let given = scratch.appendingPathComponent("lge-cell-map.tsv")
        try table.write(to: given, atomically: true, encoding: .utf8)
        let request = RNASeqResultWriter.CellMapRequest(
            name: smokeMapName, parent: parent, origin: .init(kind: .imported, tool: "Seurat", toolVersion: "5.5.1"),
            givenFiles: [.init(url: given, sample: "", tool: "Seurat")],
            embeddings: [.init(name: "UMAP", method: "UMAP", source: .imported, sourceFile: "source/1/lge-cell-map.tsv", otherCounts: false,
                               dimensions: 2, cells: drawn, values: drawn.flatMap { [smokePoint($0).x, smokePoint($0).y] })],
            labelSets: [.init(name: "clusters", source: .imported, sourceFile: "source/1/lge-cell-map.tsv", cells: labelled,
                              labels: labelled.map(smokeLabel))],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        try write(request, to: folder.appendingPathComponent("\(smokeMapName).lungfishrnaseq", isDirectory: true))
    }
}
