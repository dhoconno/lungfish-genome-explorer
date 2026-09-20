// VariantFormatOverlayTests.swift - iVar FORMAT presentation regressions
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import SQLite3
@testable import LungfishApp
@testable import LungfishIO

final class VariantFormatOverlayTests: XCTestCase {
    func testLegacyNullRawFieldsRecoverFromRetainedVCFWithoutMutatingSources() async throws {
        let fixture = try makeFixture(rows: [
            (241, "C", "T", "2140", "1"),
            (509, "GGUCAUGUUAUGGUU", "G", "30", "0.0666667"),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try clearRawFields(at: fixture.databaseURL)
        let vcfBefore = try Data(contentsOf: fixture.vcfURL)
        let databaseBefore = try Data(contentsOf: fixture.databaseURL)
        let database = try VariantDatabase(url: fixture.databaseURL)

        let snapshot = await VariantFormatOverlayLoader.load(sources: [
            VariantFormatOverlaySource(
                trackID: "ivar", database: database, vcfURL: fixture.vcfURL, isIVar: true,
                aliasesByExactToken: [:], aliasesByCanonicalToken: [:]
            )
        ])
        let record = try XCTUnwrap(database.query(chromosome: "NC_045512", start: 240, end: 241).first)
        let projected = snapshot.projectedInfo(trackID: "ivar", record: record, existing: ["TYPE": "SNP"])

        XCTAssertEqual(projected["AF"], "1")
        XCTAssertEqual(projected["DP"], "2140")
        XCTAssertEqual(snapshot.sampleFields(trackID: "ivar", record: record, sample: "sample-a")["ALT_QUAL"], "66")
        XCTAssertEqual(try Data(contentsOf: fixture.vcfURL), vcfBefore)
        XCTAssertEqual(try Data(contentsOf: fixture.databaseURL), databaseBefore)
    }

    func testProjectedFilterFindsMatchBeyondRequestedDisplayLimit() async throws {
        let fixture = try makeFixture(rows: [
            (100, "A", "G", "30", "0.1"),
            (200, "C", "T", "40", "0.2"),
            (300, "G", "A", "2140", "0.9"),
        ])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try VariantDatabase(url: fixture.databaseURL)
        let snapshot = await VariantFormatOverlayLoader.load(sources: [
            VariantFormatOverlaySource(
                trackID: "ivar", database: database, vcfURL: fixture.vcfURL, isIVar: true,
                aliasesByExactToken: [:], aliasesByCanonicalToken: [:]
            )
        ])
        let context = AnnotationVariantQueryContext(
            databases: [(trackId: "ivar", db: database)],
            trackNames: ["ivar": "iVar"],
            trackChromosomes: ["ivar": ["NC_045512"]],
            annotationDatabases: [], infoKeys: ["AF"], variantAliasMap: [:],
            formatOverlay: snapshot
        )

        let results = context.queryVariantsOnly(
            infoFilters: [.init(key: "AF", op: .gt, value: "0.8")], limit: 1
        )

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.start, 299)
        XCTAssertEqual(results.first?.infoDict?["AF"], "0.9")
    }

    func testMixedInfoAndProjectedFrequencyShareFilterAndCountSemantics() async throws {
        let fixture = try makeFixture(rows: [(100, "A", "G", "30", "0.9")])
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let infoVCF = fixture.directory.appendingPathComponent("lofreq.vcf")
        let infoDBURL = fixture.directory.appendingPathComponent("lofreq.db")
        try """
        ##fileformat=VCFv4.2
        ##INFO=<ID=AF,Number=A,Type=Float,Description="Allele frequency">
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO
        NC_045512\t200\t.\tC\tT\t.\tPASS\tAF=0.05
        """.write(to: infoVCF, atomically: true, encoding: .utf8)
        try VariantDatabase.createFromVCF(vcfURL: infoVCF, outputURL: infoDBURL)
        let ivarDB = try VariantDatabase(url: fixture.databaseURL)
        let infoDB = try VariantDatabase(url: infoDBURL)
        let snapshot = await VariantFormatOverlayLoader.load(sources: [
            .init(trackID: "ivar", database: ivarDB, vcfURL: fixture.vcfURL, isIVar: true,
                  aliasesByExactToken: [:], aliasesByCanonicalToken: [:])
        ])
        let context = AnnotationVariantQueryContext(
            databases: [("info", infoDB), ("ivar", ivarDB)],
            trackNames: ["info": "LoFreq", "ivar": "iVar"],
            trackChromosomes: ["info": ["NC_045512"], "ivar": ["NC_045512"]],
            annotationDatabases: [], infoKeys: ["AF"], variantAliasMap: [:], formatOverlay: snapshot
        )
        let filter = VariantDatabase.InfoFilter(key: "AF", op: .gt, value: "0.01")

        XCTAssertEqual(context.queryVariantsOnly(infoFilters: [filter], limit: 10).count, 2)
        XCTAssertEqual(context.queryVariantCount(infoFilters: [filter]), 2)
    }

    @MainActor
    func testStaleLoaderCompletionCannotPublish() {
        let index = AnnotationSearchIndex()
        let firstGeneration = index.variantDatabaseGeneration
        XCTAssertTrue(index.publishVariantFormatOverlay(
            VariantFormatOverlaySnapshot(singleSampleByTrack: ["old": "sample"]),
            expectedGeneration: firstGeneration
        ))
        XCTAssertFalse(index.publishVariantFormatOverlay(
            VariantFormatOverlaySnapshot(singleSampleByTrack: ["stale": "sample"]),
            expectedGeneration: firstGeneration
        ))
        XCTAssertNil(index.variantFormatOverlaySnapshot.singleSampleByTrack["stale"])
    }

    func testSingleSampleIvarFieldsProjectWithoutOverwritingInfo() {
        let record = makeRecord()
        let snapshot = VariantFormatOverlaySnapshot(
            fields: [
                VariantFormatKey(trackID: "ivar", chromosome: "NC_045512", position: 240,
                                 ref: "C", alt: "T", sample: "sample-a"): [
                    "GT": "1", "DP": "2140", "ALT_DP": "2140", "ALT_QUAL": "66", "ALT_FREQ": "1"
                ]
            ],
            singleSampleByTrack: ["ivar": "sample-a"],
            projectedKeysByTrack: ["ivar": ["AF", "DP", "ALT_DP", "ALT_QUAL", "ALT_FREQ"]]
        )

        let projected = snapshot.projectedInfo(
            trackID: "ivar", record: record, existing: ["AF": "0.25", "TYPE": "SNP"]
        )

        XCTAssertEqual(projected["AF"], "0.25", "genuine INFO/AF must win")
        XCTAssertEqual(projected["DP"], "2140")
        XCTAssertEqual(projected["ALT_FREQ"], "1")
        XCTAssertEqual(projected["ALT_QUAL"], "66")
        XCTAssertNil(projected["QUAL"], "caller ALT_QUAL must not manufacture variant QUAL")
    }

    func testZeroFrequencyProjectsButInvalidFrequencyDoesNotBecomeAF() {
        let record = makeRecord()
        let key = VariantFormatKey(trackID: "ivar", chromosome: "NC_045512", position: 240,
                                   ref: "C", alt: "T", sample: "sample-a")
        var snapshot = VariantFormatOverlaySnapshot(
            fields: [key: ["ALT_FREQ": "0", "DP": "30"]],
            singleSampleByTrack: ["ivar": "sample-a"],
            projectedKeysByTrack: ["ivar": ["AF", "DP", "ALT_FREQ"]]
        )
        XCTAssertEqual(snapshot.projectedInfo(trackID: "ivar", record: record, existing: [:])["AF"], "0")

        snapshot.fields[key] = ["ALT_FREQ": "NaN", "DP": "30"]
        let invalid = snapshot.projectedInfo(trackID: "ivar", record: record, existing: [:])
        XCTAssertNil(invalid["AF"])
        XCTAssertEqual(invalid["ALT_FREQ"], "NaN", "raw caller value remains inspectable")
    }

    func testMultisampleTrackNeverProjectsUnexplainedRowScalar() {
        let record = makeRecord()
        let sampleA = VariantFormatKey(trackID: "ivar", chromosome: record.chromosome, position: record.position,
                                       ref: record.ref, alt: record.alt, sample: "a")
        let sampleB = VariantFormatKey(trackID: "ivar", chromosome: record.chromosome, position: record.position,
                                       ref: record.ref, alt: record.alt, sample: "b")
        let snapshot = VariantFormatOverlaySnapshot(
            fields: [sampleA: ["ALT_FREQ": "0.1"], sampleB: ["ALT_FREQ": "0.9"]],
            singleSampleByTrack: [:],
            projectedKeysByTrack: [:]
        )

        XCTAssertEqual(snapshot.projectedInfo(trackID: "ivar", record: record, existing: ["TYPE": "SNP"]),
                       ["TYPE": "SNP"])
        XCTAssertEqual(snapshot.sampleFields(trackID: "ivar", record: record, sample: "a")["ALT_FREQ"], "0.1")
        XCTAssertEqual(snapshot.sampleFields(trackID: "ivar", record: record, sample: "b")["ALT_FREQ"], "0.9")
    }

    func testTrackIdentityPreventsCrossContaminationAtSameCoordinate() {
        let record = makeRecord()
        let fields: [VariantFormatKey: [String: String]] = [
            .init(trackID: "track-a", chromosome: record.chromosome, position: record.position,
                  ref: record.ref, alt: record.alt, sample: "s"): ["ALT_FREQ": "0.1"],
            .init(trackID: "track-b", chromosome: record.chromosome, position: record.position,
                  ref: record.ref, alt: record.alt, sample: "s"): ["ALT_FREQ": "0.9"],
        ]
        let snapshot = VariantFormatOverlaySnapshot(
            fields: fields,
            singleSampleByTrack: ["track-a": "s", "track-b": "s"],
            projectedKeysByTrack: ["track-a": ["AF"], "track-b": ["AF"]]
        )

        XCTAssertEqual(snapshot.projectedInfo(trackID: "track-a", record: record, existing: [:])["AF"], "0.1")
        XCTAssertEqual(snapshot.projectedInfo(trackID: "track-b", record: record, existing: [:])["AF"], "0.9")
    }

    func testInfoFilterUsesNumericAndMissingSemantics() {
        XCTAssertTrue(VariantFormatOverlaySnapshot.matches(
            ["DP": "2140"], filter: .init(key: "DP", op: .gt, value: "100")
        ))
        XCTAssertFalse(VariantFormatOverlaySnapshot.matches(
            ["DP": "30"], filter: .init(key: "DP", op: .gt, value: "100")
        ))
        XCTAssertTrue(VariantFormatOverlaySnapshot.matches(
            ["AF": "0.10"], filter: .init(key: "AF", op: .eq, value: "0.10")
        ))
        XCTAssertFalse(VariantFormatOverlaySnapshot.matches(
            [:], filter: .init(key: "AF", op: .neq, value: "0.1")
        ), "missing fields must not silently satisfy inequality")
    }

    private func makeRecord() -> VariantDatabaseRecord {
        VariantDatabaseRecord(
            id: 1, chromosome: "NC_045512", position: 240, end: 241, variantID: ".",
            ref: "C", alt: "T", variantType: "SNP", quality: nil, filter: "PASS",
            info: "TYPE=SNP", sampleCount: 1
        )
    }

    private func makeFixture(
        rows: [(position: Int, ref: String, alt: String, depth: String, frequency: String)]
    ) throws -> (directory: URL, vcfURL: URL, databaseURL: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VariantFormatOverlayTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let vcfURL = directory.appendingPathComponent("ivar.vcf")
        let databaseURL = directory.appendingPathComponent("ivar.db")
        let body = rows.map { row in
            "NC_045512\t\(row.position)\t.\t\(row.ref)\t\(row.alt)\t.\tPASS\tTYPE=SNP\tGT:DP:REF_DP:REF_RV:REF_QUAL:ALT_DP:ALT_RV:ALT_QUAL:ALT_FREQ\t1:\(row.depth):0:0:0:\(row.depth):1:66:\(row.frequency)"
        }.joined(separator: "\n")
        let vcf = """
        ##fileformat=VCFv4.2
        #CHROM\tPOS\tID\tREF\tALT\tQUAL\tFILTER\tINFO\tFORMAT\tsample-a
        \(body)
        """
        try vcf.write(to: vcfURL, atomically: true, encoding: .utf8)
        try VariantDatabase.createFromVCF(vcfURL: vcfURL, outputURL: databaseURL)
        return (directory, vcfURL, databaseURL)
    }

    private func clearRawFields(at url: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(url.path, &connection) == SQLITE_OK, let connection else {
            throw NSError(domain: "VariantFormatOverlayTests", code: 1)
        }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, "UPDATE genotypes SET raw_fields = NULL", nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "VariantFormatOverlayTests", code: 2)
        }
    }
}
