// ENAErrorMessageTests.swift - ENA's HTTP errors read as one line without markup
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore

/// During the ENA outage of 2026-10-04 the SRA Runs search showed ENA's whole
/// HTML error page as its error. An HTTP error now reads as one line, and the
/// full body goes to the log. The archive is a mock HTTP client.
final class ENAErrorMessageTests: XCTestCase {

    func testHTMLServerErrorGivesOneLineWithoutMarkup() async throws {
        let client = MockHTTPClient()
        await client.register(pattern: "portal/api/filereport", response: .text(ENAOutageFixture.page, statusCode: 500))
        let service = ENAService(httpClient: client)

        do {
            _ = try await service.searchReads(term: "SRR27069570", limit: 1)
            XCTFail("Expected the HTTP 500 to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Server error: HTTP 500")
        }
    }

    func testLongPlainTextServerErrorKeepsOnlyItsFirstLineShortened() async throws {
        let firstLine = "Portal backend timed out " + String(repeating: "while reading the run index ", count: 20)
        let body = firstLine + "\n" + String(repeating: "stack frame\n", count: 200)
        let client = MockHTTPClient()
        await client.register(pattern: "portal/api/filereport", response: .text(body, statusCode: 503))
        let service = ENAService(httpClient: client)

        do {
            _ = try await service.searchReads(term: "SRR27069570", limit: 1)
            XCTFail("Expected the HTTP 503 to throw")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.hasPrefix("Server error: HTTP 503: Portal backend timed out"), message)
            XCTAssertFalse(message.contains("\n"), message)
            XCTAssertFalse(message.contains("stack frame"), message)
            XCTAssertLessThanOrEqual(message.count, 160, message)
        }
    }

    func testHTMLBadRequestGivesOneLineWithoutMarkup() async throws {
        let client = MockHTTPClient()
        await client.register(pattern: "portal/api/filereport", response: .text(ENAOutageFixture.page, statusCode: 400))
        let service = ENAService(httpClient: client)

        do {
            _ = try await service.searchReads(term: "SRR27069570", limit: 1)
            XCTFail("Expected the HTTP 400 to throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Invalid query: HTTP 400")
        }
    }

    // MARK: - ArchiveRequestFailure

    func testArchiveRequestFailureNamesTheArchiveAndTheStatus() {
        XCTAssertEqual(
            ArchiveRequestFailure(archive: "ENA", error: DatabaseServiceError.serverError(message: "HTTP 500")).message,
            "ENA returned HTTP 500 (server error)"
        )
        XCTAssertEqual(
            ArchiveRequestFailure(archive: "NCBI", error: DatabaseServiceError.serverError(message: "HTTP 503: Service Unavailable")).message,
            "NCBI returned HTTP 503 (server error)"
        )
        XCTAssertEqual(
            ArchiveRequestFailure(archive: "ENA", error: DatabaseServiceError.rateLimitExceeded).message,
            "ENA returned HTTP 429 (too many requests)"
        )
        XCTAssertEqual(
            ArchiveRequestFailure(archive: "ENA", error: DatabaseServiceError.invalidResponse(statusCode: 502)).message,
            "ENA returned HTTP 502 (server error)"
        )
        XCTAssertEqual(
            ArchiveRequestFailure(archive: "NCBI", error: DatabaseServiceError.serverError(message: "Search Backend failed")).message,
            "NCBI failed (Server error: Search Backend failed)"
        )
        XCTAssertTrue(
            ArchiveRequestFailure(archive: "ENA", error: URLError(.cannotFindHost)).message.hasPrefix("ENA could not be reached")
        )
        XCTAssertNil(DatabaseServiceError.serverError(message: "HTTP 503malformed").httpStatusCode)
    }

    func testArchiveRequestFailureOfAnHTMLErrorPageHasNoMarkup() async throws {
        let client = MockHTTPClient()
        await client.register(pattern: "portal/api/filereport", response: .text(ENAOutageFixture.page, statusCode: 500))

        do {
            _ = try await ENAService(httpClient: client).searchReads(term: "SRR27069570", limit: 1)
            XCTFail("Expected the HTTP 500 to throw")
        } catch {
            XCTAssertEqual(ArchiveRequestFailure(archive: "ENA", error: error).message, "ENA returned HTTP 500 (server error)")
        }
    }

    func testDisplayLineDropsMarkupAndKeepsOneShortLine() {
        XCTAssertEqual(ArchiveRequestFailure.displayLine(ENAOutageFixture.page), "")
        XCTAssertEqual(
            ArchiveRequestFailure.displayLine("Server error: HTTP 500: <!doctype html>\n<html>"),
            "Server error: HTTP 500"
        )
        XCTAssertEqual(ArchiveRequestFailure.displayLine("\nfirst line\nsecond line"), "first line")
        XCTAssertEqual(ArchiveRequestFailure.displayLine("depth < 10 at 3 sites"), "depth < 10 at 3 sites")
        let long = ArchiveRequestFailure.displayLine(String(repeating: "a", count: 300))
        XCTAssertEqual(long.count, 120)
        XCTAssertTrue(long.hasSuffix("…"), long)
    }
}
