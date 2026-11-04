// BlastRowWordsTests.swift - What a person reads of a BLAST search on its row and in the quit alert
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane BLASTCOLLECT (UX-BLAST-WORDS Q1, Q2 and Q3, NCBI-100-SEARCHES). Words are checked by meaning.

import AppKit
import Foundation
import XCTest
@testable import LungfishApp
import LungfishCore
import LungfishKit
import LungfishTestSupport

@MainActor
final class BlastRowWordsTests: XCTestCase {
    private var rows: [UUID] = []

    override func tearDown() async throws {
        for row in rows {
            OperationCenter.shared.cancel(id: row)
            OperationCenter.shared.clearItem(id: row)
        }
        rows = []
        try await super.tearDown()
    }

    private func begin(_ type: OperationType) -> UUID {
        let row = OperationCenter.shared.begin(title: "BLAST words \(type)", detail: "Running", operationType: type, cliCommand: "lungfish-cli test").rowID
        rows.append(row)
        return row
    }

    // MARK: - BLAST-PROGRESS-LABEL

    func testPollingMessageShowsTheWaitingPhase() {
        XCTAssertEqual(ViewerViewController.blastPhase(forProgressMessage: "Polling BLAST results (attempt 3)..."), .waiting)
        XCTAssertEqual(ViewerViewController.blastPhase(forProgressMessage: "NCBI has the search, request ID R1"), .waiting)
        XCTAssertEqual(ViewerViewController.blastPhase(forProgressMessage: "Sending 2 reads to NCBI"), .submitting)
        XCTAssertEqual(ViewerViewController.blastPhase(forProgressMessage: "Parsing the result"), .parsing)
    }

    // MARK: - BLAST-OPERATIONS-PAIR-DENOMINATOR

    func testOperationRowNamesFragmentsWhenPairsWereSent() {
        let pair = BlastReadResult(id: "pair", verdict: .verified, otherMates: [BlastReadResult(id: "pair/2", verdict: .verified)])
        let result = BlastVerificationResult(
            taxonName: "Taxon", taxId: 7, readResults: [pair], submittedAt: Date(), completedAt: Date(), rid: "RID",
            blastProgram: "blastn", database: "core_nt", databaseSequenceCount: nil
        )
        let words = blastVerificationCompletionDetail(result)
        XCTAssertTrue(words.hasSuffix("of 1 fragment (2 reads)"), words)
    }

    // MARK: - NCBI's 100 searches

    func testThePastOneHundredLineNamesASlowerQueueAndNoRefusal() {
        let words = BlastSearchWords.heldByTheDayCountLine
        XCTAssertTrue(words.contains("slower queue"), words)
        XCTAssertTrue(words.contains("extreme"), words)
        XCTAssertFalse(words.lowercased().contains("refus"), words)
    }

    // MARK: - The quit alert (UX-BLAST-WORDS Q3)

