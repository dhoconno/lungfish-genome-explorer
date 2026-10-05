// SRARunsSearchArchiveOutageTests.swift - The SRA Runs search when ENA or NCBI fails
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishApp
@testable import LungfishCore

/// The SRA Runs search while one archive is down.
///
/// On 2026-10-04 ENA's portal API answered every request with an HTTP 500
/// HTML page while NCBI's E-utilities worked. A search for the run
/// SRR27069570 failed and showed the page's markup as its error. A search
/// now shows the run from whichever archive answered, says in one line
/// which archive failed, and fails only when both fail. The archives are
/// mock HTTP clients, so no test reaches the network.
@MainActor
final class SRARunsSearchArchiveOutageTests: XCTestCase {

    func testSingleRunSearchShowsNCBIRecordWhenENAFails() async throws {
        let client = ArchiveOutageHTTPClient()
        await client.register("portal/api/filereport", status: 500, body: Self.enaOutagePage)
        await client.register("efetch.fcgi", status: 200, body: Self.runInfoCSV(["SRR27069570"]))
        let model = makeModel(client)

        await search(model, for: "SRR27069570")

        XCTAssertEqual(model.results.map(\.accession), ["SRR27069570"])
        XCTAssertEqual(model.results.first?.organism, "Homo sapiens")
        XCTAssertEqual(model.results.first?.length, 3_000_000)
        XCTAssertEqual(model.errorMessage, "ENA returned HTTP 500 (server error). Results from NCBI are shown.")
    }

    func testSingleRunSearchShowsENARecordWhenNCBIFails() async throws {
        let client = ArchiveOutageHTTPClient()
        await client.register("portal/api/filereport", status: 200, body: Self.enaRecordsJSON(["SRR27069570"]))
        await client.register("efetch.fcgi", status: 503, body: "Service Unavailable")
        let model = makeModel(client)

        await search(model, for: "SRR27069570")

        XCTAssertEqual(model.results.map(\.accession), ["SRR27069570"])
        XCTAssertEqual(model.results.first?.title, "Exome of a human donor")
        XCTAssertEqual(model.errorMessage, "NCBI returned HTTP 503 (server error). Results from ENA are shown.")
    }

    func testSingleRunSearchFailsWithOneShortLineWhenBothArchivesFail() async throws {
        let client = ArchiveOutageHTTPClient()
        await client.register("portal/api/filereport", status: 500, body: Self.enaOutagePage)
        await client.register("efetch.fcgi", status: 500, body: Self.enaOutagePage)
        let model = makeModel(client)

        await search(model, for: "SRR27069570")

        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(
            model.errorMessage,
            "Search failed: ENA returned HTTP 500 (server error), and NCBI returned HTTP 500 (server error)."
        )
    }

    func testAccessionListSearchShowsNCBIRecordsWhenENAFails() async throws {
        let client = ArchiveOutageHTTPClient()
        await client.register("portal/api/filereport", status: 500, body: Self.enaOutagePage)
        await client.register("efetch.fcgi", status: 200, body: Self.runInfoCSV(["SRR27069570", "SRR27069571"]))
        let model = makeModel(client)

        await search(model, for: "SRR27069570, SRR27069571")

        XCTAssertEqual(model.results.map(\.accession), ["SRR27069570", "SRR27069571"])
        XCTAssertEqual(model.errorMessage, "ENA returned HTTP 500 (server error). Results from NCBI are shown.")
    }

    func testAccessionListSearchShowsENARecordsWhenNCBIFails() async throws {
        let client = ArchiveOutageHTTPClient()
        await client.register("accession=SRR27069570", status: 200, body: Self.enaRecordsJSON(["SRR27069570"]))
        await client.register("accession=SRR27069571", status: 200, body: Self.enaRecordsJSON(["SRR27069571"]))
        await client.register("efetch.fcgi", status: 500, body: Self.enaOutagePage)
        let model = makeModel(client)

        await search(model, for: "SRR27069570, SRR27069571")

        XCTAssertEqual(model.results.map(\.accession), ["SRR27069570", "SRR27069571"])
        XCTAssertEqual(model.errorMessage, "NCBI returned HTTP 500 (server error). Results from ENA are shown.")
    }

    func testProjectSearchShowsNCBIRecordsAndSaysENAFailed() async throws {
        let client = ArchiveOutageHTTPClient()
        await client.register(
            "esearch.fcgi",
            status: 200,
            body: #"{"esearchresult":{"count":"1","retmax":"1","retstart":"0","idlist":["31234567"]}}"#
        )
        await client.register("efetch.fcgi", status: 200, body: Self.runInfoCSV(["SRR27069570"]))
        await client.register("portal/api/filereport", status: 500, body: Self.enaOutagePage)
        let model = makeModel(client)

        await search(model, for: "PRJNA1047265")

        XCTAssertEqual(model.results.map(\.accession), ["SRR27069570"])
        XCTAssertEqual(model.errorMessage, "ENA returned HTTP 500 (server error). Results from NCBI are shown.")
    }

