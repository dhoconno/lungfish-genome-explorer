// SRAToolkitSplit3Tests.swift - The SRA Toolkit route writes a run's reads without a mate to their own file
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishCore

/// Owner decision of 2026-10-05: every SRA Toolkit download runs
/// `fasterq-dump --split-3`, which writes the mates of each spot to
/// `<run>_1.fastq` and `<run>_2.fastq` and every read without a mate to
/// `<run>.fastq`, the layout ENA serves. The toolkit is scripted with the
/// files sra-tools 3.4.1 wrote for two public runs, so no test spawns a tool
/// or reaches the network.
final class SRAToolkitSplit3Tests: XCTestCase {

    private var root: URL!
    private var recorded: SRAToolkitRecordedRunner!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "sra-toolkit-split-3")
        recorded = SRAToolkitRecordedRunner(testFile: #filePath)
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    func testFasterqDumpRunsWithSplit3AndNeverSplitFiles() async throws {
        let service = SRAService(toolkitRunner: recorded.runner)

        _ = try await service.downloadFASTQ(accession: SRAToolkitRecordedRunner.pairedRunWithSingletons, outputDir: root)

        let arguments = try XCTUnwrap(recorded.fasterqArguments.first)
        XCTAssertTrue(arguments.contains("--split-3"), "\(arguments)")
        XCTAssertFalse(arguments.contains("--split-files"), "\(arguments)")
    }

    func testFasterqDumpStepRecordsSplit3() async throws {
        let service = SRAService(toolkitRunner: recorded.runner)
        let steps = StepRecorder()

        _ = try await service.downloadFASTQ(
            accession: SRAToolkitRecordedRunner.pairedRunWithSingletons,
            outputDir: root,
            trace: { steps.record($0) }
        )

        let fasterq = try XCTUnwrap(steps.steps.first { $0.toolName == "fasterq-dump" })
        XCTAssertTrue(fasterq.command.contains("--split-3"), "\(fasterq.command)")
    }

    func testAPairedRunWithSingletonsReturnsBothMatesAndTheReadsWithoutAMate() async throws {
        let run = SRAToolkitRecordedRunner.pairedRunWithSingletons
        let service = SRAService(toolkitRunner: recorded.runner)

        let files = try await service.downloadFASTQ(accession: run, outputDir: root)

        XCTAssertEqual(files.map(\.lastPathComponent), ["\(run)_1.fastq", "\(run)_2.fastq", "\(run).fastq"])
        XCTAssertEqual(try files.map(Self.recordCount), [129, 129, 6])
    }

    func testASingleEndRunReturnsItsOneFile() async throws {
        let run = SRAToolkitRecordedRunner.singleEndRun
        let service = SRAService(toolkitRunner: recorded.runner)

        let files = try await service.downloadFASTQ(accession: run, outputDir: root)

        XCTAssertEqual(files.map(\.lastPathComponent), ["\(run).fastq"])
        XCTAssertEqual(try files.map(Self.recordCount), [53])
    }

    /// The fallback after ENA fails runs the same toolkit download.
    func testTheFallbackAfterAnENAOutageReturnsTheSingletonsFileToo() async throws {
        let run = SRAToolkitRecordedRunner.pairedRunWithSingletons
        let client = PortalOutageHTTPClient()
        let service = SRAService(
            ncbiService: NCBIService(httpClient: client, environment: [:]),
            httpClient: client,
            toolkitRunner: recorded.runner
        )
        let messages = MessageRecorder()

        let files = try await service.downloadFASTQWithFallback(
            accession: run,
            outputDir: root,
            onFallback: { messages.record($0) }
        )

        XCTAssertEqual(files.map(\.lastPathComponent), ["\(run)_1.fastq", "\(run)_2.fastq", "\(run).fastq"])
        XCTAssertTrue(recorded.fasterqArguments.first?.contains("--split-3") == true)
        // L1: the CLI says why it fell back.
        let message = try XCTUnwrap(messages.messages.first)
        XCTAssertTrue(message.contains("SRA Toolkit"), message)
        XCTAssertTrue(message.contains("ENA"), message)
        XCTAssertTrue(message.contains(run), "the message names the run and ENA's reason: \(message)")
    }

    private static func recordCount(_ url: URL) throws -> Int {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.isEmpty }.count / 4
    }
}

/// Answers ENA's portal with HTTP 500 and every other request with an error.
private struct PortalOutageHTTPClient: HTTPClient {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = request.url ?? URL(string: "https://example.invalid")!
        guard url.absoluteString.contains("portal/api") else {
            throw URLError(.cannotFindHost)
        }
        return (Data("Internal Server Error".utf8), HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!)
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        throw URLError(.cannotFindHost)
    }
}

private final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SRAService.FASTQDownloadStepTrace] = []
    var steps: [SRAService.FASTQDownloadStepTrace] { lock.withLock { recorded } }
    func record(_ step: SRAService.FASTQDownloadStepTrace) { lock.withLock { recorded.append(step) } }
}

private final class MessageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var messages: [String] { lock.withLock { recorded } }
    func record(_ message: String) { lock.withLock { recorded.append(message) } }
}
