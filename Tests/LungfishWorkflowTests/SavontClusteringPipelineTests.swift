import Foundation
import LungfishIO
import XCTest
@testable import LungfishWorkflow

final class SavontClusteringPipelineTests: XCTestCase {
    func testSuccessfulRunNormalizesPublishesAndRecordsCompleteProvenance() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtime = fixture.runtimeIdentity
        let runner = FakeSavontProcessRunner(actions: [
            .result(
                SavontProcessResult(
                    exitCode: 0,
                    stdout: "clustered\n",
                    stderr: "diagnostic\n",
                    argv: ["/managed/savont"],
                    runtimeIdentity: runtime,
                    startedAt: Date(timeIntervalSince1970: 100),
                    completedAt: Date(timeIntervalSince1970: 102)
                ),
                fasta: ">final_consensus_0_depth_7\nAC\nGT\n>known_ReadCount-2\nTGCA\n"
            ),
        ])
        let request = try SavontClusteringRunRequest(
            inputFASTQURL: fixture.input,
            outputFASTAURL: fixture.output,
            threads: 4
        )

        let result = try await SavontClusteringPipeline(
            processRunner: runner,
            scratchRootURL: fixture.root
        ).run(request)

        XCTAssertEqual(result.outputFASTAURL, fixture.output.standardizedFileURL)
        XCTAssertEqual(result.provenanceURL, ProvenanceRecorder.fileSidecarURL(for: fixture.output))
        XCTAssertEqual(result.summary, SavontClusterSummary(clusterCount: 2, totalSupportingReads: 9))
        XCTAssertFalse(result.usedSingleThreadFallback)
        XCTAssertFalse(result.usedSingleStrandFallback)
        XCTAssertEqual(
            try String(contentsOf: fixture.output, encoding: .utf8),
            ">final_consensus_0_depth_7_ReadCount-7\nACGT\n>known_ReadCount-2\nTGCA\n"
        )

        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertEqual(envelope.workflowName, "lungfish fastq savont-cluster")
        XCTAssertEqual(envelope.workflowVersion, SavontClusteringRunRequest.workflowVersion)
        XCTAssertEqual(envelope.toolName, "savont")
        XCTAssertEqual(envelope.toolVersion, SavontClusteringRunRequest.toolVersion)
        XCTAssertEqual(envelope.argv, [
            "lungfish-cli", "fastq", "savont-cluster", fixture.input.path,
            "--output", fixture.output.path,
            "--threads", "4",
            "--quality-value-cutoff", "90",
            "--min-cluster-size", "3",
        ])
        XCTAssertEqual(envelope.durableReplayArgv, envelope.argv)
        XCTAssertEqual(envelope.runtimeIdentity, runtime)
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.stderr, "diagnostic\n")
        XCTAssertNotNil(envelope.wallTimeSeconds)
        XCTAssertEqual(envelope.options.explicit["inputFASTQ"], .file(fixture.input))
        XCTAssertEqual(envelope.options.explicit["outputFASTA"], .file(fixture.output))
        XCTAssertEqual(envelope.options.defaults["qualityValueCutoff"], .integer(90))
        XCTAssertEqual(envelope.options.defaults["minimumClusterSize"], .integer(3))
        XCTAssertEqual(envelope.options.resolvedDefaults["threads"], .integer(4))
        XCTAssertEqual(envelope.options.resolvedDefaults["singleStrand"], .boolean(false))
        XCTAssertEqual(envelope.options.resolvedDefaults["clusterCount"], .integer(2))
        XCTAssertEqual(envelope.options.resolvedDefaults["totalSupportingReads"], .integer(9))

        let topInput = try XCTUnwrap(envelope.files.first { $0.path == fixture.input.path && $0.role == .input })
        XCTAssertNotNil(topInput.checksumSHA256)
        XCTAssertEqual(topInput.fileSize, 16)
        let finalOutput = try XCTUnwrap(envelope.output)
        XCTAssertEqual(finalOutput.path, fixture.output.path)
        XCTAssertNotNil(finalOutput.checksumSHA256)
        XCTAssertEqual(finalOutput.fileSize, 68)
        XCTAssertNotNil(finalOutput.originPath)

        XCTAssertEqual(envelope.steps.count, 2)
        let materialization = envelope.steps[0]
        let step = envelope.steps[1]
        XCTAssertEqual(materialization.toolName, "lungfish-internal materialize-savont-clustering-fastq")
        XCTAssertNil(materialization.durableReplayArgv)
        XCTAssertEqual(step.toolName, "savont")
        XCTAssertEqual(Array(step.argv.prefix(2)), ["/managed/savont", "asv"])
        XCTAssertEqual(step.argv[2], step.inputs.first?.path)
        XCTAssertNotEqual(step.argv[2], fixture.input.path)
        XCTAssertEqual(step.exitStatus, 0)
        XCTAssertEqual(step.stderr, "diagnostic\n")
        XCTAssertEqual(step.wallTimeSeconds, 2)
        XCTAssertEqual(step.runtimeIdentity, runtime)
        XCTAssertEqual(materialization.inputs.map(\.path), [fixture.input.path])
        XCTAssertEqual(step.inputs.map(\.path), materialization.outputs.map(\.path))
        XCTAssertNotNil(step.inputs.first?.checksumSHA256)
        XCTAssertEqual(step.outputs.count, 1)
        XCTAssertEqual(step.outputs.first?.fileSize, 57)
        XCTAssertTrue(step.outputs.first?.path.hasSuffix("/final_asvs.fasta") == true)
        XCTAssertTrue(try fixture.temporaryArtifacts().isEmpty)
    }

    func testBundleInputUsesDurableBundleAtTopLevelAndMaterializedPayloadForAttempt() async throws {
        let fixture = try Fixture(bundleInput: true)
        defer { fixture.remove() }
        let runner = FakeSavontProcessRunner(actions: [
            .success(fasta: ">c_depth_3\nACGT\n"),
        ])
        let request = try SavontClusteringRunRequest(
            inputFASTQURL: fixture.input,
            outputFASTAURL: fixture.output,
            threads: 2
        )

        let result = try await SavontClusteringPipeline(
            processRunner: runner,
            scratchRootURL: fixture.root
        ).run(request)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))

        XCTAssertEqual(envelope.argv[3], fixture.input.path)
        let durable = try XCTUnwrap(envelope.files.first { $0.path == fixture.input.path })
        XCTAssertNotNil(durable.checksumSHA256)
        XCTAssertNotNil(durable.fileSize)
        let materialization = try XCTUnwrap(envelope.steps.first)
        let attempt = try XCTUnwrap(envelope.steps.last)
        XCTAssertEqual(materialization.toolName, "lungfish-internal materialize-savont-clustering-fastq")
        XCTAssertEqual(attempt.toolName, "savont")
        let resolved = try XCTUnwrap(attempt.inputs.first)
        let materializedOutput = try XCTUnwrap(materialization.outputs.first)
        XCTAssertEqual(resolved.path, materializedOutput.path)
        XCTAssertEqual(resolved.checksumSHA256, materializedOutput.checksumSHA256)
        XCTAssertEqual(resolved.fileSize, materializedOutput.fileSize)
        let invocations = await runner.invocations()
        let invocation = try XCTUnwrap(invocations.first)
        XCTAssertEqual(invocation.arguments[1], resolved.path)
        XCTAssertNotEqual(invocation.arguments[1], fixture.payload.path)
        XCTAssertTrue(try fixture.temporaryArtifacts().isEmpty)
    }

    func testPlainFASTQIsMaterializedBeforeRunnerCanMutateSource() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let originalFASTQ = try String(contentsOf: fixture.input, encoding: .utf8)
        let consumedChecksum = try ProvenanceFileHasher.sha256(of: fixture.input)
        let consumedSize = try ProvenanceFileHasher.fileSize(of: fixture.input)
        let replacementFASTQ = "@replacement\nTTTTTT\n+\nIIIIII\n"
        let runner = FakeSavontProcessRunner(actions: [
            .mutateSourceAndInspectInput(
                fixture.input,
                replacement: replacementFASTQ,
                expectedInput: originalFASTQ,
                fasta: ">c_depth_3\nACGT\n"
            ),
        ])
        let request = try SavontClusteringRunRequest(
            inputFASTQURL: fixture.input,
            outputFASTAURL: fixture.output,
            threads: 2
        )

        let result = try await SavontClusteringPipeline(
            processRunner: runner,
            scratchRootURL: fixture.root
        ).run(request)
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL)
        )

        XCTAssertEqual(
            try String(contentsOf: fixture.input, encoding: .utf8),
            replacementFASTQ
        )
        XCTAssertNotEqual(try ProvenanceFileHasher.sha256(of: fixture.input), consumedChecksum)
        let topLevelInput = try XCTUnwrap(
            envelope.files.first { $0.path == fixture.input.path && $0.role == .input }
        )
        XCTAssertEqual(envelope.steps.map(\.toolName), [
            "lungfish-internal materialize-savont-clustering-fastq",
            "savont",
        ])
        let materialization = envelope.steps[0]
        let attemptInput = try XCTUnwrap(envelope.steps[1].inputs.first)
        XCTAssertEqual(topLevelInput.checksumSHA256, consumedChecksum)
        XCTAssertEqual(topLevelInput.fileSize, consumedSize)
        XCTAssertEqual(attemptInput.checksumSHA256, consumedChecksum)
        XCTAssertEqual(attemptInput.fileSize, consumedSize)
        XCTAssertEqual(attemptInput.path, materialization.outputs.first?.path)
        XCTAssertEqual(attemptInput.checksumSHA256, materialization.outputs.first?.checksumSHA256)
        XCTAssertEqual(attemptInput.fileSize, materialization.outputs.first?.fileSize)
        XCTAssertNotEqual(attemptInput.path, fixture.input.path)
    }

    func testBundleMaterializationConcatenatesEveryPayloadBeforeClustering() async throws {
        let fixture = try Fixture(bundleInput: true)
        defer { fixture.remove() }
        let firstFASTQ = try String(contentsOf: fixture.payload, encoding: .utf8)
        let secondPayload = fixture.input.appendingPathComponent("part-2.fastq")
        let secondFASTQ = "@r2\nTGCA\n+\nJJJJ\n"
        try secondFASTQ.write(to: secondPayload, atomically: true, encoding: .utf8)
        let firstEntry = FASTQSourceFileManifest.SourceFileEntry(
            filename: fixture.payload.lastPathComponent,
            originalPath: fixture.payload.path,
            sizeBytes: Int64(Data(firstFASTQ.utf8).count),
            isSymlink: false
        )
        let secondEntry = FASTQSourceFileManifest.SourceFileEntry(
            filename: secondPayload.lastPathComponent,
            originalPath: secondPayload.path,
            sizeBytes: Int64(Data(secondFASTQ.utf8).count),
            isSymlink: false
        )
        try FASTQSourceFileManifest(files: [firstEntry, secondEntry]).save(to: fixture.input)
        let runner = FakeSavontProcessRunner(actions: [
            .inspectInput(
                expectedInput: firstFASTQ + secondFASTQ,
                fasta: ">first_depth_3\nACGT\n>second_depth_4\nTGCA\n"
            ),
        ])
        let request = try SavontClusteringRunRequest(
            inputFASTQURL: fixture.input,
            outputFASTAURL: fixture.output,
            threads: 2
        )

        let result = try await SavontClusteringPipeline(
            processRunner: runner,
            scratchRootURL: fixture.root
        ).run(request)
        let envelope = try XCTUnwrap(
            ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL)
        )

        XCTAssertEqual(result.summary.clusterCount, 2)
        XCTAssertEqual(envelope.steps.map(\.toolName), [
            "lungfish-internal materialize-savont-clustering-fastq",
            "savont",
        ])
        let materialization = envelope.steps[0]
        XCTAssertEqual(materialization.resolvedOptions["payloadCount"], .integer(2))
        XCTAssertEqual(
            Set(materialization.inputs.map(\.path)).intersection([fixture.payload.path, secondPayload.path]),
            Set([fixture.payload.path, secondPayload.path])
        )
        XCTAssertEqual(envelope.steps[1].inputs.first?.path, materialization.outputs.first?.path)
        XCTAssertEqual(
            envelope.steps[1].inputs.first?.checksumSHA256,
            materialization.outputs.first?.checksumSHA256
        )
        XCTAssertTrue(try fixture.temporaryArtifacts().isEmpty)
    }

    func testCrashRetriesWithOneThreadAndRecordsBothAttempts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = FakeSavontProcessRunner(actions: [
            .failure(status: 139, stderr: "segmentation fault"),
            .success(fasta: ">c_depth_4\nACGT\n"),
        ])
        let request = try SavontClusteringRunRequest(
            inputFASTQURL: fixture.input,
            outputFASTAURL: fixture.output,
            threads: 8
        )

        let result = try await SavontClusteringPipeline(
            processRunner: runner,
            scratchRootURL: fixture.root
        ).run(request)

        XCTAssertTrue(result.usedSingleThreadFallback)
        XCTAssertFalse(result.usedSingleStrandFallback)
        let invocations = await runner.invocations()
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(argument(after: "-t", in: invocations[0].arguments), "8")
        XCTAssertEqual(argument(after: "-t", in: invocations[1].arguments), "1")
        XCTAssertEqual(invocations[0].arguments[1], invocations[1].arguments[1])
        XCTAssertNotEqual(invocations[0].arguments[1], fixture.input.path)
        XCTAssertNotEqual(invocations[0].workingDirectory, invocations[1].workingDirectory)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        let attemptSteps = envelope.steps.filter { $0.toolName == "savont" }
        XCTAssertEqual(attemptSteps.map(\.exitStatus), [139, 0])
        XCTAssertEqual(attemptSteps.count, invocations.count)
        XCTAssertTrue(try fixture.temporaryArtifacts().isEmpty)
    }

    func testLowSNPmerRetriesSingleStrand() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let lowSNPmer = "Less than 0.1% of SNPmers were bidirectional; retry with --single-strand"
        let runner = FakeSavontProcessRunner(actions: [
            .failure(status: 1, stderr: lowSNPmer),
            .success(fasta: ">c_depth_5\nACGT\n"),
        ])
        let request = try SavontClusteringRunRequest(
            inputFASTQURL: fixture.input,
            outputFASTAURL: fixture.output,
            threads: 4
        )

        let result = try await SavontClusteringPipeline(
            processRunner: runner,
            scratchRootURL: fixture.root
        ).run(request)

        XCTAssertFalse(result.usedSingleThreadFallback)
        XCTAssertTrue(result.usedSingleStrandFallback)
        let invocations = await runner.invocations()
        XCTAssertFalse(invocations[0].arguments.contains("--single-strand"))
        XCTAssertTrue(invocations[1].arguments.contains("--single-strand"))
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        let attemptSteps = envelope.steps.filter { $0.toolName == "savont" }
        XCTAssertEqual(attemptSteps.count, 2)
        XCTAssertEqual(attemptSteps.map(\.exitStatus), [1, 0])
        XCTAssertTrue(try fixture.temporaryArtifacts().isEmpty)
    }

    func testRepeatedLowSNPmerFailurePublishesEmptyFASTA() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let lowSNPmer = "Less than 0.1% of SNPmers were bidirectional; retry with --single-strand"
        let runner = FakeSavontProcessRunner(actions: [
            .failure(status: 1, stderr: lowSNPmer),
            .failure(status: 1, stderr: lowSNPmer),
        ])
        let request = try SavontClusteringRunRequest(
            inputFASTQURL: fixture.input,
            outputFASTAURL: fixture.output,
            threads: 3
        )

        let result = try await SavontClusteringPipeline(
            processRunner: runner,
            scratchRootURL: fixture.root
        ).run(request)

        XCTAssertEqual(result.summary, SavontClusterSummary(clusterCount: 0, totalSupportingReads: 0))
        XCTAssertEqual(try Data(contentsOf: fixture.output), Data())
        XCTAssertTrue(result.usedSingleStrandFallback)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        let attemptSteps = envelope.steps.filter { $0.toolName == "savont" }
        XCTAssertEqual(attemptSteps.count, 2)
        XCTAssertEqual(attemptSteps.map(\.exitStatus), [1, 1])
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.options.resolvedDefaults["emptyClusterFallback"], .boolean(true))
        XCTAssertTrue(try fixture.temporaryArtifacts().isEmpty)
    }

    func testMaterializationFailureUsesSavontSpecificErrorMessage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let symlinkTarget = fixture.root.appendingPathComponent("symlink-target.fastq")
        try FileManager.default.moveItem(at: fixture.input, to: symlinkTarget)
        try FileManager.default.createSymbolicLink(at: fixture.input, withDestinationURL: symlinkTarget)
        let request = try SavontClusteringRunRequest(
            inputFASTQURL: fixture.input,
            outputFASTAURL: fixture.output
        )

        do {
            _ = try await SavontClusteringPipeline(
                processRunner: FakeSavontProcessRunner(actions: []),
                scratchRootURL: fixture.root
            ).run(request)
            XCTFail("Expected materialization failure")
        } catch let error as SavontClusteringError {
            guard case .inputMaterializationFailed(let inputURL, _) = error else {
                return XCTFail("Unexpected Savont error: \(error)")
            }
            XCTAssertEqual(inputURL, fixture.input.standardizedFileURL)
            XCTAssertTrue(error.localizedDescription.contains("Savont could not materialize"))
            XCTAssertFalse(error.localizedDescription.localizedCaseInsensitiveContains("MHC"))
        } catch {
            XCTFail("Expected a Savont-specific error, got \(error)")
        }

        XCTAssertTrue(try fixture.temporaryArtifacts().isEmpty)
    }

    func testMHCReportMaterializationErrorTranslationOmitsMHCContext() throws {
        let inputURL = URL(fileURLWithPath: "/input/reads.fastq")
        let error = SavontClusteringPipeline.inputMaterializationError(
            for: inputURL,
            underlyingError: FullLengthONTMHCGenotypingError.reportFailed(
                "injected materializer failure"
            )
        )

        guard case .inputMaterializationFailed(let translatedURL, let reason) = error else {
            return XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(translatedURL, inputURL)
        XCTAssertEqual(reason, "injected materializer failure")
        XCTAssertFalse(error.localizedDescription.localizedCaseInsensitiveContains("MHC"))
        XCTAssertFalse(error.localizedDescription.contains("genotyping report"))
    }

    func testOrdinaryFailureThrowsAndCleansScratchWithoutPublishing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = FakeSavontProcessRunner(actions: [.failure(status: 42, stderr: "bad input")])
        let request = try SavontClusteringRunRequest(inputFASTQURL: fixture.input, outputFASTAURL: fixture.output)

        do {
            _ = try await SavontClusteringPipeline(processRunner: runner, scratchRootURL: fixture.root).run(request)
            XCTFail("Expected Savont failure")
        } catch SavontClusteringError.processFailed(let status, let stderr) {
            XCTAssertEqual(status, 42)
            XCTAssertEqual(stderr, "bad input")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: ProvenanceRecorder.fileSidecarURL(for: fixture.output).path))
        XCTAssertTrue(try fixture.temporaryArtifacts().isEmpty)
    }

    func testCancellationCleansAttemptScratchAndDoesNotPublish() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = FakeSavontProcessRunner(actions: [.waitForCancellation])
        let request = try SavontClusteringRunRequest(inputFASTQURL: fixture.input, outputFASTAURL: fixture.output)
        let task = Task {
            try await SavontClusteringPipeline(processRunner: runner, scratchRootURL: fixture.root).run(request)
        }
        while await runner.invocations().isEmpty {
            await Task.yield()
        }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
        XCTAssertTrue(try fixture.temporaryArtifacts().isEmpty)
    }

    func testCancellationCleanupFailureThrowsSavontErrorWithRetainedRunRoot() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = FakeSavontProcessRunner(actions: [.waitForCancellation])
        let request = try SavontClusteringRunRequest(
            inputFASTQURL: fixture.input,
            outputFASTAURL: fixture.output
        )
        let cleanupInjector = SynchronousInjectionRecorder()
        let task = Task {
            try await SavontClusteringPipeline(
                processRunner: runner,
                scratchRootURL: fixture.root,
                publicationFailureInjector: {},
                ownedCleanupInjector: { url in
                    guard url.lastPathComponent.contains("savont-run") else { return }
                    try cleanupInjector.fail(url)
                }
            ).run(request)
        }
        while await runner.invocations().isEmpty {
            await Task.yield()
        }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cleanup failure wrapping cancellation")
        } catch SavontClusteringError.cleanupFailed(
            let originalError,
            let retainedURLs,
            let cleanupErrors
        ) {
            XCTAssertEqual(originalError, CancellationError().localizedDescription)
            XCTAssertEqual(retainedURLs, cleanupInjector.invokedURLs)
            XCTAssertEqual(cleanupErrors.count, 1)
            XCTAssertTrue(cleanupErrors[0].contains("injected"))
        }

        let retainedRoot = try XCTUnwrap(cleanupInjector.invokedURLs.first)
        XCTAssertTrue(retainedRoot.lastPathComponent.contains("savont-run"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
    }

    func testSuccessfulExitWithoutFinalASVsFailsAndCleansScratch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = FakeSavontProcessRunner(actions: [.success(fasta: nil)])
        let request = try SavontClusteringRunRequest(inputFASTQURL: fixture.input, outputFASTAURL: fixture.output)

        do {
            _ = try await SavontClusteringPipeline(processRunner: runner, scratchRootURL: fixture.root).run(request)
            XCTFail("Expected missing output")
        } catch SavontClusteringError.missingFinalASVs(let url) {
            XCTAssertEqual(url.lastPathComponent, "final_asvs.fasta")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
        XCTAssertTrue(try fixture.temporaryArtifacts().isEmpty)
    }

    func testSuccessfulExitWithEmptyFinalASVsFailsAndCleansScratch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = FakeSavontProcessRunner(actions: [.success(fasta: "")])
        let request = try SavontClusteringRunRequest(
            inputFASTQURL: fixture.input,
            outputFASTAURL: fixture.output
        )

        do {
            _ = try await SavontClusteringPipeline(
                processRunner: runner,
                scratchRootURL: fixture.root
            ).run(request)
            XCTFail("Expected empty output failure")
        } catch SavontClusteringError.emptyFinalASVs(let url) {
            XCTAssertEqual(url.lastPathComponent, "final_asvs.fasta")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: ProvenanceRecorder.fileSidecarURL(for: fixture.output).path
            )
        )
        XCTAssertTrue(try fixture.temporaryArtifacts().isEmpty)
    }

    func testFailedRunCleanupReportsRetainedStagedOutput() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = FakeSavontProcessRunner(actions: [.success(fasta: "")])
        let request = try SavontClusteringRunRequest(
            inputFASTQURL: fixture.input,
            outputFASTAURL: fixture.output
        )
        let cleanupInjector = SynchronousInjectionRecorder()

        do {
            _ = try await SavontClusteringPipeline(
                processRunner: runner,
                scratchRootURL: fixture.root,
                publicationFailureInjector: {},
                ownedCleanupInjector: { url in
                    guard url.lastPathComponent.contains("savont-publish.tmp") else { return }
                    try cleanupInjector.fail(url)
                }
            ).run(request)
            XCTFail("Expected staged-output cleanup failure")
        } catch SavontClusteringError.cleanupFailed(
            let originalError,
            let retainedURLs,
            let cleanupErrors
        ) {
            XCTAssertTrue(originalError.contains("empty final_asvs.fasta"), originalError)
            XCTAssertEqual(retainedURLs, cleanupInjector.invokedURLs)
            XCTAssertEqual(cleanupErrors.count, 1)
        }

        let retainedOutput = try XCTUnwrap(cleanupInjector.invokedURLs.first)
        XCTAssertTrue(retainedOutput.lastPathComponent.contains("savont-publish.tmp"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedOutput.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
    }

    func testMalformedCountRejectsPublicationAndCleansScratch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = FakeSavontProcessRunner(actions: [.success(fasta: ">cluster_depth_bad\nACGT\n")])
        let request = try SavontClusteringRunRequest(inputFASTQURL: fixture.input, outputFASTAURL: fixture.output)

        do {
            _ = try await SavontClusteringPipeline(
                processRunner: runner,
                scratchRootURL: fixture.root
            ).run(request)
            XCTFail("Expected malformed supporting-read count")
        } catch let error as SavontClusterFASTAError {
            XCTAssertEqual(error, .malformedSupportingReadCount("cluster_depth_bad"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.output.path))
        XCTAssertTrue(try fixture.temporaryArtifacts().isEmpty)
    }

    func testPublicationFailureRestoresPriorOutputAndSidecar() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oldOutput = Data(">old_ReadCount-1\nAAAA\n".utf8)
        let oldSidecar = Data("old provenance".utf8)
        try oldOutput.write(to: fixture.output)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: fixture.output)
        try oldSidecar.write(to: sidecar)
        let runner = FakeSavontProcessRunner(actions: [.success(fasta: ">new_depth_8\nCCCC\n")])
        let request = try SavontClusteringRunRequest(inputFASTQURL: fixture.input, outputFASTAURL: fixture.output)
        let injector = SynchronousInjectionRecorder()

        do {
            _ = try await SavontClusteringPipeline(
                processRunner: runner,
                scratchRootURL: fixture.root,
                publicationFailureInjector: { try injector.fail() }
            ).run(request)
            XCTFail("Expected injected pre-commit publication failure")
        } catch TestFailure.injected {
            // Expected exact failure after the new output is installed but before the sidecar commit.
        } catch {
            XCTFail("Expected TestFailure.injected, got \(error)")
        }

        XCTAssertEqual(injector.invocationCount, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.output), oldOutput)
        XCTAssertEqual(try Data(contentsOf: sidecar), oldSidecar)
        XCTAssertTrue(try fixture.temporaryArtifacts().isEmpty)
    }

    func testCommittedPairReportsBackupCleanupPendingWithoutRollback() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let oldOutput = Data(">old_ReadCount-1\nAAAA\n".utf8)
        let oldSidecar = Data("old provenance".utf8)
        try oldOutput.write(to: fixture.output)
        let sidecar = ProvenanceRecorder.fileSidecarURL(for: fixture.output)
        try oldSidecar.write(to: sidecar)
        let runner = FakeSavontProcessRunner(actions: [.success(fasta: ">new_depth_8\nCCCC\n")])
        let request = try SavontClusteringRunRequest(inputFASTQURL: fixture.input, outputFASTAURL: fixture.output)
        let cleanupInjector = SynchronousInjectionRecorder()

        let result = try await SavontClusteringPipeline(
            processRunner: runner,
            scratchRootURL: fixture.root,
            publicationFailureInjector: {},
            publicationBackupCleanupInjector: { url in
                try cleanupInjector.fail(url)
            }
        ).run(request)

        XCTAssertEqual(cleanupInjector.invocationCount, 2)
        XCTAssertEqual(result.cleanupPendingURLs, cleanupInjector.invokedURLs)
        XCTAssertEqual(result.cleanupPendingURLs.count, 2)
        XCTAssertEqual(
            try String(contentsOf: fixture.output, encoding: .utf8),
            ">new_depth_8_ReadCount-8\nCCCC\n"
        )
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: sidecar))
        XCTAssertEqual(envelope.options.resolvedDefaults["publicationBackupCleanupRequired"], .boolean(true))
        XCTAssertEqual(envelope.options.resolvedDefaults["publicationBackupCleanupCandidateCount"], .integer(2))
        XCTAssertEqual(
            envelope.options.resolvedDefaults["publicationBackupCleanupStatus"],
            .string("evaluated-after-commit")
        )
        for backupURL in result.cleanupPendingURLs {
            XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        }
        let retainedBytes = try Set(result.cleanupPendingURLs.map { try Data(contentsOf: $0) })
        XCTAssertEqual(retainedBytes, Set([oldOutput, oldSidecar]))
    }

    func testSuccessfulPublicationReportsRetainedRunRootWhenOwnedCleanupFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runner = FakeSavontProcessRunner(actions: [.success(fasta: ">cluster_depth_4\nACGT\n")])
        let request = try SavontClusteringRunRequest(
            inputFASTQURL: fixture.input,
            outputFASTAURL: fixture.output
        )
        let cleanupInjector = SynchronousInjectionRecorder()

        let result = try await SavontClusteringPipeline(
            processRunner: runner,
            scratchRootURL: fixture.root,
            publicationFailureInjector: {},
            ownedCleanupInjector: { url in
                guard url.lastPathComponent.contains("savont-run") else { return }
                try cleanupInjector.fail(url)
            }
        ).run(request)

        XCTAssertEqual(result.cleanupPendingURLs, cleanupInjector.invokedURLs)
        let retainedRoot = try XCTUnwrap(result.cleanupPendingURLs.first)
        XCTAssertTrue(retainedRoot.lastPathComponent.contains("savont-run"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedRoot.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.output.path))
        XCTAssertNotNil(try ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
    }

    func testResultCodableRoundTripPreservesCleanupPendingURLsAndDecodesLegacyResults() throws {
        let result = SavontClusteringResult(
            outputFASTAURL: URL(fileURLWithPath: "/output/clusters.fasta"),
            provenanceURL: URL(fileURLWithPath: "/output/clusters.fasta.provenance.json"),
            summary: SavontClusterSummary(clusterCount: 2, totalSupportingReads: 9),
            usedSingleThreadFallback: true,
            usedSingleStrandFallback: false,
            cleanupPendingURLs: [URL(fileURLWithPath: "/output/.clusters.backup")]
        )
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        XCTAssertEqual(try decoder.decode(SavontClusteringResult.self, from: encoder.encode(result)), result)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(result)) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "cleanupPendingURLs")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyResult = try decoder.decode(SavontClusteringResult.self, from: legacyData)
        XCTAssertEqual(legacyResult.cleanupPendingURLs, [])
    }

    private func argument(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

private enum TestFailure: Error {
    case injected
    case missingInputArgument
    case unexpectedMaterializedInput
    case materializedInputIsWritable(Int)
}

private final class SynchronousInjectionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    var invocationCount: Int {
        lock.withLock { urls.count }
    }

    var invokedURLs: [URL] {
        lock.withLock { urls }
    }

    func fail(_ url: URL = URL(fileURLWithPath: "/pre-commit")) throws {
        lock.withLock { urls.append(url) }
        throw TestFailure.injected
    }
}

