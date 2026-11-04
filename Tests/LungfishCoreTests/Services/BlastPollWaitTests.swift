// BlastPollWaitTests.swift - How long a search waits around each status check of one request
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane REOPEN, item 3, moved to the advancer by Phase 3.2 lane BLASTNET N2. NCBI's developer page says "Do not
// poll for any single RID more often than once a minute." The wait before the first check stays NCBI's estimate, at
// least the service's minimum, and the waits then follow the search's age with no end while NCBI says WAITING. A hand
// clock records them in place of sleeping, so no test here waits for real. The test that a run past a limit stops
// asking NCBI retired with the limit, by the panel's decision under ARCH 7 (ARCH-BLAST-RESILIENCE, table of pins).

import Foundation
import LungfishTestSupport
import XCTest
@testable import LungfishCore

final class BlastPollWaitTests: XCTestCase {
    private static let waiting = "<!--QBlastInfoBegin\n    Status=WAITING\nQBlastInfoEnd-->"
    private static let waitingInQueue = "<!--QBlastInfoBegin\n    Status=WAITING\n    ThereAre = 7\nQBlastInfoEnd-->"
    private static let noStatus = "no status in this answer"
    private static let failed = "<!--QBlastInfoBegin\n    Status=FAILED\nQBlastInfoEnd-->"

    /// Twelve checks, with each kind of answer that leads to a wait. The check at 630 s is past 10 minutes of age.
    func testPollWaitsAMinuteBetweenChecksThenFollowsTheSearchsAge() async throws {
        let answers = Array(repeating: Self.waiting, count: 9) + [Self.waitingInQueue, Self.noStatus, Self.waiting, Self.failed]

        let run = try await runSearch(rtoe: 30, answers: answers)

        XCTAssertEqual(run.waits, [30] + Array(repeating: 60, count: 10) + [300, 300], "1 a minute to 10 min of age, then every 5")
        XCTAssertEqual(run.checks, 13)
    }

    func testTheFirstCheckStillWaitsForNCBIsEstimateAtLeastTheMinimum() async throws {
        let long = try await runSearch(rtoe: 45, answers: [Self.failed])
        XCTAssertEqual(long.waits, [45], "a longer estimate is waited in full")

        let short = try await runSearch(rtoe: 3, answers: [Self.failed])
        XCTAssertEqual(short.waits, [10], "a shorter estimate waits the minimum")
    }

    /// The schedule itself, item 12 of the ruling, with no end.
    func testTheCheckScheduleSlowsWithAgeAndHasNoEnd() {
        XCTAssertEqual(BlastSearchPolicy.checkInterval(atAge: 0), 60)
        XCTAssertEqual(BlastSearchPolicy.checkInterval(atAge: 599), 60)
        XCTAssertEqual(BlastSearchPolicy.checkInterval(atAge: 600), 300)
        XCTAssertEqual(BlastSearchPolicy.checkInterval(atAge: 3599), 300)
        XCTAssertEqual(BlastSearchPolicy.checkInterval(atAge: 3600), 900)
        XCTAssertEqual(BlastSearchPolicy.checkInterval(atAge: 21599), 900)
        XCTAssertEqual(BlastSearchPolicy.checkInterval(atAge: 21600), 1800)
        XCTAssertEqual(BlastSearchPolicy.checkInterval(atAge: 30 * 86400), 1800)
    }

    private func runSearch(rtoe: Int, answers: [String]) async throws -> (waits: [TimeInterval], checks: Int) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-poll-wait-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let hand = BlastHandClock(advancesBySleeping: true)
        let client = BlastScriptedStatusClient(rtoe: rtoe, answers: answers, last: Self.failed, waiting: Self.waiting, now: { hand.now })
        let request = BlastVerificationRequest(taxonName: "wait", taxId: 0, sequences: [(id: "read_1", sequence: "ACGT")])
        do {
            _ = try await BlastService(httpClient: client).verify(
                request: request, searchFolder: folder, submitArgv: [], clock: hand.clock, progress: nil
            )
            XCTFail("every script ends without results")
        } catch let error as BlastServiceError {
            guard case .searchEnded = error else { throw error }
        }
        return (await client.waitsOfTheFirstSend, await client.checksOfTheFirstSend.count)
    }
}

/// Accepts each Put with its own RID and follows the first send's checks by `answers`, then `last`, which every send
/// then reads, so the search ends. Until then a later send only waits, so the first send's schedule reads as it would alone.
private actor BlastScriptedStatusClient: HTTPClient {
    private let rtoe: Int
    private var answers: [String]
    private let last: String
    private let waiting: String
    private let now: @Sendable () -> Date
    private var posts = 0
    private var firstPostAt: Date?
    private(set) var checksOfTheFirstSend: [Date] = []

    init(rtoe: Int, answers: [String], last: String, waiting: String, now: @escaping @Sendable () -> Date) {
        self.rtoe = rtoe
        self.answers = answers
        self.last = last
        self.waiting = waiting
        self.now = now
    }

    /// The seconds before each of the first send's checks, from its Put on.
    var waitsOfTheFirstSend: [TimeInterval] {
        guard let firstPostAt else { return [] }
        return zip([firstPostAt] + checksOfTheFirstSend, checksOfTheFirstSend).map { (($1.timeIntervalSince($0)) * 1000).rounded() / 1000 }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try XCTUnwrap(request.url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
        if request.httpMethod == "POST" {
            posts += 1
            if posts == 1 { firstPostAt = now() }
            return (Data("<!--QBlastInfoBegin\n    RID = POLL\(posts)\n    RTOE = \(rtoe)\nQBlastInfoEnd-->".utf8), response)
        }
        guard url.query?.contains("RID=POLL1") == true else {
            return (Data((answers.isEmpty ? last : waiting).utf8), response)
        }
        guard !answers.isEmpty else { return (Data(last.utf8), response) }
        checksOfTheFirstSend.append(now())
        return (Data(answers.removeFirst().utf8), response)
    }
}
