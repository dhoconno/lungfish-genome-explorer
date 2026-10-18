// FASTQReadLayoutCountParityTests.swift - The streamed mate count equals the header scan
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.27 (SWIFT answer 2). `readHeaders` keeps every header of a file in an array, so a scan of a
// whole file held about 100 bytes of heap per record, 10 GB for 50 M interleaved pairs, before `fastq translate`
// wrote its first protein. `countMates` counts the adjacent mates while it streams and holds one header. Both
// feed the one decision in `classify`, so each case below runs both scans over the same file and compares the
// whole classification, the reason included.

import XCTest
@testable import LungfishIO

final class FASTQReadLayoutCountParityTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDown() {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
        super.tearDown()
    }

    private func write(_ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-read-layout-count-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        let url = dir.appendingPathComponent("reads.fastq")
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: Fixtures

    private struct Fixture {
        let name: String
        let text: String
        /// The counts of the whole file, worked by hand: records, adjacent mate pairs, records without a mate.
        let wholeFile: (records: Int, pairs: Int, unpaired: Int)
    }

    private static func fastq(_ headers: [String]) -> String {
        headers.map { "@\($0)\nACGT\n+\nIIII\n" }.joined()
    }

    /// Three Casava 1.8 pairs, six records.
    private static let casava: [String] = (1...3).flatMap { tile -> [String] in
        let id = "A00123:8:H7KJ2DSXX:1:1101:\(10_000 + tile):1000"
        return ["\(id) 1:N:0:ACGTACGT", "\(id) 2:N:0:ACGTACGT"]
    }

    private static let fixtures: [Fixture] = [
        Fixture(name: "strict Casava mates", text: fastq(casava), wholeFile: (6, 3, 0)),
        Fixture(name: "slash mates", text: fastq(["a/1", "a/2", "b/1", "b/2"]), wholeFile: (4, 2, 0)),
        Fixture(
            name: "mates with the same name",
            text: fastq(["SRR1.1", "SRR1.1", "SRR1.2", "SRR1.2"]),
            wholeFile: (4, 2, 0)
        ),
        Fixture(
            name: "merged reads then pairs",
            text: fastq(["m1", "a/1", "a/2", "m2", "b/1", "b/2"]),
            wholeFile: (6, 2, 2)
        ),
        Fixture(name: "single-end", text: fastq(["s1", "s2", "s3"]), wholeFile: (3, 0, 3)),
        Fixture(name: "an odd count", text: fastq(["a/1", "a/2", "b/1", "b/2", "c/1"]), wholeFile: (5, 2, 1)),
        Fixture(name: "an empty file", text: "", wholeFile: (0, 0, 0)),
        Fixture(
            name: "a non-@ header at record 3",
            text: fastq(["a/1", "a/2"]) + "not-a-header\nACGT\n+\nIIII\n" + fastq(["b/1", "b/2"]),
            wholeFile: (2, 1, 0)
        ),
    ]

    // MARK: Tests

    /// The classification from the counts equals the one from the header scan, for every fixture, limit and hint.
    func testCountedScanEqualsTheHeaderScan() throws {
        let hintSets: [(name: String, hints: FASTQPairingMetadataHints)] = [
            ("no hints", FASTQPairingMetadataHints()),
            (
                "merged reads recorded",
                FASTQPairingMetadataHints(hasMergedOrUnpairedReads: true, mergeEvidence: "a merge step in the recipe")
            ),
            ("paired content claimed", FASTQPairingMetadataHints(pairingMode: .interleaved, pairingSource: .detected)),
        ]
        for fixture in Self.fixtures {
            let url = try write(fixture.text)
            for limit in [Int.max, 100_000, 4, 5] {
                let scan = try FASTQReadLayoutClassifier.readHeaders(from: url, limit: limit)
                let counted = try FASTQReadLayoutClassifier.countMates(in: url, limit: limit)
                XCTAssertEqual(counted.scannedRecords, scan.headers.count, "\(fixture.name), limit \(limit): records")
                XCTAssertEqual(counted.scannedWholeFile, scan.scannedWholeFile, "\(fixture.name), limit \(limit)")
                for (hintName, hints) in hintSets {
                    for outranks in [false, true] {
                        let fromHeaders = FASTQReadLayoutClassifier.classify(
                            headers: scan.headers,
                            scannedWholeFile: scan.scannedWholeFile,
                            metadata: hints,
                            wholeFileScanOutranksTheMerge: outranks
                        )
                        let fromCounts = FASTQReadLayoutClassifier.classify(
                            scannedRecords: counted.scannedRecords,
                            matePairs: counted.matePairs,
                            unpairedRecords: counted.unpairedRecords,
                            scannedWholeFile: counted.scannedWholeFile,
                            metadata: hints,
                            wholeFileScanOutranksTheMerge: outranks
                        )
                        XCTAssertEqual(
                            fromCounts,
                            fromHeaders,
                            "\(fixture.name), limit \(limit), \(hintName), outranks \(outranks)"
                        )
                    }
                }
            }
        }
    }

    /// The counts are fixed by hand, so a loop that is wrong the same way in both scans still fails.
    func testCountedScanGivesTheHandWorkedCountsOfEachFixture() throws {
        for fixture in Self.fixtures {
            let counted = try FASTQReadLayoutClassifier.countMates(in: try write(fixture.text))
            XCTAssertEqual(counted.scannedRecords, fixture.wholeFile.records, fixture.name)
            XCTAssertEqual(counted.matePairs, fixture.wholeFile.pairs, fixture.name)
            XCTAssertEqual(counted.unpairedRecords, fixture.wholeFile.unpaired, fixture.name)
            XCTAssertTrue(counted.scannedWholeFile, fixture.name)
        }
    }

    /// A limit that ends halfway through a pair does not count the last record against strictness, as
    /// `classify(headers:)` does, and a limit equal to the record count still reads the whole file.
    func testCountedScanAtTheLimitDoesNotCountAHalfPairAgainstStrictness() throws {
        let url = try write(Self.fastq(Self.casava))

        let atFour = try FASTQReadLayoutClassifier.countMates(in: url, limit: 4)
        XCTAssertEqual([atFour.scannedRecords, atFour.matePairs, atFour.unpairedRecords], [4, 2, 0])
        XCTAssertFalse(atFour.scannedWholeFile)

        let atFive = try FASTQReadLayoutClassifier.countMates(in: url, limit: 5)
        XCTAssertEqual([atFive.scannedRecords, atFive.matePairs, atFive.unpairedRecords], [5, 2, 0])
        XCTAssertFalse(atFive.scannedWholeFile)

        let atSix = try FASTQReadLayoutClassifier.countMates(in: url, limit: 6)
        XCTAssertEqual([atSix.scannedRecords, atSix.matePairs, atSix.unpairedRecords], [6, 3, 0])
        XCTAssertTrue(atSix.scannedWholeFile)
    }
}
