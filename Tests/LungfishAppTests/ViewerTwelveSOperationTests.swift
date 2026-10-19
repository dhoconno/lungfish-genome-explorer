// ViewerTwelveSOperationTests.swift - begin() site in ViewerViewController+TwelveS
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// The 12S unresolved-sequence BLAST registers its row through a static begin
// helper (R4). The row locks no bundle. The run executes
// `lungfish-cli fastq 12s-export-unresolved` first, which writes the
// unresolved sequences to a FASTA file, and then searches them with
// `lungfish-cli blast submit` (Phase 2.12, lane 12.09). The row logs the
// export command, which must parse with the values the run uses, and records
// the `blast submit` command that runs the search, which a test parses. As for
// EsViritu (lane 12.08), the row begins before the export, with no command,
// and takes its command once the sequences have made the plan, so Cancel
// reaches the row, and the export's process tree, during the export. A
// reporter that refuses every begin proves the launch closure sits behind the
// `.started` case.

import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishCore
import LungfishKit
import LungfishKitTestSupport
import LungfishTestSupport

@MainActor
final class ViewerTwelveSOperationTests: XCTestCase {
    private let bundleURL = URL(
        fileURLWithPath: "/tmp/lane 1a2f/Project.lungfish/Analyses/12S Run/result.lungfish12s",
        isDirectory: true
    )
    private let exportURL = URL(
        fileURLWithPath: "/tmp/lane 1a2f/lungfish-12s-blast-ABC123/unresolved-min3.fasta"
    )

    /// The argv the call site builds, through the same builder.
    private func makeArguments(sequenceIDs: [String] = ["unresolved-1", "unresolved-2"]) -> [String] {
        ViewerViewController.twelveSUnresolvedExportArguments(
            bundleURL: bundleURL,
            minimumReads: 3,
            exportURL: exportURL,
            sequenceIDs: sequenceIDs
        )
    }

    /// The export command the row's log names.
    private func loggedExportCommand(_ item: RecordingOperationReporter.Item) throws -> String {
        let message = try XCTUnwrap(item.logs.first?.message)
        XCTAssertTrue(message.hasPrefix(ViewerViewController.twelveSExportLogPrefix), message)
        return String(message.dropFirst(ViewerViewController.twelveSExportLogPrefix.count))
    }

    func testTwelveSUnresolvedBlastRecordsItsRowAndLogsARunnableExportCommand() throws {
        let reporter = RecordingOperationReporter()
        var launchedID: UUID?

        ViewerViewController.beginTwelveSUnresolvedBlastOperation(
            cliArguments: makeArguments(),
            reporter: reporter
        ) { launchedID = $0 }

        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(launchedID, item.id)
        XCTAssertEqual(item.title, "BLAST 12S Unresolved")
        XCTAssertEqual(item.initialDetail, "Preparing unresolved sequence FASTA...")
        XCTAssertEqual(item.operationType, .blastVerification)
        XCTAssertNil(item.targetBundleURL)
        XCTAssertEqual(item.additionalLockedBundleURLs, [])
        XCTAssertNil(item.routeContext)
        XCTAssertNil(item.cliCommand, "the row begins before the export, and the search's command comes with the plan")
        let command = try RecordedCLICommand.parse(
            try loggedExportCommand(item),
            as: FastqTwelveSExportUnresolvedSubcommand.self
        )
        XCTAssertEqual(command.bundle, bundleURL.path)
        XCTAssertEqual(command.minimumReads, 3)
        XCTAssertEqual(command.output, exportURL.path)
        XCTAssertNil(command.metadataOutput)
        XCTAssertTrue(command.includeChimeraCandidates)
        XCTAssertEqual(command.sequenceIDs, ["unresolved-1", "unresolved-2"])
        XCTAssertTrue(command.force)
    }

