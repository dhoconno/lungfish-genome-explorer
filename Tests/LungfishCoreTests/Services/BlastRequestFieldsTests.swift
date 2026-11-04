// BlastRequestFieldsTests.swift - The fields, the session and the contact address of BLAST's requests
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishTestSupport
import os
import XCTest
@testable import LungfishCore

/// Phase 3.2 lane BLASTNET, milestone N5 (ARCH-BLAST-RESILIENCE section 9, BIO-BLAST-TIES item 3, UX-BLAST-WORDS Q6).
/// A stand-in on loopback is the only server here, nothing reaches NCBI, and every address is at example.org.
final class BlastRequestFieldsTests: XCTestCase {
    private static let noReplyEncoded = "lungfish-app%40users.noreply.github.com"
    private static let waitingPage = "<!--QBlastInfoBegin\n    Status=WAITING\nQBlastInfoEnd-->"
    private static let readyPage = "<!--QBlastInfoBegin\n    Status=READY\n    ThereAreHits=no\nQBlastInfoEnd-->"
    private static let rejectedAddresses = [
        "person@example", "@example.org", "person@", "person name@example.org", "person@@example.org",
        "first@example.org,second@example.org", "Person <person@example.org>", "person@.org", "person@example.",
        "", "   ", "person@example.org\nBcc: other@example.org", "person@ex\u{E4}mple.org",
    ]
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-request-fields-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func service(on server: LoopbackHTTPStandIn) -> BlastService {
        BlastService(environment: [BlastServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString])
    }

