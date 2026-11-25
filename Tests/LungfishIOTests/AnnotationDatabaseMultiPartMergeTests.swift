// AnnotationDatabaseMultiPartMergeTests.swift - GFF3 lines that share an ID are one feature, for every type
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// EXPORT-REOPEN-MULTIPART (S1, BIO-EXPORT-REOPEN-MULTIPART-17R, item 3). LGE's Export Annotations as GFF3 writes a
// spliced mRNA, misc_RNA or misc_feature as one line for each part, every line with one ID. That is valid GFF3, and
// the import joined same-ID lines for CDS only, so a new bundle from the file or an Import Center attach made one row
// for each part, with no blocks and no word. Lines join when they agree on ID, type, seqid and strand.

import Foundation
import LungfishCore
import LungfishTestSupport
import XCTest
@testable import LungfishIO

final class AnnotationDatabaseMultiPartMergeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "gff3-multipart")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// Imports `lines` and returns the count the import reports and every row it stored on `chromosomes`.
    private func importLines(
        _ lines: [String], file: String, chromosomes: [String] = ["chrT"]
    ) async throws -> (count: Int, rows: [AnnotationDatabaseRecord]) {
        let sourceURL = root.appendingPathComponent(file)
        try (lines.joined(separator: "\n") + "\n").write(to: sourceURL, atomically: true, encoding: .utf8)
        let databaseURL = root.appendingPathComponent("\(file).db")
        let count = try await AnnotationDatabase.createFromGFF3(gffURL: sourceURL, outputURL: databaseURL)
        let database = try AnnotationDatabase(url: databaseURL)
        var rows: [AnnotationDatabaseRecord] = []
        for chromosome in chromosomes {
            rows += try database.queryByRegion(chromosome: chromosome, start: 0, end: 100_000, limit: 1000)
        }
        return (count, rows)
    }

    // MARK: - (a) an mRNA on three lines

    /// HBB's spliced mRNA as LGE writes it, three lines with one ID, is one row with three blocks.
    func testAnMRNAOnThreeLinesWithOneIDIsOneRowWithThreeBlocks() async throws {
        let imported = try await importLines([
            "chrT\ttest\tmRNA\t101\t192\t.\t+\t.\tID=rna-HBB;Name=HBB",
            "chrT\ttest\tmRNA\t301\t523\t.\t+\t.\tID=rna-HBB;Name=HBB",
            "chrT\ttest\tmRNA\t801\t1000\t.\t+\t.\tID=rna-HBB;Name=HBB",
        ], file: "mrna.gff3")

        XCTAssertEqual(imported.count, 1, "three lines of one feature are one row")
        XCTAssertEqual(imported.rows.count, 1, "the database holds one row for the mRNA")
        let row = try XCTUnwrap(imported.rows.first)
        XCTAssertEqual(row.type, "mRNA")
        XCTAssertEqual(row.name, "HBB")
        XCTAssertEqual(row.start, 100, "the row starts at the first part")
        XCTAssertEqual(row.end, 1000, "the row ends at the last part")
        XCTAssertEqual(row.strand, "+")
        XCTAssertEqual(row.blockCount, 3)
        XCTAssertEqual(row.blockSizes, "92,223,200")
        XCTAssertEqual(row.blockStarts, "0,200,700")
    }

    // MARK: - (b) ncRNA, misc_RNA and misc_feature on two lines

    private func assertTwoLinesAreOneRow(type: String, file: String) async throws {
        let imported = try await importLines([
            "chrT\ttest\t\(type)\t101\t160\t.\t-\t.\tID=part-1;Name=part-A",
            "chrT\ttest\t\(type)\t301\t400\t.\t-\t.\tID=part-1;Name=part-A",
        ], file: file)

        XCTAssertEqual(imported.count, 1, "\(type): two lines of one feature are one row")
        XCTAssertEqual(imported.rows.count, 1, "\(type): the database holds one row")
        let row = try XCTUnwrap(imported.rows.first)
        XCTAssertEqual(row.type, type)
        XCTAssertEqual(row.start, 100, "\(type): the row starts at the first part")
        XCTAssertEqual(row.end, 400, "\(type): the row ends at the last part")
        XCTAssertEqual(row.strand, "-")
        XCTAssertEqual(row.blockCount, 2, "\(type): one block for each part")
        XCTAssertEqual(row.blockSizes, "60,100", "\(type)")
        XCTAssertEqual(row.blockStarts, "0,200", "\(type)")
    }

    func testAnNcRNAOnTwoLinesWithOneIDIsOneRowWithTwoBlocks() async throws {
        try await assertTwoLinesAreOneRow(type: "ncRNA", file: "ncrna.gff3")
    }

    func testAMiscRNAOnTwoLinesWithOneIDIsOneRowWithTwoBlocks() async throws {
        try await assertTwoLinesAreOneRow(type: "misc_RNA", file: "misc-rna.gff3")
    }

    func testAMiscFeatureOnTwoLinesWithOneIDIsOneRowWithTwoBlocks() async throws {
        try await assertTwoLinesAreOneRow(type: "misc_feature", file: "misc-feature.gff3")
    }

    // MARK: - (c) the writer, the build and toAnnotation

    /// A three-part mRNA goes through `GFF3Writer`, then the build, and comes back through `toAnnotation` with the
    /// same intervals. HBB's parts are the ones of NG_000007.3 in the ruling.
    func testASplicedMRNAFromGFF3WriterComesBackThroughToAnnotationWithTheSameIntervals() async throws {
        let sequenceID = "NG_000007.3"
        let intervals = [
            AnnotationInterval(start: 70_544, end: 70_686),
            AnnotationInterval(start: 70_816, end: 71_039),
            AnnotationInterval(start: 71_889, end: 72_152),
        ]
        let annotation = SequenceAnnotation(
            type: .mRNA, name: "HBB", chromosome: sequenceID, intervals: intervals, strand: .forward, qualifiers: [:]
        )
        let written = root.appendingPathComponent("writer.gff3")
        try await GFF3Writer.write([annotation], to: written)

        // The writer's form: one line for each part, every line with the one ID of the annotation.
        let lines = try String(contentsOf: written, encoding: .utf8)
            .split(separator: "\n").filter { !$0.hasPrefix("#") }
        XCTAssertEqual(lines.count, 3, "the writer gives each part its own line")
        let ids = Set(lines.compactMap { line -> String? in
            line.split(separator: "\t").last?.split(separator: ";").first { $0.hasPrefix("ID=") }.map(String.init)
        })
        XCTAssertEqual(ids.count, 1, "every line of the one annotation carries the same ID. \(ids)")

        let databaseURL = root.appendingPathComponent("writer.db")
        let count = try await AnnotationDatabase.createFromGFF3(gffURL: written, outputURL: databaseURL)
        XCTAssertEqual(count, 1, "the file holds one feature")
        let rows = try AnnotationDatabase(url: databaseURL)
            .queryByRegion(chromosome: sequenceID, start: 0, end: 100_000, limit: 100)
        XCTAssertEqual(rows.count, 1, "the database holds one row for it")

        let back = try XCTUnwrap(rows.first).toAnnotation()
        XCTAssertEqual(back.type, .mRNA)
        XCTAssertEqual(back.strand, .forward)
        XCTAssertEqual(back.intervals.map { [$0.start, $0.end] }, intervals.map { [$0.start, $0.end] },
                       "the same three intervals come back")
    }

    // MARK: - Guards

    /// Lines with one ID that differ in type are not parts of one feature. A CDS with the ID of an mRNA is a CDS of
    /// its own span, and an ncRNA and a misc_RNA that share an ID stay two rows.
    func testLinesOfTwoTypesWithOneIDDoNotMerge() async throws {
        let imported = try await importLines([
            "chrT\ttest\tmRNA\t101\t200\t.\t+\t.\tID=x;Name=x",
            "chrT\ttest\tCDS\t301\t400\t.\t+\t0\tID=x;Name=x",
            "chrT\ttest\tncRNA\t501\t600\t.\t+\t.\tID=y;Name=y",
            "chrT\ttest\tmisc_RNA\t701\t800\t.\t+\t.\tID=y;Name=y",
        ], file: "two-types.gff3")

        XCTAssertEqual(imported.count, 4, "four lines of four features")
        XCTAssertEqual(imported.rows.count, 4)
        XCTAssertTrue(imported.rows.allSatisfy { $0.blockCount == nil }, "no row has blocks. \(imported.rows)")
        let spans = imported.rows.map { "\($0.type):\($0.start)-\($0.end)" }.sorted()
        XCTAssertEqual(spans, ["CDS:300-400", "mRNA:100-200", "misc_RNA:700-800", "ncRNA:500-600"])
    }

    /// One ID on two seqids is two features, for a CDS as for any other type.
    func testOneIDOnTwoSeqidsDoesNotMerge() async throws {
        let imported = try await importLines([
            "chrA\ttest\tmRNA\t101\t200\t.\t+\t.\tID=x;Name=x",
            "chrB\ttest\tmRNA\t301\t400\t.\t+\t.\tID=x;Name=x",
            "chrA\ttest\tCDS\t501\t600\t.\t+\t0\tID=c;Name=c",
            "chrB\ttest\tCDS\t701\t800\t.\t+\t0\tID=c;Name=c",
        ], file: "two-seqids.gff3", chromosomes: ["chrA", "chrB"])

        XCTAssertEqual(imported.count, 4, "four lines of four features")
        XCTAssertEqual(imported.rows.count, 4)
        XCTAssertTrue(imported.rows.allSatisfy { $0.blockCount == nil }, "no row has blocks. \(imported.rows)")
        XCTAssertEqual(imported.rows.filter { $0.chromosome == "chrA" }.count, 2, "chrA keeps its mRNA and CDS")
        XCTAssertEqual(imported.rows.filter { $0.chromosome == "chrB" }.count, 2, "chrB keeps its mRNA and CDS")
    }

    /// One ID on two strands is two features, for a CDS as for any other type.
    func testOneIDOnTwoStrandsDoesNotMerge() async throws {
        let imported = try await importLines([
            "chrT\ttest\tmRNA\t101\t200\t.\t+\t.\tID=x;Name=x",
            "chrT\ttest\tmRNA\t301\t400\t.\t-\t.\tID=x;Name=x",
            "chrT\ttest\tCDS\t501\t600\t.\t+\t0\tID=c;Name=c",
            "chrT\ttest\tCDS\t701\t800\t.\t-\t0\tID=c;Name=c",
        ], file: "two-strands.gff3")

        XCTAssertEqual(imported.count, 4, "four lines of four features")
        XCTAssertEqual(imported.rows.count, 4)
        XCTAssertTrue(imported.rows.allSatisfy { $0.blockCount == nil }, "no row has blocks. \(imported.rows)")
    }

    /// A line written twice with one ID is one feature written twice, so it is one row with no blocks.
    func testALineWrittenTwiceWithOneIDIsOneRowWithNoBlocks() async throws {
        let line = "chrT\ttest\tmisc_feature\t101\t160\t.\t+\t.\tID=m1;Name=twice"
        let imported = try await importLines([line, line], file: "twice.gff3")

        XCTAssertEqual(imported.count, 1)
        XCTAssertEqual(imported.rows.count, 1)
        XCTAssertNil(imported.rows.first?.blockCount, "one interval is no block list")
        XCTAssertEqual(imported.rows.first.map { [$0.start, $0.end] }, [100, 160])
    }
}
