// FASTQQualityByteCounterTests.swift - The Q20 and Q30 count reads every quality byte as Phred+33
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishPortable

/// Phase 3.0 lane BIN, fix round 2 (BIO-BIN-QIN, N1, S1). The counter once chose its Q20 and Q30 thresholds from the
/// encoding it guessed from the first read. A HiFi import kept with None, whose first read holds no score below Q31 and
/// one at Q72 or above, was guessed to be Phred+64, so the shown Q20 and Q30 counted at Q51 and Q61.
final class FASTQQualityByteCounterTests: XCTestCase {
    func testAFirstReadAboveQ31CountsAsPhred33() throws {
        // 63 bases whose quality bytes run 64 to 126, which is Q31 to Q93 in Phred+33, then 10 bases of `I` (Q40).
        let firstQuality = String(decoding: (64...126).map { UInt8($0) }, as: UTF8.self)
        let text = "@first\n\(String(repeating: "A", count: 63))\n+\n\(firstQuality)\n"
            + "@second\n\(String(repeating: "C", count: 10))\n+\n\(String(repeating: "I", count: 10))\n"

        var counter = FASTQQualityByteCounter()
        try Array(text.utf8).withUnsafeBytes { try counter.consume($0) }
        let fractions = try counter.finish()

        XCTAssertEqual(fractions.baseCount, 73)
        XCTAssertEqual(fractions.q20Count, 73, "every base is Q31 or above, so every base is at Q20")
        XCTAssertEqual(fractions.q30Count, 73, "every base is Q31 or above, so every base is at Q30")
    }
}
