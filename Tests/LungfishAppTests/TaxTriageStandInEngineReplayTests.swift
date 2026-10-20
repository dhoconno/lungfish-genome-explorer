// TaxTriageStandInEngineReplayTests.swift - One TaxTriage sample through each launch seam on the stand-in engine
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.8 lane TF-G, decisions T14 and T16 (docs/plans/2026-10-11-phase-2-8.md). One sample runs
// through the CLI's pipeline factory, `TaxTriageCommand.RunSubcommand.makePipeline`, which
// `taxtriage run` reads, on `TaxTriageStandInEngine`, and the case checks what today's code writes,
// what the engine received, the result and its provenance record. The case of the GUI's runner
// factory went with the in-process route in Phase 2.12 K1.
//
// The engine starts processes, so the class runs serially. Its name ends in ReplayTests, which
// sends it to the integration tier (`REPLAY_SUITES` in scripts/full-suite-gate.sh).

import AppKit
import Foundation
import XCTest
@testable import LungfishApp
@testable import LungfishCLI
import LungfishIO
import LungfishKit
@testable import LungfishOperations
import LungfishTestSupport
@testable import LungfishWorkflow

@MainActor
final class TaxTriageStandInEngineReplayTests: XCTestCase {
    private var scratch: URL!

    enum StandInError: Error {
        case missingCLI
    }

    override func setUp() async throws {
        try await super.setUp()
        scratch = try TestTempDirectory.make(prefix: "taxtriage-stand-in")
    }

    override func tearDown() async throws {
        OperationCenter.shared.clearCompleted()
        TestTempDirectory.cleanup(scratch)
        try await super.tearDown()
    }

    // MARK: - CLI

