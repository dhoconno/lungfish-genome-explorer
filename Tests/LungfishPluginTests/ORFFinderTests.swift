// ORFFinderTests.swift - Tests for ORF finder
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishPlugin

final class ORFFinderTests: XCTestCase {

    // MARK: - Basic ORF Finding

    func testFindSimpleORF() async throws {
        let plugin = ORFFinderPlugin()

        // Simple ORF: ATG...TAA
        // ATG = start, TAA = stop, need at least 100nt by default
        // Create a 102nt ORF: ATG + 30 codons + TAA = 102 nt
        let sequence = "ATG" + String(repeating: "GCA", count: 31) + "TAA"
        var options = AnnotationOptions()
        options["minimumLength"] = .integer(30)
        options["frames"] = .stringArray(["+1"])

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations[0].start, 0)
        XCTAssertEqual(annotations[0].qualifiers["frame"], "+1")
    }

    func testNoORFWithoutStartCodon() async throws {
        let plugin = ORFFinderPlugin()

        // Sequence without ATG
        let sequence = "GCAGCAGCAGCAGCATAAGCAGCA"
        var options = AnnotationOptions()
        options["minimumLength"] = .integer(9)
        options["frames"] = .stringArray(["+1"])
        options["includePartial"] = .bool(false)

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        XCTAssertTrue(annotations.isEmpty)
    }

    func testMultipleORFsInSequence() async throws {
        let plugin = ORFFinderPlugin()

        // Two ORFs in frame +1
        let orf1 = "ATG" + String(repeating: "GCA", count: 5) + "TAA"  // 21 nt
        let spacer = "NNNNNN"  // 6 nt to stay in frame
        let orf2 = "ATG" + String(repeating: "TCG", count: 5) + "TGA"  // 21 nt

        let sequence = orf1 + spacer + orf2
        var options = AnnotationOptions()
        options["minimumLength"] = .integer(15)
        options["frames"] = .stringArray(["+1"])

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        XCTAssertEqual(annotations.count, 2)
    }

    func testMinimumLengthFilter() async throws {
        let plugin = ORFFinderPlugin()

        // Short ORF (9 nt)
        let shortORF = "ATGGCATAA"
        // Long ORF (30 nt)
        let longORF = "ATG" + String(repeating: "GCA", count: 7) + "TAA"

        let sequence = shortORF + "NNN" + longORF
        var options = AnnotationOptions()
        options["minimumLength"] = .integer(20)
        options["frames"] = .stringArray(["+1"])

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        // Only the long ORF should be found
        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations[0].start, 12)  // After short ORF + spacer
    }

    // MARK: - Reading Frame Tests

    func testDifferentReadingFrames() async throws {
        let plugin = ORFFinderPlugin()

        // ORF in frame +2
        let sequence = "N" + "ATG" + String(repeating: "GCA", count: 5) + "TAA"
        var options = AnnotationOptions()
        options["minimumLength"] = .integer(15)
        options["frames"] = .stringArray(["+1", "+2", "+3"])

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations[0].qualifiers["frame"], "+2")
    }

    func testReverseStrandORF() async throws {
        let plugin = ORFFinderPlugin()

        // Create ORF on reverse strand: TAA...CAT (reverse complement of ATG...TAA)
        // Forward: 5'-XXXTTA...CATXXX-3' -> Reverse complement has ATG...TAA
        let sequence = "NNNNNN" + "TTA" + String(repeating: "TGC", count: 5) + "CAT" + "NNNNNN"
        var options = AnnotationOptions()
        options["minimumLength"] = .integer(15)
        options["frames"] = .stringArray(["-1"])

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations[0].strand, .reverse)
    }

    func testSixFrameSearch() async throws {
        let plugin = ORFFinderPlugin()

        // This sequence has an ORF in frame +1 (forward)
        let sequence = "ATG" + String(repeating: "GCA", count: 10) + "TAA"
        var options = AnnotationOptions()
        options["minimumLength"] = .integer(15)
        options["frames"] = .stringArray(["+1", "+2", "+3", "-1", "-2", "-3"])

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        // Should find at least the forward ORF
        XCTAssertGreaterThanOrEqual(annotations.count, 1)
        XCTAssertTrue(annotations.contains { $0.qualifiers["frame"] == "+1" })
    }

    // MARK: - Alternative Start Codons

    func testAlternativeStartCodons() async throws {
        let plugin = ORFFinderPlugin()

        // ORF with GTG start (alternative)
        let sequence = "GTG" + String(repeating: "GCA", count: 5) + "TAA"
        var options = AnnotationOptions()
        options["minimumLength"] = .integer(15)
        options["frames"] = .stringArray(["+1"])
        options["allowAlternativeStarts"] = .bool(true)

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        XCTAssertEqual(annotations.count, 1)
    }

    func testAlternativeStartsDisabled() async throws {
        let plugin = ORFFinderPlugin()

        // ORF with GTG start (alternative)
        let sequence = "GTG" + String(repeating: "GCA", count: 5) + "TAA"
        var options = AnnotationOptions()
        options["minimumLength"] = .integer(15)
        options["frames"] = .stringArray(["+1"])
        options["allowAlternativeStarts"] = .bool(false)
        options["includePartial"] = .bool(false)

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        // Should not find ORF without ATG
        XCTAssertTrue(annotations.isEmpty)
    }

    // MARK: - Partial ORFs

    func testPartialORFAtEnd() async throws {
        let plugin = ORFFinderPlugin()

        // ORF that runs off the end (no stop codon)
        // When includePartial=true, ORFs starting from position 0 (partial) and ATG (real) both get tracked
        // So we expect 2 ORFs: one partial from start, one from ATG
        let sequence = "ATG" + String(repeating: "GCA", count: 10)
        var options = AnnotationOptions()
        options["minimumLength"] = .integer(15)
        options["frames"] = .stringArray(["+1"])
        options["includePartial"] = .bool(true)

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        // Two ORFs: one partial (starting from beginning) and one real (starting from ATG)
        // Both share the same coordinates since ATG is at position 0
        XCTAssertEqual(annotations.count, 2)
        // At least one should be marked as partial
        XCTAssertTrue(annotations.contains { $0.qualifiers["partial"] == "true" })
    }

    // MARK: - Edge Cases

    func testRejectsProteinSequence() async {
        let plugin = ORFFinderPlugin()

        let input = AnnotationInput(
            sequence: "MVLSPADKTN",
            alphabet: .protein
        )

        do {
            _ = try await plugin.generateAnnotations(input)
            XCTFail("Should have thrown error for protein sequence")
        } catch PluginError.unsupportedAlphabet {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEmptySequence() async throws {
        let plugin = ORFFinderPlugin()

        let input = AnnotationInput(
            sequence: "",
            alphabet: .dna
        )

        let annotations = try await plugin.generateAnnotations(input)

        XCTAssertTrue(annotations.isEmpty)
    }

    func testSequenceTooShort() async throws {
        let plugin = ORFFinderPlugin()

        let input = AnnotationInput(
            sequence: "ATG",
            alphabet: .dna
        )

        let annotations = try await plugin.generateAnnotations(input)

        XCTAssertTrue(annotations.isEmpty)
    }
}

// MARK: - Reading Frame Tests

final class ReadingFrameTests: XCTestCase {

    func testForwardFrames() {
        XCTAssertEqual(ReadingFrame.plus1.offset, 0)
        XCTAssertEqual(ReadingFrame.plus2.offset, 1)
        XCTAssertEqual(ReadingFrame.plus3.offset, 2)

        XCTAssertFalse(ReadingFrame.plus1.isReverse)
        XCTAssertFalse(ReadingFrame.plus2.isReverse)
        XCTAssertFalse(ReadingFrame.plus3.isReverse)
    }

    func testReverseFrames() {
        XCTAssertEqual(ReadingFrame.minus1.offset, 0)
        XCTAssertEqual(ReadingFrame.minus2.offset, 1)
        XCTAssertEqual(ReadingFrame.minus3.offset, 2)

        XCTAssertTrue(ReadingFrame.minus1.isReverse)
        XCTAssertTrue(ReadingFrame.minus2.isReverse)
        XCTAssertTrue(ReadingFrame.minus3.isReverse)
    }
}
