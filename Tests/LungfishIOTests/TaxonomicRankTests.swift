// TaxonomicRankTests.swift - Tests for TaxonomicRank enum
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class TaxonomicRankTests: XCTestCase {

    // MARK: - Standard Rank Initialization

    func testStandardRankCodes() {
        XCTAssertEqual(TaxonomicRank(code: "U"), .unclassified)
        XCTAssertEqual(TaxonomicRank(code: "R"), .root)
        XCTAssertEqual(TaxonomicRank(code: "D"), .domain)
        XCTAssertEqual(TaxonomicRank(code: "K"), .kingdom)
        XCTAssertEqual(TaxonomicRank(code: "P"), .phylum)
        XCTAssertEqual(TaxonomicRank(code: "C"), .class)
        XCTAssertEqual(TaxonomicRank(code: "O"), .order)
        XCTAssertEqual(TaxonomicRank(code: "F"), .family)
        XCTAssertEqual(TaxonomicRank(code: "G"), .genus)
        XCTAssertEqual(TaxonomicRank(code: "S"), .species)
    }

    // MARK: - Intermediate Ranks

    func testIntermediateRankCodes() {
        let r1 = TaxonomicRank(code: "R1")
        XCTAssertEqual(r1, .intermediate("R1"))

        let d1 = TaxonomicRank(code: "D1")
        XCTAssertEqual(d1, .intermediate("D1"))

        let s1 = TaxonomicRank(code: "S1")
        XCTAssertEqual(s1, .intermediate("S1"))

        let s2 = TaxonomicRank(code: "S2")
        XCTAssertEqual(s2, .intermediate("S2"))

        let s3 = TaxonomicRank(code: "S3")
        XCTAssertEqual(s3, .intermediate("S3"))

        let p1 = TaxonomicRank(code: "P1")
        XCTAssertEqual(p1, .intermediate("P1"))
    }

    // MARK: - Unknown Ranks

    func testUnknownRankCodes() {
        let unknown = TaxonomicRank(code: "X")
        XCTAssertEqual(unknown, .unknown("X"))

        let lowercaseUnknown = TaxonomicRank(code: "s")
        XCTAssertEqual(lowercaseUnknown, .unknown("s"))

        let empty = TaxonomicRank(code: "")
        XCTAssertEqual(empty, .unknown(""))
    }

    // MARK: - Whitespace Handling

    func testWhitespaceTrimmingInCode() {
        XCTAssertEqual(TaxonomicRank(code: " R "), .root)
        XCTAssertEqual(TaxonomicRank(code: "  S1  "), .intermediate("S1"))
    }

    // MARK: - Ring Index Ordering

    func testRingIndexStrictlyIncreasing() {
        let standardRanks = TaxonomicRank.standardRanks
        for i in 1 ..< standardRanks.count {
            XCTAssertGreaterThan(
                standardRanks[i].ringIndex,
                standardRanks[i - 1].ringIndex,
                "\(standardRanks[i]) should have higher ringIndex than \(standardRanks[i - 1])"
            )
        }
    }

    func testRingIndexValues() {
        XCTAssertEqual(TaxonomicRank.unclassified.ringIndex, -1)
        XCTAssertEqual(TaxonomicRank.root.ringIndex, 0)
        XCTAssertEqual(TaxonomicRank.domain.ringIndex, 1)
        XCTAssertEqual(TaxonomicRank.kingdom.ringIndex, 2)
        XCTAssertEqual(TaxonomicRank.phylum.ringIndex, 3)
        XCTAssertEqual(TaxonomicRank.class.ringIndex, 4)
        XCTAssertEqual(TaxonomicRank.order.ringIndex, 5)
        XCTAssertEqual(TaxonomicRank.family.ringIndex, 6)
        XCTAssertEqual(TaxonomicRank.genus.ringIndex, 7)
        XCTAssertEqual(TaxonomicRank.species.ringIndex, 8)
    }

    func testIntermediateRingIndex() {
        // S1, S2 should be at ring index 9 (below species)
        XCTAssertEqual(TaxonomicRank.intermediate("S1").ringIndex, 9)
        XCTAssertEqual(TaxonomicRank.intermediate("S2").ringIndex, 9)

        // D1 should map to domain's ring index (1)
        XCTAssertEqual(TaxonomicRank.intermediate("D1").ringIndex, 1)

        // R1 should map to root's ring index (0)
        XCTAssertEqual(TaxonomicRank.intermediate("R1").ringIndex, 0)

        // P1 should map to phylum's ring index (3)
        XCTAssertEqual(TaxonomicRank.intermediate("P1").ringIndex, 3)
    }

    // MARK: - Display Names

    func testStandardRankDisplayNames() {
        XCTAssertEqual(TaxonomicRank.unclassified.displayName, "Unclassified")
        XCTAssertEqual(TaxonomicRank.root.displayName, "Root")
        XCTAssertEqual(TaxonomicRank.domain.displayName, "Domain")
        XCTAssertEqual(TaxonomicRank.kingdom.displayName, "Kingdom")
        XCTAssertEqual(TaxonomicRank.phylum.displayName, "Phylum")
        XCTAssertEqual(TaxonomicRank.class.displayName, "Class")
        XCTAssertEqual(TaxonomicRank.order.displayName, "Order")
        XCTAssertEqual(TaxonomicRank.family.displayName, "Family")
        XCTAssertEqual(TaxonomicRank.genus.displayName, "Genus")
        XCTAssertEqual(TaxonomicRank.species.displayName, "Species")
    }

    func testIntermediateRankDisplayNames() {
        XCTAssertEqual(TaxonomicRank.intermediate("S1").displayName, "Subspecies")
        XCTAssertEqual(TaxonomicRank.intermediate("S2").displayName, "Strain")
        XCTAssertEqual(TaxonomicRank.intermediate("S3").displayName, "Sub-strain")
        XCTAssertEqual(TaxonomicRank.intermediate("D1").displayName, "Sub-domain")
        XCTAssertEqual(TaxonomicRank.intermediate("P1").displayName, "Sub-phylum")
    }

    // MARK: - Code Round-Trip

    func testCodeRoundTrip() {
        let ranks: [TaxonomicRank] = [
            .unclassified, .root, .domain, .kingdom, .phylum, .class,
            .order, .family, .genus, .species,
            .intermediate("S1"), .intermediate("D1"), .intermediate("R1"),
        ]

        for rank in ranks {
            let code = rank.code
            let reconstructed = TaxonomicRank(code: code)
            XCTAssertEqual(reconstructed, rank,
                           "Round-trip failed for \(rank) with code '\(code)'")
        }
    }

    // MARK: - isStandard

    func testIsStandard() {
        XCTAssertTrue(TaxonomicRank.root.isStandard)
        XCTAssertTrue(TaxonomicRank.species.isStandard)
        XCTAssertTrue(TaxonomicRank.unclassified.isStandard)
        XCTAssertFalse(TaxonomicRank.intermediate("S1").isStandard)
        XCTAssertFalse(TaxonomicRank.unknown("X").isStandard)
    }

    // MARK: - Parent Standard Rank

    func testParentStandardRank() {
        XCTAssertEqual(TaxonomicRank.root.parentStandardRank, .root)
        XCTAssertEqual(TaxonomicRank.species.parentStandardRank, .species)
        XCTAssertEqual(TaxonomicRank.intermediate("S1").parentStandardRank, .species)
        XCTAssertEqual(TaxonomicRank.intermediate("D1").parentStandardRank, .domain)
        XCTAssertEqual(TaxonomicRank.intermediate("P1").parentStandardRank, .phylum)
        XCTAssertNil(TaxonomicRank.unknown("X").parentStandardRank)
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let ranks: [TaxonomicRank] = [
            .root, .species, .intermediate("S1"), .unclassified,
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for rank in ranks {
            let data = try encoder.encode(rank)
            let decoded = try decoder.decode(TaxonomicRank.self, from: data)
            XCTAssertEqual(decoded, rank, "Codable round-trip failed for \(rank)")
        }
    }

    func testCodableDecodesFromString() throws {
        let decoder = JSONDecoder()

        let json = "\"S1\""
        let data = json.data(using: .utf8)!
        let rank = try decoder.decode(TaxonomicRank.self, from: data)
        XCTAssertEqual(rank, .intermediate("S1"))

        let rootJson = "\"R\""
        let rootData = rootJson.data(using: .utf8)!
        let rootRank = try decoder.decode(TaxonomicRank.self, from: rootData)
        XCTAssertEqual(rootRank, .root)
    }

    // MARK: - Hashable

    func testHashable() {
        var set: Set<TaxonomicRank> = []
        set.insert(.root)
        set.insert(.species)
        set.insert(.root) // Duplicate
        set.insert(.intermediate("S1"))
        set.insert(.intermediate("S1")) // Duplicate

        XCTAssertEqual(set.count, 3)
    }

    // MARK: - CustomStringConvertible

    func testDescription() {
        XCTAssertEqual(String(describing: TaxonomicRank.root), "Root")
        XCTAssertEqual(String(describing: TaxonomicRank.species), "Species")
        XCTAssertEqual(String(describing: TaxonomicRank.intermediate("S1")), "Subspecies")
    }

    // MARK: - Standard Ranks Collection

    func testStandardRanksCollection() {
        let standard = TaxonomicRank.standardRanks
        XCTAssertEqual(standard.count, 9)
        XCTAssertEqual(standard.first, .root)
        XCTAssertEqual(standard.last, .species)

        // Should not include unclassified or intermediate
        XCTAssertFalse(standard.contains(.unclassified))
    }
}