    func testOneSampleThroughTheCLIPipelineFactoryRunsOnTheStandIn() async throws {
        let engine = try makeEngine()
        let mate1 = try writeFASTQ("P1_R1.fastq", records: 5)
        let mate2 = try writeFASTQ("P1_R2.fastq", records: 5)
        let database = try makeDatabaseFolder()
        let output = scratch.appendingPathComponent("cli-output", isDirectory: true)

        try await Self.runCLI(
            [
                "run",
                "--input", mate1.path,
                "--input2", mate2.path,
                "--sample", "P1",
                "--output", output.path,
                "--db", database.path,
                "--nf-profile", TaxTriageStandInEngine.profile,
                "--max-cpus", "2",
                "--quiet",
            ],
            engine: engine
        )

        let launch = try Self.onlyLaunch(of: engine)
        Self.assertLaunch(
            launch,
            engine: engine,
            outputDirectory: output,
            database: database,
            samplesheet: "sample,fastq_1,fastq_2,platform\nP1,\(mate1.path),\(mate2.path),ILLUMINA\n",
            records: [
                .init(sample: "P1", column: "fastq_1", path: mate1.path, records: 5),
                .init(sample: "P1", column: "fastq_2", path: mate2.path, records: 5),
            ]
        )
        try Self.assertResult(in: output, sample: "P1", launch: launch, engine: engine, missingRecordFiles: [])
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: output.appendingPathComponent("taxtriage.sqlite").path),
            "today `taxtriage run` builds no taxtriage.sqlite, where the app runs build-db after the pipeline"
        )
    }

    // MARK: - Switches, through the pipeline the factories build

    func testFailingASampleFailsThatSampleOfASerialBatch() async throws {
        let engine = try makeEngine(.failsSamples(["S2"]))
        let config = try makeConfig([("S1", 3), ("S2", 4)], output: "batch")

        // 2.13 K1b. The batch runs on the executor, the route of a TaxTriage batch, where it ran the serial batch
        // runner, and the batch result it reads is the aggregate the executor publishes at the batch root.
        _ = try await engine.runBatch(config)
        let result = try TaxTriageResult.load(from: config.outputDirectory)

        XCTAssertEqual(result.sampleFailures.map(\.sampleID), ["S2"])
        XCTAssertEqual(result.reportFiles.map(\.lastPathComponent), ["S1.odr.txt"])
        let launches = try engine.launches()
        XCTAssertEqual(launches.map(\.exitStatus), [0, 1])
        XCTAssertEqual(launches.map { $0.fastqRecords.map(\.records) }, [[3], [4]])
    }

    func testReportingErroredTasksEndsWithAnIgnoredAlignmentFailure() async throws {
        let engine = try makeEngine(.reportsErroredTasks)
        let config = try makeConfig([("S1", 3)], output: "errored")

        let result = try await engine.makePipeline().run(config: config)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertTrue(result.completedWithErrors)
        XCTAssertEqual(result.ignoredFailures.map(\.processName), ["MINIMAP2_ALIGN"])
        XCTAssertEqual(result.ignoredFailures.map(\.sampleID), ["S1"])
        XCTAssertEqual(result.ignoredFailures.map(\.exitCode), [137])
    }

    func testAWaitingLaunchCompletesOnceReleased() async throws {
        let engine = try makeEngine(.waitsUntilCancelled)
        let config = try makeConfig([("S1", 2)], output: "waiting")

        let run = Task { try await engine.makePipeline().run(config: config) }
        let started = await engine.waitForLaunch()
        XCTAssertNotNil(started, "the launch never started")
        XCTAssertNil(started?.exitStatus, "a waiting launch has not exited")
        engine.release()
        let result = try await run.value

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(try engine.launches().map(\.exitStatus), [0])
    }

    func testAWaitingLaunchEndsAtOnceOnTerm() async throws {
        let engine = try makeEngine(.waitsUntilCancelled)
        let config = try makeConfig([("S1", 2)], output: "terminated")

        let run = Task { try? await engine.makePipeline().run(config: config) }
        let started = await engine.waitForLaunch()
        let launch = try XCTUnwrap(started, "the launch never started")
        let engineID = try XCTUnwrap(launch.processIdentifier)

        XCTAssertEqual(kill(engineID, SIGTERM), 0)
        let ended = await waitUntil(timeout: .seconds(30)) { kill(engineID, 0) != 0 }
        XCTAssertTrue(ended, "a waiting launch must end on TERM")
        _ = await run.value
        XCTAssertEqual(try engine.launches().map(\.exitStatus), [nil], "a launch a signal ended records no exit status")
    }

    func testTheTermTrappingLaunchAndItsHeartbeatChildOutliveTermUntilStopped() async throws {
        let engine = try makeEngine(.trapsTermWithHeartbeatChild)
        let config = try makeConfig([("S1", 2)], output: "trapping")

        let run = Task { try? await engine.makePipeline().run(config: config) }
        let started = await engine.waitForLaunch()
        let launch = try XCTUnwrap(started, "the launch never started")
        let engineID = try XCTUnwrap(launch.processIdentifier)
        let childID = try XCTUnwrap(launch.childProcessIdentifier)

        // Both traps are set before the launch is marked started, so TERM may go at once.
        XCTAssertEqual(kill(engineID, SIGTERM), 0)
        XCTAssertEqual(kill(childID, SIGTERM), 0)
        let beating = await waitUntil(timeout: .seconds(30)) { Self.lineCount(launch.heartbeat) >= 2 }
        XCTAssertTrue(beating, "the child wrote no heartbeat")
        let trapped = await waitUntil(timeout: .seconds(30)) {
            let current = try? engine.launches().first
            return current?.trappedSignals == ["TERM"] && current?.childTrappedSignals == ["TERM"]
        }
        XCTAssertTrue(trapped, "both must record the TERM they trapped")
        let beats = Self.lineCount(launch.heartbeat)
        let beatingOn = await waitUntil(timeout: .seconds(30)) { Self.lineCount(launch.heartbeat) > beats }
        XCTAssertTrue(beatingOn, "the child must beat on after TERM")
        XCTAssertEqual(kill(engineID, 0), 0, "the engine must outlive TERM")

        await engine.stopLeftoverProcesses()
        XCTAssertNotEqual(kill(engineID, 0), 0, "the engine must end once stopped")
        XCTAssertNotEqual(kill(childID, 0), 0, "the child must end once stopped")
        _ = await run.value
        XCTAssertEqual(try engine.launches().map(\.exitStatus), [143])
    }

    // MARK: - Checks

    /// What the stand-in received: the Nextflow arguments of today's launch, the samplesheet bytes
    /// the pipeline wrote, the FASTQ records each input held and the launch environment.
    private static func assertLaunch(
        _ launch: TaxTriageStandInEngine.Launch,
        engine: TaxTriageStandInEngine,
        outputDirectory: URL,
        database: URL,
        samplesheet: String,
        records: [TaxTriageStandInEngine.FASTQRecords],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(launch.exitStatus, 0, file: file, line: line)
        XCTAssertEqual(launch.value(after: "--outdir"), outputDirectory.path, file: file, line: line)
        XCTAssertEqual(
            launch.value(after: "--input"),
            outputDirectory.appendingPathComponent("samplesheet.csv").path,
            file: file,
            line: line
        )
        XCTAssertEqual(launch.value(after: "--db"), database.path, file: file, line: line)
        XCTAssertEqual(launch.value(after: "-profile"), TaxTriageStandInEngine.profile, file: file, line: line)
        XCTAssertEqual(launch.value(after: "-r"), (try? NextflowWorkflowDescriptor.taxTriage.resolveBundledPin())?.revision, file: file, line: line)
        XCTAssertEqual(launch.value(after: "--max_cpus"), "2", file: file, line: line)
        XCTAssertEqual(Array(launch.arguments.prefix(3)), ["-c", outputDirectory.appendingPathComponent("lungfish.nextflow.config").path, "run"], file: file, line: line)
        XCTAssertEqual(String(decoding: launch.samplesheet, as: UTF8.self), samplesheet, file: file, line: line)
        XCTAssertEqual(
            try? Data(contentsOf: outputDirectory.appendingPathComponent("samplesheet.csv")),
            launch.samplesheet,
            "the samplesheet the result keeps is the one the engine read",
            file: file,
            line: line
        )
        XCTAssertEqual(launch.fastqRecords, records, file: file, line: line)
        XCTAssertEqual(launch.environment["HOME"], engine.home.path, file: file, line: line)
        XCTAssertEqual(launch.environment["MAMBA_ROOT_PREFIX"], engine.condaRoot.path, file: file, line: line)
        XCTAssertEqual(
            launch.environment["NXF_HOME"].map { $0.hasPrefix(engine.home.path + "/") },
            true,
            "a stand-in run keeps Nextflow's home inside the engine, never the real one",
            file: file,
            line: line
        )
        XCTAssertNil(launch.environment["NXF_CONDA_ENABLED"], "a profile other than conda drops the conda variables", file: file, line: line)
    }

    /// What today's pipeline wrote around the stand-in: the result, the provenance record whose
    /// TaxTriage step names the launch the engine received, and which files the record names that
    /// are gone after the run, relative to `outputDirectory`.
    private static func assertResult(
        in outputDirectory: URL,
        sample: String,
        launch: TaxTriageStandInEngine.Launch,
        engine: TaxTriageStandInEngine,
        missingRecordFiles: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let result = try TaxTriageResult.load(from: outputDirectory)
        XCTAssertEqual(result.exitCode, 0, file: file, line: line)
        XCTAssertEqual(result.config.samples.map(\.sampleId), [sample], file: file, line: line)
        XCTAssertEqual(result.reportFiles.map(\.lastPathComponent), ["\(sample).odr.txt"], file: file, line: line)
        XCTAssertTrue(result.ignoredFailures.isEmpty, "\(result.ignoredFailures)", file: file, line: line)
        XCTAssertEqual(result.traceFile?.lastPathComponent, "trace.txt", file: file, line: line)

        let provenance = try XCTUnwrap(ProvenanceRecorder.load(from: outputDirectory), file: file, line: line)
        XCTAssertEqual(provenance.status, .completed, file: file, line: line)
        let step = try XCTUnwrap(provenance.steps.first { $0.toolName == "taxtriage" }, file: file, line: line)
        XCTAssertEqual(step.exitCode, 0, file: file, line: line)
        XCTAssertEqual(
            step.command,
            [engine.micromamba.path, "run", "-n", "nextflow", "nextflow"] + launch.arguments,
            "the record names the command that launched the engine",
            file: file,
            line: line
        )
        XCTAssertFalse(step.outputs.isEmpty, file: file, line: line)
        let prefix = outputDirectory.path + "/"
        let missing = (step.inputs + step.outputs).map(\.path)
            .filter { !FileManager.default.fileExists(atPath: $0) }
            .map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
        XCTAssertEqual(missing, missingRecordFiles, "files the record names that the run left missing", file: file, line: line)
    }

    // MARK: - Helpers

    /// The engine for one case, stopped in teardown so no stand-in outlives the case.
    private func makeEngine(
        _ behaviour: TaxTriageStandInEngine.Behaviour = .completes
    ) throws -> TaxTriageStandInEngine {
        let engine = try TaxTriageStandInEngine(
            root: scratch.appendingPathComponent("engine", isDirectory: true),
            behaviour: behaviour
        )
        addTeardownBlock { await engine.stopLeftoverProcesses() }
        return engine
    }

    /// Points `LUNGFISH_CLI_PATH` at the built CLI, which the GUI's `build-db` step runs.
    private func requireBuiltCLI() throws {
        let productsDirectory = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        guard let cli = CLITestBinaryResolver.cliBinaryURL(buildProductsDirectory: productsDirectory) else {
            XCTFail(
                "No lungfish-cli beside \(productsDirectory.path) and none named by LUNGFISH_CLI_PATH. "
                    + "Without it the GUI path builds no taxtriage.sqlite."
            )
            throw StandInError.missingCLI
        }
        let saved = ProcessInfo.processInfo.environment["LUNGFISH_CLI_PATH"]
        setenv("LUNGFISH_CLI_PATH", cli.path, 1)
        addTeardownBlock {
            if let saved {
                setenv("LUNGFISH_CLI_PATH", saved, 1)
            } else {
                unsetenv("LUNGFISH_CLI_PATH")
            }
        }
    }

    /// Runs `taxtriage run` in this process with the pipeline factory bound to the engine.
    nonisolated private static func runCLI(_ arguments: [String], engine: TaxTriageStandInEngine) async throws {
        let command = try TaxTriageCommand.RunSubcommand.parse(arguments)
        try await TaxTriageCommand.RunSubcommand.$makePipeline.withValue({ engine.makePipeline() }) {
            try await command.run()
        }
    }

    private static func onlyLaunch(
        of engine: TaxTriageStandInEngine,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> TaxTriageStandInEngine.Launch {
        let launches = try engine.launches()
        XCTAssertEqual(launches.count, 1, "the run must launch the engine once", file: file, line: line)
        return try XCTUnwrap(launches.first, file: file, line: line)
    }

    /// A FASTQ of `records` four-line records whose names never pair, so no input reads as
    /// interleaved.
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

    private static func lineCount(_ url: URL) -> Int {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").count
    }

    private static func visibleFolders(in folder: URL) -> [URL] {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

private extension Array {
    /// The element of a one-element array, else nil.
    var onlyElement: Element? { count == 1 ? first : nil }
}
