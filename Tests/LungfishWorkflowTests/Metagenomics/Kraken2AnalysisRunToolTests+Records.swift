// Kraken2AnalysisRunToolTests+Records.swift - What the root record of a Kraken2 run holds, for failures and cancels too
// Copyright (c) 2026 Lungfish Contributors
// SPDX-License-Identifier: MIT

import Foundation
import XCTest
import LungfishIO
import LungfishTestSupport
@testable import LungfishWorkflow

/// Review A8 fixes 3 and 5. The facts the deleted `lungfish.classify` wrapper tests pinned, on
/// the executor's root record, and a cancel that ends the run as cancelled whichever way the
/// pipeline ends.
extension Kraken2AnalysisRunToolTests {

    // MARK: - Database digest (E9)

    func testAGivenDigestThatMatchesTheReceiptIsRecordedWithTheDatabaseAsAReference() async throws {
        let receipt = try Kraken2DatabaseReceiptTests.writeReceipt(in: kraken2.databaseURL)
        let output = root.appendingPathComponent("digest-out", isDirectory: true)
        var given = request([fixtures.singleRoot.path])
        given.databaseDigest = receipt.digest
        let argv = command([fixtures.singleRoot.path, "--db-digest", receipt.digest, "--output-dir", output.path])

        let run = await execute(given, .directory(output), argv: argv)

        XCTAssertEqual(run.report.status, .completed, run.report.message)
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: XCTUnwrap(run.report.recordURL)))
        let database = kraken2.databaseURL.standardizedFileURL
        let reference = try XCTUnwrap(record.files.first { $0.role == .reference && $0.path == database.path }, "\(record.files.map(\.path))")
        XCTAssertEqual(reference.checksumSHA256, receipt.digest)
        XCTAssertEqual(reference.sourceProvenancePath, database.appendingPathComponent(ProvenanceWriter.provenanceFilename).path)
        XCTAssertEqual(record.options.explicit["databaseDigest"], .string(receipt.digest))

        let refusedOutput = root.appendingPathComponent("other-digest-out", isDirectory: true)
        var other = given
        other.databaseDigest = String(repeating: "b", count: 64)
        let refused = await execute(other, .directory(refusedOutput), argv: command([fixtures.singleRoot.path]))
        XCTAssertEqual(refused.report.status, .failed)
        XCTAssertEqual(refused.report.exitCode, 126)
        XCTAssertNil(refused.report.analysisDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: refusedOutput.path))
    }

    /// 2.13 lane 13.15, DB-REF-SIZE with V2-1. The root record's reference and the kraken2 step's reference name the
    /// same digest and the same size, the size of every file the receipt lists, not of the three core files alone.
    func testADbDigestRunGivesTheRootAndTheKraken2StepOneDatabaseReference() async throws {
        try "1\t10239\n".write(to: kraken2.databaseURL.appendingPathComponent("seqid2taxid.map"), atomically: true, encoding: .utf8)
        let receipt = try Kraken2DatabaseReceiptTests.writeReceipt(in: kraken2.databaseURL)
        XCTAssertGreaterThan(receipt.size, 24, "the receipt lists more than the three core files")
        let output = root.appendingPathComponent("digest-size-out", isDirectory: true)
        var given = request([fixtures.singleRoot.path])
        given.databaseDigest = receipt.digest
        let argv = command([fixtures.singleRoot.path, "--db-digest", receipt.digest, "--output-dir", output.path])

        let run = await execute(given, .directory(output), argv: argv, payloadDigest: receipt.digest)

        XCTAssertEqual(run.report.status, .completed, run.report.message)
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: XCTUnwrap(run.report.recordURL)))
        let database = kraken2.databaseURL.standardizedFileURL.path
        let rootReference = try XCTUnwrap(record.files.first { $0.role == .reference && $0.path == database })
        let kraken2 = try XCTUnwrap(record.steps.first { $0.toolName == "kraken2" })
        let stepReference = try XCTUnwrap(kraken2.inputs.first { $0.role == .reference && $0.path == database })
        XCTAssertEqual(rootReference.checksumSHA256, receipt.digest)
        XCTAssertEqual(stepReference.checksumSHA256, rootReference.checksumSHA256)
        XCTAssertEqual(rootReference.fileSize, receipt.size)
        XCTAssertEqual(stepReference.fileSize, rootReference.fileSize)
    }

    // MARK: - Failures (E5)

    func testAPipelineThatFailsEndsFailedWithItsStepsAndKeepsTheFolder() async throws {
        let failing: PipelineRun = { config, _ in
            try Self.writeFailedPipelineRecord(in: config.outputDirectory)
            throw Kraken2StandInFailure(message: "kraken2 exited with status 2")
        }

        let run = await execute(
            request([fixtures.singleRoot.path]), .project(fixtures.projectURL),
            argv: command([fixtures.singleRoot.path, "--project", fixtures.projectURL.path]), runPipeline: failing
        )

        let record = try assertKeptFolder(of: run, status: .failed, exitCode: AnalysisRunExitCode.workflowError, outcome: .failed)
        XCTAssertEqual(record.options.resolvedDefaults["profileState"], .string("failed"))
        XCTAssertEqual(record.options.resolvedDefaults["failureStage"], .string("pipeline"))
        XCTAssertTrue(record.steps.contains { $0.toolName == "kraken2" && $0.exitStatus == 2 }, "the failed pipeline's steps")
    }

    func testAMaterializationThatFailsRecordsItsStage() async throws {
        let subset = fixtures.subsetOfSingle.standardizedFileURL

        let run = await execute(
            request([subset.path]), .project(fixtures.projectURL),
            argv: command([subset.path, "--project", fixtures.projectURL.path])
        )

        let record = try assertKeptFolder(of: run, status: .failed, exitCode: AnalysisRunExitCode.workflowError, outcome: .failed)
        XCTAssertEqual(record.options.resolvedDefaults["profileState"], .string("failed"))
        XCTAssertEqual(record.options.resolvedDefaults["failureStage"], .string("materialization"))
    }

    // MARK: - Inputs

    func testABundleOfSeveralFilesIsRecordedAsTheOriginOfEach() async throws {
        let bundle = fixtures.chunkedRoot.standardizedFileURL
        let output = root.appendingPathComponent("chunked-out", isDirectory: true)

        let run = await execute(request([bundle.path]), .directory(output), argv: command([bundle.path, "--output-dir", output.path]))

        XCTAssertEqual(run.report.status, .completed, run.report.message)
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: XCTUnwrap(run.report.recordURL)))
        XCTAssertEqual(record.options.explicit["originalInputs"], .array([.file(bundle)]))
        XCTAssertEqual(record.options.resolvedDefaults["originalInputs"], .array([.file(bundle), .file(bundle)]))
        guard case .array(let executed)? = record.options.resolvedDefaults["executionInputs"] else {
            return XCTFail("the record names the files kraken2 read")
        }
        let files = executed.compactMap { value -> String? in
            if case .file(let url) = value { return url.path }
            return nil
        }
        XCTAssertEqual(files.count, 2)
        let argv = try kraken2.argv()
        for file in files {
            XCTAssertTrue(argv.contains(file), "kraken2 reads \(file): \(argv)")
        }
    }

    func testRecursiveIsRecordedAsGivenAndResolved() async throws {
        let output = root.appendingPathComponent("recursive-out", isDirectory: true)
        var given = request([fixtures.singleRoot.path])
        given.recursive = true

        let run = await execute(given, .directory(output), argv: command([fixtures.singleRoot.path, "--recursive", "--output-dir", output.path]))

        XCTAssertEqual(run.report.status, .completed, run.report.message)
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: XCTUnwrap(run.report.recordURL)))
        XCTAssertEqual(record.options.explicit["recursive"], .boolean(true))
        XCTAssertEqual(record.options.resolvedDefaults["recursive"], .boolean(true))
    }

    func testTheRootRecordNamesNoCondaEnvironmentAndTheKraken2StepKeepsItsOwn() async throws {
        let output = root.appendingPathComponent("identity-out", isDirectory: true)

        let run = await execute(request([fixtures.singleRoot.path]), .directory(output), argv: command([fixtures.singleRoot.path, "--output-dir", output.path]))

        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: XCTUnwrap(run.report.recordURL)))
        XCTAssertNil(record.runtimeIdentity.condaEnvironment, "the run is lungfish-cli, not a conda tool")
        let step = try XCTUnwrap(record.steps.first { $0.toolName == "kraken2" })
        XCTAssertNotNil(step.runtimeIdentity?.condaEnvironment, "the kraken2 step keeps its environment")
    }

    // MARK: - Cancel (E5, SWIFT X2)

    /// The app's Cancel sends SIGTERM to the process group, so kraken2 can die and the pipeline
    /// throw a plain error before the task sees the cancel. The cancel request decides.
    func testACancelWhoseChildDiesFirstIsRecordedAsCancelled() async throws {
        let cancel = Kraken2Flag()
        let killed: PipelineRun = { _, _ in
            cancel.set()
            throw Kraken2StandInFailure(message: "kraken2 ended on signal 15")
        }

        let run = await execute(
            request([fixtures.singleRoot.path]), .project(fixtures.projectURL),
            argv: command([fixtures.singleRoot.path, "--project", fixtures.projectURL.path]),
            runPipeline: killed, cancelRequested: { cancel.value }
        )

        try assertCancelledInThePipeline(run)
    }

    func testCancellingTheTaskWhileThePipelineRunsIsRecordedAsCancelled() async throws {
        let started = Kraken2Flag()
        let sleeping: PipelineRun = { _, _ in
            started.set()
            try await Task.sleep(for: .seconds(60))
            throw Kraken2StandInFailure(message: "the stand-in was not cancelled")
        }
        let given = request([fixtures.singleRoot.path])
        let project: URL = fixtures.projectURL
        let argv = command([fixtures.singleRoot.path, "--project", project.path])
        let databaseURL: URL = kraken2.databaseURL
        let condaManager = kraken2.condaManager

        let task = Task {
            await Self.run(given, .project(project), argv: argv, databaseURL: databaseURL, condaManager: condaManager, runPipeline: sleeping)
        }
        let deadline = Date().addingTimeInterval(30)
        while !started.value, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(started.value, "the pipeline started")
        task.cancel()
        let run = await task.value

        try assertCancelledInThePipeline(run)
    }

    // MARK: - Batch samples that stop (review A8c fix 3)

    /// A batch sample keeps the pipeline's record in its folder. When its pipeline fails, that
    /// record converges on the root record's rules as a completed sample's does, so one result
    /// holds one defaults table and one home of the read-set plan (E12, E13, D8).
    func testAFailedBatchSampleKeepsTheCommandsDefaultsAndOneHomeOfThePlan() async throws {
        let inputs = [fixtures.singleRoot.path, fixtures.mixedRoot.path]
        let mixedName = fixtures.mixedRoot.lastPathComponent
        let pipeline = ClassificationPipeline(condaManager: kraken2.condaManager)
        let failedFolders = Kraken2Captured<URL>()
        let failingMixed: PipelineRun = { config, progress in
            guard ((config.originalInputFiles ?? []) + config.inputFiles).contains(where: { $0.path.contains(mixedName) }) else {
                return try await pipeline.classify(config: config, progress: progress)
            }
            failedFolders.append(config.outputDirectory)
            try Self.writeFailedPipelineRecord(
                in: config.outputDirectory,
                readSetPlan: AnalysisRootRecordOptions.readSetPlanValue(of: config.readSetPlan)
            )
            throw Kraken2StandInFailure(message: "kraken2 exited with status 2")
        }

        let run = await execute(
            request(inputs), .project(fixtures.projectURL), batch: true,
            argv: command(inputs + ["--batch", "--project", fixtures.projectURL.path]),
            indexing: StubKraken2Indexer(), runPipeline: failingMixed
        )

        XCTAssertEqual(run.report.status, .completed, "the other sample completes: \(run.report.message)")
        let folder = try XCTUnwrap(failedFolders.values.first, "the mixed sample ran")
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: folder))
        XCTAssertEqual(record.status, .failed)
        XCTAssertNil(record.options.defaults["preset"], "no preset nobody gave (E12)")
        XCTAssertEqual(record.options.defaults["confidence"], Kraken2RunRecordOptions.commandDefaults["confidence"], "the command's table (D8)")
        XCTAssertEqual(record.options.defaults["readFormat"], Kraken2RunRecordOptions.commandDefaults["readFormat"])
        XCTAssertNil(record.options.explicit[AnalysisRootRecordOptions.readSetPlanKey], "the plan left its legacy home")
        XCTAssertEqual(record.readSetPlan?.place, .resolvedDefaults, "the plan's one home (E13)")
    }

    /// A cancel kills the sample's kraken2 child, which can end the pipeline with a plain error
    /// first. The sample's own record then says cancelled, from the cancel request (E5, SWIFT X2).
    func testACancelledBatchSampleRecordsTheCancelInItsOwnRecord() async throws {
        let cancel = Kraken2Flag()
        let folders = Kraken2Captured<URL>()
        let killed: PipelineRun = { config, _ in
            folders.append(config.outputDirectory)
            try Self.writeFailedPipelineRecord(
                in: config.outputDirectory,
                readSetPlan: AnalysisRootRecordOptions.readSetPlanValue(of: config.readSetPlan)
            )
            cancel.set()
            throw Kraken2StandInFailure(message: "kraken2 ended on signal 15")
        }
        let inputs = [fixtures.singleRoot.path]

        let run = await execute(
            request(inputs), .project(fixtures.projectURL), batch: true,
            argv: command(inputs + ["--batch", "--project", fixtures.projectURL.path]),
            indexing: StubKraken2Indexer(), runPipeline: killed, cancelRequested: { cancel.value }
        )

        XCTAssertEqual(run.report.status, .cancelled, run.report.message)
        XCTAssertEqual(run.report.exitCode, AnalysisRunExitCode.cancelled)
        let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: XCTUnwrap(folders.values.first)))
        XCTAssertEqual(record.status, .cancelled, "never failed from the child's signal (E5)")
        XCTAssertEqual(record.exitStatus, Int(AnalysisRunExitCode.cancelled), "the cancel request's exit, as the root record says (E5)")
        XCTAssertEqual(record.steps.map(\.toolName), ["kraken2"])
        XCTAssertEqual(record.steps.first?.exitStatus, 2, "the step keeps the exit its child ended with")
        XCTAssertEqual(record.options.resolvedDefaults["profileState"], .string("cancelled"))
        XCTAssertNil(record.options.defaults["preset"])
    }

    // MARK: - Kept staged inputs (ruling R1 of Phase 2.8)

    /// A merge sample keeps the header-only mate staged beside its merged reads (O1). The batch
    /// root names it as an input and an output, the roles the sample's own record gives it, with
    /// the digest and size the staging step recorded in the sample's record, as a one-folder root
    /// names it through the pipeline's steps.
    func testABatchRootNamesEachSamplesKeptStagedInputWithItsStagingDigest() async throws {
        let inputs = [fixtures.singleRoot.path, fixtures.mergeDerivative.path]

        let run = await execute(
            request(inputs), .project(fixtures.projectURL), batch: true,
            argv: command(inputs + ["--batch", "--project", fixtures.projectURL.path]),
            indexing: StubKraken2Indexer()
        )

        XCTAssertEqual(run.report.status, .completed, run.report.message)
        let batchRoot = try XCTUnwrap(run.report.analysisDirectory)
        let manifest = try XCTUnwrap(MetagenomicsBatchResultStore.loadClassification(from: batchRoot))
        var staged: [ProvenanceFileDescriptor] = []
        for sample in manifest.samples {
            let folder = batchRoot.appendingPathComponent(sample.resultDirectory, isDirectory: true)
            let kept = folder.appendingPathComponent(KrakenReadSetPlanner.inputsDirectoryName).path + "/"
            let record = try XCTUnwrap(ProvenanceRecorder.loadEnvelope(from: folder), sample.sampleId)
            staged += record.steps.flatMap(\.outputs).filter {
                $0.path.hasPrefix(kept) && FileManager.default.fileExists(atPath: $0.path)
            }
        }
        XCTAssertTrue(staged.contains { $0.path.hasSuffix(".emptymate.fastq") }, "the merge sample keeps its mate: \(staged.map(\.path))")
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: XCTUnwrap(run.report.recordURL)))
        for file in staged {
            for role in [FileRole.input, .output] {
                let named = record.files.first { $0.path == file.path && $0.role == role }
                XCTAssertEqual(named?.checksumSHA256, file.checksumSHA256, "\(file.path) as \(role)")
                XCTAssertEqual(named?.fileSize, file.fileSize, "\(file.path) as \(role)")
                XCTAssertEqual(named?.format, .fastq, "\(file.path) as \(role)")
            }
            let output = record.outputs.first { $0.path == file.path && $0.role == .output }
            XCTAssertEqual(output?.checksumSHA256, file.checksumSHA256, file.path)
        }
        XCTAssertEqual(
            record.output.map { URL(fileURLWithPath: $0.path).lastPathComponent },
            Kraken2AnalysisRunTool.batchSummaryFilename,
            "the summary stays the run's output"
        )
    }

    // MARK: - Helpers

    /// A failed or cancelled run keeps its folder, its root record with `status`, and its run
    /// record with `outcome`, so the folder is listed for review (E5).
    @discardableResult
    private func assertKeptFolder(
        of run: (report: AnalysisRunReport, events: [CLIEventLine]),
        status: RunStatus,
        exitCode: Int32,
        outcome: AnalysisRunRecord.Outcome,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ProvenanceEnvelope {
        XCTAssertEqual(run.report.status, status, run.report.message, file: file, line: line)
        XCTAssertEqual(run.report.exitCode, exitCode, file: file, line: line)
        let folder = try XCTUnwrap(run.report.analysisDirectory, file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path), "the folder is kept", file: file, line: line)
        XCTAssertEqual(AnalysisRunRecord.load(from: folder)?.outcome, outcome, file: file, line: line)
        let record = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: XCTUnwrap(run.report.recordURL)), file: file, line: line)
        XCTAssertEqual(record.status, status, file: file, line: line)
        return record
    }

    private func assertCancelledInThePipeline(
        _ run: (report: AnalysisRunReport, events: [CLIEventLine]),
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let record = try assertKeptFolder(
            of: run, status: .cancelled, exitCode: AnalysisRunExitCode.cancelled, outcome: .cancelled, file: file, line: line
        )
        XCTAssertEqual(record.options.resolvedDefaults["profileState"], .string("cancelled"), file: file, line: line)
        XCTAssertEqual(record.options.resolvedDefaults["failureStage"], .string("pipeline"), file: file, line: line)
    }

    /// The pipeline's record of a run whose kraken2 step failed, as the pipeline leaves it, with
    /// the pipeline's own defaults (confidence 0, read format unpaired, the balanced preset) and a
    /// read-set plan in its one home, the resolved options, where the pipeline writes it (B16).
    static func writeFailedPipelineRecord(in directory: URL, readSetPlan: ParameterValue? = nil) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date()
        var resolved: [String: ParameterValue] = ["profileState": .string("failed")]
        resolved[AnalysisRootRecordOptions.readSetPlanKey] = readSetPlan
        let envelope = ProvenanceEnvelope(
            workflowName: "Metagenomics Classification",
            toolName: "kraken2",
            toolVersion: "2.1.3",
            options: ProvenanceOptions(
                explicit: ["databaseName": .string("Viral")],
                defaults: ["confidence": .number(0), "readFormat": .string("unpaired"), "preset": .string("balanced")],
                resolvedDefaults: resolved
            ),
            steps: [ProvenanceStep(
                toolName: "kraken2", toolVersion: "2.1.3", argv: ["kraken2", "--db", "viral"], exitStatus: 2,
                wallTimeSeconds: 0, startedAt: now, completedAt: now
            )],
            exitStatus: 2,
            status: .failed
        )
        _ = try ProvenanceWriter(signingProvider: nil).write(envelope, to: directory)
    }
}

/// The values a stand-in pipeline keeps for the test to read after the run.
final class Kraken2Captured<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []

    var values: [Value] { lock.withLock { stored } }

    func append(_ value: Value) {
        lock.withLock { stored.append(value) }
    }
}

/// A flag a stand-in pipeline sets and a test or a cancel source reads.
final class Kraken2Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool { lock.withLock { stored } }

    func set() {
        lock.withLock { stored = true }
    }
}

/// The error a stand-in pipeline throws.
struct Kraken2StandInFailure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
