// BlastCopiesChildTests.swift - The built `blast submit` sending a stuck search again, with the guard across processes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
import XCTest

/// Phase 3.2 lane BLASTNET, milestone N4 (ARCH-BLAST-RESILIENCE items 4 to 7, sections 2 and 3, UX-BLAST-WORDS Q2 and
/// Q5). A test holds a search by not releasing it, children on one state folder share the guard and the ledger as two
/// processes on one Mac share `<root>/blast/`, and nothing here reaches NCBI. A scaled clock spends every wait, so
/// 180 s is 0.3 s at 600 times. Each wait below ends when its request arrives.
final class BlastCopiesChildTests: XCTestCase {
    private static let fastClock = 600.0
    /// Past this many checks a search is older than ten minutes, since three sends make at most 24 by then.
    private static let checksPastEveryCopy = 30
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-copies-child-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var state: URL {
        scratch.appendingPathComponent("state", isDirectory: true)
    }

    private var guardFile: URL {
        state.appendingPathComponent("copy-guard.json")
    }

    private var ledgerFile: URL {
        state.appendingPathComponent("submission-ledger.json")
    }

    private func output(_ name: String = "result") -> URL {
        scratch.appendingPathComponent(name, isDirectory: true)
    }

    private func rid(_ ordinal: Int) -> String {
        BlastFaultStandIn.rid(ofPut: ordinal)
    }

    private func held(_ count: Int) -> [BlastFaultScript] {
        Array(repeating: BlastFaultScript(search: .held), count: count)
    }

    private func submit(into name: String = "result") throws -> [String] {
        let query = scratch.appendingPathComponent("query-\(name).fasta")
        try Data(">read_1\nACGTACGTAC\n>read_2\nGGCCTTAAGG\n".utf8).write(to: query)
        return ["blast", "submit", "--query", query.path, "--output", output(name).path, "--format", "json", "--name", "SecretLabel"]
    }

    private func environment(_ server: BlastFaultStandIn, scale: Double) -> [String: String] {
        [
            "LUNGFISH_BLAST_STAND_IN_ORIGIN": server.baseURL.absoluteString,
            "LUNGFISH_BLAST_STAND_IN_STATE": state.path,
            "LUNGFISH_BLAST_STAND_IN_TIME_SCALE": String(scale),
        ]
    }

    private func child(_ arguments: [String], server: BlastFaultStandIn, scale: Double = fastClock) throws -> ToolProcessSpec {
        let cli = try XCTUnwrap(CLISIGTERMHarness.cliBinaryURL(for: Self.self), "build lungfish-cli first")
        return ToolProcessSpec(
            executableURL: cli, arguments: arguments,
            environment: CLISIGTERMHarness.childEnvironment(overriding: environment(server, scale: scale)),
            timeout: .seconds(60)
        )
    }

