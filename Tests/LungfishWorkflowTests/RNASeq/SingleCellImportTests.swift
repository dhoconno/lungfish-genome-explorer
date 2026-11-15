// SingleCellImportTests.swift - Cell Ranger and STARsolo folders, the summarizing pass and cells.sqlite (Phase 5.2 lane RS-SC-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The folder readers keep the files `docs/formats/rnaseq-bundle.md` names, the writer reads each kept matrix once in its
// stage and writes `cells.sqlite`, and `RNASeqCellsDatabase` reads it back. The pins are the cut's own counts
// (`Tests/Fixtures/rnaseq/README.md:19`) and the rows of `Tests/Fixtures/rnaseq/SHA256SUMS`.

import CryptoKit
import SQLite3
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class SingleCellImportTests: XCTestCase {
    var tempRoot: URL!
    var analyses: URL!
    var resultURL: URL { analyses.appendingPathComponent("pbmc.lungfishrnaseq", isDirectory: true) }

    static var starsoloRun: URL { RNASeqFixtures.root.appendingPathComponent("starsolo-pbmc_1k_v3", isDirectory: true) }
    static var cellRangerOuts: URL { RNASeqFixtures.root.appendingPathComponent("cellranger-pbmc_1k_v3/outs", isDirectory: true) }

    override func setUpWithError() throws {
        tempRoot = try TestTempDirectory.make(prefix: "single-cell-import")
        analyses = tempRoot.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { TestTempDirectory.cleanup(tempRoot) }

    func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// The fixture's own checksums, by path under `Tests/Fixtures/rnaseq`.
    func fixtureSums() throws -> [String: String] {
        let text = try String(contentsOf: RNASeqFixtures.root.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
        var sums: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            if parts.count == 2 { sums[parts[1].trimmingCharacters(in: .whitespaces)] = parts[0] }
        }
        return sums
    }

    @discardableResult
    func write(_ folders: [SingleCellFolder], genomes: [String] = []) throws -> URL {
        let request = try SingleCellFolderReader.request(
            folders, name: "pbmc", samples: folders.map { RNASeqSampleRecord(id: $0.sample) }, genomes: genomes)
        return try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(
            request, to: resultURL,
            envelope: ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test"))
    }

    func manifest(_ result: URL) throws -> RNASeqResultManifest {
        try JSONDecoder().decode(RNASeqResultManifest.self, from: Data(contentsOf: result.appendingPathComponent(RNASeqResultManifest.filename)))
    }

    func database(_ result: URL) throws -> RNASeqCellsDatabase {
        try RNASeqCellsDatabase(url: result.appendingPathComponent(RNASeqCellsDatabase.filename))
    }

    /// A Cell Ranger `outs/` folder of plain files in the temp folder, with the given features, barcodes and entries,
    /// and `comment` as the matrix's second line.
    func tinyOuts(
        named name: String, features: [String], barcodes: [String], entries: [String], header: String? = nil, comment: String = "%"
    ) throws -> URL {
        let outs = tempRoot.appendingPathComponent("\(name)/outs", isDirectory: true)
        let matrix = outs.appendingPathComponent("filtered_feature_bc_matrix", isDirectory: true)
        try FileManager.default.createDirectory(at: matrix, withIntermediateDirectories: true)
        let banner = header ?? "%%MatrixMarket matrix coordinate integer general"
        let text = ([banner, comment, "\(features.count) \(barcodes.count) \(entries.count)"] + entries).joined(separator: "\n") + "\n"
        try Data(text.utf8).write(to: matrix.appendingPathComponent("matrix.mtx"))
        try Data((features.joined(separator: "\n") + "\n").utf8).write(to: matrix.appendingPathComponent("features.tsv"))
        try Data((barcodes.joined(separator: "\n") + "\n").utf8).write(to: matrix.appendingPathComponent("barcodes.tsv"))
        return outs
    }

    func refusalWords(_ body: () throws -> Void) -> String? {
        do {
            try body()
            XCTFail("nothing was refused")
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    // MARK: - The two cuts

    func testTheSTARsoloCutImportsWithItsCountedCells() throws {
        let folder = try SingleCellFolderReader.read(folder: Self.starsoloRun)
        XCTAssertEqual(folder.tool, .starsolo)
        XCTAssertEqual(folder.sample, "starsolo-pbmc_1k_v3")
        XCTAssertEqual(folder.keptFiles, [
            "Log.final.out", "Solo.out/Gene/Summary.csv", "Solo.out/Gene/filtered/barcodes.tsv",
            "Solo.out/Gene/filtered/features.tsv", "Solo.out/Gene/filtered/matrix.mtx",
        ])
        XCTAssertEqual(folder.leftOut, ["Solo.out/Barcodes.stats", "Solo.out/Gene/Features.stats"])
        let result = try write([folder])
        let manifest = try manifest(result)
        XCTAssertEqual(manifest.modality, .singleCell)
        XCTAssertEqual(manifest.route.toolVersion, "Not recorded", "STARsolo's matrix states no version")
        XCTAssertEqual(manifest.origin.toolVersion, "Not recorded")
        let matrix = try XCTUnwrap(manifest.matrices?.first)
        XCTAssertEqual([matrix.cellCount, matrix.featureCount, matrix.entryCount], [200, 1_353, 17_692])
        XCTAssertFalse(matrix.isGzip)
        let sums = try fixtureSums()
        XCTAssertEqual(matrix.matrix.path, "source/starsolo-pbmc_1k_v3/Solo.out/Gene/filtered/matrix.mtx")
        XCTAssertEqual(matrix.matrix.sha256, sums["starsolo-pbmc_1k_v3/Solo.out/Gene/filtered/matrix.mtx"])
        XCTAssertEqual(matrix.barcodes.sha256, sums["starsolo-pbmc_1k_v3/Solo.out/Gene/filtered/barcodes.tsv"])
        let cellsFile = result.appendingPathComponent(RNASeqCellsDatabase.filename)
        let summary = try XCTUnwrap(manifest.cellsSummary)
        XCTAssertEqual(summary.path, RNASeqCellsDatabase.filename)
        XCTAssertEqual(summary.sha256, sha256(try Data(contentsOf: cellsFile)))
        XCTAssertEqual(summary.schemaVersion, 2)
        XCTAssertEqual(try RNASeqResultBundle.verifyChecksums(of: result), [])

        let db = try database(result)
        XCTAssertEqual(db.schemaVersion, 2)
        let cells = try db.cells(offset: 0, limit: 1_000)
        XCTAssertEqual(cells.count, 200)
        XCTAssertEqual(cells.reduce(0) { $0 + $1.umis }, 212_629)
        XCTAssertTrue(cells.allSatisfy { !$0.barcode.hasSuffix("-1") && $0.sample == 1 }, "STARsolo's barcodes stay bare")
        XCTAssertEqual(cells.map(\.column), Array(1...200))
        let features = try db.features()
        XCTAssertEqual(features.count, 1_353)
        XCTAssertEqual(features.reduce(0) { $0 + $1.total }, 212_629)
        XCTAssertEqual(features.reduce(0) { $0 + $1.cells }, 17_692, "no entry of the cut is zero")
        XCTAssertEqual(try db.samples().map(\.entries), [17_692])
        XCTAssertEqual(try db.meta()["sha256:\(matrix.matrix.path)"], matrix.matrix.sha256)
        XCTAssertEqual(try db.genomes(), [])
    }

    func testTheCellRangerCutImportsWithItsBarcodesAsGiven() throws {
        let folder = try SingleCellFolderReader.read(folder: Self.cellRangerOuts)
        XCTAssertEqual(folder.tool, .cellRanger)
        XCTAssertEqual(folder.sample, "cellranger-pbmc_1k_v3")
        XCTAssertEqual(folder.keptFiles, [
            "filtered_feature_bc_matrix/barcodes.tsv.gz", "filtered_feature_bc_matrix/features.tsv.gz",
            "filtered_feature_bc_matrix/matrix.mtx.gz", "metrics_summary.csv",
        ])
        let result = try write([folder])
        let manifest = try manifest(result)
        XCTAssertEqual(manifest.route.toolVersion, "3.0.0", "line 2 of matrix.mtx.gz states Cell Ranger's version")
        XCTAssertEqual(manifest.origin.toolVersion, "3.0.0")
        let matrix = try XCTUnwrap(manifest.matrices?.first)
        XCTAssertEqual([matrix.cellCount, matrix.featureCount, matrix.entryCount], [200, 1_353, 17_708])
        XCTAssertTrue(matrix.isGzip)
        let sums = try fixtureSums()
        for file in folder.keptFiles {
            let kept = try XCTUnwrap(manifest.sourceFiles.first { $0.path == "source/cellranger-pbmc_1k_v3/\(file)" }, file)
            XCTAssertEqual(kept.sha256, sums["cellranger-pbmc_1k_v3/outs/\(file)"], file)
        }
        let db = try database(result)
        let cells = try db.cells(offset: 0, limit: 1_000)
        XCTAssertEqual(cells.reduce(0) { $0 + $1.umis }, 212_733)
        XCTAssertTrue(cells.allSatisfy { $0.barcode.hasSuffix("-1") }, "10x's barcodes keep their -1")
        XCTAssertEqual(try db.features().reduce(0) { $0 + $1.total }, 212_733)
        let quality = try XCTUnwrap(try RNASeqResultBundle.load(from: result).quality)
        let column = try XCTUnwrap(quality.columns.firstIndex(of: "Estimated Number of Cells"))
        XCTAssertEqual(quality.rows.first?.values[column], "1,222", "the summary's number as Cell Ranger printed it")
    }
}
