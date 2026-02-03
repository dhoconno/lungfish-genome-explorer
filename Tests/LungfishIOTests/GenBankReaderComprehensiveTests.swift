// GenBankReaderComprehensiveTests.swift - Comprehensive tests for GenBank file parsing
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishCore

final class GenBankReaderComprehensiveTests: XCTestCase {

    // MARK: - Test File Parsing

    /// Tests comprehensive parsing of test_annotated.gb
    func testParseAnnotatedGenBankFile() async throws {
        let testFileURL = URL(fileURLWithPath: "/Users/dho/Desktop/test2/My Genome Project.lungfish/test_annotated.gb")

        guard FileManager.default.fileExists(atPath: testFileURL.path) else {
            XCTFail("Test file not found at \(testFileURL.path)")
            return
        }

        let reader = try GenBankReader(url: testFileURL)
        let records = try await reader.readAll()

        // Should have 2 records in the file
        XCTAssertEqual(records.count, 2, "Should have exactly 2 records")

        // Test first record
        let record1 = records[0]
        try verifyFirstRecord(record1)

        // Test second record
        let record2 = records[1]
        try verifySecondRecord(record2)

        print("All tests passed for test_annotated.gb!")
    }

    // MARK: - First Record Tests

    private func verifyFirstRecord(_ record: GenBankRecord) throws {
        print("\n--- Verifying First Record ---")

        // LOCUS line parsing
        print("Testing LOCUS parsing...")
        XCTAssertEqual(record.locus.name, "TestGene_001", "Locus name should be TestGene_001")
        XCTAssertEqual(record.locus.length, 2500, "Locus length should be 2500")
        XCTAssertEqual(record.locus.moleculeType, .dna, "Molecule type should be DNA")
        XCTAssertEqual(record.locus.topology, .linear, "Topology should be linear")
        XCTAssertEqual(record.locus.division, "SYN", "Division should be SYN")
        print("  LOCUS: \(record.locus.name), \(record.locus.length) bp, \(record.locus.moleculeType.rawValue), \(record.locus.topology.rawValue)")

        // DEFINITION parsing
        print("Testing DEFINITION parsing...")
        XCTAssertNotNil(record.definition, "Definition should not be nil")
        XCTAssertTrue(record.definition?.contains("comprehensive annotations") ?? false,
                      "Definition should contain 'comprehensive annotations'")
        print("  DEFINITION: \(record.definition ?? "nil")")

        // ACCESSION parsing
        print("Testing ACCESSION parsing...")
        XCTAssertEqual(record.accession, "LF000001", "Accession should be LF000001")
        print("  ACCESSION: \(record.accession ?? "nil")")

        // VERSION parsing
        print("Testing VERSION parsing...")
        XCTAssertEqual(record.version, "LF000001.1", "Version should be LF000001.1")
        print("  VERSION: \(record.version ?? "nil")")

        // ORIGIN sequence parsing
        print("Testing ORIGIN sequence parsing...")
        XCTAssertEqual(record.sequence.length, 2500, "Sequence length should be 2500")
        let firstBases = record.sequence.asString().prefix(60)
        // Sequence from ORIGIN: gcgcgcgcgc gcgcgcgcgc gcgcgcgcgc gcgcgcgcgc gcgcgctata aaagcgcgcg
        XCTAssertEqual(String(firstBases).lowercased(), "gcgcgcgcgcgcgcgcgcgcgcgcgcgcgcgcgcgcgcgcgcgcgctataaaagcgcgcg",
                       "First 60 bases should match expected")
        print("  Sequence length: \(record.sequence.length)")
        print("  First 60 bases: \(firstBases.lowercased())")

        // FEATURES parsing
        print("Testing FEATURES parsing...")
        print("  Total annotations: \(record.annotations.count)")

        // Expected feature types in record 1
        try verifyFeatureTypes(record.annotations)
        try verifyJoinLocations(record.annotations)
        try verifyComplementLocations(record.annotations)
        try verifySinglePositionVariation(record.annotations)
        try verifyQualifiers(record.annotations)
        try verifyChromosomeAssignment(record.annotations, expectedChromosome: "TestGene_001")
    }

    private func verifyFeatureTypes(_ annotations: [SequenceAnnotation]) throws {
        print("  Verifying feature types...")

        let typeCount: [AnnotationType: Int] = annotations.reduce(into: [:]) { dict, ann in
            dict[ann.type, default: 0] += 1
        }

        print("    Feature type distribution:")
        for (type, count) in typeCount.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print("      - \(type.rawValue): \(count)")
        }

