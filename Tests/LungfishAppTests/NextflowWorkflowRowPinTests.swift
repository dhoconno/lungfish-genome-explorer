// NextflowWorkflowRowPinTests.swift - Today's Operations row of each Nextflow workflow a user can start
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane U9 (decision N13, rows 1.1 and 2.1 of the UX inventory). Four rows start a
// Nextflow workflow today, and they do not read alike. TaxTriage streams the engine's lines into its
// row. Viral Recon and Local Workflow show nothing between their first detail and their end. pbAA
// starts as a plain FASTQ operation. These cases pin what each row shows, so a lane that moves a
// runner (S16 puts Viral Recon and Local Workflow on `CLIProcessLauncher`) or the words (U10) shows
// every change in a test diff, and so section 5 of docs/contracts/ADDING-A-NEXTFLOW-WORKFLOW.md
// states the rows from facts.
//
// Every case passes at the base. They pin today's behaviour, defects included, and none is a
// target. Viral Recon's row does not move in 2.9, so its cases are the ones S16 reads first. The
// TaxTriage cases here add only what `TaxTriageOperationRowTextReplayTests` does not pin, the title
// and first detail without a run, and the overlay after `Cancelling...` (row T2). No case starts a
// process or needs Docker, so the class runs in the unit tier.

