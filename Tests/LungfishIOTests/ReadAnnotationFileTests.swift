import XCTest
@testable import LungfishIO

final class ReadAnnotationFileTests: XCTestCase {

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("read-annot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Write + Load Round Trip

    func testWriteAndLoadRoundTrip() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let annotations = [
            ReadAnnotationFile.Annotation(
                readID: "read1",
                mate: 0,
                annotationType: "barcode_5p",
                start: 0,
                end: 24,
                strand: "+",
                label: "BC1001",
                metadata: ["kit": "SQK-NBD114-96", "error_rate": "0.15"]
            ),
            ReadAnnotationFile.Annotation(
                readID: "read1",
                mate: 0,
                annotationType: "barcode_3p",
                start: 130,
                end: 150,
                strand: "+",
                label: "BC1001"
            ),
            ReadAnnotationFile.Annotation(
                readID: "read2",
                mate: 1,
                annotationType: "adapter_5p",
                start: 0,
                end: 33,
                strand: "-",
                label: "VNP adapter"
            ),
        ]

        let url = tempDir.appendingPathComponent(ReadAnnotationFile.filename)
        try ReadAnnotationFile.write(annotations, to: url)

        let loaded = try ReadAnnotationFile.load(from: url)
        XCTAssertEqual(loaded.count, 3)

        // Check first annotation
        XCTAssertEqual(loaded[0].readID, "read1")
        XCTAssertEqual(loaded[0].annotationType, "barcode_5p")
        XCTAssertEqual(loaded[0].start, 0)
        XCTAssertEqual(loaded[0].end, 24)
        XCTAssertEqual(loaded[0].label, "BC1001")
        XCTAssertEqual(loaded[0].metadata["kit"], "SQK-NBD114-96")
        XCTAssertEqual(loaded[0].metadata["error_rate"], "0.15")

        // Check third annotation (different strand)
        XCTAssertEqual(loaded[2].strand, "-")
        XCTAssertEqual(loaded[2].mate, 1)
    }

