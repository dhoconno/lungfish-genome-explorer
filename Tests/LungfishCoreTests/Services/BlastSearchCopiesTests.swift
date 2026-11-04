// BlastSearchCopiesTests.swift - A stuck BLAST search sent again, on a clock moved by hand
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishTestSupport
import Synchronization
import XCTest
@testable import LungfishCore

/// Phase 3.2 lane BLASTNET N4 (ARCH-BLAST-RESILIENCE items 4 to 7, sections 2 and 3). A hand clock spends every wait at
/// once, so the times here are exact. `BlastCopiesChildTests` holds the named rows on the built leaf.
final class BlastSearchCopiesTests: XCTestCase {
    private var folder: URL!
    private let hand = BlastHandClock(advancesBySleeping: true)
    private let reads: [(id: String, sequence: String)] = [(id: "read_1", sequence: "ACGTACGTAC"), (id: "read_2", sequence: "GGCCTTAAGG")]
    private let said = SaidWords()

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-search-copies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func standIn(_ scripts: [BlastFaultScript]) throws -> BlastFaultStandIn {
        let hand = hand
        return try BlastFaultStandIn.start(scripts: scripts, now: { hand.now })
    }

    private func held(_ count: Int) -> [BlastFaultScript] {
        Array(repeating: BlastFaultScript(search: .held), count: count)
    }

    private func advancer(
        _ server: BlastFaultStandIn,
        shared: BlastSearchShared = BlastSearchShared(),
        ledger: any BlastSubmissionLedger = InMemoryBlastSubmissionLedger(),
        limits: BlastRateLimitConfiguration = .ncbiDefault
    ) -> BlastSearchAdvancer {
        let said = said
        return BlastSearchAdvancer(
            service: BlastService(
                rateLimits: limits, submissionLedger: ledger, searchShared: shared,
                environment: [BlastServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString]
            ),
            store: BlastSearchStore(folder: folder),
            request: BlastVerificationRequest(taxonName: "test", taxId: 0, sequences: reads),
            clock: hand.clock,
            noun: "sequences",
            progress: { _, words in said.append(words) },
            publish: { _ in }
        )
    }

