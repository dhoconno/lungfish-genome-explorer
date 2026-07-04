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
        XCTAssertNotNil(results.runs.first?.releaseDate)

        let requests = await efetchClient.requests
        XCTAssertEqual(requests.count, 2, "Expected one retry for transient run-info fetch failure")
    }

    func testDownloadFASTQFromENAUsesHTTPClientDownload() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sra-ena-download-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let client = DownloadRecordingHTTPClient()
        let service = SRAService(
            ncbiService: NCBIService(httpClient: client),
            httpClient: client
        )

        let urls = try await service.downloadFASTQFromENA(
            accession: "SRR123456",
            outputDir: outputDirectory
        )

        XCTAssertEqual(urls.map(\.lastPathComponent), ["SRR123456.fastq.gz"])
        let downloadedURL = try XCTUnwrap(urls.first)
        XCTAssertEqual(
            try String(contentsOf: downloadedURL, encoding: .utf8),
            "@SRR123456\nACGT\n+\nIIII\n"
        )

        let dataRequests = await client.dataRequestURLs
        XCTAssertEqual(dataRequests.count, 1)
        let dataRequestURL = try XCTUnwrap(dataRequests.first)
        XCTAssertTrue(dataRequestURL.absoluteString.contains("portal/api/filereport"))

        let downloadRequests = await client.downloadRequestURLs
        XCTAssertEqual(downloadRequests.count, 1)
        let downloadRequestURL = try XCTUnwrap(downloadRequests.first)
        XCTAssertEqual(
            downloadRequestURL.absoluteString,
            "https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR123/SRR123456/SRR123456.fastq.gz"
        )
    }

    func testDownloadFASTQFromENAPropagatesCancelledDownload() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sra-ena-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let client = CancelledENADownloadHTTPClient()
        let service = SRAService(
            ncbiService: NCBIService(httpClient: client),
            httpClient: client
        )

        do {
            _ = try await service.downloadFASTQFromENA(
                accession: "SRR123456",
                outputDir: outputDirectory
            )
            XCTFail("Expected cancellation to be propagated")
        } catch let error as URLError where error.code == .cancelled {
            // Expected.
        } catch {
            XCTFail("Expected URLError.cancelled, got \(error)")
        }

        let downloadRequests = await client.downloadRequestURLs
        XCTAssertEqual(downloadRequests.count, 1)
        XCTAssertEqual(
            downloadRequests.first?.absoluteString,
            "https://ftp.sra.ebi.ac.uk/vol1/fastq/SRR123/SRR123456/SRR123456_1.fastq.gz"
        )
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

private actor DownloadRecordingHTTPClient: HTTPClient {
    private(set) var dataRequestURLs: [URL] = []
    private(set) var downloadRequestURLs: [URL] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        dataRequestURLs.append(url)

        let payload: [[String: Any]] = [
            [
                "run_accession": "SRR123456",
                "experiment_accession": "SRX123456",
                "sample_accession": "SRS123456",
                "study_accession": "SRP123456",
                "library_layout": "SINGLE",
                "fastq_ftp": "ftp.sra.ebi.ac.uk/vol1/fastq/SRR123/SRR123456/SRR123456.fastq.gz",
                "fastq_bytes": "26",
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return (data, httpResponse(url: url, statusCode: 200))
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        downloadRequestURLs.append(url)

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sra-download-client-\(UUID().uuidString)")
        try "@SRR123456\nACGT\n+\nIIII\n".write(to: temporaryURL, atomically: true, encoding: .utf8)
        return (temporaryURL, httpResponse(url: url, statusCode: 200))
    }

    private func httpResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }
}

private actor CancelledENADownloadHTTPClient: HTTPClient {
    private(set) var downloadRequestURLs: [URL] = []

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        let payload: [[String: Any]] = [
            [
                "run_accession": "SRR123456",
                "experiment_accession": "SRX123456",
                "sample_accession": "SRS123456",
                "study_accession": "SRP123456",
                "library_layout": "PAIRED",
                "fastq_ftp": [
                    "ftp.sra.ebi.ac.uk/vol1/fastq/SRR123/SRR123456/SRR123456_1.fastq.gz",
                    "ftp.sra.ebi.ac.uk/vol1/fastq/SRR123/SRR123456/SRR123456_2.fastq.gz",
                ].joined(separator: ";"),
                "fastq_bytes": "26;26",
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        return (data, httpResponse(url: url, statusCode: 200))
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        downloadRequestURLs.append(url)
        throw URLError(.cancelled)
    }

    private func httpResponse(url: URL, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
    }
}
