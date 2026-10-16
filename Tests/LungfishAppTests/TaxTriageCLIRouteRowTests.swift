// TaxTriageCLIRouteRowTests.swift - The TaxTriage row on the CLI route reads as the legacy row does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane U30 M2 (panel decision K1, UX F4, F5, F6, F13 and row 24, RU2). Behind the hidden key's
// `cli` value the Tools menu's TaxTriage launch runs `lungfish-cli taxtriage run --project` through the
// classifier CLI route. Each case launches with `launchTaxTriage(route: .cli)` on `OperationCenter.shared`,
// with a stand-in `lungfish-cli` that plays a transcript of `Tests/Fixtures/cli-events/commands/taxtriage-run/`,
// and pins the words the legacy row's tests pin (`TaxTriageOperationRowTextReplayTests`). The result the
// read-back opens is placed before the launch, and every case checks that the route writes no byte after
// the command exits, so no sidecar and no run history (R1).

import AppKit
import XCTest
@testable import LungfishApp
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class TaxTriageCLIRouteRowTests: XCTestCase {
    private var root: URL!
    private var rowIDs: [UUID] = []
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        try await super.setUp()
        root = try TestTempDirectory.make(prefix: "taxtriage-cli-route-row")
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    override func tearDown() async throws {
        windows.forEach(close)
        rowIDs.forEach { OperationCenter.shared.clearItem(id: $0) }
        TestTempDirectory.cleanup(root)
        try await super.tearDown()
    }

    // MARK: - Completed

    /// UX F4, F13. One clean sample reads `TaxTriage (1 sample)`, completes with the result's summary as
    /// the legacy row does, logs the database line once, opens nothing and writes nothing.
    func testACleanOneSampleRunReadsTodaysRowAndOpensNothing() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root, inputs: ["S1.fastq"])
        let transcript = try CapturedClassifierTranscript.load(command: "taxtriage-run", run: "complete-project", root: root)
        let result = try placeResult(in: try XCTUnwrap(transcript.folder), samples: ["S1"], reports: 1)

        let run = try await launch(config(made.inputs, ids: ["S1"]), project: made.project, lines: transcript.lines)

        XCTAssertEqual(run.row.title, "TaxTriage (1 sample)")
        XCTAssertEqual(run.row.displayStateLabel, "Completed")
        XCTAssertEqual(run.row.detail, result.summary)
        XCTAssertEqual(run.row.progress, 1)
        XCTAssertEqual(messages(of: run.row, at: .info).filter { $0.hasPrefix("Building taxtriage.sqlite") }, ["Building taxtriage.sqlite from TaxTriage outputs"])
        XCTAssertEqual(messages(of: run.row, at: .warning), [])
        XCTAssertNil(run.window.attachedSheet, "a completed run opens no sheet")
        XCTAssertNil(run.viewer.taxonomyViewController, "a completed run opens no result")
        XCTAssertEqual(try ClassifierRouteFixtures.snapshot(of: made.project), run.before, "the route wrote into the project after the command")
    }

    /// 2.8 T8 and D4, check list row 16. Ignored task failures read Completed with Warnings, the paragraph
    /// is one warning line, the command's own, and the detail names the headline and the report count.
    func testIgnoredTasksReadCompletedWithWarningsAndOneWarningLine() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root, inputs: ["S1.fastq"])
        let transcript = try CapturedClassifierTranscript.load(command: "taxtriage-run", run: "complete-with-warning", root: root)
        // The stand-in's errored task, which its run killed (exit 137), as U30 M3 captured the transcript.
        let ignored = TaxTriageIgnoredFailure(
            processPath: "NFCORE_TAXTRIAGE:TAXTRIAGE:MINIMAP2_ALIGN", processName: "MINIMAP2_ALIGN", taskLabel: "MINIMAP2_ALIGN (S1)",
            sampleID: "S1", exitCode: 137
        )
        let result = try placeResult(in: try XCTUnwrap(transcript.folder), samples: ["S1"], reports: 1, ignored: [ignored])
        let paragraph = try XCTUnwrap(result.erroredProcessesMessage)
        XCTAssertTrue(transcript.lines.contains { $0.contains(paragraph) }, "the transcript's warning is the paragraph the command writes")

        let run = try await launch(config(made.inputs, ids: ["S1"]), project: made.project, lines: transcript.lines)

        XCTAssertEqual(run.row.displayStateLabel, "Completed with Warnings")
        XCTAssertEqual(run.row.detail, "\(try XCTUnwrap(result.erroredProcessesHeadline)) (1 report)")
        XCTAssertEqual(messages(of: run.row, at: .warning), [paragraph], "one warning line, and no line repeats the detail")
        XCTAssertFalse(messages(of: run.row, at: .info).contains(paragraph), "no information copy of the paragraph")
        XCTAssertEqual(try ClassifierRouteFixtures.snapshot(of: made.project), run.before)
    }

    /// 2.8 T9. One failed sample of two reads `TaxTriage (2 samples)`, Completed with Warnings, today's
    /// singular detail and today's one warning line. The batch lines name the sample as the command does.
    func testOneFailedSampleOfTwoReadsTodaysWarningAndDetail() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root, inputs: ["S.1.fastq.gz", "blank 1.fastq.gz"])
        let batch = try CapturedClassifierTranscript.load(command: "taxtriage-run", run: "complete-batch", root: root)
        let reason = "TaxTriage pipeline failed with exit code 1: ERROR ~ Error executing process > 'KRAKEN2_KRAKEN2 (blank 1)'"
        let start = try XCTUnwrap(batch.lines.firstIndex { $0.contains("Running blank 1 (2 of 2).") })
        let finalize = try XCTUnwrap(batch.lines.firstIndex { $0.contains("Building TaxTriage database") })
        let lines = Array(batch.lines[...start])
            + [#"{"event":"log","level":"warning","message":"blank 1 failed: \#(reason)","schemaVersion":2}"#]
            + Array(batch.lines[finalize...])
        let folder = try XCTUnwrap(batch.folder)
        let result = try placeResult(in: folder, samples: ["S.1", "blank 1"], reports: 1, failed: [("blank 1", reason)])

        let run = try await launch(config(made.inputs, ids: ["S.1", "blank 1"]), project: made.project, lines: lines)

        XCTAssertEqual(run.row.title, "TaxTriage (2 samples)")
        XCTAssertEqual(run.row.displayStateLabel, "Completed with Warnings")
        XCTAssertEqual(run.row.detail, "1 failed sample (1 report)")
        XCTAssertEqual(messages(of: run.row, at: .warning), ["1 TaxTriage sample failed (blank 1: \(reason))"])
        XCTAssertEqual(messages(of: run.row, at: .error), ["Sample 2/2 (blank 1): \(reason)"])
        XCTAssertTrue(messages(of: run.row, at: .info).contains("Sample 1/2 (S.1): Running KRAKEN2_KRAKEN2 (S.1)"))
        XCTAssertEqual(result.sampleFailures.map(\.sampleID), ["blank 1"])
        XCTAssertEqual(try ClassifierRouteFixtures.snapshot(of: made.project), run.before)
    }

    // MARK: - The bar

    /// UX F6, F13 and check list row 16. The held progress of a batch reaches 0.90 when the last sample's engine
    /// stage ends, 0.95 at `Building TaxTriage database…` and never moves back. The panel draws no bar for it (U30 W4
    /// ruling). The stage's line is shown and logged once, though the command writes it at the start and the end of the stage.
    func testTheBarReachesNinetyThenNinetyFiveAtTheDatabaseAndNeverMovesBack() throws {
        let transcript = try CapturedClassifierTranscript.load(command: "taxtriage-run", run: "complete-batch", root: root)
        var events = CLIClassifierRowEvents(tool: .taxTriage, sampleIDs: ["S.1", "blank 1"])
        var bars: [Double] = []
        var details: [String] = []
        var logs: [String] = []
        let decoder = CLIEventLineDecoder()
        for line in transcript.lines {
            for bridged in events.effects(of: try XCTUnwrap(try decoder.decode(line: line))).bridged {
                switch bridged {
                case let .progress(fraction, message):
                    bars.append(fraction)
                    details.append(message)
                case let .log(_, message):
                    logs.append(message)
                default:
                    break
                }
            }
        }
        XCTAssertEqual(bars, bars.sorted(), "the bar never moves back")
        XCTAssertEqual(Array(bars.suffix(2)), [0.9, 0.95])
        XCTAssertEqual(details.last, "Building TaxTriage database\u{2026}")
        XCTAssertEqual(details.filter { $0 == "Building TaxTriage database\u{2026}" }.count, 1)
        XCTAssertEqual(logs.filter { $0 == "Building taxtriage.sqlite from TaxTriage outputs" }.count, 1)
        XCTAssertTrue(details.contains("Sample 2/2 (blank 1): Running KRAKEN2_KRAKEN2 (blank 1)"), "\(details)")
        XCTAssertEqual(CLIClassifierTool.taxTriage.databaseBuildDetail, TaxTriageAnalysisRunTool.databaseStageMessage)
    }

    // MARK: - Failed

    /// UX F5. A failed sample fails the row with the command's message, keeps Nextflow's standard error as
    /// the row's error detail, and shows `TaxTriage Failed` with the message as its text.
    func testAFailedSampleShowsTodaysAlertAndKeepsTheCommandsDetail() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root, inputs: ["S1.fastq"])
        let transcript = try CapturedClassifierTranscript.load(command: "taxtriage-run", run: "failed", root: root)
        let detail = "ERROR ~ Error executing process > 'NFCORE_TAXTRIAGE:TAXTRIAGE:CLASSIFIER:KRAKEN2_KRAKEN2 (S1)'"
        let message = "TaxTriage pipeline failed with exit code 1: \(detail)"

        let run = try await launch(config(made.inputs, ids: ["S1"]), project: made.project, lines: transcript.lines, exitStatus: 64)
        _ = await waitUntil(timeout: .seconds(5)) { run.window.attachedSheet != nil }

        let row = try XCTUnwrap(item(run.row.id))
        XCTAssertEqual(row.displayStateLabel, "Failed")
        XCTAssertEqual(row.detail, message)
        XCTAssertEqual(row.errorDetail, detail, "the failed line's detail reaches the row")
        XCTAssertEqual(run.window.attachedSheet.map(Self.texts(in:)), "TaxTriage Failed\n\(message)")
        XCTAssertEqual(try ClassifierRouteFixtures.snapshot(of: made.project), run.before)
    }

    /// UX F5 for several samples. Every sample failing fails the row with today's words and the same alert.
    func testEverySampleFailingFailsTheRowWithTodaysWordsAndAlert() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root, inputs: ["S.1.fastq.gz", "blank 1.fastq.gz"])
        let batch = try CapturedClassifierTranscript.load(command: "taxtriage-run", run: "complete-batch", root: root)
        let lines = Array(batch.lines.prefix(3)) + [
            #"{"event":"log","level":"warning","message":"S.1 failed: Nextflow stopped","schemaVersion":2}"#,
            #"{"event":"progress","message":"Running blank 1 (2 of 2).","progress":0.45,"schemaVersion":2}"#,
            #"{"event":"log","level":"warning","message":"blank 1 failed: Nextflow stopped again","schemaVersion":2}"#,
            #"{"error":"None of the 2 runs completed.","event":"failed","schemaVersion":2}"#,
        ]

        let run = try await launch(config(made.inputs, ids: ["S.1", "blank 1"]), project: made.project, lines: lines, exitStatus: 64)
        _ = await waitUntil(timeout: .seconds(5)) { run.window.attachedSheet != nil }

        let row = try XCTUnwrap(item(run.row.id))
        XCTAssertEqual(row.displayStateLabel, "Failed")
        XCTAssertEqual(row.detail, "All TaxTriage samples failed. First failure: Nextflow stopped")
        XCTAssertNil(row.errorDetail, "the alert and the row carry no log tail")
        XCTAssertEqual(run.window.attachedSheet.map(Self.texts(in:)), "TaxTriage Failed\n\(row.detail)")
        XCTAssertEqual(try ClassifierRouteFixtures.snapshot(of: made.project), run.before)
    }

    // MARK: - Cancelled

    /// UX F13, check list rows 15 and 24. While Docker starts, the row reads the command's Docker line. A
    /// cancel reads Cancelling... and then Cancelled by user, with no alert, and the command gets SIGTERM.
    func testACancelWhileDockerStartsReadsCancelledByUserWithNoAlert() async throws {
        let made = try ClassifierRouteFixtures.makeProject(in: root, inputs: ["S1.fastq"])
        let before = try ClassifierRouteFixtures.snapshot(of: made.project)
        let transcript = try CapturedClassifierTranscript.load(command: "taxtriage-run", run: "failed-cancelled", root: root)
        let ready = root.appendingPathComponent("ready")
        let terminated = root.appendingPathComponent("terminated")
        let cli = try ClassifierRouteFixtures.cancellableCLI(
            in: root,
            lines: Array(transcript.lines.dropLast()),
            ready: ready,
            terminated: terminated,
            lastLine: try XCTUnwrap(transcript.lines.last)
        )
        let (viewer, window) = makeViewerInWindow()
        defer { close(window) }

        let row = try XCTUnwrap(start(config(made.inputs, ids: ["S1"]), project: made.project, viewer: viewer, cli: cli))
        let dockerLine = "Docker daemon unavailable. Launching Docker Desktop..."
        let waiting = await waitUntil(timeout: .seconds(30)) {
            FileManager.default.fileExists(atPath: ready.path) && self.item(row.id)?.detail == dockerLine
        }
        XCTAssertTrue(waiting, "the row never read the Docker line: \(String(describing: item(row.id)?.detail))")

        OperationCenter.shared.cancel(id: row.id)
        XCTAssertEqual(item(row.id)?.detail, "Cancelling...")
        let overlayReadsCancelling = await waitUntil(timeout: .seconds(5)) { viewer.overlayLines.last == "Cancelling..." }
        XCTAssertTrue(overlayReadsCancelling, "the overlay never read the row's Cancelling..., \(viewer.overlayLines)")
        let finished = await waitUntil(timeout: .seconds(30)) { self.item(row.id).map { !$0.state.isActive } ?? true }
        XCTAssertTrue(finished)

        let ended = try XCTUnwrap(item(row.id))
        XCTAssertEqual(ended.displayStateLabel, "Cancelled")
        XCTAssertEqual(ended.detail, "Cancelled by user")
        XCTAssertNil(window.attachedSheet, "a cancel shows no alert")
        XCTAssertTrue(FileManager.default.fileExists(atPath: terminated.path), "the command got SIGTERM and the grace to handle it")
        XCTAssertEqual(try ClassifierRouteFixtures.snapshot(of: made.project), before, "a cancel wrote into the project")
    }

    // MARK: - Helpers

    private struct Run {
        let row: OperationCenter.Item
        let viewer: ViewerViewController
        let window: NSWindow
        let before: [String: Data]
    }

    private func config(_ inputs: [URL], ids: [String]) -> TaxTriageConfig {
        TaxTriageConfig(
            samples: zip(inputs, ids).map { TaxTriageSample(sampleId: $1, fastq1: $0) },
            outputDirectory: root.appendingPathComponent("Unused/taxtriage-output", isDirectory: true),
            kraken2DatabasePath: root.appendingPathComponent("Databases/kraken2", isDirectory: true),
            maxCpus: 2,
            profile: "local"
        )
    }

    /// The result the command leaves in `folder`, one sample's or a batch root's aggregate, which the
    /// read-back opens.
    @discardableResult
    private func placeResult(
        in folder: URL,
        samples: [String],
        reports: Int,
        ignored: [TaxTriageIgnoredFailure] = [],
        failed: [(sample: String, reason: String)] = []
    ) throws -> TaxTriageResult {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = TaxTriageResult(
            config: config(samples.map { root.appendingPathComponent("\($0).fastq") }, ids: samples),
            runtime: 12.5,
            exitCode: 0,
            outputDirectory: folder,
            reportFiles: (0..<reports).map { folder.appendingPathComponent("report/S\($0).organisms.report.txt") },
            ignoredFailures: ignored,
            sampleFailures: failed.map {
                TaxTriageSampleFailure(sampleID: $0.sample, outputDirectory: folder.appendingPathComponent($0.sample), errorDescription: $0.reason)
            }
        )
        try result.save()
        return result
    }

    private func item(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    private func messages(of row: OperationCenter.Item, at level: OperationLogLevel) -> [String] {
        row.logEntries.filter { $0.level == level }.map(\.message)
    }

    private func makeViewerInWindow() -> (OverlayRecordingViewer, NSWindow) {
        let viewer = OverlayRecordingViewer()
        let window = NSWindow(contentViewController: viewer)
        window.isReleasedWhenClosed = false
        return (viewer, window)
    }

    private func close(_ window: NSWindow) {
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        window.contentViewController = nil
        window.close()
    }

    /// Launches `config` on the `cli` value and returns the row it began.
    private func start(_ config: TaxTriageConfig, project: URL, viewer: ViewerViewController, cli: URL) -> OperationCenter.Item? {
        let existing = Set(OperationCenter.shared.items.map(\.id))
        makeAppDelegateWithTemporaryState().launchTaxTriage(
            config: config,
            viewerController: viewer,
            routeContext: OperationRouteContext(projectURL: project, windowStateScopeID: nil),
            route: .cli,
            cliURLOverride: cli
        )
        let started = OperationCenter.shared.items.filter { !existing.contains($0.id) }
        rowIDs.append(contentsOf: started.map(\.id))
        return started.first
    }

    /// Launches `config` with a stand-in command that plays `lines`, waits for the row to end and
    /// returns it with the project as it was before the launch.
    private func launch(_ config: TaxTriageConfig, project: URL, lines: [String], exitStatus: Int32 = 0) async throws -> Run {
        let cli = try ClassifierRouteFixtures.standInCLI(in: root, lines: lines, exitStatus: exitStatus)
        let before = try ClassifierRouteFixtures.snapshot(of: project)
        let (viewer, window) = makeViewerInWindow()
        windows.append(window)
        let row = try XCTUnwrap(start(config, project: project, viewer: viewer, cli: cli))
        let finished = await waitUntil(timeout: .seconds(30)) { self.item(row.id).map { !$0.state.isActive } ?? true }
        XCTAssertTrue(finished, "the row did not end")
        return Run(row: try XCTUnwrap(item(row.id)), viewer: viewer, window: window, before: before)
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
