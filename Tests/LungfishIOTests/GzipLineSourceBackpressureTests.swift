// GzipLineSourceBackpressureTests.swift - streaming readers must not outrun their consumer
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// Regression for the 2026-08-22 OOM: `GzipInputStream.lines()` and
/// `FASTQReader.records(from:)` used producer tasks yielding into unbounded
/// `AsyncThrowingStream` buffers, so a fast gzip and a slow consumer buffered
/// whole files in memory. Both are now pull-based.
final class GzipLineSourceBackpressureTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gzip-backpressure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Writes `lineCount` FASTQ records (4 lines each) and gzips them.
    private func makeGzippedFASTQ(records: Int) throws -> URL {
        let plain = tempDir.appendingPathComponent("reads.fastq")
        var text = ""
        text.reserveCapacity(records * 120)
        let seq = String(repeating: "ACGT", count: 25)
        let qual = String(repeating: "I", count: 100)
        for i in 0..<records {
            text += "@read\(i) 1:N:0\n\(seq)\n+\n\(qual)\n"
        }
        try text.write(to: plain, atomically: true, encoding: .utf8)
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-f", plain.path]
        try gzip.run()
        gzip.waitUntilExit()
        XCTAssertEqual(gzip.terminationStatus, 0)
        return tempDir.appendingPathComponent("reads.fastq.gz")
    }

    func testLineSourceReadsOneChunkPerDemandNotTheWholeFile() throws {
        // 20k records ≈ 2.2 MB decompressed; with 64 KB chunks that is ~35 chunks.
        let url = try makeGzippedFASTQ(records: 20_000)
        let source = try GzipLineSource(url: url, chunkSize: 65_536)

        let first = try source.next()
        XCTAssertEqual(first, "@read0 1:N:0")
        XCTAssertEqual(source.chunksRead, 1, "pulling one line must decompress exactly one chunk")

        var count = 1
        while try source.next() != nil { count += 1 }
        XCTAssertEqual(count, 80_000)
        XCTAssertGreaterThan(source.chunksRead, 10)
        XCTAssertNil(try source.next(), "exhausted source stays exhausted")
        source.close()
    }

    func testLinesStreamCanBeAbandonedEarlyWithoutLeakingTheSubprocess() async throws {
        let url = try makeGzippedFASTQ(records: 5_000)
        let stream = try GzipInputStream(url: url).lines()
        var seen = 0
        for try await _ in stream {
            seen += 1
            if seen == 3 { break }
        }
        XCTAssertEqual(seen, 3)
        // A second, full pass must still work (no shared state between streams).
        var total = 0
        for try await _ in try GzipInputStream(url: url).lines() { total += 1 }
        XCTAssertEqual(total, 20_000)
    }

    func testRecordStreamIsLazyAndCompleteForGzipAndPlainFiles() async throws {
        let gz = try makeGzippedFASTQ(records: 3_000)
        let reader = FASTQReader(validateSequence: false)

        var firstThree: [String] = []
        for try await record in reader.records(from: gz) {
            firstThree.append(record.identifier)
            if firstThree.count == 3 { break }
        }
        XCTAssertEqual(firstThree, ["read0", "read1", "read2"])

        let all = try await reader.readAll(from: gz)
        XCTAssertEqual(all.count, 3_000)
        XCTAssertEqual(all.last?.identifier, "read2999")
        XCTAssertEqual(all.first?.length, 100)

        // Plain-text path goes through Foundation's AsyncLineSequence.
        let plain = tempDir.appendingPathComponent("plain.fastq")
        try "@a\nACGT\n+\nIIII\n@b\nGG\n+\nII\n".write(to: plain, atomically: true, encoding: .utf8)
        let plainRecords = try await reader.readAll(from: plain)
        XCTAssertEqual(plainRecords.map(\.identifier), ["a", "b"])
    }

    func testTruncatedRecordStillThrowsAtEndOfInput() async throws {
        let plain = tempDir.appendingPathComponent("truncated.fastq")
        try "@a\nACGT\n+\nII".write(to: plain, atomically: true, encoding: .utf8)
        let reader = FASTQReader(validateSequence: false)
        do {
            _ = try await reader.readAll(from: plain)
            XCTFail("expected qualityLengthMismatch")
        } catch let error as FASTQError {
            guard case .qualityLengthMismatch = error else {
                return XCTFail("unexpected \(error)")
            }
        }
    }
}
