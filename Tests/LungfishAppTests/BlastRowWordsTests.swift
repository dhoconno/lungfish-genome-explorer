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

    func testARunningBlastRowStaysOutOfTheQuitListAndTheAlertSaysItStays() {
        let blast = begin(.blastVerification)
        let export = begin(.export)
        let list = OperationCenter.shared.quitListItems.map(\.id)

        XCTAssertFalse(list.contains(blast), "a quit leaves the search at NCBI, so it cancels nothing")
        XCTAssertTrue(list.contains(export))

        let alert = NSAlert()
        let live = LiveRunningOperationsAlert(alert: alert, kind: .quit) { OperationCenter.shared.quitListItems }
        defer { live.stop() }
        XCTAssertTrue(
            alert.informativeText.contains("BLAST searches stay at NCBI. LGE checks them again when you next open LGE."),
            alert.informativeText
        )
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
