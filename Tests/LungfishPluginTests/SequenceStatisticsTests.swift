// SequenceStatisticsTests.swift - Tests for sequence statistics plugin
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishPlugin

final class SequenceStatisticsTests: XCTestCase {

    // MARK: - Basic Statistics

    func testBasicDNAStatistics() async throws {
        let plugin = SequenceStatisticsPlugin()

        let sequence = "ATCGATCGATCG"  // 12 bp, 50% GC
        let input = AnalysisInput(
            sequence: sequence,
            alphabet: .dna
        )

        let result = try await plugin.analyze(input)

        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(result.summary.contains("12 bp"))
        XCTAssertTrue(result.summary.contains("50.0% GC"))
    }

    func testProteinStatistics() async throws {
        let plugin = SequenceStatisticsPlugin()

        let sequence = "MVLSPADKTN"  // 10 aa
        let input = AnalysisInput(
            sequence: sequence,
            alphabet: .protein
        )

        let result = try await plugin.analyze(input)

        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(result.summary.contains("10 amino acids"))
    }

    // MARK: - GC Content

    func testGCContent100Percent() async throws {
        let plugin = SequenceStatisticsPlugin()

        let sequence = "GCGCGCGCGC"  // 100% GC
        let input = AnalysisInput(
            sequence: sequence,
            alphabet: .dna
        )

        let result = try await plugin.analyze(input)

        XCTAssertTrue(result.summary.contains("100.0% GC"))
    }

    func testGCContent0Percent() async throws {
        let plugin = SequenceStatisticsPlugin()

        let sequence = "ATATATATAT"  // 0% GC
        let input = AnalysisInput(
            sequence: sequence,
            alphabet: .dna
        )

        let result = try await plugin.analyze(input)

        XCTAssertTrue(result.summary.contains("0.0% GC"))
    }

    func testGCContentMixed() async throws {
        let plugin = SequenceStatisticsPlugin()

        let sequence = "ATGC"  // 50% GC
        let input = AnalysisInput(
            sequence: sequence,
            alphabet: .dna
        )

        let result = try await plugin.analyze(input)

        XCTAssertTrue(result.summary.contains("50.0% GC"))
    }

    // MARK: - Composition

    func testCompositionSection() async throws {
        let plugin = SequenceStatisticsPlugin()

        let sequence = "AAATTTCCCGGG"  // 3 of each
        let input = AnalysisInput(
            sequence: sequence,
            alphabet: .dna
        )

        let result = try await plugin.analyze(input)

        let compositionSection = result.sections.first { $0.title == "Composition" }
        XCTAssertNotNil(compositionSection)

        if case .table(let headers, let rows) = compositionSection?.content {
            XCTAssertEqual(headers, ["Residue", "Count", "Percentage"])
            XCTAssertEqual(rows.count, 4)  // A, C, G, T

            // Each base should be 25%
            for row in rows {
                XCTAssertEqual(row[1], "3")  // Count
                XCTAssertTrue(row[2].contains("25"))  // Percentage
            }
        } else {
            XCTFail("Expected table content")
        }
    }

    // MARK: - Codon Usage

    func testCodonUsage() async throws {
        let plugin = SequenceStatisticsPlugin()

        let sequence = "ATGATGATG"  // 3x ATG (Methionine)
        var options = AnalysisOptions()
        options["showCodonUsage"] = .bool(true)

        let input = AnalysisInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let result = try await plugin.analyze(input)

        let codonSection = result.sections.first { $0.title.contains("Codon Usage") }
        XCTAssertNotNil(codonSection)

        if case .table(_, let rows) = codonSection?.content {
            let atgRow = rows.first { $0[0] == "ATG" }
            XCTAssertNotNil(atgRow)
            XCTAssertEqual(atgRow?[1], "M")  // Amino acid
            XCTAssertEqual(atgRow?[2], "3")  // Count
        } else {
            XCTFail("Expected table content")
        }
    }

    func testNoCodonUsageForShortSequence() async throws {
        let plugin = SequenceStatisticsPlugin()

        let sequence = "AT"  // Too short for codons
        var options = AnalysisOptions()
        options["showCodonUsage"] = .bool(true)

        let input = AnalysisInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let result = try await plugin.analyze(input)

        // Should not have codon usage section
        let codonSection = result.sections.first { $0.title.contains("Codon Usage") }
        XCTAssertNil(codonSection)
    }

    // MARK: - Dinucleotide Frequencies

