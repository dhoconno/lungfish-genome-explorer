// AnalysisRunExecutorTests.swift - Phase order, folders, records, events and outcomes of the analysis run executor
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// The executor runs the phases in order, makes or claims the folder, writes the root record
/// last and settles the run record (2.7 A6, ARCH 2.2, E1, E4, E5, E13).
@Suite("Analysis run executor")
struct AnalysisRunExecutorTests {
    private static let readSetPlan: ParameterValue = .dictionary([
        "capability": .string("pairsOrSinglesPerRun"),
        "pairedFragments": .integer(23),
        "mergedReads": .integer(77),
    ])

    @Test("The phases run in order and the root record is written last")
    func phasesRunInOrder() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let probe = FakeToolProbe()
        var tool = FakeAnalysisRunTool(probe: probe)
        tool.readSetPlan = Self.readSetPlan
        let request = fixture.request()

        let report = await AnalysisRunExecutor.unsigned.execute(tool, request, events: .discarding)

        #expect(probe.phases == ["plan", "run s1", "finalize"])
        #expect(probe.fact("analysesEmptyAtPlan") == true)
        #expect(probe.fact("folderExistsAtRun") == true)
        #expect(probe.fact("metadataAtRun") == true)
        #expect(probe.fact("runRecordAtRun") == true)
        #expect(probe.fact("rootRecordAtRun") == false)
        #expect(probe.fact("runRecordAtFinalize") == true)

        let folder = try #require(report.analysisDirectory)
        #expect(folder.deletingLastPathComponent().lastPathComponent == "Analyses")
        #expect(folder.lastPathComponent.hasPrefix("kraken2-2"))
        #expect(report.status == .completed)
        #expect(report.exitCode == 0)
        #expect(report.warnings.isEmpty)
        #expect(report.message == "1 of 1 samples classified")
        #expect(report.recordURL == FakeAnalysisRunTool.recordURL(in: folder))

        let record = try fixture.record(at: report.recordURL)
        #expect(record.workflowName == FakeAnalysisRunTool.workflowName)
        #expect(record.argv == request.commandLine)
        #expect(record.status == .completed)
        #expect(record.exitStatus == 0)
        #expect(record.options.explicit["threads"] == .integer(2))
        #expect(record.options.resolvedDefaults["readSetPlan"] == Self.readSetPlan)
        #expect(record.options.resolvedDefaults["confidence"] == .number(0.1))
        #expect(record.steps.map(\.toolName) == ["fake-classifier", "fake-index"])
        #expect(record.outputs.contains { $0.path.hasSuffix("summary.tsv") })
        #expect(record.files.contains { $0.path.hasSuffix("s1.input.fastq") && $0.role == .input })

