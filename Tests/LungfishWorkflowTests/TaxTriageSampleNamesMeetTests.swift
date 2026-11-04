// TaxTriageSampleNamesMeetTests.swift - A run refuses two sample names that the pipeline turns into one name
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane TTCONTROLS, row TAXTRIAGE-NAMES-THAT-MEET-LOSE-ROWS (BIO backlog 5 of the TTBUILDDB review). The pipeline's
// samplesheet check turns `A (1)` and `A_1` into one name, `A_1`. In a batch root each sample runs alone, so the two
// write two folders of one name and `build-db` keeps the first folder's rows and leaves out the second's, with one
// line that nobody reads. The run now refuses the pair at its start, with the names and what to do.

import XCTest
@testable import LungfishWorkflow

final class TaxTriageSampleNamesMeetTests: XCTestCase {

    private func config(_ names: [String]) -> TaxTriageConfig {
        TaxTriageConfig(
            samples: names.map {
                TaxTriageSample(sampleId: $0, fastq1: URL(fileURLWithPath: "/nonexistent/\($0).fastq.gz"), isNegativeControl: false)
            },
            outputDirectory: URL(fileURLWithPath: "/nonexistent/taxtriage-names")
        )
    }

    // MARK: - The refusal

    func testRunRefusesTwoNamesThatBecomeOneNameAndSaysWhichMeet() throws {
        XCTAssertThrowsError(try TaxTriageAnalysisRunTool.refuseInvalidSettings(of: config(["A (1)", "A_1", "B"]))) { error in
            let words = "\(error.localizedDescription) \(error)"
            XCTAssertTrue(words.contains("A (1)"), words)
            XCTAssertTrue(words.contains("A_1"), words)
            XCTAssertTrue(words.contains("Rename"), "the words do not say what to do: \(words)")
        }
    }

    // MARK: - The rule

    func testRuleListsTheNamesThatMeetAndTheNameTheyBecome() {
        let meeting = TaxTriageSample.namesThatMeet(in: ["A (1)", "A 1", "A_1", "B"])
        XCTAssertEqual(meeting.map(\.resultsName), ["A_1"])
        XCTAssertEqual(meeting.first?.typedNames, ["A (1)", "A 1", "A_1"])
    }

    func testRuleLeavesOutExactDuplicatesAndNamesThatBecomeEmpty() {
        XCTAssertEqual(TaxTriageSample.namesThatMeet(in: ["A", "A", "()", "[]"]), [])
    }

    func testWordsNameTheNamesAndSayWhatToDo() throws {
        let words = try XCTUnwrap(TaxTriageSample.namesThatMeetWords(in: ["A (1)", "A_1"]))
        XCTAssertEqual(
            words,
            "A (1) and A_1 become the same name, A_1, once the pipeline removes spaces and symbols, so the results could "
                + "keep only one of them. Rename them so that the names stay different, then run again."
        )
        XCTAssertNil(TaxTriageSample.namesThatMeetWords(in: ["A", "B"]))
    }

    // MARK: - Guards, true at the base and after

    func testRunKeepsRefusingExactlyEqualNames() throws {
        XCTAssertThrowsError(try TaxTriageAnalysisRunTool.refuseInvalidSettings(of: config(["A", "A"]))) { error in
            XCTAssertTrue("\(error.localizedDescription) \(error)".contains("A"), "\(error)")
        }
    }

    func testRunDoesNotRefuseNamesThatStayDifferent() throws {
        XCTAssertNoThrow(try TaxTriageAnalysisRunTool.refuseInvalidSettings(of: config(["A 1", "A 2", "B (1)", "NTC"])))
    }
}
