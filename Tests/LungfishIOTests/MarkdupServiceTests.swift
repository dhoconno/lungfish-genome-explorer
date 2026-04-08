// MarkdupServiceTests.swift - Unit tests for MarkdupService
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishIO

final class MarkdupServiceTests: XCTestCase {

    private var samtoolsPath: String {
        guard let path = BamFixtureBuilder.locateSamtools() else {
            XCTFail("samtools not available; cannot run markdup tests")
            return ""
        }
        return path
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdupSvcTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Creates a BAM with 5 reads at the same position (all duplicates of each other
    /// by position+strand heuristic).
    private func makeBamWithDuplicates(at url: URL) throws {
        let refs = [BamFixtureBuilder.Reference(name: "chr1", length: 1000)]
        let seq = String(repeating: "A", count: 50)
        let qual = String(repeating: "I", count: 50)
        let reads = (0..<5).map { i in
            BamFixtureBuilder.Read(
                qname: "read\(i)", flag: 0, rname: "chr1",
                pos: 100, mapq: 60, cigar: "50M", seq: seq, qual: qual
            )
        }
        try BamFixtureBuilder.makeBAM(at: url, references: refs, reads: reads, samtoolsPath: samtoolsPath)
    }

    // MARK: - Basic operation

    func testMarkdupOnSyntheticBAM() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        let result = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)

        XCTAssertFalse(result.wasAlreadyMarkduped, "First call should not be a no-op")
        XCTAssertEqual(result.totalReads, 5, "All 5 reads should be counted as total")
        XCTAssertGreaterThan(result.duplicateReads, 0, "At least some reads should be marked as duplicates")
    }

    func testMarkdupGeneratesIndex() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        _ = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)

        let baiURL = URL(fileURLWithPath: bamURL.path + ".bai")
        XCTAssertTrue(FileManager.default.fileExists(atPath: baiURL.path), ".bai file must exist after markdup")
    }

    func testMarkdupPreservesCoordinateSortOrder() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        _ = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)

        // Read the header and verify SO:coordinate
        let process = Process()
        process.executableURL = URL(fileURLWithPath: samtoolsPath)
        process.arguments = ["view", "-H", bamURL.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let header = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(header.contains("SO:coordinate"), "Output BAM must be coordinate-sorted")
    }

    // MARK: - Idempotency

    func testIsAlreadyMarkdupedFalseOnUntouched() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        XCTAssertFalse(MarkdupService.isAlreadyMarkduped(bamURL: bamURL, samtoolsPath: samtoolsPath))
    }

    func testIsAlreadyMarkdupedTrueAfterMarkdup() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        _ = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)

        XCTAssertTrue(MarkdupService.isAlreadyMarkduped(bamURL: bamURL, samtoolsPath: samtoolsPath))
    }

    func testMarkdupIdempotentSecondRun() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        _ = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)
        let second = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)

        XCTAssertTrue(second.wasAlreadyMarkduped, "Second run should detect existing markdup")
    }

    func testMarkdupForceReRuns() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        _ = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)
        let forced = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath, force: true)

        XCTAssertFalse(forced.wasAlreadyMarkduped, "Force should re-run even if already marked")
    }

    // MARK: - countReads

    func testCountReadsTotal() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        let total = try MarkdupService.countReads(
            bamURL: bamURL, accession: nil, flagFilter: 0x004, samtoolsPath: samtoolsPath
        )
        XCTAssertEqual(total, 5)
    }

    func testCountReadsPerAccession() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        let chr1Count = try MarkdupService.countReads(
            bamURL: bamURL, accession: "chr1", flagFilter: 0x004, samtoolsPath: samtoolsPath
        )
        XCTAssertEqual(chr1Count, 5)
    }

    func testCountReadsExcludingDuplicatesAfterMarkdup() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        _ = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)

        let nonDup = try MarkdupService.countReads(
            bamURL: bamURL, accession: nil, flagFilter: 0x404, samtoolsPath: samtoolsPath
        )
        XCTAssertLessThan(nonDup, 5, "Non-duplicate count must be less than total 5 (all duplicates)")
    }

    // MARK: - Errors

    func testMarkdupThrowsOnMissingBAM() {
        let bamURL = URL(fileURLWithPath: "/nonexistent/path.bam")
        XCTAssertThrowsError(try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)) { error in
            guard case MarkdupError.fileNotFound = error else {
                XCTFail("Expected fileNotFound, got \(error)")
                return
            }
        }
    }

    // MARK: - Directory walking

    func testMarkdupDirectory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bam1 = dir.appendingPathComponent("a.bam")
        let bam2 = dir.appendingPathComponent("subdir/b.bam")
        try makeBamWithDuplicates(at: bam1)
        try makeBamWithDuplicates(at: bam2)

        let results = try MarkdupService.markdupDirectory(dir, samtoolsPath: samtoolsPath)
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { !$0.wasAlreadyMarkduped })
    }
}
