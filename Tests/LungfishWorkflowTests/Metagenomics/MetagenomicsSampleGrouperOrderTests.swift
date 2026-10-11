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

    func testNamesThatDifferOnlyInCaseHaveOneOrderWhateverTheInputOrder() {
        // The collation ignores case, so "Sample" and "sample" tie. The grouper breaks the tie on the Unicode
        // scalars of the two names, which lists upper case first. Without that the sorts keep the iteration
        // order of `Dictionary(grouping:)`, which changes with the hash seed of each process.
        XCTAssertTrue(MetagenomicsSampleGrouper.isOrderedBefore("Sample", "sample"))
        XCTAssertFalse(MetagenomicsSampleGrouper.isOrderedBefore("sample", "Sample"))
        XCTAssertFalse(MetagenomicsSampleGrouper.isOrderedBefore("sample", "sample"))

        let lower = URL(fileURLWithPath: "/data/a/sample.fastq")
        let upper = URL(fileURLWithPath: "/data/b/Sample.fastq")
        XCTAssertEqual(MetagenomicsSampleGrouper.group([lower, upper]).map(\.sampleId), ["Sample", "sample"])
        XCTAssertEqual(MetagenomicsSampleGrouper.group([upper, lower]).map(\.sampleId), ["Sample", "sample"])
    }

    func testFilesOfOneStemThatDifferOnlyInCaseNumberInOneOrderWhateverTheInputOrder() {
        // `s.fastq` and `s.FASTQ` share the stem `s`, so they number as `s_1` and `s_2`. Their names tie in the
        // collation, so the name with upper case takes the first number in either input order.
        let lower = URL(fileURLWithPath: "/data/a/s.fastq")
        let upper = URL(fileURLWithPath: "/data/b/s.FASTQ")
        for files in [[lower, upper], [upper, lower]] {
            let samples = MetagenomicsSampleGrouper.group(files)

            XCTAssertEqual(
                samples.map { [$0.sampleId, $0.fastq1.lastPathComponent] },
                [["s_1", "s.FASTQ"], ["s_2", "s.fastq"]]
            )
        }
    }

    func testTheGrouperSortsInItsOwnLocaleAndNotInSwedish() {
        // Swedish collation lists "\u{E4}" after "z" and English lists it beside "a". `isOrderedBefore` takes the
        // locale as a parameter, so the first assertion needs the locale it is given and fails if the comparison
        // reads the language of the process instead. The second assertion pins the grouper's own locale, so the
        // CLI and the app list one batch alike.
        XCTAssertTrue(
            MetagenomicsSampleGrouper.isOrderedBefore("zebra", "\u{E4}rlig", locale: Locale(identifier: "sv_SE")),
            "Swedish collation lists \u{E4} after z"
        )
        XCTAssertFalse(
            MetagenomicsSampleGrouper.isOrderedBefore("zebra", "\u{E4}rlig"),
            "the grouper's own collation lists \u{E4} beside a"
        )

        let samples = MetagenomicsSampleGrouper.group(urls(["zebra", "\u{E4}rlig", "alfa"].map { "\($0).fastq" }))

        XCTAssertEqual(samples.map(\.sampleId), ["alfa", "\u{E4}rlig", "zebra"])
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
