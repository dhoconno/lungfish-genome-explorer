// FakeAnalysisRunTool.swift - A tool for the analysis run executor tests that runs no external program
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import LungfishCore
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
    /// Throws an error that carries an exit code, which only a plan's error sets.
    case throwCoded(String, exitCode: Int32)
    /// Reports these fractions, then completes.
    case progress([Double])
    /// Completes without writing or recording an output.
    case completeWithoutRecord
    /// Records an input under a stand-in digest, writes a partial output that cannot be read, says
    /// it started and waits up to 30 seconds for the cancel request.
    case waitForCancel(digest: String)
    /// Cancels the run's task from inside the unit, then completes, or fails for the reason given,
    /// as a unit whose child process was signalled during the cancel would.
    case cancelRunThen(String?)
    /// Runs `/bin/sleep 30` through `ToolProcess`, says it started and waits for the cancel.
    case runProcessUntilCancelled
    /// Asks for a cancel through the probe, as a SIGTERM counted before the run's task is
    /// cancelled does, then fails for the reason given, or throws it, as a unit whose child
    /// process the cancel signalled would.
    case requestCancelThenFail(String, throwing: Bool)
}

struct FakeToolError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// A source record whose bundle does not take it.
struct FailingSourceRecord: AnalysisSourceRecord {
    let message: String

    func write(_ context: AnalysisSourceRecordContext) throws {
        throw FakeToolError(message: message)
    }
}

/// A refusal that carries the exit code of its command, as `conda classify`'s input errors do.
struct FakeCodedError: AnalysisRunExitCoding, LocalizedError {
    let message: String
    let analysisRunExitCode: Int32
    var errorDescription: String? { message }
}

/// What the fake tool saw, for the test to read after the run.
final class FakeToolProbe: Sendable {
    private struct State {
        var phases: [String] = []
        var facts: [String: Bool] = [:]
        var finalizedOutcomes: [String] = []
        var sampleNames: [String] = []
        var launchedProcess: Int32?
        var cancelRequested = false
        var keptContext: AnalysisRunUnitContext?
    }

    private let state = Mutex(State())
    private let started = AsyncStream<Void>.makeStream()

    /// Asks for a cancel, for an executor whose services read ``cancelRequested``.
    func requestCancel() {
        state.withLock { $0.cancelRequested = true }
    }

    var cancelRequested: Bool { state.withLock { $0.cancelRequested } }

    /// Keeps a unit's context past its run, as a handler on a `ToolProcess` queue would.
    func keep(_ context: AnalysisRunUnitContext) {
        state.withLock { $0.keptContext = context }
    }

    var keptContext: AnalysisRunUnitContext? { state.withLock { $0.keptContext } }

    /// Says a unit is running and waiting for the cancel.
    func signalStarted() {
        started.continuation.yield()
    }

    /// Whether a unit said it started within 30 seconds.
    func waitUntilStarted() async -> Bool {
        let stream = started.stream
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(30))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    func noteLaunched(_ pid: Int32) {
        state.withLock { $0.launchedProcess = pid }
    }

    var launchedProcess: Int32? { state.withLock { $0.launchedProcess } }

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
    /// The exit code the plan's error carries, which makes it a ``FakeCodedError``.
    var planErrorExitCode: Int32?
    var readSetPlan: ParameterValue?
    var sourceBundle: URL?
    /// Adds a source record that throws this message when the executor writes it.
    var sourceRecordError: String?
    var finalizeError: String?
    var finalizeWarnings: [String] = []
    var finalizeOutputs = true
    /// Options each unit records right after its input, before it fails or completes.
    var unitOptions: AnalysisRootRecordOptions?
    /// Options the finalization adds.
    var finalizeOptions: AnalysisRootRecordOptions?
    /// A plan that cancels its own run, then throws or returns its plan.
    var planCancels: PlanCancel?
    /// A finalize that cancels its own run, then returns what it wrote.
    var finalizeCancels = false
    let probe: FakeToolProbe

    enum PlanCancel: Sendable {
        case cancelAndThrow
        case cancelAndReturn
    }

