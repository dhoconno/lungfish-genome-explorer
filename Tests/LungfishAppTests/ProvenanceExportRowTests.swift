// ProvenanceExportRowTests.swift - The Operations row of the provenance report export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.38, ARCH ruling 1.5 rules 3 and 4, row B9. `AppDelegate.beginProvenanceExportOperation` begins
// an export row with no lock and a cancel callback and records the `provenance export` command the runner runs, with
// `--allow-unpinned` only after Export Anyway…. `provenanceExportSummary` keeps the alert words of the in-process
// write. ProvenanceExportCLIGUIParityReplayTests runs the command.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class ProvenanceExportRowTests: XCTestCase {
    private let reportInput = URL(fileURLWithPath: "/tmp/lane 12.38/Sample one.lungfishfastq")
    private let reportOutput = URL(fileURLWithPath: "/tmp/lane 12.38/reads, provenance-shell")

    func testTheRowRecordsTheLeafCommandItRuns() async throws {
        let invocation = ProvenanceReportExport.invocation(
            inputURL: reportInput, format: .shell, outputDirectory: reportOutput, allowUnpinned: true
        )
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(AppDelegate.beginProvenanceExportOperation(
            invocation: invocation,
            format: .shell,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ) { _ in })
        let outcome = await begun.task.value

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.id, begun.operationID)
        XCTAssertEqual(item.operationType, .export)
        XCTAssertNil(item.targetBundleURL, "an export takes no bundle lock")
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertTrue(item.hasCancelCallback, "the row's cancel stops the leaf")
        XCTAssertEqual(item.title, "Export Provenance")
        XCTAssertEqual(item.initialDetail, "Writing reads, provenance-shell")
        XCTAssertEqual(outcome, .completed(reportOutput.appendingPathComponent("run.sh")), "a text leaf completes on exit 0")

        let line = try XCTUnwrap(item.cliCommand)
        let command = try RecordedCLICommand.parse(line, as: ProvenanceCommand.ExportSubcommand.self)
        XCTAssertEqual(command.input, "/tmp/lane 12.38/Sample one.lungfishfastq")
        XCTAssertEqual(command.exportFormat, "shell")
        XCTAssertTrue(command.allowUnpinned, "Export Anyway… becomes --allow-unpinned")
        XCTAssertEqual(command.output, "/tmp/lane 12.38/reads, provenance-shell")
        XCTAssertEqual(try RouteParityHarness.arguments(ofLine: line), invocation.arguments(), "the row records the arguments the runner runs")
        XCTAssertFalse(invocation.arguments().contains("--format"), "the text leaf runs without --format json")
    }

    func testTheFlagIsInTheCommandOnlyAfterExportAnyway() {
        let plain = ProvenanceReportExport.invocation(
            inputURL: reportInput, format: .python, outputDirectory: reportOutput, allowUnpinned: false
        )
        XCTAssertEqual(plain.canonicalArgv(), [
            CLICommandIdentity.executableName, "provenance", "export", "/tmp/lane 12.38/Sample one.lungfishfastq",
            "--export-format", "python", "--output", "/tmp/lane 12.38/reads, provenance-shell",
        ])
        let override = ProvenanceReportExport.invocation(
            inputURL: reportInput, format: .python, outputDirectory: reportOutput, allowUnpinned: true
        )
        XCTAssertEqual(override.canonicalArgv().filter { $0 == ProvenanceExporter.allowUnpinnedFlag }.count, 1)
        XCTAssertEqual(Set(override.canonicalArgv()).subtracting(plain.canonicalArgv()), [ProvenanceExporter.allowUnpinnedFlag])
    }

    func testEveryFormatLinksItsPrimaryArtifact() async throws {
        let names: [ProvenanceExportFormat: String] = [
            .shell: "run.sh", .python: "reproduce.py", .nextflow: "main.nf", .snakemake: "Snakefile",
            .methods: "methods.md", .json: "provenance.json",
        ]
        XCTAssertEqual(Set(names.keys), Set(ProvenanceExportFormat.allCases))
        for format in ProvenanceExportFormat.allCases {
            let begun = try XCTUnwrap(AppDelegate.beginProvenanceExportOperation(
                invocation: ProvenanceReportExport.invocation(
                    inputURL: reportInput, format: format, outputDirectory: reportOutput, allowUnpinned: false
                ),
                format: format,
                runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
                reporter: RecordingOperationReporter()
            ) { _ in })
            let outcome = await begun.task.value
            XCTAssertEqual(outcome, .completed(reportOutput.appendingPathComponent(try XCTUnwrap(names[format]))), format.cliToken)
        }
    }

    func testAFailedLeafFailsTheRowAndReachesTheCaller() async throws {
        let reports = FailureReports()
        let begun = try XCTUnwrap(AppDelegate.beginProvenanceExportOperation(
            invocation: ProvenanceReportExport.invocation(
                inputURL: reportInput, format: .json, outputDirectory: reportOutput, allowUnpinned: false
            ),
            format: .json,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: RecordingOperationReporter()
        ) { reports.messages.append($0.message) })
        let outcome = await begun.task.value
        guard case .failed(let failure) = outcome else { return XCTFail("expected a failure, got \(outcome)") }
        XCTAssertEqual(reports.messages, [failure.message])
        XCTAssertEqual(AppDelegate.provenanceExportSummary(format: .json, outcome: outcome)?.message, failure.message)
    }

    /// The words of the alert after an export are the in-process write's, with the leaf's message as the error.
    func testTheSummaryKeepsTodaysAlertWords() {
        let url = URL(fileURLWithPath: "/tmp/out/run.sh")
        let complete = AppDelegate.provenanceExportSummary(format: .shell, outcome: .completed(url))
        XCTAssertEqual(complete?.title, "Provenance Export Complete")
        XCTAssertEqual(complete?.message, "Shell Script exported to run.sh.")
        XCTAssertEqual(complete?.style, .informational)
        XCTAssertEqual(complete?.revealURL, url)

        let failed = AppDelegate.provenanceExportSummary(
            format: .json, outcome: .failed(CLIViewerExportRunner.Failure(message: "boom"))
        )
        XCTAssertEqual(failed?.title, "Export Failed")
        XCTAssertEqual(failed?.message, "boom")
        XCTAssertEqual(failed?.style, .warning)
        XCTAssertNil(failed?.revealURL)

        XCTAssertNil(AppDelegate.provenanceExportSummary(format: .json, outcome: .cancelled), "a cancel shows no alert")
        XCTAssertEqual(AppDelegate.provenanceExportFailureSummary("The selected path exists and is not a folder: /x").title, "Export Failed")
    }
}

@MainActor
private final class FailureReports {
    var messages: [String] = []
}
