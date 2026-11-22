// MetagenomicsSampleGrouperBundleTests.swift - One sample per FASTQ bundle in the sample grouper (TT-GROUP)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishWorkflow

/// BIO ruling BIO-TT-PAIR, question 3 and action items 2 and 6. The grouper read `Swab_1` from
/// `Swab_1.lungfishfastq` as the R1 of a sample named `Swab`, so the Classification (Kraken2) and
/// EsViritu dialogs and their `--batch` commands ran two bundles of two specimens as the two reads of
/// one sample, and with `X`, `X_1` and `X_2` the lone `X` left the run with no word.
///
/// A `.lungfishfastq` bundle, or a file inside one, is one sample named by the bundle's whole stem, as
/// `TaxTriageAnalysisRunTool.firstMatePair` reads bundles. Only loose files pair by their mate endings.
final class MetagenomicsSampleGrouperBundleTests: XCTestCase {
    private func bundles(_ stems: [String]) -> [URL] {
        stems.map { URL(fileURLWithPath: "/data/run/\($0).lungfishfastq", isDirectory: true) }
    }

    func testTwoBundlesNamedLikeMatesAreTwoSamplesUnderTheirWholeStems() {
        let inputs = bundles(["Swab_1", "Swab_2"])

        let samples = MetagenomicsSampleGrouper.group(inputs)

        XCTAssertEqual(samples.map(\.sampleId), ["Swab_1", "Swab_2"])
        XCTAssertEqual(samples.map(\.fastq1), inputs)
        XCTAssertEqual(samples.map { $0.fastq2 == nil }, [true, true])
    }

    func testBundlesXAndX1AndX2AreThreeSamplesAndNoneIsLost() {
        let inputs = bundles(["X_2", "X", "X_1"])

        let samples = MetagenomicsSampleGrouper.group(inputs)

        XCTAssertEqual(samples.map(\.sampleId), ["X", "X_1", "X_2"])
        XCTAssertEqual(samples.map(\.fastq1), bundles(["X", "X_1", "X_2"]))
        XCTAssertEqual(samples.flatMap(\.inputFiles).count, 3)
    }

    /// A guard. R1 is the file whose name carries the R1 ending, never the first in the list.
    func testLooseFilesListedR2FirstPairWithTheR1FileAsR1() {
        let read2 = URL(fileURLWithPath: "/data/run/S_R2.fastq.gz")
        let read1 = URL(fileURLWithPath: "/data/run/S_R1.fastq.gz")

        let samples = MetagenomicsSampleGrouper.group([read2, read1])

        XCTAssertEqual(samples.map(\.sampleId), ["S"])
        XCTAssertEqual(samples.map(\.fastq1), [read1])
        XCTAssertEqual(samples.map(\.fastq2), [read2])
    }

    func testAFileInsideABundleCountsAsThatBundle() {
        let first = URL(fileURLWithPath: "/data/run/Swab_1.lungfishfastq/reads.fastq.gz")
        let second = URL(fileURLWithPath: "/data/run/Swab_2.lungfishfastq/reads.fastq.gz")

        let samples = MetagenomicsSampleGrouper.group([second, first])

        XCTAssertEqual(samples.map(\.sampleId), ["Swab_1", "Swab_2"])
        XCTAssertEqual(samples.map(\.fastq1), [first, second])
        XCTAssertEqual(samples.map { $0.fastq2 == nil }, [true, true])
    }

    func testFilesWithMateEndingsInsideTwoBundlesAreNeverMates() {
        let first = URL(fileURLWithPath: "/data/run/Swab_1.lungfishfastq/Swab_1.fastq")
        let second = URL(fileURLWithPath: "/data/run/Swab_2.lungfishfastq/Swab_2.fastq")

        let samples = MetagenomicsSampleGrouper.group([first, second])

        XCTAssertEqual(samples.map(\.sampleId), ["Swab_1", "Swab_2"])
        XCTAssertEqual(samples.map(\.fastq1), [first, second])
        XCTAssertEqual(samples.map { $0.fastq2 == nil }, [true, true])
    }

    /// The two files of one bundle are that bundle, once, as `AssemblyInputSamples` reads them.
    func testTwoFilesOfOneBundleAreThatBundleOnce() {
        let read1 = URL(fileURLWithPath: "/data/run/P.lungfishfastq/P_R1.fastq.gz")
        let read2 = URL(fileURLWithPath: "/data/run/P.lungfishfastq/P_R2.fastq.gz")

        let samples = MetagenomicsSampleGrouper.group([read2, read1])

        XCTAssertEqual(samples.map(\.sampleId), ["P"])
        XCTAssertEqual(samples.map(\.fastq1.path), ["/data/run/P.lungfishfastq"])
        XCTAssertEqual(samples.map { $0.fastq2 == nil }, [true])
    }

    func testDottedBundleNamesKeepTheirWholeStem() {
        let inputs = bundles(["2024.11.05_swab_1", "2024.11.05_swab_2", "Pt.7"])

        let samples = MetagenomicsSampleGrouper.group(inputs)

        XCTAssertEqual(samples.map(\.sampleId), ["2024_11_05_swab_1", "2024_11_05_swab_2", "Pt_7"])
        XCTAssertEqual(samples.map(\.fastq1), inputs)
        XCTAssertEqual(samples.map { $0.fastq2 == nil }, [true, true, true])
    }

    func testProbeCaseThreeBundlesAreThreeSamples() {
        let inputs = bundles(["Sample_3", "Sample_1", "Sample_2"])

        let samples = MetagenomicsSampleGrouper.group(inputs)

        XCTAssertEqual(samples.map(\.sampleId), ["Sample_1", "Sample_2", "Sample_3"])
        XCTAssertEqual(samples.map(\.fastq1), bundles(["Sample_1", "Sample_2", "Sample_3"]))
        XCTAssertEqual(samples.map { $0.fastq2 == nil }, [true, true, true])
    }

    /// A lone bundle is one sample under its whole stem, even when the stem ends like a mate.
    func testALoneBundleWithAMateEndingKeepsItsWholeStem() {
        let inputs = bundles(["Sample_R1"])

        let samples = MetagenomicsSampleGrouper.group(inputs)

        XCTAssertEqual(samples.map(\.sampleId), ["Sample_R1"])
        XCTAssertEqual(samples.map(\.fastq1), inputs)
        XCTAssertEqual(samples.map { $0.fastq2 == nil }, [true])
    }
}
