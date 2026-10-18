// TaxTriageCompletionStateTests.swift - The words a finished TaxTriage result gives its row; host taxa field defaults
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class TaxTriageCompletionStateTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "taxtriage-completion-state")
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    private func result(
        ignoredFailures: [TaxTriageIgnoredFailure],
        sampleFailures: [TaxTriageSampleFailure] = [],
        reportFiles: [URL] = []
    ) -> TaxTriageResult {
        let config = TaxTriageConfig(
            samples: [
                TaxTriageSample(sampleId: "SRR12486983", fastq1: URL(fileURLWithPath: "/data/a.fastq")),
                TaxTriageSample(sampleId: "SRR12486989", fastq1: URL(fileURLWithPath: "/data/b.fastq")),
            ],
            outputDirectory: root.appendingPathComponent("taxtriage-batch", isDirectory: true)
        )
        return TaxTriageResult(
            config: config,
            runtime: 10,
            exitCode: 0,
            outputDirectory: config.outputDirectory,
            reportFiles: reportFiles,
            ignoredFailures: ignoredFailures,
            sampleFailures: sampleFailures
        )
    }

    private func sampleFailure(_ sampleID: String) -> TaxTriageSampleFailure {
        TaxTriageSampleFailure(
            sampleID: sampleID,
            outputDirectory: URL(fileURLWithPath: "/tmp/taxtriage-batch/\(sampleID)"),
            errorDescription: "boom \(sampleID)"
        )
    }

    /// The completion the row of a `taxtriage run` gets, `result` saved into its folder and read back
    /// as the CLI route reads it (`CLIClassifierRunner.taxTriageCompletion(folder:)`).
    private func completion(_ result: TaxTriageResult) throws -> CLIClassifierCompletion {
        try FileManager.default.createDirectory(at: result.outputDirectory, withIntermediateDirectories: true)
        try result.save()
        return try CLIClassifierRunner.taxTriageCompletion(folder: result.outputDirectory)
    }

    private func minimapKilled(_ sampleID: String) -> TaxTriageIgnoredFailure {
        TaxTriageIgnoredFailure(
            processPath: "NFCORE_TAXTRIAGE:TAXTRIAGE:ALIGNMENT:MINIMAP2_ALIGN",
            processName: "MINIMAP2_ALIGN",
            taskLabel: "\(sampleID).\(sampleID).dwnld.references",
            sampleID: sampleID,
            exitCode: 137,
            attempts: 4,
            diagnostic: "Killed: minimap2 -ax sr -t 14 ..."
        )
    }

    // MARK: - The words of the finish
    //
    // Phase 2.8 lane U2 pinned these words on the finish of the in-process route (T8, T9 and D4 of
    // docs/plans/2026-10-11-phase-2-8.md). Since Phase 2.12 K1 the Tools menu runs `taxtriage run` only, and
    // its row reads the finished result back with `CLIClassifierRunner.taxTriageCompletion(folder:)`, so the
    // pins hold the words of that read-back. The paragraph of ignored task failures is a line of the command,
    // which `TaxTriageCLIRouteRowTests.testIgnoredTasksReadCompletedWithWarningsAndOneWarningLine` pins as the
    // row's one warning line, so the read-back adds no copy of it. A warning line makes the row read Completed
    // with Warnings (D4), which the row tests of `TaxTriageCLIRouteRowTests` pin on the whole route.

    func testErroredTasksNameTheProcessAndTheReportCountInTheDetail() throws {
        let finished = result(ignoredFailures: [minimapKilled("SRR12486983"), minimapKilled("SRR12486989")])
        let read = try completion(finished)

        XCTAssertEqual(
            read.detail,
            "Some TaxTriage tasks failed: MINIMAP2_ALIGN failed for SRR12486983, SRR12486989 after 4 attempts (killed, usually for running out of memory) (0 reports)"
        )
        XCTAssertTrue(try XCTUnwrap(finished.erroredProcessesMessage).contains("Exclude host taxa (9606 for human)"))
        // T8 and D4: the command's one warning line of the cause makes the label, so the read-back adds
        // none, and the detail is no second line.
        XCTAssertEqual(read.warnings, [])
        XCTAssertFalse(read.completesWithWarning)
    }

    func testACleanResultWarnsOfNothingAndShowsItsWholeSummary() throws {
        let finished = result(ignoredFailures: [])
        let read = try completion(finished)

        XCTAssertEqual(read.detail, finished.summary)
        XCTAssertEqual(read.warnings, [])
        XCTAssertFalse(read.completesWithWarning)
    }

    func testOneFailedSampleReadsASingularNounAndWarnsOnce() throws {
        let read = try completion(result(ignoredFailures: [], sampleFailures: [sampleFailure("SRR12486989")]))

        // One item reads in the singular and zero stays plural (T9). The detail is no second line.
        XCTAssertEqual(read.detail, "1 failed sample (0 reports)")
        XCTAssertEqual(read.warnings, ["1 TaxTriage sample failed (SRR12486989: boom SRR12486989)"])
    }

    func testTheReportCountReadsSingularForOneAndPluralOtherwise() throws {
        func detail(reports count: Int) throws -> String {
            let files = (0..<count).map { URL(fileURLWithPath: "/tmp/taxtriage-batch/report-\($0).html") }
            return try completion(result(
                ignoredFailures: [],
                sampleFailures: [sampleFailure("SRR12486989")],
                reportFiles: files
            )).detail
        }

        XCTAssertEqual(try detail(reports: 0), "1 failed sample (0 reports)")
        XCTAssertEqual(try detail(reports: 1), "1 failed sample (1 report)")
        XCTAssertEqual(try detail(reports: 2), "1 failed sample (2 reports)")
    }

    func testSixFailedSamplesListFiveAndCountTheRest() throws {
        let ids = (1...6).map { "S\($0)" }
        let read = try completion(result(ignoredFailures: [], sampleFailures: ids.map(sampleFailure)))

        XCTAssertEqual(read.detail, "6 failed samples (0 reports)")
        XCTAssertEqual(
            read.warnings,
            ["6 TaxTriage samples failed (S1: boom S1; S2: boom S2; S3: boom S3; S4: boom S4; S5: boom S5; +1 more)"]
        )
    }

    func testAnErroredTaskAndAFailedSampleShareOneDetail() throws {
        let finished = result(ignoredFailures: [minimapKilled("SRR12486983")], sampleFailures: [sampleFailure("SRR12486989")])
        let read = try completion(finished)

        let headline = try XCTUnwrap(finished.erroredProcessesHeadline)
        XCTAssertEqual(read.detail, "\(headline); 1 failed sample (0 reports)")
        // One warning line per cause (T9). The failed sample's is the read-back's and the paragraph is the
        // command's, so the detail is no third line.
        XCTAssertEqual(read.warnings, ["1 TaxTriage sample failed (SRR12486989: boom SRR12486989)"])
    }

    func testTheSummaryCountsOneAffectedSampleInTheSingular() {
        XCTAssertTrue(
            result(ignoredFailures: [minimapKilled("SRR12486983")]).summary
                .contains("Ignored task failures: 1 across 1 sample\n")
        )
        XCTAssertTrue(
            result(ignoredFailures: [minimapKilled("SRR12486983"), minimapKilled("SRR12486989")]).summary
                .contains("Ignored task failures: 2 across 2 samples\n")
        )
    }

    // MARK: - The row's bar

    /// The database stage owns the last tenth of the bar (W3, U38 M3), so the row scales the runner's
    /// fraction onto the first nine tenths, as the executor scales its units
    /// (`AnalysisRunJournal.runFraction`). The runner's own end, 1.0, reads 0.9 on the row and the stage
    /// has room to move the bar before the row completes. A fraction outside 0...1 is held to it.
    func testTheRunnersEndReadsWhereTheDatabaseStagesShareBegins() {
        let engineEnd = 1 - NextflowWorkflowDescriptor.taxTriage.finalizeProgressShare
        XCTAssertEqual(engineEnd, 0.9, accuracy: 1e-12)
        for runnerValue in [0.0, 0.05, 0.1, 0.43, 0.86, 0.9, 0.95, 1.0] {
            XCTAssertEqual(AppDelegate.taxTriageEngineBar(runnerValue), runnerValue * engineEnd, accuracy: 1e-12)
        }
        // The middle of sample 10 of 10 reads below the runner's end, where a cap read both on 0.9.
        XCTAssertLessThan(AppDelegate.taxTriageEngineBar(0.95), AppDelegate.taxTriageEngineBar(1.0))
        XCTAssertEqual(AppDelegate.taxTriageEngineBar(7.0), engineEnd, accuracy: 1e-12)
        XCTAssertEqual(AppDelegate.taxTriageEngineBar(-1), 0)
    }

    /// A serial batch maps sample `i` of `N` onto `(i + f) / N` (`TaxTriageSerialBatchRunner`), so its
    /// last samples report 0.9 and more before the batch ends. That is from the middle of sample 5 of 5,
    /// through all of sample 10 of 10 and in the last 2.4 samples of 24. The row's bar scales the
    /// fraction instead of capping it, so the bar keeps moving through the whole last sample, stays
    /// below 0.9 until the runner's last report and ends on 0.9, where the database stage takes over.
    /// A cap at 0.9 froze the bar through those samples while the detail kept moving (U38 review, fix 1).
    func testASerialBatchsBarKeepsMovingThroughItsLastSample() {
        let engineEnd = 1 - NextflowWorkflowDescriptor.taxTriage.finalizeProgressShare
        for total in [2, 5, 10, 24] {
            // Every twentieth of the last sample, from its start to its end, as the batch maps it.
            let reports = (0...20).map { (Double(total - 1) + Double($0) / 20) / Double(total) }
            let bars = reports.map { AppDelegate.taxTriageEngineBar($0) }
            for (earlier, later) in zip(bars, bars.dropFirst()) {
                XCTAssertLessThan(earlier, later, "\(total) samples, the bar froze at \(earlier), \(bars)")
            }
            XCTAssertLessThan(bars.dropLast().max() ?? 1, engineEnd, "\(total) samples, \(bars)")
            XCTAssertEqual(bars.last ?? -1, engineEnd, accuracy: 1e-12, "\(total) samples, \(bars)")
        }
    }

    // MARK: - Exclude host taxa field

    func testExcludeHostTaxaFollowsSampleRolesUntilEdited() {
        XCTAssertEqual(
            TaxTriageWizardSheet.removeTaxidsText(current: "", userEdited: false, sampleRoles: [.testSample]),
            "9606"
        )
        XCTAssertEqual(
            TaxTriageWizardSheet.removeTaxidsText(current: "9606", userEdited: false, sampleRoles: [.negativeControl]),
            ""
        )
        XCTAssertEqual(
            TaxTriageWizardSheet.removeTaxidsText(current: "10090", userEdited: true, sampleRoles: [.testSample]),
            "10090",
            "a value the user typed is never replaced"
        )
    }

    func testExcludeHostTaxaValidationAndExtraArgumentsOverride() {
        XCTAssertNil(TaxTriageWizardSheet.removeTaxidsValidationMessage("9606 10090"))
        XCTAssertNil(TaxTriageWizardSheet.removeTaxidsValidationMessage(""))
        XCTAssertNotNil(TaxTriageWizardSheet.removeTaxidsValidationMessage("human"))

        XCTAssertEqual(TaxTriageWizardSheet.effectiveRemoveTaxids(text: "9606", extraArguments: []), "9606")
        XCTAssertNil(TaxTriageWizardSheet.effectiveRemoveTaxids(text: "  ", extraArguments: []))
        XCTAssertNil(TaxTriageWizardSheet.effectiveRemoveTaxids(
            text: "9606",
            extraArguments: ["--remove_taxids", "2"]
        ))
    }
}
