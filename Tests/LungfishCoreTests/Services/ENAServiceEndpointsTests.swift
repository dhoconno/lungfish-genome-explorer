// ENAServiceEndpointsTests.swift - The stand-in origin a debug build of ENAService accepts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore
import LungfishTestSupport

/// Lane A45 M3c, the manager's grant for `ENAService.swift`, on the seven terms of review ruling Q2a of
/// lane A44 as they apply to ENA, which takes no API key. With no variable the service keeps the ENA
/// hosts and the mirror host each record names. A value that is not a loopback origin reaches no ENA
/// host, the mirror included. A loopback stand-in gets every request the service sends and every file
/// the run's record names. No record a server decodes can set the mirror origin. Every request goes to
/// a recording client or a loopback stand-in, so no test reaches the network.
final class ENAServiceEndpointsTests: XCTestCase {
    private static let accession = "SRR123456"
    private static let mirrorPath = "vol1/fastq/SRR123/SRR123456/SRR123456.fastq.gz"

    /// The portal's answer for one single-end run whose file lives on ENA's mirror host.
    private static let portalAnswer = """
        [{"run_accession":"SRR123456","library_layout":"SINGLE","instrument_platform":"ILLUMINA",\
        "fastq_ftp":"ftp.sra.ebi.ac.uk/\(mirrorPath)","fastq_bytes":"4","fastq_md5":"d41d8cd98f00b204e9800998ecf8427e"}]
        """

    func testNoVariableKeepsTodaysENAHosts() async throws {
        XCTAssertEqual(ENAServiceEndpoints(environment: [:]), .ena)
        XCTAssertEqual(ENAServiceEndpoints(environment: [ENAServiceEndpoints.standInOriginVariable: ""]), .ena)
        let client = RecordingHTTPClient(answer: Self.portalAnswer)
        let service = ENAService(httpClient: client, environment: [:])
        XCTAssertEqual(service.baseURL.absoluteString, "https://www.ebi.ac.uk/ena/browser/api/")
        let records = try await service.searchReads(term: Self.accession, limit: 1)
        let urls = await client.urls
        XCTAssertEqual(urls.map(\.host), ["www.ebi.ac.uk"])
        XCTAssertEqual(urls.map(\.path), ["/ena/portal/api/filereport"])
        XCTAssertEqual(
            records.first?.fastqHTTPURLs.map(\.absoluteString), ["https://ftp.sra.ebi.ac.uk/" + Self.mirrorPath],
            "the mirror host is the one the record names")
    }

    func testALoopbackOriginMovesBothBasesAndTheMirror() {
        let endpoints = ENAServiceEndpoints(
            environment: [ENAServiceEndpoints.standInOriginVariable: "http://127.0.0.1:8080"])
        XCTAssertTrue(endpoints.isStandIn)
        XCTAssertEqual(endpoints.browserBase.absoluteString, "http://127.0.0.1:8080/ena/browser/api/")
        XCTAssertEqual(endpoints.portalBase.absoluteString, "http://127.0.0.1:8080/ena/portal/api/")
        XCTAssertEqual(endpoints.mirrorOrigin, "http://127.0.0.1:8080")
        let v6 = ENAServiceEndpoints(environment: [ENAServiceEndpoints.standInOriginVariable: "http://[::1]:9090"])
        XCTAssertEqual(v6.portalBase.absoluteString, "http://[::1]:9090/ena/portal/api/")
    }

    func testAValueThatIsNotALoopbackOriginReachesNoENAHost() async throws {
        let refused = [
            "https://www.ebi.ac.uk", "https://ftp.sra.ebi.ac.uk:443", "http://example.com:80",
            "http://localhost:8080", "http://127.0.0.1", "http://127.0.0.1:8080/", "http://127.0.0.1:8080/ena",
            "http://user@127.0.0.1:8080", "http://127.0.0.1:8080?x=1", "http://127.0.0.1:8080#top",
            "https://127.0.0.1:8080", "127.0.0.1:8080", "http://10.0.0.1:8080",
        ]
        for value in refused {
            let client = RecordingHTTPClient(answer: Self.portalAnswer)
            let service = ENAService(httpClient: client, environment: [ENAServiceEndpoints.standInOriginVariable: value])
            XCTAssertEqual(service.baseURL.host, "127.0.0.1", value)
            let records = try await service.searchReads(term: Self.accession, limit: 1)
            _ = try? await service.searchReadsByStudy(study: "PRJNA1", limit: 1)
            let urls = await client.urls
            XCTAssertEqual(urls.count, 2, value)
            let mirror = records.first?.fastqHTTPURLs ?? []
            XCTAssertEqual(mirror.count, 1, value)
            for url in urls + mirror {
                XCTAssertEqual(url.host, "127.0.0.1", "\(value) sent \(url)")
                XCTAssertEqual(url.port, 0, "\(value) sent \(url)")
            }
        }
    }

