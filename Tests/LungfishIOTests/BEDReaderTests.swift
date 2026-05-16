// BEDReaderTests.swift - Tests for BED parser
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO
@testable import LungfishCore

final class BEDReaderTests: XCTestCase {

    // MARK: - Test Data

    let sampleBED3 = """
    chr1\t100\t200
    chr1\t300\t400
    chr2\t500\t600
    """

    let sampleBED6 = """
    chr1\t100\t200\tfeature1\t500\t+
    chr1\t300\t400\tfeature2\t800\t-
    chr1\t500\t600\tfeature3\t0\t.
    """

    let sampleBED12 = """
    chr1\t100\t500\tgene1\t900\t+\t150\t450\t255,0,0\t3\t50,50,50,\t0,150,350,
    """

    // MARK: - Helpers

    func createTempFile(content: String) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "test_\(UUID().uuidString).bed"
        let url = tempDir.appendingPathComponent(fileName)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - BED3 Tests

    func testReadBED3() async throws {
        let url = try createTempFile(content: sampleBED3)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = BEDReader()
        let features = try await reader.readAll(from: url)

        XCTAssertEqual(features.count, 3)
        XCTAssertEqual(features[0].chrom, "chr1")
        XCTAssertEqual(features[0].chromStart, 100)
        XCTAssertEqual(features[0].chromEnd, 200)
    }

    // MARK: - BED6 Tests

    func testReadBED6() async throws {
        let url = try createTempFile(content: sampleBED6)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = BEDReader()
        let features = try await reader.readAll(from: url)

        XCTAssertEqual(features.count, 3)

        XCTAssertEqual(features[0].name, "feature1")
        XCTAssertEqual(features[0].score, 500)
        XCTAssertEqual(features[0].strand, .forward)

        XCTAssertEqual(features[1].strand, .reverse)
        XCTAssertEqual(features[2].strand, .unknown)
    }

    func testReadGzippedBED6() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_\(UUID().uuidString).bed.gz")
        try GzipTestHelper.writeGzip(sampleBED6, to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = BEDReader()
        let features = try await reader.readAll(from: url)

        XCTAssertEqual(features.count, 3)
        XCTAssertEqual(features[0].name, "feature1")
        XCTAssertEqual(features[1].strand, .reverse)
    }

    // MARK: - BED12 Tests

    func testReadBED12() async throws {
        let url = try createTempFile(content: sampleBED12)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = BEDReader()
        let features = try await reader.readAll(from: url)

        XCTAssertEqual(features.count, 1)

        let feature = features[0]
        XCTAssertEqual(feature.name, "gene1")
        XCTAssertEqual(feature.thickStart, 150)
        XCTAssertEqual(feature.thickEnd, 450)
        XCTAssertEqual(feature.itemRgb, "255,0,0")
        XCTAssertEqual(feature.blockCount, 3)
        XCTAssertEqual(feature.blockSizes, [50, 50, 50])
        XCTAssertEqual(feature.blockStarts, [0, 150, 350])
    }

    // MARK: - Skip Lines Tests

    func testSkipComments() async throws {
        let bed = """
        # This is a comment
        chr1\t100\t200
        # Another comment
        chr1\t300\t400
        """
        let url = try createTempFile(content: bed)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = BEDReader()
        let features = try await reader.readAll(from: url)

        XCTAssertEqual(features.count, 2)
    }

    func testSkipTrackLines() async throws {
        let bed = """
        track name=test description="Test track"
        browser position chr1:100-500
        chr1\t100\t200
        """
        let url = try createTempFile(content: bed)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = BEDReader()
        let features = try await reader.readAll(from: url)

        XCTAssertEqual(features.count, 1)
    }

    // MARK: - Error Tests

