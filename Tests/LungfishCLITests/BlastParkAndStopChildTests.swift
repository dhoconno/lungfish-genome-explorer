// BlastParkAndStopChildTests.swift - A search that outlives its process, on the built CLI and the fault stand-in
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
import XCTest

/// Phase 3.2 lane BLASTCOLLECT, milestone C1 (ARCH-BLAST-RESILIENCE items 13, 14, 18 and 19, and section 6). A search
/// parks instead of failing, SIGTERM leaves it alone, and only the person's Stop or NCBI's answer ends it. Each child
/// runs on a scaled clock, so no real wait grows, and a test holds a search by not releasing it. Nothing here reaches NCBI.
final class BlastParkAndStopChildTests: XCTestCase {
    private static let fastClock = 600.0
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-park-child-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var output: URL {
        scratch.appendingPathComponent("result", isDirectory: true)
    }

    private var stateFolder: URL {
        scratch.appendingPathComponent("state", isDirectory: true)
    }

    private func environment(_ server: BlastFaultStandIn, scale: Double) -> [String: String] {
        [
            "LUNGFISH_BLAST_STAND_IN_ORIGIN": server.baseURL.absoluteString,
            "LUNGFISH_BLAST_STAND_IN_STATE": stateFolder.path,
            "LUNGFISH_BLAST_STAND_IN_TIME_SCALE": String(scale),
        ]
    }

    private func submitArguments(park: Bool = false, into folder: URL? = nil) throws -> [String] {
        let query = scratch.appendingPathComponent("query-from-viewer.fasta")
        try Data(">read_1\nACGTACGTAC\n>read_2\nGGCCTTAAGG\n".utf8).write(to: query)
        return ["blast", "submit", "--query", query.path, "--output", (folder ?? output).path, "--format", "json"]
            + (park ? ["--park"] : [])
    }

    private func run(
        _ arguments: [String],
        server: BlastFaultStandIn,
        scale: Double = BlastParkAndStopChildTests.fastClock
    ) async throws -> ToolProcessResult {
        let cli = try XCTUnwrap(CLISIGTERMHarness.cliBinaryURL(for: Self.self), "build lungfish-cli first")
        return try await ToolProcess.run(ToolProcessSpec(
            executableURL: cli, arguments: arguments,
            environment: CLISIGTERMHarness.childEnvironment(overriding: environment(server, scale: scale)),
            timeout: .seconds(60)
        ))
    }

    private func searchFile(in folder: URL? = nil) throws -> [String: Any] {
        let data = try Data(contentsOf: (folder ?? output).appendingPathComponent("blast-search.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func rids(in folder: URL? = nil) throws -> [String] {
        let copies = try XCTUnwrap(try searchFile(in: folder)["copies"] as? [[String: Any]])
        return copies.compactMap { $0["rid"] as? String }
    }

    private func count(_ contact: BlastFaultContact, on server: BlastFaultStandIn) -> Int {
        server.arrivals.filter { $0.contact == contact }.count
    }

    private func cancelledRecords(in folder: URL? = nil) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: (folder ?? output).path)
            .filter { $0.hasPrefix("lungfish-blast-submit-") && $0.hasSuffix(".lungfish-provenance.json") }
    }

    private func hasResult(in folder: URL? = nil) -> Bool {
        FileManager.default.fileExists(atPath: (folder ?? output).appendingPathComponent("blast-result.json").path)
    }

    /// Three held sends, parked at spent, the state every test here starts from.
    private func parkedSearch() async throws -> BlastFaultStandIn {
        let server = try BlastFaultStandIn.start(
            scripts: Array(repeating: BlastFaultScript(search: .held), count: 6), timeScale: Self.fastClock
        )
        let parked = try await run(try submitArguments(park: true), server: server)
        XCTAssertEqual(parked.status, 75, parked.stderrText)
        return server
    }

