// BlastFaultStandInTests.swift - The BLAST fault stand-in does each fault it says it does
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane BLASTNET, N1 (ARCH-BLAST-RESILIENCE section 7). Every later milestone's test of a lost search rests on
// these faults, so each one is shown here on a real loopback connection, with the clock moved by hand where time counts.

import Foundation
import LungfishTestSupport
import XCTest

final class BlastFaultStandInTests: XCTestCase {
    private let session = URLSession(configuration: .ephemeral)

    override func tearDown() {
        session.invalidateAndCancel()
        super.tearDown()
    }

    private struct Reply {
        let status: Int
        let text: String
        let body: Data
    }

    private func contact(_ server: BlastFaultStandIn, _ query: String = "", post: Bool = false) async throws -> Reply {
        var request = URLRequest(url: URL(string: server.baseURL.absoluteString + "/blast/Blast.cgi" + query)!)
        if post {
            request.httpMethod = "POST"
            request.httpBody = Data("CMD=Put&QUERY=%3Eread_1%0AACGT".utf8)
        }
        let (data, response) = try await session.data(for: request)
        let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
        return Reply(status: status, text: String(decoding: data, as: UTF8.self), body: data)
    }

    private func put(_ server: BlastFaultStandIn) async throws -> Reply {
        try await contact(server, post: true)
    }

    private func status(_ server: BlastFaultStandIn, _ rid: String) async throws -> Reply {
        try await contact(server, "?CMD=Get&RID=\(rid)&FORMAT_OBJECT=SearchInfo")
    }

    private func fetch(_ server: BlastFaultStandIn, _ rid: String) async throws -> Reply {
        try await contact(server, "?CMD=Get&RID=\(rid)&FORMAT_TYPE=JSON2&FORMAT_OBJECT=Alignment")
    }

    func testASearchThatIsReadyAtOnceRunsFromPutToResult() async throws {
        let server = try BlastFaultStandIn.start(scripts: [BlastFaultScript(rtoe: 7, thereAreHits: true)])
        defer { server.stop() }

        let accepted = try await put(server)
        XCTAssertTrue(accepted.text.contains("RID = FAULT1"), accepted.text)
        XCTAssertTrue(accepted.text.contains("RTOE = 7"), accepted.text)

        let checked = try await status(server, "FAULT1")
        XCTAssertTrue(checked.text.contains("Status=READY"), checked.text)
        XCTAssertTrue(checked.text.contains("ThereAreHits=yes"), checked.text)

        let result = try await fetch(server, "FAULT1")
        XCTAssertEqual(result.body, BlastFaultScript.noHitsResult)
        XCTAssertEqual(server.arrivals.map(\.contact), [.put, .status, .result])
        XCTAssertEqual(server.arrivals.map(\.rid), ["FAULT1", "FAULT1", "FAULT1"])
    }

    /// One Put late by 90 s and one by hours, on a clock moved by hand, so no test waits for them.
    func testALateSearchWaitsOnTheStandInsClock() async throws {
        let hand = BlastHandClock()
        let server = try BlastFaultStandIn.start(
            scripts: [
                BlastFaultScript(search: .ready(after: 90)),
                BlastFaultScript(search: .ready(after: 4 * 3600)),
            ],
            now: { hand.now }
        )
        defer { server.stop() }
        _ = try await put(server)
        _ = try await put(server)

        hand.advance(by: 89)
        var late = try await status(server, "FAULT1")
        XCTAssertTrue(late.text.contains("Status=WAITING"), late.text)
        hand.advance(by: 1)
        late = try await status(server, "FAULT1")
        XCTAssertTrue(late.text.contains("Status=READY"), late.text)

        var hours = try await status(server, "FAULT2")
        XCTAssertTrue(hours.text.contains("Status=WAITING"), hours.text)
        hand.advance(by: 4 * 3600)
        hours = try await status(server, "FAULT2")
        XCTAssertTrue(hours.text.contains("Status=READY"), hours.text)
    }