    private func create(_ advancer: BlastSearchAdvancer) async throws -> BlastSearchFile {
        try await advancer.create(
            origin: .standIn,
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "digest", sequenceCount: reads.count),
            submitArgv: ["lungfish-cli", "blast", "submit"]
        )
    }

    private func onDisk() throws -> BlastSearchFile {
        try BlastSearchStore(folder: folder).load()
    }

    private func arrivalTimes(of contact: BlastFaultContact, on server: BlastFaultStandIn, since start: Date) -> [TimeInterval] {
        server.arrivals.filter { $0.contact == contact }.map { ($0.at.timeIntervalSince(start) * 1000).rounded() / 1000 }
    }

    /// Runs `advancer` until `server` has read `count` checks, then lets go of the first search, so a held search ends.
    private func run(
        _ advancer: BlastSearchAdvancer,
        from file: BlastSearchFile,
        on server: BlastFaultStandIn,
        releasingAfterChecks count: Int
    ) async throws -> BlastSearchOutcome {
        let released = Task {
            await server.waitForRequest(count: count, of: .status)
            server.release(rid: BlastFaultStandIn.rid(ofPut: 1))
        }
        defer { released.cancel() }
        return try await advancer.advance(file)
    }

    // MARK: The schedule

    func testCopiesGoAtThreeAndSixMinutes() async throws {
        let server = try standIn(held(3))
        defer { server.stop() }
        let advancer = advancer(server)
        let start = hand.now

        let file = try await create(advancer)
        _ = try await run(advancer, from: file, on: server, releasingAfterChecks: 12)

        XCTAssertEqual(arrivalTimes(of: .put, on: server, since: start), [0, 180, 360])
        let kept = try onDisk()
        XCTAssertEqual(kept.copies.map(\.kind), [.first, .copy, .copy])
        XCTAssertEqual(kept.copies.map(\.ordinal), [1, 2, 3])
        XCTAssertEqual(kept.copies.map(\.rid), [1, 2, 3].map { BlastFaultStandIn.rid(ofPut: $0) })
    }

    func testAFirstSendTakenLateWaitsThreeMinutesBeforeItsCopy() async throws {
        // Two busy answers put the accepted Put at 180 s, past the first copy's age.
        let server = try standIn([BlastFaultScript(put: [.http(status: 503), .http(status: 503)], search: .held)] + held(2))
        defer { server.stop() }
        let advancer = advancer(server)
        let start = hand.now

        let file = try await create(advancer)
        _ = try await run(advancer, from: file, on: server, releasingAfterChecks: 13)

        XCTAssertEqual(arrivalTimes(of: .put, on: server, since: start), [0, 60, 180, 360, 540], "one POST at a time, three minutes apart")
    }

    func testTwoCopiesReadyAtOneTickTakeTheEarlierPost() async throws {
        let server = try standIn([BlastFaultScript(), BlastFaultScript()])
        defer { server.stop() }
        let advancer = advancer(server)
        var file = try await create(advancer)
        // Two sends NCBI holds, both READY and both overdue, as after a sleep. The second came due first.
        let service = BlastService(environment: [BlastServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString])
        for _ in 1...2 { _ = try await service.sendPut(try BlastSearchStore(folder: folder).loadForm(), maxConcurrentSubmissions: 1) }
        file.state = .waiting
        file.copies[0].state = .live
        file.copies[0].rid = BlastFaultStandIn.rid(ofPut: 1)
        file.copies[0].postAt = hand.now
        file.copies[0].nextCheckAt = hand.now.addingTimeInterval(-60)
        var second = BlastSearchFile.Copy(ordinal: 2, kind: .copy, nextCheckAt: hand.now.addingTimeInterval(-120))
        second.state = .live
        second.rid = BlastFaultStandIn.rid(ofPut: 2)
        second.postAt = hand.now
        file.copies.append(second)

        let outcome = try await advancer.advance(file)

        guard case .done(let result) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(result.rid, BlastFaultStandIn.rid(ofPut: 1), "one copy's reply is judged alone, and the earlier POST takes a tie")
        XCTAssertEqual(try onDisk().winnerOrdinal, 1)
        XCTAssertEqual(server.arrivals.filter { $0.contact == .status }.map(\.rid), [BlastFaultStandIn.rid(ofPut: 1)])
    }

    // MARK: A send's ending

    func testAnExpiredSendEndsTheSearchOnlyWhenNoSendIsAlive() async throws {
        let server = try standIn(Array(repeating: BlastFaultScript(search: .unknown(after: 400)), count: 2) + [BlastFaultScript(search: .ready(after: 1200))])
        defer { server.stop() }
        let advancer = advancer(server)

        let outcome = try await advancer.advance(try await create(advancer))

        guard case .done(let result) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(result.rid, BlastFaultStandIn.rid(ofPut: 3))
        XCTAssertEqual(try onDisk().copies.map(\.state), [.expired, .expired, .ready])
        XCTAssertTrue(said.all.contains(BlastSearchWords.sendExpiredLine(rid: BlastFaultStandIn.rid(ofPut: 1), send: 1)))
    }

    func testAFailedBesideALiveSendGoesOnWithNoMoreCopies() async throws {
        let server = try standIn([BlastFaultScript(search: .ready(after: 900)), BlastFaultScript(search: .failed(words: "CPU usage limit was exceeded"))])
        defer { server.stop() }
        let advancer = advancer(server)

        let outcome = try await advancer.advance(try await create(advancer))

        guard case .done(let result) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(result.rid, BlastFaultStandIn.rid(ofPut: 1))
        let kept = try onDisk()
        XCTAssertEqual(kept.copies.map(\.state), [.ready, .failed])
        XCTAssertEqual(server.arrivals.filter { $0.contact == .put }.count, 2, "NCBI's failure may be about the query, so no more copies")
        XCTAssertFalse(kept.guardStruck, "a failure is an answer and not a stuck search")
    }

    func testALaterSendNCBIWillNotTakeLeavesTheSearchGoingOn() async throws {
        let refused = BlastFaultScript(put: Array(repeating: .http(status: 503), count: 4), search: .held)
        let server = try standIn([BlastFaultScript(search: .ready(after: 2000)), refused])
        defer { server.stop() }
        let advancer = advancer(server)

        let outcome = try await advancer.advance(try await create(advancer))

        guard case .done(let result) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(result.rid, BlastFaultStandIn.rid(ofPut: 1))
        XCTAssertEqual(try onDisk().copies.first { $0.ordinal == 2 }?.state, .notSent)
        XCTAssertTrue(said.all.contains(BlastSearchWords.laterSendNotTakenLine(send: 2)))
    }

    // MARK: Holds

    func testACopyPastTheHourlyLimitGoesOutWhenItFits() async throws {
        let ledger = InMemoryBlastSubmissionLedger()
        // Two reads a POST against a limit of three on POSTs: the first send fits and the copy waits for it to leave.
        let limits = BlastRateLimitConfiguration(maxSequencesPerHour: 50, maxPostedSequencesPerHour: 3)
        let server = try standIn(held(1))
        defer { server.stop() }
        let advancer = advancer(server, ledger: ledger, limits: limits)
        let start = hand.now

        let outcome = try await advancer.advance(try await create(advancer))

        guard case .done = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(arrivalTimes(of: .put, on: server, since: start), [0, 3600], "the copy goes when the first send's reads leave the hour")
        let lines = said.all.filter { $0.contains("LGE's hourly limit is full") }
        XCTAssertEqual(lines.count, 1, "one line for the change")
    }

    func testACopyTheLedgerRefusesGoesBackToTheGuard() async throws {
        let copyGuard = BlastCopyGuard()
        let limits = BlastRateLimitConfiguration(maxSequencesPerHour: 50, maxPostedSequencesPerHour: 3)
        let server = try standIn(held(1))
        defer { server.stop() }
        let advancer = advancer(server, shared: BlastSearchShared(copyGuard: copyGuard), limits: limits)

        _ = try await advancer.advance(try await create(advancer))

        let sends = await copyGuard.state().copySends
        XCTAssertEqual(sends.count, 1, "the ledger's refusals gave their copies back, and only the one that went counts")
    }

    func testTheDayCountHoldsACopyAndNotAFirstSend() async throws {
        let long = hand.now.addingTimeInterval(-7200)
        let ledger = InMemoryBlastSubmissionLedger(events: Array(repeating: BlastSubmissionLedgerEvent(date: long, count: 1), count: 150))
        let server = try standIn(held(1))
        defer { server.stop() }
        let advancer = advancer(server, ledger: ledger)
        let start = hand.now

        let file = try await create(advancer)
        let posted = await ledger.postsInTheLastDay(at: hand.now)
        XCTAssertEqual(posted, 151, "a rolling count of POSTs, the first send among them")
        // The 150 leave the day at 22 h, and no more than 100 are left from then on, so the copy goes at the next tick.
        let outcome = try await advancer.advance(file)

        guard case .done = outcome else { return XCTFail("\(outcome)") }
        let posts = arrivalTimes(of: .put, on: server, since: start)
        XCTAssertEqual(posts.first, 0)
        XCTAssertEqual(posts.count, 2)
        XCTAssertGreaterThanOrEqual(posts[1], 22 * 3600, "no copy while this Mac is past the line")
    }

    // MARK: The field log

    func testAnEndingWithNoResultLeavesItsLineAndNoReplyBytes() async throws {
        let log = BlastSearchLog(file: folder.appendingPathComponent(BlastSearchLog.fileName))
        let server = try standIn([BlastFaultScript(search: .failed(words: "CPU usage limit was exceeded"))])
        defer { server.stop() }
        let advancer = advancer(server, shared: BlastSearchShared(searchLog: log))

        _ = try await advancer.advance(try await create(advancer))

        let text = try String(contentsOf: folder.appendingPathComponent(BlastSearchLog.fileName), encoding: .utf8)
        let columns = try XCTUnwrap(text.split(separator: "\n").last).split(separator: "\t", omittingEmptySubsequences: false)
        XCTAssertEqual(columns[5], "ncbiFailed")
        XCTAssertEqual(columns[7], "")
    }

    // MARK: The words

    func testDurationsReadAsAPersonWritesThem() {
        XCTAssertEqual(BlastSearchWords.duration(12), "12 s")
        XCTAssertEqual(BlastSearchWords.duration(180), "3 min")
        XCTAssertEqual(BlastSearchWords.duration(252), "4 min 12 s")
        XCTAssertEqual(BlastSearchWords.duration(5 * 3600 + 180), "5 h 3 min")
        XCTAssertEqual(BlastSearchWords.duration(7200), "2 h")
    }

    func testAWaitingSearchsWordsHoldNoWordOfFailure() {
        let now = Date()
        let lines = [
            BlastSearchWords.firstSendLine(count: 1, noun: "reads", rid: "R"),
            BlastSearchWords.laterSendLine(after: 190, noun: "reads", rid: "R", send: 2),
            BlastSearchWords.allWaitingLine(sends: 3, after: 540, nextCheck: now, now: now),
            BlastSearchWords.heldByTheGuardLine(until: now, now: now),
            BlastSearchWords.heldByTheLimitLine(until: now, now: now),
            BlastSearchWords.heldByTheDayCountLine,
            BlastSearchWords.winLine(rid: "R", after: 200, send: 2, sends: 2),
            BlastSearchWords.sentAgain(sends: 2, lastChecked: now, now: now),
            BlastSearchWords.everySendWaiting(since: now, sends: 3, lastChecked: now, nextCheck: now, now: now),
            BlastSearchWords.guardHoldsLaterSends(since: now, sends: 3, until: now, nextCheck: now, now: now),
            BlastSearchWords.laterSendNotTakenLine(send: 2),
        ]
        for line in lines {
            for word in ["failed", "error", "timed out", "retry", "polling", "attempt", "copy"] {
                XCTAssertFalse(line.lowercased().contains(word), "\(word) in: \(line)")
            }
        }
        XCTAssertTrue(lines[0].contains("Sent 1 read to NCBI, request ID R. LGE may send it again, at most three sends in all."), lines[0])
        XCTAssertTrue(lines[1].contains("send 2 of 3"), lines[1])
    }
}

