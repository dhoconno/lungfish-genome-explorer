// Kraken2AnalysisRunToolTests.swift - Kraken2 on the analysis run executor with a stand-in kraken2
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Lane A8 of Phase 2.7. `Kraken2AnalysisRunTool` runs the stand-in kraken2 of
/// `KrakenReadSetPipelineTests` through `AnalysisRunExecutor`, so each test checks the tree, the
/// root record and the events the command line and the app's route both get.
final class Kraken2AnalysisRunToolTests: XCTestCase {

    private var root: URL!
    private var fixtures: ReadSetFixtures!
    private var kraken2: StandInKraken2!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "kraken2-tool").resolvingSymlinksInPath()
        fixtures = try ReadSetFixtures(in: root)
        kraken2 = try StandInKraken2(root: root.appendingPathComponent("stand-in", isDirectory: true))
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - One folder

    func testAPlainFolderRunRecordsTheCommandThePipelineStepsAndNoPresetItWasNotGiven() async throws {
        let output = root.appendingPathComponent("plain-out", isDirectory: true)
        let argv = command([fixtures.singleRoot.path, "--output-dir", output.path])

        let run = await execute(request([fixtures.singleRoot.path]), .directory(output), argv: argv)

        XCTAssertEqual(run.report.status, .completed)
        XCTAssertEqual(run.report.exitCode, 0)
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: XCTUnwrap(run.report.recordURL)))
        XCTAssertEqual(record.workflowName, "lungfish.classify")
        XCTAssertEqual(record.argv, argv)
        XCTAssertTrue(record.steps.contains { $0.toolName == "kraken2" })
        XCTAssertNil(record.options.defaults["preset"], "a preset never given is not a fact (E12)")
        XCTAssertNil(record.options.explicit["preset"])
        XCTAssertNil(record.options.resolvedDefaults["preset"])
        XCTAssertEqual(record.options.defaults["confidence"], .number(ClassificationConfig.Preset.balanced.parameters.confidence))
        XCTAssertEqual(record.options.resolvedDefaults["profileState"], .string("notRequested"))
        XCTAssertEqual(record.options.explicit["outputDirectory"], .file(output))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("classification-result.json").path))
        XCTAssertNil(AnalysesFolder.readAnalysisMetadata(from: output), "a folder outside a project gets no metadata (E1b)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("kraken2.sqlite").path))
        XCTAssertEqual(kind(of: run.events.first?.event), "start")
        XCTAssertEqual(run.events.dropFirst().first?.event, Optional(CLIEvent.output(path: output.path, role: CLIEventArtifact.Role.analysisDirectory)))
        XCTAssertEqual(kind(of: run.events.last?.event), "complete")
    }

    func testAGivenPresetIsRecordedAsGiven() async throws {
        let output = root.appendingPathComponent("preset-out", isDirectory: true)
        var given = request([fixtures.singleRoot.path])
        given.preset = .sensitive
        let argv = command([fixtures.singleRoot.path, "--preset", "sensitive", "--output-dir", output.path])

        let run = await execute(given, .directory(output), argv: argv)

        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: XCTUnwrap(run.report.recordURL)))
        XCTAssertEqual(record.options.explicit["preset"], .string("sensitive"))
        XCTAssertEqual(record.options.resolvedDefaults["preset"], .string("sensitive"))
        XCTAssertEqual(
            record.options.resolvedDefaults["confidence"],
            .number(ClassificationConfig.Preset.sensitive.parameters.confidence)
        )
    }

    func testAMergeBundleKeepsItsReadSetPlanInTheResolvedOptions() async throws {
        let output = root.appendingPathComponent("merge-out", isDirectory: true)
        let argv = command([fixtures.mergeDerivative.path, "--output-dir", output.path])

        let run = await execute(request([fixtures.mergeDerivative.path]), .directory(output), argv: argv)

        XCTAssertEqual(run.report.status, .completed, run.report.message)
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: XCTUnwrap(run.report.recordURL)))
        XCTAssertNotNil(record.options.resolvedDefaults[AnalysisRootRecordOptions.readSetPlanKey], "D6 is closed (E13)")
        XCTAssertTrue(try kraken2.argv().contains("--paired"))
    }

    func testAVirtualSubsetIsMaterializedIntoTheResultKeptAndNamedByTheReplayArgv() async throws {
        let output = root.appendingPathComponent("virtual-out", isDirectory: true)
        let subset = fixtures.subsetOfSingle.standardizedFileURL
        let materializer = ReadSetFixtures.StubMaterializer(readsByBundlePath: [subset.path: ReadSetFixtures.fastq(["r1", "r2"])])
        let argv = command([subset.path, "--output-dir", output.path])

        let run = await execute(request([subset.path]), .directory(output), argv: argv, materializer: materializer)

        XCTAssertEqual(run.report.status, .completed, run.report.message)
        let inputs = output.appendingPathComponent(KrakenReadSetPlanner.inputsDirectoryName, isDirectory: true)
        let kept = try FileManager.default.contentsOfDirectory(atPath: inputs.path).filter { $0.hasSuffix(".fastq") }
        XCTAssertEqual(kept.count, 1, "the materialization is kept in the result (E3)")
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: XCTUnwrap(run.report.recordURL)))
        let replay = try XCTUnwrap(record.durableReplayArgv)
        XCTAssertTrue(replay.contains(inputs.appendingPathComponent(kept[0]).path), "\(replay)")
        XCTAssertTrue(record.steps.contains { $0.toolName == CLISequenceInputMaterialization.materializationToolName })
    }

    func testADegradedProfileCompletesWithAWarningAndRecordsItsReason() async throws {
        let output = root.appendingPathComponent("degraded-out", isDirectory: true)
        var profile = request([fixtures.singleRoot.path])
        profile.profile = true
        let argv = command([fixtures.singleRoot.path, "--profile", "--output-dir", output.path])
        let pipeline = ClassificationPipeline(condaManager: kraken2.condaManager)
        let degrading: @Sendable (ClassificationConfig, @escaping @Sendable (Double, String) -> Void) async throws -> ClassificationResult = { config, progress in
            let classified = try await pipeline.classify(config: config, progress: progress)
            let request = config.brackenProfileRequest ?? .automaticDefault
            return ClassificationResult(
                config: config,
                tree: classified.tree,
                reportURL: classified.reportURL,
                outputURL: classified.outputURL,
                brackenURL: nil,
                profileOutcome: .degraded(
                    resolution: BrackenDatabaseCapabilities.resolve(catalogID: nil, installationRecipe: nil, request: request),
                    reason: .rankAbsentFromReport,
                    message: "The report holds no species rank."
                ),
                runtime: classified.runtime,
                toolVersion: classified.toolVersion,
                provenanceId: nil
            )
        }

        let run = await execute(profile, .directory(output), argv: argv, runPipeline: degrading)

        XCTAssertEqual(run.report.status, .completed, "a degraded profile completes (E4)")
        XCTAssertEqual(run.report.exitCode, 0)
        XCTAssertEqual(run.report.warnings, [
            "Kraken classification completed, but Bracken profiling did not complete: The report holds no species rank.",
        ])
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: XCTUnwrap(run.report.recordURL)))
        XCTAssertEqual(record.status, .completed)
        XCTAssertEqual(record.options.resolvedDefaults["profileState"], .string("degraded"))
        XCTAssertEqual(record.options.resolvedDefaults["profileReason"], .string("rankAbsentFromReport"))
        XCTAssertTrue(run.events.contains { $0.event == Optional(CLIEvent.log(level: .warning, message: run.report.warnings[0])) })
    }

    // MARK: - Batch

    func testABatchGroupsSamplesIntoFoldersWithSummaryManifestIndexAndSourceRecords() async throws {
        let inputs = [fixtures.singleRoot.path, fixtures.interleavedRoot.path]
        let argv = command(inputs + ["--batch", "--project", fixtures.projectURL.path])
        let indexer = StubKraken2Indexer()

        let run = await execute(request(inputs), .project(fixtures.projectURL), batch: true, argv: argv, indexing: indexer)

        XCTAssertEqual(run.report.status, .completed, run.report.message)
        let batchRoot = try XCTUnwrap(run.report.analysisDirectory)
        XCTAssertTrue(batchRoot.lastPathComponent.hasPrefix("kraken2-batch-"))
        XCTAssertEqual(AnalysesFolder.readAnalysisMetadata(from: batchRoot)?.isBatch, true)
        let manifest = try XCTUnwrap(MetagenomicsBatchResultStore.loadClassification(from: batchRoot))
        XCTAssertEqual(manifest.samples.count, 2)
        for sample in manifest.samples {
            let folder = batchRoot.appendingPathComponent(sample.resultDirectory)
            XCTAssertTrue(ClassificationResult.exists(in: folder), sample.sampleId)
            XCTAssertNotNil(ProvenanceRecorder.loadEnvelope(from: folder), "the sample keeps the pipeline's record")
        }
        let summary = try String(contentsOf: batchRoot.appendingPathComponent("classification-batch-summary.tsv"), encoding: .utf8)
        XCTAssertEqual(summary.split(separator: "\n").count, 3)
        XCTAssertEqual(indexer.requests, [batchRoot.standardizedFileURL.path])
        XCTAssertEqual(run.report.message, "2 of 2 samples returned valid Kraken2 classifications")
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: XCTUnwrap(run.report.recordURL)))
        XCTAssertEqual(record.argv, argv, "the batch records the command that ran, not a shell script (E8)")
        XCTAssertTrue(record.steps.contains { $0.toolName == StubKraken2Indexer.stepName })
        XCTAssertEqual(record.options.explicit["batch"], .boolean(true))
        for bundle in [fixtures.singleRoot, fixtures.interleavedRoot] {
            let entries = AnalysisManifestStore.load(bundleURL: bundle, projectURL: fixtures.projectURL).analyses
            XCTAssertEqual(entries.map(\.displayName), ["Kraken2 Batch"], bundle.lastPathComponent)
        }
    }

    // MARK: - Refusals

    func testEveryRefusalComesBeforeAnyFolderWithItsExitCode() async throws {
        let output = root.appendingPathComponent("refused", isDirectory: true)
        var unknown = request([fixtures.singleRoot.path]); unknown.databaseName = "Missing"
        var badDigest = request([fixtures.singleRoot.path]); badDigest.databaseDigest = "not-a-digest"
        var noReceipt = request([fixtures.singleRoot.path]); noReceipt.databaseDigest = String(repeating: "a", count: 64)
        var tooConfident = request([fixtures.singleRoot.path]); tooConfident.confidence = 1.5
        var pairedBatch = request([fixtures.singleRoot.path]); pairedBatch.pairedEnd = true
        let cases: [(String, Kraken2RunRequest, Bool, Int32)] = [
            ("unknown database", unknown, false, 3),
            ("malformed digest", badDigest, false, 3),
            ("digest without a receipt", noReceipt, false, 126),
            ("confidence out of range", tooConfident, false, 3),
            ("--paired with --batch", pairedBatch, true, 3),
        ]
        for (name, given, batch, code) in cases {
            let run = await execute(given, .directory(output), batch: batch, argv: command([fixtures.singleRoot.path]))
            XCTAssertEqual(run.report.status, .failed, name)
            XCTAssertEqual(run.report.exitCode, code, name)
            XCTAssertNil(run.report.analysisDirectory, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), name)
            XCTAssertEqual(kind(of: run.events.last?.event), "failed", name)
        }
    }

    // MARK: - Helpers

    private func kind(of event: CLIEvent?) -> String {
        guard let event else { return "none" }
        switch event {
        case .start: return "start"
        case .progress: return "progress"
        case .log: return "log"
        case .output: return "output"
        case .complete: return "complete"
        case .failed: return "failed"
        }
    }

    private func command(_ arguments: [String]) -> [String] {
        ["lungfish-cli", "kraken2", "classify", "--db", "Viral"] + arguments
    }

    private func request(_ inputs: [String]) -> Kraken2RunRequest {
        Kraken2RunRequest(inputArguments: inputs, databaseName: "Viral", threads: 1)
    }

    private func execute(
        _ request: Kraken2RunRequest,
        _ destination: AnalysisRunDestination,
        batch: Bool = false,
        argv: [String],
        materializer: any CLISequenceInputMaterializing & Sendable = ReadSetFixtures.StubMaterializer(readsByBundlePath: [:]),
        indexing: (any AnalysisResultIndexing)? = nil,
        runPipeline: (@Sendable (ClassificationConfig, @escaping @Sendable (Double, String) -> Void) async throws -> ClassificationResult)? = nil
    ) async -> (report: AnalysisRunReport, events: [CLIEventLine]) {
        let databaseURL = kraken2.databaseURL
        let database = MetagenomicsDatabaseInfo(
            name: "Viral", tool: "kraken2", version: "2026.1", sizeBytes: 1, sizeOnDisk: 1, downloadURL: nil,
            description: "stand-in", collection: nil, path: databaseURL, isExternal: false, bookmarkData: nil,
            lastUpdated: Date(), status: .ready, recommendedRAM: 1
        )
        let pipeline = ClassificationPipeline(condaManager: kraken2.condaManager)
        let services = Kraken2RunServices(
            database: { $0 == "Viral" ? database : nil },
            availableDatabases: { [database] },
            materializer: materializer,
            runPipeline: runPipeline ?? { config, progress in
                try await pipeline.classify(config: config, progress: progress)
            }
        )
        let lines = Kraken2EventCollector()
        let report = await AnalysisRunExecutor(
            services: AnalysisRunServices(writer: ProvenanceWriter(signingProvider: nil), indexing: indexing)
        ).execute(
            Kraken2AnalysisRunTool(request: request, services: services),
            AnalysisRunRequest(inputs: [], destination: destination, groupsSamples: batch, commandLine: argv),
            events: AnalysisRunEvents { lines.append($0) }
        )
        return (report, lines.lines)
    }
}

/// Collects the event lines of a run.
private final class Kraken2EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CLIEventLine] = []

    var lines: [CLIEventLine] { lock.withLock { stored } }

    func append(_ line: CLIEventLine) {
        lock.withLock { stored.append(line) }
    }
}

/// Stands in for the command line's index builder over the `build-db kraken2` core.
private final class StubKraken2Indexer: AnalysisResultIndexing, @unchecked Sendable {
    static let stepName = "stub kraken2 index"
    private let lock = NSLock()
    private var seen: [String] = []

    var requests: [String] { lock.withLock { seen } }

    func buildIndex(_ request: AnalysisResultIndexRequest) async throws -> AnalysisResultIndex {
        lock.withLock { seen.append(request.resultDirectory.standardizedFileURL.path) }
        let database = request.resultDirectory.appendingPathComponent("kraken2.sqlite")
        try Data("index".utf8).write(to: database)
        let now = Date()
        return AnalysisResultIndex(
            outputs: [AnalysisRunOutput(url: database, role: .index)],
            steps: [ProvenanceStep(
                toolName: Self.stepName, toolVersion: "1", argv: ["index"], exitStatus: 0,
                wallTimeSeconds: 0, startedAt: now, completedAt: now
            )]
        )
    }
}
