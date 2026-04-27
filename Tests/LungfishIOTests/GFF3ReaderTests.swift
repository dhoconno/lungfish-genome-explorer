// GFF3ReaderTests.swift - Tests for GFF3 parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishCore

final class GFF3ReaderTests: XCTestCase {

    // MARK: - Test Data

    let sampleGFF3 = """
    ##gff-version 3
    ##sequence-region chr1 1 1000
    chr1\tEMBL\tgene\t100\t500\t.\t+\t.\tID=gene1;Name=TestGene
    chr1\tEMBL\tmRNA\t100\t500\t.\t+\t.\tID=mrna1;Parent=gene1;Name=TestTranscript
    chr1\tEMBL\texon\t100\t200\t.\t+\t.\tID=exon1;Parent=mrna1
    chr1\tEMBL\texon\t300\t500\t.\t+\t.\tID=exon2;Parent=mrna1
    chr1\tEMBL\tCDS\t150\t200\t.\t+\t0\tID=cds1;Parent=mrna1
    chr1\tEMBL\tCDS\t300\t450\t.\t+\t2\tID=cds2;Parent=mrna1
    """

    // MARK: - Helpers

    func createTempFile(content: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "test_\(UUID().uuidString).gff3"
        let url = tempDir.appendingPathComponent(fileName)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Tests

    func testReadAllFeatures() async throws {
        let url = try createTempFile(content: sampleGFF3)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)

        XCTAssertEqual(features.count, 6)
    }

    func testParseGeneFeature() async throws {
        let url = try createTempFile(content: sampleGFF3)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)

        let gene = features.first { $0.type == "gene" }
        XCTAssertNotNil(gene)
        XCTAssertEqual(gene?.seqid, "chr1")
        XCTAssertEqual(gene?.source, "EMBL")
        XCTAssertEqual(gene?.start, 100)
        XCTAssertEqual(gene?.end, 500)
        XCTAssertEqual(gene?.strand, .forward)
        XCTAssertEqual(gene?.attributes["ID"], "gene1")
        XCTAssertEqual(gene?.attributes["Name"], "TestGene")
    }

    func testParseGeneiousQuotedAttributes() async throws {
        let gff = #"""
        ##gff-version 3
        ##source-version geneious 2023.2.1
        M1	Geneious	gene	263031	291324	.	-	.	gene_id "GABBR1"; gene_name "GABBR1"
        """#
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)

        XCTAssertEqual(features.count, 1)
        XCTAssertEqual(features[0].name, "GABBR1")
        XCTAssertEqual(features[0].attributes["gene_id"], "GABBR1")
        XCTAssertEqual(features[0].attributes["gene_name"], "GABBR1")
    }

    func testParseCDSFeature() async throws {
        let url = try createTempFile(content: sampleGFF3)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)

        let cdsFeatures = features.filter { $0.type == "CDS" }
        XCTAssertEqual(cdsFeatures.count, 2)

        let cds1 = cdsFeatures.first { $0.attributes["ID"] == "cds1" }
        XCTAssertNotNil(cds1)
        XCTAssertEqual(cds1?.phase, 0)

        let cds2 = cdsFeatures.first { $0.attributes["ID"] == "cds2" }
        XCTAssertNotNil(cds2)
        XCTAssertEqual(cds2?.phase, 2)
    }

    func testParseStrand() async throws {
        let gff = """
        chr1\ttest\tgene\t1\t100\t.\t+\t.\tID=forward
        chr1\ttest\tgene\t1\t100\t.\t-\t.\tID=reverse
        chr1\ttest\tgene\t1\t100\t.\t.\t.\tID=unknown
        """
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)

        XCTAssertEqual(features[0].strand, .forward)
        XCTAssertEqual(features[1].strand, .reverse)
        XCTAssertEqual(features[2].strand, .unknown)
    }

    func testSkipComments() async throws {
        let gff = """
        # This is a comment
        ##gff-version 3
        # Another comment
        chr1\ttest\tgene\t1\t100\t.\t+\t.\tID=gene1
        """
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)

        XCTAssertEqual(features.count, 1)
    }

    func testUrlDecoding() async throws {
        let gff = """
        chr1\ttest\tgene\t1\t100\t.\t+\t.\tID=gene1;Note=Contains%3Bsemicolon%3Dand%3Dequals
        """
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)

        XCTAssertEqual(features[0].attributes["Note"], "Contains;semicolon=and=equals")
    }

    func testInvalidLineThrows() async throws {
        let gff = """
        chr1\ttest\tgene
        """
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GFF3Reader()

        do {
            _ = try await reader.readAll(from: url)
            XCTFail("Expected error to be thrown")
        } catch let error as GFF3Error {
            switch error {
            case .invalidLineFormat(let line, _, _):
                XCTAssertEqual(line, 1)
            default:
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testConvertToAnnotation() async throws {
        let url = try createTempFile(content: sampleGFF3)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GFF3Reader()
        let annotations = try await reader.readAsAnnotations(from: url)

        XCTAssertEqual(annotations.count, 6)

        let gene = annotations.first { $0.type == .gene }
        XCTAssertNotNil(gene)
        XCTAssertEqual(gene?.name, "TestGene")
        // GFF3 is 1-based, Annotation is 0-based
        XCTAssertEqual(gene?.start, 99)
        XCTAssertEqual(gene?.end, 500)
    }

    func testGroupBySequence() async throws {
        let gff = """
        chr1\ttest\tgene\t1\t100\t.\t+\t.\tID=gene1
        chr2\ttest\tgene\t1\t100\t.\t+\t.\tID=gene2
        chr1\ttest\texon\t10\t50\t.\t+\t.\tID=exon1
        """
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GFF3Reader()
        let grouped = try await reader.readGroupedBySequence(from: url)

        XCTAssertEqual(grouped.keys.count, 2)
        XCTAssertEqual(grouped["chr1"]?.count, 2)
        XCTAssertEqual(grouped["chr2"]?.count, 1)
    }

    func testConvertToAnnotationSupportsExtendedTypes() async throws {
        let gff = """
        chr1\ttest\tmat_peptide\t10\t20\t.\t+\t.\tID=a1
        chr1\ttest\tncRNA\t30\t40\t.\t+\t.\tID=a2
        chr1\ttest\tprotein_bind\t50\t60\t.\t+\t.\tID=a3
        """
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GFF3Reader()
        let annotations = try await reader.readAsAnnotations(from: url)

        XCTAssertEqual(annotations.count, 3)
        XCTAssertEqual(annotations[0].type, .mat_peptide)
        XCTAssertEqual(annotations[1].type, .ncRNA)
        XCTAssertEqual(annotations[2].type, .protein_bind)
    }

    func testConvertToAnnotationUnknownTypeFallsBackToRegion() async throws {
        let gff = """
        chr1\ttest\tunknown_type\t10\t20\t.\t+\t.\tID=a1
        """
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GFF3Reader()
        let annotations = try await reader.readAsAnnotations(from: url)

        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations[0].type, .region)
    }
}
