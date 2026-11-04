// BlastSearchChildTests.swift - The built `blast submit` and `blast resume` on the BLAST fault stand-in
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
import XCTest

/// Phase 3.2 lane BLASTNET, milestone N2 (ARCH-BLAST-RESILIENCE section 5). A failed contact is no news, and only
/// NCBI's answer or the person ends a search. The child runs on a scaled clock, so 60 s of its time is 0.1 s of ours
/// and no real wait grows. A test holds a search by not releasing it, and nothing here reaches NCBI.
final class BlastSearchChildTests: XCTestCase {
    private static let fastClock = 600.0
    /// A copy goes at 3 s of ours, so a test that stops a child at its first check stops it before any copy.
    private static let beforeAnyCopyClock = 60.0
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-search-child-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var output: URL {
        scratch.appendingPathComponent("result", isDirectory: true)
    }

    private func environment(_ server: BlastFaultStandIn, scale: Double) -> [String: String] {
        [
            "LUNGFISH_BLAST_STAND_IN_ORIGIN": server.baseURL.absoluteString,
            "LUNGFISH_BLAST_STAND_IN_STATE": scratch.appendingPathComponent("state", isDirectory: true).path,
            "LUNGFISH_BLAST_STAND_IN_TIME_SCALE": String(scale),
        ]
    }

    private func submitArguments() throws -> [String] {
        let query = scratch.appendingPathComponent("query-from-viewer.fasta")
        try Data(">read_1\nACGTACGTAC\n>read_2\nGGCCTTAAGG\n".utf8).write(to: query)
        return ["blast", "submit", "--query", query.path, "--output", output.path, "--format", "json"]
    }

    /// The built CLI as a child. The limit is only a safety, and a passing run takes a few seconds.
    private func child(
        _ arguments: [String],
        server: BlastFaultStandIn,
        scale: Double = BlastSearchChildTests.fastClock
    ) throws -> ToolProcessSpec {
        let cli = try XCTUnwrap(CLISIGTERMHarness.cliBinaryURL(for: Self.self), "build lungfish-cli first")
        return ToolProcessSpec(
            executableURL: cli, arguments: arguments,
            environment: CLISIGTERMHarness.childEnvironment(overriding: environment(server, scale: scale)),
            timeout: .seconds(60)
        )
    }

    private func run(
        _ arguments: [String],
        server: BlastFaultStandIn,
        scale: Double = BlastSearchChildTests.fastClock
    ) async throws -> ToolProcessResult {
        try await ToolProcess.run(try child(arguments, server: server, scale: scale))
    }

