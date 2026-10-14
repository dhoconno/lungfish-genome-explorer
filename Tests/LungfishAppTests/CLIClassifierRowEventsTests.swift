// CLIClassifierRowEventsTests.swift - The row lines the CLI route makes of the executor's stream
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane A10, UX differences D5 to D8, D11, D14 and D17. Each test plays a stream through
// `CLIClassifierRowEvents`, the rules the CLI route's runner applies: lane A9's captured
// `esviritu detect` runs, or for a shape no captured run has, the stream the real analysis run
// executor prints for `--format json` when it runs a stand-in tool in process.

import XCTest
@testable import LungfishApp
import LungfishIO
import LungfishKit
import LungfishTestSupport
@testable import LungfishWorkflow

final class CLIClassifierRowEventsTests: XCTestCase {
    // MARK: - Single runs

    /// D5, D6, D14, D17. Every progress line of a single run moves the bar, is logged at info and
    /// shows in the viewer. The executor's start and unit lines are not shown, and the early
    /// output line names the folder the row tracks.
    func testASingleRunShowsEveryProgressLineAndTracksItsFolder() async throws {
        let run = try await executorRun(StandInClassifierTool(tool: .kraken2, units: [("reads", .complete)], layout: .singleFolder))
        let (rows, effects) = play(run.events, tool: .kraken2, sampleIDs: ["reads"])
        XCTAssertEqual(run.report.status, .completed, run.report.message)

        XCTAssertEqual(logLines(effects), [
            "info: Materializing reads into the result folder",
            "info: Validating configuration...",
            "info: Running Kraken2...",
            "info: Classification complete",
        ])
        XCTAssertEqual(progressLines(effects), [
            "0.0 Materializing reads into the result folder",
            "0.0 Validating configuration...",
            "0.5 Running Kraken2...",
            "1.0 Classification complete",
        ])
        XCTAssertEqual(
            effects.compactMap(\.overlay),
            ["Materializing reads into the result folder", "Validating configuration...", "Running Kraken2...", "Classification complete"],
            "A10 review fix 5, the materialization line reaches the detail and the overlay"
        )
        let folder = try XCTUnwrap(run.report.analysisDirectory)
        XCTAssertEqual(effects.compactMap(\.trackedFolder).map(\.standardizedFileURL), [folder.standardizedFileURL])
        XCTAssertEqual(rows.analysisFolder?.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertTrue(effects[0].bridged.isEmpty, "the begin text stays the first detail")
    }

    /// D5 to D7, D14, D17. Lane A9's captured `esviritu detect` runs of one sample, plain and with
    /// `--batch`, read as today's single row. The executor's unit line is hidden, every pipeline
    /// line is logged at info with no sample, the bar never moves back, the database line logs
    /// today's single-sample line and shows no overlay, and the early output line names the
    /// folder the row tracks. The captured refusal shows nothing, since the runner reads the
    /// failure from the transport.
    func testCapturedEsVirituRunsReadAsTodaysSingleRow() throws {
        let root = URL(fileURLWithPath: "/tmp/lane a10c", isDirectory: true)
        let decoder = CLIEventLineDecoder()
        for (run, sample) in [("complete", "sarscov2"), ("complete-batch", "test")] {
            let transcript = try CapturedClassifierTranscript.load(command: "esviritu-detect", run: run, root: root)
            let (rows, effects) = play(try transcript.lines.compactMap { try decoder.decode(line: $0) }, tool: .esViritu, sampleIDs: [sample])

            let logged = logLines(effects)
            XCTAssertEqual(logged.first, "info: Validating configuration...", run)
            XCTAssertFalse(logged.contains("info: Running \(sample)."), "\(run): the executor's unit line is not shown")
            XCTAssertEqual(logged.filter { !$0.hasPrefix("info:") }, [], "\(run): no warning or error line")
            XCTAssertFalse(logged.contains { $0.contains("Sample 1/1") }, "\(run): a single row's lines carry no sample")
            XCTAssertEqual(
                logged.filter { $0.hasPrefix("info: Building esviritu.sqlite") },
                ["info: Building esviritu.sqlite from single-sample result"],
                run
            )
            let fractions = effects.flatMap(\.bridged).compactMap { event -> Double? in
                guard case let .progress(fraction, _) = event else { return nil }
                return fraction
            }
            XCTAssertEqual(fractions, fractions.sorted(), "\(run): the bar never moves back")
            XCTAssertEqual(fractions.last, 1, run)
            XCTAssertFalse(effects.compactMap(\.overlay).contains("Building EsViritu database\u{2026}"), run)
            XCTAssertEqual(effects.compactMap(\.trackedFolder), [try XCTUnwrap(transcript.folder)], run)
            XCTAssertEqual(rows.failedUnitReasons, [], run)
        }

        let refusal = try CapturedClassifierTranscript.load(command: "esviritu-detect", run: "failed", root: root)
        let (rows, effects) = play(try refusal.lines.compactMap { try decoder.decode(line: $0) }, tool: .esViritu, sampleIDs: ["sarscov2"])
        XCTAssertEqual(effects, [CLIClassifierRowEvents.Effects(), CLIClassifierRowEvents.Effects()])
        XCTAssertNil(rows.analysisFolder)
    }

    /// D11, A8d review section 4. A failed single EsViritu run ends in `failed` with the log tail
    /// as the line's detail and logs no tail. The alert shows the `failed` message, and the error
    /// detail is today's heading and the detail. A Kraken2 run and every batch keep no error
    /// detail and an alert equal to the message, even when a detail arrives.
    func testTheFailedLinesDetailGoesOnlyToASingleEsVirituRowsErrorDetail() async throws {
        let reason = "EsViritu exited with status 1"
        let run = try await executorRun(StandInClassifierTool(
            tool: .esViritu,
            units: [("air-A", .fail(reason, logTail: "line 1\nline 2"))],
            layout: .batchRoot
        ))
        let (rows, effects) = play(run.events, tool: .esViritu, sampleIDs: ["air-A"])

        XCTAssertEqual(run.report.message, reason, "a single sample's failure is the run's message")
        XCTAssertEqual(run.events.last, .failed(message: reason, detail: "line 1\nline 2"), "the command sends the tail alone")
        XCTAssertFalse(logLines(effects).contains { $0.contains("line 1") }, "the tail is no log line, as today")
        let failedLine = CLISubprocessTransport.RunError.failedEvent(message: reason, detail: "line 1\nline 2")
        XCTAssertEqual(
            CLIClassifierRunner.failure(
                for: failedLine,
                request: CLIClassifierRunRequest(tool: .esViritu, arguments: [], sampleIDs: ["air-A"]),
                events: rows
            ),
            CLIClassifierFailure(message: reason, errorMessage: reason, errorDetail: "EsViritu log (last lines):\nline 1\nline 2")
        )
        for (tool, sampleIDs) in [(CLIClassifierTool.kraken2, ["A"]), (.kraken2, ["A", "B"]), (.esViritu, ["A", "B"])] {
            let failure = CLIClassifierRunner.failure(
                for: failedLine,
                request: CLIClassifierRunRequest(tool: tool, arguments: [], sampleIDs: sampleIDs),
                events: CLIClassifierRowEvents(tool: tool, sampleIDs: sampleIDs)
            )
            XCTAssertEqual(failure.message, reason, "\(tool) \(sampleIDs): the alert is the message")
            XCTAssertNil(failure.errorDetail, "\(tool) \(sampleIDs): no error detail, as today")
        }
    }

    /// D5 to D7, D14, D17. Lane A8's captured `kraken2 classify` runs of one sample, plain, into a
    /// project, with a profile and with a degraded profile, read as today's single row. The
    /// executor's unit line is hidden, every pipeline line is logged at info with no sample, the
    /// degraded profile's warning reads as info since the row's label comes from the result read
    /// back, the bar never moves back, and the early output line names the folder the row tracks.
    /// The captured cancel shows its lines up to the cancel, and the captured refusal shows
    /// nothing, since the runner reads the end of a run from the transport.
    func testCapturedKraken2RunsReadAsTodaysSingleRow() throws {
        let root = URL(fileURLWithPath: "/tmp/lane x1", isDirectory: true)
        let decoder = CLIEventLineDecoder()
        for run in ["complete", "complete-project", "complete-profile", "complete-with-warning", "failed-cancelled"] {
            let transcript = try CapturedClassifierTranscript.load(command: "kraken2-classify", run: run, root: root)
            let events = try transcript.lines.compactMap { try decoder.decode(line: $0) }
            let (rows, effects) = play(events, tool: .kraken2, sampleIDs: ["reads"])

            let logged = logLines(effects)
            let unitLine = try XCTUnwrap(events.lazy.compactMap { event -> String? in
                guard case let .progress(_, message) = event else { return nil }
                return message
            }.first, run)
            XCTAssertTrue(unitLine.hasPrefix("Running "), "\(run): \(unitLine)")
            XCTAssertFalse(logged.contains("info: \(unitLine)"), "\(run): the executor's unit line is not shown")
            XCTAssertEqual(logged.first, "info: Validating configuration...", run)
            XCTAssertEqual(logged.filter { !$0.hasPrefix("info:") }, [], "\(run): no warning or error line")
            XCTAssertFalse(logged.contains { $0.contains("Sample 1/1") }, "\(run): a single row's lines carry no sample")
            let fractions = effects.flatMap(\.bridged).compactMap { event -> Double? in
                guard case let .progress(fraction, _) = event else { return nil }
                return fraction
            }
            XCTAssertEqual(fractions, fractions.sorted(), "\(run): the bar never moves back")
            XCTAssertEqual(effects.compactMap(\.trackedFolder), [try XCTUnwrap(transcript.folder)], run)
            XCTAssertEqual(rows.failedUnitReasons, [], run)
            // Phase 2.10 U34, W4. A `--project` run of one sample says it builds the viewer index, so the row logs
            // the line a batch logs, and a plain run builds none.
            let buildsTheIndex = ["complete-project", "complete-profile", "complete-with-warning"].contains(run)
            XCTAssertEqual(logged.contains("info: Building kraken2.sqlite from single-sample result"), buildsTheIndex, run)
            if run == "complete-with-warning" {
                XCTAssertTrue(logged.contains { $0.hasPrefix("info: Kraken classification completed, but Bracken profiling did not complete") })
            }
        }

        let refusal = try CapturedClassifierTranscript.load(command: "kraken2-classify", run: "failed", root: root)
        let (rows, effects) = play(try refusal.lines.compactMap { try decoder.decode(line: $0) }, tool: .kraken2, sampleIDs: ["reads"])
        XCTAssertEqual(effects, [CLIClassifierRowEvents.Effects(), CLIClassifierRowEvents.Effects()])
        XCTAssertNil(rows.analysisFolder)
    }

    // MARK: - Batches

    /// D5, D6. A batch line reads `Sample i/N (id): <line>` with today's sample ids, the bar is
    /// `(index + fraction) / count`, and the finalize's lines carry no sample. The database line
    /// shows today's detail and logs today's `Building esviritu.sqlite from N sample(s)`.
    func testABatchPrefixesEachSampleLineAndEndsInTodaysDatabaseLine() async throws {
        let run = try await executorRun(StandInClassifierTool(
            tool: .esViritu,
            units: [("A", .complete), ("B", .complete)],
            layout: .batchRoot
        ))
        let (_, effects) = play(run.events, tool: .esViritu, sampleIDs: ["A", "B"])
        XCTAssertEqual(run.report.status, .completed, run.report.message)

        XCTAssertEqual(logLines(effects), [
            "info: Sample 1/2 (A): Materializing A into the result folder",
            "info: Sample 1/2 (A): Validating configuration...",
            "info: Sample 1/2 (A): Running EsViritu...",
            "info: Sample 1/2 (A): Detection complete",
            "info: Sample 2/2 (B): Materializing B into the result folder",
            "info: Sample 2/2 (B): Validating configuration...",
            "info: Sample 2/2 (B): Running EsViritu...",
            "info: Sample 2/2 (B): Detection complete",
            "info: Writing the EsViritu batch summary\u{2026}",
            "info: Building esviritu.sqlite from 2 sample(s)",
            "info: Built database with 2 rows",
        ])
        XCTAssertEqual(progressLines(effects), [
            "0.0 Sample 1/2 (A): Materializing A into the result folder",
            "0.0 Sample 1/2 (A): Validating configuration...",
            "0.25 Sample 1/2 (A): Running EsViritu...",
            "0.5 Sample 1/2 (A): Detection complete",
            "0.5 Sample 2/2 (B): Materializing B into the result folder",
            "0.5 Sample 2/2 (B): Validating configuration...",
            "0.75 Sample 2/2 (B): Running EsViritu...",
            "1.0 Sample 2/2 (B): Detection complete",
            "1.0 Writing the EsViritu batch summary\u{2026}",
            "1.0 Building EsViritu database\u{2026}",
        ])
        XCTAssertFalse(effects.compactMap(\.overlay).contains("Building EsViritu database\u{2026}"), "today's database line has no overlay")
    }

    /// D5, D14, D17, A10 review fix 1 and X1 review fix 1. Lane A8's captured `kraken2 classify
    /// --batch` run of two samples given out of sorted order, `test_1.fastq.gz` and then
    /// `negative-control.fastq`, read as today's batch row. The dialog lists the samples as the
    /// inputs were given and the command runs them in its own order, so each unit's lines name the
    /// sample of the unit's own label. The finalize's line sets today's detail `Building Kraken2
    /// database…` with no overlay, the log holds today's `Building kraken2.sqlite from N
    /// sample(s)` with N the completed count of the `complete` line, and the bar never moves back.
    func testACapturedKraken2BatchReadsTodaysPrefixesAndDatabaseLine() throws {
        let root = URL(fileURLWithPath: "/tmp/lane x1", isDirectory: true)
        let transcript = try CapturedClassifierTranscript.load(command: "kraken2-classify", run: "complete-batch", root: root)
        let decoder = CLIEventLineDecoder()
        let events = try transcript.lines.compactMap { try decoder.decode(line: $0) }

        // The lines of each unit as the capture printed them, up to the finalize's `Building` line.
        var labels: [String] = []
        var unitLines: [String] = []
        var current: (index: Int, label: String)?
        var building = false
        for event in events {
            guard case let .progress(_, message) = event, !building else { continue }
            if let start = CLIClassifierRowEvents.unitStart(message) {
                labels.append(start.label)
                current = (start.index, start.label)
            } else if let current {
                if message.hasPrefix("Building ") {
                    building = true
                } else {
                    unitLines.append("Sample \(current.index + 1)/2 (\(current.label)): \(message)")
                }
            }
        }
        XCTAssertEqual(labels, ["negative-control", "test"], "the command runs the samples in its own order, not the inputs'")

        let (rows, effects) = play(events, tool: .kraken2, sampleIDs: ["test", "negative-control"])
        let logged = logLines(effects)
        XCTAssertEqual(logged.filter { $0.hasPrefix("info: Sample ") }, unitLines.map { "info: \($0)" })
        XCTAssertFalse(logged.contains { $0.contains(" of 2).") }, "the executor's unit lines are not shown")
        XCTAssertEqual(effects.compactMap(\.overlay), unitLines, "the overlay shows the unit lines and nothing of the finalize")

        let progress = progressLines(effects)
        XCTAssertEqual(progress.last, "1.0 Building Kraken2 database\u{2026}", "today's detail while the index builds")
        XCTAssertFalse(progress.contains { $0.contains("kraken2.sqlite") }, "the sqlite line is a log line, never the detail")
        guard case let .complete(_, summary)? = events.last, let summary else { return XCTFail("the capture ends in complete") }
        let completed = try XCTUnwrap(Int(summary.prefix { $0.isNumber }), summary)
        XCTAssertEqual(logged.filter { $0.hasPrefix("info: Building ") }, ["info: Building kraken2.sqlite from \(completed) sample(s)"])

        let fractions = effects.flatMap(\.bridged).compactMap { event -> Double? in
            guard case let .progress(fraction, _) = event else { return nil }
            return fraction
        }
        XCTAssertEqual(fractions, fractions.sorted(), "the bar never moves back")
        XCTAssertEqual(fractions.last, 1)
        XCTAssertEqual(effects.compactMap(\.trackedFolder), [try XCTUnwrap(transcript.folder)])
        XCTAssertEqual(rows.failedUnitReasons, [])
    }

    /// D6, D8, D11. A failed sample of an EsViritu batch reads as today's two error lines, the tail
    /// of its log under today's heading and its reason, and never as a warning, so the batch reads
    /// Completed as today. The command logs the tail as an `error` line in a batch, since no
    /// `failed` line carries it (X1 review fix 2), and does so before the executor reports the
    /// reason, so the two lines come in the opposite order of today's batch.
    func testAFailedBatchSampleReadsAsTodaysErrorLinesAndNoWarning() async throws {
        let reason = "EsViritu exited with status 1"
        let run = try await executorRun(StandInClassifierTool(
            tool: .esViritu,
            units: [("A", .fail(reason, logTail: "tail")), ("B", .complete)],
            layout: .batchRoot
        ))
        let (rows, effects) = play(run.events, tool: .esViritu, sampleIDs: ["A", "B"])

        XCTAssertEqual(run.report.warnings, ["A failed: \(reason)"], "the command's own warning")
        XCTAssertEqual(logLines(effects).filter { $0.hasPrefix("warning:") }, [])
        XCTAssertEqual(logLines(effects).filter { $0.hasPrefix("error:") }, [
            "error: Sample 1/2 (A): EsViritu log (last lines):\ntail",
            "error: Sample 1/2 (A): \(reason)",
        ])
        XCTAssertTrue(logLines(effects).contains("info: Building esviritu.sqlite from 1 sample(s)"))
        XCTAssertEqual(rows.failedUnitReasons, [reason])
        XCTAssertFalse(rows.everyUnitFailed)
    }

    /// D8. Of the command's warnings only today's database line stays a warning. A degraded
    /// sample's reason reads as info, since today's batch puts it in its completion detail.
    func testOnlyTodaysDatabaseWarningStaysAWarning() async throws {
        let degraded = "Bracken found no reads at species rank"
        var tool = StandInClassifierTool(tool: .kraken2, units: [("A", .degrade(degraded)), ("B", .complete)], layout: .batchRoot)
        tool.databaseFailure = "disk full"
        let run = try await executorRun(tool)
        let (rows, effects) = play(run.events, tool: .kraken2, sampleIDs: ["A", "B"])
        XCTAssertEqual(run.report.status, .completed, run.report.message)

        XCTAssertEqual(run.report.warnings.count, 2, "the command warns for the degraded sample and the database")
        XCTAssertEqual(logLines(effects).filter { $0.hasPrefix("warning:") }, [
            "warning: The viewer index could not be built (disk full). LGE builds it when the result opens.",
        ])
        XCTAssertTrue(logLines(effects).contains("info: Sample 1/2 (A): \(degraded)"))
        XCTAssertTrue(logLines(effects).contains("info: Building kraken2.sqlite from 2 sample(s)"))
        XCTAssertEqual(rows.databaseError, "disk full")
    }

    /// UX checklist 1. A batch whose every sample failed reads today's detail, the first sample's
    /// error, and not the command's summary of the units.
    func testABatchWhoseEverySampleFailedReadsTheFirstSamplesError() async throws {
        let run = try await executorRun(StandInClassifierTool(
            tool: .kraken2,
            units: [("A", .fail("Empty Kraken2 report", logTail: nil)), ("B", .fail("kraken2 exited with status 2", logTail: nil))],
            layout: .batchRoot
        ))
        let (rows, _) = play(run.events, tool: .kraken2, sampleIDs: ["A", "B"])

        XCTAssertEqual(run.report.status, .failed)
        XCTAssertTrue(rows.everyUnitFailed)
        let failure = CLIClassifierRunner.failure(
            for: CLISubprocessTransport.RunError.failedEvent(message: run.report.message, detail: nil),
            request: CLIClassifierRunRequest(tool: .kraken2, arguments: [], sampleIDs: ["A", "B"]),
            events: rows
        )
        XCTAssertEqual(failure, CLIClassifierFailure(message: "Empty Kraken2 report", errorMessage: nil, errorDetail: nil))
    }

    /// Review fix 1. A batch line names the sample of the command's unit by the label the
    /// executor printed for it, not the dialog's id at the same place, since the command groups
    /// and orders the samples itself. `Sample i/N` keeps the command's place and count.
    func testABatchLineNamesTheSampleOfTheCommandsUnitByItsLabel() async throws {
        let reason = "EsViritu exited with status 1"
        let run = try await executorRun(StandInClassifierTool(
            tool: .esViritu,
            units: [("B", .complete), ("A", .fail(reason, logTail: "tail"))],
            layout: .batchRoot
        ))
        let (rows, effects) = play(run.events, tool: .esViritu, sampleIDs: ["A", "B"])

        XCTAssertEqual(logLines(effects).filter { $0.hasPrefix("info: Sample") }, [
            "info: Sample 1/2 (B): Materializing B into the result folder",
            "info: Sample 1/2 (B): Validating configuration...",
            "info: Sample 1/2 (B): Running EsViritu...",
            "info: Sample 1/2 (B): Detection complete",
            "info: Sample 2/2 (A): Materializing A into the result folder",
            "info: Sample 2/2 (A): Validating configuration...",
            "info: Sample 2/2 (A): Running EsViritu...",
        ])
        XCTAssertEqual(logLines(effects).filter { $0.hasPrefix("error:") }, [
            "error: Sample 2/2 (A): EsViritu log (last lines):\ntail",
            "error: Sample 2/2 (A): \(reason)",
        ])
        XCTAssertEqual(rows.failedUnitReasons, [reason])
    }

    /// Review fix 1. A unit's label that sanitizes to a dialog id shows that id, and a label that
    /// matches no id shows the label itself.
    func testABatchLineShowsTheUnitsLabelWhenItMatchesNoSampleID() async throws {
        let run = try await executorRun(StandInClassifierTool(
            tool: .kraken2,
            units: [("air.B", .complete), ("zeta", .complete)],
            layout: .batchRoot
        ))
        let (_, effects) = play(run.events, tool: .kraken2, sampleIDs: ["air_B", "alpha"])
        XCTAssertEqual(run.report.status, .completed, run.report.message)

        XCTAssertEqual(progressLines(effects).filter { $0.contains("Running Kraken2") }, [
            "0.25 Sample 1/2 (air_B): Running Kraken2...",
            "0.75 Sample 2/2 (zeta): Running Kraken2...",
        ])
    }

    // MARK: - Lines the runner reads

    /// UX checklist 3 and S16. The bar never moves back, a line of standard error stays at info,
    /// and a warning of the command that is not today's warning line reads as info.
    func testTheBarNeverMovesBackAndOtherWarningsReadAsInfo() {
        var rows = CLIClassifierRowEvents(tool: .esViritu, sampleIDs: ["sarscov2"])
        _ = rows.effects(of: .progress(fraction: 0, message: "Running sarscov2."))
        let screening = rows.effects(of: .progress(fraction: 0.55, message: "Screening for viral signatures..."))
        let filtering = rows.effects(of: .progress(fraction: 0.25, message: "Quality filtering reads..."))
        let standardError = rows.effects(of: .log(level: .info, message: "warning: this is standard error"))
        let interleaved = rows.effects(of: .log(level: .warning, message: "The input is interleaved, so it runs as pairs"))

        XCTAssertEqual(screening.bridged.first, .progress(fraction: 0.55, message: "Screening for viral signatures..."))
        XCTAssertEqual(filtering.bridged.first, .progress(fraction: 0.55, message: "Quality filtering reads..."))
        XCTAssertEqual(standardError.bridged, [.log(level: .info, message: "warning: this is standard error")])
        XCTAssertEqual(interleaved.bridged, [.log(level: .info, message: "The input is interleaved, so it runs as pairs")])
    }

    func testTheExecutorsUnitLinesAndTodaysDatabaseWarningAreRead() {
        XCTAssertEqual(CLIClassifierRowEvents.unitStart("Running air.B (2 of 3).")?.index, 1)
        XCTAssertEqual(CLIClassifierRowEvents.unitStart("Running air (B) (2 of 3).")?.label, "air (B)")
        XCTAssertNil(CLIClassifierRowEvents.unitStart("Running EsViritu..."))
        XCTAssertNil(CLIClassifierRowEvents.unitStart("Running A (3 of 2)."))
        XCTAssertEqual(CLIClassifierRowEvents.singleUnitLabel("Running sarscov2."), "sarscov2")
        XCTAssertNil(CLIClassifierRowEvents.singleUnitLabel("Running EsViritu..."))
        XCTAssertNil(CLIClassifierRowEvents.singleUnitLabel("Running A (1 of 2)."))
        XCTAssertEqual(CLIClassifierRowEvents.databaseBuildError(in: AppDelegate.classificationDatabaseBuildWarning("x: y")), "x: y")
        // Phase 2.10 U34, W4. The executors write the app's sentence, so the row reads their warning as the
        // database failure too. The sentence of the single-folder runs read `The viewer index could not be built: x.`
        XCTAssertEqual(
            CLIClassifierRowEvents.databaseBuildError(
                in: "The viewer index could not be built (disk full). LGE builds it when the result opens."
            ),
            "disk full"
        )
        XCTAssertNil(CLIClassifierRowEvents.databaseBuildError(in: "Bracken found no reads at species rank"))
    }

    // MARK: - Helpers

    private struct ExecutorRun {
        let events: [CLIEvent]
        let report: AnalysisRunReport
    }

    /// Runs `tool` with the real executor into a new project and decodes the lines it prints.
    private func executorRun(_ tool: StandInClassifierTool) async throws -> ExecutorRun {
        let root = try TestTempDirectory.make(prefix: "classifier-row-events")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let made = try ClassifierRouteFixtures.makeProject(in: root)
        let transcript = await ClassifierRouteFixtures.transcript(
            of: tool,
            project: made.project,
            inputs: made.inputs,
            arguments: tool.tool == .kraken2 ? ["kraken2", "classify"] : ["esviritu", "detect"]
        )
        let decoder = CLIEventLineDecoder()
        let events = try transcript.lines.map { try XCTUnwrap(try decoder.decode(line: $0), $0) }
        XCTAssertEqual(events.first, .start(message: "Starting \(tool.identity.displayName)."))
        return ExecutorRun(events: events, report: transcript.report)
    }

    private func play(
        _ events: [CLIEvent],
        tool: CLIClassifierTool,
        sampleIDs: [String]
    ) -> (CLIClassifierRowEvents, [CLIClassifierRowEvents.Effects]) {
        var rows = CLIClassifierRowEvents(tool: tool, sampleIDs: sampleIDs)
        let effects = events.map { rows.effects(of: $0) }
        return (rows, effects)
    }

    private func logLines(_ effects: [CLIClassifierRowEvents.Effects]) -> [String] {
        effects.flatMap(\.bridged).compactMap { event in
            guard case let .log(level, message) = event else { return nil }
            return "\(level.rawValue): \(message)"
        }
    }

    private func progressLines(_ effects: [CLIClassifierRowEvents.Effects]) -> [String] {
        effects.flatMap(\.bridged).compactMap { event in
            guard case let .progress(fraction, message) = event else { return nil }
            return "\(fraction) \(message)"
        }
    }
}
