// AnalysisRunAPITests.swift - The value types of the analysis run executor API
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// The terminal policy, the record options, the event sink, the source record and the contexts
/// of the analysis run API (2.7 A6, E4, E6, E13).
@Suite("Analysis run API")
struct AnalysisRunAPITests {
    private static func report(
        _ index: Int,
        _ label: String,
        _ outcome: AnalysisUnitOutcome<Int>
    ) -> AnalysisUnitReport<Int> {
        AnalysisUnitReport(
            index: index,
            label: label,
            sampleName: label,
            directory: URL(fileURLWithPath: "/tmp/\(label)"),
            outcome: outcome
        )
    }

    // MARK: Terminal policy

    @Test("A unit that completes with a warning leaves the run completed under either policy")
    func warningUnitLeavesTheRunCompleted() {
        let reports = [Self.report(0, "s1", .completedWithWarning(1, reason: "Bracken degraded"))]
        for policy in [AnalysisRunTerminalPolicy.failOnAnyFailedUnit, .warnOnFailedUnits] {
            #expect(policy.outcome(for: reports, unitCount: 1) == .completed)
            #expect(policy.warning(for: reports[0], unitCount: 1) == "Bracken degraded")
            #expect(policy.warning(for: reports[0], unitCount: 2) == "s1: Bracken degraded")
            #expect(policy.continues(after: reports[0]))
        }
    }

    @Test("The default policy fails the run at the first failed unit and says it once")
    func defaultPolicyFailsAtTheFirstFailedUnit() {
        let policy = AnalysisRunTerminalPolicy.failOnAnyFailedUnit
        let failed = Self.report(1, "s2", .failed(reason: "kraken2 exited 2"))
        let reports = [Self.report(0, "s1", .completed(1)), failed]

        #expect(policy.continues(after: failed) == false)
        #expect(policy.warning(for: failed, unitCount: 3) == nil)
        #expect(policy.outcome(for: reports, unitCount: 3) == .failed(reason: "s2 failed: kraken2 exited 2"))
        #expect(policy.outcome(for: [failed], unitCount: 1) == .failed(reason: "kraken2 exited 2"))
        #expect(policy.outcome(for: [Self.report(0, "s1", .completed(1))], unitCount: 1) == .completed)
    }

    @Test("The warning policy runs every unit and fails only when none completed")
    func warningPolicyFailsOnlyWhenNoUnitCompleted() {
        let policy = AnalysisRunTerminalPolicy.warnOnFailedUnits
        let failed = Self.report(1, "s2", .failed(reason: "kraken2 exited 2"))
        let reports = [Self.report(0, "s1", .completed(1)), failed, Self.report(2, "s3", .completed(3))]

        #expect(policy.continues(after: failed))
        #expect(policy.warning(for: failed, unitCount: 3) == "s2 failed: kraken2 exited 2")
        #expect(policy.outcome(for: reports, unitCount: 3) == .completed)

        let allFailed = [Self.report(0, "s1", .failed(reason: "a")), Self.report(1, "s2", .failed(reason: "b"))]
        #expect(policy.outcome(for: allFailed, unitCount: 2) == .failed(reason: "None of the 2 runs completed."))
        #expect(policy.warning(for: Self.report(0, "s1", .failed(reason: "a")), unitCount: 1) == nil)
        #expect(policy.outcome(for: [Self.report(0, "s1", .failed(reason: "a"))], unitCount: 1) == .failed(reason: "a"))
    }

    @Test("Exit codes match the command line's codes")
    func exitCodesMatchTheCommandLine() {
        #expect(AnalysisRunExitCode.code(for: .completed) == 0)
        #expect(AnalysisRunExitCode.code(for: .failed) == 64)
        #expect(AnalysisRunExitCode.code(for: .cancelled) == 125)
        #expect(AnalysisRunExitCode.code(for: .running) == 64)
    }

    // MARK: Record options

    @Test("The read-set plan lands under its one key in the resolved options")
    func readSetPlanLandsInTheResolvedOptions() {
        let plan: ParameterValue = .dictionary(["capability": .string("pairsOrSinglesPerRun"), "runs": .integer(2)])
        let options = AnalysisRootRecordOptions(
            explicit: ["threads": .integer(4)],
            resolved: ["confidence": .number(0.2), "readSetPlan": .string("stale")],
            readSetPlan: plan
        )

        #expect(options.resolvedIncludingReadSetPlan["readSetPlan"] == plan)
        #expect(options.resolvedIncludingReadSetPlan["confidence"] == .number(0.2))
        #expect(options.explicit["readSetPlan"] == nil)
        #expect(AnalysisRootRecordOptions(resolved: ["a": .integer(1)]).resolvedIncludingReadSetPlan == ["a": .integer(1)])
        #expect(AnalysisRootRecordOptions.readSetPlanValue(of: nil) == nil)
    }

