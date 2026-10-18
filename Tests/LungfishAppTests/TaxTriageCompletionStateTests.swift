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
