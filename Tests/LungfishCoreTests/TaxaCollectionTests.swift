// TaxaCollectionTests.swift - Tests for taxa collection model
// Copyright (c) 2025 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

final class TaxaCollectionTests: XCTestCase {

    // MARK: - Built-in Collections

    func testBuiltInCollectionsExist() {
        XCTAssertEqual(TaxaCollection.builtIn.count, 8, "Should have 8 built-in collections")
    }

    func testBuiltInCollectionsHaveUniqueIDs() {
        let ids = TaxaCollection.builtIn.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "Collection IDs must be unique")
    }

    func testAllBuiltInCollectionsHaveTaxa() {
        for collection in TaxaCollection.builtIn {
            XCTAssertFalse(collection.taxa.isEmpty, "Collection '\(collection.name)' should have taxa")
            XCTAssertFalse(collection.name.isEmpty)
            XCTAssertFalse(collection.description.isEmpty)
            XCTAssertFalse(collection.sfSymbol.isEmpty)
            XCTAssertEqual(collection.tier, .builtin)
        }
    }

    func testAllTaxaHaveValidTaxIds() {
        for collection in TaxaCollection.builtIn {
            for taxon in collection.taxa {
                XCTAssertGreaterThan(taxon.taxId, 0,
                    "Taxon '\(taxon.name)' in '\(collection.name)' must have valid tax ID")
                XCTAssertFalse(taxon.name.isEmpty)
            }
        }
    }

    // MARK: - Specific Collections

    func testRespiratoryViruses() {
        let collection = TaxaCollection.respiratoryViruses
        XCTAssertEqual(collection.id, "respiratory-viruses")
        XCTAssertEqual(collection.taxa.count, 12)
        XCTAssertTrue(collection.taxa.contains { $0.taxId == 2697049 }, "Should include SARS-CoV-2")
        XCTAssertTrue(collection.taxa.contains { $0.taxId == 11320 }, "Should include Influenza A")
        XCTAssertTrue(collection.taxa.contains { $0.taxId == 12814 }, "Should include RSV")
    }

    func testEntericViruses() {
        let collection = TaxaCollection.entericViruses
        XCTAssertEqual(collection.id, "enteric-viruses")
        XCTAssertTrue(collection.taxa.contains { $0.taxId == 142786 }, "Should include Norovirus")
        XCTAssertTrue(collection.taxa.contains { $0.taxId == 10912 }, "Should include Rotavirus")
    }

    func testWastewaterSurveillance() {
        let collection = TaxaCollection.wastewaterSurveillance
        XCTAssertEqual(collection.id, "wastewater-surveillance")
        XCTAssertTrue(collection.taxa.contains { $0.commonName == "SARS-CoV-2" })
        XCTAssertTrue(collection.taxa.contains { $0.commonName == "Mpox" })
    }

    func testAMROrganisms() {
        let collection = TaxaCollection.amrOrganisms
        XCTAssertEqual(collection.id, "amr-eskape")
        // ESKAPE = 6 organisms
        XCTAssertEqual(collection.taxa.count, 6)
    }

    // MARK: - TaxonTarget

    func testTaxonTargetDisplayName() {
        let withCommon = TaxonTarget(name: "Influenza A virus", taxId: 11320, commonName: "Influenza A")
        XCTAssertEqual(withCommon.displayName, "Influenza A")

        let withoutCommon = TaxonTarget(name: "Streptococcus pneumoniae", taxId: 1313)
        XCTAssertEqual(withoutCommon.displayName, "Streptococcus pneumoniae")
    }

    func testTaxonTargetIdentifiable() {
        let target = TaxonTarget(name: "Test", taxId: 12345)
        XCTAssertEqual(target.id, 12345)
    }

    func testTaxonTargetCodable() throws {
        let original = TaxonTarget(name: "Test Virus", taxId: 99999, includeChildren: true, commonName: "TV")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TaxonTarget.self, from: data)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.taxId, original.taxId)
        XCTAssertEqual(decoded.includeChildren, original.includeChildren)
        XCTAssertEqual(decoded.commonName, original.commonName)
    }

    // MARK: - CollectionTier

    func testCollectionTierCodable() throws {
        for tier in CollectionTier.allCases {
            let data = try JSONEncoder().encode(tier)
            let decoded = try JSONDecoder().decode(CollectionTier.self, from: data)
            XCTAssertEqual(decoded, tier)
        }
    }

    // MARK: - Custom Collection

    func testCustomCollectionCreation() {
        let custom = TaxaCollection(
            id: "my-custom",
            name: "My Custom Set",
            description: "A custom collection",
            sfSymbol: "star",
            taxa: [
                TaxonTarget(name: "Test Organism", taxId: 12345),
            ],
            tier: .appWide
        )

        XCTAssertEqual(custom.tier, .appWide)
        XCTAssertEqual(custom.taxonCount, 1)
    }

    func testCollectionCodableRoundTrip() throws {
        let original = TaxaCollection.respiratoryViruses
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TaxaCollection.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.taxa.count, original.taxa.count)
        XCTAssertEqual(decoded.tier, original.tier)
    }
}
