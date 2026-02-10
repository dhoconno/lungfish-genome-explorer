// SequenceTests.swift - Comprehensive tests for Sequence model
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class SequenceTests: XCTestCase {

    // MARK: - Creation Tests

    func testCreateDNASequence() throws {
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATCGATCG")
        XCTAssertEqual(seq.name, "test")
        XCTAssertEqual(seq.alphabet, .dna)
        XCTAssertEqual(seq.length, 8)
    }

    func testCreateRNASequence() throws {
        let seq = try Sequence(name: "rna_test", alphabet: .rna, bases: "AUCGAUCG")
        XCTAssertEqual(seq.alphabet, .rna)
        XCTAssertEqual(seq.length, 8)
    }

    func testCreateProteinSequence() throws {
        let seq = try Sequence(name: "protein", alphabet: .protein, bases: "MKTAYIAKQ")
        XCTAssertEqual(seq.alphabet, .protein)
        XCTAssertEqual(seq.length, 9)
    }

    func testCreateSequenceWithDescription() throws {
        let seq = try Sequence(
            name: "test",
            description: "Test sequence description",
            alphabet: .dna,
            bases: "ATCG"
        )
        XCTAssertEqual(seq.description, "Test sequence description")
    }

    func testCreateSequenceWithCustomID() throws {
        let customID = UUID()
        let seq = try Sequence(id: customID, name: "test", alphabet: .dna, bases: "ATCG")
        XCTAssertEqual(seq.id, customID)
    }

    func testInvalidCharacterThrows() {
        XCTAssertThrowsError(try Sequence(name: "bad", alphabet: .dna, bases: "ATCGX")) { error in
            guard case SequenceError.invalidCharacter(let char, _) = error else {
                XCTFail("Expected invalidCharacter error")
                return
            }
            XCTAssertEqual(char, "X")
        }
    }

    func testInvalidCharacterReportsPosition() {
        XCTAssertThrowsError(try Sequence(name: "bad", alphabet: .dna, bases: "ATCGXYZ")) { error in
            guard case SequenceError.invalidCharacter(_, let position) = error else {
                XCTFail("Expected invalidCharacter error")
                return
            }
            XCTAssertEqual(position, 4)  // 'X' is at index 4
        }
    }

    func testInvalidRNACharacterThrows() {
        // X is not valid in RNA (Note: T validation is a known issue in SequenceStorage)
        XCTAssertThrowsError(try Sequence(name: "bad", alphabet: .rna, bases: "AUCGX"))
    }

    func testInvalidProteinCharacterThrows() {
        // 'J' is not a valid amino acid
        XCTAssertThrowsError(try Sequence(name: "bad", alphabet: .protein, bases: "MKTJAY"))
    }

    // MARK: - Edge Cases: Empty and Single Base

    func testSingleBaseSequence() throws {
        let seq = try Sequence(name: "single", alphabet: .dna, bases: "A")
        XCTAssertEqual(seq.length, 1)
        XCTAssertEqual(seq[0], "A")
        XCTAssertEqual(seq.asString(), "A")
    }

    func testSingleBaseComplement() throws {
        let seq = try Sequence(name: "single", alphabet: .dna, bases: "A")
        let comp = seq.complement()
        XCTAssertNotNil(comp)
        XCTAssertEqual(comp?.asString(), "T")
    }

    func testSingleBaseReverseComplement() throws {
        let seq = try Sequence(name: "single", alphabet: .dna, bases: "A")
        let rc = seq.reverseComplement()
        XCTAssertNotNil(rc)
        XCTAssertEqual(rc?.asString(), "T")
    }

    // MARK: - Subscript Tests

    func testSubscriptSingleBase() throws {
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATCGATCG")
        XCTAssertEqual(seq[0], "A")
        XCTAssertEqual(seq[1], "T")
        XCTAssertEqual(seq[2], "C")
        XCTAssertEqual(seq[3], "G")
    }

    func testSubscriptRange() throws {
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATCGATCGATCG")
        XCTAssertEqual(seq[0..<4], "ATCG")
        XCTAssertEqual(seq[4..<8], "ATCG")
    }

    func testSubscriptRangeAtStart() throws {
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATCGATCG")
        XCTAssertEqual(seq[0..<3], "ATC")
    }

    func testSubscriptRangeAtEnd() throws {
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATCGATCG")
        XCTAssertEqual(seq[5..<8], "TCG")
    }

    func testSubscriptEmptyRange() throws {
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATCGATCG")
        XCTAssertEqual(seq[4..<4], "")
    }

    func testSubscriptFullRange() throws {
        let bases = "ATCGATCG"
        let seq = try Sequence(name: "test", alphabet: .dna, bases: bases)
        XCTAssertEqual(seq[0..<8], bases)
    }

    func testAsString() throws {
        let bases = "ATCGATCGATCG"
        let seq = try Sequence(name: "test", alphabet: .dna, bases: bases)
        XCTAssertEqual(seq.asString(), bases)
    }

    // MARK: - 2-bit Encoding Tests

    func testTwoBitEncodingRoundTrip() throws {
        // Test all basic bases
        let bases = "AAACCCGGGTTT"
        let seq = try Sequence(name: "test", alphabet: .dna, bases: bases)
        XCTAssertEqual(seq.asString(), bases)
    }

    func testTwoBitEncodingAllCombinations() throws {
        // Test all 16 two-base combinations
        let bases = "AATACAAGTTCTCGGTGCGGA"
        let seq = try Sequence(name: "combos", alphabet: .dna, bases: bases)
        XCTAssertEqual(seq.asString(), bases)
    }

    func testLargeSequence() throws {
        // Test with a larger sequence to ensure 2-bit encoding handles boundaries
        let bases = String(repeating: "ATCG", count: 1000) // 4000 bases
        let seq = try Sequence(name: "large", alphabet: .dna, bases: bases)
        XCTAssertEqual(seq.length, 4000)
        XCTAssertEqual(seq.asString(), bases)
    }

    func testVeryLargeSequence() throws {
        // Test with 100,000 bases to verify performance and correctness
        let bases = String(repeating: "ATCGATCGATCGATCGATCG", count: 5000)  // 100,000 bases
        let seq = try Sequence(name: "very_large", alphabet: .dna, bases: bases)
        XCTAssertEqual(seq.length, 100000)

        // Verify some samples
        XCTAssertEqual(seq[0..<20], "ATCGATCGATCGATCGATCG")
        XCTAssertEqual(seq[99980..<100000], "ATCGATCGATCGATCGATCG")
    }

    func testAmbiguousBases() throws {
        let bases = "ATCNGATCN"
        let seq = try Sequence(name: "ambig", alphabet: .dna, bases: bases)
        XCTAssertEqual(seq.asString(), bases)
        XCTAssertEqual(seq[3], "N")
        XCTAssertEqual(seq[8], "N")
    }

    func testMultipleAmbiguousBases() throws {
        let bases = "NNNATCGNNNATCGNNN"
        let seq = try Sequence(name: "ambig", alphabet: .dna, bases: bases)
        XCTAssertEqual(seq.asString(), bases)
    }

    func testAllAmbiguousCodes() throws {
        // Test all IUPAC ambiguity codes
        let bases = "RYSWKMBDHVN"
        let seq = try Sequence(name: "iupac", alphabet: .dna, bases: bases)
        XCTAssertEqual(seq.asString(), bases)
    }

    func testLowercaseBases() throws {
        let bases = "atcgatcg"
        let seq = try Sequence(name: "lower", alphabet: .dna, bases: bases)
        XCTAssertEqual(seq.length, 8)
        // Note: lowercase bases should be handled properly
    }

    func testMixedCaseBases() throws {
        let bases = "AtCgAtCg"
        let seq = try Sequence(name: "mixed", alphabet: .dna, bases: bases)
        XCTAssertEqual(seq.length, 8)
    }

    // MARK: - Complement Tests

    func testComplement() throws {
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATCG")
        let comp = seq.complement()
        XCTAssertNotNil(comp)
        XCTAssertEqual(comp?.asString(), "TAGC")
    }

    func testReverseComplement() throws {
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATCG")
        let rc = seq.reverseComplement()
        XCTAssertNotNil(rc)
        XCTAssertEqual(rc?.asString(), "CGAT")
    }

    func testComplementPreservesAlphabet() throws {
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATCG")
        let comp = seq.complement()
        XCTAssertEqual(comp?.alphabet, .dna)
    }

    func testComplementNaming() throws {
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATCG")
        let comp = seq.complement()
        XCTAssertEqual(comp?.name, "test_complement")
    }

    func testReverseComplementNaming() throws {
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATCG")
        let rc = seq.reverseComplement()
        XCTAssertEqual(rc?.name, "test_rc")
    }

    func testRNAComplement() throws {
        let seq = try Sequence(name: "rna", alphabet: .rna, bases: "AUCG")
        let comp = seq.complement()
        XCTAssertNotNil(comp)
        XCTAssertEqual(comp?.asString(), "UAGC")
    }

    func testRNAReverseComplement() throws {
        let seq = try Sequence(name: "rna", alphabet: .rna, bases: "AUCG")
        let rc = seq.reverseComplement()
        XCTAssertNotNil(rc)
        XCTAssertEqual(rc?.asString(), "CGAU")
    }

    func testProteinNoComplement() throws {
        let seq = try Sequence(name: "protein", alphabet: .protein, bases: "MKTAY")
        XCTAssertNil(seq.complement())
        XCTAssertNil(seq.reverseComplement())
    }

    func testComplementWithAmbiguousBases() throws {
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATNCGN")
        let comp = seq.complement()
        XCTAssertNotNil(comp)
        XCTAssertEqual(comp?.asString(), "TANGCN")
    }

    func testReverseComplementWithAmbiguousBases() throws {
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATNCGN")
        let rc = seq.reverseComplement()
        XCTAssertNotNil(rc)
        XCTAssertEqual(rc?.asString(), "NCGNAT")
    }

    func testComplementIdempotent() throws {
        // complement(complement(seq)) should equal seq
        let original = try Sequence(name: "test", alphabet: .dna, bases: "ATCGATCG")
        let comp = original.complement()
        let doubleComp = comp?.complement()
        XCTAssertEqual(doubleComp?.asString(), original.asString())
    }

    func testReverseComplementIdempotent() throws {
        // reverseComplement(reverseComplement(seq)) should equal seq
        let original = try Sequence(name: "test", alphabet: .dna, bases: "ATCGATCG")
        let rc = original.reverseComplement()
        let doubleRc = rc?.reverseComplement()
        XCTAssertEqual(doubleRc?.asString(), original.asString())
    }

    // MARK: - Subsequence Tests

    func testSubsequence() throws {
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATCGATCGATCG")
        let region = GenomicRegion(chromosome: "test", start: 4, end: 8)
        let subseq = seq.subsequence(region: region)
        XCTAssertEqual(subseq.length, 4)
        XCTAssertEqual(subseq.asString(), "ATCG")
    }

    func testSubsequencePreservesAlphabet() throws {
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATCGATCGATCG")
        let region = GenomicRegion(chromosome: "test", start: 0, end: 4)
        let subseq = seq.subsequence(region: region)
        XCTAssertEqual(subseq.alphabet, .dna)
    }

    func testSubsequenceNaming() throws {
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATCGATCGATCG")
        let region = GenomicRegion(chromosome: "test", start: 4, end: 8)
        let subseq = seq.subsequence(region: region)
        XCTAssertEqual(subseq.name, "test:4-8")
    }

    func testSubsequenceAtStart() throws {
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATCGATCG")
        let region = GenomicRegion(chromosome: "test", start: 0, end: 3)
        let subseq = seq.subsequence(region: region)
        XCTAssertEqual(subseq.asString(), "ATC")
    }

    func testSubsequenceAtEnd() throws {
        let seq = try Sequence(name: "test", alphabet: .dna, bases: "ATCGATCG")
        let region = GenomicRegion(chromosome: "test", start: 5, end: 8)
        let subseq = seq.subsequence(region: region)
        XCTAssertEqual(subseq.asString(), "TCG")
    }

    // MARK: - Hashable and Equatable Tests

    func testSequenceEquality() throws {
        let id = UUID()
        let seq1 = try Sequence(id: id, name: "test", alphabet: .dna, bases: "ATCG")
        let seq2 = try Sequence(id: id, name: "test", alphabet: .dna, bases: "ATCG")
        XCTAssertEqual(seq1, seq2)
    }

    func testSequenceInequalityDifferentID() throws {
        let seq1 = try Sequence(name: "test", alphabet: .dna, bases: "ATCG")
        let seq2 = try Sequence(name: "test", alphabet: .dna, bases: "ATCG")
        XCTAssertNotEqual(seq1, seq2)  // Different auto-generated IDs
    }

    func testSequenceHashable() throws {
        let id = UUID()
        let seq1 = try Sequence(id: id, name: "test", alphabet: .dna, bases: "ATCG")
        let seq2 = try Sequence(id: id, name: "test", alphabet: .dna, bases: "ATCG")

        var set = Set<Sequence>()
        set.insert(seq1)
        XCTAssertTrue(set.contains(seq2))
    }

    // MARK: - Circular Sequence Tests

    func testCircularSequence() throws {
        var seq = try Sequence(name: "plasmid", alphabet: .dna, bases: "ATCGATCG")
        seq.isCircular = true
        XCTAssertTrue(seq.isCircular)
    }

    // MARK: - Performance Tests

    func testLargeSequenceCreationPerformance() throws {
        let bases = String(repeating: "ATCGATCG", count: 12500)  // 100,000 bases

        measure {
            _ = try? Sequence(name: "perf_test", alphabet: .dna, bases: bases)
        }
    }

    func testLargeSequenceAccessPerformance() throws {
        let bases = String(repeating: "ATCGATCG", count: 12500)  // 100,000 bases
        let seq = try Sequence(name: "perf_test", alphabet: .dna, bases: bases)

        measure {
            // Access random positions
            for i in stride(from: 0, to: 100000, by: 1000) {
                _ = seq[i]
            }
        }
    }

    func testLargeSequenceComplementPerformance() throws {
        let bases = String(repeating: "ATCGATCG", count: 12500)  // 100,000 bases
        let seq = try Sequence(name: "perf_test", alphabet: .dna, bases: bases)

        measure {
            _ = seq.complement()
        }
    }
}

