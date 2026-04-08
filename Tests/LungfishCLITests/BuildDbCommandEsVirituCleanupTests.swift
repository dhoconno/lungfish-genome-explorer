// BuildDbCommandEsVirituCleanupTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishIO

final class BuildDbCommandEsVirituCleanupTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EVCleanupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// After build-db runs cleanup, the BAM referenced by the DB must still exist on disk.
    func testEsVirituBamPreservedAfterCleanup() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let resultDir = tmpDir.appendingPathComponent("esviritu-batch-2026-01-15T15-00-00")
        let sampleDir = resultDir.appendingPathComponent("sample1")
        let tempDir = sampleDir.appendingPathComponent("sample1_temp")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Put a placeholder BAM + index in _temp (build-db doesn't parse the BAM)
        let bamURL = tempDir.appendingPathComponent("sample1.third.filt.sorted.bam")
        let baiURL = tempDir.appendingPathComponent("sample1.third.filt.sorted.bam.bai")
        FileManager.default.createFile(atPath: bamURL.path, contents: Data("BAM".utf8))
        FileManager.default.createFile(atPath: baiURL.path, contents: Data("BAI".utf8))

        // Minimal detection TSV
        let header = "sample_ID\tname\tdescription\tlength\tsegment\taccession\tassembly\tassembly_length\tkingdom\tphylum\tclass\torder\tfamily\tgenus\tspecies\tsubspecies\trpkmf\tread_count\tcovered_bases\tmean_coverage\tavg_read_identity\tpi\tfiltered_reads_in_sample"
        let row = "sample1\tVirusA\tdesc\t100\t\tNC_001\tGCA_001\t1000\tVirK\tVirP\tVirC\tVirO\tVirF\tVirG\tVirS\t\t1.0\t10\t50\t2.5\t99.0\t0.01\t1000"
        try "\(header)\n\(row)".write(
            to: sampleDir.appendingPathComponent("sample1.detected_virus.info.tsv"),
            atomically: true, encoding: .utf8)

        // Run with default cleanup enabled
        let cmd = try BuildDbCommand.EsVirituSubcommand.parse([resultDir.path, "-q"])
        try await cmd.run()

        // _temp/ should be gone
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path),
                       "_temp/ should be removed by cleanup")

        // The stored bam_path from the DB should still point to a file that exists
        let db = try EsVirituDatabase(at: resultDir.appendingPathComponent("esviritu.sqlite"))
        let rows = try db.fetchRows(samples: ["sample1"])
        XCTAssertEqual(rows.count, 1)
        let storedBam = rows[0].bamPath!
        let absolute = resultDir.appendingPathComponent(storedBam).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: absolute),
                      "BAM at stored path must exist after cleanup: \(absolute)")
    }
}
