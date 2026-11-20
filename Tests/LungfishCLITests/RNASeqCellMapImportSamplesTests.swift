// RNASeqCellMapImportSamplesTests.swift - The import on a result of two samples, a copy changed after the check and the Choices words no other suite reaches (Phase 5.5 lane CM-IMPORT, BIO SF2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The first cell of each sample, the counts for each sample and the suffix rule for each sample are the import's own and are not
// shared with pseudobulk, and a result of one sample cannot tell them from totals. These tests run them on a result of two
// samples that hold one barcode list twice, so a barcode matched in the wrong sample, or a cell counted from the wrong first
// cell, shows as a wrong coordinate or label. The suite also pins the refusal of a given file that changed between the check and
// the write, and the forms of the record's `Choices` and of the parent's refusal that the other suites leave out. Every test
// pins the import as it stands.

import ArgumentParser
import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishWorkflow

final class RNASeqCellMapImportSamplesTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-cell-map-samples") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    private func output(_ name: String = "map") -> URL { root.appendingPathComponent("Analyses/\(name).lungfishrnaseq", isDirectory: true) }

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent("given", isDirectory: true).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func options(_ coordinates: [URL], clusters: [URL] = [], parent: URL, labels: [String] = [],
                         suffix: RNASeqCellMapImport.BarcodeSuffix? = nil) -> RNASeqCellMapImport.Options {
        .init(parent: parent, coordinates: coordinates, clusters: clusters, labelColumns: labels, barcodeSuffix: suffix)
    }

    /// Checks, runs `between`, then writes `options`, which must be refused in `words` (as `expected`, when given), and leaves no
    /// folder and no stage beside the output.
    private func refuse(_ options: RNASeqCellMapImport.Options, between: () throws -> Void = {}, expected: RNASeqCellMapImportRefusal? = nil,
                        _ words: String, file: StaticString = #filePath, line: UInt = #line) {
        let target = output()
        do {
            let checked = try RNASeqCellMapImport.check(options, output: target)
            try between()
            try RNASeqCellMapImport.write(checked, to: target, writer: CellMapFixtureWriter.writer) { _ in
                ProvenanceEnvelope(workflowName: "RNA-seq cell map import", toolName: "lungfish-cli", toolVersion: "test")
            }
            XCTFail("the import was not refused", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, words, file: file, line: line)
            if let expected { XCTAssertEqual(error as? RNASeqCellMapImportRefusal, expected, file: file, line: line) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "a folder is left", file: file, line: line)
        let left = (try? FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)) ?? []
        XCTAssertEqual(left.filter { $0.hasPrefix(".") }, [], "a stage is left", file: file, line: line)
    }

    /// The 200 barcodes of the STARsolo cut, bare, in cell order.
    private func barcodes() throws -> [String] {
        try CellMapImportFixture.rows(CellMapImportFixture.projection).map { String($0[0].dropLast(2)) }
    }

    private func sampleNames(_ result: URL) throws -> [String] {
        try RNASeqCellsDatabase(url: result.appendingPathComponent(RNASeqCellsDatabase.filename)).samples().map(\.name)
    }

    /// A result of the STARsolo cut twice, as the samples cov_10 and cov_11 (copied from `RNASeqCellMapHandBackConformanceTests`).
    private func twoSamples() throws -> URL {
        let runs = root.appendingPathComponent("runs", isDirectory: true)
        try FileManager.default.createDirectory(at: runs, withIntermediateDirectories: true)
        let reads = try ["cov_10", "cov_11"].map { name in
            let copy = runs.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.copyItem(at: RNASeqFixtures.root.appendingPathComponent(CellMapImportFixture.starsolo, isDirectory: true), to: copy)
            return try SingleCellFolderReader.read(folder: copy)
        }
        let samples = reads.enumerated().map { RNASeqSampleRecord(id: $1.sample, animal: "A\($0 + 1)", species: "Homo sapiens", runs: [$1.sample]) }
        let request = try SingleCellFolderReader.request(reads, name: "two", samples: samples, genomes: [])
        let analyses = root.appendingPathComponent("Analyses", isDirectory: true)
        try FileManager.default.createDirectory(at: analyses, withIntermediateDirectories: true)
        let envelope = ProvenanceEnvelope(workflowName: "RNA-seq import", toolName: "lungfish-cli", toolVersion: "test")
        return try RNASeqResultWriter(provenanceWriter: ProvenanceWriter(signingProvider: nil))
            .write(request, to: analyses.appendingPathComponent("two.lungfishrnaseq", isDirectory: true), envelope: envelope)
    }

    // MARK: - A result of two samples

    /// The label of the barcode in place `i` from 1: sample A (1) has three labels and sample B (2) has two.
    private static func label(sample: Int, _ i: Int) -> String { sample == 1 ? "A\(i % 3)" : "B\(i % 2)" }

    private func line(_ sample: String, _ barcode: String, _ x: Int, label: String) -> String { "\(sample)\t\(barcode)\t\(x)\t0\t\(label)\n" }

    /// The lines of LGE's table for both samples, sample B first so that the line order is not the cell order. The barcode in
    /// place `i` is at (i, 0) in sample A and at (1000 + i, 0) in sample B, and `suffixB` follows each barcode of sample B.
    private func lines(_ names: [String], _ barcodes: [String], suffixB: String = "") -> [String] {
        let b = barcodes.enumerated().map { line(names[1], $1 + suffixB, 1000 + $0 + 1, label: Self.label(sample: 2, $0 + 1)) }
        let a = barcodes.enumerated().map { line(names[0], $1, $0 + 1, label: Self.label(sample: 1, $0 + 1)) }
        return b + a
    }

    private let header = "sample\tbarcode\tumap_1\tumap_2\tleiden\n"

    /// Every cell of `map` holds the coordinates and the label of its own line by sample and barcode, read through the map's
    /// SQLite reader, and the cells of `left` hold none. The parent holds the one list twice, so cell `c` of 1 to 200 is
    /// sample A and cell `200 + c` is sample B with the same barcode.
    private func assertCells(_ map: RNASeqCellMapDatabase, names: [String], barcodes: [String], left: Set<Int>,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let (x, y) = try map.coordinates(embedding: 1)
        let set = try XCTUnwrap(try map.labelSets().first, file: file, line: line)
        let labels = try map.cellLabels(labelSet: set.labelSet)
        let sampleOf = Dictionary(uniqueKeysWithValues: try map.samples().map { ($0.sample, $0.name) })
        let place = Dictionary(uniqueKeysWithValues: barcodes.enumerated().map { ($1, $0 + 1) })
        XCTAssertEqual(x.count, 400, file: file, line: line)
        for id in 1...400 {
            let cell = try XCTUnwrap(try map.cell(id: id), "cell \(id)", file: file, line: line)
            let name = try XCTUnwrap(sampleOf[cell.sample], "cell \(id)", file: file, line: line)
            XCTAssertEqual(cell.barcode, barcodes[(id - 1) % 200], "cell \(id)", file: file, line: line)
            XCTAssertEqual(name, names[(id - 1) / 200], "cell \(id)", file: file, line: line)
            let labelID = Int(labels[id - 1])
            if left.contains(id) {
                XCTAssertTrue(x[id - 1].isNaN && y[id - 1].isNaN, "cell \(id) is left out", file: file, line: line)
                XCTAssertEqual(labelID, 0, "cell \(id) has no label", file: file, line: line)
                continue
            }
            let i = try XCTUnwrap(place[cell.barcode], "cell \(id)", file: file, line: line)
            let isB = name == names[1]
            XCTAssertEqual(x[id - 1], Float(isB ? 1000 + i : i), "cell \(id)", file: file, line: line)
            XCTAssertEqual(y[id - 1], 0, "cell \(id)", file: file, line: line)
            XCTAssertTrue(labelID >= 1 && labelID <= set.labels.count, "cell \(id) has a label", file: file, line: line)
            if labelID >= 1 && labelID <= set.labels.count {
                XCTAssertEqual(set.labels[labelID - 1].name, Self.label(sample: isB ? 2 : 1, i), "cell \(id)", file: file, line: line)
            }
        }
        for count in set.counts {
            XCTAssertEqual(set.labels[count.label - 1].name.hasPrefix("A"), count.sample == 1, "label \(count.label) of sample \(count.sample)", file: file, line: line)
        }
        XCTAssertEqual([1, 2].map { sample in set.counts.filter { $0.sample == sample }.map(\.cells).reduce(0, +) },
                       set.samples.map(\.labelled), file: file, line: line)
    }

    func testAResultOfTwoSamplesMatchesEachCellBySampleAndBarcode() async throws {
        let result = try twoSamples()
        let names = try sampleNames(result)
        let barcodes = try barcodes()
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(barcodes.count, 200)

        let both = try file("both.tsv", header + lines(names, barcodes).joined())
        let first = output("both")
        try await RNASeqCellMapImportSubcommand.parse([result.path, "--coordinates", both.path, "--label-column", "leiden",
                                                       "--output", first.path, "--quiet"]).run()
        let map = try RNASeqCellMapDatabase(url: first.appendingPathComponent("cellmap.sqlite"))
        XCTAssertEqual(try map.embeddingCells().map { [$0.drawn, $0.leftOut] }, [[200, 0], [200, 0]])
        XCTAssertEqual(try map.labelSets().first?.samples.map { [$0.labelled, $0.unlabelled] }, [[200, 0], [200, 0]])
        try assertCells(map, names: names, barcodes: barcodes, left: [])

        // Sample B's first 3 lines dropped: B leaves out 3 cells (201 to 203) and A none, in the map and in the check's counts.
        let fewer = try file("fewer.tsv", header + lines(names, barcodes).dropFirst(3).joined())
        let checked = try RNASeqCellMapImport.check(options([fewer], parent: result, labels: ["leiden"]), output: output("probe"))
        XCTAssertEqual(checked.files[0].matched, [200, 197])
        XCTAssertEqual(checked.files[0].notHeld, [0, 0])
        let second = output("fewer")
        try await RNASeqCellMapImportSubcommand.parse([result.path, "--coordinates", fewer.path, "--label-column", "leiden",
                                                       "--output", second.path, "--quiet"]).run()
        let fewerMap = try RNASeqCellMapDatabase(url: second.appendingPathComponent("cellmap.sqlite"))
        XCTAssertEqual(try fewerMap.embeddingCells().map { [$0.drawn, $0.leftOut] }, [[200, 0], [197, 3]])
        XCTAssertEqual(try fewerMap.labelSets().first?.samples.map { [$0.labelled, $0.unlabelled] }, [[200, 0], [197, 3]])
        try assertCells(fewerMap, names: names, barcodes: barcodes, left: [201, 202, 203])

        // Sample B's barcodes given with -1 and no flag: the rule is checked for each sample, so only B is refused.
        let suffixed = try file("suffixed.tsv", header + lines(names, barcodes, suffixB: "-1").joined())
        refuse(options([suffixed], parent: result, labels: ["leiden"]),
               "No barcode of suffixed.tsv matches sample \(names[1]) as given, and 200 of its 200 barcodes would match with -1 dropped. "
               + "LGE changes no barcode unless asked. To drop -1 from every given barcode, run again with --barcode-suffix drop.")

        // 10x's files name no sample, and a table with no sample column cannot name one either.
        refuse(options([CellMapImportFixture.projection], parent: result),
               "projection.csv is one of 10x's files, which name no sample, and the result holds 2 samples. "
               + "Give 10x's files for a result of one sample, or write LGE's table with a sample column.")
        let bare = try file("no-sample.tsv", "barcode\tumap_1\tumap_2\n" + barcodes.map { "\($0)\t1\t2\n" }.joined())
        refuse(options([bare], parent: result),
               "The result holds 2 samples and no-sample.tsv has no sample column, so a barcode cannot name its sample. "
               + "Add a sample column that holds the sample ids of samples.tsv.")
    }

    // MARK: - A copy that changed after the check

    func testACopyThatChangedAfterTheCheckIsRefused() throws {
        let cellRanger = try CellMapImportFixture.result(CellMapImportFixture.cellRanger, name: "tenx", in: root)
        let given = try file("projection.csv", try String(contentsOf: CellMapImportFixture.projection, encoding: .utf8))
        refuse(options([given], parent: cellRanger), between: {
            let handle = try FileHandle(forWritingTo: given)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("AAACCTGAGAAACCTA-1,1.5,-2.5\n".utf8))
        }, expected: .changedWhileRead(file: "projection.csv"),
               "projection.csv changed while LGE read it, so the copy kept under source/ is not the file that was checked. "
               + "Run the import again once the file no longer changes.")
    }

    // MARK: - The Choices forms and the parent that no other suite reaches

    func testAddingMinusOneToBareBarcodesIsRecordedAsMinusOneAdded() async throws {
        let cellRanger = try CellMapImportFixture.result(CellMapImportFixture.cellRanger, name: "tenx", in: root)
        let table = try file("bare.tsv", "barcode\tumap_1\tumap_2\n" + barcodes().enumerated().map { "\($1)\t\($0 + 1)\t0\n" }.joined())
        let map = output("added")
        try await RNASeqCellMapImportSubcommand.parse([cellRanger.path, "--coordinates", table.path, "--barcode-suffix", "add",
                                                       "--output", map.path, "--quiet"]).run()
        XCTAssertEqual(try CellMapImportFixture.facts(map)["choices"], .dictionary([
            "barcodeSuffix": .string("-1 added"), "barcodesNotHeld": .string("refused"), "counts": .string("not checked")]))
        XCTAssertEqual(try RNASeqCellMapDatabase(url: map.appendingPathComponent("cellmap.sqlite")).embeddingCells().map { [$0.drawn, $0.leftOut] }, [[200, 0]])
    }

    func testAnLGETableGivenWithTenXsClustersIsCheckedAgainstTheParentForTenXsFilesOnly() async throws {
        let cellRanger = try CellMapImportFixture.result(CellMapImportFixture.cellRanger, name: "tenx", in: root)
        let rows = try CellMapImportFixture.rows(CellMapImportFixture.projection).map { "\($0[0])\t\($0[1])\t\($0[2])\n" }.joined()
        let table = try file("lge-cell-map.tsv", "barcode\tumap_1\tumap_2\n" + rows)
        let map = output("mixed")
        try await RNASeqCellMapImportSubcommand.parse([cellRanger.path, "--coordinates", table.path, "--clusters", CellMapImportFixture.clusters.path,
                                                       "--output", map.path, "--quiet"]).run()
        XCTAssertEqual(try CellMapImportFixture.facts(map)["choices"], .dictionary([
            "barcodeSuffix": .string("as given"), "barcodesNotHeld": .string("refused"),
            "counts": .string("the parent's for 10x's files, not checked for LGE's table")]))
        let database = try RNASeqCellMapDatabase(url: map.appendingPathComponent("cellmap.sqlite"))
        XCTAssertEqual(try database.embeddingCells().map { [$0.drawn, $0.leftOut] }, [[200, 0]])
        XCTAssertEqual(try database.labelSets().first?.samples.map { [$0.labelled, $0.unlabelled] }, [[200, 0]])
    }

    func testACellMapAsTheParentIsRefused() async throws {
        let cellRanger = try CellMapImportFixture.result(CellMapImportFixture.cellRanger, name: "tenx", in: root)
        let first = output("first")
        try await RNASeqCellMapImportSubcommand.parse([cellRanger.path, "--coordinates", CellMapImportFixture.projection.path,
                                                       "--output", first.path, "--quiet"]).run()
        refuse(options([CellMapImportFixture.projection], parent: first),
               "first is a cell map. rnaseq cell-map import reads a single-cell result, "
               + "such as one that import rnaseq made from Cell Ranger or STARsolo folders.")
    }
}
