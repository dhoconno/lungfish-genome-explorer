// OutputEquivalenceTests+FirstDifference.swift - A failure message shows both sides after the first differing line
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.11 lane B66, carry-in row SW18. `firstDifference` printed the lines after the first difference from
// side A alone, behind the same "=" mark as the lines both sides share, so a failure read as if the two sides
// agreed there. The lines after the difference now carry their own side, `A:` or `B:`. OutputEquivalenceTests
// is past the file-size baseline, so these tests sit in an extension beside it.

import XCTest
@testable import LungfishTestSupport

extension OutputEquivalenceTests {
    func testTheFirstDifferenceShowsBothSidesAfterTheLine() {
        let sideA = ["one", "two", "three-A", "four-A", "five-A", "six-A", "seven-A"].joined(separator: "\n")
        let sideB = ["one", "two", "three-B", "four-B", "five-B", "six-B", "seven-B"].joined(separator: "\n")

        let message = OutputEquivalence.firstDifference(sideA, sideB)

        XCTAssertTrue(message.contains("    A: three-A\n    B: three-B"), "the differing line shows both sides\n\(message)")
        XCTAssertTrue(message.contains("    A: four-A"), "side A's following line carries A:\n\(message)")
        XCTAssertTrue(message.contains("    B: four-B"), "side B's following line carries B:\n\(message)")
        XCTAssertTrue(message.contains("    B: six-B"), "three lines follow on side B\n\(message)")
        XCTAssertFalse(message.contains("= four-A"), "a line of side A after the difference never reads as shared\n\(message)")
    }

    func testTheFirstDifferenceMarksTheEndOfTheShorterSideAfterTheLine() {
        let message = OutputEquivalence.firstDifference("x\nold", "x\nnew\nmore\nlast")

        XCTAssertTrue(message.contains("    A: old\n    B: new"), "the differing line shows both sides\n\(message)")
        XCTAssertTrue(message.contains("    A: <end>\n    B: more"), "side A has ended where side B goes on\n\(message)")
        XCTAssertTrue(message.contains("    A: <end>\n    B: last"), "side A has ended where side B goes on\n\(message)")
    }
}
