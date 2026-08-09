// ExtractReadsByIdBAMCLITests.swift — Parse tests for `--by-id --bam` (BAM-source read-ID extraction)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Item 3 (mapping viewer fixes, 2026-08-09), CLI parity (spec E / arch Finding 8):
// `--by-id` gains a `--bam <path>` mode alongside its existing `--source`
// (FASTQ) mode. These are parse-level tests only — process/samtools
// integration coverage lives in LungfishIntegrationTests
// (ExtractReadsByIdBAMProcessTests.swift).

import XCTest
import ArgumentParser
@testable import LungfishCLI

final class ExtractReadsByIdBAMCLITests: XCTestCase {

    // MARK: - source XOR bam

    func testByIdRequiresEitherSourceOrBam() throws {
        XCTAssertThrowsError(
            try ExtractReadsSubcommand.parse([
                "--by-id",
                "--ids", "/tmp/ids.txt",
                "-o", "/tmp/out.fastq",
            ])
        ) { error in
            let message = ExtractReadsSubcommand.fullMessage(for: error).lowercased()
            XCTAssertTrue(
                message.contains("--source") || message.contains("--bam"),
                "Expected the validation error to mention --source/--bam, got: \(message)"
            )
        }
    }

    func testByIdRejectsBothSourceAndBam() throws {
        XCTAssertThrowsError(
            try ExtractReadsSubcommand.parse([
                "--by-id",
                "--ids", "/tmp/ids.txt",
                "--source", "/tmp/reads.fastq",
                "--bam", "/tmp/aligned.bam",
                "-o", "/tmp/out.fastq",
            ])
        ) { error in
            let message = ExtractReadsSubcommand.fullMessage(for: error).lowercased()
            XCTAssertTrue(
                message.contains("--source") && message.contains("--bam"),
                "Expected a mutual-exclusion message naming both --source and --bam, got: \(message)"
            )
        }
    }

    func testByIdWithBamAloneParsesAndValidates() throws {
        let cmd = try ExtractReadsSubcommand.parse([
            "--by-id",
            "--ids", "/tmp/ids.txt",
            "--bam", "/tmp/aligned.bam",
            "-o", "/tmp/out.fastq",
        ])
        XCTAssertNoThrow(try cmd.validate())
    }

    // MARK: - --no-keep-read-pairs is a validation ERROR in BAM mode

    func testNoKeepReadPairsIsRejectedInBAMMode() throws {
        XCTAssertThrowsError(
            try ExtractReadsSubcommand.parse([
                "--by-id",
                "--ids", "/tmp/ids.txt",
                "--bam", "/tmp/aligned.bam",
                "--no-keep-read-pairs",
                "-o", "/tmp/out.fastq",
            ])
        ) { error in
            let message = ExtractReadsSubcommand.fullMessage(for: error).lowercased()
            XCTAssertTrue(
                message.contains("--no-keep-read-pairs") && message.contains("--bam"),
                "Expected --no-keep-read-pairs rejected in BAM mode, got: \(message)"
            )
        }
    }

    func testKeepReadPairsFlagAloneIsHarmlessInBAMMode() throws {
        // --keep-read-pairs (the affirmative flag, not --no-keep-read-pairs)
        // is not meaningful in BAM mode (pairing is automatic by QNAME), but
        // is not an error either -- it's simply a no-op there.
        let cmd = try ExtractReadsSubcommand.parse([
            "--by-id",
            "--ids", "/tmp/ids.txt",
            "--bam", "/tmp/aligned.bam",
            "--keep-read-pairs",
            "-o", "/tmp/out.fastq",
        ])
        XCTAssertNoThrow(try cmd.validate())
    }

    // MARK: - --no-keep-read-pairs remains fine in FASTQ (--source) mode

    func testNoKeepReadPairsStillValidInSourceMode() throws {
        let cmd = try ExtractReadsSubcommand.parse([
            "--by-id",
            "--ids", "/tmp/ids.txt",
            "--source", "/tmp/reads.fastq",
            "--no-keep-read-pairs",
            "-o", "/tmp/out.fastq",
        ])
        XCTAssertNoThrow(try cmd.validate())
    }

    // MARK: - --read-format extended to --by-id (both source and bam modes)

    func testReadFormatDefaultsToFastqOnByIdBamMode() throws {
        let cmd = try ExtractReadsSubcommand.parse([
            "--by-id",
            "--ids", "/tmp/ids.txt",
            "--bam", "/tmp/aligned.bam",
            "-o", "/tmp/out.fastq",
        ])
        XCTAssertEqual(cmd.makeExtractionOptions().format.rawValue, "fastq")
    }

    func testReadFormatFastaAcceptedOnByIdBamMode() throws {
        let cmd = try ExtractReadsSubcommand.parse([
            "--by-id",
            "--ids", "/tmp/ids.txt",
            "--bam", "/tmp/aligned.bam",
            "--read-format", "fasta",
            "-o", "/tmp/out.fastq",
        ])
        XCTAssertNoThrow(try cmd.validate())
    }

    func testReadFormatInvalidValueRejectedOnByIdBamMode() throws {
        XCTAssertThrowsError(
            try ExtractReadsSubcommand.parse([
                "--by-id",
                "--ids", "/tmp/ids.txt",
                "--bam", "/tmp/aligned.bam",
                "--read-format", "bam",
                "-o", "/tmp/out.fastq",
            ])
        )
    }

    // MARK: - --include-secondary / --exclude-duplicates only make sense in BAM mode

    func testIncludeSecondaryRejectedInSourceMode() throws {
        XCTAssertThrowsError(
            try ExtractReadsSubcommand.parse([
                "--by-id",
                "--ids", "/tmp/ids.txt",
                "--source", "/tmp/reads.fastq",
                "--include-secondary",
                "-o", "/tmp/out.fastq",
            ])
        ) { error in
            let message = ExtractReadsSubcommand.fullMessage(for: error).lowercased()
            XCTAssertTrue(message.contains("--include-secondary") && message.contains("--bam"))
        }
    }

    func testExcludeDuplicatesRejectedInSourceMode() throws {
        XCTAssertThrowsError(
            try ExtractReadsSubcommand.parse([
                "--by-id",
                "--ids", "/tmp/ids.txt",
                "--source", "/tmp/reads.fastq",
                "--exclude-duplicates",
                "-o", "/tmp/out.fastq",
            ])
        ) { error in
            let message = ExtractReadsSubcommand.fullMessage(for: error).lowercased()
            XCTAssertTrue(message.contains("--exclude-duplicates") && message.contains("--bam"))
        }
    }

    func testIncludeSecondaryAndExcludeDuplicatesAcceptedInBAMMode() throws {
        let cmd = try ExtractReadsSubcommand.parse([
            "--by-id",
            "--ids", "/tmp/ids.txt",
            "--bam", "/tmp/aligned.bam",
            "--include-secondary",
            "--exclude-duplicates",
            "-o", "/tmp/out.fastq",
        ])
        XCTAssertNoThrow(try cmd.validate())
    }
}
