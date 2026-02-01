// TranslationTests.swift - Tests for translation plugin
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishPlugin

final class TranslationTests: XCTestCase {

    // MARK: - Basic Translation

    func testTranslateSimpleSequence() async throws {
        let plugin = TranslationPlugin()

        // ATG = M, GCA = A, TAA = *
        let sequence = "ATGGCAGCAGCATAA"
        var options = OperationOptions()
        options["frame"] = .string("+1")
        options["showStopAsAsterisk"] = .bool(true)

        let input = OperationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let result = try await plugin.transform(input)

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.sequence, "MAAA*")
        XCTAssertEqual(result.alphabet, .protein)
    }

    func testTranslateWithTrimToStop() async throws {
        let plugin = TranslationPlugin()

        let sequence = "ATGGCAGCAGCATAA"
        var options = OperationOptions()
        options["frame"] = .string("+1")
        options["trimToFirstStop"] = .bool(true)

        let input = OperationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let result = try await plugin.transform(input)

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.sequence, "MAAA")  // No stop codon
    }

    func testTranslateHideStops() async throws {
        let plugin = TranslationPlugin()

        let sequence = "ATGGCATAAGCA"  // M A * A
        var options = OperationOptions()
        options["frame"] = .string("+1")
        options["showStopAsAsterisk"] = .bool(false)
        options["trimToFirstStop"] = .bool(false)

        let input = OperationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let result = try await plugin.transform(input)

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.sequence, "MAA")  // Stop not shown
    }

    // MARK: - Reading Frames

    func testTranslateFrame2() async throws {
        let plugin = TranslationPlugin()

        // N + ATG + GCA + TAA = frame 2 gives: N-ATG, GGC, ATA, A
        let sequence = "NATGGCATAA"
        var options = OperationOptions()
        options["frame"] = .string("+2")

        let input = OperationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let result = try await plugin.transform(input)

        XCTAssertTrue(result.isSuccess)
        // Frame +2: ATG GCA TAA -> M A *
        XCTAssertEqual(result.sequence, "MA*")
    }

    func testTranslateFrame3() async throws {
        let plugin = TranslationPlugin()

        let sequence = "NNATGGCATAA"  // Frame 3 starts at position 2
        var options = OperationOptions()
        options["frame"] = .string("+3")

        let input = OperationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let result = try await plugin.transform(input)

        XCTAssertTrue(result.isSuccess)
        // Frame +3: ATG GCA TAA -> M A *
        XCTAssertEqual(result.sequence, "MA*")
    }

    func testTranslateReverseFrame() async throws {
        let plugin = TranslationPlugin()

        // Reverse complement of "ATGGCATAA" is "TTATGCCAT"
        // ATG GCA TAA -> reverse complement -> TTA TGC CAT
        // Reading the reverse: TAA TGC CAT -> * C H
        let sequence = "TTATGCCAT"
        var options = OperationOptions()
        options["frame"] = .string("-1")

        let input = OperationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let result = try await plugin.transform(input)

        XCTAssertTrue(result.isSuccess)
        // Reverse complement: ATG GCA TAA -> M A *
        XCTAssertEqual(result.sequence, "MA*")
    }

    // MARK: - Codon Tables

    func testStandardCodonTable() async throws {
        let plugin = TranslationPlugin()

        // Test all stop codons
        let sequence = "TAATAGTGA"  // Three stop codons
        var options = OperationOptions()
        options["frame"] = .string("+1")
        options["codonTable"] = .string("standard")

        let input = OperationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let result = try await plugin.transform(input)

        XCTAssertEqual(result.sequence, "***")
    }

    func testVertebrateMitoCodonTable() async throws {
        let plugin = TranslationPlugin()

        // In vertebrate mito: TGA = Trp (not stop), AGA = stop (not Arg)
        let sequence = "TGAAGA"
        var options = OperationOptions()
        options["frame"] = .string("+1")
        options["codonTable"] = .string("vertebrate_mito")

        let input = OperationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let result = try await plugin.transform(input)

        XCTAssertEqual(result.sequence, "W*")  // Trp + Stop
    }

    // MARK: - Codon Table Tests

    func testCodonTableBasicTranslation() {
        let table = CodonTable.standard

        XCTAssertEqual(table.translate("ATG"), "M")
        XCTAssertEqual(table.translate("GCA"), "A")
        XCTAssertEqual(table.translate("TAA"), "*")
        XCTAssertEqual(table.translate("TAG"), "*")
        XCTAssertEqual(table.translate("TGA"), "*")
    }

    func testCodonTableCaseInsensitive() {
        let table = CodonTable.standard

        XCTAssertEqual(table.translate("atg"), "M")
        XCTAssertEqual(table.translate("Atg"), "M")
        XCTAssertEqual(table.translate("ATG"), "M")
    }

    func testCodonTableRNACodons() {
        let table = CodonTable.standard

        // U should be treated as T
        XCTAssertEqual(table.translate("AUG"), "M")
        XCTAssertEqual(table.translate("UAA"), "*")
    }

    func testCodonTableStartCodons() {
        let standard = CodonTable.standard
        let bacterial = CodonTable.bacterial

        XCTAssertTrue(standard.isStartCodon("ATG"))
        XCTAssertTrue(bacterial.isStartCodon("ATG"))
        XCTAssertTrue(bacterial.isStartCodon("GTG"))
        XCTAssertTrue(bacterial.isStartCodon("TTG"))
    }

    func testCodonTableLookup() {
        XCTAssertNotNil(CodonTable.table(named: "standard"))
        XCTAssertNotNil(CodonTable.table(named: "bacterial"))
        XCTAssertNotNil(CodonTable.table(id: 1))
        XCTAssertNotNil(CodonTable.table(id: 11))
        XCTAssertNil(CodonTable.table(named: "nonexistent"))
    }

    // MARK: - Edge Cases

    func testRejectsProteinSequence() async {
        let plugin = TranslationPlugin()

        let input = OperationInput(
            sequence: "MVLSPADKTN",
            alphabet: .protein
        )

        do {
            _ = try await plugin.transform(input)
            XCTFail("Should have thrown error for protein sequence")
        } catch PluginError.unsupportedAlphabet {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPartialCodon() async throws {
        let plugin = TranslationPlugin()

        // 7 nucleotides = 2 codons + 1 leftover
        let sequence = "ATGGCAN"  // M A + leftover N
        var options = OperationOptions()
        options["frame"] = .string("+1")

        let input = OperationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let result = try await plugin.transform(input)

        XCTAssertEqual(result.sequence, "MA")  // Leftover not translated
    }

    func testUnknownCodon() async throws {
        let plugin = TranslationPlugin()

        let sequence = "ATGNNN"  // M + unknown
        var options = OperationOptions()
        options["frame"] = .string("+1")

        let input = OperationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let result = try await plugin.transform(input)

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.sequence, "MX")  // X for unknown
    }
}

