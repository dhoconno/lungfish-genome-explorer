// SRASearchIntegrationTests.swift - Live API integration tests for SRA search
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// These tests hit real NCBI/ENA APIs and may be slow or flaky.
// Skip in CI by filtering: swift test --skip SRASearchIntegrationTests

import XCTest
@testable import LungfishCore

final class SRASearchIntegrationTests: XCTestCase {

    private var enaService: ENAService!
    private var ncbiService: NCBIService!

    override func setUp() async throws {
        try await super.setUp()
        enaService = ENAService()
        ncbiService = NCBIService()
    }

    // MARK: - Single Accession via ENA

    func testSingleAccessionViaENA() async throws {
        // DRR028938: 631 reads, paired-end, Illumina HiSeq 2500
        let records = try await enaService.searchReads(term: "DRR028938", limit: 10)
        XCTAssertFalse(records.isEmpty, "Should find DRR028938 in ENA")

        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.runAccession, "DRR028938")
        XCTAssertEqual(record.libraryLayout, "PAIRED")
        XCTAssertEqual(record.instrumentPlatform, "ILLUMINA")
        XCTAssertNotNil(record.readCount)
        XCTAssertNotNil(record.fastqFTP, "Should have FASTQ download URLs")
    }

    // MARK: - Batch Lookup

    func testBatchThreeAccessions() async throws {
        let accessions = ["DRR028938", "DRR051810", "DRR052292"]

        let records = try await enaService.searchReadsBatch(
            accessions: accessions,
            concurrency: 3,
            progress: { _, _ in }
        )

        XCTAssertGreaterThanOrEqual(records.count, 2, "Should resolve at least 2 of 3 accessions")
    }

    // MARK: - NCBI SRA ESearch

    func testSRAESearchByOrganism() async throws {
        // Brief delay to avoid NCBI rate limiting when tests run back-to-back
        try await Task.sleep(nanoseconds: 500_000_000)
        let result = try await ncbiService.sraESearch(term: "SARS-CoV-2[Organism]", retmax: 5)
        XCTAssertGreaterThan(result.totalCount, 0, "Should find SRA entries for SARS-CoV-2")
        XCTAssertFalse(result.ids.isEmpty)
    }

    func testSRAESearchByBioProject() async throws {
        // PRJNA989177 is CDC Traveler-Based Genomic Surveillance
        let result = try await ncbiService.sraESearch(term: "PRJNA989177[BioProject]", retmax: 5)
        XCTAssertGreaterThan(result.totalCount, 100, "Should find many entries in PRJNA989177")
        XCTAssertFalse(result.ids.isEmpty)
    }

    // MARK: - Two-Step: ESearch → EFetch → Run Accessions

    func testESearchToEFetchRunAccessions() async throws {
        // Search for a specific small BioProject
        let esearchResult = try await ncbiService.sraESearch(term: "PRJDB3502[BioProject]", retmax: 10)
        XCTAssertGreaterThan(esearchResult.ids.count, 0, "Should find entries")

        let runAccessions = try await ncbiService.sraEFetchRunAccessions(uids: Array(esearchResult.ids.prefix(5)))
        XCTAssertGreaterThan(runAccessions.count, 0, "Should resolve to run accessions")

        // Run accessions should match SRA pattern
        for acc in runAccessions {
            XCTAssertTrue(SRAAccessionParser.isSRAAccession(acc),
                         "\(acc) should be a valid SRA accession")
        }
    }

    // MARK: - CSV Fixture Parsing

    func testParseFixtureCSV() throws {
        // Use file path relative to the test file location
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sra/sample-accession-list.csv")

        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("Fixture file not found at \(fixtureURL.path)")
        }

        let accessions = try SRAAccessionParser.parseCSVFile(at: fixtureURL)
        XCTAssertEqual(accessions, ["DRR028938", "DRR051810", "DRR052292"])
    }
}