    /// Cancels the task the executor runs in, as the command's SIGTERM handling does.
    static func cancelCurrentTask() {
        withUnsafeCurrentTask { $0?.cancel() }
    }

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
        switch planCancels {
        case .cancelAndThrow?:
            Self.cancelCurrentTask()
            throw planFailure ?? CancellationError()
        case .cancelAndReturn?:
            Self.cancelCurrentTask()
        case nil:
            break
        }
        if let planFailure {
            throw planFailure
        }
        return AnalysisRunPlan(
            layout: layout,
            units: units,
            options: AnalysisRootRecordOptions(
                explicit: ["threads": .integer(2)],
                defaults: ["confidence": .number(0)],
                resolved: ["confidence": .number(0.1)],
                readSetPlan: readSetPlan
            )
        )
    }

    /// The error the plan throws, if any.
    private var planFailure: (any Error)? {
        guard let planError else { return nil }
        guard let planErrorExitCode else { return FakeToolError(message: planError) }
        return FakeCodedError(message: planError, analysisRunExitCode: planErrorExitCode)
    }

    func run(_ unit: AnalysisRunUnit<FakeUnitScript>, context: AnalysisRunUnitContext) async throws -> AnalysisUnitOutcome<URL> {
        probe.note("run \(unit.label)")
        probe.noteSampleName(unit.sampleName)
        probe.keep(context)
        let root = context.rootDirectory
        probe.observe("folderExistsAtRun", FileManager.default.fileExists(atPath: root.path))
        probe.observe("metadataAtRun", AnalysesFolder.readAnalysisMetadata(from: root) != nil)
        probe.observe("runRecordAtRun", AnalysisRunRecord.isIncomplete(root))
        probe.observe("rootRecordAtRun", FileManager.default.fileExists(atPath: Self.recordURL(in: root).path))
        probe.observe("unit \(unit.label) writes into the root", unit.directory == root)

        let input = unit.directory.appendingPathComponent("\(unit.sampleName).input.fastq")
        try Data("@r1\nACGT\n+\nIIII\n".utf8).write(to: input)
        let inputDescriptor = try ProvenanceFileDescriptor.file(url: input, format: .fastq, role: .input)
        context.recordInput(inputDescriptor)
        if let unitOptions {
            context.recordOptions(unitOptions)
        }

        switch unit.value {
        case .fail(let reason):
            return .failed(reason: reason)
        case .throwError(let reason):
            throw FakeToolError(message: reason)
        case .throwCoded(let reason, let exitCode):
            throw FakeCodedError(message: reason, analysisRunExitCode: exitCode)
        case .progress(let fractions):
            for fraction in fractions {
                context.progress(fraction, "\(unit.label) at \(fraction)")
            }
        case .completeWithoutRecord:
            return .completed(input)
        case .waitForCancel(let digest):
            let materialized = unit.directory.appendingPathComponent("\(unit.sampleName).materialized.fastq")
            try Data("@r1\nACGT\n+\nIIII\n".utf8).write(to: materialized)
            context.recordInput(ProvenanceFileDescriptor(
                path: materialized.path,
                checksumSHA256: digest,
                fileSize: 16,
                format: .fastq,
                role: .input
            ))
            let partial = unit.directory.appendingPathComponent("\(unit.sampleName).partial.kraken")
            try Data(repeating: 0x43, count: 1 << 16).write(to: partial)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: partial.path)
            probe.signalStarted()
            try await Task.sleep(for: .seconds(30))
            return .completed(partial)
        case .cancelRunThen(let reason):
            Self.cancelCurrentTask()
            if let reason {
                return .failed(reason: reason)
            }
        case .runProcessUntilCancelled:
            let probe = probe
            let spec = ToolProcessSpec(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                environment: [:]
            )
            _ = try await ToolProcess.run(spec, onLaunch: { pid in
                probe.noteLaunched(pid)
                probe.signalStarted()
            })
            return .failed(reason: "sleep ended without a cancel request")
        case .requestCancelThenFail(let reason, let throwing):
            probe.requestCancel()
            if throwing {
                throw FakeToolError(message: reason)
            }
            return .failed(reason: reason)
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
        if finalizeCancels {
            Self.cancelCurrentTask()
        }
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
        var sourceRecords: [any AnalysisSourceRecord] = []
        if let sourceBundle {
            sourceRecords.append(AnalysisManifestSourceRecord(bundleURL: sourceBundle, displayName: "Fake Batch", summary: "\(units.count) units"))
        }
        if let sourceRecordError {
            sourceRecords.append(FailingSourceRecord(message: sourceRecordError))
        }
        return AnalysisRunFinalization(
            outputs: finalizeOutputs ? [AnalysisRunOutput(url: summary, format: .text)] : [],
            steps: [ProvenanceStep(toolName: "fake-index", toolVersion: "1.0", argv: ["fake-index", summary.path])],
            sourceRecords: sourceRecords,
            artifacts: [CLIEventArtifact(kind: "tsv", path: summary.path, role: "summary")],
            completionDetail: "\(units.filter { $0.outcome.completed }.count) of \(units.count) samples classified",
            warnings: finalizeWarnings,
            options: finalizeOptions
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
