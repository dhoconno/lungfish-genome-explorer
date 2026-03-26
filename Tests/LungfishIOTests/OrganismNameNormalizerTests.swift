// OrganismNameNormalizerTests.swift - Tests for shared organism name normalization
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class OrganismNameNormalizerTests: XCTestCase {

    // MARK: - clean()

    func testCleanRemovesStar() {
        XCTAssertEqual(
            OrganismNameNormalizer.clean("★ WU Polyomavirus°"),
            "WU Polyomavirus"
        )
    }

    func testCleanRemovesBullet() {
        XCTAssertEqual(
            OrganismNameNormalizer.clean("\u{25CF} Escherichia coli"),
            "Escherichia coli"
        )
    }

    func testCleanRemovesDegreeSign() {
        XCTAssertEqual(
            OrganismNameNormalizer.clean("Virus name°"),
            "Virus name"
        )
    }

    func testCleanRepairsInfluenzaTruncation() {
        XCTAssertEqual(
            OrganismNameNormalizer.clean("nfluenza B virus (B/Lee/40)"),
            "Influenza B virus (B/Lee/40)"
        )
    }

    func testCleanRepairsInfluenzaWithDecorators() {
        XCTAssertEqual(
            OrganismNameNormalizer.clean("★ nfluenza A virus°"),
            "Influenza A virus"
        )
    }

    func testCleanPreservesNormalName() {
        XCTAssertEqual(
            OrganismNameNormalizer.clean("Escherichia coli"),
            "Escherichia coli"
        )
    }

    func testCleanTrimsWhitespace() {
        XCTAssertEqual(
            OrganismNameNormalizer.clean("  Staphylococcus aureus  "),
            "Staphylococcus aureus"
        )
    }

    func testCleanEmptyString() {
        XCTAssertEqual(OrganismNameNormalizer.clean(""), "")
    }

    func testCleanOnlyDecorators() {
        XCTAssertEqual(OrganismNameNormalizer.clean("★°\u{25CF}"), "")
    }

    func testCleanAccentedCharacters() {
        // Accented chars should be preserved
        XCTAssertEqual(
            OrganismNameNormalizer.clean("Bacillus cereus var. fluorescéns"),
            "Bacillus cereus var. fluorescéns"
        )
    }

    func testCleanUnicodeSpecialCharacters() {
        XCTAssertEqual(
            OrganismNameNormalizer.clean("★ Virus™ name®°"),
            "Virus™ name®"
        )
    }

    // MARK: - normalizedKey()

    func testNormalizedKeyLowercase() {
        XCTAssertEqual(
            OrganismNameNormalizer.normalizedKey("Escherichia Coli"),
            "escherichia coli"
        )
    }

    func testNormalizedKeyStripsNonAlphanumeric() {
        XCTAssertEqual(
            OrganismNameNormalizer.normalizedKey("E. coli (K-12)"),
            "e coli k 12"
        )
    }

    func testNormalizedKeyCollapsesWhitespace() {
        XCTAssertEqual(
            OrganismNameNormalizer.normalizedKey("Virus   with   spaces"),
            "virus with spaces"
        )
    }

    func testNormalizedKeyWithDecorators() {
        XCTAssertEqual(
            OrganismNameNormalizer.normalizedKey("★ WU Polyomavirus°"),
            "wu polyomavirus"
        )
    }

    func testNormalizedKeyEmpty() {
        XCTAssertEqual(OrganismNameNormalizer.normalizedKey(""), "")
    }

    func testNormalizedKeyMatchesCaseInsensitive() {
        // Two names that should map to the same key
        let key1 = OrganismNameNormalizer.normalizedKey("SARS-CoV-2")
        let key2 = OrganismNameNormalizer.normalizedKey("sars-cov-2")
        XCTAssertEqual(key1, key2)
    }

    func testNormalizedKeyMatchesWithDecorators() {
        let key1 = OrganismNameNormalizer.normalizedKey("★ Human adenovirus F°")
        let key2 = OrganismNameNormalizer.normalizedKey("Human adenovirus F")
        XCTAssertEqual(key1, key2)
    }

    func testNormalizedKeyWithInfluenzaTruncation() {
        let key1 = OrganismNameNormalizer.normalizedKey("★ nfluenza B virus°")
        let key2 = OrganismNameNormalizer.normalizedKey("Influenza B virus")
        XCTAssertEqual(key1, key2)
    }
}
