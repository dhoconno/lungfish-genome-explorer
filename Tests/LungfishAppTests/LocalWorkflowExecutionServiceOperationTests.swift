// LocalWorkflowExecutionServiceOperationTests.swift - begin() sites in LocalWorkflowExecutionService
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The prepare and run launches each lock the run bundle, and a replayed run
// also locks the whole output directory (R4). A held lock must refuse the row
// and launch nothing, and the recorded row must carry its type, its locks and
// its command. `lungfish-cli workflow run` reproduces both launches, so the
// recorded command must parse with the values the request uses. The service
// keeps its injected `OperationCenter`, because it reads the row's state while
// a run is cancelled, so its refusal tests use a real center that holds the
// lock, and the recorded-row tests call the begin helper with a recording
// reporter.

import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class LocalWorkflowExecutionServiceOperationTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/tmp/lane 1a2/Analyses/main.lungfishrun", isDirectory: true)
    private let replaySourceURL = URL(fileURLWithPath: "/tmp/lane 1a2/Analyses/original.lungfishrun", isDirectory: true)

    private func makeRequest(replaying source: URL? = nil) -> LocalWorkflowRunRequest {
        LocalWorkflowRunRequest(
            workflowURL: URL(fileURLWithPath: "/tmp/lane 1a2/flows/main.nf"),
            engine: .nextflow,
            inputURLs: [URL(fileURLWithPath: "/tmp/lane 1a2/reads/S1.fastq")],
            outputDirectory: URL(fileURLWithPath: "/tmp/lane 1a2/results", isDirectory: true),
            expectedOutputURLs: [URL(fileURLWithPath: "/tmp/lane 1a2/results/summary.tsv")],
            params: ["sample": "S1", "mode": "fast"],
            resume: true,
            workDirectory: URL(fileURLWithPath: "/tmp/lane 1a2/work", isDirectory: true),
            cpus: 3,
            memory: "8.GB",
            replaySourceBundleURL: source
        )
    }

    /// A fresh center that already holds `bundle` and the whole `tree`, as when
    /// another operation is running on them.
    private func centerHolding(bundle: URL? = nil, tree: URL? = nil) throws -> OperationCenter {
        let center = OperationCenter()
        center.failureReportStore = .temporaryForTesting()
        _ = try XCTUnwrap(center.begin(
            title: "Existing writer",
            detail: "Running",
            operationType: .workflow,
            targetBundleURL: bundle ?? URL(fileURLWithPath: "/tmp/lane 1a2/Analyses/holder.lungfishrun", isDirectory: true),
            additionalLockedBundleURLs: tree.map { [$0] } ?? [],
            cliCommand: "lungfish-cli workflow run"
        ).startedID)
        return center
    }

    private func assertParses(
        _ commandString: String?,
        request: LocalWorkflowRunRequest,
        prepareOnly: Bool,
        repeatFrom: URL?
    ) throws {
        let command = try RecordedCLICommand.parse(commandString, as: RunSubcommand.self)
        XCTAssertEqual(command.workflow, request.workflowURL.path)
        XCTAssertEqual(command.bundlePath, bundleURL.path)
        XCTAssertEqual(command.resultsDir, request.outputDirectory.path)
        XCTAssertEqual(command.input, request.inputURLs.map(\.path))
        XCTAssertEqual(command.expectedOutput, request.expectedOutputURLs.map(\.path))
        XCTAssertEqual(command.params, ["mode=fast", "sample=S1"])
        XCTAssertTrue(command.resume)
        XCTAssertEqual(command.workDir, request.workDirectory?.path)
        XCTAssertEqual(command.cpus, 3)
        XCTAssertEqual(command.memory, "8.GB")
        XCTAssertEqual(command.repeatFrom, repeatFrom?.path)
        XCTAssertEqual(command.prepareOnly, prepareOnly)
        XCTAssertEqual(
            commandString,
            OperationCenter.buildCLICommand(
                subcommand: "workflow run",
                args: Array(request.cliArguments(bundlePath: bundleURL, prepareOnly: prepareOnly).dropFirst(2))
            ),
            "the row records the same string as before, which buildCLICommand also produces"
        )
    }

    // MARK: - Recorded rows

    func testPrepareRecordsAWorkflowRowLockingTheRunBundleAndARunnableCommand() throws {
        let reporter = RecordingOperationReporter()
        let routeContext = OperationRouteContext(projectURL: nil, windowStateScopeID: UUID())
        let request = makeRequest()

        let result = LocalWorkflowExecutionService.beginLocalWorkflowOperation(
            request: request,
            bundleURL: bundleURL,
            prepareOnly: true,
            routeContext: routeContext,
            reporter: reporter
        )

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(result.startedID, item.id)
        XCTAssertEqual(item.title, "Local Workflow")
        XCTAssertEqual(item.initialDetail, "Preparing \(request.engine.displayName) workflow")
        XCTAssertEqual(item.operationType, .workflow)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertEqual(item.routeContext, routeContext)
        XCTAssertFalse(item.hasCancelCallback)
        try assertParses(item.cliCommand, request: request, prepareOnly: true, repeatFrom: nil)
    }

    func testAFreshRunRecordsTheRunBundleLockAndNoCancelCallback() throws {
        let reporter = RecordingOperationReporter()
        let request = makeRequest()

        let result = LocalWorkflowExecutionService.beginLocalWorkflowOperation(
            request: request,
            bundleURL: bundleURL,
            prepareOnly: false,
            routeContext: nil,
            reporter: reporter
        )

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(result.startedID, item.id)
        XCTAssertEqual(item.initialDetail, "Running \(request.engine.displayName) workflow")
        XCTAssertEqual(item.operationType, .workflow)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [], "only a replay locks the output directory")
        XCTAssertFalse(item.hasCancelCallback)
        try assertParses(item.cliCommand, request: request, prepareOnly: false, repeatFrom: nil)
    }

    func testAReplayedRunAlsoLocksTheOutputTreeAndRegistersItsCancelCallback() throws {
        let reporter = RecordingOperationReporter()
        let request = makeRequest(replaying: replaySourceURL)

        LocalWorkflowExecutionService.beginLocalWorkflowOperation(
            request: request,
            bundleURL: bundleURL,
            prepareOnly: false,
            routeContext: nil,
            reporter: reporter,
            onCancel: {}
        )

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.targetBundleURL, bundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [request.outputDirectory])
        XCTAssertTrue(item.hasCancelCallback)
        try assertParses(item.cliCommand, request: request, prepareOnly: false, repeatFrom: replaySourceURL)
    }

    func testPrepareNeverLocksTheOutputTreeEvenForAReplayRequest() throws {
        let reporter = RecordingOperationReporter()

        LocalWorkflowExecutionService.beginLocalWorkflowOperation(
            request: makeRequest(replaying: replaySourceURL),
            bundleURL: bundleURL,
            prepareOnly: true,
            routeContext: nil,
            reporter: reporter
        )

        XCTAssertEqual(try XCTUnwrap(reporter.items.first).additionalLockedBundleURLs, [])
    }

    // MARK: - Refused rows

    func testPrepareAndRunAreRefusedByAHeldRunBundleLock() throws {
        let center = try centerHolding(bundle: bundleURL)

        for prepareOnly in [true, false] {
            let result = LocalWorkflowExecutionService.beginLocalWorkflowOperation(
                request: makeRequest(),
                bundleURL: bundleURL,
                prepareOnly: prepareOnly,
                routeContext: nil,
                reporter: center
            )
            guard case .refused(let refusal) = result else {
                return XCTFail("a held run bundle lock must refuse the row (prepareOnly: \(prepareOnly))")
            }
            XCTAssertEqual(refusal.blockingOperationTitle, "Existing writer")
        }
    }

    func testAReplayedRunIsRefusedByAHeldOutputTreeLock() throws {
        let request = makeRequest(replaying: replaySourceURL)
        let center = try centerHolding(tree: request.outputDirectory)

        let result = LocalWorkflowExecutionService.beginLocalWorkflowOperation(
            request: request,
            bundleURL: bundleURL,
            prepareOnly: false,
            routeContext: nil,
            reporter: center,
            onCancel: {}
        )

        guard case .refused = result else {
            return XCTFail("a held output tree lock must refuse a replayed run")
        }
    }

    func testPrepareRefusedByAHeldLockThrowsAndReportsNothingOnTheRefusedRow() async throws {
        let temp = try TestTempDirectory.make(prefix: "local-workflow-operation")
        defer { TestTempDirectory.cleanup(temp) }
        let request = try makeRealRequest(in: temp)
        let bundleRoot = temp.appendingPathComponent("Analyses", isDirectory: true)
        let center = try centerHolding(tree: bundleRoot)
        let service = LocalWorkflowExecutionService(
            operationCenter: center,
            processRunner: CountingLocalWorkflowRunner()
        )

        do {
            _ = try await service.prepare(request, bundleRoot: bundleRoot)
            XCTFail("a refused begin must stop the prepare")
        } catch let refused as OperationRefusedError {
            XCTAssertEqual(refused.refusal.blockingOperationTitle, "Existing writer")
        }

        let refusedRow = try XCTUnwrap(center.items.first { $0.title == "Local Workflow" })
        XCTAssertEqual(refusedRow.state, .failed)
        XCTAssertEqual(refusedRow.errorMessage, "Bundle is busy")
        XCTAssertTrue(refusedRow.logEntries.isEmpty, "a refused prepare logs nothing on the refused row")
        XCTAssertEqual(center.items.count, 2)
    }

    func testRunRefusedByAHeldLockKeepsItsRepairMessageAndLaunchesNothing() async throws {
        let temp = try TestTempDirectory.make(prefix: "local-workflow-operation")
        defer { TestTempDirectory.cleanup(temp) }
        let request = try makeRealRequest(in: temp)
        let bundleRoot = temp.appendingPathComponent("Analyses", isDirectory: true)
        let center = try centerHolding(tree: bundleRoot)
        let runner = CountingLocalWorkflowRunner()
        let service = LocalWorkflowExecutionService(operationCenter: center, processRunner: runner)

        do {
            _ = try await service.run(request, bundleRoot: bundleRoot)
            XCTFail("a refused begin must stop the run")
        } catch {
            XCTAssertEqual(
                error as? LocalWorkflowReplayError,
                .repairRequired("The output or run bundle is busy. Wait for its current operation to finish.")
            )
        }

        XCTAssertEqual(runner.launchCount, 0, "a refused row must launch no process")
        let refusedRow = try XCTUnwrap(center.items.first { $0.title == "Local Workflow" })
        XCTAssertEqual(refusedRow.state, .failed)
        XCTAssertTrue(refusedRow.logEntries.isEmpty, "a refused run logs nothing on the refused row")
        XCTAssertEqual(center.items.count, 2)
    }

    // MARK: - Fixtures

    /// A request whose workflow file exists, which `prepare` needs to checksum.
    private func makeRealRequest(in temp: URL) throws -> LocalWorkflowRunRequest {
        let workflowURL = temp.appendingPathComponent("main.nf")
        try "nextflow.enable.dsl=2\nworkflow { }\n".write(to: workflowURL, atomically: true, encoding: .utf8)
        return LocalWorkflowRunRequest(
            workflowURL: workflowURL,
            outputDirectory: temp.appendingPathComponent("results", isDirectory: true),
            params: ["sample": "S1"]
        )
    }
}

/// Counts launches and never starts a process.
@MainActor
private final class CountingLocalWorkflowRunner: LocalWorkflowCLIProcessRunning {
    private(set) var launchCount = 0

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> LocalWorkflowCLIProcessResult {
        launchCount += 1
        return LocalWorkflowCLIProcessResult(exitCode: 0, standardOutput: "", standardError: "")
    }
}
