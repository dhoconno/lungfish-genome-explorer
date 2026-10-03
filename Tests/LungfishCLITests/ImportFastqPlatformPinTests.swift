// ImportFastqPlatformPinTests.swift - Pins how `import fastq` spells and infers platforms (R15, owner decision 3)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishWorkflow
import LungfishTestSupport

/// Pins the `lungfish-cli import fastq --platform` values and the platform the
/// command infers when `--platform` is auto. The command used its own detector
/// and fell back to Illumina before owner decision 3. It now infers each
/// sample with `PlatformInference` and records Unknown when nothing matches.
final class ImportFastqPlatformPinTests: XCTestCase {

    func testPlatformOptionHelpListsEveryValueAndTheAutoDefault() {
        let help = ImportCommand.FastqSubcommand.helpMessage(columns: 400)
        XCTAssertTrue(
            help.contains("Sequencing platform: auto, illumina, ont, pacbio, element, mgi, ultima, unknown (default: auto)"),
            help
        )
    }

    func testThePlatformOptionParsesEveryValueAndDefaultsToAuto() throws {
        let parsed = try ImportCommand.FastqSubcommand.parse(["reads.fastq", "--project", "/tmp/p.lungfish"])
        XCTAssertEqual(parsed.platform, "auto")
        for value in ImportPlatformRequest.cliValues + ["nanopore", "oxford-nanopore", "oxfordNanopore"] {
            let command = try ImportCommand.FastqSubcommand.parse(["reads.fastq", "--project", "/tmp/p.lungfish", "--platform", value])
            XCTAssertNotNil(ImportPlatformRequest(cliValue: command.platform), value)
        }
    }

    func testAutoInferenceFromPlainFASTQHeaders() throws {
        let root = try TestTempDirectory.make(prefix: "import-fastq-platform-pin")
        defer { TestTempDirectory.cleanup(root) }

        // Before owner decision 3 the command imported every row marked
        // "illumina (fallback)" as Illumina.
        let cases: [(name: String, header: String, expected: String)] = [
            ("ont-runid", "@d3ef25a0-5d5c-4a5f-8c3b-12345abcdef runid=abc123 sampleid=sample1", "ont"),
            ("ont-basecall-gpu", "@read1 basecall_gpu=Tesla_V100", "ont"), // illumina (fallback)
            ("pacbio-sequel", "@m64011_190830_220126/101/ccs", "pacbio"),
            ("pacbio-revio", "@m84011_220902_175841_s1/12345/ccs", "pacbio"), // illumina (fallback)
            ("illumina", "@A00488:61:HMLGNDSXX:4:1101:1234:5678 1:N:0:ACGTACGT", "illumina"),
            ("illumina-miseq", "@M00123:45:000000000-ABCDE:1:1101:15589:1333 1:N:0:1", "illumina"),
            ("sra", "@SRR12345678.1 1 length=150", "unknown"), // illumina (fallback)
            ("generic", "@read1", "unknown"), // illumina (fallback)
        ]
        for row in cases {
            let url = root.appendingPathComponent("\(row.name).fastq")
            try "\(row.header)\nACGT\n+\nIIII\n".write(to: url, atomically: true, encoding: .utf8)
            let resolution = FASTQBatchImporter.resolvePlatform(
                for: SamplePair(sampleName: row.name, r1: url, r2: nil),
                request: .auto
            )
            XCTAssertEqual(resolution.platform.importCLIValue, row.expected, row.name)
        }

        // A BAM is read from its header and is never assumed to be ONT.
        let unlabelled = SamplePair(sampleName: "bam", r1: PlatformHeaderFixtures.url("unlabelled.bam"), r2: nil)
        XCTAssertEqual(FASTQBatchImporter.resolvePlatform(for: unlabelled, request: .auto).platform, .unknown)
    }
}
