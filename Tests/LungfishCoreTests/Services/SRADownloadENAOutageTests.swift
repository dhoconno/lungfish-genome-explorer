// SRADownloadENAOutageTests.swift - fetch sra download takes the SRA Toolkit route when ENA cannot serve a run
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore

/// `lungfish-cli fetch sra download` runs `downloadFASTQWithFallback`. When
/// ENA's portal fails or lists no FASTQ files, the run has no FASTQ links,
/// so it takes the SRA Toolkit route at once, as the window's download does,
/// instead of guessing file paths on ENA's mirror. A guessed path carries no
/// advertised size, so a mirror missing one mate could hand over half a
/// pair. The archive is a mock HTTP client and the toolkit is a stub.
final class SRADownloadENAOutageTests: XCTestCase {

    func testDownloadWithFallbackTakesToolkitRouteWhenPortalFails() async throws {
        let client = OutageMirrorHTTPClient(portalStatus: 500, portalBody: ENAOutageFixture.page)
        let toolkitCalls = CallCounter()
        let service = SRAService(
            ncbiService: NCBIService(httpClient: client, environment: [:]),
            httpClient: client,
            toolkitDownloader: { accession, _ in
                toolkitCalls.increment()
                return [
                    URL(fileURLWithPath: "/tmp/\(accession)_1.fastq"),
                    URL(fileURLWithPath: "/tmp/\(accession)_2.fastq"),
                ]
            }
        )
        let outputDirectory = try Self.makeOutputDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let urls = try await service.downloadFASTQWithFallback(accession: "SRR27069570", outputDir: outputDirectory)

        XCTAssertEqual(toolkitCalls.value, 1)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["SRR27069570_1.fastq", "SRR27069570_2.fastq"])
        let mirrorRequests = await client.downloadRequestURLs
        XCTAssertEqual(mirrorRequests, [], "no file may be fetched from a guessed ENA path")
    }

    func testDownloadWithFallbackTakesToolkitRouteWhenENAListsNoFASTQFiles() async throws {
        let record = #"[{"run_accession":"SRR27069570","library_layout":"PAIRED","fastq_ftp":"","fastq_bytes":""}]"#
        let client = OutageMirrorHTTPClient(portalStatus: 200, portalBody: record)
        let toolkitCalls = CallCounter()
        let service = SRAService(
            ncbiService: NCBIService(httpClient: client, environment: [:]),
            httpClient: client,
            toolkitDownloader: { accession, _ in
                toolkitCalls.increment()
                return [URL(fileURLWithPath: "/tmp/\(accession)_1.fastq")]
            }
        )
        let outputDirectory = try Self.makeOutputDirectory()
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        _ = try await service.downloadFASTQWithFallback(accession: "SRR27069570", outputDir: outputDirectory)

        XCTAssertEqual(toolkitCalls.value, 1)
        let mirrorRequests = await client.downloadRequestURLs
        XCTAssertEqual(mirrorRequests, [], "no file may be fetched from a guessed ENA path")
    }

    private static func makeOutputDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sra-ena-outage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Answers ENA's portal with a fixed status and body, and answers every file
/// download with HTTP 404 while recording its URL.
private actor OutageMirrorHTTPClient: HTTPClient {
    let portalStatus: Int
    let portalBody: String
    private(set) var downloadRequestURLs: [URL] = []

    init(portalStatus: Int, portalBody: String) {
        self.portalStatus = portalStatus
        self.portalBody = portalBody
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        guard url.absoluteString.contains("portal/api/filereport") else {
            throw URLError(.cannotFindHost)
        }
        return (Data(portalBody.utf8), Self.response(url, portalStatus))
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        downloadRequestURLs.append(url)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sra-ena-outage-download-\(UUID().uuidString)")
        try Data("Not Found".utf8).write(to: temporaryURL, options: .atomic)
        return (temporaryURL, Self.response(url, 404))
    }

    private static func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
