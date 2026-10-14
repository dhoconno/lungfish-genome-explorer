// AnalysisRunIndexStepRecordTests.swift - A real index build's steps in the root record, completed and cancelled
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import XCTest
import LungfishTestSupport
@testable import LungfishCLI
@testable import LungfishIO
@testable import LungfishWorkflow

/// The steps of a real viewer index build in the root record of the run that built it (2.10 A18,
/// 2.9 R6). Each finalize builds its index through the command line's builder over a `build-db`
/// core. The root record names each step of the build once, after the units' steps, with the
/// digests the build took, and a cancel never adds a digest of what did not end.
///
/// The builds read the mini fixtures without their BAMs, so no samtools runs.
/// `AnalysisRunIndexStepLiveConformanceTests` runs the TaxTriage build over the BAMs with the
/// managed samtools.
final class AnalysisRunIndexStepRecordTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = try TestTempDirectory.make(prefix: "analysis-run-index-steps")
    }

    override func tearDown() {
        TestTempDirectory.cleanup(root)
    }

    // MARK: - Completed, each step once

    /// The Kraken2 batch finalize over the three samples of `kraken2-mini`. What the root record
    /// names after the units' steps, the steps the finalize recorded and then the finalization's,
    /// is the build's steps byte for byte, each once, and the finalization keeps its outputs.
    func testTheKraken2BatchFinalizeNamesEachIndexStepOnce() async throws {
        let batch = try kraken2Batch()

        let run = try await Self.finalize(.kraken2, batch.directory, layout: .batchRoot, base: Kraken2ResultIndexer()) { context in
            try await Self.kraken2Tool.finalize(batch.units, context: context)
        }

        XCTAssertTrue(run.built.steps.contains { $0.toolName == "lungfish build-db kraken2" }, "\(run.built.steps.map(\.toolName))")
        XCTAssertEqual(try Self.encoded(run.recorded + run.finalization.steps), try Self.encoded(run.built.steps))
        Self.assertEachStepOnce(run.recorded + run.finalization.steps)
        XCTAssertEqual(run.finalization.outputs.map(\.url.lastPathComponent), [
            Kraken2AnalysisRunTool.batchSummaryFilename, ClassificationBatchResultManifest.filename, "kraken2.sqlite",
        ])
        XCTAssertEqual(run.finalization.warnings, [])
    }

    /// The TaxTriage finalize of a result folder in a project. The root record names the build's
    /// steps and then the removal step of its cleanup, byte for byte, each once.
    func testTheTaxTriageFinalizeNamesTheBuildThenItsRemovalOnce() async throws {
        let result = try Self.taxTriageResult(in: root, withBAMs: false)

        let run = try await Self.finalize(
            .taxtriage, result.directory, layout: .sharedBatchRoot, base: TaxTriageResultIndexer(), unitSteps: [result.launch]
        ) { context in
            try await Self.taxTriageTool(result.directory).finalize([], context: context)
        }

        XCTAssertEqual(
            run.built.steps.suffix(2).map(\.toolName),
            ["lungfish build-db taxtriage", BuildDbCommand.TaxTriageSubcommand.cleanupRemovalToolName]
        )
        XCTAssertEqual(try Self.encoded(run.recorded + run.finalization.steps), try Self.encoded(run.built.steps))
        Self.assertEachStepOnce(run.recorded + run.finalization.steps)
        XCTAssertEqual(run.finalization.outputs.map(\.url.lastPathComponent), ["taxtriage.sqlite"])
        XCTAssertEqual(run.finalization.warnings, [])
    }

    /// A `--project` EsViritu run of one sample, the app's batch root, with the stand-in EsViritu.
    /// The root record lists the units' steps and then the build's, byte for byte, each once.
    func testACompletedEsVirituRecordNamesTheIndexStepsOnceAfterTheUnits() async throws {
        let indexer = CapturingIndexer(base: EsVirituResultIndexing())

        let run = try await esVirituRun(indexing: indexer)

        XCTAssertEqual(run.report.status, .completed, run.report.message)
        let record = try run.record()
        let built = try XCTUnwrap(indexer.builds.first?.index)
        XCTAssertEqual(built.steps.last?.toolName, "lungfish build-db esviritu")
        let unitSteps = record.steps.dropLast(built.steps.count)
        XCTAssertTrue(unitSteps.contains { $0.toolName == "EsViritu" }, "\(record.steps.map(\.toolName))")
        XCTAssertEqual(try Self.encoded(Array(record.steps.suffix(built.steps.count))), try Self.encoded(built.steps))
        Self.assertEachStepOnce(record.steps)
        XCTAssertTrue(record.outputs.contains { $0.path.hasSuffix("/esviritu.sqlite") })
        XCTAssertEqual(run.sourceRecords.map(\.displayName), ["EsViritu Detection"])
    }

    // MARK: - A cancel inside the build

    /// A cancel inside the build, once the core wrote the database and before its next check, ends
    /// the core with the cancel. The core puts back the folder's earlier database, none here, so the
    /// cancelled record keeps the units' steps, names none of the build's and holds no digest of a
    /// database that is not there. A cancel inside a core keeps none of the core's steps, those
    /// that ended included, until the cores hand each over as it ends (lane S33).
    func testACancelInsideTheEsVirituBuildKeepsNoneOfItsStepsAndNoDigestOfItsDatabase() async throws {
        let indexer = CapturingIndexer(base: EsVirituResultIndexing())

        let run = try await esVirituRun(indexing: indexer, cancellingAtLine: { $0.hasPrefix("Built ") })

        try assertCancelled(run)
        XCTAssertTrue(indexer.builds.isEmpty, "the build ended with the cancel")
        let record = try run.record()
        XCTAssertTrue(record.steps.contains { $0.toolName == "EsViritu" }, "\(record.steps.map(\.toolName))")
        XCTAssertFalse(record.steps.contains { $0.toolName.hasPrefix("lungfish build-db") }, "\(record.steps.map(\.toolName))")
        let folder = try run.folder()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("esviritu.sqlite").path))
        let named = record.files.map(\.path) + record.steps.flatMap { $0.inputs + $0.outputs }.map(\.path)
        XCTAssertFalse(named.contains { $0.hasSuffix("/esviritu.sqlite") }, "no digest of a database that is not there")
        try assertNothingOfTheFinalization(in: record, of: run)
    }

    // MARK: - The build's steps reach the root record before the build returns

    /// The Kraken2 index builder hands each step of the build to the root record once its core
    /// returns and before the builder does, so a cancel later in the finalize keeps them (2.9 R6),
    /// and the finalization names none of them.
    func testTheKraken2BuildHandsItsStepsOverBeforeItReturns() async throws {
        let batch = try kraken2Batch()

        let run = try await Self.finalize(.kraken2, batch.directory, layout: .batchRoot, base: Kraken2ResultIndexer()) { context in
            try await Self.kraken2Tool.finalize(batch.units, context: context)
        }

        try Self.assertTheBuildHandedItsStepsOver(run)
    }

    /// The TaxTriage index builder hands over the build's steps and then the removal step of its
    /// cleanup, in that order, before it returns.
    func testTheTaxTriageBuildHandsItsStepsThenItsRemovalOverBeforeItReturns() async throws {
        let result = try Self.taxTriageResult(in: root, withBAMs: false)

        let run = try await Self.finalize(
            .taxtriage, result.directory, layout: .sharedBatchRoot, base: TaxTriageResultIndexer(), unitSteps: [result.launch]
        ) { context in
            try await Self.taxTriageTool(result.directory).finalize([], context: context)
        }

        try Self.assertTheBuildHandedItsStepsOver(run)
        XCTAssertEqual(run.recorded.last?.toolName, BuildDbCommand.TaxTriageSubcommand.cleanupRemovalToolName)
    }

    /// A cancel that arrives just after the build ended whole, while the finalize goes on, keeps the
    /// build's steps in the cancelled record, byte for byte after the units' steps, each file they
    /// wrote there with the digest and size its step took. The record drops the finalization's
    /// outputs, its batch summary and manifest, its source record and its artifacts (2.9 R6).
    func testACancelJustAfterTheEsVirituBuildKeepsItsStepsAndDropsTheFinalization() async throws {
        let indexer = CapturingIndexer(base: EsVirituResultIndexing(), cancelsAfterTheBuild: true)

        let run = try await esVirituRun(indexing: indexer)

        try assertCancelled(run)
        let record = try run.record()
        let built = try XCTUnwrap(indexer.builds.first?.index)
        XCTAssertEqual(built.steps.last?.toolName, "lungfish build-db esviritu")
        let unitSteps = record.steps.dropLast(built.steps.count)
        XCTAssertTrue(unitSteps.contains { $0.toolName == "EsViritu" }, "\(record.steps.map(\.toolName))")
        XCTAssertEqual(try Self.encoded(Array(record.steps.suffix(built.steps.count))), try Self.encoded(built.steps))
        Self.assertEachStepOnce(record.steps)
        for output in built.steps.flatMap(\.outputs) {
            let taken = try ProvenanceFileDescriptor.file(url: URL(fileURLWithPath: output.path), role: .output)
            XCTAssertEqual(taken.checksumSHA256, output.checksumSHA256, output.path)
            XCTAssertEqual(taken.fileSize, output.fileSize, output.path)
        }
        try assertNothingOfTheFinalization(in: record, of: run)
    }
}

