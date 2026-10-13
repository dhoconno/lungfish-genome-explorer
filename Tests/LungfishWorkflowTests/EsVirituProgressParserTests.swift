// EsVirituProgressParserTests.swift - EsViritu stderr to progress lines
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

final class EsVirituProgressParserTests: XCTestCase {

    /// EsViritu's logger wraps each line in color codes.
    private func logLine(_ text: String) -> String {
        "\u{1B}[93m2026-10-12 19:59:36,444 - INFO - \(text)\u{1B}[0m"
    }

    func testAlignmentBatchesReportARunningReadCount() {
        var parser = EsVirituProgressParser()
        XCTAssertEqual(parser.update(for: logLine("Starting minimap2_f..."))?.message,
                       "Aligning reads to viral references (round 1)...")
        _ = parser.update(for: "[M::worker_pipeline::612.871*13.42] mapped 333334 sequences")
        let second = parser.update(for: "[M::worker_pipeline::1220.004*13.51] mapped 333332 sequences")
        XCTAssertEqual(second?.message, "Aligning reads to viral references (round 1): 666,666 reads processed...")
        XCTAssertEqual(second?.fraction, 0.30)
    }

    func testEachAlignmentRoundRestartsItsCount() {
        var parser = EsVirituProgressParser()
        _ = parser.update(for: logLine("Starting minimap2_f..."))
        _ = parser.update(for: "[M::worker_pipeline::1.0*1.0] mapped 500 sequences")
        _ = parser.update(for: logLine("Starting assembly_read_sharing_table..."))
        let round2 = parser.update(for: logLine("Starting minimap2_f..."))
        XCTAssertEqual(round2, .init(fraction: 0.56, message: "Aligning reads to viral references (round 2)..."))
        XCTAssertEqual(parser.update(for: "[M::worker_pipeline::2.0*1.0] mapped 20 sequences")?.message,
                       "Aligning reads to viral references (round 2): 20 reads processed...")
    }

    func testStepsReportTheirOwnMessageInRunOrder() {
        var parser = EsVirituProgressParser()
        let updates = [
            "Starting trim_filter...", "Starting fastp_stats...", "Starting minimap2_f...",
            "Starting bam_to_coverm_table...", "Starting tax_profile...",
        ].compactMap { parser.update(for: logLine($0)) }
        XCTAssertEqual(updates.map(\.message), [
            "Quality filtering reads...",
            "Counting the reads that passed filtering...",
            "Aligning reads to viral references (round 1)...",
            "Calculating coverage statistics...",
            "Building taxonomic profile...",
        ])
        XCTAssertEqual(updates.map(\.fraction), updates.map(\.fraction).sorted())
    }

    func testAnUnknownStepIsNamedAndKeepsTheFraction() {
        var parser = EsVirituProgressParser()
        _ = parser.update(for: logLine("Starting fastp_stats..."))
        XCTAssertEqual(parser.update(for: logLine("Starting new_step_2...")),
                       .init(fraction: 0.25, message: "Running the EsViritu step new_step_2..."))
    }

    /// The old keyword parser turned fastp's report into seven "Quality filtering" lines and
    /// minimap2's index lines into nothing.
    func testToolChatterAndBatchLinesBeforeAnAlignmentAreIgnored() {
        var parser = EsVirituProgressParser()
        for line in [
            "reads failed due to low quality: 17492",
            "Q20 bases: 6156567(81.5439%)",
            "[M::mm_idx_gen::0.003*2.09] collected minimizers",
            "[M::worker_pipeline::0.004*1.76] mapped 1 sequences",
            logLine("Completed trim_filter in 14.25 seconds"),
            logLine("Not filtering against host/spike-in reference..."),
            "",
        ] {
            XCTAssertNil(parser.update(for: line), line)
        }
    }
}