    func testAHeldSearchWaitsUntilItIsReleased() async throws {
        let hand = BlastHandClock()
        let server = try BlastFaultStandIn.start(scripts: [BlastFaultScript(search: .held)], now: { hand.now })
        defer { server.stop() }
        _ = try await put(server)

        hand.advance(by: 100 * 3600)
        var held = try await status(server, "FAULT1")
        XCTAssertTrue(held.text.contains("Status=WAITING"), "no time ends a hold: \(held.text)")

        server.release(rid: "FAULT1")
        held = try await status(server, "FAULT1")
        XCTAssertTrue(held.text.contains("Status=READY"), held.text)
    }

    func testStatusFaultsComeFirstAndThenTheSearchsOwnAnswer() async throws {
        let server = try BlastFaultStandIn.start(scripts: [
            BlastFaultScript(status: [.http(status: 503), .http(status: 429), .noStatusLine, .emptyPage, .unknown])
        ])
        defer { server.stop() }
        _ = try await put(server)

        var reply = try await status(server, "FAULT1")
        XCTAssertEqual(reply.status, 503)
        reply = try await status(server, "FAULT1")
        XCTAssertEqual(reply.status, 429)
        reply = try await status(server, "FAULT1")
        XCTAssertEqual(reply.status, 200)
        XCTAssertFalse(reply.text.contains("Status"), reply.text)
        reply = try await status(server, "FAULT1")
        XCTAssertEqual(reply.body.count, 0)
        reply = try await status(server, "FAULT1")
        XCTAssertTrue(reply.text.contains("Status=UNKNOWN"), reply.text)
        reply = try await status(server, "FAULT1")
        XCTAssertTrue(reply.text.contains("Status=READY"), reply.text)
    }

    /// The URL loading system may repeat a dropped GET by itself, so this counts what reached the stand-in and what
    /// came back, and does not count how many tries a client needed.
    func testADroppedStatusConnectionGivesNoAnswer() async throws {
        let server = try BlastFaultStandIn.start(scripts: [BlastFaultScript(status: [.dropped])])
        defer { server.stop() }
        _ = try await put(server)

        var answer = try? await status(server, "FAULT1")
        if answer == nil { answer = try await status(server, "FAULT1") }

        XCTAssertTrue(try XCTUnwrap(answer).text.contains("Status=READY"), "the fault runs once, then the search answers")
        XCTAssertEqual(server.arrivals.count { $0.contact == .status }, 2, "one check dropped and one answered")
    }

    func testAnUnknownRidIsUnknownAndAnExpiredSearchTurnsUnknown() async throws {
        let hand = BlastHandClock()
        let server = try BlastFaultStandIn.start(
            scripts: [BlastFaultScript(search: .unknown(after: 300))], now: { hand.now })
        defer { server.stop() }
        _ = try await put(server)

        var reply = try await status(server, "FAULT1")
        XCTAssertTrue(reply.text.contains("Status=WAITING"), reply.text)
        hand.advance(by: 300)
        reply = try await status(server, "FAULT1")
        XCTAssertTrue(reply.text.contains("Status=UNKNOWN"), reply.text)
        reply = try await status(server, "NEVERSENT")
        XCTAssertTrue(reply.text.contains("Status=UNKNOWN"), reply.text)
    }

    func testAFailedSearchShowsNCBIsWords() async throws {
        let server = try BlastFaultStandIn.start(scripts: [
            BlastFaultScript(search: .failed(words: "Message ID#17 CPU usage limit was exceeded"))
        ])
        defer { server.stop() }
        _ = try await put(server)

        let reply = try await status(server, "FAULT1")

        XCTAssertTrue(reply.text.contains("Status=FAILED"), reply.text)
        XCTAssertTrue(reply.text.contains("CPU usage limit was exceeded"), reply.text)
    }

