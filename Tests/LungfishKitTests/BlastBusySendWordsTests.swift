// BlastBusySendWordsTests.swift - A send NCBI refuses says so, and says when LGE sends it again (Phase 3.2 lane S3BESIDE, BLAST-503-WORDS)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// W-5 of the 3.2 session 1 walk. While NCBI answered the first send with 503 and LGE sent it again, the Operations row and the
// BLAST pane read only "Sending 2 sequences to NCBI" and "You can keep working." for 8 minutes, with no word that NCBI was
// refusing and that LGE was trying again. These tests hold the send after a refusal and read the three places a person reads:
// the last progress report (the Operations row), the parked words (the in-flight line) and the pane body. The fault stand-in
// answers 503 on the first Puts and a hand clock holds every wait. Nothing contacts NCBI. The words are checked by meaning
// (that NCBI is refusing, and the clock time of LGE's next send), not as a whole sentence. No count, limit or timing moves.

import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishCore
@testable import LungfishKit

final class BlastBusySendWordsTests: XCTestCase {
    /// `ViewerViewController.blastFirstSendTakenFraction`, which the list pane reads. A refused send stays under it.
    private static let firstSendTaken = 0.20

    private var folder: URL!
    private let hand = BlastHandClock()
    private let reads: [(id: String, sequence: String)] = [(id: "read_1", sequence: "ACGTACGTAC"), (id: "read_2", sequence: "GGCCTTAAGG")]

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-busy-send-words-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(fraction: Double, message: String)] = []

        func add(_ fraction: Double, _ message: String) {
            lock.lock()
            defer { lock.unlock() }
            items.append((fraction, message))
        }

        var reports: [(fraction: Double, message: String)] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    /// What a person reads while a send is held, after `refusals` busy answers.
    private struct Held {
        var reports: [(fraction: Double, message: String)]
        var parked: String
        var pane: BlastSearchPaneState
        var nextSend: Date
    }

    private func makeAdvancer(_ server: BlastFaultStandIn, _ log: ProgressLog) -> BlastSearchAdvancer {
        BlastSearchAdvancer(
            service: BlastService(
                rateLimits: .ncbiDefault, searchShared: BlastSearchShared(searchLog: nil),
                environment: [BlastServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString]
            ),
            store: BlastSearchStore(folder: folder),
            request: BlastVerificationRequest(taxonName: "test", taxId: 0, sequences: reads),
            clock: hand.clock,
            noun: "sequences",
            progress: { log.add($0, $1) },
            publish: { _ in },
            pass: .once
        )
    }

    private func create(_ advancer: BlastSearchAdvancer) async throws -> BlastSearchFile {
        try await advancer.create(
            origin: .standIn,
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "digest", sequenceCount: reads.count),
            submitArgv: ["lungfish-cli", "blast", "submit"]
        )
    }

    /// One pass for each refusal. A pass sends what is due and parks, and the hand clock then moves to LGE's next send.
    private func hold(afterRefusals refusals: Int) async throws -> Held {
        let hand = hand
        let server = try BlastFaultStandIn.start(
            scripts: [BlastFaultScript(put: (0..<refusals).map { _ in .http(status: 503) })], now: { hand.now }
        )
        defer { server.stop() }
        let log = ProgressLog()
        let advancer = makeAdvancer(server, log)
        var file = try await create(advancer)
        var parked = ""
        for pass in 0..<refusals {
            if pass > 0, let due = file.copies[0].nextCheckAt { hand.advance(by: due.timeIntervalSince(hand.now)) }
            guard case .parked(let words) = try await advancer.advance(file) else {
                XCTFail("pass \(pass + 1) did not park after the refusal")
                break
            }
            parked = words
            file = try XCTUnwrap(BlastLiveSearch.read(folder: folder)).file
        }
        let live = try XCTUnwrap(BlastLiveSearch.read(folder: folder), "the search file is gone")
        let pane = try XCTUnwrap(BlastSearchPaneState.make(live, noun: "sequences", now: hand.now), "no pane state for a send in flight")
        let nextSend = try XCTUnwrap(live.file.copies[0].nextCheckAt, "the file holds no next send")
        return Held(reports: log.reports, parked: parked, pane: pane, nextSend: nextSend)
    }

    private func assertSaysNCBIIsRefusing(_ held: Held, file: StaticString = #filePath, line: UInt = #line) throws {
        let sendsAt = BlastSearchWords.time(held.nextSend, now: hand.now)
        let row = try XCTUnwrap(held.reports.last, "the advancer said nothing", file: file, line: line).message
        for (place, words) in [("the Operations row", row), ("the in-flight line", held.parked), ("the pane", held.pane.body)] {
            XCTAssertTrue(words.contains("not taking new searches"), "\(place) does not say that NCBI is refusing: \(words)", file: file, line: line)
            XCTAssertTrue(words.contains(sendsAt), "\(place) does not say when LGE sends again (\(sendsAt)): \(words)", file: file, line: line)
            for banned in ["failed", "error", "timed out", "retry", "polling", "attempt", "copy", "copies", "minutes"] {
                XCTAssertFalse(words.lowercased().contains(banned), "\(place) holds the word \(banned): \(words)", file: file, line: line)
            }
        }
        XCTAssertTrue(held.pane.body.contains("You can keep working."), "the pane no longer says the person can go on: \(held.pane.body)", file: file, line: line)
        XCTAssertEqual(held.pane.heading, "Sending sequences to NCBI", file: file, line: line)
        XCTAssertEqual(held.pane.buttons.map(\.title), ["Stop"], "the pane changed its buttons", file: file, line: line)
        for report in held.reports {
            XCTAssertLessThan(report.fraction, Self.firstSendTaken, "a report moved the pane past Submitting: \(report.message)", file: file, line: line)
        }
    }

    /// The walk: NCBI answers the first send with 503 and LGE waits to send it again.
    func testTheRowTheInFlightLineAndThePaneSayThatNCBIIsRefusingAndWhenLGESendsAgain() async throws {
        try assertSaysNCBIIsRefusing(try await hold(afterRefusals: 1))
    }

    /// The words follow the file, so the third wait names the third time and not the first.
    func testTheWordsNameTheNextSendAfterSeveralRefusals() async throws {
        try assertSaysNCBIIsRefusing(try await hold(afterRefusals: 3))
    }

    /// A send NCBI has not refused reads as it did, so the new words never say that NCBI refuses when it has not.
    func testASendNCBIHasNotRefusedKeepsTheWordsItHad() async throws {
        let hand = hand
        let server = try BlastFaultStandIn.start(scripts: [BlastFaultScript()], now: { hand.now })
        defer { server.stop() }
        let log = ProgressLog()
        let advancer = makeAdvancer(server, log)
        _ = try await create(advancer)

        let live = try XCTUnwrap(BlastLiveSearch.read(folder: folder), "the search file is gone")
        let pane = try XCTUnwrap(BlastSearchPaneState.make(live, noun: "sequences", now: hand.now), "no pane state for a send in flight")
        XCTAssertEqual(pane.heading, "Sending sequences to NCBI")
        XCTAssertEqual(pane.body, "You can keep working.")
    }
}
