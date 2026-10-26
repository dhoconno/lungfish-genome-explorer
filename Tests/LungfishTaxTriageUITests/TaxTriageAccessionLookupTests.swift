// TaxTriageAccessionLookupTests.swift - A TaxTriage row opens its own reference or none, never another organism's
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.0 lane TT-FUZZY-NAME (S1, BIO ruling of 2026-10-26). A row that no tax ID map covers is looked up by its
// normalized name. The lookup used to take the first map key that contained the name or that the name contained,
// and then the key with the best token overlap from 0.75. "human papillomavirus type 1" opened the reference of
// "human papillomavirus type 16", and "human betaherpesvirus 6" opened the 6A or the 6B reference, whichever
// key the dictionary of that launch listed first. The lookup now answers with the exact normalized key or with nil.

import XCTest
@testable import LungfishTaxTriageUI

final class TaxTriageAccessionLookupTests: XCTestCase {

    private func lookup(
        _ name: String, in map: [String: [String]], readCounts: [String: Int] = [:]
    ) -> [String]? {
        TaxTriageAccessionLookup.accessions(for: name, in: map, readCounts: readCounts)
    }

    // MARK: - Red at the base

    /// The name is a prefix of another key. The base returns the type 16 accession for a type 1 row.
    func testANameThatIsNoKeyTakesNoOtherSpecies() {
        let map = ["human papillomavirus type 16": ["NC_001526.4"]]
        XCTAssertNil(
            lookup("human papillomavirus type 1", in: map),
            "type 1 is not a key, so it must not open the reference of type 16"
        )
    }

    /// The reverse direction. A key is part of the name, so the base returns the species-level accession for a
    /// subtype row.
    func testAKeyInsideTheNameTakesNoOtherSpecies() {
        let map = ["influenza a virus": ["NC_TEST_FLUA"]]
        XCTAssertNil(
            lookup("influenza a virus h3n2", in: map),
            "a subtype row must not open the reference recorded for the species name alone"
        )
    }

    /// Two keys contain the name. The base returns one of them, and which one depends on the launch, since a
    /// Swift dictionary orders its keys from a seed that each process picks.
    func testTwoMatchingKeysGiveNoPick() {
        let map = [
            "human betaherpesvirus 6a": ["NC_001664.4"],
            "human betaherpesvirus 6b": ["NC_000898.1"],
        ]
        XCTAssertNil(
            lookup("human betaherpesvirus 6", in: map),
            "6A and 6B are two species, so a row named for neither opens neither"
        )
    }

    /// No key contains the name and the name contains no key, but 3 of 4 tokens agree (0.75), which the base
    /// took as the same organism.
    func testANameOfSimilarTokensTakesNoOtherSpecies() {
        let map = ["escherichia coli o157 h7": ["NC_TEST_O157H7"]]
        XCTAssertNil(
            lookup("escherichia coli o157 h8", in: map),
            "a serotype that differs in one token is another organism"
        )
    }

    /// A key that holds no accession records no reference, so it must not hand the row to a longer key.
    func testAnExactKeyWithNoAccessionsOpensNothing() {
        let map = ["alpha virus": [], "alpha virus beta": ["NC_TEST_BETA"]]
        XCTAssertNil(lookup("alpha virus", in: map))
    }

    // MARK: - Guards that pass at the base

    func testAnEmptyNameResolvesNothing() {
        XCTAssertNil(lookup("", in: ["alpha virus": ["NC_TEST_ALPHA"]]))
    }

    /// The exact key wins even when it is also part of a longer key.
    func testTheExactNameStillResolves() {
        let map = [
            "human papillomavirus type 1": ["NC_TEST_HPV1"],
            "human papillomavirus type 16": ["NC_001526.4"],
        ]
        XCTAssertEqual(lookup("human papillomavirus type 1", in: map), ["NC_TEST_HPV1"])
        XCTAssertEqual(lookup("human papillomavirus type 16", in: map), ["NC_001526.4"])
    }

    /// Most mapped reads first, equal counts by accession, repeats dropped and an accession with no count last.
    func testTheExactNameIsRankedByReadSupport() {
        let map = ["human papillomavirus type 16": ["NC_D", "NC_B", "NC_A", "NC_C", "NC_A"]]
        let counts = ["NC_C": 50, "NC_A": 10, "NC_B": 10]
        XCTAssertEqual(
            lookup("human papillomavirus type 16", in: map, readCounts: counts),
            ["NC_C", "NC_A", "NC_B", "NC_D"]
        )
    }

    // MARK: - Order

    /// The answer is the same for every order the keys can take. A dictionary lists its keys by hash and bucket,
    /// and the base picked the first key that matched. The same keys inserted in the two orders and into tables
    /// of different sizes list differently, so this walks both orders over several capacities. The seed of the
    /// process decides how many of them differ at the base, so the deterministic reds are the tests above.
    func testLookupIsTheSameForEveryKeyOrder() {
        let pairs: [(String, [String])] = [
            ("human betaherpesvirus 6a", ["NC_001664.4"]),
            ("human betaherpesvirus 6b", ["NC_000898.1"]),
            ("human betaherpesvirus 7", ["NC_TEST_HHV7"]),
        ]
        var results: [[String]?] = []
        for capacity in [0, 2, 8, 64, 512, 4096, 32768] {
            for order in [pairs, Array(pairs.reversed())] {
                var map = [String: [String]](minimumCapacity: capacity)
                for (key, accessions) in order { map[key] = accessions }
                results.append(lookup("human betaherpesvirus 6", in: map))
            }
        }
        let first = results[0]
        for (index, result) in results.enumerated() {
            XCTAssertEqual(result, first, "the answer for walk \(index) differs from the first walk's")
        }
    }
}