    func testResultFaultsComeInOrderAndThenTheResult() async throws {
        let tied = Data(#"{"tied": "this copy's record"}"#.utf8)
        let server = try BlastFaultStandIn.start(scripts: [
            BlastFaultScript(result: [.http(status: 503), .html, .empty, .damagedZip], body: tied)
        ])
        defer { server.stop() }
        _ = try await put(server)

        var reply = try await fetch(server, "FAULT1")
        XCTAssertEqual(reply.status, 503)
        reply = try await fetch(server, "FAULT1")
        XCTAssertTrue(reply.text.contains("<html>"), reply.text)
        reply = try await fetch(server, "FAULT1")
        XCTAssertEqual(reply.body.count, 0)
        reply = try await fetch(server, "FAULT1")
        XCTAssertEqual(reply.body, BlastFaultScript.damagedZip)
        reply = try await fetch(server, "FAULT1")
        XCTAssertEqual(reply.body, tied)
    }

    func testPutFaultsComeBeforeTheSearchIsAccepted() async throws {
        let server = try BlastFaultStandIn.start(scripts: [
            BlastFaultScript(put: [.http(status: 503), .noRID(page: "Query contains no data"), .droppedAfterSending])
        ])
        defer { server.stop() }

        var reply = try await put(server)
        XCTAssertEqual(reply.status, 503)
        reply = try await put(server)
        XCTAssertEqual(reply.status, 200)
        XCTAssertTrue(reply.text.contains("Query contains no data"), reply.text)
        XCTAssertFalse(reply.text.contains("RID"), reply.text)

        do {
            _ = try await put(server)
            XCTFail("a Put dropped after sending gets no answer")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        XCTAssertEqual(
            String(decoding: try XCTUnwrap(server.requests.last).body, as: UTF8.self),
            "CMD=Put&QUERY=%3Eread_1%0AACGT",
            "the stand-in read the whole Put before it dropped the connection"
        )

        reply = try await put(server)
        XCTAssertTrue(reply.text.contains("RID = FAULT1"), "the faults used no RID: \(reply.text)")
    }

    /// A copy gets its own RID and its own script, so two copies can name different tied records.
    func testEachPutRunsItsOwnScript() async throws {
        let first = Data(#"{"tied": "MN908947"}"#.utf8)
        let second = Data(#"{"tied": "OK091006"}"#.utf8)
        let server = try BlastFaultStandIn.start(scripts: [
            BlastFaultScript(search: .held, body: first),
            BlastFaultScript(body: second),
        ])
        defer { server.stop() }
        _ = try await put(server)
        _ = try await put(server)
        let pastTheScripts = try await put(server)

        let held = try await status(server, "FAULT1")
        XCTAssertTrue(held.text.contains("Status=WAITING"), held.text)
        let copy = try await status(server, "FAULT2")
        XCTAssertTrue(copy.text.contains("Status=READY"), copy.text)
        let result = try await fetch(server, "FAULT2")
        XCTAssertEqual(result.body, second)
        XCTAssertTrue(pastTheScripts.text.contains("RID = \(BlastFaultStandIn.rid(ofPut: 3))"), pastTheScripts.text)
    }

    func testWaitForRequestReturnsAsTheRequestArrives() async throws {
        let server = try BlastFaultStandIn.start()
        defer { server.stop() }

        async let waited = server.waitForRequest(count: 2)
        async let waitedForStatus = server.waitForRequest(count: 1, of: .status)
        _ = try await put(server)
        _ = try await status(server, "FAULT1")

        let reachedAll = await waited
        let reachedStatus = await waitedForStatus
        XCTAssertTrue(reachedAll)
        XCTAssertTrue(reachedStatus)
        let alreadyThere = await server.waitForRequest(count: 1, of: .put)
        XCTAssertTrue(alreadyThere, "a count already reached returns at once")
    }

    /// The one place a short deadline is the point: it shows a miss comes back as false.
    func testWaitForRequestReturnsFalseAtItsDeadline() async throws {
        let server = try BlastFaultStandIn.start()
        defer { server.stop() }

        let reached = await server.waitForRequest(count: 1, deadline: .milliseconds(50))

        XCTAssertFalse(reached)
    }

    func testStopEndsAWaitAsAMiss() async throws {
        let server = try BlastFaultStandIn.start()
        async let waited = server.waitForRequest(count: 1)
        server.stop()
        let reached = await waited
        XCTAssertFalse(reached)
    }

    func testTheStandInsClockCanRunAtTheChildsScale() async throws {
        let server = try BlastFaultStandIn.start(
            scripts: [BlastFaultScript(search: .ready(after: 3600))], timeScale: 1_000_000)
        defer { server.stop() }
        _ = try await put(server)
        let start = try XCTUnwrap(server.arrivals.first).at

        let answered = await waitUntil(budget: .lookup) {
            let reply = try? await self.status(server, "FAULT1")
            return reply?.text.contains("Status=READY") == true
        }

        XCTAssertTrue(answered)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(server.arrivals.last).at.timeIntervalSince(start), 3600)
    }
}
