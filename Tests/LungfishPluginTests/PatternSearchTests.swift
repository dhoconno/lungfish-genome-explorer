// PatternSearchTests.swift - Tests for pattern search plugin
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishPlugin

final class PatternSearchTests: XCTestCase {

    // MARK: - Exact Match Tests

    func testExactMatchSingle() async throws {
        let plugin = PatternSearchPlugin()

        let sequence = "ATCGATCGATCG"
        var options = AnnotationOptions()
        options["pattern"] = .string("GATC")
        options["patternType"] = .string("exact")
        options["searchBothStrands"] = .bool(false)

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        XCTAssertEqual(annotations.count, 2)
        XCTAssertEqual(annotations[0].start, 3)
        XCTAssertEqual(annotations[1].start, 7)
    }

    func testExactMatchNoResults() async throws {
        let plugin = PatternSearchPlugin()

        let sequence = "AAAAAAAAAA"
        var options = AnnotationOptions()
        options["pattern"] = .string("GGGG")
        options["patternType"] = .string("exact")

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        XCTAssertTrue(annotations.isEmpty)
    }

    func testCaseInsensitiveMatch() async throws {
        let plugin = PatternSearchPlugin()

        let sequence = "atcgATCGatcg"
        var options = AnnotationOptions()
        options["pattern"] = .string("atcg")
        options["patternType"] = .string("exact")
        options["caseSensitive"] = .bool(false)
        options["searchBothStrands"] = .bool(false)

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        XCTAssertEqual(annotations.count, 3)
    }

    func testCaseSensitiveMatch() async throws {
        let plugin = PatternSearchPlugin()

        let sequence = "atcgATCGatcg"
        var options = AnnotationOptions()
        options["pattern"] = .string("ATCG")
        options["patternType"] = .string("exact")
        options["caseSensitive"] = .bool(true)

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations[0].start, 4)
    }

    // MARK: - Mismatch Tolerance Tests

    func testMismatchTolerance() async throws {
        let plugin = PatternSearchPlugin()

        let sequence = "ATCGATCGATCG"
        var options = AnnotationOptions()
        options["pattern"] = .string("AACG")  // One mismatch from ATCG
        options["patternType"] = .string("exact")
        options["maxMismatches"] = .integer(1)
        options["searchBothStrands"] = .bool(false)

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        // Should find ATCG positions with 1 mismatch tolerance
        XCTAssertGreaterThan(annotations.count, 0)
    }

    func testNoMismatchesAllowed() async throws {
        let plugin = PatternSearchPlugin()

        let sequence = "ATCGATCGATCG"
        var options = AnnotationOptions()
        options["pattern"] = .string("AACG")  // One mismatch from ATCG
        options["patternType"] = .string("exact")
        options["maxMismatches"] = .integer(0)
        options["searchBothStrands"] = .bool(false)

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        XCTAssertTrue(annotations.isEmpty)
    }

    // MARK: - IUPAC Pattern Tests

    func testIUPACPattern() async throws {
        let plugin = PatternSearchPlugin()

        // N matches any base
        let sequence = "ATCGATCGATCG"
        var options = AnnotationOptions()
        options["pattern"] = .string("NNNN")
        options["patternType"] = .string("iupac")
        options["searchBothStrands"] = .bool(false)

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        // NSRegularExpression returns non-overlapping matches: positions 0, 4, 8
        XCTAssertEqual(annotations.count, 3)
    }

    func testIUPACPurine() async throws {
        let plugin = PatternSearchPlugin()

        // R matches A or G (purines)
        let sequence = "AATTCCGG"
        var options = AnnotationOptions()
        options["pattern"] = .string("RR")  // Two purines in a row
        options["patternType"] = .string("iupac")
        options["searchBothStrands"] = .bool(false)

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        // AA at 0, GG at 6
        XCTAssertEqual(annotations.count, 2)
    }

    func testIUPACPyrimidine() async throws {
        let plugin = PatternSearchPlugin()

        // Y matches C or T (pyrimidines)
        let sequence = "AATTCCGG"
        var options = AnnotationOptions()
        options["pattern"] = .string("YY")  // Two pyrimidines in a row
        options["patternType"] = .string("iupac")
        options["searchBothStrands"] = .bool(false)

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        // TT at 2, CC at 4
        XCTAssertEqual(annotations.count, 2)
    }

    // MARK: - Regex Pattern Tests

    func testRegexPattern() async throws {
        let plugin = PatternSearchPlugin()

        let sequence = "ATCGATCGATCG"
        var options = AnnotationOptions()
        options["pattern"] = .string("AT.G")  // AT, any char, G
        options["patternType"] = .string("regex")
        options["searchBothStrands"] = .bool(false)

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        XCTAssertEqual(annotations.count, 3)
    }

    func testRegexRepeats() async throws {
        let plugin = PatternSearchPlugin()

        let sequence = "AAATTTAAATTT"
        var options = AnnotationOptions()
        options["pattern"] = .string("A{3}")  // Three A's in a row
        options["patternType"] = .string("regex")
        options["searchBothStrands"] = .bool(false)

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        XCTAssertEqual(annotations.count, 2)
    }

    // MARK: - Both Strands Search

    func testBothStrandsSearch() async throws {
        let plugin = PatternSearchPlugin()

        // GAATTC is palindromic (reverse complement is also GAATTC)
        let sequence = "ATCGAATTCATCG"
        var options = AnnotationOptions()
        options["pattern"] = .string("GAATTC")
        options["patternType"] = .string("exact")
        options["searchBothStrands"] = .bool(true)

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        // For palindrome, forward match = reverse match at same position
        XCTAssertGreaterThanOrEqual(annotations.count, 1)
    }

    func testReverseStrandMatch() async throws {
        let plugin = PatternSearchPlugin()

        // Search for ATCG, sequence contains CGAT which is reverse complement
        let sequence = "CGATNNNN"
        var options = AnnotationOptions()
        options["pattern"] = .string("ATCG")
        options["patternType"] = .string("exact")
        options["searchBothStrands"] = .bool(true)

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        // Should find reverse complement match
        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations[0].strand, .reverse)
    }

    // MARK: - Edge Cases

    func testEmptyPattern() async {
        let plugin = PatternSearchPlugin()

        var options = AnnotationOptions()
        options["pattern"] = .string("")

        let input = AnnotationInput(
            sequence: "ATCG",
            alphabet: .dna,
            options: options
        )

        do {
            _ = try await plugin.generateAnnotations(input)
            XCTFail("Should have thrown error for empty pattern")
        } catch PluginError.invalidOptions {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testProteinPatternSearch() async throws {
        let plugin = PatternSearchPlugin()

        let sequence = "MVLSPADKTNVKAAWGKVGAHAGEYGAEALERMFLSFPTTKTYFPHFDLSH"
        var options = AnnotationOptions()
        options["pattern"] = .string("MVLS")
        options["patternType"] = .string("exact")
        options["searchBothStrands"] = .bool(false)

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .protein,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations[0].start, 0)
    }

    func testOverlappingMatches() async throws {
        let plugin = PatternSearchPlugin()

        let sequence = "AAAA"
        var options = AnnotationOptions()
        options["pattern"] = .string("AA")
        options["patternType"] = .string("exact")
        options["searchBothStrands"] = .bool(false)

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        // AA at 0, 1, 2 (overlapping)
        XCTAssertEqual(annotations.count, 3)
    }
}
