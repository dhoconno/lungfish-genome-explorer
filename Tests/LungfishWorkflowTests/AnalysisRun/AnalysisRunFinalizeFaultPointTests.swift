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
///
/// QA's fault-point test cancels the finalize at each step boundary. The cancelled record keeps the
/// steps that ended, with the digests they took, and drops the finalization's outputs, recorded
/// files, source records and artifacts.
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

    @Test(
        "A cancel at a step boundary of the finalize keeps the steps that ended and nothing else it wrote",
        arguments: 0...3, [false, true]
    )
    func cancelAtAFinalizeStepBoundary(after boundary: Int, throwing: Bool) async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let bundle = fixture.project.appendingPathComponent("Reads/s1.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let probe = FakeToolProbe()
        let recorder = AnalysisRunEventRecorder()
        var tool = Self.batchTool(probe: probe)
        tool.finalizeStopsAfterStep = boundary
        tool.finalizeStop = throwing ? .cancelThenThrow : .cancelThenReturn
        tool.finalizeRecordsKeptFile = true
        tool.sourceBundle = bundle
        let request = fixture.request(groupsSamples: true)

        let started = ContinuousClock.now
        let report = await Task { [tool] in
            await AnalysisRunExecutor.unsigned.execute(tool, request, events: recorder.events)
        }.value

        // The whole run, the cancelled record included, ends well inside the transport's grace.
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(probe.phases == ["plan", "run s1", "run s2", "finalize"])
        #expect(report.status == .cancelled)
        #expect(report.exitCode == 125)
        let folder = try #require(report.analysisDirectory)
        #expect(AnalysisRunRecord.load(from: folder)?.outcome == .cancelled)
        let record = try fixture.record(at: report.recordURL)
        #expect(record.status == .cancelled)
        #expect(record.exitStatus == 125)

        // The units' steps, then the finalize's steps that ended before the cancel, in order.
        #expect(record.steps.map(\.toolName) == Self.stepNames(finalizeSteps: boundary))
        // The run level names only what those steps wrote, so no output of the finalization.
        let written = Self.stepOutputPaths(in: folder, finalizeSteps: boundary)
        #expect(record.steps.flatMap(\.outputs).map(\.path) == written)
        #expect(record.outputs.map(\.path) == written)
        try Self.expectEachStepOutputIsThere(record)
        // No recorded file, and no file of the finalization or of a step that did not run.
        #expect(!record.files.contains { $0.path.hasSuffix("/kept.fastq") })
        #expect(!record.files.contains { $0.checksumSHA256 == FakeAnalysisRunTool.recordedDigest })
        #expect(!record.files.contains { $0.path.hasSuffix("/summary.tsv") })
        let notRun = Set((boundary..<Self.finalizeStepCount).map {
            FakeAnalysisRunTool.finalizeStepURL($0 + 1, in: folder).standardizedFileURL.path
        })
        #expect(!record.files.contains { notRun.contains($0.path) })
        // No source record and no artifact.
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent(AnalysisManifest.filename).path))
        #expect(recorder.snapshot.allSatisfy { $0.artifacts.isEmpty })
        #expect(recorder.snapshot.last?.event == .failed(message: report.message, detail: nil))
    }

    @Test("A finalize that fails after a whole step keeps that step in the failed record")
    func failedFinalizeKeepsTheStepsThatEnded() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let reason = "The fake index could not be built."
        var tool = Self.batchTool(probe: FakeToolProbe())
        tool.finalizeStopsAfterStep = 2
        tool.finalizeStop = .fail(reason)

        let report = await AnalysisRunExecutor.unsigned.execute(tool, fixture.request(groupsSamples: true), events: .discarding)

        #expect(report.status == .failed)
        #expect(report.exitCode == 64)
        #expect(report.message.hasSuffix(reason))
        let folder = try #require(report.analysisDirectory)
        let record = try fixture.record(at: report.recordURL)
        #expect(record.status == .failed)
        #expect(record.steps.map(\.toolName) == Self.stepNames(finalizeSteps: 2))
        #expect(record.outputs.map(\.path) == Self.stepOutputPaths(in: folder, finalizeSteps: 2))
        try Self.expectEachStepOutputIsThere(record)
    }

    // MARK: - Helpers

    /// Each file a step of `record` names is there, with the digest and size that step took of it.
    private static func expectEachStepOutputIsThere(_ record: ProvenanceEnvelope) throws {
        for output in record.steps.flatMap(\.outputs) {
            let taken = try ProvenanceFileDescriptor.file(url: URL(fileURLWithPath: output.path), role: .output)
            #expect(output.checksumSHA256 == taken.checksumSHA256)
            #expect(output.fileSize == taken.fileSize)
        }
    }

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
