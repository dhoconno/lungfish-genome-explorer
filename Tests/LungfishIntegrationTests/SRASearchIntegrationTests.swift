// SRASearchIntegrationTests.swift - Live API integration tests for SRA search
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The CSV fixture always runs locally. Live NCBI/ENA checks are opt-in with
// LUNGFISH_RUN_LIVE_SRA_TESTS=1 because public services can be rate limited.

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
        try Self.requireLiveSRATestsEnabled()
        // DRR028938: 631 reads, paired-end, Illumina HiSeq 2500
        let records = try await liveSRARequest(source: "ENA") {
            try await self.enaService.searchReads(term: "DRR028938", limit: 10)
        }
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
        try Self.requireLiveSRATestsEnabled()
        let accessions = ["DRR028938", "DRR051810", "DRR052292"]

        let records = try await liveSRARequest(source: "ENA") {
            try await self.enaService.searchReadsBatch(
                accessions: accessions,
                concurrency: 3,
                progress: { _, _ in }
            )
        }

        XCTAssertGreaterThanOrEqual(records.count, 2, "Should resolve at least 2 of 3 accessions")
    }

    // MARK: - NCBI SRA ESearch

    func testSRAESearchByOrganism() async throws {
        try Self.requireLiveSRATestsEnabled()
        // Brief delay to avoid NCBI rate limiting when tests run back-to-back
        try await Task.sleep(nanoseconds: 500_000_000)
        let result = try await liveSRAESearch(term: "SARS-CoV-2[Organism]", retmax: 5)
        XCTAssertGreaterThan(result.totalCount, 0, "Should find SRA entries for SARS-CoV-2")
        XCTAssertFalse(result.ids.isEmpty)
    }

    func testSRAESearchByBioProject() async throws {
        try Self.requireLiveSRATestsEnabled()
        // PRJNA989177 is CDC Traveler-Based Genomic Surveillance
        let result = try await liveSRAESearch(term: "PRJNA989177[BioProject]", retmax: 5)
        XCTAssertGreaterThan(result.totalCount, 100, "Should find many entries in PRJNA989177")
        XCTAssertFalse(result.ids.isEmpty)
    }

    // MARK: - Two-Step: ESearch → EFetch → Run Accessions

    func testESearchToEFetchRunAccessions() async throws {
        try Self.requireLiveSRATestsEnabled()
        // Search for a specific small BioProject
        let esearchResult = try await liveSRAESearch(term: "PRJDB3502[BioProject]", retmax: 10)

        let runAccessions = try await liveSRARequest(source: "NCBI") {
            try await self.ncbiService.sraEFetchRunAccessions(uids: Array(esearchResult.ids.prefix(5)))
        }
        XCTAssertFalse(runAccessions.isEmpty, "NCBI SRA EFetch should return run accessions for PRJDB3502")

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

    func testTransientClassifierRecognizesOnlyTransportRateLimitTimeoutAnd5xxFailures() {
        XCTAssertTrue(Self.isTransientLiveSRAError(URLError(.timedOut)))
        XCTAssertTrue(Self.isTransientLiveSRAError(URLError(.networkConnectionLost)))
        XCTAssertTrue(Self.isTransientLiveSRAError(DatabaseServiceError.timeout))
        XCTAssertTrue(Self.isTransientLiveSRAError(DatabaseServiceError.rateLimitExceeded))
        XCTAssertTrue(Self.isTransientLiveSRAError(DatabaseServiceError.invalidResponse(statusCode: 429)))
        XCTAssertTrue(Self.isTransientLiveSRAError(DatabaseServiceError.invalidResponse(statusCode: 503)))
        XCTAssertTrue(Self.isTransientLiveSRAError(DatabaseServiceError.serverError(message: "HTTP 503")))
        XCTAssertTrue(Self.isTransientLiveSRAError(DatabaseServiceError.serverError(message: "HTTP 500: unavailable")))
    }

    func testTransientClassifierPreservesMalformedAndAssertionRelevantFailures() {
        XCTAssertFalse(Self.isTransientLiveSRAError(DatabaseServiceError.networkError(underlying: "Invalid response type")))
        XCTAssertFalse(Self.isTransientLiveSRAError(DatabaseServiceError.serverError(message: "Search Backend failed")))
        XCTAssertFalse(Self.isTransientLiveSRAError(DatabaseServiceError.serverError(message: "address table is empty")))
        XCTAssertFalse(Self.isTransientLiveSRAError(DatabaseServiceError.serverError(message: "HTTP 503malformed")))
        XCTAssertFalse(Self.isTransientLiveSRAError(DatabaseServiceError.parseError(message: "malformed HTTP 200 payload")))
        XCTAssertFalse(Self.isTransientLiveSRAError(DatabaseServiceError.invalidQuery(reason: "Bad request")))
        XCTAssertFalse(Self.isTransientLiveSRAError(URLError(.cancelled)))
    }

    private func liveSRAESearch(term: String, retmax: Int) async throws -> NCBIService.ESearchSearchResult {
        try await liveSRARequest(source: "NCBI") {
            try await self.ncbiService.sraESearch(term: term, retmax: retmax)
        }
    }

    private static let liveSRATestsEnvironmentKey = "LUNGFISH_RUN_LIVE_SRA_TESTS"

    private static func requireLiveSRATestsEnabled() throws {
        let rawValue = ProcessInfo.processInfo.environment[liveSRATestsEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let enabledValues = ["1", "true", "yes", "on"]
        guard let rawValue, enabledValues.contains(rawValue) else {
            throw XCTSkip(
                "Live SRA integration tests are disabled. Set \(liveSRATestsEnvironmentKey)=1 to run."
            )
        }
    }

    private func liveSRARequest<T>(
        source: String,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch {
            if Self.isTransientLiveSRAError(error) {
                throw XCTSkip("\(source) SRA service is temporarily unavailable: \(error)")
            }
            throw error
        }
    }

    private static func isTransientLiveSRAError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost,
                    .networkConnectionLost, .dnsLookupFailed,
                    .notConnectedToInternet, .internationalRoamingOff,
                    .callIsActive, .dataNotAllowed, .cannotLoadFromNetwork:
                return true
            default:
                return false
            }
        }
        guard let databaseError = error as? DatabaseServiceError else {
            return false
        }
        switch databaseError {
        case .rateLimitExceeded, .timeout:
            return true
        case .invalidResponse(let statusCode):
            return statusCode == 429 || (500...599).contains(statusCode)
        case .serverError(let message):
            return isExplicit5xxServerMessage(message)
        default:
            return false
        }
    }

    private static func isExplicit5xxServerMessage(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized.hasPrefix("HTTP ") else {
            return false
        }
        let statusDigits = normalized.dropFirst("HTTP ".count).prefix(while: \.isNumber)
        guard statusDigits.count == 3, let statusCode = Int(statusDigits) else {
            return false
        }
        let remainder = normalized.dropFirst("HTTP ".count + statusDigits.count)
        guard remainder.isEmpty || remainder.first == ":" || remainder.first?.isWhitespace == true else {
            return false
        }
        return (500...599).contains(statusCode)
    }
}
