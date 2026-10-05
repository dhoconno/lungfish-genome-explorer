// SRAFASTQDownloadSourceTests.swift - fetch sra download names its source as the window's download does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore

/// After any ENA failure but a cancellation, `lungfish-cli fetch sra download`
/// and the window's SRA download fetch the run with the SRA Toolkit, and both
/// name why with `SRAFASTQDownloadSource.toolkitFallback(after:)`. The CLI
/// records the name under `downloadSource`, as the window's import does. The
/// window's side is in SRAWindowRunDownloadTests. The archive is a mock HTTP
/// client and the toolkit is a stub.
final class SRAFASTQDownloadSourceTests: XCTestCase {

    func testToolkitFallbackNamesHowTheENADownloadFailed() {
        XCTAssertEqual(
            SRAFASTQDownloadSource.toolkitFallback(after: URLError(.networkConnectionLost)),
            .sraToolkitAfterFailedTransfer
        )
        XCTAssertEqual(
            SRAFASTQDownloadSource.toolkitFallback(
                after: DatabaseServiceError.serverError(message: "HTTP 500 downloading SRR27069570_2.fastq.gz")
            ),
            .sraToolkitAfterFailedTransfer
        )
        XCTAssertEqual(
            SRAFASTQDownloadSource.toolkitFallback(
                after: ENAFASTQDownloadValidator.Failure.htmlBody(filename: "SRR27069570_2.fastq.gz")
            ),
            .sraToolkitAfterIncompleteMirror
        )
        XCTAssertEqual(
            SRAFASTQDownloadSource.toolkitFallback(
                after: ENAFASTQDownloadFailure(fallbackSource: .sraToolkit, message: "ENA has no record of SRR27069570")
            ),
            .sraToolkit
        )
        XCTAssertNil(SRAFASTQDownloadSource.toolkitFallback(after: CancellationError()))
        XCTAssertNil(SRAFASTQDownloadSource.toolkitFallback(after: URLError(.cancelled)))
        XCTAssertNil(SRAFASTQDownloadSource.toolkitFallback(after: DatabaseServiceError.cancelled))
    }

    func testEverySRAToolkitSourceUsesTheSRAToolsEnvironment() {
        XCTAssertEqual(
            SRAFASTQDownloadSource.allCases.filter(\.usesSRAToolkit).map(\.rawValue),
            ["SRA Toolkit", "SRA Toolkit (ENA mirror incomplete)", "SRA Toolkit (ENA transfer failed)"]
        )
        XCTAssertFalse(SRAFASTQDownloadSource.ena.usesSRAToolkit)
    }

    func testCLIDownloadRecordsAFailedTransferWhenTheMirrorAnswersAnHTTPError() async throws {
        let sources = try await Self.recordedSources(mirror: { url in
            url.lastPathComponent.hasSuffix("_2.fastq.gz") ? .status(500) : .gzip
        })
        XCTAssertEqual(sources.downloadSources, [.sraToolkitAfterFailedTransfer])
        XCTAssertEqual(sources.toolkitCalls, 1)
    }

    func testCLIDownloadRecordsAFailedTransferWhenTheConnectionDrops() async throws {
        let sources = try await Self.recordedSources(mirror: { url in
            url.lastPathComponent.hasSuffix("_2.fastq.gz") ? .dropConnection : .gzip
        })
        XCTAssertEqual(sources.downloadSources, [.sraToolkitAfterFailedTransfer])
        XCTAssertEqual(sources.toolkitCalls, 1)
    }

    func testCLIDownloadRecordsAnIncompleteMirrorWhenAFileFailsTheCheck() async throws {
        let sources = try await Self.recordedSources(mirror: { url in
            url.lastPathComponent.hasSuffix("_2.fastq.gz") ? .htmlListing : .gzip
        })
        XCTAssertEqual(sources.downloadSources, [.sraToolkitAfterIncompleteMirror])
        XCTAssertEqual(sources.toolkitCalls, 1)
    }

    func testCLIDownloadNamesTheFirstFailureWhenTwoFilesFail() async throws {
        let sources = try await Self.recordedSources(mirror: { url in
            url.lastPathComponent.hasSuffix("_1.fastq.gz") ? .dropConnection : .htmlListing
        })
        XCTAssertEqual(sources.downloadSources, [.sraToolkitAfterFailedTransfer])
        XCTAssertEqual(sources.toolkitCalls, 1)
    }

