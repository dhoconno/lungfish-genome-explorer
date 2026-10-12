// TaxTriageContainerCleanupTests.swift - The N5 cancel order of a TaxTriage docker run, on the stand-in engine and docker
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.9 lane S10, decision N5 with the manager's order ruling. A cancel stops the host tree first, then
// the run's containers, found by their mounts of the run's work folder, within 1.5 s, then writes the
// `cancelled` record, then removes the scratch. Each case runs `TaxTriagePipeline` on `TaxTriageStandInEngine`
// with a probe whose daemon answers and whose `docker` is `NextflowStandInDocker`, so it needs no Docker. The
// cancelled cases use the engine that waits until a signal ends it, so a cancel ends its tree at once.
//
// At the base of the lane TaxTriage gave its engine no container cleanup, so no `docker` ran on a cancel, and
// the parts of the order that only the cleanup can show sat in `XCTExpectFailure` blocks, XCTest's known issue.
// `NextflowDockerContainerCleanup`, which TaxTriage now gives a docker run's engine, made them plain assertions.

import Foundation
import LungfishCore
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow
import XCTest

final class TaxTriageContainerCleanupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-container-cleanup")
    }

    override func tearDownWithError() throws {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - A cancelled docker run

    func testACancelledDockerRunStopsItsContainersAfterTheTreeAndBeforeTheRecord() async throws {
        let engine = try makeEngine(.waitsUntilCancelled)
        let docker = try NextflowStandInDocker.make(in: root)
        let config = try makeConfig(sample: "C1", output: "cancelled", profile: "docker")
        let pipeline = makePipeline(engine, docker: docker)

        let run = Task { try await pipeline.run(config: config) }
        let started = await engine.waitForLaunch()
        let launch = try XCTUnwrap(started, "the launch never started")
        let engineID = try XCTUnwrap(launch.processIdentifier)
        let work = URL(fileURLWithPath: try XCTUnwrap(launch.workDirectory, "the launch names no work folder"), isDirectory: true)
        // The folder that holds the scratch, the system temporary folder here, which every real task mounts too.
        let holdingFolder = work.deletingLastPathComponent().deletingLastPathComponent()
        let ids = ["a1", "b2", "c3", "d4"].map { String(repeating: $0, count: 32) }
        try docker.serve([
            .init(id: ids[0], status: "running", mountSources: [holdingFolder.path, work.appendingPathComponent("aa/000001").path]),
            .init(id: ids[1], status: "running", mountSources: [root.appendingPathComponent("other-run/work/aa/000001").path]),
            .init(id: ids[2], status: "exited", mountSources: [work.appendingPathComponent("bb/000002").path]),
            .init(id: ids[3], status: "running", mountSources: [holdingFolder.path]),
        ])
        try docker.watch(pids: [engineID], record: recordFile(of: config), scratch: work)

        run.cancel()
        let outcome = await run.result
        let record = try ProvenanceEnvelopeReader.load(from: config.outputDirectory)

        XCTAssertTrue(outcome.failure is CancellationError, "\(String(describing: outcome.failure))")
        XCTAssertEqual(record?.status, .cancelled, "the record follows the cleanup")
        XCTAssertEqual(record?.exitStatus, 125)
        XCTAssertFalse(engineTestProcessIsRunning(engineID), "no process of the tree outlives the run")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path), "the scratch goes once the record is written")
        assertTheCleanupStoppedOnlyTheRunsContainers(docker, ids: ids)
    }

    func testACancelledDockerRunNeverWaitsPastTheCleanupBound() async throws {
        let engine = try makeEngine(.waitsUntilCancelled)
        let docker = try NextflowStandInDocker.make(in: root)
        docker.hangOnListing()
        let config = try makeConfig(sample: "H1", output: "hung", profile: "docker")
        let pipeline = makePipeline(engine, docker: docker)

        let run = Task { try await pipeline.run(config: config) }
        let started = await engine.waitForLaunch()
        XCTAssertNotNil(started, "the launch never started")
        let clock = ContinuousClock()
        let cancelledAt = clock.now
        run.cancel()
        let outcome = await run.result
        let waited = clock.now - cancelledAt
        let record = try ProvenanceEnvelopeReader.load(from: config.outputDirectory)
        let hungPID = docker.hungPID()
        var stopped = false
        if let hungPID {
            stopped = await waitUntil(timeout: .seconds(30)) { !engineTestProcessIsRunning(hungPID) }
        }

        XCTAssertTrue(outcome.failure is CancellationError, "\(String(describing: outcome.failure))")
        XCTAssertEqual(record?.status, .cancelled, "a cleanup that runs out its bound still leaves the record")
        XCTAssertEqual(record?.exitStatus, 125)
        XCTAssertLessThan(waited, .seconds(6), "N5, a docker that hangs holds the run no longer than the 1.5 s bound, \(waited)")
        XCTAssertNotNil(hungPID, "the cleanup asks docker for the containers")
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(1400), "the run waits for the cleanup up to its bound")
        XCTAssertTrue(stopped, "the docker that hangs is stopped, so none outlives the cleanup")
    }

    // MARK: - The executor route

    /// R4c. `taxtriage run` runs its launch as a unit of the analysis run executor, whose cancelled record is
    /// the root record. A cancel there stops the run's containers after the tree and before that record, as on
    /// the app's route, because the pipeline body both routes share gives the engine the cleanup. The scratch
    /// then stays for the abandoned-scratch sweep (N7, A2 review fix 1).
    func testACancelOnTheExecutorRouteStopsItsContainersBeforeTheRootRecord() async throws {
        let engine = try makeEngine(.waitsUntilCancelled)
        let docker = try NextflowStandInDocker.make(in: root)
        let settings = try makeConfig(sample: "E1", output: "unused", profile: "docker")
        let output = root.appendingPathComponent("executor", isDirectory: true)
        let pipeline = makePipeline(engine, docker: docker)
        let tool = TaxTriageAnalysisRunTool(
            request: TaxTriageRunRequest(input: settings.samples[0].fastq1.path, sampleID: "E1", settings: settings),
            services: TaxTriageRunServices(
                makePipeline: { pipeline },
                expandInputs: { arguments, _ in arguments.map { URL(fileURLWithPath: $0) } },
                materializer: ReadSetFixtures.StubMaterializer(readsByBundlePath: [:])
            )
        )
        let request = AnalysisRunRequest(
            inputs: [],
            destination: .directory(output),
            groupsSamples: false,
            commandLine: ["lungfish-cli", "taxtriage", "run"]
        )

        let run = Task { await AnalysisRunExecutor(services: AnalysisRunServices()).execute(tool, request, events: .discarding) }
        let started = await engine.waitForLaunch()
        let launch = try XCTUnwrap(started, "the launch never started")
        let engineID = try XCTUnwrap(launch.processIdentifier)
        let work = URL(fileURLWithPath: try XCTUnwrap(launch.workDirectory, "the launch names no work folder"), isDirectory: true)
        // The sweep removes a scratch a cancelled run leaves, and this case removes its own.
        addTeardownBlock { try? FileManager.default.removeItem(at: work.deletingLastPathComponent()) }
        let holdingFolder = work.deletingLastPathComponent().deletingLastPathComponent()
        let ids = ["a1", "b2", "c3", "d4"].map { String(repeating: $0, count: 32) }
        try docker.serve([
            .init(id: ids[0], status: "running", mountSources: [holdingFolder.path, work.appendingPathComponent("aa/000001").path]),
            .init(id: ids[1], status: "running", mountSources: [root.appendingPathComponent("other-run/work/aa/000001").path]),
            .init(id: ids[2], status: "exited", mountSources: [work.appendingPathComponent("bb/000002").path]),
            .init(id: ids[3], status: "running", mountSources: [holdingFolder.path]),
        ])
        try docker.watch(pids: [engineID], record: output.appendingPathComponent(ProvenanceRecorder.provenanceFilename), scratch: work)

        run.cancel()
        let report = await run.value
        let record = try ProvenanceEnvelopeReader.load(from: output)

        XCTAssertEqual(report.status, .cancelled, report.message ?? "")
        XCTAssertEqual(report.exitCode, 125)
        XCTAssertEqual(record?.workflowName, TaxTriageAnalysisRunTool.workflowName, "the executor writes the cancelled run's record")
        XCTAssertEqual(record?.status, .cancelled, "the root record follows the cleanup")
        XCTAssertEqual(record?.exitStatus, 125)
        XCTAssertFalse(engineTestProcessIsRunning(engineID), "no process of the tree outlives the run")
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.path), "a cancelled executor launch leaves its scratch for the sweep (N7)")
        assertTheCleanupStoppedOnlyTheRunsContainers(docker, ids: ids)
    }

    // MARK: - Runs that call no docker

    func testACompletedDockerRunCallsNoDocker() async throws {
        let engine = try makeEngine(.completes)
        let docker = try NextflowStandInDocker.make(in: root)
        let config = try makeConfig(sample: "D1", output: "completed", profile: "docker")

        _ = try await makePipeline(engine, docker: docker).run(config: config)

        XCTAssertEqual(try engine.launches().map(\.exitStatus), [0], "the engine completed")
        XCTAssertEqual(docker.calls(), [], "only a cancelled run stops containers")
    }

    func testAFailedDockerRunCallsNoDocker() async throws {
        let engine = try makeEngine(.failsSamples(["F1"]))
        let docker = try NextflowStandInDocker.make(in: root)
        let config = try makeConfig(sample: "F1", output: "failed", profile: "docker")

        do {
            _ = try await makePipeline(engine, docker: docker).run(config: config)
            XCTFail("a failed sample fails the run")
        } catch is CancellationError {
            XCTFail("a failed run is not a cancel")
        } catch {
            // The run failed, as the engine's exit 1 says.
        }

        XCTAssertEqual(try engine.launches().map(\.exitStatus), [1], "the engine failed")
        XCTAssertEqual(docker.calls(), [], "a failed run leaves its containers to Nextflow, which removes them")
    }

    func testACancelledRunOfAProfileWithoutDockerCallsNoDocker() async throws {
        let engine = try makeEngine(.waitsUntilCancelled)
        let docker = try NextflowStandInDocker.make(in: root)
        let config = try makeConfig(sample: "L1", output: "local", profile: TaxTriageStandInEngine.profile)
        let pipeline = makePipeline(engine, docker: docker)

        let run = Task { try await pipeline.run(config: config) }
        let started = await engine.waitForLaunch()
        XCTAssertNotNil(started, "the launch never started")
        run.cancel()
        let outcome = await run.result

        XCTAssertTrue(outcome.failure is CancellationError, "\(String(describing: outcome.failure))")
        XCTAssertEqual(docker.calls(), [], "a run whose profile runs no task in Docker has no container to stop")
    }

    // MARK: - Helpers

    /// The cleanup listed every container, read their mounts, killed the run's running container and removed
    /// both of the run's containers, each id an argument of its own, and at every call the tree was gone, the
    /// record not yet written and the scratch still in place (N5). The foreign container and the one that
    /// mounts only the folder holding the scratch were never named.
    private func assertTheCleanupStoppedOnlyTheRunsContainers(
        _ docker: NextflowStandInDocker,
        ids: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            docker.arguments(),
            [
                ["ps", "--all", "--quiet", "--no-trunc"],
                ["inspect", "--type", "container", "--format", "{{.Id}}|{{.State.Status}}|{{json .Mounts}}"] + ids,
                ["kill", ids[0]],
                ["rm", ids[0], ids[2]],
            ],
            file: file,
            line: line
        )
        XCTAssertEqual(
            docker.calls().map(\.argumentCount),
            docker.calls().map(\.arguments.count),
            "each id reaches docker as an argument of its own",
            file: file,
            line: line
        )
        XCTAssertEqual(
            docker.observations(),
            [
                "ps tree=gone record=absent scratch=present",
                "kill tree=gone record=absent scratch=present",
                "rm tree=gone record=absent scratch=present",
            ],
            "N5, the host tree is gone, the record waits and the scratch is in place at every docker call",
            file: file,
            line: line
        )
    }

    /// The stand-in engine for one case, stopped in teardown so no stand-in outlives a case that fails.
    private func makeEngine(_ behaviour: TaxTriageStandInEngine.Behaviour) throws -> TaxTriageStandInEngine {
        let engine = try TaxTriageStandInEngine(root: root.appendingPathComponent("engine", isDirectory: true), behaviour: behaviour)
        addTeardownBlock { await engine.stopLeftoverProcesses() }
        return engine
    }

    /// A pipeline that launches `engine`, with a Docker probe whose daemon answers and whose CLI is `docker`.
    private func makePipeline(_ engine: TaxTriageStandInEngine, docker: NextflowStandInDocker) -> TaxTriagePipeline {
        let home = engine.home
        return TaxTriagePipeline(
            processManager: .shared,
            condaManager: engine.condaManager,
            homeDirectoryProvider: { home },
            appIdentity: .preview,
            containerRuntimeProbe: StandInDockerProbe(dockerPath: docker.executable.path)
        )
    }

    /// One single-end sample of two records into `output` under the case's folder.
    private func makeConfig(sample: String, output: String, profile: String) throws -> TaxTriageConfig {
        let reads = root.appendingPathComponent("reads", isDirectory: true)
        try FileManager.default.createDirectory(at: reads, withIntermediateDirectories: true)
        let fastq = reads.appendingPathComponent("\(sample).fastq")
        try (1...2).map { "@\(sample)-read-\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
            .write(to: fastq, atomically: true, encoding: .utf8)
        let database = root.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        return TaxTriageConfig(
            samples: [TaxTriageSample(sampleId: sample, fastq1: fastq)],
            outputDirectory: root.appendingPathComponent(output, isDirectory: true),
            kraken2DatabasePath: database,
            maxCpus: 2,
            profile: profile
        )
    }

    private func recordFile(of config: TaxTriageConfig) -> URL {
        config.outputDirectory.appendingPathComponent(ProvenanceRecorder.provenanceFilename)
    }
}

private extension Result {
    /// The error of a failed result, else nil.
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
