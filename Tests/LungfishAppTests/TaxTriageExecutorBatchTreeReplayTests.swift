// TaxTriageExecutorBatchTreeReplayTests.swift - The tree `taxtriage run --project --batch` leaves for a batch with a control
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane B30 (decisions T4, T5, T6 and R1, parity X3, X4 and X7). The GUI's TaxTriage run moves onto
// `lungfish-cli taxtriage run` in 2.10 (T1), so the executor's tree must hold what the GUI's route writes. These
// cases pin that tree for a project batch of two bundles, one of them a negative control by its bundle's
// `metadata.csv`, and follow it as B30 adds each fact.
//
// - Source records (X4). Since B30 M1 each completed sample's bundle records the run once in its
//   `analyses-manifest.json`, as a Kraken2 `--project` result does, and a failed sample's bundle records nothing.
//   A plain `--output` result records nothing, outside the project or in its `Analyses/` folder (B30 ruling Q2).
//   The entry's summary is the app's, its measured runtime included (B30 ruling Q1, vote V-B30).
//   At the base no bundle recorded the run.
// - The aggregate result (X3, T5). Since B30 M3 every batch root holds `taxtriage-result.json` from its samples'
//   results in request order, a failed sample as the plan gave it and named as a failure, and the root record names
//   it with its digest. Each bundle's entry then carries its summary. At the base the root held none.
// - The control mark (T4). Since B30 M2 the control's result marks its sample, `isNegativeControl` true, from its
//   bundle's role, and `--negative-control` marks the sample it names, whose record names it as an explicit option.
//   At the base no sample was marked.
// - X7. Since B30 M3 a `build-db taxtriage --force` rebuild of an executor result runs the executor's cleanup, which
//   keeps `top/`, names the database it replaced in a removal step and refreshes the root record. At the base it ran
//   the legacy cleanup, which deleted the `top/` the executor kept and its root record still named. Since B30's
//   review fix 8 the first build of a plain `--output` result, which its run leaves with no index, does so too.
//
// Each case runs the command in this process with its pipeline seam bound to `TaxTriageStandInEngine`, which starts
// processes, so the class name ends in ReplayTests and the class runs in the serial replay tier.

import ArgumentParser
import Foundation
import XCTest
@testable import LungfishCLI
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

final class TaxTriageExecutorBatchTreeReplayTests: XCTestCase {
    private var root: URL!

