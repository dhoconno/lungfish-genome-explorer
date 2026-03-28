// ProjectUniversalSearchTests.swift - Tests for project-scoped universal search indexing/query
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishIO

final class ProjectUniversalSearchTests: XCTestCase {

    private var projectURL: URL!

    override func setUpWithError() throws {
        projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("UniversalSearchTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let projectURL, FileManager.default.fileExists(atPath: projectURL.path) {
            try? FileManager.default.removeItem(at: projectURL)
        }
    }

    func testQueryParserParsesFieldTokensAndQuotedTerms() {
        let parsed = ProjectUniversalSearchQueryParser.parse(
            #"type:fastq format:vcf sample:"Air Sample 01" role:test_sample date>=2025-01-01 date<=2025-01-31 virus:HKU1 notes:"batch alpha""#
        )

        XCTAssertEqual(parsed.kinds, ["fastq_dataset"])
        XCTAssertEqual(parsed.formats, ["vcf"])
        XCTAssertNotNil(parsed.dateFrom)
        XCTAssertNotNil(parsed.dateTo)
        XCTAssertEqual(Int(parsed.dateFrom?.timeIntervalSince1970 ?? 0), 1_735_689_600)
        XCTAssertEqual(Int(parsed.dateTo?.timeIntervalSince1970 ?? 0), 1_738_281_600)
        XCTAssertTrue(parsed.attributeFilters.contains { $0.key == "sample_name" && $0.value == "air sample 01" })
        XCTAssertTrue(parsed.attributeFilters.contains { $0.key == "sample_role" && $0.value == "test_sample" })
        XCTAssertTrue(parsed.attributeFilters.contains { $0.key == "virus_name" && $0.value == "hku1" })
        XCTAssertTrue(parsed.attributeFilters.contains { $0.key == "notes" && $0.value == "batch alpha" })
        XCTAssertTrue(parsed.textTerms.contains("hku1"))
    }

    func testRebuildIndexesFastqAndSupportsRoleAndDateFilters() throws {
        _ = try makeFASTQBundle(
            name: "AirSampleA",
            metadataRows: [
                ("sample_name", "Air Sample 01"),
                ("sample_role", "test_sample"),
                ("metadata_template", "air_sample"),
                ("collection_date", "2025-01-15"),
                ("notes", "North wing"),
            ]
        )

        let index = try ProjectUniversalSearchIndex(projectURL: projectURL)
        let build = try index.rebuild()
        XCTAssertGreaterThanOrEqual(build.indexedEntities, 1)

        let roleResults = try index.search(
            rawQuery: "type:fastq_dataset role:test_sample sample:air",
            limit: 50
        )
        XCTAssertEqual(roleResults.count, 1)
        XCTAssertEqual(roleResults.first?.kind, "fastq_dataset")
        XCTAssertEqual(roleResults.first?.url.pathExtension, "lungfishfastq")

        let dateResults = try index.search(
            rawQuery: "type:fastq_dataset date>=2025-01-01 date<=2025-01-31 metadata_template:air_sample",
            limit: 50
        )
        XCTAssertEqual(dateResults.count, 1)
        XCTAssertEqual(dateResults.first?.id.hasPrefix("fastq_dataset:"), true)
    }

    func testClassificationVirusQueryFindsKreportTaxa() throws {
        try makeClassificationResultDirectory()

        let index = try ProjectUniversalSearchIndex(projectURL: projectURL)
        _ = try index.rebuild()

        let results = try index.search(
            rawQuery: "type:classification_result virus:hku1",
            limit: 20
        )
        XCTAssertTrue(
            results.contains(where: { $0.kind == "classification_result" }),
            "Expected classification result to match virus:hku1 query"
        )
    }

