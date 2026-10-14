// PathoplexusServiceEndpointsTests.swift - The stand-in origin a debug build of PathoplexusService accepts
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore
import LungfishTestSupport

/// Lane A45 M2, the manager's grant 2, on the terms of review ruling Q2a of lane A44 as they apply to
/// Pathoplexus, which takes no API key. With no variable the service keeps the Pathoplexus hosts, and
/// a value that is not a loopback origin reaches no Pathoplexus host. A loopback stand-in gets every
/// request the service sends. Every request goes to a recording client or a loopback stand-in, so no
/// test reaches the network.
final class PathoplexusServiceEndpointsTests: XCTestCase {
    private static let detailsAnswer = #"{"data":[],"info":{}}"#

    func testNoVariableKeepsTodaysPathoplexusHosts() {
        XCTAssertEqual(PathoplexusServiceEndpoints(environment: [:]), .pathoplexus)
        XCTAssertEqual(
            PathoplexusServiceEndpoints(environment: [PathoplexusServiceEndpoints.standInOriginVariable: ""]), .pathoplexus)
        let service = PathoplexusService(httpClient: RecordingHTTPClient(answer: Self.detailsAnswer), environment: [:])
        XCTAssertEqual(service.baseURL.absoluteString, "https://lapis.pathoplexus.org/")
        XCTAssertEqual(service.backendURL.absoluteString, "https://backend.pathoplexus.org/")
        XCTAssertEqual(service.authURL.absoluteString, "https://authentication.pathoplexus.org/")
    }

    func testALoopbackOriginMovesTheThreeBases() {
        let endpoints = PathoplexusServiceEndpoints(
            environment: [PathoplexusServiceEndpoints.standInOriginVariable: "http://127.0.0.1:8080"])
        XCTAssertTrue(endpoints.isStandIn)
        for url in [endpoints.baseURL, endpoints.backendURL, endpoints.authURL] {
            XCTAssertEqual(url.absoluteString, "http://127.0.0.1:8080/")
        }
    }

    func testAValueThatIsNotALoopbackOriginReachesNoPathoplexusHost() async throws {
        let refused = [
            "https://lapis.pathoplexus.org", "https://backend.pathoplexus.org:443", "http://example.com:80",
            "http://localhost:8080", "http://127.0.0.1", "http://127.0.0.1:8080/", "http://127.0.0.1:8080/lapis",
            "http://user@127.0.0.1:8080", "http://127.0.0.1:8080?x=1", "http://127.0.0.1:8080#top",
            "https://127.0.0.1:8080", "127.0.0.1:8080", "http://10.0.0.1:8080",
        ]
        for value in refused {
            let client = RecordingHTTPClient(answer: Self.detailsAnswer)
            let service = PathoplexusService(
                httpClient: client, environment: [PathoplexusServiceEndpoints.standInOriginVariable: value])
            _ = try? await service.fetchMetadataForAccession(organism: "ebola-zaire", accession: "PP_1")
            let urls = await client.urls
            XCTAssertFalse(urls.isEmpty, value)
            for url in urls {
                XCTAssertEqual(url.host, "127.0.0.1", "\(value) sent \(url)")
                XCTAssertEqual(url.port, 0, "\(value) sent \(url)")
            }
        }
    }

    func testALoopbackStandInGetsTheRequests() async throws {
        let server = try LoopbackHTTPStandIn.start { _ in .text(Self.detailsAnswer) }
        defer { server.stop() }
        let service = PathoplexusService(
            environment: [PathoplexusServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString])
        XCTAssertEqual(service.baseURL.absoluteString, server.baseURL.absoluteString + "/")
        let metadata = try await service.fetchMetadataForAccession(organism: "ebola-zaire", accession: "PP_1")
        XCTAssertNil(metadata, "the stand-in holds no record")
        let requests = server.requests
        XCTAssertFalse(requests.isEmpty)
        XCTAssertTrue(requests.allSatisfy { $0.path.hasPrefix("/ebola-zaire/") }, "\(requests.map(\.target))")
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