    private func inFlightDocument(_ result: ToolProcessResult) throws -> [String: Any] {
        XCTAssertEqual(result.status, 0, result.stderrText)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.stdoutText.utf8)) as? [String: Any])
    }

    private func lines(of document: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(document["lines"] as? [[String: Any]])
    }

    /// Moves a line's last contact back by this many hours, as if that long had passed with no contact.
    private func ageTheLines(byHours hours: Double) throws {
        let folder = stateFolder.appendingPathComponent("in-flight", isDirectory: true)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".json") }
        XCTAssertFalse(names.isEmpty, "no line in \(folder.path)")
        for name in names {
            let url = folder.appendingPathComponent(name)
            var line = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            line["lastContactAt"] = Date().addingTimeInterval(-hours * 3600).formatted(.iso8601)
            try JSONSerialization.data(withJSONObject: line).write(to: url)
        }
    }

    // MARK: Park and one pass

    func testParkExitsSeventyFiveWithTheRidsSaved() async throws {
        let server = try BlastFaultStandIn.start(
            scripts: Array(repeating: BlastFaultScript(search: .held), count: 3), timeScale: Self.fastClock
        )
        defer { server.stop() }

        let result = try await run(try submitArguments(park: true), server: server)

        XCTAssertEqual(result.status, 75, result.stderrText)
        XCTAssertTrue(result.stdoutText.contains(#""event":"waiting""#), result.stdoutText)
        XCTAssertFalse(result.stdoutText.contains(#""event":"failed""#), result.stdoutText)
        XCTAssertEqual(try rids(), (1...3).map(BlastFaultStandIn.rid(ofPut:)), "every send's request ID is on disk")
        let file = try searchFile()
        XCTAssertEqual(file["state"] as? String, "waiting")
        XCTAssertNotNil(file["spentAt"], "the search parked because every send was out long enough")
        XCTAssertFalse(hasResult())
        try BlastSubmitStandInTests.recaptureIfAsked("waiting", stdout: result.stdoutText, scratch: scratch)
    }

    func testOnceMakesOnePassOfWhatIsDueAndExits() async throws {
        let server = try await parkedSearch()
        defer { server.stop() }
        let checksBefore = count(.status, on: server)

        // At the wall clock's own speed nothing has come due since the park, unless a check is overdue already.
        let quiet = try await run(["blast", "resume", "--output", output.path, "--once", "--format", "json"], server: server)
        XCTAssertEqual(quiet.status, 75, quiet.stderrText)
        XCTAssertTrue(quiet.stdoutText.contains(#""event":"waiting""#), quiet.stdoutText)
        XCTAssertGreaterThanOrEqual(count(.status, on: server), checksBefore)
        XCTAssertEqual(count(.put, on: server), 3, "a pass of a spent search sends nothing again")
        XCTAssertEqual(try searchFile()["state"] as? String, "waiting")

        server.release(rid: BlastFaultStandIn.rid(ofPut: 2))
        var collected = try await run(["blast", "resume", "--output", output.path, "--once", "--format", "json"], server: server)
        for _ in 0..<40 where collected.status == 75 {
            // One pass checks what is due, and on this clock the time a child takes to start brings the next check due.
            collected = try await run(["blast", "resume", "--output", output.path, "--once", "--format", "json"], server: server)
        }

        XCTAssertEqual(collected.status, 0, collected.stderrText)
        XCTAssertTrue(hasResult(), "the first READY gives the record")
        XCTAssertEqual(try searchFile()["winnerOrdinal"] as? Int, 2)
    }

    // MARK: SIGTERM and Stop

    func testSIGTERMLeavesTheSearchToResume() async throws {
        let scale = 60.0
        let server = try BlastFaultStandIn.start(scripts: [BlastFaultScript(search: .held)], timeScale: scale)
        defer { server.stop() }
        let child = try CLISIGTERMHarness.launchCLI(
            try submitArguments(), environment: environment(server, scale: scale), testClass: Self.self
        )
        defer { child.stop() }
        let checked = await server.waitForRequest(count: 1, of: .status)
        XCTAssertTrue(checked, "the leaf never checked its search")

        let stop = await CLISIGTERMHarness.cancel(child)

        XCTAssertEqual(stop.exitStatus, 125, stop.diagnostics)
        XCTAssertEqual(try cancelledRecords(), [], "the search lives on, so no record says it was cancelled")
        XCTAssertEqual(try searchFile()["state"] as? String, "waiting", "SIGTERM leaves the state alone")
        let rid = BlastFaultStandIn.rid(ofPut: 1)
        XCTAssertTrue(stop.standardError.contains("The search stays at NCBI as request ID \(rid)"), stop.standardError)
        XCTAssertTrue(stop.standardError.contains("lungfish-cli blast resume --output \(output.path)"), stop.standardError)
        XCTAssertFalse(stop.standardOutput.contains(#""event":"failed""#), stop.standardOutput)

        server.release(rid: rid)
        let resumed = try await run(["blast", "resume", "--output", output.path, "--format", "json"], server: server, scale: scale)

        XCTAssertEqual(resumed.status, 0, resumed.stderrText)
        XCTAssertTrue(hasResult())
        XCTAssertEqual(count(.put, on: server), 1, "the same request ID came back, with nothing sent again")
    }

    func testStopWritesStoppedAndACancelledRecord() async throws {
        let server = try await parkedSearch()
        defer { server.stop() }
        let contacts = server.arrivals.count

        let stop = try await run(["blast", "stop", "--output", output.path, "--format", "json"], server: server)

        XCTAssertEqual(stop.status, 0, stop.stderrText)
        XCTAssertEqual(server.arrivals.count, contacts, "Stop contacts nothing")
        let file = try searchFile()
        XCTAssertEqual(file["state"] as? String, "stopped")
        let names = try cancelledRecords()
        XCTAssertEqual(names.count, 1, "one cancelled record, found \(names)")
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: output.appendingPathComponent(try XCTUnwrap(names.first))))
        XCTAssertEqual(envelope.status.rawValue, "cancelled")
        XCTAssertEqual(try rids().count, 3, "a stopped search keeps its request IDs")
        XCTAssertTrue(stop.stdoutText.contains("Stopped. LGE no longer checks this search"), stop.stdoutText)
        try BlastSubmitStandInTests.recaptureIfAsked("complete", stdout: stop.stdoutText, scratch: scratch, command: "blast-stop")

        // Resume takes it up again while NCBI holds it, with nothing sent again.
        server.release(rid: BlastFaultStandIn.rid(ofPut: 1))
        let resumed = try await run(["blast", "resume", "--output", output.path, "--format", "json"], server: server)
        XCTAssertEqual(resumed.status, 0, resumed.stderrText)
        XCTAssertTrue(hasResult())
        XCTAssertEqual(count(.put, on: server), 3)
    }

    func testStopOfALeafAtWorkEndsTheLeafAndStopsTheSearch() async throws {
        let scale = 60.0
        let server = try BlastFaultStandIn.start(scripts: [BlastFaultScript(search: .held)], timeScale: scale)
        defer { server.stop() }
        let child = try CLISIGTERMHarness.launchCLI(
            try submitArguments(), environment: environment(server, scale: scale), testClass: Self.self
        )
        defer { child.stop() }
        let checked = await server.waitForRequest(count: 1, of: .status)
        XCTAssertTrue(checked, "the leaf never checked its search")

        let stop = try await run(["blast", "stop", "--output", output.path, "--format", "json"], server: server, scale: scale)

        XCTAssertEqual(stop.status, 0, stop.stderrText)
        XCTAssertEqual(try searchFile()["state"] as? String, "stopped", "the leaf at work did not write over the Stop")
        XCTAssertEqual(try cancelledRecords().count, 1)
    }

    func testStopOfASearchThatCameBackSaysThereWasNothingToStop() async throws {
        let server = try BlastFaultStandIn.start(timeScale: Self.fastClock)
        defer { server.stop() }
        let submitted = try await run(try submitArguments(), server: server)
        XCTAssertEqual(submitted.status, 0, submitted.stderrText)

        let stop = try await run(["blast", "stop", "--output", output.path, "--format", "json"], server: server)

        XCTAssertEqual(stop.status, 0, stop.stderrText)
        XCTAssertTrue(stop.stdoutText.contains("This search had already come back, so there was nothing to stop."), stop.stdoutText)
        XCTAssertEqual(try searchFile()["state"] as? String, "done")
        XCTAssertEqual(try cancelledRecords(), [])
    }

    func testStopOfAFolderWithNoSearchSaysSo() async throws {
        let server = try BlastFaultStandIn.start(timeScale: Self.fastClock)
        defer { server.stop() }

        let stop = try await run(["blast", "stop", "--output", output.path, "--format", "json"], server: server)

        XCTAssertEqual(stop.status, 3, stop.stderrText)
        XCTAssertTrue(stop.stdoutText.contains("No BLAST search is saved"), stop.stdoutText)
        try BlastSubmitStandInTests.recaptureIfAsked("failed", stdout: stop.stdoutText, scratch: scratch, command: "blast-stop")
    }

    // MARK: Two resumes

    func testTwoResumesOfOneSearchRunOneAtATime() async throws {
        let server = try await parkedSearch()
        defer { server.stop() }
        let checksBefore = count(.status, on: server)
        let first = try CLISIGTERMHarness.launchCLI(
            ["blast", "resume", "--output", output.path, "--format", "json"],
            environment: environment(server, scale: Self.fastClock), testClass: Self.self
        )
        defer { first.stop() }
        let working = await server.waitForRequest(count: checksBefore + 1, of: .status)
        XCTAssertTrue(working, "the first resume never checked its search")

        let second = try await run(["blast", "resume", "--output", output.path, "--once", "--format", "json"], server: server)

        XCTAssertEqual(second.status, 0, second.stderrText)
        XCTAssertTrue(second.stdoutText.contains("alreadyRunning"), second.stdoutText)
        XCTAssertEqual(count(.put, on: server), 3)
    }

    // MARK: Lines

    func testAParkedSearchHasALineThatHoldsNoReads() async throws {
        let server = try await parkedSearch()
        defer { server.stop() }

        let listed = try inFlightDocument(try await run(["blast", "in-flight", "--format", "json"], server: server))

        let line = try XCTUnwrap(try lines(of: listed).first)
        XCTAssertEqual(try lines(of: listed).count, 1)
        XCTAssertEqual(line["output"] as? String, output.path)
        XCTAssertEqual(line["searchID"] as? String, try searchFile()["searchID"] as? String)
        XCTAssertEqual(line["rids"] as? [String], try rids())
        let text = try String(contentsOf: stateFolder.appendingPathComponent("in-flight").appendingPathComponent("\(line["searchID"] as? String ?? "").json"), encoding: .utf8)
        XCTAssertFalse(text.contains("ACGTACGTAC"), "a line holds no reads")
    }

    func testASearchThatEndedIsNoLongerListed() async throws {
        let server = try BlastFaultStandIn.start(timeScale: Self.fastClock)
        defer { server.stop() }
        let submitted = try await run(try submitArguments(), server: server)
        XCTAssertEqual(submitted.status, 0, submitted.stderrText)

        let listed = try inFlightDocument(try await run(["blast", "in-flight", "--format", "json"], server: server))

        XCTAssertEqual(try lines(of: listed).count, 0)
    }

    func testAMovedProjectIsAdoptedAtOpen() async throws {
        let server = try await parkedSearch()
        defer { server.stop() }
        let project = scratch.appendingPathComponent("moved.lungfish", isDirectory: true)
        let verifications = project.appendingPathComponent("blast-verifications", isDirectory: true)
        try FileManager.default.createDirectory(at: verifications, withIntermediateDirectories: true)
        let moved = verifications.appendingPathComponent("search-one", isDirectory: true)
        try FileManager.default.moveItem(at: output, to: moved)

        // Before the project opens the line waits, and the pass says where the search is.
        let lost = try await run(["blast", "resume", "--output", output.path, "--once", "--format", "json"], server: server)
        XCTAssertEqual(lost.status, 75, lost.stderrText)
        XCTAssertTrue(lost.stdoutText.contains("LGE cannot find the folder this search saves into"), lost.stdoutText)

        let opened = try inFlightDocument(
            try await run(["blast", "in-flight", "--project", project.path, "--format", "json"], server: server)
        )
        XCTAssertEqual(try lines(of: opened).first?["output"] as? String, moved.path)

        server.release(rid: BlastFaultStandIn.rid(ofPut: 3))
        let resumed = try await run(["blast", "resume", "--output", moved.path, "--format", "json"], server: server)
        XCTAssertEqual(resumed.status, 0, resumed.stderrText)
        XCTAssertTrue(hasResult(in: moved))
        XCTAssertEqual(count(.put, on: server), 3, "the same request IDs, with nothing sent again")
    }

    func testAFolderWithNoLineIsAdoptedAtOpen() async throws {
        let server = try await parkedSearch()
        defer { server.stop() }
        let project = scratch.appendingPathComponent("adopted.lungfish", isDirectory: true)
        let verifications = project.appendingPathComponent("blast-verifications", isDirectory: true)
        try FileManager.default.createDirectory(at: verifications, withIntermediateDirectories: true)
        let moved = verifications.appendingPathComponent("search-one", isDirectory: true)
        try FileManager.default.moveItem(at: output, to: moved)
        try FileManager.default.removeItem(at: stateFolder.appendingPathComponent("in-flight", isDirectory: true))

        let opened = try inFlightDocument(
            try await run(["blast", "in-flight", "--project", project.path, "--format", "json"], server: server)
        )

        XCTAssertEqual(try lines(of: opened).first?["output"] as? String, moved.path, "losing the line loses no search")
    }

    func testACopiedProjectNeverPosts() async throws {
        let server = try await parkedSearch()
        defer { server.stop() }
        let copy = scratch.appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.copyItem(at: output, to: copy)
        // Take the copy back to two sends, with the third due, so that only the rule can hold its POST.
        let url = copy.appendingPathComponent("blast-search.json")
        var file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        file["copies"] = Array(try XCTUnwrap(file["copies"] as? [[String: Any]]).prefix(2))
        file.removeValue(forKey: "spentAt")
        try JSONSerialization.data(withJSONObject: file).write(to: url)
        let puts = count(.put, on: server)

        server.release(rid: BlastFaultStandIn.rid(ofPut: 1))
        let collected = try await run(["blast", "resume", "--output", copy.path, "--format", "json"], server: server)

        XCTAssertEqual(collected.status, 0, collected.stderrText)
        XCTAssertEqual(count(.put, on: server), puts, "a copied project only checks and fetches")
        XCTAssertTrue(hasResult(in: copy), "the copy gets its own record")
        XCTAssertFalse(hasResult(), "the first folder's record is its own to write")

        let held = try await run(["blast", "in-flight", "--format", "json"], server: server)
        XCTAssertEqual(try lines(of: try inFlightDocument(held)).first?["output"] as? String, output.path, "the line stays with the first folder")
    }

    func testAMissingFolderKeepsItsLineUntilSeventyTwoHours() async throws {
        let server = try await parkedSearch()
        defer { server.stop() }
        try FileManager.default.moveItem(at: output, to: scratch.appendingPathComponent("elsewhere", isDirectory: true))

        try ageTheLines(byHours: 71)
        let kept = try inFlightDocument(try await run(["blast", "in-flight", "--format", "json"], server: server))
        XCTAssertEqual(try lines(of: kept).count, 1, "a drive may come back")

        try ageTheLines(byHours: 73)
        let gone = try inFlightDocument(try await run(["blast", "in-flight", "--format", "json"], server: server))
        XCTAssertEqual(try lines(of: gone).count, 0)
        let log = try String(contentsOf: stateFolder.appendingPathComponent("search-log.tsv"), encoding: .utf8)
        XCTAssertTrue(log.contains("project gone"), log)
    }

    func testAFolderThatStillExistsKeepsItsLinePastSeventyTwoHours() async throws {
        let server = try await parkedSearch()
        defer { server.stop() }

        try ageTheLines(byHours: 100)
        let kept = try inFlightDocument(try await run(["blast", "in-flight", "--format", "json"], server: server))

        XCTAssertEqual(try lines(of: kept).count, 1, "a Mac left off for days has lost nothing")
    }

    // MARK: A person's buttons

    func testSendAgainGoesOutPastTheThirdAndRepeatsTheBytes() async throws {
        let server = try await parkedSearch()
        defer { server.stop() }

        let sent = try await run(["blast", "resume", "--output", output.path, "--once", "--send-again", "--format", "json"], server: server)

        XCTAssertEqual(sent.status, 75, sent.stderrText)
        XCTAssertEqual(count(.put, on: server), 4, "a person's send goes past the three LGE makes")
        XCTAssertTrue(sent.stdoutText.contains("You sent the same"), sent.stdoutText)
        let posts = server.requests.filter { $0.method == "POST" }.map { String(decoding: $0.body, as: UTF8.self) }
        XCTAssertEqual(Set(posts).count, 1, "every send repeats the same bytes")
    }

    func testSendAgainAfterStopGoesBackToWaiting() async throws {
        let server = try await parkedSearch()
        defer { server.stop() }
        let stop = try await run(["blast", "stop", "--output", output.path, "--format", "json"], server: server)
        XCTAssertEqual(stop.status, 0, stop.stderrText)

        let sent = try await run(["blast", "resume", "--output", output.path, "--once", "--send-again", "--format", "json"], server: server)

        XCTAssertEqual(sent.status, 75, sent.stderrText)
        XCTAssertEqual(try searchFile()["state"] as? String, "waiting")
        XCTAssertNil(try searchFile()["ending"], "the search goes on, so it has no ending")
        XCTAssertEqual(count(.put, on: server), 4)
    }

    func testCheckNowChecksWhatIsNotDue() async throws {
        let server = try await parkedSearch()
        defer { server.stop() }
        // Every check is put far off, and a much faster clock takes every send past its minute since the last check.
        let url = output.appendingPathComponent("blast-search.json")
        var file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        file["copies"] = try XCTUnwrap(file["copies"] as? [[String: Any]]).map { copy in
            var copy = copy
            copy["nextCheckAt"] = Date(timeIntervalSinceNow: 1_000_000_000).formatted(.iso8601)
            return copy
        }
        try JSONSerialization.data(withJSONObject: file).write(to: url)
        let scale = 60_000.0
        let checks = count(.status, on: server)

        let quiet = try await run(["blast", "resume", "--output", output.path, "--once", "--format", "json"], server: server, scale: scale)
        XCTAssertEqual(quiet.status, 75, quiet.stderrText)
        XCTAssertEqual(count(.status, on: server), checks, "a pass checks only what is due")

        let pressed = try await run(["blast", "resume", "--output", output.path, "--once", "--check-now", "--format", "json"], server: server, scale: scale)
        XCTAssertEqual(pressed.status, 75, pressed.stderrText)
        XCTAssertEqual(count(.status, on: server), checks + 3, "a press checks every send past its minute")
    }
}