    private func waitingFile() -> BlastSearchFile {
        let request = BlastVerificationRequest(taxonName: "Taxon", taxId: 7, sequences: [(id: "read_1", sequence: "ACGT")], database: "core_nt")
        var file = BlastSearchFile(
            origin: .standIn, createdAt: Date(), submitArgv: [], facts: BlastSearchFile.Facts(request),
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "x", sequenceCount: 1), formSHA256: "x"
        )
        file.state = .waiting
        file.copies[0].rid = "RID-1"
        file.copies[0].state = .live
        return file
    }

    func testOnlyASavedSearchLeavesTheQuitListAndTheAlertSaysItStays() throws {
        let folder = try TestTempDirectory.make(prefix: "blast-quit-list")
        defer { TestTempDirectory.cleanup(folder) }
        let monitor = BlastInFlightMonitor(worker: BlastInFlightMonitor.Worker(
            lines: { _ in [] }, pass: { _, _, _ in .noNews(words: "") }, stop: { _ in }
        ))
        let blast = begin(.blastVerification)
        let export = begin(.export)
        let extracting = begin(.blastVerification)
        monitor.viewerRunBegan(output: folder, row: blast)

        XCTAssertTrue(monitor.quitList().map(\.id).contains(blast), "with nothing saved a quit would lose the search, so the alert names it")
        XCTAssertTrue(monitor.quitList().map(\.id).contains(extracting), "a BLAST row with no run yet has nothing to go on with")

        try BlastSearchStore(folder: folder).save(waitingFile())

        let list = monitor.quitList().map(\.id)
        XCTAssertFalse(list.contains(blast), "a quit leaves the saved search at NCBI or ready to send, so it cancels nothing")
        XCTAssertTrue(list.contains(export))
        XCTAssertTrue(monitor.isSavedSearch(row: blast))

        let alert = NSAlert()
        let live = LiveRunningOperationsAlert(alert: alert, kind: .quit) { monitor.quitList() }
        defer { live.stop() }
        XCTAssertTrue(
            alert.informativeText.contains("BLAST searches stay at NCBI. LGE checks them again when you next open LGE."),
            alert.informativeText
        )
    }

    /// UX-BLAST-WORDS, Every route, row Copied project.
    func testACopiedProjectsPaneSaysItWasSentFromAnotherCopy() throws {
        let folder = try TestTempDirectory.make(prefix: "blast-copied-pane")
        defer { TestTempDirectory.cleanup(folder) }
        let home = folder.appendingPathComponent("home", isDirectory: true)
        let copy = folder.appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let search = BlastLiveSearch(file: waitingFile(), folder: copy)

        let words = "This search was sent from another copy of this project, request ID RID-1. Choose Check Now to collect it here."
        let state = BlastSearchPaneState.make(search, noun: "reads", now: Date(), home: home.path)
        XCTAssertEqual(state?.body, words)
        XCTAssertEqual(state?.buttons.map(\.action), [.checkNow], "a copy only checks and fetches, and never sends")

        let itsOwnFolder = BlastSearchPaneState.make(search, noun: "reads", now: Date(), home: copy.path)
        XCTAssertNotEqual(itsOwnFolder?.body, words)
        let movedAway = BlastSearchPaneState.make(search, noun: "reads", now: Date(), home: folder.appendingPathComponent("gone").path)
        XCTAssertNotEqual(movedAway?.body, words, "a folder that has gone means this one moved, and it is no copy")
    }

    // MARK: - Relaunch (UX-BLAST-WORDS Q2)

    func testARowFoundAtLaunchLogsThatLGEOpenedAndCheckedIt() async throws {
        let folder = try TestTempDirectory.make(prefix: "blast-row-words")
        defer { TestTempDirectory.cleanup(folder) }
        let request = BlastVerificationRequest(taxonName: "Taxon", taxId: 7, sequences: [(id: "read_1", sequence: "ACGT")], database: "core_nt")
        var file = BlastSearchFile(
            origin: .standIn, createdAt: Date(), submitArgv: [], facts: BlastSearchFile.Facts(request),
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "x", sequenceCount: 1), formSHA256: "x"
        )
        file.state = .waiting
        file.copies[0].rid = "RID-1"
        file.copies[0].state = .live
        file.copies[0].nextCheckAt = Date(timeIntervalSinceNow: -1)
        let line = BlastInFlightLine(file, output: folder, words: "Waiting at NCBI", now: Date())
        let monitor = BlastInFlightMonitor(worker: BlastInFlightMonitor.Worker(
            lines: { _ in [line] }, pass: { _, _, _ in .waiting(words: "still waiting", state: .parked) }, stop: { _ in }
        ))

        await monitor.refresh()
        await monitor.passesFinished()
        await monitor.refresh()
        await monitor.passesFinished()

        let row = try XCTUnwrap(monitor.row(ofSearch: file.searchID))
        rows.append(row)
        let entries = OperationCenter.shared.items.first { $0.id == row }?.logEntries ?? []
        let said = entries.filter { $0.message.hasPrefix("LGE opened at ") && $0.message.hasSuffix(" and checked this search again.") }
        XCTAssertEqual(said.count, 1, "\(entries.map(\.message))")
    }
}
