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

    func testNotesTellWhenTheSamplesThatMeetAreAllControlsOrNoneIsAndTheResultsHoldFewer() {
        let words = "A b and A_b are both named A_b in the results, and the results hold only one sample"
        let controls = TaxTriageControlMatch(
            samples: [sample("A b", control: true), sample("A_b", control: true)],
            failedSampleIDs: [],
            databaseSampleIds: ["A_b"]
        )
        XCTAssertEqual(controls.notes.count, 1, "\(controls.notes)")
        XCTAssertTrue(controls.notes.joined().contains(words), "\(controls.notes)")
        let samples = TaxTriageControlMatch(
            samples: [sample("A b"), sample("A_b"), sample("NTC1", control: true)],
            failedSampleIDs: [],
            databaseSampleIds: ["A_b", "NTC1"]
        )
        XCTAssertEqual(samples.notes.count, 1, "\(samples.notes)")
        XCTAssertTrue(samples.notes.joined().contains(words), "\(samples.notes)")
        XCTAssertEqual(samples.controlSampleIds, ["NTC1"])
    }

    /// Nothing is left out when the results hold every sample that meets, under the numbered names the pipeline gives
    /// them, or when the sample that is missing is one the run lists as failed.
    func testNoNoteWhenTheResultsHoldEverySampleThatMeetsOrTheMissingOneFailed() {
        let both = TaxTriageControlMatch(
            samples: [sample("A b"), sample("A_b"), sample("NTC1", control: true)],
            failedSampleIDs: [],
            databaseSampleIds: ["A_b_T1", "A_b_T2", "NTC1"]
        )
        XCTAssertTrue(both.notes.isEmpty, "\(both.notes)")
        let failedOne = TaxTriageControlMatch(
            samples: [sample("A b"), sample("A_b")],
            failedSampleIDs: ["A b"],
            databaseSampleIds: ["A_b"]
        )
        XCTAssertTrue(failedOne.notes.isEmpty, "\(failedOne.notes)")
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

    // MARK: - A control that was not fully checked (3.2 TTNOTCHECKED)

    /// The entry the parser writes: the whole tag is the task label and the sample is the tag cut at its first dot.
    private func ignored(_ process: String, tag: String) -> TaxTriageIgnoredFailure {
        TaxTriageIgnoredFailure(
            processPath: "NFCORE_TAXTRIAGE:TAXTRIAGE:\(process)",
            processName: process,
            taskLabel: tag,
            sampleID: tag.split(separator: ".").first.map(String.init),
            exitCode: 137
        )
    }

    /// A control with rows and a step the pipeline skipped keeps what it lists, but a No for an organism it does not list
    /// is not known, so the match counts it as not fully checked. The note names the cause once.
    func testControlWithRowsAndASkippedStepIsNotChecked() {
        let match = TaxTriageControlMatch(
            samples: [sample("S1"), sample("NTC1", control: true)],
            failedSampleIDs: [],
            ignoredFailures: [ignored("MINIMAP2_ALIGN", tag: "NTC1")],
            databaseSampleIds: ["NTC1", "S1"]
        )
        XCTAssertEqual(match.controls.map(\.state), [.found])
        XCTAssertEqual(match.controlSampleIds, ["NTC1"], "what the control holds stays a Yes")
        XCTAssertTrue(match.hasUncheckedControl, "a control with a skipped step was counted as fully checked")
        XCTAssertEqual(match.uncheckedWords, "Contamination risk is only partly checked.")
        XCTAssertEqual(match.notes.count, 1, "\(match.notes)")
        XCTAssertTrue(match.notes[0].contains("(MINIMAP2_ALIGN)"), match.notes[0])
    }

    /// The same for a control whose name has a dot, which the parser cuts at its first dot.
    func testControlWithADottedNameAndASkippedStepIsNotChecked() {
        let match = TaxTriageControlMatch(
            samples: [sample("S1"), sample("NTC.1", control: true)],
            failedSampleIDs: [],
            ignoredFailures: [ignored("MINIMAP2_ALIGN", tag: "NTC.1")],
            databaseSampleIds: ["NTC.1", "S1"]
        )
        XCTAssertEqual(match.controls.map(\.state), [.found])
        XCTAssertTrue(match.hasUncheckedControl)
    }

    /// Two typed names that the pipeline makes one name, where the results hold fewer samples than the run lists, leave a
    /// control whose rows may be the ones that were dropped. A control that meets a sample is the same.
    func testControlsWhoseNamesMetAndLostRowsAreNotChecked() {
        let controls = TaxTriageControlMatch(
            samples: [sample("S1"), sample("NTC 1", control: true), sample("NTC_1", control: true)],
            failedSampleIDs: [],
            databaseSampleIds: ["NTC_1", "S1"]
        )
        XCTAssertEqual(controls.controls.map(\.state), [.found, .found])
        XCTAssertEqual(controls.controlSampleIds, ["NTC_1"], "what the kept control holds stays a Yes")
        XCTAssertTrue(controls.hasUncheckedControl, "two controls became one and the results hold one")
        XCTAssertEqual(controls.uncheckedWords, "Contamination risk is only partly checked.")
        let mixed = TaxTriageControlMatch(
            samples: [sample("S1"), sample("NTC 1", control: true), sample("NTC_1")],
            failedSampleIDs: [],
            databaseSampleIds: ["NTC_1", "S1"]
        )
        XCTAssertTrue(mixed.hasUncheckedControl, "a control met a sample and the results hold one of the two")
    }

    // MARK: - Guards, true at the base and after

    /// FASTQC, MULTIQC and NANOPLOT only draw quality plots, so a control that has rows and lost a plot is checked.
    func testQualityPlotStepOfAControlLeavesItChecked() {
        for process in ["FASTQC", "MULTIQC", "NANOPLOT"] {
            let match = TaxTriageControlMatch(
                samples: [sample("S1"), sample("NTC1", control: true)],
                failedSampleIDs: [],
                ignoredFailures: [ignored(process, tag: "NTC1")],
                databaseSampleIds: ["NTC1", "S1"]
            )
            XCTAssertFalse(match.hasUncheckedControl, process)
            XCTAssertNil(match.uncheckedWords, process)
            XCTAssertTrue(match.notes.isEmpty, "\(process): \(match.notes)")
        }
    }

    /// A skipped step of another sample says nothing about the control.
    func testSkippedStepOfAnotherSampleLeavesAFoundControlChecked() {
        let match = TaxTriageControlMatch(
            samples: [sample("S1"), sample("NTC1", control: true)],
            failedSampleIDs: [],
            ignoredFailures: [ignored("MINIMAP2_ALIGN", tag: "S1")],
            databaseSampleIds: ["NTC1", "S1"]
        )
        XCTAssertFalse(match.hasUncheckedControl)
    }

    /// Names that meet leave nothing out when the results hold every sample that meets, or when the sets that meet hold no
    /// control, so a control with rows stays checked.
    func testNamesThatMeetLeaveAControlCheckedWhenNoRowIsLeftOutOrNoControlIsAmongThem() {
        let allHeld = TaxTriageControlMatch(
            samples: [sample("S1"), sample("NTC 1", control: true), sample("NTC_1")],
            failedSampleIDs: [],
            databaseSampleIds: ["S1", "NTC_1_T1", "NTC_1_T2"]
        )
        XCTAssertFalse(allHeld.hasUncheckedControl, "both names are held under their numbers")
        let samplesOnly = TaxTriageControlMatch(
            samples: [sample("A b"), sample("A_b"), sample("NTC1", control: true)],
            failedSampleIDs: [],
            databaseSampleIds: ["A_b", "NTC1"]
        )
        XCTAssertEqual(samplesOnly.notes.count, 1, "\(samplesOnly.notes)")
        XCTAssertFalse(samplesOnly.hasUncheckedControl, "the control is not among the names that meet")
    }

    func testListing() {
        XCTAssertEqual(TaxTriageControlMatch.listing([]), "")
        XCTAssertEqual(TaxTriageControlMatch.listing(["A"]), "A")
        XCTAssertEqual(TaxTriageControlMatch.listing(["A", "B"]), "A and B")
        XCTAssertEqual(TaxTriageControlMatch.listing(["A", "B", "C"]), "A, B and C")
    }
}
