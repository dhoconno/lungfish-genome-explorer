// RNASeqCellMapKindTests.swift - The cell-map modality beside the older results and the readers it meets (Phase 5.5 lane CM-KIND)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// A fresh bulk, single-cell and pseudobulk write stays at manifest schema 1 with none of the cell map's keys, and opens as
// before (5.5 L2, ARCH OBJECT 1). Export, quality and pseudobulk refuse a cell map in words before they hash or write
// anything, and the cell-map writer refuses a parent that is a bulk result or a cell map (ARCH OBJECT 2). Each class name
// matches the lane's filter.

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCore
@testable import LungfishIO
@testable import LungfishWorkflow

final class RNASeqResultManifestCellMapTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-cell-map-kind") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    static func bulkResult(in root: URL) throws -> URL {
        let samples = ["S1", "S2"].map { RNASeqSampleRecord(id: $0, animal: $0, species: "Homo sapiens", origin: "blood", runs: [$0]) }
        let table = RNASeqCountTable(sampleIDs: ["S1", "S2"], rows: [.init(id: "G1", counts: [1, 2]), .init(id: "G2", counts: [3, 4])])
        let request = RNASeqResultWriter.Request(
            name: "bulk", modality: .bulk, origin: .init(kind: .imported, tool: "salmon", toolVersion: "1.10.3"),
            route: .init(id: "salmon", tool: "salmon", toolVersion: "1.10.3", settings: [:]), referenceSet: nil, samples: samples,
            genes: .ids(["G1", "G2"]), counts: [.init(rows: .gene, column: .default, unit: .estimated, table: table)], sourceFiles: [], notHost: [])
        let url = root.appendingPathComponent("bulk.lungfishrnaseq", isDirectory: true)
        return try CellMapFixture.writer.write(request, to: url, envelope: ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test"))
    }

    static func pseudobulkResult(from parent: URL, in root: URL) throws -> URL {
        let outcome = try RNASeqPseudobulk.sum(result: parent, labels: RNASeqPseudobulkTests.fixture.appendingPathComponent("labels-starsolo.tsv"), name: "pb")
        let url = root.appendingPathComponent("pb.lungfishrnaseq", isDirectory: true)
        return try CellMapFixture.writer.write(outcome.request, to: url, envelope: ProvenanceEnvelope(workflowName: "RNA-seq pseudobulk", toolName: "lungfish-cli", toolVersion: "test"))
    }

    func testAFreshBulkSingleCellAndPseudobulkWriteStayAtSchemaOneAndOpenAsBefore() throws {
        let single = try CellMapFixture.parent(in: root)
        let results = [("bulk", try Self.bulkResult(in: root)), ("single-cell", single), ("pseudobulk", try Self.pseudobulkResult(from: single, in: root))]
        for (what, url) in results {
            let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: RNASeqResultBundle.manifestURL(in: url))) as? [String: Any])
            XCTAssertEqual(json["schemaVersion"] as? Int, 1, "a fresh \(what) write carries schemaVersion 1")
            for key in ["parent", "cellMap", "labelTables"] { XCTAssertNil(json[key], "a \(what) manifest holds no \(key)") }
            let loaded = try RNASeqResultBundle.load(from: url)
            XCTAssertEqual(loaded.manifest.schemaVersion, 1)
            XCTAssertNil(loaded.manifest.parent)
            XCTAssertEqual(try RNASeqResultBundle.verifyChecksums(of: url), [], "\(what) is at its sha256 values")
        }
        XCTAssertEqual(try RNASeqResultBundle.loadManifest(from: results[2].1).origin.kind, .pseudobulk)
    }

    func testTheWriterRefusesAParentThatIsABulkResultOrACellMap() throws {
        let (_, map, _) = try CellMapFixture.cellMap(in: root)
        let bulk = try Self.bulkResult(in: root)
        let tail = "rnaseq cell-map import reads a single-cell result, such as one that import rnaseq made from Cell Ranger or STARsolo folders."
        for (parent, words) in [(map, "pbmc-tsne is a cell map. " + tail), (bulk, "bulk is a bulk result. " + tail)] {
            let out = root.appendingPathComponent("again.lungfishrnaseq", isDirectory: true)
            XCTAssertThrowsError(try CellMapFixture.write(CellMapFixture.request(parent: parent), to: out)) { XCTAssertEqual($0.localizedDescription, words) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
        }
    }
}

final class RNASeqExportCellMapTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-cell-map-export") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    func testExportRefusesACellMapInWords() throws {
        let (_, map, _) = try CellMapFixture.cellMap(in: root)
        let words = "pbmc-tsne.lungfishrnaseq is a cell map, which holds coordinates and labels and no counts. Export its single-cell result, pbmc.lungfishrnaseq."
        XCTAssertThrowsError(try RNASeqExportReader.read([map])) { XCTAssertEqual($0 as? RNASeqExportRefusal, RNASeqExportRefusal(words)) }
        let output = root.appendingPathComponent("export", isDirectory: true)
        XCTAssertThrowsError(try RNASeqExport.run(results: [map], sheet: nil, settings: .init(), output: output, argv: [])) {
            XCTAssertEqual($0.localizedDescription, words)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "nothing is written")
    }
}

final class RNASeqQualityCellMapTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-cell-map-quality") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    func testQualityRefusesACellMapInWords() throws {
        let (_, map, _) = try CellMapFixture.cellMap(in: root)
        XCTAssertThrowsError(try RNASeqQualitySummary.loadVerified(map)) {
            XCTAssertEqual($0.localizedDescription,
                "pbmc-tsne.lungfishrnaseq is a cell map, which holds coordinates and labels and no counts. rnaseq quality reads the count table of a bulk result, "
                + "so give a bulk result, or sum the cells of its single-cell result, pbmc.lungfishrnaseq, with rnaseq pseudobulk.")
        }
    }
}

final class RNASeqPseudobulkCellMapTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-cell-map-pseudobulk") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    func testPseudobulkRefusesACellMapGivenAsTheResultInWords() throws {
        let (_, map, _) = try CellMapFixture.cellMap(in: root)
        let labels = map.appendingPathComponent("labels/graphclust.tsv")
        let before = try FileManager.default.contentsOfDirectory(atPath: root.path).sorted()
        XCTAssertThrowsError(try RNASeqPseudobulk.sum(result: map, labels: labels, name: "pb")) {
            XCTAssertEqual($0.localizedDescription,
                "pbmc-tsne is a cell map, which holds coordinates and labels and no counts. Give its single-cell result, pbmc.lungfishrnaseq, and name the cell map with --cell-map.")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted(), before)
    }

    func testTheCellMapsLabelTableSumsWithNoNewCode() throws {
        let (parent, map, _) = try CellMapFixture.cellMap(in: root)
        let outcome = try RNASeqPseudobulk.sum(result: parent, labels: map.appendingPathComponent("labels/graphclust.tsv"), name: "pb")
        XCTAssertEqual(outcome.request.counts.first?.table.sampleIDs.count, 7, "the seven labels of graphclust are seven groups of one sample")
    }
}