    func testTwelveSUnresolvedBlastRecordsNoSequenceIDWhenNoneAreSelected() throws {
        let reporter = RecordingOperationReporter()

        ViewerViewController.beginTwelveSUnresolvedBlastOperation(
            cliArguments: makeArguments(sequenceIDs: []),
            reporter: reporter
        ) { _ in }

        let item = try XCTUnwrap(reporter.items.first)
        let exportCommand = try loggedExportCommand(item)
        let command = try RecordedCLICommand.parse(exportCommand, as: FastqTwelveSExportUnresolvedSubcommand.self)
        XCTAssertEqual(command.sequenceIDs, [])
        XCTAssertFalse(exportCommand.contains("--sequence-id"))
    }

    func testTwelveSUnresolvedBlastRecordsTheBlastSubmitCommandAndLogsTheExportStringByteForByte() throws {
        let scratch = try TestTempDirectory.make(prefix: "twelves-blast-begin")
        defer { TestTempDirectory.cleanup(scratch) }
        let project = scratch.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundle = project.appendingPathComponent("Analyses/12S Run/result.lungfish12s", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let plan = try ViewerViewController.twelveSUnresolvedBlastSubmitPlan(
            sequences: Self.sequences, bundleURL: bundle, projectURL: project
        )
        let reporter = RecordingOperationReporter()

        ViewerViewController.beginTwelveSUnresolvedBlastOperation(
            cliArguments: makeArguments(),
            cliCommand: plan.cliCommand,
            reporter: reporter
        ) { _ in }

        // The row records the `blast submit` command that runs the search. The
        // log keeps the export string the row recorded before, byte for byte,
        // as the step that made the query.
        let item = try XCTUnwrap(reporter.items.first)
        XCTAssertEqual(item.cliCommand, plan.cliCommand)
        let command = try RecordedCLICommand.parse(item.cliCommand, as: BlastCommand.SubmitSubcommand.self)
        let stage = URL(fileURLWithPath: command.queryPath).deletingLastPathComponent()
        XCTAssertTrue(stage.lastPathComponent.hasPrefix("blast-submit-"), command.queryPath)
        XCTAssertEqual(stage.deletingLastPathComponent().lastPathComponent, ".tmp", "the query file sits in the project's .tmp")
        let output = URL(fileURLWithPath: command.outputPath).deletingLastPathComponent()
        XCTAssertEqual(output.lastPathComponent, "blast-verifications")
        XCTAssertEqual(output.deletingLastPathComponent().path, project.path, "the search sits under the project, not in the bundle")
        XCTAssertEqual(command.label, "12S unresolved sequences")
        XCTAssertNil(command.taxId, "the sequences matched no target, so no taxon")
        XCTAssertNil(command.contig)
        XCTAssertNil(command.sample, "the sequences are pooled across samples")
        XCTAssertEqual(command.sourceResult, bundle.path, "the 12S bundle the export read")
        XCTAssertNil(command.subsampleCount, "every exported sequence is searched")
        XCTAssertNil(command.subsampleSeed)
        XCTAssertEqual(command.acceptedTaxIds, [])
        XCTAssertEqual(command.acceptedNames, [])
        XCTAssertEqual(command.relatedNames, [])
        XCTAssertEqual(command.globalOptions.outputFormat, .json)
        XCTAssertEqual(String(decoding: plan.queryData, as: UTF8.self).components(separatedBy: ">").count - 1, 2)
        XCTAssertEqual(
            try loggedExportCommand(item),
            "lungfish-cli fastq 12s-export-unresolved"
                + " --bundle '/tmp/lane 1a2f/Project.lungfish/Analyses/12S Run/result.lungfish12s'"
                + " --min-reads 3"
                + " --output '/tmp/lane 1a2f/lungfish-12s-blast-ABC123/unresolved-min3.fasta'"
                + " --include-chimera-candidates --force"
                + " --sequence-id unresolved-1 --sequence-id unresolved-2"
        )
    }

    func testTwelveSUnresolvedBlastLaunchesNothingWhenTheBeginIsRefused() throws {
        // The row requests no lock, so no real center refuses it. A reporter
        // that refuses every begin proves the launch closure sits behind the
        // `.started` case.
        let reporter = RecordingOperationReporter(lockHeldBy: "Importing BAM")
        var launched = false

        let result = ViewerViewController.beginTwelveSUnresolvedBlastOperation(
            cliArguments: makeArguments(),
            reporter: reporter
        ) { _ in launched = true }

        guard case .refused = result else { return XCTFail("The refusal must be reported") }
        XCTAssertFalse(launched, "a refused row must launch nothing")
        XCTAssertEqual(reporter.items.map(\.state), [.refused])
    }

    // MARK: - The row begins before the export (the order of lane 12.08, review fix 4)

    private var folder: URL!

    override func setUp() async throws {
        try await super.setUp()
        folder = try TestTempDirectory.make(prefix: "twelves-blast-row")
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(folder)
        try await super.tearDown()
    }

    /// While the sequences are exported the Operations panel shows one running BLAST row with no command.
    /// Once they are read, the row takes the command of the plan they make before the leaf starts.
    func testTheBlastRowBeginsBeforeTheExportAndTakesItsCommandAfterIt() async throws {
        let fixture = try makeFixture()
        let gate = PreparationGate()
        addTeardownBlock { await gate.open(with: []) }
        let spy = DrawerSpy()
        let viewer = ViewerViewController()
        let known = Set(OperationCenter.shared.items.map(\.id))

        let task = viewer.launchTwelveSUnresolvedBlastSubmit(
            bundleURL: fixture.bundle, exportURL: exportURL, arguments: makeArguments(), controller: nil,
            drawer: spy.drawer, runner: CLIBlastSubmitRunner(cliURLOverride: fixture.leaf.script),
            prepare: { _, _, _ in try await gate.prepare() }
        )

        XCTAssertNotNil(task, "a project is open, so the search starts")
        let armed = await waitUntil(timeout: .seconds(10)) { await gate.started }
        XCTAssertTrue(armed, "the preparation never started")
        let row = try XCTUnwrap(newRow(since: known), "no row while the sequences are exported")
        let id = row.id
        defer { OperationCenter.shared.clearItem(id: id) }
        XCTAssertEqual(row.state, .running)
        XCTAssertEqual(row.operationType, .blastVerification)
        XCTAssertNil(row.cliCommand, "the command waits for the plan the sequences make")
        XCTAssertEqual(spy.failures, [])

        await gate.open(with: Self.sequences)
        let leafStarted = await waitUntil(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: fixture.leaf.started.path) }
        XCTAssertTrue(leafStarted, "the leaf never started")
        let running = try XCTUnwrap(self.row(id))
        XCTAssertEqual(running.state, .running)
        let command = try RecordedCLICommand.parse(running.cliCommand, as: BlastCommand.SubmitSubcommand.self)
        XCTAssertEqual(command.label, "12S unresolved sequences")
        XCTAssertEqual(command.sourceResult, fixture.bundle.path)

        OperationCenter.shared.cancel(id: id)
        let ended = await waitUntil(timeout: .seconds(15)) { self.row(id)?.state == .cancelled }
        XCTAssertTrue(ended, "the cancelled row never reached Cancelled")
    }

