// BlastQuitVersusCancelTests.swift - A quit leaves a search at NCBI and a person's Cancel stops it, whichever order they run in
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane LASTROWS (land-18.md:107, "A test that waits for that callback is still owed"). OperationCenter runs a row's Cancel on
// a global queue after `cancelAll()` has returned. A Cancel that read a flag which holds only while `cancelAll()` runs read
// false there and took a quit for a person's Stop, so it wrote `stopped` on a search that should have stayed on its row.
// `wasCancelledByAQuit(id:)` keeps the ids instead. Each test reads what the callback did after it ran. A stand-in leaf
// answers, so nothing leaves this Mac.

import Foundation
import Synchronization
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow

/// Holds a task until it is cancelled or the test opens it.
private final class Gate: Sendable {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        (stream, continuation) = AsyncStream.makeStream()
    }

    func wait() async {
        for await _ in stream { break }
    }
}

/// Set from the Cancel callback's queue, read by the test.
private final class Flag: Sendable {
    private let state = Mutex(false)
    var isSet: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
}

@MainActor
final class BlastQuitVersusCancelTests: XCTestCase {
    private var folder: URL!
    private var rows: [UUID] = []

    override func setUp() async throws {
        try await super.setUp()
        folder = try TestTempDirectory.make(prefix: "blast-quit-versus-cancel")
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    override func tearDown() async throws {
        for row in rows { OperationCenter.shared.cancelFinishAndClearForTest(id: row) }
        rows = []
        TestTempDirectory.cleanup(folder)
        try await super.tearDown()
    }

    // MARK: - A FASTA row's Cancel (ViewerViewController+BlastSubmit.swift, setFASTABlastCancel)

    /// The order OperationCenter's queue gives: `cancelAll()` has returned when the callback body runs.
    func testAQuitThatLosesTheRaceLeavesAFastaSearchOnItsRowAndWritesNoStopped() async throws {
        let fixture = try makeFixture()
        let id = begin(onCancel: {})
        let task = settlingTask(for: id)

        OperationCenter.shared.cancelAll()
        let followUp = ViewerViewController.cancelFASTABlastRun(
            operationID: id, output: fixture.plan.request.outputURL, task: task, stopper: fixture.runner
        )
        await task.value
        await followUp?.value

        XCTAssertNil(followUp, "a quit started the stop that a person's Cancel starts")
        XCTAssertEqual(item(id)?.state, .cancelled)
        XCTAssertNotEqual(item(id)?.detail, BlastSearchWords.stopped, "a quit reads as a person's Stop")
        XCTAssertEqual(try fixture.store.load().state, .waiting, "a quit never writes stopped")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.log.path), "blast stop ran after a quit")
    }

    func testAPersonsCancelOfAFastaRowWritesStoppedAndTheRowSaysSo() async throws {
        let fixture = try makeFixture()
        let id = begin(onCancel: {})
        let task = settlingTask(for: id)

        OperationCenter.shared.cancel(id: id)
        let followUp = ViewerViewController.cancelFASTABlastRun(
            operationID: id, output: fixture.plan.request.outputURL, task: task, stopper: fixture.runner
        )
        await task.value
        await followUp?.value

        XCTAssertNotNil(followUp, "a person's Cancel started no stop")
        XCTAssertEqual(item(id)?.detail, BlastSearchWords.stopped)
        XCTAssertTrue(argv(fixture).contains("blast stop --output"), "blast stop never ran: \(argv(fixture))")
    }

    // MARK: - A viewer's Cancel (ViewerViewController+BlastSubmit.swift, launchBlastSubmit)

    /// The callback is the one `launchBlastSubmit` installed, run by OperationCenter's own queue. The test waits for it.
    func testAQuitThatLosesTheRaceLeavesAViewersSearchOnItsRowAndWritesNoStopped() async throws {
        let fixture = try makeFixture()
        let run = try await startViewerRun(fixture)

        OperationCenter.shared.cancelAll()
        let called = await waitUntil(timeout: WaitBudget.lookup.duration) { run.ran.isSet }
        XCTAssertTrue(called, "the Cancel callback never ran")
        await run.task.value

        XCTAssertFalse(fixture.runner.wasStoppedByAPerson, "a quit reads as a person's Stop")
        XCTAssertEqual(item(run.id)?.state, .cancelled)
        XCTAssertNotEqual(item(run.id)?.detail, BlastSearchWords.stopped)
        XCTAssertEqual(try fixture.store.load().state, .waiting, "a quit never writes stopped")
        XCTAssertFalse(argv(fixture).contains("blast stop"), argv(fixture))
    }

    func testAPersonsCancelOfAViewersRunWritesStoppedAndTheRowSaysSo() async throws {
        let fixture = try makeFixture()
        let run = try await startViewerRun(fixture)

        OperationCenter.shared.cancel(id: run.id)
        let called = await waitUntil(timeout: WaitBudget.lookup.duration) { run.ran.isSet }
        XCTAssertTrue(called, "the Cancel callback never ran")
        await run.task.value

        XCTAssertTrue(fixture.runner.wasStoppedByAPerson)
        XCTAssertEqual(item(run.id)?.detail, BlastSearchWords.stopped)
        let stopped = await waitUntil(timeout: WaitBudget.lookup.duration) { self.argv(fixture).contains("blast stop --output") }
        XCTAssertTrue(stopped, "blast stop never ran: \(argv(fixture))")
    }

    // MARK: - Support

    private struct Fixture {
        let plan: BlastSubmitPlan
        let store: BlastSearchStore
        let log: URL
        let runner: CLIBlastSubmitRunner
    }

    /// A search waiting in its folder, and a stand-in leaf that logs each command it is given and answers `blast stop`.
    private func makeFixture() throws -> Fixture {
        let project = folder.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let plan = try BlastSubmitPlan.make(
            sequences: [(id: "read_1", sequence: "ACGTACGTACGTACGTACGT")], label: "Quit fixture", projectURL: project
        )
        try FileManager.default.createDirectory(at: plan.request.outputURL, withIntermediateDirectories: true)
        let request = BlastVerificationRequest(
            taxonName: "Quit fixture", taxId: 0, sequences: [(id: "read_1", sequence: "ACGT")], database: "core_nt"
        )
        var file = BlastSearchFile(
            origin: .standIn, createdAt: Date(), submitArgv: [], facts: BlastSearchFile.Facts(request),
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "x", sequenceCount: 1), formSHA256: "x"
        )
        file.state = .waiting
        file.copies[0].rid = "RID-QUIT"
        file.copies[0].state = .live
        let store = BlastSearchStore(folder: plan.request.outputURL)
        try store.save(file)

        let log = folder.appendingPathComponent("argv.log")
        let cli = folder.appendingPathComponent("lungfish-cli-quit")
        let leaf = "#!/bin/bash\n/bin/echo \"$*\" >> '\(log.path)'\nif [ \"$2\" = stop ]; then\n"
            + "  /bin/echo '{\"event\":\"complete\",\"message\":\"stopped\",\"outputs\":[\"x\"],\"schemaVersion\":2}'\n  exit 0\nfi\nexec /bin/sleep 30\n"
        try leaf.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)
        return Fixture(plan: plan, store: store, log: log, runner: CLIBlastSubmitRunner(cliURLOverride: cli))
    }

    private func begin(onCancel: (@Sendable () -> Void)? = nil) -> UUID {
        let row = OperationCenter.shared.begin(
            title: "BLAST quit versus cancel", detail: "Running", operationType: .blastVerification,
            cliCommand: "lungfish-cli blast submit", onCancel: onCancel
        ).rowID
        rows.append(row)
        return row
    }

    private func item(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    private func argv(_ fixture: Fixture) -> String {
        (try? String(contentsOf: fixture.log, encoding: .utf8)) ?? ""
    }

    /// A task that waits until it is cancelled and then settles the row, as a FASTA search's task does.
    private func settlingTask(for id: UUID) -> Task<Void, Never> {
        let gate = Gate()
        return Task { @MainActor in
            await gate.wait()
            OperationCenter.shared.acknowledgeCancellation(id: id)
        }
    }

    /// A viewer's run at work on the stand-in leaf. Its Cancel is the one `launchBlastSubmit` installs, wrapped so that
    /// the test can tell when OperationCenter's queue has run it.
    private func startViewerRun(_ fixture: Fixture) async throws -> (id: UUID, task: Task<Void, Never>, ran: Flag) {
        let id = begin()
        let task = ViewerViewController.launchBlastSubmit(
            fixture.plan, operationID: id, runner: fixture.runner,
            drawer: BlastSubmitDrawer(loading: { _ in }, results: { _, _ in }, failure: { _ in }),
            monitor: BlastInFlightMonitor(worker: BlastInFlightMonitor.Worker(
                lines: { _ in [] }, pass: { _, _, _ in .noNews(words: "") }, stop: { _ in }
            )),
            completeDetail: { _ in "done" }
        )
        let started = await waitUntil(timeout: WaitBudget.lookup.duration) { FileManager.default.fileExists(atPath: fixture.log.path) }
        XCTAssertTrue(started, "the leaf never started")
        let original = try XCTUnwrap(item(id)?.onCancel, "launchBlastSubmit installed no Cancel")
        let ran = Flag()
        OperationCenter.shared.setCancelCallback(for: id) {
            original()
            ran.set()
        }
        return (id, task, ran)
    }
}
