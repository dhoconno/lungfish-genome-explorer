// BlastContactAddressChildTests.swift - The built `blast submit` sending the contact address to the wire and nowhere else
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishCore
import LungfishTestSupport
import LungfishWorkflow
import XCTest

/// Phase 3.2 lane BLASTNET, milestone N5 (O132, ARCH-PLAN item 23, UX-BLAST-WORDS Q6). The address is a sentinel at
/// example.org in the child's own state folder, the stand-in is the only server, and a scaled clock spends every wait.
final class BlastContactAddressChildTests: XCTestCase {
    private static let fastClock = 600.0
    private static let noReply = "lungfish-app@users.noreply.github.com"
    private static let noReplyEncoded = "lungfish-app%40users.noreply.github.com"
    private var scratch: URL!
    private var token: String!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-contact-child-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        token = "contact-sentinel-\(UUID().uuidString.lowercased())"
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private var state: URL {
        scratch.appendingPathComponent("state", isDirectory: true)
    }

    private var sentinel: String {
        "\(token!)@example.org"
    }

    private func output(_ name: String = "result") -> URL {
        scratch.appendingPathComponent(name, isDirectory: true)
    }

    private func save(_ address: String) async throws {
        try await BlastContactAddressStore(file: state.appendingPathComponent(BlastContactAddress.fileName)).save(address)
    }

    /// `blast submit` on the stand-in, as the record's replay would run it. A throwaway key signs the record, so its
    /// provenance is written and read here too.
    private func child(_ server: BlastFaultStandIn, into name: String = "result") throws -> ToolProcessSpec {
        let cli = try XCTUnwrap(CLISIGTERMHarness.cliBinaryURL(for: Self.self), "build lungfish-cli first")
        let query = scratch.appendingPathComponent("query-\(name).fasta")
        try Data(">read_1\nACGTACGTAC\n>read_2\nGGCCTTAAGG\n".utf8).write(to: query)
        return ToolProcessSpec(
            executableURL: cli,
            arguments: ["blast", "submit", "--query", query.path, "--output", output(name).path, "--format", "json", "--name", "SecretLabel"],
            environment: CLISIGTERMHarness.childEnvironment(overriding: [
                "LUNGFISH_BLAST_STAND_IN_ORIGIN": server.baseURL.absoluteString,
                "LUNGFISH_BLAST_STAND_IN_STATE": state.path,
                "LUNGFISH_BLAST_STAND_IN_TIME_SCALE": String(Self.fastClock),
                "LUNGFISH_PROVENANCE_SIGNING_KEY": "lane-n5-sign-throwaway-\(UUID().uuidString)",
            ]),
            timeout: .seconds(60)
        )
    }

