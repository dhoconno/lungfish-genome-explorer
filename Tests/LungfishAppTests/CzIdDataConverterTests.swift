// CzIdDataConverterTests.swift - Tests for CZ-ID classification import conversion
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class CzIdDataConverterTests: XCTestCase {
    func testParsesMinimalTaxonReportAndMetadata() throws {
        let fixture = fixtureURL("minimal_taxon_report.tsv")

        let parsed = try CzIdDataConverter.parseTaxonReport(at: fixture)

        XCTAssertEqual(parsed.metadata.sampleName, "Sample-CZ-001")
        XCTAssertEqual(parsed.metadata.projectId, "Project-42")
        XCTAssertEqual(parsed.metadata.pipelineVersion, "8.4")
        XCTAssertEqual(parsed.metadata.ntDatabaseVersion, "nt_2025_12_01")
        XCTAssertEqual(parsed.metadata.nrDatabaseVersion, "nr_2025_12_01")
        XCTAssertEqual(parsed.rows.count, 3)

        let sarsCoV2 = try XCTUnwrap(parsed.rows.first { $0.taxId == 2697049 })
        XCTAssertEqual(sarsCoV2.name, "Severe acute respiratory syndrome coronavirus 2")
        XCTAssertEqual(sarsCoV2.rank, "species")
        XCTAssertEqual(sarsCoV2.ntReadCount, 42)
        XCTAssertEqual(sarsCoV2.ntRpm, 35000, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(sarsCoV2.ntPercentIdentity), 97.8, accuracy: 0.001)
        XCTAssertEqual(sarsCoV2.ntAlignmentLength, 151)
        XCTAssertEqual(try XCTUnwrap(sarsCoV2.ntEValue), 2e-50, accuracy: 1e-60)
        XCTAssertEqual(sarsCoV2.nrReadCount, 5)
    }

    func testConvertsTaxonReportToClassificationResult() throws {
        let fixture = fixtureURL("minimal_taxon_report.tsv")
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("czid-converter-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let converted = try CzIdDataConverter.convertTaxonReport(
            at: fixture,
            outputDirectory: outputDirectory
        )

        XCTAssertEqual(converted.result.config.databaseName, "CZ-ID")
        XCTAssertEqual(converted.result.config.databaseVersion, "nt=nt_2025_12_01; nr=nr_2025_12_01")
        XCTAssertEqual(converted.result.toolVersion, "8.4")
        XCTAssertEqual(converted.result.tree.totalReads, 1200)
        XCTAssertEqual(converted.result.tree.node(taxId: 2697049)?.readsDirect, 42)
        XCTAssertTrue(FileManager.default.fileExists(atPath: converted.result.reportURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: converted.result.outputURL.path))

        let manifest = try XCTUnwrap(converted.manifest)
        XCTAssertEqual(manifest.sampleName, "Sample-CZ-001")
        XCTAssertEqual(manifest.sourceFiles.map(\.lastPathComponent), ["minimal_taxon_report.tsv"])
    }

    private func fixtureURL(_ name: String) -> URL {
        Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/CzId", isDirectory: true)
            .appendingPathComponent(name)
    }
}
