// RNASeqExportCellsTests.swift - The export of a single-cell result (Phase 5.2 lane RS-SC-HANDOFF, slice B)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// `rnaseq export` of a single-cell result copies each sample's matrix, features and barcodes as given into a folder of its own,
// beside genes.tsv, samples.tsv, seurat.R and scanpy.py. The pins are the manifest's sha256 values, the 200 cells of the
// pbmc_1k_v3 cuts and the refusals in words. A single-cell result never joins a bulk result or a second single-cell result.

import XCTest
import LungfishCore
import LungfishIO
@testable import LungfishWorkflow

final class RNASeqExportCellsTests: RNASeqExportTestCase {
    static let starsolo = RNASeqPseudobulkTests.starsolo
    static let cellRanger = RNASeqPseudobulkTests.cellRanger

    func cells(_ source: URL = starsolo, name: String = "cells") throws -> URL {
        try RNASeqPseudobulkTests.singleCellResult([source], name: name, in: analyses)
    }

    @discardableResult
    func export(
        _ results: [URL], name: String = "out", sheet: URL? = nil, settings: RNASeqExportSettings = RNASeqExportSettings(),
        checkpoint: (() throws -> Void)? = nil
    ) throws -> URL {
        try RNASeqExport.run(
            results: results, sheet: sheet, settings: settings, output: root.appendingPathComponent(name, isDirectory: true),
            argv: ["lungfish-cli", "rnaseq", "export"], checkpoint: checkpoint)
    }

