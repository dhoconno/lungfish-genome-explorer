// VariantStructuredINFOProfilePinTests.swift - Pins what each import profile writes for ANN and CSQ annotations
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// Pins, per import profile, the `variant_info` keys, the INFO filter results and the CSQ part names that an import of
/// `StructuredINFOFixture` writes (lane 13.37, QA 1).
final class VariantStructuredINFOProfilePinTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StructuredINFOPins-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    // MARK: - Expectations

    /// The keys the inline import of `fast` and `low-memory` writes. A SnpEff ANN, whose header holds no `Format: `,
    /// stays one row, and a split CSQ loses its raw row.
    private static let inlineKeys: [Int: [String]] = [
        100: ["ANN", "DP"],
        200: ["ANN", "DP"],
        300: ["DP"] + StructuredINFOFixture.csqPartsAt300,
    ]

    /// The keys the materializer of `ultra-low-memory` writes.
    private static let materializedKeys: [Int: [String]] = [
        100: ["DP", "ANN", "ANN_entries"] + StructuredINFOFixture.annPartsAt100 + StructuredINFOFixture.annAliases,
        200: ["DP", "ANN"] + StructuredINFOFixture.annPartsAt200 + StructuredINFOFixture.annAliases,
        300: ["DP", "CSQ"] + StructuredINFOFixture.csqPartsAt300,
    ]

    private static let expectedKeys: [VCFImportProfile: [Int: [String]]] = [
        .fast: inlineKeys, .lowMemory: inlineKeys, .ultraLowMemory: materializedKeys,
    ]

    private static let expectedRowCounts: [VCFImportProfile: Int] = [.fast: 23, .lowMemory: 23, .ultraLowMemory: 60]

    /// The 1-based positions each annotation filter finds.
    private static let expectedFilterHits: [VCFImportProfile: [String: [Int]]] = [
        .fast: ["CSQ_IMPACT = HIGH": [300], "ANN_Consequence LIKE missense": [], "biological high impact": [300]],
        .lowMemory: ["CSQ_IMPACT = HIGH": [300], "ANN_Consequence LIKE missense": [], "biological high impact": [300]],
        .ultraLowMemory: [
            "CSQ_IMPACT = HIGH": [300], "ANN_Consequence LIKE missense": [100], "biological high impact": [300],
        ],
    ]

    /// The values the ANN_IMPACT column filter offers.
    private static let expectedImpactPicker: [VCFImportProfile: [String]] = [
        .fast: [], .lowMemory: [], .ultraLowMemory: ["LOW", "MODERATE,MODIFIER"],
    ]

    /// For the CSQ header `IMPACT|Allele|Consequence`, the keys, the stored `CSQ_IMPACT` and the `CSQ_IMPACT` that
    /// `infoValues` returns. The materializer names the parts from the fixed template.
    private static let expectedCustomOrder: [VCFImportProfile: (keys: [String], stored: String?, read: String?)] = [
        .fast: (["CSQ_Allele", "CSQ_Consequence", "CSQ_IMPACT", "DP"], "HIGH", "HIGH"),
        .ultraLowMemory: (["CSQ", "CSQ_Allele", "CSQ_Consequence", "CSQ_IMPACT", "DP"], "stop_gained", "stop_gained"),
    ]

    // MARK: - Pins

    func testPinnedVariantINFOKeysPerProfile() throws {
        for profile in StructuredINFOFixture.profiles {
            let dbURL = try StructuredINFOFixture.importDatabase(
                StructuredINFOFixture.threeRecordVCF, profile: profile, in: directory, name: "three")
            let expected = try XCTUnwrap(Self.expectedKeys[profile]).mapValues { $0.sorted() }
            XCTAssertEqual(try StructuredINFOFixture.keysByPosition(dbURL), expected, profile.rawValue)
            let rowCount = try XCTUnwrap(Self.expectedRowCounts[profile])
            XCTAssertEqual(
                try StructuredINFOFixture.rows(dbURL, "SELECT COUNT(*) FROM variant_info"), [["\(rowCount)"]],
                profile.rawValue)
        }
    }

    func testPinnedINFOFilterResultsPerProfile() throws {
        for profile in StructuredINFOFixture.profiles {
            let dbURL = try StructuredINFOFixture.importDatabase(
                StructuredINFOFixture.threeRecordVCF, profile: profile, in: directory, name: "filters")
            let database = try VariantDatabase(url: dbURL)
            func hits(_ filter: VariantDatabase.InfoFilter) -> [Int] {
                database.queryForTable(infoFilters: [filter]).map { $0.position + 1 }.sorted()
            }
            let biologicalSQL = VariantDatabase.biologicalHighImpactTokenSQL(
                impactKeys: VariantDatabase.impactInfoKeys, consequenceKeys: VariantDatabase.impactConsequenceInfoKeys)
            let found: [String: [Int]] = [
                "CSQ_IMPACT = HIGH": hits(.init(key: "CSQ_IMPACT", op: .eq, value: "HIGH")),
                "ANN_Consequence LIKE missense": hits(.init(key: "ANN_Consequence", op: .like, value: "missense")),
                "biological high impact": try StructuredINFOFixture.positions(dbURL, selectingIDs: biologicalSQL),
            ]
            XCTAssertEqual(found, Self.expectedFilterHits[profile], profile.rawValue)
            XCTAssertEqual(
                database.distinctInfoValues(forKey: "ANN_IMPACT"), Self.expectedImpactPicker[profile], profile.rawValue)
        }
    }

    func testPinnedCustomOrderCSQImpactPerProfile() throws {
        for profile in [VCFImportProfile.fast, .ultraLowMemory] {
            let dbURL = try StructuredINFOFixture.importDatabase(
                StructuredINFOFixture.customOrderCSQVCF, profile: profile, in: directory, name: "custom")
            let expected = try XCTUnwrap(Self.expectedCustomOrder[profile])
            XCTAssertEqual(try StructuredINFOFixture.keysByPosition(dbURL), [300: expected.keys], profile.rawValue)
            XCTAssertEqual(
                try StructuredINFOFixture.storedValue(dbURL, position: 300, key: "CSQ_IMPACT"), expected.stored,
                profile.rawValue)
            let database = try VariantDatabase(url: dbURL)
            let variantID = try XCTUnwrap(database.queryForTable().first?.id)
            XCTAssertEqual(database.infoValues(variantId: variantID)["CSQ_IMPACT"], expected.read, profile.rawValue)
        }
    }
}