        #expect(AnalysesFolder.isAnalysisIncomplete(folder) == false)
        #expect(AnalysesFolder.readAnalysisMetadata(from: folder)?.tool == "kraken2")
        #expect(AnalysesFolder.readAnalysisMetadata(from: folder)?.isBatch == false)
        #expect(try AnalysesFolder.listAnalyses(in: fixture.project).map(\.url.lastPathComponent) == [folder.lastPathComponent])
    }

    @Test("Events follow the phases and end with complete")
    func eventsFollowThePhases() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let recorder = AnalysisRunEventRecorder()
        var tool = FakeAnalysisRunTool(probe: FakeToolProbe())
        tool.units = [AnalysisRunPlannedUnit(label: "s1", value: .progress([0.5]))]

        let report = await AnalysisRunExecutor.unsigned.execute(tool, fixture.request(), events: recorder.events)

        let folder = try #require(report.analysisDirectory)
        #expect(recorder.names == ["start", "output", "progress", "progress", "complete"])
        let lines = recorder.snapshot
        #expect(lines[1].event == .output(path: folder.path, role: AnalysisRunEvents.Role.analysisDirectory))
        #expect(lines.last?.event == .complete(outputs: [folder.path], message: "1 of 1 samples classified"))
        #expect(lines.last?.artifacts.map(\.role) == ["summary", CLIEventArtifact.Role.provenance])
        #expect(lines.last?.artifacts.last?.path == report.recordURL?.path)
        for line in lines {
            let data = try JSONEncoder().encode(line)
            #expect(try JSONDecoder().decode(CLIEventLine.self, from: data) == line)
        }
    }

    @Test("A named folder inside a project is claimed, given metadata and completed")
    func namedFolderInsideAProjectIsClaimed() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let probe = FakeToolProbe()
        let target = fixture.project.appendingPathComponent("Analyses/classify-run", isDirectory: true)

        let report = await AnalysisRunExecutor.unsigned.execute(
            FakeAnalysisRunTool(probe: probe),
            fixture.request(.directory(target)),
            events: .discarding
        )

        #expect(report.status == .completed)
        #expect(report.analysisDirectory == target.standardizedFileURL)
        #expect(probe.fact("runRecordAtRun") == true)
        #expect(probe.fact("metadataAtRun") == true)
        #expect(AnalysesFolder.isAnalysisIncomplete(target) == false)
        #expect(AnalysesFolder.readAnalysisMetadata(from: target)?.tool == "kraken2")
        #expect(try fixture.record(at: report.recordURL).status == .completed)
    }

    @Test("A named folder outside every project gets metadata and no run record")
    func namedFolderOutsideAProjectGetsMetadata() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let probe = FakeToolProbe()
        let target = fixture.root.appendingPathComponent("plain-output", isDirectory: true)

        let report = await AnalysisRunExecutor.unsigned.execute(
            FakeAnalysisRunTool(probe: probe),
            fixture.request(.directory(target)),
            events: .discarding
        )

        #expect(report.status == .completed)
        #expect(probe.fact("runRecordAtRun") == false)
        #expect(AnalysesFolder.readAnalysisMetadata(from: target)?.tool == "kraken2")
        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("s1.kreport").path))
    }

    @Test("The project folder itself is refused before anything is written")
    func projectFolderIsRefused() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let probe = FakeToolProbe()

        let report = await AnalysisRunExecutor.unsigned.execute(
            FakeAnalysisRunTool(probe: probe),
            fixture.request(.directory(fixture.project)),
            events: .discarding
        )

        #expect(report.status == .failed)
        #expect(report.analysisDirectory == nil)
        #expect(probe.phases == ["plan"])
        #expect(AnalysesFolder.readAnalysisMetadata(from: fixture.project) == nil)
    }

    @Test("A failed unit keeps the folder hidden with a failed root record")
    func failedUnitKeepsTheFolderHidden() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let probe = FakeToolProbe()
        let recorder = AnalysisRunEventRecorder()
        let bundle = fixture.project.appendingPathComponent("Reads/s1.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        var tool = FakeAnalysisRunTool(probe: probe)
        tool.units = [AnalysisRunPlannedUnit(label: "s1", value: .fail("kraken2 exited with status 2"))]
        tool.sourceBundle = bundle

        let report = await AnalysisRunExecutor.unsigned.execute(tool, fixture.request(), events: recorder.events)

        #expect(report.status == .failed)
        #expect(report.exitCode == 64)
        #expect(report.message == "kraken2 exited with status 2")
        #expect(probe.phases == ["plan", "run s1"])
        let folder = try #require(report.analysisDirectory)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(AnalysisRunRecord.load(from: folder)?.outcome == .failed)
        #expect(try AnalysesFolder.listAnalyses(in: fixture.project).isEmpty)
        #expect(AnalysesFolder.incompleteAnalysisRuns(in: fixture.project).map(\.directory.lastPathComponent) == [folder.lastPathComponent])

        let record = try fixture.record(at: report.recordURL)
        #expect(record.status == .failed)
        #expect(record.exitStatus == 64)
        #expect(record.argv == fixture.request().commandLine)
        #expect(record.stderr == "kraken2 exited with status 2")
        #expect(record.files.contains { $0.path.hasSuffix("s1.input.fastq") })
        #expect(recorder.snapshot.last?.event == .failed(message: "kraken2 exited with status 2", detail: nil))
        #expect(!FileManager.default.fileExists(atPath: bundle.appendingPathComponent(AnalysisManifest.filename).path))
    }

    @Test("A unit that throws fails the run with the error's description")
    func throwingUnitFailsTheRun() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        var tool = FakeAnalysisRunTool(probe: FakeToolProbe())
        tool.units = [AnalysisRunPlannedUnit(label: "s1", value: .throwError("database receipt is unreadable"))]

        let report = await AnalysisRunExecutor.unsigned.execute(tool, fixture.request(), events: .discarding)

        #expect(report.status == .failed)
        #expect(report.message == "database receipt is unreadable")
        #expect(try fixture.record(at: report.recordURL).status == .failed)
    }

    @Test("A plan that fails leaves no folder")
    func failedPlanLeavesNoFolder() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let recorder = AnalysisRunEventRecorder()
        var tool = FakeAnalysisRunTool(probe: FakeToolProbe())
        tool.planError = "The database digest does not match its receipt."

        let report = await AnalysisRunExecutor.unsigned.execute(tool, fixture.request(), events: recorder.events)

        #expect(report.status == .failed)
        #expect(report.exitCode == 64)
        #expect(report.analysisDirectory == nil)
        #expect(report.recordURL == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent("Analyses").path))
        #expect(recorder.names == ["start", "failed"])
    }

    @Test("A plan with no unit and a request with no command fail before any folder")
    func emptyPlanAndMissingCommandFail() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        var tool = FakeAnalysisRunTool(probe: FakeToolProbe())
        tool.units = []
        let empty = await AnalysisRunExecutor.unsigned.execute(tool, fixture.request(), events: .discarding)
        #expect(empty.status == .failed)
        #expect(empty.message == AnalysisRunError.emptyPlan(AnalysisToolID(rawValue: "kraken2")).errorDescription)

        var request = fixture.request()
        request.commandLine = []
        let unnamed = await AnalysisRunExecutor.unsigned.execute(FakeAnalysisRunTool(probe: FakeToolProbe()), request, events: .discarding)
        #expect(unnamed.status == .failed)
        #expect(unnamed.analysisDirectory == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.project.appendingPathComponent("Analyses").path))
    }

    @Test("A unit that completes with a warning completes the run with a warning line")
    func warningUnitCompletesWithAWarningLine() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let recorder = AnalysisRunEventRecorder()
        var tool = FakeAnalysisRunTool(probe: FakeToolProbe())
        let reason = "Bracken profiling degraded at resolved rank G: too few reads"
        tool.units = [AnalysisRunPlannedUnit(label: "s1", value: .warn(reason))]

        let report = await AnalysisRunExecutor.unsigned.execute(tool, fixture.request(), events: recorder.events)

        #expect(report.status == .completed)
        #expect(report.exitCode == 0)
        #expect(report.warnings == [reason])
        #expect(recorder.snapshot.contains { $0.event == .log(level: .warning, message: reason) })
        #expect(recorder.names.last == "complete")
        let record = try fixture.record(at: report.recordURL)
        #expect(record.status == .completed)
        #expect(record.exitStatus == 0)
        #expect(record.stderr == reason)
        #expect(AnalysesFolder.isAnalysisIncomplete(try #require(report.analysisDirectory)) == false)
    }

    @Test("A batch runs every unit in its own folder and warns for the failed one")
    func batchWarnsForTheFailedUnit() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let probe = FakeToolProbe()
        let bundle = fixture.project.appendingPathComponent("Reads/s1.lungfishfastq", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        var tool = FakeAnalysisRunTool(probe: probe)
        tool.terminalPolicy = .warnOnFailedUnits
        tool.layout = .batchRoot
        tool.sourceBundle = bundle
        tool.units = [
            AnalysisRunPlannedUnit(label: "sample 1", value: .complete),
            AnalysisRunPlannedUnit(label: "s2", value: .fail("boom")),
            AnalysisRunPlannedUnit(label: "s3", value: .complete),
        ]

        let report = await AnalysisRunExecutor.unsigned.execute(tool, fixture.request(groupsSamples: true), events: .discarding)

        let folder = try #require(report.analysisDirectory)
        #expect(folder.lastPathComponent.hasPrefix("kraken2-batch-"))
        #expect(AnalysesFolder.readAnalysisMetadata(from: folder)?.isBatch == true)
        #expect(probe.phases == ["plan", "run sample 1", "run s2", "run s3", "finalize"])
        #expect(probe.sampleNames == ["sample_1", "s2", "s3"])
        #expect(probe.finalizedOutcomes == ["sample 1=completed", "s2=failed", "s3=completed"])
        for name in ["sample_1", "s2", "s3"] {
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path))
        }
        #expect(report.status == .completed)
        #expect(report.warnings == ["s2 failed: boom"])
        #expect(report.message == "2 of 3 samples classified")
        #expect(try fixture.record(at: report.recordURL).steps.filter { $0.toolName == "fake-classifier" }.count == 2)

        let history = AnalysisManifestStore.load(bundleURL: bundle, projectURL: fixture.project)
        #expect(history.analyses.map(\.analysisDirectoryName) == [folder.lastPathComponent])
        #expect(history.analyses.first?.status == .completed)
    }

    @Test("The default policy stops a batch at the failed unit")
    func defaultPolicyStopsTheBatch() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let probe = FakeToolProbe()
        var tool = FakeAnalysisRunTool(probe: probe)
        tool.layout = .batchRoot
        tool.units = [
            AnalysisRunPlannedUnit(label: "s1", value: .complete),
            AnalysisRunPlannedUnit(label: "s2", value: .fail("boom")),
            AnalysisRunPlannedUnit(label: "s3", value: .complete),
        ]

        let report = await AnalysisRunExecutor.unsigned.execute(tool, fixture.request(groupsSamples: true), events: .discarding)

        #expect(probe.phases == ["plan", "run s1", "run s2"])
        #expect(report.status == .failed)
        #expect(report.message == "s2 failed: boom")
        #expect(report.warnings.isEmpty)
        #expect(try fixture.record(at: report.recordURL).stderr == "s2 failed: boom")
    }

    @Test("A unit's progress maps onto the run")
    func unitProgressMapsOntoTheRun() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let recorder = AnalysisRunEventRecorder()
        var tool = FakeAnalysisRunTool(probe: FakeToolProbe())
        tool.layout = .batchRoot
        tool.units = [
            AnalysisRunPlannedUnit(label: "s1", value: .progress([0.5, 2, .nan])),
            AnalysisRunPlannedUnit(label: "s2", value: .progress([0.5])),
        ]

        _ = await AnalysisRunExecutor.unsigned.execute(tool, fixture.request(groupsSamples: true), events: recorder.events)

        let fractions = recorder.snapshot.compactMap { line -> Double? in
            if case .progress(let fraction, _)? = line.event { return fraction }
            return nil
        }
        #expect(fractions == [0, 0.25, 0.5, 0, 0.5, 0.75])
    }

    @Test("A finalize failure fails the run and its warnings stay in the record")
    func finalizeFailureFailsTheRun() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        var tool = FakeAnalysisRunTool(probe: FakeToolProbe())
        tool.units = [AnalysisRunPlannedUnit(label: "s1", value: .warn("degraded"))]
        tool.finalizeError = "summary could not be written"

        let report = await AnalysisRunExecutor.unsigned.execute(tool, fixture.request(), events: .discarding)

        #expect(report.status == .failed)
        #expect(report.message.hasSuffix("summary could not be written"))
        let record = try fixture.record(at: report.recordURL)
        #expect(record.status == .failed)
        #expect(record.stderr == "\(report.message)\ndegraded")
        #expect(AnalysisRunRecord.load(from: try #require(report.analysisDirectory))?.outcome == .failed)
    }

    @Test("A completed run whose record names no output fails with a failed record")
    func recordWithoutOutputFailsTheRun() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        var tool = FakeAnalysisRunTool(probe: FakeToolProbe())
        tool.units = [AnalysisRunPlannedUnit(label: "s1", value: .completeWithoutRecord)]
        tool.finalizeOutputs = false

        let report = await AnalysisRunExecutor.unsigned.execute(tool, fixture.request(), events: .discarding)

        #expect(report.status == .failed)
        #expect(report.exitCode == 64)
        #expect(report.message.hasPrefix("The run's provenance record could not be written"))
        let record = try fixture.record(at: report.recordURL)
        #expect(record.status == .failed)
        #expect(record.exitStatus == 64)
        #expect(record.steps.map(\.toolName) == ["fake-index"])
        #expect(AnalysisRunRecord.load(from: try #require(report.analysisDirectory))?.outcome == .failed)
    }

    @Test("Every unit failing under the warning policy fails the run")
    func everyUnitFailingFailsTheRun() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        let probe = FakeToolProbe()
        var tool = FakeAnalysisRunTool(probe: probe)
        tool.terminalPolicy = .warnOnFailedUnits
        tool.layout = .batchRoot
        tool.units = [
            AnalysisRunPlannedUnit(label: "s1", value: .fail("no reads")),
            AnalysisRunPlannedUnit(label: "s2", value: .fail("no reads")),
        ]

        let report = await AnalysisRunExecutor.unsigned.execute(tool, fixture.request(groupsSamples: true), events: .discarding)

        #expect(probe.phases == ["plan", "run s1", "run s2"])
        #expect(report.status == .failed)
        #expect(report.message == "None of the 2 runs completed.")
        #expect(report.warnings == ["s1 failed: no reads", "s2 failed: no reads"])
        #expect(try fixture.record(at: report.recordURL).status == .failed)
    }

    @Test("Finalize warnings complete the run with warnings")
    func finalizeWarningsCompleteWithWarnings() async throws {
        let fixture = try AnalysisRunTestProject()
        defer { fixture.cleanup() }
        var tool = FakeAnalysisRunTool(probe: FakeToolProbe())
        tool.finalizeWarnings = ["The viewer database could not be built and will be built at first view."]
        tool.finalizeOutputs = false

        let report = await AnalysisRunExecutor.unsigned.execute(tool, fixture.request(), events: .discarding)

        #expect(report.status == .completed)
        #expect(report.warnings == tool.finalizeWarnings)
        let record = try fixture.record(at: report.recordURL)
        #expect(record.outputs.contains { $0.path.hasSuffix("s1.kreport") })
    }
}