    func testALoopbackStandInGetsTheRequestsAndTheMirrorFiles() async throws {
        let server = try LoopbackHTTPStandIn.start { request in
            switch request.path {
            case "/ena/portal/api/filereport": .text(Self.portalAnswer)
            case "/" + Self.mirrorPath: LoopbackHTTPResponse(body: Data("ACGT".utf8))
            default: .notFound
            }
        }
        defer { server.stop() }
        let service = ENAService(environment: [ENAServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString])
        let route = try await service.fastqDownloadRoute(forRun: Self.accession)
        guard case .enaMirror(let record) = route else {
            return XCTFail("the stand-in's portal answer names the run's file, so the route is the mirror: \(route)")
        }
        XCTAssertEqual(record.fastqHTTPURLs.map(\.absoluteString), [server.baseURL.absoluteString + "/" + Self.mirrorPath])
        let (data, response) = try await URLSession.shared.data(from: try XCTUnwrap(record.fastqHTTPURLs.first))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "ACGT")
        XCTAssertEqual(server.requests.map(\.path), ["/ena/portal/api/filereport", "/" + Self.mirrorPath])
    }

    func testARecordAServerSentCannotNameTheMirror() throws {
        // A field of the portal's JSON, or of a stored sidecar, is data. Only a service bound to a
        // stand-in stamps its records, so neither a key of that name nor a host in a path moves a file.
        let json = """
            {"run_accession":"SRR1","mirrorOrigin":"http://127.0.0.1:1","mirror_origin":"http://127.0.0.1:1",\
            "fastq_ftp":"evil.example/vol1/a.fastq.gz;ftp.sra.ebi.ac.uk/vol1/b.fastq.gz"}
            """
        let record = try JSONDecoder().decode(ENAReadRecord.self, from: Data(json.utf8))
        XCTAssertNil(record.mirrorOrigin)
        XCTAssertEqual(
            record.fastqHTTPURLs.map(\.absoluteString),
            ["https://evil.example/vol1/a.fastq.gz", "https://ftp.sra.ebi.ac.uk/vol1/b.fastq.gz"])
        // A stamp is not part of the record a sidecar stores.
        var stamped = record
        stamped.mirrorOrigin = "http://127.0.0.1:1"
        let stored = try JSONEncoder().encode(stamped)
        XCTAssertFalse(String(decoding: stored, as: UTF8.self).contains("127.0.0.1"))
        XCTAssertNil(try JSONDecoder().decode(ENAReadRecord.self, from: stored).mirrorOrigin)
    }

    func testAStandInServesEveryListedFileWhateverHostItNames() throws {
        // With a stand-in bound, a listed host other than ENA's mirror never reaches the network.
        let json = #"{"run_accession":"SRR1","fastq_ftp":"evil.example/vol1/a.fastq.gz;ftp.sra.ebi.ac.uk/vol1/b.fastq.gz"}"#
        var record = try JSONDecoder().decode(ENAReadRecord.self, from: Data(json.utf8))
        record.mirrorOrigin = "http://127.0.0.1:8080"
        XCTAssertEqual(
            record.fastqHTTPURLs.map(\.absoluteString),
            ["http://127.0.0.1:8080/vol1/a.fastq.gz", "http://127.0.0.1:8080/vol1/b.fastq.gz"])
    }
}

/// Answers every request with one body and keeps each URL asked for, in order.
private actor RecordingHTTPClient: HTTPClient {
    private let answer: String
    private(set) var urls: [URL] = []

    init(answer: String) {
        self.answer = answer
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        urls.append(url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
        return (Data(answer.utf8), response)
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        throw URLError(.unsupportedURL)
    }
}