// MARK: - Finalizes run directly

extension AnalysisRunIndexStepRecordTests {
    /// The sample folders of `kraken2-mini` and `esviritu-mini`.
    fileprivate static let fixtureSamples = ["SRR35517702", "SRR35517703", "SRR35517705"]

    /// Files of a finished TaxTriage sample that the executor's cleanup removes.
    fileprivate static let removedByTheCleanup = ["count/S.fastq.gz", "fastp/S.fastp.fastq.gz", "get/S.get.tsv"]

    fileprivate static func fixture(_ relative: String) -> URL {
        BuildDbStreamCapture.fixturesFolder.appendingPathComponent(relative, isDirectory: true)
    }

    fileprivate static var kraken2Tool: Kraken2AnalysisRunTool {
        Kraken2AnalysisRunTool(request: Kraken2RunRequest(inputArguments: [], databaseName: "Viral", threads: 1))
    }

    fileprivate static func taxTriageTool(_ directory: URL) -> TaxTriageAnalysisRunTool {
        TaxTriageAnalysisRunTool(request: TaxTriageRunRequest(settings: TaxTriageConfig(samples: [], outputDirectory: directory)))
    }

    /// The three samples of `kraken2-mini` in a batch root, each a completed unit.
    fileprivate func kraken2Batch() throws -> (directory: URL, units: [AnalysisUnitReport<Kraken2UnitResult>]) {
        let directory = root.appendingPathComponent("kraken2-batch-1", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let units = try Self.fixtureSamples.enumerated().map { index, sample in
            let folder = directory.appendingPathComponent(sample, isDirectory: true)
            try FileManager.default.copyItem(at: Self.fixture("kraken2-mini/\(sample)"), to: folder)
            let result = Kraken2UnitResult(
                result: try ClassificationResult.load(from: folder),
                sourceBundle: nil,
                inputURLs: [folder.appendingPathComponent("source.fastq")],
                destinationIsProject: false
            )
            return AnalysisUnitReport(index: index, label: sample, sampleName: sample, directory: folder, outcome: .completed(result))
        }
        return (directory, units)
    }

    /// A copy of `taxtriage-mini`, without its BAMs unless `withBAMs`, holding files the cleanup
    /// removes, and the launch step that recorded them with their digests.
    fileprivate static func taxTriageResult(in root: URL, withBAMs: Bool) throws -> (directory: URL, launch: ProvenanceStep) {
        let fileManager = FileManager.default
        let directory = root.appendingPathComponent("taxtriage-1", isDirectory: true)
        try fileManager.copyItem(at: fixture("taxtriage-mini"), to: directory)
        if !withBAMs {
            try fileManager.removeItem(at: directory.appendingPathComponent("minimap2", isDirectory: true))
        }
        let outputs = try removedByTheCleanup.map { relative -> ProvenanceFileDescriptor in
            let url = directory.appendingPathComponent(relative)
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "\(relative)\n".write(to: url, atomically: true, encoding: .utf8)
            return try ProvenanceFileDescriptor.file(url: url, role: .output)
        }
        return (directory, ProvenanceStep(toolName: "taxtriage", toolVersion: "fixture", outputs: outputs))
    }

    /// What a finalize returned, the steps it recorded through its context, and the one build under it.
    fileprivate struct FinalizeRun {
        let finalization: AnalysisRunFinalization
        let recorded: [ProvenanceStep]
        let built: AnalysisResultIndex
        /// The steps the finalize had recorded when the build returned.
        let recordedWhenTheBuildReturned: [ProvenanceStep]
    }

    /// Runs `body`, a tool's finalize, with a context over `base` whose recorder keeps each step, as
    /// the executor's journal does, and whose units recorded `unitSteps`.
    fileprivate static func finalize(
        _ toolID: AnalysisToolID,
        _ directory: URL,
        layout: AnalysisRunLayout,
        base: any AnalysisResultIndexing,
        unitSteps: [ProvenanceStep] = [],
        _ body: (AnalysisRunFinalizeContext) async throws -> AnalysisRunFinalization
    ) async throws -> FinalizeRun {
        let recorded = StepCollector()
        let indexer = CapturingIndexer(base: base, recorded: recorded)
        let context = AnalysisRunFinalizeContext(
            rootDirectory: directory,
            layout: layout,
            projectURL: nil,
            toolID: toolID,
            indexing: indexer,
            recordedSteps: { unitSteps },
            recordStep: { recorded.append($0) }
        )
        let finalization = try await body(context)
        XCTAssertEqual(indexer.builds.count, 1, "the finalize built its index once")
        let build = try XCTUnwrap(indexer.builds.first)
        return FinalizeRun(
            finalization: finalization,
            recorded: recorded.snapshot,
            built: build.index,
            recordedWhenTheBuildReturned: build.recordedBefore
        )
    }

    /// `steps` as the root record writes them, byte for byte, but for one form of path. A core
    /// names some files of the temporary folder by their `/private/var` path, and the root record
    /// names every file there by its `/var` path, the same file, for the units' steps as for the
    /// build's.
    fileprivate static func encoded(_ steps: [ProvenanceStep]) throws -> String {
        String(decoding: try ProvenanceJSON.encoder.encode(steps), as: UTF8.self)
            .replacingOccurrences(of: "/private/var/", with: "/var/")
    }

    fileprivate static func assertEachStepOnce(_ steps: [ProvenanceStep], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Set(steps.map(\.id)).count, steps.count, "a step is named twice, \(steps.map(\.toolName))", file: file, line: line)
    }

