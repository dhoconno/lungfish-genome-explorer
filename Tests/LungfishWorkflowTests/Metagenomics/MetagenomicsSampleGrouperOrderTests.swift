// MetagenomicsSampleGrouperOrderTests.swift - The order and the dedupe suffixes of the sample grouper
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// Pins the order in which `MetagenomicsSampleGrouper` lists samples and numbers the files of one
/// sample, for names that differ in case, digits, underscores, hyphens and dots.
///
/// The wizards and `lungfish-cli` both group through the grouper, so a batch must list its samples
/// and number its duplicates the same way whatever language the process runs in. The expected
/// orders below are the collation of the English (United States) locale, which is the order the
/// grouper gave before its locale was fixed.
final class MetagenomicsSampleGrouperOrderTests: XCTestCase {
    private func urls(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/data/run/\($0)") }
    }

    func testSingleEndSamplesAreListedCaseInsensitivelyWithDigitsAndSeparatorsInEnglishOrder() {
        let files = urls([
            "Zeta.fastq", "alpha.fastq", "Beta_b.fastq", "beta.fastq", "beta-1.fastq", "Alpha2.fastq",
            "sample10.fastq", "sample2.fastq", "Sample_a.fastq", "10.fastq", "9.fastq", "a1.fastq", "B1.fastq",
        ])

        let samples = MetagenomicsSampleGrouper.group(files)

        XCTAssertEqual(
            samples.map(\.sampleId),
            [
                "10", "9", "a1", "alpha", "Alpha2", "B1", "beta", "Beta_b", "beta-1",
                "Sample_a", "sample10", "sample2", "Zeta",
            ]
        )
    }

    func testStemsThatSanitizeToOneKeyNumberTheirFilesInTheOrderOfTheirFileNames() {
        // `s.x.fastq` and `s_x.fastq` both sanitize to the key `s_x`, so they number as `s_x_1` and `s_x_2`
        // in the order of their file names. `s1-a` and `s1_a` stay two samples.
        let files = urls(["s.x.fastq", "s_x.fastq", "s1-a.fastq", "s1_a.fastq"])

        let samples = MetagenomicsSampleGrouper.group(files)

        XCTAssertEqual(samples.map(\.sampleId), ["s_x_1", "s_x_2", "s1_a", "s1-a"])
        XCTAssertEqual(
            samples.map { [$0.sampleId, $0.fastq1.lastPathComponent] },
            [["s_x_1", "s_x.fastq"], ["s_x_2", "s.x.fastq"], ["s1_a", "s1_a.fastq"], ["s1-a", "s1-a.fastq"]]
        )
    }

    func testPairedFilesOfOneStemNumberTheirPairsInTheOrderOfTheirFileNames() {
        let files = urls(["s1-R2.fastq", "s1_R2.fastq", "s1-R1.fastq", "s1_R1.fastq"])

        let samples = MetagenomicsSampleGrouper.group(files)

        XCTAssertEqual(samples.map(\.sampleId), ["s1_1", "s1_2"])
        XCTAssertEqual(
            samples.map { [$0.fastq1.lastPathComponent, $0.fastq2?.lastPathComponent ?? ""] },
            [["s1_R1.fastq", "s1_R2.fastq"], ["s1-R1.fastq", "s1-R2.fastq"]]
        )
    }
}
