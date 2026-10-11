// CLIClassifierRowEventsTests.swift - The row lines the CLI route makes of the executor's stream
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.7 lane A10, UX differences D5 to D8, D11, D14 and D17. Each test runs the real analysis
// run executor in process with a stand-in tool, so the stream is the one `--format json` prints,
// and plays it through `CLIClassifierRowEvents`, the rules the CLI route's runner applies.

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
            "0.0 Validating configuration...",
            "0.5 Running Kraken2...",
            "1.0 Classification complete",
        ])
        XCTAssertEqual(effects.compactMap(\.overlay), ["Validating configuration...", "Running Kraken2...", "Classification complete"])
        let folder = try XCTUnwrap(run.report.analysisDirectory)
        XCTAssertEqual(effects.compactMap(\.trackedFolder).map(\.standardizedFileURL), [folder.standardizedFileURL])
        XCTAssertEqual(rows.analysisFolder?.standardizedFileURL, folder.standardizedFileURL)
        XCTAssertTrue(effects[0].bridged.isEmpty, "the begin text stays the first detail")
    }

    /// D11. The EsViritu log tail of a failed single run goes to the error detail, not the log,
    /// and the alert shows the command's `failed` message, the pipeline's own error.
    func testTheEsVirituLogTailOfAFailedSingleRunGoesToTheErrorDetail() async throws {
        let reason = "EsViritu exited with status 1"
        let run = try await executorRun(StandInClassifierTool(
            tool: .esViritu,
            units: [("air-A", .fail(reason, logTail: "line 1\nline 2"))],
            layout: .batchRoot
        ))
        let (rows, effects) = play(run.events, tool: .esViritu, sampleIDs: ["air-A"])

        XCTAssertEqual(run.report.message, reason, "a single sample's failure is the run's message")
        XCTAssertFalse(logLines(effects).contains { $0.contains("EsViritu log") }, "the tail is no log line, as today")
        XCTAssertEqual(rows.esVirituLogTail, "EsViritu log (last lines):\nline 1\nline 2")
        let failure = CLIClassifierRunner.failure(
            for: CLISubprocessTransport.RunError.failedEvent(message: run.report.message, detail: nil),
            request: CLIClassifierRunRequest(tool: .esViritu, arguments: [], sampleIDs: ["air-A"]),
            events: rows
        )
        XCTAssertEqual(failure, CLIClassifierFailure(
            message: reason,
            errorMessage: reason,
            errorDetail: "EsViritu log (last lines):\nline 1\nline 2"
        ))
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
            "0.0 Sample 1/2 (A): Validating configuration...",
            "0.25 Sample 1/2 (A): Running EsViritu...",
            "0.5 Sample 1/2 (A): Detection complete",
            "0.5 Sample 2/2 (B): Validating configuration...",
            "0.75 Sample 2/2 (B): Running EsViritu...",
            "1.0 Sample 2/2 (B): Detection complete",
            "1.0 Writing the EsViritu batch summary\u{2026}",
            "1.0 Building EsViritu database\u{2026}",
        ])
        XCTAssertFalse(effects.compactMap(\.overlay).contains("Building EsViritu database\u{2026}"), "today's database line has no overlay")
    }

    /// D8, D11. A failed sample of an EsViritu batch reads as today's error lines, its log tail
    /// and its reason, and never as a warning, so the batch reads Completed as today.
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
            "warning: Database build failed: disk full \u{2014} batch will rebuild lazily on open",
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
        XCTAssertNil(CLIClassifierRowEvents.databaseBuildError(in: "The viewer index could not be built: x."))
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
