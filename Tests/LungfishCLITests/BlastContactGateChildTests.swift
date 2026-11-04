// BlastContactGateChildTests.swift - The built `blast submit` with the gate and the limit it shares across processes
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
import XCTest

/// Phase 3.2 lane BLASTNET, milestone N3 (ARCH-BLAST-RESILIENCE items 8 and 9, section 4, UX-BLAST-WORDS Q5). Children
/// given one state folder share `contact-gate` and the ledger, as two processes on one Mac share `<root>/blast/`, and
/// nothing here reaches NCBI. A test states the ledger by writing its file, in the shape an older LGE wrote or this
/// one writes, so what it reads is the file on disk.
final class BlastContactGateChildTests: XCTestCase {
    private static let fastClock = 600.0
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-contact-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var state: URL {
        scratch.appendingPathComponent("state", isDirectory: true)
    }

    private var ledger: URL {
        state.appendingPathComponent("submission-ledger.json")
    }

    private func output(_ name: String = "result") -> URL {
        scratch.appendingPathComponent(name, isDirectory: true)
    }

    /// `blast submit` of `reads` reads into the folder called `name`.
    private func submit(reads: Int = 2, into name: String = "result") throws -> [String] {
        let query = scratch.appendingPathComponent("query-\(name).fasta")
        let fasta = (1...reads).map { ">read_\($0)\nACGTACGTAC\n" }.joined()
        try Data(fasta.utf8).write(to: query)
        return ["blast", "submit", "--query", query.path, "--output", output(name).path, "--format", "json"]
    }

    private func child(_ arguments: [String], server: BlastFaultStandIn, scale: Double) throws -> ToolProcessSpec {
        let cli = try XCTUnwrap(CLISIGTERMHarness.cliBinaryURL(for: Self.self), "build lungfish-cli first")
        return ToolProcessSpec(
            executableURL: cli, arguments: arguments,
            environment: CLISIGTERMHarness.childEnvironment(overriding: [
                "LUNGFISH_BLAST_STAND_IN_ORIGIN": server.baseURL.absoluteString,
                "LUNGFISH_BLAST_STAND_IN_STATE": state.path,
                "LUNGFISH_BLAST_STAND_IN_TIME_SCALE": String(scale),
            ]),
            timeout: .seconds(60)
        )
    }

