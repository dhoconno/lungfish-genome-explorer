// FASTQReadLayoutWholeFileTests.swift - A file is strict only when all of it was read
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
import LungfishTestSupport

/// Row READ-LAYOUT-PARTIAL-SCAN (BIO ruling S1, section 6). A scan that stopped at 100,000 records called a file
/// strict when its first 50,000 or more pairs alternate, whatever followed, and every positional tool then paired
/// unrelated reads with exit 0. These tests hold real record counts, past the old window.
final class FASTQReadLayoutWholeFileTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "layout-whole-file")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    private func file(_ runs: [FASTQLayoutRecordFixtures.Run]) throws -> URL {
        let url = root.appendingPathComponent("\(UUID().uuidString).fastq")
        try FASTQLayoutRecordFixtures.write(runs, to: url)
        return url
    }

    func testSixtyThousandPairsThenTwentyThousandMergedIsMixed() throws {
        let result = FASTQReadLayoutClassifier.classify(inputURL: try file([.pairs(60_000), .singles(20_000)]))
        XCTAssertEqual(result.layout, .mixedInterleaved)
        XCTAssertEqual(result.scannedRecords, 140_000)
        XCTAssertEqual(result.matePairs, 60_000)
        XCTAssertEqual(result.unpairedRecords, 20_000)
        XCTAssertTrue(result.scannedWholeFile)
    }

    func testOddTotalIsMixed() throws {
        let result = FASTQReadLayoutClassifier.classify(inputURL: try file([.pairs(60_000), .singles(20_001)]))
        XCTAssertEqual(result.layout, .mixedInterleaved)
        XCTAssertEqual(result.scannedRecords, 140_001)
        XCTAssertEqual(result.unpairedRecords, 20_001)
    }

    func testFiftyThousandLeadingPairsIsMixed() throws {
        let result = FASTQReadLayoutClassifier.classify(inputURL: try file([.pairs(50_000), .singles(20_000)]))
        XCTAssertEqual(result.layout, .mixedInterleaved)
        XCTAssertEqual(result.matePairs, 50_000)
    }

    /// One lone read past the old window puts every later pair out of step, so a head and tail sample would miss it.
    func testLoneReadPastTheWindowIsMixed() throws {
        let result = FASTQReadLayoutClassifier.classify(
            inputURL: try file([.pairs(60_000), .singles(1), .pairs(10_000, first: 60_000)])
        )
        XCTAssertEqual(result.layout, .mixedInterleaved)
        XCTAssertEqual(result.matePairs, 70_000)
        XCTAssertEqual(result.unpairedRecords, 1)
    }

    /// The control. A truly strict file past the old window stays strict and still counts as pairs.
    func testTrueStrictStaysStrict() throws {
        let result = FASTQReadLayoutClassifier.classify(inputURL: try file([.pairs(70_000)]))
        XCTAssertEqual(result.layout, .strictlyInterleaved)
        XCTAssertEqual(result.matePairs, 70_000)
        XCTAssertEqual(result.unpairedRecords, 0)
        XCTAssertTrue(result.scannedWholeFile)
    }

    func testBoundedScanNeverReportsStrict() throws {
        let url = try file([.pairs(70_000)])
        let result = FASTQReadLayoutClassifier.classify(inputURL: url, limit: 2_000)
        XCTAssertNotEqual(result.layout, .strictlyInterleaved)
        XCTAssertFalse(result.scannedWholeFile)
        XCTAssertTrue(result.reason.contains("not read"), result.reason)
        XCTAssertNotEqual(
            FASTQInputLayoutResolver.resolve(inputURLs: [url], recordLimit: 2_000).layout,
            .strictlyInterleaved
        )
    }

    /// The resolver every operation reads its layout through, with and without a bundle's metadata as hints.
    func testTheResolverReadsTheWholeFile() throws {
        let url = try file([.pairs(60_000), .singles(20_000)])
        XCTAssertEqual(FASTQInputLayoutResolver.resolve(inputURLs: [url]).layout, .mixedMergedAndPairs)

        let bundle = root.appendingPathComponent("hints.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let resolution = FASTQInputLayoutResolver.resolve(fastqURL: url, metadataFrom: bundle)
        XCTAssertEqual(resolution.layout, .mixedMergedAndPairs)
        XCTAssertEqual(resolution.classification?.matePairs, 60_000)
    }

    // MARK: - A scan that stops at a bad record

    private func written(_ text: String) throws -> URL {
        let url = root.appendingPathComponent("\(UUID().uuidString).fastq")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func text(_ runs: [FASTQLayoutRecordFixtures.Run]) throws -> String {
        try String(contentsOf: try file(runs), encoding: .utf8)
    }

    /// BIO review B2. A scan that stopped at a record that is not FASTQ said it read the whole file, so 60,000 pairs
    /// followed by one bad line read as strict, and the importer recorded that prefix as the file's count. A file that
    /// stops being FASTQ was not read whole, whatever tool follows.
    func testABadRecordMidFileIsNotAWholeScan() throws {
        let pairs = try text([.pairs(10)])
        let morePairs = try text([.pairs(10, first: 10)])
        let singles = try text([.singles(10)])
        let bad: [(name: String, text: String)] = [
            ("a line that is not a header", pairs + "not a header\n" + morePairs),
            ("an empty line, then single reads", pairs + "\n" + singles),
        ]
        for example in bad {
            let url = try written(example.text)
            XCTAssertFalse(try FASTQReadLayoutClassifier.countMates(in: url).scannedWholeFile, example.name)
            XCTAssertEqual(FASTQReadLayoutClassifier.classify(inputURL: url).layout, .mixedInterleaved, example.name)
            XCTAssertFalse(
                try FASTQReadLayoutClassifier.readHeaders(from: url, limit: 10_000).scannedWholeFile, example.name)
        }
    }

    /// The control. Empty lines at the end of a file are not a bad record, so the file is still read whole.
    func testTrailingEmptyLinesStayAWholeScan() throws {
        let url = try written(try text([.pairs(10)]) + "\n\n")
        XCTAssertTrue(try FASTQReadLayoutClassifier.countMates(in: url).scannedWholeFile)
        XCTAssertEqual(FASTQReadLayoutClassifier.classify(inputURL: url).layout, .strictlyInterleaved)
        XCTAssertTrue(try FASTQReadLayoutClassifier.readHeaders(from: url, limit: 10_000).scannedWholeFile)
    }
}