    func testFormatHeaderWritten() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("test.tsv")
        try ReadAnnotationFile.write([
            ReadAnnotationFile.Annotation(readID: "r1", annotationType: "barcode_5p", start: 0, end: 24, label: "BC01"),
        ], to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix(ReadAnnotationFile.formatHeader))
        XCTAssertTrue(content.contains("read_id\tmate\ttype\tstart\tend\tstrand\tlabel\tmetadata"))
    }

    func testAtomicWriteNoTmpLeftBehind() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("annot.tsv")
        try ReadAnnotationFile.write([
            ReadAnnotationFile.Annotation(readID: "r1", annotationType: "test", start: 0, end: 10, label: "X"),
        ], to: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("tmp").path))
    }

    // MARK: - Filtered Load

    func testLoadWithReadIDFilter() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let annotations = [
            ReadAnnotationFile.Annotation(readID: "read1", annotationType: "barcode_5p", start: 0, end: 24, label: "BC01"),
            ReadAnnotationFile.Annotation(readID: "read2", annotationType: "barcode_5p", start: 0, end: 24, label: "BC02"),
            ReadAnnotationFile.Annotation(readID: "read3", annotationType: "barcode_5p", start: 0, end: 24, label: "BC03"),
            ReadAnnotationFile.Annotation(readID: "read1", annotationType: "barcode_3p", start: 130, end: 150, label: "BC01"),
        ]

        let url = tempDir.appendingPathComponent("annot.tsv")
        try ReadAnnotationFile.write(annotations, to: url)

        let filtered = try ReadAnnotationFile.load(from: url, readIDs: Set(["read1", "read3"]))
        XCTAssertEqual(filtered.count, 3)  // 2 for read1, 1 for read3
        XCTAssertTrue(filtered.allSatisfy { $0.readID == "read1" || $0.readID == "read3" })
    }

    // MARK: - Merge and Filter

    func testMergeParentAndNewAnnotations() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Write parent annotations
        let parentURL = tempDir.appendingPathComponent("parent-annot.tsv")
        try ReadAnnotationFile.write([
            ReadAnnotationFile.Annotation(readID: "read1", annotationType: "orient_marker", start: 0, end: 150, label: "RC"),
            ReadAnnotationFile.Annotation(readID: "read2", annotationType: "orient_marker", start: 0, end: 140, label: "RC"),
            ReadAnnotationFile.Annotation(readID: "read99", annotationType: "orient_marker", start: 0, end: 100, label: "RC"),
        ], to: parentURL)

        // New annotations for subset
        let newAnnotations = [
            ReadAnnotationFile.Annotation(readID: "read1", annotationType: "barcode_5p", start: 0, end: 24, label: "BC01"),
            ReadAnnotationFile.Annotation(readID: "read2", annotationType: "barcode_5p", start: 0, end: 24, label: "BC02"),
        ]

        let readIDs: Set<String> = ["read1", "read2"]
        let merged = try ReadAnnotationFile.mergeAndFilter(
            parentURL: parentURL,
            newAnnotations: newAnnotations,
            readIDs: readIDs
        )

        // Should have 2 parent annotations (read1 + read2, not read99) + 2 new
        XCTAssertEqual(merged.count, 4)
        let orientCount = merged.filter { $0.annotationType == "orient_marker" }.count
        let barcodeCount = merged.filter { $0.annotationType == "barcode_5p" }.count
        XCTAssertEqual(orientCount, 2)
        XCTAssertEqual(barcodeCount, 2)
    }

    func testMergeWithNoParent() throws {
        let newAnnotations = [
            ReadAnnotationFile.Annotation(readID: "read1", annotationType: "barcode_5p", start: 0, end: 24, label: "BC01"),
        ]
        let merged = try ReadAnnotationFile.mergeAndFilter(
            parentURL: nil,
            newAnnotations: newAnnotations,
            readIDs: Set(["read1"])
        )
        XCTAssertEqual(merged.count, 1)
    }

    // MARK: - Edge Cases

    func testEmptyAnnotationsRoundTrip() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("empty.tsv")
        try ReadAnnotationFile.write([], to: url)

        let loaded = try ReadAnnotationFile.load(from: url)
        XCTAssertTrue(loaded.isEmpty)
    }

    func testAnnotationWithEmptyMetadata() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("annot.tsv")
        try ReadAnnotationFile.write([
            ReadAnnotationFile.Annotation(readID: "r1", annotationType: "test", start: 0, end: 10, label: "X"),
        ], to: url)

        let loaded = try ReadAnnotationFile.load(from: url)
        XCTAssertEqual(loaded.count, 1)
        XCTAssertTrue(loaded[0].metadata.isEmpty)
    }

    func testAnnotationLength() {
        let annotation = ReadAnnotationFile.Annotation(
            readID: "read1",
            annotationType: "barcode_5p",
            start: 10,
            end: 34,
            label: "BC01"
        )
        XCTAssertEqual(annotation.length, 24)
    }

    func testMalformedLinesSkipped() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("annot.tsv")
        var content = "\(ReadAnnotationFile.formatHeader)\n"
        content += "read_id\tmate\ttype\tstart\tend\tstrand\tlabel\tmetadata\n"
        content += "read1\t0\tbarcode_5p\t0\t24\t+\tBC01\t\n"          // valid
        content += "read2\t0\tbarcode_5p\tNaN\t24\t+\tBC02\t\n"       // invalid start
        content += "read3\t0\tbarcode_5p\t-5\t24\t+\tBC03\t\n"        // negative start
        content += "too_few_columns\n"                                   // too few columns
        content += "read4\t0\tbarcode_5p\t0\t30\t+\tBC04\tkit=X\n"    // valid with metadata
        try content.write(to: url, atomically: true, encoding: .utf8)

        let loaded = try ReadAnnotationFile.load(from: url)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].readID, "read1")
        XCTAssertEqual(loaded[1].readID, "read4")
        XCTAssertEqual(loaded[1].metadata["kit"], "X")
    }

    func testMetadataWithMultipleKeyValuePairs() throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let url = tempDir.appendingPathComponent("annot.tsv")
        try ReadAnnotationFile.write([
            ReadAnnotationFile.Annotation(
                readID: "r1",
                annotationType: "barcode_5p",
                start: 0,
                end: 24,
                label: "BC01",
                metadata: ["kit": "SQK-NBD114-96", "error_rate": "0.15", "score": "42"]
            ),
        ], to: url)

        let loaded = try ReadAnnotationFile.load(from: url)
        XCTAssertEqual(loaded[0].metadata.count, 3)
        XCTAssertEqual(loaded[0].metadata["kit"], "SQK-NBD114-96")
        XCTAssertEqual(loaded[0].metadata["error_rate"], "0.15")
        XCTAssertEqual(loaded[0].metadata["score"], "42")
    }
}
