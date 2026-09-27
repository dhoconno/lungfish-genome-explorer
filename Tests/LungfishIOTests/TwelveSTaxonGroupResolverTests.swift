// TwelveSTaxonGroupResolverTests.swift - Group inference for loose 12S references
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// A loose 12S FASTA carries no `taxon_group`, so the Group column comes from
/// name inference. Macaques must land in Mammal the way the great apes do.
final class TwelveSTaxonGroupResolverTests: XCTestCase {
    func testExplicitGroupWinsOverInference() {
        XCTAssertEqual(
            TwelveSTaxonGroupResolver.groups(scientificName: "Macaca mulatta", explicitGroup: "Mammalia"),
            ["Mammal"]
        )
        XCTAssertEqual(
            TwelveSTaxonGroupResolver.groups(scientificName: "Homo sapiens", explicitGroup: "Fish"),
            ["Fish"]
        )
    }

    func testGreatApesAndMonkeysInferMammalFromGenus() {
        for name in [
            "Homo sapiens", "Pan troglodytes", "Gorilla gorilla",
            "Macaca mulatta", "Macaca fascicularis", "Macaca nemestrina",
            "Papio anubis", "Chlorocebus sabaeus", "Callithrix jacchus",
        ] {
            XCTAssertEqual(TwelveSTaxonGroupResolver.groups(scientificName: name), ["Mammal"], name)
        }
    }

    func testCommonNamesInferMammal() {
        XCTAssertEqual(
            TwelveSTaxonGroupResolver.groups(scientificName: "Unknown sp.", commonName: "rhesus macaque"),
            ["Mammal"]
        )
        XCTAssertEqual(
            TwelveSTaxonGroupResolver.groups(scientificName: "Unknown sp.", displayName: "olive baboon (Unknown sp.)"),
            ["Mammal"]
        )
    }

    func testUnknownNamesInferNothing() {
        XCTAssertEqual(TwelveSTaxonGroupResolver.groups(scientificName: "Xyzzy plugh"), [])
    }
}
