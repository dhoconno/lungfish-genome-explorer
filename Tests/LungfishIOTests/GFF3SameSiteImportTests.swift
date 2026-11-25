// GFF3SameSiteImportTests.swift - GFF3 and GTF import keeps every feature that differs in any stored field
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// BIO-GFF3-IMPORT-DEDUP-17. `createFromGFF3` skipped a line whose name, type, seqid, start and end it had seen, so it
// dropped an attribute twin, a twin on the other strand and the second transcript's copy of a shared exon or CDS. The
// two hand files are the ones BIO measured with the packaged CLI (9 of 12 and 6 of 8 rows kept). Only lines that
// agree on every stored field may collapse.

import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishIO

final class GFF3SameSiteImportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "gff3-same-site")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    /// BIO's hand GFF3, twelve lines: two notes at one site, a plus and a minus copy of one site, one distinct site, a
    /// gene with two mRNAs, and an exon at 1001-1200 under each mRNA.
    private static let gff3Lines = [
        "chrT\ttest\tmisc_feature\t101\t103\t.\t+\t.\tID=mf1;Name=siteA;note=N-acetylvaline",
        "chrT\ttest\tmisc_feature\t101\t103\t.\t+\t.\tID=mf2;Name=siteA;note=glycation valine in Hb A1c",
        "chrT\ttest\tmisc_feature\t201\t260\t.\t+\t.\tID=s1;Name=siteB;note=plus copy",
        "chrT\ttest\tmisc_feature\t201\t260\t.\t-\t.\tID=s2;Name=siteB;note=minus copy",
        "chrT\ttest\tmisc_feature\t401\t460\t.\t+\t.\tID=ctl1;Name=control;note=distinct site",
        "chrT\ttest\tgene\t1001\t2000\t.\t+\t.\tID=gene-G1;Name=G1;gene=G1",
        "chrT\ttest\tmRNA\t1001\t2000\t.\t+\t.\tID=rna-T1;Parent=gene-G1;Name=T1;gene=G1",
        "chrT\ttest\tmRNA\t1001\t1900\t.\t+\t.\tID=rna-T2;Parent=gene-G1;Name=T2;gene=G1",
        "chrT\ttest\texon\t1001\t1200\t.\t+\t.\tID=exon-T1-1;Parent=rna-T1;gene=G1",
        "chrT\ttest\texon\t1501\t2000\t.\t+\t.\tID=exon-T1-2;Parent=rna-T1;gene=G1",
        "chrT\ttest\texon\t1001\t1200\t.\t+\t.\tID=exon-T2-1;Parent=rna-T2;gene=G1",
        "chrT\ttest\texon\t1601\t1900\t.\t+\t.\tID=exon-T2-2;Parent=rna-T2;gene=G1",
    ]

    /// BIO's hand GTF, eight lines: two transcripts of one gene that share their first exon and their CDS site.
    private static let gtfLines = [
        "chrT\ttest\ttranscript\t1001\t2000\t.\t+\t.\tgene_id \"G1\"; transcript_id \"T1\"; gene_name \"G1\";",
        "chrT\ttest\texon\t1001\t1200\t.\t+\t.\tgene_id \"G1\"; transcript_id \"T1\"; gene_name \"G1\"; exon_number \"1\";",
        "chrT\ttest\texon\t1501\t2000\t.\t+\t.\tgene_id \"G1\"; transcript_id \"T1\"; gene_name \"G1\"; exon_number \"2\";",
        "chrT\ttest\ttranscript\t1001\t1900\t.\t+\t.\tgene_id \"G1\"; transcript_id \"T2\"; gene_name \"G1\";",
        "chrT\ttest\texon\t1001\t1200\t.\t+\t.\tgene_id \"G1\"; transcript_id \"T2\"; gene_name \"G1\"; exon_number \"1\";",
        "chrT\ttest\texon\t1601\t1900\t.\t+\t.\tgene_id \"G1\"; transcript_id \"T2\"; gene_name \"G1\"; exon_number \"2\";",
        "chrT\ttest\tCDS\t1051\t1200\t.\t+\t0\tgene_id \"G1\"; transcript_id \"T1\"; gene_name \"G1\";",
        "chrT\ttest\tCDS\t1051\t1200\t.\t+\t0\tgene_id \"G1\"; transcript_id \"T2\"; gene_name \"G1\";",
    ]

    /// Imports `lines` and returns the count the import reports and every row it stored.
    private func importLines(_ lines: [String], file: String) async throws -> (count: Int, rows: [AnnotationDatabaseRecord]) {
        let sourceURL = root.appendingPathComponent(file)
        try (lines.joined(separator: "\n") + "\n").write(to: sourceURL, atomically: true, encoding: .utf8)
        let databaseURL = root.appendingPathComponent("\(file).db")
        let count = try await AnnotationDatabase.createFromGFF3(gffURL: sourceURL, outputURL: databaseURL)
        let rows = try AnnotationDatabase(url: databaseURL).queryByRegion(
            chromosome: "chrT", start: 0, end: 3000, limit: 1000)
        return (count, rows)
    }

    /// All twelve lines of the hand GFF3 are twelve features: both notes at chrT 100-103, both strands of siteB at
    /// 200-260, and the exon at 1000-1200 under each mRNA (BIO-GFF3-IMPORT-DEDUP-17 item 7). H17 keeps nine.
    func testTheHandGFF3KeepsAllTwelveFeatures() async throws {
        let imported = try await importLines(Self.gff3Lines, file: "hand.gff3")

        XCTAssertEqual(imported.count, 12, "the import reports every feature it stored")
        XCTAssertEqual(imported.rows.count, 12, "the database holds every feature of the file")

        let siteA = imported.rows.filter { $0.name == "siteA" && $0.start == 100 && $0.end == 103 }
        XCTAssertEqual(siteA.count, 2, "both notes at chrT 100-103")
        XCTAssertTrue(siteA.contains { $0.attributes?.contains("note=N-acetylvaline") == true })
        XCTAssertTrue(siteA.contains { $0.attributes?.contains("note=glycation valine in Hb A1c") == true })

        let siteB = imported.rows.filter { $0.name == "siteB" && $0.start == 200 && $0.end == 260 }
        XCTAssertEqual(siteB.map(\.strand).sorted(), ["+", "-"], "the minus copy of siteB at 200-260 is kept")

        let sharedExons = imported.rows.filter { $0.type == "exon" && $0.start == 1000 && $0.end == 1200 }
        XCTAssertEqual(sharedExons.count, 2, "the exon at 1000-1200 under each mRNA")
        XCTAssertTrue(sharedExons.contains { $0.attributes?.contains("Parent=rna-T2") == true })
        XCTAssertTrue(sharedExons.contains { $0.attributes?.contains("Parent=rna-T1") == true })
    }

    /// All eight lines of the hand GTF are eight features, and the exon at 1000-1200 and the CDS at 1050-1200 of
    /// transcript T2 sit beside T1's (BIO-GFF3-IMPORT-DEDUP-17 item 7). H17 keeps six.
    func testTheHandGTFKeepsAllEightLines() async throws {
        let imported = try await importLines(Self.gtfLines, file: "hand.gtf")

        XCTAssertEqual(imported.count, 8, "the import reports every feature it stored")
        XCTAssertEqual(imported.rows.count, 8, "the database holds every line of the file")

        let t2Exon = imported.rows.filter {
            $0.type == "exon" && $0.start == 1000 && $0.end == 1200 && $0.attributes?.contains("transcript_id=T2") == true
        }
        XCTAssertEqual(t2Exon.count, 1, "T2's exon 1001-1200 is kept beside T1's")
        let t2CDS = imported.rows.filter {
            $0.type == "CDS" && $0.start == 1050 && $0.end == 1200 && $0.attributes?.contains("transcript_id=T2") == true
        }
        XCTAssertEqual(t2CDS.count, 1, "T2's CDS 1051-1200 is kept beside T1's")
    }

    /// A line that agrees with another on every stored field is the same feature written twice, so it is still one row.
    /// Two lines that differ in their ID are two features, even with one name and one site.
    func testOnlyLinesThatAgreeOnEveryStoredFieldCollapse() async throws {
        let line = "chrT\ttest\tgene\t101\t500\t.\t+\t.\tID=g1;Name=dup"
        let identical = try await importLines([line, line], file: "identical.gff3")
        XCTAssertEqual(identical.count, 1, "a line written twice is one feature")
        XCTAssertEqual(identical.rows.count, 1)

        let otherID = "chrT\ttest\tgene\t101\t500\t.\t+\t.\tID=g2;Name=dup"
        let differing = try await importLines([line, otherID], file: "ids.gff3")
        XCTAssertEqual(differing.count, 2, "two IDs are two features")
        XCTAssertEqual(differing.rows.count, 2)
    }
}
