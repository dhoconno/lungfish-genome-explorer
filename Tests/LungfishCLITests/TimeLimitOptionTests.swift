// TimeLimitOptionTests.swift - The --time-limit option of the analysis commands
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
@testable import LungfishWorkflow

/// `docs/contracts/SCOPE-AND-DELIVERY.md`, Tool run time. A run has no wall-clock limit unless the person gives
/// `--time-limit <minutes>`, and the command line a run records spells the option it was given.
final class TimeLimitOptionTests: XCTestCase {

    func testKraken2ClassifyTakesATimeLimitAndRecordsItInItsCommandLine() throws {
        let limited = try XCTUnwrap(
            try ClassifyCommand.parseAsRoot(["reads.fastq.gz", "--db", "Viral", "--time-limit", "90"]) as? ClassifyCommand)
        let plain = try XCTUnwrap(try ClassifyCommand.parseAsRoot(["reads.fastq.gz", "--db", "Viral"]) as? ClassifyCommand)

        XCTAssertEqual(limited.timeLimit.limit?.minutes, 90)
        let words = limited.canonicalArguments()
        XCTAssertEqual(words.firstIndex(of: "--time-limit").map { words[$0 + 1] }, "90",
                       "the recorded command line gives the limit the run was started with")
        XCTAssertNil(plain.timeLimit.limit, "without the option there is no limit")
        XCTAssertFalse(plain.canonicalArguments().contains("--time-limit"))
    }

    func testMapTakesATimeLimit() throws {
        let limited = try MapCommand.parse(["reads.fastq.gz", "--reference", "ref.fa", "--time-limit", "45"])
        let plain = try MapCommand.parse(["reads.fastq.gz", "--reference", "ref.fa"])

        XCTAssertEqual(limited.timeLimit.limit?.minutes, 45)
        XCTAssertNil(plain.timeLimit.limit)
    }

    func testATimeLimitThatIsNotAWholeNumberOfMinutesIsRefusedWithWords() {
        for value in [["--time-limit", "0"], ["--time-limit", "525601"], ["--time-limit=-3"]] {
            XCTAssertThrowsError(
                try ClassifyCommand.parseAsRoot(["reads.fastq.gz", "--db", "Viral"] + value),
                "\(value)"
            ) { error in
                let words = ClassifyCommand.message(for: error)
                XCTAssertTrue(words.contains("whole number of minutes"), words)
                XCTAssertTrue(words.contains("Leave the option out to run with no time limit"), words)
            }
        }
    }
}
