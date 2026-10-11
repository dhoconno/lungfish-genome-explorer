// AnalysisRunFailureDetailTests.swift - The failed line carries the one failing unit's bounded detail
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// A unit hands the executor its failure detail through `recordFailureDetail`, and the executor
/// sends it, bounded and cleaned, as the `detail` of the run's `failed` line only when that unit's
/// failure is the run's one failure (2.7 A8d review fix 1, UX D11).
@Suite("Analysis run failure detail")
struct AnalysisRunFailureDetailTests {
    // MARK: - Which runs carry it

    @Test("A one-unit failure carries the unit's detail, bounded, and no record holds it")
    func oneUnitFailureCarriesTheBoundedDetail() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let recorder = AnalysisRunEventRecorder()
        var tool = FakeAnalysisRunTool(probe: FakeToolProbe())
        tool.units = [AnalysisRunPlannedUnit(label: "s1", value: .fail("the tool stopped"))]
        tool.failureDetails = ["s1": "first line\r\n\u{1B}[31msecond line\u{1B}[0m\n\n   \nthird\rline"]

        let report = await AnalysisRunExecutor.unsigned.execute(tool, fixture.request(), events: recorder.events)

        #expect(report.status == .failed)
        #expect(report.exitCode == AnalysisRunExitCode.workflowError)
        #expect(report.message == "the tool stopped")
        #expect(recorder.snapshot.last?.event == .failed(
            message: "the tool stopped",
            detail: "first line\nsecond line\nthird\nline"
        ))
        let record = try fixture.record(at: report.recordURL)
        #expect(record.stderr == "the tool stopped", "the detail is written into no record")
    }

    @Test("A unit that records a detail and throws carries it")
    func aThrowingUnitCarriesItsDetail() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let recorder = AnalysisRunEventRecorder()
        var tool = FakeAnalysisRunTool(probe: FakeToolProbe())
        tool.units = [AnalysisRunPlannedUnit(label: "s1", value: .throwError("thrown"))]
        tool.failureDetails = ["s1": "the log's last line"]

        let report = await AnalysisRunExecutor.unsigned.execute(tool, fixture.request(), events: recorder.events)

        #expect(report.exitCode == AnalysisRunExitCode.workflowError)
        #expect(recorder.snapshot.last?.event == .failed(message: "thrown", detail: "the log's last line"))
    }

    @Test("A cancel carries no detail and exits 125")
    func aCancelCarriesNoDetail() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let probe = FakeToolProbe()
        let recorder = AnalysisRunEventRecorder()
        var tool = FakeAnalysisRunTool(probe: probe)
        tool.units = [AnalysisRunPlannedUnit(label: "s1", value: .requestCancelThenFail("killed by the cancel", throwing: false))]
        tool.failureDetails = ["s1": "the child's last line"]
        let executor = AnalysisRunExecutor(services: AnalysisRunServices(
            writer: ProvenanceWriter(signingProvider: nil),
            cancelRequested: { probe.cancelRequested }
        ))

        let report = await executor.execute(tool, fixture.request(), events: recorder.events)

        #expect(report.status == .cancelled)
        #expect(report.exitCode == AnalysisRunExitCode.cancelled)
        #expect(recorder.snapshot.last?.event == .failed(message: report.message, detail: nil))
    }

    @Test("A batch whose every unit failed carries no detail")
    func aBatchWhereEveryUnitFailedCarriesNone() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let recorder = AnalysisRunEventRecorder()
        var tool = FakeAnalysisRunTool(probe: FakeToolProbe())
        tool.terminalPolicy = .warnOnFailedUnits
        tool.layout = .batchRoot
        tool.units = [
            AnalysisRunPlannedUnit(label: "s1", value: .fail("first reason")),
            AnalysisRunPlannedUnit(label: "s2", value: .fail("second reason")),
        ]
        tool.failureDetails = ["s1": "first tail", "s2": "second tail"]

        let report = await AnalysisRunExecutor.unsigned.execute(
            tool,
            fixture.request(groupsSamples: true),
            events: recorder.events
        )

        #expect(report.status == .failed)
        #expect(recorder.snapshot.last?.event == .failed(message: "None of the 2 runs completed.", detail: nil))
    }

    @Test("A batch that stops at its first failed unit carries that unit's detail")
    func aFailRunBatchCarriesTheFailingUnitsDetail() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let probe = FakeToolProbe()
        let recorder = AnalysisRunEventRecorder()
        var tool = FakeAnalysisRunTool(probe: probe)
        tool.layout = .batchRoot
        tool.units = [
            AnalysisRunPlannedUnit(label: "s1", value: .complete),
            AnalysisRunPlannedUnit(label: "s2", value: .fail("second reason")),
            AnalysisRunPlannedUnit(label: "s3", value: .complete),
        ]
        tool.failureDetails = ["s1": "the completed unit's text", "s2": "second tail"]

        let report = await AnalysisRunExecutor.unsigned.execute(
            tool,
            fixture.request(groupsSamples: true),
            events: recorder.events
        )

        #expect(probe.phases == ["plan", "run s1", "run s2"])
        #expect(recorder.snapshot.last?.event == .failed(message: "s2 failed: second reason", detail: "second tail"))
    }

    @Test("A completed run, and a failed finalize, carry no detail a unit recorded")
    func aCompletedRunOrAFailedFinalizeCarriesNone() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let completedRecorder = AnalysisRunEventRecorder()
        var tool = FakeAnalysisRunTool(probe: FakeToolProbe())
        tool.failureDetails = ["s1": "text a completed unit recorded"]

        let completed = await AnalysisRunExecutor.unsigned.execute(tool, fixture.request(), events: completedRecorder.events)

        #expect(completed.status == .completed)
        #expect(!completedRecorder.snapshot.contains { line in
            if case .failed? = line.event { return true }
            return false
        })

        let finalizeRecorder = AnalysisRunEventRecorder()
        tool.finalizeError = "the summary could not be written"
        let failedFinalize = await AnalysisRunExecutor.unsigned.execute(tool, fixture.request(), events: finalizeRecorder.events)

        #expect(failedFinalize.status == .failed)
        #expect(finalizeRecorder.snapshot.last?.event == .failed(message: failedFinalize.message, detail: nil))
    }

    // MARK: - Bounds

    @Test("Carriage returns become line breaks")
    func carriageReturns() {
        #expect(AnalysisRunFailureDetail.bounded("a\rb\r\nc\n") == "a\nb\nc")
    }

    @Test("Colour codes and other control characters go, tabs stay")
    func colourAndControlCharacters() {
        #expect(AnalysisRunFailureDetail.bounded("\u{1B}[1;31mred\u{1B}[0m text") == "red text")
        #expect(AnalysisRunFailureDetail.bounded("bell\u{07} nul\u{00}\tafter a tab\u{7F}") == "bell nul\tafter a tab")
    }

    @Test("Blank lines go")
    func blankLines() {
        #expect(AnalysisRunFailureDetail.bounded("a\n   \n\t\n\nb") == "a\nb")
    }

    @Test("Of 21 lines the last 20 stay")
    func twentyOneLines() {
        let lines = (1...21).map { "line \($0)" }
        #expect(AnalysisRunFailureDetail.bounded(lines.joined(separator: "\n")) == lines.dropFirst().joined(separator: "\n"))
    }

    @Test("A long line is cut to 400 characters")
    func aLongLine() {
        let detail = AnalysisRunFailureDetail.bounded(String(repeating: "é", count: 450))
        #expect(detail == String(repeating: "é", count: 400))
    }

    @Test("Whole leading lines go until the detail fits in 4096 bytes")
    func theByteCap() throws {
        let lines = (0..<20).map { index in String(repeating: Character(String(UnicodeScalar(UInt8(65 + index)))), count: 400) }
        let detail = try #require(AnalysisRunFailureDetail.bounded(lines.joined(separator: "\n")))
        // Ten lines of 400 bytes and nine breaks take 4009 bytes, and eleven would take 4410.
        #expect(detail == lines.suffix(10).joined(separator: "\n"))
        #expect(detail.utf8.count <= AnalysisRunFailureDetail.byteLimit)
    }

    @Test("Text that is only whitespace leaves no detail")
    func whitespaceOnly() {
        #expect(AnalysisRunFailureDetail.bounded("  \n\t\r\n \r") == nil)
        #expect(AnalysisRunFailureDetail.bounded("") == nil)
    }
}
