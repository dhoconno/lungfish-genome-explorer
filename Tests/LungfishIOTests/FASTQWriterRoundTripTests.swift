// FASTQWriterRoundTripTests.swift - A file read with FASTQReader and written with FASTQWriter keeps its scores (BIO-BIN-QIN 7.2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// Phase 3.0 lane BIN, fix round 3 (BIO-BIN-QIN 7.2(b), S1). `FASTQWriter` stores every record's scores in its target
/// encoding, Phred+33 by default. A record the reader parsed as Phred+64 was therefore stored 31 too low, so a first read
/// with no score below Q31 changed the stored scores of the whole file.
final class FASTQWriterRoundTripTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastq-writer-round-trip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Read with `FASTQReader()` and write with `FASTQWriter`. The output's quality lines equal the input's byte for byte.
    func testAHiFiFirstReadRoundTripsByteForByte() async throws {
        let input = try HiFiFirstReadFixture.write(in: root)
        let records = try await FASTQReader().readAll(from: input)
        let output = root.appendingPathComponent("round-trip.fastq")
        try FASTQWriter.write(records, to: output)

        let inputLines = try qualityLines(of: input)
        XCTAssertEqual(inputLines.count, 2, "the fixture holds two records")
        XCTAssertEqual(
            inputLines.map { String(decoding: $0, as: UTF8.self) },
            HiFiFirstReadFixture.qualityLines,
            "the fixture's own quality lines"
        )
        XCTAssertEqual(try qualityLines(of: output), inputLines)
    }

    /// The quality line of every four-line record, as raw bytes.
    private func qualityLines(of url: URL) throws -> [[UInt8]] {
        let lines = try Data(contentsOf: url).split(separator: 0x0A, omittingEmptySubsequences: false).map { Array($0) }
        return stride(from: 3, to: lines.count, by: 4).map { lines[$0] }
    }
}