    /// The two samples, in the order the folder lists their bundles.
    private static let samples = ["control", "patient"]
    /// The sample whose bundle says it is a negative control.
    private static let controlSample = "control"

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "taxtriage-batch-tree").resolvingSymlinksInPath()
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - The tree

    func testAProjectBatchWritesTheAggregateRecordsEachSampleAndMarksTheControl() async throws {
        let engine = try makeEngine()
        let project = try makeProject()
        let control = bundle(Self.controlSample, in: project)
        let role = FASTQBundleCSVMetadata.load(from: control).map { FASTQSampleMetadata(from: $0, fallbackName: Self.controlSample).sampleRole }
        XCTAssertEqual(role, .negativeControl, "the control's bundle names its role, as the wizard reads it")

        let batch = try await runBatch(project: project, engine: engine)

        // X4. Each completed sample's bundle records the run once, naming the batch folder.
        for sample in Self.samples {
            try assertRecordsTheRun(bundle(sample, in: project), project: project, batch: batch, sample: sample)
        }
        // X3, flipped by B30 M3. The batch root holds the aggregate result of its samples' results, in request
        // order, which the root record names with its digest (T5).
        let results = try Self.samples.map { try TaxTriageResult.load(from: batch.appendingPathComponent($0, isDirectory: true)) }
        let aggregate = try TaxTriageResult.load(from: batch)
        XCTAssertEqual(aggregate.config.samples, results.flatMap(\.config.samples), "each sample as its own result holds it")
        XCTAssertEqual(aggregate.config.samples.map(\.isNegativeControl), [true, false], "T4, the batch overview's control column reads these marks")
        XCTAssertEqual(aggregate.reportFiles, results.flatMap(\.reportFiles))
        XCTAssertEqual(aggregate.runtime, results.map(\.runtime).reduce(0, +), accuracy: 1e-9)
        XCTAssertEqual(aggregate.sampleFailures, [])
        XCTAssertEqual(Self.resolved(aggregate.outputDirectory), Self.resolved(batch))
        try assertTheRootRecordNamesTheAggregate(in: batch)
        // T4, flipped by B30 M2. The control's result keeps the mark its bundle's role gives it, for the viewer.
        for sample in Self.samples {
            let result = try TaxTriageResult.load(from: batch.appendingPathComponent(sample, isDirectory: true))
            XCTAssertEqual(result.config.samples.map(\.sampleId), [sample], "\(sample)'s result names its one sample")
            XCTAssertEqual(result.config.samples.map(\.isNegativeControl), [sample == Self.controlSample], "\(sample)'s mark")
            XCTAssertNil(try sampleRecord(sample, in: batch).options.explicit["negative_controls"], "a role's mark is no option of \(sample)'s record")
        }
    }

    func testANamedNegativeControlIsKeptInItsResultAndRecordedAsExplicit() async throws {
        let engine = try makeEngine()
        let project = try makeProject()
        let patient = try XCTUnwrap(Self.samples.first { $0 != Self.controlSample })

        let batch = try await runBatch(project: project, engine: engine, extra: ["--negative-control", patient])

        for sample in Self.samples {
            let result = try TaxTriageResult.load(from: batch.appendingPathComponent(sample, isDirectory: true))
            XCTAssertEqual(result.config.samples.map(\.isNegativeControl), [true], "\(sample), by its role or by --negative-control")
        }
        XCTAssertEqual(try sampleRecord(patient, in: batch).options.explicit["negative_controls"], .array([.string(patient)]), "T4, explicit when given")
        XCTAssertNil(try sampleRecord(Self.controlSample, in: batch).options.explicit["negative_controls"])
        let argv = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: batch)).argv
        XCTAssertTrue(zip(argv, argv.dropFirst()).contains { $0 == "--negative-control" && $1 == patient }, "the root record's command names it: \(argv)")
    }

    /// The record `sample`'s launch keeps in its folder of `batch`.
    private func sampleRecord(_ sample: String, in batch: URL) throws -> ProvenanceEnvelope {
        try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: batch.appendingPathComponent(sample, isDirectory: true)), "no record of \(sample)")
    }

    func testAFailedSampleRecordsNothingInItsBundle() async throws {
        let engine = try makeEngine(.failsSamples([Self.controlSample]))
        let project = try makeProject()

        let batch = try await runBatch(project: project, engine: engine)

        let patient = try XCTUnwrap(Self.samples.first { $0 != Self.controlSample })
        try assertRecordsTheRun(bundle(patient, in: project), project: project, batch: batch, sample: patient)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: bundle(Self.controlSample, in: project).appendingPathComponent(AnalysisManifest.filename).path
            ),
            "X4: the failed sample's bundle records nothing, where the app's route records every sample"
        )
        // X3 and X4. The aggregate holds every sample in request order and names the one that failed, so the
        // batch reads Completed with Warnings and says so in the completed sample's bundle (BIO 4). The failed
        // sample is the one the plan gave its launch, its bundle with its role's mark, since its launch handed
        // back no result. The completed one is as its result holds it.
        let aggregate = try TaxTriageResult.load(from: batch)
        let completed = try TaxTriageResult.load(from: batch.appendingPathComponent(patient, isDirectory: true))
        XCTAssertEqual(aggregate.config.samples.map(\.sampleId), Self.samples, "every sample of the batch, as the app's result holds them")
        XCTAssertEqual(aggregate.config.samples.last, completed.config.samples.first)
        let failedSample = try XCTUnwrap(aggregate.config.samples.first)
        XCTAssertEqual(Self.resolved(failedSample.fastq1), Self.resolved(bundle(Self.controlSample, in: project)), "the input the plan named")
        XCTAssertTrue(failedSample.isNegativeControl, "the failed control keeps the mark its bundle's role gives it (T4)")
        XCTAssertEqual(aggregate.sampleFailures.map(\.sampleID), [Self.controlSample])
        let failure = try XCTUnwrap(aggregate.sampleFailures.first)
        XCTAssertEqual(Self.resolved(failure.outputDirectory), Self.resolved(batch.appendingPathComponent(Self.controlSample, isDirectory: true)))
        XCTAssertTrue(failure.errorDescription.hasPrefix("TaxTriage pipeline failed"), failure.errorDescription)
        XCTAssertTrue(aggregate.summary.hasPrefix("TaxTriage pipeline completed with warnings\nRuntime: "), aggregate.summary)
        XCTAssertTrue(aggregate.summary.contains("\nSamples: 2\nReports: 1\n") && aggregate.summary.contains("\nFailed samples: 1\n"), aggregate.summary)
        try assertTheRootRecordNamesTheAggregate(in: batch)
    }

    func testABatchOutsideTheProjectRecordsNothingInTheBundles() async throws {
        let engine = try makeEngine()
        let project = try makeProject()
        let output = root.appendingPathComponent("out", isDirectory: true)
        let imports = project.appendingPathComponent("Imports", isDirectory: true)

        let (code, lines) = try await run(["--input", imports.path, "--output", output.path, "--batch"], engine: engine)

        XCTAssertEqual(code, 0, lines.joined(separator: "\n"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("\(Self.controlSample)/taxtriage-result.json").path))
        for sample in Self.samples {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: bundle(sample, in: project).appendingPathComponent(AnalysisManifest.filename).path),
                "a result outside the project's Analyses folder is no entry of \(sample)'s bundle"
            )
        }
        // T5. Every batch root gets the aggregate, an --output batch's too.
        XCTAssertEqual(try TaxTriageResult.load(from: output).config.samples.map(\.sampleId), Self.samples)
        try assertTheRootRecordNamesTheAggregate(in: output)
    }

    func testAnOutputBatchInTheAnalysesFolderRecordsNothingInTheBundles() async throws {
        let engine = try makeEngine()
        let project = try makeProject()
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        let output = project.appendingPathComponent("Analyses/cli-batch", isDirectory: true)

        let (code, lines) = try await run(["--input", imports.path, "--output", output.path, "--batch"], engine: engine)

        XCTAssertEqual(code, 0, lines.joined(separator: "\n"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.appendingPathComponent("\(Self.controlSample)/taxtriage-result.json").path))
        for sample in Self.samples {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: bundle(sample, in: project).appendingPathComponent(AnalysisManifest.filename).path),
                "an --output result records nothing in its inputs' bundles, as Kraken2's (B30 ruling Q2), \(sample)"
            )
        }
    }

    /// `bundle`'s analysis history holds one entry, the run in `batch` with `sample`'s settings and the summary of
    /// the batch's aggregate result as the app's route words it, runtime included (B30 ruling Q1, vote V-B30), so
    /// a batch that lost a sample says so in each bundle (BIO ruling Q1 note, B30 M3).
    private func assertRecordsTheRun(_ bundle: URL, project: URL, batch: URL, sample: String) throws {
        let entries = AnalysisManifestStore.load(bundleURL: bundle, projectURL: project).analyses
        XCTAssertEqual(entries.count, 1, "\(sample)'s bundle records the run once")
        let entry = try XCTUnwrap(entries.first, sample)
        let result = try TaxTriageResult.load(from: batch.appendingPathComponent(sample, isDirectory: true))
        XCTAssertEqual(entry.tool, "taxtriage", sample)
        XCTAssertEqual(entry.analysisDirectoryName, batch.lastPathComponent, "\(sample)'s entry names the batch folder")
        XCTAssertEqual(entry.displayName, "TaxTriage Classification", "the app's route's name for the run")
        XCTAssertEqual(entry.status, .completed, sample)
        XCTAssertEqual(entry.parameters, result.config.summaryParameters(), "\(sample)'s entry names its settings")
        XCTAssertEqual(entry.summary, try TaxTriageResult.load(from: batch).summary, "the batch's summary, runtime included")
        XCTAssertTrue(entry.summary.hasPrefix("TaxTriage pipeline completed "), entry.summary)
        XCTAssertTrue(entry.summary.contains("\nRuntime: "), entry.summary)
    }

    /// The root record of `batch` names its aggregate result as an output, with the digest of the file it holds.
    private func assertTheRootRecordNamesTheAggregate(in batch: URL) throws {
        let aggregate = batch.appendingPathComponent("taxtriage-result.json")
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: batch), "no root record in \(batch.path)")
        let named = record.outputs.filter { Self.resolved(URL(fileURLWithPath: $0.path)) == Self.resolved(aggregate) }
        XCTAssertEqual(named.count, 1, "the root record names the aggregate once: \(record.outputs.map(\.path))")
        XCTAssertEqual(named.first?.checksumSHA256, try ProvenanceFileDescriptor.file(url: aggregate).checksumSHA256, "with its digest")
        XCTAssertEqual(named.first?.format, .json)
        XCTAssertEqual(record.output.map { URL(fileURLWithPath: $0.path).lastPathComponent }, "taxtriage.sqlite", "the viewer index stays the run's output")
    }

    private static func resolved(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    // MARK: - X7

    func testABuildDbForceRebuildKeepsTopAndRefreshesTheRootRecord() async throws {
        let engine = try makeEngine()
        let project = try makeProject()
        let batch = try await runBatch(project: project, engine: engine)
        let database = batch.appendingPathComponent("taxtriage.sqlite")

        for sample in Self.samples {
            let top = batch.appendingPathComponent("\(sample)/top", isDirectory: true)
            XCTAssertFalse(try Self.topReports(in: top).isEmpty, "the executor's cleanup keeps \(sample)/top/ (2.8 T5)")
        }
        let named = try Self.namedTopReports(in: batch)
        XCTAssertEqual(named.filter { !FileManager.default.fileExists(atPath: $0) }, [], "before the rebuild every named top report exists")
        XCTAssertEqual(named.count, Self.samples.count, "the root record names each sample's top report")
        let before = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: batch))
        let builtDigest = try ProvenanceFileDescriptor.file(url: database).checksumSHA256

        let rebuild = try BuildDbCommand.TaxTriageSubcommand.parse([batch.path, "--force", "-q"])
        try await rebuild.run()

        // X7, flipped by B30 M3. A rebuild of an executor result runs the executor's cleanup, which keeps top/.
        for sample in Self.samples {
            let top = batch.appendingPathComponent("\(sample)/top", isDirectory: true)
            XCTAssertFalse(try Self.topReports(in: top).isEmpty, "X7: the rebuild keeps \(sample)/top/ (2.8 T5)")
        }
        XCTAssertEqual(
            try Self.namedTopReports(in: batch).filter { !FileManager.default.fileExists(atPath: $0) }, [],
            "X7: every top report the root record names exists"
        )
        // The root record still records the run, its steps as they were and the rebuild's after them.
        let after = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: batch))
        XCTAssertEqual(after.workflowName, TaxTriageAnalysisRunTool.workflowName)
        XCTAssertEqual(after.argv, before.argv, "the record still names the command that ran")
        XCTAssertEqual(after.steps.prefix(before.steps.count).map(\.id), before.steps.map(\.id), "the run's steps stay")
        let added = Array(after.steps.dropFirst(before.steps.count))
        // The database the rebuild replaced, named with the digest the record held for it (2.8 P1).
        let replacement = try XCTUnwrap(added.first, "the rebuild added no step")
        XCTAssertEqual(replacement.toolName, "Lungfish TaxTriage Index Removal")
        XCTAssertEqual(replacement.resolvedOptions["operation"], .string(RecordedRemovalStep.operation))
        XCTAssertEqual(replacement.inputs.map { Self.resolved(URL(fileURLWithPath: $0.path)) }, [Self.resolved(database)])
        XCTAssertEqual(replacement.inputs.map(\.checksumSHA256), [builtDigest])
        // The rebuild's build step and the run level name the database the folder holds.
        let rebuiltDigest = try ProvenanceFileDescriptor.file(url: database).checksumSHA256
        XCTAssertTrue(
            added.contains { step in
                step.toolName == "lungfish build-db taxtriage"
                    && step.outputs.contains { Self.names($0, database) && $0.checksumSHA256 == rebuiltDigest }
            },
            "the rebuild's step names the database it wrote: \(added.map(\.toolName))"
        )
        let runLevel = (after.files + after.outputs + [after.output].compactMap { $0 }).filter { Self.names($0, database) }
        XCTAssertFalse(runLevel.isEmpty)
        XCTAssertEqual(Set(runLevel.map(\.checksumSHA256)), [rebuiltDigest], "the run level names the database it holds")
    }

    /// X7 on a plain `--output` result, which its run leaves with no index (B30 review fix 8, ruling 4). The first
    /// `build-db taxtriage` runs the executor's cleanup there too, which keeps `top/`, and adds its step to the root
    /// record. At the base it ran the legacy cleanup, which deleted the `top/` the root record names.
    func testABuildDbOfAPlainOutputResultKeepsTopAndRecordsTheBuild() async throws {
        let engine = try makeEngine()
        let project = try makeProject()
        let patient = try XCTUnwrap(Self.samples.first { $0 != Self.controlSample })
        let output = root.appendingPathComponent("out", isDirectory: true)
        let (code, lines) = try await run(
            ["--input", bundle(patient, in: project).path, "--sample", patient, "--output", output.path], engine: engine
        )
        XCTAssertEqual(code, 0, lines.joined(separator: "\n"))
        let database = output.appendingPathComponent("taxtriage.sqlite")
        let top = output.appendingPathComponent("top", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path), "a plain --output run builds no index")
        XCTAssertFalse(try Self.topReports(in: top).isEmpty, "the run keeps top/")
        XCTAssertFalse(try Self.namedTopReports(in: output).isEmpty, "the root record names the top report")
        let before = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: output))

        let build = try BuildDbCommand.TaxTriageSubcommand.parse([output.path, "-q"])
        try await build.run()

        XCTAssertFalse(try Self.topReports(in: top).isEmpty, "X7: the build keeps top/ (2.8 T5)")
        XCTAssertEqual(
            try Self.namedTopReports(in: output).filter { !FileManager.default.fileExists(atPath: $0) }, [],
            "X7: every top report the root record names exists"
        )
        let after = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: output))
        XCTAssertEqual(after.workflowName, TaxTriageAnalysisRunTool.workflowName, "the root record still records the run")
        XCTAssertEqual(after.argv, before.argv, "the record still names the command that ran")
        XCTAssertEqual(after.steps.prefix(before.steps.count).map(\.id), before.steps.map(\.id), "the run's steps stay")
        let digest = try ProvenanceFileDescriptor.file(url: database).checksumSHA256
        XCTAssertTrue(
            after.steps.dropFirst(before.steps.count).contains { step in
                step.toolName == "lungfish build-db taxtriage"
                    && step.outputs.contains { Self.names($0, database) && $0.checksumSHA256 == digest }
            },
            "the root record gains the build step, which names the database it wrote: \(after.steps.map(\.toolName))"
        )
    }

    private static func names(_ descriptor: ProvenanceFileDescriptor, _ file: URL) -> Bool {
        resolved(URL(fileURLWithPath: descriptor.path)) == resolved(file)
    }

    // MARK: - Running

    private func makeEngine(_ behaviour: TaxTriageStandInEngine.Behaviour = .completes) throws -> TaxTriageStandInEngine {
        let engine = try TaxTriageStandInEngine(
            root: root.appendingPathComponent("engine", isDirectory: true), behaviour: behaviour, maximumWait: .seconds(60)
        )
        addTeardownBlock { await engine.stopLeftoverProcesses() }
        return engine
    }

    /// Runs `taxtriage run --input <Imports> --project <project> --batch` with `extra` on the stand-in and returns the
    /// one batch folder it made, after checking it completed with one launch per sample.
    private func runBatch(project: URL, engine: TaxTriageStandInEngine, extra: [String] = []) async throws -> URL {
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        let (code, lines) = try await run(["--input", imports.path, "--project", project.path, "--batch"] + extra, engine: engine)
        XCTAssertEqual(code, 0, lines.joined(separator: "\n"))
        XCTAssertEqual(try engine.launches().count, Self.samples.count, "one Nextflow per sample")
        let analyses = project.appendingPathComponent("Analyses", isDirectory: true)
        let batches = try FileManager.default.contentsOfDirectory(atPath: analyses.path).filter { $0.hasPrefix("taxtriage-batch-") }
        XCTAssertEqual(batches.count, 1, "one batch folder in the project")
        let batch = analyses.appendingPathComponent(try XCTUnwrap(batches.first), isDirectory: true)
        XCTAssertEqual(try ProvenanceEnvelopeReader.load(from: batch)?.workflowName, TaxTriageAnalysisRunTool.workflowName)
        return batch
    }

    /// Runs `taxtriage run` with `arguments`, the stand-in's database, profile and CPU count, and the pipeline seam
    /// bound to `engine`, and returns its exit code and the JSON event lines.
    private func run(_ arguments: [String], engine: TaxTriageStandInEngine) async throws -> (Int32, [String]) {
        let database = root.appendingPathComponent("kraken2-db", isDirectory: true)
        try FileManager.default.createDirectory(at: database, withIntermediateDirectories: true)
        let command = try TaxTriageCommand.RunSubcommand.parse(
            ["run"] + arguments + ["--db", database.path, "--nf-profile", TaxTriageStandInEngine.profile, "--max-cpus", "2", "--quiet"]
        )
        let sink = BatchTreeEventLines()
        do {
            try await TaxTriageCommand.RunSubcommand.$makePipeline.withValue({ engine.makePipeline() }) {
                try await command.execute(events: .jsonLines { sink.append($0) })
            }
            return (0, sink.lines)
        } catch let exit as ExitCode {
            return (exit.rawValue, sink.lines)
        }
    }

    // MARK: - Fixtures

    /// `Project.lungfish` with `Imports/control.lungfishfastq`, whose `metadata.csv` names it a negative control as
    /// the wizard reads it, and `Imports/patient.lungfishfastq`, each one file of single reads.
    private func makeProject() throws -> URL {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        for sample in Self.samples {
            let bundle = bundle(sample, in: project)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let text = (1...3).map { "@\(sample)-read-\($0)\nACGTACGTAC\n+\nIIIIIIIIII\n" }.joined()
            try text.write(to: bundle.appendingPathComponent("\(sample).fastq"), atomically: true, encoding: .utf8)
        }
        try FASTQBundleCSVMetadata.save(
            FASTQBundleCSVMetadata(keyValuePairs: ["sample_name": Self.controlSample, "sample_role": SampleRole.negativeControl.rawValue]),
            to: bundle(Self.controlSample, in: project)
        )
        return project
    }

    private func bundle(_ sample: String, in project: URL) -> URL {
        project.appendingPathComponent("Imports/\(sample).lungfishfastq", isDirectory: true)
    }

    private static func topReports(in folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".top_report.tsv") }
    }

    /// The `top/*.top_report.tsv` paths the batch root's record names, among its outputs and its steps' files.
    private static func namedTopReports(in batch: URL) throws -> [String] {
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: batch), "no root record in \(batch.path)")
        let files = record.outputs + record.steps.flatMap { $0.inputs + $0.outputs }
        return Array(Set(files.map(\.path).filter { $0.contains("/top/") && $0.hasSuffix(".top_report.tsv") })).sorted()
    }
}

/// The event lines of one run, collected under a lock, since the executor delivers from its task.
private final class BatchTreeEventLines: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [String] = []

    func append(_ line: String) {
        lock.lock()
        collected.append(line)
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }
}
