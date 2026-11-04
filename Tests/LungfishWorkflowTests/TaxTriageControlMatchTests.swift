// TaxTriageControlMatchTests.swift - Which samples of a TaxTriage result belong to its negative controls
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Lane TTBUILDDB, rows TAXTRIAGE-CONTROL-NAME-PIPELINE-RENAMED and TAXTRIAGE-FAILED-CONTROL-READS-CLEAN.
// `TaxTriageControlMatch` reads each control through the pipeline's renaming, and tells a control that never ran
// or cannot be found from a clean one.

import XCTest
@testable import LungfishWorkflow

final class TaxTriageControlMatchTests: XCTestCase {

    private func sample(_ id: String, control: Bool = false) -> TaxTriageSample {
        TaxTriageSample(
            sampleId: id,
            fastq1: URL(fileURLWithPath: "/nonexistent/\(id).fastq.gz"),
            isNegativeControl: control
        )
    }

    func testControlWithAPlainNameIsFoundAsTyped() {
        let match = TaxTriageControlMatch(
            samples: [sample("S1"), sample("NTC1", control: true)],
            failedSampleIDs: [],
            databaseSampleIds: ["NTC1", "S1"]
        )
        XCTAssertEqual(match.controlSampleIds, ["NTC1"])
        XCTAssertEqual(match.controls.map(\.state), [.found])
        XCTAssertFalse(match.controls[0].isRenamed)
        XCTAssertTrue(match.notes.isEmpty)
        XCTAssertFalse(match.hasUncheckedControl)
    }

    func testControlTypedWithASpaceIsFoundUnderItsPipelineName() {
        let match = TaxTriageControlMatch(
            samples: [sample("S1"), sample("Water (blank)", control: true)],
            failedSampleIDs: [],
            databaseSampleIds: ["S1", "Water_blank"]
        )
        XCTAssertEqual(match.controlSampleIds, ["Water_blank"])
        XCTAssertEqual(match.controls.first?.resultsName, "Water_blank")
        XCTAssertEqual(match.controls.first?.isRenamed, true)
        XCTAssertEqual(match.controls.first?.state, .found)
    }

    /// Two samples whose names meet in one samplesheet are numbered `_T1` and `_T2`, and the match cannot tell
    /// which is which, so both count as controls and the notes say why.
    func testControlNumberedByThePipelineIsFoundUnderEveryNumber() {
        let match = TaxTriageControlMatch(
            samples: [sample("S1"), sample("NTC 1", control: true), sample("NTC_1")],
            failedSampleIDs: [],
            databaseSampleIds: ["S1", "NTC_1_T1", "NTC_1_T2"]
        )
        XCTAssertEqual(match.controlSampleIds, ["NTC_1_T1", "NTC_1_T2"])
        XCTAssertEqual(match.notes.count, 1)
        XCTAssertTrue(match.notes[0].contains("NTC 1 and NTC_1 are both named NTC_1 in the results"), match.notes[0])
        XCTAssertTrue(match.notes[0].contains("treats NTC_1_T1 and NTC_1_T2 as negative controls"), match.notes[0])
    }

    func testNoteNamesBothSamplesThatMeetAndSaysWhatToDo() {
        let match = TaxTriageControlMatch(
            samples: [sample("NTC 1", control: true), sample("NTC_1")],
            failedSampleIDs: [],
            databaseSampleIds: ["NTC_1"]
        )
        XCTAssertEqual(match.controlSampleIds, ["NTC_1"])
        XCTAssertEqual(
            match.notes,
            ["NTC 1 and NTC_1 are both named NTC_1 in the results, so Lungfish cannot tell them apart and treats "
                + "NTC_1 as a negative control. Give each sample a name that stays different once spaces and "
                + "symbols are removed, then run it again."]
        )
    }

