// TaxTriageOperationRowTextReplayTests.swift - The TaxTriage Operations row, its words and its bar, as the app writes them today
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.8 lane U2, milestone M1 (decisions T8, T9, T10 and D4 of docs/plans/2026-10-11-phase-2-8.md,
// row U1 of the UX inventory). Each case drives `AppDelegate.runTaxTriage` through the runner factory
// of `AppDelegate.TaxTriageLaunchSeam` onto `TaxTriageStandInEngine`, waits for the row to leave its
// active states and pins what it showed. That is the title, the details, the bar values in order, the
// log lines with their levels, the failure alert, the command Copy CLI Command copies and what the
// run wrote into the source bundles.
//
// Every pin states today's behaviour, defects included. The fixes of milestone M3 flip them one at a
// time, and a comment marked "M3" names the fix that changes the line beside it.
//
// The class runs on `OperationCenter.shared`, starts processes and sets LUNGFISH_CLI_PATH for the
// GUI's `build-db` step, so it runs serially. Its name ends in ReplayTests, which sends it to the
// integration tier (`REPLAY_SUITES` in scripts/full-suite-gate.sh).

import AppKit
import Combine
import Foundation
import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

/// What one new row of `OperationCenter.shared` showed while it ran: its bar, its detail and its
/// state, one frame each time any of them changed.
@MainActor
private final class TaxTriageRowTrace {
    struct Frame: Equatable {
        var progress: Double
        var detail: String
        var state: OperationCenter.Item.State
    }

    private(set) var frames: [Frame] = []
    private var subscription: AnyCancellable?

    /// Traces the first row whose id is not in `existing`.
    init(ignoring existing: Set<UUID>) {
        subscription = OperationCenter.shared.$items.sink { [weak self] items in
            MainActor.assumeIsolated {
                self?.record(items, ignoring: existing)
            }
        }
    }

    private func record(_ items: [OperationCenter.Item], ignoring existing: Set<UUID>) {
        guard let item = items.first(where: { !existing.contains($0.id) }) else { return }
        let frame = Frame(progress: item.progress, detail: item.detail, state: item.state)
        if frames.last != frame { frames.append(frame) }
    }

    func stop() {
        subscription?.cancel()
        subscription = nil
    }

    /// The bar values in the order the row showed them, a value that repeats shown once.
    var bars: [Double] {
        frames.map(\.progress).reduce(into: []) { values, value in
            if values.last != value { values.append(value) }
        }
    }

    /// The details in the order the row showed them, a detail that repeats shown once.
    var details: [String] {
        frames.map(\.detail).reduce(into: []) { values, value in
            if values.last != value { values.append(value) }
        }
    }
}

@MainActor
final class TaxTriageOperationRowTextReplayTests: XCTestCase {
    private var scratch: URL!
    private var windows: [NSWindow] = []
    private var savedFailureReportStore: OperationFailureReportStore?

    enum RowTextError: Error {
        case missingCLI
    }

    /// One launch of `runTaxTriage` and the row it made, read after the row left its active states.
    private struct Run {
        let rowID: UUID
        let trace: TaxTriageRowTrace
        let viewer: OverlayRecordingViewer
        let window: NSWindow
    }

    /// What a run left in one source bundle.
    private struct BundleWrites: Equatable {
        /// One `<run folder> <sample> of <batch size>` string per cross-reference sidecar.
        var references: [String]
        /// One `<tool> | <display name> | <status>` string per manifest entry.
        var manifestEntries: [String]
        var hasManifestFile: Bool
    }

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "taxtriage-row-text")
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

    // MARK: - A clean run

    func testACleanOneSampleRunReadsTodaysRowAndCopiesItsCommand() async throws {
        try requireBuiltCLI()
        let engine = try makeEngine()
        let project = try makeProject()
        let reads = try writeFASTQ("S1.fastq", records: 3)
        let database = try makeDatabaseFolder()

        let run = try await launch(
            makeConfig([TaxTriageSample(sampleId: "S1", fastq1: reads)], database: database),
            on: engine,
            in: project
        )
        let item = try XCTUnwrap(self.item(run.rowID))

        // The row.
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.displayStateLabel, "Completed")
        XCTAssertFalse(item.hasWarnings)
        XCTAssertEqual(item.title, "TaxTriage (1 sample)")
        XCTAssertEqual(run.trace.details.first, "Starting TaxTriage pipeline\u{2026}")
        XCTAssertNil(run.window.attachedSheet, "a completed run shows no alert")

        // A clean run's detail is the whole summary of the result, one line per fact.
        XCTAssertEqual(
            Self.maskingRuntime(item.detail),
            [
                "TaxTriage pipeline completed successfully",
                "Runtime: <seconds>s",
                "Samples: 1",
                "Reports: 1",
                "Metrics: 1",
                "Total output files: 10",
            ].joined(separator: "\n")
        )

        // The bar never moves back (T9). The runner reports 1.0 and the database build keeps the
        // bar there. Before the fix the app showed 0.95 while it built the database.
        XCTAssertEqual(Self.rounded(run.trace.bars), [0, 0.05, 0.1, 0.1533, 0.9, 1.0])
        XCTAssertEqual(Self.drops(in: run.trace.bars), [])

        // The details the row showed, from the first to the last. The database line sits between
        // the pipeline's last message and the summary.
        let details = run.trace.details
        XCTAssertEqual(Array(details.suffix(3)), ["TaxTriage pipeline complete", "Building TaxTriage database\u{2026}", item.detail])

        // The log. The database line is an information line, and a clean run logs nothing louder.
        // The overlay of the viewer shows the pipeline's messages and never the database line.
        let lines = Self.loggedLines(of: item)
        XCTAssertEqual(
            Array(lines.suffix(2)),
            ["info: TaxTriage pipeline complete", "info: Building taxtriage.sqlite from TaxTriage outputs"]
        )
        XCTAssertFalse(lines.contains { $0.hasPrefix("warning:") || $0.hasPrefix("error:") }, "\(lines)")
        XCTAssertEqual(run.viewer.overlayLines.last, "TaxTriage pipeline complete")
        XCTAssertFalse(run.viewer.overlayLines.contains("Building TaxTriage database\u{2026}"))

        // Copy CLI Command copies the recorded command. It replays into the folder the GUI wrote.
        let analysis = try analysisFolder(in: project)
        let expectedCommand = [
            "lungfish-cli taxtriage",
            "--input \(reads.path)",
            "--sample S1",
            "--output \(analysis.path)",
            "--db \(database.path)",
            "--platform illumina",
            "--confidence 0.2",
            "--top-hits 10",
            "--rank S",
            "--max-memory 16.GB",
            "--max-cpus 2",
            "--nf-profile local",
            "--revision \(TaxTriageConfig.defaultRevision)",
        ].joined(separator: " ")
        XCTAssertEqual(item.cliCommand, expectedCommand)
        XCTAssertTrue(OperationRowAction.copyCLICommand.isAvailable(for: item))
        let panel = OperationsPanelViewController()
        panel.pasteboard = NSPasteboard(name: NSPasteboard.Name("taxtriage-row-text-\(UUID().uuidString)"))
        defer { panel.pasteboard.releaseGlobally() }
        panel.perform(.copyCLICommand, on: item)
        XCTAssertEqual(panel.pasteboard.string(forType: .string), expectedCommand)

        // The folder the run made.
        for name in ["taxtriage.sqlite", "taxtriage-result.json", BatchRunHistoryLog.filename] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: analysis.appendingPathComponent(name).path),
                "the run left no \(name)"
            )
        }
    }

    // MARK: - Errored tasks

    func testAnErroredTaskCauseLogsOneInformationLineAndTwoWarningLines() async throws {
        try requireBuiltCLI()
        let engine = try makeEngine(.reportsErroredTasks)
        let project = try makeProject()
        let reads = try writeFASTQ("S1.fastq", records: 3)

        let run = try await launch(
            makeConfig([TaxTriageSample(sampleId: "S1", fastq1: reads)], database: try makeDatabaseFolder()),
            on: engine,
            in: project
        )
        let item = try XCTUnwrap(self.item(run.rowID))

        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.displayStateLabel, "Completed with Warnings")
        let headline = "TaxTriage completed with errors: MINIMAP2_ALIGN failed for S1 (killed, usually for running out of memory)"
        // M3 (T8): the headline becomes `Some TaxTriage tasks failed`. The report count follows the
        // singular rule (T9).
        XCTAssertEqual(item.detail, "\(headline) (1 report)")

        // M3 (T9): one warning line per cause and no information line. Today the paragraph is the
        // pipeline's last progress message at info, then a warning, and the detail is a third line
        // because `completeWithWarning` appends it at warning level.
        let paragraph = "\(headline). Results that depend on the failed steps, such as alignments and TASS scores, are missing for the samples named."
            + " Raise Max memory, or list the host in Exclude host taxa (9606 for human) so the host genome is not downloaded as an alignment reference."
        let lines = Self.loggedLines(of: item).filter { $0.contains("MINIMAP2_ALIGN") }
        XCTAssertEqual(lines, ["info: \(paragraph)", "warning: \(paragraph)", "warning: \(item.detail)"])

        // The bar never moves back (T9).
        XCTAssertEqual(Self.drops(in: run.trace.bars), [], "\(run.trace.bars)")
    }

    // MARK: - A failed sample

    func testOneFailedSampleOfTwoReadsSingularWordsAndWritesIntoBothBundles() async throws {
        try requireBuiltCLI()
        let engine = try makeEngine(.failsSamples(["S2"]))
        let project = try makeProject()
        let first = try makeSourceBundle("S1", in: project, records: 3)
        let second = try makeSourceBundle("S2", in: project, records: 4)

        let run = try await launch(
            makeConfig(
                [TaxTriageSample(sampleId: "S1", fastq1: first.reads), TaxTriageSample(sampleId: "S2", fastq1: second.reads)],
                database: try makeDatabaseFolder(),
                bundles: [first.bundle, second.bundle]
            ),
            on: engine,
            in: project
        )
        let item = try XCTUnwrap(self.item(run.rowID))
        let analysis = try analysisFolder(in: project)

        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.displayStateLabel, "Completed with Warnings")
        XCTAssertEqual(item.title, "TaxTriage (2 samples)")
        // One item reads in the singular (T9).
        XCTAssertEqual(item.detail, "1 failed sample (1 report)")
        let lines = Self.loggedLines(of: item)
        // The runner logs the sample's error at info, and the finish repeats it in one warning
        // line. The detail is the second warning line, because `completeWithWarning` appends it.
        let failurePrefix = "info: Sample 2/2 (S2): Failed - "
        let error = try XCTUnwrap(
            lines.first { $0.hasPrefix(failurePrefix) }.map { String($0.dropFirst(failurePrefix.count)) },
            "\(lines)"
        )
        XCTAssertEqual(
            lines.filter { $0.hasPrefix("warning:") },
            ["warning: 1 TaxTriage sample failed (S2: \(error))", "warning: 1 failed sample (1 report)"]
        )

        // Two samples record no command, because no single `taxtriage run` repeats the serial batch.
        XCTAssertNil(item.cliCommand)
        XCTAssertFalse(OperationRowAction.copyCLICommand.isAvailable(for: item))

        // The bar never moves back (T9). The failed sample ends the bar at 1.0 and the database
        // build keeps it there.
        XCTAssertEqual(Self.rounded(run.trace.bars), [0, 0.025, 0.05, 0.0767, 0.45, 0.5, 0.525, 0.55, 1.0])
        XCTAssertEqual(Self.drops(in: run.trace.bars), [])
        XCTAssertTrue(run.trace.details.contains("TaxTriage serial batch complete"))

        // A finished run writes a cross-reference sidecar and a manifest entry into every source
        // bundle, even for the sample that failed, and a line into the folder's batch history.
        let runFolder = analysis.lastPathComponent
        XCTAssertEqual(
            bundleWrites(first.bundle),
            BundleWrites(
                references: ["\(runFolder) S1 of 2"],
                manifestEntries: ["taxtriage | TaxTriage Classification | completed"],
                hasManifestFile: true
            )
        )
        XCTAssertEqual(
            bundleWrites(second.bundle),
            BundleWrites(
                references: ["\(runFolder) S2 of 2"],
                manifestEntries: ["taxtriage | TaxTriage Classification | completed"],
                hasManifestFile: true
            )
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: analysis.appendingPathComponent(BatchRunHistoryLog.filename).path))
    }

    // MARK: - Every sample fails

    func testEverySampleFailingFailsTheRowAndShowsTheAlertWithTheErrorAsItsText() async throws {
        let engine = try makeEngine(.failsSamples(["S1", "S2"]))
        let project = try makeProject()
        let first = try makeSourceBundle("S1", in: project, records: 3)
        let second = try makeSourceBundle("S2", in: project, records: 4)

        let run = try await launch(
            makeConfig(
                [TaxTriageSample(sampleId: "S1", fastq1: first.reads), TaxTriageSample(sampleId: "S2", fastq1: second.reads)],
                database: try makeDatabaseFolder(),
                bundles: [first.bundle, second.bundle]
            ),
            on: engine,
            in: project
        )
        _ = await waitUntil(timeout: .seconds(5)) { run.window.attachedSheet != nil }
        let item = try XCTUnwrap(self.item(run.rowID))

        XCTAssertEqual(item.state, .failed)
        XCTAssertEqual(item.displayStateLabel, "Failed")
        XCTAssertTrue(item.detail.hasPrefix("All TaxTriage samples failed. First failure: "), item.detail)
        XCTAssertNil(item.errorMessage, "the launch fails the row with a detail only")
        XCTAssertNil(item.errorDetail, "the alert and the row carry no log tail")
        let sheet = try XCTUnwrap(run.window.attachedSheet, "a failed run shows an alert")
        XCTAssertEqual(Self.texts(in: sheet), "TaxTriage Failed\n\(item.detail)")

        // No database build, so the bar never reached its drop.
        XCTAssertFalse(run.trace.bars.contains(0.95), "\(run.trace.bars)")
        XCTAssertFalse(run.trace.details.contains("Building TaxTriage database\u{2026}"))

        // A failed run writes nothing into the source bundles.
        for bundle in [first.bundle, second.bundle] {
            XCTAssertEqual(bundleWrites(bundle), BundleWrites(references: [], manifestEntries: [], hasManifestFile: false))
        }
    }

    // MARK: - A cancel while the run finishes

    func testACancelWhileTheDatabaseBuildsReadsCancelledButStillWritesCrossReferencesIntoTheBundles() async throws {
        try requireBuiltCLI()
        let engine = try makeEngine()
        let project = try makeProject()
        let first = try makeSourceBundle("S1", in: project, records: 3)
        let second = try makeSourceBundle("S2", in: project, records: 4)

        let run = try await launch(
            makeConfig(
                [TaxTriageSample(sampleId: "S1", fastq1: first.reads), TaxTriageSample(sampleId: "S2", fastq1: second.reads)],
                database: try makeDatabaseFolder(),
                bundles: [first.bundle, second.bundle]
            ),
            on: engine,
            in: project,
            cancelWhenDetailReads: "Building TaxTriage database\u{2026}"
        )
        let item = try XCTUnwrap(self.item(run.rowID))
        let analysis = try analysisFolder(in: project)

        XCTAssertEqual(item.state, .cancelled)
        XCTAssertEqual(item.displayStateLabel, "Cancelled")
        XCTAssertEqual(item.detail, "Cancelled by user")
        XCTAssertNil(run.window.attachedSheet, "a cancel shows no alert")
        XCTAssertTrue(FileManager.default.fileExists(atPath: analysis.appendingPathComponent("taxtriage-result.json").path))

        // The row on its way to Cancelled. The bar stays where the database build left it, which is
        // 1.0 because the bar never moves back (T9), and the build the cancel stopped logs a warning
        // about the database, the one line of the log that is not information.
        XCTAssertEqual(
            Array(run.trace.details.suffix(3)),
            ["Building TaxTriage database\u{2026}", "Cancelling...", "Cancelled by user"]
        )
        XCTAssertEqual(run.trace.bars.last, 1.0)
        XCTAssertEqual(Self.drops(in: run.trace.bars), [])
        XCTAssertEqual(
            Self.loggedLines(of: item).filter { $0.hasPrefix("warning:") },
            ["warning: Database build failed: Operation cancelled \u{2014} batch will rebuild lazily on open"]
        )

        // M3 (T10): after a cancel nothing more is written into the source bundles. Today the
        // cross-reference sidecars are written before the cancel guard, so both bundles point at the
        // folder while the row reads Cancelled. The manifests and the batch history, which follow the
        // guard, are not written.
        let runFolder = analysis.lastPathComponent
        XCTAssertEqual(
            bundleWrites(first.bundle),
            BundleWrites(references: ["\(runFolder) S1 of 2"], manifestEntries: [], hasManifestFile: false)
        )
        XCTAssertEqual(
            bundleWrites(second.bundle),
            BundleWrites(references: ["\(runFolder) S2 of 2"], manifestEntries: [], hasManifestFile: false)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: analysis.appendingPathComponent(BatchRunHistoryLog.filename).path))
    }

    // MARK: - A failed database build

    func testAFailedDatabaseBuildLogsOneWarningAndTheRowReadsCompletedWithWarnings() async throws {
        let failingCLI = scratch.appendingPathComponent("failing-lungfish-cli")
        try "#!/bin/sh\necho 'no space left' >&2\nexit 3\n".write(to: failingCLI, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failingCLI.path)
        useCLI(at: failingCLI.path)
        let engine = try makeEngine()
        let project = try makeProject()
        let reads = try writeFASTQ("S1.fastq", records: 3)

        let run = try await launch(
            makeConfig([TaxTriageSample(sampleId: "S1", fastq1: reads)], database: try makeDatabaseFolder()),
            on: engine,
            in: project
        )
        let item = try XCTUnwrap(self.item(run.rowID))

        // The result is clean, so the finish completes the row plainly, yet the warning line the
        // database failure logged makes the row read Completed with Warnings (D4).
        XCTAssertEqual(item.state, .completed)
        XCTAssertEqual(item.displayStateLabel, "Completed with Warnings")
        XCTAssertTrue(item.detail.hasPrefix("TaxTriage pipeline completed successfully\n"), item.detail)
        let lines = Self.loggedLines(of: item)
        XCTAssertEqual(
            lines.filter { $0.hasPrefix("warning:") },
            ["warning: Database build failed: lungfish-cli exited with status 3: no space left \u{2014} batch will rebuild lazily on open"]
        )
        XCTAssertEqual(Self.drops(in: run.trace.bars), [], "\(run.trace.bars)")
        let analysis = try analysisFolder(in: project)
        XCTAssertFalse(FileManager.default.fileExists(atPath: analysis.appendingPathComponent("taxtriage.sqlite").path))
    }

    // MARK: - Launch

    /// Starts `runTaxTriage` on the stand-in engine and returns once its row has left the active
    /// states. With `cancelWhenDetailReads`, it cancels the row as soon as the row reads that detail.
    private func launch(
        _ config: TaxTriageConfig,
        on engine: TaxTriageStandInEngine,
        in project: URL,
        cancelWhenDetailReads cancelDetail: String? = nil
    ) async throws -> Run {
        let delegate = makeAppDelegateWithTemporaryState()
        let viewer = OverlayRecordingViewer()
        let window = NSWindow(contentViewController: viewer)
        window.isReleasedWhenClosed = false
        windows.append(window)

        let existing = Set(OperationCenter.shared.items.map(\.id))
        let trace = TaxTriageRowTrace(ignoring: existing)
        AppDelegate.TaxTriageLaunchSeam.$makeRunner.withValue({ engine.makeRunner() }) {
            delegate.runTaxTriage(
                config: config,
                viewerController: viewer,
                routeContext: OperationRouteContext(projectURL: project, windowStateScopeID: nil)
            )
        }
        let rowID = try XCTUnwrap(
            OperationCenter.shared.items.first { !existing.contains($0.id) }?.id,
            "runTaxTriage started no row"
        )
        if let cancelDetail {
            let reached = await waitUntil(timeout: .seconds(120), pollInterval: .milliseconds(2)) {
                self.item(rowID)?.detail == cancelDetail
            }
            XCTAssertTrue(reached, "the row never read \(cancelDetail)")
            OperationCenter.shared.cancel(id: rowID)
        }
        let finished = await waitUntil(timeout: .seconds(120), pollInterval: .milliseconds(50)) {
            self.item(rowID).map { !$0.state.isActive } ?? true
        }
        XCTAssertTrue(finished, "the TaxTriage row did not finish in 120 seconds")
        trace.stop()
        return Run(rowID: rowID, trace: trace, viewer: viewer, window: window)
    }

    private func item(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    // MARK: - Fixtures

    /// The engine for one case, stopped in teardown so no stand-in outlives the case.
    private func makeEngine(
        _ behaviour: TaxTriageStandInEngine.Behaviour = .completes
    ) throws -> TaxTriageStandInEngine {
        let engine = try TaxTriageStandInEngine(
            root: scratch.appendingPathComponent("engine", isDirectory: true),
            behaviour: behaviour
        )
        addTeardownBlock { await engine.stopLeftoverProcesses() }
        return engine
    }

    /// Points `LUNGFISH_CLI_PATH` at the built CLI, which the GUI's `build-db` step runs.
    private func requireBuiltCLI() throws {
        let productsDirectory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        guard let cli = CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: productsDirectory) else {
            XCTFail(
                "No lungfish-cli beside \(productsDirectory.path) and none named by LUNGFISH_CLI_PATH. "
                    + "Without it the GUI path builds no taxtriage.sqlite."
            )
            throw RowTextError.missingCLI
        }
        useCLI(at: cli.path)
    }

    private func useCLI(at path: String) {
        let saved = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", path, 1)
        addTeardownBlock {
            if let saved {
                setenv("LUNGFISH_CLI_PATH", saved, 1)
            } else {
                unsetenv("LUNGFISH_CLI_PATH")
            }
        }
    }

    private func makeProject() throws -> URL {
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        return project
    }

    /// A Kraken2 database folder. The stand-in never reads it, but the pipeline checks it exists.
    private func makeDatabaseFolder() throws -> URL {
        let folder = scratch.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeConfig(_ samples: [TaxTriageSample], database: URL, bundles: [URL]? = nil) -> TaxTriageConfig {
        TaxTriageConfig(
            samples: samples,
            outputDirectory: scratch.appendingPathComponent("replaced-by-the-launch", isDirectory: true),
            kraken2DatabasePath: database,
            maxCpus: 2,
            profile: TaxTriageStandInEngine.profile,
            sourceBundleURLs: bundles
        )
    }

    /// A FASTQ of `records` four-line records whose names never pair, so no input reads as
    /// interleaved.
    private func writeFASTQ(_ name: String, records: Int, in folder: URL? = nil) throws -> URL {
        let folder = folder ?? scratch.appendingPathComponent("reads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let stem = url.deletingPathExtension().lastPathComponent
        let text = (1...records).map { "@\(stem)-read-\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A `<name>.lungfishfastq` folder in the project holding the sample's reads.
    private func makeSourceBundle(_ name: String, in project: URL, records: Int) throws -> (bundle: URL, reads: URL) {
        let bundle = project.appendingPathComponent("\(name).lungfishfastq", isDirectory: true)
        let reads = try writeFASTQ("\(name).fastq", records: records, in: bundle)
        return (bundle, reads)
    }

    // MARK: - Reading the row and the disk

    /// The one analysis folder the launch made in the project, spelled from the project's path.
    private func analysisFolder(in project: URL) throws -> URL {
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        let children = (try? FileManager.default.contentsOfDirectory(
            at: analyses,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let folders = children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        XCTAssertEqual(folders.count, 1, "the launch must make one analysis folder")
        let name = try XCTUnwrap(folders.first?.lastPathComponent)
        return analyses.appendingPathComponent(name, isDirectory: true)
    }

    private func bundleWrites(_ bundle: URL) -> BundleWrites {
        let references = MetagenomicsBatchResultStore.loadTaxTriageRefs(from: bundle)
            .map { "\($0.runId) \($0.sampleId) of \($0.batchSampleCount)" }
            .sorted()
        let hasManifest = FileManager.default.fileExists(
            atPath: bundle.appendingPathComponent(AnalysisManifest.filename).path
        )
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        let entries = AnalysisManifestStore.load(bundleURL: bundle, projectURL: project).analyses
            .map { "\($0.tool) | \($0.displayName) | \($0.status)" }
        return BundleWrites(references: references, manifestEntries: entries, hasManifestFile: hasManifest)
    }

    /// The log as the expanded row shows it, one `level: message` string per entry.
    private static func loggedLines(of item: OperationCenter.Item) -> [String] {
        item.logEntries.filter { !$0.isElisionMarker }.map { "\($0.level.rawValue): \($0.message)" }
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

    /// Each place the bar moved back, written `from to to`.
    private static func drops(in bars: [Double]) -> [String] {
        zip(bars, bars.dropFirst()).filter { $1 < $0 }.map { "\($0) to \($1)" }
    }

    /// The bar values to four decimals, so a sum of fractions compares as written.
    private static func rounded(_ bars: [Double]) -> [Double] {
        bars.map { ($0 * 10_000).rounded() / 10_000 }
    }

    private static func maskingRuntime(_ detail: String) -> String {
        detail.replacingOccurrences(of: #"Runtime: [0-9.]+s"#, with: "Runtime: <seconds>s", options: .regularExpression)
    }
}
