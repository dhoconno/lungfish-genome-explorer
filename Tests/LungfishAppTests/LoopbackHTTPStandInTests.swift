// LoopbackHTTPStandInTests.swift - The loopback stand-in server answers and records requests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishTestSupport

/// Pins the stand-in server that download pins and parity tests read their recorded responses
/// from (Phase 2.10 G5): loopback only, an ephemeral port, one answer per connection and every
/// request kept in order.
final class LoopbackHTTPStandInTests: XCTestCase {

    func testAnswersHeadAndGetOnLoopbackAndKeepsEachRequestInOrder() async throws {
        let body = Data(">chr1\nACGT\n".utf8)
        let server = try LoopbackHTTPStandIn.start(routes: [
            "/genomes/a.fna": LoopbackHTTPResponse(body: body),
        ])
        defer { server.stop() }
        XCTAssertEqual(server.baseURL.host, "127.0.0.1")
        XCTAssertNotEqual(server.port, 0)

        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        var head = URLRequest(url: server.url("/genomes/a.fna"), timeoutInterval: 30)
        head.httpMethod = "HEAD"
        let (headData, headResponse) = try await session.data(for: head)
        XCTAssertEqual((headResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(headResponse.expectedContentLength, Int64(body.count))
        XCTAssertTrue(headData.isEmpty)

        let get = URLRequest(url: server.url("/genomes/a.fna?db=nuccore&id=x"), timeoutInterval: 30)
        let (getData, getResponse) = try await session.data(for: get)
        XCTAssertEqual((getResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(getData, body)

        let missing = URLRequest(url: server.url("/genomes/missing.fna"), timeoutInterval: 30)
        let (_, missingResponse) = try await session.data(for: missing)
        XCTAssertEqual((missingResponse as? HTTPURLResponse)?.statusCode, 404)

        let requests = server.requests
        XCTAssertEqual(requests.map(\.method), ["HEAD", "GET", "GET"])
        XCTAssertEqual(requests.map(\.path), ["/genomes/a.fna", "/genomes/a.fna", "/genomes/missing.fna"])
        XCTAssertEqual(requests[1].queryItems, [
            URLQueryItem(name: "db", value: "nuccore"), URLQueryItem(name: "id", value: "x"),
        ])
        XCTAssertTrue(requests[1].headerLines.contains { $0.lowercased().hasPrefix("host: 127.0.0.1:") })
    }

    func testResponderSeesTheQueryAndAStoppedServerRefusesConnections() async throws {
        let server = try LoopbackHTTPStandIn.start { request in
            .text(request.queryItems.map { "\($0.name)=\($0.value ?? "")" }.joined(separator: "&"))
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: server.url("/efetch.fcgi?rettype=gb&retmode=text"), timeoutInterval: 30)
        let (data, _) = try await session.data(for: request)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "rettype=gb&retmode=text")

        server.stop()
        let afterStop = URLRequest(url: server.url("/efetch.fcgi"), timeoutInterval: 5)
        do {
            _ = try await session.data(for: afterStop)
            XCTFail("A stopped stand-in answered a request")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost, "\(error)")
        }
    }
}
