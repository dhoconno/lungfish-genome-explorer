// ExtractReadsUnmarkedFitRefusalTests.swift - extract reads refuses a sample of an older TaxTriage database in words
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1/S2 sweep, lane BUILDDB-OLDER-DB-CLI (S2). `extract reads --by-classifier --tool taxtriage` on a result whose
// `taxtriage.sqlite` was built before 2026.11.6 (no `fitted_bam_samples` key) and records `minimap2/S1_2.bam` for sample
// S1 wrote that file's reads under S1's name with no words, since `S1_2.bam` can belong to sample `S1_2`. The command
// runs the same resolver as the app, so it refuses S1 before any read is written. The run ends with an error whose words
// ArgumentParser prints on standard error after `Error: `, and the exit code is nonzero. The refusal comes before
// samtools, so the case needs no tool and runs in the unit tier.

import XCTest
import ArgumentParser
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class ExtractReadsUnmarkedFitRefusalTests: XCTestCase {

    /// The fixture of case 1 of `TaxTriageUnmarkedFitRefusalTests`, run through the command. Red at the base, which
    /// goes on to samtools with `S1_2.bam` and prints no refusal.
    func testExtractReadsRefusesAnOlderDatabasesFittedBAMInWordsAndWritesNothing() async throws {
        let root = try TestTempDirectory.make(prefix: "ExtractUnmarkedFit")
        defer { TestTempDirectory.cleanup(root) }
        let result = root.appendingPathComponent("Run.lungfish/Analyses/taxtriage-run", isDirectory: true)
        try writeOlderDatabaseResult(at: result)
        let output = root.appendingPathComponent("unmarked-out.fastq").standardizedFileURL
        let argv = [
            "--by-classifier", "--tool", "taxtriage", "--result", result.path,
            "--sample", "S1", "--accession", "NC_001", "-o", output.path,
        ]
        var cmd = try ExtractReadsSubcommand.parse(argv)
        cmd.testingRawArgs = argv
        try cmd.validate()
        do {
            try await cmd.run()
            XCTFail("Expected the refusal for a sample whose recorded BAM an older build may have fitted")
        } catch {
            XCTAssertEqual(ExtractReadsSubcommand.message(for: error), Self.words(folder: result.path))
            XCTAssertNotEqual(ExtractReadsSubcommand.exitCode(for: error).rawValue, 0, "a refusal exits nonzero")
        }
        let written = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("unmarked-out") }
        XCTAssertEqual(written, [], "A refusal writes no output")
    }

    // MARK: - Fixtures

    /// The words of the refusal for sample S1, whose recorded BAM is `S1_2.bam`, in the result folder `folder`.
    private static func words(folder: String) -> String {
        "This result's database was built by a version of Lungfish before 2026.11.6, so the BAM it records for sample "
            + "'S1', S1_2.bam, may be another sample's. No reads were extracted. "
            + "Run `lungfish-cli build-db taxtriage \"\(folder)\" --force`, then extract again."
    }

    /// A TaxTriage result in `result` whose database has no `fitted_bam_samples` key and records `minimap2/S1_2.bam` for
    /// sample S1, with that file present and no `minimap2/S1.bam`. The file holds no reads.
    private func writeOlderDatabaseResult(at result: URL) throws {
        let recorded = "minimap2/S1_2.bam"
        let bam = result.appendingPathComponent(recorded)
        try FileManager.default.createDirectory(at: bam.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x1F, 0x8B]).write(to: bam)
        let row = TaxTriageTaxonomyRow(
            sample: "S1", organism: "Alpha virus", taxId: 1001, status: nil, tassScore: 0.9, readsAligned: 40,
            uniqueReads: 20, pctReads: nil, pctAlignedReads: nil, coverageBreadth: 50, meanCoverage: nil,
            meanDepth: nil, confidence: "High", k2Reads: nil, parentK2Reads: nil, giniCoefficient: nil,
            meanBaseQ: nil, meanMapQ: nil, mapqScore: nil, disparityScore: nil, minhashScore: nil,
            diamondIdentity: nil, k2DisparityScore: nil, siblingsScore: nil, breadthWeightScore: nil,
            hhsPercentile: nil, isAnnotated: nil, annClass: nil, microbialCategory: nil, highConsequence: nil,
            isSpecies: nil, pathogenicSubstrains: nil, sampleType: nil,
            bamPath: recorded, bamIndexPath: recorded + ".bai",
            primaryAccession: "NC_1001", accessionLength: 10_000
        )
        _ = try TaxTriageDatabase.create(
            at: result.appendingPathComponent("taxtriage.sqlite"), rows: [row], metadata: ["tool": "TaxTriage"]
        )
    }
}
