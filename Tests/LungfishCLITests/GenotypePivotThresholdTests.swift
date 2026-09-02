import XCTest
import LungfishCore
import LungfishIO
import LungfishWorkflow
@testable import LungfishCLI

/// Covers the pivot export's Min Reads / Min Percent background suppression and
/// the read-count metric the workbook reports.
///
/// Context: analysts previously exported the unfiltered pivot and stripped
/// low-support background by hand in Excel (bracketing values, then hiding the
/// emptied rows). These thresholds apply the same cut while the workbook is
/// written. Separately, the workbook used to report `passedAlignments`, which
/// double-counts each mate of an unmerged Illumina pair and so read about twice
/// what the genotype inspector showed for the same sample.
final class GenotypePivotThresholdTests: XCTestCase {

    private typealias Builder = GenotypeExportPivotXlsxSubcommand.PivotWorkbookBuilder
    private typealias Thresholds = Builder.Thresholds

    // MARK: - Fixture

    /// Two samples with a strong call, a mid-support call, and background.
    ///
    /// `Animal1` retains 1,000 reads, so its 5-read background call is 0.5% and
    /// its 40-read call is 4%. `Animal2` retains 100 reads, so its 8-read call
    /// is 8% -- above a 1% floor but below a 10-read floor. That split lets one
    /// fixture exercise the read threshold and the percent threshold
    /// independently.
    private func makeResult() -> ONTGenotypeResultBundleData {
        let bundleURL = URL(fileURLWithPath: "/tmp/pivot-thresholds.lungfishgenotype", isDirectory: true)
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "thresholds", analysisName: "Thresholds",
            primaryWorkbookPath: "t.xlsx",
            longSummaryCSVPath: "g.csv", sampleSummaryCSVPath: "s.csv",
            statsJSONPath: "stats.json", provenancePath: "prov.json"
        )
        let artifacts = ONTGenotypeResultArtifacts(
            workbookURL: bundleURL.appendingPathComponent("t.xlsx"),
            longSummaryCSVURL: bundleURL.appendingPathComponent("g.csv"),
            sampleSummaryCSVURL: bundleURL.appendingPathComponent("s.csv"),
            statsJSONURL: bundleURL.appendingPathComponent("stats.json"),
            provenanceURL: bundleURL.appendingPathComponent("prov.json")
        )
        func call(
            _ sample: String,
            _ genotype: String,
            unique: Int,
            retained: Int
        ) -> ONTGenotypeCall {
            ONTGenotypeCall(
                sample: sample, genotype: genotype,
                // Alignments deliberately differ from unique reads so a test
                // that accidentally reads the alignment count fails loudly.
                passedAlignments: unique * 2, passedUniqueReads: unique,
                sampleTotalReads: retained * 2, sampleUniqueRetainedReads: retained,
                sampleUniqueRetainedPercent: 50.0,
                overallInputReads: nil, overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            )
        }
        let calls = [
            call("Animal1", "01_Strong", unique: 500, retained: 1_000),
            call("Animal1", "01_Middle", unique: 40, retained: 1_000),
            call("Animal1", "01_Background", unique: 5, retained: 1_000),
            call("Animal2", "01_Strong", unique: 60, retained: 100),
            call("Animal2", "01_Middle", unique: 8, retained: 100),
        ]
        let samples = [
            ONTGenotypeSampleResult(
                sample: "Animal1", passedAlignments: 1_090, passedUniqueReads: 1_000,
                sampleTotalReads: 2_000, sampleUniqueRetainedPercent: 50.0,
                calls: calls.filter { $0.sample == "Animal1" }
            ),
            ONTGenotypeSampleResult(
                sample: "Animal2", passedAlignments: 136, passedUniqueReads: 100,
                sampleTotalReads: 200, sampleUniqueRetainedPercent: 50.0,
                calls: calls.filter { $0.sample == "Animal2" }
            ),
        ]
        return ONTGenotypeResultBundleData(
            bundleURL: bundleURL, manifest: manifest, artifacts: artifacts,
            stats: ONTGenotypeRunStats(), calls: calls, samples: samples,
            haplotypeAnalysis: nil
        )
    }

    private func alleleCounts(_ workbook: GenotypeExportPivotXlsxSubcommand.PivotWorkbook) -> [String: [Int?]] {
        var map: [String: [Int?]] = [:]
        for group in workbook.groups {
            for allele in group.alleles {
                map[allele.name] = allele.counts
            }
        }
        return map
    }

    // MARK: - Read-count metric

    func testMappedReadCountReportsDistinctReadsNotAlignments() {
        let workbook = Builder.build(from: makeResult())
        // 1,000 and 100 are the distinct-read totals the inspector shows;
        // 1,090 and 136 are the mate-inflated alignment counts.
        XCTAssertEqual(workbook.mappedReadCounts, [1_000, 100])
    }

    func testAlleleValuesReportDistinctReads() {
        let counts = alleleCounts(Builder.build(from: makeResult()))
        XCTAssertEqual(counts["01_Strong"], [500, 60])
    }

    // MARK: - No thresholds

    func testWithoutThresholdsEveryObservedValueIsKept() {
        let workbook = Builder.build(from: makeResult(), sidecar: nil, thresholds: .none)
        let counts = alleleCounts(workbook)
        XCTAssertEqual(counts["01_Strong"], [500, 60])
        XCTAssertEqual(counts["01_Middle"], [40, 8])
        XCTAssertEqual(counts["01_Background"], [5, nil])
        XCTAssertEqual(workbook.filteredValueCount, 0)
        XCTAssertEqual(workbook.removedRowCount, 0)
    }

    // MARK: - Min Reads

    func testMinReadsSuppressesValuesBelowTheFloor() {
        let workbook = Builder.build(
            from: makeResult(),
            sidecar: nil,
            thresholds: Thresholds(minimumReads: 10)
        )
        let counts = alleleCounts(workbook)
        XCTAssertEqual(counts["01_Strong"], [500, 60])
        // Animal2's 8-read call falls below the 10-read floor.
        XCTAssertEqual(counts["01_Middle"], [40, nil])
        // The background row lost its only value, so the row is dropped.
        XCTAssertNil(counts["01_Background"])
        XCTAssertEqual(workbook.filteredValueCount, 2)
        XCTAssertEqual(workbook.removedRowCount, 1)
    }

    // MARK: - Min Percent

    func testMinPercentUsesTheSamplesRetainedReadsAsDenominator() {
        let workbook = Builder.build(
            from: makeResult(),
            sidecar: nil,
            thresholds: Thresholds(minimumPercent: 1.0)
        )
        let counts = alleleCounts(workbook)
        // Animal2's 8 of 100 reads is 8%, so it survives a 1% floor even though
        // it is numerically smaller than Animal1's 40 of 1,000 (4%).
        XCTAssertEqual(counts["01_Middle"], [40, 8])
        // Animal1's 5 of 1,000 reads is 0.5%, below the floor.
        XCTAssertNil(counts["01_Background"])
        XCTAssertEqual(workbook.filteredValueCount, 1)
    }

    func testThresholdsCombineAsAnAnd() {
        let workbook = Builder.build(
            from: makeResult(),
            sidecar: nil,
            thresholds: Thresholds(minimumReads: 10, minimumPercent: 5.0)
        )
        let counts = alleleCounts(workbook)
        // Animal1's 40 reads clears the read floor but is only 4%.
        // Animal2's 8 reads is 8% but misses the 10-read floor.
        XCTAssertNil(counts["01_Middle"])
        XCTAssertEqual(counts["01_Strong"], [500, 60])
    }

    // MARK: - Empty rows

    func testKeepEmptyRowsRetainsFullyFilteredRows() {
        let workbook = Builder.build(
            from: makeResult(),
            sidecar: nil,
            thresholds: Thresholds(minimumReads: 10, keepEmptyRows: true)
        )
        let counts = alleleCounts(workbook)
        // The row survives, but its suppressed value is blank rather than zero.
        XCTAssertEqual(counts["01_Background"], [nil, nil])
        XCTAssertEqual(workbook.removedRowCount, 1)
    }

    // MARK: - Threshold semantics

    func testAdmitsRejectsZeroAndNegativeCounts() {
        let thresholds = Thresholds(minimumReads: 5)
        XCTAssertFalse(thresholds.admits(count: 0, sampleTotal: 100))
        XCTAssertTrue(thresholds.admits(count: 5, sampleTotal: 100))
    }

    func testPercentThresholdIsSkippedWhenTheSampleTotalIsUnknown() {
        // Without a positive denominator the percent cut cannot be evaluated,
        // so the read floor alone decides and a sample of unknown depth is
        // never silently blanked.
        let thresholds = Thresholds(minimumPercent: 50.0)
        XCTAssertTrue(thresholds.admits(count: 1, sampleTotal: nil))
        XCTAssertTrue(thresholds.admits(count: 1, sampleTotal: 0))
        XCTAssertFalse(thresholds.admits(count: 1, sampleTotal: 100))
    }

    func testInactiveThresholdsAdmitEveryPositiveCount() {
        XCTAssertFalse(Thresholds.none.isActive)
        XCTAssertTrue(Thresholds.none.admits(count: 1, sampleTotal: 1_000_000))
    }

    func testProvenanceArgumentsRecordOnlyActiveThresholds() {
        XCTAssertEqual(Thresholds.none.provenanceArguments, [])
        XCTAssertEqual(
            Thresholds(minimumReads: 25).provenanceArguments,
            ["--min-reads", "25"]
        )
        XCTAssertEqual(
            Thresholds(minimumReads: 25, minimumPercent: 2.5, keepEmptyRows: true).provenanceArguments,
            ["--min-reads", "25", "--min-percent", "2.5", "--keep-empty-rows"]
        )
    }

    // MARK: - Argument parsing

    func testParsesThresholdOptions() throws {
        let command = try GenotypeExportPivotXlsxSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
            "--output", "/tmp/out.xlsx",
            "--min-reads", "25",
            "--min-percent", "1.5",
            "--keep-empty-rows",
        ])
        XCTAssertEqual(command.minReads, 25)
        XCTAssertEqual(command.minPercent, 1.5)
        XCTAssertTrue(command.keepEmptyRows)
    }

    func testThresholdsDefaultToDisabled() throws {
        let command = try GenotypeExportPivotXlsxSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
            "--output", "/tmp/out.xlsx",
        ])
        XCTAssertEqual(command.minReads, 0)
        XCTAssertEqual(command.minPercent, 0)
        XCTAssertFalse(command.keepEmptyRows)
    }

    func testRejectsOutOfRangeThresholds() throws {
        // ArgumentParser runs validate() as part of parse(), so an out-of-range
        // threshold surfaces there rather than on a separate validate() call.
        // A bare "-1" is rejected earlier still, because a leading "-" reads as
        // an option name; "--min-reads=-1" reaches the range check.
        for arguments in [
            ["--min-reads", "-1"],
            ["--min-reads=-1"],
            ["--min-percent=-1"],
            ["--min-percent", "101"],
        ] {
            XCTAssertThrowsError(
                try GenotypeExportPivotXlsxSubcommand.parse(
                    ["--bundle", "/tmp/b.lungfishgenotype", "--output", "/tmp/o.xlsx"] + arguments
                ),
                "expected \(arguments) to be rejected"
            )
        }
    }
}