// MARK: - GenomicRegion Tests

final class GenomicRegionTests: XCTestCase {

    // MARK: - Creation Tests

    func testCreateRegion() {
        let region = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        XCTAssertEqual(region.chromosome, "chr1")
        XCTAssertEqual(region.start, 100)
        XCTAssertEqual(region.end, 200)
        XCTAssertEqual(region.length, 100)
    }

    func testCreateEmptyRegion() {
        let region = GenomicRegion(chromosome: "chr1", start: 100, end: 100)
        XCTAssertEqual(region.length, 0)
        XCTAssertTrue(region.isEmpty)
    }

    func testCreateRegionFromRange() {
        let region = GenomicRegion(chromosome: "chr1", range: 100..<200)
        XCTAssertEqual(region.start, 100)
        XCTAssertEqual(region.end, 200)
    }

    func testRegionCenter() {
        let region = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        XCTAssertEqual(region.center, 150)
    }

    func testRegionCenterOdd() {
        let region = GenomicRegion(chromosome: "chr1", start: 100, end: 201)
        XCTAssertEqual(region.center, 150)  // 100 + 101/2 = 150
    }

    func testRegionRange() {
        let region = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        XCTAssertEqual(region.range, 100..<200)
    }

    // MARK: - Contains Position Tests

    func testContainsPosition() {
        let region = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        XCTAssertTrue(region.contains(position: 100))
        XCTAssertTrue(region.contains(position: 150))
        XCTAssertTrue(region.contains(position: 199))
        XCTAssertFalse(region.contains(position: 99))
        XCTAssertFalse(region.contains(position: 200))
    }

