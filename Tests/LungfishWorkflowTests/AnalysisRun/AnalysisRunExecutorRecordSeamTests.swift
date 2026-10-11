// AnalysisRunExecutorRecordSeamTests.swift - Metadata only under Analyses, a unit's replay argv, and no deleted run-level file
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// The three executor rules lane A8 of Phase 2.7 needs for Kraken2. A claimed folder gets
/// `analysis-metadata.json` only directly in a project's `Analyses/` folder (decision E1b), a unit
/// can name the replay argv it learned while it ran, such as the command with a virtual bundle
/// replaced by its kept materialization, and the root record never names a run-level file that the
/// run removed, such as the per-read output a later step compressed.
@Suite("Analysis run executor record seams")
struct AnalysisRunExecutorRecordSeamTests {

    @Test("A named folder in a project but outside Analyses gets a run record and no metadata")
    func namedFolderOutsideAnalysesGetsNoMetadata() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let target = fixture.project.appendingPathComponent("Results/kraken2-run", isDirectory: true)

        let report = await AnalysisRunExecutor.unsigned.execute(
            SeamProbeTool(sawRunRecord: SeenFlag()),
            fixture.request(.directory(target)),
            events: .discarding
        )

        #expect(report.status == .completed)
        #expect(AnalysesFolder.readAnalysisMetadata(from: target) == nil)
        #expect(AnalysesFolder.isAnalysisIncomplete(target) == false)
    }

    @Test("A named folder directly in Analyses gets metadata")
    func namedFolderInAnalysesGetsMetadata() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let seen = SeenFlag()
        let target = fixture.project.appendingPathComponent("Analyses/kraken2-golden", isDirectory: true)

        let report = await AnalysisRunExecutor.unsigned.execute(
            SeamProbeTool(sawRunRecord: seen),
            fixture.request(.directory(target)),
            events: .discarding
        )

        #expect(report.status == .completed)
        #expect(seen.value, "the folder carried its run record while the unit ran")
        #expect(AnalysesFolder.readAnalysisMetadata(from: target)?.tool == "kraken2")
    }

    @Test("A unit's replay argv replaces the request's, also in a failed run")
    func unitReplayArgvReplacesTheRequests() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let replay = ["lungfish-cli", "kraken2", "classify", "/kept/materialized.fastq"]

        for fails in [false, true] {
            let target = fixture.root.appendingPathComponent("replay-\(fails)", isDirectory: true)
            var request = fixture.request(.directory(target))
            request.durableReplayArgv = ["from", "the", "request"]
            let report = await AnalysisRunExecutor.unsigned.execute(
                SeamProbeTool(sawRunRecord: SeenFlag(), replayArgv: replay, fails: fails),
                request,
                events: .discarding
            )

            #expect(report.status == (fails ? .failed : .completed))
            #expect(try fixture.record(at: report.recordURL).durableReplayArgv == replay)
        }
    }

    @Test("The request's replay argv stays when no unit records one")
    func requestReplayArgvStays() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        var request = fixture.request(.directory(fixture.root.appendingPathComponent("plain", isDirectory: true)))
        request.durableReplayArgv = ["from", "the", "request"]

        let report = await AnalysisRunExecutor.unsigned.execute(
            SeamProbeTool(sawRunRecord: SeenFlag()),
            request,
            events: .discarding
        )

        #expect(try fixture.record(at: report.recordURL).durableReplayArgv == ["from", "the", "request"])
    }

    @Test("A file a step wrote and the run removed leaves the run level and stays on the step")
    func removedStepOutputLeavesTheRunLevel() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let target = fixture.root.appendingPathComponent("compacted", isDirectory: true)

        let report = await AnalysisRunExecutor.unsigned.execute(
            SeamProbeTool(sawRunRecord: SeenFlag()),
            fixture.request(.directory(target)),
            events: .discarding
        )

        let record = try fixture.record(at: report.recordURL)
        let raw = target.appendingPathComponent("classification.kraken").standardizedFileURL.path
        let kept = target.appendingPathComponent("classification.kraken.gz").standardizedFileURL.path
        #expect(record.steps.first?.outputs.map(\.path).contains(raw) == true)
        #expect(!record.files.map(\.path).contains(raw))
        #expect(!record.outputs.map(\.path).contains(raw))
        #expect(record.outputs.map(\.path).contains(kept))
    }
}

/// Whether the folder held its run record while the unit ran.
private final class SeenFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = false

    var value: Bool {
        lock.withLock { seen }
    }

    func set(_ value: Bool) {
        lock.withLock { seen = value }
    }
}

/// One unit that writes a per-read output, compresses it and removes the original, records a step
/// naming both, and records a replay argv when given one.
private struct SeamProbeTool: AnalysisRunTool {
    let sawRunRecord: SeenFlag
    var replayArgv: [String]?
    var fails = false

    var identity: AnalysisRunIdentity {
        AnalysisRunIdentity(toolID: AnalysisToolID(rawValue: "kraken2"), workflowName: "lungfish.seam-probe")
    }

    func plan(_ request: AnalysisRunRequest, context: AnalysisRunPlanningContext) async throws -> AnalysisRunPlan<String> {
        AnalysisRunPlan(layout: .singleFolder, units: [AnalysisRunPlannedUnit(label: "s1", value: "s1")])
    }

    func run(_ unit: AnalysisRunUnit<String>, context: AnalysisRunUnitContext) async throws -> AnalysisUnitOutcome<URL> {
        sawRunRecord.set(AnalysisRunRecord.load(from: unit.directory) != nil)
        if let replayArgv {
            context.recordDurableReplayArgv(replayArgv)
        }
        let raw = unit.directory.appendingPathComponent("classification.kraken")
        let compressed = unit.directory.appendingPathComponent("classification.kraken.gz")
        try "C\tr1\t1\t4\t1:4\n".write(to: raw, atomically: true, encoding: .utf8)
        try "compressed\n".write(to: compressed, atomically: true, encoding: .utf8)
        let started = Date()
        context.recordStep(ProvenanceStep(
            toolName: "kraken2",
            toolVersion: "2.17.1",
            argv: ["kraken2", "--output", raw.path],
            outputs: [
                try ProvenanceFileDescriptor.file(url: raw, format: .text, role: .output),
                try ProvenanceFileDescriptor.file(url: compressed, format: .text, role: .output),
            ],
            exitStatus: 0,
            wallTimeSeconds: 0,
            startedAt: started,
            completedAt: started
        ))
        try FileManager.default.removeItem(at: raw)
        return fails ? .failed(reason: "The probe failed.") : .completed(compressed)
    }

    func finalize(_ units: [AnalysisUnitReport<URL>], context: AnalysisRunFinalizeContext) async throws -> AnalysisRunFinalization {
        AnalysisRunFinalization(outputs: units.compactMap(\.outcome.result).map { AnalysisRunOutput(url: $0) })
    }
}
