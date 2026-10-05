// SRARunMetadataLookupTests.swift - SRA run lookups survive one archive failing
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore

/// The SRA Runs search looks runs up in ENA and NCBI through
/// `SRARunMetadataLookup`. It fails only when both archives fail, and it
/// says in one line which archive failed. The archives are a mock HTTP
/// client, so no test reaches the network.
final class SRARunMetadataLookupTests: XCTestCase {

    func testLookupFailsWhenBothArchivesFail() async throws {
        let client = MockHTTPClient()
        await client.register(pattern: "portal/api/filereport", response: .text(ENAOutageFixture.page, statusCode: 500))
        await client.register(pattern: "efetch.fcgi", response: .text(ENAOutageFixture.page, statusCode: 500))

        do {
            _ = try await Self.lookup(client).lookUpRuns(["SRR27069570"])
            XCTFail("Expected the lookup to fail when both archives fail")
        } catch let failure as SRARunMetadataLookup.BothArchivesFailed {
            XCTAssertEqual(
                failure.localizedDescription,
                "ENA returned HTTP 500 (server error), and NCBI returned HTTP 500 (server error)."
            )
        }
    }

    func testLookupKeepsNCBIRunWhenENAFails() async throws {
        let client = MockHTTPClient()
        await client.register(pattern: "portal/api/filereport", response: .text(ENAOutageFixture.page, statusCode: 500))
        await client.register(pattern: "efetch.fcgi", response: .text(Self.runInfoCSV(["SRR27069570"])))

        let outcome = try await Self.lookup(client).lookUpRuns(["SRR27069570"])

        XCTAssertEqual(outcome.runs.map(\.accession), ["SRR27069570"])
        XCTAssertNil(outcome.runs.first?.enaRecord)
        XCTAssertEqual(outcome.runs.first?.ncbiRun?.organism, "Homo sapiens")
        XCTAssertEqual(outcome.notice, "ENA returned HTTP 500 (server error). Results from NCBI are shown.")
    }

    func testLookupCountsENAFailuresWhenSomeLookupsAnswer() async throws {
        let client = MockHTTPClient()
        await client.register(pattern: "accession=SRR27069570", response: .text(ENAOutageFixture.page, statusCode: 500))
        await client.register(
            pattern: "accession=SRR27069571",
            response: .json([["run_accession": "SRR27069571", "library_layout": "PAIRED"]])
        )
        await client.register(pattern: "efetch.fcgi", response: .error(statusCode: 503))

        let outcome = try await Self.lookup(client).lookUpRuns(["SRR27069570", "SRR27069571"])

        XCTAssertEqual(outcome.runs.map(\.accession), ["SRR27069571"])
        XCTAssertEqual(outcome.enaFailedCount, 1)
        XCTAssertEqual(
            outcome.notice,
            "NCBI returned HTTP 503 (server error), and ENA returned HTTP 500 (server error) for 1 of 2 accessions. Results from ENA are shown."
        )
    }

    func testAddingENARecordsKeepsEveryNCBIRunWhenENAFails() async throws {
        let client = MockHTTPClient()
        await client.register(pattern: "portal/api/filereport", response: .text(ENAOutageFixture.page, statusCode: 500))
        let ncbiRun = try XCTUnwrap(SRARunInfoCSVParser.parseRows(Self.runInfoCSV(["SRR27069570"])).first)

        let outcome = try await Self.lookup(client).addingENARecords(to: [ncbiRun])

        XCTAssertEqual(outcome.runs.map(\.accession), ["SRR27069570"])
        XCTAssertEqual(outcome.runs.first?.ncbiRun, ncbiRun)
        XCTAssertEqual(outcome.notice, "ENA returned HTTP 500 (server error). Results from NCBI are shown.")
    }

    func testLookupPropagatesCancellation() async throws {
        let client = MockHTTPClient()
        await client.register(pattern: "portal/api/filereport", response: .cancelled)
        await client.register(pattern: "efetch.fcgi", response: .text(Self.runInfoCSV([])))

        do {
            _ = try await Self.lookup(client).lookUpRuns(["SRR27069570"])
            XCTFail("Expected the cancellation to propagate")
        } catch let error as URLError where error.code == .cancelled {
            // Expected.
        }
    }

    private static func lookup(_ client: MockHTTPClient) -> SRARunMetadataLookup {
        SRARunMetadataLookup(
            ena: ENAService(httpClient: client),
            ncbi: NCBIService(httpClient: client, environment: [:])
        )
    }

    private static func runInfoCSV(_ accessions: [String]) -> String {
        let header = "Run,ReleaseDate,LoadDate,spots,bases,spots_with_mates,avgLength,size_MB,AssemblyName,download_path,Experiment,LibraryName,LibraryStrategy,LibrarySelection,LibrarySource,LibraryLayout,InsertSize,InsertDev,Platform,Model,SRAStudy,BioProject,Study_Pubmed_id,ProjectID,Sample,BioSample,SampleType,TaxID,ScientificName,SampleName"
        let rows = accessions.map { accession in
            "\(accession),2023-12-01 10:00:00,2023-12-01 09:00:00,10000,3000000,10000,300,2,,https://example.invalid/\(accession).sra,SRX22663300,exome,WXS,Hybrid Selection,GENOMIC,PAIRED,0,0,ILLUMINA,Illumina NovaSeq 6000,SRP475000,PRJNA1047265,,1047265,SRS19700000,SAMN38500000,simple,9606,Homo sapiens,donor-1"
        }
        return ([header] + rows).joined(separator: "\n")
    }
}