    /// The build's steps had all reached the finalize's recorder, in their order, when the builder
    /// returned, the recorder holds each once, and the finalization names none of them.
    fileprivate static func assertTheBuildHandedItsStepsOver(
        _ run: FinalizeRun, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertFalse(run.built.steps.isEmpty, "the build returned its steps", file: file, line: line)
        XCTAssertEqual(
            try encoded(run.recordedWhenTheBuildReturned), try encoded(run.built.steps),
            "each step was handed over before the build returned", file: file, line: line
        )
        XCTAssertEqual(try encoded(run.recorded), try encoded(run.built.steps), "each step recorded once", file: file, line: line)
        XCTAssertEqual(run.finalization.steps, [], "the finalization names no step of the build", file: file, line: line)
    }
}

// MARK: - Live

/// The TaxTriage build over the BAMs of `taxtriage-mini` with the managed samtools, the live form of
/// `AnalysisRunIndexStepRecordTests` (2.9 O5). Every step of the build, its samtools passes
/// included, reaches the root record before the build returns, and each file a step wrote that
/// the cleanup kept is there with the digest the step took.
final class AnalysisRunIndexStepLiveConformanceTests: XCTestCase {
    func testTheTaxTriageBuildOverBAMsHandsItsSamtoolsStepsOverBeforeItReturns() async throws {
        _ = try await ToolAvailability.require("samtools", environment: "samtools")
        let root = try TestTempDirectory.make(prefix: "analysis-run-index-steps-live")
        defer { TestTempDirectory.cleanup(root) }
        let result = try AnalysisRunIndexStepRecordTests.taxTriageResult(in: root, withBAMs: true)

        let run = try await AnalysisRunIndexStepRecordTests.finalize(
            .taxtriage, result.directory, layout: .sharedBatchRoot, base: TaxTriageResultIndexer(), unitSteps: [result.launch]
        ) { context in
            try await AnalysisRunIndexStepRecordTests.taxTriageTool(result.directory).finalize([], context: context)
        }

        XCTAssertTrue(run.built.steps.contains { $0.toolName == "samtools" }, "\(run.built.steps.map(\.toolName))")
        try AnalysisRunIndexStepRecordTests.assertTheBuildHandedItsStepsOver(run)
        let removed = Set(run.recorded.last?.inputs.map(\.path) ?? [])
        for output in run.recorded.flatMap(\.outputs) where !removed.contains(output.path) {
            let taken = try ProvenanceFileDescriptor.file(url: URL(fileURLWithPath: output.path), role: .output)
            XCTAssertEqual(taken.checksumSHA256, output.checksumSHA256, output.path)
        }
    }
}

