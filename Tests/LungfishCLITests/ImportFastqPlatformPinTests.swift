// ImportFastqPlatformPinTests.swift - Pins how `import fastq` spells and detects platforms (R15)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishCLI
import LungfishWorkflow
import LungfishTestSupport

/// Pins the `lungfish-cli import fastq --platform` spellings and the platform
/// the command detects from a plain FASTQ header when `--platform` is absent.
/// Written before the R15 reconciliation and expected to pass unchanged after
/// it. These record today's behaviour, not a scientific ruling.
final class ImportFastqPlatformPinTests: XCTestCase {

    func testPlatformOptionHelpListsTheImportSpellings() {
        let help = ImportCommand.FastqSubcommand.helpMessage(columns: 400)
        XCTAssertTrue(
            help.contains("Sequencing platform: illumina, ont, pacbio, ultima (default: auto-detect)"),
            help
        )
    }

    func testAutoDetectionFromPlainFASTQHeaders() throws {
        let root = try TestTempDirectory.make(prefix: "import-fastq-platform-pin")
        defer { TestTempDirectory.cleanup(root) }

        // nil means the command falls back to Illumina.
        let cases: [(name: String, header: String, expected: String?)] = [
            ("ont-runid", "@d3ef25a0-5d5c-4a5f-8c3b-12345abcdef runid=abc123 sampleid=sample1", "ont"),
            ("ont-basecall-gpu", "@read1 basecall_gpu=Tesla_V100", nil),
            ("pacbio-sequel", "@m64011_190830_220126/101/ccs", "pacbio"),
            ("pacbio-revio", "@m84011_220902_175841_s1/12345/ccs", nil),
            ("illumina", "@A00488:61:HMLGNDSXX:4:1101:1234:5678 1:N:0:ACGTACGT", "illumina"),
            ("illumina-miseq", "@M00123:45:000000000-ABCDE:1:1101:15589:1333 1:N:0:1", nil),
            ("sra", "@SRR12345678.1 1 length=150", nil),
            ("generic", "@read1", nil),
        ]
        for row in cases {
            let url = root.appendingPathComponent("\(row.name).fastq")
            try "\(row.header)\nACGT\n+\nIIII\n".write(to: url, atomically: true, encoding: .utf8)
            let detected = try ImportCommand.FastqSubcommand.detectPlatformFromPairs(
                [SamplePair(sampleName: row.name, r1: url, r2: nil)]
            )
            XCTAssertEqual(detected?.rawValue, row.expected, row.name)
        }

        let bam = SamplePair(sampleName: "bam", r1: root.appendingPathComponent("reads.bam"), r2: nil)
        XCTAssertEqual(try ImportCommand.FastqSubcommand.detectPlatformFromPairs([bam])?.rawValue, "ont")
        XCTAssertNil(try ImportCommand.FastqSubcommand.detectPlatformFromPairs([]))
    }
}