    private func searchFile() throws -> [String: Any] {
        let data = try Data(contentsOf: output.appendingPathComponent("blast-search.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func firstCopy(of file: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap((file["copies"] as? [[String: Any]])?.first)
    }

    private func assertSavedResult(
        _ result: ToolProcessResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(result.status, 0, result.stderrText, file: file, line: line)
        let recordURL = output.appendingPathComponent("blast-result.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recordURL.path), "no record was saved", file: file, line: line)
        XCTAssertEqual(try searchFile()["state"] as? String, "done", file: file, line: line)
    }

    private func count(_ contact: BlastFaultContact, on server: BlastFaultStandIn) -> Int {
        server.arrivals.filter { $0.contact == contact }.count
    }

    // MARK: The file holds the search

    func testRidIsOnDiskBeforeTheFirstCheck() async throws {
        let server = try BlastFaultStandIn.start(scripts: [BlastFaultScript(search: .held)], timeScale: Self.fastClock)
        defer { server.stop() }
        let child = try CLISIGTERMHarness.launchCLI(
            try submitArguments(), environment: environment(server, scale: Self.fastClock), testClass: Self.self
        )
        defer { child.stop() }

        let checked = await server.waitForRequest(count: 1, of: .status)

        XCTAssertTrue(checked, "the leaf never checked its search")
        let copy = try firstCopy(of: try searchFile())
        XCTAssertEqual(copy["rid"] as? String, BlastFaultStandIn.rid(ofPut: 1), "the file names the RID when the first check goes out")
    }

    func testWaitingPastTenMinutesStaysWaiting() async throws {
        let scripts = Array(repeating: BlastFaultScript(search: .held), count: 3)
        let server = try BlastFaultStandIn.start(scripts: scripts, timeScale: Self.fastClock)
        defer { server.stop() }
        let spec = try child(try submitArguments(), server: server)
        async let finished = ToolProcess.run(spec)

        // Three sends make at most 24 checks by ten minutes, at one a minute each, so more can come only from past that age.
        let pastTheOldLimit = await server.waitForRequest(count: 30, of: .status)
        let arrivals = server.arrivals
        server.release(rid: BlastFaultStandIn.rid(ofPut: 1))
        let result = try await finished

        XCTAssertTrue(pastTheOldLimit, "the leaf stopped checking a search that NCBI still called WAITING")
        if let put = arrivals.first(where: { $0.contact == .put }), let last = arrivals.last {
            XCTAssertGreaterThan(last.at.timeIntervalSince(put.at), 600, "the last check came past the old 10-minute limit")
        }
        try assertSavedResult(result)
    }

    // MARK: A failed contact is no news

    func testStatus503FiveTimesThenReadyGivesAResult() async throws {
        // Every send meets the 503s, so the result can come only through them, whichever send wins.
        let server = try BlastFaultStandIn.start(
            scripts: Array(repeating: BlastFaultScript(status: Array(repeating: .http(status: 503), count: 5)), count: 3),
            timeScale: Self.fastClock
        )
        defer { server.stop() }

        let result = try await run(try submitArguments(), server: server)

        try assertSavedResult(result)
        XCTAssertGreaterThanOrEqual(count(.status, on: server), 6)
        XCTAssertLessThanOrEqual(count(.put, on: server), 3)
    }

    func testStatusConnectionLostThenReadyGivesAResult() async throws {
        // Every send meets the lost connections, so the result can come only through them, whichever send wins.
        let server = try BlastFaultStandIn.start(
            scripts: Array(repeating: BlastFaultScript(status: Array(repeating: .dropped, count: 12)), count: 3),
            timeScale: Self.fastClock
        )
        defer { server.stop() }

        let result = try await run(try submitArguments(), server: server)

        try assertSavedResult(result)
        XCTAssertLessThanOrEqual(count(.put, on: server), 3)
    }

    func testResultHTMLThenJSONGivesAResult() async throws {
        let server = try BlastFaultStandIn.start(scripts: [BlastFaultScript(result: [.html])], timeScale: Self.fastClock)
        defer { server.stop() }

        let result = try await run(try submitArguments(), server: server)

        try assertSavedResult(result)
        XCTAssertEqual(count(.result, on: server), 2, "one more fetch after a reply that could not be read")
    }

    func testResultDamagedZipThenJSONGivesAResult() async throws {
        let server = try BlastFaultStandIn.start(scripts: [BlastFaultScript(result: [.damagedZip])], timeScale: Self.fastClock)
        defer { server.stop() }

        let result = try await run(try submitArguments(), server: server)

        try assertSavedResult(result)
        XCTAssertEqual(count(.result, on: server), 2, "one more fetch after a damaged archive")
    }

    func testStatusUnknownInsideGraceKeepsPolling() async throws {
        let server = try BlastFaultStandIn.start(scripts: [BlastFaultScript(status: [.unknown])], timeScale: Self.fastClock)
        defer { server.stop() }

        let result = try await run(try submitArguments(), server: server)

        try assertSavedResult(result)
        XCTAssertEqual(count(.status, on: server), 2, "an early UNKNOWN is followed by another check")
    }

    func testStatusUnknownAfterGraceIsExpiredWithRid() async throws {
        // NCBI lets go of every send, since the search is expired only when no send is still alive.
        let server = try BlastFaultStandIn.start(
            scripts: Array(repeating: BlastFaultScript(search: .unknown(after: 400)), count: 3),
            timeScale: Self.fastClock
        )
        defer { server.stop() }

        let result = try await run(try submitArguments(), server: server)

        XCTAssertEqual(result.status, 1, result.stderrText)
        let file = try searchFile()
        let rid = BlastFaultStandIn.rid(ofPut: 1)
        XCTAssertEqual(file["state"] as? String, "expired")
        XCTAssertEqual(try firstCopy(of: file)["state"] as? String, "expired")
        XCTAssertEqual(try firstCopy(of: file)["rid"] as? String, rid)
        XCTAssertTrue(result.stdoutText.contains(#""event":"failed""#), result.stdoutText)
        XCTAssertTrue(result.stdoutText.contains(rid), "the words name the request ID: \(result.stdoutText)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("blast-result.json").path))
    }

    func testPutLostReplyDoesNotPostAgainWithinAMinute() async throws {
        // A slower clock than the others, since a one-second gap has to read as under a minute on this one.
        let scale = 20.0
        let server = try BlastFaultStandIn.start(scripts: [BlastFaultScript(put: [.droppedAfterSending])], timeScale: scale)
        defer { server.stop() }

        let result = try await run(try submitArguments(), server: server, scale: scale)

        try assertSavedResult(result)
        let posts = server.arrivals.filter { $0.contact == .put }
        XCTAssertEqual(posts.count, 2, "one re-POST and no more")
        if posts.count >= 2 {
            XCTAssertGreaterThanOrEqual(posts[1].at.timeIntervalSince(posts[0].at), 60, "a lost reply waits a minute before it sends again")
        }
    }

    // MARK: A resume

    func testResumeAfterAnInterruptedSwapFindsTheSearchOnExFAT() async throws {
        let server = try BlastFaultStandIn.start(scripts: [BlastFaultScript(search: .held)], timeScale: Self.beforeAnyCopyClock)
        defer { server.stop() }
        let child = try CLISIGTERMHarness.launchCLI(
            try submitArguments(), environment: environment(server, scale: Self.beforeAnyCopyClock), testClass: Self.self
        )
        defer { child.stop() }
        let checked = await server.waitForRequest(count: 1, of: .status)
        XCTAssertTrue(checked, "the leaf never checked its search")
        child.stop()

        // A crash between the renames of an ExFAT swap leaves the file under a tombstone and an empty file at its name.
        let name = output.appendingPathComponent("blast-search.json")
        try FileManager.default.moveItem(
            at: name, to: output.appendingPathComponent(".blast-search.json.lungfish-swap-\(UUID().uuidString)")
        )
        try Data().write(to: name)
        server.release(rid: BlastFaultStandIn.rid(ofPut: 1))

        let result = try await run(["blast", "resume", "--output", output.path, "--format", "json"], server: server, scale: Self.beforeAnyCopyClock)

        try assertSavedResult(result)
        XCTAssertEqual(count(.put, on: server), 1, "a resume sends nothing again")
        try BlastSubmitStandInTests.recaptureIfAsked("complete", stdout: result.stdoutText, scratch: scratch, command: "blast-resume")
    }

    func testAResumeOfAFolderWithNoSearchSaysSoAndContactsNothing() async throws {
        let server = try BlastFaultStandIn.start(timeScale: Self.fastClock)
        defer { server.stop() }

        let result = try await run(["blast", "resume", "--output", output.path, "--format", "json"], server: server)

        XCTAssertEqual(result.status, 3, result.stderrText)
        XCTAssertTrue(result.stdoutText.contains("No BLAST search is saved"), result.stdoutText)
        XCTAssertEqual(server.arrivals.count, 0)
        try BlastSubmitStandInTests.recaptureIfAsked("failed", stdout: result.stdoutText, scratch: scratch, command: "blast-resume")
    }

    func testASecondSubmitIntoALiveSearchIsRefused() async throws {
        let server = try BlastFaultStandIn.start(scripts: [BlastFaultScript(search: .held)], timeScale: Self.beforeAnyCopyClock)
        defer { server.stop() }
        let arguments = try submitArguments()
        let first = try CLISIGTERMHarness.launchCLI(
            arguments, environment: environment(server, scale: Self.beforeAnyCopyClock), testClass: Self.self
        )
        defer { first.stop() }
        let checked = await server.waitForRequest(count: 1, of: .status)
        XCTAssertTrue(checked, "the leaf never checked its search")
        first.stop()

        let second = try await run(arguments, server: server)

        XCTAssertEqual(second.status, 4, second.stderrText)
        XCTAssertTrue(second.stderrText.contains("blast resume"), second.stderrText)
        XCTAssertEqual(count(.put, on: server), 1, "a search in the folder is not sent over")
    }
}
