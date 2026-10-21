// PrimerAnalysisExportRowTests.swift - The Operations rows of the two primer exports that run the CLI
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.13 lane 13.43 M3, ARCH ruling 1.5 rule 3 and rule 5 of cli-parity-gaps. `MainSplitViewController`'s
// `beginPrimerOrderExportOperation` and `beginPrimerAnalysisSelectionExportOperation` each begin a row that locks the
// new folder, keeps today's title and first detail, records the command the runner runs, has a cancel callback, and
// launches nothing when the row is refused. A leaf that fails fails the run and reloads nothing.
// PrimerExportCLIGUIParityReplayTests runs both commands through the built binary.

import AppKit
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishWorkflow

@MainActor
private final class CompletedCalls {
    var count = 0
}

@MainActor
final class PrimerAnalysisExportRowTests: XCTestCase {
    private let analysis = "/tmp/lane 13.43/Project.lungfish/Analyses/design A.lungfishprimeranalysis"
    private let orderFolder = "/tmp/lane 13.43/Project.lungfish/Analyses/Pair order-1a2b3c4d"
    private let selectionFolder = "/tmp/lane 13.43/Project.lungfish/Analyses/design A primers-5e6f7a8b.lungfishref"
    private let route = OperationRouteContext(
        projectURL: URL(fileURLWithPath: "/tmp/lane 13.43/Project.lungfish"), windowStateScopeID: UUID())

    private var orderInvocation: ViewerExportInvocation {
        ViewerExportInvocation(
            commandPath: PrimerOrderExport.commandPath, input: analysis,
            leafArguments: ["--scope", "candidate-pairs", "--name=Pair order", "--requested-by=Bench"],
            output: orderFolder)
    }

    private var selectionInvocation: ViewerExportInvocation {
        ViewerExportInvocation(
            commandPath: PrimerSelectionExport.commandPath, input: analysis,
            leafArguments: ["--kind", "primer-fasta", "--target-id=target-1", "--primer-id=primer-1"],
            output: selectionFolder)
    }

