// TaxTriageCompletionStateTests.swift - Errored TaxTriage tasks finish as a warning; host taxa field defaults
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class TaxTriageCompletionStateTests: XCTestCase {

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
            outputDirectory: URL(fileURLWithPath: "/tmp/taxtriage-batch")
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

    /// Finishes a fresh row with `result` and returns the row.
    private func finishedRow(_ result: TaxTriageResult) throws -> OperationCenter.Item {
        let center = OperationCenter()
        let id = center.begin(
            title: "TaxTriage (2 samples)",
            detail: "Starting",
            operationType: .classification,
            cliCommand: nil
        ).rowID
        XCTAssertTrue(AppDelegate.finishTaxTriageOperation(id: id, result: result, center: center))
        return try XCTUnwrap(center.items.first { $0.id == id })
    }

    private func warningLines(of item: OperationCenter.Item) -> [String] {
        item.logEntries.filter { $0.level == .warning }.map(\.message)
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

    // MARK: - Operation state

    func testErroredTasksFinishTheOperationAsCompletedWithWarnings() throws {
        let center = OperationCenter()
        let id = center.begin(
            title: "TaxTriage (2 samples)",
            detail: "Starting",
            operationType: .classification,
            cliCommand: nil
        ).rowID

        let finished = AppDelegate.finishTaxTriageOperation(
            id: id,
            result: result(ignoredFailures: [minimapKilled("SRR12486983"), minimapKilled("SRR12486989")]),
            center: center
        )

        XCTAssertTrue(finished)
        let item = try XCTUnwrap(center.items.first { $0.id == id })
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.displayStateLabel, "Completed with Warnings")
        XCTAssertEqual(
            item.detail,
            "TaxTriage completed with errors: MINIMAP2_ALIGN failed for SRR12486983, SRR12486989 after 4 attempts (killed, usually for running out of memory) (0 reports)"
        )
        XCTAssertTrue(item.logEntries.contains { entry in
            entry.level == .warning && entry.message.contains("Exclude host taxa (9606 for human)")
        })
    }

    func testCleanRunFinishesAsPlainCompleted() throws {
        let center = OperationCenter()
        let id = center.begin(
            title: "TaxTriage (2 samples)",
            detail: "Starting",
            operationType: .classification,
            cliCommand: nil
        ).rowID

        XCTAssertTrue(AppDelegate.finishTaxTriageOperation(id: id, result: result(ignoredFailures: []), center: center))

        let item = try XCTUnwrap(center.items.first { $0.id == id })
        XCTAssertEqual(item.displayStateLabel, "Completed")
        XCTAssertFalse(item.hasWarnings)
    }

    // MARK: - The words of the finish
    //
    // Phase 2.8 lane U2, milestone M1. These pin the words and the warning lines of
    // `finishTaxTriageOperation` as they read today, so the fixes of milestone M3 (T8 and T9 of
    // docs/plans/2026-10-11-phase-2-8.md) flip them one at a time. The row text of a whole run is
    // pinned in `TaxTriageOperationRowTextReplayTests`.

    func testOneFailedSampleReadsASingularNoun() throws {
        let item = try finishedRow(result(ignoredFailures: [], sampleFailures: [sampleFailure("SRR12486989")]))

        XCTAssertEqual(item.displayStateLabel, "Completed with Warnings")
        // T9: one item reads in the singular and zero stays plural.
        XCTAssertEqual(item.detail, "1 failed sample (0 reports)")
        XCTAssertEqual(
            warningLines(of: item),
            ["1 TaxTriage sample failed (SRR12486989: boom SRR12486989)", "1 failed sample (0 reports)"]
        )
    }

    func testTheReportCountReadsSingularForOneAndPluralOtherwise() throws {
        func detail(reports count: Int) throws -> String {
            let files = (0..<count).map { URL(fileURLWithPath: "/tmp/taxtriage-batch/report-\($0).html") }
            return try finishedRow(result(
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
        let item = try finishedRow(result(ignoredFailures: [], sampleFailures: ids.map(sampleFailure)))

        XCTAssertEqual(item.detail, "6 failed samples (0 reports)")
        XCTAssertEqual(
            warningLines(of: item).first,
            "6 TaxTriage samples failed (S1: boom S1; S2: boom S2; S3: boom S3; S4: boom S4; S5: boom S5; +1 more)"
        )
    }

    func testAnErroredTaskAndAFailedSampleShareOneDetail() throws {
        let finished = result(ignoredFailures: [minimapKilled("SRR12486983")], sampleFailures: [sampleFailure("SRR12486989")])
        let item = try finishedRow(finished)

        let headline = try XCTUnwrap(finished.erroredProcessesHeadline)
        XCTAssertEqual(item.detail, "\(headline); 1 failed sample (0 reports)")
        // M3 (T9): one warning line per cause, so the detail is no third line.
        XCTAssertEqual(
            warningLines(of: item),
            [
                try XCTUnwrap(finished.erroredProcessesMessage),
                "1 TaxTriage sample failed (SRR12486989: boom SRR12486989)",
                item.detail,
            ]
        )
    }

    func testAnErroredTaskCauseLogsItsParagraphAndItsDetailAsWarnings() throws {
        let finished = result(ignoredFailures: [minimapKilled("SRR12486983")])
        let item = try finishedRow(finished)

        // M3 (T9): the paragraph is the one warning line of the cause. Today the detail follows it
        // as a second warning, because `completeWithWarning` appends it, and the pipeline's last
        // progress message adds the paragraph again at information level.
        XCTAssertEqual(warningLines(of: item), [try XCTUnwrap(finished.erroredProcessesMessage), item.detail])
        XCTAssertEqual(item.logEntries.count, 2)
    }

    func testACleanResultLogsNothingAndShowsItsWholeSummary() throws {
        let finished = result(ignoredFailures: [])
        let item = try finishedRow(finished)

        XCTAssertEqual(item.detail, finished.summary)
        XCTAssertTrue(item.logEntries.isEmpty)
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
