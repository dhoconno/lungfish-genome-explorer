import Foundation
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
                    argv: ["/managed/savont", "asv", fixture.input.path],
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

        XCTAssertEqual(envelope.steps.count, 1)
        let step = try XCTUnwrap(envelope.steps.first)
        XCTAssertEqual(step.argv, ["/managed/savont", "asv", fixture.input.path])
        XCTAssertEqual(step.exitStatus, 0)
        XCTAssertEqual(step.stderr, "diagnostic\n")
        XCTAssertEqual(step.wallTimeSeconds, 2)
        XCTAssertEqual(step.runtimeIdentity, runtime)
        XCTAssertEqual(step.inputs.map(\.path), [fixture.input.path])
        XCTAssertNotNil(step.inputs.first?.checksumSHA256)
        XCTAssertEqual(step.outputs.count, 1)
        XCTAssertEqual(step.outputs.first?.fileSize, 57)
        XCTAssertTrue(step.outputs.first?.path.hasSuffix("/final_asvs.fasta") == true)
        XCTAssertTrue(try fixture.temporaryArtifacts().isEmpty)
    }

    func testBundleInputUsesDurableBundleAtTopLevelAndResolvedPayloadForAttempt() async throws {
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
        let resolved = try XCTUnwrap(envelope.steps.first?.inputs.first)
        XCTAssertEqual(
            URL(fileURLWithPath: resolved.path).resolvingSymlinksInPath(),
            fixture.payload.resolvingSymlinksInPath()
        )
        XCTAssertNotNil(resolved.checksumSHA256)
        let invocations = await runner.invocations()
        let invocation = try XCTUnwrap(invocations.first)
        XCTAssertEqual(
            URL(fileURLWithPath: invocation.arguments[1]).resolvingSymlinksInPath(),
            fixture.payload.resolvingSymlinksInPath()
        )
        XCTAssertTrue(try fixture.temporaryArtifacts().isEmpty)
    }

    func testPlainFASTQProvenanceUsesPreRunConsumedSnapshotWhenInputMutatesDuringRun() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let consumedChecksum = try ProvenanceFileHasher.sha256(of: fixture.input)
        let consumedSize = try ProvenanceFileHasher.fileSize(of: fixture.input)
        let replacementFASTQ = "@replacement\nTTTTTT\n+\nIIIIII\n"
        let runner = FakeSavontProcessRunner(actions: [
            .mutateInput(
                fixture.input,
                replacement: replacementFASTQ,
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
        let attemptInput = try XCTUnwrap(envelope.steps.first?.inputs.first)
        XCTAssertEqual(topLevelInput.checksumSHA256, consumedChecksum)
        XCTAssertEqual(topLevelInput.fileSize, consumedSize)
        XCTAssertEqual(attemptInput.checksumSHA256, consumedChecksum)
        XCTAssertEqual(attemptInput.fileSize, consumedSize)
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
        XCTAssertNotEqual(invocations[0].workingDirectory, invocations[1].workingDirectory)
        let envelope = try XCTUnwrap(ProvenanceEnvelopeReader.load(fromSidecar: result.provenanceURL))
        XCTAssertEqual(envelope.steps.map(\.exitStatus), [139, 0])
        XCTAssertEqual(envelope.steps.count, invocations.count)
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
        XCTAssertEqual(envelope.steps.count, 2)
        XCTAssertEqual(envelope.steps.map(\.exitStatus), [1, 0])
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
        XCTAssertEqual(envelope.steps.count, 2)
        XCTAssertEqual(envelope.steps.map(\.exitStatus), [1, 1])
        XCTAssertEqual(envelope.exitStatus, 0)
        XCTAssertEqual(envelope.options.resolvedDefaults["emptyClusterFallback"], .boolean(true))
        XCTAssertTrue(try fixture.temporaryArtifacts().isEmpty)
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

        await XCTAssertThrowsErrorAsync {
            try await SavontClusteringPipeline(
                processRunner: runner,
                scratchRootURL: fixture.root,
                publicationFailureInjector: { throw TestFailure.injected }
            ).run(request)
        }

        XCTAssertEqual(try Data(contentsOf: fixture.output), oldOutput)
        XCTAssertEqual(try Data(contentsOf: sidecar), oldSidecar)
        XCTAssertTrue(try fixture.temporaryArtifacts().isEmpty)
    }

    private func argument(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }
}

private enum TestFailure: Error {
    case injected
}

private struct SavontInvocation: Sendable {
    let arguments: [String]
    let workingDirectory: URL
}

private actor FakeSavontProcessRunner: SavontProcessRunning {
    enum Action: Sendable {
        case result(SavontProcessResult, fasta: String?)
        case mutateInput(URL, replacement: String, fasta: String)
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
            if result.argv.isEmpty {
                result = SavontProcessResult(
                    exitCode: result.exitCode,
                    stdout: result.stdout,
                    stderr: result.stderr,
                    argv: ["savont"] + arguments,
                    runtimeIdentity: result.runtimeIdentity,
                    startedAt: result.startedAt,
                    completedAt: result.completedAt
                )
            }
            return result
        case .mutateInput(let inputURL, let replacement, let fasta):
            try replacement.write(to: inputURL, atomically: true, encoding: .utf8)
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
        case .waitForCancellation:
            try await Task.sleep(for: .seconds(60))
            throw TestFailure.injected
        }
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
