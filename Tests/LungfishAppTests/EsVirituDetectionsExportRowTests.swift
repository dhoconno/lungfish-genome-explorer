// EsVirituDetectionsExportRowTests.swift - The Operations row of the EsViritu detections export
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.12 lane 12.31 M3, ARCH ruling 1.5 rule 3. `EsVirituResultViewController.beginEsVirituDetectionsExportOperation`
// begins an export row with no lock and a cancel callback, records the `esviritu export detections` command the
// runner runs, and launches nothing when the row is refused. EsVirituExportCLIGUIParityReplayTests runs the command.

import XCTest
@testable import LungfishCLI
@testable import LungfishEsVirituUI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
final class EsVirituDetectionsExportRowTests: XCTestCase {
    private let exportInvocation = EsVirituDetectionExport.invocation(
        resultURL: URL(fileURLWithPath: "/tmp/lane 12.31/Project.lungfish/Analyses/esviritu-batch", isDirectory: true),
        samples: ["sample-A", "sample B"],
        metadataColumns: ["Group"],
        format: .csv,
        outputURL: URL(fileURLWithPath: "/tmp/lane 12.31/detections, all.csv"),
        force: true
    )

    func testTheRowRecordsTheLeafCommandItRuns() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(EsVirituResultViewController.beginEsVirituDetectionsExportOperation(
            invocation: exportInvocation,
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
        XCTAssertEqual(item.title, "Export EsViritu Detections")
        XCTAssertEqual(item.initialDetail, "Writing detections, all.csv")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: EsVirituCommand.ExportDetectionsSubcommand.self)
        XCTAssertEqual(try command.invocation(), exportInvocation, "the row records the arguments the runner runs")
        XCTAssertEqual(command.samples.samples, ["sample-A", "sample B"])
        XCTAssertEqual(command.output.path, "/tmp/lane 12.31/detections, all.csv")
        XCTAssertTrue(command.output.force)
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
    }

    func testARefusedRowLaunchesNothing() throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Another export")
        let begun = EsVirituResultViewController.beginEsVirituDetectionsExportOperation(
            invocation: exportInvocation,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false")),
            reporter: reporter
        ) { _ in XCTFail("a refused row runs nothing, so nothing fails") }

        XCTAssertNil(begun)
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
        let command = try RecordedCLICommand.parse(
            reporter.items.first?.cliCommand, as: EsVirituCommand.ExportDetectionsSubcommand.self
        )
        XCTAssertEqual(try command.invocation(), exportInvocation)
    }
}