// MARK: - EsViritu through the executor

extension AnalysisRunIndexStepRecordTests {
    /// What an EsViritu run through the executor left.
    fileprivate struct EsVirituRun {
        let report: AnalysisRunReport
        let lines: [CLIEventLine]
        let project: URL
        let bundle: URL
        /// How long the run went on after the test cancelled it, or nil when nothing cancelled it.
        let afterTheCancel: Duration?

        func folder() throws -> URL {
            try XCTUnwrap(report.analysisDirectory)
        }

        func record() throws -> ProvenanceEnvelope {
            try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: XCTUnwrap(report.recordURL)))
        }

        /// The entries of the run in its source bundle's analysis history.
        var sourceRecords: [AnalysisManifestEntry] {
            AnalysisManifestStore.load(bundleURL: bundle, projectURL: project).analyses
        }
    }

    /// The stand-in EsViritu copies the tables of `esviritu-mini`'s third sample, which name no BAM.
    fileprivate static var esVirituTables: URL {
        fixture("esviritu-mini/SRR35517705").appendingPathComponent("SRR35517705")
    }

    /// Runs a `--project` EsViritu run of one sample through the executor, with `indexing` as its
    /// index builder. `trigger` cancels the run's task at the first log line it accepts, on the
    /// task that wrote the line, so a line of the build cancels the build where it wrote it.
    fileprivate func esVirituRun(
        indexing: CapturingIndexer,
        cancellingAtLine trigger: (@Sendable (String) -> Bool)? = nil
    ) async throws -> EsVirituRun {
        let project = root.appendingPathComponent("Project.lungfish", isDirectory: true)
        let shapes = try BundleShapeFixtures(in: project.appendingPathComponent("Imports", isDirectory: true))
        let esviritu = try StandInEsViritu(root: root.appendingPathComponent("tool"), tables: Self.esVirituTables)
        let tool = EsVirituAnalysisRunTool(
            options: EsVirituAnalysisRunOptions(sampleName: "S1", readFormat: .unpaired, databasePath: esviritu.databaseURL, threads: 2),
            groupsSamples: false,
            pipeline: EsVirituPipeline(condaManager: esviritu.condaManager),
            materializer: FASTQCLIMaterializer(runner: .shared),
            installedDatabase: { [databaseURL = esviritu.databaseURL] in databaseURL }
        )
        let request = AnalysisRunRequest(
            inputs: [shapes.single],
            destination: .project(project),
            commandLine: ["lungfish-cli", "esviritu", "detect"]
        )
        let lines = EventLines()
        let moment = indexing.cancelMoment
        let events = AnalysisRunEvents { line in
            lines.append(line)
            if let trigger, case .log(_, let message)? = line.event, trigger(message) {
                moment.mark()
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        let report = await Task {
            await AnalysisRunExecutor(services: AnalysisRunServices(indexing: indexing)).execute(tool, request, events: events)
        }.value
        return EsVirituRun(
            report: report,
            lines: lines.all,
            project: project,
            bundle: shapes.single,
            afterTheCancel: moment.marked.map { ContinuousClock.now - $0 }
        )
    }

    /// The run ended as cancelled inside the grace, with exit 125 in its report, its root record
    /// and its run record, and its last line is `failed`, with no artifact on any line.
    fileprivate func assertCancelled(_ run: EsVirituRun, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(run.report.status, .cancelled, run.report.message, file: file, line: line)
        XCTAssertEqual(run.report.exitCode, 125, file: file, line: line)
        let afterTheCancel = try XCTUnwrap(run.afterTheCancel, "the test cancelled the run", file: file, line: line)
        XCTAssertLessThan(afterTheCancel, .seconds(5), "the cancelled record is written inside the grace", file: file, line: line)
        let record = try run.record()
        XCTAssertEqual(record.status, .cancelled, file: file, line: line)
        XCTAssertEqual(record.exitStatus, 125, file: file, line: line)
        XCTAssertEqual(AnalysisRunRecord.load(from: try run.folder())?.outcome, .cancelled, file: file, line: line)
        XCTAssertTrue(run.lines.allSatisfy { $0.artifacts.isEmpty }, "no line carries an artifact", file: file, line: line)
        XCTAssertEqual(run.lines.last?.event, .failed(message: run.report.message, detail: nil), file: file, line: line)
    }

    /// The record names nothing of the finalization, neither the batch summary nor the manifest that
    /// the folder holds, and the source bundle's analysis history holds no entry of the run.
    fileprivate func assertNothingOfTheFinalization(
        in record: ProvenanceEnvelope, of run: EsVirituRun, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let folder = try run.folder()
        for name in [EsVirituAnalysisRunTool.summaryFilename, EsVirituBatchResultManifest.filename] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), name, file: file, line: line)
            XCTAssertFalse(record.files.contains { $0.path.hasSuffix("/\(name)") }, name, file: file, line: line)
        }
        XCTAssertEqual(run.sourceRecords.map(\.displayName), [], file: file, line: line)
    }
}

