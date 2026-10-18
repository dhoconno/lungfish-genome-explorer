// BlastReadLookupNotesTests.swift - S38's open notes on BLAST's read lookup, closed in Phase 2.12
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import os
import LungfishTestSupport
@testable import LungfishCore

/// Phase 2.12 lane 12.10 (A65-P50), the notes S38's review left for the Kraken2 BLAST row
/// (`phase-2-10/reviews/S38.md:154-158`, K5 of 2.11). Each test failed at the lane's base.
///
/// 1. The hit-string lookup's catch swallowed a cancel and went on to submit mate 1.
/// 2. A gzip source that holds none of the sampled reads was decompressed twice.
/// 3. The plain-file branch of `nextChunk` checked no cancel, so a plain Kraken output or FASTQ was read to
///    its end after one.
final class BlastReadLookupNotesTests: XCTestCase {
    private var tempDir: URL!
    private var service: BlastService!

    override func setUp() async throws {
        tempDir = try TestTempDirectory.make(prefix: "blast-read-lookup-notes")
        service = BlastService(httpClient: MockHTTPClient())
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(tempDir)
    }

    /// A 32 MiB text of `line` after `leading`, gzip-compressed to a few hundred KB, which the service needs
    /// several seconds to read (the fixture of `BlastGzipStreamCancelTests`).
    private func makeGzip(repeating line: String, named name: String, leading: String = "") async throws -> URL {
        let plain = tempDir.appendingPathComponent(name)
        let block = Data(String(repeating: line, count: 1_048_576 / line.utf8.count).utf8)
        try SystemToolProbe.writeRepeating(block, times: 32, leading: Data(leading.utf8), to: plain)
        let gz = tempDir.appendingPathComponent("\(name).gz")
        try await SystemToolProbe.gzip(plain, to: gz)
        try FileManager.default.removeItem(at: plain)
        return gz
    }

    private func write(_ text: String, named name: String) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// Expects `task` to end with `CancellationError`.
    private func assertEndsCancelled<T: Sendable>(
        _ task: Task<T, any Error>,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("\(message): the cancelled task ran to its end", file: file, line: line)
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("\(message): expected CancellationError, got \(error)", file: file, line: line)
        }
    }

    // MARK: - Note 1, the cancel the lookup's catch swallowed

    /// The indexed path reads the Kraken output once, in the hit-string lookup, so the `gzip -dc` on it is the
    /// lookup's. The cancel comes while that gzip runs, and the source FASTQ is plain, which at the base read to
    /// its end and gave a request.
    func testACancelDuringTheHitStringLookupEndsTheRunCancelled() async throws {
        let kraken = try await makeGzip(
            repeating: "C\tother\t562\t10\t562:10\n", named: "lookup.kraken", leading: "C\thit\t562\t10\t562:10\n"
        )
        let fastq = try write("@hit\nACGTACGTAC\n+\nIIIIIIIIII\n", named: "reads.fastq")
        let service = try XCTUnwrap(service)
        let task = Task {
            try await service.buildVerificationRequestFromReadIds(
                taxonName: "Escherichia coli", taxId: 562, matchingReadIds: ["hit"],
                sources: [BlastReadSource(url: fastq)], readCount: 1, classificationOutputURL: kraken
            )
        }
        let started = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(5)) {
            !(await SystemToolProbe.childPIDs(commandLineHolding: kraken.path)).isEmpty
        }
        XCTAssertTrue(started, "the lookup's gzip -dc never started")
        task.cancel()
        await assertEndsCancelled(task, "a cancel during the lookup")
        let gone = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(20)) {
            (await SystemToolProbe.childPIDs(commandLineHolding: kraken.path)).isEmpty
        }
        XCTAssertTrue(gone, "the lookup's gzip -dc outlived the cancel")
    }
}
