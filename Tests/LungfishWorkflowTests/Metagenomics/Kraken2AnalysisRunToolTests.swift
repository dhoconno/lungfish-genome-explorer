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

    var root: URL!
    var fixtures: ReadSetFixtures!
    var kraken2: StandInKraken2!

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
        // Review A8 fix 5e, from the deleted wrapper tests.
        let keptFile = inputs.appendingPathComponent(kept[0]).standardizedFileURL
        XCTAssertEqual(record.options.resolvedDefaults["originalInputs"], .array([.file(subset)]))
        XCTAssertEqual(record.options.resolvedDefaults["executionInputs"], .array([.file(keptFile)]))
        let kraken2Step = try XCTUnwrap(record.steps.first { $0.toolName == "kraken2" })
        let traced = (kraken2Step.inputs + record.files).contains { $0.path == keptFile.path && $0.originPath == subset.path }
        XCTAssertTrue(traced, "the kept file kraken2 read traces to the bundle: \(kraken2Step.inputs.map(\.path))")
    }

    /// A10 review fix 5 (UX D5, D14). The lines a virtual input's materialization reports are
    /// progress at the start of its unit, so the app's row shows each as its detail and in the
    /// viewer's overlay, and none is a log line. Text mode prints them through the presentation, as
    /// the command always has.
    func testMaterializationLinesAreProgressAtTheStartOfTheUnit() async throws {
        let output = root.appendingPathComponent("virtual-progress-out", isDirectory: true)
        let subset = fixtures.subsetOfSingle.standardizedFileURL
        let lines = ["Materializing subset.lungfishfastq", "Wrote 2 reads"]
        let materializer = ReportingMaterializer(
            lines: lines,
            base: ReadSetFixtures.StubMaterializer(readsByBundlePath: [subset.path: ReadSetFixtures.fastq(["r1", "r2"])])
        )
        let printed = Kraken2Captured<String>()

        let run = await execute(
            request([subset.path]), .directory(output),
            argv: command([subset.path, "--output-dir", output.path]),
            materializer: materializer,
            presentation: Kraken2RunPresentation(resolving: { printed.append($0) })
        )

        XCTAssertEqual(run.report.status, .completed, run.report.message)
        let events = run.events.compactMap(\.event)
        XCTAssertEqual(
            events.filter { event in
                if case .progress(_, let message) = event { return lines.contains(message) }
                return false
            },
            lines.map { CLIEvent.progress(fraction: 0, message: $0) }
        )
        XCTAssertFalse(events.contains { event in
            if case .log(_, let message) = event { return lines.contains(message) }
            return false
        }, "no materialization line is a log line")
        XCTAssertEqual(printed.values, lines, "text mode prints each line")
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
        let inputs = [fixtures.singleRoot.path, fixtures.interleavedRoot.path, fixtures.mixedRoot.path]
        let argv = command(inputs + ["--batch", "--project", fixtures.projectURL.path])
        let indexer = StubKraken2Indexer()
        // Review A8c fix 3. Each sample's record as the pipeline left it, before the unit converges it.
        let pipeline = ClassificationPipeline(condaManager: kraken2.condaManager)
        let written = Kraken2Captured<(folder: String, record: ProvenanceEnvelope)>()
        let capturing: PipelineRun = { config, progress in
            let result = try await pipeline.classify(config: config, progress: progress)
            if let record = ProvenanceRecorder.loadEnvelope(from: config.outputDirectory) {
                written.append((config.outputDirectory.lastPathComponent, record))
            }
            return result
        }

        let run = await execute(request(inputs), .project(fixtures.projectURL), batch: true, argv: argv, indexing: indexer, runPipeline: capturing)

        XCTAssertEqual(run.report.status, .completed, run.report.message)
        XCTAssertEqual(written.values.count, 3, "each sample's pipeline wrote its record")
        let batchRoot = try XCTUnwrap(run.report.analysisDirectory)
        XCTAssertTrue(batchRoot.lastPathComponent.hasPrefix("kraken2-batch-"))
        XCTAssertEqual(AnalysesFolder.readAnalysisMetadata(from: batchRoot)?.isBatch, true)
        let manifest = try XCTUnwrap(MetagenomicsBatchResultStore.loadClassification(from: batchRoot))
        XCTAssertEqual(manifest.samples.count, 3)
        for sample in manifest.samples {
            let folder = batchRoot.appendingPathComponent(sample.resultDirectory)
            XCTAssertTrue(ClassificationResult.exists(in: folder), sample.sampleId)
            let sampleRecord = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: folder), "the sample keeps the pipeline's record")
            // Review A8 fix 4. One defaults table, the command's, and no preset nobody gave (E12, D8).
            let defaults = sampleRecord.options.defaults
            XCTAssertNil(defaults["preset"], sample.sampleId)
            XCTAssertEqual(defaults["confidence"], .number(ClassificationConfig.Preset.balanced.parameters.confidence), sample.sampleId)
            XCTAssertEqual(defaults["readFormat"], .string(Kraken2ReadFormatChoice.auto.rawValue), sample.sampleId)
            for (key, value) in Kraken2RunRecordOptions.commandDefaults where defaults[key] != nil {
                XCTAssertEqual(defaults[key], value, "\(sample.sampleId) \(key)")
            }
            XCTAssertNil(sampleRecord.options.explicit[AnalysisRootRecordOptions.readSetPlanKey], sample.sampleId)
            // The load and rewrite lose nothing but the options they converge.
            let before = try XCTUnwrap(written.values.first { $0.folder == sample.resultDirectory }?.record, sample.sampleId)
            XCTAssertEqual(sampleRecord.steps, before.steps, sample.sampleId)
            XCTAssertEqual(sampleRecord.outputs, before.outputs, sample.sampleId)
            XCTAssertEqual(sampleRecord.files, before.files, sample.sampleId)
            XCTAssertEqual(sampleRecord.status, before.status, sample.sampleId)
            if sample.inputFiles == [fixtures.mixedRoot.standardizedFileURL.path] {
                XCTAssertEqual(sampleRecord.readSetPlan?.place, .resolvedDefaults, "the plan's one home (E13)")
            }
        }
        XCTAssertTrue(manifest.samples.contains { $0.inputFiles == [fixtures.mixedRoot.standardizedFileURL.path] })
        let summary = try String(contentsOf: batchRoot.appendingPathComponent("classification-batch-summary.tsv"), encoding: .utf8)
        XCTAssertEqual(summary.split(separator: "\n").count, 4)
        XCTAssertEqual(indexer.requests, [batchRoot.standardizedFileURL.path])
        XCTAssertEqual(run.report.message, "3 of 3 samples returned valid Kraken2 classifications")
        // The batch row's detail while the index builds is today's (UX D5, X1 review fix 1), and
        // the app's row logs the `Building kraken2.sqlite from N sample(s)` line itself.
        XCTAssertEqual(Kraken2AnalysisRunTool.batchIndexMessage, "Building Kraken2 database\u{2026}")
        let building = run.events.firstIndex { line in
            if case .progress(_, let message)? = line.event { return message == Kraken2AnalysisRunTool.batchIndexMessage }
            return false
        }
        let completed = run.events.firstIndex { kind(of: $0.event) == "complete" }
        XCTAssertNotNil(building, "the batch says it builds the viewer index")
        XCTAssertLessThan(building ?? .max, completed ?? .min)
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: XCTUnwrap(run.report.recordURL)))
        XCTAssertEqual(record.argv, argv, "the batch records the command that ran, not a shell script (E8)")
        XCTAssertTrue(record.steps.contains { $0.toolName == StubKraken2Indexer.stepName })
        XCTAssertEqual(record.options.explicit["batch"], .boolean(true))
        for bundle in [fixtures.singleRoot, fixtures.interleavedRoot, fixtures.mixedRoot] {
            let entries = AnalysisManifestStore.load(bundleURL: bundle, projectURL: fixtures.projectURL).analyses
            XCTAssertEqual(entries.map(\.displayName), ["Kraken2 Batch"], bundle.lastPathComponent)
        }
    }

    /// Review A8 fix 7. A batch outside a project writes no entry into its inputs' analysis
    /// history, as a one-folder result outside a project does not.
    func testABatchOutsideAProjectRecordsNothingInItsSourceBundles() async throws {
        let inputs = [fixtures.singleRoot.path, fixtures.interleavedRoot.path]
        let output = root.appendingPathComponent("batch-elsewhere", isDirectory: true)
        let argv = command(inputs + ["--batch", "--output-dir", output.path])

        let run = await execute(request(inputs), .directory(output), batch: true, argv: argv, indexing: StubKraken2Indexer())

        XCTAssertEqual(run.report.status, .completed, run.report.message)
        XCTAssertNotNil(MetagenomicsBatchResultStore.loadClassification(from: output))
        for bundle in [fixtures.singleRoot, fixtures.interleavedRoot] {
            let entries = AnalysisManifestStore.load(bundleURL: bundle, projectURL: fixtures.projectURL).analyses
            XCTAssertEqual(entries.map(\.displayName), [], bundle.lastPathComponent)
        }
    }

    /// Review A8 fix 6. The executor gives each sample of a batch a new folder, so a sample whose
    /// name an earlier batch in the same root already used goes beside it, and an input inside the
    /// earlier sample's outputs is read, never removed.
    func testABatchLeavesAnInputInsideAnEarlierBatchsSampleFolderAlone() async throws {
        let batchRoot = root.appendingPathComponent("earlier-batch", isDirectory: true)
        let copies = batchRoot.appendingPathComponent("reads/.lungfish-provenance/intermediates/classification-inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        let input = copies.appendingPathComponent("reads.fastq")
        let reads = ReadSetFixtures.fastq(["r1", "r2"])
        try reads.write(to: input, atomically: true, encoding: .utf8)
        let argv = command([input.path, "--batch", "--output-dir", batchRoot.path])

        let run = await execute(request([input.path]), .directory(batchRoot), batch: true, argv: argv, indexing: StubKraken2Indexer())

        XCTAssertEqual(run.report.status, .completed, run.report.message)
        XCTAssertEqual(try String(contentsOf: input, encoding: .utf8), reads, "the earlier sample keeps its file")
        let manifest = try XCTUnwrap(MetagenomicsBatchResultStore.loadClassification(from: batchRoot))
        XCTAssertEqual(manifest.samples.map(\.resultDirectory), ["reads-2"])
    }

    // MARK: - The viewer index

    /// Phase 2.10 U34, W4. A `--project` run of one sample builds its viewer index at the end, as a batch
    /// root does, and says so with the batch's words before the builder's lines, where it said nothing and the
    /// row's detail stayed `Classification complete`. A plain `--output` run builds no index and says nothing
    /// of one.
    func testAProjectRunOfOneSampleSaysItBuildsTheViewerIndex() async throws {
        let indexer = StubKraken2Indexer()
        let argv = command([fixtures.singleRoot.path, "--project", fixtures.projectURL.path])

        let run = await execute(request([fixtures.singleRoot.path]), .project(fixtures.projectURL), argv: argv, indexing: indexer)

        XCTAssertEqual(run.report.status, .completed, run.report.message)
        XCTAssertEqual(indexer.requests.count, 1, "the index is built once")
        let building = run.events.firstIndex { buildsTheIndex($0) }
        let completed = run.events.firstIndex { kind(of: $0.event) == "complete" }
        XCTAssertNotNil(building, "a project run of one sample says it builds the viewer index")
        XCTAssertLessThan(building ?? .max, completed ?? .min)

        let plain = root.appendingPathComponent("plain-out", isDirectory: true)
        let outside = await execute(
            request([fixtures.singleRoot.path]), .directory(plain),
            argv: command([fixtures.singleRoot.path, "--output-dir", plain.path]), indexing: indexer
        )
        XCTAssertEqual(outside.report.status, .completed, outside.report.message)
        XCTAssertFalse(outside.events.contains { buildsTheIndex($0) }, "a plain folder builds no index and says nothing of one")
        XCTAssertEqual(indexer.requests.count, 1, "and asks for none")
    }

    /// W4. An index that cannot be built is one sentence on every layout, the sentence the app's row logs, and
    /// the run still completes with that warning. A one-folder run once wrote `The viewer index could not be
    /// built: <error>. The viewer builds it when the result opens.` and a batch root `Database build failed:
    /// <error>`, a dash and `batch will rebuild lazily on open`.
    func testAnIndexThatCannotBeBuiltIsOneSentenceOnEveryLayout() async throws {
        let sentence = "The viewer index could not be built (disk full). LGE builds it when the result opens."
        XCTAssertEqual(Kraken2AnalysisRunTool.batchIndexWarning("disk full"), sentence)

        let single = await execute(
            request([fixtures.singleRoot.path]), .project(fixtures.projectURL),
            argv: command([fixtures.singleRoot.path, "--project", fixtures.projectURL.path]), indexing: FailingKraken2Indexer()
        )
        XCTAssertEqual(single.report.status, .completed, single.report.message)
        XCTAssertEqual(single.report.warnings, [sentence], "one sample in a project")

        let inputs = [fixtures.singleRoot.path, fixtures.interleavedRoot.path]
        let batch = await execute(
            request(inputs), .project(fixtures.projectURL), batch: true,
            argv: command(inputs + ["--batch", "--project", fixtures.projectURL.path]), indexing: FailingKraken2Indexer()
        )
        XCTAssertEqual(batch.report.status, .completed, batch.report.message)
        XCTAssertEqual(batch.report.warnings, [sentence], "a batch root")
    }

    private func buildsTheIndex(_ line: CLIEventLine) -> Bool {
        if case .progress(_, let message)? = line.event { return message == Kraken2AnalysisRunTool.batchIndexMessage }
        return false
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

    /// Review B-S4. An input inside an output an earlier run left in the named folder is refused in
    /// the plan, before the folder is claimed, so the earlier run keeps its record byte for byte.
    func testAnInputInsideAnEarlierRunsOutputsIsRefusedAndTheEarlierRecordStays() async throws {
        let output = root.appendingPathComponent("earlier-run", isDirectory: true)
        let copies = output.appendingPathComponent(".lungfish-provenance/intermediates/classification-inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        let input = copies.appendingPathComponent("input-1-reads.fastq")
        try ReadSetFixtures.fastq(["r1"]).write(to: input, atomically: true, encoding: .utf8)
        let recordURL = output.appendingPathComponent(ProvenanceWriter.provenanceFilename)
        let earlier = Data("{\"earlier\":true}".utf8)
        try earlier.write(to: recordURL)

        let run = await execute(request([input.path]), .directory(output), argv: command([input.path, "--output-dir", output.path]))

        XCTAssertEqual(run.report.status, .failed)
        XCTAssertEqual(run.report.exitCode, 3)
        XCTAssertEqual(try Data(contentsOf: recordURL), earlier)
        XCTAssertNil(AnalysisRunRecord.load(from: output), "the folder was never claimed")
    }

    // MARK: - Helpers

    func kind(of event: CLIEvent?) -> String {
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

    func command(_ arguments: [String]) -> [String] {
        ["lungfish-cli", "kraken2", "classify", "--db", "Viral"] + arguments
    }

    func request(_ inputs: [String]) -> Kraken2RunRequest {
        Kraken2RunRequest(inputArguments: inputs, databaseName: "Viral", threads: 1)
    }

    typealias PipelineRun = @Sendable (ClassificationConfig, @escaping @Sendable (Double, String) -> Void) async throws -> ClassificationResult

    func execute(
        _ request: Kraken2RunRequest,
        _ destination: AnalysisRunDestination,
        batch: Bool = false,
        argv: [String],
        materializer: any CLISequenceInputMaterializing & Sendable = ReadSetFixtures.StubMaterializer(readsByBundlePath: [:]),
        indexing: (any AnalysisResultIndexing)? = nil,
        runPipeline: PipelineRun? = nil,
        presentation: Kraken2RunPresentation = .none,
        payloadDigest: String? = nil,
        cancelRequested: (@Sendable () -> Bool)? = nil
    ) async -> (report: AnalysisRunReport, events: [CLIEventLine]) {
        await Self.run(
            request, destination, batch: batch, argv: argv,
            databaseURL: kraken2.databaseURL, condaManager: kraken2.condaManager,
            materializer: materializer, indexing: indexing, runPipeline: runPipeline,
            presentation: presentation, payloadDigest: payloadDigest, cancelRequested: cancelRequested
        )
    }

    /// Runs the tool through the executor with the stand-in kraken2 at `databaseURL` and
    /// `condaManager`, or `runPipeline`. A cancel request reaches the tool and the executor alike.
    static func run(
        _ request: Kraken2RunRequest,
        _ destination: AnalysisRunDestination,
        batch: Bool = false,
        argv: [String],
        databaseURL: URL,
        condaManager: CondaManager,
        materializer: any CLISequenceInputMaterializing & Sendable = ReadSetFixtures.StubMaterializer(readsByBundlePath: [:]),
        indexing: (any AnalysisResultIndexing)? = nil,
        runPipeline: PipelineRun? = nil,
        presentation: Kraken2RunPresentation = .none,
        payloadDigest: String? = nil,
        cancelRequested: (@Sendable () -> Bool)? = nil
    ) async -> (report: AnalysisRunReport, events: [CLIEventLine]) {
        let cancelRequested = cancelRequested ?? { false }
        var row = MetagenomicsDatabaseInfo(
            name: "Viral", tool: "kraken2", version: "2026.1", sizeBytes: 1, sizeOnDisk: 1, downloadURL: nil,
            description: "stand-in", collection: nil, path: databaseURL, isExternal: false, bookmarkData: nil,
            lastUpdated: Date(), status: .ready, recommendedRAM: 1
        )
        row.payloadDigest = payloadDigest
        let database = row
        let pipeline = ClassificationPipeline(condaManager: condaManager)
        let services = Kraken2RunServices(
            database: { $0 == "Viral" ? database : nil },
            availableDatabases: { [database] },
            materializer: materializer,
            runPipeline: runPipeline ?? { config, progress in
                try await pipeline.classify(config: config, progress: progress)
            },
            presentation: presentation,
            cancelRequested: cancelRequested
        )
        let lines = Kraken2EventCollector()
        let report = await AnalysisRunExecutor(
            services: AnalysisRunServices(
                writer: ProvenanceWriter(signingProvider: nil),
                indexing: indexing,
                cancelRequested: cancelRequested
            )
        ).execute(
            Kraken2AnalysisRunTool(request: request, services: services),
            AnalysisRunRequest(inputs: [], destination: destination, groupsSamples: batch, commandLine: argv),
            events: AnalysisRunEvents { lines.append($0) }
        )
        return (report, lines.lines)
    }
}

/// A materializer that reports `lines` as its own progress, as `FASTQCLIMaterializer` does, then
/// lets `base` write the file.
struct ReportingMaterializer: CLISequenceInputMaterializing, Sendable {
    let lines: [String]
    let base: any CLISequenceInputMaterializing & Sendable

    func materialize(
        bundleURL: URL,
        tempDirectory: URL,
        progress: (@Sendable (String) -> Void)?
    ) async throws -> URL {
        lines.forEach { progress?($0) }
        return try await base.materialize(bundleURL: bundleURL, tempDirectory: tempDirectory, progress: progress)
    }
}

/// Collects the event lines of a run.
final class Kraken2EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CLIEventLine] = []

    var lines: [CLIEventLine] { lock.withLock { stored } }

    func append(_ line: CLIEventLine) {
        lock.withLock { stored.append(line) }
    }
}

/// An index builder that cannot build, as a full disk stops the `build-db kraken2` core.
struct FailingKraken2Indexer: AnalysisResultIndexing {
    struct Failure: LocalizedError {
        var errorDescription: String? { "disk full" }
    }

    func buildIndex(_ request: AnalysisResultIndexRequest) async throws -> AnalysisResultIndex {
        throw Failure()
    }
}

/// Stands in for the command line's index builder over the `build-db kraken2` core.
final class StubKraken2Indexer: AnalysisResultIndexing, @unchecked Sendable {
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
