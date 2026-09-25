// TaxTriageCompletionStateTests.swift - Errored TaxTriage tasks finish as a warning; host taxa field defaults
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishKit
import LungfishWorkflow

@MainActor
final class TaxTriageCompletionStateTests: XCTestCase {

    private func result(ignoredFailures: [TaxTriageIgnoredFailure]) -> TaxTriageResult {
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
            ignoredFailures: ignoredFailures
        )
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
        let id = center.start(title: "TaxTriage (2 samples)", detail: "Starting", operationType: .classification)

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
            "TaxTriage completed with errors: MINIMAP2_ALIGN failed for SRR12486983, SRR12486989 after 4 attempts (Killed: out of memory) (0 reports)"
        )
        XCTAssertTrue(item.logEntries.contains { entry in
            entry.level == .warning && entry.message.contains("Exclude host taxa (9606 for human)")
        })
    }

    func testCleanRunFinishesAsPlainCompleted() throws {
        let center = OperationCenter()
        let id = center.start(title: "TaxTriage (2 samples)", detail: "Starting", operationType: .classification)

        XCTAssertTrue(AppDelegate.finishTaxTriageOperation(id: id, result: result(ignoredFailures: []), center: center))

        let item = try XCTUnwrap(center.items.first { $0.id == id })
        XCTAssertEqual(item.displayStateLabel, "Completed")
        XCTAssertFalse(item.hasWarnings)
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