        // Check for expected feature types
        XCTAssertTrue(typeCount[.source, default: 0] >= 1, "Should have at least 1 source feature")
        XCTAssertTrue(typeCount[.gene, default: 0] >= 2, "Should have at least 2 gene features")
        XCTAssertTrue(typeCount[.cds, default: 0] >= 2, "Should have at least 2 CDS features")
        XCTAssertTrue(typeCount[.exon, default: 0] >= 4, "Should have at least 4 exon features")
        XCTAssertTrue(typeCount[.intron, default: 0] >= 3, "Should have at least 3 intron features")
        XCTAssertTrue(typeCount[.mRNA, default: 0] >= 1, "Should have at least 1 mRNA feature")
        XCTAssertTrue(typeCount[.promoter, default: 0] >= 1, "Should have at least 1 promoter feature")
        XCTAssertTrue(typeCount[.utr5, default: 0] >= 1, "Should have at least 1 5'UTR feature")
        XCTAssertTrue(typeCount[.utr3, default: 0] >= 1, "Should have at least 1 3'UTR feature")
        XCTAssertTrue(typeCount[.repeatRegion, default: 0] >= 1, "Should have at least 1 repeat_region feature")
        XCTAssertTrue(typeCount[.variation, default: 0] >= 2, "Should have at least 2 variation features")
        XCTAssertTrue(typeCount[.misc_feature, default: 0] >= 2, "Should have at least 2 misc_feature features")
    }

    private func verifyJoinLocations(_ annotations: [SequenceAnnotation]) throws {
        print("  Verifying join() locations...")

        // Find mRNA with join location
        let mRNAs = annotations.filter { $0.type == .mRNA }
        XCTAssertGreaterThan(mRNAs.count, 0, "Should have mRNA features")

        if let mrna = mRNAs.first {
            // mRNA join(100..300,400..700,800..1200,1300..1500) has 4 intervals
            XCTAssertEqual(mrna.intervals.count, 4, "mRNA should have 4 intervals from join()")
            XCTAssertTrue(mrna.isDiscontinuous, "mRNA should be discontinuous")

            print("    mRNA intervals:")
            for (i, interval) in mrna.intervals.enumerated() {
                // GenBank is 1-based, internal is 0-based
                // join(100..300,400..700,800..1200,1300..1500)
                // Expected 0-based: (99,300), (399,700), (799,1200), (1299,1500)
                print("      Interval \(i+1): \(interval.start+1)..\(interval.end) (0-based: \(interval.start)..\(interval.end))")
            }

            // Verify specific intervals (0-based)
            XCTAssertEqual(mrna.intervals[0].start, 99, "First interval start should be 99 (1-based: 100)")
            XCTAssertEqual(mrna.intervals[0].end, 300, "First interval end should be 300")
            XCTAssertEqual(mrna.intervals[1].start, 399, "Second interval start should be 399")
            XCTAssertEqual(mrna.intervals[1].end, 700, "Second interval end should be 700")
        }

        // Find CDS with join location
        let cdss = annotations.filter { $0.type == .cds && $0.intervals.count > 1 }
        XCTAssertGreaterThan(cdss.count, 0, "Should have CDS with join() location")

        if let cds = cdss.first {
            // CDS join(150..300,400..700,800..1200,1300..1450) has 4 intervals
            XCTAssertEqual(cds.intervals.count, 4, "CDS should have 4 intervals from join()")
            print("    CDS intervals: \(cds.intervals.count)")
        }
    }

    private func verifyComplementLocations(_ annotations: [SequenceAnnotation]) throws {
        print("  Verifying complement() locations...")

        // Find features on reverse strand
        let reverseFeatures = annotations.filter { $0.strand == .reverse }
        XCTAssertGreaterThan(reverseFeatures.count, 0, "Should have features on reverse strand")
        print("    Features on reverse strand: \(reverseFeatures.count)")

        // Gene at complement(1600..2400)
        let reverseGenes = reverseFeatures.filter { $0.type == .gene }
        XCTAssertGreaterThan(reverseGenes.count, 0, "Should have reverse-strand genes")

        if let gene = reverseGenes.first {
            XCTAssertEqual(gene.strand, .reverse, "Gene should be on reverse strand")
            XCTAssertEqual(gene.name, "testGene2", "Reverse gene should be testGene2")
            // complement(1600..2400) -> 0-based: 1599..2400
            XCTAssertEqual(gene.start, 1599, "Reverse gene start should be 1599 (1-based: 1600)")
            XCTAssertEqual(gene.end, 2400, "Reverse gene end should be 2400")
            print("    Reverse gene: \(gene.name) at \(gene.start+1)..\(gene.end) (strand: \(gene.strand))")
        }
    }

    private func verifySinglePositionVariation(_ annotations: [SequenceAnnotation]) throws {
        print("  Verifying single position features...")

        // Variation at 500 (single position)
        let variations = annotations.filter { $0.type == .variation }
        XCTAssertGreaterThanOrEqual(variations.count, 2, "Should have at least 2 variations")

        // Find the SNP at position 500
        let snp = variations.first { $0.start == 499 } // 0-based
        XCTAssertNotNil(snp, "Should have variation at position 500 (0-based: 499)")

        if let snp = snp {
            // Single position should be a 1-bp interval
            XCTAssertEqual(snp.intervals.count, 1, "Single position should have 1 interval")
            XCTAssertEqual(snp.intervals[0].start, 499, "Variation start should be 499 (1-based: 500)")
            XCTAssertEqual(snp.intervals[0].end, 500, "Variation end should be 500 (1 bp)")
            XCTAssertEqual(snp.totalLength, 1, "Single position should have length 1")
            print("    Variation at position: \(snp.start+1) (length: \(snp.totalLength))")
        }
    }

    private func verifyQualifiers(_ annotations: [SequenceAnnotation]) throws {
        print("  Verifying qualifiers...")

        // Check gene qualifiers
        let genes = annotations.filter { $0.type == .gene }
        if let gene = genes.first(where: { $0.name == "testGene1" }) {
            XCTAssertEqual(gene.qualifier("gene"), "testGene1", "gene qualifier should be testGene1")
            XCTAssertEqual(gene.qualifier("locus_tag"), "LF_0001", "locus_tag should be LF_0001")
            XCTAssertNotNil(gene.note, "Gene should have a note")
            print("    Gene qualifiers: gene=\(gene.qualifier("gene") ?? "nil"), locus_tag=\(gene.qualifier("locus_tag") ?? "nil")")
        }

        // Check CDS qualifiers (including multi-line translation)
        let cdss = annotations.filter { $0.type == .cds }
        if let cds = cdss.first(where: { $0.intervals.count > 1 }) {
            XCTAssertNotNil(cds.qualifier("translation"), "CDS should have translation")
            XCTAssertEqual(cds.qualifier("codon_start"), "1", "codon_start should be 1")
            XCTAssertEqual(cds.qualifier("protein_id"), "LFP_0001", "protein_id should be LFP_0001")

            // Check that multi-line translation was concatenated
            if let translation = cds.qualifier("translation") {
                XCTAssertTrue(translation.hasPrefix("MSKGEELFTGVVPILVELDGDVNGHKFSVSGEGEGDATYGKLTL"),
                              "Translation should start correctly")
                // Translation spans multiple lines, check it was properly joined
                XCTAssertGreaterThan(translation.count, 50, "Multi-line translation should be concatenated")
                print("    CDS translation length: \(translation.count) amino acids")
            }
        }

        // Check repeat_region qualifiers
        let repeats = annotations.filter { $0.type == .repeatRegion }
        if let repeat_region = repeats.first {
            XCTAssertEqual(repeat_region.qualifier("rpt_type"), "tandem", "rpt_type should be tandem")
            XCTAssertEqual(repeat_region.qualifier("rpt_unit_seq"), "ATGC", "rpt_unit_seq should be ATGC")
            print("    Repeat region: rpt_type=\(repeat_region.qualifier("rpt_type") ?? "nil")")
        }
    }

    private func verifyChromosomeAssignment(_ annotations: [SequenceAnnotation], expectedChromosome: String) throws {
        print("  Verifying chromosome assignment...")

        for annotation in annotations {
            XCTAssertEqual(annotation.chromosome, expectedChromosome,
                           "Annotation '\(annotation.name)' should have chromosome '\(expectedChromosome)'")
        }

        let withChromosome = annotations.filter { $0.chromosome == expectedChromosome }
        print("    Annotations with chromosome '\(expectedChromosome)': \(withChromosome.count) of \(annotations.count)")
    }

    // MARK: - Second Record Tests

    private func verifySecondRecord(_ record: GenBankRecord) throws {
        print("\n--- Verifying Second Record ---")

        // LOCUS line
        XCTAssertEqual(record.locus.name, "TestGene_002", "Second locus name should be TestGene_002")
        XCTAssertEqual(record.locus.length, 1200, "Second locus length should be 1200")
        print("  LOCUS: \(record.locus.name), \(record.locus.length) bp")

        // Accession/Version
        XCTAssertEqual(record.accession, "LF000002", "Second accession should be LF000002")
        XCTAssertEqual(record.version, "LF000002.1", "Second version should be LF000002.1")

        // Sequence
        XCTAssertEqual(record.sequence.length, 1200, "Second sequence should be 1200 bp")

        // Features - check for RNA-specific types
        print("  Total annotations: \(record.annotations.count)")

        let typeCount: [AnnotationType: Int] = record.annotations.reduce(into: [:]) { dict, ann in
            dict[ann.type, default: 0] += 1
        }

        print("  Feature types in second record:")
        for (type, count) in typeCount.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            print("    - \(type.rawValue): \(count)")
        }

        // Check chromosome assignment for second record
        for annotation in record.annotations {
            XCTAssertEqual(annotation.chromosome, "TestGene_002",
                           "Second record annotations should have chromosome 'TestGene_002'")
        }

        // Check for stem_loop feature
        let stemLoops = record.annotations.filter { $0.type == .stem_loop }
        XCTAssertGreaterThan(stemLoops.count, 0, "Should have stem_loop feature")
        if let stemLoop = stemLoops.first {
            print("  Stem loop at: \(stemLoop.start+1)..\(stemLoop.end)")
        }
    }

    // MARK: - Additional Edge Case Tests

    /// Tests that feature type mapping handles unmapped types gracefully
    func testFeatureTypeMapping() async throws {
        let testFileURL = URL(fileURLWithPath: "/Users/dho/Desktop/test2/My Genome Project.lungfish/test_annotated.gb")

        guard FileManager.default.fileExists(atPath: testFileURL.path) else {
            XCTFail("Test file not found")
            return
        }

        let reader = try GenBankReader(url: testFileURL)
        let records = try await reader.readAll()
        let record1 = records[0]

        // These features in the file should map to misc_feature since they're not in AnnotationType:
        // - TATA_signal -> misc_feature
        // - regulatory -> misc_feature
        // - ncRNA -> misc_feature
        // - misc_RNA -> misc_feature
        // - protein_bind -> misc_feature

        print("\n--- Testing Feature Type Mapping ---")

        // Find misc_feature annotations
        let miscFeatures = record1.annotations.filter { $0.type == .misc_feature }
        print("  misc_feature count: \(miscFeatures.count)")

        // The file has these that should map to misc_feature:
        // - TATA_signal (50..56)
        // - misc_feature (1..50) - explicit
        // - misc_feature (2450..2500) - explicit
        // These should at least include the two explicit misc_features
        XCTAssertGreaterThanOrEqual(miscFeatures.count, 2, "Should have at least 2 misc_feature")
    }

    /// Tests that the reader handles sequences correctly for annotation filtering
    func testAnnotationBelongsToSequence() async throws {
        let testFileURL = URL(fileURLWithPath: "/Users/dho/Desktop/test2/My Genome Project.lungfish/test_annotated.gb")

        guard FileManager.default.fileExists(atPath: testFileURL.path) else {
            XCTFail("Test file not found")
            return
        }

        let reader = try GenBankReader(url: testFileURL)
        let records = try await reader.readAll()

        print("\n--- Testing Annotation Sequence Filtering ---")

        // Get all annotations from both records
        let allAnnotations = records.flatMap { $0.annotations }

        // Filter for first sequence
        let seq1Annotations = allAnnotations.filter { $0.belongsToSequence(named: "TestGene_001") }
        let seq2Annotations = allAnnotations.filter { $0.belongsToSequence(named: "TestGene_002") }

        print("  Total annotations: \(allAnnotations.count)")
        print("  Annotations for TestGene_001: \(seq1Annotations.count)")
        print("  Annotations for TestGene_002: \(seq2Annotations.count)")

        // Each record's annotations should only belong to that sequence
        XCTAssertEqual(seq1Annotations.count, records[0].annotations.count,
                       "First sequence annotations should match")
        XCTAssertEqual(seq2Annotations.count, records[1].annotations.count,
                       "Second sequence annotations should match")

        // They should be mutually exclusive
        let overlap = seq1Annotations.filter { ann in
            seq2Annotations.contains { $0.id == ann.id }
        }
        XCTAssertEqual(overlap.count, 0, "Annotations should not overlap between sequences")
    }
}
