// RNASeqPseudobulkTests+Refusals.swift - Two samples and each refusal of the pseudobulk pass in its words (RS-PSEUDOBULK)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

extension RNASeqPseudobulkTests {
    /// The barcodes and labels of the fixture's STARsolo table, in its order.
    private func fixtureRows() throws -> [(barcode: String, label: String)] {
        let text = try String(contentsOf: Self.fixture.appendingPathComponent("labels-starsolo.tsv"), encoding: .utf8)
        return text.split(separator: "\n").dropFirst().map { line in
            let cells = line.split(separator: "\t").map(String.init)
            return (cells[0], cells[1])
        }
    }

    private func twoSamples(_ names: [String] = ["donorA", "donorB"]) throws -> URL {
        try Self.singleCellResult(try names.map { try Self.starsoloCopy($0, in: root) }, name: "two", in: root)
    }

    func testTwoSamplesSumByTheSampleColumnAndCarryEachAnimal() throws {
        let rows = try fixtureRows()
        let text = "sample\tbarcode\tlabel\n" + ["donorA", "donorB"].flatMap { sample in rows.map { "\(sample)\t\($0.barcode)\t\($0.label)\n" } }.joined()
        let outcome = try sum(try twoSamples(), try table(text))
        XCTAssertEqual(outcome.kept.map(\.column), ["donorA_B", "donorA_T", "donorA_ten", "donorB_B", "donorB_T", "donorB_ten"])
        XCTAssertEqual(outcome.request.samples.map(\.animal), ["A1", "A1", "A1", "A2", "A2", "A2"])
        XCTAssertEqual(outcome.dropped.map(\.column), ["donorA_nine", "donorB_nine"])
        let total = outcome.kept.reduce(0) { $0 + $1.umis } + outcome.dropped.reduce(0) { $0 + $1.umis }
            + outcome.unlabelled.reduce(0) { $0 + $1.umis }
        XCTAssertEqual(total, 2 * 212_629)
    }

