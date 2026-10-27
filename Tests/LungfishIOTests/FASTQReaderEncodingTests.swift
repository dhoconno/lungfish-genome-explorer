// FASTQReaderEncodingTests.swift - The reader reads Phred+33 unless the caller passes an encoding (BIO-BIN-QIN 7.2)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

/// Phase 3.0 lane BIN, fix round 3 (BIO-BIN-QIN 7.2, S1). The reader once guessed the encoding from the first record.
/// A first read with no score below Q31 and one at Q72 or above made every score of the file read 31 too low, in the
/// statistics a person sees and in the scores a writer stored. LGE stores Phred+33 only, since N2 refuses a Phred+64
/// file at import, so the reader reads Phred+33 unless the caller passes an encoding.
final class FASTQReaderEncodingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastq-reader-encoding-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Record 1 reads Q31 to Q93 and record 2 reads Q40, through the async record stream and through the synchronous
    /// path that `computeStatistics` drives. At the round head `b2860c1ad` both paths gave 0, 62 and 9.
    func testAHiFiFirstReadIsReadAsPhred33() async throws {
        let url = try HiFiFirstReadFixture.write(in: root)
        let reader = FASTQReader()

        let streamed = try await reader.readAll(from: url)
        assertPhred33(streamed, path: "async record stream")

        let (_, sampled) = try await reader.computeStatistics(from: url)
        assertPhred33(sampled, path: "synchronous path")
    }

    /// The caller's encoding still wins, so a Phred+64 file read on purpose reads right. The same bytes read 31 lower.
    func testAnExplicitPhred64EncodingIsHonoured() async throws {
        let url = try HiFiFirstReadFixture.write(in: root)
        let reader = FASTQReader(encoding: .phred64)

        let streamed = try await reader.readAll(from: url)
        let (_, sampled) = try await reader.computeStatistics(from: url)

        for (path, records) in [("async record stream", streamed), ("synchronous path", sampled)] {
            XCTAssertEqual(records.count, 2, path)
            guard records.count == 2 else { continue }
            XCTAssertEqual(records[0].quality.encoding, .phred64, path)
            XCTAssertEqual(records[0].quality.qualityAt(0), 0, "\(path), record 1 first base")
            XCTAssertEqual(records[0].quality.qualityAt(62), 62, "\(path), record 1 last base")
            XCTAssertEqual(records[1].quality.qualityAt(0), 9, "\(path), record 2 first base")
        }
    }

    private func assertPhred33(
        _ records: [FASTQRecord],
        path: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(records.count, 2, "\(path) record count", file: file, line: line)
        guard records.count == 2 else { return }
        XCTAssertEqual(records[0].quality.encoding, .phred33, "\(path) record 1 encoding", file: file, line: line)
        XCTAssertEqual(records[0].quality.qualityAt(0), 31, "\(path), record 1 first base", file: file, line: line)
        XCTAssertEqual(records[0].quality.qualityAt(62), 93, "\(path), record 1 last base", file: file, line: line)
        XCTAssertEqual(records[1].quality.encoding, .phred33, "\(path) record 2 encoding", file: file, line: line)
        XCTAssertEqual(records[1].quality.qualityAt(0), 40, "\(path), record 2 first base", file: file, line: line)
    }
}
