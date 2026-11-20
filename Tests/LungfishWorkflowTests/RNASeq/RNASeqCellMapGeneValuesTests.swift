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

    // MARK: - A real task cancel and a parent of two samples (fix round 1, item 2)

    /// SWIFT SF2. The observer cancels its own task at the end of the spill and does not throw, so the stop comes from the
    /// writer's `Task.checkCancellation()` after the observer and not from a thrown `CancellationError`.
    func testATaskCancelAtTheEndOfTheSpillStopsTheBuildAndLeavesNothing() async throws {
        let parent = try CellMapFixture.parent(in: root)
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        let map = root.appendingPathComponent("pbmc-tsne.lungfishrnaseq", isDirectory: true)
        let outcome = await Task { () -> (error: (any Error)?, steps: [RNASeqCellMapGenes.Step]) in
            var steps: [RNASeqCellMapGenes.Step] = []
            do {
                try CellMapFixture.write(CellMapFixture.request(parent: parent), to: map, observe: { step in
                    steps.append(step)
                    if step == .spilled { withUnsafeCurrentTask { $0?.cancel() } }
                })
                return (nil, steps)
            } catch {
                return (error, steps)
            }
        }.value
        XCTAssertTrue(outcome.error is CancellationError, "\(String(describing: outcome.error))")
        XCTAssertTrue(outcome.steps.contains(.spilled), "the cancel came at the end of the spill")
        XCTAssertFalse(outcome.steps.contains(where: { if case .placed = $0 { true } else { false } }), "no bucket was placed after the cancel")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before, "no stage, bucket or cell map is left")
    }

    /// Cells 1 to 200 are the first sample's and 201 to 400 the second's. The embedding leaves out cell 5 of the first and
    /// cell 250 of the second, and the label set gives no label to cell 6 of the first and cell 251 of the second.
    static let twoSampleLeftOut: Set<Int32> = [5, 250]
    static let twoSampleUnlabelled: Set<Int32> = [6, 251]
    static let twoSampleNames = ["T cell", "B cell", "NK"]

    /// A parent of two samples, each the STARsolo cut, and a cell map of it with one embedding and one label set.
    func twoSampleCellMap() throws -> (parent: URL, map: URL, request: RNASeqResultWriter.CellMapRequest, summary: RNASeqResultWriter.CellMapSummary) {
        let parent = try RNASeqPseudobulkTests.singleCellResult(
            [RNASeqPseudobulkTests.starsolo, try RNASeqPseudobulkTests.starsoloCopy("second", in: root)], name: "two", in: root)
        let all = (1...400).map { Int32($0) }
        let drawn = all.filter { !Self.twoSampleLeftOut.contains($0) }
        let labelled = all.filter { !Self.twoSampleUnlabelled.contains($0) }
        let request = RNASeqResultWriter.CellMapRequest(
            name: "two-map", parent: parent, origin: .init(kind: .imported, tool: "Cell Ranger"),
            embeddings: [.init(name: "TSNE", method: "t-SNE", source: .imported, sourceFile: "source/1/projection.csv", otherCounts: true,
                               dimensions: 2, cells: drawn, values: drawn.flatMap { [Double($0) * 0.5, 0.25 - Double($0)] })],
            labelSets: [.init(name: "cluster", source: .imported, sourceFile: "source/2/clusters.csv", cells: labelled,
                              labels: labelled.map { Self.twoSampleNames[Int($0) % 3] })],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let map = root.appendingPathComponent("two-map.lungfishrnaseq", isDirectory: true)
        return (parent, map, request, try CellMapFixture.write(request, to: map))
    }

    /// SWIFT SF1. Every other fixture has one sample, so a mixed-up sample or label number would pass there. The counts
    /// below are recounted from the request, the sample names and barcodes come from the parent, and the label order differs
    /// from the request's, so the stored label number is not the name's place in the request.
    func testAParentOfTwoSamplesKeepsEachSamplesCountsAndGlobalCellIDs() throws {
        let (parent, map, request, summary) = try twoSampleCellMap()
        let database = try RNASeqCellMapDatabase(url: map.appendingPathComponent(RNASeqCellMap.filename))
        let parentCells = try RNASeqCellsDatabase(url: parent.appendingPathComponent(RNASeqCellsDatabase.filename))
        let samples = try parentCells.samples()
        XCTAssertEqual(samples.map(\.cells), [200, 200])
        XCTAssertEqual(try database.samples().map { [$0.sample, $0.cells] }, samples.map { [$0.sample, $0.cells] })
        let ids = samples.map(\.sample)
        let names = Dictionary(uniqueKeysWithValues: samples.map { ($0.sample, $0.name) })

        // The embedding leaves out one cell of each sample.
        XCTAssertEqual(try database.embeddingCells().map { [$0.sample, $0.drawn, $0.leftOut] }, ids.map { [$0, 199, 1] })
        XCTAssertEqual(summary.embeddings.first?.drawn, [199, 199])
        XCTAssertEqual(summary.embeddings.first?.leftOut, [1, 1])

        let set = try XCTUnwrap(try database.labelSets().first)
        XCTAssertEqual(set.labels.map(\.name), ["B cell", "NK", "T cell"], "label order is by code point and not the request's order")
        let given = Dictionary(uniqueKeysWithValues: zip(request.labelSets[0].cells, request.labelSets[0].labels))
        func sample(of cell: Int32) -> Int { ids[cell <= 200 ? 0 : 1] }
        for label in set.labels {
            let recount = ids.map { id in given.filter { $0.value == label.name && sample(of: $0.key) == id }.count }
            let stored = set.counts.filter { $0.label == label.label }
            XCTAssertEqual(stored.map(\.sample), ids, "\(label.name) has a count for each sample")
            XCTAssertEqual(stored.map(\.cells), recount, "\(label.name) for each sample")
            XCTAssertEqual(label.cells, recount.reduce(0, +), "\(label.name) in all")
        }
        XCTAssertEqual(set.samples.map { [$0.sample, $0.labelled, $0.unlabelled] }, ids.map { [$0, 199, 1] })
        XCTAssertEqual(summary.labelSets.first?.labelled, [199, 199])
        XCTAssertEqual(summary.labelSets.first?.unlabelled, [1, 1])

        // The label of each cell, by its global id, is the name the request gave it, and 0 for a cell with no label.
        let indexOf = try database.cellLabels(labelSet: set.labelSet)
        XCTAssertEqual(indexOf.count, 400)
        for cell in 1...400 {
            let index = Int(indexOf[cell - 1])
            let name = set.labels.indices.contains(index - 1) ? set.labels[index - 1].name : nil
            XCTAssertEqual(name, given[Int32(cell)], "the label of cell \(cell)")
        }

        // The label table names each cell's own sample and barcode, and pseudobulk sums it into the groups the counts name.
        let lines = try parentCells.cells(offset: 0, limit: 400).compactMap { row in
            given[Int32(row.cell)].map { "\(names[row.sample] ?? "")\t\(row.barcode)\t\($0)" }
        }
        let table = try String(contentsOf: map.appendingPathComponent(set.table), encoding: .utf8)
        XCTAssertEqual(table, "sample\tbarcode\tlabel\n" + lines.joined(separator: "\n") + "\n")
        let outcome = try RNASeqPseudobulk.sum(result: parent, labels: map.appendingPathComponent(set.table), name: "pb")
        let groups = set.counts.map { count in
            "\(names[count.sample] ?? "")|\(set.labels.first { $0.label == count.label }?.name ?? "")|\(count.cells)"
        }
        XCTAssertEqual(Set(outcome.kept.map { "\($0.sample)|\($0.label)|\($0.cells)" }), Set(groups))
        XCTAssertEqual(Set(outcome.unlabelled.map { "\($0.sample)|\($0.cells)" }), Set(samples.map { "\($0.name)|1" }))
    }

    /// BIO SF1. Both samples hold the same data, so the second sample's cells are the first's plus 200 with equal UMIs and
    /// equal normalised bits, every total doubles, and each bound is taken over all 400 cells at rank 396 (index 395).
    func testTwoSamplesKeepTheirCellsAndTheBoundSetIsEveryCell() throws {
        let (_, map, _, summary) = try twoSampleCellMap()
        let database = try RNASeqCellMapDatabase(url: map.appendingPathComponent(RNASeqCellMap.filename))
        XCTAssertEqual(try database.cellCount(), 400)
        XCTAssertEqual(summary.genes.entries, 2 * 17_692)
        let features = try database.features()
        XCTAssertEqual(features.reduce(0) { $0 + $1.total }, 2 * 212_629, "each sample holds the cut's 212,629 UMIs")
        for feature in features where feature.cells > 0 {
            let umis = try XCTUnwrap(try database.geneValues(feature: feature.feature, unit: .umis))
            let normalised = try XCTUnwrap(try database.geneValues(feature: feature.feature, unit: .normalised))
            guard case .umis(let counts) = umis.values, case .normalised(let floats) = normalised.values else { return XCTFail("another unit") }
            XCTAssertEqual(umis.cells.count, feature.cells, "the cells of \(feature.id)")
            XCTAssertEqual(counts.reduce(0) { $0 + Int($1) }, feature.total, "the UMIs of \(feature.id)")
            XCTAssertEqual(normalised.cells, umis.cells)
            let low = umis.cells.filter { $0 <= 200 }
            let high = umis.cells.filter { $0 > 200 }.map { $0 - 200 }
            XCTAssertEqual(high, low, "the second sample's cells are the first's plus 200 for \(feature.id)")
            XCTAssertEqual(Array(counts.suffix(high.count)), Array(counts.prefix(low.count)), "the same UMIs for \(feature.id)")
            XCTAssertEqual(floats.suffix(high.count).map(\.bitPattern), floats.prefix(low.count).map(\.bitPattern), "the same normalised bits for \(feature.id)")
        }

        let cells = try CellMapFixture.rows("cells-starsolo.tsv")
        XCTAssertEqual(cells.count, 200)
        func expected(_ values: [Double]) -> [Double] {
            let all = (values + Array(repeating: 0, count: 400 - values.count)).sorted()
            return [all[0], all[399], all[395]]
        }
        let bounds = Dictionary(try database.valueBounds().map { ($0.value, [$0.minimum, $0.maximum, $0.p99]) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(bounds["umis"], expected((cells + cells).map { Double($0[3])! }), "the bounds of each cell's UMIs over 400 cells")
        XCTAssertEqual(bounds["genes"], expected((cells + cells).map { Double($0[4])! }), "the bounds of each cell's genes over 400 cells")
        let truth = try CellMapFixture.rows("genes-of-interest-starsolo.tsv")
        for id in ["ENSG00000090382", "ENSG00000163220"] {
            let rows = truth.filter { $0[0] == id }
            let feature = try XCTUnwrap(features.first { $0.id == id })
            let umis = try XCTUnwrap(try database.geneValues(feature: feature.feature, unit: .umis))
            let normalised = try XCTUnwrap(try database.geneValues(feature: feature.feature, unit: .normalised))
            XCTAssertEqual([umis.minimum, umis.maximum, umis.p99], expected((rows + rows).map { Double($0[4])! }), "the UMI bounds of \(id)")
            XCTAssertEqual([normalised.minimum, normalised.maximum, normalised.p99],
                           expected((rows + rows).map { Double(Float(bitPattern: UInt32($0[6], radix: 16)!)) }), "the normalised bounds of \(id)")
        }
    }

    // MARK: - The label of every cell and the not-host rows (fix round 1, item 3)

    /// BIO SF2. The fixture's labels "1" to "7" equal their numbers, so a table that stored a label's value for its number
    /// would pass there. Here `zero-based` numbers its labels from 0 and `named` holds names that sort in another order than
    /// the cells run. For each set and every cell, the stored number names the label the request gave. Each label's cells, in
    /// all and in each sample, equal the cells that hold its number, and the label table and pseudobulk agree with them.
    func testTheLabelOfEveryCellAgreesWithTheCountsAndTheTable() throws {
        let parent = try CellMapFixture.parent(in: root)
        var request = CellMapFixture.request(parent: parent)
        let labelled = request.labelSets[0].cells
        let kinds = ["T", "B", "NK", "Mono", "DC", "Plt", "Ery"]
        request.labelSets.append(.init(name: "zero-based", source: .imported, sourceFile: "source/3/zero-based.csv", cells: labelled,
                                       labels: labelled.map { String($0 % 7) }))
        request.labelSets.append(.init(name: "named", source: .imported, sourceFile: "source/4/named.csv", cells: labelled,
                                       labels: labelled.map { kinds[Int($0) % 7] }))
        let map = root.appendingPathComponent("pbmc-tsne.lungfishrnaseq", isDirectory: true)
        try CellMapFixture.write(request, to: map)
        let database = try RNASeqCellMapDatabase(url: map.appendingPathComponent(RNASeqCellMap.filename))
        let parentCells = try RNASeqCellsDatabase(url: parent.appendingPathComponent(RNASeqCellsDatabase.filename))
        let cells = try parentCells.cells(offset: 0, limit: 200)
        let sampleName = try XCTUnwrap(try parentCells.samples().first).name
        let sets = try database.labelSets()
        XCTAssertEqual(sets.map(\.name), ["graphclust", "zero-based", "named"])
        XCTAssertEqual(sets[1].labels.map(\.name), ["0", "1", "2", "3", "4", "5", "6"])
        XCTAssertEqual(sets[2].labels.map(\.name), ["B", "DC", "Ery", "Mono", "NK", "Plt", "T"])
        for (set, requested) in zip(sets, request.labelSets) {
            let given = Dictionary(uniqueKeysWithValues: zip(requested.cells, requested.labels))
            let indexOf = try database.cellLabels(labelSet: set.labelSet)
            for cell in 1...200 {
                let index = Int(indexOf[cell - 1])
                let name = set.labels.indices.contains(index - 1) ? set.labels[index - 1].name : nil
                XCTAssertEqual(name, given[Int32(cell)], "\(set.name), cell \(cell)")
            }
            for label in set.labels {
                XCTAssertEqual(indexOf.filter { Int($0) == label.label }.count, label.cells, "\(set.name), label \(label.name)")
                for count in set.counts where count.label == label.label {
                    let inSample = cells.indices.filter { Int(indexOf[$0]) == label.label && cells[$0].sample == count.sample }.count
                    XCTAssertEqual(inSample, count.cells, "\(set.name), label \(label.name), sample \(count.sample)")
                }
            }
            XCTAssertEqual(indexOf.filter { $0 != 0 }.count, set.samples.reduce(0) { $0 + $1.labelled }, "\(set.name), labelled cells")
            let table = try String(contentsOf: map.appendingPathComponent(set.table), encoding: .utf8)
            let lines = zip(requested.cells, requested.labels).map { "\(sampleName)\t\(cells[Int($0) - 1].barcode)\t\($1)" }
            XCTAssertEqual(table, "sample\tbarcode\tlabel\n" + lines.joined(separator: "\n") + "\n", "the label table of \(set.name)")
            let outcome = try RNASeqPseudobulk.sum(result: parent, labels: map.appendingPathComponent(set.table), name: "pb")
            XCTAssertEqual(Dictionary(outcome.kept.map { ($0.label, $0.cells) }, uniquingKeysWith: { first, _ in first }),
                           Dictionary(set.labels.map { ($0.name, $0.cells) }, uniquingKeysWith: { first, _ in first }), "pseudobulk of \(set.name)")
        }
    }

    /// BIO SF3. A parent with a not-host pass: 10 virus UMIs on cell 1, 4 on cell 150 and 1 on a barcode outside the cells.
    /// Each expected row is read from the parent's own tables and never through the cell-map writer.
    func testNotHostRowsEqualTheParentsTables() throws {
        let analyses = root.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let virus = SingleCellNotHostTests.virus
        let folder = try SingleCellFolderReader.read(folder: RNASeqPseudobulkTests.starsolo)
        let barcodes = try MatrixMarketReader.textLines(of: folder.url.appendingPathComponent(folder.barcodes))
        // The raw list is the cells and 50,000 more barcodes at 1 UMI, which puts the cells first and a pool behind.
        let more = (0..<50_000).map { SingleCellNotHostTests.barcode($0) }
        let raw = SingleCellRawMatrix(
            barcodes: SingleCellBarcodeTable(data: Data(((barcodes + more).joined(separator: "\n") + "\n").utf8)),
            totals: barcodes.map { _ in 900 } + more.map { _ in 1 })
        func read(_ barcode: String, _ umi: String) -> String {
            ["r\(barcode)\(umi)100", "0", "NC_045512.2", "100", "255", "50M", "*", "0", "0", "*", "*", "NH:i:1", "nM:i:0", "CB:Z:\(barcode)", "UB:Z:\(umi)"]
                .joined(separator: "\t")
        }
        var counter = SingleCellNotHostCounter(extras: [virus])
        let reads = (1...10).map { read(barcodes[0], "U\($0)") } + (1...4).map { read(barcodes[149], "V\($0)") }
            + [read(SingleCellNotHostTests.barcode(7), "U1")]
        try counter.add(samText: reads.joined(separator: "\n") + "\n")
        let pass = SingleCellNotHostPass.sample(
            folder.sample, cells: barcodes, raw: raw, pool: SingleCellAmbientPool(raw), tallies: counter.tallies(), extras: [virus])
        var parentRequest = try SingleCellFolderReader.request([folder], name: "pbmc", samples: [.init(id: folder.sample)], genomes: [])
        parentRequest.notHostCells = SingleCellNotHostResult(extras: [virus], records: [.init(name: "NC_045512.2", length: 29903)], samples: [pass])
        let parent = try CellMapFixture.writer.write(
            parentRequest, to: analyses.appendingPathComponent("pbmc.lungfishrnaseq"),
            envelope: ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test"))
        let map = analyses.appendingPathComponent("pbmc-tsne.lungfishrnaseq", isDirectory: true)
        try CellMapFixture.write(CellMapFixture.request(parent: parent), to: map)

        let database = try RNASeqCellMapDatabase(url: map.appendingPathComponent(RNASeqCellMap.filename))
        let parentCells = try RNASeqCellsDatabase(url: parent.appendingPathComponent(RNASeqCellsDatabase.filename))
        let extras = try parentCells.notHostExtras()
        XCTAssertEqual(extras.map(\.name), ["sars-cov-2"])
        XCTAssertEqual(try database.notHostExtras().map { "\($0.extra)|\($0.name)|\($0.kind)" }, extras.map { "\($0.extra)|\($0.name)|\($0.kind)" })

        // Each cell's sample, and each barcode with a cell by that cell, from the parent's tables.
        let cells = try parentCells.cells(offset: 0, limit: 200)
        let sampleOf = Dictionary(uniqueKeysWithValues: cells.map { ($0.cell, $0.sample) })
        let barcodeRows = try parentCells.notHostBarcodes()
        let cellOf = Dictionary(barcodeRows.compactMap { row in row.cell.map { ("\(row.sample)|\(row.barcode)", $0) } }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(barcodeRows.filter { $0.barcode == SingleCellNotHostTests.barcode(7) }.map(\.cell), [nil], "that barcode is outside the cells")
        let counts = try parentCells.notHostCounts()
        let calls = try parentCells.notHostCalls()
        let flagCounts = try database.flagCounts()
        let bounds = try database.valueBounds()
        for extra in extras {
            var umis: [Int: Int] = [:]
            for count in counts where count.extra == extra.extra && count.record == 0 && count.umis > 0 {
                if let cell = cellOf["\(count.sample)|\(count.barcode)"] { umis[cell] = count.umis }
            }
            var flags: [Int: String] = [:]
            for call in calls where call.extra == extra.extra && !call.flag.isEmpty { flags[call.cell] = call.flag }
            let stored = try database.cellNotHost(extra: extra.extra)
            let expectedRows = Set(umis.keys).union(flags.keys).sorted().map { "\($0)|\(umis[$0] ?? 0)|\(flags[$0] ?? "")" }
            XCTAssertEqual(stored.map { "\($0.cell)|\($0.umis)|\($0.flag)" }, expectedRows, "the rows of \(extra.name)")
            XCTAssertEqual(stored.filter { $0.umis > 0 }.map { [$0.cell, $0.umis] }, [[1, 10], [150, 4]], "the UMIs sit on cells 1 and 150 and the outside barcode has no row")
            XCTAssertEqual(stored.first { $0.cell == 1 }?.flag, "viral RNA above ambient")

            // The flags of each sample add up to its cells, and each flag's count is the number of calls with that flag.
            if extra.kind == ReferenceSetExtraKind.virus.rawValue || extra.kind == ReferenceSetExtraKind.bacterium.rawValue {
                for sample in try parentCells.samples() {
                    let rows = flagCounts.filter { $0.extra == extra.extra && $0.sample == sample.sample }
                    XCTAssertEqual(rows.reduce(0) { $0 + $1.cells }, sample.cells, "the flags of \(extra.name) add up to the cells of \(sample.name)")
                    let called = calls.filter { $0.extra == extra.extra && !$0.flag.isEmpty && sampleOf[$0.cell] == sample.sample }
                    var expectedFlags = Dictionary(grouping: called, by: \.flag).mapValues(\.count)
                    expectedFlags[""] = sample.cells - called.count
                    XCTAssertEqual(Dictionary(rows.map { ($0.flag, $0.cells) }, uniquingKeysWith: { first, _ in first }), expectedFlags)
                }
            }

            // The bound is the sort of all N values with the zeros at index rank - 1. Here 198 of 200 cells hold none, so
            // rank 198 is a zero while the maximum is 10, the edge where a legend must use the maximum.
            let all = (umis.values.map { Double($0) } + Array(repeating: 0, count: cells.count - umis.count)).sorted()
            let bound = try XCTUnwrap(bounds.first { $0.value == "not_host_umis" && $0.extra == extra.extra })
            XCTAssertEqual([bound.minimum, bound.maximum, bound.p99], [all[0], all[cells.count - 1], all[(99 * cells.count + 99) / 100 - 1]])
            XCTAssertEqual([bound.minimum, bound.maximum, bound.p99], [0, 10, 0])
        }
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
