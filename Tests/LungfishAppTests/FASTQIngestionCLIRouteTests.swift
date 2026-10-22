// FASTQIngestionCLIRouteTests.swift - The in-place ingestion route on lungfish-cli fastq ingest, on a stand-in command
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane A47 M3 (the ruling on M3, sections 2 and 4, and decision C5). The route records
// the command it runs and parses with the real parser, holds an import slot around the command so
// copied-in files ingest one at a time, and keeps today's words on its row. The command is a
// stand-in `lungfish-cli` script, so the tests need no tool. `FastqIngestRouteParityReplayTests`
// runs the real leaf against the in-process route.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class FASTQIngestionCLIRouteTests: XCTestCase {
    private let first = URL(fileURLWithPath: "/tmp/lane a47/Project/Imports/SRR1770413_1.fastq.gz")
    private let second = URL(fileURLWithPath: "/tmp/lane a47/Project/Imports/SRR9_1.fastq.gz")

    /// A `lungfish-cli` stand-in that runs `body`.
    private func standInCLI(_ body: String) throws -> URL {
        let root = try TestTempDirectory.make(prefix: "ingest-route-cli")
        addTeardownBlock { TestTempDirectory.cleanup(root) }
        let script = root.appendingPathComponent("lungfish-cli")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    /// A stand-in whose run records its arguments in `started`, waits for the file `release`, and
    /// completes the way `fastq ingest --format json` does.
    private func holdingCLI(started: URL, release: URL) throws -> URL {
        try standInCLI("""
        echo "$*" >> '\(started.path)'
        while [ ! -f '\(release.path)' ]; do sleep 0.05; done
        echo '{"event":"complete","outputs":["/work/out.fastq.gz"],"message":"Clumpified and compressed (saved 0 bytes)","progress":1,"schemaVersion":2}'
        """)
    }

    private func startedLines(_ started: URL) -> [String] {
        ((try? String(contentsOf: started, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private func state(of id: UUID) -> OperationCenter.Item.State? {
        OperationCenter.shared.items.first { $0.id == id }?.state
    }

    // MARK: - The recorded command (ruling section 4)

    func testInPlaceIngestionRecordsACommandThatParsesWithTheRunsValues() throws {
        let arguments = try FASTQIngestionService.inPlaceIngestionCLIArguments(url: first, threads: 7)
        let reporter = RecordingOperationReporter()
        FASTQIngestionService.beginInPlaceIngestionOperation(
            url: first, routeContext: nil, cliArguments: arguments, reporter: reporter
        ) { _ in }
        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.title, "FASTQ Ingestion: SRR1770413", "the CLI route keeps today's title")
        XCTAssertEqual(item.detail, "Preparing...", "and today's first detail")
        XCTAssertEqual(try RecordedCLICommand.arguments(of: item.cliCommand), arguments, "the row records the argv the runner runs")

        let command = try RecordedCLICommand.parse(item.cliCommand, as: FastqIngestSubcommand.self)
        XCTAssertEqual(command.input, first.path)
        XCTAssertNil(command.pair)
        XCTAssertTrue(command.deleteOriginals, "the app's run has always deleted the original")
        XCTAssertEqual(command.binning, QualityBinningScheme.importDefault, "the app's run bins with the import default")
        XCTAssertTrue(
            zip(arguments, arguments.dropFirst()).contains { $0 == "--binning" && $1 == QualityBinningScheme.importDefault.rawValue },
            "the row names its binning, so a record replays the same whatever the default is later: \(arguments)"
        )
        XCTAssertFalse(command.skipClumpify)
        XCTAssertEqual(command.globalOptions.threads, 7, "the leaf records its thread count only when it is given")
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
        XCTAssertEqual(
            try FASTQIngestionService.inPlaceIngestionCLIArguments(url: first),
            [
                "fastq", "ingest", first.path, "--delete-originals", "--binning", QualityBinningScheme.importDefault.rawValue,
                "--threads", String(ProcessInfo.processInfo.activeProcessorCount), "--format", "json",
            ],
            "the run passes the cores it has, as the in-process route did"
        )
    }

    func testAPairedIngestionNamesTheMateAndAnInterleavedOneHasNoCommand() throws {
        let arguments = try FASTQIngestionService.inPlaceIngestionCLIArguments(
            url: first, pairingMode: .pairedEnd, pairedFile: second, threads: 4
        )
        let command = try RecordedCLICommand.parse(
            OperationCenter.buildCLICommand(subcommand: "", args: arguments), as: FastqIngestSubcommand.self
        )
        XCTAssertEqual(command.pair, second.path)
        XCTAssertThrowsError(try FASTQIngestionService.inPlaceIngestionCLIArguments(url: first, pairingMode: .interleaved)) {
            XCTAssertEqual($0 as? InPlaceIngestionCLIError, .interleaved)
        }
        XCTAssertThrowsError(try FASTQIngestionService.inPlaceIngestionCLIArguments(url: first, pairingMode: .pairedEnd)) {
            XCTAssertEqual($0 as? InPlaceIngestionCLIError, .pairedEndWithoutMate)
        }
        XCTAssertNil(
            FASTQIngestionService.startInPlaceIngestionThroughCLI(url: first, pairingMode: .interleaved, routeContext: nil),
            "a pairing with no command starts no row"
        )
    }

    // MARK: - The import slot (ruling section 2)

    func testTwoRowsRunOneCommandAtATime() async throws {
        let root = try TestTempDirectory.make(prefix: "ingest-route-slot")
        defer { TestTempDirectory.cleanup(root) }
        let started = root.appendingPathComponent("started.txt")
        let release = root.appendingPathComponent("release")
        let cli = try holdingCLI(started: started, release: release)

        let a = try XCTUnwrap(
            FASTQIngestionService.startInPlaceIngestionThroughCLI(url: first, routeContext: nil, runner: CLIReadsRunner(cliURLOverride: cli))?.startedID
        )
        let b = try XCTUnwrap(
            FASTQIngestionService.startInPlaceIngestionThroughCLI(url: second, routeContext: nil, runner: CLIReadsRunner(cliURLOverride: cli))?.startedID
        )
        defer { for id in [a, b] { OperationCenter.shared.clearItem(id: id) } }

        let firstRuns = await waitUntil(timeout: .seconds(30)) { !self.startedLines(started).isEmpty }
        XCTAssertTrue(firstRuns, "the first command never started")
        var snapshot = await FASTQImportSlotCoordinator.shared.testingSnapshot()
        for _ in 0..<200 where snapshot.waitingImports != 1 {
            try await Task.sleep(for: .milliseconds(50))
            snapshot = await FASTQImportSlotCoordinator.shared.testingSnapshot()
        }
        XCTAssertEqual(snapshot.activeImports, 1)
        XCTAssertEqual(snapshot.waitingImports, 1, "the second row waits for the slot")
        XCTAssertEqual(startedLines(started).count, 1, "one command runs: \(startedLines(started))")
        // Which row takes the slot first is up to the scheduler.
        let runningURL = startedLines(started)[0].contains(first.path) ? first : second
        let waitingURL = runningURL == first ? second : first
        let waitingID = runningURL == first ? b : a
        XCTAssertEqual(
            startedLines(started)[0],
            try FASTQIngestionService.inPlaceIngestionCLIArguments(url: runningURL).joined(separator: " "),
            "the runner runs the argv the row records"
        )
        XCTAssertEqual(
            OperationCenter.shared.items.first { $0.id == waitingID }?.detail, "Waiting for available import slot\u{2026}"
        )

        try Data().write(to: release)
        let both = await waitUntil(timeout: .seconds(30)) { self.state(of: a) == .completed && self.state(of: b) == .completed }
        XCTAssertTrue(both, "states \(String(describing: state(of: a))), \(String(describing: state(of: b)))")
        XCTAssertEqual(startedLines(started).count, 2, "the second command ran after the first")
        XCTAssertTrue(startedLines(started)[1].contains(waitingURL.path))
    }

    func testACancelledWaitingRowLaunchesNothing() async throws {
        let root = try TestTempDirectory.make(prefix: "ingest-route-waiting-cancel")
        defer { TestTempDirectory.cleanup(root) }
        let started = root.appendingPathComponent("started.txt")
        let release = root.appendingPathComponent("release")
        let cli = try holdingCLI(started: started, release: release)

        let a = try XCTUnwrap(
            FASTQIngestionService.startInPlaceIngestionThroughCLI(url: first, routeContext: nil, runner: CLIReadsRunner(cliURLOverride: cli))?.startedID
        )
        let b = try XCTUnwrap(
            FASTQIngestionService.startInPlaceIngestionThroughCLI(url: second, routeContext: nil, runner: CLIReadsRunner(cliURLOverride: cli))?.startedID
        )
        defer { for id in [a, b] { OperationCenter.shared.clearItem(id: id) } }
        let firstRuns = await waitUntil(timeout: .seconds(30)) { !self.startedLines(started).isEmpty }
        XCTAssertTrue(firstRuns, "the first command never started")
        var snapshot = await FASTQImportSlotCoordinator.shared.testingSnapshot()
        for _ in 0..<200 where snapshot.waitingImports != 1 {
            try await Task.sleep(for: .milliseconds(50))
            snapshot = await FASTQImportSlotCoordinator.shared.testingSnapshot()
        }
        XCTAssertEqual(snapshot.waitingImports, 1, "the second row waits for the slot")

        // Which row takes the slot first is up to the scheduler, so the test cancels the other one.
        let runningIsFirst = startedLines(started)[0].contains(first.path)
        let waitingID = runningIsFirst ? b : a
        let runningID = runningIsFirst ? a : b
        OperationCenter.shared.cancel(id: waitingID)
        let cancelled = await waitUntil(timeout: .seconds(30)) { self.state(of: waitingID) == .cancelled }
        XCTAssertTrue(cancelled, "the waiting row ends cancelled: \(String(describing: state(of: waitingID)))")
        try Data().write(to: release)
        let finished = await waitUntil(timeout: .seconds(30)) { self.state(of: runningID) == .completed }
        XCTAssertTrue(finished, "the running row completes: \(String(describing: state(of: runningID)))")

        XCTAssertEqual(startedLines(started).count, 1, "the cancelled row launched nothing: \(startedLines(started))")
        let after = await FASTQImportSlotCoordinator.shared.testingSnapshot()
        XCTAssertEqual(after.activeImports, 0)
        XCTAssertEqual(after.waitingImports, 0)
    }

    // MARK: - The row's words (ruling section 3, item e)

    /// The row shows `Preparing...` and then the slot wait and the pipeline's words, never the
    /// command's `start` line as a detail. The runner logs that line at info instead.
    func testTheRowKeepsPreparingAndLogsTheStartLine() async throws {
        let transcript = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/cli-events/commands/fastq-ingest/complete.ndjson")
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.path), "the transcript of the leaf's events")
        let runner = CLIReadsRunner(cliURLOverride: try standInCLI("cat '\(transcript.path)'"))
        let input = URL(fileURLWithPath: "/tmp/lane a47/Project/Imports/SRR9_1.fastq")

        let (row, item) = try await ReadsRouteParity.record(title: "FASTQ Ingestion: SRR9") {
            FASTQIngestionService.startInPlaceIngestionThroughCLI(url: input, routeContext: nil, runner: runner)
        }

        XCTAssertEqual(item.state, .completed, row.text)
        XCTAssertEqual(Array(row.shown.prefix(2)), ["Preparing...", "Waiting for available import slot\u{2026}"], row.text)
        XCTAssertFalse(row.shown.contains { $0.hasPrefix("Ingesting ") }, "the start line is no detail: \(row.shown)")
        XCTAssertTrue(row.logged.contains { $0.hasPrefix("info Ingesting ") }, "the start line is logged at info: \(row.logged)")
        XCTAssertTrue(row.end.hasPrefix("completed Clumpified and compressed"), row.end)
    }
}