    /// Writes the ledger file. A nil `kind` is an event as an older LGE wrote it.
    private func writeLedger(_ events: [(date: Date, count: Int, kind: String?)]) throws {
        let formatter = ISO8601DateFormatter()
        let rows: [[String: Any]] = events.map { event in
            var row: [String: Any] = ["date": formatter.string(from: event.date), "count": event.count]
            if let kind = event.kind { row["kind"] = kind }
            return row
        }
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "events": rows]).write(to: ledger)
    }

    private func ledgerEvents() throws -> [[String: Any]] {
        let document = try JSONSerialization.jsonObject(with: Data(contentsOf: ledger)) as? [String: Any]
        return try XCTUnwrap(document?["events"] as? [[String: Any]])
    }

    private func words(of result: ToolProcessResult) -> String {
        result.stdoutText + result.stderrText
    }

    private func assertRefusedWithNoContact(
        _ result: ToolProcessResult,
        server: BlastFaultStandIn,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNotEqual(result.status, 0, words(of: result), file: file, line: line)
        XCTAssertEqual(server.arrivals.count, 0, "a refused search reaches nothing", file: file, line: line)
        let searchFile = output().appendingPathComponent(BlastSearchFile.fileName).path
        XCTAssertFalse(FileManager.default.fileExists(atPath: searchFile), "no file stays in sending", file: file, line: line)
    }

    // MARK: The gate

    func testTwoProcessesKeepElevenSecondsApart() async throws {
        let scale = 10.0
        let server = try BlastFaultStandIn.start(timeScale: scale)
        defer { server.stop() }
        let first = try child(try submit(into: "first"), server: server, scale: scale)
        let second = try child(try submit(into: "second"), server: server, scale: scale)

        async let firstRun = ToolProcess.run(first)
        async let secondRun = ToolProcess.run(second)
        let results = try await [firstRun, secondRun]

        for result in results { XCTAssertEqual(result.status, 0, words(of: result)) }
        let arrivals = server.arrivals
        XCTAssertEqual(arrivals.count, 6, "each search makes a Put, a check and a fetch")
        // Six contacts take five slots, whoever made them, however the two processes interleave. Each slot's own
        // lateness cancels but for the first's, so one real second of it is the room this leaves.
        let span = try XCTUnwrap(arrivals.last).at.timeIntervalSince(try XCTUnwrap(arrivals.first).at)
        XCTAssertGreaterThanOrEqual(span, 5 * 11 - scale, "six contacts on one Mac came too close together: \(arrivals)")
    }

    func testAKilledHolderDoesNotBlockTheGate() async throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/perl"), "this test holds the lock from perl")
        let gate = state.appendingPathComponent("contact-gate")
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = [
            "-e",
            #"use Fcntl qw(:flock); open(my $f, ">>", $ARGV[0]) or die; flock($f, LOCK_EX) or die; $| = 1; print "held\n"; sleep 600;"#,
            gate.path,
        ]
        let said = Pipe()
        holder.standardOutput = said
        try holder.run()
        // The read returns when the holder has the lock, or at once when it died, which the line after sees.
        let first = said.fileHandleForReading.availableData
        XCTAssertEqual(String(decoding: first, as: UTF8.self), "held\n")
        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()

        let server = try BlastFaultStandIn.start(timeScale: Self.fastClock)
        defer { server.stop() }
        let result = try await ToolProcess.run(try child(try submit(), server: server, scale: Self.fastClock))

        XCTAssertEqual(result.status, 0, words(of: result))
        let slot = try Data(contentsOf: gate)
        XCTAssertFalse(slot.isEmpty, "the run took its slots from the gate the holder left")
    }

    // MARK: The ledger

    func testEveryPostIsCountedInTheLedger() async throws {
        let server = try BlastFaultStandIn.start(
            scripts: [BlastFaultScript(put: [.http(status: 503), .droppedAfterSending])],
            timeScale: Self.fastClock
        )
        defer { server.stop() }

        let result = try await ToolProcess.run(try child(try submit(), server: server, scale: Self.fastClock))

        XCTAssertEqual(result.status, 0, words(of: result))
        let posts = server.arrivals.filter { $0.contact == .put }.count
        XCTAssertEqual(posts, 3, "a busy answer and a lost reply each bring one more POST")
        let events = try ledgerEvents()
        XCTAssertEqual(events.count, posts, "one event for each POST: \(events)")
        XCTAssertEqual(events.map { $0["count"] as? Int }, Array(repeating: 2, count: events.count))
        XCTAssertEqual(events.map { $0["kind"] as? String }, Array(repeating: "first", count: events.count), "a re-POST counts as what it repeats")
    }

    func testACopyNeverRefusesAFirstSend() async throws {
        let server = try BlastFaultStandIn.start(timeScale: 60)
        defer { server.stop() }
        let lately = Date().addingTimeInterval(-60)
        try writeLedger([(lately, 40, "first"), (lately, 60, "copy"), (lately, 30, "copy")])

        let result = try await ToolProcess.run(try child(try submit(), server: server, scale: 60))

        XCTAssertEqual(result.status, 0, "first sends stand at 40 of 50, and the copies are not theirs to refuse: \(words(of: result))")
        XCTAssertEqual(try ledgerEvents().count, 4, "the copies stay counted")
    }

    // MARK: The words of Q5

    func testTheLimitWordsNameLGE() async throws {
        let server = try BlastFaultStandIn.start()
        defer { server.stop() }
        // Events with no kind, as an older LGE wrote them, count as first sends.
        try writeLedger([(Date().addingTimeInterval(-120), 49, nil)])

        let result = try await ToolProcess.run(try child(try submit(), server: server, scale: 1))

        assertRefusedWithNoContact(result, server: server)
        let said = words(of: result)
        XCTAssertTrue(said.contains(
            "LGE's own limit stopped this search, and NCBI was not contacted. LGE sends at most 50 reads an hour, and 49 have gone in the last hour. This search of 2 reads fits at "
        ), said)
        XCTAssertTrue(said.contains("Try again then, or send 1 or fewer reads now."), said)
        XCTAssertFalse(said.contains("NCBI rate limit"), said)
    }

    func testFitTimeIsWhenTheSearchFits() async throws {
        let server = try BlastFaultStandIn.start()
        defer { server.stop() }
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let later = now.addingTimeInterval(-900)
        try writeLedger([(now.addingTimeInterval(-2700), 10, "first"), (later, 40, "first")])

        let result = try await ToolProcess.run(try child(try submit(reads: 20), server: server, scale: 1))

        assertRefusedWithNoContact(result, server: server)
        // The oldest event leaves in 15 minutes and 20 reads still do not fit beside the 40. They fit when those go.
        let fits = BlastSearchWords.time(later.addingTimeInterval(3600), now: now)
        let said = words(of: result)
        XCTAssertTrue(said.contains("and 50 have gone in the last hour. This search of 20 reads fits at \(fits). Try again then."), said)
        XCTAssertFalse(said.contains("or fewer"), "no read fits now: \(said)")
    }

    func testASearchOverTheLimitNamesNoTime() async throws {
        let server = try BlastFaultStandIn.start()
        defer { server.stop() }

        let result = try await ToolProcess.run(try child(try submit(reads: 60), server: server, scale: 1))

        assertRefusedWithNoContact(result, server: server)
        let said = words(of: result)
        XCTAssertTrue(said.contains(
            "LGE's own limit stopped this search, and NCBI was not contacted. LGE sends at most 50 reads an hour, so 60 reads cannot go as one search. Send 50 or fewer."
        ), said)
        XCTAssertFalse(said.contains("fits at"), said)
    }
}
