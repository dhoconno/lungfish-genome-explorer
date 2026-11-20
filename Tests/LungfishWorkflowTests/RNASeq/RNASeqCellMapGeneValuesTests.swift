// RNASeqCellMapGeneValuesTests.swift - The cell-map writer and its gene pass on the pbmc_1k_v3 cut (Phase 5.5 lane CM-KIND)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Check X2 of `docs/plans/2026-11-19-single-cell-embedding-view.md` on the STARsolo cut of 200 cells
// (`Tests/Fixtures/rnaseq/README.md:8`). Every gene's UMIs add up to `features.total` over `features.cells` cells. LYZ and
// S100A9 equal CM-TRUTH's `mmread` numbers cell by cell, and every normalised value equals CM-TRUTH's float32 value of
// Seurat 5.5.1's `NormalizeData` or lies 1 ulp from it, from the copies in `Tests/Fixtures/rnaseq/cell-map-pbmc_1k_v3/`.
// A cancel inside the gene pass and a refusal for free space each leave no file behind. Set
// LUNGFISH_CM_KIND_X5_RESULT to the X5 single-cell result for the O8 measure, which no gate runs.

import CryptoKit
import Darwin
import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

/// A single-cell parent of the STARsolo cut and a cell map of it, shared by the cell-map tests.
enum CellMapFixture {
    static let truth = RNASeqFixtures.root.appendingPathComponent("cell-map-pbmc_1k_v3", isDirectory: true)
    /// The cells an embedding of the cut leaves out, and the cells with no label in `graphclust`.
    static let leftOut: Set<Int32> = [5, 77, 150]
    static let unlabelled: Set<Int32> = [5, 6, 7]

    static func parent(in root: URL) throws -> URL {
        try RNASeqPseudobulkTests.singleCellResult([RNASeqPseudobulkTests.starsolo], name: "pbmc", in: root)
    }

    static func request(parent: URL, cells: Int = 200) -> RNASeqResultWriter.CellMapRequest {
        let drawn = (1...Int32(cells)).filter { !leftOut.contains($0) }
        let labelled = (1...Int32(cells)).filter { !unlabelled.contains($0) }
        return .init(
            name: "pbmc-tsne", parent: parent, origin: .init(kind: .imported, tool: "Cell Ranger"),
            embeddings: [.init(name: "TSNE", method: "t-SNE", source: .imported, sourceFile: "source/1/projection.csv", otherCounts: true,
                               dimensions: 2, cells: drawn, values: drawn.flatMap { [Double($0) * 0.5, 0.25 - Double($0)] })],
            labelSets: [.init(name: "graphclust", source: .imported, sourceFile: "source/2/clusters.csv", cells: labelled,
                              labels: labelled.map { String($0 % 7 + 1) })],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    static let writer = RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))

    @discardableResult
    static func write(_ request: RNASeqResultWriter.CellMapRequest, to url: URL, writer: RNASeqResultWriter = writer,
                      available: (URL) throws -> Int64 = { _ in Int64.max }, observe: ((RNASeqCellMapGenes.Step) throws -> Void)? = nil
    ) throws -> RNASeqResultWriter.CellMapSummary {
        try writer.writeCellMap(request, to: url, availableBytes: available, observe: observe) { _ in
            ProvenanceEnvelope(workflowName: "RNA-seq cell map", toolName: "lungfish-cli", toolVersion: "test")
        }
    }

    static func cellMap(in root: URL) throws -> (parent: URL, map: URL, summary: RNASeqResultWriter.CellMapSummary) {
        let parent = try parent(in: root)
        let map = root.appendingPathComponent("pbmc-tsne.lungfishrnaseq", isDirectory: true)
        return (parent, map, try write(request(parent: parent), to: map))
    }

    /// The rows of a tab-separated file after its header.
    static func rows(_ name: String) throws -> [[String]] {
        try String(contentsOf: truth.appendingPathComponent(name), encoding: .utf8)
            .split(separator: "\n").dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }
}

final class RNASeqCellMapGeneValuesTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-cell-map") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    func parentFeatures(_ parent: URL) throws -> [RNASeqCellsDatabase.Feature] {
        try RNASeqCellsDatabase(url: parent.appendingPathComponent(RNASeqCellsDatabase.filename)).features()
    }

    func testEveryGeneAddsUpToItsTotalOverItsCells() throws {
        let (parent, map, summary) = try CellMapFixture.cellMap(in: root)
        let database = try RNASeqCellMapDatabase(url: map.appendingPathComponent(RNASeqCellMap.filename))
        let features = try parentFeatures(parent)
        let expression = features.filter { $0.type == "Gene Expression" }
        XCTAssertEqual(expression.count, 1_353)
        XCTAssertEqual(try database.geneValueFeatures(), expression.map(\.feature), "every Gene Expression feature has a row")
        var entries = 0
        for feature in expression {
            let values = try XCTUnwrap(try database.geneValues(feature: feature.feature, unit: .umis))
            guard case .umis(let umis) = values.values else { return XCTFail("feature \(feature.id) read another unit") }
            XCTAssertEqual(umis.reduce(0) { $0 + Int($1) }, feature.total, "the UMIs of \(feature.id)")
            XCTAssertEqual(values.cells.count, feature.cells, "the cells of \(feature.id)")
            XCTAssertEqual(Array(values.cells), values.cells.sorted(), "cells rise")
            entries += values.cells.count
        }
        XCTAssertEqual(entries, 17_692, "the entries of the STARsolo cut (Tests/Fixtures/rnaseq/README.md:27)")
        XCTAssertEqual(summary.genes.entries, 17_692)
        XCTAssertEqual(summary.genes.geneExpressionFeatures, 1_353)
        XCTAssertEqual(summary.genes.blobBytesWithNormalised - summary.genes.blobBytesWithoutNormalised, 4 * 17_692)
    }

    func testLYZAndS100A9EqualTheTruthCellByCell() throws {
        let (parent, map, _) = try CellMapFixture.cellMap(in: root)
        let database = try RNASeqCellMapDatabase(url: map.appendingPathComponent(RNASeqCellMap.filename))
        let featureOfID = Dictionary(try parentFeatures(parent).map { ($0.id, $0.feature) }, uniquingKeysWith: { first, _ in first })
        var truth: [String: [(cell: UInt32, umis: UInt32, bits: UInt32)]] = [:]
        for row in try CellMapFixture.rows("genes-of-interest-starsolo.tsv") {
            truth[row[1], default: []].append((UInt32(row[2])!, UInt32(row[4])!, UInt32(row[6], radix: 16)!))
        }
        XCTAssertEqual(truth["LYZ"]?.count, 76)
        XCTAssertEqual(truth["S100A9"]?.count, 70)
        for (name, id) in [("LYZ", "ENSG00000090382"), ("S100A9", "ENSG00000163220")] {
            let expected = try XCTUnwrap(truth[name]).sorted { $0.cell < $1.cell }
            let feature = try XCTUnwrap(featureOfID[id])
            let umis = try XCTUnwrap(try database.geneValues(feature: feature, unit: .umis))
            let normalised = try XCTUnwrap(try database.geneValues(feature: feature, unit: .normalised))
            XCTAssertEqual(Array(umis.cells), expected.map(\.cell), "\(name) has a value in the same cells")
            XCTAssertEqual(umis.values, .umis(ContiguousArray(expected.map(\.umis))), "\(name) raw UMIs are exact")
            guard case .normalised(let floats) = normalised.values else { return XCTFail("\(name) read another unit") }
            for (value, row) in zip(floats, expected) {
                XCTAssertLessThanOrEqual(Self.ulps(value.bitPattern, row.bits), 1, "\(name) in cell \(row.cell)")
            }
        }
        XCTAssertEqual(truth["LYZ"]?.reduce(0) { $0 + Int($1.umis) }, 7_518, "CM-TRUTH's claim P4: LYZ 76 cells 7518 UMIs")
        XCTAssertEqual(truth["S100A9"]?.reduce(0) { $0 + Int($1.umis) }, 10_172, "CM-TRUTH's claim P4: S100A9 70 cells 10172 UMIs")
    }

    func testEachNormalisedValueEqualsTheTruthOrLiesOneUlpFromIt() throws {
        let (_, map, _) = try CellMapFixture.cellMap(in: root)
        let database = try RNASeqCellMapDatabase(url: map.appendingPathComponent(RNASeqCellMap.filename))
        var byFeature: [Int: [(cell: UInt32, umis: UInt32, bits: UInt32)]] = [:]
        for row in try CellMapFixture.rows("normalised-starsolo.tsv") {
            byFeature[Int(row[0])!, default: []].append((UInt32(row[1])!, UInt32(row[2])!, UInt32(row[3], radix: 16)!))
        }
        var (compared, equal, oneUlp) = (0, 0, 0)
        for feature in try database.geneValueFeatures() {
            let expected = (byFeature[feature] ?? []).sorted { $0.cell < $1.cell }
            let values = try XCTUnwrap(try database.geneValues(feature: feature, unit: .normalised))
            XCTAssertEqual(Array(values.cells), expected.map(\.cell), "feature \(feature)")
            guard case .normalised(let floats) = values.values, floats.count == expected.count else { continue }
            for (value, row) in zip(floats, expected) {
                let distance = Self.ulps(value.bitPattern, row.bits)
                XCTAssertLessThanOrEqual(distance, 1, "feature \(feature), cell \(row.cell), \(row.umis) UMIs")
                compared += 1
                if distance == 0 { equal += 1 } else if distance == 1 { oneUlp += 1 }
            }
        }
        print("CM-KIND normalised values: \(compared) compared, \(equal) equal, \(oneUlp) at 1 ulp")
        XCTAssertEqual(compared, 17_692, "every entry of CM-TRUTH's table")
    }

    func testTheBoundsAreTakenOverEveryCellOfTheMapZerosIncluded() throws {
        let (parent, map, _) = try CellMapFixture.cellMap(in: root)
        let database = try RNASeqCellMapDatabase(url: map.appendingPathComponent(RNASeqCellMap.filename))
        let cellCount = try database.cellCount()
        XCTAssertEqual(cellCount, 200, "the bound set is every cell of the parent, the three left out of TSNE among them")
        for feature in try parentFeatures(parent) where feature.cells > 0 {
            let umis = try XCTUnwrap(try database.geneValues(feature: feature.feature, unit: .umis))
            guard case .umis(let values) = umis.values else { return XCTFail("another unit") }
            let all = (Array(values.map(Double.init)) + Array(repeating: 0, count: cellCount - values.count)).sorted()
            let rank = Int((Double(cellCount) * 0.99).rounded(.up))
            XCTAssertEqual(umis.p99, all[rank - 1], "the nearest-rank p99 of \(feature.id)")
            XCTAssertEqual(umis.minimum, all[0])
            XCTAssertEqual(umis.maximum, all[cellCount - 1])
        }
        let umisBound = try XCTUnwrap(try database.valueBounds().first { $0.value == "umis" })
        let cellUMIs = try RNASeqCellsDatabase(url: parent.appendingPathComponent(RNASeqCellsDatabase.filename)).cells(offset: 0, limit: 200).map(\.umis).sorted()
        XCTAssertEqual(umisBound.maximum, Double(cellUMIs[199]))
        XCTAssertEqual(umisBound.p99, Double(cellUMIs[197]))
    }

    /// BIO's should-fix SF1 on the format page: CM-TRUTH wrote no bound, so each stored minimum, maximum and p99 is
    /// recomputed here from CM-TRUTH's own tables, all N values sorted with the zeros and read at index rank - 1.
    func testTheStoredBoundsEqualThoseRecomputedFromTheTruthTables() throws {
        let (parent, map, _) = try CellMapFixture.cellMap(in: root)
        let database = try RNASeqCellMapDatabase(url: map.appendingPathComponent(RNASeqCellMap.filename))
        let cells = try CellMapFixture.rows("cells-starsolo.tsv")
        let count = cells.count
        let rank = 198
        XCTAssertEqual(count, 200)
        XCTAssertEqual(Int((0.99 * Double(count)).rounded(.up)), rank)
        func expected(_ values: [Double]) -> [Double] {
            let all = (values + Array(repeating: 0, count: count - values.count)).sorted()
            return [all[0], all[count - 1], all[rank - 1]]
        }
        let featureOfID = Dictionary(try parentFeatures(parent).map { ($0.id, $0.feature) }, uniquingKeysWith: { first, _ in first })
        let truth = try CellMapFixture.rows("genes-of-interest-starsolo.tsv")
        for id in ["ENSG00000090382", "ENSG00000163220"] {
            let rows = truth.filter { $0[0] == id }
            let feature = try XCTUnwrap(featureOfID[id])
            let umis = try XCTUnwrap(try database.geneValues(feature: feature, unit: .umis))
            let normalised = try XCTUnwrap(try database.geneValues(feature: feature, unit: .normalised))
            XCTAssertEqual([umis.minimum, umis.maximum, umis.p99], expected(rows.map { Double($0[4])! }), "the UMI bounds of \(id)")
            XCTAssertEqual([normalised.minimum, normalised.maximum, normalised.p99],
                           expected(rows.map { Double(Float(bitPattern: UInt32($0[6], radix: 16)!)) }), "the normalised bounds of \(id)")
        }
        let bounds = Dictionary(try database.valueBounds().map { ($0.value, [$0.minimum, $0.maximum, $0.p99]) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(bounds["umis"], expected(cells.map { Double($0[3])! }), "the bounds of each cell's Gene Expression UMIs")
        XCTAssertEqual(bounds["genes"], expected(cells.map { Double($0[4])! }), "the bounds of each cell's genes")
    }

    /// BIO's blocker B1 on the format page: `features` names every feature, so the gene picker finds LYZ by name in a
    /// result with no reference set, whose `genes.tsv` holds ids only, and finds it with the parent gone.
    func testFeaturesTableNamesEveryFeature() throws {
        let (parent, map, _) = try CellMapFixture.cellMap(in: root)
        XCTAssertNil(try RNASeqResultBundle.loadManifest(from: parent).referenceSet, "the fixture's parent has no reference set")
        func check(_ url: URL) throws {
            let database = try RNASeqCellMapDatabase(url: url.appendingPathComponent(RNASeqCellMap.filename))
            let features = try database.features()
            XCTAssertEqual(features.count, 1_353)
            let lyz = try XCTUnwrap(features.first { $0.name == "LYZ" })
            let s100a9 = try XCTUnwrap(features.first { $0.name == "S100A9" })
            XCTAssertEqual([lyz.feature, s100a9.feature], [846, 77])
            XCTAssertEqual([lyz.type, s100a9.type], ["Gene Expression", "Gene Expression"])
            for feature in [lyz, s100a9] {
                XCTAssertEqual(try database.geneValues(feature: feature.feature, unit: .umis)?.cells.count, feature.cells, feature.name)
            }
        }
        try check(map)
        let copy = root.appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: false)
        let moved = copy.appendingPathComponent(map.lastPathComponent, isDirectory: true)
        try FileManager.default.copyItem(at: map, to: moved)
        try FileManager.default.removeItem(at: parent)
        try check(moved)
        XCTAssertEqual(try RNASeqResultBundle.verifyChecksums(of: moved), [], "the copy opens without its parent")
    }

    func testTheWriterWritesTheCountsTablesAndManifestOfL3() throws {
        let (parent, map, summary) = try CellMapFixture.cellMap(in: root)
        let manifest = try RNASeqResultBundle.loadManifest(from: map)
        let parentManifest = try RNASeqResultBundle.loadManifest(from: parent)
        XCTAssertEqual(manifest.schemaVersion, 2)
        XCTAssertEqual(manifest.modality, .cellMap)
        XCTAssertEqual(manifest.parent?.path, "pbmc.lungfishrnaseq")
        XCTAssertEqual(manifest.parent?.manifestSHA256, try RNASeqResultBundle.sha256Hex(fileAt: RNASeqResultBundle.manifestURL(in: parent)))
        XCTAssertEqual(manifest.parent?.cellsSummarySHA256, parentManifest.cellsSummary?.sha256)
        XCTAssertEqual(manifest.samples.sha256, parentManifest.samples.sha256, "samples.tsv is the parent's bytes")
        XCTAssertEqual(manifest.genes.sha256, parentManifest.genes.sha256, "genes.tsv is the parent's bytes")
        XCTAssertEqual(manifest.route, parentManifest.route)
        XCTAssertEqual(manifest.counts, [])
        XCTAssertNil(manifest.matrices)
        XCTAssertEqual(manifest.labelTables?.map(\.path), ["labels/graphclust.tsv"])
        XCTAssertEqual(try RNASeqResultBundle.verifyChecksums(of: map), [], "every file of the cell map is at its sha256")
        XCTAssertNoThrow(try RNASeqResultBundle.load(from: map))
        XCTAssertTrue(FileManager.default.fileExists(atPath: map.appendingPathComponent(".lungfish-provenance.json").path))

        let database = try RNASeqCellMapDatabase(url: map.appendingPathComponent(RNASeqCellMap.filename))
        XCTAssertEqual(try database.meta()["parent_manifest_sha256"], manifest.parent?.manifestSHA256)
        XCTAssertEqual(try database.embeddingCells().map { [$0.drawn, $0.leftOut] }, [[197, 3]])
        let (x, y) = try database.coordinates(embedding: 1)
        XCTAssertTrue(x[4].isNaN && y[76].isNaN && x[149].isNaN, "cells 5, 77 and 150 are left out")
        XCTAssertEqual(x[0], 0.5)
        XCTAssertEqual(y[199], Float(0.25 - 200))
        let set = try XCTUnwrap(try database.labelSets().first)
        let labelled = (1...200).filter { !CellMapFixture.unlabelled.contains(Int32($0)) }
        let expected = (1...7).map { label in labelled.filter { $0 % 7 + 1 == label }.count }
        XCTAssertEqual(set.labels.map(\.name), ["1", "2", "3", "4", "5", "6", "7"])
        XCTAssertEqual(set.labels.map(\.cells), expected)
        XCTAssertEqual(set.counts.map(\.cells), expected, "one sample, so each label's count of that sample is its total")
        XCTAssertEqual(set.samples.map { [$0.labelled, $0.unlabelled] }, [[197, 3]])
        XCTAssertEqual(summary.labelSets.first?.cells, expected)
        let labels = try database.cellLabels(labelSet: 1)
        XCTAssertEqual(labels[4], 0)
        XCTAssertEqual(labels[7], UInt32(8 % 7 + 1))

        let barcodes = try RNASeqCellsDatabase(url: parent.appendingPathComponent(RNASeqCellsDatabase.filename)).cells(offset: 0, limit: 200).map(\.barcode)
        let table = try String(contentsOf: map.appendingPathComponent("labels/graphclust.tsv"), encoding: .utf8)
        let lines = labelled.map { "starsolo-pbmc_1k_v3\t\(barcodes[$0 - 1])\t\($0 % 7 + 1)" }
        XCTAssertEqual(table, "sample\tbarcode\tlabel\n" + lines.joined(separator: "\n") + "\n")
        XCTAssertEqual(try database.notHostExtras(), [], "the cut has no not-host pass")
        XCTAssertEqual(summary.outputs.map(\.path).last, RNASeqResultManifest.filename)
    }

    func testTheParentPointerClimbsWhenTheMapSitsApart() throws {
        let parent = try CellMapFixture.parent(in: root)
        let maps = root.appendingPathComponent("maps/deeper", isDirectory: true)
        try FileManager.default.createDirectory(at: maps, withIntermediateDirectories: true)
        let map = maps.appendingPathComponent("apart.lungfishrnaseq", isDirectory: true)
        try CellMapFixture.write(CellMapFixture.request(parent: parent), to: map)
        XCTAssertEqual(try RNASeqResultBundle.loadManifest(from: map).parent?.path, "../../pbmc.lungfishrnaseq")
    }

    func testACancelInsideTheGenePassLeavesNoTemporaryFile() throws {
        let parent = try CellMapFixture.parent(in: root)
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let map = root.appendingPathComponent("pbmc-tsne.lungfishrnaseq", isDirectory: true)
        let folder = root!
        var spilled: [String] = []
        XCTAssertThrowsError(try CellMapFixture.write(CellMapFixture.request(parent: parent), to: map, observe: { step in
            guard step == .spilled else { return }
            let stage = try FileManager.default.contentsOfDirectory(atPath: folder.path).first { $0.hasPrefix(".pbmc-tsne.lungfishrnaseq.creating-") }
            let spill = folder.appendingPathComponent(stage ?? "missing").appendingPathComponent(".gene-pass")
            spilled = try FileManager.default.contentsOfDirectory(atPath: spill.path)
            throw CancellationError()
        })) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertFalse(spilled.isEmpty, "the bucket files existed when the cancel came")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before, "no stage, bucket or cell map is left")
    }

    func testAShortOfFreeSpaceIsRefusedInWordsBeforeAnythingIsWritten() throws {
        let parent = try CellMapFixture.parent(in: root)
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let map = root.appendingPathComponent("pbmc-tsne.lungfishrnaseq", isDirectory: true)
        XCTAssertThrowsError(try CellMapFixture.write(CellMapFixture.request(parent: parent), to: map, available: { _ in 1_000 })) { error in
            guard case .notEnoughSpace(let folder, let temporary, let output, let available)? = error as? RNASeqCellMapError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(temporary, 8 * 17_692, "8 bytes an entry of the cut's matrix")
            XCTAssertEqual(available, 1_000)
            XCTAssertEqual(error.localizedDescription,
                "The cell map needs about \(RNASeqCellMapError.bytes(temporary + output)) of free space on the volume of \(folder), "
                + "\(RNASeqCellMapError.bytes(temporary)) for the temporary files of its gene values and \(RNASeqCellMapError.bytes(output)) for the cell map, "
                + "and the volume has 1,000 bytes free. Free some space on that volume, or write the cell map to another one.")
        }
        XCTAssertEqual(RNASeqCellMapError.bytes(8_194_178_000), "8,194,178,000 bytes")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before, "nothing is written")
    }

    // MARK: - The X5 measure (O8), opt in

    static let x5Variable = "LUNGFISH_CM_KIND_X5_RESULT"

    /// Builds a cell map of the X5 result with one embedding over every cell and prints the wall, the growth of this
    /// process's `phys_footprint` (the kernel's lifetime peak after the build less the footprint before it), the
    /// temporary bytes and the size of `gene_values` with and without the float32 value. Run it alone. The bound is a
    /// peak under 1 GiB (`Tests/LungfishRNASeqUITests/SingleCell/RNASeqSingleCellScaleEvidenceTests.swift:9`).
    func testTheX5CellMapBuildsUnderOneGiB() throws {
        guard let path = ProcessInfo.processInfo.environment[Self.x5Variable], !path.isEmpty else { return }
        let parent = URL(fileURLWithPath: path, isDirectory: true)
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LUNGFISH_CM_KIND_X5_OUT"] ?? root.path, isDirectory: true)
        let cells = try RNASeqCellsDatabase(url: parent.appendingPathComponent(RNASeqCellsDatabase.filename)).cellCount()
        let all = (1...Int32(cells)).map { $0 }
        let request = RNASeqResultWriter.CellMapRequest(
            name: "x5-map", parent: parent, origin: .init(kind: .imported),
            embeddings: [.init(name: "grid", method: nil, source: .imported, sourceFile: "", otherCounts: false, dimensions: 2,
                               cells: all, values: all.flatMap { [Double($0 % 1_000), Double($0 / 1_000)] })],
            labelSets: [])
        let map = out.appendingPathComponent("x5-map-\(UUID().uuidString).lungfishrnaseq", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: map) }
        let before = Self.footprint()
        let clock = ContinuousClock()
        let began = clock.now
        let summary = try CellMapFixture.write(request, to: map)
        let wall = clock.now - began
        let after = Self.footprint()
        let growth = after.peak - before.now
        print("CM-KIND X5: cells \(summary.genes.cells), entries \(summary.genes.entries), buckets \(summary.genes.buckets), wall \(wall)")
        print("CM-KIND X5: footprint before \(before.now) B, peak after \(after.peak) B, growth \(growth) B")
        print("CM-KIND X5: temporary \(summary.genes.temporaryBytes) B, gene_values blobs with float32 \(summary.genes.blobBytesWithNormalised) B, without \(summary.genes.blobBytesWithoutNormalised) B, cellmap.sqlite \(summary.cellMapBytes) B")
        XCTAssertLessThan(growth, 1 << 30, "the build's peak stays under 1 GiB")
    }

    static func footprint() -> (now: Int64, peak: Int64) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? (Int64(info.phys_footprint), info.ledger_phys_footprint_peak) : (0, 0)
    }

    /// The distance in float32 steps between two finite values of one sign.
    static func ulps(_ a: UInt32, _ b: UInt32) -> UInt32 { a > b ? a - b : b - a }
}