// MARK: - Reverse Complement Tests

final class ReverseComplementTests: XCTestCase {

    func testSimpleReverseComplement() async throws {
        let plugin = ReverseComplementPlugin()

        let input = OperationInput(
            sequence: "ATCG",
            alphabet: .dna
        )

        let result = try await plugin.transform(input)

        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.sequence, "CGAT")
    }

    func testReverseComplementPreservesCase() async throws {
        let plugin = ReverseComplementPlugin()

        let input = OperationInput(
            sequence: "AtCg",
            alphabet: .dna
        )

        let result = try await plugin.transform(input)

        XCTAssertEqual(result.sequence, "cGaT")
    }

    func testReverseComplementAmbiguity() async throws {
        let plugin = ReverseComplementPlugin()

        let input = OperationInput(
            sequence: "RYSWKM",
            alphabet: .dna
        )

        let result = try await plugin.transform(input)

        // Input reversed: MKWSYR, then each base complemented: M->K, K->M, W->W, S->S, Y->R, R->Y
        // Result: KMWSRY
        XCTAssertEqual(result.sequence, "KMWSRY")
    }

    func testReverseComplementRNA() async throws {
        let plugin = ReverseComplementPlugin()

        let input = OperationInput(
            sequence: "AUCG",
            alphabet: .rna
        )

        let result = try await plugin.transform(input)

        // U -> A in reverse complement
        XCTAssertEqual(result.sequence, "CGAT")  // Note: U becomes A's complement
    }
}
