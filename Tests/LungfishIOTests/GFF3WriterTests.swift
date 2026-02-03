// GFF3WriterTests.swift - Tests for GFF3 writer
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishCore

final class GFF3WriterTests: XCTestCase {

    // MARK: - Helpers

    func createTempFile() -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "test_\(UUID().uuidString).gff3"
        return tempDir.appendingPathComponent(fileName)
    }

    // MARK: - Basic Write Tests

    func testWriteFeatures() async throws {
        let url = createTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let features = [
            GFF3Feature(
                seqid: "chr1",
                source: "EMBL",
                type: "gene",
                start: 100,
                end: 500,
                score: nil,
                strand: .forward,
                phase: nil,
                attributes: ["ID": "gene1", "Name": "TestGene"]
            ),
            GFF3Feature(
                seqid: "chr1",
                source: "EMBL",
                type: "exon",
                start: 100,
                end: 200,
                score: nil,
                strand: .forward,
                phase: nil,
                attributes: ["ID": "exon1", "Parent": "gene1"]
            )
        ]

        try await GFF3Writer.write(features, to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n")

        // Should have header + 2 feature lines
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "##gff-version 3")
        XCTAssertTrue(lines[1].contains("chr1\tEMBL\tgene\t100\t500"))
        XCTAssertTrue(lines[2].contains("chr1\tEMBL\texon\t100\t200"))
    }

    func testWriteFeatureWithScore() async throws {
        let url = createTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let features = [
            GFF3Feature(
                seqid: "chr1",
                source: "test",
                type: "gene",
                start: 100,
                end: 200,
                score: 95.5,
                strand: .forward,
                phase: nil,
                attributes: ["ID": "gene1"]
            )
        ]

        try await GFF3Writer.write(features, to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("95.5"))
    }

    func testWriteFeatureWithPhase() async throws {
        let url = createTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let features = [
            GFF3Feature(
                seqid: "chr1",
                source: "test",
                type: "CDS",
                start: 100,
                end: 200,
                score: nil,
                strand: .forward,
                phase: 2,
                attributes: ["ID": "cds1"]
            )
        ]

        try await GFF3Writer.write(features, to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n")
        let fields = lines[1].split(separator: "\t")

        XCTAssertEqual(fields[7], "2")
    }

    func testWriteAllStrands() async throws {
        let url = createTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let features = [
            GFF3Feature(
                seqid: "chr1",
                source: "test",
                type: "gene",
                start: 100,
                end: 200,
                score: nil,
                strand: .forward,
                phase: nil,
                attributes: ["ID": "forward"]
            ),
            GFF3Feature(
                seqid: "chr1",
                source: "test",
                type: "gene",
                start: 300,
                end: 400,
                score: nil,
                strand: .reverse,
                phase: nil,
                attributes: ["ID": "reverse"]
            ),
            GFF3Feature(
                seqid: "chr1",
                source: "test",
                type: "gene",
                start: 500,
                end: 600,
                score: nil,
                strand: .unknown,
                phase: nil,
                attributes: ["ID": "unknown"]
            )
        ]

        try await GFF3Writer.write(features, to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n")

        let forwardFields = lines[1].split(separator: "\t")
        let reverseFields = lines[2].split(separator: "\t")
        let unknownFields = lines[3].split(separator: "\t")

        XCTAssertEqual(forwardFields[6], "+")
        XCTAssertEqual(reverseFields[6], "-")
        XCTAssertEqual(unknownFields[6], ".")
    }

    // MARK: - Attribute Encoding Tests

    func testUrlEncodeSpecialCharacters() async throws {
        let url = createTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let features = [
            GFF3Feature(
                seqid: "chr1",
                source: "test",
                type: "gene",
                start: 100,
                end: 200,
                score: nil,
                strand: .forward,
                phase: nil,
                attributes: ["ID": "gene1", "Note": "Contains;semicolon=and=equals"]
            )
        ]

        try await GFF3Writer.write(features, to: url)

        let content = try String(contentsOf: url, encoding: .utf8)

        // Semicolons and equals signs in values should be URL-encoded
        XCTAssertTrue(content.contains("%3B"))
        XCTAssertTrue(content.contains("%3D"))
    }

    func testAttributeOrdering() async throws {
        let url = createTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let features = [
            GFF3Feature(
                seqid: "chr1",
                source: "test",
                type: "gene",
                start: 100,
                end: 200,
                score: nil,
                strand: .forward,
                phase: nil,
                attributes: [
                    "Dbxref": "GeneID:12345",
                    "Parent": "parent1",
                    "Name": "TestGene",
                    "ID": "gene1",
                    "Note": "Test note"
                ]
            )
        ]

        try await GFF3Writer.write(features, to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n")
        let fields = lines[1].split(separator: "\t")
        let attributesField = String(fields[8])

        // ID should come first, then Name, then Parent
        let idIndex = attributesField.range(of: "ID=")?.lowerBound
        let nameIndex = attributesField.range(of: "Name=")?.lowerBound
        let parentIndex = attributesField.range(of: "Parent=")?.lowerBound

        XCTAssertNotNil(idIndex)
        XCTAssertNotNil(nameIndex)
        XCTAssertNotNil(parentIndex)
        XCTAssertLessThan(idIndex!, nameIndex!)
        XCTAssertLessThan(nameIndex!, parentIndex!)
    }

    func testEmptyAttributes() async throws {
        let url = createTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let features = [
            GFF3Feature(
                seqid: "chr1",
                source: "test",
                type: "gene",
                start: 100,
                end: 200,
                score: nil,
                strand: .forward,
                phase: nil,
                attributes: [:]
            )
        ]

        try await GFF3Writer.write(features, to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n")
        let fields = lines[1].split(separator: "\t")

        // Empty attributes should be "."
        XCTAssertEqual(fields[8], ".")
    }

    // MARK: - Round Trip Tests

    func testRoundTrip() async throws {
        let url = createTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let originalFeatures = [
            GFF3Feature(
                seqid: "chr1",
                source: "EMBL",
                type: "gene",
                start: 100,
                end: 500,
                score: 95.5,
                strand: .forward,
                phase: nil,
                attributes: ["ID": "gene1", "Name": "TestGene", "Note": "A test gene"]
            ),
            GFF3Feature(
                seqid: "chr1",
                source: "EMBL",
                type: "CDS",
                start: 150,
                end: 450,
                score: nil,
                strand: .forward,
                phase: 0,
                attributes: ["ID": "cds1", "Parent": "gene1"]
            )
        ]

        // Write
        try await GFF3Writer.write(originalFeatures, to: url)

        // Read back
        let reader = GFF3Reader()
        let readFeatures = try await reader.readAll(from: url)

        XCTAssertEqual(readFeatures.count, 2)

        // Verify gene
        let gene = readFeatures.first { $0.type == "gene" }
        XCTAssertNotNil(gene)
        XCTAssertEqual(gene?.seqid, "chr1")
        XCTAssertEqual(gene?.source, "EMBL")
        XCTAssertEqual(gene?.start, 100)
        XCTAssertEqual(gene?.end, 500)
        // Verify score with unwrapping
        if let geneScore = gene?.score {
            XCTAssertEqual(geneScore, 95.5, accuracy: 0.001)
        } else {
            XCTFail("Gene score should not be nil")
        }
        XCTAssertEqual(gene?.strand, .forward)
        XCTAssertEqual(gene?.attributes["ID"], "gene1")
        XCTAssertEqual(gene?.attributes["Name"], "TestGene")

        // Verify CDS
        let cds = readFeatures.first { $0.type == "CDS" }
        XCTAssertNotNil(cds)
        XCTAssertEqual(cds?.phase, 0)
        XCTAssertEqual(cds?.attributes["Parent"], "gene1")
    }

    func testRoundTripWithSpecialCharacters() async throws {
        let url = createTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let originalFeatures = [
            GFF3Feature(
                seqid: "chr1",
                source: "test",
                type: "gene",
                start: 100,
                end: 200,
                score: nil,
                strand: .forward,
                phase: nil,
                attributes: ["ID": "gene1", "Note": "Contains;special=characters&more,values"]
            )
        ]

        // Write
        try await GFF3Writer.write(originalFeatures, to: url)

        // Read back
        let reader = GFF3Reader()
        let readFeatures = try await reader.readAll(from: url)

        XCTAssertEqual(readFeatures.count, 1)
        XCTAssertEqual(readFeatures[0].attributes["Note"], "Contains;special=characters&more,values")
    }

    // MARK: - Annotation Conversion Tests

    func testWriteAnnotations() async throws {
        let url = createTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let annotations = [
            SequenceAnnotation(
                type: .gene,
                name: "BRCA1",
                chromosome: "chr17",
                start: 1000,
                end: 2000,
                strand: .forward,
                qualifiers: ["gene_id": AnnotationQualifier("ENSG00000012048")]
            ),
            SequenceAnnotation(
                type: .cds,
                name: "BRCA1_CDS",
                chromosome: "chr17",
                start: 1100,
                end: 1900,
                strand: .forward
            )
        ]

        try await GFF3Writer.write(annotations, to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n")

        XCTAssertEqual(lines.count, 3) // Header + 2 features

        // Verify the gene was converted correctly
        XCTAssertTrue(lines[1].contains("chr17"))
        XCTAssertTrue(lines[1].contains("gene"))
        XCTAssertTrue(lines[1].contains("1001")) // 0-based to 1-based conversion
        XCTAssertTrue(lines[1].contains("2000"))
        XCTAssertTrue(lines[1].contains("Name=BRCA1"))

        // Verify CDS has phase
        XCTAssertTrue(lines[2].contains("CDS"))
    }

    func testWriteMultiIntervalAnnotation() async throws {
        let url = createTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let annotation = SequenceAnnotation(
            type: .exon,
            name: "TestExons",
            chromosome: "chr1",
            intervals: [
                AnnotationInterval(start: 100, end: 200),
                AnnotationInterval(start: 300, end: 400),
                AnnotationInterval(start: 500, end: 600)
            ],
            strand: .forward
        )

        try await GFF3Writer.write([annotation], to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n")

        // Should have header + 3 feature lines (one per interval)
        XCTAssertEqual(lines.count, 4)

        // Each interval should have Parent attribute pointing to main annotation
        for i in 1...3 {
            XCTAssertTrue(lines[i].contains("Parent="))
            XCTAssertTrue(lines[i].contains("exon"))
        }
    }

    func testAnnotationTypeMapping() async throws {
        let url = createTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let annotations = [
            SequenceAnnotation(type: .gene, name: "gene", chromosome: "chr1", start: 0, end: 100, strand: .forward),
            SequenceAnnotation(type: .mRNA, name: "mrna", chromosome: "chr1", start: 0, end: 100, strand: .forward),
            SequenceAnnotation(type: .cds, name: "cds", chromosome: "chr1", start: 0, end: 100, strand: .forward),
            SequenceAnnotation(type: .exon, name: "exon", chromosome: "chr1", start: 0, end: 100, strand: .forward),
            SequenceAnnotation(type: .utr5, name: "utr5", chromosome: "chr1", start: 0, end: 100, strand: .forward),
            SequenceAnnotation(type: .utr3, name: "utr3", chromosome: "chr1", start: 0, end: 100, strand: .forward),
            SequenceAnnotation(type: .promoter, name: "promoter", chromosome: "chr1", start: 0, end: 100, strand: .forward)
        ]

        try await GFF3Writer.write(annotations, to: url)

        let content = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(content.contains("\tgene\t"))
        XCTAssertTrue(content.contains("\tmRNA\t"))
        XCTAssertTrue(content.contains("\tCDS\t"))
        XCTAssertTrue(content.contains("\texon\t"))
        XCTAssertTrue(content.contains("\tfive_prime_UTR\t"))
        XCTAssertTrue(content.contains("\tthree_prime_UTR\t"))
        XCTAssertTrue(content.contains("\tpromoter\t"))
    }

    // MARK: - Writer Instance Tests

    func testWriterInstanceMethods() async throws {
        let url = createTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try GFF3Writer(url: url, defaultSource: "CustomSource")

        let feature = GFF3Feature(
            seqid: "chr1",
            source: "CustomSource",
            type: "gene",
            start: 100,
            end: 200,
            score: nil,
            strand: .forward,
            phase: nil,
            attributes: ["ID": "gene1"]
        )

        try await writer.write(feature)
        writer.close()

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("##gff-version 3"))
        XCTAssertTrue(content.contains("CustomSource"))
    }

    func testWriterWithoutHeader() async throws {
        let url = createTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try GFF3Writer(url: url, includeHeader: false)

        let feature = GFF3Feature(
            seqid: "chr1",
            source: "test",
            type: "gene",
            start: 100,
            end: 200,
            score: nil,
            strand: .forward,
            phase: nil,
            attributes: ["ID": "gene1"]
        )

        try await writer.write(feature)
        writer.close()

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(content.contains("##gff-version"))
    }

    func testWriteToClosedWriterThrows() async throws {
        let url = createTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try GFF3Writer(url: url)
        writer.close()

        let feature = GFF3Feature(
            seqid: "chr1",
            source: "test",
            type: "gene",
            start: 100,
            end: 200,
            score: nil,
            strand: .forward,
            phase: nil,
            attributes: ["ID": "gene1"]
        )

        do {
            try await writer.write(feature)
            XCTFail("Expected error to be thrown")
        } catch let error as GFF3WriterError {
            switch error {
            case .fileNotOpen:
                // Expected
                break
            default:
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    // MARK: - Coordinate Conversion Tests

    func testCoordinateConversion() async throws {
        let url = createTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        // Create annotation with 0-based coordinates
        let annotation = SequenceAnnotation(
            type: .gene,
            name: "TestGene",
            chromosome: "chr1",
            start: 99,  // 0-based
            end: 500,   // 0-based, exclusive
            strand: .forward
        )

        try await GFF3Writer.write([annotation], to: url)

        // Read back and verify 1-based coordinates
        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)

        XCTAssertEqual(features.count, 1)
        XCTAssertEqual(features[0].start, 100)  // 1-based
        XCTAssertEqual(features[0].end, 500)    // 1-based, inclusive
    }

    // MARK: - Note Field Tests

    func testAnnotationWithNote() async throws {
        let url = createTempFile()
        defer { try? FileManager.default.removeItem(at: url) }

        var annotation = SequenceAnnotation(
            type: .gene,
            name: "TestGene",
            chromosome: "chr1",
            start: 0,
            end: 100,
            strand: .forward
        )
        annotation.note = "This is a test note"

        try await GFF3Writer.write([annotation], to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("Note=This is a test note"))
    }
}
