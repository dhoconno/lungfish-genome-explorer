// BlastPollWaitTests.swift - How long the service waits around each status check of one request
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.1 lane REOPEN, item 3. NCBI's developer page says "Do not poll for any single RID more often than once a
// minute." The wait before the first check stays NCBI's estimate, at least the service's minimum. The waits are
// recorded in place of being slept, so no test here waits for real.

import Foundation
import XCTest
@testable import LungfishCore

final class BlastPollWaitTests: XCTestCase {
    private static let waiting = "<!--QBlastInfoBegin\n    Status=WAITING\nQBlastInfoEnd-->"
    private static let waitingInQueue = "<!--QBlastInfoBegin\n    Status=WAITING\n    ThereAre = 7\nQBlastInfoEnd-->"
    private static let noStatus = "no status in this answer"
    private static let failed = "<!--QBlastInfoBegin\n    Status=FAILED\nQBlastInfoEnd-->"

    /// Thirteen checks, past the points where the wait used to widen, with each kind of answer that leads to a wait.
    func testPollWaitsAMinuteBetweenChecks() async throws {
        let answers = Array(repeating: Self.waiting, count: 10) + [Self.waitingInQueue, Self.noStatus, Self.failed]

        let run = try await runPoll(initialWait: 30, timeout: 600, answers: answers)

        XCTAssertEqual(run.waits, [30] + Array(repeating: 60, count: 12), "each check but the last is followed by 60 s")
        XCTAssertEqual(run.checks, 13)
    }

    func testTheFirstCheckStillWaitsForNCBIsEstimateAtLeastTheMinimum() async throws {
        let long = try await runPoll(initialWait: 45, timeout: 600, answers: [Self.failed])
        XCTAssertEqual(long.waits, [45], "a longer estimate is waited in full")

        let short = try await runPoll(initialWait: 3, timeout: 600, answers: [Self.failed])
        XCTAssertEqual(short.waits, [10], "a shorter estimate waits the minimum")
    }

    /// The limit is read before each check, so a run past it ends without asking NCBI again.
    func testACheckPastTheLimitStopsTheRunWithoutAskingAgain() async throws {
        let run = try await runPoll(initialWait: 30, timeout: 0, answers: [Self.waiting])

        XCTAssertEqual(run.checks, 0)
        XCTAssertTrue(run.timedOut, "the run ends as a timeout")
    }

    private func runPoll(
        initialWait: Int,
        timeout: TimeInterval,
        answers: [String]
    ) async throws -> (waits: [TimeInterval], checks: Int, timedOut: Bool) {
        let client = BlastScriptedStatusClient(answers: answers, last: Self.failed)
        let recorded = BlastRecordedWaits()
        var timedOut = false
        do {
            _ = try await BlastService(httpClient: client).pollForResults(
                rid: "POLL1", initialWait: initialWait, timeout: timeout, progress: nil,
                wait: { await recorded.add($0) }
            )
            XCTFail("every script ends without results")
        } catch let error as BlastServiceError {
            if case .timeout = error {
                timedOut = true
            } else if case .jobFailed = error {
                timedOut = false
            } else {
                XCTFail("unexpected error \(error)")
            }
        }
        let waits = await recorded.seconds
        let checks = await client.checks
        return (waits, checks, timedOut)
    }
}

/// Answers each status check with the next of `answers`, then with `last`, and counts the checks.
private actor BlastScriptedStatusClient: HTTPClient {
    private var answers: [String]
    private let last: String
    private(set) var checks = 0

    init(answers: [String], last: String) {
        self.answers = answers
        self.last = last
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        checks += 1
        let url = try XCTUnwrap(request.url)
        let answer = answers.isEmpty ? last : answers.removeFirst()
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))
        return (Data(answer.utf8), response)
    }
}

private actor BlastRecordedWaits {
    private(set) var seconds: [TimeInterval] = []

    func add(_ wait: TimeInterval) {
        seconds.append(wait)
    }
}
