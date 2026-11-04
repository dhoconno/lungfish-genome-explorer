// BlastFastaCancelTests.swift - A FASTA row's Cancel stops its search, and the row says so
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLASTCOLLECT, gap 2 of C3 (UX-BLAST-WORDS Q3). The other seven viewers read `launchBlastSubmit`, whose Cancel runs
// `blast stop`. FASTA has its own task, and its Cancel was SIGTERM alone, so the row read Cancelled while the search went on
// and the monitor took it up at the next launch. A stand-in leaf answers, so nothing leaves this Mac.

import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishTestSupport
import LungfishWorkflow

@MainActor
final class BlastFastaCancelTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        try await super.setUp()
        folder = try TestTempDirectory.make(prefix: "blast-fasta-cancel")
        OperationCenter.useTemporaryFailureReportsForTesting()
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(folder)
        try await super.tearDown()
    }

    /// A FASTA row at work on a stand-in leaf, with its Cancel set as the row sets it.
    private func startRow() async throws -> (id: UUID, task: Task<Void, Never>, log: URL, store: BlastSearchStore) {
        let project = folder.appendingPathComponent("Project.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let plan = try BlastSubmitPlan.make(
            sequences: [(id: "read_1", sequence: "ACGTACGTACGTACGTACGT")], label: "FASTA fixture", projectURL: project
        )
        try FileManager.default.createDirectory(at: plan.request.outputURL, withIntermediateDirectories: true)
        let request = BlastVerificationRequest(
            taxonName: "FASTA fixture", taxId: 0, sequences: [(id: "read_1", sequence: "ACGT")], database: "core_nt"
        )
        var file = BlastSearchFile(
            origin: .standIn, createdAt: Date(), submitArgv: [], facts: BlastSearchFile.Facts(request),
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "x", sequenceCount: 1), formSHA256: "x"
        )
        file.state = .waiting
        file.copies[0].rid = "RID-FASTA"
        file.copies[0].state = .live
        let store = BlastSearchStore(folder: plan.request.outputURL)
        try store.save(file)

        let log = folder.appendingPathComponent("argv.log")
        let cli = folder.appendingPathComponent("lungfish-cli-fasta")
        let leaf = "#!/bin/bash\n/bin/echo \"$*\" >> '\(log.path)'\nif [ \"$2\" = stop ]; then\n"
            + "  /bin/echo '{\"event\":\"complete\",\"message\":\"stopped\",\"outputs\":[\"x\"],\"schemaVersion\":2}'\n  exit 0\nfi\nexec /bin/sleep 30\n"
        try leaf.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cli.path)

        let id = OperationCenter.shared.begin(
            title: "BLAST FASTA test", detail: "Running", operationType: .blastVerification, cliCommand: plan.cliCommand
        ).rowID
        let runner = CLIBlastSubmitRunner(cliURLOverride: cli)
        let search = ViewerViewController.fastaBlastRunner(plan: plan, operationID: id, override: nil, runner: runner)
        let task = Task { @MainActor in
            do {
                _ = try await search(request) { _, _ in }
            } catch is CancellationError {
                OperationCenter.shared.acknowledgeCancellation(id: id)
            } catch {
                XCTFail("the row read \(error)")
            }
        }
        ViewerViewController.setFASTABlastCancel(operationID: id, output: plan.request.outputURL, task: task, stopper: runner)
        let started = await waitUntil(timeout: WaitBudget.lookup.duration) { FileManager.default.fileExists(atPath: log.path) }
        XCTAssertTrue(started, "the leaf never started")
        return (id, task, log, store)
    }

    private func item(_ id: UUID) -> OperationCenter.Item? {
        OperationCenter.shared.items.first { $0.id == id }
    }

    /// A parked FASTA search shows waiting in its pane. A late result reaches the pane through the list's look-up of the picked
    /// sequences, which FASTACollectionSavedBlastTests reads.
    func testAParkedFastaSearchShowsWaitingInItsPane() async throws {
        let output = folder.appendingPathComponent("parked", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let request = BlastVerificationRequest(
            taxonName: "FASTA fixture", taxId: 0, sequences: [(id: "read_1", sequence: "ACGT")], database: "core_nt"
        )
        var file = BlastSearchFile(
            origin: .standIn, createdAt: Date(), submitArgv: [], facts: BlastSearchFile.Facts(request),
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "x", sequenceCount: 1), formSHA256: "x"
        )
        file.state = .waiting
        file.copies[0].rid = "RID-PARKED"
        file.copies[0].state = .live
        let store = BlastSearchStore(folder: output)
        try store.save(file)
        let fasta = FASTACollectionViewController()
        _ = fasta.view
        let id = OperationCenter.shared.begin(
            title: "BLAST FASTA parked", detail: "Running", operationType: .blastVerification, cliCommand: "lungfish-cli blast submit"
        ).rowID
        defer {
            OperationCenter.shared.cancel(id: id)
            OperationCenter.shared.acknowledgeCancellation(id: id)
            OperationCenter.shared.clearItem(id: id)
        }
        let monitor = BlastInFlightMonitor(worker: BlastInFlightMonitor.Worker(
            lines: { _ in [] }, pass: { _, _, _ in .noNews(words: "") }, stop: { _ in }
        ))

        await ViewerViewController.parkFASTABlastRow(
            id, BlastSubmitParked(words: "Still waiting at NCBI", output: output), controller: fasta, monitor: monitor
        )
        guard case .waiting = fasta.ensureBlastDrawer().displayState else {
            return XCTFail("the pane reads \(fasta.ensureBlastDrawer().displayState)")
        }
    }

    func testAPersonsCancelOfAFastaRowStopsTheSearchAndTheRowSaysSo() async throws {
        let row = try await startRow()
        defer { OperationCenter.shared.clearItem(id: row.id) }

        OperationCenter.shared.cancel(id: row.id)
        await row.task.value

        let stopped = await waitUntil(timeout: WaitBudget.lookup.duration) {
            ((try? String(contentsOf: row.log, encoding: .utf8)) ?? "").contains("blast stop --output")
        }
        XCTAssertTrue(stopped, "a person's Cancel runs blast stop, or the search goes on while the row reads Cancelled")
        XCTAssertEqual(item(row.id)?.state, .cancelled)
        let saysStopped = await waitUntil(timeout: WaitBudget.lookup.duration) { self.item(row.id)?.detail == BlastSearchWords.stopped }
        XCTAssertTrue(saysStopped, "the row reads \(item(row.id)?.detail ?? "nothing")")
    }

    func testQuitLeavesAFastaRowsSearchAtNCBI() async throws {
        let row = try await startRow()
        defer { OperationCenter.shared.clearItem(id: row.id) }

        OperationCenter.shared.cancelAll()
        await row.task.value

        let argv = try String(contentsOf: row.log, encoding: .utf8)
        XCTAssertFalse(argv.contains("blast stop"), argv)
        XCTAssertEqual(try row.store.load().state, .waiting, "a quit never writes stopped")
    }
}
