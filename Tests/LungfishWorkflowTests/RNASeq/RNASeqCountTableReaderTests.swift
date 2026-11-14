// RNASeqCountTableReaderTests.swift - A plain count table and the sample sheet (Phase 5.1 lane RS-BULK-IMPORT)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class RNASeqCountTableReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-count-table") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    private func write(_ text: String, _ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testTheC9TableReadsAsGiven() throws {
        let table = try RNASeqCountTableReader.read(RNASeqFixtures.umiCounts)
        XCTAssertEqual(table.sampleIDs.count, 33)
        XCTAssertEqual(table.sampleIDs.prefix(3), ["B1", "B2", "B3"])
        XCTAssertEqual(table.rows.count, 203)
        XCTAssertEqual(table.rows[1].id, "ENSG00000224315")
        XCTAssertEqual(table.rows[1].counts[6], 1)
    }

    func testARepeatedSampleOrFeatureIsRefused() throws {
        let samples = try write("gene_id\tB1\tB1\nG1\t1\t2\n", "samples.tsv")
        XCTAssertThrowsError(try RNASeqCountTableReader.read(samples)) { XCTAssertEqual($0 as? RNASeqImportError, .duplicateSample("B1")) }
        let features = try write("gene_id\tB1\nG1\t1\nG1\t2\n", "features.tsv")
        XCTAssertThrowsError(try RNASeqCountTableReader.read(features)) { XCTAssertEqual($0 as? RNASeqImportError, .duplicateFeature("G1")) }
        let words = try write("gene_id\tB1\nG1\tmany\n", "words.tsv")
        XCTAssertThrowsError(try RNASeqCountTableReader.read(words))
    }
}

final class RNASeqSampleSheetTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "rnaseq-sample-sheet") }
    override func tearDownWithError() throws { TestTempDirectory.cleanup(root) }

    private func sheet(_ text: String) throws -> RNASeqSampleSheet {
        let url = root.appendingPathComponent("sheet.tsv")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return try RNASeqSampleSheet.read(url)
    }

    func testSampleIDsThatDifferAreRefusedInWordsThatListBothSides() throws {
        let sheet = try sheet("sample\tanimal\tspecies\torigin\tgroup\nB1\tr01\tMacaca mulatta\tIndian\tA\nB2\tr02\tMacaca mulatta\tIndian\tB\nX9\tr09\tMacaca mulatta\tChinese\tB\n")
        XCTAssertThrowsError(try RNASeqSampleSheet.match(sheet, fileIDs: ["B1", "B2", "B3"], byRun: false)) { error in
            XCTAssertEqual(error as? RNASeqImportError, .sampleIDsDiffer(onlyInFiles: ["B3"], onlyInSheet: ["X9"]))
            XCTAssertEqual(
                error.localizedDescription,
                "The sample ids of the files and the sample sheet differ. Only in the files: B3. Only in the sheet: X9. "
                    + "Make the sheet's run or sample column name the same samples as the files, or leave out --samples.")
        }
    }

    /// Review SF3 (UX 1): a sheet written with commas says what a sample sheet is, so the person knows what to fix.
    func testASheetWithNoSampleColumnSaysItIsTabSeparated() throws {
        let url = root.appendingPathComponent("sheet.csv")
        try "sample,species\nB1,x\n".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try RNASeqSampleSheet.read(url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("tab-separated"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("sheet.csv"), error.localizedDescription)
        }
    }

    func testTheSheetGivesEachSampleItsAnimalSpeciesOriginAndGroup() throws {
        let sheet = try sheet("sample\tanimal\tspecies\torigin\tgroup\nB2\tr02\tMacaca mulatta\tIndian\tB\nB1\tr01\tMacaca mulatta\t\tA\n")
        let match = try RNASeqSampleSheet.match(sheet, fileIDs: ["B1", "B2"], byRun: false)
        XCTAssertEqual(match.sampleIDs, ["B1", "B2"])
        XCTAssertEqual(match.records, [
            RNASeqSampleRecord(id: "B2", animal: "r02", species: "Macaca mulatta", origin: "Indian", group: "B"),
            RNASeqSampleRecord(id: "B1", animal: "r01", species: "Macaca mulatta", origin: nil, group: "A"),
        ])
    }

    func testARunColumnLabelsEachSalmonFolder() throws {
        let sheet = try sheet("run\tsample\tlibrary\nSRR896663\tA_1\t1\nSRR896743\tB_1\t1\n")
        let match = try RNASeqSampleSheet.match(sheet, fileIDs: ["SRR896743", "SRR896663"], byRun: true)
        XCTAssertEqual(match.sampleIDs, ["B_1", "A_1"])
        XCTAssertEqual(match.records.map(\.id), ["A_1", "B_1"])
        XCTAssertEqual(match.records.map(\.runs), [["SRR896663"], ["SRR896743"]])
        XCTAssertNil(match.records[0].species, "what the sheet does not state reads Not recorded")
    }

    func testNoSheetLeavesEveryFieldNotRecorded() throws {
        let match = try RNASeqSampleSheet.match(nil, fileIDs: ["S1", "S2"], byRun: true)
        XCTAssertEqual(match.sampleIDs, ["S1", "S2"])
        XCTAssertEqual(match.records, [RNASeqSampleRecord(id: "S1"), RNASeqSampleRecord(id: "S2")])
    }
}