    func testContainsPositionEmptyRegion() {
        let region = GenomicRegion(chromosome: "chr1", start: 100, end: 100)
        XCTAssertFalse(region.contains(position: 100))
    }

    // MARK: - Contains Region Tests

    func testContainsRegion() {
        let outer = GenomicRegion(chromosome: "chr1", start: 100, end: 300)
        let inner = GenomicRegion(chromosome: "chr1", start: 150, end: 250)
        XCTAssertTrue(outer.contains(inner))
        XCTAssertFalse(inner.contains(outer))
    }

    func testContainsRegionExact() {
        let region1 = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let region2 = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        XCTAssertTrue(region1.contains(region2))
    }

    func testContainsRegionDifferentChromosome() {
        let region1 = GenomicRegion(chromosome: "chr1", start: 100, end: 300)
        let region2 = GenomicRegion(chromosome: "chr2", start: 150, end: 250)
        XCTAssertFalse(region1.contains(region2))
    }

    func testContainsRegionPartialOverlap() {
        let region1 = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let region2 = GenomicRegion(chromosome: "chr1", start: 150, end: 250)
        XCTAssertFalse(region1.contains(region2))
    }

    // MARK: - Overlaps Tests

    func testOverlaps() {
        let region1 = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let region2 = GenomicRegion(chromosome: "chr1", start: 150, end: 250)
        let region3 = GenomicRegion(chromosome: "chr1", start: 200, end: 300)
        let region4 = GenomicRegion(chromosome: "chr2", start: 100, end: 200)

        XCTAssertTrue(region1.overlaps(region2))
        XCTAssertFalse(region1.overlaps(region3))  // Adjacent, not overlapping
        XCTAssertFalse(region1.overlaps(region4))  // Different chromosome
    }