// MARK: - Test doubles

/// Runs a real index builder and keeps what each build returned, with the steps the finalize had
/// recorded by then. With `cancelsAfterTheBuild` it cancels the task that ran the build once the
/// build returns, as a cancel that arrives just after the index ended whole.
private final class CapturingIndexer: AnalysisResultIndexing {
    struct Build: Sendable {
        let index: AnalysisResultIndex
        /// The steps the finalize had recorded through its context when the build returned.
        let recordedBefore: [ProvenanceStep]
    }

    let cancelMoment = CancelMoment()
    private let base: any AnalysisResultIndexing
    private let recorded: StepCollector?
    private let cancelsAfterTheBuild: Bool
    private let kept = Mutex<[Build]>([])

    init(base: any AnalysisResultIndexing, recorded: StepCollector? = nil, cancelsAfterTheBuild: Bool = false) {
        self.base = base
        self.recorded = recorded
        self.cancelsAfterTheBuild = cancelsAfterTheBuild
    }

    var builds: [Build] {
        kept.withLock { $0 }
    }

    func buildIndex(_ request: AnalysisResultIndexRequest) async throws -> AnalysisResultIndex {
        let index = try await base.buildIndex(request)
        let build = Build(index: index, recordedBefore: recorded?.snapshot ?? [])
        kept.withLock { $0.append(build) }
        if cancelsAfterTheBuild {
            cancelMoment.mark()
            withUnsafeCurrentTask { $0?.cancel() }
        }
        return index
    }
}

/// The steps a finalize recorded through its context, in order.
private final class StepCollector: Sendable {
    private let steps = Mutex<[ProvenanceStep]>([])

    func append(_ step: ProvenanceStep) {
        steps.withLock { $0.append(step) }
    }

    var snapshot: [ProvenanceStep] {
        steps.withLock { $0 }
    }
}

/// The lines of a run, in the order they went out.
private final class EventLines: Sendable {
    private let lines = Mutex<[CLIEventLine]>([])

    func append(_ line: CLIEventLine) {
        lines.withLock { $0.append(line) }
    }

    var all: [CLIEventLine] {
        lines.withLock { $0 }
    }
}

/// When a test first cancelled the run's task.
private final class CancelMoment: Sendable {
    private let instant = Mutex<ContinuousClock.Instant?>(nil)

    func mark() {
        instant.withLock { if $0 == nil { $0 = .now } }
    }

    var marked: ContinuousClock.Instant? {
        instant.withLock { $0 }
    }
}