    /// A Cancel on the row while `lungfish-cli fastq 12s-export-unresolved` runs stops that process tree
    /// through the handle the row's cancel callback holds, ends the row cancelled and starts no search. The
    /// export is a stand-in script that records its process ID and waits.
    func testCancellingTheRowDuringTheExportStopsItAndStartsNoSearch() async throws {
        let fixture = try makeFixture()
        let export = try makeStandIn(startFile: "export.started")
        let spy = DrawerSpy()
        let presenter = RecordingNoProjectPresenter()
        let viewer = ViewerViewController()
        let known = Set(OperationCenter.shared.items.map(\.id))

        let launched = AppDelegate.NoProjectPresenterSeam.$presenter.withValue(presenter) {
            viewer.launchTwelveSUnresolvedBlastSubmit(
                bundleURL: fixture.bundle, exportURL: exportURL, arguments: makeArguments(), controller: nil,
                drawer: spy.drawer, runner: CLIBlastSubmitRunner(cliURLOverride: fixture.leaf.script),
                prepare: { arguments, _, cancellation in
                    _ = try await LungfishCLIRunner.run(
                        arguments: arguments, executableURL: export.script, cancellation: cancellation
                    )
                    return []
                }
            )
        }
        let task = try XCTUnwrap(launched)
        let started = await waitUntil(timeout: .seconds(30)) { FileManager.default.fileExists(atPath: export.started.path) }
        XCTAssertTrue(started, "the export never started")
        let pid = try XCTUnwrap(Int32(try String(contentsOf: export.started, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(Self.processExists(pid), "the export runs before the cancel")
        let row = try XCTUnwrap(newRow(since: known), "no row to cancel while the sequences are exported")
        let id = row.id
        defer { OperationCenter.shared.clearItem(id: id) }

        let cancelledAt = ContinuousClock.now
        OperationCenter.shared.cancel(id: id)
        XCTAssertEqual(self.row(id)?.state, .cancelling)
        await task.value
        XCTAssertLessThan(cancelledAt.duration(to: .now), .seconds(7), "the export stopped inside the grace, not at its 30 s end")
        let gone = await waitUntil(timeout: .seconds(7)) { !Self.processExists(pid) }
        XCTAssertTrue(gone, "the export process \(pid) is still there")

        let ended = try XCTUnwrap(self.row(id))
        XCTAssertEqual(ended.state, .cancelled)
        XCTAssertEqual(ended.detail, "Cancelled by user")
        XCTAssertNil(ended.errorMessage, "a cancel carries no failure text")
        XCTAssertNil(ended.cliCommand, "no plan was made, so the row never took a command")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.leaf.started.path), "no leaf, so no search")
        let stages = (try? FileManager.default.contentsOfDirectory(atPath: fixture.project.appendingPathComponent(".tmp").path)) ?? []
        XCTAssertEqual(stages.filter { $0.hasPrefix("blast-submit-") }, [], "no query was staged")
        XCTAssertEqual(spy.failures, [], "the drawer is told of no failure")
        XCTAssertEqual(spy.results.count, 0)
        XCTAssertEqual(presenter.presentations.count, 0, "a cancel shows no alert")
    }

    /// A failed export fails the row with the error's words and shows the same words once in the drawer.
    func testAnExportFailureFailsTheRowAndTheDrawer() async throws {
        let fixture = try makeFixture()
        let spy = DrawerSpy()
        let viewer = ViewerViewController()
        let known = Set(OperationCenter.shared.items.map(\.id))

        let launched = viewer.launchTwelveSUnresolvedBlastSubmit(
            bundleURL: fixture.bundle, exportURL: exportURL, arguments: makeArguments(), controller: nil,
            drawer: spy.drawer, runner: CLIBlastSubmitRunner(cliURLOverride: fixture.leaf.script),
            prepare: { _, _, _ in throw BlastServiceError.noSequences }
        )
        let task = try XCTUnwrap(launched)
        await task.value

        let words = BlastServiceError.noSequences.localizedDescription
        let row = try XCTUnwrap(newRow(since: known), "the failure reaches the Operations panel")
        defer { OperationCenter.shared.clearItem(id: row.id) }
        XCTAssertEqual(row.state, .failed)
        XCTAssertEqual(row.errorMessage, words)
        XCTAssertEqual(row.detail, words)
        XCTAssertNil(row.cliCommand, "no plan was made, so the row never took a command")
        XCTAssertEqual(spy.failures, [words], "the drawer shows the failure once")
        XCTAssertEqual(spy.results.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.leaf.started.path), "no leaf, so no search")
    }