    func testOverlapsSymmetric() {
        let region1 = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let region2 = GenomicRegion(chromosome: "chr1", start: 150, end: 250)
        XCTAssertEqual(region1.overlaps(region2), region2.overlaps(region1))
    }

    func testOverlapsSelf() {
        let region = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        XCTAssertTrue(region.overlaps(region))
    }

    func testOverlapsContained() {
        let outer = GenomicRegion(chromosome: "chr1", start: 100, end: 300)
        let inner = GenomicRegion(chromosome: "chr1", start: 150, end: 250)
        XCTAssertTrue(outer.overlaps(inner))
        XCTAssertTrue(inner.overlaps(outer))
    }

    // MARK: - Intersection Tests

    func testIntersection() {
        let region1 = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let region2 = GenomicRegion(chromosome: "chr1", start: 150, end: 250)

        let intersection = region1.intersection(region2)
        XCTAssertNotNil(intersection)
        XCTAssertEqual(intersection?.start, 150)
        XCTAssertEqual(intersection?.end, 200)
    }

    func testIntersectionNoOverlap() {
        let region1 = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let region2 = GenomicRegion(chromosome: "chr1", start: 300, end: 400)
        XCTAssertNil(region1.intersection(region2))
    }

    func testIntersectionDifferentChromosome() {
        let region1 = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let region2 = GenomicRegion(chromosome: "chr2", start: 100, end: 200)
        XCTAssertNil(region1.intersection(region2))
    }