    func testABulkResultIsRefused() throws {
        let request = RNASeqResultWriter.Request(
            name: "bulk", modality: .bulk, origin: .init(kind: .imported), route: .init(id: "r", tool: "t", toolVersion: "1", settings: [:]),
            referenceSet: nil, samples: [RNASeqSampleRecord(id: "S1")], genes: .ids(["G1"]),
            counts: [.init(rows: .gene, column: .default, unit: .reads, table: RNASeqCountTable(sampleIDs: ["S1"], rows: [.init(id: "G1", counts: [3])]))],
            sourceFiles: [], notHost: [])
        let url = root.appendingPathComponent("bulk.lungfishrnaseq", isDirectory: true)
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test")
        try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil)).write(request, to: url, envelope: envelope)
        XCTAssertEqual(refusal(url, try table("barcode\tlabel\nA\tT\n")),
                       "bulk is a bulk result. rnaseq pseudobulk sums the cells of a single-cell result, such as one that import rnaseq made from Cell Ranger or STARsolo folders.")
    }

    func testAChangedFileOfTheResultIsRefused() throws {
        let result = try Self.singleCellResult([Self.starsolo], name: "solo", in: root)
        let samples = result.appendingPathComponent("samples.tsv")
        try (try Data(contentsOf: samples) + Data("x\n".utf8)).write(to: samples)
        XCTAssertEqual(refusal(result, Self.fixture.appendingPathComponent("labels-starsolo.tsv")),
                       "The file samples.tsv of solo differs from the sha256 that its manifest lists, so the result changed after LGE wrote it. "
                        + "Import the tool's folders again into a new result.")
    }

    func testEachRefusalOfTheTableHasItsWords() throws {
        let solo = try Self.singleCellResult([Self.starsolo], name: "solo", in: root)
        let rows = try fixtureRows()
        let b0 = rows[0].barcode
        let b1 = rows[1].barcode
        XCTAssertEqual(refusal(solo, try table("barcode\tcluster\n\(b0)\tT\n")),
                       "labels.tsv has no label column. Its header needs barcode and label, and sample when the result holds two or more samples.")
        XCTAssertEqual(refusal(solo, try table("barcode\tlabel\n\(b0)\n")),
                       "Line 2 of labels.tsv has 1 column and the header has 2. Give each line one cell for each column of the header.")
        XCTAssertEqual(refusal(solo, try table("barcode\tlabel\n\(b0)\tT\n\(b1)\t\n")),
                       "Line 3 of labels.tsv has an empty label. Give the cell a label, or leave its line out so the cell has none.")
        XCTAssertEqual(refusal(solo, try table("barcode\tlabel\n\(b0)\tT\n\(b1)\tT\n\(b0)\tB\n")),
                       "Line 4 of labels.tsv lists the barcode \(b0) of sample starsolo-pbmc_1k_v3 again, after line 2. List each cell once.")
        let stray = (1...12).map { String(format: "XXXX%06d", $0) }
        XCTAssertEqual(refusal(solo, try table("barcode\tlabel\n" + (rows.map(\.barcode) + stray).map { "\($0)\tT\n" }.joined())),
                       "labels.tsv lists 12 barcodes that the result does not hold, such as \(stray.prefix(10).joined(separator: ", ")). "
                        + "Barcodes match as given, so a STARsolo barcode is bare and a 10x barcode ends in -1.")
        XCTAssertEqual(refusal(solo, try table("barcode\tlabel\n" + rows.prefix(9).map { "\($0.barcode)\tnine\n" }.joined())),
                       "No group of labels.tsv holds 10 or more cells, so there is no column to write. A group is one sample and one label.")
    }

    func testABarcodeMatchesAsGivenSoBareBarcodesAreNotTenXCells() throws {
        let tenx = try Self.singleCellResult([Self.cellRanger], name: "tenx", in: root)
        let words = refusal(tenx, Self.fixture.appendingPathComponent("labels-starsolo.tsv"))
        XCTAssertTrue(words?.hasPrefix("labels-starsolo.tsv lists 170 barcodes that the result does not hold, such as ") == true, words ?? "")
    }

    func testTheRefusalsOfTwoSamplesHaveTheirWords() throws {
        let two = try twoSamples()
        let b0 = try fixtureRows()[0].barcode
        XCTAssertEqual(refusal(two, try table("barcode\tlabel\n\(b0)\tT\n")),
                       "The result holds 2 samples and labels.tsv has no sample column, so a barcode cannot name its sample. "
                        + "Add a sample column that holds the sample ids of samples.tsv.")
        XCTAssertEqual(refusal(two, try table("sample\tbarcode\tlabel\ndonorA\t\(b0)\tT\ndonorC\t\(b0)\tT\n")),
                       "Line 3 of labels.tsv names the sample donorC, which the result does not hold. Its samples are donorA and donorB.")
        let clash = try Self.singleCellResult(try ["A_1", "A"].map { try Self.starsoloCopy($0, in: root) }, name: "clash", in: root)
        XCTAssertEqual(refusal(clash, try table("sample\tbarcode\tlabel\nA_1\t\(b0)\tT\nA\t\(b0)\t1_T\n")),
                       "The groups A_1 T and A 1_T would both be the column A_1_T. Rename a label so that each sample and label gives its own column.")
    }

    func testTheOutputMustBeANewResultFolderInAFolderThatExists() throws {
        let existing = root.appendingPathComponent("old.lungfishrnaseq", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        func words(_ url: URL) -> String? {
            do { try RNASeqPseudobulk.checkOutput(url); return nil } catch { return (error as? LocalizedError)?.errorDescription }
        }
        XCTAssertEqual(words(existing), "\(existing.path) already exists. Choose a new name for the result.")
        XCTAssertEqual(words(root.appendingPathComponent("pb")),
                       "--output names a new folder whose name ends in .lungfishrnaseq, such as pbmc-pseudobulk.lungfishrnaseq, and not pb.")
        let away = root.appendingPathComponent("missing/pb.lungfishrnaseq")
        XCTAssertEqual(words(away), "No folder at \(away.deletingLastPathComponent().path) to write the result in. Create it or choose another output.")
        XCTAssertNil(words(root.appendingPathComponent("new.lungfishrnaseq")))
    }

    /// The rows are the `Gene Expression` features only, and the record counts each other type (docs/formats/rnaseq-bundle.md,
    /// Pseudobulk). Both cuts hold `Gene Expression` alone, so this folder adds an antibody feature of 50 UMIs a cell
    /// (review RS-PSEUDOBULK BIO, fix SF1).
    func testAFeatureOfAnotherTypeStaysOutOfTheTableAndTheRecordCountsIt() throws {
        let outs = root.appendingPathComponent("adt/outs", isDirectory: true)
        let folder = outs.appendingPathComponent("filtered_feature_bc_matrix", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let barcodes = (1...10).map { String(format: "AAAC%04d-1", $0) }
        let entries = (1...10).flatMap { ["1 \($0) 2", "2 \($0) 50", "3 \($0) 3"] }
        let matrix = (["%%MatrixMarket matrix coordinate integer general", "%", "3 10 30"] + entries).joined(separator: "\n") + "\n"
        try Data(matrix.utf8).write(to: folder.appendingPathComponent("matrix.mtx"))
        try Data("G1\tG1\tGene Expression\nADT1\tCD3\tAntibody Capture\nG2\tG2\tGene Expression\n".utf8)
            .write(to: folder.appendingPathComponent("features.tsv"))
        try Data((barcodes.joined(separator: "\n") + "\n").utf8).write(to: folder.appendingPathComponent("barcodes.tsv"))
        let result = try Self.singleCellResult([outs], name: "adt", in: root)
        let outcome = try sum(result, try table("barcode\tlabel\n" + barcodes.map { "\($0)\tT\n" }.joined()))
        XCTAssertEqual(outcome.request.counts[0].table.rows.map(\.id), ["G1", "G2"])
        XCTAssertEqual(outcome.request.counts[0].table.rows.map(\.counts), [[20], [30]])
        XCTAssertEqual(outcome.kept.map(\.umis), [50], "the antibody's 500 UMIs stay out")
        XCTAssertEqual(outcome.facts["geneExpressionFeatures"], .integer(2))
        XCTAssertEqual(outcome.facts["featureTypesLeftOut"], .dictionary(["Antibody Capture": .integer(1)]))
    }
}
