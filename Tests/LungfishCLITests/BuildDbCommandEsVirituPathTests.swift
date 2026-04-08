// BuildDbCommandEsVirituPathTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishIO

final class BuildDbCommandEsVirituPathTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EVPathTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Stored bam_path should include sample prefix AND resolve to persistent bams/ dir
    /// so VC can resolve it directly against the result directory.
    func testEsVirituBamPathIncludesSamplePrefixAndBamsDir() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let resultDir = tmpDir.appendingPathComponent("esviritu-batch-2026-01-15T15-00-00")
        let sampleDir = resultDir.appendingPathComponent("sample1")
        let tempDir = sampleDir.appendingPathComponent("sample1_temp")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Minimal BAM placeholder (content doesn't matter for path test)
        let bamURL = tempDir.appendingPathComponent("sample1.third.filt.sorted.bam")
        FileManager.default.createFile(atPath: bamURL.path, contents: Data())

        // Minimal detection TSV with 1 row
        let header = "sample_ID\tname\tdescription\tlength\tsegment\taccession\tassembly\tassembly_length\tkingdom\tphylum\tclass\torder\tfamily\tgenus\tspecies\tsubspecies\trpkmf\tread_count\tcovered_bases\tmean_coverage\tavg_read_identity\tpi\tfiltered_reads_in_sample"
        let row = "sample1\tVirusA\tdesc\t100\t\tNC_001\tGCA_001\t1000\tVirK\tVirP\tVirC\tVirO\tVirF\tVirG\tVirS\t\t1.0\t10\t50\t2.5\t99.0\t0.01\t1000"
        try "\(header)\n\(row)".write(
            to: sampleDir.appendingPathComponent("sample1.detected_virus.info.tsv"),
            atomically: true, encoding: .utf8)

        // Run build-db with --no-cleanup so we just check the path format
        let cmd = try BuildDbCommand.EsVirituSubcommand.parse([resultDir.path, "--no-cleanup", "-q"])
        try await cmd.run()

        let dbURL = resultDir.appendingPathComponent("esviritu.sqlite")
        let db = try EsVirituDatabase(at: dbURL)
        let rows = try db.fetchRows(samples: ["sample1"])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(
            rows[0].bamPath,
            "sample1/bams/sample1.third.filt.sorted.bam",
            "bam_path must include sample prefix and resolve to persistent bams/ dir"
        )
    }
}
