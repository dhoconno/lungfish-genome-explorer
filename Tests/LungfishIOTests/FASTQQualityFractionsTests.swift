// FASTQQualityFractionsTests.swift - Q20/Q30 counted from the bases, not rounded by seqkit
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class FASTQQualityFractionsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fastq-quality-fractions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 40 bases: 38 at or above Q20 (95.0%), 36 at or above Q30 (90.0%),
    /// then one more read that moves both off a whole percent.
    private func writeFixture() throws -> URL {
        // '5' is Q20, '?' is Q30, 'I' is Q40, '#' is Q2 (phred+33).
        let records = [
            ("r1", String(repeating: "A", count: 20), String(repeating: "I", count: 18) + "55"),
            ("r2", String(repeating: "C", count: 20), String(repeating: "?", count: 18) + "##"),
            ("r3", String(repeating: "G", count: 7), "III??5#"),
        ]
        var text = ""
        for (id, sequence, quality) in records {
            text += "@\(id)\n\(sequence)\n+\n\(quality)\n"
        }
        let url = root.appendingPathComponent("reads.fastq")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testCountsEveryBaseAgainstQ20AndQ30() async throws {
        let url = try writeFixture()
        let fractions = try await FASTQQualityFractions.scan(url)
        XCTAssertEqual(fractions.baseCount, 47)
        XCTAssertEqual(fractions.q20Count, 44)
        XCTAssertEqual(fractions.q30Count, 41)
        XCTAssertEqual(fractions.q20Percentage, 44.0 / 47.0 * 100, accuracy: 1e-9)
        XCTAssertEqual(fractions.q30Percentage, 41.0 / 47.0 * 100, accuracy: 1e-9)
    }

    func testMatchesTheStatisticsCollectorExactly() async throws {
        let url = try writeFixture()
        let fractions = try await FASTQQualityFractions.scan(url)
        let collector = FASTQStatisticsCollector()
        for try await record in FASTQReader(validateSequence: false).records(from: url) {
            collector.process(record)
        }
        let collected = collector.finalize()
        XCTAssertEqual(fractions.q20Percentage, collected.q20Percentage)
        XCTAssertEqual(fractions.q30Percentage, collected.q30Percentage)
        XCTAssertEqual(fractions.baseCount, collected.baseCount)
    }

    func testReplacesSeqkitRoundedPercentagesOnly() async throws {
        let url = try writeFixture()
        let fractions = try await FASTQQualityFractions.scan(url)
        let seqkit = SeqkitStatsMetadata(
            numSeqs: 3, sumLen: 47, minLen: 7, avgLen: 15.7, maxLen: 20,
            q20Percentage: 94, q30Percentage: 87, averageQuality: 25.3, gcPercentage: 57.4
        )
        let exact = seqkit.replacingQualityPercentages(with: fractions)
        XCTAssertEqual(exact.q20Percentage, fractions.q20Percentage)
        XCTAssertEqual(exact.q30Percentage, fractions.q30Percentage)
        XCTAssertEqual(exact.numSeqs, 3)
        XCTAssertEqual(exact.averageQuality, 25.3)
        XCTAssertEqual(exact.gcPercentage, 57.4)
    }

    func testEmptyInputGivesZeroFractions() async throws {
        let url = root.appendingPathComponent("empty.fastq")
        try "".write(to: url, atomically: true, encoding: .utf8)
        let fractions = try await FASTQQualityFractions.scan(url)
        XCTAssertEqual(fractions.baseCount, 0)
        XCTAssertEqual(fractions.q20Percentage, 0)
        XCTAssertEqual(fractions.q30Percentage, 0)
    }
}
