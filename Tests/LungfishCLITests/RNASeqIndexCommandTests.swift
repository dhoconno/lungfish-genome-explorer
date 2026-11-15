// RNASeqIndexCommandTests.swift - The parse of `rnaseq index` (Phase 5.1 lane RS-INDEX)
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import ArgumentParser
import XCTest
@testable import LungfishCLI

final class RNASeqIndexCommandTests: XCTestCase {
    /// salmon index always runs with `-p 8` (ADJ-SPIKE-BIO item 10), so a thread count the person passes is refused
    /// in words rather than dropped (BIO SF-2 of RS-INDEX).
    func testIndexRefusesThreadsBecauseSalmonAlwaysGetsEight() throws {
        XCTAssertNoThrow(try LungfishCLI.parseAsRoot(["rnaseq", "index", "--set", "x"]))
        for flag in ["--threads", "-t"] {
            XCTAssertThrowsError(try LungfishCLI.parseAsRoot(["rnaseq", "index", "--set", "x", flag, "4"]), flag) { error in
                let words = LungfishCLI.message(for: error)
                XCTAssertTrue(words.contains("8 threads"), words)
                XCTAssertTrue(words.contains("--threads"), words)
            }
        }
    }
}
