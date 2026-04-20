// SRAServiceTests.swift - Tests for SRA service retry behavior
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore

final class SRAServiceTests: XCTestCase {

    func testSearchRetriesTransientRunInfoFetchFailure() async throws {
        let ncbiClient = MockHTTPClient()
        await ncbiClient.registerNCBISearch(ids: ["111"])

        let runInfoCSV = """
        Run,ReleaseDate,LoadDate,spots,bases,spots_with_mates,avgLength,size_MB,AssemblyName,download_path,Experiment,LibraryName,LibraryStrategy,LibrarySelection,LibrarySource,LibraryLayout,InsertSize,InsertDev,Platform,Model,SRAStudy,BioProject,Study_Pubmed_id,ProjectID,Sample,BioSample,SampleType,TaxID,ScientificName,SampleName
        SRR11140748,2020-03-18,2020-03-18,421352,126405600,421352,300,210,na,https://example.invalid/SRR11140748.sra,SRX7892566,,WGS,RANDOM,GENOMIC,PAIRED,0,0,ILLUMINA,Illumina NextSeq 500,SRP252920,PRJNA615032,,615032,SRS6529339,SAMN14430827,simple,2697049,Severe acute respiratory syndrome coronavirus 2,USA-WA-UW-2244/2020
        """

        let efetchClient = SequencedHTTPClient(
            responses: [
                .text("temporarily unavailable", statusCode: 503),
                .text(runInfoCSV)
            ]
        )

        let service = SRAService(
            ncbiService: NCBIService(httpClient: ncbiClient),
            httpClient: efetchClient
        )

        let results = try await service.search(SearchQuery(term: "SRR11140748", limit: 5))

        XCTAssertEqual(results.runs.count, 1)
        XCTAssertEqual(results.runs.first?.accession, "SRR11140748")

        let requests = await efetchClient.requests
        XCTAssertEqual(requests.count, 2, "Expected one retry for transient run-info fetch failure")
    }
}

private actor SequencedHTTPClient: HTTPClient {
    struct Response: Sendable {
        let data: Data
        let statusCode: Int

        static func text(_ string: String, statusCode: Int = 200) -> Response {
            Response(data: Data(string.utf8), statusCode: statusCode)
        }
    }

    private(set) var requests: [URLRequest] = []
    private var responses: [Response]

    init(responses: [Response]) {
        self.responses = responses
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)

        guard !responses.isEmpty else {
            throw URLError(.badServerResponse)
        }

        let response = responses.removeFirst()
        let httpResponse = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!

        return (response.data, httpResponse)
    }
}