    func testNoNoteWhenTheSamplesThatMeetAreAllControlsOrNoneIs() {
        let controls = TaxTriageControlMatch(
            samples: [sample("A b", control: true), sample("A_b", control: true)],
            failedSampleIDs: [],
            databaseSampleIds: ["A_b"]
        )
        XCTAssertTrue(controls.notes.isEmpty)
        let samples = TaxTriageControlMatch(
            samples: [sample("A b"), sample("A_b"), sample("NTC1", control: true)],
            failedSampleIDs: [],
            databaseSampleIds: ["A_b", "NTC1"]
        )
        XCTAssertTrue(samples.notes.isEmpty)
        XCTAssertEqual(samples.controlSampleIds, ["NTC1"])
    }

    /// A number the pipeline would not have written is not a claim on the sample.
    func testNumberedNameOfAControlThatSharesItsNameWithNoOneIsNotClaimed() {
        let match = TaxTriageControlMatch(
            samples: [sample("NTC 1", control: true)],
            failedSampleIDs: [],
            databaseSampleIds: ["NTC_1_T1"]
        )
        XCTAssertTrue(match.controlSampleIds.isEmpty)
        XCTAssertEqual(match.unlistedSampleIds, ["NTC_1_T1"])
    }

    func testControlThatRanAndFoundNothingIsClean() {
        let match = TaxTriageControlMatch(
            samples: [sample("S1"), sample("NTC1", control: true)],
            failedSampleIDs: [],
            databaseSampleIds: ["S1"]
        )
        XCTAssertEqual(match.controls.map(\.state), [.noOrganisms])
        XCTAssertTrue(match.controlSampleIds.isEmpty)
        XCTAssertFalse(match.hasUncheckedControl)
    }

    func testControlThatFailedIsNotChecked() {
        let byTypedName = TaxTriageControlMatch(
            samples: [sample("S1"), sample("NTC 1", control: true)],
            failedSampleIDs: ["NTC 1"],
            databaseSampleIds: ["S1"]
        )
        XCTAssertEqual(byTypedName.controls.map(\.state), [.failed])
        XCTAssertEqual(byTypedName.failedControls.map(\.sampleId), ["NTC 1"])
        XCTAssertTrue(byTypedName.hasUncheckedControl)
        let byPipelineName = TaxTriageControlMatch(
            samples: [sample("S1"), sample("NTC 1", control: true)],
            failedSampleIDs: ["NTC_1"],
            databaseSampleIds: ["S1"]
        )
        XCTAssertEqual(byPipelineName.controls.map(\.state), [.failed])
    }

    func testFailureOfASampleThatIsNotAControlChangesNothing() {
        let match = TaxTriageControlMatch(
            samples: [sample("S1"), sample("S2"), sample("NTC1", control: true)],
            failedSampleIDs: ["S2"],
            databaseSampleIds: ["S1"]
        )
        XCTAssertEqual(match.controls.map(\.state), [.noOrganisms])
        XCTAssertFalse(match.hasUncheckedControl)
    }

    /// The control may hold its organisms under a name nobody listed, so its absence is not a clean control.
    func testControlWithNoRowsBesideUnlistedSamplesIsNotFound() {
        let match = TaxTriageControlMatch(
            samples: [sample("S1"), sample("NTC1", control: true)],
            failedSampleIDs: [],
            databaseSampleIds: ["S1", "S9"]
        )
        XCTAssertEqual(match.controls.map(\.state), [.notFound])
        XCTAssertEqual(match.unlistedSampleIds, ["S9"])
        XCTAssertEqual(match.notFoundControls.map(\.sampleId), ["NTC1"])
        XCTAssertTrue(match.hasUncheckedControl)
    }

    func testControlsAreSortedByTheirTypedNames() {
        let match = TaxTriageControlMatch(
            samples: [sample("NTC2", control: true), sample("NTC1", control: true)],
            failedSampleIDs: [],
            databaseSampleIds: ["NTC1", "NTC2"]
        )
        XCTAssertEqual(match.controls.map(\.sampleId), ["NTC1", "NTC2"])
    }

    func testListing() {
        XCTAssertEqual(TaxTriageControlMatch.listing([]), "")
        XCTAssertEqual(TaxTriageControlMatch.listing(["A"]), "A")
        XCTAssertEqual(TaxTriageControlMatch.listing(["A", "B"]), "A and B")
        XCTAssertEqual(TaxTriageControlMatch.listing(["A", "B", "C"]), "A, B and C")
    }
}
