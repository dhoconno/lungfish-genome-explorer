// RestrictionSiteFinderTests.swift - Tests for restriction site finder
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishPlugin

final class RestrictionSiteFinderTests: XCTestCase {

    // MARK: - Enzyme Database Tests

    func testEnzymeDatabaseContainsCommonEnzymes() {
        let db = RestrictionEnzymeDatabase.shared

        XCTAssertNotNil(db.enzyme(named: "EcoRI"))
        XCTAssertNotNil(db.enzyme(named: "BamHI"))
        XCTAssertNotNil(db.enzyme(named: "HindIII"))
        XCTAssertNotNil(db.enzyme(named: "NotI"))
    }

    func testEcoRIProperties() {
        let enzyme = RestrictionEnzymeDatabase.shared.enzyme(named: "EcoRI")!

        XCTAssertEqual(enzyme.name, "EcoRI")
        XCTAssertEqual(enzyme.recognitionSite, "GAATTC")
        XCTAssertEqual(enzyme.overhangType, .fivePrime)
        XCTAssertTrue(enzyme.isPalindromic)
    }

    func testBluntCutter() {
        let enzyme = RestrictionEnzymeDatabase.shared.enzyme(named: "EcoRV")!

        XCTAssertEqual(enzyme.recognitionSite, "GATATC")
        XCTAssertEqual(enzyme.overhangType, .blunt)
        XCTAssertEqual(enzyme.cutPositionForward, 3)
        XCTAssertEqual(enzyme.cutPositionReverse, 3)
    }

    func testThreePrimeOverhang() {
        let enzyme = RestrictionEnzymeDatabase.shared.enzyme(named: "PstI")!

        XCTAssertEqual(enzyme.overhangType, .threePrime)
    }

    func testEnzymeSearch() {
        let db = RestrictionEnzymeDatabase.shared

        let ecoResults = db.search("Eco")
        XCTAssertTrue(ecoResults.contains { $0.name == "EcoRI" })
        XCTAssertTrue(ecoResults.contains { $0.name == "EcoRV" })

        let gaattcResults = db.search("GAATTC")
        XCTAssertTrue(gaattcResults.contains { $0.name == "EcoRI" })
    }

    // MARK: - Site Finding Tests

    func testFindEcoRISites() async throws {
        let plugin = RestrictionSiteFinderPlugin()

        // Sequence with two EcoRI sites
        // ATCGAATTCGGGGAATTCATCG
        // Position: 0123456789...
        // First GAATTC at position 3, second at position 12 (last G of GGGG starts site)
        let sequence = "ATCGAATTCGGGGAATTCATCG"
        var options = AnnotationOptions()
        options["enzymes"] = .stringArray(["EcoRI"])

        let input = AnnotationInput(
            sequence: sequence,
            sequenceName: "test",
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        XCTAssertEqual(annotations.count, 2)
        XCTAssertEqual(annotations[0].start, 3)
        XCTAssertEqual(annotations[1].start, 12)
    }

    func testFindNoSites() async throws {
        let plugin = RestrictionSiteFinderPlugin()

        // Sequence without EcoRI sites
        let sequence = "ATCGATCGATCGATCG"
        var options = AnnotationOptions()
        options["enzymes"] = .stringArray(["EcoRI"])

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        XCTAssertTrue(annotations.isEmpty)
    }

    func testFindMultipleEnzymes() async throws {
        let plugin = RestrictionSiteFinderPlugin()

        // Sequence with EcoRI and BamHI sites
        let sequence = "GAATTCATCGGGATCCATCG"
        var options = AnnotationOptions()
        options["enzymes"] = .stringArray(["EcoRI", "BamHI"])

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        XCTAssertEqual(annotations.count, 2)

        let ecoRI = annotations.first { $0.qualifiers["enzyme"] == "EcoRI" }
        let bamHI = annotations.first { $0.qualifiers["enzyme"] == "BamHI" }

        XCTAssertNotNil(ecoRI)
        XCTAssertNotNil(bamHI)
        XCTAssertEqual(ecoRI?.start, 0)
        XCTAssertEqual(bamHI?.start, 10)
    }

    func testRejectsProteinSequence() async {
        let plugin = RestrictionSiteFinderPlugin()

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

    func testCaseInsensitive() async throws {
        let plugin = RestrictionSiteFinderPlugin()

        // Lowercase sequence
        let sequence = "atcgaattcgggg"
        var options = AnnotationOptions()
        options["enzymes"] = .stringArray(["EcoRI"])

        let input = AnnotationInput(
            sequence: sequence,
            alphabet: .dna,
            options: options
        )

        let annotations = try await plugin.generateAnnotations(input)

        XCTAssertEqual(annotations.count, 1)
    }

    // MARK: - Compatible Ends Tests

    func testCompatibleEnzymes() {
        let db = RestrictionEnzymeDatabase.shared
        let ecoRI = db.enzyme(named: "EcoRI")!

        let compatible = db.compatibleEnzymes(with: ecoRI)

        // BamHI has compatible ends with EcoRI (both 5' AATT overhangs)
        // Note: In our simplified database, we check same overhang type and length
        XCTAssertTrue(compatible.allSatisfy { $0.overhangType == .fivePrime })
    }
}