    // MARK: - No project (A65-NOPROJECT, DEC Q-U8)

    /// With no project the action shows the `No Project Open` refusal, begins no row and writes nothing, and
    /// the plan itself refuses before it writes a byte.
    func testATwelveSSearchWithNoProjectRefusesAndStartsNothing() throws {
        let bundle = folder.appendingPathComponent("12s-run/result.lungfish12s", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let before = (FileManager.default.subpaths(atPath: folder.path) ?? []).sorted()
        let known = Set(OperationCenter.shared.items.map(\.id))
        let presenter = RecordingNoProjectPresenter()
        let viewer = ViewerViewController()

        let launched = AppDelegate.NoProjectPresenterSeam.$presenter.withValue(presenter) {
            viewer.launchTwelveSUnresolvedBlastSubmit(
                bundleURL: bundle, exportURL: exportURL, arguments: makeArguments(), controller: nil,
                prepare: { _, _, _ in [] }
            )
        }

        XCTAssertNil(launched, "no project, so no task")
        XCTAssertEqual(presenter.presentations.map(\.title), ["No Project Open"])
        XCTAssertEqual(presenter.presentations.map(\.message), ["Open or create a project before running BLAST."])
        XCTAssertNil(newRow(since: known), "no row begins")
        XCTAssertEqual((FileManager.default.subpaths(atPath: folder.path) ?? []).sorted(), before, "the refusal writes nothing")
        XCTAssertThrowsError(
            try ViewerViewController.twelveSUnresolvedBlastSubmitPlan(sequences: Self.sequences, bundleURL: bundle, projectURL: nil)
        ) { XCTAssertEqual($0 as? BlastSubmitPlanError, .noProject) }
    }

    // MARK: - Fixtures

    /// Two unresolved sequences, as the export gives them.
    private static let sequences: [(id: String, sequence: String)] = [
        (id: "unresolved-1", sequence: "ACGTACGTACGTACGTACGT"), (id: "unresolved-2", sequence: "GGCCTTAAGGCCTTAAGGCC"),
    ]

    /// A project with a 12S result bundle and a stand-in `lungfish-cli` that records its process ID in a
    /// start file when it starts and then waits. The file's absence says no leaf ran.
    private struct Fixture {
        let project: URL
        let bundle: URL
        let leaf: (script: URL, started: URL)
    }

    private func makeFixture() throws -> Fixture {
        let project = folder.appendingPathComponent("Project.lungfish", isDirectory: true)
        let bundle = project.appendingPathComponent("Analyses/12S Run/result.lungfish12s", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        return Fixture(project: project, bundle: bundle, leaf: try makeStandIn(startFile: "leaf.started"))
    }

    private func makeStandIn(startFile name: String) throws -> (script: URL, started: URL) {
        let started = folder.appendingPathComponent(name)
        let partial = folder.appendingPathComponent(name + ".partial")
        let script = folder.appendingPathComponent("lungfish-cli-\(UUID().uuidString)")
        let body = "#!/bin/sh\n/bin/echo $$ > '\(partial.path)'\n/bin/mv '\(partial.path)' '\(started.path)'\nexec /bin/sleep 30\n"
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, started)
    }

    /// The row a launch began since `known`. Every 12S BLAST row has one title, so the rows are told apart by ID.
    private func newRow(since known: Set<UUID>) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.title == "BLAST 12S Unresolved" && !known.contains($0.id) }
    }

    private func row(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    private nonisolated static func processExists(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    /// What the drawer of a BLAST action was told, in order.
    @MainActor
    private final class DrawerSpy {
        private(set) var phases: [BlastJobPhase] = []
        private(set) var results: [BlastVerificationResult] = []
        private(set) var failures: [String] = []

        var drawer: BlastSubmitDrawer {
            BlastSubmitDrawer(
                loading: { [self] phase in phases.append(phase) },
                results: { [self] result, _ in results.append(result) },
                failure: { [self] text in failures.append(text) }
            )
        }
    }

    /// A stand-in for the export that waits for the test, so the row can be read while the preparation runs.
    /// `open` lets it return the sequences it is handed.
    private actor PreparationGate {
        private var continuation: CheckedContinuation<[(id: String, sequence: String)], any Error>?
        private(set) var started = false

        func prepare() async throws -> [(id: String, sequence: String)] {
            started = true
            return try await withCheckedThrowingContinuation { continuation = $0 }
        }

        func open(with sequences: [(id: String, sequence: String)]) {
            continuation?.resume(returning: sequences)
            continuation = nil
        }
    }
}