    /// What a refused export leaves in `root`: no folder and no stage.
    func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? ["unreadable"]).filter { $0.hasPrefix(".") || $0 == "out" }
    }

    /// The refusal's words. A failure when the export was written, and nothing may be left behind either way.
    func refusal(_ results: [URL], settings: RNASeqExportSettings = RNASeqExportSettings(), file: StaticString = #filePath, line: UInt = #line) -> String? {
        do {
            try export(results, settings: settings)
            XCTFail("the export was written", file: file, line: line)
            return nil
        } catch let refusal as RNASeqExportRefusal {
            XCTAssertEqual(leftovers(), [], "a refused export leaves no stage and no folder", file: file, line: line)
            return refusal.message
        } catch {
            XCTFail("\(error)", file: file, line: line)
            return nil
        }
    }

    /// The folder the sample takes in the export, and the three files of its matrix as the manifest lists them.
    func listed(_ result: URL) throws -> (folder: String, files: [(entry: RNASeqResultManifest.FileEntry, name: String)]) {
        let matrix = try XCTUnwrap(try RNASeqResultBundle.loadManifest(from: result).matrices?.first)
        let parts = matrix.matrix.path.split(separator: "/").map(String.init)
        return (parts[1], [matrix.matrix, matrix.features, matrix.barcodes].map { (entry: $0, name: $0.path.split(separator: "/").last.map(String.init) ?? "") })
    }

    func cellCount(_ result: URL) throws -> Int? {
        try RNASeqCellsDatabase(url: result.appendingPathComponent(RNASeqCellsDatabase.filename)).samples().first?.cells
    }

    func testAPlainMatrixFolderIsCopiedAsGivenAndEachFileKeepsItsManifestHash() throws {
        let result = try cells()
        let out = try export([result])
        let (folder, files) = try listed(result)
        XCTAssertEqual(files.map(\.name), ["matrix.mtx", "features.tsv", "barcodes.tsv"])
        for file in files {
            let copy = out.appendingPathComponent("\(folder)/\(file.name)")
            XCTAssertEqual(try RNASeqResultBundle.sha256Hex(fileAt: copy), file.entry.sha256, "\(file.name) is the file the result keeps")
        }
        let barcodes = try String(contentsOf: out.appendingPathComponent("\(folder)/barcodes.tsv"), encoding: .utf8)
        XCTAssertEqual(barcodes.split(separator: "\n").count, 200)
        XCTAssertEqual(try cellCount(result), 200)
    }

    func testAGzipMatrixFolderKeepsItsGzNamesAndHashes() throws {
        let result = try cells(Self.cellRanger, name: "cr")
        let out = try export([result])
        let (folder, files) = try listed(result)
        XCTAssertEqual(files.map(\.name), ["matrix.mtx.gz", "features.tsv.gz", "barcodes.tsv.gz"])
        for file in files {
            let copy = out.appendingPathComponent("\(folder)/\(file.name)")
            XCTAssertEqual(try RNASeqResultBundle.sha256Hex(fileAt: copy), file.entry.sha256, "\(file.name) is the file the result keeps")
        }
        XCTAssertEqual(try RNASeqResultBundle.loadManifest(from: result).matrices?.first?.isGzip, true)
        XCTAssertEqual(try cellCount(result), 200)
    }

    func testTheFolderHoldsTheFourFilesTheRecordAndOneFolderASample() throws {
        let result = try cells()
        let out = try export([result])
        let (folder, _) = try listed(result)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: out.path).sorted(),
            [".lungfish-provenance.json", folder, "genes.tsv", "samples.tsv", "scanpy.py", "seurat.R"].sorted())
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: out.appendingPathComponent(folder).path).sorted(),
            ["barcodes.tsv", "features.tsv", "matrix.mtx"])
        let genes = try RNASeqGeneRecord.records(tsv: Data(contentsOf: out.appendingPathComponent("genes.tsv")), path: "genes.tsv")
        XCTAssertEqual(genes, try RNASeqResultBundle.load(from: result).genes)
    }

    func testSamplesTsvHoldsTheSheetColumnsThenFolderRouteAndReferenceSet() throws {
        let result = try cells()
        let loaded = try RNASeqResultBundle.load(from: result)
        let id = try XCTUnwrap(loaded.samples.first?.id)
        let sheet = root.appendingPathComponent("sheet.tsv")
        // A sheet's own folder or route column decides nothing, as at a bulk export.
        try "sample\tgroup\tdonor\tfolder\troute\n\(id)\tPBMC\tD1\tnot-this\tnot-that\n".write(to: sheet, atomically: true, encoding: .utf8)
        let out = try export([result], sheet: sheet)
        let lines = try String(contentsOf: out.appendingPathComponent("samples.tsv"), encoding: .utf8).split(separator: "\n").map { $0.components(separatedBy: "\t") }
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0], ["sample_id", "animal", "species", "origin", "group", "runs", "donor", "folder", "route", "reference_set"])
        XCTAssertEqual(lines[1], [id, "A1", "Homo sapiens", "blood", "PBMC", id, "D1", try listed(result).folder,
                                  RNASeqExportWords.route(loaded.manifest.route), RNASeqExportWords.referenceSet(loaded.manifest.referenceSet)])
    }

    func testTheRecordNamesTheModalityTheRouteAndEveryMatrixFile() throws {
        let result = try cells()
        let out = try export([result])
        let manifest = try RNASeqResultBundle.loadManifest(from: result)
        let record = try XCTUnwrap(try ProvenanceEnvelopeReader.loadCanonical(from: out))
        let resolved = record.options.resolvedDefaults
        XCTAssertEqual(resolved["modality"], .string("single-cell"))
        XCTAssertEqual(resolved["route"], .string(RNASeqExportWords.route(manifest.route)))
        XCTAssertEqual(resolved["referenceSet"], .string(RNASeqExportWords.referenceSet(manifest.referenceSet)))
        guard case .array(let items)? = resolved["matrixFiles"] else { return XCTFail("the record lists no matrix file") }
        let (folder, files) = try listed(result)
        XCTAssertEqual(items.count, 3)
        for (value, file) in zip(items, files) {
            guard case .dictionary(let item) = value else { return XCTFail("a matrix file is no dictionary") }
            XCTAssertEqual(item["path"], .string("\(folder)/\(file.name)"))
            XCTAssertEqual(item["sha256"], .string(file.entry.sha256))
            XCTAssertEqual(item["source"], .string(file.entry.path))
            let size = try FileManager.default.attributesOfItem(atPath: out.appendingPathComponent("\(folder)/\(file.name)").path)[.size] as? Int
            XCTAssertEqual(item["size"], size.map(ParameterValue.integer))
        }
    }

    func testASingleCellResultWithABulkResultIsRefusedInWordsAndNothingIsWritten() throws {
        let single = try cells()
        let bulk = try make(.init(name: "bulk", samples: ["S1", "S2"], groups: ["S1": "TB", "S2": "HIV"]))
        let words = "The single-cell result cells.lungfishrnaseq cannot share an export with the bulk result bulk.lungfishrnaseq. "
            + "The export of a single-cell result writes its matrices and the Seurat and Scanpy templates by itself. "
            + "Export it alone, or sum its cells with rnaseq pseudobulk and export that bulk result."
        XCTAssertEqual(refusal([single, bulk]), words)
        XCTAssertEqual(refusal([bulk, single]), words, "the order of the results changes no word")
    }

    func testTwoSingleCellResultsAreRefusedInWordsAndNothingIsWritten() throws {
        let first = try cells(name: "a")
        let copy = try RNASeqPseudobulkTests.starsoloCopy("second", in: root)
        let second = try RNASeqPseudobulkTests.singleCellResult([copy], name: "b", in: analyses)
        XCTAssertEqual(refusal([first, second]),
            "The results a.lungfishrnaseq and b.lungfishrnaseq are both single-cell. LGE writes one folder of matrices for one result, "
            + "so export each by itself, or import the samples into one result.")
    }

    func testEachFlagThatDoesNothingOnASingleCellExportIsRefusedAndPointsToPseudobulk() throws {
        let result = try cells()
        let given: [(flag: String, settings: RNASeqExportSettings)] = [
            ("--design", RNASeqExportSettings(design: ["group"])),
            ("--contrast", RNASeqExportSettings(contrasts: [.init(factor: "group", numerator: "T", denominator: "B")])),
            ("--batch", RNASeqExportSettings(batch: "donor")),
            ("--batch-correction", RNASeqExportSettings(batchCorrection: .sva)),
            ("--lfc-bar", RNASeqExportSettings(lfcBar: 1)),
            ("--padj-cutoff", RNASeqExportSettings(padjCutoff: 0.01)),
        ]
        let tail = "which copies the matrices and writes the Seurat and Scanpy templates and tests no difference between groups. "
            + "Leave it out, or sum the cells with rnaseq pseudobulk and export that bulk result with it."
        for item in given {
            XCTAssertEqual(refusal([result], settings: item.settings), "The flag \(item.flag) does nothing on a single-cell export, \(tail)")
        }
        let two = RNASeqExportSettings(design: ["group"], contrasts: [.init(factor: "group", numerator: "T", denominator: "B")])
        XCTAssertEqual(refusal([result], settings: two),
            "The flags --design and --contrast do nothing on a single-cell export, "
            + tail.replacingOccurrences(of: "Leave it out", with: "Leave them out").replacingOccurrences(of: "with it.", with: "with them."))
        XCTAssertNoThrow(try export([result]), "the default settings pass, and 0.05 is the default cutoff")
    }

    func testACancelInTheCheckpointLeavesNoStageAndNoFolder() throws {
        let result = try cells()
        XCTAssertThrowsError(try export([result], checkpoint: { throw CancellationError() })) { XCTAssertTrue($0 is CancellationError, "\($0)") }
        XCTAssertEqual(leftovers(), [], "a cancelled export leaves no stage and no folder")
    }

    func testTheTemplatesReadMatrixMarketByHandAndNeverTheTenXFolderLayout() throws {
        let out = try export([try cells()])
        let seurat = try String(contentsOf: out.appendingPathComponent("seurat.R"), encoding: .utf8)
        let scanpy = try String(contentsOf: out.appendingPathComponent("scanpy.py"), encoding: .utf8)
        for (name, text) in [("seurat.R", seurat), ("scanpy.py", scanpy)] {
            XCTAssertFalse(text.contains("read_10x_mtx"), "\(name) reads no 10x folder layout")
            XCTAssertFalse(text.contains("Read10X"), "\(name) reads no 10x folder layout")
            for words in ["cells total", "not-host features", "samples.tsv", "genes.tsv", "Gene Expression"] {
                XCTAssertTrue(text.contains(words), "\(name) holds \(words)")
            }
        }
        for words in ["Matrix::readMM(", "gzfile(", "seurat-cells.tsv", #"requireNamespace("Seurat", quietly = TRUE)"#, "CreateSeuratObject(", "Seurat is not installed"] {
            XCTAssertTrue(seurat.contains(words), "seurat.R holds \(words)")
        }
        for words in ["scipy.io.mmread(", "gzip.open(", "scanpy-cells.tsv", "import scanpy", "Scanpy is not installed"] {
            XCTAssertTrue(scanpy.contains(words), "scanpy.py holds \(words)")
        }
    }

    /// The Seurat object and the AnnData hold every feature type in one assay, while the table of cells counts Gene Expression only,
    /// so both scripts print how many features are of another type. `RNASeqExportCellsConformanceTests` runs the two lines.
    func testBothTemplatesPrintHowManyFeaturesAreNotGeneExpression() throws {
        let out = try export([try cells()])
        let seurat = try String(contentsOf: out.appendingPathComponent("seurat.R"), encoding: .utf8)
        let scanpy = try String(contentsOf: out.appendingPathComponent("scanpy.py"), encoding: .utf8)
        XCTAssertTrue(seurat.contains(#"cat(sprintf("features %d, of them %d not %s\n", nrow(combined), sum(info$type != feature_type), feature_type))"#), seurat)
        XCTAssertTrue(scanpy.contains(#"print("features %d, of them %d not %s" % (len(ids), int((info["type"] != feature_type).sum()), feature_type))"#), scanpy)
        for (name, text) in [("seurat.R", seurat), ("scanpy.py", scanpy)] {
            let counted = try XCTUnwrap(text.range(of: "of them %d not"), "\(name) prints the count")
            let object = try XCTUnwrap(text.range(of: name == "seurat.R" ? "CreateSeuratObject(" : "sc.AnnData("), "\(name) makes its object")
            XCTAssertTrue(counted.lowerBound < object.lowerBound, "\(name) prints the count before it needs Seurat or Scanpy")
        }
    }
}
