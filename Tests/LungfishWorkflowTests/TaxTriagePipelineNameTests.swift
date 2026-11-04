// TaxTriagePipelineNameTests.swift - The name the TaxTriage pipeline gives a sample
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane TTBUILDDB, row TAXTRIAGE-CONTROL-NAME-PIPELINE-RENAMED. `TaxTriageSample.pipelineName(of:)` does what
// `RowChecker._validate_sample` of `bin/check_samplesheet.py` does, and the table below is what that script
// wrote when it ran on each name, one name to a samplesheet (jhuapl-bio/taxtriage at e10bfebda32a, the revision
// third-party-tools-lock.json pins). A bump of the pin runs the script on these names again.

import XCTest
@testable import LungfishWorkflow

final class TaxTriagePipelineNameTests: XCTestCase {

    /// The name given and the name the pinned script wrote for it.
    private static let scriptTable: [(given: String, written: String)] = [
        ("NTC.1", "NTC.1"),
        ("NTC 1", "NTC_1"),
        ("Water (blank)", "Water_blank"),
        ("Blank [A]", "Blank_A"),
        ("Neg#1 100%", "Neg1_100"),
        ("A&B+C", "ABC"),
        ("Ctrl!@$^`~;", "Ctrl"),
        ("a,b", "ab"),
        ("q\"x*y?z<w>v|u", "qxyzwvu"),
        ("back\\slash", "backslash"),
        ("col:on", "colon"),
        ("sl/ash", "slash"),
        ("brace{a}", "bracea"),
        (" lead", "_lead"),
        ("trail ", "trail_"),
        ("\tlead", "lead"),
        ("trail\t", "trail"),
        ("nb\u{00A0}", "nb"),
        ("\u{00A0}nb", "nb"),
        ("\u{3000}ideo\u{3000}", "ideo"),
        ("mid\tdle", "mid\tdle"),
        ("caf\u{00E9} \u{00FC}ber", "caf\u{00E9}_\u{00FC}ber"),
        ("()", ""),
        ("\t", ""),
        ("us\u{001F}", "us"),
        ("\u{001F}us", "us"),
        ("em\u{2003}", "em"),
        ("e\u{0301} (a)", "e\u{0301}_a"),
        ("a  b", "a__b"),
    ]

    func testNamesAreWhatThePinnedSamplesheetCheckWrote() {
        let wrong = Self.scriptTable.compactMap { entry -> String? in
            let name = TaxTriageSample.pipelineName(of: entry.given)
            return name == entry.written ? nil : "[\(entry.given)] became [\(name)], the script wrote [\(entry.written)]"
        }
        XCTAssertTrue(wrong.isEmpty, wrong.joined(separator: "\n"))
    }

    /// Each of the 27 characters the script removes, with letters on both sides.
    func testEachRemovedCharacterIsRemoved() {
        let removed = "/\\:*?\"<>|()[]{}#%&+!@$^`~;,"
        XCTAssertEqual(removed.unicodeScalars.count, 27)
        let kept = removed.unicodeScalars.compactMap { scalar -> String? in
            let name = TaxTriageSample.pipelineName(of: "a\(Character(scalar))b")
            return name == "ab" ? nil : "[\(scalar)] left [\(name)]"
        }
        XCTAssertTrue(kept.isEmpty, kept.joined(separator: "\n"))
    }

    /// A space becomes an underscore, and no other character does.
    func testEachSpaceBecomesAnUnderscore() {
        XCTAssertEqual(TaxTriageSample.pipelineName(of: "a b c"), "a_b_c")
        XCTAssertEqual(TaxTriageSample.pipelineName(of: "a\tb"), "a\tb")
    }

    /// Letters, digits, dots, hyphens, underscores, apostrophes and letters of any script stay as they are.
    func testNamesWithNoRemovedCharacterAreKept() {
        for name in ["NTC1", "NTC.1", "NTC-1", "NTC_1", "o'neil", "S=1", "caf\u{00E9}", "\u{6C34}\u{5BF9}\u{7167}", "a1.b-2_c"] {
            XCTAssertEqual(TaxTriageSample.pipelineName(of: name), name, name)
        }
    }

    /// The name is not changed again when the pipeline's rule runs on its own result, except for the leading
    /// underscore that a leading space left.
    func testRuleIsStable() {
        for entry in Self.scriptTable where !entry.written.hasPrefix("_") && !entry.written.hasSuffix("_") {
            XCTAssertEqual(TaxTriageSample.pipelineName(of: entry.written), entry.written, entry.given)
        }
    }
}
