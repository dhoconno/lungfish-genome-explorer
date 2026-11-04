// BlastStatusParseTests.swift - What a status reply says, and what it does not say
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane BLASTNET, N1 (ARCH-BLAST-RESILIENCE section 5). A page with no Status line is no news, and NCBI's own
// Status=UNKNOWN is NCBI's answer, so the two are different answers. ThereAreHits comes in its own QBlastInfo block on
// READY, and it is the only place NCBI says a search found nothing.

import LungfishTestSupport
import XCTest
@testable import LungfishCore

final class BlastStatusParseTests: XCTestCase {
    private static func block(_ line: String) -> String {
        "<!--QBlastInfoBegin\n\t\(line)\nQBlastInfoEnd\n-->\n"
    }

    func testNoStatusLineIsNotUnknown() async {
        let service = BlastService()

        let noStatusPage = await service.parseStatusResponse("<html><body>Please wait</body></html>")
        XCTAssertNotEqual(noStatusPage, .unknown, "a page with no Status line is not NCBI saying UNKNOWN")
        XCTAssertEqual(noStatusPage, .noStatusLine)

        let emptyPage = await service.parseStatusResponse("")
        XCTAssertNotEqual(emptyPage, .unknown, "an empty page is not NCBI saying UNKNOWN")
        XCTAssertEqual(emptyPage, .noStatusLine)

        let ncbiSaysUnknown = await service.parseStatusResponse(Self.block("Status=UNKNOWN"))
        XCTAssertEqual(ncbiSaysUnknown, .unknown, "Status=UNKNOWN is the one reply that reads as unknown")
    }

    func testThereAreHitsIsRead() async {
        let service = BlastService()

        let hits = await service.parseStatusResponse(Self.block("Status=READY") + Self.block("ThereAreHits=yes"))
        let noHits = await service.parseStatusResponse(Self.block("Status=READY") + Self.block("ThereAreHits=no"))
        let silent = await service.parseStatusResponse(Self.block("Status=READY"))

        XCTAssertNotEqual(hits, noHits, "READY with hits and READY with none read as different answers")
        XCTAssertNotEqual(noHits, silent, "a reply that says no hits differs from a reply that does not say")
        XCTAssertEqual(hits, .ready(thereAreHits: true))
        XCTAssertEqual(noHits, .ready(thereAreHits: false))
        XCTAssertEqual(silent, .ready(thereAreHits: nil))
    }

    func testAThereAreHitsLineThatSaysNeitherReadsAsNotSaid() async {
        let reply = Self.block("Status=READY") + Self.block("ThereAreHits=perhaps")
        let status = await BlastService().parseStatusResponse(reply)
        XCTAssertEqual(status, .ready(thereAreHits: nil))
    }

    /// Every status answer of the fault stand-in, read through the service's own check on a real connection.
    func testEachStandInAnswerReadsAsItsStatus() async throws {
        let hand = BlastHandClock()
        let server = try BlastFaultStandIn.start(
            scripts: [
                BlastFaultScript(thereAreHits: true),
                BlastFaultScript(thereAreHits: false),
                BlastFaultScript(search: .held),
                BlastFaultScript(search: .failed(words: "CPU usage limit was exceeded")),
                BlastFaultScript(status: [.noStatusLine, .emptyPage, .unknown]),
            ],
            now: { hand.now }
        )
        defer { server.stop() }
        let environment = [BlastServiceEndpoints.standInOriginVariable: server.baseURL.absoluteString]
        let service = BlastService(environment: environment)
        var request = URLRequest(url: server.baseURL.appendingPathComponent("blast/Blast.cgi"))
        request.httpMethod = "POST"
        for _ in 1...5 { _ = try await URLSession.shared.data(for: request) }

        let withHits = try await service.checkStatus(rid: "FAULT1")
        XCTAssertEqual(withHits, .ready(thereAreHits: true))
        let withNone = try await service.checkStatus(rid: "FAULT2")
        XCTAssertEqual(withNone, .ready(thereAreHits: false))
        let held = try await service.checkStatus(rid: "FAULT3")
        XCTAssertEqual(held, .waiting(queuePosition: nil))
        let failed = try await service.checkStatus(rid: "FAULT4")
        XCTAssertEqual(failed, .error(message: "BLAST status: FAILED"))
        let noLine = try await service.checkStatus(rid: "FAULT5")
        XCTAssertEqual(noLine, .noStatusLine)
        let empty = try await service.checkStatus(rid: "FAULT5")
        XCTAssertEqual(empty, .noStatusLine)
        let unknown = try await service.checkStatus(rid: "FAULT5")
        XCTAssertEqual(unknown, .unknown)
    }
}
