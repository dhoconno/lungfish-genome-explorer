// NCBIServiceEndpointsTests.swift - The stand-in origin a debug build of NCBIService accepts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore
import LungfishTestSupport

/// Review ruling Q2a of Phase 2.10 lane A44, term 7. With no variable the service keeps NCBI's
/// hosts, a value that is not a loopback origin reaches no NCBI host, and a stand-in gets no key
/// whatever `NCBI_API_KEY` holds. Every request goes to a recording client or a loopback stand-in,
/// so no test reaches the network.
final class NCBIServiceEndpointsTests: XCTestCase {
    private static let notAKey = "lge-test-not-a-key"
    private static let esearchAnswer = #"{"esearchresult":{"count":"1","retmax":"1","retstart":"0","idlist":["9900001"]}}"#

    func testNoVariableKeepsTodaysNCBIHostsAndKey() async {
        XCTAssertEqual(NCBIServiceEndpoints(environment: [:]), .ncbi)
        XCTAssertEqual(NCBIServiceEndpoints(environment: [NCBIServiceEndpoints.standInOriginVariable: ""]), .ncbi)
        let service = NCBIService(apiKey: nil, environment: ["NCBI_API_KEY": Self.notAKey])
        XCTAssertEqual(service.baseURL.absoluteString, "https://eutils.ncbi.nlm.nih.gov/entrez/eutils/")
        let key = await service.resolvedAPIKey
        XCTAssertEqual(key, Self.notAKey, "with no stand-in the environment key still applies")
    }

    func testLoopbackOriginsAreAccepted() {
        XCTAssertEqual(NCBIServiceEndpoints.loopbackOrigin("http://127.0.0.1:8080"), "http://127.0.0.1:8080")
        XCTAssertEqual(NCBIServiceEndpoints.loopbackOrigin("http://[::1]:9"), "http://[::1]:9")
        let endpoints = NCBIServiceEndpoints(environment: [NCBIServiceEndpoints.standInOriginVariable: "http://127.0.0.1:8080"])
        XCTAssertTrue(endpoints.isStandIn)
        XCTAssertEqual(endpoints.eutilsBase.absoluteString, "http://127.0.0.1:8080/entrez/eutils/")
        XCTAssertEqual(endpoints.datasetsOrigin, "http://127.0.0.1:8080")
    }

    func testAValueThatIsNotALoopbackOriginReachesNoNCBIHost() async throws {
        let refused = [
            "https://eutils.ncbi.nlm.nih.gov", "https://api.ncbi.nlm.nih.gov:443", "http://example.com:80",
            "http://localhost:8080", "http://127.0.0.1", "http://127.0.0.1:8080/", "http://127.0.0.1:8080/entrez",
            "http://user@127.0.0.1:8080", "http://127.0.0.1:8080?db=nuccore", "http://127.0.0.1:8080#top",
            "https://127.0.0.1:8080", "127.0.0.1:8080", "http://10.0.0.1:8080",
        ]
        for value in refused {
            XCTAssertNil(NCBIServiceEndpoints.loopbackOrigin(value), value)
            let client = RecordingHTTPClient(answer: Self.esearchAnswer)
            let service = NCBIService(
                apiKey: Self.notAKey, httpClient: client,
                environment: [NCBIServiceEndpoints.standInOriginVariable: value, "NCBI_API_KEY": Self.notAKey],
                retryPolicy: NCBIRetryPolicy(enabled: false, maxRetries: 0, initialBackoffSeconds: 0, maxBackoffSeconds: 0))
            _ = try? await service.searchGenome(term: "GCF_000000001.1", retmax: 1)
            _ = try? await service.searchVirusDatasets(taxon: "11320")
            let urls = await client.urls
            XCTAssertEqual(urls.count, 2, value)
            for url in urls {
                XCTAssertEqual(url.host, "127.0.0.1", "\(value) sent \(url)")
                XCTAssertEqual(url.port, 0, "\(value) sent \(url)")
                XCTAssertFalse(url.absoluteString.contains("api_key"), "\(value) sent a key")
            }
            let key = await service.resolvedAPIKey
            XCTAssertNil(key, value)
        }
    }

    func testAStandInGetsNoKeyWhateverTheEnvironmentHolds() async throws {
        let server = try LoopbackHTTPStandIn.start { _ in .text(Self.esearchAnswer) }
        defer { server.stop() }
        let environment = [
            NCBIServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString, "NCBI_API_KEY": Self.notAKey,
        ]
        for explicitKey in [nil, Self.notAKey] {
            let service = NCBIService(apiKey: explicitKey, environment: environment)
            XCTAssertEqual(service.baseURL.absoluteString, server.baseURL.absoluteString + "/entrez/eutils/")
            let result = try await service.searchGenome(term: "GCF_000000001.1", retmax: 1)
            XCTAssertEqual(result.ids, ["9900001"])
            let key = await service.resolvedAPIKey
            XCTAssertNil(key)
        }
        let requests = server.requests
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.path, "/entrez/eutils/esearch.fcgi")
            let bytes = ([request.method, request.target] + request.headerLines).joined(separator: "\n")
                + String(decoding: request.body, as: UTF8.self)
            XCTAssertFalse(bytes.contains("api_key"), NCBIAPIKeyResolver.redactSecrets(in: bytes))
            XCTAssertFalse(bytes.contains(Self.notAKey), "the stand-in received the key")
        }
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