    func testCLIDownloadRecordsENAWhenTheMirrorServesEveryFile() async throws {
        let sources = try await Self.recordedSources(mirror: { _ in .gzip })
        XCTAssertEqual(sources.downloadSources, [.ena])
        XCTAssertEqual(sources.toolkitCalls, 0)
    }

    func testCLIDownloadRecordsSRAToolkitWhenENAFails() async throws {
        let sources = try await Self.recordedSources(portalStatus: 500, mirror: { _ in .gzip })
        XCTAssertEqual(sources.downloadSources, [.sraToolkit])
        XCTAssertEqual(sources.toolkitCalls, 1)
    }

    // MARK: - Helpers

    private struct RecordedSources {
        let downloadSources: [SRAFASTQDownloadSource]
        let toolkitCalls: Int
    }

    private static func recordedSources(
        portalStatus: Int = 200,
        mirror: @escaping @Sendable (URL) -> MirrorAnswer
    ) async throws -> RecordedSources {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sra-download-source-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let client = ScriptedMirrorHTTPClient(portalStatus: portalStatus, mirror: mirror)
        let toolkitCalls = SourceRecorder<Int>()
        let service = SRAService(
            ncbiService: NCBIService(httpClient: client, environment: [:]),
            httpClient: client,
            toolkitDownloader: { accession, _ in
                toolkitCalls.append(1)
                return [URL(fileURLWithPath: "/tmp/\(accession)_1.fastq"), URL(fileURLWithPath: "/tmp/\(accession)_2.fastq")]
            }
        )
        let sources = SourceRecorder<SRAFASTQDownloadSource>()
        _ = try await service.downloadFASTQWithFallback(
            accession: "SRR27069570",
            outputDir: outputDirectory,
            onSource: { sources.append($0) }
        )
        return RecordedSources(downloadSources: sources.values, toolkitCalls: toolkitCalls.values.count)
    }
}

private enum MirrorAnswer: Sendable {
    case gzip
    case htmlListing
    case status(Int)
    case dropConnection
}

/// Lists a paired run on ENA's portal, with the size of the gzip fixture for
/// each mate, and answers each mirror download as the test scripts it.
private actor ScriptedMirrorHTTPClient: HTTPClient {
    let portalStatus: Int
    let mirror: @Sendable (URL) -> MirrorAnswer

    init(portalStatus: Int, mirror: @escaping @Sendable (URL) -> MirrorAnswer) {
        self.portalStatus = portalStatus
        self.mirror = mirror
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        guard portalStatus == 200 else {
            return (Data(ENAOutageFixture.page.utf8), Self.response(url, portalStatus))
        }
        let size = ENAFASTQDownloadValidatorTests.gzipFixture.count
        let payload: [[String: Any]] = [[
            "run_accession": "SRR27069570",
            "library_layout": "PAIRED",
            "fastq_ftp": [
                "ftp.sra.ebi.ac.uk/vol1/fastq/SRR270/070/SRR27069570/SRR27069570_1.fastq.gz",
                "ftp.sra.ebi.ac.uk/vol1/fastq/SRR270/070/SRR27069570/SRR27069570_2.fastq.gz",
            ].joined(separator: ";"),
            "fastq_bytes": "\(size);\(size)",
        ]]
        return (try JSONSerialization.data(withJSONObject: payload), Self.response(url, 200))
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sra-download-source-file-\(UUID().uuidString)")
        switch mirror(url) {
        case .gzip:
            try ENAFASTQDownloadValidatorTests.gzipFixture.write(to: temporaryURL, options: .atomic)
            return (temporaryURL, Self.response(url, 200))
        case .htmlListing:
            try Data("<html><head><title>Index of /vol1/fastq</title></head></html>".utf8)
                .write(to: temporaryURL, options: .atomic)
            return (temporaryURL, Self.response(url, 200))
        case .status(let status):
            try Data("Internal Server Error".utf8).write(to: temporaryURL, options: .atomic)
            return (temporaryURL, Self.response(url, status))
        case .dropConnection:
            throw URLError(.networkConnectionLost)
        }
    }

    private static func response(_ url: URL, _ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}

private final class SourceRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    var values: [Value] { lock.withLock { stored } }
    func append(_ value: Value) { lock.withLock { stored.append(value) } }
}