    // MARK: Events

    @Test("JSON lines arrive whole, one per event, when many threads emit at once")
    func jsonLinesArriveWholeUnderConcurrency() async throws {
        let lines = LineCollector()
        let events = AnalysisRunEvents.jsonLines { lines.append($0) }

        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask {
                    for index in 0..<25 {
                        events.emit(.log(level: .info, message: "worker \(worker) line \(index) " + String(repeating: "x", count: 512)))
                    }
                }
            }
        }

        let written = lines.snapshot
        #expect(written.count == 200)
        let decoder = CLIEventLineDecoder()
        for line in written {
            #expect(!line.contains("\n"))
            let decoded = try decoder.decodeLine(line)
            #expect(decoded?.schemaVersion == CLIEventLine.currentSchemaVersion)
            #expect(decoded?.eventName == "log")
        }
    }

    @Test("The sink keeps the order of one emitter and the artifacts of an output line")
    func sinkKeepsOrderAndArtifacts() {
        let delivered = LineCollector()
        let events = AnalysisRunEvents { line in
            delivered.append(line.eventName ?? "?")
        }
        let artifactLines = Mutex<[CLIEventLine]>([])
        let recording = AnalysisRunEvents { line in artifactLines.withLock { $0.append(line) } }

        events.emit(.start(message: "Starting"))
        events.emit(.output(path: "/p/Analyses/kraken2-1", role: CLIEventArtifact.Role.analysisDirectory))
        events.emit(.progress(fraction: 0.5, message: "half"))
        events.emit(.complete(outputs: ["/p/Analyses/kraken2-1"], message: nil))
        recording.emit(
            .complete(outputs: ["/r"], message: "done"),
            artifacts: [CLIEventArtifact(kind: "provenance", path: "/r/lungfish-provenance.json", role: "provenance")]
        )
        recording.emit(.log(level: .info, message: "x"), artifacts: [CLIEventArtifact(kind: "k", path: "/dropped")])

        #expect(delivered.snapshot == ["start", "output", "progress", "complete"])
        let recorded = artifactLines.withLock { $0 }
        #expect(recorded.first?.artifacts.map(\.role) == ["provenance"])
        #expect(recorded.last?.artifacts.isEmpty == true)
    }

    // MARK: Source records

    @Test("A manifest source record names the folder relative to Analyses")
    func manifestSourceRecordNamesTheFolderRelativeToAnalyses() throws {
        let root = try TestTempDirectory.make(prefix: "analysis-run-source")
        defer { TestTempDirectory.cleanup(root) }
        let project = root.appendingPathComponent("Fixture.lungfish", isDirectory: true)
        let bundle = project.appendingPathComponent("Reads/sample.lungfishfastq", isDirectory: true)
        let analysis = project.appendingPathComponent("Analyses/Reviewed/kraken2-batch-2026-10-11T10-00-00", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: analysis, withIntermediateDirectories: true)
        let context = AnalysisSourceRecordContext(
            toolID: AnalysisToolID(rawValue: "kraken2"),
            analysisDirectory: analysis,
            projectURL: project
        )

        try AnalysisManifestSourceRecord(
            bundleURL: bundle,
            displayName: "Kraken2 Batch",
            parameters: ["confidence": .double(0.2)],
            summary: "100 reads, 55 classified"
        ).write(context)

        let manifest = AnalysisManifestStore.load(bundleURL: bundle, projectURL: project)
        #expect(manifest.analyses.count == 1)
        #expect(manifest.analyses.first?.analysisDirectoryName == "Reviewed/kraken2-batch-2026-10-11T10-00-00")
        #expect(manifest.analyses.first?.tool == "kraken2")
        #expect(manifest.analyses.first?.status == .completed)
        #expect(manifest.analyses.first?.summary == "100 reads, 55 classified")

        let outside = AnalysisSourceRecordContext(toolID: AnalysisToolID(rawValue: "kraken2"), analysisDirectory: root.appendingPathComponent("out"), projectURL: nil)
        #expect(outside.analysisDirectoryName == "out")
    }

    // MARK: Contexts

    @Test("The finalize context refuses an index without a builder and passes the request to one")
    func finalizeContextBuildsTheIndexThroughTheBuilder() async throws {
        let directory = URL(fileURLWithPath: "/tmp/esviritu-batch-1")
        let logged = LineCollector()
        let bare = AnalysisRunFinalizeContext(
            rootDirectory: directory,
            layout: .batchRoot,
            projectURL: nil,
            toolID: AnalysisToolID(rawValue: "esviritu"),
            indexing: nil
        )
        await #expect(throws: AnalysisRunError.noResultIndexer(AnalysisToolID(rawValue: "esviritu"))) {
            try await bare.buildIndex()
        }

        let indexer = RecordingIndexer()
        let context = AnalysisRunFinalizeContext(
            rootDirectory: directory,
            layout: .batchRoot,
            projectURL: nil,
            toolID: AnalysisToolID(rawValue: "esviritu"),
            indexing: indexer,
            log: { _, message in logged.append(message) }
        )
        let index = try await context.buildIndex()

        #expect(index.outputs.map(\.url) == [directory.appendingPathComponent("esviritu.sqlite")])
        #expect(indexer.requests.map(\.toolID.rawValue) == ["esviritu"])
        #expect(indexer.requests.first?.resultDirectory == directory)
        #expect(indexer.requests.first?.layout == .batchRoot)
        #expect(logged.snapshot == ["indexing esviritu"])
    }

    @Test("The unit context hands progress, logs and record entries to the executor")
    func unitContextForwardsEverything() {
        let seen = LineCollector()
        let context = AnalysisRunUnitContext(
            rootDirectory: URL(fileURLWithPath: "/tmp/root"),
            projectURL: nil,
            progress: { fraction, message in seen.append("progress \(fraction) \(message)") },
            log: { level, message in seen.append("\(level.rawValue) \(message)") },
            recordInput: { descriptor in seen.append("input \(descriptor.path)") },
            recordStep: { step in seen.append("step \(step.toolName)") },
            recordOptions: { options in seen.append("options \(options.resolved.keys.sorted().joined(separator: ","))") }
        )

        context.progress(0.5, "half")
        context.log(.warning, "careful")
        context.recordInput(ProvenanceFileDescriptor(path: "/tmp/reads.fastq", checksumSHA256: nil, fileSize: nil, format: .fastq, role: .input))
        context.recordStep(ProvenanceStep(toolName: "kraken2"))
        context.recordOptions(AnalysisRootRecordOptions(resolved: ["profileState": .string("degraded")]))

        #expect(seen.snapshot == [
            "progress 0.5 half",
            "warning careful",
            "input /tmp/reads.fastq",
            "step kraken2",
            "options profileState",
        ])
    }

    @Test("Recorded options merge key by key, a later value winning and a read-set plan replacing the one before")
    func recordedOptionsMergeKeyByKey() {
        let earlier: ParameterValue = .dictionary(["capability": .string("singlesPerRun")])
        let later: ParameterValue = .dictionary(["capability": .string("pairsOrSinglesPerRun")])
        let plan = AnalysisRootRecordOptions(
            explicit: ["threads": .integer(4)],
            defaults: ["confidence": .number(0)],
            resolved: ["confidence": .number(0.1), "database": .string("standard")],
            readSetPlan: earlier
        )

        let unit = plan.merging(AnalysisRootRecordOptions(
            explicit: ["memoryMapping": .boolean(true)],
            resolved: ["confidence": .number(0.2), "profileState": .string("degraded")],
            readSetPlan: later
        ))
        #expect(unit.explicit == ["threads": .integer(4), "memoryMapping": .boolean(true)])
        #expect(unit.defaults == ["confidence": .number(0)])
        #expect(unit.resolved == ["confidence": .number(0.2), "database": .string("standard"), "profileState": .string("degraded")])
        #expect(unit.readSetPlan == later)

        // A contribution without a read-set plan keeps the one before.
        #expect(unit.merging(AnalysisRootRecordOptions(resolved: ["index": .string("kraken2.sqlite")])).readSetPlan == later)
    }
}

/// Collects strings from any thread.
final class LineCollector: Sendable {
    private let lines = Mutex<[String]>([])

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    var snapshot: [String] {
        lines.withLock { $0 }
    }
}

/// An index builder that records its requests and writes nothing.
final class RecordingIndexer: AnalysisResultIndexing {
    private let seen = Mutex<[AnalysisResultIndexRequest]>([])

    var requests: [AnalysisResultIndexRequest] {
        seen.withLock { $0 }
    }

    func buildIndex(_ request: AnalysisResultIndexRequest) async throws -> AnalysisResultIndex {
        seen.withLock { $0.append(request) }
        request.log(.info, "indexing \(request.toolID.rawValue)")
        return AnalysisResultIndex(
            outputs: [AnalysisRunOutput(url: request.resultDirectory.appendingPathComponent("\(request.toolID.rawValue).sqlite"))]
        )
    }
}
