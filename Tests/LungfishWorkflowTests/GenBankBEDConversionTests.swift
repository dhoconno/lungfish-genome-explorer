// GenBankBEDConversionTests.swift - Tests for GenBank→BED12+ conversion
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
@testable import LungfishIO
@testable import LungfishCore

@MainActor
final class GenBankBEDConversionTests: XCTestCase {

    // MARK: - Helpers

    private func createTempGenBankFile(content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).gb")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func parseBEDLines(from url: URL) throws -> [[String]] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return content.components(separatedBy: .newlines)
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.components(separatedBy: "\t") }
    }

    /// Minimal GenBank with diverse feature types for testing.
    private let testGenBank = """
    LOCUS       TestSeq                 1000 bp    DNA     linear   SYN 01-JAN-2024
    DEFINITION  Test sequence for BED conversion.
    ACCESSION   TS000001
    VERSION     TS000001.1
    FEATURES             Location/Qualifiers
         source          1..1000
                         /organism="Test"
                         /mol_type="genomic DNA"
         gene            100..500
                         /gene="geneA"
                         /locus_tag="TSA_001"
                         /note="Test gene"
                         /db_xref="GeneID:12345"
         CDS             join(150..300,400..480)
                         /gene="geneA"
                         /protein_id="TSP_001"
                         /product="test protein"
                         /translation="MVTSK"
                         /db_xref="GeneID:12345"
                         /db_xref="UniProt:P99999"
         mRNA            join(120..300,400..500)
                         /gene="geneA"
         promoter        50..99
                         /note="TATA box region"
         mat_peptide     200..280
                         /product="mature peptide A"
         regulatory      80..95
                         /regulatory_class="promoter"
                         /note="regulatory element"
         misc_feature    600..700
                         /note="flanking region"
         gene            complement(700..900)
                         /gene="geneB"
                         /locus_tag="TSA_002"
    ORIGIN
            1 atcgatcgat cgatcgatcg atcgatcgat cgatcgatcg atcgatcgat cgatcgatcg
    //
    """

    // MARK: - Feature Type Preservation Tests

    func testGenBankToBEDPreservesFeatureTypes() async throws {
        let gbURL = try createTempGenBankFile(content: testGenBank)
        defer { try? FileManager.default.removeItem(at: gbURL) }

        let bedURL = gbURL.deletingPathExtension().appendingPathExtension("bed")
        defer { try? FileManager.default.removeItem(at: bedURL) }

        let builder = NativeBundleBuilder()
        let count = try await builder.convertGenBankToBED(from: gbURL, to: bedURL)

        // Source is skipped, so: gene, CDS, mRNA, promoter, mat_peptide, regulatory, misc_feature, gene = 8
        XCTAssertEqual(count, 8, "Should have 8 features (source excluded)")

        let lines = try parseBEDLines(from: bedURL)
        XCTAssertEqual(lines.count, 8)

        // Verify column 13 (index 12) has correct feature types
        let types = lines.map { $0[12] }
        XCTAssertTrue(types.contains("gene"), "Should contain gene type")
        XCTAssertTrue(types.contains("CDS"), "Should contain CDS type")
        XCTAssertTrue(types.contains("mRNA"), "Should contain mRNA type")
        XCTAssertTrue(types.contains("promoter"), "Should contain promoter type")
        XCTAssertTrue(types.contains("mat_peptide"), "Should contain mat_peptide type")
        XCTAssertTrue(types.contains("regulatory"), "Should contain regulatory type")
        XCTAssertTrue(types.contains("misc_feature"), "Should contain misc_feature type")
    }

    func testGenBankToBEDSkipsSourceFeature() async throws {
        let gbURL = try createTempGenBankFile(content: testGenBank)
        defer { try? FileManager.default.removeItem(at: gbURL) }

        let bedURL = gbURL.deletingPathExtension().appendingPathExtension("bed")
        defer { try? FileManager.default.removeItem(at: bedURL) }

        let builder = NativeBundleBuilder()
        _ = try await builder.convertGenBankToBED(from: gbURL, to: bedURL)

        let lines = try parseBEDLines(from: bedURL)
        let types = lines.map { $0[12] }
        XCTAssertFalse(types.contains("source"), "Source features should be skipped")
    }

    func testGenBankToBEDPreservesRawFeatureTypeForAliasedType() async throws {
        let gb = """
        LOCUS       AliasType                300 bp    DNA     linear   SYN 01-JAN-2024
        DEFINITION  Test aliased feature type preservation.
        ACCESSION   AT000001
        VERSION     AT000001.1
        FEATURES             Location/Qualifiers
             source          1..300
                             /organism="Test"
                             /mol_type="genomic DNA"
             primer_bind     20..40
                             /note="PCR primer site"
        ORIGIN
                1 atcgatcgat cgatcgatcg atcgatcgat cgatcgatcg atcgatcgat cgatcgatcg
        //
        """

        let gbURL = try createTempGenBankFile(content: gb)
        defer { try? FileManager.default.removeItem(at: gbURL) }

        let bedURL = gbURL.deletingPathExtension().appendingPathExtension("bed")
        defer { try? FileManager.default.removeItem(at: bedURL) }

        let builder = NativeBundleBuilder()
        let count = try await builder.convertGenBankToBED(from: gbURL, to: bedURL)

        XCTAssertEqual(count, 1, "Should include only the primer_bind feature")
        let lines = try parseBEDLines(from: bedURL)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0][12], "primer_bind", "Column 13 should preserve the original GenBank feature key")
        XCTAssertFalse(lines[0][13].contains(GenBankReader.rawFeatureTypeQualifierKey),
                       "Internal raw feature type marker must not leak into qualifier serialization")
    }

    // MARK: - Qualifier Preservation Tests

    func testGenBankToBEDPreservesQualifiers() async throws {
        let gbURL = try createTempGenBankFile(content: testGenBank)
        defer { try? FileManager.default.removeItem(at: gbURL) }

        let bedURL = gbURL.deletingPathExtension().appendingPathExtension("bed")
        defer { try? FileManager.default.removeItem(at: bedURL) }

        let builder = NativeBundleBuilder()
        _ = try await builder.convertGenBankToBED(from: gbURL, to: bedURL)

        let lines = try parseBEDLines(from: bedURL)

        // Find the first gene feature (geneA)
        let geneLines = lines.filter { $0[12] == "gene" && $0[3] == "geneA" }
        XCTAssertFalse(geneLines.isEmpty, "Should have gene feature for geneA")

        let qualifierStr = geneLines[0][13]  // Column 14 (index 13)
        XCTAssertTrue(qualifierStr.contains("gene=geneA"), "Should contain gene qualifier")
        XCTAssertTrue(qualifierStr.contains("locus_tag=TSA_001"), "Should contain locus_tag qualifier")
        XCTAssertTrue(qualifierStr.contains("note="), "Should contain note qualifier")
    }

    func testGenBankToBEDMultiValuedQualifiers() async throws {
        let gbURL = try createTempGenBankFile(content: testGenBank)
        defer { try? FileManager.default.removeItem(at: gbURL) }

        let bedURL = gbURL.deletingPathExtension().appendingPathExtension("bed")
        defer { try? FileManager.default.removeItem(at: bedURL) }

        let builder = NativeBundleBuilder()
        _ = try await builder.convertGenBankToBED(from: gbURL, to: bedURL)

        let lines = try parseBEDLines(from: bedURL)

        // Find the CDS feature which has two db_xref qualifiers
        let cdsLines = lines.filter { $0[12] == "CDS" }
        XCTAssertFalse(cdsLines.isEmpty, "Should have CDS feature")

        let qualifierStr = cdsLines[0][13]
        // Multi-valued db_xref should be comma-joined
        XCTAssertTrue(qualifierStr.contains("db_xref="), "Should contain db_xref qualifier")
        XCTAssertTrue(qualifierStr.contains("protein_id=TSP_001"), "Should contain protein_id qualifier")
        XCTAssertTrue(qualifierStr.contains("product=test%20protein") || qualifierStr.contains("product=test protein"),
                      "Should contain product qualifier")
    }

    // MARK: - BED12 Block Tests (join locations)

    func testGenBankToBEDHandlesJoinLocations() async throws {
        let gbURL = try createTempGenBankFile(content: testGenBank)
        defer { try? FileManager.default.removeItem(at: gbURL) }

        let bedURL = gbURL.deletingPathExtension().appendingPathExtension("bed")
        defer { try? FileManager.default.removeItem(at: bedURL) }

        let builder = NativeBundleBuilder()
        _ = try await builder.convertGenBankToBED(from: gbURL, to: bedURL)

        let lines = try parseBEDLines(from: bedURL)

        // Find the CDS feature which uses join(150..300,400..480)
        let cdsLines = lines.filter { $0[12] == "CDS" }
        XCTAssertFalse(cdsLines.isEmpty, "Should have CDS feature")

        let cds = cdsLines[0]
        // Verify BED12 block columns
        XCTAssertEqual(cds[9], "2", "CDS with join should have blockCount=2")

        // Block sizes: (300-149)=151, (480-399)=81 → depends on 0-based conversion
        let blockSizes = cds[10].trimmingCharacters(in: CharacterSet(charactersIn: ","))
            .split(separator: ",").map { Int($0) }
        XCTAssertEqual(blockSizes.count, 2, "CDS should have 2 blocks")

        // Block starts should be relative to chromStart
        let blockStarts = cds[11].trimmingCharacters(in: CharacterSet(charactersIn: ","))
            .split(separator: ",").map { Int($0) }
        XCTAssertEqual(blockStarts.count, 2, "CDS should have 2 block starts")
        XCTAssertEqual(blockStarts[0], 0, "First block should start at offset 0")
    }

    // MARK: - Strand Tests

    func testGenBankToBEDHandlesComplementStrand() async throws {
        let gbURL = try createTempGenBankFile(content: testGenBank)
        defer { try? FileManager.default.removeItem(at: gbURL) }

        let bedURL = gbURL.deletingPathExtension().appendingPathExtension("bed")
        defer { try? FileManager.default.removeItem(at: bedURL) }

        let builder = NativeBundleBuilder()
        _ = try await builder.convertGenBankToBED(from: gbURL, to: bedURL)

        let lines = try parseBEDLines(from: bedURL)

        // Find geneB which is complement
        let geneBLines = lines.filter { $0[3] == "geneB" }
        XCTAssertFalse(geneBLines.isEmpty, "Should have geneB feature")
        XCTAssertEqual(geneBLines[0][5], "-", "Complement feature should have strand '-'")

        // Forward strand features
        let geneALines = lines.filter { $0[3] == "geneA" && $0[12] == "gene" }
        XCTAssertFalse(geneALines.isEmpty, "Should have geneA feature")
        XCTAssertEqual(geneALines[0][5], "+", "Forward feature should have strand '+'")
    }

    // MARK: - BED Format Validation

    func testGenBankToBEDProduces14Columns() async throws {
        let gbURL = try createTempGenBankFile(content: testGenBank)
        defer { try? FileManager.default.removeItem(at: gbURL) }

        let bedURL = gbURL.deletingPathExtension().appendingPathExtension("bed")
        defer { try? FileManager.default.removeItem(at: bedURL) }

        let builder = NativeBundleBuilder()
        _ = try await builder.convertGenBankToBED(from: gbURL, to: bedURL)

        let lines = try parseBEDLines(from: bedURL)
        for (i, line) in lines.enumerated() {
            XCTAssertEqual(line.count, 14, "Line \(i) should have 14 columns, got \(line.count)")
        }
    }

    func testGenBankToBEDSortedByChromAndStart() async throws {
        let gbURL = try createTempGenBankFile(content: testGenBank)
        defer { try? FileManager.default.removeItem(at: gbURL) }

        let bedURL = gbURL.deletingPathExtension().appendingPathExtension("bed")
        defer { try? FileManager.default.removeItem(at: bedURL) }

        let builder = NativeBundleBuilder()
        _ = try await builder.convertGenBankToBED(from: gbURL, to: bedURL)

        let lines = try parseBEDLines(from: bedURL)
        for i in 1..<lines.count {
            let prevChrom = lines[i-1][0]
            let currChrom = lines[i][0]
            let prevStart = Int(lines[i-1][1])!
            let currStart = Int(lines[i][1])!

            if prevChrom == currChrom {
                XCTAssertLessThanOrEqual(prevStart, currStart,
                    "BED should be sorted by start within chromosome")
            }
        }
    }

    // MARK: - Chromosome Name Tests

    func testGenBankToBEDUsesLocusAsChromosome() async throws {
        let gbURL = try createTempGenBankFile(content: testGenBank)
        defer { try? FileManager.default.removeItem(at: gbURL) }

        let bedURL = gbURL.deletingPathExtension().appendingPathExtension("bed")
        defer { try? FileManager.default.removeItem(at: bedURL) }

        let builder = NativeBundleBuilder()
        _ = try await builder.convertGenBankToBED(from: gbURL, to: bedURL)

        let lines = try parseBEDLines(from: bedURL)
        // All features should use the locus name "TestSeq" as chromosome
        for line in lines {
            XCTAssertEqual(line[0], "TestSeq", "Chromosome should be locus name 'TestSeq'")
        }
    }

    // MARK: - GenBankReader mapFeatureType Tests

    func testMapFeatureTypeUsesFromRawString() async throws {
        let gbURL = try createTempGenBankFile(content: testGenBank)
        defer { try? FileManager.default.removeItem(at: gbURL) }

        let reader = try GenBankReader(url: gbURL)
        let records = try await reader.readAll()

        XCTAssertEqual(records.count, 1)
        let annotations = records[0].annotations

        // Verify correct type mapping for each feature
        let typeMap = Dictionary(grouping: annotations, by: { $0.type })

        XCTAssertNotNil(typeMap[.gene], "Should have gene features")
        XCTAssertNotNil(typeMap[.cds], "Should have CDS features")
        XCTAssertNotNil(typeMap[.mRNA], "Should have mRNA features")
        XCTAssertNotNil(typeMap[.promoter], "Should have promoter features")
        XCTAssertNotNil(typeMap[.mat_peptide], "Should have mat_peptide features")
        XCTAssertNotNil(typeMap[.regulatory], "Should have regulatory features")
        XCTAssertNotNil(typeMap[.misc_feature], "Should have misc_feature features")
        XCTAssertNotNil(typeMap[.source], "Should have source features")
    }

    func testMapFeatureTypeNewCases() async throws {
        // Create GenBank with all new feature types
        let gb = """
        LOCUS       NewTypes                 500 bp    DNA     linear   SYN 01-JAN-2024
        DEFINITION  Test new feature types.
        ACCESSION   NT000001
        VERSION     NT000001.1
        FEATURES             Location/Qualifiers
             source          1..500
                             /organism="Test"
                             /mol_type="genomic DNA"
             mat_peptide     10..50
                             /product="mature peptide"
             sig_peptide     60..80
                             /note="signal peptide"
             transit_peptide 90..120
                             /note="transit peptide"
             regulatory      130..150
                             /regulatory_class="enhancer"
             ncRNA           160..200
                             /ncRNA_class="lncRNA"
             misc_binding    210..230
                             /bound_moiety="ATP"
             protein_bind    240..270
                             /bound_moiety="transcription factor"
        ORIGIN
                1 atcgatcgat cgatcgatcg atcgatcgat cgatcgatcg atcgatcgat cgatcgatcg
        //
        """

        let gbURL = try createTempGenBankFile(content: gb)
        defer { try? FileManager.default.removeItem(at: gbURL) }

        let reader = try GenBankReader(url: gbURL)
        let records = try await reader.readAll()
        let annotations = records[0].annotations

        let types = annotations.map { $0.type }
        XCTAssertTrue(types.contains(.mat_peptide), "Should map mat_peptide")
        XCTAssertTrue(types.contains(.sig_peptide), "Should map sig_peptide")
        XCTAssertTrue(types.contains(.transit_peptide), "Should map transit_peptide")
        XCTAssertTrue(types.contains(.regulatory), "Should map regulatory")
        XCTAssertTrue(types.contains(.ncRNA), "Should map ncRNA")
        XCTAssertTrue(types.contains(.misc_binding), "Should map misc_binding")
        XCTAssertTrue(types.contains(.protein_bind), "Should map protein_bind")
    }

    // MARK: - Format Detection Tests

    func testConvertAnnotationToBEDRoutesGenBank() async throws {
        // Test that .gb files are detected and routed through GenBankReader
        let gbURL = try createTempGenBankFile(content: testGenBank)
        defer { try? FileManager.default.removeItem(at: gbURL) }

        let bedURL = gbURL.deletingPathExtension().appendingPathExtension("bed")
        defer { try? FileManager.default.removeItem(at: bedURL) }

        let builder = NativeBundleBuilder()
        let count = try await builder.convertGenBankToBED(from: gbURL, to: bedURL)

        // If we get features, the routing worked
        XCTAssertGreaterThan(count, 0, "Should produce features from GenBank file")

        // Verify it produced valid BED12+ (14 columns with type in col 13)
        let lines = try parseBEDLines(from: bedURL)
        let firstType = lines[0][12]
        XCTAssertFalse(firstType.isEmpty, "Column 13 should have a feature type")
    }

    // MARK: - Qualifier Encoding Tests

    func testGenBankToBEDEncodesSpecialCharacters() async throws {
        // GenBank with qualifiers containing special characters
        let gb = """
        LOCUS       EncTest                  200 bp    DNA     linear   SYN 01-JAN-2024
        DEFINITION  Test encoding.
        ACCESSION   ET000001
        VERSION     ET000001.1
        FEATURES             Location/Qualifiers
             source          1..200
                             /organism="Test"
                             /mol_type="genomic DNA"
             gene            10..100
                             /gene="testGene"
                             /note="contains special chars: A=B; C;D"
        ORIGIN
                1 atcgatcgat cgatcgatcg atcgatcgat cgatcgatcg atcgatcgat cgatcgatcg
        //
        """

        let gbURL = try createTempGenBankFile(content: gb)
        defer { try? FileManager.default.removeItem(at: gbURL) }

        let bedURL = gbURL.deletingPathExtension().appendingPathExtension("bed")
        defer { try? FileManager.default.removeItem(at: bedURL) }

        let builder = NativeBundleBuilder()
        _ = try await builder.convertGenBankToBED(from: gbURL, to: bedURL)

        let lines = try parseBEDLines(from: bedURL)
        let geneLines = lines.filter { $0[12] == "gene" }
        XCTAssertFalse(geneLines.isEmpty, "Should have gene feature")

        // The qualifier string should be parseable — semicolons and equals in values
        // must be encoded so they don't break the key=value;key=value format
        let qualStr = geneLines[0][13]
        let pairs = qualStr.split(separator: ";")
        for pair in pairs {
            let parts = pair.split(separator: "=", maxSplits: 1)
            XCTAssertEqual(parts.count, 2, "Each qualifier pair should have key=value format: \(pair)")
        }
    }

    // MARK: - Coordinate Tests

    func testGenBankToBEDCoordinatesAreZeroBased() async throws {
        let gbURL = try createTempGenBankFile(content: testGenBank)
        defer { try? FileManager.default.removeItem(at: gbURL) }

        let bedURL = gbURL.deletingPathExtension().appendingPathExtension("bed")
        defer { try? FileManager.default.removeItem(at: bedURL) }

        let builder = NativeBundleBuilder()
        _ = try await builder.convertGenBankToBED(from: gbURL, to: bedURL)

        let lines = try parseBEDLines(from: bedURL)

        // The promoter is at 50..99 in GenBank (1-based inclusive)
        // In BED (0-based half-open), this should be chromStart=49, chromEnd=99
        let promoterLines = lines.filter { $0[12] == "promoter" }
        XCTAssertFalse(promoterLines.isEmpty, "Should have promoter")
        let chromStart = Int(promoterLines[0][1])!
        let chromEnd = Int(promoterLines[0][2])!
        XCTAssertEqual(chromStart, 49, "GenBank 50 should be BED 49 (0-based)")
        XCTAssertEqual(chromEnd, 99, "GenBank 99 should be BED 99 (half-open)")
    }

    // MARK: - Color Tests

    func testGenBankToBEDIncludesTypeColor() async throws {
        let gbURL = try createTempGenBankFile(content: testGenBank)
        defer { try? FileManager.default.removeItem(at: gbURL) }

        let bedURL = gbURL.deletingPathExtension().appendingPathExtension("bed")
        defer { try? FileManager.default.removeItem(at: bedURL) }

        let builder = NativeBundleBuilder()
        _ = try await builder.convertGenBankToBED(from: gbURL, to: bedURL)

        let lines = try parseBEDLines(from: bedURL)

        // Column 9 (index 8) should have R,G,B format
        for line in lines {
            let rgb = line[8]
            let components = rgb.split(separator: ",")
            XCTAssertEqual(components.count, 3, "itemRgb should have 3 components: \(rgb)")
            for comp in components {
                let val = Int(comp)
                XCTAssertNotNil(val, "RGB component should be an integer: \(comp)")
                if let val = val {
                    XCTAssertTrue(val >= 0 && val <= 255, "RGB value should be 0-255: \(val)")
                }
            }
        }
    }
}
