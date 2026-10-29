// ClassifierCLIRouteRowTests.swift - Today's row on every outcome of the classifier CLI route
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane A10, one test per label a run ends on (Completed, Completed with Warnings,
// Failed, Cancelled), as OperationCenterCLIBridgeTests has, and UX's requirement table D1 to
// D18. Each run goes through `AppDelegate.runClassificationThroughCLI` or
// `runEsVirituThroughCLI` on `OperationCenter.shared`, with a stand-in `lungfish-cli` that plays
// lane A9's captured `esviritu detect` run, or what the real executor printed for a shape no
// captured run has (ClassifierCLIRouteFixtures.swift). The stand-in holds its last line until the
// test saw the row track the folder, then settles the folder as the command does. Every test
// checks that the route writes no byte after the command exits.

import AppKit
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishIO
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class ClassifierCLIRouteRowTests: XCTestCase {
    private var root: URL!
    private var hostDefaults: HostDefaultsRestorer?
    private var rowIDs: [UUID] = []
    private var savedBundleReady: (([URL], OperationRouteContext?) -> Void)?
    private var bundleImports: RouteBundleImports!

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "classifier-cli-route")
        // The result views save their column layouts to `UserDefaults.standard` under the result's path.
        hostDefaults = HostDefaultsRestorer(keysContaining: root.lastPathComponent)
        OperationCenter.useTemporaryFailureReportsForTesting()
        let imports = RouteBundleImports()
        bundleImports = imports
        savedBundleReady = OperationCenter.shared.onBundleReadyWithContext
        OperationCenter.shared.onBundleReadyWithContext = { urls, _ in imports.paths.append(urls.map(\.path)) }
    }

    override func tearDown() async throws {
        OperationCenter.shared.onBundleReadyWithContext = savedBundleReady
        rowIDs.forEach { OperationCenter.shared.clearItem(id: $0) }
        hostDefaults?.restore()
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - Completed

    /// D1 to D7, D9, D14 to D17. A clean Kraken2 run reads Completed with today's detail, built
    /// from the result on disk, opens the taxonomy browser, logs every progress line and standard
    /// error at info, and tracks the folder for Results and Reveal Output Files.
    func testACleanKraken2RunReadsCompletedWithTodaysDetailFromDisk() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let configs = [kraken2Config(inputs: made.inputs, sampleFolder: "classification-0000A10A")]
        let run = try await runThroughRoute(
            .kraken2(configs),
            tool: StandInClassifierTool(tool: .kraken2, units: [("reads", .complete)], layout: .singleFolder),
            project: made.project,
            inputs: made.inputs,
            standardError: ["Reading the input bundle."]
        )

        let expected = try ClassifierRouteFixtures.expectedKraken2Detail(in: run.folder)
        XCTAssertEqual(run.item.title, "Profiling reads.fastq")
        XCTAssertEqual(run.firstDetail, "Starting Kraken2 with Viral...")
        XCTAssertEqual(run.item.operationType, .classification)
        XCTAssertEqual(run.item.cliCommand, run.launch.cliCommand)
        XCTAssertEqual(run.item.displayStateLabel, "Completed")
        XCTAssertEqual(run.item.detail, expected.completionDetail)
        XCTAssertNotEqual(run.item.detail, "the command's own detail", "D9 reads the result back from disk")
        XCTAssertNil(run.item.errorMessage)
        XCTAssertNil(run.alertText)
        XCTAssertEqual(eventLines(of: run.item), [
            "info: Materializing reads into the result folder",
            "info: Validating configuration...",
            "info: Running Kraken2...",
            "info: Classification complete",
        ])
        XCTAssertTrue(loggedLines(of: run.item).contains("info: Reading the input bundle."), "D7")
        XCTAssertEqual(run.overlayWhileRunning, "Classification complete", "D14")
        XCTAssertEqual(run.overlayHiddenAtTheEnd, true)
        XCTAssertNotNil(run.viewer.taxonomyViewController, "D15 opens today's taxonomy browser")
        XCTAssertEqual(run.item.bundleURLs.map(\.standardizedFileURL), [run.folder.standardizedFileURL], "D17")
        XCTAssertEqual(run.item.outputURLs, [])
        XCTAssertEqual(bundleImports.paths, [], "the result is no bundle to import")
    }

    /// D8, E4. A degraded Bracken profile reads Completed with Warnings with today's one warning
    /// line, the completion detail. The command's own warning line reads as info.
    func testADegradedKraken2RunReadsCompletedWithWarningsAndOneWarningLine() async throws {
        let reason = "Bracken found no reads at species rank"
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let run = try await runThroughRoute(
            .kraken2([kraken2Config(inputs: made.inputs, sampleFolder: "classification-x")]),
            tool: StandInClassifierTool(tool: .kraken2, units: [("reads", .degrade(reason))], layout: .singleFolder),
            project: made.project,
            inputs: made.inputs
        )

        let expected = try ClassifierRouteFixtures.expectedKraken2Detail(in: run.folder)
        XCTAssertTrue(expected.requiresWarningCompletion)
        XCTAssertEqual(run.item.displayStateLabel, "Completed with Warnings")
        XCTAssertEqual(run.item.detail, expected.completionDetail)
        XCTAssertEqual(loggedLines(of: run.item).filter { $0.hasPrefix("warning:") }, ["warning: \(expected.completionDetail)"])
        XCTAssertTrue(loggedLines(of: run.item).contains("info: \(reason)"))
        XCTAssertNil(run.alertText)
    }

    /// D8, D18. A Kraken2 batch reads today's batch detail, logs today's database line, and a
    /// database that could not be built gives today's two warning lines.
    func testAKraken2BatchWithADatabaseFailureReadsTodaysWarnings() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root, inputs: ["A.fastq", "B.fastq"])
        let configs = [
            kraken2Config(inputs: [made.inputs[0]], sampleFolder: "classification-batch-x/A"),
            kraken2Config(inputs: [made.inputs[1]], sampleFolder: "classification-batch-x/B"),
        ]
        var tool = StandInClassifierTool(tool: .kraken2, units: [("A", .complete), ("B", .complete)], layout: .batchRoot)
        tool.databaseFailure = "disk full"
        let run = try await runThroughRoute(.kraken2(configs), tool: tool, project: made.project, inputs: made.inputs)

        let detail = "2 of 2 samples returned valid Kraken2 classifications; disk full"
        XCTAssertEqual(run.item.title, "Classification Batch (2 samples)")
        XCTAssertEqual(run.firstDetail, "Starting Kraken2/Bracken batch\u{2026}")
        XCTAssertEqual(run.item.displayStateLabel, "Completed with Warnings")
        XCTAssertEqual(run.item.detail, detail)
        XCTAssertEqual(loggedLines(of: run.item).filter { $0.hasPrefix("warning:") }, [
            "warning: The viewer index could not be built (disk full). LGE builds it when the result opens.",
            "warning: \(detail)",
        ])
        XCTAssertTrue(loggedLines(of: run.item).contains("info: Building kraken2.sqlite from 2 sample(s)"))
        XCTAssertTrue(loggedLines(of: run.item).contains("info: Sample 2/2 (B): Running Kraken2..."))
        XCTAssertNotNil(run.viewer.taxonomyViewController, "D15 opens the first sample's taxonomy")
        XCTAssertEqual(run.item.bundleURLs.map(\.standardizedFileURL), [run.folder.standardizedFileURL])
    }

    /// D8, D18 and UX's ruling on decision 1 of Phase 2.10 U34. A Kraken2 `--project` run of one sample reports
    /// `Building Kraken2 database…` now, so a viewer index that cannot be built reads Completed with Warnings with
    /// the one warning line, as a batch's, an EsViritu run's and a TaxTriage run's already do. It read Completed
    /// while the route built no index for one sample. The detail stays the one read back from the folder.
    func testAOneSampleKraken2ProjectRunWhoseIndexFailsReadsCompletedWithWarnings() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        var tool = StandInClassifierTool(tool: .kraken2, units: [("reads", .complete)], layout: .singleFolder)
        tool.indexesTheProjectRun = true
        tool.databaseFailure = "disk full"
        let run = try await runThroughRoute(
            .kraken2([kraken2Config(inputs: made.inputs, sampleFolder: "classification-0000A10A")]),
            tool: tool,
            project: made.project,
            inputs: made.inputs
        )

        let expected = try ClassifierRouteFixtures.expectedKraken2Detail(in: run.folder)
        XCTAssertFalse(expected.requiresWarningCompletion, "the result itself is clean, so only the index warns")
        XCTAssertEqual(run.item.displayStateLabel, "Completed with Warnings")
        XCTAssertEqual(run.item.detail, expected.completionDetail)
        XCTAssertEqual(loggedLines(of: run.item).filter { $0.hasPrefix("warning:") }, [
            "warning: The viewer index could not be built (disk full). LGE builds it when the result opens.",
        ])
        XCTAssertTrue(loggedLines(of: run.item).contains("info: Building kraken2.sqlite from single-sample result"))
        XCTAssertNil(run.alertText)
        XCTAssertEqual(run.item.bundleURLs.map(\.standardizedFileURL), [run.folder.standardizedFileURL])
    }

    /// D8, D11. A sample of an EsViritu batch that failed logs today's error lines and the batch
    /// reads Completed with today's detail, as today's batch does.
    func testAnEsVirituBatchWithAFailedSampleReadsCompletedWithTodaysDetail() async throws {
        let reason = "EsViritu exited with status 1"
        let made = try ClassifierRouteFixtures.makeProject(in: root, inputs: ["A.fastq", "B.fastq"])
        let configs = [
            esVirituConfig(sample: "A", inputs: [made.inputs[0]]),
            esVirituConfig(sample: "B", inputs: [made.inputs[1]]),
        ]
        let run = try await runThroughRoute(
            .esViritu(configs),
            tool: StandInClassifierTool(tool: .esViritu, units: [("A", .fail(reason, logTail: "tail")), ("B", .complete)], layout: .batchRoot),
            project: made.project,
            inputs: made.inputs
        )

        XCTAssertEqual(run.item.title, "EsViritu Batch (2 samples)")
        XCTAssertEqual(run.firstDetail, "Starting EsViritu batch\u{2026}")
        XCTAssertEqual(run.item.displayStateLabel, "Completed")
        XCTAssertEqual(run.item.detail, "1 completed, 1 failed")
        XCTAssertEqual(loggedLines(of: run.item).filter { $0.hasPrefix("warning:") }, [])
        // The command logs a batch sample's log tail as an `error` line under today's heading,
        // since no `failed` line carries it (X1 review fix 2), before the reason line.
        XCTAssertEqual(loggedLines(of: run.item).filter { $0.hasPrefix("error:") }, [
            "error: Sample 1/2 (A): EsViritu log (last lines):\ntail",
            "error: Sample 1/2 (A): \(reason)",
        ])
        XCTAssertTrue(loggedLines(of: run.item).contains("info: Building esviritu.sqlite from 1 sample(s)"))
        XCTAssertNil(run.viewer.taxonomyViewController, "nothing opens after an EsViritu run")
    }

    /// D5 to D9, D14, D17, D23. Lane A9's captured `esviritu detect` run of one sample reads
    /// today's row. The executor's unit line is hidden, every pipeline line is logged at info,
    /// the database line logs today's single-sample line, and the detail is today's detection
    /// detail read back from the sample folder of the batch root, not the command's message.
    func testACapturedSingleEsVirituRunReadsTodaysRowAndDetectionDetail() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let transcript = try CapturedClassifierTranscript.load(command: "esviritu-detect", run: "complete", root: root)
        let folder = try XCTUnwrap(transcript.folder)
        try ClassifierRouteFixtures.placeEsVirituRun(in: folder, samples: ["sarscov2"])
        let configs = Configs.esViritu([esVirituConfig(sample: "sarscov2", inputs: made.inputs)])
        let run = try await play(transcript.lines, exitStatus: 0, folder: folder, completed: true, configs: configs, project: made.project)

        XCTAssertEqual(run.item.title, "EsViritu sarscov2")
        XCTAssertEqual(run.firstDetail, "Starting EsViritu viral detection\u{2026}")
        XCTAssertEqual(run.item.displayStateLabel, "Completed")
        XCTAssertEqual(run.item.detail, try ClassifierRouteFixtures.expectedEsVirituDetail())
        XCTAssertNotEqual(run.item.detail, "1 virus detected in 1 family", "D9 reads the result back from disk")
        let logged = loggedLines(of: run.item)
        XCTAssertEqual(logged.filter { !$0.hasPrefix("info:") }, [], "no warning or error line")
        XCTAssertEqual(logged.first, "info: Validating configuration...")
        XCTAssertFalse(logged.contains("info: Running sarscov2."), "the executor's unit line is not shown")
        XCTAssertTrue(logged.contains("info: Building esviritu.sqlite from single-sample result"))
        XCTAssertTrue(logged.contains("info: Parsed 1 detection rows from EsViritu results"))
        XCTAssertEqual(run.overlayWhileRunning, "Writing the EsViritu summary\u{2026}", "the database line has no overlay")
        XCTAssertEqual(run.overlayHiddenAtTheEnd, true)
        XCTAssertNil(run.viewer.taxonomyViewController, "nothing opens after an EsViritu run")
        XCTAssertEqual(run.item.bundleURLs.map(\.standardizedFileURL), [folder.standardizedFileURL])
    }

    /// D1 to D9, D14 to D17. Lane A8's captured `kraken2 classify --project` run of one sample
    /// reads today's row. The executor's unit line is hidden, every pipeline line and the
    /// index's lines are logged at info, the detail is today's, read back from the folder's
    /// result and not the command's message, and today's taxonomy browser opens.
    func testACapturedSingleKraken2RunReadsTodaysRowAndDetail() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let transcript = try CapturedClassifierTranscript.load(command: "kraken2-classify", run: "complete-project", root: root)
        let folder = try XCTUnwrap(transcript.folder)
        try ClassifierRouteFixtures.placeKraken2Run(in: folder)
        let configs = Configs.kraken2([kraken2Config(inputs: made.inputs, sampleFolder: "classification-0000A10A")])
        let run = try await play(transcript.lines, exitStatus: 0, folder: folder, completed: true, configs: configs, project: made.project)

        XCTAssertEqual(run.item.title, "Profiling reads.fastq")
        XCTAssertEqual(run.firstDetail, "Starting Kraken2 with Viral...")
        XCTAssertEqual(run.item.displayStateLabel, "Completed")
        XCTAssertEqual(run.item.detail, try ClassifierRouteFixtures.expectedKraken2Detail(in: folder).completionDetail)
        XCTAssertNotEqual(run.item.detail, "98 of 100 reads classified", "D9 reads the result back from disk")
        let logged = loggedLines(of: run.item)
        XCTAssertEqual(logged.filter { !$0.hasPrefix("info:") }, [], "no warning or error line")
        XCTAssertEqual(logged.first, "info: Validating configuration...")
        XCTAssertFalse(logged.contains("info: Running test_1.fastq."), "the executor's unit line is not shown")
        XCTAssertTrue(logged.contains("info: Parsed 14 classification rows from Kraken2 results"))
        XCTAssertEqual(run.overlayWhileRunning, "Classification complete", "D14")
        XCTAssertEqual(run.overlayHiddenAtTheEnd, true)
        XCTAssertNotNil(run.viewer.taxonomyViewController, "D15 opens today's taxonomy browser")
        XCTAssertEqual(run.item.bundleURLs.map(\.standardizedFileURL), [folder.standardizedFileURL], "D17")
    }

    /// Review fix 4, a deliberate difference from today. A completed run whose result the app
    /// cannot read back reads Completed with Warnings with the command's own detail and one
    /// warning line, opens no taxonomy browser, and keeps the folder for Results and Reveal
    /// Output Files. Today's route holds the result in memory and has no such case.
    func testAResultThatCannotBeReadBackReadsCompletedWithWarningsAndTheCommandsDetail() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let run = try await runThroughRoute(
            .kraken2([kraken2Config(inputs: made.inputs, sampleFolder: "classification-x")]),
            tool: StandInClassifierTool(tool: .kraken2, units: [("reads", .complete)], layout: .singleFolder),
            project: made.project,
            inputs: made.inputs,
            alteringTheResult: { folder in
                try FileManager.default.removeItem(at: folder.appendingPathComponent("classification-result.json"))
            }
        )

        XCTAssertEqual(run.item.displayStateLabel, "Completed with Warnings")
        XCTAssertEqual(run.item.detail, "the command's own detail")
        let warnings = loggedLines(of: run.item).filter { $0.hasPrefix("warning:") }
        XCTAssertEqual(warnings.count, 1, "\(warnings)")
        XCTAssertTrue(
            warnings.first?.hasPrefix("warning: The result in \(run.folder.lastPathComponent) could not be read back: ") == true,
            "\(warnings)"
        )
        XCTAssertNil(run.viewer.taxonomyViewController, "no result opens")
        XCTAssertNil(run.alertText)
        XCTAssertEqual(run.item.bundleURLs.map(\.standardizedFileURL), [run.folder.standardizedFileURL])
    }

    // MARK: - Failed

    /// D11 to D13, E5. A failed EsViritu run shows today's alert with the command's message, puts
    /// the log tail in the error detail, writes the failure report with the command, and keeps
    /// its folder hidden with the failed record.
    func testAFailedEsVirituRunShowsTodaysAlertAndKeepsItsFolderHidden() async throws {
        let reason = "EsViritu exited with status 1"
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let run = try await runThroughRoute(
            .esViritu([esVirituConfig(sample: "air-A", inputs: made.inputs)]),
            tool: StandInClassifierTool(tool: .esViritu, units: [("air-A", .fail(reason, logTail: "line 1\nline 2"))], layout: .batchRoot),
            project: made.project,
            inputs: made.inputs,
            expectsAlert: true
        )

        XCTAssertEqual(run.item.displayStateLabel, "Failed")
        XCTAssertEqual(run.item.detail, reason)
        XCTAssertEqual(run.item.errorMessage, reason)
        XCTAssertEqual(run.item.errorDetail, "EsViritu log (last lines):\nline 1\nline 2")
        XCTAssertEqual(run.alertText, "EsViritu Failed\n\(reason)")
        XCTAssertTrue(loggedLines(of: run.item).contains("error: \(reason)"))
        XCTAssertEqual(
            loggedLines(of: run.item).filter { $0.contains("EsViritu log (last lines)") }, ["error: EsViritu log (last lines):\nline 1\nline 2"],
            "the tail is logged once, by the row's failure, as today"
        )
        XCTAssertEqual(AnalysisRunRecord.load(from: run.folder)?.outcome, .failed, "E5 keeps the folder hidden as a failed run")
        let report = try XCTUnwrap(run.item.failureReportURL, "D12")
        XCTAssertTrue(try String(contentsOf: report, encoding: .utf8).contains("esviritu detect"), "the report names the command")
        XCTAssertEqual(run.overlayHiddenAtTheEnd, true)
    }

    /// D11 to D13. Lane A9's captured refusal of a missing database, which the command makes
    /// before any folder exists, fails the row with the command's message in today's alert, no
    /// error detail since EsViritu never ran, a failure report that names the command, and no
    /// file written into the project.
    func testACapturedEsVirituRefusalShowsTodaysAlertAndWritesNothing() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let transcript = try CapturedClassifierTranscript.load(command: "esviritu-detect", run: "failed", root: root)
        XCTAssertNil(transcript.folder)
        let cli = try ClassifierRouteFixtures.standInCLI(in: root, lines: transcript.lines, exitStatus: 1)
        let before = try ClassifierRouteFixtures.snapshot(of: made.project)
        let (delegate, viewer, window) = makeDelegateAndViewer()
        defer { close(window) }

        let existing = Set(OperationCenter.shared.items.map(\.id))
        delegate.runEsVirituThroughCLI(
            configs: [esVirituConfig(sample: "sarscov2", inputs: made.inputs)],
            viewerController: viewer,
            routeContext: OperationRouteContext(projectURL: made.project, windowStateScopeID: nil),
            cliURLOverride: cli
        )
        let row = try XCTUnwrap(OperationCenter.shared.items.first { !existing.contains($0.id) })
        rowIDs.append(row.id)
        let finished = await waitUntil(timeout: .seconds(30)) { self.item(row.id).map { !$0.state.isActive } ?? true }
        XCTAssertTrue(finished)
        _ = await waitUntil(timeout: .seconds(5)) { window.attachedSheet != nil }

        let message = "Database directory not found: \(root.path)/missing-db"
        let item = try XCTUnwrap(self.item(row.id))
        XCTAssertEqual(item.displayStateLabel, "Failed")
        XCTAssertEqual(item.detail, message)
        XCTAssertEqual(item.errorMessage, message)
        XCTAssertNil(item.errorDetail, "EsViritu never ran, so there is no log tail")
        XCTAssertEqual(window.attachedSheet.map(Self.texts(in:)), "EsViritu Failed\n\(message)")
        XCTAssertTrue(loggedLines(of: item).contains("error: \(message)"))
        let report = try XCTUnwrap(item.failureReportURL, "D12")
        XCTAssertTrue(try String(contentsOf: report, encoding: .utf8).contains("esviritu detect"), "the report names the command")
        XCTAssertEqual(item.bundleURLs, [])
        XCTAssertEqual(try ClassifierRouteFixtures.snapshot(of: made.project), before, "the refusal left no folder")
    }

    /// UX checklist 1. A Kraken2 batch whose every sample failed reads today's detail and alert,
    /// the first sample's error.
    func testAKraken2BatchWhoseEverySampleFailedShowsTheFirstSamplesError() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root, inputs: ["A.fastq", "B.fastq"])
        let run = try await runThroughRoute(
            .kraken2([
                kraken2Config(inputs: [made.inputs[0]], sampleFolder: "classification-batch-x/A"),
                kraken2Config(inputs: [made.inputs[1]], sampleFolder: "classification-batch-x/B"),
            ]),
            tool: StandInClassifierTool(
                tool: .kraken2,
                units: [("A", .fail("Empty Kraken2 report", logTail: nil)), ("B", .fail("kraken2 exited with status 2", logTail: nil))],
                layout: .batchRoot
            ),
            project: made.project,
            inputs: made.inputs,
            expectsAlert: true
        )

        XCTAssertEqual(run.item.displayStateLabel, "Failed")
        XCTAssertEqual(run.item.detail, "Empty Kraken2 report")
        XCTAssertNil(run.item.errorMessage)
        XCTAssertEqual(run.alertText, "Classification Batch Failed\nEmpty Kraken2 report")
    }

    // MARK: - Cancelled

    /// D10, E5. A cancel stops the command through the transport, which gives it the grace to
    /// record its cancel. The row reads Cancelled with no alert and the folder stays hidden with
    /// the command's cancel record. The stand-in writes that record as the executor's
    /// `settle(.cancelled)` does, until a real `kraken2 classify` or `esviritu detect` cancel
    /// transcript exists.
    func testACancelledRunReadsCancelledWithNoAlert() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let configs = [kraken2Config(inputs: made.inputs, sampleFolder: "classification-x")]
        let launch = try XCTUnwrap(ClassifierCLIRouteLaunch.kraken2(configs: configs, projectURL: made.project))
        let recordCopy = root.appendingPathComponent("run-record.json")
        var tool = StandInClassifierTool(tool: .kraken2, units: [("reads", .complete)], layout: .singleFolder)
        tool.runRecordCopy = recordCopy
        let transcript = await ClassifierRouteFixtures.transcript(of: tool, project: made.project, inputs: made.inputs, arguments: launch.arguments)
        let folder = try XCTUnwrap(transcript.report.analysisDirectory)
        let runRecord = AnalysisRunRecord.url(in: folder)
        try FileManager.default.copyItem(at: recordCopy, to: runRecord)
        let commandsCancel = try ClassifierRouteFixtures.cancelledRecord(
            of: recordCopy,
            in: root.appendingPathComponent("command-cancel", isDirectory: true)
        )
        let ready = root.appendingPathComponent("ready")
        let terminated = root.appendingPathComponent("terminated")
        let head = Array(transcript.lines.prefix { !$0.contains("Validating configuration") })
        let cli = try ClassifierRouteFixtures.cancellableCLI(
            in: root,
            lines: head,
            ready: ready,
            terminated: terminated,
            lastLine: #"{"error":"Kraken2 was cancelled.","event":"failed","schemaVersion":2}"#,
            cancelledRecord: (commandsCancel, runRecord)
        )
        let before = try ClassifierRouteFixtures.snapshot(of: made.project, ignoring: [AnalysisRunRecord.fileName])
        let (delegate, viewer, window) = makeDelegateAndViewer()
        defer { close(window) }

        let existing = Set(OperationCenter.shared.items.map(\.id))
        delegate.runClassificationThroughCLI(
            configs: configs,
            viewerController: viewer,
            routeContext: OperationRouteContext(projectURL: made.project, windowStateScopeID: nil),
            cliURLOverride: cli
        )
        let row = try XCTUnwrap(OperationCenter.shared.items.first { !existing.contains($0.id) })
        rowIDs.append(row.id)
        let running = await waitUntil(timeout: .seconds(30)) {
            FileManager.default.fileExists(atPath: ready.path) && OperationCenter.shared.isTrackingAnalysisOutput(folder)
        }
        XCTAssertTrue(running, "the stand-in command never started or the row never tracked its folder")
        let recordFileWhileRunning = try ClassifierRouteFixtures.fileNumber(of: runRecord)

        OperationCenter.shared.cancel(id: row.id)
        let finished = await waitUntil(timeout: .seconds(30)) { self.item(row.id).map { !$0.state.isActive } ?? true }
        XCTAssertTrue(finished)

        let item = try XCTUnwrap(self.item(row.id))
        XCTAssertEqual(item.displayStateLabel, "Cancelled")
        XCTAssertEqual(item.detail, "Cancelled by user")
        XCTAssertNil(item.errorMessage)
        XCTAssertNil(window.attachedSheet, "a cancel shows no alert")
        XCTAssertTrue(FileManager.default.fileExists(atPath: terminated.path), "the command got SIGTERM and the grace to handle it")
        XCTAssertEqual(AnalysisRunRecord.load(from: folder)?.outcome, .cancelled, "listed as a cancelled run at the next open")
        XCTAssertEqual(try Data(contentsOf: runRecord), try Data(contentsOf: commandsCancel), "the command's cancel record, byte for byte (E5)")
        XCTAssertEqual(
            try ClassifierRouteFixtures.fileNumber(of: runRecord), recordFileWhileRunning,
            "the app rewrote the command's cancel record after the command exited"
        )
        XCTAssertEqual(
            try ClassifierRouteFixtures.snapshot(of: made.project, ignoring: [AnalysisRunRecord.fileName]), before,
            "no other file of the project changed"
        )
        XCTAssertEqual(bundleImports.paths, [])
    }

    // MARK: - The Tools menu

    /// E10. The Tools menu's launch takes the CLI route, the only route since the in-process route
    /// and its hidden keys went in 2.9 (E14), and records the command that ran.
    func testTheToolsMenuLaunchTakesTheCLIRoute() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let configs = [esVirituConfig(sample: "air-A", inputs: made.inputs)]
        let transcript = await ClassifierRouteFixtures.transcript(
            of: StandInClassifierTool(tool: .esViritu, units: [("air-A", .complete)], layout: .batchRoot),
            project: made.project,
            inputs: made.inputs,
            arguments: ["esviritu", "detect"]
        )
        let cli = try ClassifierRouteFixtures.standInCLI(in: root, lines: transcript.lines)
        let savedCLIPath = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
        defer {
            if let savedCLIPath { setenv("LUNGFISH_CLI_PATH", savedCLIPath, 1) } else { unsetenv("LUNGFISH_CLI_PATH") }
        }
        let (delegate, viewer, window) = makeDelegateAndViewer()
        defer { close(window) }

        let existing = Set(OperationCenter.shared.items.map(\.id))
        delegate.launchEsViritu(
            configs: configs,
            viewerController: viewer,
            routeContext: OperationRouteContext(projectURL: made.project, windowStateScopeID: nil)
        )
        let row = try XCTUnwrap(OperationCenter.shared.items.first { !existing.contains($0.id) })
        rowIDs.append(row.id)
        XCTAssertTrue(row.cliCommand?.hasPrefix("lungfish-cli esviritu detect --input ") == true, row.cliCommand ?? "none")
        XCTAssertTrue(row.cliCommand?.hasSuffix(" --format json") == true)
        let finished = await waitUntil(timeout: .seconds(30)) { self.item(row.id).map { !$0.state.isActive } ?? true }
        XCTAssertTrue(finished)
        XCTAssertEqual(item(row.id)?.displayStateLabel, "Completed")
    }

    // MARK: - One run through the route

    private enum Configs {
        case kraken2([ClassificationConfig])
        case esViritu([EsVirituConfig])
    }

    private struct RouteRun {
        let item: OperationCenter.Item
        let firstDetail: String
        let launch: ClassifierCLIRouteLaunch
        let folder: URL
        let alertText: String?
        let viewer: ViewerViewController
        let overlayWhileRunning: String?
        let overlayHiddenAtTheEnd: Bool?
    }

    /// Runs `configs` through the route with a stand-in command that plays what the real
    /// executor printed for `tool`, and checks the parts every outcome shares (``play``).
    /// `alteringTheResult` changes the folder the executor left before the command plays.
    private func runThroughRoute(
        _ configs: Configs,
        tool: StandInClassifierTool,
        project: URL,
        inputs: [URL],
        standardError: [String] = [],
        expectsAlert: Bool = false,
        alteringTheResult: ((URL) throws -> Void)? = nil
    ) async throws -> RouteRun {
        let launch = try Self.launch(of: configs, project: project)
        let recordCopy = root.appendingPathComponent("run-record-\(UUID().uuidString).json")
        var tool = tool
        tool.runRecordCopy = recordCopy
        let transcript = await ClassifierRouteFixtures.transcript(of: tool, project: project, inputs: inputs, arguments: launch.arguments)
        let folder = try XCTUnwrap(transcript.report.analysisDirectory)
        let completed = transcript.report.status == .completed
        if completed {
            // The folder as it is while the command runs. The stand-in settles it at its end.
            try FileManager.default.copyItem(at: recordCopy, to: AnalysisRunRecord.url(in: folder))
        }
        try alteringTheResult?(folder)
        return try await play(
            transcript.lines,
            exitStatus: transcript.report.exitCode,
            folder: folder,
            completed: completed,
            configs: configs,
            project: project,
            standardError: standardError,
            expectsAlert: expectsAlert
        )
    }

    /// Runs `configs` through the route with a stand-in command that plays `lines`, the command
    /// that left `folder` as it is while it runs, and checks the parts every outcome shares. The
    /// row tracks the folder while the command runs, which keeps it hidden (D16, D17), and the
    /// route writes no byte into the project after the command exits. The stand-in settles a
    /// `completed` folder before its last line, as the command does.
    private func play(
        _ lines: [String],
        exitStatus: Int32,
        folder: URL,
        completed: Bool,
        configs: Configs,
        project: URL,
        standardError: [String] = [],
        expectsAlert: Bool = false
    ) async throws -> RouteRun {
        let routeContext = OperationRouteContext(projectURL: project, windowStateScopeID: nil)
        let launch = try Self.launch(of: configs, project: project)
        let recordURL = AnalysisRunRecord.url(in: folder)
        let before = try ClassifierRouteFixtures.snapshot(of: project, ignoring: [AnalysisRunRecord.fileName])
        let recordBefore = completed ? nil : try Data(contentsOf: recordURL)
        let go = root.appendingPathComponent("go-\(UUID().uuidString)")
        let cli = try ClassifierRouteFixtures.standInCLI(
            in: root,
            lines: lines,
            standardError: standardError,
            exitStatus: exitStatus,
            holdingTheLastLineUntil: go,
            settling: completed ? recordURL : nil
        )
        let (delegate, viewer, window) = makeDelegateAndViewer()
        defer { close(window) }

        let existing = Set(OperationCenter.shared.items.map(\.id))
        switch configs {
        case .kraken2(let configs):
            delegate.runClassificationThroughCLI(configs: configs, viewerController: viewer, routeContext: routeContext, cliURLOverride: cli)
        case .esViritu(let configs):
            delegate.runEsVirituThroughCLI(configs: configs, viewerController: viewer, routeContext: routeContext, cliURLOverride: cli)
        }
        let started = try XCTUnwrap(OperationCenter.shared.items.first { !existing.contains($0.id) }, "the route started no row")
        rowIDs.append(started.id)
        let firstDetail = started.detail

        // Every line but the last has reached the row once the overlay shows the last line the
        // route's rules make of them.
        let lastOverlay = try Self.lastOverlay(of: lines.dropLast(), launch: launch)
        let tracking = await waitUntil(timeout: .seconds(30)) {
            OperationCenter.shared.isTrackingAnalysisOutput(folder)
                && (lastOverlay == nil || self.overlay(of: viewer)?.message == lastOverlay)
        }
        XCTAssertTrue(tracking, "the row never tracked the folder the output line named, or the overlay never showed \(lastOverlay ?? "")")
        XCTAssertTrue(AnalysisRunRecord.isIncomplete(folder), "the folder stays hidden while the command runs")
        let overlayWhileRunning = overlay(of: viewer).flatMap { $0.isHidden ? nil : $0.message }
        let recordFileWhileRunning = completed ? nil : try ClassifierRouteFixtures.fileNumber(of: recordURL)
        FileManager.default.createFile(atPath: go.path, contents: nil)

        let finished = await waitUntil(timeout: .seconds(30)) { self.item(started.id).map { !$0.state.isActive } ?? true }
        XCTAssertTrue(finished, "the row did not finish")
        if expectsAlert {
            _ = await waitUntil(timeout: .seconds(5)) { window.attachedSheet != nil }
        }
        let item = try XCTUnwrap(self.item(started.id))

        XCTAssertEqual(
            try ClassifierRouteFixtures.snapshot(of: project, ignoring: [AnalysisRunRecord.fileName]), before,
            "the route wrote into the project after the command exited"
        )
        if completed {
            XCTAssertFalse(AnalysisRunRecord.isIncomplete(folder), "the command settled the completed folder")
        } else {
            XCTAssertEqual(try Data(contentsOf: recordURL), recordBefore, "the failed record keeps its bytes")
            XCTAssertEqual(
                try ClassifierRouteFixtures.fileNumber(of: recordURL), recordFileWhileRunning,
                "the app rewrote the command's failed record after the command exited"
            )
        }
        return RouteRun(
            item: item,
            firstDetail: firstDetail,
            launch: launch,
            folder: folder,
            alertText: window.attachedSheet.map(Self.texts(in:)),
            viewer: viewer,
            overlayWhileRunning: overlayWhileRunning,
            overlayHiddenAtTheEnd: overlay(of: viewer)?.isHidden
        )
    }

    // MARK: - Helpers

    private static func launch(of configs: Configs, project: URL) throws -> ClassifierCLIRouteLaunch {
        switch configs {
        case .kraken2(let configs): return try XCTUnwrap(ClassifierCLIRouteLaunch.kraken2(configs: configs, projectURL: project))
        case .esViritu(let configs): return try XCTUnwrap(ClassifierCLIRouteLaunch.esViritu(configs: configs, projectURL: project))
        }
    }

    private func kraken2Config(inputs: [URL], sampleFolder: String) -> ClassificationConfig {
        ClassificationConfig(
            goal: .profile,
            inputFiles: inputs,
            isPairedEnd: false,
            databaseName: "Viral",
            databasePath: root.appendingPathComponent("Databases/Viral"),
            brackenProfileRequest: .automaticDefault,
            confidence: 0.2,
            minimumHitGroups: 2,
            threads: 1,
            memoryMapping: false,
            quickMode: false,
            outputDirectory: inputs[0].deletingLastPathComponent().appendingPathComponent(sampleFolder),
            extraArguments: []
        )
    }

    private func esVirituConfig(sample: String, inputs: [URL]) -> EsVirituConfig {
        EsVirituConfig(
            inputFiles: inputs,
            isPairedEnd: false,
            sampleName: sample,
            outputDirectory: inputs[0].deletingLastPathComponent().appendingPathComponent("esviritu-x/\(sample)"),
            databasePath: root.appendingPathComponent("Databases/esviritu"),
            qualityFilter: true,
            threads: 1,
            extraArguments: [],
            readFormat: .unpaired,
            inputLayout: nil
        )
    }

    /// An app delegate and a viewer in a window that is never ordered front, whose sheet holds a
    /// failed run's alert.
    private func makeDelegateAndViewer() -> (AppDelegate, ViewerViewController, NSWindow) {
        let delegate = makeAppDelegateWithTemporaryState()
        let viewer = ViewerViewController()
        let window = NSWindow(contentViewController: viewer)
        window.isReleasedWhenClosed = false
        return (delegate, viewer, window)
    }

    private func close(_ window: NSWindow) {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.contentViewController = nil
        window.close()
    }

    private func item(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    /// The last overlay line the route's rules make of `lines`.
    private static func lastOverlay(of lines: ArraySlice<String>, launch: ClassifierCLIRouteLaunch) throws -> String? {
        var rows = CLIClassifierRowEvents(tool: launch.tool, sampleIDs: launch.sampleIDs)
        let decoder = CLIEventLineDecoder()
        return try lines.compactMap { try decoder.decode(line: $0) }.compactMap { rows.effects(of: $0).overlay }.last
    }

    private func overlay(of viewer: ViewerViewController) -> ProgressOverlayView? {
        func find(_ view: NSView) -> ProgressOverlayView? {
            if let overlay = view as? ProgressOverlayView { return overlay }
            for subview in view.subviews {
                if let overlay = find(subview) { return overlay }
            }
            return nil
        }
        return find(viewer.view)
    }

    /// The log as the expanded row shows it, one `level: message` string per entry.
    private func loggedLines(of item: OperationCenter.Item) -> [String] {
        item.logEntries.filter { !$0.isElisionMarker }.map { "\($0.level.rawValue): \($0.message)" }
    }

    /// The logged lines the command's events made, without standard error and the row's own
    /// failure entries.
    private func eventLines(of item: OperationCenter.Item) -> [String] {
        loggedLines(of: item).filter { $0 != "info: Reading the input bundle." }
    }

    /// The text fields of a sheet, top to bottom, one per line.
    private static func texts(in window: NSWindow) -> String {
        var texts: [String] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, !field.stringValue.isEmpty { texts.append(field.stringValue) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return texts.joined(separator: "\n")
    }
}

/// What reached `onBundleReadyWithContext`, one array of paths per call.
@MainActor
private final class RouteBundleImports {
    var paths: [[String]] = []
}
