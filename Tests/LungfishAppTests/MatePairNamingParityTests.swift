// MatePairNamingParityTests.swift - The CLI pairs files the way the Map Reads window does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishWorkflow

/// The classifier wizard groups files into samples through
/// `MetagenomicsSampleGrouper`, which lives in the app and the CLI cannot
/// see. `MatePairFileNaming` in LungfishWorkflow carries the same convention
/// for the CLI and for `MappingInputResolver`, so two files named as mates
/// pair the same way on every path. This pins the two to one answer.
@MainActor
final class MatePairNamingParityTests: XCTestCase {

    func testWindowAndCLIAgreeOnWhichTwoFilesAreMates() {
        let cases: [(String, String)] = [
            ("sample_R1.fastq", "sample_R2.fastq"),
            ("sample_R2.fastq", "sample_R1.fastq"),
            ("sample_R1_001.fastq.gz", "sample_R2_001.fastq.gz"),
            ("sample_1.fq.gz", "sample_2.fq.gz"),
            ("sample.r1.fastq", "sample.r2.fastq"),
            ("sample-r1.fastq", "sample-r2.fastq"),
            ("Lib A_S1_R1_001.fastq.gz", "Lib A_S1_R2_001.fastq.gz"),
            ("sampleA.fastq", "sampleB.fastq"),
            ("a_R1.fastq", "b_R2.fastq"),
            ("s_R1.fastq", "s_R1.fastq"),
            ("run_0.fastq.gz", "run_1.fastq.gz"),
            ("run_1.fastq.gz", "run_2.fastq.gz"),
            ("reads.fastq", "more-reads.fastq"),
            ("s_R1.fastq", "s.fastq"),
            ("single.fastq", "single.fastq"),
        ]
        for (first, second) in cases {
            let files = [URL(fileURLWithPath: "/data/\(first)"), URL(fileURLWithPath: "/data/\(second)")]
            XCTAssertEqual(
                Self.groupsAsOnePairedSample(files),
                MatePairFileNaming.matePair(in: files) != nil,
                "the window and the CLI disagree on \(first) + \(second)"
            )
        }
    }

    /// Whether the grouper puts two files into one sample with both mates.
    private static func groupsAsOnePairedSample(_ files: [URL]) -> Bool {
        let grouped = MetagenomicsSampleGrouper.group(files)
        return grouped.count == 1 && grouped[0].isPairedEnd
    }
}
