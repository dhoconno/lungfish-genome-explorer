// BlastGzipStreamCancelTests.swift - A cancelled task stops the gzip behind BLAST's input streams
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
@testable import LungfishCore

/// The Kraken scan and the FASTQ extraction read `gzip -dc` as a stream. Cancelling the task that reads
/// must stop the child and end the read with `CancellationError`, as the rest of the verification does.
/// The tool is the real `/usr/bin/gzip`, and the fixtures are 32 MiB texts that compress to a few hundred
/// KB, which the service needs several seconds to read, so gzip is still writing into a full pipe when the
/// cancel comes.
final class BlastGzipStreamCancelTests: XCTestCase {
    private var tempDir: URL!
    private var service: BlastService!

    override func setUp() async throws {
        tempDir = try TestTempDirectory.make(prefix: "blast-gzip-stream-cancel")
        service = BlastService(httpClient: MockHTTPClient())
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(tempDir)
    }

    private func makeGzip(repeating line: String, named name: String, leading: String = "") async throws -> URL {
        let plain = tempDir.appendingPathComponent(name)
        let block = Data(String(repeating: line, count: 1_048_576 / line.utf8.count).utf8)
        try SystemToolProbe.writeRepeating(block, times: 32, leading: Data(leading.utf8), to: plain)
        let gz = tempDir.appendingPathComponent("\(name).gz")
        try await SystemToolProbe.gzip(plain, to: gz)
        try FileManager.default.removeItem(at: plain)
        return gz
    }

    /// Starts `read`, waits for its `gzip -dc` child, cancels the task, and expects the task to end with
    /// `CancellationError` within 10 seconds and the child to be gone.
    private func assertCancelStopsTheGzipChild<T: Sendable>(
        of gz: URL,
        _ read: @escaping @Sendable () async throws -> T
    ) async {
        let task = Task { try await read() }
        let started = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(5)) {
            let pids = await SystemToolProbe.childPIDs(commandLineHolding: gz.path)
            return !pids.isEmpty
        }
        XCTAssertTrue(started, "gzip -dc never started on \(gz.lastPathComponent)")

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("The cancelled task ran to its end")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(clock.now - cancelledAt, .seconds(10), "The cancelled task took too long to end")

        let gone = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(20)) {
            let pids = await SystemToolProbe.childPIDs(commandLineHolding: gz.path)
            return pids.isEmpty
        }
        XCTAssertTrue(gone, "gzip -dc outlived the cancelled task")
    }

    func testCancellingAKrakenScanStopsTheGzipChild() async throws {
        let gz = try await makeGzip(repeating: "C\ta\t562\t1\t562:1\n", named: "big.kraken")
        let service = try XCTUnwrap(service)
        await assertCancelStopsTheGzipChild(of: gz) {
            try await service.scanKrakenClassificationOutput(gz, targetTaxIds: [562])
        }
    }

    func testCancellingAFASTQExtractionStopsTheGzipChild() async throws {
        let gz = try await makeGzip(repeating: "@r\nA\n+\nI\n", named: "big.fastq", leading: "@hit\nA\n+\nI\n")
        let service = try XCTUnwrap(service)
        await assertCancelStopsTheGzipChild(of: gz) {
            try await service.extractMatchingSequences(from: gz, matchingReadIds: ["hit"], isGzip: true)
        }
    }
}
