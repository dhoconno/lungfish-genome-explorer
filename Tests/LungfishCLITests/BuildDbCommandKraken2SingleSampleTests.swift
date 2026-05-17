// BuildDbCommandKraken2SingleSampleTests.swift
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishIO

final class BuildDbCommandKraken2SingleSampleTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("K2SingleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Root-layout kreport (no subdirs) — build-db must still produce rows.
    func testKraken2RootLayoutSingleSample() async throws {
        let tmpDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let resultDir = tmpDir.appendingPathComponent("kraken2-2026-01-15T11-00-00")
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        // Minimal 3-line kreport (root + 2 taxa) — tab-separated
        let kreport = """
         50.00\t500\t100\tR\t1\troot
         40.00\t400\t200\tD\t2\t  Bacteria
         20.00\t200\t200\tS\t562\t    Escherichia coli
        """
        let kreportURL = resultDir.appendingPathComponent("reads.kreport")
        try kreport.write(to: kreportURL, atomically: true, encoding: .utf8)

        // Run build-db
        let cmd = try BuildDbCommand.Kraken2Subcommand.parse([resultDir.path, "-q"])
        try await cmd.run()

        // Verify DB was created with non-zero rows
        let dbURL = resultDir.appendingPathComponent("kraken2.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))

        let db = try Kraken2Database(at: dbURL)
        let samples = try db.fetchSamples()
        XCTAssertEqual(samples.count, 1, "Should produce exactly 1 sample from root-level kreport")
        XCTAssertGreaterThan(samples[0].taxonCount, 0)
    }
}