    func testIntersectionContained() {
        let outer = GenomicRegion(chromosome: "chr1", start: 100, end: 300)
        let inner = GenomicRegion(chromosome: "chr1", start: 150, end: 250)
        let intersection = outer.intersection(inner)
        XCTAssertEqual(intersection?.start, inner.start)
        XCTAssertEqual(intersection?.end, inner.end)
    }

    // MARK: - Union Tests

    func testUnion() {
        let region1 = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let region2 = GenomicRegion(chromosome: "chr1", start: 150, end: 250)

        let union = region1.union(region2)
        XCTAssertNotNil(union)
        XCTAssertEqual(union?.start, 100)
        XCTAssertEqual(union?.end, 250)
    }

    func testUnionNonOverlapping() {
        let region1 = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let region2 = GenomicRegion(chromosome: "chr1", start: 300, end: 400)

        let union = region1.union(region2)
        XCTAssertNotNil(union)
        XCTAssertEqual(union?.start, 100)
        XCTAssertEqual(union?.end, 400)
    }

    func testUnionDifferentChromosome() {
        let region1 = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let region2 = GenomicRegion(chromosome: "chr2", start: 100, end: 200)
        XCTAssertNil(region1.union(region2))
    }

    // MARK: - Expanded Tests

    func testExpanded() {
        let region = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let expanded = region.expanded(by: 50)
        XCTAssertEqual(expanded.start, 50)
        XCTAssertEqual(expanded.end, 250)
    }

    func testExpandedNegativeStart() {
        let region = GenomicRegion(chromosome: "chr1", start: 10, end: 50)
        let expanded = region.expanded(by: 20)
        XCTAssertEqual(expanded.start, 0)  // Should clamp to 0
        XCTAssertEqual(expanded.end, 70)
    }

    func testExpandedByZero() {
        let region = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let expanded = region.expanded(by: 0)
        XCTAssertEqual(expanded.start, 100)
        XCTAssertEqual(expanded.end, 200)
    }

    // MARK: - Distance Tests

    func testDistanceOverlapping() {
        let region1 = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let region2 = GenomicRegion(chromosome: "chr1", start: 150, end: 250)
        XCTAssertEqual(region1.distance(to: region2), 0)
    }

    func testDistanceNonOverlapping() {
        let region1 = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let region2 = GenomicRegion(chromosome: "chr1", start: 300, end: 400)
        XCTAssertEqual(region1.distance(to: region2), 100)
    }

