// MetagenomicsSampleGrouperFolderTests.swift - Loose R1 and R2 files pair only within one folder
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// GROUPER-CROSS-FOLDER-PAIR (BIO ruling BIO-REACH, row A). The grouper sorted each mate role by file name
/// alone, so same-named files of two folders tied and kept their input order, and the index branch paired
/// `read1[i]` with `read2[i]`. A list naming the folders in one order for the R1 files and in another for
/// the R2 files joined two specimens in each sample, with no word. Loose mates now pair only within one
/// folder, folders in path order, and the samples of one stem number as before.
final class MetagenomicsSampleGrouperFolderTests: XCTestCase {
    private func url(_ path: String) -> URL {
        URL(fileURLWithPath: "/data/run/\(path)")
    }

    /// Each sample as its name, its first file's path and its second file's path ("" for none).
    private func rows(_ samples: [MetagenomicsSampleInput]) -> [[String]] {
        samples.map { [$0.sampleId, $0.fastq1.path, $0.fastq2?.path ?? ""] }
    }

    func testAMixedListPairsEachFolderWithItsOwnMates() {
        let files = [
            url("a/S_R1.fastq.gz"), url("b/S_R1.fastq.gz"), url("b/S_R2.fastq.gz"), url("a/S_R2.fastq.gz"),
        ]

        let samples = MetagenomicsSampleGrouper.group(files)

        XCTAssertEqual(
            rows(samples),
            [
                ["S_1", url("a/S_R1.fastq.gz").path, url("a/S_R2.fastq.gz").path],
                ["S_2", url("b/S_R1.fastq.gz").path, url("b/S_R2.fastq.gz").path],
            ]
        )
    }

    func testMismatchedCompressionAcrossTwoPairsPairsWithinEachFolder() {
        // The shorter name sorts first, so by file name alone the R1 files order b before a and the R2 files
        // order a before b.
        let files = [
            url("a/S_R1.fastq.gz"), url("a/S_R2.fastq"), url("b/S_R1.fastq"), url("b/S_R2.fastq.gz"),
        ]

        let samples = MetagenomicsSampleGrouper.group(files)

        XCTAssertEqual(
            rows(samples),
            [
                ["S_1", url("a/S_R1.fastq.gz").path, url("a/S_R2.fastq").path],
                ["S_2", url("b/S_R1.fastq").path, url("b/S_R2.fastq.gz").path],
            ]
        )
    }

    func testAMateWithNoMateInItsFolderRunsAlone() {
        let files = [url("a/S_R2.fastq.gz"), url("b/S_R1.fastq.gz"), url("b/S_R2.fastq.gz")]

        let samples = MetagenomicsSampleGrouper.group(files)

        XCTAssertEqual(
            rows(samples),
            [
                ["S_1", url("a/S_R2.fastq.gz").path, ""],
                ["S_2", url("b/S_R1.fastq.gz").path, url("b/S_R2.fastq.gz").path],
            ]
        )
    }

    func testOneR1AndOneR2InTwoFoldersRunAsTwoSamples() {
        let files = [url("a/S_R1.fastq.gz"), url("b/S_R2.fastq.gz")]

        let samples = MetagenomicsSampleGrouper.group(files)

        XCTAssertEqual(
            rows(samples),
            [
                ["S_1", url("a/S_R1.fastq.gz").path, ""],
                ["S_2", url("b/S_R2.fastq.gz").path, ""],
            ]
        )
    }

    /// Guard, green at the base: `--batch a b` lists folder a, then folder b, each by full path.
    func testTwoFoldersGivenInOrderGiveTheSamplesTheyGaveBefore() {
        let files = [
            url("a/S_R1.fastq.gz"), url("a/S_R2.fastq.gz"), url("b/S_R1.fastq.gz"), url("b/S_R2.fastq.gz"),
            url("a/T_R1.fastq.gz"), url("a/T_R2.fastq.gz"),
        ]

        let samples = MetagenomicsSampleGrouper.group(files)

        XCTAssertEqual(
            rows(samples),
            [
                ["S_1", url("a/S_R1.fastq.gz").path, url("a/S_R2.fastq.gz").path],
                ["S_2", url("b/S_R1.fastq.gz").path, url("b/S_R2.fastq.gz").path],
                ["T", url("a/T_R1.fastq.gz").path, url("a/T_R2.fastq.gz").path],
            ]
        )
    }

    /// Guard, green at the base: `--batch */*_R1.fastq.gz */*_R2.fastq.gz` lists the R1 files, then the R2
    /// files, each in folder order.
    func testAGlobOrderGivesTheSamplesItGaveBefore() {
        let files = [
            url("a/S_R1.fastq.gz"), url("b/S_R1.fastq.gz"), url("a/S_R2.fastq.gz"), url("b/S_R2.fastq.gz"),
        ]

        let samples = MetagenomicsSampleGrouper.group(files)

        XCTAssertEqual(
            rows(samples),
            [
                ["S_1", url("a/S_R1.fastq.gz").path, url("a/S_R2.fastq.gz").path],
                ["S_2", url("b/S_R1.fastq.gz").path, url("b/S_R2.fastq.gz").path],
            ]
        )
    }
}