/// What a search said, for a test to read.
private final class SaidWords: Sendable {
    private let lines = Mutex<[String]>([])

    var all: [String] {
        lines.withLock { $0 }
    }

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }
}

/// The guard's rule and its file, with no search around them.
final class BlastCopyGuardTests: XCTestCase {
    private var folder: URL!
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-copy-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private var file: URL {
        folder.appendingPathComponent(BlastCopyGuard.fileName)
    }

    func testAtMostFourCopiesInARollingHourAcrossTwoGuardsOnOneFile() async {
        let (first, second) = (BlastCopyGuard(file: file), BlastCopyGuard(file: file))

        for (index, keeper) in [first, second, first, second].enumerated() {
            let answer = await keeper.takeCopy(at: start.addingTimeInterval(Double(index) * 60))
            XCTAssertEqual(answer, .granted)
        }

        let full = await first.takeCopy(at: start.addingTimeInterval(240))
        XCTAssertEqual(full, .capFull(until: start.addingTimeInterval(3600)), "the next goes when the oldest leaves the hour")
        let later = await second.takeCopy(at: start.addingTimeInterval(3600))
        XCTAssertEqual(later, .granted)
    }

    func testAGivenBackCopyCountsForNothing() async {
        let keeper = BlastCopyGuard(file: file)
        for index in 0..<4 { _ = await keeper.takeCopy(at: start.addingTimeInterval(Double(index))) }

        await keeper.giveBack(takenAt: start.addingTimeInterval(3))

        let again = await keeper.takeCopy(at: start.addingTimeInterval(10))
        XCTAssertEqual(again, .granted)
    }

