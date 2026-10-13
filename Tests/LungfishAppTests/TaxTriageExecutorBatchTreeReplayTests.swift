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
// - The aggregate result (X3). Today the batch root holds no `taxtriage-result.json`, each sample keeps its own.
// - The control mark (T4). Since B30 M2 the control's result marks its sample, `isNegativeControl` true, from its
//   bundle's role, and `--negative-control` marks the sample it names, whose record names it as an explicit option.
//   At the base no sample was marked.
// - X7. A `build-db taxtriage --force` rebuild runs the legacy cleanup, which deletes the `top/` the executor kept
//   and its root record still names.
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

    func testAProjectBatchRecordsEachSampleInItsBundleWithNoAggregateAndMarksTheControl() async throws {
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
        // X3. The batch root holds no aggregate result, each sample keeps its own.
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.appendingPathComponent("taxtriage-result.json").path))
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
    /// its result as the app's route words it, runtime included (B30 ruling Q1, vote V-B30).
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
        XCTAssertEqual(entry.summary, result.summary, "the app's summary, runtime included")
        XCTAssertTrue(entry.summary.hasPrefix("TaxTriage pipeline completed successfully\nRuntime: "), entry.summary)
    }

    // MARK: - X7

    func testABuildDbForceRebuildDeletesTheTopFolderTheRootRecordNames() async throws {
        let engine = try makeEngine()
        let project = try makeProject()
        let batch = try await runBatch(project: project, engine: engine)

        for sample in Self.samples {
            let top = batch.appendingPathComponent("\(sample)/top", isDirectory: true)
            XCTAssertFalse(try Self.topReports(in: top).isEmpty, "the executor's cleanup keeps \(sample)/top/ (2.8 T5)")
        }
        let named = try Self.namedTopReports(in: batch)
        XCTAssertEqual(named.filter { !FileManager.default.fileExists(atPath: $0) }, [], "before the rebuild every named top report exists")
        XCTAssertEqual(named.count, Self.samples.count, "the root record names each sample's top report")

        let rebuild = try BuildDbCommand.TaxTriageSubcommand.parse([batch.path, "--force", "-q"])
        try await rebuild.run()

        for sample in Self.samples {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: batch.appendingPathComponent("\(sample)/top").path),
                "X7: the forced rebuild's legacy cleanup deletes \(sample)/top/"
            )
        }
        XCTAssertEqual(
            try Self.namedTopReports(in: batch).filter { !FileManager.default.fileExists(atPath: $0) }.count,
            named.count,
            "X7: the root record still names each deleted top report"
        )
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