import AppKit
import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class NextflowWorkflowRowPinTests: XCTestCase {
    private var scratch: URL!
    private var windows: [NSWindow] = []
    private var savedFailureReportStore: OperationFailureReportStore?

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "nextflow-row-pins")
        savedFailureReportStore = OperationCenter.shared.failureReportStore
        OperationCenter.shared.failureReportStore = OperationFailureReportStore(
            directory: scratch.appendingPathComponent("failure-reports", isDirectory: true)
        )
    }

    override func tearDown() async throws {
        for window in windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.contentViewController = nil
            window.close()
        }
        windows = []
        if let savedFailureReportStore { OperationCenter.shared.failureReportStore = savedFailureReportStore }
        OperationCenter.shared.clearCompleted()
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    // MARK: - Viral Recon, the row at launch

    /// The row starts as `Viral Recon` with a detail of the platform, the sample count and the
    /// reference, and offers Cancel. Each line the CLI prints reaches the log as it arrives, standard
    /// output as info and standard error as a warning, and never the detail or the bar, which sits at
    /// 0 until the end. The CLI prints no Nextflow line today (it writes them into the run bundle's
    /// logs folder), so the lines here stand in for whatever the CLI prints.
    func testViralReconRowAtLaunchReadsItsTitleAndFirstDetailAndCLILinesOnlyReachTheLog() async throws {
        let runner = PinViralReconRunner()
        runner.streamed = [
            .standardOutput("[aa/000001] Submitted process > FASTQC (SARS2_A)"),
            .standardOutput("process > FASTQC (SARS2_A) [100%] 1 of 1"),
            .standardError("WARN: a streamed warning"),
        ]
        runner.result = ViralReconWorkflowProcessResult(exitCode: 0, standardOutput: "", standardError: "", didStreamOutput: true)
        let run = try makeViralReconRun(runner: runner)
        var running: OperationCenter.Item?
        runner.onRun = { running = run.center.items.first }

        _ = try await run.service.run(run.request, bundleRoot: run.analyses)

        let item = try XCTUnwrap(running, "the runner never saw the row")
        XCTAssertEqual(item.title, "Viral Recon")
        XCTAssertEqual(item.detail, "illumina \u{00B7} 1 sample(s) \u{00B7} MN908947.3")
        XCTAssertEqual(item.operationType, .viralRecon)
        XCTAssertEqual(item.state, .running)
        XCTAssertEqual(item.displayStateLabel, "Running")
        XCTAssertEqual(item.progress, 0, "no progress from Nextflow reaches the bar")
        XCTAssertTrue(item.isCancellable, "the row registers a cancel callback before it launches")
        XCTAssertTrue(OperationRowAction.cancel.isAvailable(for: item))
        XCTAssertEqual(item.cliCommand?.hasPrefix("lungfish-cli workflow run nf-core/viralrecon "), true, "\(item.cliCommand ?? "nil")")
        XCTAssertEqual(
            Array(Self.loggedLines(of: item).suffix(3)),
            [
                "info: [aa/000001] Submitted process > FASTQC (SARS2_A)",
                "info: process > FASTQC (SARS2_A) [100%] 1 of 1",
                "warning: WARN: a streamed warning",
            ]
        )
    }

    // MARK: - Viral Recon, the end of a run

    /// A clean run completes with the output folder and the run bundle in its detail and no
    /// warning, so it reads `Completed`.
    func testACleanViralReconRunCompletesWithTheOutputAndBundlePathsInItsDetail() async throws {
        let runner = PinViralReconRunner()
        runner.result = ViralReconWorkflowProcessResult(exitCode: 0, standardOutput: "line one\nline two", standardError: "")
        let run = try makeViralReconRun(runner: runner)

        let result = try await run.service.run(run.request, bundleRoot: run.analyses)

        let item = try XCTUnwrap(result.operationItem)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.displayStateLabel, "Completed")
        XCTAssertFalse(item.hasWarnings)
        XCTAssertEqual(
            item.detail,
            "Viral Recon completed. Output: \(run.request.outputDirectory.path). Run bundle: \(result.bundleURL.path)"
        )
        XCTAssertEqual(item.bundleURLs, [result.bundleURL])
        XCTAssertEqual(
            Array(Self.loggedLines(of: item).suffix(3)),
            ["info: line one", "info: line two", "info: Viral Recon completed"]
        )
    }

    /// Every stderr line of the CLI is a warning line, so a run that wrote any reads
    /// `Completed with Warnings` while its detail stays the same completed sentence.
    func testEveryStderrLineOfAViralReconRunIsAWarningLineAndMakesTheLabel() async throws {
        let runner = PinViralReconRunner()
        runner.result = ViralReconWorkflowProcessResult(
            exitCode: 0,
            standardOutput: "line one",
            standardError: "WARN: low coverage\nWARN: retried a task"
        )
        let run = try makeViralReconRun(runner: runner)

        let result = try await run.service.run(run.request, bundleRoot: run.analyses)

        let item = try XCTUnwrap(result.operationItem)
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.displayStateLabel, "Completed with Warnings")
        XCTAssertEqual(
            item.detail,
            "Viral Recon completed. Output: \(run.request.outputDirectory.path). Run bundle: \(result.bundleURL.path)"
        )
        XCTAssertEqual(
            Array(Self.loggedLines(of: item).suffix(4)),
            ["info: line one", "warning: WARN: low coverage", "warning: WARN: retried a task", "info: Viral Recon completed"]
        )
    }

    /// A failure shows the exit code and the last 40 lines of stderr as the detail, the same text
    /// with the exit code as the error detail, and no sheet. The thrown error says the row already
    /// reported it, so the launch adds no second failed row.
    func testAFailedViralReconRunShowsTheExitCodeAndTheLast40StderrLinesAndNoSheet() async throws {
        let runner = PinViralReconRunner()
        let stderr = (1...45).map { "stderr line \($0)" }.joined(separator: "\n") + "\nbad params"
        runner.result = ViralReconWorkflowProcessResult(exitCode: 2, standardOutput: "", standardError: stderr)
        let run = try makeViralReconRun(runner: runner)

        var thrown: Error?
        do {
            _ = try await run.service.run(run.request, bundleRoot: run.analyses)
        } catch {
            thrown = error
        }

        let error = try XCTUnwrap(thrown, "a non-zero exit must throw")
        XCTAssertEqual(error.viralReconUnderlyingFailure as? ViralReconWorkflowExecutionError, .nonZeroExit(2))
        XCTAssertTrue(ViralReconWorkflowExecutionService.failureWasReportedOnItsOperationRow(error))
        XCTAssertNil(
            AppDelegate.reportViralReconLaunchFailure(error, operationCenter: run.center, routeContext: nil),
            "a reported failure adds no second row and shows no sheet"
        )
        XCTAssertEqual(run.center.items.count, 1)
        let item = try XCTUnwrap(run.center.items.first)
        let tail = ((7...45).map { "stderr line \($0)" } + ["bad params"]).joined(separator: "\n")
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.displayStateLabel, "Failed")
        XCTAssertEqual(item.detail, "Viral Recon failed with exit code 2. \(tail)")
        XCTAssertEqual(item.errorMessage, "Viral Recon failed")
        XCTAssertEqual(item.errorDetail, "exit code 2\n\n\(tail)")
        // The row logs its own error line, and `fail` then adds three entries, the failure sentence,
        // the detail and the error detail.
        let lines = Self.loggedLines(of: item)
        XCTAssertTrue(lines.contains("error: Viral Recon failed with exit code 2"), "\(lines)")
        XCTAssertEqual(
            Array(lines.suffix(3)),
            [
                "error: Failed: Viral Recon failed",
                "error: Viral Recon failed with exit code 2. \(tail)",
                "error: exit code 2\n\n\(tail)",
            ]
        )
    }

    /// With nothing on stderr the detail is the sentence alone, and the error detail keeps its
    /// blank tail.
    func testAFailedViralReconRunWithNoStderrShowsTheSentenceAlone() async throws {
        let runner = PinViralReconRunner()
        runner.result = ViralReconWorkflowProcessResult(exitCode: 3, standardOutput: "", standardError: "")
        let run = try makeViralReconRun(runner: runner)

        do {
            _ = try await run.service.run(run.request, bundleRoot: run.analyses)
            XCTFail("a non-zero exit must throw")
        } catch {
            XCTAssertEqual(error.viralReconUnderlyingFailure as? ViralReconWorkflowExecutionError, .nonZeroExit(3))
        }

        let item = try XCTUnwrap(run.center.items.first)
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.detail, "Viral Recon failed with exit code 3")
        XCTAssertEqual(item.errorMessage, "Viral Recon failed")
        XCTAssertEqual(item.errorDetail, "exit code 3\n\n")
    }

    /// A cancel reads `Cancelling...` at once, the callback reaches the runner, and the row ends
    /// `Cancelled by user` with no error, no warning and no sheet. The run returns, it does not throw.
    func testACancelledViralReconRunReadsCancellingThenCancelledByUser() async throws {
        let runner = PinViralReconRunner()
        runner.blocksUntilCancelled = true
        // A CLI ended by the tree termination exits non-zero, and the row must still read Cancelled.
        runner.result = ViralReconWorkflowProcessResult(exitCode: 15, standardOutput: "", standardError: "")
        let run = try makeViralReconRun(runner: runner)
        var cancelling: OperationCenter.Item?
        runner.onRun = {
            guard let id = run.center.items.first?.id else { return }
            run.center.cancel(id: id)
            cancelling = run.center.items.first
        }

        let result = try await run.service.run(run.request, bundleRoot: run.analyses)

        let during = try XCTUnwrap(cancelling)
        XCTAssertEqual(during.state, .cancelling)
        XCTAssertEqual(during.displayStateLabel, "Cancelling")
        XCTAssertEqual(during.detail, "Cancelling...")
        XCTAssertFalse(during.isCancellable)
        XCTAssertEqual(runner.cancelCount, 1, "the row's cancel callback reaches the runner once")
        let item = try XCTUnwrap(result.operationItem)
        XCTAssertEqual(item.state, .cancelled)
        XCTAssertEqual(item.displayStateLabel, "Cancelled")
        XCTAssertEqual(item.detail, "Cancelled by user")
        XCTAssertNil(item.errorMessage)
        XCTAssertNil(item.errorDetail)
        XCTAssertFalse(item.hasWarnings)
        XCTAssertFalse(Self.loggedLines(of: item).contains { $0.hasPrefix("error:") }, "\(Self.loggedLines(of: item))")
    }

    // MARK: - Local Workflow

    /// A first run registers a cancel callback, so its row offers Cancel (S16, fact ruling F8, since a
    /// first run registered none before). A cancel reads `Cancelling...`, reaches the runner once, and
    /// the row ends `Cancelled by user` with no error and no warning. The run throws
    /// `CancellationError`, which the window controller ignores, so no sheet opens.
    func testALocalWorkflowFirstRunOffersCancelAndEndsCancelledByUser() async throws {
        let runner = PinLocalWorkflowRunner(exitCode: 125, standardError: "Workflow cancelled\n")
        runner.blocksUntilCancelled = true
        let run = try makeLocalWorkflowRun(runner: runner)
        var running: OperationCenter.Item?
        var cancelling: OperationCenter.Item?
        runner.onRun = {
            running = run.center.items.first
            guard let id = running?.id else { return }
            run.center.cancel(id: id)
            cancelling = run.center.items.first
        }

        do {
            _ = try await run.service.run(run.request, bundleRoot: run.analyses)
            XCTFail("a cancelled run ends by throwing CancellationError")
        } catch is CancellationError {
            // The window controller ignores it, as it does for a replay.
        }

        let item = try XCTUnwrap(running)
        XCTAssertEqual(item.title, "Local Workflow")
        XCTAssertEqual(item.detail, "Running Nextflow workflow")
        XCTAssertEqual(item.operationType, .workflow)
        XCTAssertEqual(item.state, .running)
        XCTAssertEqual(item.displayStateLabel, "Running")
        XCTAssertTrue(item.isCancellable, "a first run registers a cancel callback")
        XCTAssertTrue(OperationRowAction.cancel.isAvailable(for: item), "so its row shows a Cancel button")
        let during = try XCTUnwrap(cancelling)
        XCTAssertEqual(during.state, .cancelling)
        XCTAssertEqual(during.detail, "Cancelling...")
        XCTAssertEqual(runner.cancelCount, 1, "the row's cancel callback reaches the runner once")
        let ended = try XCTUnwrap(run.center.items.first)
        XCTAssertEqual(ended.state, .cancelled)
        XCTAssertEqual(ended.displayStateLabel, "Cancelled")
        XCTAssertEqual(ended.detail, "Cancelled by user")
        XCTAssertNil(ended.errorMessage)
        XCTAssertNil(ended.errorDetail)
        XCTAssertFalse(ended.hasWarnings)
    }

    /// The row's end words. The sentence names the run bundle, stderr lines are warning lines that
    /// are logged after the run, and a clean run reads `Completed`.
    func testALocalWorkflowRunCompletesWithTheRunBundleInItsDetailAndStderrLinesAreWarnings() async throws {
        let clean = PinLocalWorkflowRunner(exitCode: 0, standardOutput: "prepared bundle\nworkflow complete\n")
        let cleanRun = try makeLocalWorkflowRun(runner: clean)
        let cleanResult = try await cleanRun.service.run(cleanRun.request, bundleRoot: cleanRun.analyses)
        let cleanItem = try XCTUnwrap(cleanResult.operationItem)
        XCTAssertEqual(cleanItem.state, .completed)
        XCTAssertEqual(cleanItem.displayStateLabel, "Completed")
        XCTAssertEqual(cleanItem.detail, "Local workflow completed. Run bundle: \(cleanResult.bundleURL.path)")
        XCTAssertEqual(
            Array(Self.loggedLines(of: cleanItem).suffix(3)),
            ["info: prepared bundle", "info: workflow complete", "info: Status: completed"]
        )

        let noisy = PinLocalWorkflowRunner(exitCode: 0, standardError: "WARN: deprecated option\nWARN: second line\n")
        let noisyRun = try makeLocalWorkflowRun(runner: noisy)
        let noisyResult = try await noisyRun.service.run(noisyRun.request, bundleRoot: noisyRun.analyses)
        let noisyItem = try XCTUnwrap(noisyResult.operationItem)
        XCTAssertEqual(noisyItem.state, .completed)
        XCTAssertEqual(noisyItem.displayStateLabel, "Completed with Warnings")
        XCTAssertEqual(noisyItem.detail, "Local workflow completed. Run bundle: \(noisyResult.bundleURL.path)")
        XCTAssertEqual(
            Array(Self.loggedLines(of: noisyItem).suffix(3)),
            ["warning: WARN: deprecated option", "warning: WARN: second line", "info: Status: completed"]
        )
    }

    /// A failure names the exit code in the detail, keeps the whole stderr as the error detail and
    /// logs the stderr lines as warnings before the error line.
    func testAFailedLocalWorkflowRunShowsTheExitCodeAndKeepsTheWholeStderrAsDetail() async throws {
        let stderr = "ERROR ~ Script compilation failed\n  line two of the error"
        let runner = PinLocalWorkflowRunner(exitCode: 3, standardError: stderr)
        let run = try makeLocalWorkflowRun(runner: runner)

        do {
            _ = try await run.service.run(run.request, bundleRoot: run.analyses)
            XCTFail("a non-zero exit must throw")
        } catch {
            XCTAssertEqual(error as? LocalWorkflowExecutionError, .nonZeroExit(3))
        }

        let item = try XCTUnwrap(run.center.items.first)
        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.displayStateLabel, "Failed")
        XCTAssertEqual(item.detail, "Local workflow failed with exit code 3")
        XCTAssertEqual(item.errorMessage, "Local workflow failed")
        XCTAssertEqual(item.errorDetail, stderr)
        // The stderr lines come first, as warnings. The row's own error line follows, then the two
        // lines that `fail` adds, the failure sentence and the error detail as one entry.
        XCTAssertEqual(
            Array(Self.loggedLines(of: item).suffix(5)),
            [
                "warning: ERROR ~ Script compilation failed",
                "warning:   line two of the error",
                "error: Local workflow failed with exit code 3",
                "error: Failed: Local workflow failed",
                "error: \(stderr)",
            ]
        )
    }

    // MARK: - TaxTriage

    /// The title counts samples in the singular or the plural, the first detail is fixed, and a
    /// run of several samples records no command (the gap marker `taxtriage-multi-sample`).
    func testTheTaxTriageRowTitleCountsSamplesAndStartsWithTheFixedFirstDetail() throws {
        let reads = try writeFASTQ("S1.fastq")
        let reporter = RecordingOperationReporter()
        for count in [1, 2] {
            let samples = (1...count).map { TaxTriageSample(sampleId: "S\($0)", fastq1: reads) }
            _ = AppDelegate.beginTaxTriageOperation(
                config: makeTaxTriageConfig(samples),
                routeContext: nil,
                reporter: reporter
            ) { _ in }
        }

        XCTAssertEqual(reporter.items.map(\.title), ["TaxTriage (1 sample)", "TaxTriage (2 samples)"])
        XCTAssertEqual(reporter.items.map(\.initialDetail), ["Starting TaxTriage pipeline\u{2026}", "Starting TaxTriage pipeline\u{2026}"])
        XCTAssertEqual(reporter.items.map(\.operationType), [.classification, .classification])
        XCTAssertEqual(reporter.items.first?.cliCommand?.hasPrefix("lungfish-cli taxtriage --input "), true)
        XCTAssertNil(reporter.items.last?.cliCommand, "several samples record no command")
    }

    /// Row T2 of the UX inventory, as lane U10's second milestone moved it. The app shows an engine
    /// line on the viewer's overlay only once the row has taken it, and the row refuses a line once
    /// it is cancelling. From the cancel on, the overlay shows the row's own `Cancelling...`. So a
    /// line the engine prints through the grace of a cancel reaches the log alone, while the row
    /// and the overlay keep reading `Cancelling...` and the bar stays where it was. The runner here
    /// prints such a line and ends only when the case lets it.
    func testAnEngineLineAfterACancelLeavesTheRowAndTheOverlayReadingCancelling() async throws {
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let reads = try writeFASTQ("S1.fastq")
        let database = scratch.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let before = "Engine line before the cancel"
        let during = "Engine line during the grace"
        let gate = RunnerGate()
        let runner = TaxTriageSerialBatchRunner { _, progress in
            progress?(0.3, before)
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            progress?(0.4, during)
            // The engine's last reading of trace.txt, once the process has exited, reports a bar that
            // moved with the last task line's words (U10 M1 review, note 3).
            progress?(0.5, during)
            await gate.wait()
            throw CancellationError()
        }
        let delegate = makeAppDelegateWithTemporaryState()
        let viewer = OverlayRecordingViewer()
        let window = NSWindow(contentViewController: viewer)
        window.isReleasedWhenClosed = false
        windows.append(window)

        let existing = Set(OperationCenter.shared.items.map(\.id))
        AppDelegate.TaxTriageLaunchSeam.$makeRunner.withValue({ runner }) {
            delegate.runTaxTriage(
                config: makeTaxTriageConfig([TaxTriageSample(sampleId: "S1", fastq1: reads)], database: database),
                viewerController: viewer,
                routeContext: OperationRouteContext(projectURL: project, windowStateScopeID: nil)
            )
        }
        let rowID = try XCTUnwrap(OperationCenter.shared.items.first { !existing.contains($0.id) }?.id, "runTaxTriage started no row")
        defer { gate.release() }

        let reachedFirstLine = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(5)) {
            self.item(rowID)?.detail == before
        }
        XCTAssertTrue(reachedFirstLine, "the row never read the first engine line")
        XCTAssertEqual(viewer.overlayLines.last, before, "a line the row takes reaches the overlay")
        OperationCenter.shared.cancel(id: rowID)
        let loggedLateLine = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(5)) {
            self.item(rowID).map { Self.loggedLines(of: $0).last == "info: \(during)" } ?? false
        }
        XCTAssertTrue(loggedLateLine, "the late engine line never reached the log")
        let overlayReadsCancelling = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(5)) {
            viewer.overlayLines.last == "Cancelling..."
        }
        XCTAssertTrue(overlayReadsCancelling, "the overlay never read the row's Cancelling..., \(viewer.overlayLines)")

        let cancelling = try XCTUnwrap(item(rowID))
        XCTAssertEqual(cancelling.state, .cancelling)
        XCTAssertEqual(cancelling.displayStateLabel, "Cancelling")
        XCTAssertEqual(cancelling.detail, "Cancelling...", "the row refuses the late line")
        // The runner's 0.3 reads 0.27 on the row, which scales the runner's fraction by 0.9 (U38 fix 1).
        XCTAssertEqual(cancelling.progress, 0.27, accuracy: 0.0001, "and the bar stays where it was")
        XCTAssertFalse(viewer.overlayLines.contains(during), "the overlay refuses it too, \(viewer.overlayLines)")
        XCTAssertEqual(Self.loggedLines(of: cancelling).last, "info: \(during)", "and the log keeps it")

        gate.release()
        let finished = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(5)) {
            self.item(rowID).map { !$0.state.isActive } ?? true
        }
        XCTAssertTrue(finished, "the row did not leave Cancelling")
        let cancelled = try XCTUnwrap(item(rowID))
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertEqual(cancelled.detail, "Cancelled by user")
        XCTAssertNil(window.attachedSheet, "a cancel shows no sheet")
        // The main queue ran both late reports before the run's end, so this sees the reading too.
        XCTAssertEqual(viewer.overlayLines.last, "Cancelling...", "the reading after the cancel leaves the overlay, \(viewer.overlayLines)")
        XCTAssertEqual(Self.loggedLines(of: cancelled).filter { $0 == "info: \(during)" }.count, 1, "and logs the line once")
    }

    // MARK: - pbAA

    /// pbAA starts as a plain FASTQ operation row. Its title is the tool's name and its first detail
    /// is the shared `Preparing...`. Nextflow does not appear, and the inventory did not read the
    /// end of this row.
    func testThePbAARowStartsAsAFASTQOperationTitledForTheTool() throws {
        let request = FASTQOperationLaunchRequest.pbaa(request: try PBAAClusteringRunRequest(
            inputFASTQURL: scratch.appendingPathComponent("reads.fastq"),
            guideSourceURL: scratch.appendingPathComponent("guide.fasta"),
            outputDirectory: scratch.appendingPathComponent("Analyses", isDirectory: true),
            outputName: "pbaa run",
            threads: 2
        ))
        XCTAssertEqual(request.operationDisplayTitle, "pbAA Amplicon Clustering")

        let reporter = RecordingOperationReporter()
        _ = MainSplitViewController.beginFASTQLaunchRequestOperation(
            title: request.operationDisplayTitle,
            request: request,
            executionService: FASTQOperationExecutionService(),
            routeContext: nil,
            reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.title, "pbAA Amplicon Clustering")
        XCTAssertEqual(item.initialDetail, "Preparing...")
        XCTAssertEqual(item.operationType, .fastqOperation)
    }

    // MARK: - Fixtures

    private struct ViralReconRun {
        let request: ViralReconRunRequest
        let center: OperationCenter
        let service: ViralReconWorkflowExecutionService
        let analyses: URL
    }

    private struct LocalWorkflowRun {
        let request: LocalWorkflowRunRequest
        let center: OperationCenter
        let service: LocalWorkflowExecutionService
        let analyses: URL
    }

    /// A service on its own center, so a row of this case never meets another case's rows.
    private func makeViralReconRun(runner: PinViralReconRunner) throws -> ViralReconRun {
        let root = scratch.appendingPathComponent("viral-recon-\(UUID().uuidString)", isDirectory: true)
        let request = try ViralReconAppTestFixtures.illuminaRequest(root: root)
        let center = OperationCenter()
        center.failureReportStore = .temporaryForTesting()
        let service = ViralReconWorkflowExecutionService(
            operationCenter: center,
            processRunner: runner,
            referenceDownloader: { _, _ in },
            resultIngest: { _ in }
        )
        return ViralReconRun(
            request: request,
            center: center,
            service: service,
            analyses: root.appendingPathComponent("Analyses", isDirectory: true)
        )
    }

    private func makeLocalWorkflowRun(runner: PinLocalWorkflowRunner) throws -> LocalWorkflowRun {
        let root = scratch.appendingPathComponent("local-workflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workflow = root.appendingPathComponent("main.nf")
        try "nextflow.enable.dsl=2\nworkflow { }\n".write(to: workflow, atomically: true, encoding: .utf8)
        let center = OperationCenter()
        center.failureReportStore = .temporaryForTesting()
        return LocalWorkflowRun(
            request: LocalWorkflowRunRequest(
                workflowURL: workflow,
                outputDirectory: root.appendingPathComponent("results", isDirectory: true),
                params: ["sample": "S1"]
            ),
            center: center,
            service: LocalWorkflowExecutionService(operationCenter: center, processRunner: runner),
            analyses: root.appendingPathComponent("Analyses", isDirectory: true)
        )
    }

    private func makeTaxTriageConfig(_ samples: [TaxTriageSample], database: URL? = nil) -> TaxTriageConfig {
        TaxTriageConfig(
            samples: samples,
            outputDirectory: scratch.appendingPathComponent("replaced-by-the-launch", isDirectory: true),
            kraken2DatabasePath: database,
            maxCpus: 2,
            profile: TaxTriageStandInEngine.profile,
            sourceBundleURLs: nil
        )
    }

    /// A FASTQ of three four-line records whose names never pair, so no input reads as interleaved.
    private func writeFASTQ(_ name: String) throws -> URL {
        let folder = scratch.appendingPathComponent("reads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let stem = url.deletingPathExtension().lastPathComponent
        let text = (1...3).map { "@\(stem)-read-\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func item(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    /// The log as the expanded row shows it, one `level: message` string per entry.
    private static func loggedLines(of item: OperationCenter.Item) -> [String] {
        item.logEntries.filter { !$0.isElisionMarker }.map { "\($0.level.rawValue): \($0.message)" }
    }
}

// MARK: - Stand-ins

/// A Viral Recon CLI that streams the lines it is given, shows the case the row while it runs, and
/// returns a fixed result, or waits for the row's cancel callback first.
@MainActor
private final class PinViralReconRunner: ViralReconWorkflowProcessRunning {
    var streamed: [ViralReconWorkflowProcessOutput] = []
    var result = ViralReconWorkflowProcessResult(exitCode: 0, standardOutput: "", standardError: "")
    var blocksUntilCancelled = false
    var onRun: (@MainActor () -> Void)?
    private(set) var cancelCount = 0
    private var barrier: CheckedContinuation<Void, Never>?

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> ViralReconWorkflowProcessResult {
        for output in streamed { outputHandler?(output) }
        onRun?()
        if blocksUntilCancelled {
            await withCheckedContinuation { barrier = $0 }
        }
        return result
    }

    func cancel() {
        cancelCount += 1
        barrier?.resume()
        barrier = nil
    }
}

/// A `lungfish-cli workflow run` that shows the case the row while it runs and returns a fixed
/// result, or waits for the row's cancel callback first. On exit 0 it writes the completed run bundle
/// the app verifies, as the command does.
@MainActor
private final class PinLocalWorkflowRunner: LocalWorkflowCLIProcessRunning {
    let result: LocalWorkflowCLIProcessResult
    var onRun: (@MainActor () -> Void)?
    var blocksUntilCancelled = false
    private(set) var cancelCount = 0

    init(exitCode: Int32, standardOutput: String = "", standardError: String = "") {
        result = LocalWorkflowCLIProcessResult(exitCode: exitCode, standardOutput: standardOutput, standardError: standardError)
    }

    func runLungfishCLI(
        arguments: [String],
        workingDirectory: URL,
        outputHandler: (@MainActor @Sendable (ViralReconWorkflowProcessOutput) -> Void)?
    ) async throws -> LocalWorkflowCLIProcessResult {
        onRun?()
        if blocksUntilCancelled {
            // Waits for the row's cancel callback, and gives up after 10 s, so a row that registered
            // no callback fails the case instead of hanging the class.
            let deadline = Date().addingTimeInterval(10)
            while cancelCount == 0, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        if result.exitCode == 0 { try Self.writeCompletedBundle(arguments: arguments) }
        return result
    }

    func cancel() { cancelCount += 1 }

    private static func writeCompletedBundle(arguments: [String]) throws {
        guard let bundleIndex = arguments.firstIndex(of: "--bundle-path"),
              let outputIndex = arguments.firstIndex(of: "--results-dir"),
              arguments.count > max(bundleIndex, outputIndex) + 1 else {
            throw NSError(domain: "NextflowWorkflowRowPinTests", code: 1)
        }
        let bundleURL = URL(fileURLWithPath: arguments[bundleIndex + 1]).standardizedFileURL
        let workflowURL = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        let outputURL = URL(fileURLWithPath: arguments[outputIndex + 1]).standardizedFileURL
        let request = LocalWorkflowRunRequest(workflowURL: workflowURL, outputDirectory: outputURL, params: [:])
        try LocalWorkflowRunBundleStore.write(
            request.manifest(executionStatus: .completed, startedAt: Date(), completedAt: Date(), exitCode: 0),
            to: bundleURL
        )
        let step = StepExecution(
            toolName: "lungfish-cli workflow run",
            toolVersion: WorkflowRun.currentAppVersion,
            command: ["lungfish-cli"] + arguments,
            inputs: [],
            outputs: [FileRecord(path: bundleURL.path, format: .unknown, role: .output)],
            exitCode: 0,
            wallTime: 0.01,
            stderr: "",
            endTime: Date()
        )
        let stepEnvelope = ProvenanceStep(stepExecution: step)
        let envelope = ProvenanceEnvelope(
            workflowName: "Run Local Workflow",
            workflowVersion: WorkflowRun.currentAppVersion,
            toolName: step.toolName,
            toolVersion: step.toolVersion,
            tool: ProvenanceToolIdentity(name: step.toolName, version: step.toolVersion, kind: "cli"),
            argv: step.command,
            options: ProvenanceOptions(explicit: [:]),
            runtimeIdentity: ProvenanceRuntimeIdentity(),
            files: stepEnvelope.inputs + stepEnvelope.outputs,
            output: stepEnvelope.outputs.first,
            outputs: stepEnvelope.outputs,
            steps: [stepEnvelope],
            wallTimeSeconds: step.wallTime,
            exitStatus: 0,
            stderr: step.stderr
        )
        try ProvenanceWriter(signingProvider: nil).write(envelope, to: bundleURL)
    }
}

/// Holds a runner until the case releases it. Unlike a sleep, waiting on it survives the
/// cancellation of the task that waits.
private final class RunnerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                waiter.resume()
            } else {
                continuation = waiter
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume()
    }
}
