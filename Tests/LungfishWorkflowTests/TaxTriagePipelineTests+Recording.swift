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

    /// ARCH 3 and 5. On the executor route the root record takes the TaxTriage step and its inputs from the
    /// recorder's run. A run the recorder does not hold fails, instead of leaving a completed root record with
    /// no `taxtriage` step and no inputs, as the app's route fails on a record it cannot save.
    func testARootRecordWithNoRecordedRunFailsInsteadOfDroppingItsSteps() async throws {
        let folder = try TestTempDirectory.make(prefix: "taxtriage-root-record")
        defer { TestTempDirectory.cleanup(folder) }

        do {
            try await TaxTriagePipeline.shared.finishTaxTriageRecord(
                recording: .rootRecord(Self.recordingUnitContext()),
                runID: UUID(),
                outputDirectory: folder,
                description: "completed run",
                exitCode: 0,
                stderr: "",
                logFile: nil
            )
            XCTFail("a root record with no recorded run returned instead of failing the run")
        } catch let error as TaxTriagePipelineError {
            guard case .pipelineFailed = error else {
                return XCTFail("the run failed with \(error), not pipelineFailed")
            }
        }
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