    func testSearchWithBothArchivesAnsweringShowsNoNotice() async throws {
        let client = ArchiveOutageHTTPClient()
        await client.register("portal/api/filereport", status: 200, body: Self.enaRecordsJSON(["SRR27069570"]))
        await client.register("efetch.fcgi", status: 200, body: Self.runInfoCSV(["SRR27069570"]))
        let model = makeModel(client)

        await search(model, for: "SRR27069570")

        XCTAssertEqual(model.results.map(\.accession), ["SRR27069570"])
        XCTAssertEqual(model.results.first?.title, "Exome of a human donor")
        XCTAssertEqual(model.results.first?.organism, "Homo sapiens")
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - Helpers

    private func makeModel(_ client: ArchiveOutageHTTPClient) -> DatabaseBrowserViewModel {
        let model = DatabaseBrowserViewModel(
            source: .ena,
            ncbiService: NCBIService(httpClient: client, environment: [:]),
            enaService: ENAService(httpClient: client)
        )
        model.clearSearchHistory()
        return model
    }

    private func search(_ model: DatabaseBrowserViewModel, for text: String) async {
        model.searchText = text
        model.performSearch()
        XCTAssertTrue(model.isSearching, "performSearch should start a search")
        await waitUntil(timeout: .seconds(30)) { !model.isSearching }
        XCTAssertFalse(model.isSearching, "the search did not finish")
    }

    /// The page ENA's portal API served for every request during the outage,
    /// shortened.
    static let enaOutagePage = """
    <!doctype html>
    <html lang="en">
    <head><meta charset="utf-8"><title>500 Internal Server Error</title></head>
    <body>
    <h1>Internal Server Error</h1>
    <p>The server encountered an internal error and was unable to complete your request.</p>
    </body>
    </html>
    """

    static func runInfoCSV(_ accessions: [String]) -> String {
        let header = "Run,ReleaseDate,LoadDate,spots,bases,spots_with_mates,avgLength,size_MB,AssemblyName,download_path,Experiment,LibraryName,LibraryStrategy,LibrarySelection,LibrarySource,LibraryLayout,InsertSize,InsertDev,Platform,Model,SRAStudy,BioProject,Study_Pubmed_id,ProjectID,Sample,BioSample,SampleType,TaxID,ScientificName,SampleName"
        let rows = accessions.map { accession in
            "\(accession),2023-12-01 10:00:00,2023-12-01 09:00:00,10000,3000000,10000,300,2,,https://example.invalid/\(accession).sra,SRX22663300,exome,WXS,Hybrid Selection,GENOMIC,PAIRED,0,0,ILLUMINA,Illumina NovaSeq 6000,SRP475000,PRJNA1047265,,1047265,SRS19700000,SAMN38500000,simple,9606,Homo sapiens,donor-1"
        }
        return ([header] + rows).joined(separator: "\n")
    }

    static func enaRecordsJSON(_ accessions: [String]) -> String {
        let records = accessions.map { accession in
            """
            {"run_accession":"\(accession)","experiment_title":"Exome of a human donor","library_layout":"PAIRED",\
            "library_strategy":"WXS","instrument_platform":"ILLUMINA","base_count":"3000000","read_count":"10000",\
            "fastq_ftp":"ftp.sra.ebi.ac.uk/vol1/fastq/SRR270/070/\(accession)/\(accession)_1.fastq.gz;ftp.sra.ebi.ac.uk/vol1/fastq/SRR270/070/\(accession)/\(accession)_2.fastq.gz",\
            "fastq_bytes":"1000;1000","first_public":"2023-12-01"}
            """
        }
        return "[" + records.joined(separator: ",") + "]"
    }
}

/// Answers each request with the first registered response whose pattern
/// the URL contains, and fails any other request as an unreachable host.
private actor ArchiveOutageHTTPClient: HTTPClient {
    private var responses: [(pattern: String, status: Int, body: String)] = []

    func register(_ pattern: String, status: Int, body: String) {
        responses.append((pattern, status, body))
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        guard let match = responses.first(where: { url.absoluteString.contains($0.pattern) }) else {
            throw URLError(.cannotFindHost)
        }
        let response = HTTPURLResponse(url: url, statusCode: match.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(match.body.utf8), response)
    }
}
