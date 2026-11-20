// RNASeqCellMapDatabaseTests.swift - The manifest schemas and cellmap.sqlite of a cell map (Phase 5.5 lane CM-KIND)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The schema rules of `docs/formats/rnaseq-cell-map.md`, Schemas 1 and 2, the codings and bounds of `gene_values`, and a
// round trip of `cellmap.sqlite` through its writer and its `Sendable` reader, on rows small enough to count by hand.

import Foundation
import SQLite3
import XCTest
import LungfishTestSupport
@testable import LungfishIO

final class RNASeqCellMapDatabaseTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-cell-map-db") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    /// A result folder whose manifest is `json` with `samples.tsv` and `genes.tsv` beside it.
    func bundle(_ json: String, name: String = "map") throws -> URL {
        let url = root.appendingPathComponent("\(name).lungfishrnaseq", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url.appendingPathComponent(RNASeqResultManifest.filename))
        try Data("sample_id\tanimal\tspecies\torigin\truns\nS1\tA1\tHomo sapiens\tblood\tS1\n".utf8).write(to: url.appendingPathComponent("samples.tsv"))
        try Data("gene_id\nG1\n".utf8).write(to: url.appendingPathComponent("genes.tsv"))
        return url
    }

    func manifestJSON(schema: Int, modality: String, origin: String = "imported", extra: String = "") -> String {
        """
        {"schemaVersion": \(schema), "kind": "rnaseq-result", "modality": "\(modality)", "name": "map", "createdAt": "2026-11-20T10:00:00Z",
         "origin": {"kind": "\(origin)"}, "route": {"id": "r", "tool": "STARsolo", "toolVersion": "2.7.11b", "settings": {}},
         "referenceSet": null, "samples": {"path": "samples.tsv", "sha256": "s"}, "genes": {"path": "genes.tsv", "sha256": "g"},
         "counts": [], "sourceFiles": [], "notHost": []\(extra)}
        """
    }

    static let cellMapKeys = """
        , "parent": {"path": "cells.lungfishrnaseq", "manifestSHA256": "m", "cellsSummarySHA256": "c"},
         "cellMap": {"path": "cellmap.sqlite", "sha256": "d", "schemaVersion": 1},
         "labelTables": [{"path": "labels/graphclust.tsv", "sha256": "l"}]
        """

    func listing(_ url: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
    }

    // MARK: - Schemas 1 and 2

    func testEachModalityWritesItsOwnSchemaAndTheReaderReadsUpToTwo() {
        XCTAssertEqual(RNASeqResultManifest.newestReadableSchemaVersion, 2)
        XCTAssertEqual(RNASeqResultManifest.schemaVersion(for: .bulk), 1)
        XCTAssertEqual(RNASeqResultManifest.schemaVersion(for: .singleCell), 1)
        XCTAssertEqual(RNASeqResultManifest.schemaVersion(for: .cellMap), 2)
        let route = RNASeqResultManifest.Route(id: "r", tool: "t", toolVersion: "1", settings: [:])
        let entry = RNASeqResultManifest.FileEntry(path: "samples.tsv", sha256: "s")
        let bulk = RNASeqResultManifest(modality: .bulk, name: "b", createdAt: "", origin: .init(kind: .pseudobulk), route: route,
                                        referenceSet: nil, samples: entry, genes: entry, counts: [], sourceFiles: [])
        XCTAssertEqual(bulk.schemaVersion, 1, "a pseudobulk result is bulk and stays at schema 1")
    }

    func testAManifestOneSchemaAboveTheNewestIsRefusedInTheShippedWordsAndNothingIsWritten() throws {
        let url = try bundle(manifestJSON(schema: RNASeqResultManifest.newestReadableSchemaVersion + 1, modality: "cell-map") + "")
        let before = try listing(url)
        let words = "This RNA-seq result was written by a newer LGE (schema 3). Open it with that version or a later one."
        XCTAssertThrowsError(try RNASeqResultBundle.loadManifest(from: url)) { XCTAssertEqual($0.localizedDescription, words) }
        XCTAssertThrowsError(try RNASeqResultBundle.load(from: url)) { XCTAssertEqual($0.localizedDescription, words) }
        XCTAssertEqual(try listing(url), before, "a read writes nothing")
    }

    func testACellMapManifestReadsAtSchemaTwoAndWritesItsKeysBack() throws {
        let url = try bundle(manifestJSON(schema: 2, modality: "cell-map", origin: "computed", extra: Self.cellMapKeys))
        let manifest = try RNASeqResultBundle.loadManifest(from: url)
        XCTAssertEqual(manifest.modality, .cellMap)
        XCTAssertEqual(manifest.origin.kind, .computed)
        XCTAssertEqual(manifest.parent, .init(path: "cells.lungfishrnaseq", manifestSHA256: "m", cellsSummarySHA256: "c"))
        XCTAssertEqual(manifest.cellMap, .init(path: "cellmap.sqlite", sha256: "d", schemaVersion: 1))
        XCTAssertEqual(manifest.labelTables, [.init(path: "labels/graphclust.tsv", sha256: "l")])
        let encoded = try JSONEncoder().encode(manifest)
        XCTAssertEqual(try JSONDecoder().decode(RNASeqResultManifest.self, from: encoded), manifest)
        let paths = try RNASeqResultBundle.verifyChecksums(of: url).map(\.path)
        XCTAssertTrue(paths.contains("cellmap.sqlite") && paths.contains("labels/graphclust.tsv"), "\(paths)")
    }

    func testTheValuesOfOneSchemaUnderTheOtherReadAsNoReadableManifest() throws {
        let words = "The RNA-seq result has no readable manifest."
        let cases = [
            ("a schema 1 cell map", manifestJSON(schema: 1, modality: "cell-map", extra: Self.cellMapKeys)),
            ("a schema 1 computed origin", manifestJSON(schema: 1, modality: "bulk", origin: "computed")),
            ("a schema 1 bulk result with a parent", manifestJSON(schema: 1, modality: "bulk", extra: Self.cellMapKeys)),
            ("a schema 2 bulk result", manifestJSON(schema: 2, modality: "bulk")),
            ("a schema 2 cell map with no parent", manifestJSON(schema: 2, modality: "cell-map")),
            ("schema 0", manifestJSON(schema: 0, modality: "bulk")),
        ]
        for (index, (what, json)) in cases.enumerated() {
            let url = try bundle(json, name: "case\(index)")
            XCTAssertThrowsError(try RNASeqResultBundle.loadManifest(from: url), what) { XCTAssertEqual($0.localizedDescription, words, what) }
        }
        XCTAssertNoThrow(try RNASeqResultBundle.loadManifest(from: try bundle(manifestJSON(schema: 1, modality: "bulk"), name: "plain")))
    }

    // MARK: - Codings and bounds

    func testLEB128AndTheDeltaCellIDsRoundTrip() throws {
        var bytes: [UInt8] = []
        for value: UInt64 in [0, 1, 127, 128, 300, 16_384, UInt64.max] { RNASeqCellMap.appendLEB128(value, to: &bytes) }
        XCTAssertEqual(Array(bytes.prefix(7)), [0x00, 0x01, 0x7F, 0x80, 0x01, 0xAC, 0x02])
        XCTAssertEqual(try RNASeqCellMap.decodeLEB128(bytes), [0, 1, 127, 128, 300, 16_384, UInt64.max])
        XCTAssertThrowsError(try RNASeqCellMap.decodeLEB128([0x80]), "a value cut short")
        let cells: [UInt32] = [1, 2, 130, 131, 70_000]
        let encoded = RNASeqCellMap.encodeCellIDs(cells)
        XCTAssertEqual(Array(encoded.prefix(3)), [0x01, 0x01, 0x80])
        XCTAssertEqual(Array(try RNASeqCellMap.decodeCellIDs(encoded)), cells)
        let floats: [Float] = [0, 1, 2.0915222, -0.5]
        let floatBytes = RNASeqCellMap.encodeFloats(floats)
        XCTAssertEqual(Array(floatBytes.prefix(8)), [0, 0, 0, 0, 0x00, 0x00, 0x80, 0x3F], "little-endian binary32")
        XCTAssertEqual(Array(try RNASeqCellMap.decodeFloats(floatBytes)).map(\.bitPattern), floats.map(\.bitPattern))
        XCTAssertThrowsError(try RNASeqCellMap.decodeFloats([0, 0, 0]))
    }

    func testTheNormalisedValueDividesThenMultipliesThenTakesLog1p() {
        // CM-TRUTH's first row of the STARsolo cut: 1 UMI in a cell of 1,409 Gene Expression UMIs, float32 bits 4005db80.
        XCTAssertEqual(RNASeqCellMap.normalised(umis: 1, cellUMIs: 1_409).bitPattern, 0x4005_db80)
        XCTAssertEqual(RNASeqCellMap.normalised(umis: 83, cellUMIs: 1_409).bitPattern, Float(log1p((83.0 / 1_409.0) * 10_000)).bitPattern)
    }

    func testTheP99IsTheNearestRankOverEveryCellZerosIncluded() {
        XCTAssertEqual([1, 100, 101, 200, 1_224].map(RNASeqCellMap.p99Rank), [1, 99, 100, 198, 1_212])
        // 200 cells, 2 with a count: rank 198 falls among the zeros.
        let sparse = RNASeqCellMap.bounds(nonZero: [UInt64(7), 3], cells: 200)
        XCTAssertEqual(sparse.minimum, 0)
        XCTAssertEqual(sparse.maximum, 7)
        XCTAssertEqual(sparse.p99, 0)
        // 200 cells, 5 with a count: rank 198 is the 3rd smallest of the 5.
        let five = RNASeqCellMap.bounds(nonZero: [UInt64(9), 1, 4, 2, 8], cells: 200)
        XCTAssertEqual(five.p99, 4)
        // Every cell counted: the minimum is the least value.
        let full = RNASeqCellMap.bounds(nonZero: [Float(0.5), 2, 1], cells: 3)
        XCTAssertEqual(full.minimum, 0.5)
        XCTAssertEqual(full.p99, 2)
        let none = RNASeqCellMap.bounds(nonZero: [UInt64](), cells: 200)
        XCTAssertEqual(none.maximum, 0)
    }

    func testLabelOrderAndLabelTableNamesAndBytes() {
        XCTAssertEqual(RNASeqCellMap.labelOrder(["10", "9", "1", "01", "2", "1"]), ["01", "1", "2", "9", "10"])
        XCTAssertEqual(RNASeqCellMap.labelOrder(["b", "B", "a10", "a9", "10"]), ["10", "B", "a10", "a9", "b"])
        XCTAssertEqual(RNASeqCellMap.labelTableFileName("graphclust"), "graphclust.tsv")
        XCTAssertEqual(RNASeqCellMap.labelTableFileName("gene expression/k.means-7"), "gene_expression_k.means-7.tsv")
        XCTAssertEqual(RNASeqCellMap.labelTableFileName(".hidden"), "_hidden.tsv")
        XCTAssertEqual(RNASeqCellMap.labelTableFileName("Zellé"), "Zell_.tsv")
        let data = RNASeqCellMap.labelTableData([("S1", "AAAC-1", "1"), ("S2", "TTTG", "rest")])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "sample\tbarcode\tlabel\nS1\tAAAC-1\t1\nS2\tTTTG\trest\n")
    }

    // MARK: - cellmap.sqlite

    /// Five cells over two samples, one embedding that leaves out cell 3, one label set and two genes.
    func writeDatabase() throws -> URL {
        let url = root.appendingPathComponent(RNASeqCellMap.filename)
        let writer = try RNASeqCellMapDatabaseWriter(url: url)
        try writer.setMeta("parent_manifest_sha256", "m")
        try writer.addSamples([(1, "S1", 3), (2, "S2", 2)])
        try writer.addCells(firstCell: 1, samples: [1, 1, 1, 2, 2], barcodes: ["A", "B", "C", "D", "E"], umis: [10, 20, 30, 40, 50], genes: [1, 2, 3, 4, 5])
        try writer.addEmbedding(1, name: "TSNE", dimensions: 2, method: "t-SNE", source: "imported", sourceFile: "source/1/projection.csv", otherCounts: true, cells: 4)
        try writer.addEmbeddingCells(1, sample: 1, drawn: 2, leftOut: 1)
        try writer.addEmbeddingCells(1, sample: 2, drawn: 2, leftOut: 0)
        let drawn: [Int32] = [1, 2, 4, 5]
        try writer.addCoordinates(1, dimension: 1, cells: drawn) { [16.594893339647868, -1, 2, 3][$0] }
        try writer.addCoordinates(1, dimension: 2, cells: drawn) { [0.1, 0.2, 0.3, 0.4][$0] }
        try writer.addLabelSet(1, name: "graphclust", source: "imported", sourceFile: "source/2/clusters.csv", labels: [("1", 2), ("2", 1)], table: "labels/graphclust.tsv")
        try writer.addLabelCount(1, label: 1, sample: 1, cells: 1)
        try writer.addLabelCount(1, label: 1, sample: 2, cells: 1)
        try writer.addLabelCount(1, label: 2, sample: 2, cells: 1)
        try writer.addLabelSetSample(1, sample: 1, labelled: 1, unlabelled: 2)
        try writer.addLabelSetSample(1, sample: 2, labelled: 2, unlabelled: 0)
        try writer.addCellLabels(1, cells: [1, 4, 5], labels: [1, 1, 2])
        let normalised: [Float] = [RNASeqCellMap.normalised(umis: 3, cellUMIs: 10), RNASeqCellMap.normalised(umis: 200, cellUMIs: 50)]
        try writer.addGeneValues(.init(feature: 1, cells: 2, cellIDs: RNASeqCellMap.encodeCellIDs([UInt32(1), 5]),
                                       umis: { var bytes: [UInt8] = []; RNASeqCellMap.appendLEB128(3, to: &bytes); RNASeqCellMap.appendLEB128(200, to: &bytes); return bytes }(),
                                       normalised: RNASeqCellMap.encodeFloats(normalised), umisBounds: (0, 200, 200), normalisedBounds: (0, normalised[1], normalised[1])))
        try writer.addGeneValues(.init(feature: 3, cells: 0, cellIDs: [], umis: [], normalised: [], umisBounds: (0, 0, 0), normalisedBounds: (0, 0, 0)))
        try writer.addValueBounds("umis", extra: 0, minimum: 10, maximum: 50, p99: 50)
        try writer.finish()
        return url
    }

    func testTheDatabaseReadsBackThroughOneHandleACall() throws {
        let database = try RNASeqCellMapDatabase(url: try writeDatabase())
        XCTAssertEqual(database.schemaVersion, 1)
        XCTAssertEqual(try database.meta()["normalisation"], "log1p(10000 * UMIs / cell Gene Expression UMIs)")
        XCTAssertEqual(try database.cellCount(), 5)
        XCTAssertEqual(try database.cell(id: 4), .init(cell: 4, sample: 2, barcode: "D", umis: 40, genes: 4))
        XCTAssertNil(try database.cell(id: 9))
        XCTAssertEqual(try database.embeddings().map(\.method), ["t-SNE"])
        XCTAssertEqual(try database.embeddingCells().map(\.leftOut), [1, 0])

        let (x, y) = try database.coordinates(embedding: 1)
        XCTAssertEqual(x.count, 5)
        XCTAssertEqual(x[0], Float(16.594893339647868))
        XCTAssertTrue(x[2].isNaN && y[2].isNaN, "cell 3 is left out")
        XCTAssertEqual(Array(y[3...]), [Float(0.3), Float(0.4)])

        let set = try XCTUnwrap(try database.labelSets().first)
        XCTAssertEqual(set.labels.map(\.cells), [2, 1])
        XCTAssertEqual(set.counts.map(\.cells), [1, 1, 1])
        XCTAssertEqual(set.samples.map(\.unlabelled), [2, 0])
        XCTAssertEqual(Array(try database.cellLabels(labelSet: 1)), [1, 0, 0, 1, 2])

        let umis = try XCTUnwrap(try database.geneValues(feature: 1, unit: .umis))
        XCTAssertEqual(Array(umis.cells), [1, 5])
        XCTAssertEqual(umis.values, .umis([3, 200]))
        XCTAssertEqual([umis.minimum, umis.maximum, umis.p99], [0, 200, 200])
        let normalised = try XCTUnwrap(try database.geneValues(feature: 1, unit: .normalised))
        XCTAssertEqual(normalised.values, .normalised([RNASeqCellMap.normalised(umis: 3, cellUMIs: 10), RNASeqCellMap.normalised(umis: 200, cellUMIs: 50)]))
        XCTAssertEqual(normalised.maximum, Double(RNASeqCellMap.normalised(umis: 200, cellUMIs: 50)))
        let empty = try XCTUnwrap(try database.geneValues(feature: 3, unit: .umis))
        XCTAssertTrue(empty.cells.isEmpty, "a gene no cell counts has a row with empty blobs")
        XCTAssertNil(try database.geneValues(feature: 2, unit: .umis), "a feature with no row reads nil")
        XCTAssertEqual(try database.geneValueFeatures(), [1, 3])
        XCTAssertEqual(try database.valueBounds().first?.p99, 50)
    }

    func testANewerDatabaseSchemaIsRefusedInTheNewerWords() throws {
        let url = try writeDatabase()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "UPDATE meta SET value = '2' WHERE key = 'schema_version'", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        XCTAssertThrowsError(try RNASeqCellMapDatabase(url: url)) {
            XCTAssertEqual($0.localizedDescription, "This RNA-seq result was written by a newer LGE (schema 2). Open it with that version or a later one.")
        }
    }

    func testACancelledReadStopsInsideItsStepLoop() async throws {
        let database = try RNASeqCellMapDatabase(url: try writeDatabase())
        let task = Task { () throws -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return try database.coordinates(embedding: 1).x.count
        }
        let outcome = await task.result
        XCTAssertThrowsError(try outcome.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
    }

    /// Four cells of one sample with the UMIs and genes of the totals tests, one of them 0 in both.
    func writeTotalsDatabase() throws -> URL {
        let url = root.appendingPathComponent("totals-\(RNASeqCellMap.filename)")
        let writer = try RNASeqCellMapDatabaseWriter(url: url)
        try writer.setMeta("parent_manifest_sha256", "m")
        try writer.addSamples([(1, "S1", 4)])
        try writer.addCells(firstCell: 1, samples: [1, 1, 1, 1], barcodes: ["A", "B", "C", "D"], umis: [5, 0, 9, 12], genes: [3, 0, 4, 6])
        try writer.finish()
        return url
    }

    func testCellTotalsReadTheUMIsAndGenesOfEveryCellInOneOrderedRead() throws {
        let database = try RNASeqCellMapDatabase(url: try writeTotalsDatabase())
        let totals = try database.cellTotals()
        XCTAssertEqual(Array(totals.umis), [5, 0, 9, 12])
        XCTAssertEqual(Array(totals.genes), [3, 0, 4, 6])
        for cell in 1...4 {
            let one = try XCTUnwrap(try database.cell(id: cell))
            XCTAssertEqual(Int(totals.umis[cell - 1]), one.umis, "the UMIs of cell \(cell) by both reads")
            XCTAssertEqual(Int(totals.genes[cell - 1]), one.genes, "the genes of cell \(cell) by both reads")
        }
    }

    func testCellTotalsStopAtACancel() async throws {
        let database = try RNASeqCellMapDatabase(url: try writeTotalsDatabase())
        let task = Task { () throws -> Int in
            while !Task.isCancelled { await Task.yield() }
            return try database.cellTotals().umis.count
        }
        task.cancel()
        let outcome = await task.result
        XCTAssertThrowsError(try outcome.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
    }
}
