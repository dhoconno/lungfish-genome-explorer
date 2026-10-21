// VariantStructuredINFOTests.swift - Every import profile writes the same ANN and CSQ rows through one parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// The tests of the plan row VCF-INFO-EXPAND (lane 13.37). The inline import of `fast` and `low-memory` and the
/// materializer of `ultra-low-memory` write their `variant_info` rows through `VariantDatabase.forEachINFORow`.
final class VariantStructuredINFOTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StructuredINFO-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testStructuredINFOKeysMatchAcrossImportProfiles() throws {
        var keysByProfile: [VCFImportProfile: [Int: [String]]] = [:]
        for profile in StructuredINFOFixture.profiles {
            let dbURL = try StructuredINFOFixture.importDatabase(
                StructuredINFOFixture.threeRecordVCF, profile: profile, in: directory, name: "three")
            keysByProfile[profile] = try StructuredINFOFixture.keysByPosition(dbURL)
            func stored(_ position: Int, _ key: String) throws -> String? {
                try StructuredINFOFixture.storedValue(dbURL, position: position, key: key)
            }
            XCTAssertEqual(try stored(100, "ANN_IMPACT"), "MODERATE,MODIFIER", profile.rawValue)
            XCTAssertEqual(try stored(100, "ANN_entries"), "2", profile.rawValue)
            XCTAssertEqual(try stored(300, "CSQ")?.hasPrefix("A|stop_gained|HIGH|"), true, profile.rawValue)
            XCTAssertEqual(try stored(300, "CSQ_IMPACT"), "HIGH", profile.rawValue)
        }
        let fast = try XCTUnwrap(keysByProfile[.fast])
        XCTAssertEqual(fast.keys.sorted(), [100, 200, 300])
        XCTAssertEqual(keysByProfile[.lowMemory], fast, "low-memory against fast")
        XCTAssertEqual(keysByProfile[.ultraLowMemory], fast, "ultra-low-memory against fast")
    }

    func testCSQPartsFollowTheHeaderFormatOrder() throws {
        for profile in [VCFImportProfile.ultraLowMemory, .fast] {
            let dbURL = try StructuredINFOFixture.importDatabase(
                StructuredINFOFixture.customOrderCSQVCF, profile: profile, in: directory, name: "custom")
            for (key, value) in [("CSQ_IMPACT", "HIGH"), ("CSQ_Allele", "A"), ("CSQ_Consequence", "stop_gained")] {
                XCTAssertEqual(
                    try StructuredINFOFixture.storedValue(dbURL, position: 300, key: key), value, "\(profile) \(key)")
            }
            // The dictionary readers return the stored parts and do not rename them by the VEP template.
            let database = try VariantDatabase(url: dbURL)
            let id = try XCTUnwrap(database.queryForTable().first?.id)
            XCTAssertEqual(database.infoValues(variantId: id)["CSQ_IMPACT"], "HIGH", profile.rawValue)
            XCTAssertEqual(database.batchInfoValues(variantIds: [id])[id]?["CSQ_IMPACT"], "HIGH", profile.rawValue)
            XCTAssertEqual(
                try database.batchInfoValuesForExport(variantIds: [id])[id]?["CSQ_IMPACT"], "HIGH", profile.rawValue)
        }
    }

    func testANNPartsFollowTheHeaderFormatOrderWhenTheHeaderListsOne() throws {
        var keysByProfile: [VCFImportProfile: [Int: [String]]] = [:]
        for profile in StructuredINFOFixture.profiles {
            let dbURL = try StructuredINFOFixture.importDatabase(
                StructuredINFOFixture.vepANNVCF, profile: profile, in: directory, name: "vepann")
            keysByProfile[profile] = try StructuredINFOFixture.keysByPosition(dbURL)
            for (key, value) in [("ANN_IMPACT", "HIGH"), ("ANN_SYMBOL", "geneC"), ("ANN_Consequence", "stop_gained")] {
                XCTAssertEqual(
                    try StructuredINFOFixture.storedValue(dbURL, position: 300, key: key), value, "\(profile) \(key)")
            }
            // A VEP list holds no SnpEff `Annotation` part, so the SnpEff names must not leak in.
            XCTAssertNil(
                try StructuredINFOFixture.storedValue(dbURL, position: 300, key: "ANN_Annotation"), profile.rawValue)
        }
        let fast = try XCTUnwrap(keysByProfile[.fast])
        XCTAssertEqual(keysByProfile[.lowMemory], fast, "low-memory against fast")
        XCTAssertEqual(keysByProfile[.ultraLowMemory], fast, "ultra-low-memory against fast")
    }

    func testHighImpactAndANNConsequenceFiltersFindTheirVariantsAtEveryProfile() throws {
        for profile in StructuredINFOFixture.profiles {
            let dbURL = try StructuredINFOFixture.importDatabase(
                StructuredINFOFixture.threeRecordVCF, profile: profile, in: directory, name: "filters")
            let database = try VariantDatabase(url: dbURL)
            func hits(_ filter: VariantDatabase.InfoFilter) -> [Int] {
                database.queryForTable(infoFilters: [filter]).map { $0.position + 1 }.sorted()
            }
            // The High Impact token filters one impact key the database lists for HIGH.
            XCTAssertEqual(hits(.init(key: "CSQ_IMPACT", op: .eq, value: "HIGH")), [300], profile.rawValue)
            XCTAssertEqual(hits(.init(key: "ANN_IMPACT", op: .eq, value: "LOW")), [200], profile.rawValue)
            XCTAssertEqual(hits(.init(key: "ANN_Consequence", op: .like, value: "missense")), [100], profile.rawValue)
            let biologicalSQL = VariantDatabase.biologicalHighImpactTokenSQL(
                impactKeys: VariantDatabase.impactInfoKeys, consequenceKeys: VariantDatabase.impactConsequenceInfoKeys)
            XCTAssertEqual(
                try StructuredINFOFixture.positions(dbURL, selectingIDs: biologicalSQL), [300], profile.rawValue)
            XCTAssertEqual(
                database.distinctInfoValues(forKey: "ANN_IMPACT"), ["LOW", "MODERATE,MODIFIER"], profile.rawValue)
        }
    }

    func testHeaderPartNamesRoundTripThroughMetadata() throws {
        var names = StructuredINFOFieldNames()
        let lof = "Predicted loss of function effects for this variant. Format: 'Gene_Name | Gene_ID | "
            + "Number_of_transcripts_in_gene | Percent_of_transcripts_affected' "
        XCTAssertEqual(
            names.register(id: "LOF", description: lof),
            ["Gene_Name", "Gene_ID", "Number_of_transcripts_in_gene", "Percent_of_transcripts_affected"])
        XCTAssertEqual(names.register(id: "ANN", description: "Functional annotations: 'Allele | Annotation'"),
                       VariantDatabase.annSubFieldTemplate)
        XCTAssertEqual(names.register(id: "CSQ", description: "Format: IMPACT|Allele"), ["IMPACT", "Allele"])
        XCTAssertNil(names.register(id: "DP", description: "Total Depth"))
        XCTAssertEqual(StructuredINFOFieldNames(metadataValue: names.metadataValue), names)
        XCTAssertNil(StructuredINFOFieldNames().metadataValue)
        XCTAssertEqual(StructuredINFOFieldNames(metadataValue: "not json"), StructuredINFOFieldNames())

        // bcftools csq writes BCSQ with a Format list, so any key with one splits, raw row first.
        names.register(id: "BCSQ", description: "Haplotype-aware consequence annotation. Format: Consequence|gene|strand")
        var rows: [String] = []
        let bcsq = "BCSQ=missense|geneA|+,synonymous|geneA|+"
        VariantDatabase.forEachINFORow(field: bcsq[...], names: names) { rows.append("\($0)=\($1)") }
        XCTAssertEqual(rows, [
            "BCSQ=missense|geneA|+,synonymous|geneA|+", "BCSQ_Consequence=missense,synonymous", "BCSQ_gene=geneA",
            "BCSQ_strand=+", "BCSQ_entries=2",
        ])
        rows = []
        VariantDatabase.forEachINFORow(field: "SOMATIC", names: names) { rows.append("\($0)=\($1)") }
        XCTAssertEqual(rows, ["SOMATIC=true"])
    }
}
