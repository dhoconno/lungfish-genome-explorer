// BlastContactGateTests.swift - The slot rule of the BLAST contact gate and the two limits of the ledger
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
@testable import LungfishCore

/// Phase 3.2 lane BLASTNET, milestone N3 (ARCH-BLAST-RESILIENCE items 8 and 9). The children in
/// `BlastContactGateChildTests` show two processes keep apart. Here a clock moved by hand shows the rule itself, so no
/// test spends a real slot.
final class BlastContactGateTests: XCTestCase {
    private final class Hand: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_800_000_000)
        private var spent: [TimeInterval] = []

        var now: Date { lock.withLock { current } }
        var sleeps: [TimeInterval] { lock.withLock { spent } }
        func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }

        func spend(_ seconds: TimeInterval) {
            lock.withLock {
                spent.append(seconds)
                current += seconds
            }
        }

        var clock: BlastSearchClock {
            BlastSearchClock(now: { self.now }, sleep: { self.spend($0) })
        }
    }

    private var folder: URL!
    private let hand = Hand()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-contact-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var file: URL {
        folder.appendingPathComponent(BlastContactGate.fileName)
    }

    private func gate(lockWait: TimeInterval = BlastSearchPolicy.gateLockWait) -> BlastContactGate {
        BlastContactGate(file: file, clock: hand.clock, lockWait: lockWait)
    }

    // MARK: The slot

    func testTwoGatesOnOneFileKeepElevenSecondsApart() async throws {
        let one = gate()
        let two = gate()

        try await one.takeSlot()
        try await two.takeSlot()
        try await one.takeSlot()

        XCTAssertEqual(hand.sleeps, [11, 11], "the first goes now, and each later one waits for its slot whichever gate it came through")
    }

    func testAContactPastTheLastSlotGoesAtOnce() async throws {
        let gate = gate()
        try await gate.takeSlot()
        hand.advance(100)

        try await gate.takeSlot()

        XCTAssertEqual(hand.sleeps, [])
    }

    func testALastSlotFarAheadReadsAsNow() async throws {
        // A clock moved back leaves a slot far ahead, and it must not hold a search up for its whole distance.
        try Data("\(hand.now.addingTimeInterval(601).timeIntervalSince1970)\n".utf8).write(to: file)
        try await gate().takeSlot()
        XCTAssertEqual(hand.sleeps, [11])
    }

    func testALastSlotAheadInsideTheLimitIsWaitedFor() async throws {
        try Data("\(hand.now.addingTimeInterval(599).timeIntervalSince1970)\n".utf8).write(to: file)
        try await gate().takeSlot()
        XCTAssertEqual(hand.sleeps, [610])
    }

    func testAValueThatCannotBeReadIsNoLastSlot() async throws {
        try Data("not a time".utf8).write(to: file)
        try await gate().takeSlot()
        XCTAssertEqual(hand.sleeps, [])
    }

    // MARK: The gate never ends a search

    func testALockThatCannotBeHadKeepsThisProcesssOwnSpacing() async throws {
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        let gate = gate(lockWait: 0.05)

        try await gate.takeSlot()
        try await gate.takeSlot()

        XCTAssertEqual(hand.sleeps, [11], "the gate went on and kept its own spacing")
        XCTAssertEqual(try Data(contentsOf: file), Data(), "only the lock's holder writes")
    }

    func testAFileThatCannotBeOpenedKeepsThisProcesssOwnSpacing() async throws {
        try Data().write(to: folder.appendingPathComponent("a-file"))
        let gate = BlastContactGate(file: folder.appendingPathComponent("a-file/contact-gate"), clock: hand.clock)

        try await gate.takeSlot()
        try await gate.takeSlot()

        XCTAssertEqual(hand.sleeps, [11])
    }

    func testACancelStopsTheWaitForTheLock() async throws {
        let descriptor = open(file.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        defer { close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX), 0)
        let gate = gate(lockWait: 30)

        let wait = Task { try await gate.takeSlot() }
        wait.cancel()

        do {
            try await wait.value
            XCTFail("a cancelled task does not go on to its contact")
        } catch is CancellationError {}
    }

    // MARK: The two limits

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testAFirstSendCountsOnlyFirstSendsAndACopyCountsEveryPost() throws {
        var events = [
            BlastSubmissionLedgerEvent(date: start, count: 40, kind: .first),
            BlastSubmissionLedgerEvent(date: start, count: 55, kind: .copy),
        ]

        XCTAssertNoThrow(try BlastSubmissionBudget.reserve(&events, count: 10, kind: .first, at: start, limit: 50), "a copy never refuses a first send")
        XCTAssertThrowsError(try BlastSubmissionBudget.reserve(&events, count: 1, kind: .first, at: start, limit: 50))
        XCTAssertThrowsError(try BlastSubmissionBudget.reserve(&events, count: 1, kind: .copy, at: start, limit: 100), "105 POSTed reads are past 100")
        XCTAssertEqual(events.map(\.kind), [.first, .copy, .first], "a refusal records nothing")
    }

    func testACopyFitsUnderEveryPostsLimit() throws {
        var events = [BlastSubmissionLedgerEvent(date: start, count: 80, kind: .first)]
        XCTAssertNoThrow(try BlastSubmissionBudget.reserve(&events, count: 20, kind: .copy, at: start, limit: 100))
    }

    func testAnEventOfAnOlderFileIsAFirstSend() async throws {
        let url = folder.appendingPathComponent(FileBlastSubmissionLedger.fileName)
        try Data(#"{"schemaVersion":1,"events":[{"date":"2027-01-15T08:00:00Z","count":3}]}"#.utf8).write(to: url)
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2027-01-15T08:01:00Z"))

        let events = await FileBlastSubmissionLedger(fileURL: url).events(at: now)

        XCTAssertEqual(events.map(\.kind), [.first])
        XCTAssertEqual(events.map(\.count), [3])
    }

    func testTheFitTimeIsWhenTheSearchFitsAndNotWhenTheOldestLeaves() throws {
        var events = [
            BlastSubmissionLedgerEvent(date: start, count: 10),
            BlastSubmissionLedgerEvent(date: start.addingTimeInterval(1800), count: 40),
        ]
        let asked = start.addingTimeInterval(2700)

        XCTAssertThrowsError(try BlastSubmissionBudget.reserve(&events, count: 20, at: asked, limit: 50)) { error in
            guard case BlastServiceError.rateLimitExceeded(let refusal) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(refusal.used, 50)
            XCTAssertEqual(refusal.retryAfter ?? 0, 2700, accuracy: 0.001, "not 900, when 20 reads still do not fit")
        }
    }

    func testASearchOverTheLimitHasNoFitTime() {
        var events: [BlastSubmissionLedgerEvent] = []
        XCTAssertThrowsError(try BlastSubmissionBudget.reserve(&events, count: 60, at: start, limit: 50)) { error in
            guard case BlastServiceError.rateLimitExceeded(let refusal) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertNil(refusal.fitsAt)
            XCTAssertNil(refusal.retryAfter)
        }
    }
}
