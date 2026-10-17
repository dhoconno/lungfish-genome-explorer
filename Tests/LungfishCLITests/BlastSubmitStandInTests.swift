// BlastSubmitStandInTests.swift - The built `blast submit` against a loopback BLAST stand-in
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
import XCTest

/// Phase 2.11 lane A65 M1 (plan decision C1, 2.10 decisions C5 and G5). The built CLI runs against
/// a loopback stand-in of NCBI's BLAST CGI: it sends the bytes the NAO-MGS site sends today, saves
/// the result beside its query copy, and SIGTERM cancels it inside the 6-second grace with its run
/// recorded as cancelled and no process left. `LUNGFISH_RECAPTURE_CLI_EVENTS=1` writes the leaf's
/// transcripts under `Tests/Fixtures/cli-events/commands/blast-submit`.
final class BlastSubmitStandInTests: XCTestCase {
    private static let standInVariable = "LUNGFISH_BLAST_STAND_IN_ORIGIN"
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-submit-standin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Answers a submission with an RID, a status poll with READY and a result fetch with JSON2.
    static func standIn() throws -> LoopbackHTTPStandIn {
        try LoopbackHTTPStandIn.start { request in
            guard request.path == "/blast/Blast.cgi" else { return .notFound }
            if request.method == "POST" {
                return .text("<!--QBlastInfoBegin\n    RID = STANDIN1\n    RTOE = 1\nQBlastInfoEnd-->")
            }
            if request.queryItems.contains(URLQueryItem(name: "FORMAT_OBJECT", value: "SearchInfo")) {
                return .text("<!--QBlastInfoBegin\n    Status=READY\nQBlastInfoEnd-->")
            }
            return LoopbackHTTPResponse(contentType: "application/json", body: BlastSubmitCommandTests.json2NoHits)
        }
    }

    private func writeQuery() throws -> URL {
        let url = scratch.appendingPathComponent("query-from-viewer.fasta")
        try Data(">read_1\nACGTACGTAC\n>read_2\nGGCCTTAAGG\n".utf8).write(to: url)
        return url
    }

