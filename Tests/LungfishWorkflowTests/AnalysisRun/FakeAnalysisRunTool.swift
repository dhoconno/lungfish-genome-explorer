// FakeAnalysisRunTool.swift - A tool for the analysis run executor tests that runs no external program
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// What one fake unit does.
enum FakeUnitScript: Sendable {
    /// Writes its output and completes.
    case complete
    /// Writes its output and completes with a warning.
    case warn(String)
    /// Returns a failed outcome.
    case fail(String)
    /// Throws.
    case throwError(String)
    /// Reports these fractions, then completes.
    case progress([Double])
    /// Completes without writing or recording an output.
    case completeWithoutRecord
}

struct FakeToolError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// What the fake tool saw, for the test to read after the run.
final class FakeToolProbe: Sendable {
    private struct State {
        var phases: [String] = []
        var facts: [String: Bool] = [:]
        var finalizedOutcomes: [String] = []
        var sampleNames: [String] = []
    }

    private let state = Mutex(State())

    func note(_ phase: String) {
        state.withLock { $0.phases.append(phase) }
    }

    func observe(_ fact: String, _ value: Bool) {
        state.withLock { $0.facts[fact] = value }
    }

    func noteSampleName(_ name: String) {
        state.withLock { $0.sampleNames.append(name) }
    }

    func noteFinalized(_ outcomes: [String]) {
        state.withLock { $0.finalizedOutcomes = outcomes }
    }

    var phases: [String] { state.withLock { $0.phases } }
    var sampleNames: [String] { state.withLock { $0.sampleNames } }
    var finalizedOutcomes: [String] { state.withLock { $0.finalizedOutcomes } }

    func fact(_ name: String) -> Bool? {
        state.withLock { $0.facts[name] }
    }
}

/// A tool with the shape of a classifier. Each unit writes an input copy and a report, records the
/// input and its step, and the finalize writes a summary, a stand-in folder record and a source
/// record.
struct FakeAnalysisRunTool: AnalysisRunTool {
    typealias Unit = FakeUnitScript
    typealias UnitResult = URL

    static let workflowName = "lungfish.fake-analysis"

    let identity = AnalysisRunIdentity(toolID: AnalysisToolID(rawValue: "kraken2"), workflowName: FakeAnalysisRunTool.workflowName)
    var terminalPolicy: AnalysisRunTerminalPolicy = .failOnAnyFailedUnit
    var layout: AnalysisRunLayout = .singleFolder
    var units: [AnalysisRunPlannedUnit<FakeUnitScript>] = [AnalysisRunPlannedUnit(label: "s1", value: .complete)]
    var planError: String?
    var readSetPlan: ParameterValue?
    var sourceBundle: URL?
    var finalizeError: String?
    var finalizeWarnings: [String] = []
    var finalizeOutputs = true
    let probe: FakeToolProbe

    init(probe: FakeToolProbe) {
        self.probe = probe
    }

