// BAMImportServiceTests.swift - Tests for BAM/CRAM import service
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
@testable import LungfishCore

final class BAMImportServiceTests: XCTestCase {

    var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BAMImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - ImportResult

    func testImportResultProperties() {
        let trackInfo = AlignmentTrackInfo(
            id: "test_track",
            name: "sample.bam",
            format: .bam,
            sourcePath: "/path/to/sample.bam",
            indexPath: "/path/to/sample.bam.bai",
            mappedReadCount: 1000,
            unmappedReadCount: 50,
            sampleNames: ["SAMPLE1"]
        )

        let result = BAMImportService.ImportResult(
            trackInfo: trackInfo,
            mappedReads: 1000,
            unmappedReads: 50,
            sampleNames: ["SAMPLE1"],
            indexWasCreated: false,
            wasSorted: false
        )

        XCTAssertEqual(result.mappedReads, 1000)
        XCTAssertEqual(result.unmappedReads, 50)
        XCTAssertEqual(result.sampleNames, ["SAMPLE1"])
        XCTAssertFalse(result.indexWasCreated)
        XCTAssertFalse(result.wasSorted)
        XCTAssertEqual(result.trackInfo.id, "test_track")
        XCTAssertEqual(result.trackInfo.format, .bam)
    }

    func testImportResultWithMultipleSamples() {
        let trackInfo = AlignmentTrackInfo(
            id: "multi_sample",
            name: "multi.bam",
            format: .bam,
            sourcePath: "/path/to/multi.bam",
            indexPath: "/path/to/multi.bam.bai",
            sampleNames: ["NA12878", "NA12891", "NA12892"]
        )

        let result = BAMImportService.ImportResult(
            trackInfo: trackInfo,
            mappedReads: 50_000_000,
            unmappedReads: 500_000,
            sampleNames: ["NA12878", "NA12891", "NA12892"],
            indexWasCreated: true,
            wasSorted: true
        )

        XCTAssertEqual(result.sampleNames.count, 3)
        XCTAssertTrue(result.indexWasCreated)
        XCTAssertTrue(result.wasSorted)
        XCTAssertEqual(result.mappedReads, 50_000_000)
    }

    // MARK: - BAMImportError

