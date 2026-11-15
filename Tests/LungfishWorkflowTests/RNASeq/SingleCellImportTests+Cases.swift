// SingleCellImportTests+Cases.swift - Genomes, feature types, left-out files and refusals (Phase 5.2 lane RS-SC-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import CryptoKit
import SQLite3
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

extension SingleCellImportTests {
    func testTwoGenomesNamedByPrefixAndOnlyGeneExpressionEntersTheCellTotals() throws {
        let outs = try tinyOuts(
            named: "hgmm",
            features: ["hg19_A\tA\tGene Expression", "hg19_B\tB\tGene Expression", "mm10_C\tC\tGene Expression", "ADT1\tCD3\tAntibody Capture"],
            barcodes: ["AAAC-1", "CCCG-1"], entries: ["1 1 3", "3 1 1", "4 1 50", "2 2 4", "3 2 6"])
        let folder = try SingleCellFolderReader.read(folder: outs)
        XCTAssertEqual(folder.sample, "hgmm")
        XCTAssertEqual(folder.featureTypes, ["Antibody Capture": 1, "Gene Expression": 3])
        let result = try write([folder], genomes: ["hg19", "mm10"])
        let db = try database(result)
        XCTAssertEqual(try db.genomes(), ["hg19", "mm10"])
        let cells = try db.cells(offset: 0, limit: 10)
        XCTAssertEqual(cells.map(\.barcode), ["AAAC-1", "CCCG-1"])
        XCTAssertEqual(cells.map(\.umis), [4, 10], "the antibody's 50 stay out of the cell's UMIs")
        XCTAssertEqual(cells.map(\.genes), [2, 2])
        let byGenome = try db.cellGenomes()
        XCTAssertEqual(byGenome.map { [$0.cell, $0.genome, $0.umis, $0.genes] }, [[1, 1, 3, 1], [1, 2, 1, 1], [2, 1, 4, 1], [2, 2, 6, 1]])
        let features = try db.features()
        XCTAssertEqual(features.map(\.genome), [1, 1, 2, nil])
        XCTAssertEqual(features.map(\.total), [3, 4, 7, 50])
        XCTAssertEqual(features.map(\.cells), [1, 1, 2, 1])
        let facts = SingleCellFolderReader.facts([folder], genomes: ["hg19", "mm10"])
        XCTAssertEqual(facts["featureTypes"], .array([.string("hgmm: Antibody Capture 1, Gene Expression 3")]))
        XCTAssertEqual(facts["genomes"], .string("hg19, mm10, named by the person by the prefix of each gene id"))
    }

    func testAFeatureOfNoNamedGenomeIsRefusedInWords() throws {
        let outs = try tinyOuts(
            named: "hgmm", features: ["hg19_A\tA\tGene Expression", "mm10_C\tC\tGene Expression"],
            barcodes: ["AAAC-1"], entries: ["1 1 3"])
        let folder = try SingleCellFolderReader.read(folder: outs)
        XCTAssertEqual(
            refusalWords { _ = try SingleCellFolderReader.request([folder], name: "x", samples: [.init(id: "hgmm")], genomes: ["hg19"]) },
            "The feature mm10_C of hgmm starts with none of the genomes named (hg19). Name every genome of the reference with --genome, or none.")
    }

