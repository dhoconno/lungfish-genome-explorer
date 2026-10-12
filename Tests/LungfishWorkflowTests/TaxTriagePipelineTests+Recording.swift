// TaxTriagePipelineTests+Recording.swift - How a TaxTriage launch hands its record and leaves its scratch
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane A2, review fixes 1 and 5. These cases extend TaxTriagePipelineTests in a file of their
// own, because TaxTriagePipelineTests.swift is over 800 lines and may not grow.

import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

extension TaxTriagePipelineTests {
    /// N5 and N7. A cancelled executor launch leaves its scratch, Nextflow's `-w` folder among it, for the
    /// abandoned-scratch sweep, because its cancelled record is the root record, which the executor writes
    /// after the unit returns. The app's route and every launch that was not cancelled remove it.
    func testACancelledExecutorLaunchLeavesItsScratchForTheSweep() {
        let context = Self.recordingUnitContext()

        XCTAssertEqual(TaxTriageRecording.pipelineSave.scratchDisposition(cancelled: true), .remove)
        XCTAssertEqual(TaxTriageRecording.pipelineSave.scratchDisposition(cancelled: false), .remove)
        XCTAssertEqual(TaxTriageRecording.rootRecord(context).scratchDisposition(cancelled: true), .leaveForSweep)
        XCTAssertEqual(TaxTriageRecording.rootRecord(context).scratchDisposition(cancelled: false), .remove)
        XCTAssertEqual(TaxTriageRecording.unitRecord(context).scratchDisposition(cancelled: true), .leaveForSweep)
        XCTAssertEqual(TaxTriageRecording.unitRecord(context).scratchDisposition(cancelled: false), .remove)
    }

    /// A unit context as `AnalysisRunJournal.unitContext` builds one, with recorders that keep nothing.
    private static func recordingUnitContext() -> AnalysisRunUnitContext {
        AnalysisRunUnitContext(
            rootDirectory: FileManager.default.temporaryDirectory,
            projectURL: nil,
            progress: { _, _ in },
            log: { _, _ in },
            recordInput: { _ in },
            recordStep: { _ in },
            recordOptions: { _ in },
            recordDurableReplayArgv: { _ in },
            recordFailureDetail: { _ in }
        )
    }
}
