// Kraken2TimeLimitRecordTests.swift - A kraken2 run records its time limit when the person set one
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishCore
import LungfishTestSupport
@testable import LungfishWorkflow

/// `docs/contracts/SCOPE-AND-DELIVERY.md`, Tool run time. The root record of a `kraken2 classify` run holds the
/// limit as an explicit and as a resolved option when `--time-limit` was given, and holds no entry when it was not.
final class Kraken2TimeLimitRecordTests: XCTestCase {

    func testTheTimeLimitIsRecordedOnlyWhenTheRunSetOne() throws {
        let root = try TestTempDirectory.make(prefix: "kraken2-time-limit")
        defer { TestTempDirectory.cleanup(root) }
        let input = root.appendingPathComponent("reads.fastq")
        try "@r1\nACGT\n+\nIIII\n".write(to: input, atomically: true, encoding: .utf8)
        let database = root.appendingPathComponent("db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let config = ClassificationConfig(
            goal: .classify, inputFiles: [input], isPairedEnd: false, databaseName: "Viral",
            databaseVersion: "2026.1", databasePath: database, confidence: 0.2, outputDirectory: root
        )
        let request = Kraken2RunRequest(inputArguments: ["reads.fastq"], databaseName: "Viral")
        let plain = ["lungfish-cli", "kraken2", "classify", "reads.fastq", "--db", "Viral"]
        let limited = plain + ["--time-limit", "90"]
        let key = AnalysisTimeLimit.recordKey

        func explicit(_ argv: [String]) -> [String: ParameterValue] {
            Kraken2RunRecordOptions.explicit(config: config, request: request, argv: argv, originalInputURLs: [input])
        }
        func resolved(_ argv: [String]) -> [String: ParameterValue] {
            Kraken2RunRecordOptions.resolved(
                config: config, outcome: .notRequested, request: request, argv: argv,
                originalInputURLs: [input], executionInputURLs: [input]
            )
        }

        XCTAssertEqual(explicit(limited)[key], .integer(90), "the explicit options hold the limit that was typed")
        XCTAssertEqual(resolved(limited)[key], .integer(90), "the resolved options hold the limit the run used")
        XCTAssertNil(explicit(plain)[key], "a run with no limit records none")
        XCTAssertNil(resolved(plain)[key], "a run with no limit records none")
    }
}