    func testRawFolderAndHDF5StayOutAndTheRecordNamesEachH5WithItsSha256AndSize() throws {
        let outs = tempRoot.appendingPathComponent("pbmc/outs", isDirectory: true)
        try FileManager.default.createDirectory(at: outs.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: Self.cellRangerOuts, to: outs)
        let raw = outs.appendingPathComponent("raw_feature_bc_matrix", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        try Data("AAAC-1\n".utf8).write(to: raw.appendingPathComponent("barcodes.tsv.gz"))
        let h5 = Data("not really HDF5".utf8)
        try h5.write(to: outs.appendingPathComponent("filtered_feature_bc_matrix.h5"))
        try Data("<html/>".utf8).write(to: outs.appendingPathComponent("web_summary.html"))
        let folder = try SingleCellFolderReader.read(folder: outs.deletingLastPathComponent())
        XCTAssertEqual(folder.sample, "pbmc", "a run folder that holds outs/ reads as its outs/")
        XCTAssertEqual(folder.leftOut, ["filtered_feature_bc_matrix.h5", "raw_feature_bc_matrix/", "web_summary.html"])
        XCTAssertEqual(folder.leftOutHDF5, [.init(path: "filtered_feature_bc_matrix.h5", sha256: sha256(h5), size: Int64(h5.count))])
        let result = try write([folder])
        XCTAssertFalse(try manifest(result).sourceFiles.contains { $0.path.contains("raw") || $0.path.hasSuffix(".h5") })
        let facts = SingleCellFolderReader.facts([folder], genomes: [])
        XCTAssertEqual(facts[RNASeqImportFacts.filesLeftOutKey], .array([
            .string("pbmc/filtered_feature_bc_matrix.h5 (sha256 \(sha256(h5)), \(h5.count) bytes)"),
            .string("pbmc/raw_feature_bc_matrix/"), .string("pbmc/web_summary.html"),
        ]))
    }

    func testARealHeaderIsRefusedBeforeAnythingIsWritten() throws {
        let header = "%%MatrixMarket matrix coordinate real general"
        let outs = try tinyOuts(named: "velo", features: ["G1\tG1\tGene Expression"], barcodes: ["AAAC-1"], entries: ["1 1 0.5"], header: header)
        XCTAssertEqual(
            refusalWords { _ = try SingleCellFolderReader.read(folder: outs) },
            "This matrix holds real values (\(header)), and LGE counts whole unique UMIs a cell. Import the folder's integer matrix, such as Solo.out/Gene/filtered/matrix.mtx.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: analyses.path), [])
    }

    func testADecimalValueInThePassLeavesNoStageAndNoResult() throws {
        let outs = try tinyOuts(named: "half", features: ["G1\tG1\tGene Expression"], barcodes: ["AAAC-1", "CCCG-1"], entries: ["1 1 2", "1 2 1.5"])
        let folder = try SingleCellFolderReader.read(folder: outs)
        XCTAssertEqual(
            refusalWords { try write([folder]) },
            "This matrix holds decimal values (line 5 of matrix.mtx reads 1 2 1.5), and LGE counts whole unique UMIs a cell. Import the folder's integer matrix, such as Solo.out/Gene/filtered/matrix.mtx.")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: analyses.path), [], "no stage and no result")
    }

    func testBarcodesUnlikeTheSizeLineAreRefused() throws {
        let outs = try tinyOuts(named: "short", features: ["G1\tG1\tGene Expression"], barcodes: ["AAAC-1", "CCCG-1"], entries: ["1 1 2"])
        try Data("AAAC-1\n".utf8).write(to: outs.appendingPathComponent("filtered_feature_bc_matrix/barcodes.tsv"))
        XCTAssertEqual(
            refusalWords { _ = try SingleCellFolderReader.read(folder: outs) },
            "The matrix of short states 2 barcodes in its size line and barcodes.tsv lists 1, so the files do not belong together.")
    }

    func testCellRangerMultiIsRefusedInWords() throws {
        let outs = tempRoot.appendingPathComponent("multi/outs", isDirectory: true)
        try FileManager.default.createDirectory(at: outs.appendingPathComponent("per_sample_outs/s1/count"), withIntermediateDirectories: true)
        XCTAssertEqual(
            refusalWords { _ = try SingleCellFolderReader.read(folder: outs) },
            "multi is the outs folder of cellranger multi, whose per-sample folders LGE does not import yet. Import a cellranger count outs folder or a STARsolo run folder.")
    }

    func testCellRangerAndSTARsoloInOneResultAreRefused() throws {
        let folders = [try SingleCellFolderReader.read(folder: Self.starsoloRun), try SingleCellFolderReader.read(folder: Self.cellRangerOuts)]
        XCTAssertEqual(
            refusalWords { _ = try SingleCellFolderReader.request(folders, name: "x", samples: folders.map { .init(id: $0.sample) }, genomes: []) },
            "Cell Ranger and STARsolo count cells by two routes, so their folders cannot share one result. Import each tool's folders in a run of its own.")
    }

    func testANewerCellsSchemaIsRefusedInWords() throws {
        let result = try write([try SingleCellFolderReader.read(folder: Self.starsoloRun)])
        let file = result.appendingPathComponent(RNASeqCellsDatabase.filename)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(file.path, &db, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, "UPDATE meta SET value = '2' WHERE key = 'schema_version'", nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)
        XCTAssertEqual(
            refusalWords { _ = try database(result) },
            "This RNA-seq result was written by a newer LGE (schema 2). Open it with that version or a later one.")
    }
}
