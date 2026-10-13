// TaxTriageExecutorBatchTreeReplayTests.swift - The tree `taxtriage run --project --batch` leaves for a batch with a control
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT
//
// Phase 2.10 lane B30 (decisions T4, T5, T6 and R1, parity X3, X4 and X7). The GUI's TaxTriage run moves onto
// `lungfish-cli taxtriage run` in 2.10 (T1), so the executor's tree must hold what the GUI's route writes. These
// cases pin that tree for a project batch of two bundles, one of them a negative control by its bundle's
// `metadata.csv`, and follow it as B30 adds each fact.
//
// - Source records (X4). Today no bundle records the run in its `analyses-manifest.json`.
// - The aggregate result (X3). Today the batch root holds no `taxtriage-result.json`, each sample keeps its own.
// - The control mark (T4). Today the control's sample is not marked, `isNegativeControl` is false in its result.
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

    func testAProjectBatchWithAControlLeavesNoSourceRecordNoAggregateAndNoMark() async throws {
        let engine = try makeEngine()
        let project = try makeProject()
        let control = bundle(Self.controlSample, in: project)
        let role = FASTQBundleCSVMetadata.load(from: control).map { FASTQSampleMetadata(from: $0, fallbackName: Self.controlSample).sampleRole }
        XCTAssertEqual(role, .negativeControl, "the control's bundle names its role, as the wizard reads it")

        let batch = try await runBatch(project: project, engine: engine)

        // X4. No bundle records the run.
        for sample in Self.samples {
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: bundle(sample, in: project).appendingPathComponent(AnalysisManifest.filename).path),
                "\(sample)'s bundle holds no analyses-manifest.json"
            )
        }
        // X3. The batch root holds no aggregate result, each sample keeps its own.
        XCTAssertFalse(FileManager.default.fileExists(atPath: batch.appendingPathComponent("taxtriage-result.json").path))
        // T4. No sample carries a negative control mark, the control included.
        for sample in Self.samples {
            let result = try TaxTriageResult.load(from: batch.appendingPathComponent(sample, isDirectory: true))
            XCTAssertEqual(result.config.samples.map(\.sampleId), [sample], "\(sample)'s result names its one sample")
            XCTAssertEqual(result.config.samples.map(\.isNegativeControl), [false], "\(sample) carries no control mark")
        }
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

    private func makeEngine() throws -> TaxTriageStandInEngine {
        let engine = try TaxTriageStandInEngine(
            root: root.appendingPathComponent("engine", isDirectory: true), maximumWait: .seconds(60)
        )
        addTeardownBlock { await engine.stopLeftoverProcesses() }
        return engine
    }

    /// Runs `taxtriage run --input <Imports> --project <project> --batch` on the stand-in and returns the one batch
    /// folder it made, after checking it completed with one launch per sample.
    private func runBatch(project: URL, engine: TaxTriageStandInEngine) async throws -> URL {
        let imports = project.appendingPathComponent("Imports", isDirectory: true)
        let (code, lines) = try await run(["--input", imports.path, "--project", project.path, "--batch"], engine: engine)
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
