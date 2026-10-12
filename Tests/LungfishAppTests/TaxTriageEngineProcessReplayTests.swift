// TaxTriageEngineProcessReplayTests.swift - Pins of TaxTriage's engine process before it moves onto the shared engine
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane S9, milestone M1, panel decisions N5 to N9. Milestone M2 moves TaxTriage onto
// `NextflowEngineProcess` (Sources/LungfishWorkflow/Nextflow), so these cases pin, on
// `TaxTriageStandInEngine`, what the move keeps and what it fixes.
//
// Plain pins of today's behaviour, which M2 keeps.
// - A cancel stops the whole tree after the 4 s grace and records `cancelled` with exit 125, in the
//   order host tree, then record, then scratch (N5, N6, N7).
// - `nextflow.log` holds the launch metadata, then `--- stdout ---` and the stdout lines, then
//   `--- stderr ---` and the stderr lines (N8, today's bytes).
//
// Pins of the defects M2 fixes, `XCTExpectFailure` pins until TaxTriage moved onto the engine.
// - E9. A cancel during the Docker wait ends the run at once, where `try?` on its sleep swallowed it.
// - Only a run with the docker profile asks the Docker daemon (A16 M1 review, ruling 2).
// - E10. A cancel before the launch starts no engine, where the engine started and was stopped.
// - A KILL leaves `nextflow.log` with the lines so far, where the log was written once the engine
//   returned (Q15 R3).
//
// The cases start processes, so the class runs serially. Its name ends in ReplayTests, which sends it
// to the integration tier (`REPLAY_SUITES` in scripts/full-suite-gate.sh).

import Darwin
import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow
import Synchronization
import XCTest

