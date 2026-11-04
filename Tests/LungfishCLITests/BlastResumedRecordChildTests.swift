// BlastResumedRecordChildTests.swift - The record of a search that came back, on the built CLI and the fault stand-in
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
import XCTest

/// Phase 3.2 lane BLASTCOLLECT, milestone C2 (ARCH-BLAST-RESILIENCE sections 1 and 6). The record of a resumed search
/// names the command that wrote it, and its replay is the command that sent the search, so a replay sends the same
/// bytes. Each child runs on a scaled clock, so no real wait grows. Nothing here reaches NCBI.
final class BlastResumedRecordChildTests: XCTestCase {
    private static let fastClock = 600.0
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-resumed-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var output: URL {
        scratch.appendingPathComponent("result", isDirectory: true)
    }

    private func run(_ arguments: [String], server: BlastFaultStandIn, state: String) async throws -> ToolProcessResult {
        let cli = try XCTUnwrap(CLISIGTERMHarness.cliBinaryURL(for: Self.self), "build lungfish-cli first")
        return try await ToolProcess.run(ToolProcessSpec(
            executableURL: cli, arguments: arguments,
            environment: CLISIGTERMHarness.childEnvironment(overriding: [
                "LUNGFISH_BLAST_STAND_IN_ORIGIN": server.baseURL.absoluteString,
                "LUNGFISH_BLAST_STAND_IN_STATE": scratch.appendingPathComponent(state, isDirectory: true).path,
                "LUNGFISH_BLAST_STAND_IN_TIME_SCALE": String(Self.fastClock),
            ]),
            timeout: .seconds(60)
        ))
    }

    private func postBodies(_ server: BlastFaultStandIn) -> [Data] {
        server.requests.filter { $0.method == "POST" }.map(\.body)
    }

    /// `blast submit --park` parks on three held sends, then `blast resume` collects the second. The record's argv is
    /// the resume, its replay is the submit, and the replay's POST is the first POST byte for byte.
    func testTheResumedRecordsReplaySendsTheSameBytes() async throws {
        let query = scratch.appendingPathComponent("query-from-viewer.fasta")
        try Data(">read_1\nACGTACGTAC\n>read_2\nGGCCTTAAGG\n".utf8).write(to: query)
        let server = try BlastFaultStandIn.start(
            scripts: Array(repeating: BlastFaultScript(search: .held), count: 3), timeScale: Self.fastClock
        )
        defer { server.stop() }
        let parked = try await run(
            ["blast", "submit", "--query", query.path, "--output", output.path, "--name", "reads", "--format", "json", "--park"],
            server: server, state: "first"
        )
        XCTAssertEqual(parked.status, 75, parked.stderrText)

        let winner = BlastFaultStandIn.rid(ofPut: 2)
        server.release(rid: winner)
        let resumed = try await run(["blast", "resume", "--output", output.path, "--format", "json"], server: server, state: "first")
        XCTAssertEqual(resumed.status, 0, resumed.stderrText)

        let sidecar = output.appendingPathComponent("blast-result.json.lungfish-provenance.json")
        let envelope = try XCTUnwrap(try ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        let argv = envelope.argv.joined(separator: " ")
        XCTAssertTrue(argv.contains("blast resume"), "the record names the command that wrote it: \(argv)")
        let replay = try XCTUnwrap(envelope.durableReplayArgv, "the record names a replay")
        XCTAssertTrue(replay.joined(separator: " ").contains("blast submit"), "the replay is the command that sent: \(replay)")

        let text = try String(contentsOf: sidecar, encoding: .utf8)
        for key in ["\"rids\"", "\"winningRID\"", "\"copiesSent\"", winner, BlastFaultStandIn.rid(ofPut: 3)] {
            XCTAssertTrue(text.contains(key), "the provenance names \(key)")
        }

        // The replay runs in a fresh folder against a fresh stand-in, and any later send of the first is left out.
        var words = Array(replay.dropFirst())
        let place = try XCTUnwrap(words.firstIndex(of: "--output"))
        words[place + 1] = scratch.appendingPathComponent("replay", isDirectory: true).path
        let replayServer = try BlastFaultStandIn.start(
            scripts: [BlastFaultScript(search: .readyAtOnce)], timeScale: Self.fastClock
        )
        defer { replayServer.stop() }
        let replayed = try await run(words, server: replayServer, state: "second")
        XCTAssertEqual(replayed.status, 0, replayed.stderrText)
        XCTAssertEqual(postBodies(replayServer).first, postBodies(server).first, "a replay sends what the first send sent")
    }
}