    func testDinucleotideFrequencies() async throws {
        let plugin = SequenceStatisticsPlugin()

        let sequence = "ATATATAT"  // Alternating AT
        var options = AnalysisOptions()
        options["showDinucleotides"] = .bool(true)

        let input = AnalysisInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let result = try await plugin.analyze(input)

        let dinucSection = result.sections.first { $0.title.contains("Dinucleotide") }
        XCTAssertNotNil(dinucSection)

        if case .table(_, let rows) = dinucSection?.content {
            // Should have AT and TA dinucleotides
            let atRow = rows.first { $0[0] == "AT" }
            let taRow = rows.first { $0[0] == "TA" }
            XCTAssertNotNil(atRow)
            XCTAssertNotNil(taRow)
        } else {
            XCTFail("Expected table content")
        }
    }

    // MARK: - Nucleotide Statistics

    func testPurinesPyrimidines() async throws {
        let plugin = SequenceStatisticsPlugin()

        let sequence = "AAGGCCTT"  // 4 purines (A, G), 4 pyrimidines (C, T)
        let input = AnalysisInput(
            sequence: sequence,
            alphabet: .dna
        )

        let result = try await plugin.analyze(input)

        let statsSection = result.sections.first { $0.title == "Nucleotide Statistics" }
        XCTAssertNotNil(statsSection)

        if case .keyValue(let pairs) = statsSection?.content {
            let purines = pairs.first { $0.0.contains("Purines") }
            let pyrimidines = pairs.first { $0.0.contains("Pyrimidines") }

            XCTAssertNotNil(purines)
            XCTAssertNotNil(pyrimidines)
            XCTAssertTrue(purines?.1.contains("50.0%") ?? false)
            XCTAssertTrue(pyrimidines?.1.contains("50.0%") ?? false)
        } else {
            XCTFail("Expected keyValue content")
        }
    }

    // MARK: - Protein Statistics

    func testProteinHydrophobicity() async throws {
        let plugin = SequenceStatisticsPlugin()

        let sequence = "AAAIIILLL"  // All hydrophobic (A, I, L)
        let input = AnalysisInput(
            sequence: sequence,
            alphabet: .protein
        )

        let result = try await plugin.analyze(input)

        let statsSection = result.sections.first { $0.title == "Protein Statistics" }
        XCTAssertNotNil(statsSection)

        if case .keyValue(let pairs) = statsSection?.content {
            let hydrophobic = pairs.first { $0.0.contains("Hydrophobic") }
            XCTAssertNotNil(hydrophobic)
            XCTAssertTrue(hydrophobic?.1.contains("100.0%") ?? false)
        } else {
            XCTFail("Expected keyValue content")
        }
    }

    func testProteinNetCharge() async throws {
        let plugin = SequenceStatisticsPlugin()

        let sequence = "KKKDDD"  // 3 basic (K), 3 acidic (D)
        let input = AnalysisInput(
            sequence: sequence,
            alphabet: .protein
        )

        let result = try await plugin.analyze(input)

        let statsSection = result.sections.first { $0.title == "Protein Statistics" }
        XCTAssertNotNil(statsSection)

        if case .keyValue(let pairs) = statsSection?.content {
            let charge = pairs.first { $0.0.contains("Net Charge") }
            XCTAssertNotNil(charge)
            XCTAssertTrue(charge?.1.contains("+0") ?? false || charge?.1.contains("0") ?? false)
        } else {
            XCTFail("Expected keyValue content")
        }
    }

    // MARK: - Export Data

    func testExportData() async throws {
        let plugin = SequenceStatisticsPlugin()

        let sequence = "ATCG"
        let input = AnalysisInput(
            sequence: sequence,
            alphabet: .dna
        )

        let result = try await plugin.analyze(input)

        XCTAssertNotNil(result.exportData)
        XCTAssertEqual(result.exportData?.format, .tsv)
        XCTAssertTrue(result.exportData?.content.contains("Residue") ?? false)
    }

    // MARK: - Edge Cases

    func testEmptySequence() async throws {
        let plugin = SequenceStatisticsPlugin()

        let input = AnalysisInput(
            sequence: "",
            alphabet: .dna
        )

        let result = try await plugin.analyze(input)

        XCTAssertFalse(result.isSuccess)
        XCTAssertTrue(result.errorMessage?.contains("empty") ?? false)
    }

    func testSelectionAnalysis() async throws {
        let plugin = SequenceStatisticsPlugin()

        let sequence = "ATATATGCGCGC"  // First half AT-rich, second half GC-rich
        let input = AnalysisInput(
            sequence: sequence,
            alphabet: .dna,
            selection: 6..<12  // GC-rich region
        )

        let result = try await plugin.analyze(input)

        XCTAssertTrue(result.isSuccess)
        // Selection is GCGCGC = 100% GC
        XCTAssertTrue(result.summary.contains("100.0% GC"))
    }
}