    /// Runs a child until the stand-in has read `count` Puts in all. A miss releases every search, so the child ends.
    private func finish(
        _ spec: ToolProcessSpec,
        whenPutsReach count: Int,
        on server: BlastFaultStandIn,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> ToolProcessResult {
        async let finished = ToolProcess.run(spec)
        let reached = await server.waitForRequest(count: count, of: .put)
        if !reached { for ordinal in 1...count { server.release(rid: rid(ordinal)) } }
        let result = try await finished
        XCTAssertTrue(reached, "the stand-in read \(puts(on: server).count) Puts of \(count)", file: file, line: line)
        return result
    }

    private func puts(on server: BlastFaultStandIn) -> [BlastFaultArrival] {
        server.arrivals.filter { $0.contact == .put }
    }

    private func checks(on server: BlastFaultStandIn) -> Int {
        server.arrivals.filter { $0.contact == .status }.count
    }

    private func said(by result: ToolProcessResult) -> String {
        result.stdoutText + result.stderrText
    }

    private func json(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func searchFile(_ name: String = "result") throws -> [String: Any] {
        try json(output(name).appendingPathComponent("blast-search.json"))
    }

    private func copies(of file: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(file["copies"] as? [[String: Any]])
    }

    /// The guard file, or nil while no process has written one, which is no failure in itself.
    private func guardContents() -> [String: Any]? {
        guard let data = try? Data(contentsOf: guardFile) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Writes the guard file as a process that struck it would have.
    private func writeGuard(pausedUntil: Date) throws {
        let row: [String: Any] = [
            "schemaVersion": 1, "spentInARow": 0, "copySends": [String](),
            "pausedUntil": ISO8601DateFormatter().string(from: pausedUntil),
        ]
        try JSONSerialization.data(withJSONObject: row).write(to: guardFile)
    }

    /// Writes a ledger of `count` one-read first sends at `date`.
    private func writeLedger(_ count: Int, at date: Date) throws {
        let event: [String: Any] = ["date": ISO8601DateFormatter().string(from: date), "count": 1, "kind": "first"]
        let document: [String: Any] = ["schemaVersion": 1, "events": Array(repeating: event, count: count)]
        try JSONSerialization.data(withJSONObject: document).write(to: ledgerFile)
    }

    private func ledgerEvents() throws -> [[String: Any]] {
        try XCTUnwrap(try json(ledgerFile)["events"] as? [[String: Any]])
    }

    private func searchClock(scale: Double) -> BlastSearchClock {
        .scaled(scale, anchor: BlastStandInState.clockAnchor(in: state))
    }

    // MARK: The copies

    func testAHeldSearchIsSentAgainAtThreeMinutes() async throws {
        let server = try BlastFaultStandIn.start(scripts: held(1), timeScale: Self.fastClock)
        defer { server.stop() }

        let result = try await finish(try child(try submit(), server: server), whenPutsReach: 2, on: server)

        XCTAssertEqual(result.status, 0, said(by: result))
        let posts = puts(on: server)
        XCTAssertEqual(posts.count, 2, "the copy came back, so nothing more went out")
        if posts.count == 2 {
            XCTAssertGreaterThanOrEqual(posts[1].at.timeIntervalSince(posts[0].at), 180, "a copy waits three minutes")
        }
        XCTAssertTrue(said(by: result).contains("so LGE sent the same sequences again, request ID \(rid(2)), send 2 of 3. The first answer counts."), said(by: result))
    }

    func testFirstReadyWinsAndNoOtherCopyIsCheckedAgain() async throws {
        let server = try BlastFaultStandIn.start(scripts: held(1) + [BlastFaultScript()], timeScale: Self.fastClock)
        defer { server.stop() }

        let result = try await finish(try child(try submit(), server: server), whenPutsReach: 2, on: server)

        XCTAssertEqual(result.status, 0, said(by: result))
        XCTAssertEqual(try searchFile()["winnerOrdinal"] as? Int, 2)
        let record = try json(output().appendingPathComponent("blast-result.json"))
        XCTAssertEqual((record["result"] as? [String: Any])?["rid"] as? String, rid(2), "the record's request ID is the winner's")
        let arrivals = server.arrivals
        let lastCheckOfTheWinner = try XCTUnwrap(arrivals.lastIndex { $0.contact == .status && $0.rid == rid(2) })
        XCTAssertFalse(arrivals[lastCheckOfTheWinner...].dropFirst().contains { $0.contact == .status }, "\(arrivals)")
        XCTAssertEqual(arrivals.filter { $0.contact == .result }.map(\.rid), [rid(2)], "only the winner is fetched")
    }

    func testACopyPostsTheFirstSendsBytes() async throws {
        let server = try BlastFaultStandIn.start(scripts: held(3), timeScale: Self.fastClock)
        defer { server.stop() }
        let spec = try child(try submit(), server: server)
        async let finished = ToolProcess.run(spec)

        let allSent = await server.waitForRequest(count: 3, of: .put)
        server.release(rid: rid(1))
        let result = try await finished

        XCTAssertTrue(allSent, "three sends in all")
        XCTAssertEqual(result.status, 0, said(by: result))
        let form = try Data(contentsOf: output().appendingPathComponent("put-form.txt"))
        let bodies = server.requests.filter { $0.method == "POST" }.map(\.body)
        XCTAssertEqual(bodies.count, 3)
        for body in bodies { XCTAssertEqual(body, form, "every POST is the saved form, byte for byte") }
    }

    func testAtMostThreeCopies() async throws {
        let server = try BlastFaultStandIn.start(scripts: held(6), timeScale: Self.fastClock)
        defer { server.stop() }
        let spec = try child(try submit(), server: server)
        async let finished = ToolProcess.run(spec)

        let pastEveryCopy = await server.waitForRequest(count: Self.checksPastEveryCopy, of: .status)
        let posts = puts(on: server).count
        server.release(rid: rid(1))
        let result = try await finished

        XCTAssertTrue(pastEveryCopy, "the leaf stopped checking")
        XCTAssertEqual(posts, 3, "three sends in all, the first and two more")
        XCTAssertEqual(result.status, 0, said(by: result))
        let file = try searchFile()
        XCTAssertEqual(try copies(of: file).map { $0["kind"] as? String }, ["first", "copy", "copy"])
        XCTAssertNotNil(file["spentAt"], "the third send has been out three minutes")
    }

    // MARK: The guard

    func testTwoSpentSearchesPauseCopiesAcrossProcesses() async throws {
        let scale = 60.0
        let server = try BlastFaultStandIn.start(scripts: held(7), timeScale: scale)
        defer { server.stop() }
        let first = try CLISIGTERMHarness.launchCLI(try submit(into: "first"), environment: environment(server, scale: scale), testClass: Self.self)
        defer { first.stop() }
        let second = try CLISIGTERMHarness.launchCLI(try submit(into: "second"), environment: environment(server, scale: scale), testClass: Self.self)
        defer { second.stop() }

        let paused = await waitUntil(budget: .lookup, pollInterval: .milliseconds(50)) {
            ((guardContents())?["pausedUntil"]) != nil
        }
        first.stop()
        second.stop()
        guard paused else { return XCTFail("two spent searches set no pause") }
        XCTAssertEqual(puts(on: server).count, 6)

        let checked = checks(on: server)
        let spec = try child(try submit(into: "third"), server: server, scale: scale)
        async let finished = ToolProcess.run(spec)
        // A third process's checks at 10, 70, 130, 190 and 250 s take it past the age of its first copy.
        let pastThreeMinutes = await server.waitForRequest(count: checked + 5, of: .status)
        let posts = puts(on: server).count
        server.release(rid: rid(7))
        let result = try await finished

        XCTAssertTrue(pastThreeMinutes, "the third search stopped checking")
        XCTAssertEqual(posts, 7, "the pause holds the third search's copies")
        XCTAssertEqual(result.status, 0, said(by: result))
        XCTAssertTrue(said(by: result).contains("LGE did not send this search again, because the last 2 searches got stuck at NCBI. It sends nothing again before "), said(by: result))
    }

    func testFourCopiesAnHourAcrossProcesses() async throws {
        let scale = 120.0
        let ready = BlastFaultScript()
        let scripts = held(2) + [ready] + held(2) + [ready] + held(1)
        let server = try BlastFaultStandIn.start(scripts: scripts, timeScale: scale)
        defer { server.stop() }

        for (name, posts) in [("first", 3), ("second", 6)] {
            let result = try await finish(try child(try submit(into: name), server: server, scale: scale), whenPutsReach: posts, on: server)
            XCTAssertEqual(result.status, 0, said(by: result))
        }

        let checked = checks(on: server)
        let spec = try child(try submit(into: "third"), server: server, scale: scale)
        async let finished = ToolProcess.run(spec)
        let pastThreeMinutes = await server.waitForRequest(count: checked + 5, of: .status)
        let posts = puts(on: server).count
        server.release(rid: rid(7))
        let result = try await finished

        XCTAssertTrue(pastThreeMinutes, "the third search stopped checking")
        XCTAssertEqual(posts, 7, "four copies have gone in this hour")
        XCTAssertEqual(result.status, 0, said(by: result))
        XCTAssertTrue(said(by: result).contains("LGE did not send this search again, because LGE's hourly limit is full. It can send again at "), said(by: result))
        XCTAssertTrue(said(by: result).contains("NCBI was not contacted."), said(by: result))
    }

    func testAHeldCopyGoesOutWhenThePauseEnds() async throws {
        let scale = 240.0
        let pausedUntil = searchClock(scale: scale).now().addingTimeInterval(1200)
        try writeGuard(pausedUntil: pausedUntil)
        let server = try BlastFaultStandIn.start(scripts: held(1), timeScale: scale)
        defer { server.stop() }

        let result = try await finish(try child(try submit(), server: server, scale: scale), whenPutsReach: 2, on: server)

        XCTAssertEqual(result.status, 0, said(by: result))
        XCTAssertEqual(try searchFile()["state"] as? String, "done", "a hold never ends a search")
        let sentAt = try XCTUnwrap(try copies(of: try searchFile()).last?["postAt"] as? String)
        let date = try XCTUnwrap(ISO8601DateFormatter().date(from: sentAt))
        XCTAssertGreaterThanOrEqual(date.timeIntervalSince(pausedUntil), -1, "the copy went out once the pause ended")
    }

    func testAResumeStrikesTheGuardOnce() async throws {
        let server = try BlastFaultStandIn.start(scripts: held(3), timeScale: Self.fastClock)
        defer { server.stop() }
        let first = try CLISIGTERMHarness.launchCLI(try submit(), environment: environment(server, scale: Self.fastClock), testClass: Self.self)
        defer { first.stop() }

        let spent = await server.waitForRequest(count: Self.checksPastEveryCopy, of: .status)
        first.stop()
        XCTAssertTrue(spent, "the leaf stopped checking")
        let struck = guardContents()
        XCTAssertEqual(struck?["spentInARow"] as? Int, 1, "the spent search strikes the guard")

        let checked = checks(on: server)
        let spec = try child(["blast", "resume", "--output", output().path, "--format", "json"], server: server)
        async let finished = ToolProcess.run(spec)
        let goesOn = await server.waitForRequest(count: checked + 3, of: .status)
        server.release(rid: rid(1))
        let result = try await finished

        XCTAssertTrue(goesOn, "the resume stopped checking")
        XCTAssertEqual(result.status, 0, said(by: result))
        XCTAssertEqual(puts(on: server).count, 3, "a resume sends nothing past the three")
        let after = guardContents()
        XCTAssertEqual(after?["spentInARow"] as? Int, 1, "the resume does not strike again")
        XCTAssertNil(after?["pausedUntil"], "one search is not two in a row")
    }

    // MARK: NCBI's 100 searches in 24 hours

    func testNoAutomaticCopyPastOneHundredPostsInADay() async throws {
        // 99 POSTs two hours ago and the first send make 100, so the first copy goes and makes 101.
        try writeLedger(99, at: searchClock(scale: Self.fastClock).now().addingTimeInterval(-7200))
        let server = try BlastFaultStandIn.start(scripts: held(4), timeScale: Self.fastClock)
        defer { server.stop() }
        let spec = try child(try submit(), server: server)
        async let finished = ToolProcess.run(spec)

        // Two live sends make at most 17 checks by ten minutes, which is past the second copy's due time.
        let pastEveryCopy = await server.waitForRequest(count: 20, of: .status)
        let posts = puts(on: server).count
        server.release(rid: rid(1))
        let result = try await finished

        XCTAssertTrue(pastEveryCopy, "the leaf stopped checking")
        XCTAssertEqual(posts, 2, "a copy goes at 100, and none past it")
        XCTAssertEqual(result.status, 0, said(by: result))
        let line = "LGE did not send this search again, because this Mac is past NCBI's 100 searches in 24 hours."
        XCTAssertEqual(said(by: result).components(separatedBy: line).count - 1, 1, "one line for the change: \(said(by: result))")
    }

    func testAFirstSendIsNeverRefusedPastOneHundredPostsInADay() async throws {
        try writeLedger(150, at: searchClock(scale: Self.fastClock).now().addingTimeInterval(-7200))
        let server = try BlastFaultStandIn.start(timeScale: Self.fastClock)
        defer { server.stop() }

        let result = try await ToolProcess.run(try child(try submit(), server: server))

        XCTAssertEqual(result.status, 0, said(by: result))
        XCTAssertEqual(puts(on: server).count, 1, "the count holds back only LGE's own copies")
        XCTAssertEqual(try ledgerEvents().count, 151, "the ledger keeps a day of POSTs")
    }

    // MARK: The field log

    func testASearchLeavesItsLinesInTheSearchLogWithNoReadsPathOrLabel() async throws {
        let server = try BlastFaultStandIn.start(scripts: held(1), timeScale: Self.fastClock)
        defer { server.stop() }

        let result = try await finish(try child(try submit(), server: server), whenPutsReach: 2, on: server)

        XCTAssertEqual(result.status, 0, said(by: result))
        let log = try String(contentsOf: state.appendingPathComponent("search-log.tsv"), encoding: .utf8)
        let rows = log.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(rows.first, ["at", "searchID", "rids", "copies", "secondsToFirstReady", "ending", "failedContacts", "replyBytes"])
        XCTAssertEqual(rows.count, 3, "a line when NCBI has the search and a line at its ending: \(log)")
        let searchID = try XCTUnwrap(try searchFile()["searchID"] as? String)
        XCTAssertEqual(rows.dropFirst().map { $0[1] }, [searchID, searchID])
        XCTAssertEqual(rows[1][2...5], [rid(1), "1", "", ""], "a line with no ending is a search not yet seen to end")
        let ending = rows[2]
        XCTAssertEqual(ending[2], "\(rid(1)),\(rid(2))")
        XCTAssertEqual(ending[3], "2")
        XCTAssertGreaterThan(try XCTUnwrap(Double(ending[4])), 180)
        XCTAssertEqual(ending[5], "done")
        XCTAssertEqual(ending[7], String(BlastFaultScript.noHitsResult.count))
        XCTAssertFalse(log.contains("ACGT"), "no reads")
        XCTAssertFalse(log.contains("SecretLabel"), "no label")
        XCTAssertFalse(log.contains(scratch.lastPathComponent), "no path")
    }
}
