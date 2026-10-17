// BlastVerifyRecordedArgvPinTests.swift - `blast verify`'s recorded command lines still replay
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
@testable import LungfishCLI

/// Phase 2.11 lane A65 M1, step 2 (plan decision C1, BIO condition 4). `blast submit` joins the
/// `blast` group beside `verify`, and the argvs that `blast verify` records keep parsing to the same
/// command with the same values. Both spellings a record can hold are pinned, the leaf named and the
/// group's default subcommand. It passes at the base, before the group gains its second leaf.
final class BlastVerifyRecordedArgvPinTests: XCTestCase {
    /// What `--result-dir` runs record, the words after `lungfish blast`.
    static let recorded = [
        "verify", "--kreport", "classification.kreport", "--source", "reads_R1.fastq.gz",
        "--source", "reads_R2.fastq.gz", "--kraken-output", "classification.kraken", "--taxid", "562",
        "--reads", "30", "--seed", "7", "--max-concurrent", "2", "--include-children",
        "--extra-args", "WORD_SIZE=11", "--result-dir", "kraken2-run",
    ]

    func testARecordedVerifyArgvParsesToTheSameVerify() throws {
        let parsed = try BlastCommand.parseAsRoot(Self.recorded)
        let verify = try XCTUnwrap(parsed as? BlastCommand.VerifySubcommand)
        XCTAssertEqual(verify.kreportFile, "classification.kreport")
        XCTAssertEqual(verify.sourcePaths, ["reads_R1.fastq.gz", "reads_R2.fastq.gz"])
        XCTAssertEqual(verify.krakenOutput, "classification.kraken")
        XCTAssertEqual(verify.taxId, 562)
        XCTAssertEqual(verify.readCount, 30)
        XCTAssertEqual(verify.seed, 7)
        XCTAssertEqual(verify.maxConcurrent, 2)
        XCTAssertTrue(verify.includeChildren)
        XCTAssertEqual(verify.extraArgs, "WORD_SIZE=11")
        XCTAssertEqual(verify.resultDirectory, "kraken2-run")
    }

    func testTheGroupStillDefaultsToVerify() throws {
        let parsed = try BlastCommand.parseAsRoot(Array(Self.recorded.dropFirst()))
        let verify = try XCTUnwrap(parsed as? BlastCommand.VerifySubcommand, "lungfish blast <options> runs verify")
        XCTAssertEqual(verify.taxId, 562)
        XCTAssertEqual(verify.resultDirectory, "kraken2-run")
    }

    func testTheArchiveDefaultArgvStillNamesVerify() throws {
        let parsed = try BlastCommand.parseAsRoot([
            "verify", "--kreport", "a.kreport", "--source", "a.fastq", "--kraken-output", "a.kraken", "--taxid", "9606",
        ])
        let verify = try XCTUnwrap(parsed as? BlastCommand.VerifySubcommand)
        XCTAssertEqual(verify.readCount, 20)
        XCTAssertEqual(verify.seed, 0)
        XCTAssertEqual(verify.maxConcurrent, 1)
        XCTAssertFalse(verify.includeChildren)
        XCTAssertNil(verify.resultDirectory)
    }
}
