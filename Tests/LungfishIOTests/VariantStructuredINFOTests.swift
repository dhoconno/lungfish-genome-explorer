// VariantStructuredINFOTests.swift - Every import profile writes the same ANN and CSQ rows through one parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishIO

/// The tests of the plan row VCF-INFO-EXPAND (lane 13.37). The inline import of `fast` and `low-memory` and the
/// materializer of `ultra-low-memory` write their `variant_info` rows through `VariantDatabase.forEachINFORow`.
final class VariantStructuredINFOTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = try TestTempDirectory.make(prefix: "structured-info")
    }

    override func tearDownWithError() throws {
        if let directory { TestTempDirectory.cleanup(directory) }
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

    func testMultiAllelicRecordStoresTheSameRowsAtEveryProfile() throws {
        var keysByProfile: [VCFImportProfile: [Int: [String]]] = [:]
        for profile in StructuredINFOFixture.profiles {
            let dbURL = try StructuredINFOFixture.importDatabase(
                StructuredINFOFixture.multiAllelicVCF, profile: profile, in: directory, name: "multi")
            keysByProfile[profile] = try StructuredINFOFixture.keysByPosition(dbURL)
            let expected = [
                ("AF", "0.25,0.5"), ("ANN_Allele", "T,G"), ("ANN_IMPACT", "MODERATE,HIGH"), ("ANN_entries", "2"),
            ]
            for (key, value) in expected {
                XCTAssertEqual(
                    try StructuredINFOFixture.storedValue(dbURL, position: 100, key: key), value, "\(profile) \(key)")
            }
        }
        let fast = try XCTUnwrap(keysByProfile[.fast])
        XCTAssertEqual(fast.keys.sorted(), [100])
        XCTAssertEqual(keysByProfile[.lowMemory], fast, "low-memory against fast")
        XCTAssertEqual(keysByProfile[.ultraLowMemory], fast, "ultra-low-memory against fast")
    }

    func testOlderFastDatabaseKeepsItsRawANNAndSplitsItOnRead() throws {
        let dbURL = try StructuredINFOFixture.importDatabase(
            StructuredINFOFixture.threeRecordVCF, profile: .fast, in: directory, name: "older")
        // The shape of a database built before the lane: the raw ANN row only, and no stored part names.
        try StructuredINFOFixture.execute(dbURL, "DELETE FROM variant_info WHERE key LIKE 'ANN\\_%' ESCAPE '\\'")
        try StructuredINFOFixture.execute(dbURL, "DELETE FROM db_metadata WHERE key = 'structured_info_formats'")
        let database = try VariantDatabase(url: dbURL)
        let id = try XCTUnwrap(database.queryForTable().first(where: { $0.position + 1 == 100 })?.id)
        let info = database.infoValues(variantId: id)
        XCTAssertEqual(info["ANN_IMPACT"], "MODERATE,MODIFIER")
        XCTAssertEqual(info["ANN_entries"], "2")
        XCTAssertEqual(info["ANN"]?.hasPrefix("T|missense_variant|MODERATE|"), true)
        // The Known limit for a database imported before this release: the filters and the value lists read stored rows.
        XCTAssertTrue(
            database.queryForTable(infoFilters: [.init(key: "ANN_Consequence", op: .like, value: "missense")]).isEmpty)
        XCTAssertTrue(database.distinctInfoValues(forKey: "ANN_IMPACT").isEmpty)
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

    func testBiologicalHighImpactTokenFindsAHighEntryAmongOthersAtEveryProfile() throws {
        // `custom_term` is in no consequence clause of the SQL, so only the impact clause can keep a variant. POS 100
        // lists a HIGH entry beside a MODIFIER one and POS 200 lists a lone MODERATE.
        let headers = StructuredINFOFixture.threeRecordVCF.split(separator: "\n")
            .filter { $0.hasPrefix("#") }.map(String.init)
        let records = [
            "chr1\t100\t.\tC\tT\t50\tPASS\tDP=40;ANN=T|custom_term|HIGH|geneA,T|upstream_gene_variant|MODIFIER|geneB\tGT\t0/1",
            "chr1\t200\t.\tA\tG\t50\tPASS\tDP=35;ANN=G|custom_term|MODERATE|geneA\tGT\t0/1",
        ]
        let vcf = (headers + records).joined(separator: "\n") + "\n"
        let biologicalSQL = VariantDatabase.biologicalHighImpactTokenSQL(
            impactKeys: VariantDatabase.impactInfoKeys, consequenceKeys: VariantDatabase.impactConsequenceInfoKeys)
        for profile in StructuredINFOFixture.profiles {
            let dbURL = try StructuredINFOFixture.importDatabase(vcf, profile: profile, in: directory, name: "token")
            XCTAssertEqual(
                try StructuredINFOFixture.positions(dbURL, selectingIDs: biologicalSQL), [100], profile.rawValue)
        }
    }

    func testHighImpactFindsMixedImpactVariantsOfBothAnnotationsAtEveryProfile() throws {
        for profile in StructuredINFOFixture.profiles {
            let dbURL = try StructuredINFOFixture.importDatabase(
                StructuredINFOFixture.mixedImpactVCF, profile: profile, in: directory, name: "mixed")
            func hits(_ database: VariantDatabase, _ keys: [String], value: String = "HIGH") -> [Int] {
                let filter = VariantDatabase.InfoFilter(
                    key: keys[0], op: .eq, value: value, alsoKeys: Array(keys.dropFirst()))
                return database.queryForTable(infoFilters: [filter]).map { $0.position + 1 }.sorted()
            }
            // The token table the import itself built, when this profile builds one.
            do {
                let imported = try VariantDatabase(url: dbURL)
                imported.loadTokenCacheState()
                XCTAssertEqual(hits(imported, ["ANN_IMPACT", "CSQ_IMPACT"]), [100, 200], "imported \(profile)")
                XCTAssertEqual(hits(imported, ["ANN_IMPACT"]), [100], "imported ANN \(profile)")
            }
            // Cache cold. The EXISTS path reads the keys the filter names and finds a HIGH among other impacts.
            try StructuredINFOFixture.execute(dbURL, "DROP TABLE IF EXISTS _high_impact")
            // Read-write, since warming the cache creates the table.
            let database = try VariantDatabase(url: dbURL, readWrite: true)
            XCTAssertEqual(hits(database, ["ANN_IMPACT", "CSQ_IMPACT"]), [100, 200], "cold union \(profile)")
            let coldANN = hits(database, ["ANN_IMPACT"])
            let coldCSQ = hits(database, ["CSQ_IMPACT"])
            XCTAssertEqual(coldANN, [100], "cold ANN \(profile)")
            XCTAssertEqual(coldCSQ, [200], "cold CSQ \(profile)")
            XCTAssertEqual(hits(database, ["DP"], value: "4"), [], "DP stays an exact match \(profile)")
            // Cache warm. The table covers every impact key with the same list-member match, so it serves only a
            // filter on all of them, and a lone key reads `variant_info` and returns the rows it returned cold.
            XCTAssertTrue(database.warmHighImpactCache(), profile.rawValue)
            XCTAssertEqual(hits(database, ["ANN_IMPACT", "CSQ_IMPACT"]), [100, 200], "warm union \(profile)")
            XCTAssertEqual(hits(database, ["ANN_IMPACT"]), [100], "warm ANN \(profile)")
            XCTAssertEqual(hits(database, ["CSQ_IMPACT"]), [200], "warm CSQ \(profile)")
            XCTAssertEqual(hits(database, ["ANN_IMPACT"]), coldANN, "warm ANN against cold \(profile)")
            XCTAssertEqual(hits(database, ["CSQ_IMPACT"]), coldCSQ, "warm CSQ against cold \(profile)")
            XCTAssertEqual(hits(database, ["csq_impact", "ann_impact"]), [100, 200], "keys compare without case \(profile)")
        }
    }

    func testAHighImpactTableWithoutTheStampIsIgnoredThenRebuilt() throws {
        let dbURL = try StructuredINFOFixture.importDatabase(
            StructuredINFOFixture.mixedImpactVCF, profile: .fast, in: directory, name: "stamp")
        // The shape of a database imported before the list-member match. `_high_impact` is built over the four impact
        // keys with `value = 'HIGH'`, which keeps no variant of this fixture, and the stamp row does not exist.
        let keyList = VariantDatabase.impactInfoKeys.map { "'\($0)'" }.joined(separator: ",")
        try StructuredINFOFixture.execute(dbURL, "DROP TABLE IF EXISTS _high_impact")
        try StructuredINFOFixture.execute(
            dbURL,
            "CREATE TABLE _high_impact AS SELECT DISTINCT variant_id FROM variant_info "
                + "WHERE key IN (\(keyList)) AND value = 'HIGH'")
        try StructuredINFOFixture.execute(dbURL, "DELETE FROM db_metadata WHERE key = 'high_impact_match'")
        let stampQuery = "SELECT value FROM db_metadata WHERE key = 'high_impact_match'"
        let tablePositions = "SELECT variant_id FROM _high_impact"
        func hits(_ database: VariantDatabase, _ keys: [String]) -> [Int] {
            let filter = VariantDatabase.InfoFilter(
                key: keys[0], op: .eq, value: "HIGH", alsoKeys: Array(keys.dropFirst()))
            return database.queryForTable(infoFilters: [filter]).map { $0.position + 1 }.sorted()
        }
        func assertEveryFilter(_ database: VariantDatabase, _ label: String) {
            XCTAssertEqual(hits(database, ["ANN_IMPACT"]), [100], "ANN \(label)")
            XCTAssertEqual(hits(database, ["CSQ_IMPACT"]), [200], "CSQ \(label)")
            XCTAssertEqual(hits(database, ["ANN_IMPACT", "CSQ_IMPACT"]), [100, 200], "union \(label)")
        }

        // A read-only handle ignores the table, answers from `variant_info` and writes nothing.
        let readOnly = try VariantDatabase(url: dbURL)
        readOnly.loadTokenCacheState()
        XCTAssertFalse(readOnly.highImpactCacheReady, "read-only ready")
        XCTAssertNil(readOnly.tokenCacheState["highImpactBiological"], "read-only token")
        assertEveryFilter(readOnly, "read-only")
        XCTAssertFalse(readOnly.warmHighImpactCache(), "read-only warm")
        assertEveryFilter(readOnly, "read-only after warm")
        XCTAssertEqual(try StructuredINFOFixture.rows(dbURL, stampQuery), [], "read-only wrote the stamp")
        XCTAssertEqual(try StructuredINFOFixture.positions(dbURL, selectingIDs: tablePositions), [], "read-only table")

        // A writable handle drops the table, rebuilds it with the member match and writes the stamp.
        let writable = try VariantDatabase(url: dbURL, readWrite: true)
        XCTAssertTrue(writable.warmHighImpactCache(), "read-write warm")
        assertEveryFilter(writable, "read-write")
        XCTAssertEqual(try StructuredINFOFixture.rows(dbURL, stampQuery), [["member"]], "read-write stamp")
        XCTAssertEqual(try StructuredINFOFixture.positions(dbURL, selectingIDs: tablePositions), [100, 200], "table")
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
