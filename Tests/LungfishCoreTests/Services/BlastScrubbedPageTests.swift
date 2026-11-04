// BlastScrubbedPageTests.swift - NCBI's own words never carry the contact address into a log, a word or a record
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import LungfishTestSupport
import os
import XCTest
@testable import LungfishCore

/// Phase 3.2 lane BLASTNET, SWIFT review SF1. A gateway or error page can repeat the request line, and the request
/// holds the person's contact address. Whatever of NCBI's page LGE keeps must be clear of it. A stand-in on loopback is
/// the only server here, nothing reaches NCBI, and the address is at example.org.
final class BlastScrubbedPageTests: XCTestCase {
    private static let address = "name@example.org"
    /// Each way a page can repeat the address: plain, form-encoded, in capitals and as HTML entities.
    private static let spellings = [
        "name@example.org", "name%40example.org", "NAME%40EXAMPLE.ORG", "name&#64;example.org", "name&#x40;example.org",
        "name&commat;example.org",
    ]
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("blast-scrubbed-page-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func savedStore() async throws -> BlastContactAddressStore {
        let store = BlastContactAddressStore(file: scratch.appendingPathComponent(BlastContactAddress.fileName))
        try await store.save(Self.address)
        return store
    }

    private func service(on server: LoopbackHTTPStandIn, store: BlastContactAddressStore) -> BlastService {
        BlastService(
            searchShared: BlastSearchShared(contactAddress: store),
            environment: [BlastServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString]
        )
    }

    private func holdsTheAddress(_ text: String) -> Bool {
        Self.spellings.contains { text.range(of: $0, options: .caseInsensitive) != nil }
    }

    func testAStatusErrorPageRepeatingTheAddressIsScrubbed() async throws {
        let store = try await savedStore()
        let asked = OSAllocatedUnfairLock(initialState: 0)
        let server = try LoopbackHTTPStandIn.start { _ in
            let index = asked.withLock { state -> Int in
                defer { state += 1 }
                return state
            }
            return LoopbackHTTPResponse.text(
                "<html><body>Bad gateway for CMD=Get&RID=R1&email=\(Self.spellings[index % Self.spellings.count])</body></html>",
                status: 503
            )
        }
        defer { server.stop() }
        let service = self.service(on: server, store: store)

        for spelling in Self.spellings {
            do {
                _ = try await service.statusOnce(rid: "R1")
                XCTFail("a 503 ends the check (\(spelling))")
            } catch {
                let words = error.localizedDescription
                XCTAssertTrue(words.contains("503"), words)
                XCTAssertFalse(holdsTheAddress(words), "\(spelling) reached the words: \(words)")
            }
        }
        XCTAssertEqual(server.requests.count, Self.spellings.count)
    }

    func testAFetchErrorPageRepeatingTheAddressIsScrubbed() async throws {
        let store = try await savedStore()
        let server = try LoopbackHTTPStandIn.start { _ in
            LoopbackHTTPResponse.text("<html>Not found: GET ...&email=name%40example.org</html>", status: 404)
        }
        defer { server.stop() }

        do {
            _ = try await service(on: server, store: store).fetchOnce(rid: "R1")
            XCTFail("a 404 ends the fetch")
        } catch {
            XCTAssertFalse(holdsTheAddress(error.localizedDescription), error.localizedDescription)
        }
    }

    func testAPutPageRepeatingTheAddressKeepsItsRIDAndLosesTheAddress() async throws {
        let store = try await savedStore()
        let echo = "<p>CMD=Put&email=name%40example.org was sent by name@example.org</p>"
        let posted = OSAllocatedUnfairLock(initialState: 0)
        let server = try LoopbackHTTPStandIn.start { _ in
            let count = posted.withLock { state -> Int in
                state += 1
                return state
            }
            return LoopbackHTTPResponse.text(
                count == 1 ? "<!--QBlastInfoBegin\n    RID = ECHO1\n    RTOE = 30\nQBlastInfoEnd-->\(echo)" : echo
            )
        }
        defer { server.stop() }
        let service = self.service(on: server, store: store)
        let form = Data("CMD=Put".utf8)

        let accepted = try await service.putOnce(form)
        let withoutRID = try await service.putOnce(form)

        guard case .accepted(let submission) = accepted else { return XCTFail("\(accepted)") }
        XCTAssertEqual(submission.rid, "ECHO1", "a page that repeats the address still names the search it started")
        guard case .noRID(let page) = withoutRID else { return XCTFail("\(withoutRID)") }
        XCTAssertFalse(holdsTheAddress(page), "the page LGE keeps: \(page)")
    }
}