    func testTwoSpentInARowPauseAndACameBackBetweenResets() async {
        let keeper = BlastCopyGuard(file: file)

        await keeper.searchWasSpent(at: start)
        await keeper.searchCameBackInTime()
        await keeper.searchWasSpent(at: start)
        let notYet = await keeper.takeCopy(at: start)
        XCTAssertEqual(notYet, .granted, "one came back between, so these are not two in a row")

        await keeper.searchWasSpent(at: start.addingTimeInterval(1))
        let until = start.addingTimeInterval(3601)
        let paused = await BlastCopyGuard(file: file).takeCopy(at: start.addingTimeInterval(2))
        XCTAssertEqual(paused, .paused(until: until), "another process reads the pause")
        let over = await keeper.takeCopy(at: until)
        XCTAssertEqual(over, .granted, "a copy held goes out when the pause ends")
    }

    func testAFileThatCannotBeReadCountsAsNoPause() async throws {
        try Data("not json".utf8).write(to: file)

        let answer = await BlastCopyGuard(file: file).takeCopy(at: start)

        XCTAssertEqual(answer, .granted)
        let healed = try BlastSubmissionRecord.decoder.decode(BlastCopyGuard.State.self, from: Data(contentsOf: file))
        XCTAssertEqual(healed.copySends.count, 1, "the file is written again")
    }