    func testEsVirituVirusQueryReturnsVirusHitEntity() throws {
        try makeEsVirituResultDirectory()

        let index = try ProjectUniversalSearchIndex(projectURL: projectURL)
        _ = try index.rebuild()

        let results = try index.search(rawQuery: "virus:hku1", limit: 50)
        XCTAssertTrue(
            results.contains(where: { $0.kind == "virus_hit" }),
            "Expected at least one virus_hit for HKU1"
        )
        XCTAssertTrue(
            results.contains(where: { $0.kind == "esviritu_result" }),
            "Expected parent esviritu_result to be discoverable by virus query"
        )
    }

    // MARK: - Fixtures

    @discardableResult
    private func makeFASTQBundle(
        name: String,
        metadataRows: [(String, String)]
    ) throws -> URL {
        let bundleURL = projectURL.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let fastqText = """
        @read1
        ACGTACGT
        +
        IIIIIIII
        """
        try fastqText.write(
            to: bundleURL.appendingPathComponent("reads.fastq"),
            atomically: true,
            encoding: .utf8
        )

        var csv = "key,value\n"
        for (key, value) in metadataRows {
            csv += "\(key),\(value)\n"
        }
        try csv.write(
            to: bundleURL.appendingPathComponent("metadata.csv"),
            atomically: true,
            encoding: .utf8
        )

        return bundleURL
    }

    private func makeClassificationResultDirectory() throws {
        let directory = projectURL.appendingPathComponent("classification-20250328-120000", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sidecar: [String: Any] = [
            "config": ["databaseName": "kraken2-standard"],
            "reportPath": "classification.kreport",
            "outputPath": "classification.kraken",
            "runtime": 1.2,
            "toolVersion": "2.1.3",
            "savedAt": "2026-03-28T12:00:00Z",
        ]
        let sidecarData = try JSONSerialization.data(withJSONObject: sidecar, options: [.sortedKeys])
        try sidecarData.write(to: directory.appendingPathComponent("classification-result.json"))

        let kreport = """
        100.00\t100\t0\tR\t1\troot
        40.00\t40\t40\tS\t694009\t  Human coronavirus HKU1
        60.00\t60\t60\tS\t999999\t  Example virus
        """
        try kreport.write(
            to: directory.appendingPathComponent("classification.kreport"),
            atomically: true,
            encoding: .utf8
        )
        try "C\tread1\t694009\t100\t694009:100\n".write(
            to: directory.appendingPathComponent("classification.kraken"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func makeEsVirituResultDirectory() throws {
        let directory = projectURL.appendingPathComponent("esviritu-20250328-120000", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sidecar: [String: Any] = [
            "config": ["sampleName": "SAMPLE01"],
            "detectionPath": "detected_virus.info.tsv",
            "assemblyPath": NSNull(),
            "taxProfilePath": NSNull(),
            "coveragePath": NSNull(),
            "virusCount": 1,
            "runtime": 2.0,
            "toolVersion": "1.0.0",
            "savedAt": "2026-03-28T12:00:00Z",
        ]
        let sidecarData = try JSONSerialization.data(withJSONObject: sidecar, options: [.sortedKeys])
        try sidecarData.write(to: directory.appendingPathComponent("esviritu-result.json"))

        let detectionTSV = """
        sample_ID\tName\tdescription\tLength\tSegment\tAccession\tAssembly\tAsm_length\tkingdom\tphylum\ttclass\torder\tfamily\tgenus\tspecies\tsubspecies\tRPKMF\tread_count\tcovered_bases\tmean_coverage\tavg_read_identity\tPi\tfiltered_reads_in_sample
        SAMPLE01\tHuman coronavirus HKU1\tHKU1 genome\t30000\tNA\tNC_006577.2\tGCF_009858895.2\t30000\tViruses\tPisuviricota\tPisoniviricetes\tNidovirales\tCoronaviridae\tBetacoronavirus\tHuman coronavirus HKU1\tNA\t18.5\t42\t12000\t3.8\t98.7\t0.001\t500000
        """
        try detectionTSV.write(
            to: directory.appendingPathComponent("detected_virus.info.tsv"),
            atomically: true,
            encoding: .utf8
        )
    }
}
