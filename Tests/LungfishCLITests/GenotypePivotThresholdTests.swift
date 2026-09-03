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

    // MARK: - Percent basis

    /// The inspector's Percent Basis defaults to Viewed Locus: a value is a
    /// percent of the sample's reads at that allele's locus, not of every
    /// retained read. An export applying the other denominator would drop
    /// different cells than the analyst is looking at.
    func testViewedLocusBasisMeasuresAgainstTheLocusNotTheSample() {
        let bundleURL = URL(fileURLWithPath: "/tmp/pivot-basis.lungfishgenotype", isDirectory: true)
        let manifest = ONTGenotypeResultBundleManifest(
            outputName: "basis", analysisName: "Basis",
            primaryWorkbookPath: "b.xlsx",
            longSummaryCSVPath: "g.csv", sampleSummaryCSVPath: "s.csv",
            statsJSONPath: "stats.json", provenancePath: "prov.json"
        )
        let artifacts = ONTGenotypeResultArtifacts(
            workbookURL: bundleURL.appendingPathComponent("b.xlsx"),
            longSummaryCSVURL: bundleURL.appendingPathComponent("g.csv"),
            sampleSummaryCSVURL: bundleURL.appendingPathComponent("s.csv"),
            statsJSONURL: bundleURL.appendingPathComponent("stats.json"),
            provenanceURL: bundleURL.appendingPathComponent("prov.json")
        )
        func call(_ genotype: String, unique: Int) -> ONTGenotypeCall {
            ONTGenotypeCall(
                sample: "Animal1", genotype: genotype,
                passedAlignments: unique, passedUniqueReads: unique,
                sampleTotalReads: 2_000, sampleUniqueRetainedReads: 1_000,
                sampleUniqueRetainedPercent: 50.0,
                overallInputReads: nil, overallUniqueRetainedReads: nil,
                overallUniqueRetainedPercent: nil
            )
        }
        // MHC-A carries 100 reads in this sample, MHC-B 50; the sample
        // retained 1,000 in total.
        let calls = [
            call("01_Mamu-A1_001g", unique: 90),
            call("01_Mamu-A1_002g", unique: 10),
            call("03_Mamu-B_001g", unique: 50),
        ]
        XCTAssertEqual(Set(calls.prefix(2).map(\.locusGroup)).count, 1, "both A1 calls share a locus group")
        XCTAssertNotEqual(calls[0].locusGroup, calls[2].locusGroup)
        let result = ONTGenotypeResultBundleData(
            bundleURL: bundleURL, manifest: manifest, artifacts: artifacts,
            stats: ONTGenotypeRunStats(), calls: calls,
            samples: [
                ONTGenotypeSampleResult(
                    sample: "Animal1", passedAlignments: 150, passedUniqueReads: 1_000,
                    sampleTotalReads: 2_000, sampleUniqueRetainedPercent: 50.0, calls: calls
                ),
            ],
            haplotypeAnalysis: nil
        )

        let viewedLocus = alleleCounts(Builder.build(
            from: result, sidecar: nil,
            thresholds: Thresholds(minimumPercent: 5, percentBasis: .viewedLocus)
        ))
        XCTAssertEqual(viewedLocus["01_Mamu-A1_002g"], [10], "10 of 100 MHC-A reads is 10%, above 5%")

        let sampleRetained = alleleCounts(Builder.build(
            from: result, sidecar: nil,
            thresholds: Thresholds(minimumPercent: 5, percentBasis: .sampleRetained)
        ))
        XCTAssertNil(sampleRetained["01_Mamu-A1_002g"], "10 of 1,000 retained reads is 1%, below 5%")
        XCTAssertEqual(
            Thresholds(minimumPercent: 5, percentBasis: .viewedLocus).provenanceArguments,
            ["--min-percent", "5.0", "--percent-basis", "viewed-locus"]
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

    func testParsesPercentBasisAndSourceWorkbook() throws {
        let command = try GenotypeExportPivotXlsxSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype",
            "--output", "/tmp/out.xlsx",
            "--percent-basis", "viewed-locus",
            "--source-workbook", "/tmp/example.lungfishgenotype/current.xlsx",
        ])
        XCTAssertEqual(command.percentBasis, .viewedLocus)
        XCTAssertEqual(command.sourceWorkbook, "/tmp/example.lungfishgenotype/current.xlsx")

        let defaults = try GenotypeExportPivotXlsxSubcommand.parse([
            "--bundle", "/tmp/example.lungfishgenotype", "--output", "/tmp/out.xlsx",
        ])
        XCTAssertEqual(defaults.percentBasis, .sampleRetained)
        XCTAssertNil(defaults.sourceWorkbook)
        XCTAssertThrowsError(try GenotypeExportPivotXlsxSubcommand.parse([
            "--bundle", "/tmp/b.lungfishgenotype", "--output", "/tmp/o.xlsx",
            "--percent-basis", "reads",
        ]))
    }

    // MARK: - Filter plan for the workbook copy

    /// The plan handed to the openpyxl script must list every allele row,
    /// including one whose values all fell below the thresholds, so the
    /// script can delete it; the caller's keep-empty choice travels separately.
    func testFilterPlanListsEveryAlleleRowWithItsSurvivingSamples() {
        let plan = GenotypeExportPivotXlsxSubcommand.FilterPlan.make(
            from: makeResult(),
            sidecar: nil,
            thresholds: Thresholds(minimumReads: 10)
        )
        XCTAssertFalse(plan.keepEmptyRows)
        let byGenotype = Dictionary(uniqueKeysWithValues: plan.rows.map { ($0.genotype, $0.keep) })
        XCTAssertEqual(byGenotype["01_Strong"], ["Animal1", "Animal2"])
        XCTAssertEqual(byGenotype["01_Middle"], ["Animal1"], "Animal2's 8 reads fall below 10")
        XCTAssertEqual(byGenotype["01_Background"], [], "an emptied row is listed so the script removes it")
        XCTAssertEqual(plan.rows.count, 3)
    }

    func testSourceWorkbookPrefersExplicitThenCurrentThenPrimary() throws {
        let bundleURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pivot-source-\(UUID().uuidString).lungfishgenotype", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundleURL) }
        let manifest = makeResult().manifest  // primaryWorkbookPath "t.xlsx"
        typealias Command = GenotypeExportPivotXlsxSubcommand

        XCTAssertNil(
            Command.resolveSourceWorkbookURL(explicit: nil, bundleURL: bundleURL, manifest: manifest),
            "no workbook on disk means the pivot-only writer is used"
        )
        let primary = bundleURL.appendingPathComponent("t.xlsx")
        try Data("primary".utf8).write(to: primary)
        XCTAssertEqual(
            Command.resolveSourceWorkbookURL(explicit: nil, bundleURL: bundleURL, manifest: manifest)?.path,
            primary.path
        )
        let current = bundleURL.appendingPathComponent("current.xlsx")
        try Data("current".utf8).write(to: current)
        XCTAssertEqual(
            Command.resolveSourceWorkbookURL(explicit: nil, bundleURL: bundleURL, manifest: manifest)?.path,
            current.path,
            "a published current.xlsx carries the analyst's calls and wins"
        )
        XCTAssertEqual(
            Command.resolveSourceWorkbookURL(explicit: "/tmp/elsewhere.xlsx", bundleURL: bundleURL, manifest: manifest)?.path,
            "/tmp/elsewhere.xlsx"
        )
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