private struct SavontInvocation: Sendable {
    let arguments: [String]
    let workingDirectory: URL
}

private actor FakeSavontProcessRunner: SavontProcessRunning {
    enum Action: Sendable {
        case result(SavontProcessResult, fasta: String?)
        case inspectInput(expectedInput: String, fasta: String)
        case mutateSourceAndInspectInput(URL, replacement: String, expectedInput: String, fasta: String)
        case waitForCancellation

        static func success(fasta: String?) -> Action {
            .result(
                SavontProcessResult(
                    exitCode: 0,
                    stdout: "ok",
                    stderr: "",
                    argv: [],
                    runtimeIdentity: Fixture.fixedRuntimeIdentity,
                    startedAt: Date(timeIntervalSince1970: 10),
                    completedAt: Date(timeIntervalSince1970: 11)
                ),
                fasta: fasta
            )
        }

        static func failure(status: Int32, stderr: String) -> Action {
            .result(
                SavontProcessResult(
                    exitCode: status,
                    stdout: "",
                    stderr: stderr,
                    argv: [],
                    runtimeIdentity: Fixture.fixedRuntimeIdentity,
                    startedAt: Date(timeIntervalSince1970: 10),
                    completedAt: Date(timeIntervalSince1970: 11)
                ),
                fasta: nil
            )
        }
    }

    private var actions: [Action]
    private var recordedInvocations: [SavontInvocation] = []

    init(actions: [Action]) {
        self.actions = actions
    }

    func run(arguments: [String], workingDirectory: URL) async throws -> SavontProcessResult {
        recordedInvocations.append(SavontInvocation(arguments: arguments, workingDirectory: workingDirectory))
        guard !actions.isEmpty else { throw TestFailure.injected }
        let action = actions.removeFirst()
        switch action {
        case .result(var result, let fasta):
            if let fasta {
                try fasta.write(
                    to: workingDirectory.appendingPathComponent("final_asvs.fasta"),
                    atomically: true,
                    encoding: .utf8
                )
            }
            if result.argv.isEmpty || result.argv == ["/managed/savont"] {
                let executableArgv = result.argv.isEmpty ? ["savont"] : result.argv
                result = SavontProcessResult(
                    exitCode: result.exitCode,
                    stdout: result.stdout,
                    stderr: result.stderr,
                    argv: executableArgv + arguments,
                    runtimeIdentity: result.runtimeIdentity,
                    startedAt: result.startedAt,
                    completedAt: result.completedAt
                )
            }
            return result
        case .inspectInput(let expectedInput, let fasta):
            try inspectInput(arguments: arguments, expected: expectedInput)
            return try successfulResult(arguments: arguments, workingDirectory: workingDirectory, fasta: fasta)
        case .mutateSourceAndInspectInput(let inputURL, let replacement, let expectedInput, let fasta):
            try replacement.write(to: inputURL, atomically: true, encoding: .utf8)
            try inspectInput(arguments: arguments, expected: expectedInput)
            return try successfulResult(arguments: arguments, workingDirectory: workingDirectory, fasta: fasta)
        case .waitForCancellation:
            try await Task.sleep(for: .seconds(5))
            throw TestFailure.injected
        }
    }

    private func inspectInput(arguments: [String], expected: String) throws {
        guard arguments.first == "asv", arguments.indices.contains(1) else {
            throw TestFailure.missingInputArgument
        }
        let inputURL = URL(fileURLWithPath: arguments[1])
        guard try String(contentsOf: inputURL, encoding: .utf8) == expected else {
            throw TestFailure.unexpectedMaterializedInput
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: inputURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
        guard permissions == 0o400 else {
            throw TestFailure.materializedInputIsWritable(permissions)
        }
    }

    private func successfulResult(
        arguments: [String],
        workingDirectory: URL,
        fasta: String
    ) throws -> SavontProcessResult {
        try fasta.write(
            to: workingDirectory.appendingPathComponent("final_asvs.fasta"),
            atomically: true,
            encoding: .utf8
        )
        return SavontProcessResult(
            exitCode: 0,
            stdout: "ok",
            stderr: "",
            argv: ["savont"] + arguments,
            runtimeIdentity: Fixture.fixedRuntimeIdentity,
            startedAt: Date(timeIntervalSince1970: 10),
            completedAt: Date(timeIntervalSince1970: 11)
        )
    }

    func invocations() -> [SavontInvocation] {
        recordedInvocations
    }
}

private struct Fixture {
    let root: URL
    let input: URL
    let payload: URL
    let output: URL

    static let fixedRuntimeIdentity = ProvenanceRuntimeIdentity(
        appVersion: "test-app",
        executablePath: "/managed/micromamba",
        processIdentifier: 123,
        operatingSystemVersion: "test-os",
        architecture: "arm64",
        gitRevision: "abc123",
        user: "tester",
        condaEnvironment: "savont",
        condaPrefix: "/managed/conda/envs/savont"
    )

    var runtimeIdentity: ProvenanceRuntimeIdentity { Self.fixedRuntimeIdentity }

    init(bundleInput: Bool = false) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("savont-pipeline-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        output = root.appendingPathComponent("clusters.fasta")
        if bundleInput {
            input = root.appendingPathComponent("reads.lungfishfastq", isDirectory: true)
            try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
            payload = input.appendingPathComponent("reads.fastq")
        } else {
            input = root.appendingPathComponent("reads.fastq")
            payload = input
        }
        try "@r1\nACGT\n+\nIIII\n".write(to: payload, atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func temporaryArtifacts() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ).filter { url in
            let name = url.lastPathComponent
            return name.contains("savont-attempt")
                || name.contains("savont-run")
                || name.contains("savont-publish")
                || name.hasSuffix(".backup")
                || name.hasSuffix(".tmp")
        }
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {
        // Expected.
    }
}
