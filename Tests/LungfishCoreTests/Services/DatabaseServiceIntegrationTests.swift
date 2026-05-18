// DatabaseServiceIntegrationTests.swift - Integration tests for database services
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCore

/// Integration tests that make real network requests to NCBI and ENA.
/// These tests require network access and may be slow.
final class DatabaseServiceIntegrationTests: XCTestCase {

    // MARK: - NCBI Tests

    func testNCBISearch() async throws {
        try Self.requireLiveDatabaseTestsEnabled()

        // Wait to avoid rate limiting from other tests in the suite
        try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds

        let service = NCBIService()

        // Search for a well-known sequence
        let query = SearchQuery(term: "NC_001802", limit: 5)
        let results: SearchResults
        do {
            results = try await service.search(query)
        } catch {
            if let reason = Self.transientLiveNCBISkipReason(for: error) {
                throw XCTSkip(reason)
            }
            throw error
        }

        guard !results.records.isEmpty else {
            throw XCTSkip("NCBI live nucleotide search returned zero records for stable accession NC_001802")
        }

        XCTAssertGreaterThan(results.records.count, 0, "Should find at least one result")

        if let first = results.records.first {
            print("Found: \(first.accession) - \(first.title)")
            XCTAssertFalse(first.accession.isEmpty)
            XCTAssertFalse(first.title.isEmpty)
        }
    }

    func testNCBIFetchGenBank() async throws {
        try Self.requireLiveDatabaseTestsEnabled()

        let service = NCBIService()

        // Fetch HIV-1 reference genome (well-known, stable accession)
        let record = try await service.fetch(accession: "NC_001802")

        XCTAssertEqual(record.source, .ncbi)
        XCTAssertFalse(record.accession.isEmpty)
        XCTAssertFalse(record.title.isEmpty)
        XCTAssertGreaterThan(record.sequence.count, 1000, "HIV-1 genome should be >9kb")

        print("Fetched: \(record.accession)")
        print("Title: \(record.title)")
        print("Organism: \(record.organism ?? "Unknown")")
        print("Sequence length: \(record.sequence.count) bp")
    }

    func testNCBISearchEbola() async throws {
        try Self.requireLiveDatabaseTestsEnabled()

        // Wait to avoid rate limiting from previous tests
        try await Task.sleep(nanoseconds: 500_000_000)  // 0.5 seconds

        let service = NCBIService()

        // Search for Ebola virus sequences using accession prefix
        // KM034562 is a well-known Ebola virus Makona genome
        let query = SearchQuery(term: "KM034562", limit: 5)
        let results: SearchResults
        do {
            results = try await service.search(query)
        } catch {
            if let reason = Self.transientLiveNCBISkipReason(for: error) {
                throw XCTSkip(reason)
            }
            throw error
        }

        print("Found \(results.records.count) Ebola-related sequences:")
        for record in results.records.prefix(5) {
            print("  \(record.accession): \(record.title.prefix(60))...")
        }

        guard !results.records.isEmpty else {
            throw XCTSkip("NCBI live nucleotide search returned zero records for stable accession KM034562")
        }

        XCTAssertGreaterThan(results.records.count, 0, "Should find KM034562 Ebola sequence")
    }

    // MARK: - ENA Tests

    func testENASearch() async throws {
        try Self.requireLiveDatabaseTestsEnabled()

        let service = ENAService()

        // Search for a well-known sequence
        let query = SearchQuery(term: "coronavirus", limit: 5)
        let results = try await service.search(query)

        print("ENA found \(results.records.count) results:")
        for record in results.records.prefix(3) {
            print("  \(record.accession): \(record.title.prefix(50))...")
        }

        // ENA may return 0 results depending on API status
        // Just verify no crash
    }

    func testENAFetchFASTA() async throws {
        try Self.requireLiveDatabaseTestsEnabled()

        let service = ENAService()

        // Fetch a known ENA sequence
        let fasta = try await service.fetchFASTA(accession: "MN908947")

        XCTAssertTrue(fasta.hasPrefix(">"), "Should be valid FASTA")
        XCTAssertGreaterThan(fasta.count, 100)

        print("Fetched FASTA from ENA:")
        print(fasta.prefix(200))
    }

    // MARK: - SRA Tests

    func testSRASearch() async throws {
        try Self.requireLiveDatabaseTestsEnabled()

        // Wait to avoid rate limiting
        try await Task.sleep(nanoseconds: 500_000_000)

        let service = SRAService()

        // Search for a well-known SRA run
        let query = SearchQuery(term: "SRR11140748", limit: 5)
        let results: SRASearchResults
        do {
            results = try await service.search(query)
        } catch {
            if let reason = Self.transientLiveNCBISkipReason(for: error) {
                throw XCTSkip(reason)
            }
            throw error
        }

        print("SRA found \(results.runs.count) runs:")
        for run in results.runs.prefix(3) {
            print("  \(run.accession): \(run.organism ?? "Unknown") - \(run.spotsString)")
        }

        if results.runs.isEmpty {
            throw XCTSkip("NCBI live SRA search returned zero run-info rows for stable accession SRR11140748")
        }
    }

    func testSRAToolkitDetection() async throws {
        try Self.requireLiveDatabaseTestsEnabled()

        let service = SRAService()
        let available = await service.isSRAToolkitAvailable

        print("SRA Toolkit available: \(available)")
        // Don't assert - toolkit may or may not be installed
    }

