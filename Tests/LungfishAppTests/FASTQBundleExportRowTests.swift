// FASTQBundleExportRowTests.swift - The Operations rows of the sidebar's FASTQ bundle export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.38, ARCH ruling 1.5 rules 3 and 4. `AppDelegate.beginFASTQBundleExportOperation` begins an
// export row with no lock and a cancel callback and records the `fastq export reads` command the runner runs.
// `runFASTQBundleExports` begins one row per bundle in order. `fastqExportSummary` keeps the alert words of the
// in-app writer. FASTQBundleExportCLIGUIParityReplayTests runs the command.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class FASTQBundleExportRowTests: XCTestCase {
    private let readsInvocation = FASTQReadsExport.invocation(
        bundleURL: URL(fileURLWithPath: "/tmp/lane 12.38/Sample one.lungfishfastq"),
        outputURL: URL(fileURLWithPath: "/tmp/lane 12.38/sample, one.fastq.gz"),
        isDerived: true,
        force: true
    )

    func testTheRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(AppDelegate.beginFASTQBundleExportOperation(
            invocation: readsInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ) { _ in })
        _ = await begun.task.value

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.id, begun.operationID)
        XCTAssertEqual(item.operationType, .export)
        XCTAssertNil(item.targetBundleURL, "an export takes no bundle lock")
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertTrue(item.hasCancelCallback, "the row's cancel stops the leaf")
        XCTAssertEqual(item.title, "Export FASTQ")
        XCTAssertEqual(item.initialDetail, "Writing sample, one.fastq.gz")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: FastqExportReadsSubcommand.self)
        XCTAssertEqual(command.invocation(), readsInvocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.bundlePath, "/tmp/lane 12.38/Sample one.lungfishfastq")
        XCTAssertTrue(command.materializeDerived)
        XCTAssertEqual(command.output.path, "/tmp/lane 12.38/sample, one.fastq.gz")
        XCTAssertTrue(command.output.force)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
    }

    func testABatchBeginsOneRowPerBundleInOrder() async throws {
        let reporter = RecordingOperationReporter()
        let exports = ["a", "b", "c"].map {
            AppDelegate.FASTQBundleExport(
                bundleURL: URL(fileURLWithPath: "/tmp/lane 12.38/\($0).lungfishfastq"),
                outputURL: URL(fileURLWithPath: "/tmp/lane 12.38/out/\($0).fastq"),
                isDerived: $0 == "b",
                title: $0
            )
        }
        let results = await AppDelegate.runFASTQBundleExports(
            exports,
            runner: { CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")) },
            reporter: reporter
        )
        XCTAssertEqual(results.map(\.export), exports)
        XCTAssertEqual(reporter.items.map(\.initialDetail), ["Writing a.fastq", "Writing b.fastq", "Writing c.fastq"])
        let derived = try RecordedCLICommand.parse(reporter.items[1].cliCommand, as: FastqExportReadsSubcommand.self)
        XCTAssertTrue(derived.materializeDerived, "a derived bundle passes --materialize-derived")
        let plain = try RecordedCLICommand.parse(reporter.items[0].cliCommand, as: FastqExportReadsSubcommand.self)
        XCTAssertFalse(plain.materializeDerived)
        XCTAssertFalse(plain.output.force, "--force is passed only for a file that exists")
    }

    /// The words of the alert after a batch are the in-app writer's, with the leaf's message as the error.
    func testTheSummaryKeepsTodaysAlertWords() {
        func export(_ title: String) -> AppDelegate.FASTQBundleExport {
            AppDelegate.FASTQBundleExport(
                bundleURL: URL(fileURLWithPath: "/tmp/\(title).lungfishfastq"),
                outputURL: URL(fileURLWithPath: "/tmp/out/\(title).fastq"), isDerived: false, title: title
            )
        }
        func result(_ title: String, _ end: AppDelegate.FASTQBundleExportResult.End) -> AppDelegate.FASTQBundleExportResult {
            AppDelegate.FASTQBundleExportResult(export: export(title), operationID: nil, end: end)
        }
        let single = AppDelegate.fastqExportSummary(for: [result("Sample A", .completed)])
        XCTAssertEqual(single?.title, "Export Complete")
        XCTAssertEqual(single?.message, "Sample A exported as Sample A.fastq.")
        XCTAssertEqual(single?.style, .informational)
        XCTAssertEqual(single?.revealURL, export("Sample A").outputURL)

        let both = AppDelegate.fastqExportSummary(for: [result("A", .completed), result("B", .completed)])
        XCTAssertEqual(both?.message, "Successfully exported 2 FASTQ file(s).")
        XCTAssertNil(both?.revealURL)

        let failed = AppDelegate.fastqExportSummary(for: [result("A", .failed("boom")), result("B", .failed("bang"))])
        XCTAssertEqual(failed?.title, "Export Failed")
        XCTAssertEqual(failed?.message, "A: boom\nB: bang")
        XCTAssertEqual(failed?.style, .critical)

        let partial = AppDelegate.fastqExportSummary(for: [result("A", .completed), result("B", .failed("bang"))])
        XCTAssertEqual(partial?.title, "Export Partially Complete")
        XCTAssertEqual(partial?.message, "1 succeeded, 1 failed.\n\nB: bang")
        XCTAssertEqual(partial?.style, .warning)

        XCTAssertNil(AppDelegate.fastqExportSummary(for: [result("A", .completed), result("B", .cancelled)]), "a cancel shows no alert")
    }
}
