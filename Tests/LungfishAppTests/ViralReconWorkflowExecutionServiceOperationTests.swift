// ViralReconWorkflowExecutionServiceOperationTests.swift - the begin() site in ViralReconWorkflowExecutionService
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The Viral Recon launch locks its run bundle (R4). Before this site moved to
// begin(), a refused lock left the run launching anyway under a failed
// "Bundle is busy" row. A held lock must now refuse the row, launch nothing
// and leave no second failed row behind. `lungfish-cli workflow run
// nf-core/viralrecon` reproduces the launch, so the recorded command must
// parse with the values the request uses. The service keeps its injected
// `OperationCenter`, because it reads the row's state while a run is
// cancelled, so the refusal tests use a real center that holds the lock and
// the recorded-row tests call the begin helper with a recording reporter.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class ViralReconWorkflowExecutionServiceOperationTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = try TestTempDirectory.make(prefix: "viral-recon-operation")
    }

    override func tearDown() {
        if let tempDirectory {
            TestTempDirectory.cleanup(tempDirectory)
        }
        tempDirectory = nil
        super.tearDown()
    }

    private var bundleURL: URL {
        tempDirectory
            .appendingPathComponent("Analyses", isDirectory: true)
            .appendingPathComponent("viralrecon.lungfishrun", isDirectory: true)
    }

    /// A fresh center that already holds the whole Analyses folder, as when
    /// another operation is running on it.
    private func centerHoldingTheAnalysesFolder() throws -> OperationCenter {
        let center = OperationCenter()
        center.failureReportStore = .temporaryForTesting()
        _ = try XCTUnwrap(center.begin(
            title: "Existing writer",
            detail: "Running",
            operationType: .workflow,
            targetBundleURL: tempDirectory.appendingPathComponent("holder.lungfishrun", isDirectory: true),
            additionalLockedBundleURLs: [bundleURL.deletingLastPathComponent()],
            cliCommand: "lungfish-cli workflow run"
        ).startedID)
        return center
    }

    // MARK: - Recorded row

    func testRecordsAViralReconRowLockingTheRunBundleAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = OperationRouteContext(projectURL: nil, windowStateScopeID: UUID())
        let request = try ViralReconAppTestFixtures.illuminaRequest(root: tempDirectory)

        let operationID = try ViralReconWorkflowExecutionService.beginViralReconOperation(
            request: request,
            bundleURL: bundleURL,
            routeContext: routeContext,
            reporter: reporter
        )

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(operationID, item.id)
        XCTAssertEqual(reporter.items.count, 1)
        XCTAssertEqual(item.title, "Viral Recon")
        XCTAssertEqual(item.initialDetail, "illumina · 1 sample(s) · MN908947.3")
        XCTAssertEqual(item.operationType, .viralRecon)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)

        let command = try RecordedCLICommand.parse(item.cliCommand, as: RunSubcommand.self)
        XCTAssertEqual(command.workflow, "nf-core/viralrecon")
        XCTAssertEqual(command.executor, request.executor)
        XCTAssertEqual(command.resultsDir, request.outputDirectory.path)
        XCTAssertEqual(command.bundlePath, bundleURL.path)
        XCTAssertEqual(command.version, request.version)
        XCTAssertEqual(command.input, [request.samplesheetURL.path])
        XCTAssertEqual(command.expectedOutput, [request.outputDirectory.path])
        let expectedParams = request.effectiveParams
            .filter { $0.key != "input" && $0.key != "outdir" && !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
        XCTAssertEqual(command.params, expectedParams)
        XCTAssertFalse(command.prepareOnly)
        XCTAssertEqual(
            item.cliCommand,
            OperationCenter.buildCLICommand(
                subcommand: "workflow run",
                args: Array(request.cliArguments(bundlePath: bundleURL).dropFirst(2))
            ),
            "the row records the same string as before, which buildCLICommand also produces"
        )
    }

    // MARK: - Refused row

    func testARefusedRowThrowsAReportedFailureAroundTheRefusal() throws {
        let center = try centerHoldingTheAnalysesFolder()
        let request = try ViralReconAppTestFixtures.illuminaRequest(root: tempDirectory)

        XCTAssertThrowsError(
            try ViralReconWorkflowExecutionService.beginViralReconOperation(
                request: request,
                bundleURL: bundleURL,
                routeContext: nil,
                reporter: center
            )
        ) { error in
            guard let reported = error as? ViralReconReportedFailure,
                  let refused = reported.underlying as? OperationRefusedError else {
                return XCTFail("a refused begin must throw ViralReconReportedFailure around OperationRefusedError, got \(error)")
            }
            XCTAssertEqual(refused.refusal.blockingOperationTitle, "Existing writer")
            XCTAssertTrue(ViralReconWorkflowExecutionService.failureWasReportedOnItsOperationRow(error))
        }
    }

    func testARefusedRunLaunchesNothingAndLeavesNoSecondFailedRow() async throws {
        let center = try centerHoldingTheAnalysesFolder()
        let request = try ViralReconAppTestFixtures.illuminaRequest(root: tempDirectory)
        let runner = CountingViralReconProcessRunner()
        let service = ViralReconWorkflowExecutionService(
            operationCenter: center,
            processRunner: runner,
            referenceDownloader: { _, _ in },
            resultIngest: { _ in XCTFail("a refused run must ingest nothing") }
        )
        var thrown: Error?

        do {
            _ = try await service.run(request, bundleRoot: bundleURL.deletingLastPathComponent())
            XCTFail("a refused row must stop the run")
        } catch {
            thrown = error
        }

        let error = try XCTUnwrap(thrown)
        XCTAssertTrue(
            (error as? ViralReconReportedFailure)?.underlying is OperationRefusedError,
            "a refused begin must throw ViralReconReportedFailure around OperationRefusedError, got \(error)"
        )
        XCTAssertEqual(runner.launchCount, 0, "a refused row must launch no process")
        let refusedRow = try XCTUnwrap(center.items.first { $0.title == "Viral Recon" })
        XCTAssertEqual(refusedRow.state, .failed)
        XCTAssertEqual(refusedRow.errorMessage, "Bundle is busy")
        XCTAssertTrue(refusedRow.logEntries.isEmpty, "a refused run logs nothing on the refused row")

        // The launch-failure reporter adds a row for a failure that reached no
        // row of its own. The refusal already has one, so it adds none.
        XCTAssertNil(AppDelegate.reportViralReconLaunchFailure(error, operationCenter: center, routeContext: nil))
        XCTAssertEqual(center.items.count, 2, "the holder and the refused row, with no second failed row")
    }
}

/// Counts launches and never starts a process.
@MainActor
private final class CountingViralReconProcessRunner: ViralReconWorkflowProcessRunning {
    private(set) var launchCount = 0

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> ViralReconWorkflowProcessResult {
        launchCount += 1
        return ViralReconWorkflowProcessResult(exitCode: 0, standardOutput: "", standardError: "")
    }

    func cancel() {}
}
