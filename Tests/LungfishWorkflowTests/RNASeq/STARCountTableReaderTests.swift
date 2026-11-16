// STARCountTableReaderTests.swift - The readers of STAR's ReadsPerGene.out.tab and featureCounts' table with its
// .summary, and their refusals of another shape and of genes other than the set's (Phase 5.3 lane EX-ADOPT M5)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import Foundation
import LungfishTestSupport
@testable import LungfishWorkflow

final class STARCountTableReaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws { root = try TestTempDirectory.make(prefix: "STARCountTableReader") }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    static let sample = RNASeqFixtures.root.appendingPathComponent("star-adopt/star-2711-featurecounts/S1", isDirectory: true)

    private func file(_ name: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// The words of a refusal, or a failure when the read passed.
    private func words(_ read: () throws -> Any, line: UInt = #line) -> String? {
        do {
            _ = try read()
            XCTFail("The reader took the file", line: line)
            return nil
        } catch {
            return (error as? STARCountTableError)?.message
        }
    }

    // MARK: - ReadsPerGene.out.tab

    /// The returned table reads as four `N_` lines and 13 genes of three counts, with strand share 0.511.
    func testGeneCountsReaderTakesFourTotalsThenOneGeneALineWithThreeCounts() throws {
        let table = try STARCountTableReader.readGeneCounts(Self.sample.appendingPathComponent("star/ReadsPerGene.out.tab"), label: "t")
        XCTAssertEqual(table.totals.map(\.id), ["N_unmapped", "N_multimapping", "N_noFeature", "N_ambiguous"])
        XCTAssertEqual(table.totals.map(\.counts), [[0, 0, 0], [0, 0, 0], [0, 1268, 1332], [186, 98, 88]])
        XCTAssertEqual(table.genes.map(\.id), ReferenceSetMitoFixture.genes)
        XCTAssertEqual(table.genes.first?.counts, [200, 97, 103])
        XCTAssertEqual(table.strandShare.map { String(format: "%.3f", $0) }, "0.511")
    }

    /// A file of another shape is refused in words that name it, the line and what STAR writes.
    func testGeneCountsReaderRefusesAnotherShapeInWords() throws {
        let totals = "N_unmapped\t0\t0\t0\nN_multimapping\t0\t0\t0\nN_noFeature\t0\t0\t0\nN_ambiguous\t0\t0\t0\n"
        let shape = ". STAR writes four lines N_unmapped, N_multimapping, N_noFeature and N_ambiguous, then one gene a line, "
            + "each with three counts."
        let cases: [(String, String)] = [
            ("ND1\t1\t1\t0\n" + totals, "line 1 starts \"ND1\", not N_unmapped"),
            (totals + "ND1\t1\t1\n", "line 5 holds 3 columns, not 4"),
            (totals + "ND1\t1\tx\t0\n", "line 5 holds \"x\" where a count is"),
            (totals + "ND1\t1\t1\t0\nND1\t1\t1\t0\n", "the gene ND1 is on two lines"),
            (totals, "it holds no gene line"),
        ]
        for (index, (text, problem)) in cases.enumerated() {
            let url = try file("case\(index).tab", text)
            XCTAssertEqual(
                words { try STARCountTableReader.readGeneCounts(url, label: "star/ReadsPerGene.out.tab of the sample S1") },
                "The file star/ReadsPerGene.out.tab of the sample S1 is not STAR's ReadsPerGene.out.tab: \(problem)\(shape)")
        }
    }

    // MARK: - featureCounts

    /// The returned table reads as its program line, one BAM and 13 genes, with its summary.
    func testFeatureCountsReaderTakesTheProgramLineTheHeaderAndOneCountColumnWithItsSummary() throws {
        let table = try STARCountTableReader.readFeatureCounts(
            table: Self.sample.appendingPathComponent("featurecounts/counts.txt"),
            summary: Self.sample.appendingPathComponent("featurecounts/counts.txt.summary"), label: "t", summaryLabel: "s")
        XCTAssertTrue(table.program.hasPrefix("# Program:featureCounts v2.1.1; "))
        XCTAssertEqual(table.bam, "star/Aligned.out.bam")
        XCTAssertEqual(table.genes.map(\.id), ReferenceSetMitoFixture.genes)
        XCTAssertEqual(table.genes.map(\.count).reduce(0, +), 2585)
        XCTAssertEqual(table.summary.first, .init(id: "Assigned", count: 2585))
        XCTAssertEqual(table.summary.filter { $0.count > 0 }.map(\.id), ["Assigned", "Unassigned_Ambiguity"])
    }

    /// A table or summary of another shape, or a summary of another BAM, is refused in words that name the file.
    func testFeatureCountsReaderRefusesAnotherShapeInWords() throws {
        let program = "# Program:featureCounts v2.1.1; Command:\"featureCounts\"\n"
        let header = "Geneid\tChr\tStart\tEnd\tStrand\tLength\tA.bam\n"
        let row = "ND1\tNC_012670.1\t1\t9\t+\t9\t4\n"
        let summary = try file("good.summary", "Status\tA.bam\nAssigned\t4\nUnassigned_NoFeatures\t0\n")
        let tableWords = ". featureCounts writes a # Program line, the header Geneid, Chr, Start, End, Strand, Length and the BAM, "
            + "then one gene a line with its count."
        let tables: [(String, String)] = [
            (header + row, "its first line is not featureCounts' # Program line"),
            (program + "Geneid\tChr\tStart\tEnd\tStrand\tLength\tA.bam\tB.bam\n" + row,
             "its header is \"Geneid Chr Start End Strand Length A.bam B.bam\""),
            (program + header + "ND1\tNC_012670.1\t1\t9\t+\t9\t0.5\n", "line 3 holds \"0.5\" where a count is"),
        ]
        for (index, (text, problem)) in tables.enumerated() {
            let url = try file("table\(index).txt", text)
            XCTAssertEqual(
                words { try STARCountTableReader.readFeatureCounts(table: url, summary: summary, label: "T", summaryLabel: "S") },
                "The file T is not a featureCounts table of one BAM: \(problem)\(tableWords)")
        }
        let table = try file("table.txt", program + header + row)
        let summaryWords = ". featureCounts writes the header Status and the table's BAM, then one status a line with its "
            + "count, Assigned among them."
        let summaries: [(String, String)] = [
            ("Status\tB.bam\nAssigned\t4\n", "it counts B.bam, and the table counts A.bam"),
            ("Status\tA.bam\nUnassigned_NoFeatures\t0\n", "it holds no Assigned line"),
        ]
        for (index, (text, problem)) in summaries.enumerated() {
            let url = try file("summary\(index)", text)
            XCTAssertEqual(
                words { try STARCountTableReader.readFeatureCounts(table: table, summary: url, label: "T", summaryLabel: "S") },
                "The file S is not the .summary of T: \(problem)\(summaryWords)")
        }
    }

    // MARK: - BIO-COUNTING-GTF item 5, the set's genes

    /// The set's counted genes are those of `derived/genes.tsv` with a length above 0, and a table of other ids is
    /// refused in words that name the set, the numbers missing and extra and the first three of each.
    func testAGeneListOtherThanTheSetsCountedGenesIsRefusedInWords() throws {
        let genes = try file("genes.tsv", "gene_id\tname\tbiotype\tcontig\tlength\tnot_host\tmask\tunreliable\n"
            + "A\tA\tprotein_coding\tc\t10\tfalse\t\t\nB\tB\tprotein_coding\tc\t0\tfalse\t\t\nC\tC\tprotein_coding\tc\t5\tfalse\t\t\n"
            + "D\tD\tprotein_coding\tc\t7\tfalse\t\t\n")
        let set = try STARCountTableReader.countedGenes(genesTSV: genes)
        XCTAssertEqual(set, ["A", "C", "D"])
        XCTAssertNoThrow(try STARCountTableReader.checkGenes(["D", "A", "C"], label: "T", setID: "s", setGenes: set))
        XCTAssertEqual(
            words { try STARCountTableReader.checkGenes(["A", "W", "X", "Y", "Z"], label: "T", setID: "s", setGenes: set) },
            "The genes of T are not the genes of the set s: 2 of the set's 3 genes with a length above 0 are missing (C, D), "
                + "and 4 ids are not the set's (W, X, Y and 1 more). It was counted on a GTF other than the set's "
                + "derived/genes.gtf, so its genes would read 0 where the reads are. Make the plan again with this version of "
                + "Lungfish, run it, and adopt the folder it returns.")
        XCTAssertEqual(
            words { try STARCountTableReader.checkGenes(["A", "C"], label: "T", setID: "s", setGenes: set) }?
                .hasPrefix("The genes of T are not the genes of the set s: 1 of the set's 3 genes with a length above 0 is missing (D). "),
            true)
    }
}
