// RNASeqCellMapImportRefusalTests.swift - Each refusal of rnaseq cell-map import in its words (Phase 5.5 lane CM-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The words are those of `docs/formats/rnaseq-cell-map.md`, What the import refuses. Every refusal of 5.5 I2 and I3 has
// its test, and each refusal leaves no folder and no stage beside the output. The record's `Choices` words of each form
// are pinned here too, with the cells left out counted for each sample.

import ArgumentParser
import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

final class RNASeqCellMapImportRefusalTests: XCTestCase {
    private var root: URL!
    private var starsolo: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "rnaseq-cell-map-refusal")
        starsolo = try CellMapImportFixture.result(CellMapImportFixture.starsolo, in: root)
    }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    private var output: URL { root.appendingPathComponent("Analyses/map.lungfishrnaseq", isDirectory: true) }
    private let projection = CellMapImportFixture.projection
    private let clusters = CellMapImportFixture.clusters

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent("given", isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The 200 barcodes of the STARsolo cut, bare, in cell order.
    private func barcodes() throws -> [String] {
        try CellMapImportFixture.rows(projection).map { String($0[0].dropLast(2)) }
    }

    /// Checks then writes `options`, which must be refused in `words`, and leaves nothing beside the output.
    private func refuse(_ options: RNASeqCellMapImport.Options, output: URL? = nil, _ words: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = output ?? self.output
        let existed = FileManager.default.fileExists(atPath: target.path)
        XCTAssertThrowsError(try {
            let checked = try RNASeqCellMapImport.check(options, output: target)
            try RNASeqCellMapImport.write(checked, to: target, writer: CellMapFixtureWriter.writer) { _ in
                ProvenanceEnvelope(workflowName: "RNA-seq cell map import", toolName: "lungfish-cli", toolVersion: "test")
            }
        }(), file: file, line: line) { error in
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, words, file: file, line: line)
        }
        XCTAssertEqual(FileManager.default.fileExists(atPath: target.path), existed, file: file, line: line)
        let folder = target.deletingLastPathComponent()
        let left = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        XCTAssertEqual(left.filter { $0.hasPrefix(".") }, [], "a stage is left", file: file, line: line)
    }

    private func options(_ coordinates: [URL], clusters: [URL] = [], parent: URL? = nil, labels: [String] = [], methods: [String] = [],
                         suffix: RNASeqCellMapImport.BarcodeSuffix? = nil, skip: Bool = false, other: Bool = false) -> RNASeqCellMapImport.Options {
        .init(parent: parent ?? starsolo, coordinates: coordinates, clusters: clusters, labelColumns: labels, methods: methods,
              barcodeSuffix: suffix, skipBarcodesNotHeld: skip, otherCounts: other)
    }

    // MARK: - 5.5 I2, the suffix rule

    func testTheSuffixRuleRefusesBarcodesThatWouldMatchWithMinusOneDropped() {
        refuse(options([projection], clusters: [clusters]),
               "No barcode of projection.csv matches sample starsolo-pbmc_1k_v3 as given, and 200 of its 200 barcodes would match with -1 dropped. "
               + "LGE changes no barcode unless asked. To drop -1 from every given barcode, run again with --barcode-suffix drop.")
    }

    func testTheSuffixRuleRefusesBarcodesThatWouldMatchWithMinusOneAdded() throws {
        let cellRanger = try CellMapImportFixture.result(CellMapImportFixture.cellRanger, name: "tenx", in: root)
        let rows = try barcodes().prefix(3).enumerated().map { "\($1)\t\($0).5\t-\($0)\n" }
        let table = try file("lge-cell-map.tsv", "barcode\tumap_1\tumap_2\n" + rows.joined())
        refuse(options([table], parent: cellRanger),
               "No barcode of lge-cell-map.tsv matches sample \(try sampleName(cellRanger)) as given, and 3 of its 3 barcodes would match with -1 added. "
               + "LGE changes no barcode unless asked. To add -1 to every given barcode, run again with --barcode-suffix add.")
    }

    func testABarcodeThatTheSuffixFlagMakesEqualToAnotherIsRefusedWithTheFlagNamed() throws {
        let first = try barcodes()[0]
        let table = try file("twice.tsv", "barcode\tumap_1\tumap_2\n\(first)\t1\t2\n\(first)-1\t3\t4\n")
        refuse(options([table], suffix: .drop, other: true),
               "Line 3 of twice.tsv lists the barcode \(first)-1 once -1 is dropped of sample starsolo-pbmc_1k_v3 again, after line 2. List each cell once.")
    }

    // MARK: - 5.5 I3, barcodes not held, cells left out and other counts

    func testBarcodesNotHeldAreRefusedWithTheirCountAndTheFirstTen() throws {
        let extra = (1...12).map { String(format: "AAAAAAAAAAAA%04d-1,0.5,0.5\n", $0) }
        let text = try String(contentsOf: projection, encoding: .utf8) + extra.joined()
        let given = try file("projection.csv", text)
        let first = (1...10).map { String(format: "AAAAAAAAAAAA%04d-1", $0) }.joined(separator: ", ")
        refuse(options([given], suffix: .drop, other: true),
               "projection.csv lists 12 barcodes that the result does not hold, such as \(first). Barcodes match as given unless --barcode-suffix "
               + "changed them, so a STARsolo barcode is bare and a 10x barcode ends in -1. To leave them out and import the rest, run again with "
               + "--skip-barcodes-not-held, and the record counts them.")
        let map = root.appendingPathComponent("Analyses/kept.lungfishrnaseq", isDirectory: true)
        let checked = try RNASeqCellMapImport.check(options([given], suffix: .drop, skip: true, other: true), output: map)
        XCTAssertEqual(checked.files[0].notHeld, [12])
        XCTAssertEqual(checked.files[0].matched, [200])
        XCTAssertEqual(checked.files[0].firstNotHeld[0].count, 10)
        XCTAssertEqual(checked.choices.barcodesNotHeld, "left out")
    }

    func testCellsLeftOutOfAnEmbeddingAreCountedForEachSampleAndTheRecordSaysNotChecked() async throws {
        let rows = try barcodes().dropFirst(3).map { "starsolo-pbmc_1k_v3\t\($0)\t1.5\t-2\t\($0.hasPrefix("AAAC") ? "" : "x")\textra\n" }
        let table = try file("lge-cell-map.tsv", "sample\tbarcode\tumap_1\tumap_2\tleiden\tnote\n" + rows.joined())
        try await RNASeqCellMapImportSubcommand.parse([starsolo.path, "--coordinates", table.path, "--label-column", "leiden",
                                                       "--output", output.path, "--quiet"]).run()
        let database = try RNASeqCellMapDatabase(url: output.appendingPathComponent("cellmap.sqlite"))
        XCTAssertEqual(try database.embeddingCells().map { [$0.drawn, $0.leftOut] }, [[197, 3]])
        let facts = try CellMapImportFixture.facts(output)
        XCTAssertEqual(facts["choices"], .dictionary(["barcodeSuffix": .string("as given"), "barcodesNotHeld": .string("refused"),
                                                      "counts": .string("not checked")]))
        guard case .array(let files)? = facts["givenFiles"], case .dictionary(let given)? = files.first else { return XCTFail("no given file") }
        XCTAssertEqual(given["columnsReadPast"], .array([.string("note")]))
        XCTAssertEqual(given["form"], .string("LGE's table"))
        XCTAssertNil(try RNASeqResultBundle.loadManifest(from: output).origin.tool)
    }

    func testTenXFilesOnAnotherRouteNeedOtherCounts() {
        refuse(options([projection], clusters: [clusters], suffix: .drop),
               "projection.csv is 10x's analysis of Cell Ranger's counts, and cells holds the counts of STARsolo. To import it all the same, "
               + "run again with --other-counts, and the record and the view then say computed on other counts.")
    }

    // MARK: - The files and their names

    func testAnEmptyClusterIsRefusedWithItsFileAndLine() throws {
        var lines = try String(contentsOf: clusters, encoding: .utf8).split(separator: "\n").map(String.init)
        lines[5] = String(lines[5].prefix { $0 != "," }) + ","
        let given = try file("graphclust/clusters.csv", lines.joined(separator: "\n") + "\n")
        refuse(options([projection], clusters: [given], suffix: .drop, other: true),
               "Line 6 of clusters.csv has an empty label. Give the cell a label, or leave its line out so the cell has none.")
    }

    func testTheFormsAndColumnsThatAreRefused() throws {
        let first = try barcodes()[0]
        refuse(options([try file("odd.csv", "cell,x,y\n\(first),1,2\n")]),
               "odd.csv is not LGE's table or one of 10x's files. LGE's table has a barcode column, and 10x's files start Barcode,TSNE-1,TSNE-2 or Barcode,Cluster.")
        refuse(options([try file("one.tsv", "barcode\tumap_1\tumap_2\tleiden_1\n\(first)\t1\t2\t3\n")]),
               "one.tsv gives the embedding leiden only the column leiden_1. An embedding needs leiden_1 and leiden_2 at least. Name a column of labels with --label-column.")
        refuse(options([try file("gap.tsv", "barcode\tumap_1\tumap_3\n\(first)\t1\t2\n")]),
               "gap.tsv gives umap_3 and no umap_2. Number the columns of an embedding from 1 with no gap.")
        refuse(options([try file("labels.tsv", "barcode\tumap_1\tumap_2\n\(first)\t1\t2\n")], labels: ["leiden"]),
               "labels.tsv has no column leiden, which --label-column names.")
        refuse(options([try file("nan.tsv", "barcode\tumap_1\tumap_2\n\(first)\tnan\t2\n")]),
               "Line 2 of nan.tsv gives nan in umap_1, which is not a finite decimal number. Give a number such as -12.5 or 3.2e-2.")
        refuse(options([try file("only-labels.tsv", "barcode\tleiden\n\(first)\t1\n")], labels: ["leiden"]),
               "No given file holds an embedding. Give LGE's table with columns such as umap_1 and umap_2, or one of 10x's projection.csv files.")
        refuse(options([try file("m.tsv", "barcode\tumap_1\tumap_2\n\(first)\t1\t2\n")], methods: ["tsne=t-SNE"]),
               "--method names the embedding tsne, which no given file holds. The embeddings are umap.")
        let twice = try file("b.tsv", "barcode\tTSNE_1\tTSNE_2\n\(first)\t1\t2\n")
        refuse(options([projection, twice], suffix: .drop, other: true),
               "The embedding TSNE comes from both projection.csv and b.tsv. Give each embedding its own name.")
        refuse(options([try file("q.csv", "Barcode,UMAP-1,UMAP-2\n\"\(first)-1\",1,2\n")], suffix: .drop, other: true),
               "Line 2 of q.csv holds a quote, and 10x's files hold none. Give the file as Cell Ranger wrote it.")
    }

    func testAGzipStreamThatEndsEarlyCannotBeRead() throws {
        let url = root.appendingPathComponent("given/short.tsv.gz")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x4b, 0x4a]).write(to: url)
        XCTAssertThrowsError(try RNASeqCellMapImport.check(options([url]), output: output)) { error in
            guard case .unreadable(let file, _)? = error as? RNASeqCellMapImportRefusal else { return XCTFail("\(error)") }
            XCTAssertEqual(file, "short.tsv.gz")
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.hasPrefix("short.tsv.gz cannot be read as text, ") == true)
        }
    }

    // MARK: - The notes of the command

    /// The notes that `rnaseq cell-map import` prints for `arguments`, in order, with the cell map written to `Analyses/<name>`.
    private func notes(_ name: String, _ arguments: [String]) throws -> [String] {
        var printed: [String] = []
        let target = root.appendingPathComponent("Analyses/\(name).lungfishrnaseq", isDirectory: true)
        _ = try RNASeqCellMapImportSubcommand.parse(arguments + ["--output", target.path, "--quiet"]).write { printed.append($0) }
        return printed
    }

    func testTheNotesCountBarcodesNotHeldWithTheirThousandsMarkedAndAgreeInNumber() throws {
        let text = try String(contentsOf: projection, encoding: .utf8)
        func extra(_ count: Int) -> String { (1...count).map { String(format: "AAAAAAAAAAAA%04d-1,0.5,0.5\n", $0) }.joined() }
        let flags = ["--barcode-suffix", "drop", "--skip-barcodes-not-held", "--other-counts"]
        let other = "The embeddings were computed on other counts than the result's."
        XCTAssertEqual(try notes("one", [starsolo.path, "--coordinates", try file("one/projection.csv", text + extra(1)).path] + flags),
                       ["1 of the 201 barcodes of projection.csv is not held by the result and was left out.", other])
        XCTAssertEqual(try notes("many", [starsolo.path, "--coordinates", try file("many/projection.csv", text + extra(1022)).path] + flags),
                       ["1,022 of the 1,222 barcodes of projection.csv are not held by the result and were left out.", other])
    }

    func testTheNotesCountCellsLeftOutAndAgreeInNumber() throws {
        let name = try sampleName(starsolo)
        let rows = try barcodes().map { "\($0)\t1.5\t-2\n" }
        func arguments(leaving left: Int, in path: String) throws -> [String] {
            [starsolo.path, "--coordinates", try file(path, "barcode\tumap_1\tumap_2\n" + rows.dropFirst(left).joined()).path]
        }
        XCTAssertEqual(try notes("one", try arguments(leaving: 1, in: "one/lge-cell-map.tsv")),
                       ["1 of the 200 cells of \(name) has no coordinates in umap and is not drawn."])
        XCTAssertEqual(try notes("three", try arguments(leaving: 3, in: "three/lge-cell-map.tsv")),
                       ["3 of the 200 cells of \(name) have no coordinates in umap and are not drawn."])
    }

    /// A sample of 1,224 cells needs no fixture of that size: the notes' words are the page's, with the refusals' thousands marks.
    func testTheNotesMarkTheThousandsAsTheRefusalsDoAndAgreeInNumber() {
        typealias Command = RNASeqCellMapImportSubcommand
        XCTAssertEqual(Command.notHeldNote(1, of: 1_222, file: "projection.csv"),
                       "1 of the 1,222 barcodes of projection.csv is not held by the result and was left out.")
        XCTAssertEqual(Command.notHeldNote(1_021, of: 1_222, file: "projection.csv"),
                       "1,021 of the 1,222 barcodes of projection.csv are not held by the result and were left out.")
        XCTAssertEqual(Command.notHeldNote(1, of: 1, file: "a.tsv"), "1 of the 1 barcode of a.tsv is not held by the result and was left out.")
        XCTAssertEqual(Command.leftOutNote(3, of: 1_224, sample: "pbmc_1k_v3", embedding: "TSNE"),
                       "3 of the 1,224 cells of pbmc_1k_v3 have no coordinates in TSNE and are not drawn.")
        XCTAssertEqual(Command.leftOutNote(1, of: 1_224, sample: "pbmc_1k_v3", embedding: "TSNE"),
                       "1 of the 1,224 cells of pbmc_1k_v3 has no coordinates in TSNE and is not drawn.")
        XCTAssertEqual(Command.leftOutNote(1_000, of: 1_224, sample: "pbmc_1k_v3", embedding: "TSNE"),
                       "1,000 of the 1,224 cells of pbmc_1k_v3 have no coordinates in TSNE and are not drawn.")
        XCTAssertEqual(RNASeqCellMapImportRefusal.count(1_222, "barcode"), "1,222 barcodes")
    }

    // MARK: - The output and the parent

    func testTheOutputAndTheParentAreCheckedFirst() throws {
        let inside = starsolo.appendingPathComponent("maps", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        refuse(options([projection]), output: inside.appendingPathComponent("map.lungfishrnaseq"),
               "--output names a folder inside the result cells.lungfishrnaseq. LGE never writes inside a result, so choose a folder beside it, "
               + "such as the project's Analyses folder.")
        try FileManager.default.removeItem(at: inside)
        let bulk = try RNASeqExportCommandTests.makeResult("bulk", samples: ["S1"], in: root)
        refuse(options([projection], parent: bulk), "bulk is a bulk result. rnaseq cell-map import reads a single-cell result, "
               + "such as one that import rnaseq made from Cell Ranger or STARsolo folders.")
        refuse(options([projection]), output: starsolo, "\(starsolo.path) already exists. Choose a new name for the result.")
    }

    private func sampleName(_ result: URL) throws -> String {
        try RNASeqCellsDatabase(url: result.appendingPathComponent(RNASeqCellsDatabase.filename)).samples()[0].name
    }
}

/// The writer of the refusal tests, which never signs.
enum CellMapFixtureWriter {
    static let writer = RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
}