    func testAPauseOfAClockMovedBackReadsAsOver() async {
        let keeper = BlastCopyGuard(file: file)
        await keeper.searchWasSpent(at: start)
        await keeper.searchWasSpent(at: start)

        let answer = await keeper.takeCopy(at: start.addingTimeInterval(-86400))

        XCTAssertEqual(answer, .granted)
    }

    func testAGuardWhoseLockIsHeldGoesOnAlone() async throws {
        let lockFile = file.appendingPathExtension("lock")
        let holder = open(lockFile.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        XCTAssertGreaterThanOrEqual(holder, 0)
        XCTAssertEqual(flock(holder, LOCK_EX), 0)
        defer {
            flock(holder, LOCK_UN)
            close(holder)
        }

        let answer = await BlastCopyGuard(file: file, lockWait: 0).takeCopy(at: start)

        XCTAssertEqual(answer, .granted, "a storage fault must not stop a rescue")
    }
}

/// The ledger's rolling day beside its rolling hour.
final class BlastDayCountTests: XCTestCase {
    func testTheLedgerKeepsADayOfPostsAndTheHourlyLimitStillReadsAnHour() async throws {
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let ledger = InMemoryBlastSubmissionLedger()
        try await ledger.reserve(count: 50, kind: .first, at: start, limit: 50)
        try await ledger.reserve(count: 50, kind: .first, at: start.addingTimeInterval(3600), limit: 50)

        let hourly = await ledger.events(at: start.addingTimeInterval(3600))
        XCTAssertEqual(hourly.count, 1, "the older POST has left the hour")
        let inTheDay = await ledger.postsInTheLastDay(at: start.addingTimeInterval(3600))
        XCTAssertEqual(inTheDay, 2)
        let dayLater = await ledger.postsInTheLastDay(at: start.addingTimeInterval(86400))
        XCTAssertEqual(dayLater, 1, "the older POST has left the day")
    }

    func testAFileLedgerCountsTheDayAcrossProcesses() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blast-day-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(FileBlastSubmissionLedger.fileName)
        let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

        try await FileBlastSubmissionLedger(fileURL: url).reserve(count: 1, kind: .first, at: start, limit: 50)
        try await FileBlastSubmissionLedger(fileURL: url).reserve(count: 1, kind: .copy, at: start.addingTimeInterval(7200), limit: 100)

        let counted = await FileBlastSubmissionLedger(fileURL: url).postsInTheLastDay(at: start.addingTimeInterval(7200))
        XCTAssertEqual(counted, 2)
    }
}