    private func headerValues(_ name: String, in request: LoopbackHTTPRequest) -> [String] {
        request.headerLines.compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].caseInsensitiveCompare(name) == .orderedSame else { return nil }
            return parts[1].trimmingCharacters(in: .whitespaces)
        }
    }

    private func email(in request: BlastRecordedRequest) -> String? {
        request.queryItems.first { $0.name == "email" }?.value
    }

    // MARK: Field names

    func testFormIsTheFieldsNCBINames() async throws {
        let client = BlastRecordingClient()
        let service = BlastService(httpClient: client)
        let form = service.putFormBody(
            query: ">read_1\nACGT", program: "blastn", database: "core_nt", entrezQuery: nil, evalue: 1e-10,
            maxTargetSeqs: 5, megablast: true, extraParameters: [:]
        )
        XCTAssertEqual(
            form.split(separator: "&").map { String($0.prefix { $0 != "=" }) },
            ["CMD", "PROGRAM", "DATABASE", "QUERY", "EXPECT", "HITLIST_SIZE", "MAX_NUM_SEQ", "FORMAT_TYPE", "WORD_SIZE", "tool", "MEGABLAST"],
            "NCBI's page names tool in lowercase, and the address goes on at each POST and never into the saved form"
        )
        XCTAssertTrue(form.contains("&HITLIST_SIZE=5&MAX_NUM_SEQ=5&"), "BIO-BLAST-TIES item 3 keeps the two equal")

        _ = try await service.statusOnce(rid: "R1")
        _ = try await service.fetchOnce(rid: "R1")
        let sent = await client.requests
        XCTAssertEqual(sent.count, 2)
        for request in sent {
            let names = request.queryItems.map(\.name)
            XCTAssertEqual(names.suffix(2), ["tool", "email"], "\(names)")
            XCTAssertFalse(names.contains("TOOL") || names.contains("EMAIL"), "\(names)")
        }
    }

    func testEachContactReadsTheAddressAnew() async throws {
        let store = BlastContactAddressStore(file: scratch.appendingPathComponent(BlastContactAddress.fileName))
        let client = BlastRecordingClient()
        let service = BlastService(httpClient: client, searchShared: BlastSearchShared(contactAddress: store))
        let form = Data("CMD=Put".utf8)

        _ = try await service.putOnce(form)
        try await store.save("first@example.org")
        _ = try await service.statusOnce(rid: "R1")
        _ = try await service.putOnce(form)
        try await store.save("second@example.org")
        _ = try await service.fetchOnce(rid: "R1")

        let sent = await client.requests
        XCTAssertEqual(sent.count, 4)
        XCTAssertEqual(sent[0].body, "CMD=Put&email=\(Self.noReplyEncoded)", "with no address NCBI gets the no-reply one")
        XCTAssertEqual(email(in: sent[1]), "first@example.org")
        XCTAssertEqual(sent[2].body, "CMD=Put&email=first%40example.org")
        XCTAssertEqual(email(in: sent[3]), "second@example.org")
    }

    // MARK: The rule and the store

    func testContactAddressRule() {
        let accepted = ["person@example.org", "first.last@lab.example.edu", "name+tag@example.org", "o'neil@example.org"]
        for address in accepted {
            XCTAssertEqual(BlastContactAddress.accepted(address), address)
            XCTAssertEqual(BlastContactAddress.reading(of: address), .valid, address)
        }
        XCTAssertEqual(BlastContactAddress.accepted("  person@example.org \n"), "person@example.org", "spaces around it are trimmed")
        XCTAssertEqual(Self.rejectedAddresses.count + accepted.count + 1, 18, "the 18 forms of UX-BLAST-WORDS Q6")
        for address in Self.rejectedAddresses {
            XCTAssertNil(BlastContactAddress.accepted(address), address)
        }
        XCTAssertEqual(BlastContactAddress.reading(of: "   "), .empty)
        XCTAssertEqual(BlastContactAddress.reading(of: "person@example"), .notValid)

        let domain = String(repeating: "a", count: 60) + "." + String(repeating: "b", count: 60) + "."
            + String(repeating: "c", count: 60) + ".example.org"
        let local = String(repeating: "p", count: 254 - 1 - domain.count)
        XCTAssertEqual(BlastContactAddress.accepted("\(local)@\(domain)")?.count, 254, "254 characters is the limit")
        XCTAssertNil(BlastContactAddress.accepted("\(local)p@\(domain)"), "255 characters is past the limit")
    }

    func testTheWordsSayWhatEachReadingDoes() {
        XCTAssertTrue(BlastContactAddress.Words.state(.empty).contains("no-reply"))
        XCTAssertTrue(BlastContactAddress.Words.state(.valid).contains("sends this address"))
        XCTAssertTrue(BlastContactAddress.Words.state(.notValid).contains("name@example.org"))
        XCTAssertTrue(
            BlastContactAddress.Words.caption.contains(
                "LGE keeps it in your Storage Location, so a new location starts with none, and never in project files, records, logs or replay commands."
            ),
            "the address lives under the Storage Location, and the caption says so"
        )
    }

    func testSaveFailedWordsStayOneSentenceWhateverTheReasonEndsWith() {
        for reason in ["You do not have permission.", "Operation not permitted"] {
            let words = BlastContactAddress.Words.saveFailed(reason)
            XCTAssertFalse(words.contains(".."), words)
            XCTAssertTrue(words.contains("Storage Location"), words)
            XCTAssertTrue(words.hasSuffix("available."), words)
        }
    }

    func testASaveThatCannotBeWrittenThrowsAndKeepsTheOldAddress() async throws {
        let folder = scratch.appendingPathComponent("kept", isDirectory: true)
        let store = BlastContactAddressStore(file: folder.appendingPathComponent(BlastContactAddress.fileName))
        try await store.save("old@example.org")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }

        do {
            try await store.save("new@example.org")
            XCTFail("a folder nobody can write to keeps the old address")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
        let kept = await store.savedText()
        XCTAssertEqual(kept, "old@example.org")

        let file = scratch.appendingPathComponent("a-file")
        try Data("x".utf8).write(to: file)
        let blocked = BlastContactAddressStore(file: file.appendingPathComponent("blast/\(BlastContactAddress.fileName)"))
        do {
            try await blocked.save("new@example.org")
            XCTFail("a folder path that is a file cannot hold the address")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testTheStoreKeepsTheAddressPrivateAndNeverServesABadOne() async throws {
        let file = scratch.appendingPathComponent("blast/\(BlastContactAddress.fileName)")
        let store = BlastContactAddressStore(file: file)

        let empty = await store.addressInForce()
        XCTAssertNil(empty, "no file is no address")
        try await store.save(" person@example.org ")
        let trimmed = await store.addressInForce()
        XCTAssertEqual(trimmed, "person@example.org")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600, "no other account reads it")

        let bad = "Person <person@example.org>"
        try await store.save(bad)
        let shown = await store.savedText()
        XCTAssertEqual(shown, bad, "the row shows what the person wrote")
        let served = await store.addressInForce()
        XCTAssertNil(served, "a saved invalid value is never sent")

        try await store.save("   ")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "clearing the row removes the address")
        try await store.save("")
    }

    func testBlastParamLeavesTheAddressToSettings() {
        for token in ["EMAIL=person@example.org", "email=person@example.org", "TOOL=other", "tool=other", "EMAIL="] {
            XCTAssertThrowsError(try BlastVerificationRequest.parseBlastURLAPIExtraParameters(token), token) { error in
                XCTAssertEqual(error.localizedDescription, BlastContactAddress.Words.parameterRefusal, token)
            }
        }
        XCTAssertEqual(try BlastVerificationRequest.parseBlastURLAPIExtraParameters("NOHEADER=true"), ["NOHEADER": "true"])
    }

    // MARK: BLAST's own session

    func testNoCookieHeaderIsSent() async throws {
        let server = try LoopbackHTTPStandIn.start { _ in
            var response = LoopbackHTTPResponse.text(Self.waitingPage)
            response.headerLines = ["Set-Cookie: ncbi_sid=STANDIN00000000_0000SID; Path=/; Max-Age=3600"]
            return response
        }
        defer { server.stop() }
        let service = self.service(on: server)

        _ = try await service.statusOnce(rid: "R1")
        _ = try await service.statusOnce(rid: "R2")
        _ = try await service.putOnce(Data("CMD=Put".utf8))

        XCTAssertEqual(server.requests.count, 3)
        for request in server.requests {
            XCTAssertEqual(headerValues("Cookie", in: request), [], "\(request.method) \(request.target)")
        }
    }

    func testWireHeadersAreTheOnesWeChose() async throws {
        let server = try LoopbackHTTPStandIn.start { _ in LoopbackHTTPResponse.text(Self.waitingPage) }
        defer { server.stop() }
        let service = self.service(on: server)

        _ = try await service.statusOnce(rid: "R1")
        _ = try await service.putOnce(Data("CMD=Put".utf8))

        XCTAssertEqual(server.requests.count, 2)
        for request in server.requests {
            XCTAssertEqual(headerValues("User-Agent", in: request), ["lungfish"], "\(request.method) names no version or system")
            XCTAssertEqual(headerValues("Accept-Language", in: request), ["en"], "\(request.method) names no language of this Mac")
        }
    }

    func testStatusReplyWithNCBIHeadersIsNotServedFromCache() async throws {
        let answered = OSAllocatedUnfairLock(initialState: 0)
        let server = try LoopbackHTTPStandIn.start { _ in
            let count = answered.withLock { state -> Int in
                state += 1
                return state
            }
            var response = LoopbackHTTPResponse.text(count == 1 ? Self.waitingPage : Self.readyPage)
            response.headerLines = [
                "Cache-Control: public, max-age=3600",
                "Expires: Fri, 01 Jan 2100 00:00:00 GMT",
                "Last-Modified: Thu, 01 Jan 2026 00:00:00 GMT",
                "ETag: \"stand-in\"",
            ]
            return response
        }
        defer { server.stop() }
        let service = self.service(on: server)

        let first = try await service.statusOnce(rid: "R1")
        let second = try await service.statusOnce(rid: "R1")

        XCTAssertTrue(first.page.contains("Status=WAITING"), first.page)
        XCTAssertEqual(server.requests.count, 2, "each check goes out")
        XCTAssertTrue(second.page.contains("Status=READY"), second.page)
        for request in server.requests {
            XCTAssertEqual(headerValues("If-None-Match", in: request), [], "a check asks for the page and not whether it changed")
        }
    }

    // MARK: The ZIP route, which BLAST-RESULT-ZIP left as it is

    /// A pin. It carries a reply as wide as BIO-BLAST-TIES sets, 500 records, so a failure here brings the row back.
    func testAZipReplyStillParses() async throws {
        let hits = (1...500).map { index in
            #"{"description":[{"accession":"A\#(index).1","title":"t","sciname":"Influenza A virus","taxid":11320}],"#
                + #""hsps":[{"bit_score":140.0,"evalue":1e-30,"identity":76,"align_len":76,"query_from":1,"query_to":76}]}"#
        }
        let report = #"{"BlastOutput2":{"report":{"results":{"search":{"query_title":"read_1","query_len":76,"hits":["#
            + hits.joined(separator: ",") + "]}}}}}"
        let manifest = scratch.appendingPathComponent("R1.json")
        let entry = scratch.appendingPathComponent("R1_1.json")
        let archive = scratch.appendingPathComponent("R1.zip")
        try Data(#"{"BlastJSON":[{"$ref":"R1_1.json"}]}"#.utf8).write(to: manifest)
        try Data(report.utf8).write(to: entry)
        let zipped = try await ToolProcess.run(ToolProcessSpec(
            executableURL: URL(fileURLWithPath: "/usr/bin/zip"),
            arguments: ["-q", "-j", archive.path, manifest.path, entry.path],
            environment: ["PATH": "/usr/bin:/bin"],
            timeout: .seconds(30)
        ))
        XCTAssertEqual(zipped.status, 0, zipped.stderrText)
        let body = try Data(contentsOf: archive)
        XCTAssertEqual(Array(body.prefix(2)), [0x50, 0x4B], "the reply is an archive")
        let server = try LoopbackHTTPStandIn.start { _ in LoopbackHTTPResponse(contentType: "application/zip", body: body) }
        defer { server.stop() }

        let results = try await service(on: server).getResults(rid: "R1")

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.hits.count, 500, "every record of a wide reply comes through the archive")
    }
}
