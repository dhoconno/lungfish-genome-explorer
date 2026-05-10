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
        let result = try await liveSRAESearch(term: "SARS-CoV-2[Organism]", retmax: 5)
        XCTAssertGreaterThan(result.totalCount, 0, "Should find SRA entries for SARS-CoV-2")
        XCTAssertFalse(result.ids.isEmpty)
    }

    func testSRAESearchByBioProject() async throws {
        // PRJNA989177 is CDC Traveler-Based Genomic Surveillance
        let result = try await liveSRAESearch(term: "PRJNA989177[BioProject]", retmax: 5)
        XCTAssertGreaterThan(result.totalCount, 100, "Should find many entries in PRJNA989177")
        XCTAssertFalse(result.ids.isEmpty)
    }

    // MARK: - Two-Step: ESearch → EFetch → Run Accessions

    func testESearchToEFetchRunAccessions() async throws {
        // Search for a specific small BioProject
        let esearchResult = try await liveSRAESearch(term: "PRJDB3502[BioProject]", retmax: 10)

        let runAccessions: [String]
        do {
            runAccessions = try await ncbiService.sraEFetchRunAccessions(uids: Array(esearchResult.ids.prefix(5)))
        } catch {
            if isTransientNCBISRAError(error) {
                throw XCTSkip("NCBI SRA EFetch backend is temporarily unavailable for PRJDB3502: \(error)")
            }
            throw error
        }
        guard !runAccessions.isEmpty else {
            throw XCTSkip("NCBI SRA EFetch returned no run accessions for a stable BioProject; treating as transient live API unavailability.")
        }

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

    private func liveSRAESearch(term: String, retmax: Int) async throws -> NCBIService.ESearchSearchResult {
        do {
            let result = try await ncbiService.sraESearch(term: term, retmax: retmax)
            guard !result.ids.isEmpty else {
                throw XCTSkip("NCBI SRA ESearch returned zero IDs for \(term); treating as transient live API unavailability.")
            }
            return result
        } catch {
            if isTransientNCBISRAError(error) {
                throw XCTSkip("NCBI SRA ESearch backend is temporarily unavailable for \(term): \(error)")
            }
            throw error
        }
    }

    private func isTransientNCBISRAError(_ error: Error) -> Bool {
        if case DatabaseServiceError.invalidQuery(let reason) = error {
            return reason.localizedCaseInsensitiveContains("Bad request")
        }
        guard case DatabaseServiceError.serverError(let message) = error else {
            return false
        }
        return message.localizedCaseInsensitiveContains("Search Backend failed")
            || message.localizedCaseInsensitiveContains("address table is empty")
    }
}
