// KrakenIndexDatabaseTests.swift - Tests for Kraken2 per-read SQLite index
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class KrakenIndexDatabaseTests: XCTestCase {

    // MARK: - Fixtures

    /// A small Kraken2 per-read output fixture with known taxonomy IDs.
    ///
    /// Format: `C/U\treadId\ttaxId\tlength\tkmerHits`
    private static let sampleKrakenText = """
    C\tread_001\t9606\t150\t0:1 9606:120 0:29
    C\tread_002\t9606\t150\t0:5 9606:110 0:35
    C\tread_003\t562\t200\t0:2 562:180 0:18
    U\tread_004\t0\t150\t0:150
    C\tread_005\t562\t180\t0:1 562:170 0:9
    C\tread_006\t1280\t250\t1280:230 0:20
    U\tread_007\t0\t100\t0:100
    C\tread_008\t9606\t300\t9606:280 0:20
    C\tread_009\t562\t175\t562:160 0:15
    C\tread_010\t1280\t200\t1280:185 0:15
    """

    /// Temporary directory for test artifacts.
    private var tempDir: URL!

    /// URL to the temporary .kraken file.
    private var krakenURL: URL!

    /// URL to the expected index file.
    private var indexURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("KrakenIndexDBTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        krakenURL = tempDir.appendingPathComponent("sample.kraken")
        try Self.sampleKrakenText.write(to: krakenURL, atomically: true, encoding: .utf8)

        indexURL = KrakenIndexDatabase.indexURL(for: krakenURL)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Build Tests

    func testBuildCreatesIndexFile() throws {
        try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: indexURL.path),
            "Index file should exist after build"
        )
    }

    func testBuildReportsProgress() throws {
        // The build method is synchronous and calls the progress closure on the
        // calling thread, so mutation of this array is safe despite the @Sendable
        // annotation on the closure parameter.
        nonisolated(unsafe) var progressValues: [(Double, String)] = []

        try KrakenIndexDatabase.build(from: krakenURL, to: indexURL) { fraction, message in
            progressValues.append((fraction, message))
        }

        XCTAssertFalse(progressValues.isEmpty, "Progress should have been reported")
        XCTAssertEqual(progressValues.last?.0, 1.0, "Final progress should be 1.0")
    }

    func testBuildDeletesExistingIndex() throws {
        // Build once.
        try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)
        let firstSize = try FileManager.default.attributesOfItem(atPath: indexURL.path)[.size] as? Int64

        // Build again -- should overwrite.
        try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)
        let secondSize = try FileManager.default.attributesOfItem(atPath: indexURL.path)[.size] as? Int64

        XCTAssertNotNil(firstSize)
        XCTAssertNotNil(secondSize)
        // Both builds should produce the same size since the input is identical.
        XCTAssertEqual(firstSize, secondSize)
    }

    func testBuildEmptyFileThrows() throws {
        let emptyURL = tempDir.appendingPathComponent("empty.kraken")
        try "".write(to: emptyURL, atomically: true, encoding: .utf8)
        let emptyIndexURL = KrakenIndexDatabase.indexURL(for: emptyURL)

        XCTAssertThrowsError(
            try KrakenIndexDatabase.build(from: emptyURL, to: emptyIndexURL)
        ) { error in
            guard let dbError = error as? KrakenIndexDatabaseError else {
                XCTFail("Expected KrakenIndexDatabaseError, got \(type(of: error))")
                return
            }
            switch dbError {
            case .emptySource:
                break // Expected
            default:
                XCTFail("Expected .emptySource, got \(dbError)")
            }
        }
    }

    // MARK: - Query Tests

    func testReadIdsForSpecificTaxId() throws {
        try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)
        let db = try KrakenIndexDatabase(url: indexURL)
        defer { db.close() }

        // Query for human reads (taxId 9606).
        let humanReads = try db.readIds(forTaxIds: [9606])
        XCTAssertEqual(humanReads.count, 3)
        XCTAssertTrue(humanReads.contains("read_001"))
        XCTAssertTrue(humanReads.contains("read_002"))
        XCTAssertTrue(humanReads.contains("read_008"))
    }

    func testReadIdsForMultipleTaxIds() throws {
        try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)
        let db = try KrakenIndexDatabase(url: indexURL)
        defer { db.close() }

        // Query for E. coli (562) and S. aureus (1280).
        let reads = try db.readIds(forTaxIds: [562, 1280])
        XCTAssertEqual(reads.count, 5)
        XCTAssertTrue(reads.contains("read_003"))
        XCTAssertTrue(reads.contains("read_005"))
        XCTAssertTrue(reads.contains("read_009"))
        XCTAssertTrue(reads.contains("read_006"))
        XCTAssertTrue(reads.contains("read_010"))
    }

    func testReadIdsForUnclassified() throws {
        try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)
        let db = try KrakenIndexDatabase(url: indexURL)
        defer { db.close() }

        // Unclassified reads have taxId 0.
        let unclassified = try db.readIds(forTaxIds: [0])
        XCTAssertEqual(unclassified.count, 2)
        XCTAssertTrue(unclassified.contains("read_004"))
        XCTAssertTrue(unclassified.contains("read_007"))
    }

    func testReadIdsForNonexistentTaxId() throws {
        try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)
        let db = try KrakenIndexDatabase(url: indexURL)
        defer { db.close() }

        let empty = try db.readIds(forTaxIds: [99999])
        XCTAssertTrue(empty.isEmpty)
    }

    func testReadIdsForEmptySet() throws {
        try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)
        let db = try KrakenIndexDatabase(url: indexURL)
        defer { db.close() }

        let empty = try db.readIds(forTaxIds: [])
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: - Read Count Tests

    func testReadCountForKnownTaxId() throws {
        try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)
        let db = try KrakenIndexDatabase(url: indexURL)
        defer { db.close() }

        XCTAssertEqual(db.readCount(forTaxId: 9606), 3)
        XCTAssertEqual(db.readCount(forTaxId: 562), 3)
        XCTAssertEqual(db.readCount(forTaxId: 1280), 2)
        XCTAssertEqual(db.readCount(forTaxId: 0), 2) // Unclassified
    }

    func testReadCountForNonexistentTaxId() throws {
        try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)
        let db = try KrakenIndexDatabase(url: indexURL)
        defer { db.close() }

        XCTAssertEqual(db.readCount(forTaxId: 99999), 0)
    }

    // MARK: - All Tax Counts Tests

    func testAllTaxCounts() throws {
        try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)
        let db = try KrakenIndexDatabase(url: indexURL)
        defer { db.close() }

        let counts = db.allTaxCounts()

        // We have 4 distinct taxonomy IDs: 9606, 562, 1280, 0
        XCTAssertEqual(counts.count, 4)
        XCTAssertEqual(counts[9606], 3)
        XCTAssertEqual(counts[562], 3)
        XCTAssertEqual(counts[1280], 2)
        XCTAssertEqual(counts[0], 2)

        // Total reads should sum to 10.
        let totalReads = counts.values.reduce(0, +)
        XCTAssertEqual(totalReads, 10)
    }

    // MARK: - Validity Tests

    func testIsValidForValidIndex() throws {
        try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)

        XCTAssertTrue(
            KrakenIndexDatabase.isValid(at: indexURL, for: krakenURL),
            "Index should be valid for its source file"
        )
    }

    func testIsValidReturnsFalseForMissingIndex() {
        let missingURL = tempDir.appendingPathComponent("missing.kraken.idx.sqlite")

        XCTAssertFalse(
            KrakenIndexDatabase.isValid(at: missingURL, for: krakenURL),
            "isValid should return false when index file does not exist"
        )
    }

    func testIsValidReturnsFalseAfterSourceFileChanges() throws {
        try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)

        // Append data to the source file, changing its size.
        let handle = try FileHandle(forWritingTo: krakenURL)
        handle.seekToEndOfFile()
        handle.write("C\textra_read\t9606\t150\t9606:150\n".data(using: .utf8)!)
        handle.closeFile()

        XCTAssertFalse(
            KrakenIndexDatabase.isValid(at: indexURL, for: krakenURL),
            "isValid should return false when source file size has changed"
        )
    }

    func testIsValidReturnsFalseForMissingSourceFile() throws {
        try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)

        let missingSourceURL = tempDir.appendingPathComponent("does_not_exist.kraken")

        XCTAssertFalse(
            KrakenIndexDatabase.isValid(at: indexURL, for: missingSourceURL),
            "isValid should return false when source file does not exist"
        )
    }

    // MARK: - Index URL Convention Tests

    func testIndexURLConvention() {
        let krakenFile = URL(fileURLWithPath: "/data/sample.kraken")
        let expected = URL(fileURLWithPath: "/data/sample.kraken.idx.sqlite")
        XCTAssertEqual(KrakenIndexDatabase.indexURL(for: krakenFile), expected)
    }

    func testIndexURLConventionWithPath() {
        let krakenFile = URL(fileURLWithPath: "/long/path/to/output.kraken")
        let result = KrakenIndexDatabase.indexURL(for: krakenFile)
        XCTAssertEqual(result.lastPathComponent, "output.kraken.idx.sqlite")
    }

    // MARK: - Close and Reopen Tests

    func testIndexSurvivesCloseAndReopen() throws {
        try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)

        // Open, query, and close.
        let db1 = try KrakenIndexDatabase(url: indexURL)
        let countsBeforeClose = db1.allTaxCounts()
        db1.close()

        // Reopen and verify.
        let db2 = try KrakenIndexDatabase(url: indexURL)
        defer { db2.close() }

        let countsAfterReopen = db2.allTaxCounts()
        XCTAssertEqual(countsBeforeClose, countsAfterReopen)

        // Verify specific queries still work.
        let humanReads = try db2.readIds(forTaxIds: [9606])
        XCTAssertEqual(humanReads.count, 3)
    }

    func testCloseIsIdempotent() throws {
        try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)
        let db = try KrakenIndexDatabase(url: indexURL)

        // Close multiple times -- should not crash.
        db.close()
        db.close()
        db.close()

        // After close, queries return empty results.
        let counts = db.allTaxCounts()
        XCTAssertTrue(counts.isEmpty)
    }

    func testQueriesAfterCloseReturnEmpty() throws {
        try KrakenIndexDatabase.build(from: krakenURL, to: indexURL)
        let db = try KrakenIndexDatabase(url: indexURL)
        db.close()

        XCTAssertTrue(db.allTaxCounts().isEmpty)
        XCTAssertEqual(db.readCount(forTaxId: 9606), 0)

        let reads = try db.readIds(forTaxIds: [9606])
        XCTAssertTrue(reads.isEmpty)
    }

    // MARK: - Edge Cases

    func testMalformedLinesSkipped() throws {
        let mixedText = """
        C\tgood_read\t9606\t150\t9606:150
        this is not a valid line
        C\tanother_good\t562\t200\t562:200
        X\tbad_status\t100\t100\t100:100
        C\tmissing_fields
        """
        let mixedURL = tempDir.appendingPathComponent("mixed.kraken")
        try mixedText.write(to: mixedURL, atomically: true, encoding: .utf8)

        let mixedIndexURL = KrakenIndexDatabase.indexURL(for: mixedURL)
        try KrakenIndexDatabase.build(from: mixedURL, to: mixedIndexURL)

        let db = try KrakenIndexDatabase(url: mixedIndexURL)
        defer { db.close() }

        let counts = db.allTaxCounts()
        // Only 2 valid lines: good_read (9606) and another_good (562).
        XCTAssertEqual(counts.count, 2)
        XCTAssertEqual(counts[9606], 1)
        XCTAssertEqual(counts[562], 1)
    }

    func testPairedEndReadLengths() throws {
        let pairedText = """
        C\tpaired_read\t9606\t150|150\t9606:280 0:20
        """
        let pairedURL = tempDir.appendingPathComponent("paired.kraken")
        try pairedText.write(to: pairedURL, atomically: true, encoding: .utf8)

        let pairedIndexURL = KrakenIndexDatabase.indexURL(for: pairedURL)
        try KrakenIndexDatabase.build(from: pairedURL, to: pairedIndexURL)

        let db = try KrakenIndexDatabase(url: pairedIndexURL)
        defer { db.close() }

        // The paired read should exist.
        let reads = try db.readIds(forTaxIds: [9606])
        XCTAssertEqual(reads.count, 1)
        XCTAssertTrue(reads.contains("paired_read"))
    }

    // MARK: - Error Descriptions

    func testErrorDescriptions() {
        let openErr = KrakenIndexDatabaseError.openFailed("bad file")
        XCTAssertNotNil(openErr.errorDescription)
        XCTAssertTrue(openErr.errorDescription!.contains("open"))

        let buildErr = KrakenIndexDatabaseError.buildFailed("schema error")
        XCTAssertNotNil(buildErr.errorDescription)
        XCTAssertTrue(buildErr.errorDescription!.contains("build"))

        let sourceErr = KrakenIndexDatabaseError.sourceReadError(
            URL(fileURLWithPath: "/tmp/test.kraken"), "not found"
        )
        XCTAssertNotNil(sourceErr.errorDescription)
        XCTAssertTrue(sourceErr.errorDescription!.contains("test.kraken"))

        let emptyErr = KrakenIndexDatabaseError.emptySource
        XCTAssertNotNil(emptyErr.errorDescription)
        XCTAssertTrue(emptyErr.errorDescription!.contains("empty"))
    }
}
