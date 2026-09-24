// MarkdupServiceTests.swift - Unit tests for MarkdupService
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
import LungfishTestSupport
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

    // MARK: - SCI-17: pipeline robustness

    /// A mid-pipeline failure (the `sort -n` stage) must fail the whole
    /// pipeline, not be masked by a successful exit from the final stage.
    /// This requires `set -o pipefail` in the shell pipeline.
    func testMarkdupFailsWhenFirstPipelineStageFails() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        // Preserve the original bytes so we can prove they are untouched
        // after the failed run.
        let originalBytes = try Data(contentsOf: bamURL)

        // A fake "samtools" that fails its `sort -n` invocation (simulating
        // a corrupt/truncated input) but succeeds at every later stage, so
        // only `set -o pipefail` can make the overall pipeline fail.
        let fakeBin = dir.appendingPathComponent("fakebin", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
        let fakeSamtools = fakeBin.appendingPathComponent("samtools")
        try """
        #!/bin/sh
        if [ "$1" = "sort" ] && [ "$2" = "-n" ]; then
          echo "fake sort -n failure" 1>&2
          exit 1
        fi
        # Every later stage in the pipe succeeds and passes nothing through,
        # which would previously exit 0 overall despite the first failure.
        exit 0
        """.write(to: fakeSamtools, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeSamtools.path)

        XCTAssertThrowsError(
            try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: fakeSamtools.path)
        ) { error in
            guard case MarkdupError.pipelineFailed = error else {
                XCTFail("Expected pipelineFailed, got \(error)")
                return
            }
        }

        // The original BAM must be untouched: no partial/corrupt swap.
        let bytesAfterFailure = try Data(contentsOf: bamURL)
        XCTAssertEqual(bytesAfterFailure, originalBytes, "Original BAM must survive a failed pipeline stage")

        // No leftover temp files.
        let tempBamURL = URL(fileURLWithPath: bamURL.path + ".markdup.tmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempBamURL.path))
    }

    /// Paths containing shell-significant characters (`$`, a space, a
    /// double quote) must not break or be reinterpreted by the pipeline,
    /// since the input/output paths are passed as argv, not interpolated
    /// inside double-quoted shell text.
    /// The result's `totalReads`/`duplicateReads` must count primary reads,
    /// not alignment records: secondary and supplementary records for the
    /// same 5 primary reads must not inflate either count (SCI-17).
    func testMarkdupResultCountsPrimaryReadsNotAlignmentRecords() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bamURL = dir.appendingPathComponent("test.bam")

        let refs = [BamFixtureBuilder.Reference(name: "chr1", length: 1000)]
        let seq = String(repeating: "A", count: 50)
        let qual = String(repeating: "I", count: 50)
        var reads: [BamFixtureBuilder.Read] = (0..<5).map { i in
            BamFixtureBuilder.Read(
                qname: "read\(i)", flag: 0, rname: "chr1",
                pos: 100, mapq: 60, cigar: "50M", seq: seq, qual: qual
            )
        }
        // Add secondary (0x100) and supplementary (0x800) records for two of
        // the five primary reads. Before the fix these inflated both
        // `totalReads` (via flag 0x004) and the non-duplicate count.
        reads.append(BamFixtureBuilder.Read(
            qname: "read0", flag: 0x100, rname: "chr1",
            pos: 100, mapq: 0, cigar: "50M", seq: "*", qual: "*"
        ))
        reads.append(BamFixtureBuilder.Read(
            qname: "read1", flag: 0x800, rname: "chr1",
            pos: 100, mapq: 60, cigar: "50M", seq: seq, qual: qual
        ))
        try BamFixtureBuilder.makeBAM(at: bamURL, references: refs, reads: reads, samtoolsPath: samtoolsPath)

        let result = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)

        XCTAssertEqual(result.totalReads, 5, "7 alignment records (5 primary + 1 secondary + 1 supplementary) must count as 5 reads")
        XCTAssertLessThanOrEqual(result.duplicateReads, 5)
    }

    func testMarkdupHandlesPathsWithShellSignificantCharacters() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let weirdDir = dir.appendingPathComponent("weird $dir \"quoted\"", isDirectory: true)
        try FileManager.default.createDirectory(at: weirdDir, withIntermediateDirectories: true)
        let bamURL = weirdDir.appendingPathComponent("test.bam")
        try makeBamWithDuplicates(at: bamURL)

        let result = try MarkdupService.markdup(bamURL: bamURL, samtoolsPath: samtoolsPath)

        XCTAssertFalse(result.wasAlreadyMarkduped)
        XCTAssertEqual(result.totalReads, 5)
        XCTAssertTrue(MarkdupService.isAlreadyMarkduped(bamURL: bamURL, samtoolsPath: samtoolsPath))
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