    func testDistanceReverse() {
        let region1 = GenomicRegion(chromosome: "chr1", start: 300, end: 400)
        let region2 = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        XCTAssertEqual(region1.distance(to: region2), 100)
    }

    func testDistanceDifferentChromosome() {
        let region1 = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let region2 = GenomicRegion(chromosome: "chr2", start: 100, end: 200)
        XCTAssertNil(region1.distance(to: region2))
    }

    func testDistanceAdjacent() {
        let region1 = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let region2 = GenomicRegion(chromosome: "chr1", start: 200, end: 300)
        XCTAssertEqual(region1.distance(to: region2), 0)
    }

    // MARK: - Comparable Tests

    func testComparableSameChromosome() {
        let region1 = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let region2 = GenomicRegion(chromosome: "chr1", start: 200, end: 300)
        XCTAssertTrue(region1 < region2)
    }

    func testComparableDifferentChromosome() {
        let region1 = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let region2 = GenomicRegion(chromosome: "chr2", start: 50, end: 100)
        XCTAssertTrue(region1 < region2)
    }

    func testComparableSameStart() {
        let region1 = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let region2 = GenomicRegion(chromosome: "chr1", start: 100, end: 300)
        XCTAssertTrue(region1 < region2)
    }

    func testComparableSorting() {
        let regions = [
            GenomicRegion(chromosome: "chr2", start: 100, end: 200),
            GenomicRegion(chromosome: "chr1", start: 300, end: 400),
            GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        ]
        let sorted = regions.sorted()
        XCTAssertEqual(sorted[0].chromosome, "chr1")
        XCTAssertEqual(sorted[0].start, 100)
        XCTAssertEqual(sorted[1].chromosome, "chr1")
        XCTAssertEqual(sorted[1].start, 300)
        XCTAssertEqual(sorted[2].chromosome, "chr2")
    }

    // MARK: - Description Tests

    func testDescription() {
        let region = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        XCTAssertEqual(region.description, "chr1:100-200")
    }

    // MARK: - Codable Tests

    func testCodable() throws {
        let region = GenomicRegion(chromosome: "chr1", start: 100, end: 200)
        let encoded = try JSONEncoder().encode(region)
        let decoded = try JSONDecoder().decode(GenomicRegion.self, from: encoded)
        XCTAssertEqual(decoded, region)
    }
}

// MARK: - SequenceAlphabet Tests

final class SequenceAlphabetTests: XCTestCase {

    func testDNAValidCharacters() {
        let alphabet = SequenceAlphabet.dna
        XCTAssertTrue(alphabet.validCharacters.contains("A"))
        XCTAssertTrue(alphabet.validCharacters.contains("T"))
        XCTAssertTrue(alphabet.validCharacters.contains("G"))
        XCTAssertTrue(alphabet.validCharacters.contains("C"))
        XCTAssertTrue(alphabet.validCharacters.contains("N"))
        XCTAssertFalse(alphabet.validCharacters.contains("U"))
    }

    func testDNAValidAmbiguousCodes() {
        let alphabet = SequenceAlphabet.dna
        // Test all IUPAC ambiguity codes
        for char in "RYSWKMBDHVN" {
            XCTAssertTrue(alphabet.validCharacters.contains(char), "Missing code: \(char)")
        }
    }

    func testDNAValidLowercase() {
        let alphabet = SequenceAlphabet.dna
        for char in "atcgn" {
            XCTAssertTrue(alphabet.validCharacters.contains(char))
        }
    }

    func testRNAValidCharacters() {
        let alphabet = SequenceAlphabet.rna
        XCTAssertTrue(alphabet.validCharacters.contains("A"))
        XCTAssertTrue(alphabet.validCharacters.contains("U"))
        XCTAssertTrue(alphabet.validCharacters.contains("G"))
        XCTAssertTrue(alphabet.validCharacters.contains("C"))
        XCTAssertFalse(alphabet.validCharacters.contains("T"))
    }

    func testProteinValidCharacters() {
        let alphabet = SequenceAlphabet.protein
        // Test standard amino acids
        for char in "ACDEFGHIKLMNPQRSTVWY" {
            XCTAssertTrue(alphabet.validCharacters.contains(char), "Missing amino acid: \(char)")
        }
        // Stop codon
        XCTAssertTrue(alphabet.validCharacters.contains("*"))
        // Unknown
        XCTAssertTrue(alphabet.validCharacters.contains("X"))
    }

