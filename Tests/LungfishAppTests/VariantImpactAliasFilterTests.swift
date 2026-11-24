// VariantImpactAliasFilterTests.swift - A typed impact filter reads every impact key the file holds
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Row VARIANT-IMPACT-KEYS (S1). A file annotated by VEP and by SnpEff holds CSQ_IMPACT on some variants and
// ANN_IMPACT on others. A typed `impact=HIGH` named the first alias (CSQ_IMPACT) and dropped the rest, so it counted
// fewer variants than the High Impact token. The High Impact table was built over exact-case key names while the
// filters compare keys without case, so a warm table held fewer variants than the cold filter counts.
//
// The counts are those of bcftools on the same text (`bcftools view -H -i ... | wc -l`), given with each constant.

import XCTest
import SQLite3
@testable import LungfishIO
@testable import LungfishApp

@MainActor
final class VariantImpactAliasFilterTests: XCTestCase {

    private nonisolated(unsafe) var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("variant-impact-alias-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        super.tearDown()
    }

    // MARK: - Fixtures and the counts of bcftools

    /// One variant with `CSQ_IMPACT=HIGH` and one with `ANN_IMPACT=HIGH`.
    private static let twoKeysVCF = """
        ##fileformat=VCFv4.2
        ##contig=<ID=chr1,length=1000>
        ##INFO=<ID=CSQ_IMPACT,Number=1,Type=String,Description="Impact">
        ##INFO=<ID=ANN_IMPACT,Number=1,Type=String,Description="Impact">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t150\trs1\tA\tG\t30\tPASS\tCSQ_IMPACT=HIGH
        chr1\t250\trs2\tC\tT\t40\tPASS\tANN_IMPACT=HIGH

        """

    /// One variant with `Impact=HIGH` and one with `Impact=LOW`, the key written in mixed case.
    private static let mixedCaseKeyVCF = """
        ##fileformat=VCFv4.2
        ##contig=<ID=chr1,length=1000>
        ##INFO=<ID=Impact,Number=1,Type=String,Description="Impact">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t150\trs1\tA\tG\t30\tPASS\tImpact=HIGH
        chr1\t250\trs2\tC\tT\t40\tPASS\tImpact=LOW

        """

    /// `bcftools view -H -i 'INFO/CSQ_IMPACT="HIGH" || INFO/ANN_IMPACT="HIGH"' two-keys.vcf | wc -l` prints 2.
    private static let bcftoolsEitherKey = 2

    /// `bcftools view -H -i 'INFO/ANN_IMPACT="HIGH"' two-keys.vcf | wc -l` prints 1, and so does the one on CSQ_IMPACT.
    private static let bcftoolsOneKey = 1

    /// `bcftools view -H -i 'INFO/Impact="HIGH"' mixed-case-key.vcf | wc -l` prints 1.
    private static let bcftoolsMixedCaseKey = 1

    /// rs1 `Impact=HIGH` (key in mixed case), rs2 `CSQ_IMPACT=HIGH`, rs3 `CSQ_IMPACT=LOW`.
    private static let mixedAndExactKeysVCF = """
        ##fileformat=VCFv4.2
        ##contig=<ID=chr1,length=1000>
        ##INFO=<ID=Impact,Number=1,Type=String,Description="Impact">
        ##INFO=<ID=CSQ_IMPACT,Number=1,Type=String,Description="Impact">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        chr1\t150\trs1\tA\tG\t30\tPASS\tImpact=HIGH
        chr1\t250\trs2\tC\tT\t40\tPASS\tCSQ_IMPACT=HIGH
        chr1\t350\trs3\tG\tA\t40\tPASS\tCSQ_IMPACT=LOW

        """

    /// `bcftools view -H -i 'INFO/CSQ_IMPACT="HIGH"' mixed-and-exact.vcf | wc -l` prints 1, and so does the one on `Impact`.
    private static let bcftoolsOneKeyOfMixedAndExact = 1

    /// `bcftools view -H -i 'INFO/Impact="HIGH" || INFO/CSQ_IMPACT="HIGH"' mixed-and-exact.vcf | wc -l` prints 2.
    private static let bcftoolsEitherKeyOfMixedAndExact = 2

    // MARK: - Tests

    func testATypedImpactFilterCountsTheVariantsOfEveryImpactKeyTheFileHolds() throws {
        let dbURL = try importDatabase(Self.twoKeysVCF, name: "two-keys")
        let database = try VariantDatabase(url: dbURL)
        for text in ["impact=HIGH", "IMPACT=HIGH", "Impact=HIGH"] {
            XCTAssertEqual(typedCount(text, in: database), Self.bcftoolsEitherKey, text)
        }
        // A key typed in full stays that key.
        XCTAssertEqual(typedCount("ANN_IMPACT=HIGH", in: database), Self.bcftoolsOneKey, "ANN_IMPACT=HIGH")
        XCTAssertEqual(typedCount("CSQ_IMPACT=HIGH", in: database), Self.bcftoolsOneKey, "CSQ_IMPACT=HIGH")
    }

