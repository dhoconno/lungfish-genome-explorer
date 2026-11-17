// ExtractReadsSampleListRefusalTests.swift - extract reads gives a TaxTriage sample no BAM of a longer sample of its list
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// S1 sweep 2026-11-17, lane EXTRACT-SAMPLELIST (BIO-THREE-ROWS items 5 to 7 and section 2), row EXTRACT-SCAN-EXTENDED-ID.
// `extract reads --by-classifier --tool taxtriage --sample S1` on a result with no `taxtriage.sqlite`, whose
// `samplesheet.csv` names S1 and S1_2 and whose `minimap2/` holds only `S1_2.bam`, read that file as S1's, since its name
// fits S1 too. The file belongs to S1_2, a longer sample id of the same list, so the command now ends in the missing-BAM
// refusal before any read is written. The refusal comes before samtools, so the case needs no tool and runs in the unit
// tier.

import XCTest
import ArgumentParser
import LungfishIO
import LungfishTestSupport
import LungfishWorkflow
@testable import LungfishCLI

final class ExtractReadsSampleListRefusalTests: XCTestCase {

    /// BIO's CLI case of section 2, item 3. Red at the base, which goes on to samtools with `S1_2.bam`.
    func testExtractReadsWritesNothingForASampleWhoseOnlyFitBelongsToALongerSampleOfTheList() async throws {
        let root = try TestTempDirectory.make(prefix: "ExtractSampleList")
        defer { TestTempDirectory.cleanup(root) }
        let result = root.appendingPathComponent("Run.lungfish/Analyses/taxtriage-run", isDirectory: true)
        try writeResult(at: result)
        let output = root.appendingPathComponent("samplelist-out.fastq").standardizedFileURL
        let argv = [
            "--by-classifier", "--tool", "taxtriage", "--result", result.path,
            "--sample", "S1", "--accession", "NC_001", "-o", output.path,
        ]
        var cmd = try ExtractReadsSubcommand.parse(argv)
        cmd.testingRawArgs = argv
        try cmd.validate()
        do {
            try await cmd.run()
            XCTFail("Expected the missing-BAM refusal for S1, whose only fit belongs to S1_2")
        } catch {
            XCTAssertEqual(
                ExtractReadsSubcommand.message(for: error),
                "No BAM file found for sample 'S1'. The classifier result may be corrupted or imported without the "
                    + "underlying alignment data."
            )
            XCTAssertNotEqual(ExtractReadsSubcommand.exitCode(for: error).rawValue, 0, "a refusal exits nonzero")
        }
        let written = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("samplelist-out") }
        XCTAssertEqual(written, [], "A refusal writes no output")
    }

    /// BIO-THREE-ROWS item 7, the kind of the AFFECTED row. The record of an extraction from a TaxTriage result, made as
    /// `recordProvenance` makes it (`ExtractReadsCommand.swift:513-528`) from the command's own options and argv, is the
    /// kind `taxTriageReadExtraction`, and the record of an EsViritu extraction is no kind. A finished run needs samtools,
    /// so the case builds the record from the command's parts with the recorder its run calls.
    func testTheRecordOfATaxTriageExtractionIsTheKindOfItsAffectedRow() async throws {
        let root = try TestTempDirectory.make(prefix: "ExtractSampleListRecord")
        defer { TestTempDirectory.cleanup(root) }
        let cases: [(tool: String, kind: AffectedResultKind?)] = [("taxtriage", .taxTriageReadExtraction), ("esviritu", nil)]
        for (tool, kind) in cases {
            let output = root.appendingPathComponent("\(tool)-out.fastq")
            let argv = [
                "--by-classifier", "--tool", tool, "--result", root.path,
                "--sample", "S1", "--accession", "NC_001", "-o", output.path,
            ]
            var cmd = try ExtractReadsSubcommand.parse(argv)
            cmd.testingRawArgs = argv
            let folder = root.appendingPathComponent(tool, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("@r1\nACGT\n+\nIIII\n".utf8).write(to: output)
            let record = try await CLIProvenanceSupport.recordSingleStepRun(
                name: "lungfish extract reads",
                parameters: cmd.strategyParameterValues(alignmentIndexURL: nil),
                toolName: "lungfish extract reads",
                toolVersion: WorkflowRun.currentAppVersion,
                command: cmd.provenanceCommand(outputURL: output),
                inputs: [], outputs: [ProvenanceRecorder.fileRecord(url: output, role: .output)],
                exitCode: 0, wallTime: 0, stderr: nil, status: .completed,
                outputDirectory: folder, writeFileSidecars: false
            )
            XCTAssertEqual(record.workflowName, AffectedResults.RecordName.extractReads, tool)
            XCTAssertEqual(AffectedResults.kind(of: record), kind, tool)
        }
    }

    // MARK: - Fixtures

    /// A TaxTriage result in `result` with no database, a `samplesheet.csv` that names S1 and S1_2 as a run of LGE writes
    /// it, and only `minimap2/S1_2.bam`, which holds no reads.
    private func writeResult(at result: URL) throws {
        let bam = result.appendingPathComponent("minimap2/S1_2.bam")
        try FileManager.default.createDirectory(at: bam.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x1F, 0x8B]).write(to: bam)
        let samples = ["S1", "S1_2"].map {
            TaxTriageSample(sampleId: $0, fastq1: URL(fileURLWithPath: "/reads/\($0)_R1.fastq.gz"))
        }
        try TaxTriageSamplesheetBuilder().write(samples, to: result.appendingPathComponent("samplesheet.csv"))
    }
}