    // MARK: - Raw GenBank Download Tests

    func testNCBIFetchRawGenBankPreservesAnnotations() async throws {
        try Self.requireLiveDatabaseTestsEnabled()

        // Wait to avoid rate limiting from previous tests
        try await Task.sleep(nanoseconds: 500_000_000)

        let service = NCBIService()

        // Fetch HIV-1 reference genome as raw GenBank
        let result = try await service.fetchRawGenBank(accession: "NC_001802")

        // Verify raw content is preserved with all sections
        XCTAssertTrue(result.content.contains("LOCUS"), "Should contain LOCUS line")
        XCTAssertTrue(result.content.contains("FEATURES"), "Should contain FEATURES section")
        XCTAssertTrue(result.content.contains("ORIGIN"), "Should contain ORIGIN section")
        XCTAssertTrue(result.content.contains("//"), "Should contain terminator")

        // Verify annotations are preserved (HIV-1 has many genes)
        XCTAssertTrue(result.content.contains("/gene="), "Should contain gene annotations")
        XCTAssertTrue(result.content.contains("CDS"), "Should contain CDS features")

        // Verify accession is correctly extracted
        XCTAssertFalse(result.accession.isEmpty, "Accession should not be empty")
        print("Raw GenBank accession: \(result.accession)")
        print("Content length: \(result.content.count) characters")

        // Count features to verify richness
        let featureCount = result.content.components(separatedBy: "     gene").count - 1
        print("Approximate gene count: \(featureCount)")
        XCTAssertGreaterThan(featureCount, 0, "Should have gene features")
    }

    func testDownloadGenBankToFile() async throws {
        try Self.requireLiveDatabaseTestsEnabled()

        // Wait to avoid rate limiting
        try await Task.sleep(nanoseconds: 500_000_000)

        let service = NCBIService()

        // Fetch a small well-known sequence
        let result = try await service.fetchRawGenBank(accession: "NC_001802")

        // Save to temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "\(result.accession).gb"
        let fileURL = tempDir.appendingPathComponent(filename)

        try result.content.write(to: fileURL, atomically: true, encoding: .utf8)

        // Verify file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Read back and verify structure
        let readContent = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(readContent.hasPrefix("LOCUS"), "File should start with LOCUS")
        XCTAssertTrue(readContent.contains("FEATURES"), "File should contain FEATURES")
        XCTAssertTrue(readContent.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("//"), "File should end with //")

        print("Downloaded GenBank to: \(fileURL.path)")
        print("File size: \(readContent.count) bytes")

        // Clean up
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Download to File Tests

    func testDownloadToTemporaryFile() async throws {
        try Self.requireLiveDatabaseTestsEnabled()

        // Wait to avoid rate limiting from previous tests
        try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second

        let service = NCBIService()

        // Fetch a small sequence
        let record = try await service.fetch(accession: "NC_001802")

        // Save to temporary file
        let tempDir = FileManager.default.temporaryDirectory
        let filename = "\(record.accession).fasta"
        let fileURL = tempDir.appendingPathComponent(filename)

        // Create FASTA content
        var fastaContent = ">\(record.accession)"
        if !record.title.isEmpty {
            fastaContent += " \(record.title)"
        }
        if let organism = record.organism {
            fastaContent += " [\(organism)]"
        }
        fastaContent += "\n"

        // Wrap sequence at 80 characters
        let sequence = record.sequence
        let lineLength = 80
        var index = sequence.startIndex
        while index < sequence.endIndex {
            let end = sequence.index(index, offsetBy: lineLength, limitedBy: sequence.endIndex) ?? sequence.endIndex
            fastaContent += String(sequence[index..<end]) + "\n"
            index = end
        }

        try fastaContent.write(to: fileURL, atomically: true, encoding: .utf8)

        // Verify file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Read back and verify
        let readContent = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(readContent.hasPrefix(">NC_001802"))

        print("Downloaded to: \(fileURL.path)")
        print("File size: \(readContent.count) bytes")

        // Clean up
        try? FileManager.default.removeItem(at: fileURL)
    }

    private static let liveDatabaseTestsEnvironmentKey = "LUNGFISH_RUN_LIVE_DATABASE_TESTS"

    private static func requireLiveDatabaseTestsEnabled() throws {
        let rawValue = ProcessInfo.processInfo.environment[liveDatabaseTestsEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let enabledValues = ["1", "true", "yes", "on"]

        guard let rawValue, enabledValues.contains(rawValue) else {
            throw XCTSkip(
                "Live database integration tests are disabled. Set \(liveDatabaseTestsEnvironmentKey)=1 to run."
            )
        }
    }

    private static func transientLiveNCBISkipReason(for error: Error) -> String? {
        let description = String(describing: error)
        let transientFragments = [
            "Search Backend failed",
            "address table is empty",
            "Unexpected end of file",
            "Failed to fetch run info",
            "Bad request",
            "timed out",
            "resource unavailable",
            "network connection was lost",
            "cannot connect",
            "cannot find host",
        ]

        guard transientFragments.contains(where: { description.localizedCaseInsensitiveContains($0) }) else {
            return nil
        }
        return "NCBI live backend is temporarily unavailable: \(description)"
    }
}
