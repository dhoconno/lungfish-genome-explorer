// StreamingFASTATests.swift - Tests for buffered FASTA reading
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
import LungfishCore

/// Tests verifying the streaming (buffered) FASTA parser handles
/// multi-line sequences, large files, and edge cases correctly.
final class StreamingFASTATests: XCTestCase {

    // MARK: - Large File Tests

    func testReadLargeMultiSequenceFASTA() throws {
        guard let url = Bundle.module.url(forResource: "large_test", withExtension: "fasta") else {
            throw XCTSkip("large_test.fasta not found in test resources")
        }
        let reader = try FASTAReader(url: url)
        let sequences = try reader.readAllSync()

        XCTAssertEqual(sequences.count, 10, "Should read 10 sequences")

        for (i, seq) in sequences.enumerated() {
            XCTAssertEqual(seq.name, "seq\(i + 1)", "Sequence \(i + 1) name")
            XCTAssertEqual(seq.length, 10000, "Sequence \(i + 1) should be 10,000 bp")
        }
    }

    func testReadLargeFileHeaders() throws {
        guard let url = Bundle.module.url(forResource: "large_test", withExtension: "fasta") else {
            throw XCTSkip("large_test.fasta not found in test resources")
        }
        let reader = try FASTAReader(url: url)
        let headers = try reader.readHeadersSync()

        XCTAssertEqual(headers.count, 10)
        XCTAssertEqual(headers[0].name, "seq1")
        XCTAssertTrue(headers[0].description?.contains("length=10000") == true)
    }

    func testAsyncStreamingMatchesSync() async throws {
        guard let url = Bundle.module.url(forResource: "large_test", withExtension: "fasta") else {
            throw XCTSkip("large_test.fasta not found in test resources")
        }
        let reader = try FASTAReader(url: url)

        let syncResult = try reader.readAllSync()
        let asyncResult = try await reader.readAll()

        XCTAssertEqual(syncResult.count, asyncResult.count)
        for (s, a) in zip(syncResult, asyncResult) {
            XCTAssertEqual(s.name, a.name)
            XCTAssertEqual(s.length, a.length)
            XCTAssertEqual(s.asString(), a.asString())
        }
    }

    // MARK: - Edge Cases

    func testSingleLineSequence() throws {
        let content = ">single\nATCGATCGATCG\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming_test_\(UUID()).fasta")
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try FASTAReader(url: url)
        let sequences = try reader.readAllSync()

        XCTAssertEqual(sequences.count, 1)
        XCTAssertEqual(sequences[0].asString(), "ATCGATCGATCG")
    }

    func testMultiLineSequence() throws {
        let content = ">multi\nATCG\nATCG\nATCG\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming_test_\(UUID()).fasta")
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try FASTAReader(url: url)
        let sequences = try reader.readAllSync()

        XCTAssertEqual(sequences.count, 1)
        XCTAssertEqual(sequences[0].asString(), "ATCGATCGATCG")
    }

    func testNoTrailingNewline() throws {
        let content = ">noterminal\nATCGATCG"  // No trailing newline
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming_test_\(UUID()).fasta")
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try FASTAReader(url: url)
        let sequences = try reader.readAllSync()

        XCTAssertEqual(sequences.count, 1)
        XCTAssertEqual(sequences[0].asString(), "ATCGATCG")
    }

    func testWindowsLineEndings() throws {
        // Write raw bytes to ensure actual CR+LF
        let rawContent = ">windows\r\nATCG\r\nATCG\r\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming_test_\(UUID()).fasta")
        guard let data = rawContent.data(using: .utf8) else {
            XCTFail("Failed to create test data")
            return
        }
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try FASTAReader(url: url)
        let sequences = try reader.readAllSync()

        XCTAssertEqual(sequences.count, 1)
        if sequences.count > 0 {
            XCTAssertEqual(sequences[0].asString(), "ATCGATCG")
        }
    }

    func testEmptyFile() throws {
        let content = ""
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming_test_\(UUID()).fasta")
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try FASTAReader(url: url)
        let sequences = try reader.readAllSync()

        XCTAssertTrue(sequences.isEmpty)
    }

    func testConsecutiveHeaders() throws {
        // A sequence followed immediately by another header (empty sequence)
        let content = ">first\nATCG\n>second\nGCTA\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming_test_\(UUID()).fasta")
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try FASTAReader(url: url)
        let sequences = try reader.readAllSync()

        XCTAssertEqual(sequences.count, 2)
        XCTAssertEqual(sequences[0].name, "first")
        XCTAssertEqual(sequences[0].asString(), "ATCG")
        XCTAssertEqual(sequences[1].name, "second")
        XCTAssertEqual(sequences[1].asString(), "GCTA")
    }

    func testBlankLinesBetweenSequences() throws {
        let content = ">first\nATCG\n\n\n>second\nGCTA\n"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("streaming_test_\(UUID()).fasta")
        try content.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = try FASTAReader(url: url)
        let sequences = try reader.readAllSync()

        XCTAssertEqual(sequences.count, 2)
    }
}
