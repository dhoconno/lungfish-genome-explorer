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
            #"type:fastq format:vcf sample:"Air Sample 01" role:test_sample date>=2025-01-01 date<=2025-01-31 virus:HKU1 notes:"batch alpha" unique_reads>=20 total_reads<1000000"#
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
        XCTAssertTrue(parsed.numberFilters.contains {
            $0.key == "read_count" && $0.comparison == .greaterThanOrEqual && $0.value == 20
        })
        XCTAssertTrue(parsed.numberFilters.contains {
            $0.key == "filtered_reads_in_sample" && $0.comparison == .lessThan && $0.value == 1_000_000
        })
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

        let brackenTaxonResults = try index.search(
            rawQuery: "type:classification_taxon virus:sars-cov-2 read_count>=20",
            limit: 20
        )
        XCTAssertTrue(
            brackenTaxonResults.contains(where: { $0.kind == "classification_taxon" }),
            "Expected classification_taxon entity to be searchable from Bracken taxa"
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

        let thresholded = try index.search(
            rawQuery: #"type:virus_hit family:coronaviridae species:"human coronavirus hku1" unique_reads>=20 total_reads>=500000"#,
            limit: 50
        )
        XCTAssertTrue(
            thresholded.contains(where: { $0.kind == "virus_hit" }),
            "Expected virus_hit to match family/species + numeric read thresholds"
        )

        let parentFamilyMatch = try index.search(
            rawQuery: "type:esviritu_result family:coronaviridae",
            limit: 50
        )
        XCTAssertTrue(
            parentFamilyMatch.contains(where: { $0.kind == "esviritu_result" }),
            "Expected parent esviritu_result to match family filter"
        )

        let tooHigh = try index.search(
            rawQuery: "type:virus_hit virus:hku1 unique_reads>=1000",
            limit: 50
        )
        XCTAssertFalse(
            tooHigh.contains(where: { $0.kind == "virus_hit" }),
            "Expected no virus_hit at excessive unique_reads threshold"
        )

        let sarsAlias = try index.search(rawQuery: "sars-cov-2", limit: 50)
        XCTAssertTrue(
            sarsAlias.contains(where: { $0.kind == "virus_hit" }),
            "Expected plain-text SARS-CoV-2 alias to match EsViritu virus hits"
        )
    }

    func testTaxTriageFoundPathogensAreSearchable() throws {
        try makeTaxTriageResultDirectory()

        let index = try ProjectUniversalSearchIndex(projectURL: projectURL)
        _ = try index.rebuild()

        let foundPathogens = try index.search(
            rawQuery: "type:taxtriage_organism found_pathogen:true virus:sars-cov-2",
            limit: 20
        )
        XCTAssertTrue(
            foundPathogens.contains(where: { $0.kind == "taxtriage_organism" }),
            "Expected TaxTriage found pathogens to be searchable by SARS-CoV-2 alias"
        )

        let parentResults = try index.search(
            rawQuery: "type:taxtriage_result found_pathogen:true virus:sars-cov-2",
            limit: 20
        )
        XCTAssertTrue(
            parentResults.contains(where: { $0.kind == "taxtriage_result" }),
            "Expected TaxTriage parent result to carry found-pathogen search attributes"
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
            "brackenPath": "classification.bracken.tsv",
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

        let bracken = """
        name\ttaxonomy_id\ttaxonomy_lvl\tkraken_assigned_reads\tadded_reads\tnew_est_reads\tfraction_total_reads
        Severe acute respiratory syndrome coronavirus 2\t2697049\tS\t12\t38\t50\t0.50000
        Human coronavirus HKU1\t290028\tS\t5\t20\t25\t0.25000
        """
        try bracken.write(
            to: directory.appendingPathComponent("classification.bracken.tsv"),
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
        SAMPLE01\tSevere acute respiratory syndrome coronavirus 2\tSARS-CoV-2 genome\t29903\tNA\tNC_045512.2\tGCF_009858895.2\t29903\tViruses\tPisuviricota\tPisoniviricetes\tNidovirales\tCoronaviridae\tBetacoronavirus\tSevere acute respiratory syndrome coronavirus 2\tNA\t12.2\t24\t9800\t2.5\t98.2\t0.002\t500000
        """
        try detectionTSV.write(
            to: directory.appendingPathComponent("detected_virus.info.tsv"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func makeTaxTriageResultDirectory() throws {
        let directory = projectURL.appendingPathComponent("taxtriage-20250328-120000", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let sidecar: [String: Any] = [
            "runtime": 7.4,
            "exitCode": 0,
            "savedAt": "2026-03-28T12:00:00Z",
        ]
        let sidecarData = try JSONSerialization.data(withJSONObject: sidecar, options: [.sortedKeys])
        try sidecarData.write(to: directory.appendingPathComponent("taxtriage-result.json"))

        let metrics = """
        sample\ttaxid\torganism\trank\treads\tcoverage_breadth\tcoverage_depth\ttass_score\tconfidence
        SAMPLE01\t2697049\tSevere acute respiratory syndrome coronavirus 2\tS\t81\t42.0\t8.3\t0.93\thigh
        SAMPLE01\t290028\tHuman coronavirus HKU1\tS\t22\t19.1\t2.4\t0.52\tmedium
        """
        try metrics.write(
            to: directory.appendingPathComponent("multiqc_confidences.txt"),
            atomically: true,
            encoding: .utf8
        )
    }
}
