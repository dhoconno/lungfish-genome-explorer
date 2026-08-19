// SavontCLIContractTests.swift - Savont CLI flag-vocabulary conformance
// Copyright (c) 2024 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishTestSupport
@testable import LungfishWorkflow

/// Pins the savont command-line contract that `SavontClusteringRunRequest.arguments`
/// depends on.
///
/// `ToolVersionConformanceTests` proves the installed savont reports the pinned
/// version; it does not prove the flags Lungfish passes still exist. Savont is a
/// pack tool that moves in minor releases (0.5.0 -> 0.6.3 in the 2026.2 sweep),
/// and a renamed or removed flag would surface only as a failed run at genotyping
/// time, on user data. This test reads `savont asv --help` from the installed
/// environment and asserts every flag the request emits is still accepted.
///
/// Like the rest of the conformance suite this is skipped when savont is not
/// installed and enforced under `LUNGFISH_REQUIRE_TOOLS=1`.
final class SavontCLIContractTests: XCTestCase {

    /// Every option token `SavontClusteringRunRequest.arguments` can emit.
    ///
    /// Built from a request that sets every optional field, so the list is derived
    /// from the production argument builder rather than restated by hand: if a new
    /// flag is added there it is checked here automatically.
    private func emittedOptionFlags() throws -> [String] {
        let request = try SavontClusteringRunRequest(
            inputFASTQURL: URL(fileURLWithPath: "/tmp/reads.fastq.gz"),
            outputFASTAURL: URL(fileURLWithPath: "/tmp/clusters.fasta"),
            threads: 4,
            qualityValueCutoff: 90,
            minimumClusterSize: 3,
            minimumReadLength: 1100,
            maximumReadLength: 2000,
            singleStrand: true
        )
        let arguments = try request.arguments(outputDirectory: URL(fileURLWithPath: "/tmp/run"))
        return arguments.filter { $0.hasPrefix("-") }
    }

    func testSavontAsvAcceptsEveryFlagTheRunRequestEmits() async throws {
        let savont = try await ToolAvailability.require("savont", environment: "savont")
        let help = try ProcessRunner.run(savont, ["asv", "--help"], timeout: 60)
        let helpText = help.stdout + help.stderr

        XCTAssertFalse(
            helpText.isEmpty,
            "savont asv --help produced no output; cannot verify the CLI contract"
        )

        // The subcommand itself is part of the contract: arguments() leads with "asv".
        XCTAssertTrue(
            helpText.contains("savont asv"),
            "savont no longer exposes the 'asv' subcommand that the pipeline invokes: \(helpText.prefix(400))"
        )

        var missing: [String] = []
        for flag in try emittedOptionFlags() where !Self.helpText(helpText, documentsFlag: flag) {
            missing.append(flag)
        }

        XCTAssertTrue(
            missing.isEmpty,
            """
            savont asv no longer documents \(missing.joined(separator: ", ")). \
            SavontClusteringRunRequest.arguments would pass rejected flags. \
            Update the argument builder to the new spelling before shipping this pin.
            """
        )
    }

    /// True when `--help` documents `flag` as an option token.
    ///
    /// Matches on a token boundary so `-o` does not match `--output-dir` incidentally
    /// and `--min-read-length` does not match inside `--max-read-length`.
    private static func helpText(_ text: String, documentsFlag flag: String) -> Bool {
        let terminators: Set<Character> = [" ", ",", "=", "<", "\n", "\t"]
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: flag, range: searchRange) {
            let precededProperly: Bool
            if found.lowerBound == text.startIndex {
                precededProperly = true
            } else {
                let before = text[text.index(before: found.lowerBound)]
                precededProperly = before == " " || before == "\n" || before == "\t" || before == ","
            }
            let followedProperly: Bool
            if found.upperBound == text.endIndex {
                followedProperly = true
            } else {
                followedProperly = terminators.contains(text[found.upperBound])
            }
            if precededProperly && followedProperly { return true }
            searchRange = found.upperBound..<text.endIndex
        }
        return false
    }
}