    func testTheHighImpactTableServesATypedImpactFilterWithTheCountOfEveryKey() throws {
        let dbURL = try importDatabase(Self.twoKeysVCF, name: "two-keys-warm")
        let database = try VariantDatabase(url: dbURL, readWrite: true)
        XCTAssertTrue(database.warmHighImpactCache())
        XCTAssertTrue(database.highImpactCacheReady)
        XCTAssertEqual(typedCount("impact=HIGH", in: database), Self.bcftoolsEitherKey)
    }

    func testTheWarmHighImpactTableCountsWhatTheColdFilterCountsForAKeyInMixedCase() throws {
        let dbURL = try importDatabase(Self.mixedCaseKeyVCF, name: "mixed-case")
        let cold = try VariantDatabase(url: dbURL)
        XCTAssertEqual(typedCount("impact=HIGH", in: cold), Self.bcftoolsMixedCaseKey, "cold")
        let warm = try VariantDatabase(url: dbURL, readWrite: true)
        XCTAssertTrue(warm.warmHighImpactCache())
        XCTAssertEqual(typedCount("impact=HIGH", in: warm), Self.bcftoolsMixedCaseKey, "warm")
    }

    func testADatabaseStampedByTheEarlierMatchBuildsItsHighImpactTableAgain() throws {
        let dbURL = try importDatabase(Self.mixedCaseKeyVCF, name: "earlier-stamp")
        // The shape of a database an earlier release built: `_high_impact` over the four exact-case keys, which holds
        // nothing of this file, and the stamp of that release.
        try execute(dbURL, "DROP TABLE IF EXISTS _high_impact")
        try execute(
            dbURL,
            "CREATE TABLE _high_impact AS SELECT DISTINCT variant_id FROM variant_info "
                + "WHERE key IN ('IMPACT','impact','ANN_IMPACT','CSQ_IMPACT') "
                + "AND instr(',' || value || ',', ',HIGH,') > 0")
        try execute(dbURL, "INSERT OR REPLACE INTO db_metadata VALUES ('high_impact_match', 'member')")
        let database = try VariantDatabase(url: dbURL, readWrite: true)
        XCTAssertTrue(database.warmHighImpactCache())
        XCTAssertEqual(typedCount("impact=HIGH", in: database), Self.bcftoolsMixedCaseKey)
    }

    /// The tables hold the variants of `Impact` and `CSQ_IMPACT` alike, so a filter on `CSQ_IMPACT` alone is not theirs
    /// to serve. The first two assertions also pin the import-time and `_tok_bio_hi` builds that match keys without case.
    func testAFullKeyFilterIsNotServedByATableThatAlsoHoldsAKeyInMixedCase() throws {
        let database = try VariantDatabase(url: try importDatabase(Self.mixedAndExactKeysVCF, name: "mixed-and-exact"))
        XCTAssertEqual(database.tokenCacheState["highImpact"]?.count, 2, "_high_impact holds rs1 and rs2")
        XCTAssertEqual(database.tokenCacheState["highImpactBiological"]?.count, 2, "_tok_bio_hi holds rs1 and rs2")
        XCTAssertEqual(
            typedCount("CSQ_IMPACT=HIGH", in: database), Self.bcftoolsOneKeyOfMixedAndExact, "full key, bcftools CSQ_IMPACT")
        XCTAssertEqual(
            typedCount("impact=HIGH", in: database), Self.bcftoolsEitherKeyOfMixedAndExact, "logical key, bcftools either key")
    }

    // MARK: - Helpers

    /// The number of variants the filter bar finds for `text` in `database`.
    private func typedCount(_ text: String, in database: VariantDatabase) -> Int {
        let drawer = AnnotationTableDrawerView(frame: .zero)
        drawer.infoColumnKeys = database.infoKeys().map { (key: $0.key, type: $0.type, description: $0.description) }
        return database.queryForTable(infoFilters: drawer.parseVariantFilterText(text).infoFilters).count
    }

    private func importDatabase(_ vcf: String, name: String) throws -> URL {
        let vcfURL = directory.appendingPathComponent("\(name).vcf")
        try vcf.write(to: vcfURL, atomically: true, encoding: .utf8)
        let dbURL = directory.appendingPathComponent("\(name).db")
        _ = try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: dbURL)
        return dbURL
    }

    private func execute(_ dbURL: URL, _ sql: String) throws {
        var handle: OpaquePointer?
        defer { sqlite3_close(handle) }
        guard sqlite3_open_v2(dbURL.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            throw NSError(domain: "VariantImpactAliasFilterTests", code: 1, userInfo: [NSLocalizedDescriptionKey: sql])
        }
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK, sql)
    }
}