    func testBAMImportErrorFileNotFoundDescription() {
        let error = BAMImportError.fileNotFound("/path/to/missing.bam")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("missing.bam"))
        XCTAssertTrue(error.errorDescription!.contains("not found"))
    }

    func testBAMImportErrorUnsupportedFormatDescription() {
        let error = BAMImportError.unsupportedFormat("SAM files must be converted")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("SAM files must be converted"))
        XCTAssertTrue(error.errorDescription!.contains("Unsupported"))
    }

    func testBAMImportErrorIndexCreationFailedDescription() {
        let error = BAMImportError.indexCreationFailed("samtools not found")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("index"))
        XCTAssertTrue(error.errorDescription!.contains("samtools not found"))
    }

    func testBAMImportErrorStatsFailedDescription() {
        let error = BAMImportError.statsFailed("idxstats returned empty")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("statistics"))
    }

    func testBAMImportErrorManifestUpdateFailedDescription() {
        let error = BAMImportError.manifestUpdateFailed("permission denied")
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.contains("manifest"))
    }

    func testAllBAMImportErrorCasesHaveDescriptions() {
        let errors: [BAMImportError] = [
            .fileNotFound("/tmp/test.bam"),
            .unsupportedFormat("test"),
            .indexCreationFailed("test"),
            .statsFailed("test"),
            .manifestUpdateFailed("test")
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Error case \(error) should have a description")
            XCTAssertFalse(error.errorDescription!.isEmpty, "Error case \(error) should not be empty")
        }
    }

    func testBAMImportErrorConformsToLocalizedError() {
        let error: LocalizedError = BAMImportError.fileNotFound("/tmp/test.bam")
        XCTAssertNotNil(error.errorDescription)
    }

    // MARK: - File Not Found

    func testImportBAMFileNotFound() async {
        let nonExistentURL = tempDir.appendingPathComponent("does_not_exist.bam")
        let bundleURL = tempDir.appendingPathComponent("test.lungfishref")
        try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        do {
            _ = try await BAMImportService.importBAM(
                bamURL: nonExistentURL,
                bundleURL: bundleURL
            )
            XCTFail("Expected BAMImportError.fileNotFound")
        } catch let error as BAMImportError {
            if case .fileNotFound(let path) = error {
                XCTAssertTrue(path.contains("does_not_exist.bam"))
            } else {
                XCTFail("Expected .fileNotFound but got \(error)")
            }
        } catch {
            XCTFail("Expected BAMImportError but got \(type(of: error)): \(error)")
        }
    }

    // MARK: - SAM Handling

    func testImportSAMFileIsNotRejectedAsUnsupportedFormat() async {
        // SAM input is supported by normalizing to sorted BAM during import.
        // This test uses an invalid SAM payload and only verifies we do not fail
        // with the old "unsupported format" guard.
        let samURL = tempDir.appendingPathComponent("test.sam")
        try? "@HD\tVN:1.6\tSO:coordinate\n".write(to: samURL, atomically: true, encoding: .utf8)

        let bundleURL = tempDir.appendingPathComponent("test.lungfishref")
        try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        do {
            _ = try await BAMImportService.importBAM(
                bamURL: samURL,
                bundleURL: bundleURL
            )
            XCTFail("Expected import to fail for invalid test data")
        } catch let error as BAMImportError {
            if case .unsupportedFormat = error {
                XCTFail("SAM should not be rejected as unsupported format: \(error)")
            }
        } catch {
            // Non-BAMImportError failures are acceptable for invalid SAM fixture.
        }
    }

    // MARK: - Progress Handler

    func testProgressHandlerCalledOnValidation() async {
        // Progress handler should be called at least once (for validation step)
        // even if the import ultimately fails
        let bamURL = tempDir.appendingPathComponent("fake.bam")
        try? Data([0x00]).write(to: bamURL)

        let bundleURL = tempDir.appendingPathComponent("test.lungfishref")
        try? FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)

        let progressCollector = ProgressCollector()

        do {
            _ = try await BAMImportService.importBAM(
                bamURL: bamURL,
                bundleURL: bundleURL,
                progressHandler: { progress, message in
                    progressCollector.append(progress: progress, message: message)
                }
            )
        } catch {
            // Expected to fail (fake BAM file, no samtools index)
        }

        let values = progressCollector.values
        XCTAssertGreaterThan(values.count, 0, "Progress handler should be called at least once")

        // First call should be at 0.0 (validation start)
        if let first = values.first {
            XCTAssertEqual(first.0, 0.0, accuracy: 0.001, "First progress should be 0.0")
            XCTAssertFalse(first.1.isEmpty, "First message should not be empty")
        }
    }

    // MARK: - AlignmentFormat Coverage

    func testAlignmentFormatRawValues() {
        XCTAssertEqual(AlignmentFormat.bam.rawValue, "bam")
        XCTAssertEqual(AlignmentFormat.cram.rawValue, "cram")
        XCTAssertEqual(AlignmentFormat.sam.rawValue, "sam")
    }

    func testAlignmentFormatCodableRoundTrip() throws {
        for format in [AlignmentFormat.bam, .cram, .sam] {
            let encoded = try JSONEncoder().encode(format)
            let decoded = try JSONDecoder().decode(AlignmentFormat.self, from: encoded)
            XCTAssertEqual(decoded, format)
        }
    }

    // MARK: - AlignmentTrackInfo for Import

    func testAlignmentTrackInfoForBAMImport() {
        let trackInfo = AlignmentTrackInfo(
            id: "aln_abc12345",
            name: "sample.bam",
            format: .bam,
            sourcePath: "/data/sample.bam",
            sourceBookmark: "base64bookmark==",
            indexPath: "/data/sample.bam.bai",
            indexBookmark: "base64indexbookmark==",
            metadataDBPath: "alignments/aln_abc12345.stats.db",
            fileSizeBytes: 1_073_741_824,
            mappedReadCount: 30_000_000,
            unmappedReadCount: 500_000,
            sampleNames: ["NA12878"]
        )

        XCTAssertEqual(trackInfo.id, "aln_abc12345")
        XCTAssertEqual(trackInfo.format, .bam)
        XCTAssertEqual(trackInfo.sourcePath, "/data/sample.bam")
        XCTAssertNotNil(trackInfo.sourceBookmark)
        XCTAssertEqual(trackInfo.metadataDBPath, "alignments/aln_abc12345.stats.db")
        XCTAssertEqual(trackInfo.fileSizeBytes, 1_073_741_824)
        XCTAssertEqual(trackInfo.mappedReadCount, 30_000_000)
        XCTAssertEqual(trackInfo.sampleNames, ["NA12878"])
    }

    func testAlignmentTrackInfoForCRAMImport() {
        let trackInfo = AlignmentTrackInfo(
            id: "aln_cram001",
            name: "sample.cram",
            format: .cram,
            sourcePath: "/data/sample.cram",
            indexPath: "/data/sample.cram.crai",
            mappedReadCount: 20_000_000,
            unmappedReadCount: 100_000,
            sampleNames: ["HG002"]
        )

        XCTAssertEqual(trackInfo.format, .cram)
        XCTAssertEqual(trackInfo.indexPath, "/data/sample.cram.crai")
        XCTAssertNil(trackInfo.sourceBookmark)
        XCTAssertNil(trackInfo.metadataDBPath)
    }

    // MARK: - DocumentType Detection

    func testDocumentTypeDetectsBAM() {
        let extensions = ["bam", "cram", "sam"]
        for ext in extensions {
            let url = tempDir.appendingPathComponent("test.\(ext)")
            let detected = DocumentType.detect(from: url)
            XCTAssertEqual(detected, .bam, "Expected .bam for extension '\(ext)' but got \(String(describing: detected))")
        }
    }

    func testDocumentTypeBAMExtensions() {
        let bamType = DocumentType.bam
        XCTAssertTrue(bamType.extensions.contains("bam"))
        XCTAssertTrue(bamType.extensions.contains("cram"))
        XCTAssertTrue(bamType.extensions.contains("sam"))
    }
}

// MARK: - ProgressCollector

/// Thread-safe collector for progress callbacks.
private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [(Double, String)] = []

    var values: [(Double, String)] {
        lock.lock()
        defer { lock.unlock() }
        return _values
    }

    func append(progress: Double, message: String) {
        lock.lock()
        defer { lock.unlock() }
        _values.append((progress, message))
    }
}
