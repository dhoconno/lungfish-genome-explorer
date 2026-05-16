// GTFReaderTests.swift - Tests for GTF parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishCore

final class GTFReaderTests: XCTestCase {

    // MARK: - Test Data

    /// Inline GTF content for unit tests (GENCODE-style).
    let sampleGTF = """
    chr1\tGENCODE\tgene\t11869\t14409\t.\t+\t.\tgene_id "ENSG00000223972"; gene_type "transcribed_unprocessed_pseudogene"; gene_name "DDX11L1"; level 2; hgnc_id "HGNC:37102";
    chr1\tGENCODE\ttranscript\t11869\t14409\t.\t+\t.\tgene_id "ENSG00000223972"; transcript_id "ENST00000456328"; gene_type "transcribed_unprocessed_pseudogene"; gene_name "DDX11L1"; transcript_type "processed_transcript"; transcript_name "DDX11L1-202"; level 2;
    chr1\tGENCODE\texon\t11869\t12227\t.\t+\t.\tgene_id "ENSG00000223972"; transcript_id "ENST00000456328"; gene_name "DDX11L1"; exon_number 1; exon_id "ENSE00002234944"; level 2;
    chr1\tGENCODE\texon\t12613\t12721\t.\t+\t.\tgene_id "ENSG00000223972"; transcript_id "ENST00000456328"; gene_name "DDX11L1"; exon_number 2; exon_id "ENSE00003582793"; level 2;
    chr1\tGENCODE\tgene\t14404\t29570\t.\t-\t.\tgene_id "ENSG00000227232"; gene_type "unprocessed_pseudogene"; gene_name "WASH7P"; level 2;
    chr1\tGENCODE\tCDS\t14404\t14501\t.\t-\t0\tgene_id "ENSG00000227232"; transcript_id "ENST00000488147"; gene_name "WASH7P"; exon_number 1; level 2;
    """

    // MARK: - Helpers

    /// Returns the URL for the bundled sample.gtf test fixture.
    func sampleGTFURL() throws -> URL {
        guard let url = Bundle.module.url(forResource: "sample", withExtension: "gtf", subdirectory: "Resources") else {
            throw XCTSkip("sample.gtf fixture not found in test bundle")
        }
        return url
    }

    /// Creates a temporary GTF file from inline content.
    func createTempFile(content: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "test_\(UUID().uuidString).gtf"
        let url = tempDir.appendingPathComponent(fileName)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Feature Count Tests

    func testReadAllFeaturesFromInlineData() async throws {
        let url = try createTempFile(content: sampleGTF)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GTFReader(url: url)
        let features = try await reader.readAllFeatures()

        // 2 genes + 1 transcript + 2 exons + 1 CDS = 6
        XCTAssertEqual(features.count, 6)
    }

    func testReadAllFeaturesFromGzippedGTF() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).gtf.gz")
        try GzipTestHelper.writeGzip(sampleGTF, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GTFReader(url: url)
        let features = try await reader.readAllFeatures()

        XCTAssertEqual(features.count, 6)
        XCTAssertEqual(features[0].geneID, "ENSG00000223972")
    }

    func testReadAllAnnotationsFromFixture() async throws {
        let url = try sampleGTFURL()
        let reader = GTFReader(url: url)
        let annotations = try await reader.readAll()

        // sample.gtf has 10 feature lines (3 comment lines skipped)
        XCTAssertEqual(annotations.count, 10)
    }

    func testReadAllSync() throws {
        let url = try createTempFile(content: sampleGTF)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GTFReader(url: url)
        let annotations = try reader.readAllSync()

        XCTAssertEqual(annotations.count, 6)
    }