    func plan(_ request: AnalysisRunRequest, context: AnalysisRunPlanningContext) async throws -> AnalysisRunPlan<FakeUnitScript> {
        probe.note("plan")
        if let projectURL = context.projectURL {
            let analyses = projectURL.appendingPathComponent(AnalysesFolder.directoryName)
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: analyses.path)) ?? []
            probe.observe("analysesEmptyAtPlan", entries.isEmpty)
        }
        if let planError {
            throw FakeToolError(message: planError)
        }
        return AnalysisRunPlan(
            layout: layout,
            units: units,
            options: AnalysisRunRecordOptions(
                explicit: ["threads": .integer(2)],
                defaults: ["confidence": .number(0)],
                resolved: ["confidence": .number(0.1)],
                readSetPlan: readSetPlan
            )
        )
    }

    func run(_ unit: AnalysisRunUnit<FakeUnitScript>, context: AnalysisRunUnitContext) async throws -> AnalysisUnitOutcome<URL> {
        probe.note("run \(unit.label)")
        probe.noteSampleName(unit.sampleName)
        let root = context.rootDirectory
        probe.observe("folderExistsAtRun", FileManager.default.fileExists(atPath: root.path))
        probe.observe("metadataAtRun", AnalysesFolder.readAnalysisMetadata(from: root) != nil)
        probe.observe("runRecordAtRun", AnalysisRunRecord.isIncomplete(root))
        probe.observe("rootRecordAtRun", FileManager.default.fileExists(atPath: Self.recordURL(in: root).path))

        let input = unit.directory.appendingPathComponent("\(unit.sampleName).input.fastq")
        try Data("@r1\nACGT\n+\nIIII\n".utf8).write(to: input)
        let inputDescriptor = try ProvenanceFileDescriptor.file(url: input, format: .fastq, role: .input)
        context.recordInput(inputDescriptor)

        switch unit.value {
        case .fail(let reason):
            return .failed(reason: reason)
        case .throwError(let reason):
            throw FakeToolError(message: reason)
        case .progress(let fractions):
            for fraction in fractions {
                context.progress(fraction, "\(unit.label) at \(fraction)")
            }
        case .completeWithoutRecord:
            return .completed(input)
        case .complete, .warn:
            break
        }

        let output = unit.directory.appendingPathComponent("\(unit.sampleName).kreport")
        try Data("100.00\t1\t0\tR\t1\troot\n".utf8).write(to: output)
        context.recordStep(ProvenanceStep(
            toolName: "fake-classifier",
            toolVersion: "1.0",
            argv: ["fake-classifier", input.path, output.path],
            inputs: [inputDescriptor],
            outputs: [try ProvenanceFileDescriptor.file(url: output, role: .output)],
            exitStatus: 0
        ))
        if case .warn(let reason) = unit.value {
            return .completedWithWarning(output, reason: reason)
        }
        return .completed(output)
    }

    func finalize(_ units: [AnalysisUnitReport<URL>], context: AnalysisRunFinalizeContext) async throws -> AnalysisRunFinalization {
        probe.note("finalize")
        probe.noteFinalized(units.map { "\($0.label)=\($0.outcome.completed ? "completed" : "failed")" })
        probe.observe("runRecordAtFinalize", AnalysisRunRecord.isIncomplete(context.rootDirectory))
        if let finalizeError {
            throw FakeToolError(message: finalizeError)
        }

        // A record an index build would leave in the folder, which the root record must replace.
        let standIn = try ProvenanceRunBuilder(
            workflowName: "lungfish.build-db",
            workflowVersion: "stand-in",
            toolName: "lungfish-cli",
            toolVersion: "stand-in"
        )
        .complete(exitStatus: 1, startedAt: Date(timeIntervalSince1970: 0), endedAt: Date(timeIntervalSince1970: 1))
        try ProvenanceWriter(signingProvider: nil).write(standIn, to: context.rootDirectory)

        let summary = context.rootDirectory.appendingPathComponent("summary.tsv")
        try Data("sample\tstatus\n".utf8).write(to: summary)
        return AnalysisRunFinalization(
            outputs: finalizeOutputs ? [AnalysisRunOutput(url: summary, format: .text)] : [],
            steps: [ProvenanceStep(toolName: "fake-index", toolVersion: "1.0", argv: ["fake-index", summary.path])],
            sourceRecords: sourceBundle.map {
                [AnalysisManifestSourceRecord(bundleURL: $0, displayName: "Fake Batch", summary: "\(units.count) units")]
            } ?? [],
            artifacts: [CLIEventArtifact(kind: "tsv", path: summary.path, role: "summary")],
            completionDetail: "\(units.filter { $0.outcome.completed }.count) of \(units.count) samples classified",
            warnings: finalizeWarnings
        )
    }

    static func recordURL(in directory: URL) -> URL {
        directory.appendingPathComponent(ProvenanceWriter.provenanceFilename)
    }
}

/// Collects a run's event lines from any thread.
final class AnalysisRunEventRecorder: Sendable {
    private let lines = Mutex<[CLIEventLine]>([])

    var events: AnalysisRunEvents {
        AnalysisRunEvents { line in self.lines.withLock { $0.append(line) } }
    }

    var snapshot: [CLIEventLine] {
        lines.withLock { $0 }
    }

    var names: [String] {
        snapshot.compactMap(\.eventName)
    }
}

/// A project folder for one test.
struct AnalysisRunTestProject {
    let root: URL
    let project: URL

    init() throws {
        // The resolved path, so the writer's project-relative paths read back as written.
        root = try TestTempDirectory.make(prefix: "analysis-run").resolvingSymlinksInPath()
        project = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    }

    func cleanup() {
        TestTempDirectory.cleanup(root)
    }

    func request(_ destination: AnalysisRunDestination? = nil, groupsSamples: Bool = false) -> AnalysisRunRequest {
        AnalysisRunRequest(
            inputs: [project.appendingPathComponent("Reads/s1.lungfishfastq")],
            destination: destination ?? .project(project),
            groupsSamples: groupsSamples,
            commandLine: ["lungfish-cli", "fake", "run", "--project", project.path]
        )
    }

    /// The root record as a reader sees it, with the writer's portable paths resolved.
    func record(at url: URL?) throws -> ProvenanceEnvelope {
        guard let url, let envelope = try ProvenanceEnvelopeReader.load(fromSidecar: url) else {
            throw FakeToolError(message: "The run wrote no root record.")
        }
        return envelope
    }
}

extension AnalysisRunExecutor {
    /// An executor that writes unsigned records.
    static var unsigned: AnalysisRunExecutor {
        AnalysisRunExecutor(services: AnalysisRunServices(writer: ProvenanceWriter(signingProvider: nil)))
    }
}