    /// The name of each file under `folder` that holds the token, apart from the address's own file.
    private func filesHoldingTheToken(under folder: URL) throws -> [String] {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])?.allObjects as? [URL] ?? []
        return try files.filter { file in
            guard file.lastPathComponent != BlastContactAddress.fileName,
                  try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { return false }
            return try Data(contentsOf: file).range(of: Data(token.utf8)) != nil
        }.map(\.lastPathComponent)
    }

    private func assertHeldNowhere(
        _ result: ToolProcessResult, spec: ToolProcessSpec, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertFalse(result.stdoutText.contains(token), "the events and so the row's log", file: file, line: line)
        XCTAssertFalse(result.stderrText.contains(token), "the row's log", file: file, line: line)
        XCTAssertFalse(spec.arguments.joined(separator: " ").contains(token), "the row's cliCommand", file: file, line: line)
        for name in ["blast-result.json", "blast-result.json.lungfish-provenance.json", "blast-search.json", "put-form.txt"] {
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: output().appendingPathComponent(name).path),
                "\(name) was written, so the look below read it", file: file, line: line
            )
        }
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: state.appendingPathComponent("search-log.tsv").path),
            "search-log.tsv was written, so the look below read it", file: file, line: line
        )
        XCTAssertEqual(try filesHoldingTheToken(under: output()), [], "the project folder, record and replay", file: file, line: line)
        XCTAssertEqual(try filesHoldingTheToken(under: state), [], "the shared files", file: file, line: line)
    }

    /// Each POST ends with the address, with its form-encoded value, and each GET names it, as NCBI's parser reads it.
    private func assertEveryContactCarries(
        _ plain: String, encoded: String, on server: BlastFaultStandIn, file: StaticString = #filePath, line: UInt = #line
    ) {
        let posts = server.requests.filter { $0.method == "POST" }
        let gets = server.requests.filter { $0.method == "GET" }
        XCTAssertFalse(posts.isEmpty, file: file, line: line)
        XCTAssertGreaterThanOrEqual(gets.count, 2, "a check and a fetch", file: file, line: line)
        for post in posts {
            let body = String(decoding: post.body, as: UTF8.self)
            XCTAssertTrue(body.hasSuffix("&email=\(encoded)"), String(body.suffix(80)), file: file, line: line)
            XCTAssertEqual(body.components(separatedBy: "email=").count, 2, "one address", file: file, line: line)
        }
        for get in gets {
            XCTAssertEqual(get.queryItems.first { $0.name == "email" }?.value, plain, get.target, file: file, line: line)
        }
    }

    func testTheAddressReachesOnlyTheWire() async throws {
        try await save(sentinel)
        let server = try BlastFaultStandIn.start(scripts: [BlastFaultScript()], timeScale: Self.fastClock)
        defer { server.stop() }
        let spec = try child(server)

        let result = try await ToolProcess.run(spec)

        XCTAssertEqual(result.status, 0, result.stderrText)
        assertEveryContactCarries(sentinel, encoded: "\(token!)%40example.org", on: server)
        try assertHeldNowhere(result, spec: spec)
    }

    func testContactAddressNeverReachesProjectRecordLogOrReplay() async throws {
        try await save(sentinel)
        let script = BlastFaultScript(
            put: [.http(status: 503), .droppedAfterSending],
            status: [.http(status: 503), .noStatusLine, .dropped],
            result: [.html]
        )
        let server = try BlastFaultStandIn.start(scripts: [script], timeScale: Self.fastClock)
        defer { server.stop() }
        let spec = try child(server)

        let result = try await ToolProcess.run(spec)

        XCTAssertEqual(result.status, 0, result.stderrText)
        XCTAssertGreaterThanOrEqual(server.requests.filter { $0.method == "POST" }.count, 3, "the busy and lost Puts were read")
        assertEveryContactCarries(sentinel, encoded: "\(token!)%40example.org", on: server)
        try assertHeldNowhere(result, spec: spec)
    }

    /// NCBI's own words are the one open path (SWIFT review SF1). A page that repeats the request ends the search, and
    /// the words it ends with, the search file, the failed record, the events and the log are all clear of the address.
    func testNCBIRepeatingTheAddressNeverReachesWordsOrTheSearchFile() async throws {
        try await save(sentinel)
        let echoed = "<html><body>Bad request: CMD=Put&amp;email=\(token!)%40example.org was refused for \(sentinel).</body></html>"
        let server = try BlastFaultStandIn.start(
            scripts: [BlastFaultScript(put: [.noRID(page: echoed)])], timeScale: Self.fastClock
        )
        defer { server.stop() }
        let spec = try child(server)

        let result = try await ToolProcess.run(spec)

        XCTAssertNotEqual(result.status, 0, "a page with no request ID ends the search")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: output().appendingPathComponent("blast-search.json").path),
            "blast-search.json was written, so the look below read it"
        )
        XCTAssertFalse(result.stdoutText.contains(token), "the events and so the row's log")
        XCTAssertFalse(result.stderrText.contains(token), "the words a person reads")
        XCTAssertFalse(spec.arguments.joined(separator: " ").contains(token), "the row's cliCommand")
        XCTAssertEqual(try filesHoldingTheToken(under: output()), [], "the search file, the failed record and the replay")
        XCTAssertEqual(try filesHoldingTheToken(under: state), [], "the shared files and the search log")
    }

    func testContactAddressWithPlusReachesNCBIIntact() async throws {
        let address = "\(token!)+tag@example.org"
        try await save(address)
        let server = try BlastFaultStandIn.start(scripts: [BlastFaultScript()], timeScale: Self.fastClock)
        defer { server.stop() }

        let result = try await ToolProcess.run(try child(server))

        XCTAssertEqual(result.status, 0, result.stderrText)
        assertEveryContactCarries(
            // The raw target holds %2B, which `queryItems` hands back as a plus. A raw plus would read as a space to NCBI.
            address, encoded: "\(token!)%2Btag%40example.org", on: server
        )
        for get in server.requests where get.method == "GET" {
            XCTAssertTrue(get.target.contains("\(token!)%2Btag"), get.target)
            XCTAssertFalse(get.target.contains("\(token!)+tag"), "a form parser reads a raw plus as a space: \(get.target)")
        }
    }

    func testNoAddressOrABadOneSendsTheNoReplyAddress() async throws {
        let server = try BlastFaultStandIn.start(timeScale: Self.fastClock)
        defer { server.stop() }

        let unset = try await ToolProcess.run(try child(server, into: "unset"))
        XCTAssertEqual(unset.status, 0, unset.stderrText)
        assertEveryContactCarries(Self.noReply, encoded: Self.noReplyEncoded, on: server)

        try await save("Person <\(sentinel)>")
        let bad = try await ToolProcess.run(try child(server, into: "bad"))
        XCTAssertEqual(bad.status, 0, bad.stderrText)
        assertEveryContactCarries(Self.noReply, encoded: Self.noReplyEncoded, on: server)
        XCTAssertFalse(
            server.requests.contains { $0.target.contains(token) || String(decoding: $0.body, as: UTF8.self).contains(token) },
            "a saved invalid value is never sent"
        )
    }
}
