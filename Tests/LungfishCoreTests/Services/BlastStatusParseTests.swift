// BlastStatusParseTests.swift - What a status reply says, and what it does not say
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 3.2 lane BLASTNET, N1 (ARCH-BLAST-RESILIENCE section 5). A page with no Status line is no news, and NCBI's own
// Status=UNKNOWN is NCBI's answer, so the two are different answers. ThereAreHits comes in its own QBlastInfo block on
// READY, and it is the only place NCBI says a search found nothing.

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

        let emptyPage = await service.parseStatusResponse("")
        XCTAssertNotEqual(emptyPage, .unknown, "an empty page is not NCBI saying UNKNOWN")

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
    }
}