    func testReadAllSyncSupportsGzippedGTF() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).gtf.gz")
        try GzipTestHelper.writeGzip(sampleGTF, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GTFReader(url: url)
        let annotations = try reader.readAllSync()

        XCTAssertEqual(annotations.count, 6)
        XCTAssertEqual(annotations[0].name, "DDX11L1")
    }

    // MARK: - Gene Attribute Tests

    func testGeneAttributes() async throws {
        let url = try sampleGTFURL()
        let reader = GTFReader(url: url)
        let features = try await reader.readAllFeatures()

        let genes = features.filter { $0.type == "gene" }
        XCTAssertEqual(genes.count, 2)

        // First gene: DDX11L1
        let ddx11l1 = genes.first { $0.geneID == "ENSG00000223972" }
        XCTAssertNotNil(ddx11l1)
        XCTAssertEqual(ddx11l1?.attributes["gene_name"], "DDX11L1")
        XCTAssertEqual(ddx11l1?.attributes["gene_type"], "transcribed_unprocessed_pseudogene")
        XCTAssertEqual(ddx11l1?.seqid, "chr1")
        XCTAssertEqual(ddx11l1?.source, "GENCODE")
        XCTAssertEqual(ddx11l1?.name, "DDX11L1")

        // Second gene: WASH7P
        let wash7p = genes.first { $0.geneID == "ENSG00000227232" }
        XCTAssertNotNil(wash7p)
        XCTAssertEqual(wash7p?.attributes["gene_name"], "WASH7P")
        XCTAssertEqual(wash7p?.attributes["gene_type"], "unprocessed_pseudogene")
    }

    func testGeneAnnotationNameUsesGeneName() async throws {
        let url = try sampleGTFURL()
        let reader = GTFReader(url: url)
        let annotations = try await reader.readAll()

        let genes = annotations.filter { $0.type == .gene }
        XCTAssertEqual(genes.count, 2)

        // gene_name should be used as the annotation name
        let geneNames = genes.map(\.name).sorted()
        XCTAssertEqual(geneNames, ["DDX11L1", "WASH7P"])
    }

    // MARK: - Transcript Attribute Tests

    func testTranscriptAttributes() async throws {
        let url = try sampleGTFURL()
        let reader = GTFReader(url: url)
        let features = try await reader.readAllFeatures()

        let transcripts = features.filter { $0.type == "transcript" }
        XCTAssertEqual(transcripts.count, 2)

        let t1 = transcripts.first { $0.transcriptID == "ENST00000456328" }
        XCTAssertNotNil(t1)
        XCTAssertEqual(t1?.attributes["transcript_name"], "DDX11L1-202")
        XCTAssertEqual(t1?.attributes["transcript_type"], "processed_transcript")
        XCTAssertEqual(t1?.geneID, "ENSG00000223972")
    }

    // MARK: - Exon Tests

    func testExonFeaturesWithParentGeneAndTranscript() async throws {
        let url = try sampleGTFURL()
        let reader = GTFReader(url: url)
        let features = try await reader.readAllFeatures()

        let exons = features.filter { $0.type == "exon" }
        XCTAssertEqual(exons.count, 5)

        // All exons should have gene_id
        for exon in exons {
            XCTAssertNotNil(exon.geneID, "Every exon must have a gene_id")
        }

        // All exons should have transcript_id
        for exon in exons {
            XCTAssertNotNil(exon.transcriptID, "Every exon must have a transcript_id")
        }

        // DDX11L1 transcript has 3 exons
        let ddx11l1Exons = exons.filter { $0.transcriptID == "ENST00000456328" }
        XCTAssertEqual(ddx11l1Exons.count, 3)

        // WASH7P transcript has 2 exons
        let wash7pExons = exons.filter { $0.transcriptID == "ENST00000488147" }
        XCTAssertEqual(wash7pExons.count, 2)
    }

    func testExonAnnotationQualifiers() async throws {
        let url = try sampleGTFURL()
        let reader = GTFReader(url: url)
        let annotations = try await reader.readAll()

        let exons = annotations.filter { $0.type == .exon }
        XCTAssertGreaterThan(exons.count, 0)

        // Exon qualifiers should contain gene_id and transcript_id
        let firstExon = exons[0]
        XCTAssertNotNil(firstExon.qualifier("gene_id"))
        XCTAssertNotNil(firstExon.qualifier("transcript_id"))
    }

    // MARK: - Coordinate Conversion Tests

    func testCoordinateConversion() async throws {
        let url = try sampleGTFURL()
        let reader = GTFReader(url: url)

        let features = try await reader.readAllFeatures()
        let annotations = try await reader.readAll()

        // First gene: GTF 11869-14409 -> internal 11868-14409 (0-based half-open)
        let geneFeature = features.first { $0.type == "gene" }
        let geneAnnot = annotations.first { $0.type == .gene }

        XCTAssertNotNil(geneFeature)
        XCTAssertNotNil(geneAnnot)

        if let feature = geneFeature, let annot = geneAnnot {
            // GTF start is 1-based inclusive -> 0-based: subtract 1
            XCTAssertEqual(annot.start, feature.start - 1,
                           "Start should be converted from 1-based to 0-based")
            // GTF end is 1-based inclusive -> 0-based half-open: stays the same
            XCTAssertEqual(annot.end, feature.end,
                           "End should stay the same (1-based inclusive == 0-based exclusive)")
        }
    }

    func testSpecificCoordinateValues() async throws {
        let url = try sampleGTFURL()
        let reader = GTFReader(url: url)
        let annotations = try await reader.readAll()

        let genes = annotations.filter { $0.type == .gene }
        let ddx11l1 = genes.first { $0.qualifier("gene_id") == "ENSG00000223972" }
        XCTAssertNotNil(ddx11l1)

        // GTF: start=11869, end=14409 -> internal: start=11868, end=14409
        XCTAssertEqual(ddx11l1?.start, 11868)
        XCTAssertEqual(ddx11l1?.end, 14409)
    }

    func testExonCoordinates() async throws {
        let url = try sampleGTFURL()
        let reader = GTFReader(url: url)
        let features = try await reader.readAllFeatures()

        // First exon: GTF 11869-12227
        let firstExon = features.filter { $0.type == "exon" && $0.transcriptID == "ENST00000456328" }
            .sorted { $0.start < $1.start }
            .first
        XCTAssertNotNil(firstExon)
        XCTAssertEqual(firstExon?.start, 11869)
        XCTAssertEqual(firstExon?.end, 12227)

        // As annotation: 0-based half-open
        let annotations = try await reader.readAll()
        let exonAnnotations = annotations.filter {
            $0.type == .exon && $0.qualifier("transcript_id") == "ENST00000456328"
        }.sorted { $0.start < $1.start }
        XCTAssertGreaterThan(exonAnnotations.count, 0)
        XCTAssertEqual(exonAnnotations[0].start, 11868) // 11869 - 1
        XCTAssertEqual(exonAnnotations[0].end, 12227)   // same
    }

    // MARK: - Strand Tests

    func testStrandParsing() async throws {
        let url = try sampleGTFURL()
        let reader = GTFReader(url: url)
        let features = try await reader.readAllFeatures()

        // DDX11L1 gene is on + strand
        let ddx11l1 = features.first { $0.geneID == "ENSG00000223972" && $0.type == "gene" }
        XCTAssertEqual(ddx11l1?.strand, .forward)

        // WASH7P gene is on - strand
        let wash7p = features.first { $0.geneID == "ENSG00000227232" && $0.type == "gene" }
        XCTAssertEqual(wash7p?.strand, .reverse)
    }

    func testStrandAnnotationConversion() async throws {
        let url = try sampleGTFURL()
        let reader = GTFReader(url: url)
        let annotations = try await reader.readAll()

        let forwardCount = annotations.filter { $0.strand == .forward }.count
        let reverseCount = annotations.filter { $0.strand == .reverse }.count

        // DDX11L1: 1 gene + 1 transcript + 3 exons = 5 forward
        XCTAssertEqual(forwardCount, 5)
        // WASH7P: 1 gene + 1 transcript + 2 exons + 1 CDS = 5 reverse
        XCTAssertEqual(reverseCount, 5)
    }

    func testUnknownStrand() async throws {
        let gtf = """
        chr1\ttest\tgene\t1\t100\t.\t.\t.\tgene_id "g1"; gene_name "unknown_strand";
        """
        let url = try createTempFile(content: gtf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GTFReader(url: url)
        let features = try await reader.readAllFeatures()
        XCTAssertEqual(features[0].strand, .unknown)
    }

    // MARK: - CDS and Phase Tests

    func testCDSPhase() async throws {
        let url = try sampleGTFURL()
        let reader = GTFReader(url: url)
        let features = try await reader.readAllFeatures()

        let cdsFeatures = features.filter { $0.type == "CDS" }
        XCTAssertEqual(cdsFeatures.count, 1)
        XCTAssertEqual(cdsFeatures[0].phase, 0)
    }

    func testCDSAnnotationType() async throws {
        let url = try sampleGTFURL()
        let reader = GTFReader(url: url)
        let annotations = try await reader.readAll()

        let cds = annotations.filter { $0.type == .cds }
        XCTAssertEqual(cds.count, 1)
        XCTAssertEqual(cds[0].chromosome, "chr1")
    }

    // MARK: - GTF Attribute Parsing Tests

    func testAttributeParsingQuotedValues() {
        let raw = #"gene_id "ENSG00000223972"; gene_name "DDX11L1"; level 2;"#
        let attrs = GTFReader.parseGTFAttributes(raw)

        XCTAssertEqual(attrs["gene_id"], "ENSG00000223972")
        XCTAssertEqual(attrs["gene_name"], "DDX11L1")
        XCTAssertEqual(attrs["level"], "2")
    }

    func testAttributeParsingUnquotedInteger() {
        let raw = #"gene_id "ENSG1"; exon_number 3; level 2;"#
        let attrs = GTFReader.parseGTFAttributes(raw)

        XCTAssertEqual(attrs["exon_number"], "3")
        XCTAssertEqual(attrs["level"], "2")
    }

    func testAttributeParsingTrailingSemicolon() {
        // GTF lines typically end with a trailing semicolon
        let raw = #"gene_id "G1";"#
        let attrs = GTFReader.parseGTFAttributes(raw)

        XCTAssertEqual(attrs["gene_id"], "G1")
    }

    func testAttributeParsingEmptyString() {
        let attrs = GTFReader.parseGTFAttributes("")
        XCTAssertTrue(attrs.isEmpty)
    }

    func testAttributeParsingNoQuotes() {
        // Some GTF variants don't quote integer values
        let raw = #"gene_id "G1"; score 0.95;"#
        let attrs = GTFReader.parseGTFAttributes(raw)

        XCTAssertEqual(attrs["gene_id"], "G1")
        XCTAssertEqual(attrs["score"], "0.95")
    }

    // MARK: - Comment and Header Handling

    func testSkipCommentLines() async throws {
        let gtf = """
        # comment
        ##description: test
        chr1\ttest\tgene\t1\t100\t.\t+\t.\tgene_id "g1"; gene_name "TestGene";
        """
        let url = try createTempFile(content: gtf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GTFReader(url: url)
        let annotations = try await reader.readAll()

        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations[0].name, "TestGene")
    }

    func testSkipEmptyLines() async throws {
        let gtf = """
        chr1\ttest\tgene\t1\t100\t.\t+\t.\tgene_id "g1"; gene_name "A";

        chr1\ttest\tgene\t200\t300\t.\t-\t.\tgene_id "g2"; gene_name "B";
        """
        let url = try createTempFile(content: gtf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GTFReader(url: url)
        let annotations = try await reader.readAll()

        XCTAssertEqual(annotations.count, 2)
    }

    // MARK: - Missing Attribute Handling

    func testMissingGeneNameFallsBackToGeneID() async throws {
        let gtf = """
        chr1\ttest\tgene\t1\t100\t.\t+\t.\tgene_id "ENSG00000000001";
        """
        let url = try createTempFile(content: gtf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GTFReader(url: url)
        let annotations = try await reader.readAll()

        XCTAssertEqual(annotations.count, 1)
        // Name should fall back to gene_id when gene_name is absent
        XCTAssertEqual(annotations[0].name, "ENSG00000000001")
    }

    func testMissingBothNameAndIDFallsBackToType() async throws {
        let gtf = """
        chr1\ttest\texon\t1\t100\t.\t+\t.\tlevel 2;
        """
        let url = try createTempFile(content: gtf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GTFReader(url: url)
        let annotations = try await reader.readAll()

        XCTAssertEqual(annotations.count, 1)
        // With no gene_name and no gene_id, name falls back to the feature type
        XCTAssertEqual(annotations[0].name, "exon")
    }

    func testMissingScoreIsDot() async throws {
        let url = try sampleGTFURL()
        let reader = GTFReader(url: url)
        let features = try await reader.readAllFeatures()

        // All features in sample.gtf have "." as score
        for feature in features {
            XCTAssertNil(feature.score)
        }
    }

    // MARK: - Error Handling

    func testInvalidLineThrows() async throws {
        let gtf = """
        chr1\ttest\tgene
        """
        let url = try createTempFile(content: gtf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GTFReader(url: url)

        do {
            _ = try await reader.readAll()
            XCTFail("Expected GTFError to be thrown")
        } catch let error as GTFError {
            switch error {
            case .invalidLineFormat(let line, let expected, let got):
                XCTAssertEqual(line, 1)
                XCTAssertEqual(expected, 9)
                XCTAssertEqual(got, 3)
            default:
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testInvalidCoordinateThrows() async throws {
        let gtf = """
        chr1\ttest\tgene\tABC\t100\t.\t+\t.\tgene_id "g1";
        """
        let url = try createTempFile(content: gtf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GTFReader(url: url)

        do {
            _ = try await reader.readAll()
            XCTFail("Expected GTFError to be thrown")
        } catch let error as GTFError {
            switch error {
            case .invalidCoordinate(let line, let field, let value):
                XCTAssertEqual(line, 1)
                XCTAssertEqual(field, "start")
                XCTAssertEqual(value, "ABC")
            default:
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testStartGreaterThanEndThrows() async throws {
        let gtf = """
        chr1\ttest\tgene\t500\t100\t.\t+\t.\tgene_id "g1";
        """
        let url = try createTempFile(content: gtf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GTFReader(url: url)

        do {
            _ = try await reader.readAll()
            XCTFail("Expected GTFError to be thrown")
        } catch let error as GTFError {
            switch error {
            case .invalidCoordinateRange(let line, let start, let end):
                XCTAssertEqual(line, 1)
                XCTAssertEqual(start, 500)
                XCTAssertEqual(end, 100)
            default:
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testInvalidCoordinateRangeCanBeDisabled() async throws {
        let gtf = """
        chr1\ttest\tgene\t500\t100\t.\t+\t.\tgene_id "g1";
        """
        let url = try createTempFile(content: gtf)
        defer { try? FileManager.default.removeItem(at: url) }

        // Disable coordinate validation
        let reader = GTFReader(url: url, validateCoordinates: false)
        let features = try await reader.readAllFeatures()

        XCTAssertEqual(features.count, 1)
        XCTAssertEqual(features[0].start, 500)
        XCTAssertEqual(features[0].end, 100)
    }

    // MARK: - Annotation Type Mapping

    func testFeatureTypeMapping() async throws {
        let gtf = """
        chr1\ttest\tgene\t1\t100\t.\t+\t.\tgene_id "g1";
        chr1\ttest\ttranscript\t1\t100\t.\t+\t.\tgene_id "g1"; transcript_id "t1";
        chr1\ttest\texon\t1\t50\t.\t+\t.\tgene_id "g1"; transcript_id "t1";
        chr1\ttest\tCDS\t10\t40\t.\t+\t0\tgene_id "g1"; transcript_id "t1";
        chr1\ttest\tfive_prime_UTR\t1\t9\t.\t+\t.\tgene_id "g1"; transcript_id "t1";
        chr1\ttest\tthree_prime_UTR\t41\t50\t.\t+\t.\tgene_id "g1"; transcript_id "t1";
        """
        let url = try createTempFile(content: gtf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GTFReader(url: url)
        let annotations = try await reader.readAll()

        XCTAssertEqual(annotations.count, 6)
        XCTAssertEqual(annotations[0].type, .gene)
        XCTAssertEqual(annotations[1].type, .transcript)
        XCTAssertEqual(annotations[2].type, .exon)
        XCTAssertEqual(annotations[3].type, .cds)
        XCTAssertEqual(annotations[4].type, .utr5)
        XCTAssertEqual(annotations[5].type, .utr3)
    }

    func testUnknownFeatureTypeFallsBackToRegion() async throws {
        let gtf = """
        chr1\ttest\tselenocysteine\t1\t100\t.\t+\t.\tgene_id "g1";
        """
        let url = try createTempFile(content: gtf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GTFReader(url: url)
        let annotations = try await reader.readAll()

        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations[0].type, .region)
    }

    // MARK: - Grouped Reading

    func testReadGroupedBySequence() async throws {
        let gtf = """
        chr1\ttest\tgene\t1\t100\t.\t+\t.\tgene_id "g1"; gene_name "A";
        chr2\ttest\tgene\t1\t200\t.\t-\t.\tgene_id "g2"; gene_name "B";
        chr1\ttest\texon\t10\t50\t.\t+\t.\tgene_id "g1"; transcript_id "t1";
        """
        let url = try createTempFile(content: gtf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GTFReader(url: url)
        let grouped = try await reader.readGroupedBySequence()

        XCTAssertEqual(grouped.keys.count, 2)
        XCTAssertEqual(grouped["chr1"]?.count, 2)
        XCTAssertEqual(grouped["chr2"]?.count, 1)
    }

    // MARK: - GTFFeature Identity

    func testGTFFeatureIDForGene() async throws {
        let url = try sampleGTFURL()
        let reader = GTFReader(url: url)
        let features = try await reader.readAllFeatures()

        let gene = features.first { $0.type == "gene" }
        XCTAssertNotNil(gene)
        // Gene ID should be the gene_id attribute
        XCTAssertEqual(gene?.id, "ENSG00000223972")
    }

    func testGTFFeatureIDForTranscript() async throws {
        let url = try sampleGTFURL()
        let reader = GTFReader(url: url)
        let features = try await reader.readAllFeatures()

        let transcript = features.first { $0.type == "transcript" }
        XCTAssertNotNil(transcript)
        // Transcript ID should be the transcript_id attribute
        XCTAssertEqual(transcript?.id, "ENST00000456328")
    }

    // MARK: - GTFStatistics

    func testStatistics() async throws {
        let url = try sampleGTFURL()
        let reader = GTFReader(url: url)
        let features = try await reader.readAllFeatures()

        let stats = GTFStatistics(features: features)

        XCTAssertEqual(stats.featureCount, 10)
        XCTAssertEqual(stats.geneCount, 2)
        XCTAssertEqual(stats.transcriptCount, 2)
        XCTAssertEqual(stats.sequenceCount, 1) // all on chr1
        XCTAssertEqual(stats.featuresByType["gene"], 2)
        XCTAssertEqual(stats.featuresByType["transcript"], 2)
        XCTAssertEqual(stats.featuresByType["exon"], 5)
        XCTAssertEqual(stats.featuresByType["CDS"], 1)
    }

    // MARK: - Chromosome Assignment

    func testAllAnnotationsHaveChromosome() async throws {
        let url = try sampleGTFURL()
        let reader = GTFReader(url: url)
        let annotations = try await reader.readAll()

        for annotation in annotations {
            XCTAssertNotNil(annotation.chromosome, "Every annotation should have chromosome set")
            XCTAssertEqual(annotation.chromosome, "chr1")
        }
    }

    // MARK: - Format Registry Integration

    func testGTFFormatDetection() async throws {
        let url = try sampleGTFURL()
        let format = await FormatRegistry.shared.detectFormat(url: url)
        XCTAssertEqual(format, .gtf)
    }

    func testGTFImporterRegistered() async throws {
        let importer = await FormatRegistry.shared.importer(for: .gtf)
        XCTAssertNotNil(importer, "GTF importer should be registered")
    }

    func testGTFImportViaRegistry() async throws {
        let url = try sampleGTFURL()
        let result = try await FormatRegistry.shared.importDocument(from: url)

        XCTAssertEqual(result.sourceFormat, .gtf)
        XCTAssertEqual(result.annotationCount, 10)
        XCTAssertTrue(result.annotationsBySequence.keys.contains("chr1"))
    }

    // MARK: - Score Parsing

    func testScoreParsing() async throws {
        let gtf = """
        chr1\ttest\tgene\t1\t100\t42.5\t+\t.\tgene_id "g1";
        chr1\ttest\tgene\t200\t300\t.\t-\t.\tgene_id "g2";
        """
        let url = try createTempFile(content: gtf)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = GTFReader(url: url)
        let features = try await reader.readAllFeatures()

        XCTAssertEqual(features[0].score, 42.5)
        XCTAssertNil(features[1].score)
    }

    // MARK: - HGNC ID in Attributes

    func testHGNCAttribute() async throws {
        let url = try sampleGTFURL()
        let reader = GTFReader(url: url)
        let features = try await reader.readAllFeatures()

        let ddx11l1 = features.first { $0.geneID == "ENSG00000223972" && $0.type == "gene" }
        XCTAssertNotNil(ddx11l1)
        XCTAssertEqual(ddx11l1?.attributes["hgnc_id"], "HGNC:37102")
    }
}