final class TaxTriageEngineProcessReplayTests: XCTestCase {
    private var scratch: URL!

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "taxtriage-engine-pins")
    }

    override func tearDown() async throws {
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    // MARK: - Plain pins

    func testACancelStopsTheTreeAfterTheGraceThenRecordsTheCancelThenRemovesTheScratch() async throws {
        let engine = try makeEngine(.trapsTermWithHeartbeatChild)
        let config = try makeConfig([("C1", 2)], output: "order")

        let run = Task { try await engine.makePipeline().run(config: config) }
        let started = await engine.waitForLaunch()
        let launch = try XCTUnwrap(started, "the launch never started")
        let engineID = try XCTUnwrap(launch.processIdentifier)
        let childID = try XCTUnwrap(launch.childProcessIdentifier)
        let watcher = Self.watchCancelOrder(
            record: config.outputDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename),
            scratch: launch.workingDirectory,
            tree: [engineID, childID]
        )

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        run.cancel()
        let outcome = await run.result
        let waited = clock.now - cancelledAt
        let treeRunsAfterTheRun = Self.isRunning(engineID) || Self.isRunning(childID)
        let order = await watcher.value
        let record = try ProvenanceEnvelopeReader.load(from: config.outputDirectory)
        let step = record?.steps.first { $0.toolName == "taxtriage" }

        XCTAssertTrue(outcome.failure is CancellationError, "\(String(describing: outcome.failure))")
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(3500), "the tree has its 4 s grace before KILL (N6)")
        XCTAssertFalse(treeRunsAfterTheRun, "no process of the engine tree outlives the run")
        XCTAssertEqual(record?.status, .cancelled, "the record says cancelled, from the request")
        XCTAssertEqual(record?.exitStatus, 125, "a cancel records exit 125, never the signal that ended the engine")
        XCTAssertEqual(step?.exitStatus, 125)
        XCTAssertEqual(step?.outputs.map(\.path) ?? ["no step"], [], "a cancel hashes no partial output")
        // N5 and N7. The host tree goes first, then the record is written, then the scratch goes.
        XCTAssertEqual(order.treeRanWhenTheRecordAppeared, false, "the record is written only once the tree is gone")
        XCTAssertEqual(order.recordMissingWhenTheScratchWent, false, "the scratch goes only once the record is written")
    }

    func testTheLogHoldsTheLaunchMetadataThenEachStreamUnderItsHeading() async throws {
        let engine = try makeEngine(.failsSamples(["L2"]))
        let completed = try makeConfig([("L1", 2)], output: "completed")
        let failed = try makeConfig([("L2", 2)], output: "failed")

        _ = try await engine.makePipeline().run(config: completed)
        let failure = await Task { try await engine.makePipeline().run(config: failed) }.result

        XCTAssertNotNil(failure.failure, "the failing sample fails its run")
        // Since lane U10 M1 the stand-in prints the plain log of a real Nextflow 26.04.6, one task line
        // for each task of the sample. The lines are compared masked (`masked(_:)`).
        let workflow = NextflowStandInWorkflow.taxTriage
        let escape = "\u{1B}"
        let completedTasks = workflow.leadingProcessNames
            + workflow.processNames.map { $0.replacingOccurrences(of: "@SAMPLE@", with: "L1") }
            + workflow.trailingProcessNames
        XCTAssertEqual(
            Self.masked(try Self.log(in: completed.outputDirectory)),
            Self.masked(
                try Self.launchMetadata(in: completed.outputDirectory)
                    + "\n--- stdout ---\n"
                    + (Self.plainLogBanner + Self.taskLines(completedTasks) + [
                        "-\(escape)[0;35m[nf-core/taxtriage]\(escape)[0;32m Pipeline completed successfully\(escape)[0m-",
                        "[SUCCESS] completed=29 failed=0 cached=0",
                    ]).joined(separator: "\n")
                    + "\n--- stderr ---\n"
            ),
            "a completed run logs its stdout lines and an empty stderr part"
        )
        // A failing sample stops at its Kraken2 task, the fifth of its own.
        let failedTasks = workflow.leadingProcessNames
            + workflow.processNames.prefix(5).map { $0.replacingOccurrences(of: "@SAMPLE@", with: "L2") }
        XCTAssertEqual(
            Self.masked(try Self.log(in: failed.outputDirectory)),
            Self.masked(
                try Self.launchMetadata(in: failed.outputDirectory)
                    + "\n--- stdout ---\n"
                    + (Self.plainLogBanner + Self.taskLines(failedTasks) + [
                        "-\(escape)[0;35m[nf-core/taxtriage]\(escape)[0;31m Pipeline completed with errors\(escape)[0m-",
                    ]).joined(separator: "\n")
                    + "\n--- stderr ---\n"
                    + "ERROR ~ Error executing process > 'NFCORE_TAXTRIAGE:TAXTRIAGE:CLASSIFIER:KRAKEN2_KRAKEN2 (L2)'"
            ),
            "a failed run logs both streams, each line once, with no line break after the last"
        )
    }

    // MARK: - Pins of today's defects

    func testACancelDuringTheDockerWaitEndsTheRunAtOnce() async throws {
        let engine = try makeEngine(.completes)
        var config = try makeConfig([("D1", 2)], output: "docker")
        config.profile = "docker"
        let probe = CountingDockerProbe(reachable: false)
        let pipeline = makePipeline(engine, probe: probe)

        let outcome = await Task {
            try await pipeline.run(config: config) { _, message in
                // The wait says this before it runs `open`, so the cancel lands first and the run
                // never asks macOS to start Docker Desktop.
                if message == "Docker daemon unavailable. Launching Docker Desktop..." {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }.result

        XCTAssertEqual(try engine.launches().count, 0, "no engine starts once the run is cancelled")
        // E9. Before S9 M2 the wait swallowed the cancel with try? on its sleep, asked the daemon
        // without a pause until its 90 s count ran out and failed as a missing prerequisite.
        XCTAssertTrue(outcome.failure is CancellationError, "\(String(describing: outcome.failure))")
        XCTAssertGreaterThanOrEqual(probe.daemonQueries, 1, "the wait asked the daemon before it said it was unavailable")
        XCTAssertLessThanOrEqual(probe.daemonQueries, 2, "a cancelled wait stops asking the daemon")
    }

    func testOnlyARunWithTheDockerProfileAsksTheDockerDaemon() async throws {
        let engine = try makeEngine(.completes)
        // The prerequisite report asks the daemon for every profile (`checkPrerequisites`), so each
        // run's count is read against the report's own.
        let reportProbe = CountingDockerProbe(reachable: true)
        _ = await makePipeline(engine, probe: reportProbe).checkPrerequisites()
        let local = try makeConfig([("P1", 2)], output: "profile-local")
        let localProbe = CountingDockerProbe(reachable: true)
        var docker = try makeConfig([("P2", 2)], output: "profile-docker")
        docker.profile = "docker"
        let dockerProbe = CountingDockerProbe(reachable: true)
        let dockerPipeline = makePipeline(engine, probe: dockerProbe)

        _ = try await makePipeline(engine, probe: localProbe).run(config: local)
        let outcome = await Task {
            try await dockerPipeline.run(config: docker) { _, message in
                // The daemon answers at once, so `open` never runs. The run stops at its last line
                // before the launch.
                if message == "Starting TaxTriage pipeline..." {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }.result

        XCTAssertEqual(
            localProbe.daemonQueries,
            reportProbe.daemonQueries,
            "a run with profile local asks the daemon only for its prerequisite report, never to wait"
        )
        XCTAssertTrue(outcome.failure is CancellationError, "\(String(describing: outcome.failure))")
        XCTAssertGreaterThanOrEqual(
            dockerProbe.daemonQueries,
            reportProbe.daemonQueries + 1,
            "a run with profile docker waits for the daemon before it goes on"
        )
    }

    func testACancelBeforeTheLaunchStartsNoEngine() async throws {
        let engine = try makeEngine(.completes)
        let config = try makeConfig([("E1", 2)], output: "early")
        let observed = LaunchedStages()

        let outcome = await Task {
            try await ToolProcessObservation.$observer.withValue(observed.observer) {
                try await engine.makePipeline().run(config: config) { _, message in
                    // The last progress line before the launch, after the prerequisites and the samplesheet.
                    if message == "Starting TaxTriage pipeline..." {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }
        }.result
        let record = try ProvenanceEnvelopeReader.load(from: config.outputDirectory)

        XCTAssertTrue(outcome.failure is CancellationError, "\(String(describing: outcome.failure))")
        XCTAssertEqual(record?.status, .cancelled, "a cancelled run records the cancel")
        XCTAssertEqual(record?.exitStatus, 125)
        // E10. Before S9 M2 nothing checked the task between the prerequisites and the launch, so
        // the engine started and was stopped at once.
        XCTAssertEqual(observed.launchedCount(label: "micromamba"), 0, "a cancel before the launch starts no engine")
        XCTAssertEqual(try engine.launches().count, 0, "the stand-in recorded no launch")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: config.outputDirectory.appendingPathComponent("nextflow.log").path),
            "no engine ran, so no log was written"
        )
    }

    func testTheLogHoldsTheLinesSoFarWhileTheEngineRuns() async throws {
        let engine = try makeEngine(.waitsUntilCancelled)
        let config = try makeConfig([("K1", 2)], output: "kill")
        let logFile = config.outputDirectory.appendingPathComponent("nextflow.log")
        let linesSoFar = "\n--- stdout ---\n" + Self.plainLogBanner.joined(separator: "\n")

        let run = Task { try await engine.makePipeline().run(config: config) }
        let started = await engine.waitForLaunch()
        XCTAssertNotNil(started, "the launch never started")
        // The stand-in prints its banner once it is marked started, then waits for the cancel.
        let streamed = await waitUntil(timeout: .seconds(30), pollInterval: .milliseconds(50)) {
            (try? String(contentsOf: logFile, encoding: .utf8)).map(Self.masked)?.hasSuffix(linesSoFar) == true
        }
        let logWhileRunning = try? String(contentsOf: logFile, encoding: .utf8)
        let metadata = try Self.launchMetadata(in: config.outputDirectory)
        run.cancel()
        _ = await run.result

        // Before S9 M2 a KILL of the CLI or the app left no nextflow.log, because the log was
        // written once the engine returned (Q15 R3).
        XCTAssertTrue(streamed, "each stdout line reaches nextflow.log while the engine runs, so a KILL leaves it")
        // Compared as a Bool, so a failure does not print the whole launch metadata.
        XCTAssertTrue(
            logWhileRunning.map(Self.masked) == Self.masked(metadata + linesSoFar),
            "the log holds the launch metadata and the stdout so far, and no stderr part, which joins only at the end (API risk 3)"
        )
    }

    // MARK: - Helpers

    /// The engine for one case, stopped in teardown so no stand-in outlives a case that fails.
    private func makeEngine(_ behaviour: TaxTriageStandInEngine.Behaviour) throws -> TaxTriageStandInEngine {
        let engine = try TaxTriageStandInEngine(
            root: scratch.appendingPathComponent("engine", isDirectory: true),
            behaviour: behaviour
        )
        addTeardownBlock { await engine.stopLeftoverProcesses() }
        return engine
    }

    /// A pipeline that launches the stand-in and asks `probe` about the Docker daemon.
    private func makePipeline(_ engine: TaxTriageStandInEngine, probe: any ContainerRuntimeProbing) -> TaxTriagePipeline {
        let home = engine.home
        return TaxTriagePipeline(
            condaManager: engine.condaManager,
            homeDirectoryProvider: { home },
            appIdentity: .preview,
            containerRuntimeProbe: probe
        )
    }

    /// A stand-in run of one single-end FASTQ per sample into `output` under the scratch folder.
    private func makeConfig(_ samples: [(id: String, records: Int)], output: String) throws -> TaxTriageConfig {
        TaxTriageConfig(
            samples: try samples.map {
                TaxTriageSample(sampleId: $0.id, fastq1: try writeFASTQ("\($0.id).fastq", records: $0.records))
            },
            outputDirectory: scratch.appendingPathComponent(output, isDirectory: true),
            kraken2DatabasePath: try makeDatabaseFolder(),
            maxCpus: 2,
            profile: TaxTriageStandInEngine.profile
        )
    }

    /// A FASTQ of `records` four-line records whose names never pair, so no input reads as interleaved.
    private func writeFASTQ(_ name: String, records: Int) throws -> URL {
        let folder = scratch.appendingPathComponent("reads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let stem = url.deletingPathExtension().lastPathComponent
        let text = (1...records).map { "@\(stem)-read-\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// A Kraken2 database folder. The stand-in never reads it, but the pipeline checks it exists.
    private func makeDatabaseFolder() throws -> URL {
        let folder = scratch.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func log(in outputDirectory: URL) throws -> String {
        try String(contentsOf: outputDirectory.appendingPathComponent("nextflow.log"), encoding: .utf8)
    }

    /// The launch metadata the pipeline writes before the launch, the first part of its log.
    private static func launchMetadata(in outputDirectory: URL) throws -> String {
        try String(contentsOf: outputDirectory.appendingPathComponent("taxtriage-launch-command.txt"), encoding: .utf8)
    }

    /// The lines the stand-in prints before its first task in the plain-log mode, with the date, the
    /// launch target and the work folder masked: TaxTriage's own four lines, then `[PIPELINE]` and
    /// `[WORKDIR]`, as lines 66 to 71 of Q15's real run R1 read.
    private static let plainLogBanner = [
        "Nextflow version: 25.04.6",
        "Commit ID: <masked>",
        "Repository URL: <masked>",
        "Date: <masked>",
        "[PIPELINE] nf-core/taxtriage 1.0dev | profile=\(TaxTriageStandInEngine.profile)",
        "[WORKDIR] <masked>",
    ]

    /// The task line the stand-in prints for each task, numbered from 1 as its trace rows are.
    private static func taskLines(_ tasks: [String]) -> [String] {
        tasks.enumerated().map { "[PROCESS aa/\(String(format: "%06d", $0.offset + 1))] \($0.element)" }
    }

    /// A log with the parts of the banner that change with each run masked, the date the banner prints,
    /// the launch target that names the snapshot folder, and the work folder in the scratch.
    private static func masked(_ log: String) -> String {
        log.components(separatedBy: "\n").map { line in
            for prefix in ["Commit ID: ", "Repository URL: ", "Date: ", "[WORKDIR] "] where line.hasPrefix(prefix) {
                return prefix + "<masked>"
            }
            return line
        }.joined(separator: "\n")
    }

    /// Whether `pid` names a process that has not exited. A zombie only waits to be reaped, so it has exited.
    nonisolated private static func isRunning(_ pid: Int32) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0 else { return false }
        return Int32(info.kp_proc.p_stat) != SZOMB
    }

    /// What the watcher of a cancel saw, each nil when its moment never came.
    private struct CancelOrder: Sendable {
        var treeRanWhenTheRecordAppeared: Bool?
        var recordMissingWhenTheScratchWent: Bool?
    }

    /// Polls every 5 ms until the record has appeared and the scratch has gone, or 60 s pass. It reads
    /// the record before the tree and the scratch before the record, so a process that ends, or a
    /// record that is written, between two reads never reads as the defect.
    nonisolated private static func watchCancelOrder(record: URL, scratch: String, tree: [Int32]) -> Task<CancelOrder, Never> {
        Task.detached {
            var order = CancelOrder()
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(60))
            while clock.now < deadline {
                if order.treeRanWhenTheRecordAppeared == nil, FileManager.default.fileExists(atPath: record.path) {
                    order.treeRanWhenTheRecordAppeared = tree.contains { isRunning($0) }
                }
                if order.recordMissingWhenTheScratchWent == nil, !FileManager.default.fileExists(atPath: scratch) {
                    order.recordMissingWhenTheScratchWent = !FileManager.default.fileExists(atPath: record.path)
                }
                if order.treeRanWhenTheRecordAppeared != nil, order.recordMissingWhenTheScratchWent != nil {
                    return order
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return order
        }
    }
}

/// A Docker probe whose daemon answers as `reachable` says, counting how often it is asked.
private final class CountingDockerProbe: ContainerRuntimeProbing, Sendable {
    private let reachable: Bool
    private let queries = Mutex(0)

    init(reachable: Bool) {
        self.reachable = reachable
    }

    var daemonQueries: Int { queries.withLock { $0 } }

    func dockerCLIPath() -> String? { "/usr/local/bin/docker" }

    func dockerDaemon(dockerPath: String, timeout: TimeInterval) async -> DockerDaemonProbe {
        queries.withLock { $0 += 1 }
        return DockerDaemonProbe(
            reachable: reachable,
            clientVersion: "28.3.2",
            serverVersion: reachable ? "28.3.2" : nil,
            detail: reachable ? nil : "Cannot connect to the Docker daemon"
        )
    }

    func appleContainerRuntime() async -> AppleContainerProbe {
        AppleContainerProbe(frameworkAvailable: false, runtimeReady: false, detail: nil)
    }
}

/// The stages of the ToolProcess runs built while its observer is bound, by label and whether each
/// process was spawned.
private final class LaunchedStages: Sendable {
    private let stages = Mutex<[(label: String, launched: Bool)]>([])

    var observer: ToolProcessObserver {
        ToolProcessObserver { observation in
            let entries = observation.stages.map { stage in (label: stage.label, launched: stage.ending.launched) }
            self.stages.withLock { $0 += entries }
        }
    }

    func launchedCount(label: String) -> Int {
        stages.withLock { $0.filter { $0.label == label && $0.launched }.count }
    }
}

private extension Result {
    /// The error of a failed result, else nil.
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