    func testTheLeafSendsTheNaoMgsSiteBytesAndSavesItsResult() async throws {
        let cli = try XCTUnwrap(CLISIGTERMHarness.cliBinaryURL(for: Self.self), "build lungfish-cli first")
        let server = try Self.standIn()
        defer { server.stop() }
        let output = scratch.appendingPathComponent("result", isDirectory: true)
        let arguments = [
            "blast", "submit", "--query", try writeQuery().path, "--output", output.path, "--name", "Influenza A virus",
            "--taxid", "11320", "--entrez-query", "txid11320[Organism:exp]", "--source-result", scratch.path,
            "--sample", "S1", "--subsample-count", "2", "--format", "json",
        ]
        // A throwaway key signs the record, so `provenance verify` can check it (RouteParityHarness+Signing).
        let signing = ["LUNGFISH_PROVENANCE_SIGNING_KEY": "lane-a65-sign-throwaway-\(UUID().uuidString)"]
        let result = try await ToolProcess.run(ToolProcessSpec(
            executableURL: cli, arguments: arguments,
            environment: CLISIGTERMHarness.childEnvironment(
                overriding: signing.merging([Self.standInVariable: server.baseURL.absoluteString]) { $1 }),
            timeout: .seconds(90)
        ))
        XCTAssertEqual(result.status, 0, result.stderrText)
        let put = try XCTUnwrap(server.requests.first { $0.method == "POST" })
        XCTAssertEqual(
            String(decoding: put.body, as: UTF8.self),
            "CMD=Put&PROGRAM=blastn&DATABASE=core_nt&QUERY=%3Eread_1%0AACGTACGTAC%0A%3Eread_2%0AGGCCTTAAGG"
                + "&EXPECT=1e-10&HITLIST_SIZE=5&MAX_NUM_SEQ=5&FORMAT_TYPE=JSON2&WORD_SIZE=28"
                + "&TOOL=lungfish&EMAIL=lungfish-app%40users.noreply.github.com&MEGABLAST=on"
                + "&ENTREZ_QUERY=txid11320%5BOrganism%3Aexp%5D",
            "the leaf sends the bytes BlastSiteRequestBytesPinTests pins for blast-nao-mgs"
        )
        let record = try BlastSubmissionRecord.load(output.appendingPathComponent("blast-result.json"))
        XCTAssertEqual(record.lineage.sample, "S1")
        XCTAssertEqual(record.result.rid, "STANDIN1")
        XCTAssertTrue(result.stdoutText.contains(#""event":"complete""#), result.stdoutText)
        XCTAssertFalse(result.stdoutText.contains("ACGTACGTAC"), "no sequence text reaches the events")
        try Self.recaptureIfAsked("complete", stdout: result.stdoutText, scratch: scratch)
        let sidecar = output.appendingPathComponent("blast-result.json.lungfish-provenance.json")
        XCTAssertEqual(try ProvenanceEnvelopeReader.load(fromSidecar: sidecar)?.status.rawValue, "completed")
        // ARCH 3. The leaf signs the record as the other leaves do, so `provenance verify` accepts it
        // and refuses a copy with one value edited.
        let verify = try await Self.runVerify(cli, sidecar)
        XCTAssertEqual(verify.status, 0, verify.stdoutText + verify.stderrText)
        XCTAssertTrue(verify.stdoutText.contains("Signature valid"), verify.stdoutText)
        let tampered = scratch.appendingPathComponent("tampered", isDirectory: true)
        try FileManager.default.createDirectory(at: tampered, withIntermediateDirectories: true)
        let copy = tampered.appendingPathComponent(sidecar.lastPathComponent)
        let text = try String(contentsOf: sidecar, encoding: .utf8)
        try text.replacingOccurrences(of: "\"completed\"", with: "\"failed\"").write(to: copy, atomically: true, encoding: .utf8)
        let refused = try await Self.runVerify(cli, copy, signedBy: sidecar)
        XCTAssertNotEqual(refused.status, 0, "an edited copy still verifies")
        XCTAssertFalse(refused.stdoutText.contains("Signature valid"), refused.stdoutText)
    }

    /// `provenance verify` on `sidecar`, against the signature and public key of `signedBy` when given.
    private static func runVerify(_ cli: URL, _ sidecar: URL, signedBy record: URL? = nil) async throws -> ToolProcessResult {
        var arguments = ["provenance", "verify", sidecar.path]
        if let record {
            arguments += [
                "--signature", ProvenanceSigningConfiguration.signatureURL(for: record).path,
                "--public-key", ProvenanceSigningConfiguration.publicKeyURL(for: record).path,
            ]
        }
        return try await ToolProcess.run(ToolProcessSpec(
            executableURL: cli, arguments: arguments,
            environment: CLISIGTERMHarness.childEnvironment(overriding: [:]), timeout: .seconds(60)
        ))
    }

    func testAMissingQueryFailsWithAnEventAndSubmitsNothing() async throws {
        let cli = try XCTUnwrap(CLISIGTERMHarness.cliBinaryURL(for: Self.self), "build lungfish-cli first")
        let server = try Self.standIn()
        defer { server.stop() }
        let result = try await ToolProcess.run(ToolProcessSpec(
            executableURL: cli,
            arguments: ["blast", "submit", "--query", scratch.appendingPathComponent("missing.fasta").path,
                        "--output", scratch.appendingPathComponent("out").path, "--format", "json"],
            environment: CLISIGTERMHarness.childEnvironment(overriding: [Self.standInVariable: server.baseURL.absoluteString]),
            timeout: .seconds(60)
        ))
        XCTAssertEqual(result.status, 3)
        XCTAssertTrue(result.stdoutText.contains(#""event":"failed""#), result.stdoutText)
        XCTAssertEqual(server.requests.count, 0)
        try Self.recaptureIfAsked("failed", stdout: result.stdoutText, scratch: scratch)
    }

    func testSIGTERMCancelsTheSearchInsideTheGrace() async throws {
        let server = try Self.standIn()
        defer { server.stop() }
        let output = scratch.appendingPathComponent("cancelled", isDirectory: true)
        let run = try CLISIGTERMHarness.launchCLI(
            ["blast", "submit", "--query", try writeQuery().path, "--output", output.path, "--format", "json"],
            environment: [Self.standInVariable: server.baseURL.absoluteString],
            testClass: Self.self
        )
        defer { run.stop() }
        let deadline = ContinuousClock.now + CLISIGTERMHarness.processWait
        while !server.requests.contains(where: { $0.method == "POST" }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(server.requests.contains { $0.method == "POST" }, "the leaf never submitted")
        let stop = await CLISIGTERMHarness.assertSIGTERMCancels(run, record: {
            let names = try FileManager.default.contentsOfDirectory(atPath: output.path)
                .filter { $0.hasPrefix("lungfish-blast-submit-") && $0.hasSuffix(".lungfish-provenance.json") }
            XCTAssertEqual(names.count, 1, "one cancelled record, found \(names)")
            return try names.first.flatMap {
                try ProvenanceEnvelopeReader.load(fromSidecar: output.appendingPathComponent($0))?.status.rawValue
            }
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("blast-result.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("query.fasta").path))
        XCTAssertFalse(stop.standardOutput.contains(#""event":"failed""#), "a cancel reports no failed event")
    }

    /// Writes `stdout` as the transcript `name` when `LUNGFISH_RECAPTURE_CLI_EVENTS=1`, with the
    /// scratch folder rewritten to `/work` in its plain and slash-escaped spellings.
    static func recaptureIfAsked(_ name: String, stdout: String, scratch: URL, file: StaticString = #filePath) throws {
        guard ProcessInfo.processInfo.environment["LUNGFISH_RECAPTURE_CLI_EVENTS"] == "1" else { return }
        var text = stdout
        for root in [scratch.path, scratch.resolvingSymlinksInPath().path] {
            text = text.replacingOccurrences(of: root, with: "/work")
            text = text.replacingOccurrences(of: root.replacingOccurrences(of: "/", with: "\\/"), with: "\\/work")
        }
        let folder = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/cli-events/commands/blast-submit", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: folder.appendingPathComponent("\(name).ndjson"))
    }
}