    func testTheOrderRowRecordsTheLeafCommandItRunsAndKeepsTodaysWords() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(MainSplitViewController.beginPrimerOrderExportOperation(
            title: "Export Candidate Pairs", detail: "Verifying 2 candidate oligos…", invocation: orderInvocation,
            routeContext: route, runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")),
            reporter: reporter
        ) {})
        _ = await begun.task.value

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.id, begun.operationID)
        XCTAssertEqual(item.title, "Export Candidate Pairs")
        XCTAssertEqual(item.initialDetail, "Verifying 2 candidate oligos…")
        XCTAssertEqual(item.operationType, .workflow)
        XCTAssertEqual(item.targetBundleURL?.path, orderFolder, "the row locks the new order folder")
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertTrue(item.hasCancelCallback, "the row's cancel stops the leaf")
        XCTAssertEqual(
            item.cliCommand,
            OperationCenter.buildCLICommand(
                subcommand: "primers analysis export-order", args: Array(orderInvocation.arguments().dropFirst(3))),
            "the row records the arguments the runner runs")
        let command = try RecordedCLICommand.parse(item.cliCommand, as: PrimerAnalysisExportOrderCommand.self)
        XCTAssertEqual(command.bundlePath, analysis)
        XCTAssertEqual(command.outputPath, orderFolder)
        XCTAssertEqual(command.scope, .candidatePairs)
        XCTAssertEqual(command.name, "Pair order")
        XCTAssertEqual(command.requestedBy, "Bench")
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
    }

    func testTheSelectionRowRecordsTheLeafCommandItRunsAndKeepsTodaysWords() async throws {
        let reporter = RecordingOperationReporter()
        let begun = try XCTUnwrap(MainSplitViewController.beginPrimerAnalysisSelectionExportOperation(
            title: "Save Primer FASTA Bundle", invocation: selectionInvocation, routeContext: route,
            runner: CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/true")), reporter: reporter
        ) {})
        _ = await begun.task.value

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.id, begun.operationID)
        XCTAssertEqual(item.title, "Save Primer FASTA Bundle")
        XCTAssertEqual(item.initialDetail, "Verifying saved primer analysis…")
        XCTAssertEqual(item.operationType, .workflow)
        XCTAssertEqual(item.targetBundleURL?.path, selectionFolder, "the row locks the new export folder")
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertTrue(item.hasCancelCallback, "the row's cancel stops the leaf")
        XCTAssertEqual(
            item.cliCommand,
            OperationCenter.buildCLICommand(
                subcommand: "primers analysis export-selection", args: Array(selectionInvocation.arguments().dropFirst(3))),
            "the row records the arguments the runner runs")
        let command = try RecordedCLICommand.parse(item.cliCommand, as: PrimerAnalysisExportSelectionCommand.self)
        XCTAssertEqual(command.bundlePath, analysis)
        XCTAssertEqual(command.outputPath, selectionFolder)
        XCTAssertEqual(command.kind, .primerFASTA)
        XCTAssertEqual(command.targetID, "target-1")
        XCTAssertEqual(command.primerID, "primer-1")
        XCTAssertEqual(command.globalOptions.outputFormat, .json, "the runner reads the leaf's events")
    }

    func testARefusedRowLaunchesNothingForBothExports() throws {
        let reporter = RecordingOperationReporter(lockHeldBy: "Another export")
        let failing = CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false"))
        let order = MainSplitViewController.beginPrimerOrderExportOperation(
            title: "Export Candidate Pairs", detail: "Verifying 2 candidate oligos…", invocation: orderInvocation,
            routeContext: route, runner: failing, reporter: reporter
        ) { XCTFail("a refused row runs nothing, so nothing completes") }
        let selection = MainSplitViewController.beginPrimerAnalysisSelectionExportOperation(
            title: "Save Primer FASTA Bundle", invocation: selectionInvocation, routeContext: route,
            runner: failing, reporter: reporter
        ) { XCTFail("a refused row runs nothing, so nothing completes") }

        XCTAssertNil(order)
        XCTAssertNil(selection)
        XCTAssertEqual(reporter.items.map(\.state), [.refused, .refused])
        let orderCommand = try RecordedCLICommand.parse(
            reporter.items.first?.cliCommand, as: PrimerAnalysisExportOrderCommand.self)
        XCTAssertEqual(orderCommand.outputPath, orderFolder)
        let selectionCommand = try RecordedCLICommand.parse(
            reporter.items.last?.cliCommand, as: PrimerAnalysisExportSelectionCommand.self)
        XCTAssertEqual(selectionCommand.outputPath, selectionFolder)
    }

    /// A leaf that fails fails the run with its message and reloads nothing, since it wrote no folder.
    func testAFailedLeafFailsTheRunAndDoesNotReloadTheSidebar() async throws {
        let calls = CompletedCalls()
        let failing = CLIViewerExportRunner(cliURLOverride: URL(fileURLWithPath: "/usr/bin/false"))
        let order = try XCTUnwrap(MainSplitViewController.beginPrimerOrderExportOperation(
            title: "Export Candidate Pairs", detail: "Verifying 2 candidate oligos…", invocation: orderInvocation,
            routeContext: route, runner: failing, reporter: RecordingOperationReporter()
        ) { calls.count += 1 })
        let selection = try XCTUnwrap(MainSplitViewController.beginPrimerAnalysisSelectionExportOperation(
            title: "Save Primer FASTA Bundle", invocation: selectionInvocation, routeContext: route,
            runner: failing, reporter: RecordingOperationReporter()
        ) { calls.count += 1 })
        for outcome in [await order.task.value, await selection.task.value] {
            guard case .failed(let failure) = outcome else { return XCTFail("the leaf failed, the run ended \(outcome)") }
            XCTAssertFalse(failure.message.isEmpty)
        }
        XCTAssertEqual(calls.count, 0, "a failed export reloads nothing")
    }
}
