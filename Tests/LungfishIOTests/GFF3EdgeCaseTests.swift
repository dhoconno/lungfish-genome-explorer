// GFF3EdgeCaseTests.swift - Edge case tests for GFF3 parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishCore

final class GFF3EdgeCaseTests: XCTestCase {
    
    // MARK: - Helpers
    
    func createTempFile(content: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "test_\(UUID().uuidString).gff3"
        let url = tempDir.appendingPathComponent(fileName)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    
    // MARK: - URL Encoding Tests
    
    func testUrlDecodingSemicolon() async throws {
        // Semicolon in value should be encoded as %3B
        let gff = "chr1\ttest\tgene\t1\t100\t.\t+\t.\tID=gene1;Note=Contains%3Bsemicolon"
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }
        
        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)
        
        XCTAssertEqual(features.count, 1)
        XCTAssertEqual(features[0].attributes["Note"], "Contains;semicolon")
    }
    
    func testUrlDecodingEquals() async throws {
        // Equals sign in value should be encoded as %3D
        let gff = "chr1\ttest\tgene\t1\t100\t.\t+\t.\tID=gene1;Note=Key%3DValue"
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }
        
        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)
        
        XCTAssertEqual(features[0].attributes["Note"], "Key=Value")
    }
    
    func testUrlDecodingAmpersand() async throws {
        let gff = "chr1\ttest\tgene\t1\t100\t.\t+\t.\tID=gene1;Note=A%26B"
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }
        
        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)
        
        XCTAssertEqual(features[0].attributes["Note"], "A&B")
    }
    
    func testUrlDecodingComma() async throws {
        let gff = "chr1\ttest\tgene\t1\t100\t.\t+\t.\tID=gene1;Note=A%2CB"
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }
        
        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)
        
        XCTAssertEqual(features[0].attributes["Note"], "A,B")
    }
    
    func testUrlDecodingPercent() async throws {
        // Percent sign should be encoded last to avoid double-decoding
        let gff = "chr1\ttest\tgene\t1\t100\t.\t+\t.\tID=gene1;Note=100%25complete"
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }
        
        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)
        
        XCTAssertEqual(features[0].attributes["Note"], "100%complete")
    }
    
    func testUrlDecodingCombined() async throws {
        // Multiple encoded chars
        let gff = "chr1\ttest\tgene\t1\t100\t.\t+\t.\tID=gene1;Note=A%3BB%3DC%26D%2CE%25F"
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }
        
        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)
        
        XCTAssertEqual(features[0].attributes["Note"], "A;B=C&D,E%F")
    }
    
    // MARK: - Strand Tests
    
    func testAllStrandTypes() async throws {
        let gff = """
        chr1\ttest\tgene\t1\t100\t.\t+\t.\tID=forward
        chr1\ttest\tgene\t1\t100\t.\t-\t.\tID=reverse
        chr1\ttest\tgene\t1\t100\t.\t.\t.\tID=unstranded
        chr1\ttest\tgene\t1\t100\t.\t?\t.\tID=unknown
        """
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }
        
        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)
        
        XCTAssertEqual(features[0].strand, .forward)
        XCTAssertEqual(features[1].strand, .reverse)
        XCTAssertEqual(features[2].strand, .unknown)
        XCTAssertEqual(features[3].strand, .unknown) // ? also maps to unknown
    }
    
    // MARK: - Score Tests
    
    func testScoreParsing() async throws {
        let gff = """
        chr1\ttest\tgene\t1\t100\t.\t+\t.\tID=no_score
        chr1\ttest\tgene\t1\t100\t0.5\t+\t.\tID=half_score
        chr1\ttest\tgene\t1\t100\t100\t+\t.\tID=full_score
        chr1\ttest\tgene\t1\t100\t1e-10\t+\t.\tID=scientific
        """
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }
        
        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)
        
        XCTAssertNil(features[0].score)
        XCTAssertEqual(features[1].score, 0.5)
        XCTAssertEqual(features[2].score, 100.0)
        XCTAssertEqual(features[3].score!, 1e-10, accuracy: 1e-15)
    }
    
    // MARK: - Phase Tests
    
    func testPhaseParsing() async throws {
        let gff = """
        chr1\ttest\tCDS\t1\t100\t.\t+\t0\tID=phase0
        chr1\ttest\tCDS\t1\t100\t.\t+\t1\tID=phase1
        chr1\ttest\tCDS\t1\t100\t.\t+\t2\tID=phase2
        chr1\ttest\tCDS\t1\t100\t.\t+\t.\tID=no_phase
        """
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }
        
        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)
        
        XCTAssertEqual(features[0].phase, 0)
        XCTAssertEqual(features[1].phase, 1)
        XCTAssertEqual(features[2].phase, 2)
        XCTAssertNil(features[3].phase)
    }
    
    // MARK: - Type Mapping Tests
    
    func testAnnotationTypeMapping() async throws {
        let gff = """
        chr1\ttest\tgene\t1\t100\t.\t+\t.\tID=f1
        chr1\ttest\tCDS\t1\t100\t.\t+\t0\tID=f2
        chr1\ttest\texon\t1\t100\t.\t+\t.\tID=f3
        chr1\ttest\tmRNA\t1\t100\t.\t+\t.\tID=f4
        chr1\ttest\ttranscript\t1\t100\t.\t+\t.\tID=f5
        chr1\ttest\tintron\t1\t100\t.\t+\t.\tID=f6
        chr1\ttest\tfive_prime_UTR\t1\t100\t.\t+\t.\tID=f7
        chr1\ttest\tthree_prime_UTR\t1\t100\t.\t+\t.\tID=f8
        chr1\ttest\tpromoter\t1\t100\t.\t+\t.\tID=f9
        chr1\ttest\tunknown_type\t1\t100\t.\t+\t.\tID=f10
        """
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }
        
        let reader = GFF3Reader()
        let annotations = try await reader.readAsAnnotations(from: url)
        
        XCTAssertEqual(annotations[0].type, .gene)
        XCTAssertEqual(annotations[1].type, .cds)
        XCTAssertEqual(annotations[2].type, .exon)
        XCTAssertEqual(annotations[3].type, .mRNA)
        XCTAssertEqual(annotations[4].type, .mRNA) // transcript -> mRNA
        XCTAssertEqual(annotations[5].type, .intron)
        XCTAssertEqual(annotations[6].type, .utr5)
        XCTAssertEqual(annotations[7].type, .utr3)
        XCTAssertEqual(annotations[8].type, .promoter)
        XCTAssertEqual(annotations[9].type, .region) // unknown -> region
    }
    
    // MARK: - FASTA Directive Test
    
    func testFastaDirectiveStopsReading() async throws {
        let gff = """
        chr1\ttest\tgene\t1\t100\t.\t+\t.\tID=gene1
        chr1\ttest\texon\t10\t50\t.\t+\t.\tID=exon1
        ##FASTA
        >chr1
        ATGCATGCATGC
        """
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }
        
        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)
        
        // Should only have 2 features, FASTA section should be ignored
        XCTAssertEqual(features.count, 2)
    }
    
    // MARK: - Header Pragma Tests
    
    func testPragmasSkipped() async throws {
        let gff = """
        ##gff-version 3
        ##sequence-region chr1 1 1000
        ##species https://www.ncbi.nlm.nih.gov/Taxonomy/Browser/wwwtax.cgi?id=9606
        # Regular comment
        chr1\ttest\tgene\t1\t100\t.\t+\t.\tID=gene1
        """
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }
        
        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)
        
        // All pragmas and comments should be skipped
        XCTAssertEqual(features.count, 1)
    }
    
    // MARK: - Multiple Parents Test
    
    func testMultipleParentValues() async throws {
        // GFF3 allows comma-separated multiple parents
        let gff = """
        chr1\ttest\tgene\t1\t1000\t.\t+\t.\tID=gene1
        chr1\ttest\tgene\t1\t1000\t.\t+\t.\tID=gene2
        chr1\ttest\texon\t100\t200\t.\t+\t.\tID=exon1;Parent=gene1,gene2
        """
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }
        
        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)
        
        let exon = features.first { $0.type == "exon" }
        XCTAssertNotNil(exon)
        
        // Parent attribute contains comma-separated values
        XCTAssertEqual(exon?.attributes["Parent"], "gene1,gene2")
    }
    
    // MARK: - Empty Lines Test
    
    func testEmptyLinesHandled() async throws {
        let gff = """

        chr1\ttest\tgene\t1\t100\t.\t+\t.\tID=gene1

        chr1\ttest\texon\t10\t50\t.\t+\t.\tID=exon1

        """
        let url = try createTempFile(content: gff)
        defer { try? FileManager.default.removeItem(at: url) }
        
        let reader = GFF3Reader()
        let features = try await reader.readAll(from: url)
        
        XCTAssertEqual(features.count, 2)
    }
}