    func testInvalidLineThrows() async throws {
        let bed = "chr1\t100"  // Only 2 fields, need at least 3
        let url = try createTempFile(content: bed)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = BEDReader()

        do {
            _ = try await reader.readAll(from: url)
            XCTFail("Expected error to be thrown")
        } catch let error as BEDError {
            switch error {
            case .invalidLineFormat(let line, let minFields, let got):
                XCTAssertEqual(line, 1)
                XCTAssertEqual(minFields, 3)
                XCTAssertEqual(got, 2)
            default:
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testInvalidCoordinateThrows() async throws {
        let bed = "chr1\tabc\t200"  // Invalid start coordinate
        let url = try createTempFile(content: bed)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = BEDReader()

        do {
            _ = try await reader.readAll(from: url)
            XCTFail("Expected error to be thrown")
        } catch let error as BEDError {
            switch error {
            case .invalidCoordinate(let line, let field, _):
                XCTAssertEqual(line, 1)
                XCTAssertEqual(field, "chromStart")
            default:
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testInvalidRangeThrows() async throws {
        let bed = "chr1\t200\t100"  // Start > End
        let url = try createTempFile(content: bed)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = BEDReader()

        do {
            _ = try await reader.readAll(from: url)
            XCTFail("Expected error to be thrown")
        } catch let error as BEDError {
            switch error {
            case .invalidCoordinateRange(let line, let start, let end):
                XCTAssertEqual(line, 1)
                XCTAssertEqual(start, 200)
                XCTAssertEqual(end, 100)
            default:
                XCTFail("Wrong error type: \(error)")
            }
        }
    }

    func testDisableCoordinateValidation() async throws {
        let bed = "chr1\t200\t100"  // Start > End
        let url = try createTempFile(content: bed)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = BEDReader(validateCoordinates: false)
        let features = try await reader.readAll(from: url)

        // Should not throw when validation is disabled
        XCTAssertEqual(features.count, 1)
    }

    // MARK: - Conversion Tests

    func testConvertToAnnotation() async throws {
        let url = try createTempFile(content: sampleBED6)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = BEDReader()
        let annotations = try await reader.readAsAnnotations(from: url)

        XCTAssertEqual(annotations.count, 3)

        let first = annotations[0]
        XCTAssertEqual(first.name, "feature1")
        XCTAssertEqual(first.start, 100)
        XCTAssertEqual(first.end, 200)
        XCTAssertEqual(first.strand, .forward)
    }

    func testConvertBED12ToAnnotation() async throws {
        let url = try createTempFile(content: sampleBED12)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = BEDReader()
        let annotations = try await reader.readAsAnnotations(from: url)

        XCTAssertEqual(annotations.count, 1)

        let annotation = annotations[0]
        // BED12 with blocks creates multiple intervals
        XCTAssertEqual(annotation.intervals.count, 3)
        XCTAssertEqual(annotation.intervals[0].start, 100)
        XCTAssertEqual(annotation.intervals[0].end, 150)
    }

    // MARK: - Feature Length Test

    func testFeatureLength() async throws {
        let url = try createTempFile(content: sampleBED3)
        defer { try? FileManager.default.removeItem(at: url) }

        let reader = BEDReader()
        let features = try await reader.readAll(from: url)

        XCTAssertEqual(features[0].length, 100)  // 200 - 100
    }

    // MARK: - Writer Tests

    func testWriteBED() throws {
        let features = [
            BEDFeature(chrom: "chr1", chromStart: 100, chromEnd: 200, name: "test1", score: 500, strand: .forward),
            BEDFeature(chrom: "chr2", chromStart: 300, chromEnd: 400, name: "test2", score: 800, strand: .reverse)
        ]

        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("test_write_\(UUID().uuidString).bed")
        defer { try? FileManager.default.removeItem(at: url) }

        try BEDWriter.write(features, to: url, columns: 6)

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n")

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("chr1\t100\t200\ttest1"))
        XCTAssertTrue(lines[1].hasPrefix("chr2\t300\t400\ttest2"))
    }
}
