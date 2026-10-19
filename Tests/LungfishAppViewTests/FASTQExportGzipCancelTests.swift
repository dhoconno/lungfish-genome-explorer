// FASTQExportGzipCancelTests.swift - A cancelled task stops the gzip of the FASTQ export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow
import LungfishCore
import LungfishTestSupport
import Security

/// The FASTQ export compresses its staged text with the real `/usr/bin/gzip`. Cancelling the export task
/// must stop the child and end the step with `CancellationError`, and a failure keeps the words it has today.
final class FASTQExportGzipCancelTests: XCTestCase {
    private var temp: URL!

    override func setUp() async throws {
        temp = try TestTempDirectory.make(prefix: "fastq-export-gzip-cancel")
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(temp)
    }

    /// 128 MiB made of one random 1 MiB block. Deflate looks back 32 KB, so gzip finds no match and works
    /// for seconds on it.
    func testCancellingTheCompressionStopsGzip() async throws {
        var block = Data(count: 1_048_576)
        let status = block.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        XCTAssertEqual(status, errSecSuccess)
        let input = temp.appendingPathComponent("big.fastq")
        try SystemToolProbe.writeRepeating(block, times: 128, to: input)
        let output = temp.appendingPathComponent("big.fastq.gz")

        let task = Task { try await FASTQReadsExport.gzipFile(input, to: output) }
        let started = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(5)) {
            let pids = await SystemToolProbe.childPIDs(commandLineHolding: input.path)
            return !pids.isEmpty
        }
        XCTAssertTrue(started, "gzip never started on \(input.lastPathComponent)")

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        task.cancel()
        do {
            try await task.value
            XCTFail("The cancelled compression ran to its end")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        XCTAssertLessThan(clock.now - cancelledAt, .seconds(10), "The cancelled compression took too long to end")

        let gone = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(20)) {
            let pids = await SystemToolProbe.childPIDs(commandLineHolding: input.path)
            return pids.isEmpty
        }
        XCTAssertTrue(gone, "gzip outlived the cancelled compression")
    }

    func testAFailedCompressionKeepsItsWords() async throws {
        let output = temp.appendingPathComponent("missing.fastq.gz")
        do {
            try await FASTQReadsExport.gzipFile(temp.appendingPathComponent("missing.fastq"), to: output)
            XCTFail("A missing input must fail the compression")
        } catch let error as NSError {
            XCTAssertEqual(error.domain, "com.lungfish.browser")
            XCTAssertEqual(error.code, 1)
            XCTAssertEqual(error.localizedDescription, "Compression failed for missing.fastq.gz.")
        }
    }
}
