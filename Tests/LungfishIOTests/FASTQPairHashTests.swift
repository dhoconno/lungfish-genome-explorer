// FASTQPairHashTests.swift - The order-free pair hash of the whole-file scan (row RS-INSTRUMENT, ADJ-BULK G5)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
import LungfishTestSupport

final class FASTQPairHashTests: XCTestCase {

    /// `python3 -I scripts/repro/rnaseq/gse163196/pairhash.py sarscov2 test_1.fastq.gz test_2.fastq.gz pigz`, run on the
    /// two fixtures at the base, printed `sarscov2 100 ab5a1dba405f30483ea69f8ff5db4d25`. A science pin, BIO's word in review.
    private static let pairhashPyOutput = (pairs: 100, sum: "ab5a1dba405f30483ea69f8ff5db4d25")

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "pair-hash")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func fixture(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/sarscov2/\(name)")
    }

    private func records(_ url: URL) throws -> [[String]] {
        var lines: [String] = []
        try url.forEachLineAutoDecompressing { lines.append($0) }
        return stride(from: 0, to: lines.count - 3, by: 4).map { Array(lines[$0..<$0 + 4]) }
    }

    /// The two fixture files written as one interleaved file, pair `order[0]` first.
    private func interleaved(_ name: String, order: [Int]) throws -> URL {
        let first = try records(fixture("test_1.fastq.gz"))
        let second = try records(fixture("test_2.fastq.gz"))
        var text = ""
        for index in order { text += (first[index] + second[index]).joined(separator: "\n") + "\n" }
        let url = root.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testTheHashOfTheSarscov2PairsEqualsPairhashPy() throws {
        let scan = try FASTQReadLayoutClassifier.scanMates(in: interleaved("ordered.fastq", order: Array(0..<100)))
        XCTAssertEqual(scan.matePairs, Self.pairhashPyOutput.pairs)
        XCTAssertEqual(scan.unpairedRecords, 0)
        XCTAssertEqual(scan.pairHash, Self.pairhashPyOutput.sum)
    }

    func testShuffledPairsGiveTheSameHashAndCount() throws {
        let shuffled = (0..<100).map { ($0 * 37 + 11) % 100 }
        XCTAssertEqual(Set(shuffled).count, 100, "The order is a permutation of the 100 pairs")
        let scan = try FASTQReadLayoutClassifier.scanMates(in: interleaved("shuffled.fastq", order: shuffled))
        XCTAssertEqual(scan.matePairs, 100)
        XCTAssertEqual(scan.pairHash, Self.pairhashPyOutput.sum)
    }

    func testADifferentSetOfPairsGivesAnotherHash() throws {
        let scan = try FASTQReadLayoutClassifier.scanMates(in: interleaved("short.fastq", order: Array(0..<99)))
        XCTAssertEqual(scan.matePairs, 99)
        XCTAssertNotEqual(scan.pairHash, Self.pairhashPyOutput.sum)
    }

    func testTheScanCountsEqualCountMates() throws {
        let url = try interleaved("counts.fastq", order: Array(0..<100))
        let scan = try FASTQReadLayoutClassifier.scanMates(in: url)
        let counted = try FASTQReadLayoutClassifier.countMates(in: url)
        XCTAssertEqual(scan.scannedRecords, counted.scannedRecords)
        XCTAssertEqual(scan.matePairs, counted.matePairs)
        XCTAssertEqual(scan.unpairedRecords, counted.unpairedRecords)
        XCTAssertEqual(scan.scannedWholeFile, counted.scannedWholeFile)
    }

    func testAFileOfSingleReadsHasNoPairHash() throws {
        let scan = try FASTQReadLayoutClassifier.scanMates(in: PlatformHeaderFixtures.url("illumina-pre18.fastq"))
        XCTAssertEqual(scan.matePairs, 0)
        XCTAssertNil(scan.pairHash)
    }

    func testASidecarWrittenBeforeTheFieldsDecodesAndIsWrittenBackUnchanged() throws {
        // The shape the import wrote before this row. No loose sidecar fixture sits under Tests/, so the literal stands for one.
        let legacy = #"{"recordedReadCount":{"paired_r1":10,"paired_r2":10,"storedSizeBytes":1234,"unpaired":0}}"#
        let decoded = try JSONDecoder().decode(PersistedFASTQMetadata.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.recordedReadCount?.pairedR1, 10)
        XCTAssertNil(decoded.recordedReadCount?.pairHash)
        XCTAssertNil(decoded.sequencerInstrument)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rewritten = String(decoding: try encoder.encode(decoded), as: UTF8.self)
        XCTAssertFalse(rewritten.contains("pair_hash"))
        XCTAssertFalse(rewritten.contains("sequencerInstrument"))
    }
}
