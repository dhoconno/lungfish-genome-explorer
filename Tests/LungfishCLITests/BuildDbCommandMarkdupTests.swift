// BuildDbCommandMarkdupTests.swift - Tests that build-db uses markdup pipeline
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
@testable import LungfishIO

final class BuildDbCommandMarkdupTests: XCTestCase {

    private func locateSamtools() -> String? {
        let candidates = [
            "/opt/homebrew/Cellar/samtools/1.23/bin/samtools",
            "/opt/homebrew/bin/samtools",
            "/usr/local/bin/samtools",
            "/usr/bin/samtools",
        ]
        for p in candidates where FileManager.default.fileExists(atPath: p) {
            return p
        }
        return nil
    }

    private func findFixtureDir(_ name: String) -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("Tests/Fixtures/\(name)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        fatalError("Could not find fixture: \(name)")
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BuildDbMarkdupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// build-db taxtriage should run markdup on all BAMs in the result directory.
    func testBuildDbTaxTriageRunsMarkdup() async throws {
        guard let samtoolsPath = locateSamtools() else {
            XCTFail("samtools not available")
            return
        }

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fixture = findFixtureDir("taxtriage-mini")
        let resultDir = tmp.appendingPathComponent("taxtriage")
        try FileManager.default.copyItem(at: fixture, to: resultDir)

        let cmd = try BuildDbCommand.TaxTriageSubcommand.parse([resultDir.path, "-q"])
        try await cmd.run()

        // Verify every BAM in minimap2/ has been marked
        let minimap2Dir = resultDir.appendingPathComponent("minimap2")
        let contents = try FileManager.default.contentsOfDirectory(at: minimap2Dir, includingPropertiesForKeys: nil)
        let bams = contents.filter { $0.pathExtension == "bam" }
        XCTAssertGreaterThan(bams.count, 0, "Fixture must have BAM files")
        for bam in bams {
            XCTAssertTrue(
                MarkdupService.isAlreadyMarkduped(bamURL: bam, samtoolsPath: samtoolsPath),
                "BAM \(bam.lastPathComponent) should have been marked by build-db"
            )
        }

        // Verify unique_reads values in DB are consistent with samtools view -c -F 0x404
        let dbURL = resultDir.appendingPathComponent("taxtriage.sqlite")
        let db = try TaxTriageDatabase(at: dbURL)
        let samples = try db.fetchSamples()
        let allRows = try db.fetchRows(samples: samples.map(\.sample))
        let rowsWithBAM = allRows.filter { $0.bamPath != nil && $0.primaryAccession != nil && $0.uniqueReads != nil }
        XCTAssertGreaterThan(rowsWithBAM.count, 0, "At least some rows should have unique reads populated")

        if let row = rowsWithBAM.first {
            let bamURL = resultDir.appendingPathComponent(row.bamPath!)
            let expected = try MarkdupService.countReads(
                bamURL: bamURL,
                accession: row.primaryAccession!,
                flagFilter: 0x404,
                samtoolsPath: samtoolsPath
            )
            XCTAssertEqual(row.uniqueReads, expected, "DB unique_reads must match samtools count")
        }
    }
}