    func testSupportsComplement() {
        XCTAssertTrue(SequenceAlphabet.dna.supportsComplement)
        XCTAssertTrue(SequenceAlphabet.rna.supportsComplement)
        XCTAssertFalse(SequenceAlphabet.protein.supportsComplement)
    }

    func testCanTranslate() {
        XCTAssertTrue(SequenceAlphabet.dna.canTranslate)
        XCTAssertTrue(SequenceAlphabet.rna.canTranslate)
        XCTAssertFalse(SequenceAlphabet.protein.canTranslate)
    }

    func testDNAComplementMap() {
        let map = SequenceAlphabet.dna.complementMap!
        XCTAssertEqual(map["A"], "T")
        XCTAssertEqual(map["T"], "A")
        XCTAssertEqual(map["G"], "C")
        XCTAssertEqual(map["C"], "G")
        XCTAssertEqual(map["N"], "N")
    }

    func testRNAComplementMap() {
        let map = SequenceAlphabet.rna.complementMap!
        XCTAssertEqual(map["A"], "U")
        XCTAssertEqual(map["U"], "A")
        XCTAssertEqual(map["G"], "C")
        XCTAssertEqual(map["C"], "G")
    }

    func testProteinNoComplementMap() {
        XCTAssertNil(SequenceAlphabet.protein.complementMap)
    }

    func testCaseIterable() {
        let allCases = SequenceAlphabet.allCases
        XCTAssertEqual(allCases.count, 3)
        XCTAssertTrue(allCases.contains(.dna))
        XCTAssertTrue(allCases.contains(.rna))
        XCTAssertTrue(allCases.contains(.protein))
    }
}

// MARK: - Strand Tests

final class StrandTests: XCTestCase {

    func testStrandRawValues() {
        XCTAssertEqual(Strand.forward.rawValue, "+")
        XCTAssertEqual(Strand.reverse.rawValue, "-")
        XCTAssertEqual(Strand.unknown.rawValue, ".")
    }

    func testOpposite() {
        XCTAssertEqual(Strand.forward.opposite, .reverse)
        XCTAssertEqual(Strand.reverse.opposite, .forward)
        XCTAssertEqual(Strand.unknown.opposite, .unknown)
    }

    func testOppositeIdempotent() {
        XCTAssertEqual(Strand.forward.opposite.opposite, .forward)
        XCTAssertEqual(Strand.reverse.opposite.opposite, .reverse)
    }
}

// MARK: - ReadingFrame Tests

final class ReadingFrameTests: XCTestCase {

    func testForwardFrameOffsets() {
        XCTAssertEqual(ReadingFrame.plus1.offset, 0)
        XCTAssertEqual(ReadingFrame.plus2.offset, 1)
        XCTAssertEqual(ReadingFrame.plus3.offset, 2)
    }

    func testReverseFrameOffsets() {
        XCTAssertEqual(ReadingFrame.minus1.offset, 0)
        XCTAssertEqual(ReadingFrame.minus2.offset, 1)
        XCTAssertEqual(ReadingFrame.minus3.offset, 2)
    }

    func testForwardFramesNotReverse() {
        XCTAssertFalse(ReadingFrame.plus1.isReverse)
        XCTAssertFalse(ReadingFrame.plus2.isReverse)
        XCTAssertFalse(ReadingFrame.plus3.isReverse)
    }

    func testReverseFramesAreReverse() {
        XCTAssertTrue(ReadingFrame.minus1.isReverse)
        XCTAssertTrue(ReadingFrame.minus2.isReverse)
        XCTAssertTrue(ReadingFrame.minus3.isReverse)
    }

    func testRawValues() {
        XCTAssertEqual(ReadingFrame.plus1.rawValue, "+1")
        XCTAssertEqual(ReadingFrame.minus3.rawValue, "-3")
    }

    func testCaseIterable() {
        let allFrames = ReadingFrame.allCases
        XCTAssertEqual(allFrames.count, 6)
    }

    func testForwardFramesCollection() {
        XCTAssertEqual(ReadingFrame.forwardFrames, [.plus1, .plus2, .plus3])
    }

    func testReverseFramesCollection() {
        XCTAssertEqual(ReadingFrame.reverseFrames, [.minus1, .minus2, .minus3])
    }
}
