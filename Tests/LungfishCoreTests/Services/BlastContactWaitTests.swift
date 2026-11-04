// BlastContactWaitTests.swift - How long one contact can hold up a pass, and a person's press
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

@testable import LungfishCore
import LungfishTestSupport
import XCTest

/// Phase 3.2 lane BLASTCOLLECT, milestone C1. `waitsForConnectivity` sits out a session's whole resource limit on a
/// refused connection, as measured on this stand-in's port once it has stopped, so a pass that a launch runs for each
/// search must not wait on a fetch, and its check waits only as long as its own limit. Nothing here reaches NCBI.
final class BlastContactWaitTests: XCTestCase {
    private func refusedURL(_ query: String) throws -> URL {
        let server = try LoopbackHTTPStandIn.start { _ in .notFound }
        let base = server.baseURL
        server.stop()
        return try XCTUnwrap(URL(string: "\(base.absoluteString)/blast/Blast.cgi?\(query)"))
    }

    private func secondsToAnError(_ client: BlastHTTPClient, _ url: URL, method: String = "GET") async -> TimeInterval? {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let start = ContinuousClock.now
        do {
            _ = try await client.data(for: request)
            return nil
        } catch {
            let elapsed = start.duration(to: .now).components
            return Double(elapsed.seconds) + Double(elapsed.attoseconds) * 1e-18
        }
    }

    func testACheckOnARefusedConnectionWaitsOnlyToItsLimit() async throws {
        let limit: TimeInterval = 2
        let elapsed = await secondsToAnError(
            BlastHTTPClient(checkLimit: limit), try refusedURL("CMD=Get&RID=R&FORMAT_OBJECT=SearchInfo")
        )

        let seconds = try XCTUnwrap(elapsed, "a refused connection answered nothing")
        XCTAssertGreaterThanOrEqual(seconds, limit - 0.5, "a check waits for a connection, as section 5 says")
    }

    func testAFetchOnARefusedConnectionComesBackWithNoWait() async throws {
        // At the limit a check has, a fetch would still be sitting here. The real limit on a fetch is 600 s.
        let elapsed = await secondsToAnError(BlastHTTPClient(checkLimit: 60), try refusedURL("CMD=Get&RID=R&FORMAT_OBJECT=Alignment"))

        XCTAssertLessThan(try XCTUnwrap(elapsed), 30, "a fetch that reaches nothing goes again at the next tick")
    }

    func testAPostOnARefusedConnectionComesBackWithNoWait() async throws {
        let elapsed = await secondsToAnError(BlastHTTPClient(checkLimit: 60), try refusedURL(""), method: "POST")

        XCTAssertLessThan(try XCTUnwrap(elapsed), 30)
    }

    func testTheLimitOfACheckIsShorterThanTheTimeBetweenChecks() {
        XCTAssertLessThan(BlastSearchPolicy.checkResourceLimit, BlastSearchPolicy.checkFloor)
    }

    // MARK: A person's press

    private func searchFile(lastCheckAt: Date?, nextCheckAt: Date) -> BlastSearchFile {
        var file = BlastSearchFile(
            origin: .standIn,
            createdAt: Date(timeIntervalSince1970: 0),
            submitArgv: [],
            facts: BlastSearchFile.Facts(BlastVerificationRequest(taxonName: "T", taxId: 1, sequences: [(id: "r", sequence: "ACGT")])),
            query: BlastSubmissionRecord.Query(fileName: "query.fasta", sha256: "x", sequenceCount: 1),
            formSHA256: "y"
        )
        file.state = .waiting
        file.copies[0].state = .live
        file.copies[0].rid = "R1"
        file.copies[0].lastCheckAt = lastCheckAt
        file.copies[0].nextCheckAt = nextCheckAt
        return file
    }

    func testCheckNowKeepsTheMinuteFloor() {
        let now = Date(timeIntervalSince1970: 10_000)
        var checkedJustNow = searchFile(lastCheckAt: now.addingTimeInterval(-20), nextCheckAt: now.addingTimeInterval(900))
        checkedJustNow.checkNow(at: now)
        XCTAssertEqual(checkedJustNow.copies[0].nextCheckAt, now.addingTimeInterval(40), "NCBI asks for no more than one check a minute")

        var checkedLongAgo = searchFile(lastCheckAt: now.addingTimeInterval(-61), nextCheckAt: now.addingTimeInterval(900))
        checkedLongAgo.checkNow(at: now)
        XCTAssertEqual(checkedLongAgo.copies[0].nextCheckAt, now)

        var neverChecked = searchFile(lastCheckAt: nil, nextCheckAt: now.addingTimeInterval(900))
        neverChecked.checkNow(at: now)
        XCTAssertEqual(neverChecked.copies[0].nextCheckAt, now)
    }

    func testACopiedFolderHasNoPostToMake() {
        let now = Date(timeIntervalSince1970: 10_000)
        var file = searchFile(lastCheckAt: nil, nextCheckAt: now.addingTimeInterval(900))
        file.copies[0].postAt = Date(timeIntervalSince1970: 1)

        XCTAssertEqual(file.nextStep(now: now).step, .newCopy, "at this age a copy is overdue")
        XCTAssertEqual(file.nextStep(now: now, mayPost: false).step, .check(copy: 0), "a copied folder only checks")

        file.state = .sending
        XCTAssertEqual(file.nextStep(now: now, mayPost: false).step, .nothing, "and it never sends the first send")
    }

    func testTakingUpAStoppedSearchGoesBackToWhereItsSendsStand() {
        let now = Date(timeIntervalSince1970: 10_000)
        var file = searchFile(lastCheckAt: nil, nextCheckAt: now)
        file.state = .stopped
        file.ending = BlastSearchFile.Ending(state: .stopped, at: now, words: "Stopped.")

        file.takeUp()

        XCTAssertEqual(file.state, .waiting)
        XCTAssertNil(file.ending)
    }
}
