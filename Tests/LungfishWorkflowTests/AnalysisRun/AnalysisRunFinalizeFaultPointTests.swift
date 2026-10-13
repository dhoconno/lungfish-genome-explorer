// AnalysisRunFinalizeFaultPointTests.swift - The finalize's steps in the root record, completed and at each step boundary
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// The root record lists the units' steps and then the finalize's, each in the order it ended
/// (2.10 A18, 2.9 R6). Two units in a batch root each hand over one `fake-classifier` step, and a
/// finalize of three whole steps, `fake-finalize-1` to `fake-finalize-3`, follows them.
@Suite("Analysis run finalize fault points")
struct AnalysisRunFinalizeFaultPointTests {
    /// The whole steps of the finalize in these tests.
    private static let finalizeStepCount = 3
    private static let unitLabels = ["s1", "s2"]

    @Test("A completed run's record lists the units' steps, then the finalize's, in order")
    func completedRecordListsTheUnitsStepsThenTheFinalizes() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let tool = Self.batchTool(probe: FakeToolProbe())

        let report = await AnalysisRunExecutor.unsigned.execute(tool, fixture.request(groupsSamples: true), events: .discarding)

        #expect(report.status == .completed)
        #expect(report.exitCode == 0)
        let folder = try #require(report.analysisDirectory)
        let record = try fixture.record(at: report.recordURL)
        #expect(record.status == .completed)
        #expect(record.steps.map(\.toolName) == Self.stepNames(finalizeSteps: Self.finalizeStepCount))
        #expect(record.steps.flatMap(\.outputs).map(\.path) == Self.stepOutputPaths(in: folder, finalizeSteps: Self.finalizeStepCount))
    }

    // MARK: - Helpers

    /// Two units in a batch root, each with one `fake-classifier` step, and a finalize of
    /// ``finalizeStepCount`` whole steps.
    private static func batchTool(probe: FakeToolProbe) -> FakeAnalysisRunTool {
        var tool = FakeAnalysisRunTool(probe: probe)
        tool.layout = .batchRoot
        tool.units = unitLabels.map { AnalysisRunPlannedUnit(label: $0, value: .complete) }
        tool.finalizeStepCount = finalizeStepCount
        return tool
    }

    /// The tool names of the units' steps and then of the first `finalizeSteps` steps of the finalize.
    private static func stepNames(finalizeSteps: Int) -> [String] {
        unitLabels.map { _ in "fake-classifier" } + (0..<finalizeSteps).map { "fake-finalize-\($0 + 1)" }
    }

    /// The files the units' steps and the first `finalizeSteps` steps of the finalize wrote, in order.
    private static func stepOutputPaths(in folder: URL, finalizeSteps: Int) -> [String] {
        let units = unitLabels.map { folder.appendingPathComponent("\($0)/\($0).kreport") }
        let finalize = (0..<finalizeSteps).map { FakeAnalysisRunTool.finalizeStepURL($0 + 1, in: folder) }
        return (units + finalize).map(\.standardizedFileURL.path)
    }
}
